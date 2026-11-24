import CoreGraphics
import Foundation
import Metal

// MARK: - Errors & Permissions

/// Unified error type shared across capture, shader, input, and UI layers.
public enum EngineError: Error, LocalizedError, Sendable, Equatable {
    case screenRecordingPermissionDenied
    case accessibilityPermissionDenied
    case targetWindowNotFound(CGWindowID)
    case targetWindowNotCapturable(String)
    case invalidCropping(source: PixelSize, crop: CropInsets)
    case invalidScalingMode(UUID)
    case metalDeviceUnavailable
    case shaderCompilationFailed(effectID: EffectID, detail: String)
    case captureStartFailed(String)
    case captureStreamStopped(String)
    case frameGenUnavailable(String)
    case hotkeyRegistrationFailed(HotkeyAction, Int32)
    case screenshotExportFailed(String)
    case windowedModeDisallowedIn3DGameMode
    case unsupportedOSVersion(required: String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required to capture windows."
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required for scaled cursor alignment and confinement."
        case .targetWindowNotFound(let id):
            return "Target window (ID \(id)) is no longer available."
        case .targetWindowNotCapturable(let reason):
            return "Target window cannot be captured: \(reason)"
        case .invalidCropping(let source, _):
            return "Crop margins leave fewer than \(CropInsets.minimumRemainingDimension)px inside \(source.width)x\(source.height)."
        case .invalidScalingMode(let id):
            return "Scaling mode \(id.uuidString) could not be found or has no valid passes."
        case .metalDeviceUnavailable:
            return "No compatible Metal GPU device is available."
        case .shaderCompilationFailed(let effectID, let detail):
            return "Failed to compile shader '\(effectID.rawValue)': \(detail)"
        case .captureStartFailed(let detail):
            return "Failed to start ScreenCaptureKit stream: \(detail)"
        case .captureStreamStopped(let detail):
            return "Capture stream stopped: \(detail)"
        case .frameGenUnavailable(let detail):
            return "Frame generation is unavailable: \(detail)"
        case .hotkeyRegistrationFailed(let action, let status):
            return "Failed to register global hotkey for '\(action.rawValue)' (OSStatus \(status))."
        case .screenshotExportFailed(let detail):
            return "Failed to save screenshot: \(detail)"
        case .windowedModeDisallowedIn3DGameMode:
            return "Windowed scaling mode is disabled while 3D Game Mode is active."
        case .unsupportedOSVersion(let required):
            return "This feature requires \(required) or newer."
        }
    }
}

/// Snapshot of macOS TCC permission grants required by MetalPie features.
public struct PermissionStatus: Hashable, Codable, Sendable {
    public var screenRecordingGranted: Bool
    public var accessibilityGranted: Bool

    public init(screenRecordingGranted: Bool, accessibilityGranted: Bool) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
    }
}

// MARK: - Capture & Frame Transfer DTOs

/// Zero-copy captured GPU frame handed from `MetalPieCapture` to the render thread.
///
/// IMPORTANT: `backingObject` retains the underlying `CVMetalTexture` / `CVPixelBuffer` / `IOSurface`
/// until the GPU command buffer finishes (`addCompletedHandler`), preventing IOSurface pool recycling races.
public struct CapturedFrame: @unchecked Sendable {
    public var texture: any MTLTexture
    public var pixelSize: PixelSize
    public var contentRect: CGRect
    /// Window rect in CoreGraphics global coordinates (Y-down), read from `SCStreamFrameInfo.screenRect`.
    public var screenRect: CGRect
    public var scaleFactor: Double
    public var timestampSeconds: Double
    public var isHDR: Bool
    public var colorSpaceName: String?
    public var backingObject: (any AnyObject)?

