#include "ggml.h"
#include "ggml-quants.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

static int feq(float a, float b, float eps) {
    return fabsf(a - b) <= eps;
}

int main(void) {
    // One 128-element I2_S block: 32 bytes packed (4x 2-bit per byte), values {-1,0,+1}
    uint8_t packed[32];
    memset(packed, 0, sizeof(packed));
    packed[0] = (0u << 6) | (1u << 4) | (2u << 2) | (3u << 0); // -1, 0, +1, 0

    float out[128];
    memset(out, 0xFF, sizeof(out));
    dequantize_row_i2_s(packed, out, 128, 2.0f);

    if (!feq(out[0], -2.0f, 1e-5f)) {
        fprintf(stderr, "i2_s dequant[0] expected -2 got %f\n", out[0]);
        return 1;
    }
    if (!feq(out[32], 0.0f, 1e-5f)) {
        fprintf(stderr, "i2_s dequant[32] expected 0 got %f\n", out[32]);
        return 1;
    }
    if (!feq(out[64], 2.0f, 1e-5f)) {
        fprintf(stderr, "i2_s dequant[64] expected +2 got %f\n", out[64]);
        return 1;
    }
    if (!feq(out[96], 0.0f, 1e-5f)) {
        fprintf(stderr, "i2_s dequant[96] expected 0 got %f\n", out[96]);
        return 1;
    }

    printf("test-bitnet-i2s-quant: OK\n");
    return 0;
}
