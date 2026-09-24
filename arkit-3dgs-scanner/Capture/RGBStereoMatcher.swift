import Foundation
import simd

/// Known-pose PatchMatch multi-view stereo on small RGB images. Coordinates stay in the saved
/// sensor orientation. No ARKit feature depths or LiDAR measurements enter this matcher.
///
/// Every view gets a depth and a surface normal per grid pixel from slanted-plane PatchMatch:
/// random initialisation, sequential propagation from already visited neighbours, and random
/// refinement with shrinking steps. The photo cost is the mean of the best source views'
/// bilateral-weighted ZNCC, so one occluded source does not veto a visible surface. A depth is
/// kept only where neighbouring depth maps independently reach the same surface.
nonisolated enum RGBStereoMatcher {
    /// Grayscale intensities in 0...1 with unchecked reads for the matching loops. Immutable.
    final class Plane: @unchecked Sendable {
        let width: Int, height: Int
        let values: UnsafeMutableBufferPointer<Float>

        init(width: Int, height: Int, rgba: [UInt8]) {
            self.width = width; self.height = height
            values = .allocate(capacity: width * height)
            for i in 0..<(width * height) {
                values[i] = (0.299 * Float(rgba[i * 4]) + 0.587 * Float(rgba[i * 4 + 1]) + 0.114 * Float(rgba[i * 4 + 2])) / 255
            }
        }
        deinit { values.deallocate() }
    }

    struct Image: Sendable {
        let intrinsics: CameraIntrinsics
        let c2w: simd_float4x4
        let rgba: [UInt8]
        let plane: Plane
        var width: Int { intrinsics.width }
        var height: Int { intrinsics.height }
        var center: SIMD3<Float> { SIMD3(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z) }
        var forward: SIMD3<Float> { -SIMD3(c2w.columns.2.x, c2w.columns.2.y, c2w.columns.2.z) }

        init?(intrinsics: CameraIntrinsics, c2w: simd_float4x4, rgba: [UInt8]) {
            guard intrinsics.width >= 16, intrinsics.height >= 16,
                  intrinsics.width <= 4096, intrinsics.height <= 4096,
                  rgba.count == intrinsics.width * intrinsics.height * 4,
                  intrinsics.fx.isFinite, intrinsics.fy.isFinite,
                  intrinsics.cx.isFinite, intrinsics.cy.isFinite,
                  intrinsics.fx > 0, intrinsics.fy > 0,
                  (0..<4).allSatisfy({ c2w[$0].x.isFinite && c2w[$0].y.isFinite && c2w[$0].z.isFinite && c2w[$0].w.isFinite }),
                  abs(simd_determinant(c2w) - 1) < 0.01 else { return nil }
            self.intrinsics = intrinsics; self.c2w = c2w; self.rgba = rgba
            plane = Plane(width: intrinsics.width, height: intrinsics.height, rgba: rgba)
        }

        /// ARKit convention: -Z forward, +Y up, v grows downward.
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

    /// Pinhole camera in computer-vision axes (x right, y down, z forward).
    struct Camera {
        let fx: Float, fy: Float, cx: Float, cy: Float
        let toWorld: simd_float3x3, toCamera: simd_float3x3
        let center: SIMD3<Float>

        init(_ image: Image) {
            let k = image.intrinsics, m = image.c2w
            fx = Float(k.fx); fy = Float(k.fy); cx = Float(k.cx); cy = Float(k.cy)
            toWorld = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                    -SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                    -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            toCamera = toWorld.transpose
            center = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        var k: simd_float3x3 { simd_float3x3(SIMD3(fx, 0, 0), SIMD3(0, fy, 0), SIMD3(cx, cy, 1)) }
        var kInverse: simd_float3x3 {
            simd_float3x3(SIMD3(1 / fx, 0, 0), SIMD3(0, 1 / fy, 0), SIMD3(-cx / fx, -cy / fy, 1))
        }
        @inline(__always) func ray(_ pixel: SIMD2<Float>) -> SIMD3<Float> {
            SIMD3((pixel.x - cx) / fx, (pixel.y - cy) / fy, 1)
        }
        @inline(__always) func pixel(_ camera: SIMD3<Float>) -> SIMD2<Float> {
            SIMD2(fx * camera.x / camera.z + cx, fy * camera.y / camera.z + cy)
        }
    }

    /// Depths on a regular pixel grid of one view. 0 marks pixels without a reliable estimate.
    struct DepthMap: Sendable {
        let columns: Int, rows: Int, stride: Int, margin: Int
        var depth: [Float]
        var cost: [Float]
        var normal: [SIMD3<Float>]

        @inline(__always) func pixel(_ index: Int) -> SIMD2<Float> {
            SIMD2(Float(margin + (index % columns) * stride), Float(margin + (index / columns) * stride))
        }
        @inline(__always) func nearest(_ pixel: SIMD2<Float>) -> Int? {
            let c = ((pixel.x - Float(margin)) / Float(stride)).rounded()
            let r = ((pixel.y - Float(margin)) / Float(stride)).rounded()
            guard c >= 0, r >= 0, c < Float(columns), r < Float(rows) else { return nil }
            return Int(r) * columns + Int(c)
        }
    }

    struct Statistics: Sendable {
        var texturedPixels = 0
        var photoConsistentPixels = 0
        var geometricallyConsistentPixels = 0
    }

    // MARK: - Matching kernel

    /// Reference → source geometry without object references, so the hot loop has no ARC traffic.
    private struct Source {
        let values: UnsafePointer<Float>
        let width: Int
        let maxX: Float, maxY: Float
        let rotation: simd_float3x3
        let translation: SIMD3<Float>
        let k: simd_float3x3
        let center: SIMD3<Float>   // source camera centre in reference camera axes
    }

    static let windowRadius = 2      // 5×5 samples ...
    static let windowStep = 2        // ... two pixels apart: a 9×9 footprint
    private static let samples = (2 * windowRadius + 1) * (2 * windowRadius + 1)
    private static let invalidCost: Float = 2

    private struct Patch {
        var centered = [Float](repeating: 0, count: RGBStereoMatcher.samples)  // w·(r − mean)
        var weights = [Float](repeating: 0, count: RGBStereoMatcher.samples)
        var weightSum: Float = 0
        var variance: Float = 0                                                // Σ w·(r − mean)²
    }

    /// Bilateral weights keep a foreground edge from dragging the background's depth along.
    private static func preparePatch(_ patch: inout Patch, plane: Plane, x: Int, y: Int, spatial: [Float]) {
        let w = plane.width, values = plane.values
        let center = values[y * w + x]
        var sum: Float = 0, weightSum: Float = 0, k = 0
        for j in -windowRadius...windowRadius {
            let row = (y + j * windowStep) * w
            for i in -windowRadius...windowRadius {
                let value = values[row + x + i * windowStep], d = value - center
                let weight = spatial[k] * exp(-d * d * 50)       // σ_colour = 0.1
                patch.weights[k] = weight; patch.centered[k] = value
                sum += weight * value; weightSum += weight; k += 1
            }
        }
        let mean = sum / weightSum
        var variance: Float = 0
        for k in 0..<samples {
            let d = patch.centered[k] - mean
            patch.centered[k] = patch.weights[k] * d
            variance += patch.weights[k] * d * d
        }
        patch.weightSum = weightSum; patch.variance = variance
    }

    /// Weighted ZNCC cost (1 − NCC, 0...2) of plane (depth, normal) at pixel in one source.
    @inline(__always)
    private static func sourceCost(_ source: Source, homography h: simd_float3x3, pixel: SIMD2<Float>,
                                   patch: UnsafePointer<Float>, weights: UnsafePointer<Float>,
                                   weightSum: Float, variance: Float) -> Float {
        let step = Float(windowStep), radius = Float(windowRadius)
        let dx = h.columns.0 * step, dy = h.columns.1 * step
        var rowStart = h.columns.0 * (pixel.x - radius * step) + h.columns.1 * (pixel.y - radius * step) + h.columns.2
        var s1: Float = 0, s2: Float = 0, cross: Float = 0, k = 0
        let values = source.values, width = source.width
        for _ in 0...(2 * windowRadius) {
            var q = rowStart
            for _ in 0...(2 * windowRadius) {
                guard q.z > 1e-6 else { return invalidCost }
                let inverse = 1 / q.z, u = q.x * inverse, v = q.y * inverse
                guard u >= 0, v >= 0, u < source.maxX, v < source.maxY else { return invalidCost }
                let ix = Int(u), iy = Int(v), a = u - Float(ix), b = v - Float(iy)
                let i = iy * width + ix
                let top = values[i] + (values[i + 1] - values[i]) * a
                let bottom = values[i + width] + (values[i + width + 1] - values[i + width]) * a
                let value = top + (bottom - top) * b
                let weight = weights[k]
                s1 += weight * value; s2 += weight * value * value; cross += patch[k] * value
                q += dx; k += 1
            }
            rowStart += dy
        }
        let sourceVariance = s2 - s1 * s1 / weightSum
        guard sourceVariance > 1e-5 * weightSum else { return invalidCost }
        return 1 - max(-1, min(1, cross / (variance * sourceVariance).squareRoot()))
    }

    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
        mutating func signed() -> Float { unit() * 2 - 1 }
        mutating func direction() -> SIMD3<Float> {
            let z = signed(), angle = unit() * 2 * .pi, r = max(0, 1 - z * z).squareRoot()
            return SIMD3(r * cos(angle), r * sin(angle), z)
        }
    }

    /// Slanted-plane PatchMatch depth for `reference` against `sources` (at least two).
    static func depthMap(reference: Image, sources: [Image], config: CaptureConfig, seed: UInt64,
                         statistics: inout Statistics) -> DepthMap? {
        let camera = Camera(reference)
        let minDepth = max(config.rgbMinDepthM, config.pointMinDepthM), maxDepth = config.pointMaxDepthM
        guard minDepth > 0, maxDepth > minDepth else { return nil }
        let usable = sources.filter { simd_distance($0.center, reference.center) >= config.cameraOnlyMinBaselineM }
        guard usable.count >= 2 else { return nil }
        let stride = max(1, config.rgbPixelStride), margin = windowRadius * windowStep + 1
        let columns = (reference.width - 2 * margin + stride - 1) / stride
        let rows = (reference.height - 2 * margin + stride - 1) / stride
        guard columns >= 3, rows >= 3 else { return nil }
        let count = columns * rows
        var map = DepthMap(columns: columns, rows: rows, stride: stride, margin: margin,
                           depth: [Float](repeating: 0, count: count), cost: [Float](repeating: invalidCost, count: count),
                           normal: [SIMD3<Float>](repeating: SIMD3(0, 0, -1), count: count))
        let kInverse = camera.kInverse
        let geometry = usable.map { source -> Source in
            let s = Camera(source)
            let rotation = s.toCamera * camera.toWorld
            return Source(values: UnsafePointer(source.plane.values.baseAddress!), width: source.width,
                          maxX: Float(source.width - 1), maxY: Float(source.height - 1),
                          rotation: rotation, translation: s.toCamera * (camera.center - s.center), k: s.k,
                          center: camera.toCamera * (s.center - camera.center))
        }
        let best = min(geometry.count, max(2, (geometry.count + 1) / 2))
        let plane = reference.plane
        let minVariance = config.rgbMinPatchStd * config.rgbMinPatchStd

        // Texture: enough contrast and gradients in two directions (no aperture problem).
        var spatial = [Float](), active = [Bool](repeating: false, count: count)
        for j in -windowRadius...windowRadius { for i in -windowRadius...windowRadius {
            let d = Float(i * i + j * j) * Float(windowStep * windowStep)
            spatial.append(exp(-d / Float(2 * 9)))                       // σ_spatial = 3 px
        } }
        let w = plane.width, values = plane.values
        for index in 0..<count {
            let x = margin + (index % columns) * stride, y = margin + (index / columns) * stride
            var sum: Float = 0, squared: Float = 0, xx: Float = 0, yy: Float = 0, xy: Float = 0
            for j in -windowRadius...windowRadius { for i in -windowRadius...windowRadius {
                let p = (y + j * windowStep) * w + x + i * windowStep, v = values[p]
                let gx = values[p + 1] - values[p - 1], gy = values[p + w] - values[p - w]
                sum += v; squared += v * v; xx += gx * gx; yy += gy * gy; xy += gx * gy
            } }
            let n = Float(samples), variance = squared / n - (sum / n) * (sum / n)
            active[index] = variance >= minVariance && xx * yy - xy * xy > 0.01 * (xx + yy) * (xx + yy)
        }

        var random = Random(state: seed)
        var patch = Patch()
        var costs = [Float](repeating: 0, count: geometry.count)
        let invMin = 1 / maxDepth, invMax = 1 / minDepth, invRange = invMax - invMin

        func evaluate(_ depth: Float, _ normal: SIMD3<Float>, _ pixel: SIMD2<Float>, _ ray: SIMD3<Float>) -> Float {
            let point = ray * depth, offset = simd_dot(normal, point)
            guard offset < -1e-6 else { return invalidCost }
            return patch.centered.withUnsafeBufferPointer { centered in
                patch.weights.withUnsafeBufferPointer { weights in
                    for s in geometry.indices {
                        let g = geometry[s]
                        let n = normal / offset
                        let a = g.rotation + simd_float3x3(g.translation * n.x, g.translation * n.y, g.translation * n.z)
                        costs[s] = sourceCost(g, homography: g.k * a * kInverse, pixel: pixel,
                                              patch: centered.baseAddress!, weights: weights.baseAddress!,
                                              weightSum: patch.weightSum, variance: patch.variance)
                    }
                    // Mean of the best `best` sources; a small insertion sort (few sources).
                    for i in 1..<costs.count {
                        let value = costs[i]; var j = i - 1
                        while j >= 0, costs[j] > value { costs[j + 1] = costs[j]; j -= 1 }
                        costs[j + 1] = value
                    }
                    var total: Float = 0
                    for i in 0..<best { total += costs[i] }
                    return total / Float(best)
                }
            }
        }
        @inline(__always) func facing(_ normal: SIMD3<Float>, _ ray: SIMD3<Float>) -> Bool {
            simd_dot(normal, ray) < -0.26 * simd_length(ray)             // within 75° of the view ray
        }
        func randomNormal(_ ray: SIMD3<Float>) -> SIMD3<Float> {
            for _ in 0..<4 {
                var n = random.direction()
                if simd_dot(n, ray) > 0 { n = -n }
                if facing(n, ray) { return n }
            }
            return -simd_normalize(ray)
        }

        // Random initialisation.
        for index in 0..<count where active[index] {
            let pixel = map.pixel(index), ray = camera.ray(pixel)
            preparePatch(&patch, plane: plane, x: Int(pixel.x), y: Int(pixel.y), spatial: spatial)
            let depth = 1 / (invMin + random.unit() * invRange), normal = randomNormal(ray)
            map.depth[index] = depth; map.normal[index] = normal
            map.cost[index] = evaluate(depth, normal, pixel, ray)
        }
        let iterations = max(1, config.rgbPatchMatchIterations)
        for iteration in 0..<iterations {
            let forward = iteration % 2 == 0, scale = pow(0.5, Float(iteration))
            let neighbors = forward ? [(-1, 0), (0, -1), (-1, -1), (1, -1)] : [(1, 0), (0, 1), (1, 1), (-1, 1)]
            for step in 0..<count {
                let index = forward ? step : count - 1 - step
                guard active[index] else { continue }
                let column = index % columns, row = index / columns
                let pixel = map.pixel(index), ray = camera.ray(pixel)
                preparePatch(&patch, plane: plane, x: Int(pixel.x), y: Int(pixel.y), spatial: spatial)
                var depth = map.depth[index], normal = map.normal[index], cost = map.cost[index]
                func consider(_ d: Float, _ n: SIMD3<Float>) {
                    guard d >= minDepth, d <= maxDepth, facing(n, ray) else { return }
                    let c = evaluate(d, n, pixel, ray)
                    if c < cost { cost = c; depth = d; normal = n }
                }
                // Propagation: the neighbour's plane, intersected with this pixel's ray.
                for (dc, dr) in neighbors {
                    let c = column + dc, r = row + dr
                    guard c >= 0, r >= 0, c < columns, r < rows else { continue }
                    let neighbor = r * columns + c
                    guard active[neighbor] else { continue }
                    let n = map.normal[neighbor]
                    let point = camera.ray(map.pixel(neighbor)) * map.depth[neighbor]
                    let denominator = simd_dot(n, ray)
                    guard denominator < -1e-6 else { continue }
                    consider(simd_dot(n, point) / denominator, n)
                }
                // Refinement: coarse and fine depth steps, normal perturbation, and both.
                let coarse = 1 / min(invMax, max(invMin, 1 / depth + invRange * 0.25 * scale * random.signed()))
                consider(coarse, normal)
                let fine = depth * (1 + 0.03 * scale * random.signed())
                consider(fine, normal)
                let tilted = simd_normalize(normal + random.direction() * (0.4 * scale))
                consider(depth, tilted)
                consider(depth * (1 + 0.01 * scale * random.signed()),
                         simd_normalize(normal + random.direction() * (0.15 * scale)))
                if iteration == 0 { consider(1 / (invMin + random.unit() * invRange), randomNormal(ray)) }
                map.depth[index] = depth; map.normal[index] = normal; map.cost[index] = cost
            }
        }

        // Photo acceptance: cost, and at least two sources that match with enough parallax.
        let minParallax = cos(config.sparseMinParallaxDeg * .pi / 180)
        for index in 0..<count {
            guard active[index] else { map.depth[index] = 0; continue }
            statistics.texturedPixels += 1
            let pixel = map.pixel(index), ray = camera.ray(pixel)
            preparePatch(&patch, plane: plane, x: Int(pixel.x), y: Int(pixel.y), spatial: spatial)
            let depth = map.depth[index], normal = map.normal[index]
            guard map.cost[index] <= config.rgbMaxMatchCost else { map.depth[index] = 0; continue }
            let point = ray * depth, offset = simd_dot(normal, point)
            var supported = 0
            if offset < -1e-6 {
                patch.centered.withUnsafeBufferPointer { centered in
                    patch.weights.withUnsafeBufferPointer { weights in
                        for g in geometry {
                            let n = normal / offset
                            let a = g.rotation + simd_float3x3(g.translation * n.x, g.translation * n.y, g.translation * n.z)
                            let c = sourceCost(g, homography: g.k * a * kInverse, pixel: pixel,
                                               patch: centered.baseAddress!, weights: weights.baseAddress!,
                                               weightSum: patch.weightSum, variance: patch.variance)
                            let angle = simd_dot(simd_normalize(point), simd_normalize(point - g.center))
                            if c <= config.rgbMaxMatchCost, angle <= minParallax { supported += 1 }
                        }
                    }
                }
            }
            if supported >= 2 { statistics.photoConsistentPixels += 1 } else { map.depth[index] = 0 }
        }
        // Consistency checks need depths only; release the normals of stored maps.
        map.normal = []
        return map
    }

    // MARK: - Multi-view consistency

    /// Points of `maps[index]` that at least `rgbConsistentViews` neighbouring maps confirm:
    /// the neighbour's depth at the projection must reproject within a few pixels and 1% depth.
    static func consistentPoints(index: Int, views: [Image], maps: [DepthMap?], neighbors: [Int],
                                 config: CaptureConfig, statistics: inout Statistics) -> [CloudPoint] {
        guard let map = maps[index] else { return [] }
        let view = views[index], camera = Camera(view)
        let others = neighbors.compactMap { m -> (Camera, DepthMap)? in maps[m].map { (Camera(views[m]), $0) } }
        let required = max(1, config.rgbConsistentViews)
        guard others.count >= required else { return [] }
        let pixelTolerance = Float(map.stride) + 1, ratio = config.rgbConsistencyDepthRatio
        var points = [CloudPoint]()
        for i in 0..<map.depth.count {
            let depth = map.depth[i]
            guard depth > 0 else { continue }
            let pixel = map.pixel(i)
            let world = camera.toWorld * (camera.ray(pixel) * depth) + camera.center
            var sum = world, agreeing = 0
            for (other, otherMap) in others {
                let local = other.toCamera * (world - other.center)
                guard local.z > 0, let j = otherMap.nearest(other.pixel(local)) else { continue }
                let otherDepth = otherMap.depth[j]
                guard otherDepth > 0 else { continue }
                let back = other.toWorld * (other.ray(otherMap.pixel(j)) * otherDepth) + other.center
                let reprojected = camera.toCamera * (back - camera.center)
                guard reprojected.z > 0, abs(reprojected.z - depth) <= ratio * depth,
                      simd_distance(camera.pixel(reprojected), pixel) <= pixelTolerance else { continue }
                sum += back; agreeing += 1
            }
            guard agreeing >= required else { continue }
            let fused = sum / Float(agreeing + 1)
            let x = Int(pixel.x), y = Int(pixel.y), c = (y * view.width + x) * 4
            let cost = map.cost[i]
            points.append(CloudPoint(x: fused.x, y: fused.y, z: fused.z,
                                     r: view.rgba[c], g: view.rgba[c + 1], b: view.rgba[c + 2],
                                     score: (1 - min(1, cost)) * Float(agreeing) / (0.2 + depth * depth)))
        }
        statistics.geometricallyConsistentPixels += points.count
        return points
    }

    /// All views against each other: depth maps, then each view's confirmed points.
    /// Each map depends only on its own view, sources and seed, so results do not depend on
    /// thread scheduling.
    static func reconstruct(views: [Image], sources: [[Int]], config: CaptureConfig, seeds: [UInt64],
                            isCancelled: @Sendable () -> Bool = { false },
                            progress: @Sendable (Double) -> Void = { _ in }) -> (points: [[CloudPoint]], maps: [DepthMap?], statistics: Statistics) {
        precondition(views.count == sources.count && views.count == seeds.count)
        let maps = Slots<DepthMap?>(repeating: nil, count: views.count)
        let statistics = Slots<Statistics>(repeating: Statistics(), count: views.count)
        let done = Counter()
        DispatchQueue.concurrentPerform(iterations: views.count) { i in
            guard !isCancelled() else { return }
            var local = Statistics()
            let map = depthMap(reference: views[i], sources: sources[i].map { views[$0] }, config: config,
                               seed: seeds[i], statistics: &local)
            maps.set(i, map); statistics.set(i, local)
            progress(Double(done.next()) / Double(views.count) * 0.9)
        }
        guard !isCancelled() else { return (Array(repeating: [], count: views.count), maps.values, Statistics()) }
        // A map is checked against its sources and against the views that used it as a source.
        var neighbors = sources.map { Set($0) }
        for (i, list) in sources.enumerated() { for s in list { neighbors[s].insert(i) } }
        let lists = neighbors.map { $0.sorted() }
        let snapshot = maps.values
        let points = Slots<[CloudPoint]>(repeating: [], count: views.count)
        DispatchQueue.concurrentPerform(iterations: views.count) { i in
            var local = statistics.values[i]
            points.set(i, consistentPoints(index: i, views: views, maps: snapshot, neighbors: lists[i],
                                           config: config, statistics: &local))
            statistics.set(i, local)
        }
        var total = Statistics()
        for s in statistics.values {
            total.texturedPixels += s.texturedPixels
            total.photoConsistentPixels += s.photoConsistentPixels
            total.geometricallyConsistentPixels += s.geometricallyConsistentPixels
        }
        progress(1)
        return (points.values, snapshot, total)
    }

    /// One slot per concurrent worker, guarded by a lock.
    final class Slots<T>: @unchecked Sendable {
        private var storage: [T]
        private let lock = NSLock()
        init(repeating value: T, count: Int) { storage = Array(repeating: value, count: count) }
        func set(_ index: Int, _ value: T) { lock.lock(); storage[index] = value; lock.unlock() }
        var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Completed-work counter for progress reports.
    final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    /// Reference plus sources, each matched against the others; returns the reference's points.
    static func reconstruct(reference: Image, sources: [Image], config: CaptureConfig) -> [CloudPoint] {
        let views = [reference] + sources
        let lists = views.indices.map { i in views.indices.filter { $0 != i } }
        return reconstruct(views: views, sources: lists, config: config,
                           seeds: views.indices.map { UInt64($0 + 1) }).points[0]
    }
}
