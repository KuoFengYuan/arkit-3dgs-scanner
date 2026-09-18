import SwiftUI

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
        var title: String { all ? "刪除全部 \(entries.count) 筆掃描？" : "刪除 \(entries.count) 筆掃描？" }
    }

    private var selectedEntries: [ScanEntry] { entries.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Group {
                if loading && entries.isEmpty {
                    ProgressView("讀取掃描紀錄…")
                } else if entries.isEmpty {
                    ContentUnavailableView {
                        Label(error == nil ? "還沒有掃描紀錄" : "無法讀取紀錄", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text(error ?? "完成掃描後會自動保留在這裡，之後可預覽、分享或刪除。")
                    } actions: {
                        if error != nil { Button("重試") { Task { await reload() } } }
                        else { Button("返回開始掃描") { dismiss() }.buttonStyle(.borderedProminent) }
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
                                    .accessibilityValue(selectedIDs.contains(entry.id) ? "已選取" : "未選取")
                                } else {
                                    NavigationLink {
                                        ScanHistoryDetail(entry: entry) {
                                            entries.removeAll { $0.id == entry.id }
                                        }
                                    } label: { row(entry) }
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            pendingDelete = DeletionRequest(entries: [entry])
                                        } label: { Label("刪除", systemImage: "trash") }
                                    }
                                }
                            }
                        } footer: {
                            Text("包含舊版拍攝的掃描。刪除會一併移除照片、模型、點雲與分享檔案。")
                        }
                    }
                    .refreshable { if !deleting { await reload() } }
                    .disabled(deleting)
                }
            }
            .navigationTitle(selecting ? "已選取 \(selectedIDs.count) 筆" : "掃描紀錄")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !entries.isEmpty {
                        Button(selecting ? "取消選取" : "選取") {
                            selecting.toggle()
                            selectedIDs.removeAll()
                        }.disabled(deleting || loading)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.disabled(deleting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !entries.isEmpty {
                    HStack {
                        if deleting {
                            ProgressView("正在刪除照片與模型…")
                        } else if selecting {
                            Button(selectedIDs.count == entries.count ? "取消全選" : "全選") {
                                selectedIDs = selectedIDs.count == entries.count ? [] : Set(entries.map(\.id))
                            }
                            Spacer()
                            Button("刪除所選（\(selectedIDs.count)）", role: .destructive) {
                                pendingDelete = DeletionRequest(entries: selectedEntries)
                            }.disabled(selectedIDs.isEmpty)
                        } else {
                            Text("共 \(entries.count) 筆").foregroundStyle(.secondary)
                            Spacer()
                            Button("全部刪除", role: .destructive) {
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
            .confirmationDialog(pendingDelete?.title ?? "刪除掃描？", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete) { request in
                Button("永久刪除 \(request.entries.count) 筆掃描", role: .destructive) {
                    pendingDelete = nil
                    deleting = true
                    Task { await delete(request.entries) }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("所選掃描的所有照片、模型、點雲、深度與姿態資料、平面圖及同名 ZIP 都會刪除，無法復原。")
            }
            .alert("無法完成操作", isPresented: Binding(get: { error != nil && !entries.isEmpty }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
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
                Text("\(entry.frameCount) 張影像" + (entry.pointCount.map { "・\($0.formatted()) 個點" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                if let lidar = entry.usedLiDAR {
                    Label(lidar ? "LiDAR 開啟" : "LiDAR 關閉・相機模式",
                          systemImage: lidar ? "sensor.tag.radiowaves.forward" : "camera")
                        .font(.caption).foregroundStyle(lidar ? Color.accentColor : .secondary)
                }
                Text(entry.archive == nil ? "已儲存於裝置" : "已有分享檔案")
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
    let onDelete: () -> Void
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
            if let lidar = entry.usedLiDAR {
                Text(lidar ? "LiDAR 深度掃描" : "相機模式・未使用 LiDAR 深度")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            Picker("預覽內容", selection: $selectedTab) {
                Text("3D 點雲").tag(0)
                Text("拍攝影像").tag(1)
            }
            .pickerStyle(.segmented).padding()
            if let preview {
                if selectedTab == 0 {
                    if preview.points.isEmpty {
                        ContentUnavailableView("沒有可預覽的點雲", systemImage: "cube.transparent",
                                               description: Text(preview.note ?? "可切換查看拍攝影像。"))
                    } else {
                        ZStack(alignment: .bottom) {
                            ReviewPointCloudView(points: preview.points, trajectory: preview.trajectory)
                            Text("單指旋轉・雙指縮放與平移")
                                .font(.caption).padding(10).hudGlass(Capsule()).foregroundStyle(.white)
                                .padding().allowsHitTesting(false)
                        }
                        .accessibilityLabel("歷史掃描 3D 點雲")
                    }
                } else if preview.images.isEmpty {
                    ContentUnavailableView("沒有拍攝影像", systemImage: "photo")
                } else {
                    ScanRoutePlaybackView(preview: preview, currentIndex: $photoIndex, playbackFPS: $playbackFPS)
                }
                if let note = preview.note, !preview.points.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).padding()
                }
            } else {
                Spacer()
                ProgressView("準備預覽…")
                Text("舊版掃描可能需要從深度資料重建點雲")
                    .font(.caption).foregroundStyle(.secondary).padding()
                Spacer()
            }
        }
        .navigationTitle(entry.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if busy { ProgressView("處理中…") }
                else if let archive {
                    ShareLink(item: archive) { Label("分享掃描", systemImage: "square.and.arrow.up") }
                } else {
                    Button { Task { await makeArchive() } } label: {
                        Label("打包分享", systemImage: "square.and.arrow.up")
                    }
                }
                Spacer()
                Button(role: .destructive) { showDelete = true } label: {
                    Label("刪除", systemImage: "trash")
                }
            }
            .disabled(busy || preview == nil)
            .padding().background(.bar)
        }
        .task {
            archive = entry.archive
            do {
                let result = try await ScanLibrary.shared.preview(entry)
                guard !Task.isCancelled else { return }
                preview = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                preview = ScanPreview(points: [], trajectory: [], images: [], note: error.localizedDescription)
            }
        }
        .confirmationDialog("刪除這次掃描？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("刪除照片、模型與所有資料", role: .destructive) {
                Task {
                    busy = true
                    defer { busy = false }
                    do { try await ScanLibrary.shared.delete(entry); onDelete(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("此掃描的所有照片、模型、點雲、深度與姿態資料、平面圖及同名 ZIP 都會刪除，無法復原。") }
        .alert("無法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func makeArchive() async {
        busy = true
        defer { busy = false }
        do { archive = try await ScanLibrary.shared.archive(entry) }
        catch { self.error = error.localizedDescription }
    }
}

struct ScanPhoto: View {
    let url: URL?
    let maxDimension: Int
    var fit = false
    var onImageLoaded: ((URL, Bool) -> Void)? = nil
    @State private var image: UIImage?
    @State private var loaded = false

    private struct ImageRequest: Hashable {
        let url: URL?
        let maxDimension: Int
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
        .task(id: ImageRequest(url: url, maxDimension: maxDimension)) {
            // 換圖／切換預覽解析度時保留上一張；首張載入才顯示 ProgressView。
            guard let url else {
                image = nil
                loaded = true
                return
            }
            if image == nil { loaded = false }
            let data = await Task.detached(priority: .utility) {
                ScanLibrary.imageData(url, maxDimension: maxDimension)
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
        .accessibilityLabel("掃描影像")
    }
}
