import AppKit
import CoreGraphics
import Darwin
import Foundation
import MetalPieCore
import os

/// Background main-thread stall watchdog and process-exit cursor safety guard.
///
/// Design highlights:
/// - Schedules its main-thread heartbeat on `CFRunLoopGetMain()` in `.commonModes` so open `NSMenu`s,
///   window drags, and modal tracking loops NEVER trigger false stalls.
/// - Monitors monotonic `ProcessInfo.processInfo.systemUptime` from a dedicated background `Thread`
///   (independent of libdispatch worker pools and MainActor), immune to wall-clock jumps and system sleep.
/// - If the main thread stalls longer than `stallThresholdSeconds` (default `8.0s`) while scaling is active,
///   unconditionally restores the macOS hardware cursor (`CGDisplayShowCursor`), executes all registered
///   emergency recovery handlers (disabling event taps, hiding overlay panels), and logs a fatal stall
///   to `PipelineLog.shared`.
/// - Installs `atexit` and async-signal-safe GCD `SIGTERM` / `SIGINT` hooks so killing or quitting the
///   process from Terminal always restores cursor visibility cleanly before exiting.
public final class RunGuardWatchdog: @unchecked Sendable {
    public static let shared = RunGuardWatchdog()

    /// Opaque handle returned when registering an emergency recovery closure.
    public struct RecoveryToken: Hashable, Sendable {
        public let id: UUID
        public init(id: UUID = UUID()) {
            self.id = id
        }
    }

    private struct RecoveryEntry: Sendable {
        let token: RecoveryToken
        let name: String
        let handler: @Sendable () -> Void
    }

    private struct WatchdogState {
        var isRunning: Bool = false
        var isScalingActive: Bool = false
        var lastHeartbeatUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        var hasTrippedCurrentStall: Bool = false
        var stallCount: Int = 0
        var recoveryHandlers: [RecoveryEntry] = []
        var onStallDetected: (@Sendable (TimeInterval) -> Void)?
        var terminateProcessOnStall: Bool
        var mainTimer: CFRunLoopTimer?
        var monitorThread: Thread?
        var wakeObserver: (any NSObjectProtocol)?
    }

    public let stallThresholdSeconds: TimeInterval
    public let heartbeatIntervalSeconds: TimeInterval
    public let checkIntervalSeconds: TimeInterval

    private let state: OSAllocatedUnfairLock<WatchdogState>
    private let wakeupCondition = NSCondition()

    // Process-wide exit/signal hook coordination (installed at most once).
    private struct ProcessHookState {
        var atExitInstalled: Bool = false
        var signalsInstalled: Bool = false
        var sigTermSource: (any DispatchSourceSignal)?
        var sigIntSource: (any DispatchSourceSignal)?
        var exitCleanupExecuted: Bool = false
    }
    private static let processHookLock = OSAllocatedUnfairLock(uncheckedState: ProcessHookState())
    private static let signalQueue = DispatchQueue(
        label: "com.metalpie.input.runguard.signals",
        qos: .userInteractive
    )

    public init(
        stallThresholdSeconds: TimeInterval = 8.0,
        heartbeatIntervalSeconds: TimeInterval = 1.0,
        checkIntervalSeconds: TimeInterval = 0.5,
        terminateProcessOnStall: Bool = false
    ) {
        self.stallThresholdSeconds = max(0.05, stallThresholdSeconds)
        self.heartbeatIntervalSeconds = max(0.02, heartbeatIntervalSeconds)
        self.checkIntervalSeconds = max(0.02, checkIntervalSeconds)
        self.state = OSAllocatedUnfairLock(
            uncheckedState: WatchdogState(terminateProcessOnStall: terminateProcessOnStall)
        )
    }

    deinit {
        stop()
    }

    // MARK: - Status Inspection

    public var isRunning: Bool {
        state.withLockUnchecked { $0.isRunning }
    }

    public var isScalingActive: Bool {
        state.withLockUnchecked { $0.isScalingActive }
    }

    public var stallCount: Int {
        state.withLockUnchecked { $0.stallCount }
    }

    public var lastHeartbeatAgeSeconds: TimeInterval {
        let last = state.withLockUnchecked { $0.lastHeartbeatUptime }
        return max(0, ProcessInfo.processInfo.systemUptime - last)
    }

    public var terminateProcessOnStall: Bool {
        get { state.withLockUnchecked { $0.terminateProcessOnStall } }
        set { state.withLockUnchecked { $0.terminateProcessOnStall = newValue } }
    }

    // MARK: - Lifecycle

