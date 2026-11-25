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

    private let device: any MTLDevice
    private let pipelineDepth: Int
    private let gate = AsyncSerialGate()
    private let state = OSAllocatedUnfairLock(initialState: RuntimeState())

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
    private var pendingResizeTask: Task<Void, Never>?

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
        pendingResizeTask?.cancel()
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
            let (filter, scConfig, applied) = try await self.buildFilterAndConfiguration(
                window: window,
                profile: profile,
                displays: displays
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

    public func updateConfiguration(
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
            let (newFilter, newSCConfig, newApplied) = try await self.buildFilterAndConfiguration(
                window: window,
                profile: profile,
                displays: displays
            )

            self.state.withLock { s in
                s.activeWindow = window
                s.activeProfile = profile
                s.activeScalingMode = scalingMode
            }

            let filterChanged = previousApplied == nil
                || previousApplied?.captureMode != newApplied.captureMode
                || previousApplied?.windowID != newApplied.windowID
                || (newApplied.captureMode == .display && previousApplied?.displayID != newApplied.displayID)

            let configChanged = previousApplied != newApplied

            guard filterChanged || configChanged else {
                return
            }

            do {
                if filterChanged {
                    try await stream.updateContentFilter(newFilter)
                }
                if configChanged {
                    try await stream.updateConfiguration(newSCConfig)
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
            }

            PipelineLog.shared.info(
                .capture,
                "Updated SCStream live: \(newApplied.pixelWidth)x\(newApplied.pixelHeight) @ \(newApplied.backingScaleFactor)x, fpsCap=\(newApplied.frameRateLimit.map(String.init) ?? "auto(\(newApplied.effectiveFrameRateCap)Hz)"), hdr=\(newApplied.dynamicRange == .hdr), showsCursor=\(newApplied.showsCursor)."
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
        pendingResizeTask?.cancel()
        pendingResizeTask = nil

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
        displays: [DisplayDescriptor]
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

        let filter: SCContentFilter
        switch profile.capture.captureMode {
        case .window:
            guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
                throw EngineError.targetWindowNotFound(window.windowID)
            }
            filter = SCContentFilter(desktopIndependentWindow: scWindow)

        case .display:
            guard let scDisplay = content.displays.first(where: { $0.displayID == targetDisplayID })
                ?? content.displays.first
            else {
                throw EngineError.targetWindowNotCapturable("No matching SCDisplay found for display capture.")
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            let displayFilter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)
            if #available(macOS 14.2, *) {
                displayFilter.includeMenuBar = false
            }
            filter = displayFilter
        }

        // Resolve accurate pixel dimensions from ScreenCaptureKit's own filter info (macOS 14.0+).
        let filterInfo = SCShareableContent.info(for: filter)
        let resolvedScale = max(
            1.0,
            Double(filterInfo.pointPixelScale) > 0
                ? Double(filterInfo.pointPixelScale)
                : (targetDisplayDescriptor?.backingScaleFactor ?? window.backingScaleFactor)
        )

        let basePointSize: CGSize
        if filterInfo.contentRect.width >= 16 && filterInfo.contentRect.height >= 16 {
            basePointSize = filterInfo.contentRect.size
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
        // - When uncapped (`nil` / Auto), cap sensibly to the host display refresh rate (+5% jitter
        //   headroom so 60fps/120fps sources never miss a beat due to sub-ms clock phase jitter, while
        //   preventing 120–240fps SCK bursts from flooding a 60Hz display mailbox!).
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
            let autoCap = min(240, max(60, Int((max(60.0, hostRefreshHz) * 1.05).rounded())))
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

        return (filter, config, applied)
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
        scaleFactor: Double,
        contentScale: Double,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        guard screenRect.width >= 16, screenRect.height >= 16 else { return }

        let result: (
            emitBounds: Bool,
            reconfig: (WindowDescriptor, Profile, ScalingMode)?,
            checkCrossDisplay: (appliedDisplayID: CGDirectDisplayID, payload: (WindowDescriptor, Profile, ScalingMode))?
        ) = state.withLock { s in
            guard s.isRunning, let applied = s.appliedConfig else { return (false, nil, nil) }

            let prev = s.lastReportedScreenRect
            let movedOrResized = abs(prev.origin.x - screenRect.origin.x) >= 1.0
                || abs(prev.origin.y - screenRect.origin.y) >= 1.0
                || abs(prev.size.width - screenRect.size.width) >= 1.0
                || abs(prev.size.height - screenRect.size.height) >= 1.0

            if movedOrResized {
                s.lastReportedScreenRect = screenRect
                s.activeWindow?.cgBounds = screenRect
            }

            var reconfigPayload: (WindowDescriptor, Profile, ScalingMode)?
            var crossDisplayCheck: (CGDirectDisplayID, (WindowDescriptor, Profile, ScalingMode))?
            if applied.captureMode == .window {
                let expectedW = Self.clampedCaptureDimension(Double(screenRect.width) * scaleFactor)
                let expectedH = Self.clampedCaptureDimension(Double(screenRect.height) * scaleFactor)
                let contentScaleDrifted = abs(contentScale - 1.0) >= 0.05
                // Reconfigure on ANY pixel size, content scale, or backing scale change
                // (fixes MetalDuck proportional-resize bug!).
                if contentScaleDrifted
                    || abs(expectedW - applied.pixelWidth) >= 2
                    || abs(expectedH - applied.pixelHeight) >= 2
                    || abs(scaleFactor - applied.backingScaleFactor) >= 0.05
                    || abs(pixelWidth - expectedW) >= 2
                    || abs(pixelHeight - expectedH) >= 2
                {
                    if var win = s.activeWindow, let prof = s.activeProfile, let mode = s.activeScalingMode {
                        win.cgBounds = screenRect
                        win.backingScaleFactor = scaleFactor
                        s.activeWindow = win
                        reconfigPayload = (win, prof, mode)
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

        if let (win, prof, mode) = result.reconfig {
            scheduleDebouncedResizeReconfig(window: win, profile: prof, scalingMode: mode)
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

    private func scheduleDebouncedResizeReconfig(
        window: WindowDescriptor,
        profile: Profile,
        scalingMode: ScalingMode
    ) {
        pendingResizeTask?.cancel()
        pendingResizeTask = Task { [weak self] in
            // Short 60 ms debounce coalesces interactive window drag storms without perceptible lag.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.updateConfiguration(
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

        let contentRect: CGRect = {
            if let dict = info?[.contentRect] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dict),
               rect.width > 0 && rect.height > 0
            {
                return rect.standardized
            }
            return CGRect(x: 0, y: 0, width: Double(pixelWidth), height: Double(pixelHeight))
        }()

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
