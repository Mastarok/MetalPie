import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalPieCore
import VideoToolbox
import os

// MARK: - NV12 IOSurface Helper for VideoToolbox ML (`420v`)

/// Holds an IOSurface-backed `420v` (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`)
/// `CVPixelBuffer` alongside its zero-copy Metal Y (`.r8Unorm`) and CbCr (`.rg8Unorm`) views.
final class NV12PixelBufferPair: @unchecked Sendable {
    let width: Int
    let height: Int
    let pixelBuffer: CVPixelBuffer
    let lumaCVTexture: CVMetalTexture
    let chromaCVTexture: CVMetalTexture
    let lumaTexture: any MTLTexture
    let chromaTexture: any MTLTexture

    init?(
        width: Int,
        height: Int,
        resolvedAttributes: CFDictionary?,
        textureCache: CVMetalTextureCache
    ) {
        guard width >= 2, height >= 2, width % 2 == 0, height % 2 == 0 else {
            return nil
        }

        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            resolvedAttributes,
            &pb
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pb else {
            return nil
        }

        var yCVTex: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width,
            height,
            0,
            &yCVTex
        )

        var uvCVTex: CVMetalTexture?
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            width / 2,
            height / 2,
            1,
            &uvCVTex
        )

        guard yStatus == kCVReturnSuccess,
              uvStatus == kCVReturnSuccess,
              let lumaCV = yCVTex,
              let chromaCV = uvCVTex,
              let lumaMTL = CVMetalTextureGetTexture(lumaCV),
              let chromaMTL = CVMetalTextureGetTexture(chromaCV)
        else {
            return nil
        }

        self.width = width
        self.height = height
        self.pixelBuffer = pixelBuffer
        self.lumaCVTexture = lumaCV
        self.chromaCVTexture = chromaCV
        self.lumaTexture = lumaMTL
        self.chromaTexture = chromaMTL
    }
}

/// Shared helper to resolve `CVPixelBuffer` attributes compatible with both Metal and `VTFrameProcessor`.
private func makeResolved420vAttributes(
    vtAttributes: [String: Any]
) -> CFDictionary? {
    let base: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    var resolved: CFDictionary?
    let status = CVPixelBufferCreateResolvedAttributesDictionary(
        kCFAllocatorDefault,
        [base as NSDictionary, vtAttributes as NSDictionary] as CFArray,
        &resolved
    )
    return status == kCVReturnSuccess ? resolved : (base as CFDictionary)
}

/// Dedicated background queue for safely retiring `VTFrameProcessor` sessions after a short delay
/// (avoids a macOS 26/27 VideoToolbox crash when calling `endSession()` immediately after completion).
private let vtRetirementQueue = DispatchQueue(label: "com.metalpie.vt.retirement", qos: .utility)

@available(macOS 26.0, *)
private func retireVTProcessorSafely(_ processor: VTFrameProcessor) {
    final class Box: @unchecked Sendable {
        let proc: VTFrameProcessor
        init(_ proc: VTFrameProcessor) { self.proc = proc }
    }
    let box = Box(processor)
    vtRetirementQueue.asyncAfter(deadline: .now() + 0.3) {
        box.proc.endSession()
    }
}

// MARK: - VideoToolbox ML Low-Latency Super Resolution (`EffectID.vtSuperResolution`)

/// Wraps macOS 26+ `VTLowLatencySuperResolutionScalerConfiguration` (Apple Neural Engine
/// discrete 1.5x / 2.0x / 4.0x ML super-resolution) with pooled NV12 `CVPixelBuffer`s and
/// in-command-buffer BGRA <-> NV12 compute conversion.
public final class VideoToolboxSuperResolution: @unchecked Sendable {
    public let device: any MTLDevice
    private let shaderManager: ShaderLibraryManager

    private struct SRSessionKey: Equatable {
        let inputWidth: Int
        let inputHeight: Int
        let scaleFactor: Float
    }

    private struct State {
        var textureCache: CVMetalTextureCache?
        var sessionKey: SRSessionKey?
        var processorBox: AnyObject?
        var srcBuffer: NV12PixelBufferPair?
        var dstBuffer: NV12PixelBufferPair?
        var frameCount: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init(device: any MTLDevice, shaderManager: ShaderLibraryManager) {
        self.device = device
        self.shaderManager = shaderManager
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        state.withLockUnchecked { $0.textureCache = cache }
    }

    /// True if Apple Silicon VideoToolbox Low-Latency Super Resolution is supported on this Mac/OS.
    public static var isSupportedOnSystem: Bool {
        if #available(macOS 26.0, *) {
            return VTLowLatencySuperResolutionScalerConfiguration.isSupported
        }
        return false
    }

