#include <metal_stdlib>
using namespace metal;

// ============================================================================
// OpticalFlowFallback.metal:
// Ultra-fast, fixed-cost GPU 3-level hierarchical optical flow interpolator
// with GPU-only threadgroup-reduced scene-cut Artifact Guard (zero CPU stalls!),
// forward-backward occlusion consistency, and full-res bidirectional warp.
//
// Performance target on Apple M4 Pro:
//   - Analysis pyramid capped to <= 480px wide (fine) -> <= 240px (coarse) -> <= 120px (super-coarse)
//   - Pre-loaded 3x3 half-precision source patches + hardware bilinear downsampling
//   - Total FG pass < 1.5 ms even at 2560x1440 and 3024x1964 Retina!
// ============================================================================

inline uint2 clampCoord(int2 p, int2 size) {
    return uint2(clamp(p, int2(0), max(size - int2(1), int2(0))));
}

// MARK: - Luma Pyramid Construction (Hardware Bilinear Anti-Aliased)

kernel void of_luma_from_rgba(
    texture2d<half, access::sample> rgbaIn [[texture(0)]],
    texture2d<half, access::write> lumaOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = lumaOut.get_width();
    const uint outH = lumaOut.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);
    const float2 invOut = 1.0f / float2(outW, outH);
    const float2 uvCenter = (float2(gid) + 0.5f) * invOut;
    const float2 qStep = 0.25f * invOut;
    const half3 kLuma = half3(0.2126h, 0.7152h, 0.0722h);

    // 4-tap bilinear box filter (covers 4x4 footprint cleanly with zero high-frequency aliasing).
    half3 c0 = saturate(rgbaIn.sample(linearSam, uvCenter + float2(-qStep.x, -qStep.y)).rgb);
    half3 c1 = saturate(rgbaIn.sample(linearSam, uvCenter + float2( qStep.x, -qStep.y)).rgb);
    half3 c2 = saturate(rgbaIn.sample(linearSam, uvCenter + float2(-qStep.x,  qStep.y)).rgb);
    half3 c3 = saturate(rgbaIn.sample(linearSam, uvCenter + float2( qStep.x,  qStep.y)).rgb);

    half luma = dot((c0 + c1 + c2 + c3) * 0.25h, kLuma);
    lumaOut.write(half4(luma, 0.0h, 0.0h, 1.0h), gid);
}

kernel void of_luma_downsample(
    texture2d<half, access::sample> lumaIn [[texture(0)]],
    texture2d<half, access::write> lumaOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = lumaOut.get_width();
    const uint outH = lumaOut.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);
    const float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);
    half y = lumaIn.sample(linearSam, uv).r;
    lumaOut.write(half4(y, 0.0h, 0.0h, 1.0h), gid);
}

// MARK: - GPU-Only Threadgroup-Reduced Scene Cut Detector (Zero CPU Readback!)

