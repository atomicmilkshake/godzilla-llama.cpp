/*
 * TriAttention GPU scoring kernel implementation
 *
 * Computes importance scores for KV cache entries directly on GPU memory.
 * Each thread block processes one (position) with all freq dimensions in
 * parallel. The kernel handles dequantization, inverse WHT rotation (for
 * turbo2/turbo3), inverse RoPE, and the full TriAttention scoring formula.
 *
 * Grid:  (n_cells, n_offsets_or_1, 1)
 * Block: (freq_count, 1, 1)  — one thread per frequency pair
 *
 * Reference: "TriAttention: Trigonometric KV Cache Eviction" (arXiv 2604.04921)
 */

#include "triattention-score.cuh"
#include "dequantize.cuh"
#include "turbo-quant.cuh"

#include <cstdio>
#include <cstring>

// ============================================================================
// GPU-resident state
// ============================================================================

struct triattention_gpu_state {
    // Device arrays: calibration per sampled head
    float * d_q_mean_real;     // [n_sampled * freq_count]
    float * d_q_mean_imag;     // [n_sampled * freq_count]
    float * d_q_mean_abs;      // [n_sampled * freq_count]
    float * d_extra_weight;    // [n_sampled * freq_count]

    // Device arrays: precomputed
    float * d_omega;           // [freq_count]
    float * d_freq_scale_sq;   // [freq_count]
    float * d_offsets;         // [n_offsets]

    // Configuration
    triattention_gpu_config cfg;
};

// ============================================================================
// Device helper: cooperative Walsh-Hadamard Transform in shared memory
// n must be 128, threads = 64 (one butterfly per thread per stage)
// ============================================================================

// 128-point FWHT in shared memory.  Only threads with tid < 64 perform butterfly
// work, but every thread in the block must reach each __syncthreads (freq_count
// can be 128 or 256 for 256/512-dim heads — TRIX-09).
static __device__ void cooperative_fwht_128(float * smem, int tid) {
    const bool active = tid < 64;

    for (int h = 1; h < 128; h *= 2) {
        float a = 0.0f;
        float b = 0.0f;
        int   i = 0;
        const int block_half = h;
        const int block_size = h * 2;
        if (active) {
            i = (tid / block_half) * block_size + (tid % block_half);
            a = smem[i];
            b = smem[i + block_half];
        }
        __syncthreads();
        if (active) {
            smem[i]              = a + b;
            smem[i + block_half] = a - b;
        }
        __syncthreads();
    }

    if (active) {
        const float inv_sqrt_128 = 0.08838834764831845f;
        smem[tid * 2]     *= inv_sqrt_128;
        smem[tid * 2 + 1] *= inv_sqrt_128;
    }
    __syncthreads();
}

// ============================================================================
// Device helper: inverse WHT rotation for turbo2/turbo3
// R^{-1} * x = signs1 * FWHT(signs2 * x)  (inverse: signs2 pre, signs1 post)
// ============================================================================

static __device__ void inverse_wht_rotation_128(float * block, int tid) {
    const bool active = tid < 64;

    if (active) {
        block[tid * 2]     *= TURBO_WHT_SIGNS2[tid * 2];
        block[tid * 2 + 1] *= TURBO_WHT_SIGNS2[tid * 2 + 1];
    }
    __syncthreads();

    cooperative_fwht_128(block, tid);

    if (active) {
        block[tid * 2]     *= TURBO_WHT_SIGNS1[tid * 2];
        block[tid * 2 + 1] *= TURBO_WHT_SIGNS1[tid * 2 + 1];
    }
    __syncthreads();
}

// ============================================================================
// Device helper: dequantize one KV head row to shared memory
// Each thread loads 2 elements (its freq pair)
// ============================================================================

