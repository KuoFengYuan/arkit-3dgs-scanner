// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import CoreGraphics
import simd

/// Interactive viewer of a completed model: loads `gaussians.sog` (or an older `gaussians.ply`,
/// + `ppisp.json`) into an
/// inference-only model and renders on its own serial queue with the training rasterizer and
/// ISP, so the saved result looks exactly like the live preview. Memory is checked before
/// loading; requests are coalesced (the latest camera wins).
nonisolated final class GaussianModelViewer: @unchecked Sendable {
    enum ViewerError: LocalizedError {
        case insufficientMemory(Int)
        var errorDescription: String? {
            switch self {
            case .insufficientMemory(let mb): return L10n.text("記憶體不足，無法開啟 3DGS 模型（約需 \(mb) MB）。請關閉其他 App 後重試。")
            }
        }
    }

    let metadata: GaussianExport.Metadata
    let views: [TrainingFrame]
    let initialDepth: Double
    private let model: GaussianModel
    private let renderer: GaussianRenderer
    private let ppisp: PPISPModel?
    private let queue = DispatchQueue(label: "gaussian-viewer", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: ViewerRequest?
    private var busy = false
    static let maxPixels = 900 * 1_200

    /// Largest model the viewer opens (a damaged header must not overflow the estimate).
    static let maxGaussians = 16_000_000

    /// Estimated bytes to open a model of `count` Gaussians.
    static func bytes(count: Int, shDegree: Int) -> Int {
        let rows = (min(max(0, count), maxGaussians) + 1023) / 1024 * 1024
        return rows * (GaussianModel.viewerBytesPerGaussian(shDegree: shDegree) + GaussianRasterizer.bytesPerGaussian
                       + TrainingMemoryPlan.intersectionsPerGaussian * GaussianRasterizer.bytesPerIntersection)
            + GaussianRenderer.bytes(maxPixels: maxPixels)
    }

    init(workspace: TrainingWorkspace, metal: GaussianMetal? = nil) throws {
        let data = try Data(contentsOf: workspace.modelDirectory.appendingPathComponent(GaussianExport.metadataName))
        metadata = try JSONDecoder.training.decode(GaussianExport.Metadata.self, from: data)
        let header = try GaussianExport.modelInfo(workspace.modelURL)
        guard header.count > 0, header.count <= Self.maxGaussians, (0...3).contains(header.shDegree) else {
            throw GaussianExport.ExportError.damaged
        }
        let needed = Self.bytes(count: header.count, shDegree: header.shDegree)
        if let available = TrainingMemoryPlan.availableBytesIfKnown, needed + TrainingMemoryPlan.headroomBytes > available {
            throw ViewerError.insufficientMemory(needed >> 20)
        }
        let metal = try metal ?? GaussianMetal()
        let rows = (header.count + 1023) / 1024 * 1024
        model = try GaussianModel(metal: metal, capacity: rows, shDegree: header.shDegree, trainable: false)
        try GaussianExport.readModel(workspace.modelURL, into: model)
        let raster = try GaussianRasterizer(metal: metal, capacity: rows,
                                            intersectionCapacity: rows * TrainingMemoryPlan.intersectionsPerGaussian,
                                            maxTiles: 65_536)
        renderer = try GaussianRenderer(metal: metal, raster: raster, maxPixels: Self.maxPixels)
        if let ppispData = try? Data(contentsOf: workspace.modelDirectory.appendingPathComponent(GaussianExport.ppispName)),
           let file = try? JSONDecoder().decode(GaussianExport.PPISPFile.self, from: ppispData) {
            ppisp = PPISPModel(file: file)
        } else { ppisp = nil }
        // Capture views for the start pose come from the scan's records.
        let (records, _) = ScanLibrary.savedRecords(in: workspace.scan)
        let frames = records.filter { $0.transform.count == 16 && $0.blurVerdict == .keep }.map {
            TrainingFrame(id: $0.id, imageFile: $0.imageFile, intrinsics: $0.intrinsics, transform: $0.transform,
                          captureEV: nil, isValidation: false)
        }
        views = frames
        initialDepth = Self.medianDepth(model: model, view: frames.first)
    }

    /// Median distance to the Gaussians in front of `view` (the orbit pivot distance).
    static func medianDepth(model: GaussianModel, view: TrainingFrame?) -> Double {
        guard let view, model.count > 0 else { return 1.5 }
        let w2c = GaussianCamera.worldToCamera(arkitRowMajorC2W: view.transform)
        let step = max(1, model.count / 20_000)
        var depths: [Float] = []
        for row in stride(from: 0, to: model.count, by: step) {
            let mean = model.mean(row)
            let m = SIMD4<Double>(Double(mean.x), Double(mean.y), Double(mean.z), 1)
            let z = simd_mul(w2c, m).z
            if z > 0.1 && z < 50 { depths.append(Float(z)) }
        }
        return Double(MRNFStrategy.median(depths) ?? 1.5)
    }

    var gaussians: Int { model.activeCount }

    func fitted(width: Int, height: Int) -> (Int, Int) { renderer.fitted(width: width, height: height) }

    /// Renders `request` (orbit views only) asynchronously; `completion` runs on the main queue.
    func render(_ request: ViewerRequest, completion: @escaping @Sendable (RenderedFrame?, ViewerRequest) -> Void) {
        lock.lock()
        pending = request
        let start = !busy
        busy = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let next = pending else { busy = false; lock.unlock(); return }
                pending = nil
                lock.unlock()
                let frame = autoreleasepool { () -> RenderedFrame? in
                    guard let orbit = next.orbit else { return nil }
                    let camera = orbit.camera(width: next.width, height: next.height, mipFilter: metadata.mipFilter2D)
                    let isp = next.mode == .off ? nil : ppisp?.uniforms(frame: nil)
                    return try? renderer.render(model: model, camera: camera, shDegree: model.shDegree, isp: isp)
                }
                DispatchQueue.main.async { completion(frame, next) }
            }
        }
    }
}

nonisolated extension PPISPModel {
    /// Rebuilds the ISP from an exported `ppisp.json` (parameters only; no optimiser state).
    init(file: GaussianExport.PPISPFile) {
        self.init(frames: file.frames.count, cameras: max(1, file.cameras.count))
        for (f, frame) in file.frames.enumerated() {
            parameters[exposureOffset + f] = frame.exposureEV
            for k in 0..<min(8, frame.colorLatents.count) { parameters[colorOffset + f * 8 + k] = frame.colorLatents[k] }
        }
        for (c, camera) in file.cameras.enumerated() {
            for ch in 0..<min(3, camera.vignetting.count) {
                for k in 0..<min(5, camera.vignetting[ch].count) { parameters[vignettingOffset + c * 15 + ch * 5 + k] = camera.vignetting[ch][k] }
            }
            for ch in 0..<min(3, camera.responseRaw.count) {
                for k in 0..<min(4, camera.responseRaw[ch].count) { parameters[crfOffset + c * 12 + ch * 4 + k] = camera.responseRaw[ch][k] }
            }
        }
        seedMeanEV = file.seedMeanEV
    }
}
