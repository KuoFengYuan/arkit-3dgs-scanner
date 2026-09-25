// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// k-means assignment for the SOG model file: each Gaussian's higher-band SH vector goes to its
// nearest palette entry (squared Euclidean distance). The update step runs on the CPU.
#include <metal_stdlib>
using namespace metal;

constant uint kPaletteTile = 64;     // palette entries per threadgroup tile

/// One point per thread; the palette streams through threadgroup memory in tiles of 64
/// entries that every thread of the group compares against its own vector. Vectors are half
/// precision, padded to `V` half4s: SH coefficients are small (squared distances stay far
/// below the half range), and half arithmetic runs at twice the float rate.
template <uint V>
inline void assignNearest(device const half4* points, device const half4* palette, device uint* labels,
                          uint count, uint entries, uint i, uint tid, uint threads, threadgroup half4* tile) {
    const bool valid = i < count;
    half4 p[V];
    for (uint v = 0; v < V; ++v) p[v] = valid ? points[i * V + v] : half4(0);
    float best = INFINITY;
    uint bestEntry = 0;
    for (uint base = 0; base < entries; base += kPaletteTile) {
        const uint n = min(kPaletteTile, entries - base);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint t = tid; t < n * V; t += threads) tile[t] = palette[base * V + t];
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint c = 0; c < n; ++c) {
            half4 acc = 0;
            for (uint v = 0; v < V; ++v) {
                const half4 x = p[v] - tile[c * V + v];
                acc = fma(x, x, acc);
            }
            const float distance = float(acc.x) + float(acc.y) + float(acc.z) + float(acc.w);
            if (distance < best) { best = distance; bestEntry = base + c; }
        }
    }
    if (valid) labels[i] = bestEntry;
}

#define SOG_ASSIGN(D, V) \
kernel void sog_assign_##D(device const half4* points [[buffer(0)]], \
                           device const half4* palette [[buffer(1)]], \
                           device uint* labels [[buffer(2)]], \
                           constant uint2& sizes [[buffer(3)]], \
                           uint i [[thread_position_in_grid]], \
                           uint tid [[thread_index_in_threadgroup]], \
                           uint threads [[threads_per_threadgroup]]) { \
    threadgroup half4 tile[kPaletteTile * V]; \
    assignNearest<V>(points, palette, labels, sizes.x, sizes.y, i, tid, threads, tile); \
}

// SH degree 1, 2 and 3: 9, 24 and 45 coefficients, padded to 3, 6 and 12 half4s.
SOG_ASSIGN(9, 3)
SOG_ASSIGN(24, 6)
SOG_ASSIGN(45, 12)
