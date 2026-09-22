// swiftc -O fable/Capture/{Models,BlurFilter,CaptureConfig,Utils,SmartShutter,DepthSampleFilter,CameraOnlyGeometry,SparseLandmarkFilter}.swift tools/test_camera_only_accuracy.swift -o /tmp/camera-accuracy && /tmp/camera-accuracy
import Foundation
import simd

@main
struct CameraOnlyAccuracyTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1; print("PASS: \(message)")
        }
        let cfg = CaptureConfig()
        let K = CameraIntrinsics(fx: 100, fy: 100, cx: 50, cy: 50, width: 100, height: 100)
        let identity = matrix_identity_float4x4
        let front = SIMD3<Float>(0, 0, -2)
        let center = CameraOnlyGeometry.project(front, worldToCamera: identity, intrinsics: K, minDepth: 0.25, maxDepth: 5)!
        check(center.u == 50 && center.v == 50 && center.depth == 2, "ARKit -Z 前方正確投影到影像中心")
        check(CameraOnlyGeometry.project(SIMD3(0, 0, 2), worldToCamera: identity, intrinsics: K, minDepth: 0.25, maxDepth: 5) == nil,
              "背後特徵不參與距離／上色")
        check(CameraOnlyGeometry.project(SIMD3(.nan, 0, -2), worldToCamera: identity, intrinsics: K, minDepth: 0.25, maxDepth: 5) == nil,
              "非有限點不傳入投影／voxel")
        check(CameraOnlyGeometry.project(SIMD3(20, 0, -2), worldToCamera: identity, intrinsics: K, minDepth: 0.25, maxDepth: 5) == nil,
              "畫面外特徵不參與紋理覆蓋")
        let points = (0..<27).map { n in SIMD3<Float>(Float(n % 3 - 1) * 0.6, Float(n / 3 % 3 - 1) * 0.6, -2) }
        let coverage = CameraOnlyGeometry.assess(points: points, c2w: identity, intrinsics: K, config: cfg)
        check(coverage.visibleCount == 27 && coverage.occupiedCells == 9, "分布到全畫面的特徵具有九格覆蓋")
        let clustered = CameraOnlyGeometry.assess(points: Array(repeating: front, count: 30), c2w: identity, intrinsics: K, config: cfg)
        check(clustered.occupiedCells == 1, "單一角落的密集特徵不冒充全畫面紋理")
        let mixedDepth = [Float](repeating: 1, count: 8) + [Float](repeating: 4, count: 12)
        let depth = CameraOnlyGeometry.assess(points: mixedDepth.map { SIMD3<Float>(0, 0, -$0) }, c2w: identity, intrinsics: K, config: cfg)
        check(depth.estimatedDepth == 1, "近側距離估計不被遠處背景掩蓋")
        let blur = CameraOnlyGeometry.blurPixels(angularSpeed: 0, linearSpeed: 0.3, depth: nil, focalLength: 1000, exposure: 0.01, config: cfg)
        let farBlur = CameraOnlyGeometry.blurPixels(angularSpeed: 0, linearSpeed: 0.3, depth: 4, focalLength: 1000, exposure: 0.01, config: cfg)
        check(blur > 0 && blur > farBlur * 7, "沒有 LiDAR 仍計入平移模糊，缺深度使用保守距離")

        var filter = SparseLandmarkFilter()
        func observe(_ t: Double, _ x: Float, _ p: SIMD3<Float> = front, _ epoch: Int = 0) -> Bool {
            filter.accept(id: 42, position: p, camera: SIMD3(x, 0, 0), time: t, epoch: epoch, config: cfg)
        }
        check(!observe(0, 0), "單次特徵估計不直接寫進點雲")
        check(!observe(0, 0.2), "同影格重複 ID 不增加觀測次數")
        check(!observe(0.2, 0) && !observe(0.4, 0), "原地重複觀測沒有視差，不當作精確幾何")
        check(observe(0.6, 0.12), "穩定特徵跨視角具足夠基線／視差才收錄")
        check(!observe(0.8, 0.2) && filter.acceptedCount == 1, "同一 ID 只融入一次，避免重複投票／殘影")
        var unstable = SparseLandmarkFilter()
        _ = unstable.accept(id: 1, position: front, camera: .zero, time: 0, epoch: 0, config: cfg)
        _ = unstable.accept(id: 1, position: front, camera: SIMD3(0.05, 0, 0), time: 0.2, epoch: 0, config: cfg)
        check(!unstable.accept(id: 1, position: front + SIMD3(0.3, 0, 0), camera: SIMD3(0.15, 0, 0), time: 0.4, epoch: 0, config: cfg),
              "漂移不穩的特徵重建候選，不直接污染點雲")
        check(!unstable.accept(id: 1, position: front, camera: SIMD3(0.2, 0, 0), time: 0.6, epoch: 1, config: cfg),
              "追蹤座標修正後不混用修正前的候選")
        check(!unstable.accept(id: 1, position: front, camera: SIMD3(0.3, 0, 0), time: 4, epoch: 1, config: cfg),
              "相隔過久的 ID 不沿用過期觀測")
        var cap = cfg; cap.sparseMaxCandidates = 2
        var bounded = SparseLandmarkFilter()
        for id: UInt64 in 0..<100 { _ = bounded.accept(id: id, position: front, camera: .zero, time: 0, epoch: 0, config: cap) }
        check(bounded.pendingCount == 2, "候選記憶體有界")

        var rgb = SmartShutter(), lidar = SmartShutter()
        _ = rgb.shouldCapture(pose: identity, time: 0, config: cfg, cameraOnly: true)
        _ = lidar.shouldCapture(pose: identity, time: 0, config: cfg)
        var rotated = simd_float4x4(simd_quatf(angle: .pi / 8, axis: SIMD3(0, 1, 0)))
        check(!rgb.shouldCapture(pose: rotated, time: 0.3, config: cfg, cameraOnly: true), "RGB 原地旋轉不塞入缺乏基線的關鍵幀")
        check(lidar.shouldCapture(pose: rotated, time: 0.3, config: cfg), "LiDAR 原有旋轉抓幀行為維持")
        rotated.columns.3.x = 0.06
        check(rgb.shouldCapture(pose: rotated, time: 0.5, config: cfg, cameraOnly: true), "RGB 增加側向基線後恢復抓幀")
        rgb.reset(); _ = rgb.shouldCapture(pose: identity, time: 0, config: cfg, cameraOnly: true)
        var nearPose = identity; nearPose.columns.3.x = 0.05
        check(rgb.shouldCapture(pose: nearPose, time: 0.3, config: cfg, cameraOnly: true, estimatedDepth: 0.5), "近距離 RGB 以較密視角保持重疊")

        var continuity = PoseContinuityGate()
        check(continuity.accepts(identity, timestamp: 0), "首個有限姿態可建立連續性基準")
        var normal = identity; normal.columns.3.x = 0.01
        check(continuity.accepts(normal, timestamp: 1.0 / 60), "正常手持移動不誤判為座標突跳")
        var jump = identity; jump.columns.3.x = 0.5
        check(!continuity.accepts(jump, timestamp: 2.0 / 60), "normal 追蹤下的 49cm 突跳仍會被隔離")
        check(continuity.accepts(jump, timestamp: 3.0 / 60), "以修正後座標重新建立穩定追蹤基準")
        check(!continuity.accepts(jump, timestamp: 2), "長影格間隔重新等待穩定")
        print("\(checks) checks passed")
    }
}
