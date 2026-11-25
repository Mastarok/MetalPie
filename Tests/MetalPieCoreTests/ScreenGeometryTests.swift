import CoreGraphics
import Foundation
import Testing
@testable import MetalPieCore

@Suite("ScreenGeometry & Multi-Monitor Coordinates")
struct ScreenGeometryTests {
    // Exact host dual-monitor layout verified in SDK audit (#7):
    // Primary Built-in Retina Display: Cocoa (0, 0, 1512, 982) <-> CG (0, 0, 1512, 982)
    // External DELL P2422H above-right: Cocoa (1512, 982, 1280, 720) <-> CG (1512, -720, 1280, 720)
    private static let hostDisplays: [DisplayDescriptor] = [
        DisplayDescriptor(
            id: 1,
            name: "Built-in Retina Display",
            cocoaFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
            backingScaleFactor: 2.0,
            refreshRateHz: 120.0,
            maxEDRHeadroom: 16.0,
            isPrimary: true
        ),
        DisplayDescriptor(
            id: 2,
            name: "DELL P2422H",
            cocoaFrame: CGRect(x: 1512, y: 982, width: 1280, height: 720),
            cgBounds: CGRect(x: 1512, y: -720, width: 1280, height: 720),
            backingScaleFactor: 2.0,
            refreshRateHz: 60.0,
            maxEDRHeadroom: 1.0,
            isPrimary: false
        )
    ]

    // Negative-origin multi-monitor setup:
    // Left monitor: Cocoa (-1920, -200, 1920, 1080) <-> CG (-1920, 102, 1920, 1080)
    // Primary:      Cocoa (0, 0, 1512, 982)         <-> CG (0, 0, 1512, 982)
    // Bottom:       Cocoa (0, -1080, 1920, 1080)    <-> CG (0, 982, 1920, 1080)
    private static let negativeOriginDisplays: [DisplayDescriptor] = [
        DisplayDescriptor(
            id: 10,
            name: "Left External",
            cocoaFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
            cgBounds: CGRect(x: -1920, y: 102, width: 1920, height: 1080),
            backingScaleFactor: 1.0,
            refreshRateHz: 144.0,
            isPrimary: false
        ),
        DisplayDescriptor(
            id: 11,
            name: "Primary Retina",
            cocoaFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
            backingScaleFactor: 2.0,
            refreshRateHz: 120.0,
            isPrimary: true
        ),
        DisplayDescriptor(
            id: 12,
            name: "Bottom External",
            cocoaFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            cgBounds: CGRect(x: 0, y: 982, width: 1920, height: 1080),
            backingScaleFactor: 2.0,
            refreshRateHz: 60.0,
            isPrimary: false
        )
    ]

    @Test("Dual-monitor Retina + DELL P2422H CG <-> AppKit rect conversion")
    func dualMonitorHostLayoutRectConversion() {
        let displays = Self.hostDisplays
        #expect(ScreenGeometry.primaryDisplay(in: displays)?.id == 1)
        #expect(ScreenGeometry.primaryHeight(in: displays) == 982)

        // Primary display maps identically onto itself
        let primaryCG = ScreenGeometry.cocoaToCG(rect: displays[0].cocoaFrame, displays: displays)
        #expect(primaryCG == CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(ScreenGeometry.cgToCocoa(rect: primaryCG, displays: displays) == displays[0].cocoaFrame)

        // External DELL P2422H above-right of primary: Cocoa y=982, h=720 -> CG y = 982 - (982 + 720) = -720
        let dellCG = ScreenGeometry.cocoaToCG(rect: displays[1].cocoaFrame, displays: displays)
        #expect(dellCG == CGRect(x: 1512, y: -720, width: 1280, height: 720))

        let dellCocoaRoundTrip = ScreenGeometry.cgToCocoa(rect: dellCG, displays: displays)
        #expect(dellCocoaRoundTrip == displays[1].cocoaFrame)

        // A 800x600 window centered on DELL P2422H:
        // In CG: x = 1512 + 240 = 1752, y = -720 + 60 = -660
        let winCG = CGRect(x: 1752, y: -660, width: 800, height: 600)
        // In Cocoa: y = 982 - (-660 + 600) = 982 + 60 = 1042
        let winCocoa = ScreenGeometry.cgToCocoa(rect: winCG, displays: displays)
        #expect(winCocoa == CGRect(x: 1752, y: 1042, width: 800, height: 600))
        #expect(ScreenGeometry.cocoaToCG(rect: winCocoa, displays: displays) == winCG)
    }