kernel void of_scene_diff(
    texture2d<half, access::read> prevLuma [[texture(0)]],
    texture2d<half, access::read> currLuma [[texture(1)]],
    device atomic_uint *accumDiff [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    threadgroup uint tgSum[256];

    const uint w = prevLuma.get_width();
    const uint h = prevLuma.get_height();
    uint fixedDiff = 0u;
    if (gid.x < w && gid.y < h) {
        float d = abs(float(currLuma.read(gid).r) - float(prevLuma.read(gid).r));
        fixedDiff = uint(clamp(d, 0.0f, 1.0f) * 255.0f);
    }

    tgSum[tid] = fixedDiff;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128u; stride > 0u; stride >>= 1u) {
        if (tid < stride) {
            tgSum[tid] += tgSum[tid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0u && tgSum[0] > 0u) {
        atomic_fetch_add_explicit(accumDiff, tgSum[0], memory_order_relaxed);
    }
}

// MARK: - Register-Cached 3x3 Patch SAD Helpers

inline void loadPatch3x3(
    texture2d<half, access::read> tex,
    int2 pos,
    int2 size,
    thread half (&patch)[9]
) {
    int idx = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        int y = clamp(pos.y + dy, 0, max(size.y - 1, 0));
        for (int dx = -1; dx <= 1; ++dx) {
            int x = clamp(pos.x + dx, 0, max(size.x - 1, 0));
            patch[idx++] = tex.read(uint2(x, y)).r;
        }
    }
}

inline half evalPatchSAD3x3(
    const thread half (&srcPatch)[9],
    texture2d<half, access::read> refLuma,
    int2 refPos,
    int2 size
) {
    half sad = 0.0h;
    int idx = 0;
    int maxX = max(size.x - 1, 0);
    int maxY = max(size.y - 1, 0);
    for (int dy = -1; dy <= 1; ++dy) {
        int y = clamp(refPos.y + dy, 0, maxY);
        for (int dx = -1; dx <= 1; ++dx) {
            int x = clamp(refPos.x + dx, 0, maxX);
            half b = refLuma.read(uint2(x, y)).r;
            sad += abs(srcPatch[idx++] - b);
        }
    }
    return sad;
}

// MARK: - Level 2: Super-Coarse Global Search (<= 120x78, covers +/-7 super-coarse px = +/-175 full-res px)

kernel void of_block_match_supercoarse(
    texture2d<half, access::read> srcLuma [[texture(0)]],
    texture2d<half, access::read> refLuma [[texture(1)]],
    texture2d<half, access::write> flowOut [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = flowOut.get_width();
    const uint h = flowOut.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }

    const int2 size = int2(srcLuma.get_width(), srcLuma.get_height());
    const int2 pos = int2(gid);

    half srcPatch[9];
    loadPatch3x3(srcLuma, pos, size, srcPatch);

    // Zero-motion baseline (no penalty).
    half bestCost = evalPatchSAD3x3(srcPatch, refLuma, pos, size);
    int2 bestDisp = int2(0);

    // Exhaustive stride-2 search in [-6, +6] (48 non-zero candidates) prevents local minima.
    for (int dy = -6; dy <= 6; dy += 2) {
        for (int dx = -6; dx <= 6; dx += 2) {
            if (dx == 0 && dy == 0) continue;
            half penalty = 0.0025h * half(abs(dx) + abs(dy));
            half cost = evalPatchSAD3x3(srcPatch, refLuma, pos + int2(dx, dy), size) + penalty;
            if (cost < bestCost) {
                bestCost = cost;
                bestDisp = int2(dx, dy);
            }
        }
    }

    // Local 1-pixel refinement around best stride-2 candidate (8 candidates).
    int2 baseDisp = bestDisp;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            if (dx == 0 && dy == 0) continue;
            int2 cand = baseDisp + int2(dx, dy);
            half penalty = 0.0025h * half(abs(cand.x) + abs(cand.y));
            half cost = evalPatchSAD3x3(srcPatch, refLuma, pos + cand, size) + penalty;
            if (cost < bestCost) {
                bestCost = cost;
                bestDisp = cand;
            }
        }
    }

    flowOut.write(half4(half(bestDisp.x), half(bestDisp.y), 0.0h, 1.0h), gid);
}

// MARK: - Level 1: Coarse Refinement (<= 240x156)

