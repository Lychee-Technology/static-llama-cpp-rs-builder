# shellcheck shell=bash
# Shared, fail-closed helpers for build.sh / bench.sh / correctness.sh, and the release
# results gate shared by package.sh / verify-provenance.sh. Source AFTER scripts/config.env.
# Every check prints why it failed and exits non-zero; nothing here downgrades a mismatch
# to a warning.

_lib_die() { printf '\033[1;31m[%s:ERROR]\033[0m %s\n' "${LIB_TAG:-lib}" "$*" >&2; exit 1; }
_lib_log() { printf '\033[1;34m[%s]\033[0m %s\n' "${LIB_TAG:-lib}" "$*"; }

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Native-host gate --------------------------------------------------------------
# Artifacts are compiled ONLY on a native host of the target OS and architecture:
#   actual host arch == container arch (Linux) == compiler arch == artifact arch.
# Cross compilation (x86 -> ARM, ARM -> x86, Linux <-> macOS) and CPU emulation (QEMU
# user-mode / binfmt_misc, `docker --platform` of a foreign arch, buildx emulation,
# Rosetta 2) are NOT supported. qemu-user fakes `uname -m`, so on Linux the kernel's own
# arch (/proc/sys/kernel/arch, answered by the real kernel) and the binfmt_misc table are
# checked too; on macOS the kernel's sysctls say whether the CPU is arm64 and whether this
# process is translated. An x86-64 host must additionally be x86-64-v3 capable
# (scripts/check-x86-64-v3.sh), and a macOS host must have every apple-m1 feature
# (macos_host_cpu_check) — fail-closed, with no fallback to a lower baseline.
NATIVE_HOST_MSG_ARM64="ARM64 artifacts must be built on a native ARM64 host. Cross-compilation and CPU emulation are not supported."
NATIVE_HOST_MSG_X86_64="x86-64 artifacts must be built on a native x86-64 (x86-64-v3 capable) host. Cross-compilation and CPU emulation are not supported."
NATIVE_HOST_MSG_MACOS_ARM64="Apple Silicon macOS artifacts must be built natively on an Apple Silicon Mac. Cross-compilation, Rosetta 2 and CPU emulation are not supported."
# On success sets (global): HOST_CPU_MODEL, HOST_CPU_JSON (provenance).
assert_native_host() {
  local os m karch rhost tool mach v msg arch_re want_os probe_json
  os="$(uname -s)"; m="$(uname -m)"
  [[ -n "${TARGET_PROFILE:-}" ]] \
    || _lib_die "unsupported host '${os} ${m}' (release profiles: ${SUPPORTED_TARGET_PROFILES}; build-only: ${BUILD_ONLY_TARGET_PROFILES}). Cross-compilation and CPU emulation are not supported."
  case "${TARGET_OS}/${TARGET_ARCH}" in
    linux/aarch64) msg="${NATIVE_HOST_MSG_ARM64}";       arch_re='aarch64|arm64'; want_os=Linux ;;
    linux/x86_64)  msg="${NATIVE_HOST_MSG_X86_64}";      arch_re='x86_64|amd64';  want_os=Linux ;;
    macos/aarch64) msg="${NATIVE_HOST_MSG_MACOS_ARM64}"; arch_re='arm64';         want_os=Darwin ;;
    *) _lib_die "profile ${TARGET_PROFILE} has unknown TARGET_OS/TARGET_ARCH '${TARGET_OS}/${TARGET_ARCH}'" ;;
  esac
  [[ "${os}" == "${want_os}" ]] \
    || _lib_die "${msg} (uname -s: ${os}; profile ${TARGET_PROFILE} needs ${want_os})"
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
  if [[ "${TARGET_OS}" == macos ]]; then
    # The kernel answers for the hardware: hw.optional.arm64 is 1 only on Apple Silicon,
    # and sysctl.proc_translated is 1 inside a Rosetta 2 (x86_64-translated) process.
    v="$(sysctl -n hw.optional.arm64 2>/dev/null || true)"
    [[ "${v}" == 1 ]] || _lib_die "${msg} (sysctl hw.optional.arm64 = '${v:-<missing>}', expected 1)"
    v="$(sysctl -n sysctl.proc_translated 2>/dev/null || true)"
    [[ "${v}" == 0 ]] || _lib_die "${msg} (sysctl sysctl.proc_translated = '${v:-<missing>}', expected 0: Rosetta 2 translation)"
  fi
  # rustc must be a native toolchain building for its own host (no --target).
  rhost="$(rustc -vV | sed -n 's/^host: //p')"
  [[ "${rhost}" == "${TARGET_TRIPLE}" ]] \
    || _lib_die "${msg} (rustc host '${rhost}' != TARGET_TRIPLE '${TARGET_TRIPLE}')"
  # CC/CXX must be native compilers (a cross gcc/clang reports a foreign machine). Apple
  # clang reports the arch as arm64 (arm64-apple-darwin24.6.0), i.e. NATIVE_ARCH.
  for tool in "${CC:-cc}" "${CXX:-c++}"; do
    mach="$("${tool}" -dumpmachine 2>/dev/null || true)"
    [[ "${mach%%-*}" == "${NATIVE_ARCH}" ]] \
      || _lib_die "${msg} (${tool} -dumpmachine = '${mach:-<none>}')"
    if [[ "${TARGET_OS}" == macos && "${mach}" != *-apple-darwin* ]]; then
      _lib_die "${msg} (${tool} -dumpmachine = '${mach}', expected ${NATIVE_ARCH}-apple-darwin*)"
    fi
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
  if [[ "${TARGET_OS}" == macos ]]; then
    macos_host_cpu_check
  elif [[ "${TARGET_ARCH}" == "x86_64" ]]; then
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

