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
//!   compare    Pure (no llama): read two emit files A (packaged-archive emit) and B (the
//!              reference: generic emit or the golden). First require B's label set to
//!              EQUAL `<id>|<pooling>` over every row of the inputs fixture x every pooling
//!              in $CORRECTNESS_REF_POOLINGS (comma-separated, e.g. `last` for the golden,
//!              `mean,last` for a generic emit) — fail-closed in both directions, naming
//!              the labels, so an inputs.tsv row added, removed or renamed without
//!              regenerating the golden can never pass by being silently skipped, and a
//!              B with no data rows at all (truncated, emptied or comment-only) fails the
//!              same way. Then require cosine >= $CORRECTNESS_THRESHOLD for every B label,
//!              and FAIL if any B label is missing from A. Writes $CORRECTNESS_RESULT.
//!
//! Inputs fixture path: $CORRECTNESS_INPUTS (TSV: `id<TAB>role<TAB>group<TAB>text`, `#` comments).
//! Also prints llama_print_system_info() so compiled-in CPU features sit next to numbers.

#![allow(
    non_upper_case_globals,
    non_camel_case_types,
    non_snake_case,
    dead_code
)]

mod llama {
    include!(env!("STATIC_LLAMA_BINDINGS"));
}

use std::collections::{BTreeSet, HashMap};
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

#[derive(Debug)]
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
            other => fail(&format!(
                "input {:?}: role must be query|document, got {other:?}",
                self.id
            )),
        };
        format!("{p}{}", self.text)
    }
}

// Emit/golden label for one input under one pooling. The single definition of the label
// format on the llama.cpp side; scripts/gen-golden.py writes the same `<id>|last`.
fn label(id: &str, pooling: &str) -> String {
    format!("{id}|{pooling}")
}

fn parse_inputs(body: &str) -> Result<Vec<Input>, String> {
    let mut out: Vec<Input> = Vec::new();
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
                // The id is the label key (`<id>|<pooling>`): a duplicate would let one
                // row's vector shadow another's in `compare`, and a '|' would make the
                // label ambiguous. Both are fixture errors, never silently accepted.
                if id.contains('|') {
                    return Err(format!("input id {id:?} must not contain '|'"));
                }
                if out.iter().any(|i| i.id == id) {
                    return Err(format!("duplicate input id {id:?}"));
                }
                out.push(Input {
                    id: id.to_string(),
                    role: role.to_string(),
                    group: group.to_string(),
                    text: text.to_string(),
                });
            }
            _ => {
                return Err(format!(
                    "malformed inputs line (need id<TAB>role<TAB>group<TAB>text): {line:?}"
                ))
            }
        }
    }
    if out.is_empty() {
        return Err("inputs fixture has no rows".to_string());
    }
    Ok(out)
}

fn load_inputs_at(path: &str) -> Vec<Input> {
    let body = std::fs::read_to_string(path).unwrap_or_else(|e| fail(&format!("read {path}: {e}")));
    parse_inputs(&body).unwrap_or_else(|e| fail(&format!("{path}: {e}")))
}

fn load_inputs() -> Vec<Input> {
    load_inputs_at(&env_or_fail("CORRECTNESS_INPUTS"))
}

// $CORRECTNESS_REF_POOLINGS: the poolings a compare reference must cover, comma-separated,
// each a POOLINGS name (an unknown name or an empty list is an error, never "no check").
fn parse_ref_poolings(spec: &str) -> Result<Vec<&str>, String> {
    let known: Vec<&str> = POOLINGS.iter().map(|(name, _)| *name).collect();
    let mut out: Vec<&str> = Vec::new();
    for p in spec.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        if !known.contains(&p) {
            return Err(format!(
                "unknown pooling {p:?} (known: {})",
                known.join(",")
            ));
        }
        if !out.contains(&p) {
            out.push(p);
        }
    }
    if out.is_empty() {
        return Err(format!("no poolings given (known: {})", known.join(",")));
    }
    Ok(out)
}