template <enum ggml_type K_TYPE>
static __device__ void dequant_head_to_smem(
    float * smem,
    const void * k_row_ptr,    // device pointer to quantized head data
    int tid,                   // thread id = freq index
    int head_dim)
{
    if constexpr (K_TYPE == GGML_TYPE_F32) {
        const float * src = (const float *)k_row_ptr;
        smem[tid * 2]     = src[tid * 2];
        smem[tid * 2 + 1] = src[tid * 2 + 1];
    } else if constexpr (K_TYPE == GGML_TYPE_F16) {
        const half * src = (const half *)k_row_ptr;
        smem[tid * 2]     = __half2float(src[tid * 2]);
        smem[tid * 2 + 1] = __half2float(src[tid * 2 + 1]);
    } else if constexpr (K_TYPE == GGML_TYPE_Q8_0) {
        // Q8_0: block_size=32, each block has d (fp16) + 32 qs (int8)
        // Use the standard ggml dequant pattern
        const int el0 = tid * 2;
        const int el1 = tid * 2 + 1;
        const int blk0 = el0 / QK8_0;
        const int blk1 = el1 / QK8_0;
        const int off0 = el0 % QK8_0;
        const int off1 = el1 % QK8_0;
        const block_q8_0 * x = (const block_q8_0 *)k_row_ptr;
        smem[el0] = (float)x[blk0].qs[off0] * __half2float(x[blk0].d);
        smem[el1] = (float)x[blk1].qs[off1] * __half2float(x[blk1].d);
    } else if constexpr (K_TYPE == GGML_TYPE_TURBO4_0) {
        // turbo4: block_size=128, dequant includes rotation → no need for WHT inv
        const block_turbo4_0 * x = (const block_turbo4_0 *)k_row_ptr;
        const int blk = (tid * 2) / QK_TURBO4;
        const int off = (tid * 2) % QK_TURBO4;
        const float norm = __half2float(x[blk].norm);
        smem[tid * 2]     = turbo4_dequant_element(&x[blk], off,     norm);
        smem[tid * 2 + 1] = turbo4_dequant_element(&x[blk], off + 1, norm);
    } else if constexpr (K_TYPE == GGML_TYPE_TURBO3_0) {
        // turbo3: block_size=32, returns WHT-rotated values
        const block_turbo3_0 * x = (const block_turbo3_0 *)k_row_ptr;
        const int el0 = tid * 2;
        const int el1 = tid * 2 + 1;
        const int blk0 = el0 / QK_TURBO3;
        const int blk1 = el1 / QK_TURBO3;
        const int off0 = el0 % QK_TURBO3;
        const int off1 = el1 % QK_TURBO3;
        smem[el0] = turbo3_dequant_element(&x[blk0], off0, __half2float(x[blk0].norm));
        smem[el1] = turbo3_dequant_element(&x[blk1], off1, __half2float(x[blk1].norm));
    } else if constexpr (K_TYPE == GGML_TYPE_TURBO2_0) {
        // turbo2: block_size=32, returns WHT-rotated values
        const block_turbo2_0 * x = (const block_turbo2_0 *)k_row_ptr;
        const int el0 = tid * 2;
        const int el1 = tid * 2 + 1;
        const int blk0 = el0 / QK_TURBO2;
        const int blk1 = el1 / QK_TURBO2;
        const int off0 = el0 % QK_TURBO2;
        const int off1 = el1 % QK_TURBO2;
        smem[el0] = turbo2_dequant_element(&x[blk0], off0, __half2float(x[blk0].norm));
        smem[el1] = turbo2_dequant_element(&x[blk1], off1, __half2float(x[blk1].norm));
    }
}

// ============================================================================
// Main scoring kernel
//
// One block per cell (position). freq_count threads per block.
// Each thread handles one frequency pair [f, f+freq_count] (half layout).
//
// Pipeline per block:
//   1. Dequant K head row → shared mem [head_dim]
//   2. Inverse WHT rotation if turbo2/turbo3
//   3. Inverse RoPE → get pre-RoPE K in "half" layout
//   4. Compute per-freq score contributions
//   5. Block reduction → one score per position
//   6. Write to output
// ============================================================================

