import AppKit
import CoreGraphics
import Foundation
import Metal
import MetalPieCore
import QuartzCore
import os

// MARK: - GPU Overlay Sprite Payloads (for VRR Direct-Scanout Mode)

/// GPU-composited cursor sprite snapshot used when VRR direct-scanout disables WindowServer sublayers.
public struct GPUCursorSpriteSnapshot: @unchecked Sendable {
    public var isVisible: Bool
    /// Normalized `[0, 1]` cursor hotspot position in overlay drawable coordinates (Y-down).
    public var normalizedPosition: CGPoint
    /// Sprite size in drawable pixels.
    public var pixelSize: CGSize
    /// Hotspot offset inside the sprite in `[0, 1]` fractions (top-left origin).
    public var normalizedHotSpot: CGPoint
    public var useNearestFilter: Bool
    public var texture: (any MTLTexture)?

    public init(
        isVisible: Bool = false,
        normalizedPosition: CGPoint = .zero,
        pixelSize: CGSize = .zero,
        normalizedHotSpot: CGPoint = .zero,
        useNearestFilter: Bool = false,
        texture: (any MTLTexture)? = nil
    ) {
        self.isVisible = isVisible
        self.normalizedPosition = normalizedPosition
        self.pixelSize = pixelSize
        self.normalizedHotSpot = normalizedHotSpot
        self.useNearestFilter = useNearestFilter
        self.texture = texture
    }
}

/// GPU-composited HUD overlay texture snapshot used when VRR direct-scanout disables child HUD windows.
public struct GPUHUDOverlaySnapshot: @unchecked Sendable {
    public var isVisible: Bool
    /// Target placement inside overlay drawable pixels (Y-down).
    public var pixelRect: PixelRect
    public var texture: (any MTLTexture)?

    public init(
        isVisible: Bool = false,
        pixelRect: PixelRect = .zero,
        texture: (any MTLTexture)? = nil
    ) {
        self.isVisible = isVisible
        self.pixelRect = pixelRect
        self.texture = texture
    }
}

// MARK: - RenderSessionConfiguration

/// Immutable snapshot of rendering parameters passed to `RenderLoopController`.
public struct RenderSessionConfiguration: Sendable {
    public var targetWindowName: String
    public var profile: Profile
    public var scalingMode: ScalingMode
    public var overlayMetrics: OverlayDrawableMetrics
    public var vrrDirectScanout: Bool
    public var isNativeFullscreenSource: Bool

    public init(
        targetWindowName: String,
        profile: Profile,
        scalingMode: ScalingMode,
        overlayMetrics: OverlayDrawableMetrics,
        vrrDirectScanout: Bool = false,
        isNativeFullscreenSource: Bool = false
    ) {
        self.targetWindowName = targetWindowName
        self.profile = profile
        self.scalingMode = scalingMode
        self.overlayMetrics = overlayMetrics
        self.vrrDirectScanout = vrrDirectScanout
        self.isNativeFullscreenSource = isNativeFullscreenSource
    }
}

// MARK: - Single-Slot Frame Mailbox

/// Tiny-lock single-slot mailbox decoupling `SCStream`'s capture queue from the dedicated render thread.
/// Unconsumed older frames are immediately superseded so capture-to-photon latency stays minimal.
private final class FrameMailbox: @unchecked Sendable {
    private struct Storage: Sendable {
        var latestFrame: CapturedFrame?
        var supersededCount: UInt64 = 0
        var generation: UInt64 = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: Storage())

    /// Deposits the newest captured frame, returning `true` if a previous unconsumed frame was dropped.
    @discardableResult
    func deposit(_ frame: CapturedFrame) -> Bool {
        lock.withLock { s in
            let dropped = s.latestFrame != nil
            if dropped {
                s.supersededCount &+= 1
            }
            s.latestFrame = frame
            s.generation &+= 1
            return dropped
        }
    }

    /// Takes and clears the latest captured frame if one is waiting.
    func take() -> (frame: CapturedFrame?, supersededDelta: UInt64) {
        lock.withLock { s in
            let frame = s.latestFrame
            let dropped = s.supersededCount
            s.latestFrame = nil
            s.supersededCount = 0
            return (frame, dropped)
        }
    }

    var hasPendingFrame: Bool {
        lock.withLock { $0.latestFrame != nil }
    }

    func clear() {
        lock.withLock { s in
            s.latestFrame = nil
            s.supersededCount = 0
        }
    }
}

// MARK: - Cadence Tracker (for Frame Generation Pacing)

/// Tracks true source frame interval using a 5-sample median + EMA so Frame Generation
/// stays cleanly paced on 24/30/48/60 fps sources despite capture timestamp jitter.
private struct CadenceTracker: Sendable {
    private var lastTimestamp: Double = 0
    private var recentIntervals: [Double] = []
    private var smoothedInterval: Double = 1.0 / 60.0
    private var sampleCount: Int = 0

    mutating func reset() {
        lastTimestamp = 0
        recentIntervals.removeAll(keepingCapacity: true)
        smoothedInterval = 1.0 / 60.0
        sampleCount = 0
    }

    mutating func recordFrame(timestamp: Double) {
        defer { lastTimestamp = timestamp }
        guard lastTimestamp > 0 else { return }
        let dt = timestamp - lastTimestamp
        // Ignore duplicate timestamps or long pauses (> 250 ms).
        guard dt >= 0.002 && dt <= 0.25 else { return }

        recentIntervals.append(dt)
        if recentIntervals.count > 5 {
            recentIntervals.removeFirst()
        }
        let sorted = recentIntervals.sorted()
        let median = sorted[sorted.count / 2]

        if sampleCount == 0 {
            smoothedInterval = median
        } else {
            smoothedInterval = smoothedInterval * 0.8 + median * 0.2
        }
        sampleCount += 1
    }

    var estimatedIntervalSeconds: Double {
        min(max(smoothedInterval, 1.0 / 240.0), 0.1)
    }

    var estimatedFPS: Double {
        guard sampleCount >= 2, smoothedInterval > 0 else { return 0 }
        return 1.0 / smoothedInterval
    }

    var hasReliableEstimate: Bool {
        sampleCount >= 3 && smoothedInterval > 0
    }
}

// MARK: - Rolling Window FPS Counter (Zero Jensen-Inequality Bias)

/// Unbiased rolling-window FPS estimator measuring exact `(frames - 1) / span` over a sliding
/// time window (default `0.6 s`).
///
/// Unlike averaging instantaneous `1 / dt` values (which suffers Jensen's-inequality upward bias
/// `E[1/dt] > 1/E[dt]` and inflates jittered 120 Hz cadences to 150-170 fps), counting events
/// over their true elapsed span reports the exact true frame rate regardless of timing jitter.
public struct RollingFPSCounter: Sendable {
    public let windowSeconds: Double
    private var timestamps: [Double] = []
    private var headIndex: Int = 0
    public private(set) var lastTimestamp: Double = 0
    public private(set) var currentFPS: Double = 0

    public init(windowSeconds: Double = 0.6) {
        self.windowSeconds = max(0.1, windowSeconds)
    }

    public mutating func reset() {
        timestamps.removeAll(keepingCapacity: true)
        headIndex = 0
        lastTimestamp = 0
        currentFPS = 0
    }

    @discardableResult
    public mutating func record(at rawTimestamp: Double) -> Double {
        guard rawTimestamp.isFinite, rawTimestamp > 0 else { return currentFPS }
        // After a long pause (> 2 s), restart cleanly so pre-pause gaps don't drag down FPS.
        if lastTimestamp > 0 && (rawTimestamp - lastTimestamp) >= 2.0 {
            timestamps.removeAll(keepingCapacity: true)
            headIndex = 0
            currentFPS = 0
        }
        // Keep timestamps monotonic even if async presented callbacks arrive slightly out of order.
        let t = max(rawTimestamp, lastTimestamp)
        lastTimestamp = t
        timestamps.append(t)

        let cutoff = t - windowSeconds
        while headIndex + 2 < timestamps.count && timestamps[headIndex] < cutoff {
            headIndex += 1
        }
        if headIndex >= 64 && headIndex * 2 >= timestamps.count {
            timestamps.removeFirst(headIndex)
            headIndex = 0
        }

        let activeCount = timestamps.count - headIndex
        if activeCount >= 2 {
            let span = t - timestamps[headIndex]
            if span >= 0.002 {
                currentFPS = Double(activeCount - 1) / span
            }
        }
        return currentFPS
    }

    /// Returns `currentFPS`, decaying cleanly to `0` if no frame arrived within `idleTimeout`.
    public func fps(at now: Double, idleTimeout: Double = 1.5) -> Double {
        guard lastTimestamp > 0 else { return 0 }
        if (now - lastTimestamp) > idleTimeout {
            return 0
        }
        return currentFPS
    }
}

// MARK: - Telemetry Accumulator

/// Rolling-window telemetry accumulator computing unbiased `sourceFPS`, `outputFPS`, `presentedFPS`,
/// GPU `frameTimeMs`, duplicate skips, dropped frames, and per-pass timings.
private final class TelemetryAccumulator: @unchecked Sendable {
    private struct State: Sendable {
        var telemetry = SessionTelemetry.idle
        var sourceCounter = RollingFPSCounter(windowSeconds: 0.6)
        var outputCounter = RollingFPSCounter(windowSeconds: 0.6)
        var presentCounter = RollingFPSCounter(windowSeconds: 0.6)
        var lastPublishTime: Double = 0
        var lastRenderConsumeTime: Double = 0
        var displayIntervalSeconds: Double = 1.0 / 60.0
        var resizeGraceUntil: Double = 0
        var lastSourceSize: PixelSize = .zero
        var lastDrawableSize: PixelSize = .zero
        var frameTimeMs: Double = 0
        var hasPublishedNonZeroFPS: Bool = false
        var hasPublishedNonZeroFrameTime: Bool = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func reset(state: SessionState, gpuName: String, backendName: String, targetWindowName: String, displayRefreshHz: Double = 60.0) {
        lock.withLock { s in
            s = State()
            s.displayIntervalSeconds = 1.0 / max(30.0, displayRefreshHz)
            s.telemetry = SessionTelemetry(
                state: state,
                targetWindowName: targetWindowName,
                backendName: backendName,
                gpuName: gpuName
            )
        }
    }

    func setDisplayRefreshRate(_ hz: Double) {
        lock.withLock { s in
            s.displayIntervalSeconds = 1.0 / max(30.0, hz)
        }
    }

    func updateSessionMetadata(
        state: SessionState? = nil,
        targetWindowName: String? = nil,
        backendName: String? = nil,
        inputSize: PixelSize? = nil,
        outputSize: PixelSize? = nil,
        frameGenActive: Bool? = nil,
        frameGenMultiplier: Int? = nil,
        hdrActive: Bool? = nil
    ) {
        lock.withLock { s in
            if let state { s.telemetry.state = state }
            if let targetWindowName { s.telemetry.targetWindowName = targetWindowName }
            if let backendName { s.telemetry.backendName = backendName }
            if let inputSize { s.telemetry.inputSize = inputSize }
            if let outputSize { s.telemetry.outputSize = outputSize }
            if let frameGenActive { s.telemetry.frameGenActive = frameGenActive }
            if let frameGenMultiplier { s.telemetry.frameGenMultiplier = max(1, frameGenMultiplier) }
            if let hdrActive { s.telemetry.hdrActive = hdrActive }
        }
    }

    func recordRenderConsumed(now: Double) {
        lock.withLock { s in
            s.lastRenderConsumeTime = now
        }
    }

    func recordSourceSize(_ size: PixelSize, now: Double) {
        guard size.isValid else { return }
        lock.withLock { s in
            if s.lastSourceSize.isValid && s.lastSourceSize != size {
                s.resizeGraceUntil = max(s.resizeGraceUntil, now + 0.35)
            }
            s.lastSourceSize = size
        }
    }