    @Test("Negative-origin secondary monitors (left and below primary) CG <-> AppKit conversion")
    func negativeOriginMonitorsConversion() {
        let displays = Self.negativeOriginDisplays
        #expect(ScreenGeometry.primaryDisplay(in: displays)?.id == 11)

        // Left monitor: Cocoa (-1920, -200, 1920, 1080) -> CG y = 982 - (-200 + 1080) = 102
        let leftCG = ScreenGeometry.cocoaToCG(rect: displays[0].cocoaFrame, displays: displays)
        #expect(leftCG == CGRect(x: -1920, y: 102, width: 1920, height: 1080))
        #expect(ScreenGeometry.cgToCocoa(rect: leftCG, displays: displays) == displays[0].cocoaFrame)

        // Bottom monitor: Cocoa (0, -1080, 1920, 1080) -> CG y = 982 - (-1080 + 1080) = 982
        let bottomCG = ScreenGeometry.cocoaToCG(rect: displays[2].cocoaFrame, displays: displays)
        #expect(bottomCG == CGRect(x: 0, y: 982, width: 1920, height: 1080))
        #expect(ScreenGeometry.cgToCocoa(rect: bottomCG, displays: displays) == displays[2].cocoaFrame)

        // Window on left monitor with negative X and spanning below primary bottom
        let leftWinCG = CGRect(x: -1500, y: 500, width: 640, height: 480)
        let leftWinCocoa = ScreenGeometry.cgToCocoa(rect: leftWinCG, displays: displays)
        // y_cocoa = 982 - (500 + 480) = 2
        #expect(leftWinCocoa == CGRect(x: -1500, y: 2, width: 640, height: 480))
        #expect(ScreenGeometry.cocoaToCG(rect: leftWinCocoa, displays: displays) == leftWinCG)
    }

    @Test("Point CG <-> AppKit Y-flip conversion")
    func pointConversion() {
        let displays = Self.hostDisplays

        // Primary top-left in CG (0, 0) -> Cocoa (0, 982)
        #expect(ScreenGeometry.cgToCocoa(point: CGPoint(x: 0, y: 0), displays: displays) == CGPoint(x: 0, y: 982))
        // Primary bottom-left in CG (0, 982) -> Cocoa (0, 0)
        #expect(ScreenGeometry.cgToCocoa(point: CGPoint(x: 0, y: 982), displays: displays) == CGPoint(x: 0, y: 0))
        // Top-left of DELL P2422H in CG (1512, -720) -> Cocoa (1512, 1702)
        let dellTopLeftCocoa = ScreenGeometry.cgToCocoa(point: CGPoint(x: 1512, y: -720), displays: displays)
        #expect(dellTopLeftCocoa == CGPoint(x: 1512, y: 1702))
        #expect(ScreenGeometry.cocoaToCG(point: dellTopLeftCocoa, displays: displays) == CGPoint(x: 1512, y: -720))
    }

    @Test("Best display lookup and MultiMonitorMode targeting")
    func displayLookupAndMultiMonitorModes() {
        let displays = Self.negativeOriginDisplays

        // Window mostly on Left monitor, slightly crossing into Primary
        let straddlingCG = CGRect(x: -400, y: 200, width: 500, height: 400)
        #expect(ScreenGeometry.bestDisplay(forCGRect: straddlingCG, in: displays)?.id == 10)

        let closestTargets = ScreenGeometry.targetDisplays(forCGRect: straddlingCG, mode: .closest, in: displays)
        #expect(closestTargets.map(\.id) == [10])

        let intersectedTargets = ScreenGeometry.targetDisplays(forCGRect: straddlingCG, mode: .intersected, in: displays)
        #expect(intersectedTargets.map(\.id) == [10, 11])

        let allTargets = ScreenGeometry.targetDisplays(forCGRect: straddlingCG, mode: .all, in: displays)
        #expect(allTargets.map(\.id) == [10, 11, 12])

        // Combined Cocoa union for `.all`
        let allCocoa = ScreenGeometry.targetCocoaFrame(forCGRect: straddlingCG, mode: .all, in: displays)
        #expect(allCocoa == CGRect(x: -1920, y: -1080, width: 3840, height: 2062))

        // Completely off-screen window far below bottom monitor picks Bottom External (id 12)
        let offscreenCG = CGRect(x: 200, y: 3000, width: 400, height: 300)
        #expect(ScreenGeometry.bestDisplay(forCGRect: offscreenCG, in: displays)?.id == 12)
    }

