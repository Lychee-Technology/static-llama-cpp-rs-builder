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
# The build-only aarch64-apple-darwin profile (config.env BUILD_ONLY_TARGET_PROFILES) is
# accepted in --raw mode only, where it must record no contract version, the apple-m1
# baseline, the pinned macOS deployment target, a passing consumer link check, and no Linux
# build environment (glibc, image, rpm packages, lscpu). It is never a release, so
# --packaged refuses it.
#
# It then checks the release results (smoke, embeddinggemma_smoke, logits_smoke, benchmark,
# correctness) with the gate package.sh applies (lib.sh assert_release_results):
#   --packaged (default)  every result must be present and pass. Use it on anything
#                         package.sh produced, including every downloaded release.
#   --raw                 for fresh build.sh output, which has no results yet: none is
#                         required, but one that is present must still pass.
#
#   scripts/verify-provenance.sh [--packaged | --raw] [path/to/build-info.json [PROFILE]]
#     default file: dist/build-info.json; default PROFILE: the one config.env selects for
#     this host (pass aarch64-graviton2, x86_64-v3 or, with --raw, aarch64-apple-darwin to
#     check a file from elsewhere).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/config.env"
source "${ROOT}/scripts/lib.sh"
LIB_TAG=verify-provenance
usage="usage: verify-provenance.sh [--packaged | --raw] [path/to/build-info.json [PROFILE]]"
MODE=packaged
case "${1:-}" in
  --packaged) shift ;;
  --raw) MODE=raw; shift ;;
  -*) echo "verify-provenance: unknown option '$1'; ${usage}" >&2; exit 2 ;;
esac
[[ $# -le 2 ]] || { echo "verify-provenance: too many arguments; ${usage}" >&2; exit 2; }
BI="${1:-${ROOT}/dist/build-info.json}"
[[ -f "${BI}" ]] || { echo "verify-provenance: ${BI} not found" >&2; exit 1; }
if [[ -n "${2:-}" ]]; then set_target_profile "$2"; fi
[[ -n "${TARGET_PROFILE}" ]] \
  || { echo "verify-provenance: no target profile for host '$(uname -s) $(uname -m)'; pass one of: ${SUPPORTED_TARGET_PROFILES} (or, with --raw, ${BUILD_ONLY_TARGET_PROFILES})" >&2; exit 1; }
if [[ "${MODE}" == packaged ]]; then assert_release_profile "${TARGET_PROFILE}"; fi
case " ${BUILD_ONLY_TARGET_PROFILES} " in *" ${TARGET_PROFILE} "*) BUILD_ONLY=true ;; *) BUILD_ONLY=false ;; esac