    /// Supported discrete scale factors (e.g. `[1.5, 2.0, 4.0]`) for the given source dimensions.
    public static func supportedScaleFactors(width: Int, height: Int) -> [Float] {
        guard width >= 64, height >= 64, width % 2 == 0, height % 2 == 0 else {
            return []
        }
        if #available(macOS 26.0, *) {
            guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
                return []
            }
            return VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                frameWidth: width,
                frameHeight: height
            )
        }
        return []
    }

    /// Encodes a VideoToolbox ML Super Resolution pass inside `commandBuffer`.
    ///
    /// Returns `true` when executed via Apple Neural Engine, or `false` if the OS version,
    /// dimensions, or requested scale factor are outside ANE limits (caller should fall back to MetalFX/Bicubic).
    public func encode(
        commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        requestedScaleFactor: Float
    ) throws -> Bool {
        if #available(macOS 26.0, *) {
            return try encodeMacOS26(
                commandBuffer: commandBuffer,
                source: source,
                destination: destination,
                requestedScaleFactor: requestedScaleFactor
            )
        }
        return false
    }

    /// Releases active `VTFrameProcessor` session and flushes the `CVMetalTextureCache`.
    public func reset() {
        let retired: AnyObject? = state.withLockUnchecked { s in
            let old = s.processorBox
            s.processorBox = nil
            s.sessionKey = nil
            s.srcBuffer = nil
            s.dstBuffer = nil
            if let cache = s.textureCache {
                CVMetalTextureCacheFlush(cache, 0)
            }
            return old
        }
        if #available(macOS 26.0, *), let proc = retired as? VTFrameProcessor {
            retireVTProcessorSafely(proc)
        }
    }

    deinit {
        reset()
    }

    @available(macOS 26.0, *)
    private func encodeMacOS26(
        commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        requestedScaleFactor: Float
    ) throws -> Bool {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
            return false
        }

        let inW = source.width
        let inH = source.height
        // 420v NV12 requires even source dimensions.
        guard inW >= 64, inH >= 64, inW % 2 == 0, inH % 2 == 0 else {
            return false
        }

        let supportedScales = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
            frameWidth: inW,
            frameHeight: inH
        )
        guard !supportedScales.isEmpty else {
            return false
        }

        // Choose exact requested scale if supported, else closest supported scale.
        let chosenScale = supportedScales.min { abs($0 - requestedScaleFactor) < abs($1 - requestedScaleFactor) } ?? supportedScales[0]
        let outW = Int((Float(inW) * chosenScale).rounded())
        let outH = Int((Float(inH) * chosenScale).rounded())
        guard outW >= 2, outH >= 2, outW % 2 == 0, outH % 2 == 0 else {
            return false
        }

        let key = SRSessionKey(inputWidth: inW, inputHeight: inH, scaleFactor: chosenScale)
        let sessionResult = ensureSessionMacOS26(key: key, outWidth: outW, outHeight: outH)
        guard let (processor, srcNV12, dstNV12) = sessionResult else {
            return false
        }

        // 1. Convert input BGRA/RGBA -> 420v NV12 (Y + CbCr) on GPU.
        let toNV12 = try shaderManager.computePipeline(library: "Common", function: "bgraToNV12", effectHint: .vtSuperResolution)
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "VT_SR_BGRAtoNV12"
            enc.setComputePipelineState(toNV12)
            enc.setTexture(source, index: 0)
            enc.setTexture(srcNV12.lumaTexture, index: 1)
            enc.setTexture(srcNV12.chromaTexture, index: 2)
            dispatch2D(encoder: enc, pipeline: toNV12, width: srcNV12.chromaTexture.width, height: srcNV12.chromaTexture.height)
            enc.endEncoding()
        }

        // 2. Run VideoToolbox Low-Latency ML Super Resolution inside the same MTLCommandBuffer.
        let pts = CMTime(value: Int64(state.withLockUnchecked { s -> UInt64 in s.frameCount &+= 1; return s.frameCount }), timescale: 60)
        guard let srcFrame = VTFrameProcessorFrame(buffer: srcNV12.pixelBuffer, presentationTimeStamp: pts),
              let dstFrame = VTFrameProcessorFrame(buffer: dstNV12.pixelBuffer, presentationTimeStamp: pts)
        else {
            return false
        }
        let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: srcFrame, destinationFrame: dstFrame)
        processor.process(with: commandBuffer, parameters: params)

        // 3. Convert output 420v NV12 -> BGRA/RGBA destination texture on GPU.
        let fromNV12 = try shaderManager.computePipeline(library: "Common", function: "nv12ToBGRA", effectHint: .vtSuperResolution)
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "VT_SR_NV12toBGRA"
            enc.setComputePipelineState(fromNV12)
            enc.setTexture(dstNV12.lumaTexture, index: 0)
            enc.setTexture(dstNV12.chromaTexture, index: 1)
            enc.setTexture(destination, index: 2)
            dispatch2D(encoder: enc, pipeline: fromNV12, width: destination.width, height: destination.height)
            enc.endEncoding()
        }

        // Retain IOSurface-backed NV12 buffers & frames until GPU finishes commandBuffer.
        let retained = RetainedObjects([srcNV12, dstNV12, srcFrame, dstFrame])
        commandBuffer.addCompletedHandler { _ in
            _ = retained
        }
        return true
    }

    @available(macOS 26.0, *)
    private func ensureSessionMacOS26(
        key: SRSessionKey,
        outWidth: Int,
        outHeight: Int
    ) -> (VTFrameProcessor, NV12PixelBufferPair, NV12PixelBufferPair)? {
        let cached: (VTFrameProcessor, NV12PixelBufferPair, NV12PixelBufferPair)? = state.withLockUnchecked { s in
            guard s.sessionKey == key,
                  let proc = s.processorBox as? VTFrameProcessor,
                  let src = s.srcBuffer,
                  let dst = s.dstBuffer
            else {
                return nil
            }
            return (proc, src, dst)
        }
        if let cached {
            return cached
        }

        let config = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: key.inputWidth,
            frameHeight: key.inputHeight,
            scaleFactor: key.scaleFactor
        )
        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: config)
        } catch {
            PipelineLog.shared.warning(
                .shader,
                "VT Super Resolution startSession failed for \(key.inputWidth)x\(key.inputHeight) @\(key.scaleFactor)x: \(error.localizedDescription)"
            )
            return nil
        }

        let textureCache: CVMetalTextureCache? = state.withLockUnchecked { s in
            if s.textureCache == nil {
                var c: CVMetalTextureCache?
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c)
                s.textureCache = c
            }
            return s.textureCache
        }
        guard let cache = textureCache else {
            retireVTProcessorSafely(processor)
            return nil
        }

        let srcAttrs = makeResolved420vAttributes(vtAttributes: config.sourcePixelBufferAttributes)
        let dstAttrs = makeResolved420vAttributes(vtAttributes: config.destinationPixelBufferAttributes)
        guard let srcNV12 = NV12PixelBufferPair(width: key.inputWidth, height: key.inputHeight, resolvedAttributes: srcAttrs, textureCache: cache),
              let dstNV12 = NV12PixelBufferPair(width: outWidth, height: outHeight, resolvedAttributes: dstAttrs, textureCache: cache)
        else {
            retireVTProcessorSafely(processor)
            return nil
        }

        let oldProc: AnyObject? = state.withLockUnchecked { s in
            let prev = s.processorBox
            s.sessionKey = key
            s.processorBox = processor
            s.srcBuffer = srcNV12
            s.dstBuffer = dstNV12
            return prev
        }
        if let prevProc = oldProc as? VTFrameProcessor {
            retireVTProcessorSafely(prevProc)
        }

        PipelineLog.shared.info(.shader, "Started VT Low-Latency SR session \(key.inputWidth)x\(key.inputHeight) -> \(outWidth)x\(outHeight) (\(key.scaleFactor)x)")
        return (processor, srcNV12, dstNV12)
    }
}

