#!/usr/bin/env bash
#
# Benchmark parity: run the SAME embedding workload against
#   (A) the packaged release in dist/            ("prebuilt")
#   (B) a fresh from-source llama-cpp-sys-2 build ("source")
# and assert the prebuilt path is within threshold of building locally. Writes
# $RESULTS/bench.json for package.sh to merge into build-info.json.
#
# Requires: build.sh already run (dist/ populated, crate cloned in .build/), and
# a pinned model available (SMOKE_MODEL, or run smoke/fixtures/fetch-model.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"

DIST="${DIST:-${ROOT}/dist}"
RESULTS="${RESULTS:-${ROOT}/.build/results}"
SRC_DIST="${ROOT}/.build/source-dist"
ITERS="${BENCH_ITERS:-200}"
THRESHOLD_PCT="${BENCH_REGRESS_THRESHOLD_PCT:-3}"   # prebuilt must be >= source * (1 - t%)

: "${SMOKE_MODEL:?set SMOKE_MODEL to the pinned GGUF (see smoke/fixtures/fetch-model.sh)}"
mkdir -p "${RESULTS}" "${SRC_DIST}/lib"
log() { printf '\033[1;34m[bench]\033[0m %s\n' "$*"; }

# --- Produce an INDEPENDENT from-source build (fresh clone + compile, same flags) --
# "prebuilt vs local from-source" means exactly that: we do NOT reuse build.sh's output.
# A separate clone + target dir forces a real recompile of llama.cpp; comparing it to the
# packaged dist/ validates that packaging/linking loses no performance (and records an
# absolute per-release number).
SRC_BUILD="${ROOT}/.build/source-build"
if [[ ! -d "${SRC_BUILD}/.git" ]]; then
  log "fresh clone for from-source baseline: ${CRATE_REPO} @ ${CRATE_TAG}"
  git clone --depth 1 --branch "${CRATE_TAG}" --recursive "${CRATE_REPO}" "${SRC_BUILD}"
fi
# Same N1 tuning as build.sh so the comparison is apples-to-apples.
patch_ggml_arm_arch "${SRC_BUILD}/llama-cpp-sys-2/build.rs" \
  || { echo "[bench] failed to patch GGML_CPU_ARM_ARCH" >&2; exit 1; }
export CFLAGS="${CFLAGS_TUNE} ${CFLAGS:-}"
export CXXFLAGS="${CFLAGS_TUNE} ${CXXFLAGS:-}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"
log "building from-source baseline (features: ${CRATE_FEATURES}, CFLAGS=${CFLAGS})"
( cd "${SRC_BUILD}" && cargo build --release -p llama-cpp-sys-2 --features "${CRATE_FEATURES}" )

# `-print -quit` (not `| head -n1`) to avoid SIGPIPE-failing find under `set -o pipefail`.
OUT_DIR="$(find "${SRC_BUILD}/target" -type d -name out -path '*release/build*llama-cpp-sys-2*' -print -quit)"
[[ -n "${OUT_DIR}" ]] || { echo "[bench] from-source OUT_DIR not found" >&2; exit 1; }
for lib in ${STATIC_LIBS}; do
  cp "$(find "${OUT_DIR}" -name "${lib}" -print -quit)" "${SRC_DIST}/lib/${lib}"
done
cp "$(find "${OUT_DIR}" -name bindings.rs -print -quit)" "${SRC_DIST}/bindings.rs"

run() {  # $1 = label, $2 = STATIC_LLAMA_DIR, $3 = result file
  log "running '$1' workload (${ITERS} iters)"
  STATIC_LLAMA_DIR="$2" BENCH_ITERS="${ITERS}" BENCH_RESULT="$3" \
    cargo run --release --manifest-path "${ROOT}/bench/Cargo.toml"
}

run "prebuilt" "${DIST}"     "${RESULTS}/bench.prebuilt.json"
run "source"   "${SRC_DIST}" "${RESULTS}/bench.source.json"

PRE="$(jq -r '.embeddings_per_sec' "${RESULTS}/bench.prebuilt.json")"
SRCV="$(jq -r '.embeddings_per_sec' "${RESULTS}/bench.source.json")"
RATIO="$(jq -n --argjson a "${PRE}" --argjson b "${SRCV}" '$a / $b')"
PASS="$(jq -n --argjson r "${RATIO}" --argjson t "${THRESHOLD_PCT}" '$r >= (1 - $t/100)')"

jq -n \
  --argjson prebuilt "$(cat "${RESULTS}/bench.prebuilt.json")" \
  --argjson source   "$(cat "${RESULTS}/bench.source.json")" \
  --argjson ratio    "${RATIO}" \
  --argjson thr      "${THRESHOLD_PCT}" \
  --argjson pass     "${PASS}" \
  '{prebuilt:$prebuilt, source:$source, prebuilt_to_source_ratio:$ratio,
    regress_threshold_pct:$thr, passed:$pass}' > "${RESULTS}/bench.json"

log "prebuilt=${PRE} eps, source=${SRCV} eps, ratio=${RATIO} (threshold -${THRESHOLD_PCT}%)"
if [[ "${PASS}" != "true" ]]; then
  echo "[bench] FAIL: prebuilt regressed beyond ${THRESHOLD_PCT}% vs from-source build" >&2
  exit 1
fi
log "PASS"
