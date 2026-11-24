import AppKit
import CoreGraphics
import Foundation
import Metal
import MetalPieCore
import QuartzCore
import os

// MARK: - Overlay Geometry & Metrics Snapshot

/// Live display & drawable metrics emitted by `OverlayWindowController` whenever
/// the overlay moves, resizes, or transitions to a different monitor / backing scale.
public struct OverlayDrawableMetrics: Hashable, Sendable {
    /// Current overlay frame in AppKit global coordinates (Y-up, logical points).
    public var cocoaFrame: CGRect
    /// Current overlay frame in CoreGraphics global coordinates (Y-down, logical points).
    public var cgFrame: CGRect
    /// Exact Metal drawable dimensions in pixels (`round(bounds * backingScaleFactor)`).
    public var drawablePixelSize: PixelSize
    /// Active Retina backing scale factor of the screen hosting the overlay.
    public var backingScaleFactor: Double
    /// Peak refresh rate of the screen hosting the overlay (e.g. 60, 120 Hz).
    public var screenMaxFPS: Double
    /// Active display ID hosting the majority of the overlay.
    public var displayID: CGDirectDisplayID
    /// True when the hosting display supports EDR/HDR headroom > 1.0.
    public var supportsEDR: Bool
    /// True when the overlay is actively covering a full single display with VRR direct-scanout enabled.
    public var isVRRDirectScanoutActive: Bool

    public init(
        cocoaFrame: CGRect,
        cgFrame: CGRect,
        drawablePixelSize: PixelSize,
        backingScaleFactor: Double,
        screenMaxFPS: Double,
        displayID: CGDirectDisplayID,
        supportsEDR: Bool,
        isVRRDirectScanoutActive: Bool
    ) {
        self.cocoaFrame = cocoaFrame
        self.cgFrame = cgFrame
        self.drawablePixelSize = drawablePixelSize
        self.backingScaleFactor = max(1.0, backingScaleFactor)
        self.screenMaxFPS = max(1.0, screenMaxFPS)
        self.displayID = displayID
        self.supportsEDR = supportsEDR
        self.isVRRDirectScanoutActive = isVRRDirectScanoutActive
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(cocoaFrame.origin.x)
        hasher.combine(cocoaFrame.origin.y)
        hasher.combine(cocoaFrame.size.width)
        hasher.combine(cocoaFrame.size.height)
        hasher.combine(cgFrame.origin.x)
        hasher.combine(cgFrame.origin.y)
        hasher.combine(cgFrame.size.width)
        hasher.combine(cgFrame.size.height)
        hasher.combine(drawablePixelSize)
        hasher.combine(backingScaleFactor)
        hasher.combine(screenMaxFPS)
        hasher.combine(displayID)
        hasher.combine(supportsEDR)
        hasher.combine(isVRRDirectScanoutActive)
    }
}

// MARK: - OverlayPanel

/// Borderless, non-activating `NSPanel` subclass that never steals keyboard focus from the target game/app.
@MainActor
public final class OverlayPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
    }

    /// Always constructs with `screen: nil` so `globalCocoaRect` is interpreted strictly in global Cocoa coordinates
    /// (preventing AppKit's secondary-monitor offset bug).
    public convenience init(globalCocoaRect: CGRect) {
        self.init(
            contentRect: globalCocoaRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: nil
        )

        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }
}

// MARK: - MetalOverlayView

/// Plain `NSView` owning a `CAMetalLayer` directly (NO `MTKView` main-thread overhead).
///
/// Guarantees:
/// - `metalLayer.isOpaque = true` + `framebufferOnly = true` (prevents MetalGoose's 19-callback
///   `CAMetalDisplayLink` compositor stall and enables Apple Silicon TBDR tile compression).
/// - `metalLayer.maximumDrawableCount = 3` is set ONCE before any `CAMetalDisplayLink` attaches
///   and is **never mutated post-attach** (macOS 27 `CAMetalLayerInvalidOperation` crash prevention).
/// - Explicit `contentsScale` & `drawableSize` sync on frame, backing-property, and screen changes.
/// - Hardware-composited zero-latency `CALayer` cursor sublayer (disabled automatically in VRR mode).
/// - Aspect-ratio locked drag & 8-direction resize handles when running in interactive Windowed mode.
@MainActor
public final class MetalOverlayView: NSView {
    public let metalLayer: CAMetalLayer

    /// Locks mutation of `maximumDrawableCount` once a `CAMetalDisplayLink` has ever been attached.
    public private(set) var hasAttachedDisplayLink: Bool = false

