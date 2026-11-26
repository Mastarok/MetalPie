import Foundation
import Metal
import MetalPieCore
import os

// MARK: - OpticalResolutionProbe

/// Zero-CPU-pixel-readback GPU hybrid resampling-lattice & monotonic edge-width estimator for
/// `FullscreenVideoInputMode.auto`.
///
/// Runs four tiny compute passes (~0.16 ms total on Apple Silicon) inline on the render command buffer
/// ONLY when due (startup/resize warm-up at 4 Hz, steady-state at 1 Hz = ~0.016% GPU budget):
/// 1. `probeClearHistogram`: zeroes the 100-bin edge-width histogram on GPU.
/// 2. `probeMonotonicWidthHistogram`: measures sub-pixel 10%-to-90% monotonic edge transition widths
///    inside the central band (`x ∈ [12%, 88%]`, `y ∈ [22%, 78%]`) for Native UI detection and alias disambiguation.
/// 3. `probeRowResamplingProfiles`: threadgroup-reduced row-averaged deadzone-gated `|Δ¹y|` & `|Δ²y|` profiles
///    for Gallagher/Popescu-Farid vertical resampling lattice detection (`±1 px` exact across Bilinear,
///    Catmull-Rom, Spline36, Lanczos3, TVB ringing/grain, mpv dither, and Bilibili danmaku).
/// 4. `probeColResamplingProfiles`: matching horizontal `|Δ¹x|` & `|Δ²x|` profiles for cross-axis verification.
public final class OpticalResolutionProbe: @unchecked Sendable {
    private static let osLog = Logger(subsystem: "com.metalpie.app", category: "OpticalProbe")
    private static let maxProfileLength = 1024

    private struct ProfileParams {
        var startPrimary: UInt32
        var countPrimary: UInt32
        var startCross: UInt32
        var endCross: UInt32
        var crossStep: UInt32
        var outOffset1: UInt32
        var outOffset2: UInt32
        var reserved: UInt32 = 0
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ProfileParams {
        uint startPrimary;
        uint countPrimary;
        uint startCross;
        uint endCross;
        uint crossStep;
        uint outOffset1;
        uint outOffset2;
        uint reserved;
    };

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

    // Sub-pixel 10%-to-90% monotonic edge transition width in pixels.
    inline float measureMonotonicEdgeWidth(const thread float (&p)[21], int iPeak) {
        float stepDir = p[iPeak + 1] - p[iPeak];
        if (abs(stepDir) < 0.01f) {
            return 0.0f;
        }
        float sgn = (stepDir > 0.0f) ? 1.0f : -1.0f;

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

        return max(0.5f, (x90 - x10) / 0.88f);
    }

    // Kernel 2: Central-band monotonic edge-width histogram with threadgroup-local reduction.
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

