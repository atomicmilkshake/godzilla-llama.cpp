#pragma once

// this is a staging header for new llama.cpp API
// breaking changes and C++ are allowed. everything here should be considered WIP

#include "llama.h"

#include <cstdint>
#include <map>
#include <vector>

// Reserve a new compute graph. It is valid until the next call to llama_graph_reserve.
LLAMA_API struct ggml_cgraph * llama_graph_reserve(
        struct llama_context * ctx,
        uint32_t n_tokens,
        uint32_t n_seqs,
        uint32_t n_outputs);

// Get the default ggml_type for a given ftype.
LLAMA_API ggml_type llama_ftype_get_default_type(llama_ftype ftype);

struct quantize_state_impl;

LLAMA_API quantize_state_impl * llama_quant_init(
        const llama_model * model,
        const llama_model_quantize_params * params);

LLAMA_API void llama_quant_free(quantize_state_impl * qs);

// Descriptor for constructing a mock model for quantization testing.
struct llama_quant_model_desc {
    const char * architecture;
    uint32_t n_embd;
    uint32_t n_ff;
    uint32_t n_layer;
    uint32_t n_head;
    uint32_t n_head_kv;
    uint32_t n_expert;
    uint32_t n_embd_head_k;
    uint32_t n_embd_head_v;
};

// Create a mock model from a metadata descriptor (for testing).
// The returned model must be freed with llama_model_free().
LLAMA_API llama_model * llama_quant_model_from_metadata(const llama_quant_model_desc * desc);

// Returns true if this tensor should be quantized (based on name, dims, params).
LLAMA_API bool llama_quant_tensor_allows_quantization(
        const quantize_state_impl * qs,
        const ggml_tensor * tensor);

// Compute quantization type assignments for a list of tensors.
// All tensors should be quantizable (use llama_quant_tensor_allows_quantization to filter).
// result_types: caller-allocated array of n_tensors elements, filled with assigned types.
LLAMA_API void llama_quant_compute_types(
        quantize_state_impl * qs,
        llama_ftype ftype,
        ggml_tensor ** tensors,
        ggml_type * result_types,
        size_t n_tensors);

//
// device memory querying
//

// "memory" as in physical memory for a buffer type, in bytes
struct llama_memory_breakdown_data {
    size_t model   = 0; // memory allocated for the model
    size_t context = 0; // memory allocated for the context
    size_t compute = 0; // memory allocated for temporary compute buffers

    size_t total() const {
        return model + context + compute;
    }
};

struct llama_device_memory_data {
    int64_t total;
    int64_t free;
    llama_memory_breakdown_data mb;
};

// TODO: convert to C-style data structure
using llama_memory_breakdown = std::map<ggml_backend_buffer_type_t, llama_memory_breakdown_data>;

LLAMA_API int32_t llama_model_n_expert (const struct llama_model * model);
LLAMA_API int32_t llama_model_n_devices(const struct llama_model * model);
LLAMA_API const char * llama_model_arch_name(const struct llama_model * model);
LLAMA_API int32_t llama_model_is_swa_layer(const struct llama_model * model, int32_t il);
LLAMA_API float llama_model_rope_freq_base_train(const struct llama_model * model);
LLAMA_API float llama_model_rope_freq_base_train_swa(const struct llama_model * model);
LLAMA_API float llama_model_rope_freq_scale_train_swa(const struct llama_model * model);

LLAMA_API ggml_backend_dev_t llama_model_get_device(const struct llama_model * model, int i);
LLAMA_API ggml_backend_dev_t llama_model_dev_output(const struct llama_model * model);

LLAMA_API llama_memory_breakdown llama_get_memory_breakdown(const struct llama_context * ctx);

LLAMA_API struct llama_context * llama_get_ctx_other(struct llama_context * ctx);

// Set whether the context outputs nextn embeddings or not
// If masked == true,  output the embeddings only for the tokens with batch.logits != 0
// If masked == false, output the embeddings for all tokens in the batch regardless of batch.logits
LLAMA_API void llama_set_embeddings_nextn(struct llama_context * ctx, bool value, bool masked);

// mirrors:
// LLAMA_API float * llama_get_embeddings(struct llama_context * ctx);
LLAMA_API float * llama_get_embeddings_nextn(struct llama_context * ctx);

// LLAMA_API float * llama_get_embeddings_ith(struct llama_context * ctx, int32_t i);
LLAMA_API float * llama_get_embeddings_nextn_ith(struct llama_context * ctx, int32_t i);

//
// multi-layer hidden-state tap (EAGLE3 / dspark target-feature reuse)
//
// Register an ordered set of intermediate decoder layers to capture. After a
// decode, the per-layer outputs are concatenated per position into a row of
// width [n_capture_layers * n_embd], laid out [layer0 | layer1 | ...] in the
// same order as layer_ids. Pass n_layers == 0 to disable.
// If masked == true (default), capture is narrowed to output rows (batch.logits
// != 0) at the tap point. If masked == false, capture stays dense.
LLAMA_API void            llama_set_capture_layers(struct llama_context * ctx,
                                                   const int32_t *        layer_ids,
                                                   size_t                 n_layers,
                                                   bool                   masked = true);
LLAMA_API uint32_t llama_get_n_capture(struct llama_context * ctx);
LLAMA_API float *  llama_get_embeddings_capture    (struct llama_context * ctx);
LLAMA_API float *  llama_get_embeddings_capture_ith(struct llama_context * ctx, int32_t i);

//
// dspark drafter: target-tap context window staging
//
// feat is [n_ctx_rows * n_embd_cap] row-major. Pass n_ctx_rows <= 0 or feat ==
// nullptr to clear the staged context.
LLAMA_API void llama_set_dspark_ctx(
        struct llama_context * ctx,
        const float           * feat,
              int64_t           n_ctx_rows,
              int64_t           n_embd_cap);

struct llama_dspark_meta {
    int64_t n_embd        = 0;
    int64_t n_vocab       = 0; // from token_embd.weight's own shape, not the (empty) vocab
    int64_t n_capture     = 0; // target_layer_ids count
    int64_t n_embd_cap    = 0; // n_capture * n_embd (raw pre-fc tap width)
    int32_t block_size    = 0;
    int32_t mask_token_id = 0;
    int64_t markov_rank   = 0; // 0 if the checkpoint has no markov head
};

// Returns false if `model` is not a loaded dspark model (block_size == 0).
LLAMA_API bool llama_model_dspark_get_meta(
        const struct llama_model * model,
              llama_dspark_meta   * out);

// Copy the ordered target-layer ids this drafter taps into `out` (up to n_out).
// Returns the number of layers written, or 0 if not a dspark model / buffer too small.
LLAMA_API int32_t llama_model_dspark_get_target_layers(
        const struct llama_model * model,
              int32_t            * out,
              int32_t              n_out);

// w1 and w2 are both returned as [n_vocab * n_rank] row-major.
// Returns false if the model has no markov head.
LLAMA_API bool llama_model_dspark_get_markov(
        const struct llama_model * model,
        std::vector<float>       & w1,
        std::vector<float>       & w2);
