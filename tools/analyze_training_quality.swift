// Read-only diagnostic runner for the same on-device pipeline; output is written to a separate directory.
import Foundation

@main struct AnalyzeTrainingQuality {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: analyze_training_quality SCAN_DIRECTORY REPORT_DIRECTORY"); exit(2)
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        var records: [FrameRecord] = []
        for name in ["review-poses.jsonl", "poses_refined.jsonl", "poses.jsonl"] {
            records = ScanLibrary.readRecords(source.appendingPathComponent(name))
            if !records.isEmpty { break }
        }
        guard !records.isEmpty else { print("No pose records"); exit(1) }
        let selection = TrainingFrameSelector.select(records,
            evidence: TrainingFrameSelector.evidence(records: records, directory: source))
        let result = await OfflinePoseRefinement.run(records: records, directory: source, rounds: 6)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(selection).write(to: output.appendingPathComponent("training-selection.json"))
        try encoder.encode(result.report).write(to: output.appendingPathComponent("pose-refinement.json"))
        print("Selection: \(selection.inputFrames) -> \(selection.selectedIDs.count); check/recapture \(selection.recaptureIDs.count)")
        print(String(decoding: try encoder.encode(result.report), as: UTF8.self))
    }
}
