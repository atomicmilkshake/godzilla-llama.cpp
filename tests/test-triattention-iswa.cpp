#include "llama-triattention.h"
#include "llama-arch.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static const char * ondisk_v2_cal_path() {
    const char * p = std::getenv("GODZILLA_TRIATTENTION_TEST_CALIB");
    return (p && p[0]) ? p : nullptr;
}

static void require(bool cond, const char * msg) {
    if (!cond) {
        std::fprintf(stderr, "test-triattention-iswa: %s\n", msg);
        std::abort();
    }
}

static void write_u32(FILE * f, uint32_t v) {
    require(fwrite(&v, sizeof(v), 1, f) == 1, "write_u32 failed");
}

static void write_f64(FILE * f, double v) {
    require(fwrite(&v, sizeof(v), 1, f) == 1, "write_f64 failed");
}

static void write_head_stats(FILE * f, uint32_t fc, float seed) {
    std::vector<float> buf(fc);
    for (uint32_t i = 0; i < fc; i++) {
        buf[i] = seed + (float) i * 0.01f;
    }
    require(fwrite(buf.data(), sizeof(float), fc, f) == fc, "q_mean_real write failed");
    for (uint32_t i = 0; i < fc; i++) {
        buf[i] = seed * 0.5f + (float) i * 0.02f;
    }
    require(fwrite(buf.data(), sizeof(float), fc, f) == fc, "q_mean_imag write failed");
    for (uint32_t i = 0; i < fc; i++) {
        buf[i] = 1.0f + seed + (float) i * 0.001f;
    }
    require(fwrite(buf.data(), sizeof(float), fc, f) == fc, "q_abs_mean write failed");
    for (uint32_t i = 0; i < fc; i++) {
        buf[i] = 0.9f;
    }
    require(fwrite(buf.data(), sizeof(float), fc, f) == fc, "r_f write failed");
}

static std::string temp_path(const char * suffix) {
    const char * tmp = std::getenv("TEMP");
    if (!tmp || !tmp[0]) {
        tmp = std::getenv("TMP");
    }
    if (!tmp || !tmp[0]) {
        tmp = ".";
    }
    return std::string(tmp) + "\\tri_iswa_" + suffix;
}

static void write_v2_profile(
        FILE * f,
        uint32_t tag,
        uint32_t head_dim,
        uint32_t n_layers,
        uint32_t n_attn,
        uint32_t n_kv,
        double rope_theta,
        const std::vector<uint32_t> & layer_indices,
        float seed) {
    const uint32_t fc = head_dim / 2;
    const uint32_t n_sampled = 1;
    const uint32_t layer_begin = layer_indices.empty() ? 0 : layer_indices.front();
    const uint32_t layer_end = layer_indices.empty() ? 0 : (layer_indices.back() + 1);

    std::vector<uint32_t> mask((n_layers + 31) / 32, 0);
    for (uint32_t il : layer_indices) {
        mask[il / 32] |= 1u << (il % 32);
    }

    write_u32(f, tag);
    write_u32(f, head_dim);
    write_u32(f, n_layers);
    write_u32(f, n_attn);
    write_u32(f, n_kv);
    write_f64(f, rope_theta);
    write_u32(f, layer_begin);
    write_u32(f, layer_end);
    write_u32(f, (uint32_t) mask.size());
    for (uint32_t word : mask) {
        write_u32(f, word);
    }
    write_u32(f, n_sampled);
    write_u32(f, fc);
    write_u32(f, layer_indices.empty() ? 0 : layer_indices[0]);
    write_u32(f, 0);
    write_head_stats(f, fc, seed);
}

static void write_synthetic_v2_file(const std::string & path) {
    FILE * f = fopen(path.c_str(), "wb");
    require(f != nullptr, "fopen synthetic v2 failed");

    const char * name = "synthetic-gemma4-iswa";
    const uint32_t name_len = (uint32_t) strlen(name) + 1;
    const uint32_t n_profiles = 2;
    const uint32_t n_layers = 6;

    write_u32(f, TRIATTENTION_MAGIC);
    write_u32(f, TRIATTENTION_VERSION_V2);
    write_u32(f, n_profiles);
    write_u32(f, 0);
    write_u32(f, name_len);
    require(fwrite(name, 1, name_len, f) == name_len, "v2 name write failed");
    write_u32(f, 0);
    write_u32(f, 0);
    write_u32(f, 0);
    write_u32(f, 0);

    write_v2_profile(f, TRI_PROFILE_ISWA_BASE, 512, n_layers, 16, 1, 1000000.0,
        {0, 2, 4}, 2.0f);
    write_v2_profile(f, TRI_PROFILE_ISWA_SWA, 256, n_layers, 16, 8, 10000.0,
        {1, 3, 5}, 3.0f);

    fclose(f);
}

static triattention_config default_cfg() {
    triattention_config cfg = {};
    cfg.budget = 128;
    cfg.divide_length = 64;
    cfg.offset_max = 1024;
    cfg.mode = TRIATTENTION_MODE_GLOBAL;
    cfg.trigger = TRIATTENTION_TRIGGER_INTERVAL;
    cfg.agg = TRIATTENTION_AGG_MEAN;
    cfg.protect_prefill = true;
    cfg.hard_prefix = 0;
    cfg.buckets = 8;
    return cfg;
}

