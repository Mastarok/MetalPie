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

    /// Never let AppKit clamp or shift the borderless overlay below the menu bar (notch) or onto the
    /// primary display when positioning on secondary, negative-origin, diagonal, or multi-monitor spans!
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

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
        alphaValue = OverlayWindowController.antiOcclusionAlphaValue
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
        layer.cornerRadius = OverlayWindowController.windowedCornerRadius
        layer.cornerCurve = .continuous
        layer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
            "borderColor": NSNull(),
            "cornerRadius": NSNull()
        ]
        return layer
    }()

    /// Active rounded corner radius applied to `metalLayer` (10pt in windowed mode, 0pt in fullscreen).
    private var appliedCornerRadius: CGFloat = 0.0

    /// Callback fired whenever `drawableSize` or `contentsScale` changes.
    public var onGeometryChanged: ((PixelSize, Double) -> Void)?

    /// Callback fired when interactive windowed drag/resize finishes or updates the window frame.
    public var onInteractiveFrameUpdate: ((CGRect) -> Void)?

    /// Callback fired when an interactive windowed drag/resize gesture starts.
    public var onInteractiveDragStarted: ((CGRect) -> Void)?

    /// Callback fired when an interactive windowed drag/resize gesture ends.
    public var onInteractiveDragEnded: ((CGRect) -> Void)?

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

    /// Minimum allowed windowed overlay height in logical points.
    public var minimumWindowedHeight: CGFloat = 180.0

    private enum DragOperation {
        case move
        case resize(edges: ResizeEdges)
    }

    public struct ResizeEdges: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let left   = ResizeEdges(rawValue: 1 << 0)
        public static let right  = ResizeEdges(rawValue: 1 << 1)
        public static let top    = ResizeEdges(rawValue: 1 << 2)
        public static let bottom = ResizeEdges(rawValue: 1 << 3)
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
        reapplyCornerRadius()
        syncDrawableGeometry()
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        windowedBorderLayer.frame = bounds
        metalLayer.cornerRadius = appliedCornerRadius
        metalLayer.cornerCurve = .continuous
        metalLayer.masksToBounds = appliedCornerRadius > 0.0
        windowedBorderLayer.cornerRadius = appliedCornerRadius
        CATransaction.commit()
        syncDrawableGeometry()
    }

    /// Applies continuous native macOS rounded corners to `metalLayer` (re-asserted on attach/layout
    /// because AppKit can reset `masksToBounds` when attaching a backing `CAMetalLayer`).
    public func setRoundedCornerRadius(_ radius: CGFloat) {
        appliedCornerRadius = max(0.0, radius)
        reapplyCornerRadius()
    }

    private func reapplyCornerRadius() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.cornerRadius = appliedCornerRadius
        metalLayer.cornerCurve = .continuous
        metalLayer.masksToBounds = appliedCornerRadius > 0.0
        windowedBorderLayer.cornerRadius = appliedCornerRadius
        windowedBorderLayer.cornerCurve = .continuous
        CATransaction.commit()
    }

    /// Host-display backing scale override used while the overlay panel is off-screen (before first-frame
    /// reveal) so mixed-DPI multi-monitor overlays (e.g. @1x external + @2x Retina primary) never inherit
    /// `NSScreen.main`'s backing scale factor.
    public var preferredBackingScaleFactor: Double?

    /// Synchronizes `metalLayer.contentsScale` and `metalLayer.drawableSize` explicitly from view bounds.
    @discardableResult
    public func syncDrawableGeometry(preferredBackingScale: Double? = nil) -> (PixelSize, Double) {
        if let preferredBackingScale {
            preferredBackingScaleFactor = max(1.0, preferredBackingScale)
        }
        let resolvedScale: Double
        if let preferred = preferredBackingScaleFactor {
            resolvedScale = preferred
        } else if let win = window, win.isVisible, let screen = win.screen {
            resolvedScale = Double(screen.backingScaleFactor)
        } else {
            resolvedScale = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        }
        let scale = max(1.0, resolvedScale)
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
        onInteractiveDragStarted?(win.frame)
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
            if let visible = Self.bestHostVisibleFrame(for: newFrame, fallbackScreen: win.screen),
               newFrame.height <= visible.height,
               newFrame.maxY > visible.maxY
            {
                newFrame.origin.y = (visible.maxY - newFrame.height).rounded()
            }

        case .resize(let edges):
            let hostVisible = Self.bestHostVisibleFrame(for: dragStartWindowFrame, fallbackScreen: win.screen)
            let hostScreenSize = hostVisible?.size ?? win.screen?.frame.size ?? NSScreen.main?.frame.size
            var clampedDY = dy
            if edges.contains(.top), let visible = hostVisible {
                clampedDY = min(clampedDY, visible.maxY - dragStartWindowFrame.maxY)
            }
            newFrame = Self.computeInteractiveResizeFrame(
                startFrame: dragStartWindowFrame,
                edges: edges,
                delta: CGVector(dx: dx, dy: clampedDY),
                aspectRatio: lockedAspectRatio,
                minWidth: minimumWindowedWidth,
                minHeight: minimumWindowedHeight,
                maxSize: hostScreenSize
            )
            if let visible = hostVisible, newFrame.maxY > visible.maxY {
                if newFrame.height <= visible.height {
                    newFrame.origin.y = (visible.maxY - newFrame.height).rounded()
                } else {
                    newFrame.size.height = visible.height.rounded()
                    newFrame.origin.y = visible.minY.rounded()
                }
            }
        }

        win.setFrame(newFrame, display: true, animate: false)
        syncDrawableGeometry()
        onInteractiveFrameUpdate?(win.frame)
    }

    private static func bestHostVisibleFrame(for cocoaFrame: CGRect, fallbackScreen: NSScreen?) -> CGRect? {
        let bestScreen = NSScreen.screens.max { lhs, rhs in
            let lInter = lhs.frame.intersection(cocoaFrame)
            let rInter = rhs.frame.intersection(cocoaFrame)
            let lArea = (lInter.isNull || lInter.isEmpty) ? 0 : (lInter.width * lInter.height)
            let rArea = (rInter.isNull || rInter.isEmpty) ? 0 : (rInter.width * rInter.height)
            return lArea < rArea
        }
        if let bestScreen, bestScreen.frame.intersects(cocoaFrame) {
            return bestScreen.visibleFrame
        }
        return fallbackScreen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    /// Pure, unit-testable aspect-locked 8-direction interactive resize solver supporting BOTH
    /// inward shrinking (down to `minWidth`/`minHeight`) and outward expansion (up to `maxSize`).
    public static func computeInteractiveResizeFrame(
        startFrame: CGRect,
        edges: ResizeEdges,
        delta: CGVector,
        aspectRatio: CGFloat,
        minWidth: CGFloat,
        minHeight: CGFloat,
        maxSize: CGSize? = nil
    ) -> CGRect {
        let aspect = max(0.1, aspectRatio)
        let baseMinW = max(160.0, minWidth)
        let baseMinH = max(90.0, minHeight)
        let minW = max(baseMinW, baseMinH * aspect)
        let minH = max(baseMinH, minW / aspect)

        let maxW: CGFloat
        let maxH: CGFloat
        if let maxSize, maxSize.width > 0, maxSize.height > 0 {
            let aspectFitW = min(maxSize.width, maxSize.height * aspect)
            maxW = max(minW, aspectFitW)
            maxH = max(minH, maxW / aspect)
        } else {
            maxW = .greatestFiniteMagnitude
            maxH = .greatestFiniteMagnitude
        }

        var proposedW = startFrame.width
        var proposedH = startFrame.height

        if edges.contains(.right) {
            proposedW += delta.dx
        } else if edges.contains(.left) {
            proposedW -= delta.dx
        }

        if edges.contains(.top) {
            proposedH += delta.dy
        } else if edges.contains(.bottom) {
            proposedH -= delta.dy
        }

        let hasHorizontal = edges.contains(.left) || edges.contains(.right)
        let hasVertical = edges.contains(.top) || edges.contains(.bottom)

        if hasHorizontal && hasVertical {
            let widthFromH = proposedH * aspect
            if abs(proposedW - startFrame.width) >= abs(widthFromH - startFrame.width) {
                proposedW = min(maxW, max(minW, proposedW))
                proposedH = min(maxH, max(minH, proposedW / aspect))
            } else {
                proposedH = min(maxH, max(minH, proposedH))
                proposedW = min(maxW, max(minW, proposedH * aspect))
            }
        } else if hasHorizontal {
            proposedW = min(maxW, max(minW, proposedW))
            proposedH = min(maxH, max(minH, proposedW / aspect))
        } else if hasVertical {
            proposedH = min(maxH, max(minH, proposedH))
            proposedW = min(maxW, max(minW, proposedH * aspect))
        }

        proposedW = min(maxW, max(baseMinW, proposedW))
        proposedH = min(maxH, max(baseMinH, proposedH))

        var newFrame = startFrame
        let roundedW = proposedW.rounded()
        let roundedH = proposedH.rounded()
        if edges.contains(.left) {
            newFrame.origin.x = startFrame.maxX - roundedW
        }
        if edges.contains(.bottom) {
            newFrame.origin.y = startFrame.maxY - roundedH
        }
        newFrame.size = CGSize(width: roundedW, height: roundedH)
        return newFrame
    }

    public override func mouseUp(with event: NSEvent) {
        let wasDragging = activeDrag != nil
        activeDrag = nil
        if wasDragging, let win = window {
            onInteractiveDragEnded?(win.frame)
        }
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

// MARK: - Popup Menu Context Classifier Types

/// Snapshot of an on-screen popup menu window used to discriminate in-window right-click
/// context menus (which macOS 27 `SCContentFilter(desktopIndependentWindow:)` captures inside
/// the scaled stream) from macOS top Menu Bar dropdowns (which must stay visible above the overlay).
public struct PopupMenuWindowSnapshot: Hashable, Sendable {
    public var windowID: CGWindowID
    public var pid: Int32
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double

    public init(
        windowID: CGWindowID,
        pid: Int32,
        layer: Int,
        bounds: CGRect,
        alpha: Double = 1.0
    ) {
        self.windowID = windowID
        self.pid = pid
        self.layer = layer
        self.bounds = bounds.standardized
        self.alpha = alpha
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(pid)
        hasher.combine(layer)
        hasher.combine(bounds.origin.x)
        hasher.combine(bounds.origin.y)
        hasher.combine(bounds.size.width)
        hasher.combine(bounds.size.height)
        hasher.combine(alpha)
    }
}

/// Decision returned by `OverlayWindowController.evaluatePopupMenuLevelBoost(...)`.
public struct PopupMenuLevelEvaluation: Equatable, Sendable {
    public var shouldBoostAbovePopupMenus: Bool
    public var isMenuBarDropdownActive: Bool

    public init(shouldBoostAbovePopupMenus: Bool, isMenuBarDropdownActive: Bool) {
        self.shouldBoostAbovePopupMenus = shouldBoostAbovePopupMenus
        self.isMenuBarDropdownActive = isMenuBarDropdownActive
    }
}

// MARK: - OverlayChromeGeometry (Notch-Safe Placement & Shadow Bleed Padding)

/// Pure, unit-testable layout solver for floating overlay chrome (toolbar, profiler HUD, toast)
/// guaranteeing MacBook Pro notch / macOS Menu Bar clearance and transparent shadow-bleed padding
/// (so SwiftUI drop shadows never clip into rectangular boxes and empty shadow margins never hijack clicks).
public enum OverlayChromeGeometry: Sendable {
    public static let defaultToolbarSize = CGSize(width: 420, height: 42)
    public static let defaultShadowPadding: CGFloat = 20
    public static let defaultTopMargin: CGFloat = 10
    public static let notchSafeTopMargin: CGFloat = 6

    /// Computes the visible toolbar pill frame in global AppKit (Cocoa Y-up) coordinates,
    /// clamping below `hostScreenVisibleFrame.maxY` whenever `overlayCocoaFrame` extends into
    /// the macOS Menu Bar or MacBook Pro camera notch strip.
    public static func computeVisibleToolbarCocoaFrame(
        for overlayCocoaFrame: CGRect,
        hostScreenVisibleFrame: CGRect?,
        toolbarSize: CGSize = defaultToolbarSize,
        topMargin: CGFloat = defaultTopMargin,
        notchSafeTopMargin: CGFloat = notchSafeTopMargin
    ) -> CGRect {
        let usableBounds: CGRect
        if let visible = hostScreenVisibleFrame {
            let intersection = overlayCocoaFrame.intersection(visible)
            usableBounds = (!intersection.isNull && intersection.width >= 260 && intersection.height >= 80)
                ? intersection
                : overlayCocoaFrame
        } else {
            usableBounds = overlayCocoaFrame
        }
        let w = min(toolbarSize.width, max(240, usableBounds.width - 16))
        let h = toolbarSize.height
        let rawX = (usableBounds.midX - w * 0.5).rounded()
        let x = min(max(rawX, usableBounds.minX + 6), max(usableBounds.minX + 6, usableBounds.maxX - w - 6))
        let desiredTop = overlayCocoaFrame.maxY - topMargin
        let safeTop: CGFloat
        if let visible = hostScreenVisibleFrame, overlayCocoaFrame.maxY > visible.maxY {
            safeTop = min(desiredTop, visible.maxY - notchSafeTopMargin)
        } else {
            safeTop = desiredTop
        }
        let safeBottom = usableBounds.minY + 6
        let y = max(safeBottom, safeTop - h).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Expands a visible pill/card frame by `shadowPadding` on all four sides so SwiftUI drop shadows
    /// fade smoothly to 0% alpha well inside the transparent borderless `NSPanel` bounds.
    public static func panelFrame(
        fromVisibleFrame visibleFrame: CGRect,
        shadowPadding: CGFloat = defaultShadowPadding
    ) -> CGRect {
        visibleFrame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
    }

    /// Strips transparent `shadowPadding` from a chrome `NSPanel` frame to recover the exact visible
    /// interactive rect so empty transparent shadow margins never intercept mouse clicks.
    public static func visibleFrame(
        fromPanelFrame panelFrame: CGRect,
        shadowPadding: CGFloat = defaultShadowPadding
    ) -> CGRect {
        panelFrame.insetBy(dx: shadowPadding, dy: shadowPadding)
    }

    /// Converts visible interactive floating chrome panel frames (excluding transparent shadow padding)
    /// into global CoreGraphics (Y-down) rects for `CursorOverlayController.updateInteractiveChromeRects(_:)`.
    public static func interactiveChromeCGRects(
        toolbarPanelCocoaFrame: CGRect?,
        toolbarIsInteractive: Bool,
        hudPanelCocoaFrame: CGRect?,
        hudIsVisible: Bool,
        displays: [DisplayDescriptor],
        shadowPadding: CGFloat = defaultShadowPadding
    ) -> [CGRect] {
        var cgRects: [CGRect] = []
        if toolbarIsInteractive, let toolbarPanel = toolbarPanelCocoaFrame {
            let visible = visibleFrame(fromPanelFrame: toolbarPanel, shadowPadding: shadowPadding)
            if !visible.isEmpty {
                cgRects.append(ScreenGeometry.cocoaToCG(rect: visible, displays: displays))
            }
        }
        if hudIsVisible, let hudPanel = hudPanelCocoaFrame {
            let visible = visibleFrame(fromPanelFrame: hudPanel, shadowPadding: shadowPadding)
            if !visible.isEmpty {
                cgRects.append(ScreenGeometry.cocoaToCG(rect: visible, displays: displays))
            }
        }
        return cgRects
    }
}

// MARK: - OverlayToolbarAutoHideState (Idempotent Show & Dual-Pointer Hover State Machine)

/// Pure, unit-testable state machine driving `OverlayToolbarPanel`'s `Off` / `AutoHide` / `AlwaysShow`
/// lifecycle, idempotent repeated `show(...)` calls (zero hover-reset flicker), dual-pointer
/// (physical `NSEvent.mouseLocation` + scaled cursor) hover tracking with hysteresis, and
/// `0.5pt`-deduplicated interactive-frame change notifications.
public struct OverlayToolbarAutoHideState: Sendable {
    public static let fittsTopStripHeight: CGFloat = 28
    public static let hoverHysteresisDX: CGFloat = 24
    public static let hoverHysteresisDY: CGFloat = 18
    public static let hideDelaySeconds: TimeInterval = 0.85
    public static let frameChangeTolerance: CGFloat = 0.5

    public struct ShowTransition: Equatable, Sendable {
        public var shouldHide: Bool
        public var isIdempotentUpdate: Bool
        public var shouldResetAutoHideHidden: Bool
        public var shouldStartHoverTimer: Bool
        public var shouldStopHoverTimer: Bool
        public var shouldRevealAlwaysShow: Bool
        public var interactiveFrameChanged: Bool
    }

    public enum HoverAction: Equatable, Sendable {
        case none
        case reveal
        case hide
    }

    public struct HoverEvaluation: Equatable, Sendable {
        public var action: HoverAction
        public var isHovering: Bool
        public var interactiveFrameChanged: Bool
    }

    public private(set) var mode: ToolbarMode = .autoHide
    public private(set) var isShown: Bool = false
    public private(set) var isRevealedByHover: Bool = false
    public private(set) var lastHoverLeaveTime: TimeInterval = 0
    public private(set) var anchorOverlayFrame: CGRect = .zero
    public private(set) var visibleToolbarFrame: CGRect = .zero
    public private(set) var lastReportedInteractiveFrame: CGRect? = nil

    public init() {}

    /// Exact visible interactive Cocoa frame when the toolbar is currently accepting clicks,
    /// or `nil` when hidden or auto-hidden.
    public var visibleInteractiveCocoaFrame: CGRect? {
        guard isShown, !visibleToolbarFrame.isEmpty else { return nil }
        guard mode == .alwaysShow || isRevealedByHover else { return nil }
        return visibleToolbarFrame
    }

    /// Computes the Fitts's-law top-edge trigger strip in global AppKit (Cocoa Y-up) coordinates.
    /// Extends smoothly from inside `visibleToolbarRect` up past `anchorOverlayFrame.maxY` so there
    /// is ZERO dead gap between the screen/overlay top edge and the toolbar pill (including below a notch).
    public static func computeAutoHideTopStrip(
        anchorOverlayFrame: CGRect,
        visibleToolbarRect: CGRect
    ) -> CGRect {
        let stripWidth = max(visibleToolbarRect.width, OverlayChromeGeometry.defaultToolbarSize.width) * 1.3
        let stripX = (visibleToolbarRect.midX - stripWidth * 0.5).rounded()
        let stripMinY = min(visibleToolbarRect.maxY - fittsTopStripHeight, visibleToolbarRect.maxY - 12)
        let stripMaxY = max(
            anchorOverlayFrame.maxY + 4,
            visibleToolbarRect.maxY + OverlayChromeGeometry.notchSafeTopMargin + 6
        )
        return CGRect(
            x: stripX,
            y: stripMinY,
            width: stripWidth,
            height: max(fittsTopStripHeight, stripMaxY - stripMinY)
        )
    }

    /// Returns `true` when two optional rects differ by at least `tolerance` points on any edge/size.
    public static func framesDiffer(
        _ lhs: CGRect?,
        _ rhs: CGRect?,
        tolerance: CGFloat = frameChangeTolerance
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return false
        case (nil, .some), (.some, nil):
            return true
        case let (.some(a), .some(b)):
            return abs(a.origin.x - b.origin.x) >= tolerance
                || abs(a.origin.y - b.origin.y) >= tolerance
                || abs(a.size.width - b.size.width) >= tolerance
                || abs(a.size.height - b.size.height) >= tolerance
        }
    }

    /// Applies a `show(mode:overlayCocoaFrame:...)` call idempotently: when already shown in the
    /// same `mode`, preserves `isRevealedByHover`, `lastHoverLeaveTime`, and the hover timer so
    /// repeated metric/chrome syncs NEVER cause hover flicker.
    public mutating func beginShow(
        mode: ToolbarMode,
        overlayCocoaFrame: CGRect,
        visibleToolbarFrame: CGRect
    ) -> ShowTransition {
        if mode == .off || overlayCocoaFrame.isEmpty || visibleToolbarFrame.isEmpty {
            let changed = hide()
            self.mode = mode
            self.anchorOverlayFrame = overlayCocoaFrame
            return ShowTransition(
                shouldHide: true,
                isIdempotentUpdate: false,
                shouldResetAutoHideHidden: false,
                shouldStartHoverTimer: false,
                shouldStopHoverTimer: true,
                shouldRevealAlwaysShow: false,
                interactiveFrameChanged: changed
            )
        }

        let wasShownInSameMode = isShown && self.mode == mode
        self.mode = mode
        self.anchorOverlayFrame = overlayCocoaFrame
        self.visibleToolbarFrame = visibleToolbarFrame
        self.isShown = true

        if wasShownInSameMode {
            let changed = consumeInteractiveFrameChangeIfNeeded()
            return ShowTransition(
                shouldHide: false,
                isIdempotentUpdate: true,
                shouldResetAutoHideHidden: false,
                shouldStartHoverTimer: false,
                shouldStopHoverTimer: false,
                shouldRevealAlwaysShow: false,
                interactiveFrameChanged: changed
            )
        }

        switch mode {
        case .off:
            let changed = hide()
            return ShowTransition(
                shouldHide: true,
                isIdempotentUpdate: false,
                shouldResetAutoHideHidden: false,
                shouldStartHoverTimer: false,
                shouldStopHoverTimer: true,
                shouldRevealAlwaysShow: false,
                interactiveFrameChanged: changed
            )
        case .alwaysShow:
            isRevealedByHover = false
            lastHoverLeaveTime = 0
            let changed = consumeInteractiveFrameChangeIfNeeded()
            return ShowTransition(
                shouldHide: false,
                isIdempotentUpdate: false,
                shouldResetAutoHideHidden: false,
                shouldStartHoverTimer: false,
                shouldStopHoverTimer: true,
                shouldRevealAlwaysShow: true,
                interactiveFrameChanged: changed
            )
        case .autoHide:
            isRevealedByHover = false
            lastHoverLeaveTime = 0
            let changed = consumeInteractiveFrameChangeIfNeeded()
            return ShowTransition(
                shouldHide: false,
                isIdempotentUpdate: false,
                shouldResetAutoHideHidden: true,
                shouldStartHoverTimer: true,
                shouldStopHoverTimer: false,
                shouldRevealAlwaysShow: false,
                interactiveFrameChanged: changed
            )
        }
    }

    /// Updates the overlay anchor and visible pill frame without ever resetting hover state.
    /// Returns `true` ONLY if `visibleInteractiveCocoaFrame` actually changed by `>= 0.5pt`.
    public mutating func updateOverlayFrame(
        _ overlayCocoaFrame: CGRect,
        visibleToolbarFrame: CGRect
    ) -> Bool {
        self.anchorOverlayFrame = overlayCocoaFrame
        if isShown && !overlayCocoaFrame.isEmpty && !visibleToolbarFrame.isEmpty {
            self.visibleToolbarFrame = visibleToolbarFrame
        }
        return consumeInteractiveFrameChangeIfNeeded()
    }

    /// Hides the toolbar and returns `true` ONLY if an interactive frame was previously reported.
    @discardableResult
    public mutating func hide() -> Bool {
        isShown = false
        isRevealedByHover = false
        lastHoverLeaveTime = 0
        return consumeInteractiveFrameChangeIfNeeded()
    }

    /// Returns `true` when `point` (global AppKit Cocoa Y-up) lies inside the top trigger strip
    /// OR (when already revealed) inside `visibleToolbarFrame` expanded by `(±24pt, ±18pt)`.
    public func isPointHovering(_ point: CGPoint) -> Bool {
        guard isShown, !visibleToolbarFrame.isEmpty else { return false }
        let topStrip = Self.computeAutoHideTopStrip(
            anchorOverlayFrame: anchorOverlayFrame,
            visibleToolbarRect: visibleToolbarFrame
        )
        if topStrip.contains(point) {
            return true
        }
        if isRevealedByHover {
            let expandedToolbar = visibleToolbarFrame.insetBy(
                dx: -Self.hoverHysteresisDX,
                dy: -Self.hoverHysteresisDY
            )
            if expandedToolbar.contains(point) {
                return true
            }
        }
        return false
    }

    /// Evaluates hover against BOTH the physical OS cursor (`NSEvent.mouseLocation`) AND the
    /// scaled cursor position so switching into/out of `.directChrome` NEVER drops hover.
    public func isHovering(
        physicalCocoaPoint: CGPoint,
        scaledCocoaPoint: CGPoint?
    ) -> Bool {
        if isPointHovering(physicalCocoaPoint) {
            return true
        }
        if let scaled = scaledCocoaPoint, isPointHovering(scaled) {
            return true
        }
        return false
    }

    /// Advances the auto-hide hover state machine for one timer tick.
    public mutating func evaluateAutoHideHover(
        physicalCocoaPoint: CGPoint,
        scaledCocoaPoint: CGPoint?,
        now: TimeInterval
    ) -> HoverEvaluation {
        guard isShown, mode == .autoHide, !visibleToolbarFrame.isEmpty else {
            return HoverEvaluation(action: .none, isHovering: false, interactiveFrameChanged: false)
        }

        let hovering = isHovering(
            physicalCocoaPoint: physicalCocoaPoint,
            scaledCocoaPoint: scaledCocoaPoint
        )

        if hovering {
            lastHoverLeaveTime = 0
            if !isRevealedByHover {
                isRevealedByHover = true
                let changed = consumeInteractiveFrameChangeIfNeeded()
                return HoverEvaluation(action: .reveal, isHovering: true, interactiveFrameChanged: changed)
            }
            return HoverEvaluation(action: .none, isHovering: true, interactiveFrameChanged: false)
        }

        if isRevealedByHover {
            if lastHoverLeaveTime == 0 {
                lastHoverLeaveTime = now
            } else if now - lastHoverLeaveTime >= Self.hideDelaySeconds {
                isRevealedByHover = false
                lastHoverLeaveTime = 0
                let changed = consumeInteractiveFrameChangeIfNeeded()
                return HoverEvaluation(action: .hide, isHovering: false, interactiveFrameChanged: changed)
            }
        }

        return HoverEvaluation(action: .none, isHovering: false, interactiveFrameChanged: false)
    }

    private mutating func consumeInteractiveFrameChangeIfNeeded() -> Bool {
        let current = visibleInteractiveCocoaFrame
        guard Self.framesDiffer(lastReportedInteractiveFrame, current, tolerance: Self.frameChangeTolerance) else {
            return false
        }
        lastReportedInteractiveFrame = current
        return true
    }
}

// MARK: - OverlayWindowController

/// Manages the lifecycle, window level, multi-monitor geometry, color space/EDR, windowed resize state,
/// VRR direct-scanout mode, and reveal-on-first-frame gating of MetalPie's scaling overlay panel.
@MainActor
public final class OverlayWindowController {
    /// Fullscreen (non-native-FS) overlay window level: 3 below `popUpMenuWindow` (level 98 — strictly
    /// ABOVE macOS Menu Bar `24` and Status Bar `25` so fullscreen scaling never overlaps/bleeds behind
    /// the translucent top Menu Bar, while keeping overlay `98`, cursor `99`, and toolbar/HUD `100`
    /// ALL strictly below `popUpMenuWindow` `101`!).
    public static let fullscreenOverlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) - 3
    )

    /// Alias to `fullscreenOverlayLevel` (`98`) preserved for existing callers and tests.
    public static let normalOverlayLevel = fullscreenOverlayLevel

    /// Windowed overlay window level: 3 below `mainMenuWindow` (level 21 — strictly above normal apps `0`,
    /// floating palettes `3`, modal panels `8`, and Dock `20`, while keeping windowed overlay `21`,
    /// cursor `22`, and toolbar/HUD `23` ALL strictly below macOS Menu Bar `24` and Status Bar `25`!).
    public static let windowedOverlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 3
    )

    /// Native macOS Full-Screen Space overlay level: level 19 (above full-screen app, below auto-hiding Dock/Menu Bar).
    public static let nativeFullscreenOverlayLevel = NSWindow.Level(rawValue: 19)

    /// Fullscreen VRR direct-scanout overlay level (`popUpMenuWindow - 1` = 100) for unobstructed ProMotion scanout.
    public static let vrrFullscreenOverlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) - 1
    )

    /// Temporary level boost (`popUpMenuWindow + 1` = 102) engaged ONLY while an in-window `NSMenu`
    /// context menu of the scaled app is open, hiding the unscaled duplicate `layer == 101` menu behind
    /// the overlay so only the single scaled context menu captured by `SCStream` is visible.
    public static let popupMenuBoostOverlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1
    )

    /// Native continuous corner radius applied in Windowed mode (`panel.isOpaque = false, backgroundColor = .clear`
    /// with `metalLayer.isOpaque = true`, empirically verified zero black corners, zero DisplayLink stall, and
    /// zero WindowServer occlusion).
    public static let windowedCornerRadius: CGFloat = 10.0

    /// Absolute minimum interactive resize dimensions when AX source shrinking is available.
    public static let absoluteMinimumWindowedWidth: CGFloat = 320.0
    public static let absoluteMinimumWindowedHeight: CGFloat = 180.0

    /// Empirically verified on macOS 27.0.1 (Apple M4 Pro): setting `panel.alphaValue = 0.999` while
    /// keeping `metalLayer.isOpaque = true` prevents macOS WindowServer from marking underlying
    /// browser/app windows as occluded (`occlusionState = []`), keeping `<video>` playback & Blink/WebKit
    /// compositing running at full 60/120 Hz with zero visual bleed (< 0.26 LSB in 8-bit SDR) and zero
    /// `CAMetalDisplayLink` stalls (220+ frames).
    public static let antiOcclusionAlphaValue: CGFloat = 0.999

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

    /// True while temporarily boosted above `popUpMenuWindow` (`level 102`) to hide a duplicate unscaled
    /// right-click `NSMenu` that `SCContentFilter(desktopIndependentWindow:)` is already rendering scaled.
    public private(set) var isPopupMenuLevelBoostActive: Bool = false

    /// When `true` (Accessibility trusted), unlocked windowed edge-dragging may shrink inward down to
    /// `320×180` while `AppCoordinator` shrinks the underlying source window via AX to match.
    public var allowInwardResizeBelowSource: Bool = false {
        didSet {
            if allowInwardResizeBelowSource != oldValue && isSessionOpen {
                let displays = WindowEnumerator.enumerateDisplaysOnMain()
                syncMinimumWindowedBounds(for: currentSourceCGRect, displays: displays)
            }
        }
    }

    /// Fired whenever `panel.level` changes (e.g. popup-menu boost on/off or fullscreen/windowed switch)
    /// so cursor and floating chrome stay strictly layered `(base, base+1, base+2)`.
    public var onOverlayLevelChanged: ((NSWindow.Level) -> Void)?

    /// Prevents macOS WindowServer / App Nap from marking underlying browser/Electron windows as
    /// occluded in normal (non-VRR) mode (`panel.alphaValue = 0.999` + 1-pt bottom inset in fullscreen).
    public var antiOcclusionEnabled: Bool = true {
        didSet {
            if antiOcclusionEnabled != oldValue {
                applyOcclusionAndShadowState()
                if isSessionOpen && currentPresentationMode.isFullscreen && currentSourceCGRect.width > 0 {
                    updateSourceWindowGeometry(currentSourceCGRect)
                }
            }
        }
    }

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

    /// Fired when an interactive windowed drag/resize gesture starts (`true`) or ends (`false`).
    public var onWindowedDragStateChanged: ((Bool, CGRect) -> Void)?

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
            view.onInteractiveDragStarted = { [weak self] startCocoaFrame in
                self?.onWindowedDragStateChanged?(true, startCocoaFrame)
            }
            view.onInteractiveDragEnded = { [weak self] endCocoaFrame in
                guard let self else { return }
                self.lastWindowedWidth = endCocoaFrame.width
                self.refreshScreenCapabilitiesAndColorSpace()
                self.onWindowedDragStateChanged?(false, endCocoaFrame)
                let metrics = self.currentDrawableMetrics()
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
        isPopupMenuLevelBoostActive = false

        view.lockedAspectRatio = currentAspectRatio
        syncMinimumWindowedBounds(for: sourceRect, displays: displays)
        applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: nativeFS)
        applyWindowedInteractivity()
        applyOcclusionAndShadowState()
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
        isPopupMenuLevelBoostActive = false
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
        applyOcclusionAndShadowState()
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
        isPopupMenuLevelBoostActive = false

        overlayView?.hideCursorSprite()
        detachAllChildWindows()
        panel?.orderOut(nil)
        restoreActivationPolicyIfNeeded()
        PipelineLog.shared.info(.render, "Overlay closed.")
    }

    /// Temporarily boosts or restores `OverlayPanel.level` relative to `kCGPopUpMenuWindowLevelKey` (101)
    /// when an in-window right-click `NSMenu` opens/closes, eliminating duplicate scaled + unscaled menus.
    public func setPopupMenuLevelBoost(_ active: Bool) {
        guard isSessionOpen, !isSuspended else {
            isPopupMenuLevelBoostActive = false
            return
        }
        guard isPopupMenuLevelBoostActive != active else { return }
        isPopupMenuLevelBoostActive = active
        applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: isCoveringNativeFullscreenSpace)
    }

    // MARK: - Live Updates (Display Move, Source Resize, Mode Toggle, HDR/Format)

    /// Updates overlay placement when the source window moves, resizes, or switches displays.
    ///
    /// - Parameters:
    ///   - newSourceCGRect: Updated source window frame in CoreGraphics global coordinates (Y-down).
    ///   - windowID: Optional source window ID used for native Full-Screen Space detection.
    ///   - repositionWindowedOverlay: When `true` (default), repositions/expands a windowed overlay
    ///     to track external source window moves/resizes so two separate windows never appear.
    ///     Pass `false` when recording a self-initiated AX reposition underneath the overlay.
    public func updateSourceWindowGeometry(
        _ newSourceCGRect: CGRect,
        windowID: CGWindowID? = nil,
        repositionWindowedOverlay: Bool = true
    ) {
        guard isSessionOpen, let panel else { return }
        let previousSourceCGRect = currentSourceCGRect
        currentSourceCGRect = newSourceCGRect.standardized
        if currentSourceCGRect.height > 0 {
            currentAspectRatio = max(0.1, currentSourceCGRect.width / currentSourceCGRect.height)
            overlayView?.lockedAspectRatio = currentAspectRatio
        }

        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        syncMinimumWindowedBounds(for: currentSourceCGRect, displays: displays)

        if currentPresentationMode.isFullscreen {
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

            let targetDisplay = ScreenGeometry.bestDisplay(forCocoaRect: targetCocoaRect, in: displays)
            let frameChanged = abs(panel.frame.origin.x - targetCocoaRect.origin.x) >= 0.5
                || abs(panel.frame.origin.y - targetCocoaRect.origin.y) >= 0.5
                || abs(panel.frame.size.width - targetCocoaRect.size.width) >= 0.5
                || abs(panel.frame.size.height - targetCocoaRect.size.height) >= 0.5
            let displayChanged = targetDisplay != nil && targetDisplay?.id != activeDisplayID
            let nativeFSChanged = (nativeFS != isCoveringNativeFullscreenSpace)

            if frameChanged || displayChanged || nativeFSChanged {
                panel.setFrame(targetCocoaRect, display: isRevealed && !isSuspended, animate: false)
                applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: nativeFS)
                applyOcclusionAndShadowState()
                refreshScreenCapabilitiesAndColorSpace()
                emitCurrentMetrics()
            }
            return
        }

        // Windowed mode: keep the overlay locked over the source window on external move/resize so
        // the source window never drifts out from behind the scaled overlay, while staying strictly
        // inside the host screen's menu-bar-safe visible frame.
        guard repositionWindowedOverlay else { return }

        let visibleCocoa = hostVisibleCocoaFrame(for: currentSourceCGRect, displays: displays)
        let sizeChanged = abs(previousSourceCGRect.width - currentSourceCGRect.width) >= 1.0
            || abs(previousSourceCGRect.height - currentSourceCGRect.height) >= 1.0
        let targetCocoaRect: CGRect
        if sizeChanged {
            targetCocoaRect = Self.computeProportionalResizedWindowedCocoaFrame(
                previousSourceCGRect: previousSourceCGRect,
                newSourceCGRect: currentSourceCGRect,
                currentOverlayCocoaFrame: panel.frame,
                displays: displays,
                hostVisibleCocoaFrame: visibleCocoa
            )
            lastWindowedWidth = targetCocoaRect.width
        } else {
            let hostDisplay = ScreenGeometry.bestDisplay(forCGRect: currentSourceCGRect, in: displays)
                ?? ScreenGeometry.primaryDisplay(in: displays)
            let screenCocoa = Self.resolvedWindowedHostCocoaFrame(
                hostDisplay: hostDisplay,
                hostVisibleCocoaFrame: visibleCocoa
            )
            let sourceCocoa = ScreenGeometry.cgToCocoa(rect: currentSourceCGRect, displays: displays).standardized
            let currentSize = panel.frame.size
            let width = min(screenCocoa.width, max(currentSize.width, ceil(sourceCocoa.width)))
            let height = min(screenCocoa.height, max(currentSize.height, ceil(sourceCocoa.height)))
            let centered = CGRect(
                x: (sourceCocoa.midX - width * 0.5).rounded(),
                y: (sourceCocoa.midY - height * 0.5).rounded(),
                width: width.rounded(),
                height: height.rounded()
            )
            targetCocoaRect = Self.ensureOverlayCoversSource(
                overlayCocoaRect: centered,
                sourceCocoaRect: sourceCocoa,
                hostScreenCocoa: screenCocoa
            )
        }

        let targetDisplay = ScreenGeometry.bestDisplay(forCocoaRect: targetCocoaRect, in: displays)
        let frameChanged = abs(panel.frame.origin.x - targetCocoaRect.origin.x) >= 0.5
            || abs(panel.frame.origin.y - targetCocoaRect.origin.y) >= 0.5
            || abs(panel.frame.size.width - targetCocoaRect.size.width) >= 0.5
            || abs(panel.frame.size.height - targetCocoaRect.size.height) >= 0.5
        let displayChanged = targetDisplay != nil && targetDisplay?.id != activeDisplayID

        if frameChanged || displayChanged {
            panel.setFrame(targetCocoaRect, display: isRevealed && !isSuspended, animate: false)
            applyOcclusionAndShadowState()
            refreshScreenCapabilitiesAndColorSpace()
            let metrics = currentDrawableMetrics()
            onDrawableMetricsChanged?(metrics)
        }
    }

    /// Programmatically adjusts the windowed overlay frame (for example, to remain flush over a
    /// menu-bar-clamped or immovable source window), clamping strictly below the macOS Menu Bar
    /// and synchronizing Metal drawable metrics.
    public func setWindowedOverlayCocoaFrame(_ newCocoaFrame: CGRect) {
        guard isSessionOpen, currentPresentationMode.isWindowed, let panel else { return }
        var clampedFrame = newCocoaFrame.standardized
        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let hostDisplay = ScreenGeometry.bestDisplay(forCocoaRect: clampedFrame, in: displays)
            ?? ScreenGeometry.primaryDisplay(in: displays)
        if let visible = hostDisplay.flatMap({ WindowEnumerator.nsScreen(for: $0.id)?.visibleFrame }) ?? NSScreen.main?.visibleFrame,
           clampedFrame.maxY > visible.maxY
        {
            if clampedFrame.height <= visible.height {
                clampedFrame.origin.y = (visible.maxY - clampedFrame.height).rounded()
            } else {
                clampedFrame.size.height = visible.height.rounded()
                clampedFrame.origin.y = visible.minY.rounded()
            }
        }
        let frameChanged = abs(panel.frame.origin.x - clampedFrame.origin.x) >= 0.5
            || abs(panel.frame.origin.y - clampedFrame.origin.y) >= 0.5
            || abs(panel.frame.size.width - clampedFrame.size.width) >= 0.5
            || abs(panel.frame.size.height - clampedFrame.size.height) >= 0.5
        guard frameChanged else { return }
        panel.setFrame(clampedFrame, display: isRevealed && !isSuspended, animate: false)
        lastWindowedWidth = clampedFrame.width
        refreshScreenCapabilitiesAndColorSpace()
        emitCurrentMetrics()
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
        syncMinimumWindowedBounds(for: currentSourceCGRect, displays: displays)
        applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: nativeFS)
        applyWindowedInteractivity()
        applyOcclusionAndShadowState()
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

        // Prefer the hosting display's exact backingScaleFactor (avoiding stale `NSScreen.main` DPI
        // when the panel is off-screen before first-frame reveal or transitioning across mixed-DPI displays!).
        let panelScreenMatchesBest: Bool = {
            guard let panel, panel.isVisible, let screen = panel.screen, let best = bestDisplay else {
                return false
            }
            return WindowEnumerator.screenDisplayID(for: screen) == best.id
        }()
        let resolvedScale: Double
        if panelScreenMatchesBest, let panelScale = panel?.backingScaleFactor, panelScale >= 1.0 {
            resolvedScale = Double(panelScale)
        } else if let displayScale = bestDisplay?.backingScaleFactor, displayScale >= 1.0 {
            resolvedScale = displayScale
        } else {
            resolvedScale = max(1.0, Double(panel?.backingScaleFactor ?? 2.0))
        }
        let scale = max(1.0, resolvedScale)
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

    /// Pure, unit-testable multi-monitor overlay frame solver returning global AppKit (Y-up) coordinates.
    /// - In `.fullscreen` mode when `respectNotchSafeArea == true` (default for non-VRR sessions),
    ///   excludes any physical camera notch strip (`DisplayDescriptor.safeAreaTopInset`) on single
    ///   notched MacBook displays so scaled content is NEVER clipped behind the notch or overlapping
    ///   the top Menu Bar, while filling non-notched displays 100% edge-to-edge.
    /// - In `.windowed` mode when `hostVisibleCocoaFrame` is supplied, clamps the windowed overlay
    ///   strictly inside the menu-bar-safe visible frame (`frame.maxY <= hostVisibleCocoaFrame.maxY`).
    public static func computeOverlayCocoaFrame(
        sourceCGRect: CGRect,
        presentationMode: PresentationMode,
        multiMonitorMode: MultiMonitorMode,
        displays: [DisplayDescriptor],
        aspectRatio: CGFloat,
        lastWindowedWidth: CGFloat? = nil,
        applyAntiOcclusion: Bool = true,
        hostVisibleCocoaFrame: CGRect? = nil,
        respectNotchSafeArea: Bool = true
    ) -> CGRect {
        switch presentationMode {
        case .fullscreen:
            let fullDisplayRect = ScreenGeometry.targetCocoaFrame(
                forCGRect: sourceCGRect,
                mode: multiMonitorMode,
                in: displays
            )
            var rect = (respectNotchSafeArea
                ? ScreenGeometry.targetFullscreenSafeCocoaFrame(
                    forCGRect: sourceCGRect,
                    mode: multiMonitorMode,
                    in: displays
                )
                : fullDisplayRect) ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 720)

            // On notched MacBooks where `respectNotchSafeArea` already leaves the top notch band
            // uncovered (plus `panel.alphaValue = 0.999` prevents per-window occlusion), skip the
            // extra 1pt bottom shrink so maximized 3024x1898 windows match the overlay 1:1 without
            // triggering a wasteful 2px fractional Auto-Bicubic resample pass every frame!
            let alreadyExcludedNotchBand = respectNotchSafeArea
                && fullDisplayRect.map({ rect.height < $0.height - 0.5 }) == true
            if applyAntiOcclusion && !alreadyExcludedNotchBand {
                rect = ScreenGeometry.antiOcclusionInset(cocoaRect: rect, insetPoints: 1.0)
            }
            return rect

        case .windowed(let initialScale, let explicitWidth):
            let hostDisplay = ScreenGeometry.bestDisplay(forCGRect: sourceCGRect, in: displays)
                ?? ScreenGeometry.primaryDisplay(in: displays)
            let screenCocoa = resolvedWindowedHostCocoaFrame(
                hostDisplay: hostDisplay,
                hostVisibleCocoaFrame: hostVisibleCocoaFrame
            )
            let sourceCocoa = ScreenGeometry.cgToCocoa(rect: sourceCGRect, displays: displays).standardized
            let safeAspect = max(0.1, aspectRatio)

            // Always guarantee the windowed overlay is at least as large as `sourceCocoa`
            // (clamped only to `screenCocoa.size`) so stale `lastWindowedWidth` or arbitrary
            // 0.95/0.75 screen height caps can NEVER shrink the overlay smaller than the source window!
            let minCoverW = min(screenCocoa.width, max(320.0, ceil(sourceCocoa.width)))
            let minCoverH = min(screenCocoa.height, max(180.0, ceil(sourceCocoa.height)))

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
                let maxFitW = min(threeQuarterScreenW, threeQuarterScreenH * safeAspect)
                let minAutoW = sourceCocoa.width * (4.0 / 3.0)
                targetWidth = max(320.0, min(screenCocoa.width, max(maxFitW, minAutoW)))
            }

            let maxAspectFitW = min(screenCocoa.width, screenCocoa.height * safeAspect)
            let minAspectCoverW = min(maxAspectFitW, max(minCoverW, minCoverH * safeAspect))
            var finalW = min(maxAspectFitW, max(minAspectCoverW, targetWidth))
            var finalH = finalW / safeAspect

            // Enforce full coverage on both axes after rounding (and if aspectRatio slightly differs).
            finalW = min(screenCocoa.width, max(finalW.rounded(), minCoverW))
            finalH = min(screenCocoa.height, max(finalH.rounded(), minCoverH))

            // Center over source window, then enforce full containment inside `screenCocoa`.
            let centered = CGRect(
                x: (sourceCocoa.midX - finalW * 0.5).rounded(),
                y: (sourceCocoa.midY - finalH * 0.5).rounded(),
                width: finalW,
                height: finalH
            )
            // Windowed mode prevents WindowServer occlusion via `panel.alphaValue = antiOcclusionAlphaValue`
            // (0.999) rather than a 1-pt bottom inset, so the bottom edge of `sourceCocoa` never peeks out.
            return ensureOverlayCoversSource(
                overlayCocoaRect: centered,
                sourceCocoaRect: sourceCocoa,
                hostScreenCocoa: screenCocoa
            )
        }
    }

    /// Computes the proportionally scaled Windowed overlay Cocoa frame when the underlying source
    /// window is resized externally (inward OR outward) while locked in Windowed mode.
    /// Preserves the live scale ratio (`overlayWidth / previousSourceWidth >= 1.0`) so dragging the
    /// source window border inward smoothly shrinks the overlay instead of sticking at stale `lastWindowedWidth`.
    public static func computeProportionalResizedWindowedCocoaFrame(
        previousSourceCGRect: CGRect,
        newSourceCGRect: CGRect,
        currentOverlayCocoaFrame: CGRect,
        displays: [DisplayDescriptor],
        hostVisibleCocoaFrame: CGRect? = nil
    ) -> CGRect {
        let prevSource = previousSourceCGRect.standardized
        let newSource = newSourceCGRect.standardized
        let hostDisplay = ScreenGeometry.bestDisplay(forCGRect: newSource, in: displays)
            ?? ScreenGeometry.primaryDisplay(in: displays)
        let screenCocoa = resolvedWindowedHostCocoaFrame(
            hostDisplay: hostDisplay,
            hostVisibleCocoaFrame: hostVisibleCocoaFrame
        )
        let sourceCocoa = ScreenGeometry.cgToCocoa(rect: newSource, displays: displays).standardized

        let safeAspect: CGFloat = newSource.height > 0
            ? max(0.1, newSource.width / newSource.height)
            : max(0.1, currentOverlayCocoaFrame.width / max(1.0, currentOverlayCocoaFrame.height))

        let liveRatio: CGFloat
        if prevSource.width >= 1.0 && currentOverlayCocoaFrame.width >= 1.0 {
            liveRatio = max(1.0, currentOverlayCocoaFrame.width / prevSource.width)
        } else {
            liveRatio = 1.0
        }

        let desiredW = sourceCocoa.width * liveRatio
        let minCoverW = min(screenCocoa.width, max(absoluteMinimumWindowedWidth, ceil(sourceCocoa.width)))
        let minCoverH = min(screenCocoa.height, max(absoluteMinimumWindowedHeight, ceil(sourceCocoa.height)))
        let maxAspectFitW = min(screenCocoa.width, screenCocoa.height * safeAspect)
        let minAspectCoverW = min(maxAspectFitW, max(minCoverW, minCoverH * safeAspect))

        var finalW = min(maxAspectFitW, max(minAspectCoverW, desiredW))
        var finalH = finalW / safeAspect
        finalW = min(screenCocoa.width, max(finalW.rounded(), minCoverW))
        finalH = min(screenCocoa.height, max(finalH.rounded(), minCoverH))

        let centered = CGRect(
            x: (sourceCocoa.midX - finalW * 0.5).rounded(),
            y: (sourceCocoa.midY - finalH * 0.5).rounded(),
            width: finalW,
            height: finalH
        )
        return ensureOverlayCoversSource(
            overlayCocoaRect: centered,
            sourceCocoaRect: sourceCocoa,
            hostScreenCocoa: screenCocoa
        )
    }

    /// Pure, unit-testable classifier deciding whether `OverlayPanel` should temporarily boost above
    /// `kCGPopUpMenuWindowLevelKey` (101) to hide an unscaled duplicate `NSMenu` already being rendered
    /// scaled by `SCStream`, while leaving top macOS Menu Bar dropdowns visible above the overlay.
    public nonisolated static func evaluatePopupMenuLevelBoost(
        popupWindows: [PopupMenuWindowSnapshot],
        targetPID: Int32,
        sourceCGRect: CGRect,
        displays: [DisplayDescriptor],
        pointerCGPosition: CGPoint? = nil,
        menuBarHeightByDisplayID: [CGDirectDisplayID: CGFloat] = [:],
        wasBoosted: Bool = false,
        wasMenuBarDropdownActive: Bool = false
    ) -> PopupMenuLevelEvaluation {
        let popUpLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let targetPopups = popupWindows.filter {
            $0.pid == targetPID
                && $0.layer == popUpLayer
                && $0.alpha > 0.01
                && $0.bounds.width >= 20
                && $0.bounds.height >= 20
        }
        guard !targetPopups.isEmpty else {
            return PopupMenuLevelEvaluation(
                shouldBoostAbovePopupMenus: false,
                isMenuBarDropdownActive: false
            )
        }
        if wasMenuBarDropdownActive {
            return PopupMenuLevelEvaluation(
                shouldBoostAbovePopupMenus: false,
                isMenuBarDropdownActive: true
            )
        }
        if wasBoosted {
            return PopupMenuLevelEvaluation(
                shouldBoostAbovePopupMenus: true,
                isMenuBarDropdownActive: false
            )
        }

        let expandedSource = sourceCGRect.standardized.insetBy(dx: -4, dy: -4)
        var anyIntersectsSource = false

        for popup in targetPopups {
            let hostDisplay = ScreenGeometry.bestDisplay(forCGRect: popup.bounds, in: displays)
                ?? ScreenGeometry.primaryDisplay(in: displays)
            let menuBarHeight: CGFloat
            if let display = hostDisplay, let known = menuBarHeightByDisplayID[display.id], known > 0 {
                menuBarHeight = known
            } else if let display = hostDisplay, display.safeAreaTopInset > 0.5 {
                menuBarHeight = CGFloat(display.safeAreaTopInset)
            } else {
                // Standard macOS menu bar thickness on non-notched displays (covers 24-30pt & slight accessibility bump).
                menuBarHeight = 30.0
            }

            let isAnchoredToMenuBar = hostDisplay.map {
                popup.bounds.minY <= $0.cgBounds.minY + menuBarHeight + 8.0
            } ?? false
            let pointerNearMenuBar = pointerCGPosition.flatMap { pt in
                hostDisplay.map { pt.y <= $0.cgBounds.minY + menuBarHeight + 6.0 }
            } ?? false
            let intersectsSource = !expandedSource.isEmpty && popup.bounds.intersects(expandedSource)

            if isAnchoredToMenuBar && (pointerNearMenuBar || !intersectsSource) {
                return PopupMenuLevelEvaluation(
                    shouldBoostAbovePopupMenus: false,
                    isMenuBarDropdownActive: true
                )
            }
            if intersectsSource {
                anyIntersectsSource = true
            }
        }

        return PopupMenuLevelEvaluation(
            shouldBoostAbovePopupMenus: anyIntersectsSource,
            isMenuBarDropdownActive: false
        )
    }

    /// Returns `true` when `overlayRect` completely covers `sourceRect` (within `tolerance` points).
    public static func overlayCoversSource(
        overlayRect: CGRect,
        sourceRect: CGRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        let ov = overlayRect.standardized
        let src = sourceRect.standardized
        guard !ov.isEmpty, !src.isEmpty else { return false }
        return ov.minX <= src.minX + tolerance
            && ov.minY <= src.minY + tolerance
            && ov.maxX >= src.maxX - tolerance
            && ov.maxY >= src.maxY - tolerance
    }

    /// Adjusts `overlayCocoaRect` minimally (shifting and, if necessary, expanding within `hostScreenCocoa`)
    /// so it stays strictly inside `hostScreenCocoa` and completely covers `sourceCocoaRect` whenever
    /// `sourceCocoaRect` fits inside `hostScreenCocoa`.
    public static func ensureOverlayCoversSource(
        overlayCocoaRect: CGRect,
        sourceCocoaRect: CGRect,
        hostScreenCocoa: CGRect
    ) -> CGRect {
        let screen = hostScreenCocoa.standardized
        let src = sourceCocoaRect.standardized
        var w = min(screen.width, max(overlayCocoaRect.standardized.width.rounded(), min(screen.width, ceil(src.width))))
        var h = min(screen.height, max(overlayCocoaRect.standardized.height.rounded(), min(screen.height, ceil(src.height))))

        let maxOriginX = max(screen.minX, screen.maxX - w)
        let maxOriginY = max(screen.minY, screen.maxY - h)
        var originX = min(max(overlayCocoaRect.standardized.origin.x.rounded(), screen.minX), maxOriginX)
        var originY = min(max(overlayCocoaRect.standardized.origin.y.rounded(), screen.minY), maxOriginY)

        if src.width > 0 && src.minX >= screen.minX - 0.5 && src.maxX <= screen.maxX + 0.5 {
            let containMinX = max(screen.minX, ceil(src.maxX - w))
            let containMaxX = min(maxOriginX, floor(src.minX))
            if containMinX <= containMaxX {
                originX = min(max(originX, containMinX), containMaxX)
            } else {
                originX = max(screen.minX, floor(src.minX))
                w = min(screen.maxX - originX, max(w, ceil(src.maxX - originX)))
            }
        }

        if src.height > 0 && src.minY >= screen.minY - 0.5 && src.maxY <= screen.maxY + 0.5 {
            let containMinY = max(screen.minY, ceil(src.maxY - h))
            let containMaxY = min(maxOriginY, floor(src.minY))
            if containMinY <= containMaxY {
                originY = min(max(originY, containMinY), containMaxY)
            } else {
                originY = max(screen.minY, floor(src.minY))
                h = min(screen.maxY - originY, max(h, ceil(src.maxY - originY)))
            }
        }

        return CGRect(x: originX, y: originY, width: w, height: h)
    }

    /// Computes the CoreGraphics (Y-down) origin to reposition an underlying source window via AX
    /// so it stays centered directly underneath `overlayCGRect` without peeking out, while staying
    /// inside the host display's visible/reachable frame (respecting macOS menu bar clamping and
    /// multi-monitor negative-CG-Y displays).
    public static func computeHiddenSourceWindowCGOrigin(
        sourceSize: CGSize,
        overlayCGRect: CGRect,
        hostDisplayCGBounds: CGRect,
        hostVisibleCGBounds: CGRect? = nil
    ) -> CGPoint {
        let ov = overlayCGRect.standardized
        let full = hostDisplayCGBounds.standardized
        let visible = (hostVisibleCGBounds ?? full).standardized
        let srcW = max(1.0, sourceSize.width)
        let srcH = max(1.0, sourceSize.height)

        func solveAxis(
            ideal: CGFloat,
            ovMin: CGFloat,
            ovMax: CGFloat,
            visMin: CGFloat,
            visMax: CGFloat,
            fullMin: CGFloat,
            fullMax: CGFloat
        ) -> CGFloat {
            let safeFullMax = max(fullMin, fullMax)
            let safeVisMax = max(visMin, visMax)
            // 1. Prefer keeping source strictly inside BOTH overlay and visible frame (below menu bar, above Dock).
            if ovMin <= ovMax {
                let loVis = max(ovMin, visMin)
                let hiVis = min(ovMax, safeVisMax)
                if loVis <= hiVis {
                    return min(max(ideal, loVis), hiVis)
                }
                // 2. Fallback: keep strictly inside overlay and below menu bar (allowing Dock overlap).
                let loFull = max(ovMin, visMin)
                let hiFull = min(ovMax, safeFullMax)
                if loFull <= hiFull {
                    return min(max(ideal, loFull), hiFull)
                }
                // 3. Fallback: keep strictly inside overlay and full display bounds.
                let loAny = max(ovMin, fullMin)
                let hiAny = min(ovMax, safeFullMax)
                if loAny <= hiAny {
                    return min(max(ideal, loAny), hiAny)
                }
            }
            // 4. Overlay is smaller than source or above menu bar: stay safely inside visible/display bounds.
            return min(max(ideal, visMin), safeVisMax)
        }

        let idealX = ov.midX - srcW * 0.5
        let idealY = ov.midY - srcH * 0.5

        let solvedX = solveAxis(
            ideal: idealX,
            ovMin: ov.minX,
            ovMax: ov.maxX - srcW,
            visMin: visible.minX,
            visMax: visible.maxX - srcW,
            fullMin: full.minX,
            fullMax: full.maxX - srcW
        )
        let solvedY = solveAxis(
            ideal: idealY,
            ovMin: ov.minY,
            ovMax: ov.maxY - srcH,
            visMin: visible.minY,
            visMax: visible.maxY - srcH,
            fullMin: full.minY,
            fullMax: full.maxY - srcH
        )

        var x = solvedX.rounded()
        var y = solvedY.rounded()
        // Prevent 0.5pt rounding from stepping outside overlay when interior room exists.
        if ov.minX <= ov.maxX - srcW {
            x = min(max(x, ceil(ov.minX)), floor(ov.maxX - srcW))
        }
        if ov.minY <= ov.maxY - srcH {
            let minYAllowed = max(ceil(ov.minY), ceil(visible.minY))
            let maxYAllowed = floor(ov.maxY - srcH)
            if minYAllowed <= maxYAllowed {
                y = min(max(y, minYAllowed), maxYAllowed)
            }
        }
        return CGPoint(x: x, y: y)
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

    private static func resolvedWindowedHostCocoaFrame(
        hostDisplay: DisplayDescriptor?,
        hostVisibleCocoaFrame: CGRect?
    ) -> CGRect {
        let fallback = hostDisplay?.cocoaFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        guard let visible = hostVisibleCocoaFrame?.standardized, !visible.isEmpty else {
            return fallback
        }
        if let hostFull = hostDisplay?.cocoaFrame.standardized, !hostFull.isEmpty {
            let clipped = hostFull.intersection(visible)
            if !clipped.isNull && !clipped.isEmpty {
                return clipped
            }
        }
        return visible
    }

    private func hostVisibleCocoaFrame(
        for sourceCGRect: CGRect,
        displays: [DisplayDescriptor]
    ) -> CGRect? {
        guard let hostDisplay = ScreenGeometry.bestDisplay(forCGRect: sourceCGRect, in: displays)
            ?? ScreenGeometry.primaryDisplay(in: displays)
        else {
            return NSScreen.main?.visibleFrame
        }
        return WindowEnumerator.nsScreen(for: hostDisplay.id)?.visibleFrame
    }

    private func computeOverlayCocoaFrame(
        sourceCGRect: CGRect,
        presentationMode: PresentationMode,
        multiMonitorMode: MultiMonitorMode,
        displays: [DisplayDescriptor],
        aspectRatio: CGFloat,
        applyAntiOcclusion: Bool
    ) -> CGRect {
        let visibleCocoa = presentationMode.isWindowed
            ? hostVisibleCocoaFrame(for: sourceCGRect, displays: displays)
            : nil
        return Self.computeOverlayCocoaFrame(
            sourceCGRect: sourceCGRect,
            presentationMode: presentationMode,
            multiMonitorMode: multiMonitorMode,
            displays: displays,
            aspectRatio: aspectRatio,
            lastWindowedWidth: lastWindowedWidth,
            applyAntiOcclusion: applyAntiOcclusion,
            hostVisibleCocoaFrame: visibleCocoa,
            respectNotchSafeArea: !isEffectiveVRRDirectScanout()
        )
    }

    private func applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: Bool) {
        guard let panel else { return }
        let effectiveNativeFS = nativeFullscreenSpace && currentPresentationMode.isFullscreen
        isCoveringNativeFullscreenSpace = effectiveNativeFS

        let app = NSApplication.shared
        let previousLevel = panel.level
        let targetLevel: NSWindow.Level

        if isPopupMenuLevelBoostActive && !isEffectiveVRRDirectScanout() {
            targetLevel = Self.popupMenuBoostOverlayLevel
        } else if isEffectiveVRRDirectScanout() {
            targetLevel = Self.vrrFullscreenOverlayLevel
        } else if effectiveNativeFS {
            targetLevel = Self.nativeFullscreenOverlayLevel
        } else if currentPresentationMode.isFullscreen {
            targetLevel = Self.fullscreenOverlayLevel
        } else {
            targetLevel = Self.windowedOverlayLevel
        }

        if effectiveNativeFS {
            if savedActivationPolicy == nil {
                savedActivationPolicy = app.activationPolicy()
            }
            if app.activationPolicy() != .accessory {
                app.setActivationPolicy(.accessory)
            }
        } else {
            restoreActivationPolicyIfNeeded()
        }

        panel.level = targetLevel
        if targetLevel != previousLevel {
            onOverlayLevelChanged?(targetLevel)
        }
    }

    private func restoreActivationPolicyIfNeeded() {
        guard let original = savedActivationPolicy else { return }
        savedActivationPolicy = nil
        let app = NSApplication.shared
        if app.activationPolicy() != original {
            app.setActivationPolicy(original)
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

    private func applyOcclusionAndShadowState() {
        guard let panel else { return }
        let useAntiOcclusionAlpha = antiOcclusionEnabled && !isEffectiveVRRDirectScanout()
        let isWindowed = currentPresentationMode.isWindowed

        panel.isOpaque = !isWindowed
        panel.backgroundColor = isWindowed ? .clear : .black
        panel.alphaValue = useAntiOcclusionAlpha ? Self.antiOcclusionAlphaValue : 1.0
        panel.hasShadow = isWindowed

        overlayView?.setRoundedCornerRadius(isWindowed ? Self.windowedCornerRadius : 0.0)
        if isWindowed {
            panel.invalidateShadow()
        }
    }

    private func syncMinimumWindowedBounds(for sourceCGRect: CGRect, displays: [DisplayDescriptor]) {
        guard let view = overlayView else { return }
        if allowInwardResizeBelowSource {
            view.minimumWindowedWidth = Self.absoluteMinimumWindowedWidth
            view.minimumWindowedHeight = Self.absoluteMinimumWindowedHeight
            return
        }
        let normalized = sourceCGRect.standardized
        let hostDisplay = ScreenGeometry.bestDisplay(forCGRect: normalized, in: displays)
            ?? ScreenGeometry.primaryDisplay(in: displays)
        let visibleFrame = hostDisplay.flatMap { WindowEnumerator.nsScreen(for: $0.id)?.visibleFrame }
        let maxW = visibleFrame?.width ?? hostDisplay?.cocoaFrame.width ?? max(Self.absoluteMinimumWindowedWidth, normalized.width)
        let maxH = visibleFrame?.height ?? hostDisplay?.cocoaFrame.height ?? max(Self.absoluteMinimumWindowedHeight, normalized.height)
        view.minimumWindowedWidth = min(maxW, max(Self.absoluteMinimumWindowedWidth, ceil(normalized.width)))
        view.minimumWindowedHeight = min(maxH, max(Self.absoluteMinimumWindowedHeight, ceil(normalized.height)))
    }

    private func applyVRRModeState() {
        guard let view = overlayView else { return }
        let vrrActive = isEffectiveVRRDirectScanout()
        applyWindowLevelAndActivationPolicy(nativeFullscreenSpace: isCoveringNativeFullscreenSpace)
        applyOcclusionAndShadowState()
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
        let hostScale = hostDisplay?.backingScaleFactor
            ?? (hostScreen.map { Double($0.backingScaleFactor) })
        view.syncDrawableGeometry(preferredBackingScale: hostScale)
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
