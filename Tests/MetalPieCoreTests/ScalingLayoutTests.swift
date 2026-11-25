import CoreGraphics
import Testing
@testable import MetalPieCore

@Suite("ScalingLayoutCalculator & Crop/Alignment Math")
struct ScalingLayoutTests {
    @Test("All 6 ScalingTypes compute expected output dimensions")
    func allScalingTypes() {
        let source4by3 = PixelSize(width: 800, height: 600)
        let target16by9 = PixelSize(width: 2560, height: 1440)

        // 1. Fit: preserves 4:3 inside 2560x1440 -> 1920x1440 (pillarboxed)
        let fit = ScalingLayoutCalculator.calculate(
            sourcePixelSize: source4by3,
            targetPixelSize: target16by9,
            effects: [EffectInstance(effectID: .metalFXSpatial, scalingType: .fit)]
        )
        #expect(fit.finalOutputPixelSize == PixelSize(width: 1920, height: 1440))
        #expect(fit.destinationPixelRect == PixelRect(x: 320, y: 0, width: 1920, height: 1440))
        #expect(fit.visibleContentPixelRect == fit.destinationPixelRect)
        #expect(!fit.needsAutoBicubicFallback)

        // 2. Fill: covers 2560x1440 while preserving 4:3 -> 2560x1920, centered at y = -240, visible clipped to 2560x1440
        let fill = ScalingLayoutCalculator.calculate(
            sourcePixelSize: source4by3,
            targetPixelSize: target16by9,
            effects: [EffectInstance(effectID: .metalFXSpatial, scalingType: .fill)]
        )
        #expect(fill.finalOutputPixelSize == PixelSize(width: 2560, height: 1920))
        #expect(fill.destinationPixelRect == PixelRect(x: 0, y: -240, width: 2560, height: 1920))
        #expect(fill.visibleContentPixelRect == PixelRect(x: 0, y: 0, width: 2560, height: 1440))
        #expect(abs(fill.visibleTextureUVRect.origin.y - 0.125) < 1e-6)
        #expect(abs(fill.visibleTextureUVRect.size.height - 0.75) < 1e-6)
        #expect(!fill.needsAutoBicubicFallback)

        // 3. Stretch: non-uniform fill to exact target 2560x1440
        let stretch = ScalingLayoutCalculator.calculate(
            sourcePixelSize: source4by3,
            targetPixelSize: target16by9,
            effects: [EffectInstance(effectID: .lanczos6, scalingType: .stretch)]
        )
        #expect(stretch.finalOutputPixelSize == target16by9)
        #expect(stretch.destinationPixelRect == PixelRect(x: 0, y: 0, width: 2560, height: 1440))
        #expect(!stretch.needsAutoBicubicFallback)

        // 4. IntegerFit: floor(min(2560/800, 1440/600)) = floor(min(3.2, 2.4)) = 2 -> 1600x1200 centered
        let integerFit = ScalingLayoutCalculator.calculate(
            sourcePixelSize: source4by3,
            targetPixelSize: target16by9,
            effects: [EffectInstance(effectID: .nearest, scalingType: .integerFit)]
        )
        #expect(integerFit.finalOutputPixelSize == PixelSize(width: 1600, height: 1200))
        #expect(integerFit.destinationPixelRect == PixelRect(x: 480, y: 120, width: 1600, height: 1200))
        #expect(!integerFit.needsAutoBicubicFallback)

        // 5. Normal: explicit 1.5x x 2.0x multiplier -> 1200x1200
        let normal = ScalingLayoutCalculator.calculate(
            sourcePixelSize: source4by3,
            targetPixelSize: target16by9,
            effects: [EffectInstance(effectID: .bicubic, scalingType: .normal, scaleFactorX: 1.5, scaleFactorY: 2.0)]
        )
        #expect(normal.finalOutputPixelSize == PixelSize(width: 1200, height: 1200))
        #expect(!normal.needsAutoBicubicFallback)

        // 6. Absolute: exact 1920x1080 inside 2560x1440
        let absolute = ScalingLayoutCalculator.calculate(
            sourcePixelSize: source4by3,
            targetPixelSize: target16by9,
            effects: [EffectInstance(effectID: .bicubic, scalingType: .absolute, absoluteWidth: 1920, absoluteHeight: 1080)]
        )
        #expect(absolute.finalOutputPixelSize == PixelSize(width: 1920, height: 1080))
        #expect(absolute.destinationPixelRect == PixelRect(x: 320, y: 180, width: 1920, height: 1080))
        #expect(!absolute.needsAutoBicubicFallback)
    }

