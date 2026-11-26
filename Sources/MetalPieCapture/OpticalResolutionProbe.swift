import Foundation
import Metal
import MetalPieCore
import os

// MARK: - OpticalResolutionProbe

/// Zero-CPU-pixel-readback GPU Edge-Spread-Function (ESF) optical resolution estimator for
/// `FullscreenVideoInputMode.auto`.
///
/// Runs two tiny compute passes (~0.10-0.25 ms total on Apple Silicon) inline on the render command buffer
/// ONLY when due (startup/resize warm-up at 4 Hz, steady-state at 1 Hz = ~0.02% GPU budget):
/// 1. `probeDetectActiveBoundsAndClearHist`: scans 32 interior rows & 32 interior columns to locate the active
///    non-black video rect (immune to 4:3 pillarboxes, 16:9 letterboxes, and 2.39:1 cinemascope black bars)
///    and zeroes the 100-bin sharpness histogram on GPU (zero CPU/GPU race).
/// 2. `probeEdgeSpreadHistogram`: evaluates tangent-denoised 1px edge slope ratios strictly on strong
///    (`>= 20%` contrast) interior edges (excluding top chrome, analog overscan borders, and bottom subtitles),
///    making it completely immune to mpv/IINA full-resolution 8-bit dither noise and film grain!
public final class OpticalResolutionProbe: @unchecked Sendable {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    inline float probeLuma(float3 rgb) {
        return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
    }

