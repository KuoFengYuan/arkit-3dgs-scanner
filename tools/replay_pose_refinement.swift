// Desktop replay of on-device pose refinement and its photometric validation. Reads a scan
// directory; never writes into it.
//
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,TrainingFrameSelector,OfflinePoseRefinement,LocalSurfaceRefiner,LoopClosureRefiner,FeatureTracker,BundleAdjuster,PoseRefiner,PhotometricPoseValidator}.swift \
//   tools/replay_pose_refinement.swift -o /tmp/replay_pose_refinement
//
// /tmp/replay_pose_refinement compare SCAN INPUT_POSES.jsonl CANDIDATE_POSES.jsonl
// /tmp/replay_pose_refinement refine SCAN OUTPUT_POSES.jsonl [--poses FILE] [--no-surface]
import Foundation

@main struct ReplayPoseRefinement {
    static func records(_ url: URL) throws -> [FrameRecord] {
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { try decoder.decode(FrameRecord.self, from: Data($0.utf8)) }
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4, ["compare", "refine"].contains(args[1]) else {
            print("Usage: replay_pose_refinement compare SCAN INPUT CANDIDATE | refine SCAN OUTPUT [--poses FILE] [--no-surface]")
            exit(2)
        }
        let scan = URL(fileURLWithPath: args[2])
        if args[1] == "compare" {
            guard args.count == 5 else { print("compare needs INPUT and CANDIDATE pose files"); exit(2) }
            let input = try records(URL(fileURLWithPath: args[3]))
            let candidate = try records(URL(fileURLWithPath: args[4]))
            print(json(PhotometricPoseValidator.evaluate(input: input, candidate: candidate, directory: scan)))
            return
        }
        let output = URL(fileURLWithPath: args[3])
        guard !FileManager.default.fileExists(atPath: output.path) else { print("Output must not exist"); exit(2) }
        var poses = "review-poses.jsonl"
        if let i = args.firstIndex(of: "--poses"), i + 1 < args.count { poses = args[i + 1] }
        let surface = !args.contains("--no-surface")
        let input = BlurFilter.annotate(try records(scan.appendingPathComponent(poses)))
        let started = Date()
        // Diagnostic A/B switches; defaults match the app.
        let env = ProcessInfo.processInfo.environment
        var options = BundleAdjuster.Options()
        if env["BA_LEGACY"] == "1" { options = .legacy }
        if let v = env["BA_LEGACY_DEPTH"] { options.legacyDepthWeighting = v == "1" }
        if let v = env["BA_JOINT"] { options.jointSolve = v == "1" }
        if let v = env["BA_TRACKS"] { options.optimizeTracks = v == "1" }
        if env["BA_HOLDOUT"] == "0" { options.holdoutGate = nil }
        if let v = env["BA_PRIOR_T"].flatMap(Float.init) { options.priorTranslationM = v }
        if let v = env["BA_PRIOR_R_DEG"].flatMap(Float.init) { options.priorRotationRad = v * .pi / 180 }
        if let v = env["BA_PRIOR_FRACTION"].flatMap(Float.init) { options.priorMotionFraction = v }
        if let v = env["BA_RECENT"].flatMap(Int.init) { options.recentMatchFrames = v }
        if let v = env["BA_ITER"].flatMap(Int.init) { options.jointIterations = v }
        if let v = env["BA_ANCHORS"].flatMap(Int.init) { options.anchorFrames = v }
        if let v = env["BA_SUBPIXEL"] { options.subpixelFeatures = v == "1" }
        let result = await OfflinePoseRefinement.run(records: input, directory: scan, rounds: 6,
                                                     surfaceRefinement: surface, options: options)
        print(json(result.report))
        print(String(format: "REPLAY %d frames, %.1f s, status %@", input.count, Date().timeIntervalSince(started), result.report.status))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let lines = try result.records.map { String(data: try encoder.encode($0), encoding: .utf8)! }
        try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
    }
}
