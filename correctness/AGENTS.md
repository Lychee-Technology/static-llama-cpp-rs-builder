# correctness/AGENTS.md

These instructions apply to the numerical correctness harness.

Also follow `../AGENTS.md`.

Rules for committed test data under `fixtures/` live in `fixtures/AGENTS.md`.

## Purpose

The correctness harness validates embedding values rather than merely checking that the
library executes.

`scripts/correctness.sh` is the orchestration layer.

The Rust crate implements emit, comparison, and self-consistency operations used by that
gate.

## Consumer linking

Continue to reuse:

```rust
include!("../scripts/consume.build.rs");
```

Do not create an independent correctness link line.

## Numerical methodology

Treat these as correctness methodology:

- pooling modes;
- attention configuration;
- prompt prefixes;
- tokenization;
- thread configuration;
- batch-vs-single checks;
- determinism checks;
- cosine calculations;
- result thresholds.

Do not weaken or simplify them merely to make a changed build pass.

When methodology intentionally changes, explain the numerical reason and validate the new
behavior through the complete correctness pipeline.

## Generic reference

The generic reference archives are validation artifacts only.

They are not production variants.

The correctness harness must not imply that a generic x86 reference expands support below
the production x86-64-v3 baseline.

## Result interface

`scripts/correctness.sh` consumes modes, emit files, result JSON, labels, and exit status.

Treat these as an interface.

The combined correctness result is merged verbatim into the released `build-info.json` as
`.correctness` and gated on `passed == true` by `scripts/package.sh`. Adding that block
was a contract bump, so changing its fields requires review against `CONTRACT.md`.

Missing labels, invalid numerical data, and failed invariants must continue to fail closed.

The `compare` mode takes the inputs fixture (`CORRECTNESS_INPUTS`) and the poolings the
reference is expected to carry (`CORRECTNESS_REF_POOLINGS`, comma-separated: `mean,last`
for a generic emit, `last` for the golden) and requires the reference's label set to equal
inputs x poolings before any cosine is computed, naming every missing, unexpected or
duplicate label. Keep that gate required for every `compare` call and keep it checking both
directions; a reference that only partially covers `inputs.tsv` must never pass by having
the uncovered rows skipped. A reference with no data rows fails it too, saying so
explicitly. The check adds no field to the result JSON.

The golden compare is unconditional: `scripts/correctness.sh` runs it on every invocation
and counts it toward `passed`, so `golden_parity.status` is always `checked`, and a
missing, empty or comment-only `golden.tsv` fails the gate (issue #9). Do not reintroduce a
row-count guard, a non-fatal skip, or an opt-out around it.

## Dependencies

Keep the crate dependency-free where practical.

Simple numerical operations should remain explicit and reviewable instead of adding a
large dependency without need.

## Validation

Run:

```bash
cargo fmt --manifest-path correctness/Cargo.toml -- --check
```

The crate has unit tests for the pure parts (fixture parsing, pooling-spec parsing, the
reference label-coverage gate, and the committed `inputs.tsv`/`golden.tsv` pair agreeing).
They need the archives to link, so point `STATIC_LLAMA_DIR` at a `dist/`:

```bash
STATIC_LLAMA_DIR="$PWD/dist" cargo test --manifest-path correctness/Cargo.toml
```

For numerical behavior changes, run:

```bash
bash scripts/correctness.sh
```

against a real production `dist/`.

An isolated successful Rust invocation does not prove that the complete
tuned/generic/golden gate remains valid.
