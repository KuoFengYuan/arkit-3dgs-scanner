import SwiftUI
import simd

struct SceneMeasurementView: View {
    let entry: ScanEntry
    let preview: ScanPreview
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [SIMD3<Float>] = []
    @State private var showPointPicker = false
    @State private var knownLength = ""
    @FocusState private var enteringLength: Bool
    @State private var scale: SceneMetricScale?
    @State private var error: String?
    @State private var archive: URL?
    @State private var working = false
    @State private var task: Task<Void,Never>?
    private var rawDistance: Double? {
        selected.count == 2 ? Double(simd_distance(selected[0],selected[1])) : nil
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("開啟全螢幕選點，可放大表面，分別確認起點與終點。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    ReviewPointCloudView(points: preview.points, trajectory: [], measurementPoints: selected)
                        .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel(L10n.text("尺度量測點雲，點選兩個可見表面位置"))
                    Button { showPointPicker = true } label: {
                        Label(L10n.text("全螢幕精準選點"), systemImage: "scope")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).disabled(working)
                    HStack {
                        if let rawDistance {
                            Text(String(format: L10n.text("距離 %.3f m"), rawDistance * (scale?.metersPerSourceUnit ?? 1)))
                                .font(.title2.monospacedDigit())
                        } else { Text(L10n.text("已選取 \(selected.count) / 2 點")) }
                        Spacer()
                        Button(L10n.text("重新選點")) { selected = [] }
                    }
                    if let scale {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(scale.statusText).font(.headline)
                            Text(String(format: L10n.text("尺度倍率 %.6f"), scale.metersPerSourceUnit))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(L10n.text("通過標準：各參考距離誤差不超過 2 公分或已知長度的 1%，取較大值。這不代表整個場景的絕對精度。"))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(scale.residualsMeters.enumerated()), id: \.offset) { i, residual in
                                Text(String(format: L10n.text("驗證 %d：誤差 %+.1f cm"), i+1, residual*100)).font(.caption)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    TextField(L10n.text("這段距離的實際長度（公尺）"), text: $knownLength)
                        .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).focused($enteringLength)
                    HStack {
                        Button(L10n.text("設為尺度校正")) { saveReference(calibration: true) }
                        Button(L10n.text("作為獨立驗證")) { saveReference(calibration: false) }
                    }.buttonStyle(.bordered).disabled(selected.count != 2 || working || scale == nil)
                    Text(L10n.text("先用捲尺或雷射測距取得已知長度。校正後請改選另一處距離驗證；重新校正會清除舊驗證。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(.callout).foregroundStyle(.orange) }
                    if working { ProgressView(L10n.text("準備公尺尺度資料…")) }
                    else if let archive {
                        ShareLink(item: archive) { Label(L10n.text("分享公尺尺度資料"), systemImage: "square.and.arrow.up") }
                    } else {
                        Button { exportMetric() } label: {
                            Label(L10n.text("匯出公尺尺度 3DGS 資料"), systemImage: "square.and.arrow.up")
                        }.buttonStyle(.borderedProminent).disabled(scale == nil)
                    }
                    Text(L10n.text("校正倍率會同時套用至匯出的相機位置與點雲。原始照片、深度與一般匯出不會改寫；公尺版不附原始深度，避免混用尺度。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("重設尺度與驗證"), role: .destructive) {
                        working = true
                        task = Task {
                            defer { working = false }
                            do { scale = try await ScanLibrary.shared.resetMetricScale(entry); error = nil; archive = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(working)
                }.padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L10n.text("空間尺度與驗證"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("完成")) { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.text("完成")) { enteringLength = false }
                }
            }
            .task {
                do { scale = try await ScanLibrary.shared.metricScale(entry) }
                catch { self.error = error.localizedDescription }
            }
            .fullScreenCover(isPresented: $showPointPicker) {
                MeasurementPointPicker(points: preview.points, initial: selected) { selected = $0 }
            }
            .onDisappear { task?.cancel() }
        }
    }
    private func saveReference(calibration: Bool) {
        guard let scale, selected.count == 2 else { return }
        let value = Double(knownLength.replacingOccurrences(of: ",", with: ".")) ?? .nan
        let reference = SceneMetricScale.Reference(start: [Double(selected[0].x),Double(selected[0].y),Double(selected[0].z)],
            end: [Double(selected[1].x),Double(selected[1].y),Double(selected[1].z)], knownMeters: value)
        var next = scale
        if calibration { next.calibration = reference; next.validations = [] }
        else { next.validations.append(reference) }
        enteringLength = false
        working = true; archive = nil
        task = Task {
            defer { working = false }
            do { try await ScanLibrary.shared.saveMetricScale(next, for: entry); self.scale = next; error = nil; selected = []; knownLength = "" }
            catch { self.error = error.localizedDescription }
        }
    }
    private func exportMetric() {
        working = true; error = nil
        task = Task {
            defer { working = false }
            do { archive = try await ScanLibrary.shared.metricArchive(entry) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