    /// Starts the main-thread `.commonModes` heartbeat timer and background watchdog monitor thread.
    /// Automatically installs process exit hooks for the shared singleton.
    public func start(onStallDetected: (@Sendable (TimeInterval) -> Void)? = nil) {
        let shouldLaunch = state.withLockUnchecked { s -> Bool in
            if let onStallDetected {
                s.onStallDetected = onStallDetected
            }
            guard !s.isRunning else { return false }
            s.isRunning = true
            s.lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
            s.hasTrippedCurrentStall = false
            return true
        }

        guard shouldLaunch else { return }

        if self === Self.shared {
            installProcessExitHooks(interceptTerminationSignals: true)
        }

        installMainRunLoopHeartbeatTimer()
        installWakeNotificationObserver()
        launchMonitorThread()

        PipelineLog.shared.info(
            .app,
            "RunGuardWatchdog started (threshold: \(String(format: "%.1fs", stallThresholdSeconds)))."
        )
    }

    /// Stops monitoring and cleans up the main-thread heartbeat timer and monitor thread.
    public func stop() {
        let cleanup: (CFRunLoopTimer?, (any NSObjectProtocol)?) = state.withLockUnchecked { s in
            guard s.isRunning else { return (nil, nil) }
            s.isRunning = false
            s.isScalingActive = false
            let timer = s.mainTimer
            s.mainTimer = nil
            let observer = s.wakeObserver
            s.wakeObserver = nil
            s.monitorThread = nil
            return (timer, observer)
        }

        if let timer = cleanup.0 {
            CFRunLoopTimerInvalidate(timer)
            CFRunLoopRemoveTimer(CFRunLoopGetMain(), timer, .commonModes)
        }

        if let observer = cleanup.1 {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }

        wakeupCondition.lock()
        wakeupCondition.broadcast()
        wakeupCondition.unlock()
    }

    /// Marks whether a scaling session is currently active. Watchdog stall recovery only fires while active.
    public func setScalingActive(_ active: Bool) {
        state.withLockUnchecked { s in
            s.isScalingActive = active
            if active {
                s.lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
                s.hasTrippedCurrentStall = false
            }
        }

        if active && self === Self.shared {
            installProcessExitHooks(interceptTerminationSignals: true)
        }

        wakeupCondition.lock()
        wakeupCondition.broadcast()
        wakeupCondition.unlock()
    }

    /// Records a main-thread heartbeat timestamp (invoked automatically by the `.commonModes` timer).
    public func recordHeartbeat() {
        state.withLockUnchecked { s in
            s.lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
            s.hasTrippedCurrentStall = false
        }
    }

    // MARK: - Emergency Recovery Registration

    /// Registers an emergency cleanup handler executed off the main thread on stall, panic stop, or process exit.
    @discardableResult
    public func registerRecoveryHandler(
        name: String,
        handler: @escaping @Sendable () -> Void
    ) -> RecoveryToken {
        let token = RecoveryToken()
        state.withLockUnchecked { s in
            s.recoveryHandlers.append(RecoveryEntry(token: token, name: name, handler: handler))
        }
        return token
    }

    /// Removes a previously registered emergency recovery handler.
    public func unregisterRecoveryHandler(_ token: RecoveryToken) {
        state.withLockUnchecked { s in
            s.recoveryHandlers.removeAll { $0.token == token }
        }
    }

    /// Immediately executes built-in cursor restoration and all registered emergency recovery handlers.
    public func triggerEmergencyRecovery(reason: String) {
        PipelineLog.shared.error(.app, "RunGuardWatchdog emergency recovery triggered: \(reason)")

        // Always restore the OS cursor first before invoking downstream callbacks.
        Self.forceRestoreSystemCursor()

        let entries = state.withLockUnchecked { $0.recoveryHandlers }
        for entry in entries {
            PipelineLog.shared.warning(.app, "RunGuardWatchdog running recovery handler '\(entry.name)'.")
            entry.handler()
        }

        // Belt-and-suspenders: ensure cursor remains visible after handlers finish.
        Self.forceRestoreSystemCursor()
    }

    /// Unconditionally restores system cursor visibility.
    /// First unwinds every balanced hide acquired by `SystemCursorHider`, then queries `CGCursorIsVisible`
    /// dynamically (when available) as a belt-and-suspenders guard. Safe from background threads & exit hooks.
    public static func forceRestoreSystemCursor() {
        SystemCursorHider.emergencyRestoreAll()
    }

    // MARK: - Process Exit & Signal Cleanup Hooks

