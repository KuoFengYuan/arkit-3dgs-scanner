//
//  SmartShutter.swift
//  fable — 基於「位移距離 + 視角旋轉差」的自動抓幀決策
//
//  設計理由：固定 fps 暴力存檔會產生大量近乎重複的幀（原地不動時最糟），
//  既浪費儲存也讓 3DGS 訓練視角分佈失衡。改為幾何驅動：
//  只有當相機「真的移動出新視角」時才存檔，天然得到均勻的多視角覆蓋。
//

import Foundation
import simd

nonisolated struct SmartShutter {

    private var lastPose: simd_float4x4?
    private var lastTime: TimeInterval = -1

    mutating func reset() {
        lastPose = nil
        lastTime = -1
    }

    /// 平移超過 keyframeTranslationM「或」旋轉超過 keyframeRotationDeg 即觸發，
    /// 並以 minKeyframeInterval 防止手震高頻連拍。品質 gate 由呼叫端把關
    /// 此查詢不改變狀態；影像成功複製並排入寫入後才呼叫 markCaptured。
    func isDue(pose: simd_float4x4, time: TimeInterval, config: CaptureConfig,
                                cameraOnly: Bool = false, estimatedDepth: Float? = nil) -> Bool {
        guard let last = lastPose else {
            return true    // 第一幀無條件抓
        }
        guard time - lastTime >= config.minKeyframeInterval else { return false }

        let translation = simd_distance(MatrixUtil.position(pose), MatrixUtil.position(last))
        let rotationDeg = MatrixUtil.rotationAngleDeg(last, pose)
        // 近距離自動加密重疊；RGB 仍需至少 4 cm 基線，LiDAR 最小 2 cm。
        let threshold: Float
        if let depth = estimatedDepth, depth.isFinite, depth > 0 {
            let minimum = cameraOnly ? config.cameraOnlyMinBaselineM : Float(0.02)
            threshold = min(config.keyframeTranslationM, max(minimum, depth * 0.05))
        } else { threshold = config.keyframeTranslationM }
        guard !cameraOnly || translation >= config.cameraOnlyMinBaselineM else { return false }
        guard translation >= threshold || rotationDeg >= config.keyframeRotationDeg else {
            return false
        }
        return true
    }

    mutating func markCaptured(pose: simd_float4x4, time: TimeInterval) {
        lastPose = pose
        lastTime = time
    }

    /// Compatibility for callers that accept immediately; the live pipeline commits only after
    /// it has successfully copied the image and obtained its writer.
    mutating func shouldCapture(pose: simd_float4x4, time: TimeInterval, config: CaptureConfig,
                               cameraOnly: Bool = false, estimatedDepth: Float? = nil) -> Bool {
        guard isDue(pose: pose, time: time, config: config, cameraOnly: cameraOnly,
                    estimatedDepth: estimatedDepth) else { return false }
        markCaptured(pose: pose, time: time)
        return true
    }
}
