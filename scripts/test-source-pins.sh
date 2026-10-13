#!/usr/bin/env bash
# Offline regression tests for exact source/tag/version checks, provenance verification
# (raw and packaged modes) and the release-results gate that package.sh and
# verify-provenance.sh share. Each negative case starts from a baseline that passes,
# changes one input, and must fail with the diagnostic of the check it targets.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"
source "${ROOT}/scripts/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
unset ALLOW_MISSING_RESULTS

# expect_failure LABEL DIAGNOSTIC CMD...: CMD must exit non-zero AND print DIAGNOSTIC (a
# fixed string), so a case cannot pass because something unrelated failed first.
expect_failure() {
  local label="$1" diagnostic="$2"; shift 2
  if ( "$@" ) >"${TMP}/failure.log" 2>&1; then
    echo "FAIL: ${label} unexpectedly passed" >&2
    exit 1
  fi
  if ! grep -qF -- "${diagnostic}" "${TMP}/failure.log"; then
    echo "FAIL: ${label} failed without the expected diagnostic '${diagnostic}':" >&2
    cat "${TMP}/failure.log" >&2
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
  expect_failure 'wrong HEAD commit' "llama.cpp HEAD ${original} != expected" verify_llama_cpp_source
  EXPECTED_LLAMA_CPP_COMMIT="${original}"
  if [[ "${type}" == tag ]]; then EXPECTED_LLAMA_CPP_TAG_TYPE=commit
  else EXPECTED_LLAMA_CPP_TAG_TYPE=tag; fi
  expect_failure 'unexpected tag object type' \
    "llama.cpp ${LLAMA_CPP_TAG} is a ${type}, expected ${EXPECTED_LLAMA_CPP_TAG_TYPE}" verify_llama_cpp_source
  EXPECTED_LLAMA_CPP_TAG_TYPE="${type}"
  echo modified > "${LLAMA_CPP_DIR}/source.txt"
  expect_failure 'dirty source checkout' 'llama.cpp checkout has local modifications' verify_llama_cpp_source
  echo original > "${LLAMA_CPP_DIR}/source.txt"
done

# The lightweight tag moves away from the otherwise correct HEAD.
git -C "${LLAMA_CPP_DIR}" commit --allow-empty --quiet -m other
other="$(git -C "${LLAMA_CPP_DIR}" rev-parse HEAD)"
git -C "${LLAMA_CPP_DIR}" switch --quiet --detach "${EXPECTED_LLAMA_CPP_COMMIT}"
git -C "${LLAMA_CPP_DIR}" update-ref "refs/tags/${LLAMA_CPP_TAG}" "${other}"
expect_failure 'moved tag despite correct HEAD' "llama.cpp tag ${LLAMA_CPP_TAG} -> '${other}'" verify_llama_cpp_source

header="${TMP}/llama-version.h"
for version in "${EXPECTED_LLAMA_CPP_VERSION}" "${EXPECTED_LLAMA_CPP_VERSION}-dev"; do
  printf '#define LLAMA_VERSION "%s"\n#define LLAMA_COMMIT "%s"\n' \
    "${version}" "${EXPECTED_LLAMA_CPP_COMMIT:0:7}" > "${header}"
  verify_llama_cpp_embedded_version "${header}"
done
printf '#define LLAMA_VERSION "99.0.0"\n#define LLAMA_COMMIT "%s"\n' \
  "${EXPECTED_LLAMA_CPP_COMMIT:0:7}" > "${header}"
expect_failure 'wrong embedded semantic version' "compiled llama.cpp version '99.0.0'" \
  verify_llama_cpp_embedded_version "${header}"
printf '#define LLAMA_VERSION "%s-dev"\n#define LLAMA_COMMIT "unknown"\n' \
  "${EXPECTED_LLAMA_CPP_VERSION}" > "${header}"
expect_failure 'unknown embedded commit' "compiled llama.cpp commit 'unknown'" \
  verify_llama_cpp_embedded_version "${header}"

verify_provenance() { bash "${ROOT}/scripts/verify-provenance.sh" "$@"; }

# expect_verify_rejects MODE PROFILE BASELINE DIAGNOSTIC ALTERATION: apply one jq ALTERATION
# to a BASELINE that verifies, and require verify-provenance.sh --MODE to reject it with
# DIAGNOSTIC.
expect_verify_rejects() {
  local mode="$1" profile="$2" baseline="$3" diagnostic="$4" alteration="$5"
  jq "${alteration}" "${baseline}" > "${TMP}/bad-provenance.json"
  expect_failure "${profile} --${mode} ${alteration}" "${diagnostic}" \
    verify_provenance "--${mode}" "${TMP}/bad-provenance.json" "${profile}"
}

# Synthetic build-info.json per profile, from the canonical pins; never a production artifact.
# The raw form mirrors build.sh output: null result placeholders, no embeddinggemma_smoke.
# The packaged form adds the four passing results package.sh merges.
source "${ROOT}/scripts/config.env"
for profile in ${SUPPORTED_TARGET_PROFILES}; do
  set_target_profile "${profile}"
  metadata="${TMP}/provenance-${profile}.json"
  packaged="${TMP}/packaged-${profile}.json"
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
      pgo:{enabled:false,use_flags:null},
      smoke:null,benchmark:null,correctness:null}' > "${metadata}"
  jq --arg id "${EMBEDDINGGEMMA_MODEL_ID}" --arg sha "${EMBEDDINGGEMMA_MODEL_SHA256}" \
    --argjson hidden "${EMBEDDINGGEMMA_HIDDEN_DIM}" --argjson output "${EMBEDDINGGEMMA_OUTPUT_DIM}" \
    '.smoke={passed:true} | .benchmark={passed:true} | .correctness={passed:true}
     | .embeddinggemma_smoke={passed:true,model_id:$id,model_sha256:$sha,n_embd:$hidden,n_embd_out:$output}' \
    "${metadata}" > "${packaged}"

  # Raw mode accepts fresh build.sh metadata; packaged mode, the default, requires results.
  verify_provenance --raw "${metadata}" "${profile}"
  verify_provenance "${packaged}" "${profile}"
  expect_failure "${profile} raw metadata in the default (packaged) mode" '.smoke: missing' \
    verify_provenance "${metadata}" "${profile}"

  # Pins are checked in both modes.
  for mode in packaged raw; do
    verify_provenance "--${mode}" "${packaged}" "${profile}"
    expect_verify_rejects "${mode}" "${profile}" "${packaged}" 'provenance mismatch: llama_cpp.tag_type' \
      '.llama_cpp.tag_type="tag"'
    expect_verify_rejects "${mode}" "${profile}" "${packaged}" 'provenance mismatch: llama_cpp.embedded_version' \
      '.llama_cpp.embedded_version="99.0.0"'
    expect_verify_rejects "${mode}" "${profile}" "${packaged}" 'provenance mismatch: llama_cpp.commit' \
      '.llama_cpp.commit="wrong"'
    expect_verify_rejects "${mode}" "${profile}" "${packaged}" 'provenance mismatch: host.native_build' \
      '.host.native_build=false'
  done

  # Packaged mode requires every result, passing; raw mode still rejects a failed one.
  for result in smoke embeddinggemma_smoke benchmark correctness; do
    expect_verify_rejects packaged "${profile}" "${packaged}" ".${result}: missing" "del(.${result})"
    expect_verify_rejects packaged "${profile}" "${packaged}" ".${result}: missing" ".${result}=null"
    expect_verify_rejects packaged "${profile}" "${packaged}" ".${result}: true, expected a result object" \
      ".${result}=true"
    for passed in false '"true"' null; do
      expect_verify_rejects packaged "${profile}" "${packaged}" ".${result}.passed: ${passed}, expected true" \
        ".${result}.passed=${passed}"
    done
    expect_verify_rejects raw "${profile}" "${packaged}" ".${result}.passed: false, expected true" \
      ".${result}.passed=false"
  done

  # The EmbeddingGemma result must match its pins in both modes.
  for alteration in '.model_id="other/model"' '.model_sha256="wrong"' '.n_embd=768' '.n_embd_out=512'; do
    for mode in packaged raw; do
      expect_verify_rejects "${mode}" "${profile}" "${packaged}" ".embeddinggemma_smoke${alteration%%=*}: " \
        ".embeddinggemma_smoke${alteration}"
    done
  done
