// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import Metal
import simd

/// Mirrors `CameraParams` in GaussianRaster.metal (160 bytes).
nonisolated struct GaussianCamera {
    var r0 = SIMD4<Float>(), r1 = SIMD4<Float>(), r2 = SIMD4<Float>()
    var intrinsics = SIMD4<Float>()
    var center = SIMD4<Float>()
    var misc = SIMD4<Float>()
    var dims = SIMD4<UInt32>()
    var sh = SIMD4<UInt32>()
    /// Capture motion of a training photo (zero = a still camera): camera-frame linear velocity
    /// (m/s) + exposure time (s), and angular velocity (rad/s) + rolling-shutter readout (s).
    var linearMotion = SIMD4<Float>()
    var angularMotion = SIMD4<Float>()

    static let tile = 16
    static let nearPlane: Float = 0.01
    /// Mip-Splatting 2D filter variance in px² with opacity compensation (LichtFeld `--enable-mip`);
    /// without compensation the standard 3DGS dilation is 0.3 px².
    static let mipFilterVariance: Float = 0.1
    static let plainDilation: Float = 0.3

    var width: Int { Int(dims.x) }
    var height: Int { Int(dims.y) }
    var tilesX: Int { Int(dims.z) }
    var tilesY: Int { Int(dims.w) }

    /// `worldToCamera` uses the OpenCV camera convention (x right, y down, z forward).
    init(worldToCamera m: simd_double4x4, fx: Double, fy: Double, cx: Double, cy: Double,
         width: Int, height: Int, mipFilter: Bool) {
        r0 = SIMD4(Float(m[0][0]), Float(m[1][0]), Float(m[2][0]), Float(m[3][0]))
        r1 = SIMD4(Float(m[0][1]), Float(m[1][1]), Float(m[2][1]), Float(m[3][1]))
        r2 = SIMD4(Float(m[0][2]), Float(m[1][2]), Float(m[2][2]), Float(m[3][2]))
        intrinsics = SIMD4(Float(fx), Float(fy), Float(cx), Float(cy))
        let r = simd_double3x3(SIMD3(m[0][0], m[0][1], m[0][2]), SIMD3(m[1][0], m[1][1], m[1][2]),
                               SIMD3(m[2][0], m[2][1], m[2][2]))
        let c = -(r.transpose * SIMD3(m[3][0], m[3][1], m[3][2]))
        center = SIMD4(Float(c.x), Float(c.y), Float(c.z), 0)
        misc = SIMD4(Self.nearPlane, mipFilter ? Self.mipFilterVariance : Self.plainDilation, mipFilter ? 1 : 0, 0)
        dims = SIMD4(UInt32(width), UInt32(height), UInt32((width + Self.tile - 1) / Self.tile),
                     UInt32((height + Self.tile - 1) / Self.tile))
    }

    /// World point at pixel (x, y) (pixel centres at +0.5) and camera depth `z` (along the
    /// optical axis, like LiDAR depth).
    func backProject(x: Float, y: Float, depth z: Float) -> SIMD3<Float> {
        let c = SIMD3((x - intrinsics.z) / intrinsics.x * z, (y - intrinsics.w) / intrinsics.y * z, z)
        let t = SIMD3(r0.w, r1.w, r2.w)
        let d = c - t
        // p_world = R^T (p_cam - t); R's rows are r0, r1, r2.
        return SIMD3(r0.x, r0.y, r0.z) * d.x + SIMD3(r1.x, r1.y, r1.z) * d.y + SIMD3(r2.x, r2.y, r2.z) * d.z
    }

    /// ARKit camera-to-world (OpenGL camera: x right, y up, -z forward), row-major, to the
    /// OpenCV world-to-camera matrix used by the rasterizer. World axes are unchanged.
    static func worldToCamera(arkitRowMajorC2W t: [Double]) -> simd_double4x4 {
        var c2w = simd_double4x4(rows: [SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                                        SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])])
        c2w.columns.1 = -c2w.columns.1
        c2w.columns.2 = -c2w.columns.2
        return rigidInverse(c2w)
    }

    static func rigidInverse(_ m: simd_double4x4) -> simd_double4x4 {
        let r = simd_double3x3(SIMD3(m[0][0], m[0][1], m[0][2]), SIMD3(m[1][0], m[1][1], m[1][2]),
                               SIMD3(m[2][0], m[2][1], m[2][2]))
        let rt = r.transpose
        let t = -(rt * SIMD3(m[3][0], m[3][1], m[3][2]))
        return simd_double4x4(columns: (SIMD4(rt[0], 0), SIMD4(rt[1], 0), SIMD4(rt[2], 0), SIMD4(t, 1)))
    }
}

