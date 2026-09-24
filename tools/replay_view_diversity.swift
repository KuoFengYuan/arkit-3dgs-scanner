// Replays a saved LiDAR scan through the live preview grid and compares its view-coverage
// heat map with the true angular span of the viewing directions. Reads the scan only.
//
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,PointCloudFusion}.swift \
//   tools/replay_view_diversity.swift -o /tmp/replay_view_diversity
// /tmp/replay_view_diversity SCAN [--poses FILE] [--stride PX]
//
// For every depth frame, confident depth samples are inserted into `TiledFusedGrid` from the
// frame's camera position, as the live preview does (without its per-frame filters).
// - truth: per 10 cm region, the largest angle between any two camera directions seen from the
//   region centre (deduplicated at 0.5°, exact pairwise maximum);
// - current: the grid's two-direction span (`TiledFusedGrid.ViewSpan`);
// - earlier: the previous rating, 8 world azimuth × 2 elevation bins per 1 cm voxel, green at 3.
import Foundation
import simd

@main struct ReplayViewDiversity {
    static func earlierBit(_ d: SIMD3<Float>) -> UInt16 {
        let n = simd_normalize(d)
        var a = Int(((atan2(n.z, n.x) + .pi) / (2 * .pi) * 8).rounded(.down))
        a = min(max(a, 0), 7)
        return UInt16(1) << UInt16((n.y > 0.35 ? 1 : 0) * 8 + a)
    }

    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { print("Usage: replay_view_diversity SCAN [--poses FILE] [--stride PX]"); exit(2) }
        let scan = URL(fileURLWithPath: args.removeFirst())
        var posesPath: String?, stride = 8
        while !args.isEmpty {
            switch args.removeFirst() {
            case "--poses": posesPath = args.removeFirst()
            case "--stride": stride = Int(args.removeFirst()) ?? 8
            default: print("Unknown option"); exit(2)
            }
        }
        let url = posesPath.map { URL(fileURLWithPath: $0) } ?? scan.appendingPathComponent("review-poses.jsonl")
        let decoder = JSONDecoder()
        let records = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { try decoder.decode(FrameRecord.self, from: Data($0.utf8)) }
            .filter { $0.depthFile != nil && $0.transform.count == 16 }
            .sorted { $0.timestamp < $1.timestamp }
        let config = CaptureConfig()
        var grid = TiledFusedGrid(voxelSize: config.voxelSizeM, tileSize: config.previewTileSizeM, maxCells: 4_000_000)
        var earlier = [Int64: UInt16]()                 // 1 cm world voxel → bins
        var truth = [Int64: Set<Int64>]()               // 10 cm world region → quantized directions
        var directionOf = [Int64: SIMD3<Float>]()
        for record in records {
            guard let dw = record.depthWidth, let dh = record.depthHeight, let name = record.depthFile,
                  let depth = try? Data(contentsOf: scan.appendingPathComponent("depth").appendingPathComponent(name)),
                  depth.count == dw * dh * 4 else { continue }
            let conf = record.confidenceFile.flatMap { try? Data(contentsOf: scan.appendingPathComponent("depth").appendingPathComponent($0)) }
            let k = record.intrinsics.scaled(toWidth: dw, height: dh)
            let c2w = RefusionEngine.float4x4(rowMajor: record.transform)
            let camera = SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z)
            var points = [CloudPoint]()
            depth.withUnsafeBytes { raw in
                let d = raw.bindMemory(to: Float.self)
                for v in Swift.stride(from: 0, to: dh, by: stride) { for u in Swift.stride(from: 0, to: dw, by: stride) {
                    let z = d[v * dw + u]
                    guard z > 0.2, z < 5, conf.map({ $0.count == dw * dh && $0[v * dw + u] >= 2 }) ?? true else { continue }
                    let local = SIMD4<Float>((Float(u) - Float(k.cx)) / Float(k.fx) * z, -(Float(v) - Float(k.cy)) / Float(k.fy) * z, -z, 1)
                    let w = c2w * local
                    points.append(CloudPoint(x: w.x, y: w.y, z: w.z, r: 128, g: 128, b: 128))
                } }
            }
            grid.insert(points, anchorTransforms: [:], cameraPosition: camera)
            for p in points {
                let world = SIMD3(p.x, p.y, p.z), toCamera = camera - world
                if let key = PointCloudMath.voxelKey(world, size: config.voxelSizeM) { earlier[key, default: 0] |= earlierBit(toCamera) }
                if let region = PointCloudMath.voxelKey(world, size: TiledFusedGrid.viewCellSize) {
                    // Camera direction from the region centre: the diversity of camera positions.
                    let n = simd_normalize(camera - PointCloudMath.cellCenter(region, size: TiledFusedGrid.viewCellSize))
                    // 0.5° buckets on the unit sphere (azimuth × elevation).
                    let degreesPerRadian: Float = 180 / .pi
                    let azimuthAngle: Float = atan2(n.z, n.x) + .pi
                    let elevationAngle: Float = asin(max(-1, min(1, n.y))) + .pi / 2
                    let azimuth = Int64((azimuthAngle * degreesPerRadian * 2).rounded())
                    let elevation = Int64((elevationAngle * degreesPerRadian * 2).rounded())
                    let bucket = azimuth * 1000 + elevation
                    if truth[region, default: []].insert(bucket).inserted { directionOf[region &* 1_000_003 &+ bucket] = n }
                }
            }
        }
        // Exact largest pairwise angle per region.
        var truthSpan = [Int64: Float]()
        for (region, buckets) in truth {
            let dirs = buckets.compactMap { directionOf[region &* 1_000_003 &+ $0] }
            var minCos: Float = 1
            for i in dirs.indices { for j in (i + 1)..<dirs.count { minCos = min(minCos, simd_dot(dirs[i], dirs[j])) } }
            truthSpan[region] = acos(max(-1, min(1, minCos))) * 180 / .pi
        }
        // Per 1 cm voxel: truth span of its region, earlier bins, current span.
        func band(_ degrees: Float) -> Int { degrees < 10 ? 0 : (degrees < 30 ? 1 : 2) }
        var earlierVsTruth = [[Int]](repeating: [0, 0, 0], count: 3), currentVsTruth = earlierVsTruth
        var errors = [Float](), total = 0, truthWell = 0, earlierWell = 0, currentWell = 0
        for (tileKey, tile) in grid.tiles {
            _ = tileKey
            for cell in tile.cells.values {
                let world = cell.mean + tile.center
                guard let region = PointCloudMath.voxelKey(world, size: TiledFusedGrid.viewCellSize),
                      let t = truthSpan[region],
                      let fine = PointCloudMath.voxelKey(world, size: config.voxelSizeM) else { continue }
                let bins = (earlier[fine] ?? 0).nonzeroBitCount
                let current = PointCloudMath.voxelKey(cell.mean, size: TiledFusedGrid.viewCellSize).flatMap { tile.views[$0] }?.degrees ?? 0
                total += 1
                if t >= 30 { truthWell += 1 }
                if bins >= 3 { earlierWell += 1 }
                if current >= 30 { currentWell += 1 }
                earlierVsTruth[band(t)][min(2, max(0, bins - 1))] += 1
                currentVsTruth[band(t)][band(current)] += 1
                errors.append(abs(current - t))
            }
        }
        errors.sort()
        func pct(_ x: Int) -> String { String(format: "%.1f%%", Double(x) / Double(max(1, total)) * 100) }
        print("SCAN \(scan.lastPathComponent): \(records.count) depth frames, \(total) voxels")
        print("well observed (>=30° true span): truth \(pct(truthWell)), earlier bins>=3 \(pct(earlierWell)), current \(pct(currentWell)); live completeness \(String(format: "%.1f%%", grid.fusionCompleteness * 100))")
        print(String(format: "current vs truth span: median |error| %.2f°, P90 %.2f°", errors.isEmpty ? 0 : errors[errors.count / 2],
                     errors.isEmpty ? 0 : errors[Int(Double(errors.count - 1) * 0.9)]))
        let names = ["<10°", "10-30°", ">=30°"]
        print("rows = true span; earlier columns = 1 / 2 / >=3 bins; current columns = <10 / 10-30 / >=30°")
        for i in 0..<3 {
            print("  \(names[i].padding(toLength: 7, withPad: " ", startingAt: 0)) earlier \(earlierVsTruth[i].map(pct).joined(separator: " / "))   current \(currentVsTruth[i].map(pct).joined(separator: " / "))")
        }
    }
}
