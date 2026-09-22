import Foundation

@main struct CaptureMetadataTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("capture-metadata-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let legacy = root.appendingPathComponent("scan_legacy")
        let current = root.appendingPathComponent("scan_current")
        let collision = root.appendingPathComponent("scan_collision")
        for folder in [legacy, current, collision] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var count = 0
        func check(_ value: Bool, _ message: String) {
            if !value { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
            count += 1; print("PASS: \(message)")
        }
        let old = SessionMeta(device: "legacy", osVersion: "test", startedAt: "2026-09-21T01:00:00Z",
                              mode: "scene", lidarAvailable: true, lidarEnabled: false)
        let new = SessionMeta(device: "current", osVersion: "test", startedAt: "2026-09-22T01:00:00Z",
                              mode: "scene", lidarAvailable: true, lidarEnabled: true)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object["futureField"] = ["mustSurvive": true]
        let oldBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try oldBytes.write(to: legacy.appendingPathComponent("meta.json"))
        try ExportManager.writeMeta(new, to: current.appendingPathComponent(CaptureMetadata.fileName))
        check(!fm.fileExists(atPath: current.appendingPathComponent("meta.json").path), "new capture writes only capture-meta.json")
        check(CaptureMetadata.data(in: legacy) == oldBytes, "legacy metadata remains readable before export")
        let library = ScanLibrary(root: root)
        let before = try await library.entries()
        check(before.first(where: { $0.id == legacy.lastPathComponent })?.usedLiDAR == false &&
              before.first(where: { $0.id == current.lastPathComponent })?.usedLiDAR == true,
              "history reads LiDAR mode from both legacy and current filenames")
        let archive = try ExportManager.makeArchive(of: legacy)
        check(!fm.fileExists(atPath: legacy.appendingPathComponent("meta.json").path), "export migrates the conflicting legacy filename")
        check(CaptureMetadata.data(in: legacy) == oldBytes, "migration preserves exact bytes including unknown fields")
        let unzip = Process(), pipe = Pipe()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-Z1", archive.path]; unzip.standardOutput = pipe
        try unzip.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        unzip.waitUntilExit()
        let names = listing.split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent }
        check(unzip.terminationStatus == 0 && names.contains(CaptureMetadata.fileName) && !names.contains("meta.json"),
              "actual exported ZIP contains capture-meta.json and no meta.json")
        let after = try await library.entries()
        check(after.first(where: { $0.id == legacy.lastPathComponent })?.date == before.first(where: { $0.id == legacy.lastPathComponent })?.date,
              "legacy capture date remains unchanged after migration")
        try oldBytes.write(to: collision.appendingPathComponent("meta.json"))
        let newBytes = try Data(contentsOf: current.appendingPathComponent(CaptureMetadata.fileName))
        try newBytes.write(to: collision.appendingPathComponent(CaptureMetadata.fileName))
        check(CaptureMetadata.data(in: collision) == newBytes, "current metadata takes precedence when both filenames exist")
        try CaptureMetadata.migrateLegacyFile(in: collision)
        let backups = try fm.contentsOfDirectory(at: collision, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("capture-meta-legacy-") }
        let preserved = try backups.first.map { try Data(contentsOf: $0) }
        check(backups.count == 1 && preserved == oldBytes && CaptureMetadata.data(in: collision) == newBytes,
              "collision preserves both versions without overwriting current metadata")
        try CaptureMetadata.migrateLegacyFile(in: collision)
        let namesAfterRetry = try fm.contentsOfDirectory(atPath: collision.path)
        check(namesAfterRetry.count == 2 && !namesAfterRetry.contains("meta.json"), "migration is idempotent")
        check(CaptureMetadata.data(in: root) == nil, "scan without metadata remains supported")
        print("\(count) checks passed")
    }
}
