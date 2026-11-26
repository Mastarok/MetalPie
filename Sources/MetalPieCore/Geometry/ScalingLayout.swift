import CoreGraphics
import Foundation
import Metal

/// Clamps a Metal 2D texture width or height into the guaranteed Apple Silicon valid range `1...maxDimension`
/// (capped at `ScalingLayoutCalculator.maxMetalTextureDimension = 16_384`).
@inlinable
public func clampMetalTextureDimension(
    _ value: Int,
    maxDimension: Int = ScalingLayoutCalculator.maxMetalTextureDimension
) -> Int {
    let cap = min(max(1, maxDimension), ScalingLayoutCalculator.maxMetalTextureDimension)
    return min(cap, max(1, value))
}

/// Normalizes a Metal pixel format into a compute-writable (`MTLTextureUsage.shaderWrite`) format so
/// `device.makeTexture(descriptor:)` NEVER fails `-[MTLTextureDescriptorInternal validateWithDevice:]` (`SIGABRT`).
///
/// Maps sRGB views (`.bgra8Unorm_srgb`, `.rgba8Unorm_srgb`, XR sRGB) to their linear compute-writable
/// equivalents and `.invalid` / unsupported formats to `.bgra8Unorm`.
public func sanitizedComputeTextureFormat(_ format: MTLPixelFormat) -> MTLPixelFormat {
    switch format {
    case .bgra8Unorm, .rgba8Unorm, .bgr10a2Unorm, .rgb10a2Unorm,
         .rgba16Float, .rgba32Float,
         .r8Unorm, .rg8Unorm,
         .r16Unorm, .rg16Unorm, .rgba16Unorm,
         .r16Float, .rg16Float,
         .r32Float, .rg32Float,
         .r32Uint, .rg32Uint, .rgba32Uint,
         .bgr10_xr, .bgra10_xr:
        return format
    case .bgra8Unorm_srgb:
        return .bgra8Unorm
    case .rgba8Unorm_srgb:
        return .rgba8Unorm
    case .bgr10_xr_srgb:
        return .bgr10_xr
    case .bgra10_xr_srgb:
        return .bgra10_xr
    case .invalid:
        return .bgra8Unorm
    default:
        return .bgra8Unorm
    }
}

/// Optional capability adopted by effect renderers that perform GPU 1x demagnification,
/// SCStream active-content sub-rect cropping, and/or fullscreen video super-resolution pre-downscaling
/// before the effect chain.
public protocol EffectPreScaleConfigurable: AnyObject, Sendable {
    /// True when 1x Non-Retina demagnification (nearest or bilinear) is active.
    var isDemagnifyActive: Bool { get }
    /// Target pixel dimensions for fullscreen video super-resolution pre-downscaling (`nil` = disabled).
    var fullscreenVideoPreDownscaleSize: PixelSize? { get set }
    /// Optional active SCStream content sub-rectangle in raw source texture pixels (cropped BEFORE
    /// pre-downscaling and user `CropInsets` when ScreenCaptureKit pads an IOSurface with black margins).
    var sourceContentPixelRect: PixelRect? { get set }
    /// When `true`, the caller manages cursor-free screenshots and duplicate-frame output retention
    /// externally, eliminating redundant per-frame full-frame snapshot GPU blits.
    var usesExternalOutputCache: Bool { get set }
}

public extension EffectPreScaleConfigurable {
    var sourceContentPixelRect: PixelRect? {
        get { nil }
        set {}
    }

    var usesExternalOutputCache: Bool {
        get { false }
        set {}
    }
}

/// Pure display-refresh pacer for `.directPresent` mode that prevents bursty capture streams
/// (e.g. 150-240Hz browser hover animations) from over-submitting beyond the display's refresh rate
/// and exhausting `CAMetalLayer`'s 3-drawable pool.
public struct DirectPresentPacer: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Submit immediately (first frame, or elapsed >= `displayInterval * jitterAllowance`).
        case submitNow
        /// Coalesce incoming frames in the mailbox and wake at `wakeTime` (exact display interval).
        case coalesceUntil(wakeTime: Double)
    }

    /// Fraction of one display interval allowed for normal capture jitter before coalescing kicks in.
    public static let jitterAllowanceRatio: Double = 0.85

    public private(set) var lastSubmitTime: Double = 0

    public init() {}

    public mutating func reset() {
        lastSubmitTime = 0
    }

    public mutating func recordSubmitted(at time: Double) {
        lastSubmitTime = time
    }

    /// Evaluates whether a `.directPresent` submission at `now` should proceed immediately or coalesce
    /// until the next display-refresh slot (`lastSubmitTime + displayInterval`).
    public func evaluate(now: Double, displayRefreshHz: Double) -> Decision {
        guard lastSubmitTime > 0 else { return .submitNow }
        let displayInterval = 1.0 / max(30.0, displayRefreshHz)
        let elapsed = now - lastSubmitTime
        if elapsed >= displayInterval * Self.jitterAllowanceRatio {
            return .submitNow
        }
        return .coalesceUntil(wakeTime: lastSubmitTime + displayInterval)
    }
}

/// Scaling geometry mode controlling how an effect computes its target pixel dimensions.
public enum ScalingType: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Aspect-ratio-preserving largest fit inside target bounds (letterbox/pillarbox).
    case fit
    /// Aspect-ratio-preserving smallest cover filling target bounds (crops excess).
    case fill
    /// Non-uniform stretch to exact target width and height.
    case stretch
    /// Largest whole-number integer multiple (`k >= 1`) that fits inside target bounds.
    case integerFit
    /// Explicit relative multiplier (`scaleFactorX`, `scaleFactorY`) of input dimensions.
    case normal
    /// Exact pixel dimensions (`absoluteWidth`, `absoluteHeight`).
    case absolute

    public var id: String { rawValue }
}

/// 9-point placement anchor for positioning the scaled output inside the display/window canvas.
public enum OutputAlignment: String, Codable, Sendable, CaseIterable, Identifiable {
    case topLeft
    case top
    case topRight
    case left
    case center
    case right
    case bottomLeft
    case bottom
    case bottomRight

    public var id: String { rawValue }

    /// Horizontal anchor fraction in `[0.0, 0.5, 1.0]` (left -> center -> right).
    public var horizontalFraction: Double {
        switch self {
        case .topLeft, .left, .bottomLeft: return 0.0
        case .top, .center, .bottom: return 0.5
        case .topRight, .right, .bottomRight: return 1.0
        }
    }

