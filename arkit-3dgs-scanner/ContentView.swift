import SwiftUI
import ARKit

/// Home: what the app does, one prominent capture action, and the scan history one tap away.
struct ContentView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.traditionalChinese.rawValue
    @State private var showCapture = false
    @State private var showGuide = false
    @State private var showHistory = false
    /// Bumped when capture closes so the history shows the scan that was just saved.
    @State private var libraryRevision = 0
    @State private var scanCount: Int?

    private var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }
    private var canScan: Bool { ARWorldTrackingConfiguration.isSupported }

    var body: some View {
        NavigationStack {
            home
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { languageMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showGuide = true } label: {
                            Label(L10n.text("第一次掃描？查看操作指南"), systemImage: "questionmark.circle")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                .navigationDestination(isPresented: $showHistory) {
                    ScanHistoryView(revision: libraryRevision)
                }
        }
        .fullScreenCover(isPresented: $showCapture, onDismiss: { libraryRevision += 1 }) { CaptureView() }
        .sheet(isPresented: $showGuide) { ScanGuideSheet(hasLiDAR: hasLiDAR) }
        .task(id: libraryRevision) { await countScans() }
        // Deletions inside the history change the count shown on the card.
        .onChange(of: showHistory) { _, shown in if !shown { Task { await countScans() } } }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--preview-scan-detail") || $0 == "--preview-history" }) {
                showHistory = true
            }
        }
        #endif
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                DSMetric(value: hasLiDAR ? "LiDAR" : L10n.text("標準相機"),
                         symbol: hasLiDAR ? "sensor.tag.radiowaves.forward" : "camera",
                         tone: hasLiDAR ? .accent : .neutral)
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(L10n.text("把眼前的空間，\n留下來。"))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("走一圈、檢查點雲與拍攝路線，再匯出空間掃描資料。"))
                        .font(.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                historyCard
                if scanCount == 0 {
                    // First run: the steps stay visible until the first scan is saved.
                    ScanGuideSteps()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsCard(padding: DS.Space.l)
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Label(L10n.text("多走動、少原地旋轉，讓同一個表面被不同角度看見。"), systemImage: "figure.walk")
                    if !hasLiDAR {
                        Label(L10n.text("此裝置可擷取影像與稀疏點雲；完整幾何與平面圖建議使用 LiDAR 裝置。"), systemImage: "info.circle")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.xs)
            .padding(.bottom, DS.Space.xl)
            .frame(maxWidth: DS.Size.panelMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .dsCanvas()
        .safeAreaInset(edge: .bottom) { startBar }
    }

    /// Scan history opens only when asked for.
    private var historyCard: some View {
        Button { showHistory = true } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 48, height: 48)
                    .background(DS.Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("掃描紀錄")).font(.headline).foregroundStyle(DS.Palette.textPrimary)
                    Text(L10n.text("預覽、分享或刪除之前的掃描"))
                        .font(.subheadline)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.xs)
                if let scanCount, scanCount > 0 {
                    Text(L10n.text("共 \(scanCount) 筆"))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(DS.Palette.surfaceRaised, in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .dsCard(padding: DS.Space.m + 2)
        }
        .buttonStyle(DSCardButtonStyle())
        .accessibilityIdentifier("scanHistory")
    }

    private var startBar: some View {
        VStack(spacing: DS.Space.xs) {
            Button { showCapture = true } label: {
                Label(L10n.text("開始掃描"), systemImage: "record.circle")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .shadow(color: DS.Palette.accent.opacity(canScan ? 0.3 : 0), radius: 16, y: 6)
            .disabled(!canScan)
            .accessibilityIdentifier("startScan")
            Text(canScan ? L10n.text("掃描與資料優化都在裝置上進行") : L10n.text("此裝置不支援 AR 掃描"))
                .font(.caption)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: DS.Size.panelMaxWidth)
        .padding(.horizontal, DS.Space.xl)
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(stops: [.init(color: DS.Palette.canvas.opacity(0), location: 0),
                                   .init(color: DS.Palette.canvas, location: 0.4)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private func countScans() async {
        scanCount = (try? await ScanLibrary.shared.entries().count) ?? scanCount
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
