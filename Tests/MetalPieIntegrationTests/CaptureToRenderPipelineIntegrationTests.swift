import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import IOSurface
import Metal
import QuartzCore
import Testing
import UniformTypeIdentifiers
import os

@testable import MetalPieCore
@testable import MetalPieShaders
@testable import MetalPieCapture

// MARK: - Zero-Copy IOSurface Test Frame Factory

/// Generates genuine `IOSurface`-backed `CVPixelBuffer`s wrapped via `CVMetalTextureCache`
/// (identical zero-copy capture path to `ScreenCaptureEngine.wrapPixelBufferZeroCopy`).
private final class IOSurfaceFrameFactory {
    let device: any MTLDevice
    let textureCache: CVMetalTextureCache

    init(device: any MTLDevice) throws {
        self.device = device
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw EngineError.metalDeviceUnavailable
        }
        self.textureCache = cache
    }

    deinit {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Creates a BGRA8 IOSurface-backed `CapturedFrame` filled by `pixelGenerator(x, y) -> (r, g, b, a)`.
    func makeBGRA8Frame(
        width: Int,
        height: Int,
        timestampSeconds: Double = CACurrentMediaTime(),
        scaleFactor: Double = 2.0,
        screenRect: CGRect? = nil,
        pixelGenerator: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws -> CapturedFrame {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        var pbOut: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pbOut
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer = pbOut else {
            throw EngineError.captureStartFailed("CVPixelBufferCreate BGRA8 failed (\(createStatus))")
        }

        // Populate test fixture bytes on CPU before handing to zero-copy GPU path.
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = ptr + y * bytesPerRow
                for x in 0..<width {
                    let (r, g, b, a) = pixelGenerator(x, y)
                    let off = x * 4
                    row[off + 0] = b
                    row[off + 1] = g
                    row[off + 2] = r
                    row[off + 3] = a
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        return try wrapPixelBuffer(
            pixelBuffer,
            mtlFormat: .bgra8Unorm,
            isHDR: false,
            timestampSeconds: timestampSeconds,
            scaleFactor: scaleFactor,
            screenRect: screenRect
        )
    }

    /// Creates an RGBA16F HDR IOSurface-backed `CapturedFrame` with linear Float16 RGB values (supports EDR > 1.0).
    func makeRGBA16FHDRFrame(
        width: Int,
        height: Int,
        rgbLinear: (Float, Float, Float),
        timestampSeconds: Double = CACurrentMediaTime(),
        scaleFactor: Double = 2.0
    ) throws -> CapturedFrame {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf
        ]
        var pbOut: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_64RGBAHalf,
            attrs as CFDictionary,
            &pbOut
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer = pbOut else {
            throw EngineError.captureStartFailed("CVPixelBufferCreate RGBA16F failed (\(createStatus))")
        }

        let r16 = Float16(rgbLinear.0).bitPattern
        let g16 = Float16(rgbLinear.1).bitPattern
        let b16 = Float16(rgbLinear.2).bitPattern
        let a16 = Float16(1.0).bitPattern

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    let off = x * 4
                    row[off + 0] = r16
                    row[off + 1] = g16
                    row[off + 2] = b16
                    row[off + 3] = a16
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        return try wrapPixelBuffer(
            pixelBuffer,
            mtlFormat: .rgba16Float,
            isHDR: true,
            timestampSeconds: timestampSeconds,
            scaleFactor: scaleFactor,
            screenRect: nil
        )
    }

    private func wrapPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        mtlFormat: MTLPixelFormat,
        isHDR: Bool,
        timestampSeconds: Double,
        scaleFactor: Double,
        screenRect: CGRect?
    ) throws -> CapturedFrame {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            mtlFormat,
            width,
            height,
            0,
            &cvTexOut
        )
        guard status == kCVReturnSuccess,
              let cvTex = cvTexOut,
              let mtlTex = CVMetalTextureGetTexture(cvTex)
        else {
            throw EngineError.captureStartFailed("CVMetalTextureCacheCreateTextureFromImage failed (\(status))")
        }

        let surfaceID: IOSurfaceID
        if let surf = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
            surfaceID = IOSurfaceGetID(surf)
        } else {
            surfaceID = 0
        }

        let backing = CapturedFrameBacking(
            pixelBuffer: pixelBuffer,
            cvMetalTexture: cvTex,
            surfaceID: surfaceID
        )
        let resolvedRect = screenRect ?? CGRect(
            x: 100,
            y: 100,
            width: Double(width) / scaleFactor,
            height: Double(height) / scaleFactor
        )

        return CapturedFrame(
            texture: mtlTex,
            pixelSize: PixelSize(width: width, height: height),
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            screenRect: resolvedRect,
            scaleFactor: scaleFactor,
            timestampSeconds: timestampSeconds,
            isHDR: isHDR,
            colorSpaceName: isHDR ? (CGColorSpace.extendedLinearDisplayP3 as String) : (CGColorSpace.displayP3 as String),
            backingObject: backing
        )
    }
}

// MARK: - CGImage Pixel & PNG Inspection Helpers

