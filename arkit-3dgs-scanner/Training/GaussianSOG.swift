// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import ImageIO
import Metal
import simd

/// SOG ("spatially ordered Gaussians", version 2): the compressed 3DGS model format read by
/// PlayCanvas / SuperSplat and LichtFeld Studio. A ZIP of `meta.json` and lossless WebP
/// textures, one texel per Gaussian in Morton order:
/// - `means_l` / `means_u`: sign(v)·ln(|v| + 1) of each coordinate, 16 bits split in two images;
/// - `quats`: the three smallest components of the unit quaternion scaled by √2 (alpha 252 + the
///   dropped component's index in w, x, y, z order);
/// - `scales`, `sh0`: indices into 256-entry codebooks of log scales and DC coefficients, with
///   the opacity in `sh0`'s alpha;
/// - `shN_centroids` / `shN_labels`: a k-means palette of the higher-band SH vectors (up to
///   65,536 entries, values through a 256-entry codebook) and each Gaussian's 16-bit label.
///
/// Implemented from the published format description (PlayCanvas documentation); no code from
/// other SOG writers is included. It uses the same COLMAP export frame as `gaussians.ply`.
/// Lossy: positions keep 16 bits per axis, the rest 8-bit codebooks and the SH palette.
nonisolated enum GaussianSOG {
    static let fileName = "gaussians.sog"
    /// Lloyd steps of the SH palette. On FBDA13 (600,000 Gaussians) 1, 3 and 10 steps scored
    /// within 0.02 dB of each other on held-out photos; each step costs about 2.2 s on the Mac.
    static let kMeansIterations = 3

    enum SOGError: LocalizedError {
        case empty, damaged, unsupported
        var errorDescription: String? {
            switch self {
            case .empty: return L10n.text("模型沒有可匯出的高斯")
            case .damaged: return L10n.text("3DGS 模型檔案不完整")
            case .unsupported: return L10n.text("此 3DGS 模型格式不支援")
            }
        }
    }

    // MARK: meta.json

    struct Meta: Codable {
        struct Asset: Codable { var generator: String }
        struct Means: Codable { var mins: [Float]; var maxs: [Float]; var files: [String] }
        struct Codebook: Codable { var codebook: [Float]; var files: [String] }
        struct Files: Codable { var files: [String] }
        struct SH: Codable { var count: Int; var bands: Int; var codebook: [Float]; var files: [String] }
        var version = 2
        var asset: Asset?
        var count: Int
        var means: Means
        var scales: Codebook
        var quats: Files
        var sh0: Codebook
        var shN: SH?
    }

    /// Timings and sizes of one write (the tools print them).
    struct WriteReport { var gaussians = 0, bytes = 0, paletteEntries = 0; var seconds = 0.0, kMeansSeconds = 0.0 }

    /// Buffers the writer may reuse instead of allocating: at the end of training the model's
    /// gradients and the rasterizer's per-intersection buffers are free (points ≥ n·D floats,
    /// palette ≥ K·D floats, labels ≥ n words).
    struct Scratch { var points: MTLBuffer?; var palette: MTLBuffer?; var labels: MTLBuffer? }

    /// Palette size for `n` Gaussians: 1,024 × the largest power of two ≤ n / 1,024, at most
    /// 65,536 (the SOG labels are 16 bits), and never more than there are Gaussians.
    static func paletteSize(_ n: Int) -> Int {
        guard n >= 1_024 else { return max(1, n) }
        var blocks = 1
        while blocks * 2 <= n / 1_024 && blocks < 64 { blocks *= 2 }
        return min(blocks * 1_024, n)
    }

    /// Texture size for `n` texels: width ⌈√n / 4⌉·4, height ⌈n / width / 4⌉·4.
    static func textureSize(_ n: Int) -> (width: Int, height: Int) {
        let width = max(4, Int((Double(n).squareRoot() / 4).rounded(.up)) * 4)
        let height = max(4, Int((Double(n) / Double(width) / 4).rounded(.up)) * 4)
        return (width, height)
    }

    // MARK: Writing

    /// Writes the live rows of `model` to `url` (atomically). The SH palette is clustered on
    /// the GPU with `iterations` Lloyd steps.
    @discardableResult
    static func write(_ model: GaussianModel, to url: URL, metal: GaussianMetal, scratch: Scratch = Scratch(points: nil, palette: nil, labels: nil),
                      iterations: Int = kMeansIterations, paletteEntries: Int? = nil, seed: UInt64 = 0x50C) throws -> WriteReport {
        let started = Date()
        var report = WriteReport()
        let rows = model.liveRows
        let n = rows.count
        guard n > 0 else { throw SOGError.empty }
        report.gaussians = n
        let L = model.layout, p = model.floats(model.params)
        let rest = model.shRest

        // Export frame (ARKit world rotated 180° about X), then Morton order.
        var means = [SIMD3<Float>](repeating: .zero, count: n)
        for (i, row) in rows.enumerated() {
            means[i] = SIMD3(p[Int(L.means) + 3 * row], -p[Int(L.means) + 3 * row + 1], -p[Int(L.means) + 3 * row + 2])
        }
        let order = mortonOrder(means)
        let (W, H) = textureSize(n)
        /// An RGBA texture, opaque black where no Gaussian sits.
        func image() -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: W * H * 4)
            for t in 0..<(W * H) { rgba[4 * t + 3] = 255 }
            return rgba
        }

        // Positions: log transform, 16 bits per axis.
        var mins = SIMD3<Float>(repeating: .infinity), maxs = SIMD3<Float>(repeating: -.infinity)
        for i in means.indices {
            means[i] = SIMD3(logTransform(means[i].x), logTransform(means[i].y), logTransform(means[i].z))
            mins = simd_min(mins, means[i]); maxs = simd_max(maxs, means[i])
        }
        var meansL = image(), meansU = image(), quats = image(), scalesImage = image(), sh0Image = image()
        for (t, i) in order.enumerated() {
            for k in 0..<3 {
                let range = maxs[k] - mins[k]
                let q = range > 0 ? Int(((means[i][k] - mins[k]) / range * 65_535).rounded()) : 0
                let v = min(65_535, max(0, q))
                meansL[4 * t + k] = UInt8(v & 0xFF)
                meansU[4 * t + k] = UInt8(v >> 8)
            }
        }
        // Rotations: smallest three of the flipped unit quaternion.
        for (t, i) in order.enumerated() {
            let row = rows[i]
            var q = SIMD4(p[Int(L.quats) + 4 * row], p[Int(L.quats) + 4 * row + 1], p[Int(L.quats) + 4 * row + 2], p[Int(L.quats) + 4 * row + 3])
            q = GaussianExport.flipQuaternion(simd_length_squared(q) > 0 ? simd_normalize(q) : SIMD4(1, 0, 0, 0))
            var largest = 0
            for k in 1..<4 where abs(q[k]) > abs(q[largest]) { largest = k }
            if q[largest] < 0 { q = -q }
            var slot = 0
            for k in 0..<4 where k != largest {
                let v = min(max(q[k] * Float(2).squareRoot() * 0.5 + 0.5, 0), 1)
                quats[4 * t + slot] = UInt8((v * 255).rounded())
                slot += 1
            }
            quats[4 * t + 3] = UInt8(252 + largest)
        }
        // Scales and DC colour through 256-entry codebooks; opacity in sh0's alpha.
        var scaleValues = [Float](repeating: 0, count: 3 * n), dcValues = [Float](repeating: 0, count: 3 * n)
        for (t, i) in order.enumerated() {
            let row = rows[i]
            for k in 0..<3 {
                scaleValues[3 * t + k] = p[Int(L.scales) + 3 * row + k]
                dcValues[3 * t + k] = p[Int(L.sh0) + 3 * row + k]
            }
        }
        let scaleBook = Codebook1D(values: scaleValues)
        let dcBook = Codebook1D(values: dcValues)
        for t in 0..<n {
            let row = rows[order[t]]
            for k in 0..<3 {
                scalesImage[4 * t + k] = scaleBook.labels[3 * t + k]
                sh0Image[4 * t + k] = dcBook.labels[3 * t + k]
            }
            let opacity = 1 / (1 + exp(-p[Int(L.opacities) + row]))
            sh0Image[4 * t + 3] = UInt8(min(255, max(0, (opacity * 255).rounded())))
        }

        var files: [(name: String, rgba: [UInt8], width: Int, height: Int)] = [
            ("means_l.webp", meansL, W, H), ("means_u.webp", meansU, W, H), ("quats.webp", quats, W, H),
            ("scales.webp", scalesImage, W, H), ("sh0.webp", sh0Image, W, H),
        ]
        var meta = Meta(asset: Meta.Asset(generator: "arkit-3dgs-scanner"), count: n,
                        means: Meta.Means(mins: [mins.x, mins.y, mins.z], maxs: [maxs.x, maxs.y, maxs.z],
                                          files: ["means_l.webp", "means_u.webp"]),
                        scales: Meta.Codebook(codebook: scaleBook.codebook, files: ["scales.webp"]),
                        quats: Meta.Files(files: ["quats.webp"]),
                        sh0: Meta.Codebook(codebook: dcBook.codebook, files: ["sh0.webp"]))

        // Higher SH bands: k-means palette, then a codebook for the palette values.
        if rest > 0 {
            let D = 3 * rest, P = paddedDimensions(D)
            let K = min(paletteEntries ?? paletteSize(n), paletteSize(n))
            let pointBytes = n * P * 2
            let points = try scratch.points.flatMap { $0.length >= pointBytes ? $0 : nil } ?? metal.buffer(pointBytes, label: "sog-points")
            let pts = points.contents().bindMemory(to: Float16.self, capacity: n * P)
            for (t, i) in order.enumerated() {
                let row = rows[i]
                for k in 0..<rest { for c in 0..<3 {
                    pts[t * P + k * 3 + c] = Float16(p[Int(L.shN) + row * rest * 3 + k * 3 + c] * GaussianExport.shFlipSigns[k + 1])
                } }
                for d in D..<P { pts[t * P + d] = 0 }
            }
            let kStart = Date()
            let (palette, labels) = try kMeans(points: points, count: n, dimensions: D, entries: K, iterations: iterations,
                                               seed: seed, metal: metal, scratch: scratch)
            report.kMeansSeconds = Date().timeIntervalSince(kStart)
            report.paletteEntries = K
            let valueBook = Codebook1D(values: palette)
            let cw = 64 * rest, ch = (K + 63) / 64
            var centroids = [UInt8](repeating: 0, count: cw * ch * 4)
            for e in 0..<K {
                for k in 0..<rest {
                    let texel = (e / 64) * cw + (e % 64) * rest + k
                    for c in 0..<3 { centroids[4 * texel + c] = valueBook.labels[e * D + k * 3 + c] }
                    centroids[4 * texel + 3] = 255
                }
            }
            var labelImage = image()
            for t in 0..<n {
                labelImage[4 * t] = UInt8(labels[t] & 0xFF)
                labelImage[4 * t + 1] = UInt8(labels[t] >> 8)
            }
            files.append(("shN_centroids.webp", centroids, cw, ch))
            files.append(("shN_labels.webp", labelImage, W, H))
            meta.shN = Meta.SH(count: K, bands: model.shDegree, codebook: valueBook.codebook,
                               files: ["shN_centroids.webp", "shN_labels.webp"])
        }

        // Lossless WebP, one image at a time (each takes tens of milliseconds; encoding them
        // together would hold every image's working copies at once).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var entries: [(name: String, data: Data)] = [("meta.json", try encoder.encode(meta))]
        while !files.isEmpty {
            let file = files.removeFirst()
            entries.append((file.name, try WebPLossless.encode(rgba: file.rgba, width: file.width, height: file.height)))
        }
        let archive = StoredZip.archive(entries)
        try archive.write(to: url, options: .atomic)
        report.bytes = archive.count
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    static func logTransform(_ v: Float) -> Float { (v < 0 ? -1 : 1) * log(abs(v) + 1) }
    static func inverseLogTransform(_ v: Float) -> Float { (v < 0 ? -1 : 1) * (exp(abs(v)) - 1) }

    /// Indices sorted by the 30-bit Morton code of each position in its bounding box.
    static func mortonOrder(_ positions: [SIMD3<Float>]) -> [Int] {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for v in positions where v.x.isFinite && v.y.isFinite && v.z.isFinite { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        let extent = simd_max(hi - lo, SIMD3(repeating: 1e-9))
        func spread(_ x: UInt32) -> UInt64 {
            var v = UInt64(x & 0x3FF)
            v = (v | (v << 16)) & 0x0300_00FF
            v = (v | (v << 8)) & 0x0300_F00F
            v = (v | (v << 4)) & 0x030C_30C3
            v = (v | (v << 2)) & 0x0924_9249
            return v
        }
        let codes = positions.map { v -> UInt64 in
            let q = simd_clamp((v - lo) / extent, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 1023
            let x = q.x.isFinite ? UInt32(q.x) : 0, y = q.y.isFinite ? UInt32(q.y) : 0, z = q.z.isFinite ? UInt32(q.z) : 0
            return spread(x) | spread(y) << 1 | spread(z) << 2
        }
        return positions.indices.sorted { codes[$0] != codes[$1] ? codes[$0] < codes[$1] : $0 < $1 }
    }

    /// Vectors of `D` values are stored as half floats, padded to whole half4s for the GPU.
    static func paddedDimensions(_ D: Int) -> Int { (D + 3) / 4 * 4 }

    /// k-means of `count` points of `dimensions` half floats (stored padded, `paddedDimensions`)
    /// into `entries` palette entries: deterministic distinct initial points, then Lloyd steps
    /// (GPU assignment, CPU means). An entry that loses all its points keeps its previous
    /// value. Returns the palette unpadded (`entries` × `dimensions`).
    static func kMeans(points: MTLBuffer, count n: Int, dimensions D: Int, entries K: Int, iterations: Int,
                       seed: UInt64, metal: GaussianMetal, scratch: Scratch) throws -> (palette: [Float], labels: [UInt32]) {
        let P = paddedDimensions(D)
        let pts = points.contents().bindMemory(to: Float16.self, capacity: n * P)
        let paletteBuffer = try scratch.palette.flatMap { $0.length >= K * P * 2 ? $0 : nil } ?? metal.buffer(K * P * 2, label: "sog-palette")
        let labelBuffer = try scratch.labels.flatMap { $0.length >= n * 4 ? $0 : nil } ?? metal.buffer(n * 4, label: "sog-labels")
        let palette = paletteBuffer.contents().bindMemory(to: Float16.self, capacity: K * P)
        var means = [Float](repeating: 0, count: K * D)
        // Initial entries: a deterministic sample of distinct points.
        var rng = SplitMix64(seed: seed)
        var pick = Array(0..<n)
        for e in 0..<K {
            let j = e + Int(rng.next() % UInt64(n - e))
            pick.swapAt(e, j)
            for d in 0..<P { palette[e * P + d] = pts[pick[e] * P + d] }
            for d in 0..<D { means[e * D + d] = Float(pts[pick[e] * P + d]) }
        }
        let pipeline = try metal.pipeline("sog_assign_\(D)")
        let labels = labelBuffer.contents().bindMemory(to: UInt32.self, capacity: n)
        var sums = [Float](repeating: 0, count: K * D)
        var members = [Int](repeating: 0, count: K)
        for step in 0...max(0, iterations) {
            guard let cb = metal.queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { throw SOGError.damaged }
            e.dispatch(pipeline, threads: n, width: 64, [.buffer(points), .buffer(paletteBuffer), .buffer(labelBuffer),
                                                         .value(SIMD2<UInt32>(UInt32(n), UInt32(K)))])
            e.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            if let error = cb.error { throw error }
            guard step < iterations else { break }
            for k in 0..<(K * D) { sums[k] = 0 }
            for k in 0..<K { members[k] = 0 }
            for i in 0..<n {
                let e = Int(labels[i])
                members[e] += 1
                for d in 0..<D { sums[e * D + d] += Float(pts[i * P + d]) }
            }
            for e in 0..<K where members[e] > 0 {
                let inv = 1 / Float(members[e])
                for d in 0..<D {
                    means[e * D + d] = sums[e * D + d] * inv
                    palette[e * P + d] = Float16(means[e * D + d])
                }
            }
        }
        return (means, Array(UnsafeBufferPointer(start: labels, count: n)))
    }

    /// 256-entry 1-D k-means codebook of `values` (ascending) and each value's nearest entry.
    struct Codebook1D {
        var codebook: [Float]
        var labels: [UInt8]

        init(values: [Float], entries: Int = 256, iterations: Int = 10) {
            let sorted = values.map { $0.isFinite ? $0 : 0 }.sorted()
            guard !sorted.isEmpty else { codebook = [Float](repeating: 0, count: entries); labels = []; return }
            let n = sorted.count
            var centres = (0..<entries).map { sorted[min(n - 1, Int((Double($0) + 0.5) / Double(entries) * Double(n)))] }
            func lowerBound(_ x: Float) -> Int {
                var lo = 0, hi = n
                while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < x { lo = mid + 1 } else { hi = mid } }
                return lo
            }
            for _ in 0..<iterations {
                // Boundaries halfway between neighbouring centres split the sorted values; each
                // centre moves to the mean of its run.
                var start = 0
                for k in 0..<entries {
                    let end = k == entries - 1 ? n : lowerBound((centres[k] + centres[k + 1]) / 2)
                    if end > start {
                        var sum = 0.0
                        for i in start..<end { sum += Double(sorted[i]) }
                        centres[k] = Float(sum / Double(end - start))
                    }
                    start = max(start, end)
                }
                centres.sort()
            }
            codebook = centres
            labels = values.map { raw in
                let v = raw.isFinite ? raw : 0
                var lo = 0, hi = entries - 1
                while lo < hi { let mid = (lo + hi) / 2; if centres[mid] < v { lo = mid + 1 } else { hi = mid } }
                if lo > 0 && abs(centres[lo - 1] - v) <= abs(centres[lo] - v) { lo -= 1 }
                return UInt8(lo)
            }
        }
    }

    // MARK: Reading

    /// Count and SH degree of a SOG file without decoding its textures.
    static func info(_ url: URL) throws -> (count: Int, shDegree: Int) {
        let entries = try StoredZip.entries(try Data(contentsOf: url, options: .alwaysMapped))
        guard let data = entries["meta.json"] else { throw SOGError.damaged }
        let meta = try JSONDecoder().decode(Meta.self, from: data)
        guard meta.version == 2, meta.count > 0 else { throw SOGError.unsupported }
        return (meta.count, meta.shN?.bands ?? 0)
    }

    /// Reads a SOG file into `model` (ARKit frame). A model of a higher SH degree gets zero for
    /// the extra bands.
    @discardableResult
    static func read(_ url: URL, into model: GaussianModel) throws -> Int {
        let entries = try StoredZip.entries(try Data(contentsOf: url, options: .alwaysMapped))
        guard let metaData = entries["meta.json"] else { throw SOGError.damaged }
        let meta = try JSONDecoder().decode(Meta.self, from: metaData)
        let n = meta.count, degree = meta.shN?.bands ?? 0
        guard meta.version == 2, n > 0, n <= model.capacity, degree <= model.shDegree, degree <= 3,
              meta.means.mins.count == 3, meta.means.maxs.count == 3,
              meta.scales.codebook.count == 256, meta.sh0.codebook.count == 256 else { throw SOGError.unsupported }
        func texture(_ name: String?) throws -> (rgba: [UInt8], width: Int, height: Int) {
            guard let name, let data = entries[name] else { throw SOGError.damaged }
            return try decodeRGBA(data)
        }
        let meansL = try texture(meta.means.files.first), meansU = try texture(meta.means.files.dropFirst().first)
        let quats = try texture(meta.quats.files.first), scales = try texture(meta.scales.files.first)
        let sh0 = try texture(meta.sh0.files.first)
        let W = meansL.width
        for t in [meansL, meansU, quats, scales, sh0] where t.width != W || t.width * t.height < n { throw SOGError.damaged }
        model.initialize(positions: [], colors: [])
        let L = model.layout, p = model.floats(model.params)
        let rest = model.shRest, fileRest = (degree + 1) * (degree + 1) - 1
        let mins = meta.means.mins, maxs = meta.means.maxs
        for t in 0..<n {
            for k in 0..<3 {
                let q = Float(Int(meansU.rgba[4 * t + k]) << 8 | Int(meansL.rgba[4 * t + k])) / 65_535
                let v = inverseLogTransform(mins[k] + (maxs[k] - mins[k]) * q)
                p[Int(L.means) + 3 * t + k] = k == 0 ? v : -v
                p[Int(L.scales) + 3 * t + k] = meta.scales.codebook[Int(scales.rgba[4 * t + k])]
                p[Int(L.sh0) + 3 * t + k] = meta.sh0.codebook[Int(sh0.rgba[4 * t + k])]
            }
            let alpha = max(Float(sh0.rgba[4 * t + 3]), 0.5) / 255
            let opacity = min(alpha, 1 - 0.5 / 255)
            p[Int(L.opacities) + t] = log(opacity / (1 - opacity))
            let mode = Int(quats.rgba[4 * t + 3]) - 252
            guard (0..<4).contains(mode) else { throw SOGError.damaged }
            var q = SIMD4<Float>()
            var slot = 0, sum: Float = 0
            for k in 0..<4 where k != mode {
                let v = (Float(quats.rgba[4 * t + slot]) / 255 - 0.5) * 2 / Float(2).squareRoot()
                q[k] = v; sum += v * v; slot += 1
            }
            q[mode] = max(0, 1 - sum).squareRoot()
            q = GaussianExport.unflipQuaternion(simd_normalize(q))
            for k in 0..<4 { p[Int(L.quats) + 4 * t + k] = q[k] }
        }
        if let sh = meta.shN, rest > 0, fileRest > 0 {
            guard sh.codebook.count == 256, sh.count > 0, sh.count <= 65_536 else { throw SOGError.unsupported }
            let centroids = try texture(sh.files.first), labels = try texture(sh.files.dropFirst().first)
            guard centroids.width == 64 * fileRest, centroids.height * 64 >= sh.count, labels.width * labels.height >= n else {
                throw SOGError.damaged
            }
            for t in 0..<n {
                let entry = Int(labels.rgba[4 * t]) | Int(labels.rgba[4 * t + 1]) << 8
                guard entry < sh.count else { throw SOGError.damaged }
                for k in 0..<fileRest {
                    let texel = (entry / 64) * centroids.width + (entry % 64) * fileRest + k
                    for c in 0..<3 {
                        p[Int(L.shN) + t * rest * 3 + k * 3 + c] = sh.codebook[Int(centroids.rgba[4 * texel + c])] * GaussianExport.shFlipSigns[k + 1]
                    }
                }
            }
        }
        model.restore(rowCount: n, adamStep: 0)
        return n
    }

    /// RGBA8 texels of a WebP (or PNG) image, not premultiplied, top-left origin.
    static func decodeRGBA(_ data: Data) throws -> (rgba: [UInt8], width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == 0 || image.bitmapInfo.contains(.byteOrder32Big),
              let pixels = image.dataProvider?.data as Data? else { throw SOGError.unsupported }
        let alpha = image.alphaInfo
        let opaque = alpha == .noneSkipLast || alpha == .none
        guard opaque || alpha == .last else { throw SOGError.unsupported }   // premultiplied alpha would change RGB
        let w = image.width, h = image.height, row = image.bytesPerRow
        guard pixels.count >= row * (h - 1) + w * 4 else { throw SOGError.damaged }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let s = y * row + x * 4, d = (y * w + x) * 4
                    out[d] = b[s]; out[d + 1] = b[s + 1]; out[d + 2] = b[s + 2]; out[d + 3] = opaque ? 255 : b[s + 3]
                }
            }
        }
        return (out, w, h)
    }
}