/// Offsets (in floats) of each parameter block in the flat model buffer; mirrors `ModelLayout`.
nonisolated struct GaussianLayout: Equatable {
    var means: UInt32, scales: UInt32, quats: UInt32, opacities: UInt32, sh0: UInt32, shN: UInt32
    var capacity: UInt32, shRest: UInt32

    /// Floats per Gaussian for SH degree `degree`: 3 + 3 + 4 + 1 + 3 + 3 * ((d + 1)² - 1).
    static func floatsPerGaussian(shDegree degree: Int) -> Int { 14 + 3 * ((degree + 1) * (degree + 1) - 1) }

    init(capacity: Int, shDegree: Int) {
        let c = UInt32(capacity)
        let rest = UInt32((shDegree + 1) * (shDegree + 1) - 1)
        means = 0; scales = 3 * c; quats = 6 * c; opacities = 10 * c; sh0 = 11 * c; shN = 14 * c
        self.capacity = c; shRest = rest
    }

    var totalFloats: Int { Int(shN) + Int(capacity) * Int(shRest) * 3 }

    /// (offset, floats per Gaussian) of the six optimiser groups.
    var groups: [(offset: Int, width: Int)] {
        [(Int(means), 3), (Int(scales), 3), (Int(quats), 4), (Int(opacities), 1), (Int(sh0), 3), (Int(shN), Int(shRest) * 3)]
    }
}

/// Per-pixel outputs of one forward pass. Sized for `capacity` pixels; each render may use a
/// different width × height up to that capacity (preview sizes follow the view).
nonisolated final class GaussianRenderTarget: @unchecked Sendable {
    let capacity: Int
    let image: MTLBuffer          // float4: rgb, final transmittance
    let lastIndex: MTLBuffer      // uint
    let depth: MTLBuffer          // float, alpha-weighted camera depth
    var width: Int, height: Int
    var pixels: Int { width * height }

    static func bytes(width: Int, height: Int) -> Int { width * height * 24 }

    init(metal: GaussianMetal, width: Int, height: Int) throws {
        self.width = width; self.height = height
        capacity = width * height
        image = try metal.buffer(capacity * 16, label: "render-image")
        lastIndex = try metal.buffer(capacity * 4, label: "render-last")
        depth = try metal.buffer(capacity * 4, label: "render-depth")
    }
}

