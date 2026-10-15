//! Smoke test: link the prebuilt static archives and run a real init + inference path.
//!
//! SMOKE_MODE=pooled (the default): backend init -> load a GGUF embedding model -> create
//! an embeddings context (mean pooling) -> tokenize -> llama_encode -> assert the context
//! exposes no host logits (contract v6) -> read the pooled embedding and assert it is
//! non-empty, finite, and non-zero.
//!
//! SMOKE_MODE=logits: run a generative control model (one with an LM head) through each
//! output mode in LOGITS_MODES and assert where host logits exist, so archives that
//! dropped generation logits along with the pooled-embedding buffer cannot pass.
//!
//! Both modes print llama_print_system_info() so CI logs show the CPU features actually
//! compiled in (expect dotprod for N1). Model path comes from $SMOKE_MODEL. Result JSON is
//! written to $SMOKE_RESULT.

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

// SMOKE_MODEL_ID labels the model only when a caller pins one (embeddinggemma-smoke.sh
// passes the config.env pin). The legacy smoke model is identified by its SHA-256 alone,
// so an unset id is omitted from the result rather than recorded as an empty string.
fn parse_model_id(value: Result<String, std::env::VarError>) -> Result<Option<String>, String> {
    match value {
        Err(std::env::VarError::NotPresent) => Ok(None),
        Ok(id)
            if !id.is_empty()
                && id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"/._-".contains(&byte)) =>
        {
            Ok(Some(id))
        }
        _ => Err("SMOKE_MODEL_ID, when set, must be non-empty [A-Za-z0-9/._-]".into()),
    }
}

fn model_id_json(model_id: Option<&str>) -> String {
    model_id
        .map(|id| format!(",\"model_id\":{id:?}"))
        .unwrap_or_default()
}

// The results are merged verbatim into build-info.json; see CONTRACT.md before changing them.
// A pooled result only exists when llama_get_logits returned NULL, so host_logits is false.
fn result_json(
    n_embd: i32,
    n_embd_out: i32,
    n_tokens: i32,
    l2_norm: f32,
    model_id: Option<&str>,
    model_sha256: &str,
) -> String {
    let model_id = model_id_json(model_id);
    format!(
        "{{\"passed\":true,\"n_embd\":{n_embd},\"n_embd_out\":{n_embd_out},\"n_tokens\":{n_tokens},\"l2_norm\":{l2_norm},\"host_logits\":false{model_id},\"model_sha256\":{model_sha256:?}}}\n"
    )
}

// The output modes SMOKE_MODE=logits runs, in order, and whether llama_get_logits must
// return host logits in each (CONTRACT.md "Output semantics"; scripts/lib.sh
// assert_release_results checks the recorded map). The two set_* modes toggle
// llama_set_embeddings on the mean-pooled context: off must bring the LM head back. LAST
// (the legacy model's deployment pooling) and CLS must drop host logits like MEAN.
const LOGITS_MODES: [(&str, bool); 7] = [
    ("generation", true),
    ("embeddings_none", true),
    ("embeddings_mean", false),
    ("embeddings_mean_set_off", true),
    ("embeddings_mean_set_on", false),
    ("embeddings_last", false),
    ("embeddings_cls", false),
];

// LOGITS_MODES as the JSON object recorded under host_logits.
fn host_logits_json() -> String {
    let modes = LOGITS_MODES
        .iter()
        .map(|(mode, has_logits)| format!("{mode:?}:{has_logits}"))
        .collect::<Vec<_>>()
        .join(",");
    format!("{{{modes}}}")
}

fn logits_result_json(
    n_vocab: i32,
    n_tokens: i32,
    max_logit_delta: f32,
    model_id: Option<&str>,
    model_sha256: &str,
) -> String {
    let host_logits = host_logits_json();
    let model_id = model_id_json(model_id);
    format!(
        "{{\"passed\":true,\"n_vocab\":{n_vocab},\"n_tokens\":{n_tokens},\"host_logits\":{host_logits},\"max_logit_delta\":{max_logit_delta}{model_id},\"model_sha256\":{model_sha256:?}}}\n"
    )
}