    /// Hardware-composited cursor sprite layer used when VRR direct-scanout is OFF.
    private let cursorSpriteLayer: CALayer = {
        let layer = CALayer()
        layer.isHidden = true
        layer.zPosition = 1000
        layer.contentsGravity = .resize
        layer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "hidden": NSNull(),
            "contents": NSNull(),
            "anchorPoint": NSNull(),
            "contentsScale": NSNull(),
            "magnificationFilter": NSNull(),
            "minificationFilter": NSNull(),
            "opacity": NSNull()
        ]
        return layer
    }()

    /// Subtle interactive resize frame border displayed ONLY when in interactive (unpinned) windowed mode.
    private let windowedBorderLayer: CALayer = {
        let layer = CALayer()
        layer.isHidden = true
        layer.zPosition = 900
        layer.borderWidth = 1.5
        layer.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        layer.cornerRadius = 6.0
        layer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
            "borderColor": NSNull()
        ]
        return layer
    }()

    /// Callback fired whenever `drawableSize` or `contentsScale` changes.
    public var onGeometryChanged: ((PixelSize, Double) -> Void)?

    /// Callback fired when interactive windowed drag/resize finishes or updates the window frame.
    public var onInteractiveFrameUpdate: ((CGRect) -> Void)?

    /// Interactive windowed-mode state.
    public var isInteractiveWindowedMode: Bool = false {
        didSet {
            windowedBorderLayer.isHidden = !isInteractiveWindowedMode
        }
    }

    /// Locked width/height aspect ratio used during interactive windowed resizing.
    public var lockedAspectRatio: CGFloat = 16.0 / 9.0

    /// Minimum allowed windowed overlay width in logical points.
    public var minimumWindowedWidth: CGFloat = 320.0

    private enum DragOperation {
        case move
        case resize(edges: ResizeEdges)
    }

    private struct ResizeEdges: OptionSet {
        let rawValue: UInt8
        static let left   = ResizeEdges(rawValue: 1 << 0)
        static let right  = ResizeEdges(rawValue: 1 << 1)
        static let top    = ResizeEdges(rawValue: 1 << 2)
        static let bottom = ResizeEdges(rawValue: 1 << 3)
    }

    private var activeDrag: DragOperation?
    private var dragStartScreenPoint: CGPoint = .zero
    private var dragStartWindowFrame: CGRect = .zero
    private let resizeHitMargin: CGFloat = 12.0

    public init(frame frameRect: NSRect, device: any MTLDevice) {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = true
        layer.framebufferOnly = true
        layer.displaySyncEnabled = true
        layer.contentsGravity = .resize
        // Set maximumDrawableCount ONCE before any CAMetalDisplayLink attaches (macOS 27 invariant).
        layer.maximumDrawableCount = 3
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.metalLayer = layer

        super.init(frame: frameRect)

        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        self.layer = layer

        layer.addSublayer(windowedBorderLayer)
        layer.addSublayer(cursorSpriteLayer)
        syncDrawableGeometry()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    /// Marks that a `CAMetalDisplayLink` has been attached to `metalLayer`.
    /// After this call, `maximumDrawableCount` is frozen permanently for this layer's lifetime.
    public func markDisplayLinkAttached() {
        hasAttachedDisplayLink = true
    }

    /// Configures `maximumDrawableCount` ONLY if no `CAMetalDisplayLink` has ever attached.
    public func configureInitialMaximumDrawableCount(_ count: Int) {
        guard !hasAttachedDisplayLink else {
            PipelineLog.shared.debug(
                .render,
                "Skipped maximumDrawableCount update because CAMetalDisplayLink has already attached (macOS 27 safety)."
            )
            return
        }
        let clamped = min(3, max(2, count))
        if metalLayer.maximumDrawableCount != clamped {
            metalLayer.maximumDrawableCount = clamped
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncDrawableGeometry()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableGeometry()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawableGeometry()
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        windowedBorderLayer.frame = bounds
        CATransaction.commit()
        syncDrawableGeometry()
    }

    /// Synchronizes `metalLayer.contentsScale` and `metalLayer.drawableSize` explicitly from view bounds.
    @discardableResult
    public func syncDrawableGeometry() -> (PixelSize, Double) {
        let scale = max(1.0, Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0))
        let pixelW = max(1, Int((Double(bounds.width) * scale).rounded()))
        let pixelH = max(1, Int((Double(bounds.height) * scale).rounded()))
        let targetSize = CGSize(width: pixelW, height: pixelH)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if abs(Double(metalLayer.contentsScale) - scale) > 0.001 {
            metalLayer.contentsScale = CGFloat(scale)
        }
        if metalLayer.drawableSize != targetSize {
            metalLayer.drawableSize = targetSize
        }
        windowedBorderLayer.frame = bounds
        CATransaction.commit()

        let pixelSize = PixelSize(width: pixelW, height: pixelH)
        onGeometryChanged?(pixelSize, scale)
        return (pixelSize, scale)
    }

    // MARK: - Hardware-Composited Cursor Sublayer (Non-VRR Mode)

    /// Updates or hides the zero-latency `CALayer` cursor sprite sublayer.
    /// Hidden automatically when VRR direct-scanout is enabled (where Metal composites the cursor instead).
    public func updateCursorSprite(
        visible: Bool,
        localCocoaPoint: CGPoint,
        cursorImage: NSImage?,
        hotSpot: CGPoint,
        scaleFactor: Double,
        interpolation: CursorInterpolation,
        vrrDirectScanout: Bool
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard visible, !vrrDirectScanout, let image = cursorImage else {
            cursorSpriteLayer.isHidden = true
            return
        }

        let backingScale = max(1.0, Double(metalLayer.contentsScale))
        let scaledW = max(1.0, image.size.width * CGFloat(scaleFactor))
        let scaledH = max(1.0, image.size.height * CGFloat(scaleFactor))
        let filter: CALayerContentsFilter = (interpolation == .nearest || abs(scaleFactor - 1.0) < 0.05)
            ? .nearest
            : .linear

        cursorSpriteLayer.contents = image.layerContents(forContentsScale: CGFloat(backingScale))
        cursorSpriteLayer.contentsScale = CGFloat(backingScale)
        cursorSpriteLayer.bounds = CGRect(x: 0, y: 0, width: scaledW, height: scaledH)

        // Convert macOS top-left cursor hotspot to CALayer bottom-left anchorPoint.
        let anchorX = image.size.width > 0 ? min(max(hotSpot.x / image.size.width, 0), 1) : 0
        let anchorY = image.size.height > 0 ? min(max(1.0 - (hotSpot.y / image.size.height), 0), 1) : 1
        cursorSpriteLayer.anchorPoint = CGPoint(x: anchorX, y: anchorY)
        cursorSpriteLayer.position = localCocoaPoint
        cursorSpriteLayer.magnificationFilter = filter
        cursorSpriteLayer.minificationFilter = filter
        cursorSpriteLayer.isHidden = false
    }

    public func hideCursorSprite() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorSpriteLayer.isHidden = true
        CATransaction.commit()
    }

    // MARK: - Interactive Windowed Drag & Aspect-Locked Resize

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isInteractiveWindowedMode
    }

    public override func mouseDown(with event: NSEvent) {
        guard isInteractiveWindowedMode, let win = window else {
            super.mouseDown(with: event)
            return
        }
        let localPt = convert(event.locationInWindow, from: nil)
        let edges = hitTestResizeEdges(localPt)
        dragStartScreenPoint = NSEvent.mouseLocation
        dragStartWindowFrame = win.frame
        if !edges.isEmpty {
            activeDrag = .resize(edges: edges)
        } else {
            activeDrag = .move
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isInteractiveWindowedMode, let win = window, let drag = activeDrag else {
            super.mouseDragged(with: event)
            return
        }

        let currentPt = NSEvent.mouseLocation
        let dx = currentPt.x - dragStartScreenPoint.x
        let dy = currentPt.y - dragStartScreenPoint.y
        var newFrame = dragStartWindowFrame

        switch drag {
        case .move:
            newFrame.origin.x += dx
            newFrame.origin.y += dy

        case .resize(let edges):
            let aspect = max(0.1, lockedAspectRatio)
            let minW = max(160.0, minimumWindowedWidth)
            let minH = max(90.0, minW / aspect)

            var proposedW = dragStartWindowFrame.width
            var proposedH = dragStartWindowFrame.height

            if edges.contains(.right) {
                proposedW += dx
            } else if edges.contains(.left) {
                proposedW -= dx
            }

            if edges.contains(.top) {
                proposedH += dy
            } else if edges.contains(.bottom) {
                proposedH -= dy
            }

            // Enforce aspect ratio lock based on the dominant drag axis.
            let hasHorizontal = edges.contains(.left) || edges.contains(.right)
            let hasVertical = edges.contains(.top) || edges.contains(.bottom)

            if hasHorizontal && hasVertical {
                let widthFromH = proposedH * aspect
                if abs(proposedW - dragStartWindowFrame.width) >= abs(widthFromH - dragStartWindowFrame.width) {
                    proposedW = max(minW, proposedW)
                    proposedH = max(minH, proposedW / aspect)
                } else {
                    proposedH = max(minH, proposedH)
                    proposedW = max(minW, proposedH * aspect)
                }
            } else if hasHorizontal {
                proposedW = max(minW, proposedW)
                proposedH = max(minH, proposedW / aspect)
            } else if hasVertical {
                proposedH = max(minH, proposedH)
                proposedW = max(minW, proposedH * aspect)
            }

            if edges.contains(.left) {
                newFrame.origin.x = dragStartWindowFrame.maxX - proposedW
            }
            if edges.contains(.bottom) {
                newFrame.origin.y = dragStartWindowFrame.maxY - proposedH
            }
            newFrame.size = CGSize(width: proposedW.rounded(), height: proposedH.rounded())
        }

        win.setFrame(newFrame, display: true, animate: false)
        syncDrawableGeometry()
        onInteractiveFrameUpdate?(win.frame)
    }

    public override func mouseUp(with event: NSEvent) {
        activeDrag = nil
        super.mouseUp(with: event)
    }

    private func hitTestResizeEdges(_ pt: CGPoint) -> ResizeEdges {
        var edges: ResizeEdges = []
        if pt.x <= resizeHitMargin { edges.insert(.left) }
        if pt.x >= bounds.width - resizeHitMargin { edges.insert(.right) }
        if pt.y <= resizeHitMargin { edges.insert(.bottom) }
        if pt.y >= bounds.height - resizeHitMargin { edges.insert(.top) }
        return edges
    }
}

