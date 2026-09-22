import Foundation
import simd

@main struct LoopClosureTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ text: String) { precondition(value,text); checks += 1; print("PASS: \(text)") }
        let correction = PoseRefiner.deltaTransform(omega: SIMD3(0.005,-0.015,0.008), trans: SIMD3(-0.07,0.01,0.02), about: .zero)
        let pairs: [LoopClosureRefiner.Match] = (0..<100).map { i in
            let p = SIMD3<Float>(Float(i%10)*0.08, Float(i/10)*0.08, -2 + Float(i%3)*0.04)
            return LoopClosureRefiner.Match(a: LoopClosureRefiner.point(correction,p), b:p)
        }
        let fit = LoopClosureRefiner.align(pairs)!
        check(pairs.allSatisfy { simd_distance($0.a,LoopClosureRefiner.point(fit,$0.b)) < 0.0001 }, "rigid alignment recovers known rotation and translation")
        check(abs(simd_determinant(fit)-1) < 0.0001, "alignment cannot introduce scale")
        let edge = LoopClosureRefiner.verifiedEdge(a:0,b:99,matches:pairs)
        check(edge != nil && edge!.heldOut.count == 20, "revisit passes disjoint geometric holdout")
        var outliers = pairs
        for i in stride(from:0,to:100,by:7) { outliers[i] = .init(a:pairs[i].a+SIMD3(0.4,0.2,0),b:pairs[i].b) }
        check(LoopClosureRefiner.verifiedEdge(a:0,b:99,matches:outliers) != nil, "RANSAC tolerates minority mismatches")
        var wrongHoldout = pairs
        for i in stride(from:0,to:100,by:5) { wrongHoldout[i] = .init(a:pairs[i].b + SIMD3(-0.2,0,0),b:pairs[i].b) }
        check(LoopClosureRefiner.verifiedEdge(a:0,b:99,matches:wrongHoldout) == nil, "a good fit cannot override contradictory held-out observations")
        let cancelled = LoopClosureRefiner.corrections(count:100,edges:[edge!],isCancelled:{true})
        check(cancelled.allSatisfy { $0 == matrix_identity_float4x4 }, "graph cancellation returns no partial correction")
        let same = pairs.map { LoopClosureRefiner.Match(a:$0.b,b:$0.b) }
        check(LoopClosureRefiner.verifiedEdge(a:0,b:99,matches:same) == nil, "already aligned geometry does not trigger speculative correction")
        let line = (0..<50).map { i in LoopClosureRefiner.Match(a:SIMD3(Float(i),0,0),b:SIMD3(Float(i)+0.05,0,0)) }
        check(LoopClosureRefiner.align(line) == nil, "collinear constraints cannot drive a six-degree correction")
        let delta = LoopClosureRefiner.corrections(count:100,edges:[edge!])
        check(delta[0] == matrix_identity_float4x4, "graph anchors the capture origin")
        let before = LoopClosureRefiner.median(edge!.heldOut.map { simd_distance($0.a,$0.b) })
        let after = LoopClosureRefiner.median(edge!.heldOut.map { simd_distance($0.a,LoopClosureRefiner.point(delta[99],$0.b)) })
        check(after < before*0.1, "graph removes synthetic end-to-start drift")
        check(simd_length(LoopClosureRefiner.center(delta[50])) > 0.01, "loop correction propagates to intervening frames")
        check(zip(delta,delta.dropFirst()).allSatisfy { simd_distance(LoopClosureRefiner.center($0),LoopClosureRefiner.center($1)) < 0.005 }, "correction is distributed without trajectory jumps")
        check(delta.allSatisfy { abs(simd_determinant($0)-1) < 0.0001 }, "all graph nodes remain rigid")
        func record(_ i: Int, x:Double) -> FrameRecord {
            FrameRecord(id:i+1,timestamp:Double(i)*0.3,transform:[1,0,0,x,0,1,0,0,0,0,1,0,0,0,0,1],
                intrinsics:.init(fx:100,fy:100,cx:80,cy:60,width:160,height:120),exposureDuration:0.005,
                exposureOffsetEV:0,estimatedBlurPx:0,imageFile:"\(i).jpg",depthFile:"\(i).bin")
        }
        let stationary = (0..<1000).map { record($0,x:0) }
        check(LoopClosureRefiner.candidates(stationary).isEmpty, "stationary repeated photos are not a spatial loop")
        let route = (0..<1000).map { i in record(i,x:Double(i<=500 ? i : 1000-i)*0.01) }
        let candidates = LoopClosureRefiner.candidates(route)
        check(!candidates.isEmpty && candidates.count<=64, "thousand-frame revisit search obeys pair budget")
        check(candidates.allSatisfy { route[$0.1].timestamp-route[$0.0].timestamp>=8 }, "candidates connect different time segments")
        print("\(checks) loop-closure checks passed")
    }
}
