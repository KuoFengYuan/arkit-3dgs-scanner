// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,PointCloudFusion}.swift \
//   tools/test_large_scan_memory.swift -o /tmp/fable-large-scan-test
import Foundation
import simd
import CoreGraphics
import ImageIO

@main struct LargeScanMemoryTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1; print("PASS: \(message)")
        }
        let points = (0..<12_000).map { i in
            CloudPoint(x: Float(i % 120) * 0.021, y: Float(i / 120) * 0.021, z: -2,
                       r: 50, g: 100, b: 150, score: 0.7)
        }
        var tiled = TiledFusedGrid(voxelSize: 0.01, tileSize: 1.2, maxCells: 100_000)
        tiled.insert(points, anchorTransforms: [:], cameraPosition: .zero)
        var transforms: [Int64: simd_float4x4] = [:]
        for (id, tile) in tiled.tiles {
            var transform = tile.originLatest; transform.columns.3.x += 0.4
            transforms[id] = transform
        }
        tiled.updateAnchorTransforms(transforms)
        let original = Set(tiled.checkpointPoints(limit: 20_000).map { SIMD3($0.x, $0.y, $0.z) })
        tiled.trimForProcessing(limit: 100)
        let trimmed = tiled.checkpointPoints(limit: 100)
        check(tiled.count == 100 && trimmed.count == 100, "live CPU grid is actually reduced, not only its exported preview")
        check(trimmed.allSatisfy { original.contains(SIMD3($0.x, $0.y, $0.z)) }, "trim preserves corrected world positions without reprojecting anchors")
        check(tiled.voxelSize == 0.01, "fallback compaction does not change the local voxel resolution")
        check(tiled.tiles.allSatisfy { transforms[$0.key] == $0.value.originLatest }, "all anchor transforms survive trimming")
        tiled.insert(points, anchorTransforms: transforms, cameraPosition: .zero)
        check(tiled.count > 100, "resume can add detail after releasing the old live grid")
        tiled.trimForProcessing(limit: 0)
        check(tiled.count == 0, "zero retention releases every cell safely")

        var reference = FusedVoxelGrid(voxelSize: 0.01, maxCells: 100_000)
        var mobile = FusedVoxelGrid(voxelSize: 0.01, maxCells: 100_000)
        for round in 0..<8 {
            var samples = Array(points.prefix(2048))
            for i in samples.indices { samples[i].score = Float(round + 1) * 0.17; samples[i].r = UInt8(round * 20) }
            reference.insert(samples, measured: round != 0)
            mobile.insert(samples, measured: round != 0, boundedMemory: true)
        }
        func sorted(_ grid: FusedVoxelGrid) -> [CloudPoint] {
            grid.exportPoints(target: 100_000, minNeighbors: 0).sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        }
        let a = sorted(reference), b = sorted(mobile)
        check(a.count == b.count && zip(a,b).allSatisfy {
            $0.x.bitPattern == $1.x.bitPattern && $0.y.bitPattern == $1.y.bitPattern && $0.z.bitPattern == $1.z.bitPattern
                && $0.r == $1.r && $0.g == $1.g && $0.b == $1.b && $0.score.bitPattern == $1.score.bitPattern
        }, "bounded insertion matches parallel weighted fusion bit for bit without capacity pressure")
        var small = FusedVoxelGrid(voxelSize: 0.01, maxCells: 128)
        small.insert(points, boundedMemory: true)
        check(small.count <= 128 && small.count > 0, "chunked mobile insertion obeys capacity after a large incoming batch")

        // Match the cell count in the user's large-scene log, without retaining a full
        // 520k-point source array alongside the grid. Mobile inserts fixed-size batches.
        func largeGridCheck() -> (Int, Int, Float) {
            var grid = FusedVoxelGrid(voxelSize: 0.02, maxCells: 786_432)
            for batch in 0..<520 {
                let incoming = (0..<1000).map { column in
                    CloudPoint(x: Float(column) * 0.021, y: Float(batch) * 0.021, z: -2,
                               r: 50, g: 100, b: 150)
                }
                grid.insert(incoming, boundedMemory: true)
            }
            let output = grid.exportPoints(target: 250_000, minNeighbors: 0, boundedMemory: true)
            return (grid.count, output.count, output.map(\.x).max()! - output.map(\.x).min()!)
        }
        let large = largeGridCheck()
        check(large.0 == 520_000, "large-scene fixture contains 520000 native-resolution cells")
        check(large.1 == 250_000, "large-scene output stays at 250000 points without a second voxel dictionary")
        check(large.2 > 20, "bounded output still covers the full twenty-meter synthetic surface")

        let width = 256, height = 192
        let k = CameraIntrinsics(fx: 200, fy: 200, cx: 128, cy: 96, width: width, height: height)
        let values = [Float](repeating: 2, count: width * height)
        let depth = values.withUnsafeBytes { Data($0) }
        let view = DepthConsistencyView(depth: depth, confidence: nil, intrinsics: k, c2w: matrix_identity_float4x4)!
        var cache = DepthViewCache(byteLimit: depth.count * 2, entryLimit: 8)
        for id in 0..<1000 { _ = cache.view(index: id, load: { view }) }
        check(cache.peakBytes <= depth.count * 2 && cache.peakEntries == 2, "byte budget overrides entry limit across 1000 distinct depth views")
        _ = cache.view(index: 999, load: { fatalError("cached depth was loaded again") })
        check(cache.hits == 1, "recent neighbor depth is reused")
        cache.clear()
        check(cache.retainedBytes == 0, "pressure/finish releases cached depth storage")
        var tiny = DepthViewCache(byteLimit: 1)
        check(tiny.view(index: 0, load: { view }) != nil && tiny.retainedBytes == 0, "oversized view is usable but not retained in cache")
        check(tiny.view(index: 1, load: { nil }) == nil, "missing neighbor cannot reuse another frame's depth")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fable-1000-frames-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("depth"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try depth.write(to: dir.appendingPathComponent("depth/wall.bin"))
        let rgba = Data(repeating: 160, count: width * height * 4)
        let provider = CGDataProvider(data: rgba as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(dir.appendingPathComponent("images/wall.jpg") as CFURL,
                                                           "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        let records = (0..<1000).map { id -> FrameRecord in
            var pose = matrix_identity_float4x4
            pose.columns.3.x = Float(id % 101) * 0.01
            return FrameRecord(id: id, timestamp: Double(id) * 0.15, transform: RefusionEngine.rowMajor(pose),
                intrinsics: k, exposureDuration: 0.005, exposureOffsetEV: 0, estimatedBlurPx: 0,
                imageFile: "wall.jpg", depthFile: "wall.bin", depthWidth: width, depthHeight: height)
        }
        var config = CaptureConfig()
        config.exportMaxPoints = 1000
        config.refuseMemoryBudgetMB = 1
        let result = RefusionEngine.refuseWithReport(records: records, sessionDir: dir, config: config,
            target: 2_000_000, availableMemory: { 512 * 1_024 * 1_024 }, progress: { _ in })
        check(result.report.status == "completed" && result.report.completedFrames == 1000,
              "1000 disk-backed frames finish with full 256x192 depth and cross-view validation")
        check(result.points.count <= 1000 && !result.points.isEmpty && result.report.effectiveOutputLimit == 1000,
              "floor-plan override cannot bypass the mobile output budget")
        check(result.report.peakCells <= RefusionEngine.workingSetCellLimit(megabytes: 1),
              "fusion grid stays within its configured budget throughout a thousand-frame run")
        check(result.report.depthCachePeakBytes <= 2 * 1_024 * 1_024 && result.report.depthCachePeakEntries <= 8,
              "neighbor cache remains fixed size across the entire scan")
        check(result.report.depthCacheHits > 0 && result.report.depthCacheLoads <= 4 * records.count,
              "spatially diverse references reuse cached views with at most four loads per frame")
        check(result.points.allSatisfy { abs($0.z + 2) < 0.001 }, "bounded thousand-frame processing preserves the known wall plane")
        var polls = 0
        let cancelled = RefusionEngine.refuseWithReport(records: records, sessionDir: dir, config: config,
            availableMemory: { 512 * 1_024 * 1_024 }, isCancelled: { polls += 1; return polls >= 3 }, progress: { _ in })
        check(cancelled.report.status == "cancelled" && cancelled.report.completedFrames == 1 && cancelled.points.isEmpty,
              "leaving a scan cancels between frames without publishing a partial cloud")
        check(fm.fileExists(atPath: dir.appendingPathComponent("images/wall.jpg").path)
              && fm.fileExists(atPath: dir.appendingPathComponent("depth/wall.bin").path),
              "cancellation preserves source image and depth files")
        print("\(checks) checks passed")
    }
}
