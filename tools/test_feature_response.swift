import Foundation

@main struct FeatureResponseTests {
    static func main() {
        let w = 960, h = 720, row = 976
        var seed: UInt64 = 42
        var pixels = [UInt8](repeating: 0, count: row*h)
        for i in pixels.indices { seed = seed &* 6364136223846793005 &+ 1; pixels[i] = UInt8(truncatingIfNeeded: seed >> 32) }
        let s = FeatureParams.stride, gw = w/s, gh = h/s
        let start = Date()
        var reference = [Float](repeating: 0, count: gw*gh)
        for gy in 2..<(gh-2) { for gx in 2..<(gw-2) {
            var a: Float = 0, b: Float = 0, c: Float = 0
            for dy in -1...1 { for dx in -1...1 {
                let pos = (gy+dy)*s*row+(gx+dx)*s
                let ix = Float(Int(pixels[pos+s])-Int(pixels[pos-s]))
                let iy = Float(Int(pixels[pos+s*row])-Int(pixels[pos-s*row]))
                a += ix*ix; b += ix*iy; c += iy*iy
            } }
            let t = (a+c)*0.5, diff = (a-c)*0.5
            reference[gy*gw+gx] = t - (diff*diff+b*b).squareRoot()
        } }
        let scalarSeconds = Date().timeIntervalSince(start)
        let acceleratedStart = Date()
        let response = pixels.withUnsafeBufferPointer {
            FeatureExtractor.cornerResponses(pixels: $0.baseAddress!, width: w, height: h, rowBytes: row)!
        }
        let acceleratedSeconds = Date().timeIntervalSince(acceleratedStart)
        var maxError: Float = 0
        for y in 2..<(gh-2) { for x in 2..<(gw-2) {
            maxError = max(maxError, abs(response[y*gw+x]-reference[y*gw+x]))
        } }
        precondition(maxError < 0.5, "accelerated tensor differs from scalar reference: \(maxError)")
        print("PASS: strided 960x720 corner responses match scalar reference; max error \(maxError)")
        let flat = [UInt8](repeating: 128, count: row*h)
        let flatResponse = flat.withUnsafeBufferPointer {
            FeatureExtractor.cornerResponses(pixels: $0.baseAddress!, width: w, height: h, rowBytes: row)!
        }
        precondition(flatResponse.allSatisfy { $0 == 0 })
        print("PASS: a textureless image produces no spurious corners")
        print(String(format: "scalar %.4fs / Accelerate %.4fs (same Mac process, corner kernel only)", scalarSeconds, acceleratedSeconds))
    }
}
