// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// Gaussian rasterizer: GPU forward against a double-precision CPU reference, and analytic GPU
// gradients (Gaussian parameters and camera pose) against central finite differences.
//
// xcrun -sdk macosx metal -std=metal3.1 -ffast-math arkit-3dgs-scanner/Training/*.metal -o /tmp/gs.metallib
// swiftc -O -module-cache-path /tmp/fable-swift-cache arkit-3dgs-scanner/Capture/Localization.swift \
//   arkit-3dgs-scanner/Training/{GaussianMetal,GaussianSorter,GaussianRasterizer}.swift \
//   tools/test_gaussian_raster.swift -o /tmp/test_gaussian_raster && /tmp/test_gaussian_raster /tmp/gs.metallib
import Foundation
import Metal
import simd

struct RefGaussian {
    var mean: SIMD3<Double>, logScale: SIMD3<Double>, quat: SIMD4<Double>, logit: Double
    var sh: [SIMD3<Double>]      // (degree + 1)^2 coefficients
    /// Pixel velocity held fixed (the GPU backward treats velocities as constant; the rolling-
    /// shutter row time still follows the splat's position).
    var frozenVelocity: SIMD2<Double>? = nil
}

struct RefCamera {
    var w2c: simd_double4x4
    var fx, fy, cx, cy: Double
    var width, height: Int
    var mip: Bool
    var omega = SIMD3<Double>(), velocity = SIMD3<Double>(), exposure = 0.0, readout = 0.0
}

enum Reference {
    static let c0 = 0.28209479177387814, c1 = 0.4886025119029199
    static let c2 = [1.0925484305920792, -1.0925484305920792, 0.31539156525252005, -1.0925484305920792, 0.5462742152960396]
    static let c3 = [-0.5900435899266435, 2.890611442640554, -0.4570457994644658, 0.3731763325901154,
                     -0.4570457994644658, 1.445305721320277, -0.5900435899266435]

    static func basis(_ d: SIMD3<Double>, degree: Int) -> [Double] {
        var b = [Double](repeating: 0, count: 16)
        b[0] = c0
        if degree < 1 { return b }
        let (x, y, z) = (d.x, d.y, d.z)
        b[1] = -c1 * y; b[2] = c1 * z; b[3] = -c1 * x
        if degree < 2 { return b }
        let (xx, yy, zz) = (x * x, y * y, z * z)
        b[4] = c2[0] * x * y; b[5] = c2[1] * y * z; b[6] = c2[2] * (2 * zz - xx - yy); b[7] = c2[3] * x * z; b[8] = c2[4] * (xx - yy)
        if degree < 3 { return b }
        b[9] = c3[0] * y * (3 * xx - yy); b[10] = c3[1] * x * y * z; b[11] = c3[2] * y * (4 * zz - xx - yy)
        b[12] = c3[3] * z * (2 * zz - 3 * xx - 3 * yy); b[13] = c3[4] * x * (4 * zz - xx - yy)
        b[14] = c3[5] * z * (xx - yy); b[15] = c3[6] * x * (xx - 3 * yy)
        return b
    }

    struct Splat { var pixel: SIMD2<Double>; var conic: SIMD3<Double>; var opacity: Double; var color: SIMD3<Double>; var depth: Double }

