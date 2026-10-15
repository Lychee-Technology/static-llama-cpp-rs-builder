#!/usr/bin/env bash
# Required additional text-only liveness test; does not replace the legacy FP32 gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"
LIB_TAG=embeddinggemma-smoke
source "${ROOT}/scripts/lib.sh"
RESULTS="${RESULTS:-${ROOT}/.build/results}"
MODEL="${ROOT}/.build/models/embeddinggemma-2-Q8_0.gguf"
mkdir -p "${RESULTS}"
fetch_pinned_model "${EMBEDDINGGEMMA_MODEL_URL}" "${EMBEDDINGGEMMA_MODEL_SHA256}" "${MODEL}"
SMOKE_MODEL="${MODEL}" \
SMOKE_MODEL_ID="${EMBEDDINGGEMMA_MODEL_ID}" \
SMOKE_MODEL_SHA256="${EMBEDDINGGEMMA_MODEL_SHA256}" \
SMOKE_EXPECTED_HIDDEN_DIM="${EMBEDDINGGEMMA_HIDDEN_DIM}" \
SMOKE_EXPECTED_OUTPUT_DIM="${EMBEDDINGGEMMA_OUTPUT_DIM}" \
SMOKE_TEXT="task: search result | query: What causes the northern lights?" \
SMOKE_RESULT="${RESULTS}/embeddinggemma-smoke.json" \
  cargo run --release --manifest-path "${ROOT}/smoke/Cargo.toml"
