// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// Trains a 3DGS model from a saved scan on the Mac GPU with the app's Metal trainer, for
// regression and ablation experiments. Reads the scan only; writes nothing unless --out is given.
//
// xcrun -sdk macosx metal -std=metal3.1 -ffast-math arkit-3dgs-scanner/Training/*.metal -o /tmp/gs.metallib
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,ExportManager,TrainingFrameSelector}.swift \
//   arkit-3dgs-scanner/History/ScanLibrary.swift arkit-3dgs-scanner/Training/*.swift \
//   tools/train_gaussians.swift -o /tmp/train_gaussians
// /tmp/train_gaussians /tmp/gs.metallib SCAN [--iterations N] [--long-edge PX] [--max-gaussians N]
//   [--sh D] [--holdout N] [--no-ppisp] [--no-pose] [--no-mip] [--budget-mb MB] [--out DIR]
import Foundation
import Metal
import simd

@main struct TrainGaussians {
    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            print("Usage: train_gaussians METALLIB SCAN [--iterations N] [--long-edge PX] [--max-gaussians N] [--sh D] [--holdout N] [--no-ppisp] [--no-pose] [--no-mip] [--budget-mb MB] [--out DIR] [--save-model DIR] [--enhance-from MODEL_DIR]")
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
        var seedJitter = true
        var excludeIDs: Set<Int> = []
        var holdOutSegment = 0.0, fullResolution = false
        var saveModel: URL?, enhanceFrom: URL?
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--iterations": config.iterations = Int(args.removeFirst())!
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
            case "--no-depth-seeds": config.depthSeeds = false
            case "--no-hole-fill": config.holeFilling = false
            case "--depth-loss": config.depthLoss = Double(args.removeFirst())!
            case "--holdout-segment": holdOutSegment = Double(args.removeFirst())!
            case "--eval-full-res": fullResolution = true
            case "--save-model": saveModel = URL(fileURLWithPath: args.removeFirst())
            case "--enhance-from": enhanceFrom = URL(fileURLWithPath: args.removeFirst())
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
                                                  maxPoints: 250_000, depthSeedLimit: config.depthSeedLimit, holdOutSegment: holdOutSegment)
        print(String(format: "seeds: %d points (depth seeds %@, limit %d) in %.1f s", dataset.points.count,
                     config.usesDepthSeeds ? "on" : "off", config.depthSeedLimit, Date().timeIntervalSince(seedStart)))
        dataset = try perturbed(dataset, scan: scan, poseFile: poseFile, noise: initNoise, keep: initKeep, random: initRandom,
                                latticeJitter: latticeJitter)
        if !excludeIDs.isEmpty {
            // Experiment: drop these photos from training (held-out views are kept).
            let frames = dataset.frames.filter { $0.isValidation || !excludeIDs.contains($0.id) }
            print("excluded \(dataset.frames.count - frames.count) training photos: \(excludeIDs.sorted())")
            dataset = TrainingDataset(directory: dataset.directory, frames: frames, points: dataset.points, width: dataset.width, height: dataset.height)
        }
        print("dataset: \(dataset.frames.count) frames (\(dataset.validationFrames.count) validation), \(dataset.points.count) points, \(dataset.width)x\(dataset.height), prepared in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        let budget = (config.memoryBudgetMB.map { $0 << 20 }) ?? TrainingMemoryPlan.automaticBudget()
        let plan = try TrainingMemoryPlan.fit(width: dataset.width, height: dataset.height, shDegree: config.shDegree,
                                              requestedGaussians: config.maxGaussians, budgetBytes: budget)
        print("plan: \(plan.summary)")
        let metal = try GaussianMetal(libraryURL: library)
        let trainer = try GaussianTrainer(configuration: config, dataset: dataset, plan: plan, metal: metal)
        if let poseLR { trainer.poseLearningRate = poseLR }
        trainer.seedJitter = seedJitter
        print(String(format: "pose learning rate %.1e, seed jitter %@, depth loss %.2f", trainer.poseLearningRate,
                     seedJitter ? "on" : "off", config.depthLossWeight))
        if let enhanceFrom { try trainer.initializeModel(fromSaved: enhanceFrom) } else { try trainer.initializeModel() }
        if enhanceFrom != nil {
            print(String(format: "enhancement start: validation PSNR %.3f (unaligned)", try trainer.evaluate().psnr))
        }
        print("initial Gaussians \(trainer.model.activeCount), median size \(trainer.strategy.bounds.medianSize) m, footprint \(TrainingMemoryPlan.footprintBytes >> 20) MB")
        let start = Date()
        var window: [Double] = [], psnrWindow: [Double] = [], peak = 0, skipped = 0
        while trainer.iteration < config.iterations {
            let r = try trainer.step()
            if r.skipped { skipped += 1; continue }
            window.append(r.loss); psnrWindow.append(r.psnr)
            if let refine = r.refine, trainer.iteration % (trainer.strategy.schedule.refineEvery * 10) == 0 {
                print("  refine @\(r.iteration): pruned \(refine.pruned) replaced \(refine.replaced) oversize \(refine.oversize) grown \(refine.grown) holes \(refine.holes) (total \(trainer.holeSeedsAdded)) live \(refine.live)")
            }
            if ProcessInfo.processInfo.environment["GS_VERBOSE"] != nil { print("step \(r.iteration) \(String(format: "%.1f", r.seconds * 1000)) ms loss \(r.loss) M? gaussians \(r.gaussians)") }
            if r.iteration % 500 == 0 || r.iteration == config.iterations {
                peak = max(peak, TrainingMemoryPlan.footprintBytes)
                let elapsed = Date().timeIntervalSince(start)
                print(String(format: "it %5d  loss %.4f  train PSNR %.2f  Gaussians %7d  %.1f ms/it  footprint %d MB",
                             r.iteration, window.reduce(0, +) / Double(window.count), psnrWindow.reduce(0, +) / Double(psnrWindow.count),
                             r.gaussians, elapsed / Double(max(1, r.iteration - config.startIteration)) * 1000, TrainingMemoryPlan.footprintBytes >> 20))
                window.removeAll(); psnrWindow.removeAll()
            }
        }
        let seconds = Date().timeIntervalSince(start)
        for (k, v) in trainer.profile.sorted(by: { $0.key < $1.key }) {
            let n = Double(max(1, config.runIterations))
            print(String(format: "  profile %@: %.2f per iteration", k, k == "intersections" ? v / n : v / n * 1000))
        }
        let eval = try trainer.evaluate()
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
            if holdOutSegment > 0 { try reportHeldOutViews(trainer) }
            if config.captureMotion != nil {
                let still = try trainer.evaluate(alignSteps: alignSteps, captureMotion: false)
                print(String(format: "validation aligned, rendered without capture motion: PSNR %.3f SSIM %.4f", still.psnr, still.ssim))
            }
        }
        print(String(format: "done: %d iterations in %.1f s (%.1f ms/it), skipped %d, validation PSNR %.3f SSIM %.4f over %d views, peak footprint %d MB",
                     config.runIterations, seconds, seconds / Double(max(1, config.runIterations)) * 1000, skipped, eval.psnr, eval.ssim, eval.count, peak >> 20))
        if config.ppisp {
            let s = trainer.ppisp.summary
            print(String(format: "PPISP: exposure %.2f..%.2f EV, corner vignetting %.3f", s.minEV, s.maxEV, s.cornerVignetting))
        }
        if config.poseOptimization {
            let rot = trainer.poses.map(\.rotationDegrees).sorted(), trans = trainer.poses.map { $0.translationMeters * 1000 }.sorted()
            print(String(format: "pose corrections: median %.3f° / %.2f mm, max %.3f° / %.2f mm", rot[rot.count / 2], trans[trans.count / 2], rot.last!, trans.last!))
        }
        if perFrame { try reportPerFrame(trainer) }
        try reportCoverage(trainer)
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true); _ = out }
        if let saveModel {
            try FileManager.default.createDirectory(at: saveModel, withIntermediateDirectories: true)
            try GaussianTrainingSession.writeModelFiles(trainer, into: saveModel, validation: eval.count > 0 ? eval.psnr : nil,
                                                        elapsedSeconds: seconds, peakFootprintMB: peak >> 20)
            print("saved model: \(saveModel.path)")
        }
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