    @Test("All 9 OutputAlignment positions and Retina logical contentRect mapping")
    func allNineAlignments() {
        let source = PixelSize(width: 500, height: 400)
        let targetPixels = PixelSize(width: 2000, height: 1200)
        let targetCG = CGRect(x: 100, y: 50, width: 1000, height: 600) // 2x Retina

        // Output via 2x normal = 1000x800 pixels inside 2000x1200 -> slack X=1000, Y=400
        let expectedOrigins: [(OutputAlignment, Int, Int)] = [
            (.topLeft, 0, 0),
            (.top, 500, 0),
            (.topRight, 1000, 0),
            (.left, 0, 200),
            (.center, 500, 200),
            (.right, 1000, 200),
            (.bottomLeft, 0, 400),
            (.bottom, 500, 400),
            (.bottomRight, 1000, 400)
        ]

        for (alignment, expectedX, expectedY) in expectedOrigins {
            let layout = ScalingLayoutCalculator.calculate(
                sourcePixelSize: source,
                targetPixelSize: targetPixels,
                targetCGRect: targetCG,
                backingScaleFactor: 2.0,
                effects: [EffectInstance(effectID: .nearest, scalingType: .normal, scaleFactorX: 2.0, scaleFactorY: 2.0)],
                alignment: alignment
            )

            #expect(layout.destinationPixelRect == PixelRect(x: expectedX, y: expectedY, width: 1000, height: 800))
            // Check logical CG contentRect = targetCG.origin + pixelRect / 2.0
            let expectedCG = CGRect(
                x: 100.0 + Double(expectedX) / 2.0,
                y: 50.0 + Double(expectedY) / 2.0,
                width: 500.0,
                height: 400.0
            )
            #expect(layout.contentRect == expectedCG)
        }
    }

    @Test("Crop insets clamping enforces 64px minimum remaining width and height")
    func cropClampingMinimum64px() {
        let source = PixelSize(width: 200, height: 150)

        // Disabled crop yields full source rect
        let disabledCrop = CropInsets(enabled: false, left: 100, top: 100, right: 100, bottom: 100)
        #expect(disabledCrop.croppedRect(in: source) == PixelRect(x: 0, y: 0, width: 200, height: 150))

        // Valid crop
        let validCrop = CropInsets(enabled: true, left: 20, top: 10, right: 30, bottom: 20)
        #expect(validCrop.isValid(for: source))
        #expect(validCrop.croppedRect(in: source) == PixelRect(x: 20, y: 10, width: 150, height: 120))

        // Excessive symmetric crop (left=100, right=100 on width=200 -> max crop = 136 -> left=68, right=68, rem=64)
        let excessiveSymmetric = CropInsets(enabled: true, left: 100, top: 80, right: 100, bottom: 80)
        #expect(!excessiveSymmetric.isValid(for: source))
        let clampedSym = excessiveSymmetric.croppedRect(in: source)
        #expect(clampedSym.width >= CropInsets.minimumRemainingDimension)
        #expect(clampedSym.height >= CropInsets.minimumRemainingDimension)
        #expect(clampedSym.width == 64)
        #expect(clampedSym.height == 64)

        // Excessive one-sided crop (left=500, right=0 on width=200 -> left=136, right=0, rem=64)
        let excessiveOneSided = CropInsets(enabled: true, left: 500, top: 0, right: 0, bottom: 300)
        let clampedOne = excessiveOneSided.croppedRect(in: source)
        #expect(clampedOne.x == 136)
        #expect(clampedOne.width == 64)
        #expect(clampedOne.y == 0)
        #expect(clampedOne.height == 64)

        // Source already smaller than 64px does not crash or produce zero dimensions
        let tinySource = PixelSize(width: 48, height: 32)
        let tinyCropped = excessiveSymmetric.croppedRect(in: tinySource)
        #expect(tinyCropped == PixelRect(x: 0, y: 0, width: 48, height: 32))
    }

