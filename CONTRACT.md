# Artifact Contract — v7

This defines exactly what a release contains, how to link it, and how to verify it.
Both llama.cpp and `llama-cpp-rs` lack strong semver/ABI stability, so **consumers pin a
contract version** and re-verify on every bump.

## Contract version

`artifact_contract_version` (in `build-info.json`) is currently **`7`**. It **must** bump on
any change to: the set of shipped `.a`, the link line, enabled cargo features, the binding
ABI (llama-cpp-rs commit / compiled llama.cpp commit), the `dist/` layout, or the
guarantees a release carries. LTEmbed pins the contract version it supports and fails
closed on an unexpected value.

| Version | Change |
| --- | --- |
| v2 | Clang 18 compiler; OpenMP dropped, so `-lgomp` left the link line. |
| v3 | Added the numerical-correctness gate and the `correctness` block in `build-info.json`. |
| v4 | **llama.cpp `v0.6.0` (`d81235049384534c167caea52b85a694f6103d14`)**, compiled through llama-cpp-rs `0.1.159` (`3cfdd729d65e35da407e5f820edf73201bfa54f6`) with its vendored llama.cpp submodule (`26394b4e`) replaced by the tag. `bindings.rs` and `include/` are regenerated from the new `llama.h`/`ggml*.h`: **binding ABI changed — rebuild consumers against the new `bindings.rs`.** The crate is now built with `--no-default-features`. Its default feature set is `["common"]`, which pre-v4 releases silently enabled, so their `bindings.rs` also carried `llama_rs_*` declarations that no shipped archive defines; v4 drops them and gates on their absence. `build-info.json` provenance is restructured into `llama_cpp_rs` / `llama_cpp_sys_2` / `llama_cpp` blocks, with fail-closed tag/commit verification: `llama_cpp_sys_2.git_tag` and `llama_cpp.submodule_commit` are removed, replaced by `llama_cpp_rs.git_ref`/`.commit` and `llama_cpp.tag`/`.commit`. (v3 shipped `llama-cpp-sys-2` 0.1.151 with its vendored llama.cpp `9e3b928`.) **Second production variant: x86-64.** v4 adds `x86_64-unknown-linux-gnu` at the fixed `x86-64-v3` baseline, shipped as `static-llama-cpp-<tag>-x86_64-v3-linux-gnu.tar.gz` next to the unchanged `static-llama-cpp-<tag>-aarch64-graviton2.tar.gz`. Each variant is built natively on its own architecture. `build-info.json` gains `target_profile`, `architecture`, `cpu_baseline`, `cpu_profile`, `host`, `runner`, `pgo.architecture`/`.cpu_baseline`/`.use_flags` and the x86 `arch_flag_summary` keys. Because both variants share one GitHub Release, the loose release assets are per-variant: `build-info-<variant>.json` and `SHA256SUMS-<variant>`. **Unchanged:** the `.a` set, the link line and order, the ARM64 CPU profile, the toolchain (Clang 18, glibc ≥ 2.34) and the correctness thresholds. |
| v5 | **llama.cpp `b11577` (`cbe28bb3cb0758f0c566a9a3561766821aeb0748`)**, containing EmbeddingGemma 2 support. `bindings.rs` and `include/` are regenerated: **binding ABI changed — rebuild consumers against the shipped `bindings.rs`.** `llama_context_params` gains `moe_cache_size: usize` after `type_v`, shifting every later field (160 → 168 bytes); it is returned by value from `llama_context_default_params` and passed by value to `llama_init_from_model`. `llama_perf_context_data` gains `n_reallocs_same`/`n_reallocs_diff` (48 → 56 bytes, returned by value from `llama_perf_context`). `ggml_backend_sched_set_copy_callback`, `ggml_backend_sched_set_realloc_callback` and `LLAMA_VOCAB_TYPE_PLAMO3` are added; `llama_model_params` is unchanged. Sizes are the same on both 64-bit variants. The tag is lightweight, so `llama_cpp.tag_type` is now the pinned Git object type `commit` (v4: `tag`); the tag must still resolve to the exact pinned commit and match `describe --exact-match`. `llama_cpp.embedded_version` becomes a fail-closed gate on the separately pinned semantic version `0.6.0[-dev]`, because nightly tag numbers are not versions. A second required text-only smoke result, `embeddinggemma_smoke`, records the pinned ggml-org Q8_0 model identity/hash and full projected dimensions (hidden 512, output 768). The original `smoke` result also gains `n_embd_out` and the actual `model_sha256`. **Unchanged:** native profiles, the `.a` set, the link line and order, the no-default-features configuration and the legacy numerical/performance thresholds. This contract does not claim EmbeddingGemma 2 FP32 parity or multimodal coverage. |
| v6 | **llama.cpp `b11630` (`6868a52cb337450658006ad2f9281c2eb63f1666`)**, unmodified upstream, compiled through the same llama-cpp-rs `0.1.159` driver. **Output semantics changed:** a context with `embeddings = true` and a pooling type other than `NONE` no longer builds the LM head or reserves host logits (upstream [#30255](https://github.com/ggml-org/llama.cpp/pull/30255), [#30445](https://github.com/ggml-org/llama.cpp/pull/30445); [#30461](https://github.com/ggml-org/llama.cpp/pull/30461) drops a redundant graph expansion from the embedding models), so `llama_get_logits` returns `NULL` after a pooled encode or decode. v5 reserved and zeroed `n_vocab` floats per output token anyway: 1 MiB per input token for EmbeddingGemma 2, 8 GiB at 8192 tokens. Generation and `NONE`-pooled embeddings still get logits; see [Output semantics](#output-semantics-v6). Both smoke results gain `host_logits: false`, and a fifth required result, `logits_smoke`, records the output modes of a pinned generative model that has an LM head. **Binding ABI unchanged:** `bindings.rs` is byte-identical to v5's on both variants, and `include/` differs only in two comments (`llama.h`, on the `embeddings` field; `ggml.h`, a `ggml_mul_mat_id` note). The archives define no new or removed symbol that a shipped header declares. The new global symbols are all internal: mangled C++ symbols, the ggml-cpu kernel `ggml_vec_dot_q2_0_q8_0_generic` (x86_64 only), and three unmangled C++ globals from llama.cpp's internal `unicode-data.h` (`unicode_combining_class`, `unicode_composition`, `unicode_decomposition`, the Unicode normalization tables), which a statically linked consumer must not define itself. **Unchanged:** native profiles, the `.a` set, the link line and order, features, the pinned build driver and every numerical/performance threshold. |
| v7 | **llama.cpp `v0.7.0` (`620d2225cc436ab0b001e3200e590e3b286ef9ab`)**, unmodified upstream (ggml `0.27.0`; the same commit as nightly `b11669`), compiled through llama-cpp-rs **`0.1.160`** (`0dd5814c9b061930965d144c1653cd4d05054873`), whose vendored llama.cpp (`d8123504`, `v0.6.0`) is still replaced by the tag. `v0.7.0` is an annotated release tag, so `llama_cpp.tag_type` is the pinned Git object type `tag` (v5/v6: `commit`), and its tag object must name `v0.7.0`. `llama_cpp.embedded_version` is `0.7.0-dev` (pin `0.7.0[-dev]`). **Binding ABI unchanged:** `bindings.rs` is byte-identical to v6's on both variants, and `include/` differs only in two comments (`llama.h`, on `llama_batch_ext_set_embd_state`; `ggml.h`, on `ggml_gated_delta_net`). No archive symbol is removed. The added global symbols are mangled C++ internals: the new `maion-coder` model architecture and one `std::vector` instantiation. Two upstream changes are visible through the unchanged API. llama.cpp's UTF-8 decoder, used by tokenization, now rejects overlong and out-of-range sequences, so those malformed bytes tokenize as U+FFFD; well-formed UTF-8, including any Rust `&str`, is unaffected. On x86-64, scalar FP16 → FP32 conversion reads ggml's lookup table instead of using F16C; both are exact. The driver's 0.1.160 changes (Emscripten, WebGPU, PowerPC `-mcpu`, the Android NDK triple) do not apply to either Linux profile, except that it now passes an explicit `GGML_WEBGPU=OFF`, which is ggml's default. **Unchanged:** output semantics, native profiles, the `.a` set, the link line and order, features and every numerical/performance threshold. |

## Support matrix

| Architecture | Target | CPU baseline | Native build requirement |
| --- | --- | --- | --- |
| ARM64 | `aarch64-unknown-linux-gnu` | `armv8.2-a+fp16+dotprod+rcpc`, `-mtune=neoverse-n1` | native ARM64 host |
| x86-64 | `x86_64-unknown-linux-gnu` | `x86-64-v3` (generic tuning) | native x86-64 host that is x86-64-v3 capable |

Supported x86 baseline: x86-64-v3

CPUs older than x86-64-v3 are intentionally unsupported.

A release carries exactly these two variants:

| Variant (`target_profile`) | Tarball |
| --- | --- |
| `aarch64-graviton2` | `static-llama-cpp-<tag>-aarch64-graviton2.tar.gz` |
| `x86_64-v3` | `static-llama-cpp-<tag>-x86_64-v3-linux-gnu.tar.gz` |

**Build-only profile, outside this contract.** `scripts/config.env` also defines
`aarch64-apple-darwin`, a native CPU-only build for Apple Silicon macOS (`apple-m1` CPU
baseline, pinned minimum macOS). It is not a release variant and carries none of the
guarantees below. Its `build-info.json` records `"build_only": true` and
`"artifact_contract_version": null`, no release ships it, and `package.sh` and
`verify-provenance.sh --packaged` refuse it. Releasing it is a contract change (issue #22).

There is no x86-64-v2 or generic x86 variant, and no runtime ISA dispatch or fallback. The
x86-64 archives execute AVX/AVX2/BMI1/BMI2/F16C/FMA/LZCNT/MOVBE instructions
unconditionally and fault (SIGILL) on a CPU below x86-64-v3. The required baseline is part
of this contract: it is fixed in `scripts/config.env` and never chosen from the build machine
or negotiated by CI.

## Release layout (`dist/`)

```
lib/            libllama.a libggml.a libggml-cpu.a libggml-base.a
include/        llama.h ggml*.h gguf.h ... (from the compiled llama.cpp tag/commit)
bindings.rs     generated FFI bindings (bindgen, Consts enums, prepend_enum_name=false)
build-info.json full bill-of-materials + provenance + smoke/embeddinggemma_smoke/logits_smoke/benchmark/correctness results
consume.build.rs drop-in build.rs (this repo's scripts/consume.build.rs)
CONTRACT.md     this file
SHA256SUMS      sha256 over every other file in the release
LICENSES/       llama.cpp (covers ggml) and builder licenses (all MIT)
```

## Build profile (v7)

- **Native build only.** Each variant is compiled on a host of its own architecture, for that
  host's triple: actual host arch == container arch == compiler arch == artifact arch. These
  are unsupported:
  - cross compilation in either direction (x86 → ARM, ARM → x86): `--target` to a foreign
    arch, cross gcc, `CMAKE_TOOLCHAIN_FILE`/`CMAKE_SYSTEM_PROCESSOR`, cross-rs,
    cargo-zigbuild, zig;
  - CPU emulation: QEMU, binfmt_misc, Docker Buildx architecture emulation,
    `docker --platform` for a foreign arch.

  `scripts/lib.sh` `assert_native_host`, the Dockerfile, and
  `scripts/assert-native-runner.sh <arch>` (CI) all fail closed otherwise. `assert_native_host`
  checks `uname -m`, the kernel arch, binfmt_misc, rustc's host triple, the compilers'
  `-dumpmachine` and the absence of cross knobs. The CMake cache must also report
  `CMAKE_CROSSCOMPILING=FALSE` with matching system and host processors.
- **x86-64 host gate (fail-closed).** `uname -m` alone is not trusted, since an x86_64 host
  may be v1/v2 only. `scripts/check-x86-64-v3.sh` runs before any compile, in CI and in the
  container, and requires three checks to agree:
  - CPUID + XGETBV: the v2 set plus AVX, AVX2, BMI1, BMI2, F16C, FMA, LZCNT, MOVBE,
    XSAVE/OSXSAVE, and OS-enabled AVX state;
  - glibc's hwcaps (`ld.so --help`) reporting x86-64-v3 supported;
  - `/proc/cpuinfo`.

  It logs `Host architecture: x86_64`, `Required CPU baseline: x86-64-v3` and
  `x86-64-v3 capability: PASS`. A host that fails is refused with *"ERROR: native x86 build
  requires an x86-64-v3 capable CPU. This project intentionally does not support x86-64-v2
  or older hosts."* No artifact is produced by forcing `-march=x86-64-v3` on such a host. The
  result is recorded in `build-info.json` as `host.cpu_capability`.
- **ARM64 target:** `aarch64-unknown-linux-gnu`, tuned for Graviton2 / N1 via
  **`-O3 -march=armv8.2-a+fp16+dotprod+rcpc`** (ISA, incl. dotprod + LRCPC — also set through ggml's
  `GGML_CPU_ARM_ARCH`) **`-mtune=neoverse-n1`** (scheduling). Built on an N2 runner but
  never with `native`, and never `-mcpu` (it would collide with ggml's own `-march`).
- **x86-64 target:** `x86_64-unknown-linux-gnu`, **`-O3 -march=x86-64-v3`**, with no
  `-mtune`: ISA baseline = x86-64-v3, microarchitecture tuning = generic/default. It is never
  `native`, never `-march=x86-64`/`-v2`/`-v4`, and has no vendor tuning. ggml is configured
  with `GGML_NATIVE=OFF` (no host autodetection) and an explicit, fixed ISA option set:
  - ON: `GGML_SSE42`, `GGML_AVX`, `GGML_AVX2`, `GGML_BMI2`, `GGML_FMA`, `GGML_F16C`;
  - OFF: `GGML_AVX_VNNI`, `GGML_AVX512*` and `GGML_AMX_*`.

  Its CPU TUs' `-m` flags are therefore a subset of x86-64-v3. Without `GGML_BACKEND_DL`
  there is no runtime ISA dispatch.
- Engine: **llama.cpp `v0.7.0`** (annotated release tag, exact Git object type `tag`) at
  commit **`620d2225cc436ab0b001e3200e590e3b286ef9ab`** from `ggml-org/llama.cpp`, unmodified.
  Only that tag is fetched. Before compiling, the build verifies that `HEAD` equals that
  commit, that the tag peels to it, that the tag object names `v0.7.0`, and that
  `git describe --tags --exact-match` is `v0.7.0`. After compiling, it verifies that the
  generated `llama-version.h` embeds the same commit and the separately pinned semantic
  version `0.7.0` or `0.7.0-dev`. The version is never inferred from a tag, directory
  name, crate version or release name.
- Build driver: `llama-cpp-sys-2` from llama-cpp-rs, git tag **`0.1.160`** (a lightweight
  tag; verified to resolve to commit **`0dd5814c9b061930965d144c1653cd4d05054873`**, package
  version `0.1.160`). The crate pins `d8123504` (llama.cpp `v0.6.0`), not `v0.7.0`. The
  build therefore verifies that gitlink and then replaces it with the `v0.7.0` checkout
  (both commits are recorded). Its `build.rs`
  hardcodes `GGML_CPU_ARM_ARCH=armv8-a`, so on ARM64 that one literal is rewritten to the
  N1 ISA under an exact-count check. On x86-64 the crate adds no `-march` (it only does so
  for Android).
- Built with **`--no-default-features` and no cargo features**:
  - No `openmp`: ggml uses its built-in threadpool, so there is no libgomp/libomp dependency.
  - No `common`: it is in the crate's default set and would add `LLAMA_BUILD_COMMON`, a
    `llama_rs_*` wrapper archive and bindings declarations not needed for direct FFI.
- Build-time gates (all fatal):
  - **CMake cache:**
    - `CMAKE_BUILD_TYPE=Release`, `CMAKE_CROSSCOMPILING=FALSE`, and system/host processor ==
      the target arch.
    - OFF: `GGML_NATIVE`, `GGML_OPENMP`, `GGML_LTO`, `GGML_BACKEND_DL`,
      `GGML_CPU_ALL_VARIANTS`, `BUILD_SHARED_LIBS` and `LLAMA_BUILD_COMMON`.
    - ARM64: `GGML_CPU_ARM_ARCH` = the N1 ISA. ggml's ISA probes report dotprod and fp16
      enabled, and SVE, i8mm and SME disabled.
    - x86-64: every ggml ISA option equals the fixed set above.
  - **Embedded version:** the commit in `llama-version.h` matches the pin.
  - **Compile flags:** every compile command is checked:
    - No `native`, `-flto`, OpenMP or stray `-fprofile-generate`.
    - No `-mcpu`, no `-march` other than the profile's exact string, and no `--target` for a
      foreign arch.
    - Every C/C++ TU uses `-O3`, plus `-fprofile-use` in a PGO build.
    - ARM64: every C/C++ TU uses `-mtune=neoverse-n1`.
    - x86-64: every C/C++ TU carries `-march=x86-64-v3`, there is no `-mtune`, and every
      other `-m` flag is in the x86-64-v3 feature set. No AVX-512/AMX/AVX-VNNI defines are
      allowed.
    - x86-64 effective ISA: for each distinct compiler + `-m` flag set, the compiler's
      predefined macros must contain every x86-64-v3 feature and none above it (AVX-512*,
      AVX10, AMX, AVX-VNNI, SHA, AES, …). This is recorded as
      `arch_flag_summary.effective_isa = "x86-64-v3"`.
  - **x86-64 instruction scan:** `objdump -d` of the four archives must contain no EVEX
    (AVX-512) encoding, no zmm/mask/upper-16 vector register, and no AMX, VNNI, IFMA,
    BF16/NE-convert, crypto, ADX, RDRAND/RDSEED, SSE4a, FMA4, XOP or TBM instruction. This is
    recorded as `arch_flag_summary.disassembly`.
  - **Archives and bindings:**
    - The installed `.a` set equals exactly the four archives above.
    - `bindings.rs` declares no `llama_rs_*`/`mtmd_*` items.
  - **Environment:** `GGML_*`, `CMAKE_*`, `LLAMA_*`, crate env knobs and a rustc
    `target-cpu`/`target-feature` in the environment are refused, because the crate's
    `build.rs` would forward them into the build.
- Compiler: **Clang 18** (AL2023 `clang18`), GNU libstdc++.
- **PGO (optional, `PGO=1`):** an opt-in profile-guided-optimization build. `build.sh` does a
  3-phase build — instrument (`-fprofile-generate`) → train on the real embedding hot path
  (`scripts/pgo-train.cpp`, `llama_encode`) against `PGO_TRAIN_MODEL` → optimize
  (`-fprofile-use`). It changes **codegen only** — not the shipped `.a` set, link line,
  features, binding ABI, or `dist/` layout — so it does **not** bump the contract version.
  The profile is quant-type-specific (train on the deployed quant, e.g. IQ4_NL); its
  `sha256`, training model, and iteration count are recorded in `build-info.json`'s `pgo`
  block, and `bench.json` carries the measured `pgo_gain`. Default builds are non-PGO
  (`pgo.enabled = false`). Profiles are per architecture:
  - each variant trains on its own native host;
  - the x86-64 profile comes from an instrumented `-O3 -march=x86-64-v3` build on a v3
    host;
  - `pgo.architecture` and `pgo.cpu_baseline` record which variant it is for;
  - an ARM64 profile is never applied to x86-64, or vice versa (`bench.sh` checks
    `pgo.meta.json`).
- Build image: `amazonlinux:2023` of the host's own arch, **resolved at build time and recorded** — not a
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
   T=static-llama-cpp-<tag>-aarch64-graviton2.tar.gz   # or ...-x86_64-v3-linux-gnu.tar.gz
   sha256sum -c "${T}.sha256"           # pin/verify the downloaded artifact first
   mkdir -p extracted && tar xzf "${T}" -C extracted/
   ( cd extracted && sha256sum -c SHA256SUMS )   # then verify extracted contents
   ```
   Also assert `jq -r .artifact_contract_version extracted/build-info.json` equals the
   version LTEmbed supports, and (recommended) `jq -r .llama_cpp.commit` equals the engine
   commit you validated against. Also check `jq -r .target_profile` is the variant you expect
   (`aarch64-graviton2` / `x86_64-v3`). `scripts/verify-provenance.sh --packaged
   <build-info.json> <profile>` (bash + jq) checks every pin in `build-info.json` against
   this repo's `scripts/config.env`. It also requires the five release results (`smoke`,
   `embeddinggemma_smoke`, `logits_smoke`, `benchmark`, `correctness`) to be present with
   `passed == true`, and the three smoke results to match their pins, including the output
   semantics below. A downloaded release is always packaged, and
   `--packaged` is the default. `--raw` is for fresh `build.sh` output, before any results
   exist, and is not a release check.
3. **Link.** Copy `consume.build.rs` to your crate's `build.rs` and set
   `STATIC_LLAMA_DIR=/abs/path/to/extracted`. It emits the search path, the static libs in
   dependency order, and the C++/OS deps. Equivalent link line (also in `build-info.json`,
   and the single source of truth is `scripts/config.env`):
   ```
   -lllama -lggml -lggml-cpu -lggml-base -lstdc++ -lpthread -lm -ldl
   ```
   `consume.build.rs` chooses the system libraries by the target OS, and for a Linux
   target it emits exactly this line. Its macOS branch (`-lc++` only) exists for the
   build-only `aarch64-apple-darwin` profile, which is outside this contract. Any other
   target OS fails the build script.
4. **Bind.** Use the shipped `bindings.rs` (the build.rs exports its path as
   `STATIC_LLAMA_BINDINGS`):
   ```rust
   mod llama { include!(env!("STATIC_LLAMA_BINDINGS")); }
   ```
   The high-level `llama-cpp-2` safe API is **not** part of this contract; wrap the FFI
   yourself if you need a safe layer.

## Output semantics (v6)

What a context exposes on the host after `llama_encode` / `llama_decode`, by its
`llama_context_params` (since llama.cpp `b11630`, upstream
[#30255](https://github.com/ggml-org/llama.cpp/pull/30255) and
[#30445](https://github.com/ggml-org/llama.cpp/pull/30445)):

| `embeddings` | `pooling_type` | Host logits (`llama_get_logits`) | Embeddings |
| --- | --- | --- | --- |
| `false` | any | `n_vocab` floats per output token | none |
| `true` | `NONE` | `n_vocab` floats per output token, as before | per token (`llama_get_embeddings_ith`) |
| `true` | `MEAN`, `CLS`, `LAST`, `RANK` | **none: `llama_get_logits` returns `NULL`** | per sequence (`llama_get_embeddings_seq`) |

- A pooled embeddings context no longer builds the LM head into its graph and reserves no
  host logits buffer. In v5 every pooled encode still reserved and zeroed `n_vocab` floats
  per token, which an embedding model without an LM head never even filled. For
  EmbeddingGemma 2 (`n_vocab` 262144) that was 1 MiB per input token, 8 GiB at 8192
  tokens, and the buffer never shrank until the context was freed. Read pooled
  output with `llama_get_embeddings_seq` at the `llama_model_n_embd_out` width; nothing a
  pooled context produces is read through `llama_get_logits*`.
- Toggling `llama_set_embeddings` on a pooled context re-reserves its graph: `false` brings
  the LM head and host logits back, and `true` removes them again.
- Upstream keeps host logits for T5-architecture (encoder–decoder) models in every mode. No
  release gate covers T5.
- The release gates check `MEAN` on all three smoke runs: both pooled smoke runs (`smoke`,
  `embeddinggemma_smoke`) fail if `llama_get_logits` is not `NULL` after the encode, and
  record `host_logits: false`. The generative control below also checks `LAST` and `CLS`.
  `RANK` needs a reranker's classification head; it follows the same upstream rule, but no
  gate checks it. The correctness gate compares `MEAN` and `LAST` embedding values and does
  not inspect logits.

The pinned EmbeddingGemma 2 and legacy models have no LM head, so neither can show that
logits survived where they are still computed. `scripts/logits-smoke.sh` therefore runs a
generative control model pinned in `scripts/config.env` (`LOGITS_SMOKE_*`): karpathy's
tinyllamas `stories260K`, in the GGUF that llama.cpp's own CI uses (`ggml-org/models-moved`
revision `499bc8821c6b12b4e53c5bffcb21ec206f212d81`, SHA-256-checked; llama architecture,
`n_vocab` 512, with an `output.weight` LM head). It decodes one prompt in each mode below and
requires `llama_get_logits` to match:

| `host_logits` key | Context | Host logits |
| --- | --- | --- |
| `generation` | `embeddings = false` | yes, `n_vocab` finite, non-constant values |
| `embeddings_none` | `embeddings = true`, `NONE` (with per-token embeddings) | yes |
| `embeddings_mean` | `embeddings = true`, `MEAN` (with a pooled embedding) | no (`NULL`) |
| `embeddings_mean_set_off` | the `MEAN` context after `llama_set_embeddings(false)` | yes |
| `embeddings_mean_set_on` | the same context after `llama_set_embeddings(true)` | no; the pooled embedding equals `embeddings_mean`'s |
| `embeddings_last` | `embeddings = true`, `LAST` (with a pooled embedding) | no (`NULL`) |
| `embeddings_cls` | `embeddings = true`, `CLS` (with a pooled embedding) | no (`NULL`) |

The last-token logits of the three modes that have them must agree within `1e-3`
(`max_logit_delta`), so a mode cannot pass with logits from a different computation. The
result is required as `build-info.json.logits_smoke`, and its `host_logits` map must equal
this table. The control model is a test input only, not shipped, and says nothing about
generation quality.

## EmbeddingGemma 2 text liveness gate (v5)

`scripts/embeddinggemma-smoke.sh` fetches the exact Q8_0 text GGUF pinned in
`scripts/config.env` from `ggml-org/embeddinggemma-2-GGUF` revision
`bfcd298762cc34d0357ece5ebdd31791a3a374d8`. That conversion records Google source
revision `914f7f89142e33e77833254d9c9b90c3cef7303b`. Its SHA-256 is checked before
inference and recomputed by the smoke binary for its result. It runs with **MEAN
pooling, NON_CAUSAL attention, hidden width 512 and pooled/projected output width
768**. A short 128-token context avoids allocating the GGUF's full training window.
The entire 768-element output must be finite and nonzero; the old hidden-width
buffer read would only check 512 elements and is no longer used.

Packaging requires `RESULTS/embeddinggemma-smoke.json` with a passing result,
matching model identity/hash and dimensions. It is merged into
`build-info.json.embeddinggemma_smoke`, alongside (not replacing) the original
`smoke`, `logits_smoke`, `benchmark` and `correctness` records. Since v6 it also records
`host_logits: false`: the encode left no host logits (see below). `scripts/verify-provenance.sh
--packaged` requires it, with the same pins, after packaging and again before
publication. Both native CI variants run the new test before packaging; pull
requests run the matrix without publishing.

This fixture is **text-only liveness and shape coverage**. It does not run the
vision/audio projectors, validate prompt/tokenizer parity, prove FP32 embedding
accuracy, or guarantee a 250 MB application size budget (Q8_0 alone is about 310 MB).
The legacy Jina numerical fixture below remains unchanged to guard the runtime
upgrade. Downstream EmbeddingGemma 2 migration must add independent reference
embeddings and validate its new semantics before selecting it for production.
The model weights are test inputs and are not included in the native artifact.

## Correctness gate (v3)

A release fails unless the packaged archives compute the *right* embeddings — not merely
finite/fast ones. `scripts/correctness.sh` runs on the release runner and records a
`correctness` block in `build-info.json`. The target model is
**jina-embeddings-v5-text-nano-retrieval** (EuroBERT-210m, **last-token pooling**, dim 768,
task prefixes `Query: `/`Document: `). Checks run against a pinned reference GGUF and
additionally the deployed smoke/PGO model:

- **Tuned-vs-generic parity (§2):** a second archive set is built from source on the *same
  host*, from the same revision, with generic flags:
  - ARM64: `-march=armv8-a` (scalar/generic kernels);
  - x86-64: `-O3 -march=x86-64` with every ggml x86 ISA option OFF, gated to carry no
    v2/v3 feature.

  The tuned archives must match it at **cosine ≥ 0.999**. Any divergence is purely the
  tuning/codegen flags, the `v0.1.151-1` failure class. The generic build is a
  **non-production comparison reference only**: it is not an artifact, it is never
  published, it is not part of the support matrix, and it does not mean older x86 CPUs are
  supported (`correctness.generic_reference.production/published/supported = false`).
- **FP32 golden parity (§1):** cosine **≥ 0.98** between the packaged archives' embeddings
  and committed golden vectors produced offline by the **FP32 PyTorch** model via
  sentence-transformers (`scripts/gen-golden.py` → `correctness/fixtures/golden.tsv`).
  Independent of the GGUF/llama.cpp path — it mirrors the downstream GGUF-vs-FP32 benchmark
  that caught `v0.1.151-1`. The golden check is **required on every run and is never
  skipped**: `scripts/correctness.sh` fails, naming `correctness/fixtures/golden.tsv`, when
  that file is missing, has no data rows (truncated, emptied or comment-only), or when its
  label set does not equal every `inputs.tsv` row × `last` (fail-closed in both directions,
  naming the labels). `correctness.golden_parity.status` is therefore always `checked`, and
  `correctness.golden_parity.reference.passed` carries the result; a release with
  `correctness.passed == true` has passed golden parity. (Before issue #9 a golden with no
  data rows was recorded as a non-fatal `not_generated`; that status is no longer reachable.
  No published release ever carried it: `v0.1.151-2`, the first release with the gate, was
  built from the populated golden.)
  - **Threshold justification (0.98, vs issue #4's 0.99):** the deployed/reference GGUF is
    **IQ4_NL — a 4-bit quantization**, so `cosine(IQ4_NL, FP32)` is floored by quantization
    error, not runtime error (measured worst input `0.9845`; issue #4's `0.99` assumed a
    higher-fidelity quant). That the gap is *quantization* and not a codegen fault is proven
    on the same run by §2 (tuned-vs-generic `0.99981` — the two builds agree) and by the
    `v0.1.151-1` garbage being `~0.31` — so `0.98` rejects that failure class with ~0.67
    margin while not false-failing on legitimate 4-bit quantization.
  - **Coverage of the deployed model:** `scripts/correctness.sh` **requires the deployed
    `SMOKE_MODEL` to be byte-identical (sha256) to the pinned golden reference GGUF**, so the
    single golden comparison authoritatively covers the deployed model — a bug specific to
    the deployed model cannot ship golden-unchecked. Deploying a different quant requires a
    golden for it.
- **Modes & inputs (§3):** both **MEAN** and **LAST** pooling with **NON_CAUSAL** attention
  (LAST is jina's deployment pooling), single-sequence and batched, over diverse query/
  document inputs including non-ASCII/CJK. The jina task prompt is applied per role: the
  llama.cpp side prepends the literal `Query: `/`Document: `, and the FP32 golden uses
  sentence-transformers `prompt_name` (which applies the same strings).
- **Self-consistency (§4):** determinism (identical bytes), batch-invariance, and
  thread-invariance within eps, plus a coarse semantic-sanity check (paraphrase cosine >
  unrelated cosine) that catches a fully collapsed/scrambled space with no external reference.

**Hardware coverage (§5):** the x86-64 gate runs on the x86-64-v3 runner that built the
variant. Its CPU model is recorded, and correctness is not claimed on other x86
microarchitectures. The ARM64 gate runs on the GitHub-hosted **Neoverse-N2** runner. The
deploy target is Graviton2 / **Neoverse-N1**, and a codegen/microarch fault can differ
between N1 and N2. Running the gate on a real Graviton2/N1 host is **not yet covered** — this
is a known gap (`build-info.json.correctness.hardware_coverage`). A disabled-by-default
self-hosted N1 job exists in `release.yml` (`ENABLE_N1_CORRECTNESS=1`) to close it once a
runner is provisioned.

## Provenance (`build-info.json`, v7)

| Field | Meaning |
| --- | --- |
| `llama_cpp.tag` / `.tag_type` / `.commit` / `.describe` | The compiled engine: the requested tag, its Git object type (must equal the pinned `EXPECTED_LLAMA_CPP_TAG_TYPE`: `tag` for the annotated release tag `v0.7.0`, whose tag object must also name it; `commit` for a lightweight nightly tag such as v6's `b11630`), the verified `HEAD`, and the `git describe --tags --exact-match` output. |
| `llama_cpp.embedded_version` / `.embedded_commit` | `LLAMA_VERSION` / `LLAMA_COMMIT` from the generated `llama-version.h`; both are gated. The version must equal the pinned `EXPECTED_LLAMA_CPP_VERSION` (`0.7.0`), optionally with the `-dev` suffix llama.cpp gives tree builds (`v0.7.0` reports `0.7.0-dev`). It is pinned separately and never inferred from the tag name; nightly tag numbers are not semantic versions at all. The commit must be a prefix (at least 7 hex digits) of `llama_cpp.commit`. |
| `llama_cpp_rs.git_ref` / `.git_ref_type` / `.commit` | The build driver: the requested ref (a tag), its type, and the commit it resolved to. |
| `llama_cpp_rs.vendored_llama_cpp_commit` / `.vendored_llama_cpp_overridden` | The crate's own llama.cpp gitlink. It is recorded but **not** compiled when `overridden` is `true`. |
| `llama_cpp_sys_2.version` / `.default_features` / `.features` | The crate package version and its feature selection (`false` / `[]`). |
| `target_profile` / `architecture` / `target_triple` | The variant (`aarch64-graviton2` / `x86_64-v3`), its architecture (`aarch64` / `x86_64`) and triple. |
| `cpu_baseline` / `cpu_profile` / `effective_arch_flags` | The CPU contract: `armv8.2-a+fp16+dotprod+rcpc` / `neoverse-n1` / `-O3 -march=armv8.2-a+fp16+dotprod+rcpc -mtune=neoverse-n1`, or `x86-64-v3` / `x86-64-v3` / `-O3 -march=x86-64-v3`. The same for a PGO build: its extra flags are in `pgo.use_flags`. |
| `host.architecture` / `.native_build` / `.cpu_model` / `.cpu_capability` | The build host: its arch (== `architecture`), `true`, its CPU, and (x86-64) the x86-64-v3 gate result (`baseline`, `result: "PASS"`, per-check status, features). |
| `build_env.host_arch` / `.native_build` | The build host's architecture, and `true` for a native build. |
| `arch_flag_summary` | Per-TU flag-gate counts. On x86-64 it adds `march`, `mtune: null`, `ggml_isa_tus`, `effective_isa_flag_sets`, `effective_isa: "x86-64-v3"` and `disassembly` (`instructions` scanned, `above_v3: 0`). |
| `pgo.architecture` / `.cpu_baseline` | For a PGO build, the variant the profile was trained for (`null` when PGO is off). |
| `pgo.use_flags` | For a PGO build, the flags added on top of `effective_arch_flags` (`-fprofile-use=…` and its warning flags; `null` when PGO is off). |
| `runner` | Where the build ran: `kind` (`github-hosted` / `self-hosted` / `local`), `label`, `uarch`, `cpu_model`. |
| `smoke` / `embeddinggemma_smoke` | The two pooled smoke results: `passed`, `n_embd` (hidden width), `n_embd_out` (pooled output width: the number of elements read and checked), `n_tokens`, `l2_norm`, `host_logits` (`false`: `llama_get_logits` returned `NULL` after the pooled encode; required) and `model_sha256` (computed from the file tested). `embeddinggemma_smoke` also records `model_id`, and must match the `EMBEDDINGGEMMA_*` pins. The legacy `smoke` model is identified by its hash alone; `correctness.sh` requires it to equal the correctness reference GGUF. |
| `logits_smoke` | The output-semantics control: `passed`, `n_vocab`, `n_tokens`, `host_logits` (one boolean per mode, which must equal the table in [Output semantics](#output-semantics-v6)), `max_logit_delta` (largest difference between the last-token logits of the modes that have them, at most `1e-3`), `model_id` and `model_sha256` (must match the `LOGITS_SMOKE_*` pins). |

Release CI runs `scripts/verify-provenance.sh --packaged <file> <profile>` on each variant's
`build-info.json` after packaging, and again in the release job before it publishes. It
fails on any mismatch with `scripts/config.env`. On x86-64 that includes the v3 gate
result, `effective_isa` and `disassembly.above_v3 == 0`. It also fails when `smoke`,
`embeddinggemma_smoke`, `logits_smoke`, `benchmark` or `correctness` is missing, has
`passed != true` or does not match its pins, which is the same check `scripts/package.sh`
gates on.

## Guarantees & non-guarantees

- **Guaranteed:** each variant's archives were produced natively on its own architecture
  (`aarch64`, or an x86-64-v3 capable `x86_64` host) from the pinned inputs
  (llama.cpp verified by commit and exact tag; see `build-info.json.llama_cpp`), passed the
  on-target smoke tests (real embeddings from the legacy model and the pinned EmbeddingGemma 2
  text fixture; see `build-info.json.smoke` / `.embeddinggemma_smoke`), showed the output
  semantics below on both pooled models and the generative control
  (`build-info.json.logits_smoke`), were within the
  benchmark regression threshold vs a from-source build (see `build-info.json.benchmark`),
  and passed the correctness gate above (`build-info.json.correctness.passed == true`).
  `scripts/package.sh` refuses to package without these results, and release CI re-checks
  them in the published `build-info.json` (`scripts/verify-provenance.sh --packaged`).
- **Not guaranteed:** ABI stability across contract versions, correctness on a
  microarchitecture other than the one the gate ran on (see §5), that a different glibc/
  compiler baseline links cleanly, or **any** support for x86-64 CPUs below x86-64-v3.
  Rebuild + re-pin when you move the runtime base.