    static func project(_ g: RefGaussian, _ cam: RefCamera, degree: Int) -> Splat? {
        let w = cam.w2c
        let R = simd_double3x3(SIMD3(w[0][0], w[0][1], w[0][2]), SIMD3(w[1][0], w[1][1], w[1][2]), SIMD3(w[2][0], w[2][1], w[2][2]))
        let t = SIMD3(w[3][0], w[3][1], w[3][2])
        let pc = R * g.mean + t
        guard pc.z >= 0.01 else { return nil }
        let q = g.quat / simd_length(g.quat)
        let (qw, qx, qy, qz) = (q.x, q.y, q.z, q.w)
        let Rq = simd_double3x3(rows: [
            SIMD3(1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qw * qz), 2 * (qx * qz + qw * qy)),
            SIMD3(2 * (qx * qy + qw * qz), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qw * qx)),
            SIMD3(2 * (qx * qz - qw * qy), 2 * (qy * qz + qw * qx), 1 - 2 * (qx * qx + qy * qy))])
        let s = SIMD3(exp(g.logScale.x), exp(g.logScale.y), exp(g.logScale.z))
        let M = Rq * simd_double3x3(diagonal: s)
        let cov = M * M.transpose
        let W = Double(cam.width), H = Double(cam.height)
        let rx = pc.x / pc.z, ry = pc.y / pc.z
        let tx = min(max(rx, (-0.15 * W - cam.cx) / cam.fx), (1.15 * W - cam.cx) / cam.fx)
        let ty = min(max(ry, (-0.15 * H - cam.cy) / cam.fy), (1.15 * H - cam.cy) / cam.fy)
        let J = simd_double3x3(rows: [SIMD3(cam.fx / pc.z, 0, -cam.fx * tx / pc.z), SIMD3(0, cam.fy / pc.z, -cam.fy * ty / pc.z), SIMD3(0, 0, 0)])
        let T = J * R
        let c2 = T * cov * T.transpose
        let k = cam.mip ? 0.1 : 0.3
        let a = c2[0][0], b = c2[1][0], c = c2[1][1]
        let u0 = SIMD2(cam.fx * rx + cam.cx, cam.fy * ry + cam.cy)
        let (shift, blur) = motion(pc: pc, rx: tx, ry: ty, pixel: u0, cam, velocity: g.frozenVelocity)
        let f = SIMD3(a + k + blur.x, b + blur.y, c + k + blur.z)
        let base = cam.mip ? SIMD3(a, b, c) : SIMD3(a + k, b, c + k)
        let detB = max(base.x * base.z - base.y * base.y, 0), detF = f.x * f.z - f.y * f.y
        guard detF >= 1e-6 else { return nil }
        let rho = cam.mip || blur.x + blur.z > 0 ? sqrt(detB / detF) : 1
        let opacity = 1 / (1 + exp(-g.logit)) * rho
        guard opacity >= 1.0 / 255 else { return nil }
        let dir = simd_normalize(g.mean - (-(R.transpose * t)))
        let b16 = basis(dir, degree: degree)
        var rgb = SIMD3<Double>(repeating: 0.5)
        for kk in 0..<((degree + 1) * (degree + 1)) { rgb += b16[kk] * g.sh[kk] }
        return Splat(pixel: u0 + shift,
                     conic: SIMD3(f.z, -f.y, f.x) / detF, opacity: opacity,
                     color: simd_max(rgb, .zero), depth: pc.z)
    }

    /// Rolling-shutter shift and exposure-blur covariance of a camera-space centre.
    static func motion(pc: SIMD3<Double>, rx: Double, ry: Double, pixel: SIMD2<Double>, _ cam: RefCamera,
                       velocity: SIMD2<Double>? = nil) -> (SIMD2<Double>, SIMD3<Double>) {
        guard cam.exposure > 0 || cam.readout != 0 else { return (.zero, .zero) }
        let udot = velocity ?? pixelVelocity(pc: pc, rx: rx, ry: ry, cam)
        var shift = SIMD2<Double>.zero
        if cam.readout != 0 {
            let H = Double(cam.height)
            let y = (pixel.y - 0.5 * udot.y * cam.readout) / max(1 - udot.y * cam.readout / H, 0.5)
            let tau = min(max((y / H - 0.5) * cam.readout, -abs(cam.readout)), abs(cam.readout))
            shift = udot * tau
        }
        let b = udot * cam.exposure
        return (shift, SIMD3(b.x * b.x, b.x * b.y, b.y * b.y) / 12)
    }

    /// `rx`, `ry` are the frustum-clamped ratios; the speed is capped at 5% of the image per span.
    static func pixelVelocity(pc: SIMD3<Double>, rx: Double, ry: Double, _ cam: RefCamera) -> SIMD2<Double> {
        let pdot = simd_cross(cam.omega, pc) + cam.velocity
        var udot = SIMD2(cam.fx * (pdot.x - rx * pdot.z) / pc.z, cam.fy * (pdot.y - ry * pdot.z) / pc.z)
        let limit = 0.05 * Double(max(cam.width, cam.height)) / max(max(abs(cam.readout), cam.exposure), 1e-6)
        let speed = simd_length(udot)
        if speed > limit { udot *= limit / speed }
        return udot
    }

    /// Fixes each Gaussian's pixel velocity at its current state.
    static func freezeMotion(_ gs: [RefGaussian], _ cam: RefCamera) -> [RefGaussian] {
        let w = cam.w2c
        let R = simd_double3x3(SIMD3(w[0][0], w[0][1], w[0][2]), SIMD3(w[1][0], w[1][1], w[1][2]), SIMD3(w[2][0], w[2][1], w[2][2]))
        let t = SIMD3(w[3][0], w[3][1], w[3][2])
        return gs.map { g in
            var g = g
            let pc = R * g.mean + t
            let W = Double(cam.width), H = Double(cam.height)
            let tx = min(max(pc.x / pc.z, (-0.15 * W - cam.cx) / cam.fx), (1.15 * W - cam.cx) / cam.fx)
            let ty = min(max(pc.y / pc.z, (-0.15 * H - cam.cy) / cam.fy), (1.15 * H - cam.cy) / cam.fy)
            g.frozenVelocity = pixelVelocity(pc: pc, rx: tx, ry: ty, cam)
            return g
        }
    }

    /// Depth loss sum_p (lambda / z_p) sum_i w_i |z_i - z_p| over pixels with a LiDAR depth z_p > 0.
    static func depthLoss(_ gs: [RefGaussian], _ cam: RefCamera, degree: Int, lidar: [Double], lambda: Double) -> Double {
        let splats = gs.compactMap { project($0, cam, degree: degree) }.sorted { $0.depth < $1.depth }
        var total = 0.0
        for y in 0..<cam.height { for x in 0..<cam.width {
            let z = lidar[y * cam.width + x]
            guard z > 0 else { continue }
            let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
            var T = 1.0, sum = 0.0
            for s in splats {
                let d = s.pixel - p
                let power = -0.5 * (s.conic.x * d.x * d.x + s.conic.z * d.y * d.y) - s.conic.y * d.x * d.y
                if power > 0 { continue }
                let alpha = min(0.999, s.opacity * exp(power))
                if alpha < 1.0 / 255 { continue }
                let next = T * (1 - alpha)
                if next < 1e-4 { break }
                sum += alpha * T * abs(s.depth - z)
                T = next
            }
            total += lambda / z * sum
        } }
        return total
    }

    static func render(_ gs: [RefGaussian], _ cam: RefCamera, degree: Int, background: SIMD3<Double>) -> [SIMD3<Double>] {
        let splats = gs.compactMap { project($0, cam, degree: degree) }.sorted { $0.depth < $1.depth }
        var image = [SIMD3<Double>](repeating: .zero, count: cam.width * cam.height)
        for y in 0..<cam.height { for x in 0..<cam.width {
            let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
            var T = 1.0, C = SIMD3<Double>.zero
            for s in splats {
                let d = s.pixel - p
                let power = -0.5 * (s.conic.x * d.x * d.x + s.conic.z * d.y * d.y) - s.conic.y * d.x * d.y
                if power > 0 { continue }
                let alpha = min(0.999, s.opacity * exp(power))
                if alpha < 1.0 / 255 { continue }
                let next = T * (1 - alpha)
                if next < 1e-4 { break }
                C += s.color * alpha * T
                T = next
            }
            image[y * cam.width + x] = C + T * background
        } }
        return image
    }
}

