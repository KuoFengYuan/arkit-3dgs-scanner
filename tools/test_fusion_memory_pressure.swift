import Foundation

@main struct FusionMemoryTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("fusion-pressure-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let mib: UInt64 = 1_048_576
        if CommandLine.arguments.contains("--unwritable-stderr") {
            // The parent supplies fd 2 as a read-only /dev/null. The previous final
            // FileHandle.standardError.write raised an uncaught Objective-C exception here.
            let result = RefusionEngine.refuseWithReport(records: [], sessionDir: directory,
                config: CaptureConfig(), availableMemory: { 512*mib }, progress: { _ in })
            precondition(result.report.status == "completed")
            let data = try Data(contentsOf: directory.appendingPathComponent("refusion-progress.json"))
            let saved = try JSONDecoder().decode(RefusionEngine.Report.self,from:data)
            precondition(saved.status == "completed")
            return
        }
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value,message); checks += 1; print("PASS: \(message)") }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--unwritable-stderr"]
        let invalidLog = try FileHandle(forReadingFrom: URL(fileURLWithPath:"/dev/null"))
        defer { try? invalidLog.close() }
        child.standardError = invalidLog
        try child.run(); child.waitUntilExit()
        check(child.terminationReason == .exit && child.terminationStatus == 0,
              "unwritable debug stderr cannot crash final fusion or prevent completed report persistence")
        check(RefusionEngine.shouldStopForMemory(availableBytes:191*mib), "stop before exhausting the 192 MiB reserve")
        check(RefusionEngine.frameHeadroomBytes(width:256,height:192) == 224*mib,
              "native LiDAR preflight includes decode and candidate-array workspace")
        check(RefusionEngine.frameHeadroomBytes(width:4096,height:4096) > 1024*mib,
              "oversized imported depth cannot begin decoding with only a small reserve")
        let pressure = RefusionEngine.refuseWithReport(records:[],sessionDir:directory,config:CaptureConfig(),
            availableMemory:{ 2048*mib },memoryPressure:{true},progress:{ _ in })
        check(pressure.report.status == "memoryPressure" && pressure.points.isEmpty && pressure.report.memoryStopReason == "systemMemoryPressure",
              "system pressure wins over an optimistic available-memory estimate")
        let low = RefusionEngine.refuseWithReport(records:[],sessionDir:directory,config:CaptureConfig(),
            availableMemory:{ 191*mib },progress:{ _ in })
        check(low.report.status == "memoryPressure" && low.report.memoryStopReason == "reservedHeadroom",
              "low headroom preserves an explicit fallback reason")
        let points = (0..<20_000).map { i in CloudPoint(x:Float(i%200)*0.03,y:Float(i/200)*0.03,z:-2,r:5,g:6,b:7) }
        var grid = FusedVoxelGrid(voxelSize:0.01,maxCells:100_000)
        var polls = 0
        let inserted = grid.insert(points,boundedMemory:true,shouldContinue:{ polls += 1; return polls < 4 })
        check(!inserted && grid.count < points.count,"pressure interrupts one frame's insertion before the full batch is allocated")
        grid = FusedVoxelGrid(voxelSize:0.01,maxCells:100_000)
        grid.insert(points,boundedMemory:true)
        polls = 0
        let compacted = grid.reduceCapacity(to:100,shouldContinue:{ polls += 1; return polls < 5 })
        check(!compacted,"pressure interrupts coarsening itself instead of waiting until the next frame")
        // Interrupted mutable grids are discarded, never exported as a completed scan.
        print("\(checks) fusion memory/crash checks passed")
    }
}
