// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// Photometric loss and PPISP: GPU loss value, image gradient and ISP parameter gradients against
// a double-precision CPU reference with central finite differences.
//
// swiftc -O -module-cache-path /tmp/fable-swift-cache arkit-3dgs-scanner/Capture/Localization.swift \
//   arkit-3dgs-scanner/Training/{GaussianMetal,GaussianSorter,GaussianRasterizer,GaussianLoss,PPISP}.swift \
//   tools/test_gaussian_loss.swift -o /tmp/test_gaussian_loss && /tmp/test_gaussian_loss /tmp/gs.metallib
import Foundation
import Metal
import simd

enum CPU {
    static let window: [Double] = {
        let w: [Double] = (0..<11).map { (k: Int) -> Double in
            let d = Double(k - 5)
            return exp(-d * d / 4.5)
        }
        let s = w.reduce(0, +)
        return w.map { $0 / s }
    }()

    static func isp(_ raw: SIMD3<Double>, x: Int, y: Int, W: Int, H: Int, model: PPISPModel, frame: Int) -> SIMD3<Double> {
        let p = model.parameters
        let ev = min(max(p[frame], -16), 16)
        var v = raw * pow(2, ev)
        let norm = 1 / Double(max(W, H))
        let uv = SIMD2((Double(x) + 0.5 - 0.5 * Double(W)) * norm, (Double(y) + 0.5 - 0.5 * Double(H)) * norm)
        for ch in 0..<3 {
            let b = model.vignettingOffset + ch * 5
            let d = uv - SIMD2(p[b], p[b + 1])
            let r2 = simd_length_squared(d)
            v[ch] *= min(max(1 + p[b + 2] * r2 + p[b + 3] * r2 * r2 + p[b + 4] * r2 * r2 * r2, 0), 1)
        }
        let pos = simd_max(v, .zero)
        let I = pos.x + pos.y + pos.z
        let H3 = PPISPModel.homography(p[(model.colorOffset + frame * 8)..<(model.colorOffset + frame * 8 + 8)])
        let q = H3 * SIMD3(pos.x, pos.y, I)
        let k = I / (max(q.z, 0) + 1e-5)
        let o = k * q
        var x3 = SIMD3(o.x, o.y, o.z - o.x - o.y)
        for ch in 0..<3 {
            let c = model.crf(camera: 0, channel: ch)
            let xv = min(max(x3[ch], 0), 1)
            let yv = xv <= c.center ? c.a * pow(xv / c.center, c.tau) : 1 - (1 - c.a) * pow((1 - xv) / (1 - c.center), c.eta)
            x3[ch] = pow(max(yv, 0), c.gamma)
        }
        return x3
    }

    static func blur(_ img: [Double], W: Int, H: Int) -> [Double] {
        var h = [Double](repeating: 0, count: W * H), out = h
        for y in 0..<H { for x in 0..<W { var s = 0.0
            for k in -5...5 where x + k >= 0 && x + k < W { s += window[k + 5] * img[y * W + x + k] }
            h[y * W + x] = s } }
        for y in 0..<H { for x in 0..<W { var s = 0.0
            for k in -5...5 where y + k >= 0 && y + k < H { s += window[k + 5] * h[(y + k) * W + x] }
            out[y * W + x] = s } }
        return out
    }

