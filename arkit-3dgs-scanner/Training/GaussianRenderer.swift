// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import Metal
import CoreGraphics
import simd

/// An RGBA8 frame of the Gaussian model.
nonisolated struct RenderedFrame: @unchecked Sendable {
    let width: Int
    let height: Int
    let pixels: Data

    var cgImage: CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// How the viewer applies PPISP. Training views use their learned exposure and colour; any other
/// view uses the neutral ISP (0 EV, identity colour, learned camera vignetting and response),
/// like LichtFeld Studio without the optional controller. `off` shows the pre-ISP radiance that
/// external viewers display from `gaussians.ply`.
nonisolated enum ISPMode: String, CaseIterable, Codable, Sendable { case camera, off }

/// Renders a Gaussian model for display with exactly the training rasterizer (same projection,
/// 2D mip filter and blending) followed by the same PPISP kernel, so previews match training.
nonisolated final class GaussianRenderer: @unchecked Sendable {
    let metal: GaussianMetal
    let raster: GaussianRasterizer
    let maxPixels: Int
    private let target: GaussianRenderTarget
    private let ispBuffer, output: MTLBuffer
    private let ispPipeline, toRGBA: MTLComputePipelineState

    static func bytes(maxPixels: Int) -> Int { maxPixels * (24 + 16 + 4) }

    init(metal: GaussianMetal, raster: GaussianRasterizer, maxPixels: Int) throws {
        self.metal = metal
        self.raster = raster
        self.maxPixels = maxPixels
        target = try GaussianRenderTarget(metal: metal, width: maxPixels, height: 1)
        ispBuffer = try metal.buffer(maxPixels * 16, label: "preview-isp")
        output = try metal.buffer(maxPixels * 4, label: "preview-rgba")
        ispPipeline = try metal.pipeline("ppisp_forward")
        toRGBA = try metal.pipeline("image_to_rgba8")
    }

    /// Largest size with the aspect ratio of `width × height` that fits the pixel budget.
    func fitted(width: Int, height: Int) -> (Int, Int) {
        let scale = min(1, (Double(maxPixels) / Double(max(1, width * height))).squareRoot())
        return (max(16, Int(Double(width) * scale)), max(16, Int(Double(height) * scale)))
    }

    private func run(_ body: (MTLComputeCommandEncoder) throws -> Void) throws {
        guard let buffer = metal.queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { return }
        try body(encoder)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw GaussianTrainer.TrainingError.gpuFailure(error.localizedDescription) }
    }

    /// Returns nil when the view needs more tile intersections than the buffers hold.
    func render(model: GaussianModel, camera input: GaussianCamera, shDegree: Int, isp: PPISPUniforms?,
                background: SIMD3<Float> = .zero) throws -> RenderedFrame? {
        var camera = input
        guard model.count > 0, camera.width * camera.height <= maxPixels else { return nil }
        camera.sh = SIMD4(UInt32(shDegree), UInt32((model.shDegree + 1) * (model.shDegree + 1)), UInt32(model.count), 0)
        target.width = camera.width
        target.height = camera.height
        raster.resetTotal()
        try run { e in try raster.encodeProjection(e, camera: camera, layout: model.layout, model: model.params, count: model.count) }
        let m = raster.intersectionCount
        guard m <= raster.intersectionCapacity else { return nil }
        let size = SIMD2<UInt32>(UInt32(camera.width), UInt32(camera.height))
        let groups = ((camera.width + 15) / 16, (camera.height + 15) / 16)
        try run { e in
            try raster.encodeRaster(e, camera: camera, count: model.count, intersections: m, target: target, background: background)
            var source = target.image
            if let isp {
                e.dispatch(ispPipeline, groups: groups, size: (16, 16), [.buffer(target.image), .buffer(ispBuffer), .value(isp), .value(size)])
                source = ispBuffer
            }
            e.dispatch(toRGBA, groups: groups, size: (16, 16), [.buffer(source), .buffer(output), .value(size)])
        }
        return RenderedFrame(width: camera.width, height: camera.height,
                             pixels: Data(bytes: output.contents(), count: camera.width * camera.height * 4))
    }
}

/// Free-viewpoint camera around a pivot in the ARKit world (gravity-aligned, +Y up): drag to
/// orbit, two fingers to pan, pinch to zoom. The horizon stays level.
nonisolated struct OrbitCamera: Equatable, Sendable {
    var pivot: SIMD3<Double>
    var distance: Double
    var yaw: Double
    var pitch: Double
    var fovY: Double

    /// Starts at a capture camera, looking at the point `depth` metres in front of it.
    init(arkitTransform t: [Double], intrinsics k: CameraIntrinsics, depth: Double) {
        let position = SIMD3(t[3], t[7], t[11])
        let forward = simd_normalize(-SIMD3(t[2], t[6], t[10]))
        let toEye = -forward
        pitch = asin(max(-1, min(1, toEye.y)))
        yaw = atan2(toEye.x, toEye.z)
        distance = max(0.2, depth)
        pivot = position + forward * distance
        // Portrait viewing: the capture's long axis becomes the vertical field of view.
        fovY = 2 * atan(Double(max(k.width, k.height)) / 2 / max(k.fx, k.fy))
    }

    var eye: SIMD3<Double> {
        pivot + distance * SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }

    /// OpenCV world-to-camera matrix (x right, y down, z forward).
    var worldToCamera: simd_double4x4 {
        let forward = simd_normalize(pivot - eye)
        var right = simd_cross(forward, SIMD3(0, 1, 0))
        if simd_length(right) < 1e-6 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let down = simd_cross(forward, right)
        let c2w = simd_double4x4(columns: (SIMD4(right, 0), SIMD4(down, 0), SIMD4(forward, 0), SIMD4(eye, 1)))
        return GaussianCamera.rigidInverse(c2w)
    }

    func camera(width: Int, height: Int, mipFilter: Bool) -> GaussianCamera {
        let f = Double(height) / 2 / tan(fovY / 2)
        return GaussianCamera(worldToCamera: worldToCamera, fx: f, fy: f, cx: Double(width) / 2, cy: Double(height) / 2,
                              width: width, height: height, mipFilter: mipFilter)
    }

    mutating func orbit(dx: Double, dy: Double) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -1.45), 1.45)
    }

    /// `dx`, `dy` in points on a view `viewHeight` points tall.
    mutating func pan(dx: Double, dy: Double, viewHeight: Double) {
        let w2c = worldToCamera
        let right = SIMD3(w2c[0][0], w2c[1][0], w2c[2][0]), down = SIMD3(w2c[0][1], w2c[1][1], w2c[2][1])
        let metresPerPoint = 2 * distance * tan(fovY / 2) / max(1, viewHeight)
        pivot += (-dx * right - dy * down) * metresPerPoint
    }

    mutating func zoom(_ scale: Double) {
        guard scale > 0, scale.isFinite else { return }
        distance = min(max(distance / scale, 0.05), 100)
    }
}
