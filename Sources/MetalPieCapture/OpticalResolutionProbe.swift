import Foundation
import Metal
import MetalPieCore
import os

// MARK: - OpticalResolutionProbe

/// Zero-CPU-pixel-readback GPU sub-pixel 10%-to-90% monotonic edge-width estimator for
/// `FullscreenVideoInputMode.auto`.
///
/// Runs two tiny compute passes (~0.12 ms total on Apple Silicon) inline on the render command buffer
/// ONLY when due (startup/resize warm-up at 4 Hz, steady-state at 1 Hz = ~0.01% GPU budget):
/// 1. `probeClearHistogram`: zeroes the 100-bin histogram on GPU (zero CPU/GPU race).
/// 2. `probeMonotonicWidthHistogram`: measures sub-pixel 10%-to-90% monotonic transition widths
///    strictly inside the central danmaku/subtitle/titlebar/overscan-free band (`x ∈ [12%, 88%]`,
///    `y ∈ [22%, 78%]`) on tangent-denoised strong (`>= 20%` contrast) edges across gapless cells.
///    Immune to mpv/IINA 1-4 LSB dither, 1px anime ink-line overshoot, black pillarbox/letterbox bars,
///    Bilibili top danmaku, corner watermarks, and bottom subtitles/OSC controls!
public final class OpticalResolutionProbe: @unchecked Sendable {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    inline float probeLuma(float3 rgb) {
        return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
    }

    // Kernel 1: Zero the 100-bin histogram on GPU before accumulation (1 threadgroup of 128 threads).
    kernel void probeClearHistogram(
        device uint* hist [[buffer(0)]],
        uint tid [[thread_index_in_threadgroup]]
    ) {
        if (tid < 100u) {
            hist[tid] = 0u;
        }
    }

    // Sub-pixel 10%-to-90% monotonic edge transition width in pixels (1.0 for an ideal 1px native step,
    // ~S for any Sx upscaled edge across Spline36, Lanczos3, Bicubic, and Bilinear — ZERO 1px-line bias!).
    inline float measureMonotonicEdgeWidth(const thread float (&p)[21], int iPeak) {
        float stepDir = p[iPeak + 1] - p[iPeak];
        if (abs(stepDir) < 0.01f) {
            return 0.0f;
        }
        float sgn = (stepDir > 0.0f) ? 1.0f : -1.0f;

        // Walk outward along the monotonic ramp (0.012 tolerance ~= 3/255 ignores 1-2 LSB mpv dither
        // directly on raw scanlines without needing a 3px perpendicular average that blurs diagonal edges!).
        int iL = iPeak;
        while (iL > 0 && (p[iL] - p[iL - 1]) * sgn > 0.012f) {
            iL--;
        }
        int iR = iPeak + 1;
        while (iR < 20 && (p[iR + 1] - p[iR]) * sgn > 0.012f) {
            iR++;
        }

        float vL = p[iL];
        float vR = p[iR];
        float amp = abs(vR - vL);
        if (amp < 0.20f) {
            return 0.0f;
        }

        float t10 = vL + 0.10f * (vR - vL);
        float t90 = vL + 0.90f * (vR - vL);
        float x10 = float(iL);
        float x90 = float(iR);

        for (int i = iL; i < iR; ++i) {
            if ((p[i + 1] - t10) * sgn >= 0.0f) {
                float d = p[i + 1] - p[i];
                x10 = float(i) + clamp((t10 - p[i]) / (abs(d) > 1e-5f ? d : 1.0f), 0.0f, 1.0f);
                break;
            }
        }
        for (int i = iL; i < iR; ++i) {
            if ((p[i + 1] - t90) * sgn >= 0.0f) {
                float d = p[i + 1] - p[i];
                x90 = float(i) + clamp((t90 - p[i]) / (abs(d) > 1e-5f ? d : 1.0f), 0.0f, 1.0f);
                break;
            }
        }

        // Normalize against typical anti-aliased native 1px step 10%-90% span (0.88px -> native 1px step = 1.0).
        return max(0.5f, (x90 - x10) / 0.88f);
    }