// Largest element-wise difference between two logits rows of the same prompt. A NaN
// difference propagates (f32::max would drop it), and rows of different lengths are
// infinitely apart, so neither can pass the MAX_LOGIT_DELTA comparison.
fn max_abs_delta(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return f32::INFINITY;
    }
    let mut max = 0.0f32;
    for (x, y) in a.iter().zip(b) {
        let delta = (x - y).abs();
        if delta.is_nan() {
            return f32::NAN;
        }
        max = max.max(delta);
    }
    max
}

// The logits of the last prompt token may differ between modes only by floating-point
// reassociation (a different number of output rows), never by a different computation.
const MAX_LOGIT_DELTA: f32 = 1e-3;

fn check_logits(mode: &str, logits: &[f32]) -> Result<(), String> {
    if !logits.iter().all(|v| v.is_finite()) {
        return Err(format!("{mode}: logits contain non-finite values"));
    }
    let (min, max) = logits
        .iter()
        .fold((f32::INFINITY, f32::NEG_INFINITY), |(lo, hi), &v| {
            (lo.min(v), hi.max(v))
        });
    if logits.is_empty() || max <= min {
        return Err(format!("{mode}: logits are empty or constant"));
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

#[derive(Clone, Copy, Debug, PartialEq)]
enum Mode {
    Pooled,
    Logits,
}

fn parse_mode(value: Result<String, std::env::VarError>) -> Result<Mode, String> {
    match value.as_deref() {
        Err(std::env::VarError::NotPresent) | Ok("pooled") => Ok(Mode::Pooled),
        Ok("logits") => Ok(Mode::Logits),
        _ => Err("SMOKE_MODE, when set, must be pooled or logits".into()),
    }
}

fn tokenize(vocab: *const llama::llama_vocab, text: &str) -> Vec<i32> {
    let mut toks = vec![0i32; 64];
    let n = unsafe {
        llama::llama_tokenize(
            vocab,
            text.as_ptr() as *const _,
            text.len() as i32,
            toks.as_mut_ptr(),
            toks.len() as i32,
            true,  // add_special
            false, // parse_special
        )
    };
    if n <= 0 {
        fail("tokenization produced no tokens");
    }
    toks.truncate(n as usize);
    toks
}

fn new_context(
    model: *mut llama::llama_model,
    embeddings: bool,
    pooling: llama::llama_pooling_type,
) -> *mut llama::llama_context {
    unsafe {
        let mut cparams = llama::llama_context_default_params();
        cparams.embeddings = embeddings;
        cparams.pooling_type = pooling;
        cparams.n_ctx = 128;
        cparams.n_batch = 128;
        cparams.n_ubatch = 128;
        cparams.n_seq_max = 1;
        let ctx = llama::llama_init_from_model(model, cparams);
        if ctx.is_null() {
            fail("llama_init_from_model returned null");
        }
        ctx
    }
}

// Decode the whole prompt as sequence 0 of an empty context, then report whether the context
// exposes host logits. When it does, the last token's row must be n_vocab finite,
// non-constant values; it is returned for the cross-mode comparison.
fn decode_mode(
    ctx: *mut llama::llama_context,
    mode: &str,
    expect_logits: bool,
    toks: &mut [i32],
    n_vocab: i32,
) -> Option<Vec<f32>> {
    unsafe {
        llama::llama_memory_clear(llama::llama_get_memory(ctx), true);
        let batch = llama::llama_batch_get_one(toks.as_mut_ptr(), toks.len() as i32);
        if llama::llama_decode(ctx, batch) != 0 {
            fail(&format!("{mode}: llama_decode failed"));
        }
        let has_logits = !llama::llama_get_logits(ctx).is_null();
        if has_logits != expect_logits {
            fail(&format!(
                "{mode}: llama_get_logits {}, expected {}",
                if has_logits {
                    "returned host logits"
                } else {
                    "returned NULL"
                },
                if expect_logits { "host logits" } else { "NULL" },
            ));
        }
        if !has_logits {
            return None;
        }
        let row = llama::llama_get_logits_ith(ctx, -1);
        if row.is_null() {
            fail(&format!("{mode}: llama_get_logits_ith(-1) returned null"));
        }
        let logits = std::slice::from_raw_parts(row, n_vocab as usize).to_vec();
        check_logits(mode, &logits).unwrap_or_else(|e| fail(&e));
        Some(logits)
    }
}

// The finite, nonzero embedding row `emb` of `width` floats, or a failure naming `what`.
fn read_embedding(emb: *const f32, width: i32, what: &str) -> Vec<f32> {
    if emb.is_null() {
        fail(&format!("{what} returned null"));
    }
    let row = unsafe { std::slice::from_raw_parts(emb, width as usize) }.to_vec();
    let norm = row.iter().map(|v| v * v).sum::<f32>().sqrt();
    if !row.iter().all(|v| v.is_finite()) || !norm.is_finite() || norm == 0.0 {
        fail(&format!("{what}: embedding is non-finite or zero"));
    }
    row
}

// SMOKE_MODE=logits: the modes of LOGITS_MODES on one generative model, with the logits of
// every mode that has them compared against plain generation. Returns the result JSON.
fn logits_smoke(
    model: *mut llama::llama_model,
    model_id: Option<&str>,
    model_sha256: &str,
) -> String {
    let [generation, embeddings_none, embeddings_mean, set_off, set_on, embeddings_last, embeddings_cls] =
        LOGITS_MODES;
    unsafe {
        let vocab = llama::llama_model_get_vocab(model);
        let n_vocab = llama::llama_vocab_n_tokens(vocab);
        let n_embd_out = llama::llama_model_n_embd_out(model);
        if n_vocab <= 0 || n_embd_out <= 0 {
            fail(&format!(
                "invalid control model: n_vocab={n_vocab}, n_embd_out={n_embd_out}"
            ));
        }
        let text =
            std::env::var("SMOKE_TEXT").unwrap_or_else(|_| "One day, Lily met a Shoggoth".into());
        let mut toks = tokenize(vocab, &text);
        let mut max_delta = 0.0f32;
        let mut compare = |mode: &str, logits: &[f32], reference: &[f32]| {
            let delta = max_abs_delta(logits, reference);
            if !(delta <= MAX_LOGIT_DELTA) {
                fail(&format!(
                    "{mode}: last-token logits differ from {} by {delta} (> {MAX_LOGIT_DELTA})",
                    generation.0
                ));
            }
            max_delta = max_delta.max(delta);
        };

        // Plain generation: no embeddings, so the LM head is built and logits are reserved.
        let ctx = new_context(model, false, llama::LLAMA_POOLING_TYPE_NONE);
        let reference = decode_mode(ctx, generation.0, generation.1, &mut toks, n_vocab)
            .unwrap_or_else(|| fail("generation produced no logits"));
        llama::llama_free(ctx);

        // Per-token embeddings come together with logits (pooling NONE keeps the LM head).
        let ctx = new_context(model, true, llama::LLAMA_POOLING_TYPE_NONE);
        let logits = decode_mode(
            ctx,
            embeddings_none.0,
            embeddings_none.1,
            &mut toks,
            n_vocab,
        )
        .unwrap_or_else(|| fail("pooling NONE produced no logits"));
        compare(embeddings_none.0, &logits, &reference);
        read_embedding(
            llama::llama_get_embeddings_ith(ctx, -1),
            n_embd_out,
            "llama_get_embeddings_ith(-1) with pooling NONE",
        );
        llama::llama_free(ctx);

        // A mean-pooled embeddings context skips the LM head and reserves no host logits.
        let ctx = new_context(model, true, llama::LLAMA_POOLING_TYPE_MEAN);
        decode_mode(
            ctx,
            embeddings_mean.0,
            embeddings_mean.1,
            &mut toks,
            n_vocab,
        );
        let pooled = read_embedding(
            llama::llama_get_embeddings_seq(ctx, 0),
            n_embd_out,
            "llama_get_embeddings_seq(0) with mean pooling",
        );
        // Turning embeddings off on the pooled context must rebuild the LM head ...
        llama::llama_set_embeddings(ctx, false);
        let logits = decode_mode(ctx, set_off.0, set_off.1, &mut toks, n_vocab)
            .unwrap_or_else(|| fail("generation on the pooled context produced no logits"));
        compare(set_off.0, &logits, &reference);
        // ... and turning them back on must drop it again, with the same pooled output.
        llama::llama_set_embeddings(ctx, true);
        decode_mode(ctx, set_on.0, set_on.1, &mut toks, n_vocab);
        let repooled = read_embedding(
            llama::llama_get_embeddings_seq(ctx, 0),
            n_embd_out,
            "llama_get_embeddings_seq(0) after re-enabling embeddings",
        );
        if repooled != pooled {
            fail("re-enabling embeddings changed the mean-pooled embedding");
        }
        llama::llama_free(ctx);

        // The other sequence poolings follow the same rule.
        for ((mode, has_logits), pooling) in [
            (embeddings_last, llama::LLAMA_POOLING_TYPE_LAST),
            (embeddings_cls, llama::LLAMA_POOLING_TYPE_CLS),
        ] {
            let ctx = new_context(model, true, pooling);
            decode_mode(ctx, mode, has_logits, &mut toks, n_vocab);
            read_embedding(
                llama::llama_get_embeddings_seq(ctx, 0),
                n_embd_out,
                &format!("llama_get_embeddings_seq(0) for {mode}"),
            );
            llama::llama_free(ctx);
        }

        println!(
            "[smoke] PASS (logits): n_vocab={n_vocab}, tokens={}, max_logit_delta={max_delta:e}",
            toks.len()
        );
        logits_result_json(
            n_vocab,
            toks.len() as i32,
            max_delta,
            model_id,
            model_sha256,
        )
    }
}

fn main() {
    let model_path = std::env::var("SMOKE_MODEL")
        .unwrap_or_else(|_| fail("$SMOKE_MODEL not set (path to a tiny GGUF embedding model)"));
    let c_model = CString::new(model_path.clone()).unwrap();
    let mode = parse_mode(std::env::var("SMOKE_MODE")).unwrap_or_else(|e| fail(&e));
    let model_id = parse_model_id(std::env::var("SMOKE_MODEL_ID")).unwrap_or_else(|e| fail(&e));
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

        if mode == Mode::Logits {
            let result = logits_smoke(model, model_id.as_deref(), model_sha);
            if let Ok(path) = std::env::var("SMOKE_RESULT") {
                let _ = std::fs::write(&path, result);
            }
            llama::llama_model_free(model);
            llama::llama_backend_free();
            return;
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
        let mut toks = tokenize(vocab, &text);
        let n = toks.len() as i32;

        // Encode for embeddings (encoder path; mean-pooled per sequence).
        let batch = llama::llama_batch_get_one(toks.as_mut_ptr(), n);
        if llama::llama_encode(ctx, batch) != 0 {
            fail("llama_encode failed");
        }

        // Contract v6: a pooled context reserves no n_vocab floats per token for logits it
        // never computes (llama.cpp b11577 did: 1 MiB per token for EmbeddingGemma 2).
        if !llama::llama_get_logits(ctx).is_null() {
            fail("llama_get_logits returned host logits for a mean-pooled embeddings context");
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
                result_json(n_embd, n_embd_out, n, norm, model_id.as_deref(), model_sha),
            );
        }

        llama::llama_free(ctx);
        llama::llama_model_free(model);
        llama::llama_backend_free();
    }
}

#[cfg(test)]
mod tests {
    use super::{
        check_dimensions, check_logits, host_logits_json, logits_result_json, max_abs_delta,
        parse_mode, parse_model_id, result_json, Mode, LOGITS_MODES, MAX_LOGIT_DELTA,
    };
    use std::env::VarError;

    const SHA: &str = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135";

    #[test]
    fn unset_model_id_is_omitted_not_empty() {
        assert_eq!(parse_model_id(Err(VarError::NotPresent)), Ok(None));
        assert_eq!(
            result_json(768, 768, 6, 1.5, None, SHA),
            format!("{{\"passed\":true,\"n_embd\":768,\"n_embd_out\":768,\"n_tokens\":6,\"l2_norm\":1.5,\"host_logits\":false,\"model_sha256\":\"{SHA}\"}}\n")
        );
    }

    #[test]
    fn pinned_model_id_is_recorded() {
        let id = parse_model_id(Ok("google/embeddinggemma-2".into())).unwrap();
        assert_eq!(id.as_deref(), Some("google/embeddinggemma-2"));
        assert_eq!(
            result_json(512, 768, 15, 1.5, id.as_deref(), SHA),
            format!("{{\"passed\":true,\"n_embd\":512,\"n_embd_out\":768,\"n_tokens\":15,\"l2_norm\":1.5,\"host_logits\":false,\"model_id\":\"google/embeddinggemma-2\",\"model_sha256\":\"{SHA}\"}}\n")
        );
    }

    #[test]
    fn rejects_empty_or_unsafe_model_id() {
        for id in ["", "bad\"id", "has space", "back\\slash"] {
            assert!(parse_model_id(Ok(id.into())).is_err(), "{id:?}");
        }
        let not_unicode = VarError::NotUnicode(std::ffi::OsString::from("x"));
        assert!(parse_model_id(Err(not_unicode)).is_err());
    }

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

    #[test]
    fn mode_defaults_to_pooled() {
        assert_eq!(parse_mode(Err(VarError::NotPresent)), Ok(Mode::Pooled));
        assert_eq!(parse_mode(Ok("pooled".into())), Ok(Mode::Pooled));
        assert_eq!(parse_mode(Ok("logits".into())), Ok(Mode::Logits));
    }

    #[test]
    fn rejects_unknown_mode() {
        for mode in ["", "Logits", "generation", "pooled "] {
            assert!(parse_mode(Ok(mode.into())).is_err(), "{mode:?}");
        }
        let not_unicode = VarError::NotUnicode(std::ffi::OsString::from("x"));
        assert!(parse_mode(Err(not_unicode)).is_err());
    }

    // Plain generation is the reference every other logits mode is compared against, and
    // the mean-pooled modes are the ones that must not reserve host logits.
    #[test]
    fn logits_modes_start_with_generation() {
        assert_eq!(LOGITS_MODES[0], ("generation", true));
        let without: Vec<_> = LOGITS_MODES.iter().filter(|(_, has)| !has).collect();
        assert_eq!(
            without,
            [
                &("embeddings_mean", false),
                &("embeddings_mean_set_on", false),
                &("embeddings_last", false),
                &("embeddings_cls", false)
            ]
        );
    }

    // The release gate checks the recorded map against its own pin; keep the two in step.
    #[test]
    fn host_logits_match_release_pin() {
        let pin = format!("LOGITS_SMOKE_HOST_LOGITS='{}'", host_logits_json());
        let lib = include_str!("../../scripts/lib.sh");
        assert!(lib.lines().any(|line| line == pin), "{pin} not in lib.sh");
    }

    #[test]
    fn logits_result_records_modes() {
        assert_eq!(
            logits_result_json(512, 15, 2.5e-6, Some("karpathy/tinyllamas/stories260K"), SHA),
            format!("{{\"passed\":true,\"n_vocab\":512,\"n_tokens\":15,\"host_logits\":{{\"generation\":true,\"embeddings_none\":true,\"embeddings_mean\":false,\"embeddings_mean_set_off\":true,\"embeddings_mean_set_on\":false,\"embeddings_last\":false,\"embeddings_cls\":false}},\"max_logit_delta\":0.0000025,\"model_id\":\"karpathy/tinyllamas/stories260K\",\"model_sha256\":\"{SHA}\"}}\n")
        );
    }

    #[test]
    fn logit_delta_is_largest_difference() {
        assert_eq!(max_abs_delta(&[1.0, 2.0, 3.0], &[1.0, 2.5, 2.0]), 1.0);
        assert_eq!(max_abs_delta(&[1.0, -2.0], &[1.0, -2.0]), 0.0);
    }

    #[test]
    fn logit_delta_fails_closed() {
        for (a, b) in [
            (&[f32::NAN, 1.0][..], &[0.0, 1.0][..]),
            (&[0.0, 1.0][..], &[0.0, f32::NAN][..]),
            (&[1.0, 2.0][..], &[1.0][..]),
            (&[0.0, f32::INFINITY][..], &[0.0, 1.0][..]),
        ] {
            let delta = max_abs_delta(a, b);
            assert!(!(delta <= MAX_LOGIT_DELTA), "{a:?} vs {b:?}: {delta}");
        }
    }

    #[test]
    fn accepts_varied_finite_logits() {
        check_logits("generation", &[-1.0, 0.5, 3.0]).unwrap();
    }

    #[test]
    fn rejects_degenerate_logits() {
        for logits in [
            &[][..],
            &[0.0, 0.0, 0.0][..],
            &[0.0, f32::NAN, 1.0][..],
            &[0.0, f32::INFINITY, 1.0][..],
        ] {
            assert!(check_logits("generation", logits).is_err(), "{logits:?}");
        }
    }
}
