#include "llama-triattention.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static void require(bool cond, const char * msg) {
    if (!cond) {
        std::fprintf(stderr, "test-triattention-modes: %s\n", msg);
        std::abort();
    }
}

static triattention_calibration * make_cal(uint32_t n_sampled, uint32_t n_kv_heads) {
    auto * cal = new triattention_calibration();
    std::memset(cal, 0, sizeof(*cal));
    cal->head_dim       = 128;
    cal->num_layers     = 4;
    cal->num_attn_heads = n_kv_heads * 4;
    cal->num_kv_heads   = n_kv_heads;
    cal->num_kv_groups  = 4;
    cal->freq_count     = 64;
    cal->n_sampled      = n_sampled;
    cal->sampled_layer  = new uint32_t[n_sampled];
    cal->sampled_head   = new uint32_t[n_sampled];
    for (uint32_t sh = 0; sh < n_sampled; sh++) {
        cal->sampled_layer[sh] = sh % cal->num_layers;
        cal->sampled_head[sh]  = sh % cal->num_attn_heads;
    }
    return cal;
}

static void test_global_union_differs_from_plain_max() {
    const uint32_t n_sampled = 2;
    const uint32_t n_decode  = 4;
    const uint32_t budget    = 2;
    auto * cal = make_cal(n_sampled, 2);

    triattention_config cfg = {};
    cfg.mode    = TRIATTENTION_MODE_GLOBAL;
    cfg.buckets = 1;
    cfg.seed    = -1;

    std::vector<float> scores((size_t) n_sampled * n_decode);
    // Both heads rank 0,1 highest locally, but token 2 has the global max-over-heads #3 score.
    // Plain max-over-heads top-2 would keep {0,2}; union keeps {0,1}.
    scores[0 * n_decode + 0] = 10.0f;
    scores[0 * n_decode + 1] =  9.0f;
    scores[0 * n_decode + 2] =  8.0f;
    scores[0 * n_decode + 3] =  7.0f;
    scores[1 * n_decode + 0] =  6.0f;
    scores[1 * n_decode + 1] =  5.0f;
    scores[1 * n_decode + 2] =  4.0f;
    scores[1 * n_decode + 3] =  3.0f;

    std::vector<bool> keep;
    triattention_select_decode_tokens(cfg, cal, 2, 0, scores.data(), n_decode, budget, nullptr, keep);

    require(keep[0] && keep[1] && !keep[2], "global union must not admit token 2 without a per-head top-B pick");

    uint32_t n_keep = 0;
    for (bool k : keep) {
        if (k) {
            n_keep++;
        }
    }
    require(n_keep == budget, "global union must retain exactly decode_budget tokens");

    delete[] cal->sampled_layer;
    delete[] cal->sampled_head;
    delete cal;
}

static void test_per_kv_head_union_exceeds_single_budget() {
    const uint32_t n_sampled = 4;
    const uint32_t n_decode  = 4;
    const uint32_t budget    = 1;
    auto * cal = make_cal(n_sampled, 2);
    // GQA groups of 4: attn 0-3 → kv0, 4-7 → kv1 — must sample both KV heads.
    cal->sampled_head[0] = 0;
    cal->sampled_head[1] = 1;
    cal->sampled_head[2] = 4;
    cal->sampled_head[3] = 5;

    triattention_config cfg = {};
    cfg.mode    = TRIATTENTION_MODE_PER_KV_HEAD;
    cfg.buckets = 1;
    cfg.seed    = -1;

    std::vector<float> scores((size_t) n_sampled * n_decode, 0.0f);
    for (uint32_t sh = 0; sh < n_sampled; sh++) {
        const uint32_t winner = sh % n_decode;
        scores[(size_t) sh * n_decode + winner] = 10.0f - (float) sh;
    }

    std::vector<bool> keep;
    triattention_select_decode_tokens(cfg, cal, 2, 0, scores.data(), n_decode, budget, nullptr, keep);

    uint32_t n_keep = 0;
    for (bool k : keep) {
        if (k) {
            n_keep++;
        }
    }
    require(n_keep >= 2, "per-KV-head union should keep at least one token per KV head");

    delete[] cal->sampled_layer;
    delete[] cal->sampled_head;
    delete cal;
}

static void test_per_layer_head_union() {
    const uint32_t n_sampled = 3;
    const uint32_t n_decode  = 6;
    const uint32_t budget    = 1;
    auto * cal = make_cal(n_sampled, 1);

    triattention_config cfg = {};
    cfg.mode    = TRIATTENTION_MODE_PER_LAYER_HEAD;
    cfg.buckets = 1;
    cfg.seed    = -1;

    std::vector<float> scores((size_t) n_sampled * n_decode, 0.0f);
    for (uint32_t sh = 0; sh < n_sampled; sh++) {
        scores[(size_t) sh * n_decode + sh] = 5.0f;
    }

    std::vector<bool> keep;
    triattention_select_decode_tokens(cfg, cal, 1, 0, scores.data(), n_decode, budget, nullptr, keep);

    uint32_t n_keep = 0;
    for (bool k : keep) {
        if (k) {
            n_keep++;
        }
    }
    require(n_keep == n_sampled, "per-layer-head union should keep each head's top pick");

    delete[] cal->sampled_layer;
    delete[] cal->sampled_head;
    delete cal;
}

static void test_buckets_partition_budget() {
    const uint32_t n_sampled = 1;
    const uint32_t n_decode  = 4;
    const uint32_t budget    = 4;
    auto * cal = make_cal(n_sampled, 1);

    triattention_config cfg = {};
    cfg.mode    = TRIATTENTION_MODE_GLOBAL;
    cfg.buckets = 4;
    cfg.seed    = -1;

    // One decode candidate per position bucket (span 0..30, 4 buckets).
    std::vector<int32_t> positions = { 0, 10, 20, 30 };

    std::vector<float> scores((size_t) n_sampled * n_decode);
    for (uint32_t i = 0; i < n_decode; i++) {
        scores[i] = (float) i;
    }

    std::vector<bool> keep;
    triattention_select_decode_tokens(
        cfg, cal, 1, 0, scores.data(), n_decode, budget, positions.data(), keep);

    uint32_t n_keep = 0;
    for (bool k : keep) {
        if (k) {
            n_keep++;
        }
    }
    require(n_keep == budget, "bucketed selection should honor total decode budget");

    // Each position bucket (0,10,20,30) should contribute one survivor.
    for (uint32_t i = 0; i < n_decode; i++) {
        require(keep[i], "each position bucket should retain at least one token");
    }

    delete[] cal->sampled_layer;
    delete[] cal->sampled_head;
    delete cal;
}

int main() {
    test_global_union_differs_from_plain_max();
    test_per_kv_head_union_exceeds_single_budget();
    test_per_layer_head_union();
    test_buckets_partition_budget();
    std::fprintf(stderr, "test-triattention-modes: all tests passed\n");
    return 0;
}