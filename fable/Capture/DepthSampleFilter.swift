import Foundation
import simd

/// 即時與離線融合共用的深度幾何檢核。以相機空間的法向與實際視線計算入射角。
nonisolated enum DepthSampleFilter {
    static func incidenceWeight(depth: UnsafeBufferPointer<Float>, confidence: [UInt8]?,
                                u: Int, v: Int, width: Int, height: Int,
                                K: CameraIntrinsics, config: CaptureConfig) -> Float? {
        guard u > 0, v > 0, u + 1 < width, v + 1 < height,
              depth.count >= width * height, K.fx > 0, K.fy > 0 else { return nil }
        let i = v * width + u
        let z = depth[i]
        guard z.isFinite, z > config.pointMinDepthM, z < config.pointMaxDepthM else { return nil }
        // 避免在每個深度像素分配暫存陣列。
        for direction in 0..<5 {
            let n: Int
            switch direction {
            case 0: n = i
            case 1: n = i - 1
            case 2: n = i + 1
            case 3: n = i - width
            default: n = i + width
            }
            let d = depth[n]
            guard d.isFinite, d > config.pointMinDepthM, d < config.pointMaxDepthM,
                  abs(d - z) <= z * config.depthEdgeRejectRatio else { return nil }
            if let confidence {
                guard n < confidence.count, confidence[n] >= config.minDepthConfidence else { return nil }
            }
        }
        func point(_ x: Int, _ y: Int, _ d: Float) -> SIMD3<Float> {
            SIMD3((Float(x) - Float(K.cx)) * d / Float(K.fx),
                  (Float(y) - Float(K.cy)) * d / Float(K.fy), d)
        }
        let du = point(u + 1, v, depth[i + 1]) - point(u - 1, v, depth[i - 1])
        let dv = point(u, v + 1, depth[i + width]) - point(u, v - 1, depth[i - width])
        let normal = simd_cross(du, dv)
        let ray = point(u, v, z)
        let denominator = simd_length(normal) * simd_length(ray)
        guard denominator.isFinite, denominator > 1e-10 else { return nil }
        let cosine = min(1, abs(simd_dot(normal, ray)) / denominator)
        guard cosine >= cos(config.depthMaxIncidenceDeg * .pi / 180) else { return nil }
        return cosine * cosine
    }
}

/// 在初始化或重定位後等待連續穩定的追蹤，避免正常／不正常交替時立刻存入外參。
nonisolated struct TrackingStabilityGate {
    private var stableSince: TimeInterval?
    private var lastTimestamp: TimeInterval?

    mutating func reset() { stableSince = nil; lastTimestamp = nil }

    mutating func accepts(isNormal: Bool, timestamp: TimeInterval, duration: TimeInterval = 0.6) -> Bool {
        guard timestamp.isFinite, isNormal else { reset(); return false }
        if let lastTimestamp, timestamp <= lastTimestamp || timestamp - lastTimestamp > 0.25 {
            stableSince = nil
        }
        lastTimestamp = timestamp
        if stableSince == nil { stableSince = timestamp }
        return timestamp - (stableSince ?? timestamp) >= duration
    }
}