private func sampleRGBA(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let w = image.width
    let h = image.height
    let cx = min(max(0, x), max(0, w - 1))
    let cy = min(max(0, y), max(0, h - 1))
    var bytes = [UInt8](repeating: 0, count: 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let ctx = CGContext(
        data: &bytes,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) {
        // Flip Y from top-left image coordinate to CoreGraphics bottom-left draw origin.
        ctx.draw(image, in: CGRect(x: -cx, y: -(h - 1 - cy), width: w, height: h))
    }
    return (bytes[0], bytes[1], bytes[2], bytes[3])
}

private func encodeImageToPNG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

private func makeOffscreenMetalLayer(
    device: any MTLDevice,
    width: Int,
    height: Int,
    pixelFormat: MTLPixelFormat = .bgra8Unorm,
    backingScale: CGFloat = 2.0
) -> CAMetalLayer {
    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = pixelFormat
    layer.isOpaque = true
    layer.framebufferOnly = true
    layer.maximumDrawableCount = 3
    layer.contentsScale = backingScale
    layer.drawableSize = CGSize(width: width, height: height)
    layer.frame = CGRect(x: 0, y: 0, width: CGFloat(width) / backingScale, height: CGFloat(height) / backingScale)
    return layer
}

private func makeSolidTexture(
    device: any MTLDevice,
    width: Int,
    height: Int,
    rgba: (UInt8, UInt8, UInt8, UInt8)
) throws -> any MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: height,
        mipmapped: false
    )
    desc.usage = [.shaderRead]
    desc.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: desc) else {
        throw EngineError.metalDeviceUnavailable
    }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: bytes.count, by: 4) {
        bytes[i + 0] = rgba.2 // B
        bytes[i + 1] = rgba.1 // G
        bytes[i + 2] = rgba.0 // R
        bytes[i + 3] = rgba.3 // A
    }
    tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return tex
}

internal func waitForCondition(
    timeoutSeconds: TimeInterval = 5.0,
    pollMilliseconds: UInt64 = 10,
    _ predicate: @Sendable () -> Bool
) async -> Bool {
    let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
    while CFAbsoluteTimeGetCurrent() < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(pollMilliseconds))
    }
    return predicate()
}

/// 4-quadrant high-contrast test pattern:
/// Top-Left = Red (230, 30, 30), Top-Right = Green (30, 220, 30),
/// Bottom-Left = Blue (30, 60, 230), Bottom-Right = Yellow (230, 220, 30).
private func quadrantPattern(width: Int, height: Int, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let isRight = x >= width / 2
    let isBottom = y >= height / 2
    switch (isRight, isBottom) {
    case (false, false): return (230, 30, 30, 255)   // Red TL
    case (true, false):  return (30, 220, 30, 255)   // Green TR
    case (false, true):  return (30, 60, 230, 255)   // Blue BL
    case (true, true):   return (230, 220, 30, 255)  // Yellow BR
    }
}

// MARK: - End-to-End Integration Test Suite

@Suite("Capture -> Shader Chain -> RenderLoop Integration", .serialized)
struct CaptureToRenderPipelineIntegrationTests {

