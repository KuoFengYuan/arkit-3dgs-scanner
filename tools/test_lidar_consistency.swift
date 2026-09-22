import Foundation
import simd
import CoreGraphics
import ImageIO

private final class PressureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

@main struct LiDARConsistencyTests {
    static func main() throws {
        setbuf(stdout,nil)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1; print("PASS: \(message)")
        }
        let cfg = CaptureConfig()
        let k = CameraIntrinsics(fx: 100, fy: 100, cx: 16, cy: 12, width: 32, height: 24)
        func view(_ depth: Float, confidence: UInt8 = 2, camera: simd_float4x4 = matrix_identity_float4x4) -> DepthConsistencyView {
            let values = [Float](repeating: depth, count: k.width * k.height)
            return DepthConsistencyView(depth: values.withUnsafeBufferPointer { Data(buffer: $0) },
                                        confidence: [UInt8](repeating: confidence, count: values.count), intrinsics: k, c2w: camera)!
        }
        func point(_ z: Float) -> CloudPoint { CloudPoint(x: 0, y: 0, z: -z, r: 100, g: 110, b: 120) }
        let wall = view(2)
        check(wall.agreement(SIMD3(0, 0, -2), config: cfg) == .supported, "matching wall depth is supported")
        check(wall.agreement(SIMD3(0, 0, -1.9), config: cfg) == .contradicted, "foreground ghost conflicts with measured free space")
        check(wall.agreement(SIMD3(0, 0, -2.1), config: cfg) == .occluded, "hidden background is treated as occlusion")
        check(wall.agreement(SIMD3(4, 0, -2), config: cfg) == .unobserved, "out-of-view points are not false contradictions")
        check(view(2, confidence: 0).agreement(SIMD3(0, 0, -2), config: cfg) == .unobserved,
              "low-confidence samples cannot validate geometry")
        check(DepthConsistencyView.filter([point(1.9), point(2), point(2.1)], against: [wall, wall], config: cfg).count == 1,
              "front and back ghost layers are removed while true wall survives")
        let noisy = view(2.1)
        check(DepthConsistencyView.filter([point(2)], against: [wall, noisy, wall], config: cfg).count == 1,
              "one erroneous depth view cannot veto two agreeing measurements")
        check(DepthConsistencyView.filter([point(2)], against: [wall, noisy, noisy], config: cfg).isEmpty,
              "a minority agreeing view cannot validate a conflicting surface")
        check(DepthConsistencyView.filter([point(2)], against: [view(1), wall], config: cfg).count == 1,
              "a foreground occluder does not erase independently supported background")
        check(DepthConsistencyView.filter([point(2)], against: [], config: cfg).isEmpty,
              "geometry without independent support is not promoted")
        var camera = matrix_identity_float4x4; camera.columns.3.z = 0.2
        check(view(2.2, camera: camera).agreement(SIMD3(0, 0, -2), config: cfg) == .supported,
              "depth agreement uses each camera pose, not raw depth equality")
        var edgeValues = [Float](repeating: 2, count: k.width * k.height)
        edgeValues[12 * k.width + 17] = 3
        let edge = DepthConsistencyView(depth: edgeValues.withUnsafeBufferPointer { Data(buffer: $0) }, confidence: nil,
                                        intrinsics: k, c2w: matrix_identity_float4x4)!
        check(edge.agreement(SIMD3(0, 0, -2), config: cfg) == .unobserved, "depth discontinuities do not bilinearly invent surfaces")
        let corrected = DepthConsistencyView.consensus([point(2.015)], camera: .zero,
                                                       against: [wall, wall], config: cfg)
        check(corrected.count == 1 && abs(corrected[0].z + 2) < 1e-5,
              "two agreeing depth references correct a noisy source sample onto the plane")
        var tight = cfg; tight.depthConsensusMaxShiftM = 0.005
        let bounded = DepthConsistencyView.consensus([point(2.015)], camera: .zero,
                                                     against: [wall, wall], config: tight)
        check(bounded.count == 1 && abs(bounded[0].z + 2.015) < 1e-5,
              "consensus cannot exceed its configured displacement bound")
        let offAxis = CloudPoint(x: 0.1, y: 0.08, z: -2.015, r: 99, g: 80, b: 70)
        let rayResult = DepthConsistencyView.consensus([offAxis], camera: .zero,
                                                       against: [wall, wall], config: cfg)[0]
        check(abs(rayResult.x / rayResult.z - offAxis.x / offAxis.z) < 1e-6 &&
              abs(rayResult.y / rayResult.z - offAxis.y / offAxis.z) < 1e-6 && rayResult.r == 99,
              "depth correction preserves source RGB pixel coordinates and color")
        check(DepthConsistencyView.consensus([point(2)], camera: .zero,
                    against: [wall, view(1), view(1)], config: cfg).isEmpty,
              "one visible reference among occluders is insufficient for multi-view consensus")
        check(DepthConsistencyView.consensus([point(2)], camera: .zero,
                    against: [wall, wall, view(1), view(1)], config: cfg).count == 1,
              "two visible references preserve a real background despite foreground occlusion")
        let layers = DepthConsistencyView.consensus([point(1), point(2)], camera: .zero,
                    against: [view(1), view(1), wall, wall, wall], config: cfg)
        check(layers.count == 1 && abs(layers[0].z + 2) < 1e-6,
              "free-space contradictions remove unsupported foreground without averaging the layers")
        check(DepthConsistencyView.consensus([point(2)], camera: .zero,
                    against: [wall, edge, view(2, confidence: 0)], config: cfg).isEmpty,
              "edges and unreliable confidence cannot supply the second consensus vote")
        check(DepthConsistencyView.filter([point(2)], against: [wall, view(1)], config: cfg,
                    minimumSupports: 2).isEmpty, "mesh supplementation also needs two visible supports")
        // A slanted camera observes a planar world surface at varying camera-space depth.
        let tilted = simd_float4x4(simd_quatf(angle: 0.06, axis: SIMD3(0, 1, 0)))
        var tiltedDepth = [Float](repeating: 0, count: k.width * k.height)
        for v in 0..<k.height { for u in 0..<k.width {
            let direction = tilted * SIMD4(Float((Double(u)-k.cx)/k.fx), Float((k.cy-Double(v))/k.fy), -1, 0)
            tiltedDepth[v*k.width+u] = -2 / direction.z
        } }
        let tiltedView = DepthConsistencyView(depth: tiltedDepth.withUnsafeBufferPointer { Data(buffer: $0) },
                                             confidence: nil, intrinsics: k, c2w: tilted)!
        let oblique = DepthConsistencyView.consensus([point(2.015)], camera: .zero,
                    against: [wall, tiltedView], config: cfg)
        check(oblique.count == 1 && abs(oblique[0].z + 2) < 0.0001,
              "ray consensus handles rotated reference cameras with the correct depth derivative")
        var gate = TemporalDepthConsistency()
        check(gate.filter([point(2)], view: wall, timestamp: 0, epoch: 0, config: cfg).isEmpty,
              "first live depth frame only establishes a reference")
        check(gate.filter([point(2), point(1.9)], view: wall, timestamp: 0.1, epoch: 0, config: cfg).count == 1,
              "next live frame promotes stable points and rejects transients")
        check(gate.filter([point(2)], view: wall, timestamp: 0.2, epoch: 1, config: cfg).isEmpty,
              "relocalization invalidates temporal geometry comparisons")
        check(gate.filter([point(2)], view: wall, timestamp: 2, epoch: 1, config: cfg).isEmpty,
              "long frame gaps do not reuse stale depth")
        check(gate.filter([point(2)], view: wall, timestamp: 2, epoch: 1, config: cfg).isEmpty,
              "duplicate timestamps do not count as independent support")

