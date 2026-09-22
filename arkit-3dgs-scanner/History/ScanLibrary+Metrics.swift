import Foundation

extension ScanLibrary {
    func metricScale(_ entry: ScanEntry) throws -> SceneMetricScale {
        try validate(entry.directory)
        guard !Self.savedRecords(in: entry.directory).1 else { throw SceneMetricScale.MetricError.staleGeometry }
        return try SceneMetricScale.load(in: entry.directory)
    }
    func saveMetricScale(_ scale: SceneMetricScale, for entry: ScanEntry) throws {
        try validate(entry.directory)
        guard !Self.savedRecords(in: entry.directory).1 else { throw SceneMetricScale.MetricError.staleGeometry }
        try scale.save(in: entry.directory)
        // A changed reference must not leave a shareable archive with an old scale.
        let zip = root.appendingPathComponent(entry.directory.lastPathComponent + "-metric.zip")
        if FileManager.default.fileExists(atPath: zip.path) { try FileManager.default.removeItem(at: zip) }
    }
    func resetMetricScale(_ entry: ScanEntry) throws -> SceneMetricScale {
        try validate(entry.directory)
        guard !Self.savedRecords(in: entry.directory).1 else { throw SceneMetricScale.MetricError.staleGeometry }
        let scale = SceneMetricScale(geometrySHA256: try SceneMetricScale.fingerprint(in: entry.directory))
        try saveMetricScale(scale, for: entry)
        return scale
    }

    /// Explicit metric training export. Main scan, raw depth and standard archive stay in the capture frame.
    func metricArchive(_ entry: ScanEntry) async throws -> URL {
        try validate(entry.directory)
        guard !Self.savedRecords(in: entry.directory).1 else { throw SceneMetricScale.MetricError.staleGeometry }
        let scale = try metricScale(entry)
        let records = Self.savedRecords(in: entry.directory).0
        let root = self.root, source = entry.directory
        let worker = Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let workspace = root.appendingPathComponent(".metric-" + UUID().uuidString)
            let staging = workspace.appendingPathComponent(source.lastPathComponent + "-metric")
            try fm.createDirectory(at: staging.appendingPathComponent("images"), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: workspace) }
            let points = try Self.readPLY(SceneMetricScale.cloudURL(in: source), limit: 250_000)
            for record in records {
                try Task.checkCancellation()
                guard record.imageFile == (record.imageFile as NSString).lastPathComponent else { throw LibraryError.invalidDirectory }
                let from = source.appendingPathComponent("images").appendingPathComponent(record.imageFile)
                let to = staging.appendingPathComponent("images").appendingPathComponent(record.imageFile)
                if fm.fileExists(atPath: to.path) { continue }
                do { try fm.linkItem(at: from, to: to) } catch { try fm.copyItem(at: from, to: to) }
            }
            try ExportManager.writeTrainingDataset(records: scale.scaled(records), points: scale.scaled(points), to: staging)
            try scale.writeManifest(to: staging)
            // The references remain in source coordinates and explicitly carry their source fingerprint.
            try JSONEncoder().encode(scale).write(to: staging.appendingPathComponent("scale-measurements.json"))
            try Task.checkCancellation()
            guard scale.geometrySHA256 == (try SceneMetricScale.fingerprint(in: source)),
                  !Self.savedRecords(in: source).1,
                  try scale == SceneMetricScale.load(in: source) else {
                throw SceneMetricScale.MetricError.staleGeometry
            }
            let temporary = root.appendingPathComponent(UUID().uuidString + ".partial")
            defer { try? fm.removeItem(at: temporary) }
            try ExportManager.zipDirectory(staging, to: temporary)
            try Task.checkCancellation()
            let destination = root.appendingPathComponent(entry.directory.lastPathComponent + "-metric.zip")
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: temporary) }
            else { try fm.moveItem(at: temporary, to: destination) }
            return destination
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
