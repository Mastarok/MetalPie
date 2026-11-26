import Foundation
import Metal
import MetalPieCore
import os

// MARK: - OpticalResolutionProbe

/// Zero-CPU-pixel-readback GPU 1D-FFT optical resolution estimator for `FullscreenVideoInputMode.auto`.
///
/// Runs two tiny compute passes (~0.15-0.35 ms total on Apple Silicon) inline on the render command buffer
/// ONLY when due (startup/resize warm-up at 4 Hz, steady-state at 1 Hz = ~0.02% GPU budget):
/// 1. `probeDetectActiveBounds`: scans 32 interior rows & 32 interior columns to locate the active non-black
///    video rect (100% immune to 4:3 pillarboxes, 16:9 letterboxes, and 2.39:1 cinemascope black bars).
/// 2. `probeOpticalSpectrum512`: runs 64 in-threadgroup 512-point Blackman-Harris-windowed 1D FFTs
///    (32 vertical + 32 horizontal slices strictly inside the active bounds, excluding top chrome & bottom
///    subtitle strips) and outputs a compact 64 KB power spectrum buffer read asynchronously on GPU completion.
public final class OpticalResolutionProbe: @unchecked Sendable {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    inline float probeLuma(float3 rgb) {
        return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
    }

    // Kernel 1: Locate active non-black video bounding box across 32 rows & 32 columns.
    kernel void probeDetectActiveBounds(
        texture2d<float, access::read> src [[texture(0)]],
        device uint4* outBounds [[buffer(0)]],
        uint tid [[thread_index_in_threadgroup]]
    ) {
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

    // Kernel 2: 64 x 512-point Blackman-Harris 1D FFT strictly inside detected active bounds.
    kernel void probeOpticalSpectrum512(
        texture2d<float, access::read> src [[texture(0)]],
        device const uint4* activeBounds [[buffer(0)]],
        device float* outSpectra [[buffer(1)]],
        uint tgID [[threadgroup_position_in_grid]],
        uint tid [[thread_index_in_threadgroup]]
    ) {
        constexpr uint N = 512u;
        constexpr uint HALF_N = 256u;
        threadgroup float2 buf[N];
        threadgroup float scratch[HALF_N];

        uint sw = src.get_width();
        uint sh = src.get_height();
        uint4 b = activeBounds[0];
        uint bx0 = b.x, by0 = b.y, bx1 = b.z, by1 = b.w;
        if (bx1 <= bx0 + 64u || by1 <= by0 + 64u) {
            outSpectra[tgID * HALF_N + tid] = 0.0f;
            return;
        }

        // Inset 12px from black bar boundaries and exclude top 6% titlebar & bottom 18% subtitle strip.
        uint ah = by1 - by0;
        uint xMin = min(bx0 + 12u, bx1);
        uint xMax = (bx1 > xMin + 16u) ? (bx1 - 12u) : bx1;
        uint yMin = min(by0 + max(12u, uint(float(ah) * 0.06f)), by1);
        uint yMax = (by1 > yMin + 16u) ? (by1 - max(12u, uint(float(ah) * 0.18f))) : by1;
        uint safeW = max(1u, xMax - xMin);
        uint safeH = max(1u, yMax - yMin);

        bool isH = (tgID >= 32u);
        uint sliceIdx = isH ? (tgID - 32u) : tgID;

        if ((!isH && safeH < N) || (isH && safeW < N)) {
            outSpectra[tgID * HALF_N + tid] = 0.0f;
            return;
        }

        float v[2];
        for (uint p = 0u; p < 2u; ++p) {
            uint i = tid + p * HALF_N;
            uint px, py;
            if (!isH) {
                px = clamp(xMin + uint((0.06f + 0.88f * (float(sliceIdx) + 0.5f) / 32.0f) * float(safeW)), 0u, sw - 1u);
                uint maxSlack = safeH - N;
                uint yStart = yMin + ((sliceIdx % 3u) * maxSlack) / 2u;
                py = clamp(yStart + i, 0u, sh - 1u);
            } else {
                py = clamp(yMin + uint((0.06f + 0.88f * (float(sliceIdx) + 0.5f) / 32.0f) * float(safeH)), 0u, sh - 1u);
                uint maxSlack = safeW - N;
                uint xStart = xMin + ((sliceIdx % 3u) * maxSlack) / 2u;
                px = clamp(xStart + i, 0u, sw - 1u);
            }
            v[p] = probeLuma(src.read(uint2(px, py)).rgb);
        }

        // Parallel slice mean subtraction (removes DC cleanly).
        scratch[tid] = v[0] + v[1];
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = HALF_N >> 1u; stride > 0u; stride >>= 1u) {
            if (tid < stride) scratch[tid] += scratch[tid + stride];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        float mean = scratch[0] / float(N);

        // 4-term Blackman-Harris window (-92 dB sidelobes) + bit-reversed load.
        for (uint p = 0u; p < 2u; ++p) {
            uint i = tid + p * HALF_N;
            float t = 2.0f * 3.14159265f * float(i) / float(N - 1u);
            float win = 0.35875f - 0.48829f * cos(t) + 0.14128f * cos(2.0f * t) - 0.01168f * cos(3.0f * t);
            uint rev = reverse_bits(i) >> 23u;
            buf[rev] = float2((v[p] - mean) * win, 0.0f);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // 9-stage radix-2 Cooley-Tukey FFT in threadgroup memory.
        for (uint s = 1u; s <= 9u; ++s) {
            uint m = 1u << s;
            uint halfM = m >> 1u;
            uint group = tid / halfM;
            uint j = tid % halfM;
            uint idx0 = group * m + j;
            uint idx1 = idx0 + halfM;
            float angle = -2.0f * 3.14159265f * float(j) / float(m);
            float2 w = float2(cos(angle), sin(angle));
            float2 a = buf[idx0];
            float2 b = buf[idx1];
            float2 prod = float2(w.x * b.x - w.y * b.y, w.x * b.y + w.y * b.x);
            buf[idx0] = a + prod;
            buf[idx1] = a - prod;
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        float2 x = buf[tid];
        outSpectra[tgID * HALF_N + tid] = x.x * x.x + x.y * x.y;
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
    private let spectrumPipeline: (any MTLComputePipelineState)?
    private let boundsBuffer: (any MTLBuffer)?
    private let spectraBuffer: (any MTLBuffer)?
    private let state = OSAllocatedUnfairLock(initialState: ProbeState())

    public init(device: any MTLDevice) {
        self.device = device
        if let lib = try? device.makeLibrary(source: Self.shaderSource, options: nil),
           let bFn = lib.makeFunction(name: "probeDetectActiveBounds"),
           let sFn = lib.makeFunction(name: "probeOpticalSpectrum512"),
           let bPipe = try? device.makeComputePipelineState(function: bFn),
           let sPipe = try? device.makeComputePipelineState(function: sFn),
           bPipe.maxTotalThreadsPerThreadgroup >= 64,
           sPipe.maxTotalThreadsPerThreadgroup >= OpticalResolutionClassifier.binsPerSlice,
           let bBuf = device.makeBuffer(length: MemoryLayout<SIMD4<UInt32>>.stride, options: .storageModeShared),
           let sBuf = device.makeBuffer(
               length: OpticalResolutionClassifier.totalSlices * OpticalResolutionClassifier.binsPerSlice * MemoryLayout<Float>.stride,
               options: .storageModeShared
           )
        {
            self.boundsPipeline = bPipe
            self.spectrumPipeline = sPipe
            self.boundsBuffer = bBuf
            self.spectraBuffer = sBuf
        } else {
            self.boundsPipeline = nil
            self.spectrumPipeline = nil
            self.boundsBuffer = nil
            self.spectraBuffer = nil
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
              let sPipe = spectrumPipeline,
              let bBuf = boundsBuffer,
              let sBuf = spectraBuffer,
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
            spectrumPipeline: sPipe,
            boundsBuffer: bBuf,
            spectraBuffer: sBuf
        )
        cb.commit()
        cb.waitUntilCompleted()

        return evaluateBuffers(sourceSize: srcSize, boundsBuffer: bBuf, spectraBuffer: sBuf)?.resolution
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
              let sPipe = spectrumPipeline,
              let bBuf = boundsBuffer,
              let sBuf = spectraBuffer
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
            spectrumPipeline: sPipe,
            boundsBuffer: bBuf,
            spectraBuffer: sBuf
        )

        let boundsBox = UnsafeSendableBox(bBuf)
        let spectraBox = UnsafeSendableBox(sBuf)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let evaluated = self.evaluateBuffers(
                sourceSize: srcSize,
                boundsBuffer: boundsBox.value,
                spectraBuffer: spectraBox.value
            )
            let emitted: DetectedOpticalResolution? = self.state.withLock { s in
                guard s.generation == expectedGeneration else { return nil }
                s.inFlight = false
                return s.tracker.ingest(
                    candidate: evaluated?.resolution,
                    sourceSize: srcSize,
                    activeSliceCount: evaluated?.activeSlices ?? 0
                )
            }
            if let emitted {
                PipelineLog.shared.info(
                    .capture,
                    "Auto optical resolution detected: \(emitted.tier.badgeLabel)"
                        + (emitted.preDownscaleSize.map { " -> \($0.width)x\($0.height)" } ?? "")
                        + " (est=\(emitted.estimatedActiveHeight)p, cutoff=\(String(format: "%.3f", emitted.cutoffFrequencyRatio)))."
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
        spectrumPipeline: any MTLComputePipelineState,
        boundsBuffer: any MTLBuffer,
        spectraBuffer: any MTLBuffer
    ) {
        if let enc1 = commandBuffer.makeComputeCommandEncoder() {
            enc1.label = "OpticalProbe_ActiveBounds"
            enc1.setComputePipelineState(boundsPipeline)
            enc1.setTexture(sourceTexture, index: 0)
            enc1.setBuffer(boundsBuffer, offset: 0, index: 0)
            enc1.dispatchThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1)
            )
            enc1.endEncoding()
        }

        if let enc2 = commandBuffer.makeComputeCommandEncoder() {
            enc2.label = "OpticalProbe_Spectrum512"
            enc2.setComputePipelineState(spectrumPipeline)
            enc2.setTexture(sourceTexture, index: 0)
            enc2.setBuffer(boundsBuffer, offset: 0, index: 0)
            enc2.setBuffer(spectraBuffer, offset: 0, index: 1)
            enc2.dispatchThreadgroups(
                MTLSize(width: OpticalResolutionClassifier.totalSlices, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: OpticalResolutionClassifier.binsPerSlice, height: 1, depth: 1)
            )
            enc2.endEncoding()
        }
    }

    private func evaluateBuffers(
        sourceSize: PixelSize,
        boundsBuffer: any MTLBuffer,
        spectraBuffer: any MTLBuffer
    ) -> (resolution: DetectedOpticalResolution, activeSlices: Int)? {
        let b = boundsBuffer.contents().load(as: SIMD4<UInt32>.self)
        guard b.z > b.x + 64, b.w > b.y + 64 else { return nil }
        let activeRect = PixelRect(
            x: Int(b.x),
            y: Int(b.y),
            width: Int(b.z - b.x) + 1,
            height: Int(b.w - b.y) + 1
        )
        let count = OpticalResolutionClassifier.totalSlices * OpticalResolutionClassifier.binsPerSlice
        let rawPtr = spectraBuffer.contents().bindMemory(to: Float.self, capacity: count)
        let bufferPtr = UnsafeBufferPointer(start: rawPtr, count: count)
        guard let measurement = OpticalResolutionClassifier.analyzeSpectrum(bufferPtr) else {
            return nil
        }
        let resolution = OpticalResolutionClassifier.classify(
            sourceSize: sourceSize,
            activeBounds: activeRect,
            cutoffFrequencyRatio: measurement.cutoffFrequencyRatio
        )
        return (resolution, measurement.activeSliceCount)
    }
}
