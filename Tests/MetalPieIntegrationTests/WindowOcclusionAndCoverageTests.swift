import AppKit
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import Testing
import os

@testable import MetalPieCore
@testable import MetalPieCapture

// MARK: - Live CAMetalDisplayLink Test Driver

private final class TestDisplayLinkDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private let queue: any MTLCommandQueue
    private let layer: CAMetalLayer
    private let frameCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let stopped = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var runLoop: RunLoop?
    private let readySem = DispatchSemaphore(value: 0)

    var callbackCount: Int {
        frameCounter.withLock { $0 }
    }

    init(device: any MTLDevice, layer: CAMetalLayer) throws {
        guard let queue = device.makeCommandQueue() else {
            throw EngineError.metalDeviceUnavailable
        }
        self.queue = queue
        self.layer = layer
        super.init()
    }

    func resetCount() {
        frameCounter.withLock { $0 = 0 }
    }

    func start() {
        stopped.withLock { $0 = false }
        let thread = Thread { [weak self] in
            guard let self else { return }
            let rl = RunLoop.current
            rl.add(Port(), forMode: .default)
            let dl = CAMetalDisplayLink(metalLayer: self.layer)
            dl.delegate = self
            dl.preferredFrameLatency = 2
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
            dl.add(to: rl, forMode: .default)
            self.runLoop = rl
            self.readySem.signal()
            while !self.stopped.withLock({ $0 }) {
                _ = autoreleasepool {
                    rl.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
                }
            }
            dl.invalidate()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        readySem.wait()
    }

    func stop() {
        stopped.withLock { $0 = true }
        if let rl = runLoop {
            CFRunLoopWakeUp(rl.getCFRunLoop())
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let count = frameCounter.withLock { c -> Int in
            c += 1
            return c
        }
        let drawable = update.drawable
        guard let cb = queue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(count % 60) / 240.0,
            green: 0.12,
            blue: 0.18,
            alpha: 1.0
        )
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }
}

@MainActor
private func flushAndSleep(milliseconds: Int) async {
    CATransaction.flush()
    try? await Task.sleep(for: .milliseconds(milliseconds))
    CATransaction.flush()
}

// MARK: - Window Occlusion & Windowed Coverage Regression Suite

@Suite("Window Anti-Occlusion & Windowed Single-Window Coverage", .serialized)
struct WindowOcclusionAndCoverageTests {
    // Exact host dual-monitor layout:
    // Primary Built-in Retina: Cocoa (0, 0, 1512, 982)      <-> CG (0, 0, 1512, 982)
    // External DELL P2422H:    Cocoa (1512, 982, 1280, 720) <-> CG (1512, -720, 1280, 720)
    private static let primaryRetina = DisplayDescriptor(
        id: 1,
        name: "Built-in Retina Display",
        cocoaFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        backingScaleFactor: 2.0,
        refreshRateHz: 120.0,
        maxEDRHeadroom: 16.0,
        isPrimary: true
    )

    private static let externalDELLNegativeCGY = DisplayDescriptor(
        id: 2,
        name: "DELL P2422H",
        cocoaFrame: CGRect(x: 1512, y: 982, width: 1280, height: 720),
        cgBounds: CGRect(x: 1512, y: -720, width: 1280, height: 720),
        backingScaleFactor: 2.0,
        refreshRateHz: 60.0,
        maxEDRHeadroom: 1.0,
        isPrimary: false
    )

    private static let dualDisplays: [DisplayDescriptor] = [primaryRetina, externalDELLNegativeCGY]

    // MARK: - Bug #3: Anti-Occlusion + 200+ Frame CAMetalDisplayLink Stability

    @Test("OverlayWindowController runs 200+ CAMetalDisplayLink frames without stalling across Fullscreen, Windowed, and opaque-close -> reopen transitions")
    @MainActor
    func liveDisplayLinkStabilityAcrossModesAndReopen() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on test host")
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let primary = try #require(ScreenGeometry.primaryDisplay(in: displays))

        let sourceCG = CGRect(
            x: (primary.cgBounds.midX - 320).rounded(),
            y: (primary.cgBounds.midY - 180).rounded(),
            width: 640,
            height: 360
        )
        let sourceDescriptor = WindowDescriptor(
            windowID: 77_101,
            pid: ProcessInfo.processInfo.processIdentifier,
            appName: "BrowserSim",
            title: "Video Playback",
            cgBounds: sourceCG,
            isOnScreen: true,
            backingScaleFactor: primary.backingScaleFactor
        )