// MARK: - Metal Optical Flow Fallback Interpolator (`FrameInterpolating`)

/// Zero-allocation GPU hierarchical block-matching optical flow interpolator with
/// forward-backward occlusion consistency and scene-cut Artifact Guard.
public final class MetalOpticalFlowInterpolator: FrameInterpolating, @unchecked Sendable {
    public let device: any MTLDevice
    private let shaderManager: ShaderLibraryManager
    private let texturePool: TexturePool
    private let sceneDiffBuffer: (any MTLBuffer)?
    private let sceneDiffLock = OSAllocatedUnfairLock()

    public var backendName: String { "Metal Optical Flow" }
    public var isSupported: Bool { true }

    public init(
        device: any MTLDevice,
        shaderManager: ShaderLibraryManager,
        texturePool: TexturePool
    ) {
        self.device = device
        self.shaderManager = shaderManager
        self.texturePool = texturePool
        self.sceneDiffBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
    }

    public func prepare(width: Int, height: Int, settings: FrameGenSettings) throws {
        // Pre-compile all optical-flow compute pipelines ahead of first interpolated frame.
        _ = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_luma_from_rgba")
        _ = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_luma_downsample")
        _ = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_scene_diff")
        _ = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_block_match_coarse")
        _ = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_block_match_refine")
        _ = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_median_filter")
        _ = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_bidirectional_warp")
    }

