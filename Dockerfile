# Build image for Graviton2-optimized static llama-cpp-rs artifacts.
#
# Base: Amazon Linux 2023 (aarch64) — the compiler baseline (glibc 2.34, gcc 11). This is
# resolved-and-recorded build provenance, NOT a runtime pin (LTEmbed runs on AWS-managed
# AL2023). CI resolves the current digest, records it in build-info.json, and gates the
# environment envelope (EXPECTED_GCC_MAJOR / MIN_GLIBC). For a reproducible build against a
# specific patch level, override: docker build --build-arg AL2023_DIGEST=2023@sha256:<...> .
# The default is the plain tag.
ARG AL2023_DIGEST=2023
FROM amazonlinux:${AL2023_DIGEST}

# --- Pinned tool versions (build inputs; bump deliberately) ---
ARG CMAKE_VERSION=3.29.6
ARG RUST_VERSION=1.85.0

# Toolchain: gcc/g++ 11 (AL2023 default), git, make, ninja, python (ggml scripts), curl.
RUN dnf -y update \
 && dnf -y install \
      gcc gcc-c++ \
      git make ninja-build \
      python3 python3-pip \
      tar gzip xz which findutils jq \
      openssl-devel perl \
 && dnf clean all

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
