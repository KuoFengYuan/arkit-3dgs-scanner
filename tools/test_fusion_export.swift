import Foundation

@main struct FusionExportTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1; print("PASS: \(message)")
        }
        let surface: [CloudPoint] = (0..<20_000).map { i in
            let x: Float = Float(i % 200) * 0.02 + 0.01
            let y: Float = Float(i / 200) * 0.02 + 0.01
            return CloudPoint(x: x, y: y,
                       z: -2.01, r: UInt8(i % 255), g: 70, b: 90)
        }
        let isolated = (0..<10_000).map { i in
            CloudPoint(x: Float(i % 100) * 0.1 + 10, y: Float(i / 100) * 0.1 + 10,
                       z: -10, r: 255, g: 0, b: 0)
        }
        func makeGrid() -> FusedVoxelGrid {
            var grid = FusedVoxelGrid(voxelSize: 0.02, maxCells: 100_000)
            grid.insert(surface, boundedMemory: true)
            grid.insert(isolated, boundedMemory: true)
            return grid
        }
        var grid = makeGrid()
        var fractions: [Double] = []
        let result = grid.consumeExportPoints(target: 18_000, minNeighbors: 3,
            shouldContinue: { true }, progress: { fractions.append($0) })!
        check(result.count == 18_000, "rejection occurs before sampling: eligible surface fills the output budget")
        check(result.allSatisfy { $0.z > -3 }, "isolated cells do not occupy the limited output budget")
        check(grid.count == 0, "export drains every grid shard before returning the cloud")
        check(fractions.first == 0 && fractions.last == 1 && zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 },
              "filter and materialization progress is monotonic and completes")
        let expected = Set(surface.map { SIMD3($0.x, $0.y, $0.z) })
        check(result.allSatisfy { expected.contains(SIMD3($0.x, $0.y, $0.z)) }, "bounded export preserves original surface positions")
        grid = makeGrid()
        var keepGoing = true
        let interrupted = grid.consumeExportPoints(target: 18_000, minNeighbors: 3,
            shouldContinue: { keepGoing }, progress: { if $0 >= 0.6 { keepGoing = false } })
        check(interrupted == nil, "pressure/cancellation during output cannot publish a partial point cloud")
        check(grid.count > 0 && grid.count < 30_000, "already consumed shards are released before an interruption")
        grid = makeGrid()
        let stopped = grid.consumeExportPoints(target: 100, minNeighbors: 0,
            shouldContinue: { false }, progress: { _ in fatalError("must stop before allocating") })
        check(stopped == nil && grid.count == 30_000, "initial pressure stops before allocating output")
        grid = makeGrid()
        let small = grid.consumeExportPoints(target: 40_000, minNeighbors: 3,
            shouldContinue: { true }, progress: { _ in })!
        check(small.count == 20_000, "under-budget clouds keep all supported cells")
        var bad = CloudPoint(x: 0, y: 0, z: 0, r: 1, g: 2, b: 3); bad.score = .infinity
        grid.insert([bad], boundedMemory: true)
        check(grid.count == 0, "nonfinite weights cannot poison fused colors and trap UInt8 conversion")
        print("\(checks) fusion export checks passed")
    }
}
