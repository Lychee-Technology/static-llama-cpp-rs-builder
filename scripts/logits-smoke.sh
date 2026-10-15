#!/usr/bin/env bash
# Required output-semantics test (contract v6): the generative control model pinned in
# config.env must get host logits for generation and per-token embeddings, and none for
# mean-pooled embeddings, including when llama_set_embeddings toggles a pooled context.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"
LIB_TAG=logits-smoke
source "${ROOT}/scripts/lib.sh"
RESULTS="${RESULTS:-${ROOT}/.build/results}"
MODEL="${ROOT}/.build/models/stories260K.gguf"
mkdir -p "${RESULTS}"
fetch_pinned_model "${LOGITS_SMOKE_MODEL_URL}" "${LOGITS_SMOKE_MODEL_SHA256}" "${MODEL}"
SMOKE_MODE=logits \
SMOKE_MODEL="${MODEL}" \
SMOKE_MODEL_ID="${LOGITS_SMOKE_MODEL_ID}" \
SMOKE_MODEL_SHA256="${LOGITS_SMOKE_MODEL_SHA256}" \
SMOKE_RESULT="${RESULTS}/logits-smoke.json" \
  cargo run --release --manifest-path "${ROOT}/smoke/Cargo.toml"
