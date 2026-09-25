// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import SwiftUI
import UIKit

/// Plain-language wording for the on-device training flow: what the model is doing now, how
/// long is left and how long a preset took on this phone before, instead of iteration counts.
enum TrainingPresentation {
    /// What a running job is doing, following the MRNF schedule (growth until half of the run,
    /// refinement until 95 %, then the final settling iterations).
    static func stage(_ s: TrainingSnapshot) -> String {
        switch s.phase {
        case .preparing: return s.startIteration > 0 ? L10n.text("讀取照片與模型") : L10n.text("讀取照片與點雲")
        case .finishing: return L10n.text("儲存 3DGS 模型")
        case .paused: return L10n.text("已暫停")
        case .completed: return L10n.text("3DGS 模型完成")
        case .failed: return L10n.text("訓練失敗")
        case .cancelled: return L10n.text("已停止")
        case .running:
            // The schedule's position (an enhancement starts part-way through it).
            let p = Double(s.iteration) / Double(max(1, s.total))
            if p < 0.5 { return L10n.text("建立形狀並增加細節") }
            if p < 0.95 { return L10n.text("讓細節更清晰") }
            return L10n.text("最後修飾")
        }
    }

    /// Progress of this run: an enhancement counts from the saved model's iteration.
    static func fraction(_ s: TrainingSnapshot) -> Double {
        Double(max(0, s.iteration - s.startIteration)) / Double(max(1, s.total - s.startIteration))
    }

    static func percent(_ s: TrainingSnapshot) -> Int { Int(fraction(s) * 100) }

    /// Remaining time once the per-iteration speed has settled (the first iterations are
    /// faster than the rest because the model is still small).
    static func remaining(_ s: TrainingSnapshot) -> String? {
        guard s.phase == .running else { return nil }
        guard s.iteration - s.startIteration >= max(100, (s.total - s.startIteration) / 50), let seconds = s.remainingSeconds else {
            return L10n.text("正在估算剩餘時間…")
        }
        if seconds < 60 { return L10n.text("剩餘不到 1 分鐘") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return L10n.text("剩餘約 \(minutes) 分鐘") }
        return L10n.text("剩餘約 \(minutes / 60) 小時 \(minutes % 60) 分鐘")
    }

    static func approximate(_ seconds: Double) -> String {
        if seconds < 60 { return L10n.text("不到 1 分鐘") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return L10n.text("約 \(minutes) 分鐘") }
        return L10n.text("約 \(minutes / 60) 小時 \(minutes % 60) 分鐘")
    }

    static func title(_ preset: GaussianTrainingConfiguration.Preset) -> String {
        switch preset {
        case .quick: return L10n.text("快速預覽")
        case .standard: return L10n.text("標準")
        case .high: return L10n.text("高品質")
        }
    }

    static func detail(_ preset: GaussianTrainingConfiguration.Preset) -> String {
        switch preset {
        case .quick: return L10n.text("最快看到成果，細節較少")
        case .standard: return L10n.text("兼顧清晰度與時間，適合多數掃描")
        case .high: return L10n.text("細節最多，需要最長時間與較多電量")
        }
    }

    /// Enhance model: the quality choices add iterations to the saved model.
    static func enhanceTitle(_ preset: GaussianTrainingConfiguration.Preset) -> String {
        switch preset {
        case .quick: return L10n.text("稍微加強")
        case .standard: return L10n.text("標準加強")
        case .high: return L10n.text("大幅加強")
        }
    }

    static func enhanceDetail(_ iterations: Int) -> String {
        L10n.text("再訓練 \(iterations.formatted()) 次")
    }

    static func title(_ resolution: GaussianTrainingConfiguration.Resolution) -> String {
        switch resolution {
        case .low: return L10n.text("低")
        case .medium: return L10n.text("中")
        case .high: return L10n.text("高（原始）")
        }
    }

    /// Relative cost from the pixel count (per-iteration work scales with it).
    static func detail(_ resolution: GaussianTrainingConfiguration.Resolution) -> String {
        switch resolution {
        case .low: return L10n.text("960 px，最快、最省記憶體")
        case .medium: return L10n.text("1440 px，細節較多；時間約 1.7 倍")
        case .high: return L10n.text("原始 1920 px，細節最多；時間約 2.6 倍，記憶體用量最高")
        }
    }

