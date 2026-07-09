// Single source of truth: reuse the exact link snippet consumers get, so the
// correctness harness links the same archives (and same link line) documented in the
// artifact contract. STATIC_LLAMA_DIR selects the archive set under test (tuned dist/
// or the generic-flags build produced by scripts/correctness.sh).
include!("../scripts/consume.build.rs");
