import SwiftUI
import ImageIO

/// Scan history, opened from the home screen: a grid of saved scans.
struct ScanHistoryView: View {
    /// Changes when capture closes, so a newly saved scan appears without pulling to refresh.
    let revision: Int
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ScanEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var pendingDelete: DeletionRequest?
    @State private var deleting = false
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    /// DEBUG `--preview-scan-detail[-photos]`: open the newest scan for UI inspection.
    @State private var debugDetail = false

    private struct DeletionRequest {
        let entries: [ScanEntry]
        var all = false
        var title: String { all ? L10n.text("刪除全部 \(entries.count) 筆掃描？") : L10n.text("刪除 \(entries.count) 筆掃描？") }
    }

    private var selectedEntries: [ScanEntry] { entries.filter { selectedIDs.contains($0.id) } }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Two columns on iPhone; larger covers on iPad and wide windows.
    private var columns: [GridItem] {
        let minimum: CGFloat = horizontalSizeClass == .regular ? 220 : 150
        return [GridItem(.adaptive(minimum: minimum, maximum: 340), spacing: DS.Space.m, alignment: .top)]
    }

    var body: some View {
        Group {
            if loading && entries.isEmpty {
                ProgressView(L10n.text("讀取掃描紀錄…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty, let error {
                ContentUnavailableView {
                    Label(L10n.text("無法讀取紀錄"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button(L10n.text("重試")) { Task { await reload() } }
                        .buttonStyle(DSSecondaryButtonStyle())
                }
            } else if entries.isEmpty {
                emptyLibrary
            } else {
                library
            }
        }
        .dsCanvas()
        .navigationTitle(selecting ? L10n.text("已選取 \(selectedIDs.count) 筆") : L10n.text("掃描紀錄"))
        .navigationBarTitleDisplayMode(selecting ? .inline : .large)
        .toolbarBackground(DS.Palette.canvas.opacity(0.9), for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !entries.isEmpty {
                    Button(selecting ? L10n.text("取消選取") : L10n.text("選取")) {
                        withAnimation(DS.springy) {
                            selecting.toggle()
                            selectedIDs.removeAll()
                        }
                    }
                    .disabled(deleting || loading)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .animation(DS.springy, value: selecting)
        .animation(DS.springy, value: deleting)
        .task(id: revision) {
            await reload()
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if !entries.isEmpty, arguments.contains(where: { $0.hasPrefix("--preview-scan-detail") }) { debugDetail = true }
            #endif
        }
        .navigationDestination(isPresented: $debugDetail) {
            if let entry = entries.first {
                ScanHistoryDetail(entry: entry,
                                  initialTab: ProcessInfo.processInfo.arguments.contains("--preview-scan-detail-photos") ? 1 : 0) {
                    Task { await reload() }
                }
            }
        }
        .confirmationDialog(pendingDelete?.title ?? L10n.text("刪除掃描？"), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete) { request in
            Button(L10n.text("永久刪除 \(request.entries.count) 筆掃描"), role: .destructive) {
                pendingDelete = nil
                deleting = true
                Task { await delete(request.entries) }
            }
            Button(L10n.text("取消"), role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text(L10n.text("所選掃描的所有照片、模型、點雲、深度與姿態資料、平面圖及同名 ZIP 都會刪除，無法復原。"))
        }
        .alert(L10n.text("無法完成操作"), isPresented: Binding(get: { error != nil && !entries.isEmpty }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("好")) { error = nil }
        } message: { Text(error ?? "") }
        .sensoryFeedback(.selection, trigger: selectedIDs)
    }

    // MARK: - Grid

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text(L10n.text("共 \(entries.count) 筆")).font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                LazyVGrid(columns: columns, spacing: DS.Space.l) {
                    ForEach(entries) { entry in
                        if selecting {
                            Button {
                                if !selectedIDs.insert(entry.id).inserted { selectedIDs.remove(entry.id) }
                            } label: {
                                ScanCard(entry: entry, selecting: true, selected: selectedIDs.contains(entry.id))
                            }
                            .buttonStyle(DSCardButtonStyle())
                            .accessibilityValue(selectedIDs.contains(entry.id) ? L10n.text("已選取") : L10n.text("未選取"))
                        } else {
                            NavigationLink {
                                ScanHistoryDetail(entry: entry) { Task { await reload() } }
                            } label: {
                                ScanCard(entry: entry)
                            }
                            .buttonStyle(DSCardButtonStyle())
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = DeletionRequest(entries: [entry])
                                } label: { Label(L10n.text("刪除"), systemImage: "trash") }
                            }
                        }
                    }
                }
                Text(L10n.text("包含舊版拍攝的掃描。刪除會一併移除照片、模型、點雲與分享檔案。"))
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .padding(.top, DS.Space.xs)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.xl)
        }
        .refreshable { if !deleting { await reload() } }
        .disabled(deleting)
    }

    // MARK: - Empty state

    private var emptyLibrary: some View {
        ScrollView {
            VStack(spacing: DS.Space.l) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 112, height: 112)
                    .background(DS.Palette.accent.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
                VStack(spacing: DS.Space.xs) {
                    Text(L10n.text("還沒有掃描紀錄")).font(.title3.weight(.semibold))
                    Text(L10n.text("完成掃描後會自動保留在這裡，之後可預覽、分享或刪除。"))
                        .font(.subheadline)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { dismiss() } label: {
                    Label(L10n.text("返回開始掃描"), systemImage: "record.circle")
                }
                .buttonStyle(DSPrimaryButtonStyle(fill: false))
            }
            .padding(DS.Space.xl)
            .padding(.top, DS.Space.xxl)
            .frame(maxWidth: DS.Size.panelMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await reload() }
    }

    // MARK: - Bottom actions

    /// Selection and deletion actions; nothing floats over the grid otherwise.
    @ViewBuilder
    private var bottomBar: some View {
        if deleting || selecting {
            Group {
                if deleting {
                    ProgressView(L10n.text("正在刪除照片與模型…"))
                        .tint(.white)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .padding(.horizontal, DS.Space.l).frame(minHeight: DS.Size.primaryHeight)
                        .dsFloatingPanel(radius: DS.Radius.l)
                } else {
                    HStack(spacing: DS.Space.s) {
                        Button(selectedIDs.count == entries.count ? L10n.text("取消全選") : L10n.text("全選")) {
                            selectedIDs = selectedIDs.count == entries.count ? [] : Set(entries.map(\.id))
                        }
                        .buttonStyle(DSSecondaryButtonStyle())
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            pendingDelete = DeletionRequest(entries: selectedEntries, all: selectedIDs.count == entries.count)
                        } label: {
                            Label(L10n.text("刪除所選（\(selectedIDs.count)）"), systemImage: "trash")
                        }
                        .buttonStyle(DSPrimaryButtonStyle(fill: false, tint: DS.Palette.danger))
                        .disabled(selectedIDs.isEmpty)
                    }
                    .padding(DS.Space.s)
                    .dsFloatingPanel(radius: DS.Radius.xl + 4)
                }
            }
            .frame(maxWidth: DS.Size.panelMaxWidth)
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.xs)
            .frame(maxWidth: .infinity)
            .disabled(loading && !deleting)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func delete(_ targets: [ScanEntry]) async {
        defer { deleting = false }
        var deletionError: String?
        do { try await ScanLibrary.shared.delete(targets) }
        catch { deletionError = error.localizedDescription }
        await reload()
        if let deletionError { error = deletionError }
        if selectedIDs.isEmpty { selecting = false }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            entries = try await ScanLibrary.shared.entries()
            selectedIDs.formIntersection(entries.map(\.id))
            if entries.isEmpty { selecting = false }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// One scan in the library grid: cover photo first, then date and size.
private struct ScanCard: View {
    let entry: ScanEntry
    var selecting = false
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Color.clear
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay { ScanPhoto(url: entry.cover, maxDimension: 480) }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                        .strokeBorder(selected ? DS.Palette.accent : DS.Palette.stroke, lineWidth: selected ? 3 : 0.5)
                }
                .overlay(alignment: .topLeading) { badges.padding(DS.Space.xs) }
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(selected ? DS.Palette.onAccent : .white, selected ? DS.Palette.accent : .black.opacity(0.25))
                            .shadow(color: .black.opacity(0.4), radius: 3)
                            .padding(DS.Space.xs)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(L10n.text("\(entry.frameCount) 張影像") + (entry.pointCount.map { L10n.text("・\($0.formatted()) 個點") } ?? ""))
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var badges: some View {
        HStack(spacing: DS.Space.xxs) {
            if let lidar = entry.usedLiDAR {
                badge(lidar ? "sensor.tag.radiowaves.forward" : "camera",
                      label: lidar ? L10n.text("LiDAR 開啟") : L10n.text("LiDAR 關閉・相機模式"),
                      tint: lidar ? DS.Palette.accent : .white)
            }
            if entry.archive != nil {
                badge("shippingbox.fill", label: L10n.text("已有分享檔案"), tint: .white)
            }
        }
    }

    private func badge(_ symbol: String, label: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .hudGlass(Circle())
            .accessibilityLabel(label)
    }
}

// MARK: - Scan detail

/// 3D-first scan detail: the point cloud or the photo route fills the screen, a floating
/// switcher picks the view, and a compact panel holds the export action.
private struct ScanHistoryDetail: View {
    let entry: ScanEntry
    @State private var optimizedEntry: ScanEntry?
    @State private var showMeasurements = false
    @State private var showDetails = false
    private var currentEntry: ScanEntry { optimizedEntry ?? entry }
    @State private var selection: TrainingFrameSelector.Report?
    @State private var poseNotice: String?
    @State private var optimizationTask: Task<Void, Never>?
    @State private var optimizationText = ""
    @State private var optimizationProgress = 0.0
    let onLibraryChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ScanPreview?
    @State private var selectedTab: Int

    init(entry: ScanEntry, initialTab: Int = 0, onLibraryChange: @escaping () -> Void) {
        self.entry = entry
        self.onLibraryChange = onLibraryChange
        _selectedTab = State(initialValue: initialTab)
    }
    @State private var photoIndex = 0
    @State private var playbackFPS = ScanPlaybackTiming.defaultFPS
    @State private var error: String?
    @State private var showDelete = false
    @State private var busy = false
    @State private var archive: URL?
    @State private var viewReset = 0
    @State private var showGestureHint = true
    /// Brief confirmation once the export archive is ready to share.
    @State private var showReadyToast = false

    private var qualityNeedsReview: Bool { selection?.notice != nil }

    var body: some View {
        ZStack {
            DS.Palette.canvas.ignoresSafeArea()
            content
        }
        .overlay(alignment: .top) {
            if showReadyToast {
                DSToast(text: L10n.text("檔案已準備好")).padding(.top, DS.Space.xs)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topOverlay }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomPanel }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if optimizationTask != nil {
                    Button(L10n.text("取消")) { optimizationTask?.cancel() }
                } else {
                    Menu {
                        Button { showMeasurements = true } label: {
                            Label(L10n.text("空間尺度與驗證"), systemImage: "ruler")
                        }.disabled(busy || preview?.points.isEmpty != false)
                        Button {
                            optimizationTask = Task { await optimize() }
                        } label: {
                            Label(L10n.text("優化訓練資料"), systemImage: "wand.and.stars")
                        }.disabled(busy || preview == nil)
                        Divider()
                        Button(role: .destructive) { showDelete = true } label: {
                            Label(L10n.text("刪除"), systemImage: "trash")
                        }.disabled(busy)
                    } label: {
                        Label(L10n.text("更多操作"), systemImage: "ellipsis.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("scanActions")
                }
            }
        }
        .sheet(isPresented: $showDetails) { detailsSheet }
        .sheet(isPresented: $showMeasurements) {
            if let preview { SceneMeasurementView(entry: currentEntry, preview: preview) }
        }
        .onDisappear { optimizationTask?.cancel() }
        .navigationTitle(currentEntry.date.formatted(.dateTime.locale(L10n.locale).year().month().day().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DS.Palette.canvas.opacity(0.85), for: .navigationBar)
        .task {
            // Existing ZIPs may predate COLMAP preparation; regenerate once per detail visit.
            archive = nil
            selection = await ScanLibrary.shared.trainingSelection(currentEntry)
            poseNotice = await ScanLibrary.shared.poseRefinementNotice(currentEntry)
            do {
                let result = try await ScanLibrary.shared.preview(currentEntry)
                guard !Task.isCancelled else { return }
                preview = result
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--preview-scan-detail-measure"), !result.points.isEmpty {
                    showMeasurements = true
                }
                #endif
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                preview = ScanPreview(points: [], trajectory: [], images: [], note: error.localizedDescription)
            }
        }
        .task(id: preview == nil) {
            guard preview != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeOut(duration: 0.4)) { showGestureHint = false }
        }
        .confirmationDialog(L10n.text("刪除這次掃描？"), isPresented: $showDelete, titleVisibility: .visible) {
            Button(L10n.text("刪除照片、模型與所有資料"), role: .destructive) {
                Task {
                    busy = true
                    defer { busy = false }
                    do { try await ScanLibrary.shared.delete(currentEntry); onLibraryChange(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button(L10n.text("取消"), role: .cancel) { showDelete = false }
        } message: { Text(L10n.text("此掃描的所有照片、模型、點雲、深度與姿態資料、平面圖及同名 ZIP 都會刪除，無法復原。")) }
        .alert(L10n.text("無法完成操作"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("好")) { error = nil }
        } message: { Text(error ?? "") }
        .sensoryFeedback(.success, trigger: archive != nil) { _, ready in ready }
        .sensoryFeedback(.success, trigger: optimizedEntry?.id)
    }

    @ViewBuilder
    private var content: some View {
        if let preview {
            if selectedTab == 0 {
                if preview.points.isEmpty {
                    ContentUnavailableView(L10n.text("沒有可預覽的點雲"), systemImage: "cube.transparent",
                                           description: Text(preview.note ?? L10n.text("可切換查看拍攝影像。")))
                } else {
                    ReviewPointCloudView(points: preview.points, trajectory: preview.trajectory,
                                         resetCameraToken: viewReset)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityLabel(L10n.text("歷史掃描 3D 點雲"))
                        .overlay(alignment: .bottom) {
                            if showGestureHint {
                                Text(L10n.text("單指旋轉・雙指縮放與平移"))
                                    .font(.caption).hudText()
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .hudGlass(Capsule())
                                    .padding(.bottom, DS.Space.m)
                                    .transition(.opacity)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            } else if preview.images.isEmpty {
                ContentUnavailableView(L10n.text("沒有拍攝影像"), systemImage: "photo")
            } else {
                ScanRoutePlaybackView(preview: preview, currentIndex: $photoIndex, playbackFPS: $playbackFPS)
            }
        } else {
            VStack(spacing: DS.Space.s) {
                ProgressView(L10n.text("準備預覽…")).tint(.white)
                Text(L10n.text("舊版掃描可能需要從深度資料重建點雲"))
                    .font(.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            .padding()
        }
    }

    private var topOverlay: some View {
        VStack(spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Spacer(minLength: DS.Size.control + DS.Space.xs)
                DSSegmentedPicker(segments: [
                    DSSegment(value: 0, title: L10n.text("3D 點雲"), symbol: "cube"),
                    DSSegment(value: 1, title: L10n.text("拍攝影像"), symbol: "photo.on.rectangle")
                ], selection: $selectedTab)
                .accessibilityLabel(L10n.text("預覽內容"))
                Spacer(minLength: 0)
                Button { viewReset += 1 } label: {
                    Label(L10n.text("顯示完整點雲"), systemImage: "scope")
                }
                .buttonStyle(DSIconButtonStyle())
                .opacity(selectedTab == 0 && preview?.points.isEmpty == false ? 1 : 0)
                .disabled(selectedTab != 0 || preview?.points.isEmpty != false)
            }
            if selectedTab == 0 {
                HStack(spacing: DS.Space.xs) {
                    DSMetric(value: L10n.text("\(currentEntry.frameCount) 張影像"), symbol: "photo.stack")
                    if let points = currentEntry.pointCount {
                        DSMetric(value: L10n.text("\(points.formatted()) 個點"), symbol: "circle.grid.3x3.fill")
                    }
                    if let lidar = currentEntry.usedLiDAR {
                        DSMetric(value: lidar ? "LiDAR" : L10n.text("相機模式"),
                                 symbol: lidar ? "sensor.tag.radiowaves.forward" : "camera",
                                 tone: lidar ? .accent : .warning)
                            .accessibilityLabel(lidar ? L10n.text("LiDAR 深度掃描") : L10n.text("相機模式・未使用 LiDAR 深度"))
                    }
                }
                .transition(.opacity)
            }
            if optimizedEntry != nil {
                DSStatusPill(text: L10n.text("已另存優化版本，原始掃描仍保留"), symbol: "checkmark.circle.fill", tone: .success)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
        .animation(DS.springy, value: selectedTab)
        .animation(DS.springy, value: optimizedEntry != nil)
    }

    private var bottomPanel: some View {
        VStack(spacing: DS.Space.s) {
            if optimizationTask != nil {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack {
                        Label(optimizationText, systemImage: "wand.and.stars")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Spacer()
                        Text("\(Int(optimizationProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    ProgressView(value: optimizationProgress).tint(DS.Palette.accent)
                }
                .foregroundStyle(DS.Palette.textPrimary)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: DS.Space.xs) {
                Button { showDetails = true } label: {
                    Label(qualityNeedsReview ? L10n.text("拍攝品質需要檢查") : L10n.text("掃描品質資訊"),
                          systemImage: qualityNeedsReview ? "exclamationmark.circle" : "info.circle")
                }
                .buttonStyle(DSIconButtonStyle(isSelected: qualityNeedsReview, tint: DS.Palette.warning, size: DS.Size.primaryHeight))
                primaryAction
            }
        }
        .padding(DS.Space.s)
        .dsFloatingPanel(radius: DS.Radius.xl + 4)
        .frame(maxWidth: DS.Size.panelMaxWidth)
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
        .frame(maxWidth: .infinity)
        .animation(DS.springy, value: optimizationTask != nil)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let archive {
            ShareLink(item: archive) {
                Label(L10n.text("分享掃描"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(busy)
        } else {
            Button { Task { await makeArchive() } } label: {
                Label(busy && optimizationTask == nil ? L10n.text("處理中…") : L10n.text("匯出 3DGS 訓練資料"),
                      systemImage: "square.and.arrow.up")
            }
            .buttonStyle(DSPrimaryButtonStyle(isLoading: busy && optimizationTask == nil))
            .disabled(busy || preview == nil)
        }
    }

    private var detailsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Label(L10n.text("\(currentEntry.frameCount) 張影像"), systemImage: "photo.stack")
                        .font(.headline)
                    if let poseNotice {
                        Text(poseNotice).font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                    }
                    if let selection {
                        Text(L10n.text("訓練選用 \(selection.selectedIDs.count) / \(selection.inputFrames) 張影像"))
                            .font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                        if let notice = selection.notice {
                            Label(notice, systemImage: "exclamationmark.circle")
                                .font(.subheadline).foregroundStyle(DS.Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let information = selection.diagnosticSummary {
                            DisclosureGroup(L10n.text("拍攝品質資訊")) {
                                Text(information).font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    if let note = preview?.note {
                        Text(note).font(.subheadline).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCard()
                .padding()
            }
            .dsCanvas()
            .navigationTitle(L10n.text("掃描品質資訊"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("完成")) { showDetails = false }
            } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DS.Palette.canvas)
        .presentationCornerRadius(DS.Radius.xl)
    }

    private func makeArchive() async {
        busy = true
        defer { busy = false }
        do {
            archive = try await ScanLibrary.shared.archive(currentEntry)
            selection = await ScanLibrary.shared.trainingSelection(currentEntry)
            poseNotice = await ScanLibrary.shared.poseRefinementNotice(currentEntry)
            withAnimation(DS.springy) { showReadyToast = true }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.easeOut(duration: 0.3)) { showReadyToast = false }
            }
        }
        catch { self.error = error.localizedDescription }
    }

    private func optimize() async {
        busy = true
        optimizationText = L10n.text("準備優化…")
        optimizationProgress = 0
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            busy = false; optimizationTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // Release large SceneKit inputs while the offline solver/refusion needs memory.
        preview = nil
        do {
            let result = try await ScanLibrary.shared.optimizeTraining(currentEntry) { text, fraction in
                Task { @MainActor in
                    optimizationText = text; optimizationProgress = fraction
                }
            }
            optimizedEntry = result; archive = nil
            onLibraryChange()
            selection = await ScanLibrary.shared.trainingSelection(result)
            poseNotice = await ScanLibrary.shared.poseRefinementNotice(result)
            preview = try await ScanLibrary.shared.preview(result)
        } catch is CancellationError {
            preview = try? await ScanLibrary.shared.preview(currentEntry)
        } catch {
            self.error = error.localizedDescription
            preview = try? await ScanLibrary.shared.preview(currentEntry)
        }
    }
}

struct ScanPhoto: View {
    let url: URL?
    let maxDimension: Int
    var fit = false
    var orientation: CGImagePropertyOrientation? = nil
    var onImageLoaded: ((URL, Bool) -> Void)? = nil
    @State private var image: UIImage?
    @State private var loaded = false

    private struct ImageRequest: Hashable {
        let url: URL?
        let maxDimension: Int
        let orientation: UInt32?
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DS.Palette.surface
                if let image {
                    Image(uiImage: image).resizable()
                        .aspectRatio(contentMode: fit ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else if !loaded && url != nil {
                    ProgressView()
                } else {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: ImageRequest(url: url, maxDimension: maxDimension, orientation: orientation?.rawValue)) {
            // 換圖／切換預覽解析度時保留上一張；首張載入才顯示 ProgressView。
            guard let url else {
                image = nil
                loaded = true
                return
            }
            if image == nil { loaded = false }
            let data = await Task.detached(priority: .utility) {
                ScanLibrary.imageData(url, maxDimension: maxDimension, orientation: orientation)
            }.value
            guard !Task.isCancelled else { return }
            let replacement = data.flatMap(UIImage.init(data:))
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                image = replacement
                loaded = true
                // 與替換照片在同一次更新通知路線；取消的舊請求不能覆蓋新照片。
                onImageLoaded?(url, replacement != nil)
            }
        }
        .accessibilityLabel(L10n.text("掃描影像"))
    }
}
