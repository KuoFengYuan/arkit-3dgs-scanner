import Foundation

@main
struct ScanPlaybackTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fable-playback-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let scan = root.appendingPathComponent("scan_playback")
        let images = scan.appendingPathComponent("images")
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        let urls = ["frame_00001.jpg", "frame_00003.jpg", "unmatched.jpg"].map { images.appendingPathComponent($0) }
        for url in urls { try Data([0xFF, 0xD8]).write(to: url) }
        func record(_ id: Int, x: Double, file: String) -> FrameRecord {
            FrameRecord(id: id, timestamp: 100 + Double(id),
                        transform: [1,0,0,x, 0,1,0,0, 0,0,1,0, 0,0,0,1],
                        intrinsics: CameraIntrinsics(fx: 100, fy: 100, cx: 50, cy: 50, width: 100, height: 100),
                        exposureDuration: 0.01, exposureOffsetEV: 0, estimatedBlurPx: 0, imageFile: file)
        }
        let one = record(1, x: 1, file: "frame_00001.jpg")
        let two = record(2, x: 2, file: "frame_00002.jpg") // 缺少此照片
        let three = record(3, x: 3, file: "images/frame_00003.jpg")
        let frames = ScanLibrary.playbackFrames(images: urls, records: [three, two, one])
        precondition(frames.count == 3)
        precondition(frames[0].pose?.columns.3.x == 1 && frames[1].pose?.columns.3.x == 3)
        precondition(frames[1].timestamp == 103 && frames[2].pose == nil && frames[2].timestamp == nil)
        print("PASS: 缺圖及亂序紀錄以檔名配對，缺姿態的照片仍保留且不誤標位置")

        var invalid = one; invalid.transform = [1, 2]
        precondition(ScanLibrary.playbackFrames(images: urls, records: [invalid])[0].pose == nil)
        invalid.transform = one.transform; invalid.transform[3] = Double.greatestFiniteMagnitude
        invalid.timestamp = .nan
        let bad = ScanLibrary.playbackFrames(images: urls, records: [invalid])[0]
        precondition(bad.pose == nil && bad.timestamp == nil)
        invalid.imageFile = "../frame_00001.jpg"; invalid.transform = one.transform
        precondition(ScanLibrary.playbackFrames(images: urls, records: [invalid])[0].pose == nil)
        print("PASS: 損毀／溢位姿態、非有限時間與非法相對路徑不會被當成有效位置")

        let library = ScanLibrary(root: root)
        try ExportManager.writeRefinedPoses([one, two, three], to: scan.appendingPathComponent("poses.jsonl"))
        var corrected = three; corrected.transform[3] = 9
        try await library.saveReview(directory: scan,
                                     points: [CloudPoint(x: 1, y: 2, z: 3, r: 20, g: 30, b: 40)],
                                     records: [one, two, corrected])
        let entries = try await library.entries()
        let preview = try await library.preview(entries[0])
        precondition(preview.playbackFrames.count == 3)
        precondition(preview.playbackFrames[1].pose?.columns.3.x == 9)
        precondition(preview.trajectory[2].columns.3.x == 9)
        precondition(preview.playbackFrames[2].pose == nil)
        print("PASS: 歷史回放採用校正後姿態，影像標記與點雲軌跡座標一致")

        let empty = ScanLibrary.playbackFrames(images: [], records: [one])
        let legacy = ScanLibrary.playbackFrames(images: urls, records: [])
        precondition(empty.isEmpty && legacy.count == urls.count && legacy.allSatisfy { $0.pose == nil })
        print("PASS: 空紀錄及只有照片的舊掃描可安全回退")
    }
}