template <enum ggml_type K_TYPE, bool NEED_WHT_INV, bool DISABLE_TRIG, bool ROPE_HALF, bool K_ROWS_COMPACT>
static __global__ void triattention_score_kernel(
    float       * __restrict__ scores_out,       // [n_cells]
    const void  * __restrict__ k_data,           // device ptr to full K tensor
    const uint64_t              n_embd_k_gqa,
    const size_t                row_bytes,
    const size_t                head_offset_bytes, // precomputed on host
    const uint32_t              padded_hd,
    const uint32_t * __restrict__ cell_indices,  // [n_cells]
    const int32_t  * __restrict__ positions,     // [n_cells]
    const uint32_t              n_cells,
    const int64_t               round_start,
    const float  * __restrict__ omega,           // [freq_count]
    const float  * __restrict__ freq_scale_sq,   // [freq_count]
    const float  * __restrict__ offsets,          // [n_offsets]
    const uint32_t              n_offsets,
    const float  * __restrict__ q_mean_real,     // [freq_count] for this head
    const float  * __restrict__ q_mean_imag,     // [freq_count]
    const float  * __restrict__ q_mean_abs,      // [freq_count]
    const float  * __restrict__ extra_weight,    // [freq_count]
    const uint32_t              freq_count,
    const int                   agg_mode)        // 0=mean, 1=max
{
    const int cell_idx_local = blockIdx.x;  // which cell we're scoring
    const int f = threadIdx.x;              // frequency index [0, freq_count)

    if (cell_idx_local >= (int)n_cells || f >= (int)freq_count) return;

    // Shared memory for dequantized K vector
    extern __shared__ float smem[];
    // smem[0..head_dim-1]       = dequantized K
    // smem[head_dim..head_dim+freq_count-1] = partial scores for reduction

    float * k_smem = smem;
    float * score_smem = smem + padded_hd;

    // ---- Step 1: Dequant K head row to shared memory ----
    const uint32_t cell_global = K_ROWS_COMPACT
        ? (uint32_t) cell_idx_local
        : cell_indices[cell_idx_local];
    const char * k_row_ptr = (const char *)k_data + (size_t)cell_global * row_bytes + head_offset_bytes;

    dequant_head_to_smem<K_TYPE>(k_smem, k_row_ptr, f, padded_hd);
    __syncthreads();

    // ---- Step 2: Inverse WHT rotation (turbo2/turbo3 only) ----
    // Process every 128-element block (256-dim: 2 blocks, 512-dim: 4 blocks).
    if constexpr (NEED_WHT_INV) {
        for (uint32_t b = 0; b < padded_hd; b += 128) {
            inverse_wht_rotation_128(k_smem + b, f);
        }
        __syncthreads();
    }

    // ---- Step 3: Inverse RoPE ----
    {
        const int32_t pos = positions[cell_idx_local];
        const float w = omega[f];
        const float theta = w * (float)pos;
        const float cos_t = cosf(theta);
        const float sin_t = sinf(theta);

        float k_re, k_im;
        if constexpr (ROPE_HALF) {
            k_re = k_smem[f];
            k_im = k_smem[f + freq_count];
        } else {
            k_re = k_smem[2 * f];
            k_im = k_smem[2 * f + 1];
        }

        const float pre_re =  k_re * cos_t + k_im * sin_t;
        const float pre_im = -k_re * sin_t + k_im * cos_t;

        if constexpr (ROPE_HALF) {
            k_smem[f]              = pre_re;
            k_smem[f + freq_count] = pre_im;
        } else {
            k_smem[2 * f]     = pre_re;
            k_smem[2 * f + 1] = pre_im;
        }
    }
    __syncthreads();

    // ---- Step 4: Compute score ----
    float k_re, k_im;
    if constexpr (ROPE_HALF) {
        k_re = k_smem[f];
        k_im = k_smem[f + freq_count];
    } else {
        k_re = k_smem[2 * f];
        k_im = k_smem[2 * f + 1];
    }
    const float k_mag = sqrtf(k_re * k_re + k_im * k_im);

    float total_score;

    if constexpr (!DISABLE_TRIG) {
        // Full scoring with trigonometric + norm terms
        const float base_delta = (float)(round_start - positions[cell_idx_local]);
        const float amp = q_mean_abs[f] * k_mag;
        const float w = omega[f];
        const float fscale_sq = freq_scale_sq[f];

        // Phase from conjugate multiply: E[q] * conj(k)
        const float conj_re = q_mean_real[f] * k_re + q_mean_imag[f] * k_im;
        const float conj_im = q_mean_imag[f] * k_re - q_mean_real[f] * k_im;
        const float phi = atan2f(conj_im, conj_re);

        const float ew = extra_weight[f] * fscale_sq * k_mag;

        if (agg_mode == 1) {
            // Max aggregation over offsets
            float max_score = -1e30f;
            for (uint32_t d = 0; d < n_offsets; d++) {
                float delta = base_delta + offsets[d];
                float phase = w * delta + phi;
                float s = amp * fscale_sq * cosf(phase) + ew;
                max_score = fmaxf(max_score, s);
            }
            total_score = max_score;
        } else {
            // Mean aggregation over offsets
            float sum = 0.0f;
            for (uint32_t d = 0; d < n_offsets; d++) {
                float delta = base_delta + offsets[d];
                float phase = w * delta + phi;
                sum += amp * fscale_sq * cosf(phase) + ew;
            }
            total_score = sum / (float)n_offsets;
        }
    } else {
        // Ablation: norm-only scoring
        total_score = extra_weight[f] * freq_scale_sq[f] * k_mag;
    }

    // ---- Step 5: Block reduction  ----
    score_smem[f] = total_score;
    __syncthreads();

    // Tree reduction
    for (int stride = freq_count / 2; stride > 0; stride >>= 1) {
        if (f < stride) {
            score_smem[f] += score_smem[f + stride];
        }
        __syncthreads();
    }

    // ---- Step 6: Write result ----
    if (f == 0) {
        scores_out[cell_idx_local] = score_smem[0];
    }
}

