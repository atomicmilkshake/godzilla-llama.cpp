// ik_llama.cpp IQ2_BN starter port for quant-god (CPU quant round-trip smoke).
// Distinct from Microsoft BitNet I2_S (vendor/bitnet, GGML_TYPE_I2_S).
// Source reference: ik_llama.cpp ggml/src/iqk/iqk_quantize.cpp (IQ1BNQuantizer::quantize_one_row_2bn)

#include "ggml-quants.h"
#include "ggml-common.h"

#include <assert.h>
#include <math.h>
#include <stdint.h>

#define QK_IQ1BN 64
#define IQ2_BN_NJ (QK_IQ1BN / 4)

void quantize_row_iq2_bn_ref(const float * GGML_RESTRICT x, block_iq2_bn * GGML_RESTRICT y, int64_t k) {
    assert(k % QK_IQ1BN == 0);

    const int nblock = (int) (k / QK_IQ1BN);

    float max = 0.0f;
    for (int64_t j = 0; j < k; ++j) {
        const float a = fabsf(x[j]);
        if (a > max) {
            max = a;
        }
    }

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
            y[j + 0       ] = d1 * (x[i].qs[j] & 0x03) + m;
            y[j + 1 * IQ2_BN_NJ] = d2 * (x[i].qs[j] & 0x0c) + m;
            y[j + 2 * IQ2_BN_NJ] = d3 * (x[i].qs[j] & 0x30) + m;
            y[j + 3 * IQ2_BN_NJ] = d4 * (x[i].qs[j] & 0xc0) + m;
        }
        y += QK_IQ1BN;
    }
}
