import CoreGraphics
import Foundation
import Testing
import os

@testable import MetalPieCore
@testable import MetalPieCapture
@testable import MetalPieInput

// MARK: - Deterministic Mock WindowTracking for AutoScale Integration Tests

private final class MockWindowTracker: WindowTracking, @unchecked Sendable {
    private struct State: Sendable {
        var windows: [WindowDescriptor] = []
        var frontmost: WindowDescriptor?
        var trackedID: CGWindowID?
        var onEvent: (@Sendable (WindowLifecycleEvent) -> Void)?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func setFrontmost(_ window: WindowDescriptor?) {
        lock.withLock { $0.frontmost = window }
    }

    func emitEvent(_ event: WindowLifecycleEvent) {
        let cb = lock.withLock(\.onEvent)
        cb?(event)
    }

    func listCapturableWindows() -> [WindowDescriptor] {
        lock.withLock(\.windows)
    }

    func activeFrontmostWindow() -> WindowDescriptor? {
        lock.withLock(\.frontmost)
    }

    func startObserving(
        trackedWindowID: CGWindowID?,
        onEvent: @escaping @Sendable (WindowLifecycleEvent) -> Void
    ) {
        lock.withLock { s in
            s.trackedID = trackedWindowID
            s.onEvent = onEvent
        }
    }

    func updateTrackedWindow(_ windowID: CGWindowID?) {
        lock.withLock { $0.trackedID = windowID }
    }

    func stopObserving() {
        lock.withLock { s in
            s.trackedID = nil
            s.onEvent = nil
        }
    }
}

// MARK: - PointerMapping, Input, AutoScale, Window Lifecycle, Hotkeys & Watchdog Suite

@Suite("PointerMapping & Input Subsystem Integration", .serialized)
struct InputAndPointerIntegrationTests {

    private static let macBookPrimary = DisplayDescriptor(
        id: 1,
        name: "Built-in Retina Display",
        cocoaFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        backingScaleFactor: 2.0,
        refreshRateHz: 120.0,
        maxEDRHeadroom: 16.0,
        isPrimary: true
    )

    private static let leftNegativeDisplay = DisplayDescriptor(
        id: 2,
        name: "Left External 4K",
        cocoaFrame: CGRect(x: -1920, y: -98, width: 1920, height: 1080),
        cgBounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        backingScaleFactor: 2.0,
        refreshRateHz: 60.0,
        maxEDRHeadroom: 1.0,
        isPrimary: false
    )

    private static let rightPositiveDisplay = DisplayDescriptor(
        id: 3,
        name: "Right External 1440p",
        cocoaFrame: CGRect(x: 1512, y: 262, width: 1280, height: 720),
        cgBounds: CGRect(x: 1512, y: 0, width: 1280, height: 720),
        backingScaleFactor: 2.0,
        refreshRateHz: 60.0,
        maxEDRHeadroom: 1.0,
        isPrimary: false
    )

    @Test("PointerMapping fencepost (N-1) accuracy across Fit, Fill, Stretch, IntegerFit, Crop, 9 alignments, Windowed, and Dual-Monitor offsets")
    func pointerMappingAcrossAllLayoutsAndMultiMonitor() {
        let displays = [Self.macBookPrimary, Self.leftNegativeDisplay, Self.rightPositiveDisplay]
        let sourceWinCG = CGRect(x: 200, y: 150, width: 640, height: 360) // 16:9 logical window on Retina 2x = 1280x720 px
        let sourcePixels = PixelSize(width: 1280, height: 720)
        let targetPixels = Self.macBookPrimary.pixelSize // 3024x1964 (16:10)

        // 1. Fit letterboxing (16:9 on 16:10 Retina display) across ALL 9 alignments
        for alignment in OutputAlignment.allCases {
            let layout = ScalingLayoutCalculator.calculate(
                sourcePixelSize: sourcePixels,
                targetPixelSize: targetPixels,
                targetCGRect: Self.macBookPrimary.cgBounds,
                backingScaleFactor: 2.0,
                crop: .zero,
                effects: [EffectInstance(effectID: .metalFXSpatial, scalingType: .fit)],
                presentationMode: .fullscreen,
                alignment: alignment
            )
            let mapping = PointerMapping(
                sourceWindowCGRect: sourceWinCG,
                layout: layout,
                displays: displays
            )

            #expect(mapping.isValid)
            #expect(!mapping.isIdentity)
            #expect(mapping.hasLetterboxBars)

            // Fencepost exact top-left and bottom-right mapping!
            let tl = mapping.mapSourceToScaled(CGPoint(x: sourceWinCG.minX, y: sourceWinCG.minY))
            #expect(abs(tl.x - layout.contentRect.minX) < 1e-6)
            #expect(abs(tl.y - layout.contentRect.minY) < 1e-6)

            let br = mapping.mapSourceToScaled(CGPoint(x: sourceWinCG.maxX - 1.0, y: sourceWinCG.maxY - 1.0))
            #expect(abs(br.x - (layout.contentRect.maxX - 1.0)) < 1e-6)
            #expect(abs(br.y - (layout.contentRect.maxY - 1.0)) < 1e-6)

            // Round-trip interior point accuracy
            let midSrc = CGPoint(x: sourceWinCG.minX + 319.5, y: sourceWinCG.minY + 179.5)
            let midScaled = mapping.mapSourceToScaled(midSrc)
            let roundTrip = mapping.mapScaledToSource(midScaled)
            #expect(abs(roundTrip.x - midSrc.x) < 1e-6)
            #expect(abs(roundTrip.y - midSrc.y) < 1e-6)
        }

        // 2. Fill overscan (16:9 covering 16:10 -> horizontal sides clipped via visibleTextureUVRect)
        let fillLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: sourcePixels,
            targetPixelSize: targetPixels,
            targetCGRect: Self.macBookPrimary.cgBounds,
            backingScaleFactor: 2.0,
            crop: .zero,
            effects: [EffectInstance(effectID: .bicubic, scalingType: .fill)],
            presentationMode: .fullscreen,
            alignment: .center
        )
        let fillMapping = PointerMapping(sourceWindowCGRect: sourceWinCG, layout: fillLayout, displays: displays)
        #expect(fillLayout.visibleTextureUVRect.width < 0.99)
        #expect(fillMapping.sourceRect.width < sourceWinCG.width, "Fill mode effectiveSourceCGRect must shrink to visible UV slice")
        let fillTL = fillMapping.mapSourceToScaled(fillMapping.sourceRect.origin)
        #expect(abs(fillTL.x - fillLayout.contentRect.minX) < 1e-6)
        #expect(abs(fillTL.y - fillLayout.contentRect.minY) < 1e-6)

