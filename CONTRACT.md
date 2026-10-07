# Artifact Contract — v4

This defines exactly what a release contains, how to link it, and how to verify it.
Both llama.cpp and `llama-cpp-rs` lack strong semver/ABI stability, so **consumers pin a
contract version** and re-verify on every bump.

## Contract version

`artifact_contract_version` (in `build-info.json`) is currently **`4`**. It **must** bump on
any change to: the set of shipped `.a`, the link line, enabled cargo features, the binding
ABI (llama-cpp-rs commit / compiled llama.cpp commit), the `dist/` layout, or the
guarantees a release carries. LTEmbed pins the contract version it supports and fails
closed on an unexpected value.

| Version | Change |
| --- | --- |
| v2 | Clang 18 compiler; OpenMP dropped, so `-lgomp` left the link line. |
| v3 | Added the numerical-correctness gate and the `correctness` block in `build-info.json`. |
| v4 | **llama.cpp `v0.6.0` (`d81235049384534c167caea52b85a694f6103d14`)**, compiled through llama-cpp-rs `0.1.159` (`3cfdd729d65e35da407e5f820edf73201bfa54f6`) with its vendored llama.cpp submodule (`26394b4e`) replaced by the tag. `bindings.rs` and `include/` are regenerated from the new `llama.h`/`ggml*.h`: **binding ABI changed — rebuild consumers against the new `bindings.rs`.** The crate is now built with `--no-default-features`. Its default feature set is `["common"]`, which pre-v4 releases silently enabled, so their `bindings.rs` also carried `llama_rs_*` declarations that no shipped archive defines; v4 drops them and gates on their absence. `build-info.json` provenance is restructured into `llama_cpp_rs` / `llama_cpp_sys_2` / `llama_cpp` blocks, with fail-closed tag/commit verification: `llama_cpp_sys_2.git_tag` and `llama_cpp.submodule_commit` are removed, replaced by `llama_cpp_rs.git_ref`/`.commit` and `llama_cpp.tag`/`.commit`. (v3 shipped `llama-cpp-sys-2` 0.1.151 with its vendored llama.cpp `9e3b928`.) **Second production variant: x86-64.** v4 adds `x86_64-unknown-linux-gnu` at the fixed `x86-64-v3` baseline, shipped as `static-llama-cpp-<tag>-x86_64-v3-linux-gnu.tar.gz` next to the unchanged `static-llama-cpp-<tag>-aarch64-graviton2.tar.gz`. Each variant is built natively on its own architecture. `build-info.json` gains `target_profile`, `architecture`, `cpu_baseline`, `cpu_profile`, `host`, `runner`, `pgo.architecture`/`.cpu_baseline`/`.use_flags` and the x86 `arch_flag_summary` keys. Because both variants share one GitHub Release, the loose release assets are per-variant: `build-info-<variant>.json` and `SHA256SUMS-<variant>`. **Unchanged:** the `.a` set, the link line and order, the ARM64 CPU profile, the toolchain (Clang 18, glibc ≥ 2.34) and the correctness thresholds. |

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
build-info.json full bill-of-materials + provenance + smoke/benchmark/correctness results
consume.build.rs drop-in build.rs (this repo's scripts/consume.build.rs)
CONTRACT.md     this file
SHA256SUMS      sha256 over every other file in the release
LICENSES/       llama.cpp (covers ggml) and builder licenses (all MIT)
```

## Build profile (v4)

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
- Engine: **llama.cpp `v0.6.0`** (annotated tag) at commit
  **`d81235049384534c167caea52b85a694f6103d14`** from `ggml-org/llama.cpp`. Before compiling,
  the build verifies that `HEAD` equals that commit, that the tag peels to it, and that
  `git describe --tags --exact-match` is `v0.6.0`. After compiling, it verifies that the
  generated `llama-version.h` embeds the same commit. The version is never inferred from a
  directory name, crate version or release name.
- Build driver: `llama-cpp-sys-2` from llama-cpp-rs, git tag **`0.1.159`** (a lightweight
  tag; verified to resolve to commit **`3cfdd729d65e35da407e5f820edf73201bfa54f6`**, package
  version `0.1.159`). No llama-cpp-rs release vendors llama.cpp `v0.6.0`: 0.1.159 pins
  `26394b4e`, 355 commits earlier. The build therefore verifies that gitlink and then
  replaces it with the `v0.6.0` checkout (both commits are recorded). Its `build.rs`
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
   (`aarch64-graviton2` / `x86_64-v3`). `scripts/verify-provenance.sh <build-info.json>
   <profile>` (bash + jq) checks every pin in `build-info.json` against this repo's
   `scripts/config.env`.
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
  that caught `v0.1.151-1`. Until that file has data rows the golden check is recorded as
  `not_generated` and is non-fatal, while §2 and §4 still gate.
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

## Provenance (`build-info.json`, v4)

| Field | Meaning |
| --- | --- |
| `llama_cpp.tag` / `.tag_type` / `.commit` / `.describe` | The compiled engine: the requested tag, `tag` for an annotated tag, the verified `HEAD`, and the `git describe --tags --exact-match` output. |
| `llama_cpp.embedded_version` / `.embedded_commit` | `LLAMA_VERSION` / `LLAMA_COMMIT` from the generated `llama-version.h`. llama.cpp marks its tree builds `-dev`, so `v0.6.0` reports `0.6.0-dev`; the commit is authoritative. |
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

Release CI runs `scripts/verify-provenance.sh <file> <profile>` on each variant's
`build-info.json` before it publishes, and fails on any mismatch with `scripts/config.env`.
On x86-64 that includes the v3 gate result, `effective_isa` and `disassembly.above_v3 == 0`.

## Guarantees & non-guarantees

- **Guaranteed:** each variant's archives were produced natively on its own architecture
  (`aarch64`, or an x86-64-v3 capable `x86_64` host) from the pinned inputs
  (llama.cpp verified by commit and exact tag; see `build-info.json.llama_cpp`), passed the
  on-target smoke test (real embedding), were within the benchmark regression threshold vs
  a from-source build (see `build-info.json.benchmark`), and passed the correctness gate
  above (`build-info.json.correctness.passed == true`).
- **Not guaranteed:** ABI stability across contract versions, correctness on a
  microarchitecture other than the one the gate ran on (see §5), that a different glibc/
  compiler baseline links cleanly, or **any** support for x86-64 CPUs below x86-64-v3.
  Rebuild + re-pin when you move the runtime base.