    public init(
        texture: any MTLTexture,
        pixelSize: PixelSize,
        contentRect: CGRect,
        screenRect: CGRect,
        scaleFactor: Double = 2.0,
        timestampSeconds: Double = 0,
        isHDR: Bool = false,
        colorSpaceName: String? = nil,
        backingObject: (any AnyObject)? = nil
    ) {
        self.texture = texture
        self.pixelSize = pixelSize
        self.contentRect = contentRect
        self.screenRect = screenRect
        self.scaleFactor = max(1.0, scaleFactor)
        self.timestampSeconds = timestampSeconds
        self.isHDR = isHDR
        self.colorSpaceName = colorSpaceName
        self.backingObject = backingObject
    }
}

// MARK: - Shader & Effect Rendering Contract (`MetalPieShaders`)

/// Per-frame GPU resources and layout context passed into `EffectRendering.encode(...)`.
public struct EffectRenderContext: @unchecked Sendable {
    public var device: any MTLDevice
    public var commandBuffer: any MTLCommandBuffer
    public var sourceTexture: any MTLTexture
    public var destinationTexture: any MTLTexture
    public var layout: ScalingLayoutResult
    public var isHDR: Bool
    public var frameIndex: UInt64
    public var duplicateFrameMode: DuplicateFrameMode

    public init(
        device: any MTLDevice,
        commandBuffer: any MTLCommandBuffer,
        sourceTexture: any MTLTexture,
        destinationTexture: any MTLTexture,
        layout: ScalingLayoutResult,
        isHDR: Bool = false,
        frameIndex: UInt64 = 0,
        duplicateFrameMode: DuplicateFrameMode = .dynamic
    ) {
        self.device = device
        self.commandBuffer = commandBuffer
        self.sourceTexture = sourceTexture
        self.destinationTexture = destinationTexture
        self.layout = layout
        self.isHDR = isHDR
        self.frameIndex = frameIndex
        self.duplicateFrameMode = duplicateFrameMode
    }
}

/// Summary returned after encoding a multi-pass effect graph for one frame.
public struct EffectExecutionReport: Hashable, Sendable {
    public var passTimings: [PassTiming]
    public var wasDuplicateFrameSkipped: Bool
    public var finalOutputSize: PixelSize

    public init(
        passTimings: [PassTiming] = [],
        wasDuplicateFrameSkipped: Bool = false,
        finalOutputSize: PixelSize = .zero
    ) {
        self.passTimings = passTimings
        self.wasDuplicateFrameSkipped = wasDuplicateFrameSkipped
        self.finalOutputSize = finalOutputSize
    }
}

/// Contract implemented by `MetalPieShaders`'s multi-pass Metal & MetalFX effect graph engine.
public protocol EffectRendering: AnyObject, Sendable {
    /// Effects supported by this renderer on the current hardware / macOS version.
    var supportedEffects: [EffectID] { get }

    /// Compiles and caches pipeline states / MetalFX scalers ahead of first frame presentation.
    func prewarm(scalingMode: ScalingMode) async throws

    /// Encodes all enabled passes in `scalingMode` (plus any auto-Bicubic fallback specified in `context.layout`)
    /// from `context.sourceTexture` into `context.destinationTexture`.
    func encode(scalingMode: ScalingMode, context: EffectRenderContext) throws -> EffectExecutionReport

    /// Releases pooled intermediate textures and resets duplicate-frame state.
    func reset()
}

// MARK: - Frame Generation Contract (`MetalPieCapture` / `MetalPieShaders`)

/// Per-frame GPU request for optical-flow or VideoToolbox ML frame interpolation.
public struct FrameGenRequest: @unchecked Sendable {
    public var previousTexture: any MTLTexture
    public var currentTexture: any MTLTexture
    public var outputTexture: any MTLTexture
    /// Fractional timestamp between `previousTexture` (`0.0`) and `currentTexture` (`1.0`).
    public var interpolationFactor: Float
    public var commandBuffer: any MTLCommandBuffer
    public var settings: FrameGenSettings

    public init(
        previousTexture: any MTLTexture,
        currentTexture: any MTLTexture,
        outputTexture: any MTLTexture,
        interpolationFactor: Float,
        commandBuffer: any MTLCommandBuffer,
        settings: FrameGenSettings
    ) {
        self.previousTexture = previousTexture
        self.currentTexture = currentTexture
        self.outputTexture = outputTexture
        self.interpolationFactor = min(max(interpolationFactor, 0.0), 1.0)
        self.commandBuffer = commandBuffer
        self.settings = settings
    }
}

