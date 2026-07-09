#!/usr/bin/env bash
#
# Numerical embedding-correctness gate. Proves the PACKAGED archives compute the RIGHT
# embeddings (not just finite/fast), across the pooling/attention modes and diverse
# inputs consumers use. Writes $RESULTS/correctness.json for package.sh to merge + gate.
#
# Three axes, none circular:
#   §2 tuned-vs-generic  Build a second archive set with GENERIC -march=armv8-a (scalar/
#                        generic kernels) on the SAME host and require cosine >= 0.999 vs
#                        the tuned dist/. Divergence is purely the tuning/codegen flags —
#                        exactly the v0.1.151-1 failure class. No external reference.
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
HW_COVERAGE="neoverse-n2 only; graviton2/n1 not yet gated"

mkdir -p "${RESULTS}" "${GENERIC_DIST}/lib"
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

# --- 2. Build the GENERIC (-march=armv8-a) archive set from source ------------------
# A SEPARATE pristine clone (bench.sh's .build/source-build gets patched to dotprod).
# We do NOT call patch_ggml_arm_arch, so ggml keeps its default armv8-a CPU kernels; and
# CFLAGS pins generic -march=armv8-a (no fp16/dotprod/mtune) on every TU.
if [[ ! -d "${GENERIC_BUILD}/.git" ]]; then
  log "fresh clone for generic baseline: ${CRATE_REPO} @ ${CRATE_TAG}"
  git clone --depth 1 --branch "${CRATE_TAG}" --recursive "${CRATE_REPO}" "${GENERIC_BUILD}"
fi
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"
log "from-source GENERIC build -> $(basename "${GENERIC_DIST}") (CFLAGS: -O3 -march=armv8-a)"
( cd "${GENERIC_BUILD}"
  export CFLAGS="-O3 -march=armv8-a"
  export CXXFLAGS="-O3 -march=armv8-a"
  export CARGO_TARGET_DIR="${GENERIC_BUILD}/target-generic"
  cargo build --release -p llama-cpp-sys-2 ${CRATE_FEATURES:+--features "${CRATE_FEATURES}"} )
GEN_OUT="$(find "${GENERIC_BUILD}/target-generic" -type d -name out -path '*release/build*llama-cpp-sys-2*' -print -quit)"
[[ -n "${GEN_OUT}" ]] || { echo "[correct] generic OUT_DIR not found" >&2; exit 1; }
for lib in ${STATIC_LIBS}; do
  cp "$(find "${GEN_OUT}" -name "${lib}" -print -quit)" "${GENERIC_DIST}/lib/${lib}"
done
cp "$(find "${GEN_OUT}" -name bindings.rs -print -quit)" "${GENERIC_DIST}/bindings.rs"

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
  --argjson gen_cos_min   "${TUNED_GENERIC_MIN_COS}" \
  --argjson golden_cos_min "${GOLDEN_MIN_COS}" \
  --arg     golden_status "${GOLDEN_STATUS}" \
  --argjson self_ref      "${SELF_REF}" \
  --argjson self_smoke    "${SELF_SMK}" \
  --argjson gen_ref       "${GEN_REF}" \
  --argjson gen_smoke     "${GEN_SMK}" \
  --argjson golden        "${GOLDEN_JSON}" \
  '{passed:$passed, hardware_coverage:$coverage,
    tuned_vs_generic:{min_cosine_threshold:$gen_cos_min, reference:$gen_ref, deployed:$gen_smoke},
    golden_parity:{status:$golden_status, min_cosine_threshold:$golden_cos_min, reference:$golden},
    self_consistency:{reference:$self_ref, deployed:$self_smoke}}' \
  > "${RESULTS}/correctness.json"

log "wrote ${RESULTS}/correctness.json (passed=${all_pass}, golden=${GOLDEN_STATUS})"
if [[ "${all_pass}" != "true" ]]; then
  echo "[correct] FAIL: one or more correctness checks did not pass (see correctness.json)" >&2
  exit 1
fi
log "PASS"
