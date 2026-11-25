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

    // MARK: 12. Regression (Bug #2A): Floating Toolbar & Profiler HUD Direct Chrome Interaction

    @Test("Hovering, clicking, and dragging inside interactiveChromeRects (floating toolbar / Profiler HUD) bypasses source remapping at 1:1 native screen points and cleanly resumes scaled tracking on exit")
    func interactiveChromeRectsToolbarAndProfilerHUDDirectInteraction() throws {
        let sourceCG = CGRect(x: 120, y: 140, width: 680, height: 440)
        let contentCG = CGRect(x: 0, y: 0, width: 1512, height: 981)
        let toolbarCG = CGRect(x: 546, y: 42, width: 420, height: 42)
        let profilerCG = CGRect(x: 16, y: 56, width: 296, height: 110)

        let mapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: contentCG,
            overlayRect: contentCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
        )

        var proc = CursorEventTapProcessor()
        proc.interactiveChromeRects = [toolbarCG, profilerCG]
        // Start slightly below toolbar in scaled mode (`scaledY ~= 100`, `scaledX ~= 756`).
        let startScaled = CGPoint(x: 756, y: 100)
        let startSrc = mapping.mapScaledToSource(startScaled, clampToSource: true)
        var phys = CGPoint(x: 400, y: 500) // Hidden physical cursor drifted far away!
        proc.reset(initialSourcePosition: startSrc, physicalLocation: phys)

        // 1. Move up 35pt visually (`scaledY = 100 -> 65`) right onto MetalPie's floating toolbar button!
        phys.y -= 35.0
        let enterRaw = proc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: 0, deltaY: -35, timestamp: 1.0),
            mapping: mapping
        )
        let enterDec = try #require(enterRaw)
        #expect(enterDec.interactionMode == .directChrome)
        #expect(enterDec.isDirectChromeInteraction)
        #expect(!enterDec.isScaledSpriteVisible, "Scaled sprite must hide over toolbar so native OS cursor is never doubled!")
        let entryPt = try #require(enterDec.warpTarget, "Entering toolbar must warp physical cursor onto visual toolbar coordinate")
        #expect(toolbarCG.contains(entryPt))
        #expect(abs(entryPt.x - 756.0) < 1.0)
        #expect(abs(entryPt.y - 65.0) < 1.0)
        #expect(enterDec.rewrittenEventLocation == entryPt)

        // 2. Physical cursor lands at `entryPt` -> move 1:1 across toolbar buttons (zero `1/scale` distortion!).
        phys = entryPt
        let glideToolbarRaw = proc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: phys.x + 24, y: phys.y), deltaX: 24, deltaY: 0, timestamp: 1.02),
            mapping: mapping
        )
        let glideToolbar = try #require(glideToolbarRaw)
        #expect(glideToolbar.interactionMode == .directChrome)
        #expect(glideToolbar.rewrittenEventLocation == nil, "Inside toolbar, events must pass 1:1 natively without source remapping!")
        #expect(glideToolbar.warpTarget == nil)
        #expect(abs(glideToolbar.scaledCGPosition.x - (entryPt.x + 24.0)) < 0.01)

        // 3. Click toolbar button (`leftMouseDown` -> `leftMouseUp`): lands at exact screen button point, NOT sourceRect!
        let buttonPt = CGPoint(x: entryPt.x + 24, y: entryPt.y)
        let clickDownRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: buttonPt, deltaX: 0, deltaY: 0, timestamp: 1.04),
            mapping: mapping
        )
        let clickDown = try #require(clickDownRaw)
        #expect(clickDown.interactionMode == .directChrome)
        #expect(clickDown.rewrittenEventLocation == nil)
        #expect(clickDown.effectiveSourcePoint == buttonPt)

        let clickUpRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseUp, location: buttonPt, deltaX: 0, deltaY: 0, timestamp: 1.06),
            mapping: mapping
        )
        let clickUp = try #require(clickUpRaw)
        #expect(clickUp.interactionMode == .directChrome)
        #expect(clickUp.rewrittenEventLocation == nil)

        // 4. Move DOWN off the toolbar (`y = 110`, outside `toolbarCG.maxY = 84`): seamlessly resumes `.scaled`!
        let exitPt = CGPoint(x: buttonPt.x, y: 110)
        let exitDecRaw = proc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: exitPt, deltaX: 0, deltaY: 45, timestamp: 1.08),
            mapping: mapping
        )
        let exitDec = try #require(exitDecRaw)
        #expect(exitDec.interactionMode == .scaled)
        #expect(exitDec.isScaledSpriteVisible)
        let expectedReentrySrc = mapping.constrainSourcePoint(mapping.mapScaledToSource(exitPt, clampToSource: true)).point
        #expect(abs(exitDec.effectiveSourcePoint.x - expectedReentrySrc.x) < 0.05)
        #expect(abs(exitDec.effectiveSourcePoint.y - expectedReentrySrc.y) < 0.05)
        #expect(abs(exitDec.scaledCGPosition.x - exitPt.x) < 0.5)
        #expect(abs(exitDec.scaledCGPosition.y - exitPt.y) < 0.5)

        // 5. Stationary click directly over newly revealed chrome (while hidden physical cursor is drifted far away!):
        //    Click #1 MUST warp to exact visual chrome point AND flag `shouldRepostAfterWarp == true`!
        let hudClickVisual = CGPoint(x: profilerCG.midX, y: profilerCG.midY)
        let hudClickSrc = mapping.mapScaledToSource(hudClickVisual, clampToSource: true)
        proc.reset(initialSourcePosition: hudClickSrc, physicalLocation: CGPoint(x: 900, y: 700))
        let firstClickHUDRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: CGPoint(x: 900, y: 700), deltaX: 0, deltaY: 0, timestamp: 2.0),
            mapping: mapping
        )
        let firstClickHUD = try #require(firstClickHUDRaw)
        #expect(firstClickHUD.interactionMode == .directChrome)
        #expect(firstClickHUD.shouldRepostAfterWarp, "Click #1 onto toolbar/HUD when physical cursor drifted must repost after warp!")
        #expect(profilerCG.contains(try #require(firstClickHUD.warpTarget)))
        #expect(profilerCG.contains(try #require(firstClickHUD.rewrittenEventLocation)))
        #expect(proc.activeChromeDrag)

        // 6. Dragging Profiler HUD across screen (starting from warped HUD click point and moving far outside
        //    initial `profilerCG` rect!) MUST stay in `.directChrome` until `leftMouseUp`!
        let dragStep1 = CGPoint(x: hudClickVisual.x + 100, y: hudClickVisual.y + 80)
        _ = proc.process(
            input: CursorTapEventInput(type: .leftMouseDragged, location: dragStep1, deltaX: 100, deltaY: 80, timestamp: 2.02),
            mapping: mapping
        )
        let dragMidPt = CGPoint(x: 620, y: 420) // Far outside initial `profilerCG`!
        let dragHUDRaw = proc.process(
            input: CursorTapEventInput(
                type: .leftMouseDragged,
                location: dragMidPt,
                deltaX: Double(dragMidPt.x - dragStep1.x),
                deltaY: Double(dragMidPt.y - dragStep1.y),
                timestamp: 2.04
            ),
            mapping: mapping
        )
        let dragHUD = try #require(dragHUDRaw)
        #expect(dragHUD.interactionMode == .directChrome, "Active Profiler HUD drag must stay in directChrome even ahead of panel frame update!")
        #expect(!dragHUD.isScaledSpriteVisible)
        #expect(dragHUD.rewrittenEventLocation == nil)

        let dragUpRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseUp, location: dragMidPt, deltaX: 0, deltaY: 0, timestamp: 2.08),
            mapping: mapping
        )
        let dragUp = try #require(dragUpRaw)
        #expect(dragUp.interactionMode == .directChrome)
        #expect(!proc.activeChromeDrag)

        // Next move outside chrome cleanly resumes `.scaled`!
        let afterHudDragRaw = proc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 624, y: 424), deltaX: 4, deltaY: 4, timestamp: 2.10),
            mapping: mapping
        )
        let afterHudDrag = try #require(afterHudDragRaw)
        #expect(afterHudDrag.interactionMode == .scaled)
        #expect(afterHudDrag.isScaledSpriteVisible)

        // 7. Letterboxed Fit mode: toolbar sitting inside top black letterbox bar (`contentRect.minY = 66`, `toolbar.maxY = 52`)
        //    is STILL reachable by pushing upward past top of content!
        let letterboxMapping = PointerMapping(
            sourceRect: CGRect(x: 100, y: 100, width: 640, height: 360),
            contentRect: CGRect(x: 0, y: 66, width: 1512, height: 850),
            overlayRect: CGRect(x: 0, y: 0, width: 1512, height: 981),
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
        )
        let letterboxToolbar = CGRect(x: 546, y: 10, width: 420, height: 42)
        var lbProc = CursorEventTapProcessor()
        lbProc.interactiveChromeRects = [letterboxToolbar]
        let lbTopSrc = CGPoint(x: 420, y: letterboxMapping.confinementRect.minY)
        lbProc.reset(initialSourcePosition: lbTopSrc, physicalLocation: CGPoint(x: 756, y: 400))
        // Push up 20pt past content top (`66 - 20 = 46` -> lands right inside `letterboxToolbar` `[10..52]`!)
        let lbEnterRaw = lbProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 756, y: 380), deltaX: 0, deltaY: -20, timestamp: 3.0),
            mapping: letterboxMapping
        )
        let lbEnter = try #require(lbEnterRaw)
        #expect(lbEnter.interactionMode == .directChrome)
        #expect(letterboxToolbar.contains(try #require(lbEnter.warpTarget)))
    }

    // MARK: 13. Regression (Bug #2B): Windowed Mode Outside-Overlay Escape & Fullscreen Top-Edge Stability

    @Test("Windowed mode escapes smoothly outside overlayRect to macOS Menu Bar/Desktop and re-enters cleanly; Fullscreen mode keeps top edge cleanly in scaled mode without Menu Bar passthrough while 3D Game Mode stays strictly confined")
    func windowedOutsideOverlayAndFullscreenMenuBarPassthrough() throws {
        let sourceCG = CGRect(x: 120, y: 140, width: 680, height: 440)
        let windowedOverlayCG = CGRect(x: 246, y: 160, width: 1020, height: 660) // 1.5x windowed

        // --- A. Windowed Mode (`setPresentationIsWindowed(true)`) ---
        let winMapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: windowedOverlayCG,
            overlayRect: windowedOverlayCG,
            displays: Self.triMonitorDisplays,
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true),
            threeDGameMode: false
        )

        var winProc = CursorEventTapProcessor()
        winProc.isPresentationWindowed = true
        let nearTopScaled = CGPoint(x: 600, y: 166) // 6pt below windowed overlay top edge (`y = 160`)
        let nearTopSrc = winMapping.mapScaledToSource(nearTopScaled, clampToSource: true)
        var winPhys = CGPoint(x: 500, y: 400)
        winProc.reset(initialSourcePosition: nearTopSrc, physicalLocation: winPhys)

        // Push UP 12pt past `overlayRect.minY = 160` -> escapes cleanly to `.outsideWindowedOverlay`!
        winPhys.y -= 12.0
        let escapeUpRaw = winProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: winPhys, deltaX: 0, deltaY: -12, timestamp: 1.0),
            mapping: winMapping
        )
        let escapeUp = try #require(escapeUpRaw)
        #expect(escapeUp.interactionMode == .outsideWindowedOverlay)
        #expect(!escapeUp.isScaledSpriteVisible)
        let exitPt = try #require(escapeUp.warpTarget)
        #expect(!windowedOverlayCG.contains(exitPt), "Windowed escape warp must land outside overlayRect")
        #expect(exitPt.y < windowedOverlayCG.minY)

        // Move up to macOS Menu Bar `(600, 12)` and click -> 1:1 native passthrough!
        let menuMoveRaw = winProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 600, y: 12), deltaX: 0, deltaY: -140, timestamp: 1.05),
            mapping: winMapping
        )
        let menuMove = try #require(menuMoveRaw)
        #expect(menuMove.interactionMode == .outsideWindowedOverlay)
        #expect(menuMove.rewrittenEventLocation == nil)
        #expect(menuMove.warpTarget == nil)

        let menuClickRaw = winProc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: CGPoint(x: 600, y: 12), deltaX: 0, deltaY: 0, timestamp: 1.06),
            mapping: winMapping
        )
        let menuClick = try #require(menuClickRaw)
        #expect(menuClick.interactionMode == .outsideWindowedOverlay)
        #expect(menuClick.rewrittenEventLocation == nil)

        // While external mouse button is held (e.g. dragging another app window across overlayRect), MUST NOT hijack into `.scaled`!
        let externalDragAcrossRaw = winProc.process(
            input: CursorTapEventInput(type: .leftMouseDragged, location: CGPoint(x: 600, y: 300), deltaX: 0, deltaY: 288, timestamp: 1.08),
            mapping: winMapping
        )
        let externalDragAcross = try #require(externalDragAcrossRaw)
        #expect(externalDragAcross.interactionMode == .outsideWindowedOverlay, "Dragging an external window across windowed overlay must not hijack drag!")
        _ = winProc.process(
            input: CursorTapEventInput(type: .leftMouseUp, location: CGPoint(x: 600, y: 120), deltaX: 0, deltaY: -180, timestamp: 1.10),
            mapping: winMapping
        )

        // Move freely back into `overlayRect` at `(600, 220)` -> cleanly re-enters `.scaled` at exact `mapScaledToSource`!
        let reentryPt = CGPoint(x: 600, y: 220)
        let reenterRaw = winProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: reentryPt, deltaX: 0, deltaY: 100, timestamp: 1.12),
            mapping: winMapping
        )
        let reenter = try #require(reenterRaw)
        #expect(reenter.interactionMode == .scaled)
        #expect(reenter.isScaledSpriteVisible)
        let expectedSrc = winMapping.constrainSourcePoint(winMapping.mapScaledToSource(reentryPt, clampToSource: true)).point
        #expect(abs(reenter.effectiveSourcePoint.x - expectedSrc.x) < 0.05)
        #expect(abs(reenter.effectiveSourcePoint.y - expectedSrc.y) < 0.05)

        // Verify `CursorOverlayController.setPresentationIsWindowed(true)` + `updateInteractiveChromeRects` via EventTapCallbackBox!
        let controller = CursorOverlayController(presentationMode: .externalCompositor)
        defer { controller.stop() }
        controller.setPresentationIsWindowed(true)
        controller.updateInteractiveChromeRects([CGRect(x: 546, y: 170, width: 420, height: 42)])
        controller.activateForEventTapTesting(
            configuration: CursorMappingConfiguration(
                sourceCGRect: sourceCG,
                destinationCGRect: windowedOverlayCG,
                overlayCGRect: windowedOverlayCG,
                backingScaleFactor: 2.0,
                settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
            ),
            displays: Self.triMonitorDisplays,
            initialPointer: nearTopSrc
        )
        let box = EventTapCallbackBox(controller: controller)
        let dummyProxy = OpaquePointer(bitPattern: 0x1000)!
        let evMoveOut = try #require(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: nearTopSrc.x, y: nearTopSrc.y - 25),
            mouseButton: .left
        ))
        _ = box.invoke(proxy: dummyProxy, type: .mouseMoved, event: evMoveOut)
        #expect(!controller.currentState.isVisible, "Escaping windowed overlay via controller API must hide scaled sprite!")
        #expect(controller.currentState.scaledCGPosition.y < windowedOverlayCG.minY)

        // --- B. Fullscreen Mode Top Edge (Primary 37pt notch & External DELL Negative-CG-Y 25pt):
        //        OverlayPanel covers macOS's top Menu Bar cleanly (level 98 > 24), so pushing upward at the
        //        top edge in Fullscreen mode MUST stay cleanly in `.scaled` and NEVER spuriously trigger
        //        `.menuBarPassthrough` (which previously fought MetalPie's top floating toolbar!).
        let fsOverlayCG = CGRect(x: 0, y: 0, width: 1512, height: 981)
        let fsMapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: fsOverlayCG,
            overlayRect: fsOverlayCG,
            displays: Self.triMonitorDisplays,
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true),
            threeDGameMode: false
        )
        var fsProc = CursorEventTapProcessor()
        fsProc.isPresentationWindowed = false
        fsProc.displayMenuBarHeights = [Self.primaryRetina.id: 37.0, Self.externalDELLNegativeCGY.id: 25.0]
        let topEdgeSrc = CGPoint(x: 400, y: fsMapping.confinementRect.minY)
        fsProc.reset(initialSourcePosition: topEdgeSrc, physicalLocation: CGPoint(x: 500, y: 300))

        // Hovering near top inside scaled app (moving horizontally) stays in `.scaled`.
        let stayScaledRaw = fsProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 510, y: 300), deltaX: 10, deltaY: 0, timestamp: 10.0),
            mapping: fsMapping
        )
        let stayScaled = try #require(stayScaledRaw)
        #expect(stayScaled.interactionMode == .scaled)
        #expect(stayScaled.isScaledSpriteVisible)

        // Repeated upward pushes against top edge in Fullscreen mode MUST remain in `.scaled` (never `.menuBarPassthrough`!).
        var fsPhysY: CGFloat = 300.0
        for step in 0..<6 {
            fsPhysY -= 15.0
            let pushUpRaw = fsProc.process(
                input: CursorTapEventInput(
                    type: .mouseMoved,
                    location: CGPoint(x: 510, y: fsPhysY),
                    deltaX: 0,
                    deltaY: -15,
                    timestamp: 10.02 + Double(step) * 0.01
                ),
                mapping: fsMapping
            )
            let pushUp = try #require(pushUpRaw)
            #expect(pushUp.interactionMode == .scaled, "Fullscreen upward push must NOT trigger menuBarPassthrough (step \(step))!")
            #expect(pushUp.isScaledSpriteVisible)
            #expect(sourceCG.contains(pushUp.effectiveSourcePoint))
        }

        // Also verify with `adjustCursorSpeed == false` in Fullscreen mode!
        let fsRawMapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: fsOverlayCG,
            overlayRect: fsOverlayCG,
            displays: Self.triMonitorDisplays,
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: false),
            threeDGameMode: false
        )
        var fsRawProc = CursorEventTapProcessor()
        fsRawProc.isPresentationWindowed = false
        fsRawProc.displayMenuBarHeights = [Self.primaryRetina.id: 37.0]
        fsRawProc.reset(initialSourcePosition: topEdgeSrc, physicalLocation: topEdgeSrc)
        let fsRawPushRaw = fsRawProc.process(
            input: CursorTapEventInput(
                type: .mouseMoved,
                location: CGPoint(x: 400, y: fsRawMapping.confinementRect.minY - 24),
                deltaX: 0,
                deltaY: -24,
                timestamp: 15.0
            ),
            mapping: fsRawMapping
        )
        let fsRawPush = try #require(fsRawPushRaw)
        #expect(fsRawPush.interactionMode == .scaled, "Fullscreen upward push without speed compensation must NOT trigger menuBarPassthrough!")
        #expect(fsRawPush.isScaledSpriteVisible)

        // External DELL negative-CG-Y (`minY = -720`, menu bar height = 25pt): pushing up in Fullscreen ALSO stays in `.scaled`!
        let dellSource = CGRect(x: 1620, y: -620, width: 680, height: 440)
        let dellOverlay = CGRect(x: 1512, y: -720, width: 1280, height: 719)
        let dellMapping = PointerMapping(
            sourceRect: dellSource,
            contentRect: dellOverlay,
            overlayRect: dellOverlay,
            displays: Self.triMonitorDisplays,
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
        )
        var dellProc = CursorEventTapProcessor()
        dellProc.isPresentationWindowed = false
        dellProc.displayMenuBarHeights = [Self.externalDELLNegativeCGY.id: 25.0]
        dellProc.reset(
            initialSourcePosition: CGPoint(x: 1960, y: dellMapping.confinementRect.minY),
            physicalLocation: CGPoint(x: 2000, y: -400)
        )
        let dellPushRaw = dellProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 2000, y: -430), deltaX: 0, deltaY: -30, timestamp: 20.0),
            mapping: dellMapping
        )
        let dellPush = try #require(dellPushRaw)
        #expect(dellPush.interactionMode == .scaled, "External display Fullscreen upward push must stay cleanly in `.scaled`!")
        #expect(dellPush.isScaledSpriteVisible)
        #expect(dellSource.contains(dellPush.effectiveSourcePoint))

        // Exiting `.directChrome` upward into the top 37pt band in Fullscreen MUST return to `.scaled`, NOT `.menuBarPassthrough`!
        let topToolbarCG = CGRect(x: 546, y: 38, width: 420, height: 42)
        fsProc.interactiveChromeRects = [topToolbarCG]
        fsProc.reset(initialSourcePosition: CGPoint(x: 756, y: 55), physicalLocation: CGPoint(x: 756, y: 55))
        fsProc.interactionMode = .directChrome
        let exitUpFromToolbarRaw = fsProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 756, y: 12), deltaX: 0, deltaY: -43, timestamp: 25.0),
            mapping: fsMapping
        )
        let exitUpFromToolbar = try #require(exitUpFromToolbarRaw)
        #expect(exitUpFromToolbar.interactionMode == .scaled, "Exiting toolbar upward in Fullscreen must transition to `.scaled`, never `.menuBarPassthrough`!")
        #expect(exitUpFromToolbar.isScaledSpriteVisible)

        // --- C. 3D Game Mode MUST stay strictly confined (no windowed escape, no menu-bar passthrough!) ---
        let game3DMapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: fsOverlayCG,
            overlayRect: fsOverlayCG,
            displays: Self.triMonitorDisplays,
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true),
            threeDGameMode: true
        )
        var gameProc = CursorEventTapProcessor()
        gameProc.isPresentationWindowed = true // Even if windowed flag is set, 3D Game Mode locks strictly!
        gameProc.reset(
            initialSourcePosition: CGPoint(x: 400, y: game3DMapping.confinementRect.minY),
            physicalLocation: CGPoint(x: 400, y: game3DMapping.confinementRect.minY)
        )
        let gamePushRaw = gameProc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: CGPoint(x: 400, y: game3DMapping.confinementRect.minY - 40), deltaX: 0, deltaY: -40, timestamp: 30.0),
            mapping: game3DMapping
        )
        let gamePush = try #require(gamePushRaw)
        #expect(gamePush.interactionMode == .scaled, "3D Game Mode must stay strictly confined and never escape to Menu Bar or desktop!")
        #expect(sourceCG.contains(gamePush.effectiveSourcePoint))
    }

    // MARK: 14. Regression (Bug #5): Window Edge Resize Dragging (Inward & Outward) & Titlebar Drag

    @Test("Window border-resize and titlebar drags move freely BOTH inward and outward past old sourceRect with live physical cursor sync and zero snap-back on mouseUp")
    func windowBorderResizeInwardOutwardAndTitlebarDrag() throws {
        let sourceCG = CGRect(x: 200, y: 160, width: 600, height: 400) // x: [200..800], y: [160..560]
        let overlayCG = CGRect(x: 0, y: 0, width: 1512, height: 981)
        let mapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: overlayCG,
            overlayRect: overlayCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true),
            threeDGameMode: false
        )

        // Verify border/titlebar zone helper accuracy.
        #expect(mapping.isPointInWindowResizeOrTitlebarZone(CGPoint(x: 798, y: 360))) // Right border (2pt)
        #expect(mapping.isPointInWindowResizeOrTitlebarZone(CGPoint(x: 203, y: 360))) // Left border (3pt)
        #expect(mapping.isPointInWindowResizeOrTitlebarZone(CGPoint(x: 500, y: 557))) // Bottom border (3pt)
        #expect(mapping.isPointInWindowResizeOrTitlebarZone(CGPoint(x: 500, y: 185))) // Titlebar band (25pt < 32pt)
        #expect(!mapping.isPointInWindowResizeOrTitlebarZone(CGPoint(x: 500, y: 360))) // Interior content!

        // --- A. Outward Right-Border Resize Drag (`adjustCursorSpeed == true`) ---
        var proc = CursorEventTapProcessor()
        let rightEdgeGrab = CGPoint(x: 798, y: 360) // 2pt inside right edge of `sourceCG`
        proc.reset(initialSourcePosition: rightEdgeGrab, physicalLocation: rightEdgeGrab)

        let downDecRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: rightEdgeGrab, deltaX: 0, deltaY: 0, timestamp: 1.0),
            mapping: mapping
        )
        let downDec = try #require(downDecRaw)
        #expect(proc.activeWindowBorderDrag, "Grabbing within 6pt of window edge must arm activeWindowBorderDrag")
        #expect(downDec.effectiveSourcePoint == rightEdgeGrab)

        var phys = rightEdgeGrab
        var t = 1.02
        var syncWarpsDuringOutward = 0
        var lastOutward: CursorTapEventDecision?
        // Drag 300pt right (outward past `sourceCG.maxX = 800`!).
        for _ in 0..<15 {
            phys.x += 20.0
            let decRaw = proc.process(
                input: CursorTapEventInput(type: .leftMouseDragged, location: phys, deltaX: 20, deltaY: 0, timestamp: t),
                mapping: mapping
            )
            let dec = try #require(decRaw)
            if let wt = dec.warpTarget {
                syncWarpsDuringOutward += 1
                phys = wt // Simulate OS cursor warping to synced resize target!
            }
            lastOutward = dec
            t += 0.016
        }
        let finalOutward = try #require(lastOutward)
        #expect(finalOutward.effectiveSourcePoint.x > sourceCG.maxX + 100.0,
                "Outward border resize drag MUST NOT clamp to old sourceRect.maxX (\(sourceCG.maxX)); got \(finalOutward.effectiveSourcePoint.x)")
        #expect(syncWarpsDuringOutward > 0,
                "Outward border resize drag MUST sync physical OS cursor so macOS WindowServer resize loop tracks smoothly!")

        // Release mouse button: `leftMouseUp` MUST preserve the outward coordinate (never snap back inside old sourceRect!).
        let outwardUpRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseUp, location: phys, deltaX: 0, deltaY: 0, timestamp: t + 0.02),
            mapping: mapping
        )
        let outwardUp = try #require(outwardUpRaw)
        #expect(outwardUp.effectiveSourcePoint.x > sourceCG.maxX + 100.0,
                "leftMouseUp must commit the outward border coordinate rather than snapping back to old sourceRect!")
        #expect(!proc.activeWindowBorderDrag, "activeWindowBorderDrag must clear on leftMouseUp")

        // --- B. Inward Right-Border Resize Drag (`adjustCursorSpeed == true`) ---
        proc.reset(initialSourcePosition: rightEdgeGrab, physicalLocation: rightEdgeGrab)
        _ = proc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: rightEdgeGrab, deltaX: 0, deltaY: 0, timestamp: 5.0),
            mapping: mapping
        )
        #expect(proc.activeWindowBorderDrag)
        phys = rightEdgeGrab
        t = 5.02
        var syncWarpsDuringInward = 0
        var lastInward: CursorTapEventDecision?
        for _ in 0..<12 {
            phys.x -= 20.0
            let decRaw = proc.process(
                input: CursorTapEventInput(type: .leftMouseDragged, location: phys, deltaX: -20, deltaY: 0, timestamp: t),
                mapping: mapping
            )
            let dec = try #require(decRaw)
            if let wt = dec.warpTarget {
                syncWarpsDuringInward += 1
                phys = wt
            }
            lastInward = dec
            t += 0.016
        }
        let finalInward = try #require(lastInward)
        #expect(finalInward.effectiveSourcePoint.x < rightEdgeGrab.x - 80.0,
                "Inward border resize drag must move smoothly inward; got \(finalInward.effectiveSourcePoint.x)")
        #expect(syncWarpsDuringInward > 0, "Inward border resize drag must keep physical OS cursor synced!")
        _ = proc.process(
            input: CursorTapEventInput(type: .leftMouseUp, location: phys, deltaX: 0, deltaY: 0, timestamp: t + 0.02),
            mapping: mapping
        )
        #expect(!proc.activeWindowBorderDrag)

        // --- C. Outward Left-Border & Titlebar Move Drag (clamped only to display bounds, never old sourceRect!) ---
        let titlebarGrab = CGPoint(x: 450, y: 175) // 15pt from top edge (titlebar band)
        proc.reset(initialSourcePosition: titlebarGrab, physicalLocation: titlebarGrab)
        _ = proc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: titlebarGrab, deltaX: 0, deltaY: 0, timestamp: 10.0),
            mapping: mapping
        )
        #expect(proc.activeWindowBorderDrag, "Titlebar drag must also arm activeWindowBorderDrag")
        // Drag far beyond left & top of old `sourceCG` (past x=200 and y=160), verifying display clamping only!
        let dragFarOutRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseDragged, location: CGPoint(x: 50, y: 20), deltaX: -400, deltaY: -155, timestamp: 10.02),
            mapping: mapping
        )
        let dragFarOut = try #require(dragFarOutRaw)
        #expect(dragFarOut.effectiveSourcePoint.y < sourceCG.minY, "Titlebar drag must move freely above old sourceRect.minY")
        #expect(Self.primaryRetina.cgBounds.contains(dragFarOut.effectiveSourcePoint), "Border/titlebar drag must stay within host display bounds")

        // --- D. Outward Border Resize Drag with `adjustCursorSpeed == false` also bypasses old sourceRect clamp! ---
        let uncompMapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: overlayCG,
            overlayRect: overlayCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: false),
            threeDGameMode: false
        )
        var uncompProc = CursorEventTapProcessor()
        uncompProc.reset(initialSourcePosition: rightEdgeGrab, physicalLocation: rightEdgeGrab)
        _ = uncompProc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: rightEdgeGrab, deltaX: 0, deltaY: 0, timestamp: 20.0),
            mapping: uncompMapping
        )
        #expect(uncompProc.activeWindowBorderDrag)
        let uncompOutRaw = uncompProc.process(
            input: CursorTapEventInput(type: .leftMouseDragged, location: CGPoint(x: 960, y: 360), deltaX: 162, deltaY: 0, timestamp: 20.02),
            mapping: uncompMapping
        )
        let uncompOut = try #require(uncompOutRaw)
        #expect(uncompOut.effectiveSourcePoint.x == 960.0)
        _ = uncompProc.process(
            input: CursorTapEventInput(type: .leftMouseUp, location: CGPoint(x: 960, y: 360), deltaX: 0, deltaY: 0, timestamp: 20.04),
            mapping: uncompMapping
        )
        #expect(!uncompProc.activeWindowBorderDrag)
    }

    // MARK: 15. Regression (Bug #1): WindowLifecycleWatcher Fullscreen Video Selection & Replacement Helper

    @Test("WindowLifecycleWatcher.selectFrontmostWindow prefers display-covering fullscreen video window over higher z-order layer-0 helper bars, and findFullscreenReplacementWindow locates newly created HTML5/native fullscreen windows")
    func windowLifecycleFullscreenVideoSelectionAndReplacementHelper() throws {
        let displays = [Self.primaryRetina, Self.externalDELLNegativeCGY]
        let safariPID: Int32 = 4242

        // Scenario A: Safari HTML5 video fullscreen — tiny layer-0 media-control bar sits HIGHER in z-order
        // than the display-covering fullscreen video window!
        let safariHelperBar = RawWindowSnapshot(
            windowID: 5001,
            pid: safariPID,
            ownerName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            title: "Media Controls",
            cgBounds: CGRect(x: 556, y: 890, width: 400, height: 72),
            layer: 0
        )
        let safariFullscreenVideo = RawWindowSnapshot(
            windowID: 5002,
            pid: safariPID,
            ownerName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            title: "YouTube — Fullscreen",
            cgBounds: Self.primaryRetina.cgBounds, // 1512x982 display-covering!
            layer: 0
        )
        let safariDesktopTab = RawWindowSnapshot(
            windowID: 5000,
            pid: safariPID,
            ownerName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            title: "YouTube",
            cgBounds: CGRect(x: 100, y: 100, width: 1100, height: 700),
            layer: 0
        )

        let pickedFullscreen = WindowLifecycleWatcher.selectFrontmostWindow(
            forPID: safariPID,
            from: [safariHelperBar, safariFullscreenVideo, safariDesktopTab],
            displays: displays
        )
        #expect(pickedFullscreen?.windowID == 5002,
                "selectFrontmostWindow MUST prefer display-covering fullscreen video window (5002) over smaller layer-0 helper bar (5001)!")

        // Scenario B: Raised-layer fullscreen player (e.g., IINA / VLC / Wine at layer > 0) behind a layer-0 helper bar!
        let iinaPID: Int32 = 5151
        let iinaOSCBar = RawWindowSnapshot(
            windowID: 6001,
            pid: iinaPID,
            ownerName: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            title: "OSC",
            cgBounds: CGRect(x: 400, y: 860, width: 700, height: 90),
            layer: 0
        )
        let iinaFullscreenRaised = RawWindowSnapshot(
            windowID: 6002,
            pid: iinaPID,
            ownerName: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            title: "Movie.mkv",
            cgBounds: Self.primaryRetina.cgBounds,
            layer: 24
        )
        let pickedIINA = WindowLifecycleWatcher.selectFrontmostWindow(
            forPID: iinaPID,
            from: [iinaOSCBar, iinaFullscreenRaised],
            displays: displays
        )
        #expect(pickedIINA?.windowID == 6002,
                "selectFrontmostWindow MUST prefer display-covering raised fullscreen window (6002) over layer-0 OSC bar (6001)!")

        // Scenario C: Non-fullscreen desktop app with tiny layer-0 helper bar (120x80) ahead of substantial main window (900x600).
        let appPID: Int32 = 6262
        let tinyBar = RawWindowSnapshot(
            windowID: 7001,
            pid: appPID,
            ownerName: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            title: "Status Bubble",
            cgBounds: CGRect(x: 100, y: 760, width: 160, height: 70),
            layer: 0
        )
        let mainWin = RawWindowSnapshot(
            windowID: 7002,
            pid: appPID,
            ownerName: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            title: "Main Browser Window",
            cgBounds: CGRect(x: 100, y: 100, width: 1000, height: 680),
            layer: 0
        )
        let pickedSubstantial = WindowLifecycleWatcher.selectFrontmostWindow(
            forPID: appPID,
            from: [tinyBar, mainWin],
            displays: displays
        )
        #expect(pickedSubstantial?.windowID == 7002,
                "selectFrontmostWindow MUST prefer substantial (>=200x150) layer-0 window over tiny 64x64 helper bar!")

        // Scenario D: `findFullscreenReplacementWindow(forPID:excluding:from:displays:)` locates the new HTML5
        // fullscreen window (5002), excluding old desktop window (5000) and ignoring helper bars & other PIDs!
        let otherAppFullscreen = RawWindowSnapshot(
            windowID: 9999,
            pid: 9999,
            ownerName: "OtherApp",
            cgBounds: Self.primaryRetina.cgBounds,
            layer: 0
        )
        let replacement = WindowLifecycleWatcher.findFullscreenReplacementWindow(
            forPID: safariPID,
            excluding: 5000,
            from: [otherAppFullscreen, safariHelperBar, safariDesktopTab, safariFullscreenVideo],
            displays: displays
        )
        #expect(replacement?.windowID == 5002)

        // Excluding `5002` itself must return nil when no other fullscreen window exists for `safariPID`.
        let noReplacement = WindowLifecycleWatcher.findFullscreenReplacementWindow(
            forPID: safariPID,
            excluding: 5002,
            from: [otherAppFullscreen, safariHelperBar, safariDesktopTab, safariFullscreenVideo],
            displays: displays
        )
        #expect(noReplacement == nil)

        // Notch-inset macOS native fullscreen window `(0, 37, 1512, 945)` is also detected cleanly by replacement helper!
        let notchFullscreen = RawWindowSnapshot(
            windowID: 5003,
            pid: safariPID,
            ownerName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            title: "Fullscreen Video (Below Notch)",
            cgBounds: CGRect(x: 0, y: 37, width: 1512, height: 945),
            layer: 0
        )
        let notchReplacement = WindowLifecycleWatcher.findFullscreenReplacementWindow(
            forPID: safariPID,
            excluding: 5000,
            from: [safariHelperBar, safariDesktopTab, notchFullscreen],
            displays: displays
        )
        #expect(notchReplacement?.windowID == 5003)
    }

    // MARK: 16. Regression: SystemCursorHider Refcount Accounting, Race Gate & Exit Restoration

    @Test("SystemCursorHider tracks reassertHiddenIfDrifted depth with cooldown & cap, blocks late hides via setAllowedToHide(false), and guarantees hideDepth == 0 & processHideDepth == 0 on stop/forceRestore")
    func systemCursorHiderDriftAccountingAndRaceFreeTeardown() throws {
        SystemCursorHider.emergencyRestoreAll()
        defer { SystemCursorHider.emergencyRestoreAll() }

        let hider = SystemCursorHider()
        defer { hider.forceRestore() }

        #expect(hider.isAllowedToHide)
        #expect(hider.hideDepth == 0)
        #expect(SystemCursorHider.processHideDepth == 0)

        // 1. Initial hide acquires depth = 1.
        hider.hide()
        #expect(hider.hideDepth == 1)
        #expect(SystemCursorHider.processHideDepth == 1)

        // 2. reassertHiddenIfDrifted() MUST increment BOTH hideDepth AND processHideDepth,
        //    enforce the 0.25s cooldown, and cap at maxReassertHideDepth (16).
        let reassert1 = hider.reassertHiddenIfDrifted(now: 100.0, assumedCursorVisibleForTesting: true)
        #expect(reassert1)
        #expect(hider.hideDepth == 2)
        #expect(SystemCursorHider.processHideDepth == 2)

        // Within 0.25s cooldown -> ignored!
        let tooSoon = hider.reassertHiddenIfDrifted(now: 100.10, assumedCursorVisibleForTesting: true)
        #expect(!tooSoon)
        #expect(hider.hideDepth == 2)
        #expect(SystemCursorHider.processHideDepth == 2)

        // After >= 0.25s cooldown -> increments both depths accurately!
        let reassert2 = hider.reassertHiddenIfDrifted(now: 100.25, assumedCursorVisibleForTesting: true)
        #expect(reassert2)
        #expect(hider.hideDepth == 3)
        #expect(SystemCursorHider.processHideDepth == 3)

        // Repeated drifted ticks cap strictly at maxReassertHideDepth (16).
        var tickTime = 101.0
        for _ in 0..<25 {
            _ = hider.reassertHiddenIfDrifted(now: tickTime, assumedCursorVisibleForTesting: true)
            tickTime += 0.30
        }
        #expect(hider.hideDepth == SystemCursorHider.maxReassertHideDepth)
        #expect(SystemCursorHider.processHideDepth == SystemCursorHider.maxReassertHideDepth)

        // 3. setAllowedToHide(false) atomically unwinds ALL 16 hide levels AND blocks all subsequent hides/reasserts!
        hider.setAllowedToHide(false)
        #expect(!hider.isAllowedToHide)
        #expect(hider.hideDepth == 0)
        #expect(SystemCursorHider.processHideDepth == 0)

        hider.hide()
        let lateReassert = hider.reassertHiddenIfDrifted(now: tickTime + 1.0, assumedCursorVisibleForTesting: true)
        #expect(!lateReassert)
        #expect(hider.hideDepth == 0, "hide() MUST be a strict no-op while allowedToHide == false")
        #expect(SystemCursorHider.processHideDepth == 0, "processHideDepth MUST stay 0 while allowedToHide == false")

        // 4. Concurrent race stress: a racing thread hammering hide()/reassertHiddenIfDrifted() can NEVER
        //    leave depth > 0 after setAllowedToHide(false) completes!
        hider.setAllowedToHide(true)
        hider.hide()
        let keepHammering = OSAllocatedUnfairLock(initialState: true)
        let startedSem = DispatchSemaphore(value: 0)
        let finishedSem = DispatchSemaphore(value: 0)

        let racer = Thread {
            startedSem.signal()
            var t = 200.0
            while keepHammering.withLock({ $0 }) {
                hider.hide()
                _ = hider.reassertHiddenIfDrifted(now: t, assumedCursorVisibleForTesting: true)
                t += 0.30
            }
            finishedSem.signal()
        }
        racer.start()
        _ = startedSem.wait(timeout: .now() + .seconds(2))
        Thread.sleep(forTimeInterval: 0.01)

        // Flip gate OFF while racing thread is actively hammering!
        hider.setAllowedToHide(false)
        #expect(hider.hideDepth == 0)
        #expect(SystemCursorHider.processHideDepth == 0)

        Thread.sleep(forTimeInterval: 0.015)
        #expect(hider.hideDepth == 0, "Racing thread must NEVER increment hideDepth after setAllowedToHide(false)")
        #expect(SystemCursorHider.processHideDepth == 0, "Racing thread must NEVER increment processHideDepth after setAllowedToHide(false)")

        keepHammering.withLock { $0 = false }
        _ = finishedSem.wait(timeout: .now() + .seconds(2))

        // 5. CursorOverlayController.stop() and suspend() unwind drifted hide depth and lock gate to false!
        let controller = CursorOverlayController(presentationMode: .externalCompositor)
        defer { controller.stop() }
        let sourceCG = CGRect(x: 120, y: 140, width: 680, height: 440)
        let overlayCG = CGRect(x: 0, y: 0, width: 1512, height: 981)
        controller.activateForEventTapTesting(
            configuration: CursorMappingConfiguration(
                sourceCGRect: sourceCG,
                destinationCGRect: overlayCG,
                overlayCGRect: overlayCG,
                backingScaleFactor: 2.0,
                settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
            ),
            displays: [Self.primaryRetina],
            initialPointer: CGPoint(x: sourceCG.midX, y: sourceCG.midY)
        )

        // Simulate accumulated drift hide depth before suspend() and stop().
        controller.cursorHiderForTesting.setAllowedToHide(true)
        controller.cursorHiderForTesting.hide()
        for i in 0..<6 {
            _ = controller.cursorHiderForTesting.reassertHiddenIfDrifted(
                now: 300.0 + Double(i) * 0.30,
                assumedCursorVisibleForTesting: true
            )
        }
        #expect(controller.cursorHiderForTesting.hideDepth == 7)
        #expect(SystemCursorHider.processHideDepth == 7)

        controller.suspend()
        #expect(!controller.cursorHiderForTesting.isAllowedToHide)
        #expect(controller.cursorHiderForTesting.hideDepth == 0)
        #expect(SystemCursorHider.processHideDepth == 0)

        // Late hide attempt during suspend must be blocked.
        controller.cursorHiderForTesting.hide()
        #expect(controller.cursorHiderForTesting.hideDepth == 0)
        #expect(SystemCursorHider.processHideDepth == 0)

        // Re-arm and verify stop() unwinds everything cleanly via forceRestore().
        controller.cursorHiderForTesting.setAllowedToHide(true)
        controller.cursorHiderForTesting.hide()
        for i in 0..<10 {
            _ = controller.cursorHiderForTesting.reassertHiddenIfDrifted(
                now: 400.0 + Double(i) * 0.30,
                assumedCursorVisibleForTesting: true
            )
        }
        #expect(controller.cursorHiderForTesting.hideDepth == 11)
        #expect(SystemCursorHider.processHideDepth == 11)

        controller.stop()
        #expect(!controller.cursorHiderForTesting.isAllowedToHide)
        #expect(controller.cursorHiderForTesting.hideDepth == 0)
        #expect(SystemCursorHider.processHideDepth == 0)

        // RunGuardWatchdog.forceRestoreSystemCursor() also guarantees processHideDepth == 0.
        hider.setAllowedToHide(true)
        hider.hide()
        #expect(SystemCursorHider.processHideDepth >= 1)
        RunGuardWatchdog.forceRestoreSystemCursor()
        #expect(SystemCursorHider.processHideDepth == 0)
        hider.setAllowedToHide(false)
    }

    // MARK: 17. Regression: .directChrome 8pt Exit Hysteresis & Live scaledCGPosition Updates

    @Test(".directChrome uses 0pt entry and 8pt exit hysteresis to eliminate toolbar edge flicker while updating scaledCGPosition on every move")
    func directChromeExitHysteresisAndLiveScaledCursorPosition() throws {
        let sourceCG = CGRect(x: 120, y: 140, width: 680, height: 440)
        let overlayCG = CGRect(x: 0, y: 0, width: 1512, height: 981)
        let toolbarCG = CGRect(x: 546, y: 42, width: 420, height: 42) // x: [546..966], y: [42..84]

        let mapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: overlayCG,
            overlayRect: overlayCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
        )

        var proc = CursorEventTapProcessor()
        proc.isPresentationWindowed = false
        proc.interactiveChromeRects = [toolbarCG]

        // 1. Entry requires exact visible toolbar rect (`expansion: 0.0`): 5pt outside (`y = 89`) stays `.scaled`!
        let outside5Start = CGPoint(x: 756, y: 110)
        let startSrc = mapping.mapScaledToSource(outside5Start, clampToSource: true)
        var phys = CGPoint(x: 500, y: 500)
        proc.reset(initialSourcePosition: startSrc, physicalLocation: phys)

        phys.y -= 21.0 // visual Y moves 110 -> 89 (5pt below toolbarCG.maxY = 84)
        let approach5OutsideRaw = proc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: 0, deltaY: -21, timestamp: 1.0),
            mapping: mapping
        )
        let approach5Outside = try #require(approach5OutsideRaw)
        #expect(approach5Outside.interactionMode == .scaled, "Approaching 5pt outside toolbar must NOT prematurely enter directChrome!")
        #expect(approach5Outside.isScaledSpriteVisible)

        // Move 15pt further up -> visual Y = 74 (inside toolbarCG [42..84]) -> cleanly enters `.directChrome`!
        phys.y -= 15.0
        let enterToolbarRaw = proc.process(
            input: CursorTapEventInput(type: .mouseMoved, location: phys, deltaX: 0, deltaY: -15, timestamp: 1.02),
            mapping: mapping
        )
        let enterToolbar = try #require(enterToolbarRaw)
        #expect(enterToolbar.interactionMode == .directChrome)
        #expect(!enterToolbar.isScaledSpriteVisible)
        let landedPt = try #require(enterToolbar.warpTarget)
        #expect(toolbarCG.contains(landedPt))

        // 2. Once inside `.directChrome`, moving 5pt outside ANY side (bottom, top, left, right) MUST stay in
        //    `.directChrome` with ZERO ping-pong flicker AND update `scaledCGPosition == incoming` every move!
        let fivePtOutsidePoints: [CGPoint] = [
            CGPoint(x: 756, y: toolbarCG.maxY + 5.0), // 5pt below (y = 89)
            CGPoint(x: 756, y: toolbarCG.minY - 5.0), // 5pt above (y = 37)
            CGPoint(x: toolbarCG.minX - 5.0, y: 63),  // 5pt left  (x = 541)
            CGPoint(x: toolbarCG.maxX + 5.0, y: 63),  // 5pt right (x = 971)
            CGPoint(x: 756, y: toolbarCG.maxY + 7.5)  // 7.5pt below (still <= 8pt hysteresis!)
        ]
        var t = 1.05
        var prev = landedPt
        for pt in fivePtOutsidePoints {
            let decRaw = proc.process(
                input: CursorTapEventInput(
                    type: .mouseMoved,
                    location: pt,
                    deltaX: Double(pt.x - prev.x),
                    deltaY: Double(pt.y - prev.y),
                    timestamp: t
                ),
                mapping: mapping
            )
            let dec = try #require(decRaw)
            #expect(dec.interactionMode == .directChrome, "Point 5..7.5pt outside toolbar (\(pt)) must stay in directChrome via 8pt hysteresis!")
            #expect(!dec.isScaledSpriteVisible)
            #expect(dec.rewrittenEventLocation == nil)
            #expect(dec.warpTarget == nil)
            #expect(dec.scaledCGPosition == pt, "directChrome must update scaledCGPosition to incoming on every move!")
            prev = pt
            t += 0.01
        }

        // 3. Moving 12pt outside toolbar (`y = toolbarCG.maxY + 12 = 96`) cleanly exits back to `.scaled`!
        let outside12Pt = CGPoint(x: 756, y: toolbarCG.maxY + 12.0)
        let exitDecRaw = proc.process(
            input: CursorTapEventInput(
                type: .mouseMoved,
                location: outside12Pt,
                deltaX: Double(outside12Pt.x - prev.x),
                deltaY: Double(outside12Pt.y - prev.y),
                timestamp: t + 0.01
            ),
            mapping: mapping
        )
        let exitDec = try #require(exitDecRaw)
        #expect(exitDec.interactionMode == .scaled, "Moving 12pt outside toolbar (> 8pt hysteresis) must transition cleanly back to `.scaled`!")
        #expect(exitDec.isScaledSpriteVisible)

        // 4. Verify live `CursorOverlayController` + `EventTapCallbackBox` keeps `currentState.scaledCGPosition`
        //    in sync on every `.directChrome` move AND honors 8pt hysteresis across `updateInteractiveChromeRects`!
        let controller = CursorOverlayController(presentationMode: .externalCompositor)
        defer { controller.stop() }
        controller.setPresentationIsWindowed(false)
        controller.updateInteractiveChromeRects([toolbarCG])
        let insideToolbarSrc = mapping.mapScaledToSource(CGPoint(x: 756, y: 63), clampToSource: true)
        controller.activateForEventTapTesting(
            configuration: CursorMappingConfiguration(
                sourceCGRect: sourceCG,
                destinationCGRect: overlayCG,
                overlayCGRect: overlayCG,
                backingScaleFactor: 2.0,
                settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
            ),
            displays: [Self.primaryRetina],
            initialPointer: insideToolbarSrc
        )
        let box = EventTapCallbackBox(controller: controller)
        let dummyProxy = OpaquePointer(bitPattern: 0x1000)!

        // Move inside toolbar -> enters `.directChrome`
        let enterEv = try #require(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: insideToolbarSrc.x + 1, y: insideToolbarSrc.y),
            mouseButton: .left
        ))
        _ = box.invoke(proxy: dummyProxy, type: .mouseMoved, event: enterEv)
        #expect(controller.currentInteractionModeForTesting == .directChrome)

        // Move to 5pt below toolbar (`(760, 89)`) -> stays `.directChrome`, `scaledCGPosition` updates live!
        let hoverBorderPt = CGPoint(x: 760, y: toolbarCG.maxY + 5.0)
        let borderEv = try #require(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: hoverBorderPt,
            mouseButton: .left
        ))
        _ = box.invoke(proxy: dummyProxy, type: .mouseMoved, event: borderEv)
        #expect(controller.currentInteractionModeForTesting == .directChrome)
        #expect(abs(controller.currentState.scaledCGPosition.x - hoverBorderPt.x) < 0.5)
        #expect(abs(controller.currentState.scaledCGPosition.y - hoverBorderPt.y) < 0.5)

        // Refreshing chrome rects while hovering 5pt outside MUST NOT kick back to `.scaled`!
        controller.updateInteractiveChromeRects([toolbarCG])
        #expect(controller.currentInteractionModeForTesting == .directChrome)

        // When toolbar genuinely hides (`[]`), controller cleanly transitions back to `.scaled`!
        controller.updateInteractiveChromeRects([])
        #expect(controller.currentInteractionModeForTesting == .scaled)
    }

    // MARK: 18. Regression (#103): FIFO Down -> Up Repost Ordering for Fast Trackpad Taps

    @Test("Fast trackpad taps within 40ms of a reposted MouseDown also repost MouseUp in FIFO order per button while slower releases do not")
    func fifoMouseDownUpRepostOrderingForFastTrackpadTaps() throws {
        let sourceCG = CGRect(x: 120, y: 140, width: 680, height: 440)
        let overlayCG = CGRect(x: 0, y: 0, width: 1512, height: 981)
        let toolbarCG = CGRect(x: 546, y: 42, width: 420, height: 42)

        let mapping = PointerMapping(
            sourceRect: sourceCG,
            contentRect: overlayCG,
            overlayRect: overlayCG,
            displays: [Self.primaryRetina],
            backingScaleFactor: 2.0,
            settings: CursorSettings(renderScaledCursor: true, confineCursor: true, adjustCursorSpeed: true)
        )

        // 1. Fast left-click tap (15ms Down -> Up) when physical cursor had drifted outside sourceCG:
        //    Down warps + reposts via .cghidEventTap, and Up within 40ms MUST ALSO set shouldRepostAfterWarp
        //    even after physical cursor already landed at targetPos!
        var proc = CursorEventTapProcessor()
        let virtualTarget = CGPoint(x: 420, y: 310)
        let driftedPhys = CGPoint(x: 1180, y: 760)
        proc.reset(initialSourcePosition: virtualTarget, physicalLocation: driftedPhys)

        let fastDownRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: driftedPhys, deltaX: 0, deltaY: 0, timestamp: 10.000),
            mapping: mapping
        )
        let fastDown = try #require(fastDownRaw)
        #expect(fastDown.warpTarget == virtualTarget)
        #expect(fastDown.shouldRepostAfterWarp, "Drifted leftMouseDown must repost via .cghidEventTap")

        // Per-button isolation: an unrelated rightMouseUp 10ms later MUST NOT consume or trigger left's repost!
        let unrelatedRightUpRaw = proc.process(
            input: CursorTapEventInput(type: .rightMouseUp, location: virtualTarget, deltaX: 0, deltaY: 0, timestamp: 10.010),
            mapping: mapping
        )
        let unrelatedRightUp = try #require(unrelatedRightUpRaw)
        #expect(!unrelatedRightUp.shouldRepostAfterWarp, "rightMouseUp must NOT inherit leftMouseDown's FIFO repost flag")

        // Matching leftMouseUp arrives 15ms later (<= 40ms) already at `virtualTarget` -> MUST repost to stay FIFO!
        let fastUpRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseUp, location: virtualTarget, deltaX: 0, deltaY: 0, timestamp: 10.015),
            mapping: mapping
        )
        let fastUp = try #require(fastUpRaw)
        #expect(fastUp.shouldRepostAfterWarp, "Fast trackpad tap leftMouseUp within 40ms of reposted leftMouseDown MUST repost in FIFO order!")
        #expect(fastUp.rewrittenEventLocation == virtualTarget)

        // 2. Slow click (80ms > 40ms): leftMouseUp does NOT need reposting.
        proc.reset(initialSourcePosition: virtualTarget, physicalLocation: driftedPhys)
        let slowDownRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: driftedPhys, deltaX: 0, deltaY: 0, timestamp: 20.000),
            mapping: mapping
        )
        #expect(try #require(slowDownRaw).shouldRepostAfterWarp)
        let slowUpRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseUp, location: virtualTarget, deltaX: 0, deltaY: 0, timestamp: 20.080),
            mapping: mapping
        )
        #expect(!(try #require(slowUpRaw).shouldRepostAfterWarp), "Release after 80ms (> 40ms) must not unnecessarily repost")

        // 3. Fast right-click tap (12ms) also preserves FIFO Down -> Up repost ordering.
        proc.reset(initialSourcePosition: virtualTarget, physicalLocation: driftedPhys)
        let rDownRaw = proc.process(
            input: CursorTapEventInput(type: .rightMouseDown, location: driftedPhys, deltaX: 0, deltaY: 0, timestamp: 30.000),
            mapping: mapping
        )
        #expect(try #require(rDownRaw).shouldRepostAfterWarp)
        let rUpRaw = proc.process(
            input: CursorTapEventInput(type: .rightMouseUp, location: virtualTarget, deltaX: 0, deltaY: 0, timestamp: 30.012),
            mapping: mapping
        )
        #expect(try #require(rUpRaw).shouldRepostAfterWarp, "Fast right-click tap within 40ms MUST repost rightMouseUp in FIFO order!")

        // 4. Fast tap entering `.directChrome` (stationary click onto toolbar while hidden cursor was drifted):
        //    Down warps + reposts onto toolbar, and fast Up 18ms later inside `.directChrome` ALSO reposts!
        proc.interactiveChromeRects = [toolbarCG]
        let toolbarVisual = CGPoint(x: toolbarCG.midX, y: toolbarCG.midY)
        let toolbarSrc = mapping.mapScaledToSource(toolbarVisual, clampToSource: true)
        proc.reset(initialSourcePosition: toolbarSrc, physicalLocation: CGPoint(x: 950, y: 750))
        let chromeDownRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseDown, location: CGPoint(x: 950, y: 750), deltaX: 0, deltaY: 0, timestamp: 40.000),
            mapping: mapping
        )
        let chromeDown = try #require(chromeDownRaw)
        #expect(chromeDown.interactionMode == .directChrome)
        #expect(chromeDown.shouldRepostAfterWarp)
        let chromeUpRaw = proc.process(
            input: CursorTapEventInput(type: .leftMouseUp, location: toolbarVisual, deltaX: 0, deltaY: 0, timestamp: 40.018),
            mapping: mapping
        )
        let chromeUp = try #require(chromeUpRaw)
        #expect(chromeUp.interactionMode == .directChrome)
        #expect(chromeUp.shouldRepostAfterWarp, "Fast tap release on chrome within 40ms of reposted entry Down MUST repost in FIFO order!")
        #expect(chromeUp.rewrittenEventLocation == toolbarVisual)
    }

    // MARK: 19. Regression (#107): Chinese IME Exclusion, Fullscreen Space Transition Grace & Always-on-Top Video Windows

    @Test("WindowLifecycleWatcher classifies Chinese IMEs as system, applies ~450ms/11-tick Space transition grace when frontmost, and supports substantial always-on-top floating video windows")
    func windowLifecycleChineseIMESpaceGraceAndFloatingVideoWindows() throws {
        let displays = [Self.primaryRetina]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let gameBounds = CGRect(x: 100, y: 100, width: 1280, height: 720)
        let gamePID: Int32 = 8001

        // 1. Chinese IME candidate windows (Apple Pinyin/SCIM, Rime/Squirrel, Sogou, WeType/Tencent, Baidu)
        //    MUST classify as `.system`, be excluded from capturable windows, and NEVER trigger 3D overlap!
        let imeSnapshots: [RawWindowSnapshot] = [
            RawWindowSnapshot(windowID: 8101, pid: 8101, ownerName: "SCIM", bundleIdentifier: "com.apple.inputmethod.SCIM", title: "Candidate", cgBounds: CGRect(x: 200, y: 200, width: 320, height: 220), layer: 3),
            RawWindowSnapshot(windowID: 8102, pid: 8102, ownerName: "Squirrel", bundleIdentifier: "im.rime.inputmethod.Squirrel", title: "", cgBounds: CGRect(x: 220, y: 220, width: 300, height: 180), layer: 0),
            RawWindowSnapshot(windowID: 8103, pid: 8103, ownerName: "SogouInput", bundleIdentifier: "com.sogou.inputmethod.sogou", title: "", cgBounds: CGRect(x: 240, y: 240, width: 340, height: 200), layer: 3),
            RawWindowSnapshot(windowID: 8104, pid: 8104, ownerName: "WeType", bundleIdentifier: "com.tencent.inputmethod.wetype", title: "", cgBounds: CGRect(x: 260, y: 260, width: 310, height: 190), layer: 3),
            RawWindowSnapshot(windowID: 8105, pid: 8105, ownerName: "BaiduIM", bundleIdentifier: "com.baidu.inputmethod.BaiduIM", title: "", cgBounds: CGRect(x: 280, y: 280, width: 300, height: 180), layer: 0)
        ]

        for ime in imeSnapshots {
            let category = WindowLifecycleWatcher.classifyOwner(
                pid: ime.pid,
                ownerName: ime.ownerName,
                bundleIdentifier: ime.bundleIdentifier,
                layer: ime.layer,
                bounds: ime.cgBounds,
                displays: displays,
                excludedBundleIDs: AppConfig.defaultAutoScaleExcludedBundleIDs,
                ownPID: ownPID
            )
            #expect(category == .system, "IME '\(ime.bundleIdentifier ?? ime.ownerName)' MUST classify as .system!")
        }

        let capturableIMEs = WindowLifecycleWatcher.filterCapturableWindows(
            from: imeSnapshots,
            displays: displays,
            ownPID: ownPID
        )
        #expect(capturableIMEs.isEmpty, "Chinese IME candidate windows must never be listed as capturable targets!")

        let imeOverlap = WindowLifecycleWatcher.detectForeignWindowOverlap(
            trackedBounds: gameBounds,
            trackedPID: gamePID,
            ownPID: ownPID,
            displays: displays,
            windowsAboveTarget: imeSnapshots
        )
        #expect(imeOverlap == nil, "Typing with Chinese IME candidate windows over a scaled app/3D game must NEVER trigger foreign overlap!")

        // 2. Fullscreen Space Transition Grace (`shouldEmitMinimizedForOffScreenWindow`):
        //    - While tracked PID is still frontmost and AX doesn't report minimized: ignore transient 1..10 ticks (< 0.45s)!
        #expect(!WindowLifecycleWatcher.shouldEmitMinimizedForOffScreenWindow(
            trackedPID: gamePID,
            frontmostPID: gamePID,
            axMinimized: false,
            consecutiveOffScreenTicks: 8,
            elapsedOffScreenSeconds: 0.32
        ))
        #expect(!WindowLifecycleWatcher.shouldEmitMinimizedForOffScreenWindow(
            trackedPID: gamePID,
            frontmostPID: gamePID,
            axMinimized: nil,
            consecutiveOffScreenTicks: 10,
            elapsedOffScreenSeconds: 0.40
        ))
        //    - Reaching 11 ticks OR >= 0.45s elapsed -> emits cleanly!
        #expect(WindowLifecycleWatcher.shouldEmitMinimizedForOffScreenWindow(
            trackedPID: gamePID,
            frontmostPID: gamePID,
            axMinimized: nil,
            consecutiveOffScreenTicks: 11,
            elapsedOffScreenSeconds: 0.40
        ))
        #expect(WindowLifecycleWatcher.shouldEmitMinimizedForOffScreenWindow(
            trackedPID: gamePID,
            frontmostPID: gamePID,
            axMinimized: false,
            consecutiveOffScreenTicks: 5,
            elapsedOffScreenSeconds: 0.46
        ))
        //    - Genuinely AX-minimized -> emits immediately on tick 1!
        #expect(WindowLifecycleWatcher.shouldEmitMinimizedForOffScreenWindow(
            trackedPID: gamePID,
            frontmostPID: gamePID,
            axMinimized: true,
            consecutiveOffScreenTicks: 1,
            elapsedOffScreenSeconds: 0.0
        ))
        //    - Another app became frontmost -> emits immediately on tick 1!
        #expect(WindowLifecycleWatcher.shouldEmitMinimizedForOffScreenWindow(
            trackedPID: gamePID,
            frontmostPID: 9999,
            axMinimized: nil,
            consecutiveOffScreenTicks: 1,
            elapsedOffScreenSeconds: 0.0
        ))

        // 3. Always-on-Top Video Windows (`layer == floatingWindow [3]`, `>= 200x150`):
        let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))
        let iinaPID: Int32 = 8200
        let iinaFloatVideo = RawWindowSnapshot(
            windowID: 8201,
            pid: iinaPID,
            ownerName: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            title: "Anime.mkv (Float on Top)",
            cgBounds: CGRect(x: 200, y: 150, width: 640, height: 360),
            layer: floatingLayer
        )
        let iinaTinyPalette = RawWindowSnapshot(
            windowID: 8202,
            pid: iinaPID,
            ownerName: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            title: "Tiny Palette",
            cgBounds: CGRect(x: 100, y: 100, width: 140, height: 90),
            layer: floatingLayer
        )
        let highLayerOverlay = RawWindowSnapshot(
            windowID: 8203,
            pid: iinaPID,
            ownerName: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            title: "HUD Overlay",
            cgBounds: CGRect(x: 300, y: 200, width: 320, height: 220),
            layer: 25
        )
        let iinaNormalWin = RawWindowSnapshot(
            windowID: 8204,
            pid: iinaPID,
            ownerName: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            title: "Main Window",
            cgBounds: CGRect(x: 150, y: 120, width: 800, height: 500),
            layer: 0
        )

        // Substantial floating video (8201) IS capturable; tiny floating palette (8202) & layer-25 overlay (8203) are NOT!
        let capturableFloating = WindowLifecycleWatcher.filterCapturableWindows(
            from: [iinaTinyPalette, highLayerOverlay, iinaFloatVideo],
            displays: displays,
            ownPID: ownPID
        )
        #expect(capturableFloating.map(\.windowID) == [8201], "Substantial floating video window (layer 3, >=200x150) must be capturable!")

        // selectFrontmostWindow falls back to substantial floating video when no fullscreen or layer-0 window exists!
        let pickedFloatFallback = WindowLifecycleWatcher.selectFrontmostWindow(
            forPID: iinaPID,
            from: [iinaTinyPalette, highLayerOverlay, iinaFloatVideo],
            displays: displays,
            ownPID: ownPID
        )
        #expect(pickedFloatFallback?.windowID == 8201, "selectFrontmostWindow must fall back to substantial floating video window!")

        // When a normal layer-0 window also exists, selectFrontmostWindow still prefers layer-0 over floating fallback!
        let pickedNormalFirst = WindowLifecycleWatcher.selectFrontmostWindow(
            forPID: iinaPID,
            from: [iinaFloatVideo, iinaNormalWin],
            displays: displays,
            ownPID: ownPID
        )
        #expect(pickedNormalFirst?.windowID == 8204, "selectFrontmostWindow must still prefer layer-0 window ahead of floating fallback!")
    }
}
