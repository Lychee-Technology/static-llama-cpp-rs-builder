# scripts/AGENTS.md

These instructions apply to files under `scripts/`.

Also follow `../AGENTS.md`.

## Start with the build relationships

Before changing a script, identify its callers and consumers.

Important relationships:

```text
config.env
   |
   +--> lib.sh
   |      +--> build.sh
   |      +--> correctness.sh
   |      +--> bench.sh
   |
   +--> package.sh
   +--> verify-provenance.sh

consume.build.rs
   |
   +--> ../smoke/build.rs
   +--> ../bench/build.rs
   +--> ../correctness/build.rs
```

Changes to `config.env`, `lib.sh`, and `consume.build.rs` have a particularly broad blast
radius.

## `config.env`

This is the canonical source for upstream repositories and exact pins, supported target
profiles, target triples, CPU baselines, production compiler flags, static archive
membership, system link libraries, and build-environment expectations.

Do not duplicate these values into other scripts when they can be sourced.

Target profiles must remain explicit and fixed. They must not be selected from host CPU
features.

## Native-host validation

Production builds must remain native.

Do not introduce foreign Rust `--target` builds, cross GCC/Clang, CMake cross toolchains,
cross-rs, cargo-zigbuild, Zig cross compilation, QEMU/binfmt_misc, or Docker
foreign-architecture emulation.

An x86 host below x86-64-v3 must be rejected rather than served a lower baseline.

## `lib.sh`

Treat `lib.sh` as shared build infrastructure.

Prefer shared validation helpers here instead of duplicating checks across callers.

Important responsibilities include native-host checks, source checkout and exact pin
verification, llama.cpp source replacement, CMake/Cargo build setup, archive harvesting,
compiler flag validation, and ISA validation.

Do not weaken a shared validation because one caller finds it inconvenient.

## `build.sh`

A requested compiler flag is not proof that the produced objects obey it.

When changing build configuration, preserve validation of the actual build output,
including as applicable:

- CMake cache;
- cross-compilation state;
- `compile_commands.json`;
- `-march` / `-mtune` behavior;
- forbidden flags;
- effective ISA;
- generated bindings;
- expected static archive set;
- embedded llama.cpp revision.

### ARM

The production ARM profile must remain compatible with the configured Graviton2 /
Neoverse N1 baseline.

The native CI runner may support newer instructions. Never allow the runner's ISA to leak
into production objects.

Do not replace the fixed profile with `native` or `-mcpu` autodetection.

### x86-64

The production x86 baseline is exactly x86-64-v3.

Keep `GGML_NATIVE` disabled and the configured ISA set explicit.

Do not enable AVX-512, AMX, AVX-VNNI, or another above-v3 extension.

Keep the effective-ISA and disassembly gates. Seeing `-march=x86-64-v3` on the command
line alone is insufficient proof.

## Source pins

When updating llama.cpp or llama-cpp-rs:

1. update the canonical pins in `config.env`;
2. verify tags/refs resolve to the expected commits;
3. preserve validation of the vendored llama.cpp gitlink where applicable;
4. rebuild generated bindings normally;
5. evaluate ABI and contract impact;
6. run correctness and benchmark validation.

Do not manually patch generated `bindings.rs` as a substitute for rebuilding against the
pinned headers.

## `verify-provenance.sh`

Provenance should be both recorded and independently checked.

When adding a provenance-critical field to `build-info.json`, normally add verification
for it here as well.

Compare metadata against canonical configuration rather than trusting a value simply
because the build generated it.

## `package.sh`

Packaging must fail when required validation results are missing or unsuccessful.

Do not turn an incomplete build into a releasable artifact.

Keep checksums and packaged contents synchronized.

Archive membership or layout changes require review against `CONTRACT.md`.

## `consume.build.rs`

This is the canonical consumer link implementation.

The smoke, benchmark, and correctness crates intentionally include this exact file.

Do not introduce separate harness-specific link lines.

Keep synchronized:

```text
scripts/config.env
scripts/consume.build.rs
CONTRACT.md
packaged archives
build-info.json link metadata
```

Changing archive membership, archive order, or system libraries is contract-sensitive.

## `correctness.sh`

The generic reference build is a test reference only.

It must use the same pinned source revisions as production, remain independent from the
tuned production archives, remain sufficiently generic for comparison, and never be
published as a production artifact.

Do not interpret the generic x86 build as support for CPUs below x86-64-v3.

Correctness thresholds are gates. Do not reduce them simply because a new build fails.

## `bench.sh`

The source side of the benchmark must be an independent source build.

Do not reuse production build objects as the "from-source" baseline; that would make the
comparison circular.

PGO profiles are architecture- and CPU-baseline-specific.

Reject a profile whose architecture, baseline, metadata, or checksum does not match the
build.

## Shell conventions

Use Bash consistently.

Non-trivial scripts should normally use:

```bash
set -euo pipefail
```

Quote expansions unless splitting is intentional, prefer `[[ ... ]]`, check assumptions
before expensive or destructive operations, and be careful with pipelines under
`pipefail`.

Avoid broad `|| true`; constrain expected failure cases explicitly.

Use atomic replacement for important generated metadata where partial writes could be
mistaken for valid output.

## Validation

Every modified shell script must at least pass:

```bash
bash -n scripts/<modified-script>.sh
```

Changes to compiler flags, source preparation, ISA gates, provenance, packaging, consumer
linking, correctness orchestration, or benchmarking require the corresponding real build
pipeline.

Architecture-sensitive changes must ultimately pass both native CI variants.