    /// Vertical anchor fraction in Y-down coordinates (`0.0` = top, `0.5` = center, `1.0` = bottom).
    public var verticalFractionYDown: Double {
        switch self {
        case .topLeft, .top, .topRight: return 0.0
        case .left, .center, .right: return 0.5
        case .bottomLeft, .bottom, .bottomRight: return 1.0
        }
    }

    /// Vertical anchor fraction in AppKit Y-up coordinates (`0.0` = bottom, `0.5` = center, `1.0` = top).
    public var verticalFractionYUp: Double {
        1.0 - verticalFractionYDown
    }
}

/// Per-edge crop insets in source capture pixels.
public struct CropInsets: Hashable, Codable, Sendable {
    public static let minimumRemainingDimension: Int = 64
    public static let zero = CropInsets()

    public var enabled: Bool
    public var left: Int
    public var top: Int
    public var right: Int
    public var bottom: Int

    public init(
        enabled: Bool = false,
        left: Int = 0,
        top: Int = 0,
        right: Int = 0,
        bottom: Int = 0
    ) {
        self.enabled = enabled
        self.left = max(0, left)
        self.top = max(0, top)
        self.right = max(0, right)
        self.bottom = max(0, bottom)
    }

    /// Returns true if applying these insets (when enabled) leaves at least `minimumRemainingDimension`
    /// pixels in both axes (or the source itself is already smaller and insets are 0).
    public func isValid(for sourceSize: PixelSize) -> Bool {
        guard enabled else { return sourceSize.isValid }
        let remW = sourceSize.width - max(0, left) - max(0, right)
        let remH = sourceSize.height - max(0, top) - max(0, bottom)
        let minW = min(sourceSize.width, Self.minimumRemainingDimension)
        let minH = min(sourceSize.height, Self.minimumRemainingDimension)
        return remW >= minW && remH >= minH
    }

    /// Clamps crop margins so remaining width and height are never below `minimumRemainingDimension`
    /// (or `sourceSize` if `sourceSize` itself is smaller than 64 px).
    public func clamped(for sourceSize: PixelSize) -> CropInsets {
        guard enabled, sourceSize.isValid else {
            return CropInsets(enabled: false, left: 0, top: 0, right: 0, bottom: 0)
        }

        let (clampedLeft, clampedRight) = Self.clampAxis(
            first: max(0, left),
            second: max(0, right),
            total: sourceSize.width,
            minRemaining: Self.minimumRemainingDimension
        )
        let (clampedTop, clampedBottom) = Self.clampAxis(
            first: max(0, top),
            second: max(0, bottom),
            total: sourceSize.height,
            minRemaining: Self.minimumRemainingDimension
        )

        return CropInsets(
            enabled: true,
            left: clampedLeft,
            top: clampedTop,
            right: clampedRight,
            bottom: clampedBottom
        )
    }

    /// Computes the safely clamped source pixel rectangle inside `(0, 0, sourceSize.width, sourceSize.height)`.
    public func croppedRect(in sourceSize: PixelSize) -> PixelRect {
        guard sourceSize.isValid else { return .zero }
        let c = clamped(for: sourceSize)
        return PixelRect(
            x: c.left,
            y: c.top,
            width: max(1, sourceSize.width - c.left - c.right),
            height: max(1, sourceSize.height - c.top - c.bottom)
        )
    }

    /// Proportionally scales pixel crop insets when the captured frame is pre-downscaled / demagnified
    /// from `rawSourceSize` to `effectiveSourceSize` before entering the effect chain.
    public func scaled(from rawSourceSize: PixelSize, to effectiveSourceSize: PixelSize) -> CropInsets {
        guard enabled,
              rawSourceSize.isValid,
              effectiveSourceSize.isValid,
              rawSourceSize != effectiveSourceSize
        else {
            return self
        }
        let scaleX = Double(effectiveSourceSize.width) / Double(rawSourceSize.width)
        let scaleY = Double(effectiveSourceSize.height) / Double(rawSourceSize.height)
        return CropInsets(
            enabled: true,
            left: max(0, Int((Double(left) * scaleX).rounded())),
            top: max(0, Int((Double(top) * scaleY).rounded())),
            right: max(0, Int((Double(right) * scaleX).rounded())),
            bottom: max(0, Int((Double(bottom) * scaleY).rounded()))
        )
    }

    private static func clampAxis(
        first: Int,
        second: Int,
        total: Int,
        minRemaining: Int
    ) -> (Int, Int) {
        let effectiveMin = min(total, minRemaining)
        let maxCrop = max(0, total - effectiveMin)
        let sum = first + second
        guard sum > maxCrop, sum > 0 else {
            return (first, second)
        }

        let scale = Double(maxCrop) / Double(sum)
        let scaledFirst = min(maxCrop, Int((Double(first) * scale).rounded(.down)))
        let scaledSecond = min(maxCrop - scaledFirst, Int((Double(second) * scale).rounded(.down)))
        return (scaledFirst, scaledSecond)
    }
}

/// Overlay presentation strategy: fullscreen display overlay or resizable scaled window.
public enum PresentationMode: Hashable, Codable, Sendable {
    case fullscreen
    case windowed(initialScale: Double? = nil, width: Double? = nil)

    public var isFullscreen: Bool {
        if case .fullscreen = self { return true }
        return false
    }

    public var isWindowed: Bool {
        !isFullscreen
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case initialScale
        case width
    }

    private enum ModeTag: String, Codable {
        case fullscreen
        case windowed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(ModeTag.self, forKey: .type)
        switch tag {
        case .fullscreen:
            self = .fullscreen
        case .windowed:
            let initialScale = try container.decodeIfPresent(Double.self, forKey: .initialScale)
            let width = try container.decodeIfPresent(Double.self, forKey: .width)
            self = .windowed(initialScale: initialScale, width: width)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fullscreen:
            try container.encode(ModeTag.fullscreen, forKey: .type)
        case .windowed(let initialScale, let width):
            try container.encode(ModeTag.windowed, forKey: .type)
            try container.encodeIfPresent(initialScale, forKey: .initialScale)
            try container.encodeIfPresent(width, forKey: .width)
        }
    }
}

/// Resolved intermediate pixel sizes for a single pass in an effect chain.
public struct EffectPassLayout: Hashable, Codable, Sendable {
    public var effectInstanceID: UUID
    public var effectID: EffectID
    public var inputSize: PixelSize
    public var outputSize: PixelSize
    public var isAutoInsertedFallback: Bool

