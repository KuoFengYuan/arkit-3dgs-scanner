// Camera-only pose refinement replay: simulates a LiDAR-off capture of a saved scan, removes the
// depth, tracks features in the images alone (CameraOnlyTracker) and runs the joint bundle
// adjustment on those depth-free tracks. Writes the resulting poses as a candidate pose file for
// `replay_camera_only --candidate`. Reads the scan; never writes into it.
//
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,FeatureTracker,PoseRefiner,BundleAdjuster,RGBStereoMatcher,RGBReconstructionEngine,CameraOnlyTracker}.swift \
//   tools/camera_only_metrics.swift tools/refine_camera_only.swift -o /tmp/refine_camera_only
//
// /tmp/refine_camera_only SCAN OUT.jsonl [--baseline FILE] [--all-frames]
//
// Environment (diagnostics): CO_TRACK_DIM, CO_MAX_TRACKS, CO_MAX_LEN, CO_FB, CO_EPI, CO_GRID_C, CO_GRID_R,
// CO_OPTIMIZE_TRACKS=1, CO_NO_GATE=1,
// CO_PRIOR_T (m), CO_PRIOR_R (deg), CO_ITERATIONS.
import Foundation
import simd

@main struct RefineCameraOnly {
    static func records(_ url: URL) throws -> [FrameRecord] {
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .map { try decoder.decode(FrameRecord.self, from: Data($0.utf8)) }
    }

    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            print("Usage: refine_camera_only SCAN OUT.jsonl [--baseline FILE] [--all-frames]"); exit(2)
        }
        let scan = URL(fileURLWithPath: args.removeFirst()), out = URL(fileURLWithPath: args.removeFirst())
        var baselinePath: String?, allFrames = false
        while !args.isEmpty {
            switch args.removeFirst() {
            case "--baseline": baselinePath = args.isEmpty ? nil : args.removeFirst()
            case "--all-frames": allFrames = true
            default: print("Unknown option"); exit(2)
            }
        }
        let env = ProcessInfo.processInfo.environment
        let config = CaptureConfig()
        let baselineURL = baselinePath.map { URL(fileURLWithPath: $0) } ?? scan.appendingPathComponent("review-poses.jsonl")
        let baseline = try records(baselineURL)
        let ordered = baseline.filter { $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite) }
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        let simulated = allFrames ? ordered : CameraOnlyMetrics.simulateCameraOnlyShutter(
            ordered, minBaselineM: Double(config.cameraOnlyMinBaselineM), minIntervalS: config.minKeyframeInterval)
        let depthFree = BlurFilter.annotate(simulated.map { record in
            var r = record
            r.depthFile = nil; r.confidenceFile = nil; r.depthWidth = nil; r.depthHeight = nil
            return r
        })

        var trackOptions = CameraOnlyTracker.Options()
        if let v = env["CO_TRACK_DIM"].flatMap(Int.init) { trackOptions.imageDimension = v }
        if let v = env["CO_MAX_TRACKS"].flatMap(Int.init) { trackOptions.maxTracks = v }
        if let v = env["CO_MAX_LEN"].flatMap(Int.init) { trackOptions.maxTrackLength = v }
        if let v = env["CO_FB"].flatMap(Float.init) { trackOptions.maxForwardBackwardPx = v }
        if let v = env["CO_EPI"].flatMap(Float.init) { trackOptions.maxEpipolarPx = v }
        if let v = env["CO_GRID_C"].flatMap(Int.init) { trackOptions.gridColumns = v }
        if let v = env["CO_GRID_R"].flatMap(Int.init) { trackOptions.gridRows = v }
        var options = CameraOnlyPoseRefinement.defaultOptions
        if let v = env["CO_OPTIMIZE_TRACKS"] { options.optimizeTracks = v == "1" }
        if env["CO_NO_GATE"] == "1" { options.holdoutGate = nil }
        if let v = env["CO_PRIOR_T"].flatMap(Float.init) { options.priorTranslationM = v }
        if let v = env["CO_PRIOR_R"].flatMap(Float.init) { options.priorRotationRad = v * .pi / 180 }
        if let v = env["CO_ITERATIONS"].flatMap(Int.init) { options.jointIterations = v }
        // The app's code path (CameraOnlyPoseRefinement.run), so the replay measures what ships.
        let result = CameraOnlyPoseRefinement.run(records: depthFree, directory: scan, tracking: trackOptions, options: options)
        let r = result.report
        if let t = r.tracking {
            print("TRACKS \(t.tracks) tracks, \(t.observations) observations over \(t.frames) frames (failed \(t.failedFrames)); "
                  + "median length \(t.medianTrackLength); detected \(t.detected), steps \(t.tracked); rejected fb \(t.rejectedForwardBackward), "
                  + "corr \(t.rejectedCorrelation), epipolar \(t.rejectedEpipolar); \(String(format: "%.1f", t.seconds)) s")
        }
        let holdout = r.holdoutMedianBeforePx.flatMap { b in r.holdoutMedianAfterPx.map { a in
            String(format: "%.2f -> %.2f px (%+.1f%%)", b, a, (a / b - 1) * 100) } } ?? "n/a"
        print(String(format: "BA %@: rounds %d, holdout median %@, applied %d frames, move median %.1f mm max %.1f mm, total %.1f s",
                     r.status, r.roundsApplied, holdout, r.appliedFrames, r.medianCorrectionMM ?? 0, r.maxCorrectionMM ?? 0, r.seconds))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let refined = Dictionary(result.records.map { ($0.id, $0.transform) }, uniquingKeysWith: { a, _ in a })

        // Candidate file: every baseline record, with refined transforms where BA was applied.
        var lines = [String]()
        for record in baseline {
            var r = record
            if let transform = refined[r.id] { r.transform = transform }
            lines.append(String(decoding: try encoder.encode(r), as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        print("WROTE \(out.path)")
    }
}
