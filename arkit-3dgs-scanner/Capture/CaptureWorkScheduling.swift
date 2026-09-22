import Foundation

nonisolated struct WorkQueueMetrics: Codable, Sendable {
    var submitted = 0
    var processed = 0
    var replaced = 0
    var maximumRetainedJobs = 0
    var totalMS = 0.0
    var maximumMS = 0.0
}

/// One active job + one replaceable latest job. Slow optional processing never builds a FIFO
/// of full-size image buffers or holds a photo writer slot until analysis finishes.
actor LatestFrameProcessor<Job: Sendable> {
    private let process: @Sendable (Job) async -> Void
    private var pending: Job?
    private var worker: Task<Void, Never>?
    private var active = false
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var metrics = WorkQueueMetrics()

    init(process: @escaping @Sendable (Job) async -> Void) { self.process = process }

    func submit(_ job: Job) {
        guard !closed else { return }
        metrics.submitted += 1
        if pending != nil { metrics.replaced += 1 }
        pending = job
        metrics.maximumRetainedJobs = max(metrics.maximumRetainedJobs, active ? 2 : 1)
        if worker == nil { worker = Task(priority: .utility) { await self.run() } }
    }

    private func run() async {
        while let job = pending {
            pending = nil
            active = true
            let start = ProcessInfo.processInfo.systemUptime
            await process(job)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            metrics.processed += 1
            metrics.totalMS += ms
            metrics.maximumMS = max(metrics.maximumMS, ms)
            active = false
        }
        worker = nil
        let completed = waiters
        waiters.removeAll()
        for continuation in completed { continuation.resume() }
    }

    /// Call after all producers have finished; also processes the final pending frame.
    func drain() async {
        guard worker != nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Abandon pending work when leaving a scan. In-flight owned work may finish independently.
    func close() { closed = true; pending = nil }
    func report() -> WorkQueueMetrics { metrics }
}

/// Sampling changes workload, not voxel size or the stored depth resolution. Cycling both
/// offsets covers the full depth grid over time instead of permanently missing thin features.
nonisolated struct PreviewSamplingBudget {
    private(set) var adaptiveStride: Int
    private var quickFrames = 0
    private var phase = 0
    let minimumStride: Int
    let maximumStride: Int
    let targetMS: Double
    let maximumSamples: Int

    init(minimumStride: Int = 2, maximumStride: Int = 6, targetMS: Double = 35, maximumSamples: Int = 6000) {
        self.minimumStride = max(1, minimumStride)
        self.maximumStride = max(max(1, minimumStride), maximumStride)
        self.adaptiveStride = max(1, minimumStride)
        self.targetMS = max(1, targetMS)
        self.maximumSamples = max(1, maximumSamples)
    }

    mutating func next(width: Int, height: Int) -> (stride: Int, x: Int, y: Int) {
        var step = adaptiveStride
        // A hard candidate-count bound also applies to unusually large depth maps.
        while ((max(0, width) + step - 1) / step) * ((max(0, height) + step - 1) / step) > maximumSamples { step += 1 }
        let offset = phase % (step * step)
        phase = (offset + 1) % (step * step)
        return (step, offset % step, offset / step)
    }

    mutating func record(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        if milliseconds > targetMS {
            adaptiveStride = min(maximumStride, adaptiveStride + 1)
            quickFrames = 0
        } else if milliseconds < targetMS * 0.5 {
            quickFrames += 1
            if quickFrames >= 12 {
                adaptiveStride = max(minimumStride, adaptiveStride - 1)
                quickFrames = 0
            }
        } else { quickFrames = 0 }
    }
}

nonisolated struct CapturePipelineReport: Codable, Sendable {
    var version = 1
    var photoCandidates = 0
    var writerBackpressureFrames = 0
    var imageCopyFailures = 0
    var savedPhotos = 0
    var maximumPendingWrites = 0
    var writeQueueTotalMS = 0.0
    var writeQueueMaxMS = 0.0
    var jpegTotalMS = 0.0
    var jpegMaxMS = 0.0
    var fileWriteTotalMS = 0.0
    var fileWriteMaxMS = 0.0
    var savedIntervalTotalS = 0.0
    var savedIntervalMaxS = 0.0
    var configuredMinimumIntervalS = 0.0
    var poseRefinementEnabled = false
    var featureWork = WorkQueueMetrics()
    var retainedFeatureFrames = 0
    var archivedFeatureObservations = 0
    var discardedFeatureObservations = 0
}
