import Foundation

/// ScreenCaptureKit capture targeting mode.
public enum CaptureMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case window
    case display

    public var id: String { rawValue }
}

/// Preferred pixel format requested from ScreenCaptureKit.
public enum CapturePixelFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case bgra8
    case rgb10a2
    case rgba16f
    case nv12

    public var id: String { rawValue }
}

/// SDR vs HDR/EDR dynamic range capture & presentation target.
public enum DynamicRangeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case sdr
    case hdr

    public var id: String { rawValue }
}

/// GPU duplicate-frame detection policy (inspired by Magpie).
public enum DuplicateFrameMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Dynamically adapts check cadence when consecutive frames differ.
    case dynamic
    /// Always checks every incoming frame and skips shader work if unchanged.
    case always
    /// Disables duplicate-frame checking (forced in 3D Game Mode).
    case never

    public var id: String { rawValue }
}

/// Input resolution policy for fullscreen video / browser super-resolution pre-downscaling.
public enum FullscreenVideoInputMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case p480
    case p720
    case p1080
    case native

    public var id: String { rawValue }
}

/// Per-profile capture pipeline configuration.
public struct CaptureSettings: Hashable, Codable, Sendable {
    public var captureMode: CaptureMode
    public var captureTitleBar: Bool
    public var ignoreShadows: Bool
    public var preferredPixelFormat: CapturePixelFormat
    public var dynamicRange: DynamicRangeMode
    /// Optional FPS cap (`10...1000`); `nil` means uncapped / display native refresh rate.
    public var frameRateLimit: Int?
    public var duplicateFrameMode: DuplicateFrameMode
    /// Prefer paced immediate presentation over `CAMetalDisplayLink` VSync cadence when Frame Gen is off.
    /// Defaults to `false` so `CAMetalDisplayLink` (`preferredFrameLatency = 1.0`) provides smooth VSync
    /// pacing with zero drawable-pool exhaustion during high-frequency UI/video-scrubber animations.
    public var lowLatencyPresent: Bool
    /// Input resolution policy for fullscreen video / browser super-resolution pre-downscaling.
    public var fullscreenVideoInput: FullscreenVideoInputMode

    public init(
        captureMode: CaptureMode = .window,
        captureTitleBar: Bool = false,
        ignoreShadows: Bool = true,
        preferredPixelFormat: CapturePixelFormat = .bgra8,
        dynamicRange: DynamicRangeMode = .sdr,
        frameRateLimit: Int? = nil,
        duplicateFrameMode: DuplicateFrameMode = .dynamic,
        lowLatencyPresent: Bool = false,
        fullscreenVideoInput: FullscreenVideoInputMode = .auto
    ) {
        self.captureMode = captureMode
        self.captureTitleBar = captureTitleBar
        self.ignoreShadows = ignoreShadows
        self.preferredPixelFormat = preferredPixelFormat
        self.dynamicRange = dynamicRange
        if let limit = frameRateLimit {
            self.frameRateLimit = min(max(limit, 10), 1000)
        } else {
            self.frameRateLimit = nil
        }
        self.duplicateFrameMode = duplicateFrameMode
        self.lowLatencyPresent = lowLatencyPresent
        self.fullscreenVideoInput = fullscreenVideoInput
    }

    private enum CodingKeys: String, CodingKey {
        case captureMode
        case captureTitleBar
        case ignoreShadows
        case preferredPixelFormat
        case dynamicRange
        case frameRateLimit
        case duplicateFrameMode
        case lowLatencyPresent
        case fullscreenVideoInput
    }

    /// Backwards-compatible Codable decoding so saved configs lacking `fullscreenVideoInput` load cleanly as `.auto`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.captureMode = try c.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .window
        self.captureTitleBar = try c.decodeIfPresent(Bool.self, forKey: .captureTitleBar) ?? false
        self.ignoreShadows = try c.decodeIfPresent(Bool.self, forKey: .ignoreShadows) ?? true
        self.preferredPixelFormat = try c.decodeIfPresent(CapturePixelFormat.self, forKey: .preferredPixelFormat) ?? .bgra8
        self.dynamicRange = try c.decodeIfPresent(DynamicRangeMode.self, forKey: .dynamicRange) ?? .sdr
        if let limit = try c.decodeIfPresent(Int.self, forKey: .frameRateLimit) {
            self.frameRateLimit = min(max(limit, 10), 1000)
        } else {
            self.frameRateLimit = nil
        }
        self.duplicateFrameMode = try c.decodeIfPresent(DuplicateFrameMode.self, forKey: .duplicateFrameMode) ?? .dynamic
        self.lowLatencyPresent = try c.decodeIfPresent(Bool.self, forKey: .lowLatencyPresent) ?? false
        self.fullscreenVideoInput = try c.decodeIfPresent(FullscreenVideoInputMode.self, forKey: .fullscreenVideoInput) ?? .auto
    }
}

