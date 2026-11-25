import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import MetalPieCore
import ScreenCaptureKit
import os

// MARK: - Async Serial Gate

/// FIFO async mutual-exclusion actor that serializes `SCStream` lifecycle mutations
/// (`start`, `updateConfiguration`, `stop`, live resize updates) across `await` suspension points.
public actor AsyncSerialGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }
}

// MARK: - Supporting Capture Types

/// Retains both the `CVMetalTexture` and underlying `CVPixelBuffer` inside `CapturedFrame.backingObject`
/// until the GPU command buffer finishes (`commandBuffer.addCompletedHandler`), preventing SCK's
/// IOSurface pool from recycling the buffer mid-render.
public final class CapturedFrameBacking: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let cvMetalTexture: CVMetalTexture
    public let surfaceID: IOSurfaceID

    public init(
        pixelBuffer: CVPixelBuffer,
        cvMetalTexture: CVMetalTexture,
        surfaceID: IOSurfaceID
    ) {
        self.pixelBuffer = pixelBuffer
        self.cvMetalTexture = cvMetalTexture
        self.surfaceID = surfaceID
    }
}

/// Strategy for handling 1x non-Retina content magnified 2x by WindowServer (common in Wine / CrossOver / retro apps).
public enum NonRetinaDetectionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Automatically probes the first few frames on GPU (zero CPU pixel lock) to detect 2x magnified 1x content.
    case auto
    /// Treats content as native 1x half-resolution on 2x Retina displays.
    case force1x
    /// Always keeps full Retina capture resolution.
    case force2x

    public var id: String { rawValue }
}

/// Result of GPU-based 1x non-Retina magnification probing.
public enum DetectedContentResolution: String, Hashable, Codable, Sendable {
    /// Native full-resolution content (e.g. crisp Retina rendering).
    case nativeFull
    /// 1x content magnified 2x via nearest-neighbor by macOS WindowServer.
    case magnifiedNearest2x
    /// 1x content magnified 2x via bilinear filtering by macOS WindowServer.
    case magnifiedBilinear2x
}

// MARK: - ScreenCaptureEngine

/// Zero-copy `ScreenCaptureKit` capture engine implementing `FrameCaptureSession`.
///
/// Architectural guarantees solving MetalDuck & MetalGoose macOS pitfalls:
/// - **Zero CPU pixel reads** on the hot path (never calls `CVPixelBufferLockBaseAddress` or `memcmp`).
/// - **Dimension+Format-checked IOSurface cache** backed by `CVMetalTextureCache` with periodic
///   `CVMetalTextureCacheFlush` and strict `CapturedFrameBacking` retention until GPU completion.
/// - **Live `stream.updateConfiguration`** on ANY pixel-size, scale, FPS, HDR, cursor, shadow,
///   or display change (including proportional window resizes).
/// - **Serialized async lifecycle** via `AsyncSerialGate` + monotonic session tokens so errors
///   during startup are never silently dropped and stale callbacks never tear down new sessions.
/// - **Zero-IPC window geometry tracking** via `SCStreamFrameInfo.screenRect` & `contentScale`.
/// - **Optional GPU-only 1x non-Retina content probe** for Wine/CrossOver titles.
public final class ScreenCaptureEngine: NSObject, FrameCaptureSession, @unchecked Sendable {
    private struct SurfaceKey: Hashable, Sendable {
        var surfaceID: IOSurfaceID
        var width: Int
        var height: Int
        var pixelFormat: MTLPixelFormat
    }

    private struct AppliedStreamConfig: Equatable, Sendable {
        var captureMode: CaptureMode
        var windowID: CGWindowID
        var displayID: CGDirectDisplayID
        var usesDisplayScopedWindowCapture: Bool
        var sourceRect: CGRect?
        var pixelWidth: Int
        var pixelHeight: Int
        var backingScaleFactor: Double
        var cvPixelFormat: OSType
        var dynamicRange: DynamicRangeMode
        var colorSpaceName: String
        var frameRateLimit: Int?
        var effectiveFrameRateCap: Int
        var showsCursor: Bool
        var ignoreShadows: Bool
        var queueDepth: Int
    }

    private struct RuntimeState: Sendable {
        var isRunning: Bool = false
        var isPaused: Bool = false
        var sessionToken: UInt64 = 0
        var activeWindow: WindowDescriptor?
        var activeProfile: Profile?
        var activeScalingMode: ScalingMode?
        var appliedConfig: AppliedStreamConfig?
        var detectedChildWindowShrink: Bool = false
        var lastReportedScreenRect: CGRect = .zero
        var lastFrameHostTime: CFAbsoluteTime = 0
        var frameCount: UInt64 = 0
        var hasLoggedStaleWarning: Bool = false
        var nonRetinaMode: NonRetinaDetectionMode = .auto
        var detectedContentResolution: DetectedContentResolution = .nativeFull
        var nonRetinaProbesCompleted: Int = 0
        var nonRetinaFramesSinceReset: UInt64 = 0
        var nonRetinaProbeInFlight: Bool = false
        var onFrame: (@Sendable (CapturedFrame) -> Void)?
        var onEvent: (@Sendable (CaptureSessionEvent) -> Void)?
        var onContentResolutionChanged: (@Sendable (DetectedContentResolution) -> Void)?
    }

    /// ScreenCaptureKit benign stop codes:
    /// - `-3808`: `SCStreamErrorUserStopped` / stopped on request
    /// - `-3817`: stopped via macOS menu bar screen-sharing indicator
    private static let benignSCKStopCodes: Set<Int> = [-3808, -3817]
    private static let cacheFlushIntervalFrames: UInt64 = 120
    private static let maxNonRetinaProbes = 3
    private static let resizeDebounceMilliseconds = 180
    private static let fastResizeDebounceMilliseconds = 40

    private struct PendingResizeState: Sendable {
        var task: Task<Void, Never>?
        var generation: UInt64 = 0
    }

    private let device: any MTLDevice
    private let pipelineDepth: Int
    private let gate = AsyncSerialGate()
    private let state = OSAllocatedUnfairLock(initialState: RuntimeState())
    private let pendingResizeLock = OSAllocatedUnfairLock(initialState: PendingResizeState())

    private let sampleQueue = DispatchQueue(
        label: "com.metalpie.capture.sample",
        qos: .userInteractive
    )
    private let monitorQueue = DispatchQueue(
        label: "com.metalpie.capture.monitor",
        qos: .utility
    )

    // Accessed exclusively inside `gate` or `sampleQueue` as documented below.
    private var activeStream: SCStream?
    private var textureCache: CVMetalTextureCache?
    private var surfaceRegistry: [IOSurfaceID: SurfaceKey] = [:]
    private var staleMonitorTimer: DispatchSourceTimer?

    // Lazy GPU-only probe resources (zero CPU pixel lock).
    private let probeQueue: (any MTLCommandQueue)?
    private var probePipeline: (any MTLComputePipelineState)?
    private var probeDidAttemptCompile = false

