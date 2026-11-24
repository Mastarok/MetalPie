import AppKit
import ApplicationServices
import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import Metal
import QuartzCore
import Testing
import os

@testable import MetalPieCore
@testable import MetalPieCapture
@testable import MetalPieInput
@testable import MetalPieShaders

// MARK: - Helpers for Live GPU Pixel-Correspondence Verification

private func makeButtonGridFrame(
    device: any MTLDevice,
    width: Int,
    height: Int,
    gridCols: Int,
    gridRows: Int,
    screenRect: CGRect,
    scaleFactor: Double = 2.0
) throws -> (frame: CapturedFrame, cache: CVMetalTextureCache) {
    var cacheOut: CVMetalTextureCache?
    let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cacheOut)
    guard cacheStatus == kCVReturnSuccess, let cache = cacheOut else {
        throw EngineError.metalDeviceUnavailable
    }

    let attrs: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var pbOut: CVPixelBuffer?
    let pbStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &pbOut
    )
    guard pbStatus == kCVReturnSuccess, let pb = pbOut else {
        throw EngineError.captureStartFailed("CVPixelBufferCreate failed (\(pbStatus))")
    }

    // Encode each (col, row) cell with a unique deterministic (R, G, B) color so we can empirically
    // verify that mapping source CG coordinates -> scaled overlay coordinates lands on the EXACT button!
    CVPixelBufferLockBaseAddress(pb, [])
    if let base = CVPixelBufferGetBaseAddress(pb) {
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = min(gridRows - 1, (y * gridRows) / height)
            let rowPtr = ptr + y * bpr
            for x in 0..<width {
                let col = min(gridCols - 1, (x * gridCols) / width)
                let r = UInt8(30 + col * 48)   // 30, 78, 126, 174, 222
                let g = UInt8(30 + row * 48)   // 30, 78, 126, 174, 222
                let b = UInt8(220 - ((col + row) * 20))
                let off = x * 4
                rowPtr[off + 0] = b
                rowPtr[off + 1] = g
                rowPtr[off + 2] = r
                rowPtr[off + 3] = 255
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])

    var cvTexOut: CVMetalTexture?
    let texStatus = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault,
        cache,
        pb,
        nil,
        .bgra8Unorm,
        width,
        height,
        0,
        &cvTexOut
    )
    guard texStatus == kCVReturnSuccess,
          let cvTex = cvTexOut,
          let mtlTex = CVMetalTextureGetTexture(cvTex)
    else {
        throw EngineError.captureStartFailed("CVMetalTextureCacheCreateTextureFromImage failed (\(texStatus))")
    }

    let surfID: IOSurfaceID = CVPixelBufferGetIOSurface(pb).map { IOSurfaceGetID($0.takeUnretainedValue()) } ?? 0
    let backing = CapturedFrameBacking(pixelBuffer: pb, cvMetalTexture: cvTex, surfaceID: surfID)
    let frame = CapturedFrame(
        texture: mtlTex,
        pixelSize: PixelSize(width: width, height: height),
        contentRect: CGRect(x: 0, y: 0, width: width, height: height),
        screenRect: screenRect,
        scaleFactor: scaleFactor,
        timestampSeconds: CACurrentMediaTime(),
        isHDR: false,
        colorSpaceName: CGColorSpace.displayP3 as String,
        backingObject: backing
    )
    return (frame, cache)
}

private func readRGBAPixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let w = image.width
    let h = image.height
    let cx = min(max(0, x), max(0, w - 1))
    let cy = min(max(0, y), max(0, h - 1))
    var bytes = [UInt8](repeating: 0, count: 4)
    // Match the image's own color space (Display P3 from PresentPassRenderer) so CoreGraphics performs
    // zero gamut conversion when sampling exact encoded button cell IDs.
    let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    if let ctx = CGContext(
        data: &bytes,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) {
        ctx.draw(image, in: CGRect(x: -cx, y: -(h - 1 - cy), width: w, height: h))
    }
    return (bytes[0], bytes[1], bytes[2])
}

private func makeTestMetalLayer(
    device: any MTLDevice,
    pixelSize: PixelSize,
    backingScale: CGFloat
) -> CAMetalLayer {
    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.isOpaque = true
    layer.framebufferOnly = true
    layer.maximumDrawableCount = 3
    layer.contentsScale = backingScale
    layer.drawableSize = CGSize(width: pixelSize.width, height: pixelSize.height)
    layer.frame = CGRect(
        x: 0,
        y: 0,
        width: CGFloat(pixelSize.width) / backingScale,
        height: CGFloat(pixelSize.height) / backingScale
    )
    return layer
}

// MARK: - Cursor Click Alignment, Focus Stability & Multi-Monitor Suite

