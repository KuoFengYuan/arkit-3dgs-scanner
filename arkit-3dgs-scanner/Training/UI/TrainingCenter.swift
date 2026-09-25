// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import SwiftUI
import UIKit
import Combine

/// A Bool shared between the main thread and the training thread.
nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// App-wide owner of the (single) on-device training run. Training keeps running while the
/// user browses History; it pauses with a checkpoint when the app leaves the foreground (iOS
/// does not allow background GPU work), when the device gets too hot, on low battery, or when
/// memory runs short.
@MainActor
final class TrainingCenter: ObservableObject {
    static let shared = TrainingCenter()

    @Published private(set) var activeScan: URL?
    @Published private(set) var configuration: GaussianTrainingConfiguration?
    @Published private(set) var snapshot = TrainingSnapshot()
    @Published private(set) var frame: CGImage?
    @Published private(set) var frameRequest: ViewerRequest?
    @Published private(set) var views: [TrainingFrame] = []
    @Published private(set) var initialDepth = 1.5
    /// Bumped whenever a run ends so History re-reads training states.
    @Published private(set) var revision = 0

    private var session: GaussianTrainingSession?
    private var observers: [NSObjectProtocol] = []
    /// Battery state read on main (UIDevice is main-thread only) for the training thread.
    private let batteryLow = LockedFlag()
    private var memorySource: DispatchSourceMemoryPressure?

    private init() {
        let center = NotificationCenter.default
        // Pause as soon as the app stops being active: GPU work is still allowed then, so the
        // pause checkpoint can be written; a background task covers the file write.
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leaveForeground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leaveForeground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.setBackgrounded(false); self?.endBackgroundTask() }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.memoryPressure(critical: false) }
        })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.memorySource else { return }
                self.session?.memoryPressure(critical: source.data.contains(.critical))
            }
        }
        source.resume()
        memorySource = source
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBattery() }
            })
        }
        updateBattery()
    }

    private func updateBattery() {
        let device = UIDevice.current
        batteryLow.value = device.batteryState == .unplugged && device.batteryLevel >= 0 && device.batteryLevel < 0.15
    }

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func leaveForeground() {
        guard let session else { return }
        session.setBackgrounded(true)
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "gaussian-checkpoint") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func isActive(_ scan: URL) -> Bool { activeScan?.standardizedFileURL.path == scan.standardizedFileURL.path }
    var isBusy: Bool { activeScan != nil }

    /// Starts (or resumes from the checkpoint) training of `scan`. Returns false if another scan
    /// is training.
    @discardableResult
    func start(scan: URL, configuration: GaussianTrainingConfiguration, resume: Bool) -> Bool {
        guard activeScan == nil || isActive(scan) else { return false }
        guard session == nil else { return true }
        let session = GaussianTrainingSession(workspace: TrainingWorkspace(scan: scan), configuration: configuration, resume: resume)
        session.thermalLevel = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return 0
            case .fair: return 1
            case .serious: return 2
            case .critical: return 3
            @unknown default: return 2
            }
        }
        let battery = batteryLow
        session.batteryLow = { battery.value }
        session.lowPowerMode = { ProcessInfo.processInfo.isLowPowerModeEnabled }
        session.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async { self?.receive(snapshot) }
        }
        session.onFrame = { [weak self] frame, request in
            let image = frame.cgImage
            DispatchQueue.main.async { self?.frame = image; self?.frameRequest = request }
        }
        session.onPreparedViews = { [weak self] views, depth in
            DispatchQueue.main.async { self?.views = views; self?.initialDepth = depth }
        }
        self.session = session
        activeScan = scan
        self.configuration = configuration
        snapshot = TrainingSnapshot(phase: .preparing, iteration: 0, total: configuration.iterations)
        frame = nil
        views = []
        UIApplication.shared.isIdleTimerDisabled = true
        let thread = Thread { session.run() }
        thread.name = "gaussian-training"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 4 << 20
        thread.start()
        return true
    }

    private func receive(_ snapshot: TrainingSnapshot) {
        self.snapshot = snapshot
        if snapshot.phase == .completed, let configuration, snapshot.total > 0 {
            TrainingSpeedHistory.record(configuration.preset, secondsPerIteration: snapshot.elapsedSeconds / Double(snapshot.total))
        }
        switch snapshot.phase {
        case .completed, .failed, .cancelled:
            session = nil
            activeScan = nil
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()
            revision += 1
        case .paused:
            UIApplication.shared.isIdleTimerDisabled = false
            // The pause checkpoint is on disk; the background grace period is no longer needed.
            if snapshot.reason == .background { endBackgroundTask() }
        default:
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    func pause() { session?.pause() }
    func resume() { session?.resumeTraining() }
    func checkpoint() { session?.saveCheckpoint() }
    func cancel(keepCheckpoint: Bool) { session?.cancel(keepCheckpoint: keepCheckpoint) }
    func updateViewer(_ request: ViewerRequest?, interactive: Bool) { session?.updateViewer(request, interactive: interactive) }
}
