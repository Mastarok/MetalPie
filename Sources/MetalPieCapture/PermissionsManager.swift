import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MetalPieCore
import ScreenCaptureKit
import os

/// Manages macOS Screen Recording and Accessibility TCC permission status checks,
/// explicit user-driven prompts, System Settings deep links, and live polling.
///
/// Key behavioral guarantees:
/// - **Never** blindly prompts for Accessibility on launch (unlike MetalDuck).
/// - Accessibility is only prompted when the user explicitly clicks Grant or enables
///   features that require a `CGEventTap` / `AXObserver` (scaled cursor confinement / auto-scale).
/// - Screen Recording preflight checks are non-intrusive by default (`CGPreflightScreenCaptureAccess`).
public final class PermissionsManager: Sendable {
    public static let shared = PermissionsManager()

    /// Deep-link URL to System Settings -> Privacy & Security -> Screen & System Audio Recording.
    public static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    /// Deep-link URL to System Settings -> Privacy & Security -> Accessibility.
    public static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    /// Raw option key string used instead of the non-Sendable C global `kAXTrustedCheckOptionPrompt`
    /// for Swift 6 strict concurrency compliance.
    private static let axTrustedCheckOptionPromptKey = "AXTrustedCheckOptionPrompt"

    private struct ObserverBox: @unchecked Sendable {
        let token: any NSObjectProtocol
    }

    private struct PollingState: Sendable {
        var timer: DispatchSourceTimer?
        var activeObserver: ObserverBox?
        var lastStatus: PermissionStatus?
        var stopWhenAllGranted: Bool = false
        var onChange: (@Sendable (PermissionStatus) -> Void)?
    }

    private let pollingState = OSAllocatedUnfairLock(initialState: PollingState())
    private let pollingQueue = DispatchQueue(
        label: "com.metalpie.permissions.poll",
        qos: .utility
    )

    public init() {}

    deinit {
        stopPolling()
    }

    // MARK: - Live Non-Intrusive Status Snapshot

    /// Returns a live, non-intrusive snapshot of Screen Recording and Accessibility grants.
    /// Never triggers any macOS system permission dialog.
    public func currentStatus() -> PermissionStatus {
        PermissionStatus(
            screenRecordingGranted: isScreenRecordingGranted(),
            accessibilityGranted: isAccessibilityGranted()
        )
    }