# Host CPU features that -mcpu=apple-m1 code can use (clang's apple-m1 target features,
# as the kernel's hw.optional.* sysctls name them). Every Apple Silicon Mac has all of
# them; a host (or VM) missing one could not run what it builds and is refused. A NEWER
# host (M2..M4) is fine: the build never reads the host CPU, it only has to run M1 code.
APPLE_M1_HOST_FEATURES="arm.FEAT_AES arm.FEAT_PMULL arm.FEAT_SHA1 arm.FEAT_SHA256 arm.FEAT_SHA512 arm.FEAT_SHA3 arm.FEAT_CRC32 arm.FEAT_LSE arm.FEAT_RDM arm.FEAT_FP16 arm.FEAT_FHM arm.FEAT_DotProd arm.FEAT_JSCVT arm.FEAT_FCMA arm.FEAT_LRCPC arm.FEAT_FlagM arm.FEAT_FlagM2 arm.FEAT_FRINTTS arm.FEAT_SB arm.FEAT_SSBS arm.FEAT_DPB neon neon_fp16"
# macos_host_cpu_check: the apple-m1 capability gate of a macOS host (the counterpart of
# scripts/check-x86-64-v3.sh). A missing sysctl fails, it is never assumed present. Sets
# HOST_CPU_MODEL and HOST_CPU_JSON ({baseline, result, cpu_model, hw_model,
# required_features, rosetta}).
macos_host_cpu_check() {
  local f v missing="" feats=""
  for f in ${APPLE_M1_HOST_FEATURES}; do
    v="$(sysctl -n "hw.optional.${f}" 2>/dev/null || true)"
    [[ "${v}" == 1 ]] || missing+="hw.optional.${f}=${v:-<missing>} "
    feats+="${f}=${v:-0}"$'\n'
  done
  HOST_CPU_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
  echo "Host: $(uname -s) $(uname -m), ${HOST_CPU_MODEL:-unknown CPU}"
  echo "Required CPU baseline: ${CPU_BASELINE}"
  [[ -z "${missing}" ]] || _lib_die "${NATIVE_HOST_MSG_MACOS_ARM64} (host lacks apple-m1 features: ${missing})"
  echo "apple-m1 capability: PASS"
  HOST_CPU_JSON="$(printf '%s' "${feats}" \
    | jq -R 'split("=") | {(.[0]): (.[1] == "1")}' | jq -s 'add // {}' \
    | jq --arg model "${HOST_CPU_MODEL}" --arg hw "$(sysctl -n hw.model 2>/dev/null || true)" \
         --arg baseline "${CPU_BASELINE}" \
         '{baseline: $baseline, result: "PASS", cpu_model: $model, hw_model: $hw,
           required_features: ., rosetta: false}')"
}

# assert_release_profile PROFILE: die unless PROFILE is a release variant
# (SUPPORTED_TARGET_PROFILES). Every release step calls this, so a build-only profile
# (BUILD_ONLY_TARGET_PROFILES) can be built and smoke-tested but never packaged, verified as
# a release, or given release results.
assert_release_profile() {
  case " ${SUPPORTED_TARGET_PROFILES} " in *" $1 "*) return 0 ;; esac
  case " ${BUILD_ONLY_TARGET_PROFILES} " in
    *" $1 "*) _lib_die "target profile $1 is build-only, not a release variant (release variants: ${SUPPORTED_TARGET_PROFILES}; release integration: issue #22)" ;;
  esac
  _lib_die "'$1' is not a release target profile (release variants: ${SUPPORTED_TARGET_PROFILES})"
}

# --- Portable host utilities ----------------------------------------------------------
# The build scripts also run on macOS (bash 3.2, BSD userland), where `nproc`,
# `find -printf`, glibc and /proc are absent.