jq -e \
  --arg contract "${ARTIFACT_CONTRACT_VERSION}" \
  --arg llc_tag "${LLAMA_CPP_TAG}" \
  --arg llc_commit "${EXPECTED_LLAMA_CPP_COMMIT}" \
  --arg llc_tag_type "${EXPECTED_LLAMA_CPP_TAG_TYPE}" \
  --arg llc_version "${EXPECTED_LLAMA_CPP_VERSION}" \
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
  --arg mcpu "${CPU_MCPU}" \
  --arg mtune "${CPU_MTUNE}" \
  --arg os "${TARGET_OS}" \
  --arg native_arch "${NATIVE_ARCH}" \
  --arg macos_min "${MACOS_DEPLOYMENT_TARGET}" \
  --arg system_libs "${SYSTEM_LINK_LIBS}" \
  --arg link_line "$(for l in ${STATIC_LIBS}; do l="${l#lib}"; printf -- '-l%s ' "${l%.a}"; done; for l in ${SYSTEM_LINK_LIBS}; do printf -- '-l%s ' "${l}"; done)" \
  --argjson build_only "${BUILD_ONLY}" \
  '
  def check(name; cond): if cond then true else error("provenance mismatch: \(name)") end;
  # A build-only profile is outside the artifact contract: it must not claim a version.
  check("artifact_contract_version";
        if $build_only then .artifact_contract_version == null
        else (.artifact_contract_version | tostring) == $contract end)
  # ...and a release variant must not claim to be build-only.
  and check("build_only"; if $build_only then .build_only == true else has("build_only") | not end)
  and check("llama_cpp.tag";        .llama_cpp.tag == $llc_tag)
  and check("llama_cpp.tag_type";   .llama_cpp.tag_type == $llc_tag_type)
  and check("llama_cpp.commit";     .llama_cpp.commit == $llc_commit)
  and check("llama_cpp.describe";   .llama_cpp.describe == $llc_tag)
  and check("llama_cpp.embedded_version";
            .llama_cpp.embedded_version == $llc_version or .llama_cpp.embedded_version == ($llc_version + "-dev"))
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
  and check("arch_flag_summary.march";
            .arch_flag_summary.march == (if $march == "" then null else $march end))
  and check("arch_flag_summary.mtune";
            .arch_flag_summary.mtune == (if $mtune == "" then null else $mtune end))
  and check("arch_flag_summary.conflicts"; .arch_flag_summary.conflicts == 0)
  and check("build_env.native_build"; .build_env.native_build == true)
  and check("host.native_build";     .host.native_build == true)
  and (if $os == "macos"
       then check("target_os"; .target_os == "macos")
            and check("build_env.host_arch"; .build_env.host_arch == $native_arch)
            and check("host.architecture"; .host.architecture == $native_arch)
            and check("host.cpu_capability (apple-m1 gate PASS)";
                      .host.cpu_capability.baseline == $baseline
                      and .host.cpu_capability.result == "PASS"
                      and .host.cpu_capability.rosetta == false)
            and check("arch_flag_summary.mcpu"; .arch_flag_summary.mcpu == $mcpu)
            and check("arch_flag_summary.effective_isa"; .arch_flag_summary.effective_isa == $baseline)
            and check("arch_flag_summary.backend_target_cpus";
                      (.arch_flag_summary.backend_target_cpus | type) == "array"
                      and (.arch_flag_summary.backend_target_cpus | length) > 0
                      and all(.arch_flag_summary.backend_target_cpus[]; . == "apple-m1" or . == "apple-a14"))
            and check("macos_deployment_target"; .macos_deployment_target == $macos_min)
            and check("arch_flag_summary.macos_version_min"; .arch_flag_summary.macos_version_min == $macos_min)
            and check("arch_flag_summary.objects";
                      .arch_flag_summary.objects.platform == "macos"
                      and .arch_flag_summary.objects.arch == $native_arch
                      and .arch_flag_summary.objects.minos == $macos_min
                      and .arch_flag_summary.objects.weak_undefined == 0
                      and .arch_flag_summary.objects.objects > 0)
            and check("link_check";
                      .link_check.passed == true
                      and .link_check.system_libs == ($system_libs | split(" ") | map(select(. != "")))
                      and .link_check.each_system_lib_required == true
                      and .link_check.frameworks == []
                      and .link_check.backends == ["CPU"]
                      and .link_check.minos == $macos_min
                      and .link_check.archive_order_back_references == 0)
            and check("link_line"; .link_line == ($link_line | sub(" +$"; "")))
            and check("pgo.enabled"; .pgo.enabled == false)
            # No Linux claims: macOS has no AL2023 image, rpm packages, glibc or lscpu.
            and check("build_env (no Linux image/packages/glibc)";
                      (.build_env | has("image") or has("packages") or has("glibc")) | not)
            and check("runner (no lscpu)"; (.runner | has("lscpu")) | not)
       elif $arch == "aarch64"
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

assert_release_results "${MODE}" "${BI}"
if [[ "${MODE}" == packaged ]]; then results="release results present and passing"
else results="raw build metadata, release results not required"; fi
if [[ "${BUILD_ONLY}" == true ]]; then contract="build-only, no artifact contract"
else contract="contract v${ARTIFACT_CONTRACT_VERSION}"; fi

echo "provenance OK (${results}): ${contract}; llama.cpp ${LLAMA_CPP_TAG} @ ${EXPECTED_LLAMA_CPP_COMMIT}; llama-cpp-rs ${CRATE_REF} @ ${EXPECTED_CRATE_COMMIT} (llama-cpp-sys-2 ${CRATE_VERSION}); native ${TARGET_TRIPLE} (${TARGET_PROFILE}: ${CFLAGS_TUNE})"
