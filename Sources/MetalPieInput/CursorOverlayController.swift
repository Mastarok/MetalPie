import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import MetalPieCore
import QuartzCore
import os

// MARK: - Presentation Mode & Render Snapshots

/// Presentation output mode for the scaled cursor sprite.
public enum CursorPresentationMode: String, Codable, Sendable, CaseIterable {
    /// Non-VRR mode: zero-lag dedicated non-activating `CALayer` cursor sprite overlay panel.
    case overlayLayer
    /// VRR Direct-Scanout mode: zero WindowServer sub-windows; publishes `CursorRenderSnapshot`
    /// into a tiny-lock holder for direct compositing in the Metal present pass.
    case externalCompositor
}

/// Immutable, thread-safe snapshot of the active system cursor (`NSCursor.currentSystem`).
public struct CursorImageSnapshot: @unchecked Sendable {
    public let cgImage: CGImage
    public let pointSize: CGSize
    /// Hotspot measured from top-left of the cursor image (AppKit `NSCursor.hotSpot` convention).
    public let hotSpot: CGPoint
    public let backingScaleFactor: Double
    /// Monotonically incremented only when the cursor shape/bitmap changes (enables GPU texture caching).
    public let generation: UInt64

    public init(
        cgImage: CGImage,
        pointSize: CGSize,
        hotSpot: CGPoint,
        backingScaleFactor: Double,
        generation: UInt64
    ) {
        self.cgImage = cgImage
        self.pointSize = pointSize
        self.hotSpot = hotSpot
        self.backingScaleFactor = max(1.0, backingScaleFactor)
        self.generation = generation
    }
}

/// Active cursor alignment & confinement operating mode reported by `CursorOverlayController`.
///
/// Allows `AppCoordinator` and UI views to distinguish 1:1 passthrough, fully aligned event-tap
/// confinement, and non-1:1 sessions waiting for macOS Accessibility trust so MetalPie NEVER
/// silently renders a misaligned cursor sprite or leaves users guessing why scaled clicks miss.
public enum CursorAlignmentMode: String, Hashable, Codable, Sendable, CaseIterable {
    /// Cursor controller is stopped.
    case inactive
    /// 1:1 identity passthrough — native OS cursor already matches pixel-for-pixel (no Accessibility needed).
    case identityPassthrough
    /// Non-1:1 scaled mode with active `CGEventTap` confining clicks strictly inside the target window
    /// and keeping the scaled visual cursor synchronized 1:1 with the physical click coordinate.
    case scaledConfinedEventTap
    /// Non-1:1 scaled mode WITHOUT Accessibility trust (or tap unavailable): macOS cannot confine or
    /// remap clicks into the scaled window, so MetalPie keeps the native OS cursor visible, hides the
    /// scaled sprite (never showing a misleading position), and surfaces an Accessibility prompt state.
    case accessibilityRequired
}

/// Complete lock-free/tiny-lock cursor state published for Metal VRR in-pass compositing and HUD consumers.
public struct CursorRenderSnapshot: Sendable {
    public var state: CursorOverlayState
    public var image: CursorImageSnapshot?
    public var spriteGeometry: CursorSpriteGeometry?
    public var interpolation: CursorInterpolation
    public var presentationMode: CursorPresentationMode
    public var alignmentMode: CursorAlignmentMode

    public init(
        state: CursorOverlayState = CursorOverlayState(),
        image: CursorImageSnapshot? = nil,
        spriteGeometry: CursorSpriteGeometry? = nil,
        interpolation: CursorInterpolation = .bilinear,
        presentationMode: CursorPresentationMode = .overlayLayer,
        alignmentMode: CursorAlignmentMode = .inactive
    ) {
        self.state = state
        self.image = image
        self.spriteGeometry = spriteGeometry
        self.interpolation = interpolation
        self.presentationMode = presentationMode
        self.alignmentMode = alignmentMode
    }
}

/// Pure, unit-testable input event delivered to the cursor event-tap state machine.
public struct CursorTapEventInput: Hashable, Sendable {
    public var type: CGEventType
    public var location: CGPoint
    public var deltaX: Double
    public var deltaY: Double
    public var timestamp: TimeInterval

    public init(
        type: CGEventType,
        location: CGPoint,
        deltaX: Double = 0,
        deltaY: Double = 0,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.type = type
        self.location = location
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.timestamp = timestamp
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(type.rawValue)
        hasher.combine(location.x)
        hasher.combine(location.y)
        hasher.combine(deltaX)
        hasher.combine(deltaY)
        hasher.combine(timestamp)
    }
}

/// Active pointer interaction regime tracked by `CursorEventTapProcessor`.
public enum CursorPointerInteractionMode: String, Hashable, Codable, Sendable, CaseIterable {
    /// Normal scaled tracking inside the target window (scaled sprite visible, OS cursor hidden).
    case scaled
    /// Pointer is hovering or dragging over MetalPie's own floating chrome (`OverlayToolbarPanel` / `ProfilerHUDPanel`).
    /// Events deliver at 1:1 native screen coordinates with the native OS cursor visible and scaled sprite hidden.
    case directChrome
    /// Windowed scaling mode (`isPresentationWindowed && !threeDGameMode`): pointer moved outside `overlayRect`.
    /// Native OS cursor is shown and all events pass 1:1 untouched to macOS Menu Bar, Dock, and other apps.
    case outsideWindowedOverlay
    /// Fullscreen scaling mode (`!isPresentationWindowed && !threeDGameMode`): pointer pushed up into the host
    /// display's top macOS Menu Bar strip (or is browsing an open Menu Bar dropdown).
    case menuBarPassthrough
    /// Explicitly unconfined mode (`confineCursor == false && !threeDGameMode`): pointer escaped outside `sourceRect`.
    case unconfinedOutsideSource
}

/// Deterministic decision produced by `CursorOverlayController`'s event-tap processor.
public struct CursorTapEventDecision: Hashable, Sendable {
    /// If non-nil, `CGEvent.location` is rewritten to this confined/compensated source CG point.
    public var rewrittenEventLocation: CGPoint?
    /// If non-nil, `CGWarpMouseCursorPosition` synchronizes the physical pointer to this CG point.
    public var warpTarget: CGPoint?
    /// Resulting effective source CG point (where the OS delivers clicks/scrolls).
    public var effectiveSourcePoint: CGPoint
    /// Resulting scaled visual cursor hotspot CG point on the overlay.
    public var scaledCGPosition: CGPoint
    /// True if the scaled cursor sprite should be visible after this event.
    public var isScaledSpriteVisible: Bool
    /// True if `PointerTracker` detected an active FPS/3D game mouse-grab.
    public var isMouseGrabbedByGame: Bool
    /// True if `confineCursor == false` and the physical pointer escaped outside `sourceRect`
    /// (requiring native OS cursor restoration while outside).
    public var isPointerOutsideUnconfinedSource: Bool
    /// True when a `.scrollWheel` or `*MouseDown` event arrived while the hidden physical cursor
    /// was drifted or outside `sourceRect`, requiring post-warp repost so macOS WindowServer
    /// re-runs hit-testing at `effectiveSourcePoint` (ensuring even scroll notch #1 / click #1 hits!).
    public var shouldRepostAfterWarp: Bool = false
    /// Resulting pointer interaction mode after processing this event.
    public var interactionMode: CursorPointerInteractionMode = .scaled

    /// True when this event is routed directly to MetalPie's own floating chrome at 1:1 native coordinates.
    public var isDirectChromeInteraction: Bool {
        interactionMode == .directChrome
    }

    /// True when the native OS cursor should be visible and events pass through at 1:1 native desktop coordinates.
    public var isNativePassthrough: Bool {
        interactionMode != .scaled
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rewrittenEventLocation?.x)
        hasher.combine(rewrittenEventLocation?.y)
        hasher.combine(warpTarget?.x)
        hasher.combine(warpTarget?.y)
        hasher.combine(effectiveSourcePoint.x)
        hasher.combine(effectiveSourcePoint.y)
        hasher.combine(scaledCGPosition.x)
        hasher.combine(scaledCGPosition.y)
        hasher.combine(isScaledSpriteVisible)
        hasher.combine(isMouseGrabbedByGame)
        hasher.combine(isPointerOutsideUnconfinedSource)
        hasher.combine(shouldRepostAfterWarp)
        hasher.combine(interactionMode)
    }
}

/// Tracks an in-flight programmatic `CGWarpMouseCursorPosition` so the event tap can distinguish
/// stale pre-warp queued events, synthetic post-warp echoes (both zero-delta and warp-delta),
/// and genuine user motion after the warp has landed.
public struct PendingWarp: Hashable, Sendable {
    public var from: CGPoint
    public var to: CGPoint
    public var timestamp: TimeInterval

    public init(from: CGPoint, to: CGPoint, timestamp: TimeInterval) {
        self.from = from
        self.to = to
        self.timestamp = timestamp
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(from.x)
        hasher.combine(from.y)
        hasher.combine(to.x)
        hasher.combine(to.y)
        hasher.combine(timestamp)
    }
}

/// Deterministic, unit-testable event-tap state machine powering `CursorOverlayController`.
///
/// Guarantees:
/// - **Exact 1:1 visual cursor speed (`adjustCursorSpeed == true`)**: measures true double-precision
///   desktop travel from `event.location` displacement (preserving macOS trackpad/mouse sub-pixel
///   acceleration and avoiding `kCGMouseEventDeltaX` integer quantization / high-DPI mismatch / warp
///   delta spikes), integrates in `Double` `virtualSourcePosition`, and warps ONLY on confinement-edge
///   recentering, click sync, or hover settle — NEVER hammering `CGWarpMouseCursorPosition` on every move!
/// - **Warp-echo & warp-delta immunity**: reconciles every incoming event against `pendingWarp` (`from`
///   vs `to`), neutralizing zero-delta echoes, warp-contaminated `mouseEventDeltaX` spikes, and stale
///   pre-warp queued Mach-port bursts.
/// - **Exact click & scroll alignment**: mouse button down/up, drags, and scroll-wheel events ALWAYS
///   use the exact synchronized `virtualSourcePosition` matching the rendered scaled cursor sprite.
/// - **Zero FPS grab false-positives**: interior motion requires zero self-warps, and rare recenter
///   warps are reconciled before touching `PointerTracker`.
/// - **Multi-monitor unconfined escape**: when `confineCursor == false`, moving outside `sourceRect`
///   restores the native OS cursor at 1:1 desktop speed until re-entering `sourceRect`.
public struct CursorEventTapProcessor: Sendable {
    public var pointerTracker = PointerTracker()
    public var virtualSourcePosition: CGPoint?
    public var lastPhysicalLocation: CGPoint?
    public var pendingWarp: PendingWarp?
    public var pressedButtonsMask: UInt32 = 0
    public var lastWarpedPoint: CGPoint?
    public var lastWarpedTimestamp: TimeInterval = 0
    public var lastMotionTimestamp: TimeInterval = 0
    public var isPointerOutsideUnconfinedSource: Bool = false

    // Session configuration preserved across `reset()`:
    /// Visible interactive MetalPie floating chrome rects (toolbar / Profiler HUD) in global CG (Y-down) coordinates.
    public var interactiveChromeRects: [CGRect] = []
    /// Whether the active scaling session is windowed (allows smooth outside-overlay escape to Menu Bar / Dock / desktop).
    public var isPresentationWindowed: Bool = false
    /// Cached per-display macOS Menu Bar heights (from `NSScreen.frame.maxY - visibleFrame.maxY`).
    public var displayMenuBarHeights: [CGDirectDisplayID: CGFloat] = [:]

    // Active interaction state cleared by `reset()`:
    public var interactionMode: CursorPointerInteractionMode = .scaled
    public var activeChromeDrag: Bool = false
    public var activeWindowBorderDrag: Bool = false
    public var lastBorderDragSyncTimestamp: TimeInterval = 0
    public var topEdgeUpwardOverflow: CGFloat = 0
    public var menuBarDropdownActive: Bool = false
    public var menuBarDropdownDismissPendingOnUp: Bool = false

    public init() {}

    public mutating func reset(
        initialSourcePosition: CGPoint? = nil,
        physicalLocation: CGPoint? = nil
    ) {
        pointerTracker.reset()
        virtualSourcePosition = initialSourcePosition
        lastPhysicalLocation = physicalLocation ?? initialSourcePosition
        pendingWarp = nil
        pressedButtonsMask = 0
        lastWarpedPoint = nil
        lastWarpedTimestamp = 0
        lastMotionTimestamp = 0
        isPointerOutsideUnconfinedSource = false
        interactionMode = .scaled
        activeChromeDrag = false
        activeWindowBorderDrag = false
        lastBorderDragSyncTimestamp = 0
        topEdgeUpwardOverflow = 0
        menuBarDropdownActive = false
        menuBarDropdownDismissPendingOnUp = false
    }

    public mutating func recordExternalWarp(
        from origin: CGPoint? = nil,
        to point: CGPoint,
        timestamp: TimeInterval
    ) {
        let warpFrom = origin ?? lastPhysicalLocation ?? point
        lastWarpedPoint = point
        lastWarpedTimestamp = timestamp
        virtualSourcePosition = point
        lastPhysicalLocation = point
        if hypot(point.x - warpFrom.x, point.y - warpFrom.y) >= 0.5 {
            pendingWarp = PendingWarp(from: warpFrom, to: point, timestamp: timestamp)
        } else {
            pendingWarp = nil
        }
        pointerTracker.recordSelfWarp(to: point, rawIncoming: warpFrom)
    }

    /// Returns `true` if `cgPoint` lies inside any visible interactive MetalPie chrome rect. Zero heap allocations.
    public func isPointInInteractiveChrome(_ cgPoint: CGPoint) -> Bool {
        for rect in interactiveChromeRects {
            if rect.contains(cgPoint) {
                return true
            }
        }
        return false
    }

    /// Returns the host display's top macOS Menu Bar band in global CG (Y-down) coordinates.
    public func hostMenuBarRect(for mapping: PointerMapping) -> CGRect {
        let height: CGFloat
        if let displayID = mapping.hostDisplayID,
           let cached = displayMenuBarHeights[displayID],
           cached > 1.0
        {
            height = cached
        } else {
            height = PointerMapping.defaultMenuBarHeight
        }
        return mapping.menuBarRect(height: height)
    }

