#!/usr/bin/env bash
#
# Build the static llama.cpp archives for the NATIVE host's target profile (config.env):
#   aarch64 host -> aarch64-graviton2  (-O3 -march=armv8.2-a+fp16+dotprod+rcpc -mtune=neoverse-n1)
#   x86_64 host  -> x86_64-v3          (-O3 -march=x86-64-v3, generic tuning)
# THROUGH the pinned llama-cpp-sys-2 crate, so the harvested .a + bindings.rs are
# byte-for-byte what a from-source crate build would produce (this is what bench parity
# compares against).
#
# Output: $DIST/{lib,include,bindings.rs,build-info.json}
#
# Usage: scripts/build.sh   (run inside the AL2023 build container of the NATIVE host arch —
#                            cross-compilation / emulation is refused; an x86_64 host must be
#                            x86-64-v3 capable, there is no lower-baseline fallback)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"
LIB_TAG=build
source "${ROOT}/scripts/lib.sh"

WORK="${WORK:-${ROOT}/.build}"
DIST="${DIST:-${ROOT}/dist}"
SRC="${WORK}/llama-cpp-rs"

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build:ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# --- -1. Native-host + build-input gates (before anything is fetched or deleted) ----
# Artifacts are only ever compiled on a native host of the target arch (and, for x86_64,
# an x86-64-v3 capable one); see scripts/lib.sh. The profile comes from `uname -m` via
# config.env and is never negotiated: CPU_MARCH is fixed per profile.
assert_native_host
assert_no_build_env_overrides
log "Native host: $(uname -m) (kernel arch $(cat /proc/sys/kernel/arch 2>/dev/null || echo n/a)), target ${TARGET_TRIPLE}"
log "Target profile: ${TARGET_PROFILE} (CPU baseline ${CPU_BASELINE}; flags ${CFLAGS_TUNE})"
# Profile-specific ggml ISA options (x86_64: the v3 set ON, everything above v3 OFF), passed
# to the crate's GGML_* forwarding for the build_sys_crate calls only.
read -r -a ISA_DEFS <<<"${GGML_ISA_DEFINES}"

rm -rf "${DIST}"
mkdir -p "${WORK}" "${DIST}/lib" "${DIST}/include"

# --- 0. Build-environment envelope gate -------------------------------------------
# The AL2023 base is resolved (not a controlled runtime pin), so guard against drift:
# a different clang major or an older glibc could change codegen/ABI or raise the runtime
# floor. Fail fast if the observed toolchain leaves the supported envelope.
# Capture-then-parse full --version output (NOT `... | head -n1`): under `set -o pipefail`,
# head closing the pipe early makes the tool exit via SIGPIPE and spuriously fail. Note we
# parse `--version` (not -dumpversion — clang prints gcc-compat "4.2.1" for that).
cc_raw="$(${CC:-cc} --version 2>/dev/null || true)"
if [[ "${cc_raw}" =~ version[[:space:]]+([0-9]+) ]]; then CC_MAJOR="${BASH_REMATCH[1]}"; else CC_MAJOR="0"; fi
glibc_raw="$(ldd --version 2>/dev/null || true)"
if [[ "${glibc_raw}" =~ ([0-9]+\.[0-9]+) ]]; then GLIBC_VER="${BASH_REMATCH[1]}"; else GLIBC_VER="0"; fi
log "Env: ${CC:-cc} major=${CC_MAJOR} (expect ${EXPECTED_CLANG_MAJOR}), glibc=${GLIBC_VER} (min ${MIN_GLIBC})"
[[ "${CC_MAJOR}" == "${EXPECTED_CLANG_MAJOR}" ]] \
  || die "ENVELOPE: clang major ${CC_MAJOR} != expected ${EXPECTED_CLANG_MAJOR} (codegen/ABI drift risk)"
# glibc must be >= MIN_GLIBC — integer major/minor compare (whitespace-immune).
gmaj="${GLIBC_VER%%.*}"; gmin="${GLIBC_VER#*.}"; gmin="${gmin%%.*}"
mmaj="${MIN_GLIBC%%.*}"; mmin="${MIN_GLIBC#*.}"; mmin="${mmin%%.*}"
if (( gmaj < mmaj || (gmaj == mmaj && gmin < mmin) )); then
  die "ENVELOPE: glibc ${GLIBC_VER} is below the supported floor ${MIN_GLIBC}"
fi

# --- 1. Fetch + verify the pinned sources ------------------------------------------
# llama-cpp-rs @ CRATE_REF (== EXPECTED_CRATE_COMMIT) with llama.cpp LLAMA_CPP_TAG
# (== EXPECTED_LLAMA_CPP_COMMIT) in its llama.cpp path. Fails closed on any mismatch.
prepare_crate_source "${SRC}"

if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
  # Point ggml's CPU backend at N1's ISA (dotprod) instead of its default -march=armv8-a.
  patch_ggml_arm_arch "${SRC}/llama-cpp-sys-2/build.rs" \
    || die "Failed to inject GGML_CPU_ARM_ARCH into build.rs (upstream layout changed?)"
  log "Patched build.rs: GGML_CPU_ARM_ARCH=${CPU_MARCH}"
else
  # x86_64: nothing to patch. The baseline is CFLAGS -march=${CPU_MARCH} plus the explicit
  # GGML_* ISA options above (GGML_NATIVE is forced OFF by the crate and gated below).
  log "x86_64: ggml ISA options: ${GGML_ISA_DEFINES}"
