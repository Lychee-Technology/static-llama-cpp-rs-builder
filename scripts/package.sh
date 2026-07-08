#!/usr/bin/env bash
#
# Finalize the release: merge smoke + benchmark results into build-info.json, gather
# license files, and generate SHA256SUMS over every shipped file. Run AFTER build.sh,
# smoke, and bench.
#
# Optional inputs (JSON files written by the smoke/bench steps):
#   RESULTS/smoke.json    RESULTS/bench.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"

DIST="${DIST:-${ROOT}/dist}"
RESULTS="${RESULTS:-${ROOT}/.build/results}"
SRC="${SRC:-${ROOT}/.build/llama-cpp-rs}"

log() { printf '\033[1;34m[package]\033[0m %s\n' "$*"; }

[[ -f "${DIST}/build-info.json" ]] || { echo "run build.sh first" >&2; exit 1; }

# --- Merge smoke + benchmark results ----------------------------------------------
smoke_json="null"; bench_json="null"
[[ -f "${RESULTS}/smoke.json" ]] && smoke_json="$(cat "${RESULTS}/smoke.json")"
[[ -f "${RESULTS}/bench.json" ]] && bench_json="$(cat "${RESULTS}/bench.json")"

tmp="$(mktemp)"
jq --argjson smoke "${smoke_json}" --argjson bench "${bench_json}" \
   '.smoke = $smoke | .benchmark = $bench' \
   "${DIST}/build-info.json" > "${tmp}" && mv "${tmp}" "${DIST}/build-info.json"
log "Merged smoke/benchmark results into build-info.json"

# --- License files ----------------------------------------------------------------
mkdir -p "${DIST}/LICENSES"
cp -v "${ROOT}/LICENSE" "${DIST}/LICENSES/static-llama-cpp-rs-builder.LICENSE"
if [[ -d "${SRC}" ]]; then
  cp -v "${SRC}/llama-cpp-sys-2/llama.cpp/LICENSE" "${DIST}/LICENSES/llama.cpp.LICENSE" 2>/dev/null || true
  # ggml ships under the same MIT license; copy if present as a separate file.
  cp -v "${SRC}/llama-cpp-sys-2/llama.cpp/ggml/LICENSE" "${DIST}/LICENSES/ggml.LICENSE" 2>/dev/null || true
fi

# --- Ship the consume snippet so consumers have a matching build.rs ---------------
cp -v "${ROOT}/scripts/consume.build.rs" "${DIST}/consume.build.rs"
cp -v "${ROOT}/CONTRACT.md" "${DIST}/CONTRACT.md"

# --- SHA256SUMS over everything (generated last; covers build-info.json) ----------
( cd "${DIST}" && find . -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS )
log "Wrote ${DIST}/SHA256SUMS"

log "Release contents:"
( cd "${DIST}" && find . -type f | sort )