    public func encode(request: FrameGenRequest) throws -> Bool {
        let w = request.outputTexture.width
        let h = request.outputTexture.height
        let halfW = max(1, (w + 1) / 2)
        let halfH = max(1, (h + 1) / 2)
        let qtrW = max(1, (halfW + 1) / 2)
        let qtrH = max(1, (halfH + 1) / 2)

        let pLumaFromRGBA = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_luma_from_rgba")
        let pLumaDown = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_luma_downsample")
        let pCoarse = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_block_match_coarse")
        let pRefine = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_block_match_refine")
        let pMedian = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_median_filter")
        let pWarp = try shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_bidirectional_warp")

        var leases: [PooledTexture] = []
        leases.reserveCapacity(10)
        defer {
            texturePool.recycleOnCompletion(leases, of: request.commandBuffer)
        }

        let rwUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        let prevL2 = try texturePool.acquire(width: halfW, height: halfH, pixelFormat: .r16Float, usage: rwUsage, storageMode: .private)
        let currL2 = try texturePool.acquire(width: halfW, height: halfH, pixelFormat: .r16Float, usage: rwUsage, storageMode: .private)
        let prevL4 = try texturePool.acquire(width: qtrW, height: qtrH, pixelFormat: .r16Float, usage: rwUsage, storageMode: .private)
        let currL4 = try texturePool.acquire(width: qtrW, height: qtrH, pixelFormat: .r16Float, usage: rwUsage, storageMode: .private)
        let fwdCoarse = try texturePool.acquire(width: qtrW, height: qtrH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
        let bwdCoarse = try texturePool.acquire(width: qtrW, height: qtrH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
        let fwdRefine = try texturePool.acquire(width: halfW, height: halfH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
        let bwdRefine = try texturePool.acquire(width: halfW, height: halfH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
        let fwdClean = try texturePool.acquire(width: halfW, height: halfH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
        let bwdClean = try texturePool.acquire(width: halfW, height: halfH, pixelFormat: .rg16Float, usage: rwUsage, storageMode: .private)
        leases.append(contentsOf: [prevL2, currL2, prevL4, currL4, fwdCoarse, bwdCoarse, fwdRefine, bwdRefine, fwdClean, bwdClean])

        // Optional fast scene-cut pre-check when Artifact Guard is enabled.
        var sceneDiffScore: Float = 0.0
        if request.settings.artifactGuardSensitivity != .off {
            sceneDiffScore = measureSceneDiff(
                prev: request.previousTexture,
                curr: request.currentTexture,
                queue: request.commandBuffer.commandQueue,
                halfW: halfW,
                halfH: halfH,
                qtrW: qtrW,
                qtrH: qtrH
            )
            let cutThreshold: Float = (request.settings.artifactGuardSensitivity == .strong) ? 0.24 : 0.36
            if sceneDiffScore >= cutThreshold {
                // Hard scene cut detected by Artifact Guard -> fall back cleanly to nearer real frame.
                let sourceToCopy = request.interpolationFactor < 0.5 ? request.previousTexture : request.currentTexture
                if let blit = request.commandBuffer.makeBlitCommandEncoder() {
                    blit.label = "OpticalFlow_SceneCutFallback"
                    blit.copy(
                        from: sourceToCopy,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: min(sourceToCopy.width, w), height: min(sourceToCopy.height, h), depth: 1),
                        to: request.outputTexture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                    blit.endEncoding()
                }
                return false
            }
        }

        let cb = request.commandBuffer

        // 1. Build 1/2-res and 1/4-res luma pyramids for prev & curr.
        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "OF_LumaPyramid"
            enc.setComputePipelineState(pLumaFromRGBA)
            enc.setTexture(request.previousTexture, index: 0)
            enc.setTexture(prevL2.texture, index: 1)
            dispatch2D(encoder: enc, pipeline: pLumaFromRGBA, width: halfW, height: halfH)

            enc.setTexture(request.currentTexture, index: 0)
            enc.setTexture(currL2.texture, index: 1)
            dispatch2D(encoder: enc, pipeline: pLumaFromRGBA, width: halfW, height: halfH)

            enc.setComputePipelineState(pLumaDown)
            enc.setTexture(prevL2.texture, index: 0)
            enc.setTexture(prevL4.texture, index: 1)
            dispatch2D(encoder: enc, pipeline: pLumaDown, width: qtrW, height: qtrH)

            enc.setTexture(currL2.texture, index: 0)
            enc.setTexture(currL4.texture, index: 1)
            dispatch2D(encoder: enc, pipeline: pLumaDown, width: qtrW, height: qtrH)
            enc.endEncoding()
        }

        // 2. Coarse forward & backward block matching at 1/4-res.
        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "OF_CoarseMatch"
            enc.setComputePipelineState(pCoarse)
            enc.setTexture(prevL4.texture, index: 0)
            enc.setTexture(currL4.texture, index: 1)
            enc.setTexture(fwdCoarse.texture, index: 2)
            dispatch2D(encoder: enc, pipeline: pCoarse, width: qtrW, height: qtrH)

            enc.setTexture(currL4.texture, index: 0)
            enc.setTexture(prevL4.texture, index: 1)
            enc.setTexture(bwdCoarse.texture, index: 2)
            dispatch2D(encoder: enc, pipeline: pCoarse, width: qtrW, height: qtrH)
            enc.endEncoding()
        }

        // 3. 1/2-res sub-pixel refinement + 3x3 median despeckle.
        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "OF_RefineAndMedian"
            enc.setComputePipelineState(pRefine)
            enc.setTexture(prevL2.texture, index: 0)
            enc.setTexture(currL2.texture, index: 1)
            enc.setTexture(fwdCoarse.texture, index: 2)
            enc.setTexture(fwdRefine.texture, index: 3)
            dispatch2D(encoder: enc, pipeline: pRefine, width: halfW, height: halfH)

            enc.setTexture(currL2.texture, index: 0)
            enc.setTexture(prevL2.texture, index: 1)
            enc.setTexture(bwdCoarse.texture, index: 2)
            enc.setTexture(bwdRefine.texture, index: 3)
            dispatch2D(encoder: enc, pipeline: pRefine, width: halfW, height: halfH)

            enc.setComputePipelineState(pMedian)
            enc.setTexture(fwdRefine.texture, index: 0)
            enc.setTexture(fwdClean.texture, index: 1)
            dispatch2D(encoder: enc, pipeline: pMedian, width: halfW, height: halfH)

            enc.setTexture(bwdRefine.texture, index: 0)
            enc.setTexture(bwdClean.texture, index: 1)
            dispatch2D(encoder: enc, pipeline: pMedian, width: halfW, height: halfH)
            enc.endEncoding()
        }

        // 4. Bidirectional motion-compensated warp + Artifact Guard.
        struct OpticalFlowWarpUniforms {
            var interpolationFactor: Float
            var artifactGuardLevel: UInt32
            var sceneDiffScore: Float
            var _pad0: UInt32 = 0
        }

        let guardLevel: UInt32
        switch request.settings.artifactGuardSensitivity {
        case .off: guardLevel = 0
        case .balanced: guardLevel = 1
        case .strong: guardLevel = 2
        }

        var uniforms = OpticalFlowWarpUniforms(
            interpolationFactor: request.interpolationFactor,
            artifactGuardLevel: guardLevel,
            sceneDiffScore: sceneDiffScore
        )

        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "OF_BidirectionalWarp"
            enc.setComputePipelineState(pWarp)
            enc.setTexture(request.previousTexture, index: 0)
            enc.setTexture(request.currentTexture, index: 1)
            enc.setTexture(fwdClean.texture, index: 2)
            enc.setTexture(bwdClean.texture, index: 3)
            enc.setTexture(request.outputTexture, index: 4)
            enc.setBytes(&uniforms, length: MemoryLayout<OpticalFlowWarpUniforms>.stride, index: 0)
            dispatch2D(encoder: enc, pipeline: pWarp, width: w, height: h)
            enc.endEncoding()
        }

        return true
    }

    public func reset() {
        // All intermediate textures live in `texturePool`; nothing persistent to leak.
    }

    /// Computes normalized global luma difference in `[0, 1]` on the GPU for scene-cut detection.
    ///
    /// Executes on `queue` (the caller's `request.commandBuffer.commandQueue`) so Metal FIFO ordering
    /// guarantees prior committed writes to `prev`/`curr` complete before reading (zero cross-queue race!).
    internal func measureSceneDiff(
        prev: any MTLTexture,
        curr: any MTLTexture,
        queue: any MTLCommandQueue,
        halfW: Int,
        halfH: Int,
        qtrW: Int,
        qtrH: Int
    ) -> Float {
        sceneDiffLock.withLockUnchecked {
            guard let diffBuf = sceneDiffBuffer,
                  let cb = queue.makeCommandBuffer(),
                  let pLuma = try? shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_luma_from_rgba"),
                  let pDown = try? shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_luma_downsample"),
                  let pDiff = try? shaderManager.computePipeline(library: "OpticalFlowFallback", function: "of_scene_diff")
            else {
                return 0.0
            }

            let rwUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
            guard let pL2 = try? texturePool.acquire(width: halfW, height: halfH, pixelFormat: .r16Float, usage: rwUsage, storageMode: .private),
                  let cL2 = try? texturePool.acquire(width: halfW, height: halfH, pixelFormat: .r16Float, usage: rwUsage, storageMode: .private),
                  let pL4 = try? texturePool.acquire(width: qtrW, height: qtrH, pixelFormat: .r16Float, usage: rwUsage, storageMode: .private),
                  let cL4 = try? texturePool.acquire(width: qtrW, height: qtrH, pixelFormat: .r16Float, usage: rwUsage, storageMode: .private)
            else {
                return 0.0
            }
            defer {
                pL2.releaseNow()
                cL2.releaseNow()
                pL4.releaseNow()
                cL4.releaseNow()
            }

            diffBuf.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            cb.label = "MetalPie_SceneDiffCheck"

            if let enc = cb.makeComputeCommandEncoder() {
                enc.setComputePipelineState(pLuma)
                enc.setTexture(prev, index: 0)
                enc.setTexture(pL2.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: pLuma, width: halfW, height: halfH)

                enc.setTexture(curr, index: 0)
                enc.setTexture(cL2.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: pLuma, width: halfW, height: halfH)

                enc.setComputePipelineState(pDown)
                enc.setTexture(pL2.texture, index: 0)
                enc.setTexture(pL4.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: pDown, width: qtrW, height: qtrH)

                enc.setTexture(cL2.texture, index: 0)
                enc.setTexture(cL4.texture, index: 1)
                dispatch2D(encoder: enc, pipeline: pDown, width: qtrW, height: qtrH)

                enc.setComputePipelineState(pDiff)
                enc.setTexture(pL4.texture, index: 0)
                enc.setTexture(cL4.texture, index: 1)
                enc.setBuffer(diffBuf, offset: 0, index: 0)
                let sampleW = max(1, (qtrW + 1) / 2)
                let sampleH = max(1, (qtrH + 1) / 2)
                dispatch2D(encoder: enc, pipeline: pDiff, width: sampleW, height: sampleH)
                enc.endEncoding()
            }

            cb.commit()
            cb.waitUntilCompleted()

            let sumFixed = diffBuf.contents().load(as: UInt32.self)
            let sampleCount = max(1, ((qtrW + 1) / 2) * ((qtrH + 1) / 2))
            return Float(sumFixed) / (Float(sampleCount) * 255.0)
        }
    }
}

// MARK: - Unified VideoToolbox ML + Optical Flow Frame Interpolator (`FrameInterpolating`)

/// Primary MetalPie Frame Generation engine conforming to `FrameInterpolating`.
///
/// Uses Apple's macOS 26+ `VTLowLatencyFrameInterpolationConfiguration` (Neural Engine ML 2x/4x
/// frame generation up to 1920x1080) with automatic, seamless fallback to `MetalOpticalFlowInterpolator`
/// on macOS 14–15, >1080p frames, odd dimensions, or when `.metalOpticalFlow` is explicitly requested.
public final class VideoToolboxMLProcessor: FrameInterpolating, @unchecked Sendable {
    public let device: any MTLDevice
    public let superResolution: VideoToolboxSuperResolution
    public let opticalFlowFallback: MetalOpticalFlowInterpolator
    private let shaderManager: ShaderLibraryManager

