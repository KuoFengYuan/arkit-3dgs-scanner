import Foundation
import simd

/// Independent check of pose corrections against the photos themselves.
///
/// Refinement stages minimise feature reprojection and LiDAR agreement; their own held-out
/// residuals share those inputs and biases. A real-scan replay showed a correction that passed
/// its feature holdout yet made adjacent photos line up worse. This validator projects textured
/// LiDAR pixels of one frame into an overlapping frame and compares image intensities (NCC)
/// under the input and candidate poses, on identical samples. 3DGS training depends on exactly
/// this photometric alignment.
nonisolated enum PhotometricPoseValidator {
    struct Report: Codable, Sendable, Equatable {
        var status = "notRun"
        var adjacentPairs = 0
        var widePairs = 0
        /// Median NCC over evaluated pairs.
        var adjacentBefore: Float?
        var adjacentAfter: Float?
        var wideBefore: Float?
        var wideAfter: Float?
        /// Median of per-pair NCC changes (candidate - input).
        var adjacentDelta: Float?
        var wideDelta: Float?
        /// Adjacent pairs whose NCC dropped by more than `worseDrop`.
        var adjacentWorse = 0
        /// Baseline-valid samples must not disappear to make a candidate score better.
        var baselineSamples: Int? = 0
        var retainedSamples: Int? = 0
        var minimumRetainedFraction: Float?
        var lowRetentionPairs: Int? = 0
        var evaluatedPairs: Int? = 0
        var adjacentEffectiveDelta: Float?
        var wideEffectiveDelta: Float?
        var seconds = 0.0
        var accepted: Bool { status == "accepted" }
    }

    struct Pair: Hashable, Sendable {
        let target: Int
        let source: Int
        let adjacent: Bool
    }

    static let imageDimension = 960
    static let maxAdjacentPairs = 40
    static let maxWidePairs = 40
    static let minimumPairs = 8
    static let minimumSamples = 400
    static let minimumRetainedFraction: Float = 0.90
    static let minimumTotalRetainedFraction: Float = 0.95
    static let maxLowRetentionFraction: Float = 0.15
    static let lostSamplePenalty: Float = 0.1
    /// Adjacent ARKit poses already align photos well (median NCC about 0.98-0.99 in replays);
    /// refinement must not disturb them.
    static let adjacentTolerance: Float = 0.002
    static let worseDrop: Float = 0.02
    static let maxWorseFraction = 0.15
    /// Wide-baseline pairs carry the error worth fixing; require a clear median gain.
    static let requiredWideGain: Float = 0.003

    /// Deterministic pair choice from the INPUT poses, so every candidate sees the same pairs.
    /// - focus: record indices the candidate moved. Pairs between two unmoved frames score
    ///   identically under both pose sets, so they are skipped rather than diluting the medians.
    static func pairs(_ records: [FrameRecord], focus: Set<Int>? = nil) -> [Pair] {
        let usable = records.indices.filter { i in
            let r = records[i]
            return r.blurVerdict != .drop && r.depthFile != nil && r.transform.count == 16
                && r.transform.allSatisfy(\.isFinite) && r.timestamp.isFinite
        }.sorted { records[$0].timestamp == records[$1].timestamp ? $0 < $1 : records[$0].timestamp < records[$1].timestamp }
        guard usable.count >= 2 else { return [] }
        func center(_ i: Int) -> SIMD3<Float> {
            let m = records[i].transform
            return SIMD3(Float(m[3]), Float(m[7]), Float(m[11]))
        }
        func forward(_ i: Int) -> SIMD3<Float> {
            let m = records[i].transform
            return -SIMD3(Float(m[2]), Float(m[6]), Float(m[10]))
        }
        func spread<T>(_ items: [T], _ limit: Int) -> [T] {
            guard items.count > limit, limit > 0 else { return items }
            return (0..<limit).map { items[$0 * items.count / limit] }
        }
        var adjacent: [Pair] = []
        for (a, b) in zip(usable, usable.dropFirst()) {
            let dt = records[b].timestamp - records[a].timestamp
            guard dt > 0, dt < 1, simd_distance(center(a), center(b)) > 0.005,
                  focus == nil || focus!.contains(a) || focus!.contains(b) else { continue }
            adjacent.append(Pair(target: a, source: b, adjacent: true))
        }
        var wide: [Pair] = []
        var seen = Set<[Int]>()
        for q in spread(usable.filter { focus == nil || focus!.contains($0) }, maxWidePairs * 3) {
            var best: (index: Int, score: Float)?
            for p in usable where p != q && abs(records[p].timestamp - records[q].timestamp) >= 1.5 {
                let distance = simd_distance(center(p), center(q))
                guard distance >= 0.25, distance <= 0.8, simd_dot(forward(p), forward(q)) > 0.8 else { continue }
                let score = abs(distance - 0.45)
                if best == nil || score < best!.score { best = (p, score) }
            }
            guard let best else { continue }
            let key = [min(q, best.index), max(q, best.index)]
            guard seen.insert(key).inserted else { continue }
            wide.append(Pair(target: q, source: best.index, adjacent: false))
        }
        return spread(adjacent, maxAdjacentPairs) + spread(wide, maxWidePairs)
    }

    private final class FrameCache {
        let records: [FrameRecord]
        let directory: URL
        private var images: [Int: ScanImageDecoder.Gray] = [:]
        private var depths: [Int: DepthConsistencyView] = [:]
        private var order: [Int] = []
        init(records: [FrameRecord], directory: URL) { self.records = records; self.directory = directory }
        func frame(_ i: Int) -> (ScanImageDecoder.Gray, DepthConsistencyView)? {
            if let image = images[i], let depth = depths[i] { return (image, depth) }
            guard let depth = RefusionEngine.storedDepthView(records[i], directory: directory.appendingPathComponent("depth")),
                  let image = ScanImageDecoder.gray(records[i], directory: directory, maxDimension: PhotometricPoseValidator.imageDimension)
            else { return nil }
            images[i] = image; depths[i] = depth; order.append(i)
            if order.count > 12 { let old = order.removeFirst(); images[old] = nil; depths[old] = nil }
            return (image, depth)
        }
    }

    @inline(__always)
    private static func bilinear(_ g: ScanImageDecoder.Gray, _ u: Float, _ v: Float) -> Float? {
        guard u.isFinite, v.isFinite, u >= 1, v >= 1, u < Float(g.width - 2), v < Float(g.height - 2) else { return nil }
        let x = Int(u), y = Int(v), a = u - Float(x), b = v - Float(y), w = g.width
        let p00 = Float(g.pixels[y * w + x]), p10 = Float(g.pixels[y * w + x + 1])
        let p01 = Float(g.pixels[(y + 1) * w + x]), p11 = Float(g.pixels[(y + 1) * w + x + 1])
        return (p00 * (1 - a) + p10 * a) * (1 - b) + (p01 * (1 - a) + p11 * a) * b
    }

    private static func ncc(_ a: [Float], _ b: [Float]) -> Float {
        let n = Double(a.count)
        guard n > 1 else { return 0 }
        var sa = 0.0, sb = 0.0
        for i in a.indices { sa += Double(a[i]); sb += Double(b[i]) }
        let ma = sa / n, mb = sb / n
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in a.indices {
            let x = Double(a[i]) - ma, y = Double(b[i]) - mb
            ab += x * y; aa += x * x; bb += y * y
        }
        return aa > 0 && bb > 0 ? Float(ab / (aa * bb).squareRoot()) : 0
    }

    struct PairScore {
        let before: Float
        let after: Float
        let samples: Int
        let baselineSamples: Int
        var retainedFraction: Float { Float(samples) / Float(max(1,baselineSamples)) }
        var effectiveDelta: Float { after - before - (1-retainedFraction)*lostSamplePenalty }
    }

    /// NCC uses the same intersection, but lost baseline-valid samples remain visible to the
    /// acceptance gate. Even a candidate losing every projection must be scored as a failure.
    static func pairScores(_ pair: Pair, before: [simd_float4x4], after: [simd_float4x4],
                           records: [FrameRecord], frames: (Int) -> (ScanImageDecoder.Gray, DepthConsistencyView)?)
        -> PairScore? {
        guard let (sourceImage, sourceDepth) = frames(pair.source),
              let (targetImage, targetDepth) = frames(pair.target) else { return nil }
        let dk = sourceDepth.intrinsics, dw = dk.width, dh = dk.height
        let su = Float(sourceImage.width) / Float(dw), sv = Float(sourceImage.height) / Float(dh)
        let tk = records[pair.target].intrinsics
        let gx = Float(targetImage.width) / Float(tk.width), gy = Float(targetImage.height) / Float(tk.height)
        let fx = Float(tk.fx) * gx, fy = Float(tk.fy) * gy, cx = Float(tk.cx) * gx, cy = Float(tk.cy) * gy
        let tdk = targetDepth.intrinsics
        let du = Float(tdk.width) / Float(targetImage.width), dv = Float(tdk.height) / Float(targetImage.height)
        struct Sample { let local: SIMD3<Float>; let intensity: Float; let gradient: Float }
        var samples: [Sample] = []
        samples.reserveCapacity(dw * dh / 2)
        let depth = sourceDepth.depth, confidence = sourceDepth.confidence
        for v in 1..<(dh - 1) {
            for u in 1..<(dw - 1) {
                let i = v * dw + u, d = depth[i]
                guard d.isFinite, d > 0.3, d < 4, (confidence?[i] ?? 2) >= 2 else { continue }
                let tolerance = d * 0.05
                let l = depth[i - 1], r = depth[i + 1], t = depth[i - dw], b = depth[i + dw]
                guard abs(l - d) <= tolerance, abs(r - d) <= tolerance,
                      abs(t - d) <= tolerance, abs(b - d) <= tolerance else { continue }   // NaN fails
                let uu = Float(u) * su, vv = Float(v) * sv
                guard let intensity = bilinear(sourceImage, uu, vv),
                      let l = bilinear(sourceImage, uu - 1, vv), let r = bilinear(sourceImage, uu + 1, vv),
                      let t = bilinear(sourceImage, uu, vv - 1), let b = bilinear(sourceImage, uu, vv + 1) else { continue }
                let x = (Float(u) - Float(dk.cx)) / Float(dk.fx) * d
                let y = (Float(v) - Float(dk.cy)) / Float(dk.fy) * d
                samples.append(Sample(local: SIMD3(x, -y, -d), intensity: intensity,
                                      gradient: ((r - l) * (r - l) + (b - t) * (b - t)).squareRoot()))
            }
        }
        guard samples.count >= minimumSamples else { return nil }
        let gradients = samples.map(\.gradient).sorted()
        let threshold = gradients[min(gradients.count - 1, Int(Float(gradients.count) * 0.7))]
        func project(_ local: SIMD3<Float>, sourcePose: simd_float4x4, targetInverse: simd_float4x4) -> Float? {
            let world = sourcePose * SIMD4(local, 1)
            let p = targetInverse * world, z = -p.z
            guard z > 0.2 else { return nil }
            let u = fx * p.x / z + cx, v = cy - fy * p.y / z
            let x = Int((u * du).rounded()), y = Int((v * dv).rounded())
            guard x >= 0, y >= 0, x < tdk.width, y < tdk.height else { return nil }
            let measured = targetDepth.depth[y * tdk.width + x]
            guard measured.isFinite, measured > 0.2, (targetDepth.confidence?[y * tdk.width + x] ?? 2) >= 1,
                  abs(measured - z) < max(0.03, z * 0.015) else { return nil }
            return bilinear(targetImage, u, v)
        }
        let beforeInverse = before[pair.target].inverse, afterInverse = after[pair.target].inverse
        var source: [Float] = [], first: [Float] = [], second: [Float] = []
        var baselineSamples = 0
        for s in samples where s.gradient >= threshold {
            guard let a = project(s.local, sourcePose: before[pair.source], targetInverse: beforeInverse) else { continue }
            baselineSamples += 1
            guard let b = project(s.local, sourcePose: after[pair.source], targetInverse: afterInverse) else { continue }
            source.append(s.intensity); first.append(a); second.append(b)
        }
        guard baselineSamples >= minimumSamples else { return nil }
        return PairScore(before:ncc(source,first), after:ncc(source,second),
                         samples:source.count, baselineSamples:baselineSamples)
    }

    private static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted(), m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    /// Compares candidate poses with the input poses. Records are matched by frame ID.
    /// - requiredGain: minimum median wide-baseline NCC change. A later stage checked against an
    ///   already accepted stage uses -adjacentTolerance: it must not harm, rather than improve.
    static func evaluate(input: [FrameRecord], candidate: [FrameRecord], directory: URL,
                         requiredGain: Float = requiredWideGain,
                         isCancelled: () -> Bool = { false }) -> Report {
        let started = Date()
        var report = Report()
        func finish(_ status: String) -> Report {
            report.status = status; report.seconds = Date().timeIntervalSince(started); return report
        }
        let byID = Dictionary(candidate.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let before = input.map { RefusionEngine.float4x4(rowMajor: $0.transform) }
        var after = before
        for (i, r) in input.enumerated() {
            if let c = byID[r.id], c.transform.count == 16, c.transform.allSatisfy(\.isFinite) {
                after[i] = RefusionEngine.float4x4(rowMajor: c.transform)
            }
        }
        let moved = Set(input.indices.filter { i in
            let a = before[i], b = after[i]
            return (0..<4).contains { c in simd_length(a[c] - b[c]) > 1e-6 }
        })
        guard !moved.isEmpty else { return finish("unchanged") }
        let cache = FrameCache(records: input, directory: directory)
        var adjacent: [(Float, Float)] = [], wide: [(Float, Float)] = []
        var adjacentEffective: [Float] = [], wideEffective: [Float] = []
        for pair in pairs(input, focus: moved) {
            if isCancelled() { return finish("cancelled") }
            guard let score = autoreleasepool(invoking: { pairScores(pair, before: before, after: after, records: input, frames: cache.frame) })
            else { continue }
            report.baselineSamples = (report.baselineSamples ?? 0) + score.baselineSamples
            report.retainedSamples = (report.retainedSamples ?? 0) + score.samples
            report.minimumRetainedFraction = min(report.minimumRetainedFraction ?? 1,score.retainedFraction)
            report.evaluatedPairs = (report.evaluatedPairs ?? 0) + 1
            if score.retainedFraction < minimumRetainedFraction || score.samples < minimumSamples {
                report.lowRetentionPairs = (report.lowRetentionPairs ?? 0) + 1
            }
            // Border/occlusion samples can change after a legitimate correction. Keep their
            // loss in the score and require >=95% retention overall, with at most 15% weak pairs.
            // An entirely lost pair gets a negative score instead of disappearing from the gate.
            let delta = score.samples >= minimumSamples ? score.effectiveDelta
                : -max(worseDrop,(1-score.retainedFraction)*lostSamplePenalty)
            if pair.adjacent {
                adjacentEffective.append(delta)
                if score.samples >= minimumSamples { adjacent.append((score.before,score.after)) }
            } else {
                wideEffective.append(delta)
                if score.samples >= minimumSamples { wide.append((score.before,score.after)) }
            }
        }
        report.adjacentPairs = adjacent.count; report.widePairs = wide.count
        report.adjacentBefore = median(adjacent.map(\.0)); report.adjacentAfter = median(adjacent.map(\.1))
        report.wideBefore = median(wide.map(\.0)); report.wideAfter = median(wide.map(\.1))
        report.adjacentDelta = median(adjacent.map { $0.1 - $0.0 })
        report.wideDelta = median(wide.map { $0.1 - $0.0 })
        report.adjacentWorse = adjacent.filter { $0.1 - $0.0 < -worseDrop }.count
        report.adjacentEffectiveDelta = median(adjacentEffective)
        report.wideEffectiveDelta = median(wideEffective)
        let totalRetention = Float(report.retainedSamples ?? 0) / Float(max(1,report.baselineSamples ?? 0))
        if (report.evaluatedPairs ?? 0) > 0 {
            guard totalRetention >= minimumTotalRetainedFraction,
                  Float(report.lowRetentionPairs ?? 0) <= Float(report.evaluatedPairs ?? 0)*maxLowRetentionFraction else {
                return finish("rejected")
            }
        }
        guard adjacent.count >= minimumPairs, wide.count >= minimumPairs,
              let adjacentDelta = report.adjacentEffectiveDelta, let wideDelta = report.wideEffectiveDelta else {
            return finish("insufficientPairs")
        }
        let adjacentKept = adjacentDelta >= -adjacentTolerance
            && Double(report.adjacentWorse) <= Double(adjacent.count) * maxWorseFraction
        return finish(adjacentKept && wideDelta >= requiredGain ? "accepted" : "rejected")
    }
}
