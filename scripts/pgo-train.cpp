// PGO training harness — exercises the EXACT embedding hot path (llama_encode) that
// consumers run, so an instrumented (-fprofile-generate) build collects a representative
// profile. This mirrors bench/src/main.rs; it is compiled + linked + run by
// scripts/build.sh ONLY when PGO=1 (against the instrumented static archives, with
// clang++ driving the link so libclang_rt.profile is added automatically).
//
// Kept minimal and dependency-free on purpose (uses only the llama.h C API — .cpp because
// the archives are C++ and clang++ drives the link). The profile is quant-type-specific,
// so the model passed here MUST be the quant you deploy.
//
// Usage: pgo-train <model.gguf> [iters]
#include "llama.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char ** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <model.gguf> [iters]\n", argv[0]);
        return 2;
    }
    const char * model_path = argv[1];
    const int iters = (argc > 2) ? atoi(argv[2]) : 300;

    llama_backend_init();

    struct llama_model_params mparams = llama_model_default_params();
    struct llama_model * model = llama_model_load_from_file(model_path, mparams);
    if (!model) {
        fprintf(stderr, "[pgo-train] model load failed: %s\n", model_path);
        return 1;
    }
    const struct llama_vocab * vocab = llama_model_get_vocab(model);

    // Same embedding configuration as the bench + smoke workloads (mean pooling).
    struct llama_context_params cparams = llama_context_default_params();
    cparams.embeddings = true;
    cparams.pooling_type = LLAMA_POOLING_TYPE_MEAN;
    struct llama_context * ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        fprintf(stderr, "[pgo-train] context init failed\n");
        return 1;
    }

    // A representative mixed CN/EN sample (UTF-8): its length + bilingual tokenization
    // exercise a realistic embedding sequence shape. strlen() gives the UTF-8 BYTE count,
    // which is exactly what llama_tokenize expects. Buffer sized generously (512) so a
    // long sequence is never truncated into a negative return.
    const char * text =
        "他问道:你想日后到英国去住吗？我说:不会的,我已经断了这个念头了 "
        "Do you think you'll want to go back and live in England?  he asked!"
        "###I don't think so,  I said!"
        "###I think I've got that much out of my system.";
    llama_token toks[512];
    const int n = llama_tokenize(
        vocab, text, (int) strlen(text), toks, (int) (sizeof(toks) / sizeof(toks[0])),
        /*add_special=*/true, /*parse_special=*/false);
    if (n <= 0) {
        fprintf(stderr, "[pgo-train] tokenize failed\n");
        return 1;
    }

    // A few warm-up encodes (allocation/first-run paths) then the timed-free training loop.
    for (int i = 0; i < iters + 5; i++) {
        struct llama_batch b = llama_batch_get_one(toks, n);
        if (llama_encode(ctx, b) != 0) {
            fprintf(stderr, "[pgo-train] encode failed at iter %d\n", i);
            return 1;
        }
    }

    fprintf(stderr, "[pgo-train] %d encodes done (%d tokens each)\n", iters, n);

    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    return 0;
}
