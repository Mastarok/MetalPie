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

/// Optional capability adopted by effect renderers that perform GPU 1x demagnification and/or
/// fullscreen video super-resolution pre-downscaling before the effect chain.
public protocol EffectPreScaleConfigurable: AnyObject, Sendable {
    /// True when 1x Non-Retina demagnification (nearest or bilinear) is active.
    var isDemagnifyActive: Bool { get }
    /// Target pixel dimensions for fullscreen video super-resolution pre-downscaling (`nil` = disabled).
    var fullscreenVideoPreDownscaleSize: PixelSize? { get set }
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

    /// Computes an optional GPU pre-downscale target size for fullscreen / display-filling video windows
    /// so upscalers (Anime4K, MetalFX, FSR 1.0, CuNNy, FSRCNNX, Lanczos, Jinc) perform genuine ~2x
    /// super-resolution instead of 1:1 no-op passthrough on bilinearly stretched fullscreen video.
    public static func computeFullscreenVideoPreDownscaleSize(
        rawSourceSize: PixelSize,
        targetPixelSize: PixelSize,
        presentationMode: PresentationMode,
        mode: FullscreenVideoInputMode
    ) -> PixelSize? {
        guard rawSourceSize.isValid, targetPixelSize.isValid, mode != .native else {
            return nil
        }

        let coversTarget = Double(rawSourceSize.width) >= Double(targetPixelSize.width) * 0.85
            && Double(rawSourceSize.height) >= Double(targetPixelSize.height) * 0.85
        guard presentationMode.isFullscreen || coversTarget else {
            return nil
        }

        let srcW = rawSourceSize.width
        let srcH = rawSourceSize.height

        switch mode {
        case .native:
            return nil

        case .auto:
            // Retina 2.5K / 3K / 4K fullscreen window -> exact 50% per axis (inverse of 2x bilinear stretch).
            guard srcW >= 2200 || srcH >= 1300 else { return nil }
            let outW = min(srcW, max(640, srcW / 2))
            let outH = min(srcH, max(360, srcH / 2))
            guard outW < srcW || outH < srcH else { return nil }
            return clampAspectPreserving(PixelSize(width: outW, height: outH))

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
        demagnifyActive: Bool
    ) -> (effectiveSize: PixelSize, videoPreDownscaleSize: PixelSize?) {
        guard rawSourceSize.isValid else { return (rawSourceSize, nil) }
        let clampedRaw = clampAspectPreserving(rawSourceSize)

        if let videoSize = computeFullscreenVideoPreDownscaleSize(
            rawSourceSize: clampedRaw,
            targetPixelSize: targetPixelSize,
            presentationMode: presentationMode,
            mode: fullscreenVideoInput
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
                actualOutput = clampAspectPreserving(currentSize)
            case .fixed(let factor):
                let rawFixed = PixelSize(
                    width: max(1, Int((Double(currentSize.width) * factor).rounded())),
                    height: max(1, Int((Double(currentSize.height) * factor).rounded()))
                )
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
            currentSize = actualOutput
        }

        // Determine if an automatic Bicubic Catmull-Rom (B=0, C=0.5) fallback pass is required.
        var fallbackTargetSize: PixelSize? = nil

        if passes.isEmpty {
            // Empty chain: default to fitting inside target (or filling window).
            let target = presentationMode.isWindowed
                ? safeTargetSize
                : computeFitSize(inputSize: currentSize, targetPixelSize: safeTargetSize)
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
