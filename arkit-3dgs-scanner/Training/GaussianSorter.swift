// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import Metal

/// GPU exclusive scans and stable key/value radix sorts (`GaussianSort.metal`).
/// Scratch buffers grow on demand and are reused across iterations.
nonisolated final class GaussianSorter: @unchecked Sendable {
    static let block = 1024

    private let metal: GaussianMetal
    private let scanBlock, scanAdd, histogram, scatter: MTLComputePipelineState
    /// Per-level block sums of the multi-level scan; level 0 is sized for the largest input.
    private var levels: [MTLBuffer] = []
    private var levelCapacity: [Int] = []
    private var histogramBuffer: MTLBuffer?
    private var histogramScanned: MTLBuffer?
    private let sortTotal: MTLBuffer

    init(metal: GaussianMetal) throws {
        self.metal = metal
        scanBlock = try metal.pipeline("scan_block")
        scanAdd = try metal.pipeline("scan_add")
        histogram = try metal.pipeline("radix_histogram")
        scatter = try metal.pipeline("radix_scatter")
        sortTotal = try metal.buffer(16, label: "radix-total")
    }

    static func blocks(_ count: Int) -> Int { (count + block - 1) / block }

    private func level(_ index: Int, count: Int) throws -> MTLBuffer {
        while levels.count <= index { levels.append(try metal.buffer(16)); levelCapacity.append(0) }
        if levelCapacity[index] < count {
            levels[index] = try metal.buffer(count * 4, label: "scan-level-\(index)")
            levelCapacity[index] = count
        }
        return levels[index]
    }

    /// output[i] = sum(input[0..<i]); `total` receives the sum of all elements.
    /// `input` and `output` must be different buffers.
    func exclusiveScan(_ encoder: MTLComputeCommandEncoder, input: MTLBuffer, inputOffset: Int = 0,
                       output: MTLBuffer, outputOffset: Int = 0, count: Int,
                       total: MTLBuffer, totalOffset: Int = 0, depth: Int = 0) throws {
        guard count > 0 else { return }
        let blocks = Self.blocks(count)
        if blocks == 1 {
            encoder.dispatch(scanBlock, groups: 1, [.buffer(input, inputOffset), .buffer(output, outputOffset),
                                                     .buffer(total, totalOffset), .u32(UInt32(count))])
            return
        }
        let sums = try level(depth * 2, count: blocks)
        let scanned = try level(depth * 2 + 1, count: blocks)
        encoder.dispatch(scanBlock, groups: blocks, [.buffer(input, inputOffset), .buffer(output, outputOffset),
                                                      .buffer(sums), .u32(UInt32(count))])
        try exclusiveScan(encoder, input: sums, output: scanned, count: blocks,
                          total: total, totalOffset: totalOffset, depth: depth + 1)
        encoder.dispatch(scanAdd, groups: blocks, [.buffer(output, outputOffset), .buffer(scanned), .u32(UInt32(count))])
    }

    /// Stable sort of (key, value) pairs by the low `bits` of the key, 8 bits per pass.
    /// `bits` is 16 or 32, an even pass count, so the result ends in `keys`/`values`.
    func sortPairs(_ encoder: MTLComputeCommandEncoder, keys: MTLBuffer, values: MTLBuffer,
                   scratchKeys: MTLBuffer, scratchValues: MTLBuffer, count: Int, bits: Int) throws {
        guard count > 1 else { return }
        let blocks = Self.blocks(count)
        let histogramCount = 256 * blocks
        if (histogramBuffer?.length ?? 0) < histogramCount * 4 {
            histogramBuffer = try metal.buffer(histogramCount * 4, label: "radix-histogram")
            histogramScanned = try metal.buffer(histogramCount * 4, label: "radix-histogram-scanned")
        }
        guard let histogramBuffer, let histogramScanned else { return }
        let total = sortTotal
        precondition(bits == 16 || bits == 32, "radix sort uses an even number of 8-bit passes")
        var source = (keys, values), destination = (scratchKeys, scratchValues)
        for pass in 0..<(bits / 8) {
            let shift = UInt32(pass * 8)
            encoder.dispatch(histogram, groups: blocks, [.buffer(source.0), .buffer(histogramBuffer), .u32(UInt32(count)),
                                                          .u32(shift), .u32(UInt32(blocks))])
            try exclusiveScan(encoder, input: histogramBuffer, output: histogramScanned, count: histogramCount, total: total)
            encoder.dispatch(scatter, groups: blocks, [.buffer(source.0), .buffer(source.1), .buffer(destination.0),
                                                        .buffer(destination.1), .buffer(histogramScanned), .u32(UInt32(count)),
                                                        .u32(shift), .u32(UInt32(blocks))])
            swap(&source, &destination)
        }
    }
}
