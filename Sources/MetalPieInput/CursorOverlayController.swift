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
    }
}

/// Deterministic, unit-testable event-tap state machine powering `CursorOverlayController`.
///
/// Guarantees:
/// - **Exact click & scroll alignment**: mouse button down/up, drags, and scroll-wheel events ALWAYS
///   use the exact synchronized `virtualSourcePosition` matching the rendered scaled cursor sprite
///   (never snapping back to stale uncompensated `incoming` coordinates!).
/// - **Zero FPS grab false-positives**: every internal speed-compensation or edge-confinement warp calls
///   `pointerTracker.recordSelfWarp(to:)` so normal desktop apps (e.g. Terminal) never trigger game grab.
/// - **Multi-monitor unconfined escape**: when `confineCursor == false`, moving outside `sourceRect`
///   restores the native OS cursor at 1:1 desktop speed until re-entering `sourceRect`.
public struct CursorEventTapProcessor: Sendable {
    public var pointerTracker = PointerTracker()
    public var virtualSourcePosition: CGPoint?
    public var pressedButtonsMask: UInt32 = 0
    public var lastWarpedPoint: CGPoint?
    public var lastWarpedTimestamp: TimeInterval = 0
    public var isPointerOutsideUnconfinedSource: Bool = false

    public init() {}

    public mutating func reset(initialSourcePosition: CGPoint? = nil) {
        pointerTracker.reset()
        virtualSourcePosition = initialSourcePosition
        pressedButtonsMask = 0
        lastWarpedPoint = nil
        lastWarpedTimestamp = 0
        isPointerOutsideUnconfinedSource = false
    }

    public mutating func recordExternalWarp(to point: CGPoint, timestamp: TimeInterval) {
        lastWarpedPoint = point
        lastWarpedTimestamp = timestamp
        virtualSourcePosition = point
        pointerTracker.recordSelfWarp(to: point)
    }

    /// Processes a single event-tap event. Returns `nil` ONLY when the event is a benign self-warp
    /// feedback echo (`mouseMoved` with zero delta right after our own `CGWarpMouseCursorPosition`).
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

        // Update mouse button mask (pauses idle auto-hide while dragging).
        switch type {
        case .leftMouseDown: pressedButtonsMask |= (1 << 0)
        case .leftMouseUp: pressedButtonsMask &= ~(1 << 0)
        case .rightMouseDown: pressedButtonsMask |= (1 << 1)
        case .rightMouseUp: pressedButtonsMask &= ~(1 << 1)
        case .otherMouseDown: pressedButtonsMask |= (1 << 2)
        case .otherMouseUp: pressedButtonsMask &= ~(1 << 2)
        default: break
        }

        let hasDelta = abs(deltaX) > 0.001 || abs(deltaY) > 0.001

        // Skip self-warp feedback echoes ONLY on zero-delta `.mouseMoved` — NEVER skip clicks, drags, or scroll!
        if type == .mouseMoved && !hasDelta,
           let warped = lastWarpedPoint,
           now - lastWarpedTimestamp < 0.05,
           hypot(incoming.x - warped.x, incoming.y - warped.y) < 1.0
        {
            return nil
        }

        let isMotionEvent = (
            type == .mouseMoved ||
            type == .leftMouseDragged ||
            type == .rightMouseDragged ||
            type == .otherMouseDragged
        )

        // Track FPS / 3D game mouse-grab strictly on motion events (button clicks have 0 delta by nature).
        let grabbed: Bool
        if mapping.settings.respectGameMouseGrab {
            if isMotionEvent {
                grabbed = pointerTracker.recordEvent(
                    location: incoming,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    mapping: mapping,
                    timestamp: now
                )
            } else {
                grabbed = pointerTracker.isGrabbed
            }
        } else {
            grabbed = false
        }

        var newEventLocation: CGPoint?
        var warpTarget: CGPoint?
        let effectiveSourcePoint: CGPoint

        let enforceConfinement = mapping.settings.confineCursor || mapping.threeDGameMode