kernel void of_block_match_coarse(
    texture2d<half, access::read> srcLuma [[texture(0)]],
    texture2d<half, access::read> refLuma [[texture(1)]],
    texture2d<half, access::sample> parentFlow [[texture(2)]],
    texture2d<half, access::write> flowOut [[texture(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = flowOut.get_width();
    const uint h = flowOut.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);
    const int2 size = int2(srcLuma.get_width(), srcLuma.get_height());
    const int2 pos = int2(gid);
    const float2 uv = (float2(gid) + 0.5f) / float2(w, h);

    half srcPatch[9];
    loadPatch3x3(srcLuma, pos, size, srcPatch);

    int2 pred = int2(round(float2(parentFlow.sample(linearSam, uv).rg) * 2.0f));

    // Start from upsampled parent flow so smooth moving object interiors keep coherent motion.
    half predCost = evalPatchSAD3x3(srcPatch, refLuma, pos + pred, size);
    half bestCost = predCost;
    int2 bestDisp = pred;

    // Only snap to zero motion if (0, 0) is meaningfully better than parent flow (protects static UI/text
    // over moving backgrounds without punching zero-motion holes inside flat moving objects!).
    if (pred.x != 0 || pred.y != 0) {
        half zeroCost = evalPatchSAD3x3(srcPatch, refLuma, pos, size);
        if (zeroCost + 0.04h < bestCost) {
            bestCost = zeroCost;
            bestDisp = int2(0);
        }
    }

    // Local 3x3 search around upsampled parent prediction (8 neighbors around pred).
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            if (dx == 0 && dy == 0) continue;
            int2 cand = pred + int2(dx, dy);
            half penalty = 0.0015h * half(abs(dx) + abs(dy));
            half cost = evalPatchSAD3x3(srcPatch, refLuma, pos + cand, size) + penalty;
            if (cost < bestCost) {
                bestCost = cost;
                bestDisp = cand;
            }
        }
    }

    // One-step cardinal diamond follow-up if best moved to boundary of 3x3.
    if (bestDisp.x != pred.x || bestDisp.y != pred.y) {
        constexpr int2 dirs[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
        int2 center = bestDisp;
        for (int i = 0; i < 4; ++i) {
            int2 cand = center + dirs[i];
            if (abs(cand.x - pred.x) <= 1 && abs(cand.y - pred.y) <= 1) continue;
            half penalty = 0.0015h * half(abs(cand.x - pred.x) + abs(cand.y - pred.y));
            half cost = evalPatchSAD3x3(srcPatch, refLuma, pos + cand, size) + penalty;
            if (cost < bestCost) {
                bestCost = cost;
                bestDisp = cand;
            }
        }
    }

    flowOut.write(half4(half(bestDisp.x), half(bestDisp.y), 0.0h, 1.0h), gid);
}

// MARK: - Level 0: Fine Sub-Pixel Refinement (<= 480x312 -> outputs full-res pixel displacement)

struct OpticalFlowRefineUniforms {
    float2 fineToFullScale;
};

kernel void of_block_match_refine(
    texture2d<half, access::read> srcLuma [[texture(0)]],
    texture2d<half, access::read> refLuma [[texture(1)]],
    texture2d<half, access::sample> coarseFlow [[texture(2)]],
    texture2d<half, access::write> refinedFlow [[texture(3)]],
    constant OpticalFlowRefineUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = refinedFlow.get_width();
    const uint h = refinedFlow.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);
    const int2 size = int2(srcLuma.get_width(), srcLuma.get_height());
    const int2 pos = int2(gid);
    const float2 uv = (float2(gid) + 0.5f) / float2(w, h);

    half srcPatch[9];
    loadPatch3x3(srcLuma, pos, size, srcPatch);

    float2 coarseVec = float2(coarseFlow.sample(linearSam, uv).rg) * 2.0f;
    int2 pred = int2(round(coarseVec));

    // Evaluate 3x3 around pred and cache raw SADs for zero-cost parabolic sub-pixel fit when best == pred.
    half gridRaw[9];
    half bestCost = 1e4h;
    int2 bestDisp = pred;
    int gIdx = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            int2 cand = pred + int2(dx, dy);
            half raw = evalPatchSAD3x3(srcPatch, refLuma, pos + cand, size);
            gridRaw[gIdx++] = raw;
            half penalty = 0.0012h * half(abs(dx) + abs(dy));
            half cost = raw + penalty;
            if (cost < bestCost) {
                bestCost = cost;
                bestDisp = cand;
            }
        }
    }

    // Snap to zero motion only when static match is genuinely superior (protects static UI/text).
    if (bestDisp.x != 0 || bestDisp.y != 0) {
        half zeroCost = evalPatchSAD3x3(srcPatch, refLuma, pos, size);
        if (zeroCost + 0.04h < bestCost) {
            bestCost = zeroCost;
            bestDisp = int2(0);
        }
    }

    // Sub-pixel parabolic refinement along X and Y (reusing cached 3x3 values when possible).
    float cCenter, cLeft, cRight, cUp, cDown;
    if (bestDisp.x == pred.x && bestDisp.y == pred.y) {
        cCenter = float(gridRaw[4]);
        cLeft   = float(gridRaw[3]);
        cRight  = float(gridRaw[5]);
        cUp     = float(gridRaw[1]);
        cDown   = float(gridRaw[7]);
    } else {
        cCenter = float(evalPatchSAD3x3(srcPatch, refLuma, pos + bestDisp, size));
        cLeft   = float(evalPatchSAD3x3(srcPatch, refLuma, pos + bestDisp + int2(-1, 0), size));
        cRight  = float(evalPatchSAD3x3(srcPatch, refLuma, pos + bestDisp + int2( 1, 0), size));
        cUp     = float(evalPatchSAD3x3(srcPatch, refLuma, pos + bestDisp + int2(0, -1), size));
        cDown   = float(evalPatchSAD3x3(srcPatch, refLuma, pos + bestDisp + int2(0,  1), size));
    }

    float denomX = 2.0f * (cLeft - 2.0f * cCenter + cRight);
    float denomY = 2.0f * (cUp   - 2.0f * cCenter + cDown);
    float subX = (denomX > 1e-4f) ? clamp((cLeft - cRight) / denomX, -0.5f, 0.5f) : 0.0f;
    float subY = (denomY > 1e-4f) ? clamp((cUp   - cDown)  / denomY, -0.5f, 0.5f) : 0.0f;

    float2 fullFlow = (float2(bestDisp) + float2(subX, subY)) * u.fineToFullScale;
    refinedFlow.write(half4(half(fullFlow.x), half(fullFlow.y), 0.0h, 1.0h), gid);
}