    public init(
        effectInstanceID: UUID,
        effectID: EffectID,
        inputSize: PixelSize,
        outputSize: PixelSize,
        isAutoInsertedFallback: Bool = false
    ) {
        self.effectInstanceID = effectInstanceID
        self.effectID = effectID
        self.inputSize = inputSize
        self.outputSize = outputSize
        self.isAutoInsertedFallback = isAutoInsertedFallback
    }
}

/// Complete, pure layout solution for rendering an effect chain and mapping cursor input.
public struct ScalingLayoutResult: Hashable, Codable, Sendable {
    /// Original uncropped capture frame dimensions in pixels.
    public var sourcePixelSize: PixelSize
    /// Clamped source region in capture pixel space (Y-down).
    public var croppedSourceRect: PixelRect
    /// Target drawable canvas dimensions in pixels.
    public var targetPixelSize: PixelSize
    /// Target overlay logical frame in global CG (Y-down) points.
    public var targetCGRect: CGRect
    /// Backing scale factor of the target overlay (`targetPixelSize / targetCGRect.size`).
    public var backingScaleFactor: Double
    /// Ordered effect passes, including any automatically inserted Bicubic Catmull-Rom fallback pass.
    public var effectPasses: [EffectPassLayout]
    /// True if an automatic Bicubic Catmull-Rom (`B=0, C=0.5`) resize pass was appended.
    public var needsAutoBicubicFallback: Bool
    /// Final texture pixel dimensions produced by the last pass.
    public var finalOutputPixelSize: PixelSize
    /// Placement of the final output image in target canvas pixels (Y-down).
    /// May exceed target canvas bounds in `.fill` mode.
    public var destinationPixelRect: PixelRect
    /// Visible clipped region inside target canvas pixels (Y-down) where image pixels are drawn.
    public var visibleContentPixelRect: PixelRect
    /// Placement of the final output image in global CG (Y-down) logical points.
    public var destinationRect: CGRect
    /// Visible clipped content region in global CG (Y-down) logical points, used for cursor mapping.
    public var contentRect: CGRect
    /// Normalized `[0, 1]` UV sub-rectangle of the final texture visible inside `visibleContentPixelRect`.
    /// Equals `(0, 0, 1, 1)` unless the image overflows target bounds (e.g. `.fill`).
    public var visibleTextureUVRect: CGRect

    public init(
        sourcePixelSize: PixelSize,
        croppedSourceRect: PixelRect,
        targetPixelSize: PixelSize,
        targetCGRect: CGRect,
        backingScaleFactor: Double,
        effectPasses: [EffectPassLayout],
        needsAutoBicubicFallback: Bool,
        finalOutputPixelSize: PixelSize,
        destinationPixelRect: PixelRect,
        visibleContentPixelRect: PixelRect,
        destinationRect: CGRect,
        contentRect: CGRect,
        visibleTextureUVRect: CGRect
    ) {
        self.sourcePixelSize = sourcePixelSize
        self.croppedSourceRect = croppedSourceRect
        self.targetPixelSize = targetPixelSize
        self.targetCGRect = targetCGRect
        self.backingScaleFactor = backingScaleFactor
        self.effectPasses = effectPasses
        self.needsAutoBicubicFallback = needsAutoBicubicFallback
        self.finalOutputPixelSize = finalOutputPixelSize
        self.destinationPixelRect = destinationPixelRect
        self.visibleContentPixelRect = visibleContentPixelRect
        self.destinationRect = destinationRect
        self.contentRect = contentRect
        self.visibleTextureUVRect = visibleTextureUVRect
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sourcePixelSize)
        hasher.combine(croppedSourceRect)
        hasher.combine(targetPixelSize)
        hasher.combine(targetCGRect.origin.x)
        hasher.combine(targetCGRect.origin.y)
        hasher.combine(targetCGRect.size.width)
        hasher.combine(targetCGRect.size.height)
        hasher.combine(backingScaleFactor)
        hasher.combine(effectPasses)
        hasher.combine(needsAutoBicubicFallback)
        hasher.combine(finalOutputPixelSize)
        hasher.combine(destinationPixelRect)
        hasher.combine(visibleContentPixelRect)
        hasher.combine(destinationRect.origin.x)
        hasher.combine(destinationRect.origin.y)
        hasher.combine(destinationRect.size.width)
        hasher.combine(destinationRect.size.height)
        hasher.combine(contentRect.origin.x)
        hasher.combine(contentRect.origin.y)
        hasher.combine(contentRect.size.width)
        hasher.combine(contentRect.size.height)
        hasher.combine(visibleTextureUVRect.origin.x)
        hasher.combine(visibleTextureUVRect.origin.y)
        hasher.combine(visibleTextureUVRect.size.width)
        hasher.combine(visibleTextureUVRect.size.height)
    }
}

/// Pure, deterministic layout calculator for MetalPie's multi-pass scaling graph.
public enum ScalingLayoutCalculator: Sendable {
    /// Maximum 2D texture width/height supported by Apple Silicon Metal GPUs (`MTLDevice`).
    public static let maxMetalTextureDimension: Int = 16_384

    /// Stable UUID used for auto-inserted Bicubic Catmull-Rom fallback passes.
    public static let autoBicubicPassID = UUID(uuidString: "A10B1C0B-1C00-4000-8000-000000000001")!

    /// Stable UUID used for automatic second-stage 2× neural upscaling on low-resolution sources
    /// (e.g. 480p -> 960p -> 1920p, matching official Anime4K `OUTPUT/INPUT > 2.4` chaining).
    public static let secondStageNeuralPassID = UUID(uuidString: "A10B1C0B-1C00-4000-8000-000000000002")!

    /// Clamps `size` into `1...maxDimension` while preserving aspect ratio whenever either axis exceeds `maxDimension`.
    public static func clampAspectPreserving(
        _ size: PixelSize,
        maxDimension: Int = maxMetalTextureDimension
    ) -> PixelSize {
        guard size.isValid else { return .zero }
        let cap = min(max(1, maxDimension), maxMetalTextureDimension)
        let w = max(1, size.width)
        let h = max(1, size.height)
        guard w > cap || h > cap else {
            return PixelSize(width: w, height: h)
        }
        let scale = Double(cap) / Double(max(w, h))
        let clampedW = max(1, min(cap, Int((Double(w) * scale).rounded())))
        let clampedH = max(1, min(cap, Int((Double(h) * scale).rounded())))
        return PixelSize(width: clampedW, height: clampedH)
    }