static triattention_init_opts iswa_sub_opts(
        bool is_swa_sub,
        const int32_t * managed_layers,
        uint32_t n_managed_layers) {
    triattention_init_opts opts = {};
    opts.profile_pref = is_swa_sub ? TRI_PROFILE_PREF_ISWA_SWA : TRI_PROFILE_PREF_ISWA_BASE;
    opts.projection_flags = TRI_PROJECTION_OFF;
    opts.model_arch = (int32_t) LLM_ARCH_GEMMA4;
    opts.managed_layers = managed_layers;
    opts.n_managed_layers = n_managed_layers;
    return opts;
}

static triattention_state * init_iswa_sub(
        const char * path,
        bool is_swa_sub,
        const int32_t * managed_layers,
        uint32_t n_managed_layers,
        uint32_t head_dim,
        uint32_t n_kv_heads,
        double rope_theta) {
    triattention_config cfg = default_cfg();
    triattention_init_opts opts = iswa_sub_opts(is_swa_sub, managed_layers, n_managed_layers);
    return triattention_init(path, &cfg, 256, rope_theta, head_dim, n_kv_heads, &opts);
}

static void test_synthetic_dual_sub_init() {
    const std::string path = temp_path("dual_v2.triattention");
    write_synthetic_v2_file(path);

    const int32_t base_layers[] = {0, 2, 4};
    triattention_state * base_st = init_iswa_sub(
        path.c_str(), false, base_layers, 3, 512, 1, 1000000.0);
    require(base_st != nullptr, "synthetic base ISWA init failed");
    require(base_st->cal->profile_tag == TRI_PROFILE_ISWA_BASE, "synthetic base tag mismatch");
    require(base_st->cal->head_dim == 512, "synthetic base head_dim should be 512");
    require(!base_st->projection_mode, "synthetic base must not use projection");
    require(base_st->cache_head_dim == 512, "synthetic base cache head_dim should be 512");
    triattention_free(base_st);

    const int32_t swa_layers[] = {1, 3, 5};
    triattention_state * swa_st = init_iswa_sub(
        path.c_str(), true, swa_layers, 3, 256, 8, 10000.0);
    require(swa_st != nullptr, "synthetic SWA ISWA init failed");
    require(swa_st->cal->profile_tag == TRI_PROFILE_ISWA_SWA, "synthetic SWA tag mismatch");
    require(swa_st->cal->head_dim == 256, "synthetic SWA head_dim should be 256");
    require(!swa_st->projection_mode, "synthetic SWA must not use projection");
    require(swa_st->cache_head_dim == 256, "synthetic SWA cache head_dim should be 256");
    triattention_free(swa_st);

    std::remove(path.c_str());
}

static bool file_exists(const char * path) {
    FILE * f = fopen(path, "rb");
    if (!f) {
        return false;
    }
    fclose(f);
    return true;
}

static void test_ondisk_gemma4_v2_dual_init() {
    const char * ondisk_cal = ondisk_v2_cal_path();
    if (!ondisk_cal || !file_exists(ondisk_cal)) {
        std::fprintf(stderr,
            "test-triattention-iswa: skip on-disk cal (set GODZILLA_TRIATTENTION_TEST_CALIB)\n");
        return;
    }

    const int32_t base_layers[] = {5, 11, 17};
    triattention_state * base_st = init_iswa_sub(
        ondisk_cal, false, base_layers, 3, 512, 1, 1000000.0);
    require(base_st != nullptr, "on-disk base ISWA init failed");
    require(base_st->cal->profile_tag == TRI_PROFILE_ISWA_BASE, "on-disk base tag mismatch");
    require(base_st->cal->head_dim == 512, "on-disk base head_dim should be 512");
    require(!base_st->projection_mode, "on-disk base must not use projection");
    triattention_free(base_st);

    const int32_t swa_layers[] = {0, 1, 2, 3};
    triattention_state * swa_st = init_iswa_sub(
        ondisk_cal, true, swa_layers, 4, 256, 8, 10000.0);
    require(swa_st != nullptr, "on-disk SWA ISWA init failed");
    require(swa_st->cal->profile_tag == TRI_PROFILE_ISWA_SWA, "on-disk SWA tag mismatch");
    require(swa_st->cal->head_dim == 256, "on-disk SWA head_dim should be 256");
    require(!swa_st->projection_mode, "on-disk SWA must not use projection");
    triattention_free(swa_st);
}

static void test_iswa_prune_scope_single_sync(void) {
    triattention_iswa_prune_scope_begin();
    require(!triattention_iswa_gpu_blocked(), "scope begin must clear gpu block");
    triattention_iswa_note_gpu_failure();
    require(triattention_iswa_gpu_blocked(), "note_gpu_failure must block SWA GPU");
    triattention_iswa_prune_scope_end();
    require(triattention_iswa_gpu_blocked(), "block persists until next ubatch scope");
    triattention_iswa_prune_scope_begin();
    require(!triattention_iswa_gpu_blocked(), "next ubatch scope must clear block");
    triattention_iswa_prune_scope_end();
}

int main() {
    test_synthetic_dual_sub_init();
    test_ondisk_gemma4_v2_dual_init();
    test_iswa_prune_scope_single_sync();
    std::fprintf(stderr, "test-triattention-iswa: all tests passed\n");
    return 0;
}