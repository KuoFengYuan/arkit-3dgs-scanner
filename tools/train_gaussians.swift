// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// Trains a 3DGS model from a saved scan on the Mac GPU with the app's Metal trainer, for
// regression and ablation experiments. Reads the scan only; writes nothing unless --out is given.
//
// xcrun -sdk macosx metal -std=metal3.1 -ffast-math arkit-3dgs-scanner/Training/*.metal -o /tmp/gs.metallib
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector}.swift \
//   arkit-3dgs-scanner/History/ScanLibrary.swift arkit-3dgs-scanner/Training/*.swift \
//   tools/train_gaussians.swift -o /tmp/train_gaussians
// /tmp/train_gaussians /tmp/gs.metallib SCAN [--iterations N] [--long-edge PX] [--max-gaussians N]
//   [--sh D] [--holdout N] [--no-ppisp] [--no-pose] [--no-mip] [--budget-mb MB] [--out DIR]
// Densification and optimiser experiments (defaults unchanged unless given): --no-growth-ramp,
//   --relocate, --regions track|quota|reclaim, --replace-by-error, --sparse-adam. GS_REFINE=1 prints every refine.
// Photo selection experiments: --selection current|captured (blur verdicts and selection
//   evaluated again with the current rules, or the scan's own), --seed-cells fixed (the room-scale 4 cm cells), --holdout-ids FILE /
//   --write-holdout-ids FILE (the same held-out photos across runs).
// --sog-roundtrip [--sog-palette K] [--sog-iterations N]: write the model as SOG, read it back
//   and score the held-out views again (with --enhance-from DIR --iterations 0 for a saved model).
// Detail at the photos' resolution (needs --align-eval): --view-metrics FILE (per-view CSV: PSNR,
//   edge PSNR, GMSD, band-pass detail, empty share, colour-aligned PSNR), --dump-views DIR --dump-ids A,B.
// Large-scene experiments (off unless given): --sharpness-weights S [--sharpness-floor F],
//   --transient-mask, --pose-smoothing W, --add-ids FILE (train these photos too).
// Speed: --profile-stages N times each stage of a step on N training photos at the end (GPU ms
//   per command buffer; run it apart from timing runs). --strict-seeds seeds from the training
//   photos' LiDAR depth only (the saved cloud also fused the held-out photos' depth).
//   --iterations is always the fixed count (the app's automatic count is only printed).
import Foundation
import Metal
import simd
import ImageIO
import CoreGraphics

