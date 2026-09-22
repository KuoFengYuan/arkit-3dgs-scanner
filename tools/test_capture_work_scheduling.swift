import Foundation

actor BlockingWork {
    private var gate: CheckedContinuation<Void, Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var jobs: [Int] = []
    func run(_ value: Int) async {
        jobs.append(value)
        guard value == 1 else { return }
        await withCheckedContinuation { continuation in
            gate = continuation
            started = true
            for waiter in startWaiters { waiter.resume() }
            startWaiters.removeAll()
        }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
    func values() -> [Int] { jobs }
}

@main struct CaptureWorkSchedulingTests {
    static func main() async {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); count += 1; print("PASS: \(message)")
        }
        let work = BlockingWork()
        let queue = LatestFrameProcessor<Int> { await work.run($0) }
        await queue.submit(1)
        await work.waitForStart()
        // Every producer submission must return while feature matching is deliberately blocked.
        for frame in 2...100 { await queue.submit(frame) }
        let busy = await queue.report()
        check(busy.submitted == 100 && busy.processed == 0, "slow feature work does not block 99 subsequent photo submissions")
        check(busy.maximumRetainedJobs == 2 && busy.replaced == 98, "full-size work stays bounded to active plus newest pending frame")
        await work.release()
        await queue.drain()
        check(await work.values() == [1,100], "stop drains the last saved viewpoint without running stale queued frames")
        let done = await queue.report()
        check(done.processed == 2 && done.totalMS >= done.maximumMS, "feature timing counts only actually processed work")
        await queue.submit(101); await queue.drain()
        check(await work.values() == [1,100,101], "resuming after drain still accepts the next frame")
        await queue.drain()
        check(await queue.report().processed == 3, "draining an idle queue is safe")

        let oldWork = BlockingWork()
        let oldQueue = LatestFrameProcessor<Int> { await oldWork.run($0) }
        await oldQueue.submit(1); await oldWork.waitForStart(); await oldQueue.submit(2)
        await oldQueue.close(); await oldQueue.submit(3)
        let newWork = BlockingWork()
        let newQueue = LatestFrameProcessor<Int> { await newWork.run($0) }
        await newQueue.submit(7); await newQueue.drain()
        check(await newWork.values() == [7], "a new scan's worker is independent of an old in-flight scan")
        await oldWork.release(); await oldQueue.drain()
        check(await oldWork.values() == [1], "leaving a scan discards pending work and rejects later submissions")

        var budget = PreviewSamplingBudget()
        var visited = Set<Int>(); var maximumCandidates = 0
        for _ in 0..<9 {
            let sample = budget.next(width: 256, height: 192)
            var candidates = 0
            for y in stride(from: sample.y, to: 192, by: sample.stride) {
                for x in stride(from: sample.x, to: 256, by: sample.stride) { visited.insert(y*256+x); candidates += 1 }
            }
            maximumCandidates = max(maximumCandidates,candidates)
        }
        check(maximumCandidates <= 6000, "each preview considers at most 6000 raw depth samples")
        check(visited.count == 256*192, "cycling offsets covers every depth pixel instead of permanently skipping fine features")
        budget.record(milliseconds: 410); budget.record(milliseconds: 66)
        check(budget.adaptiveStride == 4, "slow integration automatically lowers next-frame work")
        for _ in 0..<100 { budget.record(milliseconds: 1000) }
        check(budget.adaptiveStride == 6, "repeated overruns keep adaptive stride bounded")
        for _ in 0..<11 { budget.record(milliseconds: 1) }
        check(budget.adaptiveStride == 6, "brief fast bursts do not cause sampling-rate oscillation")
        budget.record(milliseconds: 1)
        check(budget.adaptiveStride == 5, "sustained headroom gradually restores denser preview")
        for _ in 0..<100 { budget.record(milliseconds: 1) }
        check(budget.adaptiveStride == 2, "recovered workload returns to configured detail floor")
        budget.record(milliseconds: .nan)
        check(budget.adaptiveStride == 2, "invalid timings cannot corrupt the adaptive state")
        let large = budget.next(width: 1024,height: 768)
        let sampled = ((1024+large.stride-1)/large.stride)*((768+large.stride-1)/large.stride)
        check(sampled <= 6000, "larger depth maps still obey the hard sample-count budget")
        print("\(count) checks passed")
    }
}
