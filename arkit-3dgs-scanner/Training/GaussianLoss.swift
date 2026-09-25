// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import Metal

/// Mirrors `LossParams` in GaussianLoss.metal.
nonisolated struct GaussianLossParams {
    var width: UInt32, height: UInt32, border: UInt32, decoupled: UInt32
    var lambda: Float, invInterior: Float, unused0: Float = 0, unused1: Float = 0

    init(width: Int, height: Int, lambda: Float, decoupled: Bool) {
        self.width = UInt32(width); self.height = UInt32(height)
        let border = width > 10 && height > 10 ? 5 : 0
        self.border = UInt32(border)
        self.decoupled = decoupled ? 1 : 0
        self.lambda = lambda
        invInterior = 1 / Float(max(1, (width - 2 * border) * (height - 2 * border)))
    }
}

/// L1 + D-SSIM loss, the MRNF error map and PPISP on one training image, with gradients.
nonisolated final class GaussianLossEvaluator: @unchecked Sendable {
    static let lambda: Float = 0.2
    let width: Int, height: Int
    let isp, ispGrad, rawGrad, errorMap, sums, ppispGrad: MTLBuffer
    private let partials: MTLBuffer
    private let ppispForward, ppispBackward, forward, backward, clear: MTLComputePipelineState

    /// Bytes per pixel: isp, ispGrad, rawGrad (float4 each), error map, 12 SSIM partial planes.
    static let bytesPerPixel = 16 * 3 + 4 + 12 * 4

    init(metal: GaussianMetal, width: Int, height: Int) throws {
        self.width = width; self.height = height
        let p = width * height
        isp = try metal.buffer(p * 16, label: "loss-isp")
        ispGrad = try metal.buffer(p * 16, label: "loss-isp-grad")
        rawGrad = try metal.buffer(p * 16, label: "loss-raw-grad")
        errorMap = try metal.buffer(p * 4, label: "loss-error")
        partials = try metal.buffer(p * 12 * 4, label: "ssim-partials")
        sums = try metal.buffer(16, label: "loss-sums")
        ppispGrad = try metal.buffer(40 * 4, label: "ppisp-grad")
        ppispForward = try metal.pipeline("ppisp_forward")
        ppispBackward = try metal.pipeline("ppisp_backward")
        forward = try metal.pipeline("ssim_forward")
        backward = try metal.pipeline("ssim_backward")
        clear = try metal.pipeline("clear_float")
    }

    private var groups: (Int, Int) { ((width + 15) / 16, (height + 15) / 16) }

    /// Applies the ISP to `raw` (float4 per pixel) into `isp`; used for loss and preview.
    func encodeISP(_ encoder: MTLComputeCommandEncoder, raw: MTLBuffer, output: MTLBuffer, ppisp: PPISPUniforms) {
        encoder.dispatch(ppispForward, groups: groups, size: (16, 16),
                         [.buffer(raw), .buffer(output), .value(ppisp), .value(SIMD2<UInt32>(UInt32(width), UInt32(height)))])
    }

    /// Forward and backward of the loss. Afterwards `rawGrad` holds dL/d(raw render),
    /// `errorMap` the unnormalised error, `sums` [L1 sum, SSIM sum, error sum, squared error sum]
    /// and `ppispGrad` the 37 ISP gradient slots (when `ppisp` is enabled).
    func encode(_ encoder: MTLComputeCommandEncoder, raw: MTLBuffer, target: MTLBuffer, ppisp: PPISPUniforms?) {
        let usesISP = ppisp != nil
        let params = GaussianLossParams(width: width, height: height, lambda: Self.lambda, decoupled: usesISP)
        encoder.dispatch(clear, threads: 4, [.buffer(sums), .u32(4)])
        encoder.dispatch(clear, threads: 40, [.buffer(ppispGrad), .u32(40)])
        let ispImage: MTLBuffer
        if let ppisp { encodeISP(encoder, raw: raw, output: isp, ppisp: ppisp); ispImage = isp } else { ispImage = raw }
        encoder.dispatch(forward, groups: groups, size: (16, 16),
                         [.buffer(ispImage), .buffer(raw), .buffer(target), .buffer(partials), .buffer(errorMap),
                          .buffer(sums), .value(params)])
        encoder.dispatch(backward, groups: groups, size: (16, 16),
                         [.buffer(partials), .buffer(ispImage), .buffer(raw), .buffer(target), .buffer(ispGrad),
                          .buffer(rawGrad), .value(params)])
        if let ppisp {
            encoder.dispatch(ppispBackward, groups: groups, size: (16, 16),
                             [.buffer(raw), .buffer(ispGrad), .buffer(rawGrad), .buffer(ppispGrad), .value(ppisp),
                              .value(SIMD2<UInt32>(UInt32(width), UInt32(height)))])
        }
    }

    struct Values { var loss: Double; var l1: Double; var ssim: Double; var psnr: Double }

    /// Loss terms of the last `encode` (read after the command buffer completes).
    var values: Values {
        let s = sums.contents().bindMemory(to: Float.self, capacity: 4)
        let p = GaussianLossParams(width: width, height: height, lambda: Self.lambda, decoupled: false)
        let interior = Double(1 / p.invInterior)
        let l1 = Double(s[0]) / (interior * 3), ssim = Double(s[1]) / (interior * 3)
        let mse = Double(s[3]) / Double(width * height * 3)
        let lambda = Double(Self.lambda)
        return Values(loss: (1 - lambda) * l1 + lambda * (1 - ssim), l1: l1, ssim: ssim,
                      psnr: mse > 0 ? -10 * log10(mse) : 99)
    }

    var ppispSlots: [Float] {
        Array(UnsafeBufferPointer(start: ppispGrad.contents().bindMemory(to: Float.self, capacity: 37), count: 37))
    }
}
