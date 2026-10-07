# shellcheck shell=bash
# Shared, fail-closed helpers for build.sh / bench.sh / correctness.sh.
# Source AFTER scripts/config.env. Every check prints why it failed and exits non-zero;
# nothing here downgrades a mismatch to a warning.

_lib_die() { printf '\033[1;31m[%s:ERROR]\033[0m %s\n' "${LIB_TAG:-lib}" "$*" >&2; exit 1; }
_lib_log() { printf '\033[1;34m[%s]\033[0m %s\n' "${LIB_TAG:-lib}" "$*"; }

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Native-host gate --------------------------------------------------------------
# Artifacts are compiled ONLY on a native host of the target architecture:
#   actual host arch == container arch == compiler arch == artifact arch.
# Cross compilation (x86 -> ARM, ARM -> x86) and CPU emulation (QEMU user-mode /
# binfmt_misc, `docker --platform` of a foreign arch, buildx emulation) are NOT supported.
# qemu-user fakes `uname -m`, so the kernel's own arch (/proc/sys/kernel/arch, answered by
# the real kernel) and the binfmt_misc table are checked too. An x86-64 host must
# additionally be x86-64-v3 capable (scripts/check-x86-64-v3.sh) — fail-closed, with no
# fallback to a lower baseline.
NATIVE_HOST_MSG_ARM64="ARM64 artifacts must be built on a native ARM64 host. Cross-compilation and CPU emulation are not supported."
NATIVE_HOST_MSG_X86_64="x86-64 artifacts must be built on a native x86-64 (x86-64-v3 capable) host. Cross-compilation and CPU emulation are not supported."
# On success sets (global): HOST_CPU_MODEL, HOST_CPU_JSON (provenance).
assert_native_host() {
  local m karch rhost tool mach v msg arch_re probe_json
  m="$(uname -m)"
  [[ -n "${TARGET_PROFILE:-}" ]] \
    || _lib_die "unsupported host architecture '${m}' (supported profiles: ${SUPPORTED_TARGET_PROFILES}). Cross-compilation and CPU emulation are not supported."
  case "${TARGET_ARCH}" in
    aarch64) msg="${NATIVE_HOST_MSG_ARM64}";  arch_re='aarch64|arm64' ;;
    x86_64)  msg="${NATIVE_HOST_MSG_X86_64}"; arch_re='x86_64|amd64' ;;
    *) _lib_die "profile ${TARGET_PROFILE} has unknown TARGET_ARCH '${TARGET_ARCH}'" ;;
  esac
  [[ "${m}" =~ ^(${arch_re})$ ]] \
    || _lib_die "${msg} (uname -m: ${m}; profile ${TARGET_PROFILE} needs ${TARGET_ARCH})"
  [[ "${TARGET_TRIPLE%%-*}" == "${TARGET_ARCH}" ]] \
    || _lib_die "${msg} (TARGET_TRIPLE=${TARGET_TRIPLE} does not match the native ${TARGET_ARCH} host)"
  if [[ -r /proc/sys/kernel/arch ]]; then
    karch="$(cat /proc/sys/kernel/arch)"
    [[ "${karch}" =~ ^(${arch_re})$ ]] \
      || _lib_die "${msg} (kernel arch ${karch} != userland ${m}: CPU emulation detected)"
  fi
  # A native kernel never needs a binfmt handler for its own arch; an enabled one means
  # ELF binaries of this arch are being routed through an emulator.
  if [[ -r "/proc/sys/fs/binfmt_misc/qemu-${TARGET_ARCH}" ]] \
     && grep -qx enabled "/proc/sys/fs/binfmt_misc/qemu-${TARGET_ARCH}"; then
    _lib_die "${msg} (binfmt_misc qemu-${TARGET_ARCH} handler is enabled: CPU emulation detected)"
  fi
  # rustc must be a native toolchain building for its own host (no --target).
  rhost="$(rustc -vV | sed -n 's/^host: //p')"
  [[ "${rhost}" == "${TARGET_TRIPLE}" ]] \
    || _lib_die "${msg} (rustc host '${rhost}' != TARGET_TRIPLE '${TARGET_TRIPLE}')"
  # CC/CXX must be native compilers (a cross gcc/clang reports a foreign machine).
  for tool in "${CC:-cc}" "${CXX:-c++}"; do
    mach="$("${tool}" -dumpmachine 2>/dev/null || true)"
    [[ "${mach%%-*}" == "${TARGET_ARCH}" ]] \
      || _lib_die "${msg} (${tool} -dumpmachine = '${mach:-<none>}')"
  done
  # Knobs that would turn the build into a cross build (the crate forwards every CMAKE_*
  # env var to CMake, and cargo/cc-rs honour the rest).
  for v in CARGO_BUILD_TARGET CMAKE_TOOLCHAIN_FILE CMAKE_SYSTEM_NAME CMAKE_SYSTEM_PROCESSOR \
           CMAKE_CROSSCOMPILING CMAKE_C_COMPILER_TARGET CMAKE_CXX_COMPILER_TARGET \
           TARGET_CC TARGET_CXX TARGET_AR; do
    [[ -z "${!v:-}" ]] || _lib_die "${msg} (${v} is set: '${!v}')"
  done
  if env | grep -qE '^CARGO_TARGET_[A-Z0-9_]+_(LINKER|RUNNER)='; then
    _lib_die "${msg} (a CARGO_TARGET_*_LINKER/RUNNER override is set)"
  fi
  if [[ "${TARGET_ARCH}" == "x86_64" ]]; then
    # x86-64-v3 capability: CPUID/XGETBV + glibc hwcaps + /proc/cpuinfo, fail-closed. The
    # script prints "Host architecture / Required CPU baseline / x86-64-v3 capability".
    probe_json="$(mktemp)"
    if ! bash "${_LIB_DIR}/check-x86-64-v3.sh" --json "${probe_json}"; then
      rm -f "${probe_json}"
      exit 1
    fi
    HOST_CPU_JSON="$(cat "${probe_json}")"; rm -f "${probe_json}"
    HOST_CPU_MODEL="$(jq -r '.cpu_model' <<<"${HOST_CPU_JSON}")"
  else
    HOST_CPU_MODEL="$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n1 || true)"
    HOST_CPU_JSON="$(jq -n --arg model "${HOST_CPU_MODEL}" \
      --arg feats "$(sed -n 's/^Features[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n1 || true)" \
      '{cpu_model: $model, cpuinfo_features: ($feats | split(" ") | map(select(. != "")))}')"
  fi
}

