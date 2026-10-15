//! One pooled EmbeddingGemma 2 encode of exactly N tokens in a fresh process, with LTEmbed's
//! context settings (mean pooling, non-causal attention, flash attention on,
//! n_ctx = n_batch = n_ubatch = 8192, n_seq_max = 1). Prints one JSON line with the encode
//! latency, whether host logits exist, the token-sequence hash (to prove both archive sets
//! saw identical input) and the process peak RSS (VmHWM, kB) after the encode.
//!
//! usage: rss-probe <model.gguf> <n_tokens>   (RSS_THREADS, RSS_EMBEDDING_OUT optional)

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case, dead_code)]

mod llama {
    include!(env!("STATIC_LLAMA_BINDINGS"));
}

use std::ffi::CString;
use std::time::Instant;

const CONTEXT: u32 = 8192;
const PARAGRAPH: &str = "The northern lights appear when charged particles from the solar \
wind reach the upper atmosphere and collide with oxygen and nitrogen atoms. Those collisions \
excite the atoms, which then release the extra energy as light: green and red from oxygen, \
blue and purple from nitrogen. Activity rises after coronal mass ejections, so forecasters \
watch the sun for flares and measure the interplanetary magnetic field before predicting a \
display. Observers far from city lights, near the auroral oval, see the brightest curtains, \
usually around local midnight during the darker months of the year. ";

fn die(msg: &str) -> ! {
    eprintln!("[rss-probe] FAIL: {msg}");
    std::process::exit(1);
}

fn vm_hwm_kib() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find_map(|l| l.strip_prefix("VmHWM:"))
                .and_then(|v| v.trim().trim_end_matches("kB").trim().parse().ok())
        })
        .unwrap_or_else(|| die("cannot read VmHWM from /proc/self/status"))
}

fn fnv1a(tokens: &[i32]) -> u64 {
    tokens.iter().flat_map(|t| t.to_le_bytes()).fold(0xcbf29ce484222325, |h, b| {
        (h ^ b as u64).wrapping_mul(0x100000001b3)
    })
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        die("usage: rss-probe <model.gguf> <n_tokens>");
    }
    let n: usize = args[2].parse().ok().filter(|&n| n > 0 && n <= CONTEXT as usize)
        .unwrap_or_else(|| die("n_tokens must be in 1..=8192"));
    let threads: i32 = std::env::var("RSS_THREADS").ok().and_then(|v| v.parse().ok())
        .unwrap_or_else(|| std::thread::available_parallelism().map(|p| p.get() as i32).unwrap_or(4));
    let c_model = CString::new(args[1].clone()).unwrap();
    unsafe {
        llama::llama_backend_init();
        let model = llama::llama_model_load_from_file(c_model.as_ptr(), llama::llama_model_default_params());
        if model.is_null() {
            die("model load failed");
        }
        let vocab = llama::llama_model_get_vocab(model);
        let n_embd_out = llama::llama_model_n_embd_out(model);

        // Exactly n tokens: tokenize enough copies of the paragraph, keep the first n.
        let mut text = String::new();
        let mut toks: Vec<i32> = Vec::new();
        while toks.len() < n {
            text.push_str(PARAGRAPH);
            toks = vec![0; text.len() + 16];
            let got = llama::llama_tokenize(vocab, text.as_ptr() as *const _, text.len() as i32,
                toks.as_mut_ptr(), toks.len() as i32, true, false);
            if got <= 0 {
                die("tokenization failed");
            }
            toks.truncate(got as usize);
        }
        toks.truncate(n);

        let mut cparams = llama::llama_context_default_params();
        cparams.embeddings = true;
        cparams.pooling_type = llama::LLAMA_POOLING_TYPE_MEAN;
        cparams.attention_type = llama::LLAMA_ATTENTION_TYPE_NON_CAUSAL;
        cparams.flash_attn_type = llama::LLAMA_FLASH_ATTN_TYPE_ENABLED;
        cparams.n_ctx = CONTEXT;
        cparams.n_batch = CONTEXT;
        cparams.n_ubatch = CONTEXT;
        cparams.n_seq_max = 1;
        cparams.n_threads = threads;
        cparams.n_threads_batch = threads;
        let ctx = llama::llama_init_from_model(model, cparams);
        if ctx.is_null() {
            die("context init failed");
        }
        let hwm_before = vm_hwm_kib();

        let batch = llama::llama_batch_get_one(toks.as_mut_ptr(), n as i32);
        let start = Instant::now();
        if llama::llama_encode(ctx, batch) != 0 {
            die("llama_encode failed");
        }
        let emb = llama::llama_get_embeddings_seq(ctx, 0);
        let encode_ms = start.elapsed().as_secs_f64() * 1e3;
        if emb.is_null() {
            die("no pooled embedding");
        }
        let emb = std::slice::from_raw_parts(emb, n_embd_out as usize);
        if !emb.iter().all(|v| v.is_finite()) {
            die("non-finite embedding");
        }
        let norm = emb.iter().map(|v| v * v).sum::<f32>().sqrt();
        let host_logits = !llama::llama_get_logits(ctx).is_null();
        let hwm = vm_hwm_kib();
        if let Ok(path) = std::env::var("RSS_EMBEDDING_OUT") {
            let bytes: Vec<u8> = emb.iter().flat_map(|v| v.to_le_bytes()).collect();
            std::fs::write(path, bytes).unwrap_or_else(|_| die("cannot write embedding"));
        }
        println!(
            "{{\"n_tokens\":{n},\"token_fnv1a\":\"{:016x}\",\"threads\":{threads},\"n_embd_out\":{n_embd_out},\"encode_ms\":{encode_ms:.1},\"host_logits\":{host_logits},\"l2_norm\":{norm},\"vm_hwm_kib_before_encode\":{hwm_before},\"vm_hwm_kib\":{hwm}}}",
            fnv1a(&toks)
        );
        llama::llama_free(ctx);
        llama::llama_model_free(model);
        llama::llama_backend_free();
    }
}
