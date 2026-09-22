//
//  QualityMonitor.swift
//  fable — 即時品質監控：角速度 / 動態模糊估計 / 光線 / 距離 / 追蹤狀態
//

import Foundation
import ARKit
import CoreMotion
import simd

/// 品質問題種類。rawValue 越小優先度越高（HUD 只顯示最嚴重的一項）。
/// 是否暫停抓幀由 QualityAssessment.captureBlocked 決定（兩級門檻），
/// 一般警告只提醒、不擋拍。
nonisolated enum QualityIssue: Int, CaseIterable, Identifiable, Sendable, Comparable {
    case trackingLost
    case insufficientFeatures
    case tooFast
    case notSharp
    case deviceHot
    case tooDark
    case tooBright
    case tooClose
    case tooFar

    var id: Int { rawValue }

    static func < (lhs: QualityIssue, rhs: QualityIssue) -> Bool { lhs.rawValue < rhs.rawValue }

    var message: String {
        switch self {
        case .trackingLost: L10n.text("追蹤不穩，請放慢並對準紋理豐富的區域")
        case .insufficientFeatures: L10n.text("可追蹤紋理不足，請對準有細節的區域並緩慢側向移動")
        case .tooFast:      L10n.text("移動太快會產生動態模糊，請放慢")
        case .notSharp:     L10n.text("畫面不夠清晰，請稍停讓對焦穩定")
        case .deviceHot:    L10n.text("裝置過熱，建議暫停散熱")
        case .tooDark:      L10n.text("光線不足，請補光或移至較亮處")
        case .tooBright:    L10n.text("光線過強，注意過曝")
        case .tooClose:     L10n.text("距離太近，請後退一點")
        case .tooFar:       L10n.text("距離太遠，請靠近目標")
        }
    }

    var symbol: String {
        switch self {
        case .trackingLost: "wifi.exclamationmark"
        case .insufficientFeatures: "viewfinder"
        case .tooFast:      "hare.fill"
        case .notSharp:     "camera.metering.none"
        case .deviceHot:    "thermometer.high"
        case .tooDark:      "moon.fill"
        case .tooBright:    "sun.max.fill"
        case .tooClose:     "arrow.down.right.and.arrow.up.left"
        case .tooFar:       "arrow.up.left.and.arrow.down.right"
        }
    }
}

nonisolated struct QualityAssessment: Sendable {
    var issues: [QualityIssue] = []
    var blurPixels: Float = 0
    var exposureBlurPixels: Float = 0
    var centerDepthM: Float = -1
    var depthIsEstimated = false
    var visibleFeatureCount = 0
    var featureCoverageCells = 0
    var angularSpeedRadS: Float = 0
    var linearSpeedMS: Float = 0
    /// 影像清晰度的**直接量測**（歸一化二階差分能量）。負值 = 量不到。
    /// blurPixels 是由「角速度 × 曝光時間」推估的，只涵蓋動態模糊；
    /// 這一項才看得到失焦、對焦來回搜尋（AF hunting）、鏡頭霧氣等推估看不到的原因。
    var sharpness: Float = -1
    /// 清晰度相對於「近 0.5 秒內同一場景達到過的最佳值」的比例（0...1）。
    /// 絕對清晰度與場景紋理量綁死（白牆再清晰也是低值），只有相對值可以設門檻。
    var sharpnessRatio: Float = 1
    /// 追蹤丟失、RGB 紋理不足或嚴重模糊時暫停抓幀。
    var captureBlocked = false
    var blockReason: CaptureBlockReason?

    var allowCapture: Bool { !captureBlocked }
    var worst: QualityIssue? {
        switch blockReason {
        case .tracking: return .trackingLost
        case .features: return .insufficientFeatures
        case .motion: return .tooFast
        case .focus: return .notSharp
        case nil: return issues.min()
        }
    }
    /// Short autofocus transitions stop accepting data but do not flash a red warning.
    var showsBlockingWarning: Bool {
        captureBlocked && (blockReason != .focus || issues.contains(.notSharp))
    }
}

/// 每個 ARFrame 呼叫一次 assess()。角速度用該影格姿態差分，僅以時間相符的陀螺儀補強。
/// RGB 幾何檢查最多取樣 512 點，避免在 session delegate 熱路徑無界計算。
final class QualityMonitor {

    private static let kNotSharpFrames = 15
    private let motion = CMMotionManager()
    private var motionEstimator = CaptureMotionEstimator()
    private var sharpnessReference = SharpnessReference()
    private var notSharpStreak = 0