// ============================================================================
// Kernel launch dispatcher
// ============================================================================

static bool launch_score_kernel(
    triattention_gpu_state * state,
    float       * scores_out,
    const void  * k_data,
    uint64_t     n_embd_k_gqa,
    size_t       row_bytes,
    uint32_t     kv_head_idx,
    uint32_t     head_calib_idx,
    uint32_t     padded_hd,
    bool         k_rows_compact,
    const uint32_t * cell_indices,
    const int32_t  * positions,
    uint32_t     n_cells,
    int64_t      round_start,
    int          agg_mode,
    cudaStream_t stream)
{
    const auto & cfg = state->cfg;
    const uint32_t fc = cfg.freq_count;

    if (padded_hd == 0 || fc == 0 || fc > padded_hd) {
        fprintf(stderr, "[TriAttention GPU] invalid padded_hd=%u fc=%u\n", padded_hd, fc);
        return false;
    }

    // Calibration pointers for this head
    const float * qmr = state->d_q_mean_real  + (size_t)head_calib_idx * fc;
    const float * qmi = state->d_q_mean_imag  + (size_t)head_calib_idx * fc;
    const float * qma = state->d_q_mean_abs   + (size_t)head_calib_idx * fc;
    const float * ew  = state->d_extra_weight  + (size_t)head_calib_idx * fc;

    const dim3 grid(n_cells, 1, 1);
    const dim3 block(fc, 1, 1);
    const size_t smem_bytes = ((size_t) padded_hd + fc) * sizeof(float);

    // TRIX-03: per-layer padded head dim for GQA head offset within row
    const size_t head_off = ggml_row_size(cfg.k_type, (uint64_t)kv_head_idx * padded_hd);

    #define LAUNCH_KERNEL(KTYPE, WHT, TRIG, ROPE, COMPACT) \
        triattention_score_kernel<KTYPE, WHT, TRIG, ROPE, COMPACT><<<grid, block, smem_bytes, stream>>>( \
            scores_out, k_data, n_embd_k_gqa, row_bytes, head_off, padded_hd, \
            cell_indices, positions, n_cells, round_start, \
            state->d_omega, state->d_freq_scale_sq, state->d_offsets, cfg.n_offsets, \
            qmr, qmi, qma, ew, fc, agg_mode)

    #define LAUNCH_ALL(KTYPE, WHT, TRIG) \
        if (cfg.rope_style == 0) { \
            if (k_rows_compact) { LAUNCH_KERNEL(KTYPE, WHT, TRIG, true,  true); } \
            else                 { LAUNCH_KERNEL(KTYPE, WHT, TRIG, true,  false); } \
        } else { \
            if (k_rows_compact) { LAUNCH_KERNEL(KTYPE, WHT, TRIG, false, true); } \
            else                 { LAUNCH_KERNEL(KTYPE, WHT, TRIG, false, false); } \
        }

    if (cfg.disable_trig) {
        switch (cfg.k_type) {
            case GGML_TYPE_TURBO2_0: LAUNCH_ALL(GGML_TYPE_TURBO2_0, true,  true); break;
            case GGML_TYPE_TURBO3_0: LAUNCH_ALL(GGML_TYPE_TURBO3_0, true,  true); break;
            case GGML_TYPE_TURBO4_0: LAUNCH_ALL(GGML_TYPE_TURBO4_0, false, true); break;
            case GGML_TYPE_Q8_0:     LAUNCH_ALL(GGML_TYPE_Q8_0,     false, true); break;
            case GGML_TYPE_F16:      LAUNCH_ALL(GGML_TYPE_F16,      false, true); break;
            case GGML_TYPE_F32:      LAUNCH_ALL(GGML_TYPE_F32,      false, true); break;
            default:
                fprintf(stderr, "[TriAttention GPU] unsupported K type %d\n", cfg.k_type);
                return false;
        }
    } else {
        switch (cfg.k_type) {
            case GGML_TYPE_TURBO2_0: LAUNCH_ALL(GGML_TYPE_TURBO2_0, true,  false); break;
            case GGML_TYPE_TURBO3_0: LAUNCH_ALL(GGML_TYPE_TURBO3_0, true,  false); break;
            case GGML_TYPE_TURBO4_0: LAUNCH_ALL(GGML_TYPE_TURBO4_0, false, false); break;
            case GGML_TYPE_Q8_0:     LAUNCH_ALL(GGML_TYPE_Q8_0,     false, false); break;
            case GGML_TYPE_F16:      LAUNCH_ALL(GGML_TYPE_F16,      false, false); break;
            case GGML_TYPE_F32:      LAUNCH_ALL(GGML_TYPE_F32,      false, false); break;
            default:
                fprintf(stderr, "[TriAttention GPU] unsupported K type %d\n", cfg.k_type);
                return false;
        }
    }

    #undef LAUNCH_ALL
    #undef LAUNCH_KERNEL

    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
        fprintf(stderr, "[TriAttention GPU] kernel launch failed: %s\n", cudaGetErrorString(err));
        return false;
    }

    // Illegal access often surfaces at sync, not launch (TRIX-GPU-HARDEN)
    if (stream == nullptr) {
        err = cudaStreamSynchronize(cudaStreamPerThread);
        if (err != cudaSuccess) {
            fprintf(stderr, "[TriAttention GPU] per-head stream sync failed: %s\n",
                    cudaGetErrorString(err));
            cudaGetLastError();
            return false;
        }
        err = cudaGetLastError();
        if (err != cudaSuccess) {
            fprintf(stderr, "[TriAttention GPU] sticky error after sync: %s\n",
                    cudaGetErrorString(err));
            return false;
        }
    }
    return true;
}

