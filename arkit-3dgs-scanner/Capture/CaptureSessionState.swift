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
        case .requestingPermission: return L10n.text("請允許相機存取，才能開始掃描")
        case .permissionDenied: return L10n.text("相機權限尚未開啟，請到設定允許 ARKit 3DGS Scanner 使用相機")
        case .unsupported: return L10n.text("此裝置不支援 AR 掃描")
        case .initializing: return L10n.text("緩慢移動手機，讓相機辨識周圍環境")
        case .ready: return L10n.text("準備完成，按下開始掃描")
        case .limited: return L10n.text("追蹤暫時不穩，請放慢並對準有紋理的表面")
        case .relocalizing: return L10n.text("請回到剛才的位置，對準掃描過的區域")
        case .interrupted: return L10n.text("掃描已暫停，回到相機後會重新定位")
        case .failed(let message): return L10n.text("相機發生錯誤：\(message)")
        }
    }
}