    /// Loss with decoupled SSIM (luminance on ISP output, contrast-structure on raw).
    static func loss(raw: [SIMD3<Double>], gt: [SIMD3<Double>], W: Int, H: Int, model: PPISPModel?, frame: Int) -> Double {
        let ispImg = model.map { m in raw.indices.map { isp(raw[$0], x: $0 % W, y: $0 / W, W: W, H: H, model: m, frame: frame) } } ?? raw
        let border = 5, lambda = 0.2
        var l1 = 0.0, ssim = 0.0, n = 0.0
        for c in 0..<3 {
            let i = ispImg.map { $0[c] }, r = raw.map { $0[c] }, g = gt.map { $0[c] }
            let mi = blur(i, W: W, H: H), mr = blur(r, W: W, H: H), mg = blur(g, W: W, H: H)
            let rr = blur(r.map { $0 * $0 }, W: W, H: H), gg = blur(g.map { $0 * $0 }, W: W, H: H)
            let rg = blur(zip(r, g).map { $0 * $1 }, W: W, H: H)
            for y in border..<(H - border) { for x in border..<(W - border) {
                let p = y * W + x
                let l = (2 * mi[p] * mg[p] + 1e-4) / (mi[p] * mi[p] + mg[p] * mg[p] + 1e-4)
                let cs = (2 * (rg[p] - mr[p] * mg[p]) + 9e-4) / ((rr[p] - mr[p] * mr[p]) + (gg[p] - mg[p] * mg[p]) + 9e-4)
                ssim += l * cs; l1 += abs(i[p] - g[p]); if c == 0 { n += 1 }
            } }
        }
        return (1 - lambda) * l1 / (3 * n) + lambda * (1 - ssim / (3 * n))
    }
}

