import CoreGraphics
import Foundation
import MetalPieCore

/// Cardinal edge of a rectangle, used for border confinement and multi-monitor letterbox escape.
public enum RectEdge: String, Hashable, Codable, Sendable, CaseIterable {
    case left
    case right
    case top
    case bottom
}

/// Zero-allocation bitmask of cardinal rectangle edges for the high-frequency `CGEventTap` hot path.
/// Replaces heap-allocated `Set<RectEdge>` in `constrainSourcePoint(_:)` and `touchedBorders(_:tolerance:)`.
public struct RectEdges: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left   = RectEdges(rawValue: 1 << 0)
    public static let right  = RectEdges(rawValue: 1 << 1)
    public static let top    = RectEdges(rawValue: 1 << 2)
    public static let bottom = RectEdges(rawValue: 1 << 3)
    public static let all: RectEdges = [.left, .right, .top, .bottom]

    @inlinable
    public func contains(_ edge: RectEdge) -> Bool {
        switch edge {
        case .left: return (rawValue & Self.left.rawValue) != 0
        case .right: return (rawValue & Self.right.rawValue) != 0
        case .top: return (rawValue & Self.top.rawValue) != 0
        case .bottom: return (rawValue & Self.bottom.rawValue) != 0
        }
    }

    @inlinable
    public mutating func insert(_ edge: RectEdge) {
        switch edge {
        case .left: formUnion(Self.left)
        case .right: formUnion(Self.right)
        case .top: formUnion(Self.top)
        case .bottom: formUnion(Self.bottom)
        }
    }
}

/// Result of constraining a CoreGraphics pointer coordinate inside a source window's reachable bounds.
public struct ConstrainResult: Hashable, Sendable {
    public let point: CGPoint
    public let wasClamped: Bool
    public let clampedEdges: RectEdges

    public init(point: CGPoint, wasClamped: Bool, clampedEdges: RectEdges) {
        self.point = point
        self.wasClamped = wasClamped
        self.clampedEdges = clampedEdges
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(point.x)
        hasher.combine(point.y)
        hasher.combine(wasClamped)
        hasher.combine(clampedEdges.rawValue)
    }
}

/// Outcome of resolving a scaled overlay coordinate against letterbox bars and adjacent monitors.
public enum LetterboxResolution: Hashable, Sendable {
    /// Coordinate already falls inside the active scaled content rect.
    case insideContent(CGPoint)
    /// Coordinate fell in a black letterbox/pillarbox bar and was clamped back onto the content edge.
    case clampedToContent(CGPoint)
    /// Coordinate crossed a letterbox bar toward an adjacent monitor and skipped straight onto it.
    case escapedToAdjacentDisplay(point: CGPoint, display: DisplayDescriptor, edge: RectEdge)

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .insideContent(let pt):
            hasher.combine(0)
            hasher.combine(pt.x)
            hasher.combine(pt.y)
        case .clampedToContent(let pt):
            hasher.combine(1)
            hasher.combine(pt.x)
            hasher.combine(pt.y)
        case .escapedToAdjacentDisplay(let pt, let display, let edge):
            hasher.combine(2)
            hasher.combine(pt.x)
            hasher.combine(pt.y)
            hasher.combine(display)
            hasher.combine(edge)
        }
    }
}

/// Complete hotspot-adjusted cursor sprite placement in CG global, overlay-local CALayer, and Metal pixel spaces.
public struct CursorSpriteGeometry: Hashable, Sendable {
    /// Hotspot position in global CoreGraphics (Y-down) logical points.
    public let scaledCGPosition: CGPoint
    /// Effective visual scale factor applied to the cursor sprite.
    public let scaleFactor: Double
    /// Native logical point size of the cursor image (`NSCursor.image.size`).
    public let cursorPointSize: CGSize
    /// Native cursor hotspot measured from top-left (`NSCursor.hotSpot`).
    public let hotSpot: CGPoint
    /// Scaled logical point size of the cursor sprite.
    public let scaledSize: CGSize
    /// Scaled hotspot offset measured from top-left of the cursor sprite.
    public let scaledHotSpot: CGPoint
    /// Cursor sprite frame in global CoreGraphics (Y-down) logical points.
    public let cgFrame: CGRect
    /// Hotspot position in overlay-local CoreGraphics (Y-down) logical points.
    public let overlayLocalCGPosition: CGPoint
    /// Hotspot position in overlay-local AppKit / CALayer (Y-up) logical points.
    public let overlayLocalCocoaPosition: CGPoint
    /// Cursor sprite frame in overlay-local AppKit / CALayer (Y-up) logical points.
    public let overlayLocalCocoaFrame: CGRect
    /// Normalized CALayer `anchorPoint` in `[0, 1] x [0, 1]` (Y-up), aligning `layer.position` to the hotspot.
    public let layerAnchorPoint: CGPoint
    /// Pixel-snapped cursor sprite rect in overlay Metal drawable pixel coordinates (Y-down) for VRR compositing.
    public let drawablePixelRect: CGRect
    /// Normalized `[0, 1]` sprite rect in overlay Metal drawable coordinates (Y-down).
    public let normalizedDrawableRect: CGRect

