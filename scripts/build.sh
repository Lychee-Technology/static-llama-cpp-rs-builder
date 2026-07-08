#!/usr/bin/env bash
#
# Build Graviton2 (Neoverse N1) tuned static llama.cpp archives THROUGH the pinned
# llama-cpp-sys-2 crate, so the harvested .a + bindings.rs are byte-for-byte what a
# from-source crate build would produce (this is what bench parity compares against).
#
# Output: $DIST/{lib,include,bindings.rs,build-info.json}
#
# Usage: scripts/build.sh   (run inside the AL2023 aarch64 build container)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"

WORK="${WORK:-${ROOT}/.build}"
DIST="${DIST:-${ROOT}/dist}"
SRC="${WORK}/llama-cpp-rs"

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build:ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

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

# --- 1. Fetch the pinned crate (with the vendored llama.cpp submodule) ------------
if [[ ! -d "${SRC}/.git" ]]; then
  log "Cloning ${CRATE_REPO} @ ${CRATE_TAG} (recursive)"
  git clone --depth 1 --branch "${CRATE_TAG}" --recursive "${CRATE_REPO}" "${SRC}"
fi

LLAMA_CPP_DIR="${SRC}/llama-cpp-sys-2/llama.cpp"
LLAMA_CPP_COMMIT="$(git -C "${LLAMA_CPP_DIR}" rev-parse HEAD)"
LLAMA_CPP_DESCRIBE="$(git -C "${LLAMA_CPP_DIR}" describe --tags --always 2>/dev/null || echo unknown)"
LLAMA_CPP_DATE="$(git -C "${LLAMA_CPP_DIR}" show -s --format=%cI HEAD)"

log "llama.cpp submodule: ${LLAMA_CPP_COMMIT} (${LLAMA_CPP_DESCRIBE}, ${LLAMA_CPP_DATE})"
if [[ "${LLAMA_CPP_COMMIT}" != "${EXPECTED_LLAMA_CPP_COMMIT}" ]]; then
  die "Submodule commit ${LLAMA_CPP_COMMIT} != expected ${EXPECTED_LLAMA_CPP_COMMIT}.
       Upstream drift: verify and update EXPECTED_LLAMA_CPP_COMMIT + bump the contract."
fi

# Point ggml's CPU backend at N1's ISA (dotprod) instead of its default -march=armv8-a.
patch_ggml_arm_arch "${SRC}/llama-cpp-sys-2/build.rs" \
  || die "Failed to inject GGML_CPU_ARM_ARCH into build.rs (upstream layout changed?)"
log "Patched build.rs: GGML_CPU_ARM_ARCH=${CPU_MARCH}"

# --- 2. Build the -sys crate with N1 tuning ---------------------------------------
# CFLAGS/CXXFLAGS apply -O3 -march=${CPU_MARCH} -mtune to ALL TUs. ggml also adds
# -march=${CPU_MARCH} to its CPU kernels (via the GGML_CPU_ARM_ARCH patch above) — the
# SAME value, so there is no conflict. No -mcpu, no -flto (see config.env).
export CFLAGS="${CFLAGS_TUNE} ${CFLAGS:-}"
export CXXFLAGS="${CFLAGS_TUNE} ${CXXFLAGS:-}"
export CMAKE_EXPORT_COMPILE_COMMANDS=ON        # for the flag-verification gate
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"

# No --target: host == target (native aarch64), so plain CFLAGS is reliably honored by
# cc/cmake-rs. The triple is still recorded in build-info.json for provenance.
log "Building llama-cpp-sys-2 (features: '${CRATE_FEATURES}')"
log "  CFLAGS=${CFLAGS}"
# Omit --features entirely when empty (cargo treats `--features ""` inconsistently).
( cd "${SRC}" && cargo build --release -p llama-cpp-sys-2 ${CRATE_FEATURES:+--features "${CRATE_FEATURES}"} )

# `-print -quit` (not `| head -n1`) to avoid SIGPIPE-failing find under `set -o pipefail`.
OUT_DIR="$(find "${SRC}/target" -type d -name out -path '*release/build*llama-cpp-sys-2*' -print -quit)"
[[ -n "${OUT_DIR}" ]] || die "Could not locate llama-cpp-sys-2 OUT_DIR"
log "OUT_DIR=${OUT_DIR}"

