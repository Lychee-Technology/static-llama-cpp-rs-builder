#!/usr/bin/env bash
#
# Verify that a built dist/build-info.json records exactly the pins in scripts/config.env:
# artifact contract version, llama.cpp tag + commit (and that the compiled tree's describe
# and embedded commit agree), llama-cpp-rs ref + commit, llama-cpp-sys-2 version, crate
# features (== CRATE_FEATURES), the target profile (arch, triple, CPU baseline, flags), and
# a native build (host arch == target arch; x86_64: the build host passed the x86-64-v3
# gate). Release CI runs this before publishing; it needs only bash + jq, so it can also be
# pointed at a downloaded release's build-info.json from any machine.
#
#   scripts/verify-provenance.sh [path/to/build-info.json [PROFILE]]
#     default file: dist/build-info.json; default PROFILE: the one config.env selects for
#     this host (pass aarch64-graviton2 or x86_64-v3 to check a file from elsewhere).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"
BI="${1:-${ROOT}/dist/build-info.json}"
[[ -f "${BI}" ]] || { echo "verify-provenance: ${BI} not found" >&2; exit 1; }
if [[ -n "${2:-}" ]]; then set_target_profile "$2"; fi
[[ -n "${TARGET_PROFILE}" ]] \
  || { echo "verify-provenance: no target profile for host '$(uname -m)'; pass one of: ${SUPPORTED_TARGET_PROFILES}" >&2; exit 1; }

jq -e \
  --arg contract "${ARTIFACT_CONTRACT_VERSION}" \
  --arg llc_tag "${LLAMA_CPP_TAG}" \
  --arg llc_commit "${EXPECTED_LLAMA_CPP_COMMIT}" \
  --arg crate_ref "${CRATE_REF}" \
  --arg crate_commit "${EXPECTED_CRATE_COMMIT}" \
  --arg crate_version "${CRATE_VERSION}" \
  --arg crate_gitlink "${CRATE_VENDORED_LLAMA_CPP_COMMIT}" \
  --arg features "${CRATE_FEATURES}" \
  --arg triple "${TARGET_TRIPLE}" \
  --arg profile "${TARGET_PROFILE}" \
  --arg arch "${TARGET_ARCH}" \
  --arg baseline "${CPU_BASELINE}" \
  --arg cpu_profile "${CPU_PROFILE}" \
  --arg flags "${CFLAGS_TUNE}" \
  --arg march "${CPU_MARCH}" \
  --arg mtune "${CPU_MTUNE}" \
  '
  def check(name; cond): if cond then true else error("provenance mismatch: \(name)") end;
  check("artifact_contract_version"; (.artifact_contract_version | tostring) == $contract)
  and check("llama_cpp.tag";        .llama_cpp.tag == $llc_tag)
  and check("llama_cpp.tag_type";   .llama_cpp.tag_type == "tag")
  and check("llama_cpp.commit";     .llama_cpp.commit == $llc_commit)
  and check("llama_cpp.describe";   .llama_cpp.describe == $llc_tag)
  and (.llama_cpp.embedded_commit as $emb
       | check("llama_cpp.embedded_commit";
               ($emb | type) == "string" and ($emb | length) >= 7
               and ($llc_commit | startswith($emb))))
  and check("llama_cpp_rs.git_ref"; .llama_cpp_rs.git_ref == $crate_ref)
  and check("llama_cpp_rs.commit";  .llama_cpp_rs.commit == $crate_commit)
  and check("llama_cpp_rs.vendored_llama_cpp_commit";
            .llama_cpp_rs.vendored_llama_cpp_commit == $crate_gitlink)
  and check("llama_cpp_sys_2.version"; .llama_cpp_sys_2.version == $crate_version)
  and check("llama_cpp_sys_2.default_features"; .llama_cpp_sys_2.default_features == false)
  and check("llama_cpp_sys_2.features";
            .llama_cpp_sys_2.features == ($features | split(",") | map(select(. != ""))))
  and check("target_profile";       .target_profile == $profile)
  and check("architecture";         .architecture == $arch)
  and check("target_triple";        .target_triple == $triple)
  and check("cpu_baseline";         .cpu_baseline == $baseline)
  and check("cpu_profile";          .cpu_profile == $cpu_profile)
  # The CPU contract flags are exactly the profile flags, PGO or not (PGO flags: pgo.use_flags).
  and check("effective_arch_flags"; .effective_arch_flags == $flags)
  and check("arch_flag_summary.march"; .arch_flag_summary.march == $march)
  and check("arch_flag_summary.mtune";
            .arch_flag_summary.mtune == (if $mtune == "" then null else $mtune end))
  and check("arch_flag_summary.conflicts"; .arch_flag_summary.conflicts == 0)
  and check("build_env.native_build"; .build_env.native_build == true)
  and check("host.native_build";     .host.native_build == true)
  and (if $arch == "aarch64"
       then check("build_env.host_arch"; .build_env.host_arch == "aarch64" or .build_env.host_arch == "arm64")
            and check("host.architecture"; .host.architecture == "aarch64" or .host.architecture == "arm64")
       else check("build_env.host_arch"; .build_env.host_arch == "x86_64")
            and check("host.architecture"; .host.architecture == "x86_64")
            and check("host.cpu_capability (x86-64-v3 gate PASS)";
                      .host.cpu_capability.baseline == "x86-64-v3"
                      and .host.cpu_capability.result == "PASS")
            and check("arch_flag_summary.effective_isa"; .arch_flag_summary.effective_isa == "x86-64-v3")
            and check("arch_flag_summary.disassembly.above_v3"; .arch_flag_summary.disassembly.above_v3 == 0)
       end)
  and check("pgo.architecture";
            if .pgo.enabled == true
            then .pgo.architecture == $arch and .pgo.cpu_baseline == $baseline
            else true end)
  and check("pgo.use_flags";
            if .pgo.enabled == true
            then (.pgo.use_flags | type) == "string" and (.pgo.use_flags | startswith("-fprofile-use="))
            else .pgo.use_flags == null end)
  ' "${BI}" >/dev/null

echo "provenance OK: contract v${ARTIFACT_CONTRACT_VERSION}; llama.cpp ${LLAMA_CPP_TAG} @ ${EXPECTED_LLAMA_CPP_COMMIT}; llama-cpp-rs ${CRATE_REF} @ ${EXPECTED_CRATE_COMMIT} (llama-cpp-sys-2 ${CRATE_VERSION}); native ${TARGET_TRIPLE} (${TARGET_PROFILE}: ${CFLAGS_TUNE})"