/// How the rendered scaled cursor size is computed.
public enum CursorScaleMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Match the source window's scaling ratio automatically.
    case source
    /// Multiply native cursor size by `cursorScaleMultiplier`.
    case multiplier
    /// Always render at 1x native display size regardless of window scale.
    case fixed

    public var id: String { rawValue }
}

/// Resampling filter used when rendering the scaled cursor sprite.
public enum CursorInterpolation: String, Codable, Sendable, CaseIterable, Identifiable {
    case nearest
    case bilinear

    public var id: String { rawValue }
}

/// Per-profile cursor alignment, confinement, and visual rendering settings.
public struct CursorSettings: Hashable, Codable, Sendable {
    public var renderScaledCursor: Bool
    public var cursorScaleMode: CursorScaleMode
    public var cursorScaleMultiplier: Double
    public var interpolation: CursorInterpolation
    public var confineCursor: Bool
    public var adjustCursorSpeed: Bool
    /// Seconds of inactivity before hiding cursor sprite; `nil` disables idle auto-hide.
    public var hideOnIdleSeconds: Double?
    public var hideInScreenshots: Bool
    public var respectGameMouseGrab: Bool

    public init(
        renderScaledCursor: Bool = true,
        cursorScaleMode: CursorScaleMode = .source,
        cursorScaleMultiplier: Double = 1.0,
        interpolation: CursorInterpolation = .bilinear,
        confineCursor: Bool = true,
        adjustCursorSpeed: Bool = true,
        hideOnIdleSeconds: Double? = 3.0,
        hideInScreenshots: Bool = true,
        respectGameMouseGrab: Bool = true
    ) {
        self.renderScaledCursor = renderScaledCursor
        self.cursorScaleMode = cursorScaleMode
        self.cursorScaleMultiplier = min(max(cursorScaleMultiplier, 0.25), 8.0)
        self.interpolation = interpolation
        self.confineCursor = confineCursor
        self.adjustCursorSpeed = adjustCursorSpeed
        if let idle = hideOnIdleSeconds {
            self.hideOnIdleSeconds = max(0.1, idle)
        } else {
            self.hideOnIdleSeconds = nil
        }
        self.hideInScreenshots = hideInScreenshots
        self.respectGameMouseGrab = respectGameMouseGrab
    }
}

/// Frame generation output frame rate multiplier.
public enum FrameGenMultiplier: Int, Codable, Sendable, CaseIterable, Identifiable {
    case x2 = 2
    case x3 = 3
    case x4 = 4

    public var id: Int { rawValue }

    public var label: String { "\(rawValue)x" }
}

/// Frame generation compute backend selection.
public enum FrameGenBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Prefer VideoToolbox ML (`VTLowLatencyFrameInterpolationConfiguration`) on macOS 26+, falling back to Metal optical flow.
    case auto
    case videoToolboxML
    case metalOpticalFlow

    public var id: String { rawValue }
}

/// Controls how aggressively frame interpolation suppresses artifacts on scene cuts / fast UI motion.
public enum ArtifactGuardSensitivity: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case balanced
    case strong

    public var id: String { rawValue }
}

/// Per-profile frame generation settings.
public struct FrameGenSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var multiplier: FrameGenMultiplier
    public var backend: FrameGenBackend
    public var artifactGuardSensitivity: ArtifactGuardSensitivity
    public var disableIn3DGameMode: Bool

    public init(
        enabled: Bool = false,
        multiplier: FrameGenMultiplier = .x2,
        backend: FrameGenBackend = .auto,
        artifactGuardSensitivity: ArtifactGuardSensitivity = .balanced,
        disableIn3DGameMode: Bool = true
    ) {
        self.enabled = enabled
        self.multiplier = multiplier
        self.backend = backend
        self.artifactGuardSensitivity = artifactGuardSensitivity
        self.disableIn3DGameMode = disableIn3DGameMode
    }
}

/// Auto-scale trigger behavior when a matching application window gains focus.
public enum AutoScaleMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case disabled
    case fullscreen
    case windowed

    public var id: String { rawValue }
}

/// Visibility mode for the floating top-center overlay toolbar.
public enum ToolbarMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case autoHide
    case alwaysShow

    public var id: String { rawValue }
}

/// Default or per-application/window scaling profile.
public struct Profile: Identifiable, Hashable, Codable, Sendable {
    public static let defaultProfileID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!

