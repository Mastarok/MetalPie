import CoreGraphics
import Foundation
import Metal
import MetalFX
import MetalPieCore
import MetalPieShaders
import Testing

// MARK: - Synthetic GPU Test Helpers

private enum TestPatterns {
    /// Creates a `.shared` BGRA8 texture from a pixel generator `(x, y, w, h) -> (r, g, b, a)` in `[0, 1]`.
    static func makeBGRA8Texture(
        device: any MTLDevice,
        width: Int,
        height: Int,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget],
        label: String = "TestTex",
        generator: (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (Float, Float, Float, Float)
    ) -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!
        tex.label = label

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = generator(x, y, width, height)
                let idx = (y * width + x) * 4
                bytes[idx + 0] = UInt8(clamping: Int((min(max(b, 0), 1) * 255.0).rounded()))
                bytes[idx + 1] = UInt8(clamping: Int((min(max(g, 0), 1) * 255.0).rounded()))
                bytes[idx + 2] = UInt8(clamping: Int((min(max(r, 0), 1) * 255.0).rounded()))
                bytes[idx + 3] = UInt8(clamping: Int((min(max(a, 0), 1) * 255.0).rounded()))
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

    /// Creates a `.shared` RGBA16Float HDR texture (supports > 1.0 specular values).
    static func makeRGBA16FTexture(
        device: any MTLDevice,
        width: Int,
        height: Int,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget],
        generator: (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (Float, Float, Float, Float)
    ) -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!

        var halfs = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = generator(x, y, width, height)
                let idx = (y * width + x) * 4
                halfs[idx + 0] = Float16(r)
                halfs[idx + 1] = Float16(g)
                halfs[idx + 2] = Float16(b)
                halfs[idx + 3] = Float16(a)
            }
        }
        halfs.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 8
            )
        }
        return tex
    }

    static func makeOutputTexture(
        device: any MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget]
    ) -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)!
    }

    /// Rich diagonal-edge + color-bar + circle synthetic frame ideal for upscalers & sharpeners.
    static func diagonalEdges(device: any MTLDevice, width: Int, height: Int) -> any MTLTexture {
        makeBGRA8Texture(device: device, width: width, height: height, label: "DiagonalEdges") { x, y, w, h in
            let u = Float(x) / Float(max(1, w))
            let v = Float(y) / Float(max(1, h))
            let dx = u - 0.5
            let dy = v - 0.5
            let dist = sqrt(dx * dx + dy * dy)
            if dist < 0.22 {
                // Sharp diagonal stripes inside circle
                let stripe = ((x + y) / 6) % 2 == 0
                return stripe ? (0.95, 0.85, 0.20, 1.0) : (0.12, 0.22, 0.65, 1.0)
            }
            // High-contrast diagonal edge splitting upper-left and lower-right
            if u * 1.1 + v < 0.95 {
                return (0.15 + 0.55 * u, 0.25 + 0.45 * v, 0.78, 1.0)
            } else {
                return (0.88 - 0.30 * v, 0.22 + 0.50 * u, 0.20, 1.0)
            }
        }
    }

    /// Crisp pixel-art checkerboard + diagonal sprite edges (for xBRZ, Pixellate, Nearest).
    static func pixelArtSprite(device: any MTLDevice, width: Int, height: Int) -> any MTLTexture {
        makeBGRA8Texture(device: device, width: width, height: height, label: "PixelArtSprite") { x, y, w, h in
            let cx = x - w / 2
            let cy = y - h / 2
            let manhattan = abs(cx) + abs(cy)
            if manhattan < min(w, h) / 4 {
                return (0.95, 0.25, 0.20, 1.0)
            }
            if manhattan < min(w, h) / 4 + 3 {
                return (0.05, 0.05, 0.08, 1.0)
            }
            let checker = ((x / 4) + (y / 4)) % 2 == 0
            return checker ? (0.85, 0.92, 0.96, 1.0) : (0.20, 0.35, 0.55, 1.0)
        }
    }

    /// Anime cel-shaded gradient with crisp dark ink outlines (for Anime4K & FSRCNNX).
    static func animeLineArt(device: any MTLDevice, width: Int, height: Int) -> any MTLTexture {
        makeBGRA8Texture(device: device, width: width, height: height, label: "AnimeLineArt") { x, y, w, h in
            let u = Float(x) / Float(max(1, w))
            let v = Float(y) / Float(max(1, h))
            let ring = abs(sqrt((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)) - 0.28)
            let diag = abs((u - 0.15) - (v - 0.15))
            if ring < 0.012 || diag < 0.008 {
                return (0.04, 0.04, 0.06, 1.0) // dark ink outline
            }
            if sqrt((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)) < 0.28 {
                return (0.96, 0.78, 0.68, 1.0) // warm cel fill
            }
            return (0.30, 0.62 + 0.25 * (1.0 - v), 0.92, 1.0) // sky fill
        }
    }

    /// Deliberately quantized 8-bit sky gradient with visible 16-level banding (for Deband).
    static func bandedGradient(device: any MTLDevice, width: Int, height: Int) -> any MTLTexture {
        makeBGRA8Texture(device: device, width: width, height: height, label: "BandedGradient") { x, y, w, h in
            let t = (Float(x) / Float(max(1, w)) * 0.6 + Float(y) / Float(max(1, h)) * 0.4)
            let banded = floor(t * 16.0) / 16.0
            return (0.15 + 0.65 * banded, 0.20 + 0.55 * banded, 0.35 + 0.55 * banded, 1.0)
        }
    }

    /// Textured bright square centered at `(centerX, centerY)` over a patterned dark background
    /// (for optical flow / VideoToolbox ML motion estimation).
    static func shiftedBlockFrame(
        device: any MTLDevice,
        width: Int,
        height: Int,
        centerX: Int,
        centerY: Int,
        halfSize: Int = 24
    ) -> any MTLTexture {
        makeBGRA8Texture(device: device, width: width, height: height, label: "ShiftedBlock_\(centerX)") { x, y, _, _ in
            let dx = x - centerX
            let dy = y - centerY
            if abs(dx) <= halfSize && abs(dy) <= halfSize {
                // High-contrast internal cross/gradient gives crisp motion features.
                let edgeFade = 1.0 - 0.15 * (Float(abs(dx)) / Float(halfSize))
                let cross = (abs(dx) < 3 || abs(dy) < 3) ? Float(0.65) : Float(0.95)
                return (cross * edgeFade, 0.90 * edgeFade, 0.35 * edgeFade, 1.0)
            }
            // Subtle static background grid
            let bg: Float = ((x / 32 + y / 32) % 2 == 0) ? 0.08 : 0.11
            return (bg, bg, bg + 0.02, 1.0)
        }
    }

    static func solidColor(
        device: any MTLDevice,
        width: Int,
        height: Int,
        r: Float, g: Float, b: Float, a: Float = 1.0
    ) -> any MTLTexture {
        makeBGRA8Texture(device: device, width: width, height: height, label: "Solid") { _, _, _, _ in
            (r, g, b, a)
        }
    }

    static func makeCGImage(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let diag = ((x + y) / 10) % 2 == 0
                pixels[idx + 0] = diag ? 235 : 40
                pixels[idx + 1] = UInt8((x * 220) / max(1, width))
                pixels[idx + 2] = UInt8((y * 220) / max(1, height))
                pixels[idx + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        return ctx.makeImage()!
    }
}

// MARK: - Pixel Readback & Numerical Validation

private struct ImageStats {
    let width: Int
    let height: Int
    let nanCount: Int
    let infCount: Int
    let minLuma: Float
    let maxLuma: Float
    let meanLuma: Float
    let stdDevLuma: Float
    let maxChannelValue: Float
    let pixelsRGBA: [Float] // 4 floats per pixel (R, G, B, A)
}