# host_ncpu: number of CPUs to build with (Linux: nproc, which honours the CPU affinity).
host_ncpu() {
  case "$(uname -s)" in
    Darwin) sysctl -n hw.logicalcpu ;;
    *)      nproc ;;
  esac
}

# sha256_file FILE: print FILE's SHA-256 (64 lowercase hex). sha256sum, or macOS's
# `shasum -a 256` where there is none; fails unless a digest came out.
sha256_file() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum "$1")"
  else out="$(shasum -a 256 "$1")"; fi || return 1
  out="${out%% *}"
  [[ "${out}" =~ ^[0-9a-f]{64}$ ]] || { echo "sha256_file: no SHA-256 digest for $1" >&2; return 1; }
  printf '%s\n' "${out}"
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
  # macOS: cc-rs, CMake and rustc all take the minimum OS from MACOSX_DEPLOYMENT_TARGET;
  # the profile pins it (build.sh exports MACOS_DEPLOYMENT_TARGET), so a different
  # inherited value is a conflicting build input, not something to silently replace.
  if [[ "${TARGET_OS:-}" == macos && -n "${MACOSX_DEPLOYMENT_TARGET:-}" \
        && "${MACOSX_DEPLOYMENT_TARGET}" != "${MACOS_DEPLOYMENT_TARGET}" ]]; then
    _lib_die "MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} conflicts with the profile's pinned ${MACOS_DEPLOYMENT_TARGET} — unset it"
  fi
}

# --- Pinned sources -----------------------------------------------------------------

# Called by preparation and offline regression tests. A tag is accepted only as the
# object type config.env pins (annotated "tag" for vX.Y.Z releases, lightweight "commit"
# for nightly b* tags) and only at the pinned commit; an annotated tag object must also
# name LLAMA_CPP_TAG.
verify_llama_cpp_source() {
  local tagc tag_name dirty
  case "${EXPECTED_LLAMA_CPP_TAG_TYPE}" in
    tag|commit) ;;
    *) _lib_die "unsupported pinned llama.cpp tag type '${EXPECTED_LLAMA_CPP_TAG_TYPE}'" ;;
  esac
  LLAMA_CPP_COMMIT="$(git -C "${LLAMA_CPP_DIR}" rev-parse HEAD)"
  [[ "${LLAMA_CPP_COMMIT}" == "${EXPECTED_LLAMA_CPP_COMMIT}" ]] \
    || _lib_die "llama.cpp HEAD ${LLAMA_CPP_COMMIT} != expected ${EXPECTED_LLAMA_CPP_COMMIT}"
  tagc="$(git -C "${LLAMA_CPP_DIR}" rev-parse -q --verify "refs/tags/${LLAMA_CPP_TAG}^{commit}" || true)"
  [[ "${tagc}" == "${EXPECTED_LLAMA_CPP_COMMIT}" ]] \
    || _lib_die "llama.cpp tag ${LLAMA_CPP_TAG} -> '${tagc:-<missing>}', expected ${EXPECTED_LLAMA_CPP_COMMIT}"
  LLAMA_CPP_TAG_TYPE="$(git -C "${LLAMA_CPP_DIR}" cat-file -t "refs/tags/${LLAMA_CPP_TAG}")"
  [[ "${LLAMA_CPP_TAG_TYPE}" == "${EXPECTED_LLAMA_CPP_TAG_TYPE}" ]] \
    || _lib_die "llama.cpp ${LLAMA_CPP_TAG} is a ${LLAMA_CPP_TAG_TYPE}, expected ${EXPECTED_LLAMA_CPP_TAG_TYPE}"
  if [[ "${LLAMA_CPP_TAG_TYPE}" == "tag" ]]; then
    tag_name="$(git -C "${LLAMA_CPP_DIR}" cat-file tag "refs/tags/${LLAMA_CPP_TAG}" | sed -n 's/^tag //p')"
    [[ "${tag_name}" == "${LLAMA_CPP_TAG}" ]] \
      || _lib_die "llama.cpp tag object names '${tag_name}', expected ${LLAMA_CPP_TAG}"
  fi
  LLAMA_CPP_DESCRIBE="$(git -C "${LLAMA_CPP_DIR}" describe --tags --exact-match HEAD 2>/dev/null || true)"
  [[ "${LLAMA_CPP_DESCRIBE}" == "${LLAMA_CPP_TAG}" ]] \
    || _lib_die "llama.cpp 'git describe --tags --exact-match' = '${LLAMA_CPP_DESCRIBE}', expected ${LLAMA_CPP_TAG}"
  dirty="$(git -C "${LLAMA_CPP_DIR}" status --porcelain --untracked-files=no)"
  [[ -z "${dirty}" ]] || _lib_die "llama.cpp checkout has local modifications: ${dirty}"
  LLAMA_CPP_DATE="$(git -C "${LLAMA_CPP_DIR}" show -s --format=%cI HEAD)"
}

