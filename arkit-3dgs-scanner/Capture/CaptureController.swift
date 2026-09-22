//
//  CaptureController.swift
//  fable — ARKit session 主控：狀態監聽、智慧快門觸發、背景寫入調度、匯出
//
//  執行緒模型：
//  - ARSession delegate 預設回呼在主執行緒；session(_:didUpdate:) 內只做 O(1) 品質計算，
//    關鍵幀觸發時做一次 buffer memcpy（~2ms、約 2Hz），不會卡 UI。
//  - JPEG 編碼 / 磁碟 I/O 在 FrameWriter actor；點雲反投影在 PointCloudAccumulator actor。
//  - 背壓：pendingWrites 達上限即跳過本幀，快門條件仍成立，下一幀自動重試。
//

import Foundation
import ARKit
import AVFoundation
import SceneKit
import Combine
import UIKit
import simd

@MainActor
final class CaptureController: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle          // 相機準備與取景
        case scanning
        case processing    // 掃描後：錨點姿態修正 + 點雲重融合（進度條）
        case review        // 3D 檢視優化後點雲，決定匯出 / 續掃 / 捨棄
        case exporting     // 寫 COLMAP + zip
        case done
    }

    // MARK: - UI 狀態
    @Published private(set) var phase: Phase = .idle
    @Published var assessment = QualityAssessment()
    @Published var keyframeCount = 0
    @Published var pointCount = 0
    /// 融合完成度：已被足夠多幀觀測的表面占比。場景模式沒有涵蓋率圓頂，
    /// 這是唯一能回答「掃夠了沒」的訊號；也比幀數有意義（站原地拍 100 幀是沒用的）。
    @Published var fusionCompleteness: Double = 0
    @Published var exportedZip: URL?
    @Published var statusText: String?
    @Published private(set) var sessionState: CaptureSessionState = .initializing
    @Published private(set) var scanNotice: String?
    var trackingReady: Bool { sessionState.canCapture }
    var canStartScan: Bool { phase == .idle && sessionState.canCapture }
    var canUseScan: Bool { refinedRecords.contains { $0.blurVerdict == .keep } }
    var canResumeScan: Bool {
        guard phase == .review, writer != nil else { return false }
        if case .failed = sessionState { return false }
        return true
    }
    var canClose: Bool {
        phase == .idle || phase == .review || phase == .done
    }
    private var authorizationTask: Task<Void, Never>?
    private var isAttached = false
    private var isInBackground = false
    private var needsSessionResume = false
    private var scanGeneration = UUID()
    /// 即時點雲疊加。**預設顯示** —— RoomPlan 的即時線框已經關掉了，
    /// 少了它，點雲就是掃描當下唯一能回答「這裡掃到了沒」的東西。
    @Published var showPointCloud = true
    /// RoomPlan 即時結構疊加（牆／門／窗的發光邊框）。預設開啟：
    /// 它直接回答「掃到哪了」，而且面積小、不擋畫面。
    @Published var showRoomPlan = true
    /// 預覽點雲上色模式。掃描當下使用者最需要知道的不是顏色對不對，
    /// 而是「這塊融合夠了沒、要不要再繞一次」——熱圖直接把觀測不足的表面標紅。
    @Published var colorMode: PointColorMode = .rgb
    /// 掃描期間鎖定曝光 / 白平衡（預設開啟）：光度一致，3DGS 的光度損失才對齊得起來。
    /// **對焦不鎖**（見 CameraControls.lockForScan：鎖了會把整段掃描凍在起始那一刻的景深，
    /// 鏡頭一離開就糊）。代價是連續對焦會拉焦，拉焦當下那幾幀確實不清晰 ——
    /// 由 QualityMonitor 的清晰度閘門（直接量影像，不是推估）擋掉，不讓它們變成關鍵幀。
    @Published var lockCameraParams = true
    @Published var exportProgress: Double = 0
    /// Review 階段顯示（＝實際將匯出）的重融合點雲與修正後軌跡
    @Published var reviewPoints: [CloudPoint] = []
    @Published var reviewTrajectory: [simd_float4x4] = []

    /// 相機手動調整（曝光補償/快門/ISO/白平衡/對焦）。預設全自動；
    /// 使用者調整後，startScan 只鎖定「還在自動」的項目，手動值原樣帶進整段掃描 ——
    /// 也就是「預設鎖定，但可以調整完再鎖」。
    let cameraControls = CameraControls()
    /// 平面圖擷取（RoomPlan，共用同一個 ARSession）。掃描時同步收集，匯出時轉成 usdz/json/svg
    let floorPlan = FloorPlanCapture()
    /// 特徵追蹤：掃描時同步抽角點並建立跨幀對應，停止後餵給 BundleAdjuster。
    /// 放在掃描期做而非停止後，是因為停止後要重新解碼 120 張 JPEG（~2.4s，比 BA 還貴），
    /// 而此刻影像已經在記憶體裡。
    private var featureTracker = FeatureTracker()
    private var featureProcessor: LatestFrameProcessor<Keyframe>?
    private var fusionCancel = CancelFlag()
    private var capturePerformance = CapturePipelineReport()
    /// 建好的平面圖，於 processing 階段產生 → review 可顯示、匯出時寫檔
    @Published private(set) var floorPlanData: FloorPlanData?
    /// 是否以上次的 ARWorldMap 開始 —— 讓這次掃描與上次落在**同一個座標系**。
    /// 這是跨 session（關掉 app 再掃下一個房間）唯一的共同參考；
    /// 同一次 session 內的續掃 ARKit 本來就會自動重定位，不需要它。
    @Published private(set) var continueFromLastMap = false
    /// ARKit 正在以舊地圖重定位（尚未接上）。此時姿態不可信，必須擋住開拍。
    var relocalizing: Bool { sessionState == .relocalizing }
    /// 迴環閉合提示：走遠之後提醒回起點，讓 ARKit 修正整條軌跡的累積漂移
    @Published private(set) var loopHint: String?
    /// RoomPlan 的即時引導 ＋ 牆高不足提示（見 FloorPlanCapture.coachingHint）。
    /// **這是平面圖品質最重要的一條回饋**：每一份實機 log 都是
    /// 「2 牆、樓高 0.80m ⚠️ 掃描不完整」，而那行警告先前只在 review 才印 ——
    /// 大範圍場景到那時已經不可能重走一遍。
    @Published private(set) var floorPlanHint: String?
    /// 近 4 秒因清晰度不足而放棄的抓幀數（0 = 沒在掉幀）
    @Published private(set) var recentRejectCount = 0
    /// 掃描品質摘要，review 階段顯示（原本只印在 log 裡，使用者看不到）
    @Published private(set) var scanSummary: ScanSummary?

    /// review 期間是否疊出平面圖預覽（匯出前先驗證，不要盲匯）
    @Published var showFloorPlan = false
    /// 平面圖是否連活動家具（椅子/沙發/桌子/電視）一起畫。
    /// 預設關：建築製圖只畫固定設備，活動家具會蓋住圖面。
    /// 畫面與匯出共用這個旗標 —— 看到的就是匯出的。
    @Published var showPlanFurniture = false
    @Published var refineCameraPoses = true
    @Published var reconstructFromImages = true
    @Published private(set) var imageReconstructionReport: RGBReconstructionEngine.Report?
    private(set) var config = CaptureConfig()
    private var trackingStability = TrackingStabilityGate()
    private var poseContinuity = PoseContinuityGate()
    private var sparseTrackingEpoch = 0
    let supportsLiDAR = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    @Published private(set) var useLiDAR = true
    var hasLiDAR: Bool { supportsLiDAR && useLiDAR }

    /// 僅能在開拍前切換；以新 session 移除既有深度／網格，避免混合兩種實驗資料。
    func setLiDAREnabled(_ enabled: Bool) {
        guard phase == .idle, supportsLiDAR, useLiDAR != enabled else { return }
        useLiDAR = enabled
        if !hasLiDAR { colorMode = .rgb }
        continueFromLastMap = false
        sessionState = .initializing
        pixelBufferPool = nil
        prepareCamera()
    }

    // MARK: - 內部元件
    private weak var arView: ARSCNView?
    private var visualizer: CoverageVisualizer?
    private let monitor = QualityMonitor()
    private var shutter = SmartShutter()
    private var writer: FrameWriter?
    private var accumulator: PointCloudAccumulator?
    private var sessionDir: URL?
    private var frameIndex = 0
    /// 迴環閉合追蹤：起點、累積行走距離、是否已閉合過
    private var scanStartPosition: SIMD3<Float>?
    private var traveledM: Float = 0
    private var lastTravelPosition: SIMD3<Float>?
    private var loopClosed = false
    private var lastWorldMapMB: Double?
    /// BA 的結果。**注意位姿不一定被套用**（config.baApplyPoses），
    /// 所以摘要要一併記下「有沒有套用」與保留集判定，否則 baAfterPx 會被誤讀成
    /// 「輸出的解析度天花板」，而實際輸出用的是 ARKit 位姿。
    private var baResult: PoseRefineResult?
    /// 因清晰度不足而放棄抓幀的次數（診斷用：拿來判斷門檻是否過嚴）
    private var sharpnessRejects = 0
    /// 近幾秒被放棄的時間戳。用來即時告訴使用者「你正在掉幀」——
    /// 這是**實測結果**，比 blurPixels 那個推估值可靠：實機 log 出現過
    /// 「69% 的幀被清晰度閘門丟掉，但 HUD 全程沒有任何警告」，
    /// 因為推估值(11.4px 中位數)沒到警告線(14px)，而清晰度閘門從 ~11px 就開始擋。
    /// 與其去猜兩個門檻要怎麼對齊，不如直接把發生的事講出來。
    private var recentRejects: [TimeInterval] = []
    private var frameCounter = 0
    private var pendingWrites = 0
    private var writeTasks: [Int: Task<Void, Never>] = [:]
    private var previewTask: Task<Void, Never>?
    private var previewRenderTask: Task<Void, Never>?
    private var previewMainTotalMS = 0.0
    private var previewMainMaxMS = 0.0
    private var assessedScanFrames = 0
    private var blockedScanFrames = 0
    private var previewInFlight = false
    /// 本幀是否已進過預覽融合（關鍵幀路徑與 10Hz 路徑可能落在同一幀，避免 obs 重複累加）
    private var lastPreviewFrame = -1
    private var pixelBufferPool: CVPixelBufferPool?
    private var lastWarningHaptic: TimeInterval = 0
    private var lastSharpnessRejectTime: TimeInterval = -.infinity
    private var lastSparseIntegration: TimeInterval = 0
    private let captureHaptic = UIImpactFeedbackGenerator(style: .light)
    private let warningHaptic = UINotificationFeedbackGenerator()
    /// 關鍵幀 → ARAnchor：ARKit 地圖優化（迴環/重定位修正）會回頭調整錨點，
    /// 停止時讀回即得「修正後姿態」—— 免費的輕量級 pose graph 精修
    private var keyframeAnchors: [Int: UUID] = [:]
    private var refinedRecords: [FrameRecord] = []
    /// 點雲空間磚 → ARAnchor：融合/去重在錨點局部系進行，錨點被 ARKit 修正時整磚跟著移動
    private var tileAnchorID: [Int64: UUID] = [:]
    private var tileKeyByAnchor: [UUID: Int64] = [:]
    private var latestTileTransforms: [Int64: simd_float4x4] = [:]

    // MARK: - Session 生命週期

    func attach(arView: ARSCNView) {
        self.arView = arView
        isAttached = true
        arView.session.delegateQueue = .main
        arView.session.delegate = self

        let viz = CoverageVisualizer(config: config)
        viz.attach(to: arView.scene)
        // 初始狀態必須在這裡套用一次 —— 先前只有 toggle 時才呼叫 setPointCloudHidden，
        // 所以預設值改成 false 之後，第一次進畫面仍然會看到點雲。
        viz.setPointCloudHidden(!showPointCloud)
        viz.setRoomHidden(!showRoomPlan)
        // RoomPlan 的即時面直接進渲染層，不繞 SwiftUI（每 0.4s 一組陣列，
        // 走 @Published 等於每次都讓整個 HUD 重新求值）
        floorPlan.onRoomUpdated = { [weak viz] surfaces in
            viz?.updateRoomSurfaces(surfaces)
            viz?.updateDollhouse(surfaces)
        }
        viz.setDollhouseHidden(!showRoomPlan)
        visualizer = viz

        prepareCamera()
    }

    /// 權限回覆可能晚於畫面離開，啟動前再次確認生命週期。
    func prepareCamera() {
        guard isAttached, !isInBackground, phase == .idle else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            sessionState = .unsupported
            return
        }
        guard authorizationTask == nil else { return }
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            defer { authorizationTask = nil }
            var authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                sessionState = .requestingPermission
                authorized = await AVCaptureDevice.requestAccess(for: .video)
            }
            guard !Task.isCancelled, isAttached, !isInBackground else { return }
            guard authorized else {
                sessionState = .permissionDenied
                return
            }
            runSession()
            monitor.start()
        }
    }

    func sceneActivityChanged(isActive: Bool) {
        isInBackground = !isActive
        guard isAttached else { return }
        if !isActive {
            guard phase == .idle || phase == .scanning else { return }
            previewRenderTask?.cancel()
            needsSessionResume = true
            sessionState = .interrupted
            arView?.session.pause()
            monitor.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        } else if needsSessionResume {
            needsSessionResume = false
            if phase == .idle {
                prepareCamera()
            } else if phase == .scanning {
                resumeTracking()
            }
        } else if phase == .idle, sessionState == .permissionDenied || sessionState == .requestingPermission {
            prepareCamera()
        }
    }

    private func resumeTracking() {
        trackingStability.reset()
        poseContinuity.reset()
        sparseTrackingEpoch += 1
        sessionState = .relocalizing
        arView?.session.run(CaptureSessionConfiguration.make(config: config, useLiDAR: hasLiDAR), options: [])
        monitor.start()
        if phase == .scanning { startPreviewRendering() }
        shutter.reset()
        if lockCameraParams { applyCameraLocks() }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func teardown() {
        fusionCancel.cancel()
        if let processor = featureProcessor { Task { await processor.close() } }
        featureProcessor = nil
        isAttached = false
        previewRenderTask?.cancel()
        authorizationTask?.cancel()
        authorizationTask = nil
        scanGeneration = UUID()
        arView?.session.delegate = nil
        releaseCameraLocks()
        arView?.session.pause()
        monitor.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// 印出本機可用的 ARKit 影像格式。
    ///
    /// 訂正一個先前寫錯的推論：我原本說「4K 拍再降到 1600，雜訊降 2.4 倍」。
    /// 那對固定 sensor 不成立 —— iPhone 輸出 1920×1440 時本來就已經在 sensor 上做 binning，
    /// 4K 只是少 bin 一點；降採樣回同一尺寸後 SNR 大致打平。
    /// **高解析度買到的是細節，不是低雜訊。** 顆粒感要靠 ISO（見 denoiseISOThreshold）解。
    /// 這份清單留著是為了知道有沒有「更高解析度又維持 60fps」的選項可換細節（不換雜訊），
    /// 以及確認目前跑在哪個格式 —— 只能實機問。
    private func logVideoFormats() {
        let cur = arView?.session.configuration?.videoFormat
        for f in ARWorldTrackingConfiguration.supportedVideoFormats {
            let r = f.imageResolution
            let mark = (f == cur) ? "  ← 目前使用" : ""
            print(String(format: "[VideoFormat] %.0f×%.0f @ %dfps  %@%@",
                         r.width, r.height, f.framesPerSecond,
                         f.captureDeviceType.rawValue, mark))
        }
    }

    /// 切換「延續上次座標系」。**立刻重跑 session** 而不是等按快門 ——
    /// 重定位需要使用者把鏡頭對回舊區域、可能要幾秒，
    /// 這件事必須發生在開拍之前，否則等於用不可信的姿態拍了一段。
    func setContinueFromLastMap(_ on: Bool) {
        guard phase == .idle else { return }
        continueFromLastMap = on && WorldMapStore.hasLatest
        sessionState = .initializing
        prepareCamera()
        statusText = nil
    }

    private func runSession() {
        guard isAttached, !isInBackground,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        trackingStability.reset()
        poseContinuity.reset()
        sparseTrackingEpoch += 1
        let map = continueFromLastMap ? WorldMapStore.loadLatest() : nil
        sessionState = map == nil ? .initializing : .relocalizing
        arView?.session.run(CaptureSessionConfiguration.make(config: config, useLiDAR: hasLiDAR, initialWorldMap: map),
                           options: [.resetTracking, .removeExistingAnchors])
        logVideoFormats()
        // 曝光上限要在取景階段就設好，AE 才有時間在上限內收斂；
        // session.run 會重設裝置設定，故必須在 run 之後。
        cameraControls.capExposureDuration()
    }

    // MARK: - 開始 / 停止

    func startScan() {
        guard canStartScan else { return }
        config.baRounds = refineCameraPoses && hasLiDAR ? 6 : 0
        config.reconstructFromImages = reconstructFromImages
        do {
            try beginSessionStorage()
        } catch {
            statusText = "無法建立掃描資料夾：\(error.localizedDescription)"
            return
        }
        scanGeneration = UUID()
        scanNotice = nil
        if lockCameraParams { applyCameraLocks() }
        startFloorPlan(fresh: true)
        // 掃描中收合：中途改曝光會讓前後幀成像不一致（外觀校正要修的正是這個）
        cameraControls.expanded = nil
        cameraControls.railExpanded = false
        shutter.reset()
        frameIndex = 0
        keyframeCount = 0
        pointCount = 0
        sharpnessRejects = 0
        recentRejects = []
        recentRejectCount = 0
        featureTracker = FeatureTracker()
        let tracker = featureTracker
        let cfg = config
        featureProcessor = config.baRounds > 0 ? LatestFrameProcessor<Keyframe> { frame in
            guard let depth = frame.depthData, frame.depthWidth > 0, frame.depthHeight > 0 else { return }
            await tracker.add(frameID: frame.record.id, luma: frame.pixelBuffer, depth: depth,
                              conf: frame.confidenceData.map { [UInt8]($0) },
                              dw: frame.depthWidth, dh: frame.depthHeight,
                              K: frame.record.intrinsics, c2w: frame.c2w,
                              minDepth: cfg.pointMinDepthM, maxDepth: cfg.pointMaxDepthM)
        } : nil
        capturePerformance = CapturePipelineReport()
        capturePerformance.configuredMinimumIntervalS = config.minKeyframeInterval
        capturePerformance.poseRefinementEnabled = config.baRounds > 0
        pendingWrites = 0
        writeTasks = [:]
        scanStartPosition = nil
        lastTravelPosition = nil
        traveledM = 0
        loopClosed = false
        loopHint = nil
        floorPlanHint = nil
        lastWorldMapMB = nil
        baResult = nil
        scanSummary = nil
        previewMainTotalMS = 0
        previewMainMaxMS = 0
        assessedScanFrames = 0
        blockedScanFrames = 0
        imageReconstructionReport = nil
        phase = .scanning
        startPreviewRendering()
        statusText = nil
        UIApplication.shared.isIdleTimerDisabled = true   // 掃描中不鎖屏
        captureHaptic.prepare()
    }

    /// 停止掃描 → 取回錨點修正後姿態 → 暫停 AR → 背景重融合 → review
    func stopScan() {
        guard phase == .scanning else { return }
        fusionCancel.cancel()
        fusionCancel = CancelFlag()
        phase = .processing
        previewRenderTask?.cancel()
        exportProgress = 0
        statusText = "正在儲存最後的影像…"
        UIApplication.shared.isIdleTimerDisabled = true
        releaseCameraLocks()
        let generation = scanGeneration
        floorPlan.stopCapture()
        let tStop = Date()
        Task {
            // Let the processing state render before snapshotting any scene data.
            await Task.yield()
            for task in Array(writeTasks.values) { await task.value }
            guard isAttached, generation == scanGeneration else { return }
            statusText = "正在完成最後的特徵處理…"
            await featureProcessor?.drain()
            guard isAttached, generation == scanGeneration else { return }
            let featureWork = await featureProcessor?.report()
            let retained = await featureTracker.retainedState()
            let timestamps = await writer?.snapshotRecords().map(\.timestamp).sorted() ?? []
            guard isAttached, generation == scanGeneration else { return }
            if let featureWork { capturePerformance.featureWork = featureWork }
            capturePerformance.retainedFeatureFrames = retained.descriptorFrames
            capturePerformance.archivedFeatureObservations = retained.archivedObservations
            capturePerformance.discardedFeatureObservations = retained.discardedObservations
            let intervals = zip(timestamps, timestamps.dropFirst()).map { max(0, $1 - $0) }
            capturePerformance.savedIntervalTotalS = intervals.reduce(0, +)
            capturePerformance.savedIntervalMaxS = intervals.max() ?? 0
            if let directory = sessionDir {
                do {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(capturePerformance).write(to: directory.appendingPathComponent("capture-performance.json"), options: .atomic)
                } catch { print("拍攝效能報告儲存失敗：\(error.localizedDescription)") }
            }
            await previewTask?.value
            await previewRenderTask?.value
            guard isAttached, generation == scanGeneration else { return }
            visualizer?.releasePointCloudGeometry()
            pixelBufferPool = nil
            previewTask = nil
            previewRenderTask = nil

            // Persist a bounded fallback before optional map/mesh processing. A failed later
            // stage must not leave a long scan with only an unfinished in-memory preview.
            statusText = "正在保存掃描預覽…"
            await saveProcessingCheckpoint()
            guard isAttached, generation == scanGeneration else { return }
            // Keep a bounded anchor-local fallback for resume, rather than holding the entire
            // live grid alongside a second offline grid and floor-plan workspaces.
            await accumulator?.prepareForOfflineFusion(limit: min(config.exportMaxPoints, 100_000))
            guard isAttached, generation == scanGeneration else { return }
            let refined = snapshotRefinedTransforms()
            statusText = "正在整理場景網格…"
            let meshVerts = await snapshotMeshVertices()
            guard isAttached, generation == scanGeneration else { return }
            statusText = "正在保存世界地圖…"
            await saveWorldMapBeforeProcessing()
            statusText = "正在完成空間擷取…"
            await floorPlan.waitForSegment(timeout: 12)
            guard isAttached, generation == scanGeneration else { return }
            arView?.session.pause()
            monitor.stop()

            // Map serialization, RoomPlan building and fusion must not overlap their peaks.
            await processScan(refinedTransforms: refined, meshVertices: meshVerts, since: tStop)
            guard isAttached, generation == scanGeneration else { return }
            if scanSummary != nil { scanSummary?.worldMapMB = lastWorldMapMB }
            statusText = scanNotice ?? statusText
            exportProgress = 1
            phase = .review
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func saveProcessingCheckpoint() async {
        guard let writer, let accumulator, let dir = sessionDir else { return }
        let records = await writer.snapshotRecords()
        let points = await accumulator.checkpointPoints(limit: min(config.exportMaxPoints, 100_000),
                                                  anchorTransforms: latestTileTransforms)
        do { try await ScanLibrary.shared.saveReview(directory: dir, points: points, records: records) }
        catch { print("掃描中繼預覽儲存失敗：\(error.localizedDescription)") }
    }

    private func saveWorldMapBeforeProcessing() async {
        guard RefusionEngine.hasOptionalProcessingHeadroom else {
            scanNotice = "記憶體不足以安全保存世界地圖，已略過；掃描照片與預覽已保留。"
            return
        }
        if let box = await captureWorldMap() { await persistWorldMap(box) }
    }

    private func processScan(refinedTransforms: [Int: [Double]], meshVertices: [SIMD3<Float>],
                             since tStop: Date) async {
        guard let writer, let accumulator, let dir = sessionDir else {
            phase = .idle
            return
        }
        let generation = scanGeneration
        let cancel = fusionCancel
        // 分段計時從**按下停止**起算。先前 t0 設在重融合前面，於是「總計 1.81s」
        // 完全不含世界地圖、BA、模糊複核 —— 一個叫「總計」卻不是總計的數字，
        // 正是我在這個專案被誤導過三次的同一類錯誤。
        var seg: [(String, Double)] = []
        var tMark = tStop
        func mark(_ name: String) {
            seg.append((name, Date().timeIntervalSince(tMark)))
            tMark = Date()
        }
        // 每一段都講出來，並且讓進度條涵蓋整條流程。
        //
        // 先前進度條只由重融合的回呼驅動，而重融合是**最後**一段 ——
        // 前面三段使用者看到的是一條靜止在 0% 的進度條，那比沒有進度條更像卡住。
        // 權重是暫定的：真實比例要等新的分段計時（見下方 mark）跑過實機才知道。
        func stage(_ text: String, _ base: Double) {
            statusText = text
            exportProgress = base
        }

        stage("讀取關鍵幀…", 0)
        let raw = await writer.snapshotRecords()
        guard isAttached, scanGeneration == generation, !cancel.isCancelled else { return }
        if !raw.isEmpty {
            let sharp = raw.map(\.sharpnessRatio).sorted()
            let blur = raw.map(\.estimatedBlurPx).sorted()
            let iso = raw.map(\.iso).sorted()
            let expo = raw.map(\.exposureDuration).sorted()
            let m = raw.count / 2
            print(String(format:
                "清晰度: %d 幀，清晰度比中位數 %.2f / 最差 %.2f；模糊估計中位數 %.1fpx / 最差 %.1fpx；" +
                "另有 %d 次因不夠清晰而放棄抓幀",
                raw.count, sharp[m], sharp[0], blur[m], blur[raw.count - 1], sharpnessRejects))
            print(String(format:
                "曝光: ISO 中位數 %.0f / 最高 %.0f，快門中位數 1/%.0fs / 最長 1/%.0fs（上限 1/60s）",
                iso[m], iso[raw.count - 1], 1 / expo[m], 1 / expo[raw.count - 1]))
        }
        var corrected = 0
        defer {
            if isAttached, scanGeneration == generation { reportDrift(raw: raw, refined: refinedRecords) }
        }
        refinedRecords = raw.map { record in
            var r = record
            if let t = refinedTransforms[r.id] {
                if t != r.transform { corrected += 1 }
                r.transform = t
            }
            return r
        }
        // 局部 BA：以「ARKit ＋ 錨點修正」為初值，用掃描時建好的跨幀對應做微調。
        // 位置在這裡的理由：
        //   · 必須在錨點修正**之後** —— 那是初值，BA 只做微調
        //   · 必須在 BlurFilter 與重融合**之前** —— 它們都吃姿態，晚了就白做
        mark("停止收尾與讀取關鍵幀")
        let anchorCorrectedRecords = refinedRecords
        if config.baRounds > 0 {
            stage("逐張匹配拍攝影像…", 0.10)
            let records = BlurFilter.annotate(refinedRecords)
            let rounds = config.baRounds
            // The live worker is best-effort; release it and rebuild tracks from ALL saved
            // usable depth frames. Disk reads and descriptor storage have fixed limits.
            await featureTracker.reset()
            let onProgress: @Sendable (Double) -> Void = { p in
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .processing, self.scanGeneration == generation else { return }
                    self.exportProgress = 0.10 + p * 0.24
                    self.statusText = p < 0.85 ? "逐張匹配拍攝影像… \(Int(p / 0.85 * 100))%" : "驗證相機位置修正…"
                }
            }
            let result = await Task.detached(priority: .userInitiated) {
                await OfflinePoseRefinement.run(records: records, directory: dir, rounds: rounds,
                                                 isCancelled: { cancel.isCancelled }, progress: onProgress)
            }.value
            guard isAttached, scanGeneration == generation, !cancel.isCancelled else { return }
            if config.baApplyPoses { refinedRecords = result.records }
            baResult = result.ba
            do {
                try JSONEncoder().encode(result.report).write(to: dir.appendingPathComponent("pose-refinement.json"), options: .atomic)
            } catch { print("位姿精修報告儲存失敗：\(error.localizedDescription)") }
            if result.report.status != "validated" {
                scanNotice = result.report.notice
            }
        }

        // 模糊幀全域複核。必須在姿態修正**之後**：BlurFilter 靠位置/朝向找「看同一片表面」
        // 的鄰居，用未修正的姿態會找錯鄰居。判定寫回紀錄而非直接刪除，
        // poses_refined.jsonl 與 images/ 都保留完整，可回頭檢查判定對不對。
        mark("位姿校正")
        stage("複核模糊幀…", 0.35)
        let recordsToCheck = refinedRecords
        let annotated = await Task.detached(priority: .userInitiated) {
            BlurFilter.annotate(recordsToCheck)
        }.value
        guard isAttached, scanGeneration == generation, !cancel.isCancelled else { return }
        refinedRecords = annotated
        let dropped = refinedRecords.filter { $0.blurVerdict == .drop }.count
        let demoted = refinedRecords.filter { $0.blurVerdict == .demote }.count
        if dropped + demoted > 0 {
            print("模糊複核: \(refinedRecords.count) 幀 → 排除 \(dropped) 幀（幾何不可信，點雲也不用）"
                  + "、\(demoted) 幀（顏色糊，不進訓練但深度仍以降權併入點雲）")
        }

        mark("模糊複核")
        if hasLiDAR, config.captureFloorPlan, FloorPlanCapture.isSupported {
            stage("建立空間結構…", 0.40)
            let plan = await floorPlan.build()
            guard isAttached, scanGeneration == generation, !cancel.isCancelled else { return }
            if let plan, !plan.walls.isEmpty {
                floorPlanData = plan
                logFloorPlan(plan)
            }
        }
        guard isAttached, scanGeneration == generation, !cancel.isCancelled else { return }

        var points: [CloudPoint] = []
        var fusionInterrupted = false
        if hasLiDAR && config.saveDepth && !refinedRecords.isEmpty {
            stage("融合點雲…", 0.45)
            let records = refinedRecords
            let cfg = config
            // 重融合佔進度條的後 55%（前面三段各自佔一段，見 stage）
            let onProg: @Sendable (Double) -> Void = { p in
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .processing, self.scanGeneration == generation else { return }
                    self.exportProgress = 0.45 + p * 0.50
                }
            }
            let mesh = (config.baApplyPoses && !(baResult?.poses.isEmpty ?? true)) ? [] : meshVertices
            // Mobile output has one hard budget shared by review and floor-plan input.
            // Do not materialize a 2M-point plan cloud plus a second downsampling dictionary.
            let needsDensePlan = config.pointCloudFloorPlan && floorPlanData == nil
            let result = await Task.detached(priority: .userInitiated) {
                RefusionEngine.refuseWithReport(records: records, sessionDir: dir, config: cfg,
                                      meshVertices: mesh,
                                      target: cfg.exportMaxPoints,
                                      isCancelled: { cancel.isCancelled },
                                      progress: onProg)
            }.value
            guard isAttached, scanGeneration == generation, !cancel.isCancelled else { return }
            if result.report.status == "memoryPressure" {
                fusionInterrupted = true
                // Fallback live points were built with anchor poses, not the newly refined poses.
                refinedRecords = BlurFilter.annotate(anchorCorrectedRecords)
                baResult?.poses = [:]
                scanNotice = "融合時記憶體不足，已停止精細融合並保留即時點雲預覽；照片與深度資料仍完整保留。"
                points = await accumulator.checkpointPoints(limit: min(cfg.exportMaxPoints, 100_000),
                                                            anchorTransforms: latestTileTransforms)
            } else {
                let dense = result.points
                if needsDensePlan, RefusionEngine.hasOptionalProcessingHeadroom {
                    stage("建立平面圖…", 0.96)
                    await usePointCloudPlan(dense)
                }
                guard isAttached, scanGeneration == generation, !cancel.isCancelled else { return }
                points = dense
            }
        }
        if !hasLiDAR && config.reconstructFromImages {
            stage("影像多視角重建…", 0.45)
            let records = refinedRecords, cfg = config
            let onProgress: @Sendable (Double) -> Void = { p in
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .processing else { return }
                    self.exportProgress = 0.45 + p * 0.55
                }
            }
            let result = await Task.detached(priority: .userInitiated) {
                RGBReconstructionEngine.reconstruct(records: records, sessionDir: dir, config: cfg, progress: onProgress)
            }.value
            let sparse = await accumulator.bestPoints(target: cfg.exportMaxPoints, anchorTransforms: latestTileTransforms)
            points = await Task.detached(priority: .userInitiated) {
                RGBReconstructionEngine.supplement(rgb: result.points, sparse: sparse, config: cfg)
            }.value
            var report = result.report
            report.reviewPointsIncludingSparse = points.count
            imageReconstructionReport = report
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: dir.appendingPathComponent("rgb-reconstruction.json"), options: .atomic)
            } catch {
                scanNotice = "影像重建報告儲存失敗：\(error.localizedDescription)"
            }
            if result.points.isEmpty, scanNotice == nil {
                scanNotice = points.isEmpty
                    ? "照片已保留，但尚無可靠點雲。請對準有紋理的表面側向補拍至少三張重疊照片。"
                    : "影像重建未取得可靠匹配，目前顯示已驗證的稀疏特徵點。請側向補拍至少三張重疊照片。"
            }
        }
        if points.isEmpty, !fusionInterrupted {      // 無 LiDAR / 無深度時退回即時累積雲
            points = await accumulator.bestPoints(target: config.exportMaxPoints,
                                                   anchorTransforms: latestTileTransforms)
        }
        mark("重融合")

        // 後處理時間不含最後等待世界地圖存檔與 RoomPlan 原始片段的時間。
        let total = seg.reduce(0) { $0 + $1.1 }
        print(String(format: "點雲處理耗時: %.2fs = ", total)
              + seg.map { String(format: "%@ %.2fs", $0.0, $0.1) }.joined(separator: " + ")
              + "（含停止收尾；重融合段含已執行的平面圖，尚未計入最後歷史存檔）")

        stage("挑選訓練影像…", 0.98)
        let selectionRecords = refinedRecords
        let selection = await Task.detached(priority: .utility) {
            TrainingFrameSelector.select(selectionRecords,
                evidence: TrainingFrameSelector.evidence(records: selectionRecords, directory: dir,
                                                         isCancelled: { cancel.isCancelled }))
        }.value
        guard isAttached, scanGeneration == generation, !cancel.isCancelled else { return }
        if let notice = selection.notice { scanNotice = [scanNotice, notice].compactMap { $0 }.joined(separator: "\n") }
        do {
            try JSONEncoder().encode(selection).write(to: dir.appendingPathComponent("training-selection.json"), options: .atomic)
        } catch { print("訓練選幀報告儲存失敗：\(error.localizedDescription)") }

        reviewPoints = points
        if !hasLiDAR, points.isEmpty, scanNotice == nil {
            scanNotice = "照片已保留，但尚無通過多視角驗證的特徵點。請對準有紋理的表面緩慢側向補拍。"
        }
        // RoomPlan 沒開（或機型不支援）→ 平面圖直接用點雲版。
        // 不這樣做的話 floorPlanData 永遠是 nil，review 的平面圖按鈕不會出現，
        // 使用者要等到匯出才知道有沒有平面圖。
        // 有 LiDAR 的路徑上這已經在融合那一段用高密度點雲算完了（見上），
        // 所以這裡只補「沒有深度、退回即時累積雲」那條路。
        if !fusionInterrupted, RefusionEngine.hasOptionalProcessingHeadroom, floorPlanData == nil,
           !hasLiDAR || !config.captureFloorPlan || !FloorPlanCapture.isSupported { await usePointCloudPlan() }
        if hasLiDAR {
            var performance = await accumulator.performanceReport()
            performance.mainApplyTotalMS = previewMainTotalMS
            performance.mainApplyMaxMS = previewMainMaxMS
            performance.assessedFrames = assessedScanFrames
            performance.qualityBlockedFrames = blockedScanFrames
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(performance).write(to: dir.appendingPathComponent("preview-performance.json"), options: .atomic)
            } catch { print("預覽效能報告儲存失敗：\(error.localizedDescription)") }
        }
        reviewTrajectory = refinedRecords.map { RefusionEngine.float4x4(rowMajor: $0.transform) }
        pointCount = points.count
        do {
            try await ScanLibrary.shared.saveReview(directory: dir, points: points, records: refinedRecords)
        } catch {
            scanNotice = "掃描原始資料已保留，但歷史點雲預覽儲存失敗：\(error.localizedDescription)"
        }
        statusText = corrected > 0 ? "姿態已修正 \(corrected) 幀（ARKit 地圖優化）" : nil
    }

    /// 驗收後寫入 COLMAP、PLY 與修正後姿態，打包成外部 3DGS 訓練資料。
    func exportAndShare() {
        guard phase == .review,
              let dir = sessionDir else { return }
        guard canUseScan else {
            statusText = "尚無可用影像，請繼續掃描後再匯出"
            return
        }
        let returnPhase = phase
        phase = .exporting
        exportedZip = nil
        statusText = "正在整理影像與點雲…"
        UIApplication.shared.isIdleTimerDisabled = true
        let records = refinedRecords
        let points = reviewPoints
        let flipWorldUp = config.flipWorldUpForExport
        Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ExportManager.writeTrainingDataset(records: records, points: points, to: dir,
                                                           flipWorldUp: flipWorldUp)
                }.value
                try await writeFloorPlan(to: dir)
                statusText = "正在壓縮檔案，完成後即可分享…"
                let zip = try await Task.detached(priority: .userInitiated) {
                    try ExportManager.makeArchive(of: dir)
                }.value
                _ = await writer?.finish()
                exportedZip = zip
                statusText = "已完成：\(records.count) 張影像・\(points.count) 個點"
                phase = .done
                writer = nil
                accumulator = nil
            } catch {
                // 保留 writer 與驗收資料，允許重試及續掃；失敗不能顯示完成。
                statusText = "匯出失敗：\(error.localizedDescription)。資料已保留，可重新匯出。"
                phase = returnPhase
            }
        }
    }

    /// review 發現破洞 → 回到掃描續拍（不 reset：保留地圖與錨點，ARKit 自動重新定位）
    func resumeScan() {
        guard phase == .review, arView != nil, writer != nil, !isInBackground else { return }
        if case .failed = sessionState {
            statusText = "相機追蹤已失效。請先匯出目前資料，再開始新掃描。"
            return
        }
        scanGeneration = UUID()
        scanNotice = nil
        reviewPoints = []
        reviewTrajectory = []
        floorPlanData = nil
        resumeTracking()
        // 刻意不 reset：續掃的這一段會成為「另一個房間」，最後由 StructureBuilder 合併成整層。
        // 一間一間掃再合併的精度也優於一鏡到底（一鏡到底會在門口累積漂移）。
        startFloorPlan(fresh: false)
        phase = .scanning
        startPreviewRendering()
        statusText = nil
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// 捨棄本次掃描：刪除資料、全新開始
    func discardScan() {
        guard phase == .review || phase == .done else { return }
        if let dir = sessionDir { try? FileManager.default.removeItem(at: dir) }
        if let zip = exportedZip { try? FileManager.default.removeItem(at: zip) }
        writer = nil
        accumulator = nil
        sessionDir = nil
        cleanupToIdle()
    }

    func togglePointCloud() {
        showPointCloud.toggle()
        visualizer?.setPointCloudHidden(!showPointCloud)
    }

    func toggleRoomPlan() {
        showRoomPlan.toggle()
        visualizer?.setRoomHidden(!showRoomPlan)
        visualizer?.setDollhouseHidden(!showRoomPlan)
    }

    /// 切換「真實顏色 / 融合品質熱圖」。切換後必須把所有磚標記重畫，
    /// 否則只有之後才變動的磚會換色、畫面兩種配色混在一起。
    func toggleColorMode() {
        colorMode = (colorMode == .rgb) ? .fusionQuality : .rgb
        Task { await accumulator?.markAllDirty() }
    }

    func resetForNewScan() {
        guard phase == .done || phase == .idle else { return }
        cleanupToIdle()
    }

    private func cleanupToIdle() {
        fusionCancel.cancel()
        if let processor = featureProcessor { Task { await processor.close() } }
        featureProcessor = nil
        pendingWrites = 0
        writeTasks = [:]
        previewInFlight = false
        previewRenderTask?.cancel()
        previewRenderTask = nil
        scanGeneration = UUID()
        needsSessionResume = false
        exportedZip = nil
        statusText = nil
        scanNotice = nil
        floorPlanData = nil
        showFloorPlan = false
        fusionCompleteness = 0
        scanSummary = nil
        previewMainTotalMS = 0
        previewMainMaxMS = 0
        assessedScanFrames = 0
        blockedScanFrames = 0
        imageReconstructionReport = nil
        loopHint = nil
        floorPlanHint = nil
        recentRejectCount = 0
        recentRejects = []
        frameCounter = 0
        lastPreviewFrame = -1
        lastSparseIntegration = 0
        lastSharpnessRejectTime = -.infinity
        pixelBufferPool = nil
        sessionDir = nil
        writer = nil
        accumulator = nil
        keyframeCount = 0
        pointCount = 0
        exportProgress = 0
        reviewPoints = []
        reviewTrajectory = []
        refinedRecords = []
        keyframeAnchors = [:]
        tileAnchorID = [:]
        tileKeyByAnchor = [:]
        latestTileTransforms = [:]
        visualizer?.reset()
        runSession()          // reset tracking（review/done 期間 session 已暫停）
        releaseCameraLocks()  // 回到 idle 恢復自動曝光/白平衡，方便取景
        monitor.start()
        phase = .idle
    }

    /// 讀取每個關鍵幀錨點的「目前」變換 —— ARKit 若做過地圖修正，值會與採集當下不同
    private func snapshotRefinedTransforms() -> [Int: [Double]] {
        guard let anchors = arView?.session.currentFrame?.anchors else { return [:] }
        var byID: [UUID: simd_float4x4] = [:]
        for anchor in anchors { byID[anchor.identifier] = anchor.transform }
        var out: [Int: [Double]] = [:]
        for (index, id) in keyframeAnchors {
            if let t = byID[id] { out[index] = MatrixUtil.rowMajor16(t) }
        }
        return out
    }

    /// 讀取 ARKit 場景重建網格的世界座標頂點（停止前呼叫，與姿態快照同一時機）。
    /// 注意：ARGeometrySource 的頂點是 packed float3（stride 12B），
    /// 不可直接 bind 成 SIMD3<Float>（Swift 的 SIMD3<Float> 佔 16B）—— 必須逐分量讀。
    private func snapshotMeshVertices() async -> [SIMD3<Float>] {
        guard hasLiDAR, config.useSceneMesh,
              let anchors = arView?.session.currentFrame?.anchors else { return [] }
        // Hold anchors, never an ARFrame. Sample the full scene with a fixed allocation cap.
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        let total = meshes.reduce(0) { $0 + $1.geometry.vertices.count }
        let limit = max(1, config.processingMeshMaxVertices)
        let step = RefusionEngine.meshSampleStride(vertexCount: total, limit: limit)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(min(total, limit))
        var offset = 0
        for mesh in meshes {
            guard isAttached, phase == .processing else { return [] }
            let src = mesh.geometry.vertices
            defer { offset += src.count }
            guard src.format == .float3, src.stride >= 12, src.offset >= 0,
                  src.count == 0 || src.offset + (src.count - 1) * src.stride + 12 <= src.buffer.length else { continue }
            let base = src.buffer.contents(), transform = mesh.transform
            let first = (step - offset % step) % step
            for i in stride(from: first, to: src.count, by: step) {
                let p = base.advanced(by: src.offset + i * src.stride)
                let x = p.loadUnaligned(as: Float.self)
                let y = p.loadUnaligned(fromByteOffset: 4, as: Float.self)
                let z = p.loadUnaligned(fromByteOffset: 8, as: Float.self)
                let w = transform * SIMD4<Float>(x, y, z, 1)
                if w.x.isFinite && w.y.isFinite && w.z.isFinite { out.append(SIMD3(w.x, w.y, w.z)) }
            }
            await Task.yield()
        }
        return out
    }

    private func beginSessionStorage() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date()) + "_" + UUID().uuidString.prefix(6)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("scans/scan_\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDir = dir

        writer = try FrameWriter(sessionDir: dir,
                                 saveDepth: config.saveDepth && hasLiDAR,
                                 jpegQuality: config.jpegQuality,
                                 denoiseISOThreshold: config.denoiseISOThreshold,
                                 denoiseMaxNoiseLevel: config.denoiseMaxNoiseLevel)
        accumulator = PointCloudAccumulator(config: config)

        let meta = SessionMeta(device: Self.deviceModel(),
                               osVersion: UIDevice.current.systemVersion,
                               startedAt: ISO8601DateFormatter().string(from: Date()),
                               mode: "scene",   // 物件模式已移除；欄位保留給既有資料集相容
                               lidarAvailable: supportsLiDAR,
                               lidarEnabled: hasLiDAR,
                               rgbReconstructionEnabled: !hasLiDAR && config.reconstructFromImages)
        try ExportManager.writeMeta(meta, to: dir.appendingPathComponent(CaptureMetadata.fileName))
    }

    /// 相機三鎖：對焦（內參穩定、AF 不拉風箱）、曝光（ISO/快門固定 → 亮度一致、
    /// 模糊可預測）、白平衡（色彩一致 → 融合不閃色、3DGS 訓練色彩乾淨）。
    /// 在使用者取景完成、按下快門的當下鎖定 —— AE/AF 已收斂於目標物。
    /// 開始掃描時鎖定相機參數。委派給 CameraControls —— 它只凍結「還在自動」的項目，
    /// 使用者手動指定過的（快門/ISO/白平衡/對焦）維持自訂值。
    /// 「預設鎖定」與「調整完再鎖」因此是同一條路徑，不會互相覆蓋。
    /// 平面圖摘要 ＋ 掃描完整度判斷。
    ///
    /// 這裡原本放的是「dimensions 軸序自我檢查」，已移除 —— 那個判斷是錯的：
    /// Apple 文件明確定義 Surface.dimensions 為 (width, height, depth)，假設本來就對。
    /// 實機上樓高 1.83m 的成因是牆只被掃到 1.83m 高，不是軸序（同一份程式在另一次
    /// 掃描樓高正常，軸序若相反不可能只錯一次）。那道檢查唯一的效果是對不完整的掃描說謊。
    private func logFloorPlan(_ fp: FloorPlanData) {
        print(String(format: "平面圖: %d 房、%d 牆、%d 門、%d 窗、%d 家具，外接 %.2f×%.2fm",
                     fp.roomCount, fp.walls.count, fp.doors.count,
                     fp.windows.count, fp.objects.count, fp.sizeM.x, fp.sizeM.y))
        guard !fp.walls.isEmpty else { return }
        print(String(format: "  牆長中位數 %.2fm、最長牆 %.2fm、樓高中位數 %.2fm",
                     fp.medianWallLengthM, fp.longestWallM, fp.medianWallHeightM))
        if let reason = fp.incompleteReason {
            print("  ⚠️ 掃描不完整：\(reason)")
        }
    }

    /// 使用者為房間命名。改動會一併進到匯出的 floorplan.json / .svg
    /// （writeFloorPlan 讀的就是 floorPlanData）。
    func renameRoom(at index: Int, to name: String) {
        guard var fp = floorPlanData, fp.rooms.indices.contains(index) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        fp.rooms[index].customLabel = trimmed.isEmpty ? nil : trimmed
        floorPlanData = fp
    }

    /// 平面圖三種輸出，各有各的用途，所以都寫：
    ///   floorplan.usdz — RoomPlan 原生，帶完整 3D 幾何與門窗語意，可直接進 CAD / BIM
    ///   floorplan.json — 參數化資料 ＋ 已投影到水平面的 2D 線段，給程式化後處理用
    ///   floorplan.svg  — 直接看得到的俯視平面圖（含 1m 網格、牆長標註、比例尺）
    /// 座標維持 ARKit 原生（+Y up、公尺），與 points.ply / poses.jsonl 一致；
    /// 匯出 COLMAP 用的世界翻轉**不**套用在這裡 —— 那是 3DGS 生態的慣例，平面圖不需要。
    private func writeFloorPlan(to dir: URL) async throws {
        // ── 點雲平面圖：不需要 RoomPlan，只要有掃到表面 ──
        //
        // 為什麼要有兩套：RoomPlan 是**房間**掃描器，它要有地板、成面的牆、
        // 牆與天花板的交界才給得出正確結構；在辦公室隔間、貨架、桌面前它會把
        // 螢幕邊桌緣硬判成牆，而且第一片判錯之後後續會跟著它對齊。
        // 點雲沒有這個前提。所以兩者各自輸出、互不覆蓋，
        // 使用者拿哪一份由現場決定，而不是由我事先猜。
        // RoomPlan 關掉時 floorPlanData 已經是點雲版（見 processScan / usePointCloudPlan），
        // 這裡不重算；只有它還空著（例如匯出比 review 早）才補一次。
        if floorPlanData == nil { await usePointCloudPlan() }

        if hasLiDAR, config.captureFloorPlan, FloorPlanCapture.isSupported {
            // 平面圖是背景建的（見 processScan），匯出時若還沒好就在這裡等 ——
            // 匯出是使用者明確要求的動作，少一個檔比多等幾秒糟。
            if floorPlanData == nil { floorPlanData = await floorPlan.build() }
            await floorPlan.exportUSDZ(to: dir.appendingPathComponent("floorplan.usdz"))
        }
        guard let fp = floorPlanData else { return }
        try writePlan(fp, to: dir, prefix: "floorplan")
    }

    /// 由已融合的點雲算出平面圖並填進 floorPlanData。
    ///
    /// 算一次就存著：review 的預覽、房間命名、匯出都吃同一份，
    /// 不然使用者看到的圖和匯出的圖可能不是同一張（點雲不會變，但重算沒有意義）。
    /// - source: 要拿哪一份點雲畫。手機共用受 exportMaxPoints 限制的融合結果，
    ///   不再額外要求數百萬點。大場景平面圖可能較稀疏，優先控制處理峰值。
    private func usePointCloudPlan(_ source: [CloudPoint]? = nil) async {
        let src = source ?? reviewPoints
        guard config.pointCloudFloorPlan, !src.isEmpty else { return }
        let generation = scanGeneration
        let result = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                PointCloudFloorPlan.extract(points: src.map { SIMD3<Float>($0.x, $0.y, $0.z) })
            }
        }.value
        guard isAttached, scanGeneration == generation else { return }
        guard let r = result else {
            print("點雲平面圖: 抽不出牆（點太少、或沒有垂直跨度足夠的表面）")
            return
        }
        print(r.summary)
        floorPlanData = r.plan
    }

    /// 一份平面圖的三種格式。
    ///   .json — 參數化資料 ＋ 已投影到水平面的 2D 線段，給程式化後處理用
    ///   .svg  — 直接看得到的俯視平面圖（含 1m 網格、牆長標註、比例尺）
    ///   .dxf  — 帶圖層的 CAD 圖元，AutoCAD / QCAD / Rhino 直接開，可量可續繪
    private func writePlan(_ fp: FloorPlanData, to dir: URL, prefix: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(fp).write(to: dir.appendingPathComponent("\(prefix).json"),
                                 options: [.atomic])
        let svg = fp.svg(showAllFurniture: showPlanFurniture)
        try Data(svg.utf8).write(to: dir.appendingPathComponent("\(prefix).svg"),
                                 options: [.atomic])
        try Data(FloorPlanDXF.make(fp).utf8)
            .write(to: dir.appendingPathComponent("\(prefix).dxf"), options: [.atomic])
    }

    /// 取出 ARKit 當下的地圖並存檔。必須在 session 還活著時呼叫。
    /// 追蹤狀態不佳時 ARKit 會拒絕給地圖（回 error）—— 那種地圖本來就不該留，
    /// 帶著它下次會一直重定位失敗。
    /// 非 Sendable 的 ARKit 物件單向交給背景。交出後 main 這邊不再碰它，
    /// 所以沒有共享可變狀態（與 Keyframe 的 pixelBuffer 同一個理由）。
    nonisolated private struct MapBox: @unchecked Sendable { let map: ARWorldMap }

    /// 從**活著的** session 取出當下地圖。只有這一步需要 session，所以取完就能 pause。
    private func captureWorldMap() async -> MapBox? {
        guard let session = arView?.session else { return nil }
        return await withCheckedContinuation { c in
            session.getCurrentWorldMap { m, error in
                if let error { print("[WorldMap] 取得失敗（追蹤品質不足？）: \(error)") }
                c.resume(returning: m.map(MapBox.init))
            }
        }
    }

    /// 序列化並寫檔。**必須離開 main actor。**
    ///
    /// 這是「按下停止之後的第一段乾等」的真正來源：ARWorldMap 動輒 10~40MB，
    /// NSKeyedArchiver 是 CPU 密集的同步呼叫，先前直接跑在 main actor 上 ——
    /// 不只擋住畫面，連重融合的進度條都動不了，於是使用者看到的是一段完全靜止的等待。
    /// 停止流程會等待它完成才開始重融合，避免大型資料同時佔用記憶體。
    private func persistWorldMap(_ box: MapBox) async {
        let dir = sessionDir
        let anchors = box.map.anchors.count
        let bytes = await Task.detached(priority: .utility) {
            autoreleasepool { WorldMapStore.save(box.map, sessionDir: dir) }
        }.value
        lastWorldMapMB = bytes.map { Double($0) / 1_048_576 }
        if let bytes {
            print(String(format: "世界地圖已保存 %.1f MB（%d 個錨點）—— 下次可選「延續上次座標系」",
                         Double(bytes) / 1_048_576, anchors))
        }
    }

    /// 迴環閉合追蹤。這是**降低漂移投報率最高**的一件事：ARKit 只有在認出
    /// 「我來過這裡」時才會做全域修正，把累積誤差攤回整條軌跡；
    /// 走一條開放路徑不回頭的話，誤差只會一路累積下去，而且不會有任何警告。
    /// 沒人會主動這樣做，所以必須提示。
    private func updateLoopClosure(_ frame: ARFrame) {
        let p = MatrixUtil.position(frame.camera.transform)
        guard let start = scanStartPosition else {
            scanStartPosition = p
            lastTravelPosition = p
            return
        }
        if let last = lastTravelPosition {
            let step = simd_distance(p, last)
            if step > 0.05 { traveledM += step; lastTravelPosition = p }   // 0.05m 門檻濾掉抖動
        }
        let fromStart = simd_distance(p, start)
        if traveledM >= config.loopHintTravelM, fromStart <= config.loopClosedRadiusM {
            if !loopClosed {
                loopClosed = true
                captureHaptic.impactOccurred()
            }
            loopHint = nil
        } else if !loopClosed, traveledM >= config.loopHintTravelM {
            loopHint = String(format: "已走 %.0f m —— 走回起點閉環，讓 ARKit 修正累積漂移",
                              traveledM)
        }
        // RoomPlan 的引導與牆高檢查。
        //
        // **為什麼在這裡同步而不是讓 HUD 直接讀 floorPlan**：SwiftUI 的
        // @ObservedObject 不會觀察巢狀的 ObservableObject，所以 controller.floorPlan
        // 改變時畫面不會更新。而這個專案沒有其他 Combine 訂閱，為了一個字串
        // 引入一套 publisher 管線不划算 —— 照 loopHint 既有的做法逐幀同步即可。
        // 只在值真的改變時寫入，否則每幀都會觸發一次 SwiftUI 更新。
        let fpHint = floorPlan.coachingHint
        if fpHint != floorPlanHint { floorPlanHint = fpHint }
    }

    /// 量化 ARKit 實際修正了多少漂移。
    /// 先前只數「有幾幀被改動」，但那不分「動了 1mm」和「動了 30cm」——
    /// 後者代表這次掃描漂移嚴重、幾何可信度低，使用者應該知道。
    private func reportDrift(raw: [FrameRecord], refined: [FrameRecord]) {
        var s = ScanSummary()
        s.keyframes = refined.count
        s.traveledM = Double(traveledM)
        s.loopClosed = loopClosed
        s.blurDropped = refined.filter { $0.blurVerdict == .drop }.count
        s.blurDemoted = refined.filter { $0.blurVerdict == .demote }.count
        s.worldMapMB = lastWorldMapMB
        s.baBeforePx = baResult?.residualsPx.first
        s.baAfterPx = baResult?.residualsPx.last
        // 這兩欄是為了讓摘要無法被誤讀：只有 baApplied 為真時，baAfterPx 才描述
        // 實際輸出；否則輸出的天花板是 baBeforePx，而 baHoldoutDelta 是「若套用會怎樣」。
        s.baApplied = config.baApplyPoses && !(baResult?.poses.isEmpty ?? true)
        s.baHoldoutDelta = baResult?.holdoutDelta
        defer { scanSummary = s }
        let byID = Dictionary(uniqueKeysWithValues: raw.map { ($0.id, $0.transform) })
        var deltas: [Double] = []
        for r in refined {
            guard let o = byID[r.id], o.count == 16, r.transform.count == 16 else { continue }
            let dx = r.transform[3] - o[3], dy = r.transform[7] - o[7], dz = r.transform[11] - o[11]
            deltas.append((dx * dx + dy * dy + dz * dz).squareRoot())
        }
        guard !deltas.isEmpty else { return }
        deltas.sort()
        let med = deltas[deltas.count / 2], worst = deltas[deltas.count - 1]
        s.driftMedianCm = med * 100
        s.driftMaxCm = worst * 100

        // 兩種修正的形狀完全不同，混為一談會誤導：
        //   累積漂移      中位數 ≪ 最大值（誤差沿軌跡累積，早期的幀幾乎沒動）
        //   重定位跳變    中位數 ≈ 最大值（整組幀一起位移，把世界對齊到舊地圖）
        // 實機出現過「中位數 34.3cm / 最大 34.4cm、只走了 0.9m」——
        // 那不是 38% 的漂移率，是開了「延續上次座標系」後 ARKit 重定位的全域對齊量。
        let uniform = worst > 0.02 && med / worst > 0.9
        if uniform {
            print(String(format: "全域重定位: 整組位姿一致位移 %.1f cm"
                         + "（中位數≈最大值 ⇒ 世界座標系被對齊到舊地圖，不是累積漂移）",
                         med * 100))
        } else {
            print(String(format: "漂移修正: 中位數 %.1f cm / 最大 %.1f cm（行走 %.1f m）",
                         med * 100, worst * 100, traveledM))
        }
        // 迴環只在「走得夠遠、本來就該閉環」時才值得提。
        // 走 0.9m 也印「未閉合」只是噪音 —— 那種距離根本無所謂閉不閉。
        if traveledM >= config.loopHintTravelM {
            print(loopClosed
                  ? "  迴環已閉合 —— ARKit 有機會做全域修正"
                  : "  ⚠️ 走了 \(Int(traveledM))m 但沒有回到起點，"
                    + "ARKit 沒有機會做全域修正，遠端的累積誤差留在資料裡了")
        }
    }

    /// 開始一段平面圖擷取。fresh = 全新掃描（清空累積）；否則累積成另一個房間。
    private func startFloorPlan(fresh: Bool) {
        guard hasLiDAR, config.captureFloorPlan, FloorPlanCapture.isSupported,
              let session = arView?.session else { return }
        if fresh {
            floorPlan.reset()
            floorPlanData = nil
        }
        floorPlan.start(on: session)
    }

    private func applyCameraLocks() { cameraControls.lockForScan() }

    private func releaseCameraLocks() { cameraControls.unlock() }

    nonisolated private static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