done

expect_failure 'unknown verify-provenance option' "unknown option '--bogus'" \
  verify_provenance --bogus "${packaged}" "${profile}"
expect_failure 'verify-provenance mode flag after the file' 'too many arguments' \
  verify_provenance "${packaged}" "${profile}" --raw

# The real package.sh, run in place with DIST/RESULTS/SRC in scratch (no llama.cpp source
# tree, so only the builder LICENSE is gathered), over one profile's synthetic raw metadata
# and synthetic results. Never released.
package_profile="${SUPPORTED_TARGET_PROFILES%% *}"
raw_build_info="${TMP}/provenance-${package_profile}.json"
package_dir="${TMP}/package"
stage_package() {
  local result
  rm -rf "${package_dir}"
  mkdir -p "${package_dir}/dist" "${package_dir}/results"
  cp "${raw_build_info}" "${package_dir}/dist/build-info.json"
  for result in smoke bench correctness; do
    echo '{"passed":true}' > "${package_dir}/results/${result}.json"
  done
  jq -n --arg id "${EMBEDDINGGEMMA_MODEL_ID}" --arg sha "${EMBEDDINGGEMMA_MODEL_SHA256}" \
    --argjson hidden "${EMBEDDINGGEMMA_HIDDEN_DIM}" --argjson output "${EMBEDDINGGEMMA_OUTPUT_DIM}" \
    '{passed:true,n_embd:$hidden,n_embd_out:$output,n_tokens:15,l2_norm:1.0,
      model_id:$id,model_sha256:$sha}' > "${package_dir}/results/embeddinggemma-smoke.json"
}
alter_result() {
  local result="${package_dir}/results/$1.json"
  jq "$2" "${result}" > "${result}.new" && mv "${result}.new" "${result}"
}
run_package() {
  DIST="${package_dir}/dist" RESULTS="${package_dir}/results" SRC="${package_dir}/no-source" \
    bash "${ROOT}/scripts/package.sh"
}
verify_packaged() { verify_provenance --packaged "${package_dir}/dist/build-info.json" "${package_profile}"; }
# expect_package_rejects LABEL DIAGNOSTIC: package.sh must fail at the results gate, before
# it replaces build-info.json or writes SHA256SUMS.
expect_package_rejects() {
  expect_failure "$1" "$2" run_package
  [[ "$(< "${package_dir}/dist/build-info.json")" == "$(< "${raw_build_info}")" ]] \
    || { echo "FAIL: package.sh replaced build-info.json despite rejecting $1" >&2; exit 1; }
  [[ ! -e "${package_dir}/dist/SHA256SUMS" ]] \
    || { echo "FAIL: package.sh wrote SHA256SUMS despite rejecting $1" >&2; exit 1; }
}