verify_llama_cpp_embedded_version() {
  local header="$1"
  [[ -f "${header}" ]] || _lib_die "llama-version.h not found at ${header}"
  EMB_VERSION="$(sed -n 's/^#define LLAMA_VERSION *"\(.*\)"$/\1/p' "${header}")"
  EMB_COMMIT="$(sed -n 's/^#define LLAMA_COMMIT *"\(.*\)"$/\1/p' "${header}")"
  [[ "${#EMB_COMMIT}" -ge 7 && "${EXPECTED_LLAMA_CPP_COMMIT}" == "${EMB_COMMIT}"* ]] \
    || _lib_die "compiled llama.cpp commit '${EMB_COMMIT}' is not a prefix of ${EXPECTED_LLAMA_CPP_COMMIT}"
  [[ "${EMB_VERSION}" == "${EXPECTED_LLAMA_CPP_VERSION}" || "${EMB_VERSION}" == "${EXPECTED_LLAMA_CPP_VERSION}-dev" ]] \
    || _lib_die "compiled llama.cpp version '${EMB_VERSION}' != ${EXPECTED_LLAMA_CPP_VERSION}[-dev]"
}
# Prepare ${1} as the pinned llama-cpp-rs checkout with llama.cpp ${LLAMA_CPP_TAG}
# substituted for the crate's vendored submodule (strategy: no llama-cpp-rs release
# vendors ${LLAMA_CPP_TAG}; see config.env). Everything is verified by commit, never by a
# directory name or crate version. On success sets (global):
#   CRATE_COMMIT CRATE_GITLINK LLAMA_CPP_DIR LLAMA_CPP_COMMIT LLAMA_CPP_DESCRIBE
#   LLAMA_CPP_DATE LLAMA_CPP_TAG_TYPE
# Reuses an existing checkout only if it is exactly the pin; build.rs is always restored
# to pristine, so callers patch (or deliberately don't) from a known state.
prepare_crate_source() {
  local dest="$1" head tagc ver dirty
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
  verify_llama_cpp_source
  _lib_log "llama-cpp-rs ${CRATE_REF} @ ${CRATE_COMMIT} (llama-cpp-sys-2 ${CRATE_VERSION}; vendored ${CRATE_GITLINK:0:12} overridden)"
  _lib_log "llama.cpp ${LLAMA_CPP_DESCRIBE} @ ${LLAMA_CPP_COMMIT} (tag object type ${LLAMA_CPP_TAG_TYPE}, ${LLAMA_CPP_DATE})"
}

# --- N1 ISA injection (aarch64-graviton2 only) ------------------------------------------
# For Linux aarch64 (non-native) the crate hardcodes GGML_CPU_ARM_ARCH="armv8-a", which
# ggml turns into -march=armv8-a (no dotprod) on the CPU kernels. That define comes AFTER
# the crate's GGML_* env forwarding, so an env var cannot override it: rewrite the literal
# in the checked-out build.rs. Must run on a PRISTINE build.rs (prepare_crate_source
# restores it). Fails unless there was exactly one string-literal GGML_CPU_ARM_ARCH define,
# it was the expected literal, and afterwards exactly one literal define carries CPU_MARCH.
# (0.1.160 also has an Android-only `config.define("GGML_CPU_ARM_ARCH", &arch)` fed from
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
# GGML_ISA_DEFINES and GGML_BACKEND_DEFINES, or GENERIC_REF_GGML_DEFINES for the
# correctness reference); they reach CMake through the crate's GGML_* env forwarding for
# this one cargo invocation only, so assert_no_build_env_overrides still guarantees nothing
# else injects GGML_* options.
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
  installed="$(find "${libdirs[@]}" -maxdepth 1 -name '*.a' | sed 's|.*/||' | sort)"
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

