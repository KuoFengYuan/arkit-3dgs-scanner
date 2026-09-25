// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import Metal

/// Resumable training state in one file: a JSON header (configuration, schedule, MRNF, PPISP,
/// pose corrections, frame order) followed by the live Gaussian rows with their Adam moments.
///
/// Integrity: the header records every array's size; a 64-bit FNV-1a checksum and an end marker
/// follow the payload, so a truncated or corrupted file is rejected instead of resumed. Writes
/// go to a temporary file in the same folder that is flushed and then atomically renamed over
/// the previous checkpoint, which therefore stays valid until the new one is complete. Rows are
/// streamed in bounded chunks straight from the shared buffers (no second copy of the model).
nonisolated enum GaussianCheckpoint {
    static let fileName = "checkpoint.gsck"
    static let magic: UInt32 = 0x4B43_5347       // "GSCK"
    static let endMarker: UInt64 = 0x444E_454B_4353_4721
    /// Version 2 adds the relocation statistics; version 1 checkpoints still resume (those
    /// planes start at zero).
    static let version = 2
    static func statPlanes(version: Int) -> [Int] {
        let planes = [GaussianStats.visibility, GaussianStats.errorMax, GaussianStats.edgeSum, GaussianStats.shareMax]
        return version >= 2 ? planes + [GaussianStats.views, GaussianStats.errorSum, GaussianStats.lowWindows] : planes
    }
    static var statPlanes: [Int] { statPlanes(version: version) }

    enum CheckpointError: LocalizedError {
        case unreadable, corrupt, incompatible(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return L10n.text("找不到可用的訓練進度")
            case .corrupt: return L10n.text("訓練進度檔已損毀，無法繼續；請重新開始訓練")
            case .incompatible: return L10n.text("訓練進度與目前的掃描資料或設定不一致，請重新開始訓練")
            }
        }
    }

    struct Header: Codable {
        var version: Int
        var savedAt: Date
        var configuration: GaussianTrainingConfiguration
        var datasetSignature: String
        var iteration: Int
        var epoch: Int
        var epochPosition: Int
        var rows: Int
        var adamStep: Int
        var strategy: MRNFStrategy
        var ppisp: PPISPModel
        var poses: [PoseCorrection]
        var growthFrozen: Bool
        var elapsedSeconds: Double
        /// Floats per row of each parameter group, in layout order.
        var groupWidths: [Int]
    }

    /// Consecutive row ranges of an ascending row list.
    static func runs(_ rows: [Int]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = rows.first ?? 0, previous = start - 1
        for row in rows {
            if row != previous + 1 { result.append(start..<(previous + 1)); start = row }
            previous = row
        }
        if !rows.isEmpty { result.append(start..<(previous + 1)) }
        return result.filter { !$0.isEmpty }
    }

    /// Reads only the header (for History and resume decisions); validates magic and version.
    static func header(at url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 16), prefix.count == 16 else { return nil }
        let magic = prefix.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let length = prefix.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
        guard magic == Self.magic, length > 0, length < 64 << 20,
              let json = try? handle.read(upToCount: Int(length)), json.count == Int(length) else { return nil }
        return try? JSONDecoder().decode(Header.self, from: json)
    }

    /// Writes the trainer state atomically to `directory/checkpoint.gsck`. `formatVersion` lets
    /// tests write the previous format.
    static func save(_ trainer: GaussianTrainer, elapsedSeconds: Double, to directory: URL,
                     stagingBytes: Int = TrainingMemoryPlan.checkpointChunk, formatVersion: Int = version) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = trainer.model
        let rows = model.liveRows
        var header = Header(version: formatVersion, savedAt: Date(), configuration: trainer.configuration,
                            datasetSignature: trainer.dataset.signature, iteration: trainer.iteration,
                            epoch: trainer.epoch, epochPosition: trainer.epochPosition, rows: rows.count,
                            adamStep: model.adamStep, strategy: trainer.strategy, ppisp: trainer.ppisp,
                            poses: trainer.poses, growthFrozen: trainer.growthFrozen, elapsedSeconds: elapsedSeconds,
                            groupWidths: model.layout.groups.map(\.width))
        try trainer.flushPendingFold()
        header.strategy = trainer.strategy
        let json = try JSONEncoder().encode(header)
        let temporary = directory.appendingPathComponent(".checkpoint-\(UUID().uuidString).partial")
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw CheckpointError.unreadable }
        var published = false
        defer { if !published { try? fm.removeItem(at: temporary) } }
        let handle = try FileHandle(forWritingTo: temporary)
        var hasher = FNV64()
        var prefix = Data()
        prefix.appendLE(Self.magic)
        prefix.appendLE(UInt32(formatVersion))
        prefix.appendLE(UInt64(json.count))
        try handle.write(contentsOf: prefix)
        try handle.write(contentsOf: json)
        json.withUnsafeBytes { hasher.add($0) }
        // Payload: for params, m, v and each group, the live rows in order, then the window
        // statistics. Runs of consecutive live rows (free slots split them) are written straight
        // from the shared buffers in chunks of at most `stagingBytes`.
        let runs = Self.runs(rows)
        func write(_ base: UnsafeMutableRawPointer, bytes: Int) throws {
            var offset = 0
            while offset < bytes {
                let n = min(stagingBytes, bytes - offset)
                let chunk = UnsafeRawBufferPointer(start: base + offset, count: n)
                hasher.add(chunk)
                try handle.write(contentsOf: Data(bytesNoCopy: base + offset, count: n, deallocator: .none))
                offset += n
            }
        }
        for buffer in [model.params, model.adamM, model.adamV] {
            let source = model.floats(buffer)
            for (offset, width) in model.layout.groups where width > 0 {
                for run in runs {
                    try write(UnsafeMutableRawPointer(source + offset + run.lowerBound * width), bytes: run.count * width * 4)
                }
            }
        }
        for plane in statPlanes(version: formatVersion) {
            let source = model.stat(plane)
            for run in runs { try write(UnsafeMutableRawPointer(source + run.lowerBound), bytes: run.count * 4) }
        }
        var footer = Data()
        footer.appendLE(hasher.value)
        footer.appendLE(Self.endMarker)
        try handle.write(contentsOf: footer)
        try handle.synchronize()
        try handle.close()
        let destination = directory.appendingPathComponent(fileName)
        // rename(2) replaces the previous checkpoint atomically on the same volume.
        guard rename(temporary.path, destination.path) == 0 else { throw CheckpointError.unreadable }
        published = true
    }

    /// Validates `url` against the trainer's inputs and restores the complete training state.
    /// On any failure the trainer must be reinitialised (the model buffers may be partly written).
    static func load(_ url: URL, into trainer: GaussianTrainer) throws -> Header {
        guard let header = header(at: url) else {
            throw FileManager.default.fileExists(atPath: url.path) ? CheckpointError.corrupt : CheckpointError.unreadable
        }
        let model = trainer.model
        guard (1...version).contains(header.version) else { throw CheckpointError.incompatible("version") }
        let statPlanes = Self.statPlanes(version: header.version)
        guard header.datasetSignature == trainer.dataset.signature else { throw CheckpointError.incompatible("dataset") }
        guard header.configuration == trainer.configuration else { throw CheckpointError.incompatible("configuration") }
        guard header.groupWidths == model.layout.groups.map(\.width), header.rows <= model.capacity,
              header.ppisp.frames == trainer.dataset.frames.count, header.poses.count == trainer.dataset.frames.count else {
            throw CheckpointError.incompatible("layout")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefixLength = 16
        guard let prefix = try handle.read(upToCount: prefixLength), prefix.count == prefixLength else { throw CheckpointError.corrupt }
        let jsonLength = Int(prefix.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) })
        guard let json = try handle.read(upToCount: jsonLength), json.count == jsonLength else { throw CheckpointError.corrupt }
        var hasher = FNV64()
        json.withUnsafeBytes { hasher.add($0) }
        let rows = header.rows
        /// Reads exactly `bytes` into `destination`, hashing as it goes.
        func read(into destination: UnsafeMutableRawPointer, bytes: Int) throws {
            var offset = 0
            while offset < bytes {
                let n = min(TrainingMemoryPlan.checkpointChunk, bytes - offset)
                guard let chunk = try handle.read(upToCount: n), chunk.count == n else { throw CheckpointError.corrupt }
                chunk.withUnsafeBytes { raw in
                    hasher.add(raw)
                    (destination + offset).copyMemory(from: raw.baseAddress!, byteCount: n)
                }
                offset += n
            }
        }
        for buffer in [model.params, model.adamM, model.adamV] {
            let destination = model.floats(buffer)
            for (offset, width) in model.layout.groups where width > 0 {
                try read(into: UnsafeMutableRawPointer(destination + offset), bytes: rows * width * 4)
            }
        }
        // Statistics go to scratch first: the stats buffer is reset below before they are applied.
        var statValues: [[Float]] = []
        for _ in statPlanes {
            var values = [Float](repeating: 0, count: rows)
            try values.withUnsafeMutableBytes { try read(into: $0.baseAddress!, bytes: rows * 4) }
            statValues.append(values)
        }
        guard let footer = try handle.read(upToCount: 16), footer.count == 16 else { throw CheckpointError.corrupt }
        let checksum = footer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self) }
        let marker = footer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
        guard checksum == hasher.value, marker == endMarker, (try handle.read(upToCount: 1))?.isEmpty != false else {
            throw CheckpointError.corrupt
        }
        // Clear the rows beyond the restored count and the gradients; statistics restart.
        for buffer in [model.params, model.adamM, model.adamV] {
            let f = model.floats(buffer)
            for (offset, width) in model.layout.groups where width > 0 {
                let start = offset + rows * width, end = offset + model.capacity * width
                if end > start { (f + start).update(repeating: 0, count: end - start) }
            }
        }
        memset(model.grads.contents(), 0, model.grads.length)
        memset(model.stats.contents(), 0, model.stats.length)
        model.restore(rowCount: rows, adamStep: header.adamStep)
        for (plane, values) in zip(statPlanes, statValues) {
            let target = model.stat(plane)
            for (row, value) in values.enumerated() { target[row] = value }
        }
        trainer.strategy = header.strategy
        trainer.ppisp = header.ppisp
        trainer.poses = header.poses
        trainer.growthFrozen = header.growthFrozen
        trainer.restore(iteration: header.iteration)
        trainer.restoreOrder(epoch: header.epoch, position: header.epochPosition)
        return header
    }
}
