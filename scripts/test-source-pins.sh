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

# --- Target profiles ------------------------------------------------------------------
# Selected by OS AND architecture: an arm64 Mac used to be taken for a Graviton2 host.
for case in Linux/aarch64=aarch64-graviton2 Linux/arm64=aarch64-graviton2 Linux/x86_64=x86_64-v3 \
            Linux/amd64=x86_64-v3 Darwin/arm64=aarch64-apple-darwin Darwin/x86_64= Darwin/i386= \
            FreeBSD/aarch64= FreeBSD/amd64=; do
  host="${case%%=*}" want="${case#*=}"
  got="$(host_target_profile "${host%/*}" "${host#*/}")"
  [[ "${got}" == "${want}" ]] \
    || { echo "FAIL: host ${host} selects profile '${got}', expected '${want:-none}'" >&2; exit 1; }
done
echo "PASS: selects the target profile by OS and architecture"
# Every profile sets every variable, with fixed, host-independent flags.
profile_vars="TARGET_PROFILE TARGET_OS TARGET_ARCH NATIVE_ARCH TARGET_TRIPLE CPU_BASELINE CPU_MARCH CPU_MCPU CPU_MTUNE CPU_PROFILE CFLAGS_TUNE GGML_ISA_DEFINES GGML_BACKEND_DEFINES MACOS_DEPLOYMENT_TARGET SYSTEM_LINK_LIBS ARTIFACT_VARIANT GENERIC_REF_MARCH GENERIC_REF_GGML_DEFINES"
for profile in ${SUPPORTED_TARGET_PROFILES} ${BUILD_ONLY_TARGET_PROFILES}; do
  for v in ${profile_vars}; do unset "${v}"; done
  set_target_profile "${profile}"
  for v in ${profile_vars}; do
    [[ -n "${!v+set}" ]] || { echo "FAIL: profile ${profile} does not set ${v}" >&2; exit 1; }
  done
  [[ "${TARGET_PROFILE}" == "${profile}" && "${TARGET_TRIPLE%%-*}" == "${TARGET_ARCH}" ]] \
    || { echo "FAIL: profile ${profile} sets TARGET_PROFILE=${TARGET_PROFILE} TARGET_TRIPLE=${TARGET_TRIPLE}" >&2; exit 1; }
  [[ "${CFLAGS_TUNE} ${GGML_ISA_DEFINES} ${GGML_BACKEND_DEFINES}" != *native* ]] \
    || { echo "FAIL: profile ${profile} has a host-derived (native) flag: ${CFLAGS_TUNE}" >&2; exit 1; }
done
case " ${SUPPORTED_TARGET_PROFILES} " in
  *" aarch64-apple-darwin "*) echo "FAIL: the build-only profile is listed as a release variant" >&2; exit 1 ;;
esac
set_target_profile aarch64-apple-darwin
[[ "${TARGET_OS}/${NATIVE_ARCH}/${TARGET_TRIPLE}" == macos/arm64/aarch64-apple-darwin \
   && "${CFLAGS_TUNE}" == "-O3 -mcpu=apple-m1" && -z "${CPU_MARCH}${CPU_MTUNE}" \
   && "${GGML_BACKEND_DEFINES}" == "GGML_METAL=OFF GGML_ACCELERATE=OFF" \
   && "${MACOS_DEPLOYMENT_TARGET}" == 11.0 && "${SYSTEM_LINK_LIBS}" == "c++" ]] \
  || { echo "FAIL: aarch64-apple-darwin profile drifted: ${CFLAGS_TUNE} / ${GGML_BACKEND_DEFINES} / ${MACOS_DEPLOYMENT_TARGET} / ${SYSTEM_LINK_LIBS}" >&2; exit 1; }
for profile in aarch64-graviton2 x86_64-v3; do
  set_target_profile "${profile}"
  [[ "${TARGET_OS}" == linux && "${NATIVE_ARCH}" == "${TARGET_ARCH}" && -z "${CPU_MCPU}${GGML_BACKEND_DEFINES}${MACOS_DEPLOYMENT_TARGET}" \
     && "${SYSTEM_LINK_LIBS}" == "stdc++ pthread m dl" ]] \
    || { echo "FAIL: Linux profile ${profile} changed: os=${TARGET_OS} mcpu=${CPU_MCPU} libs=${SYSTEM_LINK_LIBS}" >&2; exit 1; }
