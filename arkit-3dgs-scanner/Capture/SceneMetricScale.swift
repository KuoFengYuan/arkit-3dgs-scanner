import Foundation
import CryptoKit
import simd

/// A scale reference belongs to one immutable preview geometry. It never changes raw RGB/depth.
nonisolated struct SceneMetricScale: Codable, Sendable, Equatable {
    /// Prefer the aimed pixel; depth only breaks ties within two screen points. A foreground
    /// point elsewhere in the finger radius must not steal a precisely aimed background point.
    static func pickProjectedIndex(_ points: [SIMD3<Float>], at aim: SIMD2<Float>, radius: Float = 18) -> Int? {
        func distance(_ p: SIMD3<Float>) -> Float {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, p.z >= 0, p.z < 1 else { return .infinity }
            return simd_distance(SIMD2(p.x,p.y),aim)
        }
        let closest = points.reduce(Float.infinity) { min($0,distance($1)) }
        guard closest <= radius else { return nil }
        var picked: Int?, bestDepth: Float = .infinity
        for (i,p) in points.enumerated() where distance(p) <= min(radius,closest+2) {
            if p.z < bestDepth { picked = i; bestDepth = p.z }
        }
        return picked
    }

    struct Reference: Codable, Sendable, Equatable {
        var start: [Double]
        var end: [Double]
        var knownMeters: Double
        var measuredMeters: Double {
            guard start.count == 3, end.count == 3 else { return .nan }
            return zip(start,end).reduce(0) { $0 + pow($1.0 - $1.1, 2) }.squareRoot()
        }
        var valid: Bool {
            start.count == 3 && end.count == 3 && (start + end).allSatisfy(\.isFinite)
                && knownMeters.isFinite && (0.1...1000).contains(knownMeters)
                && measuredMeters.isFinite && measuredMeters >= 0.1
        }
        func independent(of other: Self) -> Bool {
            guard valid, other.valid else { return false }
            let p = SIMD3(start[0],start[1],start[2]), q = SIMD3(end[0],end[1],end[2])
            let a = SIMD3(other.start[0],other.start[1],other.start[2]), b = SIMD3(other.end[0],other.end[1],other.end[2])
            return simd_distance((p+q)/2,(a+b)/2) >= 0.5
                || abs(simd_dot(simd_normalize(q-p),simd_normalize(b-a))) < 0.85
        }
    }
    enum MetricError: LocalizedError {
        case invalidReference, repeatedReference, staleGeometry, invalidScale, missingCloud
        var errorDescription: String? {
            switch self {
            case .invalidReference: return L10n.text("請選取相隔至少 10 公分的兩點，並輸入有效的已知公尺長度。")
            case .repeatedReference: return L10n.text("請選另一處或不同方向的距離驗證，不可用校正的同一段距離驗證自己。")
            case .staleGeometry: return L10n.text("點雲已更新，請重新選點校正與驗證尺度。")
            case .invalidScale: return L10n.text("尺度倍率超出 0.5–2 倍，請檢查選點與公尺單位。")
            case .missingCloud: return L10n.text("目前沒有可量測的點雲。")
            }
        }
    }
    var version = 1
    var geometrySHA256: String
    var calibration: Reference?
    var validations: [Reference] = []
    var metersPerSourceUnit: Double { calibration.map { $0.knownMeters / $0.measuredMeters } ?? 1 }
    var residualsMeters: [Double] { validations.map { $0.measuredMeters * metersPerSourceUnit - $0.knownMeters } }
    var referencesPass: Bool {
        !validations.isEmpty && zip(validations,residualsMeters).allSatisfy { abs($1) <= max(0.02, $0.knownMeters * 0.01) }
    }
    var status: String {
        if !validations.isEmpty { return referencesPass ? "referenceDistancesPassed" : "referenceDistancesFailed" }
        return calibration == nil ? "nominalUnverified" : "calibratedUnverified"
    }
    var statusText: String {
        switch status {
        case "referenceDistancesPassed": return L10n.text("參考距離驗證通過")
        case "referenceDistancesFailed": return L10n.text("參考距離存在誤差")
        case "calibratedUnverified": return L10n.text("已校正，尚未獨立驗證")
        default: return L10n.text("ARKit 公尺尺度，尚未驗證")
        }
    }
    func checked() throws -> Self {
        guard version == 1, calibration?.valid != false, validations.count <= 8,
              validations.allSatisfy(\.valid) else { throw MetricError.invalidReference }
        guard metersPerSourceUnit.isFinite, (0.5...2).contains(metersPerSourceUnit) else { throw MetricError.invalidScale }
        if let calibration, validations.contains(where: { !$0.independent(of: calibration) }) { throw MetricError.repeatedReference }
        return self
    }
    func scaled(_ records: [FrameRecord]) throws -> [FrameRecord] {
        _ = try checked()
        return try records.map { record in
            guard record.transform.count == 16 else { throw MetricError.invalidReference }
            var out = record
            for i in [3,7,11] { out.transform[i] *= metersPerSourceUnit }
            // This export has no raw depth: prevent reuse as if the depth had been scaled too.
            out.depthFile = nil; out.confidenceFile = nil; out.depthWidth = nil; out.depthHeight = nil
            return out
        }
    }
    func scaled(_ points: [CloudPoint]) throws -> [CloudPoint] {
        _ = try checked(); let factor = Float(metersPerSourceUnit)
        return points.map { point in var p = point; p.x *= factor; p.y *= factor; p.z *= factor; return p }
    }
    static func cloudURL(in directory: URL) throws -> URL {
        for name in ["review.ply", "points.ply"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw MetricError.missingCloud
    }
    static func fingerprint(in directory: URL) throws -> String {
        let data = try Data(contentsOf: cloudURL(in: directory), options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func load(in directory: URL) throws -> Self {
        let signature = try fingerprint(in: directory)
        let path = directory.appendingPathComponent("scale-measurements.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return Self(geometrySHA256: signature) }
        let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        guard saved.geometrySHA256 == signature else { throw MetricError.staleGeometry }
        return try saved.checked()
    }
    func save(in directory: URL) throws {
        _ = try checked()
        guard geometrySHA256 == (try Self.fingerprint(in: directory)) else { throw MetricError.staleGeometry }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("scale-measurements.json"), options: .atomic)
    }
    func writeManifest(to directory: URL) throws {
        _ = try checked()
        let factor = metersPerSourceUnit
        let manifest: [String: Any] = [
            "version": 1, "units": "meters", "scaleApplied": true,
            "sourceMetersPerUnit": factor, "verificationStatus": status,
            "sourceGeometrySHA256": geometrySHA256,
            "sourceToMetric": [factor,0,0,0, 0,factor,0,0, 0,0,factor,0, 0,0,0,1],
            "metricToSource": [1/factor,0,0,0, 0,1/factor,0,0, 0,0,1/factor,0, 0,0,0,1],
            "pointAndJSONLPoseCoordinates": "arkit_gravity_y_up",
            "colmapWorldRotationFromMetric": [1,0,0, 0,-1,0, 0,0,-1],
            "validationResidualsMeters": residualsMeters,
            "validationTolerance": "max(0.02 meters, 1 percent of reference length)",
            "absoluteSceneAccuracyCertified": false,
            "rawDepthIncluded": false,
            "note": "Reference checks are not a survey accuracy certificate. Preserve/invert any downstream trainer normalization."
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted,.sortedKeys])
            .write(to: directory.appendingPathComponent("scene-metrics.json"), options: .atomic)
    }
}