    /// Converts `SCStreamFrameInfo.contentRect` (reported in surface points, already incorporating
    /// `contentScale`) into clamped texture pixel coordinates inside `(0, 0, textureSize.width, textureSize.height)`.
    public static func convertSCKContentRectToPixels(
        pointRect: CGRect?,
        scaleFactor: Double,
        textureSize: PixelSize
    ) -> CGRect {
        guard textureSize.isValid else { return .zero }
        let fullRect = CGRect(x: 0, y: 0, width: Double(textureSize.width), height: Double(textureSize.height))
        guard let raw = pointRect else { return fullRect }
        let std = raw.standardized
        guard std.width.isFinite, std.height.isFinite,
              std.origin.x.isFinite, std.origin.y.isFinite,
              std.width > 0, std.height > 0
        else {
            return fullRect
        }

        let safeScale = max(1.0, scaleFactor.isFinite ? scaleFactor : 1.0)
        let maxW = Double(textureSize.width)
        let maxH = Double(textureSize.height)

        let rawX = (std.origin.x * safeScale).rounded()
        let rawY = (std.origin.y * safeScale).rounded()
        let rawW = (std.size.width * safeScale).rounded()
        let rawH = (std.size.height * safeScale).rounded()

        let clampedX = min(max(0.0, rawX), max(0.0, maxW - 1.0))
        let clampedY = min(max(0.0, rawY), max(0.0, maxH - 1.0))
        let clampedW = min(max(0.0, rawW), maxW - clampedX)
        let clampedH = min(max(0.0, rawH), maxH - clampedY)
        guard clampedW >= 1.0, clampedH >= 1.0 else {
            return fullRect
        }
        return CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
    }

    /// Returns a valid proper sub-rectangle in texture pixels when `SCStream` padded any edge of the
    /// backing IOSurface by `>= 2 px` (leaving active width >= 64 and height >= 64), or `nil` when
    /// active content already fills the full texture.
    public static func activeContentSubRect(
        contentPixelRect: CGRect,
        textureSize: PixelSize
    ) -> PixelRect? {
        guard textureSize.width >= CropInsets.minimumRemainingDimension,
              textureSize.height >= CropInsets.minimumRemainingDimension
        else {
            return nil
        }
        let std = contentPixelRect.standardized
        guard std.width.isFinite, std.height.isFinite,
              std.origin.x.isFinite, std.origin.y.isFinite,
              std.width > 0, std.height > 0
        else {
            return nil
        }

        let x = max(0, min(textureSize.width - 1, Int(std.origin.x.rounded())))
        let y = max(0, min(textureSize.height - 1, Int(std.origin.y.rounded())))
        let w = max(0, min(textureSize.width - x, Int(std.size.width.rounded())))
        let h = max(0, min(textureSize.height - y, Int(std.size.height.rounded())))

        guard w >= CropInsets.minimumRemainingDimension,
              h >= CropInsets.minimumRemainingDimension
        else {
            return nil
        }

        let leftMargin = x
        let topMargin = y
        let rightMargin = textureSize.width - (x + w)
        let bottomMargin = textureSize.height - (y + h)
        guard leftMargin >= 2 || topMargin >= 2 || rightMargin >= 2 || bottomMargin >= 2 else {
            return nil
        }
        return PixelRect(x: x, y: y, width: w, height: h)
    }

    /// Computes an optional GPU pre-downscale target size for fullscreen / display-filling video windows
    /// so upscalers (Anime4K, MetalFX, FSR 1.0, CuNNy, FSRCNNX, Lanczos, Jinc) perform genuine ~2x
    /// super-resolution instead of 1:1 no-op passthrough on bilinearly stretched fullscreen video,
    /// while NEVER accidentally pre-downscaling sharp native Retina desktop webpages or windowed apps.
    public static func computeFullscreenVideoPreDownscaleSize(
        rawSourceSize: PixelSize,
        targetPixelSize: PixelSize,
        presentationMode: PresentationMode,
        mode: FullscreenVideoInputMode,
        isNativeFullscreenSource: Bool = false,
        demagnifyActive: Bool = false,
        autoDetectedOptical: DetectedOpticalResolution? = nil
    ) -> PixelSize? {
        guard rawSourceSize.isValid, targetPixelSize.isValid, mode != .native else {
            return nil
        }

        // When `.auto` has a live confirmed GPU 1D-FFT optical resolution measurement, trust it across
        // ALL window sizes and aspect ratios (native fullscreen, maximized desktop IINA/VLC, 4:3, 16:9,
        // 2.39:1 cinema, and windowed players):
        // - Confirmed `.native` NEVER blurs Retina webpages/IDEs (even inside macOS Native Fullscreen Space!).
        // - Confirmed `.p480` / `.p720` / `.p1080` pre-downscales directly to the video's true native density!
        if mode == .auto, let optical = autoDetectedOptical, optical.isConfirmed {
            guard optical.tier != .native,
                  let detectedSize = optical.preDownscaleSize,
                  detectedSize.isValid,
                  (detectedSize.width < rawSourceSize.width || detectedSize.height < rawSourceSize.height)
            else {
                return nil
            }
            return clampAspectPreserving(detectedSize)
        }

        // Recognize full-screen / maximized video windows across 16:9, 16:10, 4:3 (e.g. classic anime
        // filling 100% height at ~83.7% width), and 21:9 ultrawide (filling 100% width at ~75% height).
        let widthFrac = Double(rawSourceSize.width) / Double(max(1, targetPixelSize.width))
        let heightFrac = Double(rawSourceSize.height) / Double(max(1, targetPixelSize.height))
        let coversTarget = (widthFrac >= 0.85 && heightFrac >= 0.50) || (heightFrac >= 0.85 && widthFrac >= 0.50)
        guard presentationMode.isFullscreen && coversTarget else {
            return nil
        }

        let srcW = rawSourceSize.width
        let srcH = rawSourceSize.height

        switch mode {
        case .native:
            return nil

        case .auto:
            // Fallback before first GPU optical probe completes (or in static layout calculation):
            // Only auto pre-downscale genuine fullscreen video spaces (HTML5 fullscreen, IINA, VLC, QuickTime)
            // or sources already identified as 2x magnified non-Retina content — NEVER sharp Retina webpages!
            guard isNativeFullscreenSource || demagnifyActive else { return nil }
            // Retina 2.5K / 3K / 4K fullscreen window -> exact 50% per axis (inverse of 2x bilinear stretch).
            guard srcW >= 2200 || srcH >= 1300 else { return nil }
            let outW = min(srcW, max(640, srcW / 2))
            let outH = min(srcH, max(360, srcH / 2))
            guard outW < srcW || outH < srcH else { return nil }
            return clampAspectPreserving(PixelSize(width: outW, height: outH))

        case .p480:
            guard srcH > 520 else { return nil }
            let scale = 480.0 / Double(srcH)
            let outW = max(1, Int((Double(srcW) * scale).rounded()))
            let candidate = clampAspectPreserving(PixelSize(width: outW, height: 480))
            return (candidate.width < srcW || candidate.height < srcH) ? candidate : nil

        case .p720:
            guard srcH > 760 else { return nil }
            let scale = 720.0 / Double(srcH)
            let outW = max(1, Int((Double(srcW) * scale).rounded()))
            let candidate = clampAspectPreserving(PixelSize(width: outW, height: 720))
            return (candidate.width < srcW || candidate.height < srcH) ? candidate : nil

        case .p1080:
            guard srcH > 1120 else { return nil }
            let scale = 1080.0 / Double(srcH)
            let outW = max(1, Int((Double(srcW) * scale).rounded()))
            let candidate = clampAspectPreserving(PixelSize(width: outW, height: 1080))
            return (candidate.width < srcW || candidate.height < srcH) ? candidate : nil
        }
    }

