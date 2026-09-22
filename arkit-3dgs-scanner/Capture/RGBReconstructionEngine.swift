import Foundation
import CoreGraphics
import ImageIO
import simd

/// Bounded CPU multi-view stereo using saved RGB frames and corrected ARKit poses.
/// It estimates geometry; it does not modify poses or create measured-depth sidecars.
nonisolated enum RGBReconstructionEngine {
    struct Report: Codable, Sendable {
        var version = 1
        var method = "known-pose-rgb-patch-stereo"
        var status = "insufficientViews"
        var eligibleFrames = 0
        var attemptedReferences = 0
        var contributingReferences = 0
        var decodedImages = 0
        var failedImageLoads = 0
        var acceptedObservations = 0
        var outputPoints = 0
        var reviewPointsIncludingSparse = 0
        var referenceFrameIDs: [Int] = []
        var maxImageDimension: Int
        var pixelStride: Int
        var maxReferenceFrames: Int
        var seconds: Double = 0
    }
    struct Result: Sendable { var points: [CloudPoint]; var report: Report }

    static func reconstruct(records: [FrameRecord], sessionDir: URL, config: CaptureConfig,
                            progress: @Sendable (Double) -> Void = { _ in }) -> Result {
        let start = Date()
        var report = Report(maxImageDimension: config.rgbMaxImageDimension, pixelStride: config.rgbPixelStride,
                            maxReferenceFrames: config.rgbMaxReferenceFrames)
        // Reject malformed/non-rigid poses before inversion and never match a duplicated camera/image.
        var imagesSeen = Set<String>(), idsSeen = Set<Int>()
        let frames = records.filter { record in
            guard record.blurVerdict == .keep, record.transform.count == 16,
                  record.transform.allSatisfy(\.isFinite), record.timestamp.isFinite,
                  record.intrinsics.width > 0, record.intrinsics.height > 0,
                  record.intrinsics.fx.isFinite, record.intrinsics.fx > 0,
                  record.intrinsics.fy.isFinite, record.intrinsics.fy > 0,
                  record.intrinsics.cx.isFinite, record.intrinsics.cy.isFinite,
                  URL(fileURLWithPath: record.imageFile).lastPathComponent == record.imageFile,
                  !imagesSeen.contains(record.imageFile), !idsSeen.contains(record.id) else { return false }
            let pose = RefusionEngine.float4x4(rowMajor: record.transform)
            let rotation = simd_float3x3(SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z),
                                         SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z),
                                         SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
            let gram = rotation.transpose * rotation
            guard abs(simd_determinant(rotation) - 1) < 0.01,
                  simd_length(gram.columns.0 - SIMD3(1, 0, 0)) < 0.01,
                  simd_length(gram.columns.1 - SIMD3(0, 1, 0)) < 0.01,
                  simd_length(gram.columns.2 - SIMD3(0, 0, 1)) < 0.01,
                  abs(pose.columns.0.w) + abs(pose.columns.1.w) + abs(pose.columns.2.w) + abs(pose.columns.3.w - 1) < 0.001 else { return false }
            imagesSeen.insert(record.imageFile); idsSeen.insert(record.id)
            return true
        }.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        report.eligibleFrames = frames.count
        guard frames.count >= 3 else { progress(1); return Result(points: [], report: report) }
        let poses = frames.map { RefusionEngine.float4x4(rowMajor: $0.transform) }
        func center(_ i: Int) -> SIMD3<Float> { SIMD3(poses[i].columns.3.x, poses[i].columns.3.y, poses[i].columns.3.z) }
        func forward(_ i: Int) -> SIMD3<Float> { -SIMD3(poses[i].columns.2.x, poses[i].columns.2.y, poses[i].columns.2.z) }
        let count = min(frames.count, max(1, config.rgbMaxReferenceFrames))
        let references = (0..<count).map { count == 1 ? 0 : $0 * (frames.count - 1) / (count - 1) }
        var grid = FusedVoxelGrid(voxelSize: config.refuseVoxelSizeM, maxCells: config.exportMaxPoints)
        for (index, referenceIndex) in references.enumerated() {
            // Full sequence remains available for neighbors even when reference frames are subsampled.
            // Prefer moderate baselines; large translations and rotations lose patch overlap.
            let neighbors = frames.indices.filter { i in
                let baseline = simd_distance(center(i), center(referenceIndex))
                return i != referenceIndex && baseline >= config.cameraOnlyMinBaselineM && baseline <= 0.3
                    && simd_dot(forward(i), forward(referenceIndex)) > 0.94
            }.sorted { a, b in
                let da = abs(simd_distance(center(a), center(referenceIndex)) - 0.12)
                let db = abs(simd_distance(center(b), center(referenceIndex)) - 0.12)
                return da == db ? a < b : da < db
            }
            if let first = neighbors.first,
               let second = neighbors.dropFirst().first(where: { simd_distance(center($0), center(first)) >= config.cameraOnlyMinBaselineM }) {
                report.attemptedReferences += 1
                // Only three small images are resident; no full-scan image cache or dense cost volume.
                let decoded = [referenceIndex, first, second].compactMap { i -> RGBStereoMatcher.Image? in
                    guard let image = load(record: frames[i], sessionDir: sessionDir, maxDimension: config.rgbMaxImageDimension) else {
                        report.failedImageLoads += 1; return nil
                    }
                    report.decodedImages += 1
                    return image
                }
                if decoded.count == 3 {
                    let points = RGBStereoMatcher.reconstruct(reference: decoded[0], sources: Array(decoded.dropFirst()), config: config)
                    if !points.isEmpty {
                        report.contributingReferences += 1
                        report.referenceFrameIDs.append(frames[referenceIndex].id)
                        report.acceptedObservations += points.count
                        grid.insert(points, measured: false)
                    }
                }
            }
            progress(Double(index + 1) / Double(references.count))
        }
        let points = grid.exportPoints(target: config.exportMaxPoints, minNeighbors: 0)
        report.outputPoints = points.count
        report.status = points.isEmpty ? (report.attemptedReferences == 0 ? "insufficientBaseline" : "noReliableMatches") : "reconstructed"
        report.seconds = Date().timeIntervalSince(start)
        return Result(points: points, report: report)
    }

    /// Preserve sparse coverage outside the sampled RGB surfaces. RGB owns its nearby voxels,
    /// so repeated sparse estimates cannot pull a reconstructed surface away from its image matches.
    static func supplement(rgb: [CloudPoint], sparse: [CloudPoint], config: CaptureConfig) -> [CloudPoint] {
        guard !rgb.isEmpty else { return sparse }
        let size = config.refuseVoxelSizeM
        let occupied = Set(rgb.compactMap { PointCloudMath.voxelKey(SIMD3($0.x, $0.y, $0.z), size: size) })
        var result = rgb
        for point in sparse {
            let position = SIMD3(point.x, point.y, point.z)
            guard PointCloudMath.voxelKey(position, size: size) != nil else { continue }
            var nearRGB = false
            for z in -1...1 { for y in -1...1 { for x in -1...1 {
                let neighbor = position + SIMD3(Float(x), Float(y), Float(z)) * size
                if let key = PointCloudMath.voxelKey(neighbor, size: size), occupied.contains(key) { nearRGB = true }
            } } }
            if !nearRGB { result.append(point) }
        }
        return result.count > config.exportMaxPoints
            ? PointCloudMath.stratifiedBest(result, startCell: size, target: config.exportMaxPoints) : result
    }

    static func load(record: FrameRecord, sessionDir: URL, maxDimension: Int) -> RGBStereoMatcher.Image? {
        let k = record.intrinsics
        guard k.width > 0, k.height > 0, record.transform.count == 16 else { return nil }
        let scale = min(1, Double(max(32, min(512, maxDimension))) / Double(max(k.width, k.height)))
        let w = max(8, Int(Double(k.width) * scale)), h = max(8, Int(Double(k.height) * scale))
        let url = sessionDir.appendingPathComponent("images").appendingPathComponent(record.imageFile)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let originalW = properties[kCGImagePropertyPixelWidth] as? Int,
              let originalH = properties[kCGImagePropertyPixelHeight] as? Int,
              originalW == k.width, originalH == k.height else { return nil }
        // No EXIF rotation: intrinsics describe the saved sensor-oriented JPEG.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return RGBStereoMatcher.Image(intrinsics: k.scaled(toWidth: w, height: h),
                                      c2w: RefusionEngine.float4x4(rowMajor: record.transform), rgba: rgba)
    }
}