private func readbackStats(texture: any MTLTexture) -> ImageStats {
    let w = texture.width
    let h = texture.height
    var rgba = [Float](repeating: 0, count: w * h * 4)

    switch texture.pixelFormat {
    case .bgra8Unorm, .bgra8Unorm_srgb:
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in 0..<(w * h) {
            rgba[i * 4 + 0] = Float(bytes[i * 4 + 2]) / 255.0
            rgba[i * 4 + 1] = Float(bytes[i * 4 + 1]) / 255.0
            rgba[i * 4 + 2] = Float(bytes[i * 4 + 0]) / 255.0
            rgba[i * 4 + 3] = Float(bytes[i * 4 + 3]) / 255.0
        }
    case .rgba8Unorm, .rgba8Unorm_srgb:
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in 0..<(w * h * 4) {
            rgba[i] = Float(bytes[i]) / 255.0
        }
    case .rgba16Float:
        var halfs = [Float16](repeating: 0, count: w * h * 4)
        halfs.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        for i in 0..<(w * h * 4) {
            rgba[i] = Float(halfs[i])
        }
    default:
        fatalError("Unsupported readback format in test: \(texture.pixelFormat.rawValue)")
    }

    var nanCount = 0
    var infCount = 0
    var minLuma: Float = .greatestFiniteMagnitude
    var maxLuma: Float = -.greatestFiniteMagnitude
    var maxChan: Float = -.greatestFiniteMagnitude
    var sum: Double = 0
    var sumSq: Double = 0
    var validCount = 0

    for i in 0..<(w * h) {
        let r = rgba[i * 4 + 0]
        let g = rgba[i * 4 + 1]
        let b = rgba[i * 4 + 2]
        let a = rgba[i * 4 + 3]
        if r.isNaN || g.isNaN || b.isNaN || a.isNaN {
            nanCount += 1
            continue
        }
        if r.isInfinite || g.isInfinite || b.isInfinite || a.isInfinite {
            infCount += 1
            continue
        }
        maxChan = max(maxChan, max(r, max(g, b)))
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        minLuma = min(minLuma, luma)
        maxLuma = max(maxLuma, luma)
        sum += Double(luma)
        sumSq += Double(luma) * Double(luma)
        validCount += 1
    }

    let mean = validCount > 0 ? sum / Double(validCount) : 0
    let variance = validCount > 0 ? max(0.0, (sumSq / Double(validCount)) - mean * mean) : 0
    return ImageStats(
        width: w,
        height: h,
        nanCount: nanCount,
        infCount: infCount,
        minLuma: validCount > 0 ? minLuma : 0,
        maxLuma: validCount > 0 ? maxLuma : 0,
        meanLuma: Float(mean),
        stdDevLuma: Float(sqrt(variance)),
        maxChannelValue: validCount > 0 ? maxChan : 0,
        pixelsRGBA: rgba
    )
}

private func readbackCGImageRGBA(_ image: CGImage) -> [UInt8] {
    let w = image.width
    let h = image.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    let ctx = CGContext(
        data: &rgba,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    )!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return rgba
}

/// Computes horizontal edge sharpness energy (mean |dx| + |dy| of luma) over interior pixels.
private func edgeGradientEnergy(_ stats: ImageStats) -> Float {
    var acc: Double = 0
    var count = 0
    for y in 1..<(stats.height - 1) {
        for x in 1..<(stats.width - 1) {
            let idx = (y * stats.width + x) * 4
            let idxR = idx + 4
            let idxD = idx + stats.width * 4
            let l0 = 0.2126 * stats.pixelsRGBA[idx] + 0.7152 * stats.pixelsRGBA[idx + 1] + 0.0722 * stats.pixelsRGBA[idx + 2]
            let lR = 0.2126 * stats.pixelsRGBA[idxR] + 0.7152 * stats.pixelsRGBA[idxR + 1] + 0.0722 * stats.pixelsRGBA[idxR + 2]
            let lD = 0.2126 * stats.pixelsRGBA[idxD] + 0.7152 * stats.pixelsRGBA[idxD + 1] + 0.0722 * stats.pixelsRGBA[idxD + 2]
            acc += Double(abs(lR - l0) + abs(lD - l0))
            count += 1
        }
    }
    return count > 0 ? Float(acc / Double(count)) : 0
}

/// Computes the bright-feature X centroid (weighted by pixels with luma > threshold).
private func brightCentroidX(_ stats: ImageStats, lumaThreshold: Float = 0.45) -> Float? {
    var sumX: Double = 0
    var sumW: Double = 0
    for y in 0..<stats.height {
        for x in 0..<stats.width {
            let idx = (y * stats.width + x) * 4
            let luma = 0.2126 * stats.pixelsRGBA[idx] + 0.7152 * stats.pixelsRGBA[idx + 1] + 0.0722 * stats.pixelsRGBA[idx + 2]
            if luma > lumaThreshold {
                let weight = Double(luma - lumaThreshold)
                sumX += Double(x) * weight
                sumW += weight
            }
        }
    }
    guard sumW > 0 else { return nil }
    return Float(sumX / sumW)
}

// MARK: - Comprehensive Real-GPU MetalPieShaders Test Suite

@Suite("MetalPieShaders Real GPU Pipeline", .serialized)
struct MetalPieShadersGPUValidationTests {
    private static func requireDeviceAndQueue() throws -> (any MTLDevice, any MTLCommandQueue) {
        let device = try #require(MTLCreateSystemDefaultDevice(), "Apple Silicon Metal GPU is required")
        let queue = try #require(device.makeCommandQueue(), "MTLCommandQueue creation failed")
        return (device, queue)
    }

