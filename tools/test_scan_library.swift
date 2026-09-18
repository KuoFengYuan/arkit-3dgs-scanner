import Foundation

@main
struct ScanLibraryTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fable-history-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let library = ScanLibrary(root: root)
        let legacy = root.appendingPathComponent("scan_legacy")
        let current = root.appendingPathComponent("scan_current")
        for directory in [legacy, current] {
            try fm.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
            try Data([0xFF, 0xD8]).write(to: directory.appendingPathComponent("images/frame_00001.jpg"))
        }
        let meta = SessionMeta(device: "test", osVersion: "test", startedAt: "2026-09-18T01:00:00Z",
                               mode: "scene", lidarAvailable: true, lidarEnabled: false)
        try ExportManager.writeMeta(meta, to: current.appendingPathComponent("meta.json"))
        let points = [CloudPoint(x: 1, y: 2, z: 3, r: 10, g: 20, b: 30),
                      CloudPoint(x: 4, y: 5, z: 6, r: 40, g: 50, b: 60)]
        try await library.saveReview(directory: current, points: points, records: [])
        var entries = try await library.entries()
        precondition(entries.count == 2)
        let newEntry = entries.first { $0.id == "scan_current" }!
        precondition(newEntry.usedLiDAR == false && newEntry.pointCount == 2)
        let preview = try await library.preview(newEntry)
        precondition(preview.points.count == 2 && preview.points[1].z == 6 && preview.images.count == 1)
        print("PASS: 自動保存的歷史點雲可讀取，並保留 LiDAR 開關標記")
        let oldEntry = entries.first { $0.id == "scan_legacy" }!
        let oldPreview = try await library.preview(oldEntry)
        precondition(oldPreview.points.isEmpty && oldPreview.images.count == 1 && oldPreview.note != nil)
        print("PASS: 沒有索引與點雲的舊版掃描仍可列出及查看影像")
        let ply = current.appendingPathComponent("review.ply")
        var truncated = try Data(contentsOf: ply); truncated.removeLast()
        let damaged = root.appendingPathComponent("damaged.ply")
        try truncated.write(to: damaged)
        do { _ = try ScanLibrary.readPLY(damaged, limit: 100); fatalError("損毀 PLY 未被拒絕") }
        catch ScanLibrary.LibraryError.damagedPLY { }
        let bounded = try ScanLibrary.readPLY(ply, limit: 1)
        precondition(bounded.count == 1)
        print("PASS: 預覽點數有界，截斷 PLY 會回報錯誤")
        let archive = root.appendingPathComponent("scan_current.zip")
        try Data("zip".utf8).write(to: archive)
        try await library.delete(newEntry)
        entries = try await library.entries()
        precondition(entries.count == 1 && entries[0].id == "scan_legacy")
        precondition(!fm.fileExists(atPath: archive.path))
        precondition(fm.fileExists(atPath: legacy.path))
        print("PASS: 刪除選定掃描與同名 ZIP，不影響其他歷史紀錄")
        // 使用與正式掃描相同的檔案位置，確認整個資料樹而非只有列表索引被刪除。
        let paths = ["images/frame_00001.jpg", "depth/frame_00001.bin", "gaussians.ply",
                     "floorplan.usdz", "review.ply", "poses.jsonl", "sparse/0/points3D.bin"]
        let batchDirs = ["scan_batch_a", "scan_batch_b", "scan_keep"].map { root.appendingPathComponent($0) }
        for directory in batchDirs {
            for relative in paths {
                let file = directory.appendingPathComponent(relative)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: file)
            }
            try Data("zip".utf8).write(to: root.appendingPathComponent(directory.lastPathComponent + ".zip"))
        }
        entries = try await library.entries()
        let selected = entries.filter { $0.id.hasPrefix("scan_batch_") }
        precondition(selected.count == 2)
        // 重複項目不會重複刪除造成錯誤。
        try await library.delete(selected + [selected[0]])
        for directory in batchDirs.prefix(2) {
            precondition(!fm.fileExists(atPath: directory.path))
            precondition(!fm.fileExists(atPath: root.appendingPathComponent(directory.lastPathComponent + ".zip").path))
            for relative in paths { precondition(!fm.fileExists(atPath: directory.appendingPathComponent(relative).path)) }
        }
        for relative in paths { precondition(fm.fileExists(atPath: batchDirs[2].appendingPathComponent(relative).path)) }
        print("PASS: 多選刪除包含照片、模型、深度、COLMAP 與 ZIP；未選掃描完整保留")
        let snapshot = try await library.entries()
        let later = root.appendingPathComponent("scan_after_confirmation")
        try fm.createDirectory(at: later, withIntermediateDirectories: true)
        try await library.delete(snapshot)
        entries = try await library.entries()
        precondition(entries.count == 1 && entries[0].id == later.lastPathComponent)
        precondition(!fm.fileExists(atPath: legacy.path))
        precondition(!fm.fileExists(atPath: batchDirs[2].path))
        precondition(!fm.fileExists(atPath: root.appendingPathComponent("scan_keep.zip").path))
        print("PASS: 全部刪除移除確認時的所有掃描，不波及確認後新增資料")
        try await library.delete([])
        let missing = ScanEntry(id: "scan_missing", directory: root.appendingPathComponent("scan_missing"),
                                date: Date(), frameCount: 0, pointCount: nil, usedLiDAR: nil, cover: nil, archive: nil)
        do { try await library.delete(entries + [missing]); fatalError("無效批次應拒絕") }
        catch ScanLibrary.LibraryError.invalidDirectory { }
        precondition(fm.fileExists(atPath: later.path))
        print("PASS: 空批次安全，無效路徑會在任何刪除前拒絕整批操作")
        let link = root.appendingPathComponent("scan_link")
        try fm.createSymbolicLink(at: link, withDestinationURL: later)
        entries = try await library.entries()
        precondition(entries.count == 1)
        print("PASS: 不將符號連結當成可刪除的掃描紀錄")
    }
}
