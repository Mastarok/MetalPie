import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import MetalPieCore
import ScreenCaptureKit
import os

/// Discovers macOS displays and capturable application windows, combining `ScreenCaptureKit`,
/// `CGWindowListCopyWindowInfo`, and `NSRunningApplication` metadata.
///
/// Key capabilities:
/// - Magpie + MetalGoose system window blacklist (Dock, WindowServer, ControlCenter,
///   NotificationCenter, Spotlight, loginwindow, Wallpaper, status items, `< 64×64` helpers,
///   and MetalPie's own windows).
/// - Wine / CrossOver raised-layer borderless fullscreen detection (`layer > 0` occupying a display).
/// - Multi-monitor `DisplayDescriptor` enumeration anchored on the `(0, 0)` primary display with
///   accurate Retina scale, ProMotion refresh rate, and EDR headroom.
/// - Async window thumbnail capture via `SCScreenshotManager` with fallback support.
public enum WindowEnumerator: Sendable {
    /// Minimum logical point width/height required for a window to be considered capturable.
    public static let minimumWindowDimension: CGFloat = 64.0

    /// Minimum logical point size required for always-on-top / floating PiP video windows (`layer == floatingWindow`).
    public static let minimumFloatingVideoDimension = CGSize(width: 200.0, height: 150.0)

    /// Bundle identifiers permanently classified as macOS system processes / excluded from capture.
    public static let systemBundleIdentifiers: Set<String> = [
        "com.apple.dock",
        "com.apple.windowserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.spotlight",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.windowmanager",
        "com.apple.screencaptureui",
        "com.apple.wallpaper.agent",
        "com.apple.wallpapervideoextension",
        "com.apple.coreservices.uiagent",
        "com.apple.osduihelper",
        "com.apple.textinputmenuagent",
        "com.apple.textinputswitcher",
        "com.apple.universalcontrol",
        "com.apple.securityagent",
        "com.apple.autofillpanelservice",
        "com.apple.accessibility.universalaccessauthwarn"
    ]

    /// Owner/process names permanently classified as system UI chrome.
    public static let systemOwnerNames: Set<String> = [
        "window server",
        "windowserver",
        "dock",
        "control center",
        "controlcenter",
        "notification center",
        "notificationcenter",
        "spotlight",
        "loginwindow",
        "systemuiserver",
        "wallpaper",
        "wallpaperagent",
        "windowmanager",
        "screencaptureui",
        "osduihelper",
        "item-0"
    ]

    /// MetalPie's own bundle identifiers.
    public static let metalPieBundleIdentifiers: Set<String> = [
        "com.metalpie.app"
    ]

    /// Cached snapshot of main-thread `NSScreen` metadata (display names, EDR headroom, refresh rate)
    /// so non-main-thread callers can enumerate displays safely without risking `DispatchQueue.main.sync` deadlocks.
    private static let cachedDisplayMeta = OSAllocatedUnfairLock<[CGDirectDisplayID: CachedScreenMetadata]>(
        initialState: [:]
    )

    private struct CachedScreenMetadata: Sendable {
        var name: String
        var refreshRateHz: Double
        var maxEDRHeadroom: Double
        var backingScaleFactor: Double
        var safeAreaTopInset: Double
    }

    /// Pure, unit-testable top notch-band resolver for `DisplayDescriptor.safeAreaTopInset`.
    /// - On notched displays (`safeAreaTop > 0.5`, e.g. MacBook Pro 14"/16" with 32pt notch), aligns
    ///   with macOS's native fullscreen / menu bar boundary (`menuBarTopInset`, e.g. 33pt -> exact 1512×949)
    ///   when within 12pt of `safeAreaTop`, falling back to `safeAreaTop` when the menu bar is auto-hidden.
    /// - On non-notched displays (`safeAreaTop <= 0.5`), returns `0` so fullscreen fills edge-to-edge.
    public static func resolveNotchSafeTopInset(
        safeAreaTop: Double,
        menuBarTopInset: Double
    ) -> Double {
        let clampedSafe = max(0.0, safeAreaTop)
        guard clampedSafe > 0.5 else { return 0.0 }
        let clampedMenu = max(0.0, menuBarTopInset)
        if clampedMenu >= clampedSafe && clampedMenu <= clampedSafe + 12.0 {
            return clampedMenu
        }
        return clampedSafe
    }

    // MARK: - Multi-Monitor Display Enumeration

