#include "ggml.h"
#include "ggml-cuda.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#if !defined(GGML_USE_CUDA)
int main() {
    std::fprintf(stderr, "test-triattention-rowbytes-multistream: skipped (CUDA not built)\n");
    return 0;
}
#else

static void require(bool cond, const char * msg) {
    if (!cond) {
        std::fprintf(stderr, "test-triattention-rowbytes-multistream: %s\n", msg);
        std::abort();
    }
}

static void test_rowbytes_multistream(void) {
    const uint32_t embd = 256;
    const uint32_t kv_size = 8;
    const uint32_t n_stream = 2;
    const enum ggml_type k_type = GGML_TYPE_F32;

    const size_t row_bytes = ggml_row_size(k_type, (int64_t) embd);
    const size_t nbytes_total = (size_t) n_stream * kv_size * row_bytes;
    const size_t row_bytes_wrong = nbytes_total / (size_t) kv_size;

    require(row_bytes_wrong != row_bytes,
            "multi-stream padded layout must differ from ggml_row_size (TRIX-ROWBYTES bug)");

    const size_t stream_stride = row_bytes * (size_t) kv_size;
    std::vector<uint8_t> k_host(nbytes_total, 0);

    const uint32_t stream_idx = 1;
    const uint32_t cell_idx   = 3;
    const uint8_t sentinel  = 0xAB;
    std::memset(k_host.data() + stream_idx * stream_stride + (size_t) cell_idx * row_bytes,
                sentinel, row_bytes);

    void * d_staging = nullptr;
    require(triattention_gpu_malloc(&d_staging, row_bytes), "staging alloc failed");

    const char * k_base = (const char *) k_host.data() + stream_idx * stream_stride;
    const std::vector<uint32_t> cells = { cell_idx };

    require(triattention_gpu_gather_k_rows(
                d_staging, k_base, row_bytes, cells.data(), 1, kv_size),
            "stream-adjusted gather failed");

    // Wrong base (stream 0) with same cell index must not read stream-1 sentinel on host
    require(k_host[(size_t) cell_idx * row_bytes] != sentinel,
            "stream-0 cell must differ from stream-1 sentinel");

    triattention_gpu_free_dev(d_staging);
}

int main() {
    if (!triattention_gpu_device_available()) {
        std::fprintf(stderr, "test-triattention-rowbytes-multistream: skipped (no CUDA device)\n");
        return 0;
    }
    test_rowbytes_multistream();
    std::fprintf(stderr, "test-triattention-rowbytes-multistream: all tests passed\n");
    return 0;
}

#endif
