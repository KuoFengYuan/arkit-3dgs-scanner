//
//  PointCloudFusion.swift
//  fable — 錨點相對的空間磚化加權融合格（防漂移殘影核心）
//
//  刻意不依賴 ARKit：純 simd 幾何，可在 macOS 上以合成漂移做單元驗證
//  （見 tools/check harness 的 no-ghost 測試）。
//

import Foundation
import simd

/// 一塊空間磚的渲染資料（actor 端打包完成，主執行緒只做 O(1) 包裝）。
/// positions 為「錨點局部座標」，渲染時由節點變換（= 該磚錨點當下變換）帶回世界。
/// 預覽點雲的上色模式。
/// 掃描當下使用者最需要知道的不是「顏色對不對」，而是「這塊融合夠了沒、要不要再繞一次」。
nonisolated enum PointColorMode: Sendable {
    case rgb            // 真實顏色
    case fusionQuality  // 融合品質熱圖（紅＝觀測不足，綠＝已充分）
}

nonisolated struct TileRenderData: Sendable {
    let key: Int64
    let center: SIMD3<Float>
    let count: Int
    let positions: Data   // float3（錨點局部座標）
    let colors: Data      // float3（0-1）
    let indices: Data     // int32
}

/// Coalesce updates while preserving arrival order: frequently touched tiles cannot starve others.
nonisolated struct DirtyTileQueue {
    private var queue: [Int64] = []
    private var head = 0
    private var members: Set<Int64> = []
    var count: Int { members.count }
    var first: Int64? { head < queue.count ? queue[head] : nil }
    mutating func insert(_ key: Int64) {
        if members.insert(key).inserted { queue.append(key) }
    }
    mutating func popFirst() -> Int64? {
        guard head < queue.count else { return nil }
        let key = queue[head]; head += 1; members.remove(key)
        if head == queue.count { queue.removeAll(keepingCapacity: true); head = 0 }
        else if head >= 1024 && head * 2 >= queue.count { queue.removeFirst(head); head = 0 }
        return key
    }
}

