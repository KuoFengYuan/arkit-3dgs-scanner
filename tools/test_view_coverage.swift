// View-coverage heat map and completeness of the live preview grid (TiledFusedGrid.ViewSpan).
//
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,PointCloudFusion}.swift \
//   tools/test_view_coverage.swift -o /tmp/fable-view-coverage && /tmp/fable-view-coverage
import Foundation
import simd

@main
struct ViewCoverageTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1; print("PASS: \(message)")
    }

    /// Points on a 1 m × 1 m patch of the wall z = -2, optionally jittered along the normal.
    static func wall(jitter: Float = 0, seed: Int = 0) -> [CloudPoint] {
        var points = [CloudPoint](), state = UInt64(seed + 1)
        func random() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) - 0.5
        }
        for y in stride(from: Float(-0.5), to: 0.5, by: 0.01) { for x in stride(from: Float(-0.5), to: 0.5, by: 0.01) {
            points.append(CloudPoint(x: x, y: y, z: -2 + jitter * random(), r: 100, g: 100, b: 100))
        } }
        return points
    }

    static func grid() -> TiledFusedGrid { TiledFusedGrid(voxelSize: 0.01, tileSize: 1.2, maxCells: 2_000_000) }

    /// Largest span over all view cells of the grid.
    static func spans(_ g: TiledFusedGrid) -> [Float] { g.tiles.values.flatMap { $0.views.values.map(\.degrees) } }

    /// Completeness recomputed from the view cells (must equal the O(1) counter).
    static func recount(_ g: TiledFusedGrid) -> Double {
        var well = 0
        for tile in g.tiles.values {
            for cell in tile.cells.values {
                if let key = PointCloudMath.voxelKey(cell.mean, size: TiledFusedGrid.viewCellSize),
                   tile.views[key]?.isWellObserved == true { well += 1 }
            }
        }
        return g.count > 0 ? Double(well) / Double(g.count) : 0
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)   // keep progress visible if a check fails
        // Standing still (rotating in place does not move the camera centre): 0°.
        var still = grid()
        for _ in 0..<20 { still.insert(wall(), anchorTransforms: [:], cameraPosition: SIMD3(0, 0, 0)) }
        check(spans(still).allSatisfy { $0 < 0.5 } && still.fusionCompleteness == 0,
              "repeated views from one position stay at a single angle")

        // A 1.4 m sideways pass at 2 m: about 38° for the centre of the wall.
        var pass = grid()
        for i in 0...14 { pass.insert(wall(), anchorTransforms: [:], cameraPosition: SIMD3(-0.7 + Float(i) * 0.1, 0, 0)) }
        let passSpans = spans(pass).sorted()
        print("sideways pass: span median \(passSpans[passSpans.count / 2])°, completeness \(pass.fusionCompleteness)")
        check(passSpans[passSpans.count / 2] > 30 && pass.fusionCompleteness > 0.9,
              "a 1.4 m sideways pass at 2 m reaches the well-observed span")
        check(abs(pass.fusionCompleteness - recount(pass)) < 1e-9, "the incremental completeness matches a full recount")

        // 5 cm move across the earlier 45° sector boundary: two old bins, but only ~1.4° of parallax.
        var boundary = grid()
        let point = CloudPoint(x: 0, y: 0, z: -2, r: 0, g: 0, b: 0)
        for x: Float in [1.975, 2.025] { boundary.insert([point], anchorTransforms: [:], cameraPosition: SIMD3(x, 0, 0)) }
        check(spans(boundary).allSatisfy { $0 < 2 }, "a small move across an old sector boundary is not multiple angles")

        // A 40° sweep inside one earlier 45° azimuth sector counts as multiple angles.
        var sector = grid()
        for degrees in stride(from: Float(95), through: 135, by: 5) {
            let a = degrees * .pi / 180
            sector.insert([point], anchorTransforms: [:], cameraPosition: SIMD3(2 * cos(a), 0, -2 + 2 * sin(a)))
        }
        check((spans(sector).max() ?? 0) > 38, "a 40° sweep within one old sector is measured as 40°")

        // Vertical parallax: moving 1.2 m up in front of the wall (old bins saw only up/level).
        var vertical = grid()
        for i in 0...12 { vertical.insert(wall(), anchorTransforms: [:], cameraPosition: SIMD3(0, -0.6 + Float(i) * 0.1, 0)) }
        let verticalSpans = spans(vertical).sorted()
        check(verticalSpans[verticalSpans.count / 2] > 28, "moving up and down adds view angle like moving sideways")

        // LiDAR-like noise scatters points over neighbouring 1 cm voxels; the 10 cm view cells do not.
        var noisy = grid()
        for i in 0...14 {
            noisy.insert(wall(jitter: 0.03, seed: i), anchorTransforms: [:], cameraPosition: SIMD3(-0.7 + Float(i) * 0.1, 0, 0))
        }
        print("noisy pass: completeness \(noisy.fusionCompleteness), voxels \(noisy.count)")
        check(noisy.fusionCompleteness > 0.85, "depth noise across voxels does not hide the viewing angles")

        // Heat-map colours: green where well observed, red for a single view.
        let greenTile = pass.tiles.keys.sorted().first!
        let colours = pass.tileRenderData(greenTile, mode: .fusionQuality)!.colors.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let greenShare = Double(stride(from: 0, to: colours.count, by: 3).filter { colours[$0] < 0.2 && colours[$0 + 1] > 0.9 }.count) / Double(colours.count / 3)
        let redTile = still.tiles.keys.sorted().first!
        let red = still.tileRenderData(redTile, mode: .fusionQuality)!.colors.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        check(greenShare > 0.8 && stride(from: 0, to: red.count, by: 3).allSatisfy { red[$0] > 0.99 && red[$0 + 1] < 0.05 },
              "heat map is green for a well-observed wall and red for one viewpoint")

        // Trimming before processing keeps the counter consistent with the remaining voxels.
        var trimmed = pass
        trimmed.trimForProcessing(limit: pass.count / 3)
        check(trimmed.count <= pass.count / 3 + 1 && abs(trimmed.fusionCompleteness - recount(trimmed)) < 1e-9
              && trimmed.fusionCompleteness > 0.9, "trimming keeps the completeness of the remaining voxels")

        // Coarsening at capacity recounts voxels per view cell.
        var capped = TiledFusedGrid(voxelSize: 0.01, tileSize: 1.2, maxCells: 4000)
        for i in 0...14 { capped.insert(wall(), anchorTransforms: [:], cameraPosition: SIMD3(-0.7 + Float(i) * 0.1, 0, 0)) }
        check(capped.voxelSize > 0.01 && abs(capped.fusionCompleteness - recount(capped)) < 1e-9 && capped.fusionCompleteness > 0.9,
              "coarsening keeps a consistent completeness")
        // Points exactly on a tile boundary (x = 0, y = 0 here) join an existing tile instead of
        // starting a new one every frame.
        check(pass.tiles.count == 4, "points on tile boundaries reuse the existing tiles")
        print("\(checks) view coverage checks passed")
    }
}
