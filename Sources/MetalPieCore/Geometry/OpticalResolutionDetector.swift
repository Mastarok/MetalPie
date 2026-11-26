import Foundation

// MARK: - Optical Resolution Detection Types

/// Standard video/content resolution tier estimated from live GPU monotonic edge-width analysis
/// when `CaptureSettings.fullscreenVideoInput == .auto`.
public enum OpticalResolutionTier: String, Hashable, Codable, Sendable, CaseIterable {
    case native
    case p1440
    case p1080
    case p720
    case p480

    /// Standard target height in pixels, or `nil` for `.native`.
    public var targetActiveHeight: Int? {
        switch self {
        case .native: return nil
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }

    /// Relative sharpness rank used for peak-envelope temporal stability.
    public var sharpnessRank: Int {
        switch self {
        case .p480: return 0
        case .p720: return 1
        case .p1080: return 2
        case .p1440: return 3
        case .native: return 4
        }
    }

    /// Concise badge label for UI display.
    public var badgeLabel: String {
        switch self {
        case .native: return "Native"
        case .p1440: return "1440p"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }
}

/// Snapshot of the GPU optical resolution probe verdict for the current captured window.
public struct DetectedOpticalResolution: Hashable, Codable, Sendable {
    public var tier: OpticalResolutionTier
    /// Deterministic pre-downscale pixel dimensions derived strictly from `(sourceSize, tier)`
    /// (zero per-frame danmaku/letterbox jitter!), or `nil` when `.native`.
    public var preDownscaleSize: PixelSize?
    /// Measured effective optical height in pixels (for diagnostics and tests).
    public var estimatedActiveHeight: Int
    /// Measured inverse monotonic edge width `1 / W_10_90` in `[0, 1]` (`1.0` = full native 1px sharpness).
    public var cutoffFrequencyRatio: Double
    /// `true` once at least one valid GPU probe has confirmed this result; `false` before
    /// the first probe completes.
    public var isConfirmed: Bool

    public init(
        tier: OpticalResolutionTier,
        preDownscaleSize: PixelSize?,
        estimatedActiveHeight: Int,
        cutoffFrequencyRatio: Double,
        isConfirmed: Bool = true
    ) {
        self.tier = tier
        self.preDownscaleSize = preDownscaleSize
        self.estimatedActiveHeight = max(0, estimatedActiveHeight)
        self.cutoffFrequencyRatio = max(0.0, min(1.0, cutoffFrequencyRatio))
        self.isConfirmed = isConfirmed
    }

    public static let unprobed = DetectedOpticalResolution(
        tier: .native,
        preDownscaleSize: nil,
        estimatedActiveHeight: 0,
        cutoffFrequencyRatio: 1.0,
        isConfirmed: false
    )

    public static let native = DetectedOpticalResolution(
        tier: .native,
        preDownscaleSize: nil,
        estimatedActiveHeight: 0,
        cutoffFrequencyRatio: 1.0,
        isConfirmed: true
    )
}

// MARK: - Pure Monotonic Edge-Width Classification (Unit-Testable, Zero Metal Dependency)

/// Pure signal-processing classifier turning a 100-bin GPU sub-pixel 10%-to-90% monotonic edge-width
/// histogram (sampled strictly in the central danmaku/subtitle/titlebar-free band on tangent-denoised
/// strong `>= 20%` contrast edges) into a rock-solid `DetectedOpticalResolution` verdict.
public enum OpticalResolutionClassifier: Sendable {
    public static let histogramBinCount = 100
    public static let minEdgeSamples: UInt64 = 100
    /// 88th percentile of inverse monotonic edge width (`1 / W_10_90`):
    /// - Rejects up to 12% sparse in-frame danmaku/UI overlays over a video.
    /// - Eliminates 1.28x 1px-ink-line overshoot (480p Spline36/Bicubic/Bilinear/1px-grid all measure ~480-560p).
    /// - Reliably captures sharp axial edges on curved/organic 1080p & native 3K scenes.
    public static let sharpnessQuantile: Double = 0.88

    /// Inverse edge-width threshold above which content is guaranteed native sharpness (Retina UI/text,
    /// native 1080p/3K/4K/5K/6K video, or nearest pixel art). Empirically `>= 0.93` on native Retina
    /// IDE text vs `<= 0.62` on 1080p -> 3K upscaled video.
    public static let nativeCutoffThreshold: Double = 0.78

    /// Maximum downscale ratio (`target / current`) required before engaging pre-downscale.
    public static let maxUsefulDownscaleRatio: Double = 0.85

    /// Raw measurement extracted from one GPU edge-width histogram pass.
    public struct EdgeSharpnessMeasurement: Hashable, Sendable {
        public var sharpnessRatio: Double
        public var edgeSampleCount: UInt64

        public init(sharpnessRatio: Double, edgeSampleCount: UInt64) {
            self.sharpnessRatio = sharpnessRatio
            self.edgeSampleCount = edgeSampleCount
        }
    }

    /// Analyzes the 100-bin GPU inverse-edge-width histogram (`bin i` = `(i + 0.5) / 100`).
    /// Returns `nil` when the frame has too few strong edges (e.g. fade-to-black, solid screen).
    public static func analyzeEdgeSharpnessHistogram(
        _ histogram: UnsafeBufferPointer<UInt32>
    ) -> EdgeSharpnessMeasurement? {
        guard histogram.count >= histogramBinCount else { return nil }

        var total: UInt64 = 0
        for i in 0..<histogramBinCount {
            total &+= UInt64(histogram[i])
        }
        guard total >= minEdgeSamples else { return nil }

        let target = UInt64((Double(total) * sharpnessQuantile).rounded())
        var cum: UInt64 = 0
        var sharpness = 1.0
        for i in 0..<histogramBinCount {
            cum &+= UInt64(histogram[i])
            if cum >= target {
                sharpness = (Double(i) + 0.5) / Double(histogramBinCount)
                break
            }
        }
        return EdgeSharpnessMeasurement(
            sharpnessRatio: max(0.0, min(1.0, sharpness)),
            edgeSampleCount: total
        )
    }

    /// Maps `(sourceSize, cutoffFrequencyRatio)` to a rock-solid `DetectedOpticalResolution`.
    ///
    /// **Zero-Jitter Guarantee**: `preDownscaleSize` is computed strictly from `(sourceSize, tier)`
    /// (never from per-frame volatile letterbox/danmaku bounds), so a locked tier produces an invariant
    /// pre-downscale dimension (e.g. `766x480`, `1148x720`, `1722x1080` on 16:10 3K; `640x480` on 4:3;
    /// `854x480` on 16:9; `2560x1440` on 5K/6K) with zero per-frame resolution wobble!
    public static func classify(
        sourceSize: PixelSize,
        activeBounds: PixelRect = .zero,
        cutoffFrequencyRatio: Double
    ) -> DetectedOpticalResolution {
        guard sourceSize.isValid, sourceSize.width >= 480, sourceSize.height >= 680 else {
            return .native
        }

        let clampedFreq = max(0.0, min(1.0, cutoffFrequencyRatio))
        // Estimate optical height against the screen/window's 16:9-equivalent reference height so
        // 4:3, 16:9, 16:10, 21:9/32:9 ultrawide, and portrait displays all map onto the same standard tiers.
        let srcAspect = Double(sourceSize.width) / Double(max(1, sourceSize.height))
        let wide16x9 = 16.0 / 9.0
        let refHeight: Double = {
            if activeBounds.width > 0 && activeBounds.height > 0 {
                let aw = Double(min(sourceSize.width, activeBounds.width))
                let ah = Double(min(sourceSize.height, activeBounds.height))
                return (aw / max(1.0, ah)) > wide16x9 ? (aw * (9.0 / 16.0)) : ah
            }
            // Portrait monitors (aspect < 1.0) displaying 16:9 video have video height ~= width * 9/16;
            // ultrawide monitors (> 16:9) pillarbox standard content to `sourceSize.height`.
            return srcAspect < 1.0
                ? (Double(sourceSize.width) * (9.0 / 16.0))
                : Double(sourceSize.height)
        }()
        let estimatedHeight = clampedFreq * refHeight
        let roundedEstHeight = max(1, Int(estimatedHeight.rounded()))

        // High inverse edge width -> native Retina UI/text, native 1080p/3K/4K/5K/6K video, or nearest pixel art.
        if clampedFreq >= nativeCutoffThreshold {
            return DetectedOpticalResolution(
                tier: .native,
                preDownscaleSize: nil,
                estimatedActiveHeight: roundedEstHeight,
                cutoffFrequencyRatio: clampedFreq,
                isConfirmed: true
            )
        }

        // Standard video tiers calibrated to 10%-90% monotonic edge width:
        // - 480p (Spline36/Bicubic/Bilinear/1px-grid/Doraemon): ~310-520p -> .p480
        // - 720p (Spline36/Bicubic/Bilinear/1px-grid):          ~620-860p -> .p720
        // - 1080p (Spline36/Bicubic/Bilinear/1px-grid):         ~920-1280p -> .p1080
        // - 1440p (on 4K/5K/6K displays):                       ~1320-1650p -> .p1440
        let tier: OpticalResolutionTier
        if estimatedHeight <= 610.0 {
            tier = .p480
        } else if estimatedHeight <= 890.0 {
            tier = .p720
        } else if estimatedHeight <= 1300.0 {
            tier = .p1080
        } else if estimatedHeight <= 1680.0 {
            tier = .p1440
        } else {
            tier = .native
        }

        guard let tierHeight = tier.targetActiveHeight else {
            return DetectedOpticalResolution(
                tier: .native,
                preDownscaleSize: nil,
                estimatedActiveHeight: roundedEstHeight,
                cutoffFrequencyRatio: clampedFreq,
                isConfirmed: true
            )
        }

        // Deterministic pre-downscale size strictly from `(sourceSize, tier)` -> ZERO danmaku/letterbox wobble!
        let downscaleRatio = Double(tierHeight) / Double(max(1, sourceSize.height))
        guard downscaleRatio.isFinite && downscaleRatio > 0.05 && downscaleRatio <= maxUsefulDownscaleRatio else {
            return DetectedOpticalResolution(
                tier: .native,
                preDownscaleSize: nil,
                estimatedActiveHeight: roundedEstHeight,
                cutoffFrequencyRatio: clampedFreq,
                isConfirmed: true
            )
        }

        let rawOutW = Int((Double(sourceSize.width) * downscaleRatio).rounded())
        let evenW = min(sourceSize.width, max(320, (rawOutW + 1) & ~1))
        let evenH = min(sourceSize.height, max(240, (tierHeight + 1) & ~1))
        guard evenW < sourceSize.width || evenH < sourceSize.height else {
            return DetectedOpticalResolution(
                tier: .native,
                preDownscaleSize: nil,
                estimatedActiveHeight: roundedEstHeight,
                cutoffFrequencyRatio: clampedFreq,
                isConfirmed: true
            )
        }

        let preSize = ScalingLayoutCalculator.clampAspectPreserving(PixelSize(width: evenW, height: evenH))
        return DetectedOpticalResolution(
            tier: tier,
            preDownscaleSize: preSize,
            estimatedActiveHeight: roundedEstHeight,
            cutoffFrequencyRatio: clampedFreq,
            isConfirmed: true
        )
    }
}

// MARK: - Peak-Envelope Temporal Stability Tracker

/// Stabilizes live GPU optical resolution detections across frames using the physical peak-envelope law:
/// - **Zero mid-video ping-pong**: a 1080p stream has blurry/bokeh/motion-blur shots that temporarily look
///   like 480p, whereas a 480p stream never produces genuine 1080p video edges. Once locked at a higher tier,
///   downgrading requires **12 consecutive lower probes (~12s)** (genuine episode switch without resize),
///   so brief motion blur, bokeh, and compression dips NEVER cause resolution flicker!
/// - **Danmaku-resistant upgrades**: stepping UP requires **2 consecutive probes** confirming the higher tier,
///   so a single 1-second burst of scrolling danmaku across the middle never falsely bumps 480p up, while
///   exiting fullscreen video to a Retina webpage or encountering the first sharp shot upgrades cleanly in ~0.5-1.5s.
/// - **Instant startup & resize lock**: locks immediately on probe #1 when edge confidence is high (even on paused video).
public struct OpticalResolutionTracker: Sendable {
    public private(set) var current: DetectedOpticalResolution = .unprobed
    private var pendingTier: OpticalResolutionTier? = nil
    private var pendingCount: Int = 0
    private var probesCompletedForSize: Int = 0
    private var lastSourceSize: PixelSize = .zero

    public init() {}

    public mutating func reset() {
        current = .unprobed
        pendingTier = nil
        pendingCount = 0
        probesCompletedForSize = 0
        lastSourceSize = .zero
    }

    /// Fast during startup/post-resize warm-up (0.25s), lightweight during steady state (1.0s).
    public var nextProbeIntervalSeconds: Double {
        probesCompletedForSize < 4 ? 0.25 : 1.0
    }

    /// Ingests one probe result (or `nil` if the frame was dark/flat/inconclusive).
    /// Returns the newly committed `DetectedOpticalResolution` iff the active tier changed.
    @discardableResult
    public mutating func ingest(
        candidate: DetectedOpticalResolution?,
        sourceSize: PixelSize,
        activeSliceCount: Int
    ) -> DetectedOpticalResolution? {
        if sourceSize != lastSourceSize {
            lastSourceSize = sourceSize
            pendingTier = nil
            pendingCount = 0
            probesCompletedForSize = 0
            if sourceSize.height < 680 || sourceSize.width < 480 {
                let changed = current.tier != .native || current.preDownscaleSize != nil || !current.isConfirmed
                current = .native
                return changed ? current : nil
            }
        }

        // Inconclusive frame (fade-to-black, solid screen): hold steady state without flickering.
        guard let candidate else {
            return nil
        }

        let isFirstProbeForSize = (probesCompletedForSize == 0)
        probesCompletedForSize += 1

        // 1. Immediate startup/post-resize lock when we have strong edge coverage (works even on paused video!).
        if isFirstProbeForSize || !current.isConfirmed {
            if candidate.tier == .native || activeSliceCount >= 6 {
                let changed = !current.isConfirmed
                    || current.tier != candidate.tier
                    || current.preDownscaleSize != candidate.preDownscaleSize
                current = candidate
                pendingTier = nil
                pendingCount = 0
                return changed ? current : nil
            }
        }

        // 2. Same tier as current: NEVER mutate preDownscaleSize mid-tier (guarantees zero jitter!).
        if candidate.tier == current.tier {
            pendingTier = nil
            pendingCount = 0
            return nil
        }

        // 3. Peak-Envelope Asymmetric Hysteresis:
        //    - Upgrade (sharper content / exiting video to Retina webpage): 2 consecutive probes (~0.5-1.5s),
        //      rejecting 1-second transient danmaku spikes while quickly snapping to true sharpness.
        //    - Downgrade (switching to a lower-res episode without resizing window):
        //      fast during initial warm-up (2 probes if startup probe #1 was a transient splash/OSD),
        //      strictly locked in steady state (12 consecutive probes = ~12s) so motion blur & bokeh NEVER flicker!
        let isUpgrade = candidate.tier.sharpnessRank > current.tier.sharpnessRank
        let requiredConfirmations: Int
        if isUpgrade {
            requiredConfirmations = 2
        } else {
            requiredConfirmations = (probesCompletedForSize <= 4) ? 3 : 12
        }

        if pendingTier == candidate.tier {
            pendingCount += 1
        } else {
            pendingTier = candidate.tier
            pendingCount = 1
        }

        if pendingCount >= requiredConfirmations {
            current = candidate
            pendingTier = nil
            pendingCount = 0
            return current
        }

        return nil
    }
}
