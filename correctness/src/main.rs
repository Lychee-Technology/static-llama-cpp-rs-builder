//! Numerical embedding-correctness harness for the prebuilt static archives.
//!
//! Unlike `smoke` (finite/non-zero liveness) this checks the embedding *values*, across
//! the pooling/attention modes and diverse inputs consumers actually use. It links
//! whatever archives `STATIC_LLAMA_DIR` points at and runs one of three modes selected by
//! `$CORRECTNESS_MODE`:
//!
//!   emit       Read $CORRECTNESS_MODEL + the inputs fixture and write, for every input
//!              and for pooling MEAN and LAST (both with NON_CAUSAL attention), the
//!              single-sequence pooled embedding to $CORRECTNESS_EMIT as `label<TAB>csv`.
//!              scripts/correctness.sh runs this against the tuned dist/ and a generic
//!              -march=armv8-a build, then diffs the two files in `compare` mode.
//!
//!   selfcheck  Reference-free invariants on ONE archive set: determinism (same input
//!              twice -> identical bytes), batch-invariance (batched vs per-sequence),
//!              thread-invariance (n_threads=1 vs N), and a coarse semantic-sanity
//!              assertion (paraphrase cosine > unrelated cosine). Catches "the whole
//!              space collapsed/scrambled" even with no external reference. Writes
//!              $CORRECTNESS_RESULT.
//!
//!   compare    Pure (no llama): read two emit files (A, B) and require cosine >=
//!              $CORRECTNESS_THRESHOLD for every shared label. Writes $CORRECTNESS_RESULT.
//!
//! Inputs fixture path: $CORRECTNESS_INPUTS (TSV: `id<TAB>group<TAB>text`, `#` comments).
//! Also prints llama_print_system_info() so compiled-in CPU features sit next to numbers.

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case, dead_code)]

mod llama {
    include!(env!("STATIC_LLAMA_BINDINGS"));
}

use std::ffi::{CStr, CString};
use std::process::exit;

fn fail(msg: &str) -> ! {
    eprintln!("[correctness] FAIL: {msg}");
    if let Ok(path) = std::env::var("CORRECTNESS_RESULT") {
        let _ = std::fs::write(path, format!("{{\"passed\":false,\"error\":{msg:?}}}\n"));
    }
    exit(1);
}

fn env_or_fail(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| fail(&format!("${key} not set")))
}

// ---- fixture parsing --------------------------------------------------------------

// jina-embeddings-v5 retrieval task prefixes (exact strings from the model's
// config_sentence_transformers.json "prompts"). llama.cpp has no prompt concept, so THIS
// (llama.cpp) side prepends the literal prefix per role before tokenizing. The FP32 golden
// side (scripts/gen-golden.py) does NOT prefix by hand — it passes prompt_name=role to
// sentence-transformers, which applies these exact strings. Same effective input, so the
// parity comparison is valid.
const QUERY_PREFIX: &str = "Query: ";
const DOCUMENT_PREFIX: &str = "Document: ";

struct Input {
    id: String,
    role: String, // "query" | "document" (selects the task prefix)
    group: String,
    text: String,
}

impl Input {
    // The exact string fed to the model: task prefix + text.
    fn prefixed(&self) -> String {
        let p = match self.role.as_str() {
            "query" => QUERY_PREFIX,
            "document" => DOCUMENT_PREFIX,
            other => fail(&format!("input {:?}: role must be query|document, got {other:?}", self.id)),
        };
        format!("{p}{}", self.text)
    }
}

fn load_inputs() -> Vec<Input> {
    let path = env_or_fail("CORRECTNESS_INPUTS");
    let body =
        std::fs::read_to_string(&path).unwrap_or_else(|e| fail(&format!("read {path}: {e}")));
    let mut out = Vec::new();
    for line in body.lines() {
        let line = line.trim_end_matches(['\r', '\n']);
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        let mut it = line.splitn(4, '\t');
        match (it.next(), it.next(), it.next(), it.next()) {
            (Some(id), Some(role), Some(group), Some(text))
                if !id.is_empty() && !role.is_empty() && !text.is_empty() =>
            {
                out.push(Input {
                    id: id.to_string(),
                    role: role.to_string(),
                    group: group.to_string(),
                    text: text.to_string(),
                });
            }
            _ => fail(&format!("malformed inputs line (need id<TAB>role<TAB>group<TAB>text): {line:?}")),
        }
    }
    if out.is_empty() {
        fail("inputs fixture has no rows");
    }
    out
}

