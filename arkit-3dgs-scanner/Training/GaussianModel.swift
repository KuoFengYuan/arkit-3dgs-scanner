// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import Metal
import simd

/// Planes of the per-row statistics buffer (capacity-strided floats); mirrors GaussianOptim.metal.
nonisolated enum GaussianStats {
    static let visibility = 0, errorMax = 1, edgeSum = 2, shareMax = 3, shareNow = 4, active = 5
    static let planes = 6
}

/// Gaussian parameters with gradients and Adam moments, stored in fixed-capacity shared buffers.
///
/// Rows `0..<count` are in use; pruned rows become free slots (zero quaternion, which the
/// rasterizer culls) and are refilled before the model grows, like LichtFeld's MRNF. The
/// capacity is fixed at creation from the memory plan, so densification can never allocate.
nonisolated final class GaussianModel: @unchecked Sendable {
    let capacity: Int
    let shDegree: Int
    let layout: GaussianLayout
    let params, grads, adamM, adamV, stats: MTLBuffer
    private(set) var count = 0
    /// Free rows below `count`, ascending.
    private(set) var freeRows: [Int] = []
    var activeCount: Int { count - freeRows.count }
    /// Global Adam step (one bias-correction counter for all groups, as upstream).
    var adamStep = 0
    let trainable: Bool

    /// Bytes per Gaussian of capacity: parameters, gradients and two Adam moments, plus statistics.
    static func bytesPerGaussian(shDegree: Int) -> Int {
        GaussianLayout.floatsPerGaussian(shDegree: shDegree) * 4 * 4 + GaussianStats.planes * 4
    }

    /// Bytes per Gaussian of a viewer (inference-only) model.
    static func viewerBytesPerGaussian(shDegree: Int) -> Int {
        GaussianLayout.floatsPerGaussian(shDegree: shDegree) * 4 + GaussianStats.planes * 4
    }

    /// `trainable: false` allocates parameters only (viewer), without gradients or Adam moments.
    init(metal: GaussianMetal, capacity: Int, shDegree: Int, trainable: Bool = true) throws {
        precondition(capacity > 0 && capacity % 4 == 0, "capacity must be a positive multiple of 4")
        self.capacity = capacity
        self.shDegree = shDegree
        layout = GaussianLayout(capacity: capacity, shDegree: shDegree)
        let bytes = layout.totalFloats * 4
        params = try metal.buffer(bytes, label: "gs-params")
        grads = try metal.buffer(trainable ? bytes : 16, label: "gs-grads")
        adamM = try metal.buffer(trainable ? bytes : 16, label: "gs-adam-m")
        adamV = try metal.buffer(trainable ? bytes : 16, label: "gs-adam-v")
        self.trainable = trainable
        stats = try metal.buffer(capacity * GaussianStats.planes * 4, label: "gs-stats")
        for buffer in [params, grads, adamM, adamV, stats] { memset(buffer.contents(), 0, buffer.length) }
    }

    func floats(_ buffer: MTLBuffer) -> UnsafeMutablePointer<Float> {
        buffer.contents().bindMemory(to: Float.self, capacity: buffer.length / 4)
    }

    func stat(_ plane: Int) -> UnsafeMutablePointer<Float> { floats(stats) + plane * capacity }

    var shRest: Int { Int(layout.shRest) }

    // MARK: Initialisation

    /// Seeds one Gaussian per point: isotropic scale from the two nearest neighbours
    /// (ln clamp((d1 + d2) / 4, 1e-3, 0.1 · median size)), opacity 0.5, identity rotation,
    /// DC colour from the point colour, higher SH zero (LichtFeld's MRNF initialisation).
    func initialize(positions: [SIMD3<Float>], colors: [SIMD3<Float>]) {
        let n = min(positions.count, capacity)
        count = n
        freeRows = []
        adamStep = 0
        for buffer in [params, grads, adamM, adamV, stats] { memset(buffer.contents(), 0, buffer.length) }
        if n == 0 { return }
        guard n > 0 else { return }
        let p = floats(params)
        let median = Self.medianSize(positions.prefix(n), percentile: 0.75, floor: 0.01)
        let distances = n >= 3 ? Self.twoNearest(Array(positions.prefix(n))) : [Float](repeating: 0, count: n)
        let active = stat(GaussianStats.active)
        for i in 0..<n {
            for k in 0..<3 { p[Int(layout.means) + 3 * i + k] = positions[i][k] }
            let logScale: Float = n >= 3 ? log(min(max(distances[i] / 4, 1e-3), 0.1 * median)) : 0
            for k in 0..<3 { p[Int(layout.scales) + 3 * i + k] = logScale }
            p[Int(layout.quats) + 4 * i] = 1
            p[Int(layout.opacities) + i] = 0
            for k in 0..<3 { p[Int(layout.sh0) + 3 * i + k] = (colors[i][k] - 0.5) / 0.28209479177387814 }
            active[i] = 1
        }
    }

    /// Median of the per-axis central-`percentile` ranges of the positions.
    static func medianSize<C: Collection>(_ points: C, percentile: Double, floor: Float) -> Float where C.Element == SIMD3<Float> {
        guard !points.isEmpty else { return floor }
        let step = max(1, points.count / 100_000)
        var axes: [[Float]] = [[], [], []]
        for (index, point) in points.enumerated() where index % step == 0 { for k in 0..<3 { axes[k].append(point[k]) } }
        let tail = (1 - percentile) / 2
        let ranges = axes.map { values -> Float in
            let sorted = values.sorted()
            let lo = sorted[Int(Double(sorted.count - 1) * tail)], hi = sorted[Int(Double(sorted.count - 1) * (1 - tail))]
            return hi - lo
        }.sorted()
        return max(ranges[1], floor)
    }

    /// Sum of the distances to the two nearest other points, with a uniform hash grid.
    static func twoNearest(_ points: [SIMD3<Float>]) -> [Float] {
        let n = points.count
        var lo = points[0], hi = points[0]
        for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let extent = simd_max(hi - lo, SIMD3(repeating: 1e-3))
        let cell = max(cbrt(extent.x * extent.y * extent.z / Float(n)) * 1.5, 1e-4)
        func key(_ c: SIMD3<Int32>) -> Int64 { (Int64(c.x) << 42) ^ (Int64(c.y) << 21) ^ Int64(c.z) }
        func cellOf(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>(((p - lo) / cell).rounded(.down)) }
        var grid: [Int64: [Int32]] = [:]
        grid.reserveCapacity(n)
        for (i, p) in points.enumerated() { grid[key(cellOf(p)), default: []].append(Int32(i)) }
        var result = [Float](repeating: 0, count: n)
        for (i, p) in points.enumerated() {
            let c = cellOf(p)
            var best = (Float.infinity, Float.infinity)
            var ring: Int32 = 1
            while ring <= 4 {
                for dz in -ring...ring { for dy in -ring...ring { for dx in -ring...ring {
                    // Only the new shell after the first ring.
                    if ring > 1 && max(abs(dx), abs(dy), abs(dz)) < ring { continue }
                    guard let bucket = grid[key(c &+ SIMD3(dx, dy, dz))] else { continue }
                    for j in bucket where Int(j) != i {
                        let d = simd_distance(points[Int(j)], p)
                        if d < best.0 { best = (d, best.0) } else if d < best.1 { best.1 = d }
                    }
                } } }
                // Any point beyond the searched shell is at least `ring * cell` away.
                if best.1 <= Float(ring) * cell { break }
                ring += 1
            }
            if !best.1.isFinite { best = (best.0.isFinite ? best.0 : Float(ring) * cell, Float(ring) * cell) }
            result[i] = best.0 + best.1
        }
        return result
    }

    // MARK: Row edits (CPU; only while the GPU is idle)

    /// Pruned rows keep their memory as free slots: zero quaternion, parameters, moments and gradients.
    func free(rows: [Int]) {
        guard !rows.isEmpty else { return }
        let active = stat(GaussianStats.active)
        for row in rows where active[row] > 0.5 {
            clearState(row: row, clearParameters: true)
            active[row] = 0
        }
        freeRows = Array(Set(freeRows).union(rows)).sorted()
    }

    /// Zero Adam moments and gradients of one row (optionally its parameters too).
    func clearState(row: Int, clearParameters: Bool = false) {
        var buffers = trainable ? [adamM, adamV, grads] : []
        if clearParameters { buffers.append(params) }
        for buffer in buffers {
            let f = floats(buffer)
            for (offset, width) in layout.groups { for k in 0..<width { f[offset + row * width + k] = 0 } }
        }
    }

    /// Rows for `n` new Gaussians: free slots first (lowest index first), then appended rows.
    /// Returns fewer than `n` rows only when the capacity is exhausted.
    func allocateRows(_ n: Int) -> [Int] {
        var rows = Array(freeRows.prefix(n))
        freeRows.removeFirst(rows.count)
        let appended = min(n - rows.count, capacity - count)
        if appended > 0 { rows += Array(count..<(count + appended)); count += appended }
        let active = stat(GaussianStats.active)
        for row in rows { active[row] = 1 }
        return rows
    }

    /// Writes a new isotropic Gaussian into `row` (already allocated) with fresh optimiser state.
    func setSeed(row: Int, _ seed: MRNFStrategy.Seed) {
        clearState(row: row, clearParameters: true)
        let p = floats(params)
        for k in 0..<3 {
            p[Int(layout.means) + 3 * row + k] = seed.position[k]
            p[Int(layout.scales) + 3 * row + k] = log(max(seed.scale, 1e-4))
            p[Int(layout.sh0) + 3 * row + k] = (seed.color[k] - 0.5) / 0.28209479177387814
        }
        p[Int(layout.quats) + 4 * row] = 1
        p[Int(layout.opacities) + row] = MRNFConstants.holeSeedLogit
        for plane in 0..<GaussianStats.planes where plane != GaussianStats.active { stat(plane)[row] = 0 }
    }

    /// Copies all parameters of `source` into `destination` (moments and gradients zeroed).
    func copyRow(_ source: Int, to destination: Int) {
        let p = floats(params)
        for (offset, width) in layout.groups { for k in 0..<width { p[offset + destination * width + k] = p[offset + source * width + k] } }
        clearState(row: destination)
    }

    /// Restores a model from checkpoint arrays (rows in order; free rows excluded).
    func restore(rowCount: Int, adamStep: Int) {
        count = rowCount
        freeRows = []
        self.adamStep = adamStep
        let active = stat(GaussianStats.active)
        for row in 0..<capacity { active[row] = row < rowCount ? 1 : 0 }
    }

    /// Live rows in ascending order.
    var liveRows: [Int] {
        let active = stat(GaussianStats.active)
        return (0..<count).filter { active[$0] > 0.5 }
    }

    func mean(_ row: Int) -> SIMD3<Float> {
        let p = floats(params) + Int(layout.means) + 3 * row
        return SIMD3(p[0], p[1], p[2])
    }
}
