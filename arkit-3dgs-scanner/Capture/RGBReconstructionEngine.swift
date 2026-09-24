import Foundation
import CoreGraphics
import ImageIO
import simd

/// Bounded CPU multi-view stereo using saved RGB frames and corrected ARKit poses.
/// It estimates geometry; it does not modify poses or create measured-depth sidecars.
///
/// Up to `rgbMaxReferenceFrames` frames are decoded once at `rgbMaxImageDimension`. Each gets
/// sources chosen by triangulation geometry and a PatchMatch depth map (`RGBStereoMatcher`);
/// depths confirmed by neighbouring maps are fused into the voxel grid.
nonisolated enum RGBReconstructionEngine {
    struct Report: Codable, Sendable {
        var version = 2
        var method = "known-pose-patchmatch-mvs"
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
        var sourceViews: Int?
        var iterations: Int?
        /// Depth-map pixels with enough texture, passing the photo check, and confirmed by
        /// neighbouring depth maps.
        var texturedPixels: Int?
        var photoConsistentPixels: Int?
        var geometricallyConsistentPixels: Int?
        var seconds: Double = 0
    }
    struct Result: Sendable { var points: [CloudPoint]; var report: Report }

    static func reconstruct(records: [FrameRecord], sessionDir: URL, config: CaptureConfig,
                            progress: @Sendable (Double) -> Void = { _ in },
                            isCancelled: @Sendable () -> Bool = { false }) -> Result {
        let start = Date()
        var report = Report(maxImageDimension: config.rgbMaxImageDimension, pixelStride: config.rgbPixelStride,
                            maxReferenceFrames: config.rgbMaxReferenceFrames)
        report.sourceViews = config.rgbSourceViews
        report.iterations = config.rgbPatchMatchIterations
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
        guard frames.count >= 3 else { progress(1); return finish(report, points: [], start: start) }

        // The shutter already spaces frames by motion, so even index spacing covers the path.
        let count = min(frames.count, max(3, config.rgbMaxReferenceFrames))
        let chosen = Array(Set((0..<count).map { $0 * (frames.count - 1) / (count - 1) })).sorted()
        let slots = RGBStereoMatcher.Slots<RGBStereoMatcher.Image?>(repeating: nil, count: chosen.count)
        DispatchQueue.concurrentPerform(iterations: chosen.count) { i in
            guard !isCancelled() else { return }
            slots.set(i, load(record: frames[chosen[i]], sessionDir: sessionDir, maxDimension: config.rgbMaxImageDimension))
        }
        let decoded = slots.values
        report.decodedImages = decoded.compactMap { $0 }.count
        report.failedImageLoads = isCancelled() ? 0 : chosen.count - report.decodedImages
        progress(0.1)
        let loaded = chosen.indices.filter { decoded[$0] != nil }
        let views = loaded.map { decoded[$0]! }
        let ids = loaded.map { frames[chosen[$0]].id }
        guard views.count >= 3, !isCancelled() else { progress(1); return finish(report, points: [], start: start) }

        let sources = selectSources(views, config: config)
        report.attemptedReferences = sources.filter { $0.count >= 2 }.count
        guard report.attemptedReferences > 0 else {
            report.status = "insufficientBaseline"; progress(1)
            return finish(report, points: [], start: start, status: "insufficientBaseline")
        }
        let result = RGBStereoMatcher.reconstruct(views: views, sources: sources, config: config,
                                                  seeds: ids.map { UInt64(bitPattern: Int64($0)) &+ 1 },
                                                  isCancelled: isCancelled,
                                                  progress: { progress(0.1 + $0 * 0.85) })
        report.texturedPixels = result.statistics.texturedPixels
        report.photoConsistentPixels = result.statistics.photoConsistentPixels
        report.geometricallyConsistentPixels = result.statistics.geometricallyConsistentPixels
        var grid = FusedVoxelGrid(voxelSize: config.refuseVoxelSizeM, maxCells: config.exportMaxPoints)
        for (i, points) in result.points.enumerated() where !points.isEmpty {
            report.contributingReferences += 1
            report.referenceFrameIDs.append(ids[i])
            report.acceptedObservations += points.count
            grid.insert(points, measured: false)
        }
        let points = isCancelled() ? [] : grid.exportPoints(target: config.exportMaxPoints, minNeighbors: 0)
        progress(1)
        return finish(report, points: points, start: start,
                      status: points.isEmpty ? "noReliableMatches" : "reconstructed")
    }

    private static func finish(_ report: Report, points: [CloudPoint], start: Date,
                               status: String = "insufficientViews") -> Result {
        var report = report
        report.outputPoints = points.count
        report.status = status
        report.seconds = Date().timeIntervalSince(start)
        return Result(points: points, report: report)
    }

    /// Up to `rgbSourceViews` sources per view. Candidates must share the viewing direction
    /// (within 45°) and see sample points of the reference at typical indoor depths with a useful
    /// triangulation angle (weight rises from 1° to 5°, stays flat to 25°, falls to 0 at 45°).
    /// Near-duplicate camera positions are skipped so the sources span different baselines.
    static func selectSources(_ views: [RGBStereoMatcher.Image], config: CaptureConfig) -> [[Int]] {
        func weight(_ degrees: Float) -> Float {
            if degrees < 1 || degrees > 45 { return 0 }
            if degrees < 5 { return (degrees - 1) / 4 }
            return degrees <= 25 ? 1 : (45 - degrees) / 20
        }
        let depths: [Float] = [0.7, 1.4, 2.8]
        return views.indices.map { r -> [Int] in
            let reference = views[r]
            var samples = [SIMD3<Float>]()
            for gy in 0..<3 { for gx in 0..<4 {
                let pixel = SIMD2(Float(reference.width) * (Float(gx) + 0.5) / 4,
                                  Float(reference.height) * (Float(gy) + 0.5) / 3)
                for depth in depths { samples.append(reference.world(pixel, depth: depth)) }
            } }
            var scored = [(index: Int, score: Float)]()
            for s in views.indices where s != r {
                let source = views[s]
                guard simd_distance(source.center, reference.center) >= config.cameraOnlyMinBaselineM,
                      simd_dot(source.forward, reference.forward) >= 0.707 else { continue }
                var score: Float = 0
                for point in samples where source.project(point) != nil {
                    let a = simd_normalize(point - reference.center), b = simd_normalize(point - source.center)
                    score += weight(acos(max(-1, min(1, simd_dot(a, b)))) * 180 / .pi)
                }
                if score > 0 { scored.append((s, score)) }
            }
            var chosen = [Int]()
            for candidate in scored.sorted(by: { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }) {
                guard chosen.count < max(2, config.rgbSourceViews) else { break }
                let center = views[candidate.index].center
                if chosen.contains(where: { simd_distance(views[$0].center, center) < config.cameraOnlyMinBaselineM * 0.5 }) { continue }
                chosen.append(candidate.index)
            }
            return chosen
        }
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
        let scale = min(1, Double(max(32, min(640, maxDimension))) / Double(max(k.width, k.height)))
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