// ---- math -------------------------------------------------------------------------

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return f32::NAN;
    }
    let mut dot = 0.0f64;
    let mut na = 0.0f64;
    let mut nb = 0.0f64;
    for i in 0..a.len() {
        dot += a[i] as f64 * b[i] as f64;
        na += a[i] as f64 * a[i] as f64;
        nb += b[i] as f64 * b[i] as f64;
    }
    if na == 0.0 || nb == 0.0 {
        return f32::NAN;
    }
    (dot / (na.sqrt() * nb.sqrt())) as f32
}

fn max_abs_diff(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| (x - y).abs()).fold(0.0f32, f32::max)
}

// ---- llama wrapper ----------------------------------------------------------------

struct Engine {
    model: *mut llama::llama_model,
    vocab: *const llama::llama_vocab,
    n_embd: usize,
}

impl Engine {
    unsafe fn load(model_path: &str) -> Engine {
        let c_model = CString::new(model_path).unwrap();
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
        Engine { model, vocab, n_embd: n_embd as usize }
    }

    unsafe fn tokenize(&self, text: &str) -> Vec<i32> {
        let mut toks = vec![0i32; text.len() + 16];
        let n = llama::llama_tokenize(
            self.vocab,
            text.as_ptr() as *const _,
            text.len() as i32,
            toks.as_mut_ptr(),
            toks.len() as i32,
            true,  // add_special
            false, // parse_special
        );
        if n <= 0 {
            fail(&format!("tokenization produced no tokens for {text:?}"));
        }
        toks.truncate(n as usize);
        toks
    }

    // A context configured for embeddings with the given pooling/attention/threads.
    unsafe fn context(
        &self,
        pooling: llama::llama_pooling_type,
        attention: llama::llama_attention_type,
        n_threads: i32,
    ) -> *mut llama::llama_context {
        let mut cparams = llama::llama_context_default_params();
        cparams.embeddings = true;
        cparams.pooling_type = pooling;
        cparams.attention_type = attention;
        cparams.n_threads = n_threads;
        cparams.n_threads_batch = n_threads;
        cparams.n_ctx = 2048;
        cparams.n_batch = 2048;
        cparams.n_ubatch = 2048;
        cparams.n_seq_max = 64;
        let ctx = llama::llama_init_from_model(self.model, cparams);
        if ctx.is_null() {
            fail("llama_init_from_model returned null");
        }
        ctx
    }

    // Single-sequence pooled embedding (matches the smoke path: llama_batch_get_one).
    unsafe fn embed_single(&self, ctx: *mut llama::llama_context, text: &str) -> Vec<f32> {
        let mut toks = self.tokenize(text);
        let n = toks.len() as i32;
        let batch = llama::llama_batch_get_one(toks.as_mut_ptr(), n);
        if llama::llama_encode(ctx, batch) != 0 {
            fail(&format!("llama_encode failed for {text:?}"));
        }
        self.read_seq(ctx, 0)
    }

