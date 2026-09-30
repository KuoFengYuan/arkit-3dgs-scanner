// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import Metal
import simd

/// User-facing training settings; persisted with checkpoints so a resume uses the same run.
nonisolated struct GaussianTrainingConfiguration: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Sendable {
        case quick, standard, high
        /// Times each training photo is used by the automatic iteration count (the presets'
        /// counts over about 333 photos, like the scans they were measured on).
        var updatesPerPhoto: Int {
            switch self {
            case .quick: return 12
            case .standard: return 30
            case .high: return 60
            }
        }
    }

    /// Training image resolution, chosen separately from the preset. `high` is the photos'
    /// own resolution (1920 px on current iPhones); images are never upscaled.
    enum Resolution: String, Codable, CaseIterable, Sendable {
        case low, medium, high
        var longEdge: Int {
            switch self {
            case .low: return 960
            case .medium: return 1_440
            case .high: return 1_920
            }
        }
        init(longEdge: Int) { self = longEdge >= 1_920 ? .high : longEdge >= 1_440 ? .medium : .low }
    }
    var resolution: Resolution { Resolution(longEdge: longEdge) }

    var preset: Preset
    var iterations: Int
    /// Long edge of the training images (photos are downscaled, never upscaled).
    var longEdge: Int
    var maxGaussians: Int
    var shDegree: Int
    var poseOptimization = true
    var ppisp = true
    var mipFilter = true
    /// Every n-th selected frame is kept for validation only (0 = train on every frame).
    var holdOutEvery = 0
    /// nil = automatic, device-dependent budget.
    var memoryBudgetMB: Int?
    var seed: UInt64 = 0x3D65
    /// Capture-motion model: render each training photo with its exposure blur and rolling-
    /// shutter readout (seconds). Optional so checkpoints written before it still decode.
    var motionBlur: Bool?
    var rollingShutterReadout: Double?
    /// Seed empty surfaces from the photos' LiDAR depth (nil = on; optional for old checkpoints).
    var depthSeeds: Bool?
    /// Grow Gaussians where the rendered view stays empty but the photo is not (nil = on).
    var holeFilling: Bool?
    /// Weight of the LiDAR depth loss sum_i w_i |z_i - z| / z, decaying to 10% (nil = the
    /// default 0.1; 0 = off). It only acts on photos with LiDAR depth.
    var depthLoss: Double?
    var depthLossWeight: Double { depthLoss ?? 0.1 }
    /// Enhance model: the iteration the scan's saved model reached. The run loads that model
    /// and continues its schedule up to `iterations` in total (nil = a new model from the
    /// point cloud; optional so older records and checkpoints still decode).
    var enhancedFrom: Int?
    var startIteration: Int { enhancedFrom ?? 0 }
    var isEnhancement: Bool { startIteration > 0 }
    /// Iterations this run trains (all of them for a new model, the extra ones for an enhancement).
    var runIterations: Int { max(0, iterations - startIteration) }
    var usesHoleFilling: Bool { holeFilling ?? true }
    var usesDepthSeeds: Bool { depthSeeds ?? true }
    /// Seeds (the saved cloud and LiDAR depth seeds together) make up at most half the Gaussian
    /// cap, leaving room to densify; initialisation applies the memory plan's cap again.
    var seedBudget: Int { maxGaussians / 2 }
    /// LiDAR depth seeds fill what the saved cloud leaves of the seed budget, and at least a
    /// quarter of the cap. An enhancement starts from the saved model, so it needs no seeds.
    func depthSeedLimit(cloudPoints: Int) -> Int {
        usesDepthSeeds && !isEnhancement ? max(maxGaussians / 4, seedBudget - cloudPoints) : 0
    }

    /// The capture motion rendered for training photos, or nil for none.
    var captureMotion: (blur: Bool, readout: Double)? {
        let blur = motionBlur ?? false, readout = rollingShutterReadout ?? 0
        return blur || readout != 0 ? (blur, readout) : nil
    }

    /// This configuration as an enhancement of a saved model: `iterations` more on top of the
    /// model's, keeping at least its Gaussians and SH degree.
    func enhancing(savedIterations: Int, savedGaussians: Int, savedSHDegree: Int) -> Self {
        var c = self
        c.enhancedFrom = max(1, savedIterations)
        c.iterations = max(1, savedIterations) + iterations
        c.maxGaussians = max(maxGaussians, savedGaussians)
        c.shDegree = min(3, max(shDegree, savedSHDegree))
        return c
    }

    /// Automatic iteration count: the preset's, or more for scans with many photos, so every
    /// training photo is still used about `updatesPerPhoto` times (a Standard run of 10,000 over
    /// 333 photos). Rounded up to a thousand; the setup screen lets the user change it.
    static func automaticIterations(_ preset: Preset, trainingPhotos: Int?) -> Int {
        let base = Self.preset(preset).iterations
        guard let photos = trainingPhotos, photos > 0 else { return base }
        return max(base, (photos * preset.updatesPerPhoto + 999) / 1_000 * 1_000)
    }

    /// The range the setup screen offers for the iteration count.
    static let iterationRange = 1_000...200_000

    /// About 1.4× the iterations of the first trainer (3,000 / 7,000 / 15,000), paid for by its
    /// faster backward pass: a Standard run of FBDA13 took 319 s instead of 354 s on the Mac and
    /// scored 0.8 dB higher on held-out photos (docs/ON_DEVICE_3DGS.md).
    static func preset(_ preset: Preset) -> Self {
        switch preset {
        case .quick: return Self(preset: preset, iterations: 4_000, longEdge: Resolution.low.longEdge, maxGaussians: 300_000, shDegree: 2)
        case .standard: return Self(preset: preset, iterations: 10_000, longEdge: Resolution.low.longEdge, maxGaussians: 600_000, shDegree: 3)
        case .high: return Self(preset: preset, iterations: 20_000, longEdge: Resolution.low.longEdge, maxGaussians: 1_000_000, shDegree: 3)
        }
    }
}

