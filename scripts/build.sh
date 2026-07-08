#!/usr/bin/env bash
#
# Build Graviton2 (Neoverse N1) tuned static llama.cpp archives THROUGH the pinned
# llama-cpp-sys-2 crate, so the harvested .a + bindings.rs are byte-for-byte what a
# from-source crate build would produce (this is what bench parity compares against).
#
# Output: $DIST/{lib,include,bindings.rs,build-info.json}
#
# Usage: scripts/build.sh   (run inside the pinned AL2023 aarch64 container)
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

# --- 2. Build the -sys crate with N1 tuning injected via CFLAGS -------------------
# On Linux aarch64 the crate adds NO -march of its own (only Android does), so our
# -mcpu is the sole architecture flag => no -march/-mcpu conflict. We deliberately do
# NOT set target-cpu (that would make the crate emit an invalid `-march=neoverse-n1`).
export CFLAGS="${CFLAGS_TUNE} ${CFLAGS:-}"
export CXXFLAGS="${CFLAGS_TUNE} ${CXXFLAGS:-}"
export CMAKE_EXPORT_COMPILE_COMMANDS=ON        # for the flag-verification gate
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"

# No --target: host == target (native aarch64), so plain CFLAGS is reliably honored by
# cc/cmake-rs. The triple is still recorded in build-info.json for provenance.
log "Building llama-cpp-sys-2 (features: ${CRATE_FEATURES})"
log "  CFLAGS=${CFLAGS}"
( cd "${SRC}" && cargo build --release -p llama-cpp-sys-2 --features "${CRATE_FEATURES}" )

OUT_DIR="$(find "${SRC}/target" -type d -name out -path '*release/build*llama-cpp-sys-2*' \
             | head -n1)"
[[ -n "${OUT_DIR}" ]] || die "Could not locate llama-cpp-sys-2 OUT_DIR"
log "OUT_DIR=${OUT_DIR}"

# --- 3. Flag-verification gate ----------------------------------------------------
CC_JSON="$(find "${OUT_DIR}" -name compile_commands.json | head -n1)"
[[ -n "${CC_JSON}" ]] || die "compile_commands.json not found; cannot verify flags"

EFFECTIVE_FLAGS="$(jq -r '.[].command' "${CC_JSON}" \
  | grep -Eo -- '-mcpu=[^ ]+|-march=[^ ]+|-mtune=[^ ]+' | sort -u | tr '\n' ' ')"
log "Effective arch flags observed: ${EFFECTIVE_FLAGS:-<none>}"

grep -q -- "-mcpu=${CPU_MCPU}" <<<"${EFFECTIVE_FLAGS}" \
  || die "GATE: expected -mcpu=${CPU_MCPU} not found on compile commands"
if grep -q -- '-mcpu=native\|-march=native' <<<"${EFFECTIVE_FLAGS}"; then
  die "GATE: native codegen detected — would emit N1-illegal instructions on Graviton2"
fi
if grep -qE -- '-march=armv8[^ ]*' <<<"${EFFECTIVE_FLAGS}"; then
  die "GATE: a conflicting -march was injected alongside -mcpu; resolve before shipping"
fi
log "GATE PASSED: tuned exclusively for ${CPU_MCPU}"

# --- 4. Harvest artifacts ---------------------------------------------------------
for lib in ${STATIC_LIBS}; do
  found="$(find "${OUT_DIR}" -name "${lib}" | head -n1)"
  [[ -n "${found}" ]] || die "Expected static lib ${lib} not found under OUT_DIR"
  cp -v "${found}" "${DIST}/lib/${lib}"
done

BINDINGS="$(find "${OUT_DIR}" -name bindings.rs | head -n1)"
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
  --arg image         "${COMPILER_IMAGE:-amazonlinux:2023}" \
  --arg cc            "$(${CC:-cc} --version | head -n1)" \
  --arg triple        "${TARGET_TRIPLE}" \
  --arg cpu           "${CPU_MCPU}" \
  --arg flags         "${EFFECTIVE_FLAGS}" \
  --arg features      "${CRATE_FEATURES}" \
  --arg link_line     "$(echo "${LINK_LINE}" | xargs)" \
  --arg bindings_sha  "${BINDINGS_SHA}" \
  --arg builder_sha   "$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)" \
  --arg built_at      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg glibc         "$(ldd --version | head -n1)" \
  --arg lscpu         "$(lscpu 2>/dev/null | tr '\n' ';' || echo unknown)" \
  --argjson libs      "${LIBS_JSON}" \
  '{
     artifact_contract_version: $contract,
     llama_cpp_sys_2: { version: $crate_tag, git_tag: $crate_tag },
     llama_cpp: { submodule_commit: $llc_commit, describe: $llc_describe, date: $llc_date },
     rust: $rustv, cmake: $cmakev,
     compiler: { image: $image, cc: $cc },
     target_triple: $triple, cpu_profile: $cpu, effective_arch_flags: $flags,
     features: ($features | split(",")),
     runner: { kind: "github-hosted", label: "ubuntu-24.04-arm", uarch: "neoverse-n2",
               glibc: $glibc, lscpu: $lscpu },
     libs: $libs, link_line: $link_line, bindings_sha256: $bindings_sha,
     builder_git_sha: $builder_sha, built_at: $built_at,
     smoke: null, benchmark: null
   }' > "${DIST}/build-info.json"

log "Wrote ${DIST}/build-info.json"
log "Build complete. Artifacts in ${DIST}/"
