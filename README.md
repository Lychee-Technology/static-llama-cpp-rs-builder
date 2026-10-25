# static-llama-cpp-rs-builder

Produces **static llama.cpp archives** for two fixed production targets, a Graviton2
(Neoverse N1) tuned `aarch64` build and an `x86-64-v3` build. Each is packaged with pinned
provenance + checksums so LTEmbed can link it directly, with no per-build llama.cpp
recompile.

A third, **build-only** profile, `aarch64-apple-darwin`, builds the same four archives and
bindings natively on an Apple Silicon Mac for local development. It is gated like the
production builds but is not released (see [below](#build-only-apple-silicon-macos)).

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

### Build-only: Apple Silicon macOS

| Architecture | Target | CPU baseline | Native build requirement |
|---|---|---|---|
| ARM64 (Apple) | `aarch64-apple-darwin` | `apple-m1` (`-mcpu=apple-m1`: Armv8.5-A + fp16, fp16fml, dotprod, rcpc, lse, crc, aes, sha2, sha3; no i8mm, bf16, SVE or SME), macOS 11.0 deployment target | Apple Silicon Mac with Xcode's Apple clang 17, not under Rosetta 2 |

`scripts/build.sh` selects this profile from `uname -s` = `Darwin` and `uname -m` = `arm64`,
never from `arm64` alone. It is CPU-only: Metal, Accelerate, BLAS, KleidiAI, OpenMP, dynamic
backend loading and LTO are all off, so the archives run ggml's CPU kernels, as on Linux
ARM64. Consumers link `-lc++` and no frameworks.

It is **not a release variant**: `build-info.json` records `"build_only": true` and
`"artifact_contract_version": null`, and `package.sh`, `correctness.sh`, `bench.sh` and
`verify-provenance.sh --packaged` refuse it. Release integration (CI job, packaging,
correctness/benchmark ports, contract version) is issue #22.

## What a release contains

Static `.a` (`libllama`, `libggml`, `libggml-cpu`, `libggml-base`),
generated `bindings.rs`, headers, `build-info.json`, `SHA256SUMS`, licenses, and a drop-in
`consume.build.rs`. See [CONTRACT.md](CONTRACT.md) for the full contract and consumption steps.

## Pinned inputs

Single source of truth: [`scripts/config.env`](scripts/config.env).

| Input | Pin |
|---|---|
| llama.cpp (compiled engine) | release tag `v0.7.0` @ `620d2225cc436ab0b001e3200e590e3b286ef9ab`, unmodified (HEAD, annotated tag type/peel/tag-object name and `describe --exact-match` verified; compiled semantic version `0.7.0[-dev]`) |
| llama-cpp-rs (`llama-cpp-sys-2` build driver) | tag `0.1.160` @ `0dd5814c9b061930965d144c1653cd4d05054873` (crate `0.1.160`). Its vendored llama.cpp `d8123504` (`v0.6.0`) is replaced by the tag above. |
| Artifact contract | `7` ([CONTRACT.md](CONTRACT.md)) |
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
   1. Selects the target profile from the **native** host OS and architecture
      (`scripts/config.env`). It refuses anything that is not a native build (see below).
      On x86-64 it also runs the fail-closed x86-64-v3 CPU gate.
   2. Clones the pinned llama-cpp-rs commit and checks out llama.cpp `v0.7.0` in place of
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
   `scripts/embeddinggemma-smoke.sh` additionally tests the fixed ggml-org
   EmbeddingGemma 2 Q8_0 text GGUF: mean pooling, non-causal attention, hidden width
   512 and projected output width 768, with the actual input SHA-256 recorded.
   This is liveness/shape validation, not independent FP32 parity or multimodal support.
   Both pooled runs also require `llama_get_logits` to return `NULL` (contract v6: a pooled
   context reserves no host logits). `scripts/logits-smoke.sh` runs a pinned ~1 MB
   generative model with an LM head (`stories260K`) through generation, per-token
   embeddings and `MEAN`/`LAST`/`CLS`-pooled embeddings, and requires logits in exactly the
   modes [CONTRACT.md](CONTRACT.md#output-semantics-v6) lists.
3. `scripts/correctness.sh` compares the tuned build against a generic reference build of
   the same revision, and also runs golden parity and self-consistency checks. Every
   comparison first requires the reference's label set to equal the rows of
   `correctness/fixtures/inputs.tsv` times the expected poolings, so a golden that is stale
   against the inputs fixture fails naming the labels instead of silently skipping rows. The
   golden check runs on every invocation: a `golden.tsv` that is missing or has no data rows
   fails the gate rather than being skipped. The generic reference is `-march=armv8-a` on
   ARM64 and `-march=x86-64` on x86-64. It is a
   **non-production comparison build only**: it is not an artifact, it is never published,
   it is not part of the support matrix, and it does not mean older x86 CPUs are
   supported.
4. `scripts/bench.sh` (`bench/`) compares prebuilt vs from-source performance and enforces
   a regression threshold.
5. `scripts/package.sh` requires and merges all five results (legacy smoke,
   EmbeddingGemma text smoke, logits smoke, benchmark, correctness), gathers licenses and
   writes `SHA256SUMS`.

CI (`.github/workflows/release.yml`) runs all of this once per variant on pull requests,
tag pushes and manual dispatch. Pull requests do not publish a release. Each variant runs on
a GitHub-hosted runner **of its own architecture**, inside a resolved-and-recorded AL2023
container of that architecture:
- `aarch64-graviton2` on `ubuntu-24.04-arm` (Neoverse N2);
- `x86_64-v3` on `ubuntu-24.04`. The runner must pass the x86-64-v3 gate, or the job
  fails: CI never lowers the baseline or changes `CPU_MARCH`.

CI checks each `build-info.json` against `scripts/config.env` with
`scripts/verify-provenance.sh`. Right after `build.sh` it runs `--raw`, which checks the
pins only. After `package.sh`, and again in the release job, it runs `--packaged` (the
default), which also requires all five results to be present, passing and matching their
pins. That is the check `package.sh` gates on, so a `build-info.json` packaged with
`ALLOW_MISSING_RESULTS=1` is rejected. On `v*` tags CI publishes one GitHub Release with
exactly the two variants. Its notes quote the verified llama.cpp tag and commit and each
tarball's SHA-256.

**Native builds only.** The actual host, container, compiler and artifact architectures must
all be the same: `aarch64` for the ARM64 variant, `x86_64` for the x86-64 variant, and
`arm64` (`aarch64-apple-darwin`) for the build-only macOS profile. The following are not
supported:
- cross compilation in either direction (x86 → ARM, ARM → x86): foreign `--target`, cross
  gcc, CMake cross toolchain files, cross-rs, cargo-zigbuild, zig;
- CPU emulation: QEMU, binfmt_misc, Docker Buildx architecture emulation or
  `docker --platform` for a foreign arch, or Rosetta 2 on macOS.

`scripts/assert-native-runner.sh <arch>` (CI), the Dockerfile and `scripts/lib.sh`
(`assert_native_host`) each refuse a non-native build:
- ARM64: *"ARM64 artifacts must be built on a native ARM64 host. Cross-compilation and CPU
  emulation are not supported."*
- x86-64 hosts that are not v3 capable get *"ERROR: native x86 build requires an x86-64-v3
  capable CPU. This project intentionally does not support x86-64-v2 or older hosts."*
  `uname -m` alone is not trusted. `scripts/check-x86-64-v3.sh` checks CPUID + XGETBV
  (AVX, AVX2, BMI1, BMI2, F16C, FMA, LZCNT, MOVBE, OS-enabled AVX state, …), glibc's hwcaps
  and `/proc/cpuinfo`.
- macOS hosts that are not Apple Silicon, or that run the build under Rosetta 2, get
  *"Apple Silicon macOS artifacts must be built natively on an Apple Silicon Mac.
  Cross-compilation, Rosetta 2 and CPU emulation are not supported."* `lib.sh` also requires
  `sysctl.proc_translated` = 0 and the apple-m1 `hw.optional` CPU features.

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
    bash scripts/embeddinggemma-smoke.sh
    bash scripts/logits-smoke.sh
    scripts/correctness.sh && scripts/bench.sh && scripts/package.sh'
```

Before the first release, pin the smoke/bench model: set the `SMOKE_MODEL_URL` /
`SMOKE_MODEL_SHA256` repo variables (see `smoke/fixtures/fetch-model.sh`).

The additional EmbeddingGemma fixture and the logits-smoke control model are pinned in
`scripts/config.env`, not those variables. They download about 310 MB and 1.2 MB into
`.build/models/` and are not shipped in the native artifact. Existing Jina numerical
fixtures are retained strictly as legacy runtime-regression coverage; this upgrade does
not select LTEmbed's default model or replace its independent correctness data. LTEmbed's
model migration must separately verify prompts, tokenizer parity, pooling, the learned
projection and independent FP32 embeddings before updating its release inputs.

Offline input/gate tests: `bash scripts/test-source-pins.sh`. They use scratch Git
repositories and synthetic metadata, not real build or model-correctness validation. On an
Apple Silicon Mac, `bash scripts/test-macos-gates.sh` also exercises the macOS object,
order, link and ISA gates on small synthetic sources.

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

## Local build on Apple Silicon macOS (build-only)

Runs directly on the Mac, with no Docker. It needs Xcode (Apple clang 17 and the macOS
SDK, selected with `xcode-select`), CMake, `git`, `jq` and the Rust toolchain from
`rust-toolchain.toml` via rustup. The SDK, Xcode, compiler path and CMake version are
recorded in `build-info.json` (`build_env`, `cmake`) rather than pinned.

```sh
scripts/build.sh                      # dist/: 4 archives, bindings.rs, headers, build-info.json
scripts/verify-provenance.sh --raw    # --packaged refuses a build-only profile
export SMOKE_MODEL="$(smoke/fixtures/fetch-model.sh)"   # needs SMOKE_MODEL_URL / _SHA256
export RESULTS="$PWD/.build/results"; mkdir -p "$RESULTS"
SMOKE_RESULT="$RESULTS/smoke.json" cargo run --release --manifest-path smoke/Cargo.toml
bash scripts/embeddinggemma-smoke.sh
bash scripts/logits-smoke.sh
```

On macOS `build.sh` gates the following, in addition to the pins and the exact archive and
bindings set:
- Apple clang 17 for both `CC` and `CXX`;
- the CMake cache: Darwin/arm64, AppleClang, the pinned `CMAKE_OSX_DEPLOYMENT_TARGET`,
  Metal/Accelerate/BLAS/KleidiAI off, and ggml's probed CPU features consistent with
  apple-m1 (dotprod and fp16 vector arithmetic; no SVE, i8mm or SME);
- every TU's flags (`-mcpu=apple-m1`, the pinned `-mmacosx-version-min`, `-arch arm64`, and
  no `-march`/`-mtune`/`native`/LTO/OpenMP), plus the frontend macros and backend
  `-target-cpu` of each flag set;
- every archive member: thin arm64, the macOS platform, the pinned minimum OS, the
  recorded SDK, and no weak-undefined (unguarded newer-than-target) API;
- archive order with no back-references;
- a probe link of the archives with only the recorded system libraries, each of which must
  be required. The probe binary may load nothing beyond `libSystem` and `libc++` and must
  report the CPU backend only.

`PGO=1` is refused on this profile.