    private struct FISessionKey: Equatable {
        let width: Int
        let height: Int
        let numInterpolatedFrames: Int
    }

    private struct State {
        var textureCache: CVMetalTextureCache?
        var sessionKey: FISessionKey?
        var processorBox: AnyObject?
        var prevBuffer: NV12PixelBufferPair?
        var currBuffer: NV12PixelBufferPair?
        var outBuffer: NV12PixelBufferPair?
        var lastUsedVT: Bool = false
        var frameSequence: Int64 = 1
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init(
        device: any MTLDevice,
        shaderManager: ShaderLibraryManager,
        texturePool: TexturePool
    ) {
        self.device = device
        self.shaderManager = shaderManager
        self.superResolution = VideoToolboxSuperResolution(device: device, shaderManager: shaderManager)
        self.opticalFlowFallback = MetalOpticalFlowInterpolator(
            device: device,
            shaderManager: shaderManager,
            texturePool: texturePool
        )
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        state.withLockUnchecked { $0.textureCache = cache }
    }

    /// True if Apple Silicon VideoToolbox Low-Latency Frame Interpolation is supported on this Mac/OS.
    public static var isFrameInterpolationSupportedOnSystem: Bool {
        if #available(macOS 26.0, *) {
            return VTLowLatencyFrameInterpolationConfiguration.isSupported
        }
        return false
    }

