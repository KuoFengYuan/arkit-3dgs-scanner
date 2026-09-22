import Foundation
import simd

/// ARKit 的 rawFeaturePoints 是中間估計。同一 ID 必須跨時間、跨視角且位置穩定才收點。
/// 已收錄 ID 不重複投票；校正後的位置由其所屬 ARAnchor 空間磚處理。
nonisolated struct SparseLandmarkFilter {
    private struct Track {
        var firstPosition: SIMD3<Float>
        var lastPosition: SIMD3<Float>
        var firstCamera: SIMD3<Float>
        var firstTime: Double
        var lastTime: Double
        var observations: Int
    }
    private var pending: [UInt64: Track] = [:]
    private var emitted: Set<UInt64> = []
    private var epoch: Int?
    private var lastTimestamp: Double?
    private var lastPruneTime = -Double.infinity
    var pendingCount: Int { pending.count }
    var acceptedCount: Int { emitted.count }

    mutating func accept(id: UInt64, position: SIMD3<Float>, camera: SIMD3<Float>,
                         time: Double, epoch: Int, config: CaptureConfig) -> Bool {
        if self.epoch != epoch || lastTimestamp.map({ time < $0 }) == true {
            pending.removeAll(keepingCapacity: true)
            self.epoch = epoch
            lastPruneTime = -Double.infinity
        }
        lastTimestamp = time
        guard time.isFinite, !emitted.contains(id), emitted.count < config.maxPoints,
              position.x.isFinite, position.y.isFinite, position.z.isFinite,
              camera.x.isFinite, camera.y.isFinite, camera.z.isFinite else { return false }
        let distance = simd_distance(position, camera)
        guard distance >= config.pointMinDepthM, distance <= config.pointMaxDepthM else { return false }
        let fresh = Track(firstPosition: position, lastPosition: position, firstCamera: camera,
                          firstTime: time, lastTime: time, observations: 1)
        guard var track = pending[id] else {
            // 明確的候選容量上限；先清過期資料，仍滿時拒絕新增，避免無界記憶體。
            if pending.count >= config.sparseMaxCandidates, time - lastPruneTime >= 0.5 {
                pending = pending.filter { time - $0.value.lastTime < config.sparseTrackMaxGapS }
                lastPruneTime = time
            }
            if pending.count < config.sparseMaxCandidates { pending[id] = fresh }
            return false
        }
        guard time - track.lastTime >= config.sparseSampleIntervalS * 0.8 else { return false }
        let tolerance = config.sparsePositionToleranceM + distance * config.sparseRelativeTolerance
        guard time - track.lastTime <= config.sparseTrackMaxGapS,
              simd_distance(position, track.firstPosition) <= tolerance,
              simd_distance(position, track.lastPosition) <= tolerance else {
            pending[id] = fresh
            return false
        }
        track.observations += 1
        track.lastTime = time
        track.lastPosition = position
        pending[id] = track
        let baseline = simd_distance(camera, track.firstCamera)
        let firstRay = simd_normalize(position - track.firstCamera)
        let ray = simd_normalize(position - camera)
        let angle = acos(min(1, max(-1, simd_dot(firstRay, ray)))) * 180 / .pi
        guard track.observations >= config.sparseMinObservations,
              time - track.firstTime >= config.sparseSampleIntervalS * Double(config.sparseMinObservations - 1) * 0.9,
              baseline >= config.cameraOnlyMinBaselineM,
              angle >= config.sparseMinParallaxDeg else { return false }
        pending.removeValue(forKey: id)
        emitted.insert(id)
        return true
    }
}
