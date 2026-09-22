import Foundation
import simd

@main struct MetricScaleTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ text: String) { precondition(value,text); checks += 1; print("PASS: \(text)") }
        let aim = SIMD2<Float>(100,100)
        check(SceneMetricScale.pickProjectedIndex([SIMD3(100,100,0.8),SIMD3(110,100,0.1)],at:aim) == 0,
              "nearby foreground cannot steal a precisely aimed surface")
        check(SceneMetricScale.pickProjectedIndex([SIMD3(100,100,0.8),SIMD3(101,100,0.1)],at:aim) == 1,
              "overlapping pixels pick the visible front surface")
        check(SceneMetricScale.pickProjectedIndex([SIMD3(140,100,0.8),SIMD3(100,100,1.1),SIMD3(.nan,100,0.1)],at:aim) == nil,
              "empty space, clipped and nonfinite points do not select an endpoint")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metric-test-"+UUID().uuidString)
        let dir = root.appendingPathComponent("scan_test")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let points = [CloudPoint(x:0,y:0,z:-2,r:1,g:2,b:3),CloudPoint(x:2,y:0,z:-2,r:4,g:5,b:6)]
        let library = ScanLibrary(root:root)
        let record = FrameRecord(id:1,timestamp:0,transform:[1,0,0,1,0,1,0,2,0,0,1,3,0,0,0,1],
            intrinsics:.init(fx:100,fy:100,cx:80,cy:60,width:160,height:120),exposureDuration:0.005,
            exposureOffsetEV:0,estimatedBlurPx:0,imageFile:"frame.jpg",depthFile:"depth.bin")
        try Data([0xff,0xd8]).write(to:dir.appendingPathComponent("images/frame.jpg"))
        try await library.saveReview(directory:dir,points:points,records:[record])
        var scale = try SceneMetricScale.load(in:dir)
        check(scale.status=="nominalUnverified" && scale.metersPerSourceUnit==1,"meter units alone are not marked validated")
        scale.calibration = .init(start:[0,0,-2],end:[2,0,-2],knownMeters:2.04)
        try scale.save(in:dir)
        check(scale.status=="calibratedUnverified", "calibration alone is not independent validation")
        var invalid = scale
        invalid.validations = [scale.calibration!]
        do { _ = try invalid.checked(); fatalError("self-validation accepted") } catch SceneMetricScale.MetricError.repeatedReference { checks+=1 }
        scale.validations = [.init(start:[0,1,-2],end:[3,1,-2],knownMeters:3.06)]
        try scale.save(in:dir)
        check(scale.referencesPass && scale.status=="referenceDistancesPassed","separate reference checks corrected length")
        var failed = scale; failed.validations[0].knownMeters=3.2
        check(!failed.referencesPass && failed.status=="referenceDistancesFailed","inconsistent room scale is reported, not forced to pass")
        invalid=scale; invalid.calibration?.knownMeters = .nan
        do { _=try invalid.checked();fatalError("NaN accepted") } catch { checks+=1 }
        invalid=scale;invalid.calibration?.knownMeters=20
        do { _=try invalid.checked();fatalError("huge factor accepted") } catch SceneMetricScale.MetricError.invalidScale { checks+=1 }
        let scaledPoints=try scale.scaled(points), scaledRecords=try scale.scaled([record])
        check(abs(scaledPoints[1].x-2.04)<0.0001 && abs(scaledRecords[0].transform[3]-1.02)<0.0001,"points and camera translation share one metric factor")
        check(scaledRecords[0].transform[0]==1 && scaledRecords[0].intrinsics.fx==100,"scale leaves rotation and camera calibration unchanged")
        check(scaledRecords[0].depthFile==nil,"metric poses cannot silently reuse unscaled depth")
        let p=SIMD3<Float>(points[1].x,points[1].y,points[1].z)
        let a=RefusionEngine.float4x4(rowMajor:record.transform).inverse * SIMD4(p,1)
        let b=RefusionEngine.float4x4(rowMajor:scaledRecords[0].transform).inverse * SIMD4(p*Float(scale.metersPerSourceUnit),1)
        check(abs(a.x/a.z-b.x/b.z)<0.00001 && abs(a.y/a.z-b.y/b.z)<0.00001,"paired scaling preserves image projections")
        let entry=try await library.entries().first!
        let original=try Data(contentsOf:dir.appendingPathComponent("review.ply"))
        let zip=try await library.metricArchive(entry)
        check(FileManager.default.fileExists(atPath:zip.path),"metric COLMAP archive is published")
        let unpacked = root.appendingPathComponent("unpacked")
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments = ["-xk",zip.path,unpacked.path]; try process.run(); process.waitUntilExit()
        check(process.terminationStatus == 0,"metric archive is a readable ZIP")
        let children = FileManager.default.enumerator(at:unpacked,includingPropertiesForKeys:nil)!.allObjects as! [URL]
        let manifestURL = children.first { $0.lastPathComponent=="scene-metrics.json" }!
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! [String:Any]
        check(manifest["units"] as? String == "meters" && manifest["scaleApplied"] as? Bool == true,
              "archive declares applied metric scale and units")
        let output = manifestURL.deletingLastPathComponent()
        check(!output.lastPathComponent.hasPrefix("."),"unzipped dataset folder is visible in file browsers")
        let exported = try ScanLibrary.readPLY(output.appendingPathComponent("points.ply"),limit:100)
        check(abs(exported[1].x-2.04)<0.0001 && FileManager.default.fileExists(atPath:output.appendingPathComponent("sparse/0/images.bin").path),
              "published ZIP contains scaled geometry and the COLMAP model")
        check(!FileManager.default.fileExists(atPath:output.appendingPathComponent("depth").path),"metric archive omits incompatible unscaled depth")
        check(original == (try Data(contentsOf:dir.appendingPathComponent("review.ply"))),"metric export preserves raw preview bytes")
        var appended = record; appended.id = 2
        try ExportManager.writeRefinedPoses([record,appended],to:dir.appendingPathComponent("poses.jsonl"))
        do { _ = try await library.metricScale(entry); fatalError("outdated preview accepted") }
        catch SceneMetricScale.MetricError.staleGeometry { checks += 1; print("PASS: resumed frames invalidate old measurement geometry") }
        try FileManager.default.removeItem(at:dir.appendingPathComponent("poses.jsonl"))
        var changed=points;changed[0].x=0.02
        try ExportManager.writePLY(changed,to:dir.appendingPathComponent("review.ply"))
        do { _=try SceneMetricScale.load(in:dir);fatalError("stale reference accepted") } catch SceneMetricScale.MetricError.staleGeometry { checks+=1 }
        try await library.delete(entry)
        check(!FileManager.default.fileExists(atPath:zip.path),"deleting a scan also removes its metric archive")
        print("\(checks) metric-scale checks passed")
    }
}