    /// Processes a single event-tap event. Returns `nil` ONLY when the event is a benign self-warp
    /// feedback echo (zero-delta OR warp-jump-delta `.mouseMoved` landing at our warp target).
    public mutating func process(
        input: CursorTapEventInput,
        mapping: PointerMapping,
        isHiddenForScreenshot: Bool = false,
        isIdleHidden: Bool = false
    ) -> CursorTapEventDecision? {
        guard mapping.isValid else { return nil }
        if mapping.isIdentity && !mapping.threeDGameMode {
            return nil
        }

        let type = input.type
        let incoming = input.location
        let deltaX = input.deltaX
        let deltaY = input.deltaY
        let now = input.timestamp

        let hadButtonsPressedBeforeEvent = (pressedButtonsMask != 0)

        // Update mouse button mask (pauses idle auto-hide & hover-settle sync while dragging).
        switch type {
        case .leftMouseDown: pressedButtonsMask |= (1 << 0)
        case .leftMouseUp: pressedButtonsMask &= ~(1 << 0)
        case .rightMouseDown: pressedButtonsMask |= (1 << 1)
        case .rightMouseUp: pressedButtonsMask &= ~(1 << 1)
        case .otherMouseDown: pressedButtonsMask |= (1 << 2)
        case .otherMouseUp: pressedButtonsMask &= ~(1 << 2)
        default: break
        }

        let isMotionEvent = (
            type == .mouseMoved ||
            type == .leftMouseDragged ||
            type == .rightMouseDragged ||
            type == .otherMouseDragged
        )
        let isButtonDownEvent = (
            type == .leftMouseDown ||
            type == .rightMouseDown ||
            type == .otherMouseDown
        )
        let isButtonUpEvent = (
            type == .leftMouseUp ||
            type == .rightMouseUp ||
            type == .otherMouseUp
        )
        let isButtonEvent = isButtonDownEvent || isButtonUpEvent
        let isScrollEvent = (type == .scrollWheel)

        let hasDelta = abs(deltaX) > 0.001 || abs(deltaY) > 0.001

        // Step 1: Reconcile against any in-flight programmatic warp (startup, bezel recenter, click/scroll sync).
        // CRITICAL: PendingWarp MUST ONLY absorb synthetic warp-induced `.mouseMoved` echoes —
        // NEVER drop or swallow `.scrollWheel`, button, or drag events!
        enum WarpResolution {
            case none
            case pureEcho
            case preWarpQueued(origin: CGPoint)
            case postWarpLanded(origin: CGPoint, deltaWasWarpContaminated: Bool)
        }

        var warpResolution: WarpResolution = .none
        if let warp = pendingWarp {
            if now - warp.timestamp >= 0.25 {
                pendingWarp = nil
            } else {
                let warpDX = Double(warp.to.x - warp.from.x)
                let warpDY = Double(warp.to.y - warp.from.y)
                let warpLen = hypot(warpDX, warpDY)

                let diffToX = Double(incoming.x - warp.to.x)
                let diffToY = Double(incoming.y - warp.to.y)
                let distTo = hypot(diffToX, diffToY)

                let diffFromX = Double(incoming.x - warp.from.x)
                let diffFromY = Double(incoming.y - warp.from.y)
                let distFrom = hypot(diffFromX, diffFromY)

                let rawDeltaMag = hypot(deltaX, deltaY)
                let matchesWarpDelta = warpLen >= 1.0 &&
                    hypot(deltaX - warpDX, deltaY - warpDY) <= max(2.5, warpLen * 0.25)

                // Tighten zero-delta echo tolerance to <= 0.15pt so gentle sub-pixel trackpad glides
                // (e.g. 0.4–0.5pt with integer-truncated deltaX == 0) right after a warp are NEVER eaten!
                let isPureZeroDeltaEcho = distTo <= 0.15 && !hasDelta
                let isPureWarpDeltaEcho = distTo <= 1.25 && matchesWarpDelta

                if isPureZeroDeltaEcho || isPureWarpDeltaEcho {
                    // Pure synthetic echo of our own CGWarpMouseCursorPosition (zero-delta OR warp-delta).
                    pendingWarp = nil
                    lastPhysicalLocation = incoming
                    if type == .mouseMoved {
                        return nil
                    }
                    warpResolution = .pureEcho
                } else if isMotionEvent {
                    if warpLen < 1.0 {
                        pendingWarp = nil
                        warpResolution = .postWarpLanded(origin: warp.to, deltaWasWarpContaminated: false)
                    } else {
                        let errPostClean = hypot(diffToX - deltaX, diffToY - deltaY)
                        let errPreClean = hypot(diffFromX - deltaX, diffFromY - deltaY)
                        let cleanTolerance = max(2.0, rawDeltaMag * 0.35)

                        if errPostClean <= cleanTolerance && errPostClean < errPreClean {
                            pendingWarp = nil
                            warpResolution = .postWarpLanded(origin: warp.to, deltaWasWarpContaminated: false)
                        } else if distTo < distFrom {
                            // Physically originated from `warp.to` (even if macOS folded warpVec into deltaX/Y!).
                            pendingWarp = nil
                            let contaminated = matchesWarpDelta || (errPreClean < errPostClean)
                            warpResolution = .postWarpLanded(origin: warp.to, deltaWasWarpContaminated: contaminated)
                        } else {
                            // Stale motion event that was already queued in WindowServer before our warp landed.
                            pendingWarp?.from = incoming
                            warpResolution = .preWarpQueued(origin: warp.from)
                        }
                    }
                } else if distTo <= 1.25 {
                    // Non-motion event (button or scrollWheel) arrived already at the post-warp coordinate.
                    pendingWarp = nil
                    warpResolution = .pureEcho
                }
            }
        }

        // Secondary benign self-warp echo filter ONLY on exact zero-delta `.mouseMoved` — NEVER skip clicks/drags/scroll!
        if case .none = warpResolution,
           type == .mouseMoved && !hasDelta,
           let warped = lastWarpedPoint,
           now - lastWarpedTimestamp < 0.05,
           hypot(incoming.x - warped.x, incoming.y - warped.y) <= 0.15
        {
            lastPhysicalLocation = incoming
            return nil
        }

        let enforceConfinement = mapping.settings.confineCursor || mapping.threeDGameMode

        // In 3D Game Mode, strictly keep scaled confinement (never windowed escape or menu-bar passthrough).
        if mapping.threeDGameMode &&
            (interactionMode == .outsideWindowedOverlay || interactionMode == .menuBarPassthrough)
        {
            interactionMode = .scaled
            menuBarDropdownActive = false
            menuBarDropdownDismissPendingOnUp = false
            topEdgeUpwardOverflow = 0
        }

        // Step 2: Handle non-scaled native passthrough modes (Direct Chrome, Windowed Outside Overlay,
        // Fullscreen Menu Bar Passthrough, and Unconfined Outside Source).
        switch interactionMode {
        case .directChrome:
            // Protect against stale pre-warp events queued before our entry warp onto the toolbar landed
            // (real WindowServer pre-warp bursts flush within ~50ms).
            if case .preWarpQueued = warpResolution,
               let pw = pendingWarp,
               (now - pw.timestamp) < 0.05
            {
                let anchor = pw.to
                if isButtonDownEvent { activeChromeDrag = true }
                if isButtonUpEvent && pressedButtonsMask == 0 { activeChromeDrag = false }
                return CursorTapEventDecision(
                    rewrittenEventLocation: anchor,
                    warpTarget: nil,
                    effectiveSourcePoint: anchor,
                    scaledCGPosition: anchor,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: isButtonDownEvent || isScrollEvent,
                    interactionMode: .directChrome
                )
            } else if let pw = pendingWarp, (now - pw.timestamp) >= 0.05 {
                pendingWarp = nil
            }

            // Click/scroll arrived before our entry warp landed (stale physical location far from chrome target).
            if (isButtonEvent || isScrollEvent),
               let pw = pendingWarp,
               hypot(incoming.x - pw.to.x, incoming.y - pw.to.y) >= 1.0
            {
                let anchor = pw.to
                if isButtonDownEvent { activeChromeDrag = true }
                if isButtonUpEvent && pressedButtonsMask == 0 { activeChromeDrag = false }
                let alreadyWarping = (now - pw.timestamp) < 0.015
                var wt: CGPoint? = nil
                if !alreadyWarping {
                    wt = anchor
                    lastWarpedPoint = anchor
                    lastWarpedTimestamp = now
                    pendingWarp = PendingWarp(from: incoming, to: anchor, timestamp: now)
                }
                lastPhysicalLocation = incoming
                return CursorTapEventDecision(
                    rewrittenEventLocation: anchor,
                    warpTarget: wt,
                    effectiveSourcePoint: anchor,
                    scaledCGPosition: anchor,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: isButtonDownEvent || isScrollEvent,
                    interactionMode: .directChrome
                )
            }

            if isButtonDownEvent && isPointInInteractiveChrome(incoming) {
                activeChromeDrag = true
            }
            let stayInChrome = isPointInInteractiveChrome(incoming)
                || activeChromeDrag
                || (isButtonUpEvent && hadButtonsPressedBeforeEvent)
            if stayInChrome {
                if isButtonUpEvent && pressedButtonsMask == 0 {
                    activeChromeDrag = false
                }
                lastPhysicalLocation = incoming
                virtualSourcePosition = incoming
                if isMotionEvent { lastMotionTimestamp = now }
                return CursorTapEventDecision(
                    rewrittenEventLocation: nil,
                    warpTarget: nil,
                    effectiveSourcePoint: incoming,
                    scaledCGPosition: incoming,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: false,
                    interactionMode: .directChrome
                )
            }

            // Exited interactive chrome with no active drag: route smoothly to destination regime.
            activeChromeDrag = false
            if isPresentationWindowed && !mapping.threeDGameMode && !mapping.overlayRect.contains(incoming) {
                interactionMode = .outsideWindowedOverlay
                lastPhysicalLocation = incoming
                virtualSourcePosition = incoming
                if isMotionEvent { lastMotionTimestamp = now }
                return CursorTapEventDecision(
                    rewrittenEventLocation: nil,
                    warpTarget: nil,
                    effectiveSourcePoint: incoming,
                    scaledCGPosition: incoming,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: false,
                    interactionMode: .outsideWindowedOverlay
                )
            }
            if !isPresentationWindowed && !mapping.threeDGameMode && hostMenuBarRect(for: mapping).contains(incoming) {
                interactionMode = .menuBarPassthrough
                menuBarDropdownActive = isButtonDownEvent
                menuBarDropdownDismissPendingOnUp = false
                lastPhysicalLocation = incoming
                virtualSourcePosition = incoming
                if isMotionEvent { lastMotionTimestamp = now }
                return CursorTapEventDecision(
                    rewrittenEventLocation: nil,
                    warpTarget: nil,
                    effectiveSourcePoint: incoming,
                    scaledCGPosition: incoming,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: false,
                    interactionMode: .menuBarPassthrough
                )
            }
            if !enforceConfinement && !mapping.isPointInsideSource(incoming) {
                interactionMode = .unconfinedOutsideSource
                isPointerOutsideUnconfinedSource = true
                lastPhysicalLocation = incoming
                virtualSourcePosition = incoming
                if isMotionEvent { lastMotionTimestamp = now }
                let scaledPos = mapping.mapSourceToScaled(incoming, clampToContent: true)
                return CursorTapEventDecision(
                    rewrittenEventLocation: nil,
                    warpTarget: nil,
                    effectiveSourcePoint: incoming,
                    scaledCGPosition: scaledPos,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: true,
                    shouldRepostAfterWarp: false,
                    interactionMode: .unconfinedOutsideSource
                )
            }
            return transitionBackToScaled(
                at: incoming,
                input: input,
                mapping: mapping,
                enforceConfinement: enforceConfinement,
                isHiddenForScreenshot: isHiddenForScreenshot,
                isIdleHidden: isIdleHidden,
                isButtonDownEvent: isButtonDownEvent,
                isScrollEvent: isScrollEvent,
                isMotionEvent: isMotionEvent
            )

        case .outsideWindowedOverlay:
            if !isPresentationWindowed || mapping.threeDGameMode {
                return transitionBackToScaled(
                    at: incoming,
                    input: input,
                    mapping: mapping,
                    enforceConfinement: enforceConfinement,
                    isHiddenForScreenshot: isHiddenForScreenshot,
                    isIdleHidden: isIdleHidden,
                    isButtonDownEvent: isButtonDownEvent,
                    isScrollEvent: isScrollEvent,
                    isMotionEvent: isMotionEvent
                )
            }
            if case .preWarpQueued = warpResolution {
                let anchor = pendingWarp?.to ?? lastWarpedPoint ?? incoming
                return CursorTapEventDecision(
                    rewrittenEventLocation: anchor,
                    warpTarget: nil,
                    effectiveSourcePoint: anchor,
                    scaledCGPosition: anchor,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: false,
                    interactionMode: .outsideWindowedOverlay
                )
            }
            if !hadButtonsPressedBeforeEvent && isPointInInteractiveChrome(incoming) {
                interactionMode = .directChrome
                activeChromeDrag = isButtonDownEvent
                lastPhysicalLocation = incoming
                virtualSourcePosition = incoming
                if isMotionEvent { lastMotionTimestamp = now }
                return CursorTapEventDecision(
                    rewrittenEventLocation: nil,
                    warpTarget: nil,
                    effectiveSourcePoint: incoming,
                    scaledCGPosition: incoming,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: false,
                    interactionMode: .directChrome
                )
            }
            if !hadButtonsPressedBeforeEvent && mapping.overlayRect.contains(incoming) {
                return transitionBackToScaled(
                    at: incoming,
                    input: input,
                    mapping: mapping,
                    enforceConfinement: enforceConfinement,
                    isHiddenForScreenshot: isHiddenForScreenshot,
                    isIdleHidden: isIdleHidden,
                    isButtonDownEvent: isButtonDownEvent,
                    isScrollEvent: isScrollEvent,
                    isMotionEvent: isMotionEvent
                )
            }
            lastPhysicalLocation = incoming
            virtualSourcePosition = incoming
            if isMotionEvent { lastMotionTimestamp = now }
            return CursorTapEventDecision(
                rewrittenEventLocation: nil,
                warpTarget: nil,
                effectiveSourcePoint: incoming,
                scaledCGPosition: incoming,
                isScaledSpriteVisible: false,
                isMouseGrabbedByGame: false,
                isPointerOutsideUnconfinedSource: false,
                shouldRepostAfterWarp: false,
                interactionMode: .outsideWindowedOverlay
            )

        case .menuBarPassthrough:
            if isPresentationWindowed || mapping.threeDGameMode {
                if isPresentationWindowed && !mapping.threeDGameMode && !mapping.overlayRect.contains(incoming) {
                    interactionMode = .outsideWindowedOverlay
                    menuBarDropdownActive = false
                    menuBarDropdownDismissPendingOnUp = false
                    lastPhysicalLocation = incoming
                    virtualSourcePosition = incoming
                    if isMotionEvent { lastMotionTimestamp = now }
                    return CursorTapEventDecision(
                        rewrittenEventLocation: nil,
                        warpTarget: nil,
                        effectiveSourcePoint: incoming,
                        scaledCGPosition: incoming,
                        isScaledSpriteVisible: false,
                        isMouseGrabbedByGame: false,
                        isPointerOutsideUnconfinedSource: false,
                        shouldRepostAfterWarp: false,
                        interactionMode: .outsideWindowedOverlay
                    )
                }
                return transitionBackToScaled(
                    at: incoming,
                    input: input,
                    mapping: mapping,
                    enforceConfinement: enforceConfinement,
                    isHiddenForScreenshot: isHiddenForScreenshot,
                    isIdleHidden: isIdleHidden,
                    isButtonDownEvent: isButtonDownEvent,
                    isScrollEvent: isScrollEvent,
                    isMotionEvent: isMotionEvent
                )
            }
            if case .preWarpQueued = warpResolution {
                let anchor = pendingWarp?.to ?? lastWarpedPoint ?? incoming
                return CursorTapEventDecision(
                    rewrittenEventLocation: anchor,
                    warpTarget: nil,
                    effectiveSourcePoint: anchor,
                    scaledCGPosition: anchor,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: isButtonDownEvent,
                    interactionMode: .menuBarPassthrough
                )
            }

            let menuBar = hostMenuBarRect(for: mapping)
            let inMenuBarStrip = incoming.y <= menuBar.maxY + 4.0 &&
                incoming.x >= menuBar.minX - 2.0 &&
                incoming.x <= menuBar.maxX + 2.0
            let belowExitHysteresis = incoming.y > menuBar.maxY + 8.0

            if isButtonDownEvent {
                if inMenuBarStrip {
                    menuBarDropdownActive = true
                    menuBarDropdownDismissPendingOnUp = false
                } else if menuBarDropdownActive {
                    menuBarDropdownDismissPendingOnUp = true
                }
            } else if isButtonUpEvent && pressedButtonsMask == 0 {
                if menuBarDropdownDismissPendingOnUp || !inMenuBarStrip {
                    menuBarDropdownActive = false
                    menuBarDropdownDismissPendingOnUp = false
                }
            }

            // Moving directly from menu bar down onto MetalPie's floating toolbar transitions cleanly to `.directChrome`.
            if !inMenuBarStrip &&
                !menuBarDropdownActive &&
                !hadButtonsPressedBeforeEvent &&
                !isButtonUpEvent &&
                isPointInInteractiveChrome(incoming)
            {
                interactionMode = .directChrome
                activeChromeDrag = isButtonDownEvent
                lastPhysicalLocation = incoming
                virtualSourcePosition = incoming
                if isMotionEvent { lastMotionTimestamp = now }
                return CursorTapEventDecision(
                    rewrittenEventLocation: nil,
                    warpTarget: nil,
                    effectiveSourcePoint: incoming,
                    scaledCGPosition: incoming,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: false,
                    interactionMode: .directChrome
                )
            }

            let stayInMenuBar = !belowExitHysteresis
                || menuBarDropdownActive
                || hadButtonsPressedBeforeEvent
                || isButtonUpEvent
            if stayInMenuBar {
                lastPhysicalLocation = incoming
                virtualSourcePosition = incoming
                if isMotionEvent { lastMotionTimestamp = now }
                return CursorTapEventDecision(
                    rewrittenEventLocation: nil,
                    warpTarget: nil,
                    effectiveSourcePoint: incoming,
                    scaledCGPosition: incoming,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: false,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: false,
                    interactionMode: .menuBarPassthrough
                )
            }

            return transitionBackToScaled(
                at: incoming,
                input: input,
                mapping: mapping,
                enforceConfinement: enforceConfinement,
                isHiddenForScreenshot: isHiddenForScreenshot,
                isIdleHidden: isIdleHidden,
                isButtonDownEvent: isButtonDownEvent,
                isScrollEvent: isScrollEvent,
                isMotionEvent: isMotionEvent
            )

        case .unconfinedOutsideSource, .scaled:
            break
        }

        // Step 3: Track FPS / 3D game mouse-grab strictly on clean motion events (never on warp echoes
        // or stale pre-warp queued events, eliminating false-positive grab flapping during normal usage).
        let grabbed: Bool
        if mapping.settings.respectGameMouseGrab {
            if isMotionEvent {
                switch warpResolution {
                case .pureEcho, .preWarpQueued:
                    grabbed = pointerTracker.isGrabbed
                case .postWarpLanded(_, let contaminated):
                    if contaminated {
                        pointerTracker.recordSelfWarp(to: incoming, rawIncoming: nil)
                        grabbed = pointerTracker.isGrabbed
                    } else {
                        grabbed = pointerTracker.recordEvent(
                            location: incoming,
                            deltaX: deltaX,
                            deltaY: deltaY,
                            mapping: mapping,
                            timestamp: now
                        )
                    }
                case .none:
                    grabbed = pointerTracker.recordEvent(
                        location: incoming,
                        deltaX: deltaX,
                        deltaY: deltaY,
                        mapping: mapping,
                        timestamp: now
                    )
                }
            } else {
                grabbed = pointerTracker.isGrabbed
            }
        } else {
            grabbed = false
        }

        let wasOutsideUnconfined = isPointerOutsideUnconfinedSource || (interactionMode == .unconfinedOutsideSource)

        // Step 4: When confinement is explicitly disabled and pointer already escaped outside sourceRect,
        // keep 1:1 native OS cursor motion across other monitors until re-entering sourceRect (or chrome).
        if !enforceConfinement && wasOutsideUnconfined {
            if !hadButtonsPressedBeforeEvent && isPointInInteractiveChrome(incoming) {
                interactionMode = .directChrome
                isPointerOutsideUnconfinedSource = false
                activeChromeDrag = isButtonDownEvent
                lastPhysicalLocation = incoming
                virtualSourcePosition = incoming
                if isMotionEvent { lastMotionTimestamp = now }
                return CursorTapEventDecision(
                    rewrittenEventLocation: nil,
                    warpTarget: nil,
                    effectiveSourcePoint: incoming,
                    scaledCGPosition: incoming,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: grabbed,
                    isPointerOutsideUnconfinedSource: false,
                    shouldRepostAfterWarp: false,
                    interactionMode: .directChrome
                )
            }
            if !mapping.isPointInsideSource(incoming) {
                lastPhysicalLocation = incoming
                if isMotionEvent {
                    lastMotionTimestamp = now
                }
                virtualSourcePosition = incoming
                isPointerOutsideUnconfinedSource = true
                interactionMode = .unconfinedOutsideSource
                let scaledPos = mapping.mapSourceToScaled(incoming, clampToContent: true)
                return CursorTapEventDecision(
                    rewrittenEventLocation: nil,
                    warpTarget: nil,
                    effectiveSourcePoint: incoming,
                    scaledCGPosition: scaledPos,
                    isScaledSpriteVisible: false,
                    isMouseGrabbedByGame: grabbed,
                    isPointerOutsideUnconfinedSource: true,
                    shouldRepostAfterWarp: false,
                    interactionMode: .unconfinedOutsideSource
                )
            }
        }

        var newEventLocation: CGPoint?
        var warpTarget: CGPoint?
        var shouldRepostAfterWarp = false
        var wasBorderDragThisEvent = activeWindowBorderDrag
        let effectiveSourcePoint: CGPoint

        if grabbed || mapping.threeDGameMode {
            // Zero-delta-drift confinement: NEVER touch relative deltas or speed scaling!
            activeWindowBorderDrag = false
            wasBorderDragThisEvent = false
            topEdgeUpwardOverflow = 0
            if enforceConfinement {
                let constrained = mapping.constrainSourcePoint(incoming)
                if constrained.wasClamped {
                    newEventLocation = constrained.point
                    warpTarget = constrained.point
                }
                effectiveSourcePoint = constrained.point
            } else {
                effectiveSourcePoint = incoming
            }
            virtualSourcePosition = effectiveSourcePoint
            lastPhysicalLocation = incoming
            if isMotionEvent {
                lastMotionTimestamp = now
            }
        } else if mapping.settings.adjustCursorSpeed && !mapping.isIdentity {
            // Exact 1:1 visual cursor speed compensation:
            // - Measures true double-precision desktop travel from `incoming - physicalOrigin`
            //   (immune to integer delta truncation, high-DPI raw-count scaling, and warp-delta spikes!).
            // - Integrates in `Double` `virtualSourcePosition` and rewrites `event.location` on every event.
            // - Warps the physical OS cursor ONLY when needed (confinement edge recenter, click/scroll sync,
            //   or live border-resize sync), eliminating 120–1000 Hz warp spam and WindowServer feedback loops!
            let base: CGPoint
            if wasOutsideUnconfined {
                // Re-entering unconfined source window: start cleanly at the entry coordinate with zero snap.
                base = incoming
            } else if let existing = virtualSourcePosition {
                base = existing
            } else {
                base = enforceConfinement ? mapping.constrainSourcePoint(incoming).point : incoming
            }

            let targetPos: CGPoint
            if isMotionEvent && !wasOutsideUnconfined {
                var motionDX = 0.0
                var motionDY = 0.0

                switch warpResolution {
                case .pureEcho:
                    motionDX = 0.0
                    motionDY = 0.0
                case .preWarpQueued(let origin):
                    motionDX = Double(incoming.x - origin.x)
                    motionDY = Double(incoming.y - origin.y)
                case .postWarpLanded(let origin, _):
                    motionDX = Double(incoming.x - origin.x)
                    motionDY = Double(incoming.y - origin.y)
                case .none:
                    if let prevPhysical = lastPhysicalLocation {
                        let locDX = Double(incoming.x - prevPhysical.x)
                        let locDY = Double(incoming.y - prevPhysical.y)
                        motionDX = locDX
                        motionDY = locDY

                        // If the physical cursor was blocked against an outer display bezel along an axis
                        // while `base` still has room inside `confinementRect`, fall back to `deltaX`/`deltaY`
                        // on that bezel-blocked axis only (capped defensively against anomalous spikes).
                        if hasDelta && (abs(locDX) < 0.001 || abs(locDY) < 0.001) {
                            let displayEdges = mapping.touchedDisplayEdges(incoming)
                            if !displayEdges.isEmpty {
                                let maxFallbackStep = 64.0
                                if abs(locDX) < 0.001 {
                                    if (deltaX < -0.001 && displayEdges.contains(.left)) ||
                                        (deltaX > 0.001 && displayEdges.contains(.right))
                                    {
                                        motionDX = min(max(deltaX, -maxFallbackStep), maxFallbackStep)
                                    }
                                }
                                if abs(locDY) < 0.001 {
                                    if (deltaY < -0.001 && displayEdges.contains(.top)) ||
                                        (deltaY > 0.001 && displayEdges.contains(.bottom))
                                    {
                                        motionDY = min(max(deltaY, -maxFallbackStep), maxFallbackStep)
                                    }
                                }
                            }
                        }
                    } else if hasDelta {
                        // First motion event with no prior physical baseline.
                        let maxInitialStep = 64.0
                        motionDX = min(max(deltaX, -maxInitialStep), maxInitialStep)
                        motionDY = min(max(deltaY, -maxInitialStep), maxInitialStep)
                    }
                }

                let comp = mapping.speedCompensationScale
                let rawNext = (abs(motionDX) > 1e-6 || abs(motionDY) > 1e-6)
                    ? CGPoint(x: base.x + motionDX * comp.width, y: base.y + motionDY * comp.height)
                    : base

                // Mode transitions (Chrome, Windowed outside-overlay, Fullscreen Menu Bar) ONLY when
                // no drag inside the target window is active (`pressedButtonsMask == 0`).
                if pressedButtonsMask == 0 {
                    let unclampedScaled = mapping.mapSourceToScaled(rawNext, clampToContent: false)

                    if base.y <= mapping.confinementRect.minY + 1.5 && motionDY < -0.001 {
                        topEdgeUpwardOverflow += CGFloat(-motionDY)
                    } else if motionDY > 0.001 || base.y > mapping.confinementRect.minY + 2.0 {
                        topEdgeUpwardOverflow = 0
                    }

                    // 1. Direct Chrome check (also allows crossing a top letterbox bar up into MetalPie's toolbar).
                    if !interactiveChromeRects.isEmpty {
                        let chromeCheckPoint: CGPoint
                        if topEdgeUpwardOverflow > 0 && unclampedScaled.y <= mapping.contentRect.minY + 1.0 {
                            chromeCheckPoint = CGPoint(
                                x: unclampedScaled.x,
                                y: mapping.contentRect.minY - topEdgeUpwardOverflow
                            )
                        } else {
                            chromeCheckPoint = unclampedScaled
                        }
                        if isPointInInteractiveChrome(chromeCheckPoint) {
                            return enterDirectChrome(
                                at: chromeCheckPoint,
                                incoming: incoming,
                                input: input,
                                isButtonDownEvent: isButtonDownEvent,
                                isScrollEvent: isScrollEvent
                            )
                        }
                    }

                    // 2. Windowed mode smooth outside-overlay escape (releases confinement to Menu Bar / Dock / Desktop).
                    if isPresentationWindowed {
                        if let exitPoint = computeWindowedOverlayExitPoint(
                            unclampedScaled: unclampedScaled,
                            mapping: mapping
                        ) {
                            return enterOutsideWindowedOverlay(
                                at: exitPoint,
                                incoming: incoming,
                                input: input
                            )
                        }
                    }

                    // 3. Fullscreen mode top Menu Bar passthrough (pushing upward at top edge into Menu Bar strip).
                    //    Only applies when confined (`enforceConfinement == true`); unconfined mode escapes naturally.
                    if enforceConfinement && !isPresentationWindowed {
                        if let menuEntry = computeFullscreenMenuBarEntryPoint(
                            candidateScaledX: unclampedScaled.x,
                            mapping: mapping
                        ) {
                            return enterMenuBarPassthrough(
                                at: menuEntry,
                                incoming: incoming,
                                input: input
                            )
                        }
                    }
                } else {
                    topEdgeUpwardOverflow = 0
                }

                if activeWindowBorderDrag {
                    // Bug #5: Allow window border-resize / titlebar move drags to travel freely BOTH
                    // inward AND outward past old `sourceRect`, clamped only to display bounds!
                    targetPos = mapping.clampPointToDisplays(rawNext)
                } else if abs(motionDX) > 1e-6 || abs(motionDY) > 1e-6 {
                    targetPos = enforceConfinement ? mapping.constrainSourcePoint(rawNext).point : rawNext
                } else {
                    targetPos = enforceConfinement ? mapping.constrainSourcePoint(base).point : base
                }
                lastMotionTimestamp = now
            } else {
                // Clicks (*MouseDown/*MouseUp), scrollWheel, and unconfined re-entry stay strictly locked
                // to `virtualSourcePosition` so clicks ALWAYS hit the visual cursor hotspot!
                if !hadButtonsPressedBeforeEvent && !interactiveChromeRects.isEmpty {
                    let currentVisual = mapping.mapSourceToScaled(base, clampToContent: true)
                    if isPointInInteractiveChrome(currentVisual) {
                        return enterDirectChrome(
                            at: currentVisual,
                            incoming: incoming,
                            input: input,
                            isButtonDownEvent: isButtonDownEvent,
                            isScrollEvent: isScrollEvent
                        )
                    }
                }

                if wasBorderDragThisEvent {
                    // Keep border-resize release coordinate unclamped to old `sourceRect` so macOS commits the resize!
                    targetPos = mapping.clampPointToDisplays(base)
                    if type == .leftMouseUp || (pressedButtonsMask & (1 << 0)) == 0 {
                        activeWindowBorderDrag = false
                    }
                } else {
                    targetPos = enforceConfinement ? mapping.constrainSourcePoint(base).point : base
                    if type == .leftMouseDown && mapping.isPointInWindowResizeOrTitlebarZone(targetPos) {
                        activeWindowBorderDrag = true
                        wasBorderDragThisEvent = true
                        lastBorderDragSyncTimestamp = 0
                    } else if type == .leftMouseUp || (pressedButtonsMask & (1 << 0)) == 0 {
                        activeWindowBorderDrag = false
                    }
                }
            }

            virtualSourcePosition = targetPos
            effectiveSourcePoint = targetPos
            newEventLocation = targetPos
            lastPhysicalLocation = incoming

            let targetInsideSource = mapping.isPointInsideSource(targetPos)
            let physicalOutsideSource = !mapping.isPointInsideSource(incoming)
            let drift = hypot(incoming.x - targetPos.x, incoming.y - targetPos.y)

            if enforceConfinement || targetInsideSource || wasBorderDragThisEvent {
                if isButtonEvent || isScrollEvent {
                    // Sync hidden physical OS cursor onto `targetPos` before button presses/releases AND
                    // scroll-wheel / trackpad 2-finger scroll events whenever drifted >= 1pt or outside
                    // `sourceRect` so macOS WindowServer hit-testing, scroll views, context menus, and
                    // `[NSEvent mouseLocation]` agree 100% with the rendered scaled cursor!
                    if drift >= 1.0 || (physicalOutsideSource && !wasBorderDragThisEvent) {
                        let alreadyWarpingToTarget: Bool = {
                            guard let pw = pendingWarp else { return false }
                            return (now - pw.timestamp) < 0.015 &&
                                hypot(pw.to.x - targetPos.x, pw.to.y - targetPos.y) < 1.0
                        }()
                        if !alreadyWarpingToTarget {
                            warpTarget = targetPos
                        }
                        if isScrollEvent || isButtonDownEvent {
                            shouldRepostAfterWarp = true
                        }
                    }
                } else if type == .leftMouseDragged && activeWindowBorderDrag {
                    // Bug #5: Keep macOS WindowServer's live window resize / titlebar drag loop synced
                    // to `targetPos` cleanly at throttled intervals (never stacking on an in-flight warp!).
                    if drift >= 1.5 && pendingWarp == nil && (now - lastBorderDragSyncTimestamp) >= 0.012 {
                        warpTarget = targetPos
                        lastBorderDragSyncTimestamp = now
                    }
                } else if isMotionEvent && enforceConfinement && !activeWindowBorderDrag && pendingWarp == nil {
                    // Zero-hitch full-display physical cursor roaming:
                    // While the physical hardware cursor is hidden in `adjustCursorSpeed` mode, let it
                    // roam freely across the entire host display (`physicalRoamingRect`, inset 20pt from
                    // outer display bezels) so gliding across the entire scaled window triggers ZERO
                    // mid-glide `CGWarpMouseCursorPosition` calls! Only recenter when the physical cursor
                    // actually reaches the 20pt display bezel margin.
                    let roam = mapping.physicalRoamingRect
                    let hitBezel = incoming.x <= roam.minX ||
                        incoming.x >= roam.maxX ||
                        incoming.y <= roam.minY ||
                        incoming.y >= roam.maxY
                    if hitBezel {
                        let recenterTarget = roam.contains(targetPos)
                            ? targetPos
                            : CGPoint(x: roam.midX, y: roam.midY)
                        if hypot(incoming.x - recenterTarget.x, incoming.y - recenterTarget.y) >= 1.0 {
                            warpTarget = recenterTarget
                        }
                    }
                }
            }
        } else {
            // Standard zero-delta-drift confinement (`adjustCursorSpeed == false`):
            // Physical cursor moves natively inside `confinementRect`, warping ONLY on boundary exit.
            let unclampedScaled = mapping.mapSourceToScaled(incoming, clampToContent: false)

            if !hadButtonsPressedBeforeEvent && !interactiveChromeRects.isEmpty {
                if isPointInInteractiveChrome(unclampedScaled) {
                    return enterDirectChrome(
                        at: unclampedScaled,
                        incoming: incoming,
                        input: input,
                        isButtonDownEvent: isButtonDownEvent,
                        isScrollEvent: isScrollEvent
                    )
                }
            }

            if pressedButtonsMask == 0 && isMotionEvent {
                if incoming.y <= mapping.confinementRect.minY + 1.5 && (deltaY < -0.001 || incoming.y < mapping.confinementRect.minY) {
                    let push = max(
                        deltaY < 0 ? CGFloat(-deltaY) : 0,
                        max(0, mapping.confinementRect.minY - incoming.y) * CGFloat(mapping.scaleY)
                    )
                    topEdgeUpwardOverflow += push
                } else if deltaY > 0.001 || incoming.y > mapping.confinementRect.minY + 2.0 {
                    topEdgeUpwardOverflow = 0
                }

                if !interactiveChromeRects.isEmpty && topEdgeUpwardOverflow > 0 && unclampedScaled.y <= mapping.contentRect.minY + 1.0 {
                    let chromeCheck = CGPoint(x: unclampedScaled.x, y: mapping.contentRect.minY - topEdgeUpwardOverflow)
                    if isPointInInteractiveChrome(chromeCheck) {
                        return enterDirectChrome(
                            at: chromeCheck,
                            incoming: incoming,
                            input: input,
                            isButtonDownEvent: isButtonDownEvent,
                            isScrollEvent: isScrollEvent
                        )
                    }
                }

                if isPresentationWindowed && !mapping.isPointInsideSource(incoming) {
                    if let exitPoint = computeWindowedOverlayExitPoint(
                        unclampedScaled: unclampedScaled,
                        mapping: mapping
                    ) {
                        return enterOutsideWindowedOverlay(
                            at: exitPoint,
                            incoming: incoming,
                            input: input
                        )
                    }
                }

                if enforceConfinement && !isPresentationWindowed {
                    if let menuEntry = computeFullscreenMenuBarEntryPoint(
                        candidateScaledX: unclampedScaled.x,
                        mapping: mapping
                    ) {
                        return enterMenuBarPassthrough(
                            at: menuEntry,
                            incoming: incoming,
                            input: input
                        )
                    }
                }
            } else {
                topEdgeUpwardOverflow = 0
            }

            if wasBorderDragThisEvent {
                // Bug #5: Allow inward & outward border resize drags even when `adjustCursorSpeed == false`!
                effectiveSourcePoint = mapping.clampPointToDisplays(incoming)
                if type == .leftMouseUp || (pressedButtonsMask & (1 << 0)) == 0 {
                    activeWindowBorderDrag = false
                }
            } else if enforceConfinement {
                let constrained = mapping.constrainSourcePoint(incoming)
                if constrained.wasClamped {
                    newEventLocation = constrained.point
                    warpTarget = constrained.point
                    if isScrollEvent || isButtonDownEvent {
                        shouldRepostAfterWarp = true
                    }
                }
                effectiveSourcePoint = constrained.point
                if type == .leftMouseDown && mapping.isPointInWindowResizeOrTitlebarZone(effectiveSourcePoint) {
                    activeWindowBorderDrag = true
                    wasBorderDragThisEvent = true
                }
            } else {
                effectiveSourcePoint = incoming
                if type == .leftMouseDown && mapping.isPointInWindowResizeOrTitlebarZone(effectiveSourcePoint) {
                    activeWindowBorderDrag = true
                    wasBorderDragThisEvent = true
                }
            }
            virtualSourcePosition = effectiveSourcePoint
            lastPhysicalLocation = incoming
            if isMotionEvent {
                lastMotionTimestamp = now
            }
        }

        isPointerOutsideUnconfinedSource = !enforceConfinement && !mapping.isPointInsideSource(effectiveSourcePoint)
        interactionMode = isPointerOutsideUnconfinedSource ? .unconfinedOutsideSource : .scaled

        if let wt = warpTarget {
            lastWarpedPoint = wt
            lastWarpedTimestamp = now
            pendingWarp = PendingWarp(from: incoming, to: wt, timestamp: now)
            pointerTracker.recordSelfWarp(to: wt, rawIncoming: incoming)
        }

        let scaledPos: CGPoint
        if wasBorderDragThisEvent {
            scaledPos = mapping.clampPointToDisplays(
                mapping.mapSourceToScaled(effectiveSourcePoint, clampToContent: false)
            )
        } else {
            scaledPos = mapping.mapSourceToScaled(effectiveSourcePoint, clampToContent: true)
        }
        let spriteVisible = mapping.requiresScaledOverlayCursor
            && !isHiddenForScreenshot
            && !isIdleHidden
            && !isPointerOutsideUnconfinedSource
            && !(mapping.settings.respectGameMouseGrab && grabbed)

        return CursorTapEventDecision(
            rewrittenEventLocation: newEventLocation,
            warpTarget: warpTarget,
            effectiveSourcePoint: effectiveSourcePoint,
            scaledCGPosition: scaledPos,
            isScaledSpriteVisible: spriteVisible,
            isMouseGrabbedByGame: grabbed,
            isPointerOutsideUnconfinedSource: isPointerOutsideUnconfinedSource,
            shouldRepostAfterWarp: shouldRepostAfterWarp,
            interactionMode: interactionMode
        )
    }