    // Kernel 2: Central-band monotonic edge-width histogram with threadgroup-local reduction.
    // Excludes top 22% (Bilibili danmaku, TV watermarks, titlebar/menubar), bottom 22% (subtitles,
    // floating player OSC), and left/right 12% (4:3 pillarbox borders & VHS overscan).
    kernel void probeMonotonicWidthHistogram(
        texture2d<float, access::read> src [[texture(0)]],
        device atomic_uint* globalHist [[buffer(0)]],
        constant uint& stride [[buffer(1)]],
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

        uint sw = src.get_width();
        uint sh = src.get_height();
        uint xMargin = max(12u, uint(float(sw) * 0.12f));
        uint yMargin = max(12u, uint(float(sh) * 0.22f));
        uint xMin = xMargin;
        uint xMax = (sw > xMargin + 32u) ? (sw - xMargin) : sw;
        uint yMin = yMargin;
        uint yMax = (sh > yMargin + 32u) ? (sh - yMargin) : sh;

        uint x = xMin + gid.x * stride;
        uint y = yMin + gid.y * stride;
        if (x >= 10u && y >= 10u && x + 10u < xMax && y + 10u < yMax) {
            float hP[21], vP[21];
            float peakLuma = 0.0f;
            for (int d = -10; d <= 10; ++d) {
                uint px = uint(int(x) + d);
                uint py = uint(int(y) + d);
                float hv = probeLuma(src.read(uint2(px, y)).rgb);
                float vv = probeLuma(src.read(uint2(x, py)).rgb);
                hP[d + 10] = hv;
                vP[d + 10] = vv;
                peakLuma = max(peakLuma, max(hv, vv));
            }

            // Skip pure-black pillarbox / letterbox regions and dark fades.
            if (peakLuma >= 0.05f) {
                int halfCell = int(stride >> 1u);
                int iStart = max(2, 10 - halfCell);
                int iEnd = min(17, 10 + halfCell - 1);
                int hBestI = 10, vBestI = 10;
                float hBestS = 0.0f, vBestS = 0.0f;
                for (int i = iStart; i <= iEnd; ++i) {
                    float hs = abs(hP[i + 1] - hP[i]);
                    if (hs > hBestS) { hBestS = hs; hBestI = i; }
                    float vs = abs(vP[i + 1] - vP[i]);
                    if (vs > vBestS) { vBestS = vs; vBestI = i; }
                }

                float w = (hBestS >= vBestS)
                    ? measureMonotonicEdgeWidth(hP, hBestI)
                    : measureMonotonicEdgeWidth(vP, vBestI);
                if (w > 0.0f) {
                    float invW = clamp(1.0f / w, 0.0f, 1.0f);
                    uint bin = min(99u, uint(invW * 100.0f));
                    atomic_fetch_add_explicit(&localHist[bin], 1u, memory_order_relaxed);
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
    private let clearPipeline: (any MTLComputePipelineState)?
    private let widthPipeline: (any MTLComputePipelineState)?
    private let histogramBuffer: (any MTLBuffer)?
    private let state = OSAllocatedUnfairLock(initialState: ProbeState())

    public init(device: any MTLDevice) {
        self.device = device
        if let lib = try? device.makeLibrary(source: Self.shaderSource, options: nil),
           let cFn = lib.makeFunction(name: "probeClearHistogram"),
           let wFn = lib.makeFunction(name: "probeMonotonicWidthHistogram"),
           let cPipe = try? device.makeComputePipelineState(function: cFn),
           let wPipe = try? device.makeComputePipelineState(function: wFn),
           cPipe.maxTotalThreadsPerThreadgroup >= 128,
           wPipe.maxTotalThreadsPerThreadgroup >= 128,
           let hBuf = device.makeBuffer(
               length: OpticalResolutionClassifier.histogramBinCount * MemoryLayout<UInt32>.stride,
               options: .storageModeShared
           )
        {
            self.clearPipeline = cPipe
            self.widthPipeline = wPipe
            self.histogramBuffer = hBuf
        } else {
            self.clearPipeline = nil
            self.widthPipeline = nil
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
        guard let cPipe = clearPipeline,
              let wPipe = widthPipeline,
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
            clearPipeline: cPipe,
            widthPipeline: wPipe,
            histogramBuffer: hBuf
        )
        cb.commit()
        cb.waitUntilCompleted()

        return evaluateBuffer(sourceSize: srcSize, histogramBuffer: hBuf)?.resolution
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
        guard let cPipe = clearPipeline,
              let wPipe = widthPipeline,
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
            clearPipeline: cPipe,
            widthPipeline: wPipe,
            histogramBuffer: hBuf
        )

        let histBox = UnsafeSendableBox(hBuf)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let evaluated = self.evaluateBuffer(
                sourceSize: srcSize,
                histogramBuffer: histBox.value
            )
            let emitted: DetectedOpticalResolution? = self.state.withLock { s in
                guard s.generation == expectedGeneration else { return nil }
                s.inFlight = false
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
                    "Auto optical resolution locked: \(emitted.tier.badgeLabel)"
                        + (emitted.preDownscaleSize.map { " -> \($0.width)x\($0.height)" } ?? "")
                        + " (est=\(emitted.estimatedActiveHeight)p, invW=\(String(format: "%.3f", emitted.cutoffFrequencyRatio)), edges=\(evaluated?.edgeSamples ?? 0))."
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
        clearPipeline: any MTLComputePipelineState,
        widthPipeline: any MTLComputePipelineState,
        histogramBuffer: any MTLBuffer
    ) {
        if let enc1 = commandBuffer.makeComputeCommandEncoder() {
            enc1.label = "OpticalProbe_ClearHist"
            enc1.setComputePipelineState(clearPipeline)
            enc1.setBuffer(histogramBuffer, offset: 0, index: 0)
            enc1.dispatchThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1)
            )
            enc1.endEncoding()
        }

        // Adapt sampling stride smoothly to display resolution (8px on 3K/4K/5K/6K, 4px on 720p/1080p).
        var stride: UInt32 = (sourceTexture.width >= 2000 && sourceTexture.height >= 1200) ? 8 : 4
        let activeW = max(1, Int((Double(sourceTexture.width) * 0.76).rounded()))
        let activeH = max(1, Int((Double(sourceTexture.height) * 0.56).rounded()))
        let gridW = max(1, (activeW + Int(stride) - 1) / Int(stride))
        let gridH = max(1, (activeH + Int(stride) - 1) / Int(stride))
        let tgW = min(16, max(8, widthPipeline.threadExecutionWidth))
        let tgH = max(8, min(16, widthPipeline.maxTotalThreadsPerThreadgroup / max(1, tgW)))
        let groupsW = max(1, (gridW + tgW - 1) / tgW)
        let groupsH = max(1, (gridH + tgH - 1) / tgH)

        if let enc2 = commandBuffer.makeComputeCommandEncoder() {
            enc2.label = "OpticalProbe_MonotonicWidth"
            enc2.setComputePipelineState(widthPipeline)
            enc2.setTexture(sourceTexture, index: 0)
            enc2.setBuffer(histogramBuffer, offset: 0, index: 0)
            enc2.setBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 1)
            enc2.dispatchThreadgroups(
                MTLSize(width: groupsW, height: groupsH, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
            )
            enc2.endEncoding()
        }
    }

    private func evaluateBuffer(
        sourceSize: PixelSize,
        histogramBuffer: any MTLBuffer
    ) -> (resolution: DetectedOpticalResolution, edgeSamples: UInt64)? {
        let count = OpticalResolutionClassifier.histogramBinCount
        let rawPtr = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: count)
        let bufferPtr = UnsafeBufferPointer(start: rawPtr, count: count)
        guard let measurement = OpticalResolutionClassifier.analyzeEdgeSharpnessHistogram(bufferPtr) else {
            return nil
        }
        let resolution = OpticalResolutionClassifier.classify(
            sourceSize: sourceSize,
            cutoffFrequencyRatio: measurement.sharpnessRatio
        )
        return (resolution, measurement.edgeSampleCount)
    }
}
