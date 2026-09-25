// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import simd

/// Live guidance for long captures: ask the user to return to an area captured earlier when
/// the scan has gone on through new ground for a while, and confirm when they are back.
///
/// Drift grows with the time since the camera last saw a place again: surfaces captured more
/// than about 40 s apart disagree by 3–14 cm on the replayed scans, and both ARKit's own
/// correction and the offline pose refinement can only fix drift across a revisit. A revisit
/// here uses the offline revisit rules (`LoopClosureRefiner.candidates`): the camera within
/// 0.8 m of a saved photo, facing the same way (cosine above 0.9), taken at least 8 s of
/// scanning earlier with at least 2 m walked since. So a revisit the guide confirms is one the
/// refinement can use.
///
/// Time is scanning time: gaps between updates longer than half a second (a pause) do not
/// count. Pure logic, driven by the capture controller.
nonisolated struct RevisitGuide {
    enum Prompt: Equatable {
        case none
        /// Walked `travelM` metres over `seconds` of scanning since the last revisit.
        case goBack(travelM: Float, seconds: Double)
        /// Just returned to a captured area after being asked to.
        case returned
    }

    struct Options: Equatable {
        var maxDistanceM: Float = 0.8
        var minFacing: Float = 0.9
        var minAgeSeconds = 8.0
        var minTravelSinceM: Float = 2
        /// Ask to go back after this long and this far through new ground.
        var promptAfterSeconds = 40.0
        var promptAfterTravelM: Float = 4
        /// Photos needed before asking (a scan must have something to return to).
        var minPhotos = 10
        var returnedSeconds = 3.0
        /// Revisit checks per second of scanning (the check scans every photo).
        var checksPerSecond = 5.0
    }

    struct Photo { var position: SIMD3<Float>; var forward: SIMD3<Float>; var time: Double; var travel: Float }

    let options: Options
    private(set) var photos: [Photo] = []
    /// Scanning time and distance walked (steps above 5 cm, which filters jitter).
    private(set) var time = 0.0
    private(set) var travelM: Float = 0
    /// Revisits found during the scan.
    private(set) var revisits = 0
    private var lastTimestamp: Double?
    private var lastPosition: SIMD3<Float>?
    private var sinceTime = 0.0
    private var sinceTravel: Float = 0
    private var asking = false
    private var returnedUntil: Double?
    private var nextCheck = 0.0

    init(options: Options = Options()) { self.options = options }

    /// A saved photo, with its camera-to-world pose (ARKit camera: looking down -z).
    mutating func addPhoto(cameraToWorld m: simd_float4x4) {
        let forward = -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        photos.append(Photo(position: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
                            forward: simd_length_squared(forward) > 0 ? simd_normalize(forward) : forward, time: time, travel: travelM))
    }

    /// One camera pose while scanning (`timestamp` in seconds, like ARFrame's).
    mutating func update(cameraToWorld m: simd_float4x4, timestamp: Double) -> Prompt {
        if let last = lastTimestamp { time += min(max(0, timestamp - last), 0.5) }
        lastTimestamp = timestamp
        let position = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        if let previous = lastPosition {
            let step = simd_distance(position, previous)
            if step > 0.05 { travelM += step; lastPosition = position }
        } else {
            lastPosition = position
        }
        if time >= nextCheck {
            nextCheck = time + 1 / options.checksPerSecond
            let forward = -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            if isRevisit(position: position, forward: simd_length_squared(forward) > 0 ? simd_normalize(forward) : forward) {
                revisits += 1
                sinceTime = time
                sinceTravel = travelM
                if asking { returnedUntil = time + options.returnedSeconds }
                asking = false
            }
        }
        if let until = returnedUntil {
            if time < until { return .returned }
            returnedUntil = nil
        }
        if !asking, photos.count >= options.minPhotos, time - sinceTime >= options.promptAfterSeconds,
           travelM - sinceTravel >= options.promptAfterTravelM {
            asking = true
        }
        return asking ? .goBack(travelM: travelM - sinceTravel, seconds: time - sinceTime) : .none
    }

    /// The camera is back at a photo saved well before, facing the same way.
    func isRevisit(position: SIMD3<Float>, forward: SIMD3<Float>) -> Bool {
        let d2 = options.maxDistanceM * options.maxDistanceM
        for photo in photos where time - photo.time >= options.minAgeSeconds && travelM - photo.travel >= options.minTravelSinceM {
            if simd_distance_squared(photo.position, position) < d2 && simd_dot(photo.forward, forward) > options.minFacing { return true }
        }
        return false
    }
}