// ============================================================================
// Host API: Init
// ============================================================================

static void triattention_gpu_free_partial(triattention_gpu_state * state) {
    if (!state) return;
    cudaFree(state->d_q_mean_real);
    cudaFree(state->d_q_mean_imag);
    cudaFree(state->d_q_mean_abs);
    cudaFree(state->d_extra_weight);
    cudaFree(state->d_omega);
    cudaFree(state->d_freq_scale_sq);
    cudaFree(state->d_offsets);
    delete state;
}

static bool triattention_gpu_malloc_impl(void ** ptr, size_t nbytes, const char * what) {
    const cudaError_t err = cudaMalloc(ptr, nbytes);
    if (err != cudaSuccess) {
        fprintf(stderr, "[TriAttention GPU] cudaMalloc %s failed (%zu bytes): %s\n",
                what, nbytes, cudaGetErrorString(err));
        return false;
    }
    return true;
}

triattention_gpu_state * triattention_gpu_init(
    const triattention_gpu_config * config,
    const triattention_gpu_head_calib * head_calibs,
    const float * omega,
    const float * freq_scale_sq,
    const float * offsets,
    void * stream_ptr)
{
    cudaStream_t stream = (cudaStream_t)stream_ptr;
    triattention_gpu_state * state = new triattention_gpu_state();
    state->cfg = *config;
    state->d_q_mean_real   = nullptr;
    state->d_q_mean_imag   = nullptr;
    state->d_q_mean_abs    = nullptr;
    state->d_extra_weight  = nullptr;
    state->d_omega         = nullptr;
    state->d_freq_scale_sq = nullptr;
    state->d_offsets       = nullptr;

    const uint32_t fc = config->freq_count;
    const uint32_t ns = config->n_sampled;
    const size_t calib_bytes = (size_t)ns * fc * sizeof(float);

    if (!triattention_gpu_malloc_impl((void **)&state->d_q_mean_real,  calib_bytes, "q_mean_real") ||
        !triattention_gpu_malloc_impl((void **)&state->d_q_mean_imag,  calib_bytes, "q_mean_imag") ||
        !triattention_gpu_malloc_impl((void **)&state->d_q_mean_abs,   calib_bytes, "q_mean_abs") ||
        !triattention_gpu_malloc_impl((void **)&state->d_extra_weight, calib_bytes, "extra_weight") ||
        !triattention_gpu_malloc_impl((void **)&state->d_omega,         fc * sizeof(float), "omega") ||
        !triattention_gpu_malloc_impl((void **)&state->d_freq_scale_sq, fc * sizeof(float), "freq_scale_sq") ||
        !triattention_gpu_malloc_impl((void **)&state->d_offsets, config->n_offsets * sizeof(float), "offsets")) {
        triattention_gpu_free_partial(state);
        return nullptr;
    }

    for (uint32_t h = 0; h < ns; h++) {
        const size_t off = (size_t)h * fc * sizeof(float);
        cudaError_t err;
        err = cudaMemcpyAsync((char *)state->d_q_mean_real + off, head_calibs[h].q_mean_real,
            fc * sizeof(float), cudaMemcpyHostToDevice, stream);
        if (err != cudaSuccess) goto upload_fail;
        err = cudaMemcpyAsync((char *)state->d_q_mean_imag + off, head_calibs[h].q_mean_imag,
            fc * sizeof(float), cudaMemcpyHostToDevice, stream);
        if (err != cudaSuccess) goto upload_fail;
        err = cudaMemcpyAsync((char *)state->d_q_mean_abs + off, head_calibs[h].q_mean_abs,
            fc * sizeof(float), cudaMemcpyHostToDevice, stream);
        if (err != cudaSuccess) goto upload_fail;
        err = cudaMemcpyAsync((char *)state->d_extra_weight + off, head_calibs[h].extra_weight,
            fc * sizeof(float), cudaMemcpyHostToDevice, stream);
        if (err != cudaSuccess) goto upload_fail;
    }

    if (cudaMemcpyAsync(state->d_omega, omega, fc * sizeof(float), cudaMemcpyHostToDevice, stream) != cudaSuccess ||
        cudaMemcpyAsync(state->d_freq_scale_sq, freq_scale_sq, fc * sizeof(float), cudaMemcpyHostToDevice, stream) != cudaSuccess ||
        cudaMemcpyAsync(state->d_offsets, offsets, config->n_offsets * sizeof(float), cudaMemcpyHostToDevice, stream) != cudaSuccess ||
        cudaStreamSynchronize(stream) != cudaSuccess) {
upload_fail:
        fprintf(stderr, "[TriAttention GPU] calibration upload failed: %s\n",
                cudaGetErrorString(cudaGetLastError()));
        triattention_gpu_free_partial(state);
        return nullptr;
    }

    return state;
}

