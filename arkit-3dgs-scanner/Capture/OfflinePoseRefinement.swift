import Foundation
import simd

/// On-device, disk-backed second pass. Rebuilds tracks from saved images instead of relying
/// on the best-effort live worker. LiDAR supplies metric landmarks; no desktop SfM is required.
nonisolated enum OfflinePoseRefinement {
    struct Report: Codable, Sendable {
        var version = 5
        var status = "pending"
        var inputFrames = 0
        var processedFrames = 0
        var failedFrames: [Int] = []
        var observationCount = 0
        var supportedFrames = 0
        var changedFrames = 0
        var peakDescriptorFrames = 0
        var observationBudget = 180_000
        var observationsPerFrame = 0
        var holdoutBefore: Float?
        var holdoutAfter: Float?
        var decodeSeconds: Double? = nil
        var featureExtractionSeconds: Double? = nil
        var matchingSeconds: Double? = nil
        var bundleAdjustmentSeconds: Double? = nil
        var localSurface: LocalSurfaceRefiner.Report?
        var loopClosure: LoopClosureRefiner.Report?
        /// v5: independent photo-alignment check per candidate stage ("features", "localSurface").
        var photometric: [String: PhotometricPoseValidator.Report]?
        /// v5: stage whose poses were applied after the photo-alignment check; nil keeps input poses.
        var appliedStage: String?
        var seconds = 0.0
        var notice: String {
            let extra = localSurface.map { $0.accepted > 0 && appliedStage == "localSurface"
                ? L10n.text("局部表面對齊已通過深度與影像驗證。")
                : L10n.text("局部表面對齊未取得可靠改善，保留原姿態。") } ?? ""
            let photo = appliedStage != nil ? L10n.text("照片對齊檢查已通過。") : ""
            return [featureNotice, extra, photo].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        private var featureNotice: String {
            guard let loopClosure, loopClosure.candidatePairs > 0 else { return localNotice }
            let counts = L10n.text("閉環：\(loopClosure.candidatePairs) 組候選，\(loopClosure.verifiedPairs) 組通過幾何驗證。")
            let outcome = loopClosure.status == "validated"
                ? L10n.text("閉環修正已套用；參考距離仍需獨立驗證。")
                : L10n.text("未套用閉環修正，保留原本的姿態精修結果。")
            return localNotice + "\n" + counts + " " + outcome
        }
        private var localNotice: String {
            switch status {
            case "validated": return L10n.text("已匹配 \(processedFrames) 張影像，\(changedFrames) 張位置通過驗證並修正。")
            case "insufficientDepthFrames": return L10n.text("深度影格不足，保留原本相機位置。")
            case "noObservations", "insufficientTrackSupport":
                return L10n.text("跨影格匹配不足（\(supportedFrames) 張達到求解需求），保留原本位置。")
            case "insufficientHoldoutTracks": return L10n.text("驗證用匹配不足，保留原本位置。")
            case "noImprovement": return L10n.text("精修未降低殘差，保留原本位置。")
            case "holdoutDidNotImprove": return L10n.text("驗證殘差未改善至少 3%，保留原本位置。")
            case "excessiveCorrection": return L10n.text("修正幅度超出安全範圍，保留原本位置。")
            case "memoryPressure", "observationBudgetExceeded": return L10n.text("精修資源不足，保留原本位置。")
            case "photometricValidationRejected": return L10n.text("照片對齊檢查未確認改善，保留原本相機位置。")
            case "photometricValidationInsufficient": return L10n.text("重疊照片不足以確認修正，保留原本相機位置。")
            default: return L10n.text("精修未通過或資料不足，保留原本位置。")
            }
        }
    }
    struct Result: Sendable {
        var records: [FrameRecord]
        var ba: PoseRefineResult
        var report: Report
    }

    /// Feature BA with verified loops, then optional local surface alignment. Each stage that
    /// changed poses is checked with the independent photo-alignment test in pipeline order: the
    /// first must improve on the input, a later one must not harm the accepted stage. Nothing
    /// passing keeps the input poses.
    static func run(records: [FrameRecord], directory: URL, rounds: Int,
                    surfaceRefinement: Bool = false, options: BundleAdjuster.Options = BundleAdjuster.Options(),
                    isCancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Result {
        let started = Date()
        let featureShare = surfaceRefinement ? 0.78 : 0.92
        let features = await runFeatures(records:records,directory:directory,rounds:rounds,options:options,
            isCancelled:isCancelled,progress:{progress($0 * featureShare)})
        var report = features.report
        func finish(_ result: Result) -> Result {
            var result = result
            result.report.seconds = Date().timeIntervalSince(started)
            return result
        }
        func keepInput(_ status: String) -> Result {
            var ba = features.ba
            ba.poses = [:]; ba.rejectionReason = status
            report.status = status; report.changedFrames = 0; report.appliedStage = nil
            return finish(Result(records: records, ba: ba, report: report))
        }
        let terminal = ["cancelled","memoryPressure","observationBudgetExceeded","insufficientDepthFrames"]
        if features.report.status == "cancelled" || isCancelled() { return keepInput("cancelled") }
        var candidates: [(stage: String, result: Result)] = []
        if features.report.status == "validated", features.report.changedFrames > 0 {
            candidates.append(("features", features))
        }
        if surfaceRefinement, rounds > 0, !terminal.contains(features.report.status) {
            let local = LocalSurfaceRefiner.run(records:features.records,directory:directory,
                shouldContinue:{ !isCancelled() && RefusionEngine.hasOptionalProcessingHeadroom },
                progress:{progress(0.78+$0*0.14)})
            report.localSurface = local.report
            if local.report.status == "interrupted" {
                report.localSurface?.accepted = 0
                if isCancelled() { return keepInput("cancelled") }
            } else if local.report.accepted > 0 {
                var ba = features.ba, localReport = report
                for r in local.records where r.transform.count == 16 { ba.poses[r.id] = RefusionEngine.float4x4(rowMajor:r.transform) }
                let original = Dictionary(records.map { ($0.id,$0.transform) },uniquingKeysWith:{$1})
                localReport.status = "validated"
                localReport.changedFrames = local.records.filter { original[$0.id] != $0.transform }.count
                candidates.append(("localSurface", Result(records: local.records, ba: ba, report: localReport)))
            }
        }
        guard !candidates.isEmpty else {
            var ba = features.ba
            if report.changedFrames == 0 { ba.poses = [:] }   // nothing moved: keep ARKit mesh support
            progress(1)
            return finish(Result(records: features.records, ba: ba, report: report))
        }
        guard RefusionEngine.hasOptionalProcessingHeadroom else { return keepInput("memoryPressure") }
        // Stages are checked in pipeline order, each against the poses it would replace: the first
        // must improve on the input; a later stage must not harm the accepted one.
        var applied: Result?
        var photometric: [String: PhotometricPoseValidator.Report] = [:]
        for (index, candidate) in candidates.enumerated() {
            let reference = applied?.records ?? records
            let check = PhotometricPoseValidator.evaluate(input: reference, candidate: candidate.result.records,
                directory: directory,
                requiredGain: applied == nil ? PhotometricPoseValidator.requiredWideGain : -PhotometricPoseValidator.adjacentTolerance,
                isCancelled: isCancelled)
            photometric[candidate.stage] = check
            report.photometric = photometric
            progress(0.92 + 0.08 * Double(index + 1) / Double(candidates.count))
            if check.status == "cancelled" || isCancelled() { return keepInput("cancelled") }
            if check.accepted {
                var result = candidate.result
                result.report.appliedStage = candidate.stage
                applied = result
            } else if applied == nil {
                break   // later stages were computed from these rejected poses
            }
        }
        if var applied {
            applied.report.localSurface = report.localSurface
            applied.report.photometric = photometric
            progress(1)
            return finish(applied)
        }
        progress(1)
        return keepInput(photometric.values.contains { $0.status == "rejected" }
                         ? "photometricValidationRejected" : "photometricValidationInsufficient")
    }

    private static func runFeatures(records: [FrameRecord], directory: URL, rounds: Int,
                    options: BundleAdjuster.Options,
                    isCancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Result {
        let started = Date()
        let local = await runLocal(records: records, directory: directory, rounds: rounds, options: options,
                                   isCancelled: isCancelled, progress: { progress($0 * 0.7) })
        guard rounds > 0, !["cancelled", "memoryPressure", "observationBudgetExceeded", "insufficientDepthFrames"].contains(local.report.status) else { return local }
        let loop = LoopClosureRefiner.run(records: local.records, directory: directory,
                                         isCancelled: isCancelled, progress: { progress(0.7 + $0 * 0.3) })
        var report = local.report
        report.loopClosure = loop.report
        report.seconds = Date().timeIntervalSince(started)
        if loop.report.status == "cancelled" {
            report.status = "cancelled"
            return Result(records: records, ba: PoseRefineResult(), report: report)
        }
        guard loop.report.status == "validated" else {
            progress(1)
            return Result(records: local.records, ba: local.ba, report: report)
        }
        var ba = local.ba
        for r in loop.records where r.transform.count == 16 {
            ba.poses[r.id] = RefusionEngine.float4x4(rowMajor: r.transform)
        }
        report.status = "validated"
        let original = Dictionary(records.map { ($0.id, $0.transform) }, uniquingKeysWith: { _, latest in latest })
        report.changedFrames = loop.records.filter { original[$0.id] != $0.transform }.count
        progress(1)
        return Result(records: loop.records, ba: ba, report: report)
    }

    private static func runLocal(records: [FrameRecord], directory: URL, rounds: Int,
                                 options: BundleAdjuster.Options,
                                 isCancelled: @escaping @Sendable () -> Bool,
                                 progress: @escaping @Sendable (Double) -> Void) async -> Result {
        let start = Date()
        var report = Report()
        report.inputFrames = records.count
        var ba = PoseRefineResult()
        func finish(_ status: String, _ output: [FrameRecord]) -> Result {
            report.status = status; report.seconds = Date().timeIntervalSince(start)
            return Result(records: output, ba: ba, report: report)
        }
        let usable = records.filter { r in
            r.blurVerdict != .drop && r.depthFile != nil && r.transform.count == 16
                && r.transform.allSatisfy(\.isFinite)
        }.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        guard rounds > 0, usable.count >= 3 else { return finish("insufficientDepthFrames", records) }
        // Cap compact observations over the ENTIRE scan, not just its most recent portion.
        report.observationsPerFrame = min(128, report.observationBudget / usable.count)
        guard report.observationsPerFrame >= 40 else { return finish("observationBudgetExceeded", records) }
        // Keep fixed references distributed over the route (four by default) in addition to the
        // recent frames. Revisits can reconnect tracks without retaining every frame's descriptors.
        let anchorCount = max(0, options.anchorFrames)
        let anchors = Set((0..<anchorCount).map { usable[min(usable.count-1, $0*usable.count/anchorCount)].id })
        let tracker = FeatureTracker(observationLimit: report.observationBudget,
                                     observationsPerFrame: report.observationsPerFrame,
                                     anchorIDs: anchors, verifyReciprocal: true,
                                     recentFrames: options.recentMatchFrames, maxAnchors: anchorCount)
        for (i, record) in usable.enumerated() {
            if isCancelled() || Task.isCancelled { return finish("cancelled", records) }
            guard RefusionEngine.hasOptionalProcessingHeadroom else { return finish("memoryPressure", records) }
            let extracted = autoreleasepool { extract(record, directory: directory, subpixel: options.subpixelFeatures) }
            if let extracted {
                report.decodeSeconds = (report.decodeSeconds ?? 0) + extracted.decodeSeconds
                report.featureExtractionSeconds = (report.featureExtractionSeconds ?? 0) + extracted.extractSeconds
                let matchStart = Date()
                await tracker.addExtracted(frameID: record.id, extracted: extracted.features, stats: extracted.stats,
                                           K: record.intrinsics,
                                           c2w: RefusionEngine.float4x4(rowMajor: record.transform))
                report.matchingSeconds = (report.matchingSeconds ?? 0) + Date().timeIntervalSince(matchStart)
                report.processedFrames += 1
            } else { report.failedFrames.append(record.id) }
            let state = await tracker.retainedState()
            report.peakDescriptorFrames = max(report.peakDescriptorFrames, state.descriptorFrames)
            progress(Double(i+1) / Double(usable.count) * 0.85)
        }
        let observations = await tracker.observations()
        report.observationCount = observations.count
        report.supportedFrames = Dictionary(grouping: observations.filter { $0.trackID % BundleAdjuster.kHoldoutEvery != BundleAdjuster.kHoldoutEvery - 1 }, by: \.frameID).values
            .filter { $0.count >= BundleAdjuster.kMinObsPerFrame }.count
        print(await tracker.stats())
        await tracker.reset() // Release descriptors before solver allocations.
        guard !isCancelled(), !Task.isCancelled else { return finish("cancelled", records) }
        guard RefusionEngine.hasOptionalProcessingHeadroom else { return finish("memoryPressure", records) }
        let solveStart = Date()
        ba = BundleAdjuster.refine(records: records, observations: observations, rounds: rounds,
                                   options: options, isCancelled: isCancelled)
        report.bundleAdjustmentSeconds = Date().timeIntervalSince(solveStart)
        print(String(format: "手機位姿分段：解碼 %.2fs、特徵 %.2fs、匹配 %.2fs、BA %.2fs；%d 幀 / %d 觀測",
                     report.decodeSeconds ?? 0, report.featureExtractionSeconds ?? 0, report.matchingSeconds ?? 0,
                     report.bundleAdjustmentSeconds ?? 0, report.processedFrames, report.observationCount))
        if isCancelled() || Task.isCancelled { return finish("cancelled", records) }
        report.holdoutBefore = ba.holdoutMedianPx?.before
        report.holdoutAfter = ba.holdoutMedianPx?.after
        guard !ba.poses.isEmpty else { progress(1); return finish(ba.rejectionReason ?? "validationRejectedOrInsufficientTracks", records) }
        // Reject the entire correction if it exceeds a small ARKit refinement. Never clamp
        // poses independently: that would invalidate the held-out reprojection validation.
        for r in records {
            guard let p = ba.poses[r.id] else { continue }
            let base = RefusionEngine.float4x4(rowMajor: r.transform)
            let shift = simd_length(SIMD3<Float>(p.columns.3.x-base.columns.3.x,
                                               p.columns.3.y-base.columns.3.y, p.columns.3.z-base.columns.3.z))
            let q = simd_quatf(p * base.inverse)
            let angle = 2 * acos(min(1, abs(q.real)))
            guard shift.isFinite, angle.isFinite, shift <= 0.15, angle <= 5 * .pi / 180 else {
                ba.poses = [:]; return finish("excessiveCorrection", records)
            }
        }
        let updated = records.map { r -> FrameRecord in
            guard let p = ba.poses[r.id] else { return r }
            var out = r; out.transform = RefusionEngine.rowMajor(p)
            if zip(r.transform, out.transform).contains(where: { abs($0-$1) > 1e-6 }) { report.changedFrames += 1 }
            return out
        }
        progress(1)
        return finish("validated", updated)
    }

    /// Decode one 960px grayscale thumbnail and one depth/confidence pair, then release them.
    /// Features are returned in ORIGINAL image pixels so the BA intrinsics remain unchanged.
    static func extract(_ r: FrameRecord, directory: URL, subpixel: Bool = false)
        -> (features: [TrackedFeature], stats: FeatureExtractor.ExtractStats, decodeSeconds: Double, extractSeconds: Double)? {
        let decodeStart = Date()
        guard let name = r.depthFile, name == (name as NSString).lastPathComponent,
              let dw = r.depthWidth, let dh = r.depthHeight,
              dw > 1, dh > 1, dw <= 1024, dh <= 1024,
              r.transform.count == 16, r.transform.allSatisfy(\.isFinite),
              r.intrinsics.fx.isFinite, r.intrinsics.fy.isFinite,
              r.intrinsics.fx > 0, r.intrinsics.fy > 0 else { return nil }
        let url = directory.appendingPathComponent("depth").appendingPathComponent(name)
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == dw*dh*4,
              let depth = try? Data(contentsOf: url),
              let image = ScanImageDecoder.gray(r, directory: directory, maxDimension: 960) else { return nil }
        var conf: [UInt8]?
        if let name = r.confidenceFile {
            guard name == (name as NSString).lastPathComponent else { return nil }
            let path = directory.appendingPathComponent("depth").appendingPathComponent(name)
            guard (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) == dw*dh,
                  let data = try? Data(contentsOf: path) else { return nil }
            conf = Array(data)
        }
        let k = r.intrinsics.scaled(toWidth: image.width, height: image.height)
        let decodeSeconds = Date().timeIntervalSince(decodeStart)
        let extractStart = Date()
        let extracted = image.pixels.withUnsafeBufferPointer { pixels in
            FeatureExtractor.extract(pixels: pixels.baseAddress!, width: image.width, height: image.height,
                                     rowBytes: image.width, depth: depth, conf: conf, dw: dw, dh: dh,
                                     K: k, c2w: RefusionEngine.float4x4(rowMajor: r.transform),
                                     minDepth: 0.15, maxDepth: 6)
        }
        let sx = Float(r.intrinsics.width) / Float(image.width)
        let sy = Float(r.intrinsics.height) / Float(image.height)
        var features = extracted.features.map { f in var out = f; out.u *= sx; out.v *= sy; return out }
        // Depth stays sampled at the detection position: refinement moves a corner by at most
        // 2.5 px, a third of a depth pixel on the locally smooth surfaces that pass extraction.
        if subpixel, let full = ScanImageDecoder.fullGray(r, directory: directory) {
            full.pixels.withUnsafeBufferPointer { pixels in
                for i in features.indices {
                    if let refined = FeatureExtractor.refineCorner(pixels: pixels.baseAddress!, width: full.width,
                                                                   height: full.height, rowBytes: full.width,
                                                                   u: features[i].u, v: features[i].v) {
                        features[i].u = refined.u; features[i].v = refined.v
                    }
                }
            }
        }
        return (features, extracted.stats, decodeSeconds, Date().timeIntervalSince(extractStart))
    }
}
