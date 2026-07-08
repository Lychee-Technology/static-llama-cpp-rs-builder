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
SRC="${SRC:-${ROOT}/.build/llama-cpp-rs}"
RESULTS="${RESULTS:-${ROOT}/.build/results}"
SRC_DIST="${ROOT}/.build/source-dist"
ITERS="${BENCH_ITERS:-200}"
THRESHOLD_PCT="${BENCH_REGRESS_THRESHOLD_PCT:-3}"   # prebuilt must be >= source * (1 - t%)

: "${SMOKE_MODEL:?set SMOKE_MODEL to the pinned GGUF (see smoke/fixtures/fetch-model.sh)}"
mkdir -p "${RESULTS}" "${SRC_DIST}/lib"
log() { printf '\033[1;34m[bench]\033[0m %s\n' "$*"; }

# --- Stage the from-source crate build as an independent "source" link target -----
# It shares provenance with dist/ by design; parity here validates packaging integrity
# and link-order performance, and records an absolute per-release number.
OUT_DIR="$(find "${SRC}/target" -type d -name out -path '*release/build*llama-cpp-sys-2*' \
             | head -n1)"
for lib in ${STATIC_LIBS}; do
  cp "$(find "${OUT_DIR}" -name "${lib}" | head -n1)" "${SRC_DIST}/lib/${lib}"
done
cp "$(find "${OUT_DIR}" -name bindings.rs | head -n1)" "${SRC_DIST}/bindings.rs"

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