// ============================================================================
// Host API: Score head
// ============================================================================

bool triattention_gpu_score_head(
    triattention_gpu_state * state,
    const void   * k_data_dev,
    uint64_t       n_embd_k_gqa,
    size_t         row_bytes,
    uint32_t       kv_head_idx,
    uint32_t       head_calib_idx,
    uint32_t       padded_hd,
    bool           k_rows_compact,
    const uint32_t * cell_indices_dev,
    const int32_t  * positions_dev,
    uint32_t       n_cells,
    int64_t        round_start,
    int            agg_mode,
    float        * scores_dev,
    void * stream_ptr)
{
    cudaStream_t stream = (cudaStream_t)stream_ptr;
    if (n_cells == 0) return true;

    return launch_score_kernel(state, scores_dev, k_data_dev,
                        n_embd_k_gqa, row_bytes, kv_head_idx,
                        head_calib_idx, padded_hd, k_rows_compact,
                        cell_indices_dev, positions_dev,
                        n_cells, round_start, agg_mode, stream);
}

// ============================================================================
// Host API: Utility functions
// ============================================================================

bool triattention_gpu_scores_to_host(
    float * scores_host,
    const float * scores_dev,
    uint32_t n_cells,
    void * stream_ptr)
{
    cudaStream_t stream = (cudaStream_t)stream_ptr;
    cudaError_t err = cudaMemcpyAsync(scores_host, scores_dev,
        (size_t) n_cells * sizeof(float), cudaMemcpyDeviceToHost, stream);
    if (err != cudaSuccess) {
        fprintf(stderr, "[TriAttention GPU] scores D2H failed: %s\n", cudaGetErrorString(err));
        return false;
    }
    err = cudaStreamSynchronize(stream);
    if (err != cudaSuccess) {
        fprintf(stderr, "[TriAttention GPU] scores sync failed: %s\n", cudaGetErrorString(err));
        return false;
    }
    return true;
}

