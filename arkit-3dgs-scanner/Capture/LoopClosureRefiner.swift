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
    static func candidates(_ records: [FrameRecord]) -> [(Int, Int)] {
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
                guard distance < 0.8, facing > 0.9 else { continue }
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

    static func run(records: [FrameRecord], directory: URL,
                    isCancelled: @escaping @Sendable () -> Bool,
                    progress: @escaping @Sendable (Double) -> Void) -> Result {
        let start = Date(); var report = Report()
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
                if let a = OfflinePoseRefinement.extract(usable[pair.0], directory: directory),
                   let b = OfflinePoseRefinement.extract(usable[pair.1], directory: directory) {
                    report.peakDescriptorFrames = 2
                    let paired = matches(a.features,b.features)
                    report.maximumPairMatches = max(report.maximumPairMatches, paired.count)
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
