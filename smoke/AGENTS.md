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

## Output behavior

The release pipeline consumes the process exit status and the machine-readable result
written to `SMOKE_RESULT`.

That result is required, not optional: `scripts/package.sh` refuses to package unless it
exists with `passed == true`, and it is merged verbatim into the released
`build-info.json` as `.smoke`. Changing its fields requires review against `CONTRACT.md`.

Preserve that interface when refactoring.

A failed smoke condition must exit nonzero.

## Validation

For Rust changes run:

```bash
cargo fmt --manifest-path smoke/Cargo.toml -- --check
```

Then exercise the smoke binary against a real built artifact.

Do not weaken `scripts/consume.build.rs` merely to make an artifact-free Cargo command
succeed.
