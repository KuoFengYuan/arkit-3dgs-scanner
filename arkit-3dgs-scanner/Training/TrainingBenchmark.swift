// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
#if DEBUG || TRAINING_BENCHMARK
import Foundation
import Metal
import SwiftUI

/// Training speed on the phone with the replay protocol of tools/train_gaussians.swift: the
/// Standard preset at a fixed iteration count (not the automatic one), seeds from the training
/// photos' LiDAR depth only, fixed held-out photos, this device's memory plan. Only in builds
/// with TRAINING_BENCHMARK (a Release build with OTHER_SWIFT_FLAGS=-DTRAINING_BENCHMARK) or
/// DEBUG; see docs/DEVICE_NOTES.md.
///
/// `--benchmark-training SCAN [--iterations N] [--holdout-ids FILE] [--benchmark-label NAME]`:
/// SCAN is a folder in Documents/benchmark (a copied scan stays out of the scan history) or else
/// in Documents/scans, and FILE is in Documents/benchmark. Reads the scan only; progress and the
/// result are printed (devicectl --console) and the result is also written to
/// Documents/benchmark-results/SCAN-NAME-TIME.json (files copied in by devicectl can leave
/// Documents/benchmark read-only for the app).
nonisolated enum TrainingBenchmark {
    struct Request { var scan: String; var iterations: Int; var holdOutIDs: String?; var label: String }

    struct Sample: Codable { var iteration: Int; var seconds: Double; var thermal: String; var footprintMB: Int }

    struct Result: Codable {
        var device: String, scan: String, label: String
        var iterations: Int, seconds: Double, millisecondsPerIteration: Double
        var trainingPhotos: Int, validationPhotos: Int, gaussians: Int
        var plan: String, plannedMB: Int
        var peakFootprintMB: Int, lifetimePeakFootprintMB: Int
        var samples: [Sample]
        /// `GaussianTrainer.profile` per iteration (milliseconds; "intersections" as a count).
        var profile: [String: Double]
        /// Mean milliseconds per stage of a step on 20 training photos after the run.
        var stages: [String: Double]
        var validationPSNR: Double, validationSSIM: Double
        var alignedPSNR: Double, alignedSSIM: Double
    }

    static var request: Request? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--benchmark-training"), a.indices.contains(i + 1) else { return nil }
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil } }
        return Request(scan: a[i + 1], iterations: value("--iterations").flatMap(Int.init) ?? 10_000,
                       holdOutIDs: value("--holdout-ids"), label: value("--benchmark-label") ?? "run")
    }

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("benchmark", isDirectory: true)
    }
    static var results: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("benchmark-results", isDirectory: true)
    }

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var lifetimePeakFootprint: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return ok == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak) : 0
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func run(_ request: Request, log: (String) -> Void) throws -> Result {
        let scans = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("scans", isDirectory: true)
        let copied = directory.appendingPathComponent(request.scan, isDirectory: true)
        let scan = FileManager.default.fileExists(atPath: copied.path) ? copied : scans.appendingPathComponent(request.scan, isDirectory: true)
        var config = GaussianTrainingConfiguration.preset(.standard)
        config.iterations = request.iterations
        config.holdOutEvery = 8
        let holdOut: Set<Int>? = try request.holdOutIDs.map { name in
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            return Set(text.split(whereSeparator: { $0 == "," || $0.isNewline }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        }
        let dataset = try TrainingDataset.prepare(scan: scan, longEdge: config.longEdge, holdOutEvery: config.holdOutEvery,
                                                  maxPoints: config.seedBudget, depthSeedLimit: config.depthSeedLimit(cloudPoints:),
                                                  holdOutIDs: holdOut, savedCloud: false)
        let plan = try TrainingMemoryPlan.fit(width: dataset.width, height: dataset.height, shDegree: config.shDegree,
                                              requestedGaussians: config.maxGaussians, budgetBytes: TrainingMemoryPlan.automaticBudget())
        log("\(deviceModel) \(request.label): \(dataset.trainFrames.count) training / \(dataset.validationFrames.count) held-out photos, \(dataset.points.count) seeds, plan \(plan.summary)")
        let trainer = try GaussianTrainer(configuration: config, dataset: dataset, plan: plan, metal: GaussianMetal())
        try trainer.initializeModel()
        var samples: [Sample] = [], peak = 0
        let start = Date()
        while trainer.iteration < config.iterations {
            let report = try trainer.step()
            if report.iteration % 500 == 0 || report.iteration == config.iterations {
                let footprint = TrainingMemoryPlan.footprintBytes >> 20
                peak = max(peak, footprint)
                let seconds = Date().timeIntervalSince(start)
                samples.append(Sample(iteration: report.iteration, seconds: seconds, thermal: thermal, footprintMB: footprint))
                log(String(format: "it %5d  %.1f ms/it  Gaussians %7d  footprint %d MB  thermal %@", report.iteration,
                           seconds / Double(report.iteration) * 1000, report.gaussians, footprint, thermal))
            }
        }
        let seconds = Date().timeIntervalSince(start)
        let n = Double(max(1, config.iterations))
        let profile = Dictionary(uniqueKeysWithValues: trainer.profile.map { ($0.key, $0.key == "intersections" ? $0.value / n : $0.value / n * 1000) })
        let lifetime = lifetimePeakFootprint >> 20
        let plain = try trainer.evaluate()
        let aligned = try trainer.evaluate(alignSteps: 30)
        let train = dataset.trainFrames
        let frames = Swift.stride(from: 0, to: train.count, by: max(1, train.count / 20)).prefix(20).map { train[$0] }
        let stages = try trainer.profileStages(frames: frames).reduce(into: [String: Double]()) {
            $0[$1.stage] = $1.milliseconds.reduce(0, +) / Double(max(1, $1.milliseconds.count))
        }
        return Result(device: deviceModel, scan: request.scan, label: request.label, iterations: config.iterations, seconds: seconds,
                      millisecondsPerIteration: seconds / n * 1000, trainingPhotos: train.count,
                      validationPhotos: dataset.validationFrames.count, gaussians: trainer.model.activeCount,
                      plan: plan.summary, plannedMB: plan.totalBytes >> 20, peakFootprintMB: peak, lifetimePeakFootprintMB: lifetime,
                      samples: samples, profile: profile, stages: stages, validationPSNR: plain.psnr, validationSSIM: plain.ssim,
                      alignedPSNR: aligned.psnr, alignedSSIM: aligned.ssim)
    }
}

/// Shown instead of the app while a benchmark runs; keeps the screen on and exits when done.
struct TrainingBenchmarkView: View {
    let request: TrainingBenchmark.Request
    @State private var status = "Starting…"

    var body: some View {
        Text(status)
            .font(.caption.monospaced())
            .padding()
            .task {
                UIApplication.shared.isIdleTimerDisabled = true
                let request = request
                let outcome = await Task.detached(priority: .userInitiated) { () -> String in
                    func log(_ line: String) {
                        print(line); fflush(stdout)
                        Task { @MainActor in status = line }
                    }
                    do {
                        let result = try TrainingBenchmark.run(request, log: log)
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let data = try encoder.encode(result)
                        let name = "\(request.scan)-\(request.label)-\(Int(Date().timeIntervalSince1970)).json"
                        log("BENCHMARK RESULT \(name)\n\(String(decoding: data, as: UTF8.self))")
                        try FileManager.default.createDirectory(at: TrainingBenchmark.results, withIntermediateDirectories: true)
                        try data.write(to: TrainingBenchmark.results.appendingPathComponent(name))
                        return "done"
                    } catch {
                        log("BENCHMARK FAILED: \(error.localizedDescription)")
                        return "failed"
                    }
                }.value
                status += "\n\(outcome)"
                try? await Task.sleep(for: .seconds(2))
                exit(0)
            }
    }
}
#endif
