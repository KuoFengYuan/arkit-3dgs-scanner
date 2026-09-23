// Reprocess a scan into a NEW directory; never writes diagnostic reports into the source scan.
import Foundation

@main struct RefuseDataset {
    static func main() throws {
        let args = CommandLine.arguments
        let flags = Set(args.dropFirst(3))
        guard args.count >= 3, flags.isSubset(of: ["--legacy-depth", "--no-range-priority"]) else {
            print("Usage: refuse_dataset SOURCE NEW_OUTPUT [--legacy-depth] [--no-range-priority]"); exit(2)
        }
        let fm = FileManager.default, source = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard !fm.fileExists(atPath: output.path) else { print("Output must not exist"); exit(2) }
        var records = ScanLibrary.readRecords(source.appendingPathComponent("fusion-input-poses.jsonl"))
        if records.isEmpty { records = ScanLibrary.readRecords(source.appendingPathComponent("review-poses.jsonl")) }
        if records.isEmpty { records = ScanLibrary.readRecords(source.appendingPathComponent("poses.jsonl")) }
        guard !records.isEmpty else { print("No records"); exit(2) }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        for name in ["images", "depth"] {
            let input = source.appendingPathComponent(name), destination = output.appendingPathComponent(name)
            guard fm.fileExists(atPath: input.path) else { continue }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for url in try fm.contentsOfDirectory(at: input, includingPropertiesForKeys: [.isRegularFileKey]) {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                do { try fm.linkItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent)) }
                catch { try fm.copyItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent)) }
            }
        }
        if let meta = CaptureMetadata.existingURL(in: source) {
            try fm.copyItem(at: meta, to: output.appendingPathComponent(CaptureMetadata.fileName))
        }
        for name in ["poses.jsonl", "pose-refinement.json"] {
            let url = source.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.copyItem(at: url, to: output.appendingPathComponent(name)) }
        }
        var config = CaptureConfig()
        if flags.contains("--legacy-depth") {
            // Reproduces the earlier temporal-neighbor check and single-range fusion.
            config.depthDiverseReferences = false
            config.depthConsensusEnabled = false
            config.fusionNearRangeM = 0
        }
        if flags.contains("--no-range-priority") { config.fusionNearRangeM = 0 }
        let start = Date()
        let result = RefusionEngine.refuseWithReport(records: records, sessionDir: output, config: config,
            availableMemory: { 6 * 1024 * 1024 * 1024 }, progress: { _ in })
        guard result.report.status == "completed" else { print("Failed: \(result.report.status)"); exit(1) }
        try ExportManager.writePLY(result.points, to: output.appendingPathComponent("review.ply"))
        try ExportManager.writeRefinedPoses(records, to: output.appendingPathComponent("review-poses.jsonl"))
        try ExportManager.writeTrainingDataset(records: records, points: result.points, to: output)
        try JSONEncoder().encode(ScanLibrary.Summary(version: 1, frameCount: records.count, pointCount: result.points.count))
            .write(to: output.appendingPathComponent("scan-summary.json"))
        print("Completed: \(result.points.count) points, \(Date().timeIntervalSince(start)) seconds; \(output.path)")
    }
}
