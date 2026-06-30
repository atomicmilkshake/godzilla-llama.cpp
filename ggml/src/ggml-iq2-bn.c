// ik_llama.cpp IQ2_BN port for quant-god (CPU + CUDA inference path).
// Distinct from Microsoft BitNet I2_S (vendor/bitnet, GGML_TYPE_I2_S).
// Source reference: ik_llama.cpp ggml/src/iqk/iqk_quantize.cpp

#include "ggml-quants.h"
#include "ggml-common.h"

#include <assert.h>
#include <math.h>
#include <stdint.h>

#define QK_IQ1BN QK_IQ2BN
#define IQ2_BN_NJ (QK_IQ1BN / 4)
#define IQ2_BN_ROW_META 4

static inline int iq2_bn_nearest_int(float fval) {
    return (int) roundf(fval);
}

static void quantize_row_iq2_bn_impl(const float * GGML_RESTRICT x, void * GGML_RESTRICT vy, int64_t k) {
    assert(k % QK_IQ1BN == 0);

    const int nblock = (int) (k / QK_IQ1BN);

    float max = 0.0f;
    for (int64_t j = 0; j < k; ++j) {
        const float a = fabsf(x[j]);
        if (a > max) {
            max = a;
        }
    }

    float * dptr = (float *) vy;
    *dptr = max;
    block_iq2_bn * y = (block_iq2_bn *) (dptr + 1);

    const float thresh = 0.5f * max;
    uint8_t L[QK_IQ1BN];

    for (int ib = 0; ib < nblock; ++ib) {
        const float * xb = x + (int64_t) QK_IQ1BN * ib;
        for (int j = 0; j < QK_IQ1BN; ++j) {
            L[j] = fabsf(xb[j]) < thresh ? 1 : (xb[j] < 0 ? 0 : 2);
        }
        for (int j = 0; j < IQ2_BN_NJ; ++j) {
            y[ib].qs[j] = (uint8_t) (L[j] | (L[j + IQ2_BN_NJ] << 2) | (L[j + 2 * IQ2_BN_NJ] << 4) | (L[j + 3 * IQ2_BN_NJ] << 6));
        }
    }
}

void quantize_row_iq2_bn_ref(const float * GGML_RESTRICT x, block_iq2_bn * GGML_RESTRICT y, int64_t k) {
    quantize_row_iq2_bn_impl(x, y, k);
}

void quantize_row_iq2_bn(const float * GGML_RESTRICT x, void * GGML_RESTRICT y, int64_t k) {
    quantize_row_iq2_bn_impl(x, y, k);
}

void dequantize_row_iq2_bn(const block_iq2_bn * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k) {
    assert(k % QK_IQ1BN == 0);

    const int nblock = (int) (k / QK_IQ1BN);
    const float d1 = 1.0f;
    const float d2 = 0.25f;
    const float d3 = d2 * 0.25f;
    const float d4 = d3 * 0.25f;
    const float m  = -1.0f;

    for (int i = 0; i < nblock; ++i) {
        for (int j = 0; j < IQ2_BN_NJ; ++j) {
            y[j + 0           ] = d1 * (x[i].qs[j] & 0x03) + m;
            y[j + 1 * IQ2_BN_NJ] = d2 * (x[i].qs[j] & 0x0c) + m;
            y[j + 2 * IQ2_BN_NJ] = d3 * (x[i].qs[j] & 0x30) + m;
            y[j + 3 * IQ2_BN_NJ] = d4 * (x[i].qs[j] & 0xc0) + m;
        }
        y += QK_IQ1BN;
    }
}

void dequantize_row_iq2_bn_packed(const void * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k) {
    dequantize_row_iq2_bn((const block_iq2_bn *) ((const char *) x + IQ2_BN_ROW_META), y, k);
}

