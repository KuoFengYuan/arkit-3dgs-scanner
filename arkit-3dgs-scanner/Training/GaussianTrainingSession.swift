// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import simd
import ImageIO
import UniformTypeIdentifiers

/// Live values of a running session for the UI (published a few times per second).
nonisolated struct TrainingSnapshot: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, running, paused, finishing, completed, failed, cancelled }
    var phase: Phase = .preparing
    var reason: TrainingRecord.Reason?
    var iteration = 0
    var total = 0
    var loss: Double?
    var psnr: Double?
    var gaussians = 0
    var elapsedSeconds = 0.0
    var secondsPerIteration: Double?
    var checkpointIteration: Int?
    var footprintMB = 0
    var plannedMB = 0
    var throttled = false
    var growthFrozen = false
    var message: String?
    var validationPSNR: Double?
    var preparationProgress = 0.0
    /// Where this run started: the saved model's iteration for Enhance model, else 0.
    var startIteration = 0

    var remainingSeconds: Double? {
        guard let s = secondsPerIteration, phase == .running, total > iteration else { return nil }
        return s * Double(total - iteration)
    }
}

/// What the live viewer wants to see.
nonisolated struct ViewerRequest: Equatable, Sendable {
    var orbit: OrbitCamera?
    /// Show a capture camera exactly (with its learned exposure/colour) instead of the orbit.
    var captureFrame: Int?
    var width: Int
    var height: Int
    var mode: ISPMode
}