// MARK: - 錨點相對的空間磚化加權融合格
//
// 每個空間磚綁定一個 ARAnchor。cell 的位置存在「該磚錨點的局部座標系」，
// 融合、去重、渲染全部在局部系進行：
//   - 世界座標會因 ARKit 漂移/重定位而變動，但「相機相對於鄰近錨點」的局部關係不變，
//     故同一實體表面永遠映到同一局部 voxel → 重掃時去重合併，不再產生第二份點（殘影）。
//   - 錨點被 ARKit 修正時，整磚點雲隨節點剛體移動，貼緊實體表面。
// 換算需要錨點「當下」的變換，由主執行緒每幀擷取後隨封包傳入。
nonisolated struct TiledFusedGrid {

    struct Tile {
        var cells: [Int64: FusedVoxelGrid.Cell] = [:]   // 鍵為「局部」voxel
        let center: SIMD3<Float>                      // 建錨當下的世界中心，ID 不再代表目前位置
        var originLatest: simd_float4x4                 // 最近一次換算所用的錨點變換
        /// 視角格（局部 10 cm）→ 觀測方向的跨度；熱圖與完成度都讀這裡。
        var views: [Int64: ViewSpan] = [:]
    }

    /// 一塊表面被看過的「角度範圍」：目前相距最遠的兩個觀測方向（點 → 相機，單位向量）。
    ///
    /// **為什麼不用方位分格。** 先前把方向量化成世界方位 8 格 × 仰角 2 格、湊滿 3 格算充分：
    /// 相機只移 1° 剛好跨過格線就多算一格，在同一格內移 40° 卻仍是一格；
    /// 仰角只分俯視與否，上下移動幾乎看不到。這裡直接量兩兩夾角的最大值（以兩端點近似），
    /// 方位與仰角一視同仁，也沒有格線。
    ///
    /// **為什麼是 10 cm 而不是每個 1 cm voxel。** 深度雜訊會把同一表面的點散到相鄰 voxel，
    /// 每格只分到少數視角而偏紅。方向一律從視角格中心算，只有相機移動才會增加夾角。
    struct ViewSpan {
        var a = SIMD3<Float>.zero
        var b = SIMD3<Float>.zero
        var spanCos: Float = 1
        /// 這個視角格內的 voxel 數（完成度以 voxel 為單位）。
        var cells = 0

        /// 以新方向擴大跨度：保留三組配對中夾角最大的一組。
        mutating func add(_ d: SIMD3<Float>) {
            guard a != .zero else { a = d; b = d; spanCos = 1; return }
            let ca = simd_dot(d, a), cb = simd_dot(d, b)
            guard min(ca, cb) < spanCos else { return }
            if ca <= cb { b = d; spanCos = ca } else { a = d; spanCos = cb }
        }
        var degrees: Float { acos(max(-1, min(1, spanCos))) * 180 / .pi }
        var isWellObserved: Bool { a != .zero && spanCos <= TiledFusedGrid.kWellObservedCos }
    }

    private(set) var tiles: [Int64: Tile] = [:]
    private var dirtyTiles = DirtyTileQueue()
    private var pendingAnchors: [Int64] = []            // 尚未建立 ARAnchor 的新磚
    private(set) var voxelSize: Float
    let tileSize: Float
    private let maxCells: Int
    private let weightCap: Float = 8
    private var totalCells = 0
    private var nextDynamicKey: Int64 = -1

    init(voxelSize: Float, tileSize: Float, maxCells: Int) {
        self.voxelSize = voxelSize
        self.tileSize = tileSize
        self.maxCells = maxCells
    }

    var count: Int { totalCells }

    /// Release the large live grid before offline fusion. Keep anchor-local samples for
    /// fallback/resume; visit one tile at a time so the old dictionaries are released promptly.
    mutating func trimForProcessing(limit: Int) {
        let limit = max(0, limit)
        guard totalCells > limit else { return }
        let total = totalCells
        var visited = 0, retained = 0
        for key in Array(tiles.keys) {
            guard var tile = tiles.removeValue(forKey: key) else { continue }
            var compact: [Int64: FusedVoxelGrid.Cell] = [:]
            for (cellKey, cell) in tile.cells {
                let before = visited * limit / total
                visited += 1
                if visited * limit / total > before { compact[cellKey] = cell }
            }
            retained += compact.count
            tile.cells = compact
            tiles[key] = tile
            dirtyTiles.insert(key)
        }
        totalCells = retained
        recountViews()
    }

    /// anchorTransforms：主執行緒傳入的各磚錨點「當下」變換（漂移修正後）。
    /// 缺席（新磚尚未建錨）時退回 translate(磚中心)，與稍後建立的錨點初始值一致。
    /// - cameraPosition: 本幀相機的世界座標。用來算「這格是從哪個方向被看到的」——
    ///   融合品質改以方向多樣性衡量，不是觀測次數（同一角度看再多次，視差仍為零）。
    mutating func insert(_ candidates: [CloudPoint], anchorTransforms: [Int64: simd_float4x4],
                         cameraPosition: SIMD3<Float>) {
        updateAnchorTransforms(anchorTransforms)
        // 用修正後的磚邊界建立索引。只按原始世界格號選磚，跨格的漂移會產生重複表面。
        var inverses = tiles.mapValues { $0.originLatest.inverse }
        var buckets: [Int64: [Int64]] = [:]
        let half = tileSize * 0.5
        func register(_ id: Int64, origin: simd_float4x4) {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for x: Float in [-half, half] { for y: Float in [-half, half] { for z: Float in [-half, half] {
                let p = origin * SIMD4<Float>(x, y, z, 1)
                lo = simd_min(lo, SIMD3(p.x, p.y, p.z))
                hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
            } } }
            guard lo.x.isFinite, lo.y.isFinite, lo.z.isFinite,
                  hi.x.isFinite, hi.y.isFinite, hi.z.isFinite else { return }
            let lower = floor(lo / tileSize)
            let upper = floor((hi - SIMD3<Float>(repeating: 0.00001)) / tileSize)
            // ARAnchor 應是剛體；不讓毀損矩陣產生無界索引。
            guard simd_reduce_min(upper - lower) >= 0, simd_reduce_max(upper - lower) <= 3,
                  PointCloudMath.voxelKey(lo, size: tileSize) != nil else { return }
            for x in Int(lower.x)...Int(upper.x) {
                for y in Int(lower.y)...Int(upper.y) {
                    for z in Int(lower.z)...Int(upper.z) {
                        let p = (SIMD3<Float>(Float(x), Float(y), Float(z)) + 0.5) * tileSize
                        if let key = PointCloudMath.voxelKey(p, size: tileSize) { buckets[key, default: []].append(id) }
                    }
                }
            }
        }
        for id in tiles.keys.sorted() { register(id, origin: tiles[id]!.originLatest) }
        for pt in candidates {
            let world = SIMD3<Float>(pt.x, pt.y, pt.z)
            guard let worldKey = PointCloudMath.voxelKey(world, size: tileSize) else { continue }
            let worldH = SIMD4<Float>(world, 1)
            var selected: (id: Int64, local: SIMD3<Float>, distance: Float)?
            for id in buckets[worldKey] ?? [] {
                guard let inverse = inverses[id] else { continue }
                let p = inverse * worldH
                let local = SIMD3(p.x, p.y, p.z)
                // 10 µm tolerance: a point on a tile boundary can round to exactly ±half, and would
                // otherwise start a new dynamic tile (and anchor) every frame.
                guard simd_reduce_min(local) >= -half - 1e-5, simd_reduce_max(local) < half + 1e-5 else { continue }
                let distance = simd_length_squared(local)
                if selected == nil || distance < selected!.distance { selected = (id, local, distance) }
            }
            let tileKey: Int64
            let local: SIMD3<Float>
            if let selected {
                tileKey = selected.id
                local = selected.local
            } else {
                // 原本 ID 所在的磚可能已移走；新區域用新 ID，不能覆寫舊錨點。
                tileKey = tiles[worldKey] == nil ? worldKey : nextDynamicKey
                if tileKey == nextDynamicKey { nextDynamicKey -= 1 }
                let center = PointCloudMath.cellCenter(worldKey, size: tileSize)
                let origin = Self.translation(center)
                tiles[tileKey] = Tile(center: center, originLatest: origin)
                inverses[tileKey] = origin.inverse
                pendingAnchors.append(tileKey)
                register(tileKey, origin: origin)
                local = world - center
            }
            let cameraLocal = inverses[tileKey]! * SIMD4<Float>(cameraPosition, 1)
            guard let cellKey = PointCloudMath.voxelKey(local, size: voxelSize),
                  let viewKey = PointCloudMath.voxelKey(local, size: Self.viewCellSize) else { continue }
            // Direction from the view cell's centre, so points spread over the cell do not add
            // angle by themselves: only a moving camera does.
            let toCamera = SIMD3(cameraLocal.x, cameraLocal.y, cameraLocal.z) - PointCloudMath.cellCenter(viewKey, size: Self.viewCellSize)
            guard simd_length_squared(toCamera) > 1e-8 else { continue }
            var span = tiles[tileKey]!.views[viewKey] ?? ViewSpan()
            let wasWell = span.isWellObserved
            span.add(simd_normalize(toCamera))
            let isNewCell = tiles[tileKey]!.cells[cellKey] == nil
            if isNewCell { span.cells += 1 }
            // 跨過門檻的那一刻整個視角格一起計入；已達標的格子只加新 voxel → O(1) 維護
            if span.isWellObserved { wellObserved += wasWell ? (isNewCell ? 1 : 0) : span.cells }
            tiles[tileKey]!.views[viewKey] = span

            let rgb = SIMD3<Float>(Float(pt.r), Float(pt.g), Float(pt.b))
            if var cell = tiles[tileKey]!.cells[cellKey] {
                let w = max(0.01, pt.score)
                let total = cell.weight + w
                cell.mean += (local - cell.mean) * (w / total)
                cell.color += (rgb - cell.color) * (w / total)
                cell.weight = min(total, weightCap)
                cell.bestScore = max(cell.bestScore, pt.score)
                tiles[tileKey]!.cells[cellKey] = cell
            } else {
                tiles[tileKey]!.cells[cellKey] = FusedVoxelGrid.Cell(
                    mean: local, color: rgb, weight: max(0.01, pt.score), bestScore: pt.score)
                totalCells += 1
                if totalCells >= maxCells { coarsen() }
            }
            dirtyTiles.insert(tileKey)
        }
    }

    mutating func updateAnchorTransforms(_ transforms: [Int64: simd_float4x4]) {
        for (key, transform) in transforms where tiles[key] != nil {
            tiles[key]!.originLatest = transform
        }
    }

    /// 觸頂自動粗化：voxel ×2、各磚局部 cell 加權合併 —— 記憶體有界、不停止收點
    private mutating func coarsen() {
        voxelSize *= 2
        totalCells = 0
        for (tileKey, tile) in tiles {
            var merged: [Int64: FusedVoxelGrid.Cell] = Dictionary(minimumCapacity: tile.cells.count / 4)
            for cell in tile.cells.values {
                guard let key = PointCloudMath.voxelKey(cell.mean, size: voxelSize) else { continue }
                if var m = merged[key] {
                    let total = m.weight + cell.weight
                    m.mean += (cell.mean - m.mean) * (cell.weight / total)
                    m.color += (cell.color - m.color) * (cell.weight / total)
                    m.weight = min(total, weightCap)
                    m.bestScore = max(m.bestScore, cell.bestScore)
                    merged[key] = m
                } else {
                    merged[key] = cell
                }
            }
            tiles[tileKey]!.cells = merged
            totalCells += merged.count
            dirtyTiles.insert(tileKey)
        }
        // 合併改變了 voxel 數 → 重算。coarsen 很少發生，O(N) 可接受。
        recountViews()
        print("[PointCloud] 自動粗化 → voxel \(voxelSize * 100)cm，剩 \(totalCells) 點")
    }

    var pendingRenderTileCount: Int { dirtyTiles.count }

    mutating func popDirtyTiles(limit: Int, pointBudget: Int = .max) -> [Int64] {
        var out: [Int64] = [], points = 0
        while out.count < max(0, limit), let key = dirtyTiles.first {
            let count = tiles[key]?.cells.count ?? 0
            // A single oversized tile is atomic and must still make progress.
            if !out.isEmpty && count > max(0, pointBudget - points) { break }
            _ = dirtyTiles.popFirst(); out.append(key); points += count
        }
        return out
    }

    func pendingAnchorSnapshot() -> [(Int64, SIMD3<Float>)] {
        pendingAnchors.map { ($0, tileCenter($0)) }
    }

    mutating func acknowledgeAnchors(_ keys: [Int64]) {
        let acknowledged = Set(keys)
        pendingAnchors.removeAll { acknowledged.contains($0) }
    }

    /// 取走待建錨磚（key + 世界中心），主執行緒建 ARAnchor
    mutating func takePendingAnchors() -> [(Int64, SIMD3<Float>)] {
        let out = pendingAnchors.map { ($0, tileCenter($0)) }
        pendingAnchors.removeAll(keepingCapacity: true)
        return out
    }

    /// 打包整磚為 GPU-ready Data（位置即錨點局部座標，渲染時由節點變換帶回世界）
    func tileRenderData(_ tileKey: Int64, mode: PointColorMode = .rgb) -> TileRenderData? {
        guard let tile = tiles[tileKey], !tile.cells.isEmpty else { return nil }
        var positions = [Float](); positions.reserveCapacity(tile.cells.count * 3)
        var colors = [Float](); colors.reserveCapacity(tile.cells.count * 3)
        var indices = [Int32](); indices.reserveCapacity(tile.cells.count)
        var n: Int32 = 0
        for c in tile.cells.values {
            positions.append(c.mean.x); positions.append(c.mean.y); positions.append(c.mean.z)
            switch mode {
            case .rgb:
                colors.append(min(1, max(0, c.color.x / 255)))
                colors.append(min(1, max(0, c.color.y / 255)))
                colors.append(min(1, max(0, c.color.z / 255)))
            case .fusionQuality:
                // 紅 → 黃 → 綠，依觀測方向的夾角跨度（0° → kWellObservedDegrees）而非次數。
                // 站著不動或原地轉身時方向不變 → 顏色不會前進，這正是要的行為。
                let span = PointCloudMath.voxelKey(c.mean, size: Self.viewCellSize).flatMap { tile.views[$0] }
                let q = min(1, (span?.degrees ?? 0) / Self.kWellObservedDegrees)
                colors.append(q < 0.5 ? 1 : 2 * (1 - q))
                colors.append(q < 0.5 ? 2 * q : 1)
                colors.append(0.15)
            }
            indices.append(n); n += 1
        }
        guard n > 0 else { return nil }
        return TileRenderData(key: tileKey, center: tileCenter(tileKey), count: Int(n),
                              positions: positions.withUnsafeBufferPointer { Data(buffer: $0) },
                              colors: colors.withUnsafeBufferPointer { Data(buffer: $0) },
                              indices: indices.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// 「觀測充分」：觀測方向的夾角跨度至少 30°（熱圖 / 完成度共用）。
    /// 在牆前 2 m 側走約 1 m 即達到；三角化與 3DGS 的視角相依外觀都需要這種基線，
    /// 原地轉身或站著連拍則維持 0°。
    static let kWellObservedDegrees: Float = 30
    static let kWellObservedCos = cos(kWellObservedDegrees * .pi / 180)
    /// 視角格邊長（公尺，錨點局部座標）。
    static let viewCellSize: Float = 0.10

    /// 依目前 voxel 重算各視角格的 voxel 數與完成度（粗化、縮減後）。
    private mutating func recountViews() {
        wellObserved = 0
        for key in Array(tiles.keys) {
            guard var tile = tiles[key] else { continue }
            for viewKey in Array(tile.views.keys) { tile.views[viewKey]!.cells = 0 }
            for cell in tile.cells.values {
                guard let viewKey = PointCloudMath.voxelKey(cell.mean, size: Self.viewCellSize) else { continue }
                var span = tile.views[viewKey] ?? ViewSpan()
                span.cells += 1
                if span.isWellObserved { wellObserved += 1 }
                tile.views[viewKey] = span
            }
            tiles[key] = tile
        }
    }

    /// 所在視角格已達 kWellObservedDegrees 的 voxel 數（O(1) 維護）
    private(set) var wellObserved = 0
    /// 融合完成度：已從夾角夠大的不同方向看過的表面占比。
    /// 比幀數與觀測次數都更有意義——100 幀站在原地拍，兩者都會給滿分，但視差為零。
    var fusionCompleteness: Double {
        totalCells > 0 ? Double(wellObserved) / Double(totalCells) : 0
    }

    /// 全部磚標記為待重畫 —— 切換上色模式時必須重送幾何，否則只有之後變動的磚會換色
    mutating func markAllDirty() {
        for key in tiles.keys.sorted() { dirtyTiles.insert(key) }
    }

    func tileCenter(_ tileKey: Int64) -> SIMD3<Float> {
        tiles[tileKey]?.center ?? PointCloudMath.cellCenter(tileKey, size: tileSize)
    }

    /// Stop-time safety checkpoint: bounded output, no full-cloud array or downsampling dictionary.
    func checkpointPoints(limit: Int) -> [CloudPoint] {
        guard limit > 0 else { return [] }
        let step = max(1, totalCells / limit + (totalCells % limit == 0 ? 0 : 1))
        var output: [CloudPoint] = []
        output.reserveCapacity(min(totalCells, limit))
        var index = 0
        for tile in tiles.values {
            for cell in tile.cells.values {
                defer { index += 1 }
                guard index % step == 0 else { continue }
                let w = tile.originLatest * SIMD4(cell.mean, 1)
                output.append(CloudPoint(x: w.x, y: w.y, z: w.z,
                    r: UInt8(min(255, max(0, cell.color.x))),
                    g: UInt8(min(255, max(0, cell.color.y))),
                    b: UInt8(min(255, max(0, cell.color.z))), score: cell.bestScore))
            }
        }
        return output
    }

    /// 匯出（無 LiDAR 備援用）：局部 → 世界（乘最近錨點變換）後分層擇優下採樣
    func exportPoints(target: Int) -> [CloudPoint] {
        func c8(_ f: Float) -> UInt8 { UInt8(min(255, max(0, f))) }
        var points: [CloudPoint] = []
        points.reserveCapacity(totalCells)
        for tile in tiles.values {
            for c in tile.cells.values {
                let w = tile.originLatest * SIMD4<Float>(c.mean.x, c.mean.y, c.mean.z, 1)
                points.append(CloudPoint(x: w.x, y: w.y, z: w.z,
                                         r: c8(c.color.x), g: c8(c.color.y), b: c8(c.color.z),
                                         score: c.bestScore * min(1, c.weight / 1.5)))
            }
        }
        // 同 RefusionEngine：起始用原生 voxelSize，加粗幅度交給解析步長決定
        return PointCloudMath.stratifiedBest(points, startCell: voxelSize, target: target)
    }

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }
}

/// Runtime evidence for device testing; durations measure work, not a promised display FPS.
nonisolated struct PreviewPerformanceReport: Codable, Sendable {
    var version = 2
    var extractionTotalMS = 0.0
    var consistencyTotalMS = 0.0
    var gridInsertTotalMS = 0.0
    var maximumSampleStride = 0
    var overBudgetFrames = 0
    var integratedFrames = 0
    var candidatePoints = 0
    var acceptedPoints = 0
    var integrationTotalMS = 0.0
    var integrationMaxMS = 0.0
    var renderBatches = 0
    var renderedTiles = 0
    var peakPendingTiles = 0
    var packingTotalMS = 0.0
    var packingMaxMS = 0.0
    var mainApplyTotalMS = 0.0
    var mainApplyMaxMS = 0.0
    var qualityBlockedFrames = 0
    var assessedFrames = 0
}
