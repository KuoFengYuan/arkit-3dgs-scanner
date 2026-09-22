import Foundation
import simd

/// Share the same quality decision between photo capture and live point integration.
nonisolated enum CaptureBlockReason: Sendable {
    case tracking, features, motion, focus
    var message: String {
        switch self {
        case .tracking: "追蹤恢復中・請保持畫面穩定"
        case .features: "紋理不足・請對準有細節的表面"
        case .motion: "移動過快・放慢後自動繼續"
        case .focus: "等待畫面清晰・請稍停讓對焦穩定"
        }
    }
}

nonisolated enum CaptureQualityPolicy {
    /// The full-frame rolling readout contributes geometric skew, not exposure blur.
    /// Keep it in the recorded risk score, but don't add it to the live photo stop threshold.
    static func exposureBlur(totalRisk: Float, exposure: Double, readout: Double) -> Float {
        guard totalRisk.isFinite, exposure.isFinite, exposure >= 0, readout.isFinite, readout >= 0 else { return .infinity }
        let total = exposure + readout
        return total > 0 ? max(0, totalRisk) * Float(exposure / total) : 0
    }

    static func blockReason(tracking: Bool, sufficientFeatures: Bool, blur: Float,
                            angular: Float, linear: Float, sharpnessRatio: Float,
                            config: CaptureConfig) -> CaptureBlockReason? {
        if !tracking { return .tracking }
        if !sufficientFeatures { return .features }
        if !blur.isFinite || !angular.isFinite || !linear.isFinite
            || blur > config.blockBlurPixels || angular > config.keyframeMaxAngularSpeedRadS
            || linear > config.keyframeMaxLinearSpeedMS { return .motion }
        if !sharpnessRatio.isFinite || sharpnessRatio < config.minSharpnessRatio { return .focus }
        return nil
    }
}

/// Windowed signed displacement avoids rectifying millimetre position noise into sustained speed.
/// Quaternions avoid the unstable acos(trace) estimate for near-identity rotations.
nonisolated struct CaptureMotionEstimator {
    struct Sample { let pose: simd_float4x4; let time: Double }
    struct Estimate { let angular: Float; let linear: Float }
    private var samples: [Sample] = []
    private var smoothedAngular: Float = 0
    mutating func reset() { samples.removeAll(keepingCapacity: true); smoothedAngular = 0 }

    mutating func update(pose: simd_float4x4, timestamp: Double, gyroRate: Float? = nil,
                         gyroTimestamp: Double? = nil) -> Estimate {
        guard timestamp.isFinite else { reset(); return Estimate(angular: 0, linear: 0) }
        if let last = samples.last, timestamp <= last.time || timestamp - last.time > 0.25 { reset() }
        let last = samples.last
        samples.append(Sample(pose: pose, time: timestamp))
        while samples.count > 2 && samples[1].time <= timestamp - 0.08 { samples.removeFirst() }
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
        var angular: Float = 0
        if let last {
            let q = simd_normalize(simd_quatf(last.pose).inverse * simd_quatf(pose))
            angular = 2 * atan2(simd_length(q.imag), abs(q.real)) / Float(timestamp - last.time)
        }
        // A gyro reading from "now" must not reject an older, already exposed ARFrame.
        if let rate = gyroRate, rate.isFinite, rate >= 0, let time = gyroTimestamp,
           abs(time - timestamp) <= 0.02 { angular = max(angular, rate) }
        let dt = last.map { timestamp - $0.time } ?? 1.0 / 60
        let blend = Float(1 - exp(-dt / 0.045))
        smoothedAngular += (angular - smoothedAngular) * blend
        var linear: Float = 0
        if let first = samples.first, timestamp > first.time {
            let delta = pose.columns.3 - first.pose.columns.3
            linear = simd_length(SIMD3(delta.x, delta.y, delta.z)) / Float(timestamp - first.time)
        }
        return Estimate(angular: max(angular, smoothedAngular), linear: linear)
    }
}

nonisolated struct SharpnessReference {
    private var peak: Float = 0
    private var lastTime: Double?
    mutating func reset() { peak = 0; lastTime = nil }
    mutating func ratio(value: Float, timestamp: Double, severeMotion: Bool) -> Float {
        guard value.isFinite, value >= 0 else { return 1 }
        let dt = lastTime.map { max(0, min(0.25, timestamp - $0)) } ?? 1.0 / 60
        lastTime = timestamp
        // Only severe motion freezes the reference. Ordinary scanning into a less textured
        // surface must not stay compared with the previous detailed surface indefinitely.
        let decay: Float = severeMotion ? 1 : Float(pow(0.97, dt * 60))
        peak = max(value, peak * decay)
        return peak > 1e-6 ? value / peak : 1
    }
}
