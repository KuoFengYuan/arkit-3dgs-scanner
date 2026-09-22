//
//  PointCloudAccumulator.swift
//  fable — LiDAR 點雲：擷取（PointExtractor）＋ 品質導向累積（actor）
//
//  主執行緒只複製自有 buffer；深度驗證、加權融合及渲染資料打包皆在 actor。
//  幾何融合約 10Hz；FIFO 預覽批次由獨立排程取走，資料不足／抓幀暫停不會卡住待更新磚。
//  voxel 加權平均與容量粗化保留，跨影格深度檢查先排除不一致樣本。
//

import Foundation
import ARKit
import CoreVideo
import simd

// MARK: - 擷取（回呼內只做 memcpy，數學在 actor 執行緒）
//
// 重要教訓：反投影/融合若跑在 session delegate 回呼（主執行緒），
// Debug 組建下每次 10ms+ 會餓死 ARKit 的 VIO → 掉幀 → 追蹤不穩與漂移。
// 因此拆成兩段：makePacket（主執行緒，純 buffer 複製 ~2ms）→ extract（actor，計算）。

nonisolated enum PointExtractor {

    /// 跨執行緒的一幀融合封包：深度/信心為緊湊複本、影像為自有 pool 的 YUV 副本
    struct FramePacket: @unchecked Sendable {
        let depth: Data
        let confidence: Data?
        let yuv: CVPixelBuffer
        let depthWidth: Int
        let depthHeight: Int
        let intrinsics: CameraIntrinsics      // 全解析度
        let c2w: simd_float4x4
        let blurPixels: Float
        let timestamp: Double
        let trackingEpoch: Int
    }

    struct SparsePacket: @unchecked Sendable {
        let points: [SIMD3<Float>]
        let identifiers: [UInt64]
        let yuv: CVPixelBuffer
        let intrinsics: CameraIntrinsics
        let c2w: simd_float4x4
        let timestamp: Double
        let trackingEpoch: Int
    }

    static func makeSparsePacket(frame: ARFrame, pool: CVPixelBufferPool, epoch: Int) -> SparsePacket? {
        guard let cloud = frame.rawFeaturePoints,
              let copy = PixelBufferUtil.clone(frame.capturedImage, pool: pool) else { return nil }
        let k = frame.camera.intrinsics
        let size = frame.camera.imageResolution
        return SparsePacket(points: cloud.points, identifiers: cloud.identifiers, yuv: copy,
                            intrinsics: CameraIntrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]),
                                                         cx: Double(k[2][0]), cy: Double(k[2][1]),
                                                         width: Int(size.width), height: Int(size.height)),
                            c2w: frame.camera.transform, timestamp: frame.timestamp, trackingEpoch: epoch)
    }

    /// 主執行緒：只做 buffer 複製（memcpy 為記憶體頻寬受限，不受最佳化等級影響）
    static func makePacket(frame: ARFrame, pool: CVPixelBufferPool,
                           blurPixels: Float, trackingEpoch: Int) -> FramePacket? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        guard dw > 0, dh > 0,
              let clone = PixelBufferUtil.clone(frame.capturedImage, pool: pool) else { return nil }
        let K = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        return FramePacket(
            depth: PixelBufferUtil.tightData(depthMap, bytesPerPixel: 4),
            confidence: sceneDepth.confidenceMap.map { PixelBufferUtil.tightData($0, bytesPerPixel: 1) },
            yuv: clone,
            depthWidth: dw,
            depthHeight: dh,
            intrinsics: CameraIntrinsics(fx: Double(K[0][0]), fy: Double(K[1][1]),
                                         cx: Double(K[2][0]), cy: Double(K[2][1]),
                                         width: Int(res.width), height: Int(res.height)),
            c2w: frame.camera.transform,
            blurPixels: blurPixels, timestamp: frame.timestamp, trackingEpoch: trackingEpoch)
    }

    /// actor 執行緒：反投影 + 信心/範圍/飛點過濾 + 品質評分
    static func extract(_ packet: FramePacket, config: CaptureConfig, sampling: (stride: Int, x: Int, y: Int)? = nil) -> [CloudPoint] {
        let dw = packet.depthWidth
        let dh = packet.depthHeight
        let K = packet.intrinsics.scaled(toWidth: dw, height: dh)
        let fx = Float(K.fx), fy = Float(K.fy), cx = Float(K.cx), cy = Float(K.cy)
        let c2w = packet.c2w
        let conf = packet.confidence.map { [UInt8]($0) }
        let sampler = YUVSampler(packet.yuv)
        defer { sampler.unlock() }

        let stride = max(1, sampling?.stride ?? config.depthSampleStride)
        let minD = config.pointMinDepthM
        let maxD = config.pointMaxDepthM
        let minConf = config.minDepthConfidence
        let sharpness = RefusionEngine.blurWeight(packet.blurPixels, config)
        // medium 信心深度降權（與重融合同一組參數，兩邊的覆蓋判定才一致 ——
        // 預覽熱圖必須 ⊇ 重融合實際會用到的，否則熱圖會把已經夠的地方標成缺）
        let mediumW = config.mediumConfidenceWeight

        return packet.depth.withUnsafeBytes { raw -> [CloudPoint] in
            let d = raw.bindMemory(to: Float32.self)
            var out: [CloudPoint] = []
            out.reserveCapacity((dw / stride) * (dh / stride))
            var v = sampling?.y ?? 0
            while v < dh {
                var u = sampling?.x ?? 0
                while u < dw {
                    let i = v * dw + u
                    let z = d[i]
                    let cv = conf?[i] ?? 2
                    if z.isFinite, z > minD, z < maxD, cv >= minConf {
                        if let incidence = DepthSampleFilter.incidenceWeight(
                            depth: d, confidence: conf, u: u, v: v, width: dw, height: dh,
                            K: K, config: config) {
                            // CV 反投影 → 翻 Y/Z 回 GL 相機系 → 世界
                            let xc = (Float(u) - cx) / fx * z
                            let yc = (Float(v) - cy) / fy * z
                            let w4 = c2w * SIMD4<Float>(xc, -yc, -z, 1)
                            let (r, g, b) = sampler.rgb(atNormalizedU: (Float(u) + 0.5) / Float(dw),
                                                        v: (Float(v) + 0.5) / Float(dh))
                            // 品質分數：畫面中心 × 近距離 × 清晰幀
                            let ru = (Float(u) - cx) / Float(dw)
                            let rv = (Float(v) - cy) / Float(dh)
                            let central = 1 - min(1, (ru * ru + rv * rv).squareRoot() * 1.4) * 0.5
                            let near = 1 / (0.2 + z * z)
                            out.append(CloudPoint(x: w4.x, y: w4.y, z: w4.z, r: r, g: g, b: b,
                                                  score: central * near * sharpness
                                                         * (cv >= 2 ? 1 : mediumW) * incidence))
                        }
                    }
                    u += stride
                }
                v += stride
            }
            return out
        }
    }
}

