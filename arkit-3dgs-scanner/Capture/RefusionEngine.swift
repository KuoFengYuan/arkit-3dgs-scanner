//
//  RefusionEngine.swift
//  fable — 掃描後點雲重融合（Scaniverse 式「Processing」階段）
//
//  停止掃描後，以「錨點修正後的姿態」把所有關鍵幀的原始深度重新反投影，
//  做逐 voxel 加權平均融合：
//    - 深度雜訊隨觀測數 ~1/√N 收斂（LiDAR 單幀 σ≈1-2cm → 融合後 <1cm）
//    - 顏色加權平均，去除曝光閃爍與斜視取樣的色偏
//    - 輸出的 points3D 與 images.bin 的姿態完全一致（同一組修正後姿態）
//  本檔不依賴 ARKit，可在 macOS 編譯，供 scratchpad/check harness 交叉驗證。
//

import Foundation
import CoreGraphics
import ImageIO
import os
import simd

/// Scoped to one fusion job; a warning latches until that job has safely stopped.
nonisolated private final class FusionMemoryWarning: @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0
    #if os(iOS)
    private var source: DispatchSourceMemoryPressure?
    #endif
    init() {
        #if os(iOS)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.record() }
        self.source = source
        source.resume()
        #endif
    }
    private func record() { lock.lock(); events += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return events }
    deinit {
        #if os(iOS)
        source?.cancel()
        #endif
    }
}

/// Exactly one pending RGB decode. Only the worker owns decoder objects; the consumer takes
/// an immutable, depth-resolution byte array. No full-frame queue or concurrent grid mutations.
nonisolated private final class FusionRGBPrefetch: @unchecked Sendable {
    struct Image: Sendable { let pixels: [UInt8]?; let seconds: Double }
    private let condition = NSCondition()
    private let queue = DispatchQueue(label:"scan.fusion.rgb",qos:.userInitiated)
    private var ready = false
    private var result: Image?
    func start(_ load: @escaping @Sendable () -> Image) {
        condition.lock(); ready = false; result = nil; condition.unlock()
        queue.async { [self] in
            let image = autoreleasepool(invoking:load)
            condition.lock(); result = image; ready = true; condition.signal(); condition.unlock()
        }
    }
    func take() -> Image {
        condition.lock(); defer { condition.unlock() }
        while !ready { condition.wait() }
        let image = result!; result = nil
        return image
    }
}

// MARK: - 共用幾何工具

nonisolated enum PointCloudMath {

    /// 21 bits/軸 精確格子索引（±2^20 格，1cm 格距下 ≈ ±10km）
    static func voxelKey(_ p: SIMD3<Float>, size: Float) -> Int64? {
        guard size.isFinite, size > 0, p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
        let scaled = p / size
        let bound = Float(1 << 20)
        guard scaled.x >= -bound, scaled.x < bound,
              scaled.y >= -bound, scaled.y < bound,
              scaled.z >= -bound, scaled.z < bound else { return nil }
        let ix = Int64(scaled.x.rounded(.down)) &+ (1 << 20)
        let iy = Int64((p.y / size).rounded(.down)) &+ (1 << 20)
        let iz = Int64((p.z / size).rounded(.down)) &+ (1 << 20)
        let limit: Int64 = 1 << 21
        guard ix >= 0, ix < limit, iy >= 0, iy < limit, iz >= 0, iz < limit else { return nil }
        return (ix << 42) | (iy << 21) | iz
    }

    /// voxelKey 反解 → 該格中心的世界座標
    static func cellCenter(_ key: Int64, size: Float) -> SIMD3<Float> {
        let mask: Int64 = (1 << 21) - 1
        let ix = ((key >> 42) & mask) - (1 << 20)
        let iy = ((key >> 21) & mask) - (1 << 20)
        let iz = (key & mask) - (1 << 20)
        return SIMD3<Float>((Float(ix) + 0.5) * size,
                            (Float(iy) + 0.5) * size,
                            (Float(iz) + 0.5) * size)
    }

    /// 分層擇優下採樣：逐級加粗格子、每格保留最高分，直到 ≤ target。
    /// 相比全域 top-K 不會把點擠在單一區域 —— 密度均勻且每處都是最佳樣本。
    ///
    /// 格距的成長率是**解析算出來的，不是固定 ×2**。點雲是嵌在 3D 裡的 2D 流形，
    /// 占據格數 ∝ 1/格距²，所以格距加倍等於點數砍成 1/4 —— 固定 ×2 會嚴重過衝。
    /// 實機出現過：332,251 格、上限 250,000，只需要砍 25%，結果一步跳到
    /// 4.2cm 只剩 74,836 點（砍掉 77%）。
    ///
    /// 這不只是少了點：外部訓練器可能依鄰近點距設定初始高斯尺寸，
    /// 匯出端把點距放大 2 倍，初始高斯就跟著大 2 倍，密集化未必追得回來 ——
    /// 與先前修過的「重融合靜默粗化」是同一種失效，只是發生在匯出端。
    ///
    /// 改為每輪由 √(count/target) 估出需要的格距，一兩步就收斂到接近上限。
    static func stratifiedBest(_ input: [CloudPoint], startCell: Float, target: Int) -> [CloudPoint] {
        var points = input
        guard target > 0, points.count > target else { return points }
        var cellSize = startCell
        var rounds = 0
        while points.count > target, rounds < 12 {   // rounds：防呆，正常 1~3 輪就結束
            rounds += 1
            // ×1.02 留一點餘裕（估計是統計性的，剛好壓線會多跑一輪）；
            // 下限 1.03 保證一定有進展，不會卡死
            let shrink = max(1.03, (Float(points.count) / Float(target)).squareRoot() * 1.02)
            cellSize *= shrink
            var cells: [Int64: CloudPoint] = Dictionary(minimumCapacity: points.count / 2)
            for pt in points {
                guard let key = voxelKey(SIMD3<Float>(pt.x, pt.y, pt.z), size: cellSize) else { continue }
                if let old = cells[key], old.score >= pt.score { continue }
                cells[key] = pt
            }
            points = Array(cells.values)
        }
        return points
    }
}

// MARK: - 加權平均 voxel 融合格