    public func hash(into hasher: inout Hasher) {
        hasher.combine(scaledCGPosition.x)
        hasher.combine(scaledCGPosition.y)
        hasher.combine(scaleFactor)
        hasher.combine(cursorPointSize.width)
        hasher.combine(cursorPointSize.height)
        hasher.combine(hotSpot.x)
        hasher.combine(hotSpot.y)
        hasher.combine(scaledSize.width)
        hasher.combine(scaledSize.height)
        hasher.combine(scaledHotSpot.x)
        hasher.combine(scaledHotSpot.y)
        hasher.combine(cgFrame.origin.x)
        hasher.combine(cgFrame.origin.y)
        hasher.combine(cgFrame.size.width)
        hasher.combine(cgFrame.size.height)
        hasher.combine(overlayLocalCGPosition.x)
        hasher.combine(overlayLocalCGPosition.y)
        hasher.combine(overlayLocalCocoaPosition.x)
        hasher.combine(overlayLocalCocoaPosition.y)
        hasher.combine(overlayLocalCocoaFrame.origin.x)
        hasher.combine(overlayLocalCocoaFrame.origin.y)
        hasher.combine(overlayLocalCocoaFrame.size.width)
        hasher.combine(overlayLocalCocoaFrame.size.height)
        hasher.combine(layerAnchorPoint.x)
        hasher.combine(layerAnchorPoint.y)
        hasher.combine(drawablePixelRect.origin.x)
        hasher.combine(drawablePixelRect.origin.y)
        hasher.combine(drawablePixelRect.size.width)
        hasher.combine(drawablePixelRect.size.height)
        hasher.combine(normalizedDrawableRect.origin.x)
        hasher.combine(normalizedDrawableRect.origin.y)
        hasher.combine(normalizedDrawableRect.size.width)
        hasher.combine(normalizedDrawableRect.size.height)
    }
}

/// Pure, unit-testable coordinate mapper translating between CoreGraphics global coordinates (Y-down),
/// the cropped source window rect, and the scaled visible content rect using Magpie's fencepost `(N - 1)` math.
///
/// Supports Fit letterboxing/pillarboxing, Fill overscan cropping, Stretch, IntegerFit, Crop insets,
/// 9-point OutputAlignment, Windowed scaling, multi-monitor desktop layouts via `ScreenGeometry`,
/// and clean 1:1 identity passthrough (avoiding any Accessibility requirement when unscaled).
public struct PointerMapping: Hashable, Sendable {
    /// Strict 1.0pt inward inset guarantees confined coordinates lie inside half-open `[min, max)` window bounds
    /// even after macOS WindowServer sub-pixel rounding (preventing accidental click-through onto Desktop/other apps).
    public static let defaultEdgeInset: CGFloat = 1.0
    public static let identityTolerance: CGFloat = 0.5

    /// Active (cropped/visible) source window rect in global CG (Y-down) logical points.
    public let sourceRect: CGRect
    /// Visible scaled image content rect in global CG (Y-down) logical points.
    public let contentRect: CGRect
    /// Full overlay window rect in global CG (Y-down) logical points (includes any letterbox bars).
    public let overlayRect: CGRect
    /// Snapshot of attached displays used for reachable confinement and multi-monitor escape checks.
    public let displays: [DisplayDescriptor]
    /// Backing scale factor of the overlay display (e.g., `2.0` on Retina).
    public let backingScaleFactor: Double
    /// Active cursor settings from the user's profile.
    public let settings: CursorSettings
    /// Whether 3D Game Mode is active (strict confinement, disables multi-monitor escape and speed scaling).
    public let threeDGameMode: Bool
    /// Sub-point inward inset applied when clamping the OS pointer inside `sourceRect` so rounding apps stay inside.
    public let edgeInset: CGFloat
    /// Individual display intersections of `sourceRect` that the OS cursor can physically reach.
    public let reachableSourceRects: [CGRect]
    /// Pre-inset reachable display intersections so `constrainSourcePoint(_:)` performs zero heap allocations.
    private let insetReachableSourceRects: [CGRect]
    /// Effective inset confinement bounds in global CG (Y-down) logical points.
    public let confinementRect: CGRect

    public init(
        sourceRect: CGRect,
        contentRect: CGRect,
        overlayRect: CGRect,
        displays: [DisplayDescriptor] = [],
        backingScaleFactor: Double = 2.0,
        settings: CursorSettings = CursorSettings(),
        threeDGameMode: Bool = false,
        edgeInset: CGFloat = PointerMapping.defaultEdgeInset
    ) {
        let normalizedSource = sourceRect.standardized
        let normalizedContent = contentRect.standardized
        let normalizedOverlay = overlayRect.standardized.isEmpty ? normalizedContent : overlayRect.standardized
        let clampedInset = max(0, edgeInset)

        self.sourceRect = normalizedSource
        self.contentRect = normalizedContent
        self.overlayRect = normalizedOverlay
        self.displays = displays
        self.backingScaleFactor = max(1.0, backingScaleFactor)
        self.settings = settings
        self.threeDGameMode = threeDGameMode
        self.edgeInset = clampedInset

        let reachable = Self.computeReachableRects(sourceRect: normalizedSource, displays: displays)
        self.reachableSourceRects = reachable
        self.insetReachableSourceRects = reachable.map { Self.insetConfinementRect($0, edgeInset: clampedInset) }

        let baseConfinement: CGRect
        if let first = reachable.first {
            baseConfinement = reachable.dropFirst().reduce(first) { $0.union($1) }
        } else {
            baseConfinement = normalizedSource
        }
        self.confinementRect = Self.insetConfinementRect(baseConfinement, edgeInset: clampedInset)
    }