    // Kernel 3: Row-averaged deadzone-gated |Δ¹y| and |Δ²y| resampling lattice profiles (128 threads/row).
    kernel void probeRowResamplingProfiles(
        texture2d<float, access::read> src [[texture(0)]],
        device float* profiles [[buffer(0)]],
        constant ProfileParams& p [[buffer(1)]],
        uint rowIdx [[threadgroup_position_in_grid]],
        uint tid [[thread_index_in_threadgroup]]
    ) {
        threadgroup float s1[128];
        threadgroup float s2[128];
        threadgroup float sc[128];

        float sum1 = 0.0f;
        float sum2 = 0.0f;
        float cnt = 0.0f;

        if (rowIdx < p.countPrimary) {
            uint y = p.startPrimary + rowIdx;
            uint step = max(1u, p.crossStep);
            for (uint x = p.startCross + tid * step; x < p.endCross; x += 128u * step) {
                float l0 = probeLuma(src.read(uint2(x, y - 1u)).rgb);
                float l1 = probeLuma(src.read(uint2(x, y)).rgb);
                float l2 = probeLuma(src.read(uint2(x, y + 1u)).rgb);
                float rawD1 = abs(l2 - l1);
                float rawD2 = abs(l0 - 2.0f * l1 + l2);
                // Skip pure-black pillarbox/letterbox AND 1px white-on-black native danmaku impulses (rawD2 > 0.65,
                // where opposing gradients sum to ~1.8 while upscaled step edges cancel to <= 0.45!).
                if (max(l0, max(l1, l2)) >= 0.04f && rawD2 <= 0.65f) {
                    sum1 += min(0.15f, max(0.0f, rawD1 - 0.012f));
                    sum2 += min(0.15f, max(0.0f, rawD2 - 0.016f));
                    cnt += 1.0f;
                }
            }
        }

        s1[tid] = sum1;
        s2[tid] = sum2;
        sc[tid] = cnt;
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint stride = 64u; stride > 0u; stride >>= 1u) {
            if (tid < stride) {
                s1[tid] += s1[tid + stride];
                s2[tid] += s2[tid + stride];
                sc[tid] += sc[tid + stride];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        if (tid == 0u && rowIdx < p.countPrimary) {
            float denom = max(1.0f, sc[0]);
            profiles[p.outOffset1 + rowIdx] = s1[0] / denom;
            profiles[p.outOffset2 + rowIdx] = s2[0] / denom;
        }
    }

    // Kernel 4: Column-averaged deadzone-gated |Δ¹x| and |Δ²x| resampling lattice profiles (128 threads/col).
    kernel void probeColResamplingProfiles(
        texture2d<float, access::read> src [[texture(0)]],
        device float* profiles [[buffer(0)]],
        constant ProfileParams& p [[buffer(1)]],
        uint colIdx [[threadgroup_position_in_grid]],
        uint tid [[thread_index_in_threadgroup]]
    ) {
        threadgroup float s1[128];
        threadgroup float s2[128];
        threadgroup float sc[128];

        float sum1 = 0.0f;
        float sum2 = 0.0f;
        float cnt = 0.0f;

        if (colIdx < p.countPrimary) {
            uint x = p.startPrimary + colIdx;
            uint step = max(1u, p.crossStep);
            for (uint y = p.startCross + tid * step; y < p.endCross; y += 128u * step) {
                float l0 = probeLuma(src.read(uint2(x - 1u, y)).rgb);
                float l1 = probeLuma(src.read(uint2(x, y)).rgb);
                float l2 = probeLuma(src.read(uint2(x + 1u, y)).rgb);
                float rawD1 = abs(l2 - l1);
                float rawD2 = abs(l0 - 2.0f * l1 + l2);
                if (max(l0, max(l1, l2)) >= 0.04f && rawD2 <= 0.65f) {
                    sum1 += min(0.15f, max(0.0f, rawD1 - 0.012f));
                    sum2 += min(0.15f, max(0.0f, rawD2 - 0.016f));
                    cnt += 1.0f;
                }
            }
        }

        s1[tid] = sum1;
        s2[tid] = sum2;
        sc[tid] = cnt;
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint stride = 64u; stride > 0u; stride >>= 1u) {
            if (tid < stride) {
                s1[tid] += s1[tid + stride];
                s2[tid] += s2[tid + stride];
                sc[tid] += sc[tid + stride];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        if (tid == 0u && colIdx < p.countPrimary) {
            float denom = max(1.0f, sc[0]);
            profiles[p.outOffset1 + colIdx] = s1[0] / denom;
            profiles[p.outOffset2 + colIdx] = s2[0] / denom;
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

    private struct EvaluatedProbe {
        var resolution: DetectedOpticalResolution
        var edgeSamples: UInt64
        var peakY: OpticalResolutionClassifier.ResamplingGridPeak?
        var peakX: OpticalResolutionClassifier.ResamplingGridPeak?
        var edgeP50: Double
        var edgeP80: Double
        var edgeP88: Double
    }

    private let device: any MTLDevice
    private let clearPipeline: (any MTLComputePipelineState)?
    private let widthPipeline: (any MTLComputePipelineState)?
    private let rowProfilePipeline: (any MTLComputePipelineState)?
    private let colProfilePipeline: (any MTLComputePipelineState)?
    private let histogramBuffer: (any MTLBuffer)?
    private let profileBuffer: (any MTLBuffer)?
    private let state = OSAllocatedUnfairLock(initialState: ProbeState())

    public init(device: any MTLDevice) {
        self.device = device
        if let lib = try? device.makeLibrary(source: Self.shaderSource, options: nil),
           let cFn = lib.makeFunction(name: "probeClearHistogram"),
           let wFn = lib.makeFunction(name: "probeMonotonicWidthHistogram"),
           let rFn = lib.makeFunction(name: "probeRowResamplingProfiles"),
           let colFn = lib.makeFunction(name: "probeColResamplingProfiles"),
           let cPipe = try? device.makeComputePipelineState(function: cFn),
           let wPipe = try? device.makeComputePipelineState(function: wFn),
           let rPipe = try? device.makeComputePipelineState(function: rFn),
           let colPipe = try? device.makeComputePipelineState(function: colFn),
           cPipe.maxTotalThreadsPerThreadgroup >= 128,
           wPipe.maxTotalThreadsPerThreadgroup >= 128,
           rPipe.maxTotalThreadsPerThreadgroup >= 128,
           colPipe.maxTotalThreadsPerThreadgroup >= 128,
           let hBuf = device.makeBuffer(
               length: OpticalResolutionClassifier.histogramBinCount * MemoryLayout<UInt32>.stride,
               options: .storageModeShared
           ),
           let pBuf = device.makeBuffer(
               length: 4 * Self.maxProfileLength * MemoryLayout<Float>.stride,
               options: .storageModeShared
           )
        {
            self.clearPipeline = cPipe
            self.widthPipeline = wPipe
            self.rowProfilePipeline = rPipe
            self.colProfilePipeline = colPipe
            self.histogramBuffer = hBuf
            self.profileBuffer = pBuf
        } else {
            self.clearPipeline = nil
            self.widthPipeline = nil
            self.rowProfilePipeline = nil
            self.colProfilePipeline = nil
            self.histogramBuffer = nil
            self.profileBuffer = nil
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
        probeWithDiagnosticsSynchronously(texture: texture, commandQueue: commandQueue)?.resolution
    }

    /// Detailed synchronous probe diagnostics (Gallagher X/Y peaks + edge-width quantiles) for tests & diagnostics.
    public struct SynchronousDiagnostics: Sendable {
        public let resolution: DetectedOpticalResolution
        public let peakY: OpticalResolutionClassifier.ResamplingGridPeak?
        public let peakX: OpticalResolutionClassifier.ResamplingGridPeak?
        public let edgeP50: Double
        public let edgeP80: Double
        public let edgeP88: Double
    }

    public func probeWithDiagnosticsSynchronously(
        texture: any MTLTexture,
        commandQueue: any MTLCommandQueue
    ) -> SynchronousDiagnostics? {
        guard let cPipe = clearPipeline,
              let wPipe = widthPipeline,
              let rPipe = rowProfilePipeline,
              let colPipe = colProfilePipeline,
              let hBuf = histogramBuffer,
              let pBuf = profileBuffer,
              let cb = commandQueue.makeCommandBuffer()
        else {
            return nil
        }
        let srcSize = PixelSize(width: texture.width, height: texture.height)
        guard srcSize.width >= 480, srcSize.height >= 680 else {
            return SynchronousDiagnostics(resolution: .native, peakY: nil, peakX: nil, edgeP50: 1, edgeP80: 1, edgeP88: 1)
        }

        let (lenY, lenX) = encodePasses(
            sourceTexture: texture,
            commandBuffer: cb,
            clearPipeline: cPipe,
            widthPipeline: wPipe,
            rowProfilePipeline: rPipe,
            colProfilePipeline: colPipe,
            histogramBuffer: hBuf,
            profileBuffer: pBuf
        )
        cb.commit()
        cb.waitUntilCompleted()

        guard let ev = evaluateBuffers(
            sourceSize: srcSize,
            histogramBuffer: hBuf,
            profileBuffer: pBuf,
            profileLenY: lenY,
            profileLenX: lenX
        ) else {
            return nil
        }
        return SynchronousDiagnostics(
            resolution: ev.resolution,
            peakY: ev.peakY,
            peakX: ev.peakX,
            edgeP50: ev.edgeP50,
            edgeP80: ev.edgeP80,
            edgeP88: ev.edgeP88
        )
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
              let rPipe = rowProfilePipeline,
              let colPipe = colProfilePipeline,
              let hBuf = histogramBuffer,
              let pBuf = profileBuffer
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

        let (lenY, lenX) = encodePasses(
            sourceTexture: sourceTexture,
            commandBuffer: commandBuffer,
            clearPipeline: cPipe,
            widthPipeline: wPipe,
            rowProfilePipeline: rPipe,
            colProfilePipeline: colPipe,
            histogramBuffer: hBuf,
            profileBuffer: pBuf
        )

        let histBox = UnsafeSendableBox(hBuf)
        let profBox = UnsafeSendableBox(pBuf)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let evaluated = self.evaluateBuffers(
                sourceSize: srcSize,
                histogramBuffer: histBox.value,
                profileBuffer: profBox.value,
                profileLenY: lenY,
                profileLenX: lenX
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
                let yInfo = evaluated?.peakY.map {
                    "Y:\(String(format: "%.1fx@%.3f", $0.snr, $0.frequencyCyclesPerPixel))"
                } ?? "Y:-"
                let xInfo = evaluated?.peakX.map {
                    "X:\(String(format: "%.1fx@%.3f", $0.snr, $0.frequencyCyclesPerPixel))"
                } ?? "X:-"
                let msg = "Auto optical resolution locked: \(emitted.tier.badgeLabel)"
                    + (emitted.preDownscaleSize.map { " -> \($0.width)x\($0.height)" } ?? "")
                    + " (est=\(emitted.estimatedActiveHeight)p, grid=\(emitted.isGridLocked), \(yInfo), \(xInfo), p50=\(String(format: "%.3f", evaluated?.edgeP50 ?? 0)), p80=\(String(format: "%.3f", evaluated?.edgeP80 ?? 0)), p88=\(String(format: "%.3f", evaluated?.edgeP88 ?? 0)), edges=\(evaluated?.edgeSamples ?? 0))."
                PipelineLog.shared.info(.capture, msg)
                Self.osLog.info("\(msg, privacy: .public)")
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
        rowProfilePipeline: any MTLComputePipelineState,
        colProfilePipeline: any MTLComputePipelineState,
        histogramBuffer: any MTLBuffer,
        profileBuffer: any MTLBuffer
    ) -> (lenY: Int, lenX: Int) {
        let sw = sourceTexture.width
        let sh = sourceTexture.height

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

        // Pass 2: Central-band 10%-90% monotonic edge-width histogram
        var stride: UInt32 = (sw >= 2000 && sh >= 1200) ? 8 : 4
        let activeW = max(1, Int((Double(sw) * 0.76).rounded()))
        let activeH = max(1, Int((Double(sh) * 0.56).rounded()))
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

        // Pass 3: Row-averaged |Δ¹y| and |Δ²y| resampling lattice profiles
        // Centered vertically (excludes top/bottom 23% on 3K/4K/5K/6K -> zero danmaku/subtitle/OSC contamination!)
        let lenY = (sh >= 1360) ? 1024 : (sh >= 520 ? 512 : 0)
        if lenY > 0, let enc3 = commandBuffer.makeComputeCommandEncoder() {
            let y0 = max(2, (sh - lenY) / 2)
            let xMin = max(8, Int((Double(sw) * 0.12).rounded()))
            let xMax = min(sw - 8, max(xMin + 16, Int((Double(sw) * 0.88).rounded())))
            let xStep = max(1, (xMax - xMin) / 512)
            var params = ProfileParams(
                startPrimary: UInt32(y0),
                countPrimary: UInt32(lenY),
                startCross: UInt32(xMin),
                endCross: UInt32(xMax),
                crossStep: UInt32(xStep),
                outOffset1: 0,
                outOffset2: UInt32(Self.maxProfileLength)
            )
            enc3.label = "OpticalProbe_RowResampling"
            enc3.setComputePipelineState(rowProfilePipeline)
            enc3.setTexture(sourceTexture, index: 0)
            enc3.setBuffer(profileBuffer, offset: 0, index: 0)
            enc3.setBytes(&params, length: MemoryLayout<ProfileParams>.stride, index: 1)
            enc3.dispatchThreadgroups(
                MTLSize(width: lenY, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1)
            )
            enc3.endEncoding()
        }

        // Pass 4: Column-averaged |Δ¹x| and |Δ²x| resampling lattice profiles
        // Centered horizontally (750px away from 4:3 pillarbox borders on 3K!)
        let lenX = (sw >= 1360) ? 1024 : (sw >= 520 ? 512 : 0)
        if lenX > 0, let enc4 = commandBuffer.makeComputeCommandEncoder() {
            let x0 = max(2, (sw - lenX) / 2)
            let yMin = max(8, Int((Double(sh) * 0.22).rounded()))
            let yMax = min(sh - 8, max(yMin + 16, Int((Double(sh) * 0.78).rounded())))
            let yStep = max(1, (yMax - yMin) / 512)
            var params = ProfileParams(
                startPrimary: UInt32(x0),
                countPrimary: UInt32(lenX),
                startCross: UInt32(yMin),
                endCross: UInt32(yMax),
                crossStep: UInt32(yStep),
                outOffset1: UInt32(2 * Self.maxProfileLength),
                outOffset2: UInt32(3 * Self.maxProfileLength)
            )
            enc4.label = "OpticalProbe_ColResampling"
            enc4.setComputePipelineState(colProfilePipeline)
            enc4.setTexture(sourceTexture, index: 0)
            enc4.setBuffer(profileBuffer, offset: 0, index: 0)
            enc4.setBytes(&params, length: MemoryLayout<ProfileParams>.stride, index: 1)
            enc4.dispatchThreadgroups(
                MTLSize(width: lenX, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1)
            )
            enc4.endEncoding()
        }

        return (lenY, lenX)
    }

    private func evaluateBuffers(
        sourceSize: PixelSize,
        histogramBuffer: any MTLBuffer,
        profileBuffer: any MTLBuffer,
        profileLenY: Int,
        profileLenX: Int
    ) -> EvaluatedProbe? {
        let histCount = OpticalResolutionClassifier.histogramBinCount
        let rawHist = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: histCount)
        let histPtr = UnsafeBufferPointer(start: rawHist, count: histCount)
        let edgeMeasurement = OpticalResolutionClassifier.analyzeEdgeSharpnessHistogram(histPtr)

        let rawProf = profileBuffer.contents().bindMemory(to: Float.self, capacity: 4 * Self.maxProfileLength)

        var peakY: OpticalResolutionClassifier.ResamplingGridPeak? = nil
        if profileLenY == 512 || profileLenY == 1024 {
            let d1Y = UnsafeBufferPointer(start: rawProf, count: profileLenY)
            let d2Y = UnsafeBufferPointer(start: rawProf.advanced(by: Self.maxProfileLength), count: profileLenY)
            peakY = OpticalResolutionClassifier.selectStrongerPeak(
                OpticalResolutionClassifier.analyzeResamplingProfile(d1Y, length: profileLenY),
                OpticalResolutionClassifier.analyzeResamplingProfile(d2Y, length: profileLenY)
            )
        }

        var peakX: OpticalResolutionClassifier.ResamplingGridPeak? = nil
        if profileLenX == 512 || profileLenX == 1024 {
            let d1X = UnsafeBufferPointer(start: rawProf.advanced(by: 2 * Self.maxProfileLength), count: profileLenX)
            let d2X = UnsafeBufferPointer(start: rawProf.advanced(by: 3 * Self.maxProfileLength), count: profileLenX)
            peakX = OpticalResolutionClassifier.selectStrongerPeak(
                OpticalResolutionClassifier.analyzeResamplingProfile(d1X, length: profileLenX),
                OpticalResolutionClassifier.analyzeResamplingProfile(d2X, length: profileLenX)
            )
        }

        guard let resolution = OpticalResolutionClassifier.classifyHybrid(
            sourceSize: sourceSize,
            edgeMeasurement: edgeMeasurement,
            gridPeakY: peakY,
            gridPeakX: peakX
        ) else {
            return nil
        }

        return EvaluatedProbe(
            resolution: resolution,
            edgeSamples: edgeMeasurement?.edgeSampleCount ?? 0,
            peakY: peakY,
            peakX: peakX,
            edgeP50: edgeMeasurement?.medianSharpnessRatio ?? 0.0,
            edgeP80: edgeMeasurement?.disambiguationRatio ?? 0.0,
            edgeP88: edgeMeasurement?.sharpnessRatio ?? 0.0
        )
    }
}
