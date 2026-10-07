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

## Output behavior

The release pipeline consumes the process exit status and optional machine-readable smoke
result.

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
