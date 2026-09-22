import Foundation
import simd

/// RGB 模式的幾何檢查。稀疏特徵僅用於距離估計與觀測驗證，不視為 LiDAR 深度。
nonisolated enum CameraOnlyGeometry {
    struct Projection {
        let u: Float
        let v: Float
        let depth: Float
    }
    struct Assessment {
        var visibleCount = 0
        var occupiedCells = 0
        var estimatedDepth: Float?
    }

    static func project(_ world: SIMD3<Float>, worldToCamera: simd_float4x4,
                        intrinsics K: CameraIntrinsics, minDepth: Float, maxDepth: Float) -> Projection? {
        guard K.width > 0, K.height > 0, K.fx.isFinite, K.fy.isFinite, K.cx.isFinite, K.cy.isFinite,
              K.fx > 0, K.fy > 0 else { return nil }
        let camera = worldToCamera * SIMD4<Float>(world, 1)
        let depth = -camera.z
        guard camera.x.isFinite, camera.y.isFinite, depth.isFinite,
              depth >= minDepth, depth <= maxDepth else { return nil }
        let u = Float(K.fx) * camera.x / depth + Float(K.cx)
        let v = Float(K.cy) - Float(K.fy) * camera.y / depth
        guard u.isFinite, v.isFinite,
              u >= 0, u < Float(K.width), v >= 0, v < Float(K.height) else { return nil }
        return Projection(u: u, v: v, depth: depth)
    }

    static func assess(points: [SIMD3<Float>], c2w: simd_float4x4,
                       intrinsics: CameraIntrinsics, config: CaptureConfig) -> Assessment {
        let inverse = c2w.inverse
        var result = Assessment()
        var cells: Set<Int> = []
        var depths: [Float] = []
        // 主執行緒有界取樣；不能讓影像品質檢查餓死 ARKit。
        let step = max(1, Int(ceil(Double(points.count) / 512)))
        for i in stride(from: 0, to: points.count, by: step) {
            guard let p = project(points[i], worldToCamera: inverse, intrinsics: intrinsics,
                                  minDepth: config.pointMinDepthM, maxDepth: config.pointMaxDepthM) else { continue }
            let u = p.u / Float(intrinsics.width), v = p.v / Float(intrinsics.height)
            guard u >= 0.05, u < 0.95, v >= 0.05, v < 0.95 else { continue }
            result.visibleCount += 1
            cells.insert(min(2, Int(u * 3)) + 3 * min(2, Int(v * 3)))
            if u > 0.2, u < 0.8, v > 0.2, v < 0.8 { depths.append(p.depth) }
        }
        result.occupiedCells = cells.count
        if depths.count >= 6 {
            depths.sort()
            // 近側四分位數避免遠處背景掩蓋前景的平移模糊。
            result.estimatedDepth = depths[depths.count / 4]
        }
        return result
    }

    static func blurPixels(angularSpeed: Float, linearSpeed: Float, depth: Float?,
                           focalLength: Float, exposure: Double, config: CaptureConfig) -> Float {
        let distance = depth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? config.cameraOnlyFallbackDepthM
        return (max(0, angularSpeed) + max(0, linearSpeed) / max(0.1, distance))
            * focalLength * Float(exposure + config.rollingShutterReadoutS)
    }
}

/// 即使 trackingState = normal，座標突跳仍須先暫停，重新等追蹤穩定。
nonisolated struct PoseContinuityGate {
    private var last: (pose: simd_float4x4, time: Double)?
    mutating func reset() { last = nil }

    mutating func accepts(_ pose: simd_float4x4, timestamp: Double) -> Bool {
        guard timestamp.isFinite,
              (0..<4).allSatisfy({ c in (0..<4).allSatisfy { pose[c][$0].isFinite } }) else {
            reset(); return false
        }
        let previous = last
        last = (pose, timestamp)
        guard let previous else { return true }
        let dt = timestamp - previous.time
        guard dt > 0, dt <= 0.25 else { return false }
        let delta = pose.columns.3 - previous.pose.columns.3
        let translation = simd_length(SIMD3<Float>(delta.x, delta.y, delta.z))
        let a = simd_float3x3(columns: (xyz(previous.pose[0]), xyz(previous.pose[1]), xyz(previous.pose[2])))
        let b = simd_float3x3(columns: (xyz(pose[0]), xyz(pose[1]), xyz(pose[2])))
        let rotation = a.transpose * b
        let cosine = (rotation[0][0] + rotation[1][1] + rotation[2][2] - 1) * 0.5
        let angle = acos(min(1, max(-1, cosine)))
        return translation <= max(0.08, Float(dt) * 3) && angle <= max(.pi / 12, Float(dt) * 4)
    }
    private func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
}
