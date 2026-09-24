import Foundation
import simd

/// Conservative, bounded revisit alignment. All corrections are rigid; scale is never optimized.
nonisolated enum LoopClosureRefiner {
    struct Report: Codable, Sendable {
        var status = "noCandidates"
        var candidatePairs = 0
        var verifiedPairs = 0
        var peakDescriptorFrames = 0
        var maximumPairMatches = 0
        var heldOutBeforePx: Float?
        var heldOutAfterPx: Float?
        var heldOutBeforeM: Float?
        var heldOutAfterM: Float?
        var maximumCorrectionM: Float = 0
        var seconds: Double = 0
        /// "guided" (pose-predicted, plane-warped search) or "descriptor" (independent detections).
        var matching: String?
        /// Matches found for each evaluated candidate pair, in candidate order.
        var pairMatchCounts: [Int]?
    }
    struct Match: Sendable { let a: SIMD3<Float>; let b: SIMD3<Float> }
    struct Edge: Sendable {
        let a: Int; let b: Int
        /// Maps the original world observations at b onto those at a.
        let alignment: simd_float4x4
        let heldOut: [Match]
    }
    struct Result: Sendable { let records: [FrameRecord]; let report: Report }
    static func center(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }
    static func point(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = m * SIMD4(p, 1); return SIMD3(q.x, q.y, q.z)
    }
    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .infinity }
        return values.sorted()[values.count / 2]
    }

    /// At most 64 pairs from at most 512 distributed query frames; original array indices survive.
    static func candidates(_ records: [FrameRecord], maxDistanceM: Float = 0.8, minFacing: Float = 0.9) -> [(Int, Int)] {
        guard records.count >= 40 else { return [] }
        let poses = records.map { RefusionEngine.float4x4(rowMajor: $0.transform) }
        var travel = [Float](repeating: 0, count: records.count)
        for i in 1..<records.count { travel[i] = travel[i-1] + simd_distance(center(poses[i]), center(poses[i-1])) }
        let strideSize = max(1, Int(ceil(Double(records.count) / 512)))
        let keys = Array(stride(from: 0, to: records.count, by: strideSize))
        var pairs: [(Int, Int, Float)] = []
        for b in keys {
            var best: (Int, Float)?
            for a in keys where a + 30 < b && records[b].timestamp - records[a].timestamp >= 8 && travel[b] - travel[a] >= 2 {
                let distance = simd_distance(center(poses[a]), center(poses[b]))
                let facing = simd_dot(poses[a].columns.2, poses[b].columns.2)
                guard distance < maxDistanceM, facing > minFacing else { continue }
                if best == nil || distance < best!.1 { best = (a, distance) }
            }
            if let best { pairs.append((best.0, b, best.1)) }
        }
        pairs.sort { $0.2 == $1.2 ? $0.1 < $1.1 : $0.2 < $1.2 }
        var chosen: [(Int, Int)] = []
        for pair in pairs {
            guard chosen.allSatisfy({ abs($0.1 - pair.1) >= max(8, strideSize) }) else { continue }
            chosen.append((pair.0, pair.1))
            if chosen.count == 64 { break }
        }
        return chosen.sorted { $0.1 < $1.1 }
    }

    /// Reciprocal appearance matching in a bounded 3D neighborhood, independent of voxel occupancy.
    static func matches(_ a: [TrackedFeature], _ b: [TrackedFeature]) -> [Match] {
        func grid(_ features: [TrackedFeature]) -> [SIMD3<Int32>: [Int]] {
            var out: [SIMD3<Int32>: [Int]] = [:]
            for (i, f) in features.enumerated() { out[key(f.world), default: []].append(i) }
            return out
        }
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3(Int32(floor(p.x / 0.15)), Int32(floor(p.y / 0.15)), Int32(floor(p.z / 0.15)))
        }
        func best(_ f: TrackedFeature, _ other: [TrackedFeature], _ lookup: [SIMD3<Int32>: [Int]]) -> Int? {
            let cell = key(f.world)
            var bestIndex = -1; var first: Float = -1; var second: Float = -1
            for z in -2...2 { for y in -2...2 { for x in -2...2 {
                for i in lookup[cell &+ SIMD3(Int32(x), Int32(y), Int32(z))] ?? [] {
                    guard simd_distance(f.world, other[i].world) <= 0.30 else { continue }
                    let score = FeatureExtractor.zncc(f, other[i])
                    if score > first { second = first; first = score; bestIndex = i }
                    else if score > second { second = score }
                }
            } } }
            guard bestIndex >= 0, first >= 0.8, second <= 0 || second / first < 0.9 else { return nil }
            return bestIndex
        }
        guard (a + b).allSatisfy({ f in
            f.world.x.isFinite && f.world.y.isFinite && f.world.z.isFinite
                && abs(f.world.x) < 1_000_000 && abs(f.world.y) < 1_000_000 && abs(f.world.z) < 1_000_000
        }) else { return [] }
        let ga = grid(a), gb = grid(b)
        var out: [Match] = []
        for (i, f) in a.enumerated() {
            guard let j = best(f, b, gb), best(b[j], a, ga) == i else { continue }
            out.append(Match(a: f.world, b: b[j].world))
            if out.count == 256 { break }
        }
        return out
    }

    // MARK: - Pose-guided, plane-warped revisit matching

    /// One decoded revisit frame: 960 px grayscale, its LiDAR depth and the current pose.
    struct GuidedView {
        let gray: ScanImageDecoder.Gray
        /// Intrinsics at `gray` resolution.
        let k: CameraIntrinsics
        let depth: DepthConsistencyView
        let c2w: simd_float4x4
        let w2c: simd_float4x4
        /// Original image size (FrameRecord intrinsics), in which observations are stored.
        let originalWidth: Int
        let originalHeight: Int
    }

    /// A revisit correspondence with the pixel data a bundle adjustment observation needs.
    struct GuidedMatch: Sendable {
        /// The feature in frame a (original pixels, a's LiDAR depth).
        let feature: TrackedFeature
        /// Location in frame b, original pixels, and b's LiDAR depth there.
        let u: Float
        let v: Float
        let depth: Float
        /// World points under the poses used for matching.
        let match: Match
    }

    static let guidedImageDimension = 960
    /// Template: 9×9 samples, 2 px apart at 960 px (the extractor's patch footprint).
    static let guidedTemplateRadius = 4
    static let guidedTemplateStep: Float = 2
    /// Search radius covers this much residual drift at the feature's depth in the revisit view.
    static let guidedDriftM: Float = 0.06
    static let guidedMinRadiusPx: Float = 12
    static let guidedMaxRadiusPx: Float = 40
    static let guidedMinZNCC: Float = 0.8
    static let guidedMaxSecondRatio: Float = 0.9
    static let guidedMaxFeatures = 320

    static func guidedView(_ r: FrameRecord, directory: URL) -> GuidedView? {
        guard r.transform.count == 16, r.transform.allSatisfy(\.isFinite),
              let gray = ScanImageDecoder.gray(r, directory: directory, maxDimension: guidedImageDimension),
              let depth = RefusionEngine.storedDepthView(r, directory: directory.appendingPathComponent("depth")) else { return nil }
        let c2w = RefusionEngine.float4x4(rowMajor: r.transform)
        return GuidedView(gray: gray, k: r.intrinsics.scaled(toWidth: gray.width, height: gray.height),
                          depth: depth, c2w: c2w, w2c: c2w.inverse,
                          originalWidth: r.intrinsics.width, originalHeight: r.intrinsics.height)
    }

    @inline(__always) static func bilinear(_ g: ScanImageDecoder.Gray, _ u: Float, _ v: Float) -> Float? {
        guard u >= 0, v >= 0, u < Float(g.width - 1), v < Float(g.height - 1) else { return nil }
        let x = Int(u), y = Int(v), fx = u - Float(x), fy = v - Float(y), i = y * g.width + x
        let top = Float(g.pixels[i]) * (1 - fx) + Float(g.pixels[i + 1]) * fx
        let bottom = Float(g.pixels[i + g.width]) * (1 - fx) + Float(g.pixels[i + g.width + 1]) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// Camera-space point (ARKit: -Z forward) → gray pixel and positive depth.
    @inline(__always) static func pixel(_ p: SIMD3<Float>, _ k: CameraIntrinsics) -> SIMD3<Float>? {
        let z = -p.z
        guard z > 0.1, z.isFinite else { return nil }
        return SIMD3(Float(k.fx) * p.x / z + Float(k.cx), Float(k.cy) - Float(k.fy) * p.y / z, z)
    }

    @inline(__always) static func ray(_ u: Float, _ v: Float, _ k: CameraIntrinsics) -> SIMD3<Float> {
        SIMD3((u - Float(k.cx)) / Float(k.fx), -(v - Float(k.cy)) / Float(k.fy), -1)
    }

    /// Camera-space LiDAR point under a gray pixel: nearest depth sample with confidence >= 1
    /// whose 3×3 neighbourhood agrees within 3% (no depth edge).
    static func depthPoint(_ view: GuidedView, u: Float, v: Float) -> SIMD3<Float>? {
        let dk = view.depth.intrinsics, dw = dk.width, dh = dk.height
        let du = u * Float(dw) / Float(view.gray.width), dv = v * Float(dh) / Float(view.gray.height)
        let x = Int(du.rounded()), y = Int(dv.rounded())
        guard x >= 1, y >= 1, x < dw - 1, y < dh - 1 else { return nil }
        let d = view.depth.depth[y * dw + x]
        guard d.isFinite, d > 0.15, d < 6, (view.depth.confidence?[y * dw + x] ?? 2) >= 1 else { return nil }
        for oy in -1...1 { for ox in -1...1 {
            let n = view.depth.depth[(y + oy) * dw + x + ox]
            guard n.isFinite, abs(n - d) <= d * 0.03 else { return nil }
        } }
        return SIMD3((du - Float(dk.cx)) / Float(dk.fx) * d, -(dv - Float(dk.cy)) / Float(dk.fy) * d, -d)
    }

    /// Unit normal of the LiDAR surface around a depth pixel, from ±2 px central differences.
    static func depthNormal(_ view: GuidedView, u: Float, v: Float) -> SIMD3<Float>? {
        let sx = Float(view.gray.width) / Float(view.depth.intrinsics.width)
        let sy = Float(view.gray.height) / Float(view.depth.intrinsics.height)
        guard let l = depthPoint(view, u: u - 2 * sx, v: v), let r = depthPoint(view, u: u + 2 * sx, v: v),
              let t = depthPoint(view, u: u, v: v - 2 * sy), let b = depthPoint(view, u: u, v: v + 2 * sy) else { return nil }
        let n = simd_cross(r - l, b - t), length = simd_length(n)
        guard length > 1e-9, length.isFinite else { return nil }
        return n / length
    }

    /// Matches features of revisit frame `a` into frame `b`. Each feature is projected with the
    /// current poses, its 9×9 patch is warped into `b` through the local LiDAR plane, and a dense
    /// ZNCC search runs around the prediction. The matched pixel's own LiDAR depth gives the 3D
    /// observation in `b`, so the pose guidance only limits the search: the alignment itself
    /// comes from the two depth measurements, verified later by RANSAC and held-out points.
    static func guidedMatches(_ features: [TrackedFeature], from a: GuidedView, to b: GuidedView) -> [GuidedMatch] {
        let scaleU = Float(a.gray.width) / Float(max(1, a.originalWidth))
        let scaleV = Float(a.gray.height) / Float(max(1, a.originalHeight))
        let radius = guidedTemplateRadius, step = guidedTemplateStep
        let side = 2 * radius + 1, count = side * side
        let marginPx = Float(radius) * step * 3 + guidedMaxRadiusPx
        // Candidate features that land well inside b, evenly thinned to the budget.
        let a2b = b.w2c * a.c2w
        func transfer(_ p: SIMD3<Float>) -> SIMD3<Float>? {
            let q = a2b * SIMD4(p, 1); return pixel(SIMD3(q.x, q.y, q.z), b.k)
        }
        var usable: [TrackedFeature] = []
        for f in features where f.depth.isFinite && f.depth > 0.15 && f.u.isFinite && f.v.isFinite {
            guard let q = transfer(ray(f.u * scaleU, f.v * scaleV, a.k) * f.depth),
                  q.x > marginPx, q.y > marginPx,
                  q.x < Float(b.gray.width) - marginPx, q.y < Float(b.gray.height) - marginPx else { continue }
            usable.append(f)
        }
        let thin = max(1, Int(ceil(Double(usable.count) / Double(guidedMaxFeatures))))
        var template = [Float](repeating: 0, count: count)
        var offsets = [SIMD2<Float>](repeating: .zero, count: count)
        var out: [GuidedMatch] = []
        for (index, f) in usable.enumerated() where index % thin == 0 {
            let ua = f.u * scaleU, va = f.v * scaleV
            // Plane through the feature's LiDAR point with the local depth normal (a's camera frame).
            let pa = ray(ua, va, a.k) * f.depth
            guard let normal = depthNormal(a, u: ua, v: va) else { continue }
            let planeOffset = simd_dot(normal, pa)
            guard let center = transfer(pa) else { continue }
            var valid = true, mean: Float = 0
            for gy in -radius...radius where valid { for gx in -radius...radius {
                let u = ua + Float(gx) * step, v = va + Float(gy) * step
                let direction = ray(u, v, a.k)
                let facing = simd_dot(normal, direction)
                guard abs(facing) >= 0.25 * simd_length(direction), let value = bilinear(a.gray, u, v) else { valid = false; break }
                let t = planeOffset / facing
                guard t > 0.1, t.isFinite else { valid = false; break }
                guard let warped = transfer(direction * t) else { valid = false; break }
                let i = (gy + radius) * side + gx + radius
                template[i] = value; offsets[i] = SIMD2(warped.x - center.x, warped.y - center.y); mean += value
            } }
            guard valid else { continue }
            // Reject extreme foreshortening between the views (warped axes vs the 16 px template span).
            let span = Float(2 * radius) * step
            let horizontal = simd_length(offsets[radius * side + side - 1] - offsets[radius * side]) / span
            let vertical = simd_length(offsets[(side - 1) * side + radius] - offsets[radius]) / span
            guard horizontal > 0.4, horizontal < 2.5, vertical > 0.4, vertical < 2.5 else { continue }
            mean /= Float(count)
            var norm: Float = 0
            for i in 0..<count { template[i] -= mean; norm += template[i] * template[i] }
            guard norm > Float(count) * 16 else { continue }   // untextured patch
            let invTemplate = 1 / norm.squareRoot()
            func score(_ c: SIMD2<Float>) -> Float? {
                var sum: Float = 0, sumSquares: Float = 0, cross: Float = 0
                for i in 0..<count {
                    let p = c + offsets[i]
                    guard let value = bilinear(b.gray, p.x, p.y) else { return nil }
                    sum += value; sumSquares += value * value; cross += template[i] * value
                }
                let variance = sumSquares - sum * sum / Float(count)
                guard variance > 1e-3 else { return nil }
                return cross * invTemplate / variance.squareRoot()
            }
            let searchRadius = min(guidedMaxRadiusPx, max(guidedMinRadiusPx, Float(b.k.fx) * guidedDriftM / center.z + 4))
            let steps = Int((searchRadius / 2).rounded(.down))
            var coarse: [(SIMD2<Float>, Float)] = []
            coarse.reserveCapacity((2 * steps + 1) * (2 * steps + 1))
            for dy in -steps...steps { for dx in -steps...steps where dx * dx + dy * dy <= steps * steps {
                let c = SIMD2(center.x, center.y) + SIMD2(Float(dx), Float(dy)) * 2
                if let s = score(c) { coarse.append((c, s)) }
            } }
            guard let peak = coarse.max(by: { $0.1 < $1.1 }), peak.1 >= guidedMinZNCC - 0.1 else { continue }
            // Refine on a 1 px grid, then a parabolic sub-pixel step on each axis.
            var best = peak
            for dy in -2...2 { for dx in -2...2 {
                let c = peak.0 + SIMD2(Float(dx), Float(dy))
                if let s = score(c), s > best.1 { best = (c, s) }
            } }
            var refined = best.0
            if let l = score(best.0 - SIMD2(1, 0)), let r = score(best.0 + SIMD2(1, 0)) {
                let d = l - 2 * best.1 + r; if d < 0 { refined.x += max(-0.5, min(0.5, 0.5 * (l - r) / d)) }
            }
            if let t = score(best.0 - SIMD2(0, 1)), let d0 = score(best.0 + SIMD2(0, 1)) {
                let d = t - 2 * best.1 + d0; if d < 0 { refined.y += max(-0.5, min(0.5, 0.5 * (t - d0) / d)) }
            }
            // Uniqueness: the best score away from the peak must be clearly lower.
            let second = coarse.lazy.filter { simd_distance($0.0, best.0) > 4 }.map(\.1).max() ?? -1
            guard best.1 >= guidedMinZNCC, second <= 0 || second / best.1 < guidedMaxSecondRatio else { continue }
            // b's own LiDAR point at the match; reject a match far from the predicted depth (occlusion).
            guard let pbCamera = depthPoint(b, u: refined.x, v: refined.y),
                  abs(-pbCamera.z - center.z) <= max(0.15, 0.1 * center.z) else { continue }
            let pbWorld = b.c2w * SIMD4(pbCamera, 1)
            let paWorld = a.c2w * SIMD4(pa, 1)
            out.append(GuidedMatch(feature: f,
                                   u: refined.x * Float(b.originalWidth) / Float(b.gray.width),
                                   v: refined.y * Float(b.originalHeight) / Float(b.gray.height),
                                   depth: -pbCamera.z,
                                   match: Match(a: SIMD3(paWorld.x, paWorld.y, paWorld.z),
                                                b: SIMD3(pbWorld.x, pbWorld.y, pbWorld.z))))
            if out.count == 256 { break }
        }
        return out
    }

    // MARK: - Revisit tracks for the joint bundle adjustment

    /// Revisit selection and outlier rejection for bundle-adjustment tracks. Unlike a rigid
    /// correction, a track needs no improvement to be useful: an already consistent revisit also
    /// constrains drift, so the check only rejects matches inconsistent with one rigid motion.
    struct RevisitOptions: Sendable {
        /// Warped patches tolerate a wider revisit than descriptor matching (0.8 m, 0.9).
        var maxDistanceM: Float = 1.0
        var minFacing: Float = 0.8
        var minMatches = 24
        var minInliers = 16
        var minInlierFraction: Float = 0.6
        var inlierM: Float = 0.025
        /// Use the rigid-correction verification (needs 40 matches and an improvement) instead.
        var requireImprovement = false
    }

    /// Deterministic RANSAC over all matches; returns the rigid transform (b onto a) and inliers,
    /// or nil when too few matches agree or the implied motion exceeds 15 cm / 5°.
    static func rigidInliers(_ matches: [Match], options: RevisitOptions) -> (alignment: simd_float4x4, inliers: [Int])? {
        guard matches.count >= options.minMatches else { return nil }
        var seed: UInt64 = 42
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
        var best: [Int] = []
        for _ in 0..<96 {
            let indices = Set([random(matches.count), random(matches.count), random(matches.count)])
            guard indices.count == 3, let t = align(indices.sorted().map { matches[$0] }) else { continue }
            let inliers = matches.indices.filter { simd_distance(matches[$0].a, point(t, matches[$0].b)) < options.inlierM }
            if inliers.count > best.count { best = inliers }
        }
        guard best.count >= options.minInliers, Float(best.count) >= options.minInlierFraction * Float(matches.count),
              let refit = align(best.map { matches[$0] }) else { return nil }
        let inliers = matches.indices.filter { simd_distance(matches[$0].a, point(refit, matches[$0].b)) < options.inlierM }
        guard inliers.count >= options.minInliers, simd_length(center(refit)) <= 0.15,
              simd_quatf(refit).angle <= 5 * .pi / 180 else { return nil }
        return (refit, inliers)
    }

    struct TrackReport: Codable, Sendable {
        var status = "noCandidates"
        var candidatePairs = 0
        var verifiedPairs = 0
        /// Guided matches per evaluated candidate pair, in candidate order.
        var pairMatchCounts: [Int] = []
        /// Frame IDs (earlier, later) of the verified revisit pairs.
        var verifiedPairFrameIDs: [[Int]] = []
        var observations = 0
        var linkedTracks = 0
        var newTracks = 0
        /// Revisit tracks in the bundle adjustment's held-out set (never optimized).
        var heldOutTracks = 0
        /// Median 3D distance between the two LiDAR observations of held-out revisit tracks.
        var heldOutBeforeM: Float?
        var heldOutAfterM: Float?
        var seconds: Double = 0
    }
    struct RevisitTrack: Sendable { let a: FeatureObservation; let b: FeatureObservation }
    struct TrackResult: Sendable {
        var observations: [FeatureObservation] = []
        /// Held-out revisit tracks, for the before/after distance in the report.
        var heldOut: [RevisitTrack] = []
        var report = TrackReport()
    }

    /// Guided revisit matches become bundle-adjustment observations, so the joint solve
    /// (reprojection, depth and ARKit motion priors) reconciles revisits. A rigid correction from
    /// LiDAR points alone fitted depth disagreements that the photos contradict. Only candidate
    /// pairs whose matches pass the rigid RANSAC and held-out check contribute, and only their
    /// inliers. A match joins frame a's existing track when that observation was kept.
    static func bundleObservations(records usable: [FrameRecord], directory: URL, existing: [FeatureObservation],
                                   options: RevisitOptions = RevisitOptions(),
                                   isCancelled: () -> Bool = { false },
                                   progress: (Double) -> Void = { _ in }) -> TrackResult {
        let start = Date()
        var result = TrackResult()
        func finish(_ status: String) -> TrackResult {
            result.report.status = status; result.report.seconds = Date().timeIntervalSince(start)
            result.report.observations = result.observations.count
            return result
        }
        let pairs = candidates(usable, maxDistanceM: options.maxDistanceM, minFacing: options.minFacing)
        result.report.candidatePairs = pairs.count
        guard !pairs.isEmpty else { return finish("noCandidates") }
        let queryFrames = Set(pairs.map { usable[$0.0].id })
        var existingTrack: [Int: [SIMD2<Float>: FeatureObservation]] = [:]
        var framesOfTrack: [Int: Set<Int>] = [:]
        for o in existing {
            framesOfTrack[o.trackID, default: []].insert(o.frameID)
            if queryFrames.contains(o.frameID) { existingTrack[o.frameID, default: [:]][SIMD2(o.u, o.v)] = o }
        }
        var nextID = (existing.map(\.trackID).max() ?? -1) + 1
        var newTrack: [Int: [SIMD2<Float>: Int]] = [:]
        let holdout = BundleAdjuster.kHoldoutEvery
        for (index, pair) in pairs.enumerated() {
            if isCancelled() { return finish("cancelled") }
            guard RefusionEngine.hasOptionalProcessingHeadroom else { return finish("memoryPressure") }
            let ra = usable[pair.0], rb = usable[pair.1]
            let matched: [GuidedMatch] = autoreleasepool {
                guard let a = OfflinePoseRefinement.extract(ra, directory: directory),
                      let viewA = guidedView(ra, directory: directory),
                      let viewB = guidedView(rb, directory: directory) else { return [] }
                return guidedMatches(a.features, from: viewA, to: viewB)
            }
            result.report.pairMatchCounts.append(matched.count)
            progress(Double(index + 1) / Double(pairs.count))
            let accepted: [GuidedMatch]
            if options.requireImprovement {
                guard let edge = verifiedEdge(a: pair.0, b: pair.1, matches: matched.map(\.match)) else { continue }
                accepted = matched.filter { simd_distance($0.match.a, point(edge.alignment, $0.match.b)) < options.inlierM }
            } else {
                guard let fit = rigidInliers(matched.map(\.match), options: options) else { continue }
                accepted = fit.inliers.map { matched[$0] }
            }
            result.report.verifiedPairs += 1
            result.report.verifiedPairFrameIDs.append([ra.id, rb.id])
            for m in accepted {
                let key = SIMD2(m.feature.u, m.feature.v)
                let observationA: FeatureObservation
                if let linked = existingTrack[ra.id]?[key] {
                    guard !(framesOfTrack[linked.trackID]?.contains(rb.id) ?? false) else { continue }
                    observationA = linked
                    result.report.linkedTracks += 1
                } else if let id = newTrack[ra.id]?[key] {
                    guard !(framesOfTrack[id]?.contains(rb.id) ?? false) else { continue }
                    observationA = FeatureObservation(frameID: ra.id, trackID: id, u: m.feature.u, v: m.feature.v, depth: m.feature.depth)
                } else {
                    let id = nextID; nextID += 1
                    newTrack[ra.id, default: [:]][key] = id
                    observationA = FeatureObservation(frameID: ra.id, trackID: id, u: m.feature.u, v: m.feature.v, depth: m.feature.depth)
                    result.observations.append(observationA)
                    framesOfTrack[id, default: []].insert(ra.id)
                    result.report.newTracks += 1
                }
                let observationB = FeatureObservation(frameID: rb.id, trackID: observationA.trackID, u: m.u, v: m.v, depth: m.depth)
                result.observations.append(observationB)
                framesOfTrack[observationA.trackID, default: []].insert(rb.id)
                if observationA.trackID % holdout == holdout - 1 {
                    result.heldOut.append(RevisitTrack(a: observationA, b: observationB))
                }
            }
        }
        result.report.heldOutTracks = Set(result.heldOut.map(\.a.trackID)).count
        guard !result.observations.isEmpty else { return finish("noVerifiedLoops") }
        return finish("added")
    }

    /// World point of an observation under a camera-to-world pose (original-pixel intrinsics).
    static func world(_ o: FeatureObservation, k: CameraIntrinsics, pose: simd_float4x4) -> SIMD3<Float> {
        point(pose, ray(o.u, o.v, k) * o.depth)
    }

    /// Median distance between the two LiDAR observations of each held-out revisit track.
    static func heldOutDistance(_ tracks: [RevisitTrack], records: [FrameRecord], poses: [Int: simd_float4x4]) -> Float? {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let distances: [Float] = tracks.compactMap { t in
            guard let ra = byID[t.a.frameID], let rb = byID[t.b.frameID] else { return nil }
            let pa = poses[ra.id] ?? RefusionEngine.float4x4(rowMajor: ra.transform)
            let pb = poses[rb.id] ?? RefusionEngine.float4x4(rowMajor: rb.transform)
            return simd_distance(world(t.a, k: ra.intrinsics, pose: pa), world(t.b, k: rb.intrinsics, pose: pb))
        }
        return distances.isEmpty ? nil : median(distances)
    }

    /// Small-angle rigid least squares about the observation centroid; no scale parameter.
    static func align(_ matches: [Match]) -> simd_float4x4? {
        guard matches.count >= 3 else { return nil }
        let origin = matches.reduce(SIMD3<Float>.zero) { $0 + $1.b } / Float(matches.count)
        let spread = matches.map { $0.b - origin }
        guard spread.contains(where: { p in spread.contains { simd_length(simd_cross(p, $0)) > 0.01 } }) else { return nil }
        var transform = matrix_identity_float4x4
        for _ in 0..<5 {
            var h = [Float](repeating: 0, count: 36), rhs = [Float](repeating: 0, count: 6)
            let c = point(transform, origin)
            for m in matches {
                let transformed = point(transform, m.b), p = transformed - c, error = m.a - transformed
                let rows: [[Float]] = [[0, p.z, -p.y, 1, 0, 0], [-p.z, 0, p.x, 0, 1, 0], [p.y, -p.x, 0, 0, 0, 1]]
                for axis in 0..<3 { for i in 0..<6 {
                    rhs[i] += rows[axis][i] * error[axis]
                    for j in 0..<6 { h[i*6+j] += rows[axis][i] * rows[axis][j] }
                } }
            }
            guard let delta = PoseRefiner.choleskySolve6(h, rhs) else { return nil }
            let rotation = SIMD3(delta[0], delta[1], delta[2]), translation = SIMD3(delta[3], delta[4], delta[5])
            guard simd_length(rotation) < 0.2, simd_length(translation) < 0.4 else { return nil }
            transform = PoseRefiner.deltaTransform(omega: rotation, trans: translation, about: c) * transform
        }
        return transform
    }

    static func verifiedEdge(a: Int, b: Int, matches: [Match]) -> Edge? {
        guard matches.count >= 40 else { return nil }
        let fit = matches.enumerated().filter { $0.offset % 5 != 0 }.map(\.element)
        let held = matches.enumerated().filter { $0.offset % 5 == 0 }.map(\.element)
        var best: [Match] = []
        // Deterministic RANSAC. Held-out observations never enter model fitting or refitting.
        var seed: UInt64 = 42
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
        for _ in 0..<64 {
            let indices = Set([random(fit.count), random(fit.count), random(fit.count)])
            guard indices.count == 3, let t = align(indices.sorted().map { fit[$0] }) else { continue }
            let inliers = fit.filter { simd_distance($0.a, point(t, $0.b)) < 0.025 }
            if inliers.count > best.count { best = inliers }
        }
        guard best.count >= 24, best.count * 5 >= fit.count * 3, let t = align(best) else { return nil }
        let before = median(held.map { simd_distance($0.a, $0.b) })
        let after = median(held.map { simd_distance($0.a, point(t, $0.b)) })
        guard before > 0.005, after < 0.025, after < before * 0.8,
              held.filter({ simd_distance($0.a, point(t, $0.b)) < 0.04 }).count * 4 >= held.count * 3 else { return nil }
        return Edge(a: a, b: b, alignment: t, heldOut: held)
    }

    /// Linearized SE(3) correction graph, anchored at frame zero. Six sparse SPD systems use
    /// conjugate gradients; memory is O(frames + edges), never a dense 6N x 6N matrix.
    static func corrections(count: Int, edges: [Edge], isCancelled: () -> Bool = { false }) -> [simd_float4x4] {
        guard count > 1, !edges.isEmpty else { return Array(repeating: matrix_identity_float4x4, count: count) }
        var links: [(Int, Int, Double, [Double])] = []
        for i in 1..<count { links.append((i-1, i, 100, Array(repeating: 0, count: 6))) }
        for edge in edges {
            let q = simd_quatf(edge.alignment), angle = q.angle
            let r = angle.isFinite && abs(angle) > 1e-7 ? q.axis * angle : .zero
            let t = center(edge.alignment)
            links.append((edge.a, edge.b, 200, [Double(r.x), Double(r.y), Double(r.z), Double(t.x), Double(t.y), Double(t.z)]))
        }
        func multiply(_ x: [Double]) -> [Double] {
            var y = x.map { $0 * 0.002 }
            for (a,b,w,_) in links {
                let v = w * ((b == 0 ? 0 : x[b]) - (a == 0 ? 0 : x[a]))
                if a != 0 { y[a] -= v }; if b != 0 { y[b] += v }
            }
            y[0] = x[0]; return y
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).reduce(0) { $0 + $1.0 * $1.1 } }
        var values = [[Double]]()
        for axis in 0..<6 {
            var rhs = [Double](repeating: 0, count: count)
            for (a,b,w,d) in links { if a != 0 { rhs[a] -= w*d[axis] }; if b != 0 { rhs[b] += w*d[axis] } }
            var x = [Double](repeating: 0, count: count), residual = rhs, direction = rhs
            var squared = dot(residual,residual)
            for _ in 0..<min(2*count, 600) {
                if isCancelled() { return Array(repeating: matrix_identity_float4x4, count: count) }
                if squared < 1e-16 { break }
                let product = multiply(direction), denominator = dot(direction,product)
                guard denominator > 1e-20 else { break }
                let alpha = squared / denominator
                for i in 1..<count { x[i] += alpha*direction[i]; residual[i] -= alpha*product[i] }
                let next = dot(residual,residual), beta = next/squared
                for i in 1..<count { direction[i] = residual[i] + beta*direction[i] }
                squared = next
            }
            values.append(x)
        }
        return (0..<count).map { i in
            PoseRefiner.deltaTransform(omega: SIMD3(Float(values[0][i]), Float(values[1][i]), Float(values[2][i])),
                trans: SIMD3(Float(values[3][i]), Float(values[4][i]), Float(values[5][i])), about: .zero)
        }
    }

    static func run(records: [FrameRecord], directory: URL, guided: Bool = true,
                    isCancelled: @escaping @Sendable () -> Bool,
                    progress: @escaping @Sendable (Double) -> Void) -> Result {
        let start = Date(); var report = Report()
        report.matching = guided ? "guided" : "descriptor"
        func finish(_ status: String, _ output: [FrameRecord]) -> Result {
            report.status = status; report.seconds = Date().timeIntervalSince(start)
            return Result(records: output, report: report)
        }
        let usable = records.filter { $0.blurVerdict != .drop && $0.depthFile != nil && $0.timestamp.isFinite && $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite) }
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        let pairs = candidates(usable); report.candidatePairs = pairs.count
        guard !pairs.isEmpty else { return finish("noCandidates", records) }
        var edges: [Edge] = []
        for (index, pair) in pairs.enumerated() {
            if isCancelled() { return finish("cancelled", records) }
            guard RefusionEngine.hasOptionalProcessingHeadroom else { return finish("memoryPressure", records) }
            autoreleasepool {
                var paired: [Match]?
                if guided {
                    if let a = OfflinePoseRefinement.extract(usable[pair.0], directory: directory),
                       let viewA = guidedView(usable[pair.0], directory: directory),
                       let viewB = guidedView(usable[pair.1], directory: directory) {
                        paired = guidedMatches(a.features, from: viewA, to: viewB).map(\.match)
                    }
                } else if let a = OfflinePoseRefinement.extract(usable[pair.0], directory: directory),
                          let b = OfflinePoseRefinement.extract(usable[pair.1], directory: directory) {
                    paired = matches(a.features,b.features)
                }
                if let paired {
                    report.peakDescriptorFrames = 2
                    report.maximumPairMatches = max(report.maximumPairMatches, paired.count)
                    report.pairMatchCounts = (report.pairMatchCounts ?? []) + [paired.count]
                    if let edge = verifiedEdge(a: pair.0, b: pair.1, matches: paired) { edges.append(edge) }
                }
            }
            progress(Double(index+1) / Double(pairs.count) * 0.85)
        }
        report.verifiedPairs = edges.count
        guard !edges.isEmpty else { return finish("noVerifiedLoops", records) }
        if isCancelled() { return finish("cancelled", records) }
        let delta = corrections(count: usable.count, edges: edges, isCancelled: isCancelled)
        let poses = usable.map { RefusionEngine.float4x4(rowMajor: $0.transform) }
        let adjusted = zip(delta,poses).map(*)
        for i in usable.indices {
            let shift = simd_distance(center(adjusted[i]),center(poses[i]))
            report.maximumCorrectionM = max(report.maximumCorrectionM, shift)
            guard shift <= 0.15, simd_quatf(delta[i]).angle <= 5 * .pi / 180 else { return finish("excessiveCorrection", records) }
            if i > 0 {
                let before = poses[i-1].inverse * poses[i], after = adjusted[i-1].inverse * adjusted[i]
                guard simd_distance(center(before),center(after)) < 0.02,
                      simd_quatf(after * before.inverse).angle < 0.01 else { return finish("odometryChanged", records) }
            }
        }
        func pixel(_ p: SIMD3<Float>, pose: simd_float4x4, k: CameraIntrinsics) -> SIMD2<Float>? {
            let local = pose.inverse * SIMD4(p,1)
            guard local.z < -0.05 else { return nil }
            return SIMD2(Float(k.cx) - Float(k.fx)*local.x/local.z,
                         Float(k.cy) + Float(k.fy)*local.y/local.z)
        }
        var before: [Float] = [], after: [Float] = []
        var pixelsBefore: [Float] = [], pixelsAfter: [Float] = []
        for edge in edges {
            let old = edge.heldOut.map { simd_distance($0.a,$0.b) }
            let new = edge.heldOut.map { simd_distance(point(delta[edge.a],$0.a),point(delta[edge.b],$0.b)) }
            guard median(new) <= median(old) * 1.05 else { return finish("validationRejected", records) }
            before += old; after += new
            for m in edge.heldOut {
                for (i, own, other, otherIndex) in [(edge.a,m.a,m.b,edge.b),(edge.b,m.b,m.a,edge.a)] {
                    let k = usable[i].intrinsics
                    guard let target = pixel(own,pose:poses[i],k:k),
                          let oldPixel = pixel(other,pose:poses[i],k:k),
                          let newPixel = pixel(point(delta[otherIndex],other),pose:adjusted[i],k:k) else {
                        return finish("validationRejected", records)
                    }
                    pixelsBefore.append(simd_distance(target,oldPixel)); pixelsAfter.append(simd_distance(target,newPixel))
                }
            }
        }
        report.heldOutBeforeM = median(before); report.heldOutAfterM = median(after)
        report.heldOutBeforePx = median(pixelsBefore); report.heldOutAfterPx = median(pixelsAfter)
        guard median(after) < median(before)*0.95, median(pixelsAfter) <= median(pixelsBefore)*1.02 else { return finish("validationRejected", records) }
        if isCancelled() { return finish("cancelled", records) }
        // Smoothly carry the accepted correction through excluded/unsupported frames too.
        // Their RGB may remain in playback, even when depth was not eligible for matching.
        let output = records.map { r -> FrameRecord in
            guard r.timestamp.isFinite, r.transform.count == 16, r.transform.allSatisfy(\.isFinite) else { return r }
            var lo = 0, hi = usable.count
            while lo < hi {
                let mid = (lo+hi)/2
                if usable[mid].timestamp < r.timestamp { lo = mid+1 } else { hi = mid }
            }
            let b = min(lo,usable.count-1), a = max(0,b-1)
            let duration = usable[b].timestamp-usable[a].timestamp
            let f = duration > 0 ? Float(min(1,max(0,(r.timestamp-usable[a].timestamp)/duration))) : 0
            let q = simd_slerp(simd_quatf(delta[a]),simd_quatf(delta[b]),f)
            var correction = simd_float4x4(q)
            correction.columns.3 = SIMD4(center(delta[a])*(1-f)+center(delta[b])*f,1)
            var result = r
            result.transform = RefusionEngine.rowMajor(correction * RefusionEngine.float4x4(rowMajor:r.transform))
            return result
        }
        for (original, changed) in zip(records, output) where original.transform.count == 16 && original.transform.allSatisfy(\.isFinite) {
            let old = RefusionEngine.float4x4(rowMajor:original.transform)
            let new = RefusionEngine.float4x4(rowMajor:changed.transform)
            guard simd_distance(center(old),center(new)) <= 0.15 else { return finish("excessiveCorrection", records) }
        }
        progress(1)
        return finish("validated", output)
    }
}