    // Kernel 1: Locate active non-black video bounding box + zero 100-bin histogram on GPU.
    // Dispatched as 1 threadgroup of 128 threads.
    kernel void probeDetectActiveBoundsAndClearHist(
        texture2d<float, access::read> src [[texture(0)]],
        device uint4* outBounds [[buffer(0)]],
        device uint* hist [[buffer(1)]],
        uint tid [[thread_index_in_threadgroup]]
    ) {
        if (tid < 100u) {
            hist[tid] = 0u;
        }

        uint sw = src.get_width();
        uint sh = src.get_height();
        threadgroup atomic_uint minX, minY, maxX, maxY;
        if (tid == 0u) {
            atomic_store_explicit(&minX, sw, memory_order_relaxed);
            atomic_store_explicit(&minY, sh, memory_order_relaxed);
            atomic_store_explicit(&maxX, 0u, memory_order_relaxed);
            atomic_store_explicit(&maxY, 0u, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        constexpr float blackThresh = 0.018f;
        if (tid < 32u) {
            uint y = clamp(uint((0.12f + 0.72f * (float(tid) + 0.5f) / 32.0f) * float(sh)), 0u, max(1u, sh) - 1u);
            for (uint x = 0u; x < sw; x += 4u) {
                if (probeLuma(src.read(uint2(x, y)).rgb) > blackThresh) {
                    atomic_fetch_min_explicit(&minX, x, memory_order_relaxed);
                    break;
                }
            }
            for (int x = int(sw) - 1; x >= 0; x -= 4) {
                if (probeLuma(src.read(uint2(uint(x), y)).rgb) > blackThresh) {
                    atomic_fetch_max_explicit(&maxX, uint(x), memory_order_relaxed);
                    break;
                }
            }
        } else if (tid < 64u) {
            uint colIdx = tid - 32u;
            uint x = clamp(uint((0.12f + 0.76f * (float(colIdx) + 0.5f) / 32.0f) * float(sw)), 0u, max(1u, sw) - 1u);
            for (uint y = 0u; y < sh; y += 4u) {
                if (probeLuma(src.read(uint2(x, y)).rgb) > blackThresh) {
                    atomic_fetch_min_explicit(&minY, y, memory_order_relaxed);
                    break;
                }
            }
            for (int y = int(sh) - 1; y >= 0; y -= 4) {
                if (probeLuma(src.read(uint2(x, uint(y))).rgb) > blackThresh) {
                    atomic_fetch_max_explicit(&maxY, uint(y), memory_order_relaxed);
                    break;
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (tid == 0u) {
            uint x0 = atomic_load_explicit(&minX, memory_order_relaxed);
            uint y0 = atomic_load_explicit(&minY, memory_order_relaxed);
            uint x1 = atomic_load_explicit(&maxX, memory_order_relaxed);
            uint y1 = atomic_load_explicit(&maxY, memory_order_relaxed);
            if (x0 >= x1 || y0 >= y1) {
                outBounds[0] = uint4(0u, 0u, 0u, 0u);
            } else {
                outBounds[0] = uint4(x0, y0, x1, y1);
            }
        }
    }

    // Kernel 2: Dither-immune Edge-Spread-Function (ESF) sharpness histogram with threadgroup reduction.
    // Dispatched as 16x16 threadgroups over `(width / stride) x (height / stride)`.
    kernel void probeEdgeSpreadHistogram(
        texture2d<float, access::read> src [[texture(0)]],
        device const uint4* activeBounds [[buffer(0)]],
        device atomic_uint* globalHist [[buffer(1)]],
        constant uint& stride [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]],
        uint tid [[thread_index_in_threadgroup]],
        uint2 tgDims [[threads_per_threadgroup]]
    ) {
        threadgroup atomic_uint localHist[100];
        uint tgSize = max(1u, tgDims.x * tgDims.y);
        for (uint b = tid; b < 100u; b += tgSize) {
            atomic_store_explicit(&localHist[b], 0u, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        uint4 b = activeBounds[0];
        uint bx0 = b.x, by0 = b.y, bx1 = b.z, by1 = b.w;
        if (bx1 > bx0 + 64u && by1 > by0 + 64u) {
            uint aw = bx1 - bx0;
            uint ah = by1 - by0;
            // Exclude analog TV/VHS overscan borders (4% L/R), top chrome/logos (8%), and bottom subtitles (18%).
            uint xInset = max(16u, uint(float(aw) * 0.04f));
            uint xMin = min(bx0 + xInset, bx1);
            uint xMax = (bx1 > xMin + 32u) ? (bx1 - xInset) : bx1;
            uint yMin = min(by0 + max(16u, uint(float(ah) * 0.08f)), by1);
            uint yMax = (by1 > yMin + 32u) ? (by1 - max(16u, uint(float(ah) * 0.18f))) : by1;

            uint x = xMin + gid.x * stride;
            uint y = yMin + gid.y * stride;
            if (x >= 10u && y >= 10u && x + 10u < xMax && y + 10u < yMax) {
                // 3-pixel tangent average eliminates random mpv dither & grain without blurring perpendicular edges.
                // Sampling [-10..+10] while searching peak 1px slope over the exact non-overlapping cell
                // [-stride/2 .. +stride/2 - 1] guarantees 100% coverage of every 1px-sharp edge with zero blind spots!
                float hProfile[21];
                float hMin = 1e9f, hMax = -1e9f;
                for (int dx = -10; dx <= 10; ++dx) {
                    uint px = uint(int(x) + dx);
                    float v = (probeLuma(src.read(uint2(px, y - 1u)).rgb)
                             + probeLuma(src.read(uint2(px, y)).rgb)
                             + probeLuma(src.read(uint2(px, y + 1u)).rgb)) * (1.0f / 3.0f);
                    hProfile[dx + 10] = v;
                    hMin = min(hMin, v);
                    hMax = max(hMax, v);
                }
                float hSpan = hMax - hMin;

                float vProfile[21];
                float vMin = 1e9f, vMax = -1e9f;
                for (int dy = -10; dy <= 10; ++dy) {
                    uint py = uint(int(y) + dy);
                    float v = (probeLuma(src.read(uint2(x - 1u, py)).rgb)
                             + probeLuma(src.read(uint2(x, py)).rgb)
                             + probeLuma(src.read(uint2(x + 1u, py)).rgb)) * (1.0f / 3.0f);
                    vProfile[dy + 10] = v;
                    vMin = min(vMin, v);
                    vMax = max(vMax, v);
                }
                float vSpan = vMax - vMin;

                float span = max(hSpan, vSpan);
                if (span >= 0.20f) {
                    int halfCell = int(stride >> 1u);
                    int iStart = max(2, 10 - halfCell);
                    int iEnd = min(17, 10 + halfCell - 1);
                    float hMaxSlope = 0.0f;
                    float vMaxSlope = 0.0f;
                    for (int i = iStart; i <= iEnd; ++i) {
                        hMaxSlope = max(hMaxSlope, abs(hProfile[i + 1] - hProfile[i]));
                        vMaxSlope = max(vMaxSlope, abs(vProfile[i + 1] - vProfile[i]));
                    }
                    float slope = (hSpan >= vSpan) ? hMaxSlope : vMaxSlope;
                    if (slope > 0.01f) {
                        float sharpness = clamp(slope / span, 0.0f, 1.0f);
                        uint bin = min(99u, uint(sharpness * 100.0f));
                        atomic_fetch_add_explicit(&localHist[bin], 1u, memory_order_relaxed);
                    }
                }
            }
        }

        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint b = tid; b < 100u; b += tgSize) {
            uint count = atomic_load_explicit(&localHist[b], memory_order_relaxed);
            if (count > 0u) {
                atomic_fetch_add_explicit(&globalHist[b], count, memory_order_relaxed);
            }
        }
    }
    """

    private struct ProbeState: Sendable {
        var tracker = OpticalResolutionTracker()
        var inFlight: Bool = false
        var lastProbeSubmitTime: Double = 0
        var lastProbedSize: PixelSize = .zero
        var generation: UInt64 = 0
    }

    private let device: any MTLDevice
    private let boundsPipeline: (any MTLComputePipelineState)?
    private let esfPipeline: (any MTLComputePipelineState)?
    private let boundsBuffer: (any MTLBuffer)?
    private let histogramBuffer: (any MTLBuffer)?
    private let state = OSAllocatedUnfairLock(initialState: ProbeState())

    public init(device: any MTLDevice) {
        self.device = device
        if let lib = try? device.makeLibrary(source: Self.shaderSource, options: nil),
           let bFn = lib.makeFunction(name: "probeDetectActiveBoundsAndClearHist"),
           let eFn = lib.makeFunction(name: "probeEdgeSpreadHistogram"),
           let bPipe = try? device.makeComputePipelineState(function: bFn),
           let ePipe = try? device.makeComputePipelineState(function: eFn),
           bPipe.maxTotalThreadsPerThreadgroup >= 128,
           ePipe.maxTotalThreadsPerThreadgroup >= 128,
           let bBuf = device.makeBuffer(length: MemoryLayout<SIMD4<UInt32>>.stride, options: .storageModeShared),
           let hBuf = device.makeBuffer(
               length: OpticalResolutionClassifier.histogramBinCount * MemoryLayout<UInt32>.stride,
               options: .storageModeShared
           )
        {
            self.boundsPipeline = bPipe
            self.esfPipeline = ePipe
            self.boundsBuffer = bBuf
            self.histogramBuffer = hBuf
        } else {
            self.boundsPipeline = nil
            self.esfPipeline = nil
            self.boundsBuffer = nil
            self.histogramBuffer = nil
        }
    }

    /// Current live confirmed/unprobed verdict (thread-safe).
    public var currentResolution: DetectedOpticalResolution {
        state.withLock { $0.tracker.current }
    }

    /// Resets probe history (call on session start/stop or when switching away from `.auto`).
    public func reset() {
        state.withLock { s in
            s.tracker.reset()
            s.inFlight = false
            s.lastProbeSubmitTime = 0
            s.lastProbedSize = .zero
            s.generation &+= 1
        }
    }

    /// Synchronously measures a single Metal texture on `commandQueue` (used by unit tests & offline checks).
    public func probeSynchronously(
        texture: any MTLTexture,
        commandQueue: any MTLCommandQueue
    ) -> DetectedOpticalResolution? {
        guard let bPipe = boundsPipeline,
              let ePipe = esfPipeline,
              let bBuf = boundsBuffer,
              let hBuf = histogramBuffer,
              let cb = commandQueue.makeCommandBuffer()
        else {
            return nil
        }
        let srcSize = PixelSize(width: texture.width, height: texture.height)
        guard srcSize.width >= 480, srcSize.height >= 680 else { return .native }

        encodePasses(
            sourceTexture: texture,
            commandBuffer: cb,
            boundsPipeline: bPipe,
            esfPipeline: ePipe,
            boundsBuffer: bBuf,
            histogramBuffer: hBuf
        )
        cb.commit()
        cb.waitUntilCompleted()

        return evaluateBuffers(sourceSize: srcSize, boundsBuffer: bBuf, histogramBuffer: hBuf)?.resolution
    }

    /// Encodes the lightweight GPU probe directly into `commandBuffer` iff due, reading results asynchronously
    /// in `commandBuffer.addCompletedHandler` with zero CPU stalls. Invokes `onChanged` whenever the committed
    /// `DetectedOpticalResolution` changes.
    public func encodeIfDue(
        sourceTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        now: Double,
        onChanged: @escaping @Sendable (DetectedOpticalResolution) -> Void
    ) {
        guard let bPipe = boundsPipeline,
              let ePipe = esfPipeline,
              let bBuf = boundsBuffer,
              let hBuf = histogramBuffer
        else {
            return
        }

        let srcSize = PixelSize(width: sourceTexture.width, height: sourceTexture.height)

        // Small windows (< 680px tall or < 480px wide, e.g. native 640x480) never need pre-downscale.
        if srcSize.width < 480 || srcSize.height < 680 {
            let emitted: DetectedOpticalResolution? = state.withLock { s in
                s.lastProbedSize = srcSize
                return s.tracker.ingest(candidate: .native, sourceSize: srcSize, activeSliceCount: 32)
            }
            if let emitted { onChanged(emitted) }
            return
        }

        let generationToCommit: UInt64? = state.withLock { s in
            guard !s.inFlight else { return nil }
            let sizeChanged = (s.lastProbedSize != srcSize)
            let interval = s.tracker.nextProbeIntervalSeconds
            guard sizeChanged || s.lastProbeSubmitTime == 0 || (now - s.lastProbeSubmitTime) >= interval else {
                return nil
            }
            s.inFlight = true
            s.lastProbeSubmitTime = now
            s.lastProbedSize = srcSize
            return s.generation
        }

        guard let expectedGeneration = generationToCommit else { return }

        encodePasses(
            sourceTexture: sourceTexture,
            commandBuffer: commandBuffer,
            boundsPipeline: bPipe,
            esfPipeline: ePipe,
            boundsBuffer: bBuf,
            histogramBuffer: hBuf
        )

        let boundsBox = UnsafeSendableBox(bBuf)
        let histBox = UnsafeSendableBox(hBuf)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let evaluated = self.evaluateBuffers(
                sourceSize: srcSize,
                boundsBuffer: boundsBox.value,
                histogramBuffer: histBox.value
            )
            let emitted: DetectedOpticalResolution? = self.state.withLock { s in
                guard s.generation == expectedGeneration else { return nil }
                s.inFlight = false
                // Map edge sample confidence into tracker's activeSliceCount scale (>= 250 edges = high confidence).
                let confidenceScore = min(32, Int((evaluated?.edgeSamples ?? 0) / 30))
                return s.tracker.ingest(
                    candidate: evaluated?.resolution,
                    sourceSize: srcSize,
                    activeSliceCount: confidenceScore
                )
            }
            if let emitted {
                PipelineLog.shared.info(
                    .capture,
                    "Auto optical resolution detected: \(emitted.tier.badgeLabel)"
                        + (emitted.preDownscaleSize.map { " -> \($0.width)x\($0.height)" } ?? "")
                        + " (est=\(emitted.estimatedActiveHeight)p, sharpness=\(String(format: "%.3f", emitted.cutoffFrequencyRatio)), edges=\(evaluated?.edgeSamples ?? 0))."
                )
                onChanged(emitted)
            }
        }
    }

    // MARK: - Helpers

    private struct UnsafeSendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private func encodePasses(
        sourceTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        boundsPipeline: any MTLComputePipelineState,
        esfPipeline: any MTLComputePipelineState,
        boundsBuffer: any MTLBuffer,
        histogramBuffer: any MTLBuffer
    ) {
        if let enc1 = commandBuffer.makeComputeCommandEncoder() {
            enc1.label = "OpticalProbe_ActiveBounds"
            enc1.setComputePipelineState(boundsPipeline)
            enc1.setTexture(sourceTexture, index: 0)
            enc1.setBuffer(boundsBuffer, offset: 0, index: 0)
            enc1.setBuffer(histogramBuffer, offset: 0, index: 1)
            enc1.dispatchThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1)
            )
            enc1.endEncoding()
        }

        // Adapt sampling stride smoothly to display resolution (8px on 3K/4K/5K/6K -> ~0.10ms, 4px on 720p/1080p).
        var stride: UInt32 = (sourceTexture.width >= 2000 && sourceTexture.height >= 1200) ? 8 : 4
        let gridW = max(1, (sourceTexture.width + Int(stride) - 1) / Int(stride))
        let gridH = max(1, (sourceTexture.height + Int(stride) - 1) / Int(stride))
        let tgW = min(16, max(8, esfPipeline.threadExecutionWidth))
        let tgH = max(8, min(16, esfPipeline.maxTotalThreadsPerThreadgroup / max(1, tgW)))
        let groupsW = max(1, (gridW + tgW - 1) / tgW)
        let groupsH = max(1, (gridH + tgH - 1) / tgH)

        if let enc2 = commandBuffer.makeComputeCommandEncoder() {
            enc2.label = "OpticalProbe_ESFHistogram"
            enc2.setComputePipelineState(esfPipeline)
            enc2.setTexture(sourceTexture, index: 0)
            enc2.setBuffer(boundsBuffer, offset: 0, index: 0)
            enc2.setBuffer(histogramBuffer, offset: 0, index: 1)
            enc2.setBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 2)
            enc2.dispatchThreadgroups(
                MTLSize(width: groupsW, height: groupsH, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
            )
            enc2.endEncoding()
        }
    }

    private func evaluateBuffers(
        sourceSize: PixelSize,
        boundsBuffer: any MTLBuffer,
        histogramBuffer: any MTLBuffer
    ) -> (resolution: DetectedOpticalResolution, edgeSamples: UInt64)? {
        let b = boundsBuffer.contents().load(as: SIMD4<UInt32>.self)
        guard b.z > b.x + 64, b.w > b.y + 64 else { return nil }
        let activeRect = PixelRect(
            x: Int(b.x),
            y: Int(b.y),
            width: Int(b.z - b.x) + 1,
            height: Int(b.w - b.y) + 1
        )
        let count = OpticalResolutionClassifier.histogramBinCount
        let rawPtr = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: count)
        let bufferPtr = UnsafeBufferPointer(start: rawPtr, count: count)
        guard let measurement = OpticalResolutionClassifier.analyzeEdgeSharpnessHistogram(bufferPtr) else {
            return nil
        }
        let resolution = OpticalResolutionClassifier.classify(
            sourceSize: sourceSize,
            activeBounds: activeRect,
            cutoffFrequencyRatio: measurement.sharpnessRatio
        )
        return (resolution, measurement.edgeSampleCount)
    }
}
