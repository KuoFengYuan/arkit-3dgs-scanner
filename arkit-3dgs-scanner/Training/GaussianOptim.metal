// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// Optimiser and MRNF per-iteration kernels: dense Adam with MRNF's regularisers, statistic
// folding and low-opacity position noise. Refinement (prune, split, decay) runs on the CPU
// against the shared buffers; see MRNFStrategy.swift.
#include <metal_stdlib>
using namespace metal;

/// Per-row statistics planes (capacity-strided floats), mirrors `GaussianStats` in Swift.
constant uint kStatVisibility = 0;   // sum of blending weights over the refine window
constant uint kStatErrorMax = 1;     // max over views of the error-weighted footprint
constant uint kStatEdgeSum = 2;      // sum over views of the normalised edge score
constant uint kStatShareMax = 3;     // max screen share over the refine window
constant uint kStatShareNow = 4;     // screen share in the current view
constant uint kStatActive = 5;       // 1 = live row, 0 = free slot
constant uint kGrad2DStride = 13;   // mirrors GaussianRasterizer.grad2DStride

/// Mirrors `AdamParams` in Swift.
struct AdamParams {
    float lr, beta1, beta2, epsilon;
    float biasCorrection1, biasCorrection2;   // 1 - beta^t
    uint offset, width;                        // group offset (floats) and floats per row
    uint rows, capacity, mode, skip;           // mode: 0 plain, 1 opacity reg, 2 scale hinge; skip: no update
    float opacityReg, sharePenalty, shareLimit, unused;
};

inline float sigmoidf(float x) { return 1.0f / (1.0f + exp(-x)); }

kernel void adam_step(device float* params [[buffer(0)]],
                      device const float* grads [[buffer(1)]],
                      device float* m [[buffer(2)]],
                      device float* v [[buffer(3)]],
                      device const float* stats [[buffer(4)]],
                      constant AdamParams& a [[buffer(5)]],
                      uint i [[thread_position_in_grid]]) {
    if (a.skip != 0 || i >= a.rows * a.width) return;
    const uint row = i / a.width;
    const uint index = a.offset + i;
    float g = grads[index];
    const bool active = stats[kStatActive * a.capacity + row] > 0.5f;
    if (!active) return;
    if (a.mode == 1) {
        // Opacity regulariser: 0.003 * mean(sigmoid(o)), on every live row including unseen ones.
        const float s = sigmoidf(params[index]);
        g += a.opacityReg * s * (1 - s);
    } else if (a.mode == 2) {
        // Screen-share hinge: shrink splats that cover more than `shareLimit` of the view.
        const float share = stats[kStatShareNow * a.capacity + row];
        if (share > a.shareLimit) g += a.sharePenalty * log2(share / a.shareLimit)
                                        * (sqrt(v[index]) / sqrt(a.biasCorrection2) + a.epsilon);
    }
    const float mi = a.beta1 * m[index] + (1 - a.beta1) * g;
    const float vi = a.beta2 * v[index] + (1 - a.beta2) * g * g;
    m[index] = mi;
    v[index] = vi;
    params[index] -= a.lr * (mi / a.biasCorrection1) / (sqrt(vi / a.biasCorrection2) + a.epsilon);
}

/// Folds one backward pass into the refine-window statistics:
/// visibility += sum w; errorMax = max(errorMax, sum w*E); edgeSum += (sum w*edge) / median.
kernel void mrnf_fold(device const float* grad2d [[buffer(0)]],
                      device float* stats [[buffer(1)]],
                      constant uint2& countCapacity [[buffer(2)]],
                      constant float& edgeScale [[buffer(3)]],      // 1 / positive median, 0 to skip
                      uint i [[thread_position_in_grid]]) {
    if (i >= countCapacity.x) return;
    const uint C = countCapacity.y;
    device const float* g = grad2d + i * kGrad2DStride;
    stats[kStatVisibility * C + i] += g[9];
    stats[kStatErrorMax * C + i] = max(stats[kStatErrorMax * C + i], g[10]);
    const float e = g[11] * edgeScale;
    if (isfinite(e)) stats[kStatEdgeSum * C + i] += e;
}

/// Positive values of a per-row plane sampled at a fixed stride (for a median estimate).
kernel void sample_stride(device const float* values [[buffer(0)]],
                          device float* samples [[buffer(1)]],
                          constant uint2& countStride [[buffer(2)]],
                          uint i [[thread_position_in_grid]]) {
    const uint index = i * countStride.y;
    samples[i] = index < countStride.x ? values[index] : 0.0f;
}

inline uint hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}

inline float uniformFloat(uint a, uint b) { return (float(hash(a * 0x9E3779B9u ^ hash(b)) >> 8) + 0.5f) * (1.0f / 16777216.0f); }

/// MRNF position noise: live, recently visible splats with low opacity drift so they can
/// relocate; weight (1 - opacity)^150 * lr_means * 50, clamped to the scene's median size.
kernel void mrnf_noise(device float* params [[buffer(0)]],
                       device const float* stats [[buffer(1)]],
                       constant uint4& info [[buffer(2)]],          // count, capacity, seed, opacity offset
                       constant float2& scaleClamp [[buffer(3)]],   // lr_means * weight, median size
                       uint i [[thread_position_in_grid]]) {
    if (i >= info.x) return;
    const uint C = info.y;
    if (stats[kStatActive * C + i] < 0.5f || stats[kStatVisibility * C + i] <= 0) return;
    const float o = sigmoidf(params[info.w + i]);
    const float w = pow(1.0f - o, 150.0f) * scaleClamp.x;
    if (w < 1e-12f) return;
    for (uint k = 0; k < 3; ++k) {
        // Box-Muller from two hashed uniforms.
        const float u1 = uniformFloat(info.z, i * 6 + 2 * k), u2 = uniformFloat(info.z, i * 6 + 2 * k + 1);
        const float n = sqrt(-2.0f * log(u1)) * cos(6.2831853f * u2);
        params[3 * i + k] += clamp(n * w, -scaleClamp.y, scaleClamp.y);
    }
}

/// Screen share of every projected splat (FastGS angular form) for the MRNF oversize logic.
kernel void screen_share(device const float* params [[buffer(0)]],
                         device float* stats [[buffer(1)]],
                         device const uint* tiles [[buffer(2)]],
                         constant uint4& info [[buffer(3)]],         // count, capacity, scale offset, opacity offset
                         constant float4& center [[buffer(4)]],
                         uint i [[thread_position_in_grid]]) {
    if (i >= info.x) return;
    const uint C = info.y;
    float share = 0;
    if (tiles[i] > 0) {
        const float3 mean = float3(params[3 * i], params[3 * i + 1], params[3 * i + 2]);
        const float3 s = float3(params[info.z + 3 * i], params[info.z + 3 * i + 1], params[info.z + 3 * i + 2]);
        const float o = sigmoidf(params[info.w + i]);
        const float r = exp(max(s.x, max(s.y, s.z))) * sqrt(2.0f * log(max(255.0f * o, 1.0f)));
        const float d = length(mean - center.xyz);
        share = clamp(r / (max(d, r) + sqrt(max(d * d - r * r, 0.0f))), 0.0f, 1.0f);
    }
    stats[kStatShareNow * C + i] = share;
    stats[kStatShareMax * C + i] = max(stats[kStatShareMax * C + i], share);
}
