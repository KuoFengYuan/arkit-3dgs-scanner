// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import SwiftUI

/// The single on-device 3DGS experience of a saved scan, opened from History and right after
/// a capture. Setup → live training (interactive preview of the current model, metrics and
/// controls) → the saved model's interactive viewer. Interrupted runs resume from a checkpoint.
struct GaussianTrainingView: View {
    let scan: URL
    var onLibraryChange: () -> Void = {}

    @ObservedObject private var center = TrainingCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var record: TrainingRecord?
    @State private var hasCheckpoint = false
    @State private var hasModel = false
    @State private var preset: GaussianTrainingConfiguration.Preset = .standard
    @State private var resolution: GaussianTrainingConfiguration.Resolution = .low
    @State private var poseOptimization = true
    @State private var ppisp = true
    @State private var mipFilter = true
    @State private var estimate: TrainingMemoryPlan?
    @State private var estimateError: String?
    @State private var viewer: GaussianModelViewer?
    @State private var loadingViewer = false
    @State private var modelFrame: CGImage?
    @State private var orbit: OrbitCamera?
    @State private var ispMode: ISPMode = .camera
    @State private var viewPixels: CGSize = .zero
    @State private var interacting = false
    @State private var confirmStop = false
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var confirmRestartFromMenu = false
    @State private var estimateGeneration = 0
    @State private var confirmRestart = false
    @State private var archive: URL?
    @State private var preparingArchive = false
    @State private var errorText: String?
    @State private var cover: URL?
    @State private var exposureRange: Double?
    @State private var debugIterations: Int?
    @State private var frameCount: Int?
    @State private var showAdvanced = false
    /// Enhance model: the setup continues the saved model instead of starting a new one.
    @State private var enhancing = false
    @State private var savedModel: GaussianExport.Metadata?
    @State private var confirmFinish = false
    @State private var showGestureHint = true

    private var workspace: TrainingWorkspace { TrainingWorkspace(scan: scan) }
    private var displayedFrame: CGImage? { isActive ? center.frame : modelFrame }
    private var isActive: Bool { center.isActive(scan) }
    private var snapshot: TrainingSnapshot { center.snapshot }
    private var otherScanTraining: Bool { center.isBusy && !isActive }
    /// An unfinished run (for example a retrain) that can resume; it takes precedence over a
    /// saved model, which stays until the new run completes.
    private var hasResumableRun: Bool { hasCheckpoint && record?.status != .completed }
    private var showsModel: Bool { !isActive && hasModel && !hasResumableRun }
    private var supported: Bool { GaussianMetal.isSupported }
    /// The ISP choice only matters when the run learned PPISP.
    private var usesPPISP: Bool {
        isActive ? (center.configuration?.ppisp == true) : (viewer?.metadata.ppisp != nil)
    }

    var body: some View {
        ZStack {
            DS.Palette.canvas.ignoresSafeArea()
            surface.ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) { topOverlay }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomPanel }
        .navigationTitle(L10n.text("3DGS 訓練"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DS.Palette.canvas.opacity(0.85), for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if showsModel || isActive {
                    Menu {
                        if usesPPISP {
                            Picker(L10n.text("色彩校正"), selection: $ispMode) {
                                Label(L10n.text("PPISP 相機校正"), systemImage: "camera.filters").tag(ISPMode.camera)
                                Label(L10n.text("未校正（與匯出檔相同）"), systemImage: "circle.slash").tag(ISPMode.off)
                            }
                        }
                        Button { resetView() } label: { Label(L10n.text("重設視角"), systemImage: "scope") }
                        if showsModel {
                            Divider()
                            Button { confirmRestartFromMenu = true } label: { Label(L10n.text("重新訓練"), systemImage: "arrow.counterclockwise") }
                            Button(role: .destructive) { confirmDelete = true } label: { Label(L10n.text("刪除 3DGS 模型"), systemImage: "trash") }
                        }
                    } label: {
                        Label(L10n.text("檢視選項"), systemImage: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("gaussianViewOptions")
                    // Confirmations open from the control that asked for them.
                    .confirmationDialog(L10n.text("重新訓練？"), isPresented: $confirmRestartFromMenu, titleVisibility: .visible) {
                        restartActions
                    } message: { Text(L10n.text("新的模型完成後才會取代目前的模型。")) }
                    .confirmationDialog(L10n.text("刪除 3DGS 模型？"), isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button(L10n.text("刪除模型與訓練進度"), role: .destructive) { deleteTraining() }
                        Button(L10n.text("取消"), role: .cancel) {}
                    } message: { Text(L10n.text("只刪除訓練結果；掃描的照片、深度與姿態不受影響。")) }
                }
            }
        }
        .task {
            await reload()
            #if DEBUG
            // `--preview-training-start`: start the selected preset right away (UI checks);
            // `--training-iterations N` shortens the run.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains(where: { $0.hasPrefix("--preview-training-start") }), !isActive, !hasModel, !hasCheckpoint {
                preset = .quick
                debugIterations = arguments.firstIndex(of: "--training-iterations").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
                start(resume: false)
            }
            if arguments.contains("--preview-training-resume"), !isActive, hasCheckpoint { start(resume: true) }
            #endif
        }
        .onChange(of: center.revision) { _, _ in Task { await reload() } }
        .onChange(of: center.views.count) { _, _ in if orbit == nil { resetView() } }
        .onChange(of: ispMode) { _, _ in requestFrame() }
        .onDisappear {
            center.updateViewer(nil, interactive: false)
            viewer = nil
        }
        .alert(L10n.text("無法完成操作"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L10n.text("好")) { errorText = nil }
        } message: { Text(errorText ?? "") }
        .sensoryFeedback(.success, trigger: snapshot.phase == .completed && isActive == false && hasModel)
        .sheet(isPresented: $showAdvanced) { advancedSheet }
        .task(id: displayedFrame != nil) {
            // The gesture hint fades once the model is on screen for a few seconds.
            guard displayedFrame != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            withAnimation(DS.springy) { showGestureHint = false }
        }
    }