    /// Synchronous, non-prompting Screen Recording access check via `CGPreflightScreenCaptureAccess()`.
    public func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Synchronous, non-prompting Accessibility trust check via `AXIsProcessTrusted()`.
    public func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Optional ScreenCaptureKit verification that confirms `SCShareableContent` actually succeeds
    /// (catches stale TCC entries after ad-hoc rebuilds).
    ///
    /// - Parameter allowSystemPrompt: When `false` (default), returns `false` immediately if
    ///   `CGPreflightScreenCaptureAccess()` is `false` so ScreenCaptureKit never triggers an
    ///   unwanted system prompt.
    public func verifyScreenRecordingWithSCK(allowSystemPrompt: Bool = false) async -> Bool {
        if !allowSystemPrompt && !CGPreflightScreenCaptureAccess() {
            return false
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
            return !content.displays.isEmpty
        } catch {
            PipelineLog.shared.debug(
                .capture,
                "SCShareableContent verification failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    /// Returns an updated `PermissionStatus`, optionally verifying Screen Recording against `SCShareableContent`.
    public func verifiedStatus(verifyWithSCK: Bool = true) async -> PermissionStatus {
        let preflight = CGPreflightScreenCaptureAccess()
        let screenGranted: Bool
        if verifyWithSCK && preflight {
            screenGranted = await verifyScreenRecordingWithSCK(allowSystemPrompt: false)
        } else {
            screenGranted = preflight
        }
        return PermissionStatus(
            screenRecordingGranted: screenGranted,
            accessibilityGranted: AXIsProcessTrusted()
        )
    }

    // MARK: - Explicit User-Initiated Requests

    /// Explicitly requests Screen Recording permission via `CGRequestScreenCaptureAccess()`.
    /// Call only in response to explicit user intent (e.g. clicking Grant or starting capture).
    @discardableResult
    public func requestScreenRecordingAccess() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        PipelineLog.shared.info(
            .app,
            "Requested Screen Recording access (preflight granted=\(granted))."
        )
        notifyStatusCheckNow()
        return granted
    }

    /// Checks or prompts for Accessibility permission via `AXIsProcessTrustedWithOptions`.
    ///
    /// - Parameter prompt: Pass `true` ONLY when the user explicitly clicks Grant or enables
    ///   a feature requiring Accessibility (scaled cursor confinement, cursor speed adjustment,
    ///   or auto-scale window observation).
    @discardableResult
    public func requestAccessibilityAccess(prompt: Bool = true) -> Bool {
        let options: CFDictionary = [
            Self.axTrustedCheckOptionPromptKey: prompt
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        PipelineLog.shared.info(
            .app,
            "Accessibility trust check (prompt=\(prompt), trusted=\(trusted))."
        )
        notifyStatusCheckNow()
        return trusted
    }

    /// Returns `true` when the given profile configuration benefits from or requires Accessibility
    /// (scaled cursor confinement/remapping or automatic focus-based scaling).
    public static func requiresAccessibility(
        for profile: Profile,
        isOneToOneOverlay: Bool = false
    ) -> Bool {
        if profile.autoScaleMode != .disabled {
            return true
        }
        if !isOneToOneOverlay && (profile.cursor.confineCursor || profile.cursor.renderScaledCursor) {
            return true
        }
        return false
    }

    // MARK: - System Settings Deep Links

    /// Opens System Settings directly to Privacy & Security -> Screen Recording.
    @discardableResult
    public func openScreenRecordingSettings() -> Bool {
        openSystemSettings(url: Self.screenRecordingSettingsURL, label: "Screen Recording")
    }

    /// Opens System Settings directly to Privacy & Security -> Accessibility.
    @discardableResult
    public func openAccessibilitySettings() -> Bool {
        openSystemSettings(url: Self.accessibilitySettingsURL, label: "Accessibility")
    }

    private func openSystemSettings(url: URL, label: String) -> Bool {
        let opened = NSWorkspace.shared.open(url)
        if !opened {
            PipelineLog.shared.warning(.app, "Failed to open System Settings for \(label) (\(url.absoluteString)).")
        } else {
            PipelineLog.shared.info(.app, "Opened System Settings for \(label).")
        }
        return opened
    }

    // MARK: - Periodic Lightweight Polling

    /// Starts lightweight periodic polling (default 1.0 s) and also refreshes immediately whenever
    /// MetalPie regains focus from System Settings.
    ///
    /// - Parameters:
    ///   - intervalSeconds: Polling interval in seconds (clamped to `[0.25, 10.0]`).
    ///   - stopWhenAllGranted: Automatically stops polling once both permissions are granted.
    ///   - onChange: Invoked immediately with the initial snapshot and whenever status changes.
    public func startPolling(
        intervalSeconds: TimeInterval = 1.0,
        stopWhenAllGranted: Bool = false,
        onChange: @escaping @Sendable (PermissionStatus) -> Void
    ) {
        stopPolling()

        let clampedInterval = min(max(intervalSeconds, 0.25), 10.0)
        let initial = currentStatus()

        let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
        timer.schedule(
            deadline: .now() + clampedInterval,
            repeating: clampedInterval,
            leeway: .milliseconds(150)
        )
        timer.setEventHandler { [weak self] in
            self?.pollTick()
        }

        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.pollingQueue.async {
                strongSelf.pollTick()
            }
        }

        let shouldStopImmediately = stopWhenAllGranted
            && initial.screenRecordingGranted
            && initial.accessibilityGranted

        if shouldStopImmediately {
            NotificationCenter.default.removeObserver(observer)
            timer.cancel()
            onChange(initial)
            return
        }

        let observerBox = ObserverBox(token: observer)
        pollingState.withLock { state in
            state.timer = timer
            state.activeObserver = observerBox
            state.lastStatus = initial
            state.stopWhenAllGranted = stopWhenAllGranted
            state.onChange = onChange
        }

        onChange(initial)
        timer.resume()
    }

    /// Stops any active permission polling timer and focus observer.
    public func stopPolling() {
        let (timer, observer) = pollingState.withLock { state -> (DispatchSourceTimer?, ObserverBox?) in
            let t = state.timer
            let obs = state.activeObserver
            state.timer = nil
            state.activeObserver = nil
            state.onChange = nil
            state.lastStatus = nil
            return (t, obs)
        }
        timer?.cancel()
        if let observer {
            NotificationCenter.default.removeObserver(observer.token)
        }
    }

    /// Triggers an immediate status refresh for any active polling listener.
    public func notifyStatusCheckNow() {
        pollingQueue.async { [weak self] in
            self?.pollTick()
        }
    }

    private func pollTick() {
        let current = currentStatus()
        let (callbackToInvoke, shouldStop): ((@Sendable (PermissionStatus) -> Void)?, Bool) =
            pollingState.withLock { state in
                guard state.onChange != nil else { return (nil, false) }
                var callback: (@Sendable (PermissionStatus) -> Void)?
                if state.lastStatus != current {
                    state.lastStatus = current
                    callback = state.onChange
                }
                let done = state.stopWhenAllGranted
                    && current.screenRecordingGranted
                    && current.accessibilityGranted
                return (callback, done)
            }

        if let callbackToInvoke {
            callbackToInvoke(current)
        }
        if shouldStop {
            stopPolling()
        }
    }
}
