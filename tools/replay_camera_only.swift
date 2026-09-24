// Desktop replay of the camera-only (LiDAR off) pipeline on a LiDAR scan, scored against
// LiDAR-backed references. Reads the scan; never writes into it. Everything goes to WORK_DIR.
//
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,TrainingFrameSelector,PhotometricPoseValidator,RGBStereoMatcher,RGBReconstructionEngine}.swift \
//   tools/camera_only_metrics.swift tools/replay_camera_only.swift -o /tmp/replay_camera_only
//
// /tmp/replay_camera_only SCAN WORK_DIR --reference REF.jsonl [--baseline FILE] [--candidate FILE] [--all-frames] [--no-mvs]
//   [--reference-voxel M]
//
// REF.jsonl: LiDAR-pipeline poses, e.g. `replay_pose_refinement refine SCAN REF.jsonl --no-surface`.
// --baseline: camera-only poses (ARKit + keyframe anchors); default SCAN/review-poses.jsonl. Its records
//   also supply image/depth metadata. --candidate: poses under test; default the baseline.
// --reference-voxel: diagnostic fusion voxel for the LiDAR cloud (default: the app's refuseVoxelSizeM).
import Foundation
import simd

@main struct ReplayCameraOnly {
    typealias Metrics = CameraOnlyMetrics

    struct Frames: Codable {
        var scanFrames = 0
        var simulatedFrames = 0
        var evaluatedFrames = 0
        var missingInReference = 0
        var missingInCandidate = 0
        var subsamplingMinBaselineM: Double?
        var subsamplingMinIntervalS: Double?
        var simulatedDurationS = 0.0
        var blurKeep = 0
        var blurDemote = 0
        var blurDrop = 0
    }

    struct PhotoAlignment: Codable {
        /// input = baseline, candidate = reference: the reference's photo-alignment gain.
        var referenceOverBaseline: PhotometricPoseValidator.Report
        var candidateOverBaseline: PhotometricPoseValidator.Report?
    }

    struct ReferenceCloud: Codable {
        var points = 0
        var fusionFrames = 0
        var exportMaxPoints = 0
        var refuseMemoryBudgetMB = 0
        var voxelSizeM = 0.0
        var medianSpacingM: Double?
        var spacingSamples = 0
        var fusion: RefusionEngine.Report
    }

    struct MVSRun: Codable {
        var poses: String
        var reconstruction: RGBReconstructionEngine.Report
        var accuracy: Metrics.Accuracy
        var completeness: Metrics.Completeness
        /// Restricted to reference points viewed by this run's contributing reference frames.
        var viewedCompleteness: Metrics.Completeness
        var viewingFrames = 0
        var reconstructionSeconds = 0.0
        var scoringSeconds = 0.0
    }

    struct Timings: Codable {
        var loadSeconds = 0.0
        var poseMetricsSeconds = 0.0
        var photoAlignmentSeconds = 0.0
        var referenceFusionSeconds = 0.0
        var referenceIndexSeconds = 0.0
        var mvsSeconds = 0.0
        var totalSeconds = 0.0
    }

    struct Report: Codable {
        var version = 1
        var scan: String
        var referencePoses: String
        var baselinePoses: String
        var candidatePoses: String
        var candidateIsBaseline = true
        var allFrames = false
        var mvsEnabled = true
        var frames = Frames()
        var candidateVsReference = Metrics.PoseComparison()
        var baselineVsReference = Metrics.PoseComparison()
        var photoAlignment: PhotoAlignment?
        var referenceCloud: ReferenceCloud?
        var mvs: [MVSRun] = []
        var timings = Timings()
        var notes: [String] = []
    }

    static func records(_ url: URL) throws -> [FrameRecord] {
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .map { try decoder.decode(FrameRecord.self, from: Data($0.utf8)) }
    }