done
echo "PASS: every profile is complete and fixed; Linux profiles unchanged; macOS is build-only, -mcpu=apple-m1, CPU-only"
for profile in ${SUPPORTED_TARGET_PROFILES}; do assert_release_profile "${profile}"; done
expect_failure 'the build-only profile as a release profile' \
  'target profile aarch64-apple-darwin is build-only, not a release variant' assert_release_profile aarch64-apple-darwin
expect_failure 'an unknown release profile' "'bogus' is not a release target profile" assert_release_profile bogus
expect_failure 'an unknown target profile' "unsupported target profile 'bogus'" set_target_profile bogus

# --- Portable checksums and archive harvesting ---------------------------------------
: >"${TMP}/empty"
[[ "$(sha256_file "${TMP}/empty")" == e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]] \
  || { echo "FAIL: sha256_file of an empty file" >&2; exit 1; }
echo "PASS: sha256_file"
# A malformed pin used to verify anything under macOS's sha256sum -c; it fails before any
# download.
for bad_pin in "" "0000" "${EMBEDDINGGEMMA_MODEL_SHA256}x" "$(tr a-f A-F <<<"${EMBEDDINGGEMMA_MODEL_SHA256}")"; do
  expect_failure "malformed pinned SHA-256 '${bad_pin}'" 'is not 64 lowercase hex digits' \
    fetch_pinned_model "https://example.invalid/model.gguf" "${bad_pin}" "${TMP}/model.gguf"
done
cp "${TMP}/empty" "${TMP}/cached.gguf"
fetch_pinned_model "https://example.invalid/never-fetched.gguf" \
  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 "${TMP}/cached.gguf"
echo "PASS: fetch_pinned_model reuses a verified copy without downloading"
# harvest_sys_outputs: the installed archive set must equal STATIC_LIBS exactly.
stage_out_dir() {
  local lib
  rm -rf "${TMP}/out" "${TMP}/harvest"; mkdir -p "${TMP}/out/lib"
  for lib in ${STATIC_LIBS}; do : >"${TMP}/out/lib/${lib}"; done
  printf 'extern "C" {\n    pub fn llama_encode(ctx: *mut llama_context) -> i32;\n}\n' >"${TMP}/out/bindings.rs"
}
stage_out_dir
harvest_sys_outputs "${TMP}/out" "${TMP}/harvest"
for lib in ${STATIC_LIBS}; do
  [[ -f "${TMP}/harvest/lib/${lib}" ]] || { echo "FAIL: harvest did not copy ${lib}" >&2; exit 1; }
done
echo "PASS: harvests exactly STATIC_LIBS + bindings.rs"
stage_out_dir; rm "${TMP}/out/lib/libggml-cpu.a"
expect_failure 'a missing installed archive' 'installed archive set differs from STATIC_LIBS' \
  harvest_sys_outputs "${TMP}/out" "${TMP}/harvest"
stage_out_dir; : >"${TMP}/out/lib/libggml-metal.a"
expect_failure 'an extra installed archive (e.g. a Metal backend)' 'installed archive set differs from STATIC_LIBS' \
  harvest_sys_outputs "${TMP}/out" "${TMP}/harvest"
