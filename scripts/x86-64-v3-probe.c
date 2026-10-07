/*
 * x86-64-v3 capability probe (used by scripts/check-x86-64-v3.sh).
 *
 * Reads the CPU's own CPUID leaves plus XGETBV (XCR0) and prints one `name=0|1` line per
 * feature the x86-64-v3 psABI level requires (v2: CX16 LAHF-SAHF POPCNT SSE3 SSE4.1
 * SSE4.2 SSSE3; v3: AVX AVX2 BMI1 BMI2 F16C FMA LZCNT MOVBE OSXSAVE), plus `os_avx_state`:
 * the OS has enabled the SSE+AVX register state (XCR0 bits 1 and 2) — without it AVX
 * instructions fault even when CPUID advertises them.
 *
 * MUST be compiled for the default x86-64 baseline (no -march): it has to run on any x86-64
 * CPU, including one that is NOT v3, and report the missing features instead of dying with
 * SIGILL. It only reports; the checker script decides pass/fail.
 */
#include <cpuid.h>
#include <stdint.h>
#include <stdio.h>

static uint64_t xgetbv0(void) {
    uint32_t eax, edx;
    /* xgetbv with ECX=0 (XCR0), as raw bytes so no -mxsave is needed. Only executed when
     * CPUID.1:ECX.OSXSAVE=1 (otherwise the instruction raises #UD). */
    __asm__ volatile(".byte 0x0f, 0x01, 0xd0" : "=a"(eax), "=d"(edx) : "c"(0));
    return ((uint64_t)edx << 32) | eax;
}

#define BIT(r, n) ((int)(((r) >> (n)) & 1u))

int main(void) {
    unsigned a, b, c, d;
    unsigned l1c = 0, l7b = 0, e1c = 0;
    unsigned max_leaf = __get_cpuid_max(0, 0);
    unsigned max_ext = __get_cpuid_max(0x80000000u, 0);
    uint64_t xcr0 = 0;
    int osxsave;

    if (max_leaf >= 1) { __cpuid(1, a, b, c, d); l1c = c; }
    if (max_leaf >= 7) { __cpuid_count(7, 0, a, b, c, d); l7b = b; }
    if (max_ext >= 0x80000001u) { __cpuid(0x80000001u, a, b, c, d); e1c = c; }
    osxsave = BIT(l1c, 27);
    if (osxsave) xcr0 = xgetbv0();

    /* x86-64-v2 */
    printf("cx16=%d\n", BIT(l1c, 13));
    printf("lahf_lm=%d\n", BIT(e1c, 0));
    printf("popcnt=%d\n", BIT(l1c, 23));
    printf("sse3=%d\n", BIT(l1c, 0));
    printf("sse4_1=%d\n", BIT(l1c, 19));
    printf("sse4_2=%d\n", BIT(l1c, 20));
    printf("ssse3=%d\n", BIT(l1c, 9));
    /* x86-64-v3 */
    printf("avx=%d\n", BIT(l1c, 28));
    printf("avx2=%d\n", BIT(l7b, 5));
    printf("bmi1=%d\n", BIT(l7b, 3));
    printf("bmi2=%d\n", BIT(l7b, 8));
    printf("f16c=%d\n", BIT(l1c, 29));
    printf("fma=%d\n", BIT(l1c, 12));
    printf("lzcnt=%d\n", BIT(e1c, 5));
    printf("movbe=%d\n", BIT(l1c, 22));
    printf("xsave=%d\n", BIT(l1c, 26));
    printf("osxsave=%d\n", osxsave);
    printf("os_avx_state=%d\n", osxsave && (xcr0 & 0x6u) == 0x6u);
    /* Informational only (above v3; never required). */
    printf("info_avx512f=%d\n", max_leaf >= 7 ? BIT(l7b, 16) : 0);
    return 0;
}
