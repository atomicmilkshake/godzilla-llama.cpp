#include "ggml-cuda.h"

#include <cstdio>
#include <cstdlib>
#include <vector>

#if !defined(GGML_USE_CUDA)
int main() {
    std::fprintf(stderr, "test-triattention-gpu-fault-inject: skipped (CUDA not built)\n");
    return 0;
}
#else

static void require(bool cond, const char * msg) {
    if (!cond) {
        std::fprintf(stderr, "test-triattention-gpu-fault-inject: %s\n", msg);
        std::abort();
    }
}

static void test_oob_cell_index_returns_false(void) {
    const size_t row_bytes = 256;
    const uint32_t kv_size = 4;
    std::vector<uint8_t> k_host((size_t) kv_size * row_bytes, 0);

    void * d_staging = nullptr;
    require(triattention_gpu_malloc(&d_staging, row_bytes), "staging alloc failed");

    triattention_gpu_clear_errors();

    // Cell index beyond kv_size — gather must fail gracefully (no abort)
    const std::vector<uint32_t> bad_cells = { kv_size + 10 };
    const bool ok = triattention_gpu_gather_k_rows(
        d_staging, k_host.data(), row_bytes, bad_cells.data(), 1, kv_size);

    require(!ok, "OOB cell index must return false");

    triattention_gpu_clear_errors();
    require(triattention_gpu_device_sync(), "device must remain healthy after OOB gather failure");

    triattention_gpu_free_dev(d_staging);
}

static void test_device_sync_returns_bool(void) {
    triattention_gpu_clear_errors();
    require(triattention_gpu_device_sync(), "healthy device sync must succeed");
}

int main() {
    if (!triattention_gpu_device_available()) {
        std::fprintf(stderr, "test-triattention-gpu-fault-inject: skipped (no CUDA device)\n");
        return 0;
    }
    test_oob_cell_index_returns_false();
    test_device_sync_returns_bool();
    std::fprintf(stderr, "test-triattention-gpu-fault-inject: all tests passed\n");
    return 0;
}

#endif
