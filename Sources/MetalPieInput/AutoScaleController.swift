import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MetalPieCore
import os

/// Trigger payload emitted by `AutoScaleController` when a foreground window satisfies a profile's
/// auto-scale rules, readiness checks, and anti-retrigger safeguards.
public struct AutoScaleTrigger: Equatable, Sendable {
    public let window: WindowDescriptor
    public let profile: Profile
    public let presentationMode: PresentationMode

    public init(
        window: WindowDescriptor,
        profile: Profile,
        presentationMode: PresentationMode
    ) {
        self.window = window
        self.profile = profile
        self.presentationMode = presentationMode
    }
}

/// Deterministic evaluation verdict for an auto-scale candidate window (unit-testable & diagnostic-friendly).
public enum AutoScaleEvaluationResult: Equatable, Sendable {
    case eligible(AutoScaleTrigger)
    case ignoredExcludedBundle(String)
    case ignoredNotApplicationWindow
    case ignoredPopupOrTinyWindow(CGSize)
    case ignoredNotReady(String)
    case ignoredAlreadyScaling
    case ignoredOwnedPopupOfScaledApp(pid: Int32)
    case ignoredAntiRetriggerLocked(CGWindowID)
    case ignoredAutoScaleDisabled
}

/// Monitors frontmost application and active window changes to automatically initiate scaling according to
/// user `Profile` rules while enforcing all Magpie auto-scale safeguards.
///
/// Safeguards enforced:
/// 1. **Forbidden system window blacklist** (`AppConfig.autoScaleExcludedBundleIDs` + own process exclusion).
/// 2. **Popup / modal / sheet / tiny-window exemption** (ignores `< 200×150` windows, AX dialogs/sheets/popovers,
///    and owned popups of an already-scaled process).
/// 3. **Readiness check** (must be onscreen, non-minimized, still frontmost after `profile.autoScaleDelaySeconds`,
///    and have a stable window size without ongoing startup resize).
/// 4. **Anti-retrigger lock**: manually stopping scaling on a `CGWindowID` suppresses auto-scale for that window
///    until the user switches away to another non-MetalPie window and returns (or resets explicitly).
public final class AutoScaleController: @unchecked Sendable {
    public static let defaultMinimumWindowSize = CGSize(width: 200, height: 150)

    private static let modalOrPopupRoles: Set<String> = [
        "AXSheet",
        "AXPopover",
        "AXHelpTag",
        "AXMenu",
        "AXDrawer"
    ]

    private static let modalOrPopupSubroles: Set<String> = [
        "AXDialog",
        "AXSystemDialog",
        "AXFloatingWindow",
        "AXSystemFloatingWindow",
        "AXUnknown"
    ]

    private struct PendingCandidate {
        let windowID: CGWindowID
        let initialBounds: CGRect
        let profileID: UUID
        let trigger: AutoScaleTrigger
        let didRetryStability: Bool
    }

    private struct ControllerState {
        var isRunning: Bool = false
        var config: AppConfig
        var onTrigger: (@Sendable (AutoScaleTrigger) -> Void)?
        var currentlyScaledWindowID: CGWindowID?
        var currentlyScaledPID: Int32?
        var suppressedWindowID: CGWindowID?
        var pendingCandidate: PendingCandidate?
        var debounceTimer: (any DispatchSourceTimer)?
        var workspaceObserver: (any NSObjectProtocol)?
    }

    public let minimumWindowSize: CGSize
    public let stabilityTolerancePoints: CGFloat
    public let stabilityRetryDelaySeconds: TimeInterval

    private let queue = DispatchQueue(
        label: "com.metalpie.input.auto-scale",
        qos: .userInitiated
    )
    private let state: OSAllocatedUnfairLock<ControllerState>
    private let windowTracker: any WindowTracking
    private let ownsWindowTracker: Bool