# --- Build-input hygiene -------------------------------------------------------------
# llama-cpp-sys-2's build.rs forwards EVERY GGML_* and CMAKE_* env var as a CMake cache
# entry, reads LLAMA_LIB_PROFILE / LLAMA_BUILD_SHARED_LIBS / LLAMA_STATIC_CRT, and turns a
# rustc `target-cpu=` into -march (or GGML_NATIVE). Any of those in the environment would
# silently change the shipped archives, so the only build inputs are the ones in config.env.
# CMAKE_BUILD_PARALLEL_LEVEL (job count only) is the one tolerated CMAKE_* variable.
assert_no_build_env_overrides() {
  local leaked v
  leaked="$(env | grep -oE '^(GGML_[A-Za-z0-9_]*|CMAKE_[A-Za-z0-9_]*|LLAMA_LIB_PROFILE|LLAMA_BUILD_SHARED_LIBS|LLAMA_STATIC_CRT)=' \
            | grep -vx 'CMAKE_BUILD_PARALLEL_LEVEL=' || true)"
  [[ -z "${leaked}" ]] \
    || _lib_die "build-input override(s) in the environment: $(tr '\n' ' ' <<<"${leaked}")— unset them; build inputs come from scripts/config.env only"
  for v in RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_BUILD_RUSTFLAGS; do
    [[ "${!v:-}" != *target-cpu* ]] \
      || _lib_die "${v} sets target-cpu (the crate maps it to -march/GGML_NATIVE): '${!v}'"
    # The crate also maps rustc target features (avx2, avx512*, avxvnni, ...) to GGML_* ON.
    [[ "${!v:-}" != *target-feature* ]] \
      || _lib_die "${v} sets target-feature (the crate maps it to GGML_* ISA options): '${!v}'"
  done
}