    func start() {
        motionEstimator.reset()
        sharpnessReference.reset()
        notSharpStreak = 0
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates()   // 不帶 handler，由 assess() 輪詢最新值
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    /// 中斷／座標修正後不以跨跳躍差分當作真實速度。
    func resetTrackingHistory() {
        motionEstimator.reset()
        sharpnessReference.reset()
    }

    func assess(frame: ARFrame, config: CaptureConfig, useLiDAR: Bool = true) -> QualityAssessment {
        var a = QualityAssessment()
        let camera = frame.camera

        // 1. 追蹤狀態
        switch camera.trackingState {
        case .normal: break
        default: a.issues.append(.trackingLost)
        }

        // Time-aligned angular rate and net displacement over ~80ms suppress pose jitter.
        let gyro = motion.deviceMotion
        let rate = gyro.map { value -> Float in
            let r = value.rotationRate
            return Float(sqrt(r.x * r.x + r.y * r.y + r.z * r.z))
        }
        let velocity = motionEstimator.update(pose: camera.transform, timestamp: frame.timestamp,
                                              gyroRate: rate, gyroTimestamp: gyro?.timestamp)
        a.angularSpeedRadS = velocity.angular
        a.linearSpeedMS = velocity.linear

        // 3. LiDAR 距離，或 RGB 可見特徵的保守近側距離估計。
        if useLiDAR, let depthMap = frame.sceneDepth?.depthMap {
            a.centerDepthM = Self.centerMedianDepth(depthMap)
        } else if !useLiDAR {
            let k = camera.intrinsics
            let size = camera.imageResolution
            let geometry = CameraOnlyGeometry.assess(points: frame.rawFeaturePoints?.points ?? [],
                c2w: camera.transform,
                intrinsics: CameraIntrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]),
                                             cx: Double(k[2][0]), cy: Double(k[2][1]),
                                             width: Int(size.width), height: Int(size.height)), config: config)
            a.centerDepthM = geometry.estimatedDepth ?? -1
            a.depthIsEstimated = true
            a.visibleFeatureCount = geometry.visibleCount
            a.featureCoverageCells = geometry.occupiedCells
            if geometry.visibleCount < config.cameraOnlyMinVisibleFeatures
                || geometry.occupiedCells < config.cameraOnlyMinFeatureCells {
                a.issues.append(.insufficientFeatures)
            }
        }

        // 4. 幾何劣化估計：像素位移 ≈ (ω + v/z) × fx × (曝光時間 + 捲簾讀出時間)
        //    平移項以中心景深歸一化。
        //
        //    為什麼要加上捲簾讀出時間 —— 原本只算曝光時間，於是「亮處」被系統性低估：
        //    明亮辦公室 AE 會縮到 1/250s，1 rad/s 的轉動只估出 6px，看起來完全合格；
        //    但 CMOS 是逐列讀出的，整幀跨越約 10ms，這段時間內相機仍在轉 →
        //    畫面上下兩端對應不同的相機姿態，變成剪切變形（skew），
        //    對 3DGS 是直接違反針孔模型，而且**縮短曝光完全救不到**。
        //    1 rad/s + 1/250s 曝光的實際劣化是 6px 模糊 ＋ 14px 剪切 ≈ 20px，不是 6px。
        //    兩者是不同的成因（一個是曝光內抹動、一個是幀內姿態不一致），
        //    但對「這一幀能不能當訓練影像」的影響同向，故合成單一保守指標。
        let fx = Float(camera.intrinsics[0][0])
        a.blurPixels = CameraOnlyGeometry.blurPixels(angularSpeed: a.angularSpeedRadS,
            linearSpeed: a.linearSpeedMS, depth: a.centerDepthM > 0 ? a.centerDepthM : nil,
            focalLength: fx, exposure: camera.exposureDuration, config: config)
        a.exposureBlurPixels = CaptureQualityPolicy.exposureBlur(totalRisk: a.blurPixels,
            exposure: camera.exposureDuration, readout: config.rollingShutterReadoutS)
        if a.blurPixels > config.maxBlurPixels {
            a.issues.append(.tooFast)
        }

        // 4b. 清晰度：直接量影像本身，補上 blurPixels 推估不到的失焦 / AF 搜尋。
        //     絕對值與場景紋理量綁死，故拿它跟「近 0.5s 內同場景的最佳值」比。
        let sharp = Self.sharpness(frame.capturedImage)
        if sharp >= 0 {
            let severeMotion = a.exposureBlurPixels > config.blockBlurPixels
                || a.angularSpeedRadS > config.keyframeMaxAngularSpeedRadS
                || a.linearSpeedMS > config.keyframeMaxLinearSpeedMS
            a.sharpness = sharp
            a.sharpnessRatio = sharpnessReference.ratio(value: sharp, timestamp: frame.timestamp,
                                                       severeMotion: severeMotion)
            if a.sharpnessRatio < config.minSharpnessRatio {
                notSharpStreak += 1
            } else {
                notSharpStreak = 0
            }
            if notSharpStreak >= Self.kNotSharpFrames { a.issues.append(.notSharp) }
        }

        // 5. 光線（lux；1000 為標準室內照度）
        if let lux = frame.lightEstimate?.ambientIntensity {
            if lux < config.minAmbientLux { a.issues.append(.tooDark) }
            else if lux > config.maxAmbientLux { a.issues.append(.tooBright) }
        }

        // 6. 距離
        if !a.depthIsEstimated, a.centerDepthM > 0 {
            if a.centerDepthM < config.minTargetDistanceM { a.issues.append(.tooClose) }
            else if a.centerDepthM > config.maxTargetDistanceM { a.issues.append(.tooFar) }
        }

        // 7. 散熱
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            a.issues.append(.deviceHot)
        }

        a.blockReason = CaptureQualityPolicy.blockReason(
            tracking: !a.issues.contains(.trackingLost),
            sufficientFeatures: !a.issues.contains(.insufficientFeatures),
            blur: a.exposureBlurPixels, angular: a.angularSpeedRadS, linear: a.linearSpeedMS,
            sharpnessRatio: a.sharpnessRatio, config: config)
        a.captureBlocked = a.blockReason != nil
        if a.blockReason == .motion, !a.issues.contains(.tooFast) { a.issues.append(.tooFast) }

        return a
    }

    /// 影像清晰度 = 歸一化的二階差分能量（Laplacian 能量的可分離、抽樣版）。
    ///
    /// 直接讀 ARKit capturedImage 的 luma plane（YCbCr 420 biplanar 的 plane 0）——
    /// 免色彩轉換、免複製。中央 80% 區域每 6 px 抽一點：1920×1440 約 5.6 萬取樣點，
    /// 純整數運算 <0.5ms，可以每幀跑在 session delegate 上。
    ///
    /// 差分步距 2 px 是刻意的：步距 1 的響應集中在 Nyquist 附近，遇到 JPEG/去馬賽克雜訊
    /// 容易把雜訊當細節；步距 2 對我們真正在意的 4~20 px 模糊核最敏感。
    /// 最後除以平均亮度 → 變成對比度量測，暗處與亮處的值可以互相比較。
    nonisolated private static func sharpness(_ pb: CVPixelBuffer) -> Float {
        guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return -1 }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return -1 }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)

        let s = 2               // 差分步距（px）
        let step = 6            // 抽樣間隔（px）
        let mx = max(w / 10, s), my = max(h / 10, s)
        let x0 = mx, x1 = w - mx, y0 = my, y1 = h - my
        guard x1 > x0, y1 > y0 else { return -1 }

        var energy = 0, luma = 0, n = 0
        var y = y0
        while y < y1 {
            let row = p + y * rowBytes
            let up = p + (y - s) * rowBytes
            let dn = p + (y + s) * rowBytes
            var x = x0
            while x < x1 {
                let c = Int(row[x])
                energy += abs(2 * c - Int(row[x - s]) - Int(row[x + s]))
                       +  abs(2 * c - Int(up[x]) - Int(dn[x]))
                luma += c
                n += 1
                x += step
            }
            y += step
        }
        guard n > 0, luma > 0 else { return -1 }
        return Float(energy) / Float(luma)
    }

    /// 取中心 5×5 網格深度的中位數（比單點抗噪，比全圖便宜）
    nonisolated private static func centerMedianDepth(_ pb: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return -1 }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var samples: [Float] = []
        samples.reserveCapacity(25)
        for dy in -2...2 {
            let row = base + (h / 2 + dy * 8) * stride
            for dx in -2...2 {
                let d = row.load(fromByteOffset: (w / 2 + dx * 8) * 4, as: Float32.self)
                if d.isFinite && d > 0 { samples.append(d) }
            }
        }
        guard !samples.isEmpty else { return -1 }
        return samples.sorted()[samples.count / 2]
    }
}
