#!/usr/bin/env bash
#
# CI pre-flight, run on the RUNNER (before `docker build`): artifacts are only ever built
# natively — runner arch == container engine arch == compiler arch == artifact arch.
#
#   scripts/assert-native-runner.sh <aarch64|x86_64>
#
# Fails if the runner, its kernel, or its Docker engine is not the expected arch, or if a
# binfmt_misc (QEMU) handler for that arch would route its binaries through an emulator.
# For x86_64 the runner CPU must also pass the fail-closed x86-64-v3 gate
# (scripts/check-x86-64-v3.sh): a runner that is not v3 capable FAILS the job — CI never
# falls back to x86-64-v2 or changes CPU_MARCH (the baseline is part of the artifact
# contract, not something CI negotiates). The Dockerfile and scripts/lib.sh
# (assert_native_host) re-check inside the container.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
want="${1:?usage: assert-native-runner.sh <aarch64|x86_64>}"
case "${want}" in
  aarch64) re='aarch64|arm64'
           MSG="ARM64 artifacts must be built on a native ARM64 host. Cross-compilation and CPU emulation are not supported." ;;
  x86_64)  re='x86_64|amd64'
           MSG="x86-64 artifacts must be built on a native x86-64 (x86-64-v3 capable) host. Cross-compilation and CPU emulation are not supported." ;;
  *) echo "::error::assert-native-runner.sh: unsupported arch '${want}' (aarch64|x86_64)" >&2; exit 1 ;;
esac
die() { echo "::error::${MSG} ($*)" >&2; exit 1; }

m="$(uname -m)"
[[ "${m}" =~ ^(${re})$ ]] || die "runner uname -m: ${m}, expected ${want}"

if [[ -r /proc/sys/kernel/arch ]]; then
  k="$(cat /proc/sys/kernel/arch)"
  [[ "${k}" =~ ^(${re})$ ]] || die "runner kernel arch: ${k}, expected ${want}"
fi

if [[ -r "/proc/sys/fs/binfmt_misc/qemu-${want}" ]] \
   && grep -qx enabled "/proc/sys/fs/binfmt_misc/qemu-${want}"; then
  die "binfmt_misc qemu-${want} handler is enabled on the runner"
fi

d="n/a (no docker)"
if command -v docker >/dev/null 2>&1; then
  # Docker reports .Architecture; podman's docker shim only answers .Host.Arch.
  d="$(docker info --format '{{.Architecture}}' 2>/dev/null \
       || docker info --format '{{.Host.Arch}}' 2>/dev/null || echo unknown)"
  [[ "${d}" =~ ^(${re})$ ]] || die "docker engine architecture: ${d}, expected ${want}"
fi
echo "native ${want} runner: uname -m=${m}, kernel=${k:-n/a}, docker=${d}"

if [[ "${want}" == "x86_64" ]]; then
  # Prints "Host architecture / Required CPU baseline / x86-64-v3 capability: PASS|FAIL".
  bash "${HERE}/check-x86-64-v3.sh" || { echo "::error::runner CPU is not x86-64-v3 capable" >&2; exit 1; }
fi