bool triattention_gpu_upload_cells(
    uint32_t     ** cell_indices_dev,
    int32_t      ** positions_dev,
    const uint32_t * cell_indices_host,
    const int32_t  * positions_host,
    uint32_t        n_cells,
    void * stream_ptr)
{
    cudaStream_t stream = (cudaStream_t)stream_ptr;
    *cell_indices_dev = nullptr;
    *positions_dev    = nullptr;

    if (!triattention_gpu_malloc_impl((void **)cell_indices_dev,
            (size_t) n_cells * sizeof(uint32_t), "cell_indices") ||
        !triattention_gpu_malloc_impl((void **)positions_dev,
            (size_t) n_cells * sizeof(int32_t), "positions")) {
        triattention_gpu_free_dev(*cell_indices_dev);
        triattention_gpu_free_dev(*positions_dev);
        *cell_indices_dev = nullptr;
        *positions_dev    = nullptr;
        return false;
    }

    cudaError_t err;
    err = cudaMemcpyAsync(*cell_indices_dev, cell_indices_host,
        n_cells * sizeof(uint32_t), cudaMemcpyHostToDevice, stream);
    if (err != cudaSuccess) goto upload_fail;
    err = cudaMemcpyAsync(*positions_dev, positions_host,
        n_cells * sizeof(int32_t), cudaMemcpyHostToDevice, stream);
    if (err != cudaSuccess) goto upload_fail;

    return true;

upload_fail:
    fprintf(stderr, "[TriAttention GPU] cell upload failed: %s\n",
            cudaGetErrorString(err));
    triattention_gpu_free_dev(*cell_indices_dev);
    triattention_gpu_free_dev(*positions_dev);
    *cell_indices_dev = nullptr;
    *positions_dev    = nullptr;
    return false;
}

