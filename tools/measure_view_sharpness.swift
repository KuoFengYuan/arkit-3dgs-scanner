// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// Measured sharpness of every photo of a scan against the photos of the same surface
// (`CovisibleSharpness`), with the capture's exposure, ISO and motion estimate, as CSV.
// Reads the scan only.
//
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector}.swift \
//   arkit-3dgs-scanner/History/ScanLibrary.swift arkit-3dgs-scanner/Training/*.swift \
//   tools/measure_view_sharpness.swift -o /tmp/measure_view_sharpness
// /tmp/measure_view_sharpness SCAN OUT.csv
//   Columns: the photo, whether the scan's selection trains it, its blur verdict, its deficit
//   against the selected photos (as training uses it) and against every photo, peers, noise.
import Foundation
import simd

@main struct MeasureViewSharpness {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 else { print("Usage: measure_view_sharpness SCAN OUT.csv"); exit(2) }
        let scan = URL(fileURLWithPath: args[0])
        let (records, _) = ScanLibrary.savedRecords(in: scan)
        let selection = TrainingDataset.storedSelection(scan.appendingPathComponent("training-selection.json"))
        let selected = Set(selection?.selectedIDs ?? records.map(\.id))
        let distance = TrainingFrameSelector.workingDistance(records: records, directory: scan)
        let scale = TrainingFrameSelector.metricScale(workingDistance: distance)
        let frames = records.filter(TrainingDataset.isValid).map { r in
            TrainingFrame(id: r.id, imageFile: r.imageFile, intrinsics: r.intrinsics, transform: r.transform, captureEV: nil,
                          isValidation: false, depthFile: r.depthFile, confidenceFile: r.confidenceFile,
                          depthWidth: r.depthWidth, depthHeight: r.depthHeight)
        }
        let started = Date()
        var grids: [CovisibleSharpness.Grid?] = []
        for (n, f) in frames.enumerated() {
            grids.append(autoreleasepool { CovisibleSharpness.grid(f, directory: scan) })
            if n % 200 == 0 { print("grid \(n) / \(frames.count)") }
        }
        let gridSeconds = Date().timeIntervalSince(started)
        let selectedIndices = Set(frames.indices.filter { selected.contains(frames[$0].id) })
        let againstSelected = CovisibleSharpness.scores(grids: grids, peers: selectedIndices, metricScale: scale)
        let againstAll = CovisibleSharpness.scores(grids: grids, metricScale: scale)
        print(String(format: "%d photos, grids in %.1f s, scores in %.1f s (working distance %.2f m)",
                     frames.count, gridSeconds, Date().timeIntervalSince(started) - gridSeconds, distance ?? 0))
        if let debug = ProcessInfo.processInfo.environment["SHARP_DEBUG"].flatMap(Int.init), let i = frames.firstIndex(where: { $0.id == debug }), let a = grids[i] {
            // One photo's pairs: peer, matched cells, median ln energy ratio, and a's grid.
            let usable = a.energy.filter { $0 >= 0 }
            print("debug \(debug): noise \(a.noise), usable cells \(usable.count), median energy \(CovisibleSharpness.median(usable))")
            for j in grids.indices where j != i {
                guard let b = grids[j], simd_distance(a.position, b.position) <= CovisibleSharpness.radius * scale,
                      simd_dot(a.forward, b.forward) >= cos(CovisibleSharpness.coneDegrees * .pi / 180) else { continue }
                let d = CovisibleSharpness.differences(a, b)
                if d.count >= CovisibleSharpness.minCells {
                    print(String(format: "  peer %d: %.2f m, %d cells, median %.3f, peer noise %.2e", frames[j].id, simd_distance(a.position, b.position), d.count, CovisibleSharpness.median(d), b.noise))
                }
            }
        }
        if let pairsPath = ProcessInfo.processInfo.environment["SHARP_PAIRS"] {
            // Every pair of photos of the same surface (any selection), for regressions of the
            // measured difference on exposure, ISO and motion: i, j, cells, median ln ratio.
            var lines = ["i,j,cells,median"]
            let cosCone = cos(CovisibleSharpness.coneDegrees * .pi / 180)
            for i in grids.indices {
                guard let a = grids[i] else { continue }
                for j in grids.indices where j > i {
                    guard let b = grids[j], simd_distance(a.position, b.position) <= CovisibleSharpness.radius * scale,
                          simd_dot(a.forward, b.forward) >= cosCone else { continue }
                    let d = CovisibleSharpness.differences(a, b)
                    if d.count >= 100 { lines.append("\(frames[i].id),\(frames[j].id),\(d.count),\(CovisibleSharpness.median(d))") }
                }
            }
            try lines.joined(separator: "\n").write(to: URL(fileURLWithPath: pairsPath), atomically: true, encoding: .utf8)
        }
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows = ["id,selected,verdict,deficit_selected,peers_selected,cells_selected,deficit_all,peers_all,noise,iso,exposure,estimated_blur_px,capture_sharpness"]
        for (i, f) in frames.enumerated() {
            let r = byID[f.id]!
            let s = againstSelected[i], a = againstAll[i]
            rows.append(String(format: "%d,%d,%@,%@,%d,%d,%@,%d,%@,%.1f,%.6f,%.2f,%.5f", f.id, selected.contains(f.id) ? 1 : 0,
                               r.blurVerdict.rawValue, s.map { String(format: "%.4f", $0.deficit) } ?? "", s?.peers ?? 0, s?.matchedCells ?? 0,
                               a.map { String(format: "%.4f", $0.deficit) } ?? "", a?.peers ?? 0,
                               (s ?? a).map { String(format: "%.3e", $0.noise) } ?? "", r.iso, r.exposureDuration, r.estimatedBlurPx, r.sharpness))
        }
        try rows.joined(separator: "\n").write(to: URL(fileURLWithPath: args[1]), atomically: true, encoding: .utf8)
    }
}
