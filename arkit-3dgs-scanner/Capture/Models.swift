//
//  Models.swift
//  fable — 資料模型與序列化格式
//

import Foundation
import CoreVideo
import simd

/// 針孔相機內參（像素單位，對應 sensor 座標的原始影像解析度）
nonisolated struct CameraIntrinsics: Codable, Sendable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var width: Int
    var height: Int

    /// 依目標解析度線性縮放（例如 1920×1440 → 深度圖 256×192）
    func scaled(toWidth w: Int, height h: Int) -> CameraIntrinsics {
        let sx = Double(w) / Double(width)
        let sy = Double(h) / Double(height)
        return CameraIntrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, width: w, height: h)
    }
}

/// poses.jsonl 每行一筆。
/// transform 為 row-major 4×4 camera-to-world，ARKit/OpenGL 相機慣例（X右、Y上、-Z 為視線方向），
/// 世界座標為 ARKit gravity 對齊（+Y 為反重力方向），單位公尺。
nonisolated struct FrameRecord: Codable, Sendable {
    var id: Int
    /// ARFrame.timestamp：開機起算的單調時鐘（秒），影像/深度/姿態取自同一 ARFrame，天然同步
    var timestamp: Double
    var transform: [Double]
    var intrinsics: CameraIntrinsics
    var exposureDuration: Double
    var exposureOffsetEV: Double
    /// 拍攝當下的感光度。顆粒感的直接成因，也是判斷「要不要降噪」的依據 ——
    /// 低 ISO 還有顆粒代表問題不在感光度，降噪只會白白吃掉細節。
    var iso: Double = 0
    var ambientLux: Double?
    var estimatedBlurPx: Double
    /// 影像清晰度的直接量測（歸一化二階差分能量）與其相對基準線的比例。
    /// 離線挑幀用：同一區域拍到多張時，可據此選最鋭利的餵給訓練。
    var sharpness: Double = 0
    var sharpnessRatio: Double = 1
    /// 掃描結束後的全域複核結果（見 BlurFilter）。刻意保留在紀錄裡而非直接刪除 ——
    /// 被排除的幀仍留在 poses_refined.jsonl 與 images/ 內，可回頭檢查判定對不對。
    var blurVerdict: BlurVerdict = .keep
    var imageFile: String
    var depthFile: String?
    var confidenceFile: String?
    var depthWidth: Int?
    var depthHeight: Int?
}

