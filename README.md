# static-llama-cpp-rs-builder

Produces **Graviton2 (Neoverse N1) tuned static llama.cpp archives** for
`aarch64-unknown-linux-gnu`, packaged with pinned provenance + checksums, for LTEmbed to
link directly (no per-build llama.cpp recompile).

## What a release contains

Static `.a` (`libllama`, `libggml`, `libggml-base`, `libggml-cpu`, `libllama-common`),
generated `bindings.rs`, headers, `build-info.json`, `SHA256SUMS`, licenses, and a drop-in
`consume.build.rs`. See [CONTRACT.md](CONTRACT.md) for the full contract and consumption steps.

## Pinned inputs

Single source of truth: [`scripts/config.env`](scripts/config.env).

| Input | Pin |
|---|---|
| `llama-cpp-sys-2` | tag `0.1.151` |
| llama.cpp submodule | `9e3b928…` (verified at build time) |
| Rust | `1.85.0` (`rust-toolchain.toml`) |
| CMake | `3.29.6` (`Dockerfile`) |
| CPU profile | `-mcpu=neoverse-n1` (never `native`) |
| Features | `common,openmp` |

**Build image (not a pin):** `amazonlinux:2023` is **resolved at build time and recorded** in
`build-info.json` (`build_env`), not pinned as a product input — LTEmbed deploys on AWS-managed
AL2023 (Lambda/Fargate). Consumers pin the **release artifact checksum**, not the build image.
CI gates the environment envelope (`EXPECTED_GCC_MAJOR`, `MIN_GLIBC`); set `AL2023_DIGEST` to
force a reproducible build against a specific patch level.

## How it works

1. `scripts/build.sh` — clones the pinned crate, builds `llama-cpp-sys-2` with
   `-mcpu=neoverse-n1` injected via `CFLAGS`, runs a **flag-verification gate**
   (asserts N1 tuning, no `native`, no conflicting `-march`), harvests `.a` + bindings +
   headers into `dist/`, and writes `build-info.json`.
2. **smoke** (`smoke/`) — links the archives and runs a real embedding/context-init test.
3. `scripts/bench.sh` (`bench/`) — compares prebuilt vs from-source performance, enforcing a
   regression threshold.
4. `scripts/package.sh` — merges results, gathers licenses, writes `SHA256SUMS`.

CI (`.github/workflows/release.yml`) runs all of this on a GitHub-hosted **ARM64 (N2)**
runner inside a resolved-and-recorded AL2023 container and publishes a GitHub Release on `v*` tags.

## Local run (on an aarch64 Linux host / container)

```sh
# Default resolves amazonlinux:2023 latest. For a reproducible build against a specific
# patch level, add: --build-arg AL2023_DIGEST=2023@sha256:<digest>
docker build -t static-llama-builder .
docker run --rm -v "$PWD:/work" -w /work \
  -e SMOKE_MODEL_URL=<url> -e SMOKE_MODEL_SHA256=<pinned-sha> static-llama-builder bash -c '
    git config --global --add safe.directory "*"
    scripts/build.sh
    export SMOKE_MODEL="$(smoke/fixtures/fetch-model.sh)"
    export RESULTS=/work/.build/results; mkdir -p "$RESULTS"
    SMOKE_RESULT="$RESULTS/smoke.json" cargo run --release --manifest-path smoke/Cargo.toml
    scripts/bench.sh && scripts/package.sh'
```

Before the first release, pin the smoke/bench model: set the `SMOKE_MODEL_URL` /
`SMOKE_MODEL_SHA256` repo variables (see `smoke/fixtures/fetch-model.sh`).