    static func byID(_ records: [FrameRecord]) -> [Int: FrameRecord] {
        Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `base` metadata with the transform from `poses` (same frame ID).
    static func substituted(_ base: [FrameRecord], poses: [Int: FrameRecord]) -> [FrameRecord] {
        base.compactMap { record in
            guard let pose = poses[record.id], pose.transform.count == 16 else { return nil }
            var out = record
            out.transform = pose.transform
            return out
        }
    }

    static func stripDepth(_ records: [FrameRecord]) -> [FrameRecord] {
        records.map { record in
            var out = record
            out.depthFile = nil; out.confidenceFile = nil; out.depthWidth = nil; out.depthHeight = nil
            return out
        }
    }

    /// Minimal binary little-endian PLY (x, y, z float; red, green, blue uchar).
    static func writePLY(_ points: [CloudPoint], to url: URL) throws {
        var data = Data(("ply\nformat binary_little_endian 1.0\n"
            + "comment camera-only replay (world: ARKit gravity-aligned, Y-up, meters)\n"
            + "element vertex \(points.count)\nproperty float x\nproperty float y\nproperty float z\n"
            + "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n").utf8)
        data.reserveCapacity(data.count + points.count * 15)
        for p in points {
            for value in [p.x, p.y, p.z] { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: [p.r, p.g, p.b])
        }
        try data.write(to: url, options: .atomic)
    }

    static func linkScanData(from scan: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["images", "depth"] {
            let input = scan.appendingPathComponent(name), output = destination.appendingPathComponent(name)
            guard fm.fileExists(atPath: input.path) else { continue }
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            for url in try fm.contentsOfDirectory(at: input, includingPropertiesForKeys: [.isRegularFileKey]) {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                do { try fm.linkItem(at: url, to: output.appendingPathComponent(url.lastPathComponent)) }
                catch { try fm.copyItem(at: url, to: output.appendingPathComponent(url.lastPathComponent)) }
            }
        }
    }

    static func usage() -> Never {
        print("Usage: replay_camera_only SCAN WORK_DIR --reference REF.jsonl [--baseline FILE] [--candidate FILE] [--all-frames] [--no-mvs] [--reference-voxel M]")
        exit(2)
    }

    /// Float settings as their shortest decimal (0.04, not 0.03999999910593033) in the JSON report.
    static func decimal(_ value: Float) -> Double { Double(value.description) ?? Double(value) }

    static func format(_ value: Double?, _ scale: Double = 1, _ digits: Int = 1) -> String {
        value.map { String(format: "%.\(digits)f", $0 * scale) } ?? "-"
    }

    static func main() throws {
        let started = Date()
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { usage() }
        let scan = URL(fileURLWithPath: args.removeFirst()), work = URL(fileURLWithPath: args.removeFirst())
        var referencePath: String?, baselinePath: String?, candidatePath: String?
        var allFrames = false, runMVS = true, referenceVoxel: Float?
        while !args.isEmpty {
            let flag = args.removeFirst()
            switch flag {
            case "--reference-voxel":
                guard let value = args.isEmpty ? nil : Float(args.removeFirst()), value >= 0.005, value <= 0.1 else { usage() }
                referenceVoxel = value
            case "--reference", "--baseline", "--candidate":
                guard !args.isEmpty else { usage() }
                let value = args.removeFirst()
                if flag == "--reference" { referencePath = value } else if flag == "--baseline" { baselinePath = value } else { candidatePath = value }
            case "--all-frames": allFrames = true
            case "--no-mvs": runMVS = false
            default: usage()
            }
        }
        guard let referencePath else { usage() }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: work.path) else { print("WORK_DIR must not exist"); exit(2) }
        let scanPath = scan.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let workParent = work.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard !(workParent.appendingPathComponent(work.lastPathComponent).path + "/").hasPrefix(scanPath) else {
            print("WORK_DIR must be outside SCAN"); exit(2)
        }
        let baselineURL = baselinePath.map { URL(fileURLWithPath: $0) } ?? scan.appendingPathComponent("review-poses.jsonl")
        let candidateURL = candidatePath.map { URL(fileURLWithPath: $0) } ?? baselineURL
        let referenceURL = URL(fileURLWithPath: referencePath)
        let baseline = try records(baselineURL), reference = byID(try records(referenceURL))
        let candidate = candidateURL == baselineURL ? byID(baseline) : byID(try records(candidateURL))
        guard !baseline.isEmpty, !reference.isEmpty, !candidate.isEmpty else { print("Empty pose file"); exit(2) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var config = CaptureConfig()   // camera-only: baRounds 0, no surface reconstruction, MVS enabled
        // Diagnostic MVS overrides (MVS_DIM, MVS_REFS, MVS_STRIDE, MVS_SOURCES, MVS_ITERS, MVS_STD,
        // MVS_COST, MVS_VIEWS, MVS_RATIO, MVS_UNIQUE); the report records the values used.
        let env = ProcessInfo.processInfo.environment
        if let v = env["MVS_DIM"].flatMap(Int.init) { config.rgbMaxImageDimension = v }
        if let v = env["MVS_REFS"].flatMap(Int.init) { config.rgbMaxReferenceFrames = v }
        if let v = env["MVS_STRIDE"].flatMap(Int.init) { config.rgbPixelStride = v }
        if let v = env["MVS_SOURCES"].flatMap(Int.init) { config.rgbSourceViews = v }
        if let v = env["MVS_ITERS"].flatMap(Int.init) { config.rgbPatchMatchIterations = v }
        if let v = env["MVS_STD"].flatMap(Float.init) { config.rgbMinPatchStd = v }
        if let v = env["MVS_COST"].flatMap(Float.init) { config.rgbMaxMatchCost = v }
        if let v = env["MVS_VIEWS"].flatMap(Int.init) { config.rgbConsistentViews = v }
        if let v = env["MVS_RATIO"].flatMap(Float.init) { config.rgbConsistencyDepthRatio = v }
        if let v = env["MVS_UNIQUE"].flatMap(Float.init) { config.rgbUniquenessMargin = v }
        var report = Report(scan: scan.path, referencePoses: referenceURL.path, baselinePoses: baselineURL.path,
                            candidatePoses: candidateURL.path, allFrames: allFrames, mvsEnabled: runMVS)
        report.timings.loadSeconds = Date().timeIntervalSince(started)

        // 1. Simulated camera-only capture on the baseline (live ARKit + anchor) poses.
        let ordered = baseline.filter { $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite) }
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        let simulated: [FrameRecord]
        if allFrames { simulated = ordered } else {
            simulated = Metrics.simulateCameraOnlyShutter(ordered, minBaselineM: decimal(config.cameraOnlyMinBaselineM),
                                                          minIntervalS: config.minKeyframeInterval)
            report.frames.subsamplingMinBaselineM = decimal(config.cameraOnlyMinBaselineM)
            report.frames.subsamplingMinIntervalS = config.minKeyframeInterval
        }
        let evaluated = simulated.filter { reference[$0.id] != nil && candidate[$0.id] != nil }
        report.frames.scanFrames = baseline.count
        report.frames.simulatedFrames = simulated.count
        report.frames.evaluatedFrames = evaluated.count
        report.frames.missingInReference = simulated.filter { reference[$0.id] == nil }.count
        report.frames.missingInCandidate = simulated.filter { candidate[$0.id] == nil }.count
        if let first = simulated.first, let last = simulated.last { report.frames.simulatedDurationS = last.timestamp - first.timestamp }
        guard evaluated.count >= 3 else { print("Fewer than three evaluated frames"); exit(1) }
        let baselineByID = byID(baseline)
        report.candidateIsBaseline = candidateURL == baselineURL
            || evaluated.allSatisfy { candidate[$0.id]!.transform == baselineByID[$0.id]!.transform }

        // 2. Poses on the simulated frame set.
        var t = Date()
        func poses(_ source: [Int: FrameRecord]) -> [Metrics.Pose] {
            evaluated.compactMap { source[$0.id].flatMap { r in Metrics.Pose(record: r) } }
        }
        let referencePoses = poses(reference)
        report.candidateVsReference = Metrics.comparePoses(candidate: poses(candidate), reference: referencePoses)
        report.baselineVsReference = Metrics.comparePoses(candidate: poses(baselineByID), reference: referencePoses)
        report.timings.poseMetricsSeconds = Date().timeIntervalSince(t)

        // 3. Photo alignment with LiDAR depth, independent of the camera-only pipeline.
        t = Date()
        let photoInput = BlurFilter.annotate(evaluated)   // depth-bearing, baseline poses
        let referenceRecords = substituted(photoInput, poses: reference)
        var photo = PhotoAlignment(referenceOverBaseline: PhotometricPoseValidator.evaluate(
            input: photoInput, candidate: referenceRecords, directory: scan))
        if !report.candidateIsBaseline {
            photo.candidateOverBaseline = PhotometricPoseValidator.evaluate(
                input: photoInput, candidate: substituted(photoInput, poses: candidate), directory: scan)
        }
        report.photoAlignment = photo
        report.timings.photoAlignmentSeconds = Date().timeIntervalSince(t)

        if runMVS {
            // Hard links keep every write out of the scan; removed at the end.
            let links = work.appendingPathComponent("scan-links")
            try linkScanData(from: scan, to: links)
            defer { try? fm.removeItem(at: links) }

            // 4. LiDAR reference cloud: reference poses on ALL frames, depth kept, default filters.
            // Desktop capacity: the phone export/working-set caps would coarsen the reference.
            t = Date()
            var fusionConfig = CaptureConfig()
            fusionConfig.exportMaxPoints = 2_000_000
            fusionConfig.refuseMemoryBudgetMB = 512
            if let referenceVoxel { fusionConfig.refuseVoxelSizeM = referenceVoxel }
            let fusionRecords = BlurFilter.annotate(substituted(ordered, poses: reference))
            let fusion = RefusionEngine.refuseWithReport(records: fusionRecords, sessionDir: links, config: fusionConfig,
                                                         target: fusionConfig.exportMaxPoints, diagnosticsDirectory: work,
                                                         availableMemory: { 6 * 1024 * 1024 * 1024 }, progress: { _ in })
            guard fusion.report.status == "completed", !fusion.points.isEmpty else {
                try? fm.removeItem(at: links)
                print("Reference fusion failed: \(fusion.report.status)"); exit(1)
            }
            report.timings.referenceFusionSeconds = Date().timeIntervalSince(t)
            try writePLY(fusion.points, to: work.appendingPathComponent("reference.ply"))
            t = Date()
            let referenceCloud = fusion.points.map { SIMD3($0.x, $0.y, $0.z) }
            let referenceGrid = Metrics.SpatialGrid(referenceCloud, cell: Metrics.accuracyGridCellM)
            let spacing = Metrics.medianSpacing(referenceGrid)
            report.referenceCloud = ReferenceCloud(points: fusion.points.count, fusionFrames: fusionRecords.count,
                                                   exportMaxPoints: fusionConfig.exportMaxPoints,
                                                   refuseMemoryBudgetMB: fusionConfig.refuseMemoryBudgetMB,
                                                   voxelSizeM: decimal(fusionConfig.refuseVoxelSizeM),
                                                   medianSpacingM: spacing.medianM, spacingSamples: spacing.samples,
                                                   fusion: fusion.report)
            report.timings.referenceIndexSeconds = Date().timeIntervalSince(t)

            // 5. Fixed-pose MVS on the simulated depth-free records. Blur verdicts come from the candidate
            // poses (as the app would annotate them) and are shared so poses are the only difference.
            let mvsStarted = Date()
            let cameraOnly = BlurFilter.annotate(stripDepth(substituted(evaluated, poses: candidate)))
            report.frames.blurKeep = cameraOnly.filter { $0.blurVerdict == .keep }.count
            report.frames.blurDemote = cameraOnly.filter { $0.blurVerdict == .demote }.count
            report.frames.blurDrop = cameraOnly.filter { $0.blurVerdict == .drop }.count
            let referenceDepthRecords = byID(substituted(ordered, poses: reference))
            var views: [Int: DepthConsistencyView] = [:]
            for (label, poseSource, file) in [("reference", reference, "mvs-reference-poses.ply"),
                                              ("candidate", candidate, "mvs-candidate-poses.ply")] {
                let runStarted = Date()
                let result = RGBReconstructionEngine.reconstruct(records: substituted(cameraOnly, poses: poseSource),
                                                                 sessionDir: links, config: config)
                let reconstructionSeconds = Date().timeIntervalSince(runStarted)
                try writePLY(result.points, to: work.appendingPathComponent(file))
                let scoringStarted = Date()
                let test = result.points.map { SIMD3($0.x, $0.y, $0.z) }
                for id in result.report.referenceFrameIDs where views[id] == nil {
                    if let record = referenceDepthRecords[id] {
                        views[id] = RefusionEngine.storedDepthView(record, directory: links.appendingPathComponent("depth"))
                    }
                }
                let runViews = result.report.referenceFrameIDs.compactMap { views[$0] }
                let viewed = Metrics.viewedMask(referenceCloud, views: runViews, minDepth: config.rgbMinDepthM,
                                                maxDepth: config.pointMaxDepthM)
                let levels = Metrics.coverageLevels(reference: referenceCloud, test: test)
                report.mvs.append(MVSRun(poses: label, reconstruction: result.report,
                                         accuracy: Metrics.accuracy(test: test, reference: referenceGrid),
                                         completeness: Metrics.completeness(levels: levels),
                                         viewedCompleteness: Metrics.completeness(levels: levels, mask: viewed),
                                         viewingFrames: runViews.count, reconstructionSeconds: reconstructionSeconds,
                                         scoringSeconds: Date().timeIntervalSince(scoringStarted)))
            }
            report.timings.mvsSeconds = Date().timeIntervalSince(mvsStarted)
        }
        if !allFrames {
            report.notes.append("Subsampling keeps a frame >= cameraOnlyMinBaselineM from the last kept frame and >= minKeyframeInterval later; it omits the RGB shutter's depth-scaled translation, rotation trigger, feature and continuity gates, and can only choose among frames the LiDAR shutter saved.")
        }
        report.notes.append("References come from the LiDAR pipeline, not ground truth. ARKit tracking ran with LiDAR enabled. Live sparse ARKit features are not saved, so only MVS points are scored.")
        report.timings.totalSeconds = Date().timeIntervalSince(started)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: work.appendingPathComponent("camera-only-replay.json"), options: .atomic)

