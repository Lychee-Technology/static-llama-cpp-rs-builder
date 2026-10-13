#!/usr/bin/env bash
# Required additional text-only liveness test; does not replace the legacy FP32 gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"
RESULTS="${RESULTS:-${ROOT}/.build/results}"
MODEL="${ROOT}/.build/models/embeddinggemma-2-Q8_0.gguf"
mkdir -p "$(dirname "${MODEL}")" "${RESULTS}"
verify() { echo "${EMBEDDINGGEMMA_MODEL_SHA256}  $1" | sha256sum -c - >&2; }
if [[ ! -f "${MODEL}" ]] || ! verify "${MODEL}"; then
  curl -fSL --retry 3 "${EMBEDDINGGEMMA_MODEL_URL}" -o "${MODEL}.download"
  verify "${MODEL}.download"
  mv "${MODEL}.download" "${MODEL}"
fi
SMOKE_MODEL="${MODEL}" \
SMOKE_MODEL_ID="${EMBEDDINGGEMMA_MODEL_ID}" \
SMOKE_MODEL_SHA256="${EMBEDDINGGEMMA_MODEL_SHA256}" \
SMOKE_EXPECTED_HIDDEN_DIM="${EMBEDDINGGEMMA_HIDDEN_DIM}" \
SMOKE_EXPECTED_OUTPUT_DIM="${EMBEDDINGGEMMA_OUTPUT_DIM}" \
SMOKE_TEXT="task: search result | query: What causes the northern lights?" \
SMOKE_RESULT="${RESULTS}/embeddinggemma-smoke.json" \
  cargo run --release --manifest-path "${ROOT}/smoke/Cargo.toml"
