import Foundation

@main
struct PlaybackTimingTests {
    static func main() {
        for fps in ScanPlaybackTiming.supportedFPS {
            let interval = ScanPlaybackTiming.interval(fps: fps)
            precondition(abs(interval * fps - 1) < 0.000001)
            precondition(ScanPlaybackTiming.transitionDuration(fps: fps) < interval)
        }
        print("PASS: 所有 FPS 的影格間隔正確，點雲過渡短於下一張影格間隔")
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            precondition(ScanPlaybackTiming.interval(fps: invalid) == 0.5)
        }
        precondition(ScanPlaybackTiming.interval(fps: 1000) == 1 / 30.0)
        precondition(ScanPlaybackTiming.interval(fps: 0.001) == 2)
        print("PASS: 無效及越界速度有安全回退，不會產生無限或負值等待")
    }
}