# Result file in RESULTS : key in build-info.json.
results_map=(smoke:smoke embeddinggemma-smoke:embeddinggemma_smoke bench:benchmark correctness:correctness)

stage_package
run_package > "${TMP}/package.log" 2>&1 \
  || { cat "${TMP}/package.log" >&2; echo "FAIL: package.sh rejected a fully passing result set" >&2; exit 1; }
for pair in "${results_map[@]}"; do
  jq -e --slurpfile want "${package_dir}/results/${pair%%:*}.json" --arg key "${pair#*:}" \
    '.[$key] == $want[0]' "${package_dir}/dist/build-info.json" >/dev/null \
    || { echo "FAIL: package.sh did not merge ${pair%%:*}.json verbatim as .${pair#*:}" >&2; exit 1; }
done
( cd "${package_dir}/dist" && sha256sum -c --quiet SHA256SUMS )
verify_packaged
echo "PASS: packages a fully passing result set, which verifies in packaged mode"

for pair in "${results_map[@]}"; do
  result="${pair%%:*}" key="${pair#*:}"
  stage_package
  rm "${package_dir}/results/${result}.json"
  expect_package_rejects "missing ${result} result" ".${key}: missing"
  # The string "true" used to pass: the old per-file gate compared jq -r output to "true".
  for passed in false '"true"'; do
    stage_package
    alter_result "${result}" ".passed=${passed}"
    expect_package_rejects "${result} result .passed=${passed}" ".${key}.passed: ${passed}, expected true"
  done
done
for alteration in '.model_id="other/model"' '.model_sha256="wrong"' '.n_embd=768' '.n_embd_out=512'; do
  stage_package
  alter_result embeddinggemma-smoke "${alteration}"
  expect_package_rejects "EmbeddingGemma smoke result ${alteration}" ".embeddinggemma_smoke${alteration%%=*}: "
done

# ALLOW_MISSING_RESULTS=1 (local dev only) packages missing or failed results; the packaged
# verifier, which runs after package.sh and in the release job, must still reject them.
stage_package
rm "${package_dir}/results/bench.json"
alter_result correctness '.passed=false'
ALLOW_MISSING_RESULTS=1 run_package > "${TMP}/package.log" 2>&1 \
  || { cat "${TMP}/package.log" >&2; echo "FAIL: ALLOW_MISSING_RESULTS=1 did not package" >&2; exit 1; }
expect_failure 'dev-packaged build-info.json without a benchmark result' '.benchmark: missing' verify_packaged
expect_failure 'dev-packaged build-info.json with a failed correctness result' \
  '.correctness.passed: false, expected true' verify_packaged
echo 'All source pin, provenance, release-result and package-gate regression tests passed'