/// Contract for VideoToolbox ML (`macOS 26+`) and Metal optical-flow frame interpolators.
public protocol FrameInterpolating: AnyObject, Sendable {
    var backendName: String { get }
    var isSupported: Bool { get }

    func prepare(width: Int, height: Int, settings: FrameGenSettings) throws
    /// Encodes one interpolated frame. Returns `true` if synthesized, or `false` if Artifact Guard
    /// fell back to the nearest real frame (e.g. scene cut).
    func encode(request: FrameGenRequest) throws -> Bool
    func reset()
}

// MARK: - Screen Capture & Overlay Presentation Contract (`MetalPieCapture`)

/// Lifecycle events emitted by an active capture & presentation session.
public enum CaptureSessionEvent: Sendable {
    case firstFrameRendered
    case windowBoundsChanged(CGRect)
    case windowMinimized
    case windowRestored
    case windowClosed
    case streamStopped(String?)
    case telemetryUpdated(SessionTelemetry)
}

/// Contract implemented by `MetalPieCapture`'s ScreenCaptureKit session manager.
public protocol FrameCaptureSession: AnyObject, Sendable {
    var isRunning: Bool { get }

    func start(
        window: WindowDescriptor,
        profile: Profile,
        scalingMode: ScalingMode,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onEvent: @escaping @Sendable (CaptureSessionEvent) -> Void
    ) async throws

    func updateConfiguration(
        window: WindowDescriptor,
        profile: Profile,
        scalingMode: ScalingMode
    ) async throws

    func stop() async
}

// MARK: - Cursor, Window Tracking & Global Hotkeys Contracts (`MetalPieInput`)

/// Geometry and behavioral configuration for scaled cursor confinement & rendering.
public struct CursorMappingConfiguration: Hashable, Sendable {
    /// Underlying source window rect in CoreGraphics (Y-down) logical points.
    public var sourceCGRect: CGRect
    /// Visible scaled content rect in CoreGraphics (Y-down) logical points.
    public var destinationCGRect: CGRect
    /// Full overlay window rect in CoreGraphics (Y-down) logical points.
    public var overlayCGRect: CGRect
    public var backingScaleFactor: Double
    public var settings: CursorSettings
    public var threeDGameMode: Bool

    public init(
        sourceCGRect: CGRect,
        destinationCGRect: CGRect,
        overlayCGRect: CGRect,
        backingScaleFactor: Double = 2.0,
        settings: CursorSettings = CursorSettings(),
        threeDGameMode: Bool = false
    ) {
        self.sourceCGRect = sourceCGRect
        self.destinationCGRect = destinationCGRect
        self.overlayCGRect = overlayCGRect
        self.backingScaleFactor = max(1.0, backingScaleFactor)
        self.settings = settings
        self.threeDGameMode = threeDGameMode
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sourceCGRect.origin.x)
        hasher.combine(sourceCGRect.origin.y)
        hasher.combine(sourceCGRect.size.width)
        hasher.combine(sourceCGRect.size.height)
        hasher.combine(destinationCGRect.origin.x)
        hasher.combine(destinationCGRect.origin.y)
        hasher.combine(destinationCGRect.size.width)
        hasher.combine(destinationCGRect.size.height)
        hasher.combine(overlayCGRect.origin.x)
        hasher.combine(overlayCGRect.origin.y)
        hasher.combine(overlayCGRect.size.width)
        hasher.combine(overlayCGRect.size.height)
        hasher.combine(backingScaleFactor)
        hasher.combine(settings)
        hasher.combine(threeDGameMode)
    }
}

