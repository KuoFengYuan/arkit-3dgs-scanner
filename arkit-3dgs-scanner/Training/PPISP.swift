// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import simd

/// GPU uniforms of one frame's ISP (mirrors `PPISPParams` in GaussianLoss.metal, 208 bytes).
nonisolated struct PPISPUniforms {
    var exposure = SIMD4<Float>(0, 1, 0, 0)
    var vignetting = (SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>())
    var vignetting2 = SIMD4<Float>()
    var homography = (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 1, 0))
    var crfTau = SIMD4<Float>(1, 1, 1, 0), crfEta = SIMD4<Float>(1, 1, 1, 0)
    var crfGamma = SIMD4<Float>(1, 1, 1, 0), crfCenter = SIMD4<Float>(0.5, 0.5, 0.5, 0)
    var crfA = SIMD4<Float>(0.5, 0.5, 0.5, 0)

    static let disabled = PPISPUniforms()
}

/// Physically-plausible ISP (PPISP) for per-image photometric compensation during training.
///
/// The model follows the PPISP formulation (nv-tlabs/ppisp, Apache-2.0) as used by LichtFeld
/// Studio: per frame, an exposure offset (EV) and a chromaticity homography from 8 latents;
/// per physical camera, per-channel radial vignetting and a camera response curve. All
/// frames of an ARKit scan come from one wide camera, so there is one camera. Parameters,
/// Adam state and regularisers live on the CPU (9 per frame + 27 per camera); the per-pixel
/// forward and backward run on the GPU. Independent Swift implementation; see
/// docs/ON_DEVICE_3DGS.md for provenance.
nonisolated struct PPISPModel: Codable, Equatable {
    static let formatVersion = 1
    static let learningRate = 2e-3
    static let regularizerScale = 1e-3
    /// Chromaticity "ZCA pinv" blocks for the blue, red, green and neutral latents.
    static let zca: [simd_double2x2] = [
        simd_double2x2(rows: [SIMD2(0.0480542, -0.0043631), SIMD2(-0.0043631, 0.0481283)]),
        simd_double2x2(rows: [SIMD2(0.0580570, -0.0179872), SIMD2(-0.0179872, 0.0431061)]),
        simd_double2x2(rows: [SIMD2(0.0433336, -0.0180537), SIMD2(-0.0180537, 0.0580500)]),
        simd_double2x2(rows: [SIMD2(0.0128369, -0.0034654), SIMD2(-0.0034654, 0.0128158)])]
    static let identityToe = log(exp(0.7) - 1)       // softplus⁻¹(0.7): tau = 0.3 + 0.7 = 1
    static let identityGamma = log(exp(0.9) - 1)     // gamma = 0.1 + 0.9 = 1

    var frames: Int
    var cameras: Int
    /// Flat parameters: exposure [F] | colour latents [F*8] | vignetting [C*15] | CRF raw [C*12].
    var parameters: [Double]
    var adamM: [Double]
    var adamV: [Double]
    var step = 0
    /// Mean EV of the capture metadata used to seed exposure; novel views use 0 EV.
    var seedMeanEV: Double?

    var exposureOffset: Int { 0 }
    var colorOffset: Int { frames }
    var vignettingOffset: Int { frames * 9 }
    var crfOffset: Int { frames * 9 + cameras * 15 }
    var count: Int { frames * 9 + cameras * 27 }

    /// Identity ISP. `captureEV[f]`: log2(exposure duration × ISO) when the capture recorded it;
    /// exposure starts at half the deviation from the mean, as LichtFeld does for EXIF.
    init(frames: Int, cameras: Int = 1, captureEV: [Double?] = []) {
        self.frames = frames
        self.cameras = cameras
        let n = frames * 9 + cameras * 27
        parameters = [Double](repeating: 0, count: n)
        adamM = parameters
        adamV = parameters
        for c in 0..<cameras { for ch in 0..<3 {
            let base = frames * 9 + cameras * 15 + c * 12 + ch * 4
            parameters[base] = Self.identityToe
            parameters[base + 1] = Self.identityToe
            parameters[base + 2] = Self.identityGamma
            parameters[base + 3] = 0
        } }
        let known = captureEV.prefix(frames).compactMap { $0 }.filter(\.isFinite)
        if !known.isEmpty {
            let mean = known.reduce(0, +) / Double(known.count)
            seedMeanEV = mean
            for (f, ev) in captureEV.prefix(frames).enumerated() {
                if let ev, ev.isFinite { parameters[f] = min(max(0.5 * (ev - mean), -16), 16) }
            }
        }
    }

    // MARK: Activations

    static func softplus(_ v: Double) -> Double { let x = min(v, 32); return max(x, 0) + log1p(exp(-abs(x))) }
    static func softplusGrad(_ v: Double) -> Double { v >= 32 ? 0 : 1 / (1 + exp(-v)) }
    static func sigmoid(_ v: Double) -> Double { 1 / (1 + exp(-v)) }

    struct CRF { var tau, eta, gamma, center, a: Double }

    func crf(camera: Int, channel: Int) -> CRF {
        let base = crfOffset + camera * 12 + channel * 4
        let tau = 0.3 + Self.softplus(parameters[base]), eta = 0.3 + Self.softplus(parameters[base + 1])
        let gamma = 0.1 + Self.softplus(parameters[base + 2])
        let center = min(max(Self.sigmoid(parameters[base + 3]), 1e-4), 1 - 1e-4)
        return CRF(tau: tau, eta: eta, gamma: gamma, center: center, a: eta * center / (tau + center * (eta - tau)))
    }

    /// Chromaticity homography from the 8 latents [b.x, b.y, r.x, r.y, g.x, g.y, n.x, n.y].
    static func homography(_ latents: ArraySlice<Double>) -> simd_double3x3 {
        let l = Array(latents)
        let sources = [SIMD2(0.0, 0.0), SIMD2(1.0, 0.0), SIMD2(0.0, 1.0), SIMD2(1.0 / 3, 1.0 / 3)]
        var targets = [SIMD3<Double>]()
        for k in 0..<4 {
            let delta = zca[k] * SIMD2(l[2 * k], l[2 * k + 1])
            targets.append(SIMD3(sources[k] + delta, 1))
        }
        let T = simd_double3x3(columns: (targets[0], targets[1], targets[2]))
        let n = targets[3]
        let skew = simd_double3x3(rows: [SIMD3(0, -n.z, n.y), SIMD3(n.z, 0, -n.x), SIMD3(-n.y, n.x, 0)])
        let M = (skew * T).transpose     // columns of the transpose are the rows of skew * T
        var lambda = simd_cross(M[0], M[1])
        if simd_length_squared(lambda) < 1e-20 { lambda = simd_cross(M[0], M[2]) }
        if simd_length_squared(lambda) < 1e-20 { lambda = simd_cross(M[1], M[2]) }
        let sInverse = simd_double3x3(rows: [SIMD3(-1, -1, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        var H = T * simd_double3x3(diagonal: lambda) * sInverse
        if abs(H[2][2]) > 1e-20 { H = H * (1 / H[2][2]) }
        return H
    }

    /// Uniforms for training frame `frame` (nil: a novel view, 0 EV and identity colour),
    /// with the frame's camera vignetting and response.
    func uniforms(frame: Int?, camera: Int = 0, exposureOffsetEV: Double = 0) -> PPISPUniforms {
        var u = PPISPUniforms()
        let ev = min(max((frame.map { parameters[exposureOffset + $0] } ?? 0) + exposureOffsetEV, -16), 16)
        u.exposure = SIMD4(Float(ev), Float(pow(2, ev)), 1, 0)
        let v = vignettingOffset + camera * 15
        func vig(_ ch: Int) -> SIMD4<Float> {
            SIMD4(Float(parameters[v + ch * 5]), Float(parameters[v + ch * 5 + 1]), Float(parameters[v + ch * 5 + 2]),
                  Float(parameters[v + ch * 5 + 3]))
        }
        u.vignetting = (vig(0), vig(1), vig(2))
        u.vignetting2 = SIMD4(Float(parameters[v + 4]), Float(parameters[v + 9]), Float(parameters[v + 14]), 0)
        let H = frame.map { Self.homography(parameters[(colorOffset + $0 * 8)..<(colorOffset + $0 * 8 + 8)]) }
            ?? matrix_identity_double3x3
        func row(_ r: Int) -> SIMD4<Float> { SIMD4(Float(H[0][r]), Float(H[1][r]), Float(H[2][r]), 0) }
        u.homography = (row(0), row(1), row(2))
        let curves = (0..<3).map { crf(camera: camera, channel: $0) }
        u.crfTau = SIMD4(curves.map { Float($0.tau) } + [0])
        u.crfEta = SIMD4(curves.map { Float($0.eta) } + [0])
        u.crfGamma = SIMD4(curves.map { Float($0.gamma) } + [0])
        u.crfCenter = SIMD4(curves.map { Float($0.center) } + [0])
        u.crfA = SIMD4(curves.map { Float($0.a) } + [0])
        return u
    }

    // MARK: Gradients

    /// Converts the 37 GPU gradient slots of one rendered frame into parameter gradients.
    func parameterGradient(frame: Int, camera: Int = 0, slots g: [Float], into grad: inout [Double]) {
        let ev = parameters[exposureOffset + frame]
        if abs(ev) < 16 { grad[exposureOffset + frame] += Double(g[0]) }
        for k in 0..<15 { grad[vignettingOffset + camera * 15 + k] += Double(g[1 + k]) }
        // Homography: dL/dlatents = J^T dL/dH, with J from central differences in double
        // precision (the construction is smooth; 16 evaluations of a 3x3 build per step).
        let base = colorOffset + frame * 8
        var latents = Array(parameters[base..<(base + 8)])
        for k in 0..<8 {
            let eps = 1e-6
            let original = latents[k]
            latents[k] = original + eps
            let plus = Self.homography(latents[0..<8])
            latents[k] = original - eps
            let minus = Self.homography(latents[0..<8])
            latents[k] = original
            var d = 0.0
            for r in 0..<3 { for c in 0..<3 { d += Double(g[16 + 3 * r + c]) * (plus[c][r] - minus[c][r]) / (2 * eps) } }
            grad[base + k] += d
        }
        for ch in 0..<3 {
            let p = crfOffset + camera * 12 + ch * 4
            grad[p] += Double(g[25 + 4 * ch]) * Self.softplusGrad(parameters[p])
            grad[p + 1] += Double(g[25 + 4 * ch + 1]) * Self.softplusGrad(parameters[p + 1])
            grad[p + 2] += Double(g[25 + 4 * ch + 2]) * Self.softplusGrad(parameters[p + 2])
            let s = Self.sigmoid(parameters[p + 3])
            if s > 1e-4 && s < 1 - 1e-4 { grad[p + 3] += Double(g[25 + 4 * ch + 3]) * s * (1 - s) }
        }
    }

    static func smoothL1Grad(_ x: Double, beta: Double) -> Double { abs(x) < beta ? x / beta : (x > 0 ? 1 : -1) }
    static func smoothL1(_ x: Double, beta: Double) -> Double { abs(x) < beta ? 0.5 * x * x / beta : abs(x) - 0.5 * beta }

    /// Regulariser loss (LichtFeld weights × 0.001) and its gradient: the across-frame means of
    /// exposure and colour stay near zero, vignetting stays centred, non-positive and similar
    /// across channels, and the response curves stay similar across channels.
    func regularizer(into grad: inout [Double]) -> Double {
        let w = Self.regularizerScale
        var loss = 0.0
        let F = Double(max(frames, 1)), C = Double(max(cameras, 1))
        if frames > 0 {
            let mean = (0..<frames).reduce(0.0) { $0 + parameters[exposureOffset + $1] } / F
            loss += w * Self.smoothL1(mean, beta: 0.1)
            let d = w * Self.smoothL1Grad(mean, beta: 0.1) / F
            for f in 0..<frames { grad[exposureOffset + f] += d }
            for k in 0..<4 {
                var u = SIMD2<Double>.zero
                for f in 0..<frames {
                    u += Self.zca[k] * SIMD2(parameters[colorOffset + f * 8 + 2 * k], parameters[colorOffset + f * 8 + 2 * k + 1])
                }
                u /= F
                loss += w / 8 * (Self.smoothL1(u.x, beta: 0.005) + Self.smoothL1(u.y, beta: 0.005))
                let g = Self.zca[k].transpose * SIMD2(Self.smoothL1Grad(u.x, beta: 0.005), Self.smoothL1Grad(u.y, beta: 0.005)) * (w / 8 / F)
                for f in 0..<frames { grad[colorOffset + f * 8 + 2 * k] += g.x; grad[colorOffset + f * 8 + 2 * k + 1] += g.y }
            }
        }
        for c in 0..<cameras {
            let v = vignettingOffset + c * 15
            for ch in 0..<3 {
                let cx = parameters[v + ch * 5], cy = parameters[v + ch * 5 + 1]
                loss += 0.02 * w * (cx * cx + cy * cy) / (3 * C)
                grad[v + ch * 5] += 0.02 * w * 2 * cx / (3 * C)
                grad[v + ch * 5 + 1] += 0.02 * w * 2 * cy / (3 * C)
                for k in 2..<5 where parameters[v + ch * 5 + k] > 0 {
                    loss += 0.01 * w * parameters[v + ch * 5 + k] / (9 * C)
                    grad[v + ch * 5 + k] += 0.01 * w / (9 * C)
                }
            }
            for k in 0..<5 {
                let values = (0..<3).map { parameters[v + $0 * 5 + k] }
                let mean = values.reduce(0, +) / 3
                loss += 0.1 * w * values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 3 / (5 * C)
                for ch in 0..<3 { grad[v + ch * 5 + k] += 0.1 * w * 2 * (values[ch] - mean) / 3 / (5 * C) }
            }
            let r = crfOffset + c * 12
            for k in 0..<4 {
                let values = (0..<3).map { parameters[r + $0 * 4 + k] }
                let mean = values.reduce(0, +) / 3
                loss += 0.1 * w * values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 3 / (4 * C)
                for ch in 0..<3 { grad[r + ch * 4 + k] += 0.1 * w * 2 * (values[ch] - mean) / 3 / (4 * C) }
            }
        }
        return loss
    }

    /// LichtFeld's schedule: linear warm-up from 1% over `warmup` steps, then exponential decay to
    /// 1% at the last iteration.
    static func learningRate(step: Int, warmup: Int, total: Int) -> Double {
        if step <= warmup { return learningRate * (0.01 + 0.99 * Double(step) / Double(max(warmup, 1))) }
        let progress = Double(step - warmup) / Double(max(total - warmup, 1))
        return learningRate * pow(0.01, min(progress, 1))
    }

    /// Dense Adam over all ISP parameters (eps 1e-15, as upstream). Non-finite values reset.
    mutating func adamStep(gradient: [Double], warmup: Int, total: Int) {
        step += 1
        let lr = Self.learningRate(step: step, warmup: warmup, total: total)
        let b1 = 0.9, b2 = 0.999
        let c1 = 1 - pow(b1, Double(step)), c2 = 1 - pow(b2, Double(step))
        for i in 0..<count {
            let g = gradient[i]
            guard g.isFinite else { continue }
            adamM[i] = b1 * adamM[i] + (1 - b1) * g
            adamV[i] = b2 * adamV[i] + (1 - b2) * g * g
            parameters[i] -= lr * (adamM[i] / c1) / ((adamV[i] / c2).squareRoot() + 1e-15)
            if !parameters[i].isFinite { parameters[i] = 0; adamM[i] = 0; adamV[i] = 0 }
        }
    }

    // MARK: Reporting

    func exposure(frame: Int) -> Double { parameters[exposureOffset + frame] }

    /// Range of the learned exposure offsets and the strongest vignetting falloff at the corner.
    var summary: (minEV: Double, maxEV: Double, cornerVignetting: Double) {
        let evs = (0..<frames).map { parameters[exposureOffset + $0] }
        var corner = 1.0
        let r2 = 0.25 + 0.14   // corner of a 4:3 image in normalised coordinates
        for ch in 0..<3 {
            let v = vignettingOffset + ch * 5
            let a = (parameters[v + 2], parameters[v + 3], parameters[v + 4])
            corner = min(corner, min(max(1 + a.0 * r2 + a.1 * r2 * r2 + a.2 * r2 * r2 * r2, 0), 1))
        }
        return (evs.min() ?? 0, evs.max() ?? 0, corner)
    }
}
