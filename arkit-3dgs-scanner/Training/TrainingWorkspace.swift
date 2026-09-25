// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation

/// Persistent training status of one scan (`gaussian-training/state.json`). Written atomically
/// on every state change and checkpoint, so History shows it after the app restarts.
nonisolated struct TrainingRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case preparing, running, paused, completed, failed, cancelled
        /// Stored as running/preparing but no session owns it: the app stopped mid-run.
        case interrupted
    }
    /// Why training stopped or paused; language-independent (the UI localises it).
    enum Reason: String, Codable, Sendable {
        case user, background, thermal, battery, memory, overflow, error, completed
        /// A capture is running (camera, AR tracking and fusion need the GPU and memory).
        case capture
    }

    var status: Status
    var reason: Reason?
    var configuration: GaussianTrainingConfiguration
    var iteration: Int
    var gaussians: Int
    var loss: Double?
    var psnr: Double?
    var validationPSNR: Double?
    var elapsedSeconds: Double
    var checkpointIteration: Int?
    var startedAt: Date
    var updatedAt: Date
    var errorMessage: String?
    var peakFootprintMB: Int?
    var plannedMB: Int?

    var totalIterations: Int { configuration.iterations }
    /// Progress of this run (an enhancement counts from the saved model's iteration).
    var progress: Double {
        let start = configuration.startIteration
        return Double(max(0, iteration - start)) / Double(max(1, totalIterations - start))
    }
    /// A completed run that was finished before its planned iterations.
    var finishedEarly: Bool { status == .completed && iteration < totalIterations }
}

/// Files of the on-device training of one scan, inside the scan directory:
///
///     scan_…/gaussian-training/
///         state.json          status for History (small, atomic)
///         checkpoint.gsck     resumable state (large; removed when training completes)
///         model/              gaussians.ply, gaussians.json, ppisp.json, training-poses.jsonl,
///                             training-report.json, preview.jpg
///
/// Nothing outside this folder is written, so original images, depth and poses are preserved.
/// The dataset ZIP leaves this folder out; the model has its own share archive.
nonisolated struct TrainingWorkspace: Sendable {
    static let folderName = ExportManager.gaussianTrainingFolder
    let scan: URL
    var root: URL { scan.appendingPathComponent(Self.folderName, isDirectory: true) }
    var stateURL: URL { root.appendingPathComponent("state.json") }
    var checkpointURL: URL { root.appendingPathComponent(GaussianCheckpoint.fileName) }
    var modelDirectory: URL { root.appendingPathComponent("model", isDirectory: true) }
    var modelURL: URL { modelDirectory.appendingPathComponent(GaussianExport.plyName) }
    var previewURL: URL { modelDirectory.appendingPathComponent("preview.jpg") }
    var snapshotURL: URL { root.appendingPathComponent("snapshot.jpg") }

    init(scan: URL) { self.scan = scan }

    var hasModel: Bool { FileManager.default.fileExists(atPath: modelURL.path) }
    var hasCheckpoint: Bool { GaussianCheckpoint.header(at: checkpointURL) != nil }

    /// The saved record; a run that was active when the app stopped reads as interrupted.
    func record(activeScan: URL? = nil) -> TrainingRecord? {
        guard let data = try? Data(contentsOf: stateURL),
              var record = try? JSONDecoder.training.decode(TrainingRecord.self, from: data) else { return nil }
        let isActive = activeScan?.standardizedFileURL.path == scan.standardizedFileURL.path
        if !isActive && (record.status == .running || record.status == .preparing) {
            record.status = .interrupted
        }
        if record.status == .completed && !hasModel { record.status = .failed }
        return record
    }

    func save(_ record: TrainingRecord) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder.training.encode(record).write(to: stateURL, options: .atomic)
    }

    /// Removes checkpoint, model and status (the scan itself is untouched).
    func removeAll() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func removeCheckpoint() { try? FileManager.default.removeItem(at: checkpointURL) }

    /// The saved model's share archive, next to the scan.
    var modelArchiveURL: URL { scan.deletingLastPathComponent().appendingPathComponent(scan.lastPathComponent + "-3dgs.zip") }

    /// The completed record of the saved model, rebuilt from its training report.
    func completedRecord() -> TrainingRecord? {
        guard hasModel,
              let data = try? Data(contentsOf: modelDirectory.appendingPathComponent(GaussianExport.reportName)),
              let report = try? JSONDecoder.training.decode(GaussianTrainingSession.Report.self, from: data) else { return nil }
        return TrainingRecord(status: .completed, reason: .completed, configuration: report.configuration,
                              iteration: report.iterations, gaussians: report.gaussians, validationPSNR: report.validationPSNR,
                              elapsedSeconds: report.elapsedSeconds, startedAt: report.createdAt, updatedAt: report.createdAt,
                              peakFootprintMB: report.peakFootprintMB, plannedMB: report.plan.totalBytes >> 20)
    }

    /// Drops an unfinished run (checkpoint, snapshot, status) but keeps a saved model: its
    /// completed status is restored. Without a model the folder is removed.
    func discardProgress() throws {
        guard let completed = completedRecord() else { return try removeAll() }
        removeCheckpoint()
        try? FileManager.default.removeItem(at: snapshotURL)
        try save(completed)
    }

    /// Removes checkpoint, model, status and the model's share archive.
    func removeTraining() throws {
        try removeAll()
        try? FileManager.default.removeItem(at: modelArchiveURL)
    }

    /// On-disk size of the training folder.
    var bytes: Int {
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in items { total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }

    /// ZIP of the trained model folder next to the scan (`scan_…-3dgs.zip`) for sharing.
    func makeModelArchive() throws -> URL {
        let fm = FileManager.default
        guard hasModel else { throw GaussianExport.ExportError.empty }
        let parent = scan.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".model-archive-\(UUID().uuidString)", isDirectory: true)
        let named = staging.appendingPathComponent(scan.lastPathComponent + "-3dgs", isDirectory: true)
        try fm.createDirectory(at: named, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for file in try fm.contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil) {
            let target = named.appendingPathComponent(file.lastPathComponent)
            do { try fm.linkItem(at: file, to: target) } catch { try fm.copyItem(at: file, to: target) }
        }
        let destination = modelArchiveURL
        let temporary = parent.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? fm.removeItem(at: temporary) }
        try ExportManager.zipDirectory(named, to: temporary)
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: destination) }
        return destination
    }
}

nonisolated extension JSONEncoder {
    static var training: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

nonisolated extension JSONDecoder {
    static var training: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
