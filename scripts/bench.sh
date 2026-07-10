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

# --- One INDEPENDENT from-source clone (fresh), reused for every variant -----------
# "prebuilt vs from-source" means exactly that: we do NOT reuse build.sh's output. A
# separate clone + per-variant CARGO_TARGET_DIR forces a real recompile of llama.cpp;
# comparing to the packaged dist/ validates that packaging/linking loses no performance.
CFLAGS_ENV="${CFLAGS:-}"; CXXFLAGS_ENV="${CXXFLAGS:-}"   # inherited extras, appended after tuning
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"

SRC_BUILD="${ROOT}/.build/source-build"
if [[ ! -d "${SRC_BUILD}/.git" ]]; then
  log "fresh clone for from-source baseline: ${CRATE_REPO} @ ${CRATE_TAG}"
  git clone --depth 1 --branch "${CRATE_TAG}" --recursive "${CRATE_REPO}" "${SRC_BUILD}"
fi
# Same N1 tuning as build.sh so the comparison is apples-to-apples.
patch_ggml_arm_arch "${SRC_BUILD}/llama-cpp-sys-2/build.rs" \
  || { echo "[bench] failed to patch GGML_CPU_ARM_ARCH" >&2; exit 1; }

# Build llama-cpp-sys-2 from source and harvest its .a + bindings into a dist-like dir.
# $1 = extra CFLAGS (e.g. -fprofile-use=...), $2 = CARGO_TARGET_DIR, $3 = dest dir.
build_and_harvest() {
  local extra="$1" target="$2" dest="$3" out
  mkdir -p "${dest}/lib"
  log "from-source build -> $(basename "${dest}") (extra: '${extra}')"
  ( cd "${SRC_BUILD}"
    export CFLAGS="${CFLAGS_TUNE} ${extra} ${CFLAGS_ENV}"
    export CXXFLAGS="${CFLAGS_TUNE} ${extra} ${CXXFLAGS_ENV}"
    export CARGO_TARGET_DIR="${target}"
    cargo build --release -p llama-cpp-sys-2 ${CRATE_FEATURES:+--features "${CRATE_FEATURES}"} )
  # `-print -quit` (not `| head -n1`) to avoid SIGPIPE-failing find under `set -o pipefail`.
  out="$(find "${target}" -type d -name out -path '*release/build*llama-cpp-sys-2*' -print -quit)"
  [[ -n "${out}" ]] || { echo "[bench] from-source OUT_DIR not found in ${target}" >&2; exit 1; }
  for lib in ${STATIC_LIBS}; do
    cp "$(find "${out}" -name "${lib}" -print -quit)" "${dest}/lib/${lib}"
  done
  cp "$(find "${out}" -name bindings.rs -print -quit)" "${dest}/bindings.rs"
}

run() {  # $1 = label, $2 = STATIC_LLAMA_DIR, $3 = result file
  log "running '$1' workload (${ITERS} iters)"
  STATIC_LLAMA_DIR="$2" BENCH_ITERS="${ITERS}" BENCH_RESULT="$3" \
    cargo run --release --manifest-path "${ROOT}/bench/Cargo.toml"
}

if [[ "${PGO}" == "1" ]]; then
  # PGO release: report BOTH the PGO gain (pgo vs no-pgo, from-source) AND an
  # apples-to-apples parity check (prebuilt vs from-source, BOTH PGO with the same profile).
  PGO_PROFDATA="${WORK:-${ROOT}/.build}/pgo/pgo.profdata"
  [[ -f "${PGO_PROFDATA}" ]] \
    || { echo "[bench] PGO=1 needs ${PGO_PROFDATA}; run scripts/build.sh with PGO=1 first" >&2; exit 1; }
  SRC_DIST_NOPGO="${ROOT}/.build/source-dist-nopgo"
  SRC_DIST_PGO="${ROOT}/.build/source-dist-pgo"
  build_and_harvest ""                                                        "${SRC_BUILD}/target-nopgo" "${SRC_DIST_NOPGO}"
  build_and_harvest "-fprofile-use=${PGO_PROFDATA} ${PGO_USE_WARN_FLAGS}"     "${SRC_BUILD}/target-pgo"   "${SRC_DIST_PGO}"

  run "prebuilt"     "${DIST}"           "${RESULTS}/bench.prebuilt.json"
  run "source-pgo"   "${SRC_DIST_PGO}"   "${RESULTS}/bench.source_pgo.json"
  run "source-nopgo" "${SRC_DIST_NOPGO}" "${RESULTS}/bench.source_nopgo.json"

  PRE="$(jq -r '.embeddings_per_sec' "${RESULTS}/bench.prebuilt.json")"
  SPGO="$(jq -r '.embeddings_per_sec' "${RESULTS}/bench.source_pgo.json")"
  SNOPGO="$(jq -r '.embeddings_per_sec' "${RESULTS}/bench.source_nopgo.json")"
  RATIO="$(jq -n --argjson a "${PRE}"  --argjson b "${SPGO}"   '$a / $b')"   # parity (both PGO)
  GAIN="$(jq -n  --argjson a "${SPGO}" --argjson b "${SNOPGO}" '$a / $b')"   # PGO speedup
  PASS="$(jq -n  --argjson r "${RATIO}" --argjson t "${THRESHOLD_PCT}" '$r >= (1 - $t/100)')"

  jq -n \
    --argjson prebuilt     "$(cat "${RESULTS}/bench.prebuilt.json")" \
    --argjson source       "$(cat "${RESULTS}/bench.source_pgo.json")" \
    --argjson source_nopgo "$(cat "${RESULTS}/bench.source_nopgo.json")" \
    --argjson ratio        "${RATIO}" \
    --argjson gain         "${GAIN}" \
    --argjson thr          "${THRESHOLD_PCT}" \
    --argjson pass         "${PASS}" \
    '{prebuilt:$prebuilt, source:$source, source_nopgo:$source_nopgo, pgo:true,
      prebuilt_to_source_ratio:$ratio, pgo_gain:$gain,
      regress_threshold_pct:$thr, passed:$pass}' > "${RESULTS}/bench.json"

  log "prebuilt=${PRE} eps, source(pgo)=${SPGO} eps, source(nopgo)=${SNOPGO} eps"
  log "PGO gain=${GAIN}x, parity ratio=${RATIO} (threshold -${THRESHOLD_PCT}%)"
  if [[ "${PASS}" != "true" ]]; then
    echo "[bench] FAIL: prebuilt regressed beyond ${THRESHOLD_PCT}% vs from-source PGO build" >&2
    exit 1
  fi
  log "PASS"
else
  # Default: a single from-source baseline; prebuilt-vs-source parity (unchanged behavior).
  build_and_harvest "" "${SRC_BUILD}/target" "${SRC_DIST}"

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
fi