    @Test("Chained effects and auto-Bicubic fallback detection")
    func chainedEffectsAndAutoBicubicFallback() {
        // Case A: FSR 1.0 chain (EASU Fit -> RCAS 1x) on 720p -> 1440p needs NO fallback
        let fsrLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 1280, height: 720),
            targetPixelSize: PixelSize(width: 2560, height: 1440),
            effects: ScalingMode.builtInPresets.first(where: { $0.id == ScalingMode.fsr1ID })!.effects
        )
        #expect(fsrLayout.effectPasses.count == 2)
        #expect(fsrLayout.effectPasses[0].effectID == .fsr1EASU)
        #expect(fsrLayout.effectPasses[0].outputSize == PixelSize(width: 2560, height: 1440))
        #expect(fsrLayout.effectPasses[1].effectID == .fsr1RCAS)
        #expect(fsrLayout.effectPasses[1].inputSize == PixelSize(width: 2560, height: 1440))
        #expect(fsrLayout.effectPasses[1].outputSize == PixelSize(width: 2560, height: 1440))
        #expect(!fsrLayout.needsAutoBicubicFallback)

        // Case B: Fixed-2x Anime4K configured with `.fit` on 720p -> Retina 3024x1964
        // Pass 1 outputs 2560x1440, Pass 2 auto-appends Bicubic -> 3024x1701
        let animeLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 1280, height: 720),
            targetPixelSize: PixelSize(width: 3024, height: 1964),
            effects: [EffectInstance(effectID: .anime4kUpscaleDenoise, scalingType: .fit)]
        )
        #expect(animeLayout.needsAutoBicubicFallback)
        #expect(animeLayout.effectPasses.count == 2)
        #expect(animeLayout.effectPasses[0].outputSize == PixelSize(width: 2560, height: 1440))
        #expect(animeLayout.effectPasses[1].effectID == .bicubic)
        #expect(animeLayout.effectPasses[1].isAutoInsertedFallback)
        #expect(animeLayout.effectPasses[1].outputSize == PixelSize(width: 3024, height: 1701))

        // Case C: Fixed-2x FSRCNNX (.normal) on 1080p targeting 1440p overflows -> auto-Bicubic downscales to 2560x1440
        let fsrcnnxOverflow = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 1920, height: 1080),
            targetPixelSize: PixelSize(width: 2560, height: 1440),
            effects: [EffectInstance(effectID: .fsrcnnx, scalingType: .normal)]
        )
        #expect(fsrcnnxOverflow.needsAutoBicubicFallback)
        #expect(fsrcnnxOverflow.effectPasses.count == 2)
        #expect(fsrcnnxOverflow.effectPasses[0].outputSize == PixelSize(width: 3840, height: 2160))
        #expect(fsrcnnxOverflow.effectPasses[1].effectID == .bicubic)
        #expect(fsrcnnxOverflow.effectPasses[1].outputSize == PixelSize(width: 2560, height: 1440))

        // Case D: Windowed mode with fixed-2x shader resized to non-exact 1800x1012 triggers auto-Bicubic
        let windowedLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 640, height: 360),
            targetPixelSize: PixelSize(width: 1800, height: 1012),
            effects: [EffectInstance(effectID: .nearest, scalingType: .normal, scaleFactorX: 2.0, scaleFactorY: 2.0)],
            presentationMode: .windowed(initialScale: 2.5, width: 900)
        )
        #expect(windowedLayout.needsAutoBicubicFallback)
        #expect(windowedLayout.finalOutputPixelSize == PixelSize(width: 1800, height: 1012))

        // Case E: Disabled effects are ignored cleanly
        let withDisabled = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 1280, height: 720),
            targetPixelSize: PixelSize(width: 2560, height: 1440),
            effects: [
                EffectInstance(effectID: .metalFXSpatial, enabled: true, scalingType: .fit),
                EffectInstance(effectID: .cas, enabled: false, scalingType: .normal)
            ]
        )
        #expect(withDisabled.effectPasses.count == 1)
        #expect(withDisabled.effectPasses[0].effectID == .metalFXSpatial)
    }

    @Test("Fencepost-accurate cursor coordinate mapping round-trip")
    func cursorCoordinateMapping() {
        let src = CGRect(x: 100, y: 200, width: 640, height: 360)
        let dst = CGRect(x: 0, y: 120, width: 1920, height: 1080)

        // First pixel -> first pixel
        let topLeft = ScalingLayoutCalculator.mapSourcePointToScaled(
            CGPoint(x: 100, y: 200),
            sourceRect: src,
            contentRect: dst
        )
        #expect(topLeft == CGPoint(x: 0, y: 120))

        // Last pixel -> last pixel
        let bottomRight = ScalingLayoutCalculator.mapSourcePointToScaled(
            CGPoint(x: 739, y: 559),
            sourceRect: src,
            contentRect: dst
        )
        #expect(abs(bottomRight.x - 1919) < 1e-6)
        #expect(abs(bottomRight.y - 1199) < 1e-6)

        // Interior point round-trip
        let sample = CGPoint(x: 419.5, y: 379.5)
        let scaled = ScalingLayoutCalculator.mapSourcePointToScaled(sample, sourceRect: src, contentRect: dst)
        let roundTrip = ScalingLayoutCalculator.mapScaledPointToSource(scaled, sourceRect: src, contentRect: dst)
        #expect(abs(roundTrip.x - sample.x) < 1e-6)
        #expect(abs(roundTrip.y - sample.y) < 1e-6)
    }

    @Test("SCStreamFrameInfo.contentRect point-to-pixel conversion and active sub-rect detection")
    func sckContentRectConversionAndSubRect() {
        // Case A: Wider Retina 2x buffer (1200x600) containing 400x300pt window -> active pixels (0, 0, 800, 600)
        let widerPx = ScalingLayoutCalculator.convertSCKContentRectToPixels(
            pointRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            scaleFactor: 2.0,
            textureSize: PixelSize(width: 1200, height: 600)
        )
        #expect(widerPx == CGRect(x: 0, y: 0, width: 800, height: 600))
        let widerSub = ScalingLayoutCalculator.activeContentSubRect(
            contentPixelRect: widerPx,
            textureSize: PixelSize(width: 1200, height: 600)
        )
        #expect(widerSub == PixelRect(x: 0, y: 0, width: 800, height: 600))

        // Case B: Downscaled Retina 2x stream (contentScale=0.5 already folded into 200x150pt contentRect)
        let downscaledPx = ScalingLayoutCalculator.convertSCKContentRectToPixels(
            pointRect: CGRect(x: 0, y: 0, width: 200, height: 150),
            scaleFactor: 2.0,
            textureSize: PixelSize(width: 700, height: 300)
        )
        #expect(downscaledPx == CGRect(x: 0, y: 0, width: 400, height: 300))

        // Case C: Bilibili padded IOSurface (3024x1898 with active 1352.5x882pt @2x -> 2705x1764px)
        let bilibiliPx = ScalingLayoutCalculator.convertSCKContentRectToPixels(
            pointRect: CGRect(x: 0, y: 0, width: 1352.5, height: 882.0),
            scaleFactor: 2.0,
            textureSize: PixelSize(width: 3024, height: 1898)
        )
        #expect(bilibiliPx == CGRect(x: 0, y: 0, width: 2705, height: 1764))
        let bilibiliSub = ScalingLayoutCalculator.activeContentSubRect(
            contentPixelRect: bilibiliPx,
            textureSize: PixelSize(width: 3024, height: 1898)
        )
        #expect(bilibiliSub == PixelRect(x: 0, y: 0, width: 2705, height: 1764))

        // Case D: Exact match (within 1px rounding) returns nil so unpadded path stays zero-copy
        let exactPx = ScalingLayoutCalculator.convertSCKContentRectToPixels(
            pointRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            scaleFactor: 2.0,
            textureSize: PixelSize(width: 3024, height: 1964)
        )
        #expect(exactPx == CGRect(x: 0, y: 0, width: 3024, height: 1964))
        #expect(ScalingLayoutCalculator.activeContentSubRect(
            contentPixelRect: exactPx,
            textureSize: PixelSize(width: 3024, height: 1964)
        ) == nil)
        #expect(ScalingLayoutCalculator.activeContentSubRect(
            contentPixelRect: CGRect(x: 0, y: 0, width: 3023, height: 1963),
            textureSize: PixelSize(width: 3024, height: 1964)
        ) == nil)

        // Case E: Nil pointRect falls back cleanly to full texture pixel bounds
        let fallbackPx = ScalingLayoutCalculator.convertSCKContentRectToPixels(
            pointRect: nil,
            scaleFactor: 2.0,
            textureSize: PixelSize(width: 1920, height: 1080)
        )
        #expect(fallbackPx == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test("Pre-downscale gating requires fullscreen && coversTarget and never blurs normal Retina webpages")
    func fullscreenVideoPreDownscaleGating() {
        let retinaWebpage = PixelSize(width: 3024, height: 1898)
        let retinaDisplay = PixelSize(width: 3024, height: 1964)

        // 1. Normal maximized Retina Chrome webpage (isNativeFullscreenSource=false, demagnifyActive=false) -> NO blur!
        let webpageAuto = ScalingLayoutCalculator.resolveEffectiveSourceSize(
            rawSourceSize: retinaWebpage,
            targetPixelSize: retinaDisplay,
            presentationMode: .fullscreen,
            fullscreenVideoInput: .auto,
            demagnifyActive: false,
            isNativeFullscreenSource: false
        )
        #expect(webpageAuto.videoPreDownscaleSize == nil)
        #expect(webpageAuto.effectiveSize == retinaWebpage)

        // 2. Windowed mode covering >=85% of target -> NEVER pre-downscales (fixes `||` -> `&&` bug!)
        for mode in [FullscreenVideoInputMode.auto, .p720, .p1080, .native] {
            let windowed = ScalingLayoutCalculator.computeFullscreenVideoPreDownscaleSize(
                rawSourceSize: retinaDisplay,
                targetPixelSize: retinaDisplay,
                presentationMode: .windowed(initialScale: 1.0, width: 1512),
                mode: mode,
                isNativeFullscreenSource: true,
                demagnifyActive: true
            )
            #expect(windowed == nil, "Windowed mode must never trigger fullscreen video pre-downscale for \(mode)")
        }

        // 3. Small 720p window in fullscreen presentation -> coversTarget is false -> NEVER pre-downscales!
        let small720p = ScalingLayoutCalculator.computeFullscreenVideoPreDownscaleSize(
            rawSourceSize: PixelSize(width: 1280, height: 720),
            targetPixelSize: retinaDisplay,
            presentationMode: .fullscreen,
            mode: .p720,
            isNativeFullscreenSource: true,
            demagnifyActive: false
        )
        #expect(small720p == nil)

        // 4. True HTML5/IINA/VLC native fullscreen video (.auto + isNativeFullscreenSource=true) -> 50% pre-downscale
        let nativeVideoAuto = ScalingLayoutCalculator.resolveEffectiveSourceSize(
            rawSourceSize: retinaDisplay,
            targetPixelSize: retinaDisplay,
            presentationMode: .fullscreen,
            fullscreenVideoInput: .auto,
            demagnifyActive: false,
            isNativeFullscreenSource: true
        )
        #expect(nativeVideoAuto.videoPreDownscaleSize == PixelSize(width: 1512, height: 982))
        #expect(nativeVideoAuto.effectiveSize == PixelSize(width: 1512, height: 982))

        // 5. Explicit .p720 / .p1080 on fullscreen target-covering window works even when isNativeFullscreenSource=false
        let explicit720 = ScalingLayoutCalculator.computeFullscreenVideoPreDownscaleSize(
            rawSourceSize: retinaDisplay,
            targetPixelSize: retinaDisplay,
            presentationMode: .fullscreen,
            mode: .p720,
            isNativeFullscreenSource: false,
            demagnifyActive: false
        )
        #expect(explicit720 == PixelSize(width: 1109, height: 720))

        let explicit1080 = ScalingLayoutCalculator.computeFullscreenVideoPreDownscaleSize(
            rawSourceSize: retinaDisplay,
            targetPixelSize: retinaDisplay,
            presentationMode: .fullscreen,
            mode: .p1080,
            isNativeFullscreenSource: false,
            demagnifyActive: false
        )
        #expect(explicit1080 == PixelSize(width: 1663, height: 1080))
    }

    @Test("DirectPresentPacer caps 150-240Hz bursts strictly to display refresh rate while passing jittered native frames immediately")
    func directPresentPacerCapsOverSubmission() {
        // 1. Default CaptureSettings.lowLatencyPresent is false (smooth CAMetalDisplayLink VSync default).
        #expect(CaptureSettings().lowLatencyPresent == false)

        // 2. Simulate 240Hz capture burst on 120Hz ProMotion over 1.0 second -> submissions <= 121 (never 150+!).
        var pacer120 = DirectPresentPacer()
        var submitted120 = 0
        var nextScheduledWake: Double? = nil
        var t = 100.0
        let end = 101.0
        while t < end {
            if let wake = nextScheduledWake, t >= wake {
                if case .submitNow = pacer120.evaluate(now: wake, displayRefreshHz: 120.0) {
                    pacer120.recordSubmitted(at: wake)
                    submitted120 += 1
                    nextScheduledWake = nil
                }
            }
            switch pacer120.evaluate(now: t, displayRefreshHz: 120.0) {
            case .submitNow:
                pacer120.recordSubmitted(at: t)
                submitted120 += 1
                nextScheduledWake = nil
            case .coalesceUntil(let wakeTime):
                if nextScheduledWake == nil {
                    nextScheduledWake = wakeTime
                }
            }
            t += 1.0 / 240.0
        }
        #expect(submitted120 >= 115 && submitted120 <= 122, "Expected ~120Hz paced submissions under 240Hz burst, got \(submitted120)")

        // 3. Simulate 150Hz capture burst on 60Hz display over 1.0 second -> submissions <= 62.
        var pacer60 = DirectPresentPacer()
        var submitted60 = 0
        nextScheduledWake = nil
        t = 200.0
        while t < 201.0 {
            if let wake = nextScheduledWake, t >= wake {
                if case .submitNow = pacer60.evaluate(now: wake, displayRefreshHz: 60.0) {
                    pacer60.recordSubmitted(at: wake)
                    submitted60 += 1
                    nextScheduledWake = nil
                }
            }
            switch pacer60.evaluate(now: t, displayRefreshHz: 60.0) {
            case .submitNow:
                pacer60.recordSubmitted(at: t)
                submitted60 += 1
                nextScheduledWake = nil
            case .coalesceUntil(let wakeTime):
                if nextScheduledWake == nil {
                    nextScheduledWake = wakeTime
                }
            }
            t += 1.0 / 150.0
        }
        #expect(submitted60 >= 58 && submitted60 <= 62, "Expected ~60Hz paced submissions under 150Hz burst, got \(submitted60)")

        // 4. Normal jittered 120Hz frame arriving at 0.90 * displayInterval submits immediately without coalescing delay.
        var jitterPacer = DirectPresentPacer()
        jitterPacer.recordSubmitted(at: 10.0)
        #expect(jitterPacer.evaluate(now: 10.0 + (1.0 / 120.0) * 0.90, displayRefreshHz: 120.0) == .submitNow)
        if case .coalesceUntil(let wake) = jitterPacer.evaluate(now: 10.0 + (1.0 / 120.0) * 0.50, displayRefreshHz: 120.0) {
            #expect(abs(wake - (10.0 + 1.0 / 120.0)) < 1e-6)
        } else {
            Issue.record("Expected 0.50x interval burst to coalesce until next display refresh slot")
        }
    }

    @Test("Target-fitting fixed/discrete upscalers bypass redundant 5K/6K overscaling on native high-res sources while preserving genuine 2x upscaling")
    func fixedUpscalerOverscalingGuard() throws {
        let modeBB = try #require(ScalingMode.builtInPresets.first { $0.id == ScalingMode.anime4kModeBBID })
        let modeCA = try #require(ScalingMode.builtInPresets.first { $0.id == ScalingMode.anime4kModeCAID })

        // 1. Native 3K Retina window (3024x1898 -> 3024x1896) with Anime4K Mode B+B must NEVER blow up to 6048x3796!
        let nativeRetinaBB = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 3024, height: 1898),
            targetPixelSize: PixelSize(width: 3024, height: 1896),
            effects: modeBB.effects
        )
        #expect(nativeRetinaBB.finalOutputPixelSize == PixelSize(width: 3021, height: 1896))
        #expect(!nativeRetinaBB.effectPasses.contains { $0.effectID == .anime4kUpscaleDenoise })
        #expect(nativeRetinaBB.effectPasses.filter { $0.effectID == .anime4kRestore }.count == 1)
        #expect(nativeRetinaBB.effectPasses.allSatisfy { $0.outputSize.width <= 3024 && $0.outputSize.height <= 1898 })

        // 2. Mode C+A on native 3K bypasses Upscale+Denoise but keeps its single Restore pass at 3K.
        let nativeRetinaCA = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 3024, height: 1898),
            targetPixelSize: PixelSize(width: 3024, height: 1898),
            effects: modeCA.effects
        )
        #expect(!nativeRetinaCA.effectPasses.contains { $0.effectID == .anime4kUpscaleDenoise })
        #expect(nativeRetinaCA.effectPasses.filter { $0.effectID == .anime4kRestore }.count == 1)
        #expect(nativeRetinaCA.finalOutputPixelSize == PixelSize(width: 3024, height: 1898))
        #expect(!nativeRetinaCA.needsAutoBicubicFallback)

        // 3. Single fixed-2x upscaler (CuNNy / FSRCNNX) or discrete Apple ML SR on 1440p -> 3K (1.18x <= 1.2x)
        //    bypasses 5K blowup and conforms cleanly via Auto Bicubic.
        for effectID in [EffectID.cunny, .fsrcnnx, .vtSuperResolution] {
            let nearNative = ScalingLayoutCalculator.calculate(
                sourcePixelSize: PixelSize(width: 2560, height: 1440),
                targetPixelSize: PixelSize(width: 3024, height: 1898),
                effects: [EffectInstance(effectID: effectID, scalingType: .fit)]
            )
            #expect(nearNative.effectPasses.count == 1)
            #expect(nearNative.effectPasses[0].isAutoInsertedFallback)
            #expect(nearNative.effectPasses[0].outputSize == PixelSize(width: 3024, height: 1701))
        }

        // 4. Genuine 2x upscaling (fullscreen pre-scaled 1512x949 -> 3024x1898) runs the FULL Mode B+B chain!
        let genuineVideoBB = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 1512, height: 949),
            targetPixelSize: PixelSize(width: 3024, height: 1898),
            effects: modeBB.effects
        )
        #expect(genuineVideoBB.effectPasses.count == 4)
        #expect(genuineVideoBB.effectPasses[0].effectID == .anime4kRestore)
        #expect(genuineVideoBB.effectPasses[0].outputSize == PixelSize(width: 1512, height: 949))
        #expect(genuineVideoBB.effectPasses[1].effectID == .anime4kUpscaleDenoise)
        #expect(genuineVideoBB.effectPasses[1].outputSize == PixelSize(width: 3024, height: 1898))
        #expect(genuineVideoBB.effectPasses[2].effectID == .anime4kRestore)
        #expect(genuineVideoBB.effectPasses[2].outputSize == PixelSize(width: 3024, height: 1898))
        #expect(genuineVideoBB.effectPasses[3].effectID == .anime4kClampHighlights)
        #expect(!genuineVideoBB.needsAutoBicubicFallback)

        // 5. Genuine 1080p -> 1440p (1.33x > 1.2x, 4K = 8.3M px <= 12M) still runs full 2x Anime4K upscaling!
        let hd1080To1440 = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 1920, height: 1080),
            targetPixelSize: PixelSize(width: 2560, height: 1440),
            effects: [EffectInstance(effectID: .anime4kUpscaleDenoise, scalingType: .fit)]
        )
        #expect(hd1080To1440.effectPasses.count == 2)
        #expect(hd1080To1440.effectPasses[0].effectID == .anime4kUpscaleDenoise)
        #expect(hd1080To1440.effectPasses[0].outputSize == PixelSize(width: 3840, height: 2160))
        #expect(hd1080To1440.effectPasses[1].isAutoInsertedFallback)
        #expect(hd1080To1440.effectPasses[1].outputSize == PixelSize(width: 2560, height: 1440))

        // 6. Exhaustive audit across ALL 21 built-in presets on native 3K (3024x1898 -> 3024x1896)
        //    and near-native 1440p -> 3K (2560x1440 -> 3024x1898): ZERO presets may ever blow up
        //    any intermediate pass above max(source, target) (no 5K/6K overscaling anywhere).
        let nearNativeCases: [(PixelSize, PixelSize)] = [
            (PixelSize(width: 3024, height: 1898), PixelSize(width: 3024, height: 1896)),
            (PixelSize(width: 3024, height: 1898), PixelSize(width: 3024, height: 1898)),
            (PixelSize(width: 2560, height: 1440), PixelSize(width: 3024, height: 1898)),
            (PixelSize(width: 3840, height: 2160), PixelSize(width: 3840, height: 2160))
        ]
        for preset in ScalingMode.builtInPresets {
            for (src, dst) in nearNativeCases {
                let maxAllowedW = max(src.width, dst.width)
                let maxAllowedH = max(src.height, dst.height)
                let layout = ScalingLayoutCalculator.calculate(
                    sourcePixelSize: src,
                    targetPixelSize: dst,
                    effects: preset.effects
                )
                for pass in layout.effectPasses {
                    #expect(
                        pass.outputSize.width <= maxAllowedW && pass.outputSize.height <= maxAllowedH,
                        "Preset '\(preset.name)' overscaled \(src.width)x\(src.height) -> \(dst.width)x\(dst.height) into \(pass.outputSize.width)x\(pass.outputSize.height) at pass \(pass.effectID.rawValue)"
                    )
                }
            }
        }
    }
}
