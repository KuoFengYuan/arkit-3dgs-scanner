//
//  HUDOverlay.swift
//  fable — 掃描 HUD：狀態、單一提示插槽、工具列、快門與檢視面板
//
//  畫面以相機與點雲為主，控制項只在需要時出現：
//  - 上方一列：關閉、置中的狀態膠囊、右側數據或資訊鍵。
//  - 提示插槽一次只顯示最重要的一則（見 guidance）。
//  - 掃描中才出現的工具列（點雲、熱圖、空間結構）。
//  - 快門外圈就是視角涵蓋率；速度表只在接近模糊門檻時出現。
//  - 掃描後是一張浮動面板：數據、主要的匯出動作、次要的續掃／捨棄。
//  橫向（高度 compact）時快門與面板移到右側，不壓住畫面中央。
//

import SwiftUI

struct HUDOverlay: View {
    @ObservedObject var controller: CaptureController
    /// 檢視階段重設 3D 視角（由承載點雲的 CaptureView 執行）。
    var onResetView: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showDiscardConfirm = false
    @State private var showExitConfirm = false
    @State private var showAdvanced = false
    @State private var summaryExpanded = false
    /// 手勢說明只在剛進入檢視時短暫出現。
    @State private var showGestureHint = true

    private var landscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            severeGlow
            VStack(spacing: DS.Space.s) {
                topBar
                guidanceBanner
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.top, DS.Space.xs)
            if controller.phase == .scanning { toolRail }
            bottomCluster
        }
        .sheet(isPresented: $showAdvanced) { scanSettings }
        .sheet(isPresented: $summaryExpanded) { scanDetails }
        .confirmationDialog(L10n.text("離開掃描檢視？"), isPresented: $showExitConfirm, titleVisibility: .visible) {
            Button(L10n.text("離開並保留檔案")) { dismiss() }
            Button(L10n.text("留在這裡"), role: .cancel) {}
        } message: {
            Text(L10n.text("掃描會保留在首頁的「掃描紀錄」，之後可預覽、分享或刪除。離開後無法接續這次即時掃描。"))
        }
        .onChange(of: controller.phase) { _, phase in
            showAdvanced = false
            summaryExpanded = false
            if phase == .review { showGestureHint = true }
        }
        .task(id: controller.phase == .review) {
            guard controller.phase == .review else { return }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeOut(duration: 0.4)) { showGestureHint = false }
        }
        .sensoryFeedback(trigger: controller.phase) { old, new in
            switch (old, new) {
            case (.idle, .scanning), (.review, .scanning): return .start
            case (.scanning, _): return .stop
            case (.processing, .review), (.exporting, .done): return .success
            default: return nil
            }
        }
        .sensoryFeedback(trigger: controller.assessment.showsBlockingWarning) { _, blocked in
            blocked && controller.phase == .scanning ? .warning : nil
        }
        .animation(.easeInOut(duration: 0.25), value: controller.assessment.worst)
        .animation(.easeInOut(duration: 0.25), value: controller.phase)
        .animation(.easeInOut(duration: 0.25), value: controller.loopHint)
        .animation(.easeInOut(duration: 0.25), value: controller.floorPlanHint)
        .animation(.easeInOut(duration: 0.25), value: controller.recentRejectCount >= 4)
        .animation(.easeInOut(duration: 0.25), value: controller.relocalizing)
        .animation(.easeInOut(duration: 0.25), value: showsMotionMeter)
    }

    // MARK: - 上方列

    private var topBar: some View {
        HStack(alignment: .top, spacing: DS.Space.xs) {
            closeButton
                .frame(maxWidth: .infinity, alignment: .leading)
            DSStatusPill(text: phaseTitle, symbol: phaseSymbol, tone: phaseTone,
                         pulsing: controller.phase == .scanning && controller.trackingReady)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize()
                .allowsHitTesting(false)
            HStack(spacing: 0) { trailingTopItems }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var closeButton: some View {
        Button {
            if controller.phase == .idle || controller.phase == .done { dismiss() }
            else { showExitConfirm = true }
        } label: {
            Label(L10n.text("離開掃描"), systemImage: "xmark")
        }
        .buttonStyle(DSIconButtonStyle())
        .disabled(!controller.canClose)
        .opacity(controller.canClose ? 1 : 0)
        .accessibilityHidden(!controller.canClose)
    }

    @ViewBuilder
    private var trailingTopItems: some View {
        switch controller.phase {
        case .scanning:
            statsCard
        case .review, .exporting, .done:
            HStack(spacing: DS.Space.xs) {
                if hasScanDetails {
                    Button { summaryExpanded = true } label: {
                        Label(L10n.text("查看掃描品質資訊"),
                              systemImage: controller.statusText != nil ? "exclamationmark.circle" : "info.circle")
                    }
                    .buttonStyle(DSIconButtonStyle(isSelected: controller.statusText != nil, tint: DS.Palette.warning))
                }
                if let onResetView, controller.phase != .exporting {
                    Button(action: onResetView) {
                        Label(L10n.text("顯示完整點雲"), systemImage: "scope")
                    }
                    .buttonStyle(DSIconButtonStyle())
                }
            }
        default:
            EmptyView()
        }
    }

    private var phaseTitle: String {
        switch controller.phase {
        case .idle: return controller.trackingReady ? L10n.text("準備就緒") : L10n.text("準備相機")
        case .scanning: return controller.trackingReady ? L10n.text("正在掃描") : L10n.text("等待追蹤恢復")
        case .processing: return L10n.text("正在整理掃描")
        case .review: return L10n.text("檢查掃描成果")
        case .exporting: return L10n.text("正在匯出")
        case .done: return L10n.text("檔案已準備好")
        }
    }

    private var phaseSymbol: String {
        switch controller.phase {
        case .idle: return controller.trackingReady ? "viewfinder" : "hourglass"
        case .scanning: return controller.trackingReady ? "record.circle" : "pause.circle"
        case .processing, .exporting: return "hourglass"
        case .review: return "cube.transparent"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var phaseTone: DS.Tone {
        switch controller.phase {
        case .idle: return controller.trackingReady ? .accent : .neutral
        case .scanning: return controller.trackingReady ? .neutral : .warning
        case .done: return .success
        default: return .neutral
        }
    }

    /// 掃描中的數據：幀數、點數與預估容量。純資訊，不吃手勢。
    private var statsCard: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Label(L10n.text("\(controller.keyframeCount) 幀"), systemImage: "camera.viewfinder")
            Label(L10n.text("\(controller.pointCount / 1000)k 點"), systemImage: "circle.grid.3x3.fill")
            Label(storageEstimate, systemImage: "internaldrive")
            if !controller.hasLiDAR {
                Label(controller.supportsLiDAR ? L10n.text("LiDAR 已關閉") : L10n.text("無 LiDAR"),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DS.Palette.warning)
            }
        }
        .labelStyle(TrailingIconLabelStyle())
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .hudText()
        .padding(.horizontal, 10).padding(.vertical, 8)
        .hudGlass(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var storageEstimate: String {
        let mb = Double(controller.keyframeCount) * 0.62
        return mb < 1000 ? String(format: "%.0f MB", mb) : String(format: "%.1f GB", mb / 1000)
    }

    private static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 90 { return L10n.text("剛剛") }
        if s < 3600 { return L10n.text("\(s / 60) 分鐘前") }
        if s < 86400 { return L10n.text("\(s / 3600) 小時前") }
        return L10n.text("\(s / 86400) 天前")
    }

    // MARK: - 全螢幕紅框：遮斷級警告（暫停抓幀中）的強視覺提示

    @ViewBuilder
    private var severeGlow: some View {
        if controller.phase == .scanning, controller.assessment.showsBlockingWarning {
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(DS.Palette.danger.opacity(0.7), lineWidth: 5)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: - 單一提示插槽（依優先序只顯示最重要的一則）

    /// 四種提示（重定位／品質警告／迴環／缺角）**共用一個位置**。
    ///
    /// 它們原本各佔一條橫幅，最壞情況同時出現四條把取景畫面塞滿 ——
    /// 而使用者在任一時刻只能對一件事做出反應，多餘的那幾條只是雜訊。
    /// 優先序即「現在最該做什麼」：
    ///   1. 重定位中   姿態不可信、快門也被擋住，其他都不重要
    ///   2. 遮斷級警告 正在暫停抓幀，不處理就一直沒有資料
    ///   3. 迴環提示   影響全域精度，且錯過就補不回來
    ///   4. 缺角提醒   局部覆蓋，之後還能補
    ///   5. 提醒級警告 照拍，只是品質差一點
    private struct Guidance {
        let text: String
        let symbol: String
        let tone: DS.Tone
    }

    private var guidance: Guidance? {
        if controller.phase == .scanning && !controller.trackingReady {
            return Guidance(text: controller.sessionState.message, symbol: "pause.circle.fill", tone: .warning)
        }
        if controller.relocalizing {
            return Guidance(text: L10n.text("重新定位中：請把鏡頭對準上次掃描過的區域"),
                            symbol: "point.3.connected.trianglepath.dotted", tone: .info)
        }
        guard controller.phase == .scanning else { return nil }
        let a = controller.assessment
        if a.showsBlockingWarning, let w = a.worst {
            return Guidance(text: a.blockReason?.message ?? w.message, symbol: w.symbol, tone: .danger)
        }
        // 正在掉幀：這是實測結果不是推估，優先於所有「可能會怎樣」的提示
        if controller.recentRejectCount >= 4 {
            return Guidance(text: L10n.text("畫面不夠清晰，已略過 \(controller.recentRejectCount) 個候選影格・請稍停讓對焦穩定"),
                            symbol: "camera.metering.none", tone: .danger)
        }
        // RoomPlan 的引導排在閉環之前：它講的是「現在這一刻正在丟失資料」
        // （靠太近、光線不足、紋理不足），而閉環提示是走了 8m 之後的長期建議。
        if let hint = controller.floorPlanHint {
            return Guidance(text: hint, symbol: "square.split.bottomrightquarter", tone: .warning)
        }
        if let hint = controller.loopHint {
            return Guidance(text: hint, symbol: "arrow.triangle.capsulepath", tone: .warning)
        }
        if let w = a.worst {
            return Guidance(text: w.message, symbol: w.symbol, tone: .warning)
        }
        return nil
    }

    @ViewBuilder
    private var guidanceBanner: some View {
        if let g = guidance {
            DSStatusPill(text: g.text, symbol: g.symbol, tone: g.tone)
                .frame(maxWidth: DS.Size.panelMaxWidth)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    // MARK: - 掃描中的工具列（只在掃描時出現）

    private var toolRail: some View {
        VStack(spacing: DS.Space.s) {
            // RoomPlan 關掉時要一起藏起來：沒有資料來源，留著就是一顆按了沒反應的按鈕。
            if controller.hasLiDAR, controller.config.captureFloorPlan, FloorPlanCapture.isSupported {
                Button { controller.toggleRoomPlan() } label: {
                    Label(L10n.text("顯示空間結構"), systemImage: controller.showRoomPlan
                          ? "square.split.bottomrightquarter.fill" : "square.split.bottomrightquarter")
                }
                .buttonStyle(DSIconButtonStyle(isSelected: controller.showRoomPlan))
                .accessibilityValue(controller.showRoomPlan ? L10n.text("已開啟") : L10n.text("已關閉"))
            }
            Button { controller.togglePointCloud() } label: {
                Label(controller.showPointCloud ? L10n.text("隱藏點雲") : L10n.text("顯示點雲"),
                      systemImage: controller.showPointCloud ? "circle.grid.3x3.fill" : "circle.grid.3x3")
            }
            .buttonStyle(DSIconButtonStyle(isSelected: controller.showPointCloud))
            // 融合品質熱圖：直接把「這塊還沒掃夠」畫在表面上。
            if controller.showPointCloud && controller.hasLiDAR {
                Button { controller.toggleColorMode() } label: {
                    Label(controller.colorMode == .fusionQuality ? L10n.text("切換真實顏色") : L10n.text("顯示掃描品質熱圖"),
                          systemImage: controller.colorMode == .fusionQuality ? "thermometer.medium" : "paintpalette")
                }
                .buttonStyle(DSIconButtonStyle(isSelected: controller.colorMode == .fusionQuality, tint: DS.Palette.warning))
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? .leading : .trailing)
        .transition(.move(edge: landscape ? .leading : .trailing).combined(with: .opacity))
    }

    // MARK: - 下方：情境提示 ＋ 依階段的控制

    private var bottomCluster: some View {
        VStack(spacing: DS.Space.s) {
            contextualIndicators
            switch controller.phase {
            case .idle, .scanning:
                if landscape { EmptyView() } else { captureControls }
            case .processing:
                processingIndicator
            case .review, .exporting, .done:
                reviewPanel
            }
        }
        .frame(maxWidth: landscape ? 380 : DS.Size.panelMaxWidth)
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? .bottomTrailing : .bottom)
        .overlay(alignment: .trailing) {
            if landscape, controller.phase == .idle || controller.phase == .scanning {
                captureColumn.padding(.trailing, DS.Space.m)
            }
        }
    }

    @ViewBuilder
    private var contextualIndicators: some View {
        fusionLegend
        if showsMotionMeter { motionMeter }
        if let text = statusHint {
            Text(text)
                .font(.footnote)
                .hudText()
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .hudGlass(Capsule())
                .transition(.opacity)
                // 純提示，不該吃手勢：檢視階段底下是可旋轉的 3D 點雲。
                .allowsHitTesting(false)
        }
    }

    /// 熱圖圖例。只在熱圖模式顯示 —— 顏色是表面被看過的夾角跨度（0° → 30° 以上），不是次數。
    @ViewBuilder
    private var fusionLegend: some View {
        if controller.phase == .scanning, controller.showPointCloud, controller.colorMode == .fusionQuality {
            HStack(spacing: 8) {
                Text(L10n.text("視角跨度")).font(.caption2)
                Text("0°").font(.caption2.monospacedDigit())
                HStack(spacing: 3) {
                    ForEach(0..<7) { i in
                        let q = Double(i) / 6
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(red: q < 0.5 ? 1 : 2 * (1 - q), green: q < 0.5 ? 2 * q : 1, blue: 0.15))
                            .frame(width: 14, height: 8)
                    }
                }
                Text(String(format: "%.0f°+", TiledFusedGrid.kWellObservedDegrees)).font(.caption2.monospacedDigit())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("視角跨度"))
            .accessibilityValue(String(format: L10n.text("紅色為單一角度，綠色為 %.0f° 以上"), TiledFusedGrid.kWellObservedDegrees))
            .hudText()
            .padding(.horizontal, 12).padding(.vertical, 6)
            .hudGlass(Capsule())
            .allowsHitTesting(false)
        }
    }

    /// 速度表只在接近模糊門檻時出現（綠＝安全、橘＝輕微模糊、紅＝暫停抓幀）。
    private var showsMotionMeter: Bool {
        guard controller.phase == .scanning, controller.trackingReady else { return false }
        return controller.assessment.blurPixels >= controller.config.maxBlurPixels * 0.6
            || controller.assessment.blockReason == .motion
    }

    private var motionMeter: some View {
        let blur = controller.assessment.blurPixels, cfg = controller.config
        let tint = controller.assessment.blockReason == .motion ? DS.Palette.danger
            : (blur > cfg.maxBlurPixels ? DS.Palette.warning : DS.Palette.success)
        return HStack(spacing: 8) {
            Image(systemName: "tortoise.fill").font(.caption2)
            ProgressView(value: Double(min(1.0, blur / cfg.blockBlurPixels)))
                .tint(tint)
                .frame(width: 120)
            Image(systemName: "hare.fill").font(.caption2)
        }
        .hudText()
        .padding(.horizontal, 12).padding(.vertical, 7)
        .hudGlass(Capsule(), tint: tint)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("移動速度"))
        .accessibilityValue("\(Int(min(1, blur / cfg.blockBlurPixels) * 100))%")
    }

    private var statusHint: String? {
        if controller.phase == .idle && !controller.trackingReady { return controller.sessionState.message }
        if controller.phase != .review, let s = controller.statusText { return s }
        switch controller.phase {
        case .idle:
            if !controller.hasLiDAR { return L10n.text("側向移動以驗證特徵點") }
            return (controller.refineCameraPoses || controller.reconstructSurfaces)
                ? L10n.text("精細掃描已開啟・沿著空間緩慢移動")
                : L10n.text("沿著空間緩慢移動，影像會自動儲存")
        case .scanning:
            // 追蹤與品質問題已由提示插槽說明；這裡只在剛開始時給一次操作說明。
            guard controller.trackingReady, guidance == nil, controller.keyframeCount < 8 else { return nil }
            return controller.hasLiDAR ? L10n.text("沿著空間緩慢移動・新視角會自動存成照片")
                                       : L10n.text("側向移動以驗證特徵點")
        case .processing:
            return L10n.text("點雲優化中：姿態修正 + 多視角加權融合…")
        case .review:
            if !controller.canUseScan { return L10n.text("尚未取得可用影像，請繼續掃描並緩慢移動") }
            return showGestureHint ? L10n.text("單指旋轉・雙指縮放，檢查是否有遺漏的區域") : nil
        case .exporting:
            return L10n.text("打包 COLMAP 資料集…")
        case .done:
            return nil
        }
    }

    // MARK: - 快門列

    private var captureControls: some View {
        VStack(spacing: DS.Space.s) {
            if controller.phase == .idle { sessionRecoveryControls }
            HStack(alignment: .center) {
                HStack(spacing: 0) { leadingCaptureSlot }.frame(maxWidth: .infinity)
                shutterButton
                HStack(spacing: 0) { trailingCaptureSlot }.frame(maxWidth: .infinity)
            }
            Text(controller.phase == .scanning ? L10n.text("結束掃描") : L10n.text("開始掃描"))
                .font(.subheadline.weight(.semibold))
                .hudText()
        }
    }

    /// 橫向：快門直立在右側，像系統相機。
    private var captureColumn: some View {
        VStack(spacing: DS.Space.m) {
            if controller.phase == .idle { settingsButton }
            shutterButton
            Text(controller.phase == .scanning ? L10n.text("結束掃描") : L10n.text("開始掃描"))
                .font(.caption.weight(.semibold))
                .hudText()
            if controller.phase == .idle { sessionRecoveryControls } else { coverageLabel }
        }
    }

    @ViewBuilder
    private var leadingCaptureSlot: some View {
        if controller.phase == .idle { settingsButton }
    }

    @ViewBuilder
    private var trailingCaptureSlot: some View {
        if controller.phase == .scanning { coverageLabel }
    }

    @ViewBuilder
    private var coverageLabel: some View {
        if controller.phase == .scanning && controller.hasLiDAR {
            Text(String(format: L10n.text("視角 %.0f%%"), controller.fusionCompleteness * 100))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(coverageTint)
                .hudText()
                .allowsHitTesting(false)
        }
    }

    /// 掃描設定只有一個入口；按鈕下方直接標示目前模式（LiDAR／相機模式）。
    private var settingsButton: some View {
        Button { showAdvanced = true } label: {
            VStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: DS.Size.control, height: DS.Size.control)
                    .hudGlass(Circle())
                Text(L10n.text("掃描設定")).font(.caption2.weight(.medium))
                Label(controller.hasLiDAR ? "LiDAR" : L10n.text("相機模式"),
                      systemImage: controller.hasLiDAR ? "sensor.tag.radiowaves.forward" : "camera")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(controller.hasLiDAR ? DS.Palette.accent : DS.Palette.warning)
            }
            .foregroundStyle(DS.Palette.textPrimary)
            .hudText()
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("掃描設定"))
        .accessibilityValue(controller.hasLiDAR ? L10n.text("LiDAR 深度掃描") : L10n.text("相機模式・未使用 LiDAR 深度"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("scanSettings")
    }

    /// 融合完成度：場景模式沒有涵蓋率圓頂，這是唯一的「掃夠了沒」訊號。
    private var coverageTint: Color {
        let f = controller.fusionCompleteness
        return f < 0.3 ? DS.Palette.danger : (f < 0.6 ? DS.Palette.warning : DS.Palette.success)
    }

    private var shutterButton: some View {
        Button {
            if controller.phase == .scanning { controller.stopScan() } else { controller.startScan() }
        } label: {
            ZStack {
                if controller.phase == .scanning && controller.hasLiDAR {
                    Circle().stroke(Color.white.opacity(0.35), lineWidth: 4)
                    DSProgressRing(progress: controller.fusionCompleteness, lineWidth: 4, tint: coverageTint)
                } else {
                    Circle().strokeBorder(.white, lineWidth: 4)
                }
                if controller.phase == .scanning {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Palette.record)
                        .frame(width: 30, height: 30)
                } else {
                    Circle().fill(DS.Palette.record).frame(width: 62, height: 62)
                }
            }
            .frame(width: DS.Size.shutter, height: DS.Size.shutter)
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .buttonStyle(ShutterButtonStyle())
        // 重定位未完成時姿態不可信，此時開拍等於把錯的外參寫進資料 —— 直接擋住
        .disabled(shutterBlocked)
        .opacity(shutterBlocked ? 0.4 : 1)
        .accessibilityLabel(controller.phase == .scanning ? L10n.text("結束掃描並檢視成果") : L10n.text("開始掃描"))
        .accessibilityHint(controller.phase == .scanning ? L10n.text("儲存影像並產生點雲") : controller.sessionState.message)
        .accessibilityValue(controller.phase == .scanning && controller.hasLiDAR
            ? String(format: L10n.text("視角 %.0f%%"), controller.fusionCompleteness * 100) : "")
    }

    private var shutterBlocked: Bool {
        controller.phase == .idle && !controller.canStartScan
    }

    @ViewBuilder
    private var sessionRecoveryControls: some View {
        switch controller.sessionState {
        case .permissionDenied:
            Button(L10n.text("開啟相機設定")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(DSPrimaryButtonStyle(fill: false))
        case .failed:
            Button(L10n.text("重新啟動相機")) { controller.prepareCamera() }
                .buttonStyle(DSPrimaryButtonStyle(fill: false))
        case .relocalizing where controller.continueFromLastMap:
            Button(L10n.text("改為全新掃描")) { controller.setContinueFromLastMap(false) }
                .buttonStyle(DSSecondaryButtonStyle())
        default: EmptyView()
        }
    }

    private var processingIndicator: some View {
        ZStack {
            DSProgressRing(progress: controller.exportProgress, lineWidth: 4)
            Text("\(Int(controller.exportProgress * 100))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 64, height: 64)
        .padding(.bottom, DS.Space.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("處理進度"))
        .accessibilityValue("\(Int(controller.exportProgress * 100))%")
    }

    // MARK: - 檢視面板（掃描後）

    private var reviewPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            DSFlowLayout {
                    DSMetric(value: L10n.text("\(controller.keyframeCount) 幀"), symbol: "camera.viewfinder")
                    DSMetric(value: L10n.text("\(controller.reviewPoints.count / 1000)k 點"), symbol: "circle.grid.3x3.fill")
                    if let report = controller.imageReconstructionReport {
                        DSMetric(value: report.outputPoints > 0
                                 ? L10n.text("影像重建 \(report.outputPoints.formatted()) 點")
                                 : L10n.text("影像重建：尚無可靠匹配"),
                                 symbol: "photo.stack", tone: report.outputPoints > 0 ? .neutral : .warning)
                            .accessibilityLabel(report.outputPoints > 0
                                 ? L10n.text("影像重建 \(report.outputPoints.formatted()) 點 · \(report.contributingReferences) 個參考視角")
                                 : L10n.text("影像重建：尚無可靠匹配"))
                    }
                    // 平面圖預覽（只有真的產出牆面時才出現）
                    if let fp = controller.floorPlanData, !fp.walls.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { controller.showFloorPlan.toggle() }
                        } label: {
                            DSMetric(value: String(format: L10n.text("平面圖（%d 牆 · %.1f×%.1fm）"),
                                                   fp.walls.count, fp.sizeM.x, fp.sizeM.y),
                                     symbol: "map", tone: .accent)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .disabled(controller.phase == .exporting)
                    }
            }
            primaryReviewAction
            secondaryReviewActions
        }
        .padding(DS.Space.m)
        .dsFloatingPanel()
        .confirmationDialog(L10n.text("捨棄這次掃描？"), isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button(L10n.text("刪除掃描資料"), role: .destructive) { controller.discardScan() }
            Button(L10n.text("取消"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var primaryReviewAction: some View {
        switch controller.phase {
        case .done:
            if let zip = controller.exportedZip {
                ShareLink(item: zip) {
                    Label(L10n.text("分享 .zip"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(DSPrimaryButtonStyle())
            }
        case .exporting:
            Button {} label: { Label(L10n.text("正在匯出"), systemImage: "shippingbox") }
                .buttonStyle(DSPrimaryButtonStyle(isLoading: true))
                .disabled(true)
        default:
            Button { controller.exportAndShare() } label: {
                Label(L10n.text("匯出 3DGS 訓練資料"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(!controller.canUseScan)
        }
    }

    @ViewBuilder
    private var secondaryReviewActions: some View {
        switch controller.phase {
        case .done:
            Button { controller.resetForNewScan() } label: {
                Label(L10n.text("新掃描"), systemImage: "plus.viewfinder")
            }
            .buttonStyle(DSSecondaryButtonStyle(fill: true))
        case .review:
            HStack(spacing: DS.Space.xs) {
                Button { controller.resumeScan() } label: {
                    Label(L10n.text("續掃"), systemImage: "plus.viewfinder")
                }
                .buttonStyle(DSSecondaryButtonStyle(fill: true))
                .disabled(!controller.canResumeScan)
                Button(role: .destructive) { showDiscardConfirm = true } label: {
                    Label(L10n.text("捨棄本次掃描"), systemImage: "trash")
                }
                .buttonStyle(DSIconButtonStyle(foreground: DS.Palette.danger))
            }
        default:
            EmptyView()
        }
    }

    // MARK: - 設定與品質資訊

    private var scanSettings: some View {
        NavigationStack {
            Form {
                Section {
                    if controller.supportsLiDAR {
                        Toggle(L10n.text("LiDAR 深度掃描"), isOn: Binding(
                            get: { controller.useLiDAR }, set: { controller.setLiDAREnabled($0) }))
                    }
                    Text(controller.hasLiDAR ? L10n.text("深度量測與彩色點雲") : L10n.text("僅相機追蹤，保留影像與稀疏點雲"))
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: { Text(L10n.text("掃描模式")) }

                Section {
                    if controller.hasLiDAR {
                        Toggle(isOn: $controller.reconstructSurfaces) {
                            settingLabel(L10n.text("表面重建（實驗）"), L10n.text("包含姿態精修；容量或涵蓋不足時使用原融合"))
                        }
                        Toggle(isOn: Binding(get: {
                            controller.refineCameraPoses || controller.reconstructSurfaces
                        }, set: { controller.refineCameraPoses = $0 })) {
                            settingLabel(L10n.text("精細掃描"), controller.reconstructSurfaces
                                ? L10n.text("表面重建已包含姿態精修")
                                : L10n.text("校正相機位置，完成後需較多處理時間"))
                        }
                        .disabled(controller.reconstructSurfaces)
                    } else {
                        Toggle(isOn: $controller.reconstructFromImages) {
                            settingLabel(L10n.text("影像深度重建"), L10n.text("停止後以重疊照片重建點雲，需較多處理時間"))
                        }
                    }
                } header: { Text(L10n.text("品質與處理")) }
                  footer: { Text(L10n.text("設定只影響接下來的掃描。完成後的處理時間依照片數量與場景而異。")) }

                Section {
                    Toggle(L10n.text("鎖定曝光 / 白平衡"), isOn: $controller.lockCameraParams)
                    CameraControlBar(controls: controller.cameraControls, enabled: controller.trackingReady)
                } header: { Text(L10n.text("相機進階控制")) }
                if let info = WorldMapStore.latestInfo() {
                    Section {
                        Toggle(isOn: Binding(get: { controller.continueFromLastMap },
                                             set: { controller.setContinueFromLastMap($0) })) {
                            Text(String(format: L10n.text("延續上次座標系（%.1f MB · %@）"),
                                        Double(info.bytes) / 1_048_576, Self.ago(info.modified)))
                        }
                    } header: { Text(L10n.text("座標系")) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Palette.canvas)
            .navigationTitle(L10n.text("掃描設定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("完成")) { showAdvanced = false }
            } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DS.Palette.canvas)
        .presentationCornerRadius(DS.Radius.xl)
        .preferredColorScheme(.dark)
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 3)
    }

    private var hasScanDetails: Bool {
        controller.statusText != nil || controller.scanSummary.map({ !summaryRows($0).isEmpty }) == true
    }

    private var scanDetails: some View {
        NavigationStack {
            List {
                if let notice = controller.statusText {
                    Section { Label(notice, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(DS.Palette.warning) }
                }
                if let summary = controller.scanSummary {
                    Section {
                        ForEach(summaryRows(summary), id: \.text) { row in
                            Label(row.text, systemImage: row.symbol)
                                .font(.subheadline).foregroundStyle(row.tint)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Palette.canvas)
            .navigationTitle(L10n.text("掃描品質資訊"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("完成")) { summaryExpanded = false }
            } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DS.Palette.canvas)
        .presentationCornerRadius(DS.Radius.xl)
        .preferredColorScheme(.dark)
    }

    private func summaryRows(_ s: ScanSummary) -> [(text: String, symbol: String, tint: Color)] {
        var rows: [(String, String, Color)] = []
        // 迴環：未閉合代表 ARKit 沒機會做全域修正，遠端誤差留在資料裡
        if s.traveledM >= 8 && !s.loopClosed {
            rows.append((String(format: L10n.text("走了 %.0fm 未回起點 —— 遠端可能有累積漂移"), s.traveledM),
                         "arrow.triangle.capsulepath", DS.Palette.warning))
        }
        // 漂移修正幅度：大代表這次追蹤本來就飄，全域幾何可信度低
        if s.driftMaxCm >= 10 {
            rows.append((String(format: L10n.text("姿態修正 中位數 %.0fcm / 最大 %.0fcm"),
                                s.driftMedianCm, s.driftMaxCm),
                         "scope", s.driftMaxCm >= 30 ? DS.Palette.danger : DS.Palette.warning))
        }
        if s.blurDropped + s.blurDemoted > 0 {
            rows.append((s.blurDropped > 0
                         ? L10n.text("排除 \(s.blurDropped) 幀（幾何不可信）、\(s.blurDemoted) 幀（RGB 品質篩選）")
                         : L10n.text("\(s.blurDemoted) 幀未選為訓練影像，深度仍供融合"),
                         "camera.metering.none", DS.Palette.textSecondary))
        }
        if let mb = s.worldMapMB {
            rows.append((String(format: L10n.text("世界地圖已存 %.1f MB —— 下次可延續同一座標系"), mb),
                         "point.3.filled.connected.trianglepath.dotted", DS.Palette.textSecondary))
        }
        // BA 的判定。**用保留集，不用 BA 自己的殘差** —— 後者下降是必然的（那是它在
        // 最小化的量），拿它報告「精度改善了幾 %」等於自我認證。
        if let d = s.baHoldoutDelta {
            let pct = String(format: "%+.0f%%", d * 100)
            if s.baApplied {
                rows.append((L10n.text("BA 已套用位姿（保留集 \(pct)）"), "checkmark.circle", DS.Palette.textSecondary))
            } else if d < BundleAdjuster.kHoldoutGate {
                // 閘門過了卻沒套用 ⇒ 硬總開關被關著。這是非預期狀態，要看得見
                rows.append((L10n.text("BA 保留集 \(pct) 通過，但總開關關著 ⇒ 位姿未修正"),
                             "exclamationmark.triangle", DS.Palette.warning))
            } else {
                // 這是正常結果，不是問題：房間尺度下位姿誤差本來就低於觀測雜訊
                rows.append((L10n.text("BA 未套用（保留集 \(pct)，此距離下位姿誤差低於觀測雜訊）"),
                             "pause.circle", DS.Palette.textSecondary))
            }
        }
        return rows.map { (text: $0.0, symbol: $0.1, tint: $0.2) }
    }
}

/// Stats read right-aligned with the icon after the value.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon.font(.caption2).foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

/// The shutter shrinks slightly while pressed; the ring and fill carry the state.
private struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(DS.springy, value: configuration.isPressed)
            .hoverEffect(.lift)
    }
}