/// Per-view pose correction w2c' = [R(ω) | τ] · w2c in the camera frame, with Adam state and
/// a Gaussian prior that keeps it near the ARKit pose. Metric scale is never changed.
nonisolated struct PoseCorrection: Codable, Equatable, Sendable {
    var rotation = SIMD3<Double>()      // axis-angle, radians
    var translation = SIMD3<Double>()   // metres
    var m = [Double](repeating: 0, count: 6), v = [Double](repeating: 0, count: 6)
    var steps = 0

    /// Base Adam rate (radians / metres per update) for ~18 updates per view; see
    /// `GaussianTrainer.poseLearningRate(iterations:trainFrames:)`. 1e-4 capped corrections
    /// near 0.05° / 1 mm, below real ARKit errors (docs/ON_DEVICE_3DGS.md).
    static let learningRate = 1e-3
    static let rotationSigma = 0.25 * .pi / 180, translationSigma = 0.005
    static let priorWeight = 1e-3

    var matrix: simd_double4x4 {
        let angle = simd_length(rotation)
        let r = angle > 1e-12 ? simd_double3x3(simd_quatd(angle: angle, axis: rotation / angle)) : matrix_identity_double3x3
        return simd_double4x4(columns: (SIMD4(r[0], 0), SIMD4(r[1], 0), SIMD4(r[2], 0), SIMD4(translation, 1)))
    }
    var isIdentity: Bool { rotation == .zero && translation == .zero }

    init() {}

    /// The correction [R | τ] of a rigid matrix (fresh optimiser state).
    init(matrix m: simd_double4x4) {
        let r = simd_double3x3(SIMD3(m[0][0], m[0][1], m[0][2]), SIMD3(m[1][0], m[1][1], m[1][2]), SIMD3(m[2][0], m[2][1], m[2][2]))
        let q = simd_quatd(r)
        let angle = q.angle
        rotation = angle > 1e-12 && angle.isFinite ? q.axis * (angle > .pi ? angle - 2 * .pi : angle) : .zero
        translation = SIMD3(m[3][0], m[3][1], m[3][2])
    }
    var rotationDegrees: Double { simd_length(rotation) * 180 / .pi }
    var translationMeters: Double { simd_length(translation) }

    /// Adam step from dL/d[R'|t'] (row-major 3x4) of the corrected world-to-camera matrix.
    /// `neighbours` (experiment) adds a prior of `neighbourWeight` × the anchor's toward the mean
    /// correction of the photos next to this one in time (ARKit drift is smooth in time).
    mutating func update(poseGradient g: [Float], base w2c: simd_double4x4, learningRate lr: Double,
                         neighbours: (rotation: SIMD3<Double>, translation: SIMD3<Double>)? = nil, neighbourWeight: Double = 0) {
        let dR = simd_double3x3(rows: [SIMD3(Double(g[0]), Double(g[1]), Double(g[2])),
                                        SIMD3(Double(g[4]), Double(g[5]), Double(g[6])),
                                        SIMD3(Double(g[8]), Double(g[9]), Double(g[10]))])
        let dt = SIMD3(Double(g[3]), Double(g[7]), Double(g[11]))
        let R = simd_double3x3(SIMD3(w2c[0][0], w2c[0][1], w2c[0][2]), SIMD3(w2c[1][0], w2c[1][1], w2c[1][2]),
                               SIMD3(w2c[2][0], w2c[2][1], w2c[2][2]))
        let t = SIMD3(w2c[3][0], w2c[3][1], w2c[3][2])
        // R' = Rd R, t' = Rd t + td.
        let outer = simd_double3x3(columns: (dt * t.x, dt * t.y, dt * t.z))
        let dRd = dR * R.transpose + outer
        let current = matrix
        let Rd = simd_double3x3(SIMD3(current[0][0], current[0][1], current[0][2]), SIMD3(current[1][0], current[1][1], current[1][2]),
                                SIMD3(current[2][0], current[2][1], current[2][2]))
        let A = dRd * Rd.transpose     // left-perturbation gradient; A[col][row]
        var grad = [A[1][2] - A[2][1], A[2][0] - A[0][2], A[0][1] - A[1][0], dt.x, dt.y, dt.z]
        let w = Self.priorWeight
        for k in 0..<3 {
            grad[k] += w * rotation[k] / (Self.rotationSigma * Self.rotationSigma)
            grad[3 + k] += w * translation[k] / (Self.translationSigma * Self.translationSigma)
            if let n = neighbours, neighbourWeight > 0 {
                grad[k] += w * neighbourWeight * (rotation[k] - n.rotation[k]) / (Self.rotationSigma * Self.rotationSigma)
                grad[3 + k] += w * neighbourWeight * (translation[k] - n.translation[k]) / (Self.translationSigma * Self.translationSigma)
            }
        }
        steps += 1
        let c1 = 1 - pow(0.9, Double(steps)), c2 = 1 - pow(0.999, Double(steps))
        var step = [Double](repeating: 0, count: 6)
        for k in 0..<6 where grad[k].isFinite {
            m[k] = 0.9 * m[k] + 0.1 * grad[k]
            v[k] = 0.999 * v[k] + 0.001 * grad[k] * grad[k]
            step[k] = lr * (m[k] / c1) / ((v[k] / c2).squareRoot() + 1e-12)
        }
        rotation -= SIMD3(step[0], step[1], step[2])
        translation -= SIMD3(step[3], step[4], step[5])
    }
}

/// One iteration's outcome.
nonisolated struct TrainingStepReport: Sendable {
    var iteration: Int
    var frame: Int
    var loss: Double
    var psnr: Double
    var gaussians: Int
    var seconds: Double
    var skipped = false
    var refine: MRNFStrategy.Report?
}

