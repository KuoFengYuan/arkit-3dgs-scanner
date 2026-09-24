// Pose-guided revisit matching and revisit tracks for the joint bundle adjustment, on a
// rendered two-pass scan of a textured wall with exact depth. Run by tools/test_metric_loop.sh.
import Foundation
import simd
import CoreGraphics
import ImageIO

@main struct RevisitTrackTests {
    static let width = 480, height = 360, depthWidth = 256, depthHeight = 192
    static let K = CameraIntrinsics(fx: 400, fy: 400, cx: 240, cy: 180, width: width, height: height)
    static let wallZ: Float = -2
    static let frames = 60

    /// Two-directional texture so shifts in any image direction change intensities.
    static func texture(_ x: Float, _ y: Float) -> Float {
        128 + 45 * sin(7 * x) * cos(5 * y) + 30 * sin(23 * x + 3 * y) + 25 * cos(31 * y - 11 * x)
            + 18 * sin(97 * x) * sin(89 * y)
    }
    /// An unrelated texture for a frame that must not match.
    static func otherTexture(_ x: Float, _ y: Float) -> Float {
        128 + 50 * sin(13 * x + 17 * y) * cos(19 * y) + 35 * cos(41 * x - 7 * y) + 20 * sin(71 * y)
    }

    static func pose(x: Float, z: Float, yawDeg: Float) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yawDeg * .pi / 180, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(x, 0, z, 1)
        return m
    }

    /// True camera poses: a pass along the wall at 2 m, then a return pass 30 cm closer, yawed 15°.
    static func truePose(_ i: Int) -> simd_float4x4 {
        let firstPass = i < frames / 2
        let s = Float(firstPass ? i : frames - 1 - i) / Float(frames / 2 - 1)
        return firstPass ? pose(x: -0.9 + 1.8 * s, z: 0, yawDeg: 0) : pose(x: -0.9 + 1.8 * s, z: -0.3, yawDeg: 15)
    }

    /// ARKit-like drift that grows over the return pass (up to 3 cm and 0.3°).
    static func drifted(_ i: Int, scale: Float = 1) -> simd_float4x4 {
        let f = max(0, Float(i - frames / 2 + 1) / Float(frames / 2)) * scale
        var d = simd_float4x4(simd_quatf(angle: 0.3 * .pi / 180 * f, axis: SIMD3(0, 1, 0)))
        d.columns.3 = SIMD4(0.03 * f, 0.005 * f, 0.02 * f, 1)
        return d * truePose(i)
    }

    static func render(_ c2w: simd_float4x4, name: String, directory: URL, texture: (Float, Float) -> Float = texture) throws {
        let R = simd_float3x3(SIMD3(c2w.columns.0.x, c2w.columns.0.y, c2w.columns.0.z),
                              SIMD3(c2w.columns.1.x, c2w.columns.1.y, c2w.columns.1.z),
                              SIMD3(c2w.columns.2.x, c2w.columns.2.y, c2w.columns.2.z))
        let c = SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z)
        func hit(_ u: Float, _ v: Float, _ k: CameraIntrinsics) -> (SIMD3<Float>, Float) {
            let ray = SIMD3((u - Float(k.cx)) / Float(k.fx), -(v - Float(k.cy)) / Float(k.fy), -1)
            let world = R * ray
            let t = (wallZ - c.z) / world.z
            return (c + world * t, t)   // t is the camera z-depth because the camera ray has z = -1
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for v in 0..<height { for u in 0..<width {
            let (p, _) = hit(Float(u), Float(v), K)
            let value = UInt8(max(0, min(255, texture(p.x, p.y))))
            rgba[(v * width + u) * 4] = value; rgba[(v * width + u) * 4 + 1] = value; rgba[(v * width + u) * 4 + 2] = value
        } }
        let dk = K.scaled(toWidth: depthWidth, height: depthHeight)
        var depth = [Float](repeating: 0, count: depthWidth * depthHeight)
        for v in 0..<depthHeight { for u in 0..<depthWidth { depth[v * depthWidth + u] = hit(Float(u), Float(v), dk).1 } }
        try depth.withUnsafeBytes { Data($0) }.write(to: directory.appendingPathComponent("depth/\(name)_depth.bin"))
        try Data(repeating: 2, count: depthWidth * depthHeight).write(to: directory.appendingPathComponent("depth/\(name)_conf.bin"))
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("images/\(name).jpg") as CFURL,
                                                           "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
    }

    static func record(_ id: Int, _ c2w: simd_float4x4, name: String? = nil) -> FrameRecord {
        let file = name ?? String(format: "frame_%05d", id)
        return FrameRecord(id: id, timestamp: Double(id) * 0.4, transform: RefusionEngine.rowMajor(c2w), intrinsics: K,
                           exposureDuration: 0.005, exposureOffsetEV: 0, estimatedBlurPx: 0,
                           imageFile: file + ".jpg", depthFile: file + "_depth.bin", confidenceFile: file + "_conf.bin",
                           depthWidth: depthWidth, depthHeight: depthHeight)
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        var checks = 0
        func check(_ value: Bool, _ text: String) { precondition(value, text); checks += 1; print("PASS: \(text)") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("revisit-tracks-\(UUID().uuidString)")
        for sub in ["images", "depth"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        for i in 0..<frames { try render(truePose(i), name: String(format: "frame_%05d", i), directory: directory) }
        try render(truePose(frames - 3), name: "other", directory: directory, texture: otherTexture)
        let exact = (0..<frames).map { record($0, truePose($0)) }
        let drift = (0..<frames).map { record($0, drifted($0)) }

        // 1. Guided matching recovers the drift between passes despite a 15° view change.
        let a = 2, b = frames - 3
        let features = OfflinePoseRefinement.extract(drift[a], directory: directory)!.features
        let viewA = LoopClosureRefiner.guidedView(drift[a], directory: directory)!
        let viewB = LoopClosureRefiner.guidedView(drift[b], directory: directory)!
        let guided = LoopClosureRefiner.guidedMatches(features, from: viewA, to: viewB)
        check(guided.count >= 60, "guided matching finds revisit correspondences across a 15° view change (\(guided.count))")
        let options = LoopClosureRefiner.RevisitOptions()
        let fit = LoopClosureRefiner.rigidInliers(guided.map(\.match), options: options)
        check(fit != nil && fit!.inliers.count * 10 >= guided.count * 9, "revisit matches agree with one rigid motion")
        // alignment maps b's (drifted) observations onto a's: it should undo the drift at frame b.
        let expected = truePose(b) * drifted(b).inverse
        let errors = guided.map { simd_distance(LoopClosureRefiner.point(expected, $0.match.b), $0.match.a) }
        check(LoopClosureRefiner.median(errors) < 0.005, "matched LiDAR points are consistent under the true drift correction")
        let recovered = fit.map { simd_distance(LoopClosureRefiner.center($0.alignment), LoopClosureRefiner.center(expected)) } ?? 1
        check(recovered < 0.01, "rigid inliers recover the injected drift")
        check(guided.allSatisfy { abs($0.u - Float(width) / 2) < Float(width) / 2 && $0.depth > 1 && $0.depth < 3 },
              "matches carry original-pixel coordinates and b's LiDAR depth")

        // 2. Guidance cannot create revisits: different images or drift outside the window yield none.
        let other = LoopClosureRefiner.guidedView(record(b, drifted(b), name: "other"), directory: directory)!
        let wrong = LoopClosureRefiner.guidedMatches(features, from: viewA, to: other)
        check(LoopClosureRefiner.rigidInliers(wrong.map(\.match), options: options) == nil,
              "an unrelated view produces no rigid revisit (\(wrong.count) raw matches)")
        let far = LoopClosureRefiner.guidedView(record(b, drifted(b, scale: 10)), directory: directory)!
        let outside = LoopClosureRefiner.guidedMatches(features, from: viewA, to: far)
        check(LoopClosureRefiner.rigidInliers(outside.map(\.match), options: options) == nil,
              "drift beyond the search window produces no revisit (\(outside.count) raw matches)")

        // 3. Revisit tracks: verified pairs, unique new IDs, existing-track linking, held-out distance.
        let tracks = LoopClosureRefiner.bundleObservations(records: drift, directory: directory, existing: [])
        check(tracks.report.candidatePairs > 0 && tracks.report.verifiedPairs > 0 && !tracks.observations.isEmpty,
              "drifted revisits become bundle-adjustment observations (\(tracks.report.verifiedPairs)/\(tracks.report.candidatePairs) pairs)")
        let perTrack = Dictionary(grouping: tracks.observations, by: \.trackID)
        check(perTrack.values.allSatisfy { Set($0.map(\.frameID)).count == $0.count && $0.count >= 2 },
              "each revisit track has one observation per frame and spans both passes")
        check(tracks.observations.allSatisfy { $0.frameID < frames / 2 || $0.frameID >= frames / 2 }
                && perTrack.values.allSatisfy { t in t.contains { $0.frameID < frames / 2 } && t.contains { $0.frameID >= frames / 2 } },
              "revisit tracks connect the first and the return pass")
        let before = LoopClosureRefiner.heldOutDistance(tracks.heldOut, records: drift, poses: [:])
        let truth = Dictionary(uniqueKeysWithValues: exact.map { ($0.id, RefusionEngine.float4x4(rowMajor: $0.transform)) })
        let atTruth = LoopClosureRefiner.heldOutDistance(tracks.heldOut, records: drift, poses: truth)
        check(!tracks.heldOut.isEmpty && before! > 0.015 && atTruth! < 0.004,
              "held-out revisit distance measures drift (\(before! * 1000) mm, \(atTruth! * 1000) mm at true poses)")
        let q = tracks.observations.first { $0.frameID < frames / 2 }!
        let existing = [FeatureObservation(frameID: q.frameID, trackID: 7, u: q.u, v: q.v, depth: q.depth)]
        let linked = LoopClosureRefiner.bundleObservations(records: drift, directory: directory, existing: existing)
        check(linked.report.linkedTracks >= 1 && linked.observations.contains { $0.trackID == 7 && $0.frameID >= frames / 2 }
                && !linked.observations.contains { $0.trackID == 7 && $0.frameID == q.frameID }
                && linked.observations.filter { $0.trackID != 7 }.allSatisfy { $0.trackID > 7 },
              "a revisit joins the existing track of its first observation; new tracks get fresh IDs")

        // 4. A consistent revisit still constrains drift; the rigid-correction check would discard it.
        let consistent = LoopClosureRefiner.bundleObservations(records: exact, directory: directory, existing: [])
        var strict = LoopClosureRefiner.RevisitOptions(); strict.requireImprovement = true
        let strictConsistent = LoopClosureRefiner.bundleObservations(records: exact, directory: directory, existing: [], options: strict)
        check(consistent.report.verifiedPairs > 0 && strictConsistent.report.verifiedPairs == 0,
              "already aligned revisits are kept as tracks but would not trigger a rigid correction")

        // 5. End to end: the joint bundle adjustment with revisit tracks reduces the revisit distance.
        let refined = await OfflinePoseRefinement.run(records: drift, directory: directory, rounds: 6)
        let loop = refined.report.loopTracks
        check(refined.report.loopMode == "bundleTracks" && (loop?.observations ?? 0) > 0,
              "the default feature stage adds revisit tracks (status \(refined.report.status))")
        if let beforeM = loop?.heldOutBeforeM, let afterM = loop?.heldOutAfterM {
            check(afterM < beforeM * 0.7, "joint BA with revisit tracks shrinks held-out revisit distance (\(beforeM * 1000) -> \(afterM * 1000) mm)")
        } else {
            check(refined.report.revisitFallback != nil, "a rejected revisit solve falls back without revisit tracks (\(refined.report.status))")
        }
        let off = await OfflinePoseRefinement.run(records: drift, directory: directory, rounds: 6, loopMode: .off)
        check(off.report.loopTracks == nil && off.report.loopMode == nil, "loop mode off adds no revisit tracks")
        print("\(checks) revisit track checks passed")
    }
}
