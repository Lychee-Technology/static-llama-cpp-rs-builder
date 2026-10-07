# static-llama-cpp-rs-builder

Produces **static llama.cpp archives** for two fixed production targets, a Graviton2
(Neoverse N1) tuned `aarch64` build and an `x86-64-v3` build. Each is packaged with pinned
provenance + checksums so LTEmbed can link it directly, with no per-build llama.cpp
recompile.

## Support matrix

| Architecture | Target | CPU baseline | Native build requirement |
|---|---|---|---|
| ARM64 | `aarch64-unknown-linux-gnu` | `armv8.2-a+fp16+dotprod+rcpc` (`-mtune=neoverse-n1`) | native ARM64 host |
| x86-64 | `x86_64-unknown-linux-gnu` | `x86-64-v3` | native x86-64 host that is x86-64-v3 capable |

Supported x86 baseline: x86-64-v3

CPUs older than x86-64-v3 are intentionally unsupported.

There are exactly two artifact variants:
- `static-llama-cpp-<tag>-aarch64-graviton2.tar.gz`
- `static-llama-cpp-<tag>-x86_64-v3-linux-gnu.tar.gz`

There is no x86-64-v2 or generic x86 artifact, and no runtime ISA fallback. The x86-64
archives require AVX, AVX2, BMI1/BMI2, F16C, FMA, LZCNT and MOVBE, and will fault with
SIGILL on older CPUs.

## What a release contains

Static `.a` (`libllama`, `libggml`, `libggml-cpu`, `libggml-base`),
generated `bindings.rs`, headers, `build-info.json`, `SHA256SUMS`, licenses, and a drop-in
`consume.build.rs`. See [CONTRACT.md](CONTRACT.md) for the full contract and consumption steps.

## Pinned inputs

Single source of truth: [`scripts/config.env`](scripts/config.env).

| Input | Pin |
|---|---|
| llama.cpp (compiled engine) | tag `v0.6.0` @ `d81235049384534c167caea52b85a694f6103d14` (HEAD, tag peel and `describe --exact-match` verified at build time) |
| llama-cpp-rs (`llama-cpp-sys-2` build driver) | tag `0.1.159` @ `3cfdd729d65e35da407e5f820edf73201bfa54f6` (crate `0.1.159`). Its vendored llama.cpp `26394b4e` is replaced by the tag above. |
| Artifact contract | `4` ([CONTRACT.md](CONTRACT.md)) |
| Rust | `1.96.1` (`rust-toolchain.toml`) |
| CMake | `3.29.6` (`Dockerfile`) |
| Compiler | Clang 18 (AL2023 `clang18`), GNU libstdc++ |
| CPU profile (ARM64) | `-O3 -march=armv8.2-a+fp16+dotprod+rcpc -mtune=neoverse-n1` (no `native`/`-mcpu`/`-flto`) |
| CPU profile (x86-64) | `-O3 -march=x86-64-v3`, generic tuning (no `-mtune`, no `native`, no `-flto`, no AVX-512/AMX/AVX-VNNI) |
| Features | none, built with `--no-default-features`: no OpenMP (ggml threadpool, no libgomp) and no `common` (no extra wrapper archive or `llama_rs_*` bindings) |
| PGO | optional (`PGO=1`) — profile-guided optimization trained on the embedding hot path; codegen-only, no contract change (see [CONTRACT.md](CONTRACT.md)) |

**Build image (not a pin):** `amazonlinux:2023` is **resolved at build time and recorded** in
`build-info.json` (`build_env`) for traceability, not pinned as a product input — LTEmbed deploys
on AWS-managed AL2023 (Lambda/Fargate). Consumers pin the **release artifact checksum**, not the
build image. CI gates the environment envelope (`EXPECTED_CLANG_MAJOR`, `MIN_GLIBC`). Setting
`AL2023_DIGEST` pins the base image for a run to aid tracing — it is **not** full reproducibility
(`dnf` still pulls current packages from mutable repos; resolved versions are recorded).

## How it works

1. `scripts/build.sh`:
   1. Selects the target profile from the **native** host architecture (`scripts/config.env`).
      It refuses anything that is not a native build (see below). On x86-64 it also runs
      the fail-closed x86-64-v3 CPU gate.
   2. Clones the pinned llama-cpp-rs commit and checks out llama.cpp `v0.6.0` in place of
      the crate's submodule, verifying both by commit.
   3. Builds `llama-cpp-sys-2` with the profile's fixed flags injected:
      - ARM64: ggml `GGML_CPU_ARM_ARCH` for dotprod, plus `-mtune`.
      - x86-64: `-march=x86-64-v3`, with `GGML_NATIVE=OFF` and an explicit ggml ISA option
        set (SSE4.2/AVX/AVX2/BMI2/FMA/F16C on; AVX-512/AVX-VNNI/AMX off).
   4. Runs **fail-closed gates**:
      - the CMake cache (including no cross compiling);
      - the embedded llama.cpp commit;
      - the per-TU compile flags: the exact `-march`; no `native`, `-mcpu`, `-flto`,
        OpenMP or conflicting `-march`/`-mtune`. On x86-64, the compiler's effective ISA per
        flag set must be exactly x86-64-v3;
      - on x86-64, a disassembly scan that rejects any AVX-512/EVEX, AMX, VNNI or other
        above-v3 instruction;
      - the exact `.a` set and the bindings.
   5. Harvests the `.a` files, bindings and headers into `dist/`, and writes
      `build-info.json`.