    /// Resolves the exact post-pre-scale source dimensions that will enter `ScalingLayoutCalculator.calculate`
    /// and the effect chain, coalescing `demagnifyActive` and `fullscreenVideoInput` so content is NEVER
    /// double-halved and effect pass sizes ALWAYS match the post-pre-scale texture (preventing 1/4 shrinking).
    public static func resolveEffectiveSourceSize(
        rawSourceSize: PixelSize,
        targetPixelSize: PixelSize,
        presentationMode: PresentationMode,
        fullscreenVideoInput: FullscreenVideoInputMode,
        demagnifyActive: Bool,
        isNativeFullscreenSource: Bool = false,
        autoDetectedOptical: DetectedOpticalResolution? = nil
    ) -> (effectiveSize: PixelSize, videoPreDownscaleSize: PixelSize?) {
        guard rawSourceSize.isValid else { return (rawSourceSize, nil) }
        let clampedRaw = clampAspectPreserving(rawSourceSize)

        if let videoSize = computeFullscreenVideoPreDownscaleSize(
            rawSourceSize: clampedRaw,
            targetPixelSize: targetPixelSize,
            presentationMode: presentationMode,
            mode: fullscreenVideoInput,
            isNativeFullscreenSource: isNativeFullscreenSource,
            demagnifyActive: demagnifyActive,
            autoDetectedOptical: autoDetectedOptical
        ) {
            return (effectiveSize: videoSize, videoPreDownscaleSize: videoSize)
        }

        if demagnifyActive, clampedRaw.width >= 64, clampedRaw.height >= 64 {
            let demagSize = PixelSize(
                width: max(1, clampedRaw.width / 2),
                height: max(1, clampedRaw.height / 2)
            )
            return (effectiveSize: demagSize, videoPreDownscaleSize: nil)
        }

        return (effectiveSize: clampedRaw, videoPreDownscaleSize: nil)
    }

