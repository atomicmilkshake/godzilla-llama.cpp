// TriAttention: Trigonometric KV Cache Eviction for llama.cpp
// Based on arXiv 2604.04921 (MIT/NVIDIA/ZJU)
//
// This file implements the complete TriAttention scoring and pruning pipeline:
//   1. Binary calibration file loader (.triattention format)
//   2. RoPE inversion (post-RoPE K → pre-RoPE K)
//   3. Trigonometric key importance scoring (Eqs. 6-10 from paper)
//   4. Three pruning modes: global union, per-KV-head, per-layer-per-head
//   5. Position tracking hooks for correct RoPE inversion after pruning
//   6. KV cache integration hooks
//
// All math references cite equation numbers from: "TriAttention: Decoding-Time
// Trigonometric Key Cache Eviction for Long-Context LLM Inference" (2604.04921)

#include "llama-triattention.h"
#include "llama-kv-cache.h"
#include "llama-hparams.h"
#include "llama-arch.h"
#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-cuda.h"   // GPU scoring: triattention_gpu_init, _score_head, etc.

// Block types and dequant declarations are in ggml-common.h (ggml/src/)
// which is not on the include path for src/. We declare the dequant
// functions with void* parameters and cast at call sites.
// Block sizes (bytes per 128 elements): turbo2=10, turbo3=14, turbo4=68, q8_0=34

#include <math.h>

#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <numeric>
#include <random>
#include <vector>

// For timing
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#   define NOMINMAX
#endif
#include <windows.h>
#else
#include <sys/time.h>
#endif

// Pre-computed WHT inverse rotation matrix R^T (128x128)
// Used to convert turbo2/turbo3 dequant output from WHT-rotated space
// back to the original post-RoPE embedding space.
// turbo4 dequant already applies R^T internally, so this is only needed
// for turbo2_0 and turbo3_0 types.
#include "turbo-rotation-data.h"