    public var backendName: String {
        if state.withLockUnchecked({ $0.lastUsedVT }) || Self.isFrameInterpolationSupportedOnSystem {
            return "VideoToolbox ML (ANE)"
        }
        return opticalFlowFallback.backendName
    }

    public var isSupported: Bool {
        true
    }

    /// Returns true if `(width, height)` is eligible for macOS 26+ `VTLowLatencyFrameInterpolation`.
    public static func supportsVideoToolboxML(width: Int, height: Int, backend: FrameGenBackend) -> Bool {
        guard backend != .metalOpticalFlow else { return false }
        guard isFrameInterpolationSupportedOnSystem else { return false }
        guard width >= 64, height >= 64, width % 2 == 0, height % 2 == 0 else { return false }
        guard width <= 1920, height <= 1080, width * height <= 2_073_600 else { return false }
        return true
    }

    public func prepare(width: Int, height: Int, settings: FrameGenSettings) throws {
        try opticalFlowFallback.prepare(width: width, height: height, settings: settings)
        _ = try shaderManager.computePipeline(library: "Common", function: "bgraToNV12")
        _ = try shaderManager.computePipeline(library: "Common", function: "nv12ToBGRA")

        if #available(macOS 26.0, *),
           Self.supportsVideoToolboxML(width: width, height: height, backend: settings.backend)
        {
            let numFrames = (settings.multiplier == .x2) ? 1 : 2
            let key = FISessionKey(width: width, height: height, numInterpolatedFrames: numFrames)
            _ = ensureFISessionMacOS26(key: key)
        }
    }