    /// Computes exact cropped source rect, per-effect intermediate pixel sizes, optional auto-Bicubic
    /// fallback pass, aligned destination rect, and cursor-mapping content rect.
    ///
    /// - Parameters:
    ///   - sourcePixelSize: Full captured source frame size in pixels.
    ///   - targetPixelSize: Destination overlay/window drawable size in pixels.
    ///   - targetCGRect: Destination overlay frame in global CG (Y-down) logical points.
    ///     If `nil`, defaults to `(0, 0, targetPixelSize.width / backingScaleFactor, targetPixelSize.height / backingScaleFactor)`.
    ///   - backingScaleFactor: Display backing scale factor (e.g. `2.0` on Retina).
    ///   - crop: Optional source pixel crop insets (safely clamped so remaining width/height >= 64 px).
    ///   - effects: Ordered list of effect instances in the active `ScalingMode`.
    ///   - presentationMode: Fullscreen or Windowed scaling mode.
    ///   - alignment: 9-point output placement anchor inside target bounds.
    public static func calculate(
        sourcePixelSize: PixelSize,
        targetPixelSize: PixelSize,
        targetCGRect: CGRect? = nil,
        backingScaleFactor: Double = 1.0,
        crop: CropInsets = .zero,
        effects: [EffectInstance],
        presentationMode: PresentationMode = .fullscreen,
        alignment: OutputAlignment = .center
    ) -> ScalingLayoutResult {
        let safeScale = max(1.0, backingScaleFactor)
        let safeTargetSize = targetPixelSize.isValid
            ? clampAspectPreserving(targetPixelSize)
            : targetPixelSize
        let resolvedTargetCGRect = targetCGRect?.standardized ?? CGRect(
            x: 0,
            y: 0,
            width: Double(safeTargetSize.width) / safeScale,
            height: Double(safeTargetSize.height) / safeScale
        )

        guard sourcePixelSize.isValid, safeTargetSize.isValid else {
            return ScalingLayoutResult(
                sourcePixelSize: sourcePixelSize,
                croppedSourceRect: .zero,
                targetPixelSize: safeTargetSize,
                targetCGRect: resolvedTargetCGRect,
                backingScaleFactor: safeScale,
                effectPasses: [],
                needsAutoBicubicFallback: false,
                finalOutputPixelSize: .zero,
                destinationPixelRect: .zero,
                visibleContentPixelRect: .zero,
                destinationRect: .zero,
                contentRect: .zero,
                visibleTextureUVRect: CGRect(x: 0, y: 0, width: 1, height: 1)
            )
        }

        let croppedRect = crop.croppedRect(in: sourcePixelSize)
        var currentSize = clampAspectPreserving(croppedRect.size)
        let enabledEffects = effects.filter(\.enabled)

        // Cap intermediate fixed/discrete upscalers cleanly so 2x/4x neural & pixel shaders on Retina
        // or dual-display captures never explode VRAM or exceed Metal's 16,384px 2D texture limit.
        let intermediateFixedCap = min(
            maxMetalTextureDimension,
            max(max(safeTargetSize.width, safeTargetSize.height) * 2, 8192)
        )

        var passes: [EffectPassLayout] = []
        passes.reserveCapacity(enabledEffects.count + 1)

        // Track the user's intended final target size from the last scaling-capable effect
        // so fixed-factor shaders (e.g. Anime4K 2x configured with `.fit`) get an automatic
        // Bicubic Catmull-Rom final pass when their fixed output differs from desired target size.
        var desiredFinalSize: PixelSize? = nil
        var explicitFillOverflowAllowed = false
        var ranRestoreAtCurrentSize = false
        var bypassedUpscalerAfterRestore = false
        var lastFittedNeural2xEffectID: EffectID? = nil

        for instance in enabledEffects {
            let descriptor = EffectCatalog.descriptor(for: instance.effectID)
            let desiredForThisPass = clampAspectPreserving(computeDesiredSize(
                inputSize: currentSize,
                targetPixelSize: safeTargetSize,
                scalingType: instance.scalingType,
                scaleFactorX: instance.scaleFactorX,
                scaleFactorY: instance.scaleFactorY,
                absoluteWidth: instance.absoluteWidth,
                absoluteHeight: instance.absoluteHeight
            ))

            let actualOutput: PixelSize
            switch descriptor.scaleCapability {
            case .sameSize:
                if instance.effectID == .anime4kRestore,
                   bypassedUpscalerAfterRestore,
                   ranRestoreAtCurrentSize
                {
                    // Skip the post-upscale second Restore pass in double-restore presets (Mode A+A / B+B)
                    // when the preceding 2x upscaler was bypassed at 1:1 native resolution.
                    continue
                }
                actualOutput = clampAspectPreserving(currentSize)
                if instance.effectID == .anime4kRestore {
                    ranRestoreAtCurrentSize = true
                }
            case .fixed(let factor):
                let rawFixed = PixelSize(
                    width: max(1, Int((Double(currentSize.width) * factor).rounded())),
                    height: max(1, Int((Double(currentSize.height) * factor).rounded()))
                )
                let desiredScale = max(
                    Double(desiredForThisPass.width) / Double(max(1, currentSize.width)),
                    Double(desiredForThisPass.height) / Double(max(1, currentSize.height))
                )
                let rawFixedPixels = Double(rawFixed.width) * Double(rawFixed.height)
                // Follow official Anime4K `//!WHEN OUTPUT/INPUT > 1.2` gating for target-fitting modes:
                // when the source is already at or near target resolution (e.g. native 3K Retina
                // 3024x1898 -> 3021x1896 or 1440p -> 3024x1898), bypass fixed-2x upscaling instead of
                // blowing up to 5K/6K (15M-23M px) only for Auto Bicubic to immediately downscale back.
                // Explicit `.normal` scaling still honors the user's fixed multiplier verbatim.
                let bypassRedundantUpscale = instance.scalingType != .normal
                    && factor > 1.0
                    && (desiredScale <= 1.2 || (desiredScale < 1.35 && rawFixedPixels > 12_000_000.0))
                if bypassRedundantUpscale {
                    desiredFinalSize = desiredForThisPass
                    explicitFillOverflowAllowed = (instance.scalingType == .fill)
                    if ranRestoreAtCurrentSize {
                        bypassedUpscalerAfterRestore = true
                    }
                    continue
                }
                actualOutput = clampAspectPreserving(rawFixed, maxDimension: intermediateFixedCap)
                if instance.scalingType != .normal {
                    desiredFinalSize = clampAspectPreserving(computeDesiredSize(
                        inputSize: actualOutput,
                        targetPixelSize: safeTargetSize,
                        scalingType: instance.scalingType,
                        scaleFactorX: instance.scaleFactorX,
                        scaleFactorY: instance.scaleFactorY,
                        absoluteWidth: instance.absoluteWidth,
                        absoluteHeight: instance.absoluteHeight
                    ))
                    explicitFillOverflowAllowed = (instance.scalingType == .fill)
                    if abs(factor - 2.0) < 0.01,
                       instance.effectID == .anime4kUpscale
                        || instance.effectID == .anime4kUpscaleDenoise
                        || instance.effectID == .cunny
                        || instance.effectID == .fsrcnnx
                    {
                        lastFittedNeural2xEffectID = instance.effectID
                    }
                }
            case .discreteScales(let factors):
                // Pick the discrete factor closest to the desired scale ratio.
                let desiredScale = max(
                    Double(desiredForThisPass.width) / Double(max(1, currentSize.width)),
                    Double(desiredForThisPass.height) / Double(max(1, currentSize.height))
                )
                let chosenFactor = factors.min { lhs, rhs in
                    abs(lhs - desiredScale) < abs(rhs - desiredScale)
                } ?? 1.5
                let rawDiscrete = PixelSize(
                    width: max(1, Int((Double(currentSize.width) * chosenFactor).rounded())),
                    height: max(1, Int((Double(currentSize.height) * chosenFactor).rounded()))
                )
                let rawDiscretePixels = Double(rawDiscrete.width) * Double(rawDiscrete.height)
                let bypassRedundantUpscale = instance.scalingType != .normal
                    && chosenFactor > 1.0
                    && (desiredScale <= 1.2 || (desiredScale < 1.35 && rawDiscretePixels > 12_000_000.0))
                if bypassRedundantUpscale {
                    desiredFinalSize = desiredForThisPass
                    explicitFillOverflowAllowed = (instance.scalingType == .fill)
                    if ranRestoreAtCurrentSize {
                        bypassedUpscalerAfterRestore = true
                    }
                    continue
                }
                actualOutput = clampAspectPreserving(rawDiscrete, maxDimension: intermediateFixedCap)
                if instance.scalingType != .normal {
                    desiredFinalSize = clampAspectPreserving(computeDesiredSize(
                        inputSize: actualOutput,
                        targetPixelSize: safeTargetSize,
                        scalingType: instance.scalingType,
                        scaleFactorX: instance.scaleFactorX,
                        scaleFactorY: instance.scaleFactorY,
                        absoluteWidth: instance.absoluteWidth,
                        absoluteHeight: instance.absoluteHeight
                    ))
                    explicitFillOverflowAllowed = (instance.scalingType == .fill)
                }
            case .downscaleOnly:
                if desiredForThisPass.width <= currentSize.width && desiredForThisPass.height <= currentSize.height {
                    actualOutput = desiredForThisPass
                } else {
                    actualOutput = clampAspectPreserving(currentSize)
                    desiredFinalSize = desiredForThisPass
                    explicitFillOverflowAllowed = (instance.scalingType == .fill)
                }
            case .arbitrary:
                actualOutput = desiredForThisPass
                desiredFinalSize = desiredForThisPass
                explicitFillOverflowAllowed = (instance.scalingType == .fill)
            }

            passes.append(EffectPassLayout(
                effectInstanceID: instance.id,
                effectID: instance.effectID,
                inputSize: currentSize,
                outputSize: actualOutput,
                isAutoInsertedFallback: false
            ))
            if actualOutput != currentSize {
                ranRestoreAtCurrentSize = false
                bypassedUpscalerAfterRestore = false
            }
            currentSize = actualOutput
        }

        // Official Anime4K / neural 2x+2x chaining for low-resolution sources (e.g. 480p -> 960p -> 1920p -> 3K):
        // when a target-fitting fixed-2x neural upscaler still leaves >1.35x upscaling to reach desiredFinalSize
        // (such as 640x480 -> 1280x960 targeting 2531x1898), append a second fast 2x neural pass instead of
        // letting Auto Bicubic blur the remaining ~2x stretch, while staying strictly within display pixel budget!
        if let secondStageEffect = lastFittedNeural2xEffectID,
           let desired = desiredFinalSize,
           desired.isValid,
           currentSize.isValid
        {
            let remainingScale = max(
                Double(desired.width) / Double(max(1, currentSize.width)),
                Double(desired.height) / Double(max(1, currentSize.height))
            )
            let secondRaw = PixelSize(
                width: max(1, currentSize.width * 2),
                height: max(1, currentSize.height * 2)
            )
            let secondPixels = Double(secondRaw.width) * Double(secondRaw.height)
            let targetPixels = Double(safeTargetSize.width) * Double(safeTargetSize.height)
            let maxSecondStagePixels = max(targetPixels * 1.25, 6_000_000.0)
            if remainingScale > 1.35 && secondPixels <= maxSecondStagePixels {
                let secondOut = clampAspectPreserving(secondRaw, maxDimension: intermediateFixedCap)
                passes.append(EffectPassLayout(
                    effectInstanceID: secondStageNeuralPassID,
                    effectID: secondStageEffect,
                    inputSize: currentSize,
                    outputSize: secondOut,
                    isAutoInsertedFallback: false
                ))
                currentSize = secondOut
            }
        }

        // Determine if an automatic Bicubic Catmull-Rom (B=0, C=0.5) fallback pass is required.
        var fallbackTargetSize: PixelSize? = nil

        if passes.isEmpty {
            // Empty chain (or every fixed/discrete upscaler was bypassed at 1:1 native resolution):
            // honor the bypassed pass's desired target if set, otherwise fit inside target.
            let target = presentationMode.isWindowed
                ? safeTargetSize
                : (desiredFinalSize ?? computeFitSize(inputSize: currentSize, targetPixelSize: safeTargetSize))
            if target != currentSize {
                fallbackTargetSize = target
            }
        } else if presentationMode.isWindowed {
            // In windowed scaling mode, always conform final output to the live window size.
            if currentSize != safeTargetSize {
                fallbackTargetSize = safeTargetSize
            }
        } else {
            // Fullscreen mode:
            // 1. If a fixed/discrete effect was asked to Fit/Fill/Stretch/IntegerFit/Absolute and
            //    its output doesn't match the desired final size, append Bicubic to reach desiredFinalSize.
            if let desired = desiredFinalSize, desired != currentSize {
                fallbackTargetSize = desired
            } else if !explicitFillOverflowAllowed &&
                (currentSize.width > safeTargetSize.width || currentSize.height > safeTargetSize.height)
            {
                // 2. If output exceeds the display bounds (e.g. 2x neural scaler on 1080p -> 1440p monitor),
                //    automatically fit-downscale via Bicubic Catmull-Rom.
                fallbackTargetSize = computeFitSize(inputSize: currentSize, targetPixelSize: safeTargetSize)
            }
        }

        var needsAutoBicubicFallback = false
        if let rawFallback = fallbackTargetSize, rawFallback.isValid {
            let clampedFallback = clampAspectPreserving(rawFallback)
            if clampedFallback.isValid && clampedFallback != currentSize {
                passes.append(EffectPassLayout(
                    effectInstanceID: autoBicubicPassID,
                    effectID: .bicubic,
                    inputSize: currentSize,
                    outputSize: clampedFallback,
                    isAutoInsertedFallback: true
                ))
                currentSize = clampedFallback
                needsAutoBicubicFallback = true
            }
        }

        currentSize = clampAspectPreserving(currentSize)

        // Align final output inside target canvas pixels (Y-down).
        let destX = Int((Double(safeTargetSize.width - currentSize.width) * alignment.horizontalFraction).rounded())
        let destY = Int((Double(safeTargetSize.height - currentSize.height) * alignment.verticalFractionYDown).rounded())
        let destinationPixelRect = PixelRect(
            x: destX,
            y: destY,
            width: currentSize.width,
            height: currentSize.height
        )

        let canvasBounds = PixelRect(origin: (0, 0), size: safeTargetSize)
        let visibleContentPixelRect = destinationPixelRect.intersection(canvasBounds)

        // Compute normalized texture UV crop rectangle corresponding to the visible portion of the output.
        let uvRect: CGRect
        if currentSize.width > 0 && currentSize.height > 0 && !visibleContentPixelRect.isEmpty {
            let u0 = Double(visibleContentPixelRect.minX - destinationPixelRect.minX) / Double(currentSize.width)
            let v0 = Double(visibleContentPixelRect.minY - destinationPixelRect.minY) / Double(currentSize.height)
            let uw = Double(visibleContentPixelRect.width) / Double(currentSize.width)
            let vh = Double(visibleContentPixelRect.height) / Double(currentSize.height)
            uvRect = CGRect(x: u0, y: v0, width: uw, height: vh)
        } else {
            uvRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        // Map pixel rects into target global CG logical point coordinates.
        let pointsPerPixelX = resolvedTargetCGRect.width / Double(safeTargetSize.width)
        let pointsPerPixelY = resolvedTargetCGRect.height / Double(safeTargetSize.height)

        let destinationRect = CGRect(
            x: resolvedTargetCGRect.origin.x + Double(destinationPixelRect.x) * pointsPerPixelX,
            y: resolvedTargetCGRect.origin.y + Double(destinationPixelRect.y) * pointsPerPixelY,
            width: Double(destinationPixelRect.width) * pointsPerPixelX,
            height: Double(destinationPixelRect.height) * pointsPerPixelY
        )

        let contentRect = CGRect(
            x: resolvedTargetCGRect.origin.x + Double(visibleContentPixelRect.x) * pointsPerPixelX,
            y: resolvedTargetCGRect.origin.y + Double(visibleContentPixelRect.y) * pointsPerPixelY,
            width: Double(visibleContentPixelRect.width) * pointsPerPixelX,
            height: Double(visibleContentPixelRect.height) * pointsPerPixelY
        )

        return ScalingLayoutResult(
            sourcePixelSize: sourcePixelSize,
            croppedSourceRect: croppedRect,
            targetPixelSize: safeTargetSize,
            targetCGRect: resolvedTargetCGRect,
            backingScaleFactor: safeScale,
            effectPasses: passes,
            needsAutoBicubicFallback: needsAutoBicubicFallback,
            finalOutputPixelSize: currentSize,
            destinationPixelRect: destinationPixelRect,
            visibleContentPixelRect: visibleContentPixelRect,
            destinationRect: destinationRect,
            contentRect: contentRect,
            visibleTextureUVRect: uvRect
        )
    }

    /// Pure size computation for a single scaling rule (always aspect-preserving clamped to Metal's 16,384px max).
    public static func computeDesiredSize(
        inputSize: PixelSize,
        targetPixelSize: PixelSize,
        scalingType: ScalingType,
        scaleFactorX: Double = 1.0,
        scaleFactorY: Double = 1.0,
        absoluteWidth: Int? = nil,
        absoluteHeight: Int? = nil
    ) -> PixelSize {
        guard inputSize.isValid, targetPixelSize.isValid else { return .zero }

        let raw: PixelSize
        switch scalingType {
        case .fit:
            let base = computeFitSize(inputSize: inputSize, targetPixelSize: targetPixelSize)
            if abs(scaleFactorX - 1.0) < 1e-6 && abs(scaleFactorY - 1.0) < 1e-6 {
                raw = base
            } else {
                let sx = max(0.01, scaleFactorX)
                let sy = max(0.01, scaleFactorY)
                raw = PixelSize(
                    width: max(1, Int((Double(base.width) * sx).rounded())),
                    height: max(1, Int((Double(base.height) * sy).rounded()))
                )
            }

        case .fill:
            let scaleX = Double(targetPixelSize.width) / Double(inputSize.width)
            let scaleY = Double(targetPixelSize.height) / Double(inputSize.height)
            let coverScale = max(scaleX, scaleY)
            raw = PixelSize(
                width: max(1, Int((Double(inputSize.width) * coverScale).rounded())),
                height: max(1, Int((Double(inputSize.height) * coverScale).rounded()))
            )

        case .stretch:
            raw = targetPixelSize

        case .integerFit:
            let scaleX = Double(targetPixelSize.width) / Double(inputSize.width)
            let scaleY = Double(targetPixelSize.height) / Double(inputSize.height)
            let k = max(1, Int(floor(min(scaleX, scaleY))))
            raw = PixelSize(
                width: max(1, Int((Double(inputSize.width) * Double(k)).rounded())),
                height: max(1, Int((Double(inputSize.height) * Double(k)).rounded()))
            )

        case .normal:
            let sx = max(0.01, scaleFactorX)
            let sy = max(0.01, scaleFactorY)
            raw = PixelSize(
                width: max(1, Int((Double(inputSize.width) * sx).rounded())),
                height: max(1, Int((Double(inputSize.height) * sy).rounded()))
            )

        case .absolute:
            let w = max(1, absoluteWidth ?? targetPixelSize.width)
            let h = max(1, absoluteHeight ?? targetPixelSize.height)
            raw = PixelSize(width: w, height: h)
        }

        return clampAspectPreserving(raw)
    }

    public static func computeFitSize(inputSize: PixelSize, targetPixelSize: PixelSize) -> PixelSize {
        guard inputSize.isValid, targetPixelSize.isValid else { return .zero }
        let safeTarget = clampAspectPreserving(targetPixelSize)
        let scaleX = Double(safeTarget.width) / Double(inputSize.width)
        let scaleY = Double(safeTarget.height) / Double(inputSize.height)
        let fitScale = min(scaleX, scaleY)
        return clampAspectPreserving(PixelSize(
            width: max(1, Int((Double(inputSize.width) * fitScale).rounded())),
            height: max(1, Int((Double(inputSize.height) * fitScale).rounded()))
        ))
    }

    // MARK: - Fencepost-Accurate Cursor Mapping (Magpie (N - 1) Convention)

    /// Maps a point in the source window rect into the scaled content rect using fencepost-accurate
    /// linear interpolation (`first pixel -> first pixel`, `last pixel -> last pixel`).
    public static func mapSourcePointToScaled(
        _ sourcePoint: CGPoint,
        sourceRect: CGRect,
        contentRect: CGRect
    ) -> CGPoint {
        let srcSpanX = max(1.0, sourceRect.width - 1.0)
        let srcSpanY = max(1.0, sourceRect.height - 1.0)
        let dstSpanX = max(0.0, contentRect.width - 1.0)
        let dstSpanY = max(0.0, contentRect.height - 1.0)

        let u = (sourcePoint.x - sourceRect.minX) / srcSpanX
        let v = (sourcePoint.y - sourceRect.minY) / srcSpanY

        return CGPoint(
            x: contentRect.minX + u * dstSpanX,
            y: contentRect.minY + v * dstSpanY
        )
    }

    /// Maps a point in the scaled content rect back into the underlying source window rect.
    public static func mapScaledPointToSource(
        _ scaledPoint: CGPoint,
        sourceRect: CGRect,
        contentRect: CGRect
    ) -> CGPoint {
        let dstSpanX = max(1.0, contentRect.width - 1.0)
        let dstSpanY = max(1.0, contentRect.height - 1.0)
        let srcSpanX = max(0.0, sourceRect.width - 1.0)
        let srcSpanY = max(0.0, sourceRect.height - 1.0)

        let u = (scaledPoint.x - contentRect.minX) / dstSpanX
        let v = (scaledPoint.y - contentRect.minY) / dstSpanY

        return CGPoint(
            x: sourceRect.minX + u * srcSpanX,
            y: sourceRect.minY + v * srcSpanY
        )
    }
}
