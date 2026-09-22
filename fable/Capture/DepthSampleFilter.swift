import Foundation
import simd

/// 即時與離線融合共用的深度幾何檢核。以相機空間的法向與實際視線計算入射角。
nonisolated enum DepthSampleFilter {
    static func incidenceWeight(depth: UnsafeBufferPointer<Float>, confidence: [UInt8]?,
                                u: Int, v: Int, width: Int, height: Int,
                                K: CameraIntrinsics, config: CaptureConfig) -> Float? {
        guard u > 0, v > 0, u + 1 < width, v + 1 < height,
              depth.count >= width * height, K.fx > 0, K.fy > 0 else { return nil }
        let i = v * width + u
        let z = depth[i]
        guard z.isFinite, z > config.pointMinDepthM, z < config.pointMaxDepthM else { return nil }
        // 避免在每個深度像素分配暫存陣列。
        for direction in 0..<5 {
            let n: Int
            switch direction {
            case 0: n = i
            case 1: n = i - 1
            case 2: n = i + 1
            case 3: n = i - width
            default: n = i + width
            }
            let d = depth[n]
            guard d.isFinite, d > config.pointMinDepthM, d < config.pointMaxDepthM,
                  abs(d - z) <= z * config.depthEdgeRejectRatio else { return nil }
            if let confidence {
                guard n < confidence.count, confidence[n] >= config.minDepthConfidence else { return nil }
            }
        }
        func point(_ x: Int, _ y: Int, _ d: Float) -> SIMD3<Float> {
            SIMD3((Float(x) - Float(K.cx)) * d / Float(K.fx),
                  (Float(y) - Float(K.cy)) * d / Float(K.fy), d)
        }
        let du = point(u + 1, v, depth[i + 1]) - point(u - 1, v, depth[i - 1])
        let dv = point(u, v + 1, depth[i + width]) - point(u, v - 1, depth[i - width])
        let normal = simd_cross(du, dv)
        let ray = point(u, v, z)
        let denominator = simd_length(normal) * simd_length(ray)
        guard denominator.isFinite, denominator > 1e-10 else { return nil }
        let cosine = min(1, abs(simd_dot(normal, ray)) / denominator)
        guard cosine >= cos(config.depthMaxIncidenceDeg * .pi / 180) else { return nil }
        return cosine * cosine
    }
}

/// 在初始化或重定位後等待連續穩定的追蹤，避免正常／不正常交替時立刻存入外參。
nonisolated struct TrackingStabilityGate {
    private var stableSince: TimeInterval?
    private var lastTimestamp: TimeInterval?

    mutating func reset() { stableSince = nil; lastTimestamp = nil }

    mutating func accepts(isNormal: Bool, timestamp: TimeInterval, duration: TimeInterval = 0.6) -> Bool {
        guard timestamp.isFinite, isNormal else { reset(); return false }
        if let lastTimestamp, timestamp <= lastTimestamp || timestamp - lastTimestamp > 0.25 {
            stableSince = nil
        }
        lastTimestamp = timestamp
        if stableSince == nil { stableSince = timestamp }
        return timestamp - (stableSince ?? timestamp) >= duration
    }
}