// MARK: - Branchless 3x3 Vector Median Filter (Despeckle Outliers)

inline void sort2(thread half &a, thread half &b) {
    half lo = min(a, b);
    half hi = max(a, b);
    a = lo;
    b = hi;
}

inline half median9Fast(thread half (&v)[9]) {
    sort2(v[1], v[2]); sort2(v[4], v[5]); sort2(v[7], v[8]);
    sort2(v[0], v[1]); sort2(v[3], v[4]); sort2(v[6], v[7]);
    sort2(v[1], v[2]); sort2(v[4], v[5]); sort2(v[7], v[8]);
    sort2(v[0], v[3]); sort2(v[5], v[8]); sort2(v[4], v[7]);
    sort2(v[3], v[6]); sort2(v[1], v[4]); sort2(v[2], v[5]);
    sort2(v[4], v[7]); sort2(v[4], v[2]); sort2(v[6], v[4]);
    sort2(v[4], v[2]);
    return v[4];
}

kernel void of_median_filter(
    texture2d<half, access::read> flowIn [[texture(0)]],
    texture2d<half, access::write> flowOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = flowOut.get_width();
    const uint h = flowOut.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }

    const int2 size = int2(flowIn.get_width(), flowIn.get_height());
    const int2 p = int2(gid);
    half vx[9], vy[9];
    int idx = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        int y = clamp(p.y + dy, 0, max(size.y - 1, 0));
        for (int dx = -1; dx <= 1; ++dx) {
            int x = clamp(p.x + dx, 0, max(size.x - 1, 0));
            half2 mv = flowIn.read(uint2(x, y)).rg;
            vx[idx] = mv.x;
            vy[idx] = mv.y;
            ++idx;
        }
    }

    flowOut.write(half4(median9Fast(vx), median9Fast(vy), 0.0h, 1.0h), gid);
}

// MARK: - Bidirectional Motion-Compensated Warp + GPU-Side Scene-Cut Artifact Guard

struct OpticalFlowWarpUniforms {
    float interpolationFactor; // t in [0, 1] between prev (0) and curr (1)
    uint artifactGuardLevel;   // 0 = off, 1 = balanced, 2 = strong
    float cutThreshold;        // hard scene-cut luma diff threshold (e.g. 0.36 balanced, 0.24 strong)
    float invSceneDiffDenom;   // 1.0 / (sampleCount * 255.0)
};

