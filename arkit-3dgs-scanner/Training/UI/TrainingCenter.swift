// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import SwiftUI
import UIKit
import Combine
import BackgroundTasks

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
    /// Training keeps running when the app leaves the foreground (a continued-processing task
    /// with background GPU access is active, iOS 26+); otherwise it pauses with a checkpoint.
    @Published private(set) var continuesInBackground = false
    /// A capture is on screen; training pauses meanwhile.
    private var capturing = false

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
            MainActor.assumeIsolated {
                self?.session?.setAppInBackground(false)
                self?.session?.setBackgrounded(false)
                self?.endBackgroundTask()
            }
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
        if continuesInBackground {
            // The system granted background GPU time: keep training, without live previews.
            session.setAppInBackground(true)
            return
        }
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
        snapshot = TrainingSnapshot(phase: .preparing, iteration: configuration.startIteration, total: configuration.iterations,
                                    startIteration: configuration.startIteration)
        frame = nil
        views = []
        UIApplication.shared.isIdleTimerDisabled = true
        session.setCapturing(capturing)
        if #available(iOS 26.0, *) { beginContinuedProcessing(total: configuration.runIterations) }
        let thread = Thread { session.run() }
        thread.name = "gaussian-training"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 4 << 20
        thread.start()
        return true
    }

    private func receive(_ snapshot: TrainingSnapshot) {
        self.snapshot = snapshot
        if #available(iOS 26.0, *) { reportContinuedProgress(snapshot) }
        // Speeds come from full new runs: early finishes and enhancements train a different mix.
        if snapshot.phase == .completed, let configuration, !configuration.isEnhancement,
           snapshot.total > 0, snapshot.iteration >= snapshot.total {
            TrainingSpeedHistory.record(configuration, secondsPerIteration: snapshot.elapsedSeconds / Double(snapshot.total))
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

    /// Pauses training while a capture is open (and resumes when it closes).
    func setCapturing(_ value: Bool) {
        capturing = value
        session?.setCapturing(value)
    }

    func pause() { session?.pause() }
    func resume() {
        session?.resumeTraining()
        // Resuming is a user action, so background time can be requested again after it expired.
        if #available(iOS 26.0, *), session != nil, continuedTask == nil, let configuration {
            beginContinuedProcessing(total: configuration.runIterations)
        }
    }
    func checkpoint() { session?.saveCheckpoint() }
    func finishNow() { session?.finishNow() }
    func cancel(keepCheckpoint: Bool) { session?.cancel(keepCheckpoint: keepCheckpoint) }
    func updateViewer(_ request: ViewerRequest?, interactive: Bool) { session?.updateViewer(request, interactive: interactive) }

    // MARK: Background continuation (iOS 26+)

    /// The running continued-processing task (`BGContinuedProcessingTask`).
    private var continuedTask: AnyObject?
    private var reportedPercent = -1

    /// Asks the system to keep this user-started run going if the app leaves the foreground.
    /// Needs background GPU support on the device and the Background GPU Access capability
    /// (paid developer teams); without either the submission fails and training pauses in the
    /// background as before.
    @available(iOS 26.0, *)
    private func beginContinuedProcessing(total: Int) {
        guard BGTaskScheduler.supportedResources.contains(.gpu), let bundle = Bundle.main.bundleIdentifier else { return }
        let identifier = "\(bundle).training.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask, let self, self.session != nil else {
                    task.setTaskCompleted(success: false)
                    return
                }
                task.progress.totalUnitCount = Int64(max(1, total))
                task.expirationHandler = { [weak self] in
                    DispatchQueue.main.async { self?.continuedProcessingExpired() }
                }
                self.continuedTask = task
                self.continuesInBackground = true
                self.reportedPercent = -1
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: L10n.text("訓練 3DGS"),
                                                       subtitle: L10n.text("讀取照片與點雲"))
        request.strategy = .fail
        request.requiredResources = .gpu
        do { try BGTaskScheduler.shared.submit(request) } catch { continuesInBackground = false }
    }

    @available(iOS 26.0, *)
    private func reportContinuedProgress(_ snapshot: TrainingSnapshot) {
        guard let task = continuedTask as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = Int64(max(1, snapshot.total - snapshot.startIteration))
        task.progress.completedUnitCount = Int64(max(0, min(snapshot.iteration, snapshot.total) - snapshot.startIteration))
        let percent = TrainingPresentation.percent(snapshot)
        if percent != reportedPercent {
            reportedPercent = percent
            task.updateTitle(L10n.text("訓練 3DGS"), subtitle: "\(percent)%・\(TrainingPresentation.stage(snapshot))")
        }
        switch snapshot.phase {
        case .completed, .failed, .cancelled: endContinuedProcessing(success: snapshot.phase == .completed)
        default: break
        }
    }

    /// The system ended the background time (or the user cancelled it from the system UI):
    /// pause with a checkpoint if the app is still in the background.
    private func continuedProcessingExpired() {
        if UIApplication.shared.applicationState != .active { session?.setBackgrounded(true) }
        endContinuedProcessing(success: false)
    }

    private func endContinuedProcessing(success: Bool) {
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask { task.setTaskCompleted(success: success) }
        continuedTask = nil
        continuesInBackground = false
    }
}