@main struct TrainGaussians {
    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            print("Usage: train_gaussians METALLIB SCAN [--iterations N] [--long-edge PX] [--max-gaussians N] [--preset quick|standard|high] [--sh D] [--holdout N] [--no-ppisp] [--no-pose] [--no-mip] [--budget-mb MB] [--out DIR] [--save-model DIR] [--enhance-from MODEL_DIR]")
            exit(2)
        }
        let library = URL(fileURLWithPath: args.removeFirst())
        let scan = URL(fileURLWithPath: args.removeFirst())
        var config = GaussianTrainingConfiguration.preset(.standard)
        config.holdOutEvery = 8
        var out: URL?
        var alignSteps = 0
        var poseLR: Double?
        var poseFile: String?
        var initNoise: Float = 0, initKeep = 1.0, initRandom = 0, latticeJitter: Float = 0
        var perFrame = false
        var seedJitter = true, sparseAdam = false, replaceByError = false, growthRamp = true, relocation = false, regionMode = RegionMode.off, sogRoundTrip = false, sogPalette: Int?, sogIterations = GaussianSOG.kMeansIterations
        var excludeIDs: Set<Int> = []
        var holdOutSegment = 0.0, fullResolution = false
        var saveModel: URL?, enhanceFrom: URL?
        var frameSelection = TrainingDataset.FrameSelection.stored, scaledSeedCells = true
        var holdOutIDs: Set<Int>?, writeHoldOutIDs: URL?
        var viewMetrics: URL?, dumpViews: URL?, dumpIDs: Set<Int> = []
        var extraIDs: Set<Int> = []
        var sharpnessStrength: Float = 0, sharpnessFloor: Float = 0.25, transientMask = false, poseSmoothing = 0.0
        var profileStages = 0, savedCloud = true
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--iterations": config.iterations = Int(args.removeFirst())!
            case "--preset":
                // Another quality preset's iterations, Gaussian cap and SH degree (training resolution kept).
                let preset = GaussianTrainingConfiguration.preset(GaussianTrainingConfiguration.Preset(rawValue: args.removeFirst())!)
                (config.preset, config.iterations, config.maxGaussians, config.shDegree) = (preset.preset, preset.iterations, preset.maxGaussians, preset.shDegree)
            case "--long-edge": config.longEdge = Int(args.removeFirst())!
            case "--max-gaussians": config.maxGaussians = Int(args.removeFirst())!
            case "--sh": config.shDegree = Int(args.removeFirst())!
            case "--holdout": config.holdOutEvery = Int(args.removeFirst())!
            case "--no-ppisp": config.ppisp = false
            case "--no-pose": config.poseOptimization = false
            case "--no-mip": config.mipFilter = false
            case "--budget-mb": config.memoryBudgetMB = Int(args.removeFirst())!
            case "--out": out = URL(fileURLWithPath: args.removeFirst())
            case "--align-eval": alignSteps = Int(args.removeFirst())!
            case "--pose-lr": poseLR = Double(args.removeFirst())!
            case "--pose-file": poseFile = args.removeFirst()
            case "--init-noise": initNoise = Float(args.removeFirst())!
            case "--init-keep": initKeep = Double(args.removeFirst())!
            case "--init-random": initRandom = Int(args.removeFirst())!
            case "--init-lattice-jitter": latticeJitter = Float(args.removeFirst())!
            case "--seed": config.seed = UInt64(args.removeFirst())!
            case "--no-seed-jitter": seedJitter = false
            case "--sparse-adam": sparseAdam = true
            case "--replace-by-error": replaceByError = true
            case "--no-growth-ramp": growthRamp = false
            case "--relocate": relocation = true
            case "--regions":
                switch args.removeFirst() {
                case "off": regionMode = .off
                case "track": regionMode = .track
                case "quota": regionMode = .quota
                case "reclaim": regionMode = .quotaReclaim
                default: print("--regions off|track|quota|reclaim"); exit(2)
                }
            case "--sog-roundtrip": sogRoundTrip = true
            case "--sog-palette": sogPalette = Int(args.removeFirst())!
            case "--sog-iterations": sogIterations = Int(args.removeFirst())!
            case "--no-depth-seeds": config.depthSeeds = false
            case "--no-hole-fill": config.holeFilling = false
            case "--depth-loss": config.depthLoss = Double(args.removeFirst())!
            case "--holdout-segment": holdOutSegment = Double(args.removeFirst())!
            case "--eval-full-res": fullResolution = true
            case "--save-model": saveModel = URL(fileURLWithPath: args.removeFirst())
            case "--enhance-from": enhanceFrom = URL(fileURLWithPath: args.removeFirst())
            case "--selection":
                // stored: as the app (older selections evaluated again); current: always evaluated
                // again; captured: the scan's own verdicts and selection.
                switch args.removeFirst() {
                case "current": frameSelection = .current(readout: CaptureConfig().rollingShutterReadoutS)
                case "captured": frameSelection = .captured
                default: frameSelection = .stored
                }
            case "--seed-cells": scaledSeedCells = args.removeFirst() != "fixed"
            case "--holdout-ids":
                let text = try String(contentsOf: URL(fileURLWithPath: args.removeFirst()), encoding: .utf8)
                holdOutIDs = Set(text.split(whereSeparator: { $0 == "," || $0.isNewline }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            case "--write-holdout-ids": writeHoldOutIDs = URL(fileURLWithPath: args.removeFirst())
            case "--transient-mask": transientMask = true
            case "--profile-stages": profileStages = Int(args.removeFirst())!
            case "--strict-seeds": savedCloud = false
            case "--add-ids":
                // Experiment: also train these photos (e.g. dropped by the blur review), held out or not by the usual rule.
                let text = try String(contentsOf: URL(fileURLWithPath: args.removeFirst()), encoding: .utf8)
                extraIDs = Set(text.split(whereSeparator: { $0 == "," || $0.isNewline }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            case "--pose-smoothing": poseSmoothing = Double(args.removeFirst())!
            case "--sharpness-weights": sharpnessStrength = Float(args.removeFirst())!
            case "--no-sharpness-weights": sharpnessStrength = 0
            case "--sharpness-floor": sharpnessFloor = Float(args.removeFirst())!
            case "--view-metrics": viewMetrics = URL(fileURLWithPath: args.removeFirst())
            case "--dump-views": dumpViews = URL(fileURLWithPath: args.removeFirst())
            case "--dump-ids": dumpIDs = Set(args.removeFirst().split(separator: ",").compactMap { Int($0) })
            case "--exclude-ids": excludeIDs = Set(args.removeFirst().split(separator: ",").compactMap { Int($0) })
            case "--per-frame": perFrame = true
            case "--motion-blur": config.motionBlur = true
            case "--readout-ms": config.rollingShutterReadout = Double(args.removeFirst())! / 1000
            default: print("Unknown option \(a)"); exit(2)
            }
        }
        if let enhanceFrom {
            // Enhance model: --iterations more on top of the saved model's.
            guard let saved = GaussianExport.metadata(in: enhanceFrom) else { print("No model metadata in \(enhanceFrom.path)"); exit(2) }
            config = config.enhancing(savedIterations: saved.iterations, savedGaussians: saved.gaussians, savedSHDegree: saved.shDegree)
            print("enhancing a model of \(saved.iterations) iterations, \(saved.gaussians) Gaussians, SH \(saved.shDegree): \(config.runIterations) more to \(config.iterations)")
        }
        let t0 = Date()
        let seedStart = Date()
        var dataset = try TrainingDataset.prepare(scan: scan, longEdge: config.longEdge, holdOutEvery: config.holdOutEvery,
                                                  maxPoints: config.seedBudget, depthSeedLimit: config.depthSeedLimit(cloudPoints:), holdOutSegment: holdOutSegment,
                                                  frameSelection: frameSelection, holdOutIDs: holdOutIDs, scaledSeedCells: scaledSeedCells,
                                                  extraTrainingIDs: extraIDs, savedCloud: savedCloud)
        let scale = scaledSeedCells ? TrainingFrameSelector.metricScale(workingDistance: dataset.workingDistance) : 1
        print(String(format: "seeds: %d points (depth seeds %@, seed budget %d, working distance %.2f m, seed cell %.1f mm) in %.1f s",
                     dataset.points.count, config.usesDepthSeeds ? "on" : "off", config.seedBudget, dataset.workingDistance ?? 0,
                     40 * scale, Date().timeIntervalSince(seedStart)))
        if let writeHoldOutIDs {
            try dataset.validationFrames.map { String(dataset.frames[$0].id) }.joined(separator: ",").write(to: writeHoldOutIDs, atomically: true, encoding: .utf8)
        }
        dataset = try perturbed(dataset, scan: scan, poseFile: poseFile, noise: initNoise, keep: initKeep, random: initRandom,
                                latticeJitter: latticeJitter)
        if !excludeIDs.isEmpty {
            // Experiment: drop these photos from training (held-out views are kept).
            let frames = dataset.frames.filter { $0.isValidation || !excludeIDs.contains($0.id) }
            print("excluded \(dataset.frames.count - frames.count) training photos: \(excludeIDs.sorted())")
            dataset = TrainingDataset(directory: dataset.directory, frames: frames, points: dataset.points, width: dataset.width, height: dataset.height)
        }
        print(String(format: "iterations: %d fixed (the app's automatic %@ count for %d training photos: %d)", config.iterations,
                     config.preset.rawValue, dataset.trainFrames.count,
                     GaussianTrainingConfiguration.automaticIterations(config.preset, trainingPhotos: dataset.trainFrames.count)))
        print("dataset: \(dataset.frames.count) frames (\(dataset.validationFrames.count) validation), \(dataset.points.count) points, \(dataset.width)x\(dataset.height), prepared in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        let budget = (config.memoryBudgetMB.map { $0 << 20 }) ?? TrainingMemoryPlan.automaticBudget()
        let plan = try TrainingMemoryPlan.fit(width: dataset.width, height: dataset.height, shDegree: config.shDegree,
                                              requestedGaussians: config.maxGaussians, budgetBytes: budget)
        print("plan: \(plan.summary)")
        let metal = try GaussianMetal(libraryURL: library)
        let trainer = try GaussianTrainer(configuration: config, dataset: dataset, plan: plan, metal: metal)
        if let poseLR { trainer.poseLearningRate = poseLR }
        trainer.transientMasking = transientMask
        trainer.poseSmoothing = poseSmoothing
        if sharpnessStrength > 0 {
            // Experiment: photos blurrier than other training photos of the same surface teach
            // detail less, weight max(floor, e^(-strength · deficit)).
            let started = Date()
            let scores = CovisibleSharpness.scores(frames: dataset.frames, directory: dataset.directory, peers: Set(dataset.trainFrames),
                                                   metricScale: TrainingFrameSelector.metricScale(workingDistance: dataset.workingDistance))
            trainer.viewWeights = CovisibleSharpness.weights(scores, count: dataset.frames.count, strength: sharpnessStrength, floor: sharpnessFloor)
            let w = dataset.trainFrames.map { trainer.viewWeights[$0] }.sorted()
            if !w.isEmpty { print(String(format: "sharpness weights (strength %.2f, floor %.2f) in %.1f s: %d scored, weight p10 %.2f, median %.2f, mean %.2f",
                         sharpnessStrength, sharpnessFloor, Date().timeIntervalSince(started), scores.count,
                         w[w.count / 10], w[w.count / 2], w.reduce(0, +) / Float(w.count))) }
        }
        trainer.seedJitter = seedJitter
        trainer.sparseAdam = sparseAdam
        trainer.replaceByError = replaceByError
        trainer.growthRamp = growthRamp
        trainer.relocation = relocation
        trainer.regionMode = regionMode
        print(String(format: "pose learning rate %.1e, seed jitter %@, depth loss %.2f", trainer.poseLearningRate,
                     seedJitter ? "on" : "off", config.depthLossWeight))
        if let enhanceFrom { try trainer.initializeModel(fromSaved: enhanceFrom) } else { try trainer.initializeModel() }
        if enhanceFrom != nil {
            print(String(format: "enhancement start: validation PSNR %.3f (unaligned)", try trainer.evaluate().psnr))
        }
        print("initial Gaussians \(trainer.model.activeCount), scene extent (10–90%) \(trainer.strategy.bounds.medianSize) m, footprint \(TrainingMemoryPlan.footprintBytes >> 20) MB, lifetime peak so far \(lifetimeFootprintPeak() >> 20) MB")
        let start = Date()
        var window: [Double] = [], psnrWindow: [Double] = [], peak = 0, skipped = 0, pairsPeak = 0.0, pairsSeen = 0.0
        while trainer.iteration < config.iterations {
            let r = try trainer.step()
            // Tile-Gaussian pairs of this view (the profile accumulates them).
            let pairsTotal = trainer.profile["intersections", default: 0]
            pairsPeak = max(pairsPeak, pairsTotal - pairsSeen)
            pairsSeen = pairsTotal
            if r.skipped { skipped += 1; continue }
            window.append(r.loss); psnrWindow.append(r.psnr)
            if let refine = r.refine, trainer.iteration % (trainer.strategy.schedule.refineEvery * 10) == 0
                || ProcessInfo.processInfo.environment["GS_REFINE"] != nil {
                print("  refine @\(r.iteration): pruned \(refine.pruned) replaced \(refine.replaced) relocated \(refine.relocated) (judged \(refine.judged) donors \(refine.donors) receivers \(refine.receivers)) oversize \(refine.oversize) grown \(refine.grown) (by quota \(refine.quotaGrown), regions \(refine.regions)) holes \(refine.holes) (total \(trainer.holeSeedsAdded)) live \(refine.live)")
            }
            if ProcessInfo.processInfo.environment["GS_VERBOSE"] != nil { print("step \(r.iteration) \(String(format: "%.1f", r.seconds * 1000)) ms loss \(r.loss) M? gaussians \(r.gaussians)") }
            if r.iteration % 500 == 0 || r.iteration == config.iterations {
                peak = max(peak, TrainingMemoryPlan.footprintBytes)
                let elapsed = Date().timeIntervalSince(start)
                print(String(format: "it %5d  loss %.4f  train PSNR %.2f  Gaussians %7d  %.1f ms/it  footprint %d MB  peak pairs %.0f",
                             r.iteration, window.reduce(0, +) / Double(window.count), psnrWindow.reduce(0, +) / Double(psnrWindow.count),
                             r.gaussians, elapsed / Double(max(1, r.iteration - config.startIteration)) * 1000, TrainingMemoryPlan.footprintBytes >> 20,
                             pairsPeak))
                pairsPeak = 0
                window.removeAll(); psnrWindow.removeAll()
            }
        }
        let seconds = Date().timeIntervalSince(start)
        print("peak physical footprint: sampled \(peak >> 20) MB, lifetime \(lifetimeFootprintPeak() >> 20) MB (lifetime includes preparation)")
        for (k, v) in trainer.profile.sorted(by: { $0.key < $1.key }) {
            let n = Double(max(1, config.runIterations))
            print(String(format: "  profile %@: %.2f per iteration", k, k == "intersections" ? v / n : v / n * 1000))
        }
        let evalStart = Date()
        let eval = try trainer.evaluate()
        let evalSeconds = Date().timeIntervalSince(evalStart)
        for scale in [0.5, 0.25] {
            let zoomed = try trainer.evaluate(scale: scale)
            print(String(format: "validation at %.2fx resolution: PSNR %.3f SSIM %.4f", scale, zoomed.psnr, zoomed.ssim))
        }
        if alignSteps > 0 {
            let aligned = try trainer.evaluate(alignSteps: alignSteps)
            print(String(format: "validation with test-time pose alignment (%d steps): PSNR %.3f SSIM %.4f", alignSteps, aligned.psnr, aligned.ssim))
            if fullResolution, let f = trainer.dataset.frames.first {
                // The photos' own resolution, with the held-out views' test-time alignment.
                let scale = Double(f.intrinsics.width) / Double(trainer.dataset.width)
                let full = try trainer.evaluate(scale: scale, aligned: true)
                print(String(format: "validation aligned at full resolution (%dx%d): PSNR %.3f SSIM %.4f over %d views",
                             f.intrinsics.width, f.intrinsics.height, full.psnr, full.ssim, full.count))
            }
            if viewMetrics != nil || dumpViews != nil {
                try reportViewMetrics(trainer, csv: viewMetrics, dump: dumpViews, dumpIDs: dumpIDs)
            }
            if holdOutSegment > 0 { try reportHeldOutViews(trainer) }
            if config.captureMotion != nil {
                let still = try trainer.evaluate(alignSteps: alignSteps, captureMotion: false)
                print(String(format: "validation aligned, rendered without capture motion: PSNR %.3f SSIM %.4f", still.psnr, still.ssim))
            }
        }
        print(String(format: "done: %d iterations in %.1f s (%.1f ms/it), skipped %d, validation PSNR %.3f SSIM %.4f over %d views, peak footprint %d MB",
                     config.runIterations, seconds, seconds / Double(max(1, config.runIterations)) * 1000, skipped, eval.psnr, eval.ssim, eval.count, peak >> 20))
        if let regions = trainer.strategy.regions { printRegions(regions, trainer: trainer) }
        if transientMask {
            let share = trainer.transientMaskedShare
            print(String(format: "transient masks: %.2f%% of blocks masked", Double(share.blocks) / Double(max(1, share.total)) * 100))
            if let viewMetrics {
                // The last mask of every training photo: id, block columns, masked block indices.
                let columns = trainer.loss.blocks.columns
                let lines = trainer.dataset.frames.indices.compactMap { i -> String? in
                    guard let m = trainer.transientMasks[i] else { return nil }
                    return ([trainer.dataset.frames[i].id, columns] + m.indices.filter { m[$0] == 0 }).map(String.init).joined(separator: ",")
                }
                try lines.joined(separator: "\n").write(to: viewMetrics.deletingLastPathComponent().appendingPathComponent("masks.csv"), atomically: true, encoding: .utf8)
            }
        }
        if config.ppisp {
            let s = trainer.ppisp.summary
            print(String(format: "PPISP: exposure %.2f..%.2f EV, corner vignetting %.3f", s.minEV, s.maxEV, s.cornerVignetting))
        }
        if config.poseOptimization {
            let rot = trainer.poses.map(\.rotationDegrees).sorted(), trans = trainer.poses.map { $0.translationMeters * 1000 }.sorted()
            print(String(format: "pose corrections: median %.3f° / %.2f mm, max %.3f° / %.2f mm", rot[rot.count / 2], trans[trans.count / 2], rot.last!, trans.last!))
        }
        if perFrame { try reportPerFrame(trainer) }
        if sogRoundTrip {
            try reportSOGRoundTrip(trainer, metal: metal, alignSteps: max(alignSteps, 30), palette: sogPalette, iterations: sogIterations)
        }
        try reportCoverage(trainer)
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true); _ = out }
        if let saveModel {
            // The app's end-of-run save: held-out scoring, then the model files, with the time of
            // each step against the progress the app shows (to check `savingShares`).
            try FileManager.default.createDirectory(at: saveModel, withIntermediateDirectories: true)
            print(String(format: "save   0.00 s    0.0%%  validating (%d views, %.2f s)", eval.count, evalSeconds))
            let saveStart = Date()
            var lastStep = ""
            try GaussianTrainingSession.writeModelFiles(trainer, into: saveModel, validation: eval.count > 0 ? eval.psnr : nil,
                                                        elapsedSeconds: seconds, peakFootprintMB: peak >> 20) { saving in
                let step = "\(saving.step)"
                guard step != lastStep else { return }
                lastStep = step
                print(String(format: "save %6.2f s  %5.1f%%  %@", evalSeconds + Date().timeIntervalSince(saveStart), saving.fraction * 100, step))
            }
            print(String(format: "saved model in %.2f s (+ %.2f s validation): %@", Date().timeIntervalSince(saveStart), evalSeconds, saveModel.path))
        }
        if profileStages > 0 { try reportStages(trainer, photos: profileStages) }
    }

    /// Experiment inputs: poses from another pose file of the scan (same frame selection), and a
    /// degraded seed cloud (Gaussian noise in metres, a kept fraction, or uniform random points
    /// in the cloud's bounding box).
    static func perturbed(_ d: TrainingDataset, scan: URL, poseFile: String?, noise: Float, keep: Double,
                          random: Int, latticeJitter: Float = 0) throws -> TrainingDataset {
        var frames = d.frames
        if let poseFile {
            var byID: [Int: [Double]] = [:]
            let text = try String(contentsOf: scan.appendingPathComponent(poseFile), encoding: .utf8)
            for line in text.split(separator: "\n") {
                guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = obj["id"] as? Int, let t = obj["transform"] as? [Double], t.count == 16 else { continue }
                byID[id] = t
            }
            var replaced = 0
            for i in frames.indices { if let t = byID[frames[i].id] { frames[i].transform = t; replaced += 1 } }
            print("poses from \(poseFile): \(replaced) of \(frames.count) frames")
        }
        var rng = SplitMix64(seed: 99)
        func gauss() -> Float {
            let u1 = max(1e-12, Double(rng.next() >> 11) / Double(1 << 53)), u2 = Double(rng.next() >> 11) / Double(1 << 53)
            return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
        }
        var points = d.points
        if keep < 1 { points = Swift.stride(from: 0, to: points.count, by: max(1, Int((1 / keep).rounded()))).map { points[$0] } }
        if noise > 0 { for i in points.indices { points[i].x += noise * gauss(); points[i].y += noise * gauss(); points[i].z += noise * gauss() } }
        if latticeJitter > 0 {
            // TSDF edge crossings: two coordinates sit on voxel centres, the third is interpolated.
            // Spread only the snapped ones (within the voxel), keeping points on axis-aligned surfaces.
            let v = latticeJitter
            func uniform() -> Float { Float(Double(rng.next() >> 11) / Double(1 << 53)) - 0.5 }
            func jitter(_ c: Float) -> Float {
                let f = c / v - 0.5
                return abs(f - f.rounded()) < 0.01 ? c + v * uniform() : c
            }
            var moved = 0
            for i in points.indices {
                let before = SIMD3(points[i].x, points[i].y, points[i].z)
                points[i].x = jitter(points[i].x); points[i].y = jitter(points[i].y); points[i].z = jitter(points[i].z)
                if SIMD3(points[i].x, points[i].y, points[i].z) != before { moved += 1 }
            }
            print("lattice jitter \(v) m: \(moved) of \(points.count) points moved")
        }
        if random > 0 {
            let xs = d.points.map(\.x).sorted(), ys = d.points.map(\.y).sorted(), zs = d.points.map(\.z).sorted()
            func range(_ v: [Float]) -> (Float, Float) { (v[v.count / 100], v[v.count * 99 / 100]) }
            let (x0, x1) = range(xs), (y0, y1) = range(ys), (z0, z1) = range(zs)
            func u() -> Float { Float(Double(rng.next() >> 11) / Double(1 << 53)) }
            points = (0..<random).map { _ in
                CloudPoint(x: x0 + (x1 - x0) * u(), y: y0 + (y1 - y0) * u(), z: z0 + (z1 - z0) * u(), r: 128, g: 128, b: 128)
            }
        }
        if keep < 1 || noise > 0 || random > 0 { print("seed cloud: \(points.count) points (noise \(noise) m, keep \(keep), random \(random))") }
        return TrainingDataset(directory: d.directory, frames: frames, points: points, width: d.width, height: d.height)
    }

    /// Share of held-out pixels the model leaves empty (final transmittance above 0.5): the
    /// surfaces no Gaussian reached.
    /// Live Gaussians per region against its quota share, grouped by that ratio: the share of
    /// the visible area, of the Gaussians and the area-weighted error in each group.
    static func printRegions(_ regions: RegionQuota, trainer: GaussianTrainer) {
        let model = trainer.model
        let shares = regions.shares(trainingViews: trainer.strategy.trainingViews ?? 1)
        let regionOf = regions.regions(model)
        let active = model.stat(GaussianStats.active)
        var counts = [Int](repeating: 0, count: shares.count)
        for i in 0..<model.count where active[i] > 0.5 { counts[Int(regionOf[i])] += 1 }
        let live = Float(max(1, model.activeCount))
        let totalArea = regions.area.reduce(0, +)
        let groups: [(String, ClosedRange<Float>)] = [("< 0.5×", 0...0.5), ("0.5–1×", 0.5...1), ("1–2×", 1...2), ("> 2×", 2...Float.infinity)]
        print(String(format: "regions: %d with visible area, cell %.2f m", shares.filter { $0 > 0 }.count, regions.cell))
        for (label, range) in groups {
            var area: Float = 0, gaussians = 0, error: Float = 0, cells = 0
            for r in 0..<shares.count where shares[r] > 0 {
                let ratio = Float(counts[r]) / (shares[r] * live)
                guard range.contains(ratio), !(ratio == range.lowerBound && range.lowerBound > 0) else { continue }
                area += regions.area[r]; gaussians += counts[r]; error += regions.area[r] * regions.error[r]; cells += 1
            }
            print(String(format: "  Gaussians/quota %@: %4d cells, %5.1f%% of visible area, %5.1f%% of Gaussians, mean error %.2f",
                         label, cells, area / max(totalArea, 1e-9) * 100, Float(gaussians) / live * 100, area > 0 ? error / area : 0))
        }
    }

    static func reportCoverage(_ trainer: GaussianTrainer) throws {
        let views = trainer.dataset.validationFrames
        guard !views.isEmpty else { return }
        var empty = 0.0
        var depthErrors: [Float] = []
        let W = trainer.dataset.width, H = trainer.dataset.height, pixels = W * H
        for i in views {
            _ = try trainer.evaluate(frames: [i])
            let image = trainer.target.image.contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels)
            let depth = trainer.target.depth.contents().bindMemory(to: Float.self, capacity: pixels)
            var count = 0
            for p in 0..<pixels where image[p].w > 0.5 { count += 1 }
            empty += Double(count) / Double(pixels)
            // Rendered depth against high-confidence LiDAR (relative error).
            if let lidar = trainer.dataset.lidarDepth(i) {
                for y in Swift.stride(from: 0, to: lidar.height, by: 2) {
                    for x in Swift.stride(from: 0, to: lidar.width, by: 2) {
                        let z = lidar.depth[y * lidar.width + x]
                        guard lidar.confidence[y * lidar.width + x] == 2, z > 0.1, z < 5 else { continue }
                        let px = min(W - 1, Int((Float(x) + 0.5) * Float(W) / Float(lidar.width)))
                        let py = min(H - 1, Int((Float(y) + 0.5) * Float(H) / Float(lidar.height)))
                        let coverage = 1 - image[py * W + px].w
                        guard coverage > 0.5 else { continue }
                        depthErrors.append(abs(depth[py * W + px] / coverage - z) / z)
                    }
                }
            }
        }
        print(String(format: "held-out empty pixels (transmittance > 0.5): %.2f%%", empty / Double(views.count) * 100))
        if !depthErrors.isEmpty {
            let sorted = depthErrors.sorted()
            print(String(format: "held-out depth vs high-confidence LiDAR: median %.2f%%, p90 %.2f%%, share > 5%%: %.2f%%",
                         sorted[sorted.count / 2] * 100, sorted[sorted.count * 9 / 10] * 100,
                         Double(sorted.filter { $0 > 0.05 }.count) / Double(sorted.count) * 100))
        }
    }

    /// Training-view PSNR per frame with the frame's angular speed (from neighbouring poses),
    /// to separate motion (blur / rolling shutter) from other error sources.
    /// Aligned PSNR of each held-out view against its distance from the nearest training camera,
    /// to tell interpolation between training views from extrapolation beyond them.
    static func reportHeldOutViews(_ trainer: GaussianTrainer) throws {
        let frames = trainer.dataset.frames
        func position(_ i: Int) -> SIMD3<Double> { let t = frames[i].transform; return SIMD3(t[3], t[7], t[11]) }
        func forward(_ i: Int) -> SIMD3<Double> { let t = frames[i].transform; return -SIMD3(t[2], t[6], t[10]) }
        for i in trainer.dataset.validationFrames {
            let nearest = trainer.dataset.trainFrames.min { simd_distance(position($0), position(i)) < simd_distance(position($1), position(i)) }!
            let angle = acos(max(-1, min(1, simd_dot(forward(nearest), forward(i))))) * 180 / .pi
            let psnr = try trainer.evaluate(scale: 1, frames: [i], aligned: true).psnr
            print(String(format: "held-out frame %d aligned PSNR %.2f, nearest training camera %.2f m / %.1f°",
                         frames[i].id, psnr, simd_distance(position(nearest), position(i)), angle))
        }
    }

    /// Local detail of each held-out view at the photos' own resolution, after the test-time
    /// alignment of the last aligned evaluation (so 960 and 1,440 px models are scored alike).
    /// Whole-image PSNR hides blur: a soft render of a large wall scores well. The CSV adds
    /// PSNR on the photo's strongest edges, GMSD and the band-pass detail kept in textured
    /// blocks (see `ViewDetail`). `dump` writes the renders of `dumpIDs` as PNG.
    static func reportViewMetrics(_ trainer: GaussianTrainer, csv: URL?, dump: URL?, dumpIDs: Set<Int>) throws {
        guard let f = trainer.dataset.frames.first else { return }
        let scale = Double(f.intrinsics.width) / Double(trainer.dataset.width)
        var rows = ["id,psnr,edge_psnr,gmsd,detail_ratio,textured_blocks,empty,color_psnr,color_edge_psnr,ssim,luma_bias"]
        var sums = [Double](repeating: 0, count: 4), n = 0, colorSum = 0.0
        if let dump { try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }
        _ = try trainer.evaluate(scale: scale, aligned: true) { index, image, photo, w, h, ssim in
            let id = trainer.dataset.frames[index].id
            let d = ViewDetail.measure(image: image, photo: photo, width: w, height: h)
            // Share of pixels the model leaves empty (final transmittance above 0.5).
            let empty = Double((0..<(w * h)).filter { image[$0].w > 0.5 }.count) / Double(w * h)
            rows.append(String(format: "%d,%.4f,%.4f,%.5f,%.4f,%d,%.4f,%.4f,%.4f,%.5f,%.5f", id, d.psnr, d.edgePSNR, d.gmsd, d.detailRatio, d.texturedBlocks, empty,
                               d.alignedPSNR, d.alignedEdgePSNR, ssim, d.lumaBias))
            sums[0] += d.psnr; sums[1] += d.edgePSNR; sums[2] += d.gmsd; sums[3] += log2(max(1e-6, d.detailRatio)); n += 1
            colorSum += d.alignedPSNR
            if let dump, dumpIDs.contains(id) { ViewDetail.writePNG(image, width: w, height: h, to: dump.appendingPathComponent("render_\(id).png")) }
        }
        guard n > 0 else { return }
        print(String(format: "view detail at %dx%d over %d views: PSNR %.3f (colour-aligned %.3f), edge PSNR %.3f, GMSD %.4f, detail ratio %.3f",
                     f.intrinsics.width, f.intrinsics.height, n, sums[0] / Double(n), colorSum / Double(n), sums[1] / Double(n), sums[2] / Double(n),
                     pow(2, sums[3] / Double(n))))
        if let csv { try rows.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8) }
    }

    /// Largest physical footprint of the process so far.
    static func lifetimeFootprintPeak() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return ok == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak) : 0
    }

    /// Stage times of a training step on `photos` training photos spread over the capture.
    static func reportStages(_ trainer: GaussianTrainer, photos: Int) throws {
        let train = trainer.dataset.trainFrames
        let frames = Swift.stride(from: 0, to: train.count, by: max(1, train.count / max(1, photos))).prefix(photos).map { train[$0] }
        let stages = try trainer.profileStages(frames: frames)
        print("stage profile at iteration \(trainer.iteration), \(trainer.model.activeCount) Gaussians, \(frames.count) photos (ms; median, mean):")
        var gpu = 0.0
        for (stage, ms) in stages {
            let sorted = ms.sorted(), mean = ms.reduce(0, +) / Double(max(1, ms.count))
            if !stage.contains("(") { gpu += mean }
            print("  stage " + stage.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "%9.3f %9.3f", sorted[sorted.count / 2], mean))
        }
        print("  stage " + "GPU total (mean)".padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "%19.3f", gpu))
    }

    /// Writes the model as SOG (reusing the gradient and intersection buffers, as the app
    /// does), reads it back into the trainer, and scores the held-out views again.
    static func reportSOGRoundTrip(_ trainer: GaussianTrainer, metal: GaussianMetal, alignSteps: Int, palette: Int?, iterations: Int) throws {
        let before = try trainer.evaluate(alignSteps: alignSteps)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-\(UUID().uuidString).sog")
        defer { try? FileManager.default.removeItem(at: url) }
        let plyBytes = trainer.model.activeCount * GaussianExport.propertyNames(shDegree: trainer.model.shDegree).count * 4
        let footprintBefore = TrainingMemoryPlan.footprintBytes, peakBefore = lifetimeFootprintPeak()
        let report = try GaussianSOG.write(trainer.model, to: url, metal: metal,
                                           scratch: .init(points: trainer.model.grads, palette: trainer.raster.keys, labels: trainer.raster.values),
                                           iterations: iterations, paletteEntries: palette)
        print(String(format: "SOG: %d Gaussians, %d palette entries, %.1f MB (PLY %.1f MB, %.1f×), %.1f s (k-means %.1f s)",
                     report.gaussians, report.paletteEntries, Double(report.bytes) / 1e6, Double(plyBytes) / 1e6,
                     Double(plyBytes) / Double(report.bytes), report.seconds, report.kMeansSeconds))
        print("SOG write memory: footprint \(footprintBefore >> 20) MB before, lifetime peak \(peakBefore >> 20) -> \(lifetimeFootprintPeak() >> 20) MB")
        let readStart = Date()
        try GaussianSOG.read(url, into: trainer.model)
        let readSeconds = Date().timeIntervalSince(readStart)
        let after = try trainer.evaluate(alignSteps: alignSteps)
        print(String(format: "SOG read in %.2f s; held-out aligned PSNR %.3f -> %.3f (SSIM %.4f -> %.4f)",
                     readSeconds, before.psnr, after.psnr, before.ssim, after.ssim))
    }

    static func reportPerFrame(_ trainer: GaussianTrainer) throws {
        let frames = trainer.dataset.frames
        var rows: [(Int, Double, Double)] = []
        for i in trainer.dataset.trainFrames {
            let psnr = try trainer.evaluate(frames: [i]).psnr
            let a = frames[max(0, i - 1)], b = frames[min(frames.count - 1, i + 1)]
            let ra = simd_double3x3(rows: [SIMD3(a.transform[0], a.transform[1], a.transform[2]), SIMD3(a.transform[4], a.transform[5], a.transform[6]), SIMD3(a.transform[8], a.transform[9], a.transform[10])])
            let rb = simd_double3x3(rows: [SIMD3(b.transform[0], b.transform[1], b.transform[2]), SIMD3(b.transform[4], b.transform[5], b.transform[6]), SIMD3(b.transform[8], b.transform[9], b.transform[10])])
            let r = ra.transpose * rb
            let angle = acos(max(-1, min(1, (r[0][0] + r[1][1] + r[2][2] - 1) / 2))) * 180 / .pi
            rows.append((frames[i].id, psnr, angle))
        }
        for row in rows { print(String(format: "frame %d psnr %.3f neighbour-rotation %.3f", row.0, row.1, row.2)) }
    }
}