kernel void of_bidirectional_warp(
    texture2d<half, access::sample> prevFrame [[texture(0)]],
    texture2d<half, access::sample> currFrame [[texture(1)]],
    texture2d<half, access::sample> fwdFlow [[texture(2)]],
    texture2d<half, access::sample> bwdFlow [[texture(3)]],
    texture2d<half, access::write> output [[texture(4)]],
    constant OpticalFlowWarpUniforms &u [[buffer(0)]],
    device const uint *sceneDiffAccum [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);

    const float2 outSize = float2(outW, outH);
    const float2 invSize = 1.0f / outSize;
    const float2 uv = (float2(gid) + 0.5f) * invSize;
    const float t = clamp(u.interpolationFactor, 0.0f, 1.0f);

    // GPU-only scene-cut Artifact Guard (zero CPU readback / zero waitUntilCompleted!).
    const float sceneDiffScore = float(sceneDiffAccum[0]) * u.invSceneDiffDenom;
    if (u.artifactGuardLevel > 0u && sceneDiffScore >= u.cutThreshold) {
        half3 nearer = (t < 0.5f)
            ? prevFrame.sample(linearSam, uv).rgb
            : currFrame.sample(linearSam, uv).rgb;
        output.write(half4(max(nearer, half3(0.0h)), 1.0h), gid);
        return;
    }

    // Direct (unwarped) samples first: early-out on bit-static UI/text/background pixels (saves 5+ texture ops!).
    half3 rawPrev = prevFrame.sample(linearSam, uv).rgb;
    half3 rawCurr = currFrame.sample(linearSam, uv).rgb;
    half3 nearerReal = (t < 0.5f) ? rawPrev : rawCurr;
    float staticDelta = length(float3(rawPrev - rawCurr));
    if (staticDelta <= 0.005f) {
        output.write(half4(max(nearerReal, half3(0.0h)), 1.0h), gid);
        return;
    }

    // Bidirectional flow vectors in full-res pixel space:
    // fwd: prev -> curr, bwd: curr -> prev
    float2 mvFwd = float2(fwdFlow.sample(linearSam, uv).rg);
    float2 mvBwd = float2(bwdFlow.sample(linearSam, uv).rg);

    // Symmetric midpoint velocity estimate
    float2 flow = 0.5f * (mvFwd - mvBwd);

    // Sample motion-compensated prev and curr frames at time t
    float2 uvPrev = saturate(uv - flow * t * invSize);
    float2 uvCurr = saturate(uv + flow * (1.0f - t) * invSize);

    half3 colPrev = prevFrame.sample(linearSam, uvPrev).rgb;
    half3 colCurr = currFrame.sample(linearSam, uvCurr).rgb;
    float warpDiscrepancy = length(float3(colPrev - colCurr));

    // Disocclusion-aware flow resolution: along moving object boundaries where one direction sees
    // the object and the other sees background (`mvFwd + mvBwd != 0`), test pure forward and pure
    // backward velocity hypotheses and pick whichever produces coherent prev/curr correspondence!
    float dirMismatch = length(mvFwd + mvBwd);
    if (dirMismatch > 2.0f && warpDiscrepancy > 0.08f) {
        float2 uvP1 = saturate(uv - mvFwd * t * invSize);
        float2 uvC1 = saturate(uv + mvFwd * (1.0f - t) * invSize);
        half3 p1 = prevFrame.sample(linearSam, uvP1).rgb;
        half3 c1 = currFrame.sample(linearSam, uvC1).rgb;
        float err1 = length(float3(p1 - c1));
        if (err1 + 0.02f < warpDiscrepancy) {
            flow = mvFwd;
            colPrev = p1;
            colCurr = c1;
            warpDiscrepancy = err1;
        }

        float2 bwdVel = -mvBwd;
        float2 uvP2 = saturate(uv - bwdVel * t * invSize);
        float2 uvC2 = saturate(uv + bwdVel * (1.0f - t) * invSize);
        half3 p2 = prevFrame.sample(linearSam, uvP2).rgb;
        half3 c2 = currFrame.sample(linearSam, uvC2).rgb;
        float err2 = length(float3(p2 - c2));
        if (err2 + 0.02f < warpDiscrepancy) {
            flow = bwdVel;
            colPrev = p2;
            colCurr = c2;
            warpDiscrepancy = err2;
        }
    }

    // Forward-backward consistency check (suppressed when photometric warp correspondence is already tight!)
    float2 uvAtFwd = saturate(uv + flow * invSize);
    float2 bwdAtFwd = float2(bwdFlow.sample(linearSam, uvAtFwd).rg);
    float fbError = length(flow + bwdAtFwd);

    // Compute motion-compensated blend
    half3 warpedBlend = mix(colPrev, colCurr, half(t));

    // Artifact Guard: suppress ghosting/tearing on genuine high-discrepancy occlusions or soft cuts.
    // When photometric warp discrepancy is low (< 0.08), the warped correspondence is verified accurate!
    float guardPull = 0.0f;
    float photometricConfidence = smoothstep(0.06f, 0.22f, warpDiscrepancy);
    if (u.artifactGuardLevel == 1u) {
        float occPull = smoothstep(4.0f, 16.0f, fbError) * photometricConfidence;
        float colPull = smoothstep(0.18f, 0.45f, warpDiscrepancy);
        float cutPull = smoothstep(0.18f, u.cutThreshold, sceneDiffScore);
        guardPull = max(max(occPull * 0.65f, colPull * 0.65f), cutPull);
    } else if (u.artifactGuardLevel >= 2u) {
        float occPull = smoothstep(2.0f, 9.0f, fbError) * photometricConfidence;
        float colPull = smoothstep(0.10f, 0.30f, warpDiscrepancy);
        float cutPull = smoothstep(0.12f, u.cutThreshold, sceneDiffScore);
        guardPull = max(max(occPull * 0.85f, colPull * 0.85f), cutPull);
    }

    // Smooth blend into static UI/text edges
    float staticMask = 1.0f - smoothstep(0.005f, 0.03f, staticDelta);

    half3 finalColor = mix(warpedBlend, nearerReal, half(saturate(max(guardPull, staticMask))));
    output.write(half4(max(finalColor, half3(0.0h)), 1.0h), gid);
}

