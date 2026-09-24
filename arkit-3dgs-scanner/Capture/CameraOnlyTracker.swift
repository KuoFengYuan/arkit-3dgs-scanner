import Foundation
import simd

/// Feature tracks for scans without depth (LiDAR off).
///
/// Shi-Tomasi corners are tracked from each keyframe to the next with pyramidal Lucas-Kanade.
/// The search starts where ARKit's relative motion predicts the feature (at the track's current
/// depth estimate). A step is kept only if tracking back returns to the start, the patches
/// correlate, and the match lies on the epipolar line of the input poses. Observations carry no
/// depth (`depth = 0`); `BundleAdjuster` triangulates them from the current poses.
nonisolated enum CameraOnlyTracker {
    struct Options: Sendable {
        /// Tracking image long edge (pixels); observations are reported at the saved resolution.
        var imageDimension = 640
        var gridColumns = 16
        var gridRows = 12
        /// At most one new corner per empty grid cell; this caps live tracks per frame.
        var maxTracks = 192
        /// Mean min-eigenvalue of the 7×7 structure tensor (intensities 0...1).
        var minCornerResponse: Float = 2e-4
        var windowRadius = 7
        var pyramidLevels = 3
        var iterations = 12
        var maxForwardBackwardPx: Float = 0.7
        var minCorrelation: Float = 0.8
        /// Distance from the input poses' epipolar line, in saved-resolution pixels.
        var maxEpipolarPx: Float = 4
        /// Longer tracks accumulate Lucas-Kanade drift; a new track restarts from a fresh corner.
        var maxTrackLength = 40
        var minTrackLength = 3
        var nominalDepthM: Float = 1.5
        init() {}
    }

    struct Report: Codable, Sendable {
        var frames = 0
        var failedFrames = 0
        var tracks = 0
        var observations = 0
        var medianTrackLength = 0
        var detected = 0
        var tracked = 0
        var rejectedForwardBackward = 0
        var rejectedCorrelation = 0
        var rejectedEpipolar = 0
        var seconds = 0.0
    }

    /// Grayscale pyramid level, intensities 0...1.
    struct Level {
        let width: Int, height: Int
        var values: [Float]
    }

    static func pyramid(_ plane: RGBStereoMatcher.Plane, levels: Int) -> [Level] {
        var result = [Level(width: plane.width, height: plane.height, values: Array(plane.values))]
        for _ in 1..<max(1, levels) {
            let top = result[result.count - 1]
            let w = top.width / 2, h = top.height / 2
            guard w >= 16, h >= 16 else { break }
            var values = [Float](repeating: 0, count: w * h)
            top.values.withUnsafeBufferPointer { src in
                for y in 0..<h { for x in 0..<w {
                    let i = 2 * y * top.width + 2 * x
                    values[y * w + x] = (src[i] + src[i + 1] + src[i + top.width] + src[i + top.width + 1]) * 0.25
                } }
            }
            result.append(Level(width: w, height: h, values: values))
        }
        return result
    }

    @inline(__always)
    private static func sample(_ v: UnsafeBufferPointer<Float>, _ w: Int, _ x: Float, _ y: Float) -> Float {
        let ix = Int(x), iy = Int(y), a = x - Float(ix), b = y - Float(iy), i = iy * w + ix
        let top = v[i] + (v[i + 1] - v[i]) * a
        let bottom = v[i + w] + (v[i + w + 1] - v[i + w]) * a
        return top + (bottom - top) * b
    }

    @inline(__always)
    private static func inside(_ level: Level, _ p: SIMD2<Float>, margin: Float) -> Bool {
        p.x >= margin && p.y >= margin && p.x < Float(level.width - 1) - margin && p.y < Float(level.height - 1) - margin
    }

    /// Inverse-compositional Lucas-Kanade (translation, mean-normalized) from `from` in `a` to
    /// `b`, starting at `guess`. Returns the level-0 position or nil if it leaves the image or the
    /// patch has no texture.
    static func lucasKanade(_ a: [Level], _ b: [Level], from: SIMD2<Float>, guess: SIMD2<Float>,
                            options: Options) -> SIMD2<Float>? {
        let r = options.windowRadius, n = (2 * r + 1) * (2 * r + 1)
        var template = [Float](repeating: 0, count: n), gx = template, gy = template, patch = template
        var q = guess
        for level in stride(from: min(a.count, b.count) - 1, through: 0, by: -1) {
            let scale = Float(1 << level)
            let p = (from + 0.5) / scale - 0.5
            var ql = (q + 0.5) / scale - 0.5
            let la = a[level], lb = b[level]
            let margin = Float(r + 2)
            guard inside(la, p, margin: margin) else { return nil }
            var hxx: Float = 0, hxy: Float = 0, hyy: Float = 0, mean: Float = 0
            la.values.withUnsafeBufferPointer { v in
                var k = 0
                for dy in -r...r { for dx in -r...r {
                    let x = p.x + Float(dx), y = p.y + Float(dy)
                    template[k] = sample(v, la.width, x, y)
                    gx[k] = (sample(v, la.width, x + 1, y) - sample(v, la.width, x - 1, y)) * 0.5
                    gy[k] = (sample(v, la.width, x, y + 1) - sample(v, la.width, x, y - 1)) * 0.5
                    hxx += gx[k] * gx[k]; hxy += gx[k] * gy[k]; hyy += gy[k] * gy[k]
                    mean += template[k]; k += 1
                } }
            }
            mean /= Float(n)
            for k in 0..<n { template[k] -= mean }
            let det = hxx * hyy - hxy * hxy
            guard det > 1e-9 * Float(n * n) else { return nil }
            let inv = 1 / det
            var ok = true
            lb.values.withUnsafeBufferPointer { v in
                for _ in 0..<options.iterations {
                    guard inside(lb, ql, margin: margin) else { ok = false; return }
                    var sx: Float = 0, sy: Float = 0, sum: Float = 0, k = 0
                    for dy in -r...r { for dx in -r...r {
                        patch[k] = sample(v, lb.width, ql.x + Float(dx), ql.y + Float(dy)); sum += patch[k]; k += 1
                    } }
                    let m = sum / Float(n)
                    for k in 0..<n {
                        let e = patch[k] - m - template[k]
                        sx += gx[k] * e; sy += gy[k] * e
                    }
                    let step = SIMD2<Float>((hyy * sx - hxy * sy) * inv, (hxx * sy - hxy * sx) * inv)
                    ql -= step
                    if simd_length(step) < 0.01 { break }
                }
            }
            guard ok else { return nil }
            q = (ql + 0.5) * scale - 0.5
        }
        return q.x.isFinite && q.y.isFinite ? q : nil
    }

    /// Zero-mean normalized cross-correlation of the two level-0 windows.
    static func correlation(_ a: Level, _ p: SIMD2<Float>, _ b: Level, _ q: SIMD2<Float>, radius: Int) -> Float {
        let margin = Float(radius + 1)
        guard inside(a, p, margin: margin), inside(b, q, margin: margin) else { return -1 }
        var sa: Float = 0, sb: Float = 0, saa: Float = 0, sbb: Float = 0, sab: Float = 0
        let n = Float((2 * radius + 1) * (2 * radius + 1))
        a.values.withUnsafeBufferPointer { va in
            b.values.withUnsafeBufferPointer { vb in
                for dy in -radius...radius { for dx in -radius...radius {
                    let x = sample(va, a.width, p.x + Float(dx), p.y + Float(dy))
                    let y = sample(vb, b.width, q.x + Float(dx), q.y + Float(dy))
                    sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y
                } }
            }
        }
        let va = saa - sa * sa / n, vb = sbb - sb * sb / n
        guard va > 1e-6, vb > 1e-6 else { return -1 }
        return (sab - sa * sb / n) / (va * vb).squareRoot()
    }

    /// Strongest Shi-Tomasi corner in each empty grid cell.
    static func detect(_ level: Level, occupied: Set<Int>, options: Options) -> [(cell: Int, point: SIMD2<Float>)] {
        let cw = Float(level.width) / Float(options.gridColumns), ch = Float(level.height) / Float(options.gridRows)
        let r = 3, margin = options.windowRadius + 4
        var corners = [(cell: Int, point: SIMD2<Float>)]()
        level.values.withUnsafeBufferPointer { v in
            let w = level.width
            for row in 0..<options.gridRows { for column in 0..<options.gridColumns {
                let cell = row * options.gridColumns + column
                guard !occupied.contains(cell) else { continue }
                let x0 = max(margin, Int(Float(column) * cw)), x1 = min(level.width - margin, Int(Float(column + 1) * cw))
                let y0 = max(margin, Int(Float(row) * ch)), y1 = min(level.height - margin, Int(Float(row + 1) * ch))
                guard x1 > x0, y1 > y0 else { continue }
                var best: Float = options.minCornerResponse, found: SIMD2<Float>?
                for y in stride(from: y0, to: y1, by: 2) { for x in stride(from: x0, to: x1, by: 2) {
                    var xx: Float = 0, yy: Float = 0, xy: Float = 0
                    for dy in -r...r { for dx in -r...r {
                        let i = (y + dy) * w + x + dx
                        let gx = (v[i + 1] - v[i - 1]) * 0.5, gy = (v[i + w] - v[i - w]) * 0.5
                        xx += gx * gx; yy += gy * gy; xy += gx * gy
                    } }
                    let area = Float((2 * r + 1) * (2 * r + 1))
                    xx /= area; yy /= area; xy /= area
                    let response = (xx + yy) * 0.5 - (((xx - yy) * 0.5) * ((xx - yy) * 0.5) + xy * xy).squareRoot()
                    if response > best { best = response; found = SIMD2(Float(x), Float(y)) }
                } }
                if let found { corners.append((cell, found)) }
            }}
        }
        return corners
    }

    private struct Active {
        let id: Int
        var point: SIMD2<Float>       // tracking resolution, previous frame
        var length: Int
        var observations: [FeatureObservation]
    }

    /// Tracks features through `records` in capture order. Frames that fail to decode end all
    /// live tracks (the next frame starts fresh).
    static func track(records: [FrameRecord], directory: URL, options: Options = Options(),
                      isCancelled: () -> Bool = { false },
                      progress: (Double) -> Void = { _ in }) -> (observations: [FeatureObservation], report: Report) {
        let start = Date()
        var report = Report()
        let frames = records.filter { $0.blurVerdict != .drop && $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite) }
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        report.frames = frames.count
        var output = [FeatureObservation]()
        var active = [Active]()
        var nextID = 0
        var previous: (record: FrameRecord, pyramid: [Level], c2w: simd_float4x4, k: CameraIntrinsics, scale: Float)?
        var depthEstimate = options.nominalDepthM

        func finish(_ track: Active) {
            guard track.observations.count >= options.minTrackLength else { return }
            output += track.observations
        }

        for (index, record) in frames.enumerated() {
            if isCancelled() { break }
            guard let image = RGBReconstructionEngine.load(record: record, sessionDir: directory, maxDimension: options.imageDimension) else {
                report.failedFrames += 1
                active.forEach(finish); active = []; previous = nil
                continue
            }
            let levels = pyramid(image.plane, levels: options.pyramidLevels)
            let scale = Float(image.width) / Float(record.intrinsics.width)
            let k = image.intrinsics, c2w = RefusionEngine.float4x4(rowMajor: record.transform)
            var survivors = [Active]()
            if let prev = previous {
                let w2c = c2w.inverse
                let pk = prev.k
                func project(_ world: SIMD3<Float>) -> SIMD2<Float>? {
                    let c = w2c * SIMD4(world, 1)
                    guard c.z < -1e-3 else { return nil }
                    return SIMD2(Float(k.fx) * c.x / -c.z + Float(k.cx), Float(k.cy) - Float(k.fy) * c.y / -c.z)
                }
                func world(_ p: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
                    let local = SIMD4<Float>((p.x - Float(pk.cx)) / Float(pk.fx) * depth,
                                             -(p.y - Float(pk.cy)) / Float(pk.fy) * depth, -depth, 1)
                    let w = prev.c2w * local
                    return SIMD3(w.x, w.y, w.z)
                }
                for var t in active {
                    guard t.length < options.maxTrackLength,
                          let guess = project(world(t.point, depth: depthEstimate)),
                          let q = lucasKanade(prev.pyramid, levels, from: t.point, guess: guess, options: options) else {
                        finish(t); continue
                    }
                    guard let back = lucasKanade(levels, prev.pyramid, from: q, guess: t.point, options: options),
                          simd_distance(back, t.point) <= options.maxForwardBackwardPx else {
                        report.rejectedForwardBackward += 1; finish(t); continue
                    }
                    guard correlation(prev.pyramid[0], t.point, levels[0], q, radius: options.windowRadius) >= options.minCorrelation else {
                        report.rejectedCorrelation += 1; finish(t); continue
                    }
                    // Epipolar line of the previous ray, from two depths along it.
                    if let a = project(world(t.point, depth: 0.25)), let b = project(world(t.point, depth: 25)) {
                        let line = b - a, length = simd_length(line)
                        let distance = length > 0.5
                            ? abs(line.x * (q.y - a.y) - line.y * (q.x - a.x)) / length
                            : simd_distance(q, a)
                        guard distance / scale <= options.maxEpipolarPx else {
                            report.rejectedEpipolar += 1; finish(t); continue
                        }
                    }
                    report.tracked += 1
                    t.point = q; t.length += 1
                    t.observations.append(FeatureObservation(frameID: record.id, trackID: t.id,
                                                             u: q.x / scale, v: q.y / scale, depth: 0))
                    survivors.append(t)
                }
            }
            // New corners in cells without a live track.
            let cw = Float(image.width) / Float(options.gridColumns), ch = Float(image.height) / Float(options.gridRows)
            let occupied = Set(survivors.map { t in
                min(options.gridRows - 1, max(0, Int(t.point.y / ch))) * options.gridColumns
                    + min(options.gridColumns - 1, max(0, Int(t.point.x / cw)))
            })
            for corner in detect(levels[0], occupied: occupied, options: options) where survivors.count < options.maxTracks {
                report.detected += 1
                survivors.append(Active(id: nextID, point: corner.point, length: 1,
                                        observations: [FeatureObservation(frameID: record.id, trackID: nextID,
                                                                          u: corner.point.x / scale, v: corner.point.y / scale, depth: 0)]))
                nextID += 1
            }
            active = survivors
            // Scene depth for predictions: median of tracks triangulated with the input poses.
            if index % 10 == 9 {
                depthEstimate = medianTrackDepth(output + active.flatMap(\.observations), records: frames) ?? depthEstimate
            }
            previous = (record, levels, c2w, k, scale)
            progress(Double(index + 1) / Double(frames.count))
        }
        active.forEach(finish)
        report.observations = output.count
        var lengths = [Int: Int]()
        for o in output { lengths[o.trackID, default: 0] += 1 }
        report.tracks = lengths.count
        let sorted = lengths.values.sorted()
        report.medianTrackLength = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        report.seconds = Date().timeIntervalSince(start)
        return (output, report)
    }

    /// Median camera depth of up to 200 recent tracks, triangulated with the input poses.
    static func medianTrackDepth(_ observations: [FeatureObservation], records: [FrameRecord]) -> Float? {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var grouped = [Int: [FeatureObservation]]()
        for o in observations.suffix(4000) { grouped[o.trackID, default: []].append(o) }
        var depths = [Float]()
        // Sorted track IDs: dictionary order varies between runs and would change the estimate.
        for id in grouped.keys.sorted().suffix(200) {
            guard let list = grouped[id], list.count >= 3 else { continue }
            let rays = list.compactMap { o -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? in
                guard let r = byID[o.frameID] else { return nil }
                let c2w = RefusionEngine.float4x4(rowMajor: r.transform), k = r.intrinsics
                let d = c2w * SIMD4<Float>((o.u - Float(k.cx)) / Float(k.fx), -(o.v - Float(k.cy)) / Float(k.fy), -1, 0)
                return (SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z), simd_normalize(SIMD3(d.x, d.y, d.z)))
            }
            guard let point = BundleAdjuster.triangulate(rays, minParallaxDeg: 2), let last = rays.last else { continue }
            depths.append(simd_dot(point - last.origin, last.direction))
        }
        guard depths.count >= 10 else { return nil }
        depths.sort()
        return min(5, max(0.3, depths[depths.count / 2]))
    }
}

