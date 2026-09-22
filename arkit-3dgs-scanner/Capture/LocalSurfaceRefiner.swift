import Foundation
import simd

/// Bounded RGB-D refinement against fixed local anchors, after feature BA/loop closure.
/// Fixed anchors prevent a sequential ICP chain from accumulating a new drift or scale change.
nonisolated enum LocalSurfaceRefiner {
    struct Report: Codable, Sendable {
        var status = "completed"
        var attempted = 0
        var accepted = 0
        var degenerate = 0
        var rejected = 0
        var rejectionReasons: [String:Int] = [:]
        var peakDepthFrames = 0
        var beforeRMSEM: Float?
        var afterRMSEM: Float?
        var maxTranslationM: Float = 0
        var seconds = 0.0
    }
    struct Frame {
        let view: DepthConsistencyView
        let gray: [UInt8]
        let grayWidth: Int
        let grayHeight: Int
        let pose: simd_float4x4
        func local(_ x: Int, _ y: Int) -> SIMD3<Float>? {
            let k = view.intrinsics, i = y*k.width+x
            guard x >= 0, y >= 0, x < k.width, y < k.height else { return nil }
            let d = view.depth[i]
            guard d.isFinite, d > 0.2, d < 4.5, view.confidence == nil || view.confidence![i] >= 1 else { return nil }
            return SIMD3((Float(x)-Float(k.cx))*d/Float(k.fx), (Float(k.cy)-Float(y))*d/Float(k.fy), -d)
        }
        func intensity(_ x: Int, _ y: Int) -> Float {
            let gx = min(grayWidth-1,max(0,x*grayWidth/view.intrinsics.width))
            let gy = min(grayHeight-1,max(0,y*grayHeight/view.intrinsics.height))
            return Float(gray[gy*grayWidth+gx])/255
        }
        func verification(_ world: SIMD3<Float>, normal: SIMD3<Float>) -> (residual: Float, intensity: Float)? {
            guard let s = view.sample(world,config:CaptureConfig()), abs(s.projectedDepth-s.measuredDepth) < 0.08 else { return nil }
            let p = view.worldToCamera*SIMD4(world,1), k = view.intrinsics
            let x = Int((Float(k.fx)*p.x/s.projectedDepth+Float(k.cx)).rounded())
            let y = Int((Float(k.cy)-Float(k.fy)*p.y/s.projectedDepth).rounded())
            let origin = SIMD3(pose.columns.3.x,pose.columns.3.y,pose.columns.3.z)
            let residual = simd_dot(world-origin,normal)*(1-s.measuredDepth/s.projectedDepth)
            return (residual,intensity(x,y))
        }
        func match(_ world: SIMD3<Float>) -> (point: SIMD3<Float>, normal: SIMD3<Float>, intensity: Float)? {
            let p = view.worldToCamera * SIMD4(world,1), z = -p.z, k = view.intrinsics
            guard z > 0.2 else { return nil }
            let u = Float(k.fx)*p.x/z+Float(k.cx), v = Float(k.cy)-Float(k.fy)*p.y/z
            guard u.isFinite,v.isFinite,u >= 1,v >= 1,u < Float(k.width-2),v < Float(k.height-2) else { return nil }
            let x = Int(u.rounded()), y = Int(v.rounded())
            guard let q = local(x,y), let l = local(x-1,y),let r = local(x+1,y),
                  let t = local(x,y-1),let b = local(x,y+1), abs(q.z+z) < 0.10,
                  max(abs(l.z-r.z),abs(t.z-b.z)) < max(0.08,-q.z*0.15) else { return nil }
            let cross = simd_cross(r-l,b-t), length = simd_length(cross)
            guard length > 1e-7 else { return nil }
            let n = cross/length
            let n1 = simd_cross(r-q,b-q), n2 = simd_cross(q-l,q-t)
            guard simd_length(n1) > 1e-7, simd_length(n2) > 1e-7,
                  simd_dot(simd_normalize(n1),simd_normalize(n2)) > 0.98,
                  max(abs(simd_dot(l-q,n)),abs(simd_dot(t-q,n))) < 0.01 else { return nil }
            let pose = self.pose, wp = pose*SIMD4(q,1), wn = pose*SIMD4(cross/length,0)
            return (SIMD3(wp.x,wp.y,wp.z),SIMD3(wn.x,wn.y,wn.z),intensity(x,y))
        }
    }
    struct Sample { let local: SIMD3<Float>; let intensity: Float; let holdout: Bool }
    struct Alignment {
        var pose: simd_float4x4
        var reason: String
        var before: Float = 0
        var after: Float = 0
    }
    static func load(_ r: FrameRecord, directory: URL) -> Frame? {
        guard r.blurVerdict != .drop, let w = r.depthWidth, let h = r.depthHeight,
              w <= 512,h <= 512,
              let view = RefusionEngine.storedDepthView(r,directory:directory.appendingPathComponent("depth")),
              let image = ScanImageDecoder.gray(r,directory:directory,maxDimension:512) else { return nil }
        return Frame(view:view,gray:image.pixels,grayWidth:image.width,grayHeight:image.height,pose:view.worldToCamera.inverse)
    }
    static func align(source: Frame, references: [Frame], shouldContinue: () -> Bool = { true }) -> Alignment {
        let original = source.pose
        var samples: [Sample] = []
        let k = source.view.intrinsics
        let stride = max(2,Int(sqrt(Double(k.width*k.height)/1800)))
        var index = 0
        for y in Swift.stride(from:2,to:k.height-2,by:stride) {
            for x in Swift.stride(from:2,to:k.width-2,by:stride) {
                guard let p = source.local(x,y) else { continue }
                samples.append(Sample(local:p,intensity:source.intensity(x,y),holdout:index%5 == 0)); index += 1
            }
        }
        struct Observation { let p: SIMD3<Float>; let n: SIMD3<Float>; let residual: Float; let photo: Float; let index: Int; let reference: Int }
        func observations(_ pose: simd_float4x4, holdout: Bool) -> [Observation] {
            var result: [Observation] = []
            for (index,s) in samples.enumerated() where s.holdout == holdout {
                let wp = pose*SIMD4(s.local,1), p = SIMD3(wp.x,wp.y,wp.z)
                for (j,reference) in references.enumerated() {
                    guard let m = reference.match(p) else { continue }
                    let verified = holdout ? reference.verification(p,normal:m.normal) : (simd_dot(p-m.point,m.normal),m.intensity)
                    guard let verified else { continue }
                    if abs(verified.0) < 0.08 {
                        result.append(Observation(p:p,n:m.normal,residual:verified.0,
                            photo:abs(s.intensity-verified.1),index:index,reference:j))
                    }
                }
            }
            return result
        }
        let before = observations(original,holdout:true)
        guard before.count >= 80 else { return Alignment(pose:original,reason:"insufficientOverlap") }
        var pose = original
        for _ in 0..<5 {
            guard shouldContinue() else { return Alignment(pose:original,reason:"interrupted") }
            let obs = observations(pose,holdout:false)
            guard obs.count >= 160 else { return Alignment(pose:original,reason:"insufficientOverlap") }
            var a = [Double](repeating:0,count:36), b = [Double](repeating:0,count:6)
            let origin = SIMD3(pose.columns.3.x,pose.columns.3.y,pose.columns.3.z)
            for o in obs {
                let rotation = simd_cross(o.p-origin,o.n)
                let row = [rotation.x,rotation.y,rotation.z,o.n.x,o.n.y,o.n.z].map(Double.init)
                let weight = Double(min(1,0.015/max(0.0001,abs(o.residual))))
                for i in 0..<6 {
                    b[i] -= row[i]*Double(o.residual)*weight
                    for j in 0..<6 { a[i*6+j] += row[i]*row[j]*weight }
                }
            }
            // Do not use damping to invent constraints in a flat wall / low-overlap scene.
            guard let step = solve(a,b) else { return Alignment(pose:original,reason:"degenerate") }
            let omega = SIMD3(Float(step[0]),Float(step[1]),Float(step[2]))
            let translation = SIMD3(Float(step[3]),Float(step[4]),Float(step[5]))
            guard simd_length(omega) < 0.035, simd_length(translation) < 0.05 else {
                return Alignment(pose:original,reason:"excessiveCorrection")
            }
            let angle = simd_length(omega)
            let rotation = angle > 1e-8 ? simd_float3x3(simd_quatf(angle:angle,axis:omega/angle)) : matrix_identity_float3x3
            var delta = matrix_identity_float4x4
            for c in 0..<3 { delta[c] = SIMD4(rotation[c],0) }
            delta.columns.3 = SIMD4(origin-rotation*origin+translation,1)
            pose = delta*pose
            let shift = simd_length(SIMD3(pose.columns.3.x-original.columns.3.x,pose.columns.3.y-original.columns.3.y,pose.columns.3.z-original.columns.3.z))
            let r = simd_quatf(pose*original.inverse)
            guard shift <= 0.03, 2*acos(min(1,abs(r.real))) <= 1.5 * .pi/180 else {
                return Alignment(pose:original,reason:"excessiveCorrection")
            }
            if simd_length(translation) < 0.0001, angle < 0.0001 { break }
        }
        guard shouldContinue() else { return Alignment(pose:original,reason:"interrupted") }
        // Hold reference normals fixed for independent validation. Re-estimating a noisy
        // normal at the new pixel can falsely erase a valid held-out depth correspondence.
        var mapped: [Int:Observation] = [:]
        for o in before {
            let s = samples[o.index], world = pose*SIMD4(s.local,1), p = SIMD3(world.x,world.y,world.z)
            guard let v = references[o.reference].verification(p,normal:o.n) else { continue }
            mapped[o.index*references.count+o.reference] = Observation(p:p,n:o.n,residual:v.residual,
                photo:abs(s.intensity-v.intensity),index:o.index,reference:o.reference)
        }
        // Evaluate the same held-out pixels/reference pairs. Losing difficult samples cannot win.
        var squaredBefore: Float = 0, squaredAfter: Float = 0, photoBefore: Float = 0, photoAfter: Float = 0
        var lost = 0
        for o in before {
            squaredBefore += o.residual*o.residual; photoBefore += o.photo
            if let n = mapped[o.index*references.count+o.reference] {
                squaredAfter += n.residual*n.residual; photoAfter += n.photo
            } else {
                lost += 1
                let penalty = max(0.03,abs(o.residual))
                squaredAfter += penalty*penalty; photoAfter += o.photo+0.02
            }
        }
        guard lost <= before.count/20 else { return Alignment(pose:original,reason:"lostHoldout") }
        let rmsBefore = sqrt(squaredBefore/Float(before.count)), rmsAfter = sqrt(squaredAfter/Float(before.count))
        guard rmsBefore > 0.001, rmsAfter < rmsBefore*0.95 else {
            return Alignment(pose:original,reason:"holdoutRejected",before:rmsBefore,after:rmsAfter)
        }
        guard photoAfter <= photoBefore*1.02 + Float(before.count)*0.002 else {
            return Alignment(pose:original,reason:"imageHoldoutRejected",before:rmsBefore,after:rmsAfter)
        }
        return Alignment(pose:pose,reason:"validated",before:rmsBefore,after:rmsAfter)
    }
    /// Normalized pivot test rejects poorly constrained six-DOF systems before any regularization.
    static func solve(_ input: [Double], _ rhs: [Double]) -> [Double]? {
        let scales = (0..<6).map { sqrt(max(0,input[$0*6+$0])) }
        guard scales.allSatisfy({ $0 > 1e-5 && $0.isFinite }) else { return nil }
        var a = input, b = rhs
        for i in 0..<6 { b[i] /= scales[i]; for j in 0..<6 { a[i*6+j] /= scales[i]*scales[j] } }
        for i in 0..<6 {
            let pivot = (i..<6).max(by:{abs(a[$0*6+i]) < abs(a[$1*6+i])})!
            guard abs(a[pivot*6+i]) > 1e-3 else { return nil }
            if pivot != i { for j in 0..<6 { a.swapAt(i*6+j,pivot*6+j) }; b.swapAt(i,pivot) }
            let d = a[i*6+i]
            for j in i..<6 { a[i*6+j] /= d }; b[i] /= d
            for row in 0..<6 where row != i {
                let factor = a[row*6+i]
                for j in i..<6 { a[row*6+j] -= factor*a[i*6+j] }; b[row] -= factor*b[i]
            }
        }
        let result = (0..<6).map { b[$0]/scales[$0] }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
    static func run(records: [FrameRecord], directory: URL,
                    shouldContinue: () -> Bool = { true }, progress: (Double) -> Void = { _ in }) -> (records: [FrameRecord], report: Report) {
        let started = Date(); var report = Report(), output = records
        let ordered = records.indices.filter { records[$0].blurVerdict != .drop && records[$0].depthFile != nil }
            .sorted { records[$0].timestamp < records[$1].timestamp }
        var sumBefore: Float = 0, sumAfter: Float = 0
        guard ordered.count >= 3 else { report.status = "insufficientDepthFrames"; return (records,report) }
        for start in Swift.stride(from:0,to:ordered.count-1,by:8) {
            guard shouldContinue() else { report.status = "interrupted"; report.seconds = Date().timeIntervalSince(started); return (records,report) }
            let end = min(start+8,ordered.count-1)
            let refs = autoreleasepool { [ordered[start],ordered[end]].compactMap { load(records[$0],directory:directory) } }
            guard refs.count == 2 else { continue }
            for ordinal in (start+1)..<end {
                guard shouldContinue() else { report.status = "interrupted"; report.seconds = Date().timeIntervalSince(started); return (records,report) }
                let i = ordered[ordinal]
                guard let source = autoreleasepool(invoking:{load(records[i],directory:directory)}) else { continue }
                report.peakDepthFrames = 3; report.attempted += 1
                let alignment = align(source:source,references:refs,shouldContinue:shouldContinue)
                if alignment.reason != "validated" { report.rejectionReasons[alignment.reason,default:0] += 1 }
                if alignment.reason == "validated" {
                    output[i].transform = RefusionEngine.rowMajor(alignment.pose); report.accepted += 1
                    sumBefore += alignment.before; sumAfter += alignment.after
                    let a = alignment.pose.columns.3, b = source.pose.columns.3
                    report.maxTranslationM = max(report.maxTranslationM,simd_length(SIMD3(a.x-b.x,a.y-b.y,a.z-b.z)))
                } else if alignment.reason == "degenerate" { report.degenerate += 1 }
                else { report.rejected += 1 }
                progress(Double(ordinal)/Double(ordered.count))
            }
        }
        if report.accepted > 0 { report.beforeRMSEM = sumBefore/Float(report.accepted); report.afterRMSEM = sumAfter/Float(report.accepted) }
        report.seconds = Date().timeIntervalSince(started); progress(1)
        return (output,report)
    }
}