    /// Initializes from `MetalPieCore`'s `CursorMappingConfiguration`.
    public init(
        configuration: CursorMappingConfiguration,
        displays: [DisplayDescriptor] = [],
        edgeInset: CGFloat = PointerMapping.defaultEdgeInset
    ) {
        self.init(
            sourceRect: configuration.sourceCGRect,
            contentRect: configuration.destinationCGRect,
            overlayRect: configuration.overlayCGRect,
            displays: displays,
            backingScaleFactor: configuration.backingScaleFactor,
            settings: configuration.settings,
            threeDGameMode: configuration.threeDGameMode,
            edgeInset: edgeInset
        )
    }

    /// Initializes directly from a source window CG frame and a `ScalingLayoutResult`, automatically
    /// incorporating `croppedSourceRect` AND `visibleTextureUVRect` (for `.fill` overscan clipping).
    public init(
        sourceWindowCGRect: CGRect,
        layout: ScalingLayoutResult,
        displays: [DisplayDescriptor] = [],
        settings: CursorSettings = CursorSettings(),
        threeDGameMode: Bool = false,
        edgeInset: CGFloat = PointerMapping.defaultEdgeInset
    ) {
        let effectiveSource = Self.effectiveSourceCGRect(
            sourceWindowCGRect: sourceWindowCGRect,
            layout: layout
        )
        self.init(
            sourceRect: effectiveSource,
            contentRect: layout.contentRect,
            overlayRect: layout.targetCGRect,
            displays: displays,
            backingScaleFactor: layout.backingScaleFactor,
            settings: settings,
            threeDGameMode: threeDGameMode,
            edgeInset: edgeInset
        )
    }

    /// Computes the portion of `sourceWindowCGRect` (in CG Y-down points) that is visibly mapped
    /// into `layout.contentRect`, accounting for both `CropInsets` and `.fill` UV clipping.
    public static func effectiveSourceCGRect(
        sourceWindowCGRect: CGRect,
        layout: ScalingLayoutResult
    ) -> CGRect {
        let winRect = sourceWindowCGRect.standardized
        guard layout.sourcePixelSize.isValid, !winRect.isEmpty else {
            return winRect
        }

        let srcW = Double(layout.sourcePixelSize.width)
        let srcH = Double(layout.sourcePixelSize.height)
        let cropped = layout.croppedSourceRect

        let croppedX = winRect.minX + (Double(cropped.x) / srcW) * winRect.width
        let croppedY = winRect.minY + (Double(cropped.y) / srcH) * winRect.height
        let croppedW = (Double(cropped.width) / srcW) * winRect.width
        let croppedH = (Double(cropped.height) / srcH) * winRect.height

        let uv = layout.visibleTextureUVRect.standardized
        let clampedU0 = min(max(uv.minX, 0.0), 1.0)
        let clampedV0 = min(max(uv.minY, 0.0), 1.0)
        let clampedUW = min(max(uv.width, 0.0), 1.0 - clampedU0)
        let clampedVH = min(max(uv.height, 0.0), 1.0 - clampedV0)

        guard clampedUW > 0, clampedVH > 0 else {
            return CGRect(x: croppedX, y: croppedY, width: croppedW, height: croppedH)
        }

        return CGRect(
            x: croppedX + clampedU0 * croppedW,
            y: croppedY + clampedV0 * croppedH,
            width: clampedUW * croppedW,
            height: clampedVH * croppedH
        )
    }

    // MARK: - Geometric Properties

    public var isValid: Bool {
        sourceRect.width >= 1.0 && sourceRect.height >= 1.0 &&
            contentRect.width >= 1.0 && contentRect.height >= 1.0
    }

    /// True when the visible content rect matches the source rect 1:1 (within 0.5 pt).
    /// When `isIdentity` is true (and not in 3D game mode), no cursor remapping or Accessibility tap is needed.
    public var isIdentity: Bool {
        abs(sourceRect.minX - contentRect.minX) <= Self.identityTolerance &&
            abs(sourceRect.minY - contentRect.minY) <= Self.identityTolerance &&
            abs(sourceRect.width - contentRect.width) <= Self.identityTolerance &&
            abs(sourceRect.height - contentRect.height) <= Self.identityTolerance
    }

    /// True if scaled cursor rendering is needed (non-1:1 layout with `renderScaledCursor` enabled).
    public var requiresScaledOverlayCursor: Bool {
        !isIdentity && settings.renderScaledCursor
    }

