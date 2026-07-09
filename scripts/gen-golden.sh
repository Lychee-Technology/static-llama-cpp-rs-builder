#!/usr/bin/env bash
#
# Convenience wrapper: set up a Python venv with the (heavy) FP32 deps and run
# scripts/gen-golden.py to regenerate correctness/fixtures/golden.tsv.
#
# Run OFFLINE (by a maintainer), NOT in CI. The golden is the FP32 PyTorch reference for
# jina-embeddings-v5-text-nano-retrieval (independent of the GGUF/llama.cpp path); CI only
# consumes the committed golden.tsv. Needs network + Python 3.10+.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/correctness/fixtures/reference-model.env"   # golden model id/rev + prefixes
VENV="${ROOT}/.build/golden-venv"

log() { printf '\033[1;35m[golden]\033[0m %s\n' "$*"; }

if [[ ! -d "${VENV}" ]]; then
  log "creating venv at ${VENV}"
  python3 -m venv "${VENV}"
fi
# shellcheck disable=SC1091
source "${VENV}/bin/activate"

log "installing deps (torch>=2.8, transformers>=5.1, sentence-transformers, peft>=0.15)"
pip install -q --upgrade pip
pip install -q "torch>=2.8" "transformers>=5.1" "sentence-transformers>=3.0" "peft>=0.15" huggingface_hub

log "running scripts/gen-golden.py"
CORRECTNESS_GOLDEN_MODEL_ID="${CORRECTNESS_GOLDEN_MODEL_ID}" \
CORRECTNESS_GOLDEN_MODEL_REV="${CORRECTNESS_GOLDEN_MODEL_REV}" \
  python3 "${ROOT}/scripts/gen-golden.py"

log "done. Review the diff to correctness/fixtures/golden.tsv and commit it."