nonisolated struct FusedVoxelGrid {

    struct Cell {
        var mean: SIMD3<Float>      // 加權平均位置
        var color: SIMD3<Float>     // 加權平均顏色（0-255）
        var weight: Float           // 累積權重（封頂 → 指數移動平均，晚到的好觀測仍能修正）
        var bestScore: Float
        /// 是否曾收到「量測」點（LiDAR 直接反投影）。false ＝ 這格只有推論來源（ARKit mesh）撐著。
        /// 用來量化補充來源的實際貢獻：只有 measured==false 的格子才是真的補到新覆蓋。
        /// 預設 true —— 即時預覽的 TiledFusedGrid 共用本型別但不追蹤來源。
        var measured: Bool = true
        /// 這格被「哪些方向」觀測過：16 個 bin 的 bitmask（方位 8 × 仰角 2）。
        /// 用方向多樣性而非觀測次數，是因為次數會給假綠燈——同一角度看 20 次，
        /// 視差為零、幾何完全沒被約束，但次數計量會判定為充分。
        /// 3DGS 的高斯深度/形狀靠視差約束（同 SfM 三角化），視角相依外觀靠角度多樣性，
        /// 兩者都不是次數能取代的。popcount 也天然涵蓋次數（1 次不可能有 3 個方向）。
        var dirMask: UInt16 = 0
    }

    /// 分片字典。
    ///
    /// **插入是重融合唯一不能平行的一段。** 逐幀的檔案讀取／JPEG 解碼／反投影／
    /// mesh 投影都是純函式（見 RefusionEngine.refuse 的 produce，已經平行化），
    /// 但它們最後都要寫進同一張表。而這一段是隨幀數線性成長的 ——
    /// 實測 54 幀 1.81s，走 60m 的整層掃描約 600 幀，線性外推就是 20 秒。
    ///
    /// 以 voxel key 分片後，每片是獨立字典 → N 條 lane 可以同時寫。
    ///
    /// **輸出與單片版逐位元相同。** cell → 分片是確定性的，而同一分片內的點仍照
    /// 原順序處理，所以每個 cell 收到的觀測序列一模一樣。這一點必須守住：
    /// 加權平均在權重封頂（weightCap）之後是順序相依的，
    /// 若順序隨執行緒排程而變，同一份掃描資料會融出不同的點雲。
    private var shards: [[Int64: Cell]]
    private let shardMask: Int64
    private(set) var voxelSize: Float
    private var maxCells: Int
    private let weightCap: Float = 8
    /// Far-range cells use a separate key space at voxelSize × farVoxelScale.
    /// voxelKey never sets bit 63, so the sign bit marks far keys without collisions.
    static let farKeyFlag = Int64.min
    private(set) var farVoxelScale: Float

    struct ExportStats: Sendable {
        var farCells = 0
        var farExcludedNearSurface = 0
        var farExported = 0
    }
    private(set) var lastExport = ExportStats()

    /// 分片數取 2 的冪且明顯多於核心數 —— 分堆才平均，lane 之間也不必等最慢的一片
    private static let shardCount = 16

    init(voxelSize: Float, maxCells: Int, farVoxelScale: Float = 1) {
        self.voxelSize = voxelSize
        self.maxCells = maxCells
        self.farVoxelScale = farVoxelScale.isFinite ? max(1, farVoxelScale) : 1
        self.shards = Array(repeating: [:], count: Self.shardCount)
        self.shardMask = Int64(Self.shardCount - 1)
    }

    @inline(__always)
    private static func isFar(_ key: Int64) -> Bool { key < 0 }

    @inline(__always)
    private func key(for p: SIMD3<Float>, far: Bool) -> Int64? {
        guard far else { return PointCloudMath.voxelKey(p, size: voxelSize) }
        return PointCloudMath.voxelKey(p, size: voxelSize * farVoxelScale).map { $0 | Self.farKeyFlag }
    }

    var farCount: Int { shards.reduce(0) { acc, s in acc + s.keys.reduce(0) { Self.isFar($1) ? $0 + 1 : $0 } } }

    /// Neighbor count in the cell's own key space and resolution (26-neighborhood).
    private func neighborCount(key: Int64, atLeast needed: Int) -> Int {
        let far = Self.isFar(key)
        let size = far ? voxelSize * farVoxelScale : voxelSize
        let center = PointCloudMath.cellCenter(far ? key & ~Self.farKeyFlag : key, size: size)
        var neighbors = 0
        for offset in Self.neighborOffsets {
            if let k = PointCloudMath.voxelKey(center + offset * size, size: size) {
                let neighbor = far ? k | Self.farKeyFlag : k
                if shards[shardIndex(neighbor)][neighbor] != nil {
                    neighbors += 1
                    if neighbors >= needed { break }
                }
            }
        }
        return neighbors
    }

    /// Measured near-range occupancy for far-cell exclusion: exact-center test on cells of
    /// exclusion/3, plus a coarse 2x-radius index for a cheap early "nothing nearby" answer.
    private struct NearSurfaceIndex {
        let radius: Float, fine: Float, coarse: Float
        var fineCells = Set<Int64>(), coarseCells = Set<Int64>()
        init(radius: Float) { self.radius = radius; fine = radius / 3; coarse = radius * 2 }
        mutating func insert(_ p: SIMD3<Float>) {
            if let k = PointCloudMath.voxelKey(p, size: fine) { fineCells.insert(k) }
            if let k = PointCloudMath.voxelKey(p, size: coarse) { coarseCells.insert(k) }
        }
        func contains(near p: SIMD3<Float>) -> Bool {
            guard !fineCells.isEmpty else { return false }
            var any = false
            let c = floor(p / coarse)
            search: for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                let offset = SIMD3(Float(dx), Float(dy), Float(dz))
                if let k = PointCloudMath.voxelKey((c + offset + 0.5) * coarse, size: coarse),
                   coarseCells.contains(k) { any = true; break search }
            } } }
            guard any else { return false }
            let base = floor(p / fine)
            for dz in -3...3 { for dy in -3...3 { for dx in -3...3 {
                let center = (base + SIMD3(Float(dx), Float(dy), Float(dz)) + 0.5) * fine
                guard simd_distance(center, p) <= radius,
                      let k = PointCloudMath.voxelKey(center, size: fine) else { continue }
                if fineCells.contains(k) { return true }
            } } }
            return false
        }
    }

    private func nearSurfaceIndex(radius: Float) -> NearSurfaceIndex? {
        guard radius.isFinite, radius > 0, farCount > 0 else { return nil }
        var index = NearSurfaceIndex(radius: radius)
        for shard in shards { for (key, cell) in shard where !Self.isFar(key) && cell.measured { index.insert(cell.mean) } }
        return index
    }

    /// voxel key 是 `(ix << 42) | (iy << 21) | iz`，空間上高度結構化 ——
    /// 直接取低位等於只用 z 分片，掃描面若接近水平就會全擠在同一片。
    /// 三軸互斥或之後再取低位，任何掃描姿態都散得開。
    @inline(__always)
    private func shardIndex(_ key: Int64) -> Int {
        Int((key ^ (key >> 21) ^ (key >> 42)) & shardMask)
    }

    var count: Int { shards.reduce(0) { $0 + $1.count } }
    /// 各分片的格數。分片若散不開，平行化就沒有意義（例如只用低位＝只用 z 軸分片時，
    /// 水平面會全擠在同一片）—— tools/test_voxel_shard.swift 用它驗證分佈。
    func shardOccupancy() -> [Int] { shards.map(\.count) }
    /// 只有推論來源（ARKit mesh）覆蓋、LiDAR 完全沒打到的格子數 ＝ 補充來源的實際新增覆蓋
    var inferredOnlyCount: Int {
        shards.reduce(0) { acc, s in acc + s.values.reduce(0) { $1.measured ? $0 : $0 + 1 } }
    }

    /// - measured: true ＝ LiDAR 直接反投影（量測）；false ＝ ARKit 場景網格（推論）
    /// - far: measured beyond the near range; stored in the far key space at the far voxel size.
    @discardableResult
    mutating func insert(_ candidates: [CloudPoint], measured: Bool = true, far: Bool = false,
                         boundedMemory: Bool = false,
                         shouldContinue: () -> Bool = { true }) -> Bool {
        guard shouldContinue() else { return false }
        guard !candidates.isEmpty else { return true }
        if boundedMemory {
            // Mobile path: no duplicate candidate buckets or concurrent dictionary expansion.
            // Check capacity every 1,024 points instead of overshooting by a whole mesh frame.
            for (index, pt) in candidates.enumerated() {
                if index % 1024 == 0, !shouldContinue() { return false }
                guard pt.score.isFinite else { continue }
                if let key = self.key(for: SIMD3(pt.x, pt.y, pt.z), far: far) {
                    let s = shardIndex(key)
                    let pos = SIMD3<Float>(pt.x, pt.y, pt.z)
                    let rgb = SIMD3<Float>(Float(pt.r), Float(pt.g), Float(pt.b))
                    let w = max(0.01, pt.score)
                    if var cell = shards[s][key] {
                        if !cell.measured || measured {
                            if !cell.measured && measured {
                                cell = Cell(mean: pos, color: rgb, weight: w, bestScore: pt.score)
                            } else {
                                let total = cell.weight + w
                                cell.mean += (pos - cell.mean) * (w / total)
                                cell.color += (rgb - cell.color) * (w / total)
                                cell.weight = min(total, weightCap)
                                cell.bestScore = max(cell.bestScore, pt.score)
                            }
                            shards[s][key] = cell
                        }
                    } else {
                        shards[s][key] = Cell(mean: pos, color: rgb, weight: w,
                                             bestScore: pt.score, measured: measured)
                    }
                }
                if (index + 1) % 1024 == 0, count > maxCells, !reduceCapacity(to: maxCells, shouldContinue: shouldContinue) { return false }
            }
            if count > maxCells, !reduceCapacity(to: maxCells, shouldContinue: shouldContinue) { return false }
            return true
        }
        // 先分堆（保序），再各片平行寫入
        let n = shards.count
        var byShard = [[(key: Int64, pt: CloudPoint)]](repeating: [], count: n)
        let guess = candidates.count / n + 8
        for i in 0..<n { byShard[i].reserveCapacity(guess) }
        for pt in candidates {
            guard pt.score.isFinite else { continue }
            guard let key = self.key(for: SIMD3<Float>(pt.x, pt.y, pt.z), far: far) else { continue }
            byShard[shardIndex(key)].append((key, pt))
        }
        let cap = weightCap
        shards.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: n) { s in
                for (key, pt) in byShard[s] {
                    let pos = SIMD3<Float>(pt.x, pt.y, pt.z)
                    let rgb = SIMD3<Float>(Float(pt.r), Float(pt.g), Float(pt.b))
                    if var cell = buf[s][key] {
                        // mesh 只補洞；反覆投影的同一網格頂點不能累積票數拉偏量測。
                        if cell.measured && !measured { continue }
                        if !cell.measured && measured {
                            buf[s][key] = Cell(mean: pos, color: rgb, weight: max(0.01, pt.score),
                                               bestScore: pt.score, measured: true)
                            continue
                        }
                        let w = max(0.01, pt.score)
                        let total = cell.weight + w
                        cell.mean += (pos - cell.mean) * (w / total)
                        cell.color += (rgb - cell.color) * (w / total)
                        cell.weight = min(total, cap)
                        cell.bestScore = max(cell.bestScore, pt.score)
                        cell.measured = cell.measured || measured
                        buf[s][key] = cell
                    } else {
                        buf[s][key] = Cell(mean: pos, color: rgb,
                                           weight: max(0.01, pt.score), bestScore: pt.score,
                                           measured: measured)
                    }
                }
            }
        }
        // 觸頂檢查移到批次之後：原本每插入一個新格就查一次全域數量，
        // 分片之後那會變成每點一次跨片加總。代價是可能短暫超出上限一個批次的量，
        // 而一個批次只有一幀的點（~49k），相對 2M 的上限可以忽略。
        if count >= maxCells, count > 1 {
            guard coarsen(shouldContinue: shouldContinue), reduceCapacity(to: maxCells, shouldContinue: shouldContinue) else { return false }
        }
        return true
    }

    /// Only lower the budget; never grow again during a memory-constrained run.
    @discardableResult
    mutating func reduceCapacity(to limit: Int, shouldContinue: () -> Bool = { true }) -> Bool {
        guard shouldContinue() else { return false }
        maxCells = min(maxCells, max(1, limit))
        var rounds = 0
        var stalled = 0
        while count > maxCells, rounds < 32, stalled < 4 {
            let before = count
            guard coarsen(shouldContinue: shouldContinue) else { return false }; rounds += 1
            stalled = count == before ? stalled + 1 : 0
        }
        // Cells on opposite sides of the origin cannot merge by doubling the voxel size.
        // Keep a bounded spatial sample if floating-point scale can no longer help.
        if count > maxCells {
            var kept = 0
            let total = count
            for index in shards.indices {
                guard shouldContinue() else { return false }
                var compact: [Int64: Cell] = [:]
                for (key, value) in shards[index] {
                    if kept % 1024 == 0, !shouldContinue() { return false }
                    let before = kept * maxCells / total
                    kept += 1
                    if kept * maxCells / total > before { compact[key] = value }
                }
                shards[index] = compact
            }
        }
        return true
    }

    /// 觸頂自動粗化：voxel ×2、加權合併 —— 長掃描記憶體有界且不停止收點。
    ///
    /// **逐片搬移並即時釋放，不要先建好整份新表再換掉。**
    /// 那樣峰值是兩份完整的表（4M 格 × ~75B ≈ 300MB，兩份就 600MB），
    /// 而觸頂粗化正好發生在記憶體已經最吃緊的時候 —— 大場景、關鍵幀與點雲都還在。
    /// 這是大場景融合時可能發生記憶體尖峰的位置，實際閃退原因仍需裝置紀錄確認。
    /// 逐片釋放之後峰值降到「舊表剩下的部分 ＋ 新表」，
    /// 而粗化本來就會把格數砍成約 1/4，所以實際峰值接近 1.25 份而不是 2 份。
    private mutating func coarsen(shouldContinue: () -> Bool) -> Bool {
        guard shouldContinue() else { return false }
        guard voxelSize.isFinite, voxelSize < Float.greatestFiniteMagnitude / 2 else { return true }
        voxelSize *= 2
        var merged = [[Int64: Cell]](repeating: [:], count: shards.count)
        var visited = 0
        for si in shards.indices {
            for (oldKey, cell) in shards[si] {
                if visited % 1024 == 0, !shouldContinue() { return false }
                visited += 1
                guard let key = self.key(for: cell.mean, far: Self.isFar(oldKey)) else { continue }
                let s = shardIndex(key)
                if var m = merged[s][key] {
                    if m.measured && !cell.measured { continue }
                    if !m.measured && cell.measured { merged[s][key] = cell; continue }
                    let total = m.weight + cell.weight
                    m.mean += (cell.mean - m.mean) * (cell.weight / total)
                    m.color += (cell.color - m.color) * (cell.weight / total)
                    m.weight = min(total, weightCap)
                    m.bestScore = max(m.bestScore, cell.bestScore)
                    m.measured = m.measured || cell.measured
                    merged[s][key] = m
                } else {
                    merged[s][key] = cell
                }
            }
            shards[si] = [:]        // 這一片搬完就放掉，不要等到全部搬完
        }
        shards = merged
        return true
    }

    /// 26 鄰域方向（單位格offset）
    private static let neighborOffsets: [SIMD3<Float>] = {
        var out: [SIMD3<Float>] = []
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0 && dz == 0) {
            out.append(SIMD3<Float>(Float(dx), Float(dy), Float(dz)))
        } } }
        return out
    }()

    /// Filter into one bit per cell, then consume shards while materializing the bounded output.
    /// Sampling AFTER rejection preserves the requested density when many cells are isolated.
    /// A nil result means cancellation/pressure: never publish a partial cloud as successful.
    mutating func consumeExportPoints(target: Int, minNeighbors: Int, farExclusion: Float = 0,
                                      shouldContinue: () -> Bool,
                                      progress: (Double) -> Void) -> [CloudPoint]? {
        lastExport = ExportStats()
        guard shouldContinue() else { return nil }
        guard target > 0, count > 0 else { return [] }
        let total = count
        let nearSurface = nearSurfaceIndex(radius: farExclusion)
        guard shouldContinue() else { return nil }
        var accepted = [[UInt64]]()
        var eligible = 0, visited = 0
        for shard in shards {
            var bits = [UInt64](repeating: 0, count: (shard.count + 63) / 64)
            for (index, entry) in shard.enumerated() {
                if visited % 4096 == 0 {
                    guard shouldContinue() else { return nil }
                    progress(Double(visited) / Double(total) * 0.5)
                }
                visited += 1
                let cell = entry.value
                guard cell.color.x.isFinite, cell.color.y.isFinite, cell.color.z.isFinite,
                      cell.mean.x.isFinite, cell.mean.y.isFinite, cell.mean.z.isFinite,
                      cell.weight.isFinite, cell.bestScore.isFinite else { continue }
                let far = Self.isFar(entry.key)
                if far { lastExport.farCells += 1 }
                let neighbors = minNeighbors > 0 ? neighborCount(key: entry.key, atLeast: minNeighbors) : 0
                guard neighbors >= minNeighbors else { continue }
                // A far sample next to a near measured surface is that surface seen through a
                // range-dependent bias; keeping it would add a second layer.
                if far, let nearSurface, nearSurface.contains(near: cell.mean) {
                    lastExport.farExcludedNearSurface += 1
                    continue
                }
                bits[index / 64] |= UInt64(1) << (index % 64)
                eligible += 1
            }
            accepted.append(bits)
        }
        guard shouldContinue() else { return nil }
        let limit = min(target, eligible)
        var output: [CloudPoint] = []
        output.reserveCapacity(limit)
        var selected = 0
        var best: (key: Int64, cell: Cell, rank: UInt64)?
        func sampleRank(_ key: Int64) -> UInt64 {
            // Stable pseudo-random choice within each spatial interval avoids striping and
            // confidence bias against thin/distant surfaces. It never perturbs point values.
            var x = UInt64(bitPattern:key) &+ 0x9e3779b97f4a7c15
            x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
            x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
            return x ^ (x >> 31)
        }
        visited = 0
        func color(_ value: Float) -> UInt8 { UInt8(min(255, max(0, value))) }
        func quality(_ cell: Cell) -> Float { cell.bestScore * min(1,cell.weight/1.5) }
        for shardIndex in shards.indices {
            // Only one shard's compact Int64 keys are sorted, never a second full cloud/grid.
            // Stable spatial order removes Dictionary hash-seed dependence at the output cap.
            var keys: [Int64] = []
            keys.reserveCapacity(shards[shardIndex].count)
            for (index,entry) in shards[shardIndex].enumerated() {
                if visited % 4096 == 0 {
                    guard shouldContinue() else { return nil }
                    progress(0.5 + Double(visited) / Double(total) * 0.5)
                }
                visited += 1
                if accepted[shardIndex][index/64] & (UInt64(1) << (index%64)) != 0 { keys.append(entry.key) }
            }
            keys.sort()
            for (index,key) in keys.enumerated() {
                if index % 4096 == 0, !shouldContinue() { return nil }
                guard let cell = shards[shardIndex][key] else { continue }
                let rank = sampleRank(key)
                if best == nil || rank < best!.rank { best = (key,cell,rank) }
                let before = selected * limit / max(1,eligible)
                selected += 1
                guard selected * limit / max(1,eligible) > before, let chosen = best else { continue }
                let point = chosen.cell
                if Self.isFar(chosen.key) { lastExport.farExported += 1 }
                output.append(CloudPoint(x:point.mean.x,y:point.mean.y,z:point.mean.z,
                    r:color(point.color.x),g:color(point.color.y),b:color(point.color.z),score:quality(point)))
                best = nil
            }
            shards[shardIndex] = [:]
            accepted[shardIndex] = []
        }
        progress(1)
        return output
    }

    /// 匯出：孤立點移除（飄浮雜點）+ 單次觀測降權，再分層擇優到 target。
    /// minNeighbors>0 時，26 鄰域占據數不足的 voxel 視為雜訊剔除。
    func exportPoints(target: Int, minNeighbors: Int, boundedMemory: Bool = false) -> [CloudPoint] {
        exportPointsWithStats(target: target, minNeighbors: minNeighbors, boundedMemory: boundedMemory).points
    }

    /// farExclusion > 0 drops far cells next to a near measured surface (see consumeExportPoints).
    func exportPointsWithStats(target: Int, minNeighbors: Int, boundedMemory: Bool = false,
                               farExclusion: Float = 0) -> (points: [CloudPoint], stats: ExportStats) {
        var stats = ExportStats()
        guard target > 0 else { return ([], stats) }
        func c8(_ f: Float) -> UInt8 { UInt8(min(255, max(0, f))) }
        let nearSurface = nearSurfaceIndex(radius: farExclusion)
        var points: [CloudPoint] = []
        let total = count
        let limit = min(total, target)
        points.reserveCapacity(boundedMemory ? limit : total)
        var visited = 0
        for shard in shards {
            for (key, cell) in shard {
                // Bounded fallback: spread selections over the whole grid, without first
                // allocating all points plus another spatial downsampling dictionary.
                if boundedMemory, total > target {
                    let before = visited * limit / total
                    visited += 1
                    if visited * limit / total == before { continue }
                }
                let far = Self.isFar(key)
                if far { stats.farCells += 1 }
                if minNeighbors > 0 {
                    let vs = far ? voxelSize * farVoxelScale : voxelSize
                    var n = 0
                    for o in Self.neighborOffsets {
                        let np = cell.mean + o * vs
                        // 鄰格可能落在別的分片 —— 查詢必須先算分片，不能只查自己這片
                        if let k0 = PointCloudMath.voxelKey(np, size: vs) {
                            let k = far ? k0 | Self.farKeyFlag : k0
                            if shards[shardIndex(k)][k] != nil {
                                n += 1
                                if n >= minNeighbors { break }
                            }
                        }
                    }
                    if n < minNeighbors { continue }   // 孤立 → 飄浮雜點，丟棄
                }
                if far, let nearSurface, nearSurface.contains(near: cell.mean) {
                    stats.farExcludedNearSurface += 1
                    continue
                }
                if far { stats.farExported += 1 }
                points.append(CloudPoint(x: cell.mean.x, y: cell.mean.y, z: cell.mean.z,
                                         r: c8(cell.color.x), g: c8(cell.color.y),
                                         b: c8(cell.color.z),
                                         score: cell.bestScore * min(1, cell.weight / 1.5)))
            }
        }
        // 起始格距用原生 voxelSize：加粗多少交給解析步長決定。
        // 先前預設 ×2 等於還沒開始就先砍掉 4 倍的點。
        return (boundedMemory ? points : PointCloudMath.stratifiedBest(points, startCell: voxelSize, target: target), stats)
    }
}

