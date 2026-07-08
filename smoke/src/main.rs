//! Smoke test: link the prebuilt static archives and run a real init + embedding path.
//!
//! Steps: backend init -> load a tiny GGUF embedding model -> create an embeddings
//! context (mean pooling) -> tokenize -> llama_encode -> read the pooled embedding and
//! assert it is non-empty, finite, and non-zero. Also prints llama_print_system_info()
//! so CI logs show the CPU features actually compiled in (expect dotprod for N1).
//!
//! Model path comes from $SMOKE_MODEL. Result JSON is written to $SMOKE_RESULT.

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case, dead_code)]

mod llama {
    include!(env!("STATIC_LLAMA_BINDINGS"));
}

use std::ffi::{CStr, CString};
use std::process::exit;

fn fail(msg: &str) -> ! {
    eprintln!("[smoke] FAIL: {msg}");
    if let Ok(path) = std::env::var("SMOKE_RESULT") {
        let _ = std::fs::write(
            path,
            format!("{{\"passed\":false,\"error\":{msg:?}}}\n"),
        );
    }
    exit(1);
}

fn main() {
    let model_path = std::env::var("SMOKE_MODEL")
        .unwrap_or_else(|_| fail("$SMOKE_MODEL not set (path to a tiny GGUF embedding model)"));
    let c_model = CString::new(model_path.clone()).unwrap();

    unsafe {
        llama::llama_backend_init();

        let sysinfo = llama::llama_print_system_info();
        if !sysinfo.is_null() {
            println!("[smoke] system info: {}", CStr::from_ptr(sysinfo).to_string_lossy());
        }

        let mparams = llama::llama_model_default_params();
        let model = llama::llama_model_load_from_file(c_model.as_ptr(), mparams);
        if model.is_null() {
            fail(&format!("llama_model_load_from_file returned null for {model_path}"));
        }

        let vocab = llama::llama_model_get_vocab(model);
        let n_embd = llama::llama_model_n_embd(model);
        if n_embd <= 0 {
            fail("model reports n_embd <= 0");
        }

        let mut cparams = llama::llama_context_default_params();
        cparams.embeddings = true;
        cparams.pooling_type = llama::LLAMA_POOLING_TYPE_MEAN;
        let ctx = llama::llama_init_from_model(model, cparams);
        if ctx.is_null() {
            fail("llama_init_from_model returned null");
        }

        // Tokenize a tiny prompt.
        let text = "hello from graviton2";
        let mut toks = vec![0i32; 64];
        let n = llama::llama_tokenize(
            vocab,
            text.as_ptr() as *const _,
            text.len() as i32,
            toks.as_mut_ptr(),
            toks.len() as i32,
            true,  // add_special
            false, // parse_special
        );
        if n <= 0 {
            fail("tokenization produced no tokens");
        }
        toks.truncate(n as usize);

        // Encode for embeddings (encoder path; mean-pooled per sequence).
        let batch = llama::llama_batch_get_one(toks.as_mut_ptr(), n);
        if llama::llama_encode(ctx, batch) != 0 {
            fail("llama_encode failed");
        }

        let emb = llama::llama_get_embeddings_seq(ctx, 0);
        if emb.is_null() {
            fail("llama_get_embeddings_seq returned null");
        }
        let slice = std::slice::from_raw_parts(emb, n_embd as usize);
        let all_finite = slice.iter().all(|v| v.is_finite());
        let norm: f32 = slice.iter().map(|v| v * v).sum::<f32>().sqrt();
        if !all_finite {
            fail("embedding contains non-finite values");
        }
        if norm == 0.0 {
            fail("embedding is all zeros");
        }

        println!("[smoke] PASS: n_embd={n_embd}, tokens={n}, L2norm={norm:.4}");

        if let Ok(path) = std::env::var("SMOKE_RESULT") {
            let _ = std::fs::write(
                &path,
                format!(
                    "{{\"passed\":true,\"n_embd\":{n_embd},\"n_tokens\":{n},\"l2_norm\":{norm}}}\n"
                ),
            );
        }

        llama::llama_free(ctx);
        llama::llama_model_free(model);
        llama::llama_backend_free();
    }
}
