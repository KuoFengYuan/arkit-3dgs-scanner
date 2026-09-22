import SwiftUI
import simd

/// Point selection is provisional until explicitly confirmed; each endpoint can be edited separately.
struct MeasurementPointPicker: View {
    let points: [CloudPoint]
    let onConfirm: ([SIMD3<Float>]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: SIMD3<Float>?
    @State private var end: SIMD3<Float>?
    @State private var candidate: SIMD3<Float>?
    @State private var endpoint = 0
    @State private var zoomed = false
    @State private var resetToken = 0
    init(points: [CloudPoint], initial: [SIMD3<Float>], onConfirm: @escaping ([SIMD3<Float>]) -> Void) {
        self.points = points; self.onConfirm = onConfirm
        _start = State(initialValue: initial.first)
        _end = State(initialValue: initial.count == 2 ? initial.last : nil)
    }
    private var confirmed: [SIMD3<Float>] { [start,end].compactMap { $0 } }
    var body: some View {
        ZStack {
            ReviewPointCloudView(points: points, trajectory: [], resetCameraToken: resetToken,
                measurementPoints: confirmed, candidatePoint: candidate, measurementZoom: zoomed,
                onPointPicked: { candidate = $0 })
                .ignoresSafeArea()
                .accessibilityLabel(L10n.text("點選表面預覽橘色候選點，再按確認。"))
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 12) {
                HStack {
                    Button(L10n.text("取消")) { dismiss() }.frame(minHeight: 44)
                    Spacer()
                    Text(L10n.text("全螢幕精準選點")).font(.headline)
                    Spacer()
                    Button(L10n.text("完成")) { onConfirm(confirmed); dismiss() }
                        .frame(minHeight: 44).disabled(start == nil || end == nil)
                }
                Text(L10n.text("單指旋轉、雙指平移或縮放。輕點表面先預覽，不會立即更改端點。"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal).background(.ultraThinMaterial)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                HStack {
                    Button {
                        zoomed.toggle()
                    } label: {
                        Label(L10n.text(zoomed ? "恢復倍率" : "放大候選位置"), systemImage: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass")
                    }.disabled(!zoomed && candidate == nil)
                    Spacer()
                    Button {
                        zoomed = false; resetToken += 1; candidate = nil
                    } label: { Label(L10n.text("顯示完整點雲"), systemImage: "arrow.up.left.and.arrow.down.right") }
                }.font(.subheadline).frame(minHeight: 44)
                Picker(L10n.text("選擇要調整的端點"), selection: $endpoint) {
                    Text(L10n.text(start == nil ? "起點（未設定）" : "起點（已設定）")).tag(0)
                    Text(L10n.text(end == nil ? "終點（未設定）" : "終點（已設定）")).tag(1)
                }.pickerStyle(.segmented).onChange(of: endpoint) { _,_ in candidate = nil }
                Text(L10n.text(candidate == nil ? "輕點想量測的表面；空白處不會選取。" : "橘色是候選位置，可放大確認後再設定端點。"))
                    .font(.caption).foregroundStyle(.secondary).frame(minHeight: 34)
                Button {
                    guard let candidate else { return }
                    if endpoint == 0 { start = candidate; if end == nil { endpoint = 1 } }
                    else { end = candidate }
                    self.candidate = nil
                } label: {
                    Label(L10n.text(endpoint == 0 ? "確認起點" : "確認終點"), systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).disabled(candidate == nil)
            }.padding().background(.ultraThinMaterial)
        }
        .preferredColorScheme(.dark)
    }
}
