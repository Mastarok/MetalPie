import CryptoKit
import Foundation
import Metal
import MetalPieCore
import os

/// Compiles MetalPie's runtime `.metal` shader sources, caches pipeline states, and persists
/// a hardware- and source-keyed `MTLBinaryArchive` so repeat launches load pipelines in <1ms.
public final class ShaderLibraryManager: @unchecked Sendable {
    /// Ordered list of every bundled `.metal` shader unit (without `.metal` extension).
    public static let allShaderNames: [String] = [
        "Common",
        "FSR1",
        "CAS",
        "SGSR",
        "Interpolation",
        "PixelArt",
        "Anime4K",
        "Anime4KRestoreML",
        "Anime4KUpscaleML",
        "CuNNy",
        "FXAA",
        "FSRCNNX",
        "SSimDownscaler",
        "OpticalFlowFallback"
    ]

    public let device: any MTLDevice
    public let shadersDirectoryURL: URL
    public let cacheDirectoryURL: URL
    public let useFastMath: Bool

    /// Whether an existing on-disk `MTLBinaryArchive` matched the current GPU, OS, and shader digest.
    public let didLoadExistingArchive: Bool

    /// Hex-encoded SHA-256 digest of GPU name, OS version, math mode, and all `.metal` sources.
    public let sourceDigest: String

    /// Path to the active `MTLBinaryArchive` on disk.
    public let binaryArchiveURL: URL

    private struct State {
        var libraries: [String: any MTLLibrary] = [:]
        var computePipelines: [String: any MTLComputePipelineState] = [:]
        var renderPipelines: [String: any MTLRenderPipelineState] = [:]
        var binaryArchive: (any MTLBinaryArchive)?
        var archiveDirty: Bool = false
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Creates a shader library manager backed by `device` and a disk `MTLBinaryArchive` cache.
    public init(
        device: any MTLDevice,
        shadersDirectoryURL: URL? = nil,
        cacheDirectoryURL: URL? = nil,
        useFastMath: Bool = true
    ) throws {
        self.device = device
        self.useFastMath = useFastMath

        guard let resolvedShadersDir = shadersDirectoryURL ?? MetalPieShadersBundle.shadersDirectoryURL else {
            let msg = "Could not locate bundled Shaders directory via MetalPieShadersBundle."
            PipelineLog.shared.error(.shader, msg)
            throw EngineError.shaderCompilationFailed(effectID: .bilinear, detail: msg)
        }
        self.shadersDirectoryURL = resolvedShadersDir

        let resolvedCacheDir: URL
        if let customCache = cacheDirectoryURL {
            resolvedCacheDir = customCache
        } else {
            let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            resolvedCacheDir = cachesBase
                .appendingPathComponent("com.metalpie.app", isDirectory: true)
                .appendingPathComponent("ShaderCache", isDirectory: true)
        }
        self.cacheDirectoryURL = resolvedCacheDir

        let digest = Self.computeSourceDigest(
            deviceName: device.name,
            useFastMath: useFastMath,
            shadersDirectory: resolvedShadersDir
        )
        self.sourceDigest = digest
        let shortKey = String(digest.prefix(24))
        self.binaryArchiveURL = resolvedCacheDir.appendingPathComponent("metalpie-\(shortKey).metallibarchive")

        try? FileManager.default.createDirectory(at: resolvedCacheDir, withIntermediateDirectories: true)

        var loadedExisting = false
        var archive: (any MTLBinaryArchive)?
        if FileManager.default.fileExists(atPath: self.binaryArchiveURL.path) {
            let desc = MTLBinaryArchiveDescriptor()
            desc.url = self.binaryArchiveURL
            if let existing = try? device.makeBinaryArchive(descriptor: desc) {
                archive = existing
                loadedExisting = true
                PipelineLog.shared.info(.shader, "Loaded shader binary archive: \(self.binaryArchiveURL.lastPathComponent)")
            } else {
                PipelineLog.shared.warning(.shader, "Stale or incompatible binary archive discarded; rebuilding cache.")
                try? FileManager.default.removeItem(at: self.binaryArchiveURL)
            }
        }

        if archive == nil {
            let desc = MTLBinaryArchiveDescriptor()
            archive = try? device.makeBinaryArchive(descriptor: desc)
        }

        self.didLoadExistingArchive = loadedExisting
        self.state = OSAllocatedUnfairLock(uncheckedState: State(binaryArchive: archive))
    }

    /// Loads and compiles every bundled `.metal` shader source file on the active GPU.
    @discardableResult
    public func loadAllLibraries() throws -> [String: any MTLLibrary] {
        var result: [String: any MTLLibrary] = [:]
        result.reserveCapacity(Self.allShaderNames.count)
        for name in Self.allShaderNames {
            result[name] = try library(named: name)
        }
        return result
    }

