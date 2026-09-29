// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import simd

/// MRNF schedule: LichtFeld Studio's 30,000-iteration defaults scaled to the run length the way
/// its `steps_scaler` scales refine interval, stop/grow iterations and the SH schedule.
nonisolated struct MRNFSchedule: Codable, Equatable {
    var iterations: Int
    var refineEvery: Int
    var stopRefine: Int
    var growUntil: Int
    var shDegreeInterval: Int
    var shWarmup: Int
    var ppispWarmup: Int

    init(iterations: Int) {
        let s = Double(iterations) / 30_000
        func scaled(_ v: Double, minimum: Int) -> Int { max(minimum, Int((v * s).rounded())) }
        self.iterations = iterations
        refineEvery = scaled(200, minimum: 25)
        stopRefine = min(iterations, scaled(28_500, minimum: 1))
        growUntil = scaled(15_000, minimum: 1)
        shDegreeInterval = scaled(1_000, minimum: 25)
        shWarmup = scaled(1_000, minimum: 0)
        ppispWarmup = scaled(500, minimum: 10)
    }

    /// Refine at `t` (1-based) when 0 < t < stop and t is a multiple of the interval.
    func isRefining(_ t: Int) -> Bool { t < stopRefine && t % refineEvery == 0 }

    /// Active SH degree after the bump at iteration `t`.
    func shDegree(at t: Int, maximum: Int) -> Int { min(maximum, t / shDegreeInterval) }
}

/// LichtFeld Studio's MRNF defaults (parameters.cpp `mrnf_defaults`, kernels and strategy).
nonisolated enum MRNFConstants {
    static let meansLR = 2e-5, meansLREnd = 2e-7
    static let scalesLR = 7e-3, scalesLREnd = 5e-3
    static let rotationLR = 2e-3, opacityLR = 0.012, sh0LR = 2e-3, shNLR = 2e-3 / 20
    static let opacityRegularizer: Float = 0.003
    static let growthThreshold: Float = 0.003
    static let growFraction = 0.07
    static let opacityDecay: Float = 0.004, scaleDecay: Float = 0.002
    static let noiseWeight = 50.0
    static let maxScreenShare: Float = 0.3, screenSharePenalty: Float = 1.0
    static let oversizeFraction = 0.15
    static let edgeWeight: Float = 0.25
    static let pruneLogit: Float = -5.54126        // logit(1/255)
    static let minLogScale: Float = log(1e-10)
    static let boundsEveryRefines = 5
    /// Hole filling: at most this many new Gaussians per refine, opacity 0.1 at birth.
    static let maxHoleSeedsPerRefine = 2_000
    static let holeSeedLogit: Float = -2.1972246      // logit(0.1)
}

/// Relocation at the Gaussian cap, this project's addition to MRNF: slots of Gaussians that
/// the photos show contribute almost nothing move to Gaussians the photos show are under-fit.
nonisolated enum RelocationConstants {
    /// A Gaussian is judged only when the frusta of at least this many views of the refine
    /// window reached it.
    static let minViews: Float = 3
    /// Low contribution: blending weight per view below this share of the median Gaussian's.
    static let lowShare: Float = 0.02
    /// Consecutive low windows before a Gaussian gives up its slot.
    static let lowWindows: Float = 2
    /// At most this share of the live Gaussians moves per refine, tapering to zero at the end
    /// of refinement.
    static let maxShare = 0.005
}

/// Densification quotas per region, this project's addition to MRNF (see `RegionQuota`).
nonisolated enum RegionQuotaConstants {
    /// The grid covers the bounds' centre ± `span` × their half extent, in `cellsPerAxis` cells
    /// per axis; Gaussians outside it count towards the border cells.
    static let cellsPerAxis = 24
    static let span: Float = 2
    /// Share of each region's demand from its visible area alone (basic coverage); the rest
    /// grows with its persistent error (complex regions).
    static let baseShare: Float = 0.5
    /// A region seen by fewer training photos than this has its demand scaled down.
    static let minSupport: Float = 3
    /// Error ratio (to the scene's area-weighted mean) above which demand stops growing.
    static let maxErrorRatio: Float = 4
}