bool triattention_gpu_device_sync(void) {
    const cudaError_t err = cudaDeviceSynchronize();
    if (err != cudaSuccess) {
        fprintf(stderr, "[TriAttention GPU] device sync failed: %s\n", cudaGetErrorString(err));
        cudaGetLastError();
        return false;
    }
    return true;
}

void triattention_gpu_clear_errors(void) {
    cudaGetLastError();
}

bool triattention_gpu_device_available(void) {
    int dev = 0;
    return cudaGetDevice(&dev) == cudaSuccess;
}

bool triattention_gpu_malloc(void ** ptr, size_t nbytes) {
    return triattention_gpu_malloc_impl(ptr, nbytes, "buffer");
}

bool triattention_gpu_memcpy_h2d(void * dst, const void * src, size_t nbytes) {
    const cudaError_t err = cudaMemcpy(dst, src, nbytes, cudaMemcpyHostToDevice);
    if (err != cudaSuccess) {
        fprintf(stderr, "[TriAttention GPU] H2D memcpy failed (%zu bytes): %s\n",
                nbytes, cudaGetErrorString(err));
        return false;
    }
    return true;
}

bool triattention_gpu_ensure_buffer(void ** ptr, size_t * cap_bytes, size_t need_bytes) {
    if (need_bytes == 0) {
        return true;
    }
    if (*ptr != nullptr && *cap_bytes >= need_bytes) {
        return true;
    }
    if (*ptr != nullptr) {
        cudaFree(*ptr);
        *ptr = nullptr;
        *cap_bytes = 0;
    }
    void * new_ptr = nullptr;
    if (!triattention_gpu_malloc_impl(&new_ptr, need_bytes, "ensure_buffer")) {
        return false;
    }
    *ptr = new_ptr;
    *cap_bytes = need_bytes;
    return true;
}

bool triattention_gpu_gather_k_rows(
    void * d_staging,
    const void * k_host,
    size_t row_bytes,
    const uint32_t * cell_indices_host,
    uint32_t n_cells,
    uint32_t kv_cells_per_stream) {
    if (!d_staging || !k_host || !cell_indices_host || n_cells == 0 || row_bytes == 0) {
        return false;
    }
    auto * dst_base = (char *) d_staging;
    const auto * src_base = (const char *) k_host;
    for (uint32_t i = 0; i < n_cells; i++) {
        if (kv_cells_per_stream > 0 && cell_indices_host[i] >= kv_cells_per_stream) {
            fprintf(stderr, "[TriAttention GPU] gather cell index %u >= kv_size %u\n",
                    cell_indices_host[i], kv_cells_per_stream);
            return false;
        }
        const char * src = src_base + (size_t) cell_indices_host[i] * row_bytes;
        char * dst = dst_base + (size_t) i * row_bytes;
        if (!triattention_gpu_memcpy_h2d(dst, src, row_bytes)) {
            return false;
        }
    }
    return true;
}

float * triattention_gpu_alloc_scores(uint32_t n_cells, void * /* stream_ptr */) {
    float * ptr = nullptr;
    const cudaError_t err = cudaMalloc(&ptr, (size_t) n_cells * sizeof(float));
    if (err != cudaSuccess) {
        fprintf(stderr, "[TriAttention GPU] cudaMalloc scores failed (%u cells): %s\n",
                n_cells, cudaGetErrorString(err));
        return nullptr;
    }
    return ptr;
}

void triattention_gpu_free_dev(void * ptr) {
    if (ptr) {
        const cudaError_t err = cudaFree(ptr);
        if (err != cudaSuccess) {
            fprintf(stderr, "[TriAttention GPU] cudaFree failed: %s\n", cudaGetErrorString(err));
        }
    }
}

// ============================================================================
// Host API: Cleanup
// ============================================================================

void triattention_gpu_free(triattention_gpu_state * state) {
    if (!state) return;

    cudaFree(state->d_q_mean_real);
    cudaFree(state->d_q_mean_imag);
    cudaFree(state->d_q_mean_abs);
    cudaFree(state->d_extra_weight);
    cudaFree(state->d_omega);
    cudaFree(state->d_freq_scale_sq);
    cudaFree(state->d_offsets);

    delete state;
}
