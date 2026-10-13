#!/usr/bin/env bash
# Offline regression tests for exact source/tag/version checks and the new package gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"
source "${ROOT}/scripts/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
unset ALLOW_MISSING_RESULTS

expect_failure() {
  local label="$1"; shift
  if ( "$@" ) >"${TMP}/failure.log" 2>&1; then
    echo "FAIL: ${label} unexpectedly passed" >&2
    exit 1
  fi
  echo "PASS: rejects ${label}"
}

for type in tag commit; do
  LLAMA_CPP_DIR="${TMP}/${type}"
  git init --quiet "${LLAMA_CPP_DIR}"
  git -C "${LLAMA_CPP_DIR}" config user.name 'Source pin tests'
  git -C "${LLAMA_CPP_DIR}" config user.email 'tests@example.invalid'
  git -C "${LLAMA_CPP_DIR}" config commit.gpgsign false
  git -C "${LLAMA_CPP_DIR}" config tag.gpgsign false
  echo original > "${LLAMA_CPP_DIR}/source.txt"
  git -C "${LLAMA_CPP_DIR}" add source.txt
  git -C "${LLAMA_CPP_DIR}" commit --quiet -m original
  EXPECTED_LLAMA_CPP_COMMIT="$(git -C "${LLAMA_CPP_DIR}" rev-parse HEAD)"
  EXPECTED_LLAMA_CPP_TAG_TYPE="${type}"
  LLAMA_CPP_TAG="pin-${type}"
  if [[ "${type}" == tag ]]; then
    git -C "${LLAMA_CPP_DIR}" tag -a "${LLAMA_CPP_TAG}" -m original
  else
    git -C "${LLAMA_CPP_DIR}" tag "${LLAMA_CPP_TAG}"
  fi
  verify_llama_cpp_source
  echo "PASS: accepts explicitly pinned ${type} tag"

  original="${EXPECTED_LLAMA_CPP_COMMIT}"
  EXPECTED_LLAMA_CPP_COMMIT="0000000000000000000000000000000000000000"
  expect_failure 'wrong HEAD commit' verify_llama_cpp_source
  EXPECTED_LLAMA_CPP_COMMIT="${original}"
  if [[ "${type}" == tag ]]; then EXPECTED_LLAMA_CPP_TAG_TYPE=commit
  else EXPECTED_LLAMA_CPP_TAG_TYPE=tag; fi
  expect_failure 'unexpected tag object type' verify_llama_cpp_source
  EXPECTED_LLAMA_CPP_TAG_TYPE="${type}"
  echo modified > "${LLAMA_CPP_DIR}/source.txt"
  expect_failure 'dirty source checkout' verify_llama_cpp_source
  echo original > "${LLAMA_CPP_DIR}/source.txt"
done

# The lightweight tag moves away from the otherwise correct HEAD.
git -C "${LLAMA_CPP_DIR}" commit --allow-empty --quiet -m other
other="$(git -C "${LLAMA_CPP_DIR}" rev-parse HEAD)"
git -C "${LLAMA_CPP_DIR}" switch --quiet --detach "${EXPECTED_LLAMA_CPP_COMMIT}"
git -C "${LLAMA_CPP_DIR}" update-ref "refs/tags/${LLAMA_CPP_TAG}" "${other}"
expect_failure 'moved tag despite correct HEAD' verify_llama_cpp_source

header="${TMP}/llama-version.h"
for version in "${EXPECTED_LLAMA_CPP_VERSION}" "${EXPECTED_LLAMA_CPP_VERSION}-dev"; do
  printf '#define LLAMA_VERSION "%s"\n#define LLAMA_COMMIT "%s"\n' \
    "${version}" "${EXPECTED_LLAMA_CPP_COMMIT:0:7}" > "${header}"
  verify_llama_cpp_embedded_version "${header}"
done
printf '#define LLAMA_VERSION "99.0.0"\n#define LLAMA_COMMIT "%s"\n' \
  "${EXPECTED_LLAMA_CPP_COMMIT:0:7}" > "${header}"
expect_failure 'wrong embedded semantic version' verify_llama_cpp_embedded_version "${header}"
printf '#define LLAMA_VERSION "%s-dev"\n#define LLAMA_COMMIT "unknown"\n' \
  "${EXPECTED_LLAMA_CPP_VERSION}" > "${header}"
expect_failure 'unknown embedded commit' verify_llama_cpp_embedded_version "${header}"

