# scripts/AGENTS.md

These instructions apply to files under `scripts/`.

Also follow `../AGENTS.md`.

## Start with the build relationships

Before changing a script, identify its callers and consumers.

Important relationships:

```text
config.env
   |
   +--> lib.sh  (sourced after config.env)
          +--> build.sh
          +--> correctness.sh           (assert_release_profile)
          +--> bench.sh                 (assert_release_profile)
          +--> embeddinggemma-smoke.sh  (fetch_pinned_model)
          +--> logits-smoke.sh          (fetch_pinned_model)
          +--> ../smoke/fixtures/fetch-model.sh  (fetch_pinned_model)
          +--> package.sh               (assert_release_profile, assert_release_results)
          +--> verify-provenance.sh     (assert_release_profile, assert_release_results)
          +--> test-source-pins.sh      (offline; every platform)
          +--> test-macos-gates.sh      (macOS gates on synthetic Mach-O; Apple Silicon only)

check-x86-64-v3.sh  (compiles and runs x86-64-v3-probe.c)
   |
   +--> lib.sh                   on every x86_64 host, inside the container
   +--> assert-native-runner.sh  on the CI runner, before the image is built

build.sh --PGO=1--> pgo-train.cpp  (compiled, linked, and run; mirrors ../bench/src/main.rs)

gen-golden.sh --> gen-golden.py    (offline, maintainer-only; sources
                                    ../correctness/fixtures/reference-model.env)

consume.build.rs
   |
   +--> ../smoke/build.rs
   +--> ../bench/build.rs
   +--> ../correctness/build.rs
```

Changes to `config.env`, `lib.sh`, `check-x86-64-v3.sh`, and `consume.build.rs` have a
particularly broad blast radius.

## `config.env`

This is the canonical source for upstream repositories and exact pins, supported target
profiles, target triples, CPU baselines, production compiler flags, static archive
membership, system link libraries, and build-environment expectations.

Do not duplicate these values into other scripts when they can be sourced.

Target profiles must remain explicit and fixed. They must not be selected from host CPU
features.

`host_target_profile` maps the host OS and architecture (`uname -s`, `uname -m`) to a
profile. An unknown pair selects no profile, and the build then refuses the host.
`SUPPORTED_TARGET_PROFILES` lists the release variants; `BUILD_ONLY_TARGET_PROFILES` lists
profiles that build and are gated but are never released (`assert_release_profile`).
Every profile sets every profile variable, including `TARGET_OS`, `NATIVE_ARCH`,
`SYSTEM_LINK_LIBS` and the macOS-only ones (empty on Linux), so that no profile inherits a
value from another.

## Native-host validation

Production builds must remain native.

Do not introduce foreign Rust `--target` builds, cross GCC/Clang, CMake cross toolchains,
cross-rs, cargo-zigbuild, Zig cross compilation, QEMU/binfmt_misc, or Docker
foreign-architecture emulation.

An x86 host below x86-64-v3 must be rejected rather than served a lower baseline.
`check-x86-64-v3.sh` is that gate: `lib.sh` runs it inside the container and
`assert-native-runner.sh` runs it on the CI runner before the image is built. Keep it
fail-closed and keep both call sites.

On macOS, `assert_native_host` requires `Darwin`/`arm64`, `hw.optional.arm64` = 1 and
`sysctl.proc_translated` = 0 (not Rosetta 2), and a compiler whose `-dumpmachine` is
`arm64-apple-darwin*`. `macos_host_cpu_check` then requires the apple-m1 `hw.optional`
features. Keep all of them.

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

### Apple Silicon macOS (build-only)

The profile pins `-mcpu=apple-m1`, not `-march`. With Apple clang, `-march=<arch>` changes
only the frontend's feature macros: the backend still gets `-target-cpu apple-m1` (or the
host default), so ggml's compile-time feature selection and the generated code can
disagree. `-mcpu=apple-m1` makes both match. It is a fixed baseline, not autodetection.
Never use `-mcpu=native` or a newer Apple CPU.