# --- 3. Flag-verification gate (PER compile command) ------------------------------
# The contract claims the archives are Neoverse-N1 tuned, so we prove it per translation
# unit. For EVERY compile command:
#   * no command may use `native` (fatal — N1-illegal insns on Graviton2),
#   * no command may use -mcpu, or any -march other than ${CPU_MARCH} (e.g. a stray
#     armv8-a would strip dotprod) — fatal,
#   * every C/C++ TU (.c/.cc/.cpp/.cxx) must carry -mtune=${CPU_MTUNE},
#   * the dotprod -march=${CPU_MARCH} must appear on the CPU-backend TUs (>=1).
CC_JSON="$(find "${OUT_DIR}" -name compile_commands.json -print -quit)"
[[ -n "${CC_JSON}" ]] || die "compile_commands.json not found; cannot verify flags"

# CMake emits either .command (string) or .arguments (array) depending on generator.
# (while-read, not mapfile, to stay portable to bash 3.2.)
CMDS=()
while IFS= read -r line; do CMDS+=("${line}"); done \
  < <(jq -r '.[] | (.command // (.arguments | join(" ")))' "${CC_JSON}")
[[ "${#CMDS[@]}" -gt 0 ]] || die "compile_commands.json had no entries"

ccxx_total=0; dotprod=0; conflicts=0; untuned=0; badopt=0
conflict_examples=""; untuned_examples=""; badopt_examples=""
for cmd in "${CMDS[@]}"; do
  # native anywhere is fatal.
  if grep -qE -- '-mcpu=native|-march=native' <<<"${cmd}"; then
    conflicts=$((conflicts+1)); conflict_examples+="[native] "; continue
  fi
  # LTO anywhere is fatal: clang -flto emits LLVM bitcode objects, unlinkable as a
  # native prebuilt .a by the consumer's GNU ld / rustc cc driver.
  if grep -qE -- '-flto' <<<"${cmd}"; then
    conflicts=$((conflicts+1)); conflict_examples+="[flto] "; continue
  fi
  # -mcpu should never appear; any -march other than our exact CPU_MARCH is a conflict.
  bad_mcpu="$(grep -oE -- '-mcpu=[^ ]+' <<<"${cmd}" || true)"
  bad_march="$(grep -oE -- '-march=[^ ]+' <<<"${cmd}" | grep -v -- "-march=${CPU_MARCH}" || true)"
  if [[ -n "${bad_mcpu}" || -n "${bad_march}" ]]; then
    conflicts=$((conflicts+1)); conflict_examples+="${bad_mcpu}${bad_march} "
  fi
  grep -q -- "-march=${CPU_MARCH}" <<<"${cmd}" && dotprod=$((dotprod+1)) || true
  # Per C/C++ TU: require -mtune (N1 scheduling) AND effective -O3 (last -O flag == -O3).
  if grep -qiE -- '-c( |$)' <<<"${cmd}" && grep -qiE -- '\.(c|cc|cpp|cxx|c\+\+)( |$|")' <<<"${cmd}"; then
    ccxx_total=$((ccxx_total+1))
    src="$(grep -oE -- '[^ ]+\.(c|cc|cpp|cxx|c\+\+)' <<<"${cmd}" | head -n1 || true)"
    if ! grep -q -- "-mtune=${CPU_MTUNE}" <<<"${cmd}"; then
      untuned=$((untuned+1)); untuned_examples+="${src} "
    fi
    # Effective optimization = the LAST -O flag on the command line.
    last_opt="$(grep -oE -- '-O[0-9sgz]' <<<"${cmd}" | tail -n1 || true)"
    if [[ "${last_opt}" != "-O3" ]]; then
      badopt=$((badopt+1)); badopt_examples+="${src}(${last_opt:-none}) "
    fi
  fi
done

log "Flag gate: ${#CMDS[@]} cmds, ${ccxx_total} C/C++ TUs, ${dotprod} with -march=${CPU_MARCH}, ${conflicts} conflicts, ${untuned} untuned, ${badopt} not -O3"
[[ "${conflicts}" -eq 0 ]] || die "GATE: ${conflicts} command(s) with native/flto/conflicting flags: ${conflict_examples}"
[[ "${ccxx_total}" -gt 0 ]] || die "GATE: no C/C++ compile commands seen; cannot verify tuning"
[[ "${untuned}" -eq 0 ]] || die "GATE: ${untuned} C/C++ TU(s) missing -mtune=${CPU_MTUNE}: ${untuned_examples}"
[[ "${badopt}" -eq 0 ]] || die "GATE: ${badopt} C/C++ TU(s) not built at effective -O3: ${badopt_examples}"
[[ "${dotprod}" -gt 0 ]] || die "GATE: -march=${CPU_MARCH} never applied — CPU backend not dotprod-tuned"
EFFECTIVE_FLAGS="-O3 -march=${CPU_MARCH} -mtune=${CPU_MTUNE}"
ARCH_SUMMARY="$(jq -n --argjson cmds "${#CMDS[@]}" --argjson ccxx "${ccxx_total}" \
  --argjson dotprod "${dotprod}" --argjson conflicts "${conflicts}" --argjson untuned "${untuned}" \
  --argjson badopt "${badopt}" --arg march "${CPU_MARCH}" --arg mtune "${CPU_MTUNE}" \
  '{compile_commands:$cmds, ccxx_tus:$ccxx, march:$march, mtune:$mtune,
    dotprod_march_tus:$dotprod, conflicts:$conflicts, untuned:$untuned, not_o3:$badopt}')"