/// A compact, owned depth view. Only raw sceneDepth is used for geometric agreement;
/// temporal smoothing can lag moving edges. Camera coordinates are ARKit (-Z forward).
nonisolated struct DepthConsistencyView: Sendable {
    let depth: [Float]
    let confidence: [UInt8]?
    let intrinsics: CameraIntrinsics
    let worldToCamera: simd_float4x4

    init?(depth: Data, confidence: [UInt8]?, intrinsics: CameraIntrinsics, c2w: simd_float4x4) {
        let w = intrinsics.width, h = intrinsics.height
        guard w > 1, h > 1, w <= 4096, h <= 4096, depth.count == w * h * 4,
              confidence == nil || confidence!.count == w * h,
              intrinsics.fx.isFinite, intrinsics.fy.isFinite, intrinsics.fx > 0, intrinsics.fy > 0,
              intrinsics.cx.isFinite, intrinsics.cy.isFinite,
              (0..<4).allSatisfy({ c2w[$0].x.isFinite && c2w[$0].y.isFinite && c2w[$0].z.isFinite && c2w[$0].w.isFinite }),
              abs(simd_determinant(c2w) - 1) < 0.01 else { return nil }
        var values = [Float](repeating: 0, count: w * h)
        _ = values.withUnsafeMutableBytes { depth.copyBytes(to: $0) }
        self.depth = values
        self.confidence = confidence
        self.intrinsics = intrinsics
        self.worldToCamera = c2w.inverse
    }

    enum Agreement { case supported, occluded, contradicted, unobserved }

    struct Sample {
        let projectedDepth: Float
        let measuredDepth: Float
        let tolerance: Float
    }

    func sample(_ point: SIMD3<Float>, config: CaptureConfig) -> Sample? {
        let p = worldToCamera * SIMD4(point, 1), z = -p.z
        guard z.isFinite, z > config.pointMinDepthM, z < config.pointMaxDepthM else { return nil }
        let u = Float(intrinsics.fx) * p.x / z + Float(intrinsics.cx)
        let v = Float(intrinsics.cy) - Float(intrinsics.fy) * p.y / z
        let w = intrinsics.width, h = intrinsics.height
        guard u.isFinite, v.isFinite, u >= 0, v >= 0, u < Float(w - 1), v < Float(h - 1) else { return nil }
        let x = Int(u), y = Int(v), i = y * w + x
        let d0 = depth[i], d1 = depth[i + 1], d2 = depth[i + w], d3 = depth[i + w + 1]
        for corner in 0..<4 {
            let index = i + (corner & 1) + (corner >> 1) * w
            let d = depth[index]
            guard d.isFinite, d > config.pointMinDepthM, d < config.pointMaxDepthM,
                  abs(d - d0) <= d0 * config.depthEdgeRejectRatio,
                  confidence == nil || confidence![index] >= config.minDepthConfidence else { return nil }
        }
        let a = u - Float(x), b = v - Float(y)
        let measured = (d0 * (1 - a) + d1 * a) * (1 - b) + (d2 * (1 - a) + d3 * a) * b
        let tolerance = config.depthAgreementAbsoluteM + config.depthAgreementRelative * measured
        return Sample(projectedDepth: z, measuredDepth: measured, tolerance: tolerance)
    }

    func agreement(_ point: SIMD3<Float>, config: CaptureConfig) -> Agreement {
        guard let s = sample(point, config: config) else { return .unobserved }
        if abs(s.projectedDepth - s.measuredDepth) <= s.tolerance { return .supported }
        // Foreground occlusion cannot invalidate a background surface.
        return s.projectedDepth > s.measuredDepth ? .occluded : .contradicted
    }

    /// Correct along the source ray only, preserving its RGB pixel and depth discontinuities.
    /// Estimates beyond the agreement band are never averaged into the surface.
    static func consensus(_ points: [CloudPoint], camera: SIMD3<Float>, against views: [Self],
                          config: CaptureConfig) -> [CloudPoint] {
        let required = min(2, views.count)
        guard required > 0 else { return [] }
        // Reuse one tiny scratch buffer per frame, not a heap allocation per depth pixel.
        var corrections = [Float](repeating: 0, count: views.count + 1)
        return points.compactMap { point in
            let origin = SIMD3(point.x, point.y, point.z)
            let distance = simd_distance(origin, camera)
            guard distance.isFinite, distance > 0 else { return nil }
            let ray = (origin - camera) / distance
            corrections[0] = 0 // include the source measurement as one vote
            var correctionCount = 1
            var supports = 0, contradictions = 0
            for view in views {
                guard let s = view.sample(origin, config: config) else { continue }
                let residual = s.measuredDepth - s.projectedDepth
                if abs(residual) <= s.tolerance {
                    supports += 1
                    let derivative = -(view.worldToCamera * SIMD4(ray, 0)).z
                    if derivative > 0.5 {
                        let delta = residual / derivative
                        if abs(delta) <= config.depthConsensusMaxShiftM {
                            // Insertion sort over at most five votes in production.
                            var j = correctionCount
                            while j > 0 && corrections[j - 1] > delta {
                                corrections[j] = corrections[j - 1]; j -= 1
                            }
                            corrections[j] = delta; correctionCount += 1
                        }
                    }
                } else if residual > 0 { contradictions += 1 }
            }
            guard supports >= required, supports > contradictions else { return nil }
            guard correctionCount >= 3 else { return point }
            let mid = correctionCount / 2
            let median = correctionCount % 2 == 0
                ? (corrections[mid-1] + corrections[mid]) * 0.5 : corrections[mid]
            guard abs(median) > 1e-6 else { return point }
            let adjusted = origin + ray * median
            // A correction may move the projection across a foreground boundary. Recheck it.
            var afterSupports = 0, afterContradictions = 0
            for view in views {
                switch view.agreement(adjusted, config: config) {
                case .supported: afterSupports += 1
                case .contradicted: afterContradictions += 1
                case .occluded, .unobserved: break
                }
            }
            guard afterSupports >= supports, afterContradictions <= contradictions else { return point }
            var result = point
            result.x = adjusted.x; result.y = adjusted.y; result.z = adjusted.z
            return result
        }
    }

    static func filter(_ points: [CloudPoint], against views: [Self], config: CaptureConfig,
                       minimumSupports: Int = 1) -> [CloudPoint] {
        points.filter { point in
            var supports = 0, contradictions = 0
            for view in views {
                switch view.agreement(SIMD3(point.x, point.y, point.z), config: config) {
                case .supported: supports += 1
                case .contradicted: contradictions += 1
                case .occluded, .unobserved: break
                }
            }
            return supports >= minimumSupports && supports > contradictions
        }
    }
}

