import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import Metal
import MetalPieCore
import MetalPieShaders
import Testing

@Suite("Metal Crash Guards, Fullscreen Video Super-Res & Legacy CaptureSettings")
struct CrashAndFullscreenVideoTests {

    // MARK: - Helpers

    private static func makeFourQuadrantTexture(
        device: any MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) throws -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = try #require(device.makeTexture(descriptor: desc))

        let halfW = width / 2
        let halfH = height / 2
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let bottom = y >= halfH
            let rowOff = y * width * 4
            for x in 0..<width {
                let right = x >= halfW
                let idx = rowOff + x * 4
                // Add subtle high-contrast grid lines inside each quadrant so upscalers process real edges,
                // while keeping each quadrant's dominant color unambiguous.
                let stripe = ((x + y) & 15) == 0
                let (r, g, b): (UInt8, UInt8, UInt8)
                switch (bottom, right) {
                case (false, false): // Top-Left: Vivid Red
                    (r, g, b) = stripe ? (210, 40, 40) : (235, 30, 30)
                case (false, true):  // Top-Right: Vivid Green
                    (r, g, b) = stripe ? (40, 210, 40) : (30, 235, 30)
                case (true, false):  // Bottom-Left: Vivid Blue
                    (r, g, b) = stripe ? (40, 70, 220) : (30, 55, 240)
                case (true, true):   // Bottom-Right: Vivid Yellow
                    (r, g, b) = stripe ? (220, 210, 40) : (242, 232, 30)
                }
                // BGRA byte order
                bytes[idx + 0] = b
                bytes[idx + 1] = g
                bytes[idx + 2] = r
                bytes[idx + 3] = 255
            }
        }
        tex.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: width * 4
        )
        return tex
    }

    private static func sampleBGRA8(
        texture: any MTLTexture,
        x: Int,
        y: Int
    ) -> (r: Float, g: Float, b: Float, a: Float) {
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &pixel,
            bytesPerRow: 4,
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: 0
        )
        return (
            r: Float(pixel[2]) / 255.0,
            g: Float(pixel[1]) / 255.0,
            b: Float(pixel[0]) / 255.0,
            a: Float(pixel[3]) / 255.0
        )
    }

    private static func makeSharedOutputTexture(
        device: any MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) throws -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: sanitizedComputeTextureFormat(pixelFormat),
            width: clampMetalTextureDimension(width),
            height: clampMetalTextureDimension(height),
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared
        return try #require(device.makeTexture(descriptor: desc))
    }

    private static func verifyAllFourQuadrantsFilled(
        outputTexture: any MTLTexture,
        label: String
    ) {
        let w = outputTexture.width
        let h = outputTexture.height
        let tl = sampleBGRA8(texture: outputTexture, x: w / 4, y: h / 4)
        let tr = sampleBGRA8(texture: outputTexture, x: (w * 3) / 4, y: h / 4)
        let bl = sampleBGRA8(texture: outputTexture, x: w / 4, y: (h * 3) / 4)
        let br = sampleBGRA8(texture: outputTexture, x: (w * 3) / 4, y: (h * 3) / 4)

        #expect(tl.r > 0.65 && tl.g < 0.35 && tl.b < 0.35, "\(label): Top-Left should be red, got \(tl)")
        #expect(tr.g > 0.65 && tr.r < 0.35 && tr.b < 0.35, "\(label): Top-Right should be green (NOT 1/4 shrunk!), got \(tr)")
        #expect(bl.b > 0.65 && bl.r < 0.35 && bl.g < 0.45, "\(label): Bottom-Left should be blue (NOT 1/4 shrunk!), got \(bl)")
        #expect(br.r > 0.65 && br.g > 0.65 && br.b < 0.35, "\(label): Bottom-Right should be yellow (NOT 1/4 shrunk!), got \(br)")
    }

    // MARK: - 1. Metal SIGABRT Crash Guards (>16384 Dimensions & Non-Compute Formats)

    @Test("Dimension clamping & format sanitization prevent Metal SIGABRT on >16384 and sRGB formats")
    func metalDimensionAndFormatCrashGuards() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try EffectChainRenderer(device: device)
        defer { renderer.reset() }

        // 1a. Shared format sanitizer maps sRGB & invalid formats to compute-writable equivalents.
        #expect(sanitizedComputeTextureFormat(.bgra8Unorm_srgb) == .bgra8Unorm)
        #expect(sanitizedComputeTextureFormat(.rgba8Unorm_srgb) == .rgba8Unorm)
        #expect(sanitizedComputeTextureFormat(.invalid) == .bgra8Unorm)
        #expect(sanitizedComputeTextureFormat(.bgra8Unorm) == .bgra8Unorm)
        #expect(sanitizedComputeTextureFormat(.bgr10a2Unorm) == .bgr10a2Unorm)
        #expect(sanitizedComputeTextureFormat(.rgba16Float) == .rgba16Float)

        // 1b. TexturePool clamps >16384 and sanitizes .bgra8Unorm_srgb / .rgba8Unorm_srgb / .invalid cleanly.
        let pool = TexturePool(device: device)
        let srgbLease = try pool.acquire(
            width: 22_336,
            height: 256,
            pixelFormat: .bgra8Unorm_srgb,
            usage: [.shaderRead, .shaderWrite, .renderTarget],
            storageMode: .private
        )
        #expect(srgbLease.texture.width == 16_384)
        #expect(srgbLease.texture.height == 256)
        #expect(srgbLease.texture.pixelFormat == .bgra8Unorm)
        srgbLease.releaseNow()

        let invalidLease = try pool.acquire(
            width: 128,
            height: 128,
            pixelFormat: .invalid,
            usage: [.shaderRead, .shaderWrite],
            storageMode: .private
        )
        #expect(invalidLease.texture.pixelFormat == .bgra8Unorm)
        invalidLease.releaseNow()
        pool.reset()

        // 1c. Extreme aspect ratio `.fill` (2000x100 -> 1920x1080 would be 21600x1080 > 16384!)
        let fillMode = ScalingMode(
            name: "ExtremeFill",
            effects: [EffectInstance(effectID: .metalFXSpatial, scalingType: .fill)]
        )
        let fillLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 2000, height: 100),
            targetPixelSize: PixelSize(width: 1920, height: 1080),
            effects: fillMode.effects
        )
        #expect(fillLayout.finalOutputPixelSize.width <= 16_384)
        #expect(fillLayout.finalOutputPixelSize.height <= 16_384)
        #expect(fillLayout.finalOutputPixelSize.width >= 1 && fillLayout.finalOutputPixelSize.height >= 1)
        for pass in fillLayout.effectPasses {
            #expect(pass.outputSize.width <= 16_384 && pass.outputSize.height <= 16_384)
        }
        // Actually execute extreme `.fill` on GPU (with `.bgra8Unorm_srgb` source!) -> ZERO SIGABRT.
        let extremeSrc = try Self.makeFourQuadrantTexture(
            device: device,
            width: 2000,
            height: 100,
            pixelFormat: .bgra8Unorm_srgb
        )
        let extremeDst = try Self.makeSharedOutputTexture(device: device, width: 1920, height: 1080)
        let fillCB = try #require(queue.makeCommandBuffer())
        _ = try renderer.encode(
            scalingMode: fillMode,
            context: EffectRenderContext(
                device: device,
                commandBuffer: fillCB,
                sourceTexture: extremeSrc,
                destinationTexture: extremeDst,
                layout: fillLayout,
                duplicateFrameMode: .never
            )
        )
        fillCB.commit()
        fillCB.waitUntilCompleted()
        #expect(fillCB.error == nil)

        // 1d. xBRZ 4x on dual-monitor `.all` (5584x1964 -> 22336x7856 > 16384!)
        let xbrz4xMode = ScalingMode(
            name: "xBRZ4xDual",
            effects: [
                EffectInstance(
                    effectID: .xbrzFreescale,
                    scalingType: .normal,
                    scaleFactorX: 4.0,
                    scaleFactorY: 4.0
                )
            ]
        )
        let xbrzLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 5584, height: 1964),
            targetPixelSize: PixelSize(width: 5584, height: 1964),
            effects: xbrz4xMode.effects
        )
        for pass in xbrzLayout.effectPasses {
            #expect(pass.outputSize.width <= 16_384 && pass.outputSize.height <= 16_384)
            #expect(pass.outputSize.width >= 1 && pass.outputSize.height >= 1)
        }
        #expect(xbrzLayout.finalOutputPixelSize.width <= 16_384)
        #expect(xbrzLayout.finalOutputPixelSize.height <= 16_384)
        // Execute real 5584x1964 xBRZ 4x on Apple Silicon GPU with zero crash!
        let dualSrc = try Self.makeFourQuadrantTexture(device: device, width: 5584, height: 1964)
        let dualDst = try Self.makeSharedOutputTexture(device: device, width: 5584, height: 1964)
        let xbrzCB = try #require(queue.makeCommandBuffer())
        _ = try renderer.encode(
            scalingMode: xbrz4xMode,
            context: EffectRenderContext(
                device: device,
                commandBuffer: xbrzCB,
                sourceTexture: dualSrc,
                destinationTexture: dualDst,
                layout: xbrzLayout,
                duplicateFrameMode: .never
            )
        )
        xbrzCB.commit()
        xbrzCB.waitUntilCompleted()
        #expect(xbrzCB.error == nil)
        renderer.reset()

        // 1e. `.absolute(20000, 20000)` clamps cleanly <= 16_384 on every pass and final output.
        let absLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 1280, height: 720),
            targetPixelSize: PixelSize(width: 2560, height: 1440),
            effects: [
                EffectInstance(
                    effectID: .bicubic,
                    scalingType: .absolute,
                    absoluteWidth: 20_000,
                    absoluteHeight: 20_000
                )
            ]
        )
        for pass in absLayout.effectPasses {
            #expect(pass.outputSize.width <= 16_384 && pass.outputSize.height <= 16_384)
        }
        #expect(absLayout.finalOutputPixelSize.width <= 16_384 && absLayout.finalOutputPixelSize.height <= 16_384)

        // 1f. Stacked fixed-2x Anime4K on 5584x1964 stays within intermediate cap <= 11168 (<= 16384).
        let stackedAnimeLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 5584, height: 1964),
            targetPixelSize: PixelSize(width: 5584, height: 1964),
            effects: [
                EffectInstance(effectID: .anime4kUpscale, scalingType: .normal),
                EffectInstance(effectID: .anime4kUpscale, scalingType: .fit)
            ]
        )
        for pass in stackedAnimeLayout.effectPasses {
            #expect(pass.outputSize.width <= 11_168 && pass.outputSize.height <= 11_168)
        }
        #expect(stackedAnimeLayout.finalOutputPixelSize == PixelSize(width: 5584, height: 1964))
    }

    // MARK: - 2. Bug #1: Fullscreen 3024x1964 Video Super-Resolution & Zero 1/4 Shrinking

    @Test("Fullscreen 3024x1964 video with .auto/.p720/.p1080 & demagnify=.bilinear covers all 4 quadrants cleanly")
    func fullscreenVideoSuperResolutionNoQuarterShrink() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try EffectChainRenderer(device: device)
        defer {
            renderer.demagnifyMode = .none
            renderer.fullscreenVideoPreDownscaleSize = nil
            renderer.reset()
        }

        let rawSize = PixelSize(width: 3024, height: 1964)
        let targetSize = PixelSize(width: 3024, height: 1964)
        let targetCGRect = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let srcTex = try Self.makeFourQuadrantTexture(device: device, width: rawSize.width, height: rawSize.height)
        let dstTex = try Self.makeSharedOutputTexture(device: device, width: targetSize.width, height: targetSize.height)

        let anime4kModeA = try #require(ScalingMode.builtInPresets.first { $0.id == ScalingMode.anime4kModeAID })
        let metalFXMode = try #require(ScalingMode.builtInPresets.first { $0.id == ScalingMode.metalFXSpatialID })
        let fsr1Mode = try #require(ScalingMode.builtInPresets.first { $0.id == ScalingMode.fsr1ID })

        let modesToTest: [(String, ScalingMode)] = [
            ("Anime4K Mode A", anime4kModeA),
            ("MetalFX", metalFXMode),
            ("FSR 1.0", fsr1Mode)
        ]

        // 2a. Verify `.auto`, `.p720`, `.p1080` (with AND without `demagnifyMode = .bilinear` active!)
        // for true fullscreen video (`isNativeFullscreenSource = true`), AND verify normal desktop Retina
        // webpages (`isNativeFullscreenSource = false`, `demagnifyMode = .none`, `.auto`) stay 1:1 native!
        let configs: [(label: String, inputMode: FullscreenVideoInputMode, demag: DemagnifyMode, isNativeFS: Bool, expectedInput: PixelSize)] = [
            ("nativeFS_auto+none", .auto, .none, true, PixelSize(width: 1512, height: 982)),
            ("desktopWebpage_auto+none_sharp1to1", .auto, .none, false, PixelSize(width: 3024, height: 1964)),
            ("auto+bilinear_coalesced", .auto, .bilinear, true, PixelSize(width: 1512, height: 982)),
            ("auto+bilinear_nonFS_coalesced", .auto, .bilinear, false, PixelSize(width: 1512, height: 982)),
            ("p720+bilinear", .p720, .bilinear, true, PixelSize(width: 1109, height: 720)),
            ("p1080+bilinear", .p1080, .bilinear, false, PixelSize(width: 1663, height: 1080)),
            ("native+bilinear", .native, .bilinear, true, PixelSize(width: 1512, height: 982))
        ]

        for cfg in configs {
            renderer.demagnifyMode = cfg.demag
            let resolved = ScalingLayoutCalculator.resolveEffectiveSourceSize(
                rawSourceSize: rawSize,
                targetPixelSize: targetSize,
                presentationMode: .fullscreen,
                fullscreenVideoInput: cfg.inputMode,
                demagnifyActive: renderer.isDemagnifyActive,
                isNativeFullscreenSource: cfg.isNativeFS
            )
            #expect(
                resolved.effectiveSize == cfg.expectedInput,
                "\(cfg.label): expected effective input \(cfg.expectedInput), got \(resolved.effectiveSize)"
            )
            if !cfg.isNativeFS && cfg.inputMode == .auto && cfg.demag == .none {
                #expect(resolved.videoPreDownscaleSize == nil, "Normal Retina desktop webpage must NOT pre-downscale")
            }
            renderer.fullscreenVideoPreDownscaleSize = resolved.videoPreDownscaleSize

            for (modeName, mode) in modesToTest {
                let layout = ScalingLayoutCalculator.calculate(
                    sourcePixelSize: resolved.effectiveSize,
                    targetPixelSize: targetSize,
                    targetCGRect: targetCGRect,
                    backingScaleFactor: 2.0,
                    crop: .zero,
                    effects: mode.effects,
                    presentationMode: .fullscreen,
                    alignment: .center
                )

                // Cursor mapping invariants: full contentRect (within 1pt rounding for p720/p1080 aspect fit)
                // and exact 100% source ratio so PointerMapping.effectiveSourceCGRect maps 1:1.
                #expect(abs(layout.contentRect.width - targetCGRect.width) <= 1.0, "\(cfg.label)/\(modeName) contentRect.width")
                #expect(abs(layout.contentRect.height - targetCGRect.height) <= 1.0, "\(cfg.label)/\(modeName) contentRect.height")
                #expect(layout.croppedSourceRect.width == layout.sourcePixelSize.width)
                #expect(layout.croppedSourceRect.height == layout.sourcePixelSize.height)
                #expect(layout.finalOutputPixelSize.width >= 3022 && layout.finalOutputPixelSize.height >= 1962)

                let cb = try #require(queue.makeCommandBuffer())
                let report = try renderer.encode(
                    scalingMode: mode,
                    context: EffectRenderContext(
                        device: device,
                        commandBuffer: cb,
                        sourceTexture: srcTex,
                        destinationTexture: dstTex,
                        layout: layout,
                        duplicateFrameMode: .never
                    )
                )
                cb.commit()
                cb.waitUntilCompleted()
                #expect(cb.error == nil, "\(cfg.label)/\(modeName) GPU error: \(String(describing: cb.error))")
                #expect(report.finalOutputSize.width >= 3022 && report.finalOutputSize.height >= 1962)

                Self.verifyAllFourQuadrantsFilled(outputTexture: dstTex, label: "\(cfg.label)/\(modeName)")
            }
        }

        // 2b. Verify GPU speed for Anime4K Mode A at 1512x982 -> 3024x1964 on Apple Silicon (warmed up).
        renderer.demagnifyMode = .bilinear
        let autoResolved = ScalingLayoutCalculator.resolveEffectiveSourceSize(
            rawSourceSize: rawSize,
            targetPixelSize: targetSize,
            presentationMode: .fullscreen,
            fullscreenVideoInput: .auto,
            demagnifyActive: true,
            isNativeFullscreenSource: true
        )
        renderer.fullscreenVideoPreDownscaleSize = autoResolved.videoPreDownscaleSize
        let animeLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: autoResolved.effectiveSize,
            targetPixelSize: targetSize,
            targetCGRect: targetCGRect,
            backingScaleFactor: 2.0,
            effects: anime4kModeA.effects,
            presentationMode: .fullscreen
        )
        // Exact 2x match: 1512x982 -> 3024x1964 needs NO auto-Bicubic fallback!
        #expect(!animeLayout.needsAutoBicubicFallback)
        #expect(animeLayout.finalOutputPixelSize == targetSize)
        var gpuSamplesMs: [Double] = []
        for _ in 0..<3 {
            let cb = try #require(queue.makeCommandBuffer())
            _ = try renderer.encode(
                scalingMode: anime4kModeA,
                context: EffectRenderContext(
                    device: device,
                    commandBuffer: cb,
                    sourceTexture: srcTex,
                    destinationTexture: dstTex,
                    layout: animeLayout,
                    duplicateFrameMode: .never
                )
            )
            cb.commit()
            cb.waitUntilCompleted()
            let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
            if gpuMs > 0 { gpuSamplesMs.append(gpuMs) }
        }
        if let bestMs = gpuSamplesMs.min() {
            #expect(bestMs < 40.0, "Anime4K Mode A at 1512x982->3024x1964 should be fast on M4 Pro (got \(bestMs) ms)")
        }

        // 2c. Direct caller reconciliation safety net: even if a caller passes UN-HALVED 3024x1964 layout
        // while `demagnifyMode = .bilinear`, EffectChainRenderer reconciles passes -> STILL covers all 4 quadrants!
        renderer.fullscreenVideoPreDownscaleSize = nil
        renderer.demagnifyMode = .bilinear
        let unadjustedLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: rawSize,
            targetPixelSize: targetSize,
            targetCGRect: targetCGRect,
            backingScaleFactor: 2.0,
            effects: anime4kModeA.effects,
            presentationMode: .fullscreen
        )
        let reconcileCB = try #require(queue.makeCommandBuffer())
        _ = try renderer.encode(
            scalingMode: anime4kModeA,
            context: EffectRenderContext(
                device: device,
                commandBuffer: reconcileCB,
                sourceTexture: srcTex,
                destinationTexture: dstTex,
                layout: unadjustedLayout,
                duplicateFrameMode: .never
            )
        )
        reconcileCB.commit()
        reconcileCB.waitUntilCompleted()
        #expect(reconcileCB.error == nil)
        Self.verifyAllFourQuadrantsFilled(outputTexture: dstTex, label: "DirectUnadjustedDemag/Anime4K")

        // 2d. Verify proportional crop scaling preserves exact normalized source crop ratios for cursor mapping.
        let rawCrop = CropInsets(enabled: true, left: 200, top: 100, right: 200, bottom: 100)
        let scaledCrop = rawCrop.scaled(from: rawSize, to: PixelSize(width: 1512, height: 982))
        let rawCroppedRect = rawCrop.croppedRect(in: rawSize)
        let scaledCroppedRect = scaledCrop.croppedRect(in: PixelSize(width: 1512, height: 982))
        #expect(abs(Double(rawCroppedRect.x) / Double(rawSize.width) - Double(scaledCroppedRect.x) / 1512.0) < 0.002)
        #expect(abs(Double(rawCroppedRect.y) / Double(rawSize.height) - Double(scaledCroppedRect.y) / 982.0) < 0.002)
        #expect(abs(Double(rawCroppedRect.width) / Double(rawSize.width) - Double(scaledCroppedRect.width) / 1512.0) < 0.002)
        #expect(abs(Double(rawCroppedRect.height) / Double(rawSize.height) - Double(scaledCroppedRect.height) / 982.0) < 0.002)
    }

    // MARK: - 2b. Padded SCStream IOSurface (3024x1898 with active contentRect 2705x1764) -> Zero Right Black Strip!

    @Test("Padded 3024x1898 IOSurface with active contentRect (0,0,2705,1764) crops black padding cleanly and fills all 4 quadrants of 3024x1964")
    func paddedIOSurfaceContentRectCropsBlackStripOnRealGPU() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try EffectChainRenderer(device: device)
        defer {
            renderer.sourceContentPixelRect = nil
            renderer.fullscreenVideoPreDownscaleSize = nil
            renderer.demagnifyMode = .none
            renderer.reset()
        }

        let surfaceW = 3024
        let surfaceH = 1898
        let activeW = 2705
        let activeH = 1764
        let targetSize = PixelSize(width: 3024, height: 1964)
        let targetCGRect = CGRect(x: 0, y: 0, width: 1512, height: 982)

        // Build a real 3024x1898 BGRA8 texture where active (0,0,2705,1764) is vivid 4-quadrant video
        // and x = 2705..<3024 plus y = 1764..<1898 are solid pure black (exact Bilibili SCStream padding!).
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: surfaceW,
            height: surfaceH,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let paddedTex = try #require(device.makeTexture(descriptor: desc))
        var bytes = [UInt8](repeating: 0, count: surfaceW * surfaceH * 4)
        let halfW = activeW / 2
        let halfH = activeH / 2
        for y in 0..<surfaceH {
            let rowOff = y * surfaceW * 4
            for x in 0..<surfaceW {
                let idx = rowOff + x * 4
                if x >= activeW || y >= activeH {
                    // Solid black SCK padding bar on right (10.55%) & bottom!
                    bytes[idx + 0] = 0
                    bytes[idx + 1] = 0
                    bytes[idx + 2] = 0
                    bytes[idx + 3] = 255
                    continue
                }
                let bottom = y >= halfH
                let right = x >= halfW
                let (r, g, b): (UInt8, UInt8, UInt8)
                switch (bottom, right) {
                case (false, false): (r, g, b) = (235, 30, 30)   // Red
                case (false, true):  (r, g, b) = (30, 235, 30)   // Green
                case (true, false):  (r, g, b) = (30, 55, 240)   // Blue
                case (true, true):   (r, g, b) = (242, 232, 30)  // Yellow
                }
                bytes[idx + 0] = b
                bytes[idx + 1] = g
                bytes[idx + 2] = r
                bytes[idx + 3] = 255
            }
        }
        paddedTex.replace(
            region: MTLRegionMake2D(0, 0, surfaceW, surfaceH),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: surfaceW * 4
        )

        // Convert SCStreamFrameInfo.contentRect (points @ 2x) -> pixel sub-rect
        let pixelContentRect = ScalingLayoutCalculator.convertSCKContentRectToPixels(
            pointRect: CGRect(x: 0, y: 0, width: Double(activeW) / 2.0, height: Double(activeH) / 2.0),
            scaleFactor: 2.0,
            textureSize: PixelSize(width: surfaceW, height: surfaceH)
        )
        let subRect = try #require(
            ScalingLayoutCalculator.activeContentSubRect(
                contentPixelRect: pixelContentRect,
                textureSize: PixelSize(width: surfaceW, height: surfaceH)
            )
        )
        #expect(subRect == PixelRect(x: 0, y: 0, width: activeW, height: activeH))

        let dstTex = try Self.makeSharedOutputTexture(device: device, width: targetSize.width, height: targetSize.height)
        let anime4kModeA = try #require(ScalingMode.builtInPresets.first { $0.id == ScalingMode.anime4kModeAID })
        let metalFXMode = try #require(ScalingMode.builtInPresets.first { $0.id == ScalingMode.metalFXSpatialID })
        let fsr1Mode = try #require(ScalingMode.builtInPresets.first { $0.id == ScalingMode.fsr1ID })

        for (label, mode) in [("Anime4K Mode A", anime4kModeA), ("MetalFX", metalFXMode), ("FSR 1.0", fsr1Mode)] {
            let resolved = ScalingLayoutCalculator.resolveEffectiveSourceSize(
                rawSourceSize: subRect.size,
                targetPixelSize: targetSize,
                presentationMode: .fullscreen,
                fullscreenVideoInput: .auto,
                demagnifyActive: false,
                isNativeFullscreenSource: true
            )
            #expect(resolved.effectiveSize == PixelSize(width: activeW / 2, height: activeH / 2))

            renderer.sourceContentPixelRect = subRect
            renderer.fullscreenVideoPreDownscaleSize = resolved.videoPreDownscaleSize

            let layout = ScalingLayoutCalculator.calculate(
                sourcePixelSize: resolved.effectiveSize,
                targetPixelSize: targetSize,
                targetCGRect: targetCGRect,
                backingScaleFactor: 2.0,
                crop: .zero,
                effects: mode.effects,
                presentationMode: .fullscreen,
                alignment: .center
            )
            // Verify layout spans ~100% of width (zero 10.55% right black bar!) and keeps 1:1 croppedSourceRect for PointerMapping.
            #expect(layout.visibleContentPixelRect.width >= 3008, "\(label): expected near-full width, got \(layout.visibleContentPixelRect.width)")
            #expect(layout.visibleContentPixelRect.height == 1964)
            #expect(layout.croppedSourceRect.width == layout.sourcePixelSize.width)
            #expect(layout.croppedSourceRect.height == layout.sourcePixelSize.height)

            let cb = try #require(queue.makeCommandBuffer())
            _ = try renderer.encode(
                scalingMode: mode,
                context: EffectRenderContext(
                    device: device,
                    commandBuffer: cb,
                    sourceTexture: paddedTex,
                    destinationTexture: dstTex,
                    layout: layout,
                    duplicateFrameMode: .never
                )
            )
            cb.commit()
            cb.waitUntilCompleted()
            #expect(cb.error == nil)

            Self.verifyAllFourQuadrantsFilled(outputTexture: dstTex, label: "PaddedContentRect/\(label)")

            // Explicitly probe the exact right-hand strip region (x = 95%..99% of 3024px) where the old
            // Bilibili screenshot showed a solid black bar (`x = 89.45%..100%`) -> MUST be vivid Green / Yellow!
            let farRightTop = Self.sampleBGRA8(texture: dstTex, x: 2980, y: 400)
            let farRightBottom = Self.sampleBGRA8(texture: dstTex, x: 2980, y: 1500)
            #expect(farRightTop.g > 0.65 && farRightTop.r < 0.35, "\(label): far-right top must be green (zero black strip!), got \(farRightTop)")
            #expect(farRightBottom.r > 0.65 && farRightBottom.g > 0.65 && farRightBottom.b < 0.35, "\(label): far-right bottom must be yellow (zero black strip!), got \(farRightBottom)")
        }
    }

    // MARK: - 2c. Eliminating Redundant 23MB/Frame Output Snapshot GPU Blits (`usesExternalOutputCache`)

    @Test("External output cache mode eliminates redundant per-frame snapshot GPU blits while preserving zero-stall IOSurface duplicate skip")
    func externalOutputCacheEliminatesSnapshotBlits() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try EffectChainRenderer(device: device)
        defer { renderer.reset() }

        // Configure exactly as `RenderLoopController.init` does:
        renderer.usesExternalOutputCache = true

        let width = 320
        let height = 180
        let props: [IOSurfacePropertyKey: Int] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: width * 4,
            .allocSize: width * height * 4,
            .pixelFormat: Int(kCVPixelFormatType_32BGRA)
        ]
        let surface = try #require(IOSurface(properties: props))
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        srcDesc.usage = [.shaderRead]
        srcDesc.storageMode = .shared
        let srcTex = try #require(device.makeTexture(descriptor: srcDesc, iosurface: surface, plane: 0))
        let dstTex = try Self.makeSharedOutputTexture(device: device, width: 640, height: 360)

        let mode = try #require(ScalingMode.builtInPresets.first { $0.id == ScalingMode.metalFXSpatialID })
        let layout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: width, height: height),
            targetPixelSize: PixelSize(width: 640, height: 360),
            effects: mode.effects
        )

        // Frame 0 (.dynamic): renders cleanly with ZERO snapshot blit!
        let cb0 = try #require(queue.makeCommandBuffer())
        let rep0 = try renderer.encode(
            scalingMode: mode,
            context: EffectRenderContext(
                device: device,
                commandBuffer: cb0,
                sourceTexture: srcTex,
                destinationTexture: dstTex,
                layout: layout,
                frameIndex: 0,
                duplicateFrameMode: .dynamic
            )
        )
        cb0.commit()
        cb0.waitUntilCompleted()
        #expect(rep0.wasDuplicateFrameSkipped == false)
        #expect(renderer.outputSnapshotBlitCount == 0, "External output cache mode must perform ZERO full-frame snapshot blits!")

        // Frames 1..5 (unchanged IOSurface with .dynamic): zero-stall duplicate skip STILL works with ZERO snapshot blits!
        for i in 1...5 {
            let cb = try #require(queue.makeCommandBuffer())
            let rep = try renderer.encode(
                scalingMode: mode,
                context: EffectRenderContext(
                    device: device,
                    commandBuffer: cb,
                    sourceTexture: srcTex,
                    destinationTexture: dstTex,
                    layout: layout,
                    frameIndex: UInt64(i),
                    duplicateFrameMode: .dynamic
                )
            )
            cb.commit()
            cb.waitUntilCompleted()
            #expect(rep.wasDuplicateFrameSkipped == true, "Frame \(i) on unchanged IOSurface should still skip cleanly")
        }
        #expect(renderer.outputSnapshotBlitCount == 0, "Expected 0 snapshot blits across all frames when externalOutputCache is enabled!")
    }

    // MARK: - 3. Backward-Compatible CaptureSettings JSON Decoding

    @Test("Legacy CaptureSettings JSON without fullscreenVideoInput decodes cleanly as .auto")
    func backwardCompatibleCaptureSettingsDecoding() throws {
        let legacyJSON = """
        {
            "captureMode": "window",
            "captureTitleBar": false,
            "ignoreShadows": true,
            "preferredPixelFormat": "bgra8",
            "dynamicRange": "sdr",
            "duplicateFrameMode": "dynamic",
            "lowLatencyPresent": true
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(CaptureSettings.self, from: data)
        #expect(decoded.captureMode == .window)
        #expect(decoded.ignoreShadows == true)
        #expect(decoded.lowLatencyPresent == true)
        #expect(decoded.fullscreenVideoInput == .auto)

        // Also verify round-trip encoding/decoding of every FullscreenVideoInputMode case.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mode in FullscreenVideoInputMode.allCases {
            let original = CaptureSettings(
                captureMode: .window,
                dynamicRange: .hdr,
                frameRateLimit: 120,
                duplicateFrameMode: .never,
                lowLatencyPresent: false,
                fullscreenVideoInput: mode
            )
            let encoded = try encoder.encode(original)
            let roundTripped = try decoder.decode(CaptureSettings.self, from: encoded)
            #expect(roundTripped == original)
            #expect(roundTripped.fullscreenVideoInput == mode)
        }
    }
}
