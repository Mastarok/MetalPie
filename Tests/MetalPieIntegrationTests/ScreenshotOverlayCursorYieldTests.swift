import CoreGraphics
import Foundation
import Testing
@testable import MetalPieCapture
@testable import MetalPieCore

@Suite("Third-Party Screenshot Overlay Detection")
struct ScreenshotOverlayCursorYieldTests {
    private let macBookDisplay = DisplayDescriptor(
        id: 1,
        name: "Built-in Liquid Retina XDR",
        cocoaFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        backingScaleFactor: 2.0,
        refreshRateHz: 120.0,
        maxEDRHeadroom: 16.0,
        isPrimary: true,
        safeAreaTopInset: 33.0
    )

    private let externalDisplay = DisplayDescriptor(
        id: 2,
        name: "DELL P2422H",
        cocoaFrame: CGRect(x: 1512, y: 982, width: 1280, height: 720),
        cgBounds: CGRect(x: 1512, y: -720, width: 1280, height: 720),
        backingScaleFactor: 2.0,
        refreshRateHz: 60.0,
        maxEDRHeadroom: 1.0,
        isPrimary: false,
        safeAreaTopInset: 0.0
    )

    @Test("Detects third-party screenshot tools (Snipaste, PixPin, iShot, CleanShot X) and macOS screencaptureui")
    func detectsThirdPartyAndSystemScreenshotOverlays() {
        let displays = [macBookDisplay, externalDisplay]
        let overlayRect = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let screenSaverLayer = Int(CGWindowLevelForKey(.screenSaverWindow))

        // 1. Snipaste fullscreen capture overlay on primary display
        let snipaste = ForeignOverlayWindowSnapshot(
            windowID: 5001,
            pid: 9001,
            ownerName: "Snipaste",
            layer: screenSaverLayer,
            bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
        let detected1 = OverlayWindowController.detectForeignCaptureOverlayAbove(
            windowsAboveOverlay: [snipaste],
            ownPID: 100,
            targetPID: 200,
            targetWindowID: 300,
            ignoredWindowIDs: [101, 102],
            overlayCGRect: overlayRect,
            displays: displays
        )
        #expect(detected1?.windowID == 5001)

        // 2. PixPin capture overlay on secondary external monitor (CGDisplayHideCursor is global!)
        let pixpinSecondary = ForeignOverlayWindowSnapshot(
            windowID: 5002,
            pid: 9002,
            ownerName: "PixPin",
            layer: screenSaverLayer,
            bounds: CGRect(x: 1512, y: -720, width: 1280, height: 720)
        )
        let detected2 = OverlayWindowController.detectForeignCaptureOverlayAbove(
            windowsAboveOverlay: [pixpinSecondary],
            ownPID: 100,
            targetPID: 200,
            targetWindowID: 300,
            ignoredWindowIDs: [101, 102],
            overlayCGRect: overlayRect,
            displays: displays
        )
        #expect(detected2?.windowID == 5002)

        // 3. macOS built-in screencaptureui (even a compact Shift+Cmd+5 HUD bar)
        let macOSScreenshot = ForeignOverlayWindowSnapshot(
            windowID: 5003,
            pid: 9003,
            ownerName: "screencaptureui",
            layer: screenSaverLayer,
            bounds: CGRect(x: 450, y: 860, width: 612, height: 64)
        )
        let detected3 = OverlayWindowController.detectForeignCaptureOverlayAbove(
            windowsAboveOverlay: [macOSScreenshot],
            ownPID: 100,
            targetPID: 200,
            targetWindowID: 300,
            ignoredWindowIDs: [101, 102],
            overlayCGRect: overlayRect,
            displays: displays
        )
        #expect(detected3?.windowID == 5003)

        // 4. Target app's own built-in screenshot overlay (e.g. scaling QQ/WeChat and pressing Ctrl+Cmd+A)
        let qqOwnScreenshot = ForeignOverlayWindowSnapshot(
            windowID: 5004,
            pid: 200,
            ownerName: "QQ",
            layer: screenSaverLayer,
            bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
        let detected4 = OverlayWindowController.detectForeignCaptureOverlayAbove(
            windowsAboveOverlay: [qqOwnScreenshot],
            ownPID: 100,
            targetPID: 200,
            targetWindowID: 300,
            ignoredWindowIDs: [101, 102],
            overlayCGRect: overlayRect,
            displays: displays
        )
        #expect(detected4?.windowID == 5004)
    }

    @Test("Ignores MetalPie chrome, macOS shell strips, IMEs, context menus, and small pinned windows")
    func ignoresShellChromeMenusAndSmallPinnedOverlays() {
        let displays = [macBookDisplay, externalDisplay]
        let overlayRect = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let popUpLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let screenSaverLayer = Int(CGWindowLevelForKey(.screenSaverWindow))

        let benignWindows: [ForeignOverlayWindowSnapshot] = [
            // MetalPie's own cursor overlay panel
            ForeignOverlayWindowSnapshot(
                windowID: 101, pid: 100, ownerName: "MetalPie",
                layer: 99, bounds: CGRect(x: 0, y: 33, width: 1512, height: 949)
            ),
            // Window Server orange screen-recording dot & MenuBar
            ForeignOverlayWindowSnapshot(
                windowID: 8313, pid: 410, ownerName: "Window Server",
                layer: 2147483630, bounds: CGRect(x: 1486, y: 1, width: 28, height: 28)
            ),
            ForeignOverlayWindowSnapshot(
                windowID: 8542, pid: 410, ownerName: "Window Server",
                layer: 24, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33)
            ),
            // Target app's normal right-click NSMenu
            ForeignOverlayWindowSnapshot(
                windowID: 7001, pid: 200, ownerName: "IINA",
                layer: popUpLayer, bounds: CGRect(x: 500, y: 400, width: 240, height: 310)
            ),
            // Small pinned reference image (Snipaste F3)
            ForeignOverlayWindowSnapshot(
                windowID: 7002, pid: 9001, ownerName: "Snipaste",
                layer: 25, bounds: CGRect(x: 1120, y: 80, width: 320, height: 220)
            ),
            // Notch utility bar sitting at high layer
            ForeignOverlayWindowSnapshot(
                windowID: 7003, pid: 9005, ownerName: "NotchUtility",
                layer: screenSaverLayer, bounds: CGRect(x: 556, y: 0, width: 400, height: 38)
            ),
            // IME candidate bar
            ForeignOverlayWindowSnapshot(
                windowID: 7004, pid: 9006, ownerName: "SCIM",
                layer: popUpLayer, bounds: CGRect(x: 620, y: 520, width: 280, height: 42)
            ),
            // Notification Center banner
            ForeignOverlayWindowSnapshot(
                windowID: 7005, pid: 420, ownerName: "Notification Center",
                layer: 25, bounds: CGRect(x: 1140, y: 44, width: 350, height: 90)
            )
        ]

        let detected = OverlayWindowController.detectForeignCaptureOverlayAbove(
            windowsAboveOverlay: benignWindows,
            ownPID: 100,
            targetPID: 200,
            targetWindowID: 300,
            ignoredWindowIDs: [101, 102],
            overlayCGRect: overlayRect,
            displays: displays
        )
        #expect(detected == nil)
    }
}