    // MARK: - Interaction Mode Transition Helpers

    private mutating func enterDirectChrome(
        at chromePoint: CGPoint,
        incoming: CGPoint,
        input: CursorTapEventInput,
        isButtonDownEvent: Bool,
        isScrollEvent: Bool
    ) -> CursorTapEventDecision {
        interactionMode = .directChrome
        isPointerOutsideUnconfinedSource = false
        activeChromeDrag = isButtonDownEvent
        activeWindowBorderDrag = false
        topEdgeUpwardOverflow = 0
        menuBarDropdownActive = false
        menuBarDropdownDismissPendingOnUp = false

        virtualSourcePosition = chromePoint
        lastPhysicalLocation = incoming
        if input.type == .mouseMoved || input.type == .leftMouseDragged ||
            input.type == .rightMouseDragged || input.type == .otherMouseDragged
        {
            lastMotionTimestamp = input.timestamp
        }

        var warpTarget: CGPoint? = nil
        var shouldRepost = false
        let drift = hypot(incoming.x - chromePoint.x, incoming.y - chromePoint.y)
        if drift >= 1.0 {
            let alreadyWarping: Bool = {
                guard let pw = pendingWarp else { return false }
                return (input.timestamp - pw.timestamp) < 0.015 &&
                    hypot(pw.to.x - chromePoint.x, pw.to.y - chromePoint.y) < 1.0
            }()
            if !alreadyWarping {
                warpTarget = chromePoint
                lastWarpedPoint = chromePoint
                lastWarpedTimestamp = input.timestamp
                pendingWarp = PendingWarp(from: incoming, to: chromePoint, timestamp: input.timestamp)
                pointerTracker.recordSelfWarp(to: chromePoint, rawIncoming: incoming)
            }
            if isButtonDownEvent || isScrollEvent {
                shouldRepost = true
            }
        }

        return CursorTapEventDecision(
            rewrittenEventLocation: chromePoint,
            warpTarget: warpTarget,
            effectiveSourcePoint: chromePoint,
            scaledCGPosition: chromePoint,
            isScaledSpriteVisible: false,
            isMouseGrabbedByGame: false,
            isPointerOutsideUnconfinedSource: false,
            shouldRepostAfterWarp: shouldRepost,
            interactionMode: .directChrome
        )
    }

    private mutating func enterOutsideWindowedOverlay(
        at exitPoint: CGPoint,
        incoming: CGPoint,
        input: CursorTapEventInput
    ) -> CursorTapEventDecision {
        interactionMode = .outsideWindowedOverlay
        isPointerOutsideUnconfinedSource = false
        activeChromeDrag = false
        activeWindowBorderDrag = false
        topEdgeUpwardOverflow = 0
        menuBarDropdownActive = false
        menuBarDropdownDismissPendingOnUp = false

        virtualSourcePosition = exitPoint
        lastPhysicalLocation = incoming
        lastMotionTimestamp = input.timestamp

        var warpTarget: CGPoint? = nil
        if hypot(incoming.x - exitPoint.x, incoming.y - exitPoint.y) >= 1.0 {
            warpTarget = exitPoint
            lastWarpedPoint = exitPoint
            lastWarpedTimestamp = input.timestamp
            pendingWarp = PendingWarp(from: incoming, to: exitPoint, timestamp: input.timestamp)
            pointerTracker.recordSelfWarp(to: exitPoint, rawIncoming: incoming)
        }

        return CursorTapEventDecision(
            rewrittenEventLocation: exitPoint,
            warpTarget: warpTarget,
            effectiveSourcePoint: exitPoint,
            scaledCGPosition: exitPoint,
            isScaledSpriteVisible: false,
            isMouseGrabbedByGame: false,
            isPointerOutsideUnconfinedSource: false,
            shouldRepostAfterWarp: false,
            interactionMode: .outsideWindowedOverlay
        )
    }

    private mutating func enterMenuBarPassthrough(
        at entryPoint: CGPoint,
        incoming: CGPoint,
        input: CursorTapEventInput
    ) -> CursorTapEventDecision {
        interactionMode = .menuBarPassthrough
        isPointerOutsideUnconfinedSource = false
        activeChromeDrag = false
        activeWindowBorderDrag = false
        topEdgeUpwardOverflow = 0
        menuBarDropdownActive = false
        menuBarDropdownDismissPendingOnUp = false

        virtualSourcePosition = entryPoint
        lastPhysicalLocation = incoming
        lastMotionTimestamp = input.timestamp

        var warpTarget: CGPoint? = nil
        if hypot(incoming.x - entryPoint.x, incoming.y - entryPoint.y) >= 1.0 {
            warpTarget = entryPoint
            lastWarpedPoint = entryPoint
            lastWarpedTimestamp = input.timestamp
            pendingWarp = PendingWarp(from: incoming, to: entryPoint, timestamp: input.timestamp)
            pointerTracker.recordSelfWarp(to: entryPoint, rawIncoming: incoming)
        }

        return CursorTapEventDecision(
            rewrittenEventLocation: entryPoint,
            warpTarget: warpTarget,
            effectiveSourcePoint: entryPoint,
            scaledCGPosition: entryPoint,
            isScaledSpriteVisible: false,
            isMouseGrabbedByGame: false,
            isPointerOutsideUnconfinedSource: false,
            shouldRepostAfterWarp: false,
            interactionMode: .menuBarPassthrough
        )
    }

    private mutating func transitionBackToScaled(
        at incoming: CGPoint,
        input: CursorTapEventInput,
        mapping: PointerMapping,
        enforceConfinement: Bool,
        isHiddenForScreenshot: Bool,
        isIdleHidden: Bool,
        isButtonDownEvent: Bool,
        isScrollEvent: Bool,
        isMotionEvent: Bool
    ) -> CursorTapEventDecision {
        let mappedSource = mapping.mapScaledToSource(incoming, clampToSource: true)
        let entrySource = enforceConfinement ? mapping.constrainSourcePoint(mappedSource).point : mappedSource

        interactionMode = .scaled
        isPointerOutsideUnconfinedSource = false
        activeChromeDrag = false
        activeWindowBorderDrag = (
            input.type == .leftMouseDown &&
                !mapping.threeDGameMode &&
                mapping.isPointInWindowResizeOrTitlebarZone(entrySource)
        )
        lastBorderDragSyncTimestamp = 0
        topEdgeUpwardOverflow = 0
        menuBarDropdownActive = false
        menuBarDropdownDismissPendingOnUp = false

        virtualSourcePosition = entrySource
        lastPhysicalLocation = incoming
        if isMotionEvent {
            lastMotionTimestamp = input.timestamp
        }

        var warpTarget: CGPoint? = nil
        var shouldRepost = false
        let drift = hypot(incoming.x - entrySource.x, incoming.y - entrySource.y)
        let needsSyncWarp = (!mapping.settings.adjustCursorSpeed && drift >= 1.0)
            || ((isButtonDownEvent || isScrollEvent) && (drift >= 1.0 || !mapping.isPointInsideSource(incoming)))

        if needsSyncWarp {
            warpTarget = entrySource
            lastWarpedPoint = entrySource
            lastWarpedTimestamp = input.timestamp
            pendingWarp = PendingWarp(from: incoming, to: entrySource, timestamp: input.timestamp)
            pointerTracker.recordSelfWarp(to: entrySource, rawIncoming: incoming)
            if isButtonDownEvent || isScrollEvent {
                shouldRepost = true
            }
        } else {
            pointerTracker.recordSelfWarp(to: incoming, rawIncoming: nil)
        }

        let scaledPos = mapping.mapSourceToScaled(entrySource, clampToContent: true)
        let spriteVisible = mapping.requiresScaledOverlayCursor
            && !isHiddenForScreenshot
            && !isIdleHidden
            && !(mapping.settings.respectGameMouseGrab && pointerTracker.isGrabbed)

        return CursorTapEventDecision(
            rewrittenEventLocation: entrySource,
            warpTarget: warpTarget,
            effectiveSourcePoint: entrySource,
            scaledCGPosition: scaledPos,
            isScaledSpriteVisible: spriteVisible,
            isMouseGrabbedByGame: pointerTracker.isGrabbed,
            isPointerOutsideUnconfinedSource: false,
            shouldRepostAfterWarp: shouldRepost,
            interactionMode: .scaled
        )
    }

