import Foundation
import simd
import CoreGraphics
import ImageIO

@main struct SurfaceTests {
    static func main() throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.count == 3 {
            if CommandLine.arguments[1] == "--replay" { try replay(CommandLine.arguments[2]); return }
            if CommandLine.arguments[1] == "--benchmark" { try benchmark(CommandLine.arguments[2]); return }
        }
        var checks = 0
        func check(_ value: Bool,_ message: String) { if !value { print("FAIL: \(message)"); exit(1) }; checks += 1; print("PASS: \(message)") }
        func frame(pose: simd_float4x4, recorded: simd_float4x4? = nil, flat: Bool = false) -> LocalSurfaceRefiner.Frame {
            let w = 128, h = 96
            let k = CameraIntrinsics(fx:80,fy:80,cx:64,cy:48,width:w,height:h)
            var depth = [Float](repeating:0,count:w*h), gray = [UInt8](repeating:0,count:w*h)
            let origin = SIMD3(pose.columns.3.x,pose.columns.3.y,pose.columns.3.z)
            for y in 0..<h { for x in 0..<w {
                let local = SIMD4((Float(x)-64)/80,(48-Float(y))/80,-1,0)
                let d4 = pose*local, d = SIMD3(d4.x,d4.y,d4.z)
                var t = (-2-origin.z)/d.z
                if !flat {
                    if d.x > 0 { t = min(t,(0.9-origin.x)/d.x) }
                    if d.y < 0 { t = min(t,(-0.65-origin.y)/d.y) }
                }
                let p = origin+d*t
                depth[y*w+x] = t
                gray[y*w+x] = UInt8(clamping:Int(125+25*sin(p.x*3)+25*cos(p.y*4)+25*sin(p.z*5)))
            } }
            let data = depth.withUnsafeBytes { Data($0) }
            let stored = recorded ?? pose
            let view = DepthConsistencyView(depth:data,confidence:nil,intrinsics:k,c2w:stored)!
            return LocalSurfaceRefiner.Frame(view:view,gray:gray,grayWidth:w,grayHeight:h,pose:stored)
        }
        var wrong = matrix_identity_float4x4; wrong.columns.3.x = 0.015; wrong.columns.3.z = 0.012
        var left = matrix_identity_float4x4; left.columns.3.x = -0.035
        var right = matrix_identity_float4x4; right.columns.3.x = 0.035
        let source = frame(pose:matrix_identity_float4x4,recorded:wrong)
        let refs = [frame(pose:left),frame(pose:right)]
        let aligned = LocalSurfaceRefiner.align(source:source,references:refs)
        print("Alignment:",aligned.reason,aligned.before,aligned.after,aligned.pose.columns.3)
        check(aligned.reason == "validated", "three-surface scene accepts a known small rigid pose correction")
        check(simd_length(SIMD3(aligned.pose.columns.3.x,aligned.pose.columns.3.y,aligned.pose.columns.3.z)) < 0.005,
              "known 19 mm pose error is recovered within 5 mm on synthetic depth")
        check(aligned.after < aligned.before*0.2,"held-out depth residual improves on an independently rendered scene")
        check(abs(simd_determinant(aligned.pose)-1) < 1e-4,"pose refinement preserves metric scale")
        let planar = LocalSurfaceRefiner.align(source:frame(pose:matrix_identity_float4x4,recorded:wrong,flat:true),
            references:[frame(pose:left,flat:true),frame(pose:right,flat:true)])
        check(planar.reason == "degenerate" && planar.pose == wrong,"a single wall cannot invent unconstrained camera motion")
        let cancelled = LocalSurfaceRefiner.align(source:source,references:refs,shouldContinue:{false})
        check(cancelled.pose == wrong && cancelled.reason == "interrupted","cancelled pose solve preserves its input")
        var far = wrong; far.columns.3.z = 0.2
        let excessive = LocalSurfaceRefiner.align(source:frame(pose:matrix_identity_float4x4,recorded:far),references:refs)
        check(excessive.reason != "validated","large misalignment is not forced into a local correction")
        let good = LocalSurfaceRefiner.align(source:frame(pose:matrix_identity_float4x4),references:refs)
        check(good.reason != "validated","already aligned camera is left unchanged")
        func plane(_ z: Float) -> [CloudPoint] {
            (-30...30).flatMap { y in (-30...30).map { x in
                CloudPoint(x:Float(x)*0.015,y:Float(y)*0.015,z:z,r:120,g:160,b:200,score:1)
            } }
        }
        let volume = SurfaceTSDF()
        for i in 0..<6 { check(volume.integrate(plane(-2 + (i%2 == 0 ? 0.012 : -0.012)),camera:.zero,frame:i),"bounded TSDF integrates view \(i)") }
        let cloud = volume.extract(limit:250_000) ?? []
        print("Surface:",volume.report,"points",cloud.count)
        check(!cloud.isEmpty && volume.report.status == "completed","surface extraction crosses sparse block boundaries")
        let meanError = cloud.reduce(Float(0)) { $0+abs($1.z+2) }/Float(max(1,cloud.count))
        check(meanError < 0.006,"opposing 12 mm depth noise produces one surface within 6 mm")
        let extra = CloudPoint(x:8,y:8,z:-2,r:13,g:21,b:34)
        let preserved = volume.preservingUnsupported(cloud,fallback:[extra],limit:250_000)!
        check(preserved.contains { $0.x == 8 && $0.y == 8 && $0.r == 13 },"unsupported geometry and color survive hybrid output unchanged")
        check(volume.report.allocatedBytes <= 32*1_048_576,"TSDF cell allocation obeys the fixed byte budget")
        let single = SurfaceTSDF(); single.integrate(plane(-2),camera:.zero,frame:0)
        check(single.extract(limit:1000) == nil,"single-view geometry falls back instead of claiming verified surfaces")
        let tiny = SurfaceTSDF(budgetBytes:SurfaceTSDF.blockBytes,pagingEnabled:false)
        check(!tiny.integrate(plane(-2),camera:.zero,frame:0) && tiny.report.status == "capacityFallback","capacity exhaustion discards the partial TSDF")
        check(tiny.extract(limit:1000) == nil,"incomplete volume cannot be exported as a successful scan")
        let limited = SurfaceTSDF()
        for i in 0..<3 { limited.integrate(plane(-2),camera:.zero,frame:i) }
        check(limited.extract(limit:100)?.count == 100,"surface extraction bounds output without collecting every crossing")
        let paged = SurfaceTSDF(budgetBytes:SurfaceTSDF.blockBytes*8)
        let resident = SurfaceTSDF(cacheBlockLookups:false)
        for i in 0..<3 {
            check(paged.integrate(plane(-2),camera:.zero,frame:i),"disk-paged TSDF integrates complete frame \(i)")
            resident.integrate(plane(-2),camera:.zero,frame:i)
        }
        let pagedCloud = paged.extract(limit:100_000) ?? [], residentCloud = resident.extract(limit:100_000) ?? []
        check(!pagedCloud.isEmpty && pagedCloud.count == residentCloud.count,"paging extracts the entire scene across evicted block boundaries")
        check(zip(pagedCloud,residentCloud).allSatisfy { $0.x.bitPattern == $1.x.bitPattern && $0.y.bitPattern == $1.y.bitPattern && $0.z.bitPattern == $1.z.bitPattern && $0.r == $1.r && $0.g == $1.g && $0.b == $1.b },"paged and in-memory TSDF outputs are bit-for-bit identical")
        check(paged.report.peakBlocks <= 8 && paged.report.blockReads > 0 && paged.report.blockWrites > 0,"paging bounds resident blocks while reloading exact observations")
        let diskFull = SurfaceTSDF(budgetBytes:SurfaceTSDF.blockBytes,diskBudgetBytes:0)
        check(!diskFull.integrate(plane(-2),camera:.zero,frame:0) && diskFull.report.status == "diskBudgetFallback","disk budget exhaustion cannot publish a partial surface")
        let stopped = SurfaceTSDF()
        check(!stopped.integrate(plane(-2),camera:.zero,frame:0,shouldContinue:{false}),"memory/cancellation interrupts TSDF insertion")
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("surface-integration-"+UUID().uuidString)
        try fm.createDirectory(at:dir.appendingPathComponent("depth"),withIntermediateDirectories:true)
        try fm.createDirectory(at:dir.appendingPathComponent("images"),withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:dir) }
        let width = 64, height = 48
        let rgba = Data(repeating:150,count:width*height*4)
        let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),
            provider:CGDataProvider(data:rgba as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(dir.appendingPathComponent("images/wall.jpg") as CFURL,"public.jpeg" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil); check(CGImageDestinationFinalize(destination),"fixture image written")
        let depth = [Float](repeating:2,count:width*height).withUnsafeBytes { Data($0) }
        try depth.write(to:dir.appendingPathComponent("depth/wall.bin"))
        let records = (0..<10).map { id in FrameRecord(id:id,timestamp:Double(id)*0.2,
            transform:RefusionEngine.rowMajor(matrix_identity_float4x4),
            intrinsics:CameraIntrinsics(fx:60,fy:60,cx:32,cy:24,width:width,height:height),
            exposureDuration:0.005,exposureOffsetEV:0,estimatedBlurPx:0,imageFile:"wall.jpg",depthFile:"wall.bin",depthWidth:width,depthHeight:height) }
        var cfg = CaptureConfig(); cfg.refuseMinNeighbors = 0
        let baseline = RefusionEngine.refuseWithReport(records:records,sessionDir:dir,config:cfg,availableMemory:{2_000_000_000},progress:{_ in})
        cfg.preparedDepthSampling = false
        cfg.prefetchFusionRGB = false
        let referenceSampling = RefusionEngine.refuseWithReport(records:records,sessionDir:dir,config:cfg,availableMemory:{2_000_000_000},progress:{_ in})
        func positions(_ cloud: [CloudPoint]) -> Set<SIMD3<Float>> { Set(cloud.map { SIMD3($0.x,$0.y,$0.z) }) }
        check(positions(referenceSampling.points) == positions(baseline.points),"prepared depth sampling preserves production fusion geometry exactly")
        cfg.preparedDepthSampling = true
        cfg.prefetchFusionRGB = true
        cfg.surfaceReconstruction = true
        let enabled = RefusionEngine.refuseWithReport(records:records,sessionDir:dir,config:cfg,availableMemory:{2_000_000_000},progress:{_ in})
        print("Integration surface",enabled.report.surface as Any)
        check(enabled.report.status == "completed" && enabled.report.surface?.status.hasPrefix("completed") == true,"production fusion enables and publishes the bounded surface path")
        check(enabled.points.allSatisfy { abs($0.z+2) < 0.005 },"production surface output preserves known metric plane depth")
        cfg.surfaceBudgetMB = 0
        let fallback = RefusionEngine.refuseWithReport(records:records,sessionDir:dir,config:cfg,availableMemory:{2_000_000_000},progress:{_ in})
        check(fallback.report.surface?.status == "capacityFallback" && fallback.points.count == baseline.points.count,
              "exhausted surface budget still publishes the full legacy cloud")
        check(Set(fallback.points.map { SIMD3($0.x,$0.y,$0.z) }) == Set(baseline.points.map { SIMD3($0.x,$0.y,$0.z) }),"capacity fallback is geometrically identical to disabled surface mode")
        cfg.surfaceBudgetMB = 32
        let thousand = (0..<1000).map { i in var r = records[i%records.count]; r.id = i; r.timestamp = Double(i)*0.2; return r }
        let long = RefusionEngine.refuseWithReport(records:thousand,sessionDir:dir,config:cfg,availableMemory:{2_000_000_000},progress:{_ in})
        check(long.report.completedFrames == 1000 && long.report.surface?.status.hasPrefix("completed") == true,"1000-frame scan completes through the enabled surface path")
        check(long.report.surface?.peakBlocks == enabled.report.surface?.peakBlocks,"revisiting a surface does not grow TSDF allocations with frame count")
        let localRun = LocalSurfaceRefiner.run(records:records,directory:dir)
        check(localRun.report.peakDepthFrames <= 3 && localRun.records.map(\.transform) == records.map(\.transform),"disk-backed planar scan holds at most three frames and preserves poses")
        let noRun = LocalSurfaceRefiner.run(records:records,directory:dir,shouldContinue:{false})
        check(noRun.report.status == "interrupted" && noRun.records.map(\.transform) == records.map(\.transform),"cancelled local pass rolls back all poses")
        check(try Data(contentsOf:dir.appendingPathComponent("depth/wall.bin")) == depth,"processing never rewrites source depth")
        var depths = [Float](repeating:2,count:64*48), confidence = [UInt8](repeating:2,count:64*48)
        depths[42] = .nan; depths[111] = 0; depths[510] = 4; confidence[712] = 0
        let data = depths.withUnsafeBytes { Data($0) }
        let rawView = DepthConsistencyView(depth:data,confidence:confidence,intrinsics:records[0].intrinsics,c2w:matrix_identity_float4x4)!
        var prepared = rawView; prepared.prepareSampling(config:cfg)
        var same = true
        for y in 0..<48 { for x in 0..<64 {
            let p = SIMD3((Float(x)+0.3-32)*2/60,(24-Float(y)-0.4)*2/60,-2)
            let a = rawView.sample(p,config:cfg), b = prepared.sample(p,config:cfg)
            if let a,let b { same = same && a.measuredDepth.bitPattern == b.measuredDepth.bitPattern && a.tolerance.bitPattern == b.tolerance.bitPattern }
            else { same = same && ((a == nil) == (b == nil)) }
        } }
        check(same,"prepared sampling is bit-identical at invalid depth, confidence, edges and bilinear subpixels")
        cfg.pointMaxDepthM = 1.5
        check(prepared.sample(SIMD3(0,0,-2),config:cfg) == nil,"changing thresholds cannot reuse stale quad validity")
        check(prepared.samplingMaskBytes <= (64*48+63)/64*8,"quad validity uses one bit per pixel")
        print("\(checks) surface reconstruction checks passed")
    }
    static func benchmark(_ path: String) throws {
        let directory = URL(fileURLWithPath:path)
        let records = try String(contentsOf:directory.appendingPathComponent("poses.jsonl"),encoding:.utf8).split(separator:"\n")
            .map { try JSONDecoder().decode(FrameRecord.self,from:Data($0.utf8)) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fusion-benchmark-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        var expected: [CloudPoint]?, times: [Bool:[Double]] = [:]
        let sort: (CloudPoint,CloudPoint)->Bool = { a,b in a.x != b.x ? a.x < b.x : a.y != b.y ? a.y < b.y : a.z < b.z }
        for (i,fast) in [false,true,true,false,true,false].enumerated() {
            var config = CaptureConfig(); config.preparedDepthSampling = fast; config.prefetchFusionRGB = fast
            let start = Date()
            let result = RefusionEngine.refuseWithReport(records:records,sessionDir:directory,config:config,
                diagnosticsDirectory:temp,availableMemory:{2_000_000_000},progress:{_ in})
            let elapsed = Date().timeIntervalSince(start)
            let sorted = result.points.sorted(by:sort)
            if let expected {
                precondition(expected.count == sorted.count && zip(expected,sorted).allSatisfy {
                    $0.x.bitPattern == $1.x.bitPattern && $0.y.bitPattern == $1.y.bitPattern && $0.z.bitPattern == $1.z.bitPattern
                    && $0.r == $1.r && $0.g == $1.g && $0.b == $1.b && $0.score.bitPattern == $1.score.bitPattern
                },"benchmark changed a coordinate, color or confidence bit")
            } else { expected = sorted }
            if i > 0 { times[fast,default:[]].append(elapsed) }
            print("BENCH",i,fast ? "prefetch+prepared" : "reference",elapsed,"s; identical output")
        }
        print("BENCH RESULTS (first warmup excluded)",times)
    }
    static func replay(_ path: String) throws {
        let directory = URL(fileURLWithPath:path), decoder = JSONDecoder()
        let records = try String(contentsOf:directory.appendingPathComponent("poses.jsonl"),encoding:.utf8)
            .split(separator:"\n").map { try decoder.decode(FrameRecord.self,from:Data($0.utf8)) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("surface-replay-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        let refined = LocalSurfaceRefiner.run(records:records,directory:directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        print("LOCAL",String(data:try encoder.encode(refined.report),encoding:.utf8)!)
        var config = CaptureConfig()
        config.preparedDepthSampling = false
        config.prefetchFusionRGB = false
        let baseline = RefusionEngine.refuseWithReport(records:records,sessionDir:directory,config:config,
            diagnosticsDirectory:temp,availableMemory:{2_000_000_000},progress:{_ in})
        try encoder.encode(baseline.report).write(to:temp.appendingPathComponent("baseline.json"))
        config.preparedDepthSampling = true
        config.prefetchFusionRGB = true
        let fast = RefusionEngine.refuseWithReport(records:records,sessionDir:directory,config:config,
            diagnosticsDirectory:temp,availableMemory:{2_000_000_000},progress:{_ in})
        try encoder.encode(fast.report).write(to:temp.appendingPathComponent("prepared.json"))
        let sort: (CloudPoint,CloudPoint)->Bool = { a,b in a.x != b.x ? a.x < b.x : a.y != b.y ? a.y < b.y : a.z < b.z }
        let a = baseline.points.sorted(by:sort),b = fast.points.sorted(by:sort)
        let identical = a.count == b.count && zip(a,b).allSatisfy { $0.x.bitPattern == $1.x.bitPattern && $0.y.bitPattern == $1.y.bitPattern && $0.z.bitPattern == $1.z.bitPattern && $0.r == $1.r && $0.g == $1.g && $0.b == $1.b && $0.score.bitPattern == $1.score.bitPattern }
        print("EXACT SAMPLING",identical,"consistency seconds",baseline.report.consistencySeconds,fast.report.consistencySeconds)
        precondition(identical,"speed optimization changed fusion output")
        config.surfaceReconstruction = true
        let result = RefusionEngine.refuseWithReport(records:refined.records,sessionDir:directory,config:config,
            diagnosticsDirectory:temp,availableMemory:{2_000_000_000},progress:{_ in})
        try encoder.encode(refined.report).write(to:temp.appendingPathComponent("local.json"))
        print("FUSION",String(data:try encoder.encode(result.report),encoding:.utf8)!)
        print("REPLAY",records.count,"frames;",baseline.points.count,"baseline;",result.points.count,"surface output;",temp.path)
    }
}
