import Foundation

/// 掃描後背景工作的跨執行緒取消旗標；與 UI 及訓練引擎無關。
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