# --- Pinned sources -----------------------------------------------------------------
# Prepare ${1} as the pinned llama-cpp-rs checkout with llama.cpp ${LLAMA_CPP_TAG}
# substituted for the crate's vendored submodule (strategy: no llama-cpp-rs release
# vendors ${LLAMA_CPP_TAG}; see config.env). Everything is verified by commit, never by a
# directory name or crate version. On success sets (global):
#   CRATE_COMMIT CRATE_GITLINK LLAMA_CPP_DIR LLAMA_CPP_COMMIT LLAMA_CPP_DESCRIBE
#   LLAMA_CPP_DATE LLAMA_CPP_TAG_TYPE
# Reuses an existing checkout only if it is exactly the pin; build.rs is always restored
# to pristine, so callers patch (or deliberately don't) from a known state.
prepare_crate_source() {
  local dest="$1" head tagc ver dirty tag_name
  local git=(git -c advice.detachedHead=false)

  if [[ -d "${dest}/.git" ]]; then
    head="$(git -C "${dest}" rev-parse HEAD 2>/dev/null || true)"
    if [[ "${head}" != "${EXPECTED_CRATE_COMMIT}" ]]; then
      _lib_log "discarding stale crate checkout ${dest} (HEAD ${head:-?} != ${EXPECTED_CRATE_COMMIT})"
      rm -rf "${dest}"
    fi
  fi
  if [[ ! -d "${dest}/.git" ]]; then
    _lib_log "cloning ${CRATE_REPO} @ ${CRATE_REF} (no submodules; llama.cpp is pinned separately)"
    "${git[@]}" clone --quiet --depth 1 --branch "${CRATE_REF}" "${CRATE_REPO}" "${dest}"
  fi

  # (1) crate: requested ref -> resolved commit -> package version -> vendored gitlink.
  CRATE_COMMIT="$(git -C "${dest}" rev-parse HEAD)"
  [[ "${CRATE_COMMIT}" == "${EXPECTED_CRATE_COMMIT}" ]] \
    || _lib_die "llama-cpp-rs ${CRATE_REF} resolved to ${CRATE_COMMIT}, expected ${EXPECTED_CRATE_COMMIT}"
  tagc="$(git -C "${dest}" rev-parse -q --verify "refs/tags/${CRATE_REF}^{commit}" || true)"
  [[ "${tagc}" == "${EXPECTED_CRATE_COMMIT}" ]] \
    || _lib_die "llama-cpp-rs tag ${CRATE_REF} -> '${tagc:-<missing>}', expected ${EXPECTED_CRATE_COMMIT}"
  ver="$(awk -F'"' '/^version = /{print $2; exit}' "${dest}/llama-cpp-sys-2/Cargo.toml")"
  [[ "${ver}" == "${CRATE_VERSION}" ]] \
    || _lib_die "llama-cpp-sys-2 package version '${ver}' != expected ${CRATE_VERSION}"
  CRATE_GITLINK="$(git -C "${dest}" ls-tree HEAD llama-cpp-sys-2/llama.cpp | awk '$2=="commit"{print $3}')"
  [[ "${CRATE_GITLINK}" == "${CRATE_VENDORED_LLAMA_CPP_COMMIT}" ]] \
    || _lib_die "crate's vendored llama.cpp gitlink '${CRATE_GITLINK}' != recorded ${CRATE_VENDORED_LLAMA_CPP_COMMIT}"
  git -C "${dest}" checkout --quiet -- llama-cpp-sys-2/build.rs
  dirty="$(git -C "${dest}" status --porcelain --untracked-files=no --ignore-submodules=all)"
  [[ -z "${dirty}" ]] || _lib_die "crate checkout ${dest} has local modifications: ${dirty}"

  # (2) llama.cpp: fetch ONLY the pinned tag into the gitlink path and check it out.
  LLAMA_CPP_DIR="${dest}/llama-cpp-sys-2/llama.cpp"
  head="$(git -C "${LLAMA_CPP_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [[ ! -d "${LLAMA_CPP_DIR}/.git" || "${head}" != "${EXPECTED_LLAMA_CPP_COMMIT}" ]]; then
    _lib_log "fetching llama.cpp ${LLAMA_CPP_TAG} from ${LLAMA_CPP_REPO} into the crate's llama.cpp path"
    rm -rf "${LLAMA_CPP_DIR}"
    git init --quiet "${LLAMA_CPP_DIR}"
    git -C "${LLAMA_CPP_DIR}" remote add origin "${LLAMA_CPP_REPO}"
    git -C "${LLAMA_CPP_DIR}" fetch --quiet --depth 1 --no-tags origin \
      "+refs/tags/${LLAMA_CPP_TAG}:refs/tags/${LLAMA_CPP_TAG}"
    "${git[@]}" -C "${LLAMA_CPP_DIR}" checkout --quiet --detach "refs/tags/${LLAMA_CPP_TAG}^{commit}"
  fi

  # (3) verify what will actually be compiled — HEAD, tag peel, tag object, exact describe.
  LLAMA_CPP_COMMIT="$(git -C "${LLAMA_CPP_DIR}" rev-parse HEAD)"
  [[ "${LLAMA_CPP_COMMIT}" == "${EXPECTED_LLAMA_CPP_COMMIT}" ]] \
    || _lib_die "llama.cpp HEAD ${LLAMA_CPP_COMMIT} != expected ${EXPECTED_LLAMA_CPP_COMMIT}"
  tagc="$(git -C "${LLAMA_CPP_DIR}" rev-parse -q --verify "refs/tags/${LLAMA_CPP_TAG}^{commit}" || true)"
  [[ "${tagc}" == "${EXPECTED_LLAMA_CPP_COMMIT}" ]] \
    || _lib_die "llama.cpp tag ${LLAMA_CPP_TAG} -> '${tagc:-<missing>}', expected ${EXPECTED_LLAMA_CPP_COMMIT}"
  LLAMA_CPP_TAG_TYPE="$(git -C "${LLAMA_CPP_DIR}" cat-file -t "refs/tags/${LLAMA_CPP_TAG}")"
  [[ "${LLAMA_CPP_TAG_TYPE}" == "tag" ]] \
    || _lib_die "llama.cpp ${LLAMA_CPP_TAG} is a ${LLAMA_CPP_TAG_TYPE}, expected an annotated tag"
  tag_name="$(git -C "${LLAMA_CPP_DIR}" cat-file tag "refs/tags/${LLAMA_CPP_TAG}" | sed -n 's/^tag //p')"
  [[ "${tag_name}" == "${LLAMA_CPP_TAG}" ]] \
    || _lib_die "llama.cpp tag object names '${tag_name}', expected ${LLAMA_CPP_TAG}"
  LLAMA_CPP_DESCRIBE="$(git -C "${LLAMA_CPP_DIR}" describe --tags --exact-match HEAD 2>/dev/null || true)"
  [[ "${LLAMA_CPP_DESCRIBE}" == "${LLAMA_CPP_TAG}" ]] \
    || _lib_die "llama.cpp 'git describe --tags --exact-match' = '${LLAMA_CPP_DESCRIBE}', expected ${LLAMA_CPP_TAG}"
  dirty="$(git -C "${LLAMA_CPP_DIR}" status --porcelain --untracked-files=no)"
  [[ -z "${dirty}" ]] || _lib_die "llama.cpp checkout has local modifications: ${dirty}"
  LLAMA_CPP_DATE="$(git -C "${LLAMA_CPP_DIR}" show -s --format=%cI HEAD)"
  _lib_log "llama-cpp-rs ${CRATE_REF} @ ${CRATE_COMMIT} (llama-cpp-sys-2 ${CRATE_VERSION}; vendored ${CRATE_GITLINK:0:12} overridden)"
  _lib_log "llama.cpp ${LLAMA_CPP_DESCRIBE} @ ${LLAMA_CPP_COMMIT} (annotated tag, ${LLAMA_CPP_DATE})"
}

# --- N1 ISA injection -----------------------------------------------------------------
# For Linux aarch64 (non-native) the crate hardcodes GGML_CPU_ARM_ARCH="armv8-a", which
# ggml turns into -march=armv8-a (no dotprod) on the CPU kernels. That define comes AFTER
# the crate's GGML_* env forwarding, so an env var cannot override it: rewrite the literal
# in the checked-out build.rs. Must run on a PRISTINE build.rs (prepare_crate_source
# restores it). Fails unless there was exactly one string-literal GGML_CPU_ARM_ARCH define,
# it was the expected literal, and afterwards exactly one literal define carries CPU_MARCH.
# (0.1.159 also has an Android-only `config.define("GGML_CPU_ARM_ARCH", &arch)` fed from
# the env var — not a literal, never reached on Linux, and the env var itself is refused by
# assert_no_build_env_overrides.)
GGML_ARM_ARCH_DEFAULT='config.define("GGML_CPU_ARM_ARCH", "armv8-a")'
GGML_ARM_ARCH_LITERAL='config.define("GGML_CPU_ARM_ARCH", "'
patch_ggml_arm_arch() {
  local build_rs="$1" want n_defs n_old n_new
  want="config.define(\"GGML_CPU_ARM_ARCH\", \"${CPU_MARCH}\")"
  n_defs="$(grep -cF -- "${GGML_ARM_ARCH_LITERAL}" "${build_rs}" || true)"
  n_old="$(grep -cF -- "${GGML_ARM_ARCH_DEFAULT}" "${build_rs}" || true)"
  if [[ "${n_defs}" != 1 || "${n_old}" != 1 ]]; then
    echo "patch_ggml_arm_arch: expected exactly 1 literal GGML_CPU_ARM_ARCH define (= armv8-a) in ${build_rs}; found ${n_defs} literal define(s), ${n_old} armv8-a" >&2
    return 1
  fi
  CPU_MARCH="${CPU_MARCH}" perl -0pi -e \
    's/config\.define\("GGML_CPU_ARM_ARCH", "armv8-a"\)/config.define("GGML_CPU_ARM_ARCH", "$ENV{CPU_MARCH}")/' \
    "${build_rs}"
  n_defs="$(grep -cF -- "${GGML_ARM_ARCH_LITERAL}" "${build_rs}" || true)"
  n_old="$(grep -cF -- "${GGML_ARM_ARCH_DEFAULT}" "${build_rs}" || true)"
  n_new="$(grep -cF -- "${want}" "${build_rs}" || true)"
  if [[ "${n_defs}" != 1 || "${n_old}" != 0 || "${n_new}" != 1 ]]; then
    echo "patch_ggml_arm_arch: post-patch check failed in ${build_rs} (defines=${n_defs}, armv8-a=${n_old}, ${CPU_MARCH}=${n_new})" >&2
    return 1
  fi
}

# Print the value of CMake cache entry ${2} (exact key, any type; may be empty) from
# CMakeCache.txt ${1}. Fails if the file or the entry is missing.
cmake_cache_get() {
  [[ -f "$1" ]] || { echo "cmake_cache_get: no CMake cache at $1" >&2; return 1; }
  awk -v k="$2" 'index($0, k ":") == 1 { sub(/^[^=]*=/, ""); print; f = 1; exit }
                 END { exit !f }' "$1"
}

# --- Build + harvest ------------------------------------------------------------------
# Build llama-cpp-sys-2 in checkout ${1}. --no-default-features is load-bearing: the
# crate's default feature set is ["common"], which would add LLAMA_BUILD_COMMON, an extra
# wrapper archive and llama_rs_* declarations to bindings.rs. --locked: the crate's own
# Cargo.lock pins bindgen/cc/cmake. Caller exports CFLAGS/CXXFLAGS/CARGO_TARGET_DIR.
# Remaining args are GGML_*=VALUE assignments from config.env (the profile's
# GGML_ISA_DEFINES, or GENERIC_REF_GGML_DEFINES for the correctness reference); they reach
# CMake through the crate's GGML_* env forwarding for this one cargo invocation only, so
# assert_no_build_env_overrides still guarantees nothing else injects GGML_* options.
build_sys_crate() {
  local dir="$1" a; shift
  for a in "$@"; do
    [[ "${a}" =~ ^GGML_[A-Z0-9_]+=(ON|OFF)$ ]] || _lib_die "build_sys_crate: unexpected define '${a}'"
  done
  ( cd "${dir}" && env "$@" cargo build --release --locked -p llama-cpp-sys-2 --no-default-features \
      ${CRATE_FEATURES:+--features "${CRATE_FEATURES}"} )
}

# Print every compile command from compile_commands.json ${1}, one per line (CMake emits
# either .command or .arguments depending on the generator).
compile_commands_lines() {
  jq -r '.[] | (.command // (.arguments | join(" ")))' "$1"
}

# Locate the llama-cpp-sys-2 OUT_DIR under a CARGO_TARGET_DIR. Exactly one must exist,
# otherwise a stale build from another pin could be harvested.
find_sys_out_dir() {
  local target="$1" d dirs=()
  [[ -d "${target}/release/build" ]] || _lib_die "no release build under ${target}"
  while IFS= read -r d; do dirs+=("${d}"); done \
    < <(find "${target}/release/build" -mindepth 2 -maxdepth 2 -type d -name out \
          -path '*/llama-cpp-sys-2-*/out')
  [[ "${#dirs[@]}" -eq 1 ]] \
    || _lib_die "expected exactly 1 llama-cpp-sys-2 OUT_DIR under ${target}, found ${#dirs[@]}: ${dirs[*]:-}"
  printf '%s\n' "${dirs[0]}"
}

# Copy the INSTALLED static archives (cmake install -> OUT_DIR/lib or lib64) + bindings.rs
# into ${2}/{lib,bindings.rs}. The installed .a set must equal STATIC_LIBS exactly: a new
# or missing archive upstream changes the consumer link line and must be a deliberate
# contract change, never silently dropped or shipped. bindings.rs must not declare
# symbols the archives don't provide (llama_rs_* from `common`, mtmd_*).
harvest_sys_outputs() {
  local out="$1" dest="$2" installed expected lib src d libdirs=()
  [[ -n "${out}" && -d "${out}" ]] || _lib_die "harvest: OUT_DIR '${out}' is not a directory"
  for d in "${out}/lib" "${out}/lib64"; do [[ -d "${d}" ]] && libdirs+=("${d}"); done
  [[ "${#libdirs[@]}" -gt 0 ]] || _lib_die "no install lib dir (lib/ or lib64/) under ${out}"
  installed="$(find "${libdirs[@]}" -maxdepth 1 -name '*.a' -printf '%f\n' | sort)"
  expected="$(tr ' ' '\n' <<<"${STATIC_LIBS}" | sed '/^$/d' | sort)"
  [[ "${installed}" == "${expected}" ]] \
    || _lib_die "installed archive set differs from STATIC_LIBS:
  installed: $(tr '\n' ' ' <<<"${installed}")
  expected:  $(tr '\n' ' ' <<<"${expected}")"
  mkdir -p "${dest}/lib"
  for lib in ${STATIC_LIBS}; do
    src="$(find "${libdirs[@]}" -maxdepth 1 -name "${lib}" -print -quit)"
    [[ -n "${src}" ]] || _lib_die "installed ${lib} not found under ${out}/lib{,64}"
    cp "${src}" "${dest}/lib/${lib}"
  done
  [[ -f "${out}/bindings.rs" ]] || _lib_die "bindings.rs not found at ${out}/bindings.rs"
  if grep -qE '\b(llama_rs_|mtmd_)' "${out}/bindings.rs"; then
    _lib_die "bindings.rs declares llama_rs_*/mtmd_* items (crate feature leak: common/mtmd); no archive provides them"
  fi
  grep -q 'pub fn llama_encode(' "${out}/bindings.rs" \
    || _lib_die "bindings.rs has no llama_encode — unexpected bindings shape"
  cp "${out}/bindings.rs" "${dest}/bindings.rs"
}

# --- x86-64 ISA gates ----------------------------------------------------------------
# Production x86 archives must have an EFFECTIVE ISA of exactly x86-64-v3: every v3 feature
# on, nothing above it. ggml is built without GGML_BACKEND_DL, so there is NO runtime ISA
# dispatch — any AVX-512 / AVX-VNNI / AMX / ... code in the archives would be executed
# unconditionally and SIGILL on a plain v3 CPU. Two independent proofs:
#   (1) x86_isa_macro_check: preprocess an empty TU with a TU's exact ISA flags and compare
#       the compiler's ISA feature macros with the v3 set (what the code is compiled for);
#   (2) x86_disasm_scan: disassemble the harvested archives and reject any instruction
#       outside v3 (what was actually emitted, including inline asm / target attributes).
X86_V3_REQUIRED_MACROS="__SSE3__ __SSSE3__ __SSE4_1__ __SSE4_2__ __POPCNT__ __AVX__ __AVX2__ __BMI__ __BMI2__ __F16C__ __FMA__ __LZCNT__ __MOVBE__ __XSAVE__"
X86_ABOVE_V3_MACRO_RE='^__(AVX512[A-Z0-9_]*|AVX10[A-Z0-9_]*|AMX_[A-Z0-9_]*|AVXVNNI[A-Z0-9_]*|AVXIFMA|AVXNECONVERT|APX_F|SHA|SHA512|SM3|SM4|AES|VAES|PCLMUL|VPCLMULQDQ|GFNI|ADX|RDRND|RDSEED|FMA4|XOP|TBM|SSE4A)__$'

# x86_isa_macro_check MODE COMPILER [FLAGS...]
#   MODE v3:       every X86_V3_REQUIRED_MACROS defined, nothing matching X86_ABOVE_V3_MACRO_RE.
#   MODE baseline: (generic correctness reference) NONE of the v2/v3 macros and nothing
#                  above v3 — i.e. plain x86-64 (SSE2).
# Prints the reason and returns 1 on a mismatch.
x86_isa_macro_check() {
  local mode="$1" cc="$2" defs m missing="" present="" extra; shift 2
  defs="$("${cc}" "$@" -dM -E -x c /dev/null 2>&1)" || { echo "preprocessor failed: ${defs}"; return 1; }
  defs="$(sed -n 's/^#define \(__[A-Za-z0-9_]*__\) .*/\1/p' <<<"${defs}")"
  for m in ${X86_V3_REQUIRED_MACROS}; do
    if grep -qxF -- "${m}" <<<"${defs}"; then present+="${m} "; else missing+="${m} "; fi
  done
  extra="$(grep -E -- "${X86_ABOVE_V3_MACRO_RE}" <<<"${defs}" | tr '\n' ' ' || true)"
  case "${mode}" in
    v3)       [[ -z "${missing}" && -z "${extra}" ]] && return 0
              echo "missing v3 features: ${missing:-none}; above-v3 features: ${extra:-none}" ;;
    baseline) [[ -z "${present}" && -z "${extra}" ]] && return 0
              echo "reference is not plain x86-64: has ${present}${extra}" ;;
    *)        echo "x86_isa_macro_check: unknown mode ${mode}" ;;
  esac
  return 1
}