    public init(
        config: AppConfig = .defaultConfig,
        windowTracker: (any WindowTracking)? = nil,
        minimumWindowSize: CGSize = AutoScaleController.defaultMinimumWindowSize,
        stabilityTolerancePoints: CGFloat = 2.0,
        stabilityRetryDelaySeconds: TimeInterval = 0.2
    ) {
        self.minimumWindowSize = CGSize(
            width: max(64, minimumWindowSize.width),
            height: max(64, minimumWindowSize.height)
        )
        self.stabilityTolerancePoints = max(0.5, stabilityTolerancePoints)
        self.stabilityRetryDelaySeconds = max(0.05, stabilityRetryDelaySeconds)
        if let tracker = windowTracker {
            self.windowTracker = tracker
            self.ownsWindowTracker = false
        } else {
            self.windowTracker = WindowLifecycleWatcher(
                excludedBundleIDs: config.autoScaleExcludedBundleIDs
            )
            self.ownsWindowTracker = true
        }
        self.state = OSAllocatedUnfairLock(uncheckedState: ControllerState(config: config))
    }

    deinit {
        stop()
    }

    // MARK: - Inspection

    public var isRunning: Bool {
        state.withLockUnchecked { $0.isRunning }
    }

    /// Currently anti-retrigger-suppressed `CGWindowID`, if the user manually stopped scaling on it.
    public var suppressedWindowID: CGWindowID? {
        state.withLockUnchecked { $0.suppressedWindowID }
    }

    /// True if at least one profile in the current `AppConfig` enables auto-scaling.
    public var hasAnyAutoScaleProfileEnabled: Bool {
        state.withLockUnchecked { s in
            s.config.profiles.contains { $0.autoScaleMode != .disabled }
        }
    }

    // MARK: - Lifecycle