    private func computeWindowedOverlayExitPoint(
        unclampedScaled: CGPoint,
        mapping: PointerMapping
    ) -> CGPoint? {
        let overlay = mapping.overlayRect
        let content = mapping.contentRect
        let crossedOverlay = !overlay.contains(unclampedScaled)
        let crossedContent = mapping.hasLetterboxBars && !content.contains(unclampedScaled)
        guard crossedOverlay || crossedContent else { return nil }

        var projected = unclampedScaled
        let exitMargin: CGFloat = 2.0
        if unclampedScaled.x < content.minX || unclampedScaled.x < overlay.minX {
            projected.x = min(unclampedScaled.x, overlay.minX - exitMargin)
        } else if unclampedScaled.x >= content.maxX || unclampedScaled.x >= overlay.maxX {
            projected.x = max(unclampedScaled.x, overlay.maxX + exitMargin)
        }
        if unclampedScaled.y < content.minY || unclampedScaled.y < overlay.minY {
            projected.y = min(unclampedScaled.y, overlay.minY - exitMargin)
        } else if unclampedScaled.y >= content.maxY || unclampedScaled.y >= overlay.maxY {
            projected.y = max(unclampedScaled.y, overlay.maxY + exitMargin)
        }

        let clampedExit = mapping.clampPointToDisplays(projected, edgeInset: 0.0)
        // Only escape if the resulting desktop point lies strictly outside `overlayRect`
        // (prevents futile escape on edges flush against an outer monitor bezel with no adjacent display).
        return overlay.contains(clampedExit) ? nil : clampedExit
    }

    private func computeFullscreenMenuBarEntryPoint(
        candidateScaledX: CGFloat,
        mapping: PointerMapping
    ) -> CGPoint? {
        let menuBar = hostMenuBarRect(for: mapping)
        guard !menuBar.isEmpty, mapping.overlayRect.minY <= menuBar.maxY + 4.0 else {
            return nil
        }
        let requiredPush = max(6.0, mapping.contentRect.minY - menuBar.maxY + 4.0)
        guard topEdgeUpwardOverflow >= requiredPush else {
            return nil
        }
        let entryX = min(max(candidateScaledX, menuBar.minX + 1.0), max(menuBar.minX + 1.0, menuBar.maxX - 1.0))
        let entryY = menuBar.minY + min(12.0, max(1.0, menuBar.height * 0.5))
        let entryPoint = CGPoint(x: entryX, y: entryY)
        guard !isPointInInteractiveChrome(entryPoint) else {
            return nil
        }
        return entryPoint
    }
}

// MARK: - FPS / 3D Game Mouse-Grab Detector

/// Pure, unit-testable detector identifying when a 3D/FPS game locks or warps the pointer
/// (`CGAssociateMouseAndMouseCursorPosition(false)` or repeated center-warp loops).
///
/// Solves MetalGoose's border false-negative bug by distinguishing outward edge-pushing deltas
/// from inward/locked mouse-grab deltas near window borders.
public struct PointerTracker: Sendable {
    public let grabThreshold: Int
    public let warpGrabThreshold: Int
    public let releaseMoveThreshold: Int
    public let minAccumulatedUnreflectedDelta: Double

    public private(set) var isGrabbed: Bool = false
    public private(set) var stillEventCount: Int = 0
    public private(set) var warpToCenterCount: Int = 0
    public private(set) var accumulatedUnreflectedDelta: Double = 0

    private var lastLocation: CGPoint?
    private var previousLocation: CGPoint?
    private var lastSelfWarpRawIncoming: CGPoint?
    private var grabAnchor: CGPoint?
    private var candidateWarpAnchor: CGPoint?
    private var lastWarpTimestamp: TimeInterval = 0
    private var movesAwayFromAnchor: Int = 0
    private var releaseMoveCount: Int = 0

    public init(
        grabThreshold: Int = 6,
        warpGrabThreshold: Int = 5,
        releaseMoveThreshold: Int = 2,
        minAccumulatedUnreflectedDelta: Double = 18.0
    ) {
        self.grabThreshold = max(1, grabThreshold)
        self.warpGrabThreshold = max(1, warpGrabThreshold)
        self.releaseMoveThreshold = max(1, releaseMoveThreshold)
        self.minAccumulatedUnreflectedDelta = max(0.0, minAccumulatedUnreflectedDelta)
    }

    public mutating func reset() {
        isGrabbed = false
        stillEventCount = 0
        warpToCenterCount = 0
        accumulatedUnreflectedDelta = 0
        lastLocation = nil
        previousLocation = nil
        lastSelfWarpRawIncoming = nil
        grabAnchor = nil
        candidateWarpAnchor = nil
        lastWarpTimestamp = 0
        movesAwayFromAnchor = 0
        releaseMoveCount = 0
    }

    /// Updates reference location after `CursorOverlayController` itself calls `CGWarpMouseCursorPosition`
    /// (for bezel recentering, click/scroll sync, or edge confinement). Stores `rawIncoming` so:
    /// - Normal apps (which follow our warp and advance by `(deltaX, deltaY)`) NEVER false-positive as FPS grab.
    /// - FPS games locking the cursor via `CGAssociateMouseAndMouseCursorPosition(false)` (where `location`
    ///   remains pinned at `rawIncoming` ignoring BOTH deltas and warps) STILL trigger `isGrabbed = true`!
    public mutating func recordSelfWarp(to point: CGPoint, rawIncoming: CGPoint? = nil) {
        lastLocation = point
        previousLocation = nil
        lastSelfWarpRawIncoming = rawIncoming
    }

    /// Processes one mouse motion event and returns whether mouse-grab is currently active.
    @discardableResult
    public mutating func recordEvent(
        location: CGPoint,
        deltaX: Double,
        deltaY: Double,
        mapping: PointerMapping,
        timestamp: TimeInterval
    ) -> Bool {
        let eps = 0.001
        let hasDelta = abs(deltaX) > eps || abs(deltaY) > eps
        let prevRawIncoming = lastSelfWarpRawIncoming

        defer {
            previousLocation = lastLocation
            lastLocation = location
            lastSelfWarpRawIncoming = nil
        }

        guard let last = lastLocation else {
            return isGrabbed
        }

        let movedX = location.x - last.x
        let movedY = location.y - last.y
        let moveDist = hypot(movedX, movedY)

        if !hasDelta {
            // Pure programmatic warp without deltas (e.g., SDL/game centering cursor) or cursor settle.
            if moveDist >= 2.0 {
                let activeAnchor = candidateWarpAnchor ?? grabAnchor
                if let anchor = activeAnchor,
                   hypot(location.x - anchor.x, location.y - anchor.y) <= 1.5,
                   hypot(last.x - anchor.x, last.y - anchor.y) >= 2.0
                {
                    if timestamp - lastWarpTimestamp > 0.75 {
                        warpToCenterCount = 1
                    } else {
                        warpToCenterCount += 1
                    }
                    lastWarpTimestamp = timestamp
                    candidateWarpAnchor = anchor
                    movesAwayFromAnchor = 0
                    releaseMoveCount = 0
                    if warpToCenterCount >= warpGrabThreshold {
                        isGrabbed = true
                        grabAnchor = anchor
                    }
                } else if let prev2 = previousLocation,
                          hypot(location.x - prev2.x, location.y - prev2.y) <= 1.5,
                          hypot(last.x - prev2.x, last.y - prev2.y) >= 2.0
                {
                    candidateWarpAnchor = prev2
                    warpToCenterCount = 1
                    lastWarpTimestamp = timestamp
                    movesAwayFromAnchor = 0
                    releaseMoveCount = 0
                    if warpToCenterCount >= warpGrabThreshold {
                        isGrabbed = true
                        grabAnchor = prev2
                    }
                } else if isGrabbed {
                    releaseMoveCount += 1
                    if releaseMoveCount >= releaseMoveThreshold {
                        isGrabbed = false
                        stillEventCount = 0
                        accumulatedUnreflectedDelta = 0
                        warpToCenterCount = 0
                        grabAnchor = nil
                        candidateWarpAnchor = nil
                        movesAwayFromAnchor = 0
                        releaseMoveCount = 0
                    }
                }
            }
            return isGrabbed
        }

        let deltaMag = hypot(deltaX, deltaY)

        // Case 1: Non-zero relative deltas while physical pointer coordinates remain strictly pinned
        // (signature of CGAssociateMouseAndMouseCursorPosition(false)).
        // Require truly pinned physical cursor (`effectiveMoveDist < 0.05`), meaningful raw delta
        // (`deltaMag >= 2.0` AND `deltaMag > effectiveMoveDist * 6.0`), AND accumulated unreflected
        // delta >= 18.0pt across >= `grabThreshold` (default 6) consecutive events so slow sub-pixel
        // trackpad glides and 120Hz mouse micro-movements can NEVER false-trigger `isGrabbed`!
        let pinnedAtLast = moveDist < 0.05
        let preWarpDist = prevRawIncoming.map { hypot(location.x - $0.x, location.y - $0.y) }
        let pinnedAtPreWarpIncoming = (preWarpDist ?? .greatestFiniteMagnitude) < 0.05
        let effectiveMoveDist = pinnedAtPreWarpIncoming ? (preWarpDist ?? 0.0) : moveDist
        let followedSelfWarpDelta = prevRawIncoming != nil &&
            hypot(Double(movedX) - deltaX, Double(movedY) - deltaY) < max(0.75, deltaMag * 0.35)

        if (pinnedAtLast || pinnedAtPreWarpIncoming) && !followedSelfWarpDelta {
            if mapping.isDeltaPushingOutward(deltaX: deltaX, deltaY: deltaY, at: location) ||
                mapping.isDeltaPushingOutwardAgainstDisplay(deltaX: deltaX, deltaY: deltaY, at: location)
            {
                // Normal user pushing mouse against window confinement edge or outer display bezel.
                stillEventCount = 0
                accumulatedUnreflectedDelta = 0
                return isGrabbed
            }

            if deltaMag >= 2.0 && deltaMag > effectiveMoveDist * 6.0 {
                stillEventCount += 1
                accumulatedUnreflectedDelta += deltaMag
                releaseMoveCount = 0
                if stillEventCount >= grabThreshold && accumulatedUnreflectedDelta >= minAccumulatedUnreflectedDelta {
                    isGrabbed = true
                    grabAnchor = location
                }
            }
            return isGrabbed
        }

        // Case 2: Repeated programmatic warp-to-center / snap-back loops (SDL/Minecraft/Wine).
        // Require returning to the EXACT same 1.5pt anchor (`>= warpGrabThreshold` = 5 snaps) where
        // raw mouse deltas point strictly AWAY from that anchor (contradicting the snap-back jump!),
        // so normal rapid left/right human mouse wiggling over buttons can NEVER false-trigger!
        let dotWithMoved = Double(movedX) * deltaX + Double(movedY) * deltaY
        let deltaContradictsSnapBack = moveDist >= 2.0 &&
            deltaMag >= 2.0 &&
            dotWithMoved < -(moveDist * deltaMag * 0.25)

        if deltaContradictsSnapBack {
            let activeAnchor = candidateWarpAnchor ?? grabAnchor
            if let anchor = activeAnchor,
               hypot(location.x - anchor.x, location.y - anchor.y) <= 1.5,
               hypot(last.x - anchor.x, last.y - anchor.y) >= 2.0
            {
                if timestamp - lastWarpTimestamp > 0.75 {
                    warpToCenterCount = 1
                } else {
                    warpToCenterCount += 1
                }
                lastWarpTimestamp = timestamp
                candidateWarpAnchor = anchor
                movesAwayFromAnchor = 0
                stillEventCount = 0
                accumulatedUnreflectedDelta = 0
                releaseMoveCount = 0
                if warpToCenterCount >= warpGrabThreshold {
                    isGrabbed = true
                    grabAnchor = anchor
                }
                return isGrabbed
            } else if activeAnchor == nil,
                      let prev2 = previousLocation,
                      hypot(location.x - prev2.x, location.y - prev2.y) <= 1.5,
                      hypot(last.x - prev2.x, last.y - prev2.y) >= 2.0
            {
                candidateWarpAnchor = prev2
                warpToCenterCount = 1
                lastWarpTimestamp = timestamp
                movesAwayFromAnchor = 0
                stillEventCount = 0
                accumulatedUnreflectedDelta = 0
                releaseMoveCount = 0
                if warpToCenterCount >= warpGrabThreshold {
                    isGrabbed = true
                    grabAnchor = prev2
                }
                return isGrabbed
            }
        }

        // Case 3: Genuine cursor motion (including slow sub-pixel glides and human wiggling).
        // Immediately reset Case 1 counters so transient ticks never accumulate across normal glides!
        stillEventCount = 0
        accumulatedUnreflectedDelta = 0

        if candidateWarpAnchor != nil {
            movesAwayFromAnchor += 1
            if movesAwayFromAnchor >= 3 || (timestamp - lastWarpTimestamp > 0.75) {
                warpToCenterCount = 0
                candidateWarpAnchor = nil
                movesAwayFromAnchor = 0
            }
        } else if timestamp - lastWarpTimestamp > 0.75 {
            warpToCenterCount = 0
        }

        if isGrabbed {
            if moveDist >= 1.5 {
                releaseMoveCount += 1
                if releaseMoveCount >= releaseMoveThreshold {
                    isGrabbed = false
                    warpToCenterCount = 0
                    grabAnchor = nil
                    candidateWarpAnchor = nil
                    movesAwayFromAnchor = 0
                    releaseMoveCount = 0
                }
            }
        }
        return isGrabbed
    }
}

// MARK: - Balanced Refcounted System Cursor Hider (Zero Flicker)

/// Thread-safe, strictly balanced hardware cursor visibility manager.
///
/// - Loads `CGSMainConnectionID` / `SLSMainConnectionID` and `CGSSetConnectionProperty` /
///   `SLSSetConnectionProperty` via `dlsym` to enable `"SetsCursorInBackground"` cleanly with graceful fallback.
/// - Maintains exact `hideDepth` so `CGDisplayHideCursor` / `CGDisplayShowCursor` never leak hidden state.
/// - Never runs a blind 500ms `Show` + `Hide` flicker loop: only reasserts hide if `CGCursorIsVisible()` drifted.
public final class SystemCursorHider: Sendable {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias SetConnectionPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias CursorIsVisibleFn = @convention(c) () -> Int32

    private struct HiderState: Sendable {
        var hideDepth: Int = 0
        var backgroundPropertyConfigured: Bool = false
    }

    private struct GlobalHiderState: Sendable {
        var totalProcessHideDepth: Int = 0
        var cursorVisibleSymbolResolved: Bool = false
        var cursorVisibleSymbolAddress: UInt = 0
    }

    private static let globalState = OSAllocatedUnfairLock(initialState: GlobalHiderState())
    private let state = OSAllocatedUnfairLock(initialState: HiderState())

    public init() {}

    deinit {
        show()
    }

    public var hideDepth: Int {
        state.withLock(\.hideDepth)
    }

    public var isHidden: Bool {
        state.withLock { $0.hideDepth > 0 }
    }

    /// Current aggregate balanced hide depth across all `SystemCursorHider` instances in this process.
    public static var processHideDepth: Int {
        globalState.withLock(\.totalProcessHideDepth)
    }

    /// Acquires a balanced single-level cursor hide (idempotent while already hidden by this hider).
    public func hide() {
        ensureBackgroundCursorPermission()
        let acquired = state.withLock { s -> Bool in
            guard s.hideDepth == 0 else { return false }
            CGDisplayHideCursor(CGMainDisplayID())
            s.hideDepth = 1
            return true
        }
        if acquired {
            Self.globalState.withLock { $0.totalProcessHideDepth += 1 }
        }
    }

    /// Releases all hide levels acquired by this hider.
    public func show() {
        let released = state.withLock { s -> Int in
            var count = 0
            while s.hideDepth > 0 {
                CGDisplayShowCursor(CGMainDisplayID())
                s.hideDepth -= 1
                count += 1
            }
            return count
        }
        if released > 0 {
            Self.globalState.withLock { g in
                g.totalProcessHideDepth = max(0, g.totalProcessHideDepth - released)
            }
        }
    }

    /// Checks whether WindowServer externally unhid the cursor while we intend it to remain hidden.
    /// Calls `CGDisplayHideCursor` ONLY if `CGCursorIsVisible` (resolved via `dlsym`) reports visible —
    /// ZERO Show+Hide flicker!
    public func reassertHiddenIfDrifted() {
        let shouldCheck = state.withLock { $0.hideDepth > 0 }
        guard shouldCheck else { return }
        guard Self.querySystemCursorVisible() == true else { return }

        let reasserted = state.withLock { s -> Bool in
            guard s.hideDepth > 0 else { return false }
            CGDisplayHideCursor(CGMainDisplayID())
            return true
        }
        if reasserted {
            PipelineLog.shared.debug(.cursor, "Reasserted hidden OS cursor after external visibility drift (no Show+Hide flicker).")
        }
    }

    /// Unconditionally clears local hide depth and guarantees the system cursor is visible.
    public func forceRestore() {
        show()
        Self.emergencyRestoreAll()
    }

    /// Process-wide emergency restoration invoked by `RunGuardWatchdog`, panic stop, and exit hooks.
    public static func emergencyRestoreAll() {
        let mainDisplay = CGMainDisplayID()
        let remaining = globalState.withLock { g -> Int in
            let count = g.totalProcessHideDepth
            g.totalProcessHideDepth = 0
            return count
        }

        if remaining > 0 {
            for _ in 0..<remaining {
                CGDisplayShowCursor(mainDisplay)
            }
        } else {
            // CoreGraphics clamps per-connection hide depth at 0, so a single Show is safe & idempotent.
            CGDisplayShowCursor(mainDisplay)
        }

        var extraAttempts = 0
        while querySystemCursorVisible() == false && extraAttempts < 8 {
            CGDisplayShowCursor(mainDisplay)
            extraAttempts += 1
        }
    }

    /// Dynamically queries CoreGraphics `CGCursorIsVisible` via `dlsym` (returns `nil` if unavailable).
    public static func querySystemCursorVisible() -> Bool? {
        let addr: UInt = globalState.withLock { g in
            if !g.cursorVisibleSymbolResolved {
                g.cursorVisibleSymbolResolved = true
                let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
                if let sym = dlsym(rtldDefault, "CGCursorIsVisible") {
                    g.cursorVisibleSymbolAddress = UInt(bitPattern: sym)
                }
            }
            return g.cursorVisibleSymbolAddress
        }
        guard addr != 0, let ptr = UnsafeMutableRawPointer(bitPattern: addr) else {
            return nil
        }
        let fn = unsafeBitCast(ptr, to: CursorIsVisibleFn.self)
        return fn() != 0
    }

