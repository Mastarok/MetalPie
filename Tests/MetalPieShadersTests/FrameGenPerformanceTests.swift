import Foundation
import Metal
import MetalPieCore
import MetalPieShaders
import QuartzCore
import Testing

@Suite("Frame Generation GPU Performance & Zero-Stall Benchmarks", .serialized)
struct FrameGenPerformanceTests {
    private static func makeMovingSceneTexture(
        device: any MTLDevice,
        width: Int,
        height: Int,
        boxCenterX: Int,
        boxCenterY: Int,
        boxHalfSize: Int
    ) throws -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = try #require(device.makeTexture(descriptor: desc))

        // Use a realistic full-screen panning checkerboard + moving foreground block so EVERY pixel moves
        // (prevents artificially cheap timings from static-pixel early-out).
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let panShift = boxCenterX - (width / 2)
        for y in 0..<height {
            let inY = abs(y - boxCenterY) <= boxHalfSize
            let tileY = (y / 32) & 1
            let bgG = UInt8(28 + (y * 36) / max(1, height))
            let rowOff = y * width * 4
            for x in 0..<width {
                let off = rowOff + x * 4
                if inY && abs(x - boxCenterX) <= boxHalfSize {
                    bytes[off + 0] = 245
                    bytes[off + 1] = 248
                    bytes[off + 2] = 250
                    bytes[off + 3] = 255
                } else {
                    let sx = x - panShift
                    let tileX = ((sx >= 0 ? sx : (sx + 4096)) / 32) & 1
                    let checker: UInt8 = ((tileX ^ tileY) == 0) ? 22 : 0
                    bytes[off + 0] = 42 &+ checker
                    bytes[off + 1] = bgG &+ checker
                    bytes[off + 2] = UInt8(20 + ((abs(sx) * 28) / max(1, width)) % 40) &+ checker
                    bytes[off + 3] = 255
                }
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

    private static func makePrivateOutput(
        device: any MTLDevice,
        width: Int,
        height: Int,
        storageMode: MTLStorageMode = .private
    ) throws -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = storageMode
        return try #require(device.makeTexture(descriptor: desc))
    }

    private static func brightCentroidX(texture: any MTLTexture) -> Double? {
        let w = texture.width
        let h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var sumX = 0.0
        var count = 0.0
        for y in stride(from: 0, to: h, by: 2) {
            let row = y * w * 4
            for x in stride(from: 0, to: w, by: 2) {
                let off = row + x * 4
                let luma = (Int(bytes[off + 2]) * 2 + Int(bytes[off + 1]) * 7 + Int(bytes[off + 0])) / 10
                if luma > 180 {
                    sumX += Double(x)
                    count += 1.0
                }
            }
        }
        return count > 0 ? (sumX / count) : nil
    }

    @Test("FG interpolation GPU pass is < 3 ms at 1920x1080, 2560x1440, and 3024x1964 Retina with zero CPU stalls")
    func benchmarkFrameGenHighResSub3Ms() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let shaderManager = try ShaderLibraryManager(device: device)
        let pool = TexturePool(device: device)
        let fg = VideoToolboxMLProcessor(device: device, shaderManager: shaderManager, texturePool: pool)

        let settings = FrameGenSettings(
            enabled: true,
            multiplier: .x2,
            backend: .auto,
            artifactGuardSensitivity: .balanced
        )

        let resolutions: [(label: String, w: Int, h: Int)] = [
            ("1080p", 1920, 1080),
            ("1440p", 2560, 1440),
            ("Retina3K", 3024, 1964)
        ]

        print("=== MetalPie Frame Generation GPU Benchmark (\(device.name)) ===")
        for (label, w, h) in resolutions {
            try fg.prepare(width: w, height: h, settings: settings)

            let prevCenterX = w / 2 - 24
            let currCenterX = w / 2 + 24
            let prevTex = try Self.makeMovingSceneTexture(
                device: device,
                width: w,
                height: h,
                boxCenterX: prevCenterX,
                boxCenterY: h / 2,
                boxHalfSize: 64
            )
            let currTex = try Self.makeMovingSceneTexture(
                device: device,
                width: w,
                height: h,
                boxCenterX: currCenterX,
                boxCenterY: h / 2,
                boxHalfSize: 64
            )
            let outPrivate = try Self.makePrivateOutput(device: device, width: w, height: h, storageMode: .private)

            // Warmup iterations (populates TexturePool + GPU caches).
            for _ in 0..<2 {
                let cb = try #require(queue.makeCommandBuffer())
                _ = try fg.encode(request: FrameGenRequest(
                    previousTexture: prevTex,
                    currentTexture: currTex,
                    outputTexture: outPrivate,
                    interpolationFactor: 0.5,
                    commandBuffer: cb,
                    settings: settings
                ))
                #expect(cb.status == .notEnqueued, "encode() must NEVER synchronously commit or waitUntilCompleted()")
                cb.commit()
                cb.waitUntilCompleted()
            }

            // Timed iterations measuring true Metal GPU execution time & CPU encode overhead.
            var gpuMsSamples: [Double] = []
            var cpuEncodeMsSamples: [Double] = []
            let iterations = 8
            for _ in 0..<iterations {
                let cb = try #require(queue.makeCommandBuffer())
                let t0 = CACurrentMediaTime()
                let ok = try fg.encode(request: FrameGenRequest(
                    previousTexture: prevTex,
                    currentTexture: currTex,
                    outputTexture: outPrivate,
                    interpolationFactor: 0.5,
                    commandBuffer: cb,
                    settings: settings
                ))
                let encodeMs = (CACurrentMediaTime() - t0) * 1000.0
                #expect(ok == true)
                #expect(cb.status == .notEnqueued)
                cb.commit()
                cb.waitUntilCompleted()

                let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
                gpuMsSamples.append(gpuMs)
                cpuEncodeMsSamples.append(encodeMs)
            }

            let avgGpuMs = gpuMsSamples.reduce(0, +) / Double(gpuMsSamples.count)
            let minGpuMs = gpuMsSamples.min() ?? 0
            let maxGpuMs = gpuMsSamples.max() ?? 0
            let avgCpuMs = cpuEncodeMsSamples.reduce(0, +) / Double(cpuEncodeMsSamples.count)

            // Verify motion-compensated midpoint accuracy at full resolution!
            let outShared = try Self.makePrivateOutput(device: device, width: w, height: h, storageMode: .shared)
            let cbCheck = try #require(queue.makeCommandBuffer())
            _ = try fg.encode(request: FrameGenRequest(
                previousTexture: prevTex,
                currentTexture: currTex,
                outputTexture: outShared,
                interpolationFactor: 0.5,
                commandBuffer: cbCheck,
                settings: settings
            ))
            cbCheck.commit()
            cbCheck.waitUntilCompleted()
            let midX = try #require(Self.brightCentroidX(texture: outShared))
            let expectedMid = Double(w) / 2.0

            let paddedLabel = label.padding(toLength: 9, withPad: " ", startingAt: 0)
            print(String(
                format: "  %@ (%4dx%-4d) | backend=%@ | avgGPU=%.3f ms (min=%.3f, max=%.3f) | cpuEncode=%.3f ms | midX=%.1f (exp %.1f)",
                paddedLabel, w, h, fg.backendName, avgGpuMs, minGpuMs, maxGpuMs, avgCpuMs, midX, expectedMid
            ))

            #expect(avgGpuMs < 3.0, "\(label) (\(w)x\(h)) FG GPU time \(avgGpuMs) ms exceeded 3.0 ms budget!")
            #expect(avgCpuMs < 1.5, "\(label) (\(w)x\(h)) CPU encode time \(avgCpuMs) ms indicates synchronous stall!")
            #expect(abs(midX - expectedMid) < 12.0, "\(label) expected interpolated centroid near \(expectedMid), got \(midX)")
        }
        print("=================================================================")
    }