    /// Returns a compiled `MTLLibrary` for `name` (e.g., `"FSR1"` for `FSR1.metal`), caching on first compile.
    public func library(named name: String, effectHint: EffectID = .bilinear) throws -> any MTLLibrary {
        if let cached = state.withLockUnchecked({ $0.libraries[name] }) {
            return cached
        }

        let fileURL = shadersDirectoryURL.appendingPathComponent("\(name).metal")
        let source: String
        do {
            source = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            let msg = "Failed to read shader source '\(fileURL.lastPathComponent)': \(error.localizedDescription)"
            PipelineLog.shared.error(.shader, msg)
            throw EngineError.shaderCompilationFailed(effectID: effectHint, detail: msg)
        }

        let options = makeCompileOptions()
        let t0 = CFAbsoluteTimeGetCurrent()
        let compiled: any MTLLibrary
        do {
            compiled = try device.makeLibrary(source: source, options: options)
        } catch {
            let msg = "MSL compile failed for '\(name).metal': \(error.localizedDescription)"
            PipelineLog.shared.error(.shader, msg)
            throw EngineError.shaderCompilationFailed(effectID: effectHint, detail: msg)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        PipelineLog.shared.debug(.shader, String(format: "Compiled %@.metal in %.2f ms", name, elapsedMs))

        state.withLockUnchecked { s in
            s.libraries[name] = compiled
        }
        return compiled
    }

    /// Returns a cached `MTLComputePipelineState`, leveraging `MTLFunctionConstantValues` and `MTLBinaryArchive`.
    public func computePipeline(
        library libraryName: String,
        function functionName: String,
        constants: MTLFunctionConstantValues? = nil,
        cacheKey: String? = nil,
        effectHint: EffectID = .bilinear
    ) throws -> any MTLComputePipelineState {
        let key = cacheKey ?? "\(libraryName)::\(functionName)"
        if let cached = state.withLockUnchecked({ $0.computePipelines[key] }) {
            return cached
        }

        let lib = try library(named: libraryName, effectHint: effectHint)
        let fn: any MTLFunction
        do {
            if let constants {
                fn = try lib.makeFunction(name: functionName, constantValues: constants)
            } else if let direct = lib.makeFunction(name: functionName) {
                fn = direct
            } else {
                let msg = "Function '\(functionName)' not found in '\(libraryName).metal'."
                PipelineLog.shared.error(.shader, msg)
                throw EngineError.shaderCompilationFailed(effectID: effectHint, detail: msg)
            }
        } catch let engineError as EngineError {
            throw engineError
        } catch {
            let msg = "Failed to specialize function '\(functionName)' in '\(libraryName).metal': \(error.localizedDescription)"
            PipelineLog.shared.error(.shader, msg)
            throw EngineError.shaderCompilationFailed(effectID: effectHint, detail: msg)
        }

        let desc = MTLComputePipelineDescriptor()
        desc.computeFunction = fn
        desc.label = key
        desc.threadGroupSizeIsMultipleOfThreadExecutionWidth = false

        let archive = state.withLockUnchecked { $0.binaryArchive }
        if let archive {
            desc.binaryArchives = [archive]
        }

        let pipeline: any MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(descriptor: desc, options: [], reflection: nil)
        } catch {
            let msg = "Failed to build compute pipeline '\(key)': \(error.localizedDescription)"
            PipelineLog.shared.error(.shader, msg)
            throw EngineError.shaderCompilationFailed(effectID: effectHint, detail: msg)
        }

        state.withLockUnchecked { s in
            s.computePipelines[key] = pipeline
            if let arch = s.binaryArchive {
                do {
                    try arch.addComputePipelineFunctions(descriptor: desc)
                    s.archiveDirty = true
                } catch {
                    PipelineLog.shared.debug(.shader, "Binary archive addCompute skipped for '\(key)': \(error.localizedDescription)")
                }
            }
        }
        return pipeline
    }

