import Foundation
import simd

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
    var version = 2
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
    /// v2: live-view pacing while scanning. `renderPacing` counts SceneKit frames (the camera
    /// view and overlays), `arFramePacing` ARKit frames reaching the app on the main thread.
    var renderPacing = FramePacing.Report()
    var arFramePacing = FramePacing.Report()
    /// Main-thread time spent handling each ARKit frame while scanning.
    var frameHandlingTotalMS = 0.0
    var frameHandlingMaxMS = 0.0
    /// Scanning time with the thermal state serious or critical (iOS throttles the device).
    var seriousThermalS = 0.0
    /// ARKit anchors in the session when scanning stopped (one per photo plus preview tiles).
    var anchorsAtStop = 0
}

/// Frame pacing grouped by how many photos the scan had saved: an interval above 50 ms (under
/// 20 fps) is a stall. Shows whether a long scan slows down as photos accumulate, as opposed
/// to heat or a single heavy moment. Thread-safe; the render thread and main thread feed it.
nonisolated final class FramePacing: @unchecked Sendable {
    struct Report: Codable, Sendable, Equatable {
        var frames = 0
        var stalls = 0
        var maximumIntervalMS = 0.0
        /// [0] covers photos 0–99, [1] photos 100–199, …
        var framesByHundredPhotos: [Int] = []
        var stallsByHundredPhotos: [Int] = []
    }

    static let stallMS = 50.0
    private let lock = NSLock()
    private var report = Report()
    private var last: TimeInterval?
    private var photos = 0
    private var active = false

    /// Starts (or continues after a pause) counting; the first frame only sets the clock.
    func start(photos: Int) {
        lock.lock(); active = true; last = nil; self.photos = photos; lock.unlock()
    }
    /// Pauses counting so a pause or background period is not a stall.
    func pause() { lock.lock(); active = false; last = nil; lock.unlock() }
    func reset() { lock.lock(); report = Report(); active = false; last = nil; photos = 0; lock.unlock() }
    func setPhotos(_ count: Int) { lock.lock(); photos = count; lock.unlock() }

    func frame(at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        defer { last = time }
        guard let last, time > last else { return }
        let ms = (time - last) * 1000
        let bucket = max(0, photos) / 100
        while report.framesByHundredPhotos.count <= bucket {
            report.framesByHundredPhotos.append(0)
            report.stallsByHundredPhotos.append(0)
        }
        report.frames += 1
        report.framesByHundredPhotos[bucket] += 1
        report.maximumIntervalMS = max(report.maximumIntervalMS, ms)
        if ms > Self.stallMS {
            report.stalls += 1
            report.stallsByHundredPhotos[bucket] += 1
        }
    }

    var snapshot: Report { lock.lock(); defer { lock.unlock() }; return report }
}

/// Wireframe markers of every captured view as one line list, so SceneKit draws all of them
/// in one call. One node, geometry and material per photo cost a draw call per photo on every
/// frame, which kept growing through long scans.
nonisolated enum CameraMarkerLines {
    /// Camera-frame corners: a 4.5 × 3.6 cm base on the camera and the apex 5 cm along the
    /// view direction (−Z), the same pyramid as the per-photo markers it replaces.
    static let corners: [SIMD3<Float>] = [SIMD3(-0.0225, -0.018, 0), SIMD3(0.0225, -0.018, 0),
                                          SIMD3(0.0225, 0.018, 0), SIMD3(-0.0225, 0.018, 0),
                                          SIMD3(0, 0, -0.05)]
    /// The base rectangle, then the four edges to the apex.
    static let edges: [Int32] = [0, 1, 1, 2, 2, 3, 3, 0, 0, 4, 1, 4, 2, 4, 3, 4]

    /// Appends one marker (5 world-space vertices) for a camera-to-world pose.
    static func append(pose: simd_float4x4, to vertices: inout [SIMD3<Float>]) {
        for corner in corners {
            let p = pose * SIMD4<Float>(corner, 1)
            vertices.append(SIMD3(p.x, p.y, p.z))
        }
    }

    /// Line-list indices for `count` markers.
    static func indices(markers count: Int) -> [Int32] {
        var indices: [Int32] = []
        indices.reserveCapacity(max(0, count) * edges.count)
        for marker in 0..<max(0, count) {
            let base = Int32(marker * corners.count)
            for e in edges { indices.append(base + e) }
        }
        return indices
    }
}
