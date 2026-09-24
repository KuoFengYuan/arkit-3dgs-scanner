// Pure metrics for the camera-only replay (tools/replay_camera_only.swift) and its synthetic
// tests (tools/test_camera_only_replay.swift). No top-level code; nothing here reads files.
//
// Poses use ARKit camera-to-world matrices (camera looks down -Z, +Y up). Results describe the
// difference from a reference pose set / point cloud, which is itself an estimate rather than
// ground truth.
import Foundation
import simd

nonisolated enum CameraOnlyMetrics {
    // MARK: - Statistics

    /// Linear interpolation between order statistics; `sorted` must be ascending.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let position = max(0, min(1, q)) * Double(sorted.count - 1)
        let low = Int(position.rounded(.down)), high = min(sorted.count - 1, low + 1)
        let fraction = position - Double(low)
        return sorted[low] * (1 - fraction) + sorted[high] * fraction
    }

    static func median(_ values: [Double]) -> Double? { percentile(values.sorted(), 0.5) }

    // MARK: - Simulated capture

    /// Approximates the RGB-mode shutter (SmartShutter with cameraOnly) on already saved frames, in
    /// timestamp order: the first frame is kept; a later frame needs >= minBaselineM from the last
    /// kept camera centre and >= minIntervalS after it. The live shutter's depth-scaled translation
    /// (4-5 cm), 3° rotation trigger and feature/continuity gates are not reproduced.
    static func simulateCameraOnlyShutter(_ records: [FrameRecord], minBaselineM: Double, minIntervalS: Double) -> [FrameRecord] {
        let ordered = records.filter { $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite) && $0.timestamp.isFinite }
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        var kept: [FrameRecord] = []
        for record in ordered {
            if let last = kept.last {
                let a = SIMD3(last.transform[3], last.transform[7], last.transform[11])
                let b = SIMD3(record.transform[3], record.transform[7], record.transform[11])
                guard record.timestamp - last.timestamp >= minIntervalS, simd_distance(a, b) >= minBaselineM else { continue }
            }
            kept.append(record)
        }
        return kept
    }

    // MARK: - Poses

    struct Pose: Sendable {
        var id: Int
        var timestamp: Double
        /// Camera-to-world rotation.
        var rotation: simd_double3x3
        var center: SIMD3<Double>

        init(id: Int, timestamp: Double, rotation: simd_double3x3, center: SIMD3<Double>) {
            self.id = id; self.timestamp = timestamp; self.rotation = rotation; self.center = center
        }

        /// `FrameRecord.transform` is row-major; Double precision is kept from the file.
        init?(record: FrameRecord) {
            let m = record.transform
            guard m.count == 16, m.allSatisfy(\.isFinite), record.timestamp.isFinite else { return nil }
            let rotation = simd_double3x3(columns: (SIMD3(m[0], m[4], m[8]), SIMD3(m[1], m[5], m[9]),
                                                    SIMD3(m[2], m[6], m[10])))
            guard abs(rotation.determinant - 1) < 0.01 else { return nil }
            self.init(id: record.id, timestamp: record.timestamp, rotation: rotation,
                      center: SIMD3(m[3], m[7], m[11]))
        }
    }

    /// Angle of a rotation matrix in degrees; atan2 keeps small angles accurate.
    static func rotationAngleDeg(_ r: simd_double3x3) -> Double {
        let axis = SIMD3(r[1][2] - r[2][1], r[2][0] - r[0][2], r[0][1] - r[1][0]) * 0.5
        let cosine = (r[0][0] + r[1][1] + r[2][2] - 1) * 0.5
        return atan2(simd_length(axis), cosine) * 180 / .pi
    }

    static func rotationDifferenceDeg(_ a: simd_double3x3, _ b: simd_double3x3) -> Double {
        rotationAngleDeg(a.transpose * b)
    }

    /// Cyclic Jacobi eigen-decomposition of a symmetric 4x4 matrix (row-major `m[row][column]`).
    /// Returns eigenvalues and the matching eigenvectors (unit length), unsorted.
    static func symmetricEigen4(_ m: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        precondition(m.count == 4 && m.allSatisfy { $0.count == 4 })
        var a = m
        var v = (0..<4).map { r in (0..<4).map { c in r == c ? 1.0 : 0.0 } }
        let scale = max(1e-300, a.joined().reduce(0) { $0 + $1 * $1 })
        for _ in 0..<64 {
            var off = 0.0
            for p in 0..<4 { for q in 0..<4 where p != q { off += a[p][q] * a[p][q] } }
            if off <= scale * 1e-30 { break }
            for p in 0..<3 { for q in (p + 1)..<4 {
                guard abs(a[p][q]) > 1e-300 else { continue }
                let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<4 {
                    let kp = a[k][p], kq = a[k][q]
                    a[k][p] = c * kp - s * kq; a[k][q] = s * kp + c * kq
                }
                for k in 0..<4 {
                    let pk = a[p][k], qk = a[q][k]
                    a[p][k] = c * pk - s * qk; a[q][k] = s * pk + c * qk
                }
                for k in 0..<4 {
                    let kp = v[k][p], kq = v[k][q]
                    v[k][p] = c * kp - s * kq; v[k][q] = s * kp + c * kq
                }
            } }
        }
        let vectors = (0..<4).map { column in (0..<4).map { v[$0][column] } }
        return ((0..<4).map { a[$0][$0] }, vectors)
    }

    struct RigidAlignment: Sendable {
        /// Maps source points onto target points: target ≈ rotation * source + translation.
        var rotation: simd_double3x3
        var translation: SIMD3<Double>
        /// Umeyama similarity scale of the source relative to the target: the least-squares s in
        /// source ≈ s * rotationᵀ * target + t'. The optimal rotation does not depend on scale.
        var sourceScaleOverTarget: Double?
    }

    /// Horn's closed-form unit-quaternion solution for the least-squares rigid transform.
    static func hornAlignment(source: [SIMD3<Double>], target: [SIMD3<Double>]) -> RigidAlignment? {
        guard source.count == target.count, source.count >= 3 else { return nil }
        let n = Double(source.count)
        let sourceMean = source.reduce(SIMD3<Double>(), +) / n, targetMean = target.reduce(SIMD3<Double>(), +) / n
        var s = simd_double3x3()   // s[column][row] = Σ a_row * b_column
        var targetSpread = 0.0
        for (p, q) in zip(source, target) {
            let a = p - sourceMean, b = q - targetMean
            targetSpread += simd_length_squared(b)
            for row in 0..<3 { for column in 0..<3 { s[column][row] += a[row] * b[column] } }
        }
        func S(_ row: Int, _ column: Int) -> Double { s[column][row] }
        let (xx, xy, xz) = (S(0, 0), S(0, 1), S(0, 2))
        let (yx, yy, yz) = (S(1, 0), S(1, 1), S(1, 2))
        let (zx, zy, zz) = (S(2, 0), S(2, 1), S(2, 2))
        let N: [[Double]] = [
            [xx + yy + zz, yz - zy, zx - xz, xy - yx],
            [yz - zy, xx - yy - zz, xy + yx, zx + xz],
            [zx - xz, xy + yx, -xx + yy - zz, yz + zy],
            [xy - yx, zx + xz, yz + zy, -xx - yy + zz]]
        let eigen = symmetricEigen4(N)
        guard let best = eigen.values.indices.max(by: { eigen.values[$0] < eigen.values[$1] }) else { return nil }
        var q = eigen.vectors[best]
        let norm = q.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm.isFinite, norm > 0 else { return nil }
        q = q.map { $0 / norm }
        let (w, x, y, z) = (q[0], q[1], q[2], q[3])
        let rotation = simd_double3x3(rows: [
            SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)),
            SIMD3(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)),
            SIMD3(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y))])
        var correlation = 0.0
        for (p, q) in zip(source, target) { correlation += simd_dot(q - targetMean, rotation * (p - sourceMean)) }
        return RigidAlignment(rotation: rotation, translation: targetMean - rotation * sourceMean,
                              sourceScaleOverTarget: targetSpread > 1e-18 ? correlation / targetSpread : nil)
    }

    struct RelativePoseError: Codable, Sendable {
        var windowM: Double
        var pairs = 0
        var translationMedianM: Double?
        var translationP90M: Double?
        var translationMedianPercent: Double?
        var translationP90Percent: Double?
        var rotationMedianDeg: Double?
        var rotationP90Deg: Double?
    }

    struct PoseComparison: Codable, Sendable {
        var commonFrames = 0
        var referencePathM = 0.0
        var rawPositionMedianM: Double?
        var rawPositionP95M: Double?
        var rawPositionMaxM: Double?
        var rawRotationMedianDeg: Double?
        var rawRotationP95Deg: Double?
        var rawRotationMaxDeg: Double?
        /// After the best rigid alignment of candidate camera centres onto the reference.
        var alignedATERMSEM: Double?
        var alignedATEMedianM: Double?
        var alignedRotationMedianDeg: Double?
        var alignmentRotationDeg: Double?
        var alignmentTranslationM: Double?
        /// Candidate trajectory size relative to the reference (Umeyama Sim(3)); > 1 means larger.
        var sim3Scale: Double?
        var relativePoseErrors: [RelativePoseError] = []
    }

    /// Candidate vs reference over common frame IDs, in timestamp order.
    static func comparePoses(candidate: [Pose], reference: [Pose], windowsM: [Double] = [1, 5]) -> PoseComparison {
        let byID = Dictionary(candidate.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pairs = reference.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
            .compactMap { r in byID[r.id].map { (candidate: $0, reference: r) } }
        var result = PoseComparison(commonFrames: pairs.count)
        result.relativePoseErrors = windowsM.map { RelativePoseError(windowM: $0) }
        guard !pairs.isEmpty else { return result }
        let positions = pairs.map { simd_distance($0.candidate.center, $0.reference.center) }.sorted()
        let rotations = pairs.map { rotationDifferenceDeg($0.reference.rotation, $0.candidate.rotation) }.sorted()
        result.rawPositionMedianM = percentile(positions, 0.5)
        result.rawPositionP95M = percentile(positions, 0.95)
        result.rawPositionMaxM = positions.last
        result.rawRotationMedianDeg = percentile(rotations, 0.5)
        result.rawRotationP95Deg = percentile(rotations, 0.95)
        result.rawRotationMaxDeg = rotations.last
        var path = [0.0]
        for (a, b) in zip(pairs, pairs.dropFirst()) {
            path.append(path[path.count - 1] + simd_distance(a.reference.center, b.reference.center))
        }
        result.referencePathM = path[path.count - 1]
        if let alignment = hornAlignment(source: pairs.map(\.candidate.center), target: pairs.map(\.reference.center)) {
            let errors = pairs.map { simd_distance(alignment.rotation * $0.candidate.center + alignment.translation,
                                                   $0.reference.center) }
            result.alignedATERMSEM = (errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count)).squareRoot()
            result.alignedATEMedianM = median(errors)
            result.alignedRotationMedianDeg = median(pairs.map {
                rotationDifferenceDeg($0.reference.rotation, alignment.rotation * $0.candidate.rotation)
            })
            result.alignmentRotationDeg = rotationAngleDeg(alignment.rotation)
            result.alignmentTranslationM = simd_length(alignment.translation)
            result.sim3Scale = alignment.sourceScaleOverTarget
        }
        result.relativePoseErrors = windowsM.map { window in
            relativePoseError(pairs.map(\.candidate), pairs.map(\.reference), path: path, windowM: window)
        }
        return result
    }

    /// For each i, j is the first frame whose cumulative reference path is at least `windowM`
    /// beyond i. E = (T_ref_i^-1 T_ref_j)^-1 (T_cand_i^-1 T_cand_j).
    static func relativePoseError(_ candidate: [Pose], _ reference: [Pose], path: [Double], windowM: Double) -> RelativePoseError {
        var result = RelativePoseError(windowM: windowM)
        guard windowM > 0, candidate.count == reference.count, path.count == reference.count else { return result }
        var translations: [Double] = [], rotations: [Double] = []
        var j = 0
        for i in reference.indices {
            if j <= i { j = i + 1 }
            while j < reference.count && path[j] - path[i] < windowM { j += 1 }
            guard j < reference.count else { break }
            let referenceRotation = reference[i].rotation.transpose * reference[j].rotation
            let referenceTranslation = reference[i].rotation.transpose * (reference[j].center - reference[i].center)
            let candidateRotation = candidate[i].rotation.transpose * candidate[j].rotation
            let candidateTranslation = candidate[i].rotation.transpose * (candidate[j].center - candidate[i].center)
            let errorTranslation = referenceRotation.transpose * (candidateTranslation - referenceTranslation)
            translations.append(simd_length(errorTranslation))
            rotations.append(rotationAngleDeg(referenceRotation.transpose * candidateRotation))
        }
        translations.sort(); rotations.sort()
        result.pairs = translations.count
        result.translationMedianM = percentile(translations, 0.5)
        result.translationP90M = percentile(translations, 0.9)
        result.translationMedianPercent = result.translationMedianM.map { $0 / windowM * 100 }
        result.translationP90Percent = result.translationP90M.map { $0 / windowM * 100 }
        result.rotationMedianDeg = percentile(rotations, 0.5)
        result.rotationP90Deg = percentile(rotations, 0.9)
        return result
    }

    // MARK: - Point clouds

    /// Hash grid over a fixed point set. Cells are sorted runs of the point array.
    struct SpatialGrid: Sendable {
        let cell: Float
        private(set) var points: [SIMD3<Float>] = []
        private(set) var sourceIndices: [Int32] = []
        private var cells: [Int64: SIMD2<Int32>] = [:]
        private static let bias: Int64 = 1 << 20

        init(_ input: [SIMD3<Float>], cell: Float) {
            precondition(cell > 0 && cell.isFinite)
            self.cell = cell
            var keyed: [(key: Int64, index: Int32)] = []
            keyed.reserveCapacity(input.count)
            for (i, p) in input.enumerated() {
                if let c = Self.coordinates(p, cell: cell) { keyed.append((Self.key(c.x, c.y, c.z), Int32(i))) }
            }
            keyed.sort { $0.key == $1.key ? $0.index < $1.index : $0.key < $1.key }
            points = keyed.map { input[Int($0.index)] }
            sourceIndices = keyed.map(\.index)
            cells.reserveCapacity(keyed.count / 4 + 1)
            var start = 0
            while start < keyed.count {
                var end = start + 1
                while end < keyed.count && keyed[end].key == keyed[start].key { end += 1 }
                cells[keyed[start].key] = SIMD2(Int32(start), Int32(end))
                start = end
            }
        }

        var count: Int { points.count }

        static func coordinates(_ p: SIMD3<Float>, cell: Float) -> SIMD3<Int64>? {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
            let c = (p / cell).rounded(.down)
            let limit = Float(bias - 2)
            guard abs(c.x) < limit, abs(c.y) < limit, abs(c.z) < limit else { return nil }
            return SIMD3(Int64(c.x), Int64(c.y), Int64(c.z))
        }

        @inline(__always) static func key(_ x: Int64, _ y: Int64, _ z: Int64) -> Int64 {
            (x + bias) | ((y + bias) << 21) | ((z + bias) << 42)
        }

        /// Exact nearest distance up to `maxDistance` (nil beyond it), searched shell by shell.
        func nearestDistance(to p: SIMD3<Float>, maxDistance: Float, excludingSource excluded: Int32? = nil) -> Float? {
            guard let c = Self.coordinates(p, cell: cell) else { return nil }
            let shells = Int64((maxDistance / cell).rounded(.up))
            var best = Float.infinity
            for k in 0...max(0, shells) {
                for dz in -k...k { for dy in -k...k { for dx in -k...k {
                    guard max(abs(dx), abs(dy), abs(dz)) == k,
                          let range = cells[Self.key(c.x + dx, c.y + dy, c.z + dz)] else { continue }
                    for i in Int(range.x)..<Int(range.y) where sourceIndices[i] != excluded {
                        best = min(best, simd_distance_squared(points[i], p))
                    }
                } } }
                // Unvisited cells are at least k cells away.
                if best.squareRoot() <= Float(k) * cell { break }
            }
            let distance = best.squareRoot()
            return distance <= maxDistance ? distance : nil
        }

        /// True if any point lies within `radius` (radius must not exceed the cell size).
        func containsPoint(within radius: Float, of p: SIMD3<Float>) -> Bool {
            guard let c = Self.coordinates(p, cell: cell) else { return false }
            let squared = radius * radius
            for dz in Int64(-1)...1 { for dy in Int64(-1)...1 { for dx in Int64(-1)...1 {
                guard let range = cells[Self.key(c.x + dx, c.y + dy, c.z + dz)] else { continue }
                for i in Int(range.x)..<Int(range.y) where simd_distance_squared(points[i], p) <= squared { return true }
            } } }
            return false
        }
    }

    struct Accuracy: Codable, Sendable {
        var testPoints = 0
        var capM = 0.10
        /// Of capped nearest distances (test point to nearest reference point).
        var medianM: Double?
        var p90M: Double?
        var within1cm: Double?
        var within2cm: Double?
        var within5cm: Double?
        var beyond10cm: Double?
    }

    static let accuracyGridCellM: Float = 0.05

    /// `reference` should be built with `accuracyGridCellM`; any cell size gives exact results.
    static func accuracy(test: [SIMD3<Float>], reference: SpatialGrid, capM: Double = 0.10) -> Accuracy {
        var result = Accuracy(testPoints: test.count, capM: capM)
        guard !test.isEmpty else { return result }
        var distances: [Double] = []
        distances.reserveCapacity(test.count)
        var beyond = 0
        for p in test {
            if let d = reference.nearestDistance(to: p, maxDistance: Float(capM)) { distances.append(Double(d)) }
            else { beyond += 1; distances.append(capM) }
        }
        distances.sort()
        let n = Double(test.count)
        func fraction(_ limit: Double) -> Double {
            // Binary search in the sorted distances.
            var low = 0, high = distances.count
            while low < high { let mid = (low + high) / 2; if distances[mid] <= limit { low = mid + 1 } else { high = mid } }
            return Double(low) / n
        }
        result.medianM = percentile(distances, 0.5)
        result.p90M = percentile(distances, 0.9)
        result.within1cm = fraction(0.01)
        result.within2cm = fraction(0.02)
        result.within5cm = fraction(0.05)
        result.beyond10cm = Double(beyond) / n
        return result
    }

    static let completenessThresholdsM: [Double] = [0.02, 0.05, 0.10]

    /// Index of the smallest threshold (ascending) at which each reference point has a test point
    /// within that distance; `thresholds.count` if none. One grid of cell τ per threshold.
    static func coverageLevels(reference: [SIMD3<Float>], test: [SIMD3<Float>],
                               thresholds: [Double] = completenessThresholdsM) -> [UInt8] {
        precondition(thresholds.count < 255 && zip(thresholds, thresholds.dropFirst()).allSatisfy { $0 < $1 })
        let none = UInt8(thresholds.count)
        guard !test.isEmpty else { return [UInt8](repeating: none, count: reference.count) }
        let radii = thresholds.map { Float($0) }
        let grids = radii.map { SpatialGrid(test, cell: $0) }
        return reference.map { p in
            for (level, radius) in radii.enumerated() where grids[level].containsPoint(within: radius, of: p) {
                return UInt8(level)
            }
            return none
        }
    }

    struct Coverage: Codable, Sendable {
        var thresholdM: Double
        var covered: Int
        var fraction: Double?
    }

    struct Completeness: Codable, Sendable {
        var referencePoints = 0
        var thresholds: [Coverage] = []
    }

    /// Fraction of (optionally masked) reference points with a test point within each threshold.
    static func completeness(levels: [UInt8], thresholds: [Double] = completenessThresholdsM,
                             mask: [Bool]? = nil) -> Completeness {
        precondition(mask == nil || mask!.count == levels.count)
        var histogram = [Int](repeating: 0, count: thresholds.count + 1)
        var total = 0
        for (i, level) in levels.enumerated() where mask?[i] ?? true {
            histogram[min(Int(level), thresholds.count)] += 1; total += 1
        }
        var covered = 0
        return Completeness(referencePoints: total, thresholds: thresholds.enumerated().map { level, threshold in
            covered += histogram[level]
            return Coverage(thresholdM: threshold, covered: covered,
                            fraction: total > 0 ? Double(covered) / Double(total) : nil)
        })
    }

    /// Median nearest-neighbour spacing of `grid`'s own points from a deterministic stride sample.
    static func medianSpacing(_ grid: SpatialGrid, samples: Int = 20_000, maxDistance: Float = 0.10) -> (medianM: Double?, samples: Int) {
        guard grid.count > 1, samples > 0 else { return (nil, 0) }
        let stride = max(1, grid.count / samples)
        var distances: [Double] = []
        var index = 0
        while index < grid.count && distances.count < samples {
            let p = grid.points[index]
            if let d = grid.nearestDistance(to: p, maxDistance: maxDistance, excludingSource: grid.sourceIndices[index]) {
                distances.append(Double(d))
            } else { distances.append(Double(maxDistance)) }
            index += stride
        }
        return (median(distances), distances.count)
    }

    // MARK: - Visibility against LiDAR depth

    /// A point is viewed if it projects inside the depth image, lies in [minDepth, maxDepth] and
    /// agrees with the frame's LiDAR depth at the nearest pixel within max(3 cm, 3%),
    /// with confidence >= 1 (no confidence file: accepted).
    static func isViewed(_ point: SIMD3<Float>, by view: DepthConsistencyView, minDepth: Float, maxDepth: Float) -> Bool {
        let p = view.worldToCamera * SIMD4(point, 1), z = -p.z
        guard z.isFinite, z >= minDepth, z <= maxDepth else { return false }
        let k = view.intrinsics
        let u = Float(k.fx) * p.x / z + Float(k.cx), v = Float(k.cy) - Float(k.fy) * p.y / z
        guard u.isFinite, v.isFinite else { return false }
        let x = Int(u.rounded()), y = Int(v.rounded())
        guard x >= 0, y >= 0, x < k.width, y < k.height else { return false }
        let i = y * k.width + x, measured = view.depth[i]
        guard measured.isFinite, measured > 0, (view.confidence?[i] ?? 2) >= 1 else { return false }
        return abs(measured - z) <= max(0.03, 0.03 * z)
    }

    static func viewedMask(_ points: [SIMD3<Float>], views: [DepthConsistencyView], minDepth: Float, maxDepth: Float) -> [Bool] {
        points.map { p in views.contains { isViewed(p, by: $0, minDepth: minDepth, maxDepth: maxDepth) } }
    }
}
