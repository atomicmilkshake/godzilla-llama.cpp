#include "llama-triattention.h"
#include "llama-arch.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static void require(bool cond, const char * msg) {
    if (!cond) {
        std::fprintf(stderr, "test-triattention-cal-v2: %s\n", msg);
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
    return std::string(tmp) + "\\tri_test_" + suffix;
}

static void write_v1_file(const std::string & path, uint32_t head_dim) {
    FILE * f = fopen(path.c_str(), "wb");
    require(f != nullptr, "fopen v1 failed");

    const uint32_t fc = head_dim / 2;
    const char * name = "synthetic-v1";
    const uint32_t name_len = (uint32_t) strlen(name) + 1;

    write_u32(f, TRIATTENTION_MAGIC);
    write_u32(f, TRIATTENTION_VERSION);
    write_u32(f, head_dim);
    write_u32(f, 4);   // num_layers
    write_u32(f, 8);   // num_attn_heads
    write_u32(f, 2);   // num_kv_heads
    write_f64(f, 10000.0);
    write_u32(f, 0);   // rope_style half
    write_u32(f, 1);   // n_sampled
    write_u32(f, fc);
    write_u32(f, name_len);
    require(fwrite(name, 1, name_len, f) == name_len, "v1 name write failed");

    write_u32(f, 0); // layer 0
    write_u32(f, 0); // head 0
    write_head_stats(f, fc, 1.0f);

    fclose(f);
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

static void write_v2_file(const std::string & path) {
    FILE * f = fopen(path.c_str(), "wb");
    require(f != nullptr, "fopen v2 failed");

    const char * name = "synthetic-gemma4-v2";
    const uint32_t name_len = (uint32_t) strlen(name) + 1;
    const uint32_t n_profiles = 2;
    const uint32_t n_layers = 4;

    write_u32(f, TRIATTENTION_MAGIC);
    write_u32(f, TRIATTENTION_VERSION_V2);
    write_u32(f, n_profiles);
    write_u32(f, 0); // rope_style
    write_u32(f, name_len);
    require(fwrite(name, 1, name_len, f) == name_len, "v2 name write failed");
    write_u32(f, 0);
    write_u32(f, 0);
    write_u32(f, 0);
    write_u32(f, 0);

    write_v2_profile(f, TRI_PROFILE_ISWA_BASE, 512, n_layers, 8, 1, 1000000.0,
        {0, 2}, 2.0f);
    write_v2_profile(f, TRI_PROFILE_ISWA_SWA, 256, n_layers, 8, 8, 10000.0,
        {1, 3}, 3.0f);

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

static void test_v1_homogeneous_load() {
    const std::string path = temp_path("v1_256.triattention");
    write_v1_file(path, 256);

    triattention_config cfg = default_cfg();
    triattention_state * st = triattention_init(path.c_str(), &cfg, 256, 10000.0, 256, 2, nullptr);
    require(st != nullptr, "v1 homogeneous init failed");
    require(st->cal->head_dim == 256, "v1 head_dim mismatch");
    require(!st->projection_mode, "v1 should not use projection");
    triattention_free(st);
    std::remove(path.c_str());
}

static void test_v1_projection_gemma4() {
    const std::string path = temp_path("v1_proj.triattention");
    write_v1_file(path, 256);

    triattention_config cfg = default_cfg();
    triattention_init_opts opts = {};
    opts.projection_flags = TRI_PROJECTION_AUTO_GEMMA4;
    opts.model_arch = (int32_t) LLM_ARCH_GEMMA4;
    opts.profile_pref = TRI_PROFILE_PREF_ISWA_BASE;

    triattention_state * st = triattention_init(path.c_str(), &cfg, 256, 10000.0, 512, 1, &opts);
    require(st != nullptr, "v1 projection base init failed");
    require(st->projection_mode, "projection should be active for 512 cache + 256 cal");
    require(st->cache_head_dim == 512, "cache head dim should be 512");
    require(st->padded_cache_hd == 512, "padded cache hd should be 512");
    triattention_free(st);
    std::remove(path.c_str());
}

static void test_v1_projection_reject() {
    const std::string path = temp_path("v1_reject.triattention");
    write_v1_file(path, 256);

    triattention_config cfg = default_cfg();
    triattention_init_opts opts = {};
    opts.projection_flags = TRI_PROJECTION_OFF;
    opts.model_arch = (int32_t) LLM_ARCH_GEMMA4;

    triattention_state * st = triattention_init(path.c_str(), &cfg, 256, 10000.0, 512, 1, &opts);
    require(st == nullptr, "v1 without projection should fail on 512 cache");
    std::remove(path.c_str());
}

static void test_v2_profile_pick_base_swa() {
    const std::string path = temp_path("v2_hybrid.triattention");
    write_v2_file(path);

    triattention_config cfg = default_cfg();

    const int32_t base_layers[] = {0, 2};
    triattention_init_opts base_opts = {};
    base_opts.profile_pref = TRI_PROFILE_PREF_ISWA_BASE;
    base_opts.managed_layers = base_layers;
    base_opts.n_managed_layers = 2;

    triattention_state * base_st = triattention_init(
        path.c_str(), &cfg, 256, 1000000.0, 512, 1, &base_opts);
    require(base_st != nullptr, "v2 base profile init failed");
    require(base_st->cal->profile_tag == TRI_PROFILE_ISWA_BASE, "expected ISWA_BASE tag");
    require(base_st->cal->head_dim == 512, "base profile head_dim should be 512");
    require(!base_st->projection_mode, "v2 base should not use projection");
    triattention_free(base_st);

    const int32_t swa_layers[] = {1, 3};
    triattention_init_opts swa_opts = {};
    swa_opts.profile_pref = TRI_PROFILE_PREF_ISWA_SWA;
    swa_opts.managed_layers = swa_layers;
    swa_opts.n_managed_layers = 2;

    triattention_state * swa_st = triattention_init(
        path.c_str(), &cfg, 256, 10000.0, 256, 8, &swa_opts);
    require(swa_st != nullptr, "v2 SWA profile init failed");
    require(swa_st->cal->profile_tag == TRI_PROFILE_ISWA_SWA, "expected ISWA_SWA tag");
    require(swa_st->cal->head_dim == 256, "SWA profile head_dim should be 256");
    triattention_free(swa_st);

    std::remove(path.c_str());
}

static void test_corrupt_magic_rejected() {
    const std::string path = temp_path("bad_magic.triattention");
    FILE * f = fopen(path.c_str(), "wb");
    require(f != nullptr, "fopen corrupt failed");
    write_u32(f, 0xDEADBEEFu);
    write_u32(f, TRIATTENTION_VERSION);
    fclose(f);

    triattention_config cfg = default_cfg();
    triattention_state * st = triattention_init(path.c_str(), &cfg, 128, 10000.0, 128, 4, nullptr);
    require(st == nullptr, "corrupt magic should fail load");
    std::remove(path.c_str());
}

int main() {
    test_v1_homogeneous_load();
    test_v1_projection_gemma4();
    test_v1_projection_reject();
    test_v2_profile_pick_base_swa();
    test_corrupt_magic_rejected();
    std::fprintf(stderr, "test-triattention-cal-v2: all tests passed\n");
    return 0;
}