    @Test("Triple-buffered pipelined FG + EffectChainRenderer submits 6 frames back-to-back with zero stalls")
    func verifyZeroStallTripleBufferedPipeline() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try EffectChainRenderer(device: device)
        let fg = renderer.videoToolboxML

        let w = 1920, h = 1080
        let fgSettings = FrameGenSettings(enabled: true, multiplier: .x2, backend: .auto, artifactGuardSensitivity: .balanced)
        try fg.prepare(width: w, height: h, settings: fgSettings)

        let prevTex = try Self.makeMovingSceneTexture(device: device, width: w, height: h, boxCenterX: 900, boxCenterY: 540, boxHalfSize: 48)
        let currTex = try Self.makeMovingSceneTexture(device: device, width: w, height: h, boxCenterX: 960, boxCenterY: 540, boxHalfSize: 48)
        let fgOutputs = try (0..<3).map { _ in try Self.makePrivateOutput(device: device, width: w, height: h) }
        let dstOutputs = try (0..<3).map { _ in try Self.makePrivateOutput(device: device, width: w, height: h) }

        let mode = ScalingMode.builtInPresets.first { $0.id == ScalingMode.bicubicCASID } ?? ScalingMode.defaultMode
        let layout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: PixelSize(width: w, height: h),
            targetPixelSize: PixelSize(width: w, height: h),
            backingScaleFactor: 2.0,
            effects: mode.effects
        )

        // Warmup once
        let warmCB = try #require(queue.makeCommandBuffer())
        _ = try fg.encode(request: FrameGenRequest(previousTexture: prevTex, currentTexture: currTex, outputTexture: fgOutputs[0], interpolationFactor: 0.5, commandBuffer: warmCB, settings: fgSettings))
        _ = try renderer.encode(scalingMode: mode, context: EffectRenderContext(device: device, commandBuffer: warmCB, sourceTexture: fgOutputs[0], destinationTexture: dstOutputs[0], layout: layout, duplicateFrameMode: .dynamic))
        warmCB.commit()
        warmCB.waitUntilCompleted()

        // Submit 6 full FG + EffectChain frames WITHOUT waiting between commits.
        // If any synchronous waitUntilCompleted() existed, encode time would equal total GPU time (~10+ ms).
        var commandBuffers: [any MTLCommandBuffer] = []
        let encodeStart = CACurrentMediaTime()
        for i in 0..<6 {
            let slot = i % 3
            let cb = try #require(queue.makeCommandBuffer())
            _ = try fg.encode(request: FrameGenRequest(
                previousTexture: prevTex,
                currentTexture: currTex,
                outputTexture: fgOutputs[slot],
                interpolationFactor: 0.5,
                commandBuffer: cb,
                settings: fgSettings
            ))
            _ = try renderer.encode(
                scalingMode: mode,
                context: EffectRenderContext(
                    device: device,
                    commandBuffer: cb,
                    sourceTexture: fgOutputs[slot],
                    destinationTexture: dstOutputs[slot],
                    layout: layout,
                    frameIndex: UInt64(i + 1),
                    duplicateFrameMode: .dynamic
                )
            )
            #expect(cb.status == .notEnqueued, "Neither FG nor EffectChainRenderer may stall or pre-commit commandBuffer")
            cb.commit()
            commandBuffers.append(cb)
        }
        let totalCpuSubmitMs = (CACurrentMediaTime() - encodeStart) * 1000.0

        for cb in commandBuffers {
            cb.waitUntilCompleted()
            #expect(cb.error == nil, "Pipelined command buffer failed: \(cb.error?.localizedDescription ?? "")")
        }

        let totalGpuMs = commandBuffers.reduce(0.0) { $0 + ($1.gpuEndTime - $1.gpuStartTime) * 1000.0 }
        print(String(format: "[Zero-Stall 6-Frame Burst 1080p FG+CAS] totalCPUSubmit=%.2f ms | totalGPU=%.2f ms (avg %.2f ms/frame)", totalCpuSubmitMs, totalGpuMs, totalGpuMs / 6.0))
        #expect(totalCpuSubmitMs < 6.0, "Submitting 6 pipelined frames took \(totalCpuSubmitMs) ms CPU — indicates synchronous GPU stall!")
    }

    @Test("Explicit VideoToolbox ML backend also runs GPU-only Artifact Guard with zero CPU stalls")
    func verifyVTMLZeroStallArtifactGuard() throws {
        guard VideoToolboxMLProcessor.isFrameInterpolationSupportedOnSystem else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let shaderManager = try ShaderLibraryManager(device: device)
        let pool = TexturePool(device: device)
        let vt = VideoToolboxMLProcessor(device: device, shaderManager: shaderManager, texturePool: pool)

        let w = 640, h = 360
        let settings = FrameGenSettings(enabled: true, multiplier: .x2, backend: .videoToolboxML, artifactGuardSensitivity: .balanced)
        try vt.prepare(width: w, height: h, settings: settings)

        let dark = try Self.makeMovingSceneTexture(device: device, width: w, height: h, boxCenterX: -100, boxCenterY: -100, boxHalfSize: 1)
        let bright = try Self.makeMovingSceneTexture(device: device, width: w, height: h, boxCenterX: w / 2, boxCenterY: h / 2, boxHalfSize: w)
        let out = try Self.makePrivateOutput(device: device, width: w, height: h, storageMode: .shared)

        let cb = try #require(queue.makeCommandBuffer())
        let ok = try vt.encode(request: FrameGenRequest(
            previousTexture: dark,
            currentTexture: bright,
            outputTexture: out,
            interpolationFactor: 0.5,
            commandBuffer: cb,
            settings: settings
        ))
        #expect(ok == true)
        #expect(cb.status == .notEnqueued, "VT ML encode must never stall or commit caller commandBuffer")
        cb.commit()
        cb.waitUntilCompleted()

        // Verify bright cut frame was output cleanly (mean luma > 0.85, not 0.50 gray ghost).
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let centerOff = ((h / 2) * w + (w / 2)) * 4
        #expect(bytes[centerOff + 1] > 210, "VT ML GPU Artifact Guard must snap hard cut cleanly to bright curr frame (got G=\(bytes[centerOff + 1]))")
        vt.reset()
    }
}
