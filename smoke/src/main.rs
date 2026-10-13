//! Smoke test: link the prebuilt static archives and run a real init + embedding path.
//!
//! Steps: backend init -> load a tiny GGUF embedding model -> create an embeddings
//! context (mean pooling) -> tokenize -> llama_encode -> read the pooled embedding and
//! assert it is non-empty, finite, and non-zero. Also prints llama_print_system_info()
//! so CI logs show the CPU features actually compiled in (expect dotprod for N1).
//!
//! Model path comes from $SMOKE_MODEL. Result JSON is written to $SMOKE_RESULT.

#![allow(
    non_upper_case_globals,
    non_camel_case_types,
    non_snake_case,
    dead_code
)]

mod llama {
    include!(env!("STATIC_LLAMA_BINDINGS"));
}

use std::ffi::{CStr, CString};
use std::process::exit;

fn check_dimensions(
    hidden: i32,
    output: i32,
    expected_hidden: Option<i32>,
    expected_output: Option<i32>,
) -> Result<(), String> {
    if hidden <= 0 || output <= 0 {
        return Err(format!(
            "invalid embedding dimensions: hidden={hidden}, output={output}"
        ));
    }
    if expected_hidden.is_some_and(|expected| hidden != expected)
        || expected_output.is_some_and(|expected| output != expected)
    {
        return Err(format!(
            "unexpected embedding dimensions: hidden={hidden}, output={output}"
        ));
    }
    Ok(())
}

fn expected_dimension(name: &str) -> Option<i32> {
    std::env::var(name).ok().map(|value| {
        value
            .parse::<i32>()
            .ok()
            .filter(|&dim| dim > 0)
            .unwrap_or_else(|| fail(&format!("{name} must be a positive integer")))
    })
}

fn fail(msg: &str) -> ! {
    eprintln!("[smoke] FAIL: {msg}");
    if let Ok(path) = std::env::var("SMOKE_RESULT") {
        let _ = std::fs::write(path, format!("{{\"passed\":false,\"error\":{msg:?}}}\n"));
    }
    exit(1);
}

fn main() {
    let model_path = std::env::var("SMOKE_MODEL")
        .unwrap_or_else(|_| fail("$SMOKE_MODEL not set (path to a tiny GGUF embedding model)"));
    let c_model = CString::new(model_path.clone()).unwrap();
    let model_id = std::env::var("SMOKE_MODEL_ID").unwrap_or_default();
    if !model_id
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"/._-".contains(&byte))
    {
        fail("SMOKE_MODEL_ID contains invalid characters");
    }
    let digest = std::process::Command::new("sha256sum")
        .arg(&model_path)
        .output()
        .unwrap_or_else(|_| fail("cannot compute model SHA-256"));
    if !digest.status.success() {
        fail("model SHA-256 command failed");
    }
    let digest =
        String::from_utf8(digest.stdout).unwrap_or_else(|_| fail("invalid model SHA-256 output"));
    let model_sha = digest.split_whitespace().next().unwrap_or("");
    if model_sha.len() != 64 || !model_sha.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        fail("invalid model SHA-256");
    }
    if let Ok(expected) = std::env::var("SMOKE_MODEL_SHA256") {
        if model_sha != expected {
            fail("model SHA-256 does not match the pinned smoke input");
        }
    }

    unsafe {
        llama::llama_backend_init();

        let sysinfo = llama::llama_print_system_info();
        if !sysinfo.is_null() {
            println!(
                "[smoke] system info: {}",
                CStr::from_ptr(sysinfo).to_string_lossy()
            );
        }

        let mparams = llama::llama_model_default_params();
        let model = llama::llama_model_load_from_file(c_model.as_ptr(), mparams);
        if model.is_null() {
            fail(&format!(
                "llama_model_load_from_file returned null for {model_path}"
            ));
        }

        let vocab = llama::llama_model_get_vocab(model);
        let n_embd = llama::llama_model_n_embd(model);
        let n_embd_out = llama::llama_model_n_embd_out(model);
        if let Err(error) = check_dimensions(
            n_embd,
            n_embd_out,
            expected_dimension("SMOKE_EXPECTED_HIDDEN_DIM"),
            expected_dimension("SMOKE_EXPECTED_OUTPUT_DIM"),
        ) {
            fail(&error);
        }

        let mut cparams = llama::llama_context_default_params();
        cparams.embeddings = true;
        cparams.pooling_type = llama::LLAMA_POOLING_TYPE_MEAN;
        cparams.attention_type = llama::LLAMA_ATTENTION_TYPE_NON_CAUSAL;
        // A short liveness prompt, not the model's full training context. In particular,
        // EmbeddingGemma 2 advertises 262144 tokens in its GGUF; do not allocate that here.
        cparams.n_ctx = 128;
        cparams.n_batch = 128;
        cparams.n_ubatch = 128;
        cparams.n_seq_max = 1;
        let ctx = llama::llama_init_from_model(model, cparams);
        if ctx.is_null() {
            fail("llama_init_from_model returned null");
        }

        // Tokenize a tiny prompt.
        let text = std::env::var("SMOKE_TEXT").unwrap_or_else(|_| "hello from graviton2".into());
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
        // The pooled buffer contains projected output dimensions, not hidden dimensions.
        let slice = std::slice::from_raw_parts(emb, n_embd_out as usize);
        let all_finite = slice.iter().all(|v| v.is_finite());
        let norm: f32 = slice.iter().map(|v| v * v).sum::<f32>().sqrt();
        if !all_finite {
            fail("embedding contains non-finite values");
        }
        if !norm.is_finite() || norm == 0.0 {
            fail("embedding norm is non-finite or zero");
        }

        println!(
            "[smoke] PASS: n_embd={n_embd}, n_embd_out={n_embd_out}, tokens={n}, L2norm={norm:.4}"
        );

        if let Ok(path) = std::env::var("SMOKE_RESULT") {
            let _ = std::fs::write(
                &path,
                format!(
                    "{{\"passed\":true,\"n_embd\":{n_embd},\"n_embd_out\":{n_embd_out},\"n_tokens\":{n},\"l2_norm\":{norm},\"model_id\":{model_id:?},\"model_sha256\":{model_sha:?}}}\n"
                ),
            );
        }

        llama::llama_free(ctx);
        llama::llama_model_free(model);
        llama::llama_backend_free();
    }
}

#[cfg(test)]
mod tests {
    use super::check_dimensions;

    #[test]
    fn projected_output_can_differ_from_hidden_width() {
        check_dimensions(512, 768, Some(512), Some(768)).unwrap();
        check_dimensions(768, 768, None, None).unwrap();
    }

    #[test]
    fn rejects_wrong_projected_width() {
        assert!(check_dimensions(512, 512, Some(512), Some(768)).is_err());
        assert!(check_dimensions(768, 768, Some(512), Some(768)).is_err());
    }

    #[test]
    fn rejects_nonpositive_dimensions() {
        for (hidden, output) in [(0, 768), (512, 0), (-1, 768), (512, -1)] {
            assert!(check_dimensions(hidden, output, None, None).is_err());
        }
    }
}