// MARK: - GPU-Side Guarded NV12 -> BGRA Output for Explicit VideoToolbox ML Backend (Zero CPU Stall)

kernel void of_nv12_to_bgra_guarded(
    texture2d<half, access::read> luma [[texture(0)]],
    texture2d<half, access::sample> chroma [[texture(1)]],
    texture2d<half, access::sample> prevFrame [[texture(2)]],
    texture2d<half, access::sample> currFrame [[texture(3)]],
    texture2d<half, access::write> output [[texture(4)]],
    constant OpticalFlowWarpUniforms &u [[buffer(0)]],
    device const uint *sceneDiffAccum [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);
    const float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);
    const float t = clamp(u.interpolationFactor, 0.0f, 1.0f);

    const float sceneDiffScore = float(sceneDiffAccum[0]) * u.invSceneDiffDenom;
    if (u.artifactGuardLevel > 0u && sceneDiffScore >= u.cutThreshold) {
        half3 nearer = (t < 0.5f)
            ? prevFrame.sample(linearSam, uv).rgb
            : currFrame.sample(linearSam, uv).rgb;
        output.write(half4(max(nearer, half3(0.0h)), 1.0h), gid);
        return;
    }

    const int2 lumaSize = int2(luma.get_width(), luma.get_height());
    uint2 yCoord = clampCoord(int2(uv * float2(lumaSize)), lumaSize);
    half yRaw = luma.read(yCoord).r;
    half2 cbcrRaw = chroma.sample(linearSam, uv).rg;

    // Invert BT.709 video range: Y in [16/255, 235/255], Cb/Cr in [16/255, 240/255].
    half y = (yRaw * 255.0h - 16.0h) / 219.0h;
    half cb = (cbcrRaw.x * 255.0h - 128.0h) / 224.0h;
    half cr = (cbcrRaw.y * 255.0h - 128.0h) / 224.0h;

    half r = y + 1.5748h * cr;
    half g = y - 0.187324h * cb - 0.468124h * cr;
    half b = y + 1.8556h * cb;

    output.write(half4(saturate(half3(r, g, b)), 1.0h), gid);
}