// MARK: - OverlayWindowController

/// Manages the lifecycle, window level, multi-monitor geometry, color space/EDR, windowed resize state,
/// VRR direct-scanout mode, and reveal-on-first-frame gating of MetalPie's scaling overlay panel.
@MainActor
public final class OverlayWindowController {
    /// Normal overlay window level: 1 below `popUpMenuWindow` (level 100) so Menu Bar, Cmd+Tab,
    /// Spotlight, and Force Quit always remain accessible (never `.screenSaver` or `maximumWindow + 1`!).
    public static let normalOverlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) - 1
    )

    /// Native macOS Full-Screen Space overlay level: level 19 (above full-screen app, below auto-hiding Dock/Menu Bar).
    public static let nativeFullscreenOverlayLevel = NSWindow.Level(rawValue: 19)

    public let device: any MTLDevice
    public private(set) var panel: OverlayPanel?
    public private(set) var overlayView: MetalOverlayView?

    /// Exposes the direct `CAMetalLayer` backing the overlay view.
    public var metalLayer: CAMetalLayer? { overlayView?.metalLayer }

    /// Remembered windowed-mode overlay width (persisted across Fullscreen <-> Windowed toggles).
    public private(set) var lastWindowedWidth: CGFloat?

    /// True once the panel has been configured and shown (even if waiting for first frame reveal).
    public private(set) var isSessionOpen: Bool = false

    /// True once `revealAfterFirstFrame()` has ordered the panel on screen.
    public private(set) var isRevealed: Bool = false

    /// True when the overlay is temporarily suspended (e.g. target app lost focus or minimized).
    public private(set) var isSuspended: Bool = false

    /// True when covering a native macOS Full-Screen Space using level 19 + `.accessory` policy.
    public private(set) var isCoveringNativeFullscreenSpace: Bool = false

    /// Applies 1-pt anti-occlusion inset in normal (non-VRR) mode so macOS WindowServer / App Nap
    /// never pauses Chromium/Firefox/Electron windows underneath.
    public var antiOcclusionEnabled: Bool = true

    /// Enables ProMotion VRR Direct-Scanout mode (full-display opaque coverage with zero sub-windows
    /// or moving `CALayer` sublayers; cursor and HUD are composited directly inside Metal).
    public var isVRRDirectScanoutEnabled: Bool = false {
        didSet {
            if isVRRDirectScanoutEnabled != oldValue {
                applyVRRModeState()
            }
        }
    }

    /// Click-through toggle for Windowed Scaling mode (always `true` in Fullscreen mode).
    public var isWindowedClickThrough: Bool = true {
        didSet {
            applyWindowedInteractivity()
        }
    }

    /// Fired whenever drawable size, backing scale, display, or overlay frame changes.
    public var onDrawableMetricsChanged: ((OverlayDrawableMetrics) -> Void)?

    /// Fired when the user interactively drags or resizes the overlay in Windowed Scaling mode.
    public var onWindowedFrameChanged: ((CGRect, PixelSize, Double) -> Void)?

    // Configuration state
    private var currentPresentationMode: PresentationMode = .fullscreen
    private var currentMultiMonitorMode: MultiMonitorMode = .closest
    private var currentDynamicRange: DynamicRangeMode = .sdr
    private var currentPixelFormat: CapturePixelFormat = .bgra8
    private var currentDisplaySyncEnabled: Bool = true
    private var currentSourceCGRect: CGRect = .zero
    private var currentSourceWindowID: CGWindowID = 0
    private var currentAspectRatio: CGFloat = 16.0 / 9.0
    private var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()
    private struct ObserverToken: @unchecked Sendable {
        let raw: any NSObjectProtocol
    }

    private var savedActivationPolicy: NSApplication.ActivationPolicy?
    private var childOverlayWindows: [NSWindow] = []
    private let observerLock = OSAllocatedUnfairLock<[ObserverToken]>(initialState: [])

    public init(device: (any MTLDevice)? = nil) throws {
        guard let resolvedDevice = device ?? MTLCreateSystemDefaultDevice() else {
            throw EngineError.metalDeviceUnavailable
        }
        self.device = resolvedDevice
    }

    deinit {
        let tokens = observerLock.withLock { list -> [ObserverToken] in
            let copy = list
            list.removeAll()
            return copy
        }
        for token in tokens {
            NotificationCenter.default.removeObserver(token.raw)
        }
    }

    // MARK: - Lifecycle: Prepare, Reveal, Suspend, Resume, Close

    /// Creates or reconfigures the overlay panel off-screen (hidden via `orderOut` for zero black flash!).
    /// Call `revealAfterFirstFrame()` from `RenderLoopController.onFirstFramePresented` once the first
    /// upscaled frame has been presented.
    @discardableResult
    public func prepareOverlay(
        sourceWindow: WindowDescriptor,
        profile: Profile,
        presentationOverride: PresentationMode? = nil,
        isNativeFullscreenSpace: Bool? = nil
    ) -> OverlayDrawableMetrics {
        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let mode = presentationOverride ?? profile.presentationMode
        let sourceRect = sourceWindow.cgBounds.standardized
        let aspect: CGFloat = sourceRect.height > 0 ? (sourceRect.width / sourceRect.height) : (16.0 / 9.0)

        currentPresentationMode = mode
        currentMultiMonitorMode = profile.multiMonitorMode
        currentDynamicRange = profile.capture.dynamicRange
        currentPixelFormat = profile.capture.preferredPixelFormat
        currentDisplaySyncEnabled = !profile.capture.lowLatencyPresent || profile.frameGen.enabled
        currentSourceCGRect = sourceRect
        currentSourceWindowID = sourceWindow.windowID
        currentAspectRatio = max(0.1, aspect)

        let nativeFS = isNativeFullscreenSpace ?? (
            mode.isFullscreen && WindowEnumerator.isLikelyNativeFullscreenWindow(
                windowID: sourceWindow.windowID,
                bounds: sourceRect,
                displays: displays
            )
        )

        let targetCocoaRect = computeOverlayCocoaFrame(
            sourceCGRect: sourceRect,
            presentationMode: mode,
            multiMonitorMode: profile.multiMonitorMode,
            displays: displays,
            aspectRatio: currentAspectRatio,
            applyAntiOcclusion: shouldApplyAntiOcclusion(mode: mode, nativeFullscreenSpace: nativeFS)
        )

        let overlayPanel: OverlayPanel
        let view: MetalOverlayView

        if let existingPanel = panel, let existingView = overlayView {
            overlayPanel = existingPanel
            view = existingView
            overlayPanel.setFrame(targetCocoaRect, display: false, animate: false)
        } else {
            overlayPanel = OverlayPanel(globalCocoaRect: targetCocoaRect)
            view = MetalOverlayView(
                frame: CGRect(origin: .zero, size: targetCocoaRect.size),
                device: device
            )
            view.autoresizingMask = [.width, .height]
            overlayPanel.contentView = view

            view.onGeometryChanged = { [weak self] _, _ in
                self?.emitCurrentMetrics()
            }
            view.onInteractiveFrameUpdate = { [weak self] newCocoaFrame in
                guard let self else { return }
                self.lastWindowedWidth = newCocoaFrame.width
                self.refreshScreenCapabilitiesAndColorSpace()
                let metrics = self.currentDrawableMetrics()
                self.onWindowedFrameChanged?(newCocoaFrame, metrics.drawablePixelSize, metrics.backingScaleFactor)
                self.onDrawableMetricsChanged?(metrics)
            }

            self.panel = overlayPanel
            self.overlayView = view
            installWindowObservers(for: overlayPanel)
        }

        // Keep hidden until first upscaled frame is presented (zero startup black flash).
        overlayPanel.orderOut(nil)
        isSessionOpen = true
        isRevealed = false
        isSuspended = false

        view.lockedAspectRatio = currentAspectRatio
        applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: nativeFS)
        applyWindowedInteractivity()
        applyVRRModeState()
        refreshScreenCapabilitiesAndColorSpace()

        let metrics = currentDrawableMetrics()
        onDrawableMetricsChanged?(metrics)

        PipelineLog.shared.info(
            .render,
            "Prepared overlay (\(mode.isFullscreen ? "fullscreen" : "windowed"), rect=\(Int(targetCocoaRect.width))x\(Int(targetCocoaRect.height)) @ \(metrics.backingScaleFactor)x, nativeFS=\(nativeFS), vrr=\(metrics.isVRRDirectScanoutActive))."
        )
        return metrics
    }

    /// Reveals the overlay panel immediately after the first upscaled frame has been rendered/presented.
    public func revealAfterFirstFrame() {
        guard isSessionOpen, !isSuspended, let panel else { return }
        guard !isRevealed else { return }
        panel.orderFrontRegardless()
        isRevealed = true
        PipelineLog.shared.info(.render, "Overlay revealed after first frame presented (zero black flash).")
    }

    /// Immediately hides the overlay panel on focus loss / minimize without destroying the Metal layer
    /// (preserving the `maximumDrawableCount` / `CAMetalDisplayLink` attachment across resume).
    public func suspend() {
        guard isSessionOpen else { return }
        isSuspended = true
        isRevealed = false
        overlayView?.hideCursorSprite()
        panel?.orderOut(nil)
        for child in childOverlayWindows {
            child.orderOut(nil)
        }
        restoreActivationPolicyIfNeeded()
        PipelineLog.shared.debug(.render, "Overlay suspended (hidden).")
    }

    /// Resumes a suspended overlay; waits for the next frame reveal (or reveals immediately if `revealImmediately`).
    public func resume(revealImmediately: Bool = false) {
        guard isSessionOpen, isSuspended else { return }
        isSuspended = false
        applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: isCoveringNativeFullscreenSpace)
        refreshScreenCapabilitiesAndColorSpace()
        if revealImmediately {
            revealAfterFirstFrame()
        }
        PipelineLog.shared.debug(.render, "Overlay resumed (revealImmediately=\(revealImmediately)).")
    }

    /// Tears down and hides the overlay cleanly, restoring macOS activation policy.
    public func close() {
        isSessionOpen = false
        isRevealed = false
        isSuspended = false
        isCoveringNativeFullscreenSpace = false

        overlayView?.hideCursorSprite()
        detachAllChildWindows()
        panel?.orderOut(nil)
        restoreActivationPolicyIfNeeded()
        PipelineLog.shared.info(.render, "Overlay closed.")
    }

    // MARK: - Live Updates (Display Move, Source Resize, Mode Toggle, HDR/Format)

    /// Updates overlay placement when the source window moves, resizes, or switches displays.
    public func updateSourceWindowGeometry(
        _ newSourceCGRect: CGRect,
        windowID: CGWindowID? = nil
    ) {
        guard isSessionOpen, let panel else { return }
        currentSourceCGRect = newSourceCGRect.standardized
        if currentSourceCGRect.height > 0 {
            currentAspectRatio = max(0.1, currentSourceCGRect.width / currentSourceCGRect.height)
            overlayView?.lockedAspectRatio = currentAspectRatio
        }

        // In Fullscreen mode, retarget screen(s) seamlessly if source window moved across monitors.
        guard currentPresentationMode.isFullscreen else { return }

        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let nativeFS: Bool
        if let windowID {
            nativeFS = WindowEnumerator.isLikelyNativeFullscreenWindow(
                windowID: windowID,
                bounds: currentSourceCGRect,
                displays: displays
            )
        } else {
            nativeFS = isCoveringNativeFullscreenSpace
        }

        let targetCocoaRect = computeOverlayCocoaFrame(
            sourceCGRect: currentSourceCGRect,
            presentationMode: currentPresentationMode,
            multiMonitorMode: currentMultiMonitorMode,
            displays: displays,
            aspectRatio: currentAspectRatio,
            applyAntiOcclusion: shouldApplyAntiOcclusion(mode: currentPresentationMode, nativeFullscreenSpace: nativeFS)
        )

        if abs(panel.frame.origin.x - targetCocoaRect.origin.x) >= 0.5
            || abs(panel.frame.origin.y - targetCocoaRect.origin.y) >= 0.5
            || abs(panel.frame.size.width - targetCocoaRect.size.width) >= 0.5
            || abs(panel.frame.size.height - targetCocoaRect.size.height) >= 0.5
        {
            panel.setFrame(targetCocoaRect, display: false, animate: false)
            applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: nativeFS)
            refreshScreenCapabilitiesAndColorSpace()
            emitCurrentMetrics()
        }
    }

    /// Switches live between Fullscreen and Windowed scaling modes while preserving `lastWindowedWidth`.
    @discardableResult
    public func setPresentationMode(
        _ newMode: PresentationMode,
        multiMonitorMode: MultiMonitorMode? = nil
    ) -> OverlayDrawableMetrics {
        if currentPresentationMode.isWindowed, let currentW = panel?.frame.width, currentW >= 160 {
            lastWindowedWidth = currentW
        }

        currentPresentationMode = newMode
        if let multiMonitorMode {
            currentMultiMonitorMode = multiMonitorMode
        }

        guard let panel else {
            return currentDrawableMetrics()
        }

        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let nativeFS = newMode.isFullscreen
            && currentSourceWindowID != 0
            && WindowEnumerator.isLikelyNativeFullscreenWindow(
                windowID: currentSourceWindowID,
                bounds: currentSourceCGRect,
                displays: displays
            )
        let targetCocoaRect = computeOverlayCocoaFrame(
            sourceCGRect: currentSourceCGRect,
            presentationMode: newMode,
            multiMonitorMode: currentMultiMonitorMode,
            displays: displays,
            aspectRatio: currentAspectRatio,
            applyAntiOcclusion: shouldApplyAntiOcclusion(mode: newMode, nativeFullscreenSpace: nativeFS)
        )

        panel.setFrame(targetCocoaRect, display: true, animate: false)
        applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: nativeFS)
        applyWindowedInteractivity()
        applyVRRModeState()
        refreshScreenCapabilitiesAndColorSpace()

        let metrics = currentDrawableMetrics()
        onDrawableMetricsChanged?(metrics)
        return metrics
    }

    /// Updates pixel format, HDR/EDR mode, and `displaySyncEnabled` on `CAMetalLayer`
    /// without ever mutating `maximumDrawableCount`.
    public func updateLayerFormat(
        pixelFormat: CapturePixelFormat,
        dynamicRange: DynamicRangeMode,
        displaySyncEnabled: Bool
    ) {
        currentPixelFormat = pixelFormat
        currentDynamicRange = dynamicRange
        currentDisplaySyncEnabled = displaySyncEnabled
        refreshScreenCapabilitiesAndColorSpace()
        emitCurrentMetrics()
    }

    /// Attaches a child overlay window (e.g. Floating Toolbar or SwiftUI Profiler HUD).
    /// Automatically hidden when `isVRRDirectScanoutEnabled` is active so ProMotion VRR engages cleanly.
    public func attachChildWindow(_ child: NSWindow) {
        guard let panel else { return }
        if !childOverlayWindows.contains(where: { $0 === child }) {
            childOverlayWindows.append(child)
        }
        if isEffectiveVRRDirectScanout() {
            child.orderOut(nil)
        } else {
            panel.addChildWindow(child, ordered: .above)
        }
    }

    /// Detaches a previously attached child overlay window.
    public func detachChildWindow(_ child: NSWindow) {
        panel?.removeChildWindow(child)
        childOverlayWindows.removeAll { $0 === child }
    }

    /// Updates the hardware-composited `CALayer` cursor sprite in non-VRR mode.
    /// Converts global CoreGraphics (Y-down) cursor position into overlay view-local Cocoa coordinates.
    public func updateCursorOverlay(
        state: CursorOverlayState,
        cursorImage: NSImage? = nil,
        hotSpot: CGPoint? = nil,
        interpolation: CursorInterpolation = .bilinear
    ) {
        guard let panel, let view = overlayView else { return }
        let vrrActive = isEffectiveVRRDirectScanout()
        guard state.isVisible, !state.isMouseGrabbedByGame, !state.isIdleHidden, !vrrActive else {
            view.hideCursorSprite()
            return
        }

        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let globalCocoaPt = ScreenGeometry.cgToCocoa(point: state.scaledCGPosition, displays: displays)
        let localPt = CGPoint(
            x: globalCocoaPt.x - panel.frame.origin.x,
            y: globalCocoaPt.y - panel.frame.origin.y
        )

        let resolvedCursor = NSCursor.currentSystem ?? NSCursor.arrow
        let img = cursorImage ?? resolvedCursor.image
        let spot = hotSpot ?? resolvedCursor.hotSpot

        view.updateCursorSprite(
            visible: true,
            localCocoaPoint: localPt,
            cursorImage: img,
            hotSpot: spot,
            scaleFactor: state.scaleFactor,
            interpolation: interpolation,
            vrrDirectScanout: vrrActive
        )
    }

    /// Returns a fresh snapshot of current overlay geometry, drawable pixel dimensions, and display metadata.
    public func currentDrawableMetrics() -> OverlayDrawableMetrics {
        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let cocoaFrame = panel?.frame ?? .zero
        let cgFrame = ScreenGeometry.cocoaToCG(rect: cocoaFrame, displays: displays)
        let bestDisplay = ScreenGeometry.bestDisplay(forCocoaRect: cocoaFrame, in: displays)
            ?? ScreenGeometry.primaryDisplay(in: displays)

        let scale = max(1.0, Double(panel?.backingScaleFactor ?? CGFloat(bestDisplay?.backingScaleFactor ?? 2.0)))
        let drawableSize: PixelSize
        if let layerSize = overlayView?.metalLayer.drawableSize, layerSize.width > 0, layerSize.height > 0 {
            drawableSize = PixelSize(cgSize: layerSize)
        } else {
            drawableSize = PixelSize(
                width: max(1, Int((Double(cocoaFrame.width) * scale).rounded())),
                height: max(1, Int((Double(cocoaFrame.height) * scale).rounded()))
            )
        }

        return OverlayDrawableMetrics(
            cocoaFrame: cocoaFrame,
            cgFrame: cgFrame,
            drawablePixelSize: drawableSize,
            backingScaleFactor: scale,
            screenMaxFPS: bestDisplay?.refreshRateHz ?? 60.0,
            displayID: bestDisplay?.id ?? CGMainDisplayID(),
            supportsEDR: bestDisplay?.supportsHDR ?? false,
            isVRRDirectScanoutActive: isEffectiveVRRDirectScanout()
        )
    }

    // MARK: - Private Layout & Display Synchronization

    private func isEffectiveVRRDirectScanout() -> Bool {
        isVRRDirectScanoutEnabled
            && currentPresentationMode.isFullscreen
            && currentMultiMonitorMode == .closest
    }

    private func shouldApplyAntiOcclusion(mode: PresentationMode, nativeFullscreenSpace: Bool) -> Bool {
        guard antiOcclusionEnabled else { return false }
        if isEffectiveVRRDirectScanout() {
            // ProMotion VRR requires exact full-display coverage.
            return false
        }
        if nativeFullscreenSpace {
            return false
        }
        return true
    }

    private func computeOverlayCocoaFrame(
        sourceCGRect: CGRect,
        presentationMode: PresentationMode,
        multiMonitorMode: MultiMonitorMode,
        displays: [DisplayDescriptor],
        aspectRatio: CGFloat,
        applyAntiOcclusion: Bool
    ) -> CGRect {
        switch presentationMode {
        case .fullscreen:
            var rect = ScreenGeometry.targetCocoaFrame(
                forCGRect: sourceCGRect,
                mode: multiMonitorMode,
                in: displays
            ) ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 720)

            if applyAntiOcclusion {
                rect = ScreenGeometry.antiOcclusionInset(cocoaRect: rect, insetPoints: 1.0)
            }
            return rect

        case .windowed(let initialScale, let explicitWidth):
            let hostDisplay = ScreenGeometry.bestDisplay(forCGRect: sourceCGRect, in: displays)
                ?? ScreenGeometry.primaryDisplay(in: displays)
            let screenCocoa = hostDisplay?.cocoaFrame
                ?? NSScreen.main?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let sourceCocoa = ScreenGeometry.cgToCocoa(rect: sourceCGRect, displays: displays)

            let targetWidth: CGFloat
            if let explicitWidth, explicitWidth >= 200 {
                targetWidth = CGFloat(explicitWidth)
            } else if let remembered = lastWindowedWidth, remembered >= 200 {
                targetWidth = remembered
            } else if let scale = initialScale, scale > 0.1 {
                targetWidth = max(320.0, sourceCocoa.width * CGFloat(scale))
            } else {
                // Magpie Auto heuristic: 3/4 of screen area, at least 4/3x source width.
                let threeQuarterScreenW = screenCocoa.width * 0.75
                let threeQuarterScreenH = screenCocoa.height * 0.75
                let maxFitW = min(threeQuarterScreenW, threeQuarterScreenH * aspectRatio)
                let minAutoW = sourceCocoa.width * (4.0 / 3.0)
                targetWidth = max(320.0, min(screenCocoa.width * 0.95, max(maxFitW, minAutoW)))
            }

            let clampedW = min(screenCocoa.width, max(320.0, targetWidth))
            var clampedH = clampedW / max(0.1, aspectRatio)
            var finalW = clampedW
            if clampedH > screenCocoa.height * 0.95 {
                clampedH = screenCocoa.height * 0.95
                finalW = clampedH * max(0.1, aspectRatio)
            }

            // Center over source window, clamped within host display bounds.
            var originX = sourceCocoa.midX - finalW * 0.5
            var originY = sourceCocoa.midY - clampedH * 0.5
            originX = min(max(originX, screenCocoa.minX), screenCocoa.maxX - finalW)
            originY = min(max(originY, screenCocoa.minY), screenCocoa.maxY - clampedH)

            var rect = CGRect(
                x: originX.rounded(),
                y: originY.rounded(),
                width: finalW.rounded(),
                height: clampedH.rounded()
            )
            if applyAntiOcclusion {
                rect = ScreenGeometry.antiOcclusionInset(cocoaRect: rect, insetPoints: 1.0)
            }
            return rect
        }
    }

    private func applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: Bool) {
        guard let panel else { return }
        isCoveringNativeFullscreenSpace = nativeFullscreenSpace

        if nativeFullscreenSpace {
            panel.level = Self.nativeFullscreenOverlayLevel
            if savedActivationPolicy == nil {
                savedActivationPolicy = NSApp.activationPolicy()
            }
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            panel.level = Self.normalOverlayLevel
            restoreActivationPolicyIfNeeded()
        }
    }

    private func restoreActivationPolicyIfNeeded() {
        guard let original = savedActivationPolicy else { return }
        savedActivationPolicy = nil
        if NSApp.activationPolicy() != original {
            NSApp.setActivationPolicy(original)
        }
    }

    private func applyWindowedInteractivity() {
        guard let panel, let view = overlayView else { return }
        if currentPresentationMode.isFullscreen {
            panel.ignoresMouseEvents = true
            view.isInteractiveWindowedMode = false
        } else {
            panel.ignoresMouseEvents = isWindowedClickThrough
            view.isInteractiveWindowedMode = !isWindowedClickThrough
        }
    }

    private func applyVRRModeState() {
        guard let view = overlayView else { return }
        let vrrActive = isEffectiveVRRDirectScanout()
        if vrrActive {
            view.hideCursorSprite()
            for child in childOverlayWindows {
                panel?.removeChildWindow(child)
                child.orderOut(nil)
            }
        } else if let panel, isRevealed && !isSuspended {
            for child in childOverlayWindows {
                panel.addChildWindow(child, ordered: .above)
            }
        }

        // Recompute frame in case 1-pt anti-occlusion inset needs to be toggled for VRR full-screen scanout.
        if isSessionOpen && currentPresentationMode.isFullscreen && currentSourceCGRect.width > 0 {
            updateSourceWindowGeometry(currentSourceCGRect)
        }
    }

    private func refreshScreenCapabilitiesAndColorSpace() {
        guard let panel, let view = overlayView else { return }

        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let hostDisplay = ScreenGeometry.bestDisplay(forCocoaRect: panel.frame, in: displays)
            ?? ScreenGeometry.primaryDisplay(in: displays)
        let hostScreen = hostDisplay.flatMap { WindowEnumerator.nsScreen(for: $0.id) }
            ?? panel.screen
            ?? NSScreen.main

        if let hostDisplay {
            activeDisplayID = hostDisplay.id
        }

        let layer = view.metalLayer
        let supportsEDR = (hostDisplay?.supportsHDR ?? false)
            || ((hostScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0)
        let wantsHDR = (currentDynamicRange == .hdr || currentPixelFormat == .rgba16f) && supportsEDR

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if wantsHDR {
            layer.pixelFormat = .rgba16Float
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        } else {
            layer.wantsExtendedDynamicRangeContent = false
            switch currentPixelFormat {
            case .rgb10a2:
                layer.pixelFormat = .bgr10a2Unorm
            case .rgba16f:
                // Requested 16f on an SDR display: still use rgba16Float without EDR headroom or bgra8.
                layer.pixelFormat = .rgba16Float
            case .bgra8, .nv12:
                layer.pixelFormat = .bgra8Unorm
            }
            if let screenSpace = hostScreen?.colorSpace?.cgColorSpace {
                layer.colorspace = screenSpace
            } else {
                layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            }
        }

        layer.isOpaque = true
        layer.framebufferOnly = true
        layer.displaySyncEnabled = currentDisplaySyncEnabled

        CATransaction.commit()
        view.syncDrawableGeometry()
    }

    private func installWindowObservers(for panel: OverlayPanel) {
        let nc = NotificationCenter.default

        let screenObs = nc.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshScreenCapabilitiesAndColorSpace()
                self?.emitCurrentMetrics()
            }
        }

        let backingObs = nc.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshScreenCapabilitiesAndColorSpace()
                self?.emitCurrentMetrics()
            }
        }

        let displayParamObs = nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isSessionOpen else { return }
                self.refreshScreenCapabilitiesAndColorSpace()
                if self.currentPresentationMode.isFullscreen && self.currentSourceCGRect.width > 0 {
                    self.updateSourceWindowGeometry(self.currentSourceCGRect)
                } else {
                    self.emitCurrentMetrics()
                }
            }
        }

        let newTokens = [
            ObserverToken(raw: screenObs),
            ObserverToken(raw: backingObs),
            ObserverToken(raw: displayParamObs)
        ]
        observerLock.withLock { $0.append(contentsOf: newTokens) }
    }

    private func detachAllChildWindows() {
        for child in childOverlayWindows {
            panel?.removeChildWindow(child)
            child.orderOut(nil)
        }
        childOverlayWindows.removeAll()
    }

    private func emitCurrentMetrics() {
        guard isSessionOpen else { return }
        let metrics = currentDrawableMetrics()
        onDrawableMetricsChanged?(metrics)
    }
}