// TurboQuant dequant function declarations (from ggml-turbo-quant.c)
// Using void* since block type definitions live in ggml-common.h (not on include path)
extern "C" {
    void dequantize_row_turbo2_0(const void * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
    void dequantize_row_turbo3_0(const void * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
    void dequantize_row_turbo4_0(const void * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
}

// Standard ggml dequant for Q8_0, F16, etc.
extern "C" {
    void dequantize_row_q8_0(const void * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
}

// ============================================================================
// Internal helpers
// ============================================================================

// Head dimension used for RoPE inversion + scoring (calibration space).
// Under v1 projection, dequant reads the full cache row then truncates here.
static uint32_t triattention_score_padded_hd(const triattention_state * state) {
    if (state->projection_mode) {
        return ((state->cal->head_dim + 127) / 128) * 128;
    }
    return state->padded_cache_hd;
}

static double triattention_time_ms(void) {
#ifdef _WIN32
    LARGE_INTEGER freq, cnt;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&cnt);
    return (double)cnt.QuadPart / (double)freq.QuadPart * 1000.0;
#else
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec * 1000.0 + (double)tv.tv_usec / 1000.0;
#endif
}

// Matrix-vector multiply: out[i] = sum_j mat[i*d + j] * vec[j]
// Used for inverse WHT rotation on turbo2/turbo3 dequant output
static void matvec_128(const float * mat, const float * vec, float * out) {
    for (int i = 0; i < 128; i++) {
        float sum = 0.0f;
        const float * row = mat + i * 128;
        for (int j = 0; j < 128; j++) {
            sum += row[j] * vec[j];
        }
        out[i] = sum;
    }
}

// ============================================================================
// Binary calibration file I/O
// ============================================================================

static void triattention_free_calibration(triattention_calibration * cal);

static bool triattention_layer_mask_test(const uint32_t * mask, uint32_t n_words, uint32_t layer) {
    if (!mask || n_words == 0) {
        return true;
    }
    const uint32_t word = layer / 32;
    const uint32_t bit  = layer % 32;
    if (word >= n_words) {
        return false;
    }
    return (mask[word] >> bit) & 1u;
}

static bool triattention_projection_allowed(
        uint32_t cache_head_dim,
        uint32_t cal_head_dim,
        uint32_t projection_flags,
        int32_t  model_arch,
        enum triattention_profile_preference profile_pref) {
    if (cache_head_dim == cal_head_dim) {
        return false;
    }
    const bool allow = (projection_flags & TRI_PROJECTION_ALLOW_TRUNCATE) ||
                       (projection_flags & TRI_PROJECTION_AUTO_GEMMA4);
    if (!allow) {
        return false;
    }
    if (projection_flags & TRI_PROJECTION_AUTO_GEMMA4) {
        if (model_arch != (int32_t) LLM_ARCH_GEMMA4 &&
            model_arch != (int32_t) LLM_ARCH_GEMMA4_ASSISTANT) {
            return false;
        }
    }
    if (profile_pref == TRI_PROFILE_PREF_ISWA_SWA) {
        return false;
    }
    return cache_head_dim == 2 * cal_head_dim;
}

static bool triattention_read_head_stats(
        FILE * f,
        triattention_head_stats & hs,
        uint32_t fc,
        const char * path,
        uint32_t head_index) {
    hs.q_mean_real  = new float[fc];
    hs.q_mean_imag  = new float[fc];
    hs.q_abs_mean   = new float[fc];
    hs.q_mean_abs   = nullptr;
    hs.extra_weight = nullptr;

    bool ok = true;
    ok = ok && fread(hs.q_mean_real, sizeof(float), fc, f) == fc;
    ok = ok && fread(hs.q_mean_imag, sizeof(float), fc, f) == fc;
    ok = ok && fread(hs.q_abs_mean,  sizeof(float), fc, f) == fc;

    float * r_f_tmp = new float[fc];
    ok = ok && fread(r_f_tmp, sizeof(float), fc, f) == fc;
    delete[] r_f_tmp;

    if (!ok) {
        fprintf(stderr, "[TriAttention] ERROR: truncated stats for head %u in %s\n", head_index, path);
        delete[] hs.q_mean_real;
        delete[] hs.q_mean_imag;
        delete[] hs.q_abs_mean;
        return false;
    }
    return true;
}

// Load v1 .triattention calibration file
static triattention_calibration * triattention_load_calibration_v1(FILE * f, const char * path) {
    auto * cal = new triattention_calibration();
    memset(cal, 0, sizeof(triattention_calibration));
    cal->profile_tag = TRI_PROFILE_DEFAULT;
    cal->projection_active = false;

    // Read header fields
    bool ok = true;
    ok = ok && fread(&cal->head_dim,        sizeof(uint32_t), 1, f) == 1;
    ok = ok && fread(&cal->num_layers,      sizeof(uint32_t), 1, f) == 1;
    ok = ok && fread(&cal->num_attn_heads,  sizeof(uint32_t), 1, f) == 1;
    ok = ok && fread(&cal->num_kv_heads,    sizeof(uint32_t), 1, f) == 1;
    ok = ok && fread(&cal->rope_theta,      sizeof(double),   1, f) == 1;
    ok = ok && fread(&cal->rope_style,      sizeof(uint32_t), 1, f) == 1;
    ok = ok && fread(&cal->n_sampled,       sizeof(uint32_t), 1, f) == 1;
    ok = ok && fread(&cal->freq_count,      sizeof(uint32_t), 1, f) == 1;

    if (!ok) {
        fprintf(stderr, "[TriAttention] ERROR: truncated header in %s\n", path);
        delete cal;
        return nullptr;
    }

    // Read model name
    uint32_t name_len;
    if (fread(&name_len, sizeof(uint32_t), 1, f) != 1 || name_len == 0 || name_len > 255) {
        fprintf(stderr, "[TriAttention] ERROR: invalid model name length %u in %s\n", name_len, path);
        delete cal;
        return nullptr;
    }
    if (fread(cal->model_name, 1, name_len, f) != name_len) {
        fprintf(stderr, "[TriAttention] ERROR: truncated model name in %s\n", path);
        delete cal;
        return nullptr;
    }
    cal->model_name[name_len] = '\0';

    // Validate basic field consistency
    if (cal->freq_count != cal->head_dim / 2) {
        fprintf(stderr, "[TriAttention] ERROR: freq_count (%u) != head_dim/2 (%u) in %s\n",
                cal->freq_count, cal->head_dim / 2, path);
        delete cal;
        return nullptr;
    }

    if (cal->num_attn_heads == 0 || cal->num_kv_heads == 0 ||
        cal->num_attn_heads % cal->num_kv_heads != 0) {
        fprintf(stderr, "[TriAttention] ERROR: invalid head counts (attn=%u, kv=%u) in %s\n",
                cal->num_attn_heads, cal->num_kv_heads, path);
        delete cal;
        return nullptr;
    }

    cal->num_kv_groups = cal->num_attn_heads / cal->num_kv_heads;

    // Allocate per-head arrays
    cal->sampled_layer = new uint32_t[cal->n_sampled];
    cal->sampled_head  = new uint32_t[cal->n_sampled];
    cal->head_stats    = new triattention_head_stats[cal->n_sampled];

    const uint32_t fc = cal->freq_count;

    for (uint32_t h = 0; h < cal->n_sampled; h++) {
        // Read layer and head indices
        ok = true;
        ok = ok && fread(&cal->sampled_layer[h], sizeof(uint32_t), 1, f) == 1;
        ok = ok && fread(&cal->sampled_head[h],  sizeof(uint32_t), 1, f) == 1;

        if (!ok) {
            fprintf(stderr, "[TriAttention] ERROR: truncated head entry %u in %s\n", h, path);
            // Cleanup partially allocated heads
            for (uint32_t j = 0; j < h; j++) {
                delete[] cal->head_stats[j].q_mean_real;
                delete[] cal->head_stats[j].q_mean_imag;
                delete[] cal->head_stats[j].q_abs_mean;
            }
            delete[] cal->sampled_layer;
            delete[] cal->sampled_head;
            delete[] cal->head_stats;
            delete cal;
            return nullptr;
        }

        // Validate indices
        if (cal->sampled_layer[h] >= cal->num_layers ||
            cal->sampled_head[h] >= cal->num_attn_heads) {
            fprintf(stderr, "[TriAttention] ERROR: head entry %u has invalid indices (layer=%u, head=%u) in %s\n",
                    h, cal->sampled_layer[h], cal->sampled_head[h], path);
            for (uint32_t j = 0; j < h; j++) {
                delete[] cal->head_stats[j].q_mean_real;
                delete[] cal->head_stats[j].q_mean_imag;
                delete[] cal->head_stats[j].q_abs_mean;
            }
            delete[] cal->sampled_layer;
            delete[] cal->sampled_head;
            delete[] cal->head_stats;
            delete cal;
            return nullptr;
        }

        // Allocate and read per-frequency arrays
        auto & hs = cal->head_stats[h];
        hs.q_mean_real  = new float[fc];
        hs.q_mean_imag  = new float[fc];
        hs.q_abs_mean   = new float[fc];
        hs.q_mean_abs   = nullptr;  // computed at init time
        hs.extra_weight = nullptr;  // computed at init time

        ok = true;
        ok = ok && fread(hs.q_mean_real, sizeof(float), fc, f) == fc;
        ok = ok && fread(hs.q_mean_imag, sizeof(float), fc, f) == fc;
        ok = ok && fread(hs.q_abs_mean,  sizeof(float), fc, f) == fc;

        // Read R_f (validation data — not stored at runtime, just skip)
        float * r_f_tmp = new float[fc];
        ok = ok && fread(r_f_tmp, sizeof(float), fc, f) == fc;
        delete[] r_f_tmp;

        if (!ok) {
            fprintf(stderr, "[TriAttention] ERROR: truncated stats for head %u in %s\n", h, path);
            // Free this head's arrays
            delete[] hs.q_mean_real;
            delete[] hs.q_mean_imag;
            delete[] hs.q_abs_mean;
            // Free previous heads
            for (uint32_t j = 0; j < h; j++) {
                delete[] cal->head_stats[j].q_mean_real;
                delete[] cal->head_stats[j].q_mean_imag;
                delete[] cal->head_stats[j].q_abs_mean;
                delete[] cal->head_stats[j].q_mean_abs;
                delete[] cal->head_stats[j].extra_weight;
            }
            delete[] cal->sampled_layer;
            delete[] cal->sampled_head;
            delete[] cal->head_stats;
            delete cal;
            return nullptr;
        }
    }

    fprintf(stderr, "[TriAttention] Loaded v1 calibration: model=%s, layers=%u, attn_heads=%u, kv_heads=%u, "
            "head_dim=%u, sampled=%u, rope_theta=%.1f\n",
            cal->model_name, cal->num_layers, cal->num_attn_heads,
            cal->num_kv_heads, cal->head_dim, cal->n_sampled, cal->rope_theta);

    return cal;
}

struct triattention_v2_profile_raw {
    triattention_profile_tag tag;
    uint32_t head_dim;
    uint32_t num_layers;
    uint32_t num_attn_heads;
    uint32_t num_kv_heads;
    double   rope_theta;
    uint32_t layer_begin;
    uint32_t layer_end;
    std::vector<uint32_t> layer_mask;
    uint32_t n_sampled;
    uint32_t freq_count;
    std::vector<uint32_t> sampled_layer;
    std::vector<uint32_t> sampled_head;
    std::vector<triattention_head_stats> head_stats;
};

static triattention_calibration * triattention_materialize_profile(
        const triattention_v2_profile_raw & prof,
        const char * model_name,
        uint32_t rope_style) {
    auto * cal = new triattention_calibration();
    memset(cal, 0, sizeof(triattention_calibration));

    cal->profile_tag       = prof.tag;
    cal->projection_active = false;
    cal->head_dim          = prof.head_dim;
    cal->num_layers        = prof.num_layers;
    cal->num_attn_heads    = prof.num_attn_heads;
    cal->num_kv_heads      = prof.num_kv_heads;
    cal->rope_theta        = prof.rope_theta;
    cal->rope_style        = rope_style;
    cal->n_sampled         = prof.n_sampled;
    cal->freq_count        = prof.freq_count;
    cal->num_kv_groups     = prof.num_attn_heads / prof.num_kv_heads;

    snprintf(cal->model_name, sizeof(cal->model_name), "%s", model_name);

    cal->sampled_layer = new uint32_t[cal->n_sampled];
    cal->sampled_head  = new uint32_t[cal->n_sampled];
    cal->head_stats    = new triattention_head_stats[cal->n_sampled];

    for (uint32_t h = 0; h < cal->n_sampled; h++) {
        cal->sampled_layer[h] = prof.sampled_layer[h];
        cal->sampled_head[h]  = prof.sampled_head[h];

        const uint32_t fc = cal->freq_count;
        auto & hs = cal->head_stats[h];
        auto & src = prof.head_stats[h];
        hs.q_mean_real  = new float[fc];
        hs.q_mean_imag  = new float[fc];
        hs.q_abs_mean   = new float[fc];
        hs.q_mean_abs   = nullptr;
        hs.extra_weight = nullptr;
        memcpy(hs.q_mean_real, src.q_mean_real, fc * sizeof(float));
        memcpy(hs.q_mean_imag, src.q_mean_imag, fc * sizeof(float));
        memcpy(hs.q_abs_mean,  src.q_abs_mean,  fc * sizeof(float));
    }

    return cal;
}

static int triattention_profile_match_score(
        const triattention_v2_profile_raw & prof,
        uint32_t cache_head_dim,
        uint32_t cache_n_kv_heads,
        const triattention_init_opts & opts) {
    const bool dim_match = prof.head_dim == cache_head_dim;
    const bool dim_proj  = triattention_projection_allowed(
        cache_head_dim, prof.head_dim, opts.projection_flags, opts.model_arch, opts.profile_pref);
    if (!dim_match && !dim_proj) {
        return -1;
    }
    if (prof.num_kv_heads != cache_n_kv_heads) {
        return -1;
    }
    if (prof.n_sampled == 0) {
        return -1;
    }

    int overlap = 0;
    if (opts.managed_layers && opts.n_managed_layers > 0) {
        for (uint32_t i = 0; i < opts.n_managed_layers; i++) {
            const uint32_t il = (uint32_t) opts.managed_layers[i];
            if (triattention_layer_mask_test(prof.layer_mask.data(), (uint32_t) prof.layer_mask.size(), il)) {
                overlap++;
            }
        }
        if (overlap == 0) {
            return -1;
        }
    }

    int score = overlap * 1000;
    if (dim_match) {
        score += 500;
    }
    if (opts.profile_pref == TRI_PROFILE_PREF_ISWA_BASE && prof.tag == TRI_PROFILE_ISWA_BASE) {
        score += 10000;
    } else if (opts.profile_pref == TRI_PROFILE_PREF_ISWA_SWA && prof.tag == TRI_PROFILE_ISWA_SWA) {
        score += 10000;
    }
    return score;
}

static triattention_calibration * triattention_load_calibration_v2(
        FILE * f,
        const char * path,
        uint32_t cache_head_dim,
        uint32_t cache_n_kv_heads,
        const triattention_init_opts & opts) {
    uint32_t n_profiles = 0;
    uint32_t rope_style = 0;
    if (fread(&n_profiles, sizeof(uint32_t), 1, f) != 1 || n_profiles == 0 || n_profiles > 8) {
        fprintf(stderr, "[TriAttention] ERROR: invalid n_profiles in %s\n", path);
        return nullptr;
    }
    if (fread(&rope_style, sizeof(uint32_t), 1, f) != 1) {
        fprintf(stderr, "[TriAttention] ERROR: truncated v2 header in %s\n", path);
        return nullptr;
    }

    uint32_t name_len = 0;
    if (fread(&name_len, sizeof(uint32_t), 1, f) != 1 || name_len == 0 || name_len > 255) {
        fprintf(stderr, "[TriAttention] ERROR: invalid v2 model name length in %s\n", path);
        return nullptr;
    }
    char model_name[256] = {};
    if (fread(model_name, 1, name_len, f) != name_len) {
        fprintf(stderr, "[TriAttention] ERROR: truncated v2 model name in %s\n", path);
        return nullptr;
    }
    model_name[name_len] = '\0';

    uint32_t reserved[4] = {};
    if (fread(reserved, sizeof(uint32_t), 4, f) != 4) {
        fprintf(stderr, "[TriAttention] ERROR: truncated v2 reserved header in %s\n", path);
        return nullptr;
    }

    std::vector<triattention_v2_profile_raw> profiles;
    profiles.reserve(n_profiles);

    for (uint32_t p = 0; p < n_profiles; p++) {
        triattention_v2_profile_raw prof = {};
        bool ok = true;
        uint32_t tag_u32 = 0;
        ok = ok && fread(&tag_u32, sizeof(uint32_t), 1, f) == 1;
        prof.tag = (triattention_profile_tag) tag_u32;
        ok = ok && fread(&prof.head_dim,       sizeof(uint32_t), 1, f) == 1;
        ok = ok && fread(&prof.num_layers,     sizeof(uint32_t), 1, f) == 1;
        ok = ok && fread(&prof.num_attn_heads, sizeof(uint32_t), 1, f) == 1;
        ok = ok && fread(&prof.num_kv_heads,   sizeof(uint32_t), 1, f) == 1;
        ok = ok && fread(&prof.rope_theta,     sizeof(double),   1, f) == 1;
        ok = ok && fread(&prof.layer_begin,    sizeof(uint32_t), 1, f) == 1;
        ok = ok && fread(&prof.layer_end,      sizeof(uint32_t), 1, f) == 1;

        uint32_t layer_mask_words = 0;
        ok = ok && fread(&layer_mask_words, sizeof(uint32_t), 1, f) == 1;
        if (!ok) {
            fprintf(stderr, "[TriAttention] ERROR: truncated v2 profile %u header in %s\n", p, path);
            return nullptr;
        }

        prof.layer_mask.resize(layer_mask_words);
        if (layer_mask_words > 0) {
            if (fread(prof.layer_mask.data(), sizeof(uint32_t), layer_mask_words, f) != layer_mask_words) {
                fprintf(stderr, "[TriAttention] ERROR: truncated v2 layer_mask in %s\n", path);
                return nullptr;
            }
        }

        ok = true;
        ok = ok && fread(&prof.n_sampled,  sizeof(uint32_t), 1, f) == 1;
        ok = ok && fread(&prof.freq_count, sizeof(uint32_t), 1, f) == 1;
        if (!ok || prof.head_dim == 0 || prof.head_dim % 2 != 0 ||
            prof.freq_count != prof.head_dim / 2 ||
            prof.num_attn_heads == 0 || prof.num_kv_heads == 0 ||
            prof.num_attn_heads % prof.num_kv_heads != 0) {
            fprintf(stderr, "[TriAttention] ERROR: invalid v2 profile %u fields in %s\n", p, path);
            return nullptr;
        }

        prof.sampled_layer.resize(prof.n_sampled);
        prof.sampled_head.resize(prof.n_sampled);
        prof.head_stats.resize(prof.n_sampled);

        for (uint32_t h = 0; h < prof.n_sampled; h++) {
            if (fread(&prof.sampled_layer[h], sizeof(uint32_t), 1, f) != 1 ||
                fread(&prof.sampled_head[h],  sizeof(uint32_t), 1, f) != 1) {
                fprintf(stderr, "[TriAttention] ERROR: truncated v2 head index in %s\n", path);
                return nullptr;
            }
            if (prof.sampled_layer[h] >= prof.num_layers ||
                prof.sampled_head[h] >= prof.num_attn_heads ||
                !triattention_layer_mask_test(prof.layer_mask.data(), layer_mask_words, prof.sampled_layer[h])) {
                fprintf(stderr, "[TriAttention] ERROR: invalid v2 head entry (p=%u h=%u layer=%u) in %s\n",
                        p, h, prof.sampled_layer[h], path);
                return nullptr;
            }
            if (!triattention_read_head_stats(f, prof.head_stats[h], prof.freq_count, path, h)) {
                return nullptr;
            }
        }

        profiles.push_back(std::move(prof));
    }

    int best_score = -1;
    int best_idx   = -1;
    for (uint32_t p = 0; p < profiles.size(); p++) {
        const int s = triattention_profile_match_score(
            profiles[p], cache_head_dim, cache_n_kv_heads, opts);
        if (s > best_score) {
            best_score = s;
            best_idx   = (int) p;
        }
    }

    if (best_idx < 0) {
        fprintf(stderr, "[TriAttention] ERROR: no v2 profile matches sub-cache (cache_hd=%u cache_kv=%u) in %s\n",
                cache_head_dim, cache_n_kv_heads, path);
        if (opts.managed_layers && opts.n_managed_layers > 0) {
            fprintf(stderr, "[TriAttention]        managed layers:");
            for (uint32_t i = 0; i < opts.n_managed_layers; i++) {
                fprintf(stderr, " %d", opts.managed_layers[i]);
            }
            fprintf(stderr, "\n");
        }
        return nullptr;
    }

    const auto & chosen = profiles[(size_t) best_idx];
    fprintf(stderr, "[TriAttention] Selected v2 profile %d tag=%u head_dim=%u sampled=%u rope_theta=%.1f\n",
            best_idx, (unsigned) chosen.tag, chosen.head_dim, chosen.n_sampled, chosen.rope_theta);

    return triattention_materialize_profile(chosen, model_name, rope_style);
}

static triattention_calibration * triattention_load_for_subcache(
        const char * path,
        uint32_t cache_head_dim,
        uint32_t cache_n_kv_heads,
        const triattention_init_opts & opts) {
    FILE * f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "[TriAttention] ERROR: cannot open calibration file: %s\n", path);
        return nullptr;
    }

    uint32_t magic = 0;
    if (fread(&magic, sizeof(uint32_t), 1, f) != 1 || magic != TRIATTENTION_MAGIC) {
        fprintf(stderr, "[TriAttention] ERROR: invalid magic in %s (got 0x%08x, expected 0x%08x)\n",
                path, magic, TRIATTENTION_MAGIC);
        fclose(f);
        return nullptr;
    }

    uint32_t version = 0;
    if (fread(&version, sizeof(uint32_t), 1, f) != 1 ||
        (version != TRIATTENTION_VERSION && version != TRIATTENTION_VERSION_V2)) {
        fprintf(stderr, "[TriAttention] ERROR: unsupported version %u in %s (expected %u or %u)\n",
                version, path, TRIATTENTION_VERSION, TRIATTENTION_VERSION_V2);
        fclose(f);
        return nullptr;
    }

    triattention_calibration * cal = nullptr;
    if (version == TRIATTENTION_VERSION_V2) {
        cal = triattention_load_calibration_v2(f, path, cache_head_dim, cache_n_kv_heads, opts);
    } else {
        cal = triattention_load_calibration_v1(f, path);
    }
    fclose(f);

    if (!cal) {
        return nullptr;
    }

    if (cal->head_dim != cache_head_dim) {
        if (triattention_projection_allowed(
                cache_head_dim, cal->head_dim, opts.projection_flags, opts.model_arch, opts.profile_pref)) {
            cal->projection_active = true;
            fprintf(stderr, "[TriAttention] WARNING: projection mode active (cache_hd=%u cal_hd=%u)\n",
                    cache_head_dim, cal->head_dim);
        } else {
            fprintf(stderr, "[TriAttention] ERROR: head_dim mismatch (calibration=%u, cache=%u)\n",
                    cal->head_dim, cache_head_dim);
            if (opts.model_arch == (int32_t) LLM_ARCH_GEMMA4 ||
                opts.model_arch == (int32_t) LLM_ARCH_GEMMA4_ASSISTANT) {
                fprintf(stderr, "[TriAttention]        Gemma4 hybrid ISWA requires v2 calibration or "
                        "--triattention-projection auto-gemma4\n");
            }
            triattention_free_calibration(cal);
            return nullptr;
        }
    }

    return cal;
}

static void triattention_free_calibration(triattention_calibration * cal) {
    if (!cal) return;

    for (uint32_t h = 0; h < cal->n_sampled; h++) {
        delete[] cal->head_stats[h].q_mean_real;
        delete[] cal->head_stats[h].q_mean_imag;
        delete[] cal->head_stats[h].q_abs_mean;
        delete[] cal->head_stats[h].q_mean_abs;
        delete[] cal->head_stats[h].extra_weight;
    }
    delete[] cal->sampled_layer;
    delete[] cal->sampled_head;
    delete[] cal->head_stats;
    delete cal;
}

// ============================================================================
// Precomputation at init time
// ============================================================================

// Build RoPE frequency array: omega[f] = rope_theta^(-2f/head_dim)
// Paper Eq. 1: theta_f = base^{-2f/d}
static void triattention_build_omega(float * omega, uint32_t freq_count, uint32_t head_dim, double rope_theta) {
    for (uint32_t f = 0; f < freq_count; f++) {
        double exponent = -2.0 * (double)f / (double)head_dim;
        omega[f] = (float)pow(rope_theta, exponent);
    }
}

// Build frequency scaling squared: freq_scale_sq[f] = cos^2(omega[f]*0) + sin^2(omega[f]*0)
// For standard RoPE this is always 1.0, but for scaled RoPE (YaRN etc.)
// the scaling factors at position 0 capture any frequency-dependent scaling.
// Paper Section 3.2: "frequency scaling factor"
static void triattention_build_freq_scale_sq(float * freq_scale_sq, const float * omega, uint32_t freq_count) {
    for (uint32_t f = 0; f < freq_count; f++) {
        // At position 0: cos(omega*0)=1, sin(omega*0)=0
        // So freq_scale_sq = 1.0 for all standard RoPE variants.
        // If we later support YaRN scaling, this would use the actual scaling factors.
        float c = cosf(omega[f] * 0.0f);
        float s = sinf(omega[f] * 0.0f);
        freq_scale_sq[f] = c * c + s * s;
    }
}

// Build geometric offset array: {1, 2, 4, 8, ..., offset_max}
// Paper Eq. 9: D = {2^0, 2^1, ..., 2^{log2(max_length)}}
static uint32_t triattention_build_offsets(float * offsets, uint32_t offset_max) {
    uint32_t n = 0;
    for (uint32_t d = 1; d <= offset_max; d *= 2) {
        offsets[n++] = (float)d;
    }
    return n;
}

// Precompute derived quantities per head from calibration stats:
//   q_mean_abs[f] = sqrt(q_mean_real[f]^2 + q_mean_imag[f]^2)  = ||E[q_f]||
//   extra_weight[f] = q_abs_mean[f] - q_mean_abs[f]              = E[||q_f||] - ||E[q_f]||
// Paper Eq. 8: the "norm excess" term weighted by (1 - R_f)
static void triattention_precompute_head_derived(triattention_head_stats * hs, uint32_t freq_count, bool disable_mlr) {
    hs->q_mean_abs   = new float[freq_count];
    hs->extra_weight = new float[freq_count];

    for (uint32_t f = 0; f < freq_count; f++) {
        float re = hs->q_mean_real[f];
        float im = hs->q_mean_imag[f];
        hs->q_mean_abs[f] = sqrtf(re * re + im * im);

        if (disable_mlr) {
            // Ablation: use q_abs_mean directly as the norm contribution
            hs->extra_weight[f] = hs->q_abs_mean[f];
        } else {
            // Standard: MLR-weighted norm excess = E[||q_f||] - ||E[q_f]||
            // This is >= 0 because ||E[x]|| <= E[||x||] (Jensen's inequality)
            hs->extra_weight[f] = hs->q_abs_mean[f] - hs->q_mean_abs[f];
            if (hs->extra_weight[f] < 0.0f) {
                hs->extra_weight[f] = 0.0f;  // Numerical safety
            }
        }
    }
}

// ============================================================================
// Core scoring functions: CPU implementations
// ============================================================================

// Invert RoPE rotation on post-RoPE key vectors.
// Paper Eq. 4: recover pre-RoPE K from post-RoPE K using known positions.
//
// For "half" style (Llama/Qwen): dimensions split as [real | imag]
//   k_pre[f]    = k_post[f]*cos(omega[f]*pos) + k_post[f+fc]*sin(omega[f]*pos)
//   k_pre[f+fc] = k_post[f+fc]*cos(omega[f]*pos) - k_post[f]*sin(omega[f]*pos)
//
// For "interleaved" style: pairs are (2f, 2f+1)
//   k_pre[2f]   = k_post[2f]*cos(omega[f]*pos) + k_post[2f+1]*sin(omega[f]*pos)
//   k_pre[2f+1] = k_post[2f+1]*cos(omega[f]*pos) - k_post[2f]*sin(omega[f]*pos)
void triattention_invert_rope(
    float       * out,
    const float * post_rope_k,
    const int32_t * positions,
    const float * omega,
    uint32_t n_keys,
    uint32_t head_dim,
    uint32_t freq_count,
    uint32_t rope_style)
{
    for (uint32_t i = 0; i < n_keys; i++) {
        const float * src = post_rope_k + (size_t)i * head_dim;
        float       * dst = out         + (size_t)i * head_dim;
        const float   pos = (float)positions[i];

        if (rope_style == 0) {
            // Half style: [real_0..real_{fc-1} | imag_0..imag_{fc-1}]
            for (uint32_t f = 0; f < freq_count; f++) {
                float angle = omega[f] * pos;
                float c = cosf(angle);
                float s = sinf(angle);
                float re = src[f];
                float im = src[f + freq_count];
                // Invert rotation: multiply by conjugate rotation matrix
                dst[f]              = re * c + im * s;
                dst[f + freq_count] = im * c - re * s;
            }
        } else {
            // Interleaved style: [re_0, im_0, re_1, im_1, ...]
            for (uint32_t f = 0; f < freq_count; f++) {
                float angle = omega[f] * pos;
                float c = cosf(angle);
                float s = sinf(angle);
                float re = src[2 * f];
                float im = src[2 * f + 1];
                dst[2 * f]     = re * c + im * s;
                dst[2 * f + 1] = im * c - re * s;
            }
        }
    }
}

// Score cached keys for a single (layer, attention_head) pair.
// Paper Eqs. 6-10: trigonometric importance scoring with MLR norm term.
//
// For each key at position p_k with base distance Delta = round_start - p_k:
//   1. Convert pre-RoPE K to complex representation
//   2. Compute amplitude: amp_f = ||E[q_f]|| * |k_f|
//   3. Compute phase: phi_f = angle(E[q_f] * conj(k_f))
//   4. Compute trig score: S_trig(Delta+delta) = sum_f amp_f * fscale_sq_f * cos(omega_f*(Delta+delta) + phi_f)
//   5. Compute norm score: S_norm = sum_f extra_f * fscale_sq_f * |k_f|
//   6. Aggregate over geometric offsets
void triattention_score_keys(
    float       * out_scores,
    const float * pre_rope_k,
    const triattention_head_stats * stats,
    const float * omega,
    const float * freq_scale_sq,
    const float * offsets,
    const int32_t * key_positions,
    int64_t  round_start,
    uint32_t n_keys,
    uint32_t head_dim,
    uint32_t freq_count,
    uint32_t n_offsets,
    enum triattention_agg agg,
    bool disable_trig,
    uint32_t rope_style)
{
    const float inv_n_offsets = 1.0f / (float)n_offsets;

    for (uint32_t i = 0; i < n_keys; i++) {
        const float * k = pre_rope_k + (size_t)i * head_dim;
        const float   base_delta = (float)(round_start - key_positions[i]);

        float total_score = 0.0f;

        if (!disable_trig) {
            // Full scoring: trigonometric + norm terms
            for (uint32_t d = 0; d < n_offsets; d++) {
                float delta = base_delta + offsets[d];
                float offset_score = 0.0f;

                for (uint32_t f = 0; f < freq_count; f++) {
                    float k_re, k_im;
                    if (rope_style == 0) {
                        k_re = k[f];
                        k_im = k[f + freq_count];
                    } else {
                        k_re = k[2 * f];
                        k_im = k[2 * f + 1];
                    }
                    float k_mag = sqrtf(k_re * k_re + k_im * k_im);

                    // Amplitude: ||E[q_f]|| * |k_f|  (Paper Eq. 7)
                    float amp = stats->q_mean_abs[f] * k_mag;

                    // Phase from conj multiply: E[q_f] * conj(k_f)
                    // = (q_re + i*q_im) * (k_re - i*k_im)
                    // = (q_re*k_re + q_im*k_im) + i*(q_im*k_re - q_re*k_im)
                    float conj_re = stats->q_mean_real[f] * k_re + stats->q_mean_imag[f] * k_im;
                    float conj_im = stats->q_mean_imag[f] * k_re - stats->q_mean_real[f] * k_im;
                    float phi = atan2f(conj_im, conj_re);

                    // Trigonometric score (Paper Eq. 6):
                    // S_trig += amp * fscale^2 * cos(omega * delta + phi)
                    float phase = omega[f] * delta + phi;
                    offset_score += amp * freq_scale_sq[f] * cosf(phase);

                    // Norm excess term (Paper Eq. 8):
                    // S_norm += extra_weight * fscale^2 * |k_f|
                    offset_score += stats->extra_weight[f] * freq_scale_sq[f] * k_mag;
                }

                if (agg == TRIATTENTION_AGG_MAX) {
                    total_score = (d == 0) ? offset_score : fmaxf(total_score, offset_score);
                } else {
                    total_score += offset_score;
                }
            }

            if (agg == TRIATTENTION_AGG_MEAN) {
                total_score *= inv_n_offsets;
            }
        } else {
            // Ablation: norm-only scoring (disable_trig=true)
            for (uint32_t f = 0; f < freq_count; f++) {
                float k_re, k_im;
                if (rope_style == 0) {
                    k_re = k[f];
                    k_im = k[f + freq_count];
                } else {
                    k_re = k[2 * f];
                    k_im = k[2 * f + 1];
                }
                float k_mag = sqrtf(k_re * k_re + k_im * k_im);
                total_score += stats->extra_weight[f] * freq_scale_sq[f] * k_mag;
            }
        }

        out_scores[i] = total_score;
    }
}

// ============================================================================
// KV cache dequantization helper
// ============================================================================

// Dequantize K values for a specific KV head from the cache tensor.
// Handles all supported quantization types and applies inverse WHT
// rotation for turbo2/turbo3 types.
//
// Parameters:
//   out         — [n_cells, layer_padded_hd] dequantized float output (row stride = layer_padded_hd)
//   k_tensor    — the raw K cache tensor for this layer
//   cell_indices— [n_cells] which cell slots to extract
//   kv_head_idx — which KV head (0..n_kv_heads-1)
//   n_cells     — number of cells to dequantize
//   layer_padded_hd — per-head dim from k_tensor->ne[0]/n_kv_heads (turbo-padded or unpadded)
//   n_kv_heads  — total number of KV heads
//   need_wht_inv— whether to apply inverse WHT rotation (turbo2/turbo3)
//
// Note: This function copies data from potentially GPU-resident tensors
// to CPU memory, which involves a synchronous transfer. This is acceptable
// because pruning happens infrequently (every divide_length tokens).
static void triattention_dequant_kv_head(
    float              * out,
    const ggml_tensor  * k_tensor,
    const uint32_t     * cell_indices,
    uint32_t             kv_head_idx,
    uint32_t             n_cells,
    uint32_t             layer_padded_hd,
    uint32_t             n_kv_heads,
    bool                 need_wht_inv)
{
    const ggml_type k_type = k_tensor->type;
    const uint64_t  n_embd_k_gqa = k_tensor->ne[0];  // total K embedding (all KV heads)
    const size_t    row_bytes = ggml_row_size(k_type, n_embd_k_gqa);

    if (n_kv_heads == 0 || n_embd_k_gqa % n_kv_heads != 0) {
        fprintf(stderr, "[TriAttention] ERROR: invalid K tensor layout (ne[0]=%llu n_kv_heads=%u)\n",
                (unsigned long long) n_embd_k_gqa, n_kv_heads);
        return;
    }

    const uint32_t tensor_head_dim = (uint32_t)(n_embd_k_gqa / n_kv_heads);
    if (layer_padded_hd != tensor_head_dim) {
        fprintf(stderr, "[TriAttention] WARNING: layer_padded_hd=%u != tensor head dim %u; using tensor layout\n",
                layer_padded_hd, tensor_head_dim);
        layer_padded_hd = tensor_head_dim;
    }

    // Byte offset to this KV head within a row (TRIX-03: tensor stride, not cal head_dim)
    const size_t head_offset_bytes = ggml_row_size(k_type, (uint64_t)kv_head_idx * layer_padded_hd);
    const size_t head_bytes = ggml_row_size(k_type, layer_padded_hd);

    // Temporary buffer for one quantized head block
    std::vector<uint8_t> quant_buf(head_bytes);

    // Temporary buffer for dequantized values (before WHT inverse)
    std::vector<float> dequant_tmp(layer_padded_hd);

    for (uint32_t ci = 0; ci < n_cells; ci++) {
        const uint32_t cell_idx = cell_indices[ci];

        // Byte offset in the full tensor: row_bytes * cell_idx + head_offset_bytes
        // This addresses stream 0 (the common case for unified KV caches)
        const size_t tensor_offset = (size_t)cell_idx * row_bytes + head_offset_bytes;

        // Copy quantized data from backend (may be GPU) to CPU
        ggml_backend_tensor_get(k_tensor, quant_buf.data(), tensor_offset, head_bytes);

        // Dequantize based on type
        float * dst = need_wht_inv ? dequant_tmp.data() : (out + (size_t)ci * layer_padded_hd);

        switch (k_type) {
            case GGML_TYPE_TURBO3_0:
                dequantize_row_turbo3_0(quant_buf.data(), dst, layer_padded_hd);
                break;
            case GGML_TYPE_TURBO4_0:
                dequantize_row_turbo4_0(quant_buf.data(), dst, layer_padded_hd);
                break;
            case GGML_TYPE_TURBO2_0:
                dequantize_row_turbo2_0(quant_buf.data(), dst, layer_padded_hd);
                break;
            case GGML_TYPE_Q8_0:
                dequantize_row_q8_0(quant_buf.data(), dst, layer_padded_hd);
                break;
            case GGML_TYPE_F16: {
                const ggml_fp16_t * src16 = (const ggml_fp16_t *)quant_buf.data();
                for (uint32_t j = 0; j < layer_padded_hd; j++) {
                    dst[j] = ggml_fp16_to_fp32(src16[j]);
                }
                break;
            }
            case GGML_TYPE_BF16: {
                const ggml_bf16_t * src16 = (const ggml_bf16_t *)quant_buf.data();
                for (uint32_t j = 0; j < layer_padded_hd; j++) {
                    dst[j] = ggml_bf16_to_fp32(src16[j]);
                }
                break;
            }
            case GGML_TYPE_F32: {
                memcpy(dst, quant_buf.data(), layer_padded_hd * sizeof(float));
                break;
            }
            default:
                fprintf(stderr, "[TriAttention] ERROR: unsupported K cache type %d\n", k_type);
                memset(out + (size_t)ci * layer_padded_hd, 0, layer_padded_hd * sizeof(float));
                continue;
        }

        // Apply inverse WHT rotation for turbo2/turbo3
        // turbo4 dequant already applies R^T internally
        if (need_wht_inv) {
            float * final_dst = out + (size_t)ci * layer_padded_hd;
            // TRIX-09: process all 128-element WHT blocks (256/512-dim heads)
            for (uint32_t b = 0; b < layer_padded_hd; b += 128) {
                matvec_128(TURBO_ROTATION_R, dequant_tmp.data() + b, final_dst + b);
            }
        }
    }
}

// ============================================================================
// Public API: Init / Free
// ============================================================================

triattention_state * triattention_init(
    const char * stats_path,
    const triattention_config * cfg,
    uint32_t kv_size,
    double   rope_theta,
    uint32_t head_dim,
    uint32_t n_kv_heads,
    const triattention_init_opts * opts_in)
{
    triattention_init_opts opts = {};
    if (opts_in) {
        opts = *opts_in;
    }

    triattention_calibration * cal = triattention_load_for_subcache(
        stats_path, head_dim, n_kv_heads, opts);
    if (!cal) {
        return nullptr;
    }

    // Warn if rope_theta differs significantly (>1% relative)
    if (fabs(cal->rope_theta - rope_theta) / fmax(cal->rope_theta, 1.0) > 0.01) {
        fprintf(stderr, "[TriAttention] WARNING: rope_theta mismatch (calibration=%.1f, model=%.1f)\n",
                cal->rope_theta, rope_theta);
    }

    const uint32_t cache_hd = head_dim;
    const uint32_t padded_cache_hd = ((cache_hd + 127) / 128) * 128;
    const uint32_t fc = cal->freq_count;

    if (cal->num_kv_heads != n_kv_heads) {
        const bool hybrid_kv_ok = cal->projection_active ||
            cal->profile_tag == TRI_PROFILE_ISWA_BASE ||
            cal->profile_tag == TRI_PROFILE_ISWA_SWA;
        if (!hybrid_kv_ok) {
            fprintf(stderr, "[TriAttention] ERROR: n_kv_heads mismatch (calibration=%u, cache=%u)\n",
                    cal->num_kv_heads, n_kv_heads);
            triattention_free_calibration(cal);
            return nullptr;
        }
        fprintf(stderr, "[TriAttention] WARNING: n_kv_heads mismatch (calibration=%u, cache=%u) — "
                "using cache KV layout for dequant\n", cal->num_kv_heads, n_kv_heads);
    }

    auto * state = new triattention_state();
    memset(state, 0, sizeof(triattention_state));

    state->cal              = cal;
    state->cfg              = *cfg;
    state->kv_size          = kv_size;
    state->cache_head_dim   = cache_hd;
    state->padded_cache_hd  = padded_cache_hd;
    state->cache_n_kv_heads = n_kv_heads;
    state->score_freq_count = fc;
    state->projection_mode  = cal->projection_active;
    state->absolute_position = 0;
    state->prefix_length     = 0;

    state->omega = new float[fc];
    {
        const uint32_t omega_hd = state->projection_mode ? cal->head_dim : cache_hd;
        const double   omega_theta = cal->rope_theta;
        triattention_build_omega(state->omega, fc, omega_hd, omega_theta);
    }

    state->freq_scale_sq = new float[fc];
    triattention_build_freq_scale_sq(state->freq_scale_sq, state->omega, fc);

    state->offsets = new float[32];
    state->n_offsets = triattention_build_offsets(state->offsets, cfg->offset_max);

    for (uint32_t h = 0; h < cal->n_sampled; h++) {
        triattention_precompute_head_derived(&cal->head_stats[h], fc, cfg->disable_mlr);
    }

    state->cell_positions = new int32_t[kv_size];
    for (uint32_t i = 0; i < kv_size; i++) {
        state->cell_positions[i] = -1;
    }

    state->dequant_buf  = new float[(size_t)kv_size * padded_cache_hd];
    state->unrot_buf    = new float[(size_t)kv_size * padded_cache_hd];
    state->score_buf    = new float[(size_t)cal->n_sampled * kv_size];
    state->combined_buf = new float[kv_size];
    state->keep_indices = new uint32_t[cfg->budget];

    state->total_prune_calls    = 0;
    state->total_tokens_evicted = 0;
    state->total_prune_time_ms  = 0.0;
    state->last_prune_time_ms   = 0.0;

    fprintf(stderr, "[TriAttention] Initialized: budget=%u, window=%u, mode=%d, offsets=%u, "
            "kv_size=%u, sampled_heads=%u, cache_hd=%u cal_hd=%u projection=%d profile_tag=%u\n",
            cfg->budget, cfg->divide_length, (int)cfg->mode,
            state->n_offsets, kv_size, cal->n_sampled, cache_hd, cal->head_dim,
            (int) state->projection_mode, (unsigned) cal->profile_tag);

    return state;
}

void triattention_free(triattention_state * state) {
    if (!state) return;

    triattention_free_calibration(state->cal);

    delete[] state->omega;
    delete[] state->freq_scale_sq;
    delete[] state->offsets;
    delete[] state->cell_positions;
    delete[] state->dequant_buf;
    delete[] state->unrot_buf;
    delete[] state->score_buf;
    delete[] state->combined_buf;
    delete[] state->keep_indices;

    // Free GPU scoring resources if initialized
    if (state->d_scores) {
        triattention_gpu_free_dev(state->d_scores);
        state->d_scores = nullptr;
    }
    if (state->d_gpu_state) {
        triattention_gpu_free((triattention_gpu_state *)state->d_gpu_state);
        state->d_gpu_state = nullptr;
    }
    if (state->d_k_staging) {
        triattention_gpu_free_dev(state->d_k_staging);
        state->d_k_staging = nullptr;
    }
    if (state->d_scores_pool) {
        triattention_gpu_free_dev(state->d_scores_pool);
        state->d_scores_pool = nullptr;
    }
    if (state->d_cell_indices_pool) {
        triattention_gpu_free_dev(state->d_cell_indices_pool);
        state->d_cell_indices_pool = nullptr;
    }
    if (state->d_positions_pool) {
        triattention_gpu_free_dev(state->d_positions_pool);
        state->d_positions_pool = nullptr;
    }

    delete state;
}

// ============================================================================
// Position tracking hooks
// ============================================================================

void triattention_on_token_added(
    triattention_state * state,
    uint32_t cell_idx,
    int32_t  abs_pos)
{
    if (!state || cell_idx >= state->kv_size) return;
    state->cell_positions[cell_idx] = abs_pos;
    if (abs_pos + 1 > (int32_t)state->absolute_position) {
        state->absolute_position = abs_pos + 1;
    }
}

void triattention_on_cell_removed(
    triattention_state * state,
    uint32_t cell_idx)
{
    if (!state || cell_idx >= state->kv_size) return;
    state->cell_positions[cell_idx] = -1;
}

void triattention_on_position_shift(
    triattention_state * state,
    int32_t delta,
    int32_t p0,
    int32_t p1)
{
    if (!state || delta == 0) return;

    for (uint32_t i = 0; i < state->kv_size; i++) {
        int32_t pos = state->cell_positions[i];
        if (pos >= 0 && pos >= p0 && (p1 < 0 || pos < p1)) {
            state->cell_positions[i] = pos + delta;
            if (state->cell_positions[i] < 0) {
                state->cell_positions[i] = -1;
            }
        }
    }
}

void triattention_on_reset(triattention_state * state) {
    if (!state) return;
    state->absolute_position = 0;
    state->prefix_length     = 0;
    for (uint32_t i = 0; i < state->kv_size; i++) {
        state->cell_positions[i] = -1;
    }
}

// ============================================================================
// Trigger logic
// ============================================================================

bool triattention_should_prune(
    const triattention_state * state,
    uint32_t n_used)
{
    if (!state) return false;

    switch (state->cfg.trigger) {
        case TRIATTENTION_TRIGGER_INTERVAL:
            return n_used >= state->cfg.budget &&
                   state->absolute_position > 0 &&
                   (state->absolute_position % state->cfg.divide_length) == 0;

        case TRIATTENTION_TRIGGER_SLACK:
            return n_used >= (state->cfg.budget + state->cfg.divide_length);

        default:
            return false;
    }
}

// ============================================================================
// Main pruning implementation
// ============================================================================

// Helper: z-score normalize an array in-place
// After normalization: mean=0, std=1
static void zscore_normalize(float * scores, uint32_t n) {
    if (n <= 1) return;

    double sum = 0.0;
    for (uint32_t i = 0; i < n; i++) sum += scores[i];
    double mean = sum / n;

    double var_sum = 0.0;
    for (uint32_t i = 0; i < n; i++) {
        double d = scores[i] - mean;
        var_sum += d * d;
    }
    double std = sqrt(var_sum / n);
    if (std < 1e-10) std = 1e-10;

    for (uint32_t i = 0; i < n; i++) {
        scores[i] = (float)((scores[i] - mean) / std);
    }
}

// Helper: partial argsort — find top-K indices by score (descending)
// Returns indices of the K highest-scoring elements
static void top_k_indices(
    uint32_t       * out_indices,
    const float    * scores,
    uint32_t         n,
    uint32_t         k)
{
    if (k >= n) {
        // Keep all
        for (uint32_t i = 0; i < n; i++) out_indices[i] = i;
        return;
    }

    // Create index array and partial sort
    std::vector<uint32_t> idx(n);
    std::iota(idx.begin(), idx.end(), 0);

    std::partial_sort(idx.begin(), idx.begin() + k, idx.end(),
        [&scores](uint32_t a, uint32_t b) {
            return scores[a] > scores[b];  // descending
        });

    for (uint32_t i = 0; i < k; i++) {
        out_indices[i] = idx[i];
    }
}

// Apply optional per-head z-score normalization and deterministic tie-break noise.
static void triattention_preprocess_scores(
    const triattention_config & cfg,
    float * score_buf,
    uint32_t n_sampled,
    uint32_t n_decode,
    uint32_t prune_call_idx)
{
    if (cfg.normalize_scores) {
        for (uint32_t sh = 0; sh < n_sampled; sh++) {
            zscore_normalize(score_buf + (size_t) sh * n_decode, n_decode);
        }
    }

    if (cfg.seed >= 0) {
        std::mt19937 rng((uint32_t) cfg.seed + prune_call_idx);
        std::uniform_real_distribution<float> noise(-1e-6f, 1e-6f);
        for (uint32_t sh = 0; sh < n_sampled; sh++) {
            float * s = score_buf + (size_t) sh * n_decode;
            for (uint32_t i = 0; i < n_decode; i++) {
                s[i] += noise(rng);
            }
        }
    }
}

// TRIX-02: global union — each head picks top-B, union, then top-B from union by max score.
static void triattention_select_global_union(
    const float * score_buf,
    uint32_t      n_sampled,
    uint32_t      n_decode,
    uint32_t      budget,
    std::vector<uint32_t> & out)
{
    out.clear();
    if (budget == 0 || n_decode == 0 || n_sampled == 0) {
        return;
    }

    const uint32_t k_pick = std::min(budget, n_decode);
    std::vector<uint32_t> head_top(k_pick);

    std::vector<bool> in_union(n_decode, false);
    for (uint32_t sh = 0; sh < n_sampled; sh++) {
        top_k_indices(head_top.data(), score_buf + (size_t) sh * n_decode, n_decode, k_pick);
        for (uint32_t j = 0; j < k_pick; j++) {
            in_union[head_top[j]] = true;
        }
    }

    std::vector<uint32_t> union_idx;
    std::vector<float>    union_scores;
    union_idx.reserve(n_decode);
    union_scores.reserve(n_decode);

    for (uint32_t i = 0; i < n_decode; i++) {
        if (!in_union[i]) {
            continue;
        }
        float max_s = -1e30f;
        for (uint32_t sh = 0; sh < n_sampled; sh++) {
            const float s = score_buf[(size_t) sh * n_decode + i];
            if (s > max_s) {
                max_s = s;
            }
        }
        union_idx.push_back(i);
        union_scores.push_back(max_s);
    }

    if (union_idx.empty()) {
        return;
    }

    const uint32_t n_union = (uint32_t) union_idx.size();
    const uint32_t k_keep  = std::min(budget, n_union);
    std::vector<uint32_t> rank_idx(k_keep);
    top_k_indices(rank_idx.data(), union_scores.data(), n_union, k_keep);
    for (uint32_t j = 0; j < k_keep; j++) {
        out.push_back(union_idx[rank_idx[j]]);
    }
}

// TRIX-06: each KV head picks top-B independently; keep set is the union.
static void triattention_select_per_kv_head_union(
    const triattention_calibration * cal,
    uint32_t                         cache_n_kv_heads,
    const float                    * score_buf,
    uint32_t                         n_decode,
    uint32_t                         budget,
    std::vector<uint32_t>          & out)
{
    out.clear();
    if (budget == 0 || n_decode == 0 || cal->n_sampled == 0 || cache_n_kv_heads == 0) {
        return;
    }

    const uint32_t n_kv = cache_n_kv_heads;
    const uint32_t cache_kv_groups = cal->num_attn_heads / n_kv;
    std::vector<std::vector<uint32_t>> kv_head_to_sampled(n_kv);

    for (uint32_t sh = 0; sh < cal->n_sampled; sh++) {
        const uint32_t attn_head = cal->sampled_head[sh];
        if (attn_head >= cal->num_attn_heads) {
            continue;
        }
        const uint32_t kv_h = attn_head / cache_kv_groups;
        if (kv_h < n_kv) {
            kv_head_to_sampled[kv_h].push_back(sh);
        }
    }

    const uint32_t k_pick = std::min(budget, n_decode);
    std::vector<uint32_t> kv_top(k_pick);
    std::vector<float>    group_scores(n_decode);
    std::vector<bool>     keep(n_decode, false);

    for (uint32_t kv_h = 0; kv_h < n_kv; kv_h++) {
        const auto & heads = kv_head_to_sampled[kv_h];
        if (heads.empty()) {
            continue;
        }

        for (uint32_t i = 0; i < n_decode; i++) {
            float max_val = -1e30f;
            for (uint32_t sh_idx : heads) {
                const float s = score_buf[(size_t) sh_idx * n_decode + i];
                if (s > max_val) {
                    max_val = s;
                }
            }
            group_scores[i] = max_val;
        }

        top_k_indices(kv_top.data(), group_scores.data(), n_decode, k_pick);
        for (uint32_t j = 0; j < k_pick; j++) {
            keep[kv_top[j]] = true;
        }
    }

    for (uint32_t i = 0; i < n_decode; i++) {
        if (keep[i]) {
            out.push_back(i);
        }
    }
}

// TRIX-07: each sampled (layer, head) picks top-B independently; keep set is the union.
static void triattention_select_per_layer_head_union(
    const triattention_calibration * cal,
    const float                    * score_buf,
    uint32_t                         n_decode,
    uint32_t                         budget,
    std::vector<uint32_t>          & out)
{
    out.clear();
    if (budget == 0 || n_decode == 0 || cal->n_sampled == 0) {
        return;
    }

    const uint32_t k_pick = std::min(budget, n_decode);
    std::vector<uint32_t> head_top(k_pick);
    std::vector<bool>     keep(n_decode, false);

    for (uint32_t sh = 0; sh < cal->n_sampled; sh++) {
        top_k_indices(head_top.data(), score_buf + (size_t) sh * n_decode, n_decode, k_pick);
        for (uint32_t j = 0; j < k_pick; j++) {
            keep[head_top[j]] = true;
        }
    }

    for (uint32_t i = 0; i < n_decode; i++) {
        if (keep[i]) {
            out.push_back(i);
        }
    }
}

static void triattention_select_by_mode(
    const triattention_config      & cfg,
    const triattention_calibration * cal,
    uint32_t                         cache_n_kv_heads,
    const float                    * score_buf,
    uint32_t                         n_decode,
    uint32_t                         budget,
    std::vector<uint32_t>          & out)
{
    if (cfg.mode == TRIATTENTION_MODE_GLOBAL) {
        triattention_select_global_union(score_buf, cal->n_sampled, n_decode, budget, out);
    } else if (cfg.mode == TRIATTENTION_MODE_PER_KV_HEAD) {
        triattention_select_per_kv_head_union(cal, cache_n_kv_heads, score_buf, n_decode, budget, out);
    } else {
        triattention_select_per_layer_head_union(cal, score_buf, n_decode, budget, out);
    }
}

static uint32_t triattention_position_bucket(
    int32_t  pos,
    int32_t  pos_min,
    int32_t  pos_max,
    uint32_t n_buckets)
{
    if (n_buckets <= 1 || pos_max <= pos_min) {
        return 0;
    }
    const int64_t span = (int64_t) pos_max - pos_min + 1;
    const int64_t rel  = (int64_t) pos - pos_min;
    uint32_t b = (uint32_t) ((rel * (int64_t) n_buckets) / span);
    if (b >= n_buckets) {
        b = n_buckets - 1;
    }
    return b;
}

// PR-9 / TRIX-19: mode selection with optional per-position bucket segmentation.
void triattention_select_decode_tokens(
    const triattention_config      & cfg,
    const triattention_calibration * cal,
    uint32_t                         cache_n_kv_heads,
    uint32_t                         prune_call_idx,
    float                          * score_buf,
    uint32_t                         n_decode,
    uint32_t                         decode_budget,
    const int32_t                  * decode_positions,
    std::vector<bool>              & keep_set)
{
    keep_set.assign(n_decode, false);
    if (n_decode == 0 || decode_budget == 0 || !cal || cal->n_sampled == 0) {
        return;
    }

    triattention_preprocess_scores(cfg, score_buf, cal->n_sampled, n_decode, prune_call_idx);

    const uint32_t n_buckets = std::max(1u, cfg.buckets);
    if (n_buckets <= 1 || !decode_positions) {
        std::vector<uint32_t> selected;
        triattention_select_by_mode(cfg, cal, cache_n_kv_heads, score_buf, n_decode, decode_budget, selected);
        for (uint32_t idx : selected) {
            keep_set[idx] = true;
        }
        return;
    }

    int32_t pos_min = decode_positions[0];
    int32_t pos_max = decode_positions[0];
    for (uint32_t i = 1; i < n_decode; i++) {
        pos_min = std::min(pos_min, decode_positions[i]);
        pos_max = std::max(pos_max, decode_positions[i]);
    }

    const uint32_t base_budget = decode_budget / n_buckets;
    const uint32_t remainder   = decode_budget % n_buckets;

    for (uint32_t b = 0; b < n_buckets; b++) {
        uint32_t bucket_budget = base_budget + (b < remainder ? 1u : 0u);
        if (bucket_budget == 0) {
            continue;
        }

        std::vector<uint32_t> bucket_global;
        bucket_global.reserve(n_decode);
        for (uint32_t i = 0; i < n_decode; i++) {
            if (triattention_position_bucket(decode_positions[i], pos_min, pos_max, n_buckets) == b) {
                bucket_global.push_back(i);
            }
        }

        const uint32_t n_bucket = (uint32_t) bucket_global.size();
        if (n_bucket == 0) {
            continue;
        }
        bucket_budget = std::min(bucket_budget, n_bucket);

        std::vector<float> bucket_scores((size_t) cal->n_sampled * n_bucket);
        for (uint32_t sh = 0; sh < cal->n_sampled; sh++) {
            for (uint32_t li = 0; li < n_bucket; li++) {
                const uint32_t gi = bucket_global[li];
                bucket_scores[(size_t) sh * n_bucket + li] = score_buf[(size_t) sh * n_decode + gi];
            }
        }

        std::vector<uint32_t> bucket_selected;
        triattention_select_by_mode(cfg, cal, cache_n_kv_heads, bucket_scores.data(), n_bucket, bucket_budget, bucket_selected);
        for (uint32_t li : bucket_selected) {
            keep_set[bucket_global[li]] = true;
        }
    }
}

// ============================================================================
// GPU scoring: lazy init
// ============================================================================

// Initializes GPU scoring state on first prune, using the K tensor type
// of the actual cache to select the right kernel variant.
// k_type must be a type supported by the GPU kernel (Q4_K, Q8_0, F16, F32,
// TURBO2_0, TURBO3_0, TURBO4_0). On failure, falls back silently to CPU.
static void triattention_init_gpu(triattention_state * state, ggml_type k_type) {
    if (state->gpu_init_tried) return;
    state->gpu_init_tried = true;

    const triattention_calibration * cal = state->cal;
    const triattention_config & cfg = state->cfg;

    triattention_gpu_config gcfg = {};
    gcfg.head_dim     = triattention_score_padded_hd(state);
    gcfg.freq_count   = state->score_freq_count;
    gcfg.n_kv_heads   = state->cache_n_kv_heads;
    gcfg.n_sampled    = cal->n_sampled;
    gcfg.n_offsets    = state->n_offsets;
    gcfg.k_type       = k_type;
    gcfg.need_wht_inv = (k_type == GGML_TYPE_TURBO2_0 || k_type == GGML_TYPE_TURBO3_0);
    gcfg.disable_trig = cfg.disable_trig;
    gcfg.rope_style   = cal->rope_style;

    std::vector<triattention_gpu_head_calib> gcalibs(cal->n_sampled);
    for (uint32_t h = 0; h < cal->n_sampled; h++) {
        gcalibs[h].q_mean_real  = cal->head_stats[h].q_mean_real;
        gcalibs[h].q_mean_imag  = cal->head_stats[h].q_mean_imag;
        gcalibs[h].q_mean_abs   = cal->head_stats[h].q_mean_abs;
        gcalibs[h].extra_weight = cal->head_stats[h].extra_weight;
    }

    auto * gpu_st = triattention_gpu_init(
        &gcfg, gcalibs.data(),
        state->omega, state->freq_scale_sq, state->offsets, nullptr);
    if (!gpu_st) {
        fprintf(stderr, "[TriAttention] GPU init failed, using CPU scoring\n");
        return;
    }

    // Pre-allocate one head's worth of score buffer on device
    float * d_s = triattention_gpu_alloc_scores(state->kv_size, nullptr);
    if (!d_s) {
        triattention_gpu_free(gpu_st);
        fprintf(stderr, "[TriAttention] GPU score buffer alloc failed, using CPU scoring\n");
        return;
    }

    state->d_gpu_state  = gpu_st;
    state->d_scores     = d_s;
    state->use_gpu      = true;

    if (state->kv_on_host) {
        fprintf(stderr, "[TriAttention] GPU scoring enabled with host-KV staging (k_type=%d, heads=%u)\n",
                (int)k_type, cal->n_sampled);
    } else {
        fprintf(stderr, "[TriAttention] GPU scoring enabled (k_type=%d, heads=%u)\n",
                (int)k_type, cal->n_sampled);
    }
}

// ============================================================================
// ISWA prune batch coordination (TRIX-ISWA-DUAL-PRUNE)
// ============================================================================

static int  g_iswa_prune_depth = 0;
static bool g_iswa_force_cpu   = false;

void triattention_iswa_prune_scope_begin(void) {
    if (g_iswa_prune_depth++ == 0) {
        g_iswa_force_cpu = false;
    }
}

void triattention_iswa_prune_scope_end(void) {
    if (g_iswa_prune_depth <= 0) {
        return;
    }
    if (--g_iswa_prune_depth == 0) {
#if defined(GGML_USE_CUDA)
        triattention_gpu_clear_errors();
        if (!triattention_gpu_device_sync()) {
            fprintf(stderr, "[TriAttention] ISWA batch device sync failed\n");
        }
#endif
    }
}

void triattention_iswa_note_gpu_failure(void) {
    g_iswa_force_cpu = true;
}

bool triattention_iswa_gpu_blocked(void) {
    return g_iswa_force_cpu;
}

#if defined(GGML_USE_CUDA)
static bool triattention_gpu_ensure_cell_pool(
        triattention_state * state,
        uint32_t n_cells) {
    if (state->d_cell_pool_capacity >= n_cells &&
        state->d_cell_indices_pool && state->d_positions_pool) {
        return true;
    }
    if (state->d_cell_indices_pool) {
        triattention_gpu_free_dev(state->d_cell_indices_pool);
        state->d_cell_indices_pool = nullptr;
    }
    if (state->d_positions_pool) {
        triattention_gpu_free_dev(state->d_positions_pool);
        state->d_positions_pool = nullptr;
    }
    if (!triattention_gpu_malloc(
            (void **)&state->d_cell_indices_pool,
            (size_t) n_cells * sizeof(uint32_t)) ||
        !triattention_gpu_malloc(
            (void **)&state->d_positions_pool,
            (size_t) n_cells * sizeof(int32_t))) {
        triattention_gpu_free_dev(state->d_cell_indices_pool);
        triattention_gpu_free_dev(state->d_positions_pool);
        state->d_cell_indices_pool = nullptr;
        state->d_positions_pool = nullptr;
        state->d_cell_pool_capacity = 0;
        return false;
    }
    state->d_cell_pool_capacity = n_cells;
    return true;
}

static bool triattention_gpu_upload_cells_pooled(
        triattention_state * state,
        const uint32_t * cell_indices_host,
        const int32_t  * positions_host,
        uint32_t n_cells) {
    if (!triattention_gpu_ensure_cell_pool(state, n_cells)) {
        return false;
    }
    if (!triattention_gpu_memcpy_h2d(
            state->d_cell_indices_pool, cell_indices_host,
            (size_t) n_cells * sizeof(uint32_t)) ||
        !triattention_gpu_memcpy_h2d(
            state->d_positions_pool, positions_host,
            (size_t) n_cells * sizeof(int32_t))) {
        return false;
    }
    return true;
}
#endif

// ============================================================================
// Internal pruning implementation (called from KV cache integration)
// ============================================================================

// This is the real workhorse. Called from llama_kv_cache::triattention_try_prune()
// with direct access to the K tensors.
//
// Parameters:
//   state       — TriAttention runtime state
//   k_tensors   — array of K cache tensors, indexed by internal layer id
//   n_layers    — number of layers in k_tensors array
//   layer_map   — maps model layer index → internal layer id in k_tensors
//   v_cells     — reference to the cache's cell metadata (for rm operations)
//   v_heads     — reference to the cache's head pointer array (for updating after prune)
//   kv_size     — cache capacity
//
// Returns: number of cells evicted
int32_t triattention_prune_impl(
    triattention_state * state,
    ggml_tensor * const * k_tensors,
    uint32_t              n_layers,
    const int32_t       * layer_map,
    uint32_t              kv_size)
{
    if (!state) return -1;

    double t_start = triattention_time_ms();

    const auto & cfg = state->cfg;
    const auto * cal = state->cal;
    const uint32_t fc = state->score_freq_count;
    const uint32_t budget = cfg.budget;

    // ---- Step 1: Enumerate occupied cells ----
    std::vector<uint32_t> occupied_indices;
    std::vector<int32_t>  occupied_positions;
    occupied_indices.reserve(kv_size);
    occupied_positions.reserve(kv_size);

    for (uint32_t i = 0; i < kv_size; i++) {
        if (state->cell_positions[i] >= 0) {
            occupied_indices.push_back(i);
            occupied_positions.push_back(state->cell_positions[i]);
        }
    }

    const uint32_t n_occupied = (uint32_t)occupied_indices.size();
    if (n_occupied <= budget) return 0;

    // ---- Step 2: Separate protected tokens from eviction candidates ----
    // Two protection classes:
    //   1. Prefix-protected: initial prompt tokens (if protect_prefill is set)
    //   2. Recent-protected: the most recent divide_length positions are never evicted.
    //      This ensures seq_pos_max remains unchanged after pruning, so the server's
    //      position counter (which expects Y = seq_pos_max + 1) stays consistent.
    //      Without this, evicting the highest-position token would cause
    //      "inconsistent sequence positions" errors.

    // Compute max position for recent-window protection
    int32_t max_pos = -1;
    for (uint32_t i = 0; i < n_occupied; i++) {
        if (occupied_positions[i] > max_pos) {
            max_pos = occupied_positions[i];
        }
    }

    const uint32_t recent_window = cfg.divide_length + cfg.spec_protect_extra;
    const int32_t recent_threshold = max_pos - (int32_t)recent_window + 1;

    std::vector<uint32_t> decode_local_idx;   // index into occupied_indices
    std::vector<uint32_t> decode_cell_idx;    // actual cell indices
    std::vector<int32_t>  decode_positions;
    uint32_t n_protected = 0;  // prefix + recent protected count

    for (uint32_t i = 0; i < n_occupied; i++) {
        const bool is_prefix = cfg.protect_prefill &&
                               occupied_positions[i] < (int32_t)state->prefix_length;
        const bool is_hard_prefix = cfg.hard_prefix > 0 &&
                                    occupied_positions[i] < (int32_t)cfg.hard_prefix;
        const bool is_recent = occupied_positions[i] >= recent_threshold;

        if (is_prefix || is_hard_prefix || is_recent) {
            n_protected++;
        } else {
            decode_local_idx.push_back(i);
            decode_cell_idx.push_back(occupied_indices[i]);
            decode_positions.push_back(occupied_positions[i]);
        }
    }

    const uint32_t n_decode = (uint32_t)decode_cell_idx.size();
    const uint32_t decode_budget = (budget > n_protected) ? (budget - n_protected) : 0;

    if (n_decode == 0) return 0;
    if (decode_budget == 0) {
        // TRIX-01: protected tokens fill the budget — evict all decode candidates
        for (uint32_t i = 0; i < n_decode; i++) {
            const uint32_t cell = decode_cell_idx[i];
            state->cell_positions[cell] = -1;
        }
        state->total_prune_calls++;
        state->total_tokens_evicted += n_decode;
        double t_end = triattention_time_ms();
        state->last_prune_time_ms = t_end - t_start;
        state->total_prune_time_ms += state->last_prune_time_ms;
        return (int32_t) n_decode;
    }
    if (n_decode <= decode_budget) return 0;

    // Layer filter: only score heads belonging to this sub-cache's managed layers
    std::vector<bool> layer_in_subcache;
    uint32_t max_layer = 0;
    for (uint32_t l = 0; l < n_layers; l++) {
        max_layer = std::max(max_layer, (uint32_t) layer_map[l]);
    }
    layer_in_subcache.assign(max_layer + 1, false);
    for (uint32_t l = 0; l < n_layers; l++) {
        if (layer_map[l] >= 0) {
            layer_in_subcache[(uint32_t) layer_map[l]] = true;
        }
    }

    // ---- Step 3: Score all sampled (layer, head) pairs ----
    // score_buf layout: [n_sampled, n_decode] — row-major
    float * score_buf = state->score_buf;

    // Determine K tensor type (used for lazy GPU init)
    const ggml_type k_type = (n_layers > 0 && k_tensors[0]) ? k_tensors[0]->type : GGML_TYPE_F32;

    // Lazy GPU init: runs only once per state lifetime
    if (!state->gpu_init_tried) {
        if (n_layers > 0 && k_tensors[0] && k_tensors[0]->buffer) {
            state->kv_on_host = ggml_backend_buffer_is_host(k_tensors[0]->buffer);
        }
        triattention_init_gpu(state, k_type);
        if (state->kv_on_host && state->use_gpu && !state->kv_on_host_logged) {
            fprintf(stderr, "[TriAttention] GPU scoring with host-KV staging enabled\n");
            state->kv_on_host_logged = true;
        }
    }

    bool gpu_scored = false;
    const bool try_gpu = state->use_gpu && !triattention_iswa_gpu_blocked();
    static bool n_decode_cap_logged = false;
    const bool n_decode_gpu_ok = (n_decode <= 8192);
    if (state->use_gpu && !n_decode_gpu_ok) {
        if (!n_decode_cap_logged) {
            fprintf(stderr,
                "[TriAttention] n_decode %u exceeds GPU cap 8192, using CPU for large prunes\n",
                n_decode);
            n_decode_cap_logged = true;
        }
    }

    if (try_gpu && n_decode_gpu_ok) {
#if defined(GGML_USE_CUDA)
        triattention_gpu_clear_errors();
        if (g_iswa_prune_depth == 0) {
            if (!triattention_gpu_device_sync()) {
                fprintf(stderr,
                    "[TriAttention] GPU device sync failed before prune, using CPU scoring\n");
                triattention_iswa_note_gpu_failure();
                state->use_gpu = false;
            }
        }
#endif
        if (state->use_gpu && !triattention_iswa_gpu_blocked()) {
        // ---- GPU path ----
        uint32_t * d_cell_indices = nullptr;
        int32_t  * d_positions    = nullptr;
#if defined(GGML_USE_CUDA)
        const bool cells_uploaded = triattention_gpu_upload_cells_pooled(
            state, decode_cell_idx.data(), decode_positions.data(), n_decode);
        if (cells_uploaded) {
            d_cell_indices = state->d_cell_indices_pool;
            d_positions    = state->d_positions_pool;
        }
#else
        const bool cells_uploaded = false;
#endif

        const size_t need_score_bytes = (size_t)cal->n_sampled * n_decode * sizeof(float);
        size_t scores_cap_bytes = state->d_scores_pool_floats * sizeof(float);
        float * d_scores_all = nullptr;
        if (cells_uploaded &&
            triattention_gpu_ensure_buffer(
                (void **)&state->d_scores_pool, &scores_cap_bytes, need_score_bytes)) {
            d_scores_all = state->d_scores_pool;
            state->d_scores_pool_floats = scores_cap_bytes / sizeof(float);
        }

        if (!cells_uploaded || !d_scores_all) {
            fprintf(stderr, "[TriAttention] GPU prune buffer alloc failed, using CPU scoring\n");
            triattention_iswa_note_gpu_failure();
            state->use_gpu = false;
            triattention_gpu_free((triattention_gpu_state *)state->d_gpu_state);
            state->d_gpu_state = nullptr;
        } else {
            bool gpu_ok = true;
            int32_t last_staged_ikv = -1;

            // TRIX-ROWBYTES: validate cell indices before any gather/score
            if (n_layers > 0 && k_tensors[0]) {
                const uint64_t kv_cells_per_stream = (uint64_t) k_tensors[0]->ne[1];
                for (uint32_t ci = 0; ci < n_decode; ci++) {
                    if ((uint64_t) decode_cell_idx[ci] >= kv_cells_per_stream) {
                        fprintf(stderr,
                            "[TriAttention] GPU: cell index %u >= kv_size %llu\n",
                            decode_cell_idx[ci], (unsigned long long) kv_cells_per_stream);
                        gpu_ok = false;
                        break;
                    }
                }
            }

            for (uint32_t sh = 0; sh < cal->n_sampled && gpu_ok; sh++) {
                const uint32_t layer_idx = cal->sampled_layer[sh];
                if (layer_idx >= layer_in_subcache.size() || !layer_in_subcache[layer_idx]) {
                    continue;
                }
                const uint32_t attn_head = cal->sampled_head[sh];
                const uint32_t cache_kv_groups = cal->num_attn_heads / state->cache_n_kv_heads;
                const uint32_t kv_head   = attn_head / cache_kv_groups;

                int32_t ikv = -1;
                for (uint32_t l = 0; l < n_layers; l++) {
                    if (layer_map[l] == (int32_t) layer_idx) { ikv = (int32_t)l; break; }
                }
                if (ikv < 0) {
                    continue;
                }

                const ggml_tensor * kt = k_tensors[ikv];
                if (state->cache_n_kv_heads == 0 || kt->ne[0] % state->cache_n_kv_heads != 0) {
                    fprintf(stderr, "[TriAttention] GPU: bad K tensor layout for layer %u\n", layer_idx);
                    gpu_ok = false;
                    break;
                }
                const uint32_t layer_padded_hd =
                    (uint32_t)(kt->ne[0] / (uint64_t) state->cache_n_kv_heads);
                // TRIX-ROWBYTES: align with CPU dequant path (not ggml_nbytes/ne[1])
                const size_t row_bytes = ggml_row_size(kt->type, (int64_t) kt->ne[0]);
                const uint64_t n_embd  = (uint64_t) kt->ne[0];
                const uint32_t stream_idx = 0; // prune path uses stream 0 (unified / single-slot)
                const size_t stream_stride = row_bytes * (size_t) kt->ne[1];
                const char * k_host_base = (const char *) kt->data +
                    (size_t) stream_idx * stream_stride;
                const uint32_t score_hd = state->projection_mode ? cal->head_dim : layer_padded_hd;

                const void * k_ptr = k_host_base;
                bool k_rows_compact = false;

                if (state->kv_on_host) {
                    if (ikv != last_staged_ikv) {
                        const size_t need_staging = n_decode * row_bytes;
                        if (!triattention_gpu_ensure_buffer(
                                &state->d_k_staging, &state->k_staging_bytes, need_staging) ||
                            !triattention_gpu_gather_k_rows(
                                state->d_k_staging, k_host_base, row_bytes,
                                decode_cell_idx.data(), n_decode,
                                (uint32_t) kt->ne[1])) {
                            fprintf(stderr,
                                "[TriAttention] GPU host-KV staging failed for layer %u\n", layer_idx);
                            gpu_ok = false;
                            break;
                        }
                        last_staged_ikv = ikv;
                    }
                    k_ptr = state->d_k_staging;
                    k_rows_compact = true;
                }

                if (!triattention_gpu_score_head(
                        (triattention_gpu_state *)state->d_gpu_state,
                        k_ptr,
                        n_embd,
                        row_bytes,
                        kv_head,
                        sh,
                        score_hd,
                        k_rows_compact,
                        d_cell_indices,
                        d_positions,
                        n_decode,
                        (int64_t)state->absolute_position,
                        (int)cfg.agg,
                        d_scores_all + (size_t)sh * n_decode,
                        nullptr)) {
                    fprintf(stderr, "[TriAttention] GPU score_head failed for layer %u head %u\n",
                            layer_idx, attn_head);
                    gpu_ok = false;
                }
            }

            if (gpu_ok &&
                !triattention_gpu_scores_to_host(
                    score_buf, d_scores_all,
                    (uint32_t)((size_t)cal->n_sampled * n_decode), nullptr)) {
                fprintf(stderr, "[TriAttention] GPU scores D2H failed\n");
                gpu_ok = false;
            }

            if (!gpu_ok) {
                fprintf(stderr, "[TriAttention] GPU scoring failed, using CPU scoring\n");
                triattention_iswa_note_gpu_failure();
                state->use_gpu = false;
                triattention_gpu_free((triattention_gpu_state *)state->d_gpu_state);
                state->d_gpu_state = nullptr;
                if (state->d_scores) {
                    triattention_gpu_free_dev(state->d_scores);
                    state->d_scores = nullptr;
                }
            } else {
                for (uint32_t sh = 0; sh < cal->n_sampled; sh++) {
                    const uint32_t layer_idx = cal->sampled_layer[sh];
                    if (layer_idx >= layer_in_subcache.size() || !layer_in_subcache[layer_idx]) {
                        memset(score_buf + (size_t)sh * n_decode, 0, n_decode * sizeof(float));
                        continue;
                    }
                    int32_t ikv = -1;
                    for (uint32_t l = 0; l < n_layers; l++) {
                        if (layer_map[l] == (int32_t) layer_idx) { ikv = (int32_t)l; break; }
                    }
                    if (ikv < 0) {
                        memset(score_buf + (size_t)sh * n_decode, 0, n_decode * sizeof(float));
                    }
                }
                gpu_scored = true;
            }
        }
        } // state->use_gpu && !triattention_iswa_gpu_blocked()
    }

    if (!gpu_scored) {
        // ---- CPU fallback path ----
        for (uint32_t sh = 0; sh < cal->n_sampled; sh++) {
            const uint32_t layer_idx = cal->sampled_layer[sh];
            if (layer_idx >= layer_in_subcache.size() || !layer_in_subcache[layer_idx]) {
                memset(score_buf + (size_t)sh * n_decode, 0, n_decode * sizeof(float));
                continue;
            }
            const uint32_t attn_head = cal->sampled_head[sh];
            const uint32_t cache_kv_groups = cal->num_attn_heads / state->cache_n_kv_heads;
            const uint32_t kv_head   = attn_head / cache_kv_groups;

            int32_t ikv = -1;
            for (uint32_t l = 0; l < n_layers; l++) {
                if (layer_map[l] == (int32_t) layer_idx) {
                    ikv = (int32_t)l;
                    break;
                }
            }
            if (ikv < 0) {
                memset(score_buf + (size_t)sh * n_decode, 0, n_decode * sizeof(float));
                continue;
            }

            const ggml_tensor * k_tensor = k_tensors[ikv];
            const ggml_type k_type_l = k_tensor->type;
            const bool need_wht_inv = (k_type_l == GGML_TYPE_TURBO2_0 || k_type_l == GGML_TYPE_TURBO3_0);

            // TRIX-03: per-layer padded head dim from KV tensor layout (not cal head_dim)
            if (state->cache_n_kv_heads == 0 || k_tensor->ne[0] % state->cache_n_kv_heads != 0) {
                fprintf(stderr, "[TriAttention] ERROR: bad K tensor layout for layer %u\n", layer_idx);
                memset(score_buf + (size_t)sh * n_decode, 0, n_decode * sizeof(float));
                continue;
            }
            const uint32_t layer_padded_hd =
                (uint32_t)(k_tensor->ne[0] / (uint64_t) state->cache_n_kv_heads);
            if (layer_padded_hd > state->padded_cache_hd) {
                fprintf(stderr, "[TriAttention] ERROR: layer %u head dim %u exceeds buffer %u\n",
                        layer_idx, layer_padded_hd, state->padded_cache_hd);
                memset(score_buf + (size_t)sh * n_decode, 0, n_decode * sizeof(float));
                continue;
            }

            const uint32_t score_hd = state->projection_mode ? cal->head_dim : layer_padded_hd;

            // 3a. Dequantize K for this KV head for all decode cells
            triattention_dequant_kv_head(
                state->dequant_buf,
                k_tensor,
                decode_cell_idx.data(),
                kv_head,
                n_decode,
                layer_padded_hd,
                state->cache_n_kv_heads,
                need_wht_inv);

            float * pre_rope_k = state->dequant_buf;
            if (state->projection_mode) {
                // Truncate 2:1 cache→cal head projection (Gemma4 ISWA base interim path).
                for (uint32_t ci = 0; ci < n_decode; ci++) {
                    float * dst = state->dequant_buf + (size_t) ci * score_hd;
                    const float * src = state->dequant_buf + (size_t) ci * layer_padded_hd;
                    if (dst != src) {
                        memmove(dst, src, (size_t) score_hd * sizeof(float));
                    }
                }
                pre_rope_k = state->dequant_buf;
            }

            // 3b. Invert RoPE → pre-RoPE K
            triattention_invert_rope(
                state->unrot_buf,
                pre_rope_k,
                decode_positions.data(),
                state->omega,
                n_decode,
                score_hd,
                fc,
                cal->rope_style);

            // 3c. Score keys (TRIX-08: rope_style selects half vs interleaved layout)
            triattention_score_keys(
                score_buf + (size_t)sh * n_decode,
                state->unrot_buf,
                &cal->head_stats[sh],
                state->omega,
                state->freq_scale_sq,
                state->offsets,
                decode_positions.data(),
                state->absolute_position,
                n_decode,
                score_hd,
                fc,
                state->n_offsets,
                cfg.agg,
                cfg.disable_trig,
                cal->rope_style);
        }
    }

    // ---- Step 4: Mode-dependent selection (TRIX-02/06/07) + buckets (TRIX-19) ----
    std::vector<bool> keep_set;
    triattention_select_decode_tokens(
        cfg,
        cal,
        state->cache_n_kv_heads,
        (uint32_t) state->total_prune_calls,
        score_buf,
        n_decode,
        decode_budget,
        decode_positions.data(),
        keep_set);

    // ---- Step 5: Build keep set and evict ----

    // Evict cells not in keep set
    uint32_t n_evicted = 0;
    for (uint32_t i = 0; i < n_decode; i++) {
        if (!keep_set[i]) {
            uint32_t cell_idx = decode_cell_idx[i];
            state->cell_positions[cell_idx] = -1;
            n_evicted++;
        }
    }

    // ---- Step 6: Update statistics ----
    double t_end = triattention_time_ms();
    state->total_prune_calls++;
    state->total_tokens_evicted += n_evicted;
    state->last_prune_time_ms = t_end - t_start;
    state->total_prune_time_ms += state->last_prune_time_ms;

    if (cfg.enable_logging) {
        fprintf(stderr, "[TriAttention] Pruned: %u → %u tokens (%u evicted, %u protected [prefix=%lld, recent=%d]), "
                "%.2f ms [%s], pos=%lld\n",
                n_occupied, n_occupied - n_evicted, n_evicted, n_protected,
                (long long)state->prefix_length, (int)recent_window,
                state->last_prune_time_ms, state->use_gpu ? "GPU" : "CPU",
                (long long)state->absolute_position);
    }

    return (int32_t)n_evicted;
}

// ============================================================================
// Monitoring
// ============================================================================

void triattention_print_stats(const triattention_state * state, FILE * stream) {
    if (!state) return;

    fprintf(stream, "\n=== TriAttention Statistics ===\n");
    fprintf(stream, "  Model:            %s\n", state->cal->model_name);
    fprintf(stream, "  Budget:           %u tokens\n", state->cfg.budget);
    fprintf(stream, "  Pruning interval: %u tokens\n", state->cfg.divide_length);
    fprintf(stream, "  Pruning mode:     %s\n",
            state->cfg.mode == TRIATTENTION_MODE_GLOBAL         ? "global (union)" :
            state->cfg.mode == TRIATTENTION_MODE_PER_KV_HEAD    ? "per-KV-head" :
            state->cfg.mode == TRIATTENTION_MODE_PER_LAYER_HEAD ? "per-layer-per-head" : "unknown");
    fprintf(stream, "  Score aggregation: %s\n",
            state->cfg.agg == TRIATTENTION_AGG_MEAN ? "mean" : "max");
    fprintf(stream, "  Sampled heads:    %u of %u\n", state->cal->n_sampled, state->cal->num_attn_heads);
    fprintf(stream, "  Geometric offsets: %u (max %u)\n", state->n_offsets, state->cfg.offset_max);
    fprintf(stream, "  ---\n");
    fprintf(stream, "  Total prune calls:    %llu\n", (unsigned long long)state->total_prune_calls);
    fprintf(stream, "  Total tokens evicted: %llu\n", (unsigned long long)state->total_tokens_evicted);
    fprintf(stream, "  Total prune time:     %.2f ms\n", state->total_prune_time_ms);
    if (state->total_prune_calls > 0) {
        fprintf(stream, "  Avg time per prune:   %.2f ms\n",
                state->total_prune_time_ms / state->total_prune_calls);
        fprintf(stream, "  Avg tokens per prune: %.1f\n",
                (double)state->total_tokens_evicted / state->total_prune_calls);
    }
    fprintf(stream, "  Last prune time:      %.2f ms\n", state->last_prune_time_ms);
    fprintf(stream, "  Current position:     %lld\n", (long long)state->absolute_position);
    fprintf(stream, "===============================\n\n");
}