source "${ROOT}/scripts/config.env"

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

  if [[ "${type}" == tag ]]; then
    # The ref is the pinned name and peels to the right commit, but its tag object was
    # created as another tag.
    pinned_object="$(git -C "${LLAMA_CPP_DIR}" rev-parse "refs/tags/${LLAMA_CPP_TAG}")"
    git -C "${LLAMA_CPP_DIR}" tag -a impostor -m impostor
    git -C "${LLAMA_CPP_DIR}" update-ref "refs/tags/${LLAMA_CPP_TAG}" "$(git -C "${LLAMA_CPP_DIR}" rev-parse refs/tags/impostor)"
    expect_failure 'annotated tag object naming another tag' \
      "llama.cpp tag object names 'impostor', expected ${LLAMA_CPP_TAG}" verify_llama_cpp_source
    git -C "${LLAMA_CPP_DIR}" update-ref "refs/tags/${LLAMA_CPP_TAG}" "${pinned_object}"
    git -C "${LLAMA_CPP_DIR}" tag -d impostor >/dev/null
    verify_llama_cpp_source
  fi

  # The tag moves away from the otherwise correct HEAD.
  git -C "${LLAMA_CPP_DIR}" commit --allow-empty --quiet -m other
  other="$(git -C "${LLAMA_CPP_DIR}" rev-parse HEAD)"
  git -C "${LLAMA_CPP_DIR}" switch --quiet --detach "${EXPECTED_LLAMA_CPP_COMMIT}"
  if [[ "${type}" == tag ]]; then
    git -C "${LLAMA_CPP_DIR}" tag -f -a "${LLAMA_CPP_TAG}" -m moved "${other}" >/dev/null
  else
    git -C "${LLAMA_CPP_DIR}" update-ref "refs/tags/${LLAMA_CPP_TAG}" "${other}"
  fi
  expect_failure "moved ${type} tag despite correct HEAD" "llama.cpp tag ${LLAMA_CPP_TAG} -> '${other}'" \
    verify_llama_cpp_source
done

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

# Pin cases for the smoke results: "<jq alteration of a packaged build-info.json>|<diagnostic>".
# Each changes one pinned field, so a v5 result (no host_logits) or a pooled run that still
# exposed logits fails, as does a control run that lost generation logits.
result_pin_cases=(
  '.smoke.host_logits=true|.smoke.host_logits: true, expected false'
  'del(.smoke.host_logits)|.smoke.host_logits: null, expected false'
  '.embeddinggemma_smoke.model_id="other/model"|.embeddinggemma_smoke.model_id: "other/model"'
  '.embeddinggemma_smoke.model_sha256="wrong"|.embeddinggemma_smoke.model_sha256: "wrong"'
  '.embeddinggemma_smoke.n_embd=768|.embeddinggemma_smoke.n_embd: 768, expected 512'
  '.embeddinggemma_smoke.n_embd_out=512|.embeddinggemma_smoke.n_embd_out: 512, expected 768'
  '.embeddinggemma_smoke.host_logits=true|.embeddinggemma_smoke.host_logits: true, expected false'
  'del(.embeddinggemma_smoke.host_logits)|.embeddinggemma_smoke.host_logits: null, expected false'
  '.logits_smoke.model_id="other/model"|.logits_smoke.model_id: "other/model"'
  '.logits_smoke.model_sha256="wrong"|.logits_smoke.model_sha256: "wrong"'
  '.logits_smoke.host_logits.generation=false|.logits_smoke.host_logits: {"generation":false'
  '.logits_smoke.host_logits.embeddings_mean=true|.logits_smoke.host_logits: {"generation":true,"embeddings_none":true,"embeddings_mean":true,'
  '.logits_smoke.host_logits.embeddings_mean_set_off=false|.logits_smoke.host_logits: {"generation":true,"embeddings_none":true,"embeddings_mean":false,"embeddings_mean_set_off":false,'
  'del(.logits_smoke.host_logits.embeddings_mean_set_on)|.logits_smoke.host_logits: {"generation":true,"embeddings_none":true,"embeddings_mean":false,"embeddings_mean_set_off":true,"embeddings_last":false,"embeddings_cls":false}, expected'
  '.logits_smoke.host_logits.embeddings_last=true|"embeddings_mean_set_on":false,"embeddings_last":true,"embeddings_cls":false}, expected'
  '.logits_smoke.host_logits.embeddings_cls=true|"embeddings_last":false,"embeddings_cls":true}, expected'
  'del(.logits_smoke.host_logits)|.logits_smoke.host_logits: null'
)