    /// True if an Accessibility `CGEventTap` is beneficial for cursor confinement or speed compensation.
    /// Returns `false` for 1:1 non-3D scaling so 1:1 mode NEVER requires Accessibility permission.
    public var requiresEventTap: Bool {
        if isIdentity {
            return threeDGameMode && settings.confineCursor
        }
        return settings.confineCursor || settings.adjustCursorSpeed || settings.renderScaledCursor || threeDGameMode
    }

    /// True if `overlayRect` contains black letterbox/pillarbox margins around `contentRect`.
    public var hasLetterboxBars: Bool {
        abs(contentRect.minX - overlayRect.minX) > 0.5 ||
            abs(contentRect.minY - overlayRect.minY) > 0.5 ||
            abs(contentRect.maxX - overlayRect.maxX) > 0.5 ||
            abs(contentRect.maxY - overlayRect.maxY) > 0.5
    }

    public var scaleX: Double {
        guard sourceRect.width > 0 else { return 1.0 }
        return Double(contentRect.width / sourceRect.width)
    }

    public var scaleY: Double {
        guard sourceRect.height > 0 else { return 1.0 }
        return Double(contentRect.height / sourceRect.height)
    }

    public var averageScale: Double {
        (scaleX + scaleY) * 0.5
    }

    /// Effective visual scale applied to the rendered cursor sprite according to `CursorSettings.cursorScaleMode`.
    public var effectiveCursorScaleFactor: Double {
        let raw: Double
        switch settings.cursorScaleMode {
        case .source:
            raw = averageScale
        case .multiplier:
            raw = settings.cursorScaleMultiplier
        case .fixed:
            raw = 1.0
        }
        return min(max(raw, 0.25), 8.0)
    }

    /// Per-axis delta multiplier (`srcSpan / dstSpan`) applied when `adjustCursorSpeed` is enabled outside
    /// 3D Game Mode so moving the physical desktop cursor by `+N pt` moves the visual scaled cursor by exact `+N pt`.
    public var speedCompensationScale: CGSize {
        guard settings.adjustCursorSpeed, !isIdentity, !threeDGameMode, isValid else {
            return CGSize(width: 1.0, height: 1.0)
        }
        let srcSpanX = max(1.0, Double(sourceRect.width - 1.0))
        let srcSpanY = max(1.0, Double(sourceRect.height - 1.0))
        let dstSpanX = max(1.0, Double(contentRect.width - 1.0))
        let dstSpanY = max(1.0, Double(contentRect.height - 1.0))
        let sx = min(max(srcSpanX / dstSpanX, 0.05), 4.0)
        let sy = min(max(srcSpanY / dstSpanY, 0.05), 4.0)
        return CGSize(width: sx, height: sy)
    }

    /// Isotropic delta multiplier (`1 / averageScale`) when `adjustCursorSpeed` is enabled.
    public var speedCompensationFactor: Double {
        guard settings.adjustCursorSpeed, !isIdentity, !threeDGameMode, isValid else {
            return 1.0
        }
        return min(max(1.0 / max(averageScale, 0.125), 0.05), 4.0)
    }

    // MARK: - Fencepost (N - 1) Coordinate Mapping

    /// Maps a point in source window CG coordinates (Y-down) to scaled content CG coordinates (Y-down)
    /// using `ScalingLayoutCalculator.mapSourcePointToScaled` (`(N - 1)` fencepost convention).
    public func mapSourceToScaled(
        _ sourcePoint: CGPoint,
        clampToContent: Bool = true
    ) -> CGPoint {
        guard isValid else { return sourcePoint }
        if isIdentity {
            return clampToContent ? Self.clampToFencepost(sourcePoint, rect: contentRect) : sourcePoint
        }

        let mapped = ScalingLayoutCalculator.mapSourcePointToScaled(
            sourcePoint,
            sourceRect: sourceRect,
            contentRect: contentRect
        )
        return clampToContent ? Self.clampToFencepost(mapped, rect: contentRect) : mapped
    }

    /// Maps a point in scaled content CG coordinates (Y-down) back to underlying source window CG coordinates
    /// using `ScalingLayoutCalculator.mapScaledPointToSource` (`(N - 1)` fencepost convention).
    public func mapScaledToSource(
        _ scaledPoint: CGPoint,
        clampToSource: Bool = true
    ) -> CGPoint {
        guard isValid else { return scaledPoint }
        if isIdentity {
            return clampToSource ? Self.clampToFencepost(scaledPoint, rect: sourceRect) : scaledPoint
        }

        let mapped = ScalingLayoutCalculator.mapScaledPointToSource(
            scaledPoint,
            sourceRect: sourceRect,
            contentRect: contentRect
        )
        return clampToSource ? Self.clampToFencepost(mapped, rect: sourceRect) : mapped
    }

    // MARK: - Confinement & Letterbox Handling

