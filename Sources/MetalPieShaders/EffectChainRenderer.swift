import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalFX
import MetalPieCore
import UniformTypeIdentifiers
import os

// MARK: - Supporting Public Types

/// Optional 1x Non-Retina pre-demagnification mode (MetalGoose Wine/CrossOver 4x pixel win).
public enum DemagnifyMode: String, Hashable, Codable, Sendable, CaseIterable {
    case none
    case nearest
    case bilinear
}

/// Optional in-pass VRR overlay resources composited inside the single TBDR present pass.
public struct PresentOverlayOptions: @unchecked Sendable {
    public var cursorTexture: (any MTLTexture)?
    /// Normalized `[0, 1]` Y-down rect of cursor sprite in destination canvas space.
    public var cursorRectNormalized: CGRect
    public var cursorNearest: Bool
    public var hudTexture: (any MTLTexture)?
    /// Normalized `[0, 1]` Y-down rect of HUD texture in destination canvas space.
    public var hudRectNormalized: CGRect
    public var exposure: Float
    public var applySRGBDecode: Bool
    public var applySRGBEncode: Bool

    public init(
        cursorTexture: (any MTLTexture)? = nil,
        cursorRectNormalized: CGRect = .zero,
        cursorNearest: Bool = false,
        hudTexture: (any MTLTexture)? = nil,
        hudRectNormalized: CGRect = .zero,
        exposure: Float = 1.0,
        applySRGBDecode: Bool = false,
        applySRGBEncode: Bool = false
    ) {
        self.cursorTexture = cursorTexture
        self.cursorRectNormalized = cursorRectNormalized
        self.cursorNearest = cursorNearest
        self.hudTexture = hudTexture
        self.hudRectNormalized = hudRectNormalized
        self.exposure = exposure
        self.applySRGBDecode = applySRGBDecode
        self.applySRGBEncode = applySRGBEncode
    }
}

/// Real Apple Silicon GPU benchmark metrics for a single built-in effect.
public struct ShaderBenchmarkResult: Identifiable, Hashable, Codable, Sendable {
    public var id: EffectID { effectID }
    public var effectID: EffectID
    public var effectName: String
    public var inputSize: PixelSize
    public var outputSize: PixelSize
    public var iterations: Int
    public var averageGPUMilliseconds: Double
    public var minGPUMilliseconds: Double
    public var maxGPUMilliseconds: Double
    public var estimatedFPS: Double
    public var succeeded: Bool
    public var note: String?

    public init(
        effectID: EffectID,
        effectName: String,
        inputSize: PixelSize,
        outputSize: PixelSize,
        iterations: Int,
        averageGPUMilliseconds: Double,
        minGPUMilliseconds: Double,
        maxGPUMilliseconds: Double,
        succeeded: Bool = true,
        note: String? = nil
    ) {
        self.effectID = effectID
        self.effectName = effectName
        self.inputSize = inputSize
        self.outputSize = outputSize
        self.iterations = iterations
        self.averageGPUMilliseconds = max(0, averageGPUMilliseconds)
        self.minGPUMilliseconds = max(0, minGPUMilliseconds)
        self.maxGPUMilliseconds = max(0, maxGPUMilliseconds)
        self.estimatedFPS = averageGPUMilliseconds > 1e-4 ? (1000.0 / averageGPUMilliseconds) : 0
        self.succeeded = succeeded
        self.note = note
    }
}

// MARK: - EffectChainRenderer

/// MetalPie's production multi-pass GPU shader & MetalFX/VideoToolbox effect graph engine.
///
/// Implements `EffectRendering` from `MetalPieCore`, plus:
/// - Optional 1x Non-Retina Demagnification (`DemagnifyMode`)
/// - Zero-CPU-readback GPU Duplicate Frame Detection (`DuplicateFrameMode`)
/// - Full 22-effect catalog + Auto-Bicubic fallback + single-pass TBDR Present (9-point alignment,
///   black letterbox, HDR/EDR, optional VRR cursor & HUD compositing)
/// - Live Metal Preview (`renderPreview`), GPU Shader Benchmark (`runBenchmark`),
///   and Cursor-Free PNG Screenshot Export (`captureLastOutputImage` / `captureLastOutputPNGData`).
public final class EffectChainRenderer: EffectRendering, @unchecked Sendable {
    public let device: any MTLDevice
    public let shaderManager: ShaderLibraryManager
    public let texturePool: TexturePool
    public let metalFX: MetalFXEffect
    public let videoToolboxML: VideoToolboxMLProcessor

    private let utilityQueue: any MTLCommandQueue
    private let duplicateFlagBuffer: any MTLBuffer
    private let dummyOverlayTexture: any MTLTexture

    // MARK: - Thread-Safe Mutable State

    private struct DuplicateDetectorState {
        var prevCroppedTexture: (any MTLTexture)?
        var cachedFinalOutputTexture: (any MTLTexture)?
        var cachedOutputSize: PixelSize = .zero
        var cachedSignature: String = ""
        // Magpie Dynamic cadence state machine
        var checkRemaining: Int = 16
        var nextSkipCount: Int = 1
        var skipRemaining: Int = 0
    }

    private struct RendererState {
        var demagnifyMode: DemagnifyMode = .none
        var presentOverlayOptions: PresentOverlayOptions?
        var enableCursorFreeScreenshotCache: Bool = true
        var duplicate = DuplicateDetectorState()
        var lastCursorFreeOutput: (any MTLTexture)?
        /// Smoothed real GPU milliseconds per pass identifier, updated on `commandBuffer.addCompletedHandler`.
        var passGPUEmaMs: [String: Double] = [:]
        var lastCompletedPassTimings: [PassTiming] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: RendererState())

    // MARK: - Initialization

