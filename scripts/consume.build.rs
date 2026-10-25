// Drop-in build.rs for linking the prebuilt static llama.cpp archives (either production
// variant: aarch64-graviton2 or x86_64-v3; use the one whose build-info.json `target_triple`
// equals your crate's target, the archives contain native code for that target only). It
// also links a build of the build-only aarch64-apple-darwin profile, which is not a
// release variant and is not covered by CONTRACT.md.
//
// Copy this into your crate as `build.rs` (LTEmbed does this), or `include!` it.
// Point STATIC_LLAMA_DIR at the directory of a VERIFIED, extracted release — the one
// whose SHA256SUMS you have already checked. It must contain `lib/*.a` and `bindings.rs`.
//
// This file is also the single source of truth for the smoke crate (which include!s it),
// so the link line the release is tested with is exactly the one consumers get.

use std::{env, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=STATIC_LLAMA_DIR");

    let dir = env::var("STATIC_LLAMA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist"));

    let libdir = dir.join("lib");
    assert!(
        libdir.join("libllama.a").exists(),
        "libllama.a not found in {} — set STATIC_LLAMA_DIR to the extracted, SHA-verified release",
        libdir.display()
    );
    println!("cargo:rustc-link-search=native={}", libdir.display());

    // Static archives, in dependency order (a lib must precede the libs it needs for GNU ld).
    // This order is the canonical one in scripts/config.env (STATIC_LIBS) and equals
    // build-info.json's `link_line`; keep all three in sync. If you ever hit unresolved
    // symbols, the archives are safe to wrap in a linker group.
    for lib in ["llama", "ggml", "ggml-cpu", "ggml-base"] {
        println!("cargo:rustc-link-lib=static={lib}");
    }

    // C++ runtime + OS deps of the TARGET OS (== config.env SYSTEM_LINK_LIBS of its profile,
    // == build-info.json link_line tail), linked dynamically from the system. No -lgomp:
    // OpenMP is disabled (ggml threadpool).
    //   linux: GNU libstdc++ and glibc, from the base image.
    //   macos: libc++ only; libSystem is implicit, and no framework is needed (ggml's Metal
    //          and Accelerate backends are off).
    // There are no archives for any other OS, so anything else fails here, not at link time.
    let system_libs: &[&str] = match env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("linux") => &["stdc++", "pthread", "m", "dl"],
        Ok("macos") => &["c++"],
        other => panic!("no static llama.cpp archives for target OS {other:?} (linux and macos only)"),
    };
    for lib in system_libs {
        println!("cargo:rustc-link-lib=dylib={lib}");
    }

    // Expose the generated FFI bindings path so consumers can `include!(env!("..."))`.
    let bindings = dir.join("bindings.rs");
    assert!(bindings.exists(), "bindings.rs not found in {}", dir.display());
    println!("cargo:rustc-env=STATIC_LLAMA_BINDINGS={}", bindings.display());
}
