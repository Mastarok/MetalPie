import CoreGraphics
import Foundation

/// Strategy for selecting which display(s) a fullscreen scaled overlay covers.
public enum MultiMonitorMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Target only the display containing or closest to the source window.
    case closest
    /// Span the union of all displays intersected by the source window.
    case intersected
    /// Span the entire virtual desktop across all attached displays.
    case all

    public var id: String { rawValue }
}

/// Integer pixel dimensions (e.g. Metal texture dimensions, capture dimensions).
public struct PixelSize: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int

    public static let zero = PixelSize(width: 0, height: 0)

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public init(cgSize: CGSize) {
        self.width = max(0, Int(cgSize.width.rounded()))
        self.height = max(0, Int(cgSize.height.rounded()))
    }

    public var isValid: Bool {
        width > 0 && height > 0
    }

    public var aspectRatio: Double {
        guard height > 0 else { return 0 }
        return Double(width) / Double(height)
    }

    public var cgSize: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    public var pixelCount: Int {
        width * height
    }
}

/// Integer pixel rectangle (Y-down texture/framebuffer coordinate space).
public struct PixelRect: Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public init(origin: (Int, Int) = (0, 0), size: PixelSize) {
        self.x = origin.0
        self.y = origin.1
        self.width = size.width
        self.height = size.height
    }

    public init(cgRect: CGRect) {
        self.x = Int(cgRect.origin.x.rounded())
        self.y = Int(cgRect.origin.y.rounded())
        self.width = max(0, Int(cgRect.size.width.rounded()))
        self.height = max(0, Int(cgRect.size.height.rounded()))
    }

    public var size: PixelSize {
        PixelSize(width: width, height: height)
    }

    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    /// Returns the intersection of two pixel rectangles, or `.zero` if disjoint.
    public func intersection(_ other: PixelRect) -> PixelRect {
        let left = max(minX, other.minX)
        let top = max(minY, other.minY)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else {
            return .zero
        }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// Pure, AppKit-independent snapshot of a macOS display's geometry and capabilities.
public struct DisplayDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: CGDirectDisplayID
    public var name: String
    /// Display frame in AppKit global coordinates (Y-up, origin at primary display bottom-left).
    public var cocoaFrame: CGRect
    /// Display bounds in CoreGraphics global coordinates (Y-down, origin at primary display top-left).
    public var cgBounds: CGRect
    /// Retina backing scale factor (e.g. 1.0, 2.0).
    public var backingScaleFactor: Double
    /// Display peak refresh rate in Hz (e.g. 60, 120).
    public var refreshRateHz: Double
    /// Maximum potential EDR headroom (1.0 for SDR, > 1.0 for HDR/XDR displays).
    public var maxEDRHeadroom: Double
    /// True for the primary macOS display (`cocoaFrame.origin == .zero`).
    public var isPrimary: Bool

    public init(
        id: CGDirectDisplayID,
        name: String,
        cocoaFrame: CGRect,
        cgBounds: CGRect,
        backingScaleFactor: Double = 2.0,
        refreshRateHz: Double = 60.0,
        maxEDRHeadroom: Double = 1.0,
        isPrimary: Bool = false
    ) {
        self.id = id
        self.name = name
        self.cocoaFrame = cocoaFrame
        self.cgBounds = cgBounds
        self.backingScaleFactor = max(1.0, backingScaleFactor)
        self.refreshRateHz = max(1.0, refreshRateHz)
        self.maxEDRHeadroom = max(1.0, maxEDRHeadroom)
        self.isPrimary = isPrimary
    }

    public var pixelSize: PixelSize {
        PixelSize(
            width: Int((cocoaFrame.width * backingScaleFactor).rounded()),
            height: Int((cocoaFrame.height * backingScaleFactor).rounded())
        )
    }

    public var supportsHDR: Bool {
        maxEDRHeadroom > 1.0
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(cocoaFrame.origin.x)
        hasher.combine(cocoaFrame.origin.y)
        hasher.combine(cocoaFrame.size.width)
        hasher.combine(cocoaFrame.size.height)
        hasher.combine(cgBounds.origin.x)
        hasher.combine(cgBounds.origin.y)
        hasher.combine(cgBounds.size.width)
        hasher.combine(cgBounds.size.height)
        hasher.combine(backingScaleFactor)
        hasher.combine(refreshRateHz)
        hasher.combine(maxEDRHeadroom)
        hasher.combine(isPrimary)
    }
}