// MARK: - 累積 actor

actor PointCloudAccumulator {

    private var sparseFilter = SparseLandmarkFilter()
    private var temporalDepth = TemporalDepthConsistency()
    private var performance = PreviewPerformanceReport()
    func performanceReport() -> PreviewPerformanceReport { performance }
    private var grid: TiledFusedGrid
    private let config: CaptureConfig
    private var samplingBudget: PreviewSamplingBudget

    init(config: CaptureConfig) {
        self.config = config
        samplingBudget = PreviewSamplingBudget(minimumStride: config.depthSampleStride,
            maximumStride: config.previewMaxSampleStride, targetMS: config.previewIntegrationBudgetMS,
            maximumSamples: config.previewMaxCandidates)
        grid = TiledFusedGrid(voxelSize: config.voxelSizeM,
                              tileSize: config.previewTileSizeM,
                              maxCells: config.maxPoints)
    }

    var count: Int { grid.count }
    var fusionCompleteness: Double { grid.fusionCompleteness }

    /// 反投影 + 過濾 + 融合（全部在 actor 執行緒，不佔 delegate 回呼）。
    /// anchorTransforms：各磚錨點當下變換（主執行緒每幀擷取），用於世界↔局部換算。
    func integrate(_ packet: PointExtractor.FramePacket,
                   anchorTransforms: [Int64: simd_float4x4]) {
        let camPos = SIMD3<Float>(packet.c2w.columns.3.x, packet.c2w.columns.3.y,
                                  packet.c2w.columns.3.z)
        let started = ProcessInfo.processInfo.systemUptime
        let sampling = samplingBudget.next(width: packet.depthWidth, height: packet.depthHeight)
        performance.maximumSampleStride = max(performance.maximumSampleStride, sampling.stride)
        var points = PointExtractor.extract(packet, config: config, sampling: sampling)
        let extractedAt = ProcessInfo.processInfo.systemUptime
        performance.extractionTotalMS += (extractedAt - started) * 1000
        performance.candidatePoints += points.count
        if config.depthConsistencyEnabled {
            guard let view = DepthConsistencyView(depth: packet.depth,
                    confidence: packet.confidence.map { [UInt8]($0) },
                    intrinsics: packet.intrinsics.scaled(toWidth: packet.depthWidth, height: packet.depthHeight),
                    c2w: packet.c2w) else { return }
            points = temporalDepth.filter(points, view: view, timestamp: packet.timestamp,
                                          epoch: packet.trackingEpoch, config: config)
        }
        let filteredAt = ProcessInfo.processInfo.systemUptime
        performance.consistencyTotalMS += (filteredAt - extractedAt) * 1000
        grid.insert(points, anchorTransforms: anchorTransforms, cameraPosition: camPos)
        let insertedAt = ProcessInfo.processInfo.systemUptime
        performance.gridInsertTotalMS += (insertedAt - filteredAt) * 1000
        performance.integratedFrames += 1
        performance.acceptedPoints += points.count
        let milliseconds = (insertedAt - started) * 1000
        samplingBudget.record(milliseconds: milliseconds)
        if milliseconds > config.previewIntegrationBudgetMS { performance.overBudgetFrames += 1 }
        performance.integrationTotalMS += milliseconds
        performance.integrationMaxMS = max(performance.integrationMaxMS, milliseconds)
    }

    /// 稀疏特徵先經 ID、跨視角與時間穩定檢查，再以當張 RGB 上色；同一 ID 只融入一次。
    func integrateSparse(_ packet: PointExtractor.SparsePacket, anchorTransforms: [Int64: simd_float4x4]) {
        guard packet.points.count == packet.identifiers.count else { return }
        let inverse = packet.c2w.inverse
        let camera = SIMD3<Float>(packet.c2w.columns.3.x, packet.c2w.columns.3.y, packet.c2w.columns.3.z)
        let sampler = YUVSampler(packet.yuv)
        defer { sampler.unlock() }
        var points: [CloudPoint] = []
        for (id, position) in zip(packet.identifiers, packet.points) {
            guard let pixel = CameraOnlyGeometry.project(position, worldToCamera: inverse,
                                                         intrinsics: packet.intrinsics,
                                                         minDepth: config.pointMinDepthM, maxDepth: config.pointMaxDepthM),
                  sparseFilter.accept(id: id, position: position, camera: camera,
                                      time: packet.timestamp, epoch: packet.trackingEpoch, config: config) else { continue }
            let (r, g, b) = sampler.rgb(atNormalizedU: pixel.u / Float(packet.intrinsics.width),
                                        v: pixel.v / Float(packet.intrinsics.height))
            points.append(CloudPoint(x: position.x, y: position.y, z: position.z, r: r, g: g, b: b,
                                     score: 1 / (0.2 + pixel.depth * pixel.depth)))
        }
        grid.insert(points, anchorTransforms: anchorTransforms, cameraPosition: camera)
    }

    struct RenderBatch: Sendable {
        let anchors: [(Int64, SIMD3<Float>)]
        let tiles: [TileRenderData]
        let pointCount: Int
        let completeness: Double
    }

    /// One actor hop packages a bounded FIFO batch independently of camera acceptance.
    func nextRenderBatch(pointBudget: Int, mode: PointColorMode) -> RenderBatch {
        let started = Date()
        performance.peakPendingTiles = max(performance.peakPendingTiles, grid.pendingRenderTileCount)
        let anchors = grid.pendingAnchorSnapshot()
        let tiles = grid.popDirtyTiles(limit: 8, pointBudget: pointBudget).compactMap { grid.tileRenderData($0, mode: mode) }
        if !tiles.isEmpty {
            performance.renderBatches += 1
            performance.renderedTiles += tiles.count
            let milliseconds = Date().timeIntervalSince(started) * 1000
            performance.packingTotalMS += milliseconds
            performance.packingMaxMS = max(performance.packingMaxMS, milliseconds)
        }
        return RenderBatch(anchors: anchors, tiles: tiles, pointCount: grid.count, completeness: grid.fusionCompleteness)
    }

    func acknowledgeRenderAnchors(_ keys: [Int64]) { grid.acknowledgeAnchors(keys) }

    /// 取走待建錨磚（主執行緒據此建立 ARAnchor）
    func takePendingAnchors() -> [(Int64, SIMD3<Float>)] {
        grid.takePendingAnchors()
    }

    /// 取出至多 limit 個待刷新磚的 GPU-ready 渲染資料
    func dirtyTileRenderData(limit: Int, mode: PointColorMode = .rgb) -> [TileRenderData] {
        grid.popDirtyTiles(limit: limit).compactMap { grid.tileRenderData($0, mode: mode) }
    }

    /// 切換上色模式後呼叫：把所有磚標記為待重畫（否則只有之後變動的磚會換色）
    func markAllDirty() { grid.markAllDirty() }

    func prepareForOfflineFusion(limit: Int) {
        grid.trimForProcessing(limit: limit)
        temporalDepth = TemporalDepthConsistency()
    }

    func checkpointPoints(limit: Int, anchorTransforms: [Int64: simd_float4x4]) -> [CloudPoint] {
        grid.updateAnchorTransforms(anchorTransforms)
        return grid.checkpointPoints(limit: limit)
    }

    /// 匯出用擇優下採樣（無 LiDAR 時的備援輸出；LiDAR 路徑以 RefusionEngine 重融合為準）
    func bestPoints(target: Int, anchorTransforms: [Int64: simd_float4x4] = [:]) -> [CloudPoint] {
        grid.updateAnchorTransforms(anchorTransforms)
        return grid.exportPoints(target: target)
    }
}
