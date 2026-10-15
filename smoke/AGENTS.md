# smoke/AGENTS.md

These instructions apply to the smoke-test crate.

Also follow `../AGENTS.md`.

## Purpose

The smoke test proves that the packaged static artifact can be linked and execute a real
llama.cpp model-load/context/embedding path.

It is an integration and liveness test.

It is not a substitute for numerical correctness testing.

## Consumer linking

`build.rs` must continue to reuse the canonical consumer link implementation:

```rust
include!("../scripts/consume.build.rs");
```

Do not create a smoke-specific link line.

## Scope

Keep this crate small and dependency-free unless a new dependency has a strong
justification.

Prefer the Rust standard library for simple result serialization and test logic.

Generated bindings must continue to come from `STATIC_LLAMA_BINDINGS`.

Keep unsafe FFI operations localized and validate error/pointer results before use.

## Model fixture

The smoke model is fetched by `fixtures/fetch-model.sh` from the `SMOKE_MODEL_URL` /
`SMOKE_MODEL_SHA256` repository variables. There is no default, and the fetch fails closed
on a checksum mismatch.

The same model is the benchmark workload and, for a PGO build, the training model.
`scripts/correctness.sh` requires it to be byte-identical to the correctness reference GGUF
pinned in `correctness/fixtures/reference-model.env`; changing either pin without the
other fails the release at that check.

Contract v5 also requires the separate text-only EmbeddingGemma 2 liveness fixture
from `../scripts/config.env`, run by `../scripts/embeddinggemma-smoke.sh`. It does
not replace the legacy model or its independent golden. `../CONTRACT.md` describes
the additional result and its limited coverage. Read pooled buffers using
`llama_model_n_embd_out`, not the hidden `llama_model_n_embd` width.

Contract v6 makes a pooled embeddings context reserve no host logits: both pooled runs
require `llama_get_logits` to return `NULL` and record `"host_logits":false`. Neither
embedding fixture has an LM head, so `SMOKE_MODE=logits` (run by
`../scripts/logits-smoke.sh`) uses a third pinned fixture, a tiny generative model, to
prove logits still exist in every mode that needs them. `LOGITS_MODES` in `src/main.rs`
and `LOGITS_SMOKE_HOST_LOGITS` in `../scripts/lib.sh` describe the same expectations; a
unit test keeps them equal, and `../CONTRACT.md` "Output semantics" is the authority for
both.

## Output behavior

The release pipeline consumes the process exit status and the machine-readable result
written to `SMOKE_RESULT`.

That result is required, not optional: `scripts/package.sh` refuses to package unless it
exists with `passed == true`, and it is merged verbatim into the released
`build-info.json` as `.smoke` (`.embeddinggemma_smoke`, `.logits_smoke` for the other
two runs). Changing its fields requires review against `CONTRACT.md`.

Preserve that interface when refactoring.

A failed smoke condition must exit nonzero.

## Validation

For Rust changes run:

```bash
cargo fmt --manifest-path smoke/Cargo.toml -- --check
```

The unit tests need a built artifact to link against (`STATIC_LLAMA_DIR`). Then exercise
the smoke binary against that artifact in both modes.

Do not weaken `scripts/consume.build.rs` merely to make an artifact-free Cargo command
succeed.