fi

# --- 2a. PGO instrument + train (only when PGO=1) ---------------------------------
# Off by default. When PGO=1: build an instrumented copy in a SEPARATE target dir (so
# cmake/ninja truly recompile), run the real embedding hot path against a representative
# model to collect a profile, then feed -fprofile-use into the shipped build below. Only
# the final (optimized) build is harvested/gated; the instrumented build is throwaway.
PGO_USE_FLAGS=""            # appended to the shipped build's CFLAGS/CXXFLAGS when PGO=1
PGO_PROFDATA=""            # set to the merged profile path when PGO=1 (recorded in build-info)
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"
if [[ "${PGO}" == "1" ]]; then
  [[ -n "${PGO_TRAIN_MODEL}" && -f "${PGO_TRAIN_MODEL}" ]] \
    || die "PGO=1 needs PGO_TRAIN_MODEL to point at a readable GGUF (got: '${PGO_TRAIN_MODEL}')"
  # llvm-profdata ships in the llvm18 package (binary name/path varies); resolve robustly.
  LLVM_PROFDATA="$(command -v llvm-profdata-18 || command -v llvm-profdata \
                   || echo /usr/lib64/llvm18/bin/llvm-profdata)"
  [[ -x "${LLVM_PROFDATA}" ]] || die "llvm-profdata not found (install the llvm18 package in the build image)"

  PGO_DIR="${WORK}/pgo"
  PGO_GEN_TARGET="${PGO_DIR}/target-gen"    # instrumented build's CARGO_TARGET_DIR
  PGO_GEN_HARVEST="${PGO_DIR}/gen"          # harvested instrumented .a (+ bindings) for the train link
  PGO_GEN_LIBS="${PGO_GEN_HARVEST}/lib"
  PGO_RAW="${PGO_DIR}/raw"                  # *.profraw drop
  PGO_PROFDATA="${PGO_DIR}/pgo.profdata"    # merged profile consumed by -fprofile-use
  PGO_META="${PGO_DIR}/pgo.meta.json"       # which arch/baseline the profile was trained for
  rm -rf "${PGO_DIR}"; mkdir -p "${PGO_GEN_HARVEST}" "${PGO_RAW}"

  # (1) Instrumented build. -fprofile-generate is added to the SAME profile flags as the
  #     shipped build (x86_64: -march=x86-64-v3, never native); a distinct CARGO_TARGET_DIR
  #     guarantees a clean recompile independent of the final one.
  log "PGO 1/3: instrumented build (${CFLAGS_TUNE} ${PGO_GEN_FLAGS})"
  ( export CFLAGS="${CFLAGS_TUNE} ${PGO_GEN_FLAGS} ${CFLAGS:-}"
    export CXXFLAGS="${CFLAGS_TUNE} ${PGO_GEN_FLAGS} ${CXXFLAGS:-}"
    export CARGO_TARGET_DIR="${PGO_GEN_TARGET}"
    build_sys_crate "${SRC}" ${ISA_DEFS[@]+"${ISA_DEFS[@]}"} )
  GEN_OUT="$(find_sys_out_dir "${PGO_GEN_TARGET}")"   # assignment: a failure aborts (set -e)
  harvest_sys_outputs "${GEN_OUT}" "${PGO_GEN_HARVEST}"

  # (2) Train. Link scripts/pgo-train.cpp against the instrumented archives with clang++
  #     (so libclang_rt.profile is auto-linked and __llvm_profile_* resolve), run the
  #     embedding workload, and merge the emitted *.profraw into one profile.
  log "PGO 2/3: training on $(basename "${PGO_TRAIN_MODEL}") (${PGO_TRAIN_ITERS} iters)"
  PGO_TRAIN_BIN="${PGO_DIR}/pgo-train"
  # shellcheck disable=SC2046  # word-splitting SYSTEM_LINK_LIBS into -l flags is intended.
  # -g -rdynamic so a SIGSEGV in the training run yields a symbolized backtrace (the harness
  # installs a handler); -O2 keeps the profiled hot path representative.
  "${CXX}" ${PGO_GEN_FLAGS} -O2 -g -rdynamic \
    -I"${LLAMA_CPP_DIR}/include" -I"${LLAMA_CPP_DIR}/ggml/include" \
    "${ROOT}/scripts/pgo-train.cpp" \
    "${PGO_GEN_LIBS}/libllama.a" "${PGO_GEN_LIBS}/libggml.a" \
    "${PGO_GEN_LIBS}/libggml-cpu.a" "${PGO_GEN_LIBS}/libggml-base.a" \
    $(for l in ${SYSTEM_LINK_LIBS}; do printf -- '-l%s ' "$l"; done) \
    -o "${PGO_TRAIN_BIN}" \
    || die "PGO: failed to build/link the training harness"
  LLVM_PROFILE_FILE="${PGO_RAW}/pgo-%p.profraw" \
    "${PGO_TRAIN_BIN}" "${PGO_TRAIN_MODEL}" "${PGO_TRAIN_ITERS}" \
    || die "PGO: training run failed"
  "${LLVM_PROFDATA}" merge -output="${PGO_PROFDATA}" "${PGO_RAW}"/*.profraw \
    || die "PGO: llvm-profdata merge failed"
  [[ -s "${PGO_PROFDATA}" ]] || die "PGO: merged profile is empty (${PGO_PROFDATA})"
  # Bind the profile to this arch + baseline: a profile is never reused across profiles
  # (bench.sh refuses a pgo.profdata whose meta names another arch/baseline).
  jq -n --arg arch "${TARGET_ARCH}" --arg triple "${TARGET_TRIPLE}" --arg prof "${TARGET_PROFILE}" \
        --arg baseline "${CPU_BASELINE}" --arg flags "${CFLAGS_TUNE}" \
        --arg sha "$(sha256sum "${PGO_PROFDATA}" | awk '{print $1}')" \
        '{architecture: $arch, target_triple: $triple, target_profile: $prof,
          cpu_baseline: $baseline, training_flags: $flags, profdata_sha256: $sha}' >"${PGO_META}"
  PGO_USE_FLAGS="-fprofile-use=${PGO_PROFDATA} ${PGO_USE_WARN_FLAGS}"
  log "PGO 3/3: optimized build with -fprofile-use ($(basename "${PGO_PROFDATA}"))"
fi

# --- 2. Build the -sys crate with the profile's flags --------------------------------
# CFLAGS/CXXFLAGS apply ${CFLAGS_TUNE} to ALL TUs.
#   aarch64: -O3 -march=${CPU_MARCH} -mtune; ggml also adds -march=${CPU_MARCH} to its CPU
#            kernels (via the GGML_CPU_ARM_ARCH patch above) — the SAME value, no conflict.
#   x86_64:  -O3 -march=x86-64-v3 (generic tuning, no -mtune); ggml adds -msse4.2 -mavx
#            -mavx2 -mbmi2 -mf16c -mfma to its CPU kernels — all inside v3.
# No -mcpu, no -flto (see config.env). When PGO=1, ${PGO_USE_FLAGS} adds -fprofile-use
# (no -march/-mcpu, so the flag gate below is unaffected).
export CFLAGS="${CFLAGS_TUNE} ${PGO_USE_FLAGS} ${CFLAGS:-}"
export CXXFLAGS="${CFLAGS_TUNE} ${PGO_USE_FLAGS} ${CXXFLAGS:-}"
export CMAKE_EXPORT_COMPILE_COMMANDS=ON        # for the flag-verification gate
# Always a clean, explicitly-placed target dir: a cached OUT_DIR from an earlier run (other
# flags, features, or a non-PGO build) must never be harvested, and an inherited
# CARGO_TARGET_DIR must not redirect the build away from what is gated below.
export CARGO_TARGET_DIR="${SRC}/target"
rm -rf "${CARGO_TARGET_DIR}"

# No --target: host == target (native, asserted above), so plain CFLAGS is reliably
# honored by cc/cmake-rs. The triple is still recorded in build-info.json for provenance.
log "Building llama-cpp-sys-2 (--no-default-features; features: '${CRATE_FEATURES}')"
log "  CFLAGS=${CFLAGS}"
build_sys_crate "${SRC}" ${ISA_DEFS[@]+"${ISA_DEFS[@]}"}

OUT_DIR="$(find_sys_out_dir "${CARGO_TARGET_DIR}")"
log "OUT_DIR=${OUT_DIR}"

# --- 3a. CMake configuration gate --------------------------------------------------
# Prove the options that define this artifact were what CMake actually configured (not
# just what we asked for): CMake itself saw a native (non-cross) build for the target
# arch, nothing native/OpenMP/LTO/shared/dynamic-backend/common slipped in, and
#   aarch64: the N1 ISA reached ggml, and ggml's own ARM feature probes saw dotprod+fp16
#            but none of the features N1 lacks (SVE, i8mm, SME);
#   x86_64:  exactly the v3 ggml ISA options are ON and every above-v3 one (AVX-VNNI,
#            AVX-512*, AMX*) is OFF.
CMAKE_CACHE="${OUT_DIR}/build/CMakeCache.txt"
[[ -f "${CMAKE_CACHE}" ]] || die "CMakeCache.txt not found at ${CMAKE_CACHE}"
cache_get() { cmake_cache_get "${CMAKE_CACHE}" "$1"; }
cache_expect() {
  local got
  got="$(cache_get "$1")" || die "GATE: CMake cache has no $1 entry"
  [[ "${got}" == "$2" ]] || die "GATE: CMake cache $1='${got}', expected '$2'"
}
CMAKE_SYSTEM_FILE="$(find "${OUT_DIR}/build/CMakeFiles" -maxdepth 2 -name CMakeSystem.cmake -print -quit)"
[[ -n "${CMAKE_SYSTEM_FILE}" ]] || die "GATE: CMakeSystem.cmake not found under ${OUT_DIR}/build/CMakeFiles"
cmake_sys() { sed -n "s/^set(${1} \"\(.*\)\")\$/\1/p" "${CMAKE_SYSTEM_FILE}"; }
[[ "$(cmake_sys CMAKE_SYSTEM_PROCESSOR)" == "${TARGET_ARCH}" \
   && "$(cmake_sys CMAKE_HOST_SYSTEM_PROCESSOR)" == "${TARGET_ARCH}" \
   && "$(cmake_sys CMAKE_CROSSCOMPILING)" == "FALSE" ]] \
  || die "GATE: CMake did not configure a native ${TARGET_ARCH} build (system=$(cmake_sys CMAKE_SYSTEM_PROCESSOR), host=$(cmake_sys CMAKE_HOST_SYSTEM_PROCESSOR), crosscompiling=$(cmake_sys CMAKE_CROSSCOMPILING))"
cache_expect CMAKE_BUILD_TYPE      Release
cache_expect GGML_NATIVE           OFF
cache_expect GGML_OPENMP           OFF
cache_expect GGML_LTO              OFF
cache_expect GGML_BACKEND_DL       OFF
cache_expect GGML_CPU_ALL_VARIANTS OFF
cache_expect BUILD_SHARED_LIBS     OFF
cache_expect LLAMA_BUILD_COMMON    OFF
if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
  cache_expect GGML_CPU_ARM_ARCH     "${CPU_MARCH}"
  cache_expect HAVE_DOTPROD          1
  cache_expect HAVE_FP16_VECTOR_ARITHMETIC 1
  for f in HAVE_SVE HAVE_MATMUL_INT8 HAVE_SME; do
    v="$(cache_get "${f}")" || die "GATE: CMake cache has no ${f} entry (ggml ARM feature probe missing)"
    [[ -z "${v}" || "${v}" == 0 ]] || die "GATE: ggml probed ${f}=${v} — not an N1 feature (-march leak?)"
  done
  log "GATE PASSED: CMake cache (native ${TARGET_ARCH}, GGML_CPU_ARM_ARCH=${CPU_MARCH}, native/openmp/lto/shared/common OFF, dotprod+fp16 on, no SVE/i8mm/SME)"
else
  [[ "${#ISA_DEFS[@]}" -gt 0 ]] || die "GATE: profile ${TARGET_PROFILE} has no GGML_ISA_DEFINES"
  for d in "${ISA_DEFS[@]}"; do cache_expect "${d%%=*}" "${d#*=}"; done
  log "GATE PASSED: CMake cache (native ${TARGET_ARCH}, GGML_NATIVE OFF, v3 ISA options ON, AVX-VNNI/AVX-512/AMX OFF, openmp/lto/shared/common OFF)"
fi

# --- 3b. Embedded-version gate -------------------------------------------------------
# llama.cpp bakes its version + commit into llama-version.h (-> llama_version()); it must
# name the pinned commit, independently of the git checks in prepare_crate_source.
VERSION_H="${OUT_DIR}/build/src/llama-version.h"
[[ -f "${VERSION_H}" ]] || die "llama-version.h not found at ${VERSION_H}"
EMB_VERSION="$(sed -n 's/^#define LLAMA_VERSION *"\(.*\)"$/\1/p' "${VERSION_H}")"
EMB_COMMIT="$(sed -n 's/^#define LLAMA_COMMIT *"\(.*\)"$/\1/p' "${VERSION_H}")"
[[ "${#EMB_COMMIT}" -ge 7 && "${EXPECTED_LLAMA_CPP_COMMIT}" == "${EMB_COMMIT}"* ]] \
  || die "GATE: compiled llama.cpp reports commit '${EMB_COMMIT}', expected a prefix of ${EXPECTED_LLAMA_CPP_COMMIT}"
# LLAMA_BUILD_IS_DEV defaults ON upstream (the crate cannot override it), so the tag's
# version is reported as "<X.Y.Z>-dev"; accept exactly that or the bare version.
[[ "${EMB_VERSION}" == "${LLAMA_CPP_TAG#v}" || "${EMB_VERSION}" == "${LLAMA_CPP_TAG#v}-dev" ]] \
  || die "GATE: compiled llama.cpp reports version '${EMB_VERSION}', expected ${LLAMA_CPP_TAG#v}[-dev]"
log "GATE PASSED: compiled llama.cpp version ${EMB_VERSION}, commit ${EMB_COMMIT}"

# --- 3c. Flag-verification gate (PER compile command) -----------------------------
# The contract names an exact CPU baseline, so we prove it per translation unit. For EVERY
# compile command:
#   * no command may use `native` (-march/-mcpu/-mtune=native: host-dependent ISA) — fatal,
#   * no -flto, no OpenMP (-fopenmp / GGML_USE_OPENMP), no instrumentation
#     (-fprofile-generate / -fprofile-instr-generate) in the shipped build — fatal,
#   * no -mcpu, no -march other than ${CPU_MARCH}, and any clang --target= must name the
#     native ${TARGET_ARCH} — fatal,
#   * every C/C++ TU (.c/.cc/.cpp/.cxx) must have an effective -O3 and (PGO=1)
#     -fprofile-use=<the trained profile>.
# aarch64 (Graviton2):
#   * every C/C++ TU carries -mtune=${CPU_MTUNE}; the dotprod -march=${CPU_MARCH} must appear
#     on the CPU-backend TUs (>=1).
# x86_64 (x86-64-v3):
#   * every C/C++ TU carries -march=x86-64-v3; NO -mtune at all (generic tuning — no vendor
#     tuning), so -march=x86-64 / -v2 / -v4 / native are all conflicts,
#   * every other -m flag must be in X86_V3_ALLOWED_M (v3-subset ISA flags ggml adds, -m64);
#     anything else (-mavx512*, -mamx*, -mavxvnni, -mno-*, ...) is fatal, as is any
#     -D__AVX512* / -D__AMX* / -D__AVXVNNI* / -DGGML_AVX512* / -DGGML_AMX* / -DGGML_AVX_VNNI,
#   * the ggml ISA TUs (-DGGML_AVX2) must be >=1, and the EFFECTIVE ISA of every distinct
#     compiler+flag set is checked by preprocessing (x86_isa_macro_check v3).
CC_JSON="$(find "${OUT_DIR}" -name compile_commands.json -print -quit)"
[[ -n "${CC_JSON}" ]] || die "compile_commands.json not found; cannot verify flags"

# CMake emits either .command (string) or .arguments (array) depending on generator.
# (while-read, not mapfile, to stay portable to bash 3.2.)
CMDS=()
while IFS= read -r line; do CMDS+=("${line}"); done < <(compile_commands_lines "${CC_JSON}")
[[ "${#CMDS[@]}" -gt 0 ]] || die "compile_commands.json had no entries"

X86_V3_ALLOWED_M='-m64|-mmmx|-msse|-msse2|-msse3|-mssse3|-msse4|-msse4\.1|-msse4\.2|-mpopcnt|-mcx16|-msahf|-mfxsr|-mxsave|-mavx|-mavx2|-mbmi|-mbmi2|-mf16c|-mfma|-mlzcnt|-mmovbe'
ccxx_total=0; march_tus=0; isa_tus=0; conflicts=0; untuned=0; unmarched=0; badopt=0; nopgo=0
conflict_examples=""; untuned_examples=""; unmarched_examples=""; badopt_examples=""; nopgo_examples=""
declare -A ISA_SETS=()      # x86_64: distinct "compiler + ISA flags" sets -> example TU
for cmd in "${CMDS[@]}"; do
  # native anywhere is fatal.
  if grep -qE -- '-m(cpu|arch|tune)=native' <<<"${cmd}"; then
    conflicts=$((conflicts+1)); conflict_examples+="[native] "; continue
  fi
  # LTO anywhere is fatal: clang -flto emits LLVM bitcode objects, unlinkable as a
  # native prebuilt .a by the consumer's GNU ld / rustc cc driver.
  if grep -qE -- '-flto' <<<"${cmd}"; then
    conflicts=$((conflicts+1)); conflict_examples+="[flto] "; continue
  fi
  # OpenMP anywhere is fatal: it would add a libgomp/libomp runtime dep to the link line.
  if grep -qE -- '-fopenmp|-DGGML_USE_OPENMP' <<<"${cmd}"; then
    conflicts=$((conflicts+1)); conflict_examples+="[openmp] "; continue
  fi
  # Instrumentation in the SHIPPED build is fatal (it would need the profile runtime).
  if grep -qE -- '-fprofile-(instr-)?generate' <<<"${cmd}"; then
    conflicts=$((conflicts+1)); conflict_examples+="[profile-generate] "; continue
  fi
  # -mcpu should never appear; any -march other than our exact CPU_MARCH is a conflict; a
  # clang --target= for another arch would be a cross compile.
  bad_mcpu="$(grep -oE -- '-mcpu=[^ ]+' <<<"${cmd}" || true)"
  bad_march="$(grep -oE -- '-march=[^ ]+' <<<"${cmd}" | grep -vxF -- "-march=${CPU_MARCH}" || true)"
  bad_target="$(grep -oE -- '--target=[^ ]+' <<<"${cmd}" | grep -v -- "^--target=${TARGET_ARCH}-" || true)"
  if [[ -n "${bad_mcpu}" || -n "${bad_march}" || -n "${bad_target}" ]]; then
    conflicts=$((conflicts+1)); conflict_examples+="${bad_mcpu}${bad_march}${bad_target} "
  fi
  grep -qF -- "-march=${CPU_MARCH}" <<<"${cmd}" && march_tus=$((march_tus+1)) || true
  if [[ "${TARGET_ARCH}" == "x86_64" ]]; then
    # Generic tuning only: any -mtune (vendor or otherwise) is a conflict.
    bad_tune="$(grep -oE -- '-mtune=[^ ]+' <<<"${cmd}" | tr '\n' ' ' || true)"
    bad_m="$(grep -oE -- '(^| )-m[^ ]+' <<<"${cmd}" | sed 's/^ //' \
             | grep -vE -- '^-m(arch|tune|cpu)=' | grep -vxE -- "${X86_V3_ALLOWED_M}" | tr '\n' ' ' || true)"
    bad_def="$(grep -oE -- '-D(__AVX512|__AMX|__AVXVNNI|GGML_AVX512|GGML_AMX|GGML_AVX_VNNI)[^ ]*' <<<"${cmd}" | tr '\n' ' ' || true)"
    if [[ -n "${bad_tune}${bad_m}${bad_def}" ]]; then
      conflicts=$((conflicts+1)); conflict_examples+="${bad_tune}${bad_m}${bad_def}"
    fi
    grep -qE -- '-DGGML_AVX2( |=|$)' <<<"${cmd}" && isa_tus=$((isa_tus+1)) || true
  fi
  # Per C/C++ TU: profile tuning AND effective -O3 (last -O flag == -O3).
  if grep -qiE -- '-c( |$)' <<<"${cmd}" && grep -qiE -- '\.(c|cc|cpp|cxx|c\+\+)( |$|")' <<<"${cmd}"; then
    ccxx_total=$((ccxx_total+1))
    src="$(grep -oE -- '[^ ]+\.(c|cc|cpp|cxx|c\+\+)' <<<"${cmd}" | head -n1 || true)"
    if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
      if ! grep -qF -- "-mtune=${CPU_MTUNE}" <<<"${cmd}"; then
        untuned=$((untuned+1)); untuned_examples+="${src} "
      fi
    else
      if ! grep -qF -- "-march=${CPU_MARCH}" <<<"${cmd}"; then
        unmarched=$((unmarched+1)); unmarched_examples+="${src} "
      fi
      # Effective-ISA key: the compiler plus every -m / --target flag, in command order.
      isa_key="${cmd%% *} $(grep -oE -- '(^| )(-m[^ ]+|--target=[^ ]+)' <<<"${cmd}" | tr -d '\n' | sed 's/^ //')"
      ISA_SETS["${isa_key}"]="${src}"
    fi
    # Effective optimization = the LAST -O flag on the command line.
    last_opt="$(grep -oE -- '-O[0-9sgz]' <<<"${cmd}" | tail -n1 || true)"
    if [[ "${last_opt}" != "-O3" ]]; then
      badopt=$((badopt+1)); badopt_examples+="${src}(${last_opt:-none}) "
    fi
    if [[ -n "${PGO_PROFDATA}" ]] && ! grep -qF -- "-fprofile-use=${PGO_PROFDATA}" <<<"${cmd}"; then
      nopgo=$((nopgo+1)); nopgo_examples+="${src} "
    fi
  fi
done

log "Flag gate: ${#CMDS[@]} cmds, ${ccxx_total} C/C++ TUs, ${march_tus} with -march=${CPU_MARCH}, ${conflicts} conflicts, ${badopt} not -O3, ${nopgo} missing PGO profile"
[[ "${conflicts}" -eq 0 ]] || die "GATE: ${conflicts} command(s) with native/flto/openmp/instrumentation/conflicting flags: ${conflict_examples}"
[[ "${ccxx_total}" -gt 0 ]] || die "GATE: no C/C++ compile commands seen; cannot verify tuning"
[[ "${badopt}" -eq 0 ]] || die "GATE: ${badopt} C/C++ TU(s) not built at effective -O3: ${badopt_examples}"
[[ "${nopgo}" -eq 0 ]] || die "GATE: PGO=1 but ${nopgo} C/C++ TU(s) lack -fprofile-use: ${nopgo_examples}"
[[ "${march_tus}" -gt 0 ]] || die "GATE: -march=${CPU_MARCH} never applied — CPU backend not built for the ${TARGET_PROFILE} baseline"
# effective_arch_flags is the CPU contract only (identical for PGO builds); the PGO flags
# are recorded separately as pgo.use_flags.
EFFECTIVE_FLAGS="${CFLAGS_TUNE}"
if [[ "${TARGET_ARCH}" == "aarch64" ]]; then
  [[ "${untuned}" -eq 0 ]] || die "GATE: ${untuned} C/C++ TU(s) missing -mtune=${CPU_MTUNE}: ${untuned_examples}"
  ARCH_SUMMARY="$(jq -n --argjson cmds "${#CMDS[@]}" --argjson ccxx "${ccxx_total}" \
    --argjson dotprod "${march_tus}" --argjson conflicts "${conflicts}" --argjson untuned "${untuned}" \
    --argjson badopt "${badopt}" --arg march "${CPU_MARCH}" --arg mtune "${CPU_MTUNE}" \
    '{compile_commands:$cmds, ccxx_tus:$ccxx, march:$march, mtune:$mtune,
      dotprod_march_tus:$dotprod, conflicts:$conflicts, untuned:$untuned, not_o3:$badopt}')"
  log "GATE PASSED: ${ccxx_total} C/C++ TUs -O3 -mtune=${CPU_MTUNE}, ${march_tus} dotprod-tuned, no conflicts/flto/openmp"
else
  [[ "${unmarched}" -eq 0 ]] || die "GATE: ${unmarched} C/C++ TU(s) missing -march=${CPU_MARCH}: ${unmarched_examples}"
  [[ "${isa_tus}" -gt 0 ]] || die "GATE: no ggml CPU TU carries -DGGML_AVX2 — v3 kernels not compiled in"
  # Effective ISA per distinct compiler + flag set: exactly the v3 feature macros.
  for k in "${!ISA_SETS[@]}"; do
    read -r -a kv <<<"${k}"
    why="$(x86_isa_macro_check v3 "${kv[@]}")" \
      || die "GATE: effective ISA is not x86-64-v3 for '${k}' (e.g. ${ISA_SETS[${k}]}): ${why}"
    log "  effective ISA x86-64-v3: ${k}"
  done
  ARCH_SUMMARY="$(jq -n --argjson cmds "${#CMDS[@]}" --argjson ccxx "${ccxx_total}" \
    --argjson march_tus "${march_tus}" --argjson isa "${isa_tus}" --argjson conflicts "${conflicts}" \
    --argjson badopt "${badopt}" --argjson sets "${#ISA_SETS[@]}" --arg march "${CPU_MARCH}" \
    '{compile_commands:$cmds, ccxx_tus:$ccxx, march:$march, mtune:null, march_tus:$march_tus,
      ggml_isa_tus:$isa, effective_isa_flag_sets:$sets, effective_isa:"x86-64-v3",
      conflicts:$conflicts, not_o3:$badopt}')"
  log "GATE PASSED: ${ccxx_total} C/C++ TUs -O3 -march=${CPU_MARCH} (no -mtune), ${isa_tus} ggml ISA TUs, ${#ISA_SETS[@]} flag set(s) == x86-64-v3, no conflicts/flto/openmp"
fi

# --- 4. Harvest artifacts ---------------------------------------------------------
# Installed archives (exact set == STATIC_LIBS) + bindings.rs; see scripts/lib.sh.
harvest_sys_outputs "${OUT_DIR}" "${DIST}"

# Public headers of the pinned llama.cpp (what bindings.rs was generated from).
cp "${LLAMA_CPP_DIR}/include/"*.h      "${DIST}/include/"
cp "${LLAMA_CPP_DIR}/ggml/include/"*.h "${DIST}/include/"
for h in llama.h ggml.h ggml-cpu.h ggml-backend.h gguf.h; do
  [[ -f "${DIST}/include/${h}" ]] || die "expected header ${h} missing from ${DIST}/include"
done

# --- 4b. Emitted-ISA gate (x86_64) -------------------------------------------------
# What the compiler actually emitted: disassemble every harvested archive and reject any
# instruction above x86-64-v3 (EVEX/AVX-512 incl. VL forms, AVX-VNNI, AMX, ...). There is no
# runtime dispatch in this build, so a single such instruction would SIGILL on a v3 CPU.
DISASM_JSON="null"
if [[ "${TARGET_ARCH}" == "x86_64" ]]; then
  OBJDUMP="$(x86_find_objdump)" || die "GATE: objdump (binutils) is required to verify the emitted ISA"
  libs=(); for lib in ${STATIC_LIBS}; do libs+=("${DIST}/lib/${lib}"); done
  disasm_out="$(x86_disasm_scan "${OBJDUMP}" "${libs[@]}")" \
    || die "GATE: archives contain instructions above x86-64-v3:
$(grep -E '^(violation|category|instructions)' <<<"${disasm_out}" | head -n 60)"
  n_insns="$(sed -n 's/^instructions //p' <<<"${disasm_out}")"
  DISASM_JSON="$(jq -n --arg tool "$("${OBJDUMP}" --version | head -n1)" --argjson n "${n_insns}" \
    '{tool: $tool, instructions: $n, above_v3: 0,
      rejected: ["evex/avx512*", "avx-vnni*", "amx*", "avx-ifma", "bf16/avx-ne-convert",
                 "aes/vaes/pclmul/gfni/sha/sm3/sm4", "adx", "rdrand/rdseed", "fma4/xop/tbm/sse4a"]}')"
  ARCH_SUMMARY="$(jq --argjson d "${DISASM_JSON}" '. + {disassembly: $d}' <<<"${ARCH_SUMMARY}")"
  log "GATE PASSED: ${n_insns} instructions disassembled, none above x86-64-v3"
fi

# --- 5. Core build-info.json (smoke/benchmark filled in later by package.sh) ------
BINDINGS_SHA="$(sha256sum "${DIST}/bindings.rs" | awk '{print $1}')"
LIBS_JSON="$(for lib in ${STATIC_LIBS}; do
    sha="$(sha256sum "${DIST}/lib/${lib}" | awk '{print $1}')"
    printf '{"name":"%s","sha256":"%s"}\n' "${lib}" "${sha}"
  done | jq -s '.')"
LINK_LINE="$(for lib in ${STATIC_LIBS}; do printf -- '-l%s ' "${lib#lib}"; done \
             | sed 's/\.a//g'; for l in ${SYSTEM_LINK_LIBS}; do printf -- '-l%s ' "$l"; done)"

jq -n \
  --arg contract      "${ARTIFACT_CONTRACT_VERSION}" \
  --arg crate_repo    "${CRATE_REPO}" \
  --arg crate_ref     "${CRATE_REF}" \
  --arg crate_commit  "${CRATE_COMMIT}" \
  --arg crate_version "${CRATE_VERSION}" \
  --arg crate_gitlink "${CRATE_GITLINK}" \
  --arg llc_repo      "${LLAMA_CPP_REPO}" \
  --arg llc_tag       "${LLAMA_CPP_TAG}" \
  --arg llc_tag_type  "${LLAMA_CPP_TAG_TYPE}" \
  --arg llc_commit    "${LLAMA_CPP_COMMIT}" \
  --arg llc_describe  "${LLAMA_CPP_DESCRIBE}" \
  --arg llc_date      "${LLAMA_CPP_DATE}" \
  --arg llc_emb_ver   "${EMB_VERSION}" \
  --arg llc_emb_commit "${EMB_COMMIT}" \
  --arg rustv         "$(rustc --version)" \
  --arg cmakev        "$(cmake --version | head -n1)" \
  --arg image         "${COMPILER_IMAGE:-amazonlinux:2023 (unrecorded)}" \
  --arg cc            "$(${CC:-cc} --version | head -n1)" \
  --arg cxx           "$(${CXX:-c++} --version | head -n1)" \
  --arg pkgs          "$(command -v rpm >/dev/null && rpm -q glibc libstdc++ gcc clang18 llvm18-libs compiler-rt18 2>/dev/null | tr '\n' ';' || echo 'rpm-unavailable')" \
  --arg triple        "${TARGET_TRIPLE}" \
  --arg profile       "${TARGET_PROFILE}" \
  --arg arch_name     "${TARGET_ARCH}" \
  --arg baseline      "${CPU_BASELINE}" \
  --arg host_arch     "$(uname -m)" \
  --arg host_cpu      "${HOST_CPU_MODEL:-}" \
  --argjson host_caps "${HOST_CPU_JSON:-null}" \
  --arg cpu           "${CPU_PROFILE}" \
  --arg flags         "${EFFECTIVE_FLAGS}" \
  --arg features      "${CRATE_FEATURES}" \
  --arg link_line     "$(echo "${LINK_LINE}" | xargs)" \
  --arg bindings_sha  "${BINDINGS_SHA}" \
  --arg builder_sha   "$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)" \
  --arg built_at      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg glibc         "$(ldd --version | head -n1)" \
  --arg lscpu         "$(lscpu 2>/dev/null | tr '\n' ';' || echo unknown)" \
  --arg runner_kind   "${RUNNER_KIND:-local}" \
  --arg runner_label  "${RUNNER_LABEL:-}" \
  --arg runner_uarch  "${RUNNER_UARCH:-}" \
  --arg pgo_enabled   "${PGO}" \
  --arg pgo_model     "$( [[ -n "${PGO_PROFDATA}" ]] && basename "${PGO_TRAIN_MODEL}" || echo "" )" \
  --arg pgo_iters     "$( [[ "${PGO}" == "1" ]] && echo "${PGO_TRAIN_ITERS}" || echo "" )" \
  --arg pgo_flags     "${PGO_USE_FLAGS}" \
  --arg pgo_sha       "$( [[ -f "${PGO_PROFDATA:-/nonexistent}" ]] && sha256sum "${PGO_PROFDATA}" | awk '{print $1}' || echo "" )" \
  --argjson arch      "${ARCH_SUMMARY}" \
  --argjson libs      "${LIBS_JSON}" \
  '{
     artifact_contract_version: $contract,
     # Where build.rs + bindgen config came from. git_ref is the REQUESTED ref (a tag);
     # commit is what it resolved to and was verified against. The llama.cpp gitlink the
     # crate vendors is recorded but was NOT compiled (replaced by the llama_cpp block below).
     llama_cpp_rs: { repository: $crate_repo, git_ref: $crate_ref, git_ref_type: "tag",
                     commit: $crate_commit, vendored_llama_cpp_commit: $crate_gitlink,
                     vendored_llama_cpp_overridden: ($crate_gitlink != $llc_commit) },
     llama_cpp_sys_2: { version: $crate_version, default_features: false,
                        features: ($features | split(",") | map(select(. != ""))) },
     # The engine actually compiled: verified HEAD == commit, annotated tag peels to it,
     # `git describe --tags --exact-match` == tag, and the compiled llama-version.h agrees.
     llama_cpp: { repository: $llc_repo, tag: $llc_tag, tag_type: $llc_tag_type,
                  commit: $llc_commit, describe: $llc_describe, date: $llc_date,
                  embedded_version: $llc_emb_ver, embedded_commit: $llc_emb_commit },
     rust: $rustv, cmake: $cmakev,
     # Build environment is RESOLVED-and-RECORDED provenance (not a controlled runtime
     # pin): consumers pin the artifact checksum, and CI gates the environment envelope.
     build_env: { image: $image, cc: $cc, cxx: $cxx, packages: $pkgs, glibc: $glibc,
                  host_arch: $host_arch, native_build: true },
     # Target profile (config.env). host.architecture == architecture is asserted before the
     # build (no cross compilation / emulation); for x86_64 host.cpu_capability is the
     # x86-64-v3 gate result (scripts/check-x86-64-v3.sh) of the build host.
     target_profile: $profile, architecture: $arch_name, target_triple: $triple,
     cpu_baseline: $baseline, cpu_profile: $cpu, effective_arch_flags: $flags,
     host: { architecture: $host_arch, native_build: true, cpu_model: $host_cpu,
             cpu_capability: $host_caps },
     arch_flag_summary: $arch,
     # PGO changes codegen only (no ABI/link/shape change); the profile is a recorded build
     # input. enabled=false means a plain single-phase build (the default).
     pgo: { enabled: ($pgo_enabled == "1"),
            mode: (if $pgo_enabled == "1" then "ir-pgo (-fprofile-generate/-fprofile-use)" else null end),
            # A profile is trained on, and only ever used for, this arch + baseline.
            architecture: (if $pgo_enabled == "1" then $arch_name else null end),
            cpu_baseline: (if $pgo_enabled == "1" then $baseline else null end),
            training_model: (if $pgo_model == "" then null else $pgo_model end),
            train_iters: (if $pgo_iters == "" then null else ($pgo_iters | tonumber) end),
            profdata_sha256: (if $pgo_sha == "" then null else $pgo_sha end),
            use_flags: (if $pgo_flags == "" then null else $pgo_flags end) },
     features: ($features | split(",") | map(select(. != ""))),
     # Where the build ran (CI passes RUNNER_KIND/RUNNER_LABEL/RUNNER_UARCH; default local).
     runner: { kind: $runner_kind,
               label: (if $runner_label == "" then null else $runner_label end),
               uarch: (if $runner_uarch == "" then null else $runner_uarch end),
               cpu_model: $host_cpu, lscpu: $lscpu },
     libs: $libs, link_line: $link_line, bindings_sha256: $bindings_sha,
     builder_git_sha: $builder_sha, built_at: $built_at,
     smoke: null, benchmark: null, correctness: null
   }' > "${DIST}/build-info.json"

log "Wrote ${DIST}/build-info.json"
log "Build complete. Artifacts in ${DIST}/"
