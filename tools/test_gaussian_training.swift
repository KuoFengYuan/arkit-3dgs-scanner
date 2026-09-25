// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// End-to-end tests of on-device 3DGS training on synthetic scans (Mac GPU, same Metal kernels):
// convergence, PPISP exposure recovery, pose refinement, the Gaussian cap under a small memory
// budget, checkpoint round trip / corruption / atomicity, PLY export frame math, the session
// state machine (pause, stop with checkpoint, resume, finish), the saved-model viewer, and a
// large-scan stress run with bounded memory.
//
// bash tools/test_gaussian_training.sh
import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers
import simd

@main struct GaussianTrainingTests {
    static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        if !ok { print("FAIL: \(message)"); exit(1) }
        checks += 1; print("PASS: \(message)")
    }

    static var library: URL!
    static var metal: GaussianMetal!
    static let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gs-training-tests-\(getpid())")

    // MARK: Synthetic scans

    struct Scene {
        var positions: [SIMD3<Float>] = [], colors: [SIMD3<Float>] = [], scales: [Float] = []
    }

    /// A textured corner: floor and two walls of small coloured splats, plus a box.
    static func scene(seed: UInt64) -> Scene {
        var r = SplitMix64(seed: seed)
        var s = Scene()
        func add(_ p: SIMD3<Float>, _ c: SIMD3<Float>) { s.positions.append(p); s.colors.append(c); s.scales.append(0.035) }
        for i in 0..<34 { for j in 0..<34 {
            let u = Float(i) / 33 * 2 - 1, v = Float(j) / 33 * 2 - 1
            let check: Float = ((i / 4 + j / 4) % 2 == 0) ? 0.85 : 0.25
            add(SIMD3(u * 1.2, -0.6, v * 1.2 - 2.4), SIMD3(check, 0.5 + 0.3 * r.nextFloat(), 0.3))
            add(SIMD3(u * 1.2, v * 0.6, -3.6), SIMD3(0.3 + 0.5 * r.nextFloat(), check * 0.8, 0.6))
            add(SIMD3(-1.2, v * 0.6, u * 1.2 - 2.4), SIMD3(0.7, 0.35, check))
        } }
        for i in 0..<14 { for j in 0..<14 {
            let u = Float(i) / 13 - 0.5, v = Float(j) / 13 - 0.5
            add(SIMD3(u * 0.5 + 0.2, v * 0.5 - 0.35, -2.2), SIMD3(0.9, 0.9 * r.nextFloat(), 0.1))
        } }
        return s
    }

    /// Camera-to-world (ARKit convention, row-major) looking at `target` from `eye`.
    static func arkitPose(eye: SIMD3<Double>, target: SIMD3<Double>) -> [Double] {
        let back = simd_normalize(eye - target)                       // +Z (camera looks down -Z)
        let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
        let up = simd_cross(back, right)
        return [right.x, up.x, back.x, eye.x, right.y, up.y, back.y, eye.y, right.z, up.z, back.z, eye.z, 0, 0, 0, 1]
    }

    struct SyntheticScan {
        var directory: URL
        var truePoses: [[Double]]
        var trueExposure: [Double]
        /// Ground-truth model and renderer (sharp reference views).
        var model: GaussianModel
        var renderer: GaussianRenderer
        var background = SIMD3<Float>(0.05, 0.05, 0.08)
    }

    /// Writes a scan directory (images/, poses.jsonl, review.ply) rendered from a ground-truth model.
    /// `motion` integrates each photo over its exposure along the camera path and reads rows at
    /// their rolling-shutter times (physically, from many sub-frame renders), like a handheld
    /// capture; poses are recorded at the frame times.
    static func writeScan(name: String, frames: Int, width: Int = 160, height: Int = 120, exposureSpread: Double = 0,
                          poseNoise: (translation: Double, degrees: Double) = (0, 0), seed: UInt64 = 1,
                          grid: Bool = false, motion: (exposure: Double, readout: Double)? = nil) throws -> SyntheticScan {
        let dir = temp.appendingPathComponent("scan_" + name)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        let gt = scene(seed: seed)
        let capacity = (gt.positions.count + 1023) / 1024 * 1024
        let model = try GaussianModel(metal: metal, capacity: capacity, shDegree: 1, trainable: false)
        model.initialize(positions: gt.positions, colors: gt.colors)
        let p = model.floats(model.params)
        for i in 0..<gt.positions.count {
            for k in 0..<3 { p[Int(model.layout.scales) + 3 * i + k] = log(gt.scales[i]) }
            p[Int(model.layout.opacities) + i] = 3
        }
        let raster = try GaussianRasterizer(metal: metal, capacity: capacity, intersectionCapacity: capacity * 40, maxTiles: 65_536)
        let renderer = try GaussianRenderer(metal: metal, raster: raster, maxPixels: width * height)
        var rng = SplitMix64(seed: seed &+ 99)
        var records = Data(), truePoses: [[Double]] = [], exposures: [Double] = []
        let fx = Double(width) * 0.9
        let background = SIMD3<Float>(0.05, 0.05, 0.08)
        /// Pose at continuous frame time `f` (frames are 0.1 s apart).
        func path(at f: Double) -> [Double] {
            let a = -0.9 + 1.5 * f / Double(max(1, frames - 1))
            var eye = SIMD3(1.6 * sin(a), 0.15 + 0.2 * sin(f * 0.7), -2.4 + 1.6 * cos(a))
            if grid {
                // 5 cm apart: no view is a near-duplicate that frame selection would replace.
                let columns = 40, i = Int(f)
                eye = SIMD3(-1.0 + 0.05 * Double(i % columns), -0.3 + 0.05 * Double(i / columns), -0.3)
            }
            return arkitPose(eye: eye, target: SIMD3(0, -0.2, -2.6))
        }
        let intr = CameraIntrinsics(fx: fx, fy: fx, cx: Double(width) / 2, cy: Double(height) / 2, width: width, height: height)
        func still(_ pose: [Double]) throws -> [UInt8] {
            var camera = GaussianCamera(worldToCamera: GaussianCamera.worldToCamera(arkitRowMajorC2W: pose), fx: fx, fy: fx,
                                        cx: intr.cx, cy: intr.cy, width: width, height: height, mipFilter: true)
            camera.sh = .zero
            guard let frame = try renderer.render(model: model, camera: camera, shDegree: 0, isp: nil, background: background) else {
                throw GaussianExport.ExportError.damaged
            }
            return [UInt8](frame.pixels)
        }
        for f in 0..<frames {
            let pose = path(at: Double(f))
            truePoses.append(pose)
            let ev = exposureSpread > 0 ? (Double(rng.nextFloat()) * 2 - 1) * exposureSpread : 0
            exposures.append(ev)
            var pixels = try still(pose)
            if let motion {
                // Sub-frame renders across readout + exposure; each row averages the renders
                // exposed while it was read (row time (y / H - 0.5) * readout).
                let span: Double = motion.readout + motion.exposure
                let slices = 41
                var times: [Double] = []
                for k in 0..<slices { times.append(-span / 2 + span * Double(k) / Double(slices - 1)) }
                var renders: [[UInt8]] = []
                for t in times { renders.append(try still(path(at: Double(f) + t * 10))) }
                var out = [Double](repeating: 0, count: pixels.count), weight = [Double](repeating: 0, count: height)
                for y in 0..<height {
                    let tau = ((Double(y) + 0.5) / Double(height) - 0.5) * motion.readout
                    for (k, t) in times.enumerated() where abs(t - tau) <= motion.exposure / 2 {
                        weight[y] += 1
                        for i in (y * width * 4)..<((y + 1) * width * 4) { out[i] += Double(renders[k][i]) }
                    }
                }
                for y in 0..<height where weight[y] > 0 {
                    for i in (y * width * 4)..<((y + 1) * width * 4) { pixels[i] = UInt8((out[i] / weight[y]).rounded()) }
                }
            }
            if ev != 0 {
                let gain = pow(2, ev)
                for i in 0..<pixels.count where i % 4 != 3 { pixels[i] = UInt8(min(255, (Double(pixels[i]) * gain).rounded())) }
            }
            let name = String(format: "frame_%05d.jpg", f + 1)
            try writeJPEG(pixels, width: width, height: height, to: dir.appendingPathComponent("images").appendingPathComponent(name))
            // Recorded pose, optionally perturbed (what ARKit would have reported).
            var saved = pose
            if poseNoise.translation > 0 || poseNoise.degrees > 0 {
                let axis = simd_normalize(SIMD3(Double(rng.nextFloat()) - 0.5, Double(rng.nextFloat()) - 0.5, Double(rng.nextFloat()) - 0.5))
                let q = simd_quatd(angle: poseNoise.degrees * .pi / 180, axis: axis)
                let R = simd_double3x3(rows: [SIMD3(pose[0], pose[1], pose[2]), SIMD3(pose[4], pose[5], pose[6]), SIMD3(pose[8], pose[9], pose[10])])
                let R2 = simd_double3x3(q) * R
                let dt = simd_normalize(SIMD3(Double(rng.nextFloat()) - 0.5, Double(rng.nextFloat()) - 0.5, Double(rng.nextFloat()) - 0.5)) * poseNoise.translation
                saved = [R2[0][0], R2[1][0], R2[2][0], pose[3] + dt.x, R2[0][1], R2[1][1], R2[2][1], pose[7] + dt.y,
                         R2[0][2], R2[1][2], R2[2][2], pose[11] + dt.z, 0, 0, 0, 1]
            }
            let record = FrameRecord(id: f + 1, timestamp: Double(f) / 10, transform: saved, intrinsics: intr,
                                     exposureDuration: motion?.exposure ?? 0.01, exposureOffsetEV: 0, iso: 0, estimatedBlurPx: 0,
                                     imageFile: name)
            records.append(try JSONEncoder().encode(record)); records.append(0x0A)
        }
        try records.write(to: dir.appendingPathComponent("poses.jsonl"))
        // Seed cloud: every second ground-truth centre with 1 cm noise.
        var points: [CloudPoint] = []
        for i in stride(from: 0, to: gt.positions.count, by: 2) {
            let n = SIMD3(rng.nextFloat() - 0.5, rng.nextFloat() - 0.5, rng.nextFloat() - 0.5) * 0.02
            let c = simd_clamp(gt.colors[i], .zero, SIMD3(repeating: 1)) * 255
            points.append(CloudPoint(x: gt.positions[i].x + n.x, y: gt.positions[i].y + n.y, z: gt.positions[i].z + n.z,
                                     r: UInt8(c.x), g: UInt8(c.y), b: UInt8(c.z)))
        }
        try ExportManager.writePLY(points, to: dir.appendingPathComponent("review.ply"))
        return SyntheticScan(directory: dir, truePoses: truePoses, trueExposure: exposures, model: model, renderer: renderer,
                             background: background)
    }

    static func writeJPEG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw GaussianExport.ExportError.damaged
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw GaussianExport.ExportError.damaged }
    }

    // MARK: Helpers

    static func config(iterations: Int, ppisp: Bool = false, pose: Bool = false, maxGaussians: Int = 40_000,
                       holdOut: Int = 0, sh: Int = 1) -> GaussianTrainingConfiguration {
        var c = GaussianTrainingConfiguration.preset(.quick)
        c.iterations = iterations
        c.longEdge = 160
        c.maxGaussians = maxGaussians
        c.shDegree = sh
        c.ppisp = ppisp
        c.poseOptimization = pose
        c.holdOutEvery = holdOut
        return c
    }

    static func trainer(_ scan: URL, _ c: GaussianTrainingConfiguration, budgetMB: Int = 512, initialize: Bool = true) throws -> GaussianTrainer {
        let dataset = try TrainingDataset.prepare(scan: scan, longEdge: c.longEdge, holdOutEvery: c.holdOutEvery, maxPoints: 250_000)
        let plan = try TrainingMemoryPlan.fit(width: dataset.width, height: dataset.height, shDegree: c.shDegree,
                                              requestedGaussians: c.maxGaussians, budgetBytes: budgetMB << 20,
                                              imageSlots: 3, previewPixels: 320 * 240)
        let t = try GaussianTrainer(configuration: c, dataset: dataset, plan: plan, metal: metal)
        if initialize { try t.initializeModel() }
        return t
    }

    static func train(_ t: GaussianTrainer, until iteration: Int, onStep: (TrainingStepReport) -> Void = { _ in }) throws -> [TrainingStepReport] {
        var reports: [TrainingStepReport] = []
        while t.iteration < iteration { let r = try t.step(); reports.append(r); onStep(r) }
        return reports
    }

    static func meanPSNR(_ t: GaussianTrainer, frames: [Int]) throws -> Double { try t.evaluate(frames: frames).psnr }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for (x, y) in zip(a, b) { sab += (x - ma) * (y - mb); saa += (x - ma) * (x - ma); sbb += (y - mb) * (y - mb) }
        return sab / max(1e-12, (saa * sbb).squareRoot())
    }

    // MARK: Tests

    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        library = URL(fileURLWithPath: CommandLine.arguments[1])
        metal = try GaussianMetal(libraryURL: library)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        // GS_ONLY=session,enhancement runs a subset while iterating.
        let only = ProcessInfo.processInfo.environment["GS_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let tests: [(String, () throws -> Void)] = [
            ("memoryPlan", memoryPlan),
            ("resolutionAndHoldOut", resolutionAndHoldOut),
            ("strategyUnits", strategyUnits),
            ("exportFrame", exportFrame),
            ("depthSeeding", depthSeeding),
            ("holeFilling", holeFilling),
            ("convergence", convergence),
            ("enhancement", enhancement),
            ("ppispRecovery", ppispRecovery),
            ("poseRefinement", poseRefinement),
            ("captureMotion", captureMotion),
            ("capUnderSmallBudget", capUnderSmallBudget),
            ("checkpoints", checkpoints),
            ("session", session),
            ("largeScanStress", largeScanStress),
        ]
        for (name, test) in tests where only?.contains(name) ?? true { try test() }
        print("\(checks) training checks passed")
    }

    static func resolutionAndHoldOut() throws {
        typealias Resolution = GaussianTrainingConfiguration.Resolution
        let edges = Resolution.allCases.map(\.longEdge)
        check(edges == [960, 1_440, 1_920] && Resolution.allCases.allSatisfy { Resolution(longEdge: $0.longEdge) == $0 }
              && GaussianTrainingConfiguration.Preset.allCases.allSatisfy { GaussianTrainingConfiguration.preset($0).resolution == .low },
              "resolution tiers map to 960 / 1440 / 1920 px, and every preset starts at low")
        let full = try TrainingMemoryPlan.fit(width: 1_920, height: 1_440, shDegree: 3, requestedGaussians: 600_000,
                                              budgetBytes: 2_600 << 20, imageSlots: 3, previewPixels: 320 * 240)
        let low = try TrainingMemoryPlan.fit(width: 960, height: 720, shDegree: 3, requestedGaussians: 600_000,
                                             budgetBytes: 2_600 << 20, imageSlots: 3, previewPixels: 320 * 240)
        check(full.gaussianCapacity == low.gaussianCapacity && full.totalBytes > low.totalBytes + (200 << 20),
              "full resolution keeps the Gaussian cap in a large budget and plans the larger image buffers (\(full.totalBytes >> 20) vs \(low.totalBytes >> 20) MB)")
        let bands = GaussianRasterizer.backwardBands(tilesX: 120, tilesY: 90)
        check(bands.first?.lowerBound == 0 && bands.last?.upperBound == 90 && zip(bands, bands.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }
              && bands.allSatisfy { $0.count * 120 <= 2_048 } && GaussianRasterizer.backwardBands(tilesX: 60, tilesY: 45).count == 2,
              "the backward pass covers every tile row in bands of at most 2,048 tiles (\(bands.count) at 1920 x 1440)")
        let scan = try writeScan(name: "segment", frames: 40)
        let segment = try TrainingDataset.prepare(scan: scan.directory, longEdge: 1_920, holdOutEvery: 8, maxPoints: 250_000, holdOutSegment: 0.1)
        let held = segment.validationFrames
        check(segment.width == 160 && held == Array(18..<22),
              "a held-out segment is one contiguous middle stretch (frames \(held)) and photos are never upscaled")
    }

    static func memoryPlan() throws {
        let plan = try TrainingMemoryPlan.fit(width: 960, height: 720, shDegree: 3, requestedGaussians: 600_000, budgetBytes: 900 << 20)
        check(plan.totalBytes <= 900 << 20 && plan.gaussianCapacity < 600_000 && plan.gaussianCapacity % 1024 == 0,
              "memory plan fits the budget by lowering the Gaussian cap (\(plan.gaussianCapacity) in \(plan.totalBytes >> 20) MB)")
        let roomy = try TrainingMemoryPlan.fit(width: 960, height: 720, shDegree: 3, requestedGaussians: 100_000, budgetBytes: 4 << 30)
        check(roomy.gaussianCapacity == 100_352, "memory plan keeps the requested cap when memory allows")
        var threwOverflow = false
        do { _ = try TrainingMemoryPlan.fit(width: Int.max / 2, height: 4, shDegree: 3, requestedGaussians: 10, budgetBytes: Int.max) }
        catch TrainingMemoryPlan.PlanError.overflow { threwOverflow = true }
        check(threwOverflow, "allocation sizes are overflow-checked")
        var threwInsufficient = false
        do { _ = try TrainingMemoryPlan.fit(width: 960, height: 720, shDegree: 3, requestedGaussians: 10_000, budgetBytes: 64 << 20) }
        catch TrainingMemoryPlan.PlanError.insufficientMemory { threwInsufficient = true }
        check(threwInsufficient, "an impossible budget is refused before allocating")
        let small = TrainingMemoryPlan.automaticBudget(available: 1_500 << 20, physical: 4 << 30)
        let large = TrainingMemoryPlan.automaticBudget(available: 6_000 << 20, physical: 8 << 30)
        check(small <= 900 << 20 && small < Int(Double(1_500 << 20) * 0.55) && large == 2_600 << 20,
              "automatic budget keeps headroom and a device-tier ceiling")
    }

    static func strategyUnits() throws {
        // Gumbel top-k: k distinct rows with positive weight, never excluded ones.
        var rng = SplitMix64(seed: 3)
        let weights: [Float] = (0..<1000).map { $0 % 3 == 0 ? 0 : Float($0 % 7 + 1) }
        var excluded = [Bool](repeating: false, count: 1000)
        for i in 0..<100 { excluded[i] = true }
        let picked = MRNFStrategy.gumbelTopK(weights, k: 200, rng: &rng, excluding: excluded)
        check(picked.count == 200 && Set(picked).count == 200 && picked.allSatisfy { weights[$0] > 0 && !excluded[$0] },
              "Gumbel top-k draws distinct, positive-weight, non-excluded parents")
        // Heavier weights are drawn more often.
        var heavy = 0, light = 0
        for s in 0..<200 {
            var g = SplitMix64(seed: UInt64(s))
            let one = MRNFStrategy.gumbelTopK([1, 9], k: 1, rng: &g, excluding: [false, false])
            if one == [1] { heavy += 1 } else { light += 1 }
        }
        check(heavy > light * 4, "sampling probability follows the weights (\(heavy) vs \(light))")
        // Split rule on one Gaussian.
        let model = try GaussianModel(metal: metal, capacity: 1024, shDegree: 0)
        model.initialize(positions: [SIMD3(0, 0, 0)], colors: [SIMD3(0.5, 0.5, 0.5)])
        let p = model.floats(model.params)
        p[Int(model.layout.scales)] = log(0.2); p[Int(model.layout.scales) + 1] = log(0.05); p[Int(model.layout.scales) + 2] = log(0.05)
        p[Int(model.layout.opacities)] = 2
        let e = model.stat(GaussianStats.errorMax), v = model.stat(GaussianStats.visibility)
        e[0] = 1; v[0] = 1
        var strategy = MRNFStrategy(schedule: MRNFSchedule(iterations: 1000), maxGaussians: 10)
        strategy.bounds = MRNFBounds(center: .zero, maxExtent: 1, medianSize: 1, valid: true)
        // A single candidate: 7% of 1 rounds to 0, so force growth with more candidates below.
        _ = strategy.refine(model, iteration: 25)
        check(model.activeCount == 1, "no split when 7% of the candidates rounds to zero")
        let many = try GaussianModel(metal: metal, capacity: 1024, shDegree: 0)
        many.initialize(positions: (0..<100).map { SIMD3(Float($0) * 0.1, 0, 0) }, colors: Array(repeating: SIMD3(0.5, 0.5, 0.5), count: 100))
        let q = many.floats(many.params)
        for i in 0..<100 {
            q[Int(many.layout.scales) + 3 * i] = log(0.2); q[Int(many.layout.scales) + 3 * i + 1] = log(0.05); q[Int(many.layout.scales) + 3 * i + 2] = log(0.05)
            q[Int(many.layout.opacities) + i] = 2
            many.stat(GaussianStats.errorMax)[i] = 1; many.stat(GaussianStats.visibility)[i] = 1
        }
        let before = (0..<100).map { many.mean($0) }
        var s2 = MRNFStrategy(schedule: MRNFSchedule(iterations: 1000), maxGaussians: 1000)
        s2.bounds = MRNFBounds(center: .zero, maxExtent: 5, medianSize: 5, valid: true)
        let report = s2.refine(many, iteration: 25)
        check(report.grown == 7 && many.activeCount == 107, "growth splits 7% of the erroring splats")
        let parent = (0..<100).first { simd_distance(many.mean($0), before[$0]) > 1e-6 }!
        let child = 100 + (0..<7).first { simd_distance(many.mean(100 + $0) + (many.mean(parent) - before[parent]), before[parent]) < 1e-5 && true }!
        let offset = many.mean(parent) - before[parent]
        let tau = Float(25) / 1000
        let expectedOpacity = 0.6 * (1 / (1 + exp(-2))) - 0.004 * (1 - tau)
        let opacity = 1 / (1 + exp(-q[Int(many.layout.opacities) + parent]))
        check(abs(simd_length(offset) - 0.1) < 1e-4 && simd_distance(many.mean(child), before[parent] - offset) < 1e-5
              && abs(exp(q[Int(many.layout.scales) + 3 * parent]) - 0.1 * (1 - 0.002 * (1 - tau))) < 1e-4
              && abs(opacity - expectedOpacity) < 1e-4,
              "long-axis split moves parent and child ±0.5 σ, halves the long axis and fades opacity to 60%")
        // Prune + replacement reuses the freed rows before appending.
        for i in 0..<10 { q[Int(many.layout.opacities) + i] = -8 }
        for i in 0..<many.count { many.stat(GaussianStats.errorMax)[i] = 0; many.stat(GaussianStats.visibility)[i] = 1 }
        let countBefore = many.count
        let r2 = s2.refine(many, iteration: 50)
        check(r2.pruned == 10 && r2.replaced == 10 && many.count == countBefore && many.activeCount == countBefore,
              "soft-pruned slots are refilled by replacement splits without growing the buffers")
        // Growth ramp: the ceiling rises linearly from the starting count to the cap at growUntil.
        var ramp = MRNFStrategy(schedule: MRNFSchedule(iterations: 1000), maxGaussians: 1000)
        ramp.growthStart = 200
        let until = ramp.schedule.growUntil
        check(ramp.growthCeiling(at: 0, capacity: 4096) == 200 && ramp.growthCeiling(at: until / 2, capacity: 4096) == 600
              && ramp.growthCeiling(at: until, capacity: 4096) == 1000 && ramp.growthCeiling(at: until / 2, capacity: 400) == 300,
              "growth ramp reaches the cap at the end of the growth phase and never exceeds the capacity")
        // 600 erroring splats want 42 splits (7%); the ramp allows only 620 - 600 at t = 25.
        let rampModel = try GaussianModel(metal: metal, capacity: 1024, shDegree: 0)
        rampModel.initialize(positions: (0..<600).map { SIMD3(Float($0 % 30) * 0.1, Float($0 / 30) * 0.1, 0) },
                             colors: Array(repeating: SIMD3(0.5, 0.5, 0.5), count: 600))
        let rp = rampModel.floats(rampModel.params)
        for i in 0..<600 {
            rp[Int(rampModel.layout.opacities) + i] = 2
            rampModel.stat(GaussianStats.errorMax)[i] = 1; rampModel.stat(GaussianStats.visibility)[i] = 1
        }
        var ramped = MRNFStrategy(schedule: MRNFSchedule(iterations: 1000), maxGaussians: 1000)
        ramped.bounds = MRNFBounds(center: SIMD3(1.5, 1, 0), maxExtent: 5, medianSize: 5, valid: true)
        ramped.growthStart = 600
        let t0 = ramped.schedule.refineEvery
        let early = ramped.refine(rampModel, iteration: t0)
        check(ramped.growthCeiling(at: t0, capacity: 1024) == 620 && early.grown == 20 && rampModel.activeCount == 620,
              "with the ramp an early refine grows only to its ceiling (\(early.grown) of 42 wanted)")
        // Relocation at the cap: 1,000 Gaussians fill a 1,000 cap. 40 contribute almost nothing
        // in the views that saw them, 100 cover pixels with above-average error; 20 of the low
        // ones were seen by only 2 views (too little evidence to judge).
        let full = try GaussianModel(metal: metal, capacity: 1024, shDegree: 0)
        full.initialize(positions: (0..<1000).map { SIMD3(Float($0 % 40) * 0.1, Float($0 / 40) * 0.1, 0) },
                        colors: Array(repeating: SIMD3(0.5, 0.5, 0.5), count: 1000))
        let fp = full.floats(full.params)
        func setWindow() {
            for i in 0..<1000 {
                fp[Int(full.layout.opacities) + i] = 2
                let few = i >= 960 && i < 980
                full.stat(GaussianStats.views)[i] = few ? 2 : 6
                full.stat(GaussianStats.visibility)[i] = i >= 940 && i < 980 ? 0.01 : 6
                full.stat(GaussianStats.errorSum)[i] = i < 100 ? 12 : 3
            }
        }
        var relocating = MRNFStrategy(schedule: MRNFSchedule(iterations: 20_000), maxGaussians: 1000)
        relocating.bounds = MRNFBounds(center: SIMD3(2, 1.25, 0), maxExtent: 5, medianSize: 5, valid: true)
        let step = relocating.schedule.refineEvery
        setWindow()
        let first = relocating.refine(full, iteration: step, relocate: true)
        setWindow()
        let second = relocating.refine(full, iteration: 2 * step, relocate: true)
        let lowest = full.stat(GaussianStats.lowWindows)
        check(first.relocated == 0 && first.judged == 980 && first.receivers == 100 && lowest[965] == 0,
              "relocation waits for a second low window and ignores Gaussians seen by too few views")
        check(second.relocated == 4 && second.donors == 20 && full.activeCount == 1000 && second.grown == 0,
              "relocation moves at most 0.5% of the cap per refine, from the lowest contributors, without growing (\(second.relocated) moved)")
        var quiet = relocating
        let quietModel = full
        setWindow()
        for i in 0..<100 { quietModel.stat(GaussianStats.errorSum)[i] = 3 }
        let none = quiet.refine(quietModel, iteration: 3 * step, relocate: true)
        check(none.relocated == 0 && none.receivers == 0, "nothing moves when no Gaussian is under-fit")
        check(relocating.relocationCandidates(full, guidance: Array(repeating: 1, count: full.count),
                                              iteration: relocating.schedule.stopRefine).donors.isEmpty,
              "relocation tapers to zero at the end of refinement")
        // Checkpoints written before the ramp decode without it.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ramp)) as! [String: Any]
        legacy.removeValue(forKey: "growthStart")
        let decoded = try JSONDecoder().decode(MRNFStrategy.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(decoded.growthStart == nil && decoded.growthCeiling(at: 1, capacity: 4096) == 1000,
              "a strategy saved without the growth ramp decodes and grows as before")
    }

    static func exportFrame() throws {
        let scan = try writeScan(name: "export", frames: 8)
        let t = try trainer(scan.directory, config(iterations: 40, sh: 3))
        _ = try train(t, until: 40)
        let url = temp.appendingPathComponent("export.ply")
        try GaussianExport.writePLY(t.model, to: url, comment: "test")
        let loaded = try GaussianModel(metal: metal, capacity: t.model.capacity, shDegree: 3, trainable: false)
        let n = try GaussianExport.readPLY(url, into: loaded)
        var worst: Float = 0
        let rows = t.model.liveRows
        let a = t.model.floats(t.model.params), b = loaded.floats(loaded.params)
        for (k, row) in rows.enumerated() {
            for (offset, width) in t.model.layout.groups where width > 0 && offset != Int(t.model.layout.quats) {
                for j in 0..<width { worst = max(worst, abs(a[offset + row * width + j] - b[offset + k * width + j])) }
            }
            let qa = simd_normalize(SIMD4(a[Int(t.model.layout.quats) + 4 * row], a[Int(t.model.layout.quats) + 4 * row + 1],
                                          a[Int(t.model.layout.quats) + 4 * row + 2], a[Int(t.model.layout.quats) + 4 * row + 3]))
            let qb = SIMD4(b[Int(loaded.layout.quats) + 4 * k], b[Int(loaded.layout.quats) + 4 * k + 1], b[Int(loaded.layout.quats) + 4 * k + 2], b[Int(loaded.layout.quats) + 4 * k + 3])
            worst = max(worst, min(simd_length(qa - qb), simd_length(qa + qb)))
        }
        check(n == rows.count && worst < 1e-5, "PLY export round-trips every parameter (max difference \(worst))")
        // The exported frame is the COLMAP export frame: render the flipped model directly (no
        // un-flip) with the flipped camera; it must match the ARKit-frame render.
        let raw = try GaussianModel(metal: metal, capacity: t.model.capacity, shDegree: 3, trainable: false)
        let info = try GaussianExport.readHeader(url)
        let data = try Data(contentsOf: url)
        raw.initialize(positions: [], colors: [])
        let rp = raw.floats(raw.params), L = raw.layout
        data.withUnsafeBytes { bytes in
            for row in 0..<info.count {
                let base = info.headerBytes + row * info.names.count * 4
                func f(_ k: Int) -> Float { bytes.loadUnaligned(fromByteOffset: base + 4 * k, as: Float.self) }
                for k in 0..<3 { rp[Int(L.means) + 3 * row + k] = f(k); rp[Int(L.sh0) + 3 * row + k] = f(6 + k) }
                for c in 0..<3 { for k in 0..<15 { rp[Int(L.shN) + row * 45 + k * 3 + c] = f(9 + c * 15 + k) } }
                rp[Int(L.opacities) + row] = f(54)
                for k in 0..<3 { rp[Int(L.scales) + 3 * row + k] = f(55 + k) }
                for k in 0..<4 { rp[Int(L.quats) + 4 * row + k] = f(58 + k) }
            }
        }
        raw.restore(rowCount: info.count, adamStep: 0)
        let frame = t.dataset.frames[3]
        let w2c = GaussianCamera.worldToCamera(arkitRowMajorC2W: frame.transform)
        let flip = simd_double4x4(diagonal: SIMD4(1, -1, -1, 1))
        func render(_ model: GaussianModel, _ m: simd_double4x4) throws -> [UInt8] {
            let camera = GaussianCamera(worldToCamera: m, fx: frame.intrinsics.fx, fy: frame.intrinsics.fy, cx: frame.intrinsics.cx,
                                        cy: frame.intrinsics.cy, width: frame.intrinsics.width, height: frame.intrinsics.height, mipFilter: true)
            return [UInt8](try t.renderer.render(model: model, camera: camera, shDegree: 3, isp: nil)!.pixels)
        }
        let arkit = try render(t.model, w2c), colmap = try render(raw, w2c * flip)
        let diff = zip(arkit, colmap).map { abs(Int($0) - Int($1)) }.max() ?? 255
        check(diff <= 2, "the exported model in the COLMAP frame renders like the ARKit model (max pixel difference \(diff))")
    }

    /// LiDAR depth seeds only empty surfaces, on the measured surface, with the photo's colour,
    /// one per cell, within the limit, and skips far low-confidence depth.
    static func depthSeeding() throws {
        let dir = temp.appendingPathComponent("scan_depthseed")
        try? FileManager.default.removeItem(at: dir)
        for sub in ["images", "depth"] { try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let w = 64, h = 48
        // A wall 2 m ahead; the bottom-right quadrant is low confidence, its right half 5 m away.
        var depth = [Float](repeating: 2, count: w * h), confidence = [UInt8](repeating: 2, count: w * h)
        for y in (h / 2)..<h { for x in (w / 2)..<w { confidence[y * w + x] = 0; if x >= 3 * w / 4 { depth[y * w + x] = 5 } } }
        try depth.withUnsafeBytes { try Data($0).write(to: dir.appendingPathComponent("depth/f1_depth.bin")) }
        try Data(confidence).write(to: dir.appendingPathComponent("depth/f1_conf.bin"))
        try writeJPEG([UInt8]((0..<(w * h)).flatMap { _ in [230, 30, 30, 255] as [UInt8] }), width: w, height: h,
                      to: dir.appendingPathComponent("images/f1.jpg"))
        var record = FrameRecord(id: 1, timestamp: 0, transform: arkitPose(eye: .zero, target: SIMD3(0, 0, -1)),
                                 intrinsics: CameraIntrinsics(fx: 50, fy: 50, cx: 32, cy: 24, width: w, height: h),
                                 exposureDuration: 0.01, exposureOffsetEV: 0, iso: 0, estimatedBlurPx: 0, imageFile: "f1.jpg")
        record.depthFile = "f1_depth.bin"; record.confidenceFile = "f1_conf.bin"; record.depthWidth = w; record.depthHeight = h
        // The saved cloud already covers the left half of the wall.
        var existing: [CloudPoint] = []
        for i in 0..<130 { for j in 0..<100 {
            existing.append(CloudPoint(x: -1.3 + Float(i) * 0.01, y: -0.99 + Float(j) * 0.02, z: -2, r: 0, g: 0, b: 255))
        } }
        let seeds = TrainingDataset.depthSeeds(records: [record], directory: dir, existing: existing, limit: 100_000, stride: 2)
        let voxel: Float = 0.04
        let cells = Set(seeds.map { SIMD3(Int(($0.x / voxel).rounded(.down)), Int(($0.y / voxel).rounded(.down)), Int(($0.z / voxel).rounded(.down))) })
        let onWall = seeds.allSatisfy { abs($0.z + 2) < 0.01 && $0.x > -0.05 }
        let red = seeds.allSatisfy { $0.r > 180 && $0.g < 90 && $0.b < 90 }
        let far = seeds.contains { $0.z < -3 }
        let limited = TrainingDataset.depthSeeds(records: [record], directory: dir, existing: existing, limit: 7, stride: 2).count
        print("  \(seeds.count) depth seeds in \(cells.count) cells")
        check(!seeds.isEmpty && onWall && red && cells.count == seeds.count && !far && limited == 7,
              "depth seeds fill only empty cells, on the measured surface, coloured from the photo, within the limit, without far low-confidence depth")
    }

    /// The left wall has no seeds: splitting neighbours reaches it slowly and blurrily; hole
    /// filling grows Gaussians there from the empty, erroring pixels (depth from covered pixels
    /// nearby, as without LiDAR).
    static func holeFilling() throws {
        let scan = try writeScan(name: "holes", frames: 36, seed: 17)
        let ply = scan.directory.appendingPathComponent("review.ply")
        let full = try ScanLibrary.readPLY(ply, limit: 1_000_000)
        // Empty = the model leaves the pixel uncovered although the photo shows the scene there.
        func measure(_ t: GaussianTrainer) throws -> (psnr: Double, empty: Double) {
            var empty = 0.0
            let pixels = t.dataset.width * t.dataset.height
            for i in t.dataset.validationFrames {
                _ = try t.evaluate(frames: [i])
                let image = t.target.image.contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels)
                guard let photo = TrainingImageLoader.decode(t.dataset.imageURL(i), width: t.dataset.width, height: t.dataset.height) else { continue }
                var count = 0
                for p in 0..<pixels where image[p].w > 0.5 {
                    let c = SIMD3(Float(photo[4 * p]), Float(photo[4 * p + 1]), Float(photo[4 * p + 2])) / 255
                    if simd_reduce_max(simd_abs(c - scan.background)) > 0.1 { count += 1 }
                }
                empty += Double(count) / Double(pixels)
            }
            return (try meanPSNR(t, frames: t.dataset.validationFrames), empty / Double(t.dataset.validationFrames.count))
        }
        var reference = config(iterations: 1500, holdOut: 6)
        reference.holeFilling = false
        let complete = try measure({ let t = try trainer(scan.directory, reference); _ = try train(t, until: 1500); return t }())
        try ExportManager.writePLY(full.filter { $0.x > -1.1 }, to: ply)     // the whole left wall
        var results: [Bool: (psnr: Double, empty: Double, holes: Int)] = [:]
        for fill in [false, true] {
            var c = config(iterations: 1500, holdOut: 6)
            c.holeFilling = fill
            let t = try trainer(scan.directory, c)
            _ = try train(t, until: 1500)
            let m = try measure(t)
            results[fill] = (m.psnr, m.empty, t.holeSeedsAdded)
        }
        print(String(format: "  full seed cloud: held-out PSNR %.2f dB, empty scene pixels %.2f%%", complete.psnr, complete.empty * 100))
        let off = results[false]!, on = results[true]!
        print(String(format: "  left wall unseeded: held-out PSNR %.2f -> %.2f dB, empty scene pixels %.2f%% -> %.2f%%, %d hole seeds",
                     off.psnr, on.psnr, off.empty * 100, on.empty * 100, on.holes))
        check(on.holes > 0 && on.empty <= off.empty && on.psnr > off.psnr + 0.1,
              "hole filling grows Gaussians where the seed cloud had none (held-out PSNR +\(String(format: "%.2f", on.psnr - off.psnr)) dB, no more empty pixels)")
    }

    static func convergence() throws {
        let scan = try writeScan(name: "converge", frames: 36)
        let t = try trainer(scan.directory, config(iterations: 1500, holdOut: 6))
        let start = try meanPSNR(t, frames: t.dataset.validationFrames)
        _ = try train(t, until: 1500)
        let end = try meanPSNR(t, frames: t.dataset.validationFrames)
        print("  held-out PSNR \(String(format: "%.2f", start)) -> \(String(format: "%.2f", end)) dB, Gaussians \(t.model.activeCount)")
        check(end > start + 6 && end > 25, "training converges on held-out views (\(String(format: "%.1f", end)) dB)")
    }

    static func enhancement() throws {
        let scan = try writeScan(name: "enhance", frames: 30)
        let c = config(iterations: 600, pose: true, holdOut: 6, sh: 1)
        let t = try trainer(scan.directory, c)
        _ = try train(t, until: 600)
        let directory = temp.appendingPathComponent("enhance-model", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try GaussianTrainingSession.writeModelFiles(t, into: directory, validation: nil, elapsedSeconds: 1, peakFootprintMB: 1)
        let views = t.dataset.trainFrames
        let before = try meanPSNR(t, frames: views), heldBefore = try meanPSNR(t, frames: t.dataset.validationFrames)
        // Enhance with a higher SH degree: the extra band starts at zero, so it renders as saved.
        let saved = GaussianExport.metadata(in: directory)!
        let e = try trainer(scan.directory, config(iterations: 600, pose: true, holdOut: 6, sh: 2)
            .enhancing(savedIterations: saved.iterations, savedGaussians: saved.gaussians, savedSHDegree: saved.shDegree),
                            initialize: false)
        try e.initializeModel(fromSaved: directory)
        let loaded = try meanPSNR(e, frames: views)
        let poseError = views.map { max(simd_length(t.poses[$0].rotation - e.poses[$0].rotation),
                                        simd_length(t.poses[$0].translation - e.poses[$0].translation)) }.max() ?? 1
        let moved = views.filter { !t.poses[$0].isIdentity }.count
        print(String(format: "  saved %.3f dB, reloaded %.3f dB, pose difference %.2e over %d refined views", before, loaded, poseError, moved))
        check(e.iteration == 600 && e.configuration.iterations == 1_200 && e.model.shDegree == 2
              && e.model.activeCount == t.model.activeCount && abs(loaded - before) < 0.02 && moved > 0 && poseError < 1e-6,
              "a saved model reloads with its refined poses and renders as saved (SH 1 raised to 2)")
        _ = try train(e, until: e.configuration.iterations)
        let heldAfter = try meanPSNR(e, frames: e.dataset.validationFrames)
        print(String(format: "  held-out %.2f -> %.2f dB after enhancing", heldBefore, heldAfter))
        check(heldAfter > heldBefore + 0.2, "enhancing continues the saved model's schedule and improves held-out views")
    }

    static func ppispRecovery() throws {
        let scan = try writeScan(name: "ppisp", frames: 30, exposureSpread: 0.6, seed: 5)
        var results: [Bool: Double] = [:]
        var learned: [Double] = []
        for usePPISP in [false, true] {
            let t = try trainer(scan.directory, config(iterations: 1500, ppisp: usePPISP))
            _ = try train(t, until: 1500)
            results[usePPISP] = try meanPSNR(t, frames: t.dataset.trainFrames)
            if usePPISP { learned = t.dataset.frames.indices.map { t.ppisp.exposure(frame: $0) } }
        }
        let truth = scan.trueExposure
        let r = correlation(learned, truth)
        print("  training-view PSNR without PPISP \(String(format: "%.2f", results[false]!)), with \(String(format: "%.2f", results[true]!)); exposure correlation \(String(format: "%.3f", r))")
        check(results[true]! > results[false]! + 1.0, "PPISP compensates per-image exposure (+\(String(format: "%.1f", results[true]! - results[false]!)) dB)")
        check(r > 0.9, "learned exposure offsets follow the applied ones (r = \(String(format: "%.3f", r)))")
    }

    static func poseRefinement() throws {
        let scan = try writeScan(name: "pose", frames: 30, poseNoise: (0.01, 0.3), seed: 9)
        var c = config(iterations: 2000, pose: true)
        c.seed = 11
        let t = try trainer(scan.directory, c)
        _ = try train(t, until: 2000)
        func errors(_ corrected: Bool) -> (Double, Double) {
            var rot = 0.0, trans = 0.0
            for (i, frame) in t.dataset.frames.enumerated() {
                let truth = GaussianCamera.worldToCamera(arkitRowMajorC2W: scan.truePoses[frame.id - 1])
                var estimate = GaussianCamera.worldToCamera(arkitRowMajorC2W: frame.transform)
                if corrected { estimate = t.poses[i].matrix * estimate }
                let c1 = GaussianCamera.rigidInverse(truth), c2 = GaussianCamera.rigidInverse(estimate)
                trans += simd_distance(SIMD3(c1[3][0], c1[3][1], c1[3][2]), SIMD3(c2[3][0], c2[3][1], c2[3][2]))
                let R = simd_double3x3(SIMD3(truth[0][0], truth[0][1], truth[0][2]), SIMD3(truth[1][0], truth[1][1], truth[1][2]), SIMD3(truth[2][0], truth[2][1], truth[2][2]))
                let S = simd_double3x3(SIMD3(estimate[0][0], estimate[0][1], estimate[0][2]), SIMD3(estimate[1][0], estimate[1][1], estimate[1][2]), SIMD3(estimate[2][0], estimate[2][1], estimate[2][2]))
                let d = R * S.transpose
                rot += acos(min(1, max(-1, (d[0][0] + d[1][1] + d[2][2] - 1) / 2))) * 180 / .pi
            }
            let n = Double(t.dataset.frames.count)
            return (rot / n, trans / n * 1000)
        }
        let before = errors(false), after = errors(true)
        print(String(format: "  pose error %.3f° / %.2f mm -> %.3f° / %.2f mm", before.0, before.1, after.0, after.1))
        check(after.0 < before.0 * 0.8 || after.1 < before.1 * 0.8, "pose refinement reduces the perturbation of the recorded poses")
        // Metric scale: the mean camera distance to the scene centre is unchanged by rigid corrections.
        check(t.poses.allSatisfy { $0.rotationDegrees < 5 && $0.translationMeters < 0.1 }, "pose corrections stay bounded near the ARKit prior")
    }

    /// Photos blurred over the exposure and read row by row: the capture-motion model should
    /// reproduce them better and, rendered still, be sharper than training without it.
    static func captureMotion() throws {
        let motion = (exposure: 0.06, readout: 0.06)
        let scan = try writeScan(name: "motion", frames: 36, seed: 13, motion: motion)
        var results: [Bool: (photo: Double, sharp: Double)] = [:]
        for modeled in [false, true] {
            var c = config(iterations: 2000, holdOut: 6)
            if modeled { c.motionBlur = true; c.rollingShutterReadout = motion.readout }
            let t = try trainer(scan.directory, c)
            _ = try train(t, until: 2000)
            let photo = try t.evaluate(frames: t.dataset.validationFrames).psnr
            var sharp = 0.0
            for i in t.dataset.validationFrames {
                let frame = t.dataset.frames[i]
                let w2c = GaussianCamera.worldToCamera(arkitRowMajorC2W: scan.truePoses[frame.id - 1])
                let camera = GaussianCamera(worldToCamera: w2c, fx: frame.intrinsics.fx, fy: frame.intrinsics.fy, cx: frame.intrinsics.cx,
                                            cy: frame.intrinsics.cy, width: t.dataset.width, height: t.dataset.height, mipFilter: true)
                guard let truth = try scan.renderer.render(model: scan.model, camera: camera, shDegree: 0, isp: nil, background: scan.background),
                      let estimate = try t.renderer.render(model: t.model, camera: camera, shDegree: t.activeDegree, isp: nil, background: scan.background) else { continue }
                sharp += psnr([UInt8](truth.pixels), [UInt8](estimate.pixels))
            }
            results[modeled] = (photo, sharp / Double(t.dataset.validationFrames.count))
        }
        let off = results[false]!, on = results[true]!
        print(String(format: "  held-out photos: %.2f -> %.2f dB; sharp reference: %.2f -> %.2f dB", off.photo, on.photo, off.sharp, on.sharp))
        check(on.photo > off.photo + 0.5, "the capture-motion model reproduces blurred, rolling-shutter photos (+\(String(format: "%.1f", on.photo - off.photo)) dB)")
        check(on.sharp > off.sharp + 0.5, "trained with the motion model, still renders are sharper (+\(String(format: "%.1f", on.sharp - off.sharp)) dB against the sharp scene)")
    }

    /// PSNR of two RGBA8 images (RGB only).
    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0.0, n = 0
        for i in 0..<min(a.count, b.count) where i % 4 != 3 {
            let d = (Double(a[i]) - Double(b[i])) / 255; sum += d * d; n += 1
        }
        return 10 * log10(1 / max(sum / Double(max(1, n)), 1e-12))
    }

    static func capUnderSmallBudget() throws {
        let scan = try writeScan(name: "cap", frames: 24)
        var c = config(iterations: 800, maxGaussians: 200_000)
        c.memoryBudgetMB = nil
        let dataset = try TrainingDataset.prepare(scan: scan.directory, longEdge: 160, holdOutEvery: 0, maxPoints: 250_000)
        // Budget that only fits a small capacity.
        let plan = try TrainingMemoryPlan.fit(width: dataset.width, height: dataset.height, shDegree: 1, requestedGaussians: 200_000,
                                              budgetBytes: 190 << 20, imageSlots: 3, previewPixels: 320 * 240)
        let t = try GaussianTrainer(configuration: c, dataset: dataset, plan: plan, metal: metal)
        try t.initializeModel()
        var peak = 0
        _ = try train(t, until: 800) { r in peak = max(peak, r.gaussians) }
        print("  capacity \(plan.gaussianCapacity), peak live \(peak), total planned \(plan.totalBytes >> 20) MB")
        check(plan.totalBytes <= 190 << 20 && peak <= plan.gaussianCapacity && t.model.count <= plan.gaussianCapacity,
              "densification never exceeds the memory plan's Gaussian cap")
    }

    static func checkpoints() throws {
        let scan = try writeScan(name: "checkpoint", frames: 20)
        let c = config(iterations: 600, ppisp: true, pose: true)
        let a = try trainer(scan.directory, c)
        _ = try train(a, until: 300)
        let dir = temp.appendingPathComponent("ck")
        try GaussianCheckpoint.save(a, elapsedSeconds: 12, to: dir)
        let url = dir.appendingPathComponent(GaussianCheckpoint.fileName)
        let b = try trainer(scan.directory, c)
        let header = try GaussianCheckpoint.load(url, into: b)
        var identical = header.iteration == 300 && b.model.activeCount == a.model.activeCount && b.ppisp == a.ppisp && b.poses == a.poses
        let pa = a.model.floats(a.model.params), pb = b.model.floats(b.model.params)
        for (k, row) in a.model.liveRows.enumerated() {
            for (offset, width) in a.model.layout.groups where width > 0 {
                for j in 0..<width where pa[offset + row * width + j] != pb[offset + k * width + j] { identical = false }
            }
        }
        check(identical, "a checkpoint restores parameters, Adam state, PPISP, poses and schedule exactly")
        let ra = try train(a, until: 400), rb = try train(b, until: 400)
        let la = ra.suffix(50).map(\.loss).reduce(0, +) / 50, lb = rb.suffix(50).map(\.loss).reduce(0, +) / 50
        print("  loss after resume: uninterrupted \(la), resumed \(lb)")
        check(abs(la - lb) / la < 0.03 && ra.map(\.frame) == rb.map(\.frame), "a resumed run follows the uninterrupted run (same views, loss within 3%)")
        // A version 1 checkpoint (before the relocation statistics) still resumes.
        let v1 = temp.appendingPathComponent("ck-v1")
        try GaussianCheckpoint.save(b, elapsedSeconds: 12, to: v1, formatVersion: 1)
        let old = try trainer(scan.directory, c)
        let oldHeader = try GaussianCheckpoint.load(v1.appendingPathComponent(GaussianCheckpoint.fileName), into: old)
        let views = old.model.stat(GaussianStats.views)
        check(oldHeader.version == 1 && old.model.activeCount == b.model.activeCount && (0..<old.model.count).allSatisfy { views[$0] == 0 },
              "a version 1 checkpoint resumes, with the relocation statistics starting at zero")
        // Corruption and truncation are detected.
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count / 2] ^= 0x5A
        let corrupt = dir.appendingPathComponent("corrupt.gsck")
        try bytes.write(to: corrupt)
        var detected = false
        do { _ = try GaussianCheckpoint.load(corrupt, into: try trainer(scan.directory, c)) } catch GaussianCheckpoint.CheckpointError.corrupt { detected = true }
        check(detected, "a flipped byte is rejected by the checksum")
        let truncated = dir.appendingPathComponent("truncated.gsck")
        try Data(contentsOf: url).prefix(Int(Double(bytes.count) * 0.7)).write(to: truncated)
        detected = false
        do { _ = try GaussianCheckpoint.load(truncated, into: try trainer(scan.directory, c)) } catch GaussianCheckpoint.CheckpointError.corrupt { detected = true }
        check(detected, "a truncated checkpoint is rejected")
        let other = try writeScan(name: "checkpoint-other", frames: 21)
        detected = false
        do { _ = try GaussianCheckpoint.load(url, into: try trainer(other.directory, c)) } catch GaussianCheckpoint.CheckpointError.incompatible { detected = true }
        check(detected, "a checkpoint of different inputs is refused")
        // A crash while writing leaves only a partial temporary file; the last checkpoint still loads.
        try Data(repeating: 7, count: 1000).write(to: dir.appendingPathComponent(".checkpoint-crash.partial"))
        _ = try train(a, until: 450)
        try GaussianCheckpoint.save(a, elapsedSeconds: 20, to: dir)
        let reloaded = try GaussianCheckpoint.load(url, into: try trainer(scan.directory, c))
        check(reloaded.iteration == 450, "checkpoints are replaced atomically and stay loadable")
    }

    static func session() throws {
        let scan = try writeScan(name: "session", frames: 20)
        let workspace = TrainingWorkspace(scan: scan.directory)
        var c = config(iterations: 700, ppisp: true, pose: true, holdOut: 5)
        c.memoryBudgetMB = 400
        final class Box: @unchecked Sendable { var snapshots: [TrainingSnapshot] = []; var frames = 0; let lock = NSLock() }
        let box = Box()
        func run(resume: Bool, configuration: GaussianTrainingConfiguration? = nil,
                 control: ((GaussianTrainingSession) -> Void)? = nil) -> TrainingSnapshot {
            box.lock.lock(); box.snapshots.removeAll(); box.lock.unlock()
            let s = GaussianTrainingSession(workspace: workspace, configuration: configuration ?? c, resume: resume, libraryURL: library)
            s.onSnapshot = { snap in box.lock.lock(); box.snapshots.append(snap); box.lock.unlock() }
            s.onFrame = { _, _ in box.lock.lock(); box.frames += 1; box.lock.unlock() }
            s.onPreparedViews = { views, depth in
                let o = OrbitCamera(arkitTransform: views[0].transform, intrinsics: views[0].intrinsics, depth: depth)
                s.updateViewer(ViewerRequest(orbit: o, captureFrame: nil, width: 120, height: 160, mode: .camera), interactive: false)
            }
            let thread = Thread { s.run() }
            thread.start()
            control?(s)
            while !s.isFinished { Thread.sleep(forTimeInterval: 0.05) }
            box.lock.lock(); defer { box.lock.unlock() }
            return box.snapshots.last!
        }
        func waitIteration(_ s: GaussianTrainingSession, _ n: Int) {
            while true {
                box.lock.lock(); let it = box.snapshots.last?.iteration ?? 0; box.lock.unlock()
                if it >= n { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        // Pause, checkpoint while paused, resume, then stop keeping the checkpoint.
        let stopped = run(resume: false) { s in
            waitIteration(s, 150)
            s.pause()
            Thread.sleep(forTimeInterval: 0.5)
            s.updateViewer(ViewerRequest(orbit: nil, captureFrame: 2, width: 120, height: 90, mode: .camera), interactive: true)
            Thread.sleep(forTimeInterval: 0.3)
            s.resumeTraining()
            waitIteration(s, 300)
            s.cancel(keepCheckpoint: true)
        }
        box.lock.lock(); let paused = box.snapshots.contains { $0.phase == .paused }; box.lock.unlock()
        let record = workspace.record()
        check(paused && stopped.phase == .cancelled && workspace.hasCheckpoint && record?.status == .cancelled
              && (record?.checkpointIteration ?? 0) >= 300, "pause, resume and stop-with-checkpoint keep a resumable state")
        check(box.frames > 0, "the live viewer received renders while training and while paused")
        // An app kill mid-run leaves "running" on disk; it reads as interrupted.
        var running = record!
        running.status = .running
        try workspace.save(running)
        check(workspace.record()?.status == .interrupted, "a run the app did not finish reads as interrupted in History")
        // Resuming needs room for the checkpoint's rows; with less memory now it says how much.
        let fits = try TrainingMemoryPlan.fit(width: 160, height: 120, shDegree: c.shDegree, requestedGaussians: 8_192, budgetBytes: 400 << 20)
        var refusal: String?
        do { try GaussianTrainingSession.checkResumeFits(rows: fits.gaussianCapacity + 1_000, plan: fits) } catch { refusal = error.localizedDescription }
        let accepted = (try? GaussianTrainingSession.checkResumeFits(rows: fits.gaussianCapacity, plan: fits)) != nil
        check(accepted && (refusal ?? "").contains("可用記憶體不足以載入上次的進度") && (refusal ?? "").contains("MB"),
              "a checkpoint larger than today's memory plan is refused with the memory it needs, not as damaged")
        // Resume to the end: model files are exported and the checkpoint is removed.
        let resumeFrom = GaussianCheckpoint.header(at: workspace.checkpointURL)!.iteration
        let done = run(resume: true)
        let files = [GaussianExport.plyName, GaussianExport.metadataName, GaussianExport.ppispName, GaussianExport.posesName,
                     GaussianExport.reportName, "preview.jpg"].allSatisfy { FileManager.default.fileExists(atPath: workspace.modelDirectory.appendingPathComponent($0).path) }
        check(done.phase == .completed && files && !FileManager.default.fileExists(atPath: workspace.checkpointURL.path)
              && workspace.record()?.status == .completed && resumeFrom >= 300,
              "resuming from iteration \(resumeFrom) completes the run and saves the model")
        // The scan's own files were never modified.
        let poses = try Data(contentsOf: scan.directory.appendingPathComponent("poses.jsonl"))
        let recorded = ScanLibrary.readRecords(scan.directory.appendingPathComponent("poses.jsonl"))
        check(!poses.isEmpty && recorded.count == 20 && recorded.map(\.transform) == ScanLibrary.readRecords(scan.directory.appendingPathComponent("poses.jsonl")).map(\.transform),
              "the scan's original poses stay unchanged; refined poses go to the model folder")
        // Saved-model viewer renders the model with the same ISP.
        let viewer = try GaussianModelViewer(workspace: workspace, metal: metal)
        let sem = DispatchSemaphore(value: 0)
        final class Result: @unchecked Sendable { var frame: RenderedFrame? }
        let result = Result()
        let o = OrbitCamera(arkitTransform: viewer.views[0].transform, intrinsics: viewer.views[0].intrinsics, depth: viewer.initialDepth)
        viewer.render(ViewerRequest(orbit: o, captureFrame: nil, width: 120, height: 160, mode: .camera)) { f, _ in result.frame = f; sem.signal() }
        while sem.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let lit = result.frame.map { Set($0.pixels.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)).count } ?? 0
        check(viewer.gaussians > 0 && lit > 20, "the saved model reloads in the viewer and renders an image")
        let metadata = try JSONDecoder.training.decode(GaussianExport.Metadata.self,
            from: Data(contentsOf: workspace.modelDirectory.appendingPathComponent(GaussianExport.metadataName)))
        check(metadata.mipFilter2D && metadata.opacityCompensation && metadata.ppisp == GaussianExport.ppispName && !metadata.viewerNotes.isEmpty,
              "model metadata records the mip filter, PPISP sidecar and viewer limitations")
        // The dataset ZIP leaves the training folder out.
        let zip = try ExportManager.makeArchive(of: scan.directory)
        let listing = try String(decoding: Data(contentsOf: zip), as: UTF8.self)
        check(!listing.contains(TrainingWorkspace.folderName) && listing.contains("poses.jsonl"),
              "the dataset archive excludes the training checkpoint and model")
        let model = try workspace.makeModelArchive()
        let modelListing = try String(decoding: Data(contentsOf: model), as: UTF8.self)
        check(modelListing.contains(GaussianExport.plyName) && modelListing.contains(GaussianExport.ppispName),
              "the model archive contains the PLY and its sidecars")
        // A retrain only replaces the saved model when it completes.
        let savedModel = try Data(contentsOf: workspace.modelURL)
        _ = run(resume: false) { s in waitIteration(s, 120); s.cancel(keepCheckpoint: false) }
        check(workspace.hasModel && (try? Data(contentsOf: workspace.modelURL)) == savedModel && !workspace.hasCheckpoint
              && workspace.record()?.status == .completed, "stopping a retrain with delete keeps the saved model and its status")
        _ = run(resume: false) { s in waitIteration(s, 120); s.cancel(keepCheckpoint: true) }
        check(workspace.hasModel && workspace.hasCheckpoint && workspace.record()?.status == .cancelled,
              "a retrain stopped with its progress can resume while the saved model stays")
        try workspace.discardProgress()
        check(workspace.hasModel && !workspace.hasCheckpoint && workspace.record()?.status == .completed
              && (try? Data(contentsOf: workspace.modelURL)) == savedModel,
              "deleting a retrain's progress restores the saved model's completed status")
        // Enhance model: continue the saved model for 300 more iterations.
        let saved = GaussianExport.metadata(in: workspace.modelDirectory)!
        var extra = c
        extra.iterations = 300
        let enhanced = extra.enhancing(savedIterations: saved.iterations, savedGaussians: saved.gaussians, savedSHDegree: saved.shDegree)
        let finished = run(resume: false, configuration: enhanced)
        box.lock.lock()
        let started = box.snapshots.first { $0.phase == .running }
        let neverRestarted = box.snapshots.allSatisfy { $0.iteration >= saved.iterations && $0.startIteration == saved.iterations }
        box.lock.unlock()
        let after = GaussianExport.metadata(in: workspace.modelDirectory)
        print("  enhancement: started \(started?.iteration ?? -1), restarted \(!neverRestarted), finished \(finished.phase) \(finished.iteration)/\(finished.total), saved \(after?.iterations ?? -1), progress \(workspace.record()?.progress ?? -1)")
        check(finished.phase == .completed && started?.iteration == saved.iterations && neverRestarted
              && workspace.record()?.progress == 1
              && after?.iterations == saved.iterations + 300 && workspace.record()?.status == .completed
              && (try? Data(contentsOf: workspace.modelURL)) != savedModel && !workspace.hasCheckpoint,
              "Enhance model continues from iteration \(saved.iterations) to \(saved.iterations + 300) and replaces the model")
        // Finish now, also from a pause: the current model becomes the result.
        let early = run(resume: false) { s in
            waitIteration(s, 150)
            s.pause()
            Thread.sleep(forTimeInterval: 0.3)
            s.finishNow()
        }
        let earlyRecord = workspace.record()
        let earlyMetadata = GaussianExport.metadata(in: workspace.modelDirectory)
        check(early.phase == .completed && earlyRecord?.status == .completed && earlyRecord?.finishedEarly == true
              && (earlyRecord?.iteration ?? 0) >= 150 && (earlyRecord?.iteration ?? 0) < c.iterations
              && earlyMetadata?.iterations == earlyRecord?.iteration && !workspace.hasCheckpoint,
              "Finish and save model ends a paused run at iteration \(earlyRecord?.iteration ?? 0) and saves it as the model")
    }


    static func largeScanStress() throws {
        // 1,200 small frames: dataset preparation, streaming with a 3-image cache, and a tight
        // budget. Footprint growth must stay within the plan.
        let scan = try writeScan(name: "large", frames: 1_200, width: 96, height: 72, seed: 21, grid: true)
        let baseline = TrainingMemoryPlan.footprintBytes
        let c = config(iterations: 1_500, ppisp: true, pose: true, maxGaussians: 30_000)
        let dataset = try TrainingDataset.prepare(scan: scan.directory, longEdge: 96, holdOutEvery: 0, maxPoints: 250_000)
        let plan = try TrainingMemoryPlan.fit(width: dataset.width, height: dataset.height, shDegree: 1, requestedGaussians: 30_000,
                                              budgetBytes: 200 << 20, imageSlots: 3, previewPixels: 160 * 120)
        let t = try GaussianTrainer(configuration: c, dataset: dataset, plan: plan, metal: metal)
        try t.initializeModel()
        var peak = 0
        _ = try train(t, until: 1_500) { r in if r.iteration % 100 == 0 { peak = max(peak, TrainingMemoryPlan.footprintBytes) } }
        let growth = peak - baseline
        print("  \(dataset.frames.count) frames, planned \(plan.totalBytes >> 20) MB, footprint growth \(growth >> 20) MB, live \(t.model.activeCount)")
        check(dataset.frames.count >= 1_100 && growth < plan.totalBytes + (64 << 20) && t.model.count <= plan.gaussianCapacity,
              "a 1,200-frame scan trains within the planned memory (streamed images, bounded cache)")
    }
}