        // Concise summary.
        let f = report.frames
        print("FRAMES scan \(f.scanFrames), simulated \(f.simulatedFrames) over \(format(f.simulatedDurationS)) s, evaluated \(f.evaluatedFrames)")
        for (label, c) in [("CANDIDATE", report.candidateVsReference), ("BASELINE", report.baselineVsReference)]
            where label == "CANDIDATE" || !report.candidateIsBaseline {
            print("\(label) vs reference: raw pos median/P95/max \(format(c.rawPositionMedianM, 100))/\(format(c.rawPositionP95M, 100))/\(format(c.rawPositionMaxM, 100)) cm, "
                + "rot \(format(c.rawRotationMedianDeg, 1, 2))/\(format(c.rawRotationP95Deg, 1, 2))/\(format(c.rawRotationMaxDeg, 1, 2))°; "
                + "aligned ATE RMSE \(format(c.alignedATERMSEM, 100)) cm, median \(format(c.alignedATEMedianM, 100)) cm, rot \(format(c.alignedRotationMedianDeg, 1, 2))°; "
                + "Sim(3) scale \(format(c.sim3Scale, 1, 4)); path \(format(c.referencePathM, 1, 2)) m")
            for e in c.relativePoseErrors {
                print("  RPE \(format(e.windowM, 1, 0)) m: \(e.pairs) pairs, trans median/P90 \(format(e.translationMedianM, 100))/\(format(e.translationP90M, 100)) cm "
                    + "(\(format(e.translationMedianPercent, 1, 2))/\(format(e.translationP90Percent, 1, 2))%), rot \(format(e.rotationMedianDeg, 1, 2))/\(format(e.rotationP90Deg, 1, 2))°")
            }
        }
        if let photo = report.photoAlignment {
            for (label, r) in [("reference over baseline", Optional(photo.referenceOverBaseline)), ("candidate over baseline", photo.candidateOverBaseline)] {
                guard let r else { continue }
                print("PHOTO \(label): \(r.status), adjacent \(format(r.adjacentBefore.map(Double.init), 1, 4))->\(format(r.adjacentAfter.map(Double.init), 1, 4)) "
                    + "(Δ \(format(r.adjacentDelta.map(Double.init), 1, 4)), \(r.adjacentPairs) pairs), wide \(format(r.wideBefore.map(Double.init), 1, 4))->\(format(r.wideAfter.map(Double.init), 1, 4)) "
                    + "(Δ \(format(r.wideDelta.map(Double.init), 1, 4)), \(r.widePairs) pairs)")
            }
        }
        if let cloud = report.referenceCloud {
            print("REFERENCE cloud \(cloud.points) points from \(cloud.fusionFrames) frames, voxel \(format(Double(cloud.fusion.finalVoxelSizeM), 100)) cm, median spacing \(format(cloud.medianSpacingM, 100, 2)) cm")
        }
        for run in report.mvs {
            let a = run.accuracy, r = run.reconstruction
            func coverage(_ c: Metrics.Completeness) -> String {
                c.thresholds.map { "\(format($0.thresholdM, 100, 0))cm \(format($0.fraction, 100))%" }.joined(separator: " ")
                    + " of \(c.referencePoints)"
            }
            print("MVS \(run.poses) poses: \(r.outputPoints) points, \(r.contributingReferences)/\(r.attemptedReferences) references, \(format(run.reconstructionSeconds)) s; "
                + "accuracy median/P90 \(format(a.medianM, 100, 2))/\(format(a.p90M, 100, 2)) cm, <=1/2/5 cm \(format(a.within1cm, 100))/\(format(a.within2cm, 100))/\(format(a.within5cm, 100))%, >10 cm \(format(a.beyond10cm, 100))%")
            print("  completeness overall \(coverage(run.completeness)); viewed by \(run.viewingFrames) frames \(coverage(run.viewedCompleteness))")
        }
        let tm = report.timings
        print("TIME total \(format(tm.totalSeconds)) s: poses \(format(tm.poseMetricsSeconds, 1, 2)), photo \(format(tm.photoAlignmentSeconds)), fusion \(format(tm.referenceFusionSeconds)), index \(format(tm.referenceIndexSeconds)), MVS+scoring \(format(tm.mvsSeconds)) s")
        print("REPORT \(work.appendingPathComponent("camera-only-replay.json").path)")
    }
}
