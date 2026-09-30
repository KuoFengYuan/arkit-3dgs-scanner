// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import ImageIO
import CoreGraphics
import simd

/// Measured sharpness of each training photo against the other photos of the same surface.
///
/// A photo's gradient energy depends on what it shows (a bookshelf against a white wall), so
/// an absolute threshold is wrong, and the capture's motion estimate is not measured blur. Here
/// each textured cell of a photo is carried by its LiDAR depth into nearby photos looking the
/// same way, and the gradient energy of the same piece of surface is compared directly. A
/// photo's `deficit` is how much less energy it holds than its sharper peers (natural log of the
/// energy ratio against the 80th percentile of its pair medians); 0 means no clearer photo of
/// that surface exists, which also holds for a photo without peers.
///
/// Memory is bounded: one 640 × 480 grey thumbnail and one depth map are decoded at a time, and
/// only a 40 × 30 grid of cell energies and depths is kept per photo (9.6 KB). Reads the scan only.
nonisolated enum CovisibleSharpness {
    struct Score: Sendable, Equatable {
        /// ln(energy of the sharper peers / this photo's) on the same surface, ≥ 0.
        var deficit: Float
        /// Peers with enough matched cells, and matched cells over all of them.
        var peers: Int
        var matchedCells: Int
        /// Noise variance of the thumbnail's luma relative to the cells' mean squared (contrast units).
        var noise: Float
    }

    static let thumbnailLongEdge = 640
    static let cell = 16
    /// Peers: camera within `radius` (scaled like the other metric sizes below room scale) and
    /// view directions within 30°, nearest first, at most `maxPeers`.
    static let radius: Float = 1.0
    static let coneDegrees: Float = 30
    static let maxPeers = 16
    /// A pair needs this many matched textured cells, and this share of the photo's usable
    /// cells: a few cells of a peer that barely overlaps (or sees a textureless close-up from
    /// further away) would otherwise decide the score.
    static let minCells = 8
    static let minOverlap: Float = 0.15
    /// Projected depth must agree with the peer's LiDAR within this fraction (occlusion), and the
    /// surface's image scale within this ratio (a closer photo shows finer texture).
    static let depthTolerance: Float = 0.05
    static let maxScaleRatio: Float = 1.25
    /// The reference: this percentile of a photo's pair medians (its sharper peers).
    static let referencePercentile: Float = 0.8

    /// The per-photo grid kept between the two passes.
    struct Grid: Sendable {
        var rotation: simd_float3x3      // camera-to-world
        var position: SIMD3<Float>
        var forward: SIMD3<Float>
        var fx, fy, cx, cy: Float        // at the thumbnail
        var columns, rows: Int
        var energy: [Float]              // squared gradient over squared mean per cell, noise removed; -1 unusable
        var depth: [Float]               // LiDAR depth at the cell centre, 0 = unusable
        var noise: Float
    }

    /// Scores `frames` (indices into it) against the other frames in `peers` (default: all).
    /// Photos without depth get no score. `metricScale` shrinks the peer radius at close range.
    static func scores(frames: [TrainingFrame], directory: URL, peers: Set<Int>? = nil, metricScale: Float = 1,
                       isCancelled: () -> Bool = { false }) -> [Int: Score] {
        var grids: [Grid?] = []
        grids.reserveCapacity(frames.count)
        for frame in frames {
            if isCancelled() { return [:] }
            grids.append(autoreleasepool { grid(frame, directory: directory) })
        }
        return scores(grids: grids, peers: peers, metricScale: metricScale)
    }

    static func scores(grids: [Grid?], peers: Set<Int>? = nil, metricScale: Float = 1) -> [Int: Score] {
        let cosCone = cos(coneDegrees * .pi / 180)
        let r2 = (radius * metricScale) * (radius * metricScale)
        var out: [Int: Score] = [:]
        for i in grids.indices {
            guard let a = grids[i] else { continue }
            var candidates: [(Int, Float)] = []
            for j in grids.indices where j != i && (peers?.contains(j) ?? true) {
                guard let b = grids[j] else { continue }
                let d2 = simd_distance_squared(a.position, b.position)
                if d2 <= r2 && simd_dot(a.forward, b.forward) >= cosCone { candidates.append((j, d2)) }
            }
            candidates.sort { $0.1 < $1.1 }
            var medians: [Float] = [], matched = 0
            let usable = zip(a.depth, a.energy).filter { $0.0 > 0 && $0.1 >= 0 }.count
            let needed = max(minCells, Int(minOverlap * Float(usable)))
            for (j, _) in candidates.prefix(maxPeers) {
                let d = differences(a, grids[j]!)
                guard d.count >= needed else { continue }
                medians.append(median(d)); matched += d.count
            }
            // A negative median: the peer holds more energy on the same cells (it is sharper).
            let reference = medians.isEmpty ? 0 : percentile(medians.map { -$0 }, referencePercentile)
            out[i] = Score(deficit: max(0, reference), peers: medians.count, matchedCells: matched, noise: a.noise)
        }
        return out
    }

    /// ln(energy in `a`) − ln(energy in `b`) for each textured cell of `a` that `b` sees at a
    /// similar scale and without occlusion, with the scale difference taken out.
    static func differences(_ a: Grid, _ b: Grid) -> [Float] {
        var out: [Float] = []
        let bT = b.rotation.transpose
        for row in 0..<a.rows {
            for col in 0..<a.columns {
                let c = row * a.columns + col
                let z = a.depth[c]
                guard z > 0, a.energy[c] >= 0 else { continue }
                let u = Float(col * cell + cell / 2) + 0.5, v = Float(row * cell + cell / 2) + 0.5
                let camera = SIMD3((u - a.cx) / a.fx * z, -(v - a.cy) / a.fy * z, -z)
                let world = a.rotation * camera + a.position
                let q = bT * (world - b.position)
                let zb = -q.z
                guard zb > 0.1 else { continue }
                let ub = b.fx * q.x / zb + b.cx, vb = -b.fy * q.y / zb + b.cy
                let colB = Int(ub) / cell, rowB = Int(vb) / cell
                guard ub >= Float(cell / 2), vb >= Float(cell / 2), colB >= 0, rowB >= 0, colB < b.columns, rowB < b.rows else { continue }
                let cb = rowB * b.columns + colB
                let measured = b.depth[cb]
                guard measured > 0, abs(measured - zb) <= depthTolerance * zb, b.energy[cb] >= 0 else { continue }
                // Pixels per metre of surface in each photo; texture magnified by m has 1/m² of
                // the gradient energy per pixel.
                let scale = (b.fx / zb) / (a.fx / z)
                guard scale <= maxScaleRatio, scale >= 1 / maxScaleRatio else { continue }
                // Texture in either photo: a blurred photo loses the cells a sharp one shows.
                guard max(a.energy[c], b.energy[cb] * scale * scale) > textureFloor(max(a.noise, b.noise)) else { continue }
                let ea = max(a.energy[c], 0.25 * a.noise + 1e-7), eb = max(b.energy[cb], 0.25 * b.noise + 1e-7)
                out.append(max(-3, min(3, log(ea) - log(eb * scale * scale))))
            }
        }
        return out
    }

    /// A cell has texture when its noise-free contrast energy is four times the noise and
    /// clearly above JPEG quantisation.
    static func textureFloor(_ noise: Float) -> Float { max(4 * noise, 1e-4) }

    /// The photo's grid: gradient energy of its grey thumbnail per cell, minus the noise
    /// variance (Immerkær's estimate), and its LiDAR depth at the cell centres (confident, and
    /// not at a depth edge). Nil without depth or a readable image.
    static func grid(_ frame: TrainingFrame, directory: URL) -> Grid? {
        guard let depthFile = frame.depthFile, let w = frame.depthWidth, let h = frame.depthHeight, w > 2, h > 2,
              frame.transform.count == 16,
              let depthData = try? Data(contentsOf: directory.appendingPathComponent("depth").appendingPathComponent(depthFile)),
              depthData.count == w * h * 4 else { return nil }
        let confidence = frame.confidenceFile.flatMap { try? Data(contentsOf: directory.appendingPathComponent("depth").appendingPathComponent($0)) }
        guard let gray = grayThumbnail(directory.appendingPathComponent("images").appendingPathComponent(frame.imageFile)) else { return nil }
        let (pixels, gw, gh) = gray
        let columns = gw / cell, rows = gh / cell
        guard columns > 0, rows > 0 else { return nil }
        // Immerkær: sigma = sqrt(pi/2) / (6 (W-2)(H-2)) * sum |I * N|.
        var laplace = 0.0
        for y in 1..<(gh - 1) {
            for x in 1..<(gw - 1) {
                let i = y * gw + x
                let v = pixels[i - gw - 1] - 2 * pixels[i - gw] + pixels[i - gw + 1]
                    - 2 * pixels[i - 1] + 4 * pixels[i] - 2 * pixels[i + 1]
                    + pixels[i + gw - 1] - 2 * pixels[i + gw] + pixels[i + gw + 1]
                laplace += Double(abs(v))
            }
        }
        let sigma = Float((Double.pi / 2).squareRoot() * laplace / (6 * Double((gw - 2) * (gh - 2))))
        // Central differences: noise adds sigma² / 2 per axis, sigma² to gx² + gy².
        let noise = sigma * sigma
        var noiseSum: Float = 0, noiseCells: Float = 0
        // Contrast, not raw energy: auto exposure shows the same surface brighter or darker in
        // different photos, and gradient energy scales with brightness squared. Clipped or
        // nearly black cells hold no usable detail (-1).
        var energy = [Float](repeating: -1, count: columns * rows)
        for row in 0..<rows {
            for col in 0..<columns {
                var sum: Float = 0, mean: Float = 0, clipped: Float = 0, n: Float = 0
                for y in max(1, row * cell)..<min(gh - 1, (row + 1) * cell) {
                    for x in max(1, col * cell)..<min(gw - 1, (col + 1) * cell) {
                        let i = y * gw + x
                        let gx = 0.5 * (pixels[i + 1] - pixels[i - 1]), gy = 0.5 * (pixels[i + gw] - pixels[i - gw])
                        sum += gx * gx + gy * gy; mean += pixels[i]; n += 1
                        if pixels[i] > 0.97 { clipped += 1 }
                    }
                }
                mean /= max(1, n)
                guard mean > 0.04, clipped < 0.1 * n else { continue }
                energy[row * columns + col] = max(0, sum / max(1, n) - noise) / (mean * mean)
                noiseSum += noise / (mean * mean); noiseCells += 1
            }
        }
        let relativeNoise = noiseCells > 0 ? noiseSum / noiseCells : noise
        let k = frame.intrinsics
        let sx = Float(gw) / Float(k.width), sy = Float(gh) / Float(k.height)
        var depth = [Float](repeating: 0, count: columns * rows)
        depthData.withUnsafeBytes { raw in
            let z = raw.bindMemory(to: Float.self)
            for row in 0..<rows {
                for col in 0..<columns {
                    let dx = min(w - 2, max(1, Int((Float(col * cell + cell / 2) + 0.5) * Float(w) / Float(gw))))
                    let dy = min(h - 2, max(1, Int((Float(row * cell + cell / 2) + 0.5) * Float(h) / Float(gh))))
                    let i = dy * w + dx, d = z[i]
                    guard d.isFinite, d > 0.1, d < 6, (confidence.map { $0.count == w * h ? $0[i] >= 1 : true } ?? true) else { continue }
                    var edge = false
                    for j in [i - 1, i + 1, i - w, i + w] where !(abs(z[j] - d) <= 0.05 * d) { edge = true }
                    if !edge { depth[row * columns + col] = d }
                }
            }
        }
        let t = frame.transform.map(Float.init)
        let rotation = simd_float3x3(rows: [SIMD3(t[0], t[1], t[2]), SIMD3(t[4], t[5], t[6]), SIMD3(t[8], t[9], t[10])])
        let forward = -SIMD3(t[2], t[6], t[10])
        return Grid(rotation: rotation, position: SIMD3(t[3], t[7], t[11]), forward: simd_normalize(forward),
                    fx: Float(k.fx) * sx, fy: Float(k.fy) * sy, cx: Float(k.cx) * sx, cy: Float(k.cy) * sy,
                    columns: columns, rows: rows, energy: energy, depth: depth, noise: relativeNoise)
    }

    /// Sensor-oriented grey thumbnail (no EXIF rotation, like the recorded intrinsics), 0...1.
    static func grayThumbnail(_ url: URL) -> ([Float], Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: thumbnailLongEdge,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width >= 32, image.height >= 32 else { return nil }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (bytes.map { Float($0) / 255 }, w, h) : nil
    }

    /// Training weights from the scores: the energy ratio against the sharper peers raised to
    /// `strength`, e^(-strength · deficit), never below `floor`, so every photo keeps teaching
    /// its view (coverage) while clearer photos of the same surface lead. Unscored views keep 1.
    static func weights(_ scores: [Int: Score], count: Int, strength: Float, floor: Float) -> [Float] {
        (0..<count).map { i in scores[i].map { max(floor, exp(-strength * $0.deficit)) } ?? 1 }
    }

    static func median(_ v: [Float]) -> Float { percentile(v, 0.5) }

    static func percentile(_ v: [Float], _ p: Float) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int((Float(s.count - 1) * p).rounded())))]
    }
}
