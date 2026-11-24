import CoreGraphics
import Foundation

/// Classification of the process owning a discovered macOS window.
public enum WindowOwnerCategory: String, Codable, Sendable, CaseIterable {
    case application
    case system
    case metalPie
    case overlay
    case unknown
}

/// Pure metadata snapshot of a macOS window discovered via CoreGraphics / ScreenCaptureKit.
public struct WindowDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: CGWindowID { windowID }

    public var windowID: CGWindowID
    public var pid: Int32
    public var appName: String
    public var bundleIdentifier: String?
    public var appPath: String?
    public var title: String
    /// Window bounds in CoreGraphics global coordinates (Y-down, logical points).
    public var cgBounds: CGRect
    public var isOnScreen: Bool
    public var isMinimized: Bool
    public var backingScaleFactor: Double
    public var ownerCategory: WindowOwnerCategory

    public init(
        windowID: CGWindowID,
        pid: Int32,
        appName: String,
        bundleIdentifier: String? = nil,
        appPath: String? = nil,
        title: String = "",
        cgBounds: CGRect,
        isOnScreen: Bool = true,
        isMinimized: Bool = false,
        backingScaleFactor: Double = 2.0,
        ownerCategory: WindowOwnerCategory = .application
    ) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.title = title
        self.cgBounds = cgBounds.standardized
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.backingScaleFactor = max(1.0, backingScaleFactor)
        self.ownerCategory = ownerCategory
    }

    /// Human-readable label combining application name and window title.
    public var displayName: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty || trimmedTitle.caseInsensitiveCompare(appName) == .orderedSame {
            return appName
        }
        return "\(appName) — \(trimmedTitle)"
    }

    /// Backing pixel size estimated from `cgBounds * backingScaleFactor`.
    public var estimatedPixelSize: PixelSize {
        PixelSize(
            width: Int((cgBounds.width * backingScaleFactor).rounded()),
            height: Int((cgBounds.height * backingScaleFactor).rounded())
        )
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(pid)
        hasher.combine(appName)
        hasher.combine(bundleIdentifier)
        hasher.combine(appPath)
        hasher.combine(title)
        hasher.combine(cgBounds.origin.x)
        hasher.combine(cgBounds.origin.y)
        hasher.combine(cgBounds.size.width)
        hasher.combine(cgBounds.size.height)
        hasher.combine(isOnScreen)
        hasher.combine(isMinimized)
        hasher.combine(backingScaleFactor)
        hasher.combine(ownerCategory)
    }
}