    func recordDrawableSize(_ size: PixelSize, now: Double) {
        guard size.isValid else { return }
        lock.withLock { s in
            if s.lastDrawableSize.isValid && s.lastDrawableSize != size {
                s.resizeGraceUntil = max(s.resizeGraceUntil, now + 0.35)
            }
            s.lastDrawableSize = size
        }
    }

    func recordDroppedPresent(now: Double = CACurrentMediaTime(), count: UInt64 = 1) {
        lock.withLock { s in
            // Do not falsely count transient swapchain/drawable transitions during live window resize as drops.
            guard now >= s.resizeGraceUntil else { return }
            s.telemetry.droppedFrames &+= count
        }
    }

    func recordSourceFrame(now: Double, mailboxSuperseded: Bool) {
        lock.withLock { s in
            // Distinguish true render-deadline-miss drops from harmless sub-vsync mailbox coalescing
            // and transient source/drawable dimension changes during live window resize / titlebar zoom.
            if mailboxSuperseded,
               now >= s.resizeGraceUntil,
               s.lastRenderConsumeTime > 0,
               (now - s.lastRenderConsumeTime) > s.displayIntervalSeconds * 1.45
            {
                s.telemetry.droppedFrames &+= 1
            }
            s.telemetry.sourceFPS = s.sourceCounter.record(at: now)
        }
    }

    func recordOutputFrame(
        now: Double,
        wasDuplicateSkipped: Bool,
        passTimings: [PassTiming]
    ) {
        lock.withLock { s in
            if wasDuplicateSkipped {
                s.telemetry.duplicateFramesSkipped &+= 1
            }
            s.telemetry.outputFPS = s.outputCounter.record(at: now)
            if !passTimings.isEmpty {
                s.telemetry.passTimings = passTimings
            }
        }
    }

    func recordGPUFrameTimeMs(_ ms: Double) {
        guard ms > 0 && ms < 1000 else { return }
        lock.withLock { s in
            s.frameTimeMs = s.frameTimeMs == 0 ? ms : (s.frameTimeMs * 0.85 + ms * 0.15)
            s.telemetry.frameTimeMs = s.frameTimeMs
        }
    }

    func recordPresented(presentedTime: Double) {
        lock.withLock { s in
            s.telemetry.presentedFPS = s.presentCounter.record(at: presentedTime)
        }
    }

    func snapshot() -> SessionTelemetry {
        lock.withLock { s in
            var copy = s.telemetry
            let now = CACurrentMediaTime()
            // Decay stale FPS readouts cleanly to 0 if idle > 1.5 s.
            copy.sourceFPS = s.sourceCounter.fps(at: now)
            copy.outputFPS = s.outputCounter.fps(at: now)
            copy.presentedFPS = s.presentCounter.fps(at: now)
            return copy
        }
    }

    /// Returns a telemetry snapshot if at least `minInterval` seconds (default 0.2 s = 5 Hz) have elapsed,
    /// OR immediately during startup as soon as the first real non-zero FPS / GPU frame time arrives so
    /// the HUD never lingers at `0.0 fps / 0.00 ms`.
    func snapshotIfDue(now: Double, minInterval: Double = 0.2) -> SessionTelemetry? {
        lock.withLock { s in
            let hasFreshFPS = !s.hasPublishedNonZeroFPS
                && (s.telemetry.sourceFPS > 0 || s.telemetry.outputFPS > 0 || s.telemetry.presentedFPS > 0)
            let hasFreshFrameTime = !s.hasPublishedNonZeroFrameTime && s.telemetry.frameTimeMs > 0
            guard hasFreshFPS || hasFreshFrameTime || (now - s.lastPublishTime >= minInterval) else {
                return nil
            }
            if s.telemetry.sourceFPS > 0 || s.telemetry.outputFPS > 0 || s.telemetry.presentedFPS > 0 {
                s.hasPublishedNonZeroFPS = true
            }
            if s.telemetry.frameTimeMs > 0 {
                s.hasPublishedNonZeroFrameTime = true
            }
            s.lastPublishTime = now
            var copy = s.telemetry
            copy.sourceFPS = s.sourceCounter.fps(at: now)
            copy.outputFPS = s.outputCounter.fps(at: now)
            copy.presentedFPS = s.presentCounter.fps(at: now)
            return copy
        }
    }
}

// MARK: - Self-Contained Inline MSL Present & Screenshot Convert Pass

private final class PresentPassRenderer {
    struct PresentUniforms {
        var uvMin: SIMD2<Float>
        var uvSize: SIMD2<Float>
    }

    struct SpriteUniforms {
        var rectMin: SIMD2<Float>   // normalized NDC or [0,1] viewport space
        var rectSize: SIMD2<Float>
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PresentVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct PresentUniforms {
        float2 uvMin;
        float2 uvSize;
    };

    vertex PresentVertexOut presentTriangleVertex(
        uint vid [[vertex_id]],
        constant PresentUniforms& u [[buffer(0)]]
    ) {
        // Full-screen triangle covering clip space [-1, 1].
        float2 pos = float2((vid == 1) ? 3.0f : -1.0f, (vid == 2) ? -3.0f : 1.0f);
        float2 baseUV = float2((vid == 1) ? 2.0f : 0.0f, (vid == 2) ? 2.0f : 0.0f);
        PresentVertexOut out;
        out.position = float4(pos, 0.0f, 1.0f);
        out.uv = u.uvMin + baseUV * u.uvSize;
        return out;
    }

    fragment half4 presentFragmentLinear(
        PresentVertexOut in [[stage_in]],
        texture2d<half, access::sample> tex [[texture(0)]]
    ) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        return half4(tex.sample(s, in.uv).rgb, 1.0h);
    }

    fragment half4 presentFragmentNearest(
        PresentVertexOut in [[stage_in]],
        texture2d<half, access::sample> tex [[texture(0)]]
    ) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
        return half4(tex.sample(s, in.uv).rgb, 1.0h);
    }

    struct SpriteUniforms {
        float2 rectMin;
        float2 rectSize;
    };

    vertex PresentVertexOut spriteQuadVertex(
        uint vid [[vertex_id]],
        constant SpriteUniforms& u [[buffer(0)]]
    ) {
        constexpr float2 corners[6] = {
            float2(0.0f, 0.0f), float2(1.0f, 0.0f), float2(0.0f, 1.0f),
            float2(1.0f, 0.0f), float2(1.0f, 1.0f), float2(0.0f, 1.0f)
        };
        float2 c = corners[vid];
        float2 p01 = u.rectMin + c * u.rectSize;
        // Convert [0, 1] Y-down to NDC [-1, 1] Y-up.
        float2 ndc = float2(p01.x * 2.0f - 1.0f, 1.0f - p01.y * 2.0f);
        PresentVertexOut out;
        out.position = float4(ndc, 0.0f, 1.0f);
        out.uv = c;
        return out;
    }

