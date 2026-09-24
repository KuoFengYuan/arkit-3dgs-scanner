import Foundation
import simd

/// 即時與離線融合共用的深度幾何檢核。以相機空間的法向與實際視線計算入射角。
nonisolated enum DepthSampleFilter {
    static func incidenceWeight(depth: UnsafeBufferPointer<Float>, confidence: [UInt8]?,
                                u: Int, v: Int, width: Int, height: Int,
                                K: CameraIntrinsics, config: CaptureConfig) -> Float? {
        incidenceSample(depth:depth,confidence:confidence,u:u,v:v,width:width,height:height,K:K,config:config)?.weight
    }
    static func incidenceSample(depth: UnsafeBufferPointer<Float>, confidence: [UInt8]?,
                                u: Int, v: Int, width: Int, height: Int,
                                K: CameraIntrinsics, config: CaptureConfig) -> (weight: Float, normal: SIMD3<Float>)? {
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
        return (cosine * cosine, normal)
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
    private struct SamplingLimits: Equatable, Sendable {
        let near: Float, far: Float, edge: Float
        let confidence: UInt8
        init(_ c: CaptureConfig) { near=c.pointMinDepthM; far=c.pointMaxDepthM; edge=c.depthEdgeRejectRatio; confidence=c.minDepthConfidence }
    }
    private var preparedLimits: SamplingLimits?
    private var validQuads: [UInt64] = []
    var samplingMaskBytes: Int { validQuads.count * 8 }
    /// One bit per bilinear quad. Same predicates and floating-point order as the reference path.
    mutating func prepareSampling(config: CaptureConfig, maximumQuadSpreadM: Float = .infinity) {
        let w = intrinsics.width, h = intrinsics.height
        validQuads = [UInt64](repeating:0,count:(w*h+63)/64)
        for y in 0..<(h-1) { for x in 0..<(w-1) {
            let i = y*w+x
            if validQuad(i,config:config) {
                if maximumQuadSpreadM.isFinite {
                    let low = min(depth[i],depth[i+1],depth[i+w],depth[i+w+1])
                    let high = max(depth[i],depth[i+1],depth[i+w],depth[i+w+1])
                    if high-low > maximumQuadSpreadM { continue }
                }
                validQuads[i >> 6] |= UInt64(1) << (i & 63)
            }
        } }
        preparedLimits = SamplingLimits(config)
    }
    private func validQuad(_ i: Int, config: CaptureConfig) -> Bool {
        let w = intrinsics.width, d0 = depth[i]
        for corner in 0..<4 {
            let index = i + (corner & 1) + (corner >> 1) * w, d = depth[index]
            guard d.isFinite, d > config.pointMinDepthM, d < config.pointMaxDepthM,
                  abs(d-d0) <= d0*config.depthEdgeRejectRatio,
                  confidence == nil || confidence![index] >= config.minDepthConfidence else { return false }
        }
        return true
    }

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
        if preparedLimits == SamplingLimits(config) {
            guard validQuads[i >> 6] & (UInt64(1) << (i & 63)) != 0 else { return nil }
        } else if !validQuad(i,config:config) { return nil }
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

/// Route-wide check after surface extraction. Near-neighbor fusion can agree with itself
/// while retaining a second shell from a different part of the route. Only strong measured
/// free-space contradictions may remove a point; occlusion is never negative evidence.
nonisolated enum SurfaceVisibilityValidator {
    struct Report: Codable, Sendable {
        var status = "pending"
        var inputPoints = 0
        var referenceFrames = 0
        var candidateRemovals = 0
        var removedPoints = 0
        var protectedPoints = 0
        var locallyProtectedPoints: Int?
        var coverageWorkspaceBytesEstimate: Int?
        var peakDepthFrames = 0
        var counterBytes = 0
        var seconds = 0.0
    }
    static let maximumReferences = 64
    static let minimumBaseline: Float = 0.08

    static func referenceIndices(_ records: [FrameRecord]) -> [Int] {
        var selected: [Int] = [], centers: [SIMD3<Float>] = []
        // Metadata only, globally separated camera centers. Repeated visits or stationary
        // bursts cannot acquire extra votes simply by saving more frames.
        for i in records.indices {
            let r = records[i]
            guard r.blurVerdict != .drop, r.depthFile != nil, r.confidenceFile != nil,
                  r.timestamp.isFinite, r.transform.count == 16, r.transform.allSatisfy(\.isFinite),
                  let w = r.depthWidth, let h = r.depthHeight, w > 1, h > 1, w <= 1024, h <= 1024 else { continue }
            let p = SIMD3(Float(r.transform[3]),Float(r.transform[7]),Float(r.transform[11]))
            guard selected.last.map({ r.timestamp-records[$0].timestamp >= 0.25 }) ?? true,
                  centers.allSatisfy({ simd_distance($0,p) >= minimumBaseline }) else { continue }
            selected.append(i); centers.append(p)
        }
        guard selected.count > maximumReferences else { return selected }
        return (0..<maximumReferences).map { selected[$0*(selected.count-1)/(maximumReferences-1)] }
    }

    /// `load` is injected for tests. One owned map and two UInt8 counters per output point.
    /// Experimental coverage adds one counter and compact indices; surviving XYZ/RGB stay intact.
    static func validate(_ points: inout [CloudPoint], references: [Int], config: CaptureConfig,
                         load: (Int) -> DepthConsistencyView?, shouldContinue: () -> Bool = { true },
                         progress: (Double) -> Void = { _ in }) -> Report {
        let start = Date()
        var report = Report(inputPoints:points.count)
        func finish(_ status: String) -> Report {
            report.status = status; report.seconds = Date().timeIntervalSince(start); return report
        }
        let references = Array(references.prefix(maximumReferences))
        guard references.count >= 3, !points.isEmpty else { return finish("insufficientReferences") }
        guard shouldContinue() else { return finish("interrupted") }
        var supports = [UInt8](repeating:0,count:points.count)
        var contradictions = supports
        var preciseSupports = config.surfaceCoverageProtection ? supports : []
        report.counterBytes = points.count*(config.surfaceCoverageProtection ? 3 : 2)
        var strict = config
        strict.minDepthConfidence = 2
        strict.pointMaxDepthM = min(3, config.pointMaxDepthM)
        for (ordinal,index) in references.enumerated() {
            guard shouldContinue() else { return finish("interrupted") }
            var interrupted = false
            autoreleasepool {
                guard var view = load(index), view.confidence != nil else { return }
                view.prepareSampling(config:strict,maximumQuadSpreadM:0.03)
                report.referenceFrames += 1; report.peakDepthFrames = 1
                for i in points.indices {
                    if i % 4096 == 0, !shouldContinue() { interrupted = true; return }
                    let p = points[i]
                    guard let sample = view.sample(SIMD3(p.x,p.y,p.z),config:strict) else { continue }
                    let residual = sample.measuredDepth-sample.projectedDepth
                    if abs(residual) <= sample.tolerance {
                        supports[i] += 1
                        if config.surfaceCoverageProtection, abs(residual) <= min(0.01,sample.tolerance) { preciseSupports[i] += 1 }
                    }
                    // Two agreement bands protect quantization/noise close to the real wall.
                    else if residual > 2*sample.tolerance { contradictions[i] += 1 }
                }
            }
            guard !interrupted, shouldContinue() else { return finish("interrupted") }
            progress(Double(ordinal+1)/Double(references.count))
        }
        guard report.referenceFrames >= 3 else { return finish("insufficientReferences") }
        for i in points.indices {
            if supports[i] >= 2 { report.protectedPoints += 1 }
            else if contradictions[i] >= 3 { report.candidateRemovals += 1 }
        }
        // Widespread conflict can indicate bad poses or transparent/reflective surfaces.
        // Keep the complete input instead of presenting a heavily erased model as repaired.
        guard report.candidateRemovals <= points.count/10 else { return finish("excessiveConflictFallback") }
        guard shouldContinue() else { return finish("interrupted") }
        if config.surfaceCoverageProtection {
            // A global percentage cannot protect a small local wall or thin structure. Only
            // reconsider clusters that would empty over 60% of the local occupied subcells.
            // Small contradicted shells still follow the depth evidence, rather than restoring
            // every rejected point simply because a sparse export cannot fit its neighborhood.
            guard let retained = SurfaceCoverageIndex(points:points,include:{ supports[$0] >= 2 || contradictions[$0] < 3 },shouldContinue:shouldContinue),
                  let candidates = SurfaceCoverageIndex(points:points,include:{ supports[$0] < 2 && contradictions[$0] >= 3 },shouldContinue:shouldContinue) else {
                return finish("interrupted")
            }
            report.coverageWorkspaceBytesEstimate = retained.workspaceBytesEstimate+candidates.workspaceBytesEstimate
            report.locallyProtectedPoints = 0
            var visited = 0
            for i in points.indices where supports[i] < 2 && contradictions[i] >= 3 {
                if visited % 256 == 0, !shouldContinue() { return finish("interrupted") }
                visited += 1
                let p = SurfaceCoverageIndex.position(points[i])
                let patch = candidates.patch(p,points:points,allowRough:true)
                let normal = PackedSurfaceNormal.decode(points[i].packedNormal) ?? patch?.normal
                let isThin = candidates.isThinStructure(p,points:points)
                let largeLocalLoss = candidates.lostCoverageFraction(around:p,retained:retained) > 0.60
                if isThin || (largeLocalLoss && !retained.covers(p,normal:normal,radius:0.15,points:points)) {
                    contradictions[i] = 0
                    // Votes use at most 64; the high bit carries the local safeguard
                    // through compaction without allocating another per-point array.
                    preciseSupports[i] |= 128
                    report.locallyProtectedPoints! += 1
                }
            }
        }
        guard shouldContinue() else { return finish("interrupted") }
        // Compact only after the complete decision succeeds. This avoids a second point array.
        var written = 0
        for i in points.indices where supports[i] >= 2 || contradictions[i] < 3 {
            if written != i { points[written] = points[i] }
            if config.surfaceCoverageProtection {
                if preciseSupports[i] & 127 >= 2 { points[written].fusionSource |= 4 }
                if preciseSupports[i] & 128 != 0 { points[written].fusionSource |= 8 }
            }
            written += 1
        }
        report.removedPoints = points.count-written
        points.removeLast(report.removedPoints)
        return finish("completed")
    }
}

/// Compact linked spatial index over the bounded export, never over all source depth frames.
/// The index borrows point coordinates at query time, so in-place compaction cannot cause a
/// second full cloud allocation. Neighborhoods keep at most 24 samples in deterministic order.
nonisolated struct SurfaceCoverageIndex {
    private struct Bucket { var first: Int32 = -1; var occupancy: UInt32 = 0 }
    private var heads: [Int64: Bucket] = [:]
    private var next: [Int32]
    private let cell: Float = 0.10
    var indexedPoints = 0
    var workspaceBytesEstimate: Int { next.count * 4 + heads.count * 48 }

    init?(points: [CloudPoint], include: (Int) -> Bool, shouldContinue: () -> Bool = { true }) {
        guard points.count < Int(Int32.max) else { return nil }
        next = [Int32](repeating:-1,count:points.count)
        for i in points.indices {
            if i % 4096 == 0, !shouldContinue() { return nil }
            guard include(i), let key = PointCloudMath.voxelKey(Self.position(points[i]),size:cell) else { continue }
            var bucket = heads[key] ?? Bucket()
            next[i] = bucket.first; bucket.first = Int32(i)
            let local = (Self.position(points[i])/cell-floor(Self.position(points[i])/cell))*3
            let x = min(2,max(0,Int(local.x))), y = min(2,max(0,Int(local.y))), z = min(2,max(0,Int(local.z)))
            bucket.occupancy |= 1 << (x+3*y+9*z)
            heads[key] = bucket; indexedPoints += 1
        }
    }
    static func position(_ p: CloudPoint) -> SIMD3<Float> { SIMD3(p.x,p.y,p.z) }

    func samples(_ p: SIMD3<Float>, radius: Float, points: [CloudPoint]) -> [(position: SIMD3<Float>,normal:UInt16)] {
        guard p.x.isFinite,p.y.isFinite,p.z.isFinite,radius.isFinite,radius > 0 else { return [] }
        let lo = floor((p-radius)/cell), hi = floor((p+radius)/cell)
        guard abs(lo.x) < 1_000_000,abs(lo.y) < 1_000_000,abs(lo.z) < 1_000_000 else { return [] }
        var nearest: [(distance:Float,position:SIMD3<Float>,key:Int64,normal:UInt16)] = []
        nearest.reserveCapacity(24)
        for x in Int(lo.x)...Int(hi.x) { for y in Int(lo.y)...Int(hi.y) { for z in Int(lo.z)...Int(hi.z) {
            guard let key = PointCloudMath.voxelKey((SIMD3(Float(x),Float(y),Float(z))+0.5)*cell,size:cell) else { continue }
            var i = heads[key]?.first ?? -1
            while i >= 0 {
                let point = points[Int(i)]
                let q = Self.position(point), d = simd_length_squared(q-p)
                i = next[Int(i)]
                guard d <= radius*radius,
                      let sampleKey = PointCloudMath.voxelKey(q,size:0.02) else { continue }
                // TSDF edges can emit several almost coincident samples. Count spatial
                // coverage, not repeated crossings concentrated in one tiny footprint.
                if let old = nearest.firstIndex(where:{ $0.key == sampleKey }) {
                    let previous = nearest[old]
                    guard d < previous.distance || (d == previous.distance &&
                        (q.x,q.y,q.z) < (previous.position.x,previous.position.y,previous.position.z)) else { continue }
                    nearest.remove(at:old)
                }
                let at = nearest.firstIndex { d < $0.distance || (d == $0.distance &&
                    (q.x,q.y,q.z) < ($0.position.x,$0.position.y,$0.position.z)) } ?? nearest.count
                if at < 24 {
                    nearest.insert((d,q,sampleKey,point.packedNormal),at:at)
                    if nearest.count > 24 { nearest.removeLast() }
                }
            }
        } } }
        return nearest.map { ($0.position,$0.normal) }
    }
    func neighbors(_ p: SIMD3<Float>,radius: Float,points: [CloudPoint]) -> [SIMD3<Float>] {
        samples(p,radius:radius,points:points).map(\.position)
    }

    /// Occupancy, not point density: repeated TSDF crossings cannot hide a locally erased
    /// region. Shared occupied subcells survive regardless of how many points were removed.
    func lostCoverageFraction(around p: SIMD3<Float>,retained: Self) -> Float {
        let base = floor(p/cell)
        var original = 0, lost = 0
        for x in -2...2 { for y in -2...2 { for z in -2...2 {
            guard let key = PointCloudMath.voxelKey((base+SIMD3(Float(x),Float(y),Float(z))+0.5)*cell,size:cell) else { continue }
            let candidate = heads[key]?.occupancy ?? 0, kept = retained.heads[key]?.occupancy ?? 0
            original += (candidate | kept).nonzeroBitCount
            lost += (candidate & ~kept).nonzeroBitCount
        } } }
        return original > 0 ? Float(lost)/Float(original) : 1
    }

    struct Patch {
        let center: SIMD3<Float>
        let normal: SIMD3<Float>
        let tangent: SIMD3<Float>
        let samples: [SIMD3<Float>]
    }
    /// PCA rejects lines, corners and thick/mixed neighborhoods instead of inventing a plane.
    func patch(_ p: SIMD3<Float>, points: [CloudPoint], allowRough: Bool = false) -> Patch? {
        let neighborhood = self.samples(p,radius:allowRough ? 0.12 : 0.085,points:points)
        func sourcePatch() -> Patch? {
            if let first = neighborhood.first,let normal = PackedSurfaceNormal.decode(first.normal) {
                let aligned = neighborhood.filter { sample in
                    guard let n = PackedSurfaceNormal.decode(sample.normal) else { return false }
                    return abs(simd_dot(normal,n)) >= 0.94 && abs(simd_dot(sample.position-first.position,normal)) <= 0.02
                }.map(\.position)
                if aligned.count >= 4 {
                    let center = aligned.reduce(SIMD3<Float>.zero,+)/Float(aligned.count)
                    let axis = abs(normal.x) < 0.8 ? SIMD3<Float>(1,0,0) : SIMD3<Float>(0,1,0)
                    return Patch(center:center,normal:normal,tangent:simd_normalize(simd_cross(normal,axis)),samples:aligned)
                }
            }
            return nil
        }
        let samples = neighborhood.map(\.position)
        guard samples.count >= 6 else { return sourcePatch() }
        let center = samples.reduce(SIMD3<Float>.zero,+)/Float(samples.count)
        var covariance = simd_float3x3()
        for q in samples {
            let d = q-center
            covariance += simd_float3x3(d*d.x,d*d.y,d*d.z)
        }
        covariance *= 1/Float(samples.count)
        var vectors = matrix_identity_float3x3
        for _ in 0..<12 {
            var a = 0, b = 1
            if abs(covariance[0][2]) > abs(covariance[a][b]) { a = 0; b = 2 }
            if abs(covariance[1][2]) > abs(covariance[a][b]) { a = 1; b = 2 }
            if abs(covariance[a][b]) < 1e-10 { break }
            let angle = 0.5*atan2(2*covariance[a][b],covariance[b][b]-covariance[a][a])
            let c = cos(angle), s = sin(angle)
            var rotation = matrix_identity_float3x3
            rotation[a][a] = c; rotation[b][b] = c
            rotation[a][b] = -s; rotation[b][a] = s
            covariance = rotation.transpose*covariance*rotation
            vectors = vectors*rotation
        }
        let order = (0..<3).sorted { covariance[$0][$0] < covariance[$1][$1] }
        let minimum = max(0,covariance[order[0]][order[0]]), middle = covariance[order[1]][order[1]]
        guard middle >= 0.000035,minimum <= min(allowRough ? 0.0004 : 0.000144,middle*(allowRough ? 0.35 : 0.15)) else { return sourcePatch() }
        return Patch(center:center,normal:simd_normalize(vectors[order[0]]),
                     tangent:simd_normalize(vectors[order[2]]),samples:samples)
    }

    func isThinStructure(_ p: SIMD3<Float>, points: [CloudPoint]) -> Bool {
        let samples = neighbors(p,radius:0.085,points:points)
        guard samples.count >= 4 else { return false }
        var a = samples[0], b = a, span: Float = 0
        for i in samples.indices { for j in samples.indices where j > i {
            let length = simd_length_squared(samples[i]-samples[j])
            if length > span { span = length; a = samples[i]; b = samples[j] }
        } }
        guard span > 0.04*0.04 else { return false }
        let direction = simd_normalize(b-a)
        return samples.allSatisfy { simd_length_squared(simd_cross($0-a,direction)) < 0.01*0.01 }
    }

    /// A nearby plane is insufficient: the candidate's projection must have close samples
    /// on all four tangent quadrants. This protects boundaries, holes and perpendicular walls.
    func covers(_ p: SIMD3<Float>, normal: SIMD3<Float>?, radius: Float, points: [CloudPoint]) -> Bool {
        guard let nearest = neighbors(p,radius:radius,points:points).first,
              let patch = patch(nearest,points:points) else { return false }
        if let normal, abs(simd_dot(normal,patch.normal)) < 0.94 { return false }
        let offset = simd_dot(p-patch.center,patch.normal)
        guard abs(offset) <= radius else { return false }
        let projected = p-patch.normal*offset
        let u = patch.tangent, v = simd_cross(patch.normal,u)
        var quadrants: UInt8 = 0, closest = Float.infinity
        for sample in patch.samples {
            let d = sample-projected, x = simd_dot(d,u), y = simd_dot(d,v)
            let distance = x*x+y*y
            closest = min(closest,distance)
            guard distance <= 0.065*0.065,abs(x) >= 0.003,abs(y) >= 0.003 else { continue }
            quadrants |= 1 << ((x > 0 ? 1 : 0)+(y > 0 ? 2 : 0))
        }
        return quadrants == 15 && closest <= 0.035*0.035
    }
}

nonisolated enum SurfaceCoverageFilter {
    struct Report: Codable, Sendable {
        var candidatePoints = 0
        var budgetRemovedPoints = 0
        var removedPoints = 0
        var protectedPoints = 0
        var supportedPoints = 0
        var workspaceBytesEstimate = 0
        var seconds = 0.0
    }
    /// Uniform deterministic thinning of far fill only. The near output was bounded before
    /// visibility/coverage; preserving it here keeps all replacement evidence valid.
    static func capFarPreservingNear(_ points: inout [CloudPoint], limit: Int) -> Int {
        guard points.count > limit else { return 0 }
        let far = points.reduce(0) { $0 + (($1.fusionSource & 3) == 2 ? 1 : 0) }
        let near = points.count-far, keep = max(0,limit-near)
        precondition(near <= limit,"Near output must be bounded before far coverage")
        var ordinal = 0, written = 0
        for i in points.indices {
            if (points[i].fusionSource & 3) == 2 {
                let selected = (ordinal+1)*keep/far > ordinal*keep/far
                ordinal += 1
                if !selected { continue }
            }
            if written != i { points[written] = points[i] }; written += 1
        }
        let removed = points.count-written
        points.removeLast(removed)
        return removed
    }

    /// No synthesized geometry, snapping or smoothing. All surviving XYZ/RGB values are exact.
    /// nil signals cancellation/pressure and leaves the complete input unchanged.
    static func filterFar(_ points: inout [CloudPoint], radius: Float,
                          shouldContinue: () -> Bool = { true }) -> Report? {
        let start = Date()
        var report = Report()
        guard shouldContinue() else { return nil }
        report.candidatePoints = points.reduce(0) { $0 + (($1.fusionSource & 3) == 2 ? 1 : 0) }
        guard radius.isFinite,radius > 0,report.candidatePoints > 0 else { return report }
        // A malformed configuration must never create unbounded spatial queries.
        let radius = min(0.15,radius)
        guard let near = SurfaceCoverageIndex(points:points,include:{ (points[$0].fusionSource & 3) == 1 },shouldContinue:shouldContinue),
              let far = SurfaceCoverageIndex(points:points,include:{ (points[$0].fusionSource & 3) == 2 },shouldContinue:shouldContinue) else { return nil }
        var remove = [UInt8](repeating:0,count:points.count)
        report.workspaceBytesEstimate = near.workspaceBytesEstimate+far.workspaceBytesEstimate+remove.count
        var visited = 0
        for i in points.indices where (points[i].fusionSource & 3) == 2 {
            if visited % 256 == 0, !shouldContinue() { return nil }
            visited += 1
            if points[i].fusionSource & 4 != 0 { report.supportedPoints += 1; continue }
            if points[i].fusionSource & 8 != 0 { report.protectedPoints += 1; continue }
            let p = SurfaceCoverageIndex.position(points[i])
            let normal = far.patch(p,points:points)?.normal ?? PackedSurfaceNormal.decode(points[i].packedNormal)
            guard let normal, near.covers(p,normal:normal,radius:radius,points:points) else {
                report.protectedPoints += 1; continue
            }
            remove[i] = 1; report.removedPoints += 1
        }
        guard shouldContinue() else { return nil }
        var written = 0
        for i in points.indices where remove[i] == 0 {
            if written != i { points[written] = points[i] }
            written += 1
        }
        points.removeLast(points.count-written)
        report.seconds = Date().timeIntervalSince(start)
        return report
    }
}