    @Test("End-to-end IOSurface -> RenderLoopController -> Real EffectChainRenderer across scaling modes (zero double-present clipping)")
    func endToEndScalingModesAndZeroClipping() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on test host")
            return
        }

        let factory = try IOSurfaceFrameFactory(device: device)
        let renderer = try EffectChainRenderer(device: device)
        let loop = try RenderLoopController(
            device: device,
            effectRenderer: renderer,
            frameInterpolator: renderer.videoToolboxML
        )
        defer { loop.stop() }

        // 16:9 source (320x180) targeting 16:10 canvas (640x400) — triggers Fit letterboxing (640x360 @ y=20)
        // AND IntegerFit centering (320x180 @ x=160, y=110) — exposing any double-present clipping bug!
        let srcW = 320
        let srcH = 180
        let dstW = 640
        let dstH = 400
        let layer = makeOffscreenMetalLayer(device: device, width: dstW, height: dstH)
        let metrics = OverlayDrawableMetrics(
            cocoaFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
            cgFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
            drawablePixelSize: PixelSize(width: dstW, height: dstH),
            backingScaleFactor: 2.0,
            screenMaxFPS: 120.0,
            displayID: CGMainDisplayID(),
            supportsEDR: false,
            isVRRDirectScanoutActive: false
        )

        let modesToTest: [(label: String, mode: ScalingMode, expectedW: Int, expectedH: Int, crop: CropInsets)] = [
            (
                "MetalFX Spatial (Fit 16:9->16:10)",
                ScalingMode.builtInPresets.first { $0.id == ScalingMode.metalFXSpatialID }!,
                640, 360, .zero
            ),
            (
                "FSR 1.0 EASU + RCAS (Fit 16:9->16:10)",
                ScalingMode.builtInPresets.first { $0.id == ScalingMode.fsr1ID }!,
                640, 360, .zero
            ),
            (
                "Anime4K Upscale & Denoise (2x + Fit)",
                ScalingMode.builtInPresets.first { $0.id == ScalingMode.anime4kID }!,
                640, 360, .zero
            ),
            (
                "xBRZ Pixel Art (Fit)",
                ScalingMode.builtInPresets.first { $0.id == ScalingMode.xbrzID }!,
                640, 360, .zero
            ),
            (
                "Integer Scale 2x (IntegerFit centered inside 640x400)",
                ScalingMode(
                    name: "IntegerFit Test",
                    effects: [EffectInstance(effectID: .nearest, scalingType: .integerFit)]
                ),
                640, 360, .zero
            ),
            (
                "Integer Scale 1x Normal (320x180 centered inside 640x400 — catches offset shift bug!)",
                ScalingMode(
                    name: "Normal 1x Centered",
                    effects: [EffectInstance(effectID: .nearest, scalingType: .normal, scaleFactorX: 1.0, scaleFactorY: 1.0)]
                ),
                320, 180, .zero
            ),
            (
                "Fill Overscan (16:9 covering 16:10 — catches double UV crop bug!)",
                ScalingMode(
                    name: "Fill Overscan",
                    effects: [EffectInstance(effectID: .bicubic, scalingType: .fill)]
                ),
                640, 400, .zero
            ),
            (
                "Custom Multi-Pass Chain (Crop + Lanczos6 + ImageAdjustment + CAS)",
                ScalingMode(
                    name: "Custom Chain",
                    effects: [
                        EffectInstance(effectID: .lanczos6, scalingType: .fit, parameters: ["arStrength": .float(0.5)]),
                        EffectInstance(
                            effectID: .imageAdjustment,
                            scalingType: .normal,
                            parameters: [
                                "gamma": .float(1.0),
                                "brightness": .float(0.05),
                                "contrast": .float(1.1),
                                "saturation": .float(1.1),
                                "vibrance": .float(0.0),
                                "temperature": .float(0.0)
                            ]
                        ),
                        EffectInstance(effectID: .cas, scalingType: .normal, parameters: ["sharpness": .float(0.5)])
                    ]
                ),
                // Cropping 32px L/R, 18px T/B from 320x180 -> 256x144 (exact 16:9) -> Fit in 640x400 = 640x360!
                640, 360, CropInsets(enabled: true, left: 32, top: 18, right: 32, bottom: 18)
            )
        ]

        let frame = try factory.makeBGRA8Frame(width: srcW, height: srcH) { x, y in
            quadrantPattern(width: srcW, height: srcH, x: x, y: y)
        }

        for testCase in modesToTest {
            var profile = Profile.defaultProfile
            profile.scalingModeID = testCase.mode.id
            profile.crop = testCase.crop
            profile.capture.lowLatencyPresent = true
            profile.capture.duplicateFrameMode = .never
            profile.frameGen.enabled = false

            let firstFrameSeen = OSAllocatedUnfairLock(initialState: false)
            loop.setFirstFrameHandler {
                firstFrameSeen.withLock { $0 = true }
            }

            let sessionConfig = RenderSessionConfiguration(
                targetWindowName: testCase.label,
                profile: profile,
                scalingMode: testCase.mode,
                overlayMetrics: metrics,
                vrrDirectScanout: false
            )

            try await renderer.prewarm(scalingMode: testCase.mode)
            loop.start(metalLayer: layer, configuration: sessionConfig)
            loop.ingest(frame: frame)

            let rendered = await waitForCondition(timeoutSeconds: 3.0) {
                firstFrameSeen.withLock { $0 }
            }
            #expect(rendered, "First frame failed to render for \(testCase.label)")

            let screenshot = try await loop.requestCursorFreeScreenshot()
            #expect(screenshot.width == testCase.expectedW, "Width mismatch for \(testCase.label): got \(screenshot.width), expected \(testCase.expectedW)")
            #expect(screenshot.height == testCase.expectedH, "Height mismatch for \(testCase.label): got \(screenshot.height), expected \(testCase.expectedH)")

            // Verify all 4 quadrants survived intact with ZERO black-bar shift / clipping!
            let qTL = sampleRGBA(screenshot, x: screenshot.width / 4, y: screenshot.height / 4)
            let qTR = sampleRGBA(screenshot, x: (screenshot.width * 3) / 4, y: screenshot.height / 4)
            let qBL = sampleRGBA(screenshot, x: screenshot.width / 4, y: (screenshot.height * 3) / 4)
            let qBR = sampleRGBA(screenshot, x: (screenshot.width * 3) / 4, y: (screenshot.height * 3) / 4)

            #expect(qTL.r > 150 && qTL.g < 100 && qTL.b < 100, "TL quadrant should be red in \(testCase.label), got \(qTL)")
            #expect(qTR.g > 150 && qTR.r < 100 && qTR.b < 100, "TR quadrant should be green in \(testCase.label), got \(qTR)")
            #expect(qBL.b > 150 && qBL.r < 100 && qBL.g < 120, "BL quadrant should be blue in \(testCase.label), got \(qBL)")
            #expect(qBR.r > 150 && qBR.g > 150 && qBR.b < 100, "BR quadrant should be yellow in \(testCase.label), got \(qBR)")

            // Also verify edge pixels near all 4 borders are NOT clipped black bars!
            let nearTop = sampleRGBA(screenshot, x: screenshot.width / 4, y: 6)
            let nearBottom = sampleRGBA(screenshot, x: (screenshot.width * 3) / 4, y: screenshot.height - 7)
            let nearLeft = sampleRGBA(screenshot, x: 6, y: (screenshot.height * 3) / 4)
            let nearRight = sampleRGBA(screenshot, x: screenshot.width - 7, y: screenshot.height / 4)
            #expect(nearTop.r > 120, "Top edge clipped black in \(testCase.label): \(nearTop)")
            #expect(nearBottom.r > 120 && nearBottom.g > 120, "Bottom edge clipped black in \(testCase.label): \(nearBottom)")
            #expect(nearLeft.b > 120, "Left edge clipped black in \(testCase.label): \(nearLeft)")
            #expect(nearRight.g > 120, "Right edge clipped black in \(testCase.label): \(nearRight)")

            loop.stop()
        }
    }

    @Test("Dynamic mid-session reconfiguration updates resolution, scaling mode, crop, alignment, HDR, and FPS cap live (MetalDuck stale-config regression)")
    func dynamicReconfigurationMidSession() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on test host")
            return
        }

        let factory = try IOSurfaceFrameFactory(device: device)
        let renderer = try EffectChainRenderer(device: device)
        let loop = try RenderLoopController(
            device: device,
            effectRenderer: renderer,
            frameInterpolator: renderer.videoToolboxML
        )
        defer { loop.stop() }

        let layer = makeOffscreenMetalLayer(device: device, width: 640, height: 400)
        var metrics = OverlayDrawableMetrics(
            cocoaFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
            cgFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
            drawablePixelSize: PixelSize(width: 640, height: 400),
            backingScaleFactor: 2.0,
            screenMaxFPS: 120.0,
            displayID: CGMainDisplayID(),
            supportsEDR: true,
            isVRRDirectScanoutActive: false
        )

        let metalFXMode = ScalingMode.builtInPresets.first { $0.id == ScalingMode.metalFXSpatialID }!
        let fsrMode = ScalingMode.builtInPresets.first { $0.id == ScalingMode.fsr1ID }!
        let normal1xMode = ScalingMode(
            name: "1x Normal",
            effects: [EffectInstance(effectID: .nearest, scalingType: .normal, scaleFactorX: 1.0, scaleFactorY: 1.0)]
        )

        var profile = Profile.defaultProfile
        profile.scalingModeID = metalFXMode.id
        profile.outputAlignment = .center
        profile.crop = .zero
        profile.capture.lowLatencyPresent = true
        profile.capture.duplicateFrameMode = .never
        profile.capture.dynamicRange = .sdr
        profile.capture.frameRateLimit = 30

        let firstRendered = OSAllocatedUnfairLock(initialState: false)
        loop.setFirstFrameHandler { firstRendered.withLock { $0 = true } }

        loop.start(
            metalLayer: layer,
            configuration: RenderSessionConfiguration(
                targetWindowName: "DynamicReconfigTest",
                profile: profile,
                scalingMode: metalFXMode,
                overlayMetrics: metrics
            )
        )

        let sdrFrame = try factory.makeBGRA8Frame(width: 320, height: 180) { x, y in
            quadrantPattern(width: 320, height: 180, x: x, y: y)
        }
        loop.ingest(frame: sdrFrame)
        #expect(await waitForCondition { firstRendered.withLock { $0 } })

        // 1. Initial state: 640x360 centered inside 640x400 (y = 20)
        let layout1 = try #require(loop.currentLayout)
        #expect(layout1.finalOutputPixelSize == PixelSize(width: 640, height: 360))
        #expect(layout1.visibleContentPixelRect == PixelRect(x: 0, y: 20, width: 640, height: 360))

        // 2. Dynamically switch scaling mode to 1x Normal + alignment to `.bottomRight` on a STATIC frame (NO new ingest!)
        profile.scalingModeID = normal1xMode.id
        profile.outputAlignment = .bottomRight
        loop.updateConfiguration(RenderSessionConfiguration(
            targetWindowName: "DynamicReconfigTest",
            profile: profile,
            scalingMode: normal1xMode,
            overlayMetrics: metrics
        ))

        let reconfiguredStatic = await waitForCondition(timeoutSeconds: 2.0) {
            guard let l = loop.currentLayout else { return false }
            return l.finalOutputPixelSize == PixelSize(width: 320, height: 180)
                && l.visibleContentPixelRect.x == 320
                && l.visibleContentPixelRect.y == 220
        }
        #expect(reconfiguredStatic, "Dynamic updateConfiguration must apply scaling mode + alignment immediately even on static frame!")
        let shot2 = try await loop.requestCursorFreeScreenshot()
        #expect(shot2.width == 320 && shot2.height == 180)

        // 3. Dynamically enable Crop Insets + switch to FSR 1.0 + change target resolution (640x400 -> 800x450) + FPS cap (60)
        layer.drawableSize = CGSize(width: 800, height: 450)
        metrics.drawablePixelSize = PixelSize(width: 800, height: 450)
        metrics.cgFrame = CGRect(x: 0, y: 0, width: 400, height: 225)
        metrics.cocoaFrame = CGRect(x: 0, y: 0, width: 400, height: 225)

        profile.scalingModeID = fsrMode.id
        profile.outputAlignment = .center
        profile.crop = CropInsets(enabled: true, left: 40, top: 20, right: 40, bottom: 20)
        profile.capture.frameRateLimit = 60

        loop.updateConfiguration(RenderSessionConfiguration(
            targetWindowName: "DynamicReconfigTest",
            profile: profile,
            scalingMode: fsrMode,
            overlayMetrics: metrics
        ))
        loop.ingest(frame: sdrFrame)

        let resizedAndCropped = await waitForCondition(timeoutSeconds: 2.0) {
            guard let l = loop.currentLayout else { return false }
            return l.targetPixelSize == PixelSize(width: 800, height: 450)
                && l.croppedSourceRect == PixelRect(x: 40, y: 20, width: 240, height: 140)
                && l.effectPasses.first?.effectID == .fsr1EASU
        }
        #expect(resizedAndCropped, "Dynamic resize + crop + scalingMode switch failed to take effect live")
        #expect(loop.currentTelemetry.backendName == fsrMode.name)
        let shot3 = try await loop.requestCursorFreeScreenshot()
        #expect(shot3.width > 0 && shot3.height > 0)

        // 4. Dynamically toggle HDR mid-session and ingest a real RGBA16F EDR (> 1.0) IOSurface frame!
        layer.pixelFormat = .rgba16Float
        profile.crop = .zero
        profile.capture.dynamicRange = .hdr
        profile.capture.preferredPixelFormat = .rgba16f
        profile.capture.frameRateLimit = nil

        loop.updateConfiguration(RenderSessionConfiguration(
            targetWindowName: "DynamicReconfigTest",
            profile: profile,
            scalingMode: metalFXMode,
            overlayMetrics: metrics
        ))

        let hdrFrame = try factory.makeRGBA16FHDRFrame(width: 320, height: 180, rgbLinear: (1.8, 0.5, 0.2))
        loop.ingest(frame: hdrFrame)

        let hdrActive = await waitForCondition(timeoutSeconds: 2.0) {
            loop.currentTelemetry.hdrActive
        }
        #expect(hdrActive, "HDR dynamic reconfiguration did not activate telemetry.hdrActive")

        let hdrScreenshot = try await loop.requestCursorFreeScreenshot()
        #expect(hdrScreenshot.width == 800 && hdrScreenshot.height == 450)
        let centerPx = sampleRGBA(hdrScreenshot, x: 400, y: 225)
        #expect(centerPx.r > centerPx.g && centerPx.g > centerPx.b, "HDR -> SDR tone-mapped screenshot should preserve warm red>green>blue channel order, got \(centerPx)")
    }

    @Test("Cursor-free PNG screenshot excludes VRR GPU cursor and HUD overlays and produces valid PNG")
    func cursorFreePNGScreenshotExcludesOverlays() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on test host")
            return
        }

        let factory = try IOSurfaceFrameFactory(device: device)
        let renderer = try EffectChainRenderer(device: device)
        let loop = try RenderLoopController(device: device, effectRenderer: renderer)
        defer { loop.stop() }

        let layer = makeOffscreenMetalLayer(device: device, width: 640, height: 360)
        let metrics = OverlayDrawableMetrics(
            cocoaFrame: CGRect(x: 0, y: 0, width: 320, height: 180),
            cgFrame: CGRect(x: 0, y: 0, width: 320, height: 180),
            drawablePixelSize: PixelSize(width: 640, height: 360),
            backingScaleFactor: 2.0,
            screenMaxFPS: 120.0,
            displayID: CGMainDisplayID(),
            supportsEDR: false,
            isVRRDirectScanoutActive: true
        )

        var profile = Profile.defaultProfile
        profile.capture.lowLatencyPresent = true
        profile.capture.duplicateFrameMode = .never
        let mode = ScalingMode.builtInPresets.first { $0.id == ScalingMode.lanczos6ID }!

        // Bright red cursor sprite & bright green HUD directly over the center of the frame.
        let redCursorTex = try makeSolidTexture(device: device, width: 64, height: 64, rgba: (255, 0, 0, 255))
        let greenHUDTex = try makeSolidTexture(device: device, width: 200, height: 100, rgba: (0, 255, 0, 255))

        loop.updateGPUCursorSprite(GPUCursorSpriteSnapshot(
            isVisible: true,
            normalizedPosition: CGPoint(x: 0.5, y: 0.5),
            pixelSize: CGSize(width: 64, height: 64),
            normalizedHotSpot: CGPoint(x: 0.5, y: 0.5),
            useNearestFilter: true,
            texture: redCursorTex
        ))
        loop.updateGPUHUDOverlay(GPUHUDOverlaySnapshot(
            isVisible: true,
            pixelRect: PixelRect(x: 220, y: 130, width: 200, height: 100),
            texture: greenHUDTex
        ))

        let firstSeen = OSAllocatedUnfairLock(initialState: false)
        loop.setFirstFrameHandler { firstSeen.withLock { $0 = true } }

        loop.start(
            metalLayer: layer,
            configuration: RenderSessionConfiguration(
                targetWindowName: "ScreenshotCleanTest",
                profile: profile,
                scalingMode: mode,
                overlayMetrics: metrics,
                vrrDirectScanout: true
            )
        )

        // Solid pure blue source frame (20, 40, 220)
        let blueFrame = try factory.makeBGRA8Frame(width: 320, height: 180) { _, _ in (20, 40, 220, 255) }
        loop.ingest(frame: blueFrame)
        #expect(await waitForCondition { firstSeen.withLock { $0 } })

        let cgImage = try await loop.requestCursorFreeScreenshot()
        #expect(cgImage.width == 640 && cgImage.height == 360)

        // Sample right where both cursor sprite and HUD overlay were positioned!
        let center = sampleRGBA(cgImage, x: 320, y: 180)
        #expect(center.b > 180 && center.r < 60 && center.g < 80, "Screenshot must be pure blue without red cursor or green HUD bleed! Got \(center)")

        // Verify valid PNG encoding with standard PNG magic signature bytes.
        let pngData = try #require(encodeImageToPNG(cgImage))
        #expect(pngData.count > 200)
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(Array(pngData.prefix(8)) == pngMagic)
    }

    @Test("Frame Generation 2x pacing + telemetry (sourceFPS, outputFPS, passTimings) + GPU duplicate frame skipping")
    func frameGenPacingTelemetryAndDuplicateSkip() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on test host")
            return
        }

        let factory = try IOSurfaceFrameFactory(device: device)
        let renderer = try EffectChainRenderer(device: device)
        let loop = try RenderLoopController(
            device: device,
            effectRenderer: renderer,
            frameInterpolator: renderer.videoToolboxML
        )
        defer { loop.stop() }

        let layer = makeOffscreenMetalLayer(device: device, width: 640, height: 360)
        let metrics = OverlayDrawableMetrics(
            cocoaFrame: CGRect(x: 0, y: 0, width: 320, height: 180),
            cgFrame: CGRect(x: 0, y: 0, width: 320, height: 180),
            drawablePixelSize: PixelSize(width: 640, height: 360),
            backingScaleFactor: 2.0,
            screenMaxFPS: 120.0,
            displayID: CGMainDisplayID(),
            supportsEDR: false,
            isVRRDirectScanoutActive: true
        )

        var profile = Profile.defaultProfile
        profile.capture.lowLatencyPresent = false
        profile.capture.duplicateFrameMode = .never
        profile.frameGen = FrameGenSettings(
            enabled: true,
            multiplier: .x2,
            backend: .auto,
            artifactGuardSensitivity: .balanced,
            disableIn3DGameMode: true
        )
        let mode = ScalingMode.builtInPresets.first { $0.id == ScalingMode.bicubicCASID }!
        // Pre-warm shader pipelines and VideoToolbox ANE session ahead of the timed 30fps cadence loop
        // (avoids measuring one-time cold ML model compilation inside the 330ms pacing window).
        try await renderer.prewarm(scalingMode: mode)
        try renderer.videoToolboxML.prepare(width: 320, height: 180, settings: profile.frameGen)

        let telemetrySnapshots = OSAllocatedUnfairLock<[SessionTelemetry]>(initialState: [])
        loop.setTelemetryHandler { snap in
            telemetrySnapshots.withLock { $0.append(snap) }
        }

        loop.start(
            metalLayer: layer,
            configuration: RenderSessionConfiguration(
                targetWindowName: "FrameGen2xTest",
                profile: profile,
                scalingMode: mode,
                overlayMetrics: metrics,
                vrrDirectScanout: true
            )
        )

        // Feed 10 smooth moving-bar frames at ~30 FPS (33 ms cadence) -> 2x FG should pace intermediate beats!
        let baseTime = CACurrentMediaTime()
        for idx in 0..<10 {
            let boxX = 40 + idx * 14
            let frame = try factory.makeBGRA8Frame(
                width: 320,
                height: 180,
                timestampSeconds: baseTime + Double(idx) * 0.033
            ) { x, y in
                if x >= boxX && x < boxX + 48 && y >= 50 && y < 130 {
                    return (230, 230, 230, 255)
                }
                return (30, 40, 60, 255)
            }
            loop.ingest(frame: frame)
            try await Task.sleep(for: .milliseconds(33))
        }

        // Wait briefly for the final scheduled 2x beat to complete.
        try await Task.sleep(for: .milliseconds(60))

        let snap = loop.currentTelemetry
        #expect(snap.state == .running)
        #expect(snap.frameGenActive == true)
        #expect(snap.frameGenMultiplier == 2)
        #expect(snap.sourceFPS > 10.0, "Expected live sourceFPS > 10, got \(snap.sourceFPS)")
        #expect(snap.outputFPS > snap.sourceFPS * 1.15, "Expected 2x FG outputFPS (\(snap.outputFPS)) to exceed sourceFPS (\(snap.sourceFPS))")
        #expect(!snap.passTimings.isEmpty, "Expected populated passTimings")
        let sawFrameGenPass = telemetrySnapshots.withLock { snaps in
            snaps.contains { s in s.passTimings.contains { $0.id == "frame-gen" } }
        } || snap.passTimings.contains { $0.id == "frame-gen" }
        #expect(sawFrameGenPass, "Expected 'frame-gen' pass timing in telemetry snapshots")

        loop.stop()

        // Part 2: Verify GPU Duplicate Frame Detection (`duplicateFrameMode = .always`)
        var dupProfile = Profile.defaultProfile
        dupProfile.capture.lowLatencyPresent = true
        dupProfile.capture.duplicateFrameMode = .always
        dupProfile.frameGen.enabled = false

        loop.start(
            metalLayer: layer,
            configuration: RenderSessionConfiguration(
                targetWindowName: "DupSkipTest",
                profile: dupProfile,
                scalingMode: mode,
                overlayMetrics: metrics,
                vrrDirectScanout: false
            )
        )

        let staticFrame = try factory.makeBGRA8Frame(width: 320, height: 180) { x, y in
            quadrantPattern(width: 320, height: 180, x: x, y: y)
        }
        for _ in 0..<6 {
            loop.ingest(frame: staticFrame)
            try await Task.sleep(for: .milliseconds(25))
        }

        let dupSnap = loop.currentTelemetry
        #expect(dupSnap.duplicateFramesSkipped >= 3, "Expected >=3 duplicate frames skipped on GPU, got \(dupSnap.duplicateFramesSkipped)")
    }

    @Test("TexturePool steady-state zero allocations across repeated multi-pass EffectChainRenderer frames")
    func texturePoolZeroPerFrameAllocationsInSteadyState() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            Issue.record("Metal device unavailable on test host")
            return
        }

        let renderer = try EffectChainRenderer(device: device)
        let mode = ScalingMode.builtInPresets.first { $0.id == ScalingMode.fsr1ID }!
        let srcTex = try makeSolidTexture(device: device, width: 320, height: 180, rgba: (120, 180, 210, 255))

        let dstDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 640,
            height: 360,
            mipmapped: false
        )
        dstDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        dstDesc.storageMode = .private
        let dstTex = try #require(device.makeTexture(descriptor: dstDesc))

        let layout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 320, height: 180),
            targetPixelSize: PixelSize(width: 640, height: 360),
            effects: mode.effects,
            presentationMode: .fullscreen
        )

        // Warmup frame populates pool.
        let warmCB = try #require(queue.makeCommandBuffer())
        _ = try renderer.encode(
            scalingMode: mode,
            context: EffectRenderContext(
                device: device,
                commandBuffer: warmCB,
                sourceTexture: srcTex,
                destinationTexture: dstTex,
                layout: layout,
                duplicateFrameMode: .never
            )
        )
        warmCB.commit()
        warmCB.waitUntilCompleted()

        let baselineAllocs = renderer.texturePool.stats.totalAllocations
        let baselineHits = renderer.texturePool.stats.cacheHits

        // Steady state: 8 consecutive frames must allocate ZERO new pooled textures!
        for i in 1...8 {
            let cb = try #require(queue.makeCommandBuffer())
            _ = try renderer.encode(
                scalingMode: mode,
                context: EffectRenderContext(
                    device: device,
                    commandBuffer: cb,
                    sourceTexture: srcTex,
                    destinationTexture: dstTex,
                    layout: layout,
                    frameIndex: UInt64(i),
                    duplicateFrameMode: .never
                )
            )
            cb.commit()
            cb.waitUntilCompleted()
        }

        let steadyStats = renderer.texturePool.stats
        #expect(steadyStats.totalAllocations == baselineAllocs, "TexturePool allocated \(steadyStats.totalAllocations - baselineAllocs) textures during steady state!")
        #expect(steadyStats.cacheHits > baselineHits, "Expected steady-state TexturePool cache hits")
    }

    @Test("OverlayWindowController and MetalOverlayView enforce macOS 27 maximumDrawableCount, opaque layer, safe level, and anti-occlusion invariants")
    @MainActor
    func overlayWindowControllerInvariants() throws {
        _ = NSApplication.shared
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on test host")
            return
        }

        let controller = try OverlayWindowController(device: device)
        defer { controller.close() }

        let displays = WindowEnumerator.enumerateDisplaysOnMain()
        let primaryBounds = displays.first?.cgBounds ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        let sourceWindow = WindowDescriptor(
            windowID: 4242,
            pid: 9999,
            appName: "TestGame",
            bundleIdentifier: "com.example.testgame",
            title: "TestGame 720p",
            cgBounds: CGRect(x: primaryBounds.minX + 100, y: primaryBounds.minY + 100, width: 640, height: 360),
            isOnScreen: true,
            backingScaleFactor: 2.0
        )

        var profile = Profile.defaultProfile
        profile.presentationMode = .fullscreen
        profile.multiMonitorMode = .closest

        let metrics = controller.prepareOverlay(
            sourceWindow: sourceWindow,
            profile: profile,
            isNativeFullscreenSpace: false
        )

        let panel = try #require(controller.panel)
        let view = try #require(controller.overlayView)

        // 1. Non-activating, opaque, hidden until first frame!
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.isOpaque == true)
        #expect(panel.hasShadow == false)
        #expect(panel.ignoresMouseEvents == true)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(controller.isRevealed == false)
        #expect(panel.isVisible == false)

        // 2. Safe window level: popUpMenu - 1 (NEVER screenSaver or maximumWindow + 1!)
        #expect(panel.level == OverlayWindowController.normalOverlayLevel)
        #expect(panel.level.rawValue < Int(CGWindowLevelForKey(.popUpMenuWindow)))
        #expect(panel.level.rawValue < Int(CGWindowLevelForKey(.screenSaverWindow)))

        // 3. Metal layer invariants & 1-pt anti-occlusion inset in normal mode
        #expect(view.metalLayer.isOpaque == true)
        #expect(view.metalLayer.framebufferOnly == true)
        #expect(view.metalLayer.maximumDrawableCount == 3)
        if let primary = ScreenGeometry.primaryDisplay(in: displays) {
            #expect(abs(metrics.cocoaFrame.height - (primary.cocoaFrame.height - 1.0)) <= 1.0)
        }

        // 4. macOS 27 invariant: NEVER mutate maximumDrawableCount after CAMetalDisplayLink attaches!
        view.markDisplayLinkAttached()
        #expect(view.hasAttachedDisplayLink == true)
        view.configureInitialMaximumDrawableCount(2)
        #expect(view.metalLayer.maximumDrawableCount == 3, "maximumDrawableCount must NEVER mutate post-attach!")

        // 5. Native Full-Screen Space level == 19
        _ = controller.prepareOverlay(
            sourceWindow: sourceWindow,
            profile: profile,
            isNativeFullscreenSpace: true
        )
        #expect(panel.level == NSWindow.Level(rawValue: 19))
        #expect(controller.isCoveringNativeFullscreenSpace == true)

        controller.close()
        #expect(controller.isSessionOpen == false)
        #expect(controller.isRevealed == false)
    }

    @Test("RenderLoopController marks CAMetalDisplayLink attached even when transitioning directPresent -> displayLink via updateConfiguration")
    func displayLinkAttachmentCallbackOnDynamicTransition() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on test host")
            return
        }

        let renderer = try EffectChainRenderer(device: device)
        let loop = try RenderLoopController(
            device: device,
            effectRenderer: renderer,
            frameInterpolator: renderer.videoToolboxML
        )
        defer { loop.stop() }

        let layer = makeOffscreenMetalLayer(device: device, width: 320, height: 180)
        let metrics = OverlayDrawableMetrics(
            cocoaFrame: CGRect(x: 0, y: 0, width: 160, height: 90),
            cgFrame: CGRect(x: 0, y: 0, width: 160, height: 90),
            drawablePixelSize: PixelSize(width: 320, height: 180),
            backingScaleFactor: 2.0,
            screenMaxFPS: 120.0,
            displayID: CGMainDisplayID(),
            supportsEDR: false,
            isVRRDirectScanoutActive: false
        )

        let markedAttached = OSAllocatedUnfairLock(initialState: false)
        var profile = Profile.defaultProfile
        profile.capture.lowLatencyPresent = true
        profile.frameGen.enabled = false

        // Start in `.directPresent` mode (no display link yet).
        loop.start(
            metalLayer: layer,
            configuration: RenderSessionConfiguration(
                targetWindowName: "TransitionTest",
                profile: profile,
                scalingMode: .defaultMode,
                overlayMetrics: metrics
            ),
            onMarkDisplayLinkAttached: {
                markedAttached.withLock { $0 = true }
            }
        )
        try await Task.sleep(for: .milliseconds(30))
        #expect(markedAttached.withLock { $0 } == false)

        // Transition dynamically to `.displayLink` by disabling lowLatencyPresent (or enabling FG).
        profile.capture.lowLatencyPresent = false
        loop.updateConfiguration(RenderSessionConfiguration(
            targetWindowName: "TransitionTest",
            profile: profile,
            scalingMode: .defaultMode,
            overlayMetrics: metrics
        ))

        let didMark = await waitForCondition(timeoutSeconds: 2.0) {
            markedAttached.withLock { $0 }
        }
        #expect(didMark, "onMarkDisplayLinkAttached MUST fire when transitioning directPresent -> displayLink via updateConfiguration!")
    }

    @Test("RenderLoopController does not double-count droppedFrames when mailbox supersedes frames")
    func droppedFramesNotDoubleCounted() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable on test host")
            return
        }

        let factory = try IOSurfaceFrameFactory(device: device)
        let renderer = try EffectChainRenderer(device: device)
        let loop = try RenderLoopController(device: device, effectRenderer: renderer)
        defer { loop.stop() }

        let layer = makeOffscreenMetalLayer(device: device, width: 320, height: 180)
        let metrics = OverlayDrawableMetrics(
            cocoaFrame: CGRect(x: 0, y: 0, width: 160, height: 90),
            cgFrame: CGRect(x: 0, y: 0, width: 160, height: 90),
            drawablePixelSize: PixelSize(width: 320, height: 180),
            backingScaleFactor: 2.0,
            screenMaxFPS: 60.0,
            displayID: CGMainDisplayID(),
            supportsEDR: false,
            isVRRDirectScanoutActive: false
        )

        var profile = Profile.defaultProfile
        profile.capture.lowLatencyPresent = true
        profile.capture.duplicateFrameMode = .never

        loop.start(
            metalLayer: layer,
            configuration: RenderSessionConfiguration(
                targetWindowName: "DropCountTest",
                profile: profile,
                scalingMode: .defaultMode,
                overlayMetrics: metrics
            )
        )

        let frame = try factory.makeBGRA8Frame(width: 160, height: 90) { _, _ in (100, 150, 200, 255) }
        // Ingest 5 frames back-to-back without yielding; at most 4 can ever be superseded!
        let totalIngested: UInt64 = 5
        for _ in 0..<totalIngested {
            loop.ingest(frame: frame)
        }
        try await Task.sleep(for: .milliseconds(80))

        let drops = loop.currentTelemetry.droppedFrames
        #expect(drops < totalIngested, "droppedFrames (\(drops)) cannot equal or exceed totalIngested (\(totalIngested)) — indicates double-counting!")
    }
}