/// Local detail of a render against its photo (luma for the gradient terms, RGB for PSNR).
/// - `edgePSNR`: PSNR on the photo's strongest 10% of Sobel gradients (edges and texture).
/// - `gmsd`: gradient magnitude similarity deviation (Xue et al., 2014; Prewitt, c = 0.0026),
///   lower is better; computed at full resolution, without the usual 2× downsampling.
/// - `alignedPSNR`, `alignedEdgePSNR`: the same after a per-channel gain and offset fitted to the
///   photo (a global brightness or colour offset of the novel view is not lost detail).
/// - `detailRatio`: in 32 × 32 blocks where the photo has texture, band-pass energy
///   (3 × 3 minus 7 × 7 box blur) of the render over the photo's, geometric mean. Below 1 the
///   render is softer than the photo; a noisy photo also lowers it, so compare runs, not scans.
enum ViewDetail {
    /// `lumaBias`: mean luma of the render minus the photo's (0-1; negative = darker).
    struct Result { var psnr, edgePSNR, gmsd, detailRatio: Double; var texturedBlocks: Int; var alignedPSNR = 0.0, alignedEdgePSNR = 0.0, lumaBias = 0.0 }

    static func measure(image: UnsafePointer<SIMD4<Float>>, photo: UnsafePointer<UInt8>, width w: Int, height h: Int) -> Result {
        let n = w * h
        var yr = [Float](repeating: 0, count: n), yg = [Float](repeating: 0, count: n)
        var sq = [Float](repeating: 0, count: n)
        for p in 0..<n {
            let c = simd_clamp(SIMD3(image[p].x, image[p].y, image[p].z), SIMD3(repeating: 0), SIMD3(repeating: 1))
            let g = SIMD3(Float(photo[4 * p]), Float(photo[4 * p + 1]), Float(photo[4 * p + 2])) / 255
            let d = c - g
            sq[p] = simd_dot(d, d)
            yr[p] = simd_dot(c, SIMD3(0.299, 0.587, 0.114)); yg[p] = simd_dot(g, SIMD3(0.299, 0.587, 0.114))
        }
        let mse = sq.reduce(0.0) { $0 + Double($1) } / Double(n * 3)
        // Colour-aligned error: a per-channel gain and offset fitted by least squares first, so a
        // global brightness or colour offset of the novel-view ISP does not count as lost detail.
        var alignedSq = [Float](repeating: 0, count: n)
        for c in 0..<3 {
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for p in 0..<n {
                let x = Double(min(1, max(0, image[p][c]))), y = Double(photo[4 * p + c]) / 255
                sx += x; sy += y; sxx += x * x; sxy += x * y
            }
            let N = Double(n), den = N * sxx - sx * sx
            let gain = den > 1e-9 ? (N * sxy - sx * sy) / den : 1, offset = (sy - gain * sx) / N
            for p in 0..<n {
                let x = Double(min(1, max(0, image[p][c]))), y = Double(photo[4 * p + c]) / 255
                let d = Float(min(1, max(0, gain * x + offset)) - y)
                alignedSq[p] += d * d
            }
        }
        let alignedMSE = alignedSq.reduce(0.0) { $0 + Double($1) } / Double(n * 3)
        // Gradients (Sobel for the edge mask, Prewitt for GMSD) on the interior.
        var sobel = [Float](repeating: 0, count: n), gms = [Double]()
        gms.reserveCapacity(n)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                func grad(_ v: [Float], _ k: Float) -> Float {
                    let gx = (v[i - w + 1] + k * v[i + 1] + v[i + w + 1]) - (v[i - w - 1] + k * v[i - 1] + v[i + w - 1])
                    let gy = (v[i + w - 1] + k * v[i + w] + v[i + w + 1]) - (v[i - w - 1] + k * v[i - w] + v[i - w + 1])
                    return (gx * gx + gy * gy).squareRoot() / (2 + k)
                }
                sobel[i] = grad(yg, 2)
                let mr = Double(grad(yr, 1)), mg = Double(grad(yg, 1)), c = 0.0026
                gms.append((2 * mr * mg + c) / (mr * mr + mg * mg + c))
            }
        }
        let meanGMS = gms.reduce(0, +) / Double(max(1, gms.count))
        let gmsd = (gms.reduce(0) { $0 + ($1 - meanGMS) * ($1 - meanGMS) } / Double(max(1, gms.count))).squareRoot()
        let sampled = Swift.stride(from: 0, to: n, by: 7).map { sobel[$0] }.sorted()
        let edgeThreshold = sampled[sampled.count * 9 / 10]
        var edgeSum = 0.0, alignedEdgeSum = 0.0, edgeCount = 0
        for p in 0..<n where sobel[p] >= edgeThreshold && sobel[p] > 0 { edgeSum += Double(sq[p]); alignedEdgeSum += Double(alignedSq[p]); edgeCount += 1 }
        let edgeMSE = edgeSum / Double(max(1, edgeCount) * 3), alignedEdgeMSE = alignedEdgeSum / Double(max(1, edgeCount) * 3)
        // Band-pass energy per 32 × 32 block.
        let br = bandPass(yr, w, h), bg = bandPass(yg, w, h)
        var logs: [Double] = []
        let block = 32
        for by in Swift.stride(from: 4, to: h - block - 4, by: block) {
            for bx in Swift.stride(from: 4, to: w - block - 4, by: block) {
                var er = 0.0, eg = 0.0, grad = 0.0
                for y in by..<(by + block) { for x in bx..<(bx + block) {
                    let i = y * w + x
                    er += Double(br[i] * br[i]); eg += Double(bg[i] * bg[i]); grad += Double(sobel[i])
                } }
                // Texture: mean gradient above 0.01 (a white wall's noise stays below it).
                guard grad / Double(block * block) > 0.01, eg > 1e-9 else { continue }
                logs.append(log2(max(er, 1e-12) / eg))
            }
        }
        let detail = logs.isEmpty ? 0 : pow(2, logs.reduce(0, +) / Double(logs.count))
        func psnr(_ m: Double) -> Double { m > 0 ? -10 * log10(m) : 99 }
        return Result(psnr: psnr(mse), edgePSNR: psnr(edgeMSE), gmsd: gmsd, detailRatio: detail, texturedBlocks: logs.count,
                      alignedPSNR: psnr(alignedMSE), alignedEdgePSNR: psnr(alignedEdgeMSE),
                      lumaBias: (yr.reduce(0.0) { $0 + Double($1) } - yg.reduce(0.0) { $0 + Double($1) }) / Double(n))
    }

    /// 3 × 3 minus 7 × 7 box blur (separable, clamped borders).
    static func bandPass(_ v: [Float], _ w: Int, _ h: Int) -> [Float] {
        func box(_ src: [Float], _ r: Int) -> [Float] {
            var tmp = [Float](repeating: 0, count: src.count), out = tmp
            let k = Float(2 * r + 1)
            for y in 0..<h { for x in 0..<w {
                var s: Float = 0
                for d in -r...r { s += src[y * w + min(w - 1, max(0, x + d))] }
                tmp[y * w + x] = s / k
            } }
            for y in 0..<h { for x in 0..<w {
                var s: Float = 0
                for d in -r...r { s += tmp[min(h - 1, max(0, y + d)) * w + x] }
                out[y * w + x] = s / k
            } }
            return out
        }
        let a = box(v, 1), b = box(v, 3)
        return zip(a, b).map { $0 - $1 }
    }

    static func writePNG(_ image: UnsafePointer<SIMD4<Float>>, width: Int, height: Int, to url: URL) {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for p in 0..<(width * height) {
            for c in 0..<3 { bytes[4 * p + c] = UInt8((min(1, max(0, image[p][c])) * 255).rounded()) }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}
