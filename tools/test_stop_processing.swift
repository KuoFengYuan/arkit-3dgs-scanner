import Foundation
import simd

@main struct StopProcessingTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1; print("PASS: \(message)") }
        let mib: UInt64 = 1_024 * 1_024
        check(RefusionEngine.cellBudget(configured: 4_000_000, availableBytes: 32 * mib) < 200_000,
              "low memory no longer forces a 200k-cell allocation")
        check(RefusionEngine.cellBudget(configured: 4_000_000, availableBytes: 0) == 1,
              "zero headroom never returns the full configured cloud budget")
        let budget = RefusionEngine.cellBudget(configured: 4_000_000, availableBytes: 128 * mib)
        check(UInt64(budget * 80) <= 16 * mib, "128 MiB headroom reserves space for other processing allocations")
        check(RefusionEngine.cellBudget(configured: 1000, availableBytes: 8_000 * mib) == 1000,
              "memory budget never exceeds the configured point limit")
        for total in [0, 1, 149_999, 150_000, 150_001, 2_000_000, 20_000_000] {
            let stride = RefusionEngine.meshSampleStride(vertexCount: total, limit: 150_000)
            let sampled = total / stride + (total % stride == 0 ? 0 : 1)
            check(sampled <= 150_000, "mesh snapshot remains capped for \(total) source vertices")
        }
        var grid = FusedVoxelGrid(voxelSize: 0.01, maxCells: 128)
        let points = (0..<12_000).map { i in
            CloudPoint(x: Float(i % 120) * 0.021, y: Float(i / 120) * 0.021, z: -2, r: 40, g: 90, b: 120)
        }
        grid.insert(points)
        check(grid.count <= 128, "one large batch is repeatedly coarsened until it meets the memory cap")
        check(!grid.exportPoints(target: 128, minNeighbors: 0).isEmpty, "memory degradation keeps usable geometry")
        var tiled = TiledFusedGrid(voxelSize: 0.01, tileSize: 1.2, maxCells: 100_000)
        tiled.insert(points, anchorTransforms: [:], cameraPosition: .zero)
        let saved = tiled.checkpointPoints(limit: 100)
        check(saved.count > 0 && saved.count <= 100, "checkpoint output stays bounded without copying the full cloud")
        check(tiled.count == points.count, "saving a checkpoint preserves the accumulator for resume")
        check(tiled.checkpointPoints(limit: 0).isEmpty, "zero checkpoint limit is safe")
        check(RefusionEngine.shouldStopForMemory(availableBytes: 95 * mib), "critical runtime headroom requests an orderly fallback")
        check(!RefusionEngine.shouldStopForMemory(availableBytes: 128 * mib), "noncritical headroom can continue with a smaller grid")
        check(RefusionEngine.workingSetCellLimit(megabytes: 96) == 786_432, "device dictionary budget has an absolute ceiling")
        let reduced = RefusionEngine.pressureCellLimit(currentLimit: 786_432, currentCells: 500_000, availableBytes: 128 * mib)
        check(reduced < 500_000 && reduced > 0, "pressure appearing midscan lowers the existing grid budget")
        check(RefusionEngine.pressureCellLimit(currentLimit: 2000, currentCells: 1000, availableBytes: 512 * mib) == 2000,
              "stable headroom does not repeatedly shrink the grid")
        var exportGrid = FusedVoxelGrid(voxelSize: 0.01, maxCells: 100_000)
        exportGrid.insert(points)
        let bounded = exportGrid.exportPoints(target: 100, minNeighbors: 0, boundedMemory: true)
        check(bounded.count == 100 && exportGrid.count == points.count, "bounded export never materializes or destroys the entire cloud")
        check((bounded.map(\.x).max()! - bounded.map(\.x).min()!) > 2 && (bounded.map(\.y).max()! - bounded.map(\.y).min()!) > 1.5,
              "bounded export retains coverage across the scanned surface")
        exportGrid.reduceCapacity(to: 128)
        check(exportGrid.count <= 128 && exportGrid.count > 0, "runtime capacity reduction keeps a bounded usable grid")
        var origin = FusedVoxelGrid(voxelSize: 0.01, maxCells: 1)
        origin.insert([CloudPoint(x: -1, y: 0, z: 0, r: 1, g: 1, b: 1), CloudPoint(x: 1, y: 0, z: 0, r: 1, g: 1, b: 1)])
        check(origin.count == 1 && origin.voxelSize.isFinite, "opposite sides of origin cannot cause an endless coarsening loop")
        check(exportGrid.exportPoints(target: 0, minNeighbors: 0, boundedMemory: true).isEmpty, "zero export budget is safe")
        print("\(checks) checks passed")
    }
}
