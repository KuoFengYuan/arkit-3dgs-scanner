// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import simd

/// Trained-model files. `gaussians.ply` is the standard INRIA 3DGS layout (positions, zero
/// normals, SH DC + rest, opacity logit, log scales, wxyz rotation) read by common 3DGS
/// viewers and trainers. It uses the same world frame as the dataset export's `sparse/0`
/// (ARKit world rotated 180° about X, metres) so it lines up with the COLMAP cameras.
/// Colours are pre-ISP radiance: the per-image PPISP compensation lives in `ppisp.json`.
nonisolated enum GaussianExport {
    static let plyName = "gaussians.ply"
    static let metadataName = "gaussians.json"
    static let ppispName = "ppisp.json"
    static let posesName = "training-poses.jsonl"
    static let reportName = "training-report.json"

    enum ExportError: LocalizedError {
        case empty, unsupported, damaged
        var errorDescription: String? {
            switch self {
            case .empty: return L10n.text("模型沒有可匯出的高斯")
            case .unsupported: return L10n.text("此 3DGS 模型格式不支援")
            case .damaged: return L10n.text("3DGS 模型檔案不完整")
            }
        }
    }

    // MARK: Coordinate frame

    /// Parity of each real SH basis function under (x, y, z) -> (x, -y, -z).
    static let shFlipSigns: [Float] = [1, -1, -1, 1, -1, 1, 1, -1, 1, -1, 1, -1, -1, 1, -1, 1]

    /// 180° rotation about X applied to a wxyz quaternion: q' = (0, 1, 0, 0) ⊗ q.
    static func flipQuaternion(_ q: SIMD4<Float>) -> SIMD4<Float> { SIMD4(-q.y, q.x, -q.w, q.z) }
    /// Inverse of `flipQuaternion` (the flip applied twice is a 360° rotation, q -> -q).
    static func unflipQuaternion(_ q: SIMD4<Float>) -> SIMD4<Float> { -flipQuaternion(q) }

    // MARK: PLY

    static func propertyNames(shDegree: Int) -> [String] {
        let rest = 3 * ((shDegree + 1) * (shDegree + 1) - 1)
        return ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2"] + (0..<rest).map { "f_rest_\($0)" }
            + ["opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
    }

    /// Writes the live rows of `model` in the export frame, streaming in chunks.
    static func writePLY(_ model: GaussianModel, to url: URL, comment: String) throws {
        let rows = model.liveRows
        guard !rows.isEmpty else { throw ExportError.empty }
        let names = propertyNames(shDegree: model.shDegree)
        var header = "ply\nformat binary_little_endian 1.0\n"
        header += "comment \(comment)\n"
        header += "comment frame: ARKit world rotated 180 deg about X (COLMAP export frame, Y down), metres\n"
        header += "element vertex \(rows.count)\n"
        for name in names { header += "property float \(name)\n" }
        header += "end_header\n"
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: temporary) } }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: Data(header.utf8))
        let L = model.layout, p = model.floats(model.params)
        let rest = model.shRest
        let stride = names.count
        let chunkRows = max(1, (4 << 20) / (stride * 4))
        var buffer = [Float](repeating: 0, count: chunkRows * stride)
        var filled = 0
        func flush() throws {
            guard filled > 0 else { return }
            try buffer.withUnsafeBytes { try handle.write(contentsOf: Data($0[0..<(filled * stride * 4)])) }
            filled = 0
        }
        for row in rows {
            var o = filled * stride
            let m = SIMD3(p[Int(L.means) + 3 * row], p[Int(L.means) + 3 * row + 1], p[Int(L.means) + 3 * row + 2])
            buffer[o] = m.x; buffer[o + 1] = -m.y; buffer[o + 2] = -m.z
            buffer[o + 3] = 0; buffer[o + 4] = 0; buffer[o + 5] = 0
            for c in 0..<3 { buffer[o + 6 + c] = p[Int(L.sh0) + 3 * row + c] }
            o += 9
            // INRIA order: all rest coefficients of red, then green, then blue.
            for c in 0..<3 { for k in 0..<rest {
                buffer[o + c * rest + k] = p[Int(L.shN) + row * rest * 3 + k * 3 + c] * shFlipSigns[k + 1]
            } }
            o += 3 * rest
            buffer[o] = p[Int(L.opacities) + row]
            for k in 0..<3 { buffer[o + 1 + k] = p[Int(L.scales) + 3 * row + k] }
            var q = SIMD4(p[Int(L.quats) + 4 * row], p[Int(L.quats) + 4 * row + 1], p[Int(L.quats) + 4 * row + 2], p[Int(L.quats) + 4 * row + 3])
            q = flipQuaternion(simd_normalize(q))
            for k in 0..<4 { buffer[o + 4 + k] = q[k] }
            filled += 1
            if filled == chunkRows { try flush() }
        }
        try flush()
        try handle.synchronize()
        try handle.close()
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
        published = true
    }

    struct LoadedModel {
        var count: Int
        var shDegree: Int
    }

    /// Reads an INRIA-layout PLY (any SH degree ≤ 3) into `model` (ARKit frame). `limit` caps
    /// the rows read (memory); returns nil header info when the file does not match.
    static func readHeader(_ url: URL) throws -> (count: Int, shDegree: Int, headerBytes: Int, names: [String]) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 65_536) else { throw ExportError.damaged }
        guard let end = prefix.range(of: Data("end_header\n".utf8)),
              let text = String(data: prefix[..<end.upperBound], encoding: .ascii) else { throw ExportError.damaged }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.contains("format binary_little_endian 1.0"),
              let vertex = lines.first(where: { $0.hasPrefix("element vertex ") }),
              let count = Int(vertex.split(separator: " ").last ?? "") else { throw ExportError.unsupported }
        let names = lines.filter { $0.hasPrefix("property float ") }.map { String($0.dropFirst("property float ".count)) }
        guard names.count == lines.filter({ $0.hasPrefix("property ") }).count else { throw ExportError.unsupported }
        let rest = names.filter { $0.hasPrefix("f_rest_") }.count
        let degree: Int
        switch rest { case 0: degree = 0; case 9: degree = 1; case 24: degree = 2; case 45: degree = 3; default: throw ExportError.unsupported }
        guard names == propertyNames(shDegree: degree) else { throw ExportError.unsupported }
        return (count, degree, end.upperBound, names)
    }

    /// Reads the PLY into `model`. A model of a higher SH degree gets the file's coefficients
    /// and zero for the extra bands (Enhance model can raise the degree).
    static func readPLY(_ url: URL, into model: GaussianModel) throws -> Int {
        let info = try readHeader(url)
        guard info.shDegree <= model.shDegree, info.count <= model.capacity else { throw ExportError.unsupported }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let stride = info.names.count * 4
        guard data.count >= info.headerBytes + info.count * stride else { throw ExportError.damaged }
        let rest = model.shRest, fileRest = (info.shDegree + 1) * (info.shDegree + 1) - 1
        model.initialize(positions: [], colors: [])
        let L = model.layout, p = model.floats(model.params)
        data.withUnsafeBytes { raw in
            for row in 0..<info.count {
                let base = info.headerBytes + row * stride
                func f(_ k: Int) -> Float { raw.loadUnaligned(fromByteOffset: base + 4 * k, as: Float.self) }
                p[Int(L.means) + 3 * row] = f(0); p[Int(L.means) + 3 * row + 1] = -f(1); p[Int(L.means) + 3 * row + 2] = -f(2)
                for c in 0..<3 { p[Int(L.sh0) + 3 * row + c] = f(6 + c) }
                for c in 0..<3 { for k in 0..<rest {
                    p[Int(L.shN) + row * rest * 3 + k * 3 + c] = k < fileRest ? f(9 + c * fileRest + k) * shFlipSigns[k + 1] : 0
                } }
                let o = 9 + 3 * fileRest
                p[Int(L.opacities) + row] = f(o)
                for k in 0..<3 { p[Int(L.scales) + 3 * row + k] = f(o + 1 + k) }
                let q = unflipQuaternion(SIMD4(f(o + 4), f(o + 5), f(o + 6), f(o + 7)))
                for k in 0..<4 { p[Int(L.quats) + 4 * row + k] = q[k] }
            }
        }
        model.restore(rowCount: info.count, adamStep: 0)
        return info.count
    }

    // MARK: Sidecars

    struct Metadata: Codable {
        var format = "3dgs-ply"
        var version = 1
        var gaussians: Int
        var shDegree: Int
        var coordinateFrame = "ARKit world rotated 180° about X (same as sparse/0 of the dataset export), metres"
        var mipFilter2D: Bool
        var filterVariancePx2: Float
        var opacityCompensation: Bool
        var colorSpace = "pre-ISP radiance (sRGB-encoded training targets); per-image PPISP in ppisp.json"
        var ppisp: String?
        var iterations: Int
        var configuration: GaussianTrainingConfiguration
        var createdAt: Date
        var validationPSNR: Double?
        var viewerNotes: [String]
    }

    struct PPISPFile: Codable {
        struct Camera: Codable { var vignetting: [[Double]]; var responseRaw: [[Double]]; var response: [[Double]] }
        struct Frame: Codable { var id: Int; var image: String; var exposureEV: Double; var colorLatents: [Double]; var homography: [Double] }
        var format = "ppisp"
        var version = PPISPModel.formatVersion
        var model = "Physically-Plausible ISP (nv-tlabs/ppisp) as used by LichtFeld Studio"
        var pipeline = ["exposure: rgb * 2^EV", "vignetting: rgb_c * clamp(1 + a0 r² + a1 r⁴ + a2 r⁶, 0, 1), r from (cx, cy) in max(W, H)-normalised coordinates",
                        "colour: chromaticity homography on (R, G, R+G+B), intensity preserving",
                        "response: toe/shoulder curve (tau, eta, centre) then gamma, per channel"]
        var appliesTo = "images rendered from gaussians.ply"
        var novelView = "0 EV, identity colour, camera 0 vignetting and response"
        var seedMeanEV: Double?
        var cameras: [Camera]
        var frames: [Frame]
    }

    /// The saved model's metadata (`gaussians.json`), or nil.
    static func metadata(in directory: URL) -> Metadata? {
        (try? Data(contentsOf: directory.appendingPathComponent(metadataName)))
            .flatMap { try? JSONDecoder.training.decode(Metadata.self, from: $0) }
    }

    static func ppispFile(_ ppisp: PPISPModel, frames: [TrainingFrame]) -> PPISPFile {
        var cameras: [PPISPFile.Camera] = []
        for c in 0..<ppisp.cameras {
            let v = ppisp.vignettingOffset + c * 15, r = ppisp.crfOffset + c * 12
            cameras.append(PPISPFile.Camera(
                vignetting: (0..<3).map { ch in (0..<5).map { ppisp.parameters[v + ch * 5 + $0] } },
                responseRaw: (0..<3).map { ch in (0..<4).map { ppisp.parameters[r + ch * 4 + $0] } },
                response: (0..<3).map { ch in let k = ppisp.crf(camera: c, channel: ch); return [k.tau, k.eta, k.gamma, k.center] }))
        }
        let list = frames.enumerated().map { index, frame -> PPISPFile.Frame in
            let latents = Array(ppisp.parameters[(ppisp.colorOffset + index * 8)..<(ppisp.colorOffset + index * 8 + 8)])
            let H = PPISPModel.homography(latents[0..<8])
            return PPISPFile.Frame(id: frame.id, image: frame.imageFile, exposureEV: ppisp.exposure(frame: index),
                                   colorLatents: latents, homography: (0..<3).flatMap { r in (0..<3).map { H[$0][r] } })
        }
        return PPISPFile(seedMeanEV: ppisp.seedMeanEV, cameras: cameras, frames: list)
    }

    static func viewerNotes(mipFilter: Bool, ppisp: Bool) -> [String] {
        var notes = [
            "Standard 3DGS viewers read gaussians.ply directly. Most assume a Y-up world and show this COLMAP-frame model upside down; rotate it 180° about X.",
        ]
        if mipFilter {
            notes.append("Trained with the Mip-Splatting 2D filter (0.1 px² dilation with opacity compensation). Viewers without an anti-aliased mode dilate by 0.3 px² without compensation, so small splats look slightly thicker and brighter.")
        }
        if ppisp {
            notes.append("Colours are pre-ISP. ppisp.json holds the per-image exposure/colour and the camera vignetting/response; viewers ignore it and show the uncorrected appearance (the in-app ‘ISP off’ view).")
        }
        return notes
    }

    /// Corrected ARKit camera-to-world (row-major) for a pose correction.
    static func correctedTransform(_ original: [Double], correction: PoseCorrection) -> [Double] {
        let w2c = correction.matrix * GaussianCamera.worldToCamera(arkitRowMajorC2W: original)
        var c2w = GaussianCamera.rigidInverse(w2c)
        c2w.columns.1 = -c2w.columns.1
        c2w.columns.2 = -c2w.columns.2
        return (0..<4).flatMap { r in (0..<4).map { c2w[$0][r] } }
    }
}

nonisolated extension PPISPModel {
    /// Restores a saved model's colour model (`ppisp.json`), matching frames by id; frames it
    /// does not list keep their initial values. The optimiser state starts fresh.
    mutating func restore(_ file: GaussianExport.PPISPFile, frames list: [TrainingFrame]) {
        let byID = Dictionary(file.frames.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (index, frame) in list.enumerated() where index < frames {
            guard let saved = byID[frame.id], saved.colorLatents.count == 8, saved.exposureEV.isFinite else { continue }
            parameters[exposureOffset + index] = saved.exposureEV
            for k in 0..<8 { parameters[colorOffset + index * 8 + k] = saved.colorLatents[k] }
        }
        for (c, camera) in file.cameras.prefix(cameras).enumerated() {
            for ch in 0..<3 {
                if camera.vignetting.count == 3, camera.vignetting[ch].count == 5 {
                    for k in 0..<5 { parameters[vignettingOffset + c * 15 + ch * 5 + k] = camera.vignetting[ch][k] }
                }
                if camera.responseRaw.count == 3, camera.responseRaw[ch].count == 4 {
                    for k in 0..<4 { parameters[crfOffset + c * 12 + ch * 4 + k] = camera.responseRaw[ch][k] }
                }
            }
        }
    }
}
