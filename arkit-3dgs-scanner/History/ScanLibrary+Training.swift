// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation

extension ScanLibrary {
    /// History entries with their on-device 3DGS state (`activeScan` is training right now,
    /// so its stored "running" status is not an interruption).
    func entriesWithTraining(activeScan: URL?) throws -> [ScanEntry] {
        try entries().map { Self.annotateTraining($0, activeScan: activeScan) }
    }

    nonisolated static func annotateTraining(_ entry: ScanEntry, activeScan: URL?) -> ScanEntry {
        var entry = entry
        let workspace = TrainingWorkspace(scan: entry.directory)
        let record = workspace.record(activeScan: activeScan)
        entry.trainingStatus = record?.status.rawValue
        entry.trainingProgress = record?.progress
        entry.hasGaussianModel = workspace.hasModel
        entry.canResumeTraining = record != nil && record?.status != .completed
            && FileManager.default.fileExists(atPath: workspace.checkpointURL.path)
        return entry
    }
}
