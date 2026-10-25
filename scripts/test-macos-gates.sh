#!/usr/bin/env bash
# Regression tests for the macOS (aarch64-apple-darwin) build gates in scripts/lib.sh:
# apple_m1_isa_check, macos_objects_check, archive_order_check and macos_link_check. Each
# gate must accept a conforming input and reject one broken property with its diagnostic,
# on small synthetic sources compiled here (no llama.cpp build is involved). The gates read
# Mach-O objects and link with ld64, so this runs only on an Apple Silicon Mac with Apple
# clang; scripts/test-source-pins.sh covers the platform-independent checks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"
source "${ROOT}/scripts/lib.sh"
[[ "${TARGET_PROFILE}" == aarch64-apple-darwin ]] \
  || { echo "test-macos-gates.sh: needs an Apple Silicon Mac (host profile: '${TARGET_PROFILE:-none}')" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
MIN="${MACOS_DEPLOYMENT_TARGET}"
SDK="$(xcrun --show-sdk-version)"

# expect_failure LABEL DIAGNOSTIC CMD...: CMD must exit non-zero AND print DIAGNOSTIC (a
# fixed string), so a case cannot pass because something unrelated failed first.
expect_failure() {
  local label="$1" diagnostic="$2"; shift 2
  if ( "$@" ) >"${TMP}/failure.log" 2>&1; then
    echo "FAIL: ${label} unexpectedly passed" >&2
    cat "${TMP}/failure.log" >&2
    exit 1
  fi
  if ! grep -qF -- "${diagnostic}" "${TMP}/failure.log"; then
    echo "FAIL: ${label} failed without the expected diagnostic '${diagnostic}':" >&2
    cat "${TMP}/failure.log" >&2
    exit 1
  fi
  echo "PASS: rejects ${label}"
}
expect_success() {
  local label="$1"; shift
  ( "$@" ) >"${TMP}/success.log" 2>&1 \
    || { echo "FAIL: ${label} was rejected:" >&2; cat "${TMP}/success.log" >&2; exit 1; }
  echo "PASS: accepts ${label}"
}

# --- apple_m1_isa_check: frontend macros and backend -cc1 features ---------------------
M1_FLAGS=(--target=arm64-apple-macosx -mmacosx-version-min="${MIN}" -mcpu=apple-m1 -arch arm64)
for cc in "${CC}" "${CXX}"; do
  expect_success "apple-m1 flags (${cc})" apple_m1_isa_check "${cc}" "${M1_FLAGS[@]}"
done
expect_failure 'a newer CPU (-mcpu=apple-m2)' 'above-apple-m1 features: __ARM_ARCH_8_6__' \
  apple_m1_isa_check "${CC}" -mcpu=apple-m2 -arch arm64
expect_failure 'a lower -march in place of -mcpu' 'missing apple-m1 features: __ARM_FEATURE_FP16_VECTOR_ARITHMETIC' \
  apple_m1_isa_check "${CC}" -march=armv8.2-a+dotprod -arch arm64
expect_failure 'an above-M1 feature added to -mcpu=apple-m1' '__ARM_FEATURE_MATMUL_INT8' \
  apple_m1_isa_check "${CC}" "${M1_FLAGS[@]}" -Xclang -target-feature -Xclang +i8mm
expect_failure 'an apple-m1 feature removed in the backend' 'missing apple-m1 features: +dotprod' \
  apple_m1_isa_check "${CC}" --target=arm64-apple-macosx -mcpu=apple-m1+nodotprod -arch arm64

# --- macos_objects_check: thin arm64, macOS, minos, SDK, availability ------------------
mkdir -p "${TMP}/obj"
printf 'int answer(void) { return 42; }\n' >"${TMP}/obj/answer.c"
# A macOS 14.4 API called with no availability guard, compiled with -w as cc-rs compiles
# the archives (which hides -Wunguarded-availability): the reference becomes weak.
printf '#include <os/os_sync_wait_on_address.h>\n#include <stdint.h>\nint wake(uint64_t *p) { return os_sync_wake_by_address_any(p, sizeof *p, OS_SYNC_WAKE_BY_ADDRESS_NONE); }\n' \
  >"${TMP}/obj/wake.c"
# archive NAME CFLAGS... : compile answer.c (and wake.c for NAME=weak) into lib${NAME}.a.
archive() {
  local name="$1" src="${TMP}/obj/answer.c"; shift
  [[ "${name}" == weak ]] && src="${TMP}/obj/wake.c"
  "${CC}" -w -c "$@" "${src}" -o "${TMP}/obj/${name}.o"
  rm -f "${TMP}/obj/lib${name}.a"
  ar -rcs "${TMP}/obj/lib${name}.a" "${TMP}/obj/${name}.o" 2>/dev/null   # (ranlib warns on the fat one)
}
archive ok      -arch arm64 -mmacosx-version-min="${MIN}" -mcpu=apple-m1
archive newer   -arch arm64 -mmacosx-version-min=13.0
archive x86     -arch x86_64 -mmacosx-version-min="${MIN}"
archive fat     -arch arm64 -arch x86_64 -mmacosx-version-min="${MIN}"
archive ios     -target arm64-apple-ios14.0
archive weak    -arch arm64 -mmacosx-version-min="${MIN}"
expect_success "an arm64 macOS ${MIN} archive" macos_objects_check "${MIN}" "${SDK}" "${TMP}/obj/libok.a"
expect_failure 'objects for a newer minimum macOS' 'minos=13.0' \
  macos_objects_check "${MIN}" "${SDK}" "${TMP}/obj/libok.a" "${TMP}/obj/libnewer.a"
expect_failure 'x86_64 objects' "architectures 'x86_64', expected thin arm64" \
  macos_objects_check "${MIN}" "${SDK}" "${TMP}/obj/libx86.a"
expect_failure 'universal (fat) archives' 'expected thin arm64' \
  macos_objects_check "${MIN}" "${SDK}" "${TMP}/obj/libfat.a"
expect_failure 'objects for another Apple platform (iOS)' 'platform=2' \
  macos_objects_check "${MIN}" "${SDK}" "${TMP}/obj/libios.a"
expect_failure 'objects built against another SDK than the recorded one' "sdk=${SDK}" \
  macos_objects_check "${MIN}" "0.1" "${TMP}/obj/libok.a"
expect_failure 'an API newer than the deployment target used without a guard' \
  'weak undefined symbols (an API newer than macOS' \
  macos_objects_check "${MIN}" "${SDK}" "${TMP}/obj/libweak.a"

# --- archive_order_check: single left-to-right pass ------------------------------------
mkdir -p "${TMP}/order"
printf 'int b(void);\nint a(void) { return b() + 1; }\n' >"${TMP}/order/a.c"
printf 'int b(void) { return 1; }\n' >"${TMP}/order/b.c"
for x in a b; do
  "${CC}" -c -arch arm64 -mmacosx-version-min="${MIN}" "${TMP}/order/${x}.c" -o "${TMP}/order/${x}.o"
  ar -rcs "${TMP}/order/lib${x}.a" "${TMP}/order/${x}.o"
done
expect_success 'a dependency order' archive_order_check "${TMP}/order/liba.a" "${TMP}/order/libb.a"
expect_failure 'a reversed dependency order' 'archive #2 needs 1 symbol(s) only an earlier archive defines (e.g. _b' \
  archive_order_check "${TMP}/order/libb.a" "${TMP}/order/liba.a"

# --- macos_link_check: -all_load link, minimal system libs, dylibs, backend ------------
# Stand-ins for the llama/ggml entry points the probe calls; llama is C++ (libc++), like
# the real libllama.a.
DIST="${TMP}/dist"
mkdir -p "${DIST}/include" "${TMP}/link"
cat >"${DIST}/include/ggml-backend.h" <<'EOF'
#include <stddef.h>
typedef struct ggml_backend_reg * ggml_backend_reg_t;
size_t ggml_backend_reg_count(void);
ggml_backend_reg_t ggml_backend_reg_get(size_t i);
const char * ggml_backend_reg_name(ggml_backend_reg_t reg);
EOF
cat >"${DIST}/include/llama.h" <<'EOF'
void llama_backend_init(void);
void llama_backend_free(void);
const char * llama_print_system_info(void);
EOF
cat >"${TMP}/link/llama.cpp" <<'EOF'
#include <string>
static std::string info;
extern "C" void llama_backend_init(void) { info = std::string("CPU : NEON = 1 | "); }
extern "C" void llama_backend_free(void) { info.clear(); }
extern "C" const char * llama_print_system_info(void) { return info.c_str(); }
EOF
cat >"${TMP}/link/llama-c.c" <<'EOF'
void llama_backend_init(void) {}
void llama_backend_free(void) {}
const char * llama_print_system_info(void) { return "CPU : NEON = 1 | "; }
EOF
# ggml.c NREGS: the registered backends ("CPU", then "Metal").
ggml_src() {
  printf '#include <stddef.h>\nstatic const char *names[] = {"CPU", "Metal"};\n'
  printf 'size_t ggml_backend_reg_count(void) { return %s; }\n' "$1"
  printf 'void *ggml_backend_reg_get(size_t i) { return (void *) names[i]; }\n'
  printf 'const char *ggml_backend_reg_name(void *r) { return (const char *) r; }\n'
}
ggml_src 1 >"${TMP}/link/ggml.c"
ggml_src 2 >"${TMP}/link/ggml-metal.c"
printf '#include <CoreFoundation/CoreFoundation.h>\nvoid release(CFTypeRef r) { CFRelease(r); }\n' >"${TMP}/link/framework.c"
# stub NAME SRC [MINOS]: compile SRC into lib${NAME}.a.
stub() {
  "${CXX}" -w -c -arch arm64 -mmacosx-version-min="${3:-${MIN}}" -mcpu=apple-m1 \
    "$( [[ "$2" == *.c ]] && echo '-xc' || echo '-xc++' )" "${TMP}/link/$2" -o "${TMP}/link/$1.o"
  ar -rcs "${TMP}/link/lib$1.a" "${TMP}/link/$1.o"
}
stub llama llama.cpp; stub llama-c llama-c.c; stub llama-newer llama.cpp 13.0
stub ggml ggml.c; stub ggml-metal ggml-metal.c; stub framework framework.c
L="${TMP}/link"
expect_success "a C++ archive set with SYSTEM_LINK_LIBS='${SYSTEM_LINK_LIBS}'" \
  macos_link_check "${TMP}/probe" "${MIN}" "${L}/libllama.a" "${L}/libggml.a"
expect_failure 'a missing archive (unresolved symbols)' '_ggml_backend_reg_count' \
  macos_link_check "${TMP}/probe" "${MIN}" "${L}/libllama.a"
expect_failure 'a member that needs a framework' '_CFRelease' \
  macos_link_check "${TMP}/probe" "${MIN}" "${L}/libllama.a" "${L}/libggml.a" "${L}/libframework.a"
expect_failure 'a system library the archives do not need' \
  'the archives also link without -lc++: SYSTEM_LINK_LIBS is not minimal' \
  macos_link_check "${TMP}/probe" "${MIN}" "${L}/libllama-c.a" "${L}/libggml.a"
expect_failure 'objects for a newer macOS than the consumer (linker warning is fatal)' "was built for newer 'macOS' version (13.0)" \
  macos_link_check "${TMP}/probe" "${MIN}" "${L}/libllama-newer.a" "${L}/libggml.a"
expect_failure 'a second (non-CPU) ggml backend' 'expected the CPU backend as the only ggml backend, got: CPU Metal' \
  macos_link_check "${TMP}/probe" "${MIN}" "${L}/libllama.a" "${L}/libggml-metal.a"
echo 'All macOS build-gate regression tests passed'