# Exercise the actual packaging gate with successful legacy results, but no (or bad)
# new model result. These synthetic JSON files are never production artifacts.
source "${ROOT}/scripts/config.env"
for profile in ${SUPPORTED_TARGET_PROFILES}; do
  set_target_profile "${profile}"
  metadata="${TMP}/provenance-${profile}.json"
  jq -n \
    --arg contract "${ARTIFACT_CONTRACT_VERSION}" \
    --arg tag "${LLAMA_CPP_TAG}" --arg kind "${EXPECTED_LLAMA_CPP_TAG_TYPE}" \
    --arg commit "${EXPECTED_LLAMA_CPP_COMMIT}" --arg version "${EXPECTED_LLAMA_CPP_VERSION}" \
    --arg crate "${CRATE_REF}" --arg crate_commit "${EXPECTED_CRATE_COMMIT}" \
    --arg gitlink "${CRATE_VENDORED_LLAMA_CPP_COMMIT}" --arg crate_version "${CRATE_VERSION}" \
    --arg features "${CRATE_FEATURES}" --arg profile "${TARGET_PROFILE}" \
    --arg triple "${TARGET_TRIPLE}" --arg arch "${TARGET_ARCH}" \
    --arg baseline "${CPU_BASELINE}" --arg cpu "${CPU_PROFILE}" \
    --arg flags "${CFLAGS_TUNE}" --arg march "${CPU_MARCH}" --arg mtune "${CPU_MTUNE}" \
    '{artifact_contract_version:$contract,
      llama_cpp:{tag:$tag,tag_type:$kind,commit:$commit,describe:$tag,
                 embedded_version:($version+"-dev"),embedded_commit:($commit[:7])},
      llama_cpp_rs:{git_ref:$crate,commit:$crate_commit,vendored_llama_cpp_commit:$gitlink},
      llama_cpp_sys_2:{version:$crate_version,default_features:false,
                      features:($features|split(",")|map(select(.!="")))},
      target_profile:$profile,architecture:$arch,target_triple:$triple,
      cpu_baseline:$baseline,cpu_profile:$cpu,effective_arch_flags:$flags,
      arch_flag_summary:{march:$march,mtune:(if $mtune=="" then null else $mtune end),
                        conflicts:0,effective_isa:$baseline,disassembly:{above_v3:0}},
      build_env:{native_build:true,host_arch:$arch},
      host:{native_build:true,architecture:$arch,cpu_capability:{baseline:$baseline,result:"PASS"}},
      pgo:{enabled:false,use_flags:null}}' > "${metadata}"
  bash "${ROOT}/scripts/verify-provenance.sh" "${metadata}" "${profile}"
  for alteration in '.llama_cpp.tag_type="tag"' '.llama_cpp.embedded_version="99.0.0"' \
                    '.llama_cpp.commit="wrong"' '.host.native_build=false'; do
    jq "${alteration}" "${metadata}" > "${TMP}/bad-provenance.json"
    expect_failure "${profile} provenance ${alteration}" \
      bash "${ROOT}/scripts/verify-provenance.sh" "${TMP}/bad-provenance.json" "${profile}"
  done
  jq --arg id "${EMBEDDINGGEMMA_MODEL_ID}" --arg sha "${EMBEDDINGGEMMA_MODEL_SHA256}" \
    --argjson hidden "${EMBEDDINGGEMMA_HIDDEN_DIM}" --argjson output "${EMBEDDINGGEMMA_OUTPUT_DIM}" \
    '.embeddinggemma_smoke={passed:true,model_id:$id,model_sha256:$sha,n_embd:$hidden,n_embd_out:$output}' \
    "${metadata}" > "${TMP}/packaged-provenance.json"
  bash "${ROOT}/scripts/verify-provenance.sh" "${TMP}/packaged-provenance.json" "${profile}"
  for alteration in '.embeddinggemma_smoke.model_sha256="wrong"' '.embeddinggemma_smoke.n_embd_out=512' \
                    '.embeddinggemma_smoke.passed=false'; do
    jq "${alteration}" "${TMP}/packaged-provenance.json" > "${TMP}/bad-provenance.json"
    expect_failure "${profile} provenance ${alteration}" \
      bash "${ROOT}/scripts/verify-provenance.sh" "${TMP}/bad-provenance.json" "${profile}"
  done
done
scratch="${TMP}/package"
mkdir -p "${scratch}/scripts" "${scratch}/dist" "${scratch}/results"
cp "${ROOT}/scripts/package.sh" "${ROOT}/scripts/config.env" "${scratch}/scripts/"
echo '{}' > "${scratch}/dist/build-info.json"
for result in smoke bench correctness; do echo '{"passed":true}' > "${scratch}/results/${result}.json"; done
export DIST="${scratch}/dist" RESULTS="${scratch}/results"
expect_failure 'missing EmbeddingGemma smoke result' bash "${scratch}/scripts/package.sh"
jq -n --arg id "${EMBEDDINGGEMMA_MODEL_ID}" --arg sha "${EMBEDDINGGEMMA_MODEL_SHA256}" \
  '{passed:true, model_id:$id, model_sha256:$sha, n_embd:512, n_embd_out:512}' \
  > "${scratch}/results/embeddinggemma-smoke.json"
expect_failure 'truncated EmbeddingGemma output' bash "${scratch}/scripts/package.sh"
echo '{"passed":false}' > "${scratch}/results/embeddinggemma-smoke.json"
expect_failure 'failed EmbeddingGemma smoke result' bash "${scratch}/scripts/package.sh"
echo 'All source pin and package-gate regression tests passed'