    // Batched pooled embeddings: all texts in ONE llama_batch, one llama_encode, then
    // read each sequence's pooled vector. Mirrors llama.cpp's embedding example.
    unsafe fn embed_batch(&self, ctx: *mut llama::llama_context, texts: &[&str]) -> Vec<Vec<f32>> {
        let toks: Vec<Vec<i32>> = texts.iter().map(|t| self.tokenize(t)).collect();
        let total: usize = toks.iter().map(|t| t.len()).sum();
        let mut batch = llama::llama_batch_init(total as i32, 0, texts.len() as i32);
        let mut i = 0usize;
        for (seq, seq_toks) in toks.iter().enumerate() {
            for (pos, &tok) in seq_toks.iter().enumerate() {
                *batch.token.add(i) = tok;
                *batch.pos.add(i) = pos as i32;
                *batch.n_seq_id.add(i) = 1;
                *(*batch.seq_id.add(i)).add(0) = seq as i32;
                *batch.logits.add(i) = 1; // request output (pooling reads flagged tokens)
                i += 1;
            }
        }
        batch.n_tokens = total as i32;
        if llama::llama_encode(ctx, batch) != 0 {
            llama::llama_batch_free(batch);
            fail("llama_encode failed for batched input");
        }
        let out = (0..texts.len()).map(|s| self.read_seq(ctx, s as i32)).collect();
        llama::llama_batch_free(batch);
        out
    }

    unsafe fn read_seq(&self, ctx: *mut llama::llama_context, seq: i32) -> Vec<f32> {
        let emb = llama::llama_get_embeddings_seq(ctx, seq);
        if emb.is_null() {
            fail(&format!("llama_get_embeddings_seq returned null (seq {seq})"));
        }
        let slice = std::slice::from_raw_parts(emb, self.n_embd);
        if !slice.iter().all(|v| v.is_finite()) {
            fail(&format!("embedding for seq {seq} contains non-finite values"));
        }
        slice.to_vec()
    }

    unsafe fn free(self) {
        llama::llama_model_free(self.model);
    }
}

// Cosine between the first two members of the first input group whose group name starts
// with `prefix` (e.g. "para" -> a paraphrase pair, "unrel" -> an unrelated pair).
unsafe fn group_pair_cosine(
    eng: &Engine,
    ctx: *mut llama::llama_context,
    inputs: &[Input],
    prefix: &str,
) -> f32 {
    let members: Vec<&Input> = inputs.iter().filter(|i| i.group.starts_with(prefix)).collect();
    if members.len() < 2 {
        fail(&format!("need >=2 inputs in a '{prefix}*' group for semantic sanity"));
    }
    let a = eng.embed_single(ctx, &members[0].prefixed());
    let b = eng.embed_single(ctx, &members[1].prefixed());
    cosine(&a, &b)
}

unsafe fn print_sysinfo() {
    let s = llama::llama_print_system_info();
    if !s.is_null() {
        println!("[correctness] system info: {}", CStr::from_ptr(s).to_string_lossy());
    }
}

// pooling modes exercised for emit/compare: (label, pooling_type)
const POOLINGS: &[(&str, i32)] = &[
    ("mean", llama::LLAMA_POOLING_TYPE_MEAN),
    ("last", llama::LLAMA_POOLING_TYPE_LAST),
];

// ---- emit -------------------------------------------------------------------------

fn mode_emit() {
    let model = env_or_fail("CORRECTNESS_MODEL");
    let out_path = env_or_fail("CORRECTNESS_EMIT");
    let inputs = load_inputs();
    let n_inputs = inputs.len();
    let mut out = String::new();
    unsafe {
        llama::llama_backend_init();
        print_sysinfo();
        let eng = Engine::load(&model);
        for &(pname, pool) in POOLINGS {
            let ctx = eng.context(pool, llama::LLAMA_ATTENTION_TYPE_NON_CAUSAL, 0);
            for inp in &inputs {
                let v = eng.embed_single(ctx, &inp.prefixed());
                out.push_str(&format!("{}|{}\t", inp.id, pname));
                for (k, x) in v.iter().enumerate() {
                    if k > 0 {
                        out.push(',');
                    }
                    out.push_str(&x.to_string());
                }
                out.push('\n');
            }
            llama::llama_free(ctx);
        }
        eng.free();
        llama::llama_backend_free();
    }
    std::fs::write(&out_path, out).unwrap_or_else(|e| fail(&format!("write {out_path}: {e}")));
    eprintln!("[correctness] emit wrote {out_path} ({n_inputs} inputs x {} poolings)", POOLINGS.len());
}

// ---- selfcheck --------------------------------------------------------------------

