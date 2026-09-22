import Foundation
import simd
@main struct CaptureQualityPolicyTests {
 static func main() {
  var count = 0
  func check(_ condition: Bool, _ message: String) { precondition(condition, message); count += 1; print("PASS: \(message)") }
  let cfg = CaptureConfig()
  func reason(_ blur: Float = 5, angular: Float = 0.3, linear: Float = 0.1, sharp: Float = 1,
              tracking: Bool = true, features: Bool = true) -> CaptureBlockReason? {
    CaptureQualityPolicy.blockReason(tracking: tracking, sufficientFeatures: features, blur: blur,
                                     angular: angular, linear: linear, sharpnessRatio: sharp, config: cfg)
  }
  check(reason() == nil, "ordinary scanning motion remains accepted")
  check(reason(15) == nil, "warning-level blur is a hint and does not pause capture")
  check(reason(30) == .motion && reason(5, angular: 2) == .motion, "severe blur and fast turns still block all capture")
  check(reason(5, sharp: 0.2) == .focus, "focus failure blocks both photos and live geometry through one policy")
  check(reason(tracking: false) == .tracking && reason(features: false) == .features, "tracking and texture failures have explicit reasons")
  check(reason(.nan) == .motion, "invalid quality measurements cannot enter the geometry pipeline")
  var jitter = CaptureMotionEstimator()
  var measured: Float = 0
  for i in 0..<120 {
    var p = matrix_identity_float4x4; p.columns.3.x = i % 2 == 0 ? 0.002 : -0.002
    let estimate = jitter.update(pose: p, timestamp: Double(i) / 60)
    if i > 10 { measured = max(measured, estimate.linear) }
  }
  check(measured < 0.07, "2mm pose jitter does not become a sustained 0.24m/s movement")
  var movement = CaptureMotionEstimator(); var velocity: Float = 0
  for i in 0..<120 {
    var p = matrix_identity_float4x4; p.columns.3.x = Float(i) / 60 * 0.3
    velocity = movement.update(pose: p, timestamp: Double(i) / 60).linear
  }
  check(abs(velocity - 0.3) < 0.001, "windowed speed preserves real 0.3m/s translation")
  var gyro = CaptureMotionEstimator()
  _ = gyro.update(pose: matrix_identity_float4x4, timestamp: 1)
  let stale = gyro.update(pose: matrix_identity_float4x4, timestamp: 1.016, gyroRate: 2, gyroTimestamp: 1.08)
  check(stale.angular == 0, "newer gyro samples do not reject an older stationary camera frame")
  let aligned = gyro.update(pose: matrix_identity_float4x4, timestamp: 1.032, gyroRate: 2, gyroTimestamp: 1.033)
  check(aligned.angular == 2, "time-aligned gyro spikes remain guarded")
  var rotation = CaptureMotionEstimator()
  _ = rotation.update(pose: matrix_identity_float4x4, timestamp: 1)
  let rotated = simd_float4x4(simd_quatf(angle: 0.02, axis: SIMD3(0,1,0)))
  check(abs(rotation.update(pose: rotated, timestamp: 1.02).angular - 1) < 0.001, "quaternion angular speed retains true rapid rotation")
  var reference = SharpnessReference()
  _ = reference.ratio(value: 1, timestamp: 0, severeMotion: false)
  var ratio: Float = 0
  for i in 1...60 { ratio = reference.ratio(value: 0.2, timestamp: Double(i) / 60, severeMotion: false) }
  check(ratio > cfg.minSharpnessRatio, "ordinary movement into a less textured surface can recover its sharpness reference")
  reference.reset(); _ = reference.ratio(value: 1, timestamp: 0, severeMotion: false)
  for i in 1...120 { ratio = reference.ratio(value: 0.2, timestamp: Double(i) / 60, severeMotion: true) }
  check(ratio < cfg.minSharpnessRatio, "severe continuous motion cannot lower the sharpness baseline to pass")
  var shutter = SmartShutter()
  check(shutter.isDue(pose: matrix_identity_float4x4, time: 0, config: cfg), "first viewpoint is due")
  check(shutter.isDue(pose: matrix_identity_float4x4, time: 0.01, config: cfg), "failed image copy does not consume the pending viewpoint")
  shutter.markCaptured(pose: matrix_identity_float4x4, time: 0.01)
  check(!shutter.isDue(pose: matrix_identity_float4x4, time: 0.2, config: cfg), "accepted viewpoint stops duplicate photos until the camera moves")
  let walkingRisk: Float = 31.9 // 1.1 m/s, 1 m range, 0.1 rad/s, fx 1450, 1/120 s exposure + 10 ms readout
  let walkingExposure = CaptureQualityPolicy.exposureBlur(totalRisk: walkingRisk, exposure: 1.0/120, readout: 0.01)
  check(walkingRisk > cfg.blockBlurPixels && walkingExposure < cfg.blockBlurPixels,
        "rolling readout risk no longer masquerades as exposure blur")
  check(reason(walkingExposure, angular: 0.1, linear: 1.1, sharp: 0.8) == nil,
        "clear ordinary walking frames at 1.1m/s remain capturable")
  let darkExposure = CaptureQualityPolicy.exposureBlur(totalRisk: 75.4, exposure: 1.0/30, readout: 0.01)
  check(reason(darkExposure, angular: 0.1, linear: 1.1) == .motion,
        "long-exposure walking blur still rejects genuinely risky frames")
  check(reason(5, linear: 2.0) == .motion,
        "fast travel remains gated even under short exposure")
  func translated(_ x: Float) -> simd_float4x4 {
    var pose = matrix_identity_float4x4; pose.columns.3.x = x; return pose
  }
  var dense = SmartShutter()
  dense.markCaptured(pose: matrix_identity_float4x4, time: 0)
  check(dense.isDue(pose: translated(0.051), time: 0.11, config: cfg), "5cm translation now captures instead of waiting for 10cm")
  let turn = simd_float4x4(simd_quatf(angle: 3.1 * .pi / 180, axis: SIMD3(0,1,0)))
  check(dense.isDue(pose: turn, time: 0.11, config: cfg), "LiDAR captures a new 3-degree view instead of waiting for 6 degrees")
  check(!dense.isDue(pose: translated(0.2), time: 0.09, config: cfg), "dense capture still enforces the 100ms write rate ceiling")
  check(dense.isDue(pose: translated(0.2), time: 0.11, config: cfg), "walking can capture again after 100ms")
  check(dense.isDue(pose: translated(0.026), time: 0.11, config: cfg, estimatedDepth: 0.5), "nearby LiDAR surfaces receive more overlapping views")
  check(!dense.isDue(pose: translated(0.026), time: 0.11, config: cfg, cameraOnly: true, estimatedDepth: 0.5), "denser RGB capture retains the 4cm triangulation baseline")
  check(dense.isDue(pose: translated(0.041), time: 0.11, config: cfg, cameraOnly: true, estimatedDepth: 0.5), "RGB accepts the next useful nearby baseline")
  check(!dense.isDue(pose: turn, time: 1, config: cfg, cameraOnly: true), "RGB still rejects rotation without a new camera center")
  check(!dense.isDue(pose: matrix_identity_float4x4, time: 100, config: cfg), "standing still does not create redundant photos")
  var trajectory = SmartShutter(); var captures: [Double] = []
  for i in 0...120 {
    let time = Double(i) / 60
    if trajectory.shouldCapture(pose: translated(Float(time) * 0.3), time: time, config: cfg) { captures.append(time) }
  }
  check(captures.count >= 11 && zip(captures, captures.dropFirst()).allSatisfy { $1 - $0 >= 0.1 },
        "0.3m/s trajectory captures at least 11 spaced views over two seconds")
  print("\(count) checks passed")
 }
}
