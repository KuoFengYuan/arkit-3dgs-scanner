import Foundation
import simd
import ImageIO
import CoreGraphics

/// RGB selection never changes BlurVerdict or removes photos/depth. Motion estimates alone
/// are not evidence of optical blur. Only replace a view when a nearby, clearer view exists.
nonisolated enum TrainingFrameSelector {
    struct Decision: Codable, Sendable {
        let frameID: Int
        let imageFile: String
        let timestamp: Double
        let selected: Bool
        let reason: String
        let replacementID: Int?
    }
    struct Report: Codable, Sendable {
        var version = 3
        let inputFrames: Int
        let selectedIDs: [Int]
        let recaptureIDs: [Int]
        let decisions: [Decision]
        var motionRiskIDs: [Int]? = nil
        var weakDetailIDs: [Int]? = nil
        var uncertainDetailIDs: [Int]? = nil
        /// Only measured weak detail warrants a recapture banner. Motion is a risk
        /// estimate, and textureless/unmeasured images have unknown sharpness.
        var notice: String? {
            guard let weakDetailIDs, !weakDetailIDs.isEmpty else { return nil }
            let ids = weakDetailIDs.prefix(5).map(String.init).joined(separator: ", ")
            return L10n.text("\(weakDetailIDs.count) 張視角細節偏弱，建議檢查或補拍（影格 \(ids)）。")
        }

        var diagnosticSummary: String? {
            guard let motionRiskIDs, let uncertainDetailIDs, weakDetailIDs != nil else {
                return recaptureIDs.isEmpty ? nil
                    : L10n.text("舊版報告有 \(recaptureIDs.count) 張品質待確認的視角，未區分運動估計與實測細節；可重新優化資料。")
            }
            var notes: [String] = []
            if !motionRiskIDs.isEmpty {
                notes.append(L10n.text("\(motionRiskIDs.count) 張拍攝時的運動估計偏高；這不代表照片已模糊，也不單獨要求補拍。"))
            }
            if !uncertainDetailIDs.isEmpty {
                notes.append(L10n.text("\(uncertainDetailIDs.count) 張低紋理或資料不足，無法判定清晰度。"))
            }
            return notes.isEmpty ? nil : notes.joined(separator: "\n")
        }
    }
    struct Evidence: Sendable {
        let detail: Double
        let signature: [Float]
    }

    /// Small thumbnails only; each image is released before reading the next one.
    static func evidence(records: [FrameRecord], directory: URL,
                         isCancelled: () -> Bool = { false }) -> [Int: Evidence] {
        var out: [Int: Evidence] = [:]
        for r in records where r.blurVerdict == .keep {
            if isCancelled() { break }
            if let e = autoreleasepool(invoking: { measure(r, directory: directory) }) { out[r.id] = e }
        }
        return out
    }

    static func select(_ records: [FrameRecord], evidence: [Int: Evidence] = [:]) -> Report {
        let candidates = records.filter { $0.blurVerdict == .keep }
        func score(_ r: FrameRecord) -> Double {
            if let e = evidence[r.id] { return e.detail }
            return r.sharpness.isFinite ? max(0, r.sharpness) : 0
        }
        func near(_ a: FrameRecord, _ b: FrameRecord) -> Bool {
            guard a.transform.count == 16, b.transform.count == 16,
                  a.transform.allSatisfy(\.isFinite), b.transform.allSatisfy(\.isFinite) else { return false }
            let x = a.transform, y = b.transform
            // Conservative: do not suppress parallax, camera roll, or a new view around an occluder.
            let d2 = pow(x[3]-y[3], 2) + pow(x[7]-y[7], 2) + pow(x[11]-y[11], 2)
            let trace = [0,1,2,4,5,6,8,9,10].reduce(0.0) { $0 + x[$1] * y[$1] }
            return d2 <= 0.04 * 0.04 && (trace - 1) / 2 >= cos(3 * .pi / 180)
        }
        func similar(_ a: FrameRecord, _ b: FrameRecord) -> Bool {
            guard let x = evidence[a.id], let y = evidence[b.id], !x.signature.isEmpty,
                  x.signature.count == y.signature.count else { return false }
            let error = zip(x.signature, y.signature).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }
            return error / Float(x.signature.count) < 0.06
        }
        let ranked = candidates.sorted {
            let a = score($0), b = score($1)
            return a == b ? $0.id < $1.id : a > b
        }
        var selected: [FrameRecord] = []
        var replacements: [Int: Int] = [:]
        for r in ranked {
            let replacement = selected.first { s in
                guard near(r, s), score(r) > 0, score(s) > 0 else { return false }
                // Image evidence is required for de-duplication and visibility preservation.
                // Without it (legacy scans), retain the view rather than assuming overlap.
                return similar(r, s)
            }
            if let replacement { replacements[r.id] = replacement.id }
            else { selected.append(r) }
        }
        let selectedByID = selected.reduce(into: [Int: FrameRecord]()) { $0[$1.id] = $1 }
        let ids = Set(selected.map(\.id))
        let weakIDs = selected.filter {
            // A relative drop needs a valid detail measurement; a white wall or missing
            // measurement is uncertainty, not evidence that recapture will help.
            score($0) > 0 && $0.sharpness > 0 && $0.sharpness.isFinite
                && $0.sharpnessRatio.isFinite && $0.sharpnessRatio < 0.5
        }.map(\.id).sorted()
        var report = Report(inputFrames: records.count, selectedIDs: ids.sorted(), recaptureIDs: weakIDs,
                      decisions: records.map { r in
            let reason: String
            if r.blurVerdict == .drop { reason = "unreliableGeometry" }
            else if r.blurVerdict == .demote { reason = "rgbRejectedDepthRetained" }
            else if let replacement = replacements[r.id] {
                reason = score(r) < score(selectedByID[replacement]!) * 0.65
                    ? "clearerEquivalentView" : "redundantView"
            } else { reason = weakIDs.contains(r.id) ? "coverageFallbackCheckOrRecapture" : "distinctView" }
            return Decision(frameID: r.id, imageFile: r.imageFile, timestamp: r.timestamp,
                            selected: ids.contains(r.id), reason: reason, replacementID: replacements[r.id])
        })
        report.weakDetailIDs = weakIDs
        let weak = Set(report.weakDetailIDs ?? [])
        report.motionRiskIDs = selected.filter { $0.estimatedBlurPx > BlurFilter.kTrainBlurPx && !weak.contains($0.id) }.map(\.id).sorted()
        report.uncertainDetailIDs = selected.filter { score($0) <= 0 && !weak.contains($0.id) }.map(\.id).sorted()
        return report
    }

    static func measure(_ record: FrameRecord, directory: URL) -> Evidence? {
        guard let gray = ScanImageDecoder.gray(record, directory: directory, maxDimension: 320) else { return nil }
        let w = gray.width, h = gray.height, p = gray.pixels
        var gradient = 0.0, laplacian = 0.0
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y*w+x, c = Double(p[i])
            let dx = Double(p[i+1])-Double(p[i-1]), dy = Double(p[i+w])-Double(p[i-w])
            let l = Double(p[i-1])+Double(p[i+1])+Double(p[i-w])+Double(p[i+w])-4*c
            gradient += dx*dx+dy*dy; laplacian += l*l
        } }
        // Low-texture surfaces have no reliable blur evidence. Do not classify white walls as bad.
        let detail = gradient / Double(w*h) > 4 ? laplacian / max(1, gradient) : 0
        var signature: [Float] = []
        for gy in 0..<12 { for gx in 0..<16 {
            var sum: Float = 0, n: Float = 0
            for y in (gy*h/12)..<((gy+1)*h/12) { for x in (gx*w/16)..<((gx+1)*w/16) {
                sum += Float(p[y*w+x]) / 255; n += 1
            } }
            signature.append(sum / max(1,n))
        } }
        return Evidence(detail: detail, signature: signature)
    }
}

