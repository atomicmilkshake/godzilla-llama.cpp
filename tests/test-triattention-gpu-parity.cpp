#include "llama-triattention.h"
#include "ggml-cuda.h"
#include "ggml-quants.h"
#include "turbo-rotation-data.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#if !defined(GGML_USE_CUDA)
int main() {
    std::fprintf(stderr, "test-triattention-gpu-parity: skipped (CUDA not built)\n");
    return 0;
}
#else

static void require(bool cond, const char * msg) {
    if (!cond) {
        std::fprintf(stderr, "test-triattention-gpu-parity: %s\n", msg);
        std::abort();
    }
}

static void precompute_stats(triattention_head_stats * hs, uint32_t fc) {
    hs->q_mean_abs   = new float[fc];
    hs->extra_weight = new float[fc];
    for (uint32_t f = 0; f < fc; f++) {
        const float re = hs->q_mean_real[f];
        const float im = hs->q_mean_imag[f];
        hs->q_mean_abs[f] = std::sqrt(re * re + im * im);
        hs->extra_weight[f] = hs->q_abs_mean[f] - hs->q_mean_abs[f];
        if (hs->extra_weight[f] < 0.0f) {
            hs->extra_weight[f] = 0.0f;
        }
    }
}

static void build_omega(float * omega, uint32_t fc, uint32_t head_dim, double rope_theta) {
    for (uint32_t f = 0; f < fc; f++) {
        const double exponent = -2.0 * (double) f / (double) head_dim;
        omega[f] = (float) std::pow(rope_theta, exponent);
    }
}

static void matvec_128_local(const float * mat, const float * vec, float * out) {
    for (int i = 0; i < 128; i++) {
        float sum = 0.0f;
        for (int j = 0; j < 128; j++) {
            sum += mat[(size_t) i * 128 + (size_t) j] * vec[j];
        }
        out[i] = sum;
    }
}

static void cpu_wht_inverse(float * dst, const float * src, uint32_t padded_hd) {
    for (uint32_t b = 0; b < padded_hd; b += 128) {
        // turbo2/turbo3 dequant is in rotated space; inverse is R^T (not R)
        matvec_128_local(TURBO_ROTATION_RT, src + b, dst + b);
    }
}

