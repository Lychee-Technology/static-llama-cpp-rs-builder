#!/usr/bin/env bash
#
# Numerical embedding-correctness gate. Proves the PACKAGED archives compute the RIGHT
# embeddings (not just finite/fast), across the pooling/attention modes and diverse
# inputs consumers use. Writes $RESULTS/correctness.json for package.sh to merge + gate.
#
# Three axes, none circular:
#   §2 tuned-vs-generic  Build a second archive set with GENERIC flags on the SAME host —
#                        aarch64: -O3 -march=armv8-a; x86_64: -O3 -march=x86-64 with every
#                        ggml ISA option OFF (scalar/SSE2 kernels) — and require cosine >=
#                        0.999 vs the production dist/. Divergence is purely the tuning/
#                        codegen flags — exactly the v0.1.151-1 failure class. No external
#                        reference. The generic set is a NON-PRODUCTION correctness reference
#                        only: it is not an artifact, never published, not part of the support
#                        matrix, and does not mean older CPUs (e.g. pre-x86-64-v3) are supported.
#   §1 golden parity     Require cosine >= 0.98 vs committed FP32 golden vectors produced
#                        offline by scripts/gen-golden.py (the PyTorch model via
#                        sentence-transformers) — independent of the GGUF/llama.cpp path,
#                        mirroring the downstream GGUF-vs-FP32 benchmark. IQ4_NL vs FP32,
#                        so the threshold allows quantization error. Skipped (recorded,
#                        non-fatal) until golden.tsv has data rows.
#   §4 self-consistency  Determinism / batch-invariance / thread-invariance / semantic
#                        sanity on the tuned build (reference-free).
#
# Runs against a pinned REFERENCE model (§1/§2/§4) and, additionally, the deployed
# SMOKE_MODEL (§2/§4 — the actual shipped quant, the direct v0.1.151-1 check).
#
# Requires: build.sh already run (dist/ populated).  Mirrors scripts/bench.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"
LIB_TAG=correct
source "${ROOT}/scripts/lib.sh"
# Same native-host / build-input gates as build.sh (the generic baseline is compiled too); before any side effect.
assert_native_host
assert_no_build_env_overrides

DIST="${DIST:-${ROOT}/dist}"
RESULTS="${RESULTS:-${ROOT}/.build/results}"
FIX="${ROOT}/correctness/fixtures"
INPUTS="${FIX}/inputs.tsv"
GOLDEN="${FIX}/golden.tsv"
GENERIC_BUILD="${ROOT}/.build/generic-build"
GENERIC_DIST="${ROOT}/.build/generic-dist"
REF_MODEL="${ROOT}/.build/correctness-ref-model.gguf"

# Thresholds.
TUNED_GENERIC_MIN_COS="${TUNED_GENERIC_MIN_COS:-0.999}"   # §2 tuned vs generic (same host)
GOLDEN_MIN_COS="${GOLDEN_MIN_COS:-0.98}"                   # §1 IQ4_NL(4-bit) vs FP32 — justified in CONTRACT.md
if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
  HW_COVERAGE="neoverse-n2 only; graviton2/n1 not yet gated"
else
  # Only the CPU this ran on is covered (recorded verbatim; no wider claim).
  HW_COVERAGE="x86_64 (x86-64-v3): ${HOST_CPU_MODEL:-unknown CPU} only"
fi

mkdir -p "${RESULTS}"
log() { printf '\033[1;34m[correct]\033[0m %s\n' "$*"; }

CARGO="cargo run --release --manifest-path ${ROOT}/correctness/Cargo.toml"