    public init(
        device: (any MTLDevice)? = nil,
        pipelineDepth: Int = 2,
        nonRetinaMode: NonRetinaDetectionMode = .auto
    ) throws {
        guard let resolvedDevice = device ?? MTLCreateSystemDefaultDevice() else {
            throw EngineError.metalDeviceUnavailable
        }
        self.device = resolvedDevice
        self.pipelineDepth = max(1, min(pipelineDepth, 4))
        self.probeQueue = resolvedDevice.makeCommandQueue()
        super.init()

        self.state.withLock { $0.nonRetinaMode = nonRetinaMode }

        var cacheOut: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            resolvedDevice,
            nil,
            &cacheOut
        )
        if cacheStatus == kCVReturnSuccess, let cacheOut {
            self.textureCache = cacheOut
        } else {
            PipelineLog.shared.error(
                .capture,
                "Failed to create CVMetalTextureCache (CVReturn \(cacheStatus))."
            )
        }
    }

    deinit {
        staleMonitorTimer?.cancel()
        cancelPendingResizeTask()
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    // MARK: - Public Inspection & Controls

    public var isRunning: Bool {
        state.withLock(\.isRunning)
    }

    public var nonRetinaMode: NonRetinaDetectionMode {
        get { state.withLock(\.nonRetinaMode) }
        set {
            let resolved: DetectedContentResolution? = state.withLock { s in
                s.nonRetinaMode = newValue
                switch newValue {
                case .force1x:
                    s.detectedContentResolution = .magnifiedNearest2x
                    return .magnifiedNearest2x
                case .force2x:
                    s.detectedContentResolution = .nativeFull
                    return .nativeFull
                case .auto:
                    s.nonRetinaProbesCompleted = 0
                    s.nonRetinaFramesSinceReset = 0
                    return nil
                }
            }
            if let resolved {
                let cb = state.withLock(\.onContentResolutionChanged)
                cb?(resolved)
            }
        }
    }

    public var detectedContentResolution: DetectedContentResolution {
        state.withLock(\.detectedContentResolution)
    }

    /// Optional callback fired whenever GPU 1x non-Retina detection settles or changes.
    public func setContentResolutionHandler(
        _ handler: (@Sendable (DetectedContentResolution) -> Void)?
    ) {
        state.withLock { $0.onContentResolutionChanged = handler }
    }

    /// Pure, unit-testable converter returning the display-local `SCStreamConfiguration.sourceRect`
    /// for a window on `displayCGBounds` (required by ScreenCaptureKit on both primary and secondary
    /// negative-CG-Y monitors so `SCContentFilter(display:...)` never throws `-3812`).
    /// Returns `nil` if the window is mostly off-display (< 50% area) or smaller than 64×64 pt.
    public static func computeDisplayLocalSourceRect(
        windowCGRect: CGRect,
        displayCGBounds: CGRect
    ) -> CGRect? {
        let win = windowCGRect.standardized
        let disp = displayCGBounds.standardized
        guard win.width >= 64, win.height >= 64, disp.width >= 64, disp.height >= 64 else {
            return nil
        }
        let inter = win.intersection(disp)
        guard !inter.isNull, inter.width >= 64, inter.height >= 64 else {
            return nil
        }
        let winArea = win.width * win.height
        let interArea = inter.width * inter.height
        guard winArea > 0, (interArea / winArea) >= 0.5 else {
            return nil
        }

        let localX = min(max(0.0, (inter.minX - disp.minX).rounded()), max(0.0, disp.width - 1.0))
        let localY = min(max(0.0, (inter.minY - disp.minY).rounded()), max(0.0, disp.height - 1.0))
        let localW = min(max(1.0, inter.width.rounded()), disp.width - localX)
        let localH = min(max(1.0, inter.height.rounded()), disp.height - localY)
        guard localW >= 64, localH >= 64 else {
            return nil
        }
        return CGRect(x: localX, y: localY, width: localW, height: localH)
    }

    /// Returns `true` when `windowCGRect` lies completely inside `displayCGBounds` (within `tolerance` pt),
    /// meaning a display-scoped `sourceRect` captures 100% of the window with zero clipping.
    public static func isWindowFullyContainedInDisplay(
        windowCGRect: CGRect,
        displayCGBounds: CGRect,
        tolerance: CGFloat = 2.0
    ) -> Bool {
        let win = windowCGRect.standardized
        let disp = displayCGBounds.standardized
        guard win.width >= 64, win.height >= 64, disp.width >= 64, disp.height >= 64 else {
            return false
        }
        return win.minX >= disp.minX - tolerance
            && win.minY >= disp.minY - tolerance
            && win.maxX <= disp.maxX + tolerance
            && win.maxY <= disp.maxY + tolerance
    }

    /// Pure, unit-testable policy deciding whether window capture should use a display-scoped
    /// `SCContentFilter` + `sourceRect` instead of `SCContentFilter(desktopIndependentWindow:)`.
    ///
    /// On macOS, `SCContentFilter(desktopIndependentWindow:)` expands its composite bounding box and
    /// bilinearly downscales the entire captured window (`contentScale < 1.0`, destroying >85% pixel
    /// contrast) whenever ANY attached child window (Chrome's `StatusBubbleMac` URL bar, hover tooltips
    /// at layer 103, tab hover cards, or offscreen fullscreen toolbars) protrudes by even 0.5 pt past
    /// the parent window — or when macOS's window chrome frame differs from `SCWindow.frame`.
    ///
    /// Display-scoped app-inclusive capture with an exact display-local `sourceRect` delivers exact
    /// `contentScale == 1.0` pixel-sharp frames while still capturing tooltips, status bubbles, and
    /// popups cleanly and excluding MetalPie's overlay and all other apps. Partially off-screen windows
    /// (unless fullscreen or shrink-detected) keep `desktopIndependentWindow` to avoid clipping.
    public static func shouldUseDisplayScopedWindowCapture(
        windowBounds: CGRect,
        displays: [DisplayDescriptor],
        isFullscreenWindow: Bool,
        didDetectChildWindowShrink: Bool,
        captureMode: CaptureMode,
        ignoreShadows: Bool = true
    ) -> Bool {
        guard captureMode == .window else { return false }
        guard let targetDisplay = ScreenGeometry.bestDisplay(forCGRect: windowBounds, in: displays)
            ?? ScreenGeometry.primaryDisplay(in: displays)
        else {
            return false
        }
        guard computeDisplayLocalSourceRect(
            windowCGRect: windowBounds,
            displayCGBounds: targetDisplay.cgBounds
        ) != nil else {
            return false
        }
        if isFullscreenWindow || didDetectChildWindowShrink {
            return true
        }
        return ignoreShadows && isWindowFullyContainedInDisplay(
            windowCGRect: windowBounds,
            displayCGBounds: targetDisplay.cgBounds
        )
    }

    /// Pauses or resumes frame emission without tearing down the active `SCStream`
    /// (useful when the target app temporarily loses focus).
    public func setPaused(_ paused: Bool) {
        state.withLock { $0.isPaused = paused }
    }

    // MARK: - FrameCaptureSession

    public func start(
        window: WindowDescriptor,
        profile: Profile,
        scalingMode: ScalingMode,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onEvent: @escaping @Sendable (CaptureSessionEvent) -> Void
    ) async throws {
        try await gate.withLock {
            guard CGPreflightScreenCaptureAccess() else {
                throw EngineError.screenRecordingPermissionDenied
            }

            // Tear down any existing stream cleanly first.
            await self.stopInternal(emitEvent: false)

            let token = self.state.withLock { s -> UInt64 in
                s.sessionToken &+= 1
                s.activeWindow = window
                s.activeProfile = profile
                s.activeScalingMode = scalingMode
                s.onFrame = onFrame
                s.onEvent = onEvent
                s.isPaused = false
                s.detectedChildWindowShrink = false
                s.frameCount = 0
                s.lastFrameHostTime = 0
                s.lastReportedScreenRect = window.cgBounds
                s.hasLoggedStaleWarning = false
                s.nonRetinaProbesCompleted = 0
                s.nonRetinaFramesSinceReset = 0
                s.nonRetinaProbeInFlight = false
                if s.nonRetinaMode == .force1x {
                    s.detectedContentResolution = .magnifiedNearest2x
                } else {
                    s.detectedContentResolution = .nativeFull
                }
                return s.sessionToken
            }

            let displays = await WindowEnumerator.enumerateDisplaysAsync()
            let isFullscreenWindow = (profile.capture.captureMode == .window)
                && WindowEnumerator.isFullscreenVideoOrGameWindow(
                    windowID: window.windowID,
                    bounds: window.cgBounds,
                    displays: displays
                )
            let useDisplayScoped = Self.shouldUseDisplayScopedWindowCapture(
                windowBounds: window.cgBounds,
                displays: displays,
                isFullscreenWindow: isFullscreenWindow,
                didDetectChildWindowShrink: false,
                captureMode: profile.capture.captureMode,
                ignoreShadows: profile.capture.ignoreShadows
            )
            let (filter, scConfig, applied) = try await self.buildFilterAndConfiguration(
                window: window,
                profile: profile,
                displays: displays,
                useDisplayScopedWindowCapture: useDisplayScoped,
                isFullscreenWindow: isFullscreenWindow
            )

            // Flush texture cache before attaching new stream to guarantee clean surface tracking.
            self.flushTextureCacheSync()

            let stream = SCStream(filter: filter, configuration: scConfig, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)

            // Publish active stream & running state BEFORE awaiting `startCapture()` so early
            // stream stop/error callbacks during startup are NEVER dropped (fixing MetalGoose race!).
            self.activeStream = stream
            self.state.withLock { s in
                guard s.sessionToken == token else { return }
                s.isRunning = true
                s.appliedConfig = applied
            }

            do {
                try await stream.startCapture()
            } catch {
                self.activeStream = nil
                self.state.withLock { s in
                    guard s.sessionToken == token else { return }
                    s.isRunning = false
                    s.appliedConfig = nil
                }
                throw EngineError.captureStartFailed(error.localizedDescription)
            }

            self.startStaleFrameMonitor(sessionToken: token)

            PipelineLog.shared.info(
                .capture,
                "Started SCStream for '\(window.displayName)' (\(applied.pixelWidth)x\(applied.pixelHeight) @ \(applied.backingScaleFactor)x, queueDepth=\(applied.queueDepth), hdr=\(applied.dynamicRange == .hdr), showsCursor=\(applied.showsCursor))."
            )
        }
    }

    /// Coalesced live resize/move reconfiguration so macOS titlebar zoom animations
    /// and edge drags never trigger mid-animation SCShareableContent / IOSurface pool storms,
    /// while origin-only moves in display-scoped `sourceRect` mode snap swiftly (`40 ms`).
    public func requestDebouncedResizeReconfiguration(
        window: WindowDescriptor,
        profile: Profile,
        scalingMode: ScalingMode
    ) {
        let debounceMs: Int? = state.withLock { s in
            guard s.isRunning else { return nil }
            if let applied = s.appliedConfig,
               applied.usesDisplayScopedWindowCapture,
               let prevRect = applied.sourceRect,
               abs(Double(window.cgBounds.width) - Double(prevRect.width)) < 2.0,
               abs(Double(window.cgBounds.height) - Double(prevRect.height)) < 2.0
            {
                return Self.fastResizeDebounceMilliseconds
            }
            return Self.resizeDebounceMilliseconds
        }
        guard let debounceMs else { return }
        scheduleDebouncedResizeReconfig(
            window: window,
            profile: profile,
            scalingMode: scalingMode,
            debounceMilliseconds: debounceMs
        )
    }

    public func updateConfiguration(
        window: WindowDescriptor,
        profile: Profile,
        scalingMode: ScalingMode
    ) async throws {
        // Explicit reconfiguration supersedes any queued debounced resize task.
        cancelPendingResizeTask()
        try await applyConfigurationUpdate(
            window: window,
            profile: profile,
            scalingMode: scalingMode
        )
    }

    private func applyConfigurationUpdate(
        window: WindowDescriptor,
        profile: Profile,
        scalingMode: ScalingMode
    ) async throws {
        try await gate.withLock {
            guard let stream = self.activeStream, self.state.withLock(\.isRunning) else {
                return
            }

            let previousApplied = self.state.withLock(\.appliedConfig)
            let displays = await WindowEnumerator.enumerateDisplaysAsync()
            let targetDisplayDescriptor = ScreenGeometry.bestDisplay(forCGRect: window.cgBounds, in: displays)
                ?? ScreenGeometry.primaryDisplay(in: displays)
            let targetDisplayID = targetDisplayDescriptor?.id ?? CGMainDisplayID()

            let isFullscreenWindow = (profile.capture.captureMode == .window)
                && WindowEnumerator.isFullscreenVideoOrGameWindow(
                    windowID: window.windowID,
                    bounds: window.cgBounds,
                    displays: displays
                )

            let didDetectShrink: Bool = self.state.withLock { s in
                if let prev = s.appliedConfig, prev.windowID != window.windowID {
                    s.detectedChildWindowShrink = false
                } else if let prev = s.appliedConfig,
                          prev.usesDisplayScopedWindowCapture,
                          !isFullscreenWindow,
                          !WindowEnumerator.isNotchInsetFullscreenBounds(window.cgBounds, displays: displays),
                          let disp = targetDisplayDescriptor,
                          !WindowEnumerator.boundsCoversDisplay(window.cgBounds, displayBounds: disp.cgBounds, tolerance: 4.0),
                          (abs(Double(window.cgBounds.width) * prev.backingScaleFactor - Double(prev.pixelWidth)) > 16.0
                           || abs(Double(window.cgBounds.height) * prev.backingScaleFactor - Double(prev.pixelHeight)) > 16.0)
                {
                    // Window exited fullscreen / resized back to a normal desktop window:
                    // clear shrink flag so we cleanly return to `desktopIndependentWindow`.
                    s.detectedChildWindowShrink = false
                }
                return s.detectedChildWindowShrink
            }

            let wantsDisplayScoped = Self.shouldUseDisplayScopedWindowCapture(
                windowBounds: window.cgBounds,
                displays: displays,
                isFullscreenWindow: isFullscreenWindow,
                didDetectChildWindowShrink: didDetectShrink,
                captureMode: profile.capture.captureMode,
                ignoreShadows: profile.capture.ignoreShadows
            )

            let filterChanged: Bool
            if let prev = previousApplied {
                filterChanged = prev.captureMode != profile.capture.captureMode
                    || prev.windowID != window.windowID
                    || prev.usesDisplayScopedWindowCapture != wantsDisplayScoped
                    || ((profile.capture.captureMode == .display || wantsDisplayScoped) && prev.displayID != targetDisplayID)
            } else {
                filterChanged = true
            }

            let newFilter: SCContentFilter?
            let newSCConfig: SCStreamConfiguration
            let newApplied: AppliedStreamConfig

            if filterChanged {
                let built = try await self.buildFilterAndConfiguration(
                    window: window,
                    profile: profile,
                    displays: displays,
                    useDisplayScopedWindowCapture: wantsDisplayScoped,
                    isFullscreenWindow: isFullscreenWindow
                )
                newFilter = built.0
                newSCConfig = built.1
                newApplied = built.2
            } else {
                // Fast path: stream target identity & filter mode did NOT change -> SKIP SCShareableContent IPC!
                // Build SCStreamConfiguration directly from window.cgBounds & display backingScaleFactor.
                newFilter = nil
                let localSourceRect: CGRect? = wantsDisplayScoped
                    ? targetDisplayDescriptor.flatMap {
                        Self.computeDisplayLocalSourceRect(
                            windowCGRect: window.cgBounds,
                            displayCGBounds: $0.cgBounds
                        )
                    }
                    : nil
                let built = await self.buildStreamConfiguration(
                    window: window,
                    profile: profile,
                    displays: displays,
                    targetDisplayDescriptor: targetDisplayDescriptor,
                    targetDisplayID: targetDisplayID,
                    filterPointPixelScale: nil,
                    filterContentSize: nil,
                    usesDisplayScopedWindowCapture: wantsDisplayScoped && localSourceRect != nil,
                    displayLocalSourceRect: localSourceRect
                )
                newSCConfig = built.0
                newApplied = built.1
            }

            self.state.withLock { s in
                s.activeWindow = window
                s.activeProfile = profile
                s.activeScalingMode = scalingMode
            }

            let configChanged = previousApplied != newApplied

            guard filterChanged || configChanged else {
                return
            }

            let leavingDisplayScoped = (previousApplied?.usesDisplayScopedWindowCapture == true)
                && !newApplied.usesDisplayScopedWindowCapture
            do {
                if leavingDisplayScoped {
                    // Clear display-local `sourceRect` BEFORE switching back to `desktopIndependentWindow`
                    // so SCK never rejects an out-of-bounds `sourceRect` during filter transition.
                    if configChanged {
                        try await stream.updateConfiguration(newSCConfig)
                    }
                    if let newFilter, filterChanged {
                        try await stream.updateContentFilter(newFilter)
                    }
                } else {
                    if let newFilter, filterChanged {
                        try await stream.updateContentFilter(newFilter)
                    }
                    if configChanged {
                        try await stream.updateConfiguration(newSCConfig)
                    }
                }
            } catch {
                PipelineLog.shared.warning(
                    .capture,
                    "Live SCStream reconfiguration failed (\(error.localizedDescription)); keeping previous config."
                )
                throw EngineError.captureStartFailed("Failed to update stream configuration: \(error.localizedDescription)")
            }

            // Flush texture cache & reset non-Retina probe on geometry/format/scale change.
            let dimensionsOrFormatChanged = previousApplied?.pixelWidth != newApplied.pixelWidth
                || previousApplied?.pixelHeight != newApplied.pixelHeight
                || previousApplied?.cvPixelFormat != newApplied.cvPixelFormat
                || previousApplied?.backingScaleFactor != newApplied.backingScaleFactor

            if dimensionsOrFormatChanged {
                self.flushTextureCacheSync()
                self.state.withLock { s in
                    s.nonRetinaProbesCompleted = 0
                    s.nonRetinaFramesSinceReset = 0
                }
            }

            self.state.withLock { s in
                s.appliedConfig = newApplied
                if newApplied.usesDisplayScopedWindowCapture {
                    s.lastReportedScreenRect = window.cgBounds
                }
            }

            PipelineLog.shared.info(
                .capture,
                "Updated SCStream live (filterChanged=\(filterChanged)): \(newApplied.pixelWidth)x\(newApplied.pixelHeight) @ \(newApplied.backingScaleFactor)x, fpsCap=\(newApplied.frameRateLimit.map(String.init) ?? "auto(\(newApplied.effectiveFrameRateCap)Hz)"), hdr=\(newApplied.dynamicRange == .hdr), showsCursor=\(newApplied.showsCursor)."
            )
        }
    }

    public func stop() async {
        await gate.withLock {
            await self.stopInternal(emitEvent: false)
        }
    }

    // MARK: - Internal Stream Construction & Teardown

    private func stopInternal(emitEvent: Bool, reason: String? = nil) async {
        cancelPendingResizeTask()

        staleMonitorTimer?.cancel()
        staleMonitorTimer = nil

        let streamToStop = activeStream
        activeStream = nil

        let onEventCallback: (@Sendable (CaptureSessionEvent) -> Void)? = state.withLock { s in
            let wasRunning = s.isRunning
            s.sessionToken &+= 1
            s.isRunning = false
            s.isPaused = false
            s.appliedConfig = nil
            s.detectedChildWindowShrink = false
            s.activeWindow = nil
            s.activeProfile = nil
            s.activeScalingMode = nil
            let cb = emitEvent && wasRunning ? s.onEvent : nil
            s.onFrame = nil
            s.onEvent = nil
            return cb
        }

        if let streamToStop {
            do {
                try streamToStop.removeStreamOutput(self, type: .screen)
            } catch {
                // Ignore if already removed.
            }
            do {
                try await streamToStop.stopCapture()
            } catch {
                let nsErr = error as NSError
                if !(nsErr.domain == SCStreamErrorDomain && Self.benignSCKStopCodes.contains(nsErr.code)) {
                    PipelineLog.shared.debug(
                        .capture,
                        "SCStream.stopCapture returned error: \(error.localizedDescription)"
                    )
                }
            }
        }

        flushTextureCacheSync()

        if let onEventCallback {
            onEventCallback(.streamStopped(reason))
        }
    }

    private func buildFilterAndConfiguration(
        window: WindowDescriptor,
        profile: Profile,
        displays: [DisplayDescriptor],
        useDisplayScopedWindowCapture: Bool = false,
        isFullscreenWindow: Bool = false
    ) async throws -> (SCContentFilter, SCStreamConfiguration, AppliedStreamConfig) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        } catch {
            throw EngineError.captureStartFailed("Unable to query SCShareableContent: \(error.localizedDescription)")
        }

        let targetDisplayDescriptor = ScreenGeometry.bestDisplay(forCGRect: window.cgBounds, in: displays)
            ?? ScreenGeometry.primaryDisplay(in: displays)
        let targetDisplayID = targetDisplayDescriptor?.id ?? CGMainDisplayID()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let filter: SCContentFilter
        var resolvedDisplayScoped = false
        var resolvedLocalSourceRect: CGRect? = nil

        switch profile.capture.captureMode {
        case .window:
            guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
                throw EngineError.targetWindowNotFound(window.windowID)
            }
            let captureWindowBounds = (scWindow.frame.width >= 64 && scWindow.frame.height >= 64)
                ? scWindow.frame
                : window.cgBounds
            if useDisplayScopedWindowCapture,
               let scDisplay = content.displays.first(where: { $0.displayID == targetDisplayID }),
               let localSource = Self.computeDisplayLocalSourceRect(
                   windowCGRect: captureWindowBounds,
                   displayCGBounds: scDisplay.frame
               )
            {
                // Display-scoped capture with exact display-local `sourceRect`:
                // guarantees `contentScale == 1.0` pixel-exact sharpness (completely immune to
                // child-window hover blur from Chrome `StatusBubbleMac` / tooltips / offscreen
                // fullscreen toolbars and macOS window bezel mismatches), while still capturing
                // tooltips, status bubbles, and context menus belonging to the target app!
                let displayFilter: SCContentFilter
                if isFullscreenWindow && window.pid != ownPID {
                    if let ownApp = content.applications.first(where: { $0.processID == ownPID }) {
                        displayFilter = SCContentFilter(
                            display: scDisplay,
                            excludingApplications: [ownApp],
                            exceptingWindows: []
                        )
                    } else {
                        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
                        displayFilter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)
                    }
                } else if window.pid != ownPID,
                          let targetApp = content.applications.first(where: { $0.processID == window.pid })
                {
                    // Include the target app (so dynamically created child tooltips, status bubbles,
                    // dropdowns, and context menus render cleanly at 1:1) while excluding any OTHER
                    // major layer-0 windows of the same app so stacked sibling windows never bleed in.
                    let siblingMajorWindows = content.windows.filter { candidate in
                        candidate.owningApplication?.processID == window.pid
                            && candidate.windowID != scWindow.windowID
                            && candidate.windowLayer == 0
                            && candidate.frame.width >= 150
                            && candidate.frame.height >= 120
                    }
                    displayFilter = SCContentFilter(
                        display: scDisplay,
                        including: [targetApp],
                        exceptingWindows: siblingMajorWindows
                    )
                } else {
                    displayFilter = SCContentFilter(display: scDisplay, including: [scWindow])
                }
                if #available(macOS 14.2, *) {
                    displayFilter.includeMenuBar = false
                }
                filter = displayFilter
                resolvedDisplayScoped = true
                resolvedLocalSourceRect = localSource
            } else {
                filter = SCContentFilter(desktopIndependentWindow: scWindow)
            }

        case .display:
            guard let scDisplay = content.displays.first(where: { $0.displayID == targetDisplayID })
                ?? content.displays.first
            else {
                throw EngineError.targetWindowNotCapturable("No matching SCDisplay found for display capture.")
            }
            let displayFilter: SCContentFilter
            if let ownApp = content.applications.first(where: { $0.processID == ownPID }) {
                displayFilter = SCContentFilter(
                    display: scDisplay,
                    excludingApplications: [ownApp],
                    exceptingWindows: []
                )
            } else {
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
                displayFilter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)
            }
            if #available(macOS 14.2, *) {
                displayFilter.includeMenuBar = false
            }
            filter = displayFilter
        }

        // Resolve accurate pixel dimensions from ScreenCaptureKit's own filter info (macOS 14.0+).
        let filterInfo = SCShareableContent.info(for: filter)
        let (config, applied) = await buildStreamConfiguration(
            window: window,
            profile: profile,
            displays: displays,
            targetDisplayDescriptor: targetDisplayDescriptor,
            targetDisplayID: targetDisplayID,
            filterPointPixelScale: Double(filterInfo.pointPixelScale),
            filterContentSize: resolvedDisplayScoped ? nil : filterInfo.contentRect.size,
            usesDisplayScopedWindowCapture: resolvedDisplayScoped,
            displayLocalSourceRect: resolvedLocalSourceRect
        )
        return (filter, config, applied)
    }

    private func buildStreamConfiguration(
        window: WindowDescriptor,
        profile: Profile,
        displays: [DisplayDescriptor],
        targetDisplayDescriptor: DisplayDescriptor?,
        targetDisplayID: CGDirectDisplayID,
        filterPointPixelScale: Double?,
        filterContentSize: CGSize?,
        usesDisplayScopedWindowCapture: Bool = false,
        displayLocalSourceRect: CGRect? = nil
    ) async -> (SCStreamConfiguration, AppliedStreamConfig) {
        let resolvedScale = max(
            1.0,
            (filterPointPixelScale ?? 0) > 0
                ? filterPointPixelScale!
                : (targetDisplayDescriptor?.backingScaleFactor ?? window.backingScaleFactor)
        )

        let basePointSize: CGSize
        if usesDisplayScopedWindowCapture, let localSource = displayLocalSourceRect {
            basePointSize = localSource.size
        } else if let contentSize = filterContentSize, contentSize.width >= 16 && contentSize.height >= 16 {
            basePointSize = contentSize
        } else if profile.capture.captureMode == .display, let d = targetDisplayDescriptor {
            basePointSize = d.cgBounds.size
        } else {
            basePointSize = window.cgBounds.size
        }

        let pixelWidth = Self.clampedCaptureDimension(Double(basePointSize.width) * resolvedScale)
        let pixelHeight = Self.clampedCaptureDimension(Double(basePointSize.height) * resolvedScale)

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        if usesDisplayScopedWindowCapture, let localSource = displayLocalSourceRect {
            config.sourceRect = localSource
        }
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = profile.capture.ignoreShadows
        config.captureResolution = .best
        config.showsCursor = !profile.cursor.renderScaledCursor
        config.capturesAudio = false
        config.presenterOverlayPrivacyAlertSetting = .never

        // Dynamic queue depth formula from MetalGoose audit: prevents SCK IOSurface pool starvation.
        let queueDepth = min(8, max(3, pipelineDepth + 4))
        config.queueDepth = queueDepth

        // Frame rate interval:
        // - Explicit user FPS cap is honored directly.
        // - When uncapped (`nil` / Auto), match the host display refresh rate 1:1 (e.g. 120Hz on ProMotion,
        //   60Hz on 60Hz monitors) so SCK cadence aligns with CAMetalDisplayLink with zero beat-frequency drift.
        let hostRefreshHz: Double = {
            switch profile.multiMonitorMode {
            case .closest:
                return targetDisplayDescriptor?.refreshRateHz ?? 60.0
            case .intersected:
                let intersecting = displays.filter { $0.cgBounds.intersects(window.cgBounds) }
                return intersecting.map(\.refreshRateHz).max() ?? targetDisplayDescriptor?.refreshRateHz ?? 60.0
            case .all:
                return displays.map(\.refreshRateHz).max() ?? targetDisplayDescriptor?.refreshRateHz ?? 60.0
            }
        }()
        let effectiveFrameRateCap: Int
        if let limit = profile.capture.frameRateLimit, limit > 0 {
            effectiveFrameRateCap = limit
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(limit))
        } else {
            let autoCap = min(240, max(60, Int(max(60.0, hostRefreshHz).rounded())))
            effectiveFrameRateCap = autoCap
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(autoCap))
        }

        // Pixel format, dynamic range, and explicit color space propagation.
        let isHDR = profile.capture.dynamicRange == .hdr
            || profile.capture.preferredPixelFormat == .rgba16f
        let resolvedCVFormat: OSType
        let resolvedColorSpaceName: CFString

        if isHDR {
            resolvedCVFormat = kCVPixelFormatType_64RGBAHalf
            resolvedColorSpaceName = CGColorSpace.extendedLinearDisplayP3
            if #available(macOS 15.0, *) {
                config.captureDynamicRange = .hdrLocalDisplay
            }
        } else {
            if #available(macOS 15.0, *) {
                config.captureDynamicRange = .SDR
            }
            let sdrColorSpace = await Self.preferredSDRColorSpaceName(for: targetDisplayID)
            resolvedColorSpaceName = sdrColorSpace as CFString

            switch profile.capture.preferredPixelFormat {
            case .bgra8:
                resolvedCVFormat = kCVPixelFormatType_32BGRA
            case .rgb10a2:
                resolvedCVFormat = kCVPixelFormatType_ARGB2101010LEPacked
            case .rgba16f:
                resolvedCVFormat = kCVPixelFormatType_64RGBAHalf
            case .nv12:
                // Single-plane RGB EffectRendering expects color BGRA/RGBA textures;
                // capture BGRA so shader chains never receive a single-channel R8 luma plane.
                PipelineLog.shared.debug(
                    .capture,
                    "NV12 capture requested for RGB shader chain; capturing 32BGRA for single-plane compatibility."
                )
                resolvedCVFormat = kCVPixelFormatType_32BGRA
            }
        }

        config.pixelFormat = resolvedCVFormat
        config.colorSpaceName = resolvedColorSpaceName

        let applied = AppliedStreamConfig(
            captureMode: profile.capture.captureMode,
            windowID: window.windowID,
            displayID: targetDisplayID,
            usesDisplayScopedWindowCapture: usesDisplayScopedWindowCapture && displayLocalSourceRect != nil,
            sourceRect: usesDisplayScopedWindowCapture ? displayLocalSourceRect : nil,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            backingScaleFactor: resolvedScale,
            cvPixelFormat: resolvedCVFormat,
            dynamicRange: isHDR ? .hdr : .sdr,
            colorSpaceName: resolvedColorSpaceName as String,
            frameRateLimit: profile.capture.frameRateLimit,
            effectiveFrameRateCap: effectiveFrameRateCap,
            showsCursor: config.showsCursor,
            ignoreShadows: config.ignoreShadowsSingleWindow,
            queueDepth: queueDepth
        )

        return (config, applied)
    }

    @MainActor
    private static func preferredSDRColorSpaceName(for displayID: CGDirectDisplayID) -> String {
        if let screen = WindowEnumerator.nsScreen(for: displayID),
           let cgSpaceName = screen.colorSpace?.cgColorSpace?.name
        {
            if cgSpaceName == CGColorSpace.displayP3 {
                return CGColorSpace.displayP3 as String
            }
            if cgSpaceName == CGColorSpace.sRGB {
                return CGColorSpace.sRGB as String
            }
        }
        // Default to Display P3 on modern wide-gamut Apple displays.
        return CGColorSpace.displayP3 as String
    }

    private static func clampedCaptureDimension(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return min(16_384, max(64, rounded))
    }

    // MARK: - Texture Wrapping & Cache Management (Zero CPU Pixel Locks)

    private func wrapPixelBufferZeroCopy(_ pixelBuffer: CVPixelBuffer) -> (any MTLTexture, CapturedFrameBacking)? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return nil }

        let cvFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let mtlFormat = Self.mtlPixelFormat(for: cvFormat) else {
            PipelineLog.shared.warning(
                .capture,
                "Unsupported CVPixelBuffer format \(cvFormat) in zero-copy wrapper."
            )
            return nil
        }

        let surfaceID: IOSurfaceID
        if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
            surfaceID = IOSurfaceGetID(surface)
        } else {
            surfaceID = 0
        }

        // Verify cache consistency by (IOSurfaceID, width, height, pixelFormat) — NEVER by IOSurfaceID alone!
        if surfaceID != 0 {
            let key = SurfaceKey(
                surfaceID: surfaceID,
                width: width,
                height: height,
                pixelFormat: mtlFormat
            )
            if let existing = surfaceRegistry[surfaceID], existing != key {
                // Underlying surface dimensions or pixel format mutated under the same IOSurfaceID:
                // flush cache immediately before wrapping to avoid stale-dimension texture corruption.
                CVMetalTextureCacheFlush(cache, 0)
                surfaceRegistry.removeAll(keepingCapacity: true)
            }
            surfaceRegistry[surfaceID] = key
        }

        var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            mtlFormat,
            width,
            height,
            0,
            &cvTextureOut
        )

        guard status == kCVReturnSuccess,
              let cvMetalTexture = cvTextureOut,
              let mtlTexture = CVMetalTextureGetTexture(cvMetalTexture)
        else {
            PipelineLog.shared.warning(
                .capture,
                "CVMetalTextureCacheCreateTextureFromImage failed (CVReturn \(status), \(width)x\(height), fmt=\(mtlFormat.rawValue))."
            )
            return nil
        }

        let backing = CapturedFrameBacking(
            pixelBuffer: pixelBuffer,
            cvMetalTexture: cvMetalTexture,
            surfaceID: surfaceID
        )
        return (mtlTexture, backing)
    }

    private func flushTextureCacheSync() {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.surfaceRegistry.removeAll(keepingCapacity: true)
            if let cache = self.textureCache {
                CVMetalTextureCacheFlush(cache, 0)
            }
        }
    }

    private static func mtlPixelFormat(for cvFormat: OSType) -> MTLPixelFormat? {
        switch cvFormat {
        case kCVPixelFormatType_32BGRA:
            return .bgra8Unorm
        case kCVPixelFormatType_ARGB2101010LEPacked:
            return .bgr10a2Unorm
        case kCVPixelFormatType_64RGBAHalf:
            return .rgba16Float
        default:
            return nil
        }
    }

    // MARK: - Live Geometry Tracking & Dynamic Resize

    private func handleFrameGeometryUpdate(
        screenRect: CGRect,
        contentPixelRect: CGRect,
        scaleFactor: Double,
        contentScale: Double,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        guard screenRect.width >= 16, screenRect.height >= 16 else { return }

        let result: (
            emitBounds: Bool,
            reconfig: (WindowDescriptor, Profile, ScalingMode, Int)?,
            checkCrossDisplay: (appliedDisplayID: CGDirectDisplayID, payload: (WindowDescriptor, Profile, ScalingMode))?
        ) = state.withLock { s in
            guard s.isRunning, let applied = s.appliedConfig else { return (false, nil, nil) }

            let prev = s.lastReportedScreenRect
            // In display-scoped `sourceRect` mode, SCStreamFrameInfo.screenRect echoes our configured
            // sourceRect rather than live window moves (`WindowLifecycleWatcher` owns live bounds updates),
            // so never let pre-update frames emit stale `.windowBoundsChanged` feedback loops.
            let movedOrResized = !applied.usesDisplayScopedWindowCapture && (
                abs(prev.origin.x - screenRect.origin.x) >= 1.0
                    || abs(prev.origin.y - screenRect.origin.y) >= 1.0
                    || abs(prev.size.width - screenRect.size.width) >= 1.0
                    || abs(prev.size.height - screenRect.size.height) >= 1.0
            )

            if movedOrResized {
                s.lastReportedScreenRect = screenRect
                s.activeWindow?.cgBounds = screenRect
            }

            var reconfigPayload: (WindowDescriptor, Profile, ScalingMode, Int)?
            var crossDisplayCheck: (CGDirectDisplayID, (WindowDescriptor, Profile, ScalingMode))?
            if applied.captureMode == .window {
                let expectedW = Self.clampedCaptureDimension(Double(screenRect.width) * scaleFactor)
                let expectedH = Self.clampedCaptureDimension(Double(screenRect.height) * scaleFactor)
                let contentScaleDrifted = contentScale < 0.999 || abs(contentScale - 1.0) >= 0.001
                let appliedAspect = Double(applied.pixelWidth) / Double(max(1, applied.pixelHeight))
                let bufferAspect = Double(pixelWidth) / Double(max(1, pixelHeight))
                let liveAspect = Double(screenRect.width) / Double(max(1, screenRect.height))
                let aspectRatioChanged = abs(liveAspect - appliedAspect) / max(appliedAspect, 0.001) > 0.02
                    || abs(liveAspect - bufferAspect) / max(bufferAspect, 0.001) > 0.02
                let hasContentPadding = ScalingLayoutCalculator.activeContentSubRect(
                    contentPixelRect: contentPixelRect,
                    textureSize: PixelSize(width: pixelWidth, height: pixelHeight)
                ) != nil

                // Detect ANY child-window / tooltip / status-bubble shrink in `desktopIndependentWindow`
                // (even a 0.5 pt protrusion drops `contentScale` to ~0.9979 and destroys >85% pixel contrast):
                // switch immediately to display-scoped `sourceRect` capture!
                let detectedOffscreenChildShrink = !applied.usesDisplayScopedWindowCapture
                    && applied.ignoreShadows
                    && contentScale < 0.999
                    && abs(pixelWidth - expectedW) <= 4
                    && abs(pixelHeight - expectedH) <= 4
                if detectedOffscreenChildShrink {
                    s.detectedChildWindowShrink = true
                }

                // Reconfigure on ANY pixel size, content scale, aspect ratio, padding, or backing scale change.
                if detectedOffscreenChildShrink
                    || contentScaleDrifted
                    || aspectRatioChanged
                    || hasContentPadding
                    || abs(expectedW - applied.pixelWidth) >= 2
                    || abs(expectedH - applied.pixelHeight) >= 2
                    || abs(scaleFactor - applied.backingScaleFactor) >= 0.05
                    || abs(pixelWidth - expectedW) >= 2
                    || abs(pixelHeight - expectedH) >= 2
                {
                    if var win = s.activeWindow, let prof = s.activeProfile, let mode = s.activeScalingMode {
                        if !applied.usesDisplayScopedWindowCapture {
                            win.cgBounds = screenRect
                        }
                        win.backingScaleFactor = scaleFactor
                        s.activeWindow = win
                        // Snap quickly (40ms) on fullscreen transitions / aspect shifts / SCK padding / child shrink,
                        // while keeping 180ms settle debounce for gradual drags & titlebar zooms.
                        let debounceMs = (detectedOffscreenChildShrink || contentScale < 0.999 || aspectRatioChanged || hasContentPadding)
                            ? Self.fastResizeDebounceMilliseconds
                            : Self.resizeDebounceMilliseconds
                        reconfigPayload = (win, prof, mode, debounceMs)
                    }
                } else if movedOrResized,
                          var win = s.activeWindow,
                          let prof = s.activeProfile,
                          let mode = s.activeScalingMode
                {
                    win.cgBounds = screenRect
                    win.backingScaleFactor = scaleFactor
                    crossDisplayCheck = (applied.displayID, (win, prof, mode))
                }
            }
            return (movedOrResized, reconfigPayload, crossDisplayCheck)
        }

        if result.emitBounds {
            let onEvent = state.withLock(\.onEvent)
            onEvent?(.windowBoundsChanged(screenRect))
        }

        if let (win, prof, mode, debounceMs) = result.reconfig {
            scheduleDebouncedResizeReconfig(
                window: win,
                profile: prof,
                scalingMode: mode,
                debounceMilliseconds: debounceMs
            )
        } else if let (appliedDisplayID, payload) = result.checkCrossDisplay {
            // Check outside unfair lock if window moved onto a different display (e.g. Display P3 <-> sRGB).
            let displays = WindowEnumerator.enumerateDisplays()
            if let newDisplayID = ScreenGeometry.bestDisplay(forCGRect: screenRect, in: displays)?.id,
               newDisplayID != appliedDisplayID
            {
                scheduleDebouncedResizeReconfig(window: payload.0, profile: payload.1, scalingMode: payload.2)
            }
        }
    }

    private func cancelPendingResizeTask() {
        let taskToCancel = pendingResizeLock.withLock { s -> Task<Void, Never>? in
            s.generation &+= 1
            let prev = s.task
            s.task = nil
            return prev
        }
        taskToCancel?.cancel()
    }

    private func scheduleDebouncedResizeReconfig(
        window: WindowDescriptor,
        profile: Profile,
        scalingMode: ScalingMode,
        debounceMilliseconds: Int = resizeDebounceMilliseconds
    ) {
        let scheduledGen = pendingResizeLock.withLock { s -> UInt64 in
            s.generation &+= 1
            return s.generation
        }

        let nextTask = Task { [weak self] in
            // 180 ms settle debounce coalesces macOS titlebar zoom animations (250-350 ms)
            // and live edge resize drags into a single post-settle SCStream update;
            // 40 ms fast debounce snaps fullscreen / aspect-ratio transitions immediately.
            try? await Task.sleep(for: .milliseconds(max(10, debounceMilliseconds)))
            guard !Task.isCancelled, let self else { return }
            let stillCurrent = self.pendingResizeLock.withLock { $0.generation == scheduledGen }
            guard stillCurrent, self.state.withLock(\.isRunning) else { return }
            do {
                try await self.applyConfigurationUpdate(
                    window: window,
                    profile: profile,
                    scalingMode: scalingMode
                )
            } catch {
                PipelineLog.shared.debug(
                    .capture,
                    "Auto resize reconfiguration skipped: \(error.localizedDescription)"
                )
            }
        }

        let previousTask = pendingResizeLock.withLock { s -> Task<Void, Never>? in
            guard s.generation == scheduledGen else {
                nextTask.cancel()
                return nil
            }
            let prev = s.task
            s.task = nextTask
            return prev
        }
        previousTask?.cancel()
    }

    // MARK: - Stale-Frame Monitor

    private func startStaleFrameMonitor(sessionToken: UInt64) {
        staleMonitorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let shouldWarn: Bool = self.state.withLock { s in
                guard s.isRunning, s.sessionToken == sessionToken, !s.isPaused else { return false }
                guard s.frameCount > 0, s.lastFrameHostTime > 0 else { return false }
                let elapsed = now - s.lastFrameHostTime
                if elapsed >= 5.0 && !s.hasLoggedStaleWarning {
                    s.hasLoggedStaleWarning = true
                    return true
                }
                return false
            }
            if shouldWarn {
                PipelineLog.shared.debug(
                    .capture,
                    "No new capture frames received for >5s (window may be static or occluded)."
                )
            }
        }
        staleMonitorTimer = timer
        timer.resume()
    }

    // MARK: - GPU-Only 1x Non-Retina Content Probe (Zero CPU Pixel Locks)

    private static let nonRetinaProbeMSL = """
    #include <metal_stdlib>
    using namespace metal;

    struct ProbeCounters {
        atomic_uint edgeCount;
        atomic_uint nearestBreaks;
        atomic_uint bilinearBreaks;
    };

    inline float luma(float3 c) {
        return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    }

    kernel void probeNonRetina2x(
        texture2d<float, access::read> tex [[texture(0)]],
        device ProbeCounters* counters [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint x = gid.x * 8u + 2u;
        uint y = gid.y * 8u + 2u;
        uint w = tex.get_width();
        uint h = tex.get_height();
        if (x + 3u >= w || y + 3u >= h) { return; }

        float l0 = luma(tex.read(uint2(x, y)).rgb);
        float l1 = luma(tex.read(uint2(x + 1u, y)).rgb);
        float l2 = luma(tex.read(uint2(x + 2u, y)).rgb);
        float l_prev = luma(tex.read(uint2(x - 1u, y)).rgb);
        float l_down = luma(tex.read(uint2(x, y + 1u)).rgb);

        float edge = max(
            max(abs(l0 - l1), abs(l0 - l2)),
            max(abs(l0 - l_down), abs(l0 - luma(tex.read(uint2(x, y + 2u)).rgb)))
        );
        // 24/255 ~= 0.094 luma step filters flat gradients/noise.
        if (edge < 0.094f) { return; }

        atomic_fetch_add_explicit(&counters->edgeCount, 1u, memory_order_relaxed);

        // 2x nearest check: P[2i] == P[2i+1] horizontally & vertically (tolerance ~6/255 = 0.024).
        if (abs(l0 - l1) > 0.024f || abs(l0 - l_down) > 0.024f) {
            atomic_fetch_add_explicit(&counters->nearestBreaks, 1u, memory_order_relaxed);
        }

        // 2x bilinear check (MetalGoose identity): (3*P[2i+1] - P[2i+2]) ~= (3*P[2i] - P[2i-1]).
        float lhs = 3.0f * l1 - l2;
        float rhs = 3.0f * l0 - l_prev;
        if (abs(lhs - rhs) > 0.048f) {
            atomic_fetch_add_explicit(&counters->bilinearBreaks, 1u, memory_order_relaxed);
        }
    }
    """

    private struct SendableBox<T>: @unchecked Sendable {
        let value: T
    }

    private func maybeRunNonRetinaGPUProbe(
        texture: any MTLTexture,
        backing: CapturedFrameBacking,
        scaleFactor: Double
    ) {
        guard scaleFactor >= 1.5, texture.width >= 128, texture.height >= 128 else { return }

        let shouldProbe: Bool = state.withLock { s in
            guard s.nonRetinaMode == .auto,
                  !s.nonRetinaProbeInFlight,
                  s.nonRetinaProbesCompleted < Self.maxNonRetinaProbes
            else {
                return false
            }
            s.nonRetinaProbeInFlight = true
            return true
        }
        guard shouldProbe else { return }

        guard let queue = probeQueue else {
            state.withLock { $0.nonRetinaProbeInFlight = false }
            return
        }

        if probePipeline == nil && !probeDidAttemptCompile {
            probeDidAttemptCompile = true
            if let lib = try? device.makeLibrary(source: Self.nonRetinaProbeMSL, options: nil),
               let fn = lib.makeFunction(name: "probeNonRetina2x")
            {
                probePipeline = try? device.makeComputePipelineState(function: fn)
            }
        }

        guard let pipeline = probePipeline,
              let counterBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 3, options: .storageModeShared),
              let cmdBuffer = queue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder()
        else {
            state.withLock { $0.nonRetinaProbeInFlight = false }
            return
        }

        memset(counterBuffer.contents(), 0, MemoryLayout<UInt32>.stride * 3)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(counterBuffer, offset: 0, index: 0)

        let gridW = max(1, (texture.width - 4) / 8)
        let gridH = max(1, (texture.height - 4) / 8)
        let tgW = min(16, pipeline.threadExecutionWidth)
        let tgH = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / tgW))
        encoder.dispatchThreads(
            MTLSize(width: gridW, height: gridH, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
        )
        encoder.endEncoding()

        // Retain backing object until GPU probe finishes!
        let counterBox = SendableBox(value: counterBuffer)
        cmdBuffer.addCompletedHandler { [weak self] _ in
            _ = backing
            guard let self else { return }
            let ptr = counterBox.value.contents().bindMemory(to: UInt32.self, capacity: 3)
            let edges = ptr[0]
            let nearestBreaks = ptr[1]
            let bilinearBreaks = ptr[2]

            let emittedResolution: DetectedContentResolution? = self.state.withLock { s in
                s.nonRetinaProbeInFlight = false
                s.nonRetinaProbesCompleted += 1
                guard s.nonRetinaMode == .auto, edges >= 32 else { return nil }

                let nearestRatio = Double(nearestBreaks) / Double(edges)
                let bilinearRatio = Double(bilinearBreaks) / Double(edges)

                let verdict: DetectedContentResolution
                if nearestRatio <= 0.015 {
                    verdict = .magnifiedNearest2x
                } else if bilinearRatio <= 0.025 {
                    verdict = .magnifiedBilinear2x
                } else {
                    verdict = .nativeFull
                }

                if s.detectedContentResolution != verdict {
                    s.detectedContentResolution = verdict
                    return verdict
                }
                return nil
            }

            if let emittedResolution {
                PipelineLog.shared.info(
                    .capture,
                    "GPU Non-Retina content probe detected: \(emittedResolution.rawValue) (edges=\(edges), nearestBreaks=\(nearestBreaks), bilinearBreaks=\(bilinearBreaks))."
                )
                let cb = self.state.withLock(\.onContentResolutionChanged)
                cb?(emittedResolution)
            }
        }
        cmdBuffer.commit()
    }
}

