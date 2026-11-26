import Foundation

// MARK: - Optical Resolution Detection Types

/// Standard video/content resolution tier estimated from live GPU 1D-FFT spectral bandwidth analysis
/// when `CaptureSettings.fullscreenVideoInput == .auto`.
public enum OpticalResolutionTier: String, Hashable, Codable, Sendable, CaseIterable {
    case native
    case p1440
    case p1080
    case p720
    case p480

    /// Standard 16:9-equivalent active video height in pixels, or `nil` for `.native`.
    public var targetActiveHeight: Int? {
        switch self {
        case .native: return nil
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }

    /// Relative sharpness rank used for asymmetric upward/downward temporal hysteresis.
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
    /// Exact full-frame pre-downscale pixel dimensions preserving the active video's true pixel density
    /// (including 4:3 pillarbox, 16:9 letterbox, and 2.39:1 cinemascope inside 16:10/16:9 screens),
    /// or `nil` when `.native` (no pre-downscale).
    public var preDownscaleSize: PixelSize?
    /// Measured 16:9-equivalent active optical height in pixels (for diagnostics and tests).
    public var estimatedActiveHeight: Int
    /// Measured Nyquist cutoff ratio in `[0, 1]` (`1.0` = full native pixel bandwidth).
    public var cutoffFrequencyRatio: Double
    /// `true` once at least one valid GPU spectral probe has confirmed this result; `false` before
    /// the first probe completes (so callers can distinguish "not yet probed" from "confirmed native").
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

// MARK: - Pure Edge-Spread-Function (ESF) Classification (Unit-Testable, Zero Metal Dependency)

/// Pure signal-processing classifier turning a 100-bin GPU Edge-Spread-Function (ESF) sharpness
/// histogram (measured strictly on strong `>= 20%` contrast edges inside active non-black bounds,
/// tangent-denoised so mpv/IINA 1-4 LSB dither and film grain have zero effect) into an exact
/// `DetectedOpticalResolution` verdict.
public enum OpticalResolutionClassifier: Sendable {
    public static let histogramBinCount = 100
    public static let minEdgeSamples: UInt64 = 120
    /// 88th percentile across strong edges: rejects sparse corner watermarks/OSD while reliably
    /// capturing native Retina anti-aliased text stems (`>= 0.82`) and in-focus 1080p bokeh subjects.
    public static let sharpnessQuantile: Double = 0.88

    /// Sharpness ratio above which content is guaranteed native sharpness (Retina UI/text, native
    /// 1080p/3K/4K/5K/6K video, or nearest-neighbor pixel art). Empirically `>= 0.82` on native
    /// anti-aliased Retina IDE text and `<= 0.67` on 1080p -> 3K upscaled video.
    public static let nativeCutoffThreshold: Double = 0.78

    /// Maximum downscale ratio (`target / current`) required before engaging pre-downscale.
    /// Avoids pointless ~90-95% rescaling when content is already near native density.
    public static let maxUsefulDownscaleRatio: Double = 0.85

    /// Raw measurement extracted from one GPU ESF histogram probe pass.
    public struct EdgeSharpnessMeasurement: Hashable, Sendable {
        public var sharpnessRatio: Double
        public var edgeSampleCount: UInt64

        public init(sharpnessRatio: Double, edgeSampleCount: UInt64) {
            self.sharpnessRatio = sharpnessRatio
            self.edgeSampleCount = edgeSampleCount
        }
    }

    /// Analyzes the 100-bin GPU ESF sharpness histogram (`bin i` = sharpness `(i + 0.5) / 100`).
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

    /// Maps `(sourceSize, activeBounds, cutoffFrequencyRatio)` to an exact `DetectedOpticalResolution`.
    /// Automatically preserves pixel density across 4:3 pillarbox, 16:9 letterbox, 16:10, 21:9/32:9 ultrawide,
    /// 2.39:1 cinema, portrait monitors, and displays from 720p/1080p up through 4K/5K/6K.
    public static func classify(
        sourceSize: PixelSize,
        activeBounds: PixelRect,
        cutoffFrequencyRatio: Double
    ) -> DetectedOpticalResolution {
        guard sourceSize.isValid, sourceSize.width >= 480, sourceSize.height >= 680 else {
            return .native
        }

        let clampedFreq = max(0.0, min(1.0, cutoffFrequencyRatio))
        let activeW = max(1, min(sourceSize.width, activeBounds.width > 0 ? activeBounds.width : sourceSize.width))
        let activeH = max(1, min(sourceSize.height, activeBounds.height > 0 ? activeBounds.height : sourceSize.height))

        let activeAspect = Double(activeW) / Double(activeH)
        let wide16x9 = 16.0 / 9.0
        let equiv16x9Height = activeAspect > wide16x9
            ? (clampedFreq * Double(activeW) * (9.0 / 16.0))
            : (clampedFreq * Double(activeH))
        let roundedEstHeight = max(1, Int(equiv16x9Height.rounded()))

        // High edge sharpness -> native Retina UI/text, native 1080p/3K/4K/5K/6K video, or nearest pixel art.
        if clampedFreq >= nativeCutoffThreshold {
            return DetectedOpticalResolution(
                tier: .native,
                preDownscaleSize: nil,
                estimatedActiveHeight: roundedEstHeight,
                cutoffFrequencyRatio: clampedFreq,
                isConfirmed: true
            )
        }

        // Snap into clean standard tiers with calibrated headroom so Lanczos3, Bicubic, and Bilinear
        // players all map accurately to their true underlying source tier without discarding real detail.
        let tier: OpticalResolutionTier
        if equiv16x9Height <= 580.0 {
            tier = .p480
        } else if equiv16x9Height <= 900.0 {
            tier = .p720
        } else if equiv16x9Height <= 1340.0 {
            tier = .p1080
        } else if equiv16x9Height <= 1680.0 {
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

        // Compute exact full-frame downscale ratio so the active video inside any letterbox/pillarbox
        // lands squarely on its native resolution (e.g. 4:3 480p in 3024x1964 -> 739x480 with 640x480 video;
        // 16:9 720p in 3024x1964 -> 1280x831 with 1280x720 video; 2.39:1 1080p -> 1920x1247 with 1920x804 video).
        let downscaleRatio: Double = activeAspect > wide16x9
            ? (Double(tierHeight) * wide16x9) / Double(activeW)
            : Double(tierHeight) / Double(activeH)

        guard downscaleRatio.isFinite && downscaleRatio > 0.05 && downscaleRatio <= maxUsefulDownscaleRatio else {
            return DetectedOpticalResolution(
                tier: .native,
                preDownscaleSize: nil,
                estimatedActiveHeight: roundedEstHeight,
                cutoffFrequencyRatio: clampedFreq,
                isConfirmed: true
            )
        }

        // Round to clean even dimensions (minimum 320x240) for optimal GPU/MetalFX/NV12 alignment.
        let rawOutW = Int((Double(sourceSize.width) * downscaleRatio).rounded())
        let rawOutH = Int((Double(sourceSize.height) * downscaleRatio).rounded())
        let evenW = min(sourceSize.width, max(320, (rawOutW + 1) & ~1))
        let evenH = min(sourceSize.height, max(240, (rawOutH + 1) & ~1))
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

// MARK: - Asymmetric Temporal Hysteresis Tracker

/// Stabilizes live GPU optical resolution detections across frames so:
/// - Startup & window resizes lock onto the true resolution immediately (within 1-2 probes, even on paused video).
/// - Switching to sharper content (e.g. exiting video to Retina webpage or 480p -> 1080p) upgrades fast (1 probe for Native).
/// - Brief blurry bokeh shots or dark fades in a 1080p/4K movie never cause false downgrades (requires 3 consecutive steady-state probes).
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

    /// Recommended interval in seconds before running the next GPU optical probe.
    /// Fast during startup/post-resize warm-up (0.25s), lightweight during steady state (1.0s).
    public var nextProbeIntervalSeconds: Double {
        probesCompletedForSize < 3 ? 0.25 : 1.0
    }

    /// Ingests one probe result (or `nil` if the frame was dark/flat/inconclusive).
    /// Returns the newly committed `DetectedOpticalResolution` iff the active verdict changed meaningfully.
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
            // If window shrunk below pre-downscale eligibility, reset immediately to confirmed native.
            if sourceSize.height < 680 || sourceSize.width < 480 {
                let changed = current.tier != .native || current.preDownscaleSize != nil || !current.isConfirmed
                current = .native
                return changed ? current : nil
            }
        }

        // Inconclusive frame (fade-to-black, solid screen): hold previous steady state without flickering.
        guard let candidate else {
            return nil
        }

        let isFirstProbeForSize = (probesCompletedForSize == 0)
        probesCompletedForSize += 1

        // 1. First probe after session start or window resize:
        //    Lock immediately when we have solid edge sample coverage (so even paused videos adapt within ~16ms!).
        if isFirstProbeForSize || !current.isConfirmed {
            if candidate.tier == .native || activeSliceCount >= 8 {
                let changed = !current.isConfirmed
                    || current.tier != candidate.tier
                    || current.preDownscaleSize != candidate.preDownscaleSize
                current = candidate
                pendingTier = nil
                pendingCount = 0
                return changed ? current : nil
            }
        }

        // 2. Same tier as current: refresh exact dimensions only if aspect/letterbox shifted significantly (> 8px).
        if candidate.tier == current.tier {
            pendingTier = nil
            pendingCount = 0
            if let newSize = candidate.preDownscaleSize, let oldSize = current.preDownscaleSize {
                if abs(newSize.width - oldSize.width) >= 12 || abs(newSize.height - oldSize.height) >= 12 {
                    current = candidate
                    return current
                }
            } else if candidate.preDownscaleSize != current.preDownscaleSize {
                current = candidate
                return current
            }
            return nil
        }

        // 3. Asymmetric hysteresis across tier transitions:
        let isUpgrade = candidate.tier.sharpnessRank > current.tier.sharpnessRank
        let requiredConfirmations: Int
        if isUpgrade {
            // Instant upgrade to crisp Native Retina (never blur text when exiting video to webpage/IDE!),
            // or fast 2-probe upgrade between video tiers (e.g. 480p -> 1080p).
            requiredConfirmations = (candidate.tier == .native && candidate.cutoffFrequencyRatio >= 0.84) ? 1 : 2
        } else {
            // Downgrade (e.g. Native -> 480p or 1080p -> 480p):
            // Fast during initial warm-up (2 probes = ~0.3s), conservative in steady state (3 probes = ~3.0s)
            // so brief bokeh/motion-blur shots in 1080p/4K movies never trigger false downgrades.
            requiredConfirmations = (probesCompletedForSize <= 3) ? 2 : 3
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