# --- 1. Fetch the pinned reference model (fail-closed, verify sha) ------------------
source "${FIX}/reference-model.env"
: "${CORRECTNESS_MODEL_URL:?set CORRECTNESS_MODEL_URL in correctness/fixtures/reference-model.env}"
: "${CORRECTNESS_MODEL_SHA256:?set CORRECTNESS_MODEL_SHA256 in correctness/fixtures/reference-model.env}"
verify_ref() { echo "${CORRECTNESS_MODEL_SHA256}  ${REF_MODEL}" | sha256sum -c - >/dev/null 2>&1; }
if [[ ! -f "${REF_MODEL}" ]] || ! verify_ref; then
  log "fetching reference model: ${CORRECTNESS_MODEL_URL}"
  curl -fSL "${CORRECTNESS_MODEL_URL}" -o "${REF_MODEL}"
  verify_ref || { echo "[correct] reference model sha256 mismatch" >&2; exit 1; }
fi

# --- 2. Build the GENERIC reference archive set from source -------------------------
# NON-PRODUCTION: built only to compare against; never packaged, published or supported.
# A SEPARATE pristine checkout of the SAME pinned sources (bench.sh's .build/source-build
# may be patched), with CFLAGS pinning the profile's generic -march=${GENERIC_REF_MARCH} on
# every TU. Verified below, so the baseline cannot silently be tuned.
#   aarch64: we do NOT call patch_ggml_arm_arch, so ggml keeps the crate's default armv8-a
#            CPU kernels (no fp16/dotprod/mtune).
#   x86_64:  GENERIC_REF_GGML_DEFINES turns every ggml ISA option OFF, so ggml adds no
#            -msse4.2/-mavx*/... and the kernels are plain x86-64 (SSE2).
prepare_crate_source "${GENERIC_BUILD}"
n_default="$(grep -cF -- "${GGML_ARM_ARCH_DEFAULT}" "${GENERIC_BUILD}/llama-cpp-sys-2/build.rs" || true)"
[[ "${n_default}" == 1 ]] \
  || { echo "[correct] generic build.rs is not pristine (${n_default}x '${GGML_ARM_ARCH_DEFAULT}')" >&2; exit 1; }
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"
GENERIC_FLAGS="-O3 -march=${GENERIC_REF_MARCH}"
read -r -a GEN_DEFS <<<"${GENERIC_REF_GGML_DEFINES}"
log "from-source GENERIC (non-production reference) build -> $(basename "${GENERIC_DIST}") (CFLAGS: ${GENERIC_FLAGS}${GENERIC_REF_GGML_DEFINES:+; ${GENERIC_REF_GGML_DEFINES}})"
rm -rf "${GENERIC_BUILD}/target-generic" "${GENERIC_DIST}"
( export CFLAGS="${GENERIC_FLAGS}"
  export CXXFLAGS="${GENERIC_FLAGS}"
  export CMAKE_EXPORT_COMPILE_COMMANDS=ON
  export CARGO_TARGET_DIR="${GENERIC_BUILD}/target-generic"
  build_sys_crate "${GENERIC_BUILD}" ${GEN_DEFS[@]+"${GEN_DEFS[@]}"} )
GEN_OUT="$(find_sys_out_dir "${GENERIC_BUILD}/target-generic")"
GEN_CACHE="${GEN_OUT}/build/CMakeCache.txt"
gen_fail() { echo "[correct] generic baseline is not generic: $*" >&2; exit 1; }
if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
  gen_arch="$(cmake_cache_get "${GEN_CACHE}" GGML_CPU_ARM_ARCH)" \
    || { echo "[correct] generic CMake cache has no GGML_CPU_ARM_ARCH" >&2; exit 1; }
  gen_dot="$(cmake_cache_get "${GEN_CACHE}" HAVE_DOTPROD)" \
    || { echo "[correct] generic CMake cache has no HAVE_DOTPROD probe" >&2; exit 1; }
  [[ "${gen_arch}" == "armv8-a" && ( -z "${gen_dot}" || "${gen_dot}" == 0 ) ]] \
    || gen_fail "GGML_CPU_ARM_ARCH='${gen_arch}', HAVE_DOTPROD='${gen_dot}'"