# --- macOS (aarch64-apple-darwin) gates -------------------------------------------------
# The macOS archives must be apple-m1 code for macOS >= MACOS_DEPLOYMENT_TARGET that a
# consumer links with SYSTEM_LINK_LIBS alone. As with the x86 gates, each property is proven
# on what the compiler and linker actually did, not inferred from the requested flags:
#   apple_m1_isa_check   a TU's exact flags give apple-m1 in the frontend (feature macros)
#                        AND in the backend (the -cc1 job's -target-cpu / -target-feature);
#   macos_objects_check  every archive member is a thin arm64 Mach-O object for macOS with
#                        minos == the pin, built against the recorded SDK, and with no weak
#                        undefined symbol (an API newer than minos used without a guard);
#   archive_order_check  the STATIC_LIBS order resolves in one left-to-right pass;
#   macos_link_check     a C consumer links EVERY member (-all_load) with SYSTEM_LINK_LIBS
#                        only, each of them necessary, depends on system dylibs only (no
#                        framework), and runs with the CPU backend as the only backend.
APPLE_M1_REQUIRED_MACROS="__ARM_NEON __ARM_FEATURE_FMA __ARM_FEATURE_DOTPROD __ARM_FEATURE_FP16_VECTOR_ARITHMETIC __ARM_FEATURE_FP16_SCALAR_ARITHMETIC __ARM_FEATURE_FP16_FML __ARM_FEATURE_ATOMICS __ARM_FEATURE_QRDMX __ARM_FEATURE_RCPC __ARM_FEATURE_JCVT __ARM_FEATURE_COMPLEX __ARM_FEATURE_CRC32 __ARM_FEATURE_AES __ARM_FEATURE_SHA2 __ARM_FEATURE_SHA3 __ARM_FEATURE_SHA512 __ARM_FEATURE_FRINT"
APPLE_ABOVE_M1_MACRO_RE='^__ARM_(ARCH_(8_[6-9]|9[0-9_]*)__|FEATURE_(MATMUL_INT8|BF16[A-Z0-9_]*|SVE[A-Z0-9_]*|SME[A-Z0-9_]*|SM3|SM4|MEMORY_TAGGING|LS64|RNG|MOPS|CSSC|FP8[A-Z0-9_]*|GCS[A-Z0-9_]*))$'
# clang names the -mcpu=apple-m1 backend CPU by its alias apple-a14 (apple-m1 when it is
# the target's default CPU); both have the same feature set.
APPLE_M1_BACKEND_CPUS="apple-m1 apple-a14"
APPLE_M1_REQUIRED_TARGET_FEATURES="v8.5a neon fullfp16 fp16fml dotprod lse rdm rcpc crc aes sha2 sha3 jsconv complxnum"
APPLE_ABOVE_M1_TARGET_FEATURE_RE='^(v8\.[6-9]a|v9(\.[0-9])?a|i8mm|bf16|sve.*|sme.*|f32mm|f64mm|mte|ls64|fp8.*|cssc|mops|hbc|wfxt|gcs)$'

# apple_m1_isa_check COMPILER [FLAGS...]: on success print the backend CPU name; otherwise
# print the reason and return 1.
apple_m1_isa_check() {
  local cc="$1" defs m missing="" extra cc1 cpu feats f; shift
  defs="$("${cc}" "$@" -dM -E -x c /dev/null 2>&1)" || { echo "preprocessor failed: ${defs}"; return 1; }
  defs="$(sed -n 's/^#define \(__ARM_[A-Za-z0-9_]*\) .*/\1/p' <<<"${defs}")"
  for m in ${APPLE_M1_REQUIRED_MACROS}; do
    grep -qxF -- "${m}" <<<"${defs}" || missing+="${m} "
  done
  extra="$(grep -E -- "${APPLE_ABOVE_M1_MACRO_RE}" <<<"${defs}" | tr '\n' ' ' || true)"
  if [[ -n "${missing}" || -n "${extra}" ]]; then
    echo "frontend: missing apple-m1 features: ${missing:-none}; above-apple-m1 features: ${extra:-none}"
    return 1
  fi
  # The code generator's view: the -cc1 job clang would run. Its -target-feature list is
  # applied in order, so the last +name / -name of each feature wins.
  cc1="$("${cc}" "$@" -### -x c -c /dev/null -o /dev/null 2>&1)" || { echo "clang -### failed: ${cc1}"; return 1; }
  cpu="$(tr ' ' '\n' <<<"${cc1}" | tr -d '"' | awk 'p == "-target-cpu" { c = $0 } { p = $0 } END { print c }')"
  feats="$(tr ' ' '\n' <<<"${cc1}" | tr -d '"' | awk '
    p == "-target-feature" {
      n = substr($0, 2); st[n] = substr($0, 1, 1)
      if (!(n in seen)) { seen[n] = 1; ord[++k] = n }
    }
    { p = $0 }
    END { for (i = 1; i <= k; i++) if (st[ord[i]] == "+") print ord[i] }')"
  case " ${APPLE_M1_BACKEND_CPUS} " in
    *" ${cpu} "*) ;;
    *) echo "backend: -target-cpu '${cpu:-<none>}', expected one of: ${APPLE_M1_BACKEND_CPUS}"; return 1 ;;
  esac
  for f in ${APPLE_M1_REQUIRED_TARGET_FEATURES}; do
    grep -qxF -- "${f}" <<<"${feats}" || missing+="+${f} "
  done
  extra="$(grep -E -- "${APPLE_ABOVE_M1_TARGET_FEATURE_RE}" <<<"${feats}" | sed 's/^/+/' | tr '\n' ' ' || true)"
  if [[ -n "${missing}" || -n "${extra}" ]]; then
    echo "backend (-target-cpu ${cpu}): missing apple-m1 features: ${missing:-none}; above-apple-m1 features: ${extra:-none}"
    return 1
  fi
  echo "${cpu}"
}