@Suite("Cursor Click Alignment, Focus Stability & Multi-Monitor", .serialized)
struct CursorClickAlignmentAndMultiMonitorTests {
    // Exact host dual-monitor topology from live macOS hardware:
    // - Primary: Built-in Retina XDR 1512x982 @2x 120Hz, Cocoa (0,0), CG (0,0)
    // - External: DELL P2422H 1280x720 @2x 60Hz, Cocoa (1512,982) -> CG (1512,-720) (negative CG Y!)
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
        id: 3,
        name: "DELL P2422H",
        cocoaFrame: CGRect(x: 1512, y: 982, width: 1280, height: 720),
        cgBounds: CGRect(x: 1512, y: -720, width: 1280, height: 720),
        backingScaleFactor: 2.0,
        refreshRateHz: 60.0,
        maxEDRHeadroom: 1.0,
        isPrimary: false
    )

    private static let leftExternal1x = DisplayDescriptor(
        id: 7,
        name: "Left 1080p 1x External",
        cocoaFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
        cgBounds: CGRect(x: -1920, y: 102, width: 1920, height: 1080),
        backingScaleFactor: 1.0,
        refreshRateHz: 144.0,
        maxEDRHeadroom: 1.0,
        isPrimary: false
    )

    private static let triMonitorDisplays = [primaryRetina, externalDELLNegativeCGY, leftExternal1x]

    // MARK: 1. 25-Point Terminal Click Correspondence (Points/Pixels + Real GPU Output Proof)

    @Test("25-point Terminal click alignment across Fullscreen Fit, Fill, IntegerFit, Windowed, External DELL negative-Y, and Left 1x display (with GPU pixel verification)")
    func terminal25PointClickCorrespondenceAndGPUPixelProof() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable")
            return
        }

        let displays = Self.triMonitorDisplays

        struct Scenario {
            let name: String
            let sourceWindowCG: CGRect
            let sourceBackingScale: Double
            let targetOverlayCG: CGRect
            let targetBackingScale: Double
            let scalingType: ScalingType
            let presentationMode: PresentationMode
            let verifyOnGPU: Bool
        }

        let scenarios: [Scenario] = [
            // Retina 2x Terminal (680x440 pt @ (120, 140)) scaled Fullscreen Fit on 1512x982 @2x (with 1pt anti-occlusion -> 1512x981)
            Scenario(
                name: "Primary Retina Fullscreen Fit",
                sourceWindowCG: CGRect(x: 120, y: 140, width: 680, height: 440),
                sourceBackingScale: 2.0,
                targetOverlayCG: CGRect(x: 0, y: 0, width: 1512, height: 981),
                targetBackingScale: 2.0,
                scalingType: .fit,
                presentationMode: .fullscreen,
                verifyOnGPU: true
            ),
            Scenario(
                name: "Primary Retina Fullscreen Fill",
                sourceWindowCG: CGRect(x: 120, y: 140, width: 680, height: 440),
                sourceBackingScale: 2.0,
                targetOverlayCG: CGRect(x: 0, y: 0, width: 1512, height: 981),
                targetBackingScale: 2.0,
                scalingType: .fill,
                presentationMode: .fullscreen,
                verifyOnGPU: true
            ),
            Scenario(
                name: "Primary Retina IntegerFit",
                sourceWindowCG: CGRect(x: 120, y: 140, width: 680, height: 440),
                sourceBackingScale: 2.0,
                targetOverlayCG: CGRect(x: 0, y: 0, width: 1512, height: 981),
                targetBackingScale: 2.0,
                scalingType: .integerFit,
                presentationMode: .fullscreen,
                verifyOnGPU: true
            ),
            Scenario(
                name: "Primary Retina Windowed 1.5x",
                sourceWindowCG: CGRect(x: 120, y: 140, width: 680, height: 440),
                sourceBackingScale: 2.0,
                targetOverlayCG: CGRect(x: 246, y: 160, width: 1020, height: 660),
                targetBackingScale: 2.0,
                scalingType: .fit,
                presentationMode: .windowed(initialScale: 1.5),
                verifyOnGPU: true
            ),
            // Terminal sitting on External DELL P2422H (negative CG Y = -720!)
            Scenario(
                name: "External DELL Negative-CG-Y Fullscreen Fit",
                sourceWindowCG: CGRect(x: 1620, y: -620, width: 680, height: 440),
                sourceBackingScale: 2.0,
                targetOverlayCG: CGRect(x: 1512, y: -720, width: 1280, height: 719),
                targetBackingScale: 2.0,
                scalingType: .fit,
                presentationMode: .fullscreen,
                verifyOnGPU: true
            ),
            // Terminal sitting on Left 1x External display (negative CG X = -1920, @1x backing scale!)
            Scenario(
                name: "Left 1x External Display Fullscreen Fit",
                sourceWindowCG: CGRect(x: -1700, y: 260, width: 680, height: 440),
                sourceBackingScale: 1.0,
                targetOverlayCG: CGRect(x: -1920, y: 102, width: 1920, height: 1079),
                targetBackingScale: 1.0,
                scalingType: .fit,
                presentationMode: .fullscreen,
                verifyOnGPU: false
            )
        ]

        let renderer = try EffectChainRenderer(device: device)
        let loop = try RenderLoopController(device: device, effectRenderer: renderer)
        defer { loop.stop() }

        let gridCols = 5
        let gridRows = 5

        for scenario in scenarios {
            let srcPixels = PixelSize(
                width: Int((scenario.sourceWindowCG.width * scenario.sourceBackingScale).rounded()),
                height: Int((scenario.sourceWindowCG.height * scenario.sourceBackingScale).rounded())
            )
            let dstPixels = PixelSize(
                width: Int((scenario.targetOverlayCG.width * scenario.targetBackingScale).rounded()),
                height: Int((scenario.targetOverlayCG.height * scenario.targetBackingScale).rounded())
            )

            let effect = EffectInstance(effectID: .nearest, scalingType: scenario.scalingType)
            let layout = ScalingLayoutCalculator.calculate(
                sourcePixelSize: srcPixels,
                targetPixelSize: dstPixels,
                targetCGRect: scenario.targetOverlayCG,
                backingScaleFactor: scenario.targetBackingScale,
                crop: .zero,
                effects: [effect],
                presentationMode: scenario.presentationMode,
                alignment: .center
            )

            let mapping = PointerMapping(
                sourceWindowCGRect: scenario.sourceWindowCG,
                layout: layout,
                displays: displays,
                settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
            )

            #expect(mapping.isValid, "Invalid mapping for \(scenario.name)")
            #expect(!mapping.isIdentity, "Scaled Terminal must not be identity in \(scenario.name)")

            // Verify sourceRect is strictly in CG logical points matching window.cgBounds (or UV sub-slice for Fill).
            #expect(mapping.sourceRect.minX >= scenario.sourceWindowCG.minX - 1e-6)
            #expect(mapping.sourceRect.minY >= scenario.sourceWindowCG.minY - 1e-6)
            #expect(mapping.sourceRect.maxX <= scenario.sourceWindowCG.maxX + 1e-6)
            #expect(mapping.sourceRect.maxY <= scenario.sourceWindowCG.maxY + 1e-6)

            // Build 25 test button centers inside the visible source rect (5x5 grid covering corners, edges, center)
            var testButtons: [(col: Int, row: Int, sourceCG: CGPoint)] = []
            for row in 0..<gridRows {
                for col in 0..<gridCols {
                    let fracX = (Double(col) + 0.5) / Double(gridCols)
                    let fracY = (Double(row) + 0.5) / Double(gridRows)
                    let pt = CGPoint(
                        x: mapping.sourceRect.minX + fracX * mapping.sourceRect.width,
                        y: mapping.sourceRect.minY + fracY * mapping.sourceRect.height
                    )
                    testButtons.append((col, row, pt))
                }
            }
            #expect(testButtons.count == 25)

            // Verify round-trip <= 0.5pt, strict source confinement, and hotspot Y-flip geometry for all 25 buttons!
            let cursorSize = CGSize(width: 28, height: 40)
            let cursorHotSpot = CGPoint(x: 4, y: 2)

            for btn in testButtons {
                let scaledCG = mapping.mapSourceToScaled(btn.sourceCG, clampToContent: true)
                let backToSource = mapping.mapScaledToSource(scaledCG, clampToSource: true)
                #expect(abs(backToSource.x - btn.sourceCG.x) <= 0.5, "X round-trip drift > 0.5pt in \(scenario.name)")
                #expect(abs(backToSource.y - btn.sourceCG.y) <= 0.5, "Y round-trip drift > 0.5pt in \(scenario.name)")

                // Every scaled button maps strictly inside sourceWindowCG (never clicks Desktop/MetalPie!)
                let confined = mapping.constrainSourcePoint(backToSource)
                #expect(scenario.sourceWindowCG.contains(confined.point), "Confined click escaped source window in \(scenario.name)!")

                // Verify spriteGeometry local Cocoa Y-up matches CG Y-down overlay height!
                let geom = mapping.spriteGeometry(
                    forSourcePoint: btn.sourceCG,
                    cursorPointSize: cursorSize,
                    hotSpot: cursorHotSpot
                )
                let expectedLocalCGX = scaledCG.x - scenario.targetOverlayCG.minX
                let expectedLocalCGY = scaledCG.y - scenario.targetOverlayCG.minY
                #expect(abs(geom.overlayLocalCGPosition.x - expectedLocalCGX) < 1e-6)
                #expect(abs(geom.overlayLocalCGPosition.y - expectedLocalCGY) < 1e-6)
                #expect(abs(geom.overlayLocalCocoaPosition.x - expectedLocalCGX) < 1e-6)
                #expect(abs(geom.overlayLocalCocoaPosition.y - (scenario.targetOverlayCG.height - expectedLocalCGY)) < 1e-6)
                #expect(abs(geom.layerAnchorPoint.x - (4.0 / 28.0)) < 1e-6)
                #expect(abs(geom.layerAnchorPoint.y - (1.0 - 2.0 / 40.0)) < 1e-6)
            }

            // Real GPU verification: render 5x5 color-coded button grid via RenderLoopController & verify that
            // every mapped cursor hotspot lands on the EXACT button color in the Metal output texture!
            if scenario.verifyOnGPU {
                let (frame, cache) = try makeButtonGridFrame(
                    device: device,
                    width: srcPixels.width,
                    height: srcPixels.height,
                    gridCols: gridCols,
                    gridRows: gridRows,
                    screenRect: scenario.sourceWindowCG,
                    scaleFactor: scenario.sourceBackingScale
                )
                defer { CVMetalTextureCacheFlush(cache, 0) }

                let mode = ScalingMode(name: scenario.name, effects: [effect])
                var profile = Profile.defaultProfile
                profile.presentationMode = scenario.presentationMode
                profile.capture.lowLatencyPresent = true
                profile.capture.duplicateFrameMode = .never
                profile.frameGen.enabled = false

                let layer = makeTestMetalLayer(
                    device: device,
                    pixelSize: dstPixels,
                    backingScale: CGFloat(scenario.targetBackingScale)
                )
                let overlayCocoa = ScreenGeometry.cgToCocoa(rect: scenario.targetOverlayCG, displays: displays)
                let metrics = OverlayDrawableMetrics(
                    cocoaFrame: overlayCocoa,
                    cgFrame: scenario.targetOverlayCG,
                    drawablePixelSize: dstPixels,
                    backingScaleFactor: scenario.targetBackingScale,
                    screenMaxFPS: 120.0,
                    displayID: CGMainDisplayID(),
                    supportsEDR: false,
                    isVRRDirectScanoutActive: false
                )

                let firstReady = OSAllocatedUnfairLock(initialState: false)
                loop.setFirstFrameHandler { firstReady.withLock { $0 = true } }
                loop.start(
                    metalLayer: layer,
                    configuration: RenderSessionConfiguration(
                        targetWindowName: scenario.name,
                        profile: profile,
                        scalingMode: mode,
                        overlayMetrics: metrics
                    )
                )
                loop.ingest(frame: frame)
                #expect(await waitForCondition(timeoutSeconds: 3.0) { firstReady.withLock { $0 } })

                let renderedLayout = try #require(loop.currentLayout)
                let screenshot = try await loop.requestCursorFreeScreenshot()

                // Verify screenshot pixels match exact mapped button colors for ALL 25 grid buttons!
                // Note: cursor-free screenshot covers `renderedLayout.visibleContentPixelRect` (= `contentRect` in points).
                for row in 0..<gridRows {
                    for col in 0..<gridCols {
                        let rawBtnX = scenario.sourceWindowCG.minX + ((Double(col) + 0.5) / Double(gridCols)) * scenario.sourceWindowCG.width
                        let rawBtnY = scenario.sourceWindowCG.minY + ((Double(row) + 0.5) / Double(gridRows)) * scenario.sourceWindowCG.height
                        let btnPt = CGPoint(x: rawBtnX, y: rawBtnY)
                        // Skip buttons cropped off-screen in `.fill` mode
                        guard mapping.isPointInsideSource(btnPt, margin: 4.0) else { continue }

                        let scaledCG = mapping.mapSourceToScaled(btnPt, clampToContent: true)
                        let pxInContentX = Int(((scaledCG.x - renderedLayout.contentRect.minX) * scenario.targetBackingScale).rounded())
                        let pxInContentY = Int(((scaledCG.y - renderedLayout.contentRect.minY) * scenario.targetBackingScale).rounded())

                        let sampled = readRGBAPixel(screenshot, x: pxInContentX, y: pxInContentY)
                        let expectedR = Int(30 + col * 48)
                        let expectedG = Int(30 + row * 48)
                        let expectedB = Int(220 - ((col + row) * 20))
                        #expect(
                            abs(Int(sampled.r) - expectedR) <= 12 &&
                            abs(Int(sampled.g) - expectedG) <= 12 &&
                            abs(Int(sampled.b) - expectedB) <= 12,
                            "Button (\(col),\(row)) misaligned in \(scenario.name): expected RGB(\(expectedR),\(expectedG),\(expectedB)), got \(sampled) at screenshot px (\(pxInContentX),\(pxInContentY))"
                        )
                    }
                }
                loop.stop()
            }
        }
    }

    // MARK: 2. Event-Tap Click Alignment, Safe Center Warp, Speed Compensation & Scroll Confinement

    @Test("Event-tap processor centers initial pointer when starting outside Terminal, keeps clicks/scrolls aligned under speed compensation, and avoids FPS-grab false positives")
    func eventTapClickAlignmentAndZeroFalseGrab() throws {
        let displays = Self.triMonitorDisplays
        let terminalCG = CGRect(x: 120, y: 140, width: 680, height: 440) // 680x440 pt
        let contentCG = CGRect(x: 0, y: 1.5, width: 1512, height: 978.5) // ~2.22x Fit
        let overlayCG = CGRect(x: 0, y: 0, width: 1512, height: 981)

        let mapping = PointerMapping(
            sourceRect: terminalCG,
            contentRect: contentCG,
            overlayRect: overlayCG,
            displays: displays,
            backingScaleFactor: 2.0,
            settings: CursorSettings(
                renderScaledCursor: true,
                confineCursor: true,
                adjustCursorSpeed: true,
                respectGameMouseGrab: true
            ),
            threeDGameMode: false
        )

        // 1. Clicking "Scale" in MetalPie's UI outside Terminal (e.g. (1180, 760)) MUST center into Terminal
        //    instead of clamping onto Terminal's bottom-right corner!
        let outsideClickStart = mapping.safeInitialSourcePoint(from: CGPoint(x: 1180, y: 760))
        #expect(outsideClickStart.shouldWarp)
        #expect(abs(outsideClickStart.point.x - terminalCG.midX) < 0.01)
        #expect(abs(outsideClickStart.point.y - terminalCG.midY) < 0.01)

        // Starting via hotkey while already inside Terminal preserves exact position with zero jump!
        let insideHotkeyStart = mapping.safeInitialSourcePoint(from: CGPoint(x: 310, y: 280))
        #expect(!insideHotkeyStart.shouldWarp)
        #expect(insideHotkeyStart.point == CGPoint(x: 310, y: 280))

        // 2. Simulate 40 slow + fast mouse moves with speed compensation (1 / 2.22x) followed by clicks & scroll!
        var processor = CursorEventTapProcessor()
        processor.reset(initialSourcePosition: outsideClickStart.point)
        processor.recordExternalWarp(to: outsideClickStart.point, timestamp: 10.0)

        var simulatedPhysicalCursor = outsideClickStart.point
        var t = 10.05

        for step in 0..<40 {
            let dx: Double = (step < 20) ? 2.0 : 35.0
            let dy: Double = (step % 2 == 0) ? 1.5 : -1.0
            // Simulate uncompensated OS hardware movement before event tap rewrites/warps it
            simulatedPhysicalCursor.x += dx
            simulatedPhysicalCursor.y += dy

            let moveDecision = processor.process(
                input: CursorTapEventInput(type: .mouseMoved, location: simulatedPhysicalCursor, deltaX: dx, deltaY: dy, timestamp: t),
                mapping: mapping
            )
            let decision = try #require(moveDecision)
            // Must NEVER false-positive FPS mouse-grab on Terminal during speed-compensated warps!
            #expect(!decision.isMouseGrabbedByGame, "Speed-compensation self-warp false-positived FPS grab at step \(step)!")
            #expect(decision.isScaledSpriteVisible, "Scaled cursor sprite disappeared at step \(step)!")
            #expect(terminalCG.contains(decision.effectiveSourcePoint), "Effective point escaped Terminal!")
            #expect(decision.effectiveSourcePoint.x >= terminalCG.minX + 1.0 && decision.effectiveSourcePoint.x <= terminalCG.maxX - 1.0)
            #expect(decision.effectiveSourcePoint.y >= terminalCG.minY + 1.0 && decision.effectiveSourcePoint.y <= terminalCG.maxY - 1.0)

            if let wt = decision.warpTarget {
                simulatedPhysicalCursor = wt
            }
            t += 0.008
        }

        // Now simulate a click (`leftMouseDown` -> `leftMouseUp`) EVEN IF stale `incoming` drifted far outside Terminal!
        let expectedClickSource = try #require(processor.virtualSourcePosition)
        let expectedClickScaled = mapping.mapSourceToScaled(expectedClickSource, clampToContent: true)

        let staleDriftedIncoming = CGPoint(x: 1450, y: 920) // WAY outside Terminal!
        let downDecision = processor.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: staleDriftedIncoming, deltaX: 0, deltaY: 0, timestamp: t + 0.01),
            mapping: mapping
        )
        let clickDown = try #require(downDecision)
        #expect(clickDown.rewrittenEventLocation == expectedClickSource, "leftMouseDown MUST NOT snap back to stale incoming!")
        #expect(clickDown.effectiveSourcePoint == expectedClickSource)
        #expect(clickDown.scaledCGPosition == expectedClickScaled)
        #expect(terminalCG.contains(clickDown.effectiveSourcePoint), "Click MUST land strictly inside Terminal!")

        // Verify rightMouseDown & scrollWheel ALSO stay locked to virtualSourcePosition inside Terminal!
        let scrollDecision = processor.process(
            input: CursorTapEventInput(type: .scrollWheel, location: staleDriftedIncoming, deltaX: 0, deltaY: 0, timestamp: t + 0.02),
            mapping: mapping
        )
        let scroll = try #require(scrollDecision)
        #expect(scroll.rewrittenEventLocation == expectedClickSource, "scrollWheel MUST be confined inside Terminal!")
        #expect(terminalCG.contains(scroll.effectiveSourcePoint))

        // Verify self-warp echo filter skips zero-delta `.mouseMoved` within 50ms, yet NEVER skips `.leftMouseDown`!
        let warpPt = clickDown.effectiveSourcePoint
        let echoMove = processor.process(
            input: CursorTapEventInput(type: .mouseMoved, location: warpPt, deltaX: 0, deltaY: 0, timestamp: t + 0.025),
            mapping: mapping
        )
        #expect(echoMove == nil, "Zero-delta mouseMoved echo right after warp should passthrough")

        let fastClickAfterWarp = processor.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: warpPt, deltaX: 0, deltaY: 0, timestamp: t + 0.026),
            mapping: mapping
        )
        #expect(fastClickAfterWarp != nil, "leftMouseDown right after a warp MUST NEVER be skipped as a warp echo!")

        // 3. Verify genuine FPS mouse grab (stationary incoming with non-zero deltas) STILL triggers accurately!
        var fpsProcessor = CursorEventTapProcessor()
        let anchor = CGPoint(x: 460, y: 360)
        fpsProcessor.reset(initialSourcePosition: anchor)
        var fpsT = 20.0
        _ = fpsProcessor.process(input: CursorTapEventInput(type: .mouseMoved, location: anchor, deltaX: 0, deltaY: 0, timestamp: fpsT), mapping: mapping)
        for i in 1...4 {
            fpsT += 0.01
            let res = fpsProcessor.process(
                input: CursorTapEventInput(type: .mouseMoved, location: anchor, deltaX: 12, deltaY: -5, timestamp: fpsT),
                mapping: mapping
            )
            if i >= 3 {
                #expect(res?.isMouseGrabbedByGame == true, "Genuine stationary FPS mouse grab must be detected!")
                #expect(res?.isScaledSpriteVisible == false, "Scaled sprite must hide during genuine FPS mouse grab!")
            }
        }

        // 4. Verify unconfined multi-monitor escape (`confineCursor == false`): moving outside source hides scaled sprite!
        let freeMapping = PointerMapping(
            sourceRect: terminalCG,
            contentRect: contentCG,
            overlayRect: overlayCG,
            displays: displays,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: false, adjustCursorSpeed: false)
        )
        var freeProc = CursorEventTapProcessor()
        freeProc.reset(initialSourcePosition: CGPoint(x: 460, y: 360))
        let outsideRes = freeProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 1800, y: -300), deltaX: 100, deltaY: -50, timestamp: 30.0),
            mapping: freeMapping
        )
        #expect(outsideRes?.isPointerOutsideUnconfinedSource == true)
        #expect(outsideRes?.isScaledSpriteVisible == false)
    }

    // MARK: 3. No-Accessibility Honesty & 1:1 Passthrough Mode

    @Test("CursorOverlayController reports exact CursorAlignmentMode, never draws misaligned sprite or hides OS cursor when Accessibility is unavailable")
    func cursorOverlayAlignmentModesAndNoAXHonesty() throws {
        let controller = CursorOverlayController(
            presentationMode: .overlayLayer,
            requireAccessibilityForScaledMode: false
        )
        defer { controller.stop() }

        let reportedModes = OSAllocatedUnfairLock<[CursorAlignmentMode]>(initialState: [])
        controller.setAlignmentModeHandler { mode in
            reportedModes.withLock { $0.append(mode) }
        }
        controller.updateDisplays(Self.triMonitorDisplays)

        // 1. 1:1 Identity mode -> `.identityPassthrough`, zero AX required, OS cursor untouched!
        let rect1to1 = CGRect(x: 100, y: 100, width: 800, height: 600)
        try controller.start(
            configuration: CursorMappingConfiguration(
                sourceCGRect: rect1to1,
                destinationCGRect: rect1to1,
                overlayCGRect: rect1to1,
                backingScaleFactor: 2.0,
                settings: CursorSettings(),
                threeDGameMode: false
            )
        ) { _ in }
        #expect(controller.alignmentMode == .identityPassthrough)
        #expect(!controller.isAccessibilityRequiredForAlignment)
        #expect(!controller.currentState.isVisible)
        #expect(SystemCursorHider.processHideDepth == 0)

        // 2. Non-1:1 Scaled Terminal (680x440 -> 1512x981)
        let scaledConfig = CursorMappingConfiguration(
            sourceCGRect: CGRect(x: 120, y: 140, width: 680, height: 440),
            destinationCGRect: CGRect(x: 0, y: 1.5, width: 1512, height: 978.5),
            overlayCGRect: CGRect(x: 0, y: 0, width: 1512, height: 981),
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true),
            threeDGameMode: false
        )
        try controller.start(configuration: scaledConfig) { _ in }

        if !AXIsProcessTrusted() {
            #expect(controller.alignmentMode == .accessibilityRequired)
            #expect(controller.isAccessibilityRequiredForAlignment)
            #expect(controller.latestRenderSnapshot.alignmentMode == .accessibilityRequired)
            #expect(!controller.currentState.isVisible, "NEVER draw a misaligned cursor sprite without Accessibility!")
            #expect(SystemCursorHider.processHideDepth == 0, "NEVER hide the native OS cursor without Accessibility!")

            // Strict mode (`requireAccessibilityForScaledMode: true`) must throw `.accessibilityPermissionDenied`!
            let strictController = CursorOverlayController(requireAccessibilityForScaledMode: true)
            defer { strictController.stop() }
            var threwAXError = false
            do {
                try strictController.start(configuration: scaledConfig) { _ in }
            } catch EngineError.accessibilityPermissionDenied {
                threwAXError = true
            }
            #expect(threwAXError)
        } else {
            #expect(controller.alignmentMode == .scaledConfinedEventTap)
            #expect(!controller.isAccessibilityRequiredForAlignment)
        }

        controller.stop()
        #expect(controller.alignmentMode == .inactive)
        #expect(SystemCursorHider.processHideDepth == 0)
    }

    // MARK: 4. Multi-Monitor Overlay Placement & Live Dual-Monitor Hardware Verification

    @Test("Multi-monitor OverlayWindowController targets exact external display (DELL negative-CG-Y & Left negative-X @1x) and preserves live dual-display metrics")
    @MainActor
    func multiMonitorOverlayPlacementAndLiveDualDisplayCheck() throws {
        let displays = Self.triMonitorDisplays

        // A. Pure multi-monitor solver across Primary, DELL (negative CG Y), Left (@1x negative X), and all MultiMonitorModes
        let terminalOnDELL = CGRect(x: 1620, y: -620, width: 680, height: 440)
        let dellFullscreen = OverlayWindowController.computeOverlayCocoaFrame(
            sourceCGRect: terminalOnDELL,
            presentationMode: .fullscreen,
            multiMonitorMode: .closest,
            displays: displays,
            aspectRatio: 680.0 / 440.0,
            applyAntiOcclusion: true
        )
        // DELL Cocoa frame is (1512, 982, 1280, 720) -> 1pt anti-occlusion inset at bottom -> (1512, 983, 1280, 719)!
        #expect(dellFullscreen == CGRect(x: 1512, y: 983, width: 1280, height: 719))
        #expect(ScreenGeometry.cocoaToCG(rect: dellFullscreen, displays: displays) == CGRect(x: 1512, y: -720, width: 1280, height: 719))

        // Windowed overlay for window on DELL MUST open inside DELL's Cocoa bounds, NOT Primary!
        let dellWindowed = OverlayWindowController.computeOverlayCocoaFrame(
            sourceCGRect: terminalOnDELL,
            presentationMode: .windowed(initialScale: 1.5),
            multiMonitorMode: .closest,
            displays: displays,
            aspectRatio: 680.0 / 440.0,
            applyAntiOcclusion: true
        )
        #expect(dellWindowed.minX >= Self.externalDELLNegativeCGY.cocoaFrame.minX)
        #expect(dellWindowed.maxX <= Self.externalDELLNegativeCGY.cocoaFrame.maxX)
        #expect(dellWindowed.minY >= Self.externalDELLNegativeCGY.cocoaFrame.minY)
        #expect(dellWindowed.maxY <= Self.externalDELLNegativeCGY.cocoaFrame.maxY)

        // Window on Left 1x External display -> Fullscreen opens on Left display (`x = -1920`)
        let terminalOnLeft = CGRect(x: -1700, y: 260, width: 680, height: 440)
        let leftFullscreen = OverlayWindowController.computeOverlayCocoaFrame(
            sourceCGRect: terminalOnLeft,
            presentationMode: .fullscreen,
            multiMonitorMode: .closest,
            displays: displays,
            aspectRatio: 680.0 / 440.0,
            applyAntiOcclusion: true
        )
        #expect(leftFullscreen == CGRect(x: -1920, y: -199, width: 1920, height: 1079))
        #expect(ScreenGeometry.cocoaToCG(rect: leftFullscreen, displays: displays) == CGRect(x: -1920, y: 102, width: 1920, height: 1079))

        // MultiMonitorMode.intersected for window straddling Primary + Left External
        let straddlingCG = CGRect(x: -300, y: 250, width: 600, height: 400)
        let intersectedCocoa = OverlayWindowController.computeOverlayCocoaFrame(
            sourceCGRect: straddlingCG,
            presentationMode: .fullscreen,
            multiMonitorMode: .intersected,
            displays: displays,
            aspectRatio: 1.5,
            applyAntiOcclusion: false
        )
        #expect(intersectedCocoa == Self.leftExternal1x.cocoaFrame.union(Self.primaryRetina.cocoaFrame))

        // MultiMonitorMode.all spans all 3 displays
        let allCocoa = OverlayWindowController.computeOverlayCocoaFrame(
            sourceCGRect: terminalOnDELL,
            presentationMode: .fullscreen,
            multiMonitorMode: .all,
            displays: displays,
            aspectRatio: 1.5,
            applyAntiOcclusion: false
        )
        let expectedAll = Self.primaryRetina.cocoaFrame
            .union(Self.externalDELLNegativeCGY.cocoaFrame)
            .union(Self.leftExternal1x.cocoaFrame)
        #expect(allCocoa == expectedAll)

        // B. Live OverlayWindowController test against REAL attached NSScreens on this Mac!
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let liveDisplays = WindowEnumerator.enumerateDisplaysOnMain()
        #expect(!liveDisplays.isEmpty)

        // Verify ScreenGeometry matches EVERY live display's real CGDisplayBounds <-> NSScreen.frame!
        for d in liveDisplays {
            let computedCG = ScreenGeometry.cocoaToCG(rect: d.cocoaFrame, displays: liveDisplays)
            let computedCocoa = ScreenGeometry.cgToCocoa(rect: d.cgBounds, displays: liveDisplays)
            #expect(abs(computedCG.minX - d.cgBounds.minX) < 0.5)
            #expect(abs(computedCG.minY - d.cgBounds.minY) < 0.5)
            #expect(abs(computedCG.width - d.cgBounds.width) < 0.5)
            #expect(abs(computedCG.height - d.cgBounds.height) < 0.5)
            #expect(abs(computedCocoa.minX - d.cocoaFrame.minX) < 0.5)
            #expect(abs(computedCocoa.minY - d.cocoaFrame.minY) < 0.5)
        }

        let overlayController = try OverlayWindowController()
        defer { overlayController.close() }

        // Test opening OverlayPanel on EVERY live display (including external DELL P2422H if attached!)
        for display in liveDisplays {
            let syntheticWinBounds = CGRect(
                x: display.cgBounds.minX + 60,
                y: display.cgBounds.minY + 60,
                width: min(680, display.cgBounds.width - 120),
                height: min(440, display.cgBounds.height - 120)
            )
            let winDesc = WindowDescriptor(
                windowID: 99_001,
                pid: 42_001,
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                title: "zsh",
                cgBounds: syntheticWinBounds,
                backingScaleFactor: display.backingScaleFactor
            )
            var profile = Profile.defaultProfile
            profile.presentationMode = .fullscreen
            profile.multiMonitorMode = .closest

            let metrics = overlayController.prepareOverlay(
                sourceWindow: winDesc,
                profile: profile,
                isNativeFullscreenSpace: false
            )
            #expect(metrics.displayID == display.id, "Overlay jumped away from display '\(display.name)' (\(display.id)) to \(metrics.displayID)!")
            #expect(abs(metrics.cocoaFrame.minX - display.cocoaFrame.minX) < 0.5)
            #expect(abs(metrics.cocoaFrame.minY - (display.cocoaFrame.minY + 1.0)) < 0.5)
            #expect(abs(metrics.cgFrame.minX - display.cgBounds.minX) < 0.5)
            #expect(abs(metrics.cgFrame.minY - display.cgBounds.minY) < 0.5)
            #expect(abs(metrics.backingScaleFactor - display.backingScaleFactor) < 0.01)
            #expect(abs(metrics.screenMaxFPS - display.refreshRateHz) < 0.5)
            #expect(metrics.drawablePixelSize.width == Int((metrics.cocoaFrame.width * display.backingScaleFactor).rounded()))
            #expect(metrics.drawablePixelSize.height == Int((metrics.cocoaFrame.height * display.backingScaleFactor).rounded()))
        }
    }

    // MARK: 5. Live AppKit Window + WindowLifecycleWatcher Zero False Focus-Loss & Overlap Test

    @Test("WindowLifecycleWatcher startup grace window suppresses own-PID bounce and never counts MetalPie overlay/cursor panels as foreign overlap")
    @MainActor
    func windowLifecycleGraceWindowAndZeroOwnPanelOverlap() async throws {
        // 1. Pure grace window unit checks
        let ownPID: Int32 = 1000
        let terminalPID: Int32 = 2000
        let finderPID: Int32 = 3000

        // Own-PID bounce during grace window -> IGNORED!
        #expect(WindowLifecycleWatcher.shouldIgnoreActivationBounce(
            activatedPID: ownPID,
            trackedPID: terminalPID,
            ownPID: ownPID,
            nowUptime: 100.10,
            graceDeadlineUptime: 100.45
        ))
        // Own-PID activation AFTER grace window (user Cmd+Tabbed back to MetalPie!) -> NOT ignored!
        #expect(!WindowLifecycleWatcher.shouldIgnoreActivationBounce(
            activatedPID: ownPID,
            trackedPID: terminalPID,
            ownPID: ownPID,
            nowUptime: 100.60,
            graceDeadlineUptime: 100.45
        ))
        // Third-party app activation (user Cmd+Tabbed to Finder even during grace window) -> NOT ignored!
        #expect(!WindowLifecycleWatcher.shouldIgnoreActivationBounce(
            activatedPID: finderPID,
            trackedPID: terminalPID,
            ownPID: ownPID,
            nowUptime: 100.10,
            graceDeadlineUptime: 100.45
        ))

        // 2. Live AppKit test window + OverlayPanel + WindowLifecycleWatcher (zero false focus loss or overlap!)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let liveWindow = NSWindow(
            contentRect: NSRect(x: 200, y: 260, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        liveWindow.isReleasedWhenClosed = false
        liveWindow.title = "MetalPieLiveWatcherTarget"
        liveWindow.orderFrontRegardless()

        let liveOverlay = OverlayPanel(globalCocoaRect: CGRect(x: 160, y: 220, width: 620, height: 440))
        liveOverlay.isReleasedWhenClosed = false
        liveOverlay.orderFrontRegardless()
        liveWindow.displayIfNeeded()
        liveOverlay.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(80))

        defer {
            liveOverlay.orderOut(nil)
            liveWindow.orderOut(nil)
            liveOverlay.close()
            liveWindow.close()
        }

        let liveDisplays = WindowEnumerator.enumerateDisplaysOnMain()
        let testBounds = ScreenGeometry.cocoaToCG(rect: liveWindow.frame, displays: liveDisplays)
        let liveWID = CGWindowID(max(0, liveWindow.windowNumber))
        let liveOverlayID = CGWindowID(max(0, liveOverlay.windowNumber))

        // Verify detectForeignWindowOverlap NEVER flags MetalPie's own OverlayPanel / CursorPanel / ToolbarPanel!
        let ownPIDLive = ProcessInfo.processInfo.processIdentifier
        let ownPanels: [RawWindowSnapshot] = [
            RawWindowSnapshot(
                windowID: liveOverlayID > 0 ? liveOverlayID : 88_001,
                pid: ownPIDLive,
                ownerName: "MetalPie",
                bundleIdentifier: "com.metalpie.app",
                title: "OverlayPanel",
                cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 981),
                layer: 100
            ),
            RawWindowSnapshot(
                windowID: 88_002,
                pid: ownPIDLive,
                ownerName: "MetalPie",
                bundleIdentifier: "com.metalpie.app",
                title: "CursorOverlayPanel",
                cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 981),
                layer: 101
            ),
            RawWindowSnapshot(
                windowID: 88_003,
                pid: ownPIDLive,
                ownerName: "MetalPie",
                bundleIdentifier: "com.metalpie.app",
                title: "OverlayToolbarPanel",
                cgBounds: CGRect(x: 546, y: 10, width: 420, height: 42),
                layer: 102
            ),
            RawWindowSnapshot(
                windowID: 88_004,
                pid: ownPIDLive,
                ownerName: "MetalPie",
                bundleIdentifier: "com.metalpie.app",
                title: "ProfilerHUDPanel",
                cgBounds: CGRect(x: 16, y: 16, width: 260, height: 110),
                layer: 103
            )
        ]

        let overlapResult = WindowLifecycleWatcher.detectForeignWindowOverlap(
            trackedBounds: testBounds.isEmpty ? CGRect(x: 120, y: 140, width: 680, height: 440) : testBounds,
            trackedPID: 99_999,
            ownPID: ownPIDLive,
            ignoredWindowIDs: Set(ownPanels.map(\.windowID)),
            displays: Self.triMonitorDisplays,
            windowsAboveTarget: ownPanels
        )
        #expect(overlapResult == nil, "MetalPie's own overlay/cursor/toolbar/HUD panels MUST NEVER trigger foreignWindowOverlapped!")

        // Verify a genuine third-party foreign window overlapping the target IS detected.
        let foreignWindow = RawWindowSnapshot(
            windowID: 99_123,
            pid: 77_777,
            ownerName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            title: "Documentation",
            cgBounds: CGRect(x: 150, y: 160, width: 500, height: 350),
            layer: 0
        )
        let foreignOverlap = WindowLifecycleWatcher.detectForeignWindowOverlap(
            trackedBounds: CGRect(x: 120, y: 140, width: 680, height: 440),
            trackedPID: 99_999,
            ownPID: ownPIDLive,
            ignoredWindowIDs: Set(ownPanels.map(\.windowID)),
            displays: Self.triMonitorDisplays,
            windowsAboveTarget: ownPanels + [foreignWindow]
        )
        #expect(foreignOverlap?.window.windowID == 99_123)

        // Only run the live WindowServer polling assertion if our headless test NSWindow is actually
        // registered in CGWindowList (swift test CLI processes without an active runloop may not
        // materialize backing windows in WindowServer).
        let isLiveWindowRegistered: Bool = {
            guard liveWID > 0,
                  let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], liveWID) as? [[String: Any]],
                  !info.isEmpty else {
                return false
            }
            return true
        }()

        if isLiveWindowRegistered {
            let watcher = WindowLifecycleWatcher(pollIntervalMilliseconds: 25, activationGraceSeconds: 0.45)
            defer { watcher.stopObserving() }

            let falseEvents = OSAllocatedUnfairLock<[String]>(initialState: [])
            watcher.setThreeDGameMode(true, ignoredOverlayWindowIDs: [liveOverlayID])
            watcher.setDetailedEventHandler { ev in
                switch ev {
                case .targetLostFocus:
                    falseEvents.withLock { $0.append("targetLostFocus") }
                case .foreignWindowOverlapped(_, let win, _):
                    falseEvents.withLock { $0.append("overlap:\(win.appName)") }
                case .targetClosed:
                    falseEvents.withLock { $0.append("targetClosed") }
                default:
                    break
                }
            }
            watcher.startObserving(trackedWindowID: liveWID) { _ in }
            try await Task.sleep(for: .milliseconds(250))

            #expect(falseEvents.withLock { $0 }.isEmpty, "Live watcher emitted spurious events: \(falseEvents.withLock { $0 })")
        }
    }
}
