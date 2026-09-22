import SwiftUI

/// Pipeline phases are set by work completion, never by the decorative animation.
nonisolated enum ScanProcessingStage: Int, CaseIterable {
    case preparing, aligning, checking, fusing, finalizing

    var title: String {
        switch self {
        case .preparing: return L10n.text("保存拍攝資料")
        case .aligning: return L10n.text("對齊相機視角")
        case .checking: return L10n.text("檢查影像品質")
        case .fusing: return L10n.text("融合空間點雲")
        case .finalizing: return L10n.text("整理掃描成果")
        }
    }
    var icon: String {
        switch self {
        case .preparing: return "square.and.arrow.down"
        case .aligning: return "viewfinder"
        case .checking: return "checkmark.shield"
        case .fusing: return "cube.transparent"
        case .finalizing: return "square.stack.3d.up"
        }
    }
}

/// Fixed-size procedural illustration; never uploads or duplicates the scan point cloud.
struct FusionProcessingView: View {
    let progress: Double
    let stage: ScanProcessingStage
    let detail: String?
    let frameCount: Int
    let startedAt: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var progressFont = 48.0
    private let cyan = Color(red: 0.26, green: 0.91, blue: 0.94)
    private var fraction: Double { progress.isFinite ? min(1, max(0, progress)) : 0 }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.path").foregroundStyle(cyan)
                        Text(L10n.text("空間重建")).font(.caption.weight(.semibold)).tracking(3)
                        Spacer()
                        Text(L10n.text("裝置端處理")).font(.caption2)
                            .foregroundStyle(cyan).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(cyan.opacity(0.10), in: Capsule())
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("正在合成你的空間"))
                            .font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                        Text(L10n.text("將拍攝視角與深度逐步融合為 3D 點雲"))
                            .font(.subheadline).foregroundStyle(.white.opacity(0.6))
                    }
                    ZStack {
                        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || scenePhase != .active)) { context in
                            let time = reduceMotion ? 0 : context.date.timeIntervalSince(startedAt)
                            FusionSynthesisGraphic(time: time, progress: fraction)
                        }.accessibilityHidden(true)
                        VStack(spacing: 3) {
                            Text("\(Int(fraction * 100))")
                                .font(.system(size: progressFont, weight: .light, design: .rounded).monospacedDigit())
                            Text(L10n.text("整體進度 %")).font(.caption2).foregroundStyle(cyan)
                        }
                    }
                    .frame(height: min(250, max(170, geometry.size.height * 0.29)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("處理進度"))
                    .accessibilityValue("\(Int(fraction * 100))%")

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(stage.title).font(.title3.bold())
                            Spacer()
                            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                                    .font(.caption.monospacedDigit()).foregroundStyle(cyan)
                                    .accessibilityLabel(L10n.text("已用時間"))
                                    .accessibilityValue(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            }
                        }
                        ProgressView(value: fraction).tint(cyan)
                        Text(detail ?? stage.title).font(.caption).foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Label(L10n.text("\(frameCount) 張影像"), systemImage: "photo.stack")
                            Spacer()
                            Text(L10n.text("階段 \(stage.rawValue + 1) / \(ScanProcessingStage.allCases.count)"))
                        }.font(.caption2).foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(20)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(cyan.opacity(0.18)))

                    VStack(spacing: 15) {
                        ForEach(ScanProcessingStage.allCases, id: \.rawValue) { step in
                            HStack(spacing: 12) {
                                Image(systemName: step.rawValue < stage.rawValue ? "checkmark.circle.fill" : step.icon)
                                    .frame(width: 22)
                                    .foregroundStyle(step.rawValue <= stage.rawValue ? cyan : .white.opacity(0.25))
                                Text(step.title).font(.subheadline)
                                    .foregroundStyle(step.rawValue <= stage.rawValue ? .white : .white.opacity(0.35))
                                Spacer()
                                if step == stage {
                                    Text(L10n.text("處理中")).font(.caption2).foregroundStyle(cyan)
                                } else if step.rawValue < stage.rawValue {
                                    Text(L10n.text("已完成")).font(.caption2).foregroundStyle(.white.opacity(0.4))
                                }
                            }
                        }
                    }.padding(.horizontal, 6)
                    Text(L10n.text("請保持 App 開啟。照片越多，處理時間越長；完成後會自動顯示預覽。"))
                        .font(.caption).foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(28)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
            }
            .background {
                LinearGradient(colors: [Color(red: 0.02, green: 0.075, blue: 0.11), Color(red: 0.015, green: 0.025, blue: 0.045)],
                               startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

private struct FusionSynthesisGraphic: View {
    let time: Double
    let progress: Double
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width * 0.36, size.height * 0.45)
            let tint = Color(red: 0.26, green: 0.91, blue: 0.94)
            for ring in 0..<3 {
                let r = radius * (1 + Double(ring) * 0.12)
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(ring == 0 ? 0.28 : 0.07)), lineWidth: 1)
            }
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + 360 * progress), clockwise: false)
            context.stroke(arc, with: .color(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            // 180 particles, independent of photo/point count; decorative, not reconstructed geometry.
            for i in 0..<180 {
                let angle = Double(i) * 2.39996 + time * 0.1
                let belt = 1.15 + Double(i % 11) * 0.06
                let pulse = sin(time * 0.7 + Double(i) * 0.23) * 0.05
                let x = center.x + cos(angle) * radius * (belt + pulse)
                let y = center.y + sin(angle) * radius * (0.62 + Double(i % 5) * 0.06)
                guard hypot(x - center.x, y - center.y) > radius * 1.08 else { continue }
                let d = i % 7 == 0 ? 2.8 : 1.5
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)),
                             with: .color(tint.opacity(i % 3 == 0 ? 0.7 : 0.3)))
            }
        }
    }
}

#Preview("Fusion") {
    FusionProcessingView(progress: 0.67, stage: .fusing, detail: L10n.text("融合點雲…"),
                         frameCount: 399, startedAt: Date().addingTimeInterval(-42))
}
