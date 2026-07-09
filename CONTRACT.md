# Artifact Contract — v3

This defines exactly what a release contains, how to link it, and how to verify it.
Both llama.cpp and `llama-cpp-rs` lack strong semver/ABI stability, so **consumers pin a
contract version** and re-verify on every bump.

## Contract version

`artifact_contract_version` (in `build-info.json`) is currently **`3`** (v1 → v2: Clang 18
compiler and OpenMP dropped, so `-lgomp` left the link line; v2 → v3: added the
numerical-correctness gate and the `correctness` block in `build-info.json`). It **must**
bump on any change to: the set of shipped `.a`, the link line, enabled cargo features, the
binding ABI (crate tag / llama.cpp submodule), the `dist/` layout, or the guarantees a
release carries. LTEmbed pins the contract version it supports and fails closed on an
unexpected value.

## Release layout (`dist/`)

```
lib/            libllama.a libggml.a libggml-cpu.a libggml-base.a
include/        llama.h ggml*.h ... (matching the pinned submodule)
bindings.rs     generated FFI bindings (bindgen, Consts enums, prepend_enum_name=false)
build-info.json full bill-of-materials + provenance + smoke/benchmark/correctness results
consume.build.rs drop-in build.rs (this repo's scripts/consume.build.rs)
CONTRACT.md     this file
SHA256SUMS      sha256 over every other file in the release
LICENSES/       llama.cpp, ggml, and builder licenses (all MIT)
```

## Build profile (v2)