@main struct GaussianLossTests {
    static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        if !ok { print("FAIL: \(message)"); exit(1) }
        checks += 1; print("PASS: \(message)")
    }
    struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let metal = try GaussianMetal(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let W = 36, H = 30
        var r = LCG(s: 5)
        // Smooth-ish images so SSIM terms are well conditioned.
        let gtBytes: [SIMD4<UInt8>] = (0..<(W * H)).map { p in
            let x = Double(p % W), y = Double(p / W)
            let base = SIMD3(0.5 + 0.3 * sin(x * 0.3), 0.4 + 0.3 * cos(y * 0.25), 0.5 + 0.2 * sin((x + y) * 0.2))
            let noisy = simd_clamp(base + SIMD3(r.next(), r.next(), r.next()) * 0.1 - 0.05, .zero, SIMD3(repeating: 1))
            return SIMD4(UInt8((noisy.x * 255).rounded()), UInt8((noisy.y * 255).rounded()), UInt8((noisy.z * 255).rounded()), 255)
        }
        let gt = gtBytes.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) / 255 }
        let raw = gt.map { g in simd_clamp(g * 0.9 + SIMD3(r.next(), r.next(), r.next()) * 0.2 - 0.05, SIMD3(repeating: 0.02), SIMD3(repeating: 0.98)) }
        var model = PPISPModel(frames: 3, captureEV: [0.3, nil, -0.2])
        // Non-trivial ISP state.
        for k in 0..<model.count { model.parameters[k] += (r.next() - 0.5) * 0.2 }
        for ch in 0..<3 {
            let b = model.vignettingOffset + ch * 5
            model.parameters[b + 2] = -0.4 - 0.1 * Double(ch); model.parameters[b + 3] = 0.1; model.parameters[b + 4] = -0.05
        }
        for k in 0..<8 { model.parameters[model.colorOffset + 8 + k] = (r.next() - 0.5) * 2 }
        let frame = 1
        let evaluator = try GaussianLossEvaluator(metal: metal, width: W, height: H)
        let rawBuf = try metal.buffer(raw.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 0.3) })
        let gtBuf = try metal.buffer(gtBytes)
        for usePPISP in [false, true] {
            let cb = metal.queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
            evaluator.encode(e, raw: rawBuf, target: gtBuf, ppisp: usePPISP ? model.uniforms(frame: frame) : nil)
            e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            let values = evaluator.values
            let ref = CPU.loss(raw: raw, gt: gt, W: W, H: H, model: usePPISP ? model : nil, frame: frame)
            print("ppisp \(usePPISP): loss GPU \(values.loss) CPU \(ref)")
            check(abs(values.loss - ref) < 2e-5, "loss value matches the CPU reference (PPISP \(usePPISP))")
            let grad = evaluator.rawGrad.contents().bindMemory(to: SIMD4<Float>.self, capacity: W * H)
            var worst = 0.0
            for p in stride(from: 3, to: W * H, by: 37) { for c in 0..<3 {
                // |x| has a kink at the target value; finite differences across it are meaningless.
                if !usePPISP && abs(raw[p][c] - gt[p][c]) < 1e-4 { continue }
                var plus = raw, minus = raw
                let eps = 1e-5
                plus[p][c] += eps; minus[p][c] -= eps
                let numeric = (CPU.loss(raw: plus, gt: gt, W: W, H: H, model: usePPISP ? model : nil, frame: frame)
                               - CPU.loss(raw: minus, gt: gt, W: W, H: H, model: usePPISP ? model : nil, frame: frame)) / (2 * eps)
                let analytic = Double(grad[p][c])
                let rel = abs(numeric - analytic) / max(abs(numeric), abs(analytic), 1e-4)
                worst = max(worst, rel)
                if rel > 0.03 { print("  pixel \(p) ch \(c): analytic \(analytic) numeric \(numeric)") }
            } }
            print("  image gradient worst relative error \(worst)")
            check(worst < 0.03, "dL/d(render) matches finite differences (PPISP \(usePPISP))")
            if usePPISP {
                var g = [Double](repeating: 0, count: model.count)
                model.parameterGradient(frame: frame, slots: evaluator.ppispSlots, into: &g)
                var pworst = 0.0, compared = 0
                let indices = [model.exposureOffset + frame] + (0..<8).map { model.colorOffset + frame * 8 + $0 }
                    + (0..<15).map { model.vignettingOffset + $0 } + (0..<12).map { model.crfOffset + $0 }
                for i in indices {
                    var plus = model, minus = model
                    let eps = 1e-5
                    plus.parameters[i] += eps; minus.parameters[i] -= eps
                    let numeric = (CPU.loss(raw: raw, gt: gt, W: W, H: H, model: plus, frame: frame)
                                   - CPU.loss(raw: raw, gt: gt, W: W, H: H, model: minus, frame: frame)) / (2 * eps)
                    let rel = abs(numeric - g[i]) / max(abs(numeric), abs(g[i]), 1e-4)
                    pworst = max(pworst, rel); compared += 1
                    if rel > 0.03 { print("  ppisp param \(i): analytic \(g[i]) numeric \(numeric)") }
                }
                print("  \(compared) ISP parameter gradients, worst relative error \(pworst)")
                check(pworst < 0.03, "PPISP parameter gradients match finite differences")
            }
        }
        // Identity ISP is exactly the identity.
        let identity = PPISPModel(frames: 1)
        let u = identity.uniforms(frame: 0)
        let out = try metal.buffer(W * H * 16)
        let cb = metal.queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        evaluator.encodeISP(e, raw: rawBuf, output: out, ppisp: u)
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let o = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: W * H)
        var maxDiff: Float = 0
        for p in 0..<(W * H) { maxDiff = max(maxDiff, simd_reduce_max(simd_abs(SIMD3(o[p].x, o[p].y, o[p].z) - SIMD3(Float(raw[p].x), Float(raw[p].y), Float(raw[p].z))))) }
        print("identity ISP max deviation \(maxDiff)")
        check(maxDiff < 2e-4, "the initial PPISP state is the identity for in-range colours")
        // Regulariser gradient against finite differences.
        var g = [Double](repeating: 0, count: model.count)
        _ = model.regularizer(into: &g)
        var rworst = 0.0
        for i in 0..<model.count {
            var plus = model, minus = model
            plus.parameters[i] += 1e-6; minus.parameters[i] -= 1e-6
            var scratch = g
            let numeric = (plus.regularizer(into: &scratch) - minus.regularizer(into: &scratch)) / 2e-6
            rworst = max(rworst, abs(numeric - g[i]) / max(abs(numeric), abs(g[i]), 1e-9))
        }
        check(rworst < 1e-3, "PPISP regulariser gradient matches finite differences (worst \(rworst))")
        print("\(checks) loss and PPISP checks passed")
    }
}