        var queue = DirtyTileQueue()
        for key: Int64 in 0..<100 { queue.insert(key) }
        for _ in 0..<1000 { queue.insert(0) }
        check(queue.count == 100, "repeated tile edits coalesce to bounded pending work")
        var visited = [Int64]()
        for _ in 0..<100 { visited.append(queue.popFirst()!); queue.insert(0) }
        check(Set(visited).count == 100 && visited == Array(Int64(0)..<100),
              "continuously changing hot tile cannot starve 99 older pending tiles")
        _ = queue.popFirst()
        check(queue.count == 0 && queue.popFirst() == nil, "pending render work drains without any new capture")
        for key: Int64 in 0..<4000 { queue.insert(key) }
        for expected: Int64 in 0..<4000 { precondition(queue.popFirst() == expected) }
        check(queue.count == 0, "queue compaction preserves order over long scans")

        var grid = TiledFusedGrid(voxelSize: 0.01, tileSize: 1.2, maxCells: 1000)
        let samples = (0..<3).flatMap { tile in (0..<10).map { i in
            CloudPoint(x: Float(tile) * 1.2 + 0.1 + Float(i) * 0.02, y: 0.2, z: 0.3, r: 20, g: 30, b: 40)
        } }
        grid.insert(samples, anchorTransforms: [:], cameraPosition: .zero)
        let first = grid.popDirtyTiles(limit: 8, pointBudget: 15)
        check(first.count == 1 && grid.pendingRenderTileCount == 2, "point budget splits render updates into small batches")
        let second = grid.popDirtyTiles(limit: 8, pointBudget: 1)
        check(second.count == 1, "oversized individual tile still makes progress")
        check(grid.popDirtyTiles(limit: 8, pointBudget: 100).count == 1 && grid.pendingRenderTileCount == 0,
              "all tiles eventually render even when camera stops producing geometry")
        check(grid.pendingAnchorSnapshot().count == 3 && grid.pendingAnchorSnapshot().count == 3,
              "cancelled render batches do not lose unregistered anchors")
        grid.acknowledgeAnchors([grid.pendingAnchorSnapshot()[0].0])
        check(grid.pendingAnchorSnapshot().count == 2, "only applied anchors are acknowledged")
        grid.markAllDirty()
        check(grid.pendingRenderTileCount == 3, "resume can redraw tiles whose previous batch was cancelled")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fable-depth-consistency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("depth"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var records = [FrameRecord]()
        for frame in 0..<5 {
            let z: Float = frame == 1 ? 1.9 : (frame == 3 ? 2.1 : 2)
            let depths = [Float](repeating: z, count: k.width * k.height)
            try depths.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("depth/\(frame).bin"))
            let rgba = [UInt8](repeating: 180, count: k.width * k.height * 4)
            let provider = CGDataProvider(data: Data(rgba) as CFData)!
            let image = CGImage(width: k.width, height: k.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: k.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let destination = CGImageDestinationCreateWithURL(dir.appendingPathComponent("images/\(frame).jpg") as CFURL,
                                                               "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
            var pose = matrix_identity_float4x4; pose.columns.3.x = Float(frame) * 0.02
            records.append(FrameRecord(id: frame, timestamp: Double(frame) * 0.15, transform: RefusionEngine.rowMajor(pose),
                                        intrinsics: k, exposureDuration: 0.005, exposureOffsetEV: 0, estimatedBlurPx: 0,
                                        imageFile: "\(frame).jpg", depthFile: "\(frame).bin", depthWidth: k.width, depthHeight: k.height))
        }
        var referenceRecords = records
        for i in referenceRecords.indices {
            referenceRecords[i].timestamp = Double(i) * 0.3
            referenceRecords[i].transform[3] = [0, 0.01, 0.15, -0.15, 0.3][i]
        }
        let diverse = DepthReferenceSelection(records: referenceRecords).indices(for: 0)
        check(diverse.prefix(3) == [2, 3, 4] && diverse.count <= 4 && !diverse.contains(0),
              "reference lookup prefers separated camera positions before near-duplicate frames")
        referenceRecords[2].blurVerdict = .drop
        referenceRecords[3].transform = []
        let validReferences = DepthReferenceSelection(records: referenceRecords).indices(for: 0)
        check(!validReferences.contains(2) && !validReferences.contains(3),
              "reference selection excludes rejected and malformed poses")
        for i in referenceRecords.indices { referenceRecords[i].transform = RefusionEngine.rowMajor(matrix_identity_float4x4) }
        let stationary = DepthReferenceSelection(records: referenceRecords).indices(for: 0)
        check(!stationary.isEmpty && stationary.count <= 4,
              "stationary scans fall back to bounded temporal references")
        var enabled = cfg; enabled.refuseMinNeighbors = 0
        var disabled = enabled; disabled.depthConsistencyEnabled = false
        let meshGhost = [SIMD3<Float>(0.13, 0.05, -1.94)]
        let old = RefusionEngine.refuse(records: records, sessionDir: dir, config: disabled, meshVertices: meshGhost, progress: { _ in })
        let cleaned = RefusionEngine.refuse(records: records, sessionDir: dir, config: enabled, meshVertices: meshGhost, progress: { _ in })
        check(old.contains { abs($0.z + 2) > 0.05 }, "synthetic disk fixture reproduces the original multi-layer wall")
        check(cleaned.count > 100, "cross-frame filtering preserves supported wall coverage")
        check(cleaned.allSatisfy { abs($0.z + 2) < 0.03 }, "full refusion removes both 10cm ghost layers and mesh refill")
        check(!cleaned.contains { abs($0.z + 1.94) < 0.005 }, "mesh cannot reintroduce a rejected surface under its old 10cm color tolerance")
        let mib: UInt64 = 1_024 * 1_024
        let completedTwoFrames = PressureFlag()
        let interrupted = RefusionEngine.refuseWithReport(records: records, sessionDir: dir, config: enabled,
            availableMemory: { completedTwoFrames.value ? 80*mib : 512*mib },
            progress: { p in if p >= 0.35 { completedTwoFrames.set() } })
        check(interrupted.report.status == "memoryPressure" && interrupted.report.completedFrames == 2,
              "memory pressure arriving midway stops before decoding the next frame")
        check(interrupted.points.isEmpty && interrupted.report.peakCells > 0,
              "partial fusion is not presented as a completed model")
        let saved = try JSONDecoder().decode(RefusionEngine.Report.self, from: Data(contentsOf: dir.appendingPathComponent("refusion-progress.json")))
        check(saved.status == "memoryPressure" && saved.minimumAvailableBytes == 80 * mib,
              "on-disk report preserves the stopping frame and minimum headroom")
        check(records.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/" + $0.imageFile).path) },
              "memory fallback preserves every source image")
        let completedFrames = PressureFlag()
        let exportStop = RefusionEngine.refuseWithReport(records: records, sessionDir: dir, config: enabled,
            availableMemory: { completedFrames.value ? 80*mib : 512*mib },
            progress: { p in if p >= 0.9 { completedFrames.set() } })
        check(exportStop.report.status == "memoryPressure" && exportStop.report.stage == "exportFilter" && exportStop.report.boundedExport && exportStop.report.completedFrames == 5,
              "pressure before output allocation also takes the safe fallback")
        let reduceHeadroom = PressureFlag()
        let afterDecode = RefusionEngine.refuseWithReport(records: records, sessionDir: dir, config: enabled,
            availableMemory: { reduceHeadroom.value ? 300*mib : 512*mib },
            progress: { p in if p >= 0.18 { reduceHeadroom.set() } })
        check(afterDecode.report.status == "completed" && afterDecode.report.capacityReductions > 0,
              "declining headroom above the reserve reduces capacity before subsequent insertion")
        let device = RefusionEngine.refuseWithReport(records: records, sessionDir: dir, config: enabled, target: 150,
            availableMemory: { 512 * mib }, progress: { _ in })
        check(device.report.status == "completed" && device.report.boundedExport && device.points.count <= 150 && !device.points.isEmpty,
              "device-style bounded processing finishes and respects the output cap")
        check(device.points.allSatisfy { abs($0.z + 2) < 0.03 }, "bounded output still rejects ghost layers")
        print("\(checks) checks passed")
    }
}
