import Foundation

extension ScanLibrary {
    nonisolated struct OptimizationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Publish a new history entry only after images, poses, cloud and COLMAP agree.
    /// Source scans are never overwritten. Hard links avoid duplicating original media storage.
    func optimizeTraining(_ entry: ScanEntry,
                          progress: @escaping @Sendable (String, Double) -> Void) async throws -> ScanEntry {
        try validate(entry.directory)
        let records = Self.savedRecords(in: entry.directory).0
        let root = self.root
        let worker = Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let staging = root.appendingPathComponent(".optimizing-" + UUID().uuidString)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let source = entry.directory
            let annotated = BlurFilter.annotate(records)
            progress(L10n.text("逐張匹配拍攝影像…"), 0)
            let refined = await OfflinePoseRefinement.run(records: annotated, directory: source, rounds: 6, surfaceRefinement:true,
                isCancelled: { Task.isCancelled }, progress: { progress($0 >= 0.85 ? L10n.text("驗證局部表面對齊…") : $0 >= 0.595 ? L10n.text("搜尋並驗證重訪視角…") : L10n.text("逐張匹配與驗證相機位置…"), $0 * 0.45) })
            try Task.checkCancellation()
            if ["memoryPressure", "observationBudgetExceeded"].contains(refined.report.status) {
                throw OptimizationError(message: L10n.text("目前資源不足以完成相機精修，原始掃描未變更。請關閉其他工作後重試。"))
            }
            let outputRecords = refined.records
            var points: [CloudPoint] = []
            if outputRecords.contains(where: { $0.depthFile != nil }) {
                progress(L10n.text("用修正後位置重融合深度…"), 0.45)
                var cfg = CaptureConfig()
                cfg.surfaceReconstruction = true
                let fusion = RefusionEngine.refuseWithReport(records: outputRecords, sessionDir: source, config: cfg,
                    meshVertices: [], target: cfg.exportMaxPoints, diagnosticsDirectory: staging, isCancelled: { Task.isCancelled },
                    progress: { progress(L10n.text("用修正後位置重融合深度…"), 0.45 + $0 * 0.4) })
                try Task.checkCancellation()
                guard fusion.report.status != "memoryPressure", !fusion.points.isEmpty else {
                    throw OptimizationError(message: L10n.text("深度不足或記憶體不足，未發布新的優化版本；原始掃描仍保留。"))
                }
                points = fusion.points
                try JSONEncoder().encode(fusion.report).write(to: staging.appendingPathComponent("refusion-progress.json"))
            } else {
                // Camera-only data still benefits from RGB selection; do not claim LiDAR BA ran.
                for name in ["review.ply", "points.ply"] {
                    if let saved = try? Self.readPLY(source.appendingPathComponent(name), limit: 250_000) {
                        points = saved; break
                    }
                }
            }
            progress(L10n.text("挑選清晰照片並準備訓練資料…"), 0.86)
            for name in ["images", "depth"] {
                let folder = source.appendingPathComponent(name)
                guard fm.fileExists(atPath: folder.path) else { continue }
                let dest = staging.appendingPathComponent(name)
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
                    try Task.checkCancellation()
                    guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
                    let target = dest.appendingPathComponent(file.lastPathComponent)
                    do { try fm.linkItem(at: file, to: target) }
                    catch { try fm.copyItem(at: file, to: target) }
                }
            }
            let raw = source.appendingPathComponent("poses.jsonl")
            if fm.fileExists(atPath: raw.path) { try fm.copyItem(at: raw, to: staging.appendingPathComponent("poses.jsonl")) }
            if let data = CaptureMetadata.data(in: source),
               var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                meta["startedAt"] = ISO8601DateFormatter().string(from: Date())
                meta["optimizedFrom"] = entry.id
                try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]).write(to: staging.appendingPathComponent(CaptureMetadata.fileName))
            }
            try ExportManager.writePLY(points, to: staging.appendingPathComponent("review.ply"))
            try ExportManager.writeRefinedPoses(outputRecords, to: staging.appendingPathComponent("review-poses.jsonl"))
            try JSONEncoder().encode(Summary(version: 1, frameCount: outputRecords.count, pointCount: points.count))
                .write(to: staging.appendingPathComponent("scan-summary.json"))
            try JSONEncoder().encode(refined.report).write(to: staging.appendingPathComponent("pose-refinement.json"))
            try ExportManager.writeTrainingDataset(records: outputRecords, points: points, to: staging)
            try Task.checkCancellation()
            guard fm.fileExists(atPath: source.path) else { throw LibraryError.invalidDirectory }
            let target = root.appendingPathComponent("scan_optimized_" + UUID().uuidString)
            try fm.moveItem(at: staging, to: target) // same-volume publish after all artifacts succeed
            progress(L10n.text("優化版本已儲存"), 1)
            return target
        }
        let destination = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                onCancel: { worker.cancel() })
        guard let result = try entries().first(where: { $0.directory.standardizedFileURL.path == destination.standardizedFileURL.path }) else { throw LibraryError.invalidDirectory }
        return result
    }

    func poseRefinementNotice(_ entry: ScanEntry) -> String? {
        guard let data = try? Data(contentsOf: entry.directory.appendingPathComponent("pose-refinement.json")),
              let report = try? JSONDecoder().decode(OfflinePoseRefinement.Report.self, from: data) else { return nil }
        return report.notice
    }

    func trainingSelection(_ entry: ScanEntry) -> TrainingFrameSelector.Report? {
        guard let data = try? Data(contentsOf: entry.directory.appendingPathComponent("training-selection.json")) else { return nil }
        return try? JSONDecoder().decode(TrainingFrameSelector.Report.self, from: data)
    }
}