else
  # CMake: GGML_NATIVE and every ggml ISA option OFF.
  for d in GGML_NATIVE=OFF "${GEN_DEFS[@]}"; do
    got="$(cmake_cache_get "${GEN_CACHE}" "${d%%=*}")" || gen_fail "CMake cache has no ${d%%=*}"
    [[ "${got}" == "${d#*=}" ]] || gen_fail "CMake ${d%%=*}='${got}', expected '${d#*=}'"
  done
  # Every C/C++ TU: exactly -march=${GENERIC_REF_MARCH}, no -mtune, no ISA -m flag (-m64 only),
  # and an effective ISA of plain x86-64 (no SSE3+ / AVX feature macros).
  GEN_CC_JSON="$(find "${GEN_OUT}" -name compile_commands.json -print -quit)"
  [[ -n "${GEN_CC_JSON}" ]] || gen_fail "compile_commands.json not found"
  declare -A GEN_SETS=(); gen_tus=0
  while IFS= read -r cmd; do
    grep -qiE -- '-c( |$)' <<<"${cmd}" && grep -qiE -- '\.(c|cc|cpp|cxx|c\+\+)( |$|")' <<<"${cmd}" || continue
    gen_tus=$((gen_tus+1))
    marches="$(grep -oE -- '-march=[^ ]+' <<<"${cmd}" | sort -u | tr '\n' ' ')"
    [[ "${marches}" == "-march=${GENERIC_REF_MARCH} " ]] || gen_fail "TU with -march '${marches}'"
    extra_m="$(grep -oE -- '(^| )-m[^ ]+' <<<"${cmd}" | sed 's/^ //' | grep -vxE -- "-m64|-march=${GENERIC_REF_MARCH}" | tr '\n' ' ' || true)"
    [[ -z "${extra_m}" ]] || gen_fail "TU with extra -m flags '${extra_m}'"
    GEN_SETS["${cmd%% *} $(grep -oE -- '(^| )(-m[^ ]+|--target=[^ ]+)' <<<"${cmd}" | tr -d '\n' | sed 's/^ //')"]=1
  done < <(compile_commands_lines "${GEN_CC_JSON}")
  [[ "${gen_tus}" -gt 0 ]] || gen_fail "no C/C++ TUs in compile_commands.json"
  for k in "${!GEN_SETS[@]}"; do
    read -r -a kv <<<"${k}"
    why="$(x86_isa_macro_check baseline "${kv[@]}")" || gen_fail "'${k}': ${why}"
  done
  log "generic reference verified: ${gen_tus} C/C++ TUs at -O3 -march=${GENERIC_REF_MARCH}, ggml ISA options OFF, effective ISA plain x86-64"
fi
harvest_sys_outputs "${GEN_OUT}" "${GENERIC_DIST}"

# --- helpers (grouped by STATIC_LLAMA_DIR to minimise crate recompiles) -------------
emit() {  # model, static_dir, out_emit
  CORRECTNESS_MODE=emit CORRECTNESS_MODEL="$1" STATIC_LLAMA_DIR="$2" \
    CORRECTNESS_INPUTS="${INPUTS}" CORRECTNESS_EMIT="$3" ${CARGO}
}
selfcheck() {  # model, static_dir, out_result  (may exit 1 => caller uses set +e)
  CORRECTNESS_MODE=selfcheck CORRECTNESS_MODEL="$1" STATIC_LLAMA_DIR="$2" \
    CORRECTNESS_INPUTS="${INPUTS}" CORRECTNESS_RESULT="$3" ${CARGO}
}
compare() {  # a_emit, b_emit, threshold, out_result  (may exit 1)
  CORRECTNESS_MODE=compare STATIC_LLAMA_DIR="${GENERIC_DIST}" \
    CORRECTNESS_A="$1" CORRECTNESS_B="$2" CORRECTNESS_THRESHOLD="$3" CORRECTNESS_RESULT="$4" ${CARGO}
}

E_TUNED_REF="${RESULTS}/emit.ref.tuned.tsv"
E_GEN_REF="${RESULTS}/emit.ref.generic.tsv"
E_TUNED_SMK="${RESULTS}/emit.smoke.tuned.tsv"
E_GEN_SMK="${RESULTS}/emit.smoke.generic.tsv"

