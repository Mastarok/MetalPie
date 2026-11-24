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
}
