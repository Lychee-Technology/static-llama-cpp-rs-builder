#!/usr/bin/env bash
#
# Fail-closed x86-64-v3 capability gate for the NATIVE x86-64 build host. `uname -m` alone
# is not enough: an x86_64 host may be v1/v2 only. Run by scripts/lib.sh
# (assert_native_host, inside the build container) and by scripts/assert-native-runner.sh
# (on the CI runner, before the image is built).
#
# The host must satisfy ALL of the following; any negative fails the gate:
#   1. CPUID + XGETBV (scripts/x86-64-v3-probe.c, compiled for the default x86-64 baseline
#      and run natively): every x86-64-v3 feature — the v2 set plus AVX AVX2 BMI1 BMI2 F16C
#      FMA LZCNT MOVBE XSAVE OSXSAVE — and OS-enabled SSE+AVX state (XCR0 & 0x6). This is
#      the primary check and is mandatory (no compiler => cannot verify => FAIL).
#   2. glibc's own hwcaps view (`ld.so --help`, glibc >= 2.33, CPUID + OS usability): must
#      list "x86-64-v3 (supported". Mandatory whenever the loader can answer.
#   3. /proc/cpuinfo flags (when readable): every feature present, with Linux's naming
#      (SSE3 = "pni", LZCNT = "abm", LAHF/SAHF = "lahf_lm"; OSXSAVE / XCR0 are not
#      exposed there and are covered by 1 and 2).
# There is NO fallback: a host that is not x86-64-v3 capable is refused — the build never
# downgrades to x86-64-v2 and never adjusts CPU_MARCH (the baseline is part of the
# artifact contract).
#
# Usage: scripts/check-x86-64-v3.sh [--json FILE]
#   --json FILE   also write a machine-readable summary (recorded in build-info.json).
# Self-test hook: X86_V3_GATE_SELFTEST_DROP="avx2 fma" treats those CPUID features as
# absent. It can only make the gate FAIL (it removes features, never adds one).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_OUT=""
if [[ "${1:-}" == "--json" ]]; then JSON_OUT="${2:?--json needs a file}"; fi

REQUIRED="cx16 lahf_lm popcnt sse3 sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma lzcnt movbe xsave osxsave os_avx_state"
FAIL_MSG="ERROR: native x86 build requires an x86-64-v3 capable CPU.
This project intentionally does not support x86-64-v2 or older hosts."

reasons=()
m="$(uname -m)"
echo "Host architecture: ${m}"
echo "Required CPU baseline: x86-64-v3"
[[ "${m}" == "x86_64" ]] || reasons+=("host architecture is ${m}, not x86_64")
cpu_model="$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n1 || true)"
echo "CPU model: ${cpu_model:-unknown}"

