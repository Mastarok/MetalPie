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

/// Returns a non-nil diagnostic reason ONLY when the host display is physically asleep or on the
/// macOS lock screen (where WindowServer pauses `CAMetalDisplayLink` vsync and marks every window
/// occluded regardless of MetalPie's overlay). Returns `nil` whenever the display is awake & unlocked.
private func hostDisplayUnavailableForLiveWindowServerReason() -> String? {
    let isAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    var isScreenLocked = false
    if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
       let locked = dict["CGSSessionScreenIsLocked"] as? NSNumber
    {
        isScreenLocked = locked.boolValue
    }
    if isAsleep || isScreenLocked {
        return "host main display is unavailable for live WindowServer compositor checks (asleep=\(isAsleep), screenLocked=\(isScreenLocked))"
    }
    return nil
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

        // 1. Reopen in Fullscreen non-VRR anti-occlusion mode and verify deterministic invariants
        //    (plus 200+ consecutive CAMetalDisplayLink callbacks whenever the host display is awake & unlocked).
        let hardwareSkipReason = hostDisplayUnavailableForLiveWindowServerReason()
        controller.isVRRDirectScanoutEnabled = false
        _ = controller.prepareOverlay(
            sourceWindow: sourceDescriptor,
            profile: profile,
            presentationOverride: .fullscreen,
            isNativeFullscreenSpace: false
        )
        #expect(panel.isOpaque == true)
        #expect(panel.backgroundColor == .black)
        #expect(view.metalLayer.isOpaque == true)
        #expect(view.metalLayer.framebufferOnly == true)
        #expect(view.metalLayer.cornerRadius == 0.0)
        #expect(view.metalLayer.masksToBounds == false)
        #expect(panel.hasShadow == false)
        #expect(abs(panel.alphaValue - OverlayWindowController.antiOcclusionAlphaValue) < 0.0001)

        controller.revealAfterFirstFrame()
        view.markDisplayLinkAttached()
        CATransaction.flush()

        let driver: TestDisplayLinkDriver?
        if let hardwareSkipReason {
            print("[WindowOcclusionAndCoverageTests] Skipping live CAMetalDisplayLink vsync count assertions: \(hardwareSkipReason)")
            driver = nil
        } else {
            let liveDriver = try TestDisplayLinkDriver(device: device, layer: view.metalLayer)
            liveDriver.start()
            driver = liveDriver
        }
        defer { driver?.stop() }

        if let driver {
            let fsDeadline = CFAbsoluteTimeGetCurrent() + 4.5
            while CFAbsoluteTimeGetCurrent() < fsDeadline && driver.callbackCount < 210 {
                await flushAndSleep(milliseconds: 50)
            }
            #expect(
                driver.callbackCount >= 200,
                "CAMetalDisplayLink stalled in Fullscreen anti-occlusion mode: only \(driver.callbackCount) callbacks (expected >= 200)"
            )
        }

        // 2. Live switch to Windowed mode (rounded native corners + shadow, metalLayer.isOpaque = true)
        //    and verify zero DisplayLink stall!
        let winMetrics = controller.setPresentationMode(.windowed(initialScale: 1.5), multiMonitorMode: .closest)
        #expect(panel.hasShadow == true)
        #expect(panel.isOpaque == false)
        #expect(panel.backgroundColor == .clear)
        #expect(view.metalLayer.isOpaque == true)
        #expect(view.metalLayer.cornerRadius == OverlayWindowController.windowedCornerRadius)
        #expect(view.metalLayer.masksToBounds == true)
        #expect(abs(panel.alphaValue - OverlayWindowController.antiOcclusionAlphaValue) < 0.0001)
        #expect(
            OverlayWindowController.overlayCoversSource(overlayRect: winMetrics.cgFrame, sourceRect: sourceCG),
            "Windowed overlay must completely cover source window"
        )

        if let driver {
            driver.resetCount()
            let winDeadline = CFAbsoluteTimeGetCurrent() + 3.0
            while CFAbsoluteTimeGetCurrent() < winDeadline && driver.callbackCount < 110 {
                await flushAndSleep(milliseconds: 50)
            }
            #expect(
                driver.callbackCount >= 100,
                "CAMetalDisplayLink stalled after Fullscreen -> Windowed transition: only \(driver.callbackCount) callbacks"
            )
        }

        // 3. Close & reopen back into Fullscreen non-VRR and confirm deterministic invariants + DisplayLink resume!
        controller.close()
        await flushAndSleep(milliseconds: 80)
        _ = controller.prepareOverlay(
            sourceWindow: sourceDescriptor,
            profile: profile,
            presentationOverride: .fullscreen,
            isNativeFullscreenSpace: false
        )
        #expect(panel.isOpaque == true)
        #expect(panel.backgroundColor == .black)
        #expect(panel.hasShadow == false)
        #expect(view.metalLayer.isOpaque == true)
        #expect(view.metalLayer.cornerRadius == 0.0)
        #expect(view.metalLayer.masksToBounds == false)
        #expect(abs(panel.alphaValue - OverlayWindowController.antiOcclusionAlphaValue) < 0.0001)

        controller.revealAfterFirstFrame()
        if let driver {
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
        let underLevel = OverlayWindowController.windowedOverlayLevel.rawValue - 2

        if let hardwareSkipReason = hostDisplayUnavailableForLiveWindowServerReason() {
            print("[WindowOcclusionAndCoverageTests] Skipping live cross-process WindowServer occlusion sampling: \(hardwareSkipReason)")
            // Still verify all deterministic anti-occlusion, shadow, corner-radius, and VRR panel invariants!
            let controller = try OverlayWindowController(device: device)
            defer { controller.close() }

            let sourceDescriptor = WindowDescriptor(
                windowID: 77_202,
                pid: ProcessInfo.processInfo.processIdentifier,
                appName: "BrowserChild",
                title: "Video",
                cgBounds: underCG,
                isOnScreen: true,
                backingScaleFactor: primary.backingScaleFactor
            )
            var profile = Profile.defaultProfile
            profile.presentationMode = .fullscreen
            profile.multiMonitorMode = .closest

            _ = controller.prepareOverlay(
                sourceWindow: sourceDescriptor,
                profile: profile,
                presentationOverride: .fullscreen,
                isNativeFullscreenSpace: false
            )
            let panel = try #require(controller.panel)
            let view = try #require(controller.overlayView)
            #expect(panel.isOpaque == true)
            #expect(panel.hasShadow == false)
            #expect(view.metalLayer.isOpaque == true)
            #expect(abs(panel.alphaValue - OverlayWindowController.antiOcclusionAlphaValue) < 0.0001)

            let winMetrics = controller.setPresentationMode(.windowed(initialScale: 1.5), multiMonitorMode: .closest)
            #expect(panel.isOpaque == false)
            #expect(panel.backgroundColor == .clear)
            #expect(panel.hasShadow == true)
            #expect(view.metalLayer.isOpaque == true)
            #expect(view.metalLayer.cornerRadius == OverlayWindowController.windowedCornerRadius)
            #expect(view.metalLayer.masksToBounds == true)
            #expect(abs(panel.alphaValue - OverlayWindowController.antiOcclusionAlphaValue) < 0.0001)
            #expect(OverlayWindowController.overlayCoversSource(overlayRect: winMetrics.cgFrame, sourceRect: underCG))

            _ = controller.setPresentationMode(.fullscreen, multiMonitorMode: .closest)
            controller.isVRRDirectScanoutEnabled = true
            #expect(panel.isOpaque == true)
            #expect(panel.hasShadow == false)
            #expect(abs(panel.alphaValue - 1.0) < 0.0001)

            controller.isVRRDirectScanoutEnabled = false
            #expect(panel.isOpaque == true)
            #expect(abs(panel.alphaValue - OverlayWindowController.antiOcclusionAlphaValue) < 0.0001)
            return
        }

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

        // 4. External source window SHRINK (locked inward edge drag!) MUST shrink windowed overlay
        //    proportionally instead of remaining stuck at stale enlarged `lastWindowedWidth`!
        let widthBeforeShrink = enlargedMetrics.cocoaFrame.width
        let shrunkCG = CGRect(
            x: primary.cgBounds.minX + 160,
            y: primary.cgBounds.minY + 160,
            width: 520,
            height: 310
        )
        controller.updateSourceWindowGeometry(
            shrunkCG,
            windowID: sourceWin.windowID,
            repositionWindowedOverlay: true
        )
        let shrunkMetrics = controller.currentDrawableMetrics()
        #expect(
            shrunkMetrics.cocoaFrame.width < widthBeforeShrink - 100,
            "Locked windowed overlay must shrink proportionally when source window shrinks inward (before=\(widthBeforeShrink), after=\(shrunkMetrics.cocoaFrame.width))"
        )
        #expect(
            OverlayWindowController.overlayCoversSource(overlayRect: shrunkMetrics.cgFrame, sourceRect: shrunkCG),
            "Shrunk windowed overlay must still completely cover the shrunk source window"
        )
        #expect(
            abs((controller.lastWindowedWidth ?? 0) - shrunkMetrics.cocoaFrame.width) < 1.0,
            "lastWindowedWidth must update to the new shrunk overlay width"
        )
    }

    // MARK: - Bug #5: Windowed Inward & Outward Resize (Unlocked Overlay Drag + Locked Source Shrink/Grow)

    @Test("Windowed resize works smoothly BOTH inward and outward in unlocked overlay drag and locked source-window modes")
    @MainActor
    func windowedResizeInwardAndOutward() throws {
        let displays = Self.dualDisplays

        // 1. Unlocked interactive resize (`MetalOverlayView.computeInteractiveResizeFrame`):
        //    Dragging inward shrinks below original source window size down to 320x180 (preserving aspect ratio),
        //    and dragging outward expands smoothly up to screen bounds!
        let start = CGRect(x: 300, y: 200, width: 960, height: 540)
        let aspect: CGFloat = 16.0 / 9.0
        let screenMax = Self.primaryRetina.cocoaFrame.size

        // Inward drag from right edge (-480pt -> 480x270, well below e.g. 640x360 source!)
        let inwardRight = MetalOverlayView.computeInteractiveResizeFrame(
            startFrame: start,
            edges: [.right],
            delta: CGVector(dx: -480, dy: 0),
            aspectRatio: aspect,
            minWidth: OverlayWindowController.absoluteMinimumWindowedWidth,
            minHeight: OverlayWindowController.absoluteMinimumWindowedHeight,
            maxSize: screenMax
        )
        #expect(inwardRight.width == 480)
        #expect(inwardRight.height == 270)
        #expect(inwardRight.minX == start.minX)

        // Deep inward drag from top-left corner clamps cleanly to 320x180 while pinning bottom-right anchor!
        let inwardMinClamp = MetalOverlayView.computeInteractiveResizeFrame(
            startFrame: start,
            edges: [.left, .top],
            delta: CGVector(dx: 800, dy: -500),
            aspectRatio: aspect,
            minWidth: OverlayWindowController.absoluteMinimumWindowedWidth,
            minHeight: OverlayWindowController.absoluteMinimumWindowedHeight,
            maxSize: screenMax
        )
        #expect(inwardMinClamp.width == 320)
        #expect(inwardMinClamp.height == 180)
        #expect(inwardMinClamp.maxX == start.maxX)

        // Outward drag from bottom-right corner expands smoothly while pinning top-left anchor!
        let outwardBR = MetalOverlayView.computeInteractiveResizeFrame(
            startFrame: start,
            edges: [.right, .bottom],
            delta: CGVector(dx: 320, dy: -180),
            aspectRatio: aspect,
            minWidth: OverlayWindowController.absoluteMinimumWindowedWidth,
            minHeight: OverlayWindowController.absoluteMinimumWindowedHeight,
            maxSize: screenMax
        )
        #expect(outwardBR.width == 1280)
        #expect(outwardBR.height == 720)
        #expect(outwardBR.minX == start.minX)
        #expect(outwardBR.maxY == start.maxY)

        // Verify `OverlayWindowController.allowInwardResizeBelowSource` unlocks 320x180 minimum on live view.
        if let device = MTLCreateSystemDefaultDevice() {
            let controller = try OverlayWindowController(device: device)
            defer { controller.close() }
            let src = WindowDescriptor(
                windowID: 88_001,
                pid: 4_242,
                appName: "ResizableApp",
                title: "Doc",
                cgBounds: CGRect(x: 100, y: 100, width: 800, height: 450),
                backingScaleFactor: 2.0
            )
            controller.allowInwardResizeBelowSource = true
            _ = controller.prepareOverlay(
                sourceWindow: src,
                profile: .defaultProfile,
                presentationOverride: .windowed(initialScale: 1.25),
                isNativeFullscreenSpace: false
            )
            let view = try #require(controller.overlayView)
            #expect(view.minimumWindowedWidth == OverlayWindowController.absoluteMinimumWindowedWidth)
            #expect(view.minimumWindowedHeight == OverlayWindowController.absoluteMinimumWindowedHeight)

            controller.allowInwardResizeBelowSource = false
            #expect(view.minimumWindowedWidth >= 800)
            #expect(view.minimumWindowedHeight >= 450)
        }

        // 2. Locked proportional resize (`computeProportionalResizedWindowedCocoaFrame`) on Primary AND negative-CG-Y DELL:
        //    Source 640x360 with 1.5x overlay (960x540):
        //    - Shrink source inward to 480x270 -> overlay shrinks proportionally to 720x405!
        //    - Grow source outward to 800x450 -> overlay grows proportionally to 1200x675!
        let prevSourcePrimary = CGRect(x: 200, y: 200, width: 640, height: 360)
        let prevOverlayCocoaPrimary = CGRect(x: 40, y: 332, width: 960, height: 540)

        let shrunkSourcePrimary = CGRect(x: 200, y: 200, width: 480, height: 270)
        let shrunkOverlayCocoa = OverlayWindowController.computeProportionalResizedWindowedCocoaFrame(
            previousSourceCGRect: prevSourcePrimary,
            newSourceCGRect: shrunkSourcePrimary,
            currentOverlayCocoaFrame: prevOverlayCocoaPrimary,
            displays: displays
        )
        #expect(abs(shrunkOverlayCocoa.width - 720) <= 1.0)
        #expect(abs(shrunkOverlayCocoa.height - 405) <= 1.0)
        #expect(OverlayWindowController.overlayCoversSource(
            overlayRect: ScreenGeometry.cocoaToCG(rect: shrunkOverlayCocoa, displays: displays),
            sourceRect: shrunkSourcePrimary
        ))

        let grownSourcePrimary = CGRect(x: 200, y: 200, width: 800, height: 450)
        let grownOverlayCocoa = OverlayWindowController.computeProportionalResizedWindowedCocoaFrame(
            previousSourceCGRect: shrunkSourcePrimary,
            newSourceCGRect: grownSourcePrimary,
            currentOverlayCocoaFrame: shrunkOverlayCocoa,
            displays: displays
        )
        #expect(abs(grownOverlayCocoa.width - 1200) <= 1.0)
        #expect(abs(grownOverlayCocoa.height - 675) <= 1.0)
        #expect(OverlayWindowController.overlayCoversSource(
            overlayRect: ScreenGeometry.cocoaToCG(rect: grownOverlayCocoa, displays: displays),
            sourceRect: grownSourcePrimary
        ))

        // Negative-CG-Y DELL display inward shrink (640x360 @ 1.5x = 960x540 -> 440x248 -> ~660x372)
        let prevSourceDELL = CGRect(x: 1700, y: -560, width: 640, height: 360)
        let prevOverlayDELL = CGRect(x: 1600, y: 1100, width: 960, height: 540)
        let shrunkSourceDELL = CGRect(x: 1700, y: -560, width: 440, height: 248)
        let shrunkOverlayDELL = OverlayWindowController.computeProportionalResizedWindowedCocoaFrame(
            previousSourceCGRect: prevSourceDELL,
            newSourceCGRect: shrunkSourceDELL,
            currentOverlayCocoaFrame: prevOverlayDELL,
            displays: displays
        )
        #expect(shrunkOverlayDELL.width < 700 && shrunkOverlayDELL.width >= 655)
        #expect(shrunkOverlayDELL.minX >= Self.externalDELLNegativeCGY.cocoaFrame.minX - 0.5)
        #expect(shrunkOverlayDELL.maxX <= Self.externalDELLNegativeCGY.cocoaFrame.maxX + 0.5)
        #expect(OverlayWindowController.overlayCoversSource(
            overlayRect: ScreenGeometry.cocoaToCG(rect: shrunkOverlayDELL, displays: displays),
            sourceRect: shrunkSourceDELL
        ))
    }

    // MARK: - Bug #2 & Bug #4A: Notch-Safe Toolbar Placement & Shadow-Padded Interactive Chrome Rects

    @Test("Notch-safe toolbar stays strictly below Menu Bar & MacBook Pro notch and interactive chrome rects exclude transparent shadow padding")
    func notchSafeToolbarAndInteractiveChromeRects() {
        let displays = Self.dualDisplays

        // 1. Primary MacBook Pro Retina with 33pt Menu Bar / notch strip (`visibleFrame.maxY = 949`, `frame.maxY = 982`)
        let primaryFullscreenOverlay = CGRect(x: 0, y: 1, width: 1512, height: 981)
        let primaryVisibleScreen = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let primaryToolbarVisible = OverlayChromeGeometry.computeVisibleToolbarCocoaFrame(
            for: primaryFullscreenOverlay,
            hostScreenVisibleFrame: primaryVisibleScreen
        )
        #expect(
            primaryToolbarVisible.maxY <= primaryVisibleScreen.maxY - OverlayChromeGeometry.notchSafeTopMargin + 0.5,
            "Toolbar must sit cleanly below MacBook Pro notch / Menu Bar (maxY=\(primaryToolbarVisible.maxY), visibleMaxY=\(primaryVisibleScreen.maxY))"
        )
        #expect(primaryToolbarVisible.size == OverlayChromeGeometry.defaultToolbarSize)
        #expect(abs(primaryToolbarVisible.midX - primaryFullscreenOverlay.midX) <= 1.0)

        // 2. External DELL P2422H (negative CG Y; Cocoa frame 982..1702, 30pt Menu Bar -> visible maxY = 1672)
        let dellFullscreenOverlay = CGRect(x: 1512, y: 983, width: 1280, height: 719)
        let dellVisibleScreen = CGRect(x: 1512, y: 982, width: 1280, height: 690)
        let dellToolbarVisible = OverlayChromeGeometry.computeVisibleToolbarCocoaFrame(
            for: dellFullscreenOverlay,
            hostScreenVisibleFrame: dellVisibleScreen
        )
        #expect(dellToolbarVisible.maxY <= dellVisibleScreen.maxY - OverlayChromeGeometry.notchSafeTopMargin + 0.5)
        #expect(abs(dellToolbarVisible.midX - dellFullscreenOverlay.midX) <= 1.0)

        // 3. Windowed overlay well below Menu Bar keeps standard 10pt top margin inside the window
        let windowedOverlay = CGRect(x: 200, y: 120, width: 960, height: 540)
        let windowedToolbarVisible = OverlayChromeGeometry.computeVisibleToolbarCocoaFrame(
            for: windowedOverlay,
            hostScreenVisibleFrame: primaryVisibleScreen
        )
        #expect(abs(windowedToolbarVisible.maxY - (windowedOverlay.maxY - OverlayChromeGeometry.defaultTopMargin)) <= 1.0)

        // 4. Shadow padding round-trip & interactive CG rect extraction (MUST exclude 20pt transparent shadow bleed!)
        let pad = OverlayChromeGeometry.defaultShadowPadding
        let toolbarPanelCocoa = OverlayChromeGeometry.panelFrame(fromVisibleFrame: primaryToolbarVisible)
        #expect(toolbarPanelCocoa.width == primaryToolbarVisible.width + pad * 2)
        #expect(toolbarPanelCocoa.height == primaryToolbarVisible.height + pad * 2)

        let hudVisibleCocoa = CGRect(x: 16, y: 720, width: 296, height: 150)
        let hudPanelCocoa = OverlayChromeGeometry.panelFrame(fromVisibleFrame: hudVisibleCocoa)

        let activeCGRects = OverlayChromeGeometry.interactiveChromeCGRects(
            toolbarPanelCocoaFrame: toolbarPanelCocoa,
            toolbarIsInteractive: true,
            hudPanelCocoaFrame: hudPanelCocoa,
            hudIsVisible: true,
            displays: displays
        )
        #expect(activeCGRects.count == 2)
        let expectedToolbarCG = ScreenGeometry.cocoaToCG(rect: primaryToolbarVisible, displays: displays)
        let expectedHUDCG = ScreenGeometry.cocoaToCG(rect: hudVisibleCocoa, displays: displays)
        #expect(activeCGRects[0] == expectedToolbarCG)
        #expect(activeCGRects[1] == expectedHUDCG)

        // Point inside transparent outer shadow margin MUST NOT be inside the interactive CG rect!
        let shadowMarginPoint = CGPoint(x: expectedToolbarCG.minX - 10, y: expectedToolbarCG.midY)
        #expect(!activeCGRects[0].contains(shadowMarginPoint))
        #expect(ScreenGeometry.cocoaToCG(rect: toolbarPanelCocoa, displays: displays).contains(shadowMarginPoint))

        // Auto-hidden toolbar (`toolbarIsInteractive: false`) must NOT be included in interactive rects
        let hiddenToolbarRects = OverlayChromeGeometry.interactiveChromeCGRects(
            toolbarPanelCocoaFrame: toolbarPanelCocoa,
            toolbarIsInteractive: false,
            hudPanelCocoaFrame: hudPanelCocoa,
            hudIsVisible: false,
            displays: displays
        )
        #expect(hiddenToolbarRects.isEmpty)
    }

    // MARK: - Bug #2 & Bug #3: Fullscreen vs Windowed Levels, Menu-Bar Clamping & Context-Menu Dedup Boost

    @Test("Fullscreen level (98) sits strictly above macOS Menu Bar/Status Bar & below NSMenu (101); Windowed level (21) sits below Menu Bar; popup boost rises cleanly to 102/103/104")
    @MainActor
    func overlayLevelsAndPopupMenuDedupClassifier() throws {
        let displays = Self.dualDisplays
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusBarLevel = Int(CGWindowLevelForKey(.statusWindow))
        let popUpLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

        // 1. Fullscreen overlay (98), cursor (+1 = 99), and toolbar/HUD (+2 = 100) must sit
        //    strictly ABOVE macOS Menu Bar (24) & Status Bar (25) — ZERO Menu Bar bleed-through —
        //    and ALL strictly BELOW popUpMenuWindow (101)!
        let fsBase = OverlayWindowController.fullscreenOverlayLevel.rawValue
        #expect(fsBase == popUpLayer - 3)
        #expect(OverlayWindowController.normalOverlayLevel == OverlayWindowController.fullscreenOverlayLevel)
        #expect(fsBase > menuBarLevel)
        #expect(fsBase > statusBarLevel)
        #expect(fsBase + 1 < popUpLayer, "Fullscreen cursor level (99) must sit strictly below popUpMenuWindow (101)")
        #expect(fsBase + 2 < popUpLayer, "Fullscreen toolbar/HUD level (100) must sit strictly below popUpMenuWindow (101)")

        // 2. Windowed overlay (21), cursor (+1 = 22), and toolbar/HUD (+2 = 23) must sit strictly
        //    above Dock (20) and ALL strictly BELOW macOS Menu Bar (24) & Status Bar (25)!
        let winBase = OverlayWindowController.windowedOverlayLevel.rawValue
        #expect(winBase == menuBarLevel - 3)
        #expect(winBase > dockLevel)
        #expect(winBase + 1 < menuBarLevel)
        #expect(winBase + 2 < menuBarLevel)
        #expect(winBase + 2 < statusBarLevel)

        // 3. Popup boost rises cleanly to 102 (cursor 103, toolbar/HUD 104); native FS = 19; VRR = 100.
        let boostBase = OverlayWindowController.popupMenuBoostOverlayLevel.rawValue
        #expect(boostBase == popUpLayer + 1)
        #expect(boostBase + 1 == popUpLayer + 2)
        #expect(boostBase + 2 == popUpLayer + 3)
        #expect(OverlayWindowController.nativeFullscreenOverlayLevel.rawValue == 19)
        #expect(OverlayWindowController.vrrFullscreenOverlayLevel.rawValue == popUpLayer - 1)

        let targetPID: Int32 = 4242
        let sourceWindow = CGRect(x: 100, y: 120, width: 800, height: 500)
        let mbHeights: [CGDirectDisplayID: CGFloat] = [1: 33, 2: 30]

        // 4. In-window right-click NSMenu (layer 101, intersects source, pointer inside window) -> BOOST!
        let contextMenu = PopupMenuWindowSnapshot(
            windowID: 9001,
            pid: targetPID,
            layer: popUpLayer,
            bounds: CGRect(x: 320, y: 280, width: 220, height: 240)
        )
        let evalContext = OverlayWindowController.evaluatePopupMenuLevelBoost(
            popupWindows: [contextMenu],
            targetPID: targetPID,
            sourceCGRect: sourceWindow,
            displays: displays,
            pointerCGPosition: CGPoint(x: 320, y: 280),
            menuBarHeightByDisplayID: mbHeights
        )
        #expect(evalContext.shouldBoostAbovePopupMenus == true)
        #expect(evalContext.isMenuBarDropdownActive == false)

        // 5. Submenu opening slightly outside source while already boosted -> stays boosted!
        let submenu = PopupMenuWindowSnapshot(
            windowID: 9002,
            pid: targetPID,
            layer: popUpLayer,
            bounds: CGRect(x: 910, y: 300, width: 180, height: 140)
        )
        let evalSub = OverlayWindowController.evaluatePopupMenuLevelBoost(
            popupWindows: [contextMenu, submenu],
            targetPID: targetPID,
            sourceCGRect: sourceWindow,
            displays: displays,
            pointerCGPosition: CGPoint(x: 920, y: 310),
            menuBarHeightByDisplayID: mbHeights,
            wasBoosted: true
        )
        #expect(evalSub.shouldBoostAbovePopupMenus == true)

        // 6. Menu closes -> immediately drops boost!
        let evalClosed = OverlayWindowController.evaluatePopupMenuLevelBoost(
            popupWindows: [],
            targetPID: targetPID,
            sourceCGRect: sourceWindow,
            displays: displays,
            wasBoosted: true
        )
        #expect(evalClosed.shouldBoostAbovePopupMenus == false)
        #expect(evalClosed.isMenuBarDropdownActive == false)

        // 7. macOS top Menu Bar dropdown (anchored at y=33 on primary, pointer in menu bar, even over fullscreen source!)
        //    MUST NOT boost so macOS Menu Bar dropdown stays visible above OverlayPanel!
        let fullscreenSource = Self.primaryRetina.cgBounds
        let menuBarDropdown = PopupMenuWindowSnapshot(
            windowID: 9003,
            pid: targetPID,
            layer: popUpLayer,
            bounds: CGRect(x: 120, y: 33, width: 240, height: 320)
        )
        let evalMenuBar = OverlayWindowController.evaluatePopupMenuLevelBoost(
            popupWindows: [menuBarDropdown],
            targetPID: targetPID,
            sourceCGRect: fullscreenSource,
            displays: displays,
            pointerCGPosition: CGPoint(x: 140, y: 16),
            menuBarHeightByDisplayID: mbHeights
        )
        #expect(evalMenuBar.shouldBoostAbovePopupMenus == false)
        #expect(evalMenuBar.isMenuBarDropdownActive == true)

        // 8. External DELL negative-CG-Y top Menu Bar dropdown (y = -720 + 30 = -690) MUST NOT boost!
        let dellMenuBarDropdown = PopupMenuWindowSnapshot(
            windowID: 9004,
            pid: targetPID,
            layer: popUpLayer,
            bounds: CGRect(x: 1620, y: -690, width: 220, height: 260)
        )
        let evalDELLMenuBar = OverlayWindowController.evaluatePopupMenuLevelBoost(
            popupWindows: [dellMenuBarDropdown],
            targetPID: targetPID,
            sourceCGRect: Self.externalDELLNegativeCGY.cgBounds,
            displays: displays,
            pointerCGPosition: CGPoint(x: 1640, y: -705),
            menuBarHeightByDisplayID: mbHeights
        )
        #expect(evalDELLMenuBar.shouldBoostAbovePopupMenus == false)
        #expect(evalDELLMenuBar.isMenuBarDropdownActive == true)

        // 9. Live OverlayWindowController cleanly separates Fullscreen (98), Windowed (21),
        //    Native FS (19), VRR (100), and popup-menu boost (102) while firing `onOverlayLevelChanged`!
        if let device = MTLCreateSystemDefaultDevice() {
            let controller = try OverlayWindowController(device: device)
            defer { controller.close() }
            var observedLevels: [Int] = []
            controller.onOverlayLevelChanged = { observedLevels.append($0.rawValue) }
            let src = WindowDescriptor(
                windowID: 88_002,
                pid: targetPID,
                appName: "FinderSim",
                title: "Desktop",
                cgBounds: sourceWindow,
                backingScaleFactor: 2.0
            )

            // Fullscreen non-native-FS -> level 98 -> boost 102 -> restore 98
            _ = controller.prepareOverlay(
                sourceWindow: src,
                profile: .defaultProfile,
                presentationOverride: .fullscreen,
                isNativeFullscreenSpace: false
            )
            let panel = try #require(controller.panel)
            #expect(panel.level == OverlayWindowController.fullscreenOverlayLevel)
            controller.setPopupMenuLevelBoost(true)
            #expect(panel.level == OverlayWindowController.popupMenuBoostOverlayLevel)
            controller.setPopupMenuLevelBoost(false)
            #expect(panel.level == OverlayWindowController.fullscreenOverlayLevel)
            #expect(observedLevels.suffix(2) == [
                OverlayWindowController.popupMenuBoostOverlayLevel.rawValue,
                OverlayWindowController.fullscreenOverlayLevel.rawValue
            ])

            // Windowed -> level 21 -> boost 102 -> restore 21
            _ = controller.setPresentationMode(.windowed(initialScale: 1.25), multiMonitorMode: .closest)
            #expect(panel.level == OverlayWindowController.windowedOverlayLevel)
            controller.setPopupMenuLevelBoost(true)
            #expect(panel.level == OverlayWindowController.popupMenuBoostOverlayLevel)
            controller.setPopupMenuLevelBoost(false)
            #expect(panel.level == OverlayWindowController.windowedOverlayLevel)
            #expect(observedLevels.suffix(2) == [
                OverlayWindowController.popupMenuBoostOverlayLevel.rawValue,
                OverlayWindowController.windowedOverlayLevel.rawValue
            ])

            // Native Fullscreen Space -> level 19 -> exiting back to desktop window restores level 98 & activation policy!
            let originalPolicy = NSApplication.shared.activationPolicy()
            _ = controller.prepareOverlay(
                sourceWindow: src,
                profile: .defaultProfile,
                presentationOverride: .fullscreen,
                isNativeFullscreenSpace: true
            )
            #expect(panel.level == OverlayWindowController.nativeFullscreenOverlayLevel)
            #expect(controller.isCoveringNativeFullscreenSpace == true)
            #expect(NSApplication.shared.activationPolicy() == .accessory)

            // Smooth fullscreen video exit (`W2` -> `W1`): level transitions 19 -> 98 and policy restores!
            _ = controller.prepareOverlay(
                sourceWindow: src,
                profile: .defaultProfile,
                presentationOverride: .fullscreen,
                isNativeFullscreenSpace: false
            )
            #expect(panel.level == OverlayWindowController.fullscreenOverlayLevel)
            #expect(controller.isCoveringNativeFullscreenSpace == false)
            #expect(NSApplication.shared.activationPolicy() == originalPolicy)

            // VRR Direct-Scanout Fullscreen -> level 100
            controller.isVRRDirectScanoutEnabled = true
            #expect(panel.level == OverlayWindowController.vrrFullscreenOverlayLevel)
            controller.isVRRDirectScanoutEnabled = false
            #expect(panel.level == OverlayWindowController.fullscreenOverlayLevel)
        }
    }

    @Test("Windowed overlay frame clamps strictly inside host visibleFrame (never sliding behind macOS Menu Bar)")
    @MainActor
    func windowedFrameClampsStrictlyInsideVisibleFrame() throws {
        let displays = Self.dualDisplays

        // 1. Primary Retina (0, 0, 1512, 982) with 33pt top Menu Bar -> visibleFrame (0, 0, 1512, 949)
        let primaryVisibleNoDock = CGRect(x: 0, y: 0, width: 1512, height: 949)
        // Source sits flush below Menu Bar at CG y=33 (Cocoa maxY=949), 1.6x scale would expand above 949 if unclamped!
        let primaryTopSourceCG = CGRect(x: 200, y: 33, width: 700, height: 420)
        let primaryWindowed = OverlayWindowController.computeOverlayCocoaFrame(
            sourceCGRect: primaryTopSourceCG,
            presentationMode: .windowed(initialScale: 1.6),
            multiMonitorMode: .closest,
            displays: displays,
            aspectRatio: 700.0 / 420.0,
            hostVisibleCocoaFrame: primaryVisibleNoDock
        )
        #expect(primaryWindowed.maxY <= primaryVisibleNoDock.maxY + 0.01, "Windowed overlay maxY \(primaryWindowed.maxY) slid into Menu Bar above \(primaryVisibleNoDock.maxY)")
        #expect(primaryWindowed.minY >= primaryVisibleNoDock.minY - 0.01)
        #expect(OverlayWindowController.overlayCoversSource(
            overlayRect: primaryWindowed,
            sourceRect: ScreenGeometry.cgToCocoa(rect: primaryTopSourceCG, displays: displays)
        ))

        // 2. Primary Retina with 38pt notch Menu Bar + 60pt Dock -> visibleFrame (0, 60, 1512, 884)
        let primaryVisibleWithDock = CGRect(x: 0, y: 60, width: 1512, height: 884)
        let tallWindowSourceCG = CGRect(x: 80, y: 40, width: 1200, height: 820)
        let clampedWithDock = OverlayWindowController.computeOverlayCocoaFrame(
            sourceCGRect: tallWindowSourceCG,
            presentationMode: .windowed(),
            multiMonitorMode: .closest,
            displays: displays,
            aspectRatio: 1200.0 / 820.0,
            hostVisibleCocoaFrame: primaryVisibleWithDock
        )
        #expect(clampedWithDock.maxY <= primaryVisibleWithDock.maxY + 0.01)
        #expect(clampedWithDock.minY >= primaryVisibleWithDock.minY - 0.01)
        #expect(clampedWithDock.height <= primaryVisibleWithDock.height + 0.01)

        // 3. External DELL (negative CG Y; Cocoa 982..1702, 30pt Menu Bar -> visibleFrame 982..1672)
        let dellVisible = CGRect(x: 1512, y: 982, width: 1280, height: 690)
        let dellTopSourceCG = CGRect(x: 1620, y: -690, width: 640, height: 360)
        let dellWindowed = OverlayWindowController.computeOverlayCocoaFrame(
            sourceCGRect: dellTopSourceCG,
            presentationMode: .windowed(initialScale: 1.5),
            multiMonitorMode: .closest,
            displays: displays,
            aspectRatio: 16.0 / 9.0,
            hostVisibleCocoaFrame: dellVisible
        )
        #expect(dellWindowed.maxY <= dellVisible.maxY + 0.01, "DELL windowed overlay maxY \(dellWindowed.maxY) slid into Menu Bar above \(dellVisible.maxY)")
        #expect(dellWindowed.minY >= dellVisible.minY - 0.01)
        #expect(OverlayWindowController.overlayCoversSource(
            overlayRect: dellWindowed,
            sourceRect: ScreenGeometry.cgToCocoa(rect: dellTopSourceCG, displays: displays)
        ))

        // 4. Proportional resize growth near the top edge MUST also stay strictly inside `visibleFrame`!
        let prevSourceCG = CGRect(x: 200, y: 33, width: 640, height: 360)
        let prevOverlayCocoa = CGRect(x: 40, y: 409, width: 960, height: 540) // maxY = 949
        let grownSourceCG = CGRect(x: 200, y: 33, width: 800, height: 450)
        let grownOverlayCocoa = OverlayWindowController.computeProportionalResizedWindowedCocoaFrame(
            previousSourceCGRect: prevSourceCG,
            newSourceCGRect: grownSourceCG,
            currentOverlayCocoaFrame: prevOverlayCocoa,
            displays: displays,
            hostVisibleCocoaFrame: primaryVisibleNoDock
        )
        #expect(grownOverlayCocoa.maxY <= primaryVisibleNoDock.maxY + 0.01)
        #expect(grownOverlayCocoa.minY >= primaryVisibleNoDock.minY - 0.01)

        // 5. Live OverlayWindowController Windowed preparation respects the host NSScreen's visibleFrame!
        if let device = MTLCreateSystemDefaultDevice(),
           let primaryScreen = NSScreen.screens.first(where: { abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5 }) ?? NSScreen.main
        {
            let liveDisplays = WindowEnumerator.enumerateDisplaysOnMain()
            let topInset = max(0, primaryScreen.frame.maxY - primaryScreen.visibleFrame.maxY)
            let liveSourceCG = CGRect(
                x: primaryScreen.visibleFrame.minX + 120,
                y: topInset + 4,
                width: min(640, primaryScreen.visibleFrame.width - 240),
                height: min(360, primaryScreen.visibleFrame.height - 80)
            )
            let controller = try OverlayWindowController(device: device)
            defer { controller.close() }
            let src = WindowDescriptor(
                windowID: 88_009,
                pid: 4_321,
                appName: "BrowserTopEdge",
                title: "Top",
                cgBounds: liveSourceCG,
                backingScaleFactor: Double(primaryScreen.backingScaleFactor)
            )
            let metrics = controller.prepareOverlay(
                sourceWindow: src,
                profile: .defaultProfile,
                presentationOverride: .windowed(initialScale: 1.75),
                isNativeFullscreenSpace: false
            )
            let panel = try #require(controller.panel)
            #expect(panel.level == OverlayWindowController.windowedOverlayLevel)
            #expect(panel.level.rawValue < Int(CGWindowLevelForKey(.mainMenuWindow)))
            #expect(
                metrics.cocoaFrame.maxY <= primaryScreen.visibleFrame.maxY + 0.5,
                "Live Windowed overlay maxY \(metrics.cocoaFrame.maxY) overlapped Menu Bar above visibleFrame.maxY \(primaryScreen.visibleFrame.maxY) (displays=\(liveDisplays.count))"
            )
        }
    }

    // MARK: - Floating Toolbar Anti-Flicker & Dual-Pointer Hover Regression Suite

    @Test("OverlayToolbarAutoHideState.beginShow(.autoHide) is idempotent when already shown and NEVER resets isRevealedByHover (zero flicker)")
    func toolbarAutoHideIdempotentShowPreventsFlicker() {
        var state = OverlayToolbarAutoHideState()
        let overlayFrame = CGRect(x: 0, y: 1, width: 1512, height: 981)
        let visibleScreen = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let pillFrame = OverlayChromeGeometry.computeVisibleToolbarCocoaFrame(
            for: overlayFrame,
            hostScreenVisibleFrame: visibleScreen
        )

        // 1. Initial show in .autoHide starts hidden and requests hover timer.
        let first = state.beginShow(
            mode: .autoHide,
            overlayCocoaFrame: overlayFrame,
            visibleToolbarFrame: pillFrame
        )
        #expect(first.shouldHide == false)
        #expect(first.isIdempotentUpdate == false)
        #expect(first.shouldResetAutoHideHidden == true)
        #expect(first.shouldStartHoverTimer == true)
        #expect(state.isShown == true)
        #expect(state.isRevealedByHover == false)
        #expect(state.visibleInteractiveCocoaFrame == nil)

        // 2. Move pointer into top strip -> reveals toolbar and reports interactive frame once.
        let topEdgePoint = CGPoint(x: pillFrame.midX, y: overlayFrame.maxY - 2)
        let revealEval = state.evaluateAutoHideHover(
            physicalCocoaPoint: topEdgePoint,
            scaledCocoaPoint: nil,
            now: 10.0
        )
        #expect(revealEval.action == .reveal)
        #expect(revealEval.interactiveFrameChanged == true)
        #expect(state.isRevealedByHover == true)
        #expect(state.visibleInteractiveCocoaFrame == pillFrame)

        // 3. Repeated show(.autoHide) calls (e.g. from metric/chrome syncs) MUST be idempotent:
        //    NEVER reset isRevealedByHover, NEVER hide, NEVER restart hoverTimer, and NEVER spam interactiveFrameChanged!
        for i in 0..<10 {
            let jitterFrame = CGRect(
                x: pillFrame.origin.x + (i.isMultiple(of: 2) ? 0.2 : -0.2),
                y: pillFrame.origin.y,
                width: pillFrame.width,
                height: pillFrame.height
            )
            let repeatShow = state.beginShow(
                mode: .autoHide,
                overlayCocoaFrame: overlayFrame,
                visibleToolbarFrame: jitterFrame
            )
            #expect(repeatShow.isIdempotentUpdate == true)
            #expect(repeatShow.shouldResetAutoHideHidden == false)
            #expect(repeatShow.shouldStartHoverTimer == false)
            #expect(repeatShow.shouldHide == false)
            #expect(repeatShow.interactiveFrameChanged == false, "Sub-0.5pt jitter must not spam interactiveFrameChanged")
            #expect(state.isRevealedByHover == true, "Repeated show(.autoHide) must NEVER hide a hovered toolbar!")
            #expect(state.visibleInteractiveCocoaFrame != nil)
        }

        // 4. Genuine frame move (>= 0.5pt) updates frame WITHOUT hiding toolbar and fires interactiveFrameChanged once.
        let shiftedOverlay = CGRect(x: 200, y: 120, width: 960, height: 540)
        let shiftedPill = OverlayChromeGeometry.computeVisibleToolbarCocoaFrame(
            for: shiftedOverlay,
            hostScreenVisibleFrame: visibleScreen
        )
        let movedShow = state.beginShow(
            mode: .autoHide,
            overlayCocoaFrame: shiftedOverlay,
            visibleToolbarFrame: shiftedPill
        )
        #expect(movedShow.isIdempotentUpdate == true)
        #expect(movedShow.shouldResetAutoHideHidden == false)
        #expect(movedShow.interactiveFrameChanged == true)
        #expect(state.isRevealedByHover == true)
        #expect(state.visibleInteractiveCocoaFrame == shiftedPill)
    }

    @Test("OverlayToolbarAutoHideState stays continuously hovered when EITHER physical or scaled pointer is inside toolbar, topStrip (zero gap), or +24pt hysteresis zone")
    func toolbarAutoHideDualPointerAndHysteresis() {
        var state = OverlayToolbarAutoHideState()
        let overlayFrame = CGRect(x: 0, y: 1, width: 1512, height: 981)
        let visibleScreen = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let pillFrame = OverlayChromeGeometry.computeVisibleToolbarCocoaFrame(
            for: overlayFrame,
            hostScreenVisibleFrame: visibleScreen
        )
        _ = state.beginShow(
            mode: .autoHide,
            overlayCocoaFrame: overlayFrame,
            visibleToolbarFrame: pillFrame
        )

        // 1. Verify ZERO dead gap between topStrip and visibleToolbarRect from screen top down into the pill!
        let topStrip = OverlayToolbarAutoHideState.computeAutoHideTopStrip(
            anchorOverlayFrame: overlayFrame,
            visibleToolbarRect: pillFrame
        )
        #expect(topStrip.maxY >= overlayFrame.maxY, "topStrip must reach the very top edge of the overlay")
        #expect(topStrip.minY < pillFrame.maxY, "topStrip must overlap visibleToolbarRect with zero dead gap")
        for y in stride(from: Int(pillFrame.maxY - 20), through: Int(overlayFrame.maxY), by: 2) {
            let probe = CGPoint(x: pillFrame.midX, y: CGFloat(y))
            #expect(
                topStrip.contains(probe) || pillFrame.contains(probe),
                "Dead gap found between topStrip and visibleToolbarRect at y=\(y)"
            )
        }

        // 2. Scaled pointer enters topStrip while physical OS cursor is confined far away in a small source window -> REVEALS!
        let farAwayPoint = CGPoint(x: 120, y: 120)
        let scaledTopPoint = CGPoint(x: pillFrame.midX, y: pillFrame.maxY + 4)
        let e1 = state.evaluateAutoHideHover(
            physicalCocoaPoint: farAwayPoint,
            scaledCocoaPoint: scaledTopPoint,
            now: 1.0
        )
        #expect(e1.action == .reveal)
        #expect(e1.isHovering == true)
        #expect(state.isRevealedByHover == true)

        // 3. CursorOverlayController switches to .directChrome (physical mouse is on a toolbar button while
        //    scaled pointer lags far away) -> MUST stay continuously hovered well past 0.85s!
        let physicalOnStopButton = CGPoint(x: pillFrame.maxX - 24, y: pillFrame.midY)
        for tick in 1...25 {
            let eval = state.evaluateAutoHideHover(
                physicalCocoaPoint: physicalOnStopButton,
                scaledCocoaPoint: farAwayPoint,
                now: 1.0 + Double(tick) * 0.08
            )
            #expect(eval.action == .none)
            #expect(eval.isHovering == true)
            #expect(eval.interactiveFrameChanged == false)
            #expect(state.isRevealedByHover == true)
        }

        // 4. +24pt horizontal / +18pt vertical hysteresis zone keeps toolbar continuously revealed for EITHER pointer!
        let hysteresisPoints: [CGPoint] = [
            CGPoint(x: pillFrame.minX - 22, y: pillFrame.midY),
            CGPoint(x: pillFrame.maxX + 22, y: pillFrame.midY),
            CGPoint(x: pillFrame.midX, y: pillFrame.minY - 16),
            CGPoint(x: pillFrame.midX, y: pillFrame.maxY + 16)
        ]
        for (idx, pt) in hysteresisPoints.enumerated() {
            // Test with physical inside hysteresis, scaled far away
            let evalPhys = state.evaluateAutoHideHover(
                physicalCocoaPoint: pt,
                scaledCocoaPoint: farAwayPoint,
                now: 4.0 + Double(idx) * 0.5
            )
            #expect(evalPhys.isHovering == true, "Physical point \(pt) inside hysteresis zone must remain hovered")
            #expect(evalPhys.action == .none)

            // Test with scaled inside hysteresis, physical far away
            let evalScaled = state.evaluateAutoHideHover(
                physicalCocoaPoint: farAwayPoint,
                scaledCocoaPoint: pt,
                now: 6.0 + Double(idx) * 0.5
            )
            #expect(evalScaled.isHovering == true, "Scaled point \(pt) inside hysteresis zone must remain hovered")
            #expect(evalScaled.action == .none)
        }

        // 5. Once BOTH pointers leave outside the hysteresis zone, waits >= 0.85s then hides cleanly ONCE.
        let outsidePoint = CGPoint(x: pillFrame.maxX + 40, y: pillFrame.minY - 40)
        let leaveStart = state.evaluateAutoHideHover(
            physicalCocoaPoint: outsidePoint,
            scaledCocoaPoint: outsidePoint,
            now: 10.0
        )
        #expect(leaveStart.action == .none)
        #expect(state.isRevealedByHover == true)

        let beforeDelay = state.evaluateAutoHideHover(
            physicalCocoaPoint: outsidePoint,
            scaledCocoaPoint: outsidePoint,
            now: 10.70
        )
        #expect(beforeDelay.action == .none)
        #expect(state.isRevealedByHover == true)

        let afterDelay = state.evaluateAutoHideHover(
            physicalCocoaPoint: outsidePoint,
            scaledCocoaPoint: outsidePoint,
            now: 10.90
        )
        #expect(afterDelay.action == .hide)
        #expect(afterDelay.interactiveFrameChanged == true)
        #expect(state.isRevealedByHover == false)
        #expect(state.visibleInteractiveCocoaFrame == nil)

        // Subsequent unhovered ticks produce zero redundant interactive-frame notifications.
        let steadyHidden = state.evaluateAutoHideHover(
            physicalCocoaPoint: outsidePoint,
            scaledCocoaPoint: outsidePoint,
            now: 11.50
        )
        #expect(steadyHidden.action == .none)
        #expect(steadyHidden.interactiveFrameChanged == false)
    }

    // MARK: - Bug #1: WindowEnumerator Fullscreen Video Window Priority

    @Test("WindowEnumerator.selectBestTargetWindow prefers display-covering fullscreen video windows over smaller layer-0 HUD helper bars")
    func windowEnumeratorPrefersFullscreenVideoWindow() {
        let displays = Self.dualDisplays

        // Case 1: Chrome/Safari/IINA fullscreen — small layer-0 HUD helper bar sits at zOrder=0 ABOVE
        // the actual display-covering fullscreen video window at zOrder=1!
        let hudHelperBar = WindowEnumerator.TargetWindowCandidate(
            windowID: 1001,
            layer: 0,
            alpha: 1.0,
            bounds: CGRect(x: 400, y: 880, width: 700, height: 72),
            zOrder: 0
        )
        let fullscreenVideo = WindowEnumerator.TargetWindowCandidate(
            windowID: 1002,
            layer: 0,
            alpha: 1.0,
            bounds: Self.primaryRetina.cgBounds,
            zOrder: 1
        )
        let picked1 = WindowEnumerator.selectBestTargetWindow(
            from: [hudHelperBar, fullscreenVideo],
            displays: displays
        )
        #expect(picked1?.windowID == 1002)

        // Case 2: Raised-layer fullscreen game/video window (`layer > 0`) vs small layer-0 companion window
        let raisedFullscreen = WindowEnumerator.TargetWindowCandidate(
            windowID: 2002,
            layer: 5,
            alpha: 1.0,
            bounds: Self.externalDELLNegativeCGY.cgBounds,
            zOrder: 2
        )
        let picked2 = WindowEnumerator.selectBestTargetWindow(
            from: [hudHelperBar, raisedFullscreen],
            displays: displays
        )
        #expect(picked2?.windowID == 2002)

        // Case 3: MacBook Pro notch-inset native fullscreen video (top inset = 33pt below notch, full width, flush bottom)
        // vs tiny floating control strip at zOrder=0
        let notchFullscreen = WindowEnumerator.TargetWindowCandidate(
            windowID: 3002,
            layer: 0,
            alpha: 1.0,
            bounds: CGRect(x: 0, y: 33, width: 1512, height: 949),
            zOrder: 1
        )
        let picked3 = WindowEnumerator.selectBestTargetWindow(
            from: [hudHelperBar, notchFullscreen],
            displays: displays
        )
        #expect(picked3?.windowID == 3002)

        // Case 4: Non-fullscreen — substantial layer-0 content window (>= 200x150) beats tiny layer-0 toolbar helper
        let tinyBar = WindowEnumerator.TargetWindowCandidate(
            windowID: 4001,
            layer: 0,
            alpha: 1.0,
            bounds: CGRect(x: 100, y: 100, width: 180, height: 80),
            zOrder: 0
        )
        let mainContent = WindowEnumerator.TargetWindowCandidate(
            windowID: 4002,
            layer: 0,
            alpha: 1.0,
            bounds: CGRect(x: 120, y: 120, width: 1024, height: 640),
            zOrder: 1
        )
        let picked4 = WindowEnumerator.selectBestTargetWindow(
            from: [tinyBar, mainContent],
            displays: displays
        )
        #expect(picked4?.windowID == 4002)

        // Case 5: Always-on-Top / PiP video window (`layer == floatingWindow`, >= 200x150) is capturable
        // and classified as `.application`, while still ranking below fullscreen & normal `layer == 0` windows!
        let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))
        let pipVideo = WindowEnumerator.TargetWindowCandidate(
            windowID: 5001,
            layer: floatingLayer,
            alpha: 1.0,
            bounds: CGRect(x: 900, y: 500, width: 480, height: 270),
            zOrder: 0
        )
        let tinyFloatingPalette = WindowEnumerator.TargetWindowCandidate(
            windowID: 5002,
            layer: floatingLayer,
            alpha: 1.0,
            bounds: CGRect(x: 100, y: 100, width: 120, height: 48),
            zOrder: 0
        )
        #expect(WindowEnumerator.isSubstantialFloatingAppWindow(layer: floatingLayer, alpha: 1.0, bounds: pipVideo.bounds) == true)
        #expect(WindowEnumerator.isSubstantialFloatingAppWindow(layer: floatingLayer, alpha: 1.0, bounds: tinyFloatingPalette.bounds) == false)
        #expect(WindowEnumerator.classifyOwner(
            pid: 9090,
            bundleIdentifier: "com.colliderli.iina",
            ownerName: "IINA",
            layer: floatingLayer,
            bounds: pipVideo.bounds,
            displays: displays
        ) == .application)
        #expect(WindowEnumerator.classifyOwner(
            pid: 9090,
            bundleIdentifier: "com.colliderli.iina",
            ownerName: "IINA",
            layer: floatingLayer,
            bounds: tinyFloatingPalette.bounds,
            displays: displays
        ) == .overlay)
        // Normal layer-0 window still beats floating PiP when both exist
        #expect(WindowEnumerator.selectBestTargetWindow(from: [pipVideo, mainContent], displays: displays)?.windowID == 4002)
        // When ONLY the Float-on-Top / PiP window exists, it is cleanly selected!
        #expect(WindowEnumerator.selectBestTargetWindow(from: [tinyFloatingPalette, pipVideo], displays: displays)?.windowID == 5001)
    }

    @Test("WindowEnumerator distinguishes MacBook Pro notch-inset native fullscreen video from maximized desktop Chrome and IINA/Wine legacy fullscreen")
    func notchFullscreenAndLegacyFullscreenClassification() {
        let displays = Self.dualDisplays
        let notchBounds = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let fullBleedBounds = Self.primaryRetina.cgBounds

        // 1. Native fullscreen Bilibili/Safari/Chrome/IINA below MacBook Pro notch (`AXFullScreen == true`):
        //    BOTH native FS space (level 19) AND fullscreen video SR source (`true`)!
        #expect(WindowEnumerator.resolveNativeFullscreenClassification(
            axFullScreenAttribute: true,
            windowLayer: 0,
            bounds: notchBounds,
            displays: displays
        ) == true)
        #expect(WindowEnumerator.resolveFullscreenVideoOrGameClassification(
            axFullScreenAttribute: true,
            windowLayer: 0,
            bounds: notchBounds,
            displays: displays
        ) == true)

        // 2. Maximized desktop Chrome webpage below notch (`(0, 33, 1512, 949)` with `AXFullScreen == false`):
        //    Desktop space (level 98, above Menu Bar) AND NOT a fullscreen video source (`false` -> 1:1 sharp text)!
        #expect(WindowEnumerator.resolveNativeFullscreenClassification(
            axFullScreenAttribute: false,
            windowLayer: 0,
            bounds: notchBounds,
            displays: displays
        ) == false)
        #expect(WindowEnumerator.resolveFullscreenVideoOrGameClassification(
            axFullScreenAttribute: false,
            windowLayer: 0,
            bounds: notchBounds,
            displays: displays
        ) == false)

        // 3. IINA/VLC/mpv Legacy Fullscreen or Wine borderless fullscreen on Desktop Space
        //    (`(0, 0, 1512, 982)` with `AXFullScreen == false`):
        //    NOT native FS space (stays level 98 on Desktop Space!), YES fullscreen video/game source (`true`)!
        #expect(WindowEnumerator.resolveNativeFullscreenClassification(
            axFullScreenAttribute: false,
            windowLayer: 0,
            bounds: fullBleedBounds,
            displays: displays
        ) == false)
        #expect(WindowEnumerator.resolveFullscreenVideoOrGameClassification(
            axFullScreenAttribute: false,
            windowLayer: 0,
            bounds: fullBleedBounds,
            displays: displays
        ) == true)
        #expect(WindowEnumerator.resolveFullscreenVideoOrGameClassification(
            axFullScreenAttribute: false,
            windowLayer: 5,
            bounds: fullBleedBounds,
            displays: displays
        ) == true)

        // 4. AX unavailable (`nil`) fallback: exact full-bleed layer 0 -> true; notch desktop -> false
        #expect(WindowEnumerator.resolveNativeFullscreenClassification(
            axFullScreenAttribute: nil,
            windowLayer: 0,
            bounds: fullBleedBounds,
            displays: displays
        ) == true)
        #expect(WindowEnumerator.resolveNativeFullscreenClassification(
            axFullScreenAttribute: nil,
            windowLayer: 5,
            bounds: fullBleedBounds,
            displays: displays
        ) == false)
        #expect(WindowEnumerator.resolveNativeFullscreenClassification(
            axFullScreenAttribute: nil,
            windowLayer: 0,
            bounds: notchBounds,
            displays: displays
        ) == false)
    }
}