    public func encode(request: FrameGenRequest) throws -> Bool {
        let w = request.outputTexture.width
        let h = request.outputTexture.height

        if #available(macOS 26.0, *),
           Self.supportsVideoToolboxML(width: w, height: h, backend: request.settings.backend),
           request.previousTexture.width == w,
           request.previousTexture.height == h,
           request.currentTexture.width == w,
           request.currentTexture.height == h
        {
            if let synthesized = try encodeVTFrameGenMacOS26(request: request) {
                state.withLockUnchecked { $0.lastUsedVT = true }
                return synthesized
            }
        }

        state.withLockUnchecked { $0.lastUsedVT = false }
        return try opticalFlowFallback.encode(request: request)
    }

    public func reset() {
        superResolution.reset()
        opticalFlowFallback.reset()
        let retired: AnyObject? = state.withLockUnchecked { s in
            let old = s.processorBox
            s.processorBox = nil
            s.sessionKey = nil
            s.prevBuffer = nil
            s.currBuffer = nil
            s.outBuffer = nil
            s.lastUsedVT = false
            if let cache = s.textureCache {
                CVMetalTextureCacheFlush(cache, 0)
            }
            return old
        }
        if #available(macOS 26.0, *), let proc = retired as? VTFrameProcessor {
            retireVTProcessorSafely(proc)
        }
    }

    deinit {
        reset()
    }

    @available(macOS 26.0, *)
    private func encodeVTFrameGenMacOS26(request: FrameGenRequest) throws -> Bool? {
        let w = request.outputTexture.width
        let h = request.outputTexture.height

        // Artifact Guard scene-cut pre-check so hard cuts fall back cleanly to nearer real frame.
        if request.settings.artifactGuardSensitivity != .off {
            let halfW = max(1, (w + 1) / 2)
            let halfH = max(1, (h + 1) / 2)
            let qtrW = max(1, (halfW + 1) / 2)
            let qtrH = max(1, (halfH + 1) / 2)
            let diffScore = opticalFlowFallback.measureSceneDiff(
                prev: request.previousTexture,
                curr: request.currentTexture,
                queue: request.commandBuffer.commandQueue,
                halfW: halfW,
                halfH: halfH,
                qtrW: qtrW,
                qtrH: qtrH
            )
            let cutThreshold: Float = (request.settings.artifactGuardSensitivity == .strong) ? 0.24 : 0.36
            if diffScore >= cutThreshold {
                let nearer = request.interpolationFactor < 0.5 ? request.previousTexture : request.currentTexture
                if let blit = request.commandBuffer.makeBlitCommandEncoder() {
                    blit.label = "VT_FI_SceneCutFallback"
                    blit.copy(
                        from: nearer,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: w, height: h, depth: 1),
                        to: request.outputTexture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                    blit.endEncoding()
                }
                return false
            }
        }

        // Snap interpolation phase to valid VideoToolbox ANE grid points:
        // numInterpolatedFrames=1 -> [0.5]; numInterpolatedFrames=2 -> [0.25, 0.5, 0.75].
        let numFrames = (request.settings.multiplier == .x2) ? 1 : 2
        let validPhases: [Float] = (numFrames == 1) ? [0.5] : [0.25, 0.5, 0.75]
        let phase = validPhases.min { abs($0 - request.interpolationFactor) < abs($1 - request.interpolationFactor) } ?? 0.5

        let key = FISessionKey(width: w, height: h, numInterpolatedFrames: numFrames)
        guard let (processor, prevNV12, currNV12, outNV12) = ensureFISessionMacOS26(key: key) else {
            return nil
        }

        let toNV12 = try shaderManager.computePipeline(library: "Common", function: "bgraToNV12")
        let fromNV12 = try shaderManager.computePipeline(library: "Common", function: "nv12ToBGRA")
        let cb = request.commandBuffer

        // 1. Convert previous and current BGRA frames to 420v NV12 on GPU.
        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "VT_FI_BGRAtoNV12"
            enc.setComputePipelineState(toNV12)

            enc.setTexture(request.previousTexture, index: 0)
            enc.setTexture(prevNV12.lumaTexture, index: 1)
            enc.setTexture(prevNV12.chromaTexture, index: 2)
            dispatch2D(encoder: enc, pipeline: toNV12, width: prevNV12.chromaTexture.width, height: prevNV12.chromaTexture.height)

            enc.setTexture(request.currentTexture, index: 0)
            enc.setTexture(currNV12.lumaTexture, index: 1)
            enc.setTexture(currNV12.chromaTexture, index: 2)
            dispatch2D(encoder: enc, pipeline: toNV12, width: currNV12.chromaTexture.width, height: currNV12.chromaTexture.height)
            enc.endEncoding()
        }

        // 2. Encode VideoToolbox Low-Latency ML Frame Interpolation inside `cb`.
        let seq = state.withLockUnchecked { s -> Int64 in
            s.frameSequence &+= 1
            return s.frameSequence
        }
        let prevPTS = CMTime(value: seq * 1000, timescale: 60_000)
        let currPTS = CMTime(value: (seq + 1) * 1000, timescale: 60_000)
        let outPTS = CMTime(value: seq * 1000 + Int64((Double(phase) * 1000.0).rounded()), timescale: 60_000)