/// On-device 3D Gaussian Splatting optimisation (Metal): differentiable rasterization with the
/// Mip-Splatting 2D filter, L1 + D-SSIM loss, PPISP photometric compensation, optional ARKit-
/// anchored pose refinement, dense Adam and MRNF densification within a fixed memory plan.
///
/// Not thread-safe: one owner calls `step`, `renderPreview`, checkpoint and export in sequence.
nonisolated final class GaussianTrainer: @unchecked Sendable {
    enum TrainingError: LocalizedError {
        case noSeedPoints, repeatedOverflow, gpuFailure(String)
        var errorDescription: String? {
            switch self {
            case .noSeedPoints: return L10n.text("這次掃描沒有可用的點雲，無法初始化 3DGS 模型")
            case .repeatedOverflow:
                return L10n.text("畫面中的高斯數量超出記憶體配置，已儲存進度並停止。請降低訓練品質後繼續。")
            case .gpuFailure(let reason): return L10n.text("GPU 運算失敗：\(reason)")
            }
        }
    }

    let configuration: GaussianTrainingConfiguration
    let dataset: TrainingDataset
    let plan: TrainingMemoryPlan
    let metal: GaussianMetal
    let model: GaussianModel
    let raster: GaussianRasterizer
    let loss: GaussianLossEvaluator
    let target: GaussianRenderTarget
    let images: TrainingImageLoader
    private let targetImage, edgeMap, edgeScratch: MTLBuffer
    private let adam, fold, relocationFold, noise, share, edgeBlur, edgeSobel, scale: MTLComputePipelineState
    let renderer: GaussianRenderer

    var strategy: MRNFStrategy
    var ppisp: PPISPModel
    var poses: [PoseCorrection]
    private(set) var iteration = 0
    var epoch = 0, epochPosition = 0
    private var order: [Int] = []
    private var edgeMedians: [Float?]
    private var pendingFold: Float? = nil      // edge scale of the last backward, folded next step
    private var gpuSkipStreak = 0
    private var overflowStreak = 0
    /// Stops densification after a tile overflow or memory pressure.
    var growthFrozen = false
    private(set) var lastPSNR = 0.0

    /// Pose refinement starts once the scene has a coarse structure.
    var poseStart: Int { max(1, configuration.iterations / 10) }
    var poseLearningRate: Double
    /// Spread the seed cloud before initialising (experiments can turn it off).
    var seedJitter = true
    /// Experiment: Adam updates only the Gaussians the current view reached.
    var sparseAdam = false
    /// Experiment: refill pruned slots by splitting high-error Gaussians instead of opaque ones.
    var replaceByError = false
    /// Growth ramp: a new model reaches the Gaussian cap at the end of the growth phase instead
    /// of within its first refines (`MRNFStrategy.growthCeiling`); experiments can turn it off.
    var growthRamp = true
    /// Experiment: evidence-based relocation at the cap (`MRNFStrategy.relocationCandidates`).
    var relocation = false
    /// Region statistics and densification quotas (`RegionQuota`).
    var regionMode = RegionMode.off
    /// The view rendered by the last completed step (its render and photo are still in the
    /// buffers at the next refine).
    private var lastRendered: Int?
    /// Hole seeds added so far (reports).
    private(set) var holeSeedsAdded = 0
    /// LiDAR depth of the current view for the depth loss (allocated on first use, ~200 KB).
    private var lidarBuffer: MTLBuffer?
    /// Experiment (all 1 = off): gradient weight of each view's photometric loss, from
    /// `CovisibleSharpness.weights`. Below 1, the loss keeps (1 - weight) as an L1 on the window
    /// means (GaussianLoss.metal).
    var viewWeights: [Float]
    /// Experiment (off): transient masking. Once `transientStart` of the run has passed, the
    /// 16 × 16 blocks of a photo whose mean colour the model misses by far more than the photo's
    /// other blocks (moving people, reflections of them) are left out of its gradients at the
    /// photo's next visit. Block means, not pixel errors, so detail the model has not learnt yet
    /// (right mean, missing texture) is not masked.
    var transientMasking = false
    static let transientStart = 0.5
    /// A block is transient above max(`transientFloor`, `transientFactor` × the photo's median
    /// block difference), next to another such block, where the render covers it, and when it
    /// was already transient at the photo's previous visit (a region the model has not learnt
    /// yet improves between visits; a moving person in one photo does not).
    static let transientFloor: Float = 0.12, transientFactor: Float = 6
    private(set) var transientMasks: [[UInt8]?] = []
    private var transientCandidates: [[Bool]?] = []
    /// Masked share of blocks over the masks built so far (reports).
    private(set) var transientMaskedShare = (blocks: 0, total: 0)
    /// Experiment (0 = off): weight of the temporal smoothness prior on pose corrections,
    /// relative to the prior that anchors them to the ARKit pose (`PoseCorrection.update`).
    var poseSmoothing = 0.0

    /// Adam moves a view only when it is sampled, so a view's total correction is bounded by
    /// about the rate × its updates. Scale the rate so that bound does not shrink for shorter
    /// runs or more photos (a Standard run over ~350 photos, ~18 updates per view, uses the base).
    static func poseLearningRate(iterations: Int, trainFrames: Int) -> Double {
        let updates = Double(max(1, iterations - max(1, iterations / 10))) / Double(max(1, trainFrames))
        return PoseCorrection.learningRate * min(3, max(1, 18 / updates))
    }

    init(configuration: GaussianTrainingConfiguration, dataset: TrainingDataset, plan: TrainingMemoryPlan,
         metal: GaussianMetal) throws {
        self.configuration = configuration
        self.dataset = dataset
        self.plan = plan
        self.metal = metal
        model = try GaussianModel(metal: metal, capacity: plan.gaussianCapacity, shDegree: configuration.shDegree)
        raster = try GaussianRasterizer(metal: metal, capacity: plan.gaussianCapacity,
                                        intersectionCapacity: plan.intersectionCapacity, maxTiles: 65_536)
        loss = try GaussianLossEvaluator(metal: metal, width: dataset.width, height: dataset.height)
        target = try GaussianRenderTarget(metal: metal, width: dataset.width, height: dataset.height)
        let pixels = dataset.width * dataset.height
        targetImage = try metal.buffer(pixels * 4, label: "target-image")
        edgeMap = try metal.buffer(pixels * 4, label: "edge-map")
        edgeScratch = try metal.buffer(pixels * 4, label: "edge-scratch")
        images = TrainingImageLoader(width: dataset.width, height: dataset.height, slots: plan.imageSlots,
                                     url: { [dataset] in dataset.imageURL($0) })
        adam = try metal.pipeline("adam_step")
        fold = try metal.pipeline("mrnf_fold")
        relocationFold = try metal.pipeline("relocation_fold")
        noise = try metal.pipeline("mrnf_noise")
        share = try metal.pipeline("screen_share")
        edgeBlur = try metal.pipeline("edge_blur")
        edgeSobel = try metal.pipeline("edge_sobel_nms")
        scale = try metal.pipeline("scale_float")
        renderer = try GaussianRenderer(metal: metal, raster: raster, maxPixels: plan.previewPixels)
        let schedule = MRNFSchedule(iterations: configuration.iterations)
        strategy = MRNFStrategy(schedule: schedule, maxGaussians: min(configuration.maxGaussians, plan.gaussianCapacity))
        strategy.seed = configuration.seed
        strategy.trainingViews = dataset.trainFrames.count
        ppisp = PPISPModel(frames: dataset.frames.count, captureEV: dataset.frames.map(\.captureEV))
        poses = Array(repeating: PoseCorrection(), count: dataset.frames.count)
        edgeMedians = Array(repeating: nil, count: dataset.frames.count)
        viewWeights = Array(repeating: 1, count: dataset.frames.count)
        transientMasks = Array(repeating: nil, count: dataset.frames.count)
        transientCandidates = Array(repeating: nil, count: dataset.frames.count)
        poseLearningRate = Self.poseLearningRate(iterations: configuration.iterations, trainFrames: dataset.trainFrames.count)
    }

    /// Seeds the model from the scan's point cloud (subsampled to half the cap to leave room
    /// for densification).
    func initializeModel() throws {
        let points = dataset.points
        guard !points.isEmpty else { throw TrainingError.noSeedPoints }
        let limit = max(1, min(points.count, strategy.maxGaussians / 2))
        let step = Double(points.count) / Double(limit)
        let chosen = (0..<limit).map { points[min(points.count - 1, Int(Double($0) * step))] }
        let raw = chosen.map { SIMD3($0.x, $0.y, $0.z) }
        let positions = seedJitter ? Self.jitteredSeeds(raw, seed: configuration.seed) : raw
        model.initialize(positions: positions,
                         colors: chosen.map { SIMD3(Float($0.r), Float($0.g), Float($0.b)) / 255 })
        strategy.updateBounds(model)
        if growthRamp { strategy.growthStart = model.activeCount }
        iteration = 0
    }

    /// Seeds spread by about their own spacing (Gaussian on every axis, at most 3 cm). Fused
    /// LiDAR surfaces sit ~1 cm from where the photos place them and are sampled as a thin
    /// lattice; starting with some depth lets the optimiser find the photometric surface. On
    /// FBDA13 (2 cm spacing) this raised the aligned held-out PSNR by 0.45 dB with two seeds;
    /// spreading only along the lattice did nothing.
    static func jitteredSeeds(_ positions: [SIMD3<Float>], seed: UInt64) -> [SIMD3<Float>] {
        guard positions.count >= 3 else { return positions }
        let nearest = GaussianModel.twoNearest(positions).map { $0 / 2 }.filter { $0 > 0 }
        guard let spacing = MRNFStrategy.median(nearest), spacing > 0 else { return positions }
        let sigma = min(spacing, maxSeedJitter)
        var rng = SplitMix64(seed: seed &+ 0x5EED)
        func gaussian() -> Float {
            let u1 = max(1e-12, Double(rng.next() >> 11) / Double(1 << 53)), u2 = Double(rng.next() >> 11) / Double(1 << 53)
            return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
        }
        return positions.map { $0 + sigma * SIMD3(gaussian(), gaussian(), gaussian()) }
    }

    static let maxSeedJitter: Float = 0.03

    /// Enhance model: loads the saved model folder (`gaussians.sog` or an older `gaussians.ply`,
    /// the refined training poses and `ppisp.json`) and continues its schedule at
    /// `configuration.startIteration`. The optimiser moments start fresh; poses and the colour
    /// model resume where they were. A SOG model starts from its compressed values.
    func initializeModel(fromSaved directory: URL) throws {
        guard let file = GaussianExport.modelFile(in: directory) else { throw GaussianExport.ExportError.empty }
        try GaussianExport.readModel(file, into: model)
        guard model.activeCount > 0 else { throw GaussianExport.ExportError.empty }
        strategy.updateBounds(model)
        iteration = configuration.startIteration
        pendingFold = nil
        if configuration.poseOptimization {
            // Each refined camera-to-world back to its correction of this dataset's ARKit pose.
            let refined = ScanLibrary.readRecords(directory.appendingPathComponent(GaussianExport.posesName))
            let byID = Dictionary(refined.map { ($0.id, $0.transform) }, uniquingKeysWith: { a, _ in a })
            for (index, frame) in dataset.frames.enumerated() where !frame.isValidation {
                guard let transform = byID[frame.id], transform.count == 16, transform != frame.transform else { continue }
                let base = GaussianCamera.worldToCamera(arkitRowMajorC2W: frame.transform)
                let corrected = GaussianCamera.worldToCamera(arkitRowMajorC2W: transform)
                let correction = PoseCorrection(matrix: corrected * GaussianCamera.rigidInverse(base))
                if correction.rotationDegrees < 5 && correction.translationMeters < 0.1 { poses[index] = correction }
            }
        }
        if configuration.ppisp, let data = try? Data(contentsOf: directory.appendingPathComponent(GaussianExport.ppispName)),
           let file = try? JSONDecoder.training.decode(GaussianExport.PPISPFile.self, from: data) {
            ppisp.restore(file, frames: dataset.frames)
        }
    }

    // MARK: Frame order

    private func nextFrame() -> Int {
        let train = dataset.trainFrames
        if order.isEmpty || epochPosition >= order.count {
            if !order.isEmpty { epoch += 1 }
            epochPosition = 0
            var rng = SplitMix64(seed: configuration.seed &+ UInt64(epoch) &* 0x9E37)
            order = train.shuffled(using: &rng)
        }
        defer { epochPosition += 1 }
        return order[epochPosition]
    }

    private func peekFrame() -> Int? {
        if epochPosition < order.count { return order[epochPosition] }
        return nil
    }

    /// Restores the frame order after loading a checkpoint.
    func restoreOrder(epoch: Int, position: Int) {
        self.epoch = epoch
        var rng = SplitMix64(seed: configuration.seed &+ UInt64(epoch) &* 0x9E37)
        order = dataset.trainFrames.shuffled(using: &rng)
        epochPosition = min(position, order.count)
    }

    func restore(iteration: Int) { self.iteration = iteration; pendingFold = nil }

    /// Folds the last backward pass into the window statistics now (it would happen at the start
    /// of the next step), so a checkpoint holds complete statistics and resumes like an
    /// uninterrupted run.
    func flushPendingFold() throws {
        guard pendingFold != nil, iteration + 1 < strategy.schedule.stopRefine else { pendingFold = nil; return }
        let counts = SIMD2<UInt32>(UInt32(model.count), UInt32(model.capacity))
        let edgeScale = pendingFold ?? 0
        try run("refine") { e in
            e.dispatch(fold, threads: model.count, [.buffer(raster.grad2d), .buffer(model.stats), .value(counts), .f32(edgeScale)])
        }
        strategy.edgeViews += 1
        pendingFold = nil
    }

    // MARK: Cameras

    func camera(frame: Int, activeDegree: Int) -> GaussianCamera {
        let delta = configuration.poseOptimization && !poses[frame].isIdentity ? poses[frame].matrix : nil
        var camera = dataset.camera(frame, delta: delta, mipFilter: configuration.mipFilter, motion: configuration.captureMotion)
        camera.sh = SIMD4(UInt32(activeDegree), UInt32((configuration.shDegree + 1) * (configuration.shDegree + 1)),
                          UInt32(model.count), 0)
        return camera
    }

    var activeDegree: Int { strategy.schedule.shDegree(at: iteration, maximum: configuration.shDegree) }

    // MARK: Step

    /// Accumulated seconds per stage over this trainer's steps: GPU time per command buffer
    /// label (".gpu"), the time the CPU waited for the GPU (".wait"), CPU stages (".cpu", "image"),
    /// whole steps ("step") and tile-Gaussian pairs ("intersections"). Evaluations count under
    /// "evaluate".
    var profile: [String: Double] = [:]
    /// Completed (not skipped) steps `profile` covers.
    private(set) var profiledSteps = 0

    /// `profile` per completed step, in milliseconds ("intersections" as a count); saved in the
    /// training report, so a phone's run records its own split.
    var stageMillisecondsPerStep: [String: Double] {
        guard profiledSteps > 0 else { return [:] }
        let n = Double(profiledSteps)
        return Dictionary(uniqueKeysWithValues: profile.map { key, value in (key, key == "intersections" ? value / n : value / n * 1000) })
    }

    private typealias Submitted = (buffer: MTLCommandBuffer, label: String)

    private func run(_ label: String = "gpu", _ body: (MTLComputeCommandEncoder) throws -> Void) throws {
        try wait([submit(label, body)])
    }

    /// Encodes and commits one command buffer without waiting, so CPU work can overlap it.
    private func submit(_ label: String, _ body: (MTLComputeCommandEncoder) throws -> Void) throws -> Submitted {
        guard let buffer = metal.queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else {
            throw TrainingError.gpuFailure("command buffer")
        }
        try body(encoder)
        encoder.endEncoding()
        buffer.commit()
        return (buffer, label)
    }

    /// Waits for command buffers committed in this order and checks each one. `profile` gets
    /// their GPU time by label and the time the CPU was blocked, under the last one's label.
    private func wait(_ chain: [Submitted]) throws {
        let blocked = Date()
        for item in chain { item.buffer.waitUntilCompleted() }
        if let last = chain.last { profile[last.label + ".wait", default: 0] += Date().timeIntervalSince(blocked) }
        for item in chain {
            profile[item.label + ".gpu", default: 0] += item.buffer.gpuEndTime - item.buffer.gpuStartTime
            if let error = item.buffer.error { throw TrainingError.gpuFailure(error.localizedDescription) }
        }
    }

    private var imageGroups: (Int, Int) { ((dataset.width + 15) / 16, (dataset.height + 15) / 16) }

    /// Edge map of the target image (unnormalised); the positive median is cached per frame.
    private func encodeEdges(_ e: MTLComputeCommandEncoder) {
        let size = SIMD2<UInt32>(UInt32(dataset.width), UInt32(dataset.height))
        e.dispatch(edgeBlur, groups: imageGroups, size: (16, 16), [.buffer(targetImage), .buffer(edgeScratch), .value(size)])
        e.dispatch(edgeSobel, groups: imageGroups, size: (16, 16), [.buffer(edgeScratch), .buffer(edgeMap), .value(size)])
    }

    private func edgeMedian(_ index: Int) -> Float {
        if let cached = edgeMedians[index] { return cached }
        let n = dataset.width * dataset.height
        let values = edgeMap.contents().bindMemory(to: Float.self, capacity: n)
        let positive = Swift.stride(from: 0, to: n, by: max(1, n / 40_000)).compactMap { values[$0] > 0 ? values[$0] : nil }
        let median = MRNFStrategy.median(positive) ?? 0
        edgeMedians[index] = median
        return median
    }

    /// Folds the previous backward pass, then adds position noise (MRNF post_backward order).
    private func encodePostBackward(_ e: MTLComputeCommandEncoder, iteration t: Int) {
        let refining = t < strategy.schedule.stopRefine
        let counts = SIMD2<UInt32>(UInt32(model.count), UInt32(model.capacity))
        if let edgeScale = pendingFold, refining {
            e.dispatch(fold, threads: model.count, [.buffer(raster.grad2d), .buffer(model.stats), .value(counts), .f32(edgeScale)])
        }
        if refining && strategy.bounds.valid {
            let lr = Double(strategy.meansLR(at: t)) * MRNFConstants.noiseWeight
            e.dispatch(noise, threads: model.count,
                       [.buffer(model.params), .buffer(model.stats),
                        .value(SIMD4<UInt32>(UInt32(model.count), UInt32(model.capacity), UInt32(truncatingIfNeeded: t &* 7919), model.layout.opacities)),
                        .value(SIMD2<Float>(Float(lr), strategy.bounds.medianSize))])
        }
    }

    /// One optimisation iteration on the next training view. Its command buffers, encoders and
    /// file reads are autoreleased objects: the training thread has no run loop to drain them,
    /// so without this pool they would pile up for the whole run.
    func step() throws -> TrainingStepReport {
        try autoreleasepool { try trainStep() }
    }

    private func trainStep() throws -> TrainingStepReport {
        let started = Date()
        let t = iteration + 1
        let schedule = strategy.schedule
        let refining = t < schedule.stopRefine
        let frame = nextFrame()
        if let next = peekFrame() { images.prefetch(next) }
        let folded = pendingFold != nil && refining
        var refineReport: MRNFStrategy.Report?
        let refineNow = schedule.isRefining(t)
        if refineNow {
            // Refinement edits rows on the CPU, so the GPU work before it must finish first.
            try run("refine") { e in encodePostBackward(e, iteration: t) }
            pendingFold = nil
            if folded { strategy.edgeViews += 1 }
            if growthFrozen { strategy.maxGaussians = min(strategy.maxGaussians, model.activeCount) }
            let seeds = configuration.usesHoleFilling && !growthFrozen && t < schedule.growUntil && t >= 3 * schedule.refineEvery
                ? lastRendered.map { holeSeeds(frame: $0) } ?? [] : []
            let refineStarted = Date()
            refineReport = strategy.refine(model, iteration: t, seeds: seeds, replaceByError: replaceByError, relocate: relocation,
                                           regionMode: regionMode)
            profile["refine.cpu", default: 0] += Date().timeIntervalSince(refineStarted)
            holeSeedsAdded += refineReport?.holes ?? 0
        }
        iteration = t
        let degree = activeDegree
        let loadStarted = Date()
        try images.load(frame, into: targetImage.contents())
        profile["image", default: 0] += Date().timeIntervalSince(loadStarted)
        let cam = camera(frame: frame, activeDegree: degree)
        let count = model.count
        raster.resetTotal()
        try run("project") { e in
            if !refineNow { encodePostBackward(e, iteration: t) }
            encodeEdges(e)
            try raster.encodeProjection(e, camera: cam, layout: model.layout, model: model.params, count: count)
            e.dispatch(share, threads: count, [.buffer(model.params), .buffer(model.stats), .buffer(raster.tiles),
                                               .value(SIMD4<UInt32>(UInt32(count), UInt32(model.capacity), model.layout.scales, model.layout.opacities)),
                                               .value(cam.center)])
        }
        if !refineNow {
            if folded { strategy.edgeViews += 1 }
            pendingFold = nil
        }
        let intersections = raster.intersectionCount
        if intersections > raster.intersectionCapacity {
            overflowStreak += 1
            growthFrozen = true
            if overflowStreak >= 8 { throw TrainingError.repeatedOverflow }
            return TrainingStepReport(iteration: t, frame: frame, loss: .nan, psnr: .nan, gaussians: model.activeCount,
                                      seconds: Date().timeIntervalSince(started), skipped: true, refine: refineReport)
        }
        overflowStreak = 0
        let median = edgeMedian(frame)

        let usesISP = configuration.ppisp
        let uniforms = usesISP ? ppisp.uniforms(frame: frame) : nil
        model.adamStep += 1
        let pixels = dataset.width * dataset.height
        profile["intersections", default: 0] += Double(intersections)
        let masking = transientMasking && Double(t) >= Self.transientStart * Double(configuration.iterations)
        let mask = masking ? transientMasks[frame] : nil
        if let mask {
            let weights = loss.blockWeight.contents().bindMemory(to: Float.self, capacity: mask.count)
            for i in mask.indices { weights[i] = Float(mask[i]) / 255 }
        }
        do {
            // The render and loss, the backward bands and the projection backward are committed
            // back to back and waited for once (each band stays its own command buffer for the
            // GPU watchdog). They write only gradients and render outputs; the parameters and
            // statistics change after all of them succeeded. The LiDAR target is prepared on the
            // CPU meanwhile (the previous backward pass, its only reader, has finished).
            var chain = [try submit("forward") { e in
                e.dispatch(scale, threads: pixels, [.buffer(edgeMap), .value(SIMD2<Float>(median > 0 ? 1 / median : 0, Float(pixels)))])
                try raster.encodeRaster(e, camera: cam, count: count, intersections: intersections, target: target,
                                        background: .zero)
                loss.encode(e, raw: target.image, target: targetImage, ppisp: uniforms, weight: viewWeights[frame], mask: mask != nil)
            }]
            let lidarStarted = Date()
            let depthTarget = try lidarTarget(frame: frame, iteration: t)
            profile["lidar.cpu", default: 0] += Date().timeIntervalSince(lidarStarted)
            if masking {
                try wait(chain)
                chain.removeAll()
                transientMasks[frame] = transientMask(frame)
            }
            for (band, rows) in GaussianRasterizer.backwardBands(tilesX: cam.tilesX, tilesY: cam.tilesY).enumerated() {
                chain.append(try submit("backward") { e in
                    if band == 0 { raster.encodeBackwardClear(e, count: count) }
                    raster.encodeBackwardBlend(e, camera: cam, layout: model.layout, count: count, target: target, background: .zero,
                                               imageGrad: loss.rawGrad, errorMap: loss.errorMap, edgeMap: edgeMap, lossSums: loss.sums,
                                               depth: depthTarget, rows: rows)
                })
            }
            chain.append(try submit("backward") { e in
                raster.encodeProjectBackward(e, camera: cam, layout: model.layout, model: model.params, grads: model.grads, count: count)
            })
            try wait(chain)
        } catch TrainingError.gpuFailure(let reason) {
            // Nothing has touched the parameters yet (the backward pass overwrites the gradients),
            // so a watchdog abort or transient GPU fault skips this view instead of ending the run.
            model.adamStep -= 1
            gpuSkipStreak += 1
            if gpuSkipStreak >= 3 { throw TrainingError.gpuFailure(reason) }
            return TrainingStepReport(iteration: t, frame: frame, loss: .nan, psnr: .nan, gaussians: model.activeCount,
                                      seconds: Date().timeIntervalSince(started), skipped: true, refine: refineReport)
        }
        gpuSkipStreak = 0
        try run("adam") { e in
            if refining {
                e.dispatch(relocationFold, threads: count, [.buffer(raster.grad2d), .buffer(model.stats),
                                                            .value(SIMD2<UInt32>(UInt32(count), UInt32(model.capacity))), .buffer(raster.tiles)])
            }
            encodeAdam(e, iteration: t, count: count)
        }
        let postStarted = Date()
        defer {
            profile["post.cpu", default: 0] += Date().timeIntervalSince(postStarted)
            profile["step", default: 0] += Date().timeIntervalSince(started)
            profiledSteps += 1
        }
        let values = loss.values
        lastPSNR = values.psnr
        lastRendered = frame
        // Per-view edge normalisation for the next fold: positive median of sum(w * edge).
        if refining {
            let g2 = raster.grad2d.contents().bindMemory(to: Float.self, capacity: count * GaussianRasterizer.grad2DStride)
            let stride = max(1, count / 20_000), s2 = GaussianRasterizer.grad2DStride
            let positive = Swift.stride(from: 0, to: count, by: stride).compactMap { g2[$0 * s2 + 11] > 0 ? g2[$0 * s2 + 11] : nil }
            let median = MRNFStrategy.median(positive) ?? 0
            pendingFold = median > 0 ? 1 / median : 0
        }
        if usesISP {
            var gradient = [Double](repeating: 0, count: ppisp.count)
            ppisp.parameterGradient(frame: frame, slots: loss.ppispSlots, into: &gradient)
            _ = ppisp.regularizer(into: &gradient)
            ppisp.adamStep(gradient: gradient, warmup: schedule.ppispWarmup, total: configuration.iterations)
        }
        if configuration.poseOptimization && t >= poseStart {
            let base = GaussianCamera.worldToCamera(arkitRowMajorC2W: dataset.frames[frame].transform)
            let progress = Double(t - poseStart) / Double(max(1, configuration.iterations - poseStart))
            poses[frame].update(poseGradient: raster.poseGradient, base: base,
                                learningRate: poseLearningRate * pow(0.1, progress),
                                neighbours: poseSmoothing > 0 ? neighbourCorrection(frame) : nil, neighbourWeight: poseSmoothing)
        }
        return TrainingStepReport(iteration: t, frame: frame, loss: values.loss, psnr: values.psnr,
                                  gaussians: model.activeCount, seconds: Date().timeIntervalSince(started),
                                  refine: refineReport)
    }

    /// Dense Adam on every optimiser group at step `model.adamStep` (MRNF's regularisers), in
    /// one dispatch. `raster.tiles` must hold this view's projection (tests call it directly).
    func encodeAdam(_ e: MTLComputeCommandEncoder, iteration t: Int, count: Int) {
        let schedule = strategy.schedule
        let refining = t < schedule.stopRefine
        let adamT = Double(model.adamStep)
        let lrs: [Float] = [strategy.meansLR(at: t), strategy.scalesLR(at: t), Float(MRNFConstants.rotationLR),
                            Float(MRNFConstants.opacityLR), Float(MRNFConstants.sh0LR), Float(MRNFConstants.shNLR)]
        var groups: [AdamGroup] = []
        var threads = 0
        for (g, group) in model.layout.groups.enumerated() {
            let skip = g == 5 && (t <= schedule.shWarmup || group.width == 0)
            guard !skip else { continue }
            groups.append(AdamGroup(offset: UInt32(group.offset), width: UInt32(group.width), start: UInt32(threads),
                                    mode: g == 3 ? 1 : (g == 1 && refining ? 2 : 0), lr: lrs[g]))
            threads += count * group.width
        }
        let params = AdamParams(beta1: 0.9, beta2: 0.999, epsilon: 1e-15,
                                biasCorrection1: Float(1 - pow(0.9, adamT)), biasCorrection2: Float(1 - pow(0.999, adamT)),
                                opacityReg: MRNFConstants.opacityRegularizer / Float(max(1, model.activeCount)),
                                sharePenalty: MRNFConstants.screenSharePenalty, shareLimit: MRNFConstants.maxScreenShare,
                                rows: UInt32(count), capacity: UInt32(model.capacity), groups: UInt32(groups.count),
                                visibleOnly: sparseAdam ? 1 : 0)
        e.dispatch(adam, threads: threads,
                   [.buffer(model.params), .buffer(model.grads), .buffer(model.adamM), .buffer(model.adamV),
                    .buffer(model.stats), .value(params), .buffer(raster.tiles), .array(groups)])
    }

    /// Mean correction of the nearest training photos before and after `frame` in capture order
    /// (frames are sorted by ID; held-out photos are skipped).
    private func neighbourCorrection(_ frame: Int) -> (rotation: SIMD3<Double>, translation: SIMD3<Double>)? {
        let frames = dataset.frames
        var picked: [PoseCorrection] = []
        for direction in [-1, 1] {
            var j = frame + direction
            while j >= 0 && j < frames.count && frames[j].isValidation { j += direction }
            guard j >= 0, j < frames.count else { continue }
            picked.append(poses[j])
        }
        guard !picked.isEmpty else { return nil }
        let n = Double(picked.count)
        return (picked.map(\.rotation).reduce(.zero, +) / n, picked.map(\.translation).reduce(.zero, +) / n)
    }

    /// Block weights (255 = keep, 0 = transient) from the block differences of the forward pass.
    private func transientMask(_ frame: Int) -> [UInt8] {
        let (columns, rows) = loss.blocks
        let n = columns * rows
        // -1: a block the render barely covers (no evidence).
        let d = Array(UnsafeBufferPointer(start: loss.blockDifference.contents().bindMemory(to: Float.self, capacity: n), count: n))
        let threshold = max(Self.transientFloor, Self.transientFactor * (MRNFStrategy.median(d.filter { $0 >= 0 }) ?? 0))
        var candidate = [Bool](repeating: false, count: n)
        for r in 0..<rows {
            for c in 0..<columns where d[r * columns + c] > threshold {
                let neighbours = [(c - 1, r), (c + 1, r), (c, r - 1), (c, r + 1)]
                candidate[r * columns + c] = neighbours.contains { $0.0 >= 0 && $0.1 >= 0 && $0.0 < columns && $0.1 < rows && d[$0.1 * columns + $0.0] > threshold }
            }
        }
        let previous = transientCandidates[frame]
        transientCandidates[frame] = candidate
        var mask = [UInt8](repeating: 255, count: n)
        var masked = 0
        if let previous { for i in 0..<n where candidate[i] && previous[i] { mask[i] = 0; masked += 1 } }
        transientMaskedShare = (transientMaskedShare.blocks + masked, transientMaskedShare.total + n)
        return mask
    }

    // MARK: LiDAR depth loss

    /// The photo's LiDAR depth for the depth loss: medium/high confidence, 0.1-5 m, and not
    /// at a depth edge (LiDAR blurs discontinuities at 256 × 192), else 0.
    private func lidarTarget(frame: Int, iteration t: Int) throws -> GaussianRasterizer.DepthTarget? {
        let weight = configuration.depthLossWeight
        guard weight > 0, let lidar = dataset.lidarDepth(frame) else { return nil }
        let w = lidar.width, h = lidar.height
        if lidarBuffer == nil || lidarBuffer!.length < w * h * 4 { lidarBuffer = try metal.buffer(w * h * 4, label: "lidar-depth") }
        let out = lidarBuffer!.contents().bindMemory(to: Float.self, capacity: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x, z = lidar.depth[i]
                var ok = z.isFinite && z > 0.1 && z < 5 && lidar.confidence[i] >= 1
                if ok {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let n = lidar.depth[ny * w + nx]
                        if !(abs(n - z) <= 0.05 * z) { ok = false; break }
                    }
                }
                out[i] = ok ? z : 0
            }
        }
        let progress = Double(t) / Double(max(1, configuration.iterations))
        let perPixel = weight * (1 - 0.9 * progress) / Double(dataset.width * dataset.height)
        return GaussianRasterizer.DepthTarget(buffer: lidarBuffer!, width: w, height: h, weight: Float(perPixel))
    }

    // MARK: Hole filling

    /// Pixels of the last rendered view that Gaussians barely cover (final transmittance > 0.4)
    /// but the photo shows something (colour error > 0.08), on a coarse grid, worst first.
    /// Each gets a seed on its camera ray at the photo's LiDAR depth, or else at the median
    /// depth of covered pixels nearby. Wrong guesses fade (decay, opacity regularisation) and
    /// are pruned; densification alone only splits existing Gaussians, so it never reaches
    /// surfaces that start without any.
    func holeSeeds(frame: Int) -> [MRNFStrategy.Seed] {
        let W = dataset.width, H = dataset.height, n = W * H
        let render = target.image.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let depth = target.depth.contents().bindMemory(to: Float.self, capacity: n)
        let photo = targetImage.contents().bindMemory(to: UInt8.self, capacity: n * 4)
        let cam = camera(frame: frame, activeDegree: 0)
        let lidar = dataset.lidarDepth(frame)
        let step = max(4, W / 120)
        var candidates: [(error: Float, x: Int, y: Int, color: SIMD3<Float>)] = []
        for y in Swift.stride(from: step / 2, to: H, by: step) {
            for x in Swift.stride(from: step / 2, to: W, by: step) {
                let i = y * W + x
                let r = render[i]
                guard r.w > Self.holeTransmittance else { continue }
                let c = SIMD3(Float(photo[4 * i]), Float(photo[4 * i + 1]), Float(photo[4 * i + 2])) / 255
                let error = simd_reduce_add(simd_abs(c - SIMD3(r.x, r.y, r.z))) / 3
                if error > 0.08 { candidates.append((error, x, y, c)) }
            }
        }
        candidates.sort { $0.error > $1.error }
        var seeds: [MRNFStrategy.Seed] = []
        for c in candidates.prefix(MRNFConstants.maxHoleSeedsPerRefine) {
            var z: Float?
            if let lidar {
                let lx = min(lidar.width - 1, Int((Float(c.x) + 0.5) * Float(lidar.width) / Float(W)))
                let ly = min(lidar.height - 1, Int((Float(c.y) + 0.5) * Float(lidar.height) / Float(H)))
                let d = lidar.depth[ly * lidar.width + lx]
                if d.isFinite, d > 0.1, d < 8, lidar.confidence[ly * lidar.width + lx] >= 1 || d < 4 { z = d }
            }
            if z == nil {
                // Expected depth of covered pixels within ±24 px (normalised by coverage).
                var near: [Float] = []
                let radius = 24
                for yy in Swift.stride(from: max(0, c.y - radius), through: min(H - 1, c.y + radius), by: 4) {
                    for xx in Swift.stride(from: max(0, c.x - radius), through: min(W - 1, c.x + radius), by: 4) {
                        let j = yy * W + xx
                        let coverage = 1 - render[j].w
                        if coverage > 0.7 { near.append(depth[j] / coverage) }
                    }
                }
                z = MRNFStrategy.median(near.filter { $0.isFinite && $0 > 0.05 })
            }
            guard let z, z.isFinite, z > GaussianCamera.nearPlane else { continue }
            let position = cam.backProject(x: Float(c.x) + 0.5, y: Float(c.y) + 0.5, depth: z)
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { continue }
            // Half the grid spacing in pixels, at that depth.
            seeds.append(MRNFStrategy.Seed(position: position, color: c.color, scale: 0.5 * Float(step) * z / cam.intrinsics.x))
        }
        return seeds
    }

    /// A pixel counts as a hole above this final transmittance (and 0.08 colour error). Empty
    /// regions are often half covered by stretched neighbours, so fully empty is too strict.
    static let holeTransmittance: Float = 0.4

    // MARK: Rendering and evaluation

    /// ISP for a view: a training frame uses its learned exposure and colour; a novel view uses
    /// the camera's vignetting and response with neutral exposure and colour (`exposureEV` added).
    func ispUniforms(frame: Int?, exposureEV: Double = 0) -> PPISPUniforms? {
        guard configuration.ppisp else { return nil }
        return ppisp.uniforms(frame: frame, exposureOffsetEV: exposureEV)
    }

    /// Renders the current model for display (same rasterizer, mip filter and PPISP as training).
    func renderPreview(camera: GaussianCamera, frame: Int?, mode: ISPMode) throws -> RenderedFrame? {
        let isp = mode == .off ? nil : ispUniforms(frame: frame)
        return try renderer.render(model: model, camera: camera, shDegree: activeDegree, isp: isp)
    }

    /// PSNR / SSIM on the held-out views (ARKit poses; novel-view ISP with the capture
    /// exposure difference, like LichtFeld's evaluation without a controller). `alignSteps` > 0
    /// first aligns each held-out camera to the frozen model (test-time pose optimisation), the
    /// fair comparison when training refined the other poses.
    /// Test-time pose corrections of held-out views from the last aligned evaluation.
    private(set) var heldOutAlignment: [Int: PoseCorrection] = [:]

    func evaluate(frames: [Int]? = nil, alignSteps: Int = 0, captureMotion: Bool = true,
                  progress: ((_ done: Int, _ of: Int) -> Void)? = nil) throws -> (psnr: Double, ssim: Double, count: Int) {
        let list = frames ?? dataset.validationFrames
        guard !list.isEmpty, model.count > 0 else { return (0, 0, 0) }
        if alignSteps > 0 { try flushPendingFold() }
        var psnr = 0.0, ssim = 0.0, n = 0
        let degree = activeDegree
        for (position, index) in list.enumerated() {
            progress?(position, list.count)
            try images.load(index, into: targetImage.contents())
            let ev = dataset.frames[index].captureEV.flatMap { ev in ppisp.seedMeanEV.map { 0.5 * (ev - $0) } } ?? 0
            let heldOut = dataset.frames[index].isValidation
            let isp = ispUniforms(frame: heldOut ? nil : index, exposureEV: heldOut ? ev : 0)
            var correction = heldOut ? PoseCorrection() : poses[index]
            let base = GaussianCamera.worldToCamera(arkitRowMajorC2W: dataset.frames[index].transform)
            var ok = true
            for pass in 0...(heldOut ? alignSteps : 0) {
                let usesDelta = !correction.isIdentity && (heldOut || configuration.poseOptimization)
                var cam = dataset.camera(index, delta: usesDelta ? correction.matrix : nil, mipFilter: configuration.mipFilter,
                                         motion: captureMotion ? configuration.captureMotion : nil)
                cam.sh = SIMD4(UInt32(degree), UInt32((configuration.shDegree + 1) * (configuration.shDegree + 1)), UInt32(model.count), 0)
                raster.resetTotal()
                try run("evaluate") { e in try raster.encodeProjection(e, camera: cam, layout: model.layout, model: model.params, count: model.count) }
                let m = raster.intersectionCount
                guard m <= raster.intersectionCapacity else { ok = false; break }
                let aligning = heldOut && pass < alignSteps
                try run("evaluate") { e in
                    try raster.encodeRaster(e, camera: cam, count: model.count, intersections: m, target: target, background: .zero)
                    loss.encode(e, raw: target.image, target: targetImage, ppisp: isp)
                    if aligning {
                        raster.encodeBackward(e, camera: cam, layout: model.layout, model: model.params, grads: model.grads,
                                              count: model.count, target: target, background: .zero, imageGrad: loss.rawGrad,
                                              errorMap: loss.errorMap, edgeMap: edgeMap, lossSums: loss.sums)
                    }
                }
                if aligning { correction.update(poseGradient: raster.poseGradient, base: base, learningRate: 3e-4) }
            }
            guard ok else { continue }
            if heldOut && alignSteps > 0 { heldOutAlignment[index] = correction }
            let v = loss.values
            psnr += v.psnr; ssim += v.ssim; n += 1
        }
        return n > 0 ? (psnr / Double(n), ssim / Double(n), n) : (0, 0, 0)
    }

    /// Held-out PSNR/SSIM when rendering at `scale` × the training resolution against photos
    /// downsampled to the same size: zoomed-out views (where the mip filter matters) or, above 1,
    /// the photos' own resolution (detail the training resolution cannot hold). `aligned` reuses
    /// the test-time pose corrections of the last aligned evaluation. Larger renders get their
    /// own rasterizer (evaluation tools only; the training plan does not include it).
    /// `inspect` receives each view's final image (after the ISP, as scored), the photo and the
    /// view's SSIM.
    func evaluate(scale: Double, frames: [Int]? = nil, aligned: Bool = false,
                  inspect: ((_ index: Int, _ image: UnsafePointer<SIMD4<Float>>, _ photo: UnsafePointer<UInt8>, _ width: Int, _ height: Int,
                             _ ssim: Double) -> Void)? = nil)
        throws -> (psnr: Double, ssim: Double, count: Int) {
        let list = frames ?? dataset.validationFrames
        guard !list.isEmpty, model.count > 0 else { return (0, 0, 0) }
        let w = max(16, Int((Double(dataset.width) * scale).rounded())), h = max(16, Int((Double(dataset.height) * scale).rounded()))
        let scaledLoss = try GaussianLossEvaluator(metal: metal, width: w, height: h)
        let scaledTarget = try GaussianRenderTarget(metal: metal, width: w, height: h)
        let raster = scale > 1 ? try GaussianRasterizer(metal: metal, capacity: model.capacity,
                                                        intersectionCapacity: Int(Double(self.raster.intersectionCapacity) * scale * scale),
                                                        maxTiles: 65_536) : self.raster
        let photo = try metal.buffer(w * h * 4)
        var psnr = 0.0, ssim = 0.0, n = 0
        for index in list {
            guard let pixels = TrainingImageLoader.decode(dataset.imageURL(index), width: w, height: h) else { continue }
            pixels.withUnsafeBytes { photo.contents().copyMemory(from: $0.baseAddress!, byteCount: w * h * 4) }
            let f = dataset.frames[index]
            let sx = Double(w) / Double(f.intrinsics.width), sy = Double(h) / Double(f.intrinsics.height)
            var w2c = GaussianCamera.worldToCamera(arkitRowMajorC2W: f.transform)
            if aligned, let correction = f.isValidation ? heldOutAlignment[index] : (configuration.poseOptimization ? poses[index] : nil) {
                w2c = correction.matrix * w2c
            }
            var cam = GaussianCamera(worldToCamera: w2c,
                                     fx: f.intrinsics.fx * sx, fy: f.intrinsics.fy * sy, cx: f.intrinsics.cx * sx, cy: f.intrinsics.cy * sy,
                                     width: w, height: h, mipFilter: configuration.mipFilter)
            cam.sh = SIMD4(UInt32(activeDegree), UInt32((configuration.shDegree + 1) * (configuration.shDegree + 1)), UInt32(model.count), 0)
            raster.resetTotal()
            try run("evaluate") { e in try raster.encodeProjection(e, camera: cam, layout: model.layout, model: model.params, count: model.count) }
            let m = raster.intersectionCount
            guard m <= raster.intersectionCapacity else { continue }
            let ev = f.captureEV.flatMap { ev in ppisp.seedMeanEV.map { 0.5 * (ev - $0) } } ?? 0
            let isp = ispUniforms(frame: f.isValidation ? nil : index, exposureEV: f.isValidation ? ev : 0)
            try run("evaluate") { e in
                try raster.encodeRaster(e, camera: cam, count: model.count, intersections: m, target: scaledTarget, background: .zero)
                scaledLoss.encode(e, raw: scaledTarget.image, target: photo, ppisp: isp)
            }
            let v = scaledLoss.values
            if let inspect {
                let image = (isp != nil ? scaledLoss.isp : scaledTarget.image).contents().bindMemory(to: SIMD4<Float>.self, capacity: w * h)
                inspect(index, image, photo.contents().bindMemory(to: UInt8.self, capacity: w * h * 4), w, h, v.ssim)
            }
            psnr += v.psnr; ssim += v.ssim; n += 1
        }
        return n > 0 ? (psnr / Double(n), ssim / Double(n), n) : (0, 0, 0)
    }

    // MARK: Profiling

    /// Milliseconds of each stage of a training step on `frames` (tools): the step's kernels in
    /// its order with one command buffer per stage (GPU time), and its CPU stages. `profile`
    /// holds a run's split by command buffer. These steps run Adam and the MRNF kernels, so the
    /// model does not stay as it was: call this after the run's evaluation and saving.
    func profileStages(frames: [Int], iteration at: Int? = nil) throws -> [(stage: String, milliseconds: [Double])] {
        var stages: [(stage: String, milliseconds: [Double])] = []
        func record(_ stage: String, _ ms: Double) {
            if let i = stages.firstIndex(where: { $0.stage == stage }) { stages[i].milliseconds.append(ms) }
            else { stages.append((stage, [ms])) }
        }
        func gpu(_ body: (MTLComputeCommandEncoder) throws -> Void) throws -> Double {
            let buffer = try submit("profile", body).buffer
            buffer.waitUntilCompleted()
            if let error = buffer.error { throw TrainingError.gpuFailure(error.localizedDescription) }
            return (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
        }
        func timed(_ stage: String, _ body: (MTLComputeCommandEncoder) throws -> Void) throws { record(stage, try gpu(body)) }
        let t = max(1, at ?? iteration), count = model.count, pixels = dataset.width * dataset.height
        let refining = t < strategy.schedule.stopRefine
        for frame in frames {
            let decodeStarted = Date()
            guard let photo = TrainingImageLoader.decode(dataset.imageURL(frame), width: dataset.width, height: dataset.height) else { continue }
            record("image decode (CPU)", Date().timeIntervalSince(decodeStarted) * 1000)
            photo.withUnsafeBytes { targetImage.contents().copyMemory(from: $0.baseAddress!, byteCount: pixels * 4) }
            let cam = camera(frame: frame, activeDegree: activeDegree)
            pendingFold = 1
            try timed("MRNF fold + noise") { e in encodePostBackward(e, iteration: t) }
            pendingFold = nil
            try timed("edge map") { e in encodeEdges(e) }
            try timed("project") { e in
                raster.encodeProject(e, camera: cam, layout: model.layout, model: model.params, count: count)
                e.dispatch(share, threads: count, [.buffer(model.params), .buffer(model.stats), .buffer(raster.tiles),
                                                   .value(SIMD4<UInt32>(UInt32(count), UInt32(model.capacity), model.layout.scales, model.layout.opacities)),
                                                   .value(cam.center)])
            }
            try timed("depth sort") { e in try raster.encodeDepthOrder(e, count: count) }
            raster.resetTotal()
            try timed("tile offsets") { e in try raster.encodeTileOffsets(e, count: count) }
            let intersections = raster.intersectionCount
            guard intersections <= raster.intersectionCapacity else { continue }
            try timed("emit pairs") { e in try raster.encodeEmit(e, camera: cam, count: count, intersections: intersections) }
            try timed("tile sort") { e in try raster.encodeTileSort(e, intersections: intersections) }
            let median = edgeMedian(frame)
            try timed("blend forward") { e in
                e.dispatch(scale, threads: pixels, [.buffer(edgeMap), .value(SIMD2<Float>(median > 0 ? 1 / median : 0, Float(pixels)))])
                raster.encodeBlend(e, camera: cam, count: count, target: target, background: .zero)
            }
            let uniforms = configuration.ppisp ? ppisp.uniforms(frame: frame) : nil
            try timed("loss forward") { e in loss.encodeForward(e, raw: target.image, target: targetImage, ppisp: uniforms) }
            try timed("loss backward") { e in loss.encodeBackward(e, raw: target.image, target: targetImage, ppisp: uniforms) }
            let lidarStarted = Date()
            let depth = try lidarTarget(frame: frame, iteration: t)
            record("LiDAR target (CPU)", Date().timeIntervalSince(lidarStarted) * 1000)
            var backward = 0.0
            for (band, rows) in GaussianRasterizer.backwardBands(tilesX: cam.tilesX, tilesY: cam.tilesY).enumerated() {
                backward += try gpu { e in
                    if band == 0 { raster.encodeBackwardClear(e, count: count) }
                    raster.encodeBackwardBlend(e, camera: cam, layout: model.layout, count: count, target: target, background: .zero,
                                               imageGrad: loss.rawGrad, errorMap: loss.errorMap, edgeMap: edgeMap, lossSums: loss.sums,
                                               depth: depth, rows: rows)
                }
            }
            record("blend backward", backward)
            try timed("project backward") { e in
                raster.encodeProjectBackward(e, camera: cam, layout: model.layout, model: model.params, grads: model.grads, count: count)
            }
            model.adamStep += 1     // a step count, as in training (a restored model starts at 0)
            try timed("adam") { e in
                if refining {
                    e.dispatch(relocationFold, threads: count, [.buffer(raster.grad2d), .buffer(model.stats),
                                                                .value(SIMD2<UInt32>(UInt32(count), UInt32(model.capacity))), .buffer(raster.tiles)])
                }
                encodeAdam(e, iteration: t, count: count)
            }
            record("intersections (thousands)", Double(intersections) / 1000)
        }
        return stages
    }

    /// Drops cached images and freezes growth (memory pressure).
    func reduceMemory() {
        images.purge()
        growthFrozen = true
        strategy.maxGaussians = min(strategy.maxGaussians, max(model.activeCount, 1))
    }
}

/// Mirrors `AdamParams` in GaussianOptim.metal.
nonisolated struct AdamParams {
    var beta1: Float, beta2: Float, epsilon: Float
    var biasCorrection1: Float, biasCorrection2: Float
    var opacityReg: Float, sharePenalty: Float, shareLimit: Float
    var rows: UInt32, capacity: UInt32, groups: UInt32, visibleOnly: UInt32 = 0
}

/// Mirrors `AdamGroup` in GaussianOptim.metal (32 bytes).
nonisolated struct AdamGroup {
    var offset: UInt32, width: UInt32, start: UInt32, mode: UInt32
    var lr: Float
    var unused0: Float = 0, unused1: Float = 0, unused2: Float = 0
}
