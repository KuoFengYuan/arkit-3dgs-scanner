// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// GPU prefix sums and a stable LSD radix sort for the Gaussian rasterizer.
//
// Both kernels use 256-thread threadgroups (8 SIMD groups of 32 lanes on Apple GPUs) and
// 1024-element blocks. The radix sort ranks keys inside a block with SIMD ballots, so equal
// digits keep their input order: sorting by depth first and then by tile yields per-tile lists
// in depth order.
#include <metal_stdlib>
using namespace metal;

constant uint kScanThreads = 256;
constant uint kScanItems = 4;
constant uint kBlock = kScanThreads * kScanItems;   // 1024
constant uint kSimdGroups = kScanThreads / 32;

/// Exclusive scan of one 1024-element block; writes the block total to `blockSums`.
kernel void scan_block(device const uint* input [[buffer(0)]],
                       device uint* output [[buffer(1)]],
                       device uint* blockSums [[buffer(2)]],
                       constant uint& count [[buffer(3)]],
                       uint tid [[thread_index_in_threadgroup]],
                       uint block [[threadgroup_position_in_grid]],
                       uint lane [[thread_index_in_simdgroup]],
                       uint simd [[simdgroup_index_in_threadgroup]]) {
    threadgroup uint simdTotals[kSimdGroups];
    const uint base = block * kBlock + tid * kScanItems;
    uint values[kScanItems];
    uint local = 0;
    for (uint i = 0; i < kScanItems; ++i) {
        const uint index = base + i;
        const uint v = index < count ? input[index] : 0u;
        values[i] = local;
        local += v;
    }
    const uint simdPrefix = simd_prefix_exclusive_sum(local);
    if (lane == 31) simdTotals[simd] = simdPrefix + local;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (simd == 0) {
        const uint total = lane < kSimdGroups ? simdTotals[lane] : 0u;
        const uint prefix = simd_prefix_exclusive_sum(total);
        if (lane < kSimdGroups) simdTotals[lane] = prefix;
        if (lane == kSimdGroups - 1) blockSums[block] = prefix + total;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint offset = simdTotals[simd] + simdPrefix;
    for (uint i = 0; i < kScanItems; ++i) {
        const uint index = base + i;
        if (index < count) output[index] = values[i] + offset;
    }
}

/// Adds the scanned block totals back to every element of the block.
kernel void scan_add(device uint* output [[buffer(0)]],
                     device const uint* blockOffsets [[buffer(1)]],
                     constant uint& count [[buffer(2)]],
                     uint tid [[thread_index_in_threadgroup]],
                     uint block [[threadgroup_position_in_grid]]) {
    const uint offset = blockOffsets[block];
    const uint base = block * kBlock + tid * kScanItems;
    for (uint i = 0; i < kScanItems; ++i) {
        const uint index = base + i;
        if (index < count) output[index] += offset;
    }
}

/// Per-block digit histogram, stored digit-major so one exclusive scan gives scatter bases.
kernel void radix_histogram(device const uint* keys [[buffer(0)]],
                            device uint* histogram [[buffer(1)]],
                            constant uint& count [[buffer(2)]],
                            constant uint& shift [[buffer(3)]],
                            constant uint& blocks [[buffer(4)]],
                            uint tid [[thread_index_in_threadgroup]],
                            uint block [[threadgroup_position_in_grid]]) {
    threadgroup atomic_uint bins[256];
    atomic_store_explicit(&bins[tid], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint r = 0; r < kScanItems; ++r) {
        const uint index = block * kBlock + r * kScanThreads + tid;
        if (index < count) atomic_fetch_add_explicit(&bins[(keys[index] >> shift) & 255u], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    histogram[tid * blocks + block] = atomic_load_explicit(&bins[tid], memory_order_relaxed);
}

/// Stable scatter by one 8-bit digit. Elements are ranked in index order: rounds of 256,
/// SIMD groups in order within a round, lanes in order within a SIMD group.
kernel void radix_scatter(device const uint* keysIn [[buffer(0)]],
                          device const uint* valuesIn [[buffer(1)]],
                          device uint* keysOut [[buffer(2)]],
                          device uint* valuesOut [[buffer(3)]],
                          device const uint* scannedHistogram [[buffer(4)]],
                          constant uint& count [[buffer(5)]],
                          constant uint& shift [[buffer(6)]],
                          constant uint& blocks [[buffer(7)]],
                          uint tid [[thread_index_in_threadgroup]],
                          uint block [[threadgroup_position_in_grid]],
                          uint lane [[thread_index_in_simdgroup]],
                          uint simd [[simdgroup_index_in_threadgroup]]) {
    threadgroup uint digitBase[256];
    threadgroup uint simdCounts[kSimdGroups][256];
    digitBase[tid] = scannedHistogram[tid * blocks + block];
    const ulong below = (1ul << lane) - 1ul;
    for (uint r = 0; r < kScanItems; ++r) {
        for (uint s = 0; s < kSimdGroups; ++s) simdCounts[s][tid] = 0u;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const uint index = block * kBlock + r * kScanThreads + tid;
        const bool valid = index < count;
        const uint key = valid ? keysIn[index] : 0u;
        const uint digit = (key >> shift) & 255u;
        ulong match = static_cast<ulong>(static_cast<simd_vote::vote_t>(simd_ballot(valid)));
        for (uint b = 0; b < 8; ++b) {
            const bool bit = ((digit >> b) & 1u) != 0u;
            const ulong vote = static_cast<ulong>(static_cast<simd_vote::vote_t>(simd_ballot(bit)));
            match &= bit ? vote : ~vote;
        }
        const uint rank = popcount(match & below);
        if (valid && rank == 0) simdCounts[simd][digit] = popcount(match);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // Thread `tid` owns digit `tid`: prefix over SIMD groups, then advance the block base.
        uint running = digitBase[tid];
        for (uint s = 0; s < kSimdGroups; ++s) {
            const uint c = simdCounts[s][tid];
            simdCounts[s][tid] = running;
            running += c;
        }
        digitBase[tid] = running;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (valid) {
            const uint position = simdCounts[simd][digit] + rank;
            keysOut[position] = key;
            valuesOut[position] = valuesIn[index];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

/// values[i] = i, used before sorting Gaussian indices by depth.
kernel void iota_uint(device uint* values [[buffer(0)]],
                      constant uint& count [[buffer(1)]],
                      uint index [[thread_position_in_grid]]) {
    if (index < count) values[index] = index;
}

/// Gathers `source[indices[i]]` (used to order per-Gaussian tile counts by depth).
kernel void gather_uint(device const uint* source [[buffer(0)]],
                        device const uint* indices [[buffer(1)]],
                        device uint* output [[buffer(2)]],
                        constant uint& count [[buffer(3)]],
                        uint index [[thread_position_in_grid]]) {
    if (index < count) output[index] = source[indices[index]];
}