log "GATE PASSED: ${ccxx_total} C/C++ TUs -O3 -mtune=${CPU_MTUNE}, ${dotprod} dotprod-tuned, no conflicts/flto"

# --- 4. Harvest artifacts ---------------------------------------------------------
for lib in ${STATIC_LIBS}; do
  found="$(find "${OUT_DIR}" -name "${lib}" -print -quit)"
  [[ -n "${found}" ]] || die "Expected static lib ${lib} not found under OUT_DIR"
  cp -v "${found}" "${DIST}/lib/${lib}"
done

BINDINGS="$(find "${OUT_DIR}" -name bindings.rs -print -quit)"
[[ -n "${BINDINGS}" ]] || die "generated bindings.rs not found"
cp -v "${BINDINGS}" "${DIST}/bindings.rs"

cp -v "${LLAMA_CPP_DIR}/include/"*.h            "${DIST}/include/" 2>/dev/null || true
cp -v "${LLAMA_CPP_DIR}/ggml/include/"*.h       "${DIST}/include/" 2>/dev/null || true

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
  --arg crate_tag     "${CRATE_TAG}" \
  --arg llc_commit    "${LLAMA_CPP_COMMIT}" \
  --arg llc_describe  "${LLAMA_CPP_DESCRIBE}" \
  --arg llc_date      "${LLAMA_CPP_DATE}" \
  --arg rustv         "$(rustc --version)" \
  --arg cmakev        "$(cmake --version | head -n1)" \
  --arg image         "${COMPILER_IMAGE:-amazonlinux:2023 (unrecorded)}" \
  --arg cc            "$(${CC:-cc} --version | head -n1)" \
  --arg cxx           "$(${CXX:-c++} --version | head -n1)" \
  --arg pkgs          "$(command -v rpm >/dev/null && rpm -q glibc libstdc++ gcc clang18 llvm18-libs 2>/dev/null | tr '\n' ';' || echo 'rpm-unavailable')" \
  --arg triple        "${TARGET_TRIPLE}" \
  --arg cpu           "${CPU_MTUNE}" \
  --arg flags         "${EFFECTIVE_FLAGS}" \
  --arg features      "${CRATE_FEATURES}" \
  --arg link_line     "$(echo "${LINK_LINE}" | xargs)" \
  --arg bindings_sha  "${BINDINGS_SHA}" \
  --arg builder_sha   "$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)" \
  --arg built_at      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg glibc         "$(ldd --version | head -n1)" \
  --arg lscpu         "$(lscpu 2>/dev/null | tr '\n' ';' || echo unknown)" \
  --argjson arch      "${ARCH_SUMMARY}" \
  --argjson libs      "${LIBS_JSON}" \
  '{
     artifact_contract_version: $contract,
     llama_cpp_sys_2: { version: $crate_tag, git_tag: $crate_tag },
     llama_cpp: { submodule_commit: $llc_commit, describe: $llc_describe, date: $llc_date },
     rust: $rustv, cmake: $cmakev,
     # Build environment is RESOLVED-and-RECORDED provenance (not a controlled runtime
     # pin): consumers pin the artifact checksum, and CI gates the environment envelope.
     build_env: { image: $image, cc: $cc, cxx: $cxx, packages: $pkgs, glibc: $glibc },
     target_triple: $triple, cpu_profile: $cpu, effective_arch_flags: $flags,
     arch_flag_summary: $arch,
     features: ($features | split(",")),
     runner: { kind: "github-hosted", label: "ubuntu-24.04-arm", uarch: "neoverse-n2",
               lscpu: $lscpu },
     libs: $libs, link_line: $link_line, bindings_sha256: $bindings_sha,
     builder_git_sha: $builder_sha, built_at: $built_at,
     smoke: null, benchmark: null
   }' > "${DIST}/build-info.json"

log "Wrote ${DIST}/build-info.json"
log "Build complete. Artifacts in ${DIST}/"
