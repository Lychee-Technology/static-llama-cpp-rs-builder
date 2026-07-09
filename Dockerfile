# Build image for Graviton2-optimized static llama-cpp-rs artifacts.
#
# Base: Amazon Linux 2023 (aarch64) — the compiler baseline (Clang 18, GNU libstdc++,
# glibc 2.34). This is resolved-and-recorded build provenance, NOT a runtime pin (LTEmbed
# runs on AWS-managed AL2023). CI resolves the current digest, records it in build-info.json,
# and gates the environment envelope (EXPECTED_CLANG_MAJOR / MIN_GLIBC). To pin the base image
# for a run (aids tracing; NOT full reproducibility — dnf still pulls current packages),
# override:
#   docker build --build-arg AL2023_DIGEST=2023@sha256:<...> .
# The default is the plain tag.
ARG AL2023_DIGEST=2023
FROM amazonlinux:${AL2023_DIGEST}

# --- Pinned tool versions (build inputs; bump deliberately) ---
ARG CMAKE_VERSION=3.29.6
ARG RUST_VERSION=1.96.1

# Compiler: Clang 18 (clang18) — builds the archives AND (via libclang from clang18-devel)
# drives bindgen. gcc/g++ are still installed because clang uses GNU libstdc++ headers/crt
# on Linux and rustc links via the `cc` (gcc) driver. python for ggml scripts.
#
# llvm18 provides `llvm-profdata` and compiler-rt18 provides libclang_rt.profile — both are
# needed ONLY for the opt-in PGO build path (scripts/build.sh with PGO=1); the default
# single-phase build does not use them. compiler-rt MUST be the clang-18-matched package
# (compiler-rt18): AL2023's unversioned `compiler-rt` is clang-15's runtime, and linking
# clang-18 -fprofile-generate against the clang-15 profile runtime SEGFAULTS at run time
# (ABI mismatch). compiler-rt18 installs the profile lib in clang-18's per-target search
# path so no path hack is needed. If AL2023 renames the package the image build fails here.
RUN dnf -y update \
 && dnf -y install \
      gcc gcc-c++ \
      clang18 clang18-devel llvm18 compiler-rt18 \
      git make ninja-build \
      python3 python3-pip \
      tar gzip xz which findutils jq \
      openssl-devel perl \
 && dnf clean all

# Compile with Clang 18. Binaries are version-suffixed (no unversioned `clang` on AL2023).
ENV CC=clang-18 CXX=clang++-18
# bindgen (clang-sys) locates libclang here on AL2023 (llvm18 tree, not /usr/lib64).
ENV LIBCLANG_PATH=/usr/lib64/llvm18/lib

# Prove the PGO instrument runtime works: compile, link, AND RUN a -fprofile-generate
# binary, then require it emitted a .profraw. Running (not just linking) is essential — a
# mismatched profile runtime links fine but segfaults on execution, which is exactly how
# the clang-15-vs-clang-18 bug hid before. Only PGO uses this; harmless for the default
# build. Fails the image build loudly if compiler-rt18's profile runtime is missing/broken.
RUN set -eux; \
    printf 'int main(void){return 0;}\n' > /tmp/pgo-probe.c; \
    clang-18 -fprofile-generate /tmp/pgo-probe.c -o /tmp/pgo-probe; \
    ( cd /tmp && LLVM_PROFILE_FILE=/tmp/pgo-%p.profraw ./pgo-probe ); \
    test -n "$(ls /tmp/pgo-*.profraw 2>/dev/null)"; \
    rm -f /tmp/pgo-probe /tmp/pgo-probe.c /tmp/pgo-*.profraw

# CMake pinned to an exact version (do not rely on the distro package).
RUN set -eux; \
    arch="$(uname -m)"; \
    url="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-${arch}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/cmake.tgz; \
    tar -xzf /tmp/cmake.tgz -C /opt; \
    ln -s "/opt/cmake-${CMAKE_VERSION}-linux-${arch}/bin/"* /usr/local/bin/; \
    rm -f /tmp/cmake.tgz; \
    cmake --version | grep "${CMAKE_VERSION}"

# Rust via rustup, pinned. rust-toolchain.toml in the repo re-asserts the version.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN set -eux; \
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh; \
    sh /tmp/rustup.sh -y --profile minimal \
      --default-toolchain "${RUST_VERSION}" \
      --target aarch64-unknown-linux-gnu; \
    rm -f /tmp/rustup.sh; \
    rustc --version | grep "${RUST_VERSION}"

WORKDIR /work
