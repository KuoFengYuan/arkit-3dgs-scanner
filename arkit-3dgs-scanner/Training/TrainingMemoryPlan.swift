// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Upper bound on the memory one training run allocates, computed with overflow-checked
/// arithmetic before any buffer exists. Every growable quantity (Gaussian count, tile
/// intersections, cached images, checkpoint staging) has a fixed capacity inside this plan, so
/// densification can never allocate more.
nonisolated struct TrainingMemoryPlan: Codable, Equatable, Sendable {
    enum PlanError: LocalizedError {
        case overflow, insufficientMemory(availableMB: Int, requiredMB: Int)
        var errorDescription: String? {
            switch self {
            case .overflow: return L10n.text("訓練設定超出可計算的記憶體範圍")
            case .insufficientMemory(let available, let required):
                return L10n.text("可用記憶體不足：需要約 \(required) MB，目前可用 \(available) MB。請關閉其他 App 或降低訓練品質後重試。")
            }
        }
    }

    var width: Int
    var height: Int
    var shDegree: Int
    /// Rows of the Gaussian buffers (hard cap for densification).
    var gaussianCapacity: Int
    /// Tile intersections the sort buffers hold.
    var intersectionCapacity: Int
    var imageSlots: Int
    var previewPixels: Int
    /// Bytes by component.
    var modelBytes: Int, rasterBytes: Int, intersectionBytes: Int, pixelBytes: Int, imageBytes: Int
    var previewBytes: Int, stagingBytes: Int, fixedBytes: Int
    /// Total planned bytes and the budget they were fitted into.
    var totalBytes: Int
    var budgetBytes: Int

    /// Average tile intersections provisioned per Gaussian; a view needing more skips that
    /// iteration and stops growth instead of allocating.
    static let intersectionsPerGaussian = 10
    static let minimumCapacity = 4_096
    /// Kernel/pipeline objects, command buffers, CPU-side refine arrays and the SwiftUI app.
    static let fixedOverhead = 160 << 20
    /// Memory that must stay free after the plan so the system never has to terminate the app.
    static let headroomBytes = 450 << 20
    static let checkpointChunk = 8 << 20

    static func mul(_ a: Int, _ b: Int) throws -> Int {
        let (v, o) = a.multipliedReportingOverflow(by: b)
        guard !o, v >= 0 else { throw PlanError.overflow }
        return v
    }
    static func add(_ values: Int...) throws -> Int {
        try values.reduce(0) { a, b in let (v, o) = a.addingReportingOverflow(b); guard !o else { throw PlanError.overflow }; return v }
    }

    /// Bytes for a given capacity (every buffer the trainer creates).
    static func components(width: Int, height: Int, shDegree: Int, capacity: Int, imageSlots: Int,
                           previewPixels: Int) throws -> (model: Int, raster: Int, intersections: Int, pixels: Int,
                                                          images: Int, preview: Int, intersectionCapacity: Int) {
        let pixels = try mul(width, height)
        let model = try mul(capacity, GaussianModel.bytesPerGaussian(shDegree: shDegree))
        let raster = try mul(capacity, GaussianRasterizer.bytesPerGaussian)
        let intersectionCapacity = try mul(capacity, intersectionsPerGaussian)
        let intersections = try mul(intersectionCapacity, GaussianRasterizer.bytesPerIntersection)
        // Render target, loss/SSIM/PPISP buffers, target image and edge map (+ edge scratch).
        let perPixel = GaussianRenderTarget.bytes(width: 1, height: 1) + GaussianLossEvaluator.bytesPerPixel + 4 + 4 + 4
        let pixelBytes = try mul(pixels, perPixel)
        let images = try mul(TrainingImageLoader.bytes(width: width, height: height, slots: 1), imageSlots)
        // Preview: its own render target, ISP output and RGBA8 image.
        let preview = try mul(previewPixels, GaussianRenderer.bytes(maxPixels: 1))
        return (model, raster, intersections, pixelBytes, images, preview, intersectionCapacity)
    }

    /// Largest capacity (≤ `requestedGaussians`, multiple of 1024) that fits `budget`.
    static func fit(width: Int, height: Int, shDegree: Int, requestedGaussians: Int, budgetBytes: Int,
                    imageSlots: Int = 3, previewPixels: Int = 720 * 960) throws -> TrainingMemoryPlan {
        func plan(_ capacity: Int) throws -> TrainingMemoryPlan {
            let c = try components(width: width, height: height, shDegree: shDegree, capacity: capacity,
                                   imageSlots: imageSlots, previewPixels: previewPixels)
            let total = try add(c.model, c.raster, c.intersections, c.pixels, c.images, c.preview,
                                checkpointChunk, fixedOverhead)
            return TrainingMemoryPlan(width: width, height: height, shDegree: shDegree, gaussianCapacity: capacity,
                                      intersectionCapacity: c.intersectionCapacity, imageSlots: imageSlots,
                                      previewPixels: previewPixels, modelBytes: c.model, rasterBytes: c.raster,
                                      intersectionBytes: c.intersections, pixelBytes: c.pixels, imageBytes: c.images,
                                      previewBytes: c.preview, stagingBytes: checkpointChunk, fixedBytes: fixedOverhead,
                                      totalBytes: total, budgetBytes: budgetBytes)
        }
        let requested = max(minimumCapacity, (requestedGaussians + 1023) / 1024 * 1024)
        let minimal = try plan(minimumCapacity)
        guard minimal.totalBytes <= budgetBytes else {
            throw PlanError.insufficientMemory(availableMB: budgetBytes >> 20, requiredMB: minimal.totalBytes >> 20)
        }
        var lo = minimumCapacity / 1024, hi = requested / 1024
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if try plan(mid * 1024).totalBytes <= budgetBytes { lo = mid } else { hi = mid - 1 }
        }
        return try plan(lo * 1024)
    }

    // MARK: Device memory

    /// Memory the process may still allocate before the system limit (iOS), or a conservative
    /// share of physical memory elsewhere.
    static var availableBytes: Int {
        #if os(iOS)
        let value = Int(os_proc_available_memory())
        if value > 0 { return value }
        #endif
        return Int(min(ProcessInfo.processInfo.physicalMemory / 2, UInt64(Int.max)))
    }

    /// Current physical footprint of the process (what the system limit is enforced on).
    static var footprintBytes: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Default budget: 55% of what the process can still allocate, minus fixed headroom,
    /// and never more than a device-tier ceiling (smaller phones get smaller runs).
    static func automaticBudget(available: Int = availableBytes,
                                physical: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let tierCeiling: Int
        switch physical {
        case ..<(5 << 30): tierCeiling = 900 << 20        // 4 GB devices
        case ..<(7 << 30): tierCeiling = 1_600 << 20      // 6 GB devices
        default: tierCeiling = 2_600 << 20                // 8 GB and larger
        }
        return max(0, min(tierCeiling, Int(Double(available) * 0.55) - headroomBytes))
    }

    var summary: String {
        "capacity \(gaussianCapacity) Gaussians, \(width)×\(height), \(intersectionCapacity) intersections, "
            + "planned \(totalBytes >> 20) MB of \(budgetBytes >> 20) MB "
            + "(model \(modelBytes >> 20), raster \(rasterBytes >> 20), tiles \(intersectionBytes >> 20), "
            + "pixels \(pixelBytes >> 20), images \(imageBytes >> 20), preview \(previewBytes >> 20))"
    }
}