    @Test("Anti-occlusion 1-point inset helper")
    func antiOcclusionInset() {
        let cocoaRect = CGRect(x: 100, y: 200, width: 1280, height: 720)
        let insetCocoa = ScreenGeometry.antiOcclusionInset(cocoaRect: cocoaRect)
        #expect(insetCocoa == CGRect(x: 100, y: 201, width: 1280, height: 719))

        let cgRect = CGRect(x: 100, y: 200, width: 1280, height: 720)
        let insetCG = ScreenGeometry.antiOcclusionInset(cgRect: cgRect)
        #expect(insetCG == CGRect(x: 100, y: 200, width: 1280, height: 719))

        // Tiny rect should not collapse to negative or zero height
        let tiny = CGRect(x: 0, y: 0, width: 10, height: 2)
        #expect(ScreenGeometry.antiOcclusionInset(cocoaRect: tiny) == tiny)
    }

    @Test("DisplayDescriptor notch-safe fullscreen geometry excludes camera notch on notched MacBooks and preserves full edge-to-edge on non-notched monitors")
    func notchSafeDisplayGeometry() throws {
        let notchedMacBook = DisplayDescriptor(
            id: 1,
            name: "Built-in Retina Display",
            cocoaFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
            backingScaleFactor: 2.0,
            refreshRateHz: 120.0,
            maxEDRHeadroom: 16.0,
            isPrimary: true,
            safeAreaTopInset: 33.0
        )
        let externalDELL = DisplayDescriptor(
            id: 3,
            name: "DELL P2422H",
            cocoaFrame: CGRect(x: 1512, y: 982, width: 1280, height: 720),
            cgBounds: CGRect(x: 1512, y: -720, width: 1280, height: 720),
            backingScaleFactor: 2.0,
            refreshRateHz: 60.0,
            maxEDRHeadroom: 1.0,
            isPrimary: false,
            safeAreaTopInset: 0.0
        )
        let displays = [notchedMacBook, externalDELL]

        #expect(notchedMacBook.hasNotch == true)
        #expect(notchedMacBook.notchSafeCocoaFrame == CGRect(x: 0, y: 0, width: 1512, height: 949))
        #expect(notchedMacBook.notchSafeCGBounds == CGRect(x: 0, y: 33, width: 1512, height: 949))

        #expect(externalDELL.hasNotch == false)
        #expect(externalDELL.notchSafeCocoaFrame == externalDELL.cocoaFrame)
        #expect(externalDELL.notchSafeCGBounds == externalDELL.cgBounds)

        // Single notched display -> exact below-notch 1512x949 (maxY == 949, zero notch overlap)
        let macSafe = ScreenGeometry.targetFullscreenSafeCocoaFrame(
            forCGRect: CGRect(x: 100, y: 120, width: 900, height: 600),
            mode: .closest,
            in: displays
        )
        #expect(macSafe == CGRect(x: 0, y: 0, width: 1512, height: 949))

        // External non-notched display -> full 1280x720 edge-to-edge
        let dellSafe = ScreenGeometry.targetFullscreenSafeCocoaFrame(
            forCGRect: CGRect(x: 1620, y: -600, width: 800, height: 500),
            mode: .closest,
            in: displays
        )
        #expect(dellSafe == externalDELL.cocoaFrame)

        // Multi-display `.all` span -> preserves full union
        let allSpan = ScreenGeometry.targetFullscreenSafeCocoaFrame(
            forCGRect: CGRect(x: 100, y: 120, width: 900, height: 600),
            mode: .all,
            in: displays
        )
        #expect(allSpan == notchedMacBook.cocoaFrame.union(externalDELL.cocoaFrame))

        // Backwards-compatible Codable decode without `safeAreaTopInset` defaults to 0.0
        let encoded = try JSONEncoder().encode(notchedMacBook)
        var obj = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        obj.removeValue(forKey: "safeAreaTopInset")
        let legacyData = try JSONSerialization.data(withJSONObject: obj)
        let decodedLegacy = try JSONDecoder().decode(DisplayDescriptor.self, from: legacyData)
        #expect(decodedLegacy.safeAreaTopInset == 0.0)
        #expect(decodedLegacy.hasNotch == false)
    }
}