    public init(
        device: any MTLDevice,
        shaderManager: ShaderLibraryManager? = nil,
        texturePool: TexturePool? = nil
    ) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw EngineError.metalDeviceUnavailable
        }
        queue.label = "com.metalpie.shaders.utilityQueue"
        self.utilityQueue = queue

        let resolvedManager = try shaderManager ?? ShaderLibraryManager(device: device)
        let resolvedPool = texturePool ?? TexturePool(device: device)
        self.shaderManager = resolvedManager
        self.texturePool = resolvedPool
        self.metalFX = MetalFXEffect(device: device)
        self.videoToolboxML = VideoToolboxMLProcessor(
            device: device,
            shaderManager: resolvedManager,
            texturePool: resolvedPool
        )

        guard let flagBuf = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            throw EngineError.metalDeviceUnavailable
        }
        flagBuf.label = "MetalPie_DuplicateFrameFlag"
        self.duplicateFlagBuffer = flagBuf

        // 1x1 transparent RGBA8 texture bound to unused cursor/HUD slots during present.
        let dummyDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dummyDesc.usage = .shaderRead
        dummyDesc.storageMode = .shared
        guard let dummy = device.makeTexture(descriptor: dummyDesc) else {
            throw EngineError.metalDeviceUnavailable
        }
        var zeroPixel: [UInt8] = [0, 0, 0, 0]
        dummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zeroPixel, bytesPerRow: 4)
        self.dummyOverlayTexture = dummy
    }

    public convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError.metalDeviceUnavailable
        }
        try self.init(device: device)
    }

    // MARK: - Public Configuration Properties

    /// Optional 1x Non-Retina pre-demagnification mode (for 2x magnified Wine/CrossOver windows).
    public var demagnifyMode: DemagnifyMode {
        get { state.withLockUnchecked { $0.demagnifyMode } }
        set { state.withLockUnchecked { $0.demagnifyMode = newValue } }
    }

    /// Optional in-pass VRR cursor & HUD compositing configuration applied during the Present pass.
    public var presentOverlayOptions: PresentOverlayOptions? {
        get { state.withLockUnchecked { $0.presentOverlayOptions } }
        set { state.withLockUnchecked { $0.presentOverlayOptions = newValue } }
    }

    /// When `true` (default), caches a GPU copy of the final upscaled texture before cursor/HUD
    /// compositing so `captureLastOutputImage()` exports clean cursor-free screenshots.
    public var enableCursorFreeScreenshotCache: Bool {
        get { state.withLockUnchecked { $0.enableCursorFreeScreenshotCache } }
        set { state.withLockUnchecked { $0.enableCursorFreeScreenshotCache = newValue } }
    }

    /// Most recent pass timings measured after actual GPU command buffer completion.
    public var lastCompletedPassTimings: [PassTiming] {
        state.withLockUnchecked { $0.lastCompletedPassTimings }
    }

    // MARK: - EffectRendering Conformance

    public var supportedEffects: [EffectID] {
        if VideoToolboxSuperResolution.isSupportedOnSystem {
            return EffectID.allCases
        }
        return EffectID.allCases.filter { $0 != .vtSuperResolution }
    }

    public func prewarm(scalingMode: ScalingMode) async throws {
        _ = try shaderManager.computePipeline(library: "Common", function: "cropBlit")
        _ = try shaderManager.computePipeline(library: "Common", function: "duplicateFrameCheck")
        _ = try shaderManager.computePipeline(library: "Common", function: "demagnifyNearest")
        _ = try shaderManager.computePipeline(library: "Common", function: "demagnifyBilinear")
        _ = try shaderManager.computePipeline(library: "Common", function: "presentCompute")
        _ = try shaderManager.renderPipeline(
            library: "Common",
            vertexFunction: "presentVertex",
            fragmentFunction: "presentFragment",
            colorPixelFormat: .bgra8Unorm
        )
        _ = try shaderManager.computePipeline(library: "Interpolation", function: "bicubic")

        for instance in scalingMode.effects where instance.enabled {
            try prewarmEffect(instance.effectID, parameters: instance.parameters)
        }

        try? shaderManager.saveBinaryArchive()
    }

    public func encode(scalingMode: ScalingMode, context: EffectRenderContext) throws -> EffectExecutionReport {
        try encodeInternal(scalingMode: scalingMode, context: context, allowLiveStateMutation: true)
    }

    private func encodeInternal(
        scalingMode: ScalingMode,
        context: EffectRenderContext,
        allowLiveStateMutation: Bool
    ) throws -> EffectExecutionReport {
        let cb = context.commandBuffer
        let layout = context.layout
        let workingFormat = resolveWorkingPixelFormat(sourceFormat: context.sourceTexture.pixelFormat, isHDR: context.isHDR)

        var frameLeases: [PooledTexture] = []
        defer {
            texturePool.recycleOnCompletion(frameLeases, of: cb)
        }

        var passRecords: [(id: String, name: String, colorHex: String, weight: Double)] = []

        // 0. GPU Duplicate Frame Detection (zero CPU readback, works with crop & demagnify too!)
        let activeDemag: DemagnifyMode = allowLiveStateMutation ? state.withLockUnchecked { $0.demagnifyMode } : .none
        let modeSignature = makeModeSignature(scalingMode: scalingMode, layout: layout, isHDR: context.isHDR, demagnify: activeDemag)
        if allowLiveStateMutation,
           context.duplicateFrameMode != .never,
           let cachedOutput = try checkDuplicateFrameOnGPU(
               currentSource: context.sourceTexture,
               queue: cb.commandQueue,
               mode: context.duplicateFrameMode,
               signature: modeSignature
           )
        {
            // Skip entire shader chain and write cached upscaled texture (1:1 for intermediate buffer or full TBDR present).
            try encodeOutputOrPresent(
                contentTexture: cachedOutput.texture,
                destinationTexture: context.destinationTexture,
                layout: layout,
                isHDR: context.isHDR,
                allowOverlays: true,
                commandBuffer: cb
            )
            let timing = PassTiming(
                id: "duplicate_skip",
                name: "Duplicate Skip + Present",
                gpuMilliseconds: cachedEmaMs(for: "duplicate_skip", fallback: 0.05),
                colorHex: "#64748B"
            )
            attachTimingCompletion(commandBuffer: cb, records: [(id: "duplicate_skip", name: "Duplicate Skip + Present", colorHex: "#64748B", weight: 1.0)])
            return EffectExecutionReport(
                passTimings: [timing],
                wasDuplicateFrameSkipped: true,
                finalOutputSize: cachedOutput.size
            )
        }

        // Record current source texture for next frame's GPU duplicate check.
        if allowLiveStateMutation, context.duplicateFrameMode != .never {
            updatePreviousSourceCache(from: context.sourceTexture, commandBuffer: cb)
        }

        // 1. Optional 1x Non-Retina Demagnification
        var currentTex: any MTLTexture = context.sourceTexture
        if activeDemag != .none, currentTex.width >= 64, currentTex.height >= 64 {
            let demagW = max(1, currentTex.width / 2)
            let demagH = max(1, currentTex.height / 2)
            let demagLease = try texturePool.acquire(
                width: demagW,
                height: demagH,
                pixelFormat: workingFormat,
                usage: [.shaderRead, .shaderWrite],
                storageMode: .private,
                label: "MetalPie_Demagnify"
            )
            frameLeases.append(demagLease)
            try encodeDemagnifyPass(
                source: currentTex,
                destination: demagLease.texture,
                mode: activeDemag,
                commandBuffer: cb
            )
            currentTex = demagLease.texture
            passRecords.append((
                id: "demagnify",
                name: activeDemag == .nearest ? "1x Demagnify (Nearest)" : "1x Demagnify (Bilinear)",
                colorHex: "#FFD60A",
                weight: Double(demagW * demagH) * 0.4
            ))
        }

        // 2. Optional Crop Pass (scales layout.croppedSourceRect when demagnify halved currentTex)
        let rawCropRect = layout.croppedSourceRect
        let effCropX: Int
        let effCropY: Int
        let effCropW: Int
        let effCropH: Int
        if rawCropRect.width > 0 && rawCropRect.height > 0 {
            let srcRefW = max(1, layout.sourcePixelSize.width > 0 ? layout.sourcePixelSize.width : context.sourceTexture.width)
            let srcRefH = max(1, layout.sourcePixelSize.height > 0 ? layout.sourcePixelSize.height : context.sourceTexture.height)
            if currentTex.width != srcRefW || currentTex.height != srcRefH {
                let scaleX = Double(currentTex.width) / Double(srcRefW)
                let scaleY = Double(currentTex.height) / Double(srcRefH)
                effCropX = max(0, min(currentTex.width - 1, Int((Double(rawCropRect.x) * scaleX).rounded())))
                effCropY = max(0, min(currentTex.height - 1, Int((Double(rawCropRect.y) * scaleY).rounded())))
                effCropW = max(1, min(currentTex.width - effCropX, Int((Double(rawCropRect.width) * scaleX).rounded())))
                effCropH = max(1, min(currentTex.height - effCropY, Int((Double(rawCropRect.height) * scaleY).rounded())))
            } else {
                effCropX = max(0, min(currentTex.width - 1, rawCropRect.x))
                effCropY = max(0, min(currentTex.height - 1, rawCropRect.y))
                effCropW = max(1, min(currentTex.width - effCropX, rawCropRect.width))
                effCropH = max(1, min(currentTex.height - effCropY, rawCropRect.height))
            }
        } else {
            effCropX = 0
            effCropY = 0
            effCropW = currentTex.width
            effCropH = currentTex.height
        }

        let needsCrop = rawCropRect.width > 0 && rawCropRect.height > 0 && (
            effCropX > 0 || effCropY > 0 ||
            effCropW != currentTex.width || effCropH != currentTex.height
        )
        if needsCrop {
            let croppedLease = try texturePool.acquire(
                width: effCropW,
                height: effCropH,
                pixelFormat: workingFormat,
                usage: [.shaderRead, .shaderWrite],
                storageMode: .private,
                label: "MetalPie_Crop"
            )
            frameLeases.append(croppedLease)
            try encodeCropPass(
                source: currentTex,
                destination: croppedLease.texture,
                origin: SIMD2<UInt32>(UInt32(effCropX), UInt32(effCropY)),
                size: SIMD2<UInt32>(UInt32(effCropW), UInt32(effCropH)),
                commandBuffer: cb
            )
            currentTex = croppedLease.texture
            passRecords.append((
                id: "crop",
                name: "Crop (\(effCropW)x\(effCropH))",
                colorHex: "#FFD60A",
                weight: Double(effCropW * effCropH) * 0.2
            ))
        }

        // Map EffectInstance by UUID (and ordered enabled fallback) for fast parameter lookup.
        let enabledEffects = scalingMode.effects.filter(\.enabled)
        var instanceLookup: [UUID: EffectInstance] = [:]
        instanceLookup.reserveCapacity(scalingMode.effects.count)
        for inst in scalingMode.effects {
            instanceLookup[inst.id] = inst
        }

        // 4. Execute Ordered Effect Chain (`layout.effectPasses`, including any auto-Bicubic fallback).
        let rwUsage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget]
        for (passIdx, passLayout) in layout.effectPasses.enumerated() {
            let outW = max(1, passLayout.outputSize.width)
            let outH = max(1, passLayout.outputSize.height)
            let targetLease = try texturePool.acquire(
                width: outW,
                height: outH,
                pixelFormat: workingFormat,
                usage: rwUsage,
                storageMode: .private,
                label: "MetalPie_Pass\(passIdx)_\(passLayout.effectID.rawValue)"
            )
            frameLeases.append(targetLease)

            let params: EffectParameters
            if passLayout.isAutoInsertedFallback {
                params = ["b": .float(0.0), "c": .float(0.5)]
            } else if let byID = instanceLookup[passLayout.effectInstanceID] {
                params = byID.parameters
            } else if passIdx < enabledEffects.count, enabledEffects[passIdx].effectID == passLayout.effectID {
                params = enabledEffects[passIdx].parameters
            } else {
                params = EffectCatalog.descriptor(for: passLayout.effectID).defaultParameters
            }

            try encodeSingleEffect(
                effectID: passLayout.effectID,
                parameters: params,
                source: currentTex,
                destination: targetLease.texture,
                isHDR: context.isHDR,
                frameIndex: context.frameIndex,
                commandBuffer: cb,
                frameLeases: &frameLeases
            )

            currentTex = targetLease.texture
            let desc = EffectCatalog.descriptor(for: passLayout.effectID)
            let passName = passLayout.isAutoInsertedFallback
                ? "Auto Bicubic (\(outW)x\(outH))"
                : "\(desc.nameEN) (\(outW)x\(outH))"
            let passID = "\(passIdx)_\(passLayout.effectID.rawValue)"
            let colorHex = passLayout.isAutoInsertedFallback ? "#8E8E93" : Self.colorHex(for: desc.category)
            passRecords.append((
                id: passID,
                name: passName,
                colorHex: colorHex,
                weight: Double(outW * outH) * Self.costWeight(for: passLayout.effectID)
            ))
        }

        let finalSize = PixelSize(width: currentTex.width, height: currentTex.height)

        // 5. Save Cursor-Free Output Snapshot (for live PNG screenshots & duplicate-frame skip reuse).
        // Skipped for preview/benchmark calls so live session caches are never clobbered.
        let shouldCacheSnapshot = allowLiveStateMutation && (
            state.withLockUnchecked { $0.enableCursorFreeScreenshotCache } || context.duplicateFrameMode != .never
        )
        if shouldCacheSnapshot {
            cacheFinalOutputTexture(
                from: currentTex,
                size: finalSize,
                signature: modeSignature,
                commandBuffer: cb
            )
        }

        // 6. Output Copy (1:1 when destination is an intermediate upscaled buffer) or Single-Pass TBDR Present.
        try encodeOutputOrPresent(
            contentTexture: currentTex,
            destinationTexture: context.destinationTexture,
            layout: layout,
            isHDR: context.isHDR,
            allowOverlays: allowLiveStateMutation,
            commandBuffer: cb
        )
        passRecords.append((
            id: "present",
            name: "Present (\(context.destinationTexture.width)x\(context.destinationTexture.height))",
            colorHex: "#48484A",
            weight: Double(context.destinationTexture.width * context.destinationTexture.height) * 0.25
        ))

        // Build PassTiming array using smoothed real GPU measurements (updated asynchronously on GPU completion).
        let timings: [PassTiming] = passRecords.map { rec in
            PassTiming(
                id: rec.id,
                name: rec.name,
                gpuMilliseconds: cachedEmaMs(for: rec.id, fallback: 0.0),
                colorHex: rec.colorHex
            )
        }
        if allowLiveStateMutation {
            attachTimingCompletion(commandBuffer: cb, records: passRecords)
        }

        return EffectExecutionReport(
            passTimings: timings,
            wasDuplicateFrameSkipped: false,
            finalOutputSize: finalSize
        )
    }

    public func reset() {
        metalFX.reset()
        videoToolboxML.reset()
        texturePool.reset()
        state.withLockUnchecked { s in
            s.duplicate = DuplicateDetectorState()
            s.lastCursorFreeOutput = nil
            s.passGPUEmaMs.removeAll()
            s.lastCompletedPassTimings.removeAll()
        }
    }

    // MARK: - Live Preview Rendering API (SwiftUI Effect Chain Editor)

    /// Renders a real GPU before/after preview of any `ScalingMode` & parameter tweaks from a `CGImage`.
    public func renderPreview(
        sourceImage: CGImage,
        scalingMode: ScalingMode,
        outputSize: PixelSize,
        crop: CropInsets = .zero,
        alignment: OutputAlignment = .center,
        isHDR: Bool = false
    ) throws -> CGImage {
        let srcTex = try uploadCGImageToTexture(sourceImage)
        let srcSize = PixelSize(width: srcTex.width, height: srcTex.height)
        let safeOut = PixelSize(width: max(1, outputSize.width), height: max(1, outputSize.height))

        let layout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: srcSize,
            targetPixelSize: safeOut,
            backingScaleFactor: 1.0,
            crop: crop,
            effects: scalingMode.effects,
            presentationMode: .fullscreen,
            alignment: alignment
        )

        let dstFormat: MTLPixelFormat = isHDR ? .rgba16Float : .bgra8Unorm
        let dstDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: dstFormat,
            width: safeOut.width,
            height: safeOut.height,
            mipmapped: false
        )
        dstDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        dstDesc.storageMode = .private
        guard let dstTex = device.makeTexture(descriptor: dstDesc),
              let cb = utilityQueue.makeCommandBuffer()
        else {
            throw EngineError.metalDeviceUnavailable
        }
        cb.label = "MetalPie_PreviewRender"

        let ctx = EffectRenderContext(
            device: device,
            commandBuffer: cb,
            sourceTexture: srcTex,
            destinationTexture: dstTex,
            layout: layout,
            isHDR: isHDR,
            frameIndex: 0,
            duplicateFrameMode: .never
        )
        _ = try encodeInternal(scalingMode: scalingMode, context: ctx, allowLiveStateMutation: false)
        cb.commit()
        cb.waitUntilCompleted()

        if let err = cb.error {
            throw EngineError.shaderCompilationFailed(effectID: .bilinear, detail: "Preview GPU execution failed: \(err.localizedDescription)")
        }

        return try exportTextureToCGImage(dstTex)
    }

    // MARK: - GPU Shader Benchmark API

    /// Runs real Apple Silicon GPU timing benchmarks across the specified `EffectID` catalog.
    public func runBenchmark(
        effects: [EffectID] = EffectID.allCases,
        inputSize: PixelSize = PixelSize(width: 1280, height: 720),
        outputSize: PixelSize = PixelSize(width: 2560, height: 1440),
        iterations: Int = 5
    ) throws -> [ShaderBenchmarkResult] {
        let safeIterations = max(1, iterations)
        let inW = max(64, inputSize.width)
        let inH = max(64, inputSize.height)
        let outW = max(64, outputSize.width)
        let outH = max(64, outputSize.height)

        // Generate a high-contrast synthetic test texture once on the GPU.
        let srcTex = try makeSyntheticTestTexture(width: inW, height: inH)
        let downscaleSrcTex = try makeSyntheticTestTexture(width: outW, height: outH)

        var results: [ShaderBenchmarkResult] = []
        results.reserveCapacity(effects.count)

        for effectID in effects {
            let desc = EffectCatalog.descriptor(for: effectID)
            let (benchInTex, targetOutSize, scalingType): (any MTLTexture, PixelSize, ScalingType)
            switch desc.scaleCapability {
            case .sameSize:
                benchInTex = srcTex
                targetOutSize = PixelSize(width: inW, height: inH)
                scalingType = .normal
            case .fixed(let factor):
                benchInTex = srcTex
                targetOutSize = PixelSize(
                    width: Int((Double(inW) * factor).rounded()),
                    height: Int((Double(inH) * factor).rounded())
                )
                scalingType = .normal
            case .downscaleOnly:
                benchInTex = downscaleSrcTex
                targetOutSize = PixelSize(width: inW, height: inH)
                scalingType = .fit
            case .discreteScales:
                // Use 640x360 -> 1280x720 (2x) if input exceeds ANE 2x max dim (960px),
                // or 1280x720 @ 1.5x -> 1920x1080 so real VideoToolbox ANE path is measured!
                let supported = VideoToolboxSuperResolution.supportedScaleFactors(width: inW, height: inH)
                if let scale = supported.first {
                    benchInTex = srcTex
                    targetOutSize = PixelSize(
                        width: Int((Double(inW) * Double(scale)).rounded()),
                        height: Int((Double(inH) * Double(scale)).rounded())
                    )
                    scalingType = .fit
                } else {
                    benchInTex = srcTex
                    targetOutSize = PixelSize(width: outW, height: outH)
                    scalingType = .fit
                }
            case .arbitrary:
                benchInTex = srcTex
                targetOutSize = PixelSize(width: outW, height: outH)
                scalingType = .fit
            }

            let dstDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: targetOutSize.width,
                height: targetOutSize.height,
                mipmapped: false
            )
            dstDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            dstDesc.storageMode = .private
            guard let dstTex = device.makeTexture(descriptor: dstDesc) else {
                continue
            }

            var params = desc.defaultParameters
            if effectID == .vtSuperResolution {
                let supported = VideoToolboxSuperResolution.supportedScaleFactors(width: benchInTex.width, height: benchInTex.height)
                if let firstScale = supported.first {
                    params["scaleFactor"] = .choice(String(format: "%.1f", firstScale))
                }
            }

            let mode = ScalingMode(
                name: "Bench_\(effectID.rawValue)",
                effects: [EffectInstance(effectID: effectID, scalingType: scalingType, parameters: params)]
            )
            let layout = ScalingLayoutCalculator.calculate(
                sourcePixelSize: PixelSize(width: benchInTex.width, height: benchInTex.height),
                targetPixelSize: targetOutSize,
                effects: mode.effects,
                presentationMode: .fullscreen
            )

            // Warmup pass (compiles pipeline & primes caches / ANE session).
            do {
                guard let warmCB = utilityQueue.makeCommandBuffer() else { continue }
                let warmCtx = EffectRenderContext(
                    device: device,
                    commandBuffer: warmCB,
                    sourceTexture: benchInTex,
                    destinationTexture: dstTex,
                    layout: layout,
                    isHDR: false,
                    frameIndex: 0,
                    duplicateFrameMode: .never
                )
                _ = try encodeInternal(scalingMode: mode, context: warmCtx, allowLiveStateMutation: false)
                warmCB.commit()
                warmCB.waitUntilCompleted()
            } catch {
                results.append(ShaderBenchmarkResult(
                    effectID: effectID,
                    effectName: desc.nameEN,
                    inputSize: PixelSize(width: benchInTex.width, height: benchInTex.height),
                    outputSize: targetOutSize,
                    iterations: 0,
                    averageGPUMilliseconds: 0,
                    minGPUMilliseconds: 0,
                    maxGPUMilliseconds: 0,
                    succeeded: false,
                    note: error.localizedDescription
                ))
                continue
            }

            var samples: [Double] = []
            samples.reserveCapacity(safeIterations)
            var benchError: String?

            for iter in 0..<safeIterations {
                guard let cb = utilityQueue.makeCommandBuffer() else { break }
                let ctx = EffectRenderContext(
                    device: device,
                    commandBuffer: cb,
                    sourceTexture: benchInTex,
                    destinationTexture: dstTex,
                    layout: layout,
                    isHDR: false,
                    frameIndex: UInt64(iter + 1),
                    duplicateFrameMode: .never
                )
                let t0 = CFAbsoluteTimeGetCurrent()
                do {
                    _ = try encodeInternal(scalingMode: mode, context: ctx, allowLiveStateMutation: false)
                    cb.commit()
                    cb.waitUntilCompleted()
                } catch {
                    benchError = error.localizedDescription
                    break
                }
                let wallMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
                // For Neural Engine passes (VideoToolbox ML), ANE execution time appears in wallMs while GPU time is near-zero.
                let measuredMs = (effectID == .vtSuperResolution) ? max(gpuMs, wallMs) : (gpuMs > 0 ? gpuMs : wallMs)
                samples.append(measuredMs)
            }

            if samples.isEmpty {
                results.append(ShaderBenchmarkResult(
                    effectID: effectID,
                    effectName: desc.nameEN,
                    inputSize: PixelSize(width: benchInTex.width, height: benchInTex.height),
                    outputSize: targetOutSize,
                    iterations: 0,
                    averageGPUMilliseconds: 0,
                    minGPUMilliseconds: 0,
                    maxGPUMilliseconds: 0,
                    succeeded: false,
                    note: benchError ?? "Benchmark produced no samples."
                ))
            } else {
                let avg = samples.reduce(0, +) / Double(samples.count)
                results.append(ShaderBenchmarkResult(
                    effectID: effectID,
                    effectName: desc.nameEN,
                    inputSize: PixelSize(width: benchInTex.width, height: benchInTex.height),
                    outputSize: targetOutSize,
                    iterations: samples.count,
                    averageGPUMilliseconds: avg,
                    minGPUMilliseconds: samples.min() ?? avg,
                    maxGPUMilliseconds: samples.max() ?? avg,
                    succeeded: true,
                    note: effectID == .vtSuperResolution ? "ANE + GPU convert wall time" : nil
                ))
            }
        }

        return results
    }

    // MARK: - Cursor-Free PNG Screenshot Export API

    /// Exports the most recently rendered upscaled frame (before cursor/HUD compositing) as a `CGImage`.
    public func captureLastOutputImage() throws -> CGImage {
        guard let tex = state.withLockUnchecked({ $0.lastCursorFreeOutput }) else {
            throw EngineError.screenshotExportFailed("No upscaled frame has been rendered yet.")
        }
        return try exportTextureToCGImage(tex)
    }

    /// Exports the most recently rendered upscaled frame (before cursor/HUD compositing) as PNG `Data`.
    public func captureLastOutputPNGData() throws -> Data {
        let image = try captureLastOutputImage()
        return try encodePNGData(from: image)
    }

    /// Reads back any Metal 2D texture (`.bgra8Unorm`, `.rgba8Unorm`, `.bgr10a2Unorm`, `.rgba16Float`)
    /// into an sRGB `CGImage`.
    public func exportTextureToCGImage(_ texture: any MTLTexture) throws -> CGImage {
        let w = texture.width
        let h = texture.height
        guard w > 0, h > 0 else {
            throw EngineError.screenshotExportFailed("Cannot export empty texture.")
        }

        // Convert to a `.shared` BGRA8 readback texture via GPU blit/compute so `.private` and HDR textures work cleanly.
        let readbackDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        readbackDesc.usage = [.shaderWrite, .shaderRead]
        readbackDesc.storageMode = .shared
        guard let readbackTex = device.makeTexture(descriptor: readbackDesc),
              let cb = utilityQueue.makeCommandBuffer()
        else {
            throw EngineError.screenshotExportFailed("Failed to allocate screenshot readback texture.")
        }
        cb.label = "MetalPie_ScreenshotReadback"

        if texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb {
            if let blit = cb.makeBlitCommandEncoder() {
                blit.copy(
                    from: texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: w, height: h, depth: 1),
                    to: readbackTex,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
            }
        } else {
            // Convert RGBA16F / BGR10A2 / RGBA8 -> BGRA8 via nearest compute kernel.
            let pipe = try shaderManager.computePipeline(library: "Interpolation", function: "nearest")
            if let enc = cb.makeComputeCommandEncoder() {
                enc.setComputePipelineState(pipe)
                enc.setTexture(texture, index: 0)
                enc.setTexture(readbackTex, index: 1)
                dispatch2D(encoder: enc, pipeline: pipe, width: w, height: h)
                enc.endEncoding()
            }
        }

        cb.commit()
        cb.waitUntilCompleted()

        let bytesPerRow = w * 4
        var rawBytes = Data(count: bytesPerRow * h)
        rawBytes.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress {
                readbackTex.getBytes(base, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            }
        }

        guard let provider = CGDataProvider(data: rawBytes as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = CGImage(
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            throw EngineError.screenshotExportFailed("Failed to construct CGImage from Metal texture bytes.")
        }

        return cgImage
    }

    /// Reads back any Metal 2D texture directly into PNG `Data`.
    public func exportTextureToPNGData(_ texture: any MTLTexture) throws -> Data {
        let image = try exportTextureToCGImage(texture)
        return try encodePNGData(from: image)
    }

    // MARK: - Standalone Demagnification Helper

    /// Encodes 1x Non-Retina GPU demagnification (nearest or exact 4-tap bilinear) from `source` to `destination`.
    public func encodeDemagnifyPass(
        source: any MTLTexture,
        destination: any MTLTexture,
        mode: DemagnifyMode,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard mode != .none else { return }
        let fn = (mode == .nearest) ? "demagnifyNearest" : "demagnifyBilinear"
        let pipe = try shaderManager.computePipeline(library: "Common", function: fn)
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "MetalPie_\(fn)"
            enc.setComputePipelineState(pipe)
            enc.setTexture(source, index: 0)
            enc.setTexture(destination, index: 1)
            dispatch2D(encoder: enc, pipeline: pipe, width: destination.width, height: destination.height)
            enc.endEncoding()
        }
    }

    // MARK: - Private Effect Dispatch (All 30 Built-In EffectIDs)

    private func encodeSingleEffect(
        effectID: EffectID,
        parameters: EffectParameters,
        source: any MTLTexture,
        destination: any MTLTexture,
        isHDR: Bool,
        frameIndex: UInt64,
        commandBuffer: any MTLCommandBuffer,
        frameLeases: inout [PooledTexture]
    ) throws {
        let inW = source.width
        let inH = source.height
        let outW = destination.width
        let outH = destination.height
        let rwUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]

        switch effectID {
        case .metalFXSpatial:
            let colorMode = MetalFXEffect.resolveColorProcessingMode(
                parameters: parameters,
                isHDR: isHDR,
                pixelFormat: destination.pixelFormat
            )
            let ranMetalFX = try metalFX.encode(
                commandBuffer: commandBuffer,
                source: source,
                destination: destination,
                colorProcessingMode: colorMode,
                texturePool: texturePool
            )
            if !ranMetalFX {
                // Graceful fallback (e.g. downscale or >3x scale ratio): Bicubic Catmull-Rom
                try encodeBicubic(source: source, destination: destination, b: 0.0, c: 0.5, commandBuffer: commandBuffer)
            }

        case .vtSuperResolution:
            let scaleStr = parameters.choice("scaleFactor", default: "2.0")
            let requestedScale = Float(scaleStr) ?? 2.0
            let ranVT = try videoToolboxML.superResolution.encode(
                commandBuffer: commandBuffer,
                source: source,
                destination: destination,
                requestedScaleFactor: requestedScale
            )
            if !ranVT {
                // Seamless hardware fallback: MetalFX Spatial -> Bicubic Catmull-Rom
                let colorMode: MTLFXSpatialScalerColorProcessingMode = isHDR ? .hdr : .perceptual
                let ranFX = try metalFX.encode(
                    commandBuffer: commandBuffer,
                    source: source,
                    destination: destination,
                    colorProcessingMode: colorMode,
                    texturePool: texturePool
                )
                if !ranFX {
                    try encodeBicubic(source: source, destination: destination, b: 0.0, c: 0.5, commandBuffer: commandBuffer)
                }
            }

        case .fsr1EASU:
            let pipe = try shaderManager.computePipeline(library: "FSR1", function: "fsr1_easu", effectHint: .fsr1EASU)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "FSR1_EASU"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .fsr1RCAS:
            struct RCASUniforms {
                var sharpness: Float
                var isHDR: UInt32
                var denoise: UInt32
                var _pad1: UInt32 = 0
            }
            var u = RCASUniforms(
                sharpness: parameters.float32("sharpness", default: 0.87),
                isHDR: isHDR ? 1 : 0,
                denoise: parameters.bool("denoise", default: true) ? 1 : 0
            )
            let pipe = try shaderManager.computePipeline(library: "FSR1", function: "fsr1_rcas", effectHint: .fsr1RCAS)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "FSR1_RCAS"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&u, length: MemoryLayout<RCASUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .sgsr:
            struct SGSRUniforms {
                var edgeSharpness: Float
                var edgeThreshold: Float
                var _pad0: UInt32 = 0
                var _pad1: UInt32 = 0
            }
            var u = SGSRUniforms(
                edgeSharpness: parameters.float32("edgeSharpness", default: 2.0),
                edgeThreshold: parameters.float32("edgeThreshold", default: 8.0)
            )
            let pipe = try shaderManager.computePipeline(library: "SGSR", function: "sgsr_upscale", effectHint: .sgsr)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "SGSR_Upscale"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&u, length: MemoryLayout<SGSRUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .anime4kRestore:
            let variant = parameters.choice("variant", default: "M")
            let strength = parameters.float32("strength", default: 1.0)
            let clampHighlights = parameters.bool("clampHighlights", default: true)
            try encodeAnime4KRestore(
                variant: variant,
                strength: strength,
                clampHighlights: clampHighlights,
                source: source,
                destination: destination,
                commandBuffer: commandBuffer,
                frameLeases: &frameLeases
            )

        case .anime4kUpscale:
            let variant = parameters.choice("variant", default: "L")
            let strength = parameters.float32("strength", default: 1.0)
            let clampHighlights = parameters.bool("clampHighlights", default: true)
            try encodeAnime4KUpscale(
                variant: variant,
                strength: strength,
                clampHighlights: clampHighlights,
                source: source,
                destination: destination,
                commandBuffer: commandBuffer,
                frameLeases: &frameLeases
            )

        case .anime4kUpscaleDenoise:
            let variant = parameters.choice("variant", default: "L")
            let denoiseStrength = parameters.float32("denoiseStrength", default: 1.0)
            let lineSharpness = parameters.float32("lineSharpness", default: 1.0)
            let clampHighlights = parameters.bool("clampHighlights", default: true)
            let legacyThinning = parameters.float32("lineThinning", default: 0.0)
            var cnnInput: any MTLTexture = source

            // Smooth bilateral mode pre-denoise scaled by denoiseStrength (0 = off, 1 = subtle, 2 = strong)
            if denoiseStrength > 0.01 {
                struct Anime4KDenoiseUniforms {
                    var denoiseStrength: Float
                    var _pad0: UInt32 = 0
                    var _pad1: UInt32 = 0
                    var _pad2: UInt32 = 0
                }
                let effectiveBilateral = min(max(denoiseStrength * 0.35, 0.0), 1.0)
                var du = Anime4KDenoiseUniforms(denoiseStrength: effectiveBilateral)
                let pDenoise = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_bilateral_mode", effectHint: .anime4kUpscaleDenoise)
                let denoised = try texturePool.acquire(width: inW, height: inH, pixelFormat: source.pixelFormat, usage: rwUsage, storageMode: .private)
                frameLeases.append(denoised)
                if let enc = commandBuffer.makeComputeCommandEncoder() {
                    enc.label = "Anime4K_BilateralMode"
                    enc.setComputePipelineState(pDenoise)
                    enc.setTexture(cnnInput, index: 0)
                    enc.setTexture(denoised.texture, index: 1)
                    enc.setBytes(&du, length: MemoryLayout<Anime4KDenoiseUniforms>.stride, index: 0)
                    dispatch2D(encoder: enc, pipeline: pDenoise, width: inW, height: inH)
                    enc.endEncoding()
                }
                cnnInput = denoised.texture
            }

            // Backwards-compatible support for legacy saved `lineThinning` parameter if present
            if legacyThinning > 0.001 {
                struct Anime4KThinUniforms {
                    var strength: Float
                    var iterations: UInt32
                    var _pad0: UInt32 = 0
                    var _pad1: UInt32 = 0
                }
                var tu = Anime4KThinUniforms(strength: legacyThinning, iterations: 1)
                let pSobel = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_sobel", effectHint: .anime4kUpscaleDenoise)
                let pWarp = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_warp", effectHint: .anime4kUpscaleDenoise)
                let gradTex = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
                let thinned = try texturePool.acquire(width: inW, height: inH, pixelFormat: source.pixelFormat, usage: rwUsage, storageMode: .private)
                frameLeases.append(contentsOf: [gradTex, thinned])
                if let enc = commandBuffer.makeComputeCommandEncoder() {
                    enc.label = "Anime4K_LineThinningLegacy"
                    enc.setComputePipelineState(pSobel)
                    enc.setTexture(cnnInput, index: 0)
                    enc.setTexture(gradTex.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: pSobel, width: inW, height: inH)

                    enc.setComputePipelineState(pWarp)
                    enc.setTexture(cnnInput, index: 0)
                    enc.setTexture(gradTex.texture, index: 1)
                    enc.setTexture(thinned.texture, index: 2)
                    enc.setBytes(&tu, length: MemoryLayout<Anime4KThinUniforms>.stride, index: 0)
                    dispatch2D(encoder: enc, pipeline: pWarp, width: inW, height: inH)
                    enc.endEncoding()
                }
                cnnInput = thinned.texture
            }

            try encodeAnime4KUpscaleDenoise(
                variant: variant,
                strength: lineSharpness,
                clampHighlights: clampHighlights,
                source: cnnInput,
                destination: destination,
                commandBuffer: commandBuffer,
                frameLeases: &frameLeases
            )

        case .anime4kThin:
            struct Anime4KThinUniforms {
                var strength: Float
                var iterations: UInt32
                var _pad0: UInt32 = 0
                var _pad1: UInt32 = 0
            }
            let quality = parameters.choice("quality", default: "hq")
            var tu = Anime4KThinUniforms(
                strength: parameters.float32("strength", default: 0.6),
                iterations: UInt32(max(1, min(3, parameters.int("iterations", default: 1))))
            )
            let pSobel = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_sobel", effectHint: .anime4kThin)
            let gradA = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(gradA)

            if quality == "fast" {
                let pWarp = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_warp", effectHint: .anime4kThin)
                if let enc = commandBuffer.makeComputeCommandEncoder() {
                    enc.label = "Anime4K_Thin_Fast"
                    enc.setComputePipelineState(pSobel)
                    enc.setTexture(source, index: 0)
                    enc.setTexture(gradA.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: pSobel, width: inW, height: inH)

                    enc.setComputePipelineState(pWarp)
                    enc.setTexture(source, index: 0)
                    enc.setTexture(gradA.texture, index: 1)
                    enc.setTexture(destination, index: 2)
                    enc.setBytes(&tu, length: MemoryLayout<Anime4KThinUniforms>.stride, index: 0)
                    dispatch2D(encoder: enc, pipeline: pWarp, width: outW, height: outH)
                    enc.endEncoding()
                }
            } else {
                let pGX = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_gauss_x", effectHint: .anime4kThin)
                let pGY = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_gauss_y", effectHint: .anime4kThin)
                let pKernel = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_kernel", effectHint: .anime4kThin)
                let pHQWarp = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_hq_warp", effectHint: .anime4kThin)
                let gradB = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
                frameLeases.append(gradB)
                if let enc = commandBuffer.makeComputeCommandEncoder() {
                    enc.label = "Anime4K_Thin_HQ"
                    enc.setComputePipelineState(pSobel)
                    enc.setTexture(source, index: 0)
                    enc.setTexture(gradA.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: pSobel, width: inW, height: inH)

                    enc.setComputePipelineState(pGX)
                    enc.setTexture(gradA.texture, index: 0)
                    enc.setTexture(gradB.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: pGX, width: inW, height: inH)

                    enc.setComputePipelineState(pGY)
                    enc.setTexture(gradB.texture, index: 0)
                    enc.setTexture(gradA.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: pGY, width: inW, height: inH)

                    enc.setComputePipelineState(pKernel)
                    enc.setTexture(gradA.texture, index: 0)
                    enc.setTexture(gradB.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: pKernel, width: inW, height: inH)

                    enc.setComputePipelineState(pHQWarp)
                    enc.setTexture(source, index: 0)
                    enc.setTexture(gradB.texture, index: 1)
                    enc.setTexture(destination, index: 2)
                    enc.setBytes(&tu, length: MemoryLayout<Anime4KThinUniforms>.stride, index: 0)
                    dispatch2D(encoder: enc, pipeline: pHQWarp, width: outW, height: outH)
                    enc.endEncoding()
                }
            }

        case .anime4kDarken:
            struct Anime4KDarkenUniforms {
                var strength: Float
                var _pad0: UInt32 = 0
                var _pad1: UInt32 = 0
                var _pad2: UInt32 = 0
            }
            let quality = parameters.choice("quality", default: "hq")
            var du = Anime4KDarkenUniforms(strength: parameters.float32("strength", default: 0.5))
            if quality == "fast" {
                let pFast = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_darken_fast", effectHint: .anime4kDarken)
                if let enc = commandBuffer.makeComputeCommandEncoder() {
                    enc.label = "Anime4K_Darken_Fast"
                    enc.setComputePipelineState(pFast)
                    enc.setTexture(source, index: 0)
                    enc.setTexture(destination, index: 1)
                    enc.setBytes(&du, length: MemoryLayout<Anime4KDarkenUniforms>.stride, index: 0)
                    dispatch2D(encoder: enc, pipeline: pFast, width: outW, height: outH)
                    enc.endEncoding()
                }
            } else {
                let pLuma = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_darken_luma", effectHint: .anime4kDarken)
                let pDiffX = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_darken_diff_x", effectHint: .anime4kDarken)
                let pDiffY = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_darken_diff_y", effectHint: .anime4kDarken)
                let pApply = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_darken_apply", effectHint: .anime4kDarken)
                let tLuma = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
                let tBlurX = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
                let tDiff = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
                frameLeases.append(contentsOf: [tLuma, tBlurX, tDiff])
                if let enc = commandBuffer.makeComputeCommandEncoder() {
                    enc.label = "Anime4K_Darken_HQ"
                    enc.setComputePipelineState(pLuma)
                    enc.setTexture(source, index: 0)
                    enc.setTexture(tLuma.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: pLuma, width: inW, height: inH)

                    enc.setComputePipelineState(pDiffX)
                    enc.setTexture(tLuma.texture, index: 0)
                    enc.setTexture(tBlurX.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: pDiffX, width: inW, height: inH)

                    enc.setComputePipelineState(pDiffY)
                    enc.setTexture(tBlurX.texture, index: 0)
                    enc.setTexture(tLuma.texture, index: 1)
                    enc.setTexture(tDiff.texture, index: 2)
                    dispatch2D(encoder: enc, pipeline: pDiffY, width: inW, height: inH)

                    enc.setComputePipelineState(pApply)
                    enc.setTexture(source, index: 0)
                    enc.setTexture(tDiff.texture, index: 1)
                    enc.setTexture(destination, index: 2)
                    enc.setBytes(&du, length: MemoryLayout<Anime4KDarkenUniforms>.stride, index: 0)
                    dispatch2D(encoder: enc, pipeline: pApply, width: outW, height: outH)
                    enc.endEncoding()
                }
            }

        case .anime4kDenoiseBilateral:
            struct Anime4KBilateralUniforms {
                var intensitySigma: Float
                var spatialSigma: Float
                var mode: UInt32
                var _pad0: UInt32 = 0
            }
            let modeStr = parameters.choice("mode", default: "mode")
            let modeID: UInt32 = (modeStr == "mean") ? 1 : ((modeStr == "median") ? 2 : 0)
            var bu = Anime4KBilateralUniforms(
                intensitySigma: parameters.float32("intensitySigma", default: 0.15),
                spatialSigma: parameters.float32("spatialSigma", default: 1.0),
                mode: modeID
            )
            let pipe = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_bilateral_full", effectHint: .anime4kDenoiseBilateral)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Anime4K_DenoiseBilateral"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&bu, length: MemoryLayout<Anime4KBilateralUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .anime4kClampHighlights:
            struct Anime4KClampUniforms {
                var radius: UInt32
                var strength: Float
                var _pad0: UInt32 = 0
                var _pad1: UInt32 = 0
            }
            var cu = Anime4KClampUniforms(
                radius: UInt32(max(1, min(2, parameters.int("radius", default: 1)))),
                strength: parameters.float32("strength", default: 1.0)
            )
            let pipe = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_clamp_highlights", effectHint: .anime4kClampHighlights)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Anime4K_ClampHighlights"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&cu, length: MemoryLayout<Anime4KClampUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .cunny:
            let variant = parameters.choice("variant", default: "balanced")
            let sharpness = parameters.float32("sharpness", default: 1.0)
            try encodeCuNNy(
                variant: variant,
                sharpness: sharpness,
                source: source,
                destination: destination,
                commandBuffer: commandBuffer,
                frameLeases: &frameLeases
            )

        case .fxaa:
            struct FXAAUniforms {
                var qualityPreset: UInt32
                var edgeThreshold: Float
                var subpixelQuality: Float
                var _pad0: UInt32 = 0
            }
            let presetStr = parameters.choice("qualityPreset", default: "high")
            let presetID: UInt32
            switch presetStr {
            case "low": presetID = 0
            case "medium": presetID = 1
            case "ultra": presetID = 3
            default: presetID = 2
            }
            var fu = FXAAUniforms(
                qualityPreset: presetID,
                edgeThreshold: parameters.float32("edgeThreshold", default: 0.125),
                subpixelQuality: parameters.float32("subpixelQuality", default: 0.75)
            )
            let pipe = try shaderManager.computePipeline(library: "FXAA", function: "fxaa", effectHint: .fxaa)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "FXAA_311"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&fu, length: MemoryLayout<FXAAUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .jinc:
            struct JincUniforms {
                var windowSinc: Float
                var sinc: Float
                var antiRinging: Float
                var _pad0: UInt32 = 0
            }
            var ju = JincUniforms(
                windowSinc: parameters.float32("windowSinc", default: 0.5),
                sinc: parameters.float32("sinc", default: 0.825),
                antiRinging: parameters.float32("antiRinging", default: 0.5)
            )
            let pipe = try shaderManager.computePipeline(library: "Interpolation", function: "jinc", effectHint: .jinc)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Jinc_EWA"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&ju, length: MemoryLayout<JincUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .fsrcnnx:
            struct FSRCNNXOutputUniforms {
                var sharpness: Float
                var antiRinging: Float
                var enhancedDetail: UInt32
                var _pad0: UInt32 = 0
            }
            let variant = parameters.choice("variant", default: "standard")
            let isEnhanced = (variant == "enhancedDetail")
            let prefix = (variant == "lineArt" || isEnhanced) ? "fsrcnnx_lineart" : "fsrcnnx_std"
            var outUniforms = FSRCNNXOutputUniforms(
                sharpness: parameters.float32("sharpness", default: 1.0),
                antiRinging: parameters.float32("antiRinging", default: 0.35),
                enhancedDetail: isEnhanced ? 1 : 0
            )

            let p1 = try shaderManager.computePipeline(library: "FSRCNNX", function: "\(prefix)_pass1", effectHint: .fsrcnnx)
            let p2 = try shaderManager.computePipeline(library: "FSRCNNX", function: "\(prefix)_pass2", effectHint: .fsrcnnx)
            let p3 = try shaderManager.computePipeline(library: "FSRCNNX", function: "\(prefix)_pass3", effectHint: .fsrcnnx)
            let p4 = try shaderManager.computePipeline(library: "FSRCNNX", function: "\(prefix)_pass4", effectHint: .fsrcnnx)
            let p5 = try shaderManager.computePipeline(library: "FSRCNNX", function: "\(prefix)_pass5", effectHint: .fsrcnnx)
            let p6 = try shaderManager.computePipeline(library: "FSRCNNX", function: "\(prefix)_pass6", effectHint: .fsrcnnx)

            let f1 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let f2 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t1 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t2 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t3 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t4 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(contentsOf: [f1, f2, t1, t2, t3, t4])

            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "FSRCNNX_2x"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(f1.texture, index: 1)
                enc.setTexture(f2.texture, index: 2)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(f1.texture, index: 0)
                enc.setTexture(f2.texture, index: 1)
                enc.setTexture(t1.texture, index: 2)
                enc.setTexture(t2.texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                enc.setTexture(t3.texture, index: 2)
                enc.setTexture(t4.texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(t3.texture, index: 0)
                enc.setTexture(t4.texture, index: 1)
                enc.setTexture(t1.texture, index: 2)
                enc.setTexture(t2.texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)

                enc.setComputePipelineState(p5)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                enc.setTexture(f1.texture, index: 2)
                enc.setTexture(f2.texture, index: 3)
                enc.setTexture(t3.texture, index: 4)
                enc.setTexture(t4.texture, index: 5)
                dispatch2D(encoder: enc, pipeline: p5, width: inW, height: inH)

                enc.setComputePipelineState(p6)
                enc.setTexture(t3.texture, index: 0)
                enc.setTexture(t4.texture, index: 1)
                enc.setTexture(source, index: 2)
                enc.setTexture(destination, index: 3)
                enc.setBytes(&outUniforms, length: MemoryLayout<FSRCNNXOutputUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p6, width: inW, height: inH)
                enc.endEncoding()
            }

        case .xbrzFreescale:
            struct XBRZUniforms {
                var equalColorTolerance: Float
                var edgeThreshold: Float
                var dominantDirectionThreshold: Float
                var _pad0: UInt32 = 0
            }
            var u = XBRZUniforms(
                equalColorTolerance: parameters.float32("equalColorTolerance", default: 30.0),
                edgeThreshold: parameters.float32("edgeThreshold", default: 2.2),
                dominantDirectionThreshold: parameters.float32("dominantDirectionThreshold", default: 3.6)
            )
            let p1 = try shaderManager.computePipeline(library: "PixelArt", function: "xbrz_pass1", effectHint: .xbrzFreescale)
            let p2 = try shaderManager.computePipeline(library: "PixelArt", function: "xbrz_pass2", effectHint: .xbrzFreescale)
            let blendTex = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba8Unorm, usage: rwUsage, storageMode: .private)
            frameLeases.append(blendTex)

            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "xBRZ_Freescale"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(blendTex.texture, index: 1)
                enc.setBytes(&u, length: MemoryLayout<XBRZUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(source, index: 0)
                enc.setTexture(blendTex.texture, index: 1)
                enc.setTexture(destination, index: 2)
                dispatch2D(encoder: enc, pipeline: p2, width: outW, height: outH)
                enc.endEncoding()
            }

        case .crtGeom:
            struct CRTGeomUniforms {
                var curvature: UInt32
                var crtGamma: Float
                var monitorGamma: Float
                var scanlineWeight: Float
                var dotMask: Float
                var cornerSize: Float
                var vignette: Float
                var bloom: Float
                var curvatureRadius: Float
                var maskType: UInt32
                var brightness: Float
                var _pad0: UInt32 = 0
            }
            let maskStr = parameters.choice("maskType", default: "apertureGrille")
            let maskID: UInt32
            switch maskStr {
            case "shadowMask": maskID = 1
            case "slotMask": maskID = 2
            case "off": maskID = 3
            default: maskID = 0
            }
            let halationVal = Float(parameters["halation"]?.floatValue ?? parameters["bloom"]?.floatValue ?? 0.15)
            var u = CRTGeomUniforms(
                curvature: parameters.bool("curvature", default: false) ? 1 : 0,
                crtGamma: parameters.float32("crtGamma", default: 2.4),
                monitorGamma: parameters.float32("monitorGamma", default: 2.2),
                scanlineWeight: parameters.float32("scanlineWeight", default: 0.3),
                dotMask: parameters.float32("dotMask", default: 0.3),
                cornerSize: parameters.float32("cornerSize", default: 0.01),
                vignette: parameters.float32("vignette", default: 0.15),
                bloom: halationVal,
                curvatureRadius: parameters.float32("curvatureRadius", default: 2.0),
                maskType: maskID,
                brightness: parameters.float32("brightness", default: 1.05)
            )
            let pipe = try shaderManager.computePipeline(library: "PixelArt", function: "crt_geom", effectHint: .crtGeom)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "CRT_Geom"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&u, length: MemoryLayout<CRTGeomUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .crtLottes:
            struct CRTLottesUniforms {
                var hardScan: Float
                var hardPix: Float
                var warpX: Float
                var warpY: Float
                var maskDark: Float
                var maskLight: Float
                var shadowMask: UInt32
                var brightBoost: Float
            }
            let maskChoice = parameters.choice("shadowMask", default: "apertureGrille")
            let maskID: UInt32
            switch maskChoice {
            case "none": maskID = 0
            case "compressedTV": maskID = 1
            case "apertureGrille": maskID = 2
            case "stretchedVGA": maskID = 3
            case "vga": maskID = 4
            default: maskID = 2
            }
            var u = CRTLottesUniforms(
                hardScan: parameters.float32("hardScan", default: -8.0),
                hardPix: parameters.float32("hardPix", default: -3.0),
                warpX: parameters.float32("warpX", default: 0.0),
                warpY: parameters.float32("warpY", default: 0.0),
                maskDark: parameters.float32("maskDark", default: 0.5),
                maskLight: parameters.float32("maskLight", default: 1.5),
                shadowMask: maskID,
                brightBoost: parameters.float32("brightBoost", default: 1.0)
            )
            let pipe = try shaderManager.computePipeline(library: "PixelArt", function: "crt_lottes", effectHint: .crtLottes)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "CRT_Lottes"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&u, length: MemoryLayout<CRTLottesUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .lanczos6:
            struct LanczosUniforms {
                var arStrength: Float
                var sharpness: Float
                var _pad0: UInt32 = 0
                var _pad1: UInt32 = 0
            }
            let ar = Float(parameters["antiRinging"]?.floatValue ?? parameters["arStrength"]?.floatValue ?? 0.5)
            var u = LanczosUniforms(
                arStrength: ar,
                sharpness: parameters.float32("sharpness", default: 1.0)
            )
            let pH = try shaderManager.computePipeline(library: "Interpolation", function: "lanczos6_h", effectHint: .lanczos6)
            let pV = try shaderManager.computePipeline(library: "Interpolation", function: "lanczos6_v", effectHint: .lanczos6)
            let horiz = try texturePool.acquire(width: outW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(horiz)

            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Lanczos6_Separable"
                enc.setComputePipelineState(pH)
                enc.setTexture(source, index: 0)
                enc.setTexture(horiz.texture, index: 1)
                enc.setBytes(&u, length: MemoryLayout<LanczosUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pH, width: outW, height: inH)

                enc.setComputePipelineState(pV)
                enc.setTexture(horiz.texture, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&u, length: MemoryLayout<LanczosUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pV, width: outW, height: outH)
                enc.endEncoding()
            }

        case .bicubic:
            let b = parameters.float32("b", default: 0.0)
            let c = parameters.float32("c", default: 0.5)
            try encodeBicubic(source: source, destination: destination, b: b, c: c, commandBuffer: commandBuffer)

        case .sharpBilinear:
            struct SharpBilinearUniforms {
                var sharpness: Float
                var _pad0: UInt32 = 0
                var _pad1: UInt32 = 0
                var _pad2: UInt32 = 0
            }
            var u = SharpBilinearUniforms(sharpness: parameters.float32("sharpness", default: 1.0))
            let pipe = try shaderManager.computePipeline(library: "Interpolation", function: "sharp_bilinear", effectHint: .sharpBilinear)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "SharpBilinear"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&u, length: MemoryLayout<SharpBilinearUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .pixellate:
            let pipe = try shaderManager.computePipeline(library: "Interpolation", function: "pixellate", effectHint: .pixellate)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Pixellate"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .nearest:
            let pipe = try shaderManager.computePipeline(library: "Interpolation", function: "nearest", effectHint: .nearest)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Nearest"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .bilinear:
            let pipe = try shaderManager.computePipeline(library: "Interpolation", function: "bilinear", effectHint: .bilinear)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Bilinear"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .cas:
            struct CASUniforms {
                var sharpness: Float
                var isHDR: UInt32
                var _pad0: UInt32 = 0
                var _pad1: UInt32 = 0
            }
            var u = CASUniforms(
                sharpness: parameters.float32("sharpness", default: 0.4),
                isHDR: isHDR ? 1 : 0
            )
            let pipe = try shaderManager.computePipeline(library: "CAS", function: "cas_sharpen", effectHint: .cas)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "CAS_Sharpen"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&u, length: MemoryLayout<CASUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .adaptiveSharpen:
            struct AdaptiveSharpenUniforms {
                var curveHeight: Float
                var _pad0: UInt32 = 0
                var _pad1: UInt32 = 0
                var _pad2: UInt32 = 0
            }
            var u = AdaptiveSharpenUniforms(curveHeight: parameters.float32("curveHeight", default: 0.3))
            let p1 = try shaderManager.computePipeline(library: "CAS", function: "adaptive_sharpen_pass1", effectHint: .adaptiveSharpen)
            let p2 = try shaderManager.computePipeline(library: "CAS", function: "adaptive_sharpen_pass2", effectHint: .adaptiveSharpen)
            let edgeTex = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(edgeTex)

            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "AdaptiveSharpen_2Pass"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(edgeTex.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(source, index: 0)
                enc.setTexture(edgeTex.texture, index: 1)
                enc.setTexture(destination, index: 2)
                enc.setBytes(&u, length: MemoryLayout<AdaptiveSharpenUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p2, width: outW, height: outH)
                enc.endEncoding()
            }

        case .ssimDownscaler:
            if outW >= inW && outH >= inH {
                // Passthrough copy when not downscaling
                let pipe = try shaderManager.computePipeline(library: "Interpolation", function: "nearest", effectHint: .ssimDownscaler)
                if let enc = commandBuffer.makeComputeCommandEncoder() {
                    enc.label = "SSimDownscaler_Passthrough"
                    enc.setComputePipelineState(pipe)
                    enc.setTexture(source, index: 0)
                    enc.setTexture(destination, index: 1)
                    dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                    enc.endEncoding()
                }
            } else {
                struct SSimUniforms {
                    var oversharp: Float
                    var _pad0: UInt32 = 0
                    var _pad1: UInt32 = 0
                    var _pad2: UInt32 = 0
                }
                var u = SSimUniforms(oversharp: parameters.float32("oversharp", default: 1.0))

                let p1 = try shaderManager.computePipeline(library: "SSimDownscaler", function: "ssim_pass1_postkernel", effectHint: .ssimDownscaler)
                let p2 = try shaderManager.computePipeline(library: "SSimDownscaler", function: "ssim_pass2_l2_v", effectHint: .ssimDownscaler)
                let p3 = try shaderManager.computePipeline(library: "SSimDownscaler", function: "ssim_pass3_l2_h", effectHint: .ssimDownscaler)
                let p4 = try shaderManager.computePipeline(library: "SSimDownscaler", function: "ssim_pass4_mean_r", effectHint: .ssimDownscaler)
                let p5 = try shaderManager.computePipeline(library: "SSimDownscaler", function: "ssim_pass5_reconstruct", effectHint: .ssimDownscaler)

                let postTex = try texturePool.acquire(width: outW, height: outH, pixelFormat: destination.pixelFormat, usage: rwUsage, storageMode: .private)
                let l2Tex = try texturePool.acquire(width: inW, height: outH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
                let l22Tex = try texturePool.acquire(width: outW, height: outH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
                let mrTex = try texturePool.acquire(width: outW, height: outH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
                frameLeases.append(contentsOf: [postTex, l2Tex, l22Tex, mrTex])

                if let enc = commandBuffer.makeComputeCommandEncoder() {
                    enc.label = "SSimDownscaler_5Pass"
                    enc.setComputePipelineState(p1)
                    enc.setTexture(source, index: 0)
                    enc.setTexture(postTex.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: p1, width: outW, height: outH)

                    enc.setComputePipelineState(p2)
                    enc.setTexture(source, index: 0)
                    enc.setTexture(l2Tex.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: p2, width: inW, height: outH)

                    enc.setComputePipelineState(p3)
                    enc.setTexture(l2Tex.texture, index: 0)
                    enc.setTexture(l22Tex.texture, index: 1)
                    dispatch2D(encoder: enc, pipeline: p3, width: outW, height: outH)

                    enc.setComputePipelineState(p4)
                    enc.setTexture(postTex.texture, index: 0)
                    enc.setTexture(l22Tex.texture, index: 1)
                    enc.setTexture(mrTex.texture, index: 2)
                    enc.setBytes(&u, length: MemoryLayout<SSimUniforms>.stride, index: 0)
                    dispatch2D(encoder: enc, pipeline: p4, width: outW, height: outH)

                    enc.setComputePipelineState(p5)
                    enc.setTexture(mrTex.texture, index: 0)
                    enc.setTexture(postTex.texture, index: 1)
                    enc.setTexture(destination, index: 2)
                    dispatch2D(encoder: enc, pipeline: p5, width: outW, height: outH)
                    enc.endEncoding()
                }
            }

        case .deband:
            struct DebandUniforms {
                var threshold: Float
                var range: Float
                var grain: Float
                var frameSeed: Float
            }
            var u = DebandUniforms(
                threshold: parameters.float32("threshold", default: 0.015),
                range: parameters.float32("range", default: 16.0),
                grain: parameters.float32("grain", default: 0.006),
                frameSeed: Float((frameIndex % 1024) + 1) * 0.371
            )
            let pipe = try shaderManager.computePipeline(library: "Interpolation", function: "deband", effectHint: .deband)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Deband"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&u, length: MemoryLayout<DebandUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }

        case .imageAdjustment:
            struct ImageAdjustmentUniforms {
                var gamma: Float
                var brightness: Float
                var contrast: Float
                var saturation: Float
                var vibrance: Float
                var temperature: Float
                var _pad0: UInt32 = 0
                var _pad1: UInt32 = 0
            }
            var u = ImageAdjustmentUniforms(
                gamma: parameters.float32("gamma", default: 1.0),
                brightness: parameters.float32("brightness", default: 0.0),
                contrast: parameters.float32("contrast", default: 1.0),
                saturation: parameters.float32("saturation", default: 1.0),
                vibrance: parameters.float32("vibrance", default: 0.0),
                temperature: parameters.float32("temperature", default: 0.0)
            )
            let pipe = try shaderManager.computePipeline(library: "Interpolation", function: "image_adjustment", effectHint: .imageAdjustment)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "ImageAdjustment"
                enc.setComputePipelineState(pipe)
                enc.setTexture(source, index: 0)
                enc.setTexture(destination, index: 1)
                enc.setBytes(&u, length: MemoryLayout<ImageAdjustmentUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: pipe, width: outW, height: outH)
                enc.endEncoding()
            }
        }
    }

    // MARK: - Neural Multi-Pass Encoders (Anime4K v4.0.1 Suite & CuNNy)

    private struct Anime4KNeuralUniforms {
        var strength: Float
        var clampHighlights: UInt32
        var _pad0: UInt32 = 0
        var _pad1: UInt32 = 0
    }

    private func encodeAnime4KRestore(
        variant: String,
        strength: Float,
        clampHighlights: Bool,
        source: any MTLTexture,
        destination: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        frameLeases: inout [PooledTexture]
    ) throws {
        let inW = source.width
        let inH = source.height
        let rwUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        var u = Anime4KNeuralUniforms(strength: strength, clampHighlights: clampHighlights ? 1 : 0)

        switch variant {
        case "S", "softS":
            let isSoft = (variant == "softS")
            let p1 = try shaderManager.computePipeline(library: "Anime4K", function: isSoft ? "a4k_restore_soft_s_p1" : "anime4k_restore_pass1", effectHint: .anime4kRestore)
            let p2 = try shaderManager.computePipeline(library: "Anime4K", function: isSoft ? "a4k_restore_soft_s_p2" : "anime4k_restore_pass2", effectHint: .anime4kRestore)
            let p3 = try shaderManager.computePipeline(library: "Anime4K", function: isSoft ? "a4k_restore_soft_s_p3" : "anime4k_restore_pass3", effectHint: .anime4kRestore)
            let p4 = try shaderManager.computePipeline(library: "Anime4K", function: isSoft ? "a4k_restore_soft_s_p4" : "anime4k_restore_pass4", effectHint: .anime4kRestore)
            let t1 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t2 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(contentsOf: [t1, t2])
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = isSoft ? "Anime4K_Restore_SoftS" : "Anime4K_Restore_S"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t2.texture, index: 0)
                enc.setTexture(t1.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                enc.setTexture(destination, index: 2)
                enc.setBytes(&u, length: MemoryLayout<Anime4KNeuralUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)
                enc.endEncoding()
            }

        case "L", "softL":
            let prefix = (variant == "softL") ? "a4k_restore_soft_l" : "a4k_restore_l"
            let p1 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p1", effectHint: .anime4kRestore)
            let p2 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p2", effectHint: .anime4kRestore)
            let p3 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p3", effectHint: .anime4kRestore)
            let p4 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p4", effectHint: .anime4kRestore)
            let p5 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p5", effectHint: .anime4kRestore)
            let t1 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t2 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t3 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t4 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(contentsOf: [t1, t2, t3, t4])
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Anime4K_Restore_\(variant)"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                enc.setTexture(t2.texture, index: 2)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                enc.setTexture(t3.texture, index: 2)
                enc.setTexture(t4.texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t3.texture, index: 0)
                enc.setTexture(t4.texture, index: 1)
                enc.setTexture(t1.texture, index: 2)
                enc.setTexture(t2.texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                enc.setTexture(t3.texture, index: 2)
                enc.setTexture(t4.texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)

                enc.setComputePipelineState(p5)
                enc.setTexture(source, index: 0)
                enc.setTexture(t3.texture, index: 1)
                enc.setTexture(t4.texture, index: 2)
                enc.setTexture(destination, index: 3)
                enc.setBytes(&u, length: MemoryLayout<Anime4KNeuralUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p5, width: inW, height: inH)
                enc.endEncoding()
            }

        case "VL":
            let p1 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "a4k_restore_vl_p1", effectHint: .anime4kRestore)
            let p2 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "a4k_restore_vl_p2", effectHint: .anime4kRestore)
            let p3 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "a4k_restore_vl_p3", effectHint: .anime4kRestore)
            let p4 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "a4k_restore_vl_p4", effectHint: .anime4kRestore)
            let p5 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "a4k_restore_vl_p5", effectHint: .anime4kRestore)
            let p6 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "a4k_restore_vl_p6", effectHint: .anime4kRestore)
            let p7 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "a4k_restore_vl_p7", effectHint: .anime4kRestore)
            let p8 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "a4k_restore_vl_p8", effectHint: .anime4kRestore)
            let t1 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t2 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t3 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t4 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t5 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t6 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(contentsOf: [t1, t2, t3, t4, t5, t6])
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Anime4K_Restore_VL"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                enc.setTexture(t2.texture, index: 2)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                enc.setTexture(t3.texture, index: 2)
                enc.setTexture(t4.texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t3.texture, index: 0)
                enc.setTexture(t4.texture, index: 1)
                enc.setTexture(t1.texture, index: 2)
                enc.setTexture(t2.texture, index: 3)
                enc.setTexture(t5.texture, index: 4)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                enc.setTexture(t5.texture, index: 2)
                enc.setTexture(t3.texture, index: 3)
                enc.setTexture(t4.texture, index: 4)
                enc.setTexture(t6.texture, index: 5)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)

                enc.setComputePipelineState(p5)
                enc.setTexture(t3.texture, index: 0)
                enc.setTexture(t4.texture, index: 1)
                enc.setTexture(t6.texture, index: 2)
                enc.setTexture(t1.texture, index: 3)
                enc.setTexture(t2.texture, index: 4)
                enc.setTexture(t5.texture, index: 5)
                dispatch2D(encoder: enc, pipeline: p5, width: inW, height: inH)

                enc.setComputePipelineState(p6)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                enc.setTexture(t5.texture, index: 2)
                enc.setTexture(t3.texture, index: 3)
                enc.setTexture(t4.texture, index: 4)
                enc.setTexture(t6.texture, index: 5)
                dispatch2D(encoder: enc, pipeline: p6, width: inW, height: inH)

                enc.setComputePipelineState(p7)
                enc.setTexture(t3.texture, index: 0)
                enc.setTexture(t4.texture, index: 1)
                enc.setTexture(t6.texture, index: 2)
                enc.setTexture(t1.texture, index: 3)
                enc.setTexture(t2.texture, index: 4)
                enc.setTexture(t5.texture, index: 5)
                dispatch2D(encoder: enc, pipeline: p7, width: inW, height: inH)

                enc.setComputePipelineState(p8)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                enc.setTexture(t2.texture, index: 2)
                enc.setTexture(t5.texture, index: 3)
                enc.setTexture(destination, index: 4)
                enc.setBytes(&u, length: MemoryLayout<Anime4KNeuralUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p8, width: inW, height: inH)
                enc.endEncoding()
            }

        default: // "M" and "softM"
            let prefix = (variant == "softM") ? "a4k_restore_soft_m" : "a4k_restore_m"
            let p1 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p1", effectHint: .anime4kRestore)
            let p2 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p2", effectHint: .anime4kRestore)
            let p3 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p3", effectHint: .anime4kRestore)
            let p4 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p4", effectHint: .anime4kRestore)
            let p5 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p5", effectHint: .anime4kRestore)
            let p6 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p6", effectHint: .anime4kRestore)
            let p7 = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p7", effectHint: .anime4kRestore)
            let t1 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t2 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t3 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t4 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t5 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t6 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(contentsOf: [t1, t2, t3, t4, t5, t6])
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Anime4K_Restore_\(variant)"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t2.texture, index: 0)
                enc.setTexture(t3.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(t3.texture, index: 0)
                enc.setTexture(t4.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)

                enc.setComputePipelineState(p5)
                enc.setTexture(t4.texture, index: 0)
                enc.setTexture(t5.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p5, width: inW, height: inH)

                enc.setComputePipelineState(p6)
                enc.setTexture(t5.texture, index: 0)
                enc.setTexture(t6.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p6, width: inW, height: inH)

                enc.setComputePipelineState(p7)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                enc.setTexture(t2.texture, index: 2)
                enc.setTexture(t3.texture, index: 3)
                enc.setTexture(t4.texture, index: 4)
                enc.setTexture(t5.texture, index: 5)
                enc.setTexture(t6.texture, index: 6)
                enc.setTexture(destination, index: 7)
                enc.setBytes(&u, length: MemoryLayout<Anime4KNeuralUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p7, width: inW, height: inH)
                enc.endEncoding()
            }
        }
    }

    private func encodeAnime4KUpscale(
        variant: String,
        strength: Float,
        clampHighlights: Bool,
        source: any MTLTexture,
        destination: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        frameLeases: inout [PooledTexture]
    ) throws {
        let inW = source.width
        let inH = source.height
        let outW = destination.width
        let outH = destination.height
        let rwUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        var u = Anime4KNeuralUniforms(strength: strength, clampHighlights: clampHighlights ? 1 : 0)

        switch variant {
        case "S":
            let p1 = try shaderManager.computePipeline(library: "Anime4K", function: "a4k_upscale_s_p1", effectHint: .anime4kUpscale)
            let p2 = try shaderManager.computePipeline(library: "Anime4K", function: "a4k_upscale_s_p2", effectHint: .anime4kUpscale)
            let p3 = try shaderManager.computePipeline(library: "Anime4K", function: "a4k_upscale_s_p3", effectHint: .anime4kUpscale)
            let p4 = try shaderManager.computePipeline(library: "Anime4K", function: "a4k_upscale_s_p4", effectHint: .anime4kUpscale)
            let t1 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t2 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(contentsOf: [t1, t2])
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Anime4K_Upscale_S"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t2.texture, index: 0)
                enc.setTexture(t1.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                enc.setTexture(destination, index: 2)
                enc.setBytes(&u, length: MemoryLayout<Anime4KNeuralUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)
                enc.endEncoding()
            }

        case "M":
            let p1 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upscale_m_p1", effectHint: .anime4kUpscale)
            let p2 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upscale_m_p2", effectHint: .anime4kUpscale)
            let p3 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upscale_m_p3", effectHint: .anime4kUpscale)
            let p4 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upscale_m_p4", effectHint: .anime4kUpscale)
            let p5 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upscale_m_p5", effectHint: .anime4kUpscale)
            let p6 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upscale_m_p6", effectHint: .anime4kUpscale)
            let p7 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upscale_m_p7", effectHint: .anime4kUpscale)
            var t: [PooledTexture] = []
            t.reserveCapacity(8)
            for _ in 0..<8 {
                t.append(try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private))
            }
            frameLeases.append(contentsOf: t)
            // t[0]=tex1 .. t[7]=tex8
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Anime4K_Upscale_M"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(t[0].texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(t[0].texture, index: 0)
                enc.setTexture(t[2].texture, index: 1)
                enc.setTexture(t[3].texture, index: 2)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t[3].texture, index: 0)
                enc.setTexture(t[2].texture, index: 1)
                enc.setTexture(t[1].texture, index: 2)
                enc.setTexture(t[4].texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(t[4].texture, index: 0)
                enc.setTexture(t[1].texture, index: 1)
                enc.setTexture(t[2].texture, index: 2)
                enc.setTexture(t[3].texture, index: 3)
                enc.setTexture(t[5].texture, index: 4)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)

                enc.setComputePipelineState(p5)
                enc.setTexture(t[5].texture, index: 0)
                enc.setTexture(t[2].texture, index: 1)
                enc.setTexture(t[1].texture, index: 2)
                enc.setTexture(t[3].texture, index: 3)
                enc.setTexture(t[0].texture, index: 4)
                enc.setTexture(t[4].texture, index: 5)
                enc.setTexture(t[6].texture, index: 6)
                dispatch2D(encoder: enc, pipeline: p5, width: inW, height: inH)

                enc.setComputePipelineState(p6)
                enc.setTexture(t[6].texture, index: 0)
                enc.setTexture(t[0].texture, index: 1)
                enc.setTexture(t[2].texture, index: 2)
                enc.setTexture(t[1].texture, index: 3)
                enc.setTexture(t[3].texture, index: 4)
                enc.setTexture(t[4].texture, index: 5)
                enc.setTexture(t[5].texture, index: 6)
                enc.setTexture(t[7].texture, index: 7)
                dispatch2D(encoder: enc, pipeline: p6, width: inW, height: inH)

                enc.setComputePipelineState(p7)
                enc.setTexture(t[5].texture, index: 0)
                enc.setTexture(t[7].texture, index: 1)
                enc.setTexture(source, index: 2)
                enc.setTexture(destination, index: 3)
                enc.setBytes(&u, length: MemoryLayout<Anime4KNeuralUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p7, width: outW, height: outH)
                enc.endEncoding()
            }

        case "VL":
            try encodeAnime4KVL2x(
                prefix: "a4k_upscale_vl",
                effectHint: .anime4kUpscale,
                uniforms: &u,
                source: source,
                destination: destination,
                commandBuffer: commandBuffer,
                frameLeases: &frameLeases
            )

        default: // "L"
            try encodeAnime4KL2x(
                prefix: "a4k_upscale_l",
                effectHint: .anime4kUpscale,
                uniforms: &u,
                source: source,
                destination: destination,
                commandBuffer: commandBuffer,
                frameLeases: &frameLeases
            )
        }
    }

    private func encodeAnime4KUpscaleDenoise(
        variant: String,
        strength: Float,
        clampHighlights: Bool,
        source: any MTLTexture,
        destination: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        frameLeases: inout [PooledTexture]
    ) throws {
        let inW = source.width
        let inH = source.height
        let rwUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        var u = Anime4KNeuralUniforms(strength: strength, clampHighlights: clampHighlights ? 1 : 0)

        switch variant {
        case "S":
            let p1 = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_upscale_pass1", effectHint: .anime4kUpscaleDenoise)
            let p2 = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_upscale_pass2", effectHint: .anime4kUpscaleDenoise)
            let p3 = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_upscale_pass3", effectHint: .anime4kUpscaleDenoise)
            let p4 = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_upscale_pass4", effectHint: .anime4kUpscaleDenoise)
            let t1 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            let t2 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(contentsOf: [t1, t2])
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Anime4K_UpscaleDenoise_S"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(t1.texture, index: 0)
                enc.setTexture(t2.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t2.texture, index: 0)
                enc.setTexture(t1.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(source, index: 0)
                enc.setTexture(t1.texture, index: 1)
                enc.setTexture(destination, index: 2)
                enc.setBytes(&u, length: MemoryLayout<Anime4KNeuralUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)
                enc.endEncoding()
            }

        case "M":
            // Balanced 2-stage 4ch pipeline: Restore Soft S (1x) -> Upscale+Denoise S (2x)
            let midTex = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
            frameLeases.append(midTex)
            try encodeAnime4KRestore(
                variant: "softS",
                strength: 1.0,
                clampHighlights: clampHighlights,
                source: source,
                destination: midTex.texture,
                commandBuffer: commandBuffer,
                frameLeases: &frameLeases
            )
            try encodeAnime4KUpscaleDenoise(
                variant: "S",
                strength: strength,
                clampHighlights: clampHighlights,
                source: midTex.texture,
                destination: destination,
                commandBuffer: commandBuffer,
                frameLeases: &frameLeases
            )

        case "VL":
            try encodeAnime4KVL2x(
                prefix: "a4k_upden_vl",
                effectHint: .anime4kUpscaleDenoise,
                uniforms: &u,
                source: source,
                destination: destination,
                commandBuffer: commandBuffer,
                frameLeases: &frameLeases
            )

        default: // "L"
            try encodeAnime4KL2x(
                prefix: "a4k_upden_l",
                effectHint: .anime4kUpscaleDenoise,
                uniforms: &u,
                source: source,
                destination: destination,
                commandBuffer: commandBuffer,
                frameLeases: &frameLeases
            )
        }
    }

    private func encodeAnime4KL2x(
        prefix: String,
        effectHint: EffectID,
        uniforms: inout Anime4KNeuralUniforms,
        source: any MTLTexture,
        destination: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        frameLeases: inout [PooledTexture]
    ) throws {
        let inW = source.width
        let inH = source.height
        let rwUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        let p1 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p1", effectHint: effectHint)
        let p2 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p2", effectHint: effectHint)
        let p3 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p3", effectHint: effectHint)
        let p4 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p4", effectHint: effectHint)
        let t1 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
        let t2 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
        let t3 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
        let t4 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private)
        frameLeases.append(contentsOf: [t1, t2, t3, t4])
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "Anime4K_\(prefix)"
            enc.setComputePipelineState(p1)
            enc.setTexture(source, index: 0)
            enc.setTexture(t1.texture, index: 1)
            enc.setTexture(t2.texture, index: 2)
            dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

            enc.setComputePipelineState(p2)
            enc.setTexture(t1.texture, index: 0)
            enc.setTexture(t2.texture, index: 1)
            enc.setTexture(t3.texture, index: 2)
            enc.setTexture(t4.texture, index: 3)
            dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

            enc.setComputePipelineState(p3)
            enc.setTexture(t3.texture, index: 0)
            enc.setTexture(t4.texture, index: 1)
            enc.setTexture(t1.texture, index: 2)
            enc.setTexture(t2.texture, index: 3)
            dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

            enc.setComputePipelineState(p4)
            enc.setTexture(source, index: 0)
            enc.setTexture(t1.texture, index: 1)
            enc.setTexture(t2.texture, index: 2)
            enc.setTexture(destination, index: 3)
            enc.setBytes(&uniforms, length: MemoryLayout<Anime4KNeuralUniforms>.stride, index: 0)
            dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)
            enc.endEncoding()
        }
    }

    private func encodeAnime4KVL2x(
        prefix: String,
        effectHint: EffectID,
        uniforms: inout Anime4KNeuralUniforms,
        source: any MTLTexture,
        destination: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        frameLeases: inout [PooledTexture]
    ) throws {
        let inW = source.width
        let inH = source.height
        let rwUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        let p1 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p1", effectHint: effectHint)
        let p2 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p2", effectHint: effectHint)
        let p3 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p3", effectHint: effectHint)
        let p4 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p4", effectHint: effectHint)
        let p5 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p5", effectHint: effectHint)
        let p6 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p6", effectHint: effectHint)
        let p7 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p7", effectHint: effectHint)
        let p8 = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "\(prefix)_p8", effectHint: effectHint)

        var c: [PooledTexture] = []
        c.reserveCapacity(14)
        for _ in 0..<14 {
            c.append(try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba16Float, usage: rwUsage, storageMode: .private))
        }
        frameLeases.append(contentsOf: c)

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "Anime4K_\(prefix)"
            enc.setComputePipelineState(p1)
            enc.setTexture(source, index: 0)
            enc.setTexture(c[0].texture, index: 1)
            enc.setTexture(c[1].texture, index: 2)
            dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

            let midPipes = [p2, p3, p4, p5, p6, p7]
            for (idx, pipe) in midPipes.enumerated() {
                let inBase = idx * 2
                let outBase = (idx + 1) * 2
                enc.setComputePipelineState(pipe)
                enc.setTexture(c[inBase].texture, index: 0)
                enc.setTexture(c[inBase + 1].texture, index: 1)
                enc.setTexture(c[outBase].texture, index: 2)
                enc.setTexture(c[outBase + 1].texture, index: 3)
                dispatch2D(encoder: enc, pipeline: pipe, width: inW, height: inH)
            }

            enc.setComputePipelineState(p8)
            enc.setTexture(source, index: 0)
            for i in 0..<14 {
                enc.setTexture(c[i].texture, index: i + 1)
            }
            enc.setTexture(destination, index: 15)
            enc.setBytes(&uniforms, length: MemoryLayout<Anime4KNeuralUniforms>.stride, index: 0)
            dispatch2D(encoder: enc, pipeline: p8, width: inW, height: inH)
            enc.endEncoding()
        }
    }

    private func encodeCuNNy(
        variant: String,
        sharpness: Float,
        source: any MTLTexture,
        destination: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        frameLeases: inout [PooledTexture]
    ) throws {
        struct CuNNyUniforms {
            var sharpness: Float
            var _pad0: UInt32 = 0
            var _pad1: UInt32 = 0
            var _pad2: UInt32 = 0
        }
        let inW = source.width
        let inH = source.height
        let rwUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        var u = CuNNyUniforms(sharpness: sharpness)

        // Authentic CuNNy2 ReLU1 intermediate format (.rgba8Unorm clamps feature maps to [0, 1]).
        switch variant {
        case "fast":
            let p1 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_fast_p1", effectHint: .cunny)
            let p2 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_fast_p2", effectHint: .cunny)
            let p3 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_fast_p3", effectHint: .cunny)
            let p4 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_fast_p4", effectHint: .cunny)
            let t0 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba8Unorm, usage: rwUsage, storageMode: .private)
            let t1 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba8Unorm, usage: rwUsage, storageMode: .private)
            let t2 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba8Unorm, usage: rwUsage, storageMode: .private)
            let t3 = try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba8Unorm, usage: rwUsage, storageMode: .private)
            frameLeases.append(contentsOf: [t0, t1, t2, t3])
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "CuNNy_Fast"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(t0.texture, index: 1)
                enc.setTexture(t1.texture, index: 2)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(t0.texture, index: 0)
                enc.setTexture(t1.texture, index: 1)
                enc.setTexture(t2.texture, index: 2)
                enc.setTexture(t3.texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t2.texture, index: 0)
                enc.setTexture(t3.texture, index: 1)
                enc.setTexture(t0.texture, index: 2)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(source, index: 0)
                enc.setTexture(t0.texture, index: 1)
                enc.setTexture(destination, index: 2)
                enc.setBytes(&u, length: MemoryLayout<CuNNyUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)
                enc.endEncoding()
            }

        case "highQuality":
            let p1 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_hq_p1", effectHint: .cunny)
            let p2 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_hq_p2", effectHint: .cunny)
            let p3 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_hq_p3", effectHint: .cunny)
            let p4 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_hq_p4", effectHint: .cunny)
            let p5 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_hq_p5", effectHint: .cunny)
            var t: [PooledTexture] = []
            t.reserveCapacity(6)
            for _ in 0..<6 {
                t.append(try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba8Unorm, usage: rwUsage, storageMode: .private))
            }
            frameLeases.append(contentsOf: t)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "CuNNy_HighQuality"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(t[0].texture, index: 1)
                enc.setTexture(t[1].texture, index: 2)
                enc.setTexture(t[2].texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(t[0].texture, index: 0)
                enc.setTexture(t[1].texture, index: 1)
                enc.setTexture(t[2].texture, index: 2)
                enc.setTexture(t[3].texture, index: 3)
                enc.setTexture(t[4].texture, index: 4)
                enc.setTexture(t[5].texture, index: 5)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t[3].texture, index: 0)
                enc.setTexture(t[4].texture, index: 1)
                enc.setTexture(t[5].texture, index: 2)
                enc.setTexture(t[0].texture, index: 3)
                enc.setTexture(t[1].texture, index: 4)
                enc.setTexture(t[2].texture, index: 5)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(t[0].texture, index: 0)
                enc.setTexture(t[1].texture, index: 1)
                enc.setTexture(t[2].texture, index: 2)
                enc.setTexture(t[3].texture, index: 3)
                enc.setTexture(t[4].texture, index: 4)
                enc.setTexture(t[5].texture, index: 5)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)

                enc.setComputePipelineState(p5)
                enc.setTexture(source, index: 0)
                enc.setTexture(t[3].texture, index: 1)
                enc.setTexture(t[4].texture, index: 2)
                enc.setTexture(t[5].texture, index: 3)
                enc.setTexture(destination, index: 4)
                enc.setBytes(&u, length: MemoryLayout<CuNNyUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p5, width: inW, height: inH)
                enc.endEncoding()
            }

        default: // "balanced"
            let p1 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_bal_p1", effectHint: .cunny)
            let p2 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_bal_p2", effectHint: .cunny)
            let p3 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_bal_p3", effectHint: .cunny)
            let p4 = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_bal_p4", effectHint: .cunny)
            var t: [PooledTexture] = []
            t.reserveCapacity(6)
            for _ in 0..<6 {
                t.append(try texturePool.acquire(width: inW, height: inH, pixelFormat: .rgba8Unorm, usage: rwUsage, storageMode: .private))
            }
            frameLeases.append(contentsOf: t)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "CuNNy_Balanced"
                enc.setComputePipelineState(p1)
                enc.setTexture(source, index: 0)
                enc.setTexture(t[0].texture, index: 1)
                enc.setTexture(t[1].texture, index: 2)
                enc.setTexture(t[2].texture, index: 3)
                dispatch2D(encoder: enc, pipeline: p1, width: inW, height: inH)

                enc.setComputePipelineState(p2)
                enc.setTexture(t[0].texture, index: 0)
                enc.setTexture(t[1].texture, index: 1)
                enc.setTexture(t[2].texture, index: 2)
                enc.setTexture(t[3].texture, index: 3)
                enc.setTexture(t[4].texture, index: 4)
                enc.setTexture(t[5].texture, index: 5)
                dispatch2D(encoder: enc, pipeline: p2, width: inW, height: inH)

                enc.setComputePipelineState(p3)
                enc.setTexture(t[3].texture, index: 0)
                enc.setTexture(t[4].texture, index: 1)
                enc.setTexture(t[5].texture, index: 2)
                enc.setTexture(t[0].texture, index: 3)
                enc.setTexture(t[1].texture, index: 4)
                dispatch2D(encoder: enc, pipeline: p3, width: inW, height: inH)

                enc.setComputePipelineState(p4)
                enc.setTexture(source, index: 0)
                enc.setTexture(t[0].texture, index: 1)
                enc.setTexture(t[1].texture, index: 2)
                enc.setTexture(destination, index: 3)
                enc.setBytes(&u, length: MemoryLayout<CuNNyUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: p4, width: inW, height: inH)
                enc.endEncoding()
            }
        }
    }

    // MARK: - Helper Encoders (Crop, Bicubic, Present)

    private func encodeCropPass(
        source: any MTLTexture,
        destination: any MTLTexture,
        origin: SIMD2<UInt32>,
        size: SIMD2<UInt32>,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        struct CropUniforms {
            var cropOrigin: SIMD2<UInt32>
            var cropSize: SIMD2<UInt32>
        }
        var u = CropUniforms(cropOrigin: origin, cropSize: size)
        let pipe = try shaderManager.computePipeline(library: "Common", function: "cropBlit")
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "CropBlit"
            enc.setComputePipelineState(pipe)
            enc.setTexture(source, index: 0)
            enc.setTexture(destination, index: 1)
            enc.setBytes(&u, length: MemoryLayout<CropUniforms>.stride, index: 0)
            dispatch2D(encoder: enc, pipeline: pipe, width: destination.width, height: destination.height)
            enc.endEncoding()
        }
    }

    private func encodeBicubic(
        source: any MTLTexture,
        destination: any MTLTexture,
        b: Float,
        c: Float,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        struct BicubicUniforms {
            var paramB: Float
            var paramC: Float
            var _pad0: UInt32 = 0
            var _pad1: UInt32 = 0
        }
        var u = BicubicUniforms(paramB: b, paramC: c)
        let pipe = try shaderManager.computePipeline(library: "Interpolation", function: "bicubic", effectHint: .bicubic)
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "Bicubic"
            enc.setComputePipelineState(pipe)
            enc.setTexture(source, index: 0)
            enc.setTexture(destination, index: 1)
            enc.setBytes(&u, length: MemoryLayout<BicubicUniforms>.stride, index: 0)
            dispatch2D(encoder: enc, pipeline: pipe, width: destination.width, height: destination.height)
            enc.endEncoding()
        }
    }

    /// Writes `contentTexture` into `destinationTexture`:
    /// - When `destinationTexture` is sized to the intermediate upscaled content (`contentTexture.size != layout.targetPixelSize`,
    ///   e.g. `RenderLoopController`'s intermediate `dstTex` before its own `PresentPassRenderer`), copies 1:1 with full
    ///   `(0, 0, 1, 1)` dest & UV rects (zero double-letterbox / double-crop!).
    /// - Otherwise (`destinationTexture` is the full target canvas), executes the single-pass TBDR present with
    ///   9-point alignment, black letterbox clear, HDR/SDR, and optional VRR cursor/HUD overlays.
    private func encodeOutputOrPresent(
        contentTexture: any MTLTexture,
        destinationTexture: any MTLTexture,
        layout: ScalingLayoutResult,
        isHDR: Bool,
        allowOverlays: Bool,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let isIntermediateContentBuffer = (
            destinationTexture.width == contentTexture.width &&
            destinationTexture.height == contentTexture.height &&
            (contentTexture.width != layout.targetPixelSize.width ||
             contentTexture.height != layout.targetPixelSize.height)
        )

        if isIntermediateContentBuffer {
            if contentTexture.pixelFormat == destinationTexture.pixelFormat,
               let blit = commandBuffer.makeBlitCommandEncoder()
            {
                blit.label = "EffectChain_OutputBlit1to1"
                blit.copy(
                    from: contentTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: contentTexture.width, height: contentTexture.height, depth: 1),
                    to: destinationTexture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
                return
            }

            try encodePresentPass(
                contentTexture: contentTexture,
                destinationTexture: destinationTexture,
                layout: layout,
                isHDR: isHDR,
                forceFullFramePassthrough: true,
                allowOverlays: false,
                commandBuffer: commandBuffer
            )
            return
        }

        try encodePresentPass(
            contentTexture: contentTexture,
            destinationTexture: destinationTexture,
            layout: layout,
            isHDR: isHDR,
            forceFullFramePassthrough: false,
            allowOverlays: allowOverlays,
            commandBuffer: commandBuffer
        )
    }

    private func encodePresentPass(
        contentTexture: any MTLTexture,
        destinationTexture: any MTLTexture,
        layout: ScalingLayoutResult,
        isHDR: Bool,
        forceFullFramePassthrough: Bool = false,
        allowOverlays: Bool = true,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        struct PresentUniforms {
            var destRectNorm: SIMD4<Float>
            var uvRect: SIMD4<Float>
            var cursorRectNorm: SIMD4<Float>
            var hudRectNorm: SIMD4<Float>
            var exposure: Float
            var flags: UInt32
            var _pad0: UInt32 = 0
            var _pad1: UInt32 = 0
        }

        let dstW = max(1.0, Float(destinationTexture.width))
        let dstH = max(1.0, Float(destinationTexture.height))
        let vis = layout.visibleContentPixelRect
        let destRectNorm: SIMD4<Float>
        let uvRect: SIMD4<Float>
        let fillsCanvas: Bool

        if forceFullFramePassthrough {
            destRectNorm = SIMD4<Float>(0, 0, 1, 1)
            uvRect = SIMD4<Float>(0, 0, 1, 1)
            fillsCanvas = true
        } else {
            if vis.width > 0 && vis.height > 0 {
                destRectNorm = SIMD4<Float>(
                    Float(vis.x) / dstW,
                    Float(vis.y) / dstH,
                    Float(vis.width) / dstW,
                    Float(vis.height) / dstH
                )
            } else {
                destRectNorm = SIMD4<Float>(0, 0, 1, 1)
            }
            let uv = layout.visibleTextureUVRect
            uvRect = SIMD4<Float>(
                Float(uv.origin.x),
                Float(uv.origin.y),
                Float(uv.size.width),
                Float(uv.size.height)
            )
            fillsCanvas = (vis.x == 0 && vis.y == 0 && vis.width == destinationTexture.width && vis.height == destinationTexture.height)
        }

        let overlay = allowOverlays ? state.withLockUnchecked { $0.presentOverlayOptions } : nil
        let cursorTex = overlay?.cursorTexture ?? dummyOverlayTexture
        let hudTex = overlay?.hudTexture ?? dummyOverlayTexture
        let hasCursor = overlay?.cursorTexture != nil
        let hasHUD = overlay?.hudTexture != nil

        var flags: UInt32 = 0
        if isHDR { flags |= 1 }
        if hasCursor { flags |= 2 }
        if overlay?.cursorNearest == true { flags |= 4 }
        if hasHUD { flags |= 8 }
        if overlay?.applySRGBDecode == true { flags |= 16 }
        if overlay?.applySRGBEncode == true { flags |= 32 }

        let cRect = overlay?.cursorRectNormalized ?? .zero
        let hRect = overlay?.hudRectNormalized ?? .zero

        var u = PresentUniforms(
            destRectNorm: destRectNorm,
            uvRect: uvRect,
            cursorRectNorm: SIMD4<Float>(Float(cRect.origin.x), Float(cRect.origin.y), Float(cRect.size.width), Float(cRect.size.height)),
            hudRectNorm: SIMD4<Float>(Float(hRect.origin.x), Float(hRect.origin.y), Float(hRect.size.width), Float(hRect.size.height)),
            exposure: overlay?.exposure ?? 1.0,
            flags: flags
        )

        if destinationTexture.usage.contains(.renderTarget) {
            let renderPipe = try shaderManager.renderPipeline(
                library: "Common",
                vertexFunction: "presentVertex",
                fragmentFunction: "presentFragment",
                colorPixelFormat: destinationTexture.pixelFormat
            )
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = destinationTexture
            passDesc.colorAttachments[0].loadAction = fillsCanvas ? .dontCare : .clear
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            passDesc.colorAttachments[0].storeAction = .store

            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) {
                enc.label = "Present_TBDR"
                enc.setRenderPipelineState(renderPipe)
                enc.setFragmentTexture(contentTexture, index: 0)
                enc.setFragmentTexture(cursorTex, index: 1)
                enc.setFragmentTexture(hudTex, index: 2)
                enc.setFragmentBytes(&u, length: MemoryLayout<PresentUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        } else {
            let computePipe = try shaderManager.computePipeline(library: "Common", function: "presentCompute")
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Present_Compute"
                enc.setComputePipelineState(computePipe)
                enc.setTexture(contentTexture, index: 0)
                enc.setTexture(cursorTex, index: 1)
                enc.setTexture(hudTex, index: 2)
                enc.setTexture(destinationTexture, index: 3)
                enc.setBytes(&u, length: MemoryLayout<PresentUniforms>.stride, index: 0)
                dispatch2D(encoder: enc, pipeline: computePipe, width: destinationTexture.width, height: destinationTexture.height)
                enc.endEncoding()
            }
        }
    }

    // MARK: - GPU Duplicate Frame Detection & Output Cache

    private func checkDuplicateFrameOnGPU(
        currentSource: any MTLTexture,
        queue: any MTLCommandQueue,
        mode: DuplicateFrameMode,
        signature: String
    ) throws -> (texture: any MTLTexture, size: PixelSize)? {
        let candidate: (prev: any MTLTexture, cachedOut: any MTLTexture, cachedSize: PixelSize, shouldCheck: Bool)? = state.withLockUnchecked { s in
            guard s.duplicate.cachedSignature == signature,
                  let prev = s.duplicate.prevCroppedTexture,
                  let cachedOut = s.duplicate.cachedFinalOutputTexture,
                  prev.width == currentSource.width,
                  prev.height == currentSource.height,
                  prev.pixelFormat == currentSource.pixelFormat
            else {
                return nil
            }

            if mode == .dynamic {
                if s.duplicate.skipRemaining > 0 {
                    s.duplicate.skipRemaining -= 1
                    return (prev, cachedOut, s.duplicate.cachedOutputSize, false)
                }
            }
            return (prev, cachedOut, s.duplicate.cachedOutputSize, true)
        }

        guard let candidate, candidate.shouldCheck else {
            return nil
        }

        struct DuplicateCheckUniforms {
            var tolerance: Float
            var _pad0: UInt32 = 0
            var _pad1: UInt32 = 0
            var _pad2: UInt32 = 0
        }
        var u = DuplicateCheckUniforms(tolerance: 1.0 / 512.0)

        duplicateFlagBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        let pipe = try shaderManager.computePipeline(library: "Common", function: "duplicateFrameCheck")
        guard let checkCB = queue.makeCommandBuffer(),
              let enc = checkCB.makeComputeCommandEncoder()
        else {
            return nil
        }
        checkCB.label = "MetalPie_DuplicateFrameCheck"
        enc.setComputePipelineState(pipe)
        enc.setTexture(currentSource, index: 0)
        enc.setTexture(candidate.prev, index: 1)
        enc.setBuffer(duplicateFlagBuffer, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<DuplicateCheckUniforms>.stride, index: 1)
        let quadW = max(1, (currentSource.width + 1) / 2)
        let quadH = max(1, (currentSource.height + 1) / 2)
        dispatch2D(encoder: enc, pipeline: pipe, width: quadW, height: quadH)
        enc.endEncoding()
        checkCB.commit()
        checkCB.waitUntilCompleted()

        let changed = duplicateFlagBuffer.contents().load(as: UInt32.self) != 0
        state.withLockUnchecked { s in
            if !changed {
                // Identical frame: immediately reset Dynamic cadence to tight checking.
                s.duplicate.checkRemaining = 16
                s.duplicate.nextSkipCount = 1
                s.duplicate.skipRemaining = 0
            } else if mode == .dynamic {
                s.duplicate.checkRemaining -= 1
                if s.duplicate.checkRemaining <= 0 {
                    s.duplicate.skipRemaining = s.duplicate.nextSkipCount
                    s.duplicate.nextSkipCount = min(16, s.duplicate.nextSkipCount * 2)
                    s.duplicate.checkRemaining = max(2, (-4 * s.duplicate.nextSkipCount + 78) / 7)
                }
            }
        }

        return changed ? nil : (candidate.cachedOut, candidate.cachedSize)
    }

    private func updatePreviousSourceCache(from source: any MTLTexture, commandBuffer: any MTLCommandBuffer) {
        let dest: (any MTLTexture)? = state.withLockUnchecked { s in
            if let existing = s.duplicate.prevCroppedTexture,
               existing.width == source.width,
               existing.height == source.height,
               existing.pixelFormat == source.pixelFormat
            {
                return existing
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat,
                width: source.width,
                height: source.height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            let created = device.makeTexture(descriptor: desc)
            created?.label = "MetalPie_PrevSourceCache"
            s.duplicate.prevCroppedTexture = created
            return created
        }

        guard let dest, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "CachePrevSource"
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: dest,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    private func cacheFinalOutputTexture(
        from finalTex: any MTLTexture,
        size: PixelSize,
        signature: String,
        commandBuffer: any MTLCommandBuffer
    ) {
        let dest: (any MTLTexture)? = state.withLockUnchecked { s in
            if let existing = s.duplicate.cachedFinalOutputTexture,
               existing.width == finalTex.width,
               existing.height == finalTex.height,
               existing.pixelFormat == finalTex.pixelFormat
            {
                s.duplicate.cachedOutputSize = size
                s.duplicate.cachedSignature = signature
                s.lastCursorFreeOutput = existing
                return existing
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: finalTex.pixelFormat,
                width: finalTex.width,
                height: finalTex.height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            let created = device.makeTexture(descriptor: desc)
            created?.label = "MetalPie_FinalOutputSnapshot"
            s.duplicate.cachedFinalOutputTexture = created
            s.duplicate.cachedOutputSize = size
            s.duplicate.cachedSignature = signature
            s.lastCursorFreeOutput = created
            return created
        }

        guard let dest, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "CacheCursorFreeOutput"
        blit.copy(
            from: finalTex,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: finalTex.width, height: finalTex.height, depth: 1),
            to: dest,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    // MARK: - Prewarm, Profiling & Utilities

    private func prewarmEffect(_ effectID: EffectID, parameters: EffectParameters) throws {
        switch effectID {
        case .metalFXSpatial, .vtSuperResolution:
            _ = try shaderManager.computePipeline(library: "Common", function: "bgraToNV12")
            _ = try shaderManager.computePipeline(library: "Common", function: "nv12ToBGRA")
        case .fsr1EASU:
            _ = try shaderManager.computePipeline(library: "FSR1", function: "fsr1_easu")
        case .fsr1RCAS:
            _ = try shaderManager.computePipeline(library: "FSR1", function: "fsr1_rcas")
        case .sgsr:
            _ = try shaderManager.computePipeline(library: "SGSR", function: "sgsr_upscale")
        case .anime4kRestore:
            let variant = parameters.choice("variant", default: "M")
            switch variant {
            case "S":
                for i in 1...4 {
                    _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_restore_pass\(i)")
                }
            case "softS":
                for i in 1...4 {
                    _ = try shaderManager.computePipeline(library: "Anime4K", function: "a4k_restore_soft_s_p\(i)")
                }
            case "L", "softL":
                let prefix = (variant == "softL") ? "a4k_restore_soft_l" : "a4k_restore_l"
                for i in 1...5 {
                    _ = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p\(i)")
                }
            case "VL":
                for i in 1...8 {
                    _ = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "a4k_restore_vl_p\(i)")
                }
            default: // "M", "softM"
                let prefix = (variant == "softM") ? "a4k_restore_soft_m" : "a4k_restore_m"
                for i in 1...7 {
                    _ = try shaderManager.computePipeline(library: "Anime4KRestoreML", function: "\(prefix)_p\(i)")
                }
            }
        case .anime4kUpscale:
            let variant = parameters.choice("variant", default: "L")
            switch variant {
            case "S":
                for i in 1...4 {
                    _ = try shaderManager.computePipeline(library: "Anime4K", function: "a4k_upscale_s_p\(i)")
                }
            case "M":
                for i in 1...7 {
                    _ = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upscale_m_p\(i)")
                }
            case "VL":
                for i in 1...8 {
                    _ = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upscale_vl_p\(i)")
                }
            default: // "L"
                for i in 1...4 {
                    _ = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upscale_l_p\(i)")
                }
            }
        case .anime4kUpscaleDenoise:
            _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_bilateral_mode")
            let variant = parameters.choice("variant", default: "L")
            switch variant {
            case "S":
                for i in 1...4 {
                    _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_upscale_pass\(i)")
                }
            case "M":
                for i in 1...4 {
                    _ = try shaderManager.computePipeline(library: "Anime4K", function: "a4k_restore_soft_s_p\(i)")
                    _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_upscale_pass\(i)")
                }
            case "VL":
                for i in 1...8 {
                    _ = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upden_vl_p\(i)")
                }
            default: // "L"
                for i in 1...4 {
                    _ = try shaderManager.computePipeline(library: "Anime4KUpscaleML", function: "a4k_upden_l_p\(i)")
                }
            }
        case .anime4kThin:
            _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_sobel")
            if parameters.choice("quality", default: "hq") == "fast" {
                _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_warp")
            } else {
                _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_gauss_x")
                _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_gauss_y")
                _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_kernel")
                _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_thin_hq_warp")
            }
        case .anime4kDarken:
            if parameters.choice("quality", default: "hq") == "fast" {
                _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_darken_fast")
            } else {
                _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_darken_luma")
                _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_darken_diff_x")
                _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_darken_diff_y")
                _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_darken_apply")
            }
        case .anime4kDenoiseBilateral:
            _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_bilateral_full")
        case .anime4kClampHighlights:
            _ = try shaderManager.computePipeline(library: "Anime4K", function: "anime4k_clamp_highlights")
        case .cunny:
            let variant = parameters.choice("variant", default: "balanced")
            switch variant {
            case "fast":
                for i in 1...4 {
                    _ = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_fast_p\(i)")
                }
            case "highQuality":
                for i in 1...5 {
                    _ = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_hq_p\(i)")
                }
            default:
                for i in 1...4 {
                    _ = try shaderManager.computePipeline(library: "CuNNy", function: "cunny_bal_p\(i)")
                }
            }
        case .fxaa:
            _ = try shaderManager.computePipeline(library: "FXAA", function: "fxaa")
        case .jinc:
            _ = try shaderManager.computePipeline(library: "Interpolation", function: "jinc")
        case .fsrcnnx:
            let variant = parameters.choice("variant", default: "standard")
            let prefix = (variant == "lineArt" || variant == "enhancedDetail") ? "fsrcnnx_lineart" : "fsrcnnx_std"
            for i in 1...6 {
                _ = try shaderManager.computePipeline(library: "FSRCNNX", function: "\(prefix)_pass\(i)")
            }
        case .xbrzFreescale:
            _ = try shaderManager.computePipeline(library: "PixelArt", function: "xbrz_pass1")
            _ = try shaderManager.computePipeline(library: "PixelArt", function: "xbrz_pass2")
        case .crtGeom:
            _ = try shaderManager.computePipeline(library: "PixelArt", function: "crt_geom")
        case .crtLottes:
            _ = try shaderManager.computePipeline(library: "PixelArt", function: "crt_lottes")
        case .lanczos6:
            _ = try shaderManager.computePipeline(library: "Interpolation", function: "lanczos6_h")
            _ = try shaderManager.computePipeline(library: "Interpolation", function: "lanczos6_v")
        case .bicubic:
            _ = try shaderManager.computePipeline(library: "Interpolation", function: "bicubic")
        case .sharpBilinear:
            _ = try shaderManager.computePipeline(library: "Interpolation", function: "sharp_bilinear")
        case .pixellate:
            _ = try shaderManager.computePipeline(library: "Interpolation", function: "pixellate")
        case .nearest:
            _ = try shaderManager.computePipeline(library: "Interpolation", function: "nearest")
        case .bilinear:
            _ = try shaderManager.computePipeline(library: "Interpolation", function: "bilinear")
        case .cas:
            _ = try shaderManager.computePipeline(library: "CAS", function: "cas_sharpen")
        case .adaptiveSharpen:
            _ = try shaderManager.computePipeline(library: "CAS", function: "adaptive_sharpen_pass1")
            _ = try shaderManager.computePipeline(library: "CAS", function: "adaptive_sharpen_pass2")
        case .ssimDownscaler:
            _ = try shaderManager.computePipeline(library: "SSimDownscaler", function: "ssim_pass1_postkernel")
            _ = try shaderManager.computePipeline(library: "SSimDownscaler", function: "ssim_pass2_l2_v")
            _ = try shaderManager.computePipeline(library: "SSimDownscaler", function: "ssim_pass3_l2_h")
            _ = try shaderManager.computePipeline(library: "SSimDownscaler", function: "ssim_pass4_mean_r")
            _ = try shaderManager.computePipeline(library: "SSimDownscaler", function: "ssim_pass5_reconstruct")
        case .deband:
            _ = try shaderManager.computePipeline(library: "Interpolation", function: "deband")
        case .imageAdjustment:
            _ = try shaderManager.computePipeline(library: "Interpolation", function: "image_adjustment")
        }
    }

    private func resolveWorkingPixelFormat(sourceFormat: MTLPixelFormat, isHDR: Bool) -> MTLPixelFormat {
        if isHDR || sourceFormat == .rgba16Float {
            return .rgba16Float
        }
        if sourceFormat == .bgr10a2Unorm {
            return .bgr10a2Unorm
        }
        return .bgra8Unorm
    }

    private func makeModeSignature(
        scalingMode: ScalingMode,
        layout: ScalingLayoutResult,
        isHDR: Bool,
        demagnify: DemagnifyMode
    ) -> String {
        var hasher = Hasher()
        hasher.combine(scalingMode)
        hasher.combine(layout.effectPasses)
        hasher.combine(layout.croppedSourceRect)
        hasher.combine(isHDR)
        hasher.combine(demagnify)
        return String(hasher.finalize())
    }

    private func cachedEmaMs(for id: String, fallback: Double) -> Double {
        state.withLockUnchecked { $0.passGPUEmaMs[id] ?? fallback }
    }

    private func attachTimingCompletion(
        commandBuffer: any MTLCommandBuffer,
        records: [(id: String, name: String, colorHex: String, weight: Double)]
    ) {
        let totalWeight = max(records.reduce(0.0) { $0 + max($1.weight, 0.001) }, 0.001)
        let capturedRecords = records
        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            let totalMs = max(0.0, (cb.gpuEndTime - cb.gpuStartTime) * 1000.0)
            guard totalMs > 0 else { return }

            self.state.withLockUnchecked { s in
                var completed: [PassTiming] = []
                completed.reserveCapacity(capturedRecords.count)
                for rec in capturedRecords {
                    let share = max(rec.weight, 0.001) / totalWeight
                    let measured = totalMs * share
                    let prev = s.passGPUEmaMs[rec.id]
                    let smoothed = prev.map { $0 * 0.7 + measured * 0.3 } ?? measured
                    s.passGPUEmaMs[rec.id] = smoothed
                    completed.append(PassTiming(
                        id: rec.id,
                        name: rec.name,
                        gpuMilliseconds: smoothed,
                        colorHex: rec.colorHex
                    ))
                }
                s.lastCompletedPassTimings = completed
            }
        }
    }

    private func uploadCGImageToTexture(_ image: CGImage) throws -> any MTLTexture {
        let w = max(1, image.width)
        let h = max(1, image.height)
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &pixels,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else {
            throw EngineError.screenshotExportFailed("Failed to create CGContext for CGImage upload.")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw EngineError.metalDeviceUnavailable
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        return tex
    }

    private func encodePNGData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw EngineError.screenshotExportFailed("Failed to create PNG image destination.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw EngineError.screenshotExportFailed("Failed to finalize PNG image encoding.")
        }
        return data as Data
    }

    private func makeSyntheticTestTexture(width: Int, height: Int) throws -> any MTLTexture {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 255, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let off = y * bytesPerRow + x * 4
                let diag = ((x + y) / 16) % 2 == 0
                let checker = ((x / 8) + (y / 8)) % 2 == 0
                let r = UInt8(min(255, (x * 255) / max(1, width - 1)))
                let g = UInt8(diag ? 220 : 40)
                let b = UInt8(checker ? 200 : 60)
                bytes[off + 0] = b
                bytes[off + 1] = g
                bytes[off + 2] = r
                bytes[off + 3] = 255
            }
        }
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
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
        return tex
    }

    private static func colorHex(for category: EffectCategory) -> String {
        switch category {
        case .mlUpscaler:      return "#0A84FF"
        case .superResolution: return "#30D158"
        case .anime:           return "#BF5AF2"
        case .pixelArt:        return "#FF9F0A"
        case .crt:             return "#FF375F"
        case .sharpening:      return "#64D2FF"
        case .interpolation:   return "#5E5CE6"
        case .downscaling:     return "#32ADE6"
        case .utility:         return "#AC8E68"
        }
    }

    private static func costWeight(for effectID: EffectID) -> Double {
        switch effectID {
        case .fsrcnnx:                  return 6.0
        case .anime4kUpscaleDenoise:    return 5.0
        case .anime4kUpscale:           return 4.5
        case .anime4kRestore:           return 4.0
        case .cunny:                    return 3.5
        case .ssimDownscaler:           return 3.0
        case .jinc:                     return 2.2
        case .adaptiveSharpen:          return 2.0
        case .xbrzFreescale:            return 2.0
        case .anime4kDenoiseBilateral:  return 1.9
        case .crtLottes, .crtGeom:      return 1.8
        case .anime4kThin, .anime4kDarken: return 1.6
        case .lanczos6:                 return 1.6
        case .vtSuperResolution:        return 1.5
        case .fsr1EASU:                 return 1.4
        case .fxaa:                     return 1.3
        case .metalFXSpatial:           return 1.2
        case .sgsr, .deband:            return 1.1
        case .bicubic:                  return 1.0
        case .fsr1RCAS, .cas, .anime4kClampHighlights: return 0.8
        case .sharpBilinear, .pixellate, .imageAdjustment: return 0.7
        case .nearest, .bilinear:       return 0.5
        }
    }
}