HAVE_SMOKE=0
[[ -n "${SMOKE_MODEL:-}" && -f "${SMOKE_MODEL:-}" ]] && HAVE_SMOKE=1

# The FP32 golden (§1) is tied to the pinned reference model. To guarantee golden parity
# ALSO covers the DEPLOYED model (issue #4), require the deployed SMOKE_MODEL to be
# byte-identical to the reference GGUF — then the reference-vs-golden check authoritatively
# covers the deployed model too (no bug specific to SMOKE_MODEL can ship unchecked). For
# jina nano, reference == deployed == IQ4_NL. If you deploy a different quant, either pin
# SMOKE_MODEL to the reference GGUF, or generate a golden for the deployed model.
if [[ "${HAVE_SMOKE}" == 1 ]]; then
  SMK_SHA="$(sha256sum "${SMOKE_MODEL}" | awk '{print $1}')"
  if [[ "${SMK_SHA}" != "${CORRECTNESS_MODEL_SHA256}" ]]; then
    echo "[correct] FAIL: deployed SMOKE_MODEL sha ${SMK_SHA} != golden reference sha ${CORRECTNESS_MODEL_SHA256}." >&2
    echo "[correct]   The FP32 golden covers the reference model; the deployed model would ship golden-unchecked." >&2
    echo "[correct]   Pin SMOKE_MODEL to correctness/fixtures/reference-model.env's GGUF, or add a deployed golden." >&2
    exit 1
  fi
  log "deployed SMOKE_MODEL == golden reference (sha ${SMK_SHA:0:12}…) — golden covers the deployed model"
fi

# Emit + selfcheck against the TUNED archives first (all STATIC_LLAMA_DIR=dist).
log "emit/selfcheck against tuned dist/"
emit "${REF_MODEL}" "${DIST}" "${E_TUNED_REF}"
[[ "${HAVE_SMOKE}" == 1 ]] && emit "${SMOKE_MODEL}" "${DIST}" "${E_TUNED_SMK}"

# selfcheck may exit 1 (a real gate trip) — capture, keep going, gate at the end.
set +e
selfcheck "${REF_MODEL}" "${DIST}" "${RESULTS}/correctness.self.ref.json"
[[ "${HAVE_SMOKE}" == 1 ]] && selfcheck "${SMOKE_MODEL}" "${DIST}" "${RESULTS}/correctness.self.smoke.json"
set -e

# Emit against the GENERIC archives (all STATIC_LLAMA_DIR=generic-dist).
log "emit against generic build"
emit "${REF_MODEL}" "${GENERIC_DIST}" "${E_GEN_REF}"
[[ "${HAVE_SMOKE}" == 1 ]] && emit "${SMOKE_MODEL}" "${GENERIC_DIST}" "${E_GEN_SMK}"

# --- 3/4. Comparisons (may exit 1) -------------------------------------------------
set +e
compare "${E_TUNED_REF}" "${E_GEN_REF}" "${TUNED_GENERIC_MIN_COS}" "${RESULTS}/correctness.generic.ref.json"
[[ "${HAVE_SMOKE}" == 1 ]] && compare "${E_TUNED_SMK}" "${E_GEN_SMK}" "${TUNED_GENERIC_MIN_COS}" "${RESULTS}/correctness.generic.smoke.json"

# §1 golden: only if golden.tsv has data rows (non-comment, non-blank).
# grep -c prints "0" AND exits 1 when there are no matches, so capture with `|| true`
# (NOT `|| echo 0`, which would append a second line and break the arithmetic test).
GOLDEN_STATUS="not_generated"
GOLDEN_ROWS="$(grep -cvE '^[[:space:]]*(#.*)?$' "${GOLDEN}" 2>/dev/null || true)"
if [[ "${GOLDEN_ROWS:-0}" -gt 0 ]]; then
  GOLDEN_STATUS="checked"
  compare "${E_TUNED_REF}" "${GOLDEN}" "${GOLDEN_MIN_COS}" "${RESULTS}/correctness.golden.ref.json"