static void parity_case(
        enum ggml_type k_type,
        uint32_t padded_hd,
        uint32_t rope_style,
        bool need_wht) {
    const uint32_t fc = padded_hd / 2;
    const uint32_t n_cells = 4;
    const int64_t round_start = 128;

    std::vector<float> omega(fc);
    build_omega(omega.data(), fc, padded_hd, 10000.0);

    std::vector<float> freq_scale_sq(fc, 1.0f);
    std::vector<float> offsets = { 1.0f, 2.0f, 4.0f, 8.0f };

    triattention_head_stats hs = {};
    hs.q_mean_real  = new float[fc];
    hs.q_mean_imag  = new float[fc];
    hs.q_abs_mean   = new float[fc];
    for (uint32_t f = 0; f < fc; f++) {
        hs.q_mean_real[f] = 0.3f + 0.01f * (float) f;
        hs.q_mean_imag[f] = 0.2f + 0.02f * (float) f;
        hs.q_abs_mean[f]  = 0.5f + 0.005f * (float) f;
    }
    precompute_stats(&hs, fc);

    std::vector<float> post_rope((size_t) n_cells * padded_hd);
    std::vector<int32_t> positions = { 10, 25, 40, 55 };
    for (uint32_t c = 0; c < n_cells; c++) {
        for (uint32_t d = 0; d < padded_hd; d++) {
            post_rope[(size_t) c * padded_hd + d] =
                0.1f * (float) ((c + 1) * (d + 3) % 17) - 0.05f * (float) c;
        }
    }

    std::vector<float> cpu_scores(n_cells, 0.0f);
    std::vector<float> unrot((size_t) n_cells * padded_hd);
    std::vector<float> dequant((size_t) n_cells * padded_hd);

    const size_t row_bytes = ggml_row_size(k_type, padded_hd);
    std::vector<uint8_t> k_rows((size_t) n_cells * row_bytes);

    for (uint32_t c = 0; c < n_cells; c++) {
        float * row_f = post_rope.data() + (size_t) c * padded_hd;
        uint8_t * row_q = k_rows.data() + (size_t) c * row_bytes;

        if (k_type == GGML_TYPE_F32) {
            std::memcpy(row_q, row_f, padded_hd * sizeof(float));
            std::memcpy(dequant.data() + (size_t) c * padded_hd, row_f, padded_hd * sizeof(float));
        } else if (k_type == GGML_TYPE_TURBO3_0) {
            quantize_row_turbo3_0_ref(row_f, (block_turbo3_0 *) row_q, (int64_t) padded_hd);
            dequantize_row_turbo3_0((const block_turbo3_0 *) row_q,
                dequant.data() + (size_t) c * padded_hd, (int64_t) padded_hd);
            if (need_wht) {
                std::vector<float> tmp(padded_hd);
                cpu_wht_inverse(tmp.data(), dequant.data() + (size_t) c * padded_hd, padded_hd);
                std::memcpy(dequant.data() + (size_t) c * padded_hd, tmp.data(), padded_hd * sizeof(float));
            }
        } else {
            require(false, "unsupported k_type in parity test");
        }

        if (k_type == GGML_TYPE_F32) {
            triattention_invert_rope(
                unrot.data() + (size_t) c * padded_hd,
                dequant.data() + (size_t) c * padded_hd,
                positions.data() + c,
                omega.data(),
                1,
                padded_hd,
                fc,
                rope_style);
        } else {
            triattention_invert_rope(
                unrot.data() + (size_t) c * padded_hd,
                dequant.data() + (size_t) c * padded_hd,
                positions.data() + c,
                omega.data(),
                1,
                padded_hd,
                fc,
                rope_style);
        }
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
        rope_style);

    void * d_k = nullptr;
    require(triattention_gpu_malloc(&d_k, k_rows.size()), "triattention_gpu_malloc k failed");
    require(triattention_gpu_memcpy_h2d(d_k, k_rows.data(), k_rows.size()),
            "triattention_gpu_memcpy_h2d k failed");

    triattention_gpu_config gcfg = {};
    gcfg.head_dim     = padded_hd;
    gcfg.freq_count   = fc;
    gcfg.n_kv_heads   = 1;
    gcfg.n_sampled    = 1;
    gcfg.n_offsets    = (uint32_t) offsets.size();
    gcfg.k_type       = k_type;
    gcfg.need_wht_inv = need_wht;
    gcfg.disable_trig = false;
    gcfg.rope_style   = rope_style;

    triattention_gpu_head_calib gcal = {
        hs.q_mean_real, hs.q_mean_imag, hs.q_mean_abs, hs.extra_weight,
    };

    triattention_gpu_state * gst = triattention_gpu_init(
        &gcfg, &gcal, omega.data(), freq_scale_sq.data(), offsets.data(), nullptr);
    require(gst != nullptr, "triattention_gpu_init failed");

    std::vector<uint32_t> cell_idx(n_cells);
    for (uint32_t i = 0; i < n_cells; i++) {
        cell_idx[i] = i;
    }

    uint32_t * d_cells = nullptr;
    int32_t  * d_pos   = nullptr;
    require(triattention_gpu_upload_cells(
        &d_cells, &d_pos, cell_idx.data(), positions.data(), n_cells, nullptr),
        "triattention_gpu_upload_cells failed");

    float * d_scores = triattention_gpu_alloc_scores(n_cells, nullptr);
    require(d_scores != nullptr, "gpu score alloc failed");

    triattention_gpu_score_head(
        gst, d_k, padded_hd, row_bytes, 0, 0,
        d_cells, d_pos, n_cells, round_start, (int) TRIATTENTION_AGG_MEAN,
        d_scores, nullptr);

    std::vector<float> gpu_scores(n_cells);
    triattention_gpu_scores_to_host(gpu_scores.data(), d_scores, n_cells, nullptr);

    const float eps = k_type == GGML_TYPE_F32 ? 1e-4f : 5e-2f;
    for (uint32_t i = 0; i < n_cells; i++) {
        const float diff = std::fabs(cpu_scores[i] - gpu_scores[i]);
        if (diff > eps) {
            std::fprintf(stderr,
                "parity mismatch k_type=%d hd=%u cell=%u cpu=%.6f gpu=%.6f diff=%.6f\n",
                (int) k_type, padded_hd, i, cpu_scores[i], gpu_scores[i], diff);
            require(false, "CPU/GPU score mismatch");
        }
    }

    triattention_gpu_free_dev(d_scores);
    triattention_gpu_free_dev(d_cells);
    triattention_gpu_free_dev(d_pos);
    triattention_gpu_free(gst);
    triattention_gpu_free_dev(d_k);

    delete[] hs.q_mean_real;
    delete[] hs.q_mean_imag;
    delete[] hs.q_abs_mean;
    delete[] hs.q_mean_abs;
    delete[] hs.extra_weight;
}

int main() {
    if (!triattention_gpu_device_available()) {
        std::fprintf(stderr, "test-triattention-gpu-parity: no CUDA device\n");
        return 1;
    }

    parity_case(GGML_TYPE_F32,       256, 0, false);
    parity_case(GGML_TYPE_F32,       512, 0, false);
    parity_case(GGML_TYPE_F32,       256, 1, false);
    parity_case(GGML_TYPE_F32,       512, 1, false);
    parity_case(GGML_TYPE_TURBO3_0,  256, 0, true);
    parity_case(GGML_TYPE_TURBO3_0,  512, 0, true);

    std::fprintf(stderr, "test-triattention-gpu-parity: all tests passed\n");
    return 0;
}

#endif