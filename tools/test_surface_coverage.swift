import Foundation
import simd

@main struct SurfaceCoverageTests {
    static func main() {
        setbuf(stdout,nil)
        var checks = 0
        var coverageConfig = CaptureConfig(); coverageConfig.surfaceCoverageProtection = true
        func check(_ result: Bool, _ label: String) { precondition(result,label); checks += 1; print("PASS: \(label)") }
        func point(_ x: Float,_ y: Float,_ z: Float,_ source: UInt8 = 1) -> CloudPoint {
            CloudPoint(x:x,y:y,z:z,r:17,g:89,b:143,fusionSource:source,score:0.8)
        }
        check(!CaptureConfig().surfaceCoverageProtection,"unvalidated coverage tradeoff is opt-in, never a silent default change")
        let near = (0..<41*41).map { i in point(Float(i%41)*0.02,Float(i/41)*0.02,-2) }
        let far = near.map { point($0.x,$0.y,-2.04,2) }
        check(MemoryLayout<CloudPoint>.stride == 24 && MemoryLayout<FusedVoxelGrid.Cell>.stride == 48 && MemoryLayout<SurfaceTSDF.Cell>.stride == 28,
              "source normals add four bytes per point without growing grid or TSDF cells")
        var largestNormalError: Float = 0
        for x in -10...10 { for y in -10...10 { for z in -10...10 where x != 0 || y != 0 || z != 0 {
            let n = simd_normalize(SIMD3(Float(x),Float(y),Float(z)))
            let decoded = PackedSurfaceNormal.decode(PackedSurfaceNormal.encode(n))!
            largestNormalError = max(largestNormalError,acos(min(1,max(-1,simd_dot(n,decoded)))))
        } } }
        check(largestNormalError < 0.02 && PackedSurfaceNormal.decode(0) == nil && PackedSurfaceNormal.encode(SIMD3(.nan,0,0)) == 0,
              "compact normals preserve directions within 1.15 degrees and reject missing data")
        let index = SurfaceCoverageIndex(points:near,include:{_ in true})!
        check(index.covers(SIMD3(0.4,0.4,-2.04),normal:SIMD3(0,0,1),radius:0.15,points:near),
              "a covered parallel surface is eligible for replacement")
        check(!index.covers(SIMD3(0.84,0.4,-2.04),normal:SIMD3(0,0,1),radius:0.15,points:near),
              "nearby edge does not claim coverage outside its tangent footprint")
        check(!index.covers(SIMD3(0.4,0.4,-2.04),normal:SIMD3(1,0,0),radius:0.15,points:near),
              "perpendicular walls cannot replace one another")
        var cloud = near+far
        let result = SurfaceCoverageFilter.filterFar(&cloud,radius:0.15)!
        check(result.removedPoints > 1000 && !cloud.contains { ($0.fusionSource & 3) == 2 && $0.x > 0.15 && $0.x < 0.65 && $0.y > 0.15 && $0.y < 0.65 },
              "supported near plane removes the biased far layer in its interior")
        check(cloud.filter { $0.fusionSource == 1 }.count == near.count,
              "replacement never removes, shifts or resamples the final near surface")
        let sparseFar = far.enumerated().compactMap { i,p -> CloudPoint? in
            guard i%17 == 0,p.x > 0.1,p.x < 0.7,p.y > 0.1,p.y < 0.7 else { return nil }
            var p = p; p.packedNormal = PackedSurfaceNormal.encode(SIMD3(0,0,1)); return p
        }
        var sparseCovered = near+sparseFar
        let sparseResult = SurfaceCoverageFilter.filterFar(&sparseCovered,radius:0.15)!
        check(!sparseFar.isEmpty && sparseResult.removedPoints == sparseFar.count,
              "retained source normals still identify covered repeats after sparse export sampling")
        var perpendicular = near+sparseFar.map { var p = $0; p.packedNormal = PackedSurfaceNormal.encode(SIMD3(1,0,0)); return p }
        check(SurfaceCoverageFilter.filterFar(&perpendicular,radius:0.15)!.removedPoints == 0,
              "source normals protect perpendicular surfaces even when export is sparse")
        let hole = near.filter { hypot($0.x-0.4,$0.y-0.4) > 0.11 }
        var gap = hole+far
        _ = SurfaceCoverageFilter.filterFar(&gap,radius:0.15)
        check(gap.contains { $0.fusionSource == 2 && hypot($0.x-0.4,$0.y-0.4) < 0.025 },
              "far depth survives a hole in the final near cloud")
        var absent = far
        let noCoverage = SurfaceCoverageFilter.filterFar(&absent,radius:0.15)!
        check(noCoverage.removedPoints == 0 && absent.count == far.count,
              "filtered or unsampled near points cannot exclude far fill")
        var thin = near + (0..<31).map { point(0.1+Float($0)*0.02,0.4,-2.04,2) }
        let thinResult = SurfaceCoverageFilter.filterFar(&thin,radius:0.15)!
        check(thinResult.removedPoints == 0,"a thin line cannot be mistaken for a biased planar shell")
        var confirmed = near+far.map { var p = $0; p.fusionSource |= 4; return p }
        let protected = SurfaceCoverageFilter.filterFar(&confirmed,radius:0.15)!
        check(protected.removedPoints == 0 && protected.supportedPoints == far.count,
              "independent depth support protects a distinct parallel surface")
        var cancelled = near+far, calls = 0
        let original = cancelled.map { SIMD3($0.x,$0.y,$0.z) }
        let interrupted = SurfaceCoverageFilter.filterFar(&cancelled,radius:0.15,shouldContinue:{ calls += 1; return calls != 8 })
        check(interrupted == nil && cancelled.map { SIMD3($0.x,$0.y,$0.z) } == original,
              "transient interruption cannot publish partial coverage decisions")
        var shuffled = Array((near+far).reversed())
        _ = SurfaceCoverageFilter.filterFar(&shuffled,radius:0.15)
        check(Set(shuffled.map { SIMD3($0.x,$0.y,$0.z) }) == Set(cloud.map { SIMD3($0.x,$0.y,$0.z) }),
              "coverage decisions are independent of input order")
        check(result.workspaceBytesEstimate < (near.count+far.count)*110,
              "coverage workspace scales with capped output, not input frames")

        // A small conflicted wall is below the global 10% guard. Its complete loss must
        // still be prevented when the surviving wall does not cover the same footprint.
        let k = CameraIntrinsics(fx:80,fy:80,cx:64,cy:48,width:128,height:96)
        func view() -> DepthConsistencyView {
            let depth = [Float](repeating:2,count:k.width*k.height)
            return DepthConsistencyView(depth:depth.withUnsafeBytes { Data($0) },confidence:[UInt8](repeating:2,count:depth.count),
                intrinsics:k,c2w:matrix_identity_float4x4)!
        }
        let wall = (0..<50*50).map { i in point((Float(i%50)-25)*0.01,(Float(i/50)-25)*0.01,-2) }
        let patch = (0..<7*7).map { i in point(0.6+Float(i%7)*0.01,Float(i/7)*0.01,-1.9) }
        var local = wall+patch
        var defaultLocal = wall+patch
        let defaultResult = SurfaceVisibilityValidator.validate(&defaultLocal,references:[0,1,2],config:CaptureConfig(),load:{_ in view()})
        check(defaultResult.removedPoints == patch.count && defaultResult.locallyProtectedPoints == nil && defaultResult.counterBytes == (wall.count+patch.count)*2,
              "default visibility retains previous deletion behavior and two-counter budget")
        let localResult = SurfaceVisibilityValidator.validate(&local,references:[0,1,2],config:coverageConfig,load:{_ in view()})
        check(localResult.candidateRemovals == patch.count && localResult.locallyProtectedPoints == patch.count && local.count == wall.count+patch.count,
              "local wall survives even when its erasure would pass the global percentage guard")
        let ghosts = (0..<7*7).map { i in point((Float(i%7)-3)*0.01,(Float(i/7)-3)*0.01,-1.9) }
        var duplicate = wall+ghosts
        let cleaned = SurfaceVisibilityValidator.validate(&duplicate,references:[0,1,2],config:coverageConfig,load:{_ in view()})
        check(cleaned.removedPoints == ghosts.count && duplicate.count == wall.count,
              "local protection still removes a contradicted shell over a retained supported wall")
        var line = wall+(0..<20).map { point(Float($0)*0.01,0,-1.9) }
        let lineResult = SurfaceVisibilityValidator.validate(&line,references:[0,1,2],config:coverageConfig,load:{_ in view()})
        check(lineResult.removedPoints == 0 && lineResult.locallyProtectedPoints == 20,
              "local visibility guard preserves an unsupported thin structure for review")
        var encodedLine = wall+(0..<20).map { i -> CloudPoint in
            var p = point(Float(i)*0.01,0,-1.9,2); p.packedNormal = PackedSurfaceNormal.encode(SIMD3(0,0,1)); return p
        }
        check(SurfaceVisibilityValidator.validate(&encodedLine,references:[0,1,2],config:coverageConfig,load:{_ in view()}).removedPoints == 0,
              "source normal metadata cannot turn a line into a removable plane")
        let protectedLine = SurfaceCoverageFilter.filterFar(&encodedLine,radius:0.15)!
        check(protectedLine.removedPoints == 0 && protectedLine.protectedPoints == 20 && encodedLine.count == wall.count+20,
              "far replacement respects the preceding local thin-structure safeguard")
        var budget = near + far
        let removedForBudget = SurfaceCoverageFilter.capFarPreservingNear(&budget,limit:near.count+100)
        check(removedForBudget == far.count-100 && budget.count == near.count+100 && budget.filter { $0.fusionSource == 1 }.count == near.count,
              "final output cap thins only far fill and preserves the near replacement evidence")
        let volume = SurfaceTSDF()
        let compactNear = Array(near.prefix(100))
        let distant = (0..<100).map { point(3+Float($0%10)*0.02,Float($0/10)*0.02,-2.04,2) }
        var merged = volume.preservingUnsupported(compactNear,fallback:distant,limit:100,farExclusion:0.15)!
        check(merged.count <= 200 && volume.report.farReservePoints == 50 && merged.filter { $0.fusionSource == 1 }.count == 50,
              "surface merge reserves bounded room for far-only coverage without letting repeats evict all near geometry")
        _ = SurfaceCoverageFilter.filterFar(&merged,radius:0.15)
        _ = SurfaceCoverageFilter.capFarPreservingNear(&merged,limit:100)
        check(merged.count == 100 && merged.filter { $0.fusionSource == 2 }.count == 50,
              "deferred far coverage is finally capped and still fills unobserved space")
        check(volume.preservingUnsupported(compactNear,fallback:distant,limit:100,farExclusion:0.15,shouldContinue:{ false }) == nil,
              "deferred surface merge honors cancellation before publishing geometry")
        print("\(checks) coverage checks passed")
    }
}