2. **smoke** (`smoke/`): links the archives and runs a real embedding/context-init test.
3. `scripts/correctness.sh` compares the tuned build against a generic reference build of
   the same revision, and also runs golden parity and self-consistency checks. The generic
   reference is `-march=armv8-a` on ARM64 and `-march=x86-64` on x86-64. It is a
   **non-production comparison build only**: it is not an artifact, it is never published,
   it is not part of the support matrix, and it does not mean older x86 CPUs are
   supported.
4. `scripts/bench.sh` (`bench/`) compares prebuilt vs from-source performance and enforces
   a regression threshold.
5. `scripts/package.sh` merges the results, gathers licenses and writes `SHA256SUMS`.

CI (`.github/workflows/release.yml`) runs all of this once per variant. Each variant runs on
a GitHub-hosted runner **of its own architecture**, inside a resolved-and-recorded AL2023
container of that architecture:
- `aarch64-graviton2` on `ubuntu-24.04-arm` (Neoverse N2);
- `x86_64-v3` on `ubuntu-24.04`. The runner must pass the x86-64-v3 gate, or the job
  fails: CI never lowers the baseline or changes `CPU_MARCH`.

CI checks each `build-info.json` against `scripts/config.env`
(`scripts/verify-provenance.sh <file> <profile>`). On `v*` tags it publishes one GitHub
Release with exactly the two variants.

**Native builds only.** The actual host, container, compiler and artifact architectures must
all be the same: `aarch64` for the ARM64 variant, `x86_64` for the x86-64 variant. The
following are not supported:
- cross compilation in either direction (x86 → ARM, ARM → x86): foreign `--target`, cross
  gcc, CMake cross toolchain files, cross-rs, cargo-zigbuild, zig;
- CPU emulation: QEMU, binfmt_misc, Docker Buildx architecture emulation or
  `docker --platform` for a foreign arch.

`scripts/assert-native-runner.sh <arch>` (CI), the Dockerfile and `scripts/lib.sh`
(`assert_native_host`) each refuse a non-native build:
- ARM64: *"ARM64 artifacts must be built on a native ARM64 host. Cross-compilation and CPU
  emulation are not supported."*
- x86-64 hosts that are not v3 capable get *"ERROR: native x86 build requires an x86-64-v3
  capable CPU. This project intentionally does not support x86-64-v2 or older hosts."*
  `uname -m` alone is not trusted. `scripts/check-x86-64-v3.sh` checks CPUID + XGETBV
  (AVX, AVX2, BMI1, BMI2, F16C, FMA, LZCNT, MOVBE, OS-enabled AVX state, …), glibc's hwcaps
  and `/proc/cpuinfo`.

## Local run (on a native aarch64 or x86-64-v3 Linux host)

```sh
# Default resolves amazonlinux:2023 latest. To pin the base image for a run (tracing;
# not full reproducibility), add: --build-arg AL2023_DIGEST=2023@sha256:<digest>
# Build on the host whose architecture you want to produce: the image is the host's own
# arch. Never pass a foreign --platform.
docker build -t static-llama-builder .
docker run --rm -v "$PWD:/work" -w /work \
  -e SMOKE_MODEL_URL=<url> -e SMOKE_MODEL_SHA256=<pinned-sha> static-llama-builder bash -c '
    git config --global --add safe.directory "*"
    scripts/build.sh
    export SMOKE_MODEL="$(smoke/fixtures/fetch-model.sh)"
    export RESULTS=/work/.build/results; mkdir -p "$RESULTS"
    SMOKE_RESULT="$RESULTS/smoke.json" cargo run --release --manifest-path smoke/Cargo.toml
    scripts/correctness.sh && scripts/bench.sh && scripts/package.sh'
```

Before the first release, pin the smoke/bench model: set the `SMOKE_MODEL_URL` /
`SMOKE_MODEL_SHA256` repo variables (see `smoke/fixtures/fetch-model.sh`).

### Optional: PGO-optimized build

The ISA is fixed per variant (N1: dotprod + fp16; x86-64: v3), so the remaining
compile-time lever is **PGO**. It is opt-in and trains on the exact embedding hot path
(`llama_encode`). Each architecture trains its own profile on its own native host; on x86-64
the instrumented build also uses `-march=x86-64-v3` on a v3 host. Profiles are never shared
between ARM64 and x86-64:

```sh
# PGO_TRAIN_MODEL must be the quant you deploy (e.g. IQ4_NL) — the profile is quant-specific.
PGO=1 PGO_TRAIN_MODEL="$SMOKE_MODEL" scripts/build.sh   # instrument → train → optimize
PGO=1 SMOKE_MODEL="$SMOKE_MODEL"     scripts/bench.sh    # reports pgo_gain + a both-PGO parity check
```

`build.sh` records the profile's `sha256` and training metadata in `build-info.json`, in the
`pgo` block, including `architecture` and `cpu_baseline`. `bench.sh` refuses a profile whose
`pgo.meta.json` is for another architecture or baseline, and writes the measured `pgo_gain`
into `bench.json`. Needs `llvm-profdata`
(`llvm18`) and the compiler-rt profile runtime in the image. Default builds are non-PGO.
