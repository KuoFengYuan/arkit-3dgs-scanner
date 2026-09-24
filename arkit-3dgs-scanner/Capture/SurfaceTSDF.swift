import Foundation
import simd

/// Sparse 8³ blocks and a narrow signed-distance band. Never expands its allocation budget.
/// A failed/cancelled volume is discarded; the independent voxel fusion remains the fallback.
nonisolated final class SurfaceTSDF {
    struct Cell {
        var distance: Float = 0
        var weight: Float = 0
        var r: Float = 0
        var g: Float = 0
        var b: Float = 0
        var lastFrame: Int32 = -1
        var views: UInt16 = 0
        var packedNormal: UInt16 = 0
    }
    final class Block { var cells = [Cell](repeating: Cell(), count: 512); var accessed = 0; var dirty = false }
    struct Key: Hashable, Comparable {
        let x: Int32, y: Int32, z: Int32
        static func < (a: Self, b: Self) -> Bool {
            if a.x != b.x { return a.x < b.x }; if a.y != b.y { return a.y < b.y }; return a.z < b.z
        }
    }
    struct Report: Codable, Sendable {
        var status = "integrating"
        var peakBlocks = 0
        var allocatedBytes = 0
        var surfaceCoverage: Float = 0
        var crossings = 0
        var seconds = 0.0
        var spilledBlocks = 0
        var blockReads = 0
        var blockWrites = 0
        var diskBytes = 0
        var fallbackPoints = 0
        var farReservePoints: Int?
        var peakMergePoints: Int?
        // Optional for compatibility with scans saved before packed paging.
        var storageReadOperations: Int? = 0
        var storageWriteOperations: Int? = 0
        var storageReadSeconds: Double? = 0
        var storageWriteSeconds: Double? = 0
    }
    private var blocks: [Key: Block] = [:]
    private var surfaceBlocks = Set<Key>()
    private final class Mask { var bits = [UInt64](repeating:0,count:8) }
    private var supportedCells: [Key:Mask] = [:]
    private var knownBlocks = Set<Key>()
    // Fixed-size slots in one private scratch file; overwriting a dirty slot never grows disk use.
    private var savedSlots: [Key: Int] = [:]
    private var backing: FileHandle?
    private var tick = 0
    private var scratch: URL?
    private let diskBudgetBytes: Int
    private let pagingEnabled: Bool
    private let cacheBlockLookups: Bool
    private let recordNormals: Bool
    private(set) var report = Report()
    let voxel: Float
    let truncation: Float
    let maxBlocks: Int
    static var blockBytes: Int { 512 * MemoryLayout<Cell>.stride + 256 }

    init(voxel: Float = 0.02, budgetBytes: Int = 32 * 1_048_576, diskBudgetBytes: Int = 256 * 1_048_576, pagingEnabled: Bool = true, cacheBlockLookups: Bool = true, recordNormals: Bool = false) {
        self.recordNormals = recordNormals
        self.cacheBlockLookups = cacheBlockLookups
        self.diskBudgetBytes = max(0,diskBudgetBytes); self.pagingEnabled = pagingEnabled
        self.voxel = max(0.01, min(0.05, voxel.isFinite ? voxel : 0.02))
        truncation = self.voxel * 3
        maxBlocks = max(0, budgetBytes / Self.blockBytes)
    }
    deinit {
        try? backing?.close()
        if let scratch { try? FileManager.default.removeItem(at:scratch) }
    }
    private static var payloadBytes: Int { 512 * MemoryLayout<Cell>.stride }

    /// One eviction batch is at most 32 blocks. Contiguous slots share a single write; live
    /// blocks, pending data and slot metadata remain bounded. This file is disposable, not a
    /// persisted scan: any short read/write error invalidates the entire TSDF and uses the grid.
    private func spill(_ victims: [(key: Key, value: Block)]) throws -> Bool {
        if backing == nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("surface-blocks-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            scratch = directory
            let url = directory.appendingPathComponent("blocks.bin")
            guard FileManager.default.createFile(atPath:url.path,contents:nil) else { return false }
            backing = try FileHandle(forUpdating:url)
        }
        guard let backing else { return false }
        var writes: [(slot: Int, block: Block)] = []
        for (key, block) in victims where block.dirty || savedSlots[key] == nil {
            let slot: Int
            if let existing = savedSlots[key] { slot = existing }
            else {
                guard savedSlots.count < diskBudgetBytes / Self.blockBytes else {
                    report.status = "diskBudgetFallback"; return false
                }
                slot = savedSlots.count; savedSlots[key] = slot
            }
            writes.append((slot,block))
        }
        writes.sort { $0.slot < $1.slot }
        var i = 0
        while i < writes.count {
            let start = writes[i].slot
            var data = Data()
            data.reserveCapacity(min(32,writes.count-i) * Self.payloadBytes)
            repeat {
                writes[i].block.cells.withUnsafeBytes { data.append(contentsOf:$0) }
                i += 1
            } while i < writes.count && writes[i].slot == start + data.count / Self.payloadBytes
            let started = Date()
            try backing.seek(toOffset:UInt64(start * Self.payloadBytes))
            try backing.write(contentsOf:data)
            report.storageWriteSeconds = (report.storageWriteSeconds ?? 0) + Date().timeIntervalSince(started)
            report.storageWriteOperations = (report.storageWriteOperations ?? 0) + 1
            report.blockWrites += data.count / Self.payloadBytes
        }
        for (key, _) in victims { blocks.removeValue(forKey:key) }
        report.spilledBlocks = savedSlots.count
        report.diskBytes = savedSlots.count * Self.blockBytes
        return true
    }
    private func block(_ key: Key, create: Bool) -> Block? {
        tick += 1
        if let existing = blocks[key] { existing.accessed = tick; return existing }
        guard create || knownBlocks.contains(key) else { return nil }
        guard maxBlocks > 0 else { report.status = "capacityFallback"; return nil }
        if blocks.count >= maxBlocks {
            guard pagingEnabled else { report.status = "capacityFallback"; return nil }
            do {
                let victims = Array(blocks.sorted { $0.value.accessed < $1.value.accessed }.prefix(min(32,maxBlocks)))
                guard try spill(victims) else {
                    if report.status == "integrating" { report.status = "storageFallback" }
                    return nil
                }
            } catch { report.status = "storageFallback"; return nil }
        }
        // Bound the metadata/index as well as the backing data, even when the scan spans new blocks.
        if !knownBlocks.contains(key), knownBlocks.count >= maxBlocks + diskBudgetBytes/Self.blockBytes {
            report.status = "diskBudgetFallback"; return nil
        }
        let block = Block()
        if let slot = savedSlots[key] {
            do {
                guard let backing else { report.status = "storageFallback"; return nil }
                let started = Date()
                try backing.seek(toOffset:UInt64(slot * Self.payloadBytes))
                guard let data = try backing.read(upToCount:Self.payloadBytes),data.count == Self.payloadBytes else {
                    report.status = "storageFallback"; return nil
                }
                _ = block.cells.withUnsafeMutableBytes { data.copyBytes(to:$0) }
                report.storageReadSeconds = (report.storageReadSeconds ?? 0) + Date().timeIntervalSince(started)
                report.storageReadOperations = (report.storageReadOperations ?? 0) + 1
                report.blockReads += 1
            } catch { report.status = "storageFallback"; return nil }
        }
        block.accessed = tick; blocks[key] = block; knownBlocks.insert(key)
        report.peakBlocks = max(report.peakBlocks,blocks.count)
        report.allocatedBytes = report.peakBlocks*Self.blockBytes
        return block
    }
    private func address(_ p: SIMD3<Float>) -> (Key, Int, SIMD3<Int32>)? {
        let c = floor(p / voxel)
        guard c.x.isFinite, c.y.isFinite, c.z.isFinite, simd_reduce_max(abs(c)) < 1_000_000 else { return nil }
        let v = SIMD3<Int32>(Int32(c.x), Int32(c.y), Int32(c.z))
        return address(v)
    }
    private func address(_ v: SIMD3<Int32>) -> (Key, Int, SIMD3<Int32>) {
        // Arithmetic shift is floor division, including negative world coordinates.
        (Key(x: v.x >> 3, y: v.y >> 3, z: v.z >> 3), Int((v.x & 7) + 8 * (v.y & 7) + 64 * (v.z & 7)), v)
    }
    private func center(_ v: SIMD3<Int32>) -> SIMD3<Float> {
        (SIMD3(Float(v.x), Float(v.y), Float(v.z)) + 0.5) * voxel
    }
    @discardableResult
    func integrate(_ points: [CloudPoint], camera: SIMD3<Float>, frame: Int, view: DepthConsistencyView? = nil,
                   shouldContinue: () -> Bool = { true }) -> Bool {
        guard report.status == "integrating" else { return false }
        let started = Date(); defer { report.seconds += Date().timeIntervalSince(started) }
        guard frame >= 0, frame < Int(Int32.max) else { report.status = "invalidFrame"; return false }
        // Adjacent samples often continue in the last resident block. Keep one reference
        // across the frame, never across a paging operation without replacing it.
        var lastKey: Key?, lastBlock: Block?
        for (i, p) in points.enumerated() {
            if i % 256 == 0, !shouldContinue() { report.status = "interrupted"; return false }
            let position = SIMD3(p.x,p.y,p.z), delta = position-camera, range = simd_length(delta)
            guard range.isFinite, range > truncation, p.score.isFinite, p.score > 0,
                  let surface = address(position) else { continue }
            let ray = delta/range
            let normal: SIMD3<Float>
            if let view {
                guard let n = Self.normal(at:position,view:view) else { continue }
                normal = simd_dot(n,-ray) >= 0 ? n : -n
            } else { normal = -ray }
            let packedNormal = recordNormals ? PackedSurfaceNormal.encode(normal) : 0
            surfaceBlocks.insert(surface.0)
            // Half-voxel normal steps avoid holes along diagonals. A cell receives at most one
            // observation per frame, so higher sampling density cannot inflate confidence.
            if !cacheBlockLookups { lastKey = nil; lastBlock = nil }
            var previousVoxel: SIMD3<Int32>?
            for step in -6...6 {
                guard let (key,index,v) = address(position + normal * (Float(step) * voxel * 0.5)) else { continue }
                let block: Block
                if cacheBlockLookups, lastKey == key, let cached = lastBlock {
                    // Preserve observation order and LRU timestamps; avoid hashing the same
                    // block for every narrow-band voxel on the current surface sample.
                    tick += 1; cached.accessed = tick; block = cached
                } else {
                    guard let loaded = self.block(key,create:true) else {
                        blocks.removeAll(); surfaceBlocks.removeAll(); return false
                    }
                    block = loaded; lastKey = key; lastBlock = loaded
                }
                // Half-voxel steps can hit the same cell twice. LRU has already advanced;
                // its first observation is final for this frame, so no second array read.
                if cacheBlockLookups, previousVoxel == v { continue }
                previousVoxel = v
                var cell = block.cells[index]
                guard cell.lastFrame != Int32(frame) else { continue }
                let sdf = simd_dot(center(v)-position, normal)
                guard abs(sdf) <= truncation else { continue }
                let weight = max(0.05,min(1,p.score))
                let old = min(cell.weight, 24), sum = old+weight
                if cell.packedNormal == 0 { cell.packedNormal = packedNormal }
                cell.distance = (cell.distance*old + sdf*weight)/sum
                cell.r = (cell.r*old + Float(p.r)*weight)/sum
                cell.g = (cell.g*old + Float(p.g)*weight)/sum
                cell.b = (cell.b*old + Float(p.b)*weight)/sum
                cell.weight = sum; cell.lastFrame = Int32(frame)
                cell.views = min(65534,cell.views) + 1
                block.cells[index] = cell; block.dirty = true
            }
        }
        return true
    }
    /// Estimate a local surface normal without treating a sloped plane as a depth edge.
    private static func normal(at world: SIMD3<Float>, view: DepthConsistencyView) -> SIMD3<Float>? {
        let q = view.worldToCamera*SIMD4(world,1), z = -q.z, k = view.intrinsics
        guard z > 0.1 else { return nil }
        let u = Float(k.fx)*q.x/z+Float(k.cx), v = Float(k.cy)-Float(k.fy)*q.y/z
        guard u.isFinite,v.isFinite,u >= 1,v >= 1,u < Float(k.width-2),v < Float(k.height-2) else { return nil }
        let x = Int(u.rounded()), y = Int(v.rounded())
        func point(_ x: Int,_ y: Int) -> SIMD3<Float>? {
            let i = y*k.width+x, d = view.depth[i]
            guard d.isFinite,d > 0.15,d < 5,view.confidence == nil || view.confidence![i] >= 1 else { return nil }
            return SIMD3((Float(x)-Float(k.cx))*d/Float(k.fx),(Float(k.cy)-Float(y))*d/Float(k.fy),-d)
        }
        guard let p = point(x,y),let l = point(x-1,y),let r = point(x+1,y),let t = point(x,y-1),let b = point(x,y+1),
              max(abs(l.z-r.z),abs(t.z-b.z)) < max(0.08,z*0.15) else { return nil }
        let n1 = simd_cross(r-p,b-p), n2 = simd_cross(p-l,p-t)
        guard simd_length(n1) > 1e-7,simd_length(n2) > 1e-7,
              simd_dot(simd_normalize(n1),simd_normalize(n2)) > 0.95 else { return nil }
        let local = simd_normalize(n1+n2)
        // R^-1 = R^T for the validated rigid camera matrix; avoid an inverse per point.
        let w2c = view.worldToCamera
        let rotation = simd_float3x3(SIMD3(w2c[0].x,w2c[0].y,w2c[0].z),
            SIMD3(w2c[1].x,w2c[1].y,w2c[1].z),SIMD3(w2c[2].x,w2c[2].y,w2c[2].z))
        return rotation.transpose*local
    }

    private func markSurface(_ p: SIMD3<Float>) {
        guard let (_,_,v) = address(p) else { return }
        for z: Int32 in -1...1 { for y: Int32 in -1...1 { for x: Int32 in -1...1 {
            let (key,index,_) = address(v &+ SIMD3(x,y,z))
            // Never grow the support-mask index beyond the bounded volume index, or claim
            // support in wholly unobserved neighboring blocks.
            guard knownBlocks.contains(key) else { continue }
            let mask: Mask
            if let old = supportedCells[key] { mask = old } else { mask = Mask(); supportedCells[key] = mask }
            mask.bits[index >> 6] |= UInt64(1) << (index & 63)
        } } }
    }
    func covers(_ p: CloudPoint) -> Bool {
        guard let (key,index,_) = address(SIMD3(p.x,p.y,p.z)),let mask = supportedCells[key] else { return false }
        return mask.bits[index >> 6] & (UInt64(1) << (index & 63)) != 0
    }
    /// Keep the original fused samples in holes and unsupported regions. Never fill those holes
    /// by relaxing the two-view surface rule. Reservoir uses the same fixed output limit.
    func preservingUnsupported(_ surface: [CloudPoint], fallback: [CloudPoint], limit: Int,
                               farExclusion: Float = 0,
                               shouldContinue: () -> Bool = {true}) -> [CloudPoint]? {
        var out = surface, seen = surface.count, random: UInt64 = 0x425ae
        for (i,point) in fallback.enumerated() {
            if i%1024 == 0, !shouldContinue() { report.status = "interrupted"; return nil }
            // Defer far points: duplicates that will be discarded must not evict near
            // crossings from the reservoir. Their final eligibility is tested later.
            if farExclusion > 0, (point.fusionSource & 3) == 2 { continue }
            guard !covers(point) else { continue }
            report.fallbackPoints += 1; seen += 1
            if out.count < limit { out.append(point) }
            else if limit > 0 {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                let index = Int(random%UInt64(seen)); if index < limit { out[index] = point }
            }
        }
        if farExclusion > 0 {
            guard let near = SurfaceCoverageIndex(points:out,include:{ (out[$0].fusionSource & 3) == 1 },shouldContinue:shouldContinue) else {
                report.status = "interrupted"; return nil
            }
            var expectedFill = 0, farCount = 0
            for (i,p) in fallback.enumerated() {
                if i%256 == 0, !shouldContinue() { report.status = "interrupted"; return nil }
                guard (p.fusionSource & 3) == 2 else { continue }
                farCount += 1
                let normal = PackedSurfaceNormal.decode(p.packedNormal)
                if normal == nil || !near.covers(SurfaceCoverageIndex.position(p),normal:normal,radius:min(0.15,farExclusion),points:out) {
                    expectedFill += 1
                }
            }
            // Estimate capacity only; do not discard any far geometry on this provisional
            // coverage. The final near survivors may change during visibility validation.
            let reserve = min(limit/2,expectedFill)
            report.farReservePoints = reserve
            let nearLimit = max(0,limit-reserve)
            if out.count > nearLimit {
                let total = out.count
                var written = 0
                for i in out.indices where (i+1)*nearLimit/total > i*nearLimit/total {
                    if written != i { out[written] = out[i] }; written += 1
                }
                out.removeLast(total-written)
            }
            for (i,p) in fallback.enumerated() {
                if i%1024 == 0, !shouldContinue() { report.status = "interrupted"; return nil }
                guard (p.fusionSource & 3) == 2 else { continue }
                out.append(p)
            }
            report.fallbackPoints += farCount
            // At most two capped clouds; final coverage then caps only far fill so near
            // points used as replacement evidence cannot disappear in another reservoir.
            report.peakMergePoints = out.count
        }
        if report.fallbackPoints > 0 { report.status = "completedWithFallback" }
        return out
    }

    /// Extract sign-changing edges only between observed cells. Unknown space never creates a face.
    /// Deterministic reservoir bounds the output array without allocating all crossings first.
    func extract(limit: Int, shouldContinue: () -> Bool = { true }) -> [CloudPoint]? {
        guard report.status == "integrating", limit > 0 else { return nil }
        let started = Date(); defer { report.seconds += Date().timeIntervalSince(started) }
        var output: [CloudPoint] = []; output.reserveCapacity(min(limit,250_000))
        var covered = Set<Key>(), seen = 0
        var random: UInt64 = 0x8e45bc91
        for key in knownBlocks.sorted() {
            guard shouldContinue() else { report.status = "interrupted"; return nil }
            guard let block = block(key,create:false) else { return nil }
            for i in 0..<512 {
                let a = block.cells[i]
                guard a.views >= 2 else { continue }
                let v = SIMD3(key.x * 8 + Int32(i & 7), key.y * 8 + Int32((i >> 3) & 7), key.z * 8 + Int32(i >> 6))
                for axis in 0..<3 {
                    var next = v; next[axis] += 1
                    let (nk,ni,_) = address(next)
                    let neighbor: Block
                    if nk == key {
                        // Same values and LRU access order, without a hash lookup per interior edge.
                        tick += 1; block.accessed = tick; neighbor = block
                    } else if let nextBlock = self.block(nk,create:false) { neighbor = nextBlock }
                    else { if report.status != "integrating" { return nil }; continue }
                    let b = neighbor.cells[ni]
                    guard b.views >= 2,
                          (a.distance < 0) != (b.distance < 0), abs(a.distance-b.distance) > 1e-7 else { continue }
                    let t = a.distance / (a.distance-b.distance)
                    let p = center(v)*(1-t) + center(next)*t
                    let color = SIMD3(a.r,a.g,a.b)*(1-t) + SIMD3(b.r,b.g,b.b)*t
                    let point = CloudPoint(x:p.x,y:p.y,z:p.z,r:UInt8(clamping:Int(color.x.rounded())),
                        g:UInt8(clamping:Int(color.y.rounded())),b:UInt8(clamping:Int(color.z.rounded())),fusionSource:1,packedNormal:a.packedNormal,score:min(1,(a.weight+b.weight)*0.25))
                    markSurface(p)
                    covered.insert(key); covered.insert(nk); seen += 1
                    if output.count < limit { output.append(point) }
                    else {
                        random = random &* 6364136223846793005 &+ 1442695040888963407
                        let index = Int(random % UInt64(seen))
                        if index < limit { output[index] = point }
                    }
                }
            }
        }
        report.crossings = seen
        report.surfaceCoverage = Float(surfaceBlocks.intersection(covered).count)/Float(max(1,surfaceBlocks.count))
        guard !output.isEmpty else {
            report.status = "coverageFallback"; return nil
        }
        report.status = "completed"
        return output
    }
}
