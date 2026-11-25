import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import MetalPieCore
import os

// MARK: - Rich Lifecycle Types & Pure Snapshots

/// Richer window & display lifecycle events emitted alongside `MetalPieCore.WindowLifecycleEvent`.
public enum DetailedWindowLifecycleEvent: Sendable {
    case activeWindowChanged(WindowDescriptor?)
    case targetLostFocus(CGWindowID)
    case targetGainedFocus(WindowDescriptor)
    case targetClosed(CGWindowID)
    case targetMinimized(CGWindowID)
    case targetRestored(WindowDescriptor)
    case targetFrameChanged(window: WindowDescriptor, newBounds: CGRect, display: DisplayDescriptor?)
    case foreignWindowOverlapped(trackedWindowID: CGWindowID, overlappingWindow: WindowDescriptor, overlapRect: CGRect)
    case activeSpaceChanged
    case screenParametersChanged([DisplayDescriptor])
}

/// Tracks Magpie's Auto-Reposition Wait state when the target window minimizes or moves off-screen.
public enum AutoRepositionWaitState: Hashable, Sendable {
    case inactive
    case tracking(CGWindowID)
    case waitingForRestore(CGWindowID, since: Date)
}

/// Pure representation of a CoreGraphics window dictionary entry, enabling deterministic unit tests.
public struct RawWindowSnapshot: Hashable, Sendable {
    public var windowID: CGWindowID
    public var pid: Int32
    public var ownerName: String
    public var bundleIdentifier: String?
    public var appPath: String?
    public var title: String
    public var cgBounds: CGRect
    public var layer: Int
    public var alpha: Double
    public var isOnScreen: Bool

    public init(
        windowID: CGWindowID,
        pid: Int32,
        ownerName: String,
        bundleIdentifier: String? = nil,
        appPath: String? = nil,
        title: String = "",
        cgBounds: CGRect,
        layer: Int = 0,
        alpha: Double = 1.0,
        isOnScreen: Bool = true
    ) {
        self.windowID = windowID
        self.pid = pid
        self.ownerName = ownerName
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.title = title
        self.cgBounds = cgBounds.standardized
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(pid)
        hasher.combine(ownerName)
        hasher.combine(bundleIdentifier)
        hasher.combine(appPath)
        hasher.combine(title)
        hasher.combine(cgBounds.origin.x)
        hasher.combine(cgBounds.origin.y)
        hasher.combine(cgBounds.size.width)
        hasher.combine(cgBounds.size.height)
        hasher.combine(layer)
        hasher.combine(alpha)
        hasher.combine(isOnScreen)
    }
}

// MARK: - Memory-Safe AXObserver Callback Box

private final class AXObserverCallbackBox: @unchecked Sendable {
    /// Concrete struct wrapper prevents Swift's generic `inout` closure reabstraction
    /// writeback bug in `OSAllocatedUnfairLock<Closure?>`.
    private struct CallbackState: Sendable {
        var handler: (@Sendable (String) -> Void)?
    }

    private let state: OSAllocatedUnfairLock<CallbackState>

    init(handler: @escaping @Sendable (String) -> Void) {
        self.state = OSAllocatedUnfairLock(initialState: CallbackState(handler: handler))
    }

    func invalidate() {
        state.withLock { $0.handler = nil }
    }

    func notify(_ notificationName: String) {
        let cb = state.withLock(\.handler)
        cb?(notificationName)
    }
}

// MARK: - WindowLifecycleWatcher (WindowTracking)

/// Observes macOS workspace, space, screen, and tracked-window lifecycle transitions without blocking MainActor.
///
/// Highlights:
/// - Observes `NSWorkspace.didActivateApplicationNotification`, `didHideApplicationNotification`,
///   `didTerminateApplicationNotification`, `activeSpaceDidChangeNotification`, and
///   `NSApplication.didChangeScreenParametersNotification`.
/// - Polls lightweight single-window `CGWindowListCopyWindowInfo(.optionIncludingWindow, trackedID)` at ~25 Hz
///   on a background serial queue (zero MainActor IPC stalls) + optional `AXObserver` when Accessibility is granted.
/// - Immediately emits focus loss on Cmd+Tab / app hide (fixing MetalDuck's stuck overlay bug).
/// - Explicitly detects `windowInfo == nil` as target-closed (fixing MetalGoose's orphan overlay bug!).
/// - Supports Magpie's Auto-Reposition Wait when a window minimizes or switches Spaces, auto-resuming on restore.
/// - Supports 3D Game Mode foreign window overlap detection (`>= 8pt` overlap by a non-popup foreign window).
/// - Shares system window blacklist and Wine/CrossOver raised-layer borderless fullscreen detection.
public final class WindowLifecycleWatcher: WindowTracking, @unchecked Sendable {
    /// Known macOS system owner process names excluded from capturable/auto-scale windows.
    public static let systemOwnerNames: Set<String> = [
        "WindowServer",
        "Dock",
        "Control Center",
        "ControlCenter",
        "Notification Center",
        "NotificationCenter",
        "Spotlight",
        "Wallpaper",
        "WindowManager",
        "SystemUIServer",
        "loginwindow",
        "screencaptureui",
        "UniversalControl"
    ]

    /// Bundle identifier prefixes for macOS & third-party IME (Chinese/CJK input method) candidate windows
    /// classified as `.system` so typing in a scaled app or 3D game NEVER triggers a false foreign-window overlap stop.
    public static let imeBundleIdentifierPrefixes: [String] = [
        "com.apple.inputmethod.",
        "im.rime.",
        "com.sogou.inputmethod",
        "com.tencent.inputmethod",
        "com.baidu.inputmethod"
    ]

    /// Minimum size for substantial always-on-top floating app windows (e.g. IINA/VLC/QuickTime "Float on Top").
    public static let substantialFloatingMinimumSize = CGSize(width: 200.0, height: 150.0)

    public static let defaultPollIntervalMilliseconds: Int = 40 // 25 Hz
    public static let defaultMinimumWindowDimension: CGFloat = 64.0
    public static let defaultOverlapThresholdPoints: CGFloat = 8.0
    /// Grace window after starting/switching tracked window during which delayed activation bounce
    /// notifications belonging to MetalPie's own PID are ignored (preventing instant session dismissal!).
    public static let defaultActivationGraceSeconds: TimeInterval = 0.45
    /// Off-screen grace duration while the tracked app is still frontmost so macOS's ~0.4–0.5s
    /// Fullscreen Space enter/exit zoom animation never emits a false `.targetMinimized`.
    public static let frontmostOffScreenGraceSeconds: TimeInterval = 0.45
    public static let frontmostOffScreenGraceTicks: Int = 11

    private struct WatcherState {
        var isObserving: Bool = false
        var trackedWindowID: CGWindowID?
        var trackedPID: Int32?
        var trackedLastDescriptor: WindowDescriptor?
        var trackedLastDisplayID: CGDirectDisplayID?
        var trackedHasFocus: Bool = false
        var activationGraceDeadlineUptime: TimeInterval = 0
        var autoRepositionState: AutoRepositionWaitState = .inactive
        var consecutiveMissingTicks: Int = 0
        var consecutiveOffScreenTicks: Int = 0
        var offScreenSinceUptime: TimeInterval? = nil
        var lastActiveWindowID: CGWindowID?
        var threeDGameMode: Bool = false
        var ignoredOverlayWindowIDs: Set<CGWindowID> = []
        var overlapCheckCounter: Int = 0
        var hasReportedOverlapForCurrentTarget: Bool = false
        var excludedBundleIDs: [String]
        var onEvent: (@Sendable (WindowLifecycleEvent) -> Void)?
        var onDetailedEvent: (@Sendable (DetailedWindowLifecycleEvent) -> Void)?
        var workspaceObservers: [any NSObjectProtocol] = []
        var appObservers: [any NSObjectProtocol] = []
        var pollTimer: (any DispatchSourceTimer)?
        var axObserver: AXObserver?
        var axRunLoopSource: CFRunLoopSource?
        var axCallbackBox: AXObserverCallbackBox?
        var cachedDisplays: [DisplayDescriptor] = []
    }