    /// Constrains a CG global pointer coordinate inside the source window's reachable confinement bounds.
    /// Zero heap allocations — safe for the high-frequency `CGEventTap` hot path.
    public func constrainSourcePoint(_ cgPoint: CGPoint) -> ConstrainResult {
        guard isValid else {
            return ConstrainResult(point: cgPoint, wasClamped: false, clampedEdges: [])
        }

        var clampedEdges: RectEdges = []
        var x = cgPoint.x
        var y = cgPoint.y

        if x < confinementRect.minX {
            x = confinementRect.minX
            clampedEdges.insert(.left)
        } else if x > confinementRect.maxX {
            x = confinementRect.maxX
            clampedEdges.insert(.right)
        }

        if y < confinementRect.minY {
            y = confinementRect.minY
            clampedEdges.insert(.top)
        } else if y > confinementRect.maxY {
            y = confinementRect.maxY
            clampedEdges.insert(.bottom)
        }

        var candidate = CGPoint(x: x, y: y)

        // For non-rectangular L-shaped multi-monitor unions, ensure the confined point actually
        // resides within one of the physical reachable display intersections (precomputed; zero alloc).
        if insetReachableSourceRects.count > 1 {
            var insideAny = false
            for rect in insetReachableSourceRects {
                if candidate.x >= rect.minX && candidate.x <= rect.maxX &&
                    candidate.y >= rect.minY && candidate.y <= rect.maxY
                {
                    insideAny = true
                    break
                }
            }
            if !insideAny, let nearest = Self.nearestPoint(to: candidate, in: insetReachableSourceRects) {
                if nearest.x > candidate.x { clampedEdges.insert(.left) }
                if nearest.x < candidate.x { clampedEdges.insert(.right) }
                if nearest.y > candidate.y { clampedEdges.insert(.top) }
                if nearest.y < candidate.y { clampedEdges.insert(.bottom) }
                candidate = nearest
            }
        }

        let wasClamped = !clampedEdges.isEmpty
        return ConstrainResult(point: candidate, wasClamped: wasClamped, clampedEdges: clampedEdges)
    }

    /// Returns `true` if `cgPoint` lies inside `sourceRect` (optionally inset by `margin` points).
    public func isPointInsideSource(_ cgPoint: CGPoint, margin: CGFloat = 0.0) -> Bool {
        guard isValid else { return false }
        let safeMargin = max(0, margin)
        let dx = min(safeMargin, max(0, (sourceRect.width - 1.0) * 0.5))
        let dy = min(safeMargin, max(0, (sourceRect.height - 1.0) * 0.5))
        let checkRect = CGRect(
            x: sourceRect.minX + dx,
            y: sourceRect.minY + dy,
            width: max(0, sourceRect.width - dx * 2.0),
            height: max(0, sourceRect.height - dy * 2.0)
        )
        return cgPoint.x >= checkRect.minX && cgPoint.x <= checkRect.maxX &&
            cgPoint.y >= checkRect.minY && cgPoint.y <= checkRect.maxY
    }

    /// Resolves a safe starting physical source point when starting/resuming confinement.
    ///
    /// - If `cgPoint` is already strictly inside the confined interior of `sourceRect` (e.g. triggered
    ///   via global hotkey while interacting with the target window), preserves `cgPoint` with zero jump.
    /// - If `cgPoint` is outside `confinementRect` (e.g. user clicked "Scale" in MetalPie's UI window),
    ///   returns the **center** of the largest reachable confinement region rather than clamping onto an
    ///   extreme corner/resize border where the first click could miss or hit a window border.
    public func safeInitialSourcePoint(
        from cgPoint: CGPoint
    ) -> (point: CGPoint, shouldWarp: Bool) {
        guard isValid else { return (cgPoint, false) }
        let constrained = constrainSourcePoint(cgPoint)
        if !constrained.wasClamped {
            return (cgPoint, false)
        }

        // Target center of the largest reachable display intersection (handles L-shaped multi-monitor windows cleanly).
        if reachableSourceRects.count > 1,
           let largest = reachableSourceRects.max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        {
            let insetLargest = Self.insetConfinementRect(largest, edgeInset: edgeInset)
            return (CGPoint(x: insetLargest.midX, y: insetLargest.midY), true)
        }

        return (CGPoint(x: confinementRect.midX, y: confinementRect.midY), true)
    }

    /// Returns `true` if `cgPoint` lies inside the overlay window's black letterbox/pillarbox bars
    /// (inside `overlayRect` but outside `contentRect`).
    public func isPointInLetterboxBar(_ cgPoint: CGPoint) -> Bool {
        overlayRect.contains(cgPoint) && !contentRect.contains(cgPoint)
    }