fn mode_selfcheck() {
    let model = env_or_fail("CORRECTNESS_MODEL");
    let inputs = load_inputs();
    // Thresholds. Determinism is exact; the invariances allow FP reduction-order slack.
    let inv_cos_min = 0.9999f32; // batch / thread invariance
    let inv_diff_max = 1e-3f32;
    let sem_margin = 0.05f32; // paraphrase must beat unrelated by this
    let sem_para_min = 0.5f32;

    unsafe {
        llama::llama_backend_init();
        print_sysinfo();
        let eng = Engine::load(&model);

        // All invariants run on the deployment path: LAST pooling + NON_CAUSAL (EuroBERT
        // encoder), with the jina task prefix prepended to every input.
        let texts: Vec<String> = inputs.iter().map(|i| i.prefixed()).collect();
        let text_refs: Vec<&str> = texts.iter().map(|s| s.as_str()).collect();

        // --- determinism: same input encoded twice -> identical bytes ---------------
        let ctx = eng.context(
            llama::LLAMA_POOLING_TYPE_LAST,
            llama::LLAMA_ATTENTION_TYPE_NON_CAUSAL,
            0,
        );
        let d1 = eng.embed_single(ctx, text_refs[0]);
        let d2 = eng.embed_single(ctx, text_refs[0]);
        let determinism = d1 == d2; // exact bitwise equality

        // --- batch-invariance: batched vs per-sequence ------------------------------
        let batched = eng.embed_batch(ctx, &text_refs);
        let mut batch_cos_min = 1.0f32;
        let mut batch_diff_max = 0.0f32;
        for (k, t) in text_refs.iter().enumerate() {
            let single = eng.embed_single(ctx, t);
            batch_cos_min = batch_cos_min.min(cosine(&single, &batched[k]));
            batch_diff_max = batch_diff_max.max(max_abs_diff(&single, &batched[k]));
        }
        llama::llama_free(ctx);

        // --- thread-invariance: n_threads=1 vs N ------------------------------------
        let nproc = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2) as i32;
        let ctx1 = eng.context(llama::LLAMA_POOLING_TYPE_LAST, llama::LLAMA_ATTENTION_TYPE_NON_CAUSAL, 1);
        let ctxn = eng.context(llama::LLAMA_POOLING_TYPE_LAST, llama::LLAMA_ATTENTION_TYPE_NON_CAUSAL, nproc.max(1));
        let mut thread_cos_min = 1.0f32;
        let mut thread_diff_max = 0.0f32;
        for t in &text_refs {
            let a = eng.embed_single(ctx1, t);
            let b = eng.embed_single(ctxn, t);
            thread_cos_min = thread_cos_min.min(cosine(&a, &b));
            thread_diff_max = thread_diff_max.max(max_abs_diff(&a, &b));
        }
        llama::llama_free(ctx1);
        llama::llama_free(ctxn);

        // --- semantic sanity: paraphrase cosine > unrelated cosine ------------------
        // groups whose id starts "para" are positive pairs; "unrel" are negative pairs.
        let ctx = eng.context(llama::LLAMA_POOLING_TYPE_LAST, llama::LLAMA_ATTENTION_TYPE_NON_CAUSAL, 0);
        let para_cos = group_pair_cosine(&eng, ctx, &inputs, "para");
        let unrel_cos = group_pair_cosine(&eng, ctx, &inputs, "unrel");
        llama::llama_free(ctx);
        let semantic = para_cos >= sem_para_min && para_cos > unrel_cos + sem_margin;

        eng.free();
        llama::llama_backend_free();

        let batch_ok = batch_cos_min >= inv_cos_min && batch_diff_max <= inv_diff_max;
        let thread_ok = thread_cos_min >= inv_cos_min && thread_diff_max <= inv_diff_max;
        let passed = determinism && batch_ok && thread_ok && semantic;

        let result = env_or_fail("CORRECTNESS_RESULT");
        let json = format!(
            "{{\"passed\":{passed},\"determinism\":{determinism},\
\"batch_invariance\":{{\"passed\":{batch_ok},\"min_cosine\":{batch_cos_min},\"max_abs_diff\":{batch_diff_max}}},\
\"thread_invariance\":{{\"passed\":{thread_ok},\"n_threads\":{nproc},\"min_cosine\":{thread_cos_min},\"max_abs_diff\":{thread_diff_max}}},\
\"semantic_sanity\":{{\"passed\":{semantic},\"paraphrase_cosine\":{para_cos},\"unrelated_cosine\":{unrel_cos}}}}}\n"
        );
        std::fs::write(&result, json).unwrap_or_else(|e| fail(&format!("write {result}: {e}")));
        println!(
            "[correctness] selfcheck: determinism={determinism} batch(min_cos={batch_cos_min:.5}) \
thread(min_cos={thread_cos_min:.5}) semantic(para={para_cos:.4} unrel={unrel_cos:.4}) -> passed={passed}"
        );
        if !passed {
            exit(1);
        }
    }
}

