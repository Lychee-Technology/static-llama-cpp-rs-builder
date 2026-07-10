//! Timed embedding workload. Reports embeddings/sec as JSON so bench.sh can compare a
//! packaged-release link against a from-source crate build.
//!
//! Env: SMOKE_MODEL (GGUF path), BENCH_ITERS (default 200), BENCH_RESULT (output JSON).

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case, dead_code)]

mod llama {
    include!(env!("STATIC_LLAMA_BINDINGS"));
}

use std::ffi::CString;
use std::time::Instant;

fn main() {
    let model_path = std::env::var("SMOKE_MODEL").expect("$SMOKE_MODEL not set");
    let iters: u32 = std::env::var("BENCH_ITERS").ok().and_then(|s| s.parse().ok()).unwrap_or(200);
    let c_model = CString::new(model_path).unwrap();

    unsafe {
        llama::llama_backend_init();
        let mparams = llama::llama_model_default_params();
        let model = llama::llama_model_load_from_file(c_model.as_ptr(), mparams);
        assert!(!model.is_null(), "model load failed");
        let vocab = llama::llama_model_get_vocab(model);

        let mut cparams = llama::llama_context_default_params();
        cparams.embeddings = true;
        cparams.pooling_type = llama::LLAMA_POOLING_TYPE_MEAN;
        let ctx = llama::llama_init_from_model(model, cparams);
        assert!(!ctx.is_null(), "context init failed");

        // Same representative mixed CN/EN sample as scripts/pgo-train.cpp, so the measured
        // pgo_gain reflects the sequence shape the profile was trained on. text.len() is the
        // UTF-8 BYTE count, which is what llama_tokenize expects.
        let text = concat!(
            "他问道:你想日后到英国去住吗？我说:不会的,我已经断了这个念头了 ",
            "Do you think you'll want to go back and live in England?  he asked!",
            "###I don't think so,  I said!",
            "###I think I've got that much out of my system.",
        );
        let mut toks = vec![0i32; 512];
        let n = llama::llama_tokenize(
            vocab, text.as_ptr() as *const _, text.len() as i32,
            toks.as_mut_ptr(), toks.len() as i32, true, false,
        );
        assert!(n > 0, "tokenize failed");
        toks.truncate(n as usize);

        // Warm-up (exclude first-run allocation from timing).
        for _ in 0..5 {
            let b = llama::llama_batch_get_one(toks.as_mut_ptr(), n);
            assert_eq!(llama::llama_encode(ctx, b), 0);
        }

        let start = Instant::now();
        for _ in 0..iters {
            let b = llama::llama_batch_get_one(toks.as_mut_ptr(), n);
            assert_eq!(llama::llama_encode(ctx, b), 0);
        }
        let secs = start.elapsed().as_secs_f64();
        let eps = iters as f64 / secs;

        println!("[bench] {iters} encodes in {secs:.3}s => {eps:.2} embeddings/s ({n} tokens each)");
        if let Ok(path) = std::env::var("BENCH_RESULT") {
            std::fs::write(
                path,
                format!("{{\"iters\":{iters},\"seconds\":{secs},\"embeddings_per_sec\":{eps},\"tokens\":{n}}}\n"),
            ).unwrap();
        }

        llama::llama_free(ctx);
        llama::llama_model_free(model);
        llama::llama_backend_free();
    }
}
