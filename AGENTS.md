# AGENTS.md

This repository builds and publishes precompiled static llama.cpp artifacts for
`llama-cpp-rs` consumers.

The product is not merely a successful compilation. The product includes the native
archives, generated bindings, provenance, checksums, consumer link behavior, numerical
correctness, and the guarantees documented in `CONTRACT.md`.

## Before making changes

Read:

- `README.md` for the repository architecture and release flow.
- `CONTRACT.md` before changing anything consumer-visible.
- The nearest nested `AGENTS.md` for the directory you are modifying.

Build inputs and supported target profiles are defined by `scripts/config.env`.

Directory-specific instructions exist under:

- `scripts/`
- `.github/workflows/`
- `smoke/`
- `bench/`
- `correctness/`
- `correctness/fixtures/`

Prefer the most specific applicable instructions.

## Repository-wide invariants

### Production builds are native-only

For every production artifact:

```text
host architecture
    == container architecture
    == compiler architecture
    == Rust target architecture
    == artifact architecture
```

Do not introduce cross-compilation or CPU-emulation fallbacks.

This project does not support producing ARM artifacts from x86 hosts or x86 artifacts from
ARM hosts.

If the current environment cannot perform a required native build, report that limitation
instead of silently changing the build strategy.

### Production target profiles are fixed

The production profiles are defined in `scripts/config.env`.

There are exactly two supported production variants:

```text
aarch64-graviton2
x86_64-v3
```

Do not add a generic or lower-ISA production fallback merely to support an incapable host.

Production code generation must not depend on the current host CPU.

Never introduce host-derived production flags such as:

```text
-march=native
-mtune=native
-mcpu=native
```

unless the artifact contract is intentionally redesigned.

### Validation must fail closed

Build, ISA, provenance, checksum, correctness, and packaging gates are part of the product.

Do not make a failing change pass by:

- deleting a validation;
- changing an error to a warning;
- accepting unknown provenance;
- silently substituting another target or CPU baseline;
- weakening ISA checks;
- ignoring source revision mismatches;
- reducing correctness thresholds without evidence;
- bypassing checksum or provenance verification.

If an upstream change invalidates an existing expectation, update the expectation
deliberately while preserving an equivalent or stronger guarantee.

### Treat the artifact contract as an API

Read `CONTRACT.md` before changing:

```text
shipped archives
consumer link line or link order
enabled Cargo features
bindings ABI
compiled llama.cpp / llama-cpp-rs revisions
dist/ layout
build-info.json fields, including the merged smoke / benchmark / correctness results
production target variants
CPU baselines
consumer-visible guarantees
```

These changes may require an artifact contract version bump.

Do not bump the contract for an internal refactor with no externally visible effect.
Do not avoid a required contract bump merely to retain the current version.

### Exact source provenance matters

Pinned inputs must continue to be verified against exact commits.

Do not weaken an exact commit verification into a tag-only or version-only check.

When changing an upstream pin, explicitly evaluate source provenance, generated bindings,
ABI compatibility, artifact contract impact, correctness, and performance.

## Sources of truth

Avoid copying canonical values into additional files.

The important authorities are:

```text
scripts/config.env          build inputs and target profiles
CONTRACT.md                 consumer-visible artifact contract
scripts/consume.build.rs    canonical consumer link implementation
```

If documentation, configuration, generated provenance, and executable behavior disagree,
fix the inconsistency instead of creating another independent definition.

## Root-level build files

`Dockerfile` and `rust-toolchain.toml` are build inputs even though they live at repository
root.

Changes to either can affect code generation or ABI. For such changes, also read
`scripts/AGENTS.md` and treat the change as build-system work.

Do not add foreign Rust targets to `rust-toolchain.toml` as part of the normal build; the
repository intentionally uses native host toolchains only.

## Generated files

Do not normally commit local build output such as:

```text
.build/
dist/
target/
**/target/
smoke/fixtures/model.gguf
__pycache__/
*.pyc
```

Committed correctness fixtures are governed by `correctness/fixtures/AGENTS.md`.

## Validation

Use the smallest validation that proves the change, but do not substitute a lightweight
syntax check for release validation.

Shell changes should at least pass `bash -n`.

Rust changes should pass rustfmt under the toolchain pinned by `rust-toolchain.toml`. There
is no workspace `Cargo.toml` at the repository root; `smoke/`, `bench/`, and `correctness/`
are independent crates, so run the check per affected harness:

```bash
cargo fmt --manifest-path <harness>/Cargo.toml -- --check
```

The `lint` workflow runs both baseline checks on every push and pull request, so the tree
is expected to be clean before a change starts. If a toolchain bump changes rustfmt output,
reformat in a commit of its own rather than mixing it into an unrelated change.

Release-affecting or architecture-sensitive changes must ultimately pass the native CI
matrix for both production variants.

A local machine validates only its own native architecture.

If complete validation is unavailable, state exactly what was run and what remains
unverified. Never claim an architecture was tested when it was not.