    /// Begins monitoring frontmost app/window focus changes and triggering auto-scale after each profile's delay.
    public func start(onTrigger: @escaping @Sendable (AutoScaleTrigger) -> Void) {
        stop()

        state.withLockUnchecked { s in
            s.isRunning = true
            s.onTrigger = onTrigger
        }

        let wsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.evaluateCurrentFrontmostWindow()
            }
        }
        state.withLockUnchecked { $0.workspaceObserver = wsObserver }

        if ownsWindowTracker {
            windowTracker.startObserving(trackedWindowID: nil) { [weak self] event in
                if case .activeWindowChanged(let window) = event {
                    self?.handleActiveWindowChanged(window)
                }
            }
        }

        queue.async { [weak self] in
            self?.evaluateCurrentFrontmostWindow()
        }

        PipelineLog.shared.info(.profile, "AutoScaleController started.")
    }

    /// Stops monitoring and cancels any pending debounce timer.
    public func stop() {
        let cleanup = state.withLockUnchecked { s -> (wasRunning: Bool, timer: (any DispatchSourceTimer)?, observer: (any NSObjectProtocol)?) in
            let was = s.isRunning
            let timer = s.debounceTimer
            let obs = s.workspaceObserver
            s.isRunning = false
            s.onTrigger = nil
            s.pendingCandidate = nil
            s.debounceTimer = nil
            s.workspaceObserver = nil
            return (was, timer, obs)
        }

        cleanup.timer?.cancel()
        if let obs = cleanup.observer {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if ownsWindowTracker {
            windowTracker.stopObserving()
        }

        if cleanup.wasRunning {
            PipelineLog.shared.info(.profile, "AutoScaleController stopped.")
        }
    }

    /// Updates the active `AppConfig` (profiles, auto-scale modes, delays, exclusion list).
    public func updateConfig(_ config: AppConfig) {
        let shouldReevaluate = state.withLockUnchecked { s -> Bool in
            s.config = config
            let anyEnabled = config.profiles.contains { $0.autoScaleMode != .disabled }
            if !anyEnabled {
                s.debounceTimer?.cancel()
                s.debounceTimer = nil
                s.pendingCandidate = nil
            }
            return s.isRunning && anyEnabled
        }

        if let watcher = windowTracker as? WindowLifecycleWatcher {
            watcher.updateExcludedBundleIDs(config.autoScaleExcludedBundleIDs)
        }

        if shouldReevaluate {
            queue.async { [weak self] in
                self?.evaluateCurrentFrontmostWindow()
            }
        }
    }

    /// Notifies `AutoScaleController` of the currently active scaling session window (or `nil` when idle).
    public func setCurrentlyScaling(window: WindowDescriptor?) {
        state.withLockUnchecked { s in
            s.currentlyScaledWindowID = window?.windowID
            s.currentlyScaledPID = window?.pid
            if window != nil {
                s.debounceTimer?.cancel()
                s.debounceTimer = nil
                s.pendingCandidate = nil
            }
        }
    }

    /// Engages the Magpie anti-retrigger lock after the user manually stops scaling on `windowID`
    /// (via Stop button or global hotkey). Auto-scale will NOT retrigger on `windowID` until the user
    /// switches focus to a different non-MetalPie window and comes back (or calls `resetAntiRetriggerLock()`).
    public func notifyManualStop(windowID: CGWindowID) {
        state.withLockUnchecked { s in
            s.suppressedWindowID = windowID
            if s.currentlyScaledWindowID == windowID {
                s.currentlyScaledWindowID = nil
                s.currentlyScaledPID = nil
            }
            if s.pendingCandidate?.windowID == windowID {
                s.debounceTimer?.cancel()
                s.debounceTimer = nil
                s.pendingCandidate = nil
            }
        }
        PipelineLog.shared.info(.profile, "Auto-scale anti-retrigger lock engaged for window \(windowID).")
    }

    /// Clears the anti-retrigger lock manually.
    public func resetAntiRetriggerLock() {
        state.withLockUnchecked { $0.suppressedWindowID = nil }
    }

    // MARK: - Pure Candidate Evaluation (Unit-Testable)

    /// Evaluates whether `window` is eligible to auto-scale under the current config and safeguards.
    public func evaluateCandidate(
        _ window: WindowDescriptor,
        isModalOrPopup: Bool = false
    ) -> AutoScaleEvaluationResult {
        let snapshot = state.withLockUnchecked { s in
            (
                config: s.config,
                scaledWindowID: s.currentlyScaledWindowID,
                scaledPID: s.currentlyScaledPID,
                suppressedWindowID: s.suppressedWindowID
            )
        }

        // 1. Currently scaling / owned-popup exemption.
        if let activeID = snapshot.scaledWindowID {
            if activeID == window.windowID {
                return .ignoredAlreadyScaling
            }
            if let scaledPID = snapshot.scaledPID, scaledPID == window.pid {
                return .ignoredOwnedPopupOfScaledApp(pid: scaledPID)
            }
            return .ignoredAlreadyScaling
        }

        // 2. Forbidden system window / MetalPie blacklist.
        if window.pid == ProcessInfo.processInfo.processIdentifier {
            return .ignoredNotApplicationWindow
        }
        if window.ownerCategory != .application {
            return .ignoredNotApplicationWindow
        }
        if let bundleID = window.bundleIdentifier,
           snapshot.config.isExcludedFromAutoScale(bundleIdentifier: bundleID)
        {
            return .ignoredExcludedBundle(bundleID)
        }

        // 3. Anti-retrigger lock after manual stop.
        if snapshot.suppressedWindowID == window.windowID {
            return .ignoredAntiRetriggerLocked(window.windowID)
        }

        // 4. Readiness check (must be onscreen and not minimized).
        if window.isMinimized || !window.isOnScreen {
            return .ignoredNotReady("Window is minimized or off-screen")
        }

        // 5. Popup / modal / sheet / tiny-window exemption (< 200x150).
        if isModalOrPopup ||
            window.cgBounds.width < minimumWindowSize.width ||
            window.cgBounds.height < minimumWindowSize.height
        {
            return .ignoredPopupOrTinyWindow(window.cgBounds.size)
        }

        // 6. Profile match + auto-scale mode check.
        let profile = ProfileMatcher.match(window: window, profiles: snapshot.config.profiles)
        let presentation: PresentationMode
        switch profile.autoScaleMode {
        case .disabled:
            return .ignoredAutoScaleDisabled
        case .fullscreen:
            presentation = .fullscreen
        case .windowed:
            if case .windowed(let initialScale, let width) = profile.presentationMode {
                presentation = .windowed(initialScale: initialScale, width: width)
            } else {
                presentation = .windowed()
            }
        }

        return .eligible(AutoScaleTrigger(
            window: window,
            profile: profile,
            presentationMode: presentation
        ))
    }

    // MARK: - Active Window Transitions & Debounce Pipeline

    /// Feeds an active frontmost window change directly into `AutoScaleController`
    /// (called automatically by `WindowTracking` / `NSWorkspace`, and directly callable in tests).
    public func handleActiveWindowChanged(_ window: WindowDescriptor?) {
        queue.async { [weak self] in
            self?.processActiveWindow(window)
        }
    }

    private func evaluateCurrentFrontmostWindow() {
        guard state.withLockUnchecked({ $0.isRunning }) else { return }
        // Fast path: skip immediately if no profile enables auto-scale.
        guard hasAnyAutoScaleProfileEnabled else { return }

        let front = windowTracker.activeFrontmostWindow()
        processActiveWindow(front)
    }

    private func processActiveWindow(_ window: WindowDescriptor?) {
        let isRunning = state.withLockUnchecked { $0.isRunning }
        guard isRunning else { return }

        // Unlock anti-retrigger lock as soon as the user switches away to any other non-MetalPie window
        // (ignoring MetalPie's own windows so clicking Stop in MetalPie's main window doesn't unlock immediately).
        if let window {
            if window.ownerCategory != .metalPie && window.pid != ProcessInfo.processInfo.processIdentifier {
                state.withLockUnchecked { s in
                    if let suppressed = s.suppressedWindowID, suppressed != window.windowID {
                        s.suppressedWindowID = nil
                    }
                }
            }
        } else {
            // Switched to desktop / no capturable window -> clear anti-retrigger lock.
            state.withLockUnchecked { $0.suppressedWindowID = nil }
            cancelPendingCandidate()
            return
        }

        guard let window else { return }

        // Fast path: if no profile enables auto-scale, skip AX queries and timers completely.
        guard hasAnyAutoScaleProfileEnabled else {
            cancelPendingCandidate()
            return
        }

        let isModal = Self.isFocusedWindowModalOrPopup(pid: window.pid)
        let verdict = evaluateCandidate(window, isModalOrPopup: isModal)

        switch verdict {
        case .eligible(let trigger):
            scheduleDebouncedTrigger(trigger, didRetryStability: false)

        case .ignoredAntiRetriggerLocked(let wid):
            PipelineLog.shared.debug(.profile, "Auto-scale suppressed for window \(wid) (anti-retrigger lock active).")
            cancelPendingCandidate()

        case .ignoredExcludedBundle, .ignoredNotApplicationWindow, .ignoredPopupOrTinyWindow,
             .ignoredNotReady, .ignoredAlreadyScaling, .ignoredOwnedPopupOfScaledApp,
             .ignoredAutoScaleDisabled:
            cancelPendingCandidate()
        }
    }

    private func scheduleDebouncedTrigger(
        _ trigger: AutoScaleTrigger,
        didRetryStability: Bool
    ) {
        let delay = didRetryStability
            ? stabilityRetryDelaySeconds
            : max(0.0, trigger.profile.autoScaleDelaySeconds)

        let candidate = PendingCandidate(
            windowID: trigger.window.windowID,
            initialBounds: trigger.window.cgBounds,
            profileID: trigger.profile.id,
            trigger: trigger,
            didRetryStability: didRetryStability
        )

        let existingSame = state.withLockUnchecked { s -> Bool in
            if !didRetryStability,
               let pending = s.pendingCandidate,
               pending.windowID == candidate.windowID,
               pending.profileID == candidate.profileID
            {
                return true
            }
            s.debounceTimer?.cancel()
            s.debounceTimer = nil
            s.pendingCandidate = candidate
            return false
        }
        guard !existingSame else { return }

        if delay <= 0.001 && !didRetryStability {
            confirmAndFire(candidate: candidate)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let delayMs = max(1, Int((delay * 1000.0).rounded()))
        timer.schedule(deadline: .now() + .milliseconds(delayMs), repeating: .never, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.confirmAndFire(candidate: candidate)
        }

        state.withLockUnchecked { s in
            s.debounceTimer = timer
        }
        timer.resume()
    }

    private func confirmAndFire(candidate: PendingCandidate) {
        let pendingCheck = state.withLockUnchecked { s -> (isValid: Bool, onTrigger: (@Sendable (AutoScaleTrigger) -> Void)?) in
            guard s.isRunning,
                  let current = s.pendingCandidate,
                  current.windowID == candidate.windowID
            else {
                return (false, nil)
            }
            s.debounceTimer?.cancel()
            s.debounceTimer = nil
            s.pendingCandidate = nil
            return (true, s.onTrigger)
        }
        guard pendingCheck.isValid else { return }

        // Readiness & stability verification at fire time: re-query current frontmost window.
        guard let currentFront = windowTracker.activeFrontmostWindow(),
              currentFront.windowID == candidate.windowID
        else {
            PipelineLog.shared.debug(.profile, "Auto-scale cancelled: window \(candidate.windowID) is no longer frontmost.")
            return
        }

        // Check window size stability (if app is still mid-resize during launch, wait one stability interval).
        let widthDelta = abs(currentFront.cgBounds.width - candidate.initialBounds.width)
        let heightDelta = abs(currentFront.cgBounds.height - candidate.initialBounds.height)
        if (widthDelta > stabilityTolerancePoints || heightDelta > stabilityTolerancePoints) && !candidate.didRetryStability {
            let refreshedTrigger = AutoScaleTrigger(
                window: currentFront,
                profile: candidate.trigger.profile,
                presentationMode: candidate.trigger.presentationMode
            )
            PipelineLog.shared.debug(.profile, "Auto-scale delaying window \(candidate.windowID): size still stabilizing.")
            scheduleDebouncedTrigger(refreshedTrigger, didRetryStability: true)
            return
        }

        let isModal = Self.isFocusedWindowModalOrPopup(pid: currentFront.pid)
        guard case .eligible(let verifiedTrigger) = evaluateCandidate(currentFront, isModalOrPopup: isModal) else {
            return
        }

        PipelineLog.shared.info(
            .profile,
            "Auto-scale triggered for '\(verifiedTrigger.window.displayName)' using profile '\(verifiedTrigger.profile.name)' (\(verifiedTrigger.presentationMode.isFullscreen ? "fullscreen" : "windowed"))."
        )
        pendingCheck.onTrigger?(verifiedTrigger)
    }

    private func cancelPendingCandidate() {
        let timer = state.withLockUnchecked { s -> (any DispatchSourceTimer)? in
            let existing = s.debounceTimer
            s.debounceTimer = nil
            s.pendingCandidate = nil
            return existing
        }
        timer?.cancel()
    }

    // MARK: - Optional AX Role/Subrole Check for Modals/Sheets/Dialogs

    /// Uses Accessibility (only when already granted, never prompting) to detect modal sheets, dialogs,
    /// popovers, and floating utility panels so Auto-Scale exempts them cleanly.
    private static func isFocusedWindowModalOrPopup(pid: Int32) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXFocusedWindow" as CFString, &focusedObj) == .success,
              let focusedObj
        else {
            return false
        }

        // `AXFocusedWindow` returns an `AXUIElement` when status == `.success`.
        guard CFGetTypeID(focusedObj) == AXUIElementGetTypeID() else {
            return false
        }
        let windowElement = unsafeDowncast(focusedObj as AnyObject, to: AXUIElement.self)

        var roleObj: CFTypeRef?
        if AXUIElementCopyAttributeValue(windowElement, "AXRole" as CFString, &roleObj) == .success,
           let role = roleObj as? String,
           modalOrPopupRoles.contains(role)
        {
            return true
        }

        var subroleObj: CFTypeRef?
        if AXUIElementCopyAttributeValue(windowElement, "AXSubrole" as CFString, &subroleObj) == .success,
           let subrole = subroleObj as? String,
           modalOrPopupSubroles.contains(subrole)
        {
            return true
        }

        return false
    }
}
