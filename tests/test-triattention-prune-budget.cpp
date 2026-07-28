#include "llama-triattention.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

static void require(bool cond, const char * msg) {
    if (!cond) {
        std::fprintf(stderr, "test-triattention-prune-budget: %s\n", msg);
        std::abort();
    }
}

static triattention_calibration * make_min_cal(uint32_t fc) {
    auto * cal = new triattention_calibration();
    std::memset(cal, 0, sizeof(*cal));
    cal->head_dim       = fc * 2;
    cal->num_layers     = 1;
    cal->num_attn_heads = 1;
    cal->num_kv_heads   = 1;
    cal->num_kv_groups  = 1;
    cal->rope_theta     = 10000.0;
    cal->rope_style     = 0;
    cal->freq_count     = fc;
    cal->n_sampled      = 1;
    cal->profile_tag    = TRI_PROFILE_DEFAULT;
    cal->sampled_layer  = new uint32_t[1]{ 0 };
    cal->sampled_head   = new uint32_t[1]{ 0 };
    cal->head_stats     = new triattention_head_stats[1];
    auto & hs = cal->head_stats[0];
    hs.q_mean_real  = new float[fc];
    hs.q_mean_imag  = new float[fc];
    hs.q_abs_mean   = new float[fc];
    hs.q_mean_abs   = new float[fc];
    hs.extra_weight = new float[fc];
    for (uint32_t f = 0; f < fc; f++) {
        hs.q_mean_real[f]  = 0.5f;
        hs.q_mean_imag[f]  = 0.1f;
        hs.q_abs_mean[f]   = 0.6f;
        hs.q_mean_abs[f]   = 0.55f;
        hs.extra_weight[f] = 0.05f;
    }
    std::strncpy(cal->model_name, "synthetic-prune", sizeof(cal->model_name) - 1);
    return cal;
}

static void test_decode_budget_zero_evicts_all() {
    const uint32_t kv_size = 10;
    const uint32_t fc = 64;
    auto * cal = make_min_cal(fc);

    triattention_config cfg = {};
    cfg.budget           = 4;
    cfg.divide_length    = 1;
    cfg.offset_max       = 64;
    cfg.mode             = TRIATTENTION_MODE_GLOBAL;
    cfg.trigger          = TRIATTENTION_TRIGGER_INTERVAL;
    cfg.agg              = TRIATTENTION_AGG_MEAN;
    cfg.protect_prefill  = false;
    cfg.hard_prefix      = 4;
    cfg.spec_protect_extra = 0;

    triattention_state * state = new triattention_state();
    std::memset(state, 0, sizeof(*state));
    state->cal = cal;
    state->cfg = cfg;
    state->kv_size = kv_size;
    state->cache_head_dim = cal->head_dim;
    state->padded_cache_hd = 128;
    state->cache_n_kv_heads = 1;
    state->score_freq_count = fc;
    state->absolute_position = 100;

    state->omega = new float[fc];
    for (uint32_t f = 0; f < fc; f++) {
        state->omega[f] = 1.0f / (float) (f + 1);
    }
    state->freq_scale_sq = new float[fc];
    for (uint32_t f = 0; f < fc; f++) {
        state->freq_scale_sq[f] = 1.0f;
    }
    state->offsets = new float[4]{ 1, 2, 4, 8 };
    state->n_offsets = 4;

    state->cell_positions = new int32_t[kv_size];
    for (uint32_t i = 0; i < kv_size; i++) {
        state->cell_positions[i] = (int32_t) i;
    }

    state->score_buf    = new float[(size_t) cal->n_sampled * kv_size];
    state->combined_buf = new float[kv_size];
    state->keep_indices = new uint32_t[cfg.budget];
    state->dequant_buf  = new float[(size_t) kv_size * state->padded_cache_hd];
    state->unrot_buf      = new float[(size_t) kv_size * state->padded_cache_hd];

    const int32_t layer_map[1] = { 0 };
    const int32_t n_evicted = triattention_prune_impl(
        state, nullptr, 0, layer_map, kv_size);

    // hard_prefix=4 protects pos 0-3; recent_window=1 protects pos 9 only
    require(n_evicted == 5, "expected 5 decode cells evicted when decode_budget==0");

    for (uint32_t i = 0; i < 4; i++) {
        require(state->cell_positions[i] == (int32_t) i, "hard-prefix cells should remain");
    }
    require(state->cell_positions[9] == 9, "recent cell should remain");
    for (uint32_t i = 4; i < 9; i++) {
        require(state->cell_positions[i] == -1, "decode cells should be evicted");
    }

    triattention_free(state);
}

int main() {
    test_decode_budget_zero_evicts_all();
    std::fprintf(stderr, "test-triattention-prune-budget: all tests passed\n");
    return 0;
}