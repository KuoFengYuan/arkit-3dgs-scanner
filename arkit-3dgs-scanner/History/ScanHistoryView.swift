import SwiftUI
import ImageIO

struct ScanHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ScanEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var pendingDelete: DeletionRequest?
    @State private var deleting = false
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []

    private struct DeletionRequest {
        let entries: [ScanEntry]
        var all = false
        var title: String { all ? L10n.text("刪除全部 \(entries.count) 筆掃描？") : L10n.text("刪除 \(entries.count) 筆掃描？") }
    }

    private var selectedEntries: [ScanEntry] { entries.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Group {
                if loading && entries.isEmpty {
                    ProgressView(L10n.text("讀取掃描紀錄…"))
                } else if entries.isEmpty {
                    ContentUnavailableView {
                        Label(error == nil ? L10n.text("還沒有掃描紀錄") : L10n.text("無法讀取紀錄"), systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text(error ?? L10n.text("完成掃描後會自動保留在這裡，之後可預覽、分享或刪除。"))
                    } actions: {
                        if error != nil { Button(L10n.text("重試")) { Task { await reload() } } }
                        else { Button(L10n.text("返回開始掃描")) { dismiss() }.buttonStyle(.borderedProminent) }
                    }
                } else {
                    List {
                        Section {
                            ForEach(entries) { entry in
                                if selecting {
                                    Button {
                                        if !selectedIDs.insert(entry.id).inserted { selectedIDs.remove(entry.id) }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.title2).foregroundStyle(Color.accentColor)
                                            row(entry)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityValue(selectedIDs.contains(entry.id) ? L10n.text("已選取") : L10n.text("未選取"))
                                } else {
                                    NavigationLink {
                                        ScanHistoryDetail(entry: entry) {
                                            Task { await reload() }
                                        }
                                    } label: { row(entry) }
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            pendingDelete = DeletionRequest(entries: [entry])
                                        } label: { Label(L10n.text("刪除"), systemImage: "trash") }
                                    }
                                }
                            }
                        } footer: {
                            Text(L10n.text("包含舊版拍攝的掃描。刪除會一併移除照片、模型、點雲與分享檔案。"))
                        }
                    }
                    .refreshable { if !deleting { await reload() } }
                    .disabled(deleting)
                }
            }
            .navigationTitle(selecting ? L10n.text("已選取 \(selectedIDs.count) 筆") : L10n.text("掃描紀錄"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !entries.isEmpty {
                        Button(selecting ? L10n.text("取消選取") : L10n.text("選取")) {
                            selecting.toggle()
                            selectedIDs.removeAll()
                        }.disabled(deleting || loading)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("完成")) { dismiss() }.disabled(deleting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !entries.isEmpty {
                    HStack {
                        if deleting {
                            ProgressView(L10n.text("正在刪除照片與模型…"))
                        } else if selecting {
                            Button(selectedIDs.count == entries.count ? L10n.text("取消全選") : L10n.text("全選")) {
                                selectedIDs = selectedIDs.count == entries.count ? [] : Set(entries.map(\.id))
                            }
                            Spacer()
                            Button(L10n.text("刪除所選（\(selectedIDs.count)）"), role: .destructive) {
                                pendingDelete = DeletionRequest(entries: selectedEntries)
                            }.disabled(selectedIDs.isEmpty)
                        } else {
                            Text(L10n.text("共 \(entries.count) 筆")).foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.text("全部刪除"), role: .destructive) {
                                pendingDelete = DeletionRequest(entries: entries, all: true)
                            }
                        }
                    }
                    .disabled(loading)
                    .padding().background(.bar)
                }
            }
            .interactiveDismissDisabled(deleting)
            .task { await reload() }
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
        }
    }

    private func row(_ entry: ScanEntry) -> some View {
        HStack(spacing: 14) {
            ScanPhoto(url: entry.cover, maxDimension: 240)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.date, format: .dateTime.month().day().hour().minute()).font(.headline)
                Text(L10n.text("\(entry.frameCount) 張影像") + (entry.pointCount.map { L10n.text("・\($0.formatted()) 個點") } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                if let lidar = entry.usedLiDAR {
                    Label(lidar ? L10n.text("LiDAR 開啟") : L10n.text("LiDAR 關閉・相機模式"),
                          systemImage: lidar ? "sensor.tag.radiowaves.forward" : "camera")
                        .font(.caption).foregroundStyle(lidar ? Color.accentColor : .secondary)
                }
                Text(entry.archive == nil ? L10n.text("已儲存於裝置") : L10n.text("已有分享檔案"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

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
    @State private var selectedTab = 0
    @State private var photoIndex = 0
    @State private var playbackFPS = ScanPlaybackTiming.defaultFPS
    @State private var error: String?
    @State private var showDelete = false
    @State private var busy = false
    @State private var archive: URL?

    var body: some View {
        VStack(spacing: 0) {
            if let lidar = currentEntry.usedLiDAR {
                Text(lidar ? L10n.text("LiDAR 深度掃描") : L10n.text("相機模式・未使用 LiDAR 深度"))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            if optimizedEntry != nil {
                Text(L10n.text("已另存優化版本，原始掃描仍保留")).font(.caption).foregroundStyle(.secondary)
            }
            Button { showDetails = true } label: {
                Label(selection?.notice != nil ? L10n.text("拍攝品質需要檢查") : L10n.text("掃描品質資訊"),
                      systemImage: selection?.notice != nil ? "exclamationmark.circle" : "info.circle")
                    .font(.subheadline).frame(minHeight: 44)
                    .foregroundStyle(selection?.notice != nil ? Color.orange : Color.accentColor)
            }
            if optimizationTask != nil {
                ProgressView(optimizationText, value: optimizationProgress).padding()
            }
            Picker(L10n.text("預覽內容"), selection: $selectedTab) {
                Text(L10n.text("3D 點雲")).tag(0)
                Text(L10n.text("拍攝影像")).tag(1)
            }
            .pickerStyle(.segmented).padding()
            if let preview {
                if selectedTab == 0 {
                    if preview.points.isEmpty {
                        ContentUnavailableView(L10n.text("沒有可預覽的點雲"), systemImage: "cube.transparent",
                                               description: Text(preview.note ?? L10n.text("可切換查看拍攝影像。")))
                    } else {
                        ZStack(alignment: .bottom) {
                            ReviewPointCloudView(points: preview.points, trajectory: preview.trajectory)
                            Text(L10n.text("單指旋轉・雙指縮放與平移"))
                                .font(.caption).padding(10).hudGlass(Capsule()).foregroundStyle(.white)
                                .padding().allowsHitTesting(false)
                        }
                        .accessibilityLabel(L10n.text("歷史掃描 3D 點雲"))
                    }
                } else if preview.images.isEmpty {
                    ContentUnavailableView(L10n.text("沒有拍攝影像"), systemImage: "photo")
                } else {
                    ScanRoutePlaybackView(preview: preview, currentIndex: $photoIndex, playbackFPS: $playbackFPS)
                }
            } else {
                Spacer()
                ProgressView(L10n.text("準備預覽…"))
                Text(L10n.text("舊版掃描可能需要從深度資料重建點雲"))
                    .font(.caption).foregroundStyle(.secondary).padding()
                Spacer()
            }
        }
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
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(L10n.text("\(currentEntry.frameCount) 張影像"), systemImage: "photo.stack")
                        if let poseNotice {
                            Text(poseNotice).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let selection {
                            Text(L10n.text("訓練選用 \(selection.selectedIDs.count) / \(selection.inputFrames) 張影像"))
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let notice = selection.notice {
                                Label(notice, systemImage: "exclamationmark.circle")
                                    .font(.subheadline).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let information = selection.diagnosticSummary {
                                DisclosureGroup(L10n.text("拍攝品質資訊")) {
                                    Text(information).font(.subheadline)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if let note = preview?.note {
                            Text(note).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle(L10n.text("掃描品質資訊"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("完成")) { showDetails = false }
                } }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(uiColor: .systemGroupedBackground))
        }
        .sheet(isPresented: $showMeasurements) {
            if let preview { SceneMeasurementView(entry: currentEntry, preview: preview) }
        }
        .onDisappear { optimizationTask?.cancel() }
        .navigationTitle(currentEntry.date.formatted(.dateTime.locale(L10n.locale).year().month().day().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Group {
                if busy {
                    ProgressView(L10n.text("處理中…"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else if let archive {
                    ShareLink(item: archive) {
                        Label(L10n.text("分享掃描"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                } else {
                    Button { Task { await makeArchive() } } label: {
                        Label(L10n.text("匯出 3DGS 訓練資料"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || preview == nil)
            .padding().background(.bar)
        }
        .task {
            // Existing ZIPs may predate COLMAP preparation; regenerate once per detail visit.
            archive = nil
            selection = await ScanLibrary.shared.trainingSelection(currentEntry)
            poseNotice = await ScanLibrary.shared.poseRefinementNotice(currentEntry)
            do {
                let result = try await ScanLibrary.shared.preview(currentEntry)
                guard !Task.isCancelled else { return }
                preview = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                preview = ScanPreview(points: [], trajectory: [], images: [], note: error.localizedDescription)
            }
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
    }

    private func makeArchive() async {
        busy = true
        defer { busy = false }
        do {
            archive = try await ScanLibrary.shared.archive(currentEntry)
            selection = await ScanLibrary.shared.trainingSelection(currentEntry)
            poseNotice = await ScanLibrary.shared.poseRefinementNotice(currentEntry)
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
                Color(uiColor: .secondarySystemBackground)
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