    /// Resolves a scaled overlay coordinate against `contentRect` and black letterbox bars.
    ///
    /// - If inside `contentRect`: returns `.insideContent`.
    /// - If outside `contentRect` (e.g. crossing into a black bar): skips directly across the black bar onto
    ///   an adjacent monitor when `allowAdjacentDisplayEscape && !threeDGameMode` and a monitor exists in that
    ///   direction; otherwise clamps to the visible content edge.
    public func resolveScaledPoint(
        _ scaledCGPoint: CGPoint,
        allowAdjacentDisplayEscape: Bool = true
    ) -> LetterboxResolution {
        guard isValid else { return .insideContent(scaledCGPoint) }

        let fenceMaxX = max(contentRect.minX, contentRect.maxX - 1.0)
        let fenceMaxY = max(contentRect.minY, contentRect.maxY - 1.0)

        let crossedEdge: RectEdge?
        if scaledCGPoint.x < contentRect.minX {
            crossedEdge = .left
        } else if scaledCGPoint.x > fenceMaxX {
            crossedEdge = .right
        } else if scaledCGPoint.y < contentRect.minY {
            crossedEdge = .top
        } else if scaledCGPoint.y > fenceMaxY {
            crossedEdge = .bottom
        } else {
            crossedEdge = nil
        }

        guard let edge = crossedEdge else {
            return .insideContent(scaledCGPoint)
        }

        if allowAdjacentDisplayEscape, !threeDGameMode, let adjacent = adjacentDisplay(beyond: edge) {
            let escapedPoint: CGPoint
            let adjBounds = adjacent.cgBounds.standardized
            switch edge {
            case .left:
                escapedPoint = CGPoint(
                    x: max(adjBounds.minX, adjBounds.maxX - 1.0),
                    y: min(max(scaledCGPoint.y, adjBounds.minY), max(adjBounds.minY, adjBounds.maxY - 1.0))
                )
            case .right:
                escapedPoint = CGPoint(
                    x: adjBounds.minX,
                    y: min(max(scaledCGPoint.y, adjBounds.minY), max(adjBounds.minY, adjBounds.maxY - 1.0))
                )
            case .top:
                escapedPoint = CGPoint(
                    x: min(max(scaledCGPoint.x, adjBounds.minX), max(adjBounds.minX, adjBounds.maxX - 1.0)),
                    y: max(adjBounds.minY, adjBounds.maxY - 1.0)
                )
            case .bottom:
                escapedPoint = CGPoint(
                    x: min(max(scaledCGPoint.x, adjBounds.minX), max(adjBounds.minX, adjBounds.maxX - 1.0)),
                    y: adjBounds.minY
                )
            }
            return .escapedToAdjacentDisplay(point: escapedPoint, display: adjacent, edge: edge)
        }

        return .clampedToContent(Self.clampToFencepost(scaledCGPoint, rect: contentRect))
    }

    /// Finds an attached display strictly beyond `overlayRect` along `edge` (for multi-monitor letterbox skip).
    public func adjacentDisplay(beyond edge: RectEdge) -> DisplayDescriptor? {
        guard displays.count > 1 else { return nil }
        let tolerance: CGFloat = 2.0

        return displays.first { display in
            let b = display.cgBounds.standardized
            switch edge {
            case .left:
                let overlapsY = b.maxY > overlayRect.minY && b.minY < overlayRect.maxY
                return overlapsY && b.maxX <= overlayRect.minX + tolerance
            case .right:
                let overlapsY = b.maxY > overlayRect.minY && b.minY < overlayRect.maxY
                return overlapsY && b.minX >= overlayRect.maxX - tolerance
            case .top:
                let overlapsX = b.maxX > overlayRect.minX && b.minX < overlayRect.maxX
                return overlapsX && b.maxY <= overlayRect.minY + tolerance
            case .bottom:
                let overlapsX = b.maxX > overlayRect.minX && b.minX < overlayRect.maxX
                return overlapsX && b.minY >= overlayRect.maxY - tolerance
            }
        }
    }

    // MARK: - Border & FPS Grab Helpers (Zero Heap Allocation)

    /// Returns which edges of `confinementRect` the source point is currently touching within `tolerance`.
    /// Uses stack-allocated `RectEdges` bitmask (zero heap allocations per mouse event).
    public func touchedBorders(_ sourcePoint: CGPoint, tolerance: CGFloat = 1.5) -> RectEdges {
        guard isValid else { return [] }
        var edges: RectEdges = []
        if sourcePoint.x <= confinementRect.minX + tolerance { edges.insert(.left) }
        if sourcePoint.x >= confinementRect.maxX - tolerance { edges.insert(.right) }
        if sourcePoint.y <= confinementRect.minY + tolerance { edges.insert(.top) }
        if sourcePoint.y >= confinementRect.maxY - tolerance { edges.insert(.bottom) }
        return edges
    }

    /// Returns which physical outer display bezel edges `cgPoint` is currently touching within `tolerance`.
    /// Used to distinguish monitor-bezel clamping from an FPS game locking the cursor in place.
    public func touchedDisplayEdges(_ cgPoint: CGPoint, tolerance: CGFloat = 2.0) -> RectEdges {
        guard !displays.isEmpty else { return [] }
        var containing: CGRect?
        for display in displays {
            let b = display.cgBounds.standardized
            if cgPoint.x >= b.minX - tolerance && cgPoint.x <= b.maxX + tolerance &&
                cgPoint.y >= b.minY - tolerance && cgPoint.y <= b.maxY + tolerance
            {
                containing = b
                break
            }
        }
        guard let b = containing else { return [] }

        var edges: RectEdges = []
        if cgPoint.x <= b.minX + tolerance && !hasDisplay(covering: CGPoint(x: b.minX - tolerance - 2.0, y: cgPoint.y)) {
            edges.insert(.left)
        }
        if cgPoint.x >= b.maxX - tolerance && !hasDisplay(covering: CGPoint(x: b.maxX + tolerance + 2.0, y: cgPoint.y)) {
            edges.insert(.right)
        }
        if cgPoint.y <= b.minY + tolerance && !hasDisplay(covering: CGPoint(x: cgPoint.x, y: b.minY - tolerance - 2.0)) {
            edges.insert(.top)
        }
        if cgPoint.y >= b.maxY - tolerance && !hasDisplay(covering: CGPoint(x: cgPoint.x, y: b.maxY + tolerance + 2.0)) {
            edges.insert(.bottom)
        }
        return edges
    }