/// Scan metadata has a capture-specific name so trainer format detection ignores it.
/// Legacy scans remain readable; export migrates the filename without changing its bytes.
nonisolated enum CaptureMetadata {
    static let fileName = "capture-meta.json"
    static let legacyFileName = "meta.json"

    static func existingURL(in directory: URL) -> URL? {
        for name in [fileName, legacyFileName] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func data(in directory: URL) -> Data? {
        existingURL(in: directory).flatMap { try? Data(contentsOf: $0) }
    }

    static func migrateLegacyFile(in directory: URL) throws {
        let fm = FileManager.default
        let legacy = directory.appendingPathComponent(legacyFileName)
        guard fm.fileExists(atPath: legacy.path) else { return }
        let current = directory.appendingPathComponent(fileName)
        // Preserve both versions on collision; the current name always takes precedence.
        let destination = fm.fileExists(atPath: current.path)
            ? directory.appendingPathComponent("capture-meta-legacy-\(UUID().uuidString).json") : current
        try fm.moveItem(at: legacy, to: destination)
    }
}

/// Standard Swift assertion mode; old datasets omit it. This also works in CLI replays
/// and avoids guessing the build configuration from the DEBUG compilation condition.
nonisolated enum ProcessingBuild {
    static var debugAssertionsEnabled: Bool { _isDebugAssertConfiguration() }
}

/// capture-meta.json：一次掃描的全域資訊，Python 端據此判斷座標慣例與深度格式
nonisolated struct SessionMeta: Codable, Sendable {
    var app = "fable-gs-capture"
    var version = 1
    var device: String
    var osVersion: String
    var startedAt: String
    var mode: String
    var worldAlignment = "gravity"
    var cameraConvention = "arkit_gl_c2w_row_major"
    var imageOrientation = "sensor_landscape_right"
    var depthFormat = "float32_raw_little_endian"
    var lidarAvailable: Bool
    /// 硬體能力與這次是否啟用分開；nil 為舊版紀錄（依 lidarAvailable 判定）。
    var lidarEnabled: Bool? = nil
    /// nil 為舊版；僅無 LiDAR 模式使用 RGB 多視角重建。
    var rgbReconstructionEnabled: Bool? = nil
    var debugAssertionsEnabled: Bool? = ProcessingBuild.debugAssertionsEnabled
}

/// 掃描結束後的品質摘要。
/// 這些數字本來只走 print()，使用者完全看不到 —— 而它們正是判斷
/// 「這次掃描能不能用、要不要重掃」的依據，應該當面講。
nonisolated struct ScanSummary: Sendable {
    var keyframes = 0
    /// ARKit 回頭修正關鍵幀位置的幅度（公分）。大＝這次漂移嚴重、全域幾何可信度低
    var driftMedianCm = 0.0
    var driftMaxCm = 0.0
    var traveledM = 0.0
    /// 有沒有走回起點讓 ARKit 做全域修正。未閉合＝遠端的累積誤差留在資料裡了
    var loopClosed = false
    /// 掃描後複核排除的幀（幾何不可信 + 顏色糊）
    var blurDropped = 0
    var blurDemoted = 0
    /// 世界地圖大小（MB）；nil = 沒存成（追蹤品質不足或超過上限）
    var worldMapMB: Double?
    /// BA 前後的重投影 RMS（像素）。這是 3DGS 解析度天花板的直接量測 ——
    /// 1cm 位姿誤差 @2m ≈ 7px，所以這個數字就是「高斯最細能到多細」。
    ///
    /// **baAfterPx 只在 baApplied 為真時描述實際輸出。** 否則 BA 只是量測、
    /// 位姿沒被改動，輸出的天花板是 baBeforePx。
    var baBeforePx: Float?
    var baAfterPx: Float?
    /// BA 的位姿有沒有真的套用（見 CaptureConfig.baApplyPoses，預設不套用）
    var baApplied = false
    /// 保留集（未參與求解的 track）重投影中位數的變化率。負值＝位姿真的變好。
    /// 這是唯一一個不在 BA 目標函數裡的數字 —— 也是決定要不要打開 baApplyPoses 的依據。
    var baHoldoutDelta: Double?
}

/// 世界座標彩色點。score 為採集品質分數（距離近、靠畫面中心、低模糊 → 高分），
/// 供 voxel 內擇優與匯出下採樣使用。
nonisolated struct CloudPoint: Sendable {
    var x: Float, y: Float, z: Float
    var r: UInt8, g: UInt8, b: UInt8
    // Transient provenance, not serialized to PLY. 1 = near/TSDF, 2 = far;
    // bit 2 = precise support within 1 cm from two independent validation views;
    // bit 3 = local visibility safeguard (coverage protection only).
    var fusionSource: UInt8 = 0
    var packedNormal: UInt16 = 0
    var score: Float = 1
}

/// 跨 actor 傳遞的關鍵幀封包。
/// pixelBuffer 是從自有 CVPixelBufferPool 複製出的副本（絕不保留 ARFrame 原始 buffer），
/// 影像為 App 自有 clone；FrameWriter 完成後交由特徵 worker 唯讀使用，兩者不修改 buffer。
nonisolated struct Keyframe: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let depthData: Data?
    let confidenceData: Data?
    let depthWidth: Int
    let depthHeight: Int
    let c2w: simd_float4x4
    var record: FrameRecord
}

/// Octahedral direction encoding. Zero means unavailable; coordinates/RGB are unaffected.
/// A point grows by four aligned bytes, while grid/TSDF cells use existing padding.
nonisolated enum PackedSurfaceNormal {
    static func encode(_ input: SIMD3<Float>) -> UInt16 {
        let sum = abs(input.x)+abs(input.y)+abs(input.z)
        guard sum.isFinite,sum > 1e-12 else { return 0 }
        var v = input/sum
        if v.z < 0 {
            let x = (1-abs(v.y))*(v.x >= 0 ? Float(1) : -1)
            v.y = (1-abs(v.x))*(v.y >= 0 ? Float(1) : -1); v.x = x
        }
        let x = UInt16(max(0,min(255,Int(((v.x+1)*127.5).rounded()))))
        let y = UInt16(max(0,min(255,Int(((v.y+1)*127.5).rounded()))))
        return max(1,x | (y << 8))
    }
    static func decode(_ code: UInt16) -> SIMD3<Float>? {
        guard code != 0 else { return nil }
        let x = Float(code & 255)/127.5-1, y = Float(code >> 8)/127.5-1
        var v = SIMD3(x,y,1-abs(x)-abs(y))
        if v.z < 0 {
            v.x = (1-abs(y))*(x >= 0 ? Float(1) : -1)
            v.y = (1-abs(x))*(y >= 0 ? Float(1) : -1)
        }
        return simd_normalize(v)
    }
}
