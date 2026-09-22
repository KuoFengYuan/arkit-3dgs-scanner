import Foundation

/// 相機／追蹤狀態與資料處理階段分開，UI 與快門共用同一份開拍條件。
nonisolated enum CaptureSessionState: Equatable, Sendable {
    case requestingPermission
    case permissionDenied
    case unsupported
    case initializing
    case ready
    case limited
    case relocalizing
    case interrupted
    case failed(String)

    var canCapture: Bool { self == .ready }

    var message: String {
        switch self {
        case .requestingPermission: return "請允許相機存取，才能開始掃描"
        case .permissionDenied: return "相機權限尚未開啟，請到設定允許 fable 使用相機"
        case .unsupported: return "此裝置不支援 AR 掃描"
        case .initializing: return "緩慢移動手機，讓相機辨識周圍環境"
        case .ready: return "準備完成，按下開始掃描"
        case .limited: return "追蹤暫時不穩，請放慢並對準有紋理的表面"
        case .relocalizing: return "請回到剛才的位置，對準掃描過的區域"
        case .interrupted: return "掃描已暫停，回到相機後會重新定位"
        case .failed(let message): return "相機發生錯誤：\(message)"
        }
    }
}
