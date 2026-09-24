// Camera-only tracking + bundle adjustment on a rendered, textured room corner.
//
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,FeatureTracker,PoseRefiner,BundleAdjuster,RGBStereoMatcher,RGBReconstructionEngine,CameraOnlyTracker}.swift \
//   tools/test_camera_only_bundle.swift -o /tmp/fable-camera-only-bundle && /tmp/fable-camera-only-bundle
import Foundation
import CoreGraphics
import ImageIO
import simd

@main
struct CameraOnlyBundleTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1; print("PASS: \(message)")
    }

    static let k = CameraIntrinsics(fx: 280, fy: 280, cx: 160, cy: 120, width: 320, height: 240)

    /// Deterministic value noise: blobs with corners at two scales.
    static func noise(_ u: Float, _ v: Float, cell: Float, seed: UInt32) -> Float {
        func hash(_ x: Int, _ y: Int) -> Float {
            var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263) &+ seed
            h = (h ^ (h >> 13)) &* 1_274_126_177
            return Float((h ^ (h >> 16)) & 0xFFFF) / 65535
        }
        let x = u / cell, y = v / cell, ix = Int(floor(x)), iy = Int(floor(y))
        let fx = x - Float(ix), fy = y - Float(iy)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy) + (hash(ix + 1, iy) - hash(ix, iy)) * sx
        let b = hash(ix, iy + 1) + (hash(ix + 1, iy + 1) - hash(ix, iy + 1)) * sx
        return a + (b - a) * sy
    }

    /// Back wall (z = -2.2), floor (y = -1) and left wall (x = -1.6); flat = untextured.
    static func render(_ c2w: simd_float4x4, flat: Bool = false) -> [UInt8] {
        var data = [UInt8](); data.reserveCapacity(k.width * k.height * 4)
        let origin = SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z)
        for y in 0..<k.height { for x in 0..<k.width {
            let d4 = c2w * SIMD4<Float>((Float(x) - Float(k.cx)) / Float(k.fx), -(Float(y) - Float(k.cy)) / Float(k.fy), -1, 0)
            let d = SIMD3(d4.x, d4.y, d4.z)
            var best = Float.infinity, value: Float = 0.5
            func plane(_ t: Float, _ uv: (SIMD3<Float>) -> SIMD2<Float>, seed: UInt32) {
                guard t > 0.05, t < best else { return }
                let p = origin + d * t, c = uv(p)
                best = t
                value = flat ? 0.55 : 0.2 + 0.45 * noise(c.x, c.y, cell: 0.06, seed: seed) + 0.3 * noise(c.x, c.y, cell: 0.015, seed: seed &+ 7)
            }
            if d.z != 0 { plane((-2.2 - origin.z) / d.z, { SIMD2($0.x, $0.y) }, seed: 1) }
            if d.y != 0 { plane((-1.0 - origin.y) / d.y, { SIMD2($0.x, $0.z) }, seed: 2) }
            if d.x != 0 { plane((-1.6 - origin.x) / d.x, { SIMD2($0.z, $0.y) }, seed: 3) }
            let byte = UInt8(max(0, min(255, value * 255)))
            data += [byte, byte, byte, 255]
        } }
        return data
    }

    static func write(_ rgba: [UInt8], to url: URL) {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: k.width, height: k.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: k.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    /// A 1.2 m lateral pass with a gentle yaw sweep, looking into the corner.
    static func truth(_ i: Int) -> simd_float4x4 {
        let s = Float(i)
        var pose = simd_float4x4(simd_quatf(angle: 0.25 - s * 0.012, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -0.08, axis: SIMD3(1, 0, 0)))
        pose.columns.3 = SIMD4(-0.4 + s * 0.04, 0.2 + 0.02 * sin(s * 0.3), 0.4 + 0.01 * s, 1)
        return pose
    }

    /// Input pose error: slow drift (up to 2 cm / 0.4°) plus a wobble over a few frames
    /// (±5 mm, ±0.1°). Monocular tracks without loop closure cannot see the slow part, which the
    /// structure absorbs; the wobble is what feature tracks constrain.
    static func drifted(_ pose: simd_float4x4, _ i: Int, of n: Int) -> simd_float4x4 {
        let f = Float(i) / Float(n - 1), s = Float(i)
        let rotation = simd_quatf(angle: 0.007 * f * f + 0.0018 * sin(s * 0.9), axis: simd_normalize(SIMD3(0.3, 1, 0.2)))
        var out = simd_float4x4(rotation) * pose
        out.columns.3 = pose.columns.3 + SIMD4(0.02 * f * f + 0.005 * sin(s * 0.8), -0.012 * f + 0.004 * cos(s * 0.7), 0.008 * f, 0)
        return out
    }

    static func center(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }

    /// Mean error of the camera displacement over four-frame windows: independent of the gauge
    /// and of drift slower than the tracks can observe.
    static func relativeError(_ poses: [simd_float4x4], _ reference: [simd_float4x4], window: Int = 4) -> Float {
        var sum: Float = 0, count = 0
        for i in 0..<(poses.count - window) {
            let estimated = center(poses[i + window]) - center(poses[i])
            let actual = center(reference[i + window]) - center(reference[i])
            sum += simd_distance(estimated, actual); count += 1
        }
        return sum / Float(count)
    }

    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)   // keep progress visible if a check fails
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fable-camera-only-ba-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let n = 30
        var truthRecords = [FrameRecord](), flatRecords = [FrameRecord]()
        for i in 0..<n {
            let name = "frame_\(i).png", flatName = "flat_\(i).png"
            write(render(truth(i)), to: dir.appendingPathComponent("images/\(name)"))
            let record = FrameRecord(id: i, timestamp: Double(i) * 0.2, transform: RefusionEngine.rowMajor(truth(i)),
                                     intrinsics: k, exposureDuration: 0.005, exposureOffsetEV: 0, estimatedBlurPx: 0, imageFile: name)
            truthRecords.append(record)
            if i < 6 {
                write(render(truth(i), flat: true), to: dir.appendingPathComponent("images/\(flatName)"))
                var flat = record; flat.imageFile = flatName
                flatRecords.append(flat)
            }
        }
        let driftRecords = truthRecords.map { r -> FrameRecord in
            var out = r
            out.transform = RefusionEngine.rowMajor(drifted(truth(r.id), r.id, of: n))
            return out
        }

        // Tracking alone.
        let tracked = CameraOnlyTracker.track(records: driftRecords, directory: dir)
        let t = tracked.report
        print("tracks \(t.tracks), observations \(t.observations), median length \(t.medianTrackLength), rejected fb/corr/epi \(t.rejectedForwardBackward)/\(t.rejectedCorrelation)/\(t.rejectedEpipolar)")
        check(t.tracks > 150 && t.medianTrackLength >= 4 && tracked.observations.allSatisfy { $0.depth == 0 },
              "textured views give long depth-free tracks")
        // Observations reproject onto the true geometry: triangulate with the TRUE poses.
        let truthByID = Dictionary(uniqueKeysWithValues: truthRecords.map { ($0.id, truth($0.id)) })
        var grouped = [Int: [FeatureObservation]]()
        for o in tracked.observations { grouped[o.trackID, default: []].append(o) }
        var errors = [Float]()
        for (_, list) in grouped where list.count >= 4 {
            let rays = list.map { o -> (origin: SIMD3<Float>, direction: SIMD3<Float>) in
                let c2w = truthByID[o.frameID]!
                let d = c2w * SIMD4<Float>((o.u - Float(k.cx)) / Float(k.fx), -(o.v - Float(k.cy)) / Float(k.fy), -1, 0)
                return (center(c2w), simd_normalize(SIMD3(d.x, d.y, d.z)))
            }
            guard let point = BundleAdjuster.triangulate(rays, minParallaxDeg: 2) else { continue }
            for o in list {
                let w2c = truthByID[o.frameID]!.inverse, c = w2c * SIMD4(point, 1)
                let u = Float(k.fx) * c.x / -c.z + Float(k.cx), v = Float(k.cy) - Float(k.fy) * c.y / -c.z
                errors.append(simd_distance(SIMD2(u, v), SIMD2(o.u, o.v)))
            }
        }
        errors.sort()
        let medianError = errors.isEmpty ? .infinity : errors[errors.count / 2]
        print("true-pose reprojection median \(medianError) px over \(errors.count) observations")
        check(medianError < 0.35, "tracked positions agree with the true geometry to sub-pixel accuracy")

        // Bundle adjustment removes smooth drift.
        let result = CameraOnlyPoseRefinement.run(records: driftRecords, directory: dir)
        let truths = (0..<n).map(truth)
        let before = relativeError(driftRecords.map { RefusionEngine.float4x4(rowMajor: $0.transform) }, truths)
        let after = relativeError(result.records.map { RefusionEngine.float4x4(rowMajor: $0.transform) }, truths)
        print("status \(result.report.status), holdout \(result.report.holdoutMedianBeforePx ?? -1) -> \(result.report.holdoutMedianAfterPx ?? -1) px, 4-frame displacement error \(before * 1000) -> \(after * 1000) mm")
        check(result.report.status == "applied" && (result.report.holdoutMedianAfterPx ?? 99) < (result.report.holdoutMedianBeforePx ?? 0),
              "held-out tracks confirm the camera-only correction")
        // ARKit's frame-to-frame motion is a tight prior (0.3 mm / 0.01° per step), so the solve
        // mainly restores multi-view consistency; displacement errors must not grow.
        check((result.report.holdoutMedianAfterPx ?? 99) < (result.report.holdoutMedianBeforePx ?? 0) * 0.7 && after < before,
              "held-out reprojection improves by 30% or more without larger displacement errors")

        // True poses: nothing to fix.
        let exact = CameraOnlyPoseRefinement.run(records: truthRecords, directory: dir)
        let moved = zip(exact.records, truthRecords).map { simd_distance(center(RefusionEngine.float4x4(rowMajor: $0.transform)),
                                                                          center(RefusionEngine.float4x4(rowMajor: $1.transform))) }.max() ?? 0
        print("true input: status \(exact.report.status), max move \(moved * 1000) mm")
        check(exact.report.status != "applied" || moved < 0.003, "correct input poses are left (nearly) unchanged")

        // Deterministic.
        let again = CameraOnlyPoseRefinement.run(records: driftRecords, directory: dir)
        check(zip(again.records, result.records).allSatisfy { $0.transform == $1.transform }, "repeated runs give identical poses")

        // Blank walls: no corners, no tracks, no change.
        let blank = CameraOnlyPoseRefinement.run(records: flatRecords, directory: dir)
        check(blank.report.status != "applied" && (blank.report.tracking?.tracks ?? 1) == 0
              && zip(blank.records, flatRecords).allSatisfy { $0.transform == $1.transform },
              "untextured walls produce no tracks and keep the input poses")

        // A 2° pitch error in one frame moves every feature ~10 px across the (horizontal)
        // epipolar lines of this sideways pass. Errors along the lines, such as translation along
        // the baseline, are invisible to this check by construction.
        var jumped = truthRecords
        let jump = truth(15) * simd_float4x4(simd_quatf(angle: 2 * .pi / 180, axis: SIMD3(1, 0, 0)))
        jumped[15].transform = RefusionEngine.rowMajor(jump)
        let jumpTracks = CameraOnlyTracker.track(records: jumped, directory: dir)
        let inJump = jumpTracks.observations.filter { $0.frameID == 15 }.count
        let inNeighbor = tracked.observations.filter { $0.frameID == 15 }.count
        print("epipolar rejections \(jumpTracks.report.rejectedEpipolar), frame-15 observations \(inJump) vs \(inNeighbor)")
        check(jumpTracks.report.rejectedEpipolar > 50, "an inconsistent input pose fails the epipolar check")

        // Missing images end tracks safely.
        var missing = driftRecords
        missing[10].imageFile = "does_not_exist.png"
        let gap = CameraOnlyTracker.track(records: missing, directory: dir)
        check(gap.report.failedFrames == 1 && !gap.observations.contains { $0.frameID == 10 }, "an unreadable frame ends tracks without observations")

        // Cancellation.
        let cancelled = CameraOnlyPoseRefinement.run(records: driftRecords, directory: dir, isCancelled: { true })
        check(cancelled.report.status == "cancelled" && zip(cancelled.records, driftRecords).allSatisfy { $0.transform == $1.transform },
              "cancellation keeps the input poses")

        // Report round trip.
        let decoded = try JSONDecoder().decode(CameraOnlyPoseRefinement.Report.self, from: JSONEncoder().encode(result.report))
        check(decoded.status == result.report.status && decoded.tracking?.tracks == result.report.tracking?.tracks
              && decoded.holdoutMedianAfterPx == result.report.holdoutMedianAfterPx,
              "the refinement report encodes and decodes")
        print("\(checks) camera-only bundle checks passed")
    }
}