    private func ensureBackgroundCursorPermission() {
        let shouldConfigure = state.withLock { s -> Bool in
            guard !s.backgroundPropertyConfigured else { return false }
            s.backgroundPropertyConfigured = true
            return true
        }
        guard shouldConfigure else { return }

        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard
            let connSym = dlsym(rtldDefault, "CGSMainConnectionID") ?? dlsym(rtldDefault, "SLSMainConnectionID"),
            let propSym = dlsym(rtldDefault, "CGSSetConnectionProperty") ?? dlsym(rtldDefault, "SLSSetConnectionProperty")
        else {
            PipelineLog.shared.debug(.cursor, "CGS/SLS background cursor symbols unavailable; continuing with standard CGDisplayHideCursor.")
            return
        }

        let mainConnectionID = unsafeBitCast(connSym, to: MainConnectionIDFn.self)
        let setConnectionProperty = unsafeBitCast(propSym, to: SetConnectionPropertyFn.self)
        let cid = mainConnectionID()
        let status = setConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if status != 0 {
            PipelineLog.shared.debug(.cursor, "SetsCursorInBackground returned status \(status); continuing gracefully.")
        }
    }
}

// MARK: - Dynamic System Cursor Mirror (NSCursor.currentSystem)

@MainActor
private final class SystemCursorMirror {
    private var lastFingerprint: UInt64 = 0
    private var generation: UInt64 = 0
    private var cachedSnapshot: CursorImageSnapshot?

    func captureIfChanged(backingScaleFactor: Double) -> CursorImageSnapshot {
        let safeScale = max(1.0, backingScaleFactor)
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        let rawSize = image.size
        let pointSize = CGSize(
            width: rawSize.width > 0 ? rawSize.width : 24,
            height: rawSize.height > 0 ? rawSize.height : 24
        )
        let hotSpot = cursor.hotSpot

        var proposedRect = NSRect(origin: .zero, size: pointSize)
        let hints: [NSImageRep.HintKey: Any] = [
            .ctm: AffineTransform(scale: CGFloat(safeScale))
        ]

        let cgImage: CGImage?
        if let direct = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: hints) {
            cgImage = direct
        } else if let fallback = NSCursor.arrow.image.cgImage(forProposedRect: &proposedRect, context: nil, hints: hints) {
            cgImage = fallback
        } else {
            cgImage = nil
        }

        guard let resolvedCG = cgImage else {
            if let existing = cachedSnapshot {
                return existing
            }
            let empty = Self.makeFallbackArrowCGImage(scale: safeScale)
            generation &+= 1
            let snap = CursorImageSnapshot(
                cgImage: empty,
                pointSize: CGSize(width: 24, height: 24),
                hotSpot: CGPoint(x: 4, y: 4),
                backingScaleFactor: safeScale,
                generation: generation
            )
            cachedSnapshot = snap
            return snap
        }

        let fp = Self.computeFingerprint(
            cgImage: resolvedCG,
            pointSize: pointSize,
            hotSpot: hotSpot,
            backingScaleFactor: safeScale
        )

        if let existing = cachedSnapshot, fp == lastFingerprint {
            return existing
        }

        lastFingerprint = fp
        generation &+= 1
        let snapshot = CursorImageSnapshot(
            cgImage: resolvedCG,
            pointSize: pointSize,
            hotSpot: hotSpot,
            backingScaleFactor: safeScale,
            generation: generation
        )
        cachedSnapshot = snapshot
        return snapshot
    }

    private static func computeFingerprint(
        cgImage: CGImage,
        pointSize: CGSize,
        hotSpot: CGPoint,
        backingScaleFactor: Double
    ) -> UInt64 {
        var hash: UInt64 = 14695981039346656037 // FNV-1a 64-bit offset basis
        func mix(_ value: UInt64) {
            hash ^= value
            hash = hash &* 1099511628211
        }

        mix(UInt64(cgImage.width))
        mix(UInt64(cgImage.height))
        mix(UInt64(cgImage.bytesPerRow))
        mix(UInt64(pointSize.width.bitPattern))
        mix(UInt64(pointSize.height.bitPattern))
        mix(UInt64(hotSpot.x.bitPattern))
        mix(UInt64(hotSpot.y.bitPattern))
        mix(backingScaleFactor.bitPattern)

        if let cfData = cgImage.dataProvider?.data {
            let length = CFDataGetLength(cfData)
            mix(UInt64(length))
            if length > 0, let ptr = CFDataGetBytePtr(cfData) {
                let strideStep = max(1, length / 64)
                var idx = 0
                while idx < length {
                    mix(UInt64(ptr[idx]))
                    idx += strideStep
                }
                mix(UInt64(ptr[length - 1]))
            }
        }
        return hash
    }

    private static func makeFallbackArrowCGImage(scale: Double) -> CGImage {
        let sizePx = max(16, Int((24.0 * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        if let ctx = CGContext(
            data: nil,
            width: sizePx,
            height: sizePx,
            bitsPerComponent: 8,
            bytesPerRow: sizePx * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.setLineWidth(max(1.0, CGFloat(scale)))
            ctx.move(to: CGPoint(x: 2, y: CGFloat(sizePx - 2)))
            ctx.addLine(to: CGPoint(x: 2, y: CGFloat(sizePx) * 0.25))
            ctx.addLine(to: CGPoint(x: CGFloat(sizePx) * 0.65, y: CGFloat(sizePx) * 0.45))
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
            if let img = ctx.makeImage() {
                return img
            }
        }
        let data = Data(count: 4)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

// MARK: - Non-Activating CALayer Cursor Sprite Panel (Non-VRR Mode)

@MainActor
private final class NonActivatingCursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Never let AppKit shift the cursor overlay below the menu bar or clamp it onto the primary display
    /// (critical for exact Y-alignment on primary displays AND negative-CG-Y / diagonal secondary monitors!).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
internal final class CursorSpriteOverlayPanel {
    private var panel: NonActivatingCursorPanel?
    private let spriteLayer = CALayer()
    private var lastAppliedGeneration: UInt64 = 0
    private var lastOverlayCocoaFrame: CGRect = .zero
    private var currentLevel: NSWindow.Level = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow))
    )

    internal var isPanelVisibleForTesting: Bool {
        panel?.isVisible ?? false
    }

    internal var isSpriteLayerHiddenForTesting: Bool {
        spriteLayer.isHidden
    }

    internal var spriteLayerPositionForTesting: CGPoint {
        spriteLayer.position
    }

    init() {
        spriteLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "contents": NSNull(),
            "hidden": NSNull(),
            "opacity": NSNull(),
            "anchorPoint": NSNull(),
            "contentsScale": NSNull(),
            "magnificationFilter": NSNull(),
            "minificationFilter": NSNull()
        ]
        spriteLayer.isHidden = true
    }

    var windowID: CGWindowID? {
        guard let panel else { return nil }
        let num = panel.windowNumber
        return num > 0 ? CGWindowID(num) : nil
    }

    func setWindowLevel(_ level: NSWindow.Level) {
        currentLevel = level
        panel?.level = level
    }

    func apply(snapshot: CursorRenderSnapshot, overlayCocoaFrame: CGRect) {
        guard snapshot.presentationMode == .overlayLayer else {
            hide()
            return
        }

        guard snapshot.state.isVisible,
              let image = snapshot.image,
              let geometry = snapshot.spriteGeometry,
              !overlayCocoaFrame.isEmpty
        else {
            // Transient hide during active tracking (e.g. FPS mouse-grab, idle hide, unconfined escape):
            // ONLY toggle `spriteLayer.isHidden` inside `CATransaction` — NEVER call `panel?.orderOut(nil)`,
            // which tears down and recreates the WindowServer backing surface causing visible flicker!
            // (`orderOut` is reserved strictly for `hide()` / `close()` on suspend, stop, or VRR mode.)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spriteLayer.isHidden = true
            CATransaction.commit()
            CATransaction.flush()
            return
        }

        let activePanel = ensurePanel(frame: overlayCocoaFrame)
        if lastOverlayCocoaFrame != overlayCocoaFrame {
            activePanel.setFrame(overlayCocoaFrame, display: false)
            lastOverlayCocoaFrame = overlayCocoaFrame
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Update sprite position FIRST for minimal pointer-to-photon latency.
        spriteLayer.position = geometry.overlayLocalCocoaPosition
        spriteLayer.anchorPoint = geometry.layerAnchorPoint
        spriteLayer.bounds = CGRect(origin: .zero, size: geometry.scaledSize)

        if lastAppliedGeneration != image.generation {
            spriteLayer.contents = image.cgImage
            spriteLayer.contentsScale = CGFloat(image.backingScaleFactor)
            lastAppliedGeneration = image.generation
        }

        let useNearest = (snapshot.interpolation == .nearest) || abs(geometry.scaleFactor - 1.0) < 0.01
        let filter: CALayerContentsFilter = useNearest ? .nearest : .linear
        spriteLayer.magnificationFilter = filter
        spriteLayer.minificationFilter = filter

        spriteLayer.isHidden = false

        CATransaction.commit()
        CATransaction.flush()

        if !activePanel.isVisible {
            activePanel.orderFrontRegardless()
        }
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.isHidden = true
        CATransaction.commit()
        CATransaction.flush()
        panel?.orderOut(nil)
    }

    func close() {
        hide()
        spriteLayer.removeFromSuperlayer()
        panel?.close()
        panel = nil
        lastAppliedGeneration = 0
        lastOverlayCocoaFrame = .zero
    }

    private func ensurePanel(frame: CGRect) -> NonActivatingCursorPanel {
        if let panel {
            return panel
        }

        // CRITICAL: Always pass `screen: nil` when using global Cocoa coordinates!
        let newPanel = NonActivatingCursorPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: nil
        )
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.ignoresMouseEvents = true
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.level = currentLevel
        newPanel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let rootView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        rootView.wantsLayer = true
        rootView.autoresizingMask = [.width, .height]
        rootView.layer?.backgroundColor = CGColor.clear
        rootView.layer?.addSublayer(spriteLayer)

        newPanel.contentView = rootView
        panel = newPanel
        lastOverlayCocoaFrame = frame
        return newPanel
    }
}

// MARK: - Dedicated Event Tap Bridge (Zero-Closure, O(1)-Stack C Callback Context)

/// Memory-safe, zero-allocation bridge passed as `userInfo` (`refcon`) to `CGEvent.tapCreate`.
///
/// CRITICAL: Never store an optional Swift closure directly in `OSAllocatedUnfairLock<Closure?>`!
/// Reading an optional function via generic `inout` `withLock({ $0 })` causes Swift to emit
/// copy-in/copy-out reabstraction thunks on EVERY invocation, nesting thunks O(N) deep until
/// the event-tap thread overflows its 544 KB stack (`EXC_BAD_ACCESS` / `SIGBUS`).
/// Storing a concrete struct holding `weak var controller` eliminates closure boxing completely,
/// guarantees O(1) constant stack depth across millions of events, and allocates zero heap memory.
internal final class EventTapCallbackBox: @unchecked Sendable {
    private struct TargetState {
        weak var controller: CursorOverlayController?
    }

    private let targetLock: OSAllocatedUnfairLock<TargetState>

    init(controller: CursorOverlayController) {
        self.targetLock = OSAllocatedUnfairLock(uncheckedState: TargetState(controller: controller))
    }

    func invalidate() {
        targetLock.withLockUnchecked { $0.controller = nil }
    }

    func invoke(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let controller = targetLock.withLockUnchecked({ $0.controller }) else {
            return Unmanaged.passUnretained(event)
        }
        return controller.handleEventTap(proxy: proxy, type: type, event: event)
    }
}

// MARK: - CursorOverlayController (CursorControlling)

/// Zero-delta-drift cursor confinement, dynamic `NSCursor.currentSystem` mirroring, FPS mouse-grab detection,
/// and dual-output (non-VRR `CALayer` panel + VRR Metal compositor snapshot) cursor controller.
///
/// Conforms to `CursorControlling` from `MetalPieCore`.
public final class CursorOverlayController: CursorControlling, @unchecked Sendable {
    /// Unique 64-bit magic tag stamped onto `eventSourceUserData` for post-warp reposted
    /// `.scrollWheel` / `*MouseDown` events so `handleEventTap` passes them straight through in O(1).
    internal static let repostedEventMagicTag: Int64 = 0x4D50_4945_5245_5054

    private struct ControllerState: Sendable {
        var isActive: Bool = false
        var isSuspended: Bool = false
        var isHiddenForScreenshot: Bool = false
        var isUsingEventTap: Bool = false
        var alignmentMode: CursorAlignmentMode = .inactive
        var presentationMode: CursorPresentationMode
        var configuration: CursorMappingConfiguration?
        var mapping: PointerMapping?
        var displays: [DisplayDescriptor] = []
        var tapProcessor = CursorEventTapProcessor()
        var currentState = CursorOverlayState()
        var cachedCursorImage: CursorImageSnapshot?
        var latestRenderSnapshot = CursorRenderSnapshot()
        var onStateChange: (@Sendable (CursorOverlayState) -> Void)?
        var onAlignmentModeChange: (@Sendable (CursorAlignmentMode) -> Void)?
        var lastActivityUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        var lastPositionStateNotifyUptime: TimeInterval = 0
        var drawPending: Bool = false
        var shapeRefreshPending: Bool = false
        var suppressSystemWarpForTesting: Bool = false
        var recoveryToken: RunGuardWatchdog.RecoveryToken?
        var overlayWindowID: CGWindowID?
        var preferredWindowLevelRawValue: Int = Int(CGWindowLevelForKey(.popUpMenuWindow))
        var isPresentationWindowed: Bool = false
    }

    private struct TapRuntime {
        var thread: Thread?
        var runLoop: CFRunLoop?
        var tapPort: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var callbackBox: EventTapCallbackBox?
    }

    private let state: OSAllocatedUnfairLock<ControllerState>
    private let tapRuntime = OSAllocatedUnfairLock(uncheckedState: TapRuntime())
    private let cursorHider = SystemCursorHider()
    private let requireAccessibilityForScaledMode: Bool
    private let watchdog: RunGuardWatchdog
    /// Pre-configured event source with `localEventsSuppressionInterval = 0.0` so warps and
    /// post-warp reposts never trigger macOS's default 250ms local hardware event stall.
    private let warpEventSource: CGEventSource? = {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.localEventsSuppressionInterval = 0.0
        return src
    }()

    // Timer queue for idle auto-hide, fallback cursor polling (when AX denied), and low-cost drift check.
    private let maintenanceQueue = DispatchQueue(
        label: "com.metalpie.input.cursor.maintenance",
        qos: .userInteractive
    )
    private let maintenanceTimerLock = OSAllocatedUnfairLock<(any DispatchSourceTimer)?>(uncheckedState: nil)

    // MainActor-only UI objects: `spritePanelLock` allows safe atomic extraction in `stop()` / `deinit`
    // from any thread without racing or losing the panel reference via `[weak self]`.
    private let spritePanelLock = OSAllocatedUnfairLock<CursorSpriteOverlayPanel?>(uncheckedState: nil)
    private nonisolated(unsafe) var cursorMirror: SystemCursorMirror?

    public init(
        presentationMode: CursorPresentationMode = .overlayLayer,
        requireAccessibilityForScaledMode: Bool = false,
        watchdog: RunGuardWatchdog = .shared
    ) {
        self.requireAccessibilityForScaledMode = requireAccessibilityForScaledMode
        self.watchdog = watchdog
        self.state = OSAllocatedUnfairLock(
            initialState: ControllerState(presentationMode: presentationMode)
        )
        refreshDisplayMenuBarHeights()
    }

    deinit {
        stop()
    }

    // MARK: - CursorControlling Properties

    public var isActive: Bool {
        state.withLock(\.isActive)
    }

    public var currentState: CursorOverlayState {
        state.withLock(\.currentState)
    }

    /// True if the controller is temporarily suspended (e.g. target lost focus).
    public var isSuspended: Bool {
        state.withLock(\.isSuspended)
    }

    /// True if a `CGEventTap` is currently running on the dedicated `.userInteractive` thread.
    public var isEventTapRunning: Bool {
        state.withLock(\.isUsingEventTap)
    }

    /// Current cursor alignment operating mode (`.inactive`, `.identityPassthrough`,
    /// `.scaledConfinedEventTap`, or `.accessibilityRequired`).
    public var alignmentMode: CursorAlignmentMode {
        state.withLock(\.alignmentMode)
    }

    /// True when the active session is scaling non-1:1 without Accessibility permission so macOS
    /// cannot confine or align mouse clicks (UI should prompt the user to enable Accessibility!).
    public var isAccessibilityRequiredForAlignment: Bool {
        state.withLock { $0.alignmentMode == .accessibilityRequired }
    }

    /// Latest render snapshot (state + `NSCursor.currentSystem` CGImage + hotspot geometry) for VRR Metal pass.
    public var latestRenderSnapshot: CursorRenderSnapshot {
        state.withLock(\.latestRenderSnapshot)
    }

    /// The `CGWindowID` of the non-VRR cursor sprite overlay panel, if currently created (for exclusion lists).
    public var cursorOverlayWindowID: CGWindowID? {
        state.withLock(\.overlayWindowID)
    }

    // MARK: - Configuration & Output Mode Controls

    /// Registers an optional callback fired whenever `alignmentMode` transitions (e.g. `.accessibilityRequired`
    /// -> `.scaledConfinedEventTap` upon live Accessibility grant!).
    public func setAlignmentModeHandler(_ handler: (@Sendable (CursorAlignmentMode) -> Void)?) {
        state.withLock { $0.onAlignmentModeChange = handler }
    }

    /// Switches between non-VRR `CALayer` sprite panel and VRR direct-scanout external compositor output.
    public func setPresentationMode(_ mode: CursorPresentationMode) {
        let shouldRedraw = state.withLock { s -> Bool in
            guard s.presentationMode != mode else { return false }
            s.presentationMode = mode
            s.latestRenderSnapshot.presentationMode = mode
            return s.isActive
        }
        guard shouldRedraw else { return }

        if mode == .externalCompositor {
            hideSpritePanelOnMain()
        } else {
            scheduleVisualPositionUpdate()
            scheduleCursorShapeRefresh()
        }
    }

