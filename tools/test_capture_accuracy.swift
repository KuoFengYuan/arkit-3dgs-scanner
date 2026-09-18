import Foundation
import simd

@main
struct CaptureAccuracyTests {
    static func main() {
        var failures = 0
        func check(_ success: Bool, _ message: String) {
            print("\(success ? "PASS" : "FAIL"): \(message)")
            if !success { failures += 1 }
        }
        var gate = TrackingStabilityGate()
        var ready = false
        for i in 0...42 { ready = gate.accepts(isNormal: true, timestamp: Double(i) / 60) }
        check(ready, "連續穩定追蹤後可擷取")
        check(!gate.accepts(isNormal: false, timestamp: 0.72), "追蹤遺失立即停止擷取")
        check(!gate.accepts(isNormal: true, timestamp: 0.74), "恢復第一幀不能直接擷取")
        check(!gate.accepts(isNormal: true, timestamp: 3), "長時間無新幀重新等待穩定")

        var transform = matrix_identity_float4x4
        let delta = PoseRefiner.deltaTransform(omega: SIMD3(0.005, -0.01, 0.012), trans: .zero, about: .zero)
        for _ in 0..<1000 { transform = delta * transform }
        let rotation = simd_float3x3(SIMD3(transform[0].x, transform[0].y, transform[0].z),
                                    SIMD3(transform[1].x, transform[1].y, transform[1].z),
                                    SIMD3(transform[2].x, transform[2].y, transform[2].z))
        check(abs(simd_determinant(rotation) - 1) < 0.0002,
              "1000 次姿態增量仍保持剛體旋轉，不累積縮放")

        let K = CameraIntrinsics(fx: 100, fy: 100, cx: 2, cy: 2, width: 5, height: 5)
        let config = CaptureConfig()
        let flat = [Float](repeating: 2, count: 25)
        let confidence = [UInt8](repeating: 2, count: 25)
        func weight(_ depth: [Float], _ conf: [UInt8] = [UInt8](repeating: 2, count: 25), _ intrinsics: CameraIntrinsics = K) -> Float? {
            depth.withUnsafeBufferPointer {
                DepthSampleFilter.incidenceWeight(depth: $0, confidence: conf, u: 2, v: 2,
                                                  width: 5, height: 5, K: intrinsics, config: config)
            }
        }
        check(abs((weight(flat) ?? 0) - 1) < 1e-6, "正面平面保留完整權重")
        for neighbor in [11, 13, 7, 17] {
            var edge = flat; edge[neighbor] = 3
            check(weight(edge) == nil, "拒絕深度邊緣（鄰點 \(neighbor)）")
        }
        var low = confidence; low[11] = 0
        check(weight(flat, low) == nil, "低信心鄰點不能形成可信法向")
        var offAxis = K; offAxis.cx = -98
        check(abs((weight(flat, confidence, offAxis) ?? 0) - 0.5) < 0.001,
              "畫面邊緣按真實視線計算入射角，而非視為正面")
        check(PointCloudMath.voxelKey(SIMD3(.nan, 0, 0), size: 0.01) == nil,
              "非有限座標不會造成整數轉換崩潰")

        let measured = CloudPoint(x: 0.001, y: 0.002, z: 0.003, r: 80, g: 90, b: 100)
        let mesh = CloudPoint(x: 0.018, y: 0.002, z: 0.003, r: 250, g: 0, b: 0, score: 0.25)
        var grid = FusedVoxelGrid(voxelSize: 0.02, maxCells: 1000)
        grid.insert([measured])
        for _ in 0..<100 { grid.insert([mesh], measured: false) }
        var point = grid.exportPoints(target: 100, minNeighbors: 0)[0]
        check(abs(point.x - measured.x) < 1e-7 && point.r == measured.r,
              "100 次網格補洞不會拉偏 LiDAR 量測或顏色")
        var reverse = FusedVoxelGrid(voxelSize: 0.02, maxCells: 1000)
        reverse.insert([mesh], measured: false); reverse.insert([measured])
        point = reverse.exportPoints(target: 100, minNeighbors: 0)[0]
        check(abs(point.x - measured.x) < 1e-7, "較晚取得的 LiDAR 量測取代網格推論")
        var coarse = FusedVoxelGrid(voxelSize: 0.01, maxCells: 2)
        coarse.insert([measured]); coarse.insert([mesh], measured: false)
        let output = coarse.exportPoints(target: 100, minNeighbors: 0)
        check(output.count == 1 && abs(output[0].x - measured.x) < 1e-7,
              "記憶體降採樣仍保留量測優先規則")

        var tiled = TiledFusedGrid(voxelSize: 0.01, tileSize: 1.2, maxCells: 1000)
        var p = CloudPoint(x: 1.195, y: 0.437, z: 0.353, r: 100, g: 100, b: 100)
        tiled.insert([p], anchorTransforms: [:], cameraPosition: SIMD3(0, 0, 0))
        let anchor = tiled.takePendingAnchors()[0]
        var corrected = matrix_identity_float4x4
        corrected.columns.3 = SIMD4(anchor.1 + SIMD3(0.04, 0, 0), 1)
        p.x += 0.04
        tiled.insert([p], anchorTransforms: [anchor.0: corrected], cameraPosition: SIMD3(0.04, 0, 0))
        check(tiled.count == 1, "錨點修正跨越世界磚邊界不產生第二層點")
        corrected.columns.3.x += 0.1
        tiled.updateAnchorTransforms([anchor.0: corrected])
        let updated = tiled.exportPoints(target: 100)[0]
        check(abs(updated.x - (p.x + 0.1)) < 1e-5, "停止時沒有再觀測的磚也套用最新錨點姿態")
        exit(failures == 0 ? 0 : 1)
    }
}
