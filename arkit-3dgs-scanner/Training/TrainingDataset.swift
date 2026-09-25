// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import ImageIO
import CoreGraphics
import simd

/// One training view: a selected capture frame with its calibration and pose.
nonisolated struct TrainingFrame: Codable, Equatable, Sendable {
    var id: Int
    var imageFile: String
    /// Full-resolution calibration of the stored (sensor-oriented) JPEG.
    var intrinsics: CameraIntrinsics
    /// ARKit camera-to-world, row-major, as saved by the capture (never modified).
    var transform: [Double]
    /// log2(exposure duration × ISO) when recorded; seeds the PPISP exposure.
    var captureEV: Double?
    var isValidation: Bool
    /// Exposure time (s) and camera-frame angular (rad/s) + linear (m/s) velocity from the
    /// neighbouring poses in time (OpenCV camera axes), for the capture-motion model.
    var exposure: Double? = nil
    var motion: [Double]? = nil
    /// The photo's LiDAR depth (metres along the optical axis) and confidence, when captured.
    var depthFile: String? = nil
    var confidenceFile: String? = nil
    var depthWidth: Int? = nil
    var depthHeight: Int? = nil

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.imageFile == b.imageFile && a.transform == b.transform && a.isValidation == b.isValidation
            && a.intrinsics.fx == b.intrinsics.fx && a.intrinsics.width == b.intrinsics.width
    }
}

