import Foundation

/// Global hotkey actions supported by MetalPie.
public enum HotkeyAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case toggleFullscreen
    case toggleWindowed
    case toggleToolbar
    case captureScreenshot
    /// Reserved emergency stop shortcut (`⌃⌥⌘⎋`), always active and non-overridable.
    case panicStop

    public var id: String { rawValue }
}

/// Platform-neutral modifier key mask with Carbon `RegisterEventHotKey` flag conversion.
public struct HotkeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option  = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift   = HotkeyModifiers(rawValue: 1 << 3)

    /// Equivalent Carbon `cmdKey`/`optionKey`/`controlKey`/`shiftKey` bitmask for `RegisterEventHotKey`.
    public var carbonModifierFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= 1 << 8 }  // cmdKey (256)
        if contains(.shift)   { flags |= 1 << 9 }  // shiftKey (512)
        if contains(.option)  { flags |= 1 << 11 } // optionKey (2048)
        if contains(.control) { flags |= 1 << 12 } // controlKey (4096)
        return flags
    }

    /// Standard macOS symbol prefix order (`⌃⌥⇧⌘`).
    public var symbolString: String {
        var out = ""
        if contains(.control) { out.append("⌃") }
        if contains(.option)  { out.append("⌥") }
        if contains(.shift)   { out.append("⇧") }
        if contains(.command) { out.append("⌘") }
        return out
    }
}

/// Single global keyboard shortcut binding using macOS virtual key code + modifiers.
public struct HotkeyBinding: Hashable, Codable, Sendable {
    /// macOS Carbon virtual key code (e.g., `0` = A, `12` = Q, `2` = D, `1` = S, `53` = Escape).
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers
    public var displayString: String
    public var isEnabled: Bool

    public init(
        keyCode: UInt32,
        modifiers: HotkeyModifiers,
        displayString: String,
        isEnabled: Bool = true
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayString = displayString
        self.isEnabled = isEnabled
    }

    /// Reserved, unoverrideable emergency stop chord: `⌃⌥⌘⎋`.
    public static let panicStop = HotkeyBinding(
        keyCode: 53, // kVK_Escape
        modifiers: [.control, .option, .command],
        displayString: "⌃⌥⌘⎋",
        isEnabled: true
    )
}

/// User-configurable global hotkey set plus fixed emergency stop chord.
public struct HotkeyConfig: Hashable, Codable, Sendable {
    public var toggleFullscreen: HotkeyBinding
    public var toggleWindowed: HotkeyBinding
    public var toggleToolbar: HotkeyBinding
    public var captureScreenshot: HotkeyBinding

    /// Reserved emergency stop shortcut (`⌃⌥⌘⎋`), always active and cannot be overridden.
    public var panicStop: HotkeyBinding {
        .panicStop
    }

    public init(
        toggleFullscreen: HotkeyBinding = HotkeyBinding(
            keyCode: 0, // kVK_ANSI_A
            modifiers: [.option, .shift],
            displayString: "⌥⇧A"
        ),
        toggleWindowed: HotkeyBinding = HotkeyBinding(
            keyCode: 12, // kVK_ANSI_Q
            modifiers: [.option, .shift],
            displayString: "⌥⇧Q"
        ),
        toggleToolbar: HotkeyBinding = HotkeyBinding(
            keyCode: 2, // kVK_ANSI_D
            modifiers: [.option, .shift],
            displayString: "⌥⇧D"
        ),
        captureScreenshot: HotkeyBinding = HotkeyBinding(
            keyCode: 1, // kVK_ANSI_S
            modifiers: [.option, .shift],
            displayString: "⌥⇧S"
        )
    ) {
        self.toggleFullscreen = toggleFullscreen
        self.toggleWindowed = toggleWindowed
        self.toggleToolbar = toggleToolbar
        self.captureScreenshot = captureScreenshot
    }

    public func binding(for action: HotkeyAction) -> HotkeyBinding {
        switch action {
        case .toggleFullscreen: return toggleFullscreen
        case .toggleWindowed: return toggleWindowed
        case .toggleToolbar: return toggleToolbar
        case .captureScreenshot: return captureScreenshot
        case .panicStop: return panicStop
        }
    }
}

/// UI localization preference.
public enum AppLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case zhHans
    case en

    public var id: String { rawValue }
}

/// Versioned root application configuration persisted atomically to disk.
public struct AppConfig: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 2
    public static let defaultScreenshotFilenameTemplate = "MetalPie_%PN%_%Y%%M%%D%_%H%%m%%S%"

    /// macOS system processes and MetalPie itself that must never be auto-scaled.
    public static let defaultAutoScaleExcludedBundleIDs: [String] = [
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.finder",
        "com.apple.SystemUIServer",
        "com.apple.WindowManager",
        "com.apple.screencaptureui",
        "com.metalpie.app"
    ]

    public var schemaVersion: Int
    public var profiles: [Profile]
    public var scalingModes: [ScalingMode]
    public var hotkeys: HotkeyConfig
    public var countdownSeconds: Int
    public var language: AppLanguage
    public var screenshotDirectory: String
    public var screenshotFilenameTemplate: String
    public var launchAtLogin: Bool
    public var keepRunningInMenuBar: Bool
    public var autoScaleExcludedBundleIDs: [String]

    public init(
        schemaVersion: Int = AppConfig.currentSchemaVersion,
        profiles: [Profile] = [.defaultProfile],
        scalingModes: [ScalingMode] = ScalingMode.builtInPresets,
        hotkeys: HotkeyConfig = HotkeyConfig(),
        countdownSeconds: Int = 3,
        language: AppLanguage = .system,
        screenshotDirectory: String = AppConfig.defaultScreenshotDirectoryPath,
        screenshotFilenameTemplate: String = AppConfig.defaultScreenshotFilenameTemplate,
        launchAtLogin: Bool = false,
        keepRunningInMenuBar: Bool = true,
        autoScaleExcludedBundleIDs: [String] = AppConfig.defaultAutoScaleExcludedBundleIDs
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.scalingModes = scalingModes
        self.hotkeys = hotkeys
        self.countdownSeconds = min(max(countdownSeconds, 1), 10)
        self.language = language
        self.screenshotDirectory = screenshotDirectory
        self.screenshotFilenameTemplate = screenshotFilenameTemplate
        self.launchAtLogin = launchAtLogin
        self.keepRunningInMenuBar = keepRunningInMenuBar
        self.autoScaleExcludedBundleIDs = autoScaleExcludedBundleIDs
    }

    public static var defaultScreenshotDirectoryPath: String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("MetalPie").path
    }

    public static var defaultConfig: AppConfig {
        AppConfig()
    }

    public var defaultProfile: Profile {
        profiles.first(where: \.isDefault) ?? .defaultProfile
    }

    public func scalingMode(for id: UUID) -> ScalingMode? {
        scalingModes.first(where: { $0.id == id })
    }

    public func resolvedScalingMode(for profile: Profile) -> ScalingMode {
        scalingMode(for: profile.scalingModeID) ?? scalingModes.first ?? .defaultMode
    }

    public func matchingProfile(for window: WindowDescriptor) -> Profile {
        ProfileMatcher.match(window: window, profiles: profiles)
    }

    public func isExcludedFromAutoScale(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty
        else {
            return false
        }
        return autoScaleExcludedBundleIDs.contains {
            $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }
}