    /// Updates the window level of the non-VRR cursor sprite panel (e.g. level 20 for Full-Screen Space mode).
    public func setOverlayWindowLevel(_ level: NSWindow.Level) {
        let rawLevel = level.rawValue
        state.withLock { $0.preferredWindowLevelRawValue = rawLevel }
        let panel = spritePanelLock.withLockUnchecked { $0 }
        guard let panel else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                panel.setWindowLevel(NSWindow.Level(rawValue: rawLevel))
            }
        }
    }

    /// Updates the attached display list used for reachable confinement and `ScreenGeometry` conversions.
    public func updateDisplays(_ displays: [DisplayDescriptor]) {
        refreshDisplayMenuBarHeights()
        let updatedConfig = state.withLock { s -> CursorMappingConfiguration? in
            s.displays = displays
            guard let config = s.configuration else { return nil }
            let mapping = PointerMapping(configuration: config, displays: displays)
            s.mapping = mapping
            if s.tapProcessor.interactionMode == .scaled,
               !s.tapProcessor.activeWindowBorderDrag,
               let currentVirtual = s.tapProcessor.virtualSourcePosition
            {
                let effective = mapping.settings.confineCursor && !mapping.isIdentity
                    ? mapping.constrainSourcePoint(currentVirtual).point
                    : currentVirtual
                s.tapProcessor.virtualSourcePosition = effective
                s.currentState.scaledCGPosition = mapping.mapSourceToScaled(effective, clampToContent: true)
                s.latestRenderSnapshot.state = s.currentState
            }
            return config
        }
        if updatedConfig != nil {
            scheduleVisualPositionUpdate()
        }
    }

    /// Updates visible interactive MetalPie floating chrome rects (toolbar / HUD) in global CG (Y-down)
    /// logical coordinates so clicks/drags on MetalPie's own buttons bypass source-window remapping.
    public func updateInteractiveChromeRects(_ cgRects: [CGRect]) {
        let normalized = cgRects.map(\.standardized).filter { !$0.isEmpty }
        let now = ProcessInfo.processInfo.systemUptime

        let transition = state.withLock { s -> (
            osCursorHide: Bool?,
            warpTarget: CGPoint?,
            reassociate: Bool,
            visibilityChanged: Bool
        ) in
            s.tapProcessor.interactiveChromeRects = normalized
            guard s.isActive, !s.isSuspended, s.isUsingEventTap,
                  let mapping = s.mapping, mapping.isValid, !mapping.isIdentity
            else {
                return (nil, nil, true, false)
            }

            let prevVisible = s.currentState.isVisible
            let prevNative = (s.tapProcessor.interactionMode != .scaled)
            var warpTarget: CGPoint? = nil

            if s.tapProcessor.interactionMode == .directChrome,
               !s.tapProcessor.activeChromeDrag,
               s.tapProcessor.pressedButtonsMask == 0
            {
                let ptr = s.tapProcessor.lastPhysicalLocation ?? s.currentState.scaledCGPosition
                if !s.tapProcessor.isPointInInteractiveChrome(ptr) {
                    let enforceConfinement = mapping.settings.confineCursor || mapping.threeDGameMode
                    if s.isPresentationWindowed && !mapping.threeDGameMode && !mapping.overlayRect.contains(ptr) {
                        s.tapProcessor.interactionMode = .outsideWindowedOverlay
                    } else if !s.isPresentationWindowed && !mapping.threeDGameMode && s.tapProcessor.hostMenuBarRect(for: mapping).contains(ptr) {
                        s.tapProcessor.interactionMode = .menuBarPassthrough
                    } else if !enforceConfinement && !mapping.isPointInsideSource(ptr) {
                        s.tapProcessor.interactionMode = .unconfinedOutsideSource
                        s.tapProcessor.isPointerOutsideUnconfinedSource = true
                    } else {
                        let mapped = mapping.mapScaledToSource(ptr, clampToSource: true)
                        let entry = enforceConfinement ? mapping.constrainSourcePoint(mapped).point : mapped
                        s.tapProcessor.interactionMode = .scaled
                        s.tapProcessor.isPointerOutsideUnconfinedSource = false
                        s.tapProcessor.virtualSourcePosition = entry
                        s.tapProcessor.lastPhysicalLocation = ptr
                        s.currentState.scaledCGPosition = mapping.mapSourceToScaled(entry, clampToContent: true)
                        if !mapping.settings.adjustCursorSpeed && hypot(ptr.x - entry.x, ptr.y - entry.y) >= 1.0 {
                            s.tapProcessor.recordExternalWarp(from: ptr, to: entry, timestamp: now)
                            warpTarget = entry
                        }
                    }
                }
            } else if s.tapProcessor.interactionMode == .scaled,
                      s.tapProcessor.pressedButtonsMask == 0,
                      !s.currentState.isMouseGrabbedByGame,
                      !mapping.threeDGameMode,
                      !normalized.isEmpty
            {
                let visualPos = s.currentState.scaledCGPosition
                if s.tapProcessor.isPointInInteractiveChrome(visualPos) {
                    let fromPt = s.tapProcessor.lastPhysicalLocation ?? visualPos
                    s.tapProcessor.interactionMode = .directChrome
                    s.tapProcessor.virtualSourcePosition = visualPos
                    if hypot(fromPt.x - visualPos.x, fromPt.y - visualPos.y) >= 1.0 {
                        s.tapProcessor.recordExternalWarp(from: fromPt, to: visualPos, timestamp: now)
                        warpTarget = visualPos
                    }
                }
            }

            Self.recomputeVisibilityLocked(&s)
            s.latestRenderSnapshot.state = s.currentState
            let newNative = (s.tapProcessor.interactionMode != .scaled)
            let osHide: Bool? = (prevNative != newNative) ? !newNative : nil
            return (osHide, warpTarget, !mapping.threeDGameMode, prevVisible != s.currentState.isVisible)
        }

        if let wt = transition.warpTarget {
            performCursorWarp(to: wt, reassociateMouse: transition.reassociate)
        }
        if let shouldHide = transition.osCursorHide {
            if shouldHide {
                cursorHider.hide()
            } else {
                cursorHider.show()
            }
        }
        if transition.visibilityChanged {
            scheduleVisualPositionUpdate()
            notifyStateChange()
        }
    }

    /// Configures whether the active scaling session is windowed (not fullscreen). In windowed mode
    /// (outside 3D Game Mode), moving outside the scaled overlay releases confinement smoothly so the
    /// user can freely click macOS's Menu Bar, Dock, and other windows.
    public func setPresentationIsWindowed(_ isWindowed: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let transition = state.withLock { s -> (
            osCursorHide: Bool?,
            warpTarget: CGPoint?,
            reassociate: Bool,
            visibilityChanged: Bool
        ) in
            s.isPresentationWindowed = isWindowed
            s.tapProcessor.isPresentationWindowed = isWindowed

            guard s.isActive, !s.isSuspended, s.isUsingEventTap,
                  let mapping = s.mapping, mapping.isValid, !mapping.isIdentity
            else {
                return (nil, nil, true, false)
            }

            let prevVisible = s.currentState.isVisible
            let prevNative = (s.tapProcessor.interactionMode != .scaled)
            var warpTarget: CGPoint? = nil

            if !isWindowed && s.tapProcessor.interactionMode == .outsideWindowedOverlay {
                let ptr = s.tapProcessor.lastPhysicalLocation ?? Self.currentCGPointerLocation()
                let placed = mapping.safeInitialSourcePoint(from: ptr)
                s.tapProcessor.interactionMode = .scaled
                s.tapProcessor.isPointerOutsideUnconfinedSource = false
                s.tapProcessor.virtualSourcePosition = placed.point
                s.tapProcessor.lastPhysicalLocation = ptr
                s.currentState.scaledCGPosition = mapping.mapSourceToScaled(placed.point, clampToContent: true)
                if placed.shouldWarp {
                    s.tapProcessor.recordExternalWarp(from: ptr, to: placed.point, timestamp: now)
                    warpTarget = placed.point
                }
            } else if isWindowed && !mapping.threeDGameMode &&
                        s.tapProcessor.interactionMode == .menuBarPassthrough &&
                        !s.tapProcessor.menuBarDropdownActive
            {
                let ptr = s.tapProcessor.lastPhysicalLocation ?? s.currentState.scaledCGPosition
                if !mapping.overlayRect.contains(ptr) {
                    s.tapProcessor.interactionMode = .outsideWindowedOverlay
                }
            }

            Self.recomputeVisibilityLocked(&s)
            s.latestRenderSnapshot.state = s.currentState
            let newNative = (s.tapProcessor.interactionMode != .scaled)
            let osHide: Bool? = (prevNative != newNative) ? !newNative : nil
            return (osHide, warpTarget, !mapping.threeDGameMode, prevVisible != s.currentState.isVisible)
        }

        if let wt = transition.warpTarget {
            performCursorWarp(to: wt, reassociateMouse: transition.reassociate)
        }
        if let shouldHide = transition.osCursorHide {
            if shouldHide {
                cursorHider.hide()
            } else {
                cursorHider.show()
            }
        }
        if transition.visibilityChanged {
            scheduleVisualPositionUpdate()
            notifyStateChange()
        }
    }

    /// Instantly hides or restores the cursor sprite during screenshot capture (respecting `hideInScreenshots`).
    public func setHiddenForScreenshot(_ hidden: Bool) {
        let changed = state.withLock { s -> Bool in
            let effectiveHidden = hidden && (s.configuration?.settings.hideInScreenshots ?? true)
            guard s.isHiddenForScreenshot != effectiveHidden else { return false }
            s.isHiddenForScreenshot = effectiveHidden
            Self.recomputeVisibilityLocked(&s)
            return true
        }
        guard changed else { return }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.flushVisualPositionOnMainActor()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self.flushVisualPositionOnMainActor()
                }
            }
        }
    }

    // MARK: - CursorControlling Lifecycle

    public func start(
        configuration: CursorMappingConfiguration,
        onStateChange: @escaping @Sendable (CursorOverlayState) -> Void
    ) throws {
        stop()

        let existingDisplays = state.withLock(\.displays)
        let displays = existingDisplays.isEmpty ? Self.snapshotCurrentDisplays() : existingDisplays
        refreshDisplayMenuBarHeights()
        let mapping = PointerMapping(configuration: configuration, displays: displays)
        let axGranted = AXIsProcessTrusted()

        if mapping.requiresEventTap && !axGranted && requireAccessibilityForScaledMode {
            throw EngineError.accessibilityPermissionDenied
        }

        let recoveryToken = watchdog.registerRecoveryHandler(name: "CursorOverlayController") { [weak self] in
            self?.emergencyStopFromWatchdog()
        }

        let now = ProcessInfo.processInfo.systemUptime
        let initialPointer = Self.currentCGPointerLocation()
        let isWindowed = state.withLock(\.isPresentationWindowed)
        let initialMode: CursorPointerInteractionMode
        let initialPlacement: (point: CGPoint, shouldWarp: Bool)
        if isWindowed && !configuration.threeDGameMode && !mapping.isIdentity {
            if state.withLock({ $0.tapProcessor.isPointInInteractiveChrome(initialPointer) }) {
                initialMode = .directChrome
                initialPlacement = (initialPointer, false)
            } else if !mapping.overlayRect.contains(initialPointer) {
                initialMode = .outsideWindowedOverlay
                initialPlacement = (initialPointer, false)
            } else {
                initialMode = .scaled
                let mapped = mapping.mapScaledToSource(initialPointer, clampToSource: true)
                let entry = mapping.settings.confineCursor ? mapping.constrainSourcePoint(mapped).point : mapped
                let needsWarp = !mapping.settings.adjustCursorSpeed && hypot(initialPointer.x - entry.x, initialPointer.y - entry.y) >= 1.0
                initialPlacement = (entry, needsWarp)
            }
        } else if (mapping.settings.confineCursor || configuration.threeDGameMode) && !mapping.isIdentity {
            initialMode = .scaled
            initialPlacement = mapping.safeInitialSourcePoint(from: initialPointer)
        } else {
            initialMode = (!mapping.settings.confineCursor && !configuration.threeDGameMode && !mapping.isPointInsideSource(initialPointer))
                ? .unconfinedOutsideSource
                : .scaled
            initialPlacement = (initialPointer, false)
        }
        let scaledInitial = (initialMode == .scaled)
            ? mapping.mapSourceToScaled(initialPlacement.point, clampToContent: true)
            : initialPlacement.point

        state.withLock { s in
            s.isActive = true
            s.isSuspended = false
            s.isHiddenForScreenshot = false
            s.configuration = configuration
            s.displays = displays
            s.mapping = mapping
            s.tapProcessor.isPresentationWindowed = s.isPresentationWindowed
            s.tapProcessor.reset(
                initialSourcePosition: initialPlacement.point,
                physicalLocation: initialPointer
            )
            s.tapProcessor.interactionMode = initialMode
            s.tapProcessor.isPointerOutsideUnconfinedSource = (initialMode == .unconfinedOutsideSource)
            s.onStateChange = onStateChange
            s.lastActivityUptime = now
            s.recoveryToken = recoveryToken
            s.alignmentMode = .inactive
            s.currentState = CursorOverlayState(
                isVisible: false,
                scaledCGPosition: scaledInitial,
                scaleFactor: mapping.effectiveCursorScaleFactor,
                isMouseGrabbedByGame: false,
                isIdleHidden: false
            )
            s.latestRenderSnapshot = CursorRenderSnapshot(
                state: s.currentState,
                image: s.cachedCursorImage,
                spriteGeometry: nil,
                interpolation: configuration.settings.interpolation,
                presentationMode: s.presentationMode,
                alignmentMode: .inactive
            )
        }

        if mapping.isIdentity && !configuration.threeDGameMode {
            // 1:1 Identity passthrough: zero Accessibility requirement, zero event tap, native OS cursor.
            setAlignmentMode(.identityPassthrough)
            PipelineLog.shared.info(.cursor, "CursorOverlayController started in 1:1 identity passthrough mode (no Accessibility needed).")
            notifyStateChange()
            return
        }

        var tapStarted = false
        if mapping.requiresEventTap {
            if axGranted {
                tapStarted = startEventTapThread()
                if !tapStarted {
                    PipelineLog.shared.warning(
                        .cursor,
                        "CGEventTap creation failed despite Accessibility trust; keeping native OS cursor visible and reporting accessibilityRequired."
                    )
                }
            } else {
                PipelineLog.shared.warning(
                    .cursor,
                    "Accessibility permission denied for non-1:1 scaling; keeping native OS cursor visible and hiding scaled sprite to avoid misaligned clicks."
                )
            }
        }

        let didStartTap = tapStarted
        let resolvedMode: CursorAlignmentMode = didStartTap
            ? .scaledConfinedEventTap
            : (mapping.requiresEventTap ? .accessibilityRequired : .identityPassthrough)

        state.withLock { s in
            s.isUsingEventTap = didStartTap
            s.alignmentMode = resolvedMode
            s.latestRenderSnapshot.alignmentMode = resolvedMode
            if didStartTap && (mapping.requiresScaledOverlayCursor || configuration.threeDGameMode) {
                if !mapping.settings.confineCursor && !configuration.threeDGameMode && s.tapProcessor.interactionMode == .scaled {
                    let outside = !mapping.isPointInsideSource(initialPlacement.point)
                    s.tapProcessor.isPointerOutsideUnconfinedSource = outside
                    if outside {
                        s.tapProcessor.interactionMode = .unconfinedOutsideSource
                    }
                }
                Self.recomputeVisibilityLocked(&s)
            } else {
                // NEVER draw a misleading remapped cursor sprite when OS clicks cannot be confined/aligned!
                s.currentState.isVisible = false
            }
            s.latestRenderSnapshot.state = s.currentState
        }

        if didStartTap && (mapping.requiresScaledOverlayCursor || configuration.threeDGameMode) {
            let isNativeMode = state.withLock { $0.tapProcessor.interactionMode != .scaled }
            if !isNativeMode {
                cursorHider.hide()
                if (mapping.settings.confineCursor || configuration.threeDGameMode) && initialPlacement.shouldWarp {
                    recordWarp(from: initialPointer, to: initialPlacement.point)
                    performCursorWarp(to: initialPlacement.point, reassociateMouse: !configuration.threeDGameMode)
                }
            } else {
                cursorHider.show()
            }
        } else {
            cursorHider.show()
            hideSpritePanelOnMain()
        }

        startMaintenanceTimer(pollingMode: !didStartTap)
        if didStartTap {
            scheduleVisualPositionUpdate()
            scheduleCursorShapeRefresh()
        }
        notifyAlignmentMode(resolvedMode)
        notifyStateChange()

        PipelineLog.shared.info(
            .cursor,
            "CursorOverlayController started (mode: \(resolvedMode.rawValue), eventTap: \(didStartTap), identity: \(mapping.isIdentity), 3DMode: \(configuration.threeDGameMode), scale: \(String(format: "%.2fx", mapping.averageScale)))."
        )
    }

    public func update(configuration: CursorMappingConfiguration) {
        let transition = state.withLock { s -> (
            active: Bool,
            needsTapChange: Bool,
            shouldHaveTap: Bool,
            shouldHideOS: Bool,
            mapping: PointerMapping,
            prevMode: CursorAlignmentMode
        )? in
            guard s.isActive else { return nil }
            let displays = s.displays.isEmpty ? Self.snapshotCurrentDisplays() : s.displays
            let mapping = PointerMapping(configuration: configuration, displays: displays)
            let prevMode = s.alignmentMode
            s.configuration = configuration
            s.displays = displays
            s.mapping = mapping
            s.currentState.scaleFactor = mapping.effectiveCursorScaleFactor
            s.latestRenderSnapshot.interpolation = configuration.settings.interpolation

            let axGranted = AXIsProcessTrusted()
            let shouldHaveTap = !s.isSuspended && mapping.requiresEventTap && axGranted
            let needsTapChange = (shouldHaveTap != s.isUsingEventTap)
            let shouldHideOS = !s.isSuspended && shouldHaveTap && (mapping.requiresScaledOverlayCursor || configuration.threeDGameMode)

            return (true, needsTapChange, shouldHaveTap, shouldHideOS, mapping, prevMode)
        }

        guard let transition, transition.active else { return }

        var justStartedTap = false
        if transition.needsTapChange {
            if transition.shouldHaveTap {
                let started = startEventTapThread()
                justStartedTap = started
                state.withLock { $0.isUsingEventTap = started }
                startMaintenanceTimer(pollingMode: !started)
            } else {
                stopEventTapThread()
                state.withLock { $0.isUsingEventTap = false }
                let stillScaled = !transition.mapping.isIdentity
                if stillScaled {
                    startMaintenanceTimer(pollingMode: true)
                } else {
                    stopMaintenanceTimer()
                }
            }
        }

        let tapActive = state.withLock(\.isUsingEventTap)
        let resolvedMode: CursorAlignmentMode
        if transition.mapping.isIdentity && !configuration.threeDGameMode {
            resolvedMode = .identityPassthrough
        } else if tapActive {
            resolvedMode = .scaledConfinedEventTap
        } else if transition.mapping.requiresEventTap {
            resolvedMode = .accessibilityRequired
        } else {
            resolvedMode = .identityPassthrough
        }

        let startedTapNow = justStartedTap
        let warpSpec: (from: CGPoint, to: CGPoint)? = state.withLock { s in
            s.alignmentMode = resolvedMode
            s.latestRenderSnapshot.alignmentMode = resolvedMode

            let mapping = transition.mapping
            let enforceConfinement = mapping.settings.confineCursor || configuration.threeDGameMode

            var pendingWarpSpec: (from: CGPoint, to: CGPoint)? = nil
            if tapActive && !s.isSuspended && !mapping.isIdentity {
                let currentPhysical = Self.currentCGPointerLocation()
                if configuration.threeDGameMode &&
                    (s.tapProcessor.interactionMode == .outsideWindowedOverlay || s.tapProcessor.interactionMode == .menuBarPassthrough)
                {
                    s.tapProcessor.interactionMode = .scaled
                    s.tapProcessor.menuBarDropdownActive = false
                    s.tapProcessor.menuBarDropdownDismissPendingOnUp = false
                }

                if s.tapProcessor.interactionMode != .scaled && !startedTapNow {
                    // Preserve active native chrome / menu-bar / outside-windowed interaction across layout updates!
                    s.currentState.isVisible = false
                } else if s.tapProcessor.activeWindowBorderDrag && !startedTapNow {
                    // Bug #5: Never clamp or warp `virtualSourcePosition` back into `confinementRect` mid-resize!
                    let currentRef = s.tapProcessor.virtualSourcePosition ?? currentPhysical
                    let clampedDisplay = mapping.clampPointToDisplays(currentRef)
                    s.tapProcessor.virtualSourcePosition = clampedDisplay
                    s.currentState.scaledCGPosition = mapping.clampPointToDisplays(
                        mapping.mapSourceToScaled(clampedDisplay, clampToContent: false)
                    )
                    Self.recomputeVisibilityLocked(&s)
                } else {
                    let currentRef = startedTapNow
                        ? currentPhysical
                        : (s.tapProcessor.virtualSourcePosition ?? currentPhysical)

                    if enforceConfinement {
                        if startedTapNow {
                            if s.isPresentationWindowed && !configuration.threeDGameMode && !mapping.overlayRect.contains(currentPhysical) {
                                s.tapProcessor.reset(
                                    initialSourcePosition: currentPhysical,
                                    physicalLocation: currentPhysical
                                )
                                s.tapProcessor.interactionMode = .outsideWindowedOverlay
                            } else {
                                let placed = mapping.safeInitialSourcePoint(from: currentRef)
                                s.tapProcessor.reset(
                                    initialSourcePosition: placed.point,
                                    physicalLocation: currentPhysical
                                )
                                if placed.shouldWarp {
                                    pendingWarpSpec = (from: currentPhysical, to: placed.point)
                                }
                            }
                        } else {
                            let constrained = mapping.constrainSourcePoint(currentRef)
                            s.tapProcessor.virtualSourcePosition = constrained.point
                            if constrained.wasClamped {
                                let fromPt = s.tapProcessor.lastPhysicalLocation ?? currentPhysical
                                pendingWarpSpec = (from: fromPt, to: constrained.point)
                            }
                        }
                        s.tapProcessor.isPointerOutsideUnconfinedSource = false
                    } else {
                        s.tapProcessor.virtualSourcePosition = currentRef
                        let outside = !mapping.isPointInsideSource(currentRef)
                        s.tapProcessor.isPointerOutsideUnconfinedSource = outside
                        s.tapProcessor.interactionMode = outside ? .unconfinedOutsideSource : .scaled
                    }

                    let finalSource = s.tapProcessor.virtualSourcePosition ?? currentRef
                    s.currentState.scaledCGPosition = (s.tapProcessor.interactionMode == .scaled)
                        ? mapping.mapSourceToScaled(finalSource, clampToContent: true)
                        : finalSource
                    Self.recomputeVisibilityLocked(&s)
                }
            } else {
                let curPtr = Self.currentCGPointerLocation()
                s.tapProcessor.virtualSourcePosition = curPtr
                s.tapProcessor.lastPhysicalLocation = curPtr
                s.tapProcessor.isPointerOutsideUnconfinedSource = false
                s.tapProcessor.interactionMode = .scaled
                s.currentState.scaledCGPosition = mapping.mapSourceToScaled(curPtr, clampToContent: true)
                s.currentState.isVisible = false
            }

            s.latestRenderSnapshot.state = s.currentState
            if let img = s.cachedCursorImage {
                s.latestRenderSnapshot.spriteGeometry = mapping.spriteGeometry(
                    forScaledPoint: s.currentState.scaledCGPosition,
                    cursorPointSize: img.pointSize,
                    hotSpot: img.hotSpot
                )
            }
            return pendingWarpSpec
        }

        let isNativeMode = state.withLock { $0.tapProcessor.interactionMode != .scaled }
        if transition.shouldHideOS && tapActive && !isNativeMode {
            cursorHider.hide()
            if let wp = warpSpec {
                recordWarp(from: wp.from, to: wp.to)
                performCursorWarp(to: wp.to, reassociateMouse: !configuration.threeDGameMode)
            }
            scheduleVisualPositionUpdate()
            scheduleCursorShapeRefresh()
        } else {
            cursorHider.show()
            hideSpritePanelOnMain()
        }

        if resolvedMode != transition.prevMode {
            notifyAlignmentMode(resolvedMode)
        }
        notifyStateChange()
    }

    public func suspend() {
        let shouldSuspend = state.withLock { s -> Bool in
            guard s.isActive, !s.isSuspended else { return false }
            s.isSuspended = true
            s.currentState.isVisible = false
            s.currentState.isMouseGrabbedByGame = false
            s.currentState.isIdleHidden = false
            s.tapProcessor.reset()
            s.latestRenderSnapshot.state = s.currentState
            return true
        }
        guard shouldSuspend else { return }

        // Always restore OS hardware cursor immediately and pause tap interception.
        cursorHider.show()
        setEventTapEnabled(false)
        hideSpritePanelOnMain()

        notifyStateChange()
        PipelineLog.shared.debug(.cursor, "CursorOverlayController suspended (OS cursor restored).")
    }

    public func resume() {
        let resumeInfo = state.withLock { s -> (
            shouldTap: Bool,
            shouldHideOS: Bool,
            mapping: PointerMapping,
            currentPtr: CGPoint,
            placement: (point: CGPoint, shouldWarp: Bool),
            prevMode: CursorAlignmentMode
        )? in
            guard s.isActive, s.isSuspended, let mapping = s.mapping else { return nil }
            let prevMode = s.alignmentMode
            s.isSuspended = false
            s.lastActivityUptime = ProcessInfo.processInfo.systemUptime
            s.currentState.isIdleHidden = false

            let currentPtr = Self.currentCGPointerLocation()
            let enforceConfinement = (mapping.settings.confineCursor || mapping.threeDGameMode) && !mapping.isIdentity
            let resumeMode: CursorPointerInteractionMode
            let placement: (point: CGPoint, shouldWarp: Bool)
            if s.isPresentationWindowed && !mapping.threeDGameMode && !mapping.isIdentity {
                if s.tapProcessor.isPointInInteractiveChrome(currentPtr) {
                    resumeMode = .directChrome
                    placement = (point: currentPtr, shouldWarp: false)
                } else if !mapping.overlayRect.contains(currentPtr) {
                    resumeMode = .outsideWindowedOverlay
                    placement = (point: currentPtr, shouldWarp: false)
                } else {
                    resumeMode = .scaled
                    let mapped = mapping.mapScaledToSource(currentPtr, clampToSource: true)
                    let entry = enforceConfinement ? mapping.constrainSourcePoint(mapped).point : mapped
                    let needsWarp = !mapping.settings.adjustCursorSpeed && hypot(currentPtr.x - entry.x, currentPtr.y - entry.y) >= 1.0
                    placement = (point: entry, shouldWarp: needsWarp)
                }
            } else if enforceConfinement {
                resumeMode = .scaled
                placement = mapping.safeInitialSourcePoint(from: currentPtr)
            } else {
                resumeMode = (!mapping.settings.confineCursor && !mapping.threeDGameMode && !mapping.isPointInsideSource(currentPtr))
                    ? .unconfinedOutsideSource
                    : .scaled
                placement = (point: currentPtr, shouldWarp: false)
            }

            s.tapProcessor.isPresentationWindowed = s.isPresentationWindowed
            s.tapProcessor.reset(
                initialSourcePosition: placement.point,
                physicalLocation: currentPtr
            )
            s.tapProcessor.interactionMode = resumeMode
            s.tapProcessor.isPointerOutsideUnconfinedSource = (resumeMode == .unconfinedOutsideSource)
            s.currentState.scaledCGPosition = (resumeMode == .scaled)
                ? mapping.mapSourceToScaled(placement.point, clampToContent: true)
                : placement.point

            let axGranted = AXIsProcessTrusted()
            let shouldTap = mapping.requiresEventTap && axGranted
            let shouldHideOS = shouldTap && (mapping.requiresScaledOverlayCursor || mapping.threeDGameMode)
            return (shouldTap, shouldHideOS, mapping, currentPtr, placement, prevMode)
        }

        guard let resumeInfo else { return }

        if resumeInfo.shouldTap {
            if state.withLock(\.isUsingEventTap) {
                setEventTapEnabled(true)
            } else {
                let started = startEventTapThread()
                state.withLock { $0.isUsingEventTap = started }
            }
        }

        let tapActive = state.withLock(\.isUsingEventTap)
        let resolvedMode: CursorAlignmentMode
        if resumeInfo.mapping.isIdentity && !resumeInfo.mapping.threeDGameMode {
            resolvedMode = .identityPassthrough
        } else if tapActive {
            resolvedMode = .scaledConfinedEventTap
        } else if resumeInfo.mapping.requiresEventTap {
            resolvedMode = .accessibilityRequired
        } else {
            resolvedMode = .identityPassthrough
        }

        state.withLock { s in
            s.alignmentMode = resolvedMode
            s.latestRenderSnapshot.alignmentMode = resolvedMode
            if !resumeInfo.mapping.settings.confineCursor && !resumeInfo.mapping.threeDGameMode && s.tapProcessor.interactionMode == .scaled {
                let outside = !resumeInfo.mapping.isPointInsideSource(resumeInfo.placement.point)
                s.tapProcessor.isPointerOutsideUnconfinedSource = outside
                if outside {
                    s.tapProcessor.interactionMode = .unconfinedOutsideSource
                }
            }
            if resumeInfo.shouldHideOS && tapActive {
                Self.recomputeVisibilityLocked(&s)
            } else {
                s.currentState.isVisible = false
            }
            s.latestRenderSnapshot.state = s.currentState
        }

        let isNativeMode = state.withLock { $0.tapProcessor.interactionMode != .scaled }
        if resumeInfo.shouldHideOS && tapActive && !isNativeMode {
            cursorHider.hide()
            if (resumeInfo.mapping.settings.confineCursor || resumeInfo.mapping.threeDGameMode) && resumeInfo.placement.shouldWarp {
                recordWarp(from: resumeInfo.currentPtr, to: resumeInfo.placement.point)
                performCursorWarp(to: resumeInfo.placement.point, reassociateMouse: !resumeInfo.mapping.threeDGameMode)
            }
            scheduleVisualPositionUpdate()
            scheduleCursorShapeRefresh()
        } else {
            cursorHider.show()
            hideSpritePanelOnMain()
        }

        if resolvedMode != resumeInfo.prevMode {
            notifyAlignmentMode(resolvedMode)
        }
        notifyStateChange()
        PipelineLog.shared.debug(.cursor, "CursorOverlayController resumed (mode: \(resolvedMode.rawValue)).")
    }

    public func stop() {
        let cleanup = state.withLock { s -> (wasActive: Bool, prevMode: CursorAlignmentMode, token: RunGuardWatchdog.RecoveryToken?) in
            let wasActive = s.isActive
            let prevMode = s.alignmentMode
            let token = s.recoveryToken
            s.isActive = false
            s.isSuspended = false
            s.isUsingEventTap = false
            s.alignmentMode = .inactive
            s.isHiddenForScreenshot = false
            s.configuration = nil
            s.mapping = nil
            s.onStateChange = nil
            s.tapProcessor.reset()
            s.recoveryToken = nil
            s.overlayWindowID = nil
            s.drawPending = false
            s.shapeRefreshPending = false
            s.lastPositionStateNotifyUptime = 0
            s.currentState = CursorOverlayState()
            s.latestRenderSnapshot = CursorRenderSnapshot(
                state: CursorOverlayState(),
                image: nil,
                spriteGeometry: nil,
                interpolation: .bilinear,
                presentationMode: s.presentationMode,
                alignmentMode: .inactive
            )
            return (wasActive, prevMode, token)
        }

        if let token = cleanup.token {
            watchdog.unregisterRecoveryHandler(token)
        }

        stopMaintenanceTimer()
        stopEventTapThread()
        // Unconditionally release any cursor hide we acquired.
        cursorHider.show()

        // Extract panel strongly BEFORE async hop so off-main-thread `deinit` NEVER leaks the panel via `[weak self]`.
        let panelToClose = spritePanelLock.withLockUnchecked { p -> CursorSpriteOverlayPanel? in
            let current = p
            p = nil
            return current
        }

        if let panelToClose {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    panelToClose.close()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        panelToClose.close()
                    }
                }
            }
        }

        if cleanup.prevMode != .inactive {
            notifyAlignmentMode(.inactive)
        }

        if cleanup.wasActive {
            PipelineLog.shared.info(.cursor, "CursorOverlayController stopped and hardware cursor restored.")
        }
    }

    // MARK: - Emergency Watchdog Recovery

    private func emergencyStopFromWatchdog() {
        stopEventTapThread()
        cursorHider.forceRestore()
        state.withLock { s in
            s.isSuspended = true
            s.isUsingEventTap = false
            s.currentState.isVisible = false
            s.latestRenderSnapshot.state = s.currentState
        }
        hideSpritePanelOnMain()
    }

    private func hideSpritePanelOnMain() {
        guard let panel = spritePanelLock.withLockUnchecked({ $0 }) else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                panel.hide()
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    panel.hide()
                }
            }
        }
    }

    // MARK: - Dedicated .userInteractive EventTapThread

    private func startEventTapThread() -> Bool {
        stopEventTapThread()

        // Direct weak-controller bridge: ZERO closure boxing or reabstraction thunks!
        let box = EventTapCallbackBox(controller: self)

        let readySem = DispatchSemaphore(value: 0)
        let startedFlag = OSAllocatedUnfairLock(initialState: false)

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                return
            }

            let mask = Self.monitoredEventMask()
            let userInfo = Unmanaged.passUnretained(box).toOpaque()

            let callback: CGEventTapCallBack = { proxy, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let callbackBox = Unmanaged<EventTapCallbackBox>.fromOpaque(refcon).takeUnretainedValue()
                return callbackBox.invoke(proxy: proxy, type: type, event: event)
            }

            guard let tapPort = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: userInfo
            ) else {
                box.invalidate()
                readySem.signal()
                return
            }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0) else {
                CFMachPortInvalidate(tapPort)
                box.invalidate()
                readySem.signal()
                return
            }

            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tapPort, enable: true)

            self.tapRuntime.withLockUnchecked { rt in
                rt.runLoop = runLoop
                rt.tapPort = tapPort
                rt.runLoopSource = source
                rt.callbackBox = box
            }

            startedFlag.withLock { $0 = true }
            readySem.signal()

            CFRunLoopRun()

            // Cleanup on the tap thread itself before exiting.
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(tapPort)
            box.invalidate()

            self.tapRuntime.withLockUnchecked { rt in
                if rt.tapPort === tapPort {
                    rt.tapPort = nil
                    rt.runLoopSource = nil
                    rt.runLoop = nil
                    rt.callbackBox = nil
                    rt.thread = nil
                }
            }
        }

        thread.name = "com.metalpie.input.event-tap"
        thread.qualityOfService = .userInteractive

        tapRuntime.withLockUnchecked { rt in
            rt.thread = thread
        }
        thread.start()

        _ = readySem.wait(timeout: .now() + .seconds(2))
        let didStart = startedFlag.withLock { $0 }
        if !didStart {
            tapRuntime.withLockUnchecked { $0.thread = nil }
        }
        return didStart
    }

    private func stopEventTapThread() {
        let runtime = tapRuntime.withLockUnchecked { rt -> (CFMachPort?, CFRunLoop?, EventTapCallbackBox?) in
            let port = rt.tapPort
            let loop = rt.runLoop
            let box = rt.callbackBox
            return (port, loop, box)
        }

        runtime.2?.invalidate()
        if let port = runtime.0 {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let loop = runtime.1 {
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
        }
    }

    private func setEventTapEnabled(_ enabled: Bool) {
        if let port = tapRuntime.withLockUnchecked({ $0.tapPort }) {
            CGEvent.tapEnable(tap: port, enable: enabled)
        }
    }

    private static func monitoredEventMask() -> CGEventMask {
        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel
        ]
        return types.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }
    }

    // MARK: - Event Tap Processing (Zero-Delta-Drift + Synchronized Speed Compensation)

    internal func handleEventTap(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Fast O(1) passthrough for our own post-warp reposted scroll/click events (prevents re-entry).
        if event.getIntegerValueField(.eventSourceUserData) == Self.repostedEventMagicTag {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !AXIsProcessTrusted() {
                PipelineLog.shared.warning(.cursor, "Accessibility trust revoked mid-session; restoring OS cursor and switching to accessibilityRequired mode.")
                cursorHider.show()
                let changedToAXRequired = state.withLock { s -> Bool in
                    let prev = s.alignmentMode
                    s.isUsingEventTap = false
                    s.alignmentMode = .accessibilityRequired
                    s.currentState.isVisible = false
                    s.latestRenderSnapshot.alignmentMode = .accessibilityRequired
                    s.latestRenderSnapshot.state = s.currentState
                    return prev != .accessibilityRequired
                }
                hideSpritePanelOnMain()
                startMaintenanceTimer(pollingMode: true)
                if changedToAXRequired {
                    notifyAlignmentMode(.accessibilityRequired)
                }
                notifyStateChange()
                return Unmanaged.passUnretained(event)
            }

            if let port = tapRuntime.withLockUnchecked({ $0.tapPort }), state.withLock({ $0.isActive && !$0.isSuspended }) {
                CGEvent.tapEnable(tap: port, enable: true)
                PipelineLog.shared.debug(.cursor, "Re-enabled CGEventTap after system disable (\(type.rawValue)).")
            }
            return Unmanaged.passUnretained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let tapInput = CursorTapEventInput(
            type: type,
            location: event.location,
            deltaX: event.getDoubleValueField(.mouseEventDeltaX),
            deltaY: event.getDoubleValueField(.mouseEventDeltaY),
            timestamp: now
        )

        enum TapAction {
            case passthrough
            case update(
                newEventLocation: CGPoint?,
                warpTarget: CGPoint?,
                shouldRepostAfterWarp: Bool,
                reassociateMouseOnWarp: Bool,
                immediateStateNotify: Bool,
                shouldNotifyPosition: Bool,
                osCursorHideTransition: Bool?
            )
        }

        let action: TapAction = state.withLock { s in
            guard s.isActive, !s.isSuspended, let mapping = s.mapping, mapping.isValid else {
                return .passthrough
            }

            if mapping.isIdentity && !mapping.threeDGameMode {
                return .passthrough
            }

            let wasNativePassthrough = (s.tapProcessor.interactionMode != .scaled)
            let prevVisible = s.currentState.isVisible
            let prevGrabbed = s.currentState.isMouseGrabbedByGame
            let prevIdleHidden = s.currentState.isIdleHidden

            guard let decision = s.tapProcessor.process(
                input: tapInput,
                mapping: mapping,
                isHiddenForScreenshot: s.isHiddenForScreenshot,
                isIdleHidden: false
            ) else {
                return .passthrough
            }

            s.lastActivityUptime = now
            s.currentState.isIdleHidden = false
            s.currentState.isMouseGrabbedByGame = decision.isMouseGrabbedByGame
            s.currentState.scaledCGPosition = decision.scaledCGPosition
            s.currentState.scaleFactor = mapping.effectiveCursorScaleFactor
            Self.recomputeVisibilityLocked(&s)

            // Update VRR Metal render snapshot immediately (zero freeze).
            s.latestRenderSnapshot.state = s.currentState
            if let img = s.cachedCursorImage {
                s.latestRenderSnapshot.spriteGeometry = mapping.spriteGeometry(
                    forScaledPoint: decision.scaledCGPosition,
                    cursorPointSize: img.pointSize,
                    hotSpot: img.hotSpot
                )
            }

            let isNativePassthrough = decision.isNativePassthrough
            let osCursorHideTransition: Bool?
            if wasNativePassthrough != isNativePassthrough {
                osCursorHideTransition = !isNativePassthrough
            } else {
                osCursorHideTransition = nil
            }

            let stateFlagChanged = (prevVisible != s.currentState.isVisible)
                || (prevGrabbed != s.currentState.isMouseGrabbedByGame)
                || (prevIdleHidden != s.currentState.isIdleHidden)
            let reassociate = !decision.isMouseGrabbedByGame && !mapping.threeDGameMode

            // In VRR `.externalCompositor` mode, notify on every coalesced visual update so GPU cursor
            // uniforms stay 120Hz-synced; in `.overlayLayer` mode, fire immediately on state transitions
            // and throttle pure position notifications to ~15Hz so MainActor is never flooded with
            // redundant Task allocations competing with CALayer position flushes!
            let shouldNotifyPosition: Bool
            if stateFlagChanged || s.presentationMode == .externalCompositor {
                shouldNotifyPosition = true
                s.lastPositionStateNotifyUptime = now
            } else if (now - s.lastPositionStateNotifyUptime) >= (1.0 / 15.0) {
                shouldNotifyPosition = true
                s.lastPositionStateNotifyUptime = now
            } else {
                shouldNotifyPosition = false
            }

            return .update(
                newEventLocation: decision.rewrittenEventLocation,
                warpTarget: decision.warpTarget,
                shouldRepostAfterWarp: decision.shouldRepostAfterWarp,
                reassociateMouseOnWarp: reassociate,
                immediateStateNotify: stateFlagChanged,
                shouldNotifyPosition: shouldNotifyPosition,
                osCursorHideTransition: osCursorHideTransition
            )
        }

        switch action {
        case .passthrough:
            return Unmanaged.passUnretained(event)

        case .update(
            let newEventLocation,
            let warpTarget,
            let shouldRepostAfterWarp,
            let reassociateMouseOnWarp,
            let immediateStateNotify,
            let shouldNotifyPosition,
            let osCursorHideTransition
        ):
            if let target = warpTarget {
                // Warp physical OS cursor FIRST so macOS WindowServer cursor state is synced
                // before delivering or reposting click/scroll events!
                performCursorWarp(to: target, reassociateMouse: reassociateMouseOnWarp)
            }
            if let loc = newEventLocation {
                // Update event location only; NEVER mutate mouseEventDeltaX / mouseEventDeltaY!
                event.location = loc
            }
            if let shouldHide = osCursorHideTransition {
                if shouldHide {
                    cursorHider.hide()
                } else {
                    cursorHider.show()
                }
            }
            // Fast position-only visual update (ZERO SystemCursorMirror bitmap hashing on pointer move!).
            let scheduledVisual = scheduleVisualPositionUpdate()
            if immediateStateNotify || (shouldNotifyPosition && (scheduledVisual || warpTarget != nil || osCursorHideTransition != nil)) {
                notifyStateChange()
            }
            if shouldRepostAfterWarp,
               let loc = newEventLocation ?? warpTarget,
               repostEventAfterWarp(event, at: loc)
            {
                // Drop stale pre-warp event; the freshly hit-tested copy at `loc` was posted to `.cghidEventTap`.
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Maintenance Timer (Idle Auto-Hide, Anti-Drift Check, AX-Denied Tracking Poll)

    private func startMaintenanceTimer(pollingMode: Bool) {
        stopMaintenanceTimer()

        let intervalMs = pollingMode ? 16 : 100
        let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(intervalMs),
            repeating: .milliseconds(intervalMs),
            leeway: .milliseconds(pollingMode ? 4 : 20)
        )
        timer.setEventHandler { [weak self] in
            self?.runMaintenanceTick(pollingMode: pollingMode)
        }

        maintenanceTimerLock.withLockUnchecked { $0 = timer }
        timer.resume()
    }

    private func stopMaintenanceTimer() {
        let timer = maintenanceTimerLock.withLockUnchecked { t -> (any DispatchSourceTimer)? in
            let current = t
            t = nil
            return current
        }
        timer?.cancel()
    }

    private func runMaintenanceTick(pollingMode: Bool) {
        let now = ProcessInfo.processInfo.systemUptime

        if pollingMode {
            // Accessibility denied fallback: keep native OS cursor visible and scaled sprite strictly hidden
            // so MetalPie NEVER renders a misleading remapped cursor that disagrees with where OS clicks land.
            let pointer = Self.currentCGPointerLocation()
            let changed = state.withLock { s -> Bool in
                guard s.isActive, !s.isSuspended, let mapping = s.mapping, mapping.isValid else {
                    return false
                }
                let scaled = mapping.mapSourceToScaled(pointer, clampToContent: true)
                let moved = hypot(scaled.x - s.currentState.scaledCGPosition.x, scaled.y - s.currentState.scaledCGPosition.y) >= 0.5
                guard moved else { return false }
                s.currentState.scaledCGPosition = scaled
                s.currentState.isVisible = false
                s.latestRenderSnapshot.state = s.currentState
                return true
            }
            if changed {
                notifyStateChange()
            }
            return
        }

        // Event-tap mode: check idle auto-hide, quiet hover-settle OS sync (>= 300ms idle),
        // non-flickering hide drift, and decoupled ~10Hz cursor-shape mirroring (off the pointer-move hot path!).
        let result = state.withLock { s -> (
            idleChanged: Bool,
            shouldCheckDrift: Bool,
            shouldPollCursorShape: Bool,
            hoverSettleWarp: CGPoint?
        ) in
            guard s.isActive, !s.isSuspended, let mapping = s.mapping else {
                return (false, false, false, nil)
            }

            let isScaledMode = (s.tapProcessor.interactionMode == .scaled)

            var idleChanged = false
            if isScaledMode,
               let idleTimeout = mapping.settings.hideOnIdleSeconds,
               s.tapProcessor.pressedButtonsMask == 0,
               !s.currentState.isIdleHidden
            {
                if (now - s.lastActivityUptime) >= idleTimeout {
                    s.currentState.isIdleHidden = true
                    Self.recomputeVisibilityLocked(&s)
                    s.latestRenderSnapshot.state = s.currentState
                    idleChanged = true
                }
            }

            // Quiet hover-settle sync: ONLY after >= 300ms of true stillness (no buttons pressed,
            // no active glide, no pending warp, in `.scaled` mode), perform ONE silent OS cursor sync onto
            // `virtualSourcePosition` so tooltips / `NSCursor.currentSystem` shapes stay accurate
            // without EVER calling `CGWarpMouseCursorPosition` during active glides or micro-pauses!
            var hoverSettleWarp: CGPoint?
            if isScaledMode,
               s.isUsingEventTap,
               mapping.settings.adjustCursorSpeed,
               mapping.settings.confineCursor,
               !mapping.isIdentity,
               !mapping.threeDGameMode,
               !s.currentState.isMouseGrabbedByGame,
               !s.tapProcessor.isPointerOutsideUnconfinedSource,
               !s.tapProcessor.activeWindowBorderDrag,
               s.tapProcessor.pressedButtonsMask == 0,
               s.tapProcessor.pendingWarp == nil,
               s.tapProcessor.lastMotionTimestamp > 0,
               (now - s.tapProcessor.lastMotionTimestamp) >= 0.30,
               let virtualPos = s.tapProcessor.virtualSourcePosition,
               let physicalPos = s.tapProcessor.lastPhysicalLocation,
               hypot(physicalPos.x - virtualPos.x, physicalPos.y - virtualPos.y) >= 2.0
            {
                let target = mapping.constrainSourcePoint(virtualPos).point
                s.tapProcessor.recordExternalWarp(from: physicalPos, to: target, timestamp: now)
                hoverSettleWarp = target
            }

            let shouldCheckDrift = isScaledMode
                && s.isUsingEventTap
                && !s.tapProcessor.isPointerOutsideUnconfinedSource
                && (mapping.requiresScaledOverlayCursor || mapping.threeDGameMode)
            let shouldPollCursorShape = isScaledMode
                && s.isUsingEventTap
                && mapping.requiresScaledOverlayCursor
                && !s.tapProcessor.isPointerOutsideUnconfinedSource
                && !s.currentState.isMouseGrabbedByGame
            return (idleChanged, shouldCheckDrift, shouldPollCursorShape, hoverSettleWarp)
        }

        if let settlePoint = result.hoverSettleWarp {
            performCursorWarp(to: settlePoint, reassociateMouse: true)
        }

        if result.shouldCheckDrift {
            // Zero-flicker check: only calls CGDisplayHideCursor if CGCursorIsVisible() actually drifted to true!
            cursorHider.reassertHiddenIfDrifted()
        }

        if result.idleChanged {
            scheduleVisualPositionUpdate()
            notifyStateChange()
        }

        if result.shouldPollCursorShape {
            // Decoupled ~10Hz cursor-shape check — NEVER blocks pointer position updates!
            scheduleCursorShapeRefresh()
        }
    }

    // MARK: - Coalesced MainActor Visual Presentation & Decoupled System Cursor Mirroring

    /// High-priority position-only visual update: NEVER runs `SystemCursorMirror` bitmap hashing!
    @discardableResult
    private func scheduleVisualPositionUpdate() -> Bool {
        let shouldDispatch = state.withLock { s -> Bool in
            guard s.isActive else { return false }
            if s.drawPending { return false }
            s.drawPending = true
            return true
        }
        guard shouldDispatch else { return false }

        DispatchQueue.main.async(qos: .userInteractive) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.flushVisualPositionOnMainActor()
            }
        }
        return true
    }

    /// Low-priority decoupled cursor-shape check (~10Hz from maintenance timer or lifecycle transitions).
    /// Completely off the pointer-motion critical path so `NSCursor.currentSystem` rasterization &
    /// pixel fingerprinting NEVER stall `spriteLayer.position`!
    private func scheduleCursorShapeRefresh() {
        let shouldDispatch = state.withLock { s -> Bool in
            guard s.isActive, !s.isSuspended else { return false }
            if s.shapeRefreshPending { return false }
            s.shapeRefreshPending = true
            return true
        }
        guard shouldDispatch else { return }

        DispatchQueue.main.async(qos: .utility) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.refreshCursorShapeOnMainActor()
            }
        }
    }

    @MainActor
    private func flushVisualPositionOnMainActor() {
        let pre = state.withLock { s -> (
            active: Bool,
            scale: Double,
            hasImage: Bool,
            mapping: PointerMapping?
        ) in
            s.drawPending = false
            return (
                s.isActive,
                s.mapping?.backingScaleFactor ?? 2.0,
                s.cachedCursorImage != nil,
                s.mapping
            )
        }

        guard pre.active, let mapping = pre.mapping else {
            spritePanelLock.withLockUnchecked { $0 }?.hide()
            return
        }

        // Only bootstrap the initial cursor image once when nil; steady-state pointer moves NEVER
        // run `NSCursor.currentSystem` / `CFDataGetBytePtr` pixel hashing!
        var bootstrapImage: CursorImageSnapshot?
        if !pre.hasImage {
            let mirror = cursorMirror ?? {
                let m = SystemCursorMirror()
                cursorMirror = m
                return m
            }()
            bootstrapImage = mirror.captureIfChanged(backingScaleFactor: pre.scale)
        }

        let capturedImage = bootstrapImage
        let renderBundle = state.withLock { s -> (
            isActive: Bool,
            snapshot: CursorRenderSnapshot,
            overlayCocoa: CGRect,
            levelRaw: Int,
            prevOverlayWindowID: CGWindowID?
        ) in
            if let img = capturedImage {
                s.cachedCursorImage = img
            }
            s.latestRenderSnapshot.state = s.currentState
            s.latestRenderSnapshot.image = s.cachedCursorImage
            if let img = s.cachedCursorImage {
                s.latestRenderSnapshot.spriteGeometry = mapping.spriteGeometry(
                    forScaledPoint: s.currentState.scaledCGPosition,
                    cursorPointSize: img.pointSize,
                    hotSpot: img.hotSpot
                )
            } else {
                s.latestRenderSnapshot.spriteGeometry = nil
            }
            return (
                s.isActive,
                s.latestRenderSnapshot,
                mapping.overlayCocoaFrame(),
                s.preferredWindowLevelRawValue,
                s.overlayWindowID
            )
        }

        guard renderBundle.isActive else {
            spritePanelLock.withLockUnchecked { $0 }?.hide()
            return
        }

        if renderBundle.snapshot.presentationMode == .overlayLayer {
            let overlay: CursorSpriteOverlayPanel
            if let existing = spritePanelLock.withLockUnchecked({ $0 }) {
                overlay = existing
            } else {
                let created = CursorSpriteOverlayPanel()
                created.setWindowLevel(NSWindow.Level(rawValue: renderBundle.levelRaw))
                let stillActive = state.withLock(\.isActive)
                guard stillActive else {
                    created.close()
                    return
                }
                spritePanelLock.withLockUnchecked { $0 = created }
                overlay = created
            }
            guard state.withLock(\.isActive) else {
                let toClose = spritePanelLock.withLockUnchecked { p -> CursorSpriteOverlayPanel? in
                    let old = p; p = nil; return old
                }
                toClose?.close()
                return
            }
            overlay.apply(snapshot: renderBundle.snapshot, overlayCocoaFrame: renderBundle.overlayCocoa)
            let wid = overlay.windowID
            let overlayIDChanged = state.withLock { s -> Bool in
                guard s.isActive else { return false }
                let changed = (s.overlayWindowID != wid)
                s.overlayWindowID = wid
                return changed && wid != nil
            }
            if overlayIDChanged {
                // Immediately notify AppCoordinator once so the newly created cursor panel CGWindowID
                // is added to WindowLifecycleWatcher's ignored overlay list.
                notifyStateChange()
            }
        } else {
            spritePanelLock.withLockUnchecked { $0 }?.hide()
        }
    }

    @MainActor
    private func refreshCursorShapeOnMainActor() {
        let pre = state.withLock { s -> (
            active: Bool,
            scale: Double,
            prevGeneration: UInt64?,
            mapping: PointerMapping?
        ) in
            s.shapeRefreshPending = false
            guard s.isActive, !s.isSuspended else {
                return (false, 2.0, nil, nil)
            }
            return (
                true,
                s.mapping?.backingScaleFactor ?? 2.0,
                s.cachedCursorImage?.generation,
                s.mapping
            )
        }

        guard pre.active, let mapping = pre.mapping else { return }

        let mirror = cursorMirror ?? {
            let m = SystemCursorMirror()
            cursorMirror = m
            return m
        }()
        let captured = mirror.captureIfChanged(backingScaleFactor: pre.scale)

        // Fast exit: cursor shape unchanged (~99% of ticks) -> zero state mutation, zero layer flush!
        if let prevGen = pre.prevGeneration, prevGen == captured.generation {
            return
        }

        let update = state.withLock { s -> (
            shouldApplyPanel: Bool,
            shouldNotify: Bool,
            snapshot: CursorRenderSnapshot,
            overlayCocoa: CGRect
        ) in
            guard s.isActive else {
                return (false, false, s.latestRenderSnapshot, .zero)
            }
            let prevGen = s.cachedCursorImage?.generation
            let prevIdle = s.currentState.isIdleHidden
            s.cachedCursorImage = captured
            if prevGen != nil && prevGen != captured.generation {
                // Cursor shape changed (e.g. arrow -> I-beam); wake idle cursor just like Magpie!
                s.lastActivityUptime = ProcessInfo.processInfo.systemUptime
                if s.currentState.isIdleHidden {
                    s.currentState.isIdleHidden = false
                    Self.recomputeVisibilityLocked(&s)
                }
            }
            s.latestRenderSnapshot.state = s.currentState
            s.latestRenderSnapshot.image = captured
            s.latestRenderSnapshot.spriteGeometry = mapping.spriteGeometry(
                forScaledPoint: s.currentState.scaledCGPosition,
                cursorPointSize: captured.pointSize,
                hotSpot: captured.hotSpot
            )
            let shouldNotify = (s.presentationMode == .externalCompositor) || (prevIdle != s.currentState.isIdleHidden)
            return (
                s.presentationMode == .overlayLayer,
                shouldNotify,
                s.latestRenderSnapshot,
                mapping.overlayCocoaFrame()
            )
        }

        if update.shouldApplyPanel {
            spritePanelLock.withLockUnchecked { $0 }?.apply(
                snapshot: update.snapshot,
                overlayCocoaFrame: update.overlayCocoa
            )
        }
        if update.shouldNotify {
            notifyStateChange()
        }
    }

    // MARK: - Helpers

    private func recordWarp(from origin: CGPoint? = nil, to point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { s in
            s.tapProcessor.recordExternalWarp(from: origin, to: point, timestamp: now)
        }
    }

    /// Warps the hardware cursor and immediately clears macOS's default 0.25s local hardware event
    /// suppression interval via `localEventsSuppressionInterval = 0.0` + `CGAssociateMouseAndMouseCursorPosition(true)`
    /// (when not in 3D game mode or FPS mouse-grab). Never calls `CGAssociateMouseAndMouseCursorPosition(false)`.
    private func performCursorWarp(to point: CGPoint, reassociateMouse: Bool) {
        if state.withLock(\.suppressSystemWarpForTesting) {
            return
        }
        warpEventSource?.localEventsSuppressionInterval = 0.0
        CGWarpMouseCursorPosition(point)
        if reassociateMouse {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        }
    }

    /// Copies a `.scrollWheel` or `*MouseDown` event that arrived while the hidden physical cursor
    /// was drifted/outside `sourceRect`, clears stale WindowServer hit-test window IDs, zeros
    /// local event suppression, tags `eventSourceUserData` to bypass re-entry in O(1), and reposts
    /// at `.cghidEventTap` so macOS WindowServer re-hit-tests at `targetLocation` (fixing notch #1 / click #1!).
    private func repostEventAfterWarp(_ event: CGEvent, at targetLocation: CGPoint) -> Bool {
        if state.withLock(\.suppressSystemWarpForTesting) {
            return false
        }
        guard let copied = event.copy() else {
            return false
        }
        copied.location = targetLocation
        copied.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 0)
        copied.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 0)
        copied.setIntegerValueField(.eventSourceUserData, value: Self.repostedEventMagicTag)
        if let evSource = CGEventSource(event: copied) {
            evSource.localEventsSuppressionInterval = 0.0
        }
        copied.post(tap: .cghidEventTap)
        return true
    }

    /// Configures active controller state without launching a live system event tap or warping the
    /// host cursor, enabling deterministic multi-ten-thousand-event callback stress tests via
    /// `EventTapCallbackBox.invoke(proxy:type:event:)`.
    internal func activateForEventTapTesting(
        configuration: CursorMappingConfiguration,
        displays: [DisplayDescriptor],
        initialPointer: CGPoint
    ) {
        let mapping = PointerMapping(configuration: configuration, displays: displays)
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { s in
            s.isActive = true
            s.isSuspended = false
            s.isUsingEventTap = true
            s.suppressSystemWarpForTesting = true
            s.alignmentMode = .scaledConfinedEventTap
            s.configuration = configuration
            s.displays = displays
            s.mapping = mapping
            s.tapProcessor.reset(initialSourcePosition: initialPointer, physicalLocation: initialPointer)
            s.lastActivityUptime = now
            s.currentState = CursorOverlayState(
                isVisible: mapping.requiresScaledOverlayCursor,
                scaledCGPosition: mapping.mapSourceToScaled(initialPointer, clampToContent: true),
                scaleFactor: mapping.effectiveCursorScaleFactor,
                isMouseGrabbedByGame: false,
                isIdleHidden: false
            )
            s.latestRenderSnapshot.state = s.currentState
            s.latestRenderSnapshot.alignmentMode = .scaledConfinedEventTap
        }
    }

    private func setAlignmentMode(_ mode: CursorAlignmentMode) {
        let changed = state.withLock { s -> Bool in
            let prev = s.alignmentMode
            s.alignmentMode = mode
            s.latestRenderSnapshot.alignmentMode = mode
            return prev != mode
        }
        if changed {
            notifyAlignmentMode(mode)
        }
    }

    private func notifyAlignmentMode(_ mode: CursorAlignmentMode) {
        let cb = state.withLock(\.onAlignmentModeChange)
        cb?(mode)
    }

    private func notifyStateChange() {
        let payload = state.withLock { ($0.currentState, $0.onStateChange) }
        payload.1?(payload.0)
    }

    private static func recomputeVisibilityLocked(_ s: inout ControllerState) {
        guard let mapping = s.mapping,
              s.isActive,
              !s.isSuspended,
              s.isUsingEventTap,
              mapping.requiresScaledOverlayCursor,
              !s.isHiddenForScreenshot,
              !s.currentState.isIdleHidden,
              s.tapProcessor.interactionMode == .scaled,
              !s.tapProcessor.isPointerOutsideUnconfinedSource
        else {
            s.currentState.isVisible = false
            return
        }

        if mapping.settings.respectGameMouseGrab && s.currentState.isMouseGrabbedByGame {
            s.currentState.isVisible = false
            return
        }

        s.currentState.isVisible = true
    }

    /// Refreshes per-display macOS top Menu Bar heights (`NSScreen.frame.maxY - visibleFrame.maxY`)
    /// safely on the MainActor without ever touching AppKit from the background `CGEventTap` thread.
    private func refreshDisplayMenuBarHeights() {
        if Thread.isMainThread {
            let heights = MainActor.assumeIsolated {
                Self.snapshotDisplayMenuBarHeightsOnMain()
            }
            state.withLock { $0.tapProcessor.displayMenuBarHeights = heights }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let heights = MainActor.assumeIsolated {
                    Self.snapshotDisplayMenuBarHeightsOnMain()
                }
                self.state.withLock { $0.tapProcessor.displayMenuBarHeights = heights }
            }
        }
    }

    @MainActor
    internal static func snapshotDisplayMenuBarHeightsOnMain() -> [CGDirectDisplayID: CGFloat] {
        var result: [CGDirectDisplayID: CGFloat] = [:]
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(num.uint32Value)
            let topInset = screen.frame.maxY - screen.visibleFrame.maxY
            result[displayID] = topInset > 1.0 ? topInset : PointerMapping.defaultMenuBarHeight
        }
        return result
    }

    private static func currentCGPointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Snapshots active displays safely from any thread via CoreGraphics (without blocking MainActor).
    internal static func snapshotCurrentDisplays() -> [DisplayDescriptor] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return []
        }

        var ids = Array(repeating: CGDirectDisplayID(0), count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &ids, &displayCount) == .success else {
            return []
        }

        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)
        let primaryHeight = mainBounds.height

        var descriptors: [DisplayDescriptor] = []
        descriptors.reserveCapacity(Int(displayCount))

        for i in 0..<Int(displayCount) {
            let id = ids[i]
            let cgBounds = CGDisplayBounds(id)
            let cocoaFrame = ScreenGeometry.cgToCocoa(rect: cgBounds, primaryHeight: primaryHeight)

            var backingScale = 1.0
            var refreshHz = 60.0
            if let mode = CGDisplayCopyDisplayMode(id) {
                if cgBounds.width > 0 {
                    backingScale = max(1.0, Double(mode.pixelWidth) / Double(cgBounds.width))
                }
                if mode.refreshRate > 0 {
                    refreshHz = mode.refreshRate
                }
            }

            descriptors.append(DisplayDescriptor(
                id: id,
                name: id == mainID ? "Main Display" : "Display \(id)",
                cocoaFrame: cocoaFrame,
                cgBounds: cgBounds,
                backingScaleFactor: backingScale,
                refreshRateHz: refreshHz,
                maxEDRHeadroom: 1.0,
                isPrimary: id == mainID
            ))
        }

        return descriptors
    }
}
