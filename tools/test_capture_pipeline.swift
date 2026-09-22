// Regression: successful writes, failed writes, closed writers and atomic archive retries.
// swiftc -module-cache-path /tmp/fable-swift-cache fable/Capture/Models.swift \
//   fable/Capture/BlurFilter.swift fable/Capture/FrameWriter.swift \
//   fable/Capture/ExportManager.swift tools/test_capture_pipeline.swift -o /tmp/test_capture_pipeline
import Foundation
import CoreVideo
import simd

@main
struct CapturePipelineTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fable-tests-" + UUID().uuidString)
        let scan = root.appendingPathComponent("scan", isDirectory: true)
        try fm.createDirectory(at: scan, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        precondition(status == kCVReturnSuccess)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        func keyframe(_ id: Int, imageFile: String) -> Keyframe {
            let record = FrameRecord(id: id, timestamp: Double(id),
                transform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
                intrinsics: CameraIntrinsics(fx: 16, fy: 16, cx: 8, cy: 8, width: 16, height: 16),
                exposureDuration: 1.0 / 60, exposureOffsetEV: 0, estimatedBlurPx: 0,
                imageFile: imageFile)
            return Keyframe(pixelBuffer: pixels, depthData: nil, confidenceData: nil,
                            depthWidth: 0, depthHeight: 0, c2w: matrix_identity_float4x4, record: record)
        }
        let writer = try FrameWriter(sessionDir: scan, saveDepth: false, jpegQuality: 0.9)
        let enqueuedAt = ProcessInfo.processInfo.systemUptime - 0.025
        let timing = try await writer.write(keyframe(1, imageFile: "frame_00001.jpg"), enqueuedAt: enqueuedAt)
        precondition(timing.queueMS.isFinite && timing.queueMS >= 25)
        precondition(timing.jpegMS.isFinite && timing.jpegMS >= 0)
        precondition(timing.fileWriteMS.isFinite && timing.fileWriteMS >= 0)
        print("PASS: writer reports queue delay separately from finite JPEG and I/O timings")
        var records = await writer.snapshotRecords()
        precondition(records.count == 1)
        precondition(fm.fileExists(atPath: scan.appendingPathComponent("images/frame_00001.jpg").path))
        print("PASS: saved count includes only successfully persisted images")

        do {
            try await writer.write(keyframe(2, imageFile: "missing/frame_00002.jpg"))
            fatalError("write failure was swallowed")
        } catch { }
        records = await writer.snapshotRecords()
        precondition(records.count == 1)
        try await writer.write(keyframe(3, imageFile: "frame_00003.jpg"))
        records = await writer.snapshotRecords()
        precondition(records.map(\.id) == [1, 3])
        let lines = try String(contentsOf: scan.appendingPathComponent("poses.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        let decoded = try lines.map { try JSONDecoder().decode(FrameRecord.self, from: Data($0.utf8)) }
        precondition(decoded.map(\.id) == [1, 3])
        print("PASS: write failure propagates; retry preserves valid JSONL and prior records")

        try ExportManager.writeColmapSparse(records: records, points: [], to: scan)
        let zip = try ExportManager.makeArchive(of: scan)
        let firstArchive = try Data(contentsOf: zip)
        precondition(firstArchive.prefix(2) == Data([0x50, 0x4b]))
        // Writer stays open after export preparation failures, so continuation can still append.
        try await writer.write(keyframe(4, imageFile: "frame_00004.jpg"))
        let replacement = try ExportManager.makeArchive(of: scan)
        precondition(replacement == zip)
        let secondArchive = try Data(contentsOf: zip)
        precondition(secondArchive != firstArchive)
        try fm.moveItem(at: scan, to: root.appendingPathComponent("saved-scan"))
        do {
            _ = try ExportManager.makeArchive(of: scan)
            fatalError("archive of missing source succeeded")
        } catch { }
        let preserved = try Data(contentsOf: zip)
        precondition(preserved == secondArchive)
        let contents = try fm.contentsOfDirectory(atPath: root.path)
        precondition(!contents.contains { $0.hasSuffix(".partial") })
        print("PASS: archive replacement succeeds; failed retry preserves prior ZIP and removes temporary output")

        _ = await writer.finish()
        do {
            try await writer.write(keyframe(5, imageFile: "frame_00005.jpg"))
            fatalError("closed writer accepted a frame")
        } catch FrameWriter.WriteError.closed { }
        print("PASS: closed writer explicitly rejects new frames")
    }
}
