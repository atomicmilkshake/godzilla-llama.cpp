#include "ggml.h"
#include "ggml-quants.h"
#include "ggml-impl.h"

#include <assert.h>
#include <math.h>
#include <string.h>

void ggml_vec_dot_i2_i8_s(int n, float * s, size_t bs, const void * vx, size_t bx, const void * vy, size_t by, int nrc);

// Microsoft BitNet I2_S / I8_S quant helpers (from Eddie-Wang ggml-quants.c)

static inline int bitnet_nearest_int(float fval) {
    assert(fabsf(fval) <= 4194303.f);
    float val = fval + 12582912.f;
    int i;
    memcpy(&i, &val, sizeof(int));
    return (i & 0x007fffff) - 0x00400000;
}

void dequantize_row_i2_s(const uint8_t * x, float * y, int64_t n, const float i2_scale) {
    static const float map2bit[4] = { -1.0f, 0.0f, +1.0f, 0.0f };

    int64_t done = 0;
    while (done < n) {
        const int64_t blk_e = (n - done >= 128) ? 128 : (n - done);
        const int64_t cols0 = blk_e >= 32 ? 32 : blk_e;
        const int64_t cols1 = blk_e >= 64 ? 32 : MAX(0, blk_e - 32);
        const int64_t cols2 = blk_e >= 96 ? 32 : MAX(0, blk_e - 64);
        const int64_t cols3 = blk_e >= 128 ? 32 : MAX(0, blk_e - 96);

        for (int gp = 0; gp < 32; ++gp) {
            const uint8_t b = x[gp];

            const uint8_t c0 = (b >> 6) & 0x3;
            const uint8_t c1 = (b >> 4) & 0x3;
            const uint8_t c2 = (b >> 2) & 0x3;
            const uint8_t c3 = (b >> 0) & 0x3;

            if (gp < cols0) y[done + 0*32 + gp] = i2_scale * map2bit[c0];
            if (gp < cols1) y[done + 1*32 + gp] = i2_scale * map2bit[c1];
            if (gp < cols2) y[done + 2*32 + gp] = i2_scale * map2bit[c2];
            if (gp < cols3) y[done + 3*32 + gp] = i2_scale * map2bit[c3];
        }

        x    += 32;
        done += blk_e;
    }
}

void quantize_row_i8_s(const float * x, void * y, int64_t n, float * act_scales, int32_t * act_sums) {
    int8_t * dst = (int8_t *) y;
    double max = 0.00001;
    for (int64_t i = 0; i < n; ++i) {
        max = MAX(max, (double) fabs((double) x[i]));
    }
    const float s = (float) (127.0 / max);
    act_scales[0] = s;
    int32_t sum = 0;
    for (int64_t i = 0; i < n; ++i) {
        int v = bitnet_nearest_int(x[i] * s);
        if (v >  127) v = 127;
        if (v < -128) v = -128;
        sum += v;
        dst[i] = (int8_t) v;
    }
    act_sums[0] = sum;
}

void ggml_gemv_i2_i8_s(int n, float * GGML_RESTRICT s, size_t bs, const void * GGML_RESTRICT vx, const void * GGML_RESTRICT vy, int nr, int nc) {
    GGML_UNUSED(bs);
    GGML_UNUSED(nr);
    const int64_t blck_0 = 16;
    for (int64_t iir0 = 0; iir0 < nc; iir0 += blck_0) {
        ggml_vec_dot_i2_i8_s(n, s + iir0, 1, (const char *) vx + iir0 * n / 4, n, vy, 0, MIN(blck_0, nc - iir0));
    }
}

void ggml_gemm_i2_i8_s(int n, float * GGML_RESTRICT s, size_t bs, const void * GGML_RESTRICT vx, const void * GGML_RESTRICT vy, int nr, int nc) {
    GGML_UNUSED(bs);
    for (int64_t iir0 = 0; iir0 < nc; iir0 += 4) {
        ggml_vec_dot_i2_i8_s(n, s + iir0 * nr, 1, (const char *) vx + iir0 * n / 4, n, (const char *) vy + iir0 * n, 0, MIN(4, nc - iir0));
    }
}