# macos_objects_check MINOS SDK ARCHIVE...: on success print a JSON summary; otherwise
# print the reason and return 1.
macos_objects_check() {
  local minos="$1" sdk="$2" a archs members report weak total=0; shift 2
  for a in "$@"; do
    archs="$(lipo -archs "${a}" 2>&1)" || { echo "lipo failed on ${a}: ${archs}"; return 1; }
    [[ "${archs}" == arm64 ]] || { echo "${a}: architectures '${archs}', expected thin arm64"; return 1; }
    members="$(ar -t "${a}" | grep -vc '^__\.SYMDEF' || true)"
    report="$(otool -l "${a}" | awk -v want_min="${minos}" -v want_sdk="${sdk}" '
      /^[^ ].*\(.*\):$/ { m = $0; sub(/:$/, "", m); n++; bv[m] = 0; next }
      $1 == "cmd" {
        inbv = ($2 == "LC_BUILD_VERSION"); if (inbv) bv[m]++
        if ($2 ~ /^LC_VERSION_MIN_/) old[m] = " " $2
        next
      }
      inbv && $1 == "platform" { pl[m] = $2 }
      inbv && $1 == "minos"    { mi[m] = $2 }
      inbv && $1 == "sdk"      { sd[m] = $2 }
      END {
        bad = 0
        for (x in bv) if (bv[x] != 1 || pl[x] != "1" || mi[x] != want_min || sd[x] != want_sdk) {
          if (++bad <= 10) printf "  %s: LC_BUILD_VERSION x%d platform=%s minos=%s sdk=%s%s\n", x, bv[x], pl[x], mi[x], sd[x], old[x]
        }
        printf "members %d\n", n
        exit (bad > 0)
      }')" || { echo "${a}: objects not built for macOS (platform 1) minos ${minos} with SDK ${sdk}:"$'\n'"${report}"; return 1; }
    [[ "$(sed -n 's/^members //p' <<<"${report}")" == "${members}" && "${members}" -gt 0 ]] \
      || { echo "${a}: otool saw $(sed -n 's/^members //p' <<<"${report}") object(s), ar lists ${members}"; return 1; }
    total=$((total + members))
  done
  weak="$(nm -m "$@" | grep '(undefined) weak external' || true)"
  if [[ -n "${weak}" ]]; then
    echo "weak undefined symbols (an API newer than macOS ${minos} used without an availability guard): $(head -n 10 <<<"${weak}" | tr '\n' ' ')"
    return 1
  fi
  jq -n --argjson archives "$#" --argjson objects "${total}" --arg minos "${minos}" --arg sdk "${sdk}" \
    '{archives: $archives, objects: $objects, arch: "arm64", platform: "macos",
      minos: $minos, sdk: $sdk, weak_undefined: 0}'
}

# archive_order_check ARCHIVE...: the archives in link order. Fails (printing which) if an
# archive needs an external symbol that only an EARLIER archive defines, i.e. if the order
# could not be resolved in a single left-to-right pass.
archive_order_check() {
  local dir a i j n=$# report=""
  dir="$(mktemp -d)"
  i=0
  for a in "$@"; do
    nm -g --defined-only "${a}" | awk 'NF >= 3 { print $3 }' | sort -u >"${dir}/def.${i}" \
      && nm -g --undefined-only "${a}" | awk 'NF >= 1 && $0 !~ /:$/ { print $NF }' | sort -u >"${dir}/und.${i}" \
      || { rm -rf "${dir}"; echo "nm failed on ${a}"; return 1; }
    i=$((i + 1))
  done
  for ((i = 1; i < n; i++)); do
    : >"${dir}/later"; : >"${dir}/earlier"
    for ((j = 0; j < n; j++)); do
      if (( j < i )); then cat "${dir}/def.${j}" >>"${dir}/earlier"; else cat "${dir}/def.${j}" >>"${dir}/later"; fi
    done
    sort -u -o "${dir}/later" "${dir}/later"; sort -u -o "${dir}/earlier" "${dir}/earlier"
    comm -23 "${dir}/und.${i}" "${dir}/later" | comm -12 - "${dir}/earlier" >"${dir}/back"
    if [[ -s "${dir}/back" ]]; then
      report+="archive #$((i + 1)) needs $(wc -l <"${dir}/back" | tr -d ' ') symbol(s) only an earlier archive defines (e.g. $(head -n 5 "${dir}/back" | tr '\n' ' ')); "
    fi
  done
  rm -rf "${dir}"
  [[ -z "${report}" ]] || { echo "${report}"; return 1; }
}