// Fail-closed coverage check for a compare reference (generic emit or golden): its label
// set must EQUAL `<id>|<pooling>` over every input x every requested pooling. Both
// directions are errors, and the message names the labels:
//   - an expected label absent from the reference: an inputs.tsv row was added (or
//     renamed) without regenerating the reference, so it would otherwise be skipped;
//   - a reference label no input produces: a row was removed or renamed, so the reference
//     is stale;
//   - a duplicate reference label: ambiguous, so it is never accepted;
//   - no reference label at all (a truncated, emptied or comment-only file): every expected
//     label is absent, and the message says so explicitly. This is the whole golden check
//     for that case — scripts/correctness.sh has no "empty golden" skip (issue #9).
fn check_reference_coverage(
    inputs: &[Input],
    poolings: &[&str],
    ref_labels: &[String],
) -> Result<(), String> {
    let expected: BTreeSet<String> = inputs
        .iter()
        .flat_map(|i| poolings.iter().map(move |p| label(&i.id, p)))
        .collect();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut duplicate: Vec<String> = Vec::new();
    for l in ref_labels {
        if !seen.insert(l.clone()) {
            duplicate.push(l.clone());
        }
    }
    let missing: Vec<String> = expected.difference(&seen).cloned().collect();
    let unexpected: Vec<String> = seen.difference(&expected).cloned().collect();
    if missing.is_empty() && unexpected.is_empty() && duplicate.is_empty() {
        return Ok(());
    }
    let mut why: Vec<String> = Vec::new();
    if ref_labels.is_empty() {
        why.push("the reference has no data rows".to_string());
    }
    if !missing.is_empty() {
        why.push(format!(
            "{} expected label(s) absent from the reference: {}",
            missing.len(),
            missing.join(", ")
        ));
    }
    if !unexpected.is_empty() {
        why.push(format!(
            "{} reference label(s) that no input produces: {}",
            unexpected.len(),
            unexpected.join(", ")
        ));
    }
    if !duplicate.is_empty() {
        why.push(format!(
            "{} duplicate reference label(s): {}",
            duplicate.len(),
            duplicate.join(", ")
        ));
    }
    Err(format!(
        "reference label set != inputs x [{}] ({} input(s), {} expected label(s)): {}",
        poolings.join(","),
        inputs.len(),
        expected.len(),
        why.join("; ")
    ))
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
    a.iter()
        .zip(b)
        .map(|(x, y)| (x - y).abs())
        .fold(0.0f32, f32::max)
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
            fail(&format!(
                "llama_model_load_from_file returned null for {model_path}"
            ));
        }
        let vocab = llama::llama_model_get_vocab(model);
        let n_embd = llama::llama_model_n_embd(model);
        if n_embd <= 0 {
            fail("model reports n_embd <= 0");
        }
        Engine {
            model,
            vocab,
            n_embd: n_embd as usize,
        }
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
        let out = (0..texts.len())
            .map(|s| self.read_seq(ctx, s as i32))
            .collect();
        llama::llama_batch_free(batch);
        out
    }

    unsafe fn read_seq(&self, ctx: *mut llama::llama_context, seq: i32) -> Vec<f32> {
        let emb = llama::llama_get_embeddings_seq(ctx, seq);
        if emb.is_null() {
            fail(&format!(
                "llama_get_embeddings_seq returned null (seq {seq})"
            ));
        }
        let slice = std::slice::from_raw_parts(emb, self.n_embd);
        if !slice.iter().all(|v| v.is_finite()) {
            fail(&format!(
                "embedding for seq {seq} contains non-finite values"
            ));
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
    let members: Vec<&Input> = inputs
        .iter()
        .filter(|i| i.group.starts_with(prefix))
        .collect();
    if members.len() < 2 {
        fail(&format!(
            "need >=2 inputs in a '{prefix}*' group for semantic sanity"
        ));
    }
    let a = eng.embed_single(ctx, &members[0].prefixed());
    let b = eng.embed_single(ctx, &members[1].prefixed());
    cosine(&a, &b)
}

unsafe fn print_sysinfo() {
    let s = llama::llama_print_system_info();
    if !s.is_null() {
        println!(
            "[correctness] system info: {}",
            CStr::from_ptr(s).to_string_lossy()
        );
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
                out.push_str(&label(&inp.id, pname));
                out.push('\t');
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
    eprintln!(
        "[correctness] emit wrote {out_path} ({n_inputs} inputs x {} poolings)",
        POOLINGS.len()
    );
}

// ---- selfcheck --------------------------------------------------------------------

fn mode_selfcheck() {
    let model = env_or_fail("CORRECTNESS_MODEL");
    let inputs = load_inputs();
    // Thresholds. Determinism is exact; batch/thread invariance allow FP reduction-order
    // slack. We gate on COSINE only (scale-invariant): llama.cpp returns UNNORMALIZED
    // pooled vectors, so an absolute max-abs-diff bound is unreliable (magnitudes vary by
    // model/layer). 0.999 catches real divergence (garbage is ~0.3) while ignoring the
    // ~1e-4 batched-vs-per-sequence noise seen on jina IQ4_NL. max_abs_diff is still
    // recorded for information.
    let inv_cos_min = 0.999f32; // batch / thread invariance (cosine)
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
        let nproc = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(2) as i32;
        let ctx1 = eng.context(
            llama::LLAMA_POOLING_TYPE_LAST,
            llama::LLAMA_ATTENTION_TYPE_NON_CAUSAL,
            1,
        );
        let ctxn = eng.context(
            llama::LLAMA_POOLING_TYPE_LAST,
            llama::LLAMA_ATTENTION_TYPE_NON_CAUSAL,
            nproc.max(1),
        );
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
        let ctx = eng.context(
            llama::LLAMA_POOLING_TYPE_LAST,
            llama::LLAMA_ATTENTION_TYPE_NON_CAUSAL,
            0,
        );
        let para_cos = group_pair_cosine(&eng, ctx, &inputs, "para");
        let unrel_cos = group_pair_cosine(&eng, ctx, &inputs, "unrel");
        llama::llama_free(ctx);
        let semantic = para_cos >= sem_para_min && para_cos > unrel_cos + sem_margin;

        eng.free();
        llama::llama_backend_free();

        let batch_ok = batch_cos_min >= inv_cos_min;
        let thread_ok = thread_cos_min >= inv_cos_min;
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

// Emit / golden TSV: `label<TAB>f0,f1,...`, `#` comments. A body with no data rows parses
// to an empty Vec on purpose: `compare` rejects that through check_reference_coverage,
// which names every absent label (issue #9), so there is no separate "no rows" error here.
fn parse_emit(body: &str) -> Result<Vec<(String, Vec<f32>)>, String> {
    let mut out = Vec::new();
    for line in body.lines() {
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        let mut it = line.splitn(2, '\t');
        let label = it.next().unwrap_or("").to_string();
        let csv = it.next().unwrap_or("");
        if label.is_empty() || csv.is_empty() {
            return Err(format!("malformed emit line: {line:?}"));
        }
        let v: Vec<f32> = csv
            .split(',')
            .map(|s| {
                s.trim()
                    .parse::<f32>()
                    .map_err(|_| format!("bad float: {s:?}"))
            })
            .collect::<Result<_, _>>()?;
        out.push((label, v));
    }
    Ok(out)
}

fn read_emit(path: &str) -> Vec<(String, Vec<f32>)> {
    let body = std::fs::read_to_string(path).unwrap_or_else(|e| fail(&format!("read {path}: {e}")));
    parse_emit(&body).unwrap_or_else(|e| fail(&format!("{path}: {e}")))
}

fn mode_compare() {
    let a_path = env_or_fail("CORRECTNESS_A");
    let b_path = env_or_fail("CORRECTNESS_B");
    let result = env_or_fail("CORRECTNESS_RESULT");
    let threshold: f32 = env_or_fail("CORRECTNESS_THRESHOLD")
        .parse()
        .unwrap_or_else(|_| fail("CORRECTNESS_THRESHOLD not a float"));
    let inputs_path = env_or_fail("CORRECTNESS_INPUTS");
    let inputs = load_inputs_at(&inputs_path);
    let ref_poolings_spec = env_or_fail("CORRECTNESS_REF_POOLINGS");
    let ref_poolings = parse_ref_poolings(&ref_poolings_spec)
        .unwrap_or_else(|e| fail(&format!("$CORRECTNESS_REF_POOLINGS: {e}")));

    // A = the packaged-archive emit (superset: every input x MEAN and LAST). B = the
    // REFERENCE side (generic emit, or the golden).
    //
    // B must cover the inputs fixture exactly: label set == inputs x ref_poolings. The
    // comparison below iterates B, so without this a B that is MISSING an input (an
    // inputs.tsv row added without regenerating the golden) would leave that input out of
    // the parity check while the gate still passes. A B label that no input produces is a
    // stale reference and fails too.
    let a: HashMap<String, Vec<f32>> = read_emit(&a_path).into_iter().collect();
    let b = read_emit(&b_path);
    let b_labels: Vec<String> = b.iter().map(|(l, _)| l.clone()).collect();
    if let Err(e) = check_reference_coverage(&inputs, &ref_poolings, &b_labels) {
        fail(&format!(
            "reference {b_path} does not cover inputs {inputs_path}: {e}. Regenerate the \
reference for the current inputs fixture (golden: scripts/gen-golden.sh)"
        ));
    }

    // Every reference label MUST then be present in A and matched — a reference label
    // missing from the emit is a hard failure (an emit missing a pooling/input must never
    // pass by being silently skipped).
    let mut min_cosine = 1.0f32;
    let mut worst_label = String::new();
    let mut n = 0usize;
    let mut per_label = String::new();
    let mut missing: Vec<String> = Vec::new();
    for (label, vb) in &b {
        let Some(va) = a.get(label) else {
            missing.push(label.clone());
            continue;
        };
        let c = cosine(va, vb);
        if c.is_nan() {
            fail(&format!(
                "cosine NaN for label {label:?} (len {} vs {})",
                va.len(),
                vb.len()
            ));
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
    if !missing.is_empty() {
        fail(&format!(
            "{} reference label(s) in {b_path} absent from emit {a_path}: {}",
            missing.len(),
            missing.join(", ")
        ));
    }
    if n == 0 {
        fail(&format!(
            "no labels to compare between {a_path} and {b_path}"
        ));
    }
    let passed = min_cosine >= threshold;
    let json = format!(
        "{{\"passed\":{passed},\"threshold\":{threshold},\"pairs\":{n},\
\"min_cosine\":{min_cosine},\"worst_label\":{worst_label:?},\"per_label\":[{per_label}]}}\n"
    );
    std::fs::write(&result, json).unwrap_or_else(|e| fail(&format!("write {result}: {e}")));
    println!(
        "[correctness] compare {a_path} vs {b_path}: {n} pairs (reference covers {} inputs x \
[{}]), min_cosine={min_cosine:.5} (worst {worst_label:?}) threshold={threshold} -> \
passed={passed}",
        inputs.len(),
        ref_poolings.join(",")
    );
    if !passed {
        exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = "# comment\n\
q1\tquery\tgeneral\tHello world\n\
\n\
   # indented comment\n\
d1\tdocument\tgeneral\tA document\twith a tab in its text\n\
para1_a\tdocument\tpara1\tSame\n\
para1_b\tdocument\tpara1\tSame, reworded\n";

    fn inputs() -> Vec<Input> {
        parse_inputs(FIXTURE).expect("fixture parses")
    }

    fn labels(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parse_inputs_skips_comments_and_blank_lines_and_keeps_tabs_in_text() {
        let rows = inputs();
        let ids: Vec<&str> = rows.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, ["q1", "d1", "para1_a", "para1_b"]);
        assert_eq!(rows[1].text, "A document\twith a tab in its text");
        assert_eq!(rows[0].role, "query");
        assert_eq!(rows[2].group, "para1");
    }

    #[test]
    fn parse_inputs_rejects_malformed_empty_duplicate_and_pipe_ids() {
        assert!(parse_inputs("q1\tquery\tgeneral\n")
            .unwrap_err()
            .contains("malformed"));
        assert!(parse_inputs("# only comments\n\n")
            .unwrap_err()
            .contains("no rows"));
        let dup = "q1\tquery\tg\tA\nq1\tdocument\tg\tB\n";
        assert!(parse_inputs(dup)
            .unwrap_err()
            .contains("duplicate input id \"q1\""));
        let pipe = "q|1\tquery\tg\tA\n";
        assert!(parse_inputs(pipe)
            .unwrap_err()
            .contains("must not contain '|'"));
    }

    #[test]
    fn ref_poolings_must_be_known_and_non_empty() {
        assert_eq!(parse_ref_poolings("last").unwrap(), ["last"]);
        assert_eq!(
            parse_ref_poolings(" mean , last ,mean").unwrap(),
            ["mean", "last"]
        );
        assert!(parse_ref_poolings("lsat")
            .unwrap_err()
            .contains("unknown pooling \"lsat\""));
        assert!(parse_ref_poolings("").unwrap_err().contains("no poolings"));
        assert!(parse_ref_poolings(" , ")
            .unwrap_err()
            .contains("no poolings"));
    }

    #[test]
    fn coverage_passes_when_reference_equals_inputs_x_poolings() {
        let golden = labels(&["q1|last", "d1|last", "para1_a|last", "para1_b|last"]);
        check_reference_coverage(&inputs(), &["last"], &golden).unwrap();
        // Order does not matter.
        let shuffled = labels(&["para1_b|last", "d1|last", "para1_a|last", "q1|last"]);
        check_reference_coverage(&inputs(), &["last"], &shuffled).unwrap();
        // A generic emit covers every pooling.
        let generic = labels(&[
            "q1|mean",
            "q1|last",
            "d1|mean",
            "d1|last",
            "para1_a|mean",
            "para1_a|last",
            "para1_b|mean",
            "para1_b|last",
        ]);
        check_reference_coverage(&inputs(), &["mean", "last"], &generic).unwrap();
    }

    // The gap behind issue #7: an inputs.tsv row with no golden row must fail, naming it.
    #[test]
    fn coverage_fails_closed_when_an_input_has_no_reference_label() {
        let stale_golden = labels(&["q1|last", "d1|last", "para1_a|last"]);
        let err = check_reference_coverage(&inputs(), &["last"], &stale_golden).unwrap_err();
        assert!(
            err.contains("1 expected label(s) absent from the reference: para1_b|last"),
            "{err}"
        );
        assert!(!err.contains("no input produces"), "{err}");
        assert!(!err.contains("no data rows"), "{err}");
    }

    // A removed or renamed row leaves a stale golden label: still fails, naming it.
    #[test]
    fn coverage_fails_closed_when_the_reference_has_a_label_no_input_produces() {
        let stale_golden = labels(&[
            "q1|last",
            "d1|last",
            "para1_a|last",
            "para1_b|last",
            "d_removed|last",
        ]);
        let err = check_reference_coverage(&inputs(), &["last"], &stale_golden).unwrap_err();
        assert!(
            err.contains("1 reference label(s) that no input produces: d_removed|last"),
            "{err}"
        );
        // A rename shows up on both sides at once.
        let renamed = labels(&["q1|last", "d1|last", "para1_a|last", "para1_c|last"]);
        let err = check_reference_coverage(&inputs(), &["last"], &renamed).unwrap_err();
        assert!(
            err.contains("absent from the reference: para1_b|last"),
            "{err}"
        );
        assert!(err.contains("no input produces: para1_c|last"), "{err}");
    }

    #[test]
    fn coverage_fails_closed_on_wrong_pooling_duplicates_and_empty_reference() {
        // A golden that carries a pooling it should not (or the wrong one) is not equal.
        let mean = labels(&["q1|mean", "d1|mean", "para1_a|mean", "para1_b|mean"]);
        let err = check_reference_coverage(&inputs(), &["last"], &mean).unwrap_err();
        assert!(err.contains("4 expected label(s) absent"), "{err}");
        assert!(
            err.contains("4 reference label(s) that no input produces"),
            "{err}"
        );
        let dup = labels(&[
            "q1|last",
            "d1|last",
            "para1_a|last",
            "para1_b|last",
            "q1|last",
        ]);
        let err = check_reference_coverage(&inputs(), &["last"], &dup).unwrap_err();
        assert!(
            err.contains("1 duplicate reference label(s): q1|last"),
            "{err}"
        );
        let err = check_reference_coverage(&inputs(), &["last"], &[]).unwrap_err();
        assert!(err.contains("the reference has no data rows"), "{err}");
        assert!(err.contains("4 expected label(s) absent"), "{err}");
    }

    #[test]
    fn parse_emit_skips_comments_and_blank_lines() {
        let rows = parse_emit("# header\n\nq1|last\t1, -2.5,3e-1\n  # note\nd1|mean\t0\n").unwrap();
        assert_eq!(
            rows,
            [
                ("q1|last".to_string(), vec![1.0, -2.5, 0.3]),
                ("d1|mean".to_string(), vec![0.0]),
            ]
        );
    }

    // Unparseable emit data fails closed instead of being skipped or zero-filled.
    #[test]
    fn parse_emit_rejects_malformed_lines_and_bad_floats() {
        for bad in ["q1|last\n", "q1|last\t\n", "\t1,2\n"] {
            assert!(
                parse_emit(bad).unwrap_err().contains("malformed emit line"),
                "{bad:?}"
            );
        }
        assert!(parse_emit("q1|last\t1,x,3\n")
            .unwrap_err()
            .contains("bad float: \"x\""));
        assert!(parse_emit("q1|last\t1,,3\n")
            .unwrap_err()
            .contains("bad float: \"\""));
    }

    // Issue #9: a golden.tsv that was truncated, emptied or left comment-only (a bad merge,
    // a stray `> golden.tsv`) must fail the golden check, not degrade it to a skip. It
    // parses to no labels (read_emit is parse_emit plus the read, whose error already
    // names the file), and the coverage gate rejects that explicitly.
    #[test]
    fn comment_only_reference_yields_no_labels_and_fails_coverage() {
        let golden = parse_emit(
            "# GOLDEN reference embeddings (§1). label<TAB>f0,f1,...\n\
             # DO NOT EDIT BY HAND.\n\
             \n",
        )
        .unwrap();
        assert!(golden.is_empty());
        let golden_labels: Vec<String> = golden.iter().map(|(l, _)| l.clone()).collect();
        let err = check_reference_coverage(&inputs(), &["last"], &golden_labels).unwrap_err();
        assert!(err.contains("the reference has no data rows"), "{err}");
        assert!(
            err.contains("4 expected label(s) absent from the reference: d1|last, para1_a|last, para1_b|last, q1|last"),
            "{err}"
        );
    }

    // The committed fixture pair must pass the gate unchanged: every inputs.tsv row has
    // exactly one `<id>|last` golden row and nothing else.
    #[test]
    fn committed_inputs_and_golden_fixtures_agree() {
        let fix = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures");
        let inputs = load_inputs_at(fix.join("inputs.tsv").to_str().unwrap());
        let golden = read_emit(fix.join("golden.tsv").to_str().unwrap());
        let golden_labels: Vec<String> = golden.iter().map(|(l, _)| l.clone()).collect();
        check_reference_coverage(&inputs, &["last"], &golden_labels).unwrap();
        assert_eq!(golden.len(), inputs.len());
        for (_, v) in &golden {
            assert_eq!(v.len(), 768);
        }
    }
}

fn main() {
    match env_or_fail("CORRECTNESS_MODE").as_str() {
        "emit" => mode_emit(),
        "selfcheck" => mode_selfcheck(),
        "compare" => mode_compare(),
        other => fail(&format!(
            "unknown $CORRECTNESS_MODE {other:?} (emit|selfcheck|compare)"
        )),
    }
}
