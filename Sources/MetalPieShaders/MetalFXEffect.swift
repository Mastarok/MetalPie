import Foundation
import Metal
import MetalFX
import MetalPieCore
import os

/// Caches and encodes Apple Silicon hardware-accelerated `MTLFXSpatialScaler` instances,
/// supporting both SDR (`.perceptual` / `.linear`) and HDR (`.hdr` with `.rgba16Float`)
/// with automatic `.private` staging via `TexturePool` when caller textures lack MetalFX usage flags.
public final class MetalFXEffect: @unchecked Sendable {
    public let device: any MTLDevice
    public let maxCachedScalers: Int

    private struct ScalerKey: Hashable {
        let inputWidth: Int
        let inputHeight: Int
        let outputWidth: Int
        let outputHeight: Int
        let colorFormatRaw: UInt
        let outputFormatRaw: UInt
        let colorProcessingModeRaw: Int
    }

    private final class LockedScaler: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock()
        let scaler: any MTLFXSpatialScaler

        init(_ scaler: any MTLFXSpatialScaler) {
            self.scaler = scaler
        }
    }

    private struct CacheEntry {
        var lockedScaler: LockedScaler
        var lastUsedSequence: UInt64
    }

    private struct State {
        var scalers: [ScalerKey: CacheEntry] = [:]
        var sequence: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init(device: any MTLDevice, maxCachedScalers: Int = 16) {
        self.device = device
        self.maxCachedScalers = max(4, maxCachedScalers)
    }

    /// True when the active GPU supports `MTLFXSpatialScaler`.
    public var isSupported: Bool {
        MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    /// Resolves `MTLFXSpatialScalerColorProcessingMode` from an `EffectInstance`'s parameters and HDR flag.
    public static func resolveColorProcessingMode(
        parameters: EffectParameters,
        isHDR: Bool,
        pixelFormat: MTLPixelFormat
    ) -> MTLFXSpatialScalerColorProcessingMode {
        let choice = parameters.choice("colorProcessingMode", default: isHDR ? "hdr" : "perceptual")
        switch choice {
        case "hdr":
            return .hdr
        case "linear":
            return .linear
        case "perceptual":
            return (isHDR && pixelFormat == .rgba16Float) ? .hdr : .perceptual
        default:
            return isHDR ? .hdr : .perceptual
        }
    }

    /// Checks whether `MTLFXSpatialScaler` supports scaling directly from `(inputWidth, inputHeight)`
    /// to `(outputWidth, outputHeight)` (MetalFX Spatial is an upscaler: `out >= in`, up to 3x per axis).
    public func canScaleDirectly(
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> Bool {
        guard isSupported,
              inputWidth >= 16, inputHeight >= 16,
              outputWidth >= inputWidth, outputHeight >= inputHeight
        else {
            return false
        }
        // MetalFX Spatial supports up to ~3x per axis; larger factors need chaining or fallback.
        let scaleX = Double(outputWidth) / Double(inputWidth)
        let scaleY = Double(outputHeight) / Double(inputHeight)
        return scaleX <= 3.001 && scaleY <= 3.001
    }

    /// Prewarms and caches a `MTLFXSpatialScaler` for the specified dimensions, format, and color mode.
    public func prewarm(
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        colorFormat: MTLPixelFormat,
        outputFormat: MTLPixelFormat? = nil,
        colorProcessingMode: MTLFXSpatialScalerColorProcessingMode
    ) throws {
        _ = try acquireScaler(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            colorFormat: colorFormat,
            outputFormat: outputFormat ?? colorFormat,
            colorProcessingMode: colorProcessingMode
        )
    }

    /// Encodes a MetalFX Spatial scaling pass into `commandBuffer`.
    ///
    /// Automatically stages `source` or `destination` through `.private` pooled textures when
    /// required by MetalFX's `colorTextureUsage`, `outputTextureUsage`, or `.private` storage rules.
    /// Returns `true` if encoded via MetalFX Spatial, or `false` if dimensions require fallback (e.g. downscale).
    @discardableResult
    public func encode(
        commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        colorProcessingMode: MTLFXSpatialScalerColorProcessingMode,
        texturePool: TexturePool
    ) throws -> Bool {
        let inW = source.width
        let inH = source.height
        let outW = destination.width
        let outH = destination.height

        guard canScaleDirectly(inputWidth: inW, inputHeight: inH, outputWidth: outW, outputHeight: outH) else {
            return false
        }

        // Normalize unsupported storage/pixel formats (e.g. sRGB views) into MetalFX-compatible formats.
        let effectiveColorFmt = normalizedMetalFXFormat(source.pixelFormat, mode: colorProcessingMode)
        let effectiveOutputFmt = normalizedMetalFXFormat(destination.pixelFormat, mode: colorProcessingMode)

        let lockedScaler: LockedScaler
        do {
            lockedScaler = try acquireScaler(
                inputWidth: inW,
                inputHeight: inH,
                outputWidth: outW,
                outputHeight: outH,
                colorFormat: effectiveColorFmt,
                outputFormat: effectiveOutputFmt,
                colorProcessingMode: colorProcessingMode
            )
        } catch {
            PipelineLog.shared.warning(.shader, "MetalFX scaler unavailable for \(inW)x\(inH)->\(outW)x\(outH): \(error.localizedDescription)")
            return false
        }
        let scaler = lockedScaler.scaler

        var stagingLeases: [PooledTexture] = []
        defer {
            if !stagingLeases.isEmpty {
                texturePool.recycleOnCompletion(stagingLeases, of: commandBuffer)
            }
        }

        // Prepare input texture (must satisfy scaler.colorTextureUsage and matching format).
        let inputTex: any MTLTexture
        let inputCompatible = source.pixelFormat == effectiveColorFmt
            && source.usage.contains(scaler.colorTextureUsage)
        if inputCompatible {
            inputTex = source
        } else {
            let usage = scaler.colorTextureUsage.union([.shaderRead])
            let staged = try texturePool.acquire(
                width: inW,
                height: inH,
                pixelFormat: effectiveColorFmt,
                usage: usage,
                storageMode: .private,
                label: "MetalFX_InputStage"
            )
            stagingLeases.append(staged)
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "MetalFX_StageInput"
                blit.copy(
                    from: source,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: inW, height: inH, depth: 1),
                    to: staged.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
            }
            inputTex = staged.texture
        }

        // Prepare output texture (MetalFX requires .private storage + scaler.outputTextureUsage).
        let outputTex: any MTLTexture
        let needsOutputCopyBack: Bool
        let outputCompatible = destination.pixelFormat == effectiveOutputFmt
            && destination.storageMode == .private
            && destination.usage.contains(scaler.outputTextureUsage)
        if outputCompatible {
            outputTex = destination
            needsOutputCopyBack = false
        } else {
            let usage = scaler.outputTextureUsage.union([.shaderRead, .renderTarget])
            let staged = try texturePool.acquire(
                width: outW,
                height: outH,
                pixelFormat: effectiveOutputFmt,
                usage: usage,
                storageMode: .private,
                label: "MetalFX_OutputStage"
            )
            stagingLeases.append(staged)
            outputTex = staged.texture
            needsOutputCopyBack = true
        }

        // Encode MetalFX Spatial pass under per-scaler lock so concurrent preview/live calls
        // sharing the same cached scaler never race on colorTexture/outputTexture properties.
        lockedScaler.lock.withLockUnchecked {
            scaler.colorTexture = inputTex
            scaler.outputTexture = outputTex
            scaler.inputContentWidth = inW
            scaler.inputContentHeight = inH
            scaler.encode(commandBuffer: commandBuffer)
        }

        if needsOutputCopyBack, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "MetalFX_CopyOutput"
            blit.copy(
                from: outputTex,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: outW, height: outH, depth: 1),
                to: destination,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        return true
    }

    /// Number of currently cached `MTLFXSpatialScaler` configurations.
    public var cachedScalerCount: Int {
        state.withLockUnchecked { $0.scalers.count }
    }

    /// Releases all cached `MTLFXSpatialScaler` instances.
    public func reset() {
        state.withLockUnchecked { s in
            s.scalers.removeAll()
        }
    }

    private func normalizedMetalFXFormat(
        _ format: MTLPixelFormat,
        mode: MTLFXSpatialScalerColorProcessingMode
    ) -> MTLPixelFormat {
        switch format {
        case .bgra8Unorm, .rgba8Unorm, .bgr10a2Unorm, .rgba16Float:
            return format
        case .bgra8Unorm_srgb:
            return .bgra8Unorm
        case .rgba8Unorm_srgb:
            return .rgba8Unorm
        default:
            return mode == .hdr ? .rgba16Float : .bgra8Unorm
        }
    }

    private func acquireScaler(
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        colorFormat: MTLPixelFormat,
        outputFormat: MTLPixelFormat,
        colorProcessingMode: MTLFXSpatialScalerColorProcessingMode
    ) throws -> LockedScaler {
        guard isSupported else {
            throw EngineError.shaderCompilationFailed(
                effectID: .metalFXSpatial,
                detail: "MTLFXSpatialScaler is not supported on \(device.name)."
            )
        }

        let key = ScalerKey(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            colorFormatRaw: colorFormat.rawValue,
            outputFormatRaw: outputFormat.rawValue,
            colorProcessingModeRaw: colorProcessingMode.rawValue
        )

        if let existing = state.withLockUnchecked({ s -> LockedScaler? in
            guard var entry = s.scalers[key] else { return nil }
            s.sequence &+= 1
            entry.lastUsedSequence = s.sequence
            s.scalers[key] = entry
            return entry.lockedScaler
        }) {
            return existing
        }

        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = inputWidth
        desc.inputHeight = inputHeight
        desc.outputWidth = outputWidth
        desc.outputHeight = outputHeight
        desc.colorTextureFormat = colorFormat
        desc.outputTextureFormat = outputFormat
        desc.colorProcessingMode = colorProcessingMode

        guard let created = desc.makeSpatialScaler(device: device) else {
            throw EngineError.shaderCompilationFailed(
                effectID: .metalFXSpatial,
                detail: "Failed to create MTLFXSpatialScaler (\(inputWidth)x\(inputHeight) -> \(outputWidth)x\(outputHeight), fmt=\(colorFormat.rawValue))."
            )
        }

        let wrapped = LockedScaler(created)
        state.withLockUnchecked { s in
            s.sequence &+= 1
            s.scalers[key] = CacheEntry(lockedScaler: wrapped, lastUsedSequence: s.sequence)
            while s.scalers.count > maxCachedScalers {
                if let oldestKey = s.scalers.min(by: { $0.value.lastUsedSequence < $1.value.lastUsedSequence })?.key {
                    s.scalers.removeValue(forKey: oldestKey)
                } else {
                    break
                }
            }
        }
        PipelineLog.shared.debug(.shader, "Created MTLFXSpatialScaler \(inputWidth)x\(inputHeight)->\(outputWidth)x\(outputHeight)")
        return wrapped
    }
}
