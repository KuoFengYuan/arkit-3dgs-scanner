// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// Live revisit guidance: when it asks the user to return, and when it confirms the return.
//
// swiftc -O arkit-3dgs-scanner/Capture/RevisitGuide.swift tools/test_revisit_guide.swift -o /tmp/revisit-guide-test
// /tmp/revisit-guide-test
import Foundation
import simd

@main struct RevisitGuideTest {
    static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        if !ok { print("FAIL: \(message)"); exit(1) }
        checks += 1; print("PASS: \(message)")
    }

    /// Camera-to-world at `position` looking along `direction` (ARKit camera looks down -z).
    static func pose(_ position: SIMD3<Float>, facing direction: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(direction), up = SIMD3<Float>(0, 1, 0)
        let x = simd_normalize(simd_cross(f, up)), y = simd_cross(x, f)
        return simd_float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(-f, 0), SIMD4(position, 1)))
    }

    static func main() {
        var guide = RevisitGuide()
        var t = 0.0
        var prompts: [RevisitGuide.Prompt] = []
        /// Moves at 60 Hz from `a` to `b` over `seconds`, facing `facing`, saving a photo each second.
        func walk(from a: SIMD3<Float>, to b: SIMD3<Float>, seconds: Double, facing: SIMD3<Float>, photos: Bool = true) {
            let steps = Int(seconds * 60)
            for k in 1...steps {
                let p = a + (b - a) * Float(k) / Float(steps)
                t += 1.0 / 60
                prompts.append(guide.update(cameraToWorld: pose(p, facing: facing), timestamp: t))
                if photos && k % 60 == 0 { guide.addPhoto(cameraToWorld: pose(p, facing: facing)) }
            }
        }
        let east = SIMD3<Float>(1, 0, 0), west = SIMD3<Float>(-1, 0, 0)

        // New ground for 30 s: no prompt yet (under 40 s).
        walk(from: .zero, to: SIMD3(6, 0, 0), seconds: 30, facing: east)
        check(prompts.allSatisfy { $0 == .none }, "no prompt during the first 30 s of new ground")
        // Standing still near recent photos is not a revisit, and the prompt comes after 40 s.
        walk(from: SIMD3(6, 0, 0), to: SIMD3(6, 0, 0), seconds: 5, facing: east, photos: false)
        prompts.removeAll()
        walk(from: SIMD3(6, 0, 0), to: SIMD3(8, 0, 0), seconds: 10, facing: east)
        let asked = prompts.firstIndex { if case .goBack = $0 { return true }; return false }
        if case .goBack(let travel, let seconds)? = prompts.last {
            check(asked != nil && guide.revisits == 0 && travel >= 7.9 && seconds >= 44,
                  "after 40 s and 4 m of new ground it asks to go back (\(String(format: "%.1f m, %.0f s", travel, seconds)))")
        } else { check(false, "after 40 s and 4 m of new ground it asks to go back") }
        // A pause does not count as scanning time.
        var paused = RevisitGuide()
        for k in 0..<20 { paused.addPhoto(cameraToWorld: pose(SIMD3(Float(k) * 0.2, 0, 0), facing: east)) }
        _ = paused.update(cameraToWorld: pose(.zero, facing: east), timestamp: 0)
        let afterPause = paused.update(cameraToWorld: pose(SIMD3(5, 0, 0), facing: east), timestamp: 300)
        check(afterPause == .none && paused.time <= 0.5, "a paused gap does not count as scanning time")
        // Walking back facing the other way is not yet a revisit; the prompt stays.
        prompts.removeAll()
        walk(from: SIMD3(8, 0, 0), to: SIMD3(2.2, 0, 0), seconds: 8, facing: west, photos: false)
        check(prompts.allSatisfy { if case .goBack = $0 { return true }; return false } && guide.revisits == 0,
              "walking back facing the other way keeps the prompt")
        // Facing the way the early photos looked: back in a captured area, confirmed for 3 s.
        prompts.removeAll()
        walk(from: SIMD3(2.2, 0, 0), to: SIMD3(2.0, 0, 0), seconds: 1, facing: east, photos: false)
        let back = prompts.firstIndex(of: .returned)
        check(back != nil && guide.revisits >= 1, "turning to face a captured area confirms the return")
        prompts.removeAll()
        walk(from: SIMD3(2.0, 0, 0), to: SIMD3(2.0, 0, 1), seconds: 4, facing: SIMD3(0, 0, 1), photos: false)
        let returnedFrames = prompts.filter { $0 == .returned }.count
        check(returnedFrames > 100 && returnedFrames < 200 && prompts.last == RevisitGuide.Prompt.none,
              "the confirmation lasts about 3 s, then the prompt is gone")
        // The clock restarts at the revisit: new ground asks again only after another 40 s.
        prompts.removeAll()
        walk(from: SIMD3(2, 0, 1), to: SIMD3(2, 0, 7), seconds: 30, facing: SIMD3(0, 0, 1))
        check(prompts.allSatisfy { $0 == .none }, "after a revisit the next prompt waits for another 40 s of new ground")
        print("\(checks) revisit guidance checks passed")
    }
}