    fragment half4 spriteFragmentLinear(
        PresentVertexOut in [[stage_in]],
        texture2d<half, access::sample> tex [[texture(0)]]
    ) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        return tex.sample(s, in.uv);
    }

    fragment half4 spriteFragmentNearest(
        PresentVertexOut in [[stage_in]],
        texture2d<half, access::sample> tex [[texture(0)]]
    ) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
        return tex.sample(s, in.uv);
    }

    // Converts any input format (BGRA8 / BGR10A2 / RGBA16F HDR) + UV sub-rect into BGRA8 for CGImage screenshots.
    kernel void copyScreenshotBGRA8(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant PresentUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint dstW = dst.get_width();
        uint dstH = dst.get_height();
        if (gid.x >= dstW || gid.y >= dstH) { return; }

        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = u.uvMin + ((float2(gid) + 0.5f) / float2(dstW, dstH)) * u.uvSize;
        float4 c = src.sample(s, uv);
        // Soft Reinhard highlight rolloff only for values > 1.0 (HDR/EDR -> SDR PNG screenshot).
        float3 rgb = max(c.rgb, float3(0.0f));
        float peak = max(rgb.r, max(rgb.g, rgb.b));
        if (peak > 1.0f) {
            rgb = rgb / (1.0f + rgb) * 2.0f;
            rgb = clamp(rgb, 0.0f, 1.0f);
        }
        dst.write(float4(rgb, 1.0f), gid);
    }
    """

    private let device: any MTLDevice
    private let library: any MTLLibrary
    private var presentLinearPipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
    private var presentNearestPipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
    private var spriteLinearPipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
    private var spriteNearestPipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
    private let screenshotPipeline: any MTLComputePipelineState

    init(device: any MTLDevice) throws {
        self.device = device
        self.library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let ssFn = library.makeFunction(name: "copyScreenshotBGRA8") else {
            throw EngineError.shaderCompilationFailed(
                effectID: .bilinear,
                detail: "Missing copyScreenshotBGRA8 kernel."
            )
        }
        self.screenshotPipeline = try device.makeComputePipelineState(function: ssFn)
    }

    func encodePresent(
        commandBuffer: any MTLCommandBuffer,
        drawableTexture: any MTLTexture,
        sourceTexture: any MTLTexture,
        layout: ScalingLayoutResult,
        cursorSprite: GPUCursorSpriteSnapshot?,
        hudOverlay: GPUHUDOverlaySnapshot?
    ) {
        let drawableW = drawableTexture.width
        let drawableH = drawableTexture.height
        guard drawableW > 0 && drawableH > 0 else { return }

        let visibleRect = layout.visibleContentPixelRect
        let fillsEntireDrawable = visibleRect.x == 0
            && visibleRect.y == 0
            && visibleRect.width == drawableW
            && visibleRect.height == drawableH

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawableTexture
        rpd.colorAttachments[0].loadAction = fillsEntireDrawable ? .dontCare : .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.label = "MetalPie Present Pass"

        // 1. Draw upscaled image into visibleContentPixelRect (preserving aspect ratio, letterbox/pillarbox, alignment).
        if !visibleRect.isEmpty {
            let useNearest = sourceTexture.width == visibleRect.width
                && sourceTexture.height == visibleRect.height
            if let pipeline = presentPipeline(for: drawableTexture.pixelFormat, nearest: useNearest) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setViewport(MTLViewport(
                    originX: Double(visibleRect.x),
                    originY: Double(visibleRect.y),
                    width: Double(visibleRect.width),
                    height: Double(visibleRect.height),
                    znear: 0,
                    zfar: 1
                ))

                let uv = layout.visibleTextureUVRect
                var uniforms = PresentUniforms(
                    uvMin: SIMD2<Float>(Float(uv.minX), Float(uv.minY)),
                    uvSize: SIMD2<Float>(Float(uv.width), Float(uv.height))
                )
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<PresentUniforms>.stride, index: 0)
                encoder.setFragmentTexture(sourceTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        // 2. Optional GPU-composited HUD & Cursor sprites in the exact same Apple Silicon TBDR tile pass (VRR Direct-Scanout!).
        let fullViewport = MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(drawableW),
            height: Double(drawableH),
            znear: 0,
            zfar: 1
        )

        if let hud = hudOverlay, hud.isVisible, let hudTex = hud.texture, !hud.pixelRect.isEmpty {
            if let pipeline = spritePipeline(for: drawableTexture.pixelFormat, nearest: true) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setViewport(fullViewport)
                var uniforms = SpriteUniforms(
                    rectMin: SIMD2<Float>(
                        Float(hud.pixelRect.x) / Float(drawableW),
                        Float(hud.pixelRect.y) / Float(drawableH)
                    ),
                    rectSize: SIMD2<Float>(
                        Float(hud.pixelRect.width) / Float(drawableW),
                        Float(hud.pixelRect.height) / Float(drawableH)
                    )
                )
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SpriteUniforms>.stride, index: 0)
                encoder.setFragmentTexture(hudTex, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        if let cursor = cursorSprite, cursor.isVisible, let cursorTex = cursor.texture,
           cursor.pixelSize.width > 0, cursor.pixelSize.height > 0
        {
            if let pipeline = spritePipeline(
                for: drawableTexture.pixelFormat,
                nearest: cursor.useNearestFilter
            ) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setViewport(fullViewport)

                let normW = Float(cursor.pixelSize.width) / Float(drawableW)
                let normH = Float(cursor.pixelSize.height) / Float(drawableH)
                let originX = Float(cursor.normalizedPosition.x) - Float(cursor.normalizedHotSpot.x) * normW
                let originY = Float(cursor.normalizedPosition.y) - Float(cursor.normalizedHotSpot.y) * normH

                // Snap sprite origin to whole pixels for razor-sharp cursor rendering.
                let snappedX = floor(originX * Float(drawableW) + 0.5) / Float(drawableW)
                let snappedY = floor(originY * Float(drawableH) + 0.5) / Float(drawableH)

                var uniforms = SpriteUniforms(
                    rectMin: SIMD2<Float>(snappedX, snappedY),
                    rectSize: SIMD2<Float>(normW, normH)
                )
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SpriteUniforms>.stride, index: 0)
                encoder.setFragmentTexture(cursorTex, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        encoder.endEncoding()
    }

    func encodeScreenshotReadback(
        commandBuffer: any MTLCommandBuffer,
        sourceTexture: any MTLTexture,
        uvRect: CGRect,
        outputSize: PixelSize
    ) -> (any MTLTexture)? {
        guard outputSize.isValid else { return nil }
        let safeSize = ScalingLayoutCalculator.clampAspectPreserving(outputSize)
        guard safeSize.isValid else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: clampMetalTextureDimension(safeSize.width),
            height: clampMetalTextureDimension(safeSize.height),
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        guard let staging = device.makeTexture(descriptor: desc),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return nil
        }

        encoder.label = "MetalPie Cursor-Free Screenshot"
        encoder.setComputePipelineState(screenshotPipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(staging, index: 1)

        var uniforms = PresentUniforms(
            uvMin: SIMD2<Float>(Float(uvRect.minX), Float(uvRect.minY)),
            uvSize: SIMD2<Float>(Float(uvRect.width), Float(uvRect.height))
        )
        encoder.setBytes(&uniforms, length: MemoryLayout<PresentUniforms>.stride, index: 0)

        let tgW = min(16, screenshotPipeline.threadExecutionWidth)
        let tgH = max(1, min(16, screenshotPipeline.maxTotalThreadsPerThreadgroup / tgW))
        encoder.dispatchThreads(
            MTLSize(width: staging.width, height: staging.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
        )
        encoder.endEncoding()
        return staging
    }

    static func makeCGImage(fromBGRA8SharedTexture texture: any MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        guard width > 0 && height > 0 else { return nil }

        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func presentPipeline(
        for format: MTLPixelFormat,
        nearest: Bool
    ) -> (any MTLRenderPipelineState)? {
        if nearest, let cached = presentNearestPipelines[format] { return cached }
        if !nearest, let cached = presentLinearPipelines[format] { return cached }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "presentTriangleVertex")
        desc.fragmentFunction = library.makeFunction(
            name: nearest ? "presentFragmentNearest" : "presentFragmentLinear"
        )
        desc.colorAttachments[0].pixelFormat = format
        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        if nearest {
            presentNearestPipelines[format] = state
        } else {
            presentLinearPipelines[format] = state
        }
        return state
    }

    private func spritePipeline(
        for format: MTLPixelFormat,
        nearest: Bool
    ) -> (any MTLRenderPipelineState)? {
        if nearest, let cached = spriteNearestPipelines[format] { return cached }
        if !nearest, let cached = spriteLinearPipelines[format] { return cached }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "spriteQuadVertex")
        desc.fragmentFunction = library.makeFunction(
            name: nearest ? "spriteFragmentNearest" : "spriteFragmentLinear"
        )
        desc.colorAttachments[0].pixelFormat = format
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        if nearest {
            spriteNearestPipelines[format] = state
        } else {
            spriteLinearPipelines[format] = state
        }
        return state
    }
}

// MARK: - Dedicated User-Interactive Render Thread

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

private final class RenderThread: Thread, @unchecked Sendable {
    private struct RunLoopBox: @unchecked Sendable {
        var runLoop: CFRunLoop?
    }

    private let readySemaphore = DispatchSemaphore(value: 0)
    private let runLoopLock = OSAllocatedUnfairLock<RunLoopBox>(initialState: RunLoopBox(runLoop: nil))
    private let stopRequested = OSAllocatedUnfairLock<Bool>(initialState: false)

    override init() {
        super.init()
        name = "com.metalpie.render-thread"
        qualityOfService = .userInteractive
    }

    func startAndWait() {
        start()
        readySemaphore.wait()
    }

    override func main() {
        autoreleasepool {
            let rl = RunLoop.current
            let cfRL = rl.getCFRunLoop()
            let port = Port()
            rl.add(port, forMode: .default)
            rl.add(port, forMode: .common)
            let box = RunLoopBox(runLoop: cfRL)
            runLoopLock.withLock { $0 = box }
            readySemaphore.signal()

            while !stopRequested.withLock({ $0 }) {
                autoreleasepool {
                    _ = CFRunLoopRunInMode(.defaultMode, 1.0, true)
                }
            }

            runLoopLock.withLock { $0.runLoop = nil }
            rl.remove(port, forMode: .default)
            rl.remove(port, forMode: .common)
        }
    }

    func perform(_ block: @escaping @Sendable () -> Void) {
        let box = runLoopLock.withLock { $0 }
        guard let cfRL = box.runLoop else { return }
        CFRunLoopPerformBlock(cfRL, CFRunLoopMode.commonModes.rawValue) {
            block()
        }
        CFRunLoopWakeUp(cfRL)
    }

    func performSync(_ block: @escaping @Sendable () -> Void) {
        if Thread.current === self {
            block()
            return
        }
        let box = runLoopLock.withLock { $0 }
        guard let cfRL = box.runLoop else { return }
        let sem = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(cfRL, CFRunLoopMode.commonModes.rawValue) {
            block()
            sem.signal()
        }
        CFRunLoopWakeUp(cfRL)
        sem.wait()
    }

    func shutdown() {
        stopRequested.withLock { $0 = true }
        let box = runLoopLock.withLock { $0 }
        if let cfRL = box.runLoop {
            CFRunLoopStop(cfRL)
            CFRunLoopWakeUp(cfRL)
        }
    }
}

// MARK: - RenderLoopController

/// Decoupled dual-thread Metal presentation, effect-graph execution, Frame Generation scheduler,
/// telemetry publisher, and cursor-free screenshot controller.
///
/// Coded strictly against `MetalPieCore`'s `EffectRendering` and `FrameInterpolating` protocols
/// (zero compile-time or runtime coupling to `MetalPieShaders`'s concrete classes).
public final class RenderLoopController: NSObject, @unchecked Sendable {
    private enum DriverMode: Equatable {
        case stopped
        case displayLink
        case directPresent
        case vrrDirectScanout
    }

    private struct ScheduledFGBeat {
        var factor: Float
        var targetTime: Double
    }

    private struct SharedControlState: Sendable {
        var isRunning: Bool = false
        var isPaused: Bool = false
        var sessionGeneration: UInt64 = 0
        var inFlightCommandBuffers: Int = 0
        var configuration: RenderSessionConfiguration?
        var latestLayout: ScalingLayoutResult?
        var gpuCursorSprite: GPUCursorSpriteSnapshot?
        var gpuHUDOverlay: GPUHUDOverlaySnapshot?
        var needsGraphicsRedraw: Bool = false
        var configDirty: Bool = false
        var pendingScreenshots: [@Sendable (Result<CGImage, Error>) -> Void] = []
        var onFirstFramePresented: (@Sendable () -> Void)?
        var onTelemetry: (@Sendable (SessionTelemetry) -> Void)?
        var onLayoutUpdated: (@Sendable (ScalingLayoutResult) -> Void)?
        var onMarkDisplayLinkAttached: (@MainActor @Sendable () -> Void)?
        var hasEmittedFirstFrame: Bool = false
    }

    public let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let effectRenderer: any EffectRendering
    private var frameInterpolator: (any FrameInterpolating)?
    private let presentPass: PresentPassRenderer

    private let mailbox = FrameMailbox()
    private let telemetry = TelemetryAccumulator()
    private let control = OSAllocatedUnfairLock(initialState: SharedControlState())
    private let renderThread = RenderThread()

    // Owned EXCLUSIVELY by `renderThread`!
    private var metalLayer: CAMetalLayer?
    private var displayLink: CAMetalDisplayLink?
    private var driverMode: DriverMode = .stopped
    private var directWakeupPending = false
    private var directPresentPacer = DirectPresentPacer()
    private var directPaceTimer: CFRunLoopTimer?
    private var vrrBeatTimer: CFRunLoopTimer?

    // Pooled GPU resources owned exclusively by `renderThread` (zero per-frame allocations).
    private var upscaledRing: [any MTLTexture] = []
    private var upscaledRingIndex: Int = 0
    private var contentCropRing: [any MTLTexture] = []
    private var contentCropRingIndex: Int = 0
    private var lastValidUpscaledTexture: (any MTLTexture)?
    private var lastValidLayout: ScalingLayoutResult?
    /// Private GPU copy of the latest raw captured source frame (already cropped to active `contentRect`)
    /// so mid-session `updateConfiguration` changes re-run effects immediately even on static windows.
    private var lastRawSourceTexture: (any MTLTexture)?
    private var lastRawContentPixelRect: PixelRect = .zero
    private var lastRawSourceIsHDR: Bool = false
    private var frameIndex: UInt64 = 0

    // Frame Generation history ring (4-slot private GPU ring so in-flight frames NEVER alias or stall!).
    private static let fgHistoryRingCapacity = 4
    private var fgHistoryTextures: [any MTLTexture] = []
    private var fgHistoryCursor: Int = 0
    private var fgPreviousIndex: Int?
    private var fgCurrentIndex: Int?
    /// Triple-buffered private GPU ring for FG interpolated outputs (prevents write-after-read GPU hazards!).
    private var fgInterpolatedRing: [any MTLTexture] = []
    private var fgInterpolatedRingIndex: Int = 0
    private var fgPreparedSize: PixelSize = .zero
    private var fgPreparedSettings: FrameGenSettings?
    private var fgPendingBeats: [ScheduledFGBeat] = []
    private var fgHysteresisSuppressedByHighFPS = false
    private var fgConsecutiveDisplayRateBursts: Int = 0
    private var fgBurstCooldownUntil: Double = 0
    private var fgLastNewFrameArrivalTime: Double = 0
    private var fgLastPassTiming: PassTiming?
    private var cadenceTracker = CadenceTracker()

    public init(
        device: (any MTLDevice)? = nil,
        effectRenderer: any EffectRendering,
        frameInterpolator: (any FrameInterpolating)? = nil
    ) throws {
        guard let resolvedDevice = device ?? MTLCreateSystemDefaultDevice() else {
            throw EngineError.metalDeviceUnavailable
        }
        guard let queue = resolvedDevice.makeCommandQueue() else {
            throw EngineError.metalDeviceUnavailable
        }

        self.device = resolvedDevice
        self.commandQueue = queue
        self.effectRenderer = effectRenderer
        self.frameInterpolator = frameInterpolator
        self.presentPass = try PresentPassRenderer(device: resolvedDevice)

        // RenderLoopController manages both cursor-free screenshots (`presentPass.encodeScreenshotReadback`)
        // and duplicate-frame output retention (`lastValidUpscaledTexture`) externally -> eliminate the
        // redundant ~23 MB/frame GPU snapshot blit inside `EffectChainRenderer`!
        if let preScaleConfigurable = effectRenderer as? any EffectPreScaleConfigurable {
            preScaleConfigurable.usesExternalOutputCache = true
        }

        super.init()
        self.renderThread.startAndWait()
    }

    deinit {
        stopInternal()
        renderThread.shutdown()
    }

    // MARK: - Public Callbacks & Telemetry Inspection

    /// Latest rolling telemetry snapshot (thread-safe).
    public var currentTelemetry: SessionTelemetry {
        telemetry.snapshot()
    }

    /// Latest computed `ScalingLayoutResult` (useful for cursor coordinate mapping).
    public var currentLayout: ScalingLayoutResult? {
        control.withLock(\.latestLayout)
    }

    /// Called once when the very first upscaled frame is presented so `OverlayWindowController`
    /// reveals the overlay with zero black flash.
    public func setFirstFrameHandler(_ handler: (@Sendable () -> Void)?) {
        control.withLock { $0.onFirstFramePresented = handler }
    }

    /// Called at ~5 Hz with rolling 500 ms EMA `SessionTelemetry` snapshots.
    public func setTelemetryHandler(_ handler: (@Sendable (SessionTelemetry) -> Void)?) {
        control.withLock { $0.onTelemetry = handler }
    }

    /// Called whenever `ScalingLayoutResult` changes (e.g. source resize, overlay resize, crop change).
    public func setLayoutUpdatedHandler(_ handler: (@Sendable (ScalingLayoutResult) -> Void)?) {
        control.withLock { $0.onLayoutUpdated = handler }
    }

    /// Replaces or clears the optional Frame Generation backend cleanly.
    public func setFrameInterpolator(_ interpolator: (any FrameInterpolating)?) {
        renderThread.perform { [weak self] in
            guard let self else { return }
            self.frameInterpolator?.reset()
            self.frameInterpolator = interpolator
            self.resetFrameGenStateOnRenderThread()
            self.reconfigureDriverOnRenderThread()
        }
    }

    // MARK: - Lifecycle

    /// Starts the decoupled render loop attached to the overlay's `CAMetalLayer`.
    ///
    /// Note: Pass `overlayView` via `@MainActor` callers or ensure `metalLayer.maximumDrawableCount`
    /// was already configured before calling `start(...)`; `RenderLoopController` NEVER mutates
    /// `maximumDrawableCount` (macOS 27 `CAMetalLayerInvalidOperation` safety).
    public func start(
        metalLayer: CAMetalLayer,
        configuration: RenderSessionConfiguration,
        onMarkDisplayLinkAttached: (@MainActor @Sendable () -> Void)? = nil
    ) {
        mailbox.clear()

        let backendLabel = configuration.scalingMode.name
        telemetry.reset(
            state: .starting,
            gpuName: device.name,
            backendName: backendLabel,
            targetWindowName: configuration.targetWindowName,
            displayRefreshHz: configuration.overlayMetrics.screenMaxFPS
        )

        control.withLock { s in
            s.isRunning = true
            s.isPaused = false
            s.sessionGeneration &+= 1
            s.configuration = configuration
            s.hasEmittedFirstFrame = false
            s.needsGraphicsRedraw = false
            s.configDirty = false
            s.latestLayout = nil
            s.onMarkDisplayLinkAttached = onMarkDisplayLinkAttached
        }

        let layerBox = UncheckedBox(value: metalLayer)
        renderThread.performSync { [weak self] in
            guard let self else { return }
            self.metalLayer = layerBox.value
            self.frameIndex = 0
            self.directPresentPacer.reset()
            self.cancelDirectPaceTimerOnRenderThread()
            self.contentCropRing.removeAll()
            self.contentCropRingIndex = 0
            self.lastValidUpscaledTexture = nil
            self.lastValidLayout = nil
            self.lastRawSourceTexture = nil
            self.lastRawContentPixelRect = .zero
            self.lastRawSourceIsHDR = false
            self.resetFrameGenStateOnRenderThread()
            self.reconfigureDriverOnRenderThread()
        }

        PipelineLog.shared.info(
            .render,
            "Started RenderLoopController (mode=\(desiredDriverMode(for: configuration)), screenMaxFPS=\(Int(configuration.overlayMetrics.screenMaxFPS)), fg=\(configuration.profile.frameGen.enabled))."
        )
    }

    /// Updates live rendering configuration (profile, scaling mode, overlay drawable metrics, VRR flag).
    public func updateConfiguration(_ configuration: RenderSessionConfiguration) {
        control.withLock { s in
            s.configuration = configuration
            s.needsGraphicsRedraw = true
            s.configDirty = true
        }
        telemetry.recordDrawableSize(configuration.overlayMetrics.drawablePixelSize, now: CACurrentMediaTime())
        telemetry.setDisplayRefreshRate(configuration.overlayMetrics.screenMaxFPS)
        telemetry.updateSessionMetadata(
            targetWindowName: configuration.targetWindowName,
            backendName: configuration.scalingMode.name,
            hdrActive: configuration.profile.capture.dynamicRange == .hdr
        )

        renderThread.perform { [weak self] in
            guard let self else { return }
            self.reconfigureDriverOnRenderThread()
            self.scheduleDirectOrVRRWakeupIfNeeded()
        }
    }

    /// Pauses presentation (e.g. when target window loses focus) with zero CPU/GPU wakeups.
    public func setPaused(_ paused: Bool) {
        control.withLock { s in
            s.isPaused = paused
            if !paused {
                s.hasEmittedFirstFrame = false
            }
        }
        telemetry.updateSessionMetadata(state: paused ? .suspended : .running)

        renderThread.perform { [weak self] in
            guard let self else { return }
            if paused {
                self.mailbox.clear()
                self.fgPendingBeats.removeAll(keepingCapacity: true)
                self.cancelDirectPaceTimerOnRenderThread()
                self.cancelVRRBeatTimerOnRenderThread()
                self.displayLink?.isPaused = true
            } else {
                self.displayLink?.isPaused = false
                self.scheduleDirectOrVRRWakeupIfNeeded()
            }
        }
    }

    /// Stops the render loop, detaches `CAMetalDisplayLink`, flushes pooled GPU textures, and fails any pending screenshot requests.
    public func stop() {
        stopInternal()
        PipelineLog.shared.info(.render, "Stopped RenderLoopController.")
    }

    /// Synchronous teardown safe to invoke both during normal execution and from `deinit`
    /// (never forms an ObjC `[weak self]` reference during deallocation).
    private func stopInternal() {
        let pendingShots: [@Sendable (Result<CGImage, Error>) -> Void] = control.withLock { s in
            s.isRunning = false
            s.isPaused = false
            s.sessionGeneration &+= 1
            s.configuration = nil
            s.latestLayout = nil
            s.gpuCursorSprite = nil
            s.gpuHUDOverlay = nil
            s.configDirty = false
            s.onMarkDisplayLinkAttached = nil
            s.hasEmittedFirstFrame = false
            let shots = s.pendingScreenshots
            s.pendingScreenshots.removeAll()
            return shots
        }

        mailbox.clear()
        telemetry.updateSessionMetadata(state: .idle)

        for shot in pendingShots {
            shot(.failure(EngineError.screenshotExportFailed("Scaling session stopped before screenshot completed.")))
        }

        // `performSync` blocks until execution completes, so `self` is guaranteed alive for its entire duration.
        let unretainedBox = UncheckedBox(value: Unmanaged.passUnretained(self))
        renderThread.performSync {
            let controller = unretainedBox.value.takeUnretainedValue()
            controller.detachDisplayLinkOnRenderThread()
            controller.cancelDirectPaceTimerOnRenderThread()
            controller.cancelVRRBeatTimerOnRenderThread()
            controller.directPresentPacer.reset()
            controller.driverMode = .stopped
            controller.metalLayer = nil
            controller.upscaledRing.removeAll()
            controller.contentCropRing.removeAll()
            controller.contentCropRingIndex = 0
            controller.lastValidUpscaledTexture = nil
            controller.lastValidLayout = nil
            controller.lastRawSourceTexture = nil
            controller.lastRawContentPixelRect = .zero
            controller.lastRawSourceIsHDR = false
            controller.resetFrameGenStateOnRenderThread()
            controller.effectRenderer.reset()
        }
    }

    // MARK: - Capture Frame Ingestion (Hot Path - Lock-Free/Tiny-Lock)

    /// Deposits a captured GPU frame into the single-slot mailbox without blocking `SCStream`.
    public func ingest(frame: CapturedFrame) {
        let (running, paused) = control.withLock { ($0.isRunning, $0.isPaused) }
        guard running, !paused else { return }

        let now = CACurrentMediaTime()
        telemetry.recordSourceSize(frame.pixelSize, now: now)
        let dropped = mailbox.deposit(frame)
        telemetry.recordSourceFrame(
            now: now,
            mailboxSuperseded: dropped
        )

        // Wake the render thread immediately if running in low-latency direct-present or VRR mode.
        renderThread.perform { [weak self] in
            guard let self else { return }
            if self.driverMode == .directPresent || self.driverMode == .vrrDirectScanout {
                self.scheduleDirectOrVRRWakeupIfNeeded()
            }
        }
    }

    // MARK: - VRR GPU Cursor & HUD Sprite Updates

    /// Updates the GPU-composited cursor sprite snapshot (used when VRR direct-scanout is enabled).
    public func updateGPUCursorSprite(_ snapshot: GPUCursorSpriteSnapshot?) {
        control.withLock { s in
            s.gpuCursorSprite = snapshot
            s.needsGraphicsRedraw = true
        }
        renderThread.perform { [weak self] in
            guard let self else { return }
            if self.driverMode == .vrrDirectScanout || self.driverMode == .directPresent {
                self.scheduleDirectOrVRRWakeupIfNeeded()
            }
        }
    }

    /// Updates the GPU-composited HUD texture snapshot (used when VRR direct-scanout is enabled).
    public func updateGPUHUDOverlay(_ snapshot: GPUHUDOverlaySnapshot?) {
        control.withLock { s in
            s.gpuHUDOverlay = snapshot
            s.needsGraphicsRedraw = true
        }
        renderThread.perform { [weak self] in
            guard let self else { return }
            if self.driverMode == .vrrDirectScanout || self.driverMode == .directPresent {
                self.scheduleDirectOrVRRWakeupIfNeeded()
            }
        }
    }

    // MARK: - Cursor-Free Screenshot Hook

    /// Requests a cursor-free, HUD-free screenshot captured directly from the upscaled Metal output texture.
    public func requestCursorFreeScreenshot(
        completion: @escaping @Sendable (Result<CGImage, Error>) -> Void
    ) {
        let running = control.withLock { s -> Bool in
            guard s.isRunning else { return false }
            s.pendingScreenshots.append(completion)
            return true
        }

        guard running else {
            completion(.failure(EngineError.screenshotExportFailed("No active scaling session.")))
            return
        }

        // Wake render thread even if source window is completely static so screenshot resolves immediately!
        renderThread.perform { [weak self] in
            guard let self else { return }
            if self.driverMode == .directPresent || self.driverMode == .vrrDirectScanout {
                self.scheduleDirectOrVRRWakeupIfNeeded()
            }
        }
    }

    /// Async/await wrapper around `requestCursorFreeScreenshot(completion:)`.
    public func requestCursorFreeScreenshot() async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            requestCursorFreeScreenshot { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Render Thread Driver Switching

    private func desiredDriverMode(for config: RenderSessionConfiguration) -> DriverMode {
        if config.vrrDirectScanout && config.overlayMetrics.isVRRDirectScanoutActive {
            return .vrrDirectScanout
        }
        let fgRequested = isFrameGenAllowedByConfig(config)
        if !fgRequested && config.profile.capture.lowLatencyPresent {
            return .directPresent
        }
        return .displayLink
    }

    private func isFrameGenAllowedByConfig(_ config: RenderSessionConfiguration) -> Bool {
        guard config.profile.frameGen.enabled else { return false }
        if config.profile.threeDGameMode && config.profile.frameGen.disableIn3DGameMode {
            return false
        }
        guard let interpolator = frameInterpolator, interpolator.isSupported else {
            return false
        }
        return true
    }

    private func reconfigureDriverOnRenderThread() {
        guard let config = control.withLock(\.configuration),
              control.withLock(\.isRunning),
              let layer = metalLayer
        else {
            detachDisplayLinkOnRenderThread()
            cancelVRRBeatTimerOnRenderThread()
            driverMode = .stopped
            return
        }

        let targetMode = desiredDriverMode(for: config)
        let maxFPS = Float(max(30.0, config.overlayMetrics.screenMaxFPS))

        switch targetMode {
        case .displayLink:
            cancelDirectPaceTimerOnRenderThread()
            cancelVRRBeatTimerOnRenderThread()
            if displayLink == nil {
                // Always mark the overlay layer as display-link-attached on EVERY creation (including
                // `.directPresent` / `.vrrDirectScanout` -> `.displayLink` transitions) so `maximumDrawableCount`
                // is frozen permanently (macOS 27 `CAMetalLayerInvalidOperation` crash prevention).
                if let markAttached = control.withLock(\.onMarkDisplayLinkAttached) {
                    Task { @MainActor in
                        markAttached()
                    }
                }
                let link = CAMetalDisplayLink(metalLayer: layer)
                link.delegate = self
                link.add(to: RunLoop.current, forMode: .common)
                displayLink = link
            }
            if let link = displayLink {
                // Lock to full display refresh rate (never throttle link to 30Hz, avoiding 2x latency).
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: maxFPS,
                    maximum: maxFPS,
                    preferred: maxFPS
                )
                link.preferredFrameLatency = isFrameGenAllowedByConfig(config) ? 2.0 : 1.0
                link.isPaused = control.withLock(\.isPaused)
            }
            driverMode = .displayLink

        case .directPresent:
            detachDisplayLinkOnRenderThread()
            cancelVRRBeatTimerOnRenderThread()
            driverMode = .directPresent

        case .vrrDirectScanout:
            detachDisplayLinkOnRenderThread()
            cancelDirectPaceTimerOnRenderThread()
            driverMode = .vrrDirectScanout

        case .stopped:
            detachDisplayLinkOnRenderThread()
            cancelDirectPaceTimerOnRenderThread()
            cancelVRRBeatTimerOnRenderThread()
            driverMode = .stopped
        }
    }

    private func detachDisplayLinkOnRenderThread() {
        if let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    private func scheduleDirectOrVRRWakeupIfNeeded() {
        guard driverMode == .directPresent || driverMode == .vrrDirectScanout else { return }

        if driverMode == .directPresent {
            let displayHz = control.withLock { $0.configuration?.overlayMetrics.screenMaxFPS ?? 60.0 }
            let now = CACurrentMediaTime()
            switch directPresentPacer.evaluate(now: now, displayRefreshHz: displayHz) {
            case .submitNow:
                cancelDirectPaceTimerOnRenderThread()
            case .coalesceUntil(let wakeTime):
                // Coalesce bursty capture frames into the single-slot mailbox so `.directPresent`
                // NEVER over-submits past display Hz and exhausts CAMetalLayer's 3-drawable pool.
                if directPaceTimer == nil {
                    scheduleDirectPaceTimerOnRenderThread(at: wakeTime)
                }
                return
            }
        }

        guard !directWakeupPending else { return }
        directWakeupPending = true

        renderThread.perform { [weak self] in
            guard let self else { return }
            self.directWakeupPending = false
            self.renderDirectOrVRRTickOnRenderThread()
        }
    }

    private func scheduleDirectPaceTimerOnRenderThread(at targetTime: Double) {
        cancelDirectPaceTimerOnRenderThread()
        let delay = max(0.0005, targetTime - CACurrentMediaTime())
        let fireDate = CFAbsoluteTimeGetCurrent() + delay
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, fireDate, 0, 0, 0) { [weak self] _ in
            self?.directPaceTimer = nil
            self?.renderDirectOrVRRTickOnRenderThread()
        }
        if let timer {
            directPaceTimer = timer
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        }
    }

    private func cancelDirectPaceTimerOnRenderThread() {
        if let timer = directPaceTimer {
            CFRunLoopTimerInvalidate(timer)
            directPaceTimer = nil
        }
    }

    private func scheduleVRRBeatTimerOnRenderThread(at targetTime: Double) {
        cancelVRRBeatTimerOnRenderThread()
        let delay = max(0.0005, targetTime - CACurrentMediaTime())
        let fireDate = CFAbsoluteTimeGetCurrent() + delay
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, fireDate, 0, 0, 0) { [weak self] _ in
            self?.vrrBeatTimer = nil
            self?.renderDirectOrVRRTickOnRenderThread()
        }
        if let timer {
            vrrBeatTimer = timer
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        }
    }

    private func cancelVRRBeatTimerOnRenderThread() {
        if let timer = vrrBeatTimer {
            CFRunLoopTimerInvalidate(timer)
            vrrBeatTimer = nil
        }
    }

    // MARK: - Core Render Tick (DisplayLink, DirectPresent, VRR)

    private func renderDirectOrVRRTickOnRenderThread() {
        guard let layer = metalLayer else { return }
        let now = CACurrentMediaTime()

        if driverMode == .directPresent {
            let displayHz = control.withLock { $0.configuration?.overlayMetrics.screenMaxFPS ?? 60.0 }
            if case .coalesceUntil(let wakeTime) = directPresentPacer.evaluate(now: now, displayRefreshHz: displayHz) {
                if directPaceTimer == nil {
                    scheduleDirectPaceTimerOnRenderThread(at: wakeTime)
                }
                return
            }
        }

        executeRenderStepOnRenderThread(
            now: now,
            vsyncPeriod: nil,
            acquireDrawable: { layer.nextDrawable() },
            presentDrawable: { cmdBuf, drawable, scheduledPresentationTime in
                if self.driverMode == .vrrDirectScanout,
                   let targetTime = scheduledPresentationTime,
                   targetTime > CACurrentMediaTime() + 0.001
                {
                    cmdBuf.present(drawable, atTime: targetTime)
                } else {
                    cmdBuf.present(drawable)
                }
            }
        )

        // If more FG beats are queued in VRR mode, schedule an exact timer wakeup (zero polling!).
        if driverMode == .vrrDirectScanout, let nextBeat = fgPendingBeats.first {
            scheduleVRRBeatTimerOnRenderThread(at: nextBeat.targetTime)
        }
    }

    /// Unified single-frame render & presentation step executed exclusively on `renderThread`.
    /// Returns BEFORE invoking `acquireDrawable()` on unchanged static frames (zero drawable/GPU waste).
    private func executeRenderStepOnRenderThread(
        now: Double,
        vsyncPeriod: Double?,
        acquireDrawable: () -> (any CAMetalDrawable)?,
        presentDrawable: (any MTLCommandBuffer, any CAMetalDrawable, Double?) -> Void
    ) {
        let snapshot = control.withLock { s -> (
            running: Bool,
            paused: Bool,
            config: RenderSessionConfiguration?,
            cursor: GPUCursorSpriteSnapshot?,
            hud: GPUHUDOverlaySnapshot?,
            redraw: Bool,
            configDirty: Bool,
            hasScreenshots: Bool
        ) in
            let redraw = s.needsGraphicsRedraw
            let cfgDirty = s.configDirty
            s.needsGraphicsRedraw = false
            s.configDirty = false
            return (
                s.isRunning,
                s.isPaused,
                s.configuration,
                s.gpuCursorSprite,
                s.gpuHUDOverlay,
                redraw,
                cfgDirty,
                !s.pendingScreenshots.isEmpty
            )
        }

        guard snapshot.running, !snapshot.paused, let config = snapshot.config else {
            return
        }

        // Check if we have a new captured frame, a due FG beat, a config/graphics redraw, or a pending screenshot.
        let taken = mailbox.take()
        let newFrame = taken.frame

        let displayInterval = 1.0 / max(30.0, config.overlayMetrics.screenMaxFPS)
        let fgPlan = evaluateFrameGenPlan(config: config)
        let fgActive = fgPlan.active

        // In DisplayLink mode, fire queued FG beats on the closest vsync tick (half-vsync tolerance)
        // so minor capture cadence jitter never causes a beat to miss a vsync and get wiped by the next real frame!
        // In timer-driven VRR mode, keep a tight 2 ms tolerance.
        let beatTolerance = vsyncPeriod.map { $0 * 0.45 } ?? 0.002
        var dueBeat: ScheduledFGBeat?
        if newFrame == nil && fgActive && now >= fgBurstCooldownUntil {
            // Drop any stale intermediate beat that fell >1.5 refreshes behind; preserve the real-frame beat (1.0).
            while let head = fgPendingBeats.first,
                  head.factor < 0.999,
                  now > head.targetTime + displayInterval * 1.5
            {
                fgPendingBeats.removeFirst()
            }
            if let head = fgPendingBeats.first, now >= head.targetTime - beatTolerance {
                dueBeat = fgPendingBeats.removeFirst()
            }
        } else if now < fgBurstCooldownUntil {
            fgPendingBeats.removeAll(keepingCapacity: true)
        }

        let screenshots = drainPendingScreenshots()
        let canRerenderStaticConfig = snapshot.configDirty && lastRawSourceTexture != nil

        // Fast path: static frame with no new capture, no FG beat, no config/cursor/HUD redraw, and no screenshot ->
        // return BEFORE acquiring a drawable or allocating a command buffer!
        if newFrame == nil && dueBeat == nil && !snapshot.redraw && !canRerenderStaticConfig && screenshots.isEmpty {
            publishTelemetryIfDue(now: now)
            return
        }

        // Static screenshot-only path when no drawable/config redraw is needed and we already have a cached upscaled texture.
        if newFrame == nil && dueBeat == nil && !snapshot.redraw && !canRerenderStaticConfig && !screenshots.isEmpty,
           let cachedTex = lastValidUpscaledTexture,
           let cachedLayout = lastValidLayout
        {
            executeStaticScreenshotOnly(
                sourceTexture: cachedTex,
                layout: cachedLayout,
                callbacks: screenshots
            )
            return
        }

        // Need either a new frame, an FG beat, a cached raw frame for config re-render, or a cached upscaled texture.
        if newFrame == nil && dueBeat == nil && !canRerenderStaticConfig && lastValidUpscaledTexture == nil {
            for cb in screenshots {
                cb(.failure(EngineError.screenshotExportFailed("No frame has been rendered yet.")))
            }
            return
        }

        guard let drawable = acquireDrawable() else {
            if newFrame != nil || dueBeat != nil {
                telemetry.recordDroppedPresent(now: now)
            }
            if let newFrame {
                // Put frame back if drawable temporarily unavailable.
                mailbox.deposit(newFrame)
            }
            if snapshot.configDirty {
                control.withLock { $0.configDirty = true }
            }
            if snapshot.redraw {
                control.withLock { $0.needsGraphicsRedraw = true }
            }
            if !screenshots.isEmpty {
                requeueScreenshots(screenshots)
            }
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            if snapshot.configDirty {
                control.withLock { $0.configDirty = true }
            }
            if !screenshots.isEmpty {
                requeueScreenshots(screenshots)
            }
            return
        }
        commandBuffer.label = "MetalPie Frame \(frameIndex)"
        frameIndex &+= 1

        var retainedObjects: [any AnyObject] = []
        var effectReport = EffectExecutionReport()
        var extraPassTimings: [PassTiming] = []
        var renderedOutputTexture: (any MTLTexture)? = lastValidUpscaledTexture
        var activeLayout: ScalingLayoutResult? = lastValidLayout

        let targetPixelSize = PixelSize(
            width: drawable.texture.width,
            height: drawable.texture.height
        )
        telemetry.recordDrawableSize(targetPixelSize, now: now)
        let targetCGRect = config.overlayMetrics.cgFrame.width > 0
            ? config.overlayMetrics.cgFrame
            : CGRect(
                x: 0,
                y: 0,
                width: Double(targetPixelSize.width) / config.overlayMetrics.backingScaleFactor,
                height: Double(targetPixelSize.height) / config.overlayMetrics.backingScaleFactor
            )

        // Determine source texture to feed into `EffectRendering`:
        // fresh captured frame, synthesized Frame Generation frame, or cached raw source on live config change.
        var sourceTextureForEffects: (any MTLTexture)?
        var sourceIsHDR = config.profile.capture.dynamicRange == .hdr
        var isSynthesizedFrame = false
        var forceBypassDuplicateCheck = snapshot.configDirty
        var scheduledPresentationTime: Double? = nil

        if let frame = newFrame {
            if let backing = frame.backingObject {
                retainedObjects.append(backing)
            }
            cadenceTracker.recordFrame(timestamp: frame.timestampSeconds > 0 ? frame.timestampSeconds : now)
            sourceIsHDR = frame.isHDR

            // Crop out any SCStream black right/bottom padding (`frame.contentRect`) BEFORE pre-downscaling,
            // FG history staging, and `ScalingLayoutCalculator.calculate` so padded IOSurfaces NEVER produce
            // black side strips or distort `PointerMapping.effectiveSourceCGRect`!
            let activeContentSubRect = ScalingLayoutCalculator.activeContentSubRect(
                contentPixelRect: frame.contentRect,
                textureSize: PixelSize(width: frame.texture.width, height: frame.texture.height)
            )
            lastRawContentPixelRect = activeContentSubRect
                ?? PixelRect(x: 0, y: 0, width: frame.texture.width, height: frame.texture.height)
            let activeFrameTexture: any MTLTexture
            if let subRect = activeContentSubRect,
               let croppedTex = cropActiveContentSubRect(
                   from: frame.texture,
                   subRect: subRect,
                   commandBuffer: commandBuffer
               )
            {
                activeFrameTexture = croppedTex
            } else {
                activeFrameTexture = frame.texture
            }

            // Retain a private GPU copy of the latest clean raw source frame (zero IOSurface hoarding) so
            // mid-session `updateConfiguration` changes can immediately re-run effects on static windows.
            stageLastRawSourceTexture(
                sourceTexture: activeFrameTexture,
                isHDR: frame.isHDR,
                commandBuffer: commandBuffer
            )

            // Re-evaluate FG plan after recording the latest cadence sample so 60fps on 60Hz bypasses immediately.
            let postPlan = evaluateFrameGenPlan(config: config)
            let postFGActive = postPlan.active
            let postMultiplier = postPlan.effectiveMultiplier

            // Update 4-slot private GPU history ring for Frame Generation (zero IOSurface hoarding & zero GPU hazards!).
            if postFGActive {
                let hadUnrenderedRealBeat = fgPendingBeats.contains { $0.factor >= 0.999 }
                let arrivalDelta = fgLastNewFrameArrivalTime > 0 ? (now - fgLastNewFrameArrivalTime) : 1.0
                fgLastNewFrameArrivalTime = now

                stageFrameIntoFGHistory(
                    sourceTexture: activeFrameTexture,
                    commandBuffer: commandBuffer
                )

                // Burst & hover-spike safeguard (e.g. Bilibili progress-bar hover jumping 30fps -> 120fps -> 30fps):
                // When frames arrive at or near display refresh rate (`arrivalDelta < displayInterval * 1.35`),
                // there is no spare VSync slot for an interpolated beat. Bypass interpolation consistently across
                // consecutive display-rate frames (avoiding alternating real/synth/real/synth motion stutter!) and
                // hold a short smooth cooldown until source cadence genuinely settles back below display rate.
                if arrivalDelta < displayInterval * 1.35 {
                    fgConsecutiveDisplayRateBursts &+= 1
                    if (hadUnrenderedRealBeat && arrivalDelta < displayInterval * 1.15)
                        || fgConsecutiveDisplayRateBursts >= 2
                        || now < fgBurstCooldownUntil
                    {
                        fgBurstCooldownUntil = max(fgBurstCooldownUntil, now + max(0.18, displayInterval * 12.0))
                    }
                } else if arrivalDelta >= displayInterval * 1.45 {
                    fgConsecutiveDisplayRateBursts = 0
                }

                let isBurstAtDisplayRate = (hadUnrenderedRealBeat && arrivalDelta < displayInterval * 1.15)
                    || fgConsecutiveDisplayRateBursts >= 2
                    || now < fgBurstCooldownUntil

                if !isBurstAtDisplayRate,
                   let prevIdx = fgPreviousIndex,
                   prevIdx < fgHistoryTextures.count,
                   fgHistoryTextures[prevIdx].width == activeFrameTexture.width,
                   fgHistoryTextures[prevIdx].height == activeFrameTexture.height
                {
                    let firstFactor = scheduleFGBeatsForNextInterval(
                        arrivalTime: now,
                        multiplier: postMultiplier,
                        displayInterval: displayInterval
                    )
                    let (tex, synth, timing) = encodeInterpolatedOrRealFrame(
                        factor: firstFactor,
                        prevTex: fgHistoryTextures[prevIdx],
                        currTex: activeFrameTexture,
                        commandBuffer: commandBuffer,
                        config: config
                    )
                    sourceTextureForEffects = tex
                    isSynthesizedFrame = synth
                    if let timing { extraPassTimings.append(timing) }
                } else {
                    fgPendingBeats.removeAll(keepingCapacity: true)
                    sourceTextureForEffects = activeFrameTexture
                }
            } else {
                fgPendingBeats.removeAll(keepingCapacity: true)
                fgConsecutiveDisplayRateBursts = 0
                fgBurstCooldownUntil = 0
                fgLastNewFrameArrivalTime = now
                sourceTextureForEffects = activeFrameTexture
            }
        } else if let beat = dueBeat,
                  fgActive,
                  let prevIdx = fgPreviousIndex,
                  let currIdx = fgCurrentIndex,
                  prevIdx < fgHistoryTextures.count,
                  currIdx < fgHistoryTextures.count
        {
            scheduledPresentationTime = beat.targetTime
            let prevTex = fgHistoryTextures[prevIdx]
            let currTex = fgHistoryTextures[currIdx]
            if beat.factor >= 0.999 {
                // Final beat of the interval: present exact real `curr` frame cleanly.
                sourceTextureForEffects = currTex
                isSynthesizedFrame = false
            } else if prevTex.width == currTex.width && prevTex.height == currTex.height {
                let (tex, synth, timing) = encodeInterpolatedOrRealFrame(
                    factor: beat.factor,
                    prevTex: prevTex,
                    currTex: currTex,
                    commandBuffer: commandBuffer,
                    config: config
                )
                sourceTextureForEffects = tex
                isSynthesizedFrame = synth
                if let timing { extraPassTimings.append(timing) }
            } else {
                sourceTextureForEffects = currTex
            }
        } else if canRerenderStaticConfig, let cachedRaw = lastRawSourceTexture {
            // Mid-session configuration change (scalingMode / crop / alignment / resize / HDR) on a static window:
            // re-run the effect chain and recompute layout immediately from the retained private raw frame!
            sourceTextureForEffects = cachedRaw
            sourceIsHDR = lastRawSourceIsHDR || (config.profile.capture.dynamicRange == .hdr)
            forceBypassDuplicateCheck = true
        }

        // Run multi-pass EffectRendering graph when we have a real, interpolated, or reconfigured source frame.
        if let srcTex = sourceTextureForEffects {
            let rawSourceSize = PixelSize(width: srcTex.width, height: srcTex.height)
            let resolvedInput: (effectiveSize: PixelSize, videoPreDownscaleSize: PixelSize?)
            if let preScaleConfigurable = effectRenderer as? any EffectPreScaleConfigurable {
                let resolved = ScalingLayoutCalculator.resolveEffectiveSourceSize(
                    rawSourceSize: rawSourceSize,
                    targetPixelSize: targetPixelSize,
                    presentationMode: config.profile.presentationMode,
                    fullscreenVideoInput: config.profile.capture.fullscreenVideoInput,
                    demagnifyActive: preScaleConfigurable.isDemagnifyActive,
                    isNativeFullscreenSource: config.isNativeFullscreenSource
                )
                // Active SCStream contentRect was already cropped into `srcTex` above, so clear sub-rect on renderer.
                preScaleConfigurable.sourceContentPixelRect = nil
                preScaleConfigurable.fullscreenVideoPreDownscaleSize = resolved.videoPreDownscaleSize
                resolvedInput = resolved
            } else {
                resolvedInput = (rawSourceSize, nil)
            }

            let effectiveCrop = config.profile.crop.scaled(
                from: rawSourceSize,
                to: resolvedInput.effectiveSize
            )

            var layout = ScalingLayoutCalculator.calculate(
                sourcePixelSize: resolvedInput.effectiveSize,
                targetPixelSize: targetPixelSize,
                targetCGRect: targetCGRect,
                backingScaleFactor: config.overlayMetrics.backingScaleFactor,
                crop: effectiveCrop,
                effects: config.scalingMode.effects,
                presentationMode: config.profile.presentationMode,
                alignment: config.profile.outputAlignment
            )
            // Defensive aspect-preserving guard: never allow finalOutputPixelSize to exceed Metal's 16,384px limit.
            if layout.finalOutputPixelSize.width > ScalingLayoutCalculator.maxMetalTextureDimension
                || layout.finalOutputPixelSize.height > ScalingLayoutCalculator.maxMetalTextureDimension
            {
                layout.finalOutputPixelSize = ScalingLayoutCalculator.clampAspectPreserving(layout.finalOutputPixelSize)
            }
            activeLayout = layout
            notifyLayoutIfChanged(layout)

            let upscaledFormat = sanitizedComputeTextureFormat(
                sourceIsHDR ? .rgba16Float : drawable.texture.pixelFormat
            )
            if let dstTex = nextUpscaledOutputTexture(
                size: layout.finalOutputPixelSize,
                pixelFormat: upscaledFormat
            ) {
                let effectiveDupMode: DuplicateFrameMode = (
                    config.profile.threeDGameMode
                        || isSynthesizedFrame
                        || forceBypassDuplicateCheck
                        || lastValidUpscaledTexture == nil
                )
                    ? .never
                    : config.profile.capture.duplicateFrameMode

                let ctx = EffectRenderContext(
                    device: device,
                    commandBuffer: commandBuffer,
                    sourceTexture: srcTex,
                    destinationTexture: dstTex,
                    layout: layout,
                    isHDR: sourceIsHDR,
                    frameIndex: frameIndex,
                    duplicateFrameMode: effectiveDupMode
                )

                do {
                    effectReport = try effectRenderer.encode(
                        scalingMode: config.scalingMode,
                        context: ctx
                    )
                    if effectReport.wasDuplicateFrameSkipped, let prevValid = lastValidUpscaledTexture {
                        renderedOutputTexture = prevValid
                    } else {
                        renderedOutputTexture = dstTex
                        lastValidUpscaledTexture = dstTex
                    }
                    lastValidLayout = layout
                } catch {
                    PipelineLog.shared.error(
                        .shader,
                        "EffectRendering.encode failed: \(error.localizedDescription)"
                    )
                    // Graceful passthrough fallback: present raw source texture directly.
                    renderedOutputTexture = srcTex
                    lastValidLayout = layout
                }
            }
        }

        guard let finalTex = renderedOutputTexture, let finalLayout = activeLayout else {
            for cb in screenshots {
                cb(.failure(EngineError.screenshotExportFailed("Upscaled texture unavailable.")))
            }
            return
        }

        // Cursor-Free Screenshot Hook: capture upscaled output BEFORE cursor/HUD compositing!
        var screenshotStaging: (any MTLTexture)?
        if !screenshots.isEmpty {
            let ssSize = finalLayout.visibleContentPixelRect.isEmpty
                ? finalLayout.finalOutputPixelSize
                : finalLayout.visibleContentPixelRect.size
            screenshotStaging = presentPass.encodeScreenshotReadback(
                commandBuffer: commandBuffer,
                sourceTexture: finalTex,
                uvRect: finalLayout.visibleTextureUVRect,
                outputSize: ssSize
            )
        }

        // Single-pass Metal present pass into drawable (with letterbox clear + optional VRR cursor/HUD composite).
        let useGPUCompositing = config.vrrDirectScanout && config.overlayMetrics.isVRRDirectScanoutActive
        presentPass.encodePresent(
            commandBuffer: commandBuffer,
            drawableTexture: drawable.texture,
            sourceTexture: finalTex,
            layout: finalLayout,
            cursorSprite: useGPUCompositing ? snapshot.cursor : nil,
            hudOverlay: useGPUCompositing ? snapshot.hud : nil
        )

        // Measure true presentation cadence via `drawable.addPresentedHandler`.
        drawable.addPresentedHandler { [weak self] presentedDrawable in
            guard let self else { return }
            let t = presentedDrawable.presentedTime > 0
                ? presentedDrawable.presentedTime
                : CACurrentMediaTime()
            self.telemetry.recordPresented(presentedTime: t)
            self.publishTelemetryIfDue(now: CACurrentMediaTime())
        }

        let encodeWallStart = now
        let retainedBox = UncheckedBox(value: retainedObjects)
        let stagingBox = UncheckedBox(value: screenshotStaging)
        let screenshotCallbacks = screenshots
        let submittedGeneration = control.withLock { s -> UInt64 in
            s.inFlightCommandBuffers += 1
            return s.sessionGeneration
        }

        // Retain `CapturedFrame.backingObject` until GPU finishes + capture GPU duration, resolve screenshots,
        // and drain any textures recycled back into `TexturePool` after `stop()` so VRAM returns to ~0 MB!
        commandBuffer.addCompletedHandler { [weak self] cb in
            _ = retainedBox.value
            if let self {
                let gpuDurationSec = cb.gpuEndTime - cb.gpuStartTime
                if gpuDurationSec > 0 && gpuDurationSec < 1.0 {
                    self.telemetry.recordGPUFrameTimeMs(gpuDurationSec * 1000.0)
                } else {
                    let wallMs = (CACurrentMediaTime() - encodeWallStart) * 1000.0
                    self.telemetry.recordGPUFrameTimeMs(wallMs)
                }

                let (isStillRunning, shouldDrainStoppedVRAM) = self.control.withLock { s -> (Bool, Bool) in
                    s.inFlightCommandBuffers = max(0, s.inFlightCommandBuffers - 1)
                    let drain = !s.isRunning && s.inFlightCommandBuffers == 0 && s.sessionGeneration != submittedGeneration
                    return (s.isRunning, drain)
                }
                if isStillRunning {
                    self.publishTelemetryIfDue(now: CACurrentMediaTime())
                } else if shouldDrainStoppedVRAM {
                    // Final in-flight GPU frame finished after `stop()`: drain any textures just returned
                    // by `TexturePool.recycleOnCompletion` so idle VRAM returns cleanly to ~0 MB.
                    self.renderThread.perform { [weak self] in
                        guard let self else { return }
                        let stillStopped = self.control.withLock { !$0.isRunning && $0.inFlightCommandBuffers == 0 }
                        if stillStopped {
                            self.effectRenderer.reset()
                            self.frameInterpolator?.reset()
                        }
                    }
                }
            }

            if !screenshotCallbacks.isEmpty {
                if let staging = stagingBox.value,
                   let cgImage = PresentPassRenderer.makeCGImage(fromBGRA8SharedTexture: staging)
                {
                    for callback in screenshotCallbacks {
                        callback(.success(cgImage))
                    }
                } else {
                    let err = EngineError.screenshotExportFailed("Failed to read back Metal output texture.")
                    for callback in screenshotCallbacks {
                        callback(.failure(err))
                    }
                }
            }
        }

        presentDrawable(commandBuffer, drawable, scheduledPresentationTime)
        commandBuffer.commit()
        if driverMode == .directPresent {
            directPresentPacer.recordSubmitted(at: now)
        }
        telemetry.recordRenderConsumed(now: now)

        // Reveal overlay after the first upscaled frame is committed/presented (zero startup black flash!).
        emitFirstFrameIfNeeded()

        // Update telemetry snapshot & publish at ~5 Hz.
        // Preserve the most recent `"frame-gen"` PassTiming across real source frames while Frame Gen
        // stays active so the 5 Hz telemetry snapshots & Profiler HUD never flicker `"frame-gen"` off
        // when a publish tick lands on a real source beat; clear immediately when `!fgActive`.
        let finalFGPlan = evaluateFrameGenPlan(config: config)
        let finalFGActive = finalFGPlan.active
        var combinedTimings = extraPassTimings
        if finalFGActive {
            if let freshFG = extraPassTimings.first(where: { $0.id == "frame-gen" }) {
                fgLastPassTiming = freshFG
            } else if let cachedFG = fgLastPassTiming {
                combinedTimings.append(cachedFG)
            }
        } else {
            fgLastPassTiming = nil
        }
        combinedTimings.append(contentsOf: effectReport.passTimings)
        telemetry.updateSessionMetadata(
            state: .running,
            inputSize: finalLayout.croppedSourceRect.size,
            outputSize: finalLayout.finalOutputPixelSize,
            frameGenActive: finalFGActive,
            frameGenMultiplier: finalFGActive ? finalFGPlan.effectiveMultiplier : 1,
            hdrActive: sourceIsHDR
        )
        telemetry.recordOutputFrame(
            now: now,
            wasDuplicateSkipped: effectReport.wasDuplicateFrameSkipped,
            passTimings: combinedTimings
        )
        publishTelemetryIfDue(now: now)
    }

    // MARK: - Frame Generation Helpers (Render Thread Only)

    private func evaluateFrameGenPlan(config: RenderSessionConfiguration) -> (active: Bool, effectiveMultiplier: Int) {
        guard isFrameGenAllowedByConfig(config) else {
            fgHysteresisSuppressedByHighFPS = false
            return (false, 1)
        }
        let displayHz = max(30.0, config.overlayMetrics.screenMaxFPS)
        let sourceFPS = cadenceTracker.estimatedFPS
        let requestedM = max(2, config.profile.frameGen.multiplier.rawValue)

        // Auto-bypass FG cleanly with hysteresis whenever source FPS already fills the display
        // refresh rate (zero spare vsync slots — e.g. 60fps source on 60Hz monitor or 120fps on 120Hz).
        if cadenceTracker.hasReliableEstimate && sourceFPS > 0 {
            let headroomRatio = displayHz / sourceFPS
            let maxUsefulM = max(1, Int((headroomRatio + 0.20).rounded(.down)))
            if fgHysteresisSuppressedByHighFPS {
                if sourceFPS < displayHz * 0.78 && headroomRatio >= 1.80 {
                    fgHysteresisSuppressedByHighFPS = false
                }
            } else if sourceFPS >= displayHz * 0.88 || maxUsefulM < 2 {
                fgHysteresisSuppressedByHighFPS = true
            }
            if fgHysteresisSuppressedByHighFPS {
                return (false, 1)
            }
            return (true, min(requestedM, max(2, maxUsefulM)))
        }

        return (!fgHysteresisSuppressedByHighFPS, requestedM)
    }

    private func cropActiveContentSubRect(
        from sourceTexture: any MTLTexture,
        subRect: PixelRect,
        commandBuffer: any MTLCommandBuffer
    ) -> (any MTLTexture)? {
        guard subRect.width > 0 && subRect.height > 0,
              subRect.x >= 0 && subRect.y >= 0,
              subRect.x + subRect.width <= sourceTexture.width,
              subRect.y + subRect.height <= sourceTexture.height,
              sourceTexture.pixelFormat != .invalid
        else {
            return nil
        }

        let safeW = clampMetalTextureDimension(subRect.width)
        let safeH = clampMetalTextureDimension(subRect.height)
        let safeFormat = sanitizedComputeTextureFormat(sourceTexture.pixelFormat)

        let needsRebuild = contentCropRing.count != 3
            || contentCropRing[0].width != safeW
            || contentCropRing[0].height != safeH
            || contentCropRing[0].pixelFormat != safeFormat

        if needsRebuild {
            contentCropRing.removeAll(keepingCapacity: true)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: safeFormat,
                width: safeW,
                height: safeH,
                mipmapped: false
            )
            desc.storageMode = .private
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            for _ in 0..<3 {
                if let tex = device.makeTexture(descriptor: desc) {
                    contentCropRing.append(tex)
                }
            }
            contentCropRingIndex = 0
        }

        guard !contentCropRing.isEmpty else { return nil }
        let dst = contentCropRing[contentCropRingIndex]
        contentCropRingIndex = (contentCropRingIndex + 1) % contentCropRing.count

        let blitSource: any MTLTexture
        if sourceTexture.pixelFormat == dst.pixelFormat {
            blitSource = sourceTexture
        } else if let view = sourceTexture.makeTextureView(pixelFormat: dst.pixelFormat) {
            blitSource = view
        } else {
            return nil
        }

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        let copyW = min(subRect.width, dst.width)
        let copyH = min(subRect.height, dst.height)
        blit.label = "MetalPie_ContentRectSubCrop"
        blit.copy(
            from: blitSource,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: subRect.x, y: subRect.y, z: 0),
            sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
            to: dst,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        return dst
    }

    private func stageLastRawSourceTexture(
        sourceTexture: any MTLTexture,
        isHDR: Bool,
        commandBuffer: any MTLCommandBuffer
    ) {
        guard sourceTexture.width > 0 && sourceTexture.height > 0,
              sourceTexture.pixelFormat != .invalid
        else {
            return
        }
        let w = clampMetalTextureDimension(sourceTexture.width)
        let h = clampMetalTextureDimension(sourceTexture.height)
        let fmt = sanitizedComputeTextureFormat(sourceTexture.pixelFormat)

        let needsRebuild = lastRawSourceTexture == nil
            || lastRawSourceTexture?.width != w
            || lastRawSourceTexture?.height != h
            || lastRawSourceTexture?.pixelFormat != fmt

        if needsRebuild {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt,
                width: w,
                height: h,
                mipmapped: false
            )
            desc.storageMode = .private
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            lastRawSourceTexture = device.makeTexture(descriptor: desc)
        }

        guard let dst = lastRawSourceTexture,
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            return
        }
        let copyW = min(sourceTexture.width, dst.width)
        let copyH = min(sourceTexture.height, dst.height)
        blit.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
            to: dst,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        lastRawSourceIsHDR = isHDR
    }

    private func stageFrameIntoFGHistory(
        sourceTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) {
        guard sourceTexture.width > 0 && sourceTexture.height > 0,
              sourceTexture.pixelFormat != .invalid
        else {
            return
        }
        let w = clampMetalTextureDimension(sourceTexture.width)
        let h = clampMetalTextureDimension(sourceTexture.height)
        let fmt = sanitizedComputeTextureFormat(sourceTexture.pixelFormat)

        let needsRebuild = fgHistoryTextures.count != Self.fgHistoryRingCapacity
            || fgHistoryTextures[0].width != w
            || fgHistoryTextures[0].height != h
            || fgHistoryTextures[0].pixelFormat != fmt

        if needsRebuild {
            fgHistoryTextures.removeAll(keepingCapacity: true)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt,
                width: w,
                height: h,
                mipmapped: false
            )
            desc.storageMode = .private
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            var ring: [any MTLTexture] = []
            ring.reserveCapacity(Self.fgHistoryRingCapacity)
            for _ in 0..<Self.fgHistoryRingCapacity {
                if let tex = device.makeTexture(descriptor: desc) {
                    ring.append(tex)
                }
            }
            if ring.count == Self.fgHistoryRingCapacity {
                fgHistoryTextures = ring
            }
            fgHistoryCursor = 0
            fgPreviousIndex = nil
            fgCurrentIndex = nil
        }

        guard fgHistoryTextures.count == Self.fgHistoryRingCapacity,
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            return
        }

        let targetIdx = fgHistoryCursor
        let dst = fgHistoryTextures[targetIdx]
        let copyW = min(sourceTexture.width, dst.width)
        let copyH = min(sourceTexture.height, dst.height)
        blit.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
            to: dst,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        fgPreviousIndex = fgCurrentIndex
        fgCurrentIndex = targetIdx
        fgHistoryCursor = (targetIdx + 1) % Self.fgHistoryRingCapacity
    }

    /// Schedules strictly monotonic forward beats for the `(prev, curr)` interval.
    /// Returns the first immediate factor (`1 / M`) to render on arrival, and queues
    /// `[2/M, ..., (M-1)/M, 1.0]` spaced evenly across the measured source cadence interval.
    private func scheduleFGBeatsForNextInterval(
        arrivalTime: Double,
        multiplier: Int,
        displayInterval: Double
    ) -> Float {
        fgPendingBeats.removeAll(keepingCapacity: true)
        let m = max(2, multiplier)
        let interval = cadenceTracker.estimatedIntervalSeconds
        // Never bunch beats tighter than one display refresh period.
        let step = max(displayInterval * 0.92, interval / Double(m))

        // Immediate beat rendered right now: factor = 1 / m
        let immediateFactor = 1.0 / Float(m)

        // Subsequent beats spaced evenly at +step, +2*step, ..., ending with real frame (factor = 1.0).
        for idx in 2...m {
            let factor = Float(idx) / Float(m)
            let targetTime = arrivalTime + Double(idx - 1) * step
            fgPendingBeats.append(ScheduledFGBeat(factor: factor, targetTime: targetTime))
        }
        return immediateFactor
    }

    private func encodeInterpolatedOrRealFrame(
        factor: Float,
        prevTex: any MTLTexture,
        currTex: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        config: RenderSessionConfiguration
    ) -> (texture: any MTLTexture, synthesized: Bool, timing: PassTiming?) {
        guard factor > 0.001 && factor < 0.999,
              let interpolator = frameInterpolator,
              let fgOut = ensureFGOutputTexture(matching: currTex)
        else {
            return (factor < 0.5 ? prevTex : currTex, false, nil)
        }

        let fgStart = CACurrentMediaTime()
        do {
            let size = PixelSize(width: currTex.width, height: currTex.height)
            if fgPreparedSize != size || fgPreparedSettings != config.profile.frameGen {
                try interpolator.prepare(
                    width: size.width,
                    height: size.height,
                    settings: config.profile.frameGen
                )
                fgPreparedSize = size
                fgPreparedSettings = config.profile.frameGen
            }

            let req = FrameGenRequest(
                previousTexture: prevTex,
                currentTexture: currTex,
                outputTexture: fgOut,
                interpolationFactor: factor,
                commandBuffer: commandBuffer,
                settings: config.profile.frameGen
            )
            let synthesized = try interpolator.encode(request: req)
            let fgMs = (CACurrentMediaTime() - fgStart) * 1000.0
            if synthesized {
                let timing = PassTiming(
                    id: "frame-gen",
                    name: "Frame Gen (\(interpolator.backendName))",
                    gpuMilliseconds: fgMs,
                    colorHex: "#A78BFA"
                )
                return (fgOut, true, timing)
            } else {
                // Artifact Guard / scene cut fallback -> nearest real frame.
                return (factor < 0.5 ? prevTex : currTex, false, nil)
            }
        } catch {
            PipelineLog.shared.debug(
                .render,
                "Frame interpolation skipped for beat \(factor): \(error.localizedDescription)"
            )
            return (factor < 0.5 ? prevTex : currTex, false, nil)
        }
    }

    private func ensureFGOutputTexture(matching template: any MTLTexture) -> (any MTLTexture)? {
        guard template.width > 0 && template.height > 0 else { return nil }
        let safeW = clampMetalTextureDimension(template.width)
        let safeH = clampMetalTextureDimension(template.height)
        let safeFormat = sanitizedComputeTextureFormat(template.pixelFormat)

        let needsRebuild = fgInterpolatedRing.count != 3
            || fgInterpolatedRing[0].width != safeW
            || fgInterpolatedRing[0].height != safeH
            || fgInterpolatedRing[0].pixelFormat != safeFormat

        if needsRebuild {
            fgInterpolatedRing.removeAll(keepingCapacity: true)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: safeFormat,
                width: safeW,
                height: safeH,
                mipmapped: false
            )
            desc.storageMode = .private
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            for _ in 0..<3 {
                if let tex = device.makeTexture(descriptor: desc) {
                    fgInterpolatedRing.append(tex)
                }
            }
            fgInterpolatedRingIndex = 0
        }

        guard !fgInterpolatedRing.isEmpty else { return nil }
        let tex = fgInterpolatedRing[fgInterpolatedRingIndex]
        fgInterpolatedRingIndex = (fgInterpolatedRingIndex + 1) % fgInterpolatedRing.count
        return tex
    }

    private func resetFrameGenStateOnRenderThread() {
        fgHistoryTextures.removeAll()
        fgHistoryCursor = 0
        fgPreviousIndex = nil
        fgCurrentIndex = nil
        fgInterpolatedRing.removeAll()
        fgInterpolatedRingIndex = 0
        fgPreparedSize = .zero
        fgPreparedSettings = nil
        fgPendingBeats.removeAll()
        fgHysteresisSuppressedByHighFPS = false
        fgConsecutiveDisplayRateBursts = 0
        fgBurstCooldownUntil = 0
        fgLastNewFrameArrivalTime = 0
        fgLastPassTiming = nil
        cadenceTracker.reset()
        frameInterpolator?.reset()
    }

    // MARK: - Upscaled Output Texture Pool (Zero Per-Frame Allocations)

    private func nextUpscaledOutputTexture(
        size: PixelSize,
        pixelFormat: MTLPixelFormat
    ) -> (any MTLTexture)? {
        guard size.isValid else { return nil }
        let safeSize = ScalingLayoutCalculator.clampAspectPreserving(size)
        guard safeSize.isValid else { return nil }
        let safeW = clampMetalTextureDimension(safeSize.width)
        let safeH = clampMetalTextureDimension(safeSize.height)
        let safeFormat = sanitizedComputeTextureFormat(pixelFormat)

        let needsRebuild = upscaledRing.count != 3
            || upscaledRing[0].width != safeW
            || upscaledRing[0].height != safeH
            || upscaledRing[0].pixelFormat != safeFormat

        if needsRebuild {
            upscaledRing.removeAll(keepingCapacity: true)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: safeFormat,
                width: safeW,
                height: safeH,
                mipmapped: false
            )
            desc.storageMode = .private
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            for _ in 0..<3 {
                if let tex = device.makeTexture(descriptor: desc) {
                    upscaledRing.append(tex)
                }
            }
            upscaledRingIndex = 0
            lastValidUpscaledTexture = nil
        }

        guard !upscaledRing.isEmpty else { return nil }
        let tex = upscaledRing[upscaledRingIndex]
        upscaledRingIndex = (upscaledRingIndex + 1) % upscaledRing.count
        return tex
    }

    // MARK: - Screenshot & Notification Helpers

    private func drainPendingScreenshots() -> [@Sendable (Result<CGImage, Error>) -> Void] {
        control.withLock { s in
            guard !s.pendingScreenshots.isEmpty else { return [] }
            let list = s.pendingScreenshots
            s.pendingScreenshots.removeAll(keepingCapacity: true)
            return list
        }
    }

    private func requeueScreenshots(_ callbacks: [@Sendable (Result<CGImage, Error>) -> Void]) {
        control.withLock { s in
            s.pendingScreenshots.insert(contentsOf: callbacks, at: 0)
        }
    }

    private func executeStaticScreenshotOnly(
        sourceTexture: any MTLTexture,
        layout: ScalingLayoutResult,
        callbacks: [@Sendable (Result<CGImage, Error>) -> Void]
    ) {
        guard let cmdBuf = commandQueue.makeCommandBuffer() else {
            for cb in callbacks {
                cb(.failure(EngineError.screenshotExportFailed("Failed to allocate Metal command buffer.")))
            }
            return
        }
        let ssSize = layout.visibleContentPixelRect.isEmpty
            ? layout.finalOutputPixelSize
            : layout.visibleContentPixelRect.size
        let staging = presentPass.encodeScreenshotReadback(
            commandBuffer: cmdBuf,
            sourceTexture: sourceTexture,
            uvRect: layout.visibleTextureUVRect,
            outputSize: ssSize
        )
        let stagingBox = UncheckedBox(value: staging)
        cmdBuf.addCompletedHandler { _ in
            if let stagingTex = stagingBox.value,
               let image = PresentPassRenderer.makeCGImage(fromBGRA8SharedTexture: stagingTex)
            {
                for cb in callbacks { cb(.success(image)) }
            } else {
                let err = EngineError.screenshotExportFailed("Failed to read back cached upscaled texture.")
                for cb in callbacks { cb(.failure(err)) }
            }
        }
        cmdBuf.commit()
    }

    private func emitFirstFrameIfNeeded() {
        let callback: (@Sendable () -> Void)? = control.withLock { s in
            guard !s.hasEmittedFirstFrame else { return nil }
            s.hasEmittedFirstFrame = true
            return s.onFirstFramePresented
        }
        callback?()
    }

    private func notifyLayoutIfChanged(_ layout: ScalingLayoutResult) {
        let callback: (@Sendable (ScalingLayoutResult) -> Void)? = control.withLock { s in
            guard s.latestLayout != layout else { return nil }
            s.latestLayout = layout
            return s.onLayoutUpdated
        }
        callback?(layout)
    }

    private func publishTelemetryIfDue(now: Double) {
        guard let snapshot = telemetry.snapshotIfDue(now: now, minInterval: 0.2) else { return }
        let callback = control.withLock(\.onTelemetry)
        callback?(snapshot)
    }
}

// MARK: - CAMetalDisplayLinkDelegate

extension RenderLoopController: CAMetalDisplayLinkDelegate {
    public func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {
        let now = CACurrentMediaTime()
        let maxFPS = control.withLock { $0.configuration?.overlayMetrics.screenMaxFPS ?? 60.0 }
        let vsyncPeriod = 1.0 / max(30.0, maxFPS)
        executeRenderStepOnRenderThread(
            now: now,
            vsyncPeriod: vsyncPeriod,
            acquireDrawable: { update.drawable },
            presentDrawable: { cmdBuf, drawable, _ in
                cmdBuf.present(drawable)
            }
        )
    }
}