/// Views, seed points and training resolution prepared from a saved scan. Reads the scan only;
/// original images, depth and pose files are never written.
nonisolated struct TrainingDataset: Sendable {
    enum PreparationError: LocalizedError {
        case noFrames, missingImages, incompatibleResolution
        var errorDescription: String? {
            switch self {
            case .noFrames: return L10n.text("沒有可用於訓練的影像與相機姿態")
            case .missingImages: return L10n.text("找不到訓練影像，掃描資料可能不完整")
            case .incompatibleResolution: return L10n.text("影像解析度與相機參數不一致，無法訓練")
            }
        }
    }

    let directory: URL
    let frames: [TrainingFrame]
    /// Seed points in ARKit world coordinates (metres) with colour.
    let points: [CloudPoint]
    let width: Int, height: Int
    var trainFrames: [Int] { frames.indices.filter { !frames[$0].isValidation } }
    var validationFrames: [Int] { frames.indices.filter { frames[$0].isValidation } }

    /// Training resolution for a stored image scaled to `longEdge` (never upscaled).
    static func trainingSize(width: Int, height: Int, longEdge: Int) -> (Int, Int) {
        let scale = min(1, Double(longEdge) / Double(max(width, height)))
        return (max(16, Int((Double(width) * scale).rounded())), max(16, Int((Double(height) * scale).rounded())))
    }

    /// Uses the same inputs as the COLMAP export: the latest review poses (anchor-corrected and
    /// bundle-adjusted when validated), the RGB frame selection, per-frame intrinsics and the
    /// saved point cloud. `holdOutEvery` > 0 keeps every n-th selected frame for validation.
    /// `depthSeedLimit` > 0 adds up to that many seeds from the photos' LiDAR depth where the
    /// saved cloud has none (see `depthSeeds`).
    /// `holdOutSegment` > 0 instead holds out one contiguous stretch of that fraction of the
    /// selected frames, from the middle of the capture (novel views away from the training path).
    static func prepare(scan directory: URL, longEdge: Int, holdOutEvery: Int, maxPoints: Int,
                        depthSeedLimit: Int = 0, holdOutSegment: Double = 0,
                        isCancelled: () -> Bool = { false }) throws -> TrainingDataset {
        let (records, _) = ScanLibrary.savedRecords(in: directory)
        let usable = records.filter {
            $0.blurVerdict == .keep && $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite)
                && $0.intrinsics.width > 0 && $0.intrinsics.height > 0 && $0.intrinsics.fx > 0 && $0.intrinsics.fy > 0
                && $0.imageFile == ($0.imageFile as NSString).lastPathComponent
        }
        guard !usable.isEmpty else { throw PreparationError.noFrames }
        // Prefer the stored selection; recompute it (in memory) for scans exported before it existed.
        var selected: Set<Int>
        if let data = try? Data(contentsOf: directory.appendingPathComponent("training-selection.json")),
           let report = try? JSONDecoder().decode(TrainingFrameSelector.Report.self, from: data),
           !Set(report.selectedIDs).isDisjoint(with: usable.map(\.id)) {
            selected = Set(report.selectedIDs)
        } else {
            let evidence = TrainingFrameSelector.evidence(records: usable, directory: directory, isCancelled: isCancelled)
            selected = Set(TrainingFrameSelector.select(usable, evidence: evidence).selectedIDs)
        }
        let chosen = usable.filter { selected.contains($0.id) }.sorted { $0.id < $1.id }
        guard !chosen.isEmpty else { throw PreparationError.noFrames }
        // ARKit's raw tracking is smooth frame to frame; corrected pose sets can jump between
        // segments (anchor updates, relocalisation), which would read as motion.
        let raw = ScanLibrary.readRecords(directory.appendingPathComponent("poses.jsonl"))
        let velocities = motion(records: raw.isEmpty ? records : raw)
        let first = chosen[0].intrinsics
        let images = directory.appendingPathComponent("images")
        var frames: [TrainingFrame] = []
        for (index, record) in chosen.enumerated() {
            guard record.intrinsics.width == first.width, record.intrinsics.height == first.height else {
                throw PreparationError.incompatibleResolution
            }
            guard FileManager.default.fileExists(atPath: images.appendingPathComponent(record.imageFile).path) else {
                throw PreparationError.missingImages
            }
            let ev: Double? = record.exposureDuration > 0 && record.iso > 0 ? log2(record.exposureDuration * record.iso) : nil
            frames.append(TrainingFrame(id: record.id, imageFile: record.imageFile, intrinsics: record.intrinsics,
                                        transform: record.transform, captureEV: ev,
                                        isValidation: holdOutSegment > 0
                                            ? abs(Double(index) + 0.5 - Double(chosen.count) / 2) < holdOutSegment * Double(chosen.count) / 2
                                            : holdOutEvery > 1 && index % holdOutEvery == holdOutEvery / 2,
                                        exposure: record.exposureDuration > 0 ? record.exposureDuration : nil,
                                        motion: velocities[record.id], depthFile: record.depthFile,
                                        confidenceFile: record.confidenceFile, depthWidth: record.depthWidth,
                                        depthHeight: record.depthHeight))
        }
        if frames.allSatisfy(\.isValidation) || frames.filter({ !$0.isValidation }).isEmpty {
            for i in frames.indices { frames[i].isValidation = false }
        }
        var points: [CloudPoint] = []
        for name in ["review.ply", "points.ply"] {
            if let saved = try? ScanLibrary.readPLY(directory.appendingPathComponent(name), limit: maxPoints), !saved.isEmpty {
                points = saved; break
            }
        }
        if depthSeedLimit > 0 {
            let training = Set(frames.filter { !$0.isValidation }.map(\.id))
            points += depthSeeds(records: chosen.filter { training.contains($0.id) }, directory: directory, existing: points,
                                 limit: depthSeedLimit, isCancelled: isCancelled)
        }
        let size = trainingSize(width: first.width, height: first.height, longEdge: longEdge)
        return TrainingDataset(directory: directory, frames: frames, points: points, width: size.0, height: size.1)
    }

    /// Densification only splits existing Gaussians, so surfaces without seeds never get any.
    /// The fused cloud keeps only depth that passed its consistency checks: on FBDA13 about
    /// 40% of the 5 cm cells the LiDAR saw had no point. This back-projects a grid of each
    /// training photo's LiDAR depth and adds one seed (coloured from the photo) per empty
    /// `voxel` cell: medium/high-confidence depth first, then low-confidence depth closer than
    /// 4 m for cells still empty. Reads the scan only.
    static func depthSeeds(records: [FrameRecord], directory: URL, existing: [CloudPoint], limit: Int,
                           voxel: Float = 0.04, stride: Int = 4, isCancelled: () -> Bool = { false }) -> [CloudPoint] {
        struct Key: Hashable { var x, y, z: Int32 }
        func key(_ p: SIMD3<Float>) -> Key {
            Key(x: Int32((p.x / voxel).rounded(.down)), y: Int32((p.y / voxel).rounded(.down)), z: Int32((p.z / voxel).rounded(.down)))
        }
        var occupied = Set<Key>(minimumCapacity: existing.count)
        for p in existing { occupied.insert(key(SIMD3(p.x, p.y, p.z))) }
        var seeds: [CloudPoint] = []
        let depthDirectory = directory.appendingPathComponent("depth"), images = directory.appendingPathComponent("images")
        for pass in 0..<2 {
            for record in records where seeds.count < limit {
                if isCancelled() { return seeds }
                guard let depthFile = record.depthFile, let confidenceFile = record.confidenceFile,
                      let w = record.depthWidth, let h = record.depthHeight, w > 0, h > 0, record.transform.count == 16,
                      let depthData = try? Data(contentsOf: depthDirectory.appendingPathComponent(depthFile)), depthData.count == w * h * 4,
                      let confidence = try? Data(contentsOf: depthDirectory.appendingPathComponent(confidenceFile)), confidence.count == w * h,
                      let rgb = TrainingImageLoader.decode(images.appendingPathComponent(record.imageFile), width: w, height: h) else { continue }
                let k = record.intrinsics
                let sx = Double(w) / Double(k.width), sy = Double(h) / Double(k.height)
                let fx = Float(k.fx * sx), fy = Float(k.fy * sy), cx = Float(k.cx * sx), cy = Float(k.cy * sy)
                let t = record.transform.map(Float.init)
                depthData.withUnsafeBytes { raw in
                    let depth = raw.bindMemory(to: Float.self)
                    for y in Swift.stride(from: stride / 2, to: h, by: stride) {
                        for x in Swift.stride(from: stride / 2, to: w, by: stride) where seeds.count < limit {
                            let i = y * w + x
                            let z = depth[i], c = confidence[i]
                            guard z.isFinite, z > 0.1, pass == 0 ? c >= 1 : (c == 0 && z < 4) else { continue }
                            // ARKit camera: x right, y up, looking down -z; image rows go down.
                            let cam = SIMD3((Float(x) + 0.5 - cx) / fx * z, -(Float(y) + 0.5 - cy) / fy * z, -z)
                            let world = SIMD3(t[0] * cam.x + t[1] * cam.y + t[2] * cam.z + t[3],
                                              t[4] * cam.x + t[5] * cam.y + t[6] * cam.z + t[7],
                                              t[8] * cam.x + t[9] * cam.y + t[10] * cam.z + t[11])
                            guard world.x.isFinite, world.y.isFinite, world.z.isFinite, occupied.insert(key(world)).inserted else { continue }
                            seeds.append(CloudPoint(x: world.x, y: world.y, z: world.z, r: rgb[4 * i], g: rgb[4 * i + 1], b: rgb[4 * i + 2]))
                        }
                    }
                }
            }
        }
        return seeds
    }

    /// Camera-frame angular (rad/s) and linear (m/s) velocity of every record from its
    /// neighbours in time, [ωx, ωy, ωz, vx, vy, vz] in OpenCV camera axes: with
    /// W(t + Δ) ≈ exp([ω]× Δ) W(t), a static point moves as p' = ω × p + v.
    ///
    /// Records at the ends, next to a gap, whose backward and forward differences disagree (a
    /// pose jump rather than motion), or faster than handheld limits get none: a wrong velocity
    /// would blur and shift every splat of that photo.
    static func motion(records: [FrameRecord]) -> [Int: [Double]] {
        let sorted = records.filter { $0.transform.count == 16 && $0.transform.allSatisfy(\.isFinite) && $0.timestamp.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 3 else { return [:] }
        func split(_ m: simd_double4x4) -> (simd_double3x3, SIMD3<Double>) {
            (simd_double3x3(SIMD3(m[0][0], m[0][1], m[0][2]), SIMD3(m[1][0], m[1][1], m[1][2]), SIMD3(m[2][0], m[2][1], m[2][2])),
             SIMD3(m[3][0], m[3][1], m[3][2]))
        }
        let poses = sorted.map { split(GaussianCamera.worldToCamera(arkitRowMajorC2W: $0.transform)) }
        func rates(_ i: Int, _ j: Int) -> (omega: SIMD3<Double>, v: SIMD3<Double>)? {
            let dt = sorted[j].timestamp - sorted[i].timestamp
            guard dt > 1e-3, dt < 0.3 else { return nil }
            let relative = poses[j].0 * poses[i].0.transpose
            let q = simd_quatd(relative)
            let angle = q.angle
            let omega = angle > 1e-9 ? q.axis * (angle > .pi ? angle - 2 * .pi : angle) / dt : SIMD3<Double>()
            let v = (poses[j].1 - relative * poses[i].1) / dt
            guard omega.x.isFinite, omega.y.isFinite, omega.z.isFinite, v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
            return (omega, v)
        }
        var out: [Int: [Double]] = [:]
        for k in 1..<(sorted.count - 1) {
            guard let back = rates(k - 1, k), let forward = rates(k, k + 1), let central = rates(k - 1, k + 1),
                  simd_length(back.omega - forward.omega) <= maxAngularChange,
                  simd_length(back.v - forward.v) <= maxLinearChange,
                  simd_length(central.omega) <= maxAngularSpeed, simd_length(central.v) <= maxLinearSpeed else { continue }
            out[sorted[k].id] = [central.omega.x, central.omega.y, central.omega.z, central.v.x, central.v.y, central.v.z]
        }
        return out
    }

    /// Handheld limits for `motion(records:)` (rad/s, m/s) and the largest change between the
    /// backward and forward differences that still reads as smooth motion.
    static let maxAngularSpeed = 3.0, maxLinearSpeed = 1.5
    static let maxAngularChange = 1.5, maxLinearChange = 0.8

    /// Range of the recorded exposure (log2 of exposure duration × ISO) over the scan's frames;
    /// nil when the capture did not record it. A locked exposure gives ~0.
    static func exposureRange(scan directory: URL) -> Double? {
        let evs = ScanLibrary.savedRecords(in: directory).0
            .compactMap { $0.exposureDuration > 0 && $0.iso > 0 ? log2($0.exposureDuration * $0.iso) : nil }
        guard let lo = evs.min(), let hi = evs.max() else { return nil }
        return hi - lo
    }

    /// PPISP defaults on when the capture's exposure varied (auto exposure); with a locked
    /// exposure there is little per-image difference to compensate.
    static let ppispExposureThreshold = 0.15

    init(directory: URL, frames: [TrainingFrame], points: [CloudPoint], width: Int, height: Int) {
        self.directory = directory; self.frames = frames; self.points = points; self.width = width; self.height = height
    }

    /// Stable identity of the training inputs; a checkpoint only resumes on the same inputs.
    var signature: String {
        var hasher = FNV64()
        hasher.add("\(width)x\(height)")
        for f in frames {
            hasher.add("\(f.id)|\(f.imageFile)|\(f.isValidation)|\(f.intrinsics.fx)|\(f.intrinsics.cx)|\(f.intrinsics.cy)")
            for v in f.transform { hasher.add(v.bitPattern) }
        }
        return String(format: "%016llx", hasher.value)
    }

    /// Rasterizer camera for frame `index` at the training resolution. `delta` is an optional
    /// pose correction applied in the camera frame: w2c' = [R_d | t_d] · w2c.
    /// `motion` renders the photo's capture motion (exposure blur and rolling-shutter readout
    /// in seconds); novel views and previews leave it nil.
    func camera(_ index: Int, delta: simd_double4x4? = nil, mipFilter: Bool,
                motion: (blur: Bool, readout: Double)? = nil) -> GaussianCamera {
        let f = frames[index]
        let sx = Double(width) / Double(f.intrinsics.width), sy = Double(height) / Double(f.intrinsics.height)
        var w2c = GaussianCamera.worldToCamera(arkitRowMajorC2W: f.transform)
        if let delta { w2c = delta * w2c }
        var camera = GaussianCamera(worldToCamera: w2c, fx: f.intrinsics.fx * sx, fy: f.intrinsics.fy * sy,
                                    cx: f.intrinsics.cx * sx, cy: f.intrinsics.cy * sy, width: width, height: height,
                                    mipFilter: mipFilter)
        if let motion, let m = f.motion, m.count == 6 {
            camera.angularMotion = SIMD4(Float(m[0]), Float(m[1]), Float(m[2]), Float(motion.readout))
            camera.linearMotion = SIMD4(Float(m[3]), Float(m[4]), Float(m[5]), motion.blur ? Float(f.exposure ?? 0) : 0)
        }
        return camera
    }

    /// Frame `index`'s LiDAR depth map and confidence, if it has one.
    func lidarDepth(_ index: Int) -> (width: Int, height: Int, depth: [Float], confidence: [UInt8])? {
        let f = frames[index]
        guard let file = f.depthFile, let w = f.depthWidth, let h = f.depthHeight, w > 0, h > 0,
              let data = try? Data(contentsOf: directory.appendingPathComponent("depth").appendingPathComponent(file)),
              data.count == w * h * 4 else { return nil }
        let depth = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let confidence = f.confidenceFile.flatMap { try? Data(contentsOf: directory.appendingPathComponent("depth").appendingPathComponent($0)) }
            .flatMap { $0.count == w * h ? [UInt8]($0) : nil } ?? [UInt8](repeating: 1, count: w * h)
        return (w, h, depth, confidence)
    }

    func imageURL(_ index: Int) -> URL {
        directory.appendingPathComponent("images").appendingPathComponent(frames[index].imageFile)
    }
}