# macos_link_check WORKDIR MINOS ARCHIVE...: link and run a C consumer of the archives (in
# link order) against SYSTEM_LINK_LIBS. On success print a JSON summary; otherwise print the
# reason and return 1. Needs ${DIST}/include (llama.h, ggml-backend.h) and ${CC}.
macos_link_check() {
  local work="$1" minos="$2" l k libs=() link=() deps dep out bv ldv; shift 2
  mkdir -p "${work}"
  cat >"${work}/link-probe.c" <<'PROBE'
#include <stdio.h>
#include "ggml-backend.h"
#include "llama.h"
int main(void) {
    llama_backend_init();
    for (size_t i = 0; i < ggml_backend_reg_count(); i++) {
        printf("backend %s\n", ggml_backend_reg_name(ggml_backend_reg_get(i)));
    }
    printf("system_info %s\n", llama_print_system_info());
    llama_backend_free();
    return 0;
}
PROBE
  for l in ${SYSTEM_LINK_LIBS}; do libs+=("-l${l}"); done
  link=("${CC}" -mmacosx-version-min="${minos}" -I"${DIST}/include" "${work}/link-probe.c"
        -Wl,-all_load "$@")
  out="$("${link[@]}" ${libs[@]+"${libs[@]}"} -Wl,-fatal_warnings -o "${work}/link-probe" 2>&1)" \
    || { echo "link with ${libs[*]:-no system libs} (-all_load, every member) failed: ${out}"; return 1; }
  # Each SYSTEM_LINK_LIBS entry is NEEDED: leaving any one out must break the link.
  for l in ${SYSTEM_LINK_LIBS}; do
    libs=(); for k in ${SYSTEM_LINK_LIBS}; do [[ "${k}" == "${l}" ]] || libs+=("-l${k}"); done
    if "${link[@]}" ${libs[@]+"${libs[@]}"} -o "${work}/link-probe-without" >/dev/null 2>&1; then
      echo "the archives also link without -l${l}: SYSTEM_LINK_LIBS is not minimal"; return 1
    fi
  done
  # Runtime dependencies: libSystem plus exactly the SYSTEM_LINK_LIBS dylibs, all from
  # /usr/lib; no framework, nothing outside the OS.
  deps="$(otool -L "${work}/link-probe" | tail -n +2 | awk '{ print $1 }')"
  while IFS= read -r dep; do
    [[ "${dep}" == /usr/lib/libSystem.B.dylib ]] && continue
    for l in ${SYSTEM_LINK_LIBS}; do [[ "${dep}" == /usr/lib/lib"${l}".*dylib ]] && continue 2; done
    echo "unexpected runtime dependency ${dep} (allowed: /usr/lib/libSystem.B.dylib and SYSTEM_LINK_LIBS '${SYSTEM_LINK_LIBS}')"; return 1
  done <<<"${deps}"
  grep -qx /usr/lib/libSystem.B.dylib <<<"${deps}" || { echo "no libSystem dependency: ${deps}"; return 1; }
  for l in ${SYSTEM_LINK_LIBS}; do
    grep -qF "/usr/lib/lib${l}." <<<"${deps}" || { echo "no runtime dependency on lib${l}: ${deps}"; return 1; }
  done
  bv="$(otool -l "${work}/link-probe" | awk '$1 == "cmd" { inbv = ($2 == "LC_BUILD_VERSION") } inbv && $1 == "minos" { print $2 }')"
  [[ "${bv}" == "${minos}" ]] || { echo "consumer binary minos '${bv}', expected ${minos}"; return 1; }
  out="$("${work}/link-probe" 2>&1)" || { echo "consumer binary failed to run: ${out}"; return 1; }
  [[ "$(sed -n 's/^backend //p' <<<"${out}")" == CPU ]] \
    || { echo "expected the CPU backend as the only ggml backend, got: $(sed -n 's/^backend //p' <<<"${out}" | tr '\n' ' ')"; return 1; }
  ldv="$(ld -v 2>&1 || true)"
  jq -n --arg linker "$(head -n 1 <<<"${ldv}")" --arg libs "${SYSTEM_LINK_LIBS}" --arg deps "${deps}" \
        --arg minos "${minos}" --arg info "$(sed -n 's/^system_info //p' <<<"${out}")" \
    '{passed: true, linker: $linker, mode: "-Wl,-all_load -Wl,-fatal_warnings",
      system_libs: ($libs | split(" ") | map(select(. != ""))), each_system_lib_required: true,
      runtime_dylibs: ($deps | split("\n") | map(select(. != ""))), frameworks: [],
      minos: $minos, backends: ["CPU"], system_info: $info}'
}