/// Centralized, unit-tested geometry utilities converting between macOS CoreGraphics (Y-down)
/// and AppKit/Cocoa (Y-up) global desktop coordinate spaces.
///
/// Both coordinate systems are anchored on the primary display (`cocoaFrame.origin == .zero`):
/// - CoreGraphics: origin at primary display TOP-left, +Y points DOWN.
/// - AppKit/Cocoa: origin at primary display BOTTOM-left, +Y points UP.
public enum ScreenGeometry: Sendable {
    /// Locates the primary display (`cocoaFrame.origin == .zero`), falling back to `isPrimary`,
    /// then the first display in the array.
    public static func primaryDisplay(in displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        if let originPrimary = displays.first(where: {
            abs($0.cocoaFrame.origin.x) < 0.5 && abs($0.cocoaFrame.origin.y) < 0.5
        }) {
            return originPrimary
        }
        if let flaggedPrimary = displays.first(where: \.isPrimary) {
            return flaggedPrimary
        }
        return displays.first
    }

    /// Returns the primary display height in logical points used as the Y-flip axis.
    public static func primaryHeight(in displays: [DisplayDescriptor]) -> CGFloat {
        guard let primary = primaryDisplay(in: displays) else { return 0 }
        return primary.cocoaFrame.height > 0 ? primary.cocoaFrame.height : primary.cgBounds.height
    }

    // MARK: - Coordinate Conversion (CG Y-down <-> AppKit Y-up)

