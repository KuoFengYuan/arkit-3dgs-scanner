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
        check(selected.recaptureIDs.isEmpty && selected.notice == nil, "motion estimate alone does not request recapture or raise a banner")
        check(selected.motionRiskIDs == [10] && selected.weakDetailIDs == [] && selected.diagnosticSummary != nil,
              "motion-only risk remains available as optional diagnostic information")
        var weak = record(20, x: 1, risk: 15); weak.sharpnessRatio = 0.2
        let weakReport = TrainingFrameSelector.select([weak], evidence: [20: E(detail: 0.3, signature: flat)])
        check(weakReport.recaptureIDs == [20] && weakReport.notice?.contains("細節偏弱") == true,
              "measured weak detail still raises an actionable recapture warning")
        let unknown = TrainingFrameSelector.select([weak], evidence: [20: E(detail: 0, signature: flat)])
        check(unknown.notice == nil && unknown.recaptureIDs.isEmpty && unknown.uncertainDetailIDs == [20],
              "textureless measurements are unknown quality instead of false weak-detail warnings")
        let mixed = TrainingFrameSelector.select(burst + [weak], evidence: evidence.merging([20: E(detail: 0.3, signature: flat)]) { _, new in new })
        check(mixed.selectedIDs == [10,20] && mixed.recaptureIDs == [20] && mixed.motionRiskIDs == [10],
              "mixed scans warn only for measured weak views while preserving distinct coverage")
        let oldV2 = TrainingFrameSelector.Report(version: 2, inputFrames: 10, selectedIDs: [10], recaptureIDs: [10],
            decisions: selected.decisions, motionRiskIDs: [10], weakDetailIDs: [], uncertainDetailIDs: [])
        check(oldV2.notice == nil && oldV2.diagnosticSummary != nil,
              "existing version-two motion-only reports no longer raise a warning banner")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as! [String: Any]
        legacy["version"] = 1; legacy["recaptureIDs"] = [10]
        legacy.removeValue(forKey: "motionRiskIDs"); legacy.removeValue(forKey: "weakDetailIDs")
        legacy.removeValue(forKey: "uncertainDetailIDs")
        let legacyReport = try JSONDecoder().decode(TrainingFrameSelector.Report.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        check(legacyReport.selectedIDs == selected.selectedIDs && legacyReport.notice == nil && legacyReport.diagnosticSummary != nil, "legacy selection reports remain readable")
        let stableEncoder = JSONEncoder()
        stableEncoder.outputFormatting = [.sortedKeys]
        let originalReportBytes = try stableEncoder.encode(mixed)
        let defaults = UserDefaults.standard
        let priorLanguage = defaults.object(forKey: AppLanguage.preferenceKey)
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        let englishReportBytes = try stableEncoder.encode(mixed)
        if let priorLanguage { defaults.set(priorLanguage, forKey: AppLanguage.preferenceKey) }
        else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        check(originalReportBytes == englishReportBytes, "language preference does not change serialized selection IDs or reasons")
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

        // Working distance: the median confident depth; metric sizes scale only below room scale.
        try [Float](repeating: 0.3, count: 40*30).withUnsafeBytes { try Data($0).write(to: scan.appendingPathComponent("depth/near.bin")) }
        func withDepth(_ id: Int, _ file: String, x: Double = 0) -> FrameRecord {
            var r = record(id, x: x); r.depthFile = file; r.confidenceFile = "c.bin"; r.depthWidth = 40; r.depthHeight = 30
            return r
        }
        let roomDistance = TrainingFrameSelector.workingDistance(records: (1...5).map { withDepth($0, "d.bin") }, directory: scan)
        let nearDistance = TrainingFrameSelector.workingDistance(records: (1...5).map { withDepth($0, "near.bin") }, directory: scan)
        check(roomDistance == 2 && nearDistance.map { abs($0 - 0.3) < 1e-6 } == true
              && TrainingFrameSelector.workingDistance(records: [record(1)], directory: scan) == nil,
              "working distance is the median confident LiDAR depth, and nil without depth")
        check(TrainingFrameSelector.metricScale(workingDistance: 2) == 1 && TrainingFrameSelector.metricScale(workingDistance: 1.2) == 1
              && abs(TrainingFrameSelector.metricScale(workingDistance: 0.3) - 0.25) < 1e-6
              && TrainingFrameSelector.metricScale(workingDistance: 0.05) == 0.125 && TrainingFrameSelector.metricScale(workingDistance: nil) == 1,
              "metric sizes keep their room-scale values from 1.2 m on and shrink in proportion below, to at most 1/8")
        // Redundancy: 2 cm apart is a near-duplicate at room scale, 3.8° of parallax at 0.3 m.
        let pair = [record(30), record(31, x: 0.02)]
        let pairEvidence = [30: E(detail: 2, signature: flat), 31: E(detail: 1, signature: flat)]
        check(TrainingFrameSelector.select(pair, evidence: pairEvidence).selectedIDs == [30]
              && TrainingFrameSelector.select(pair, evidence: pairEvidence, workingDistance: 0.3).selectedIDs == [30, 31],
              "the redundancy step shrinks with the working distance: 2 cm apart is a distinct view at 0.3 m")
        // Blur verdicts: readout skew is not image blur, and neighbours must see the same surface.
        func blurRecord(_ id: Int, x: Double, risk: Double, sharpness: Double) -> FrameRecord {
            var r = record(id, x: x, risk: risk); r.exposureDuration = 0.006; r.sharpness = sharpness
            return r
        }
        let slow = (0..<4).map { blurRecord(40 + $0, x: Double($0) * 0.01, risk: 12, sharpness: 1) }
        check(BlurFilter.evaluate(slow).values.contains(.demote) == true
              && BlurFilter.evaluate(slow, readout: 0.01).values.allSatisfy { $0 == .keep },
              "with the readout given, 12 px of risk from a 6 ms exposure and 10 ms readout (4.5 px of blur) keeps the photos")
        let surfaces = (0..<4).map { blurRecord(50 + $0, x: Double($0) * 0.01, risk: 2, sharpness: 10) }
            + [blurRecord(60, x: 0.3, risk: 2, sharpness: 1), blurRecord(61, x: 0.31, risk: 2, sharpness: 1.1), blurRecord(62, x: 0.32, risk: 2, sharpness: 0.9)]
        check(BlurFilter.evaluate(surfaces)[60] == .demote && BlurFilter.evaluate(surfaces, neighborScale: 0.25)[60] == .keep,
              "at close range, photos 30 cm apart are not neighbours, so a less textured surface is not judged blurred")
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