    private func hasDisplay(covering point: CGPoint) -> Bool {
        for display in displays {
            let b = display.cgBounds.standardized
            if point.x >= b.minX && point.x < b.maxX && point.y >= b.minY && point.y < b.maxY {
                return true
            }
        }
        return false
    }

    /// True if `sourcePoint` lies within `tolerance` points of any edge of `confinementRect`.
    public func isAtBorder(_ sourcePoint: CGPoint, tolerance: CGFloat = 1.5) -> Bool {
        !touchedBorders(sourcePoint, tolerance: tolerance).isEmpty
    }

    /// Returns `true` if the raw mouse delta is pushing strictly outward against a touched border
    /// (distinguishing normal edge pushing from an FPS game locking the cursor near a border).
    public func isDeltaPushingOutward(
        deltaX: Double,
        deltaY: Double,
        at sourcePoint: CGPoint,
        tolerance: CGFloat = 1.5
    ) -> Bool {
        let edges = touchedBorders(sourcePoint, tolerance: tolerance)
        guard !edges.isEmpty else { return false }

        let eps = 0.001
        let hasX = abs(deltaX) > eps
        let hasY = abs(deltaY) > eps

        let xBlockedOutward = !hasX ||
            (deltaX < -eps && edges.contains(.left)) ||
            (deltaX > eps && edges.contains(.right))
        let yBlockedOutward = !hasY ||
            (deltaY < -eps && edges.contains(.top)) ||
            (deltaY > eps && edges.contains(.bottom))

        return (hasX || hasY) && xBlockedOutward && yBlockedOutward
    }

    // MARK: - Hotspot-Adjusted Cursor Sprite Geometry

    /// Computes complete hotspot-adjusted cursor sprite placement from a source-window CG point.
    public func spriteGeometry(
        forSourcePoint sourcePoint: CGPoint,
        cursorPointSize: CGSize,
        hotSpot: CGPoint,
        clampToContent: Bool = true
    ) -> CursorSpriteGeometry {
        let scaledPos = mapSourceToScaled(sourcePoint, clampToContent: clampToContent)
        return spriteGeometry(
            forScaledPoint: scaledPos,
            cursorPointSize: cursorPointSize,
            hotSpot: hotSpot
        )
    }

    /// Computes complete hotspot-adjusted cursor sprite placement from a scaled global CG point.
    public func spriteGeometry(
        forScaledPoint scaledCGPoint: CGPoint,
        cursorPointSize: CGSize,
        hotSpot: CGPoint
    ) -> CursorSpriteGeometry {
        let scale = effectiveCursorScaleFactor
        let safeW = max(1.0, cursorPointSize.width)
        let safeH = max(1.0, cursorPointSize.height)
        let clampedHotX = min(max(hotSpot.x, 0.0), safeW)
        let clampedHotY = min(max(hotSpot.y, 0.0), safeH)

        let scaledSize = CGSize(width: safeW * scale, height: safeH * scale)
        let scaledHotSpot = CGPoint(x: clampedHotX * scale, y: clampedHotY * scale)

        // Global CG (Y-down): hotspot is measured from top-left of cursor image.
        let cgFrame = CGRect(
            x: scaledCGPoint.x - scaledHotSpot.x,
            y: scaledCGPoint.y - scaledHotSpot.y,
            width: scaledSize.width,
            height: scaledSize.height
        )

        // Overlay-local CG (Y-down) and AppKit / CALayer (Y-up).
        let localCGPos = CGPoint(
            x: scaledCGPoint.x - overlayRect.minX,
            y: scaledCGPoint.y - overlayRect.minY
        )
        let localCocoaPos = CGPoint(
            x: localCGPos.x,
            y: overlayRect.height - localCGPos.y
        )
        let localCocoaFrame = CGRect(
            x: localCocoaPos.x - scaledHotSpot.x,
            y: localCocoaPos.y - (scaledSize.height - scaledHotSpot.y),
            width: scaledSize.width,
            height: scaledSize.height
        )

        // CALayer anchorPoint is in [0, 1] Y-up layer space (0 = bottom, 1 = top).
        let anchorPoint = CGPoint(
            x: clampedHotX / safeW,
            y: 1.0 - (clampedHotY / safeH)
        )

        // Metal drawable pixel coordinates (Y-down), snapped to whole pixels for crisp sampling.
        let pxOriginX = ((cgFrame.minX - overlayRect.minX) * backingScaleFactor).rounded()
        let pxOriginY = ((cgFrame.minY - overlayRect.minY) * backingScaleFactor).rounded()
        let pxWidth = max(1.0, (cgFrame.width * backingScaleFactor).rounded())
        let pxHeight = max(1.0, (cgFrame.height * backingScaleFactor).rounded())
        let drawablePixelRect = CGRect(x: pxOriginX, y: pxOriginY, width: pxWidth, height: pxHeight)

        let drawableTotalW = max(1.0, overlayRect.width * backingScaleFactor)
        let drawableTotalH = max(1.0, overlayRect.height * backingScaleFactor)
        let normalizedDrawableRect = CGRect(
            x: drawablePixelRect.minX / drawableTotalW,
            y: drawablePixelRect.minY / drawableTotalH,
            width: drawablePixelRect.width / drawableTotalW,
            height: drawablePixelRect.height / drawableTotalH
        )

        return CursorSpriteGeometry(
            scaledCGPosition: scaledCGPoint,
            scaleFactor: scale,
            cursorPointSize: CGSize(width: safeW, height: safeH),
            hotSpot: CGPoint(x: clampedHotX, y: clampedHotY),
            scaledSize: scaledSize,
            scaledHotSpot: scaledHotSpot,
            cgFrame: cgFrame,
            overlayLocalCGPosition: localCGPos,
            overlayLocalCocoaPosition: localCocoaPos,
            overlayLocalCocoaFrame: localCocoaFrame,
            layerAnchorPoint: anchorPoint,
            drawablePixelRect: drawablePixelRect,
            normalizedDrawableRect: normalizedDrawableRect
        )
    }