    public var id: UUID
    public var name: String
    public var isDefault: Bool
    public var bundleIdentifier: String?
    public var appPath: String?
    public var windowTitlePattern: String?
    public var scalingModeID: UUID
    public var presentationMode: PresentationMode
    public var outputAlignment: OutputAlignment
    public var multiMonitorMode: MultiMonitorMode
    public var crop: CropInsets
    public var capture: CaptureSettings
    public var cursor: CursorSettings
    public var frameGen: FrameGenSettings
    public var autoScaleMode: AutoScaleMode
    public var autoScaleDelaySeconds: Double
    public var threeDGameMode: Bool
    public var toolbarMode: ToolbarMode
    public var showProfilerHUD: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        isDefault: Bool = false,
        bundleIdentifier: String? = nil,
        appPath: String? = nil,
        windowTitlePattern: String? = nil,
        scalingModeID: UUID = ScalingMode.metalFXSpatialID,
        presentationMode: PresentationMode = .fullscreen,
        outputAlignment: OutputAlignment = .center,
        multiMonitorMode: MultiMonitorMode = .closest,
        crop: CropInsets = .zero,
        capture: CaptureSettings = CaptureSettings(),
        cursor: CursorSettings = CursorSettings(),
        frameGen: FrameGenSettings = FrameGenSettings(),
        autoScaleMode: AutoScaleMode = .disabled,
        autoScaleDelaySeconds: Double = 0.5,
        threeDGameMode: Bool = false,
        toolbarMode: ToolbarMode = .autoHide,
        showProfilerHUD: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.windowTitlePattern = windowTitlePattern
        self.scalingModeID = scalingModeID
        self.presentationMode = presentationMode
        self.outputAlignment = outputAlignment
        self.multiMonitorMode = multiMonitorMode
        self.crop = crop
        self.capture = capture
        self.cursor = cursor
        self.frameGen = frameGen
        self.autoScaleMode = autoScaleMode
        self.autoScaleDelaySeconds = max(0.0, autoScaleDelaySeconds)
        self.threeDGameMode = threeDGameMode
        self.toolbarMode = toolbarMode
        self.showProfilerHUD = showProfilerHUD
    }

    public static let defaultProfile = Profile(
        id: defaultProfileID,
        name: "Default",
        isDefault: true,
        scalingModeID: ScalingMode.metalFXSpatialID
    )
}

/// Deterministic profile matcher resolving the best `Profile` for a target window.
public enum ProfileMatcher: Sendable {
    /// Selects the most specific matching non-default profile (bundleID/appPath + optional title regex),
    /// falling back to the default profile if none match.
    public static func match(window: WindowDescriptor, profiles: [Profile]) -> Profile {
        let nonDefault = profiles.filter { !$0.isDefault }

        var bestMatch: (profile: Profile, specificity: Int)? = nil

        for profile in nonDefault {
            guard let specificity = matchSpecificity(profile: profile, window: window) else {
                continue
            }
            if let currentBest = bestMatch {
                if specificity > currentBest.specificity {
                    bestMatch = (profile, specificity)
                }
            } else {
                bestMatch = (profile, specificity)
            }
        }

        if let bestMatch {
            return bestMatch.profile
        }
        return profiles.first(where: \.isDefault) ?? .defaultProfile
    }

    /// Returns nil if `profile` does not match `window`, or a positive specificity score
    /// (bundleID+title = 4, appPath+title = 3, bundleID = 2, appPath = 2, titleOnly = 1).
    public static func matchSpecificity(profile: Profile, window: WindowDescriptor) -> Int? {
        let hasBundleRule = !(profile.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasPathRule = !(profile.appPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasTitleRule = !(profile.windowTitlePattern?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        guard hasBundleRule || hasPathRule || hasTitleRule else {
            return nil
        }

        var score = 0

        if hasBundleRule {
            guard let ruleBundle = profile.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let winBundle = window.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  winBundle.caseInsensitiveCompare(ruleBundle) == .orderedSame
            else {
                return nil
            }
            score += 2
        }

        if hasPathRule {
            guard let rulePath = profile.appPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let winPath = window.appPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  winPath.caseInsensitiveCompare(rulePath) == .orderedSame
            else {
                return nil
            }
            score += hasBundleRule ? 1 : 2
        }

        if hasTitleRule {
            guard let pattern = profile.windowTitlePattern?.trimmingCharacters(in: .whitespacesAndNewlines),
                  matchesTitle(window.title, pattern: pattern)
            else {
                return nil
            }
            score += hasBundleRule || hasPathRule ? 2 : 1
        }

        return score > 0 ? score : nil
    }

    /// Evaluates `pattern` as a case-insensitive regular expression against `title`,
    /// safely falling back to case-insensitive substring matching if the regex is invalid.
    public static func matchesTitle(_ title: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            return regex.firstMatch(in: title, options: [], range: range) != nil
        }
        return title.localizedCaseInsensitiveContains(pattern)
    }
}
