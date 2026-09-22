// Regression: eviction releases descriptors while preserving older BA observations.
// swiftc -O -module-cache-path /tmp/fable-swift-cache \
//   fable/Capture/{FeatureTracker,BundleAdjuster,PoseRefiner}.swift \
//   tools/{test_stubs_core,test_feature_retention}.swift -o /tmp/fable-feature-retention-test
import Foundation
import CoreVideo
import simd

@main
struct FeatureRetentionTests {
    static func main() async {
        let width = 160, height = 120, dw = 80, dh = 60
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        precondition(result == kCVReturnSuccess)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        var seed: UInt64 = 42
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                luma[y * rowBytes + x] = UInt8(truncatingIfNeeded: seed >> 32)
            }
        }
        let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let depths = [Float](repeating: 2, count: dw * dh)
        let depth = depths.withUnsafeBytes { Data($0) }
        let conf = [UInt8](repeating: 2, count: dw * dh)
        let intrinsics = CameraIntrinsics(fx: 100, fy: 100, cx: 80, cy: 60, width: width, height: height)

        let tracker = FeatureTracker()
        let bounded = FeatureTracker(observationLimit: 10)
        for id in 1...12 {
            for target in [tracker, bounded] {
                await target.add(frameID: id, luma: pixels, depth: depth, conf: conf,
                                 dw: dw, dh: dh, K: intrinsics, c2w: matrix_identity_float4x4,
                                 minDepth: 0.1, maxDepth: 5)
            }
        }
        let state = await tracker.retainedState()
        precondition(state.descriptorFrames == FeatureParams.matchAgainstRecent)
        precondition(state.archivedObservations > 0 && state.discardedObservations == 0)
        print("PASS: a twelve-frame scan retains only four frames of descriptors")
        let observations = await tracker.observations()
        precondition(Set(observations.map(\.frameID)) == Set(1...12))
        print("PASS: BA observations still include evicted and recent frames")
        let tracks = Dictionary(grouping: observations, by: \.trackID)
        precondition(!tracks.isEmpty)
        for track in tracks.values {
            precondition(track.count == 12)
            precondition(Set(track.map(\.frameID)).count == 12)
            precondition(track.allSatisfy { $0.u == track[0].u && $0.v == track[0].v && $0.depth == 2 })
        }
        print("PASS: track identity, coordinates and measured depth survive descriptor eviction")
        let capped = await bounded.retainedState()
        precondition(capped.descriptorFrames == 4 && capped.archivedObservations == 10)
        precondition(capped.discardedObservations > 0)
        let cappedObs = await bounded.observations()
        precondition(!cappedObs.isEmpty && !cappedObs.contains { $0.frameID == 1 })
        precondition(Set(cappedObs.map(\.frameID)).isSuperset(of: Set(9...12)))
        print("PASS: long-scan archive budget discards oldest observations and preserves current tracks")
        await tracker.reset()
        let empty = await tracker.retainedState()
        let resetObs = await tracker.observations()
        precondition(empty.descriptorFrames == 0 && empty.archivedObservations == 0)
        precondition(empty.discardedObservations == 0 && resetObs.isEmpty)
        print("PASS: reset releases descriptors and observations")
    }
}