    private let watcherQueue = DispatchQueue(
        label: "com.metalpie.input.window-lifecycle",
        qos: .userInitiated
    )
    private let state: OSAllocatedUnfairLock<WatcherState>
    private let pollIntervalMs: Int
    private let activationGraceSeconds: TimeInterval

    public init(
        excludedBundleIDs: [String] = AppConfig.defaultAutoScaleExcludedBundleIDs,
        pollIntervalMilliseconds: Int = WindowLifecycleWatcher.defaultPollIntervalMilliseconds,
        activationGraceSeconds: TimeInterval = WindowLifecycleWatcher.defaultActivationGraceSeconds
    ) {
        self.pollIntervalMs = max(20, min(pollIntervalMilliseconds, 200))
        self.activationGraceSeconds = max(0.0, activationGraceSeconds)
        let initialDisplays = CursorOverlayController.snapshotCurrentDisplays()
        self.state = OSAllocatedUnfairLock(
            uncheckedState: WatcherState(
                excludedBundleIDs: excludedBundleIDs,
                cachedDisplays: initialDisplays
            )
        )
    }

    deinit {
        stopObserving()
    }

    // MARK: - Public Configuration & State

    public var autoRepositionState: AutoRepositionWaitState {
        state.withLockUnchecked { $0.autoRepositionState }
    }

    /// Registers an optional richer lifecycle event callback in addition to `WindowTracking`'s callback.
    public func setDetailedEventHandler(
        _ handler: (@Sendable (DetailedWindowLifecycleEvent) -> Void)?
    ) {
        state.withLockUnchecked { $0.onDetailedEvent = handler }
    }

    /// Enables/disables 3D Game Mode foreign window overlap detection (`>= 8pt`) and registers MetalPie's
    /// own overlay/cursor/toolbar `CGWindowID`s so they are never treated as foreign overlapping windows.
    public func setThreeDGameMode(
        _ enabled: Bool,
        ignoredOverlayWindowIDs: Set<CGWindowID> = []
    ) {
        state.withLockUnchecked { s in
            s.threeDGameMode = enabled
            if !ignoredOverlayWindowIDs.isEmpty {
                s.ignoredOverlayWindowIDs = ignoredOverlayWindowIDs
            }
            s.hasReportedOverlapForCurrentTarget = false
        }
    }

    /// Updates MetalPie's own overlay window IDs excluded from foreign overlap checks.
    public func updateIgnoredOverlayWindowIDs(_ ids: Set<CGWindowID>) {
        state.withLockUnchecked { $0.ignoredOverlayWindowIDs = ids }
    }

    /// Updates the bundle-ID blacklist shared with `AppConfig.autoScaleExcludedBundleIDs`.
    public func updateExcludedBundleIDs(_ bundleIDs: [String]) {
        state.withLockUnchecked { $0.excludedBundleIDs = bundleIDs }
    }

    /// Returns the latest cached multi-monitor display descriptors (refreshed on screen parameter changes).
    public func currentDisplays() -> [DisplayDescriptor] {
        let cached = state.withLockUnchecked { $0.cachedDisplays }
        if !cached.isEmpty { return cached }
        let fresh = CursorOverlayController.snapshotCurrentDisplays()
        state.withLockUnchecked { $0.cachedDisplays = fresh }
        return fresh
    }

    // MARK: - WindowTracking Discovery API

    /// Lists all capturable application windows across attached displays, applying the system blacklist
    /// and Wine/CrossOver raised-layer borderless fullscreen detection.
    public func listCapturableWindows() -> [WindowDescriptor] {
        let displays = currentDisplays()
        let excluded = state.withLockUnchecked { $0.excludedBundleIDs }
        let snapshots = Self.fetchOnScreenWindowSnapshots()
        return Self.filterCapturableWindows(
            from: snapshots,
            displays: displays,
            excludedBundleIDs: excluded
        )
    }

