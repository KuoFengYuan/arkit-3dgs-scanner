// Range-priority fusion: far depth fills unobserved surfaces but cannot add a biased second layer.
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,PointCloudFusion}.swift \
//   tools/test_range_priority.swift -o /tmp/fable-range-priority-test
import Foundation
import simd
import CoreGraphics
import ImageIO

@main struct RangePriorityTests {
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0) // keep PASS lines when a failed precondition traps
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1; print("PASS: \(message)")
        }

        // Grid level: far samples live in their own key space and survive coarsening.
        var grid = FusedVoxelGrid(voxelSize: 0.02, maxCells: 1_000_000, farVoxelScale: 2)
        let plane = (0..<400).map { i in
            CloudPoint(x: (Float(i % 20) + 0.5) * 0.02, y: (Float(i / 20) + 0.5) * 0.02, z: -2.01,
                       r: 10, g: 20, b: 30, score: 0.5)
        }
        grid.insert(plane, boundedMemory: true)
        grid.insert(plane, far: true, boundedMemory: true)
        check(grid.count == 400 + 100 && grid.farCount == 100,
              "coincident near and far samples do not merge; far cells use the doubled voxel")
        grid.reduceCapacity(to: 200)
        check(grid.farCount > 0 && grid.count - grid.farCount > 0 && grid.count <= 200,
              "capacity coarsening keeps near and far key spaces separate")

        let width = 256, height = 192
        let k = CameraIntrinsics(fx: 200, fy: 200, cx: 128, cy: 96, width: width, height: height)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fable-range-priority-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("depth"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Near cameras (x 0...0.32 m) measure wall A at z = -2 m from 2 m away.
        // Far cameras (x 3.0...3.32 m, z = +2 m) see wall A 4 m away with a +4 cm range bias
        // (left half) and wall B at z = -2.6 m that no near camera sees (right half).
        let nearDepth = [Float](repeating: 2.0, count: width * height)
        var farDepth = [Float](repeating: 4.6, count: width * height)
        for v in 0..<height { for u in 0..<(width / 2) { farDepth[v * width + u] = 4.04 } }
        try nearDepth.withUnsafeBytes { Data($0) }.write(to: dir.appendingPathComponent("depth/near.bin"))
        try farDepth.withUnsafeBytes { Data($0) }.write(to: dir.appendingPathComponent("depth/far.bin"))
        let rgba = Data(repeating: 150, count: width * height * 4)
        let provider = CGDataProvider(data: rgba as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(dir.appendingPathComponent("images/frame.jpg") as CFURL,
                                                           "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))

        func record(_ id: Int, x: Float, z: Float, time: Double, depth: String) -> FrameRecord {
            var pose = matrix_identity_float4x4
            pose.columns.3 = SIMD4(x, 0, z, 1)
            return FrameRecord(id: id, timestamp: time, transform: RefusionEngine.rowMajor(pose), intrinsics: k,
                               exposureDuration: 0.005, exposureOffsetEV: 0, estimatedBlurPx: 0,
                               imageFile: "frame.jpg", depthFile: depth, depthWidth: width, depthHeight: height)
        }
        let near = (0..<5).map { record($0, x: Float($0) * 0.08, z: 0, time: Double($0) * 0.3, depth: "near.bin") }
        let far = (0..<5).map { record(5 + $0, x: 3 + Float($0) * 0.08, z: 2, time: 10 + Double($0) * 0.3, depth: "far.bin") }

        var config = CaptureConfig()
        config.exportMaxPoints = 1_000_000
        func fuse(_ records: [FrameRecord], _ config: CaptureConfig, bounded: Bool = true) -> RefusionEngine.Result {
            RefusionEngine.refuseWithReport(records: records, sessionDir: dir, config: config,
                availableMemory: { bounded ? 512 * 1_024 * 1_024 : nil }, progress: { _ in })
        }
        // Near cameras cover |y| < 0.94 m of wall A; stay a margin inside that coverage.
        func ghost(_ points: [CloudPoint]) -> Int {
            points.filter { $0.z < -2.025 && $0.z > -2.06 && $0.x > -1 && $0.x < 1.3 && abs($0.y) < 0.7 }.count
        }
        var legacyConfig = config
        legacyConfig.fusionNearRangeM = 0
        let legacy = fuse(near + far, legacyConfig)
        check(legacy.report.status == "completed" && ghost(legacy.points) > 100,
              "legacy fusion reproduces the biased far layer 4 cm behind the near wall")
        check(legacy.report.nearRangeM == nil && legacy.report.farCells == nil,
              "disabled range priority leaves the v7 range fields empty")

        let ranged = fuse(near + far, config)
        check(ranged.report.status == "completed" && ghost(ranged.points) == 0,
              "range priority removes far samples beside the near measured surface")
        check(ranged.points.filter { abs($0.z + 2) < 0.005 && $0.x > -1 && $0.x < 1.3 }.count
                == legacy.points.filter { abs($0.z + 2) < 0.005 && $0.x > -1 && $0.x < 1.3 }.count,
              "near measured wall is unchanged by far-range handling")
        check(ranged.points.contains { abs($0.z + 2.6) < 0.03 },
              "far depth still fills a surface that no near camera observed")
        check(ranged.points.contains { $0.z < -2.025 && $0.z > -2.06 && $0.x > 2.0 && $0.x < 3.0 }
                && ranged.points.contains { $0.z < -2.025 && $0.z > -2.06 && $0.x > 0 && $0.x < 1.3 && abs($0.y) > 1.3 },
              "far depth still fills the parts of the near wall outside near coverage")
        check(ranged.report.nearRangeM == 3 && ranged.report.farVoxelSizeM == 0.04
                && (ranged.report.farCells ?? 0) > 0 && (ranged.report.farExcludedNearSurface ?? 0) > 0
                && (ranged.report.farExportedPoints ?? 0) > 0,
              "refusion report v7 records range, far resolution, exclusions and exported fill")

        let desktop = fuse(near + far, config, bounded: false)
        check(desktop.report.status == "completed" && ghost(desktop.points) == 0
                && desktop.points.contains { abs($0.z + 2.6) < 0.03 },
              "unbounded desktop export applies the same near-surface exclusion")

        func sorted(_ points: [CloudPoint]) -> [CloudPoint] {
            points.sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }
        }
        let a = sorted(fuse(near, config).points), b = sorted(fuse(near, legacyConfig).points)
        check(!a.isEmpty && a.count == b.count && zip(a, b).allSatisfy {
            $0.x.bitPattern == $1.x.bitPattern && $0.y.bitPattern == $1.y.bitPattern && $0.z.bitPattern == $1.z.bitPattern
                && $0.r == $1.r && $0.g == $1.g && $0.b == $1.b && $0.score.bitPattern == $1.score.bitPattern
        }, "scans without far depth fuse bit for bit as before")

        var wide = config
        wide.fusionNearRangeM = wide.pointMaxDepthM
        check(fuse(near + far, wide).report.nearRangeM == nil, "a near range covering all accepted depth disables the split")
        print("\(checks) checks passed")
    }
}