        // 3. Stretch mode
        let stretchLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: sourcePixels,
            targetPixelSize: targetPixels,
            targetCGRect: Self.macBookPrimary.cgBounds,
            backingScaleFactor: 2.0,
            effects: [EffectInstance(effectID: .bilinear, scalingType: .stretch)],
            presentationMode: .fullscreen
        )
        let stretchMapping = PointerMapping(sourceWindowCGRect: sourceWinCG, layout: stretchLayout, displays: displays)
        #expect(!stretchMapping.hasLetterboxBars)
        #expect(abs(stretchMapping.scaleX - (1512.0 / 640.0)) < 0.01)
        #expect(abs(stretchMapping.scaleY - (982.0 / 360.0)) < 0.01)

        // 4. IntegerFit mode
        let intLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 640, height: 360),
            targetPixelSize: targetPixels,
            targetCGRect: Self.macBookPrimary.cgBounds,
            backingScaleFactor: 2.0,
            effects: [EffectInstance(effectID: .nearest, scalingType: .integerFit)],
            presentationMode: .fullscreen,
            alignment: .center
        )
        let intMapping = PointerMapping(sourceWindowCGRect: sourceWinCG, layout: intLayout, displays: displays)
        #expect(intLayout.finalOutputPixelSize == PixelSize(width: 2560, height: 1440)) // 4x integer!
        #expect(intMapping.hasLetterboxBars)
        // Verify point inside black top bar is detected & clamped (or escaped on side monitors)
        let barPoint = CGPoint(x: 756, y: 10)
        #expect(intMapping.isPointInLetterboxBar(barPoint))
        if case .clampedToContent(let clamped) = intMapping.resolveScaledPoint(barPoint, allowAdjacentDisplayEscape: true) {
            #expect(abs(clamped.y - intLayout.contentRect.minY) < 1e-6)
        } else {
            Issue.record("Expected top letterbox bar (no display above) to clamp to content top")
        }
        // Crossing left edge toward leftNegativeDisplay should escape cleanly!
        let leftEscapePt = CGPoint(x: intLayout.contentRect.minX - 20, y: 400)
        if case .escapedToAdjacentDisplay(let pt, let adj, let edge) = intMapping.resolveScaledPoint(leftEscapePt, allowAdjacentDisplayEscape: true) {
            #expect(adj.id == Self.leftNegativeDisplay.id)
            #expect(edge == .left)
            #expect(pt.x == Self.leftNegativeDisplay.cgBounds.maxX - 1.0)
        } else {
            Issue.record("Expected left letterbox escape onto leftNegativeDisplay")
        }

        // 5. Crop insets (L/T/R/B) accurately shift effective source rect
        let crop = CropInsets(enabled: true, left: 128, top: 72, right: 128, bottom: 72) // 10% each edge in 1280x720 px -> 64pt L/R, 36pt T/B
        let cropLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: sourcePixels,
            targetPixelSize: targetPixels,
            targetCGRect: Self.macBookPrimary.cgBounds,
            backingScaleFactor: 2.0,
            crop: crop,
            effects: [EffectInstance(effectID: .lanczos6, scalingType: .fit)],
            presentationMode: .fullscreen
        )
        let cropMapping = PointerMapping(sourceWindowCGRect: sourceWinCG, layout: cropLayout, displays: displays)
        #expect(abs(cropMapping.sourceRect.minX - (sourceWinCG.minX + 64.0)) < 1e-6)
        #expect(abs(cropMapping.sourceRect.minY - (sourceWinCG.minY + 36.0)) < 1e-6)
        #expect(abs(cropMapping.sourceRect.width - (sourceWinCG.width - 128.0)) < 1e-6)
        #expect(abs(cropMapping.sourceRect.height - (sourceWinCG.height - 72.0)) < 1e-6)

        // 6. Windowed mode + Dual-monitor negative and positive offsets
        let negWinCG = CGRect(x: -1600, y: 200, width: 640, height: 360)
        let negOverlayCG = CGRect(x: -1760, y: 110, width: 960, height: 540)
        let windowedLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: sourcePixels,
            targetPixelSize: PixelSize(width: 1920, height: 1080),
            targetCGRect: negOverlayCG,
            backingScaleFactor: 2.0,
            effects: [EffectInstance(effectID: .metalFXSpatial, scalingType: .fit)],
            presentationMode: .windowed(initialScale: 1.5)
        )
        let negMapping = PointerMapping(sourceWindowCGRect: negWinCG, layout: windowedLayout, displays: displays)
        let negMappedCenter = negMapping.mapSourceToScaled(CGPoint(x: negWinCG.midX, y: negWinCG.midY))
        #expect(abs(negMappedCenter.x - negOverlayCG.midX) < 1.0)
        #expect(abs(negMappedCenter.y - negOverlayCG.midY) < 1.0)
        // Verify Cocoa conversion on negative-X display preserves X and flips Y around primary height (982).
        let negCocoaFrame = negMapping.overlayCocoaFrame()
        #expect(abs(negCocoaFrame.minX - (-1760)) < 1e-6)
        #expect(abs(negCocoaFrame.minY - (982.0 - (110.0 + 540.0))) < 1e-6)

        // Positive secondary monitor
        let posWinCG = CGRect(x: 1600, y: 100, width: 640, height: 360)
        let posMapping = PointerMapping(
            sourceRect: posWinCG,
            contentRect: Self.rightPositiveDisplay.cgBounds,
            overlayRect: Self.rightPositiveDisplay.cgBounds,
            displays: displays
        )
        let confinedPos = posMapping.constrainSourcePoint(CGPoint(x: 1500, y: 50))
        #expect(confinedPos.wasClamped)
        #expect(confinedPos.clampedEdges == [.left, .top])
        #expect(confinedPos.point.x >= posWinCG.minX)
        #expect(confinedPos.point.y >= posWinCG.minY)

        // 7. 1:1 Identity passthrough requires ZERO Accessibility event tap (non-3D mode)
        let identityMapping = PointerMapping(
            sourceRect: sourceWinCG,
            contentRect: sourceWinCG,
            overlayRect: sourceWinCG,
            displays: displays,
            threeDGameMode: false
        )
        #expect(identityMapping.isIdentity)
        #expect(identityMapping.requiresEventTap == false)
        #expect(identityMapping.requiresScaledOverlayCursor == false)

        // 8. Cursor scale modes & hotspot Y-flip anchorPoint
        let spriteGeom = fillMapping.spriteGeometry(
            forSourcePoint: CGPoint(x: fillMapping.sourceRect.midX, y: fillMapping.sourceRect.midY),
            cursorPointSize: CGSize(width: 24, height: 24),
            hotSpot: CGPoint(x: 6, y: 6)
        )
        #expect(abs(spriteGeom.layerAnchorPoint.x - 0.25) < 1e-6)
        #expect(abs(spriteGeom.layerAnchorPoint.y - 0.75) < 1e-6)
        #expect(spriteGeom.drawablePixelRect.origin.x == spriteGeom.drawablePixelRect.origin.x.rounded())
        #expect(spriteGeom.drawablePixelRect.origin.y == spriteGeom.drawablePixelRect.origin.y.rounded())
    }

    @Test("PointerTracker detects interior FPS mouse-grab, border-adjacent inward grab, warp-to-center loop, and clean release")
    func pointerTrackerFPSGrabAndRelease() {
        let mapping = PointerMapping(
            sourceRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            contentRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            overlayRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            displays: [Self.macBookPrimary]
        )

        // 1. Interior stationary grab (CGAssociateMouseAndMouseCursorPosition(false))
        var tracker = PointerTracker(grabThreshold: 3, releaseMoveThreshold: 2)
        let center = CGPoint(x: 500, y: 400)
        _ = tracker.recordEvent(location: center, deltaX: 0, deltaY: 0, mapping: mapping, timestamp: 1.00)
        #expect(!tracker.isGrabbed)
        _ = tracker.recordEvent(location: center, deltaX: 12, deltaY: -4, mapping: mapping, timestamp: 1.01)
        _ = tracker.recordEvent(location: center, deltaX: 10, deltaY: 2, mapping: mapping, timestamp: 1.02)
        #expect(!tracker.isGrabbed)
        let grabbed = tracker.recordEvent(location: center, deltaX: -8, deltaY: 5, mapping: mapping, timestamp: 1.03)
        #expect(grabbed && tracker.isGrabbed)

        // Genuine cursor motion releases grab cleanly after releaseMoveThreshold (2) events
        _ = tracker.recordEvent(location: CGPoint(x: 520, y: 405), deltaX: 20, deltaY: 5, mapping: mapping, timestamp: 1.10)
        #expect(tracker.isGrabbed)
        let stillGrabbed = tracker.recordEvent(location: CGPoint(x: 545, y: 410), deltaX: 25, deltaY: 5, mapping: mapping, timestamp: 1.11)
        #expect(!stillGrabbed && !tracker.isGrabbed)

        // 2. Border-adjacent OUTWARD push (normal user hitting left edge) must NOT trigger grab!
        tracker.reset()
        let leftBorder = CGPoint(x: mapping.confinementRect.minX, y: 400)
        _ = tracker.recordEvent(location: leftBorder, deltaX: -5, deltaY: 0, mapping: mapping, timestamp: 2.00)
        for i in 1...5 {
            _ = tracker.recordEvent(location: leftBorder, deltaX: -10, deltaY: 0, mapping: mapping, timestamp: 2.0 + Double(i) * 0.01)
        }
        #expect(!tracker.isGrabbed, "Pushing outward against left border must NOT false-positive as FPS mouse grab")

        // 3. Border-adjacent INWARD deltas with unchanged cursor (MetalGoose border false-negative fix!)
        for i in 1...3 {
            _ = tracker.recordEvent(location: leftBorder, deltaX: 15, deltaY: 0, mapping: mapping, timestamp: 2.2 + Double(i) * 0.01)
        }
        #expect(tracker.isGrabbed, "Stationary cursor at border with INWARD deltas MUST trigger FPS mouse grab!")
    }

    @Test("SystemCursorHider preserves strict hide/show refcount invariants and clean deinit restore")
    func systemCursorHiderRefcountInvariants() {
        let initialGlobal = SystemCursorHider.processHideDepth
        do {
            let hider = SystemCursorHider()
            #expect(hider.hideDepth == 0)
            #expect(!hider.isHidden)

            // Idempotent hide
            hider.hide()
            hider.hide()
            hider.hide()
            #expect(hider.hideDepth == 1)
            #expect(hider.isHidden)
            #expect(SystemCursorHider.processHideDepth == initialGlobal + 1)

            // Balanced show + extra show never goes negative
            hider.show()
            hider.show()
            #expect(hider.hideDepth == 0)
            #expect(!hider.isHidden)
            #expect(SystemCursorHider.processHideDepth == initialGlobal)

            // Acquire again and let `deinit` restore automatically
            hider.hide()
            #expect(SystemCursorHider.processHideDepth == initialGlobal + 1)
        }
        #expect(SystemCursorHider.processHideDepth == initialGlobal, "SystemCursorHider.deinit must restore hide depth cleanly")
        SystemCursorHider.emergencyRestoreAll()
        #expect(SystemCursorHider.processHideDepth == 0)
    }

    @Test("CursorOverlayController foreign-overlay yield restores OS cursor, passes events through 1:1, and stays orthogonal to suspend")
    func cursorYieldOrthogonalityAndPassthrough() throws {
        let controller = CursorOverlayController(presentationMode: .overlayLayer)
        defer { controller.stop() }

        let config = CursorMappingConfiguration(
            sourceCGRect: CGRect(x: 100, y: 100, width: 640, height: 360),
            destinationCGRect: CGRect(x: 0, y: 33, width: 1512, height: 949),
            overlayCGRect: CGRect(x: 0, y: 33, width: 1512, height: 949),
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true),
            threeDGameMode: false
        )

        controller.activateForEventTapTesting(
            configuration: config,
            displays: [Self.macBookPrimary],
            initialPointer: CGPoint(x: 320, y: 240)
        )
        controller.cursorHiderForTesting.setAllowedToHide(true)
        controller.cursorHiderForTesting.hide()
        #expect(controller.cursorHiderForTesting.hideDepth == 1)
        #expect(controller.currentState.isVisible == true)

        // Enter third-party screenshot UI -> yield cursor immediately
        controller.setYieldedForForeignOverlay(true)
        #expect(controller.isYieldedForForeignOverlay == true)
        #expect(controller.isSuspended == false)
        #expect(controller.currentState.isVisible == false)
        #expect(controller.cursorHiderForTesting.isAllowedToHide == false)
        #expect(controller.cursorHiderForTesting.hideDepth == 0)

        // Drift check must NEVER re-hide OS cursor while yielded for screenshot tool!
        let reasserted = controller.cursorHiderForTesting.reassertHiddenIfDrifted(
            now: 100.0,
            assumedCursorVisibleForTesting: true
        )
        #expect(reasserted == false)
        #expect(controller.cursorHiderForTesting.hideDepth == 0)

        // Mouse events during screenshot UI MUST pass through 1:1 untouched (no confinement/rewriting)
        let box = EventTapCallbackBox(controller: controller)
        let testPt = CGPoint(x: 1420, y: 900)
        let moveEvent = try #require(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: testPt,
            mouseButton: .left
        ))
        let dummyProxy = OpaquePointer(bitPattern: 1)!
        let returned = box.invoke(proxy: dummyProxy, type: .mouseMoved, event: moveEvent)
        #expect(returned != nil)
        #expect(abs(moveEvent.location.x - testPt.x) < 0.01)
        #expect(abs(moveEvent.location.y - testPt.y) < 0.01)

        // Orthogonality: suspend while yielded, then exit screenshot overlay -> MUST remain suspended!
        controller.suspend()
        #expect(controller.isSuspended == true)
        controller.setYieldedForForeignOverlay(false)
        #expect(controller.isYieldedForForeignOverlay == false)
        #expect(controller.isSuspended == true)
        #expect(controller.cursorHiderForTesting.isAllowedToHide == false)
        #expect(controller.cursorHiderForTesting.hideDepth == 0)
        #expect(controller.currentState.isVisible == false)

        // Re-yield while suspended, then call resume() -> MUST remain yielded until foreign overlay closes!
        controller.setYieldedForForeignOverlay(true)
        controller.resume()
        #expect(controller.isSuspended == false)
        #expect(controller.isYieldedForForeignOverlay == true)
        #expect(controller.cursorHiderForTesting.isAllowedToHide == false)
        #expect(controller.currentState.isVisible == false)
    }

    @Test("AutoScaleController enforces bundle+title regex specificity, blacklist, popup/tiny exemption, and anti-retrigger lock")
    func autoScaleControllerRulesAndSafeguards() async throws {
        var config = AppConfig.defaultConfig
        let bundleProfile = Profile(
            name: "RetroArch General",
            bundleIdentifier: "com.libretro.RetroArch",
            scalingModeID: ScalingMode.lanczos6ID,
            autoScaleMode: .windowed,
            autoScaleDelaySeconds: 0.05
        )
        let titleProfile = Profile(
            name: "RetroArch SNES",
            bundleIdentifier: "com.libretro.RetroArch",
            windowTitlePattern: "SNES9x|Super Mario",
            scalingModeID: ScalingMode.crtGeomID,
            autoScaleMode: .fullscreen,
            autoScaleDelaySeconds: 0.05
        )
        config.profiles = [.defaultProfile, bundleProfile, titleProfile]

        let mockTracker = MockWindowTracker()
        let controller = AutoScaleController(
            config: config,
            windowTracker: mockTracker,
            stabilityRetryDelaySeconds: 0.05
        )
        defer { controller.stop() }

        // 1. Bundle + title regex wins over bundle-only profile
        let snesWin = WindowDescriptor(
            windowID: 501,
            pid: 5001,
            appName: "RetroArch",
            bundleIdentifier: "com.libretro.RetroArch",
            title: "RetroArch SNES9x - Super Mario World",
            cgBounds: CGRect(x: 100, y: 100, width: 640, height: 480)
        )
        if case .eligible(let trig) = controller.evaluateCandidate(snesWin) {
            #expect(trig.profile.id == titleProfile.id)
            #expect(trig.presentationMode.isFullscreen)
        } else {
            Issue.record("Expected title-specific profile to match snesWin")
        }

        // 2. Bundle-only profile matches other title
        let gbaWin = WindowDescriptor(
            windowID: 502,
            pid: 5001,
            appName: "RetroArch",
            bundleIdentifier: "com.libretro.RetroArch",
            title: "RetroArch mGBA - Metroid Fusion",
            cgBounds: CGRect(x: 100, y: 100, width: 480, height: 320)
        )
        if case .eligible(let trig) = controller.evaluateCandidate(gbaWin) {
            #expect(trig.profile.id == bundleProfile.id)
            #expect(trig.presentationMode.isWindowed)
        } else {
            Issue.record("Expected bundle-only profile to match gbaWin")
        }

        // 3. System blacklist rejection
        let dockWin = WindowDescriptor(
            windowID: 503,
            pid: 100,
            appName: "Dock",
            bundleIdentifier: "com.apple.dock",
            title: "",
            cgBounds: CGRect(x: 0, y: 900, width: 1512, height: 82)
        )
        if case .ignoredExcludedBundle(let bid) = controller.evaluateCandidate(dockWin) {
            #expect(bid == "com.apple.dock")
        } else {
            Issue.record("Expected Dock to be rejected by system blacklist")
        }

        // 4. Tiny window (< 200x150) & modal/popup exemption
        let tinyWin = WindowDescriptor(
            windowID: 504,
            pid: 5001,
            appName: "RetroArch",
            bundleIdentifier: "com.libretro.RetroArch",
            title: "SNES9x",
            cgBounds: CGRect(x: 100, y: 100, width: 180, height: 120)
        )
        if case .ignoredPopupOrTinyWindow = controller.evaluateCandidate(tinyWin) {
        } else {
            Issue.record("Expected tiny window (<200x150) to be exempt")
        }
        if case .ignoredPopupOrTinyWindow = controller.evaluateCandidate(snesWin, isModalOrPopup: true) {
        } else {
            Issue.record("Expected modal/popup window to be exempt")
        }

        // 5. Owned popup of already-scaled PID exemption
        controller.setCurrentlyScaling(window: snesWin)
        if case .ignoredOwnedPopupOfScaledApp(let pid) = controller.evaluateCandidate(gbaWin) {
            #expect(pid == snesWin.pid)
        } else {
            Issue.record("Expected same-PID secondary window while scaling to be ignored as owned popup")
        }
        controller.setCurrentlyScaling(window: nil)

        // 6. Anti-retrigger lock after manual stop + live debounced trigger delivery
        let triggers = OSAllocatedUnfairLock<[AutoScaleTrigger]>(initialState: [])
        mockTracker.setFrontmost(snesWin)
        controller.notifyManualStop(windowID: snesWin.windowID)
        controller.start { trig in
            triggers.withLock { $0.append(trig) }
        }
        try await Task.sleep(for: .milliseconds(30))

        #expect(controller.suppressedWindowID == snesWin.windowID)
        if case .ignoredAntiRetriggerLocked(let wid) = controller.evaluateCandidate(snesWin) {
            #expect(wid == snesWin.windowID)
        } else {
            Issue.record("Expected anti-retrigger lock after manual stop")
        }

        // Focusing MetalPie's own window must NOT unlock the anti-retrigger lock
        let ownMetalPieWin = WindowDescriptor(
            windowID: 999,
            pid: ProcessInfo.processInfo.processIdentifier,
            appName: "MetalPie",
            bundleIdentifier: "com.metalpie.app",
            title: "MetalPie",
            cgBounds: CGRect(x: 100, y: 100, width: 900, height: 600),
            ownerCategory: .metalPie
        )
        controller.handleActiveWindowChanged(ownMetalPieWin)
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.suppressedWindowID == snesWin.windowID)

        // Switching to another real app unlocks the anti-retrigger lock
        let otherAppWin = WindowDescriptor(
            windowID: 600,
            pid: 6000,
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            title: "Notes",
            cgBounds: CGRect(x: 100, y: 100, width: 600, height: 500)
        )
        mockTracker.setFrontmost(otherAppWin)
        controller.handleActiveWindowChanged(otherAppWin)
        try await Task.sleep(for: .milliseconds(40))
        #expect(controller.suppressedWindowID == nil)

        // Returning to snesWin now fires the auto-scale trigger cleanly!
        mockTracker.setFrontmost(snesWin)
        controller.handleActiveWindowChanged(snesWin)
        let fired = await waitForCondition(timeoutSeconds: 2.0) {
            triggers.withLock { !$0.isEmpty }
        }
        #expect(fired)
        #expect(triggers.withLock(\.first)?.window.windowID == snesWin.windowID)
        #expect(triggers.withLock(\.first)?.profile.id == titleProfile.id)
    }

    @Test("WindowEnumerator and WindowLifecycleWatcher filter system windows, detect Wine raised fullscreen, 3D Game Mode 8pt overlap, and nil-window close")
    func windowFilteringWineRaisedAndOverlapDetection() async throws {
        let displays = [Self.macBookPrimary]
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // 1. System blacklist & Wine raised-layer borderless fullscreen detection
        let snapshots: [RawWindowSnapshot] = [
            // System Dock -> filtered
            RawWindowSnapshot(windowID: 1, pid: 101, ownerName: "Dock", bundleIdentifier: "com.apple.dock", title: "", cgBounds: CGRect(x: 0, y: 900, width: 1512, height: 82), layer: 20),
            // MetalPie own window -> filtered
            RawWindowSnapshot(windowID: 2, pid: ownPID, ownerName: "MetalPie", bundleIdentifier: "com.metalpie.app", title: "Overlay", cgBounds: Self.macBookPrimary.cgBounds, layer: 100),
            // Tiny helper < 64x64 -> filtered
            RawWindowSnapshot(windowID: 3, pid: 200, ownerName: "Helper", bundleIdentifier: "com.example.helper", title: "Dot", cgBounds: CGRect(x: 10, y: 10, width: 32, height: 32), layer: 0),
            // Raised small tooltip/overlay (layer 25, NOT display-filling) -> filtered
            RawWindowSnapshot(windowID: 4, pid: 201, ownerName: "OverlayTool", bundleIdentifier: "com.example.tool", title: "HUD", cgBounds: CGRect(x: 200, y: 200, width: 300, height: 200), layer: 25),
            // Wine/CrossOver raised-layer borderless fullscreen (layer 26, fills display!) -> INCLUDED!
            RawWindowSnapshot(windowID: 5, pid: 300, ownerName: "wine64-preloader", bundleIdentifier: "com.codeweavers.CrossOver", title: "Elden Ring", cgBounds: Self.macBookPrimary.cgBounds, layer: 26),
            // Normal layer-0 app window -> INCLUDED!
            RawWindowSnapshot(windowID: 6, pid: 301, ownerName: "HollowKnight", bundleIdentifier: "com.teamcherry.hk", title: "Hollow Knight", cgBounds: CGRect(x: 100, y: 100, width: 1280, height: 720), layer: 0)
        ]

        let capturable = WindowLifecycleWatcher.filterCapturableWindows(
            from: snapshots,
            displays: displays,
            ownPID: ownPID
        )
        let ids = Set(capturable.map(\.windowID))
        #expect(ids == [5, 6], "Only Wine raised fullscreen (5) and normal app (6) should be capturable; got \(ids)")

        // Verify WindowEnumerator agrees on Wine raised fullscreen & system blacklist
        #expect(WindowEnumerator.isRaisedFullscreenWindow(layer: 26, alpha: 1.0, bounds: Self.macBookPrimary.cgBounds, displays: displays))
        #expect(!WindowEnumerator.isRaisedFullscreenWindow(layer: 25, alpha: 1.0, bounds: CGRect(x: 200, y: 200, width: 300, height: 200), displays: displays))
        #expect(WindowEnumerator.classifyOwner(pid: 101, bundleIdentifier: "com.apple.controlcenter", ownerName: "Control Center", layer: 25, bounds: CGRect(x: 0, y: 0, width: 300, height: 300), displays: displays) == .system)
        #expect(WindowEnumerator.classifyOwner(pid: ownPID, bundleIdentifier: "com.metalpie.app", ownerName: "MetalPie", layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), displays: displays) == .metalPie)

        // 2. 3D Game Mode >= 8pt foreign window overlap detection (both layer 0 AND substantial floating layer > 0!)
        let gameBounds = CGRect(x: 100, y: 100, width: 1280, height: 720)
        let gamePID: Int32 = 301

        // 7pt overlap -> NOT enough (must be >= 8pt in both axes)
        let minorOverlap = RawWindowSnapshot(
            windowID: 70,
            pid: 400,
            ownerName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            title: "Slack",
            cgBounds: CGRect(x: 1373, y: 100, width: 400, height: 400), // 7pt X overlap
            layer: 0
        )
        #expect(WindowLifecycleWatcher.detectForeignWindowOverlap(
            trackedBounds: gameBounds,
            trackedPID: gamePID,
            ownPID: ownPID,
            displays: displays,
            windowsAboveTarget: [minorOverlap]
        ) == nil)

        // 8pt normal layer-0 overlap -> DETECTED!
        let normalOverlap = RawWindowSnapshot(
            windowID: 71,
            pid: 400,
            ownerName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            title: "Slack",
            cgBounds: CGRect(x: 1372, y: 100, width: 400, height: 400), // exact 8pt X overlap
            layer: 0
        )
        let normalHit = WindowLifecycleWatcher.detectForeignWindowOverlap(
            trackedBounds: gameBounds,
            trackedPID: gamePID,
            ownPID: ownPID,
            displays: displays,
            windowsAboveTarget: [normalOverlap]
        )
        #expect(normalHit?.window.windowID == 71)
        #expect(normalHit?.overlapRect.width == 8.0)

        // Substantial floating window (layer > 0, >= 200x150, e.g. floating PiP/Discord) overlapping by >= 8pt -> DETECTED!
        let floatingOverlap = RawWindowSnapshot(
            windowID: 72,
            pid: 401,
            ownerName: "Discord",
            bundleIdentifier: "com.hnc.Discord",
            title: "Discord Call",
            cgBounds: CGRect(x: 300, y: 300, width: 320, height: 240),
            layer: 3
        )
        let floatingHit = WindowLifecycleWatcher.detectForeignWindowOverlap(
            trackedBounds: gameBounds,
            trackedPID: gamePID,
            ownPID: ownPID,
            displays: displays,
            windowsAboveTarget: [floatingOverlap]
        )
        #expect(floatingHit?.window.windowID == 72, "Substantial floating foreign window (>=200x150, layer > 0) overlapping 3D game must be detected!")

        // Own overlay / ignoredOverlayWindowIDs / same trackedPID -> IGNORED!
        let ignoredWin = RawWindowSnapshot(
            windowID: 73,
            pid: 400,
            ownerName: "Toolbar",
            bundleIdentifier: "com.example.toolbar",
            title: "Toolbar",
            cgBounds: CGRect(x: 200, y: 200, width: 400, height: 300),
            layer: 0
        )
        #expect(WindowLifecycleWatcher.detectForeignWindowOverlap(
            trackedBounds: gameBounds,
            trackedPID: gamePID,
            ownPID: ownPID,
            ignoredWindowIDs: [73],
            displays: displays,
            windowsAboveTarget: [ignoredWin]
        ) == nil)

        // 3. WindowLifecycleWatcher handles `windowInfo == nil` immediately (no orphan overlay!)
        let watcher = WindowLifecycleWatcher(pollIntervalMilliseconds: 25)
        defer { watcher.stopObserving() }
        let closedWindowID = OSAllocatedUnfairLock<CGWindowID?>(initialState: nil)
        let nonexistentID: CGWindowID = 0x7FFF_FFFE
        watcher.startObserving(trackedWindowID: nonexistentID) { event in
            if case .trackedWindowClosed(let wid) = event {
                closedWindowID.withLock { $0 = wid }
            }
        }
        let sawClose = await waitForCondition(timeoutSeconds: 2.0) {
            closedWindowID.withLock { $0 == nonexistentID }
        }
        #expect(sawClose, "WindowLifecycleWatcher MUST emit trackedWindowClosed immediately when tracked windowInfo == nil")
    }

    @Test("GlobalHotkeyManager registers Carbon shortcuts + reserved panic chord, detects conflicts, and cleans up")
    func globalHotkeyManagerRegistrationAndConflicts() throws {
        let manager = GlobalHotkeyManager(debounceIntervalSeconds: 0.05)
        defer { manager.unregisterAll() }

        // 1. Clean registration of distinct chords + reserved panicStop (`⌃⌥⌘⎋`)
        let cleanConfig = HotkeyConfig(
            toggleFullscreen: HotkeyBinding(keyCode: 18, modifiers: [.control, .option, .shift], displayString: "⌃⌥⇧1"),
            toggleWindowed: HotkeyBinding(keyCode: 19, modifiers: [.control, .option, .shift], displayString: "⌃⌥⇧2"),
            toggleToolbar: HotkeyBinding(keyCode: 20, modifiers: [.control, .option, .shift], displayString: "⌃⌥⇧3"),
            captureScreenshot: HotkeyBinding(keyCode: 21, modifiers: [.control, .option, .shift], displayString: "⌃⌥⇧4")
        )
        try manager.register(config: cleanConfig) { _ in }
        #expect(manager.isRegistered)
        #expect(manager.activeBindings[.panicStop] == HotkeyBinding.panicStop)
        #expect(manager.activeBindings[.toggleFullscreen] == cleanConfig.toggleFullscreen)
        #expect(manager.activeBindings[.toggleWindowed] == cleanConfig.toggleWindowed)
        #expect(manager.activeBindings[.toggleToolbar] == cleanConfig.toggleToolbar)
        #expect(manager.activeBindings[.captureScreenshot] == cleanConfig.captureScreenshot)
        #expect(manager.failedRegistrations.isEmpty)

        // 2. Conflict detection: binding matching reserved panicStop chord throws, yet panicStop + other valid keys stay active!
        var conflictingConfig = cleanConfig
        conflictingConfig.toggleToolbar = HotkeyBinding.panicStop
        var caughtError: EngineError?
        do {
            try manager.register(config: conflictingConfig) { _ in }
        } catch let err as EngineError {
            caughtError = err
        }
        #expect(caughtError != nil, "Expected EngineError.hotkeyRegistrationFailed on panic-chord collision")
        #expect(manager.activeBindings[.panicStop] == HotkeyBinding.panicStop, "Reserved panicStop MUST stay registered even when user config conflicts!")
        #expect(manager.failedRegistrations[.toggleToolbar] != nil)
        #expect(manager.activeBindings[.toggleFullscreen] == cleanConfig.toggleFullscreen)

        // 3. Unregister clears everything
        manager.unregisterAll()
        #expect(!manager.isRegistered)
        #expect(manager.activeBindings.isEmpty)
    }

    @Test("RunGuardWatchdog executes emergency recovery handlers on trigger and on simulated main-thread stall")
    func runGuardWatchdogRecoveryAndStallDetection() async throws {
        // Use a dedicated isolated watchdog instance with short threshold & terminateProcessOnStall = false
        let watchdog = RunGuardWatchdog(
            stallThresholdSeconds: 0.12,
            heartbeatIntervalSeconds: 0.5, // slower than stall threshold so it trips deterministically without blocking main!
            checkIntervalSeconds: 0.03,
            terminateProcessOnStall: false
        )
        defer { watchdog.stop() }

        let recoveryCount = OSAllocatedUnfairLock(initialState: 0)
        let stallElapsed = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

        let token = watchdog.registerRecoveryHandler(name: "TestOverlayCleanup") {
            recoveryCount.withLock { $0 += 1 }
        }

        // 1. Direct emergency recovery execution
        watchdog.triggerEmergencyRecovery(reason: "Integration test direct recovery")
        #expect(recoveryCount.withLock { $0 } == 1)

        // 2. Simulated stall detection while scaling active
        watchdog.start { elapsed in
            stallElapsed.withLock { $0 = elapsed }
        }
        watchdog.setScalingActive(true)

        let tripped = await waitForCondition(timeoutSeconds: 2.0) {
            watchdog.stallCount >= 1 && recoveryCount.withLock { $0 >= 2 } && stallElapsed.withLock { $0 != nil }
        }
        #expect(tripped, "Watchdog should detect heartbeat stall > threshold and execute registered recovery handlers")
        #expect((stallElapsed.withLock { $0 } ?? 0) >= 0.12)

        watchdog.unregisterRecoveryHandler(token)
        watchdog.setScalingActive(false)
        watchdog.stop()
        #expect(!watchdog.isRunning)
    }
}