# --- 1. CPUID + XGETBV probe (mandatory) ---------------------------------------------
declare -A have=()
probe_status="unavailable"
if [[ "${m}" == "x86_64" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  cc_bin=""
  for c in "${CC:-}" cc gcc clang clang-18; do
    [[ -n "${c}" ]] && command -v "${c}" >/dev/null 2>&1 && { cc_bin="${c}"; break; }
  done
  # NO -march / CFLAGS: the probe must run on non-v3 CPUs to report what is missing.
  if [[ -z "${cc_bin}" ]]; then
    reasons+=("no C compiler to build the CPUID/XGETBV probe (cannot verify)")
  elif ! "${cc_bin}" -O1 -o "${tmp}/probe" "${HERE}/x86-64-v3-probe.c" 2>"${tmp}/cc.log"; then
    reasons+=("CPUID/XGETBV probe failed to compile with ${cc_bin}: $(tr '\n' ' ' <"${tmp}/cc.log")")
  elif ! "${tmp}/probe" >"${tmp}/probe.out"; then
    reasons+=("CPUID/XGETBV probe failed to run")
  else
    while IFS='=' read -r k v; do have["${k}"]="${v}"; done <"${tmp}/probe.out"
    for f in ${X86_V3_GATE_SELFTEST_DROP:-}; do
      echo "SELFTEST: treating '${f}' as absent (X86_V3_GATE_SELFTEST_DROP)"
      have["${f}"]=0
    done
    missing=()
    for f in ${REQUIRED}; do [[ "${have[${f}]:-0}" == 1 ]] || missing+=("${f}"); done
    if [[ "${#missing[@]}" -eq 0 ]]; then
      probe_status="pass"
      echo "CPUID/XGETBV: all x86-64-v3 features present, OS AVX state enabled"
    else
      probe_status="fail"
      reasons+=("CPUID/XGETBV missing: ${missing[*]}")
      echo "CPUID/XGETBV: MISSING ${missing[*]}"
    fi
  fi
fi

# --- 2. glibc hwcaps (mandatory when the loader answers) -----------------------------
hwcaps_status="unavailable"
for ldso in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
  [[ -x "${ldso}" ]] || continue
  out="$("${ldso}" --help 2>/dev/null || true)"
  if grep -qE '^[[:space:]]*x86-64-v3 \(supported' <<<"${out}"; then
    hwcaps_status="supported"
  elif grep -qE '^[[:space:]]*x86-64-v3([[:space:]]|$)' <<<"${out}"; then
    hwcaps_status="unsupported"
    reasons+=("glibc (${ldso} --help) reports x86-64-v3 NOT supported")
  fi
  break
done
echo "glibc hwcaps (ld.so --help): x86-64-v3 ${hwcaps_status}"

# --- 3. /proc/cpuinfo flags (cross-check when readable) ------------------------------
cpuinfo_status="unavailable"
flags=" $(sed -n 's/^flags[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n1 || true) "
if [[ -n "${flags// /}" ]]; then
  cmissing=()
  for f in ${REQUIRED}; do
    case "${f}" in
      osxsave|os_avx_state) continue ;;               # not exposed in /proc/cpuinfo
      sse3)  alts="pni sse3" ;;
      lzcnt) alts="abm lzcnt" ;;
      *)     alts="${f}" ;;
    esac
    ok=0; for a in ${alts}; do [[ "${flags}" == *" ${a} "* ]] && ok=1; done
    [[ "${ok}" == 1 ]] || cmissing+=("${f}")
  done
  if [[ "${#cmissing[@]}" -eq 0 ]]; then
    cpuinfo_status="agree"
  else
    cpuinfo_status="missing:${cmissing[*]}"
    reasons+=("/proc/cpuinfo flags missing: ${cmissing[*]}")
  fi
fi
echo "/proc/cpuinfo flags: ${cpuinfo_status}"

[[ "${probe_status}" == "pass" ]] || [[ "${#reasons[@]}" -gt 0 ]] \
  || reasons+=("CPUID/XGETBV probe did not run")

result="PASS"; [[ "${#reasons[@]}" -eq 0 ]] || result="FAIL"
if [[ -n "${JSON_OUT}" ]]; then
  feats="$(for f in ${REQUIRED}; do printf '%s\n' "${f}=${have[${f}]:-0}"; done \
           | jq -R 'split("=") | {(.[0]): (.[1] == "1")}' | jq -s 'add // {}')"
  jq -n --arg result "${result}" --arg model "${cpu_model}" --arg probe "${probe_status}" \
        --arg hwcaps "${hwcaps_status}" --arg cpuinfo "${cpuinfo_status}" \
        --argjson features "${feats}" \
        --arg avx512f "${have[info_avx512f]:-0}" \
        '{baseline: "x86-64-v3", result: $result, cpu_model: $model,
          checks: {cpuid_xgetbv: $probe, glibc_hwcaps: $hwcaps, proc_cpuinfo: $cpuinfo},
          required_features: $features, info: {avx512f: ($avx512f == "1")}}' >"${JSON_OUT}"
fi

if [[ "${result}" == "PASS" ]]; then
  echo "x86-64-v3 capability: PASS"
  exit 0
fi
echo "x86-64-v3 capability: FAIL" >&2
printf '  - %s\n' "${reasons[@]}" >&2
echo "${FAIL_MSG}" >&2
exit 1