# Synthetic build-info.json per profile, from the canonical pins; never a production artifact.
# The raw form mirrors build.sh output: null result placeholders, no embeddinggemma_smoke or
# logits_smoke. The packaged form adds the five passing results package.sh merges.
source "${ROOT}/scripts/config.env"
# The Git object type the pin does not name, so the tag_type case below is a mismatch
# whichever kind of tag config.env pins.
if [[ "${EXPECTED_LLAMA_CPP_TAG_TYPE}" == tag ]]; then wrong_tag_type=commit; else wrong_tag_type=tag; fi
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
    --arg ls_id "${LOGITS_SMOKE_MODEL_ID}" --arg ls_sha "${LOGITS_SMOKE_MODEL_SHA256}" \
    --argjson ls_logits "${LOGITS_SMOKE_HOST_LOGITS}" \
    '.smoke={passed:true,host_logits:false} | .benchmark={passed:true} | .correctness={passed:true}
     | .embeddinggemma_smoke={passed:true,model_id:$id,model_sha256:$sha,n_embd:$hidden,
                              n_embd_out:$output,host_logits:false}
     | .logits_smoke={passed:true,model_id:$ls_id,model_sha256:$ls_sha,host_logits:$ls_logits}' \
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
      ".llama_cpp.tag_type=\"${wrong_tag_type}\""
    expect_verify_rejects "${mode}" "${profile}" "${packaged}" 'provenance mismatch: llama_cpp.embedded_version' \
      '.llama_cpp.embedded_version="99.0.0"'
    expect_verify_rejects "${mode}" "${profile}" "${packaged}" 'provenance mismatch: llama_cpp.commit' \
      '.llama_cpp.commit="wrong"'
    expect_verify_rejects "${mode}" "${profile}" "${packaged}" 'provenance mismatch: host.native_build' \
      '.host.native_build=false'
  done

  # Packaged mode requires every result, passing; raw mode still rejects a failed one.
  for result in smoke embeddinggemma_smoke logits_smoke benchmark correctness; do
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

  # The smoke results must match their pins in both modes.
  for case in "${result_pin_cases[@]}"; do
    IFS='|' read -r alteration diagnostic <<<"${case}"
    for mode in packaged raw; do
      expect_verify_rejects "${mode}" "${profile}" "${packaged}" "${diagnostic}" "${alteration}"
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
  for result in bench correctness; do
    echo '{"passed":true}' > "${package_dir}/results/${result}.json"
  done
  echo '{"passed":true,"host_logits":false}' > "${package_dir}/results/smoke.json"
  jq -n --arg id "${EMBEDDINGGEMMA_MODEL_ID}" --arg sha "${EMBEDDINGGEMMA_MODEL_SHA256}" \
    --argjson hidden "${EMBEDDINGGEMMA_HIDDEN_DIM}" --argjson output "${EMBEDDINGGEMMA_OUTPUT_DIM}" \
    '{passed:true,n_embd:$hidden,n_embd_out:$output,n_tokens:15,l2_norm:1.0,host_logits:false,
      model_id:$id,model_sha256:$sha}' > "${package_dir}/results/embeddinggemma-smoke.json"
  jq -n --arg id "${LOGITS_SMOKE_MODEL_ID}" --arg sha "${LOGITS_SMOKE_MODEL_SHA256}" \
    --argjson logits "${LOGITS_SMOKE_HOST_LOGITS}" \
    '{passed:true,n_vocab:512,n_tokens:15,host_logits:$logits,max_logit_delta:0,
      model_id:$id,model_sha256:$sha}' > "${package_dir}/results/logits-smoke.json"
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
results_map=(smoke:smoke embeddinggemma-smoke:embeddinggemma_smoke logits-smoke:logits_smoke
             bench:benchmark correctness:correctness)

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
# The same pin cases, applied to the result file package.sh merges as that key.
for case in "${result_pin_cases[@]}"; do
  IFS='|' read -r alteration diagnostic <<<"${case}"
  key="$(sed -E 's/^(del\()?\.([a-z_]+)\..*/\2/' <<<"${alteration}")" result=""
  for pair in "${results_map[@]}"; do [[ "${pair#*:}" == "${key}" ]] && result="${pair%%:*}"; done
  [[ -n "${result}" ]] || { echo "FAIL: no result file for pin case ${alteration}" >&2; exit 1; }
  stage_package
  alter_result "${result}" "${alteration/.${key}/}"
  expect_package_rejects "${result} result ${alteration/.${key}/}" "${diagnostic}"
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
