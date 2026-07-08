# Artifact Contract — v2

This defines exactly what a release contains, how to link it, and how to verify it.
Both llama.cpp and `llama-cpp-rs` lack strong semver/ABI stability, so **consumers pin a
contract version** and re-verify on every bump.

## Contract version

`artifact_contract_version` (in `build-info.json`) is currently **`2`** (v1 → v2: Clang 18
compiler and OpenMP dropped, so `-lgomp` left the link line). It **must** bump on any
change to: the set of shipped `.a`, the link line, enabled cargo features, the binding ABI
(crate tag / llama.cpp submodule), or the `dist/` layout. LTEmbed pins the contract version
it supports and fails closed on an unexpected value.

## Release layout (`dist/`)

```
lib/            libllama.a libggml.a libggml-base.a libggml-cpu.a libllama-common.a
include/        llama.h ggml*.h ... (matching the pinned submodule)
bindings.rs     generated FFI bindings (bindgen, Consts enums, prepend_enum_name=false)
build-info.json full bill-of-materials + provenance + smoke/benchmark results
consume.build.rs drop-in build.rs (this repo's scripts/consume.build.rs)
CONTRACT.md     this file
SHA256SUMS      sha256 over every other file in the release
LICENSES/       llama.cpp, ggml, and builder licenses (all MIT)
```

## Build profile (v2)

- Target: `aarch64-unknown-linux-gnu`, tuned for Graviton2 / N1 via
  **`-march=armv8.2-a+fp16+dotprod`** (ISA, incl. dotprod — set through ggml's
  `GGML_CPU_ARM_ARCH`) **`-mtune=neoverse-n1`** (scheduling). Built on an N2 runner but
  never with `native`, and never `-mcpu` (it would collide with ggml's own `-march`).
- Crate: `llama-cpp-sys-2` pinned tag `0.1.151`; features `common` (no `openmp` — ggml uses
  its built-in threadpool, so there is no libgomp/libomp runtime dependency).
- Compiler: **Clang 18** (AL2023 `clang18`), GNU libstdc++.
- Build image: `amazonlinux:2023` (aarch64), **resolved at build time** — not a controlled
  runtime pin. LTEmbed deploys on AWS-managed AL2023 (Lambda/Fargate) whose patch level AWS
  controls, so **consumers pin the release artifact checksum, not the build image digest**.
  The resolved digest, glibc, gcc/g++, runtime packages, and effective CPU flags are all
  recorded in `build-info.json` (`build_env`, `arch_flag_summary`). CI gates the observed
  environment against a supported envelope (`EXPECTED_CLANG_MAJOR`, `MIN_GLIBC` in
  `scripts/config.env`); an optional `AL2023_DIGEST` override forces a reproducible build.
  libstdc++ is linked **dynamically** by the consumer (see link line); no libgomp.

## How LTEmbed consumes a release (required steps)

1. **Download** the release tarball + `SHA256SUMS` for the pinned contract version.
2. **Verify before use (mandatory):**
   ```sh
   tar xzf static-llama-cpp-<tag>-aarch64-graviton2.tar.gz -C extracted/
   ( cd extracted && sha256sum -c SHA256SUMS )   # fail the build on mismatch
   ```
   Also assert `jq -r .artifact_contract_version extracted/build-info.json` equals the
   version LTEmbed supports.
3. **Link.** Copy `consume.build.rs` to your crate's `build.rs` and set
   `STATIC_LLAMA_DIR=/abs/path/to/extracted`. It emits the search path, the static libs in
   dependency order, and the C++/OS deps. Equivalent link line (also in `build-info.json`,
   and the single source of truth is `scripts/config.env`):
   ```
   -lllama-common -lllama -lggml -lggml-cpu -lggml-base -lstdc++ -lpthread -lm -ldl
   ```
4. **Bind.** Use the shipped `bindings.rs` (the build.rs exports its path as
   `STATIC_LLAMA_BINDINGS`):
   ```rust
   mod llama { include!(env!("STATIC_LLAMA_BINDINGS")); }
   ```
   The high-level `llama-cpp-2` safe API is **not** part of this contract; wrap the FFI
   yourself if you need a safe layer.

## Guarantees & non-guarantees

- **Guaranteed:** the archives were produced from the pinned inputs, passed the on-target
  smoke test (real embedding), and were within the benchmark regression threshold vs a
  from-source build (see `build-info.json.benchmark`).
- **Not guaranteed:** ABI stability across contract versions, or that a different glibc/
  compiler baseline links cleanly. Rebuild + re-pin when you move the runtime base.