// MARK: - SCStreamOutput & SCStreamDelegate

extension ScreenCaptureEngine: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Check SCStreamFrameInfo.status before touching pixel buffer.
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        let info = attachments?.first

        if let statusRaw = (info?[.status] as? NSNumber)?.intValue,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete
        {
            return
        }

        let (running, paused, onFrame, applied): (
            Bool,
            Bool,
            (@Sendable (CapturedFrame) -> Void)?,
            AppliedStreamConfig?
        ) = state.withLock { s in
            (s.isRunning, s.isPaused, s.onFrame, s.appliedConfig)
        }
        guard running, !paused, let onFrame else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Zero-copy IOSurface -> CVMetalTexture wrap (ZERO CPU pixel locks!).
        guard let (mtlTexture, backing) = wrapPixelBufferZeroCopy(pixelBuffer) else { return }

        let pixelWidth = mtlTexture.width
        let pixelHeight = mtlTexture.height

        // Periodic cache flush every N frames & resettable non-Retina probe frame counter.
        let (currentFrameNumber, shouldRunNonRetinaProbe): (UInt64, Bool) = state.withLock { s in
            s.frameCount &+= 1
            s.nonRetinaFramesSinceReset &+= 1
            s.lastFrameHostTime = CFAbsoluteTimeGetCurrent()
            s.hasLoggedStaleWarning = false

            let probeDue = (s.nonRetinaMode == .auto)
                && (s.nonRetinaProbesCompleted < Self.maxNonRetinaProbes)
                && !s.nonRetinaProbeInFlight
                && s.nonRetinaFramesSinceReset >= 2
                && ((s.nonRetinaFramesSinceReset - 2) % 3 == 0)
            return (s.frameCount, probeDue)
        }
        if currentFrameNumber % Self.cacheFlushIntervalFrames == 0, let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }

        // Read zero-IPC window geometry & scaling attachments directly from SCStreamFrameInfo.
        let scaleFactor: Double = {
            if let s = (info?[.scaleFactor] as? NSNumber)?.doubleValue, s > 0 { return s }
            return applied?.backingScaleFactor ?? 2.0
        }()

        let contentScale: Double = {
            if let cs = (info?[.contentScale] as? NSNumber)?.doubleValue, cs > 0 { return cs }
            return 1.0
        }()

        // Empirically verified on macOS: SCStreamFrameInfo.contentRect is reported in surface points
        // (already scaled by contentScale); multiply by scaleFactor to obtain exact texture pixel bounds.
        let rawPointContentRect: CGRect? = {
            if let dict = info?[.contentRect] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dict),
               rect.width > 0 && rect.height > 0
            {
                return rect.standardized
            }
            return nil
        }()
        let contentRect = ScalingLayoutCalculator.convertSCKContentRectToPixels(
            pointRect: rawPointContentRect,
            scaleFactor: scaleFactor,
            textureSize: PixelSize(width: pixelWidth, height: pixelHeight)
        )

        let screenRect: CGRect = {
            if let dict = info?[.screenRect] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dict),
               rect.width > 0 && rect.height > 0
            {
                return rect.standardized
            }
            return state.withLock(\.lastReportedScreenRect)
        }()

        let timestampSeconds: Double = {
            if let displayTime = (info?[.displayTime] as? NSNumber)?.uint64Value, displayTime > 0 {
                return Self.machTicksToSeconds(displayTime)
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isValid && pts.isNumeric {
                return CMTimeGetSeconds(pts)
            }
            return CACurrentMediaTime()
        }()

        // Optional GPU-only 1x non-Retina content probe on startup, window resize, or `.auto` toggle.
        if shouldRunNonRetinaProbe {
            maybeRunNonRetinaGPUProbe(
                texture: mtlTexture,
                backing: backing,
                scaleFactor: scaleFactor
            )
        }

        // Track live window movement & dynamic proportional resizes without CGWindowList IPC.
        handleFrameGeometryUpdate(
            screenRect: screenRect,
            contentPixelRect: contentRect,
            scaleFactor: scaleFactor,
            contentScale: contentScale,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )

        let frame = CapturedFrame(
            texture: mtlTexture,
            pixelSize: PixelSize(width: pixelWidth, height: pixelHeight),
            contentRect: contentRect,
            screenRect: screenRect,
            scaleFactor: scaleFactor,
            timestampSeconds: timestampSeconds,
            isHDR: applied?.dynamicRange == .hdr || mtlTexture.pixelFormat == .rgba16Float,
            colorSpaceName: applied?.colorSpaceName,
            backingObject: backing
        )

        onFrame(frame)
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let nsErr = error as NSError
        let isBenign = nsErr.domain == SCStreamErrorDomain
            && Self.benignSCKStopCodes.contains(nsErr.code)
        let reason: String? = isBenign ? nil : error.localizedDescription

        if isBenign {
            PipelineLog.shared.info(.capture, "SCStream stopped cleanly (code \(nsErr.code)).")
        } else {
            PipelineLog.shared.error(.capture, "SCStream interrupted with error: \(error.localizedDescription)")
        }

        let stoppedStreamID = ObjectIdentifier(stream)
        Task { [weak self] in
            guard let self else { return }
            await self.gate.withLock {
                // Ignore stale delegate callback from a previously stopped stream instance.
                guard let current = self.activeStream, ObjectIdentifier(current) == stoppedStreamID else {
                    return
                }
                await self.stopInternal(emitEvent: true, reason: reason)
            }
        }
    }

    @available(macOS 15.2, *)
    public func streamDidBecomeActive(_ stream: SCStream) {
        PipelineLog.shared.debug(.capture, "SCStream became active.")
    }

    @available(macOS 15.2, *)
    public func streamDidBecomeInactive(_ stream: SCStream) {
        PipelineLog.shared.debug(.capture, "SCStream became inactive (source temporarily unavailable).")
    }

    // MARK: - Mach Timebase Conversion

    private static let machSecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let denom = max(1, Double(info.denom))
        return (Double(info.numer) / denom) * 1e-9
    }()

    private static func machTicksToSeconds(_ ticks: UInt64) -> Double {
        Double(ticks) * machSecondsPerTick
    }
}
