# bench/AGENTS.md

These instructions apply to the benchmark harness.

Also follow `../AGENTS.md`.

## Purpose

This crate measures an embedding workload against whichever archive set is selected by
`STATIC_LLAMA_DIR`.

`scripts/bench.sh` defines the actual packaged-vs-source methodology.

The Rust crate is the measurement harness, not the benchmark policy.

## Consumer linking

Continue to reuse:

```rust
include!("../scripts/consume.build.rs");
```

Do not create a benchmark-specific consumer link implementation.

## Preserve workload comparability

Treat these as benchmark methodology:

- input text;
- tokenization;
- context configuration;
- warm-up;
- iteration semantics;
- timed region;
- reported metric.

Do not casually change them because that can make before/after performance results
incomparable.

The input text intentionally mirrors `scripts/pgo-train.cpp`, so the measured PGO gain
reflects the sequence shape the profile was trained on. Change the two together.

When methodology intentionally changes, update the surrounding benchmark assumptions and
document why.

## Machine-readable results

`scripts/bench.sh` consumes benchmark result fields and embeds the raw harness JSON
verbatim in its own result, which `scripts/package.sh` merges into the released
`build-info.json` as `.benchmark` and gates on `passed == true`.

Treat field names and meanings as a published interface, not only one between the Rust
harness and shell orchestration.

Update the harness and `scripts/bench.sh` together when this interface changes, and
review the change against `CONTRACT.md`.

## Performance failures

Do not change timing code, workload size, warm-up behavior, or iteration counts merely to
make the regression gate pass.

Investigate the artifact, compiler flags, or methodology first.

## Dependencies

Keep the harness dependency-free where practical.

## Validation

Run:

```bash
cargo fmt --manifest-path bench/Cargo.toml -- --check
```

For workload or output changes, run the complete `scripts/bench.sh` path against real
archives.

Running only the Rust binary does not validate the packaged-vs-source comparison.