    /// Enumerates all active macOS displays using `NSScreen.screens` + `CGDisplayBounds` on the MainActor.
    /// Anchors `isPrimary` on `screens.first { $0.frame.origin == .zero }`.
    @MainActor
    public static func enumerateDisplaysOnMain() -> [DisplayDescriptor] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return enumerateDisplaysViaCoreGraphics()
        }

        let primaryScreen = screens.first {
            abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5
        } ?? screens.first
        let primaryHeight = primaryScreen?.frame.height ?? 0

        var descriptors: [DisplayDescriptor] = []
        descriptors.reserveCapacity(screens.count)

        var newCache: [CGDirectDisplayID: CachedScreenMetadata] = [:]

        for screen in screens {
            guard let displayID = screenDisplayID(for: screen) else { continue }
            let cocoaFrame = screen.frame.standardized
            let cgRawBounds = CGDisplayBounds(displayID).standardized
            let cgBounds: CGRect
            if cgRawBounds.width > 0 && cgRawBounds.height > 0 {
                cgBounds = cgRawBounds
            } else {
                cgBounds = ScreenGeometry.cocoaToCG(rect: cocoaFrame, primaryHeight: primaryHeight)
            }

            let scale = max(1.0, Double(screen.backingScaleFactor))
            let refreshHz: Double
            let maxFPS = screen.maximumFramesPerSecond
            if maxFPS > 0 {
                refreshHz = Double(maxFPS)
            } else if let mode = CGDisplayCopyDisplayMode(displayID), mode.refreshRate > 0 {
                refreshHz = mode.refreshRate
            } else {
                refreshHz = 60.0
            }

            let edrHeadroom = max(
                1.0,
                Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
            )
            let isPrimary = (abs(cocoaFrame.origin.x) < 0.5 && abs(cocoaFrame.origin.y) < 0.5)
                || displayID == CGMainDisplayID()
            let displayName = screen.localizedName.isEmpty
                ? "Display \(displayID)"
                : screen.localizedName
            let rawSafeTop = max(0.0, Double(screen.safeAreaInsets.top))
            let menuBarTopInset = max(0.0, Double(cocoaFrame.maxY - screen.visibleFrame.maxY))
            let safeAreaTopInset = resolveNotchSafeTopInset(
                safeAreaTop: rawSafeTop,
                menuBarTopInset: menuBarTopInset
            )

            descriptors.append(
                DisplayDescriptor(
                    id: displayID,
                    name: displayName,
                    cocoaFrame: cocoaFrame,
                    cgBounds: cgBounds,
                    backingScaleFactor: scale,
                    refreshRateHz: refreshHz,
                    maxEDRHeadroom: edrHeadroom,
                    isPrimary: isPrimary,
                    safeAreaTopInset: safeAreaTopInset
                )
            )

            newCache[displayID] = CachedScreenMetadata(
                name: displayName,
                refreshRateHz: refreshHz,
                maxEDRHeadroom: edrHeadroom,
                backingScaleFactor: scale,
                safeAreaTopInset: safeAreaTopInset
            )
        }

        let finalCache = newCache
        cachedDisplayMeta.withLock { $0 = finalCache }
        return descriptors
    }

    /// Async multi-monitor display enumeration guaranteed to fetch fresh `NSScreen` metadata on `@MainActor`.
    public static func enumerateDisplaysAsync() async -> [DisplayDescriptor] {
        await enumerateDisplaysOnMain()
    }

    /// Synchronous display enumeration safe to invoke from ANY thread (never deadlocks main thread).
    /// When called on the main thread, reads `NSScreen.screens` directly; off-main-thread, queries
    /// CoreGraphics display bounds/modes merged with the latest cached `NSScreen` names/EDR values.
    public static func enumerateDisplays() -> [DisplayDescriptor] {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                enumerateDisplaysOnMain()
            }
        }
        return enumerateDisplaysViaCoreGraphics()
    }

    /// Returns the `CGDirectDisplayID` backing an `NSScreen`.
    @MainActor
    public static func screenDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// Finds the live `NSScreen` matching a `CGDirectDisplayID`.
    @MainActor
    public static func nsScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screenDisplayID(for: $0) == displayID }
    }

    private static func enumerateDisplaysViaCoreGraphics() -> [DisplayDescriptor] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return []
        }
        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return []
        }

        let mainID = CGMainDisplayID()
        let primaryBounds = CGDisplayBounds(mainID).standardized
        let primaryHeight = primaryBounds.height
        let cache = cachedDisplayMeta.withLock { $0 }

        var result: [DisplayDescriptor] = []
        result.reserveCapacity(Int(displayCount))

        for id in displayIDs.prefix(Int(displayCount)) {
            let cgBounds = CGDisplayBounds(id).standardized
            guard cgBounds.width > 0 && cgBounds.height > 0 else { continue }
            let cocoaFrame = ScreenGeometry.cgToCocoa(rect: cgBounds, primaryHeight: primaryHeight)

            let cached = cache[id]
            let mode = CGDisplayCopyDisplayMode(id)
            let inferredScale: Double
            if let cached {
                inferredScale = cached.backingScaleFactor
            } else if let mode, cgBounds.width > 0 {
                inferredScale = max(1.0, Double(mode.pixelWidth) / Double(cgBounds.width))
            } else {
                inferredScale = 1.0
            }

            let refreshHz: Double
            if let cached, cached.refreshRateHz > 0 {
                refreshHz = cached.refreshRateHz
            } else if let mode, mode.refreshRate > 0 {
                refreshHz = mode.refreshRate
            } else {
                refreshHz = 60.0
            }

            let isPrimary = (id == mainID) || (abs(cocoaFrame.origin.x) < 0.5 && abs(cocoaFrame.origin.y) < 0.5)
            result.append(
                DisplayDescriptor(
                    id: id,
                    name: cached?.name ?? (isPrimary ? "Primary Display" : "Display \(id)"),
                    cocoaFrame: cocoaFrame,
                    cgBounds: cgBounds,
                    backingScaleFactor: inferredScale,
                    refreshRateHz: refreshHz,
                    maxEDRHeadroom: cached?.maxEDRHeadroom ?? 1.0,
                    isPrimary: isPrimary,
                    safeAreaTopInset: cached?.safeAreaTopInset ?? 0.0
                )
            )
        }

        return result
    }

    // MARK: - Window Enumeration (ScreenCaptureKit + CoreGraphics + NSRunningApplication)

    /// Rich async window enumeration combining `SCShareableContent` (captures off-space / minimized
    /// windows and accurate SCK window titles) with `CGWindowListCopyWindowInfo` (layer, alpha,
    /// onscreen flags, Wine raised-layer detection) and `NSRunningApplication` metadata.
    ///
    /// - Parameters:
    ///   - includeOffScreen: Include minimized or other-Space windows (default `true`).
    ///   - excludedBundleIDs: Additional user-configured bundle IDs to filter out.
    public static func enumerateWindows(
        includeOffScreen: Bool = true,
        excludedBundleIDs: Set<String> = []
    ) async -> [WindowDescriptor] {
        let displays = await enumerateDisplaysAsync()
        let cgMap = collectCGWindowMetadata(onScreenOnly: !includeOffScreen)

        var scWindowsByID: [CGWindowID: SCWindow] = [:]
        if CGPreflightScreenCaptureAccess() {
            if let content = try? await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: !includeOffScreen
            ) {
                for scWin in content.windows {
                    scWindowsByID[scWin.windowID] = scWin
                }
            }
        }

        return mergeAndFilterWindows(
            cgWindows: cgMap,
            scWindowsByID: scWindowsByID,
            displays: displays,
            includeOffScreen: includeOffScreen,
            excludedBundleIDs: excludedBundleIDs
        )
    }

    /// Synchronous window enumeration powered by `CGWindowListCopyWindowInfo` + `NSRunningApplication`.
    /// Suitable for `WindowLifecycleWatcher` and fallback picker refreshes without awaiting SCK.
    public static func enumerateWindowsSync(
        includeOffScreen: Bool = true,
        excludedBundleIDs: Set<String> = []
    ) -> [WindowDescriptor] {
        let displays = enumerateDisplays()
        let cgMap = collectCGWindowMetadata(onScreenOnly: !includeOffScreen)
        return mergeAndFilterWindows(
            cgWindows: cgMap,
            scWindowsByID: [:],
            displays: displays,
            includeOffScreen: includeOffScreen,
            excludedBundleIDs: excludedBundleIDs
        )
    }

    /// Looks up a single window by `CGWindowID` via CoreGraphics without enumerating all SCK objects.
    public static func windowDescriptor(for windowID: CGWindowID) -> WindowDescriptor? {
        let displays = enumerateDisplays()
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let rawList = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
              let dict = rawList.first,
              let meta = parseCGWindowInfo(dict, zOrder: 0)
        else {
            return nil
        }

        let app = NSRunningApplication(processIdentifier: meta.pid)
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName ?? meta.ownerName
        let appPath = app?.bundleURL?.path ?? app?.executableURL?.path
        let category = classifyOwner(
            pid: meta.pid,
            bundleIdentifier: bundleID,
            ownerName: appName,
            layer: meta.layer,
            bounds: meta.bounds,
            displays: displays
        )
        let bestDisplay = ScreenGeometry.bestDisplay(forCGRect: meta.bounds, in: displays)

        return WindowDescriptor(
            windowID: meta.windowID,
            pid: meta.pid,
            appName: appName,
            bundleIdentifier: bundleID,
            appPath: appPath,
            title: meta.title,
            cgBounds: meta.bounds,
            isOnScreen: meta.isOnScreen,
            isMinimized: !meta.isOnScreen,
            backingScaleFactor: bestDisplay?.backingScaleFactor ?? 2.0,
            ownerCategory: category
        )
    }

    /// Pure, unit-testable candidate metadata for `selectBestTargetWindow(from:displays:)`.
    public struct TargetWindowCandidate: Hashable, Sendable {
        public var windowID: CGWindowID
        public var layer: Int
        public var alpha: Double
        public var bounds: CGRect
        public var zOrder: Int

        public init(
            windowID: CGWindowID,
            layer: Int,
            alpha: Double = 1.0,
            bounds: CGRect,
            zOrder: Int
        ) {
            self.windowID = windowID
            self.layer = layer
            self.alpha = alpha
            self.bounds = bounds.standardized
            self.zOrder = zOrder
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(windowID)
            hasher.combine(layer)
            hasher.combine(alpha)
            hasher.combine(bounds.origin.x)
            hasher.combine(bounds.origin.y)
            hasher.combine(bounds.size.width)
            hasher.combine(bounds.size.height)
            hasher.combine(zOrder)
        }
    }

    /// Pure, unit-testable target selection rule shared by `bestTargetWindow(forPID:displays:)`.
    ///
    /// Priority:
    /// 1. Display-covering fullscreen window (largest visible area among `layer == 0` and valid raised
    ///    fullscreen windows, including MacBook Pro notch-inset fullscreen windows) — prevents selecting
    ///    tiny browser/video-player HUD helper bars over the actual fullscreen video window!
    /// 2. Topmost substantial `layer == 0` window (`>= 200×150`) over tiny helper strips (`64×64..199×149`).
    /// 3. Topmost `layer == 0` window (`>= 64×64`).
    public static func selectBestTargetWindow(
        from candidates: [TargetWindowCandidate],
        displays: [DisplayDescriptor]
    ) -> TargetWindowCandidate? {
        let visible = candidates.filter {
            $0.alpha > 0.01
                && $0.bounds.width >= minimumWindowDimension
                && $0.bounds.height >= minimumWindowDimension
        }
        guard !visible.isEmpty else { return nil }

        // 1. Prefer display-covering fullscreen windows (strict full-display first, then notch-inset fullscreen).
        let strictFullscreen = visible.filter { candidate in
            let isEligibleLayer = (candidate.layer == 0)
                || isRaisedFullscreenWindow(
                    layer: candidate.layer,
                    alpha: candidate.alpha,
                    bounds: candidate.bounds,
                    displays: displays
                )
            guard isEligibleLayer else { return false }
            return displays.contains {
                boundsCoversDisplay(candidate.bounds, displayBounds: $0.cgBounds, tolerance: 4.0)
            }
        }
        if let bestStrict = strictFullscreen.max(by: { lhs, rhs in
            let lArea = lhs.bounds.width * lhs.bounds.height
            let rArea = rhs.bounds.width * rhs.bounds.height
            if abs(lArea - rArea) > 1.0 {
                return lArea < rArea
            }
            return lhs.zOrder > rhs.zOrder
        }) {
            return bestStrict
        }

        let notchFullscreen = visible.filter { candidate in
            let maxAllowedLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
            guard candidate.layer >= 0 && candidate.layer < maxAllowedLayer else { return false }
            return isNotchInsetFullscreenBounds(candidate.bounds, displays: displays)
        }
        if let bestNotch = notchFullscreen.max(by: { lhs, rhs in
            let lArea = lhs.bounds.width * lhs.bounds.height
            let rArea = rhs.bounds.width * rhs.bounds.height
            if abs(lArea - rArea) > 1.0 {
                return lArea < rArea
            }
            return lhs.zOrder > rhs.zOrder
        }) {
            return bestNotch
        }

        // 2. Among normal layer-0 windows, prefer substantial content windows over tiny helper bars.
        let normalCandidates = visible.filter { $0.layer == 0 }
        let substantial = normalCandidates.filter { $0.bounds.width >= 200.0 && $0.bounds.height >= 150.0 }
        if let topSubstantial = substantial.min(by: { $0.zOrder < $1.zOrder }) {
            return topSubstantial
        }
        if let topNormal = normalCandidates.min(by: { $0.zOrder < $1.zOrder }) {
            return topNormal
        }

        // 3. Fallback: substantial floating / always-on-top / PiP video windows (`layer == floatingWindow`, >= 200x150).
        let floatingVideoCandidates = visible.filter {
            isSubstantialFloatingAppWindow(layer: $0.layer, alpha: $0.alpha, bounds: $0.bounds)
        }
        if let topFloating = floatingVideoCandidates.min(by: { $0.zOrder < $1.zOrder }) {
            return topFloating
        }
        return nil
    }

    /// Returns `true` when `bounds` matches a macOS native fullscreen window sitting flush below a
    /// MacBook Pro camera notch (edge-to-edge horizontally, flush to bottom, top inset `<= 44pt`).
    public static func isNotchInsetFullscreenBounds(
        _ bounds: CGRect,
        displays: [DisplayDescriptor],
        maxTopInset: CGFloat = 44.0,
        tolerance: CGFloat = 4.0
    ) -> Bool {
        let normalized = bounds.standardized
        guard !normalized.isEmpty else { return false }
        return displays.contains { display in
            let db = display.cgBounds.standardized
            guard db.width > 0 && db.height > 0 else { return false }
            let topInset = normalized.minY - db.minY
            return normalized.minX <= db.minX + tolerance
                && normalized.maxX >= db.maxX - tolerance
                && normalized.maxY >= db.maxY - tolerance
                && topInset >= -tolerance
                && topInset <= maxTopInset
        }
    }

    /// Finds the best capturable window owned by a given process ID, preferring display-covering
    /// fullscreen video/game windows over smaller helper/HUD bars, and handling Wine / CrossOver
    /// raised-layer borderless fullscreen windows.
    public static func bestTargetWindow(
        forPID pid: Int32,
        displays: [DisplayDescriptor]? = nil
    ) -> WindowDescriptor? {
        let resolvedDisplays = displays ?? enumerateDisplays()
        let allCG = collectCGWindowMetadata(onScreenOnly: true).filter { $0.pid == pid }
        guard !allCG.isEmpty else { return nil }

        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName ?? allCG[0].ownerName
        let appPath = app?.bundleURL?.path ?? app?.executableURL?.path

        let candidates = allCG.map {
            TargetWindowCandidate(
                windowID: $0.windowID,
                layer: $0.layer,
                alpha: $0.alpha,
                bounds: $0.bounds,
                zOrder: $0.zOrder
            )
        }
        guard let chosen = selectBestTargetWindow(from: candidates, displays: resolvedDisplays),
              let meta = allCG.first(where: { $0.windowID == chosen.windowID })
        else {
            return nil
        }

        let display = ScreenGeometry.bestDisplay(forCGRect: meta.bounds, in: resolvedDisplays)
        return WindowDescriptor(
            windowID: meta.windowID,
            pid: meta.pid,
            appName: appName,
            bundleIdentifier: bundleID,
            appPath: appPath,
            title: meta.title,
            cgBounds: meta.bounds,
            isOnScreen: meta.isOnScreen,
            isMinimized: !meta.isOnScreen,
            backingScaleFactor: display?.backingScaleFactor ?? 2.0,
            ownerCategory: .application
        )
    }

    // MARK: - Classification & Fullscreen Helpers

    /// Returns `true` when a raised-layer window (`layer > 0`) occupies a full display
    /// (typical of Wine / CrossOver / Whisky borderless fullscreen games).
    public static func isRaisedFullscreenWindow(
        layer: Int,
        alpha: Double,
        bounds: CGRect,
        displays: [DisplayDescriptor]
    ) -> Bool {
        guard layer > 0,
              alpha > 0.01,
              bounds.width >= minimumWindowDimension,
              bounds.height >= minimumWindowDimension
        else {
            return false
        }
        // Reject extreme system shield/cursor/screensaver levels.
        let maxAllowedLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
        guard layer < maxAllowedLayer else { return false }

        return displays.contains { display in
            boundsCoversDisplay(bounds, displayBounds: display.cgBounds, tolerance: 2.0)
        }
    }

    /// Returns `true` if `windowBounds` covers virtually the entire `displayBounds`
    /// (used for Wine raised-layer fullscreen detection and native macOS Full-Screen Space detection).
    public static func boundsCoversDisplay(
        _ windowBounds: CGRect,
        displayBounds: CGRect,
        tolerance: CGFloat = 2.0
    ) -> Bool {
        guard displayBounds.width > 0 && displayBounds.height > 0 else { return false }
        let expanded = windowBounds.standardized.insetBy(dx: -tolerance, dy: -tolerance)
        return expanded.contains(displayBounds.standardized)
    }

    /// Returns `true` when a floating-level window (`layer == floatingWindow` = 3, e.g. IINA/VLC/QuickTime
    /// "Float on Top" or browser Picture-in-Picture) is substantial enough (`>= 200×150`) to capture.
    public static func isSubstantialFloatingAppWindow(
        layer: Int,
        alpha: Double,
        bounds: CGRect
    ) -> Bool {
        let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))
        let normalized = bounds.standardized
        return layer == floatingLayer
            && alpha > 0.01
            && normalized.width >= minimumFloatingVideoDimension.width
            && normalized.height >= minimumFloatingVideoDimension.height
    }

    /// Pure, unit-testable decision rule for `isLikelyNativeFullscreenWindow(windowID:bounds:displays:)`.
    /// When `axFullScreenAttribute` is known (`true`/`false`), it is authoritative — distinguishing
    /// MacBook Pro notch-inset native fullscreen video (`(0, 33, 1512, 949)` with `AXFullScreen == true`)
    /// from maximized desktop browser windows (`(0, 33, 1512, 949)` with `AXFullScreen == false`).
    public static func resolveNativeFullscreenClassification(
        axFullScreenAttribute: Bool?,
        windowLayer: Int?,
        bounds: CGRect,
        displays: [DisplayDescriptor]
    ) -> Bool {
        if let axFullScreen = axFullScreenAttribute {
            return axFullScreen
        }
        guard let display = ScreenGeometry.bestDisplay(forCGRect: bounds, in: displays) else {
            return false
        }
        guard boundsCoversDisplay(bounds, displayBounds: display.cgBounds, tolerance: 2.0) else {
            return false
        }
        return (windowLayer ?? 0) == 0
    }

    /// Pure, unit-testable decision rule for `isFullscreenVideoOrGameWindow(windowID:bounds:displays:)`.
    /// Returns `true` for EITHER native macOS Full-Screen Space (`AXFullScreen == true`, including
    /// below a MacBook Pro notch) OR exact full-bleed `boundsCoversDisplay(tolerance: 2.0)` windows
    /// on Desktop Space (e.g. IINA/VLC/mpv Legacy Fullscreen and Wine/CrossOver borderless games).
    public static func resolveFullscreenVideoOrGameClassification(
        axFullScreenAttribute: Bool?,
        windowLayer: Int?,
        bounds: CGRect,
        displays: [DisplayDescriptor]
    ) -> Bool {
        if axFullScreenAttribute == true {
            return true
        }
        guard let display = ScreenGeometry.bestDisplay(forCGRect: bounds, in: displays) else {
            return false
        }
        guard boundsCoversDisplay(bounds, displayBounds: display.cgBounds, tolerance: 2.0) else {
            return false
        }
        let maxAllowedLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
        let layer = windowLayer ?? 0
        return layer >= 0 && layer < maxAllowedLayer
    }

    /// Detects whether a window occupies a native macOS Full-Screen Space.
    /// Uses AX `"AXFullScreen"` when Accessibility is trusted (handling MacBook Pro notch-inset
    /// `(0, 33, 1512, 949)` native fullscreen cleanly without misclassifying maximized desktop windows),
    /// falling back to exact `boundsCoversDisplay(tolerance: 2.0)` + `layer == 0` when AX is unavailable.
    public static func isLikelyNativeFullscreenWindow(
        windowID: CGWindowID,
        bounds: CGRect,
        displays: [DisplayDescriptor]
    ) -> Bool {
        guard let display = ScreenGeometry.bestDisplay(forCGRect: bounds, in: displays) else {
            return false
        }
        let isFullBleed = boundsCoversDisplay(bounds, displayBounds: display.cgBounds, tolerance: 2.0)
        let isNotchCandidate = isFullBleed || isNotchInsetFullscreenBounds(bounds, displays: [display])
        guard isNotchCandidate else {
            return false
        }

        let (pid, layer) = lookupCGWindowPIDAndLayer(windowID: windowID)
        let axFullScreen = pid.flatMap { queryAXFullScreenAttribute(windowID: windowID, pid: $0) }
        return resolveNativeFullscreenClassification(
            axFullScreenAttribute: axFullScreen,
            windowLayer: layer,
            bounds: bounds,
            displays: displays
        )
    }

    /// Returns `true` when `windowID` is EITHER a native macOS Full-Screen Space window
    /// (`AXFullScreen == true`, including MacBook Pro notch-inset fullscreen video) OR an exact
    /// full-bleed Desktop Space fullscreen video/game window (IINA/VLC/mpv Legacy Fullscreen,
    /// Wine/CrossOver borderless games). Returns `false` for normal maximized desktop browsers.
    public static func isFullscreenVideoOrGameWindow(
        windowID: CGWindowID,
        bounds: CGRect,
        displays: [DisplayDescriptor]
    ) -> Bool {
        guard let display = ScreenGeometry.bestDisplay(forCGRect: bounds, in: displays) else {
            return false
        }
        let isFullBleed = boundsCoversDisplay(bounds, displayBounds: display.cgBounds, tolerance: 2.0)
        let isNotchCandidate = isFullBleed || isNotchInsetFullscreenBounds(bounds, displays: [display])
        guard isNotchCandidate else {
            return false
        }

        let (pid, layer) = lookupCGWindowPIDAndLayer(windowID: windowID)
        let axFullScreen = pid.flatMap { queryAXFullScreenAttribute(windowID: windowID, pid: $0) }
        return resolveFullscreenVideoOrGameClassification(
            axFullScreenAttribute: axFullScreen,
            windowLayer: layer,
            bounds: bounds,
            displays: displays
        )
    }

    private static func lookupCGWindowPIDAndLayer(windowID: CGWindowID) -> (pid: Int32?, layer: Int?) {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let list = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
              let first = list.first
        else {
            return (nil, nil)
        }
        let pid = (first[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let layer = (first[kCGWindowLayer as String] as? NSNumber)?.intValue
        return (pid, layer)
    }

    private static func queryAXFullScreenAttribute(windowID: CGWindowID, pid: Int32) -> Bool? {
        guard AXIsProcessTrusted(),
              pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }

        typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, "_AXUIElementGetWindow") else {
            return nil
        }
        let getWindowID = unsafeBitCast(sym, to: AXGetWindowFn.self)

        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElem, 0.15)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else {
            return nil
        }

        for axWin in axWindows {
            var candidateID: CGWindowID = 0
            if getWindowID(axWin, &candidateID) == .success && candidateID == windowID {
                var fsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axWin, "AXFullScreen" as CFString, &fsRef) == .success,
                      let fsRef
                else {
                    return nil
                }
                if let boolVal = fsRef as? Bool {
                    return boolVal
                }
                if let numVal = fsRef as? NSNumber {
                    return numVal.boolValue
                }
                return nil
            }
        }
        return nil
    }

    /// Classifies a window owner against MetalPie's own PID/bundle and macOS system blacklists.
    public static func classifyOwner(
        pid: Int32,
        bundleIdentifier: String?,
        ownerName: String,
        layer: Int,
        bounds: CGRect,
        displays: [DisplayDescriptor]
    ) -> WindowOwnerCategory {
        if pid == ProcessInfo.processInfo.processIdentifier {
            return .metalPie
        }

        if let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !bundle.isEmpty
        {
            if let ownBundle = Bundle.main.bundleIdentifier?.lowercased(), bundle == ownBundle {
                return .metalPie
            }
            if metalPieBundleIdentifiers.contains(bundle) {
                return .metalPie
            }
            if systemBundleIdentifiers.contains(bundle) {
                return .system
            }
            // Filter Finder desktop backdrop window while keeping real Finder windows capturable.
            if bundle == "com.apple.finder" && layer < 0 {
                return .system
            }
        }

        let loweredOwner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if systemOwnerNames.contains(loweredOwner) {
            return .system
        }

        if layer < 0 {
            return .system
        }
        if layer > 0
            && !isRaisedFullscreenWindow(layer: layer, alpha: 1.0, bounds: bounds, displays: displays)
            && !isSubstantialFloatingAppWindow(layer: layer, alpha: 1.0, bounds: bounds)
        {
            return .overlay
        }

        return .application
    }

    // MARK: - Window Picker Thumbnail Capture

    /// Captures a scaled thumbnail `CGImage` for the specified window for display in the UI window picker.
    /// Uses `SCScreenshotManager.captureImage` (macOS 14.0+) without shadows or cursor.
    public static func captureThumbnail(
        for windowID: CGWindowID,
        maxDimension: Int = 480
    ) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else {
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let frame = scWindow.frame
            let safeMax = max(64, maxDimension)

            if frame.width > 0 && frame.height > 0 {
                let scale = min(1.0, Double(safeMax) / Double(max(frame.width, frame.height)))
                config.width = max(32, Int((Double(frame.width) * scale).rounded()))
                config.height = max(32, Int((Double(frame.height) * scale).rounded()))
            } else {
                config.width = safeMax
                config.height = max(32, (safeMax * 9) / 16)
            }

            config.scalesToFit = true
            config.preservesAspectRatio = true
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.captureResolution = .nominal

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            PipelineLog.shared.debug(
                .capture,
                "SCScreenshotManager thumbnail failed for window \(windowID): \(error.localizedDescription); trying fallback."
            )
            return captureThumbnailFallback(for: windowID, maxDimension: maxDimension)
        }
    }

    /// Best-effort dynamic `CGWindowListCreateImage` fallback for window thumbnails when
    /// `SCScreenshotManager` fails, resolved via `dlsym` to stay warning-free on macOS 15–27 SDKs.
    private static func captureThumbnailFallback(
        for windowID: CGWindowID,
        maxDimension: Int
    ) -> CGImage? {
        typealias CreateImageFn = @convention(c) (
            CGRect,
            CGWindowListOption,
            CGWindowID,
            CGWindowImageOption
        ) -> Unmanaged<CGImage>?

        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        let fn = unsafeBitCast(sym, to: CreateImageFn.self)
        guard let rawImage = fn(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )?.takeRetainedValue() else {
            return nil
        }

        let safeMax = max(64, maxDimension)
        let w = rawImage.width
        let h = rawImage.height
        guard w > 0 && h > 0 else { return nil }
        if max(w, h) <= safeMax {
            return rawImage
        }

        let scale = Double(safeMax) / Double(max(w, h))
        let dstW = max(1, Int((Double(w) * scale).rounded()))
        let dstH = max(1, Int((Double(h) * scale).rounded()))
        let colorSpace = rawImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: dstW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return rawImage
        }
        ctx.interpolationQuality = .medium
        ctx.draw(rawImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        return ctx.makeImage() ?? rawImage
    }

    // MARK: - Private Merging & Parsing

    private struct CGWindowMeta: Sendable {
        var windowID: CGWindowID
        var pid: Int32
        var ownerName: String
        var title: String
        var bounds: CGRect
        var layer: Int
        var alpha: Double
        var isOnScreen: Bool
        var zOrder: Int
    }

    private static func collectCGWindowMetadata(onScreenOnly: Bool) -> [CGWindowMeta] {
        var options: CGWindowListOption = [.excludeDesktopElements]
        if onScreenOnly {
            options.insert(.optionOnScreenOnly)
        } else {
            options.insert(.optionAll)
        }

        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [CGWindowMeta] = []
        result.reserveCapacity(rawList.count)
        for (idx, dict) in rawList.enumerated() {
            if let meta = parseCGWindowInfo(dict, zOrder: idx) {
                result.append(meta)
            }
        }
        return result
    }

    private static func parseCGWindowInfo(_ dict: [String: Any], zOrder: Int) -> CGWindowMeta? {
        guard let windowNumber = dict[kCGWindowNumber as String] as? UInt32,
              let ownerPID = dict[kCGWindowOwnerPID as String] as? Int32,
              let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else {
            return nil
        }

        let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
        let title = (dict[kCGWindowName as String] as? String) ?? ""
        let layer = (dict[kCGWindowLayer as String] as? Int) ?? 0
        let alpha = (dict[kCGWindowAlpha as String] as? Double) ?? 1.0
        let isOnScreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false

        return CGWindowMeta(
            windowID: CGWindowID(windowNumber),
            pid: ownerPID,
            ownerName: ownerName,
            title: title,
            bounds: bounds.standardized,
            layer: layer,
            alpha: alpha,
            isOnScreen: isOnScreen,
            zOrder: zOrder
        )
    }

    private static func mergeAndFilterWindows(
        cgWindows: [CGWindowMeta],
        scWindowsByID: [CGWindowID: SCWindow],
        displays: [DisplayDescriptor],
        includeOffScreen: Bool,
        excludedBundleIDs: Set<String>
    ) -> [WindowDescriptor] {
        let loweredExcluded = Set(excludedBundleIDs.map { $0.lowercased() })
        let cgByID = Dictionary(uniqueKeysWithValues: cgWindows.map { ($0.windowID, $0) })

        // Cache NSRunningApplication lookups per PID.
        var appCache: [Int32: NSRunningApplication] = [:]
        func runningApp(for pid: Int32) -> NSRunningApplication? {
            if let cached = appCache[pid] {
                return cached
            }
            if let found = NSRunningApplication(processIdentifier: pid) {
                appCache[pid] = found
                return found
            }
            return nil
        }

        var descriptors: [(zOrder: Int, descriptor: WindowDescriptor)] = []
        var seenIDs = Set<CGWindowID>()

        // Pass 1: Iterate CG windows in front-to-back z-order, enriching with SCWindow metadata.
        for cg in cgWindows {
            seenIDs.insert(cg.windowID)
            let scWin = scWindowsByID[cg.windowID]

            let bounds = cg.bounds
            guard bounds.width >= minimumWindowDimension,
                  bounds.height >= minimumWindowDimension,
                  cg.alpha > 0.01
            else {
                continue
            }

            let isOnScreen = scWin?.isOnScreen ?? cg.isOnScreen
            if !includeOffScreen && !isOnScreen {
                continue
            }

            // Accept layer == 0, Wine/CrossOver raised-layer fullscreen, or substantial floating/PiP video window.
            let isAllowedLayer = (cg.layer == 0)
                || isRaisedFullscreenWindow(
                    layer: cg.layer,
                    alpha: cg.alpha,
                    bounds: bounds,
                    displays: displays
                )
                || isSubstantialFloatingAppWindow(
                    layer: cg.layer,
                    alpha: cg.alpha,
                    bounds: bounds
                )
            guard isAllowedLayer else { continue }

            let app = runningApp(for: cg.pid)
            let bundleID = scWin?.owningApplication?.bundleIdentifier ?? app?.bundleIdentifier
            let appName = app?.localizedName
                ?? scWin?.owningApplication?.applicationName
                ?? cg.ownerName
            let appPath = app?.bundleURL?.path ?? app?.executableURL?.path

            let category = classifyOwner(
                pid: cg.pid,
                bundleIdentifier: bundleID,
                ownerName: appName,
                layer: cg.layer,
                bounds: bounds,
                displays: displays
            )
            guard category == .application else { continue }

            if let b = bundleID?.lowercased(), loweredExcluded.contains(b) {
                continue
            }

            // Filter empty Finder desktop backdrop window that may appear at layer 0 on some macOS builds.
            let title = {
                if let scTitle = scWin?.title, !scTitle.isEmpty { return scTitle }
                return cg.title
            }()
            if bundleID?.lowercased() == "com.apple.finder" && title.isEmpty {
                let coversDesktop = displays.contains {
                    boundsCoversDisplay(bounds, displayBounds: $0.cgBounds, tolerance: 2.0)
                }
                if coversDesktop { continue }
            }

            // Skip accessory/agent processes that aren't normal user apps unless they have a visible title
            // or occupy a raised fullscreen surface (Wine/CrossOver/SDL binaries often run as unbundled procs).
            if let app, app.activationPolicy == .prohibited {
                continue
            }

            let display = ScreenGeometry.bestDisplay(forCGRect: bounds, in: displays)
            let descriptor = WindowDescriptor(
                windowID: cg.windowID,
                pid: cg.pid,
                appName: appName.isEmpty ? "App (\(cg.pid))" : appName,
                bundleIdentifier: bundleID,
                appPath: appPath,
                title: title,
                cgBounds: bounds,
                isOnScreen: isOnScreen,
                isMinimized: !isOnScreen,
                backingScaleFactor: display?.backingScaleFactor ?? 2.0,
                ownerCategory: category
            )
            descriptors.append((cg.zOrder, descriptor))
        }

        // Pass 2: Include any SCWindow not present in CG list (e.g. windows on other Spaces when includeOffScreen == true).
        if includeOffScreen {
            var fallbackZ = cgWindows.count
            for (windowID, scWin) in scWindowsByID where !seenIDs.contains(windowID) && cgByID[windowID] == nil {
                let bounds = scWin.frame.standardized
                guard bounds.width >= minimumWindowDimension,
                      bounds.height >= minimumWindowDimension
                else {
                    continue
                }

                let pid = scWin.owningApplication?.processID ?? 0
                guard pid > 0 else { continue }
                let app = runningApp(for: pid)
                let bundleID = scWin.owningApplication?.bundleIdentifier ?? app?.bundleIdentifier
                let appName = app?.localizedName
                    ?? scWin.owningApplication?.applicationName
                    ?? "App (\(pid))"
                let appPath = app?.bundleURL?.path ?? app?.executableURL?.path

                let layer = scWin.windowLayer
                let isAllowedLayer = (layer == 0)
                    || isRaisedFullscreenWindow(
                        layer: layer,
                        alpha: 1.0,
                        bounds: bounds,
                        displays: displays
                    )
                    || isSubstantialFloatingAppWindow(
                        layer: layer,
                        alpha: 1.0,
                        bounds: bounds
                    )
                guard isAllowedLayer else { continue }

                let category = classifyOwner(
                    pid: pid,
                    bundleIdentifier: bundleID,
                    ownerName: appName,
                    layer: layer,
                    bounds: bounds,
                    displays: displays
                )
                guard category == .application else { continue }
                if let b = bundleID?.lowercased(), loweredExcluded.contains(b) {
                    continue
                }

                let display = ScreenGeometry.bestDisplay(forCGRect: bounds, in: displays)
                let descriptor = WindowDescriptor(
                    windowID: windowID,
                    pid: pid,
                    appName: appName,
                    bundleIdentifier: bundleID,
                    appPath: appPath,
                    title: scWin.title ?? "",
                    cgBounds: bounds,
                    isOnScreen: scWin.isOnScreen,
                    isMinimized: !scWin.isOnScreen,
                    backingScaleFactor: display?.backingScaleFactor ?? 2.0,
                    ownerCategory: category
                )
                descriptors.append((fallbackZ, descriptor))
                fallbackZ += 1
            }
        }

        // Sort: on-screen windows first (in natural front-to-back z-order), then minimized/other-Space windows.
        descriptors.sort { lhs, rhs in
            if lhs.descriptor.isOnScreen != rhs.descriptor.isOnScreen {
                return lhs.descriptor.isOnScreen
            }
            return lhs.zOrder < rhs.zOrder
        }

        return descriptors.map(\.descriptor)
    }
}