    /// Installs `atexit`, `SIGTERM`, and `SIGINT` cleanup hooks so killing MetalPie restores the macOS cursor.
    /// Safe to call multiple times (idempotent).
    public func installProcessExitHooks(interceptTerminationSignals: Bool = true) {
        let needsAtExit = Self.processHookLock.withLockUnchecked { hook -> Bool in
            guard !hook.atExitInstalled else { return false }
            hook.atExitInstalled = true
            return true
        }

        if needsAtExit {
            atexit {
                RunGuardWatchdog.executeProcessExitCleanup(reason: "atexit")
            }
        }

        guard interceptTerminationSignals else { return }

        let needsSignals = Self.processHookLock.withLockUnchecked { hook -> Bool in
            guard !hook.signalsInstalled else { return false }
            hook.signalsInstalled = true
            return true
        }

        if needsSignals {
            let termSource = installSignalSource(for: SIGTERM, name: "SIGTERM")
            let intSource = installSignalSource(for: SIGINT, name: "SIGINT")
            Self.processHookLock.withLockUnchecked { hook in
                hook.sigTermSource = termSource
                hook.sigIntSource = intSource
            }
        }
    }

    private func installSignalSource(for sig: Int32, name: String) -> any DispatchSourceSignal {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: Self.signalQueue)
        source.setEventHandler {
            RunGuardWatchdog.executeProcessExitCleanup(reason: name)
            signal(sig, SIG_DFL)
            raise(sig)
        }
        source.resume()
        return source
    }

    private static func executeProcessExitCleanup(reason: String) {
        let shouldRun = processHookLock.withLockUnchecked { hook -> Bool in
            guard !hook.exitCleanupExecuted else { return false }
            hook.exitCleanupExecuted = true
            return true
        }
        guard shouldRun else { return }

        forceRestoreSystemCursor()
        let handlers = RunGuardWatchdog.shared.state.withLockUnchecked { $0.recoveryHandlers }
        for entry in handlers {
            entry.handler()
        }
        forceRestoreSystemCursor()
        PipelineLog.shared.info(.app, "RunGuardWatchdog completed exit cleanup (\(reason)).")
    }

    // MARK: - Internal Monitoring Plumbing

    private func installMainRunLoopHeartbeatTimer() {
        let interval = heartbeatIntervalSeconds
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + interval,
            interval,
            0,
            0
        ) { [weak self] _ in
            self?.recordHeartbeat()
        }

        guard let timer else { return }

        let stored = state.withLockUnchecked { s -> Bool in
            guard s.isRunning else { return false }
            s.mainTimer = timer
            return true
        }

        if stored {
            CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        } else {
            CFRunLoopTimerInvalidate(timer)
        }
    }

    private func installWakeNotificationObserver() {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.recordHeartbeat()
        }

        let keep = state.withLockUnchecked { s -> Bool in
            guard s.isRunning else { return false }
            s.wakeObserver = observer
            return true
        }

        if !keep {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func launchMonitorThread() {
        let thread = Thread { [weak self] in
            self?.monitorLoop()
        }
        thread.name = "com.metalpie.input.watchdog"
        thread.qualityOfService = .utility

        state.withLockUnchecked { s in
            s.monitorThread = thread
        }
        thread.start()
    }

    private func monitorLoop() {
        while true {
            let snapshot = state.withLockUnchecked { s in
                (
                    isRunning: s.isRunning,
                    isScalingActive: s.isScalingActive,
                    lastHeartbeat: s.lastHeartbeatUptime,
                    hasTripped: s.hasTrippedCurrentStall,
                    terminate: s.terminateProcessOnStall,
                    onStall: s.onStallDetected
                )
            }

            guard snapshot.isRunning else { break }

            if snapshot.isScalingActive {
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - snapshot.lastHeartbeat)
                if elapsed > stallThresholdSeconds && !snapshot.hasTripped {
                    let shouldTrigger = state.withLockUnchecked { s -> Bool in
                        guard s.isRunning, s.isScalingActive, !s.hasTrippedCurrentStall else {
                            return false
                        }
                        s.hasTrippedCurrentStall = true
                        s.stallCount += 1
                        return true
                    }

                    if shouldTrigger {
                        triggerEmergencyRecovery(
                            reason: "Main thread stalled for \(String(format: "%.2fs", elapsed)) (threshold \(String(format: "%.2fs", stallThresholdSeconds)))"
                        )
                        snapshot.onStall?(elapsed)

                        if snapshot.terminate {
                            // Give recovery side effects a brief window, then hard-exit to avoid deadlocking on main-thread locks.
                            usleep(150_000)
                            Self.forceRestoreSystemCursor()
                            _exit(0)
                        }
                    }
                }

                wakeupCondition.lock()
                _ = wakeupCondition.wait(until: Date().addingTimeInterval(checkIntervalSeconds))
                wakeupCondition.unlock()
            } else {
                // Zero-CPU idle sleep until scaling becomes active or watchdog stops.
                wakeupCondition.lock()
                let stillIdle = state.withLockUnchecked { $0.isRunning && !$0.isScalingActive }
                if stillIdle {
                    wakeupCondition.wait()
                }
                wakeupCondition.unlock()
            }
        }
    }
}