/// 64-bit FNV-1a, used for dataset signatures and checkpoint integrity.
nonisolated struct FNV64 {
    private(set) var value: UInt64 = 0xcbf29ce484222325
    mutating func add(_ bytes: UnsafeRawBufferPointer) {
        for b in bytes { value = (value ^ UInt64(b)) &* 0x100000001b3 }
    }
    mutating func add(_ string: String) { var s = string; s.withUTF8 { add(UnsafeRawBufferPointer($0)) } }
    mutating func add<T>(_ value: T) { withUnsafeBytes(of: value) { add($0) } }
}

/// Decodes training images at the training resolution on demand, with a small bounded cache.
/// Photos are streamed from the scan's JPEGs; nothing is written to disk.
nonisolated final class TrainingImageLoader: @unchecked Sendable {
    enum LoadError: LocalizedError {
        case decodeFailed(String)
        var errorDescription: String? {
            switch self { case .decodeFailed(let name): return L10n.text("無法讀取訓練影像：\(name)") }
        }
    }

    let width: Int, height: Int
    private let capacity: Int
    private let lock = NSLock()
    private var cache: [Int: [UInt8]] = [:]
    private var order: [Int] = []
    private var pending: Set<Int> = []
    private let queue = DispatchQueue(label: "gaussian-training.images", qos: .userInitiated)
    private let url: (Int) -> URL

    static func bytes(width: Int, height: Int, slots: Int) -> Int { width * height * 4 * slots }

    init(width: Int, height: Int, slots: Int, url: @escaping (Int) -> URL) {
        self.width = width; self.height = height; capacity = max(1, slots); self.url = url
    }

    /// RGBA8 pixels at the training resolution (sensor orientation, no EXIF transform).
    static func decode(_ url: URL, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }

    /// Starts decoding `index` in the background unless cached or pending.
    func prefetch(_ index: Int) {
        lock.lock()
        guard cache[index] == nil, !pending.contains(index) else { lock.unlock(); return }
        pending.insert(index)
        lock.unlock()
        queue.async { [self] in
            let pixels = autoreleasepool { Self.decode(url(index), width: width, height: height) }
            lock.lock()
            pending.remove(index)
            if let pixels { insert(index, pixels) }
            lock.unlock()
        }
    }

    private func insert(_ index: Int, _ pixels: [UInt8]) {
        cache[index] = pixels
        order.removeAll { $0 == index }
        order.append(index)
        while order.count > capacity { cache[order.removeFirst()] = nil }
    }

    /// Copies frame `index` into `destination` (width × height × 4 bytes), decoding if needed.
    func load(_ index: Int, into destination: UnsafeMutableRawPointer) throws {
        lock.lock()
        let hit = cache[index]
        let isPending = pending.contains(index)
        lock.unlock()
        var pixels = hit
        if pixels == nil && isPending {
            queue.sync {}          // wait for the in-flight decode
            lock.lock(); pixels = cache[index]; lock.unlock()
        }
        if pixels == nil {
            pixels = autoreleasepool { Self.decode(url(index), width: width, height: height) }
            if let pixels { lock.lock(); insert(index, pixels); lock.unlock() }
        }
        guard let pixels else { throw LoadError.decodeFailed(url(index).lastPathComponent) }
        pixels.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: width * height * 4) }
    }

    /// Releases every cached image (memory pressure).
    func purge() {
        lock.lock(); cache.removeAll(); order.removeAll(); lock.unlock()
    }
}