else
  log "golden.tsv has no data rows — §1 golden parity SKIPPED (run scripts/gen-golden.sh). §2/§4 still gate."
fi
set -e

# --- 5. Combine into correctness.json + gate ---------------------------------------
read_json() { [[ -f "$1" ]] && cat "$1" || echo 'null'; }
pass_of()  { jq -r '.passed // false' <<<"$(read_json "$1")"; }

SELF_REF="$(read_json "${RESULTS}/correctness.self.ref.json")"
GEN_REF="$(read_json "${RESULTS}/correctness.generic.ref.json")"
SELF_SMK="null"; GEN_SMK="null"; GOLDEN_JSON="null"
if [[ "${HAVE_SMOKE}" == 1 ]]; then
  SELF_SMK="$(read_json "${RESULTS}/correctness.self.smoke.json")"
  GEN_SMK="$(read_json "${RESULTS}/correctness.generic.smoke.json")"
fi
[[ "${GOLDEN_STATUS}" == "checked" ]] && GOLDEN_JSON="$(read_json "${RESULTS}/correctness.golden.ref.json")"

# Overall pass = every REQUIRED sub-check passed. Golden only counts when checked.
all_pass=true
required=("${RESULTS}/correctness.self.ref.json" "${RESULTS}/correctness.generic.ref.json")
[[ "${HAVE_SMOKE}" == 1 ]] && required+=("${RESULTS}/correctness.self.smoke.json" "${RESULTS}/correctness.generic.smoke.json")
[[ "${GOLDEN_STATUS}" == "checked" ]] && required+=("${RESULTS}/correctness.golden.ref.json")
for f in "${required[@]}"; do
  [[ "$(pass_of "$f")" == "true" ]] || all_pass=false
done

jq -n \
  --argjson passed        "${all_pass}" \
  --arg     coverage      "${HW_COVERAGE}" \
  --arg     profile       "${TARGET_PROFILE}" \
  --arg     arch          "${TARGET_ARCH}" \
  --arg     prod_flags    "${CFLAGS_TUNE}" \
  --arg     gen_flags     "${GENERIC_FLAGS}" \
  --arg     gen_defs      "${GENERIC_REF_GGML_DEFINES}" \
  --argjson gen_cos_min   "${TUNED_GENERIC_MIN_COS}" \
  --argjson golden_cos_min "${GOLDEN_MIN_COS}" \
  --arg     golden_status "${GOLDEN_STATUS}" \
  --argjson self_ref      "${SELF_REF}" \
  --argjson self_smoke    "${SELF_SMK}" \
  --argjson gen_ref       "${GEN_REF}" \
  --argjson gen_smoke     "${GEN_SMK}" \
  --argjson golden        "${GOLDEN_JSON}" \
  '{passed:$passed, hardware_coverage:$coverage, target_profile:$profile, architecture:$arch,
    tuned_vs_generic:{min_cosine_threshold:$gen_cos_min, production_flags:$prod_flags,
                      generic_reference:{flags:$gen_flags,
                                         ggml_options:($gen_defs | split(" ") | map(select(. != ""))),
                                         production:false, published:false, supported:false,
                                         note:"non-production correctness reference only; not an artifact, not published, not part of the support matrix"},
                      reference:$gen_ref, deployed:$gen_smoke},
    golden_parity:{status:$golden_status, min_cosine_threshold:$golden_cos_min, reference:$golden},
    self_consistency:{reference:$self_ref, deployed:$self_smoke}}' \
  > "${RESULTS}/correctness.json"

log "wrote ${RESULTS}/correctness.json (passed=${all_pass}, golden=${GOLDEN_STATUS})"
if [[ "${all_pass}" != "true" ]]; then
  echo "[correct] FAIL: one or more correctness checks did not pass (see correctness.json)" >&2
  exit 1
fi
log "PASS"