/// Real-time scaled cursor sprite state driven by `CursorControlling` on the dedicated event tap thread.
public struct CursorOverlayState: Hashable, Sendable {
    public var isVisible: Bool
    /// Cursor position inside global CoreGraphics (Y-down) coordinates on the scaled overlay.
    public var scaledCGPosition: CGPoint
    /// Effective cursor visual scale factor.
    public var scaleFactor: Double
    /// True when a 3D game has locked/grabbed relative mouse movement.
    public var isMouseGrabbedByGame: Bool
    /// True when the cursor is currently hidden due to idle timeout.
    public var isIdleHidden: Bool

    public init(
        isVisible: Bool = false,
        scaledCGPosition: CGPoint = .zero,
        scaleFactor: Double = 1.0,
        isMouseGrabbedByGame: Bool = false,
        isIdleHidden: Bool = false
    ) {
        self.isVisible = isVisible
        self.scaledCGPosition = scaledCGPosition
        self.scaleFactor = max(0.25, scaleFactor)
        self.isMouseGrabbedByGame = isMouseGrabbedByGame
        self.isIdleHidden = isIdleHidden
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(isVisible)
        hasher.combine(scaledCGPosition.x)
        hasher.combine(scaledCGPosition.y)
        hasher.combine(scaleFactor)
        hasher.combine(isMouseGrabbedByGame)
        hasher.combine(isIdleHidden)
    }
}

/// Contract implemented by `MetalPieInput` for cursor confinement, zero-delta-drift mapping,
/// FPS mouse-grab detection, and balanced `CGDisplayHideCursor`/`CGDisplayShowCursor` refcounting.
public protocol CursorControlling: AnyObject, Sendable {
    var isActive: Bool { get }
    var currentState: CursorOverlayState { get }

    func start(
        configuration: CursorMappingConfiguration,
        onStateChange: @escaping @Sendable (CursorOverlayState) -> Void
    ) throws

    func update(configuration: CursorMappingConfiguration)

    /// Temporarily releases confinement and restores the hardware cursor (e.g. on target focus loss).
    func suspend()

    /// Re-engages confinement and scaled cursor rendering when target regains focus.
    func resume()

    /// Unconditionally stops the event tap, releases confinement, and balances cursor hide/show refcount.
    func stop()
}

/// Window focus, geometry, and lifecycle transitions observed by `WindowTracking`.
public enum WindowLifecycleEvent: Sendable {
    case activeWindowChanged(WindowDescriptor?)
    case trackedWindowMoved(WindowDescriptor)
    case trackedWindowMinimized(CGWindowID)
    case trackedWindowRestored(WindowDescriptor)
    case trackedWindowClosed(CGWindowID)
    case trackedWindowFocusLost(CGWindowID)
    case trackedWindowFocusGained(WindowDescriptor)
}

/// Contract implemented by `MetalPieInput` for window discovery, focus tracking, and auto-scale monitoring.
public protocol WindowTracking: AnyObject, Sendable {
    func listCapturableWindows() -> [WindowDescriptor]
    func activeFrontmostWindow() -> WindowDescriptor?

    func startObserving(
        trackedWindowID: CGWindowID?,
        onEvent: @escaping @Sendable (WindowLifecycleEvent) -> Void
    )

    func updateTrackedWindow(_ windowID: CGWindowID?)
    func stopObserving()
}

/// Contract implemented by `MetalPieInput` for Carbon `RegisterEventHotKey` global shortcuts + panic stop.
public protocol HotkeyManaging: AnyObject, Sendable {
    func register(
        config: HotkeyConfig,
        handler: @escaping @Sendable (HotkeyAction) -> Void
    ) throws

    func unregisterAll()
}

// MARK: - High-Level Session Orchestrator Contract (`MetalPieApp` / `MetalPieCapture`)

/// Top-level coordinator contract linking capture, effect rendering, overlay window, and input control.
public protocol ScalingSessionCoordinating: AnyObject, Sendable {
    var currentTelemetry: SessionTelemetry { get }

    func startScaling(
        window: WindowDescriptor,
        profile: Profile,
        scalingMode: ScalingMode,
        presentationOverride: PresentationMode?
    ) async throws

    func stopScaling() async

    func togglePresentationMode() async throws

    func captureScreenshot(
        to directory: URL,
        template: String
    ) async throws -> URL
}