    /// Converts a point from CoreGraphics (Y-down) to AppKit (Y-up).
    public static func cgToCocoa(point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Converts a point from AppKit (Y-up) to CoreGraphics (Y-down).
    public static func cocoaToCG(point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Converts a point from CoreGraphics (Y-down) to AppKit (Y-up) using the display list's primary anchor.
    public static func cgToCocoa(point: CGPoint, displays: [DisplayDescriptor]) -> CGPoint {
        cgToCocoa(point: point, primaryHeight: primaryHeight(in: displays))
    }

    /// Converts a point from AppKit (Y-up) to CoreGraphics (Y-down) using the display list's primary anchor.
    public static func cocoaToCG(point: CGPoint, displays: [DisplayDescriptor]) -> CGPoint {
        cocoaToCG(point: point, primaryHeight: primaryHeight(in: displays))
    }

    /// Converts a rectangle from CoreGraphics (Y-down) to AppKit (Y-up).
    public static func cgToCocoa(rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        let normalized = rect.standardized
        return CGRect(
            x: normalized.origin.x,
            y: primaryHeight - (normalized.origin.y + normalized.size.height),
            width: normalized.size.width,
            height: normalized.size.height
        )
    }

    /// Converts a rectangle from AppKit (Y-up) to CoreGraphics (Y-down).
    public static func cocoaToCG(rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        let normalized = rect.standardized
        return CGRect(
            x: normalized.origin.x,
            y: primaryHeight - (normalized.origin.y + normalized.size.height),
            width: normalized.size.width,
            height: normalized.size.height
        )
    }

    /// Converts a rectangle from CoreGraphics (Y-down) to AppKit (Y-up) using the display list's primary anchor.
    public static func cgToCocoa(rect: CGRect, displays: [DisplayDescriptor]) -> CGRect {
        cgToCocoa(rect: rect, primaryHeight: primaryHeight(in: displays))
    }

    /// Converts a rectangle from AppKit (Y-up) to CoreGraphics (Y-down) using the display list's primary anchor.
    public static func cocoaToCG(rect: CGRect, displays: [DisplayDescriptor]) -> CGRect {
        cocoaToCG(rect: rect, primaryHeight: primaryHeight(in: displays))
    }

    // MARK: - Display Matching & Multi-Monitor Targeting

    /// Finds the best-matching display for a CoreGraphics (Y-down) window rect:
    /// prefers the display with the largest intersection area; if completely off-screen,
    /// selects the display with the shortest Euclidean distance from the rect's center.
    public static func bestDisplay(
        forCGRect rect: CGRect,
        in displays: [DisplayDescriptor]
    ) -> DisplayDescriptor? {
        bestDisplay(for: rect.standardized, in: displays, boundsKeyPath: \.cgBounds)
    }

    /// Finds the best-matching display for an AppKit (Y-up) window rect.
    public static func bestDisplay(
        forCocoaRect rect: CGRect,
        in displays: [DisplayDescriptor]
    ) -> DisplayDescriptor? {
        bestDisplay(for: rect.standardized, in: displays, boundsKeyPath: \.cocoaFrame)
    }

    /// Returns the displays selected by `mode` for a CoreGraphics (Y-down) window rect.
    public static func targetDisplays(
        forCGRect rect: CGRect,
        mode: MultiMonitorMode,
        in displays: [DisplayDescriptor]
    ) -> [DisplayDescriptor] {
        targetDisplays(for: rect.standardized, mode: mode, in: displays, boundsKeyPath: \.cgBounds)
    }

    /// Returns the displays selected by `mode` for an AppKit (Y-up) window rect.
    public static func targetDisplays(
        forCocoaRect rect: CGRect,
        mode: MultiMonitorMode,
        in displays: [DisplayDescriptor]
    ) -> [DisplayDescriptor] {
        targetDisplays(for: rect.standardized, mode: mode, in: displays, boundsKeyPath: \.cocoaFrame)
    }

    /// Returns the combined AppKit (Y-up) bounding frame for the selected multi-monitor target.
    public static func targetCocoaFrame(
        forCGRect rect: CGRect,
        mode: MultiMonitorMode,
        in displays: [DisplayDescriptor]
    ) -> CGRect? {
        let selected = targetDisplays(forCGRect: rect, mode: mode, in: displays)
        return unionRect(selected.map(\.cocoaFrame))
    }

    /// Returns the combined CoreGraphics (Y-down) bounding frame for the selected multi-monitor target.
    public static func targetCGBounds(
        forCGRect rect: CGRect,
        mode: MultiMonitorMode,
        in displays: [DisplayDescriptor]
    ) -> CGRect? {
        let selected = targetDisplays(forCGRect: rect, mode: mode, in: displays)
        return unionRect(selected.map(\.cgBounds))
    }

    // MARK: - Anti-Occlusion Helper

    /// Shrinks an AppKit (Y-up) overlay rect by `insetPoints` (default 1 pt) along the bottom edge
    /// so macOS WindowServer / App Nap / browsers never treat the underlying window as 100% occluded.
    public static func antiOcclusionInset(cocoaRect: CGRect, insetPoints: CGFloat = 1.0) -> CGRect {
        let normalized = cocoaRect.standardized
        let inset = max(0, insetPoints)
        guard inset > 0, normalized.size.height > inset * 2 else {
            return normalized
        }
        return CGRect(
            x: normalized.origin.x,
            y: normalized.origin.y + inset,
            width: normalized.size.width,
            height: normalized.size.height - inset
        )
    }

    /// Shrinks a CoreGraphics (Y-down) overlay rect by `insetPoints` (default 1 pt) along the bottom edge.
    public static func antiOcclusionInset(cgRect: CGRect, insetPoints: CGFloat = 1.0) -> CGRect {
        let normalized = cgRect.standardized
        let inset = max(0, insetPoints)
        guard inset > 0, normalized.size.height > inset * 2 else {
            return normalized
        }
        return CGRect(
            x: normalized.origin.x,
            y: normalized.origin.y,
            width: normalized.size.width,
            height: normalized.size.height - inset
        )
    }

    // MARK: - Private Helpers

    private static func bestDisplay(
        for rect: CGRect,
        in displays: [DisplayDescriptor],
        boundsKeyPath: KeyPath<DisplayDescriptor, CGRect>
    ) -> DisplayDescriptor? {
        guard !displays.isEmpty else { return nil }

        var bestOverlapDisplay: DisplayDescriptor?
        var bestOverlapArea: CGFloat = 0

        for display in displays {
            let intersection = rect.intersection(display[keyPath: boundsKeyPath])
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestOverlapArea {
                bestOverlapArea = area
                bestOverlapDisplay = display
            } else if area == bestOverlapArea, let current = bestOverlapDisplay {
                if display.isPrimary && !current.isPrimary {
                    bestOverlapDisplay = display
                } else if display.isPrimary == current.isPrimary && display.id < current.id {
                    bestOverlapDisplay = display
                }
            }
        }

        if let bestOverlapDisplay {
            return bestOverlapDisplay
        }

        // No overlap: pick closest display by distance from rect center to clamped point on display bounds.
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return displays.min { lhs, rhs in
            let dL = squaredDistance(from: center, to: lhs[keyPath: boundsKeyPath])
            let dR = squaredDistance(from: center, to: rhs[keyPath: boundsKeyPath])
            if dL != dR { return dL < dR }
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.id < rhs.id
        }
    }

    private static func targetDisplays(
        for rect: CGRect,
        mode: MultiMonitorMode,
        in displays: [DisplayDescriptor],
        boundsKeyPath: KeyPath<DisplayDescriptor, CGRect>
    ) -> [DisplayDescriptor] {
        guard !displays.isEmpty else { return [] }
        switch mode {
        case .closest:
            return bestDisplay(for: rect, in: displays, boundsKeyPath: boundsKeyPath).map { [$0] } ?? []
        case .intersected:
            let overlapping = displays.filter { display in
                let inter = rect.intersection(display[keyPath: boundsKeyPath])
                return !inter.isNull && !inter.isEmpty
            }
            if !overlapping.isEmpty {
                return overlapping
            }
            return bestDisplay(for: rect, in: displays, boundsKeyPath: boundsKeyPath).map { [$0] } ?? []
        case .all:
            return displays
        }
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }

    private static func unionRect(_ rects: [CGRect]) -> CGRect? {
        guard var acc = rects.first?.standardized else { return nil }
        for rect in rects.dropFirst() {
            acc = acc.union(rect.standardized)
        }
        return acc
    }
}