        let controller = try OverlayWindowController(device: device)
        defer { controller.close() }

        var profile = Profile.defaultProfile
        profile.presentationMode = .fullscreen
        profile.multiMonitorMode = .closest

        // Precondition (MetalGoose 19-callback stall repro): open and close an opaque VRR fullscreen window first!
        controller.isVRRDirectScanoutEnabled = true
        _ = controller.prepareOverlay(
            sourceWindow: sourceDescriptor,
            profile: profile,
            presentationOverride: .fullscreen,
            isNativeFullscreenSpace: false
        )
        let panel = try #require(controller.panel)
        let view = try #require(controller.overlayView)
        #expect(panel.isOpaque == true)
        #expect(abs(panel.alphaValue - 1.0) < 0.0001)
        controller.revealAfterFirstFrame()
        await flushAndSleep(milliseconds: 120)
        controller.close()
        await flushAndSleep(milliseconds: 100)

        // 1. Reopen in Fullscreen non-VRR anti-occlusion mode and verify 200+ consecutive CAMetalDisplayLink callbacks!
        controller.isVRRDirectScanoutEnabled = false
        _ = controller.prepareOverlay(
            sourceWindow: sourceDescriptor,
            profile: profile,
            presentationOverride: .fullscreen,
            isNativeFullscreenSpace: false
        )
        #expect(panel.isOpaque == true)
        #expect(view.metalLayer.isOpaque == true)
        #expect(view.metalLayer.framebufferOnly == true)
        #expect(panel.hasShadow == false)
        #expect(abs(panel.alphaValue - OverlayWindowController.antiOcclusionAlphaValue) < 0.0001)

        controller.revealAfterFirstFrame()
        view.markDisplayLinkAttached()
        CATransaction.flush()

        let driver = try TestDisplayLinkDriver(device: device, layer: view.metalLayer)
        driver.start()
        defer { driver.stop() }

