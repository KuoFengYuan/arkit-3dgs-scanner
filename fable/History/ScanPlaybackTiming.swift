import Foundation

nonisolated enum ScanPlaybackTiming {
    static let supportedFPS: [Double] = [0.5, 1, 2, 5, 10, 15, 30]
    static let defaultFPS: Double = 2

    static func interval(fps: Double) -> TimeInterval {
        let valid = fps.isFinite && fps > 0 ? fps : defaultFPS
        return 1 / min(30, max(0.5, valid))
    }

    static func transitionDuration(fps: Double) -> TimeInterval {
        min(0.25, interval(fps: fps) * 0.8)
    }
}
