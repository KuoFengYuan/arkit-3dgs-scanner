// Run using the compile command in docs/CAMERA_ONLY_ACCURACY.md.
import Foundation
import CoreGraphics
import ImageIO
import simd

@main
struct RGBReconstructionTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1; print("PASS: \(message)")
        }
        let k = CameraIntrinsics(fx: 90, fy: 90, cx: 48, cy: 36, width: 96, height: 72)
        var cfg = CaptureConfig(); cfg.rgbPixelStride = 4
        func pose(_ x: Float, yaw: Float = 0) -> simd_float4x4 {
            var p = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))); p.columns.3.x = x; return p
        }
        // Render a textured plane with known metric geometry, independent of stereo projection code.
        func render(_ camera: simd_float4x4, depth: Float = 1.5, tilted: Bool = false,
                    flat: Bool = false, stripes: Bool = false, repeated: Bool = false, gain: Float = 1) -> RGBStereoMatcher.Image {
            var data = [UInt8](); data.reserveCapacity(k.width * k.height * 4)
            for y in 0..<k.height { for x in 0..<k.width {
                let ray = camera * SIMD4<Float>((Float(x) - Float(k.cx)) / Float(k.fx),
                                                -(Float(y) - Float(k.cy)) / Float(k.fy), -1, 0)
                let origin = camera.columns.3
                let sx: Float = tilted ? 0.25 : 0, sy: Float = tilted ? -0.15 : 0
                let t = (-depth + sx * origin.x + sy * origin.y - origin.z) / (ray.z - sx * ray.x - sy * ray.y)
                let p = origin + t * ray
                let intensity: Float
                if flat { intensity = 0.5 }
                else if stripes { intensity = 0.5 + 0.35 * sin(p.x * 70) }
                else if repeated { intensity = 0.5 + 0.2 * sin(p.x * 125.6637) + 0.2 * sin(p.y * 125.6637) }
                else {
                    intensity = 0.5 + 0.12 * sin(p.x * 71 + p.y * 37)
                        + 0.11 * cos(p.x * 33 - p.y * 83) + 0.1 * sin(p.x * 117 + p.y * 19)
                        + 0.1 * cos(p.x * 51 + p.y * 109)
                }
                let value = UInt8(max(0, min(255, intensity * gain * 255)))
                data += [value, value, value, 255]
            } }
            return RGBStereoMatcher.Image(intrinsics: k, c2w: camera, rgba: data)!
        }
        let reference = render(pose(0)), left = render(pose(-0.12)), right = render(pose(0.12), gain: 0.85)
        let started = Date()
        let points = RGBStereoMatcher.reconstruct(reference: reference, sources: [left, right], config: cfg)
        let errors = points.map { abs($0.z + 1.5) }.sorted()
        print("plane points=\(points.count), median=\(errors.isEmpty ? -1 : errors[errors.count/2]), elapsed=\(Date().timeIntervalSince(started))")
        check(points.count > 60, "three translated RGB views reconstruct a textured plane")
        check(errors[errors.count / 2] < 0.015 && errors[Int(Double(errors.count - 1) * 0.95)] < 0.04,
              "known 1.5 m plane: median depth error < 1.5 cm and p95 < 4 cm")
        check(RGBStereoMatcher.reconstruct(reference: reference, sources: [reference, reference], config: cfg).isEmpty,
              "identical cameras never fabricate depth")
        let rotationOnly = [render(pose(0, yaw: -0.1)), render(pose(0, yaw: 0.1))]
        check(RGBStereoMatcher.reconstruct(reference: reference, sources: rotationOnly, config: cfg).isEmpty,
              "pure rotation lacks triangulation baseline")
        check(RGBStereoMatcher.reconstruct(reference: render(pose(0), flat: true),
              sources: [render(pose(-0.12), flat: true), render(pose(0.12), flat: true)], config: cfg).isEmpty,
              "blank walls do not acquire invented geometry")
        check(RGBStereoMatcher.reconstruct(reference: render(pose(0), stripes: true),
              sources: [render(pose(-0.12), stripes: true), render(pose(0.12), stripes: true)], config: cfg).isEmpty,
              "single-direction repeating stripes fail texture conditioning")
        let repeated = RGBStereoMatcher.reconstruct(reference: render(pose(0), repeated: true),
              sources: [render(pose(-0.12), repeated: true), render(pose(0.12), repeated: true)], config: cfg)
        check(repeated.count < points.count / 10, "two-dimensional repeated texture fails match uniqueness")
        var occludedBytes = right.rgba
        for y in 0..<right.height { for x in 0..<(right.width / 2) {
            let i = (y * right.width + x) * 4
            occludedBytes[i] = 127; occludedBytes[i+1] = 127; occludedBytes[i+2] = 127
        } }
        let occluded = RGBStereoMatcher.Image(intrinsics: k, c2w: right.c2w, rgba: occludedBytes)!
        let visible = RGBStereoMatcher.reconstruct(reference: reference, sources: [left, occluded], config: cfg)
        check(!visible.isEmpty && visible.allSatisfy { point in
            guard let p = right.project(SIMD3(point.x, point.y, point.z)) else { return false }
            return p.pixel.x >= Float(right.width / 2)
        }, "third-view occlusion removes unsupported points while keeping visible surfaces")
        let inconsistent = RGBStereoMatcher.reconstruct(reference: reference,
              sources: [left, render(pose(0.12), depth: 2.2)], config: cfg)
        check(inconsistent.count < points.count / 10, "inconsistent third-view geometry is rejected")
        let tilted = RGBStereoMatcher.reconstruct(reference: render(pose(0), tilted: true),
              sources: [render(pose(-0.12, yaw: -0.025), tilted: true), render(pose(0.12, yaw: 0.025), tilted: true)], config: cfg)
        let tiltedErrors = tilted.map { abs($0.z + 1.5 - 0.25 * $0.x + 0.15 * $0.y) }.sorted()
        print("tilted points=\(tilted.count), median=\(tiltedErrors.isEmpty ? -1 : tiltedErrors[tiltedErrors.count/2])")
        check(tilted.count > 30 && tiltedErrors[tiltedErrors.count / 2] < 0.025,
              "rotated cameras reconstruct a slanted plane with < 2.5 cm median plane residual")

        let again = RGBStereoMatcher.reconstruct(reference: reference, sources: [left, right], config: cfg)
        check(again.count == points.count && zip(again, points).allSatisfy { $0.x == $1.x && $0.y == $1.y && $0.z == $1.z },
              "concurrent depth maps give identical points on every run")
        let behind = render(pose(0.06, yaw: .pi))
        let nearDuplicate = render(pose(0.125))
        let wide = render(pose(0.24))
        var selectionConfig = cfg; selectionConfig.rgbSourceViews = 2
        let selected = RGBReconstructionEngine.selectSources([reference, left, right, behind, nearDuplicate, wide], config: selectionConfig)
        check(!selected[0].contains(3) && selected[0].count == 2 && Set(selected[0]).isSubset(of: [1, 2, 4, 5]),
              "sources exclude opposite-facing views and respect the per-view budget")
        check(!(selected[0].contains(2) && selected[0].contains(4)), "near-duplicate camera positions are not both chosen as sources")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fable-rgb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ image: RGBStereoMatcher.Image, name: String, jpeg: Bool = false) throws {
            let provider = CGDataProvider(data: Data(image.rgba) as CFData)!
            let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let destination = CGImageDestinationCreateWithURL(dir.appendingPathComponent("images/\(name)") as CFURL, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            check(CGImageDestinationFinalize(destination), "test image writes successfully")
        }
        var records = [FrameRecord]()
        for (i, image) in [left, reference, right].enumerated() {
            let name = "frame_\(i).png"; try write(image, name: name)
            records.append(FrameRecord(id: i, timestamp: Double(i), transform: RefusionEngine.rowMajor(image.c2w),
                                       intrinsics: k, exposureDuration: 0.005, exposureOffsetEV: 0,
                                       estimatedBlurPx: 0, imageFile: name))
        }
        let decoded = RGBReconstructionEngine.load(record: records[1], sessionDir: dir, maxDimension: 256)!
        check(zip(decoded.rgba, reference.rgba).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
              "disk decoding preserves sensor image row orientation and colors")
        var enlarged = [UInt8]()
        for y in 0..<(reference.height * 2) { for x in 0..<(reference.width * 2) {
            let i = ((y / 2) * reference.width + x / 2) * 4
            enlarged.append(contentsOf: reference.rgba[i..<(i + 4)])
        } }
        let largeK = k.scaled(toWidth: k.width * 2, height: k.height * 2)
        let large = RGBStereoMatcher.Image(intrinsics: largeK, c2w: reference.c2w, rgba: enlarged)!
        try write(large, name: "large.jpg", jpeg: true)
        var largeRecord = records[1]; largeRecord.intrinsics = largeK; largeRecord.imageFile = "large.jpg"
        let small = RGBReconstructionEngine.load(record: largeRecord, sessionDir: dir, maxDimension: 96)!
        check(small.width == k.width && small.height == k.height && small.intrinsics.fx == k.fx && small.intrinsics.cy == k.cy,
              "JPEG downsampling scales calibration with image dimensions")
        let jpegPoints = RGBStereoMatcher.reconstruct(reference: small, sources: [left, right], config: cfg)
        let jpegErrors = jpegPoints.map { abs($0.z + 1.5) }.sorted()
        check(jpegPoints.count > 30 && jpegErrors[jpegErrors.count / 2] < 0.02,
              "JPEG and resizing preserve known plane geometry")
        var capped = cfg; capped.rgbMaxReferenceFrames = 1
        let result = RGBReconstructionEngine.reconstruct(records: records, sessionDir: dir, config: capped)
        check(result.points.count > 30 && result.report.status == "reconstructed", "disk pipeline reconstructs and voxel-fuses RGB geometry")
        check(result.report.attemptedReferences == 3 && result.report.decodedImages == 3,
              "a budget below three views still decodes the minimum three, each matched against the others")
        let report = try JSONDecoder().decode(RGBReconstructionEngine.Report.self, from: JSONEncoder().encode(result.report))
        check(report.outputPoints == result.points.count && report.method == "known-pose-patchmatch-mvs", "report preserves RGB provenance and output statistics")
        check((report.texturedPixels ?? 0) >= (report.photoConsistentPixels ?? 0)
              && (report.photoConsistentPixels ?? 0) >= (report.geometricallyConsistentPixels ?? 0)
              && (report.geometricallyConsistentPixels ?? 0) == report.acceptedObservations && report.acceptedObservations > 0,
              "report funnel: textured ≥ photo-consistent ≥ multi-view consistent observations")
        let seed = CloudPoint(x: 0, y: 0, z: -1.5, r: 200, g: 100, b: 50)
        let nearby = CloudPoint(x: 0.001, y: 0, z: -1.5, r: 0, g: 0, b: 0)
        let far = CloudPoint(x: 2, y: 0, z: -1.5, r: 30, g: 40, b: 50)
        let mixed = RGBReconstructionEngine.supplement(rgb: [seed], sparse: [nearby, far], config: cfg)
        check(mixed.count == 2 && mixed[0].r == 200 && mixed[1].x == 2,
              "RGB surfaces keep priority while sparse points preserve unsampled coverage")
        check(RGBReconstructionEngine.supplement(rgb: [], sparse: [far], config: cfg).count == 1,
              "failed image reconstruction preserves the sparse fallback")
        var malformedK = records[1]; malformedK.intrinsics.width += 1
        check(RGBReconstructionEngine.load(record: malformedK, sessionDir: dir, maxDimension: 256) == nil,
              "image and calibration dimensions must agree")
        let oldMeta = Data(#"{"device":"test","osVersion":"test","startedAt":"test","mode":"scene","app":"fable-gs-capture","version":1,"worldAlignment":"gravity","cameraConvention":"arkit_gl_c2w_row_major","imageOrientation":"sensor_landscape_right","depthFormat":"float32_raw_little_endian","lidarAvailable":false}"#.utf8)
        check(try JSONDecoder().decode(SessionMeta.self, from: oldMeta).rgbReconstructionEnabled == nil,
              "legacy metadata remains readable without the RGB option")
        var invalid = records; invalid[1].transform = [0]
        check(RGBReconstructionEngine.reconstruct(records: invalid, sessionDir: dir, config: cfg).points.isEmpty,
              "malformed poses are skipped safely")
        var dropped = records; dropped[1].blurVerdict = .drop
        check(RGBReconstructionEngine.reconstruct(records: dropped, sessionDir: dir, config: cfg).points.isEmpty,
              "blur-rejected frames cannot support reconstructed depth")
        var demoted = records; demoted[1].blurVerdict = .demote
        check(RGBReconstructionEngine.reconstruct(records: demoted, sessionDir: dir, config: cfg).points.isEmpty,
              "appearance-demoted frames cannot support reconstructed depth")
        check(RGBReconstructionEngine.reconstruct(records: Array(repeating: records[0], count: 3), sessionDir: dir, config: cfg).points.isEmpty,
              "duplicate frame IDs/images cannot imitate three independent views")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("images/\(records[1].imageFile)"))
        let missing = RGBReconstructionEngine.reconstruct(records: records, sessionDir: dir, config: capped)
        check(missing.points.isEmpty && missing.report.failedImageLoads == 1, "missing images produce a report and safe sparse fallback")
        print("\(checks) checks passed")
    }
}