/// How refinement uses the regions.
nonisolated enum RegionMode: Equatable {
    /// Plain MRNF, no region statistics.
    case off
    /// Region statistics only (for diagnostics); densification is unchanged.
    case track
    /// Growth is split between regions by their quota.
    case quota
    /// Quotas, and at the cap, slots of proven low contributors in regions over their quota
    /// move to under-fit Gaussians in regions below it.
    case quotaReclaim
}

/// Region statistics and densification quotas. A fixed grid over the scene splits the Gaussian
/// budget by what the photos show of each cell, not by where the largest splats are:
/// - **visible area:** the blending weight per training view the cell's Gaussians receive
///   (pixels, at the training resolution);
/// - **photo support:** the share of training views whose frustum reached the cell;
/// - **persistent error:** the cell's error-weighted footprint over its visible area (1 is the
///   image's mean error), averaged over refine windows.
/// Averages start as a running mean and become moving averages spanning about one pass over the
/// photos, so every cell is judged from all the views that see it.
nonisolated struct RegionQuota: Codable, Equatable {
    var origin: SIMD3<Float>
    var cell: Float
    var area: [Float]
    var support: [Float]
    var error: [Float]
    var windows = 0

    init?(bounds: MRNFBounds) {
        typealias C = RegionQuotaConstants
        guard bounds.valid, bounds.maxExtent > 0 else { return nil }
        let cells = C.cellsPerAxis * C.cellsPerAxis * C.cellsPerAxis
        cell = 2 * C.span * bounds.maxExtent / Float(C.cellsPerAxis)
        origin = bounds.center - SIMD3(repeating: C.span * bounds.maxExtent)
        area = [Float](repeating: 0, count: cells)
        support = area
        error = area
    }

    func region(_ position: SIMD3<Float>) -> Int {
        let n = RegionQuotaConstants.cellsPerAxis
        let q = (position - origin) / cell
        func axis(_ v: Float) -> Int { v.isFinite ? Int(min(Float(n - 1), max(0, v.rounded(.down)))) : 0 }
        return (axis(q.x) * n + axis(q.y)) * n + axis(q.z)
    }

    /// Region of every row (live or not) from its current centre.
    func regions(_ model: GaussianModel) -> [Int32] {
        let p = model.floats(model.params), means = Int(model.layout.means)
        return (0..<model.count).map { i in
            Int32(region(SIMD3(p[means + 3 * i], p[means + 3 * i + 1], p[means + 3 * i + 2])))
        }
    }

    /// Folds one refine window of `windowViews` training views into the averages.
    mutating func update(_ model: GaussianModel, regionOf: [Int32], windowViews: Int, trainingViews: Int) {
        let active = model.stat(GaussianStats.active), visibility = model.stat(GaussianStats.visibility)
        let views = model.stat(GaussianStats.views), errorSum = model.stat(GaussianStats.errorSum)
        var a = [Float](repeating: 0, count: area.count), e = a, s = a
        for i in 0..<model.count where active[i] > 0.5 {
            let r = Int(regionOf[i])
            a[r] += visibility[i]
            e[r] += errorSum[i]
            s[r] = max(s[r], views[i])
        }
        let w = Float(max(1, windowViews))
        let pass = min(0.5, max(0.05, Float(windowViews) / Float(max(1, trainingViews))))
        let alpha = max(1 / Float(windows + 1), pass)
        for r in 0..<area.count {
            area[r] += alpha * (a[r] / w - area[r])
            support[r] += alpha * (min(1, s[r] / w) - support[r])
            if a[r] > 0 {
                let ratio = e[r] / a[r]
                error[r] = error[r] > 0 ? error[r] + max(alpha, pass) * (ratio - error[r]) : ratio
            }
        }
        windows += 1
    }

    /// Each region's share of the Gaussians: its visible area, scaled down below three photos of
    /// support, times a base plus a term that grows with its persistent error. Sums to 1.
    func shares(trainingViews: Int) -> [Float] {
        typealias C = RegionQuotaConstants
        var base = [Float](repeating: 0, count: area.count)
        var weight: Float = 0, weightedError: Float = 0
        for r in 0..<area.count where area[r] > 0 {
            base[r] = area[r] * min(1, support[r] * Float(trainingViews) / C.minSupport)
            weight += base[r]
            weightedError += base[r] * error[r]
        }
        guard weight > 0 else { return base }
        let meanError = weightedError > 0 ? weightedError / weight : 1
        var total: Float = 0
        for r in 0..<area.count where base[r] > 0 {
            base[r] *= C.baseShare + (1 - C.baseShare) * min(error[r] / meanError, C.maxErrorRatio)
            total += base[r]
        }
        return total > 0 ? base.map { $0 / total } : base
    }

    /// Splits `k` between regions in proportion to `deficit`, at most `available[r]` each
    /// (largest remainders first); what no region can take is left for the global pool.
    static func allot(_ k: Int, deficit: [Float], available: [Int]) -> [Int] {
        var result = [Int](repeating: 0, count: deficit.count)
        var remaining = k
        var open = (0..<deficit.count).filter { deficit[$0] > 0 && available[$0] > 0 }
        while remaining > 0 && !open.isEmpty {
            let total = open.reduce(Float(0)) { $0 + deficit[$1] }
            var given = 0
            var fractions: [(Float, Int)] = []
            for r in open {
                let exact = Float(remaining) * deficit[r] / total
                let whole = min(Int(exact), available[r] - result[r])
                result[r] += whole
                given += whole
                if result[r] < available[r] { fractions.append((exact - Float(Int(exact)), r)) }
            }
            fractions.sort { $0.0 > $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
            for (_, r) in fractions where given < remaining && result[r] < available[r] {
                result[r] += 1
                given += 1
            }
            remaining -= given
            open = open.filter { result[$0] < available[$0] }
            if given == 0 { break }
        }
        return result
    }
}

/// Scene bounds from the 10th/90th percentile of the live centres.
nonisolated struct MRNFBounds: Codable, Equatable {
    var center = SIMD3<Float>(), maxExtent: Float = 0, medianSize: Float = 0, valid = false
}

/// MRNF densification (the default, non-"background improvements" path of LichtFeld Studio):
/// error- and edge-weighted Gumbel-top-k parent sampling, long-axis splits, replacement of
/// soft-pruned slots, screen-share clipping and gentle opacity/scale decay, all within a hard
/// Gaussian cap. Runs on the CPU against the shared buffers while the GPU is idle; the
/// per-iteration parts (statistic folding, noise, Adam) are GPU kernels.
nonisolated struct MRNFStrategy: Codable, Equatable {
    var schedule: MRNFSchedule
    /// Hard cap on live Gaussians (≤ model capacity); lowered when memory runs short.
    var maxGaussians: Int
    var bounds = MRNFBounds()
    var refinesSinceBounds = 0
    var edgeViews = 0
    var seed: UInt64 = 0x5EED
    /// Growth ramp: live Gaussians when training started. The cap is then reached gradually,
    /// at `growUntil`, instead of within the first refines (nil = no ramp; older checkpoints).
    var growthStart: Int?
    /// Region statistics and quotas (nil until the first refine that uses them).
    var regions: RegionQuota?
    /// Training views, for the regions' photo support and averaging span.
    var trainingViews: Int?

    struct Report: Equatable {
        var pruned = 0, replaced = 0, oversize = 0, grown = 0, holes = 0, live = 0
        /// Relocation: slots moved, and the Gaussians judged, eligible as donors and as receivers.
        var relocated = 0, judged = 0, donors = 0, receivers = 0
        /// Regions: cells with visible area, and growth splits placed by quota.
        var regions = 0, quotaGrown = 0
    }

    /// A new Gaussian for a pixel no Gaussian covers: on its camera ray at the best depth
    /// guess, small, faint and coloured from the photo (a wrong guess fades and is pruned).
    struct Seed: Equatable { var position: SIMD3<Float>; var color: SIMD3<Float>; var scale: Float }

    init(schedule: MRNFSchedule, maxGaussians: Int) {
        self.schedule = schedule
        self.maxGaussians = maxGaussians
    }

    // MARK: Learning rates

    func meansLR(at t: Int) -> Float {
        let gamma = pow(MRNFConstants.meansLREnd / MRNFConstants.meansLR, 1 / Double(schedule.iterations))
        let size = bounds.valid ? Double(bounds.medianSize) : 1
        return Float(MRNFConstants.meansLR * size * pow(gamma, Double(max(t - 1, 0))))
    }

    func scalesLR(at t: Int) -> Float {
        let gamma = pow(MRNFConstants.scalesLREnd / MRNFConstants.scalesLR, 1 / Double(schedule.iterations))
        return Float(MRNFConstants.scalesLR * pow(gamma, Double(max(t - 1, 0))))
    }

    // MARK: Bounds

    mutating func updateBounds(_ model: GaussianModel) {
        let rows = model.liveRows
        guard !rows.isEmpty else { bounds.valid = false; return }
        let step = max(1, rows.count / 100_000)
        var axes: [[Float]] = [[], [], []]
        for (i, row) in rows.enumerated() where i % step == 0 {
            let m = model.mean(row)
            for k in 0..<3 { axes[k].append(m[k]) }
        }
        var center = SIMD3<Float>(), extent = SIMD3<Float>()
        for k in 0..<3 {
            let sorted = axes[k].sorted()
            let lo = sorted[Int(Double(sorted.count - 1) * 0.1)], hi = sorted[Int(Double(sorted.count - 1) * 0.9)]
            center[k] = (lo + hi) / 2
            extent[k] = (hi - lo) / 2
        }
        let maxExtent = extent.max()
        let finite = center.x.isFinite && center.y.isFinite && center.z.isFinite && maxExtent.isFinite
        guard finite, maxExtent > 32 * .ulpOfOne * max(1, simd_length(center)) else { bounds.valid = false; return }
        var median = 2 * [extent.x, extent.y, extent.z].sorted()[1]
        if !(median > 0) || !median.isFinite { median = 2 * maxExtent }
        bounds = MRNFBounds(center: center, maxExtent: maxExtent, medianSize: median, valid: true)
        refinesSinceBounds = 0
    }

    // MARK: Refinement

    /// Most live Gaussians allowed after the refine at `t`: the cap, or with the growth ramp a
    /// share of it that grows linearly from the starting count to the cap at `growUntil`.
    func growthCeiling(at t: Int, capacity: Int) -> Int {
        let cap = min(maxGaussians, capacity)
        guard let start = growthStart, start < cap, t < schedule.growUntil else { return cap }
        let fraction = Double(t) / Double(max(1, schedule.growUntil))
        return min(cap, start + Int(Double(cap - start) * fraction))
    }

    /// One refine step at iteration `t` (1-based). `seeds` fill image regions no Gaussian
    /// covers; they take at most half of the free budget (and `maxHoleSeedsPerRefine`), the
    /// rest refills pruned slots by splitting as before.
    mutating func refine(_ model: GaussianModel, iteration t: Int, seeds: [Seed] = [], replaceByError: Bool = false,
                         relocate: Bool = false, regionMode: RegionMode = .off) -> Report {
        var report = Report()
        refinesSinceBounds += 1
        if !bounds.valid || refinesSinceBounds >= MRNFConstants.boundsEveryRefines { updateBounds(model) }
        let L = model.layout
        let p = model.floats(model.params)
        let active = model.stat(GaussianStats.active)
        let visibility = model.stat(GaussianStats.visibility)
        let errorMax = model.stat(GaussianStats.errorMax)
        let shareMax = model.stat(GaussianStats.shareMax)
        let edgeSum = model.stat(GaussianStats.edgeSum)
        let n = model.count
        let scales = Int(L.scales), quats = Int(L.quats), opacities = Int(L.opacities), means = Int(L.means)

        // Screen-share clip of the largest axis.
        for i in 0..<n where active[i] > 0.5 && shareMax[i] > MRNFConstants.maxScreenShare {
            let a = argmax(p + scales + 3 * i)
            p[scales + 3 * i + a] -= min(log(shareMax[i] / MRNFConstants.maxScreenShare), log(1.5))
        }

        // Soft prune.
        var pruned: [Int] = []
        let maxLogScale = bounds.valid ? log(100 * bounds.maxExtent) : .infinity
        for i in 0..<n where active[i] > 0.5 {
            let q = SIMD4(p[quats + 4 * i], p[quats + 4 * i + 1], p[quats + 4 * i + 2], p[quats + 4 * i + 3])
            let s = max(p[scales + 3 * i], p[scales + 3 * i + 1], p[scales + 3 * i + 2])
            var remove = p[opacities + i] < MRNFConstants.pruneLogit || simd_length_squared(q) < 1e-8
                || s < MRNFConstants.minLogScale || !s.isFinite
            if !remove && bounds.valid {
                let d = simd_abs(SIMD3(p[means + 3 * i], p[means + 3 * i + 1], p[means + 3 * i + 2]) - bounds.center)
                remove = s > maxLogScale || d.max() > 100 * bounds.maxExtent || !d.max().isFinite
            }
            if remove { pruned.append(i) }
        }
        // Edge guidance: 1 + 0.25 * E / positive median(E).
        var guidance = [Float](repeating: 1, count: n)
        if edgeViews > 0 {
            let values = (0..<n).compactMap { active[$0] > 0.5 && edgeSum[$0] > 0 ? edgeSum[$0] / Float(edgeViews) : nil }
            if let median = Self.median(values), median > 0 {
                for i in 0..<n where active[i] > 0.5 && edgeSum[i] > 0 {
                    guidance[i] = 1 + MRNFConstants.edgeWeight * (edgeSum[i] / Float(edgeViews)) / median
                }
            }
        }
        let ceiling = growthCeiling(at: t, capacity: model.capacity)
        let atCeiling = model.activeCount >= ceiling
        // Regions: fold this window, then quotas against the live count per region.
        var regionOf: [Int32] = [], regionShares: [Float] = []
        if regionMode != .off {
            if regions == nil, bounds.valid { regions = RegionQuota(bounds: bounds) }
            if var quota = regions {
                regionOf = quota.regions(model)
                quota.update(model, regionOf: regionOf, windowViews: schedule.refineEvery, trainingViews: trainingViews ?? schedule.refineEvery)
                regionShares = quota.shares(trainingViews: trainingViews ?? schedule.refineEvery)
                report.regions = regionShares.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
                regions = quota
            }
        }
        let quotas = regionMode == .quota || regionMode == .quotaReclaim ? regionShares : []
        model.free(rows: pruned)
        report.pruned = pruned.count
        var regionCounts = [Int](repeating: 0, count: quotas.count)
        if !quotas.isEmpty {
            for i in 0..<n where active[i] > 0.5 { regionCounts[Int(regionOf[i])] += 1 }
        }

        // Relocation at the cap: see `relocationCandidates`. With region quotas, only regions
        // over their quota give slots, and only regions below it receive them.
        var relocationWeights: [Float] = []
        let cap = min(maxGaussians, model.capacity)
        // The cap counts as reached once growth has ended (the ramp stops a few slots short).
        let reachedCap = model.activeCount + pruned.count >= cap || t >= schedule.growUntil
        let reclaim = regionMode == .quotaReclaim && !quotas.isEmpty && reachedCap
        if (relocate && atCeiling || reclaim) && t < schedule.stopRefine {
            var surplus: [Int]?, below: [Bool]?
            if reclaim {
                let targets = quotas.map { $0 * Float(cap) }
                surplus = (0..<quotas.count).map { r in
                    let supported = (regions?.support[r] ?? 0) * Float(trainingViews ?? 1) >= RegionQuotaConstants.minSupport
                    return supported ? max(0, regionCounts[r] - Int(targets[r].rounded(.up))) : 0
                }
                below = (0..<quotas.count).map { Float(regionCounts[$0]) < targets[$0] }
            }
            let (donors, weights, counts) = relocationCandidates(model, guidance: guidance, iteration: t,
                                                                 regionOf: regionOf, surplus: surplus, below: below)
            (report.judged, report.donors, report.receivers) = counts
            if !donors.isEmpty {
                model.free(rows: donors)
                report.relocated = donors.count
                relocationWeights = weights
            }
        }

        let live = model.activeCount
        var budget = max(0, ceiling - live)
        let holeCount = min(seeds.count, budget / 2, MRNFConstants.maxHoleSeedsPerRefine)
        if holeCount > 0 {
            let rows = model.allocateRows(holeCount)
            for (row, seed) in zip(rows, seeds) { model.setSeed(row: row, seed) }
            budget -= rows.count
            report.holes = rows.count
        }
        var rng = SplitMix64(seed: seed ^ UInt64(t))
        var taken = [Bool](repeating: false, count: n)
        func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

        // 1. Replacement splits refill the pruned slots, sampled by opacity.
        let replaceWeights = (0..<n).map { i -> Float in
            guard active[i] > 0.5 && visibility[i] > 0 else { return 0 }
            return (replaceByError ? errorMax[i] : sigmoid(p[opacities + i])) * guidance[i]
        }
        let replacement = Self.gumbelTopK(replaceWeights, k: min(pruned.count, budget), rng: &rng, excluding: taken)
        for i in replacement { taken[i] = true }
        budget -= replacement.count
        var parents = replacement
        report.replaced = replacement.count

        // 1b. Relocation splits refill the relocated slots, sampled by the evidence of under-fit.
        if !relocationWeights.isEmpty {
            let moved = Self.gumbelTopK(relocationWeights, k: min(report.relocated, budget), rng: &rng, excluding: taken)
            for i in moved { taken[i] = true }
            budget -= moved.count
            parents += moved
        }

        // 2. Growth while t < growUntil: ~7% of the visible, erroring splats per refine.
        if t < schedule.growUntil && budget > 0 {
            let candidates = (0..<n).filter { active[$0] > 0.5 && errorMax[$0] > MRNFConstants.growthThreshold && visibility[$0] > 0 }
            let desired = Int((Double(candidates.count) * MRNFConstants.growFraction).rounded())
            var grow = max(0, min(desired - replacement.count, budget))
            if grow > 0 {
                let overK = Int((MRNFConstants.oversizeFraction * Double(grow)).rounded())
                let overWeights = (0..<n).map { i -> Float in
                    let err = errorMax[i] * guidance[i]
                    guard active[i] > 0.5, shareMax[i] > MRNFConstants.maxScreenShare, err > 0 else { return 0 }
                    return sqrt(err) * (shareMax[i] / MRNFConstants.maxScreenShare)
                }
                let oversize = Self.gumbelTopK(overWeights, k: overK, rng: &rng, excluding: taken)
                for i in oversize { taken[i] = true }
                grow -= oversize.count
                report.oversize = oversize.count
                var growWeights = [Float](repeating: 0, count: n)
                for i in candidates { growWeights[i] = errorMax[i] * guidance[i] }
                var grown: [Int]
                if quotas.isEmpty {
                    grown = Self.gumbelTopK(growWeights, k: grow, rng: &rng, excluding: taken)
                } else {
                    // Split the growth between regions by how far each is below its quota of
                    // the ceiling (children already chosen count towards their region), then
                    // sample by error within each region; the global pool takes the rest.
                    for i in parents + oversize { regionCounts[Int(regionOf[i])] += 1 }
                    let keys = Self.gumbelKeys(growWeights, rng: &rng, excluding: taken)
                    var byRegion = [[(Float, Int)]](repeating: [], count: quotas.count)
                    for (key, i) in keys { byRegion[Int(regionOf[i])].append((key, i)) }
                    let deficit = (0..<quotas.count).map { max(0, quotas[$0] * Float(ceiling) - Float(regionCounts[$0])) }
                    let allotted = RegionQuota.allot(grow, deficit: deficit, available: byRegion.map(\.count))
                    grown = []
                    var rest: [(Float, Int)] = []
                    for r in 0..<quotas.count where !byRegion[r].isEmpty {
                        let sorted = byRegion[r].sorted { $0.0 > $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
                        grown += sorted.prefix(allotted[r]).map(\.1)
                        rest += sorted.dropFirst(allotted[r])
                    }
                    report.quotaGrown = grown.count
                    if grown.count < grow {
                        rest.sort { $0.0 > $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
                        grown += rest.prefix(grow - grown.count).map(\.1)
                    }
                    grown.sort()
                }
                report.grown = grown.count
                parents += oversize + grown
            }
        }

        // Long-axis split: parent moves +offset, child -offset; both shrink and fade.
        let childRows = model.allocateRows(parents.count)
        for (index, parent) in parents.enumerated() {
            let s = SIMD3(p[scales + 3 * parent], p[scales + 3 * parent + 1], p[scales + 3 * parent + 2])
            let a = argmax(p + scales + 3 * parent)
            let q = simd_normalize(SIMD4(p[quats + 4 * parent], p[quats + 4 * parent + 1], p[quats + 4 * parent + 2], p[quats + 4 * parent + 3]))
            let axis = Self.rotationColumn(q, a)
            let offset = 0.5 * exp(s[a]) * axis
            let opacity = sigmoid(p[opacities + parent])
            let faded = min(max(0.6 * opacity, 1e-7), 1 - 1e-7)
            var newScale = s + log(0.85)
            newScale[a] = s[a] + log(0.5)
            let child = index < childRows.count ? childRows[index] : nil
            if let child { model.copyRow(parent, to: child) }
            for row in [parent] + (child.map { [$0] } ?? []) {
                let sign: Float = row == parent ? 1 : -1
                for k in 0..<3 {
                    p[means + 3 * row + k] += sign * offset[k]
                    p[scales + 3 * row + k] = newScale[k]
                }
                p[opacities + row] = log(faded / (1 - faded))
                model.clearState(row: row)
            }
        }

        // Decay: the main pruning pressure, weaker as training progresses.
        let tau = Float(t) / Float(schedule.iterations)
        let opacityDrop = MRNFConstants.opacityDecay * (1 - tau), scaleFactor = 1 - MRNFConstants.scaleDecay * (1 - tau)
        for i in 0..<model.count where active[i] > 0.5 {
            let o = min(max(sigmoid(p[opacities + i]) - opacityDrop, 1e-12), 1 - Float.ulpOfOne)
            p[opacities + i] = log(o / (1 - o))
            for k in 0..<3 { p[scales + 3 * i + k] = log(max(exp(p[scales + 3 * i + k]) * scaleFactor, 1e-12)) }
        }

        // Reset the window statistics.
        for plane in [GaussianStats.visibility, GaussianStats.errorMax, GaussianStats.edgeSum, GaussianStats.shareMax,
                      GaussianStats.views, GaussianStats.errorSum] {
            memset(model.stat(plane), 0, model.capacity * 4)
        }
        edgeViews = 0
        report.live = model.activeCount
        return report
    }

    /// Relocation donors and receivers from the window statistics, judged only for Gaussians
    /// that at least `minViews` views of the window reached (enough photographic evidence):
    /// - **Donors** contributed almost nothing in those views, with a blending weight per view
    ///   below 2% of the median Gaussian's, in two consecutive windows: hidden behind other
    ///   splats, redundant, or too small to matter. They are freed, lowest contribution first.
    /// - **Receivers** cover pixels whose error stays above the image's mean error across those
    ///   views (error-weighted footprint over blending weight above 1). They are split into the
    ///   freed slots, sampled by their error per view and the edge guidance.
    /// At most 0.5% of the live Gaussians move per refine, tapering to zero at the end of
    /// refinement, and never more than there are receivers, so the model settles instead of
    /// churning. Returns the donors (not yet freed) and the receivers' weights.
    /// With region quotas, `surplus` limits the donors per region (regions at or below their
    /// quota give none) and `below` marks the regions whose Gaussians may receive.
    func relocationCandidates(_ model: GaussianModel, guidance: [Float], iteration t: Int,
                              regionOf: [Int32] = [], surplus: [Int]? = nil, below: [Bool]? = nil)
        -> (donors: [Int], weights: [Float], counts: (judged: Int, donors: Int, receivers: Int)) {
        typealias R = RelocationConstants
        let n = model.count
        let active = model.stat(GaussianStats.active), visibility = model.stat(GaussianStats.visibility)
        let views = model.stat(GaussianStats.views), errorSum = model.stat(GaussianStats.errorSum)
        let low = model.stat(GaussianStats.lowWindows)
        var perView: [Float] = []
        for i in 0..<n where active[i] > 0.5 && views[i] >= R.minViews { perView.append(visibility[i] / views[i]) }
        guard let median = Self.median(perView), median > 0 else { return ([], [], (perView.count, 0, 0)) }
        let threshold = R.lowShare * median
        var donors: [(contribution: Float, row: Int)] = []
        var weights = [Float](repeating: 0, count: n)
        var receivers = 0
        for i in 0..<n where active[i] > 0.5 && views[i] >= R.minViews {
            let contribution = visibility[i] / views[i]
            if contribution < threshold {
                // Too faint for its error to mean anything: never a receiver.
                low[i] += 1
                if low[i] >= R.lowWindows { donors.append((contribution, i)) }
                continue
            }
            low[i] = 0
            if let below, !below[Int(regionOf[i])] { continue }
            if visibility[i] > 0 && errorSum[i] > visibility[i] {
                weights[i] = errorSum[i] / views[i] * guidance[i]
                receivers += 1
            }
        }
        let taper = max(0, 1 - Double(t) / Double(max(1, schedule.stopRefine)))
        let limit = min(Int(Double(model.activeCount) * R.maxShare * taper), receivers)
        let counts = (perView.count, donors.count, receivers)
        guard limit > 0, !donors.isEmpty else { return ([], [], counts) }
        donors.sort { $0.contribution < $1.contribution || ($0.contribution == $1.contribution && $0.row < $1.row) }
        guard var left = surplus else { return (donors.prefix(limit).map(\.row).sorted(), weights, counts) }
        var chosen: [Int] = []
        for donor in donors where chosen.count < limit {
            let r = Int(regionOf[donor.row])
            if left[r] > 0 { left[r] -= 1; chosen.append(donor.row) }
        }
        return (chosen.sorted(), weights, counts)
    }

    private func argmax(_ s: UnsafeMutablePointer<Float>) -> Int { s[0] >= s[1] ? (s[0] >= s[2] ? 0 : 2) : (s[1] >= s[2] ? 1 : 2) }

    static func rotationColumn(_ q: SIMD4<Float>, _ column: Int) -> SIMD3<Float> {
        let (w, x, y, z) = (q.x, q.y, q.z, q.w)
        switch column {
        case 0: return SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y))
        case 1: return SIMD3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x))
        default: return SIMD3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y))
        }
    }

    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        var v = values
        let k = v.count / 2
        quickselect(&v, k)
        return v[k]
    }

    /// Weighted sampling without replacement: the k largest Gumbel keys ln w - ln(-ln u).
    static func gumbelTopK(_ weights: [Float], k: Int, rng: inout SplitMix64, excluding: [Bool]) -> [Int] {
        guard k > 0 else { return [] }
        var keyed: [(Float, Int)] = []
        keyed.reserveCapacity(weights.count)
        for (i, w) in weights.enumerated() {
            let u = min(max(rng.nextFloat(), 1e-10), 1 - 1e-7)   // one draw per row keeps sequences aligned
            guard w > 0, w.isFinite, !excluding[i] else { continue }
            keyed.append((log(w) - log(-log(u)), i))
        }
        guard !keyed.isEmpty else { return [] }
        let take = min(k, keyed.count)
        if take < keyed.count {
            var keys = keyed.map { -$0.0 }
            quickselect(&keys, take - 1)
            let threshold = -keys[take - 1]
            var chosen = keyed.filter { $0.0 > threshold }.map(\.1)
            for item in keyed where item.0 == threshold && chosen.count < take { chosen.append(item.1) }
            return chosen.sorted()
        }
        return keyed.map(\.1).sorted()
    }

    /// The Gumbel keys `gumbelTopK` ranks, for rows with a positive weight (one draw per row).
    static func gumbelKeys(_ weights: [Float], rng: inout SplitMix64, excluding: [Bool]) -> [(Float, Int)] {
        var keyed: [(Float, Int)] = []
        for (i, w) in weights.enumerated() {
            let u = min(max(rng.nextFloat(), 1e-10), 1 - 1e-7)
            guard w > 0, w.isFinite, !excluding[i] else { continue }
            keyed.append((log(w) - log(-log(u)), i))
        }
        return keyed
    }

    /// Hoare-partition quickselect: afterwards v[k] is the k-th smallest.
    static func quickselect(_ v: inout [Float], _ k: Int) {
        var lo = 0, hi = v.count - 1
        while lo < hi {
            let pivot = v[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while v[i] < pivot { i += 1 }
                while v[j] > pivot { j -= 1 }
                if i <= j { v.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return }
        }
    }
}

/// Deterministic generator for refinement sampling (checkpoints resume identically).
nonisolated struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextFloat() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