- Target: `aarch64-unknown-linux-gnu`, tuned for Graviton2 / N1 via
  **`-O3 -march=armv8.2-a+fp16+dotprod+rcpc`** (ISA, incl. dotprod + LRCPC — also set through ggml's
  `GGML_CPU_ARM_ARCH`) **`-mtune=neoverse-n1`** (scheduling). Built on an N2 runner but
  never with `native`, and never `-mcpu` (it would collide with ggml's own `-march`).
- Crate: `llama-cpp-sys-2` pinned tag `0.1.151`; **no cargo features** (no `openmp` — ggml
  uses its built-in threadpool, no libgomp/libomp dep; no `common` — it would add a
  `llama_rs_*` wrapper archive + bindings decls not needed for direct FFI).
- Compiler: **Clang 18** (AL2023 `clang18`), GNU libstdc++.
- **PGO (optional, `PGO=1`):** an opt-in profile-guided-optimization build. `build.sh` does a
  3-phase build — instrument (`-fprofile-generate`) → train on the real embedding hot path
  (`scripts/pgo-train.cpp`, `llama_encode`) against `PGO_TRAIN_MODEL` → optimize
  (`-fprofile-use`). It changes **codegen only** — not the shipped `.a` set, link line,
  features, binding ABI, or `dist/` layout — so it does **not** bump the contract version.
  The profile is quant-type-specific (train on the deployed quant, e.g. IQ4_NL); its
  `sha256`, training model, and iteration count are recorded in `build-info.json`'s `pgo`
  block, and `bench.json` carries the measured `pgo_gain`. Default builds are non-PGO
  (`pgo.enabled = false`).
- Build image: `amazonlinux:2023` (aarch64), **resolved at build time and recorded** — not a
  reproducibility pin. LTEmbed deploys on AWS-managed AL2023 (Lambda/Fargate) whose patch
  level AWS controls, so **consumers pin the release artifact checksum, not the build image**.
  The resolved digest, glibc, compiler, exact package versions, and effective CPU flags are
  all recorded in `build-info.json` (`build_env`, `arch_flag_summary`) for traceability. CI
  gates the observed environment against a supported envelope (`EXPECTED_CLANG_MAJOR`,
  `MIN_GLIBC` in `scripts/config.env`). An optional `AL2023_DIGEST` override pins the base
  image for a run to aid tracing — **not a full reproducibility guarantee**, since `dnf`
  still pulls current packages from mutable repos (the resolved versions are recorded).
  libstdc++ is linked **dynamically** by the consumer (see link line); no libgomp.

## How LTEmbed consumes a release (required steps)

1. **Download** the release tarball, its `<tarball>.sha256`, and `SHA256SUMS`.
2. **Verify before use (mandatory):**
   ```sh
   T=static-llama-cpp-<tag>-aarch64-graviton2.tar.gz
   sha256sum -c "${T}.sha256"           # pin/verify the downloaded artifact first
   mkdir -p extracted && tar xzf "${T}" -C extracted/
   ( cd extracted && sha256sum -c SHA256SUMS )   # then verify extracted contents
   ```
   Also assert `jq -r .artifact_contract_version extracted/build-info.json` equals the
   version LTEmbed supports.
3. **Link.** Copy `consume.build.rs` to your crate's `build.rs` and set
   `STATIC_LLAMA_DIR=/abs/path/to/extracted`. It emits the search path, the static libs in
   dependency order, and the C++/OS deps. Equivalent link line (also in `build-info.json`,
   and the single source of truth is `scripts/config.env`):
   ```
   -lllama -lggml -lggml-cpu -lggml-base -lstdc++ -lpthread -lm -ldl
   ```
4. **Bind.** Use the shipped `bindings.rs` (the build.rs exports its path as
   `STATIC_LLAMA_BINDINGS`):
   ```rust
   mod llama { include!(env!("STATIC_LLAMA_BINDINGS")); }
   ```
   The high-level `llama-cpp-2` safe API is **not** part of this contract; wrap the FFI
   yourself if you need a safe layer.

## Correctness gate (v3)

A release fails unless the packaged archives compute the *right* embeddings — not merely
finite/fast ones. `scripts/correctness.sh` runs on the release runner and records a
`correctness` block in `build-info.json`. The target model is
**jina-embeddings-v5-text-nano-retrieval** (EuroBERT-210m, **last-token pooling**, dim 768,
task prefixes `Query: `/`Document: `). Checks run against a pinned reference GGUF and
additionally the deployed smoke/PGO model:

- **Tuned-vs-generic parity (§2):** a second archive set built from source with generic
  `-march=armv8-a` (scalar/generic kernels) on the *same host*; the tuned archives must
  match it at **cosine ≥ 0.999**. Any divergence is purely the tuning/codegen flags — the
  `v0.1.151-1` failure class.
- **FP32 golden parity (§1):** cosine **≥ 0.98** (IQ4_NL quant vs FP32) between the packaged
  archives' embeddings and committed golden vectors produced offline by the **FP32 PyTorch**
  model via sentence-transformers (`scripts/gen-golden.py` → `correctness/fixtures/golden.tsv`).
  Independent of the GGUF/llama.cpp path — it mirrors the downstream GGUF-vs-FP32 benchmark
  that caught `v0.1.151-1`. Until that file has data rows the golden check is recorded as
  `not_generated` and is non-fatal, while §2 and §4 still gate.
- **Modes & inputs (§3):** both **MEAN** and **LAST** pooling with **NON_CAUSAL** attention
  (LAST is jina's deployment pooling), single-sequence and batched, over diverse query/
  document inputs including non-ASCII/CJK. The jina task prompt is applied per role: the
  llama.cpp side prepends the literal `Query: `/`Document: `, and the FP32 golden uses
  sentence-transformers `prompt_name` (which applies the same strings).
- **Self-consistency (§4):** determinism (identical bytes), batch-invariance, and
  thread-invariance within eps, plus a coarse semantic-sanity check (paraphrase cosine >
  unrelated cosine) that catches a fully collapsed/scrambled space with no external reference.

**Hardware coverage (§5):** the gate runs on the GitHub-hosted **Neoverse-N2** runner. The
deploy target is Graviton2 / **Neoverse-N1**, and a codegen/microarch fault can differ
between N1 and N2. Running the gate on a real Graviton2/N1 host is **not yet covered** — this
is a known gap (`build-info.json.correctness.hardware_coverage`). A disabled-by-default
self-hosted N1 job exists in `release.yml` (`ENABLE_N1_CORRECTNESS=1`) to close it once a
runner is provisioned.

## Guarantees & non-guarantees

- **Guaranteed:** the archives were produced from the pinned inputs, passed the on-target
  smoke test (real embedding), were within the benchmark regression threshold vs a
  from-source build (see `build-info.json.benchmark`), and passed the correctness gate above
  (`build-info.json.correctness.passed == true`).
- **Not guaranteed:** ABI stability across contract versions, correctness on a
  microarchitecture other than the one the gate ran on (see §5), or that a different glibc/
  compiler baseline links cleanly. Rebuild + re-pin when you move the runtime base.