// MARK: - 重融合引擎

/// Neighbor reuse has both a byte cap and an entry cap, independent of total scan length.
/// Keys are record indices within one fusion run, so resumed/corrected scans cannot reuse poses.
nonisolated struct DepthViewCache {
    private struct Entry { let view: DepthConsistencyView; let bytes: Int; var accessed: Int }
    private var entries: [Int: Entry] = [:]
    private var tick = 0
    let byteLimit: Int
    let entryLimit: Int
    private(set) var retainedBytes = 0
    private(set) var peakBytes = 0
    private(set) var peakEntries = 0
    private(set) var hits = 0
    private(set) var loads = 0

    init(byteLimit: Int = 2 * 1_024 * 1_024, entryLimit: Int = 8) {
        self.byteLimit = max(0, byteLimit)
        self.entryLimit = max(0, entryLimit)
    }

    mutating func view(index: Int, load: () -> DepthConsistencyView?) -> DepthConsistencyView? {
        tick += 1
        if var entry = entries[index] {
            hits += 1; entry.accessed = tick; entries[index] = entry
            return entry.view
        }
        loads += 1
        guard let view = load() else { return nil }
        let bytes = view.depth.count * MemoryLayout<Float>.stride + (view.confidence?.count ?? 0) + view.samplingMaskBytes
        guard bytes <= byteLimit, entryLimit > 0 else { return view }
        while retainedBytes + bytes > byteLimit || entries.count >= entryLimit {
            guard let key = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key,
                  let old = entries.removeValue(forKey: key) else { break }
            retainedBytes -= old.bytes
        }
        entries[index] = Entry(view: view, bytes: bytes, accessed: tick)
        retainedBytes += bytes
        peakBytes = max(peakBytes, retainedBytes)
        peakEntries = max(peakEntries, entries.count)
        return view
    }

    mutating func clear() { entries = [:]; retainedBytes = 0 }
}