        // When confinement is explicitly disabled and pointer already escaped outside sourceRect,
        // keep 1:1 native OS cursor motion across other monitors until re-entering sourceRect.
        if !enforceConfinement && isPointerOutsideUnconfinedSource && !mapping.isPointInsideSource(incoming) {
            effectiveSourcePoint = incoming
            virtualSourcePosition = incoming
            isPointerOutsideUnconfinedSource = true
            let scaledPos = mapping.mapSourceToScaled(effectiveSourcePoint, clampToContent: true)
            return CursorTapEventDecision(
                rewrittenEventLocation: nil,
                warpTarget: nil,
                effectiveSourcePoint: effectiveSourcePoint,
                scaledCGPosition: scaledPos,
                isScaledSpriteVisible: false,
                isMouseGrabbedByGame: grabbed,
                isPointerOutsideUnconfinedSource: true
            )
        }

        if grabbed || mapping.threeDGameMode {
            // Zero-delta-drift confinement: NEVER touch relative deltas or speed scaling!
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
        } else if mapping.settings.adjustCursorSpeed && !mapping.isIdentity {
            // Smooth 1 / scaleFactor speed compensation synchronized across motion, clicks, drags & scroll!
            let base: CGPoint
            if let existing = virtualSourcePosition {
                base = existing
            } else {
                base = enforceConfinement ? mapping.constrainSourcePoint(incoming).point : incoming
            }

            let targetPos: CGPoint
            if isMotionEvent && hasDelta {
                let comp = mapping.speedCompensationScale
                let rawNext = CGPoint(
                    x: base.x + deltaX * comp.width,
                    y: base.y + deltaY * comp.height
                )
                targetPos = enforceConfinement ? mapping.constrainSourcePoint(rawNext).point : rawNext
            } else {
                // Clicks (*MouseDown/*MouseUp), scrollWheel, and zero-delta motion MUST stay locked
                // to `virtualSourcePosition` so the physical click ALWAYS hits the visual cursor hotspot!
                targetPos = enforceConfinement ? mapping.constrainSourcePoint(base).point : base
            }

            virtualSourcePosition = targetPos
            effectiveSourcePoint = targetPos
            newEventLocation = targetPos

            if hypot(incoming.x - targetPos.x, incoming.y - targetPos.y) >= 0.5 {
                warpTarget = targetPos
            }
        } else {
            // Standard zero-delta-drift confinement across ALL events (motion, clicks, drags, scroll).
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
        }

        isPointerOutsideUnconfinedSource = !enforceConfinement && !mapping.isPointInsideSource(effectiveSourcePoint)

        if let wt = warpTarget {
            lastWarpedPoint = wt
            lastWarpedTimestamp = now
            pointerTracker.recordSelfWarp(to: wt, rawIncoming: incoming)
        }