        let fsDeadline = CFAbsoluteTimeGetCurrent() + 4.5
        while CFAbsoluteTimeGetCurrent() < fsDeadline && driver.callbackCount < 210 {
            await flushAndSleep(milliseconds: 50)
        }
        #expect(
            driver.callbackCount >= 200,
            "CAMetalDisplayLink stalled in Fullscreen anti-occlusion mode: only \(driver.callbackCount) callbacks (expected >= 200)"
        )

        // 2. Live switch to Windowed mode (with native shadow enabled) and verify zero DisplayLink stall!
        let winMetrics = controller.setPresentationMode(.windowed(initialScale: 1.5), multiMonitorMode: .closest)
        #expect(panel.hasShadow == true)
        #expect(panel.isOpaque == true)
        #expect(view.metalLayer.isOpaque == true)
        #expect(abs(panel.alphaValue - OverlayWindowController.antiOcclusionAlphaValue) < 0.0001)
        #expect(
            OverlayWindowController.overlayCoversSource(overlayRect: winMetrics.cgFrame, sourceRect: sourceCG),
            "Windowed overlay must completely cover source window"
        )

        driver.resetCount()
        let winDeadline = CFAbsoluteTimeGetCurrent() + 3.0
        while CFAbsoluteTimeGetCurrent() < winDeadline && driver.callbackCount < 110 {
            await flushAndSleep(milliseconds: 50)
        }
        #expect(
            driver.callbackCount >= 100,
            "CAMetalDisplayLink stalled after Fullscreen -> Windowed transition: only \(driver.callbackCount) callbacks"
        )

        // 3. Close & reopen back into Fullscreen non-VRR and confirm DisplayLink resumes cleanly with zero stall!
        controller.close()
        await flushAndSleep(milliseconds: 80)
        _ = controller.prepareOverlay(
            sourceWindow: sourceDescriptor,
            profile: profile,
            presentationOverride: .fullscreen,
            isNativeFullscreenSpace: false
        )
        controller.revealAfterFirstFrame()
        driver.resetCount()
        let reopenDeadline = CFAbsoluteTimeGetCurrent() + 3.0
        while CFAbsoluteTimeGetCurrent() < reopenDeadline && driver.callbackCount < 110 {
            await flushAndSleep(milliseconds: 50)
        }
        #expect(
            driver.callbackCount >= 100,
            "CAMetalDisplayLink stalled after close -> reopen transition: only \(driver.callbackCount) callbacks"
        )
    }

    @Test("Live cross-process WindowServer occlusion check: OverlayWindowController keeps a 100%-covered separate-process NSWindow visible in Fullscreen & Windowed modes")
    @MainActor
    func liveCrossProcessWindowServerAntiOcclusion() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on test host")
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let primary = try #require(ScreenGeometry.primaryDisplay(in: displays))

        let underW = 640
        let underH = 360
        let underCocoaX = Int((primary.cocoaFrame.midX - CGFloat(underW) * 0.5).rounded())
        let underCocoaY = Int((primary.cocoaFrame.midY - CGFloat(underH) * 0.5).rounded())
        let underCocoa = CGRect(x: underCocoaX, y: underCocoaY, width: underW, height: underH)
        let underCG = ScreenGeometry.cocoaToCG(rect: underCocoa, displays: displays)
        let underLevel = OverlayWindowController.normalOverlayLevel.rawValue - 2

        // Spawn a real separate-process AppKit host (just like Chrome/Safari/Edge) whose NSApplication
        // pumps WindowServer occlusion events and reports `occlusionState.contains(.visible)` every 60ms.
        let childScript = """
        import AppKit
        import Foundation
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let win = NSWindow(
            contentRect: NSRect(x: \(underCocoaX), y: \(underCocoaY), width: \(underW), height: \(underH)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
            screen: nil
        )
        win.level = NSWindow.Level(rawValue: \(underLevel))
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.orderFrontRegardless()
        func pump(_ sec: TimeInterval) {
            let end = Date(timeIntervalSinceNow: sec)
            while Date() < end {
                while let ev = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) {
                    app.sendEvent(ev)
                }
                app.updateWindows()
            }
        }
        pump(0.25)
        print("READY \\(win.windowNumber)")
        fflush(stdout)
        for _ in 0..<250 {
            pump(0.06)
            print("OCC \\(win.occlusionState.contains(.visible) ? 1 : 0)")
            fflush(stdout)
        }
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        proc.arguments = ["-"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        defer {
            if proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
        }

        if let scriptData = childScript.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(scriptData)
        }
        inPipe.fileHandleForWriting.closeFile()

        let sharedState = OSAllocatedUnfairLock<(readyWID: CGWindowID?, samples: [Int])>(initialState: (nil, []))
        DispatchQueue.global(qos: .userInitiated).async {
            let fh = outPipe.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: 0..<nl)
                    buffer.removeSubrange(0...nl)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    if line.hasPrefix("READY "), let wid = UInt32(line.dropFirst(6)) {
                        sharedState.withLock { $0.readyWID = CGWindowID(wid) }
                    } else if line.hasPrefix("OCC "), let val = Int(line.dropFirst(4)) {
                        sharedState.withLock { $0.samples.append(val) }
                    }
                }
            }
        }

        let readyDeadline = CFAbsoluteTimeGetCurrent() + 8.0
        var childWID: CGWindowID?
        while CFAbsoluteTimeGetCurrent() < readyDeadline {
            if let wid = sharedState.withLock(\.readyWID) {
                childWID = wid
                break
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        let resolvedChildWID = try #require(childWID, "Separate-process AppKit test window failed to start")

        func collectOcclusionSamples(forMilliseconds ms: Int) async -> [Int] {
            sharedState.withLock { $0.samples.removeAll() }
            await flushAndSleep(milliseconds: ms)
            return sharedState.withLock(\.samples)
        }

        // 0. Baseline: separate-process window must be visible before overlay opens.
        let baselineSamples = await collectOcclusionSamples(forMilliseconds: 300)
        #expect(!baselineSamples.isEmpty && baselineSamples.allSatisfy { $0 == 1 }, "Baseline separate-process window should be visible, got \(baselineSamples)")

        let controller = try OverlayWindowController(device: device)
        defer { controller.close() }

        let sourceDescriptor = WindowDescriptor(
            windowID: resolvedChildWID,
            pid: proc.processIdentifier,
            appName: "BrowserChild",
            title: "Video",
            cgBounds: underCG,
            isOnScreen: true,
            backingScaleFactor: primary.backingScaleFactor
        )

        var profile = Profile.defaultProfile
        profile.presentationMode = .fullscreen
        profile.multiMonitorMode = .closest

        // 1. Fullscreen anti-occlusion (alphaValue = 0.999, panel.isOpaque = true, metalLayer.isOpaque = true):
        //    100% covers child window yet keeps WindowServer occlusionState.contains(.visible) == true!
        _ = controller.prepareOverlay(
            sourceWindow: sourceDescriptor,
            profile: profile,
            presentationOverride: .fullscreen,
            isNativeFullscreenSpace: false
        )
        controller.revealAfterFirstFrame()
        await flushAndSleep(milliseconds: 220)
        let fsSamples = await collectOcclusionSamples(forMilliseconds: 450)
        #expect(!fsSamples.isEmpty && fsSamples.allSatisfy { $0 == 1 }, "Fullscreen overlay occluded separate-process browser window! samples=\(fsSamples)")

        // 2. Windowed anti-occlusion (hasShadow = true, alphaValue = 0.999) covering 100% of child window:
        let winMetrics = controller.setPresentationMode(.windowed(initialScale: 1.5), multiMonitorMode: .closest)
        #expect(OverlayWindowController.overlayCoversSource(overlayRect: winMetrics.cgFrame, sourceRect: underCG))
        await flushAndSleep(milliseconds: 220)
        let winSamples = await collectOcclusionSamples(forMilliseconds: 450)
        #expect(!winSamples.isEmpty && winSamples.allSatisfy { $0 == 1 }, "Windowed overlay occluded separate-process browser window! samples=\(winSamples)")

        // 3. Negative control: VRR Fullscreen (`alphaValue = 1.0`) MUST occlude the covered child window
        //    (proving the overlay truly covers 100% of the child window in macOS WindowServer!),
        //    and turning VRR off MUST immediately recover visible == true!
        _ = controller.setPresentationMode(.fullscreen, multiMonitorMode: .closest)
        controller.isVRRDirectScanoutEnabled = true
        await flushAndSleep(milliseconds: 250)
        let vrrSamples = await collectOcclusionSamples(forMilliseconds: 350)
        #expect(!vrrSamples.isEmpty && vrrSamples.contains(0), "Negative control failed: opaque VRR alpha=1.0 should occlude covered window, got \(vrrSamples)")

        controller.isVRRDirectScanoutEnabled = false
        await flushAndSleep(milliseconds: 250)
        let recoveredSamples = await collectOcclusionSamples(forMilliseconds: 400)
        #expect(!recoveredSamples.isEmpty && recoveredSamples.allSatisfy { $0 == 1 }, "Separate-process browser window failed to recover non-occluded state after leaving VRR! samples=\(recoveredSamples)")
    }

    // MARK: - Bug #4: Windowed Coverage Across Primary & Negative-CG-Y External DELL

    @Test("Windowed computeOverlayCocoaFrame ALWAYS covers sourceCocoa across Primary and negative-CG-Y DELL displays regardless of stale width, small scale, tall height, or screen edges")
    @MainActor
    func windowedComputeOverlayAlwaysCoversSource() {
        let displays = Self.dualDisplays

        struct Case {
            let label: String
            let sourceCG: CGRect
            let mode: PresentationMode
            let lastWidth: CGFloat?
            let expectedDisplay: DisplayDescriptor
        }

        let cases: [Case] = [
            // Stale lastWindowedWidth smaller than source window on Primary
            Case(
                label: "Primary stale small lastWindowedWidth",
                sourceCG: CGRect(x: 200, y: 120, width: 1000, height: 700),
                mode: .windowed(),
                lastWidth: 500,
                expectedDisplay: Self.primaryRetina
            ),
            // Tall browser window exceeding old 0.95 height cap on Primary (950 > 982 * 0.95 = 932.9)
            Case(
                label: "Primary tall window exceeding 95% screen height",
                sourceCG: CGRect(x: 40, y: 20, width: 1400, height: 950),
                mode: .windowed(),
                lastWidth: nil,
                expectedDisplay: Self.primaryRetina
            ),
            // Tall browser window exceeding old 0.95 / 0.75 cap on external DELL 1280x720 (negative CG Y!)
            Case(
                label: "DELL negative-CG-Y tall window (1200x700 on 1280x720)",
                sourceCG: CGRect(x: 1552, y: -710, width: 1200, height: 700),
                mode: .windowed(),
                lastWidth: 640,
                expectedDisplay: Self.externalDELLNegativeCGY
            ),
            // Explicit width / initialScale smaller than source must never expose source edges
            Case(
                label: "DELL explicitWidth smaller than source",
                sourceCG: CGRect(x: 1620, y: -620, width: 900, height: 520),
                mode: .windowed(width: 480),
                lastWidth: nil,
                expectedDisplay: Self.externalDELLNegativeCGY
            ),
            Case(
                label: "Primary initialScale < 1.0 must never shrink below source",
                sourceCG: CGRect(x: 300, y: 200, width: 800, height: 500),
                mode: .windowed(initialScale: 0.5),
                lastWidth: nil,
                expectedDisplay: Self.primaryRetina
            ),
            // Source slammed into all 4 corners on Primary & DELL
            Case(
                label: "Primary top-left corner",
                sourceCG: CGRect(x: 0, y: 0, width: 640, height: 360),
                mode: .windowed(initialScale: 1.5),
                lastWidth: nil,
                expectedDisplay: Self.primaryRetina
            ),
            Case(
                label: "Primary bottom-right corner",
                sourceCG: CGRect(x: 872, y: 622, width: 640, height: 360),
                mode: .windowed(initialScale: 1.5),
                lastWidth: nil,
                expectedDisplay: Self.primaryRetina
            ),
            Case(
                label: "DELL negative-CG-Y top-right corner",
                sourceCG: CGRect(x: 2152, y: -720, width: 640, height: 360),
                mode: .windowed(initialScale: 1.4),
                lastWidth: nil,
                expectedDisplay: Self.externalDELLNegativeCGY
            ),
            Case(
                label: "DELL negative-CG-Y bottom-left corner",
                sourceCG: CGRect(x: 1512, y: -360, width: 640, height: 360),
                mode: .windowed(initialScale: 1.4),
                lastWidth: nil,
                expectedDisplay: Self.externalDELLNegativeCGY
            ),
            // Fractional sub-pixel source bounds
            Case(
                label: "Fractional sub-pixel source bounds",
                sourceCG: CGRect(x: 100.4, y: 200.7, width: 800.3, height: 500.4),
                mode: .windowed(initialScale: 1.0),
                lastWidth: nil,
                expectedDisplay: Self.primaryRetina
            )
        ]

        for tc in cases {
            let aspect = tc.sourceCG.width / tc.sourceCG.height
            let overlayCocoa = OverlayWindowController.computeOverlayCocoaFrame(
                sourceCGRect: tc.sourceCG,
                presentationMode: tc.mode,
                multiMonitorMode: .closest,
                displays: displays,
                aspectRatio: aspect,
                lastWindowedWidth: tc.lastWidth,
                applyAntiOcclusion: true
            )
            let sourceCocoa = ScreenGeometry.cgToCocoa(rect: tc.sourceCG, displays: displays)
            let hostCocoa = tc.expectedDisplay.cocoaFrame

            // 1. Must remain strictly inside the expected host display (never jumps displays!)
            #expect(overlayCocoa.minX >= hostCocoa.minX - 0.5, "\(tc.label): minX escaped display")
            #expect(overlayCocoa.maxX <= hostCocoa.maxX + 0.5, "\(tc.label): maxX escaped display")
            #expect(overlayCocoa.minY >= hostCocoa.minY - 0.5, "\(tc.label): minY escaped display")
            #expect(overlayCocoa.maxY <= hostCocoa.maxY + 0.5, "\(tc.label): maxY escaped display")

            // 2. Must NEVER be smaller than sourceCocoa and MUST 100% contain sourceCocoa (zero second window!)
            #expect(overlayCocoa.width >= sourceCocoa.width - 0.5, "\(tc.label): overlay width \(overlayCocoa.width) < source \(sourceCocoa.width)")
            #expect(overlayCocoa.height >= sourceCocoa.height - 0.5, "\(tc.label): overlay height \(overlayCocoa.height) < source \(sourceCocoa.height)")
            #expect(
                OverlayWindowController.overlayCoversSource(overlayRect: overlayCocoa, sourceRect: sourceCocoa, tolerance: 0.01),
                "\(tc.label): overlay \(overlayCocoa) did NOT completely cover source \(sourceCocoa)!"
            )

            // 3. Round-trip back to CG coordinates must also cover sourceCG!
            let overlayCG = ScreenGeometry.cocoaToCG(rect: overlayCocoa, displays: displays)
            #expect(
                OverlayWindowController.overlayCoversSource(overlayRect: overlayCG, sourceRect: tc.sourceCG, tolerance: 0.01),
                "\(tc.label): CG round-trip overlay \(overlayCG) did NOT cover sourceCG \(tc.sourceCG)!"
            )
        }
    }

    @Test("AX hidden source origin solver and menu-bar fallback keep source hidden underneath dragged windowed overlay on Primary & negative-CG-Y DELL")
    @MainActor
    func hiddenSourceOriginAndDragCoverage() {
        let displays = Self.dualDisplays

        // 1. Primary display with 38pt notch menu bar + 60pt Dock
        let primaryFullCG = Self.primaryRetina.cgBounds
        let primaryVisibleCG = CGRect(x: 0, y: 38, width: 1512, height: 884)
        let sourceSize = CGSize(width: 640, height: 360)

        // User drags 960x540 windowed overlay to arbitrary right-side spot
        let draggedPrimaryOverlayCG = CGRect(x: 500, y: 200, width: 960, height: 540)
        let hiddenPrimaryOrigin = OverlayWindowController.computeHiddenSourceWindowCGOrigin(
            sourceSize: sourceSize,
            overlayCGRect: draggedPrimaryOverlayCG,
            hostDisplayCGBounds: primaryFullCG,
            hostVisibleCGBounds: primaryVisibleCG
        )
        let hiddenPrimaryRect = CGRect(origin: hiddenPrimaryOrigin, size: sourceSize)
        #expect(OverlayWindowController.overlayCoversSource(overlayRect: draggedPrimaryOverlayCG, sourceRect: hiddenPrimaryRect, tolerance: 0.01))
        #expect(hiddenPrimaryRect.minY >= primaryVisibleCG.minY, "Must stay below menu bar")
        #expect(hiddenPrimaryRect.maxY <= primaryVisibleCG.maxY, "Must stay above Dock when room exists")

        // 2. External DELL negative-CG-Y display: CG (1512, -720, 1280, 720), 25pt menu bar -> visible y in [-695, 0]
        let dellFullCG = Self.externalDELLNegativeCGY.cgBounds
        let dellVisibleCG = CGRect(x: 1512, y: -695, width: 1280, height: 695)
        let draggedDELLOverlayCG = CGRect(x: 1700, y: -710, width: 960, height: 540)
        let hiddenDELLOrigin = OverlayWindowController.computeHiddenSourceWindowCGOrigin(
            sourceSize: sourceSize,
            overlayCGRect: draggedDELLOverlayCG,
            hostDisplayCGBounds: dellFullCG,
            hostVisibleCGBounds: dellVisibleCG
        )
        let hiddenDELLRect = CGRect(origin: hiddenDELLOrigin, size: sourceSize)
        #expect(OverlayWindowController.overlayCoversSource(overlayRect: draggedDELLOverlayCG, sourceRect: hiddenDELLRect, tolerance: 0.01))
        #expect(hiddenDELLRect.minY >= dellVisibleCG.minY, "DELL negative-CG-Y origin must respect menu bar at -695")
        #expect(hiddenDELLRect.maxY <= dellFullCG.maxY)

        // Verify Cocoa conversion of the DELL hidden source rect is also strictly covered!
        let draggedDELLOverlayCocoa = ScreenGeometry.cgToCocoa(rect: draggedDELLOverlayCG, displays: displays)
        let hiddenDELLCocoa = ScreenGeometry.cgToCocoa(rect: hiddenDELLRect, displays: displays)
        #expect(OverlayWindowController.overlayCoversSource(overlayRect: draggedDELLOverlayCocoa, sourceRect: hiddenDELLCocoa, tolerance: 0.01))

        // 3. Menu-bar clamp fallback: overlay dragged into menu bar with same height as source (800x500 at CG y=0)
        // macOS clamps source window down to CG y=38 -> ensureOverlayCoversSource shifts overlay flush over clamped source!
        let tightOverlayCG = CGRect(x: 200, y: 0, width: 800, height: 500)
        let clampedSourceCG = CGRect(x: 200, y: 38, width: 800, height: 500)
        let tightOverlayCocoa = ScreenGeometry.cgToCocoa(rect: tightOverlayCG, displays: displays)
        let clampedSourceCocoa = ScreenGeometry.cgToCocoa(rect: clampedSourceCG, displays: displays)
        let adjustedOverlayCocoa = OverlayWindowController.ensureOverlayCoversSource(
            overlayCocoaRect: tightOverlayCocoa,
            sourceCocoaRect: clampedSourceCocoa,
            hostScreenCocoa: Self.primaryRetina.cocoaFrame
        )
        #expect(OverlayWindowController.overlayCoversSource(overlayRect: adjustedOverlayCocoa, sourceRect: clampedSourceCocoa, tolerance: 0.01))
    }

    @Test("OverlayWindowController tracks external source move/resize in Windowed mode while suppressing self-reposition loops")
    @MainActor
    func windowedLiveGeometrySyncAndLoopSuppression() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on test host")
            return
        }
        _ = NSApplication.shared

        let controller = try OverlayWindowController(device: device)
        defer { controller.close() }

        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let primary = try #require(ScreenGeometry.primaryDisplay(in: displays))

        let initialSourceCG = CGRect(
            x: primary.cgBounds.minX + 120,
            y: primary.cgBounds.minY + 120,
            width: 640,
            height: 360
        )
        let sourceWin = WindowDescriptor(
            windowID: 55_123,
            pid: 9_999,
            appName: "WindowedTrackTest",
            title: "Test",
            cgBounds: initialSourceCG,
            backingScaleFactor: primary.backingScaleFactor
        )

        var profile = Profile.defaultProfile
        profile.presentationMode = .windowed(initialScale: 1.25)

        let initialMetrics = controller.prepareOverlay(
            sourceWindow: sourceWin,
            profile: profile,
            presentationOverride: .windowed(initialScale: 1.25),
            isNativeFullscreenSpace: false
        )
        let view = try #require(controller.overlayView)
        let panel = try #require(controller.panel)

        #expect(view.minimumWindowedWidth >= 640)
        #expect(view.minimumWindowedHeight >= 360)
        #expect(panel.hasShadow == true)
        #expect(OverlayWindowController.overlayCoversSource(overlayRect: initialMetrics.cgFrame, sourceRect: initialSourceCG))

        // 1. Self-reposition suppression (`repositionWindowedOverlay: false`) must NOT move the panel!
        let frameBeforeSelfMove = panel.frame
        let selfMovedSourceCG = CGRect(
            x: initialSourceCG.origin.x + 25,
            y: initialSourceCG.origin.y + 15,
            width: initialSourceCG.width,
            height: initialSourceCG.height
        )
        controller.updateSourceWindowGeometry(
            selfMovedSourceCG,
            windowID: sourceWin.windowID,
            repositionWindowedOverlay: false
        )
        #expect(panel.frame == frameBeforeSelfMove, "Self-reposition update must not cause overlay feedback jump")

        // 2. External source window move (`repositionWindowedOverlay: true`) MUST pull windowed overlay along!
        let externallyMovedCG = CGRect(
            x: primary.cgBounds.minX + 520,
            y: primary.cgBounds.minY + 340,
            width: 640,
            height: 360
        )
        controller.updateSourceWindowGeometry(
            externallyMovedCG,
            windowID: sourceWin.windowID,
            repositionWindowedOverlay: true
        )
        let movedMetrics = controller.currentDrawableMetrics()
        #expect(
            OverlayWindowController.overlayCoversSource(overlayRect: movedMetrics.cgFrame, sourceRect: externallyMovedCG),
            "Windowed overlay must follow externally moved source window so two separate windows never appear"
        )

        // 3. External source window enlargement MUST expand windowed overlay & minimum resize bounds!
        let enlargedCG = CGRect(
            x: primary.cgBounds.minX + 100,
            y: primary.cgBounds.minY + 100,
            width: min(1040, primary.cgBounds.width - 140),
            height: min(620, primary.cgBounds.height - 140)
        )
        controller.updateSourceWindowGeometry(
            enlargedCG,
            windowID: sourceWin.windowID,
            repositionWindowedOverlay: true
        )
        let enlargedMetrics = controller.currentDrawableMetrics()
        #expect(view.minimumWindowedWidth >= enlargedCG.width - 0.5)
        #expect(view.minimumWindowedHeight >= enlargedCG.height - 0.5)
        #expect(
            OverlayWindowController.overlayCoversSource(overlayRect: enlargedMetrics.cgFrame, sourceRect: enlargedCG),
            "Windowed overlay must expand when source window grows externally"
        )
    }
}