# Resolve a GNU-format disassembler (binutils objdump; the AL2023 image installs binutils).
x86_find_objdump() {
  command -v objdump 2>/dev/null || command -v x86_64-linux-gnu-objdump 2>/dev/null \
    || { _lib_log "objdump (binutils) not found; cannot verify the emitted ISA"; return 1; }
}

# x86_disasm_scan OBJDUMP ARCHIVE...: disassemble every object and report each instruction
# outside x86-64-v3. Output: "instructions <n>" then one "violation <category> <member>
# <insn>" line per hit (first 20 per category) and "category <name> <count>" totals.
# Returns 1 if any violation (or nothing was disassembled). Categories:
#   evex         any EVEX-encoded instruction (byte 0x62 after optional segment/0x67
#                prefixes; in 64-bit mode 0x62 is always EVEX) = every AVX-512 / AVX10 /
#                AVX512-FP16 form, including AVX512VL on xmm/ymm0-15
#   avx512-operand  zmm, xmm/ymm16-31, mask registers, {1toN} broadcast, {z}, {evex}
#   amx / vnni / ifma / bf16-neconvert   VEX-encoded beyond-v3 extensions
#   crypto       AES/VAES, PCLMULQDQ, GFNI, SHA, SM3/SM4
#   other        ADX, RDRAND/RDSEED, FMA4, XOP, TBM, SSE4a
x86_disasm_scan() {
  local od="$1"; shift
  "${od}" -d "$@" | awk -F'\t' '
    function hit(cat, what) {
      cnt[cat]++
      if (cnt[cat] <= 20) printf "violation %s %s %s\n", cat, member, what
    }
    /^[^ \t].*:[ \t]+file format / { member = $0; sub(/:[ \t]+file format.*/, "", member); next }
    NF >= 3 && $1 ~ /^ *[0-9a-f]+:$/ {
      n++
      bytes = $2; ins = $3
      gsub(/^ +| +$/, "", bytes)
      nb = split(bytes, b, " ")
      i = 1
      while (i < nb && b[i] ~ /^(26|2e|36|3e|64|65|67)$/) i++
      if (b[i] == "62") hit("evex", ins)
      if (ins ~ /%zmm|%[xy]mm(1[6-9]|2[0-9]|3[01])([^0-9]|$)|%k[0-7]([^0-9]|$)|\{1to[0-9]+\}|\{z\}|\{evex\}/)
        hit("avx512-operand", ins)
      m = ins
      sub(/^\{vex3?\}[ ]*/, "", m)
      while (match(m, /^(rep|repz|repnz|repe|repne|lock|notrack|bnd|data16|addr32|cs|ds|es|fs|gs|ss|xacquire|xrelease)[ ]+/))
        m = substr(m, RLENGTH + 1)
      split(m, t, " "); mn = t[1]
      if (mn ~ /^(ldtilecfg|sttilecfg|tileloadd|tileloaddt1|tilestored|tilerelease|tilezero|tdp[a-z0-9]+|tcmmimfp16ps|tcmmrlfp16ps)$/) hit("amx", ins)
      else if (mn ~ /^vpdp[a-z0-9]+$/) hit("vnni", ins)
      else if (mn ~ /^vpmadd52[lh]uq$/) hit("ifma", ins)
      else if (mn ~ /^(vcvtne2ps2bf16|vcvtneps2bf16|vdpbf16ps|vbcstne[a-z0-9]+|vcvtnee[a-z0-9]+|vcvtneo[a-z0-9]+)$/) hit("bf16-neconvert", ins)
      else if (mn ~ /^(v?aes[a-z0-9]*|v?pclmul[a-z0-9]*|v?gf2p8[a-z0-9]*|sha(1|256|512)[a-z0-9]*|vsm[34][a-z0-9]*)$/) hit("crypto", ins)
      else if (mn ~ /^(adcx[lq]?|adox[lq]?|rdrand|rdseed|extrq|insertq|movntss|movntsd|vfn?m(add|sub|addsub|subadd)(ps|pd|ss|sd)|vfrcz[a-z]+|vpperm|vpcmov|vprot[bwdq]|vpsha[bwdq]|vpshl[bwdq]|vpmacs[a-z]+|vpmadcs[a-z]+|vpermil2p[sd]|blcfill|blci|blcic|blcmsk|blcs|blsfill|blsic|t1mskc|tzmsk)$/) hit("other", ins)
    }
    END {
      printf "instructions %d\n", n
      bad = 0
      for (c in cnt) { printf "category %s %d\n", c, cnt[c]; bad += cnt[c] }
      exit (bad > 0 || n == 0) ? 1 : 0
    }'
}