    // 1. Runtime MSL Compilation + Binary Archive Disk Caching & Reload
    @Test("All 10 bundled .metal shaders compile cleanly and persist/reload MTLBinaryArchive")
    func compileAllShadersAndBinaryArchiveRoundTrip() throws {
        let (device, _) = try Self.requireDeviceAndQueue()
        let tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetalPieShaderCacheTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempCacheDir) }

        // Cold build
        let coldManager = try ShaderLibraryManager(device: device, cacheDirectoryURL: tempCacheDir, useFastMath: true)
        #expect(coldManager.didLoadExistingArchive == false)
        #expect(coldManager.sourceDigest.count == 64)

        let libraries = try coldManager.loadAllLibraries()
        #expect(libraries.count == ShaderLibraryManager.allShaderNames.count)
        for name in ShaderLibraryManager.allShaderNames {
            #expect(libraries[name] != nil, "Missing compiled MTLLibrary for \(name).metal")
        }

        // Build pipelines spanning every .metal file (compute + render) so all are recorded into MTLBinaryArchive.
        let computeFunctions: [(String, String)] = [
            ("Common", "cropBlit"),
            ("Common", "demagnifyNearest"),
            ("Common", "demagnifyBilinear"),
            ("Common", "duplicateFrameCheck"),
            ("Common", "bgraToNV12"),
            ("Common", "nv12ToBGRA"),
            ("Common", "presentCompute"),
            ("FSR1", "fsr1_easu"),
            ("FSR1", "fsr1_rcas"),
            ("CAS", "cas_sharpen"),
            ("CAS", "adaptive_sharpen_pass1"),
            ("CAS", "adaptive_sharpen_pass2"),
            ("SGSR", "sgsr_upscale"),
            ("Interpolation", "lanczos6_h"),
            ("Interpolation", "lanczos6_v"),
            ("Interpolation", "bicubic"),
            ("Interpolation", "sharp_bilinear"),
            ("Interpolation", "pixellate"),
            ("Interpolation", "nearest"),
            ("Interpolation", "bilinear"),
            ("Interpolation", "deband"),
            ("Interpolation", "image_adjustment"),
            ("PixelArt", "xbrz_pass1"),
            ("PixelArt", "xbrz_pass2"),
            ("PixelArt", "crt_geom"),
            ("PixelArt", "crt_lottes"),
            ("Anime4K", "anime4k_restore_pass1"),
            ("Anime4K", "anime4k_restore_pass4"),
            ("Anime4K", "anime4k_bilateral_mode"),
            ("Anime4K", "anime4k_upscale_pass1"),
            ("Anime4K", "anime4k_upscale_pass4"),
            ("FSRCNNX", "fsrcnnx_std_pass1"),
            ("FSRCNNX", "fsrcnnx_std_pass6"),
            ("FSRCNNX", "fsrcnnx_lineart_pass1"),
            ("FSRCNNX", "fsrcnnx_lineart_pass6"),
            ("SSimDownscaler", "ssim_pass1_postkernel"),
            ("SSimDownscaler", "ssim_pass5_reconstruct"),
            ("OpticalFlowFallback", "of_luma_from_rgba"),
            ("OpticalFlowFallback", "of_block_match_coarse"),
            ("OpticalFlowFallback", "of_bidirectional_warp")
        ]
        for (lib, fn) in computeFunctions {
            _ = try coldManager.computePipeline(library: lib, function: fn)
        }
        _ = try coldManager.renderPipeline(
            library: "Common",
            vertexFunction: "presentVertex",
            fragmentFunction: "presentFragment",
            colorPixelFormat: .bgra8Unorm
        )

        try coldManager.saveBinaryArchive(force: true)
        #expect(FileManager.default.fileExists(atPath: coldManager.binaryArchiveURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: coldManager.binaryArchiveURL.path)
        let archiveBytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        #expect(archiveBytes > 0, "Serialized MTLBinaryArchive must be non-empty")

        // Warm reload from disk cache on a fresh manager
        let warmManager = try ShaderLibraryManager(device: device, cacheDirectoryURL: tempCacheDir, useFastMath: true)
        #expect(warmManager.didLoadExistingArchive == true)
        #expect(warmManager.sourceDigest == coldManager.sourceDigest)

        let t0 = CFAbsoluteTimeGetCurrent()
        _ = try warmManager.computePipeline(library: "FSR1", function: "fsr1_easu")
        _ = try warmManager.computePipeline(library: "FSR1", function: "fsr1_rcas")
        _ = try warmManager.renderPipeline(
            library: "Common",
            vertexFunction: "presentVertex",
            fragmentFunction: "presentFragment",
            colorPixelFormat: .bgra8Unorm
        )
        let warmMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        print(String(format: "[BinaryArchive] archive=%d bytes, warm pipeline reload=%.2f ms", archiveBytes, warmMs))
        #expect(warmManager.cachedPipelineCount == 3)
    }

    // 2. TexturePool Zero-Allocation Steady State across all required formats
    @Test("TexturePool achieves zero steady-state allocations across all GPU pixel formats")
    func texturePoolZeroAllocationSteadyState() throws {
        let (device, queue) = try Self.requireDeviceAndQueue()
        let pool = TexturePool(device: device, maxCachedTextures: 32)

        let formats: [MTLPixelFormat] = [.bgra8Unorm, .rgba16Float, .bgr10a2Unorm, .r8Unorm, .rg16Float]
        for frame in 0..<6 {
            let cb = try #require(queue.makeCommandBuffer())
            var leases: [PooledTexture] = []
            for fmt in formats {
                let usage: MTLTextureUsage = (fmt == .r8Unorm || fmt == .rg16Float)
                    ? [.shaderRead, .shaderWrite]
                    : [.shaderRead, .shaderWrite, .renderTarget]
                let lease = try pool.acquire(
                    width: 256,
                    height: 144,
                    pixelFormat: fmt,
                    usage: usage,
                    storageMode: .private
                )
                #expect(lease.texture.pixelFormat == fmt)
                #expect(lease.texture.storageMode == .private)
                leases.append(lease)
            }
            pool.recycleOnCompletion(leases, of: cb)
            let commitSync: (any MTLCommandBuffer) -> Void = { cmd in
                cmd.commit()
                cmd.waitUntilCompleted()
            }
            commitSync(cb)
            if frame == 0 {
                #expect(pool.stats.totalAllocations == UInt64(formats.count))
            }
        }

        let finalStats = pool.stats
        #expect(finalStats.totalAllocations == UInt64(formats.count), "Zero per-frame allocations after frame 0!")
        #expect(finalStats.cacheHits == UInt64(formats.count * 5))
        #expect(finalStats.activeLeaseCount == 0)
        #expect(finalStats.pooledCount == formats.count)
    }

    // 3. Every Single One of the 22 EffectIDs Executed & Numerically Verified on Apple Silicon GPU
    @Test("All 22 EffectIDs execute on real GPU with valid dimensions, contrast, and zero NaN/Inf")
    func executeAll22EffectsOnRealGPU() throws {
        let (device, queue) = try Self.requireDeviceAndQueue()
        let renderer = try EffectChainRenderer(device: device)

        #expect(EffectID.allCases.count == 22)

        let diagSrc = TestPatterns.diagonalEdges(device: device, width: 320, height: 180)
        let pixelSrc = TestPatterns.pixelArtSprite(device: device, width: 160, height: 90)
        let animeSrc = TestPatterns.animeLineArt(device: device, width: 320, height: 180)
        let bandSrc = TestPatterns.bandedGradient(device: device, width: 320, height: 180)
        let downSrc = TestPatterns.diagonalEdges(device: device, width: 512, height: 288)

        var bilinearEnergy: Float = 0
        var rcasEnergy: Float = 0

        for effectID in EffectID.allCases {
            let sourceTex: any MTLTexture
            let targetSize: PixelSize
            let instance: EffectInstance

            switch effectID {
            case .ssimDownscaler:
                sourceTex = downSrc
                targetSize = PixelSize(width: 256, height: 144)
                instance = EffectInstance(effectID: .ssimDownscaler, scalingType: .fit)
            case .xbrzFreescale, .pixellate:
                sourceTex = pixelSrc
                targetSize = PixelSize(width: 320, height: 180)
                instance = EffectInstance(effectID: effectID, scalingType: .fit)
            case .anime4kRestore:
                sourceTex = animeSrc
                targetSize = PixelSize(width: 320, height: 180)
                instance = EffectInstance(effectID: .anime4kRestore, scalingType: .normal)
            case .anime4kUpscaleDenoise:
                sourceTex = animeSrc
                targetSize = PixelSize(width: 640, height: 360)
                instance = EffectInstance(
                    effectID: .anime4kUpscaleDenoise,
                    scalingType: .fit,
                    parameters: ["denoiseStrength": .float(0.5), "lineThinning": .float(0.15)]
                )
            case .fsrcnnx:
                sourceTex = animeSrc
                targetSize = PixelSize(width: 640, height: 360)
                instance = EffectInstance(effectID: .fsrcnnx, scalingType: .fit, parameters: ["variant": .choice("standard")])
            case .deband:
                sourceTex = bandSrc
                targetSize = PixelSize(width: 320, height: 180)
                instance = EffectInstance(effectID: .deband, scalingType: .normal)
            case .cas, .adaptiveSharpen, .fsr1RCAS, .imageAdjustment:
                sourceTex = diagSrc
                targetSize = PixelSize(width: 320, height: 180)
                instance = EffectInstance(effectID: effectID, scalingType: .normal)
            case .vtSuperResolution:
                sourceTex = diagSrc
                targetSize = PixelSize(width: 640, height: 360)
                instance = EffectInstance(effectID: .vtSuperResolution, scalingType: .fit, parameters: ["scaleFactor": .choice("2.0")])
            default:
                sourceTex = diagSrc
                targetSize = PixelSize(width: 640, height: 360)
                instance = EffectInstance(effectID: effectID, scalingType: .fit)
            }

            let mode = ScalingMode(name: "Test_\(effectID.rawValue)", effects: [instance])
            let layout = ScalingLayoutCalculator.calculate(
                sourcePixelSize: PixelSize(width: sourceTex.width, height: sourceTex.height),
                targetPixelSize: targetSize,
                backingScaleFactor: 1.0,
                crop: .zero,
                effects: mode.effects,
                alignment: .center
            )
            let destTex = TestPatterns.makeOutputTexture(device: device, width: targetSize.width, height: targetSize.height)
            let cb = try #require(queue.makeCommandBuffer())

            let report = try renderer.encode(
                scalingMode: mode,
                context: EffectRenderContext(
                    device: device,
                    commandBuffer: cb,
                    sourceTexture: sourceTex,
                    destinationTexture: destTex,
                    layout: layout,
                    isHDR: false,
                    frameIndex: 1,
                    duplicateFrameMode: .never
                )
            )
            let commitSync: (any MTLCommandBuffer) -> Void = { cmd in
                cmd.commit()
                cmd.waitUntilCompleted()
            }
            commitSync(cb)

            #expect(cb.status == .completed, "Command buffer failed for \(effectID.rawValue): \(String(describing: cb.error))")
            #expect(report.finalOutputSize == PixelSize(width: layout.visibleContentPixelRect.width, height: layout.visibleContentPixelRect.height), "Output size mismatch for \(effectID.rawValue)")
            #expect(!report.passTimings.isEmpty)

            let stats = readbackStats(texture: destTex)
            #expect(stats.nanCount == 0, "\(effectID.rawValue) produced \(stats.nanCount) NaN pixels")
            #expect(stats.infCount == 0, "\(effectID.rawValue) produced \(stats.infCount) Inf pixels")
            #expect(stats.meanLuma > 0.05 && stats.meanLuma < 0.95, "\(effectID.rawValue) has degenerate luma \(stats.meanLuma)")
            #expect(stats.stdDevLuma > 0.02, "\(effectID.rawValue) collapsed contrast (stdDev=\(stats.stdDevLuma))")

            if effectID == .bilinear {
                bilinearEnergy = edgeGradientEnergy(stats)
            } else if effectID == .fsr1RCAS {
                rcasEnergy = edgeGradientEnergy(stats)
            }

            if effectID == .ssimDownscaler {
                let srcStats = readbackStats(texture: downSrc)
                #expect(abs(stats.meanLuma - srcStats.meanLuma) < 0.04, "SSimDownscaler luma drift too large")
            }

            if effectID == .deband {
                let srcStats = readbackStats(texture: bandSrc)
                #expect(abs(stats.meanLuma - srcStats.meanLuma) < 0.03, "Deband luma drift too large")
            }

            if effectID == .crtGeom || effectID == .crtLottes {
                // Verify horizontal scanline modulation exists between consecutive rows.
                var rowDiffSum: Double = 0
                let midX = stats.width / 2
                for y in 20..<(stats.height - 20) {
                    let i0 = (y * stats.width + midX) * 4
                    let i1 = ((y + 1) * stats.width + midX) * 4
                    let l0 = 0.2126 * stats.pixelsRGBA[i0] + 0.7152 * stats.pixelsRGBA[i0 + 1] + 0.0722 * stats.pixelsRGBA[i0 + 2]
                    let l1 = 0.2126 * stats.pixelsRGBA[i1] + 0.7152 * stats.pixelsRGBA[i1 + 1] + 0.0722 * stats.pixelsRGBA[i1 + 2]
                    rowDiffSum += Double(abs(l1 - l0))
                }
                let avgRowDiff = rowDiffSum / Double(max(1, stats.height - 40))
                #expect(avgRowDiff > 0.01, "\(effectID.rawValue) expected visible scanline modulation (got \(avgRowDiff))")
            }
        }

        // Verify FSR1 RCAS sharpens edges cleanly above plain bilinear.
        #expect(rcasEnergy > bilinearEnergy, "FSR1 RCAS should preserve stronger edge gradients than bilinear")

        // Also test FSRCNNX LineArt variant + ImageAdjustment brightness shift!
        let lineArtMode = ScalingMode(name: "FSRCNNX_LineArt", effects: [
            EffectInstance(effectID: .fsrcnnx, scalingType: .fit, parameters: ["variant": .choice("lineArt")])
        ])
        let lineArtLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: animeSrc.width, height: animeSrc.height),
            targetPixelSize: PixelSize(width: 640, height: 360),
            backingScaleFactor: 1.0,
            effects: lineArtMode.effects
        )
        let lineArtOut = TestPatterns.makeOutputTexture(device: device, width: 640, height: 360)
        let cbLine = try #require(queue.makeCommandBuffer())
        _ = try renderer.encode(
            scalingMode: lineArtMode,
            context: EffectRenderContext(
                device: device,
                commandBuffer: cbLine,
                sourceTexture: animeSrc,
                destinationTexture: lineArtOut,
                layout: lineArtLayout,
                duplicateFrameMode: .never
            )
        )
        cbLine.commit()
        cbLine.waitUntilCompleted()
        let lineStats = readbackStats(texture: lineArtOut)
        #expect(lineStats.nanCount == 0 && lineStats.infCount == 0 && lineStats.stdDevLuma > 0.02)

        // Verify ImageAdjustment brightness parameter measurably brightens the image.
        let brightMode = ScalingMode(name: "Bright", effects: [
            EffectInstance(effectID: .imageAdjustment, scalingType: .normal, parameters: ["brightness": .float(0.25)])
        ])
        let neutralMode = ScalingMode(name: "Neutral", effects: [
            EffectInstance(effectID: .imageAdjustment, scalingType: .normal, parameters: ["brightness": .float(0.0)])
        ])
        let adjLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 320, height: 180),
            targetPixelSize: PixelSize(width: 320, height: 180),
            backingScaleFactor: 1.0,
            effects: neutralMode.effects
        )
        let neutralOut = TestPatterns.makeOutputTexture(device: device, width: 320, height: 180)
        let brightOut = TestPatterns.makeOutputTexture(device: device, width: 320, height: 180)
        let cbAdj = try #require(queue.makeCommandBuffer())
        _ = try renderer.encode(scalingMode: neutralMode, context: EffectRenderContext(device: device, commandBuffer: cbAdj, sourceTexture: diagSrc, destinationTexture: neutralOut, layout: adjLayout, duplicateFrameMode: .never))
        _ = try renderer.encode(scalingMode: brightMode, context: EffectRenderContext(device: device, commandBuffer: cbAdj, sourceTexture: diagSrc, destinationTexture: brightOut, layout: adjLayout, duplicateFrameMode: .never))
        cbAdj.commit()
        cbAdj.waitUntilCompleted()
        let neutralStats = readbackStats(texture: neutralOut)
        let brightStats = readbackStats(texture: brightOut)
        #expect(brightStats.meanLuma > neutralStats.meanLuma + 0.12)
    }

    // 4. All 12 Built-In Presets End-to-End Execution + Real PassTimings
    @Test("All 12 built-in ScalingMode presets prewarm and render cleanly on real GPU")
    func executeAll12BuiltInPresets() async throws {
        let (device, queue) = try Self.requireDeviceAndQueue()
        let renderer = try EffectChainRenderer(device: device)

        #expect(ScalingMode.builtInPresets.count == 12)
        let srcTex = TestPatterns.diagonalEdges(device: device, width: 320, height: 180)
        let targetSize = PixelSize(width: 640, height: 360)

        for preset in ScalingMode.builtInPresets {
            try await renderer.prewarm(scalingMode: preset)
            let layout = ScalingLayoutCalculator.calculate(
                sourcePixelSize: PixelSize(width: 320, height: 180),
                targetPixelSize: targetSize,
                backingScaleFactor: 1.0,
                effects: preset.effects
            )
            let destTex = TestPatterns.makeOutputTexture(device: device, width: targetSize.width, height: targetSize.height)
            let cb = try #require(queue.makeCommandBuffer())
            let report = try renderer.encode(
                scalingMode: preset,
                context: EffectRenderContext(
                    device: device,
                    commandBuffer: cb,
                    sourceTexture: srcTex,
                    destinationTexture: destTex,
                    layout: layout,
                    duplicateFrameMode: .never
                )
            )
            let commitSync: (any MTLCommandBuffer) -> Void = { cmd in
                cmd.commit()
                cmd.waitUntilCompleted()
            }
            commitSync(cb)

            #expect(cb.status == .completed, "Preset '\(preset.name)' failed")
            #expect(!report.passTimings.isEmpty)
            for timing in report.passTimings {
                #expect(timing.colorHex.hasPrefix("#"), "PassTiming '\(timing.name)' missing colorHex")
            }

            let stats = readbackStats(texture: destTex)
            #expect(stats.nanCount == 0 && stats.infCount == 0, "Preset '\(preset.name)' produced NaN/Inf")
            #expect(stats.stdDevLuma > 0.02, "Preset '\(preset.name)' collapsed contrast")
        }

        // Wait briefly for Metal completedHandler to record smoothed GPU pass timings.
        try await Task.sleep(for: .milliseconds(30))
        #expect(!renderer.lastCompletedPassTimings.isEmpty)
    }

    // 5. GPU Duplicate Frame Detection (zero CPU IOSurface lock)
    @Test("GPU duplicate frame detector skips identical frames and re-renders changed frames")
    func verifyDuplicateFrameDetection() throws {
        let (device, queue) = try Self.requireDeviceAndQueue()
        let renderer = try EffectChainRenderer(device: device)

        let frameA1 = TestPatterns.diagonalEdges(device: device, width: 256, height: 144)
        let frameA2 = TestPatterns.diagonalEdges(device: device, width: 256, height: 144)
        let frameB = TestPatterns.animeLineArt(device: device, width: 256, height: 144)
        let mode = ScalingMode.builtInPresets[1] // FSR 1.0 (EASU + RCAS)
        let layout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 256, height: 144),
            targetPixelSize: PixelSize(width: 512, height: 288),
            backingScaleFactor: 1.0,
            effects: mode.effects
        )
        let out1 = TestPatterns.makeOutputTexture(device: device, width: 512, height: 288)
        let out2 = TestPatterns.makeOutputTexture(device: device, width: 512, height: 288)
        let out3 = TestPatterns.makeOutputTexture(device: device, width: 512, height: 288)

        // Frame 1: fresh frame -> not skipped
        let cb1 = try #require(queue.makeCommandBuffer())
        let rep1 = try renderer.encode(
            scalingMode: mode,
            context: EffectRenderContext(device: device, commandBuffer: cb1, sourceTexture: frameA1, destinationTexture: out1, layout: layout, frameIndex: 1, duplicateFrameMode: .always)
        )
        cb1.commit()
        cb1.waitUntilCompleted()
        #expect(rep1.wasDuplicateFrameSkipped == false)

        // Frame 2: identical pixels -> skipped on GPU, cached upscaled frame presented!
        let cb2 = try #require(queue.makeCommandBuffer())
        let rep2 = try renderer.encode(
            scalingMode: mode,
            context: EffectRenderContext(device: device, commandBuffer: cb2, sourceTexture: frameA2, destinationTexture: out2, layout: layout, frameIndex: 2, duplicateFrameMode: .always)
        )
        cb2.commit()
        cb2.waitUntilCompleted()
        #expect(rep2.wasDuplicateFrameSkipped == true)

        let stats1 = readbackStats(texture: out1)
        let stats2 = readbackStats(texture: out2)
        #expect(abs(stats1.meanLuma - stats2.meanLuma) < 0.002, "Skipped frame output must match Frame 1")

        // Frame 3: changed content -> NOT skipped, re-rendered cleanly!
        let cb3 = try #require(queue.makeCommandBuffer())
        let rep3 = try renderer.encode(
            scalingMode: mode,
            context: EffectRenderContext(device: device, commandBuffer: cb3, sourceTexture: frameB, destinationTexture: out3, layout: layout, frameIndex: 3, duplicateFrameMode: .always)
        )
        cb3.commit()
        cb3.waitUntilCompleted()
        #expect(rep3.wasDuplicateFrameSkipped == false)
        let stats3 = readbackStats(texture: out3)
        #expect(abs(stats3.meanLuma - stats1.meanLuma) > 0.02, "Changed frame must reflect new content")
    }

    // 6. 1x Non-Retina Demagnify, Crop, 9-Point Letterbox, VRR Cursor Overlay & Cursor-Free PNG Export
    @Test("Demagnify, crop, letterbox alignment, VRR cursor compositing, and cursor-free PNG export")
    func verifyDemagnifyCropLetterboxAndCursorFreeScreenshot() throws {
        let (device, queue) = try Self.requireDeviceAndQueue()
        let renderer = try EffectChainRenderer(device: device)

        // 6a. Demagnify Nearest & Bilinear
        let src2x = TestPatterns.diagonalEdges(device: device, width: 256, height: 256)
        let demagNearestOut = TestPatterns.makeOutputTexture(device: device, width: 128, height: 128)
        let demagBilinearOut = TestPatterns.makeOutputTexture(device: device, width: 128, height: 128)
        let cbDemag = try #require(queue.makeCommandBuffer())
        try renderer.encodeDemagnifyPass(source: src2x, destination: demagNearestOut, mode: .nearest, commandBuffer: cbDemag)
        try renderer.encodeDemagnifyPass(source: src2x, destination: demagBilinearOut, mode: .bilinear, commandBuffer: cbDemag)
        cbDemag.commit()
        cbDemag.waitUntilCompleted()
        let dnStats = readbackStats(texture: demagNearestOut)
        let dbStats = readbackStats(texture: demagBilinearOut)
        #expect(dnStats.nanCount == 0 && dnStats.stdDevLuma > 0.05)
        #expect(dbStats.nanCount == 0 && dbStats.stdDevLuma > 0.05)

        // 6b. Crop + Letterbox (4:3 inside 16:9) + VRR Magenta Cursor Overlay + Cursor-Free PNG Export
        // Source 200x160 has 20px pure-red border and pure-green 160x120 interior.
        let borderedSrc = TestPatterns.makeBGRA8Texture(device: device, width: 200, height: 160) { x, y, w, h in
            if x < 20 || x >= w - 20 || y < 20 || y >= h - 20 {
                return (1.0, 0.0, 0.0, 1.0) // bright red margin to be cropped off
            }
            return (0.05, 0.85, 0.15, 1.0) // vivid green interior
        }
        let cursorTex = TestPatterns.solidColor(device: device, width: 16, height: 16, r: 1.0, g: 0.0, b: 1.0, a: 1.0)
        renderer.presentOverlayOptions = PresentOverlayOptions(
            cursorTexture: cursorTex,
            cursorRectNormalized: CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10),
            cursorNearest: true
        )

        let crop = CropInsets(enabled: true, left: 20, top: 20, right: 20, bottom: 20)
        let mode = ScalingMode(name: "Bicubic", effects: [EffectInstance(effectID: .bicubic, scalingType: .fit)])
        let layout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 200, height: 160),
            targetPixelSize: PixelSize(width: 320, height: 180),
            backingScaleFactor: 1.0,
            crop: crop,
            effects: mode.effects,
            alignment: .center
        )
        // Cropped 160x120 (4:3) centered inside 320x180 (16:9) => 240x180 at x=40..280, black bars at x=0..39 and x=280..319
        #expect(layout.visibleContentPixelRect.x == 40)
        #expect(layout.visibleContentPixelRect.width == 240)

        let presentedTex = TestPatterns.makeOutputTexture(device: device, width: 320, height: 180)
        let cb = try #require(queue.makeCommandBuffer())
        _ = try renderer.encode(
            scalingMode: mode,
            context: EffectRenderContext(
                device: device,
                commandBuffer: cb,
                sourceTexture: borderedSrc,
                destinationTexture: presentedTex,
                layout: layout,
                duplicateFrameMode: .never
            )
        )
        cb.commit()
        cb.waitUntilCompleted()

        let presented = readbackStats(texture: presentedTex)
        // Left letterbox bar (x=10, y=90) MUST be pure black.
        let leftBarIdx = (90 * 320 + 10) * 4
        #expect(presented.pixelsRGBA[leftBarIdx + 0] < 0.01)
        #expect(presented.pixelsRGBA[leftBarIdx + 1] < 0.01)
        #expect(presented.pixelsRGBA[leftBarIdx + 2] < 0.01)

        // Cropped green interior outside cursor (x=80, y=90) MUST be vivid green (zero red margin leak!).
        let greenIdx = (90 * 320 + 80) * 4
        #expect(presented.pixelsRGBA[greenIdx + 1] > 0.75)
        #expect(presented.pixelsRGBA[greenIdx + 0] < 0.15)

        // Center pixel (x=160, y=90) MUST show the composited magenta VRR cursor!
        let centerIdx = (90 * 320 + 160) * 4
        #expect(presented.pixelsRGBA[centerIdx + 0] > 0.85, "Presented frame should composite VRR cursor red channel")
        #expect(presented.pixelsRGBA[centerIdx + 2] > 0.85, "Presented frame should composite VRR cursor blue channel")
        #expect(presented.pixelsRGBA[centerIdx + 1] < 0.15, "Presented frame should composite VRR cursor green=0")

        // Cursor-Free PNG Screenshot Export MUST have valid PNG header AND NO magenta cursor at its center!
        let pngData = try renderer.captureLastOutputPNGData()
        #expect(pngData.count > 100)
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(Array(pngData.prefix(8)) == pngMagic, "Exported data must be a valid PNG file")

        let cursorFreeCG = try renderer.captureLastOutputImage()
        #expect(cursorFreeCG.width == 240 && cursorFreeCG.height == 180)
        let cfRGBA = readbackCGImageRGBA(cursorFreeCG)
        let cfCenterIdx = ((cursorFreeCG.height / 2) * cursorFreeCG.width + (cursorFreeCG.width / 2)) * 4
        #expect(cfRGBA[cfCenterIdx + 1] > 180, "Cursor-free screenshot center must remain green")
        #expect(cfRGBA[cfCenterIdx + 0] < 40, "Cursor-free screenshot must NOT bake the magenta cursor!")
    }

    // 7. MetalFX Spatial Scaler (SDR + HDR RGBA16Float)
    @Test("MetalFXEffect executes both SDR (.perceptual) and HDR (.rgba16Float) cleanly")
    func verifyMetalFXSDRAndHDR() throws {
        let (device, queue) = try Self.requireDeviceAndQueue()
        let pool = TexturePool(device: device)
        let mfx = MetalFXEffect(device: device)
        #expect(mfx.isSupported == true)

        // SDR pass
        let sdrSrc = TestPatterns.diagonalEdges(device: device, width: 320, height: 180)
        let sdrDst = TestPatterns.makeOutputTexture(device: device, width: 640, height: 360, pixelFormat: .bgra8Unorm)
        let cbSDR = try #require(queue.makeCommandBuffer())
        let ranSDR = try mfx.encode(commandBuffer: cbSDR, source: sdrSrc, destination: sdrDst, colorProcessingMode: .perceptual, texturePool: pool)
        cbSDR.commit()
        cbSDR.waitUntilCompleted()
        #expect(ranSDR == true)
        let sdrStats = readbackStats(texture: sdrDst)
        #expect(sdrStats.nanCount == 0 && sdrStats.infCount == 0 && sdrStats.stdDevLuma > 0.05)

        // HDR pass with > 1.0 specular highlights in RGBA16Float
        let hdrSrc = TestPatterns.makeRGBA16FTexture(device: device, width: 320, height: 180) { x, y, w, h in
            let dx = Float(x - w / 2) / Float(w)
            let dy = Float(y - h / 2) / Float(h)
            if dx * dx + dy * dy < 0.04 {
                return (2.2, 1.9, 1.4, 1.0) // bright HDR sun > 1.0
            }
            return (0.15, 0.25, 0.45, 1.0)
        }
        let hdrDst = TestPatterns.makeOutputTexture(device: device, width: 640, height: 360, pixelFormat: .rgba16Float)
        let cbHDR = try #require(queue.makeCommandBuffer())
        let ranHDR = try mfx.encode(commandBuffer: cbHDR, source: hdrSrc, destination: hdrDst, colorProcessingMode: .hdr, texturePool: pool)
        cbHDR.commit()
        cbHDR.waitUntilCompleted()
        #expect(ranHDR == true)
        let hdrStats = readbackStats(texture: hdrDst)
        #expect(hdrStats.nanCount == 0 && hdrStats.infCount == 0)
        #expect(hdrStats.maxChannelValue > 1.3, "HDR MetalFX pass must preserve >1.0 EDR highlights (got \(hdrStats.maxChannelValue))")
        #expect(mfx.cachedScalerCount == 2)
    }

    // 8. VideoToolbox ML Super Resolution + ML Frame Interpolation + OpticalFlowFallback + Artifact Guard
    @Test("VideoToolbox ML SuperRes, ML Frame Interpolation, OpticalFlowFallback, and Artifact Guard")
    func verifyVideoToolboxMLAndOpticalFlow() throws {
        let (device, queue) = try Self.requireDeviceAndQueue()
        let shaderManager = try ShaderLibraryManager(device: device)
        let pool = TexturePool(device: device)
        let vtML = VideoToolboxMLProcessor(device: device, shaderManager: shaderManager, texturePool: pool)

        // 8a. VideoToolbox ML Super Resolution (640x360 -> 1280x720 2x)
        if VideoToolboxSuperResolution.isSupportedOnSystem {
            let srSrc = TestPatterns.diagonalEdges(device: device, width: 640, height: 360)
            let srDst = TestPatterns.makeOutputTexture(device: device, width: 1280, height: 720)
            let cbSR = try #require(queue.makeCommandBuffer())
            let okSR = try vtML.superResolution.encode(
                commandBuffer: cbSR,
                source: srSrc,
                destination: srDst,
                requestedScaleFactor: 2.0
            )
            cbSR.commit()
            cbSR.waitUntilCompleted()
            #expect(okSR == true, "VideoToolbox Low-Latency SR should run on macOS 26+ Apple Silicon")
            let srStats = readbackStats(texture: srDst)
            #expect(srStats.nanCount == 0 && srStats.infCount == 0 && srStats.stdDevLuma > 0.05)
        }

        // 8b. VideoToolbox ML Frame Interpolation (640x360, bright square moves x=260 -> x=284, mid expected ~272)
        let fiPrev = TestPatterns.shiftedBlockFrame(device: device, width: 640, height: 360, centerX: 260, centerY: 180, halfSize: 32)
        let fiCurr = TestPatterns.shiftedBlockFrame(device: device, width: 640, height: 360, centerX: 284, centerY: 180, halfSize: 32)
        let fiMid = TestPatterns.makeOutputTexture(device: device, width: 640, height: 360)
        let fiSettings = FrameGenSettings(enabled: true, multiplier: .x2, backend: .videoToolboxML, artifactGuardSensitivity: .balanced)
        try vtML.prepare(width: 640, height: 360, settings: fiSettings)

        let cbFI = try #require(queue.makeCommandBuffer())
        let synthesizedVT = try vtML.encode(request: FrameGenRequest(
            previousTexture: fiPrev,
            currentTexture: fiCurr,
            outputTexture: fiMid,
            interpolationFactor: 0.5,
            commandBuffer: cbFI,
            settings: fiSettings
        ))
        cbFI.commit()
        cbFI.waitUntilCompleted()
        #expect(synthesizedVT == true)
        let fiStats = readbackStats(texture: fiMid)
        #expect(fiStats.nanCount == 0 && fiStats.infCount == 0)
        let midX = try #require(brightCentroidX(fiStats), "Interpolated frame must contain bright moving block")
        #expect(midX > 263.0 && midX < 281.0, "Expected VT ML interpolated centroid near 272, got \(midX)")
        print(String(format: "[VT ML FrameGen] prevX=260 currX=284 -> interpolated centroidX=%.2f (backend=%@)", midX, vtML.backendName))

        // 8c. Metal Optical Flow Fallback directly (320x180, block moves x=120 -> x=136, mid expected ~128)
        let ofPrev = TestPatterns.shiftedBlockFrame(device: device, width: 320, height: 180, centerX: 120, centerY: 90, halfSize: 22)
        let ofCurr = TestPatterns.shiftedBlockFrame(device: device, width: 320, height: 180, centerX: 136, centerY: 90, halfSize: 22)
        let ofMid = TestPatterns.makeOutputTexture(device: device, width: 320, height: 180)
        let ofSettings = FrameGenSettings(enabled: true, multiplier: .x2, backend: .metalOpticalFlow, artifactGuardSensitivity: .balanced)
        let cbOF = try #require(queue.makeCommandBuffer())
        let synthesizedOF = try vtML.encode(request: FrameGenRequest(
            previousTexture: ofPrev,
            currentTexture: ofCurr,
            outputTexture: ofMid,
            interpolationFactor: 0.5,
            commandBuffer: cbOF,
            settings: ofSettings
        ))
        cbOF.commit()
        cbOF.waitUntilCompleted()
        #expect(synthesizedOF == true)
        let ofStats = readbackStats(texture: ofMid)
        #expect(ofStats.nanCount == 0 && ofStats.infCount == 0)
        let ofMidX = try #require(brightCentroidX(ofStats), "Optical flow frame must contain bright moving block")
        #expect(ofMidX > 122.0 && ofMidX < 134.0, "Expected OpticalFlow interpolated centroid near 128, got \(ofMidX)")
        print(String(format: "[OpticalFlowFallback] prevX=120 currX=136 -> interpolated centroidX=%.2f", ofMidX))

        // 8d. Artifact Guard scene-cut detection (hard dark -> bright cut MUST return false!)
        let darkFrame = TestPatterns.solidColor(device: device, width: 320, height: 180, r: 0.04, g: 0.04, b: 0.04)
        let brightFrame = TestPatterns.solidColor(device: device, width: 320, height: 180, r: 0.96, g: 0.96, b: 0.96)
        let cutOut = TestPatterns.makeOutputTexture(device: device, width: 320, height: 180)
        let cbCut = try #require(queue.makeCommandBuffer())
        let cutSynthesized = try vtML.opticalFlowFallback.encode(request: FrameGenRequest(
            previousTexture: darkFrame,
            currentTexture: brightFrame,
            outputTexture: cutOut,
            interpolationFactor: 0.5,
            commandBuffer: cbCut,
            settings: ofSettings
        ))
        cbCut.commit()
        cbCut.waitUntilCompleted()
        #expect(cutSynthesized == false, "Artifact Guard must reject hard scene cuts and fall back cleanly")

        vtML.reset()
    }

    // 9. Live Preview API + Real Apple M4 Pro GPU Shader Benchmark
    @Test("Live Preview CGImage rendering and real Apple Silicon GPU Shader Benchmark across all 22 effects")
    func verifyPreviewAndM4ProGPUBenchmark() throws {
        let (device, _) = try Self.requireDeviceAndQueue()
        let renderer = try EffectChainRenderer(device: device)

        // 9a. Live Preview CGImage API
        let srcCG = TestPatterns.makeCGImage(width: 320, height: 180)
        let previewCG = try renderer.renderPreview(
            sourceImage: srcCG,
            scalingMode: ScalingMode.builtInPresets[1], // FSR 1.0
            outputSize: PixelSize(width: 640, height: 360)
        )
        #expect(previewCG.width == 640 && previewCG.height == 360)
        let previewBytes = readbackCGImageRGBA(previewCG)
        let nonZeroPixels = stride(from: 0, to: previewBytes.count, by: 4).filter { previewBytes[$0] > 10 || previewBytes[$0 + 1] > 10 || previewBytes[$0 + 2] > 10 }.count
        #expect(nonZeroPixels > (640 * 360) / 2, "Preview CGImage should contain real upscaled visual content")

        // 9b. Real Apple M4 Pro GPU Benchmark (720p -> 1440p)
        let benchResults = try renderer.runBenchmark(
            inputSize: PixelSize(width: 1280, height: 720),
            outputSize: PixelSize(width: 2560, height: 1440),
            iterations: 4
        )
        #expect(benchResults.count == EffectID.allCases.count)

        print("=== MetalPie Real GPU Benchmark (\(device.name)) 1280x720 -> 2560x1440 ===")
        for res in benchResults {
            let statusStr = res.succeeded ? "OK" : "FAIL(\(res.note ?? ""))"
            print(String(
                format: "  %-26s | %4dx%-4d -> %4dx%-4d | avg %6.3f ms (min %.3f, max %.3f) | %7.1f FPS | %@",
                (res.effectID.rawValue as NSString).utf8String!,
                res.inputSize.width, res.inputSize.height,
                res.outputSize.width, res.outputSize.height,
                res.averageGPUMilliseconds,
                res.minGPUMilliseconds,
                res.maxGPUMilliseconds,
                res.estimatedFPS,
                statusStr
            ))
            #expect(res.succeeded == true, "Benchmark failed for \(res.effectID.rawValue): \(res.note ?? "")")
            #expect(res.averageGPUMilliseconds > 0.0, "Benchmark GPU ms must be > 0 for \(res.effectID.rawValue)")
        }
        print("==========================================================================")
    }

    // 10. Verifier Audit Regressions (Intermediate Output 1:1, Same-Queue SceneDiff, Cache Isolation, Demagnify+Crop)
    @Test("Verifier regressions: intermediate output buffer 1:1, live-cache isolation, concurrent MetalFX, demagnify+crop")
    func verifyAuditRegressions() async throws {
        let (device, queue) = try Self.requireDeviceAndQueue()
        let renderer = try EffectChainRenderer(device: device)

        let commitSync: (any MTLCommandBuffer) -> Void = { cmd in
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        // 10a. Intermediate output buffer mode (dstTex sized to layout.finalOutputPixelSize != targetPixelSize):
        // Test Fit letterbox (4:3 -> 16:9), IntegerFit, and Fill (16:9 -> 4:3) + duplicate-skip frame!
        let cases: [(String, PixelSize, PixelSize, ScalingType)] = [
            ("FitLetterbox", PixelSize(width: 160, height: 120), PixelSize(width: 320, height: 180), .fit),
            ("IntegerFit",   PixelSize(width: 96,  height: 72),  PixelSize(width: 320, height: 240), .integerFit),
            ("FillOverhang", PixelSize(width: 160, height: 90),  PixelSize(width: 240, height: 180), .fill)
        ]

        for (label, srcSize, targetSize, scalingType) in cases {
            renderer.reset()
            let greenSrc = TestPatterns.solidColor(device: device, width: srcSize.width, height: srcSize.height, r: 0.05, g: 0.90, b: 0.10)
            let mode = ScalingMode(name: label, effects: [EffectInstance(effectID: .bicubic, scalingType: scalingType)])
            let layout = ScalingLayoutCalculator.calculate(
                sourcePixelSize: srcSize,
                targetPixelSize: targetSize,
                backingScaleFactor: 1.0,
                effects: mode.effects,
                alignment: .center
            )
            let interSize = layout.finalOutputPixelSize
            #expect(interSize != targetSize, "\(label) should exercise finalOutputPixelSize != targetPixelSize")

            // Frame 1 (fresh) + Frame 2 (duplicate-skip) both targeting intermediate buffer!
            for frameIdx in UInt64(1)...2 {
                let dstTex = TestPatterns.makeOutputTexture(device: device, width: interSize.width, height: interSize.height)
                let cb = try #require(queue.makeCommandBuffer())
                let rep = try renderer.encode(
                    scalingMode: mode,
                    context: EffectRenderContext(
                        device: device,
                        commandBuffer: cb,
                        sourceTexture: greenSrc,
                        destinationTexture: dstTex,
                        layout: layout,
                        frameIndex: frameIdx,
                        duplicateFrameMode: .always
                    )
                )
                commitSync(cb)
                #expect(rep.wasDuplicateFrameSkipped == (frameIdx == 2), "\(label) frame \(frameIdx) dup skip mismatch")

                let stats = readbackStats(texture: dstTex)
                let samplePoints = [
                    (0, 0),
                    (interSize.width - 1, 0),
                    (0, interSize.height - 1),
                    (interSize.width - 1, interSize.height - 1),
                    (interSize.width / 2, interSize.height / 2)
                ]
                for (px, py) in samplePoints {
                    let idx = (py * interSize.width + px) * 4
                    #expect(stats.pixelsRGBA[idx + 1] > 0.75, "\(label) frame \(frameIdx) corner/center (\(px),\(py)) must stay vivid green without letterbox/clip (got G=\(stats.pixelsRGBA[idx + 1]))")
                }
            }
        }

        // 10b. Live-cache isolation: renderPreview & runBenchmark must NOT clobber live lastCursorFreeOutput!
        renderer.reset()
        let liveGreen = TestPatterns.solidColor(device: device, width: 160, height: 90, r: 0.05, g: 0.92, b: 0.12)
        let liveMode = ScalingMode(name: "LiveGreen", effects: [EffectInstance(effectID: .bilinear, scalingType: .fit)])
        let liveLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 160, height: 90),
            targetPixelSize: PixelSize(width: 320, height: 180),
            backingScaleFactor: 1.0,
            effects: liveMode.effects
        )
        let liveDst = TestPatterns.makeOutputTexture(device: device, width: 320, height: 180)
        let cbLive = try #require(queue.makeCommandBuffer())
        _ = try renderer.encode(
            scalingMode: liveMode,
            context: EffectRenderContext(device: device, commandBuffer: cbLive, sourceTexture: liveGreen, destinationTexture: liveDst, layout: liveLayout, duplicateFrameMode: .always)
        )
        commitSync(cbLive)

        // Now run preview (different image) and benchmark on the SAME renderer instance!
        let previewCG = TestPatterns.makeCGImage(width: 160, height: 90)
        _ = try renderer.renderPreview(sourceImage: previewCG, scalingMode: liveMode, outputSize: PixelSize(width: 320, height: 180))
        _ = try renderer.runBenchmark(effects: [.bicubic], inputSize: PixelSize(width: 160, height: 90), outputSize: PixelSize(width: 320, height: 180), iterations: 1)

        // Live cursor-free snapshot MUST still be the original solid green 320x180 frame!
        let liveSnap = try renderer.captureLastOutputImage()
        #expect(liveSnap.width == 320 && liveSnap.height == 180)
        let snapRGBA = readbackCGImageRGBA(liveSnap)
        let snapCenter = ((90 * 320) + 160) * 4
        #expect(snapRGBA[snapCenter + 1] > 200 && snapRGBA[snapCenter + 0] < 40, "Preview/Benchmark must not clobber live cursor-free snapshot!")

        // 10c. Concurrent MetalFXEffect encode at identical resolution (tests per-scaler lock safety).
        let mfxPool = TexturePool(device: device)
        let mfx = MetalFXEffect(device: device)
        final class DeviceBox: @unchecked Sendable {
            let device: any MTLDevice
            init(_ device: any MTLDevice) { self.device = device }
        }
        let devBox = DeviceBox(device)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let dev = devBox.device
                    let q = try #require(dev.makeCommandQueue())
                    let src = TestPatterns.diagonalEdges(device: dev, width: 320, height: 180)
                    let dst = TestPatterns.makeOutputTexture(device: dev, width: 640, height: 360)
                    let cb = try #require(q.makeCommandBuffer())
                    let ok = try mfx.encode(commandBuffer: cb, source: src, destination: dst, colorProcessingMode: .perceptual, texturePool: mfxPool)
                    #expect(ok == true)
                    let syncCommit: (any MTLCommandBuffer) -> Void = { c in c.commit(); c.waitUntilCompleted() }
                    syncCommit(cb)
                    let s = readbackStats(texture: dst)
                    #expect(s.nanCount == 0 && s.stdDevLuma > 0.05)
                }
            }
            try await group.waitForAll()
        }

        // 10c-2. Same-queue GPU FIFO synchronization for measureSceneDiff (back-to-back GPU write -> scene-cut check)
        let darkSrc = TestPatterns.solidColor(device: device, width: 320, height: 180, r: 0.03, g: 0.03, b: 0.03)
        let brightSrc = TestPatterns.solidColor(device: device, width: 320, height: 180, r: 0.96, g: 0.96, b: 0.96)
        let gpuPrev = TestPatterns.makeOutputTexture(device: device, width: 320, height: 180)
        let gpuCurr = TestPatterns.makeOutputTexture(device: device, width: 320, height: 180)
        let gpuCutOut = TestPatterns.makeOutputTexture(device: device, width: 320, height: 180)
        // Commit GPU blits onto `queue` WITHOUT waiting on CPU, then immediately encode FrameGen on `queue`!
        let cbWrite = try #require(queue.makeCommandBuffer())
        if let blit = cbWrite.makeBlitCommandEncoder() {
            blit.copy(from: darkSrc, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: 320, height: 180, depth: 1), to: gpuPrev, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.copy(from: brightSrc, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: 320, height: 180, depth: 1), to: gpuCurr, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        cbWrite.commit() // intentionally NOT waiting before invoking encode!
        let cbFG = try #require(queue.makeCommandBuffer())
        let fgSettings = FrameGenSettings(enabled: true, multiplier: .x2, backend: .metalOpticalFlow, artifactGuardSensitivity: .balanced)
        let cutResult = try renderer.videoToolboxML.encode(request: FrameGenRequest(
            previousTexture: gpuPrev,
            currentTexture: gpuCurr,
            outputTexture: gpuCutOut,
            interpolationFactor: 0.5,
            commandBuffer: cbFG,
            settings: fgSettings
        ))
        commitSync(cbFG)
        #expect(cutResult == false, "Same-queue measureSceneDiff must observe prior in-flight GPU writes and detect hard cut")

        // 10d. DemagnifyMode != .none + CropInsets(enabled: true) coordinate scaling!
        renderer.reset()
        renderer.demagnifyMode = .bilinear
        defer { renderer.demagnifyMode = .none }
        // 400x320 2x-magnified frame with 40px pure red border and vivid green 320x240 interior.
        let wine2xSrc = TestPatterns.makeBGRA8Texture(device: device, width: 400, height: 320) { x, y, w, h in
            if x < 40 || x >= w - 40 || y < 40 || y >= h - 40 {
                return (1.0, 0.0, 0.0, 1.0)
            }
            return (0.05, 0.90, 0.12, 1.0)
        }
        let demagCrop = CropInsets(enabled: true, left: 40, top: 40, right: 40, bottom: 40)
        let demagMode = ScalingMode(name: "DemagCrop", effects: [EffectInstance(effectID: .bicubic, scalingType: .fit)])
        let demagLayout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: 400, height: 320),
            targetPixelSize: PixelSize(width: 320, height: 240),
            backingScaleFactor: 1.0,
            crop: demagCrop,
            effects: demagMode.effects
        )
        let demagDst = TestPatterns.makeOutputTexture(device: device, width: 320, height: 240)
        let cbDemagCrop = try #require(queue.makeCommandBuffer())
        _ = try renderer.encode(
            scalingMode: demagMode,
            context: EffectRenderContext(
                device: device,
                commandBuffer: cbDemagCrop,
                sourceTexture: wine2xSrc,
                destinationTexture: demagDst,
                layout: demagLayout,
                duplicateFrameMode: .never
            )
        )
        commitSync(cbDemagCrop)
        let dcStats = readbackStats(texture: demagDst)
        // Verify interior and near-edge pixels are vivid green with ZERO red border bleed!
        for (px, py) in [(8, 8), (311, 8), (8, 231), (311, 231), (160, 120)] {
            let idx = (py * 320 + px) * 4
            #expect(dcStats.pixelsRGBA[idx + 1] > 0.70, "Demagnify+Crop (\(px),\(py)) should be green")
            #expect(dcStats.pixelsRGBA[idx + 0] < 0.20, "Demagnify+Crop (\(px),\(py)) leaked red border (R=\(dcStats.pixelsRGBA[idx + 0]))")
        }
    }
}