The profile is CPU-only: `GGML_BACKEND_DEFINES` turns off Metal and Accelerate; the
crate already forces BLAS off. A backend or framework dependency must not come back
without a deliberate profile change.

Keep the macOS gates in `lib.sh` and their `build.sh` call sites:
- `apple_m1_isa_check`: frontend macros and backend `-target-cpu`/features per flag set;
- `macos_objects_check`: thin arm64, macOS platform, pinned `minos`, recorded SDK, and no
  weak-undefined symbol (cc-rs compiles with `-w`, which hides
  `-Wunguarded-availability`);
- `archive_order_check`: ld64 does not enforce archive order, so check it directly;
- `macos_link_check`: link the archives with exactly `SYSTEM_LINK_LIBS` (each required),
  allow only `libSystem` plus those libraries at run time, and require the CPU backend
  only.

`scripts/test-macos-gates.sh` holds a passing and a failing case for each of them. Extend
it together with the gate.

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

It has two modes. `--packaged`, the default, also requires the five release results
(`smoke`, `embeddinggemma_smoke`, `logits_smoke`, `benchmark`, `correctness`) to be
present, passing, and matching their pins (model ids and SHA-256s, and the `host_logits`
expectations of contract v6).
Use it on anything `package.sh` produced. `--raw` is only for fresh `build.sh` output,
which has no results yet. Do not use `--raw` after packaging, and do not make it the
default.

## `package.sh`

Packaging must fail when required validation results are missing or unsuccessful.

`ALLOW_MISSING_RESULTS=1` bypasses that gate for local development packaging only. Never
set it in CI or on a release path, and do not add further bypasses.

The gate is `lib.sh` `assert_release_results`, which `verify-provenance.sh --packaged`
repeats after packaging and in the release job. It is the one definition of the required
results. Change it there, not in either caller, and keep the
`scripts/test-source-pins.sh` cases in step.

Do not turn an incomplete build into a releasable artifact.

The smoke (all three), benchmark, and correctness result JSON is merged verbatim into
`build-info.json`, so those result schemas are consumer-visible. Changing them requires
review against `CONTRACT.md`.

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

## `pgo-train.cpp`

This is the PGO training workload that `build.sh` compiles, links, and runs when `PGO=1`.

Its input text intentionally mirrors `../bench/src/main.rs`, so the measured PGO gain
reflects the sequence shape the profile was trained on. Change the two together.

## `gen-golden.sh` and `gen-golden.py`

These regenerate `../correctness/fixtures/golden.tsv` offline. They never run in CI.

Run the shell wrapper, not the Python script directly: the wrapper sources
`../correctness/fixtures/reference-model.env` so the pinned golden model revision is used
instead of the script's mutable default.

Fixture rules live in `../correctness/fixtures/AGENTS.md`.

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

Scripts that run on macOS (`config.env`, `lib.sh`, `build.sh`, `verify-provenance.sh`,
the smoke scripts and the test scripts) must work with the system `/bin/bash` 3.2 and BSD
userland:
- no `declare -A`, `mapfile`/`readarray`, `${var,,}` or `local -n`;
- expand a possibly empty array under `set -u` as `${a[@]+"${a[@]}"}`;
- no GNU-only options such as `find -printf`, `sed -i` without a suffix argument,
  `stat -c` or `readlink -f`;
- use `sha256_file` rather than `sha256sum` (macOS `sha256sum -c` passes malformed or empty
  input), and `host_ncpu` rather than `nproc`.

## Validation

Every modified shell script must at least pass:

```bash
bash -n scripts/<modified-script>.sh
```

Changes to compiler flags, source preparation, ISA gates, provenance, packaging, consumer
linking, correctness orchestration, or benchmarking require the corresponding real build
pipeline.

Architecture-sensitive changes must ultimately pass both native CI variants.