void quantize_row_q8_K64_ref(const float * GGML_RESTRICT x, block_q8_K64 * GGML_RESTRICT y, int64_t k) {
    assert(k >= 8 * QK_IQ1BN);

    float * dptr = (float *) y;
    int8_t * qs = (int8_t *) (dptr + 8);

    float aux[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    for (int j = 0; j < k; j += 16) {
        for (int i = 0; i < 4; ++i) {
            for (int l = 0; l < 4; ++l) {
                const float ax = fabsf(x[j + 4 * i + l]);
                aux[i] = aux[i] > ax ? aux[i] : ax;
            }
        }
    }
    for (int i = 0; i < 4; ++i) {
        dptr[i] = aux[i] / 127.0f;
        aux[i] = dptr[i] > 0.0f ? 1.0f / dptr[i] : 0.0f;
    }

    int32_t sum[4] = { 0, 0, 0, 0 };
    for (int j = 0; j < k; j += 16) {
        for (int i = 0; i < 4; ++i) {
            for (int l = 0; l < 4; ++l) {
                qs[j + 4 * i + l] = (int8_t) iq2_bn_nearest_int(aux[i] * x[j + 4 * i + l]);
                sum[i] += qs[j + 4 * i + l];
            }
        }
    }
    for (int i = 0; i < 4; ++i) {
        dptr[4 + i] = dptr[i] * (float) sum[i];
    }
}

void quantize_row_q8_K64(const float * GGML_RESTRICT x, void * GGML_RESTRICT y, int64_t k) {
    quantize_row_q8_K64_ref(x, (block_q8_K64 *) y, k);
}

void vec_dot_iq2_bn_q8_K64(int n, float * s, size_t bs, const void * vx, size_t bx, const void * vy, size_t by, int nrc) {
    GGML_ASSERT(nrc == 1);
    GGML_UNUSED(bs);
    GGML_UNUSED(bx);
    GGML_UNUSED(by);
    GGML_UNUSED(nrc);

    static_assert(QK_IQ1BN == 64, "iq2_bn vec_dot requires block size 64");

    #define IQ2_BN_VEC_DOT_NJ (QK_IQ1BN / 4)

    const block_iq2_bn * x = (const block_iq2_bn *) ((const char *) vx + IQ2_BN_ROW_META);
    const int nblock = n / QK_IQ1BN;

    const float * d = (const float *) vy;
    const int8_t * q8 = (const int8_t *) (d + 4);

    int sum[16] = { 0 };
    int sum0[4]  = { 0 };

    for (int i = 0; i < nblock; ++i) {
        for (int j = 0; j < IQ2_BN_VEC_DOT_NJ / 4; ++j) {
            for (int l = 0; l < 4; ++l) {
                sum[4 * j + 0] += q8[4 * j + l + 0    ] * (x[i].qs[4 * j + l] & 0x03);
                sum[4 * j + 1] += q8[4 * j + l + 1 * IQ2_BN_VEC_DOT_NJ] * (x[i].qs[4 * j + l] & 0x0c);
                sum[4 * j + 2] += q8[4 * j + l + 2 * IQ2_BN_VEC_DOT_NJ] * (x[i].qs[4 * j + l] & 0x30);
                sum[4 * j + 3] += q8[4 * j + l + 3 * IQ2_BN_VEC_DOT_NJ] * (x[i].qs[4 * j + l] & 0xc0);
                sum0[j] += q8[4 * j + l] + q8[4 * j + l + 1 * IQ2_BN_VEC_DOT_NJ] + q8[4 * j + l + 2 * IQ2_BN_VEC_DOT_NJ] + q8[4 * j + l + 3 * IQ2_BN_VEC_DOT_NJ];
            }
        }
        q8 += QK_IQ1BN;
    }

    float sumf = 0.0f;
    for (int j = 0; j < 4; ++j) {
        sumf += d[j] * (sum[4 * j + 0] + 0.25f * sum[4 * j + 1] + 0.0625f * sum[4 * j + 2] + 0.015625f * sum[4 * j + 3] - sum0[j]);
    }
    *s = sumf;
}