    // MARK: Surface

    @ViewBuilder
    private var surface: some View {
        if isActive || showsModel {
            GaussianViewport(image: isActive ? center.frame : modelFrame,
                             onOrbit: { d in orbit?.orbit(dx: d.width, dy: d.height); requestFrame() },
                             onPan: { d, h in orbit?.pan(dx: d.width, dy: d.height, viewHeight: h); requestFrame() },
                             onZoom: { s in orbit?.zoom(s); requestFrame() },
                             onReset: { resetView() },
                             onInteraction: { interacting = $0; if $0 { showGestureHint = false }; requestFrame() },
                             onSize: { viewPixels = $0; requestFrame() })
                .overlay {
                    if (isActive ? center.frame : modelFrame) == nil {
                        VStack(spacing: DS.Space.s) {
                            ProgressView().tint(.white)
                            Text(isActive ? L10n.text("準備預覽…") : L10n.text("載入 3DGS 模型…"))
                                .font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                }
                .accessibilityLabel(L10n.text("3DGS 模型預覽，單指旋轉、雙指平移、捏合縮放"))
        } else {
            ZStack {
                if hasCheckpoint, FileManager.default.fileExists(atPath: workspace.snapshotURL.path) {
                    // Last checkpoint's model, shown dimmed until training resumes.
                    ScanPhoto(url: workspace.snapshotURL, maxDimension: 1200, orientation: .up).opacity(0.7)
                        .accessibilityLabel(L10n.text("上次儲存時的 3DGS 模型"))
                } else if let cover {
                    // The scan itself, softened, behind the setup card.
                    ScanPhoto(url: cover, maxDimension: 1200).opacity(0.55).blur(radius: 6)
                        .overlay(LinearGradient(colors: [.clear, DS.Palette.canvas.opacity(0.85)], startPoint: .center, endPoint: .bottom))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(DS.Palette.accent)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 160)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: Top

    /// The viewer stays clear: notices only, a short gesture hint and the ISP state of a saved
    /// model. Progress and statistics live in the bottom card.
    private var topOverlay: some View {
        VStack(spacing: DS.Space.xs) {
            if let notice = notice {
                DSStatusPill(text: notice.text, symbol: notice.symbol, tone: notice.tone)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if isActive && snapshot.phase == .running && snapshot.throttled {
                DSStatusPill(text: L10n.text("訓練中（降速以控制溫度與電量）"), symbol: "thermometer.medium", tone: .warning)
            } else if showGestureHint && (isActive || showsModel) && displayedFrame != nil {
                DSStatusPill(text: L10n.text("拖曳旋轉・雙指平移・捏合縮放"), symbol: "hand.draw")
                    .transition(.opacity)
            }
            if showsModel && usesPPISP {
                DSMetric(value: ispMode == .camera ? L10n.text("PPISP 校正") : L10n.text("未校正"), symbol: "camera.filters",
                         tone: ispMode == .camera ? .accent : .neutral)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
        .animation(DS.springy, value: snapshot.phase)
        .animation(DS.springy, value: showGestureHint)
    }

    private struct Notice { let text: String; let symbol: String; let tone: DS.Tone }

    private var notice: Notice? {
        if !supported { return Notice(text: L10n.text("這台裝置的 GPU 不支援手機端 3DGS 訓練（需要 A14 或更新的晶片）"), symbol: "xmark.octagon", tone: .danger) }
        if isActive {
            if let message = snapshot.message { return Notice(text: message, symbol: "exclamationmark.triangle", tone: .warning) }
            if snapshot.phase == .paused, let reason = snapshot.reason { return Self.pauseNotice(reason) }
            if snapshot.growthFrozen { return Notice(text: L10n.text("為避免記憶體不足，已停止增加高斯"), symbol: "memorychip", tone: .warning) }
            return nil
        }
        if otherScanTraining { return Notice(text: L10n.text("另一筆掃描正在訓練，完成或停止後才能開始"), symbol: "hourglass", tone: .info) }
        if let viewerError = errorTextForViewer { return Notice(text: viewerError, symbol: "exclamationmark.triangle", tone: .warning) }
        if showsModel, let message = record?.errorMessage {
            return Notice(text: L10n.text("上次重新訓練沒有完成：\(message)"), symbol: "exclamationmark.triangle", tone: .warning)
        }
        // A saved checkpoint is explained by the resume card; only problems get a notice here.
        if let record, !hasModel {
            switch record.status {
            case .interrupted where !hasCheckpoint:
                return Notice(text: L10n.text("上次訓練中斷，沒有可用的進度"), symbol: "exclamationmark.arrow.circlepath", tone: .warning)
            case .failed: return Notice(text: record.errorMessage ?? L10n.text("訓練失敗"), symbol: "exclamationmark.triangle", tone: .danger)
            default: return nil
            }
        }
        return nil
    }

    @State private var errorTextForViewer: String?

    private static func pauseNotice(_ reason: TrainingRecord.Reason) -> Notice {
        switch reason {
        case .background: return Notice(text: L10n.text("App 不在前景時無法使用 GPU，已暫停並儲存進度；回到 App 後會自動繼續"), symbol: "moon.fill", tone: .info)
        case .thermal: return Notice(text: L10n.text("裝置過熱，已自動暫停並儲存進度；降溫後會自動繼續"), symbol: "thermometer.high", tone: .warning)
        case .battery: return Notice(text: L10n.text("電量低於 15%，已暫停；接上電源後會自動繼續"), symbol: "battery.25", tone: .warning)
        case .memory: return Notice(text: L10n.text("可用記憶體不足，已儲存進度並暫停訓練。關閉其他 App 後可繼續。"), symbol: "memorychip", tone: .warning)
        case .capture: return Notice(text: L10n.text("正在拍攝，3DGS 訓練先暫停；結束拍攝後會自動繼續"), symbol: "camera.viewfinder", tone: .info)
        default: return Notice(text: L10n.text("已暫停，進度已儲存"), symbol: "pause.circle", tone: .neutral)
        }
    }

    // MARK: Bottom

    private var bottomPanel: some View {
        VStack(spacing: DS.Space.s) {
            if isActive { activeControls }
            else if showsModel && !enhancing { modelActions }
            else { setupPanel }
        }
        .padding(DS.Space.m)
        .dsFloatingPanel(radius: DS.Radius.xl + 4)
        .frame(maxWidth: DS.Size.panelMaxWidth)
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
        .frame(maxWidth: .infinity)
        .animation(DS.springy, value: isActive)
        .animation(DS.springy, value: enhancing)
    }

    private var activeControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                progressRing(snapshot.phase == .preparing ? snapshot.preparationProgress : TrainingPresentation.fraction(snapshot),
                             tint: snapshot.phase == .paused ? DS.Palette.warning : DS.Palette.accent) {
                    Text(snapshot.phase == .preparing ? "…" : "\(TrainingPresentation.percent(snapshot))%")
                        .font(.footnote.weight(.bold).monospacedDigit())
                }
                .accessibilityElement()
                .accessibilityLabel(L10n.text("訓練進度"))
                .accessibilityValue("\(TrainingPresentation.percent(snapshot))%")
                VStack(alignment: .leading, spacing: 2) {
                    Text(TrainingPresentation.stage(snapshot)).font(.headline).foregroundStyle(DS.Palette.textPrimary)
                    if let line = activeSubtitle {
                        Text(line).font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(metricsLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.xs) {
                if snapshot.phase == .paused {
                    Button { center.resume() } label: { Label(L10n.text("繼續訓練"), systemImage: "play.fill") }
                        .buttonStyle(DSPrimaryButtonStyle())
                        .accessibilityIdentifier("resumeTraining")
                } else {
                    Button { center.pause() } label: { Label(L10n.text("暫停"), systemImage: "pause.fill") }
                        .buttonStyle(DSPrimaryButtonStyle(fill: true, isLoading: snapshot.phase == .preparing || snapshot.phase == .finishing))
                        .disabled(snapshot.phase != .running)
                        .accessibilityIdentifier("pauseTraining")
                }
                Button { center.checkpoint() } label: { Label(L10n.text("儲存進度"), systemImage: "square.and.arrow.down") }
                    .buttonStyle(DSIconButtonStyle(size: DS.Size.primaryHeight))
                    .disabled(snapshot.phase != .running && snapshot.phase != .paused)
                    .accessibilityIdentifier("checkpointTraining")
                Button { confirmStop = true } label: { Label(L10n.text("停止訓練"), systemImage: "stop.fill") }
                    .buttonStyle(DSIconButtonStyle(size: DS.Size.primaryHeight, foreground: DS.Palette.danger))
                    .disabled(snapshot.phase == .finishing)
                    .accessibilityIdentifier("stopTraining")
                    .confirmationDialog(L10n.text("停止訓練？"), isPresented: $confirmStop, titleVisibility: .visible) {
                        Button(L10n.text("停止並保留進度")) { center.cancel(keepCheckpoint: true) }
                        Button(L10n.text("停止並刪除這次訓練"), role: .destructive) { center.cancel(keepCheckpoint: false) }
                        Button(L10n.text("繼續訓練"), role: .cancel) {}
                    } message: {
                        Text(L10n.text("保留進度時會先儲存目前的檢查點，之後可從掃描紀錄繼續。"))
                    }
            }
            // Good enough already: keep the current model as the result and end the run.
            Button { confirmFinish = true } label: { Label(L10n.text("完成並保存模型"), systemImage: "checkmark.seal") }
                .buttonStyle(DSSecondaryButtonStyle(fill: true, tint: DS.Palette.success))
                .disabled((snapshot.phase != .running && snapshot.phase != .paused) || snapshot.iteration <= snapshot.startIteration)
                .accessibilityIdentifier("finishTraining")
                .confirmationDialog(L10n.text("現在完成並保存模型？"), isPresented: $confirmFinish, titleVisibility: .visible) {
                    Button(L10n.text("完成並保存")) { center.finishNow() }
                    Button(L10n.text("繼續訓練"), role: .cancel) {}
                } message: {
                    Text(L10n.text("以目前的訓練結果建立模型並結束訓練。之後可以用「加強模型」繼續訓練它。"))
                }
            Label(center.continuesInBackground ? L10n.text("可以切到其他 App，訓練會在背景繼續")
                                               : L10n.text("可以在 App 內切換頁面；切到其他 App 時會先暫停並儲存進度"),
                  systemImage: center.continuesInBackground ? "arrow.triangle.2.circlepath" : "pause.circle")
                .font(.caption2).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let checkpoint = snapshot.checkpointIteration {
                    Label(L10n.text("已儲存至第 \(checkpoint.formatted()) 次迭代"), systemImage: "checkmark.icloud")
                }
                Spacer()
                Text(L10n.text("App 記憶體 \(snapshot.footprintMB) MB・訓練配置 \(snapshot.plannedMB) MB"))
            }
            .font(.caption2)
            .foregroundStyle(DS.Palette.textTertiary)
        }
    }

    private var activeSubtitle: String? {
        switch snapshot.phase {
        case .paused: return L10n.text("進度已儲存，可隨時繼續")
        case .running: return TrainingPresentation.remaining(snapshot)
        case .finishing: return L10n.text("即將完成")
        default: return nil
        }
    }

    /// Iteration, Gaussians, loss, PSNR and elapsed time in one quiet line.
    private var metricsLine: String {
        var parts = [L10n.text("迭代 \(snapshot.iteration.formatted()) / \(snapshot.total.formatted())"),
                     L10n.text("\(snapshot.gaussians.formatted()) 個高斯")]
        if let loss = snapshot.loss { parts.append(String(format: L10n.text("損失 %.4f"), loss)) }
        if let psnr = snapshot.psnr { parts.append(String(format: "PSNR %.1f dB", psnr)) }
        parts.append(L10n.text("用時 \(Self.duration(snapshot.elapsedSeconds))"))
        // Wrap between items, never inside one ("PSNR" / "15.2 dB").
        return parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "・")
    }

    private func progressRing<Label: View>(_ progress: Double, tint: Color, @ViewBuilder label: () -> Label) -> some View {
        ZStack {
            DSProgressRing(progress: progress, lineWidth: 5, tint: tint)
            label().foregroundStyle(DS.Palette.textPrimary)
        }
        .frame(width: 54, height: 54)
    }

    /// The saved model: summary, then sharing in the same card layout as the scan's export.
    @ViewBuilder
    private var modelActions: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(DS.Palette.success)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("3DGS 模型完成")).font(.headline).foregroundStyle(DS.Palette.textPrimary)
                    if let record {
                        Text(modelSummary(record)).font(.caption.monospacedDigit()).foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, DS.Space.xxs)
            Button { withAnimation(DS.springy) { beginEnhancing() } } label: {
                DSActionCardLabel(title: L10n.text("加強模型"),
                                  subtitle: L10n.text("從這個模型繼續訓練，也可以改用更高的解析度"),
                                  tint: DS.Palette.accent) {
                    DSActionIcon(symbol: "wand.and.sparkles", tint: DS.Palette.accent)
                }
            }
            .buttonStyle(DSCardButtonStyle())
            .disabled(!supported || otherScanTraining || savedModel == nil)
            .accessibilityIdentifier("enhanceGaussianModel")
            Button { Task { await share() } } label: {
                DSActionCardLabel(title: preparingArchive ? L10n.text("處理中…") : L10n.text("分享 3DGS 模型"),
                                  subtitle: usesPPISP ? L10n.text("PLY 格式，可用一般 3DGS 檢視器開啟；色彩校正另存 ppisp.json")
                                                      : L10n.text("PLY 格式，可用一般 3DGS 檢視器開啟"),
                                  tint: DS.Palette.info) {
                    if preparingArchive { ProgressView().tint(DS.Palette.info) }
                    else { DSActionIcon(symbol: "square.and.arrow.up", tint: DS.Palette.info) }
                }
            }
            .buttonStyle(DSCardButtonStyle())
            .disabled(preparingArchive)
            .accessibilityIdentifier("exportGaussianModel")
        }
    }

    private func modelSummary(_ record: TrainingRecord) -> String {
        var parts = [record.finishedEarly ? L10n.text("\(record.iteration.formatted()) 次迭代（提前完成）") : L10n.text("\(record.iteration.formatted()) 次迭代"),
                     L10n.text("\(record.gaussians.formatted()) 個高斯"),
                     L10n.text("用時 \(Self.duration(record.elapsedSeconds))")]
        if let psnr = record.validationPSNR { parts.append(String(format: L10n.text("驗證 PSNR %.1f dB"), psnr)) }
        return parts.joined(separator: "・")
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if enhancing, let savedModel {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(L10n.text("加強 3DGS 模型")).font(.title3.weight(.bold)).foregroundStyle(DS.Palette.textPrimary)
                        Text(L10n.text("從已保存的模型（\(savedModel.iterations.formatted()) 次迭代・\(savedModel.gaussians.formatted()) 個高斯）繼續訓練；新的結果完成前，會保留目前的模型。"))
                            .font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.Space.xs)
                    Button(L10n.text("取消")) { withAnimation(DS.springy) { enhancing = false } }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("cancelEnhance")
                }
                setupChoices(startTitle: L10n.text("開始加強"), identifier: "startEnhance")
            } else if hasCheckpoint, let record {
                HStack(spacing: DS.Space.s) {
                    progressRing(record.progress, tint: DS.Palette.warning) {
                        Image(systemName: "pause.fill").font(.footnote.weight(.bold))
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("繼續訓練 3DGS")).font(.headline).foregroundStyle(DS.Palette.textPrimary)
                        Text(L10n.text("已完成 \(Int(record.progress * 100))%，上次進度已儲存"))
                            .font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                Button { start(resume: true) } label: { Label(L10n.text("從上次進度繼續"), systemImage: "play.fill") }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(!supported || otherScanTraining)
                    .accessibilityIdentifier("resumeFromCheckpoint")
                HStack {
                    Button { confirmRestart = true } label: { Label(L10n.text("重新開始"), systemImage: "arrow.counterclockwise") }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .confirmationDialog(L10n.text("重新訓練？"), isPresented: $confirmRestart, titleVisibility: .visible) {
                            restartActions
                        } message: { Text(L10n.text("新的模型完成後才會取代目前的模型。")) }
                    Spacer()
                    Button(role: .destructive) { confirmDiscard = true } label: { Label(L10n.text("刪除進度"), systemImage: "trash") }
                        .buttonStyle(DSSecondaryButtonStyle(tint: DS.Palette.danger))
                        .confirmationDialog(L10n.text("刪除訓練進度？"), isPresented: $confirmDiscard, titleVisibility: .visible) {
                            Button(L10n.text("刪除進度"), role: .destructive) { discardProgress() }
                            Button(L10n.text("取消"), role: .cancel) {}
                        } message: {
                            Text(hasModel ? L10n.text("只刪除這次未完成的訓練；已完成的 3DGS 模型會保留。")
                                          : L10n.text("只刪除訓練進度；掃描的照片、深度與姿態不受影響。"))
                        }
                }
                .disabled(!supported || otherScanTraining)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(L10n.text("訓練 3DGS")).font(.title3.weight(.bold)).foregroundStyle(DS.Palette.textPrimary)
                    Text(frameCount.map { L10n.text("用這次掃描的 \($0.formatted()) 張照片在 iPhone 上建立模型，完成後可自由旋轉檢視並分享。") }
                         ?? L10n.text("用這次掃描的照片在 iPhone 上建立模型，完成後可自由旋轉檢視並分享。"))
                        .font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                setupChoices(startTitle: L10n.text("開始訓練"), identifier: "startTraining")
            }
        }
        .onChange(of: preset) { _, _ in Task { await updateEstimate() } }
        .onChange(of: resolution) { _, _ in Task { await updateEstimate() } }
    }

    /// Quality cards, resolution, memory check, and the start button (new run or enhancement).
    @ViewBuilder
    private func setupChoices(startTitle: String, identifier: String) -> some View {
        VStack(spacing: DS.Space.xs) {
            ForEach(GaussianTrainingConfiguration.Preset.allCases, id: \.self) { presetCard($0) }
        }
        resolutionPicker
        readiness
        HStack(spacing: DS.Space.xs) {
            Button { showAdvanced = true } label: { Label(L10n.text("進階設定"), systemImage: "slider.horizontal.3") }
                .buttonStyle(DSIconButtonStyle(size: DS.Size.primaryHeight))
                .accessibilityIdentifier("trainingAdvancedSettings")
            Button { start(resume: false) } label: { Label(startTitle, systemImage: enhancing ? "wand.and.sparkles" : "sparkles") }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(!supported || otherScanTraining || estimateError != nil)
                .accessibilityIdentifier(identifier)
        }
    }

    /// Training image resolution: low (960 px), medium (1440 px) or the photos' own (1920 px).
    private var resolutionPicker: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(L10n.text("訓練解析度")).font(.subheadline.weight(.semibold)).foregroundStyle(DS.Palette.textPrimary)
            DSSegmentedPicker(segments: GaussianTrainingConfiguration.Resolution.allCases.map {
                DSSegment(value: $0, title: TrainingPresentation.title($0), symbol: $0 == .high ? "sparkles.rectangle.stack" : $0 == .medium ? "rectangle.stack" : "rectangle")
            }, selection: $resolution, fillsWidth: true)
            .accessibilityLabel(L10n.text("訓練解析度"))
            .accessibilityIdentifier("trainingResolution")
            Text(TrainingPresentation.detail(resolution)).font(.caption).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One quality choice: what it is for, in words, and how long it took here before.
    private func presetCard(_ value: GaussianTrainingConfiguration.Preset) -> some View {
        let selected = preset == value
        let config = configuration(for: value, enhance: enhancing)
        let estimate = TrainingSpeedHistory.estimatedSeconds(config)
        return Button { withAnimation(DS.springy) { preset = value } } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: TrainingPresentation.symbol(value))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? DS.Palette.accent : DS.Palette.textSecondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(enhancing ? TrainingPresentation.enhanceTitle(value) : TrainingPresentation.title(value)).font(.subheadline.weight(.semibold))
                            .foregroundStyle(DS.Palette.textPrimary)
                        if value == .standard {
                            Text(L10n.text("建議")).font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .foregroundStyle(DS.Palette.onAccent)
                                .background(DS.Palette.accent, in: Capsule())
                        }
                    }
                    Text(enhancing ? TrainingPresentation.enhanceDetail(config.runIterations) : TrainingPresentation.detail(value))
                        .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let estimate {
                    Text(TrainingPresentation.approximate(estimate)).font(.caption.monospacedDigit())
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? DS.Palette.accent : DS.Palette.textTertiary)
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 10)
            .background(selected ? DS.Palette.accent.opacity(0.12) : DS.Palette.surface,
                        in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .strokeBorder(selected ? DS.Palette.accent.opacity(0.8) : DS.Palette.stroke, lineWidth: selected ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("trainingPreset.\(value.rawValue)")
    }

    /// Memory check and the two things the user should do while training.
    private var readiness: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let estimateError {
                Label(estimateError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if estimate != nil {
                Label { Text(L10n.text("記憶體足夠")).foregroundStyle(DS.Palette.textSecondary) } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.success)
                }
            }
            Label { Text(L10n.text("訓練時可以使用 App 的其他功能，建議接上電源；可隨時暫停，進度會自動儲存。"))
                .foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "bolt.fill").foregroundStyle(DS.Palette.warning)
            }
        }
        .font(.caption)
    }

    private var advancedSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $poseOptimization) {
                        setting(L10n.text("相機姿態微調"), L10n.text("以 ARKit 姿態為基準微調，保留公制尺度"))
                    }
                    Toggle(isOn: $ppisp) {
                        setting(L10n.text("PPISP 色彩校正"), ppispDetail)
                    }
                    Toggle(isOn: $mipFilter) {
                        setting(L10n.text("抗鋸齒（Mip 濾波）"), L10n.text("縮放檢視時減少閃爍與鋸齒"))
                    }
                } footer: { Text(L10n.text("大多數掃描維持預設即可。")) }
                Section {
                    Text(presetDescription).font(.subheadline)
                    if let estimate {
                        Text(L10n.text("預估記憶體 \(estimate.totalBytes >> 20) MB・最多 \(estimate.gaussianCapacity.formatted()) 個高斯"))
                            .font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                    }
                } header: { Text(L10n.text("\(TrainingPresentation.title(preset))的訓練規格")) }
            }
            .tint(DS.Palette.accent)
            .scrollContentBackground(.hidden)
            .background(DS.Palette.canvas)
            .navigationTitle(L10n.text("進階設定"))
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

    @ViewBuilder
    private var restartActions: some View {
        Button(L10n.text("以目前設定重新訓練")) { start(resume: false, configuration: configuration(for: preset, enhance: false)) }
        Button(L10n.text("取消"), role: .cancel) {}
    }

    private var ppispDetail: String {
        guard let range = exposureRange else { return L10n.text("補償照片間的曝光、白平衡與暗角差異") }
        return range < TrainingDataset.ppispExposureThreshold
            ? String(format: L10n.text("拍攝時曝光固定（變化 %.2f EV），預設關閉；仍可補償暗角與色調"), range)
            : String(format: L10n.text("拍攝時曝光變化 %.1f EV，建議開啟以補償曝光與白平衡差異"), range)
    }

    private func setting(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            Text(detail).font(.caption).foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private var configuration: GaussianTrainingConfiguration { configuration(for: preset, enhance: enhancing) }

    /// The run a quality choice starts: a new model, or `iterations` more on the saved model.
    private func configuration(for preset: GaussianTrainingConfiguration.Preset, enhance: Bool) -> GaussianTrainingConfiguration {
        var c = GaussianTrainingConfiguration.preset(preset)
        c.longEdge = resolution.longEdge
        c.poseOptimization = poseOptimization
        c.ppisp = ppisp
        c.mipFilter = mipFilter
        if let debugIterations { c.iterations = debugIterations }
        if enhance, let savedModel {
            c = c.enhancing(savedIterations: savedModel.iterations, savedGaussians: savedModel.gaussians,
                            savedSHDegree: savedModel.shDegree)
        }
        return c
    }

    /// Opens the enhancement setup with the saved model's settings.
    private func beginEnhancing() {
        guard let saved = savedModel else { return }
        let c = saved.configuration
        resolution = c.resolution
        poseOptimization = c.poseOptimization
        ppisp = c.ppisp
        mipFilter = c.mipFilter
        preset = .standard
        enhancing = true
        Task { await updateEstimate() }
    }

    private var presetDescription: String {
        let c = configuration
        if c.isEnhancement {
            return L10n.text("再訓練 \(c.runIterations.formatted()) 次（共 \(c.iterations.formatted()) 次）・訓練影像長邊 \(c.longEdge) px・最多 \(c.maxGaussians.formatted()) 個高斯・SH \(c.shDegree) 階")
        }
        return L10n.text("\(c.iterations.formatted()) 次迭代・訓練影像長邊 \(c.longEdge) px・最多 \(c.maxGaussians.formatted()) 個高斯・SH \(c.shDegree) 階")
    }

    // MARK: Actions

    private func start(resume: Bool, configuration override: GaussianTrainingConfiguration? = nil) {
        let config: GaussianTrainingConfiguration
        if resume, let saved = GaussianCheckpoint.header(at: workspace.checkpointURL)?.configuration { config = saved }
        else { config = override ?? configuration }
        orbit = nil
        guard center.start(scan: scan, configuration: config, resume: resume) else {
            errorText = L10n.text("另一筆掃描正在訓練，完成或停止後才能開始")
            return
        }
        viewer = nil
        modelFrame = nil
        archive = nil
        enhancing = false
        onLibraryChange()
    }

    /// Deletes the model, its share archive and any progress.
    private func deleteTraining() {
        viewer = nil
        modelFrame = nil
        do { try workspace.removeTraining() } catch { errorText = error.localizedDescription }
        archive = nil
        onLibraryChange()
        Task { await reload() }
    }

    /// Deletes only the unfinished run; a saved model stays.
    private func discardProgress() {
        do { try workspace.discardProgress() } catch { errorText = error.localizedDescription }
        onLibraryChange()
        Task { await reload() }
    }

    /// One tap: builds the model archive if needed, then opens the share sheet.
    private func share() async {
        if archive == nil {
            preparingArchive = true
            defer { preparingArchive = false }
            let workspace = self.workspace
            do { archive = try await Task.detached(priority: .userInitiated) { try workspace.makeModelArchive() }.value }
            catch { errorText = error.localizedDescription; return }
        }
        if let archive { SystemShare.present([archive]) }
    }

    private func reload() async {
        let workspace = self.workspace
        let activeScan = center.activeScan
        let loaded = await Task.detached(priority: .userInitiated) { () -> (TrainingRecord?, Bool, Bool, URL?, Double?, Int?, GaussianExport.Metadata?) in
            let images = workspace.scan.appendingPathComponent("images")
            let first = (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
            let selection = (try? Data(contentsOf: workspace.scan.appendingPathComponent("training-selection.json")))
                .flatMap { try? JSONDecoder().decode(TrainingFrameSelector.Report.self, from: $0) }
            return (workspace.record(activeScan: activeScan), workspace.hasCheckpoint, workspace.hasModel, first,
                    TrainingDataset.exposureRange(scan: workspace.scan), selection?.selectedIDs.count,
                    workspace.hasModel ? GaussianExport.metadata(in: workspace.modelDirectory) : nil)
        }.value
        record = loaded.0
        hasCheckpoint = loaded.1
        hasModel = loaded.2
        archive = nil       // a finished run may have replaced the model
        cover = loaded.3
        exposureRange = loaded.4
        frameCount = loaded.5
        savedModel = loaded.6
        if savedModel == nil || isActive { enhancing = false }
        if let config = record?.configuration, !isActive, !enhancing {
            preset = config.preset
            resolution = config.resolution
            poseOptimization = config.poseOptimization
            ppisp = config.ppisp
            mipFilter = config.mipFilter
        } else if record == nil, let range = exposureRange {
            ppisp = range >= TrainingDataset.ppispExposureThreshold
        }
        if isActive && orbit == nil { resetView() }
        if showsModel && viewer == nil && !loadingViewer { await loadViewer() }
        if (!hasModel || enhancing) && !isActive { await updateEstimate() }
    }

    private func loadViewer() async {
        loadingViewer = true
        defer { loadingViewer = false }
        let workspace = self.workspace
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try GaussianModelViewer(workspace: workspace) }.value
            viewer = loaded
            errorTextForViewer = nil
            resetView()
        } catch {
            errorTextForViewer = error.localizedDescription
        }
    }

    private func updateEstimate() async {
        // Only the latest request may update the estimate (preset taps can overtake each other).
        estimateGeneration += 1
        let generation = estimateGeneration
        let scan = self.scan, config = configuration, savedCount = enhancing ? savedModel?.gaussians : nil
        let result = await Task.detached(priority: .utility) { () -> Result<TrainingMemoryPlan, Error> in
            let (records, _) = ScanLibrary.savedRecords(in: scan)
            guard let first = records.first(where: { $0.intrinsics.width > 0 }) else {
                return .failure(TrainingDataset.PreparationError.noFrames)
            }
            let size = TrainingDataset.trainingSize(width: first.intrinsics.width, height: first.intrinsics.height, longEdge: config.longEdge)
            return Result { try TrainingMemoryPlan.fit(width: size.0, height: size.1, shDegree: config.shDegree,
                                                      requestedGaussians: config.maxGaussians,
                                                      budgetBytes: TrainingMemoryPlan.automaticBudget()) }
        }.value
        guard generation == estimateGeneration else { return }
        switch result {
        case .success(let plan) where (savedCount ?? 0) > plan.gaussianCapacity:
            estimate = nil
            estimateError = L10n.text("可用記憶體不足以載入已保存的模型（約需 \(GaussianTrainingSession.requiredMB(rows: savedCount ?? 0, plan: plan)) MB）。請選較低的訓練解析度，或關閉其他 App 後再試；模型仍保留。")
        case .success(let plan): estimate = plan; estimateError = nil
        case .failure(let error): estimate = nil; estimateError = error.localizedDescription
        }
    }

    // MARK: Viewer

    private func resetView() {
        let views = isActive ? center.views : (viewer?.views ?? [])
        let depth = isActive ? center.initialDepth : (viewer?.initialDepth ?? 1.5)
        guard let first = views.first(where: { !$0.isValidation }) ?? views.first else { return }
        orbit = OrbitCamera(arkitTransform: first.transform, intrinsics: first.intrinsics, depth: depth)
        requestFrame()
    }

    private func requestFrame() {
        guard let orbit, viewPixels.width > 0, viewPixels.height > 0 else { return }
        let maxPixels = isActive ? 720.0 * 960.0 : Double(GaussianModelViewer.maxPixels)
        let scale = min(1, (maxPixels / Double(viewPixels.width * viewPixels.height)).squareRoot())
        let request = ViewerRequest(orbit: orbit, captureFrame: nil, width: max(16, Int(Double(viewPixels.width) * scale)),
                                    height: max(16, Int(Double(viewPixels.height) * scale)), mode: ispMode)
        if isActive {
            center.updateViewer(request, interactive: interacting)
        } else if let viewer {
            viewer.render(request) { frame, _ in
                Task { @MainActor in if let image = frame?.cgImage { modelFrame = image } }
            }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
