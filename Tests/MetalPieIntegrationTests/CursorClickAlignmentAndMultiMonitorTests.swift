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

        // 3. Verify genuine FPS mouse grab (strictly stationary incoming with >= 6 pinned events and >= 18pt
        //    accumulated unreflected delta) STILL triggers accurately without prematurely firing on < 6 events!
        var fpsProcessor = CursorEventTapProcessor()
        let anchor = CGPoint(x: 460, y: 360)
        fpsProcessor.reset(initialSourcePosition: anchor)
        var fpsT = 20.0
        _ = fpsProcessor.process(input: CursorTapEventInput(type: .mouseMoved, location: anchor, deltaX: 0, deltaY: 0, timestamp: fpsT), mapping: mapping)
        for i in 1...6 {
            fpsT += 0.01
            let res = fpsProcessor.process(
                input: CursorTapEventInput(type: .mouseMoved, location: anchor, deltaX: 12, deltaY: -5, timestamp: fpsT),
                mapping: mapping
            )
            if i < 6 {
                #expect(res?.isMouseGrabbedByGame == false, "FPS grab must require >= 6 consecutive pinned events (step \(i))")
            } else {
                #expect(res?.isMouseGrabbedByGame == true, "Genuine stationary FPS mouse grab must be detected at step 6!")
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

    // MARK: 6. Regression: 5,128-Level EventTap Stack-Overflow Crash & Zero-Alloc Border Checks

    @Test("EventTapCallbackBox survives 60,000 consecutive callbacks on a 512KB thread stack with O(1) depth and zero-allocation RectEdges border checks")
    func eventTapCallbackBox60kStressAndZeroAllocBorders() throws {
        // 1. Verify RectEdges is a 1-byte stack OptionSet (zero heap allocations in CGEventTap hot path!).
        #expect(MemoryLayout<RectEdges>.size == 1)

        let sourceCG = CGRect(x: 100, y: 100, width: 600, height: 400)
        let contentCG = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let config = CursorMappingConfiguration(
            sourceCGRect: sourceCG,
            destinationCGRect: contentCG,
            overlayCGRect: contentCG,
            backingScaleFactor: 2.0,
            settings: CursorSettings(
                renderScaledCursor: true,
                confineCursor: true,
                adjustCursorSpeed: true,
                respectGameMouseGrab: true
            ),
            threeDGameMode: false
        )

        let mapping = PointerMapping(configuration: config, displays: Self.triMonitorDisplays)
        // Exercise border/confinement checks across corners, edges, interior, and multi-monitor L-shapes.
        let topLeftBorders = mapping.touchedBorders(CGPoint(x: mapping.confinementRect.minX, y: mapping.confinementRect.minY))
        #expect(topLeftBorders == [.left, .top])
        #expect(topLeftBorders.contains(.left) && topLeftBorders.contains(.top))
        #expect(!topLeftBorders.contains(.right) && !topLeftBorders.contains(.bottom))

        let bottomRightBorders = mapping.touchedBorders(CGPoint(x: mapping.confinementRect.maxX, y: mapping.confinementRect.maxY))
        #expect(bottomRightBorders == [.right, .bottom])
        #expect(mapping.isDeltaPushingOutward(deltaX: 5, deltaY: 5, at: CGPoint(x: mapping.confinementRect.maxX, y: mapping.confinementRect.maxY)))
        #expect(!mapping.isDeltaPushingOutward(deltaX: -5, deltaY: 0, at: CGPoint(x: mapping.confinementRect.maxX, y: mapping.confinementRect.maxY)))

        // 2. Run 60,000 consecutive EventTapCallbackBox.invoke(...) calls on a 512 KB pthread stack
        //    (matching the exact 544 KB stack of `com.metalpie.input.event-tap` that overflowed at 5,128
        //    levels before eliminating `OSAllocatedUnfairLock<Closure?>`!).
        let controller = CursorOverlayController(presentationMode: .externalCompositor)
        defer { controller.stop() }
        controller.activateForEventTapTesting(
            configuration: config,
            displays: Self.triMonitorDisplays,
            initialPointer: CGPoint(x: sourceCG.midX, y: sourceCG.midY)
        )

        let box = EventTapCallbackBox(controller: controller)
        let doneSem = DispatchSemaphore(value: 0)
        let completedCount = OSAllocatedUnfairLock(initialState: 0)
        let maxVisualOutOfBounds = OSAllocatedUnfairLock(initialState: 0)

        let worker = Thread {
            let dummyProxy = OpaquePointer(bitPattern: 0x1000)!
            guard let ev = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: sourceCG.midX, y: sourceCG.midY),
                mouseButton: .left
            ) else {
                doneSem.signal()
                return
            }

            var x = sourceCG.midX
            var y = sourceCG.midY
            var outOfBounds = 0

            for i in 0..<60_000 {
                // Alternate smooth interior moves AND border pushes (which directly invoke
                // PointerTracker.recordEvent -> PointerMapping.isDeltaPushingOutward -> touchedBorders!).
                if i % 100 < 80 {
                    let stepX: CGFloat = (i % 40 < 20) ? 1.5 : -1.5
                    let stepY: CGFloat = (i % 30 < 15) ? 1.0 : -1.0
                    x = min(max(x + stepX, sourceCG.minX + 10), sourceCG.maxX - 10)
                    y = min(max(y + stepY, sourceCG.minY + 10), sourceCG.maxY - 10)
                    ev.location = CGPoint(x: x, y: y)
                    ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(stepX.rounded()))
                    ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(stepY.rounded()))
                } else {
                    // Push straight against right border so `touchedBorders` runs thousands of times!
                    ev.location = CGPoint(x: mapping.confinementRect.maxX, y: sourceCG.midY)
                    ev.setIntegerValueField(.mouseEventDeltaX, value: 4)
                    ev.setIntegerValueField(.mouseEventDeltaY, value: 0)
                }

                _ = box.invoke(proxy: dummyProxy, type: .mouseMoved, event: ev)
                let rewritten = ev.location
                if !sourceCG.contains(rewritten) {
                    outOfBounds += 1
                }
            }

            // Also verify invalidate() safely drops controller reference and passes events through.
            box.invalidate()
            _ = box.invoke(proxy: dummyProxy, type: .mouseMoved, event: ev)

            let finalOutOfBounds = outOfBounds
            maxVisualOutOfBounds.withLock { $0 = finalOutOfBounds }
            completedCount.withLock { $0 = 60_000 }
            doneSem.signal()
        }
        worker.name = "com.metalpie.test.event-tap-512k-stack"
        worker.stackSize = 512 * 1024
        worker.start()

        #expect(doneSem.wait(timeout: .now() + .seconds(30)) == .success, "60k event-tap stress thread timed out!")
        #expect(completedCount.withLock { $0 } == 60_000)
        #expect(maxVisualOutOfBounds.withLock { $0 } == 0, "Rewritten events must always remain strictly inside sourceCG")
    }

    // MARK: 7. Regression: Mouse Speed 1:1 Accuracy, Sub-Pixel Trackpad, Warp-Echo & Burst Immunity

    @Test("adjustCursorSpeed delivers exact 1:1 visual speed across sub-pixel trackpad nudges, high-DPI delta inflation, warp-delta spikes, and 120Hz pre-warp queued bursts")
    func cursorSpeedExact1to1AndWarpFeedbackImmunity() throws {
        // Exact user geometry: 600x400 window scaled fullscreen to 1512x982 (scaleX = 2.52, scaleY = 2.455)
        let sourceCG = CGRect(x: 100, y: 100, width: 600, height: 400)
        let contentCG = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let mapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: contentCG,
            overlayRect: contentCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(
                renderScaledCursor: true,
                confineCursor: true,
                adjustCursorSpeed: true,
                respectGameMouseGrab: true
            ),
            threeDGameMode: false
        )

        var processor = CursorEventTapProcessor()
        let startSource = CGPoint(x: 400, y: 300) // exact center of 600x400
        let outsideStart = CGPoint(x: 1180, y: 760) // simulated "Scale" button click outside window
        processor.reset(initialSourcePosition: startSource, physicalLocation: outsideStart)
        processor.recordExternalWarp(from: outsideStart, to: startSource, timestamp: 10.0)

        let initialScaled = mapping.mapSourceToScaled(startSource, clampToContent: true)

        // 1. Warp-contaminated startup echo: macOS reports landing at `startSource` WITH the full
        //    `-780, -460` warp jump inside `mouseEventDeltaX`/`DeltaY`! MUST BE COMPLETELY IGNORED!
        let contaminatedStartupEcho = processor.process(
            input: CursorTapEventInput(
                type: .mouseMoved,
                location: startSource,
                deltaX: Double(startSource.x - outsideStart.x),
                deltaY: Double(startSource.y - outsideStart.y),
                timestamp: 10.004
            ),
            mapping: mapping
        )
        #expect(contaminatedStartupEcho == nil, "Warp-contaminated startup echo must be dropped without moving virtualSourcePosition!")
        #expect(processor.virtualSourcePosition == startSource)

        // 2. Startup warp followed immediately by real `+4, +2` user move whose `deltaX/Y` ALSO
        //    carries the `-780, -460` warp jump! Must move visual cursor by EXACTLY `(+4, +2)`!
        processor.recordExternalWarp(from: outsideStart, to: startSource, timestamp: 10.10)
        let firstRealRaw = processor.process(
            input: CursorTapEventInput(
                type: .mouseMoved,
                location: CGPoint(x: startSource.x + 4.0, y: startSource.y + 2.0),
                deltaX: Double(startSource.x - outsideStart.x) + 4.0,
                deltaY: Double(startSource.y - outsideStart.y) + 2.0,
                timestamp: 10.108
            ),
            mapping: mapping
        )
        let firstRealAfterWarp = try #require(firstRealRaw)
        #expect(!firstRealAfterWarp.isMouseGrabbedByGame)
        #expect(abs((firstRealAfterWarp.scaledCGPosition.x - initialScaled.x) - 4.0) < 0.05)
        #expect(abs((firstRealAfterWarp.scaledCGPosition.y - initialScaled.y) - 2.0) < 0.05)

        // 3. Sub-pixel MacBook Pro Trackpad nudges: 200 tiny `0.5 pt` horizontal + `0.3 pt` vertical moves
        //    where integer `mouseEventDeltaX`/`DeltaY` truncates to `0` on every fractional step!
        //    Total physical hand move: +100.0 pt X, +60.0 pt Y -> Visual scaled cursor MUST move
        //    EXACTLY +100.0 pt X, +60.0 pt Y with ZERO warps during interior travel and ZERO FPS grab!
        processor.reset(initialSourcePosition: startSource, physicalLocation: startSource)
        var phys = startSource
        var t = 20.0
        var interiorWarpCount = 0
        var lastDecision: CursorTapEventDecision?

        for _ in 0..<200 {
            phys.x += 0.5
            phys.y += 0.3
            let raw = processor.process(
                input: CursorTapEventInput(
                    type: .mouseMoved,
                    location: phys,
                    deltaX: 0, // integer truncation on slow trackpad!
                    deltaY: 0,
                    timestamp: t
                ),
                mapping: mapping
            )
            let dec = try #require(raw)
            #expect(!dec.isMouseGrabbedByGame)
            #expect(dec.isScaledSpriteVisible)
            if dec.warpTarget != nil {
                interiorWarpCount += 1
            }
            lastDecision = dec
            t += 0.008
        }

        let afterTrackpad = try #require(lastDecision)
        #expect(interiorWarpCount == 0, "Interior glides MUST NOT spam CGWarpMouseCursorPosition!")
        #expect(abs((afterTrackpad.scaledCGPosition.x - initialScaled.x) - 100.0) < 0.05,
                "Expected exact +100pt visual X travel, got \(afterTrackpad.scaledCGPosition.x - initialScaled.x)")
        #expect(abs((afterTrackpad.scaledCGPosition.y - initialScaled.y) - 60.0) < 0.05,
                "Expected exact +60pt visual Y travel, got \(afterTrackpad.scaledCGPosition.y - initialScaled.y)")

        // 4. High-DPI mouse inflation immunity: `event.location` moves +2.0 pt per step while raw
        //    `mouseEventDeltaX` reports 4x larger (+8.0)! Visual cursor MUST still track 1:1 (+40pt over 20 steps),
        //    NOT 4x (+160pt)!
        let beforeHighDPI = afterTrackpad.scaledCGPosition
        for _ in 0..<20 {
            phys.x += 2.0
            let raw = processor.process(
                input: CursorTapEventInput(
                    type: .mouseMoved,
                    location: phys,
                    deltaX: 8.0, // 4x inflated raw device delta!
                    deltaY: 0,
                    timestamp: t
                ),
                mapping: mapping
            )
            let dec = try #require(raw)
            #expect(!dec.isMouseGrabbedByGame)
            lastDecision = dec
            t += 0.008
        }
        let afterHighDPI = try #require(lastDecision)
        #expect(abs((afterHighDPI.scaledCGPosition.x - beforeHighDPI.x) - 40.0) < 0.05,
                "High-DPI delta inflation must NEVER make scaled cursor fly; expected +40pt, got \(afterHighDPI.scaledCGPosition.x - beforeHighDPI.x)")

        // 5. Zero mid-glide warps across full host display roaming (`physicalRoamingRect`) + outer
        //    20pt bezel recenter warp + 120Hz stale pre-warp queued Mach-port burst + post-warp contaminated echo!
        //    First glide 500pt right (well past sourceCG.maxX = 700, staying inside display bezel 1492):
        //    MUST trigger ZERO mid-glide warps and move visual cursor exact +500pt!
        var handTravelRight = 0.0
        let beforeBurstScaledX = afterHighDPI.scaledCGPosition.x
        for _ in 0..<50 {
            phys.x += 10.0
            handTravelRight += 10.0
            let raw = processor.process(
                input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: 10.0, deltaY: 0, timestamp: t),
                mapping: mapping
            )
            let dec = try #require(raw)
            #expect(!dec.isMouseGrabbedByGame)
            #expect(dec.warpTarget == nil, "Full-display roaming must trigger ZERO mid-glide warps inside display bezel!")
            lastDecision = dec
            t += 0.008
        }
        let after500Glide = try #require(lastDecision)
        #expect(abs((after500Glide.scaledCGPosition.x - beforeBurstScaledX) - 500.0) < 0.05,
                "500pt interior full-display glide must move visual cursor exact +500pt with zero warps")

        // Now continue gliding right until physical cursor hits the 20pt outer display bezel (`x >= 1492`),
        // triggering ONE clean recenter warp!
        var recenterWarp: CGPoint?
        while recenterWarp == nil && handTravelRight < 1200.0 {
            phys.x += 10.0
            handTravelRight += 10.0
            let raw = processor.process(
                input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: 10.0, deltaY: 0, timestamp: t),
                mapping: mapping
            )
            let dec = try #require(raw)
            #expect(!dec.isMouseGrabbedByGame)
            if let wt = dec.warpTarget {
                recenterWarp = wt
            }
            t += 0.008
        }
        let warpTo = try #require(recenterWarp, "Expected bezel recenter warp when physical cursor reaches 20pt display margin")
        let warpFrom = phys

        // Simulate 2 stale pre-warp events ALREADY queued in WindowServer Mach port BEFORE warp landed!
        for _ in 0..<2 {
            phys.x += 5.0
            handTravelRight += 5.0
            let raw = processor.process(
                input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: 5.0, deltaY: 0, timestamp: t),
                mapping: mapping
            )
            let dec = try #require(raw)
            #expect(!dec.isMouseGrabbedByGame)
            #expect(dec.warpTarget == nil, "Must not stack redundant warps while a recenter warp is already in flight")
            lastDecision = dec
            t += 0.004
        }

        // Now warp lands -> WindowServer emits a warp echo with contaminated delta = (warpTo - phys)!
        let midWarpEcho = processor.process(
            input: CursorTapEventInput(
                type: .mouseMoved,
                location: warpTo,
                deltaX: Double(warpTo.x - phys.x),
                deltaY: Double(warpTo.y - phys.y),
                timestamp: t
            ),
            mapping: mapping
        )
        #expect(midWarpEcho == nil, "Contaminated recenter-warp echo must be completely ignored!")
        phys = warpTo
        t += 0.004

        // Next genuine post-warp move `-8.0 pt` (back inward so we stay strictly inside contentRect)!
        let beforePostWarpScaledX = try #require(lastDecision).scaledCGPosition.x
        phys.x -= 8.0
        let postWarpRaw = processor.process(
            input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: -8.0, deltaY: 0, timestamp: t),
            mapping: mapping
        )
        let postWarpReal = try #require(postWarpRaw)
        #expect(!postWarpReal.isMouseGrabbedByGame)
        #expect(warpTo.x < warpFrom.x - 50.0, "Recenter warp should jump cleanly back inward from display bezel")
        #expect(abs((postWarpReal.scaledCGPosition.x - beforePostWarpScaledX) - (-8.0)) < 0.15,
                "Post-warp movement must track exact 1:1 (-8.0pt) after recenter warp + echo, got \(postWarpReal.scaledCGPosition.x - beforePostWarpScaledX)pt")

        // 6. Click + Drag alignment right after burst (even if physical OS cursor drifted from virtualSourcePosition).
        let expectedClickPos = try #require(processor.virtualSourcePosition)
        let downRaw = processor.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: CGPoint(x: phys.x + 15, y: phys.y), deltaX: 0, deltaY: 0, timestamp: t + 0.01),
            mapping: mapping
        )
        let downDec = try #require(downRaw)
        #expect(downDec.rewrittenEventLocation == expectedClickPos)
        #expect(downDec.warpTarget == expectedClickPos, "Click should sync OS cursor to exact virtualSourcePosition when drifted")

        // 7. Verify `adjustCursorSpeed == false` moves proportionally to scale with ZERO interior warps and ZERO runaway!
        let uncompensatedMapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: contentCG,
            overlayRect: contentCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(
                renderScaledCursor: true,
                confineCursor: true,
                adjustCursorSpeed: false,
                respectGameMouseGrab: true
            ),
            threeDGameMode: false
        )
        var rawProc = CursorEventTapProcessor()
        rawProc.reset(initialSourcePosition: startSource, physicalLocation: startSource)
        let uncompRaw = rawProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 410, y: 300), deltaX: 10, deltaY: 0, timestamp: 30.0),
            mapping: uncompensatedMapping
        )
        let uncompMove = try #require(uncompRaw)
        #expect(uncompMove.warpTarget == nil, "Uncompensated interior movement must never warp")
        #expect(uncompMove.effectiveSourcePoint == CGPoint(x: 410, y: 300))
        let expectedUncompScaledDX = 10.0 * (1511.0 / 599.0)
        #expect(abs((uncompMove.scaledCGPosition.x - initialScaled.x) - expectedUncompScaledDX) < 0.05)
    }

    // MARK: 8. Regression (Bug #2A): Slow Sub-Pixel Glides, Human Wiggling & Genuine Warp-to-Center Detection

    @Test("PointerTracker never false-triggers FPS grab on slow sub-pixel glides, tiny sensor ticks, human back-and-forth wiggling, or display-bezel pushes, while still detecting genuine grabs")
    func pointerTrackerZeroFalseGrabOnSlowGlidesAndHumanWiggling() throws {
        let sourceCG = CGRect(x: 120, y: 140, width: 680, height: 440)
        let contentCG = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let mapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: contentCG,
            overlayRect: contentCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(
                renderScaledCursor: true,
                confineCursor: true,
                adjustCursorSpeed: true,
                respectGameMouseGrab: true
            ),
            threeDGameMode: false
        )

        // 1. Slow sub-pixel trackpad / 120Hz mouse glides (moveDist = 0.25–0.40pt with delta = 0.3–1.0pt):
        //    Previously hit `moveDist < 0.5 && hasDelta` -> false `isGrabbed = true` after 3 ticks (~25ms)!
        var processor = CursorEventTapProcessor()
        var phys = CGPoint(x: 400, y: 320)
        processor.reset(initialSourcePosition: phys, physicalLocation: phys)
        var t = 1.0
        for step in 0..<120 {
            let stepX: Double = (step % 3 == 0) ? 0.25 : 0.35
            let stepY: Double = (step % 2 == 0) ? 0.15 : 0.20
            // Alternate matching fractional deltas AND integer-quantized 1.0pt deltas!
            let dx: Double = (step % 2 == 0) ? stepX : 1.0
            let dy: Double = (step % 2 == 0) ? stepY : 0.0
            phys.x += stepX
            phys.y += stepY
            let rawDec = processor.process(
                input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: dx, deltaY: dy, timestamp: t),
                mapping: mapping
            )
            let dec = try #require(rawDec)
            #expect(!dec.isMouseGrabbedByGame, "Slow sub-pixel glide false-triggered isGrabbed at step \(step)!")
            #expect(dec.isScaledSpriteVisible, "Cursor sprite vanished during slow glide at step \(step)!")
            #expect(processor.pointerTracker.stillEventCount == 0)
            t += 0.008
        }

        // 2. Tiny stationary sensor jitter (`deltaMag < 2.0`) AND insufficient accumulated delta (< 18pt) must NOT grab!
        var tracker = PointerTracker()
        let stationary = CGPoint(x: 500, y: 400)
        _ = tracker.recordEvent(location: stationary, deltaX: 0, deltaY: 0, mapping: mapping, timestamp: 10.0)
        for i in 1...20 {
            _ = tracker.recordEvent(location: stationary, deltaX: 1.0, deltaY: 0.5, mapping: mapping, timestamp: 10.0 + Double(i) * 0.008)
            #expect(!tracker.isGrabbed, "Tiny deltaMag < 2.0 must never trigger FPS grab")
        }
        // 6 pinned events with deltaMag = 2.5 -> accumulated = 15.0 < 18.0 -> still NOT grabbed!
        tracker.reset()
        _ = tracker.recordEvent(location: stationary, deltaX: 0, deltaY: 0, mapping: mapping, timestamp: 11.0)
        for i in 1...6 {
            _ = tracker.recordEvent(location: stationary, deltaX: 2.5, deltaY: 0, mapping: mapping, timestamp: 11.0 + Double(i) * 0.008)
            #expect(!tracker.isGrabbed, "Accumulated unreflected delta < 18pt must not trigger FPS grab")
        }
        // Events 7 & 8 push accumulated unreflected delta to 20.0 >= 18.0 -> now grabs cleanly!
        _ = tracker.recordEvent(location: stationary, deltaX: 2.5, deltaY: 0, mapping: mapping, timestamp: 11.06)
        _ = tracker.recordEvent(location: stationary, deltaX: 2.5, deltaY: 0, mapping: mapping, timestamp: 11.07)
        #expect(tracker.isGrabbed)

        // 3. Rapid human back-and-forth mouse wiggling over a UI button (60 oscillations):
        //    MUST NEVER false-trigger Case 2 warp-to-center grab!
        processor.reset(initialSourcePosition: CGPoint(x: 450, y: 350), physicalLocation: CGPoint(x: 450, y: 350))
        phys = CGPoint(x: 450, y: 350)
        t = 20.0
        for step in 0..<60 {
            let dir: Double = (step % 2 == 0) ? 1.0 : -1.0
            let dx = dir * 12.0
            let dy = (step % 4 < 2) ? 2.0 : -2.0
            phys.x += dx
            phys.y += dy
            let rawDec = processor.process(
                input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: dx, deltaY: dy, timestamp: t),
                mapping: mapping
            )
            let dec = try #require(rawDec)
            #expect(!dec.isMouseGrabbedByGame, "Human back-and-forth wiggling false-triggered FPS grab at step \(step)!")
            #expect(dec.isScaledSpriteVisible, "Cursor vanished during human wiggling at step \(step)!")
            #expect(processor.pointerTracker.warpToCenterCount == 0)
            t += 0.012
        }

        // 4. Pushing outward against outer physical display bezel while roaming outside sourceRect must NOT grab!
        tracker.reset()
        let leftDisplayBezel = CGPoint(x: 0.0, y: 500.0)
        _ = tracker.recordEvent(location: leftDisplayBezel, deltaX: -5, deltaY: 0, mapping: mapping, timestamp: 30.0)
        for i in 1...10 {
            _ = tracker.recordEvent(location: leftDisplayBezel, deltaX: -12, deltaY: 0, mapping: mapping, timestamp: 30.0 + Double(i) * 0.01)
            #expect(!tracker.isGrabbed, "Pushing outward against physical display bezel must never trigger FPS grab")
        }

        // 5. Genuine game programmatic warp-to-center loop (Case 2: 5 snaps back to exact 1.5pt anchor with
        //    raw deltas pointing AWAY from anchor) MUST trigger on snap #5 and release cleanly!
        tracker.reset()
        let center = CGPoint(x: 460, y: 360)
        var wt = 40.0
        _ = tracker.recordEvent(location: center, deltaX: 0, deltaY: 0, mapping: mapping, timestamp: wt)
        for snap in 1...5 {
            wt += 0.01
            _ = tracker.recordEvent(location: CGPoint(x: center.x + 18, y: center.y), deltaX: 18, deltaY: 0, mapping: mapping, timestamp: wt)
            wt += 0.01
            // Game snaps cursor straight back to `center` while user's raw delta still points +14 right!
            _ = tracker.recordEvent(location: CGPoint(x: center.x + 0.5, y: center.y), deltaX: 14, deltaY: 0, mapping: mapping, timestamp: wt)
            if snap < 5 {
                #expect(!tracker.isGrabbed, "Warp-to-center must require >= 5 snaps (snap \(snap))")
            } else {
                #expect(tracker.isGrabbed, "Genuine 5-snap warp-to-center loop must trigger isGrabbed!")
            }
        }
        // Release after 2 genuine moves away
        _ = tracker.recordEvent(location: CGPoint(x: center.x + 20, y: center.y), deltaX: 20, deltaY: 0, mapping: mapping, timestamp: wt + 0.02)
        _ = tracker.recordEvent(location: CGPoint(x: center.x + 45, y: center.y), deltaX: 25, deltaY: 0, mapping: mapping, timestamp: wt + 0.04)
        #expect(!tracker.isGrabbed)

        // 6. Genuine zero-delta warp-to-center loop (SDL style) MUST ALSO detect on snap #5!
        tracker.reset()
        wt = 50.0
        _ = tracker.recordEvent(location: center, deltaX: 0, deltaY: 0, mapping: mapping, timestamp: wt)
        for snap in 1...5 {
            wt += 0.01
            _ = tracker.recordEvent(location: CGPoint(x: center.x + 16, y: center.y - 4), deltaX: 16, deltaY: -4, mapping: mapping, timestamp: wt)
            wt += 0.01
            _ = tracker.recordEvent(location: center, deltaX: 0, deltaY: 0, mapping: mapping, timestamp: wt)
            if snap < 5 {
                #expect(!tracker.isGrabbed)
            } else {
                #expect(tracker.isGrabbed, "Genuine 5-snap zero-delta warp-to-center loop must trigger isGrabbed!")
            }
        }
    }

    // MARK: 9. Regression (Bug #2A/2B): CursorSpriteOverlayPanel Never Calls orderOut on Transient Hide

    @Test("CursorSpriteOverlayPanel toggles spriteLayer.isHidden without panel.orderOut during transient hides and reserves orderOut for hide/suspend/stop")
    @MainActor
    func cursorSpriteOverlayPanelTransientHideNoOrderOutFlicker() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let spritePanel = CursorSpriteOverlayPanel()
        defer { spritePanel.close() }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ctx = try #require(CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 32 * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ))
        let cgImage = try #require(ctx.makeImage())
        let imgSnap = CursorImageSnapshot(
            cgImage: cgImage,
            pointSize: CGSize(width: 16, height: 16),
            hotSpot: CGPoint(x: 2, y: 2),
            backingScaleFactor: 2.0,
            generation: 1
        )

        let mapping = PointerMapping(
            sourceRect: CGRect(x: 120, y: 140, width: 680, height: 440),
            contentRect: CGRect(x: 0, y: 0, width: 1512, height: 981),
            overlayRect: CGRect(x: 0, y: 0, width: 1512, height: 981),
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0
        )
        let overlayCocoa = mapping.overlayCocoaFrame()
        let pos1 = CGPoint(x: 420, y: 310)
        let geom1 = mapping.spriteGeometry(forScaledPoint: pos1, cursorPointSize: imgSnap.pointSize, hotSpot: imgSnap.hotSpot)

        // 1. Apply visible snapshot -> panel visible, spriteLayer visible at exact Cocoa position.
        let visibleSnap1 = CursorRenderSnapshot(
            state: CursorOverlayState(isVisible: true, scaledCGPosition: pos1, scaleFactor: mapping.effectiveCursorScaleFactor),
            image: imgSnap,
            spriteGeometry: geom1,
            interpolation: .bilinear,
            presentationMode: .overlayLayer,
            alignmentMode: .scaledConfinedEventTap
        )
        spritePanel.apply(snapshot: visibleSnap1, overlayCocoaFrame: overlayCocoa)
        #expect(spritePanel.isPanelVisibleForTesting)
        #expect(!spritePanel.isSpriteLayerHiddenForTesting)
        #expect(spritePanel.spriteLayerPositionForTesting == geom1.overlayLocalCocoaPosition)

        // 2. Apply transient hide (e.g. game grab or idle hide) -> spriteLayer.isHidden == true,
        //    panel MUST stay ordered-in (`isVisible == true`) to prevent WindowServer surface flicker!
        var transientHiddenSnap = visibleSnap1
        transientHiddenSnap.state.isVisible = false
        transientHiddenSnap.state.isMouseGrabbedByGame = true
        spritePanel.apply(snapshot: transientHiddenSnap, overlayCocoaFrame: overlayCocoa)
        #expect(spritePanel.isSpriteLayerHiddenForTesting)
        #expect(spritePanel.isPanelVisibleForTesting, "Transient hide in apply() MUST NOT call panel.orderOut(nil)!")

        // 3. Restore visibility at a new coordinate -> position updates immediately!
        let pos2 = CGPoint(x: 980, y: 615)
        let geom2 = mapping.spriteGeometry(forScaledPoint: pos2, cursorPointSize: imgSnap.pointSize, hotSpot: imgSnap.hotSpot)
        let visibleSnap2 = CursorRenderSnapshot(
            state: CursorOverlayState(isVisible: true, scaledCGPosition: pos2, scaleFactor: mapping.effectiveCursorScaleFactor),
            image: imgSnap,
            spriteGeometry: geom2,
            interpolation: .bilinear,
            presentationMode: .overlayLayer,
            alignmentMode: .scaledConfinedEventTap
        )
        spritePanel.apply(snapshot: visibleSnap2, overlayCocoaFrame: overlayCocoa)
        #expect(spritePanel.isPanelVisibleForTesting)
        #expect(!spritePanel.isSpriteLayerHiddenForTesting)
        #expect(spritePanel.spriteLayerPositionForTesting == geom2.overlayLocalCocoaPosition)

        // 4. Explicit hide() (suspend / stop / VRR mode) DOES orderOut the panel cleanly!
        spritePanel.hide()
        #expect(spritePanel.isSpriteLayerHiddenForTesting)
        #expect(!spritePanel.isPanelVisibleForTesting, "hide() for suspend/stop must orderOut the panel")
    }

    // MARK: 10. Regression (Bug #2B): Full-Display Zero-Warp Roaming, Edge-Anchored Recenter & Post-Warp Sub-Pixel Motion

    @Test("Full-display roaming eliminates mid-glide warps, recenters edge-anchored windows to display center, and preserves immediate post-warp sub-pixel trackpad motion")
    func fullDisplayRoamingAndPostWarpSubPixelResponsiveness() throws {
        // 1. Full-screen sweep across 1512x982 from small 600x400 source window: ZERO mid-glide warps!
        let sourceCG = CGRect(x: 100, y: 100, width: 600, height: 400)
        let contentCG = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let mapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: contentCG,
            overlayRect: contentCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
        )
        #expect(mapping.physicalRoamingRect == CGRect(x: 20, y: 20, width: 1472, height: 942))

        var proc = CursorEventTapProcessor()
        let startSrc = CGPoint(x: 400, y: 300)
        proc.reset(initialSourcePosition: startSrc, physicalLocation: startSrc)
        let startScaled = mapping.mapSourceToScaled(startSrc, clampToContent: true)

        var phys = startSrc
        var t = 1.0
        var warpCount = 0
        var lastDec: CursorTapEventDecision?

        // Move +600pt right (phys reaches x=1000, far past sourceCG.maxX=700, still inside roam.maxX=1492)
        for _ in 0..<60 {
            phys.x += 10.0
            let rawDec = proc.process(
                input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: 10, deltaY: 0, timestamp: t),
                mapping: mapping
            )
            let dec = try #require(rawDec)
            if dec.warpTarget != nil { warpCount += 1 }
            lastDec = dec
            t += 0.008
        }
        #expect(warpCount == 0, "600pt sweep right across scaled screen must trigger ZERO mid-glide warps!")
        #expect(abs((try #require(lastDec).scaledCGPosition.x - startScaled.x) - 600.0) < 0.05)

        // Move -900pt left + +300pt down (phys reaches (100, 600), still strictly inside roam!)
        for _ in 0..<90 {
            phys.x -= 10.0
            phys.y += 300.0 / 90.0
            let rawDec = proc.process(
                input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: -10, deltaY: 3.33, timestamp: t),
                mapping: mapping
            )
            let dec = try #require(rawDec)
            if dec.warpTarget != nil { warpCount += 1 }
            lastDec = dec
            t += 0.008
        }
        #expect(warpCount == 0, "Full cross-screen sweep must trigger ZERO mid-glide warps!")
        let finalScaled = try #require(lastDec).scaledCGPosition
        #expect(abs((finalScaled.x - startScaled.x) - (-300.0)) < 0.1)
        #expect(abs((finalScaled.y - startScaled.y) - 300.0) < 0.1)

        // 2. Source window anchored at display top-left (0, 0, 400, 300): when physical cursor hits left
        //    20pt display bezel while `targetPos` is at (10, 10) (outside roam), recenter warps physical
        //    cursor to `physicalRoamingRect` center (756, 491) while `virtualSourcePosition` stays pinned!
        let edgeMapping = PointerMapping(
            sourceRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            contentRect: contentCG,
            overlayRect: contentCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
        )
        var edgeProc = CursorEventTapProcessor()
        edgeProc.reset(initialSourcePosition: CGPoint(x: 10, y: 10), physicalLocation: CGPoint(x: 30, y: 100))
        let hitBezelRaw = edgeProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 15, y: 100), deltaX: -15, deltaY: 0, timestamp: 10.0),
            mapping: edgeMapping
        )
        let hitBezelDec = try #require(hitBezelRaw)
        let recenteredTo = try #require(hitBezelDec.warpTarget, "Hitting 20pt display bezel must recenter physical cursor")
        #expect(abs(recenteredTo.x - edgeMapping.physicalRoamingRect.midX) < 0.5)
        #expect(abs(recenteredTo.y - edgeMapping.physicalRoamingRect.midY) < 0.5)
        #expect(hitBezelDec.effectiveSourcePoint.x <= 10.0)

        // 3. Gentle sub-pixel trackpad motion (`+0.4pt`, `deltaX = 0`) IMMEDIATELY after a warp MUST NOT be dropped!
        proc.reset(initialSourcePosition: startSrc, physicalLocation: CGPoint(x: 900, y: 500))
        proc.recordExternalWarp(from: CGPoint(x: 900, y: 500), to: startSrc, timestamp: 20.0)
        var subPhys = startSrc
        var subT = 20.008
        for i in 0..<10 {
            subPhys.x += 0.4
            let raw = proc.process(
                input: CursorTapEventInput(type: .mouseMoved, location: subPhys, deltaX: 0, deltaY: 0, timestamp: subT),
                mapping: mapping
            )
            let dec = try #require(raw, "Gentle 0.4pt trackpad glide immediately after warp must NEVER be dropped as warp echo (step \(i))!")
            lastDec = dec
            subT += 0.008
        }
        #expect(abs((try #require(lastDec).scaledCGPosition.x - startScaled.x) - 4.0) < 0.05)
    }

    // MARK: 11. Regression (Bug #6): Scroll Wheel & Drag in Fullscreen, Windowed & Unconfined Modes + PendingWarp Immunity

    @Test("Scroll wheel remaps, syncs hidden physical cursor, reposts notch #1, survives PendingWarp, and works in Fullscreen, Windowed, and Unconfined modes")
    func scrollWheelFullscreenWindowedUnconfinedAndPendingWarpImmunity() throws {
        let sourceCG = CGRect(x: 120, y: 140, width: 680, height: 440)
        let fullscreenCG = CGRect(x: 0, y: 0, width: 1512, height: 981)
        let windowedOverlayCG = CGRect(x: 246, y: 160, width: 1020, height: 660) // 1.5x windowed

        // --- A. Fullscreen mode (`adjustCursorSpeed == true`, physical cursor roamed outside sourceCG) ---
        let fsMapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: fullscreenCG,
            overlayRect: fullscreenCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
        )
        var fsProc = CursorEventTapProcessor()
        let startSrc = CGPoint(x: 460, y: 360)
        fsProc.reset(initialSourcePosition: startSrc, physicalLocation: startSrc)

        // Glide physical cursor far outside sourceCG (e.g. to (1160, 720) — still inside display roam bounds!)
        var phys = startSrc
        var t = 1.0
        for _ in 0..<35 {
            phys.x += 20.0
            phys.y += 10.0
            let rawMove = fsProc.process(
                input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: 20, deltaY: 10, timestamp: t),
                mapping: fsMapping
            )
            let move = try #require(rawMove)
            #expect(move.warpTarget == nil)
            t += 0.008
        }
        #expect(!fsMapping.isPointInsideSource(phys), "Physical cursor should have roamed outside sourceCG")
        let expectedScrollTarget = try #require(fsProc.virtualSourcePosition)
        #expect(fsMapping.isPointInsideSource(expectedScrollTarget))

        // Scroll notch #1 arrives while physical cursor is at `phys` (outside sourceCG):
        // MUST rewrite event.location, sync physical cursor via warpTarget, AND flag shouldRepostAfterWarp!
        let notch1Raw = fsProc.process(
            input: CursorTapEventInput(type: .scrollWheel, location: phys, deltaX: 0, deltaY: 0, timestamp: t + 0.01),
            mapping: fsMapping
        )
        let notch1 = try #require(notch1Raw)
        #expect(notch1.rewrittenEventLocation == expectedScrollTarget)
        #expect(notch1.warpTarget == expectedScrollTarget, "Scroll notch #1 must warp physical cursor onto targetPos!")
        #expect(notch1.shouldRepostAfterWarp, "Scroll notch #1 must repost after warp so WindowServer re-hit-tests target window!")
        #expect(fsProc.pendingWarp != nil)

        // Queued pre-warp notch #2 arrives 3ms later STILL carrying old `phys` while PendingWarp is in flight:
        // MUST NOT be dropped by PendingWarp, must NOT spam a duplicate warp, and MUST repost at targetPos!
        let notch2Raw = fsProc.process(
            input: CursorTapEventInput(type: .scrollWheel, location: phys, deltaX: 0, deltaY: 0, timestamp: t + 0.013),
            mapping: fsMapping
        )
        let notch2 = try #require(notch2Raw)
        #expect(notch2.rewrittenEventLocation == expectedScrollTarget)
        #expect(notch2.warpTarget == nil, "Must not spam duplicate warp while warp to same targetPos is already in flight")
        #expect(notch2.shouldRepostAfterWarp, "Pre-warp queued scroll notch #2 must still repost at targetPos")

        // Post-warp notches #3..#10 arrive at `expectedScrollTarget`: fast direct passthrough (zero warp, zero repost)!
        for i in 3...10 {
            let notchRaw = fsProc.process(
                input: CursorTapEventInput(type: .scrollWheel, location: expectedScrollTarget, deltaX: 0, deltaY: 0, timestamp: t + 0.015 + Double(i) * 0.008),
                mapping: fsMapping
            )
            let notch = try #require(notchRaw)
            #expect(notch.rewrittenEventLocation == expectedScrollTarget)
            #expect(notch.warpTarget == nil)
            #expect(!notch.shouldRepostAfterWarp)
        }

        // --- B. Windowed 1.5x mode (click-through locked): scroll + click + drag inside windowed overlay ---
        let winMapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: windowedOverlayCG,
            overlayRect: windowedOverlayCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
        )
        var winProc = CursorEventTapProcessor()
        winProc.reset(initialSourcePosition: startSrc, physicalLocation: startSrc)
        var winPhys = startSrc
        var wt = 10.0
        for _ in 0..<25 {
            winPhys.x += 20.0
            winPhys.y += 12.0
            let mvRaw = winProc.process(
                input: CursorTapEventInput(type: .mouseMoved, location: winPhys, deltaX: 20, deltaY: 12, timestamp: wt),
                mapping: winMapping
            )
            let mv = try #require(mvRaw)
            #expect(mv.warpTarget == nil)
            wt += 0.008
        }
        #expect(!winMapping.isPointInsideSource(winPhys))
        let winTarget = try #require(winProc.virtualSourcePosition)
        #expect(sourceCG.contains(winTarget))

        // Scroll in windowed overlay -> warps + reposts at exact mapped coordinate inside sourceCG!
        let winScrollRaw = winProc.process(
            input: CursorTapEventInput(type: .scrollWheel, location: winPhys, deltaX: 0, deltaY: 0, timestamp: wt + 0.01),
            mapping: winMapping
        )
        let winScroll = try #require(winScrollRaw)
        #expect(winScroll.rewrittenEventLocation == winTarget)
        #expect(winScroll.warpTarget == winTarget)
        #expect(winScroll.shouldRepostAfterWarp)

        // Click down + 200pt drag (text selection / scrollbar drag) + mouse up in windowed overlay!
        winPhys = winTarget
        let winDownRaw = winProc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: CGPoint(x: winPhys.x + 120, y: winPhys.y), deltaX: 0, deltaY: 0, timestamp: wt + 0.05),
            mapping: winMapping
        )
        let winDown = try #require(winDownRaw)
        #expect(winDown.rewrittenEventLocation == winTarget)
        #expect(winDown.warpTarget == winTarget)
        #expect(winDown.shouldRepostAfterWarp)

        var dragPhys = winTarget
        let dragStartScaledX = winDown.scaledCGPosition.x
        var dragWarps = 0
        var lastDrag: CursorTapEventDecision?
        for i in 0..<20 {
            dragPhys.x -= 10.0
            let drRaw = winProc.process(
                input: CursorTapEventInput(type: .leftMouseDragged, location: dragPhys, deltaX: -10, deltaY: 0, timestamp: wt + 0.06 + Double(i) * 0.008),
                mapping: winMapping
            )
            let dr = try #require(drRaw)
            if dr.warpTarget != nil { dragWarps += 1 }
            #expect(sourceCG.contains(dr.effectiveSourcePoint))
            lastDrag = dr
        }
        #expect(dragWarps == 0, "Dragging across windowed overlay must incur zero mid-drag warps")
        #expect(abs((try #require(lastDrag).scaledCGPosition.x - dragStartScaledX) - (-200.0)) < 0.1)

        let dragEndSource = try #require(winProc.virtualSourcePosition)
        let winUpRaw = winProc.process(
            input: CursorTapEventInput(type: .leftMouseUp, location: dragPhys, deltaX: 0, deltaY: 0, timestamp: wt + 0.25),
            mapping: winMapping
        )
        let winUp = try #require(winUpRaw)
        #expect(winUp.rewrittenEventLocation == dragEndSource)
        #expect(!winUp.shouldRepostAfterWarp, "mouseUp must sync without reposting")

        // --- C. Unconfined mode (`confineCursor == false`, `adjustCursorSpeed == true`) while inside sourceCG ---
        let freeSpeedMapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: fullscreenCG,
            overlayRect: fullscreenCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: false, adjustCursorSpeed: true)
        )
        var freeProc = CursorEventTapProcessor()
        freeProc.reset(initialSourcePosition: startSrc, physicalLocation: startSrc)
        // Move right 400pt: physical reaches 860 (outside sourceCG maxX=800), virtual is at ~640 (still inside sourceCG!)
        let freeMoveRaw = freeProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 860, y: 360), deltaX: 400, deltaY: 0, timestamp: 20.0),
            mapping: freeSpeedMapping
        )
        let freeMove = try #require(freeMoveRaw)
        #expect(!freeMove.isPointerOutsideUnconfinedSource)
        let freeScrollRaw = freeProc.process(
            input: CursorTapEventInput(type: .scrollWheel, location: CGPoint(x: 860, y: 360), deltaX: 0, deltaY: 0, timestamp: 20.01),
            mapping: freeSpeedMapping
        )
        let freeScroll = try #require(freeScrollRaw)
        #expect(freeScroll.warpTarget == freeMove.effectiveSourcePoint)
        #expect(freeScroll.shouldRepostAfterWarp)

        // --- D. PendingWarp NEVER drops `.scrollWheel`, `.leftMouseDown`, or `.leftMouseDragged` ---
        var pwProc = CursorEventTapProcessor()
        let ptA = CGPoint(x: 1100, y: 700)
        let ptB = CGPoint(x: 460, y: 360)
        pwProc.reset(initialSourcePosition: ptB, physicalLocation: ptA)
        pwProc.recordExternalWarp(from: ptA, to: ptB, timestamp: 30.0)
        let pwScrollB = pwProc.process(input: CursorTapEventInput(type: .scrollWheel, location: ptB, deltaX: 0, deltaY: 0, timestamp: 30.005), mapping: fsMapping)
        #expect(pwScrollB != nil)
        pwProc.recordExternalWarp(from: ptA, to: ptB, timestamp: 30.1)
        let pwScrollA = pwProc.process(input: CursorTapEventInput(type: .scrollWheel, location: ptA, deltaX: 0, deltaY: 0, timestamp: 30.105), mapping: fsMapping)
        #expect(pwScrollA != nil)
        pwProc.recordExternalWarp(from: ptA, to: ptB, timestamp: 30.2)
        let pwDownB = pwProc.process(input: CursorTapEventInput(type: .leftMouseDown, location: ptB, deltaX: 0, deltaY: 0, timestamp: 30.205), mapping: fsMapping)
        #expect(pwDownB != nil)
        pwProc.recordExternalWarp(from: ptA, to: ptB, timestamp: 30.3)
        let pwDragB = pwProc.process(input: CursorTapEventInput(type: .leftMouseDragged, location: CGPoint(x: ptB.x + 4, y: ptB.y), deltaX: 4, deltaY: 0, timestamp: 30.305), mapping: fsMapping)
        #expect(pwDragB != nil)

        // --- E. EventTapCallbackBox passes reposted magic-tag scroll events straight through untouched ---
        let controller = CursorOverlayController(presentationMode: .externalCompositor)
        defer { controller.stop() }
        controller.activateForEventTapTesting(
            configuration: CursorMappingConfiguration(
                sourceCGRect: sourceCG,
                destinationCGRect: fullscreenCG,
                overlayCGRect: fullscreenCG,
                backingScaleFactor: 2.0,
                settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
            ),
            displays: [Self.primaryRetina],
            initialPointer: startSrc
        )
        let box = EventTapCallbackBox(controller: controller)
        let dummyProxy = OpaquePointer(bitPattern: 0x1000)!
        let taggedScroll = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -24,
            wheel2: 0,
            wheel3: 0
        ))
        let taggedLoc = CGPoint(x: 333, y: 222)
        taggedScroll.location = taggedLoc
        taggedScroll.setIntegerValueField(.eventSourceUserData, value: CursorOverlayController.repostedEventMagicTag)
        let result = box.invoke(proxy: dummyProxy, type: .scrollWheel, event: taggedScroll)
        #expect(result != nil)
        #expect(taggedScroll.location == taggedLoc, "Reposted magic-tag event must pass straight through untouched")
    }
}
