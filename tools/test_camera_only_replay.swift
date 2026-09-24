// Synthetic checks for the camera-only replay metrics (tools/camera_only_metrics.swift).
// bash tools/test_camera_only_replay.sh
import Foundation
import simd

@main struct CameraOnlyReplayTests {
    typealias M = CameraOnlyMetrics
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if value { print("PASS: \(message)") } else { failures += 1; print("FAIL: \(message)") }
    }

    static func near(_ value: Double?, _ expected: Double, _ tolerance: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    /// Deterministic pseudo-random numbers in [0, 1).
    struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }

    static func rotation(yaw: Double, pitch: Double) -> simd_double3x3 {
        let ry = simd_double3x3(rows: [SIMD3(cos(yaw), 0, sin(yaw)), SIMD3(0, 1, 0), SIMD3(-sin(yaw), 0, cos(yaw))])
        let rx = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(pitch), -sin(pitch)), SIMD3(0, sin(pitch), cos(pitch))])
        return ry * rx
    }

    static func axisAngle(_ axis: SIMD3<Double>, _ angle: Double) -> simd_double3x3 {
        let q = simd_quatd(angle: angle, axis: simd_normalize(axis))
        return simd_double3x3(q)
    }

    /// 12 m curved path sampled every 1 cm of arc parameter, with changing yaw and pitch.
    static func trajectory() -> [M.Pose] {
        (0...1200).map { k in
            let s = Double(k) * 0.01
            return M.Pose(id: k, timestamp: Double(k) * 0.02, rotation: rotation(yaw: 0.3 * s, pitch: 0.2 * sin(s)),
                          center: SIMD3(s, 0.3 * sin(s / 2), 0.5 * sin(s / 4)))
        }
    }

    static func pathLengths(_ poses: [M.Pose]) -> [Double] {
        var path = [0.0]
        for (a, b) in zip(poses, poses.dropFirst()) { path.append(path[path.count - 1] + simd_distance(a.center, b.center)) }
        return path
    }

    static func poseTests() {
        let reference = trajectory()

        let same = M.comparePoses(candidate: reference, reference: reference)
        check(same.commonFrames == reference.count && same.rawPositionMaxM == 0 && near(same.rawRotationMaxDeg, 0, 1e-6),
              "identical trajectories have zero raw position/rotation difference")
        check(near(same.alignedATERMSEM, 0, 1e-9) && near(same.alignedRotationMedianDeg, 0, 1e-6) && near(same.sim3Scale, 1, 1e-9),
              "identical trajectories: aligned ATE 0, Sim(3) scale 1 (\(same.sim3Scale ?? .nan))")
        check(same.relativePoseErrors.count == 2 && same.relativePoseErrors.allSatisfy {
            $0.pairs > 0 && near($0.translationP90M, 0, 1e-9) && near($0.rotationP90Deg, 0, 1e-6)
        }, "identical trajectories: 1 m / 5 m RPE are zero")

        // Rigid transform: a different world frame, same shape.
        let R = axisAngle(SIMD3(0.3, 1, -0.2), 30 * .pi / 180), t = SIMD3(2.0, -1.0, 3.0)
        let rigid = reference.map { M.Pose(id: $0.id, timestamp: $0.timestamp, rotation: R * $0.rotation, center: R * $0.center + t) }
        let r = M.comparePoses(candidate: rigid, reference: reference)
        check((r.rawPositionMedianM ?? 0) > 1 && (r.rawRotationMedianDeg ?? 0) > 29,
              "rigidly moved trajectory has large raw difference (\(r.rawPositionMedianM ?? .nan) m, \(r.rawRotationMedianDeg ?? .nan)°)")
        check(near(r.alignedATERMSEM, 0, 1e-6) && near(r.alignedRotationMedianDeg, 0, 1e-4) && near(r.alignmentRotationDeg, 30, 1e-4),
              "rigid alignment recovers 30° and removes it: aligned ATE \(r.alignedATERMSEM ?? .nan) m")
        check(near(r.sim3Scale, 1, 1e-6) && r.relativePoseErrors.allSatisfy { near($0.translationP90M, 0, 1e-6) },
              "rigidly moved trajectory: scale 1 and zero RPE")

        // Large rotation (150°) still aligns: the Jacobi solve is not a small-angle approximation.
        let big = axisAngle(SIMD3(-0.5, 0.2, 1), 150 * .pi / 180)
        let flipped = reference.map { M.Pose(id: $0.id, timestamp: $0.timestamp, rotation: big * $0.rotation, center: big * $0.center) }
        let f = M.comparePoses(candidate: flipped, reference: reference)
        check(near(f.alignedATERMSEM, 0, 1e-6) && near(f.alignmentRotationDeg, 150, 1e-4), "150° world rotation is recovered")

        // 2% larger trajectory (e.g. a scale error of monocular reconstruction).
        let scaled = reference.map { M.Pose(id: $0.id, timestamp: $0.timestamp, rotation: $0.rotation, center: $0.center * 1.02) }
        let s = M.comparePoses(candidate: scaled, reference: reference)
        check(near(s.sim3Scale, 1.02, 1e-9), "2% scaled trajectory: Sim(3) scale \(s.sim3Scale ?? .nan)")
        // The chord of a curved window can be slightly shorter, and the first frame past it slightly longer.
        check(s.relativePoseErrors.allSatisfy { near($0.translationMedianPercent, 2, 0.05) }
              && s.relativePoseErrors.allSatisfy { near($0.rotationP90Deg, 0, 1e-6) },
              "2% scaled trajectory: RPE translation ≈ 2% (\(s.relativePoseErrors.map { $0.translationMedianPercent ?? .nan }))")

        // Linear drift of 1 cm per metre travelled along a fixed direction.
        let path = pathLengths(reference), drift = simd_normalize(SIMD3(0.2, 1.0, -0.4))
        let drifting = reference.enumerated().map { i, p in
            M.Pose(id: p.id, timestamp: p.timestamp, rotation: p.rotation, center: p.center + drift * 0.01 * path[i])
        }
        let d = M.comparePoses(candidate: drifting, reference: reference)
        let one = d.relativePoseErrors.first { $0.windowM == 1 }, five = d.relativePoseErrors.first { $0.windowM == 5 }
        check(near(one?.translationMedianM, 0.01, 0.0002) && near(one?.translationP90M, 0.01, 0.0002),
              "1 cm/m drift: 1 m RPE \(one?.translationMedianM ?? .nan) m")
        check(near(five?.translationMedianPercent, 1, 0.02) && near(one?.rotationP90Deg, 0, 1e-6),
              "1 cm/m drift: 5 m RPE \(five?.translationMedianPercent ?? .nan)% with no rotation error")
        check(one.map { $0.pairs > 1000 } ?? false && five.map { $0.pairs > 600 && $0.pairs < one!.pairs } ?? false,
              "RPE windows stop where the remaining path is shorter than the window")

        // Common frames only, sorted by timestamp regardless of input order.
        let subset = Array(drifting.reversed().prefix(400))
        let common = M.comparePoses(candidate: subset, reference: reference.shuffled())
        check(common.commonFrames == 400 && near(common.relativePoseErrors[0].translationMedianM, 0.01, 0.0002),
              "comparison uses common frame IDs in timestamp order")
    }

    static func eigenTests() {
        var random = LCG(state: 7)
        var m = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for r in 0..<4 { for c in r..<4 { let v = random.next() * 2 - 1; m[r][c] = v; m[c][r] = v } }
        let e = M.symmetricEigen4(m)
        var worst = 0.0
        for k in 0..<4 {
            let v = e.vectors[k]
            for r in 0..<4 {
                let av = (0..<4).reduce(0.0) { $0 + m[r][$1] * v[$1] }
                worst = max(worst, abs(av - e.values[k] * v[r]))
            }
            for j in 0..<4 { worst = max(worst, abs((0..<4).reduce(0.0) { $0 + v[$1] * e.vectors[j][$1] } - (j == k ? 1 : 0))) }
        }
        check(worst < 1e-12, "Jacobi 4x4 eigenvectors satisfy Av = λv and are orthonormal (\(worst))")
    }

    static func planeGrid(xCount: Int, yCount: Int, z: Float) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for i in 0..<xCount { for j in 0..<yCount { points.append(SIMD3(Float(i) * 0.01, Float(j) * 0.01, z)) } }
        return points
    }

    static func cloudTests() {
        // Grid search equals brute force.
        var random = LCG(state: 11)
        let cloud = (0..<3000).map { _ in SIMD3(Float(random.next()), Float(random.next()), Float(random.next())) * 0.5 }
        let grid = M.SpatialGrid(cloud, cell: M.accuracyGridCellM)
        var mismatches = 0
        for _ in 0..<600 {
            let q = SIMD3(Float(random.next()), Float(random.next()), Float(random.next())) * 0.7 - 0.1
            let brute = cloud.map { simd_distance($0, q) }.min()!
            let found = grid.nearestDistance(to: q, maxDistance: 0.1)
            if brute <= 0.1 ? found.map({ abs($0 - brute) > 1e-6 }) ?? true : found != nil { mismatches += 1 }
        }
        check(mismatches == 0, "hash-grid nearest distance matches brute force within the 10 cm cap")

        // Reference plane 1 m x 1 m at 1 cm spacing; test plane 1 cm above it over x <= 0.5 m.
        let reference = planeGrid(xCount: 101, yCount: 101, z: 0)
        let test = planeGrid(xCount: 51, yCount: 101, z: 0.01)
        let referenceGrid = M.SpatialGrid(reference, cell: M.accuracyGridCellM)
        let a = M.accuracy(test: test, reference: referenceGrid)
        check(a.testPoints == test.count && near(a.medianM, 0.01, 1e-4) && near(a.p90M, 0.01, 1e-4),
              "1 cm normal offset: accuracy median \(a.medianM ?? .nan) m")
        check(near(a.within2cm, 1, 0) && near(a.beyond10cm, 0, 0), "1 cm offset: all within 2 cm, none beyond 10 cm")

        let levels = M.coverageLevels(reference: reference, test: test)
        let c = M.completeness(levels: levels)
        // Columns covered: x <= 0.50 + dx with sqrt(dx² + 1 cm²) <= τ.
        let expected = [52.0, 55.0, 60.0].map { $0 / 101 }
        check(c.referencePoints == reference.count && zip(c.thresholds, expected).allSatisfy { near($0.fraction, $1, 1e-9) },
              "half-plane completeness at 2/5/10 cm = \(c.thresholds.map { $0.fraction ?? .nan })")
        var bruteCovered = [0, 0, 0]
        for p in reference {
            let nearest = test.map { simd_distance($0, p) }.min()!
            for (k, tau) in M.completenessThresholdsM.enumerated() where Double(nearest) <= tau { bruteCovered[k] += 1 }
        }
        check(c.thresholds.map(\.covered) == bruteCovered, "completeness counts match brute force \(bruteCovered)")
        let mask = reference.map { $0.x < 0.505 }
        let masked = M.completeness(levels: levels, mask: mask)
        check(masked.referencePoints == 51 * 101 && masked.thresholds.allSatisfy { near($0.fraction, 1, 0) },
              "masked completeness counts only masked reference points")
        let empty = M.completeness(levels: M.coverageLevels(reference: reference, test: []))
        check(empty.thresholds.allSatisfy { $0.covered == 0 } && M.accuracy(test: [], reference: referenceGrid).medianM == nil,
              "empty test cloud has zero completeness and no accuracy statistic")

        // Far outliers.
        let outliers = (0..<100).map { SIMD3(Float($0) * 0.01, 0.5, 0.5) }
        let o = M.accuracy(test: test + outliers, reference: referenceGrid)
        check(near(o.beyond10cm, 100.0 / Double(test.count + 100), 1e-12) && near(o.medianM, 0.01, 1e-4),
              "outliers counted beyond 10 cm (\(o.beyond10cm ?? .nan)), median unchanged")

        let spacing = M.medianSpacing(referenceGrid)
        check(near(spacing.medianM, 0.01, 1e-5) && spacing.samples == reference.count, "median spacing of a 1 cm grid is 1 cm")
    }

    static func depthView(_ c2w: simd_float4x4, depth: Float, lowConfidenceColumns: Range<Int> = 0..<0) -> DepthConsistencyView {
        let w = 64, h = 48
        let values = [Float](repeating: depth, count: w * h)
        var confidence = [UInt8](repeating: 2, count: w * h)
        for y in 0..<h { for x in lowConfidenceColumns { confidence[y * w + x] = 0 } }
        let k = CameraIntrinsics(fx: 50, fy: 50, cx: 32, cy: 24, width: w, height: h)
        return DepthConsistencyView(depth: values.withUnsafeBytes { Data($0) }, confidence: confidence, intrinsics: k, c2w: c2w)!
    }

    static func viewedTests() {
        let config = CaptureConfig()
        let (near, far) = (config.rgbMinDepthM, config.pointMaxDepthM)
        let view = depthView(matrix_identity_float4x4, depth: 2, lowConfidenceColumns: 0..<8)
        check(M.isViewed(SIMD3(0, 0, -2), by: view, minDepth: near, maxDepth: far), "point on the LiDAR surface is viewed")
        check(!M.isViewed(SIMD3(0.5, 0.25, -3), by: view, minDepth: near, maxDepth: far), "point behind the LiDAR surface is occluded")
        check(M.isViewed(SIMD3(0, 0, -2.05), by: view, minDepth: near, maxDepth: far)
              && !M.isViewed(SIMD3(0, 0, -2.08), by: view, minDepth: near, maxDepth: far),
              "agreement tolerance is max(3 cm, 3%)")
        check(!M.isViewed(SIMD3(5, 0, -2), by: view, minDepth: near, maxDepth: far)
              && !M.isViewed(SIMD3(0, 0, 2), by: view, minDepth: near, maxDepth: far),
              "points outside the image or behind the camera are not viewed")
        check(!M.isViewed(SIMD3(-1.4, 0, -2), by: view, minDepth: near, maxDepth: far),
              "low-confidence depth does not confirm visibility")
        let close = depthView(matrix_identity_float4x4, depth: 0.2)
        check(!M.isViewed(SIMD3(0, 0, -0.2), by: close, minDepth: near, maxDepth: far), "points nearer than rgbMinDepthM are not viewed")
        // A second camera one metre to the right sees the far point past the first view's wall.
        var side = matrix_identity_float4x4; side.columns.3 = SIMD4(0.5, 0.25, 0, 1)
        let mask = M.viewedMask([SIMD3(0.5, 0.25, -3), SIMD3(0.5, 0.25, -5.5)],
                                views: [view, depthView(side, depth: 3)], minDepth: near, maxDepth: far)
        check(mask == [true, false], "viewed mask accepts a point seen by any frame and rejects one no frame sees")
    }

    static func record(_ id: Int, x: Double, time: Double) -> FrameRecord {
        FrameRecord(id: id, timestamp: time, transform: [1, 0, 0, x, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                    intrinsics: CameraIntrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 1, height: 1),
                    exposureDuration: 0, exposureOffsetEV: 0, estimatedBlurPx: 0, imageFile: "f\(id).jpg")
    }

    static func shutterTests() {
        // 1/64 m steps every 50 ms: 4 cm needs three steps (150 ms).
        let slow = (0..<30).map { record($0, x: Double($0) / 64, time: Double($0) * 0.05) }
        let kept = M.simulateCameraOnlyShutter(slow.shuffled(), minBaselineM: 0.04, minIntervalS: 0.10).map(\.id)
        check(kept == Array(stride(from: 0, to: 30, by: 3)), "shutter keeps frames >= 4 cm apart in timestamp order")
        // 5 cm steps every 40 ms: the 0.10 s interval binds.
        let fast = (0..<12).map { record($0, x: Double($0) * 0.05, time: Double($0) * 0.04) }
        check(M.simulateCameraOnlyShutter(fast, minBaselineM: 0.04, minIntervalS: 0.10).map(\.id) == [0, 3, 6, 9],
              "shutter enforces the 0.10 s minimum interval")
    }

    static func main() {
        poseTests()
        eigenTests()
        cloudTests()
        viewedTests()
        shutterTests()
        print("\(checks - failures)/\(checks) camera-only replay checks passed")
        if failures > 0 { exit(1) }
    }
}