    /// Returns the frontmost capturable window belonging to the currently active application,
    /// preferring layer-0 windows `>= 64×64` and falling back to Wine raised display-filling windows.
    public func activeFrontmostWindow() -> WindowDescriptor? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = frontApp.processIdentifier
        let displays = currentDisplays()
        let excluded = state.withLockUnchecked { $0.excludedBundleIDs }
        let snapshots = Self.fetchOnScreenWindowSnapshots()
        return Self.selectFrontmostWindow(
            forPID: pid,
            from: snapshots,
            displays: displays,
            excludedBundleIDs: excluded
        )
    }

    // MARK: - WindowTracking Observation Lifecycle

    public func startObserving(
        trackedWindowID: CGWindowID?,
        onEvent: @escaping @Sendable (WindowLifecycleEvent) -> Void
    ) {
        stopObserving()

        let displays = CursorOverlayController.snapshotCurrentDisplays()
        let graceDeadline = ProcessInfo.processInfo.systemUptime + activationGraceSeconds
        state.withLockUnchecked { s in
            s.isObserving = true
            s.onEvent = onEvent
            s.cachedDisplays = displays
            s.trackedWindowID = trackedWindowID
            s.trackedPID = nil
            s.trackedLastDescriptor = nil
            s.trackedLastDisplayID = nil
            s.trackedHasFocus = false
            s.activationGraceDeadlineUptime = graceDeadline
            s.consecutiveMissingTicks = 0
            s.consecutiveOffScreenTicks = 0
            s.offScreenSinceUptime = nil
            s.hasReportedOverlapForCurrentTarget = false
            s.autoRepositionState = trackedWindowID.map { .tracking($0) } ?? .inactive
        }

        installWorkspaceAndAppObservers()

        watcherQueue.async { [weak self] in
            guard let self else { return }
            self.initializeTrackedWindowState(trackedWindowID)
            self.syncPollingTimer()
        }

        PipelineLog.shared.info(
            .input,
            "WindowLifecycleWatcher started (trackedWindowID: \(trackedWindowID.map(String.init) ?? "none"))."
        )
    }

    public func updateTrackedWindow(_ windowID: CGWindowID?) {
        let graceDeadline = ProcessInfo.processInfo.systemUptime + activationGraceSeconds
        watcherQueue.async { [weak self] in
            guard let self else { return }
            let isObserving = self.state.withLockUnchecked { $0.isObserving }
            guard isObserving else { return }

            self.teardownAXObserver()
            self.state.withLockUnchecked { s in
                s.trackedWindowID = windowID
                s.trackedPID = nil
                s.trackedLastDescriptor = nil
                s.trackedLastDisplayID = nil
                s.trackedHasFocus = false
                s.activationGraceDeadlineUptime = graceDeadline
                s.consecutiveMissingTicks = 0
                s.consecutiveOffScreenTicks = 0
                s.offScreenSinceUptime = nil
                s.hasReportedOverlapForCurrentTarget = false
                s.autoRepositionState = windowID.map { .tracking($0) } ?? .inactive
            }

            self.initializeTrackedWindowState(windowID)
            self.syncPollingTimer()
        }
    }

    public func stopObserving() {
        let teardown = state.withLockUnchecked { s -> (
            wasObserving: Bool,
            wsObservers: [any NSObjectProtocol],
            appObservers: [any NSObjectProtocol],
            timer: (any DispatchSourceTimer)?
        ) in
            let was = s.isObserving
            let ws = s.workspaceObservers
            let app = s.appObservers
            let timer = s.pollTimer
            s.isObserving = false
            s.trackedWindowID = nil
            s.trackedPID = nil
            s.trackedLastDescriptor = nil
            s.trackedLastDisplayID = nil
            s.trackedHasFocus = false
            s.consecutiveMissingTicks = 0
            s.consecutiveOffScreenTicks = 0
            s.offScreenSinceUptime = nil
            s.hasReportedOverlapForCurrentTarget = false
            s.autoRepositionState = .inactive
            s.onEvent = nil
            s.workspaceObservers.removeAll()
            s.appObservers.removeAll()
            s.pollTimer = nil
            return (was, ws, app, timer)
        }

        teardown.timer?.cancel()
        teardownAXObserver()

        let wsCenter = NSWorkspace.shared.notificationCenter
        for observer in teardown.wsObservers {
            wsCenter.removeObserver(observer)
        }
        let defaultCenter = NotificationCenter.default
        for observer in teardown.appObservers {
            defaultCenter.removeObserver(observer)
        }

        if teardown.wasObserving {
            PipelineLog.shared.info(.input, "WindowLifecycleWatcher stopped.")
        }
    }

    // MARK: - Cooperative Target Window Activation (macOS 14–27 Safe)

    /// Cooperatively hands focus from MetalPie to the target application and raises the exact target
    /// window so MetalPie's own window is NEVER left physically covering the target underneath the
    /// click-through `OverlayPanel` (which would cause the very first mouse click to hit MetalPie
    /// and immediately dismiss scaling!).
    ///
    /// - Orders back any visible non-panel MetalPie windows (`orderBack(nil)`).
    /// - Calls `NSApp.yieldActivation(to: targetApp)` + `targetApp.activate()` (macOS 14+ cooperative API).
    /// - When Accessibility is granted, raises the specific `AXUIElement` window matching `windowID`
    ///   (`kAXRaiseAction` + `kAXMainAttribute`) so multi-window apps like Terminal bring the exact window forward.
    /// - Polls briefly (up to `timeoutMilliseconds`) until `frontmostApplication?.processIdentifier == pid`.
    @MainActor
    @discardableResult
    public static func activateAndRaiseTargetWindow(
        windowID: CGWindowID,
        pid: Int32,
        orderBackOwnMainWindows: Bool = true,
        timeoutMilliseconds: Int = 300
    ) async -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard pid != ownPID else { return true }

        let app = NSApplication.shared
        if orderBackOwnMainWindows {
            for win in app.windows where win.isVisible && !(win is NSPanel) {
                win.orderBack(nil)
            }
        }

        guard let targetApp = NSRunningApplication(processIdentifier: pid) else {
            return false
        }

        app.yieldActivation(to: targetApp)
        _ = targetApp.activate()

        if AXIsProcessTrusted() {
            raiseSpecificAXWindowIfPossible(windowID: windowID, pid: pid)
        }

        let maxMs = max(0, min(timeoutMilliseconds, 1500))
        if maxMs == 0 || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }

        let deadline = CFAbsoluteTimeGetCurrent() + Double(maxMs) / 1000.0
        while CFAbsoluteTimeGetCurrent() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Pure grace-window helper preventing delayed MetalPie activation bounce notifications during
    /// cooperative handoff from immediately aborting a newly started scaling session.
    public static func shouldIgnoreActivationBounce(
        activatedPID: Int32,
        trackedPID: Int32,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        nowUptime: TimeInterval,
        graceDeadlineUptime: TimeInterval
    ) -> Bool {
        guard activatedPID != trackedPID else { return false }
        return activatedPID == ownPID && nowUptime < graceDeadlineUptime
    }

    /// Pure grace-window helper deciding whether an off-screen tracked window should emit `.targetMinimized`
    /// right now or wait during macOS's ~0.4–0.5s Fullscreen Space enter/exit zoom animation.
    ///
    /// - If Accessibility confirms `axMinimized == true` (genuinely minimized to Dock): emit immediately.
    /// - If the tracked app is no longer frontmost (`frontmostPID != trackedPID`): emit immediately.
    /// - While the tracked app is still frontmost (`frontmostPID == trackedPID`): require either
    ///   `consecutiveOffScreenTicks >= graceTicks` (default 11) or `elapsedOffScreenSeconds >= graceSeconds` (default 0.45s).
    public static func shouldEmitMinimizedForOffScreenWindow(
        trackedPID: Int32,
        frontmostPID: Int32?,
        axMinimized: Bool?,
        consecutiveOffScreenTicks: Int,
        elapsedOffScreenSeconds: TimeInterval,
        graceTicks: Int = WindowLifecycleWatcher.frontmostOffScreenGraceTicks,
        graceSeconds: TimeInterval = WindowLifecycleWatcher.frontmostOffScreenGraceSeconds
    ) -> Bool {
        if axMinimized == true {
            return true
        }
        guard frontmostPID == trackedPID else {
            return true
        }
        return consecutiveOffScreenTicks >= max(1, graceTicks)
            || elapsedOffScreenSeconds >= max(0.0, graceSeconds)
    }

    /// Queries `kAXMinimizedAttribute` on the matching `AXUIElement` window when Accessibility is granted.
    /// Returns `nil` when AX is unavailable or the window cannot be matched.
    private static func queryAXWindowMinimized(windowID: CGWindowID, pid: Int32) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return nil }
        let getWindowID = unsafeBitCast(sym, to: AXGetWindowFn.self)

        let appElem = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else {
            return nil
        }

        for axWin in axWindows {
            var candidateID: CGWindowID = 0
            if getWindowID(axWin, &candidateID) == .success && candidateID == windowID {
                var minimizedRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minimizedRef) == .success else {
                    return nil
                }
                if let boolVal = minimizedRef as? Bool {
                    return boolVal
                }
                if let numVal = minimizedRef as? NSNumber {
                    return numVal.boolValue
                }
                return nil
            }
        }
        return nil
    }

    private static func raiseSpecificAXWindowIfPossible(windowID: CGWindowID, pid: Int32) {
        typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return }
        let getWindowID = unsafeBitCast(sym, to: AXGetWindowFn.self)

        let appElem = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else {
            return
        }

        for axWin in axWindows {
            var candidateID: CGWindowID = 0
            if getWindowID(axWin, &candidateID) == .success && candidateID == windowID {
                _ = AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
                return
            }
        }
    }

    // MARK: - Pure Filtering & Overlap Detection (Unit-Testable)

    /// Filters raw CG window snapshots into capturable `WindowDescriptor`s, enforcing the system window
    /// blacklist, minimum size (`64×64`), and Wine/CrossOver raised-layer borderless fullscreen inclusion.
    public static func filterCapturableWindows(
        from snapshots: [RawWindowSnapshot],
        displays: [DisplayDescriptor],
        excludedBundleIDs: [String] = AppConfig.defaultAutoScaleExcludedBundleIDs,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        minimumDimension: CGFloat = WindowLifecycleWatcher.defaultMinimumWindowDimension
    ) -> [WindowDescriptor] {
        var results: [WindowDescriptor] = []
        results.reserveCapacity(snapshots.count)

        for snap in snapshots {
            guard snap.isOnScreen,
                  snap.alpha > 0.01,
                  snap.cgBounds.width >= minimumDimension,
                  snap.cgBounds.height >= minimumDimension
            else {
                continue
            }

            let category = classifyOwner(
                pid: snap.pid,
                ownerName: snap.ownerName,
                bundleIdentifier: snap.bundleIdentifier,
                layer: snap.layer,
                bounds: snap.cgBounds,
                displays: displays,
                excludedBundleIDs: excludedBundleIDs,
                ownPID: ownPID
            )

            guard category == .application else { continue }

            let isNormalLayer = (snap.layer == 0)
            let isWineRaisedFullscreen = (snap.layer > 0) && isDisplayFillingWindow(snap.cgBounds, displays: displays)
            let isSubstantialFloating = isSubstantialFloatingAppWindow(layer: snap.layer, bounds: snap.cgBounds)
            guard isNormalLayer || isWineRaisedFullscreen || isSubstantialFloating else { continue }

            let scale = ScreenGeometry.bestDisplay(forCGRect: snap.cgBounds, in: displays)?.backingScaleFactor ?? 2.0
            results.append(WindowDescriptor(
                windowID: snap.windowID,
                pid: snap.pid,
                appName: snap.ownerName,
                bundleIdentifier: snap.bundleIdentifier,
                appPath: snap.appPath,
                title: snap.title,
                cgBounds: snap.cgBounds,
                isOnScreen: snap.isOnScreen,
                isMinimized: !snap.isOnScreen,
                backingScaleFactor: scale,
                ownerCategory: category
            ))
        }

        return results
    }

    /// Selects the frontmost capturable window for `pid` (preserving z-order from `snapshots`):
    /// 1. Prefers any display-covering fullscreen window (`layer == 0` OR raised `layer > 0`; largest area if multiple)
    ///    so tiny Safari/Chrome/IINA media-control/HUD helper bars never shadow the real fullscreen video window.
    /// 2. Otherwise prefers the topmost substantial `layer == 0` window (`>= 200x150`) over tiny helper bars.
    /// 3. Falls back to the topmost `layer == 0` window meeting `minimumDimension`.
    public static func selectFrontmostWindow(
        forPID pid: Int32,
        from snapshots: [RawWindowSnapshot],
        displays: [DisplayDescriptor],
        excludedBundleIDs: [String] = AppConfig.defaultAutoScaleExcludedBundleIDs,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        minimumDimension: CGFloat = WindowLifecycleWatcher.defaultMinimumWindowDimension
    ) -> WindowDescriptor? {
        let pidSnapshots = snapshots.filter {
            $0.pid == pid &&
                $0.isOnScreen &&
                $0.alpha > 0.01 &&
                $0.cgBounds.width >= minimumDimension &&
                $0.cgBounds.height >= minimumDimension
        }

        // 1. Prefer any display-covering fullscreen window (layer == 0 OR raised layer > 0;
        //    largest area wins if multiple, preserving frontmost z-order on area ties).
        var bestFullscreen: RawWindowSnapshot?
        var bestFullscreenArea: CGFloat = -1
        for snap in pidSnapshots where snap.layer >= 0 && isDisplayFillingWindow(snap.cgBounds, displays: displays) {
            let area = snap.cgBounds.width * snap.cgBounds.height
            if area > bestFullscreenArea {
                bestFullscreen = snap
                bestFullscreenArea = area
            }
        }
        if let fullscreen = bestFullscreen {
            return makeDescriptor(
                from: fullscreen,
                displays: displays,
                excludedBundleIDs: excludedBundleIDs,
                ownPID: ownPID
            )
        }

        // 2. Prefer topmost substantial normal layer-0 window (>= 200x150) over tiny 64x64 helper bars.
        if let substantialNormal = pidSnapshots.first(where: {
            $0.layer == 0 && $0.cgBounds.width >= 200.0 && $0.cgBounds.height >= 150.0
        }) {
            return makeDescriptor(
                from: substantialNormal,
                displays: displays,
                excludedBundleIDs: excludedBundleIDs,
                ownPID: ownPID
            )
        }

        // 3. Fallback: topmost normal layer-0 window meeting `minimumDimension`.
        if let normal = pidSnapshots.first(where: { $0.layer == 0 }) {
            return makeDescriptor(
                from: normal,
                displays: displays,
                excludedBundleIDs: excludedBundleIDs,
                ownPID: ownPID
            )
        }

        // 4. Always-on-top fallback: topmost substantial floating app window (layer == floatingWindow [3], >= 200x150),
        //    e.g. IINA/VLC/QuickTime "Float on Top", strictly excluding system & IME processes.
        if let floating = pidSnapshots.first(where: { snap in
            guard isSubstantialFloatingAppWindow(layer: snap.layer, bounds: snap.cgBounds) else {
                return false
            }
            return classifyOwner(
                pid: snap.pid,
                ownerName: snap.ownerName,
                bundleIdentifier: snap.bundleIdentifier,
                layer: snap.layer,
                bounds: snap.cgBounds,
                displays: displays,
                excludedBundleIDs: excludedBundleIDs,
                ownPID: ownPID
            ) == .application
        }) {
            return makeDescriptor(
                from: floating,
                displays: displays,
                excludedBundleIDs: excludedBundleIDs,
                ownPID: ownPID
            )
        }

        return nil
    }

    /// Finds a newly opened display-covering fullscreen window owned by `pid` (e.g. Safari/Chrome
    /// HTML5 video fullscreen or IINA/VLC native fullscreen) to seamlessly follow when `previousWindowID`
    /// hides or leaves the desktop Space.
    public static func findFullscreenReplacementWindow(
        forPID pid: Int32,
        excluding previousWindowID: CGWindowID,
        displays: [DisplayDescriptor]
    ) -> WindowDescriptor? {
        let snapshots = fetchOnScreenWindowSnapshots()
        return findFullscreenReplacementWindow(
            forPID: pid,
            excluding: previousWindowID,
            from: snapshots,
            displays: displays
        )
    }

    /// Pure, unit-testable helper locating a display-covering fullscreen replacement window owned by
    /// `pid` (excluding `previousWindowID`) from a snapshot list.
    public static func findFullscreenReplacementWindow(
        forPID pid: Int32,
        excluding previousWindowID: CGWindowID,
        from snapshots: [RawWindowSnapshot],
        displays: [DisplayDescriptor],
        excludedBundleIDs: [String] = AppConfig.defaultAutoScaleExcludedBundleIDs,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> WindowDescriptor? {
        guard !displays.isEmpty else { return nil }

        // Pass 1: Strict full-display covering window (layer == 0 or raised layer > 0).
        var bestStrict: RawWindowSnapshot?
        var bestStrictArea: CGFloat = -1
        // Pass 2 fallback: macOS native fullscreen window sitting strictly below a notch camera housing
        // (edge-to-edge horizontally, flush to bottom, top inset <= 44pt).
        var bestNotchInset: RawWindowSnapshot?
        var bestNotchInsetArea: CGFloat = -1

        for snap in snapshots {
            guard snap.pid == pid,
                  snap.windowID != previousWindowID,
                  snap.isOnScreen,
                  snap.alpha > 0.01,
                  snap.layer >= 0
            else {
                continue
            }

            let area = snap.cgBounds.width * snap.cgBounds.height
            if isDisplayFillingWindow(snap.cgBounds, displays: displays) {
                if area > bestStrictArea {
                    bestStrict = snap
                    bestStrictArea = area
                }
            } else if isNotchInsetFullscreenWindow(snap.cgBounds, displays: displays) {
                if area > bestNotchInsetArea {
                    bestNotchInset = snap
                    bestNotchInsetArea = area
                }
            }
        }

        guard let chosen = bestStrict ?? bestNotchInset else { return nil }
        return makeDescriptor(
            from: chosen,
            displays: displays,
            excludedBundleIDs: excludedBundleIDs,
            ownPID: ownPID
        )
    }

    private static func isNotchInsetFullscreenWindow(
        _ bounds: CGRect,
        displays: [DisplayDescriptor]
    ) -> Bool {
        let tolerance: CGFloat = 4.0
        let maxNotchInset: CGFloat = 44.0
        let normalized = bounds.standardized
        guard !normalized.isEmpty else { return false }
        return displays.contains { display in
            let db = display.cgBounds.standardized
            return normalized.minX <= db.minX + tolerance &&
                normalized.maxX >= db.maxX - tolerance &&
                normalized.maxY >= db.maxY - tolerance &&
                normalized.minY >= db.minY &&
                normalized.minY <= db.minY + maxNotchInset
        }
    }

    /// Detects whether any non-popup foreign window above the tracked window overlaps `trackedBounds`
    /// by at least `minimumOverlapPoints` (default `8.0pt`) in both axes (Magpie 3D Game Mode guard).
    public static func detectForeignWindowOverlap(
        trackedBounds: CGRect,
        trackedPID: Int32,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        ignoredWindowIDs: Set<CGWindowID> = [],
        excludedBundleIDs: [String] = AppConfig.defaultAutoScaleExcludedBundleIDs,
        displays: [DisplayDescriptor] = [],
        windowsAboveTarget: [RawWindowSnapshot],
        minimumOverlapPoints: CGFloat = WindowLifecycleWatcher.defaultOverlapThresholdPoints
    ) -> (window: WindowDescriptor, overlapRect: CGRect)? {
        let normalizedTarget = trackedBounds.standardized
        guard !normalizedTarget.isEmpty else { return nil }

        for candidate in windowsAboveTarget {
            guard candidate.isOnScreen, candidate.alpha > 0.01 else { continue }
            guard candidate.pid != ownPID else { continue }
            guard candidate.pid != trackedPID else { continue }
            guard !ignoredWindowIDs.contains(candidate.windowID) else { continue }

            // Ignore tiny popups, tooltips, and system chrome.
            let isNonPopupNormal = candidate.layer == 0 && candidate.cgBounds.width >= 64 && candidate.cgBounds.height >= 64
            let isSubstantialFloating = candidate.layer > 0 && candidate.cgBounds.width >= 200 && candidate.cgBounds.height >= 150
            guard isNonPopupNormal || isSubstantialFloating else { continue }

            let category = classifyOwner(
                pid: candidate.pid,
                ownerName: candidate.ownerName,
                bundleIdentifier: candidate.bundleIdentifier,
                layer: candidate.layer,
                bounds: candidate.cgBounds,
                displays: displays,
                excludedBundleIDs: excludedBundleIDs,
                ownPID: ownPID
            )
            // Accept normal app windows AND substantial non-system/non-MetalPie floating panels (`layer > 0`).
            guard category == .application || (isSubstantialFloating && category == .overlay) else { continue }

            let inter = candidate.cgBounds.intersection(normalizedTarget)
            if !inter.isNull, !inter.isEmpty,
               inter.width >= minimumOverlapPoints,
               inter.height >= minimumOverlapPoints
            {
                let desc = makeDescriptor(
                    from: candidate,
                    displays: displays,
                    excludedBundleIDs: excludedBundleIDs,
                    ownPID: ownPID
                )
                return (desc, inter)
            }
        }
        return nil
    }

    public static func classifyOwner(
        pid: Int32,
        ownerName: String,
        bundleIdentifier: String?,
        layer: Int,
        bounds: CGRect,
        displays: [DisplayDescriptor],
        excludedBundleIDs: [String],
        ownPID: Int32
    ) -> WindowOwnerCategory {
        if pid == ownPID {
            return .metalPie
        }
        if let bid = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bid.isEmpty {
            if bid.caseInsensitiveCompare("com.metalpie.app") == .orderedSame {
                return .metalPie
            }
            if excludedBundleIDs.contains(where: { $0.caseInsensitiveCompare(bid) == .orderedSame }) {
                return .system
            }
            let lowerBid = bid.lowercased()
            if imeBundleIdentifierPrefixes.contains(where: { lowerBid.hasPrefix($0) }) {
                return .system
            }
        }
        if systemOwnerNames.contains(ownerName) {
            return .system
        }
        if layer != 0
            && !isDisplayFillingWindow(bounds, displays: displays)
            && !isSubstantialFloatingAppWindow(layer: layer, bounds: bounds)
        {
            return .overlay
        }
        return .application
    }

    /// Returns `true` when `layer` matches macOS's standard floating window level (`CGWindowLevelForKey(.floatingWindow)` == `3`)
    /// and `bounds` is substantial (`>= 200×150`), supporting IINA/VLC/QuickTime "Float on Top" windows.
    public static func isSubstantialFloatingAppWindow(layer: Int, bounds: CGRect) -> Bool {
        let normalized = bounds.standardized
        return layer == Int(CGWindowLevelForKey(.floatingWindow))
            && normalized.width >= substantialFloatingMinimumSize.width
            && normalized.height >= substantialFloatingMinimumSize.height
    }

    public static func isDisplayFillingWindow(_ bounds: CGRect, displays: [DisplayDescriptor]) -> Bool {
        let tolerance: CGFloat = 4.0
        let normalized = bounds.standardized
        guard !normalized.isEmpty else { return false }
        return displays.contains { display in
            let db = display.cgBounds.standardized
            return normalized.minX <= db.minX + tolerance &&
                normalized.minY <= db.minY + tolerance &&
                normalized.maxX >= db.maxX - tolerance &&
                normalized.maxY >= db.maxY - tolerance
        }
    }

    // MARK: - Workspace & Screen Notifications

    private func installWorkspaceAndAppObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        let appCenter = NotificationCenter.default

        var wsTokens: [any NSObjectProtocol] = []
        wsTokens.append(wsCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            self.watcherQueue.async { [weak self] in
                self?.handleApplicationActivated(pid: pid)
            }
        })

        wsTokens.append(wsCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            self.watcherQueue.async { [weak self] in
                self?.handleApplicationHidden(pid: pid)
            }
        })

        wsTokens.append(wsCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            self.watcherQueue.async { [weak self] in
                self?.handleApplicationTerminated(pid: pid)
            }
        })

        wsTokens.append(wsCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.watcherQueue.async { [weak self] in
                self?.handleActiveSpaceChanged()
            }
        })

        let screenToken = appCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.watcherQueue.async { [weak self] in
                self?.handleScreenParametersChanged()
            }
        }

        state.withLockUnchecked { s in
            s.workspaceObservers = wsTokens
            s.appObservers = [screenToken]
        }
    }

    // MARK: - Event Handlers (Always on `watcherQueue`)

    private func initializeTrackedWindowState(_ windowID: CGWindowID?) {
        guard let windowID else { return }

        let displays = currentDisplays()
        let excluded = state.withLockUnchecked { $0.excludedBundleIDs }
        guard let snap = Self.fetchSingleWindowSnapshot(windowID: windowID) else {
            // Window already gone before tracking began!
            emit(.trackedWindowClosed(windowID), detailed: .targetClosed(windowID))
            state.withLockUnchecked { s in
                s.trackedWindowID = nil
                s.autoRepositionState = .inactive
            }
            return
        }

        let desc = Self.makeDescriptor(
            from: snap,
            displays: displays,
            excludedBundleIDs: excluded,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        let bestDisplay = ScreenGeometry.bestDisplay(forCGRect: desc.cgBounds, in: displays)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let hasFocus = (frontPID == snap.pid) && snap.isOnScreen

        state.withLockUnchecked { s in
            s.trackedPID = snap.pid
            s.trackedLastDescriptor = desc
            s.trackedLastDisplayID = bestDisplay?.id
            s.trackedHasFocus = hasFocus
            s.autoRepositionState = snap.isOnScreen
                ? .tracking(windowID)
                : .waitingForRestore(windowID, since: Date())
        }

        attachAXObserverIfTrusted(forPID: snap.pid)
    }

    private func handleApplicationActivated(pid: Int32?) {
        let info = state.withLockUnchecked { s in
            (
                isObserving: s.isObserving,
                trackedID: s.trackedWindowID,
                trackedPID: s.trackedPID,
                hadFocus: s.trackedHasFocus,
                graceDeadline: s.activationGraceDeadlineUptime,
                repositionState: s.autoRepositionState
            )
        }
        guard info.isObserving else { return }

        // 1. Tracked window focus transitions (IMMEDIATE focus-loss emission on Cmd+Tab,
        //    protected against delayed startup MetalPie activation bounce during grace window!).
        if let trackedID = info.trackedID, let trackedPID = info.trackedPID {
            if let activatedPID = pid, activatedPID != trackedPID {
                let nowUptime = ProcessInfo.processInfo.systemUptime
                if Self.shouldIgnoreActivationBounce(
                    activatedPID: activatedPID,
                    trackedPID: trackedPID,
                    nowUptime: nowUptime,
                    graceDeadlineUptime: info.graceDeadline
                ) {
                    PipelineLog.shared.debug(
                        .input,
                        "Ignored own-app activation bounce during startup grace window for tracked window \(trackedID)."
                    )
                } else if info.hadFocus {
                    state.withLockUnchecked { s in
                        s.trackedHasFocus = false
                        s.hasReportedOverlapForCurrentTarget = false
                    }
                    emit(.trackedWindowFocusLost(trackedID), detailed: .targetLostFocus(trackedID))
                }
            } else if let activatedPID = pid, activatedPID == trackedPID {
                // Target app regained focus — verify tracked window is onscreen and exists.
                if let snap = Self.fetchSingleWindowSnapshot(windowID: trackedID) {
                    let desc = Self.makeDescriptor(
                        from: snap,
                        displays: currentDisplays(),
                        excludedBundleIDs: state.withLockUnchecked { $0.excludedBundleIDs },
                        ownPID: ProcessInfo.processInfo.processIdentifier
                    )
                    if snap.isOnScreen {
                        let wasWaiting: Bool
                        if case .waitingForRestore = info.repositionState {
                            wasWaiting = true
                        } else {
                            wasWaiting = false
                        }
                        state.withLockUnchecked { s in
                            s.trackedHasFocus = true
                            s.trackedLastDescriptor = desc
                            s.autoRepositionState = .tracking(trackedID)
                            s.consecutiveMissingTicks = 0
                            s.consecutiveOffScreenTicks = 0
                            s.offScreenSinceUptime = nil
                        }
                        if wasWaiting {
                            emit(.trackedWindowRestored(desc), detailed: .targetRestored(desc))
                        }
                        if !info.hadFocus {
                            emit(.trackedWindowFocusGained(desc), detailed: .targetGainedFocus(desc))
                        }
                    }
                } else {
                    handleTrackedWindowConfirmedClosed(trackedID)
                }
            }
        }

        // 2. Active frontmost window changed notification (for AutoScaleController & UI).
        let activeDesc: WindowDescriptor?
        if let pid {
            let displays = currentDisplays()
            let excluded = state.withLockUnchecked { $0.excludedBundleIDs }
            let snapshots = Self.fetchOnScreenWindowSnapshots()
            activeDesc = Self.selectFrontmostWindow(
                forPID: pid,
                from: snapshots,
                displays: displays,
                excludedBundleIDs: excluded
            )
        } else {
            activeDesc = nil
        }

        state.withLockUnchecked { $0.lastActiveWindowID = activeDesc?.windowID }
        emit(.activeWindowChanged(activeDesc), detailed: .activeWindowChanged(activeDesc))
    }

    private func handleApplicationHidden(pid: Int32?) {
        guard let pid else { return }
        let info = state.withLockUnchecked { s in
            (isObserving: s.isObserving, trackedID: s.trackedWindowID, trackedPID: s.trackedPID, hadFocus: s.trackedHasFocus)
        }
        guard info.isObserving, let trackedID = info.trackedID, info.trackedPID == pid else { return }

        state.withLockUnchecked { s in
            s.trackedHasFocus = false
            s.autoRepositionState = .waitingForRestore(trackedID, since: Date())
        }
        if info.hadFocus {
            emit(.trackedWindowFocusLost(trackedID), detailed: .targetLostFocus(trackedID))
        }
        emit(.trackedWindowMinimized(trackedID), detailed: .targetMinimized(trackedID))
    }

    private func handleApplicationTerminated(pid: Int32?) {
        guard let pid else { return }
        let info = state.withLockUnchecked { s in
            (isObserving: s.isObserving, trackedID: s.trackedWindowID, trackedPID: s.trackedPID)
        }
        guard info.isObserving, let trackedID = info.trackedID, info.trackedPID == pid else { return }

        handleTrackedWindowConfirmedClosed(trackedID)
    }

    private func handleActiveSpaceChanged() {
        let info = state.withLockUnchecked { s in
            (isObserving: s.isObserving, trackedID: s.trackedWindowID, hadFocus: s.trackedHasFocus)
        }
        guard info.isObserving else { return }

        emitDetailedOnly(.activeSpaceChanged)

        guard let trackedID = info.trackedID else { return }
        if let snap = Self.fetchSingleWindowSnapshot(windowID: trackedID) {
            if !snap.isOnScreen {
                let nowUptime = ProcessInfo.processInfo.systemUptime
                let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let axMinimized = (frontPID == snap.pid)
                    ? Self.queryAXWindowMinimized(windowID: trackedID, pid: snap.pid)
                    : nil
                let offScreenStats = state.withLockUnchecked { s -> (alreadyWaiting: Bool, ticks: Int, elapsed: TimeInterval) in
                    if case .waitingForRestore = s.autoRepositionState {
                        return (true, s.consecutiveOffScreenTicks, 0)
                    }
                    let since = s.offScreenSinceUptime ?? nowUptime
                    s.offScreenSinceUptime = since
                    s.consecutiveOffScreenTicks += 1
                    return (false, s.consecutiveOffScreenTicks, max(0, nowUptime - since))
                }
                guard !offScreenStats.alreadyWaiting else { return }
                guard Self.shouldEmitMinimizedForOffScreenWindow(
                    trackedPID: snap.pid,
                    frontmostPID: frontPID,
                    axMinimized: axMinimized,
                    consecutiveOffScreenTicks: offScreenStats.ticks,
                    elapsedOffScreenSeconds: offScreenStats.elapsed
                ) else {
                    // Tracked app is still frontmost during macOS's ~0.45s Space zoom animation;
                    // defer to the 25Hz poll loop rather than firing a false `.targetMinimized`!
                    return
                }

                let alreadyWaiting = state.withLockUnchecked { s -> Bool in
                    if case .waitingForRestore = s.autoRepositionState { return true }
                    s.trackedHasFocus = false
                    s.autoRepositionState = .waitingForRestore(trackedID, since: Date())
                    return false
                }
                if info.hadFocus {
                    emit(.trackedWindowFocusLost(trackedID), detailed: .targetLostFocus(trackedID))
                }
                if !alreadyWaiting {
                    emit(.trackedWindowMinimized(trackedID), detailed: .targetMinimized(trackedID))
                }
            } else {
                // Re-check immediately on space restore.
                pollTrackedWindowTick()
            }
        } else {
            handleTrackedWindowConfirmedClosed(trackedID)
        }
    }

    private func handleScreenParametersChanged() {
        let freshDisplays = CursorOverlayController.snapshotCurrentDisplays()
        let isObserving = state.withLockUnchecked { s -> Bool in
            s.cachedDisplays = freshDisplays
            return s.isObserving
        }
        guard isObserving else { return }

        emitDetailedOnly(.screenParametersChanged(freshDisplays))
        // Immediately re-evaluate tracked window display/bounds.
        pollTrackedWindowTick()
    }

    // MARK: - Lightweight ~25 Hz Tracked-Window Poll (Zero MainActor IPC!)

    private func syncPollingTimer() {
        let needsTimer = state.withLockUnchecked { $0.isObserving && $0.trackedWindowID != nil }

        let oldTimer = state.withLockUnchecked { s -> (any DispatchSourceTimer)? in
            if needsTimer && s.pollTimer != nil {
                return nil
            }
            let existing = s.pollTimer
            if !needsTimer {
                s.pollTimer = nil
            }
            return existing
        }

        if !needsTimer {
            oldTimer?.cancel()
            return
        }

        let alreadyHasTimer = state.withLockUnchecked { $0.pollTimer != nil }
        guard !alreadyHasTimer else { return }

        let timer = DispatchSource.makeTimerSource(queue: watcherQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(pollIntervalMs),
            repeating: .milliseconds(pollIntervalMs),
            leeway: .milliseconds(8)
        )
        timer.setEventHandler { [weak self] in
            self?.pollTrackedWindowTick()
        }
        state.withLockUnchecked { $0.pollTimer = timer }
        timer.resume()
    }

    private func pollTrackedWindowTick() {
        let snapState = state.withLockUnchecked { s in
            (
                isObserving: s.isObserving,
                trackedID: s.trackedWindowID,
                trackedPID: s.trackedPID,
                lastDescriptor: s.trackedLastDescriptor,
                lastDisplayID: s.trackedLastDisplayID,
                hadFocus: s.trackedHasFocus,
                repositionState: s.autoRepositionState,
                threeDGameMode: s.threeDGameMode,
                ignoredOverlayIDs: s.ignoredOverlayWindowIDs,
                excludedBundleIDs: s.excludedBundleIDs,
                displays: s.cachedDisplays
            )
        }

        guard snapState.isObserving, let trackedID = snapState.trackedID else { return }

        // Single-window lookup: fast (~0.1 ms), avoids scanning all system windows!
        guard let raw = Self.fetchSingleWindowSnapshot(windowID: trackedID) else {
            // Explicitly fix MetalGoose's orphan-overlay bug: `windowInfo == nil` -> targetClosed!
            // Confirm across 2 ticks (40ms) to filter out single-frame WindowServer transition glitches.
            let missingCount = state.withLockUnchecked { s -> Int in
                s.consecutiveMissingTicks += 1
                return s.consecutiveMissingTicks
            }
            if missingCount >= 2 {
                handleTrackedWindowConfirmedClosed(trackedID)
            }
            return
        }

        state.withLockUnchecked { $0.consecutiveMissingTicks = 0 }

        let displays = snapState.displays.isEmpty ? currentDisplays() : snapState.displays
        let desc = Self.makeDescriptor(
            from: raw,
            displays: displays,
            excludedBundleIDs: snapState.excludedBundleIDs,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )

        // 1. Check onscreen / minimized / Auto-Reposition Wait transitions.
        let wasWaiting: Bool
        if case .waitingForRestore = snapState.repositionState {
            wasWaiting = true
        } else {
            wasWaiting = false
        }

        if !raw.isOnScreen {
            if !wasWaiting {
                let nowUptime = ProcessInfo.processInfo.systemUptime
                let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let axMinimized = (frontPID == raw.pid)
                    ? Self.queryAXWindowMinimized(windowID: trackedID, pid: raw.pid)
                    : nil
                let offScreenStats = state.withLockUnchecked { s -> (ticks: Int, elapsed: TimeInterval) in
                    let since = s.offScreenSinceUptime ?? nowUptime
                    s.offScreenSinceUptime = since
                    s.consecutiveOffScreenTicks += 1
                    return (s.consecutiveOffScreenTicks, max(0, nowUptime - since))
                }

                guard Self.shouldEmitMinimizedForOffScreenWindow(
                    trackedPID: raw.pid,
                    frontmostPID: frontPID,
                    axMinimized: axMinimized,
                    consecutiveOffScreenTicks: offScreenStats.ticks,
                    elapsedOffScreenSeconds: offScreenStats.elapsed
                ) else {
                    // Brief Fullscreen Space enter/exit animation blackout while target app stays frontmost.
                    return
                }

                state.withLockUnchecked { s in
                    s.trackedHasFocus = false
                    s.autoRepositionState = .waitingForRestore(trackedID, since: Date())
                    s.trackedLastDescriptor = desc
                }
                if snapState.hadFocus {
                    emit(.trackedWindowFocusLost(trackedID), detailed: .targetLostFocus(trackedID))
                }
                emit(.trackedWindowMinimized(trackedID), detailed: .targetMinimized(trackedID))
            }
            return
        } else if wasWaiting {
            // Window returned onscreen! Auto-resume from Magpie's Auto-Reposition Wait.
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let nowFocused = (frontPID == raw.pid)
            state.withLockUnchecked { s in
                s.autoRepositionState = .tracking(trackedID)
                s.trackedLastDescriptor = desc
                s.trackedHasFocus = nowFocused
                s.consecutiveOffScreenTicks = 0
                s.offScreenSinceUptime = nil
            }
            emit(.trackedWindowRestored(desc), detailed: .targetRestored(desc))
            if nowFocused && !snapState.hadFocus {
                emit(.trackedWindowFocusGained(desc), detailed: .targetGainedFocus(desc))
            }
        } else {
            state.withLockUnchecked { s in
                s.consecutiveOffScreenTicks = 0
                s.offScreenSinceUptime = nil
                if !s.trackedHasFocus {
                    let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    if frontPID == raw.pid {
                        s.trackedHasFocus = true
                    }
                }
            }
        }

        // 2. Check frame / display changes (move, resize, or cross-monitor drag).
        let currentDisplay = ScreenGeometry.bestDisplay(forCGRect: desc.cgBounds, in: displays)
        let displayChanged = (snapState.lastDisplayID != nil && currentDisplay?.id != snapState.lastDisplayID)
        let boundsChanged: Bool
        if let prevBounds = snapState.lastDescriptor?.cgBounds {
            boundsChanged =
                abs(prevBounds.minX - desc.cgBounds.minX) >= 0.5 ||
                abs(prevBounds.minY - desc.cgBounds.minY) >= 0.5 ||
                abs(prevBounds.width - desc.cgBounds.width) >= 0.5 ||
                abs(prevBounds.height - desc.cgBounds.height) >= 0.5
        } else {
            boundsChanged = false
        }

        if boundsChanged || displayChanged {
            state.withLockUnchecked { s in
                s.trackedLastDescriptor = desc
                s.trackedLastDisplayID = currentDisplay?.id
            }
            emit(
                .trackedWindowMoved(desc),
                detailed: .targetFrameChanged(window: desc, newBounds: desc.cgBounds, display: currentDisplay)
            )
        } else if snapState.lastDescriptor == nil {
            state.withLockUnchecked { s in
                s.trackedLastDescriptor = desc
                s.trackedLastDisplayID = currentDisplay?.id
            }
        }

        // 3. Check 3D Game Mode foreign window overlap (>= 8pt) at ~8–10 Hz while focused.
        if snapState.threeDGameMode && snapState.hadFocus {
            let shouldCheckOverlap = state.withLockUnchecked { s -> Bool in
                s.overlapCheckCounter += 1
                return (s.overlapCheckCounter % 3) == 0
            }

            if shouldCheckOverlap {
                let aboveSnapshots = Self.fetchWindowSnapshotsAbove(windowID: trackedID)
                if let overlap = Self.detectForeignWindowOverlap(
                    trackedBounds: desc.cgBounds,
                    trackedPID: raw.pid,
                    ownPID: ProcessInfo.processInfo.processIdentifier,
                    ignoredWindowIDs: snapState.ignoredOverlayIDs,
                    excludedBundleIDs: snapState.excludedBundleIDs,
                    displays: displays,
                    windowsAboveTarget: aboveSnapshots
                ) {
                    let shouldEmit = state.withLockUnchecked { s -> Bool in
                        guard !s.hasReportedOverlapForCurrentTarget else { return false }
                        s.hasReportedOverlapForCurrentTarget = true
                        s.trackedHasFocus = false
                        return true
                    }
                    if shouldEmit {
                        PipelineLog.shared.warning(
                            .input,
                            "3D Game Mode overlap detected: '\(overlap.window.displayName)' overlapped tracked window \(trackedID) by \(Int(overlap.overlapRect.width))x\(Int(overlap.overlapRect.height))pt."
                        )
                        emit(
                            .trackedWindowFocusLost(trackedID),
                            detailed: .foreignWindowOverlapped(
                                trackedWindowID: trackedID,
                                overlappingWindow: overlap.window,
                                overlapRect: overlap.overlapRect
                            )
                        )
                    }
                } else {
                    state.withLockUnchecked { $0.hasReportedOverlapForCurrentTarget = false }
                }
            }
        }
    }

    private func handleTrackedWindowConfirmedClosed(_ windowID: CGWindowID) {
        let shouldEmit = state.withLockUnchecked { s -> Bool in
            guard s.trackedWindowID == windowID else { return false }
            s.trackedWindowID = nil
            s.trackedPID = nil
            s.trackedLastDescriptor = nil
            s.trackedLastDisplayID = nil
            s.trackedHasFocus = false
            s.consecutiveMissingTicks = 0
            s.consecutiveOffScreenTicks = 0
            s.offScreenSinceUptime = nil
            s.hasReportedOverlapForCurrentTarget = false
            s.autoRepositionState = .inactive
            return true
        }
        guard shouldEmit else { return }

        teardownAXObserver()
        syncPollingTimer()
        PipelineLog.shared.info(.input, "Tracked window \(windowID) closed; emitting targetClosed immediately.")
        emit(.trackedWindowClosed(windowID), detailed: .targetClosed(windowID))
    }

    // MARK: - Optional AXObserver (Zero-Latency Move/Resize/Minimize/Destroy when AX Granted)

    private func attachAXObserverIfTrusted(forPID pid: Int32) {
        guard AXIsProcessTrusted() else { return }
        teardownAXObserver()

        let box = AXObserverCallbackBox { [weak self] notificationName in
            guard let self else { return }
            self.watcherQueue.async { [weak self] in
                self?.handleAXNotification(notificationName)
            }
        }

        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let callbackBox = Unmanaged<AXObserverCallbackBox>.fromOpaque(refcon).takeUnretainedValue()
            callbackBox.notify(notification as String)
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            box.invalidate()
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        let notifications: [String] = [
            "AXMoved",
            "AXResized",
            "AXWindowMiniaturized",
            "AXWindowDeminiaturized",
            "AXUIElementDestroyed",
            "AXFocusedWindowChanged"
        ]

        for name in notifications {
            _ = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
        }

        let source = AXObserverGetRunLoopSource(observer)
        state.withLockUnchecked { s in
            s.axObserver = observer
            s.axRunLoopSource = source
            s.axCallbackBox = box
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func teardownAXObserver() {
        let ax = state.withLockUnchecked { s -> (CFRunLoopSource?, AXObserverCallbackBox?) in
            let src = s.axRunLoopSource
            let box = s.axCallbackBox
            s.axObserver = nil
            s.axRunLoopSource = nil
            s.axCallbackBox = nil
            return (src, box)
        }

        ax.1?.invalidate()
        if let src = ax.0 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func handleAXNotification(_ notificationName: String) {
        if notificationName == "AXFocusedWindowChanged" {
            if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                let snapshots = Self.fetchOnScreenWindowSnapshots()
                let active = Self.selectFrontmostWindow(
                    forPID: frontPID,
                    from: snapshots,
                    displays: currentDisplays(),
                    excludedBundleIDs: state.withLockUnchecked { $0.excludedBundleIDs }
                )
                let changed = state.withLockUnchecked { s -> Bool in
                    guard s.lastActiveWindowID != active?.windowID else { return false }
                    s.lastActiveWindowID = active?.windowID
                    return true
                }
                if changed {
                    emit(.activeWindowChanged(active), detailed: .activeWindowChanged(active))
                }
            }
        }
        // Trigger an immediate tracked-window refresh so move/resize/minimize/destroy arrive in <1ms!
        pollTrackedWindowTick()
    }

    // MARK: - Emission Helpers

    private func emit(
        _ event: WindowLifecycleEvent,
        detailed: DetailedWindowLifecycleEvent
    ) {
        let handlers = state.withLockUnchecked { ($0.onEvent, $0.onDetailedEvent) }
        handlers.0?(event)
        handlers.1?(detailed)
    }

    private func emitDetailedOnly(_ detailed: DetailedWindowLifecycleEvent) {
        let handler = state.withLockUnchecked { $0.onDetailedEvent }
        handler?(detailed)
    }

    // MARK: - CoreGraphics Window Info Helpers

    private static func fetchOnScreenWindowSnapshots() -> [RawWindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return parseWindowDictionaries(list)
    }

    private static func fetchSingleWindowSnapshot(windowID: CGWindowID) -> RawWindowSnapshot? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let first = list.first
        else {
            return nil
        }
        return parseWindowDictionaries([first]).first
    }

    private static func fetchWindowSnapshotsAbove(windowID: CGWindowID) -> [RawWindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenAboveWindow, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] else {
            return []
        }
        return parseWindowDictionaries(list)
    }

    private static func parseWindowDictionaries(_ dicts: [[String: Any]]) -> [RawWindowSnapshot] {
        // Cache NSRunningApplication metadata per PID within this single scan.
        var appCache: [Int32: (bundleID: String?, path: String?, name: String?)] = [:]
        var result: [RawWindowSnapshot] = []
        result.reserveCapacity(dicts.count)

        for dict in dicts {
            guard let idNum = dict[kCGWindowNumber as String] as? NSNumber,
                  let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }

            let pid = pidNum.int32Value
            let meta: (bundleID: String?, path: String?, name: String?)
            if let cached = appCache[pid] {
                meta = cached
            } else {
                let runningApp = NSRunningApplication(processIdentifier: pid)
                let entry = (
                    bundleID: runningApp?.bundleIdentifier,
                    path: runningApp?.bundleURL?.path ?? runningApp?.executableURL?.path,
                    name: runningApp?.localizedName
                )
                appCache[pid] = entry
                meta = entry
            }

            let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? meta.name ?? "Unknown"
            let title = (dict[kCGWindowName as String] as? String) ?? ""
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            let isOnScreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false

            result.append(RawWindowSnapshot(
                windowID: CGWindowID(idNum.uint32Value),
                pid: pid,
                ownerName: ownerName,
                bundleIdentifier: meta.bundleID,
                appPath: meta.path,
                title: title,
                cgBounds: bounds.standardized,
                layer: layer,
                alpha: alpha,
                isOnScreen: isOnScreen
            ))
        }
        return result
    }

    private static func makeDescriptor(
        from snap: RawWindowSnapshot,
        displays: [DisplayDescriptor],
        excludedBundleIDs: [String],
        ownPID: Int32
    ) -> WindowDescriptor {
        let scale = ScreenGeometry.bestDisplay(forCGRect: snap.cgBounds, in: displays)?.backingScaleFactor ?? 2.0
        let category = classifyOwner(
            pid: snap.pid,
            ownerName: snap.ownerName,
            bundleIdentifier: snap.bundleIdentifier,
            layer: snap.layer,
            bounds: snap.cgBounds,
            displays: displays,
            excludedBundleIDs: excludedBundleIDs,
            ownPID: ownPID
        )
        return WindowDescriptor(
            windowID: snap.windowID,
            pid: snap.pid,
            appName: snap.ownerName,
            bundleIdentifier: snap.bundleIdentifier,
            appPath: snap.appPath,
            title: snap.title,
            cgBounds: snap.cgBounds,
            isOnScreen: snap.isOnScreen,
            isMinimized: !snap.isOnScreen,
            backingScaleFactor: scale,
            ownerCategory: category
        )
    }
}