/// Sensor-oriented decoding shared by selection and offline matching. Never apply EXIF rotation:
/// pixel coordinates must remain in the same convention as the recorded intrinsics.
nonisolated enum ScanImageDecoder {
    struct Gray: Sendable { let pixels: [UInt8]; let width: Int; let height: Int }
    static func gray(_ record: FrameRecord, directory: URL, maxDimension: Int) -> Gray? {
        guard record.imageFile == (record.imageFile as NSString).lastPathComponent,
              record.intrinsics.width > 0, record.intrinsics.height > 0 else { return nil }
        let url = directory.appendingPathComponent("images").appendingPathComponent(record.imageFile)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              props[kCGImagePropertyPixelWidth] as? Int == record.intrinsics.width,
              props[kCGImagePropertyPixelHeight] as? Int == record.intrinsics.height else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceThumbnailMaxPixelSize: max(32, min(1280, maxDimension)),
                                    kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
              image.width >= 16, image.height >= 16 else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w*h)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        return ok ? Gray(pixels: pixels, width: w, height: h) : nil
    }

    /// Native-resolution luminance for sub-pixel feature refinement; same sensor orientation.
    static func fullGray(_ record: FrameRecord, directory: URL) -> Gray? {
        guard record.imageFile == (record.imageFile as NSString).lastPathComponent,
              record.intrinsics.width > 0, record.intrinsics.height > 0,
              record.intrinsics.width <= 8192, record.intrinsics.height <= 8192 else { return nil }
        let url = directory.appendingPathComponent("images").appendingPathComponent(record.imageFile)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == record.intrinsics.width, image.height == record.intrinsics.height else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w*h)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        return ok ? Gray(pixels: pixels, width: w, height: h) : nil
    }
}