        guard let prevFrame = VTFrameProcessorFrame(buffer: prevNV12.pixelBuffer, presentationTimeStamp: prevPTS),
              let currFrame = VTFrameProcessorFrame(buffer: currNV12.pixelBuffer, presentationTimeStamp: currPTS),
              let outFrame = VTFrameProcessorFrame(buffer: outNV12.pixelBuffer, presentationTimeStamp: outPTS),
              let params = VTLowLatencyFrameInterpolationParameters(
                  sourceFrame: currFrame,
                  previousFrame: prevFrame,
                  interpolationPhase: [phase],
                  destinationFrames: [outFrame]
              )
        else {
            return nil
        }

        processor.process(with: cb, parameters: params)

        // 3. Convert interpolated NV12 back to BGRA/RGBA output texture.
        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "VT_FI_NV12toBGRA"
            enc.setComputePipelineState(fromNV12)
            enc.setTexture(outNV12.lumaTexture, index: 0)
            enc.setTexture(outNV12.chromaTexture, index: 1)
            enc.setTexture(request.outputTexture, index: 2)
            dispatch2D(encoder: enc, pipeline: fromNV12, width: w, height: h)
            enc.endEncoding()
        }

        let retained = RetainedObjects([prevNV12, currNV12, outNV12, prevFrame, currFrame, outFrame])
        cb.addCompletedHandler { _ in
            _ = retained
        }
        return true
    }

    @available(macOS 26.0, *)
    private func ensureFISessionMacOS26(
        key: FISessionKey
    ) -> (VTFrameProcessor, NV12PixelBufferPair, NV12PixelBufferPair, NV12PixelBufferPair)? {
        let cached: (VTFrameProcessor, NV12PixelBufferPair, NV12PixelBufferPair, NV12PixelBufferPair)? = state.withLockUnchecked { s in
            guard s.sessionKey == key,
                  let proc = s.processorBox as? VTFrameProcessor,
                  let prev = s.prevBuffer,
                  let curr = s.currBuffer,
                  let out = s.outBuffer
            else {
                return nil
            }
            return (proc, prev, curr, out)
        }
        if let cached {
            return cached
        }

        guard let config = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: key.width,
            frameHeight: key.height,
            numberOfInterpolatedFrames: key.numInterpolatedFrames
        ) else {
            return nil
        }

        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: config)
        } catch {
            PipelineLog.shared.warning(
                .shader,
                "VT Frame Interpolation startSession failed for \(key.width)x\(key.height): \(error.localizedDescription)"
            )
            return nil
        }

        let textureCache: CVMetalTextureCache? = state.withLockUnchecked { s in
            if s.textureCache == nil {
                var c: CVMetalTextureCache?
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c)
                s.textureCache = c
            }
            return s.textureCache
        }
        guard let cache = textureCache else {
            retireVTProcessorSafely(processor)
            return nil
        }

        let srcAttrs = makeResolved420vAttributes(vtAttributes: config.sourcePixelBufferAttributes)
        let dstAttrs = makeResolved420vAttributes(vtAttributes: config.destinationPixelBufferAttributes)

        guard let prevNV12 = NV12PixelBufferPair(width: key.width, height: key.height, resolvedAttributes: srcAttrs, textureCache: cache),
              let currNV12 = NV12PixelBufferPair(width: key.width, height: key.height, resolvedAttributes: srcAttrs, textureCache: cache),
              let outNV12 = NV12PixelBufferPair(width: key.width, height: key.height, resolvedAttributes: dstAttrs, textureCache: cache)
        else {
            retireVTProcessorSafely(processor)
            return nil
        }

        let oldProc: AnyObject? = state.withLockUnchecked { s in
            let prev = s.processorBox
            s.sessionKey = key
            s.processorBox = processor
            s.prevBuffer = prevNV12
            s.currBuffer = currNV12
            s.outBuffer = outNV12
            return prev
        }
        if let prevProc = oldProc as? VTFrameProcessor {
            retireVTProcessorSafely(prevProc)
        }

        PipelineLog.shared.info(.shader, "Started VT Low-Latency Frame Interpolation session \(key.width)x\(key.height) (numFrames=\(key.numInterpolatedFrames))")
        return (processor, prevNV12, currNV12, outNV12)
    }
}

// MARK: - Internal Dispatch & Lifetime Helpers

private final class RetainedObjects: @unchecked Sendable {
    let objects: [AnyObject]
    init(_ objects: [AnyObject]) { self.objects = objects }
}

internal func dispatch2D(
    encoder: any MTLComputeCommandEncoder,
    pipeline: any MTLComputePipelineState,
    width: Int,
    height: Int
) {
    let w = max(1, width)
    let h = max(1, height)
    let tgW = min(16, max(1, pipeline.threadExecutionWidth))
    let tgH = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / tgW))
    let threadgroupSize = MTLSize(width: tgW, height: tgH, depth: 1)
    let gridSize = MTLSize(width: w, height: h, depth: 1)
    encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
}