/// Pose refinement for camera-only scans: image-only feature tracks (`CameraOnlyTracker`) and the
/// joint bundle adjustment with ARKit's frame-to-frame motion as a prior. Held-out tracks decide
/// whether the result is applied, as for LiDAR scans; there is no depth-based photo check.
nonisolated enum CameraOnlyPoseRefinement {
    struct Report: Codable, Sendable {
        var version = 1
        var method = "camera-only-lucas-kanade-joint-bundle-adjustment"
        /// applied, holdoutDidNotImprove, insufficientHoldoutTracks, insufficientTrackSupport,
        /// noImprovement, noObservations, insufficientFrames, cancelled
        var status = "notRun"
        var inputFrames = 0
        var tracking: CameraOnlyTracker.Report?
        var roundsApplied = 0
        var holdoutMedianBeforePx: Float?
        var holdoutMedianAfterPx: Float?
        var appliedFrames = 0
        var medianCorrectionMM: Float?
        var maxCorrectionMM: Float?
        var seconds = 0.0
    }

    struct Result: Sendable {
        var records: [FrameRecord]
        var ba: PoseRefineResult
        var report: Report
    }

    /// The LiDAR defaults, except that track points are refined by reprojection after
    /// triangulation (camera-only tracks have no depth to anchor them). Replays of two scans chose
    /// this over plain triangulation, looser or tighter motion priors, a denser grid and longer
    /// tracks; see docs/CAMERA_ONLY_ACCURACY.md.
    static var defaultOptions: BundleAdjuster.Options {
        var options = BundleAdjuster.Options()
        options.optimizeTracks = true
        return options
    }

    static func run(records: [FrameRecord], directory: URL,
                    tracking: CameraOnlyTracker.Options = CameraOnlyTracker.Options(),
                    options: BundleAdjuster.Options = CameraOnlyPoseRefinement.defaultOptions,
                    isCancelled: @escaping () -> Bool = { false },
                    progress: @escaping (Double) -> Void = { _ in }) -> Result {
        let start = Date()
        var report = Report()
        let usable = records.filter { $0.blurVerdict != .drop && $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite) }
        report.inputFrames = usable.count
        func finish(_ status: String, _ ba: PoseRefineResult = PoseRefineResult()) -> Result {
            report.status = status
            report.seconds = Date().timeIntervalSince(start)
            progress(1)
            return Result(records: records, ba: ba, report: report)
        }
        guard usable.count >= 3 else { return finish("insufficientFrames") }
        let tracked = CameraOnlyTracker.track(records: usable, directory: directory, options: tracking,
                                              isCancelled: isCancelled, progress: { progress($0 * 0.9) })
        report.tracking = tracked.report
        guard !isCancelled() else { return finish("cancelled") }
        let ba = BundleAdjuster.refine(records: usable, observations: tracked.observations, rounds: 1,
                                       options: options, isCancelled: isCancelled)
        report.roundsApplied = ba.roundsApplied
        report.holdoutMedianBeforePx = ba.holdoutMedianPx?.before
        report.holdoutMedianAfterPx = ba.holdoutMedianPx?.after
        guard !isCancelled() else { return finish("cancelled") }
        guard !ba.poses.isEmpty else { return finish(ba.rejectionReason ?? "noImprovement", ba) }
        var corrections = [Float]()
        let refined = records.map { record -> FrameRecord in
            guard let pose = ba.poses[record.id] else { return record }
            let before = RefusionEngine.float4x4(rowMajor: record.transform)
            corrections.append(simd_distance(BundleAdjuster.center(pose), BundleAdjuster.center(before)) * 1000)
            var r = record
            r.transform = RefusionEngine.rowMajor(pose)
            return r
        }
        corrections.sort()
        report.appliedFrames = corrections.count
        report.medianCorrectionMM = corrections.isEmpty ? nil : corrections[corrections.count / 2]
        report.maxCorrectionMM = corrections.last
        var result = finish("applied", ba)
        result.records = refined
        return result
    }
}