/// First frame establishes a reference; new geometry needs a second compatible observation.
/// A tracking epoch or long gap invalidates the reference rather than comparing different maps.
nonisolated struct TemporalDepthConsistency {
    private var previous: DepthConsistencyView?
    private var lastTime: Double = -.infinity
    private var epoch = -1

    mutating func filter(_ points: [CloudPoint], view: DepthConsistencyView,
                         timestamp: Double, epoch: Int, config: CaptureConfig) -> [CloudPoint] {
        defer { previous = view; lastTime = timestamp; self.epoch = epoch }
        guard timestamp.isFinite, self.epoch == epoch,
              timestamp > lastTime, timestamp - lastTime <= 0.5, let previous else { return [] }
        return DepthConsistencyView.filter(points, against: [previous], config: config)
    }
}

/// Metadata-only lookup: at most four depth maps are loaded, irrespective of scan length.
nonisolated struct DepthReferenceSelection {
    private struct Pose {
        let center: SIMD3<Float>
        let forward: SIMD3<Float>
        let time: Double
        let valid: Bool
    }
    private let poses: [Pose]
    init(records: [FrameRecord]) {
        poses = records.map { r in
            guard r.transform.count == 16, r.transform.allSatisfy(\.isFinite) else {
                return Pose(center: .zero, forward: .zero, time: r.timestamp, valid: false)
            }
            let m = r.transform
            return Pose(center: SIMD3(Float(m[3]), Float(m[7]), Float(m[11])),
                        forward: SIMD3(-Float(m[2]), -Float(m[6]), -Float(m[10])), time: r.timestamp,
                        valid: r.blurVerdict != .drop && r.depthFile != nil)
        }
    }
    func indices(for index: Int) -> [Int] {
        guard poses.indices.contains(index), poses[index].valid else { return [] }
        let current = poses[index]
        let ranked = poses.indices.filter { i in
            guard i != index, poses[i].valid, abs(poses[i].time-current.time) >= 0.25 else { return false }
            let d = simd_distance(poses[i].center, current.center)
            return d >= 0.06 && d <= 0.4 && simd_dot(poses[i].forward, current.forward) >= 0.85
        }.sorted { a,b in
            let da = abs(simd_distance(poses[a].center, current.center)-0.15)
            let db = abs(simd_distance(poses[b].center, current.center)-0.15)
            return da == db ? a < b : da < db
        }
        var selected: [Int] = []
        for i in ranked {
            if selected.allSatisfy({ simd_distance(poses[$0].center, poses[i].center) >= 0.06 }) {
                selected.append(i)
                if selected.count == 4 { return selected }
            }
        }
        // Static or short scans still benefit from temporal support; don't invent parallax.
        for offset in [1,-1,2,-2,3,-3,4,-4] {
            let i = index + offset
            guard poses.indices.contains(i), poses[i].valid, !selected.contains(i),
                  abs(poses[i].time-current.time) >= 0.05 else { continue }
            selected.append(i)
            if selected.count == 4 { break }
        }
        return selected
    }
}
