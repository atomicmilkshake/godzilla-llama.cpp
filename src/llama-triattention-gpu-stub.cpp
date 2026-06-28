// CPU-only / no-CUDA builds: stub TriAttention GPU symbols declared in ggml-cuda.h.
// llama-triattention.cpp always links; real implementations live in ggml-cuda when GGML_CUDA=ON.

#include "ggml-cuda.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>

triattention_gpu_state * triattention_gpu_init(
    const triattention_gpu_config *,
    const triattention_gpu_head_calib *,
    const float *,
    const float *,
    const float *,
    void *) {
    return nullptr;
}

bool triattention_gpu_score_head(
    triattention_gpu_state *,
    const void *,
    uint64_t,
    size_t,
    uint32_t,
    uint32_t,
    uint32_t,
    bool,
    const uint32_t *,
    const int32_t *,
    uint32_t,
    int64_t,
    int,
    float *,
    void *) {
    return false;
}

bool triattention_gpu_scores_to_host(float *, const float *, uint32_t, void *) {
    return false;
}

bool triattention_gpu_upload_cells(
    uint32_t **,
    int32_t **,
    const uint32_t *,
    const int32_t *,
    uint32_t,
    void *) {
    return false;
}

float * triattention_gpu_alloc_scores(uint32_t, void *) {
    return nullptr;
}

void triattention_gpu_free_dev(void * ptr) {
    std::free(ptr);
}

void triattention_gpu_free(triattention_gpu_state *) {
}

bool triattention_gpu_device_sync(void) {
    return true;
}

void triattention_gpu_clear_errors(void) {
}

bool triattention_gpu_device_available(void) {
    return false;
}

bool triattention_gpu_malloc(void ** ptr, size_t nbytes) {
    if (ptr == nullptr || nbytes == 0) {
        return false;
    }
    *ptr = std::malloc(nbytes);
    return *ptr != nullptr;
}

bool triattention_gpu_memcpy_h2d(void *, const void *, size_t) {
    return false;
}

bool triattention_gpu_ensure_buffer(void **, size_t *, size_t) {
    return false;
}

bool triattention_gpu_gather_k_rows(
    void *,
    const void *,
    size_t,
    const uint32_t *,
    uint32_t,
    size_t) {
    return false;
}
