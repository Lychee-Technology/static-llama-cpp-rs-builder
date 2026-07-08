#!/usr/bin/env bash
#
# Fetch the pinned tiny GGUF embedding model used by the smoke test and benchmark,
# verifying its SHA256. The model is a build input: pin URL + SHA and treat a change
# as a test-fixture change.
#
# BOTH are required — the fixture is a pinned build input, so this fails closed until
# you set both (no silent default URL):
#   SMOKE_MODEL_URL     download URL for a small embedding GGUF (e.g. all-MiniLM / bge-small)
#   SMOKE_MODEL_SHA256  expected sha256 of that file
#
# Suggested model: bge-small-en-v1.5 Q8_0 (~34 MB), a small BERT embedding model:
#   https://huggingface.co/CompendiumLabs/bge-small-en-v1.5-gguf/resolve/main/bge-small-en-v1.5-q8_0.gguf
# Download it once, run `sha256sum`, then set the two vars (repo variables in CI).
#
# Prints the resolved model path on stdout (also export SMOKE_MODEL to it).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HERE}/model.gguf"

URL="${SMOKE_MODEL_URL:-}"
SHA="${SMOKE_MODEL_SHA256:-}"

if [[ -z "${URL}" || -z "${SHA}" ]]; then
  echo "ERROR: SMOKE_MODEL_URL and SMOKE_MODEL_SHA256 must both be set (the smoke/bench" >&2
  echo "       model is a pinned input). See the header of this script for a suggested model." >&2
  exit 2
fi

verify() { echo "${SHA}  ${DEST}" | sha256sum -c - >/dev/null 2>&1; }

if [[ -f "${DEST}" ]] && verify; then
  echo "${DEST}"; exit 0
fi

echo "[fixtures] downloading ${URL}" >&2
curl -fSL "${URL}" -o "${DEST}"
if ! verify; then
  echo "ERROR: SHA256 mismatch for ${DEST}" >&2
  echo "  expected: ${SHA}" >&2
  echo "  actual:   $(sha256sum "${DEST}" | awk '{print $1}')" >&2
  exit 1
fi
echo "${DEST}"