// ---- compare ----------------------------------------------------------------------

fn read_emit(path: &str) -> Vec<(String, Vec<f32>)> {
    let body =
        std::fs::read_to_string(path).unwrap_or_else(|e| fail(&format!("read {path}: {e}")));
    let mut out = Vec::new();
    for line in body.lines() {
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        let mut it = line.splitn(2, '\t');
        let label = it.next().unwrap_or("").to_string();
        let csv = it.next().unwrap_or("");
        if label.is_empty() || csv.is_empty() {
            fail(&format!("malformed emit line in {path}: {line:?}"));
        }
        let v: Vec<f32> = csv
            .split(',')
            .map(|s| s.trim().parse::<f32>().unwrap_or_else(|_| fail(&format!("bad float in {path}: {s:?}"))))
            .collect();
        out.push((label, v));
    }
    out
}

fn mode_compare() {
    let a_path = env_or_fail("CORRECTNESS_A");
    let b_path = env_or_fail("CORRECTNESS_B");
    let result = env_or_fail("CORRECTNESS_RESULT");
    let threshold: f32 = env_or_fail("CORRECTNESS_THRESHOLD")
        .parse()
        .unwrap_or_else(|_| fail("CORRECTNESS_THRESHOLD not a float"));

    let a = read_emit(&a_path);
    let b: std::collections::HashMap<String, Vec<f32>> = read_emit(&b_path).into_iter().collect();

    let mut min_cosine = 1.0f32;
    let mut worst_label = String::new();
    let mut n = 0usize;
    let mut per_label = String::new();
    for (label, va) in &a {
        let Some(vb) = b.get(label) else { continue };
        let c = cosine(va, vb);
        if c.is_nan() {
            fail(&format!("cosine NaN for label {label:?} (len {} vs {})", va.len(), vb.len()));
        }
        if !per_label.is_empty() {
            per_label.push(',');
        }
        per_label.push_str(&format!("{{\"label\":{label:?},\"cosine\":{c}}}"));
        if c < min_cosine {
            min_cosine = c;
            worst_label = label.clone();
        }
        n += 1;
    }
    if n == 0 {
        fail(&format!("no shared labels between {a_path} and {b_path}"));
    }
    let passed = min_cosine >= threshold;
    let json = format!(
        "{{\"passed\":{passed},\"threshold\":{threshold},\"pairs\":{n},\
\"min_cosine\":{min_cosine},\"worst_label\":{worst_label:?},\"per_label\":[{per_label}]}}\n"
    );
    std::fs::write(&result, json).unwrap_or_else(|e| fail(&format!("write {result}: {e}")));
    println!(
        "[correctness] compare {a_path} vs {b_path}: {n} pairs, min_cosine={min_cosine:.5} \
(worst {worst_label:?}) threshold={threshold} -> passed={passed}"
    );
    if !passed {
        exit(1);
    }
}

fn main() {
    match env_or_fail("CORRECTNESS_MODE").as_str() {
        "emit" => mode_emit(),
        "selfcheck" => mode_selfcheck(),
        "compare" => mode_compare(),
        other => fail(&format!("unknown $CORRECTNESS_MODE {other:?} (emit|selfcheck|compare)")),
    }
}