// MARK: - ARSessionDelegate（主執行緒回呼）

extension CaptureController: @preconcurrency ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isAttached, !isInBackground, phase == .idle || phase == .scanning else { return }
        if case .failed = sessionState { return }
        frameCounter += 1

        let normalTracking: Bool
        if case .normal = frame.camera.trackingState { normalTracking = true } else { normalTracking = false }
        let continuous = normalTracking && poseContinuity.accepts(frame.camera.transform, timestamp: frame.timestamp)
        if !continuous {
            trackingStability.reset()
            if !normalTracking { poseContinuity.reset() }
            sparseTrackingEpoch += 1
        }
        var a = monitor.assess(frame: frame, config: config, useLiDAR: hasLiDAR)
        if !continuous {
            if !a.issues.contains(.trackingLost) { a.issues.append(.trackingLost) }
            a.captureBlocked = true
            a.blockReason = .tracking
            // assess 也會保存當前姿態；在其後清除，避免異常姿態污染下一幀速度。
            monitor.resetTrackingHistory()
        }
        // UI 每 6 幀（~0.1s）更新一次即可，避免 60Hz 重繪
        if frameCounter % 6 == 0 { assessment = a }
        let nextState: CaptureSessionState
        switch frame.camera.trackingState {
        case .normal:
            let stable = trackingStability.accepts(isNormal: continuous, timestamp: frame.timestamp)
            nextState = stable ? .ready : (sessionState == .relocalizing ? .relocalizing : .initializing)
        case .limited(.relocalizing): nextState = .relocalizing
        case .limited(.initializing): nextState = .initializing
        default: nextState = .limited
        }
        if case .normal = frame.camera.trackingState { } else { trackingStability.reset() }
        if sessionState != nextState { sessionState = nextState }
        guard phase == .scanning else { return }
        assessedScanFrames += 1
        if a.captureBlocked || !sessionState.canCapture { blockedScanFrames += 1 }
        if ProcessInfo.processInfo.thermalState == .critical {
            scanNotice = "裝置過熱，已停止掃描並保留資料。請等手機降溫後再繼續。"
            stopScan()
            return
        }
        guard sessionState.canCapture else { return }

        // 遮斷級警告觸覺回饋（限流 1 次 / 1.5 秒）
        if a.showsBlockingWarning, frame.timestamp - lastWarningHaptic > 1.5 {
            warningHaptic.notificationOccurred(.warning)
            lastWarningHaptic = frame.timestamp
        }

        updateLoopClosure(frame)
        // 掉幀率：只留近 4 秒。連續掉幀代表使用者正在流失資料而不自知
        recentRejects.removeAll { frame.timestamp - $0 > 4 }
        if recentRejectCount != recentRejects.count { recentRejectCount = recentRejects.count }

        // ARKit 修正了磚錨點（漂移校正/重定位）→ 更新快照並讓點雲磚跟著實體表面移動（防殘影）
        if !tileKeyByAnchor.isEmpty {
            var current: [Int64: simd_float4x4] = [:]
            current.reserveCapacity(tileKeyByAnchor.count)
            for anchor in frame.anchors {
                if let key = tileKeyByAnchor[anchor.identifier] { current[key] = anchor.transform }
            }
            latestTileTransforms = current
            visualizer?.syncTileTransforms(current)
        }

        // 點雲連續融合（~10Hz，與快門解耦）：只收「姿態可靠 + 清晰 + 相機夠穩」的幀。
        // 追蹤丟失/模糊（captureBlocked, blurPixels）+ 相機速度閘門（angular/linear）三管齊下：
        // 移動過快時姿態延遲/誤差大 → 深度投影到錯位的世界座標 → 點不貼合表面且出殘影，故直接跳過。
        // 取樣用「距上次融合隔了幾幀」而不是 frameCounter % N：
        // 取模的話，被抽中的那一幀只要剛好稍微糊一點或轉快一點，
        // **整個 0.1 秒的窗就整個丟掉**，要再等下一個倍數。
        // 改成隔夠久就試，沒過就下一幀再試 —— 一有合格的幀立刻補上。
        if frameCounter - lastPreviewFrame >= config.previewFrameInterval,
           a.allowCapture {
            integratePreview(frame, blurPixels: a.blurPixels)
        }

        // Dollhouse 擺位：**每幀**都要更新，不能像上面那樣抽幀 ——
        // 它跟著視線走，抽幀會看起來一頓一頓的。內容只是一次 transform 賦值，
        // 真正的重建是在 onRoomUpdated 那裡（節流 0.2s）。
        //
        // 用 pointOfView 而不是 frame.camera.transform：後者的座標系與介面方向無關
        // （X 軸沿裝置長軸、Y 軸是 landscapeRight 的「上」），直向 App 拿它當
        // 「下方」會偏到螢幕左邊。pointOfView 已經套過介面方向。
        if showRoomPlan, let pov = arView?.pointOfView {
            visualizer?.placeDollhouse(pov: pov.simdWorldTransform)
        }

        guard a.allowCapture else {
            if a.blockReason == .focus,
               frame.timestamp - lastSharpnessRejectTime >= config.minKeyframeInterval,
               shutter.isDue(pose: frame.camera.transform, time: frame.timestamp, config: config,
                             cameraOnly: !hasLiDAR, estimatedDepth: a.centerDepthM > 0 ? a.centerDepthM : nil) {
                lastSharpnessRejectTime = frame.timestamp
                sharpnessRejects += 1
                recentRejects.append(frame.timestamp)
            }
            return
        }
        guard shutter.isDue(pose: frame.camera.transform,
                                    time: frame.timestamp,
                                    config: config, cameraOnly: !hasLiDAR,
                                    estimatedDepth: a.centerDepthM > 0 ? a.centerDepthM : nil) else { return }
        capturePerformance.photoCandidates += 1
        guard pendingWrites < config.maxPendingWrites else {
            capturePerformance.writerBackpressureFrames += 1
            return
        }
        // 合格關鍵幀亦嘗試進入預覽；已有背景融合時保持背壓，下一個合格幀重試。
        if frameCounter != lastPreviewFrame {
            integratePreview(frame, blurPixels: a.blurPixels)
        }
        captureKeyframe(frame, assessment: a)
    }

    /// 擷取時只複製自有 buffer；actor 處理驗證與融合，渲染由獨立排程更新。
    private func integratePreview(_ frame: ARFrame, blurPixels: Float) {
        guard let accumulator, !previewInFlight else { return }
        let anchorSnapshot = latestTileTransforms
        let generation = scanGeneration
        if pixelBufferPool == nil {
            let src = frame.capturedImage
            pixelBufferPool = PixelBufferUtil.makePool(
                width: CVPixelBufferGetWidth(src),
                height: CVPixelBufferGetHeight(src),
                pixelFormat: CVPixelBufferGetPixelFormatType(src))
        }
        if hasLiDAR {
            guard let pool = pixelBufferPool,
                  let packet = PointExtractor.makePacket(frame: frame, pool: pool,
                                                         blurPixels: blurPixels, trackingEpoch: sparseTrackingEpoch) else { return }
            lastPreviewFrame = frameCounter
            previewInFlight = true
            previewTask = Task {
                await accumulator.integrate(packet, anchorTransforms: anchorSnapshot)
                if self.scanGeneration == generation { self.previewInFlight = false }
            }
        } else if frame.timestamp - lastSparseIntegration >= config.sparseSampleIntervalS,
                  let pool = pixelBufferPool,
                  let packet = PointExtractor.makeSparsePacket(frame: frame, pool: pool, epoch: sparseTrackingEpoch) {
            lastSparseIntegration = frame.timestamp
            lastPreviewFrame = frameCounter
            previewInFlight = true
            previewTask = Task {
                await accumulator.integrateSparse(packet, anchorTransforms: anchorSnapshot)
                if self.scanGeneration == generation { self.previewInFlight = false }
            }
        }
    }

    /// Render work continues at a bounded cadence even when quality gates reject new frames.
    /// Fusion never waits for SceneKit geometry creation and failed capture attempts do not
    /// consume the next sampling interval.
    private func startPreviewRendering() {
        previewRenderTask?.cancel()
        guard let accumulator else { return }
        let generation = scanGeneration
        let interval = UInt64(config.previewRenderIntervalS * 1_000_000_000)
        previewRenderTask = Task { [weak self] in
            await accumulator.markAllDirty()
            while !Task.isCancelled {
                guard let self, self.phase == .scanning, self.isAttached,
                      !self.isInBackground, self.scanGeneration == generation else { return }
                let batch = await accumulator.nextRenderBatch(pointBudget: self.config.previewRenderPointBudget,
                                                               mode: self.colorMode)
                guard !Task.isCancelled, self.phase == .scanning,
                      self.scanGeneration == generation else { return }
                self.applyPreviewBatch(batch)
                await accumulator.acknowledgeRenderAnchors(batch.anchors.map { $0.0 })
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
            }
        }
    }

    private func applyPreviewBatch(_ batch: PointCloudAccumulator.RenderBatch) {
        let started = Date()
        defer {
            if !batch.tiles.isEmpty {
                let milliseconds = Date().timeIntervalSince(started) * 1000
                previewMainTotalMS += milliseconds
                previewMainMaxMS = max(previewMainMaxMS, milliseconds)
            }
        }
        for (key, center) in batch.anchors where tileAnchorID[key] == nil {
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4<Float>(center.x, center.y, center.z, 1)
            if let session = arView?.session {
                let anchor = ARAnchor(name: "tile", transform: t)
                session.add(anchor: anchor)
                tileAnchorID[key] = anchor.identifier
                tileKeyByAnchor[anchor.identifier] = key
            }
            latestTileTransforms[key] = t
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        SCNTransaction.disableActions = true
        for tile in batch.tiles {
            let xform = latestTileTransforms[tile.key]
                ?? { var m = matrix_identity_float4x4
                     m.columns.3 = SIMD4<Float>(tile.center.x, tile.center.y, tile.center.z, 1)
                     return m }()
            visualizer?.updateTile(tile, transform: xform)
        }
        SCNTransaction.commit()
        if pointCount != batch.pointCount { pointCount = batch.pointCount }
        if abs(fusionCompleteness - batch.completeness) > 0.005 { fusionCompleteness = batch.completeness }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        trackingStability.reset()
        poseContinuity.reset()
        sparseTrackingEpoch += 1
        guard phase == .idle || phase == .scanning else { return }
        sessionState = .interrupted
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard isAttached, !isInBackground, phase == .idle || phase == .scanning else { return }
        sessionState = .relocalizing
        monitor.start()
        shutter.reset()
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func session(_ session: ARSession, didFailWithError error: Error) {
        sessionState = .failed(error.localizedDescription)
        if phase == .scanning {
            scanNotice = "相機追蹤中斷，已停止掃描並保留資料。匯出後請開始新掃描。"
            stopScan()
        }
    }

    private func captureKeyframe(_ frame: ARFrame, assessment a: QualityAssessment) {
        guard let writer else { return }
        let src = frame.capturedImage
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        if pixelBufferPool == nil {
            pixelBufferPool = PixelBufferUtil.makePool(width: w, height: h,
                                                       pixelFormat: CVPixelBufferGetPixelFormatType(src))
        }
        guard let pool = pixelBufferPool,
              let copy = PixelBufferUtil.clone(src, pool: pool) else {
            capturePerformance.imageCopyFailures += 1
            return
        }

        // 深度 / 信心圖 → 緊湊 Data（float32 / uint8 raw）
        var depthData: Data?
        var confData: Data?
        var dw = 0, dh = 0
        if hasLiDAR, config.saveDepth, let sceneDepth = frame.sceneDepth {
            dw = CVPixelBufferGetWidth(sceneDepth.depthMap)
            dh = CVPixelBufferGetHeight(sceneDepth.depthMap)
            depthData = PixelBufferUtil.tightData(sceneDepth.depthMap, bytesPerPixel: 4)
            confData = sceneDepth.confidenceMap.map { PixelBufferUtil.tightData($0, bytesPerPixel: 1) }
        }

        let camera = frame.camera
        let K = camera.intrinsics
        frameIndex += 1
        let name = String(format: "frame_%05d", frameIndex)

        let record = FrameRecord(
            id: frameIndex,
            timestamp: frame.timestamp,
            transform: MatrixUtil.rowMajor16(camera.transform),
            intrinsics: CameraIntrinsics(fx: Double(K[0][0]), fy: Double(K[1][1]),
                                         cx: Double(K[2][0]), cy: Double(K[2][1]),
                                         width: w, height: h),
            exposureDuration: camera.exposureDuration,
            exposureOffsetEV: Double(camera.exposureOffset),
            iso: cameraControls.currentISO,
            ambientLux: frame.lightEstimate.map { Double($0.ambientIntensity) },
            estimatedBlurPx: Double(a.blurPixels),
            sharpness: Double(a.sharpness),
            sharpnessRatio: Double(a.sharpnessRatio),
            imageFile: name + ".jpg",
            depthFile: depthData != nil ? name + "_depth.bin" : nil,
            confidenceFile: confData != nil ? name + "_conf.bin" : nil,
            depthWidth: depthData != nil ? dw : nil,
            depthHeight: depthData != nil ? dh : nil)

        let keyframe = Keyframe(pixelBuffer: copy,
                                depthData: depthData,
                                confidenceData: confData,
                                depthWidth: dw, depthHeight: dh,
                                c2w: camera.transform,
                                record: record)

        // 掛錨點：ARKit 後續的地圖優化會調整它，停止時讀回 = 修正後姿態
        if let session = arView?.session {
            let anchor = ARAnchor(name: name, transform: camera.transform)
            session.add(anchor: anchor)
            keyframeAnchors[frameIndex] = anchor.identifier
        }

        pendingWrites += 1
        capturePerformance.maximumPendingWrites = max(capturePerformance.maximumPendingWrites, pendingWrites)

        // Only consume the viewpoint after buffer ownership and write scheduling are secured.
        shutter.markCaptured(pose: frame.camera.transform, time: frame.timestamp)
        let processor = featureProcessor
        let generation = scanGeneration
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        writeTasks[record.id] = Task {
            defer {
                if generation == scanGeneration {
                    pendingWrites -= 1
                    writeTasks[record.id] = nil
                }
            }
            do {
                let timing = try await writer.write(keyframe, enqueuedAt: enqueuedAt)
                guard generation == scanGeneration, isAttached else { return }
                capturePerformance.savedPhotos += 1
                capturePerformance.writeQueueTotalMS += timing.queueMS
                capturePerformance.writeQueueMaxMS = max(capturePerformance.writeQueueMaxMS, timing.queueMS)
                capturePerformance.jpegTotalMS += timing.jpegMS
                capturePerformance.jpegMaxMS = max(capturePerformance.jpegMaxMS, timing.jpegMS)
                capturePerformance.fileWriteTotalMS += timing.fileWriteMS
                capturePerformance.fileWriteMaxMS = max(capturePerformance.fileWriteMaxMS, timing.fileWriteMS)
                keyframeCount += 1
                visualizer?.addKeyframe(pose: keyframe.c2w)
                if phase == .scanning { captureHaptic.impactOccurred(intensity: 0.6) }
            } catch {
                guard generation == scanGeneration, isAttached else { return }
                if let id = keyframeAnchors.removeValue(forKey: record.id),
                   let anchor = arView?.session.currentFrame?.anchors.first(where: { $0.identifier == id }) {
                    arView?.session.remove(anchor: anchor)
                }
                scanNotice = "影像儲存失敗：\(error.localizedDescription)。已停止掃描，先前成功儲存的資料仍保留。"
                stopScan()
                return
            }
            // Submission returns immediately even while matching is busy; only the newest
            // pending frame is retained. BA observes the subset, while all photos remain saved.
            if keyframe.depthData != nil { await processor?.submit(keyframe) }
        }
    }
}
