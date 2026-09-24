import SwiftUI
import ARKit

/// Home: the scan library is the first thing people see, with one prominent capture action.
struct ContentView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.traditionalChinese.rawValue
    @State private var showCapture = false
    @State private var showGuide = false
    /// Bumped when capture closes so the library shows the scan that was just saved.
    @State private var libraryRevision = 0

    private var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    var body: some View {
        NavigationStack {
            ScanHistoryView(revision: libraryRevision, hasLiDAR: hasLiDAR,
                            canScan: ARWorldTrackingConfiguration.isSupported,
                            onStartScan: { showCapture = true })
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { languageMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showGuide = true } label: {
                            Label(L10n.text("第一次掃描？查看操作指南"), systemImage: "questionmark.circle")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
        }
        .fullScreenCover(isPresented: $showCapture, onDismiss: { libraryRevision += 1 }) { CaptureView() }
        .sheet(isPresented: $showGuide) { ScanGuideSheet(hasLiDAR: hasLiDAR) }
    }

    /// The app language stays selectable directly from the home screen.
    private var languageMenu: some View {
        Menu {
            Picker(L10n.text("語言"), selection: $language) {
                ForEach(AppLanguage.allCases, id: \.rawValue) { option in
                    Text(option.nativeName).tag(option.rawValue)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                Text(AppLanguage.resolve(language).nativeName)
            }
            .font(.subheadline.weight(.medium))
        }
        .accessibilityLabel(L10n.text("語言"))
        .accessibilityValue(AppLanguage.resolve(language).nativeName)
        .accessibilityIdentifier("appLanguage")
    }
}

/// How to scan: three steps and the tips that used to crowd the home screen.
struct ScanGuideSheet: View {
    let hasLiDAR: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    ScanGuideSteps()
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Label(L10n.text("多走動、少原地旋轉，讓同一個表面被不同角度看見。"), systemImage: "figure.walk")
                        Label(L10n.text("掃描與資料優化都在裝置上進行"), systemImage: "lock.shield")
                        if !hasLiDAR {
                            Label(L10n.text("此裝置可擷取影像與稀疏點雲；完整幾何與平面圖建議使用 LiDAR 裝置。"),
                                  systemImage: "info.circle")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.l)
                .frame(maxWidth: DS.Size.panelMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .dsCanvas()
            .navigationTitle(L10n.text("第一次掃描？查看操作指南"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DS.Palette.canvas)
        .presentationCornerRadius(DS.Radius.xl)
    }
}

/// Scan → review → export, shared by the empty library and the guide sheet.
struct ScanGuideSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            step("01", L10n.text("緩慢掃描"), L10n.text("沿著空間移動，手機會自動擷取影像。"), "viewfinder")
            step("02", L10n.text("檢查與補掃"), L10n.text("旋轉點雲檢查缺漏，隨時回到原處補拍。"), "cube.transparent")
            step("03", L10n.text("匯出與分享"), L10n.text("匯出影像、相機姿態與點雲，供外部 3DGS 訓練使用。"), "square.and.arrow.up")
        }
    }

    private func step(_ number: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Palette.accent)
                .frame(width: 44, height: 44)
                .background(DS.Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number)  \(title)").font(.headline).foregroundStyle(DS.Palette.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview { ContentView().preferredColorScheme(.dark) }