        let scaledPos = mapping.mapSourceToScaled(effectiveSourcePoint, clampToContent: true)
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
            isPointerOutsideUnconfinedSource: isPointerOutsideUnconfinedSource
        )
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
    public let releaseMoveThreshold: Int

    public private(set) var isGrabbed: Bool = false
    public private(set) var stillEventCount: Int = 0
    public private(set) var warpToCenterCount: Int = 0

    private var lastLocation: CGPoint?
    private var previousLocation: CGPoint?
    private var lastSelfWarpRawIncoming: CGPoint?
    private var grabAnchor: CGPoint?
    private var lastWarpTimestamp: TimeInterval = 0
    private var releaseMoveCount: Int = 0

    public init(grabThreshold: Int = 3, releaseMoveThreshold: Int = 2) {
        self.grabThreshold = max(1, grabThreshold)
        self.releaseMoveThreshold = max(1, releaseMoveThreshold)
    }

    public mutating func reset() {
        isGrabbed = false
        stillEventCount = 0
        warpToCenterCount = 0
        lastLocation = nil
        previousLocation = nil
        lastSelfWarpRawIncoming = nil
        grabAnchor = nil
        lastWarpTimestamp = 0
        releaseMoveCount = 0
    }

    /// Updates reference location after `CursorOverlayController` itself calls `CGWarpMouseCursorPosition`
    /// (for speed compensation or edge confinement). Stores `rawIncoming` so:
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
            // Pure programmatic warp without deltas (e.g., game centering cursor) or cursor settle.
            if moveDist > 2.0 {
                if let anchor = grabAnchor, hypot(location.x - anchor.x, location.y - anchor.y) <= 2.5 {
                    warpToCenterCount += 1
                    lastWarpTimestamp = timestamp
                } else if isGrabbed {
                    releaseMoveCount += 1
                    if releaseMoveCount >= releaseMoveThreshold {
                        isGrabbed = false
                        stillEventCount = 0
                        warpToCenterCount = 0
                        grabAnchor = nil
                        releaseMoveCount = 0
                    }
                }
            }
            return isGrabbed
        }

        // Case 1: Non-zero relative deltas while pointer coordinates remain stationary
        // (either unchanged from `lastLocation`, OR pinned identically at `prevRawIncoming` ignoring our self-warp —
        // both are signatures of CGAssociateMouseAndMouseCursorPosition(false)!).
        let pinnedAtPreWarpIncoming = prevRawIncoming.map {
            hypot(location.x - $0.x, location.y - $0.y) < 0.5
        } ?? false
        let followedSelfWarpDelta = prevRawIncoming != nil &&
            hypot(Double(movedX) - deltaX, Double(movedY) - deltaY) < max(0.75, hypot(deltaX, deltaY) * 0.35)

        if (moveDist < 0.5 || pinnedAtPreWarpIncoming) && !followedSelfWarpDelta {
            if mapping.isDeltaPushingOutward(deltaX: deltaX, deltaY: deltaY, at: location) {
                // Normal user pushing mouse against an edge; not a game mouse-grab.
                stillEventCount = 0
                return isGrabbed
            }

            stillEventCount += 1
            releaseMoveCount = 0
            if stillEventCount >= grabThreshold {
                isGrabbed = true
                grabAnchor = location
            }
            return isGrabbed
        }

        // Case 2: Repeated warp-to-center / snap-back loops (SDL/Minecraft/Wine relative mouse).
        // Detect returning to `previousLocation` (or an established `grabAnchor`) despite deltas not pointing back.
        let snappedToPrevious: Bool
        if let prev2 = previousLocation {
            let distFromPrev2 = hypot(location.x - prev2.x, location.y - prev2.y)
            let prevStep = hypot(last.x - prev2.x, last.y - prev2.y)
            let dotWithDelta = Double(movedX) * deltaX + Double(movedY) * deltaY
            snappedToPrevious = prevStep >= 2.0 && distFromPrev2 <= 2.0 && dotWithDelta <= 0
        } else {
            snappedToPrevious = false
        }

        let snappedToAnchor: Bool
        if let anchor = grabAnchor {
            let distToAnchor = hypot(location.x - anchor.x, location.y - anchor.y)
            let lastDistToAnchor = hypot(last.x - anchor.x, last.y - anchor.y)
            snappedToAnchor = lastDistToAnchor >= 2.0 && distToAnchor <= 2.0
        } else {
            snappedToAnchor = false
        }

        if snappedToPrevious || snappedToAnchor {
            if timestamp - lastWarpTimestamp > 0.75 {
                warpToCenterCount = 1
            } else {
                warpToCenterCount += 1
            }
            lastWarpTimestamp = timestamp
            grabAnchor = location
            releaseMoveCount = 0
            if warpToCenterCount >= grabThreshold {
                isGrabbed = true
            }
            return isGrabbed
        }

        // Case 3: Genuine cursor motion away from anchor.
        stillEventCount = 0
        if timestamp - lastWarpTimestamp > 0.75 {
            warpToCenterCount = 0
        }

        if isGrabbed {
            if moveDist >= 1.5 {
                releaseMoveCount += 1
                if releaseMoveCount >= releaseMoveThreshold {
                    isGrabbed = false
                    warpToCenterCount = 0
                    grabAnchor = nil
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
private final class CursorSpriteOverlayPanel {
    private var panel: NonActivatingCursorPanel?
    private let spriteLayer = CALayer()
    private var lastAppliedGeneration: UInt64 = 0
    private var lastOverlayCocoaFrame: CGRect = .zero
    private var currentLevel: NSWindow.Level = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow))
    )

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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spriteLayer.isHidden = true
            CATransaction.commit()
            panel?.orderOut(nil)
            return
        }

        let activePanel = ensurePanel(frame: overlayCocoaFrame)
        if lastOverlayCocoaFrame != overlayCocoaFrame {
            activePanel.setFrame(overlayCocoaFrame, display: false)
            lastOverlayCocoaFrame = overlayCocoaFrame
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if lastAppliedGeneration != image.generation {
            spriteLayer.contents = image.cgImage
            spriteLayer.contentsScale = CGFloat(image.backingScaleFactor)
            lastAppliedGeneration = image.generation
        }

        let useNearest = (snapshot.interpolation == .nearest) || abs(geometry.scaleFactor - 1.0) < 0.01
        let filter: CALayerContentsFilter = useNearest ? .nearest : .linear
        spriteLayer.magnificationFilter = filter
        spriteLayer.minificationFilter = filter

        spriteLayer.bounds = CGRect(origin: .zero, size: geometry.scaledSize)
        spriteLayer.anchorPoint = geometry.layerAnchorPoint
        spriteLayer.position = geometry.overlayLocalCocoaPosition
        spriteLayer.isHidden = false

        CATransaction.commit()

        if !activePanel.isVisible {
            activePanel.orderFrontRegardless()
        }
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.isHidden = true
        CATransaction.commit()
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

// MARK: - Dedicated Event Tap Bridge (Memory-Safe C Callback Context)

private final class EventTapCallbackBox: @unchecked Sendable {
    private let handlerLock = OSAllocatedUnfairLock<(@Sendable (CGEventTapProxy, CGEventType, CGEvent) -> Unmanaged<CGEvent>?)?>(
        initialState: nil
    )

    init(handler: @escaping @Sendable (CGEventTapProxy, CGEventType, CGEvent) -> Unmanaged<CGEvent>?) {
        handlerLock.withLock { $0 = handler }
    }

    func invalidate() {
        handlerLock.withLock { $0 = nil }
    }

    func invoke(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let handler = handlerLock.withLock({ $0 }) else {
            return Unmanaged.passUnretained(event)
        }
        return handler(proxy, type, event)
    }
}

// MARK: - CursorOverlayController (CursorControlling)

/// Zero-delta-drift cursor confinement, dynamic `NSCursor.currentSystem` mirroring, FPS mouse-grab detection,
/// and dual-output (non-VRR `CALayer` panel + VRR Metal compositor snapshot) cursor controller.
///
/// Conforms to `CursorControlling` from `MetalPieCore`.
public final class CursorOverlayController: CursorControlling, @unchecked Sendable {
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
        var lastCursorShapeRefreshUptime: TimeInterval = 0
        var drawPending: Bool = false
        var recoveryToken: RunGuardWatchdog.RecoveryToken?
        var overlayWindowID: CGWindowID?
        var preferredWindowLevelRawValue: Int = Int(CGWindowLevelForKey(.popUpMenuWindow))
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
            scheduleVisualUpdate(refreshCursorShape: true)
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
        let updatedConfig = state.withLock { s -> CursorMappingConfiguration? in
            s.displays = displays
            guard let config = s.configuration else { return nil }
            let mapping = PointerMapping(configuration: config, displays: displays)
            s.mapping = mapping
            if let currentVirtual = s.tapProcessor.virtualSourcePosition {
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
            scheduleVisualUpdate(refreshCursorShape: false)
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
                self.flushVisualUpdateOnMainActor(refreshCursorShape: false)
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self.flushVisualUpdateOnMainActor(refreshCursorShape: false)
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
        let initialPlacement: (point: CGPoint, shouldWarp: Bool)
        if (mapping.settings.confineCursor || configuration.threeDGameMode) && !mapping.isIdentity {
            initialPlacement = mapping.safeInitialSourcePoint(from: initialPointer)
        } else {
            initialPlacement = (initialPointer, false)
        }
        let scaledInitial = mapping.mapSourceToScaled(initialPlacement.point, clampToContent: true)

        state.withLock { s in
            s.isActive = true
            s.isSuspended = false
            s.isHiddenForScreenshot = false
            s.configuration = configuration
            s.displays = displays
            s.mapping = mapping
            s.tapProcessor.reset(initialSourcePosition: initialPlacement.point)
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
                if !mapping.settings.confineCursor && !configuration.threeDGameMode {
                    s.tapProcessor.isPointerOutsideUnconfinedSource = !mapping.isPointInsideSource(initialPlacement.point)
                }
                Self.recomputeVisibilityLocked(&s)
            } else {
                // NEVER draw a misleading remapped cursor sprite when OS clicks cannot be confined/aligned!
                s.currentState.isVisible = false
            }
            s.latestRenderSnapshot.state = s.currentState
        }

        if didStartTap && (mapping.requiresScaledOverlayCursor || configuration.threeDGameMode) {
            let outsideUnconfined = state.withLock(\.tapProcessor.isPointerOutsideUnconfinedSource)
            if !outsideUnconfined {
                cursorHider.hide()
            }
            if (mapping.settings.confineCursor || configuration.threeDGameMode) && initialPlacement.shouldWarp {
                recordWarp(initialPlacement.point)
                CGWarpMouseCursorPosition(initialPlacement.point)
            }
        } else {
            cursorHider.show()
            hideSpritePanelOnMain()
        }

        startMaintenanceTimer(pollingMode: !didStartTap)
        if didStartTap {
            scheduleVisualUpdate(refreshCursorShape: true)
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
        let warpPoint: CGPoint? = state.withLock { s in
            s.alignmentMode = resolvedMode
            s.latestRenderSnapshot.alignmentMode = resolvedMode

            let mapping = transition.mapping
            let enforceConfinement = mapping.settings.confineCursor || configuration.threeDGameMode

            var pendingWarp: CGPoint? = nil
            if tapActive && !s.isSuspended && !mapping.isIdentity {
                let currentRef = startedTapNow
                    ? Self.currentCGPointerLocation()
                    : (s.tapProcessor.virtualSourcePosition ?? Self.currentCGPointerLocation())

                if enforceConfinement {
                    if startedTapNow {
                        let placed = mapping.safeInitialSourcePoint(from: currentRef)
                        s.tapProcessor.virtualSourcePosition = placed.point
                        if placed.shouldWarp {
                            pendingWarp = placed.point
                        }
                    } else {
                        let constrained = mapping.constrainSourcePoint(currentRef)
                        s.tapProcessor.virtualSourcePosition = constrained.point
                        if constrained.wasClamped {
                            pendingWarp = constrained.point
                        }
                    }
                    s.tapProcessor.isPointerOutsideUnconfinedSource = false
                } else {
                    s.tapProcessor.virtualSourcePosition = currentRef
                    s.tapProcessor.isPointerOutsideUnconfinedSource = !mapping.isPointInsideSource(currentRef)
                }

                let finalSource = s.tapProcessor.virtualSourcePosition ?? currentRef
                s.currentState.scaledCGPosition = mapping.mapSourceToScaled(finalSource, clampToContent: true)
                Self.recomputeVisibilityLocked(&s)
            } else {
                let curPtr = Self.currentCGPointerLocation()
                s.tapProcessor.virtualSourcePosition = curPtr
                s.tapProcessor.isPointerOutsideUnconfinedSource = false
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
            return pendingWarp
        }

        let outsideUnconfined = state.withLock(\.tapProcessor.isPointerOutsideUnconfinedSource)
        if transition.shouldHideOS && tapActive && !outsideUnconfined {
            cursorHider.hide()
            if let wp = warpPoint {
                recordWarp(wp)
                CGWarpMouseCursorPosition(wp)
            }
            scheduleVisualUpdate(refreshCursorShape: true)
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
            let placement: (point: CGPoint, shouldWarp: Bool) = enforceConfinement
                ? mapping.safeInitialSourcePoint(from: currentPtr)
                : (point: currentPtr, shouldWarp: false)

            s.tapProcessor.reset(initialSourcePosition: placement.point)
            s.currentState.scaledCGPosition = mapping.mapSourceToScaled(placement.point, clampToContent: true)

            let axGranted = AXIsProcessTrusted()
            let shouldTap = mapping.requiresEventTap && axGranted
            let shouldHideOS = shouldTap && (mapping.requiresScaledOverlayCursor || mapping.threeDGameMode)
            return (shouldTap, shouldHideOS, mapping, placement, prevMode)
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
            if !resumeInfo.mapping.settings.confineCursor && !resumeInfo.mapping.threeDGameMode {
                s.tapProcessor.isPointerOutsideUnconfinedSource = !resumeInfo.mapping.isPointInsideSource(resumeInfo.placement.point)
            }
            if resumeInfo.shouldHideOS && tapActive {
                Self.recomputeVisibilityLocked(&s)
            } else {
                s.currentState.isVisible = false
            }
            s.latestRenderSnapshot.state = s.currentState
        }

        let outsideUnconfined = state.withLock(\.tapProcessor.isPointerOutsideUnconfinedSource)
        if resumeInfo.shouldHideOS && tapActive && !outsideUnconfined {
            cursorHider.hide()
            if (resumeInfo.mapping.settings.confineCursor || resumeInfo.mapping.threeDGameMode) && resumeInfo.placement.shouldWarp {
                recordWarp(resumeInfo.placement.point)
                CGWarpMouseCursorPosition(resumeInfo.placement.point)
            }
            scheduleVisualUpdate(refreshCursorShape: true)
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

        let box = EventTapCallbackBox { [weak self] proxy, type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handleEventTap(proxy: proxy, type: type, event: event)
        }

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

    private func handleEventTap(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
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
                shouldNotify: Bool,
                refreshShape: Bool,
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

            let wasOutsideUnconfined = s.tapProcessor.isPointerOutsideUnconfinedSource
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

            // Update VRR Metal render snapshot immediately (zero 50ms freeze!).
            s.latestRenderSnapshot.state = s.currentState
            if let img = s.cachedCursorImage {
                s.latestRenderSnapshot.spriteGeometry = mapping.spriteGeometry(
                    forScaledPoint: decision.scaledCGPosition,
                    cursorPointSize: img.pointSize,
                    hotSpot: img.hotSpot
                )
            }

            let refreshShape = (now - s.lastCursorShapeRefreshUptime) >= (1.0 / 30.0)
            if refreshShape {
                s.lastCursorShapeRefreshUptime = now
            }

            let osCursorHideTransition: Bool?
            if wasOutsideUnconfined != decision.isPointerOutsideUnconfinedSource {
                osCursorHideTransition = !decision.isPointerOutsideUnconfinedSource
            } else {
                osCursorHideTransition = nil
            }

            return .update(
                newEventLocation: decision.rewrittenEventLocation,
                warpTarget: decision.warpTarget,
                shouldNotify: true,
                refreshShape: refreshShape,
                osCursorHideTransition: osCursorHideTransition
            )
        }

        switch action {
        case .passthrough:
            return Unmanaged.passUnretained(event)

        case .update(let newEventLocation, let warpTarget, let shouldNotify, let refreshShape, let osCursorHideTransition):
            if let loc = newEventLocation {
                // Update event location only; NEVER mutate mouseEventDeltaX / mouseEventDeltaY!
                event.location = loc
            }
            if let target = warpTarget {
                CGWarpMouseCursorPosition(target)
            }
            if let shouldHide = osCursorHideTransition {
                if shouldHide {
                    cursorHider.hide()
                } else {
                    cursorHider.show()
                }
            }
            if shouldNotify {
                scheduleVisualUpdate(refreshCursorShape: refreshShape)
                notifyStateChange()
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

        // Event-tap mode: check idle auto-hide and non-flickering cursor hide drift.
        let result = state.withLock { s -> (idleChanged: Bool, shouldCheckDrift: Bool) in
            guard s.isActive, !s.isSuspended, let mapping = s.mapping else {
                return (false, false)
            }

            var idleChanged = false
            if let idleTimeout = mapping.settings.hideOnIdleSeconds,
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

            let shouldCheckDrift = s.isUsingEventTap
                && !s.tapProcessor.isPointerOutsideUnconfinedSource
                && (mapping.requiresScaledOverlayCursor || mapping.threeDGameMode)
            return (idleChanged, shouldCheckDrift)
        }

        if result.shouldCheckDrift {
            // Zero-flicker check: only calls CGDisplayHideCursor if CGCursorIsVisible() actually drifted to true!
            cursorHider.reassertHiddenIfDrifted()
        }

        if result.idleChanged {
            scheduleVisualUpdate(refreshCursorShape: false)
            notifyStateChange()
        }
    }

    // MARK: - Coalesced MainActor Visual Presentation & System Cursor Mirroring

    private func scheduleVisualUpdate(refreshCursorShape: Bool) {
        let shouldDispatch = state.withLock { s -> Bool in
            guard s.isActive else { return false }
            if s.drawPending { return false }
            s.drawPending = true
            return true
        }
        guard shouldDispatch else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.flushVisualUpdateOnMainActor(refreshCursorShape: refreshCursorShape)
            }
        }
    }

    @MainActor
    private func flushVisualUpdateOnMainActor(refreshCursorShape: Bool) {
        let pre = state.withLock { s -> (active: Bool, scale: Double, mode: CursorPresentationMode, hasImage: Bool, mapping: PointerMapping?) in
            s.drawPending = false
            return (
                s.isActive,
                s.mapping?.backingScaleFactor ?? 2.0,
                s.presentationMode,
                s.cachedCursorImage != nil,
                s.mapping
            )
        }

        guard pre.active, let mapping = pre.mapping else {
            spritePanelLock.withLockUnchecked { $0 }?.hide()
            return
        }

        var refreshedImage: CursorImageSnapshot?
        if refreshCursorShape || !pre.hasImage {
            let mirror = cursorMirror ?? {
                let m = SystemCursorMirror()
                cursorMirror = m
                return m
            }()
            refreshedImage = mirror.captureIfChanged(backingScaleFactor: pre.scale)
        }

        let capturedImage = refreshedImage
        let renderBundle = state.withLock { s -> (isActive: Bool, snapshot: CursorRenderSnapshot, overlayCocoa: CGRect, levelRaw: Int) in
            if let img = capturedImage {
                let prevGen = s.cachedCursorImage?.generation
                s.cachedCursorImage = img
                if prevGen != nil && prevGen != img.generation {
                    // Cursor shape changed (e.g. arrow -> I-beam); wake idle cursor just like Magpie!
                    s.lastActivityUptime = ProcessInfo.processInfo.systemUptime
                    if s.currentState.isIdleHidden {
                        s.currentState.isIdleHidden = false
                        Self.recomputeVisibilityLocked(&s)
                    }
                }
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
            return (s.isActive, s.latestRenderSnapshot, mapping.overlayCocoaFrame(), s.preferredWindowLevelRawValue)
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
            state.withLock { s in
                if s.isActive {
                    s.overlayWindowID = wid
                }
            }
        } else {
            spritePanelLock.withLockUnchecked { $0 }?.hide()
        }
    }

    // MARK: - Helpers

    private func recordWarp(_ point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { s in
            s.tapProcessor.recordExternalWarp(to: point, timestamp: now)
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