/// Runs one scan's on-device training on a background thread. Controls are thread-safe; the
/// loop checks them between iterations, renders throttled previews, checkpoints periodically
/// and whenever it pauses, and exports the model when it finishes.
nonisolated final class GaussianTrainingSession: @unchecked Sendable {
    let workspace: TrainingWorkspace
    let configuration: GaussianTrainingConfiguration
    private let libraryURL: URL?
    private let resume: Bool

    /// Environment probes (the app wires thermal state, battery and memory; tools leave defaults).
    var thermalLevel: @Sendable () -> Int = { 0 }          // 0 nominal … 3 critical
    var batteryLow: @Sendable () -> Bool = { false }
    var lowPowerMode: @Sendable () -> Bool = { false }
    var onSnapshot: @Sendable (TrainingSnapshot) -> Void = { _ in }
    var onFrame: @Sendable (RenderedFrame, ViewerRequest) -> Void = { _, _ in }
    var onPreparedViews: @Sendable (_ views: [TrainingFrame], _ initialDepth: Double) -> Void = { _, _ in }

    // Checkpoints are written only when the run pauses, when the app leaves the foreground
    // (even if training continues in the background), and when stopping with the progress
    // kept. Each replaces the previous one (`GaussianCheckpoint.save`); a 600,000-Gaussian
    // checkpoint is about 425 MB, so periodic ones cost storage writes for little benefit.
    static let previewInterval = 1.5          // seconds between automatic live-view refreshes
    static let interactiveInterval = 0.08     // while the user moves the camera

    private let lock = NSCondition()
    private var pauseRequested = false
    private var cancelRequested: Bool?        // keep checkpoint?
    private var checkpointRequested = false
    /// Finish now: save the current model as the result and end the run.
    private var finishRequested = false
    private var memoryWarning = false
    private var memoryCritical = false
    private var backgrounded = false
    /// The app is in the background but a continued-processing task keeps training (iOS 26+).
    private var appInBackground = false
    private var capturing = false
    private var viewer: ViewerRequest?
    private var viewerDirty = false
    private var lastInteraction = Date.distantPast
    private(set) var isFinished = false

    enum SessionError: LocalizedError {
        case resumeNeedsMemory(requiredMB: Int), repeatedGPUFailure(String), enhanceNeedsMemory(requiredMB: Int)
        var errorDescription: String? {
            switch self {
            case .enhanceNeedsMemory(let mb):
                return L10n.text("可用記憶體不足以載入已保存的模型（約需 \(mb) MB）。請選較低的訓練解析度，或關閉其他 App 後再試；模型仍保留。")
            case .resumeNeedsMemory(let mb):
                return L10n.text("可用記憶體不足以載入上次的進度（約需 \(mb) MB）。請關閉其他 App 後再繼續，進度仍保留。")
            case .repeatedGPUFailure(let reason):
                return L10n.text("GPU 運算反覆失敗，已停止訓練並保留最後的進度：\(reason)")
            }
        }
    }

    init(workspace: TrainingWorkspace, configuration: GaussianTrainingConfiguration, resume: Bool, libraryURL: URL? = nil) {
        self.workspace = workspace
        self.configuration = configuration
        self.resume = resume
        self.libraryURL = libraryURL
    }

    // MARK: Controls

    func pause() { lock.lock(); pauseRequested = true; lock.broadcast(); lock.unlock() }
    func resumeTraining() { lock.lock(); pauseRequested = false; lock.broadcast(); lock.unlock() }
    func cancel(keepCheckpoint: Bool) { lock.lock(); cancelRequested = keepCheckpoint; lock.broadcast(); lock.unlock() }
    func saveCheckpoint() { lock.lock(); checkpointRequested = true; lock.broadcast(); lock.unlock() }
    /// Ends the run now and saves the current model as its result (like a completed run).
    func finishNow() { lock.lock(); finishRequested = true; lock.broadcast(); lock.unlock() }
    func memoryPressure(critical: Bool) {
        lock.lock(); if critical { memoryCritical = true } else { memoryWarning = true }; lock.broadcast(); lock.unlock()
    }
    /// GPU work is not allowed in the background: pause (with a checkpoint) until foreground.
    func setBackgrounded(_ value: Bool) { lock.lock(); backgrounded = value; lock.broadcast(); lock.unlock() }
    /// The app left the foreground while training continues (background GPU granted): skip the
    /// live preview, and treat a GPU failure as losing background access (pause, not an error).
    /// Leaving the app also saves a checkpoint, in case iOS ends the app in the background.
    func setAppInBackground(_ value: Bool) {
        lock.lock(); if value && !appInBackground { checkpointRequested = true }; appInBackground = value; lock.broadcast(); lock.unlock()
    }
    /// Pause while the user captures a new scan; continue when the capture closes.
    func setCapturing(_ value: Bool) { lock.lock(); capturing = value; lock.broadcast(); lock.unlock() }
    func updateViewer(_ request: ViewerRequest?, interactive: Bool) {
        lock.lock()
        if request != viewer { viewer = request; viewerDirty = true }
        if interactive { lastInteraction = Date() }
        lock.broadcast()
        lock.unlock()
    }

    // MARK: Loop

    private var snapshot = TrainingSnapshot()
    private var record: TrainingRecord?
    /// The scan's status before this run; restored if a new run stops before it starts.
    private var previousRecord: TrainingRecord?
    private var trainer: GaussianTrainer?
    private var lastPublished = Date.distantPast
    private var lastPreview = Date.distantPast
    private var modelChangedSincePreview = true
    private var peakFootprint = 0

    func run() {
        let started = Date()
        do {
            try execute()
        } catch {
            fail(error)
        }
        _ = started
        lock.lock(); isFinished = true; lock.unlock()
    }

    private func publish(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPublished) > 0.25 else { return }
        lastPublished = Date()
        snapshot.footprintMB = TrainingMemoryPlan.footprintBytes >> 20
        peakFootprint = max(peakFootprint, snapshot.footprintMB)
        onSnapshot(snapshot)
    }

    private func saveRecord(status: TrainingRecord.Status, reason: TrainingRecord.Reason? = nil, error: String? = nil) {
        guard var r = record else { return }
        r.status = status
        r.reason = reason
        r.iteration = snapshot.iteration
        r.gaussians = snapshot.gaussians
        r.loss = snapshot.loss
        r.psnr = snapshot.psnr
        r.elapsedSeconds = snapshot.elapsedSeconds
        r.checkpointIteration = snapshot.checkpointIteration
        r.updatedAt = Date()
        r.errorMessage = error
        r.peakFootprintMB = peakFootprint
        r.validationPSNR = snapshot.validationPSNR ?? r.validationPSNR
        record = r
        try? workspace.save(r)
    }

    /// Records a failure before announcing it (History reloads on the announcement). A failed
    /// retrain without a resumable checkpoint keeps the saved model's completed status.
    private func fail(_ error: Error) {
        snapshot.phase = .failed
        snapshot.message = error.localizedDescription
        if trainer == nil, !resume, var previous = previousRecord {
            // The new run never started: the scan keeps its previous model or checkpoint.
            previous.errorMessage = error.localizedDescription
            try? workspace.save(previous)
        } else if !workspace.hasCheckpoint, var completed = workspace.completedRecord() {
            completed.errorMessage = error.localizedDescription
            try? workspace.save(completed)
        } else if record != nil {
            saveRecord(status: .failed, reason: .error, error: error.localizedDescription)
        } else {
            let now = Date()
            try? workspace.save(TrainingRecord(status: .failed, reason: .error, configuration: configuration, iteration: 0,
                                               gaussians: 0, elapsedSeconds: 0, startedAt: now, updatedAt: now,
                                               errorMessage: error.localizedDescription))
        }
        publish(force: true)
    }

    private func execute() throws {
        snapshot.total = configuration.iterations
        snapshot.startIteration = configuration.startIteration
        if !resume { snapshot.iteration = configuration.startIteration }
        snapshot.phase = .preparing
        publish(force: true)
        let now = Date()
        let previous = workspace.record()
        previousRecord = previous
        record = TrainingRecord(status: .preparing, configuration: configuration,
                                iteration: resume ? (previous?.iteration ?? 0) : configuration.startIteration,
                                gaussians: 0, elapsedSeconds: resume ? (previous?.elapsedSeconds ?? 0) : 0,
                                checkpointIteration: resume ? previous?.checkpointIteration : nil,
                                startedAt: resume ? (previous?.startedAt ?? now) : now, updatedAt: now)
        // Keep the saved progress visible while preparing (saveRecord copies the snapshot).
        snapshot.iteration = record?.iteration ?? 0
        snapshot.elapsedSeconds = record?.elapsedSeconds ?? 0
        snapshot.checkpointIteration = record?.checkpointIteration
        saveRecord(status: .preparing)
        let dataset = try TrainingDataset.prepare(scan: workspace.scan, longEdge: configuration.longEdge,
                                                  holdOutEvery: configuration.holdOutEvery, maxPoints: 250_000,
                                                  depthSeedLimit: configuration.depthSeedLimit,
                                                  isCancelled: { [weak self] in self?.cancelRequestedNow ?? true })
        if let keep = cancelValue {
            if !resume, let previous {
                // Stopped before the new run started: nothing of the scan's state changes.
                try? workspace.save(previous)
                snapshot.phase = .cancelled
                snapshot.reason = .user
                publish(force: true)
                return
            }
            return finishCancelled(keepCheckpoint: keep)
        }
        let budget = configuration.memoryBudgetMB.map { $0 << 20 } ?? TrainingMemoryPlan.automaticBudget()
        let plan = try TrainingMemoryPlan.fit(width: dataset.width, height: dataset.height, shDegree: configuration.shDegree,
                                              requestedGaussians: configuration.maxGaussians, budgetBytes: budget)
        // A checkpoint needs as many rows as it saved; with less memory now, say so (the
        // progress stays) instead of reporting a mismatched checkpoint.
        if resume, let header = GaussianCheckpoint.header(at: workspace.checkpointURL) {
            try Self.checkResumeFits(rows: header.rows, plan: plan)
        } else if configuration.isEnhancement {
            // Enhance model: every saved Gaussian needs a row at this resolution's plan.
            let saved = try GaussianExport.modelInfo(workspace.modelURL)
            if saved.count > plan.gaussianCapacity {
                throw SessionError.enhanceNeedsMemory(requiredMB: Self.requiredMB(rows: saved.count, plan: plan))
            }
        }
        let metal = try GaussianMetal(libraryURL: libraryURL)
        let trainer = try GaussianTrainer(configuration: configuration, dataset: dataset, plan: plan, metal: metal)
        self.trainer = trainer
        snapshot.plannedMB = plan.totalBytes >> 20
        record?.plannedMB = snapshot.plannedMB
        var elapsedBase = 0.0
        if resume, workspace.hasCheckpoint {
            let header = try GaussianCheckpoint.load(workspace.checkpointURL, into: trainer)
            elapsedBase = header.elapsedSeconds
            snapshot.checkpointIteration = header.iteration
        } else {
            // A new run replaces an old checkpoint only once it is ready to start; the saved
            // model is replaced only when the new run completes.
            workspace.removeCheckpoint()
            if configuration.isEnhancement { try trainer.initializeModel(fromSaved: workspace.modelDirectory) }
            else { try trainer.initializeModel() }
        }
        let depth = Double(trainer.strategy.bounds.valid ? max(0.5, trainer.strategy.bounds.medianSize * 0.6) : 1.5)
        onPreparedViews(dataset.frames, depth)
        snapshot.iteration = trainer.iteration
        snapshot.gaussians = trainer.model.activeCount
        snapshot.elapsedSeconds = elapsedBase
        snapshot.phase = .running
        saveRecord(status: .running)
        publish(force: true)
        try loop(trainer, elapsedBase: elapsedBase)
    }

    /// Throws `resumeNeedsMemory` (with an estimate) when a checkpoint of `rows` Gaussians does
    /// not fit the plan that fits the memory available now.
    static func checkResumeFits(rows: Int, plan: TrainingMemoryPlan) throws {
        guard rows > plan.gaussianCapacity else { return }
        throw SessionError.resumeNeedsMemory(requiredMB: requiredMB(rows: rows, plan: plan))
    }

    /// Estimated plan size (MB) with room for `rows` Gaussians.
    static func requiredMB(rows: Int, plan: TrainingMemoryPlan) -> Int {
        let perGaussian = Double(plan.totalBytes) / Double(max(1, plan.gaussianCapacity))
        return Int(Double(plan.totalBytes) + perGaussian * Double(max(0, rows - plan.gaussianCapacity))) >> 20
    }

    private var cancelRequestedNow: Bool { cancelValue != nil }
    /// The requested stop, if any: true keeps the checkpoint.
    private var cancelValue: Bool? { lock.lock(); defer { lock.unlock() }; return cancelRequested }

    private func checkpoint(_ trainer: GaussianTrainer) throws {
        if trainer.iteration > (snapshot.checkpointIteration ?? -1) { foregroundGPUFailures = 0 }
        try GaussianCheckpoint.save(trainer, elapsedSeconds: snapshot.elapsedSeconds, to: workspace.root)
        snapshot.checkpointIteration = trainer.iteration
        writeSnapshotImage(trainer)
        saveRecord(status: snapshot.phase == .paused ? .paused : .running, reason: snapshot.reason)
        publish(force: true)
    }

    /// Foreground GPU failures since the last checkpoint that followed new progress.
    private var foregroundGPUFailures = 0

    private func loop(_ trainer: GaussianTrainer, elapsedBase: Double) throws {
        var runStart = Date()
        var elapsedAtRunStart = elapsedBase
        var lossEMA: Double?, psnrEMA: Double?, spiEMA: Double?
        while trainer.iteration < configuration.iterations {
            // Controls.
            lock.lock()
            let cancel = cancelRequested
            // Finishing renders and exports, so it waits while the app has no GPU access.
            let finishing = finishRequested && !backgrounded
            var pauseReason: TrainingRecord.Reason? = pauseRequested ? .user : nil
            if capturing { pauseReason = .capture }
            if backgrounded { pauseReason = .background }
            let wantsCheckpoint = checkpointRequested
            checkpointRequested = false
            let warn = memoryWarning, critical = memoryCritical
            memoryWarning = false
            lock.unlock()
            if let keep = cancel {
                if keep && trainer.iteration > (snapshot.checkpointIteration ?? 0) { try? checkpoint(trainer) }
                return finishCancelled(keepCheckpoint: keep)
            }
            if finishing { break }
            if critical || TrainingMemoryPlan.availableBytesIfKnown.map({ $0 < 150 << 20 }) == true {
                // Not safe to continue: keep a valid checkpoint and stop with a clear message.
                trainer.reduceMemory()
                try? checkpoint(trainer)
                snapshot.phase = .paused
                snapshot.reason = .memory
                snapshot.message = L10n.text("可用記憶體不足，已儲存進度並暫停訓練。關閉其他 App 後可繼續。")
                saveRecord(status: .paused, reason: .memory)
                publish(force: true)
                lock.lock(); memoryCritical = false; pauseRequested = true; lock.unlock()
                continue
            }
            if warn {
                trainer.reduceMemory()
                snapshot.growthFrozen = true
            }
            let thermal = thermalLevel()
            if pauseReason == nil && thermal >= 3 { pauseReason = .thermal }
            if pauseReason == nil && batteryLow() { pauseReason = .battery }
            if let reason = pauseReason {
                elapsedAtRunStart += Date().timeIntervalSince(runStart)
                snapshot.elapsedSeconds = elapsedAtRunStart
                if trainer.iteration > (snapshot.checkpointIteration ?? -1) { try? checkpoint(trainer) }
                snapshot.phase = .paused
                snapshot.reason = reason
                saveRecord(status: .paused, reason: reason)
                publish(force: true)
                waitWhilePaused(trainer, reason: reason)
                runStart = Date()
                snapshot.phase = .running
                snapshot.reason = nil
                snapshot.message = nil
                saveRecord(status: .running)
                publish(force: true)
                continue
            }
            if wantsCheckpoint && trainer.iteration > (snapshot.checkpointIteration ?? -1) { try checkpoint(trainer) }

            // One iteration.
            let report: TrainingStepReport
            do { report = try trainer.step() } catch GaussianTrainer.TrainingError.repeatedOverflow {
                try? checkpoint(trainer)
                snapshot.reason = .overflow
                throw GaussianTrainer.TrainingError.repeatedOverflow
            } catch GaussianTrainer.TrainingError.gpuFailure(let reason) {
                // A GPU command failed (typically: the app lost the foreground mid-iteration). The
                // model may be partly updated, so continue from the last checkpoint, or from
                // memory when there is none: the trainer skips failed views before touching the
                // parameters, and only a failure in the Adam step leaves a partial update. Replays
                // are deterministic, so a failure that repeats in the foreground stops the run.
                lock.lock()
                // In the background the system can withdraw GPU access: wait for the foreground.
                if appInBackground { backgrounded = true }
                let wasBackgrounded = backgrounded
                lock.unlock()
                if !wasBackgrounded {
                    foregroundGPUFailures += 1
                    if foregroundGPUFailures > 2 { throw SessionError.repeatedGPUFailure(reason) }
                }
                elapsedAtRunStart += Date().timeIntervalSince(runStart)
                snapshot.phase = .paused
                snapshot.reason = .background
                saveRecord(status: .paused, reason: .background)
                publish(force: true)
                lock.lock(); let inBackground = backgrounded; lock.unlock()
                if inBackground { waitWhilePaused(trainer, reason: .background) }
                if workspace.hasCheckpoint {
                    let header = try GaussianCheckpoint.load(workspace.checkpointURL, into: trainer)
                    elapsedAtRunStart = header.elapsedSeconds
                    snapshot.iteration = header.iteration
                }
                runStart = Date()
                snapshot.phase = .running
                snapshot.reason = nil
                saveRecord(status: .running)
                publish(force: true)
                continue
            }
            modelChangedSincePreview = true
            if !report.skipped {
                lossEMA = lossEMA.map { 0.95 * $0 + 0.05 * report.loss } ?? report.loss
                psnrEMA = psnrEMA.map { 0.95 * $0 + 0.05 * report.psnr } ?? report.psnr
            }
            spiEMA = spiEMA.map { 0.97 * $0 + 0.03 * report.seconds } ?? report.seconds
            snapshot.iteration = trainer.iteration
            snapshot.loss = lossEMA
            snapshot.psnr = psnrEMA
            snapshot.gaussians = report.gaussians
            snapshot.secondsPerIteration = spiEMA
            snapshot.growthFrozen = trainer.growthFrozen
            snapshot.elapsedSeconds = elapsedAtRunStart + Date().timeIntervalSince(runStart)

            // Thermal / energy throttling: idle for a share of each iteration.
            snapshot.throttled = thermal >= 2 || lowPowerMode()
            if snapshot.throttled { Thread.sleep(forTimeInterval: min(0.5, report.seconds * (thermal >= 2 ? 1.0 : 0.4))) }

            renderIfNeeded(trainer, paused: false)
            publish()
        }
        snapshot.elapsedSeconds = elapsedAtRunStart + Date().timeIntervalSince(runStart)
        try finish(trainer)
    }

    /// Waits for resume/cancel; renders viewer requests meanwhile so the live view stays
    /// interactive. A thermal pause lasts until the device cools to "fair" (hysteresis).
    private func waitWhilePaused(_ trainer: GaussianTrainer, reason: TrainingRecord.Reason) {
        while true {
            lock.lock()
            let userPaused = pauseRequested || capturing, inBackground = backgrounded
            let leave = cancelRequested != nil || (finishRequested && !inBackground)
            let wantsCheckpoint = checkpointRequested
            checkpointRequested = false
            lock.unlock()
            if leave { return }
            if wantsCheckpoint && trainer.iteration > (snapshot.checkpointIteration ?? -1) { try? checkpoint(trainer) }
            let hot = thermalLevel() >= (reason == .thermal ? 2 : 3)
            let blocked = userPaused || inBackground || hot || batteryLow()
            if !blocked { return }
            if !inBackground { renderIfNeeded(trainer, paused: true) }
            publish()
            lock.lock()
            if cancelRequested == nil && !finishRequested && !checkpointRequested && !viewerDirty && (pauseRequested || capturing) == userPaused
                && backgrounded == inBackground {
                _ = lock.wait(until: Date().addingTimeInterval(userPaused || inBackground ? 1 : 5))
            }
            lock.unlock()
        }
    }

    private func renderIfNeeded(_ trainer: GaussianTrainer, paused: Bool) {
        lock.lock()
        guard let request = viewer, !backgrounded, !appInBackground else { lock.unlock(); return }
        let dirty = viewerDirty
        let interactive = Date().timeIntervalSince(lastInteraction) < 0.5
        lock.unlock()
        let now = Date()
        let interval = interactive ? Self.interactiveInterval : Self.previewInterval
        let due = dirty ? now.timeIntervalSince(lastPreview) >= (interactive || paused ? Self.interactiveInterval : 0.3)
                        : (modelChangedSincePreview && now.timeIntervalSince(lastPreview) >= interval)
        guard due else { return }
        lock.lock(); viewerDirty = false; lock.unlock()
        lastPreview = now
        modelChangedSincePreview = false
        guard let camera = Self.camera(for: request, dataset: trainer.dataset, mipFilter: configuration.mipFilter, poses: trainer.poses,
                                       poseOptimization: configuration.poseOptimization) else { return }
        if let frame = try? trainer.renderPreview(camera: camera, frame: request.captureFrame, mode: request.mode) {
            onFrame(frame, request)
        }
    }

    /// Camera for a viewer request: the orbit view, or a capture camera at the preview size.
    static func camera(for request: ViewerRequest, dataset: TrainingDataset, mipFilter: Bool, poses: [PoseCorrection],
                       poseOptimization: Bool) -> GaussianCamera? {
        if let index = request.captureFrame, dataset.frames.indices.contains(index) {
            let f = dataset.frames[index]
            let scale = min(Double(request.width * request.height) / Double(f.intrinsics.width * f.intrinsics.height), 1).squareRoot()
            let w = max(16, Int(Double(f.intrinsics.width) * scale)), h = max(16, Int(Double(f.intrinsics.height) * scale))
            var w2c = GaussianCamera.worldToCamera(arkitRowMajorC2W: f.transform)
            if poseOptimization { w2c = poses[index].matrix * w2c }
            let sx = Double(w) / Double(f.intrinsics.width), sy = Double(h) / Double(f.intrinsics.height)
            return GaussianCamera(worldToCamera: w2c, fx: f.intrinsics.fx * sx, fy: f.intrinsics.fy * sy,
                                  cx: f.intrinsics.cx * sx, cy: f.intrinsics.cy * sy, width: w, height: h, mipFilter: mipFilter)
        }
        return request.orbit?.camera(width: request.width, height: request.height, mipFilter: mipFilter)
    }

    /// Small render of the current model for the resume screen and History (best effort).
    private func writeSnapshotImage(_ trainer: GaussianTrainer) {
        guard let first = trainer.dataset.trainFrames.first.map({ trainer.dataset.frames[$0] }) else { return }
        let orbit = OrbitCamera(arkitTransform: first.transform, intrinsics: first.intrinsics,
                                depth: Double(max(0.5, trainer.strategy.bounds.medianSize * 0.6)))
        let (w, h) = trainer.renderer.fitted(width: 360, height: 480)
        guard let frame = try? trainer.renderPreview(camera: orbit.camera(width: w, height: h, mipFilter: configuration.mipFilter),
                                                     frame: nil, mode: .camera) else { return }
        let temporary = workspace.root.appendingPathComponent(".snapshot-\(UUID().uuidString).jpg")
        if (try? Self.writeJPEG(frame, to: temporary)) != nil {
            _ = rename(temporary.path, workspace.snapshotURL.path)
        } else { try? FileManager.default.removeItem(at: temporary) }
    }

    /// "Stop and delete" drops this run's progress but never a saved model (a retrain only
    /// replaces it on completion). The status is written before it is announced.
    private func finishCancelled(keepCheckpoint: Bool) {
        snapshot.phase = .cancelled
        snapshot.reason = .user
        if keepCheckpoint && workspace.hasCheckpoint { saveRecord(status: .cancelled, reason: .user) }
        else { try? workspace.discardProgress(); snapshot.checkpointIteration = nil }
        publish(force: true)
    }

    // MARK: Finish and export

    private func finish(_ trainer: GaussianTrainer) throws {
        snapshot.phase = .finishing
        publish(force: true)
        let validation = try trainer.evaluate()
        if validation.count > 0 { snapshot.validationPSNR = validation.psnr }
        try GaussianTrainingSession.exportModel(trainer, to: workspace, validation: validation.count > 0 ? validation.psnr : nil,
                                                elapsedSeconds: snapshot.elapsedSeconds, peakFootprintMB: peakFootprint)
        workspace.removeCheckpoint()
        snapshot.checkpointIteration = nil
        snapshot.phase = .completed
        snapshot.reason = .completed
        saveRecord(status: .completed, reason: .completed)
        publish(force: true)
    }

    struct Report: Codable {
        var configuration: GaussianTrainingConfiguration
        var plan: TrainingMemoryPlan
        var iterations: Int
        var gaussians: Int
        var elapsedSeconds: Double
        var peakFootprintMB: Int
        var validationPSNR: Double?
        var trainingViews: Int
        var validationViews: Int
        var poseCorrectionMedianDegrees: Double?
        var poseCorrectionMedianMillimetres: Double?
        var poseCorrectionMaxDegrees: Double?
        var poseCorrectionMaxMillimetres: Double?
        var exposureRangeEV: [Double]?
        var growthFrozen: Bool
        var createdAt: Date
    }

    /// Writes the model folder atomically (staged next to it, then swapped in).
    static func exportModel(_ trainer: GaussianTrainer, to workspace: TrainingWorkspace, validation: Double?,
                            elapsedSeconds: Double, peakFootprintMB: Int) throws {
        let fm = FileManager.default
        let staging = workspace.root.appendingPathComponent(".model-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var published = false
        defer { if !published { try? fm.removeItem(at: staging) } }
        try writeModelFiles(trainer, into: staging, validation: validation, elapsedSeconds: elapsedSeconds, peakFootprintMB: peakFootprintMB)
        let destination = workspace.modelDirectory
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        published = true
    }

    /// Writes the model files (SOG, metadata, PPISP, refined poses, report, cover) into `staging`.
    /// Training is over, so the SOG writer reuses the gradient and intersection buffers for its
    /// k-means instead of allocating beyond the memory plan.
    static func writeModelFiles(_ trainer: GaussianTrainer, into staging: URL, validation: Double?,
                                elapsedSeconds: Double, peakFootprintMB: Int) throws {
        let config = trainer.configuration
        try GaussianSOG.write(trainer.model, to: staging.appendingPathComponent(GaussianSOG.fileName), metal: trainer.metal,
                              scratch: .init(points: trainer.model.grads, palette: trainer.raster.keys, labels: trainer.raster.values),
                              iterations: GaussianSOG.kMeansIterations)
        let metadata = GaussianExport.Metadata(gaussians: trainer.model.activeCount, shDegree: config.shDegree,
                                               mipFilter2D: config.mipFilter,
                                               filterVariancePx2: config.mipFilter ? GaussianCamera.mipFilterVariance : GaussianCamera.plainDilation,
                                               opacityCompensation: config.mipFilter,
                                               ppisp: config.ppisp ? GaussianExport.ppispName : nil,
                                               iterations: trainer.iteration, configuration: config, createdAt: Date(),
                                               validationPSNR: validation,
                                               viewerNotes: GaussianExport.viewerNotes(mipFilter: config.mipFilter, ppisp: config.ppisp))
        try JSONEncoder.training.encode(metadata).write(to: staging.appendingPathComponent(GaussianExport.metadataName))
        if config.ppisp {
            try JSONEncoder.training.encode(GaussianExport.ppispFile(trainer.ppisp, frames: trainer.dataset.frames))
                .write(to: staging.appendingPathComponent(GaussianExport.ppispName))
        }
        // Refined poses of the training views (ARKit convention); the scan's pose files are unchanged.
        let (records, _) = ScanLibrary.savedRecords(in: trainer.dataset.directory)
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var refined: [FrameRecord] = []
        for (index, frame) in trainer.dataset.frames.enumerated() {
            guard var record = byID[frame.id] else { continue }
            if config.poseOptimization && !frame.isValidation {
                record.transform = GaussianExport.correctedTransform(frame.transform, correction: trainer.poses[index])
            }
            refined.append(record)
        }
        try ExportManager.writeRefinedPoses(refined, to: staging.appendingPathComponent(GaussianExport.posesName))
        let trained = trainer.dataset.trainFrames
        let rotations = trained.map { trainer.poses[$0].rotationDegrees }.sorted()
        let translations = trained.map { trainer.poses[$0].translationMeters * 1000 }.sorted()
        let evs = trainer.dataset.frames.indices.map { trainer.ppisp.exposure(frame: $0) }
        let report = Report(configuration: config, plan: trainer.plan, iterations: trainer.iteration,
                            gaussians: trainer.model.activeCount, elapsedSeconds: elapsedSeconds, peakFootprintMB: peakFootprintMB,
                            validationPSNR: validation, trainingViews: trained.count,
                            validationViews: trainer.dataset.validationFrames.count,
                            poseCorrectionMedianDegrees: config.poseOptimization ? rotations[rotations.count / 2] : nil,
                            poseCorrectionMedianMillimetres: config.poseOptimization ? translations[translations.count / 2] : nil,
                            poseCorrectionMaxDegrees: config.poseOptimization ? rotations.last : nil,
                            poseCorrectionMaxMillimetres: config.poseOptimization ? translations.last : nil,
                            exposureRangeEV: config.ppisp ? [evs.min() ?? 0, evs.max() ?? 0] : nil,
                            growthFrozen: trainer.growthFrozen, createdAt: Date())
        try JSONEncoder.training.encode(report).write(to: staging.appendingPathComponent(GaussianExport.reportName))
        // Cover image: the orbit start view with the camera ISP.
        if let first = trainer.dataset.trainFrames.first.map({ trainer.dataset.frames[$0] }) {
            let orbit = OrbitCamera(arkitTransform: first.transform, intrinsics: first.intrinsics,
                                    depth: Double(max(0.5, trainer.strategy.bounds.medianSize * 0.6)))
            let (w, h) = trainer.renderer.fitted(width: 540, height: 720)
            if let frame = try? trainer.renderPreview(camera: orbit.camera(width: w, height: h, mipFilter: config.mipFilter),
                                                      frame: nil, mode: .camera) {
                try? writeJPEG(frame, to: staging.appendingPathComponent("preview.jpg"))
            }
        }
    }

    static func writeJPEG(_ frame: RenderedFrame, to url: URL) throws {
        guard let image = frame.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw GaussianExport.ExportError.damaged
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw GaussianExport.ExportError.damaged }
    }
}

nonisolated extension TrainingMemoryPlan {
    /// Remaining allocatable memory where the platform reports it (iOS); nil elsewhere.
    static var availableBytesIfKnown: Int? {
        #if os(iOS)
        let value = Int(os_proc_available_memory())
        return value > 0 ? value : nil
        #else
        return nil
        #endif
    }
}
