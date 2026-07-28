#include "llama-triattention.h"
#include "ggml.h"
#include "ggml-cuda.h"
#include "ggml-quants.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#if !defined(GGML_USE_CUDA)
int main() {
    std::fprintf(stderr, "test-triattention-host-kv-staging: skipped (CUDA not built)\n");
    return 0;
}
#else

static void require(bool cond, const char * msg) {
    if (!cond) {
        std::fprintf(stderr, "test-triattention-host-kv-staging: %s\n", msg);
        std::abort();
    }
}

static void build_omega(float * omega, uint32_t fc, uint32_t head_dim, double rope_theta) {
    for (uint32_t f = 0; f < fc; f++) {
        const double exponent = -2.0 * (double) f / (double) head_dim;
        omega[f] = (float) std::pow(rope_theta, exponent);
    }
}

static void staging_case(enum ggml_type k_type, uint32_t padded_hd) {
    const uint32_t fc = padded_hd / 2;
    const uint32_t n_cells = 4;
    const uint32_t kv_size = 16;
    const int64_t round_start = 200;

    std::vector<uint32_t> cell_idx = { 3, 7, 11, 15 };
    std::vector<int32_t> positions = { 12, 48, 96, 144 };

    std::vector<float> omega(fc);
    build_omega(omega.data(), fc, padded_hd, 10000.0);

    std::vector<float> freq_scale_sq(fc, 1.0f);
    std::vector<float> offsets = { 1.0f, 2.0f, 4.0f, 8.0f };

    triattention_head_stats hs = {};
    hs.q_mean_real    = new float[fc];
    hs.q_mean_imag    = new float[fc];
    hs.q_abs_mean     = new float[fc];
    hs.q_mean_abs     = new float[fc];
    hs.extra_weight   = new float[fc];
    for (uint32_t f = 0; f < fc; f++) {
        hs.q_mean_real[f] = 0.25f + 0.01f * (float) f;
        hs.q_mean_imag[f] = 0.15f + 0.02f * (float) f;
        hs.q_abs_mean[f]  = 0.45f + 0.005f * (float) f;
        hs.q_mean_abs[f]  = std::sqrt(hs.q_mean_real[f] * hs.q_mean_real[f] +
                                        hs.q_mean_imag[f] * hs.q_mean_imag[f]);
        hs.extra_weight[f] = hs.q_abs_mean[f] - hs.q_mean_abs[f];
        if (hs.extra_weight[f] < 0.0f) {
            hs.extra_weight[f] = 0.0f;
        }
    }

    const size_t row_bytes = ggml_row_size(k_type, padded_hd);
    std::vector<uint8_t> k_host((size_t) kv_size * row_bytes, 0);

    for (uint32_t c = 0; c < n_cells; c++) {
        const uint32_t global_cell = cell_idx[c];
        uint8_t * row_q = k_host.data() + (size_t) global_cell * row_bytes;
        for (uint32_t d = 0; d < padded_hd; d++) {
            const float v = 0.08f * (float) ((global_cell + 1) * (d + 5) % 19)
                          - 0.03f * (float) c;
            if (k_type == GGML_TYPE_F32) {
                std::memcpy(row_q + d * sizeof(float), &v, sizeof(float));
            } else if (k_type == GGML_TYPE_F16) {
                const ggml_fp16_t h = ggml_fp32_to_fp16(v);
                std::memcpy(row_q + d * sizeof(ggml_fp16_t), &h, sizeof(ggml_fp16_t));
            } else {
                require(false, "unsupported k_type in host-kv staging test");
            }
        }
    }

    std::vector<float> cpu_scores(n_cells, 0.0f);
    std::vector<float> dequant((size_t) n_cells * padded_hd);
    std::vector<float> unrot((size_t) n_cells * padded_hd);

    for (uint32_t c = 0; c < n_cells; c++) {
        const uint8_t * row_q = k_host.data() + (size_t) cell_idx[c] * row_bytes;
        float * row_f = dequant.data() + (size_t) c * padded_hd;
        if (k_type == GGML_TYPE_F32) {
            std::memcpy(row_f, row_q, padded_hd * sizeof(float));
        } else {
            ggml_fp16_to_fp32_row((const ggml_fp16_t *) row_q, row_f, (int64_t) padded_hd);
        }
        triattention_invert_rope(
            unrot.data() + (size_t) c * padded_hd,
            row_f,
            positions.data() + c,
            omega.data(),
            1,
            padded_hd,
            fc,
            0);
    }

    triattention_score_keys(
        cpu_scores.data(),
        unrot.data(),
        &hs,
        omega.data(),
        freq_scale_sq.data(),
        offsets.data(),
        positions.data(),
        round_start,
        n_cells,
        padded_hd,
        fc,
        (uint32_t) offsets.size(),
        TRIATTENTION_AGG_MEAN,
        false,
        0);

    void * d_staging = nullptr;
    size_t staging_cap = 0;
    const size_t need_staging = n_cells * row_bytes;
    require(triattention_gpu_ensure_buffer(&d_staging, &staging_cap, need_staging),
            "ensure_buffer staging failed");
    require(triattention_gpu_gather_k_rows(
        d_staging, k_host.data(), row_bytes, cell_idx.data(), n_cells, kv_size),
        "gather_k_rows failed");

    triattention_gpu_config gcfg = {};
    gcfg.head_dim     = padded_hd;
    gcfg.freq_count   = fc;
    gcfg.n_kv_heads   = 1;
    gcfg.n_sampled    = 1;
    gcfg.n_offsets    = (uint32_t) offsets.size();
    gcfg.k_type       = k_type;
    gcfg.need_wht_inv = false;
    gcfg.disable_trig = false;
    gcfg.rope_style   = 0;

    triattention_gpu_head_calib gcal = {
        hs.q_mean_real, hs.q_mean_imag, hs.q_mean_abs, hs.extra_weight,
    };

    triattention_gpu_state * gst = triattention_gpu_init(
        &gcfg, &gcal, omega.data(), freq_scale_sq.data(), offsets.data(), nullptr);
    require(gst != nullptr, "triattention_gpu_init failed");

    uint32_t * d_cells = nullptr;
    int32_t  * d_pos   = nullptr;
    require(triattention_gpu_upload_cells(
        &d_cells, &d_pos, cell_idx.data(), positions.data(), n_cells, nullptr),
        "upload_cells failed");

    float * d_scores = triattention_gpu_alloc_scores(n_cells, nullptr);
    require(d_scores != nullptr, "score alloc failed");

    require(triattention_gpu_score_head(
        gst, d_staging, padded_hd, row_bytes, 0, 0,
        padded_hd, true,
        d_cells, d_pos, n_cells, round_start, (int) TRIATTENTION_AGG_MEAN,
        d_scores, nullptr), "score_head compact failed");

    std::vector<float> gpu_scores(n_cells);
    require(triattention_gpu_scores_to_host(gpu_scores.data(), d_scores, n_cells, nullptr),
            "scores_to_host failed");

    const float eps = (k_type == GGML_TYPE_F32) ? 1e-4f : 1e-3f;
    for (uint32_t i = 0; i < n_cells; i++) {
        const float diff = std::fabs(cpu_scores[i] - gpu_scores[i]);
        if (diff > eps) {
            std::fprintf(stderr,
                "host-kv staging mismatch k_type=%d hd=%u cell=%u cpu=%.6f gpu=%.6f diff=%.6f\n",
                (int) k_type, padded_hd, i, cpu_scores[i], gpu_scores[i], diff);
            require(false, "CPU/GPU staged score mismatch");
        }
    }

    triattention_gpu_free_dev(d_scores);
    triattention_gpu_free_dev(d_cells);
    triattention_gpu_free_dev(d_pos);
    triattention_gpu_free(gst);
    triattention_gpu_free_dev(d_staging);

    delete[] hs.q_mean_real;
    delete[] hs.q_mean_imag;
    delete[] hs.q_abs_mean;
    delete[] hs.q_mean_abs;
    delete[] hs.extra_weight;
}

int main() {
    if (!triattention_gpu_device_available()) {
        std::fprintf(stderr, "test-triattention-host-kv-staging: no CUDA device\n");
        return 1;
    }

    staging_case(GGML_TYPE_F32, 256);
    staging_case(GGML_TYPE_F32, 512);
    staging_case(GGML_TYPE_F16,  512);

    std::fprintf(stderr, "test-triattention-host-kv-staging: all tests passed\n");
    return 0;
}

#endif