    static func symbol(_ preset: GaussianTrainingConfiguration.Preset) -> String {
        switch preset {
        case .quick: return "hare"
        case .standard: return "circle.lefthalf.filled"
        case .high: return "sparkles"
        }
    }
}

/// Measured speed of completed runs on this device, per preset. Time estimates are shown only
/// from these measurements; nothing is extrapolated from another device.
nonisolated enum TrainingSpeedHistory {
    static let key = "gaussianTraining.secondsPerIteration"

    /// One measurement per preset and training resolution.
    static func slot(_ configuration: GaussianTrainingConfiguration) -> String {
        "\(configuration.preset.rawValue)@\(configuration.longEdge)"
    }

    static func record(_ configuration: GaussianTrainingConfiguration, secondsPerIteration: Double) {
        guard secondsPerIteration.isFinite, secondsPerIteration > 0 else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[slot(configuration)] = secondsPerIteration
        UserDefaults.standard.set(all, forKey: key)
    }

    static func estimatedSeconds(_ configuration: GaussianTrainingConfiguration) -> Double? {
        guard let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
              let spi = all[slot(configuration)] else { return nil }
        return spi * Double(configuration.runIterations)
    }
}

/// The History entry of a scan's 3DGS model: one row that says what happens next (train,
/// follow, resume or view) with progress and time, instead of a bare button.
struct TrainingEntryCard: View {
    enum State: Equatable {
        case idle(estimate: Double?)
        case active(TrainingSnapshot)
        case resumable(progress: Double)
        case model
        case failed
    }

    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DSActionCardLabel(title: title, subtitle: subtitle, tint: tint) { leading }
        }
        .buttonStyle(DSCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var tint: Color {
        switch state {
        case .idle, .active: return DS.Palette.accent
        case .resumable, .failed: return DS.Palette.warning
        case .model: return DS.Palette.success
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch state {
        case .active(let snapshot):
            ZStack {
                DSProgressRing(progress: TrainingPresentation.fraction(snapshot), lineWidth: 4,
                               tint: snapshot.phase == .paused ? DS.Palette.warning : DS.Palette.accent)
                Text("\(TrainingPresentation.percent(snapshot))%").font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(DS.Palette.textPrimary)
            }
        case .resumable(let progress):
            ZStack {
                DSProgressRing(progress: progress, lineWidth: 4, tint: DS.Palette.warning)
                Image(systemName: "play.fill").font(.caption.weight(.bold)).foregroundStyle(DS.Palette.warning)
            }
        default:
            DSActionIcon(symbol: symbol, tint: tint)
        }
    }

    private var symbol: String {
        switch state {
        case .model: return "cube.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "sparkles"
        }
    }

    private var title: String {
        switch state {
        case .idle: return L10n.text("訓練 3DGS")
        case .active(let s): return s.phase == .paused ? L10n.text("3DGS 訓練已暫停") : L10n.text("3DGS 訓練中")
        case .resumable: return L10n.text("繼續訓練 3DGS")
        case .model: return L10n.text("檢視 3DGS 模型")
        case .failed: return L10n.text("訓練 3DGS")
        }
    }

    private var subtitle: String {
        switch state {
        case .idle(let estimate):
            if let estimate { return L10n.text("直接在 iPhone 上建立模型・標準品質\(TrainingPresentation.approximate(estimate))") }
            return L10n.text("直接在 iPhone 上建立模型")
        case .active(let s):
            if s.phase == .paused { return L10n.text("已完成 \(TrainingPresentation.percent(s))%，點此繼續") }
            let stage = TrainingPresentation.stage(s)
            if let remaining = TrainingPresentation.remaining(s) { return "\(stage)・\(remaining)" }
            return stage
        case .resumable(let progress): return L10n.text("已完成 \(Int(progress * 100))%，可從上次進度繼續")
        case .model: return L10n.text("旋轉檢視或分享模型")
        case .failed: return L10n.text("上次訓練未完成，點此查看並重試")
        }
    }
}
