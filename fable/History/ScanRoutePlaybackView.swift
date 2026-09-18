import SwiftUI

/// 拍攝關鍵影格與對應的修正後相機位置同步顯示；並非原始連續錄影。
struct ScanRoutePlaybackView: View {
    let preview: ScanPreview
    @Binding var currentIndex: Int
    @Binding var playbackFPS: Double
    var allowsFullscreen = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing = false
    @State private var expanded = false
    @State private var resetCameraToken = 0
    @State private var following = true
    @State private var displayedFrame: ScanPlaybackFrame?
    @State private var settledImageURL: URL?

    private var frames: [ScanPlaybackFrame] {
        preview.playbackFrames.isEmpty
            ? preview.images.map { ScanPlaybackFrame(image: $0, pose: nil, timestamp: nil) }
            : preview.playbackFrames
    }
    private var index: Int { min(max(0, currentIndex), max(0, frames.count - 1)) }
    private var frame: ScanPlaybackFrame? { frames.isEmpty ? nil : frames[index] }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                Group {
                    if geometry.size.width > geometry.size.height || geometry.size.width >= 700 {
                        HStack(spacing: 2) { photoPane; cloudPane }
                    } else {
                        VStack(spacing: 2) { photoPane; cloudPane }
                    }
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            controls
        }
        .padding(.horizontal, 12)
        .background(Color(uiColor: .systemBackground))
        .task(id: playing ? playbackFPS : 0) {
            guard playing, frames.count > 1 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(ScanPlaybackTiming.interval(fps: playbackFPS))) }
                catch { return }
                guard !Task.isCancelled, playing else { return }
                // 解碼較慢時等當張呈現再前進，避免高速播放不停取消載入而閃爍／凍結。
                guard settledImageURL == frame?.image else { continue }
                if currentIndex + 1 < frames.count { currentIndex += 1 }
                if currentIndex >= frames.count - 1 { playing = false; return }
            }
        }
        .onDisappear { playing = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playing = false } }
        .fullScreenCover(isPresented: $expanded) {
            NavigationStack {
                ScanRoutePlaybackView(preview: preview, currentIndex: $currentIndex, playbackFPS: $playbackFPS, allowsFullscreen: false)
                    .navigationTitle("拍攝路線回放")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("完成") { expanded = false } }
                    }
            }
        }
    }

    private var photoPane: some View {
        ScanPhoto(url: frame?.image,
                  maxDimension: playing && playbackFPS >= 10 ? 960 : (allowsFullscreen ? 1600 : 2400),
                  fit: true) { url, succeeded in
            settledImageURL = url
            displayedFrame = succeeded ? frames.first(where: { $0.image == url }) : nil
        }
            .background(.black)
            .overlay(alignment: .topLeading) { badge("拍攝影像", icon: "photo") }
            .overlay(alignment: .bottomLeading) {
                if let time = relativeTime {
                    Text(time).font(.caption.monospacedDigit()).padding(8)
                        .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white).padding(10)
                }
            }
    }

    private var cloudPane: some View {
        ZStack {
            Color(red: 0.035, green: 0.055, blue: 0.065)
            if preview.points.isEmpty && preview.trajectory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.title)
                    Text("沒有點雲或路線資料").font(.subheadline)
                    Text("仍可播放拍攝影像").font(.caption)
                }.foregroundStyle(.white.opacity(0.7))
            } else {
                ReviewPointCloudView(points: preview.points, trajectory: preview.trajectory,
                                     highlightedPose: displayedFrame?.pose, resetCameraToken: resetCameraToken,
                                     followsHighlightedPose: following, isPlaying: playing,
                                     followTransitionDuration: ScanPlaybackTiming.transitionDuration(fps: playbackFPS))
                    .accessibilityLabel("拍攝路線點雲；橘色標記為目前影像的相機位置與方向")
            }
        }
        .overlay(alignment: .topLeading) { badge(preview.points.isEmpty ? "拍攝路線" : "點雲與路線", icon: "view.3d") }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button { following.toggle() } label: {
                    Image(systemName: following ? "location.fill" : "location")
                        .foregroundStyle(following ? Color.orange : .white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(following ? "停止跟隨拍攝位置" : "跟隨拍攝位置")
                .accessibilityValue(following ? "已開啟" : "已關閉")
                Button { playing = false; following = false; resetCameraToken += 1 } label: {
                    Image(systemName: "scope").frame(width: 44, height: 44)
                }.accessibilityLabel("查看完整路線")
                if allowsFullscreen {
                    Button { playing = false; expanded = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                    }.accessibilityLabel("全螢幕預覽")
                }
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12)).padding(8)
        }
        .overlay(alignment: .bottomLeading) {
            Text(displayedFrame?.pose == nil ? "此影像沒有對應位置" : (following ? "自動跟隨拍攝位置與方向" : "橘色：目前視角 · 綠色：拍攝路線"))
                .font(.caption2).foregroundStyle(.white)
                .padding(8).background(.black.opacity(0.65), in: Capsule()).padding(8)
                .allowsHitTesting(false)
        }
    }

    private func badge(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.caption.weight(.medium))
            .padding(8).background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
            .padding(8).allowsHitTesting(false)
    }

    private var controls: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { Double(index) }, set: { playing = false; following = true; currentIndex = Int($0) }),
                   in: 0...Double(max(1, frames.count - 1)), step: 1,
                   onEditingChanged: { _ in playing = false })
                .disabled(frames.count < 2)
                .accessibilityLabel("拍攝影像進度")
                .accessibilityValue("第 \(frames.isEmpty ? 0 : index + 1) 張，共 \(frames.count) 張")
            HStack(spacing: 12) {
                Button { playing = false; following = true; currentIndex = max(0, index - 1) } label: {
                    Image(systemName: "backward.end.fill").frame(width: 44, height: 44)
                }.disabled(index == 0).accessibilityLabel("上一張")
                Button {
                    if !playing { following = true }
                    if index == frames.count - 1 { currentIndex = 0 }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 48, height: 48)
                        .foregroundStyle(.white).background(Color.accentColor, in: Circle())
                }
                .disabled(frames.count < 2)
                .accessibilityLabel(playing ? "暫停回放" : (index == frames.count - 1 ? "重新播放" : "播放拍攝路線"))
                Button { playing = false; following = true; currentIndex = min(frames.count - 1, index + 1) } label: {
                    Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                }.disabled(index + 1 >= frames.count).accessibilityLabel("下一張")
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(frames.isEmpty ? 0 : index + 1) / \(frames.count)").font(.subheadline.monospacedDigit())
                    Menu {
                        Picker("每秒影格數", selection: $playbackFPS) {
                            ForEach(ScanPlaybackTiming.supportedFPS, id: \.self) { fps in
                                Text("\(fps.formatted()) fps").tag(fps)
                            }
                        }
                    } label: {
                        Label("\(playbackFPS.formatted()) fps", systemImage: "speedometer")
                            .font(.caption).frame(minHeight: 32)
                    }
                    .accessibilityLabel("回放速度")
                    .accessibilityValue("每秒 \(playbackFPS.formatted()) 張")
                }
            }.buttonStyle(.plain)
        }.padding(.vertical, 8)
    }

    private var relativeTime: String? {
        guard let start = frames.compactMap(\.timestamp).first, let timestamp = displayedFrame?.timestamp,
              timestamp >= start, timestamp - start < 86_400 else { return nil }
        let seconds = Int(timestamp - start)
        return String(format: "拍攝時間 +%02d:%02d", seconds / 60, seconds % 60)
    }
}