    /// Returns a cached `MTLRenderPipelineState` for the given vertex/fragment functions and color format.
    public func renderPipeline(
        library libraryName: String,
        vertexFunction: String,
        fragmentFunction: String,
        colorPixelFormat: MTLPixelFormat,
        constants: MTLFunctionConstantValues? = nil,
        cacheKey: String? = nil,
        effectHint: EffectID = .bilinear
    ) throws -> any MTLRenderPipelineState {
        let key = cacheKey ?? "\(libraryName)::\(vertexFunction)+\(fragmentFunction)@\(colorPixelFormat.rawValue)"
        if let cached = state.withLockUnchecked({ $0.renderPipelines[key] }) {
            return cached
        }

        let lib = try library(named: libraryName, effectHint: effectHint)
        guard let vfn = lib.makeFunction(name: vertexFunction) else {
            let msg = "Vertex function '\(vertexFunction)' not found in '\(libraryName).metal'."
            PipelineLog.shared.error(.shader, msg)
            throw EngineError.shaderCompilationFailed(effectID: effectHint, detail: msg)
        }
        let ffn: any MTLFunction
        do {
            if let constants {
                ffn = try lib.makeFunction(name: fragmentFunction, constantValues: constants)
            } else if let direct = lib.makeFunction(name: fragmentFunction) {
                ffn = direct
            } else {
                let msg = "Fragment function '\(fragmentFunction)' not found in '\(libraryName).metal'."
                PipelineLog.shared.error(.shader, msg)
                throw EngineError.shaderCompilationFailed(effectID: effectHint, detail: msg)
            }
        } catch let engineError as EngineError {
            throw engineError
        } catch {
            let msg = "Failed to specialize fragment '\(fragmentFunction)': \(error.localizedDescription)"
            PipelineLog.shared.error(.shader, msg)
            throw EngineError.shaderCompilationFailed(effectID: effectHint, detail: msg)
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = key
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = colorPixelFormat

        let archive = state.withLockUnchecked { $0.binaryArchive }
        if let archive {
            desc.binaryArchives = [archive]
        }

        let pipeline: any MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            let msg = "Failed to build render pipeline '\(key)': \(error.localizedDescription)"
            PipelineLog.shared.error(.shader, msg)
            throw EngineError.shaderCompilationFailed(effectID: effectHint, detail: msg)
        }

        state.withLockUnchecked { s in
            s.renderPipelines[key] = pipeline
            if let arch = s.binaryArchive {
                do {
                    try arch.addRenderPipelineFunctions(descriptor: desc)
                    s.archiveDirty = true
                } catch {
                    PipelineLog.shared.debug(.shader, "Binary archive addRender skipped for '\(key)': \(error.localizedDescription)")
                }
            }
        }
        return pipeline
    }

    /// Serializes the active `MTLBinaryArchive` atomically to disk if new pipelines were added.
    public func saveBinaryArchive(force: Bool = false) throws {
        let (archive, shouldSave): ((any MTLBinaryArchive)?, Bool) = state.withLockUnchecked { s in
            (s.binaryArchive, force || s.archiveDirty)
        }
        guard let archive, shouldSave else { return }

        try FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        let tempURL = binaryArchiveURL.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tempURL)
        try archive.serialize(to: tempURL)
        _ = try FileManager.default.replaceItemAt(binaryArchiveURL, withItemAt: tempURL)

        state.withLockUnchecked { $0.archiveDirty = false }
        PipelineLog.shared.info(.shader, "Persisted shader binary archive to \(binaryArchiveURL.lastPathComponent)")
    }

    /// Removes cached binary archives in `cacheDirectoryURL` and resets in-memory pipeline caches.
    public func clearCache() throws {
        state.withLockUnchecked { s in
            s.libraries.removeAll()
            s.computePipelines.removeAll()
            s.renderPipelines.removeAll()
            let desc = MTLBinaryArchiveDescriptor()
            s.binaryArchive = try? device.makeBinaryArchive(descriptor: desc)
            s.archiveDirty = false
        }

        if FileManager.default.fileExists(atPath: cacheDirectoryURL.path) {
            let items = try FileManager.default.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: nil)
            for item in items where item.pathExtension == "metallibarchive" || item.pathExtension == "tmp" {
                try? FileManager.default.removeItem(at: item)
            }
        }
        PipelineLog.shared.info(.shader, "Cleared shader binary archive cache.")
    }

    /// Number of compute + render pipelines currently cached in memory.
    public var cachedPipelineCount: Int {
        state.withLockUnchecked { $0.computePipelines.count + $0.renderPipelines.count }
    }

    private func makeCompileOptions() -> MTLCompileOptions {
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            options.mathMode = useFastMath ? .fast : .relaxed
        } else {
            options.fastMathEnabled = useFastMath
        }
        options.languageVersion = .version3_1
        return options
    }

    private static func computeSourceDigest(
        deviceName: String,
        useFastMath: Bool,
        shadersDirectory: URL
    ) -> String {
        var hasher = SHA256()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let header = "MetalPieShaderCache-v1|\(deviceName)|\(osVersion)|fastMath=\(useFastMath)\n"
        hasher.update(data: Data(header.utf8))

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: shadersDirectory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "metal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in files {
            hasher.update(data: Data(url.lastPathComponent.utf8))
            hasher.update(data: Data([0]))
            if let data = try? Data(contentsOf: url) {
                hasher.update(data: data)
            }
            hasher.update(data: Data([0]))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
