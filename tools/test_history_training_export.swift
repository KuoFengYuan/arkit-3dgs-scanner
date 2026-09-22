import Foundation

@main struct HistoryTrainingExportTests {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAILED: \(error)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fable-training-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let scan = root.appendingPathComponent("scan_fixture")
        try fm.createDirectory(at: scan.appendingPathComponent("images"), withIntermediateDirectories: true)
        let library = ScanLibrary(root: root)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
            checks += 1; print("PASS: \(message)")
        }
        func record(_ id: Int) -> FrameRecord {
            FrameRecord(id: id, timestamp: Double(id), transform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
                        intrinsics: CameraIntrinsics(fx: 100, fy: 101, cx: 50, cy: 40, width: 100, height: 80),
                        exposureDuration: 0.005, exposureOffsetEV: 0, estimatedBlurPx: 2, imageFile: "frame_\(id).jpg")
        }
        let raw = [record(1), record(2), record(3)]
        for r in raw { try Data("image \(r.id)".utf8).write(to: scan.appendingPathComponent("images/" + r.imageFile)) }
        try ExportManager.writeRefinedPoses(raw, to: scan.appendingPathComponent("poses.jsonl"))
        var reviewed = raw
        reviewed[0].transform[3] = 1.25
        reviewed[1].blurVerdict = .demote
        reviewed[2].blurVerdict = .drop
        let points = [CloudPoint(x: 0.1, y: 0.2, z: -2, r: 100, g: 120, b: 140)]
        try await library.saveReview(directory: scan, points: points, records: reviewed)
        let entry = try await library.entries()[0]
        let stale = try ExportManager.makeArchive(of: scan)
        let staleBytes = try Data(contentsOf: stale)
        check(!fm.fileExists(atPath: scan.appendingPathComponent("sparse/0").path), "fixture reproduces preview-only export without COLMAP")
        let archive = try await library.archive(entry)
        let repairedBytes = try Data(contentsOf: archive)
        check(archive.standardizedFileURL.path == stale.standardizedFileURL.path && repairedBytes != staleBytes, "history replaces the incomplete existing ZIP")
        let sparse = scan.appendingPathComponent("sparse/0")
        let cameras = try Data(contentsOf: sparse.appendingPathComponent("cameras.bin"))
        let images = try Data(contentsOf: sparse.appendingPathComponent("images.bin"))
        let seeds = try Data(contentsOf: sparse.appendingPathComponent("points3D.bin"))
        func uint64(_ data: Data, _ offset: Int = 0) -> UInt64 { data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) } }
        func number(_ data: Data, _ offset: Int) -> Double { Double(bitPattern: uint64(data, offset)) }
        check(uint64(cameras) == 1 && uint64(images) == 1, "only keep frames enter cameras.bin and images.bin")
        check(cameras.count == 64 && number(cameras, 32) == 100, "camera binary contains PINHOLE dimensions and intrinsics")
        check(abs(number(images, 44) + 1.25) < 1e-9, "export uses corrected review poses instead of raw ARKit positions")
        check(uint64(seeds) == 1 && abs(number(seeds, 32) - 2) < 1e-6, "point coordinates use the same world flip as the cameras")
        let exported = ScanLibrary.readRecords(scan.appendingPathComponent("poses_refined.jsonl"))
        check(exported.count == 1 && exported[0].transform[3] == 1.25, "refined sidecar matches training cameras")
        check(ScanLibrary.readRecords(scan.appendingPathComponent("poses.jsonl")).count == 3, "raw poses and excluded source photos remain preserved")
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-Z1", archive.path]
        let pipe = Pipe(); unzip.standardOutput = pipe
        try unzip.run(); let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); unzip.waitUntilExit()
        check(unzip.terminationStatus == 0 && ["cameras.bin", "images.bin", "points3D.bin", "points.ply", "poses_refined.jsonl", "frame_1.jpg"].allSatisfy { listing.contains($0) }, "actual ZIP includes the complete dataset and images")
        let originalArchive = try Data(contentsOf: archive)
        try fm.removeItem(at: scan.appendingPathComponent("images/frame_1.jpg"))
        do { _ = try await library.archive(entry); preconditionFailure("missing image should fail") }
        catch ExportManager.TrainingExportError.missingImage { checks += 1; print("PASS: missing training photo prevents a misleading successful export") }
        check((try Data(contentsOf: archive)) == originalArchive, "failed export preserves the previous valid ZIP")
        try Data("restored".utf8).write(to: scan.appendingPathComponent("images/frame_1.jpg"))
        var invalid = record(1); invalid.transform = [1]
        do { try ExportManager.writeTrainingDataset(records: [invalid], points: points, to: scan); preconditionFailure("invalid pose should fail") }
        catch ExportManager.TrainingExportError.invalidFrame { checks += 1; print("PASS: malformed pose cannot crash binary pose conversion") }
        do { try ExportManager.writeTrainingDataset(records: [], points: points, to: scan); preconditionFailure("empty model should fail") }
        catch ExportManager.TrainingExportError.noUsableFrames { checks += 1; print("PASS: no usable poses reports a clear error instead of silently omitting sparse") }
        // A saved zero-point scan can still export calibrated images, but never stale seed points.
        try ExportManager.writeTrainingDataset(records: [record(1)], points: [], to: scan)
        let emptySeeds = try Data(contentsOf: sparse.appendingPathComponent("points3D.bin"))
        let emptyPLY = try ScanLibrary.readPLY(scan.appendingPathComponent("points.ply"), limit: 100)
        check(uint64(emptySeeds) == 0 && emptyPLY.isEmpty,
              "zero-point dataset replaces stale PLY and still has a valid binary header")
        print("\(checks) checks passed")
    }
}