    // MARK: - AppKit / Multi-Monitor Conversions via ScreenGeometry

    /// Converts a mapped scaled CG point into global AppKit (Y-up) coordinates using `ScreenGeometry`.
    public func scaledCocoaPoint(forSourcePoint sourcePoint: CGPoint) -> CGPoint {
        let cgPoint = mapSourceToScaled(sourcePoint, clampToContent: true)
        return ScreenGeometry.cgToCocoa(point: cgPoint, displays: displays)
    }

    /// Converts `overlayRect` from CG (Y-down) to AppKit (Y-up) global coordinates for `NSPanel(..., screen: nil)`.
    public func overlayCocoaFrame() -> CGRect {
        ScreenGeometry.cgToCocoa(rect: overlayRect, displays: displays)
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sourceRect.origin.x)
        hasher.combine(sourceRect.origin.y)
        hasher.combine(sourceRect.size.width)
        hasher.combine(sourceRect.size.height)
        hasher.combine(contentRect.origin.x)
        hasher.combine(contentRect.origin.y)
        hasher.combine(contentRect.size.width)
        hasher.combine(contentRect.size.height)
        hasher.combine(overlayRect.origin.x)
        hasher.combine(overlayRect.origin.y)
        hasher.combine(overlayRect.size.width)
        hasher.combine(overlayRect.size.height)
        hasher.combine(displays)
        hasher.combine(backingScaleFactor)
        hasher.combine(settings)
        hasher.combine(threeDGameMode)
        hasher.combine(edgeInset)
    }

    // MARK: - Private Geometry Helpers

    private static func clampToFencepost(_ point: CGPoint, rect: CGRect) -> CGPoint {
        let maxX = max(rect.minX, rect.maxX - 1.0)
        let maxY = max(rect.minY, rect.maxY - 1.0)
        return CGPoint(
            x: min(max(point.x, rect.minX), maxX),
            y: min(max(point.y, rect.minY), maxY)
        )
    }

    private static func computeReachableRects(
        sourceRect: CGRect,
        displays: [DisplayDescriptor]
    ) -> [CGRect] {
        guard !displays.isEmpty, !sourceRect.isEmpty else { return [] }
        var rects: [CGRect] = []
        rects.reserveCapacity(displays.count)
        for display in displays {
            let inter = sourceRect.intersection(display.cgBounds.standardized)
            if !inter.isNull, !inter.isEmpty {
                rects.append(inter)
            }
        }
        return rects
    }

    private static func insetConfinementRect(_ rect: CGRect, edgeInset: CGFloat) -> CGRect {
        let r = rect.standardized
        guard !r.isEmpty else { return r }
        let dx = min(edgeInset, max(0, (r.width - 1.0) * 0.5))
        let dy = min(edgeInset, max(0, (r.height - 1.0) * 0.5))
        return CGRect(
            x: r.minX + dx,
            y: r.minY + dy,
            width: max(0, r.width - dx * 2.0),
            height: max(0, r.height - dy * 2.0)
        )
    }

    private static func nearestPoint(to point: CGPoint, in rects: [CGRect]) -> CGPoint? {
        var bestPoint: CGPoint?
        var bestDistSq: CGFloat = .greatestFiniteMagnitude

        for rect in rects {
            let cx = min(max(point.x, rect.minX), rect.maxX)
            let cy = min(max(point.y, rect.minY), rect.maxY)
            let dx = point.x - cx
            let dy = point.y - cy
            let distSq = dx * dx + dy * dy
            if distSq < bestDistSq {
                bestDistSq = distSq
                bestPoint = CGPoint(x: cx, y: cy)
            }
        }
        return bestPoint
    }
}