/// Projection, depth ordering, tile binning and blending (forward) plus their gradients.
/// Buffers are sized once for a Gaussian capacity and an intersection capacity; nothing grows
/// implicitly, so the memory plan stays an upper bound.
nonisolated final class GaussianRasterizer: @unchecked Sendable {
    enum RenderError: Error { case intersectionOverflow(needed: Int, capacity: Int) }

    let metal: GaussianMetal
    let sorter: GaussianSorter
    let capacity: Int
    let intersectionCapacity: Int
    private let project, emit, ranges, forwardBlend, backwardBlend, projectBack, clearU2, clearF, gather, iota: MTLComputePipelineState

    // Per Gaussian.
    let pixels, conics, colors, tiles, rects, depthKeys: MTLBuffer
    let order, orderScratch, depthScratch, orderedTiles, offsets: MTLBuffer
    let grad2d: MTLBuffer
    let poseGrad: MTLBuffer
    /// Placeholder LiDAR buffer when the depth loss is off.
    private let noLidar: MTLBuffer
    // Per intersection.
    let keys, values, keysScratch, valuesScratch: MTLBuffer
    private var tileRanges: MTLBuffer
    var debugRanges: MTLBuffer { tileRanges }
    private let total: MTLBuffer

    /// Bytes allocated per Gaussian of capacity, excluding the sort's temporary histogram.
    /// Floats per Gaussian of screen-space gradients and statistics: dx, dy, dA, dB, dC,
    /// dOpacity, dRGB (3), Σw, Σw·error, Σw·edge, dDepth. Mirrors `kGrad2DStride`.
    static let grad2DStride = 13
    static let bytesPerGaussian = 8 + 16 + 16 + 4 + 16 + 4 + 5 * 4 + grad2DStride * 4
    static let bytesPerIntersection = 16 + 2    // keys/values twice + radix histogram share

    init(metal: GaussianMetal, capacity: Int, intersectionCapacity: Int, maxTiles: Int) throws {
        self.metal = metal
        self.capacity = capacity
        self.intersectionCapacity = intersectionCapacity
        sorter = try GaussianSorter(metal: metal)
        project = try metal.pipeline("project_forward")
        emit = try metal.pipeline("emit_intersections")
        ranges = try metal.pipeline("tile_ranges")
        forwardBlend = try metal.pipeline("rasterize_forward")
        backwardBlend = try metal.pipeline("rasterize_backward")
        projectBack = try metal.pipeline("project_backward")
        clearU2 = try metal.pipeline("clear_uint2")
        clearF = try metal.pipeline("clear_float")
        gather = try metal.pipeline("gather_uint")
        iota = try metal.pipeline("iota_uint")
        let c = capacity
        pixels = try metal.buffer(c * 8, label: "gs-pixels")
        conics = try metal.buffer(c * 16, label: "gs-conics")
        colors = try metal.buffer(c * 16, label: "gs-colors")
        tiles = try metal.buffer(c * 4, label: "gs-tiles")
        rects = try metal.buffer(c * 16, label: "gs-rects")
        depthKeys = try metal.buffer(c * 4, label: "gs-depth-keys")
        order = try metal.buffer(c * 4, label: "gs-order")
        orderScratch = try metal.buffer(c * 4, label: "gs-order-scratch")
        depthScratch = try metal.buffer(c * 4, label: "gs-depth-scratch")
        orderedTiles = try metal.buffer(c * 4, label: "gs-ordered-tiles")
        offsets = try metal.buffer(c * 4, label: "gs-offsets")
        grad2d = try metal.buffer(c * Self.grad2DStride * 4, label: "gs-grad2d")
        noLidar = try metal.buffer(16, label: "gs-no-lidar")
        poseGrad = try metal.buffer(16 * 4, label: "gs-pose-grad")
        let m = intersectionCapacity
        keys = try metal.buffer(m * 4, label: "isect-keys")
        values = try metal.buffer(m * 4, label: "isect-values")
        keysScratch = try metal.buffer(m * 4, label: "isect-keys-scratch")
        valuesScratch = try metal.buffer(m * 4, label: "isect-values-scratch")
        tileRanges = try metal.buffer(max(1, maxTiles) * 8, label: "tile-ranges")
        total = try metal.buffer(16, label: "isect-total")
    }

    /// Stage 1: project every Gaussian, sort by depth and count tile intersections.
    /// Returns the number of intersections after the command buffer completes.
    /// The kernels stride SH coefficients by `sh.y - 1`: take it from the model's layout (never a
    /// caller's default of 0) and cap the active degree at the model's.
    static func bind(_ camera: GaussianCamera, layout: GaussianLayout, count: Int) -> GaussianCamera {
        var cam = camera
        let coefficients = layout.shRest + 1
        let degree = UInt32(Double(coefficients).squareRoot().rounded()) - 1
        cam.sh = SIMD4(min(cam.sh.x, degree), coefficients, UInt32(count), cam.sh.w)
        return cam
    }

    func encodeProjection(_ encoder: MTLComputeCommandEncoder, camera: GaussianCamera, layout: GaussianLayout,
                          model: MTLBuffer, count: Int) throws {
        let cam = Self.bind(camera, layout: layout, count: count)
        encoder.dispatch(project, threads: count, [.value(cam), .value(layout), .buffer(model), .buffer(pixels),
                                                   .buffer(conics), .buffer(colors), .buffer(tiles), .buffer(rects),
                                                   .buffer(depthKeys)])
        encoder.dispatch(iota, threads: count, [.buffer(order), .u32(UInt32(count))])
        try sorter.sortPairs(encoder, keys: depthKeys, values: order, scratchKeys: depthScratch,
                             scratchValues: orderScratch, count: count, bits: 32)
        encoder.dispatch(gather, threads: count, [.buffer(tiles), .buffer(order), .buffer(orderedTiles), .u32(UInt32(count))])
        try sorter.exclusiveScan(encoder, input: orderedTiles, output: offsets, count: count, total: total)
    }

    var intersectionCount: Int { Int(total.contents().load(as: UInt32.self)) }

    /// Clears the intersection total so an empty model reads back zero.
    func resetTotal() { total.contents().storeBytes(of: UInt32(0), as: UInt32.self) }

    /// Stage 2: bin, sort by tile and blend. `intersections` comes from stage 1.
    func encodeRaster(_ encoder: MTLComputeCommandEncoder, camera: GaussianCamera, count: Int, intersections: Int,
                      target: GaussianRenderTarget, background: SIMD3<Float>) throws {
        guard intersections <= intersectionCapacity else {
            throw RenderError.intersectionOverflow(needed: intersections, capacity: intersectionCapacity)
        }
        let tileCount = camera.tilesX * camera.tilesY
        precondition(tileCount <= 65_536 && tileRanges.length >= tileCount * 8, "tile grid exceeds the rasterizer limits")
        encoder.dispatch(clearU2, threads: tileCount, [.buffer(tileRanges), .u32(UInt32(tileCount))])
        if intersections > 0 {
            encoder.dispatch(emit, threads: count, [.buffer(order), .buffer(offsets), .buffer(rects), .buffer(tiles),
                                                    .buffer(keys), .buffer(values),
                                                    .value(SIMD4<UInt32>(UInt32(count), UInt32(camera.tilesX),
                                                                         UInt32(intersectionCapacity), 0))])
            try sorter.sortPairs(encoder, keys: keys, values: values, scratchKeys: keysScratch,
                                 scratchValues: valuesScratch, count: intersections, bits: 16)
            encoder.dispatch(ranges, threads: intersections, [.buffer(keys), .buffer(tileRanges), .u32(UInt32(intersections))])
        }
        var cam = camera
        cam.sh.z = UInt32(count)
        encoder.dispatch(forwardBlend, groups: (camera.tilesX, camera.tilesY), size: (16, 16),
                         [.value(cam), .buffer(tileRanges), .buffer(values), .buffer(pixels), .buffer(conics),
                          .buffer(colors), .buffer(target.image), .buffer(target.lastIndex),
                          .value(SIMD4<Float>(background, 0)), .buffer(target.depth)])
    }

    /// Backward through the blend and the projection. `imageGrad` is dL/d(raw rgb) (float4).
    /// LiDAR depth for the depth loss: `buffer` holds `width` × `height` depths in metres
    /// (0 = unusable) and `weight` is the loss weight per pixel.
    struct DepthTarget { var buffer: MTLBuffer; var width: Int; var height: Int; var weight: Float }

    func encodeBackward(_ encoder: MTLComputeCommandEncoder, camera: GaussianCamera, layout: GaussianLayout,
                        model: MTLBuffer, grads: MTLBuffer, count: Int, target: GaussianRenderTarget,
                        background: SIMD3<Float>, imageGrad: MTLBuffer, errorMap: MTLBuffer, edgeMap: MTLBuffer,
                        lossSums: MTLBuffer, depth: DepthTarget? = nil) {
        let cam = Self.bind(camera, layout: layout, count: count)
        encoder.dispatch(clearF, threads: count * Self.grad2DStride, [.buffer(grad2d), .u32(UInt32(count * Self.grad2DStride))])
        encoder.dispatch(clearF, threads: 16, [.buffer(poseGrad), .u32(16)])
        encoder.dispatch(backwardBlend, groups: (camera.tilesX, camera.tilesY), size: (16, 16),
                         [.value(cam), .buffer(tileRanges), .buffer(values), .buffer(pixels), .buffer(conics),
                          .buffer(colors), .buffer(target.image), .buffer(target.lastIndex),
                          .value(SIMD4<Float>(background, 0)), .buffer(imageGrad), .buffer(grad2d),
                          .buffer(errorMap), .buffer(edgeMap), .buffer(lossSums), .buffer(depth?.buffer ?? noLidar),
                          .value(depth.map { SIMD4<Float>($0.weight, Float($0.width), Float($0.height), 1) } ?? SIMD4<Float>(0, 1, 1, 0))])
        if skipProjectBackward { return }
        encoder.dispatch(projectBack, threads: count, [.value(cam), .value(layout), .buffer(model), .buffer(grad2d),
                                                       .buffer(tiles), .buffer(grads), .buffer(poseGrad)])
    }
    var skipProjectBackward = false

    /// dL/d[R|t] of the world-to-camera matrix, row-major 3x4.
    var poseGradient: [Float] {
        Array(UnsafeBufferPointer(start: poseGrad.contents().bindMemory(to: Float.self, capacity: 12), count: 12))
    }
}
