// Drop-in build.rs for linking the prebuilt Graviton2 static llama.cpp archives.
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
    // If you ever hit unresolved symbols, the archives are safe to wrap in a linker group.
    for lib in ["llama-common", "llama", "ggml", "ggml-cpu", "ggml-base"] {
        println!("cargo:rustc-link-lib=static={lib}");
    }

    // C++ runtime + OS deps (mirror build-info.json "link_line"). Dynamic from the base image.
    for lib in ["stdc++", "gomp", "pthread", "m", "dl"] {
        println!("cargo:rustc-link-lib=dylib={lib}");
    }

    // Expose the generated FFI bindings path so consumers can `include!(env!("..."))`.
    let bindings = dir.join("bindings.rs");
    assert!(bindings.exists(), "bindings.rs not found in {}", dir.display());
    println!("cargo:rustc-env=STATIC_LLAMA_BINDINGS={}", bindings.display());
}
