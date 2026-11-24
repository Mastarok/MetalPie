import CoreGraphics
import Foundation

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
    /// Stable UUID used for auto-inserted Bicubic Catmull-Rom fallback passes.
    public static let autoBicubicPassID = UUID(uuidString: "A10B1C0B-1C00-4000-8000-000000000001")!

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
        let resolvedTargetCGRect = targetCGRect?.standardized ?? CGRect(
            x: 0,
            y: 0,
            width: Double(targetPixelSize.width) / safeScale,
            height: Double(targetPixelSize.height) / safeScale
        )

        guard sourcePixelSize.isValid, targetPixelSize.isValid else {
            return ScalingLayoutResult(
                sourcePixelSize: sourcePixelSize,
                croppedSourceRect: .zero,
                targetPixelSize: targetPixelSize,
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
        var currentSize = croppedRect.size
        let enabledEffects = effects.filter(\.enabled)

        var passes: [EffectPassLayout] = []
        passes.reserveCapacity(enabledEffects.count + 1)

        // Track the user's intended final target size from the last scaling-capable effect
        // so fixed-factor shaders (e.g. Anime4K 2x configured with `.fit`) get an automatic
        // Bicubic Catmull-Rom final pass when their fixed output differs from desired target size.
        var desiredFinalSize: PixelSize? = nil
        var explicitFillOverflowAllowed = false

        for instance in enabledEffects {
            let descriptor = EffectCatalog.descriptor(for: instance.effectID)
            let desiredForThisPass = computeDesiredSize(
                inputSize: currentSize,
                targetPixelSize: targetPixelSize,
                scalingType: instance.scalingType,
                scaleFactorX: instance.scaleFactorX,
                scaleFactorY: instance.scaleFactorY,
                absoluteWidth: instance.absoluteWidth,
                absoluteHeight: instance.absoluteHeight
            )

            let actualOutput: PixelSize
            switch descriptor.scaleCapability {
            case .sameSize:
                actualOutput = currentSize
            case .fixed(let factor):
                actualOutput = PixelSize(
                    width: max(1, Int((Double(currentSize.width) * factor).rounded())),
                    height: max(1, Int((Double(currentSize.height) * factor).rounded()))
                )
                if instance.scalingType != .normal {
                    desiredFinalSize = computeDesiredSize(
                        inputSize: actualOutput,
                        targetPixelSize: targetPixelSize,
                        scalingType: instance.scalingType,
                        scaleFactorX: instance.scaleFactorX,
                        scaleFactorY: instance.scaleFactorY,
                        absoluteWidth: instance.absoluteWidth,
                        absoluteHeight: instance.absoluteHeight
                    )
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
                actualOutput = PixelSize(
                    width: max(1, Int((Double(currentSize.width) * chosenFactor).rounded())),
                    height: max(1, Int((Double(currentSize.height) * chosenFactor).rounded()))
                )
                if instance.scalingType != .normal {
                    desiredFinalSize = computeDesiredSize(
                        inputSize: actualOutput,
                        targetPixelSize: targetPixelSize,
                        scalingType: instance.scalingType,
                        scaleFactorX: instance.scaleFactorX,
                        scaleFactorY: instance.scaleFactorY,
                        absoluteWidth: instance.absoluteWidth,
                        absoluteHeight: instance.absoluteHeight
                    )
                    explicitFillOverflowAllowed = (instance.scalingType == .fill)
                }
            case .downscaleOnly:
                if desiredForThisPass.width <= currentSize.width && desiredForThisPass.height <= currentSize.height {
                    actualOutput = desiredForThisPass
                } else {
                    actualOutput = currentSize
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
                ? targetPixelSize
                : computeFitSize(inputSize: currentSize, targetPixelSize: targetPixelSize)
            if target != currentSize {
                fallbackTargetSize = target
            }
        } else if presentationMode.isWindowed {
            // In windowed scaling mode, always conform final output to the live window size.
            if currentSize != targetPixelSize {
                fallbackTargetSize = targetPixelSize
            }
        } else {
            // Fullscreen mode:
            // 1. If a fixed/discrete effect was asked to Fit/Fill/Stretch/IntegerFit/Absolute and
            //    its output doesn't match the desired final size, append Bicubic to reach desiredFinalSize.
            if let desired = desiredFinalSize, desired != currentSize {
                fallbackTargetSize = desired
            } else if !explicitFillOverflowAllowed &&
                (currentSize.width > targetPixelSize.width || currentSize.height > targetPixelSize.height)
            {
                // 2. If output exceeds the display bounds (e.g. 2x neural scaler on 1080p -> 1440p monitor),
                //    automatically fit-downscale via Bicubic Catmull-Rom.
                fallbackTargetSize = computeFitSize(inputSize: currentSize, targetPixelSize: targetPixelSize)
            }
        }

        var needsAutoBicubicFallback = false
        if let fallbackTarget = fallbackTargetSize, fallbackTarget.isValid, fallbackTarget != currentSize {
            passes.append(EffectPassLayout(
                effectInstanceID: autoBicubicPassID,
                effectID: .bicubic,
                inputSize: currentSize,
                outputSize: fallbackTarget,
                isAutoInsertedFallback: true
            ))
            currentSize = fallbackTarget
            needsAutoBicubicFallback = true
        }

        // Align final output inside target canvas pixels (Y-down).
        let destX = Int((Double(targetPixelSize.width - currentSize.width) * alignment.horizontalFraction).rounded())
        let destY = Int((Double(targetPixelSize.height - currentSize.height) * alignment.verticalFractionYDown).rounded())
        let destinationPixelRect = PixelRect(
            x: destX,
            y: destY,
            width: currentSize.width,
            height: currentSize.height
        )

        let canvasBounds = PixelRect(origin: (0, 0), size: targetPixelSize)
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
        let pointsPerPixelX = resolvedTargetCGRect.width / Double(targetPixelSize.width)
        let pointsPerPixelY = resolvedTargetCGRect.height / Double(targetPixelSize.height)

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
            targetPixelSize: targetPixelSize,
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

    /// Pure size computation for a single scaling rule.
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

        switch scalingType {
        case .fit:
            let base = computeFitSize(inputSize: inputSize, targetPixelSize: targetPixelSize)
            if abs(scaleFactorX - 1.0) < 1e-6 && abs(scaleFactorY - 1.0) < 1e-6 {
                return base
            }
            let sx = max(0.01, scaleFactorX)
            let sy = max(0.01, scaleFactorY)
            return PixelSize(
                width: max(1, Int((Double(base.width) * sx).rounded())),
                height: max(1, Int((Double(base.height) * sy).rounded()))
            )

        case .fill:
            let scaleX = Double(targetPixelSize.width) / Double(inputSize.width)
            let scaleY = Double(targetPixelSize.height) / Double(inputSize.height)
            let coverScale = max(scaleX, scaleY)
            return PixelSize(
                width: max(1, Int((Double(inputSize.width) * coverScale).rounded())),
                height: max(1, Int((Double(inputSize.height) * coverScale).rounded()))
            )

        case .stretch:
            return targetPixelSize

        case .integerFit:
            let scaleX = Double(targetPixelSize.width) / Double(inputSize.width)
            let scaleY = Double(targetPixelSize.height) / Double(inputSize.height)
            let k = max(1, Int(floor(min(scaleX, scaleY))))
            return PixelSize(
                width: inputSize.width * k,
                height: inputSize.height * k
            )

        case .normal:
            let sx = max(0.01, scaleFactorX)
            let sy = max(0.01, scaleFactorY)
            return PixelSize(
                width: max(1, Int((Double(inputSize.width) * sx).rounded())),
                height: max(1, Int((Double(inputSize.height) * sy).rounded()))
            )

        case .absolute:
            let w = max(1, absoluteWidth ?? targetPixelSize.width)
            let h = max(1, absoluteHeight ?? targetPixelSize.height)
            return PixelSize(width: w, height: h)
        }
    }

    public static func computeFitSize(inputSize: PixelSize, targetPixelSize: PixelSize) -> PixelSize {
        guard inputSize.isValid, targetPixelSize.isValid else { return .zero }
        let scaleX = Double(targetPixelSize.width) / Double(inputSize.width)
        let scaleY = Double(targetPixelSize.height) / Double(inputSize.height)
        let fitScale = min(scaleX, scaleY)
        return PixelSize(
            width: max(1, Int((Double(inputSize.width) * fitScale).rounded())),
            height: max(1, Int((Double(inputSize.height) * fitScale).rounded()))
        )
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
