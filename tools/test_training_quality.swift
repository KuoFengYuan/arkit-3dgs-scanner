import Foundation
import CoreGraphics
import ImageIO
import simd

@main struct TrainingQualityTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fable-quality-" + UUID().uuidString)
        let scan = root.appendingPathComponent("scan_fixture")
        try fm.createDirectory(at: scan.appendingPathComponent("images"), withIntermediateDirectories: true)
        try fm.createDirectory(at: scan.appendingPathComponent("depth"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ ok: Bool, _ message: String) {
            precondition(ok, message); checks += 1; print("PASS: \(message)")
        }
        func record(_ id: Int, x: Double = 0, risk: Double = 2) -> FrameRecord {
            FrameRecord(id: id, timestamp: Double(id)*0.1,
                        transform: [1,0,0,x, 0,1,0,0, 0,0,1,0, 0,0,0,1],
                        intrinsics: CameraIntrinsics(fx: 140, fy: 140, cx: 80, cy: 60, width: 160, height: 120),
                        exposureDuration: 0.004, exposureOffsetEV: 0, estimatedBlurPx: risk,
                        sharpness: Double(id), imageFile: "frame_\(id).png")
        }
        typealias E = TrainingFrameSelector.Evidence
        let flat = [Float](repeating: 0.5, count: 192)
        let burst = (1...10).map { record($0, risk: 15) }
        let evidence = Dictionary(uniqueKeysWithValues: burst.map { ($0.id, E(detail: Double($0.id), signature: flat)) })
        let selected = TrainingFrameSelector.select(burst, evidence: evidence)
        check(selected.selectedIDs == [10], "clearest equivalent view wins without a 30% RGB rejection cap")
        check(selected.recaptureIDs == [10] && selected.notice != nil, "risky unique view remains and carries a recapture warning")
        check(selected.motionRiskIDs == [10] && selected.weakDetailIDs == [] && selected.notice!.contains("尚未判定為模糊"),
              "motion-only risk is not presented as confirmed image blur")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as! [String: Any]
        legacy.removeValue(forKey: "motionRiskIDs"); legacy.removeValue(forKey: "weakDetailIDs")
        legacy.removeValue(forKey: "uncertainDetailIDs")
        let legacyReport = try JSONDecoder().decode(TrainingFrameSelector.Report.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        check(legacyReport.selectedIDs == selected.selectedIDs && legacyReport.notice != nil, "legacy selection reports remain readable")
        check(burst.allSatisfy { $0.blurVerdict == .keep }, "RGB de-duplication leaves depth fusion decisions unchanged")
        var novel = record(11, x: 0.2)
        var allEvidence = evidence; allEvidence[11] = E(detail: 1, signature: flat)
        check(TrainingFrameSelector.select(burst+[novel], evidence: allEvidence).selectedIDs == [10,11], "distinct camera baseline is preserved")
        novel.transform = [0,0,1,0, 0,1,0,0, -1,0,0,0, 0,0,0,1]
        check(TrainingFrameSelector.select(burst+[novel], evidence: allEvidence).selectedIDs == [10,11], "distinct viewing direction is preserved")
        novel = record(11)
        allEvidence[11] = E(detail: 1, signature: [Float](repeating: 0.8, count: 192))
        check(TrainingFrameSelector.select(burst+[novel], evidence: allEvidence).selectedIDs == [10,11], "changed image content/occlusion is not removed as a duplicate")
        check(TrainingFrameSelector.select(burst).selectedIDs.count == 10, "legacy data without visual evidence is not blindly thinned")
        allEvidence[11] = E(detail: 0, signature: flat)
        check(TrainingFrameSelector.select(burst+[novel], evidence: allEvidence).selectedIDs.count == 2, "textureless view is not classified as optical blur")
        var demoted = record(12); demoted.blurVerdict = .demote
        check(!TrainingFrameSelector.select(burst+[demoted], evidence: evidence).selectedIDs.contains(12), "RGB-demoted image stays out of training while its depth record survives")

        // Deterministic non-symmetric textured image: decoding must preserve sensor row order.
        let w = 160, h = 120
        var seed: UInt64 = 42
        var pixels = [UInt8](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[y*w+x] = y < 12 ? 10 : (y >= h-12 ? 245 : UInt8(truncatingIfNeeded: seed >> 32))
        } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                         decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let imageURL = scan.appendingPathComponent("images/frame_1.png")
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil); precondition(CGImageDestinationFinalize(destination))
        let originalBytes = try Data(contentsOf: imageURL)
        let gray = ScanImageDecoder.gray(record(1), directory: scan, maxDimension: 960)!
        check(gray.pixels[3*w+3] < gray.pixels[(h-3)*w+3], "sensor-oriented grayscale decoder does not vertically flip pixels")
        check(TrainingFrameSelector.measure(record(1), directory: scan)!.detail > 0, "RGB selector measures actual image detail")
        var mismatch = record(1); mismatch.intrinsics.width = 161
        check(ScanImageDecoder.gray(mismatch, directory: scan, maxDimension: 960) == nil, "dimension mismatch is rejected instead of corrupting intrinsics")
        let depthURL = scan.appendingPathComponent("depth/d.bin")
        try [Float](repeating: 2, count: 40*30).withUnsafeBytes { try Data($0).write(to: depthURL) }
        try Data(repeating: 2, count: 40*30).write(to: scan.appendingPathComponent("depth/c.bin"))
        var frames = (1...1000).map { i -> FrameRecord in
            var r = record(i); r.imageFile = "frame_1.png"
            r.depthFile = "d.bin"; r.confidenceFile = "c.bin"; r.depthWidth = 40; r.depthHeight = 30
            return r
        }
        let offline = await OfflinePoseRefinement.run(records: frames, directory: scan, rounds: 2)
        check(offline.report.processedFrames == 1000, "disk pass processes all 1000 saved frames without latest-only drops")
        check(offline.report.peakDescriptorFrames <= 8, "1000-frame pass retains at most eight descriptor frames")
        check(offline.report.observationCount <= offline.report.observationBudget, "compact observation storage stays within the whole-scan budget")
        check(offline.report.featureExtractionSeconds != nil && offline.report.matchingSeconds != nil,
              "offline report separates decoding, feature extraction and matching costs")
        check(offline.report.status == "insufficientTrackSupport" && offline.report.notice.contains("匹配不足"),
              "failed refinement reports the actual support failure instead of a generic warning")
        var legacyPose = try JSONSerialization.jsonObject(with: JSONEncoder().encode(offline.report)) as! [String: Any]
        for key in ["decodeSeconds", "featureExtractionSeconds", "matchingSeconds", "bundleAdjustmentSeconds"] { legacyPose.removeValue(forKey: key) }
        let oldPoseReport = try JSONDecoder().decode(OfflinePoseRefinement.Report.self, from: JSONSerialization.data(withJSONObject: legacyPose))
        check(oldPoseReport.processedFrames == 1000, "old pose reports without timings remain readable")
        check(offline.records.map(\.transform) == frames.map(\.transform), "already consistent poses are not changed without validation improvement")
        let cancelled = await OfflinePoseRefinement.run(records: frames, directory: scan, rounds: 2, isCancelled: { true })
        check(cancelled.report.status == "cancelled" && cancelled.report.processedFrames == 0, "cancellation returns original poses before decoding")
        frames[0].depthWidth = 41
        check(OfflinePoseRefinement.extract(frames[0], directory: scan) == nil, "truncated/mismatched depth is rejected without buffer over-read")
        var pathTraversal = frames[1]; pathTraversal.depthFile = "../d.bin"
        check(OfflinePoseRefinement.extract(pathTraversal, directory: scan) == nil, "depth sidecars cannot escape their directory")
        check(try Data(contentsOf: imageURL) == originalBytes, "selection and pose processing preserve original image bytes")

        // Historical camera-only scan: publish a separate, internally consistent selection export.
        let r = record(1)
        try ExportManager.writeRefinedPoses([r], to: scan.appendingPathComponent("poses.jsonl"))
        let library = ScanLibrary(root: root)
        try await library.saveReview(directory: scan, points: [CloudPoint(x: 0,y: 0,z: -2,r: 1,g: 2,b: 3)], records: [r])
        let sourceEntry = try await library.entries()[0]
        let optimized = try await library.optimizeTraining(sourceEntry, progress: { _,_ in })
        check(optimized.id != sourceEntry.id && fm.fileExists(atPath: scan.path), "history optimization publishes a new scan and preserves the original")
        check(fm.fileExists(atPath: optimized.directory.appendingPathComponent("sparse/0/images.bin").path), "optimized history scan contains a ready-to-train COLMAP export")
        let report = await library.trainingSelection(optimized)
        check(report?.selectedIDs == [1], "history preview can read the training selection report")
        try await library.delete(optimized)
        check(try Data(contentsOf: imageURL) == originalBytes, "deleting optimized hard-linked media does not delete original scan photos")
        print("\(checks) training-quality checks passed")
    }
}
