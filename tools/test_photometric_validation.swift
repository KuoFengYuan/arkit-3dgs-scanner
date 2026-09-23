// Photo-alignment gate for pose refinement, on a rendered textured wall with exact depth.
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,TrainingFrameSelector,PhotometricPoseValidator}.swift \
//   tools/test_photometric_validation.swift -o /tmp/fable-photometric-test
import Foundation
import simd
import CoreGraphics
import ImageIO

@main struct PhotometricValidationTests {
    static let width = 480, height = 360, depthWidth = 256, depthHeight = 192
    static let K = CameraIntrinsics(fx: 400, fy: 400, cx: 240, cy: 180, width: width, height: height)
    static let wallZ: Float = -2

    /// Two-directional texture so shifts in any image direction change intensities.
    static func texture(_ x: Float, _ y: Float) -> Float {
        128 + 45 * sin(7 * x) * cos(5 * y) + 30 * sin(23 * x + 3 * y) + 25 * cos(31 * y - 11 * x)
            + 18 * sin(97 * x) * sin(89 * y)
    }

    static func pose(x: Float, yawDeg: Float) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yawDeg * .pi / 180, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(x, 0, 0, 1)
        return m
    }

    static func render(_ c2w: simd_float4x4, name: String, directory: URL) throws {
        let R = simd_float3x3(SIMD3(c2w.columns.0.x, c2w.columns.0.y, c2w.columns.0.z),
                              SIMD3(c2w.columns.1.x, c2w.columns.1.y, c2w.columns.1.z),
                              SIMD3(c2w.columns.2.x, c2w.columns.2.y, c2w.columns.2.z))
        let c = SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z)
        func hit(_ u: Float, _ v: Float, _ k: CameraIntrinsics) -> (SIMD3<Float>, Float) {
            let ray = R * SIMD3((u - Float(k.cx)) / Float(k.fx), -(v - Float(k.cy)) / Float(k.fy), -1)
            let t = (wallZ - c.z) / ray.z
            return (c + ray * t, t)
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

    static func record(_ id: Int, _ c2w: simd_float4x4) -> FrameRecord {
        let name = String(format: "frame_%05d", id)
        return FrameRecord(id: id, timestamp: Double(id) * 0.4, transform: RefusionEngine.rowMajor(c2w), intrinsics: K,
                           exposureDuration: 0.005, exposureOffsetEV: 0, estimatedBlurPx: 0,
                           imageFile: name + ".jpg", depthFile: name + "_depth.bin", confidenceFile: name + "_conf.bin",
                           depthWidth: depthWidth, depthHeight: depthHeight)
    }

    static func moved(_ records: [FrameRecord], _ change: (Int, simd_float4x4) -> simd_float4x4) -> [FrameRecord] {
        records.enumerated().map { i, r in
            var out = r
            out.transform = RefusionEngine.rowMajor(change(i, RefusionEngine.float4x4(rowMajor: r.transform)))
            return out
        }
    }

    static func correction(_ m: simd_float4x4, omega: SIMD3<Float>, shift: SIMD3<Float>) -> simd_float4x4 {
        let c = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let angle = simd_length(omega)
        var r = matrix_identity_float4x4
        if angle > 0 { r = simd_float4x4(simd_quatf(angle: angle, axis: omega / angle)) }
        var t = matrix_identity_float4x4; t.columns.3 = SIMD4(c + shift, 1)
        var back = matrix_identity_float4x4; back.columns.3 = SIMD4(-c, 1)
        return t * r * back * m
    }

    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1; print("PASS: \(message)")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fable-photometric-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("depth"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // 30 keyframes 5 cm apart, 0.4 s apart, gently turning: adjacent and wide-baseline pairs.
        let truth = (0..<30).map { pose(x: Float($0) * 0.05, yawDeg: 3 * sin(Float($0) * 0.3)) }
        for (i, m) in truth.enumerated() { try render(m, name: String(format: "frame_%05d", i), directory: dir) }
        let exact = truth.enumerated().map { record($0.offset, $0.element) }

        // ARKit-like input: accurate local motion with accumulated drift.
        let drifted = moved(exact) { i, m in
            let f = Float(i) / 29
            return correction(m, omega: SIMD3(0.2, 1, 0) * (f * 0.8 * .pi / 180), shift: SIMD3(0.004, 0.003, 0.02) * f)
        }
        let fixed = PhotometricPoseValidator.evaluate(input: drifted, candidate: exact, directory: dir)
        check(fixed.status == "accepted" && (fixed.wideDelta ?? 0) > PhotometricPoseValidator.requiredWideGain
                && (fixed.adjacentDelta ?? -1) >= -PhotometricPoseValidator.adjacentTolerance,
              String(format: "correcting drift is accepted: wide NCC %+.4f, adjacent %+.4f over %d/%d pairs",
                     fixed.wideDelta ?? 0, fixed.adjacentDelta ?? 0, fixed.widePairs, fixed.adjacentPairs))
        check(fixed.widePairs >= PhotometricPoseValidator.minimumPairs && fixed.adjacentPairs >= PhotometricPoseValidator.minimumPairs,
              "pairs cover both adjacent and wide-baseline views")

        var seed: UInt64 = 7
        func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) - 0.5 }
        let jittered = moved(exact) { _, m in
            correction(m, omega: SIMD3(rnd(), rnd(), rnd()) * (0.6 * .pi / 180), shift: SIMD3(rnd(), rnd(), rnd()) * 0.01)
        }
        let jitter = PhotometricPoseValidator.evaluate(input: exact, candidate: jittered, directory: dir)
        check(jitter.status == "rejected" && (jitter.adjacentDelta ?? 0) < -PhotometricPoseValidator.adjacentTolerance,
              String(format: "per-frame jitter is rejected: adjacent NCC %+.4f, %d pairs worse",
                     jitter.adjacentDelta ?? 0, jitter.adjacentWorse))

        let fewMoved = moved(exact) { i, m in
            [8, 16, 24].contains(i) ? correction(m, omega: SIMD3(0, 0, 1) * (0.8 * .pi / 180), shift: SIMD3(0.012, -0.01, 0)) : m
        }
        let sparse = PhotometricPoseValidator.evaluate(input: exact, candidate: fewMoved, directory: dir)
        check(sparse.status != "accepted" && sparse.adjacentPairs <= 6 && (sparse.adjacentDelta ?? 0) < 0,
              String(format: "only pairs touching the 3 moved frames are scored (%d adjacent, median %+.4f)",
                     sparse.adjacentPairs, sparse.adjacentDelta ?? 0))

        check(PhotometricPoseValidator.evaluate(input: exact, candidate: exact, directory: dir).status == "unchanged",
              "unchanged poses are never reported as an improvement")
        let short = Array(exact.prefix(4)), shortMoved = Array(drifted.prefix(4))
        check(PhotometricPoseValidator.evaluate(input: shortMoved, candidate: short, directory: dir).status == "insufficientPairs",
              "too few overlapping photos cannot confirm a correction")
        var polls = 0
        check(PhotometricPoseValidator.evaluate(input: drifted, candidate: exact, directory: dir,
                                                isCancelled: { polls += 1; return polls > 2 }).status == "cancelled",
              "validation stops on cancellation")
        let missing = drifted.map { r -> FrameRecord in var out = r; out.imageFile = "missing.jpg"; return out }
        check(PhotometricPoseValidator.evaluate(input: missing, candidate: exact, directory: dir).status == "insufficientPairs",
              "missing photos are unscored rather than trusted")
        let invisible = moved(exact) { i, m in
            correction(m,omega:.zero,shift:i % 2 == 0 ? SIMD3(0,0,1) : .zero)
        }
        let lost = PhotometricPoseValidator.evaluate(input:exact,candidate:invisible,directory:dir)
        check(lost.status == "rejected" && (lost.lowRetentionPairs ?? 0) > 0
                && (lost.minimumRetainedFraction ?? 1) < 0.9,
              "moving difficult projections out of depth agreement is rejected, never silently unscored")
        check((fixed.baselineSamples ?? 0) >= (fixed.retainedSamples ?? 0)
                && (fixed.retainedSamples ?? 0) > 0 && fixed.lowRetentionPairs == 0,
              "correct drift retains sufficient baseline-valid samples")
        check((fixed.wideEffectiveDelta ?? 1) <= (fixed.wideDelta ?? 0),
              "lost samples carry a penalty even below the rejection threshold")
        let oldReport = Data(#"{"status":"accepted","adjacentPairs":8,"widePairs":8,"adjacentWorse":0,"seconds":1}"#.utf8)
        let decoded = try JSONDecoder().decode(PhotometricPoseValidator.Report.self,from:oldReport)
        check(decoded.accepted && decoded.baselineSamples == nil,"older photo reports remain readable")
        print("\(checks) photometric validation checks passed")
    }
}
