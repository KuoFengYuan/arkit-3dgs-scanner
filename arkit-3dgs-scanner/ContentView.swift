import SwiftUI
import ARKit

struct ContentView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.traditionalChinese.rawValue
    @State private var showCapture = false
    @State private var showHistory = false

    private var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Label("ARKit 3DGS Scanner", systemImage: "viewfinder")
                        .font(.headline)
                        .lineLimit(2)
                    Spacer()
                    Label(hasLiDAR ? "LiDAR" : L10n.text("標準相機"),
                          systemImage: hasLiDAR ? "sensor.tag.radiowaves.forward" : "camera")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.quaternary, in: Capsule())
                }

                Picker(L10n.text("語言"), selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { option in
                        Text(option.nativeName).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appLanguage")

                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("把眼前的空間，\n留下來。"))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("走一圈、檢查點雲與拍攝路線，再匯出空間掃描資料。"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 16)

                Button { showHistory = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath").font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("掃描紀錄")).font(.headline)
                            Text(L10n.text("預覽、分享或刪除之前的掃描")).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding(20)
                    .background(.background, in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 24) {
                        step("01", L10n.text("緩慢掃描"), L10n.text("沿著空間移動，手機會自動擷取影像。"), "viewfinder")
                        step("02", L10n.text("檢查與補掃"), L10n.text("旋轉點雲檢查缺漏，隨時回到原處補拍。"), "cube.transparent")
                        step("03", L10n.text("匯出與分享"), L10n.text("匯出影像、相機姿態與點雲，供外部 3DGS 訓練使用。"), "square.and.arrow.up")
                    }.padding(.top, 18)
                } label: {
                    Label(L10n.text("第一次掃描？查看操作指南"), systemImage: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(20)
                .background(.background, in: RoundedRectangle(cornerRadius: 24))

                Label(L10n.text("多走動、少原地旋轉，讓同一個表面被不同角度看見。"),
                      systemImage: "figure.walk")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !hasLiDAR {
                    Label(L10n.text("此裝置可擷取影像與稀疏點雲；完整幾何與平面圖建議使用 LiDAR 裝置。"),
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button { showCapture = true } label: {
                    Label(L10n.text("開始掃描"), systemImage: "camera.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!ARWorldTrackingConfiguration.isSupported)
                Text(ARWorldTrackingConfiguration.isSupported
                     ? L10n.text("掃描與資料優化都在裝置上進行") : L10n.text("此裝置不支援 AR 掃描"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .fullScreenCover(isPresented: $showCapture) { CaptureView() }
        .sheet(isPresented: $showHistory) { ScanHistoryView() }
    }

    private func step(_ number: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(number)  \(title)").font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview { ContentView() }
