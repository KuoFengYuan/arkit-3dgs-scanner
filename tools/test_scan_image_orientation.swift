import Foundation
import ImageIO
import CoreGraphics
import simd

@main struct ScanImageOrientationTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1; print("PASS: \(message)") }
        func roll(_ angle: Float) -> simd_float4x4 {
            simd_float4x4(simd_quatf(angle: angle, axis: SIMD3(0,0,1)))
        }
        check(ScanImageOrientation.upright(pose: roll(0)) == .up, "upright landscape remains unrotated")
        check(ScanImageOrientation.upright(pose: roll(-.pi/2)) == .right, "portrait sensor image rotates clockwise")
        check(ScanImageOrientation.upright(pose: roll(.pi/2)) == .left, "opposite portrait rotates counterclockwise")
        check(ScanImageOrientation.upright(pose: roll(.pi)) == .down, "inverted landscape rotates 180 degrees")
        check(ScanImageOrientation.upright(pose: nil) == .right, "legacy missing pose uses portrait fallback")
        let down = simd_float4x4(simd_quatf(angle: .pi/2, axis: SIMD3(1,0,0)))
        check(ScanImageOrientation.upright(pose: down) == .right, "near-vertical viewing direction has a stable fallback")
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("fable-image-orientation-\(UUID().uuidString)")
        let images = directory.appendingPathComponent("images")
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let pixels = Data(repeating: 128, count: 80 * 40 * 4)
        let cg = CGImage(width: 80, height: 40, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        func write(_ orientation: CGImagePropertyOrientation, to url: URL) {
            let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, cg, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
            precondition(CGImageDestinationFinalize(dst))
        }
        func decoded(_ data: Data) -> CGImage {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            return CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: 100] as CFDictionary)!
        }
        let url = images.appendingPathComponent("frame.jpg")
        write(.up, to: url)
        let original = try Data(contentsOf: url)
        let rotated = decoded(ScanLibrary.imageData(url, maxDimension: 100, orientation: .right)!)
        check(rotated.width == 40 && rotated.height == 80, "thumbnail orientation produces portrait display dimensions")
        check(try Data(contentsOf: url) == original, "preview generation leaves training JPEG bytes unchanged")
        let record = FrameRecord(id: 1, timestamp: 1, transform: RefusionEngine.rowMajor(roll(-.pi/2)),
            intrinsics: CameraIntrinsics(fx: 50, fy: 50, cx: 40, cy: 20, width: 80, height: 40),
            exposureDuration: 0.01, exposureOffsetEV: 0, estimatedBlurPx: 0, imageFile: "frame.jpg")
        try ExportManager.writeRefinedPoses([record], to: directory.appendingPathComponent("poses.jsonl"))
        let cover = decoded(ScanLibrary.imageData(url, maxDimension: 100)!)
        check(cover.width == 40 && cover.height == 80, "history cover resolves existing scan pose without migration")
        write(.right, to: url)
        let exif = decoded(ScanLibrary.imageData(url, maxDimension: 100, orientation: .left)!)
        check(exif.width == 40 && exif.height == 80, "embedded EXIF orientation is applied once without double rotation")

        // Optional real-frame verification; output a display-normalized PNG for visual QA.
        if CommandLine.arguments.count == 4 {
            let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let records = ScanLibrary.readRecords(URL(fileURLWithPath: CommandLine.arguments[2]))
            let frame = ScanLibrary.playbackFrames(images: [imageURL], records: records)[0]
            let before = try Data(contentsOf: imageURL)
            let data = ScanLibrary.imageData(imageURL, maxDimension: 960, orientation: frame.imageOrientation)!
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let result = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: 960] as CFDictionary)!
            let output = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[3]) as CFURL,
                                                         "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(output, result, nil)
            precondition(CGImageDestinationFinalize(output))
            let after = try Data(contentsOf: imageURL)
            check(result.height > result.width && after == before,
                  "reported real frame becomes portrait while original pixels remain unchanged")
        }
        print("\(count) checks passed")
    }
}