# --- Pinned test models -----------------------------------------------------------------
# fetch_pinned_model URL SHA256 DEST: make DEST the file whose SHA-256 is SHA256, reusing a
# verified copy or downloading URL. A download that does not verify is never moved into
# place, so DEST only ever holds the pinned bytes. The digests are compared here rather
# than with `sha256sum -c`: macOS's sha256sum -c exits 0 on a malformed or empty checksum
# line, so a mistyped pin would have verified any file.
fetch_pinned_model() {
  local url="$1" sha="$2" dest="$3" got
  [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] \
    || _lib_die "pinned SHA-256 for ${url} is not 64 lowercase hex digits: '${sha}'"
  mkdir -p "$(dirname "${dest}")"
  if [[ -f "${dest}" ]] && [[ "$(sha256_file "${dest}" || true)" == "${sha}" ]]; then
    return 0
  fi
  _lib_log "fetching ${url}"
  curl -fSL --retry 3 "${url}" -o "${dest}.download"
  got="$(sha256_file "${dest}.download")" || _lib_die "cannot hash ${dest}.download"
  [[ "${got}" == "${sha}" ]] \
    || _lib_die "${url} does not match the pinned SHA-256 ${sha} (got ${got})"
  mv "${dest}.download" "${dest}"
}

# --- Release results ------------------------------------------------------------------
# The one definition of the results a release must carry (CONTRACT.md "Guarantees"). The
# packaging gate (package.sh) and the verifier (verify-provenance.sh, after packaging and in
# the release job) both call this, so they cannot drift. BUILD_INFO is a build-info.json,
# into which package.sh merges each result verbatim. A result passes when it is an object
# with `passed == true` (the boolean) and carries every field of its entry in the pins
# below. Missing means absent or null (build.sh writes null placeholders).
#   MODE packaged  every result must be present and pass (any packaged build-info.json);
#   MODE raw       fresh build.sh metadata has no results yet: none is required, but a
#                  result that is present must still pass.
# Dies listing every problem, one `.path: actual, expected ...` entry each.
#
# The output semantics of contract v6 (CONTRACT.md "Output semantics"): both pooled smoke
# runs found no host logits, and the generative control found them exactly here. The modes
# are the ones smoke/src/main.rs LOGITS_MODES runs.
LOGITS_SMOKE_HOST_LOGITS='{"generation":true,"embeddings_none":true,"embeddings_mean":false,"embeddings_mean_set_off":true,"embeddings_mean_set_on":false,"embeddings_last":false,"embeddings_cls":false}'
assert_release_results() {
  local mode="$1" build_info="$2" problems
  [[ "${mode}" == packaged || "${mode}" == raw ]] \
    || _lib_die "assert_release_results: unknown mode '${mode}' (expected packaged or raw)"
  problems="$(jq -r \
    --arg mode "${mode}" \
    --arg eg_model "${EMBEDDINGGEMMA_MODEL_ID}" \
    --arg eg_sha "${EMBEDDINGGEMMA_MODEL_SHA256}" \
    --argjson eg_hidden "${EMBEDDINGGEMMA_HIDDEN_DIM}" \
    --argjson eg_output "${EMBEDDINGGEMMA_OUTPUT_DIM}" \
    --arg ls_model "${LOGITS_SMOKE_MODEL_ID}" \
    --arg ls_sha "${LOGITS_SMOKE_MODEL_SHA256}" \
    --argjson ls_logits "${LOGITS_SMOKE_HOST_LOGITS}" \
    '{smoke: {host_logits: false},
      embeddinggemma_smoke: {model_id: $eg_model, model_sha256: $eg_sha, n_embd: $eg_hidden,
                             n_embd_out: $eg_output, host_logits: false},
      logits_smoke: {model_id: $ls_model, model_sha256: $ls_sha, host_logits: $ls_logits}} as $pins
     | ("smoke", "embeddinggemma_smoke", "logits_smoke", "benchmark", "correctness") as $k
     | .[$k] as $r
     | if $r == null then (if $mode == "packaged" then ".\($k): missing" else empty end)
       elif ($r | type) != "object" then ".\($k): \($r | tojson), expected a result object"
       elif $r.passed != true then ".\($k).passed: \($r.passed | tojson), expected true"
       else
         ($pins[$k] // {}) | to_entries[] | select($r[.key] != .value)
         | ".\($k).\(.key): \($r[.key] | tojson), expected \(.value | tojson)"
       end' "${build_info}")" \
    || _lib_die "cannot read release results from ${build_info}"
  [[ -z "${problems}" ]] \
    || _lib_die "release results rejected (${mode}): ${problems//$'\n'/; }"
}
