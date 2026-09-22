import Foundation
import simd

/// Known-pose, conservative patch stereo. Coordinates stay in the original sensor orientation.
/// No ARKit feature depths or LiDAR measurements enter this matcher.
nonisolated enum RGBStereoMatcher {
    struct Image: Sendable {
        let intrinsics: CameraIntrinsics
        let c2w: simd_float4x4
        let rgba: [UInt8]
        let gray: [Float]
        var width: Int { intrinsics.width }
        var height: Int { intrinsics.height }
        var center: SIMD3<Float> { SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z) }

        init?(intrinsics: CameraIntrinsics, c2w: simd_float4x4, rgba: [UInt8]) {
            guard intrinsics.width >= 8, intrinsics.height >= 8,
                  intrinsics.width <= 4096, intrinsics.height <= 4096,
                  rgba.count == intrinsics.width * intrinsics.height * 4,
                  intrinsics.fx.isFinite, intrinsics.fy.isFinite,
                  intrinsics.cx.isFinite, intrinsics.cy.isFinite,
                  intrinsics.fx > 0, intrinsics.fy > 0,
                  (0..<4).allSatisfy({ c2w[$0].x.isFinite && c2w[$0].y.isFinite && c2w[$0].z.isFinite && c2w[$0].w.isFinite }),
                  abs(simd_determinant(c2w) - 1) < 0.01 else { return nil }
            self.intrinsics = intrinsics; self.c2w = c2w; self.rgba = rgba
            gray = stride(from: 0, to: rgba.count, by: 4).map {
                (0.299 * Float(rgba[$0]) + 0.587 * Float(rgba[$0 + 1]) + 0.114 * Float(rgba[$0 + 2])) / 255
            }
        }

        @inline(__always) func sample(_ x: Float, _ y: Float) -> Float? {
            guard x.isFinite, y.isFinite, x >= 0, y >= 0,
                  x < Float(width - 1), y < Float(height - 1) else { return nil }
            let ix = Int(x), iy = Int(y), a = x - Float(ix), b = y - Float(iy)
            let i = iy * width + ix
            return (gray[i] * (1 - a) + gray[i + 1] * a) * (1 - b)
                 + (gray[i + width] * (1 - a) + gray[i + width + 1] * a) * b
        }
        func world(_ pixel: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
            let p = c2w * SIMD4((pixel.x - Float(intrinsics.cx)) / Float(intrinsics.fx) * depth,
                               (Float(intrinsics.cy) - pixel.y) / Float(intrinsics.fy) * depth, -depth, 1)
            return SIMD3(p.x, p.y, p.z)
        }
        func project(_ world: SIMD3<Float>) -> (pixel: SIMD2<Float>, depth: Float)? {
            let p = simd_inverse(c2w) * SIMD4(world, 1)
            guard p.z < -0.001 else { return nil }
            let uv = SIMD2(Float(intrinsics.fx) * p.x / -p.z + Float(intrinsics.cx),
                           Float(intrinsics.cy) - Float(intrinsics.fy) * p.y / -p.z)
            guard uv.x.isFinite, uv.y.isFinite, uv.x >= 3, uv.y >= 3,
                  uv.x < Float(width - 4), uv.y < Float(height - 4) else { return nil }
            return (uv, -p.z)
        }
    }

    struct Match {
        var depth: Float
        var cost: Float
    }

    /// ZNCC on a 5x5 patch warped by a reference-frontoparallel plane.
    /// Rejects the aperture problem, ambiguous repeats, low texture and range-boundary minima.
    static func match(reference: Image, source: Image, pixel: SIMD2<Float>, config: CaptureConfig) -> Match? {
        guard simd_distance(reference.center, source.center) >= config.cameraOnlyMinBaselineM else { return nil }
        var patch = [Float](); patch.reserveCapacity(25)
        for y in -2...2 { for x in -2...2 {
            guard let value = reference.sample(pixel.x + Float(x), pixel.y + Float(y)) else { return nil }
            patch.append(value)
        } }
        let mean = patch.reduce(0, +) / 25
        var variance: Float = 0
        for i in patch.indices { patch[i] -= mean; variance += patch[i] * patch[i] }
        guard variance / 25 >= 0.0009 else { return nil }
        var xx: Float = 0, yy: Float = 0, xy: Float = 0
        for y in 1...3 { for x in 1...3 {
            let i = y * 5 + x, gx = patch[i + 1] - patch[i - 1], gy = patch[i + 5] - patch[i - 5]
            xx += gx * gx; yy += gy * gy; xy += gx * gy
        } }
        guard xx * yy - xy * xy > 0.01 * (xx + yy) * (xx + yy) else { return nil }
        let transform = simd_inverse(source.c2w) * reference.c2w
        let k = reference.intrinsics, sk = source.intrinsics
        let ray = SIMD4((pixel.x - Float(k.cx)) / Float(k.fx), (Float(k.cy) - pixel.y) / Float(k.fy), -1, 0)
        let direction = transform * ray, origin = transform.columns.3
        let dx = transform.columns.0 / Float(k.fx), dy = -transform.columns.1 / Float(k.fy)
        func location(_ depth: Float) -> SIMD2<Float>? {
            let p = direction * depth + origin
            guard p.z < -0.001 else { return nil }
            return SIMD2(Float(sk.fx) * p.x / -p.z + Float(sk.cx), Float(sk.cy) - Float(sk.fy) * p.y / -p.z)
        }
        func cost(_ inverseDepth: Float) -> Float {
            let depth = 1 / inverseDepth
            let center = direction * depth + origin
            var sum: Float = 0, squared: Float = 0, dot: Float = 0, i = 0
            for y in -2...2 { for x in -2...2 {
                let p = center + (dx * Float(x) + dy * Float(y)) * depth
                guard p.z < -0.001,
                      let value = source.sample(Float(sk.fx) * p.x / -p.z + Float(sk.cx),
                                                Float(sk.cy) - Float(sk.fy) * p.y / -p.z) else { return .infinity }
                sum += value; squared += value * value; dot += patch[i] * value; i += 1
            } }
            let sourceVariance = max(0, squared - sum * sum / 25)
            guard sourceVariance / 25 >= 0.0009 else { return .infinity }
            return 1 - max(-1, min(1, dot / sqrt(variance * sourceVariance)))
        }
        let lo = 1 / config.pointMaxDepthM, hi = 1 / max(config.rgbMinDepthM, config.pointMinDepthM)
        guard lo.isFinite, hi.isFinite, hi > lo, lo > 0 else { return nil }
        // Keep the epipolar sampling close to one pixel; bound work even for difficult pairs.
        let span: Float
        if let a = location(1 / lo), let b = location(1 / hi) { span = simd_distance(a, b) } else { return nil }
        guard span.isFinite, span < 384 else { return nil }
        let count = max(96, min(384, Int(ceil(span * 1.5)) + 1))
        let step = (hi - lo) / Float(count - 1)
        var costs = [Float](repeating: .infinity, count: count)
        var best = 0
        for i in 0..<count {
            costs[i] = cost(lo + Float(i) * step)
            if costs[i] < costs[best] { best = i }
        }
        guard best > 0, best < count - 1, costs[best].isFinite else { return nil }
        var inverse = lo + Float(best) * step, bestCost = costs[best]
        // Refine inverse depth to reduce quantisation without inventing unsupported surfaces.
        for offset in -8...8 {
            let trial = lo + (Float(best) + Float(offset) / 8) * step
            let c = cost(trial)
            if c < bestCost { bestCost = c; inverse = trial }
        }
        guard bestCost <= 0.12, let bestLocation = location(1 / inverse) else { return nil }
        var runnerUp: Float = .infinity
        for i in 0..<count {
            let trial = lo + Float(i) * step
            guard abs(trial / inverse - 1) > 0.04,
                  let uv = location(1 / trial), simd_distance(uv, bestLocation) > 1.5 else { continue }
            runnerUp = min(runnerUp, costs[i])
        }
        guard runnerUp.isFinite, runnerUp - bestCost >= 0.06 else { return nil }
        let world = reference.world(pixel, depth: 1 / inverse)
        let a = simd_normalize(world - reference.center), b = simd_normalize(world - source.center)
        guard acos(max(-1, min(1, simd_dot(a, b)))) >= config.sparseMinParallaxDeg * .pi / 180 else { return nil }
        return Match(depth: 1 / inverse, cost: bestCost)
    }

    /// Two independent source estimates AND reverse correspondence for both must agree.
    static func reconstruct(reference: Image, sources: [Image], config: CaptureConfig) -> [CloudPoint] {
        guard sources.count == 2,
              simd_distance(sources[0].center, sources[1].center) >= config.cameraOnlyMinBaselineM else { return [] }
        var points = [CloudPoint]()
        for y in stride(from: 4, to: reference.height - 4, by: max(2, config.rgbPixelStride)) {
            for x in stride(from: 4, to: reference.width - 4, by: max(2, config.rgbPixelStride)) {
                let pixel = SIMD2<Float>(Float(x), Float(y))
                guard let a = match(reference: reference, source: sources[0], pixel: pixel, config: config),
                      let b = match(reference: reference, source: sources[1], pixel: pixel, config: config),
                      abs(a.depth - b.depth) / min(a.depth, b.depth) <= 0.04 else { continue }
                let world = reference.world(pixel, depth: 2 / (1 / a.depth + 1 / b.depth))
                var consistent = true
                for (source, estimate) in zip(sources, [a, b]) {
                    let ownWorld = reference.world(pixel, depth: estimate.depth)
                    guard let projection = source.project(world), let ownProjection = source.project(ownWorld),
                          simd_distance(projection.pixel, ownProjection.pixel) <= 0.8,
                          let reverse = match(reference: source, source: reference, pixel: projection.pixel, config: config),
                          abs(reverse.depth - projection.depth) / projection.depth <= 0.04,
                          let back = reference.project(source.world(projection.pixel, depth: reverse.depth)),
                          simd_distance(back.pixel, pixel) <= 0.8,
                          abs(back.depth - a.depth) / a.depth <= 0.04 else { consistent = false; break }
                }
                guard consistent else { continue }
                let i = (y * reference.width + x) * 4
                points.append(CloudPoint(x: world.x, y: world.y, z: world.z,
                                         r: reference.rgba[i], g: reference.rgba[i + 1], b: reference.rgba[i + 2],
                                         score: (1 - max(a.cost, b.cost)) / (0.2 + a.depth * a.depth)))
            }
        }
        return points
    }
}