@main struct GaussianRasterTests {
    static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        if !ok { print("FAIL: \(message)"); exit(1) }
        checks += 1; print("PASS: \(message)")
    }

    struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    static func scene(count: Int, degree: Int, seed: UInt64) -> [RefGaussian] {
        var r = LCG(s: seed)
        return (0..<count).map { _ in
            let q = SIMD4(r.next() - 0.5, r.next() - 0.5, r.next() - 0.5, r.next() - 0.5) + SIMD4(0.8, 0, 0, 0)
            return RefGaussian(mean: SIMD3(r.next() * 1.2 - 0.6, r.next() * 0.9 - 0.45, 2.2 + r.next() * 1.5),
                               logScale: SIMD3(log(0.04 + r.next() * 0.12), log(0.04 + r.next() * 0.12), log(0.02 + r.next() * 0.1)),
                               quat: q, logit: r.next() * 3 - 1,
                               sh: (0..<((degree + 1) * (degree + 1))).map { k in k == 0 ? SIMD3(r.next() - 0.3, r.next() - 0.3, r.next() - 0.3) * 2 : SIMD3(r.next() - 0.5, r.next() - 0.5, r.next() - 0.5) * 0.3 })
        }
    }

    static func pack(_ gs: [RefGaussian], layout: GaussianLayout, into buffer: MTLBuffer) {
        let f = buffer.contents().bindMemory(to: Float.self, capacity: layout.totalFloats)
        for (i, g) in gs.enumerated() {
            for k in 0..<3 {
                f[Int(layout.means) + 3 * i + k] = Float(g.mean[k])
                f[Int(layout.scales) + 3 * i + k] = Float(g.logScale[k])
                f[Int(layout.sh0) + 3 * i + k] = Float(g.sh[0][k])
            }
            for k in 0..<4 { f[Int(layout.quats) + 4 * i + k] = Float(g.quat[k]) }
            f[Int(layout.opacities) + i] = Float(g.logit)
            for c in 1..<(Int(layout.shRest) + 1) { for k in 0..<3 {
                f[Int(layout.shN) + i * Int(layout.shRest) * 3 + (c - 1) * 3 + k] = c < g.sh.count ? Float(g.sh[c][k]) : 0
            } }
        }
    }

    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let metal = try GaussianMetal(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let degree = 3
        let W = 56, H = 44
        let yaw = 0.08, pitch = -0.05
        let rot = simd_double3x3(simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: pitch, axis: SIMD3(1, 0, 0)))
        let w2c = simd_double4x4(columns: (SIMD4(rot[0], 0), SIMD4(rot[1], 0), SIMD4(rot[2], 0), SIMD4(0.05, -0.03, 0.1, 1)))
        let background = SIMD3<Double>(0.1, 0.2, 0.3)
        for (mip, moving, depthTerm) in [(true, false, false), (false, false, false), (true, true, false), (false, true, false), (true, false, true)] {
            var cam = RefCamera(w2c: w2c, fx: 48, fy: 47, cx: 28.3, cy: 21.7, width: W, height: H, mip: mip)
            if moving {
                // ~2 px of exposure blur and ~1 px rolling-shutter shift at this size.
                cam.omega = SIMD3(0.3, -0.5, 0.2); cam.velocity = SIMD3(0.2, 0.1, -0.15)
                cam.exposure = 0.08; cam.readout = 0.1
            }
            let label = depthTerm ? "mip \(mip), LiDAR depth loss" : moving ? "mip \(mip), capture motion" : "mip \(mip)"
            var gs = scene(count: 40, degree: degree, seed: mip ? 7 : 11)
            let capacity = 1024
            let layout = GaussianLayout(capacity: capacity, shDegree: degree)
            let model = try metal.buffer(layout.totalFloats * 4)
            let grads = try metal.buffer(layout.totalFloats * 4)
            pack(gs, layout: layout, into: model)
            var camera = GaussianCamera(worldToCamera: w2c, fx: cam.fx, fy: cam.fy, cx: cam.cx, cy: cam.cy,
                                        width: W, height: H, mipFilter: mip)
            camera.sh = SIMD4(UInt32(degree), UInt32((degree + 1) * (degree + 1)), 0, 0)
            camera.angularMotion = SIMD4(SIMD3<Float>(cam.omega), Float(cam.readout))
            camera.linearMotion = SIMD4(SIMD3<Float>(cam.velocity), Float(cam.exposure))
            let raster = try GaussianRasterizer(metal: metal, capacity: capacity, intersectionCapacity: 1 << 16,
                                                maxTiles: camera.tilesX * camera.tilesY)
            let target = try GaussianRenderTarget(metal: metal, width: W, height: H)
            // Random linear loss L = sum w_p . C_p
            var r = LCG(s: 99)
            let weights = (0..<(W * H)).map { _ in SIMD3(r.next() - 0.5, r.next() - 0.5, r.next() - 0.5) }
            let imageGrad = try metal.buffer(weights.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 0) })
            // LiDAR depths 2.5-3.9 m at full resolution, a quarter missing.
            let lidar = (0..<(W * H)).map { _ -> Double in r.next() < 0.25 ? 0 : 2.5 + 1.4 * r.next() }
            let lambda = 0.05
            let lidarBuffer = try metal.buffer(lidar.map { Float($0) })
            let depthTarget = depthTerm ? GaussianRasterizer.DepthTarget(buffer: lidarBuffer, width: W, height: H, weight: Float(lambda)) : nil
            let zeros = try metal.buffer(W * H * 4)
            let cb = metal.queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
            try raster.encodeProjection(e, camera: camera, layout: layout, model: model, count: gs.count)
            e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            let m = raster.intersectionCount
            let cb2 = metal.queue.makeCommandBuffer()!, e2 = cb2.makeComputeCommandEncoder()!
            try raster.encodeRaster(e2, camera: camera, count: gs.count, intersections: m, target: target,
                                    background: SIMD3<Float>(background))
            raster.encodeBackward(e2, camera: camera, layout: layout, model: model, grads: grads, count: gs.count,
                                  target: target, background: SIMD3<Float>(background), imageGrad: imageGrad,
                                  errorMap: zeros, edgeMap: zeros, lossSums: zeros, depth: depthTarget)
            e2.endEncoding(); cb2.commit(); cb2.waitUntilCompleted()
            let gpu = target.image.contents().bindMemory(to: SIMD4<Float>.self, capacity: W * H)
            let ref = Reference.render(gs, cam, degree: degree, background: background)
            var maxDiff = 0.0
            for i in 0..<(W * H) { maxDiff = max(maxDiff, simd_reduce_max(simd_abs(SIMD3<Double>(Double(gpu[i].x), Double(gpu[i].y), Double(gpu[i].z)) - ref[i]))) }
            print("\(label): intersections \(m), forward max |GPU - CPU| = \(maxDiff)")
            check(maxDiff < 2e-3, "forward render matches the CPU reference (\(label))")
            // Gradients treat the capture-motion shift and blur as constants.
            if moving { gs = Reference.freezeMotion(gs, cam) }

            func loss(_ gs: [RefGaussian], _ cam: RefCamera) -> Double {
                let img = Reference.render(gs, cam, degree: degree, background: background)
                let colour = zip(img, weights).reduce(0) { $0 + simd_dot($1.0, $1.1) }
                return depthTerm ? colour + Reference.depthLoss(gs, cam, degree: degree, lidar: lidar, lambda: lambda) : colour
            }
            let g = grads.contents().bindMemory(to: Float.self, capacity: layout.totalFloats)
            var worst = 0.0, compared = 0
            func compare(_ name: String, _ analytic: Float, _ perturb: (inout RefGaussian, Double) -> Void, index: Int, eps: Double) {
                func difference(_ e: Double) -> Double {
                    var plus = gs, minus = gs
                    perturb(&plus[index], e); perturb(&minus[index], -e)
                    return (loss(plus, cam) - loss(minus, cam)) / (2 * e)
                }
                func relative(_ numeric: Double) -> Double {
                    abs(numeric - Double(analytic)) / max(abs(numeric), abs(Double(analytic)), 0.05)
                }
                var numeric = difference(eps)
                var rel = relative(numeric)
                if rel > 0.05 {
                    // A pixel crossing the 1/255 alpha threshold inside the step makes the loss
                    // discontinuous (the difference grows as 1/eps); smaller steps avoid it.
                    for e in [eps / 4, eps / 16] where rel > 0.05 { numeric = difference(e); rel = relative(numeric) }
                }
                worst = max(worst, rel); compared += 1
                if rel > 0.05 { print("  \(name)[\(index)] analytic \(analytic) numeric \(numeric)") }
            }
            for i in stride(from: 0, to: gs.count, by: 3) {
                for k in 0..<3 {
                    compare("mean\(k)", g[Int(layout.means) + 3 * i + k], { $0.mean[k] += $1 }, index: i, eps: 1e-5)
                    compare("scale\(k)", g[Int(layout.scales) + 3 * i + k], { $0.logScale[k] += $1 }, index: i, eps: 1e-5)
                    compare("sh0_\(k)", g[Int(layout.sh0) + 3 * i + k], { $0.sh[0][k] += $1 }, index: i, eps: 1e-5)
                    compare("sh5_\(k)", g[Int(layout.shN) + i * 45 + 4 * 3 + k], { $0.sh[5][k] += $1 }, index: i, eps: 1e-5)
                    compare("sh13_\(k)", g[Int(layout.shN) + i * 45 + 12 * 3 + k], { $0.sh[13][k] += $1 }, index: i, eps: 1e-5)
                }
                for k in 0..<4 { compare("quat\(k)", g[Int(layout.quats) + 4 * i + k], { $0.quat[k] += $1 }, index: i, eps: 1e-5) }
                compare("opacity", g[Int(layout.opacities) + i], { $0.logit += $1 }, index: i, eps: 1e-5)
            }
            print("  compared \(compared) parameter gradients, worst relative error \(worst)")
            check(worst < 0.05, "parameter gradients match finite differences (\(label))")
            // Pose: d L / d [R|t] of the world-to-camera matrix.
            let pose = raster.poseGradient
            var poseWorst = 0.0
            for row in 0..<3 { for col in 0..<4 {
                var plus = cam, minus = cam
                let eps = 1e-6
                plus.w2c[col][row] += eps; minus.w2c[col][row] -= eps
                let numeric = (loss(gs, plus) - loss(gs, minus)) / (2 * eps)
                let analytic = Double(pose[row * 4 + col])
                let rel = abs(numeric - analytic) / max(abs(numeric), abs(analytic), 0.05)
                poseWorst = max(poseWorst, rel)
                if rel > 0.05 { print("  pose[\(row)][\(col)] analytic \(analytic) numeric \(numeric)") }
            } }
            print("  pose gradient worst relative error \(poseWorst)")
            check(poseWorst < 0.05, "camera pose gradient matches finite differences (\(label))")
            // Replaying the tiles one row per command buffer (as large images do) gives the same gradients.
            let single = Array(UnsafeBufferPointer(start: g, count: layout.totalFloats)), singlePose = pose
            let bands = GaussianRasterizer.backwardBands(tilesX: camera.tilesX, tilesY: camera.tilesY, maxTiles: camera.tilesX)
            func submit(_ body: (MTLComputeCommandEncoder) -> Void) {
                let cb = metal.queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
                body(e); e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            }
            submit { raster.encodeBackwardClear($0, count: gs.count) }
            for rows in bands {
                submit { raster.encodeBackwardBlend($0, camera: camera, layout: layout, count: gs.count, target: target,
                                                   background: SIMD3<Float>(background), imageGrad: imageGrad, errorMap: zeros,
                                                   edgeMap: zeros, lossSums: zeros, depth: depthTarget, rows: rows) }
            }
            submit { raster.encodeProjectBackward($0, camera: camera, layout: layout, model: model, grads: grads, count: gs.count) }
            let banded = Array(UnsafeBufferPointer(start: g, count: layout.totalFloats)) + raster.poseGradient
            var bandWorst: Float = 0
            for (a, b) in zip(single + singlePose, banded) { bandWorst = max(bandWorst, abs(a - b) / max(abs(a), abs(b), 1e-3)) }
            check(bands.count == camera.tilesY && bandWorst < 1e-4,
                  "banded backward pass matches the single pass (\(label), \(bands.count) bands, worst \(bandWorst))")
        }
        print("\(checks) rasterizer checks passed")
    }
}