nonisolated enum RefusionEngine {

    /// 由磁碟上的關鍵幀（深度 .bin + JPEG + 修正後姿態）重建高品質融合點雲。
    /// 在背景執行緒同步執行；progress ∈ 0...1。
    /// - meshVertices: ARKit 場景重建網格的世界座標頂點（可空）。用來補上關鍵幀沒拍到的表面
    ///   —— ARKit 的 mesh 融合每一幀（60fps）的深度，而本函式只吃 ~120 個關鍵幀。
    /// - target: 桌機可覆寫匯出上限；手機仍受 config.exportMaxPoints 限制，
    ///   避免平面圖要求造成第二份大型點雲與下採樣字典同時存在。
    static func refuse(records: [FrameRecord], sessionDir: URL, config: CaptureConfig,
                       meshVertices: [SIMD3<Float>] = [], target: Int? = nil,
                       progress: @Sendable (Double) -> Void) -> [CloudPoint] {
        refuseWithReport(records: records, sessionDir: sessionDir, config: config,
                         meshVertices: meshVertices, target: target, progress: progress).points
    }

    struct Report: Codable, Sendable {
        var version = 9
        var debugAssertionsEnabled: Bool? = ProcessingBuild.debugAssertionsEnabled
        var status = "running"
        var stage = "frames"
        var totalFrames = 0
        var completedFrames = 0
        var peakCells = 0
        var initialCellLimit = 0
        var capacityReductions = 0
        var minimumAvailableBytes: UInt64?
        var peakProcessFootprintBytes: UInt64?
        var memoryWarningCount: Int? = 0
        var memoryStopReason: String?
        var requiredFrameHeadroomBytes: UInt64?
        var outputPoints = 0
        var boundedExport = false
        var exportSampling: String?
        var finalVoxelSizeM: Float = 0
        var effectiveOutputLimit = 0
        var exportFraction: Double?
        var exportSeconds: Double?
        var depthCacheHits = 0
        var depthCacheLoads = 0
        var depthCachePeakBytes = 0
        var depthCachePeakEntries = 0
        var depthReadSeconds = 0.0
        var unprojectSeconds = 0.0
        var consistencySeconds = 0.0
        var diverseReferences: Bool?
        var rayConsensus: Bool?
        var preparedDepthSampling: Bool?
        var rgbPrefetch: Bool?
        var rgbWaitSeconds: Double?
        var wallSeconds: Double?
        var surface: SurfaceTSDF.Report?
        var surfaceValidation: SurfaceVisibilityValidator.Report?
        /// Range priority (v7). nil in reports written before it existed or when disabled.
        var nearRangeM: Float?
        var farExclusionM: Float?
        var farVoxelSizeM: Float?
        var farCells: Int?
        var farExcludedNearSurface: Int?
        var farExportedPoints: Int?
    }
    struct Result: Sendable { var points: [CloudPoint]; var report: Report }

    /// Range priority is active only when it actually splits the accepted depth interval.
    static func nearPriorityRange(_ config: CaptureConfig) -> Float? {
        let range = config.fusionNearRangeM
        guard range.isFinite, range > config.pointMinDepthM, range < config.pointMaxDepthM else { return nil }
        return range
    }

    /// availableMemory is injectable to reproduce pressure appearing midway through a scan.
    static func refuseWithReport(records: [FrameRecord], sessionDir: URL, config: CaptureConfig,
                                 meshVertices: [SIMD3<Float>] = [], target: Int? = nil,
                                 diagnosticsDirectory: URL? = nil,
                                 availableMemory: () -> UInt64? = { availableMemoryBytes },
                                 memoryPressure: () -> Bool = { false },
                                 isCancelled: () -> Bool = { false },
                                 progress: @Sendable (Double) -> Void) -> Result {
        let jobStarted = Date()
        let warning = FusionMemoryWarning()
        var report = Report(totalFrames: records.count)
        report.diverseReferences = config.depthConsistencyEnabled && config.depthDiverseReferences
        report.rayConsensus = config.depthConsistencyEnabled && config.depthConsensusEnabled
        report.preparedDepthSampling = config.preparedDepthSampling
        let nearRange = nearPriorityRange(config)
        let farExclusion = nearRange == nil ? 0 : max(0, config.fusionFarExclusionM.isFinite ? config.fusionFarExclusionM : 0)
        let farScale = nearRange == nil ? 1 : max(1, config.fusionFarVoxelScale.isFinite ? config.fusionFarVoxelScale : 1)
        if let nearRange {
            report.nearRangeM = nearRange
            report.farExclusionM = farExclusion
            report.farVoxelSizeM = config.refuseVoxelSizeM * farScale
        }
        func persistReport() {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: (diagnosticsDirectory ?? sessionDir).appendingPathComponent("refusion-progress.json"), options: .atomic)
            } catch { print("融合診斷儲存失敗：\(error.localizedDescription)") }
        }
        func memorySnapshot() -> UInt64? {
            let bytes = availableMemory()
            if let bytes { report.minimumAvailableBytes = min(report.minimumAvailableBytes ?? bytes, bytes) }
            if let footprint = processFootprintBytes {
                report.peakProcessFootprintBytes = max(report.peakProcessFootprintBytes ?? 0, footprint)
            }
            report.memoryWarningCount = warning.count
            return bytes
        }
        let initialMemory = memorySnapshot()
        let boundedMemory = initialMemory != nil
        let outputLimit = boundedMemory
            ? max(0, min(target ?? config.exportMaxPoints, config.exportMaxPoints))
            : max(0, target ?? config.exportMaxPoints)
        report.effectiveOutputLimit = outputLimit
        report.boundedExport = boundedMemory
        report.exportSampling = boundedMemory ? "spatialUniform" : "stratifiedBest"
        let initialLimit = initialMemory.map {
            min(cellBudget(configured: config.refuseMaxCells, availableBytes: $0),
                workingSetCellLimit(megabytes: config.refuseMemoryBudgetMB))
        } ?? max(1, config.refuseMaxCells)
        report.initialCellLimit = initialLimit
        persistReport()
        func interrupted(status: String = "memoryPressure") -> Result {
            report.status = status
            report.wallSeconds = Date().timeIntervalSince(jobStarted)
            persistReport()
            return Result(points: [], report: report)
        }
        var interruptionStatus = "memoryPressure"
        func canContinue() -> Bool {
            if isCancelled() { interruptionStatus = "cancelled"; return false }
            if warning.count > 0 || memoryPressure() {
                report.memoryWarningCount = max(1,warning.count)
                report.memoryStopReason = "systemMemoryPressure"
                return false
            }
            if let bytes = memorySnapshot(), shouldStopForMemory(availableBytes: bytes) {
                report.memoryStopReason = "reservedHeadroom"
                return false
            }
            return true
        }
        guard canContinue() else { return interrupted(status: interruptionStatus) }
        // 位姿在進來之前就已經定案（ARKit ＋ 錨點修正，必要時再加 BA ——
        // 見 CaptureController.processScan）。這裡只負責融合。
        //
        // 先前這裡還有一條「以融合點雲為固定結構做幾何對齊」的路徑，已刪除：
        // 它用 voxel 佔用建立對應，而離線測試證明那在最該修正的方向（平面法向）
        // 完全收不到訊號 —— 沿法向偏 3cm 時 0/40000 點有對應。留著只是死碼。
        // 重投影誤差沒有這個盲點，那條路走 BundleAdjuster。

        var surface: SurfaceTSDF? = config.surfaceReconstruction
            ? SurfaceTSDF(voxel:config.refuseVoxelSizeM, budgetBytes:max(0,min(64,config.surfaceBudgetMB))*1_048_576) : nil
        var grid = FusedVoxelGrid(voxelSize: config.refuseVoxelSizeM,
                                  maxCells: initialLimit, farVoxelScale: farScale)
        let depthDir = sessionDir.appendingPathComponent("depth", isDirectory: true)
        let imagesDir = sessionDir.appendingPathComponent("images", isDirectory: true)
        let prefetch = config.prefetchFusionRGB && (initialMemory == nil || initialMemory! >= 512*1_048_576)
            ? FusionRGBPrefetch() : nil
        report.rgbPrefetch = prefetch != nil
        func startDecode(_ index: Int) {
            guard records.indices.contains(index),let prefetch else { return }
            let r = records[index]
            let required = frameHeadroomBytes(width:r.depthWidth,height:r.depthHeight)
            let allowed = !isCancelled() && warning.count == 0 && (availableMemory().map { $0 >= required } ?? true)
            prefetch.start {
                let started = Date()
                let pixels: [UInt8]?
                if allowed, r.blurVerdict != .drop, r.depthFile != nil, r.transform.count == 16,
                   r.imageFile == (r.imageFile as NSString).lastPathComponent,
                   let w = r.depthWidth,let h = r.depthHeight,w > 0,h > 0,w <= 4096,h <= 4096 {
                    pixels = decodeRGBA(url:imagesDir.appendingPathComponent(r.imageFile),width:w,height:h)
                } else { pixels = nil }
                return FusionRGBPrefetch.Image(pixels:pixels,seconds:Date().timeIntervalSince(started))
            }
        }
        startDecode(0)
        let total = max(1, records.count)
        // 分段計時：先前只能靠估算猜哪一段慢，實際數字才有依據。
        // tProduce 與 tInsert 一定要分開 —— 前者可以平行、後者不行（共享 grid），
        // 先前兩者混在同一個 tUnproject 裡，等於看不出並行化的上限在哪。
        var tProduce: Double = 0, tInsert: Double = 0, tMesh: Double = 0, tDecode: Double = 0
        var depthCache = DepthViewCache()
        let referenceSelection = DepthReferenceSelection(records: records)

        /// 一幀的產出。純函式、不碰共享狀態 —— 所以可以平行跑。
        struct FrameYield {
            var measured: [CloudPoint] = []
            /// Measured beyond the near range: fused separately, kept only where no near surface exists.
            var far: [CloudPoint] = []
            var mesh: [CloudPoint] = []
            var decodeSec: Double = 0
            var meshSec: Double = 0
            var surfaceView: DepthConsistencyView?
        }

        func produce(_ index: Int, decoded: FusionRGBPrefetch.Image?) -> FrameYield {
            let readStart = ProcessInfo.processInfo.systemUptime
            let r = records[index]
            var y = FrameYield()
            // 幾何不可信的幀直接跳過：它的深度會被反投影到錯的世界座標，疊出殘影／雙層殼。
            // 殘影比破洞更糟 —— 破洞看得出來，殘影會被當成真的幾何。
            // 注意這裡**不**跳過 .demote：那些只是顏色糊，幾何來自 LiDAR、照樣可信，
            // 丟了只會白白開洞。它們改以降權併入（見下）。
            //
            // 這個檢查先前排在 JPEG 解碼**之後** —— 被排除的幀白白付了一次解碼。
            if r.blurVerdict == .drop || r.transform.count != 16 || !r.transform.allSatisfy(\.isFinite) { return y }
            guard let depthFile = r.depthFile,
                  let dw = r.depthWidth, let dh = r.depthHeight, dw > 0, dh > 0, dw <= 4096, dh <= 4096,
                  r.intrinsics.width > 0, r.intrinsics.height > 0,
                  r.intrinsics.fx.isFinite, r.intrinsics.fy.isFinite, r.intrinsics.fx > 0, r.intrinsics.fy > 0,
                  r.intrinsics.cx.isFinite, r.intrinsics.cy.isFinite,
                  depthFile == (depthFile as NSString).lastPathComponent,
                  (try? depthDir.appendingPathComponent(depthFile).resourceValues(forKeys: [.fileSizeKey]).fileSize) == dw * dh * 4,
                  let depth = try? Data(contentsOf: depthDir.appendingPathComponent(depthFile)),
                  depth.count == dw * dh * 4 else { return y }

            var conf: [UInt8]?
            if let confFile = r.confidenceFile,
               let confData = try? Data(contentsOf: depthDir.appendingPathComponent(confFile)),
               confData.count == dw * dh {
                conf = [UInt8](confData)
            }
            report.depthReadSeconds += ProcessInfo.processInfo.systemUptime - readStart
            let tD = Date()
            let pixels = decoded != nil ? decoded!.pixels : decodeRGBA(url:imagesDir.appendingPathComponent(r.imageFile),width:dw,height:dh)
            guard let rgba = pixels else { return y }
            y.decodeSec = decoded?.seconds ?? Date().timeIntervalSince(tD)

            let K = r.intrinsics.scaled(toWidth: dw, height: dh)
            let c2w = float4x4(rowMajor: r.transform)
            if surface != nil { y.surfaceView = DepthConsistencyView(depth:depth,confidence:conf,intrinsics:K,c2w:c2w) }
            // 權重同時吃兩個來源：估計的幾何劣化（運動/捲簾）與實測的清晰度判定。
            // 原本只看 estimatedBlurPx，於是「相機拿得很穩但失焦」的幀拿到滿分權重，
            // 它糊掉的顏色會主導那格的加權平均 —— 這是實測清晰度才看得到的破口。
            let sharpness = blurWeight(Float(r.estimatedBlurPx), config)
            let unprojectStart = ProcessInfo.processInfo.systemUptime
            y.measured = unprojectStored(depth: depth, conf: conf, rgba: rgba,
                                         dw: dw, dh: dh, K: K, c2w: c2w,
                                         config: config, sharpness: sharpness)
            report.unprojectSeconds += ProcessInfo.processInfo.systemUptime - unprojectStart
            let consistencyStart = ProcessInfo.processInfo.systemUptime
            // Bounded neighbor window: at most four depth maps per worker, never the full scan.
            // Compare corrected poses and raw depth before voxels hide the source observations.
            var neighbors: [DepthConsistencyView] = []
            if config.depthConsistencyEnabled {
                let referenceIndices = config.depthDiverseReferences ? referenceSelection.indices(for: index)
                    : [1, -1, 2, -2, 3, -3, 4, -4].map { index + $0 }
                for other in referenceIndices {
                    guard records.indices.contains(other), records[other].id != r.id,
                          abs(records[other].timestamp - r.timestamp) >= 0.05,
                          records[other].blurVerdict != .drop,
                          let view = depthCache.view(index: other, load: {
                              var view = storedDepthView(records[other], directory: depthDir)
                              if config.preparedDepthSampling { view?.prepareSampling(config:config) }
                              return view
                          }) else { continue }
                    neighbors.append(view)
                    if neighbors.count == 4 { break }
                }
                if config.depthConsensusEnabled {
                    y.measured = DepthConsistencyView.consensus(y.measured,
                        camera: SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z),
                        against: neighbors, config: config)
                } else {
                    y.measured = DepthConsistencyView.filter(y.measured, against: neighbors, config: config)
                }
            }
            if let nearRange {
                // Camera-space depth; the ray consensus shifts points by at most a few cm.
                let camera = SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z)
                let forward = -SIMD3(c2w.columns.2.x, c2w.columns.2.y, c2w.columns.2.z)
                var near: [CloudPoint] = []
                near.reserveCapacity(y.measured.count)
                for point in y.measured {
                    if simd_dot(SIMD3(point.x, point.y, point.z) - camera, forward) <= nearRange {
                        near.append(point)
                    } else { y.far.append(point) }
                }
                y.measured = near
            }
            report.consistencySeconds += ProcessInfo.processInfo.systemUptime - consistencyStart
            // mesh 頂點：投影進本幀取色。同一頂點會被多幀命中 → 由 voxel 加權平均做多視角混色。
            if !meshVertices.isEmpty {
                let tM = Date()
                y.mesh = projectMesh(meshVertices, depth: depth, rgba: rgba, dw: dw, dh: dh,
                                     K: K, c2w: c2w, config: config, sharpness: sharpness)
                if config.depthConsistencyEnabled {
                    // Mesh must agree with this frame AND another measured view; the old 10cm
                    // color tolerance alone could refill rejected geometry with a second shell.
                    if let own = DepthConsistencyView(depth: depth, confidence: conf, intrinsics: K, c2w: c2w) {
                        y.mesh = DepthConsistencyView.filter(y.mesh, against: [own], config: config)
                        // Mesh may fill holes, but must not bypass the measured-point support gate.
                        y.mesh = DepthConsistencyView.filter(y.mesh, against: neighbors, config: config,
                            minimumSupports: config.depthConsensusEnabled ? max(1, min(2, neighbors.count)) : 1)
                    } else { y.mesh = [] }
                }
                y.meshSec = Date().timeIntervalSince(tM)
            }
            return y
        }

        // One owned frame at a time: no retained batch of projected mesh and depth points.
        // Re-check headroom before decoding, inserting, and exporting, not only at startup.
        let lanes = 1
        var cellLimit = initialLimit
        func adaptCapacity(to bytes: UInt64) -> Bool {
            if bytes < 512 * 1_024 * 1_024, let volume = surface {
                report.surface = volume.report; report.surface?.status = "memoryFallback"; surface = nil
            }
            if bytes < 384 * 1_024 * 1_024 { depthCache.clear() }
            let limit = pressureCellLimit(currentLimit: cellLimit, currentCells: grid.count, availableBytes: bytes)
            if limit < cellLimit {
                guard grid.reduceCapacity(to: limit, shouldContinue: canContinue) else { return false }
                cellLimit = limit
                report.capacityReductions += 1
            }
            return true
        }
        for i in records.indices {
            guard canContinue() else { return interrupted(status: interruptionStatus) }
            if let bytes = memorySnapshot() {
                let required = frameHeadroomBytes(width: records[i].depthWidth, height: records[i].depthHeight)
                report.requiredFrameHeadroomBytes = max(report.requiredFrameHeadroomBytes ?? 0, required)
                guard bytes >= required else {
                    report.memoryStopReason = "frameWorkspace"; return interrupted()
                }
                guard adaptCapacity(to: bytes) else { return interrupted(status: interruptionStatus) }
            }
            let tP = Date()
            let decoded = prefetch?.take()
            guard canContinue() else { return interrupted(status:interruptionStatus) }
            if prefetch != nil {
                report.rgbWaitSeconds = (report.rgbWaitSeconds ?? 0) + Date().timeIntervalSince(tP)
                startDecode(i+1)
            }
            let produced = autoreleasepool { produce(i,decoded:decoded) }
            tProduce += Date().timeIntervalSince(tP)
            guard canContinue() else { return interrupted(status: interruptionStatus) }
            if let bytes = memorySnapshot() {
                guard adaptCapacity(to: bytes) else { return interrupted(status: interruptionStatus) }
            }
            let tI = Date()
            guard grid.insert(produced.measured, boundedMemory: boundedMemory, shouldContinue: canContinue),
                  grid.insert(produced.mesh, measured: false, boundedMemory: boundedMemory, shouldContinue: canContinue),
                  grid.insert(produced.far, far: true, boundedMemory: boundedMemory, shouldContinue: canContinue) else {
                return interrupted(status: interruptionStatus)
            }
            if let volume = surface {
                let pose = records[i].transform
                if pose.count == 16 {
                    let camera = SIMD3(Float(pose[3]),Float(pose[7]),Float(pose[11]))
                    let integrated = volume.integrate(produced.measured,camera:camera,frame:i,view:produced.surfaceView,shouldContinue:canContinue)
                    report.surface = volume.report
                    if !integrated { surface = nil }
                    guard canContinue() else { return interrupted(status:interruptionStatus) }
                }
            }
            tInsert += Date().timeIntervalSince(tI)
            tDecode += produced.decodeSec
            tMesh += produced.meshSec
            report.completedFrames = i + 1
            report.peakCells = max(report.peakCells, grid.count)
            report.depthCacheHits = depthCache.hits
            report.depthCacheLoads = depthCache.loads
            report.depthCachePeakBytes = depthCache.peakBytes
            report.depthCachePeakEntries = depthCache.peakEntries
            if i % 8 == 0 || i == records.count - 1 { persistReport() }
            progress(Double(i + 1) / Double(total) * 0.9)
        }
        report.stage = "exportFilter"
        report.finalVoxelSizeM = grid.voxelSize
        depthCache.clear()
        persistReport()
        guard canContinue() else { return interrupted(status: interruptionStatus) }
        // 診斷：這條鏈上有三處會悄悄粗化解析度（融合格觸頂、匯出擇優下採樣、訓練高斯預算），
        // 而初始點距直接決定初始高斯大小（依外部訓練器的初始化方式而定）。
        // 過去完全沒有數字，訓練端看到 15cm 的初始高斯卻無從得知是哪一段造成的。
        // 串流產出與插入分開計時；JPEG／mesh 是產出內的子階段。
        print(String(format: "  重融合分段: 產出 %.2fs（%d 路串流；其中牆鐘時間 "
                     + "JPEG 解碼 %.2fs、mesh 投影 %.2fs）、插入 grid %.2fs（序列）、%d 幀",
                     tProduce, lanes, tDecode, tMesh, tInsert, records.count))
        print(String(format: "  深度分段: 讀取 %.2fs、反投影 %.2fs、一致性驗證（含鄰幀）%.2fs；快取峰值 %.2f MiB / %d 幀",
                     report.depthReadSeconds, report.unprojectSeconds, report.consistencySeconds,
                     Double(report.depthCachePeakBytes) / 1_048_576, report.depthCachePeakEntries))
        let rawCells = grid.count
        let inferredOnly = grid.inferredOnlyCount
        let gridVoxel = grid.voxelSize
        var outputVoxel = gridVoxel
        let tE = Date()
        // On device, use a bounded pass rather than a full cloud + downsampling dictionary.
        report.boundedExport = boundedMemory
        var out: [CloudPoint]
        var exportStats = FusedVoxelGrid.ExportStats()
        if boundedMemory {
            var lastPersisted = -1
            guard let exported = grid.consumeExportPoints(target: outputLimit,
                minNeighbors: config.refuseMinNeighbors, farExclusion: farExclusion,
                shouldContinue: canContinue, progress: { fraction in
                    report.exportFraction = fraction
                    report.stage = fraction < 0.5 ? "exportFilter" : "exportPoints"
                    report.exportSeconds = Date().timeIntervalSince(tE)
                    let bucket = Int(fraction * 10)
                    if bucket != lastPersisted { persistReport(); lastPersisted = bucket }
                    progress(0.9 + fraction * (config.surfaceReconstruction ? 0.05 : 0.1))
                }) else { return interrupted(status: interruptionStatus) }
            out = exported
            exportStats = grid.lastExport
        } else {
            let exported = grid.exportPointsWithStats(target: outputLimit, minNeighbors: config.refuseMinNeighbors,
                                                      farExclusion: farExclusion)
            out = exported.points
            exportStats = exported.stats
        }
        if nearRange != nil {
            report.farVoxelSizeM = gridVoxel * grid.farVoxelScale
            report.farCells = exportStats.farCells
            report.farExcludedNearSurface = exportStats.farExcludedNearSurface
            report.farExportedPoints = exportStats.farExported
        }
        if let volume = surface {
            report.stage = "surfaceExport"; persistReport(); progress(0.95)
            if let extracted = volume.extract(limit:outputLimit,shouldContinue:canContinue),
               let reconstructed = volume.preservingUnsupported(extracted,fallback:out,limit:outputLimit,shouldContinue:canContinue),
               reconstructed.count >= max(1,Int(Float(out.count)*0.35)) {
                out = reconstructed; outputVoxel = volume.voxel
            } else if volume.report.status.hasPrefix("completed") {
                report.surface = volume.report; report.surface?.status = "densityFallback"
            }
            if report.surface?.status != "densityFallback" { report.surface = volume.report }
            surface = nil
            guard canContinue() else { return interrupted(status:interruptionStatus) }
        }
        if config.surfaceVisibilityValidation, config.depthConsistencyEnabled,
           report.surface?.status.hasPrefix("completed") == true {
            report.stage = "surfaceValidation"; persistReport(); progress(0.97)
            report.surfaceValidation = SurfaceVisibilityValidator.validate(&out,
                references:SurfaceVisibilityValidator.referenceIndices(records),config:config,
                load:{ storedDepthView(records[$0],directory:depthDir) },shouldContinue:canContinue,
                progress:{progress(0.97+$0*0.025)})
            guard canContinue() else { return interrupted(status:interruptionStatus) }
        }
        report.exportSeconds = Date().timeIntervalSince(tE)
        print(String(format: "  匯出擇優 %.2fs（%d 格 → %d 點）",
                     Date().timeIntervalSince(tE), rawCells, out.count))
        var msg = "Refusion: \(records.count) frames"
        if !meshVertices.isEmpty { msg += " + \(meshVertices.count) mesh verts" }
        msg += " -> \(rawCells) cells @ "
        msg += String(format: "%.3f", gridVoxel) + "m"
        if gridVoxel > config.refuseVoxelSizeM {
            let steps = Int((log2(Double(gridVoxel / config.refuseVoxelSizeM))).rounded())
            msg += String(format: " (觸頂粗化 %d 次，設定值 %.3fm)", steps, config.refuseVoxelSizeM)
        }
        msg += " -> 匯出 \(out.count) 點（本次上限 \(outputLimit)）"
        if let nearRange {
            msg += String(format: "；%.1fm 外深度 %d 格，其中 %d 格貼近近距表面而捨棄、%d 點補入未覆蓋表面",
                          nearRange, exportStats.farCells, exportStats.farExcludedNearSurface, exportStats.farExported)
        }
        if inferredOnly > 0 {
            let pct = Double(inferredOnly) * 100 / Double(max(1, rawCells))
            msg += String(format: "；其中 %d 格(%.1f%%) 是 LiDAR 沒覆蓋、只靠 ARKit mesh 撐著",
                          inferredOnly, pct)
        }
        if out.count < rawCells {
            msg += "，過濾／取樣移除 \(rawCells - out.count) 格"
        }
        // Xcode's stderr transport can close during a long device run. The legacy
        // FileHandle.write raises an Objective-C exception (SIGABRT), outside Swift catch.
        // Unified logging must never decide whether completed scan data is published.
        Logger(subsystem: "itri.fable", category: "Refusion").info("\(msg, privacy: .public)")
        report.status = "completed"
        report.wallSeconds = Date().timeIntervalSince(jobStarted)
        report.stage = "finished"
        report.outputPoints = out.count
        report.finalVoxelSizeM = outputVoxel
        persistReport()
        progress(1)
        return Result(points: out, report: report)
    }

    static func storedDepthView(_ r: FrameRecord, directory: URL) -> DepthConsistencyView? {
        guard r.transform.count == 16, r.transform.allSatisfy(\.isFinite),
              let name = r.depthFile, let w = r.depthWidth, let h = r.depthHeight,
              w > 1, h > 1, w <= 4096, h <= 4096,
              name == (name as NSString).lastPathComponent,
              (try? directory.appendingPathComponent(name).resourceValues(forKeys:[.fileSizeKey]).fileSize) == w*h*4,
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)), data.count == w * h * 4 else { return nil }
        var confidence: [UInt8]?
        if let file = r.confidenceFile {
            guard file == (file as NSString).lastPathComponent,
                  (try? directory.appendingPathComponent(file).resourceValues(forKeys:[.fileSizeKey]).fileSize) == w*h,
                  let bytes = try? Data(contentsOf: directory.appendingPathComponent(file)), bytes.count == w * h else { return nil }
            confidence = [UInt8](bytes)
        }
        return DepthConsistencyView(depth: data, confidence: confidence,
                                    intrinsics: r.intrinsics.scaled(toWidth: w, height: h),
                                    c2w: float4x4(rowMajor: r.transform))
    }

    /// simd_float4x4 → row-major 16（FrameRecord.transform 的格式）
    static func rowMajor(_ m: simd_float4x4) -> [Double] {
        (0..<4).flatMap { r in (0..<4).map { c in Double(m[c][r]) } }
    }

    /// 模糊 → 融合權重。曲線與錨點見 CaptureConfig.blurWeightPower。
    ///
    /// 以 refPx 錨定的用意：power 只該改變「幀之間的相對輕重」。若直接取 base^power，
    /// 所有權重會一起縮小數十倍，而匯出端的 `min(1, weight/1.5)` 是有飽和點的 ——
    /// 那會連帶改變下採樣的選點，把一個「相對權重」的實驗混進「絕對尺度」的副作用。
    @inline(__always)
    static func blurWeight(_ blurPx: Float, _ config: CaptureConfig) -> Float {
        let half = max(0.1, config.blurWeightHalfPx)
        let base = 1 / (1 + max(0, blurPx) / half)
        let p = config.blurWeightPower
        guard p != 1 else { return base }          // 預設路徑：與舊寫法逐位元相同
        let ref = 1 / (1 + max(0, config.blurWeightRefPx) / half)
        return pow(base, p) * pow(ref, 1 - p)
    }

    static func float4x4(rowMajor m: [Double]) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(Float(m[0]), Float(m[4]), Float(m[8]), Float(m[12])),
            SIMD4<Float>(Float(m[1]), Float(m[5]), Float(m[9]), Float(m[13])),
            SIMD4<Float>(Float(m[2]), Float(m[6]), Float(m[10]), Float(m[14])),
            SIMD4<Float>(Float(m[3]), Float(m[7]), Float(m[11]), Float(m[15]))))
    }

    // 註：先前這裡有一個 kDemotedColorWeight = 0.2，註解寫「只降顏色權重」——
    // 但 score 是**單一權重**，同時決定位置與顏色的加權平均，所以它其實也把幾何
    // 一起壓到 1/5。在覆蓋率吃緊（實機 26.4% 的格子沒有 LiDAR）的情況下這是反效果，
    // 故移除。運動模糊本來就有物理權重 1/(1+blur/4) 壓著；
    // 失焦則完全不影響幾何，本來就不該罰。
    /// 把 mesh 頂點投影進一個關鍵幀取色，並用該幀的深度圖做可見性檢核。
    /// 分數刻意壓低（×kMeshScore）：同格若有 LiDAR 直接觀測，加權平均由 LiDAR 主導；
    /// mesh 只在「關鍵幀沒拍到」的空格補洞，不會稀釋既有的良好觀測。
    private static let kMeshScore: Float = 0.25

    private static func projectMesh(_ verts: [SIMD3<Float>], depth: Data, rgba: [UInt8],
                                    dw: Int, dh: Int, K: CameraIntrinsics,
                                    c2w: simd_float4x4, config: CaptureConfig,
                                    sharpness: Float) -> [CloudPoint] {
        let fx = Float(K.fx), fy = Float(K.fy), cx = Float(K.cx), cy = Float(K.cy)
        let w2c = c2w.inverse
        let minD = config.pointMinDepthM, maxD = config.pointMaxDepthM
        let tol = config.meshColorDepthTolM

        return depth.withUnsafeBytes { raw -> [CloudPoint] in
            let d = raw.bindMemory(to: Float32.self)
            var out: [CloudPoint] = []
            out.reserveCapacity(verts.count / 8)
            for p in verts {
                let cam = w2c * SIMD4<Float>(p, 1)
                // 相機系為 GL 慣例（-Z 前方）→ 可視深度 z = -cam.z
                let z = -cam.z
                if !(z > minD && z < maxD) { continue }
                let u = fx * (cam.x / z) + cx
                let v = fy * (-cam.y / z) + cy
                guard u.isFinite, v.isFinite, u >= 0, v >= 0, u < Float(dw), v < Float(dh) else { continue }
                let iu = Int(u), iv = Int(v)
                if iu < 0 || iv < 0 || iu >= dw || iv >= dh { continue }
                // 可見性：與該幀量到的深度一致才算「這一幀真的看到它」，否則是被遮擋的背面
                let zm = d[iv * dw + iu]
                if !zm.isFinite || abs(zm - z) > tol { continue }
                let px = (iv * dw + iu) * 4
                let ru = (u - cx) / Float(dw), rv = (v - cy) / Float(dh)
                let central = 1 - min(1, (ru * ru + rv * rv).squareRoot() * 1.4) * 0.5
                let near = 1 / (0.2 + z * z)
                out.append(CloudPoint(x: p.x, y: p.y, z: p.z,
                                      r: rgba[px], g: rgba[px + 1], b: rgba[px + 2],
                                      score: central * near * sharpness * kMeshScore))
            }
            return out
        }
    }

    private static func unprojectStored(depth: Data, conf: [UInt8]?, rgba: [UInt8],
                                        dw: Int, dh: Int, K: CameraIntrinsics,
                                        c2w: simd_float4x4, config: CaptureConfig,
                                        sharpness: Float) -> [CloudPoint] {
        let fx = Float(K.fx), fy = Float(K.fy), cx = Float(K.cx), cy = Float(K.cy)
        let minD = config.pointMinDepthM
        let maxD = config.pointMaxDepthM
        let minConf = config.minDepthConfidence
        let stride = max(1, config.refuseSampleStride)

        return depth.withUnsafeBytes { raw -> [CloudPoint] in
            let d = raw.bindMemory(to: Float32.self)
            var out: [CloudPoint] = []
            out.reserveCapacity((dw / stride) * (dh / stride))
            var v = 0
            while v < dh {
                var u = 0
                while u < dw {
                    let i = v * dw + u
                    let z = d[i]
                    let cv = conf?[i] ?? 2
                    if z.isFinite, z > minD, z < maxD, cv >= minConf {
                        if let incidence = DepthSampleFilter.incidenceWeight(
                            depth: d, confidence: conf, u: u, v: v, width: dw, height: dh,
                            K: K, config: config) {
                            let xc = (Float(u) - cx) / fx * z
                            let yc = (Float(v) - cy) / fy * z
                            let w4 = c2w * SIMD4<Float>(xc, -yc, -z, 1)
                            let px = i * 4
                            let ru = (Float(u) - cx) / Float(dw)
                            let rv = (Float(v) - cy) / Float(dh)
                            let central = 1 - min(1, (ru * ru + rv * rv).squareRoot() * 1.4) * 0.5
                            let near = 1 / (0.2 + z * z)   // 反變異數：LiDAR 雜訊 ∝ z²，遠點大幅降權
                            let confW: Float = cv >= 2 ? 1 : config.mediumConfidenceWeight
                            out.append(CloudPoint(x: w4.x, y: w4.y, z: w4.z,
                                                  r: rgba[px], g: rgba[px + 1], b: rgba[px + 2],
                                                  // cos²θ：掠射樣本降到 3% 左右
                                                  // （80° → cos²=0.03），正面觀測因此
                                                  // 一進來就主導這一格的加權平均
                                                  score: central * near * sharpness
                                                         * confW * incidence))
                        }
                    }
                    u += stride
                }
                v += stride
            }
            return out
        }
    }

    /// 每格的實際記憶體成本（位元組）。
    /// 包含 SIMD 對齊、字典空位與擴容餘裕；這是預算估計，並非實測 RSS。
    private static let kBytesPerCell = 128

    /// 依「現在**還能**用多少記憶體」夾住格數上限。
    ///
    /// Reserve room for ARKit, output arrays, dictionary growth and coarsening. In particular,
    /// never impose a 200k-cell minimum when the available memory cannot afford it.
    static func cellBudget(configured: Int, availableBytes: UInt64) -> Int {
        let reserve = processingReserveBytes
        let usable = availableBytes > reserve ? availableBytes - reserve : 0
        let cells = usable / 4 / UInt64(kBytesPerCell)
        return max(1, min(max(1, configured), Int(min(cells, UInt64(Int.max)))))
    }

    static var availableMemoryBytes: UInt64? {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return nil
        #endif
    }

    static func workingSetCellLimit(megabytes: Int) -> Int {
        max(1, min(max(1, megabytes), 512) * 1_024 * 1_024 / kBytesPerCell)
    }

    static let processingReserveBytes: UInt64 = 192 * 1_024 * 1_024

    /// Account for candidate arrays, decoding, current depth and up to four references before allocation.
    static func frameHeadroomBytes(width: Int?, height: Int?) -> UInt64 {
        let w = min(4096,max(0,width ?? 0)), h = min(4096,max(0,height ?? 0))
        return processingReserveBytes + max(32 * 1_024 * 1_024, UInt64(w) * UInt64(h) * 96)
    }

    static var processFootprintBytes: UInt64? {
        #if os(iOS)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
        #else
        return nil
        #endif
    }

    static func shouldStopForMemory(availableBytes: UInt64) -> Bool {
        availableBytes < processingReserveBytes
    }

    static func pressureCellLimit(currentLimit: Int, currentCells: Int, availableBytes: UInt64) -> Int {
        guard availableBytes < 384 * 1_024 * 1_024 else { return currentLimit }
        // Include the existing grid when recalculating; otherwise every sample would shrink
        // the budget simply because this same grid has consumed memory since the last sample.
        let existing = UInt64(max(0, currentCells)) * UInt64(kBytesPerCell)
        let (sum, overflow) = availableBytes.addingReportingOverflow(existing)
        return cellBudget(configured: currentLimit, availableBytes: overflow ? UInt64.max : sum)
    }

    static func meshSampleStride(vertexCount: Int, limit: Int) -> Int {
        guard vertexCount > 0 else { return 1 }
        let limit = max(1, limit)
        return max(1, vertexCount / limit + (vertexCount % limit == 0 ? 0 : 1))
    }

    static var hasOptionalProcessingHeadroom: Bool {
        #if os(iOS)
        let available = os_proc_available_memory()
        return available >= 128 * 1_024 * 1_024
        #else
        return true
        #endif
    }

    static func safeMaxCells(_ configured: Int) -> Int {
        #if !os(iOS)
        return max(1, configured)
        #else
        let available = os_proc_available_memory()
        let capped = available > 0 ? cellBudget(configured: configured, availableBytes: UInt64(available))
                                   : min(max(1, configured), 250_000)
        if capped < configured { print("重融合記憶體保護：格數上限 \(configured) → \(capped)") }
        return capped
        #endif
    }

    /// JPEG →（縮圖解碼）→ 深度解析度的緊湊 RGBA buffer。
    /// CGBitmapContext 第 0 列對應影像頂列，與深度圖的 v 方向一致
    /// （由 check harness 的顏色-座標相關性測試驗證）。
    private static func decodeRGBA(url: URL, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }
}
