#include <metal_stdlib>
using namespace metal;

// ============================================================================
// OpticalFlowFallback.metal:
// Lightweight GPU hierarchical block-matching motion estimation +
// cut/occlusion Artifact Guard + bidirectional motion-compensated warp.
// Used for Frame Generation fallback on macOS 14-15, >1080p frames, or
// explicit Metal Optical Flow backend selection — ZERO per-frame allocations!
// ============================================================================

inline uint2 clampCoord(int2 p, int2 size) {
    return uint2(clamp(p, int2(0), max(size - int2(1), int2(0))));
}

// MARK: - Luma Pyramid Construction

kernel void of_luma_from_rgba(
    texture2d<float, access::read> rgbaIn [[texture(0)]],
    texture2d<half, access::write> lumaOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = lumaOut.get_width();
    const uint outH = lumaOut.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }
    const int2 inSize = int2(rgbaIn.get_width(), rgbaIn.get_height());
    const int2 base = int2(gid * 2u);
    const float3 kLuma = float3(0.2126f, 0.7152f, 0.0722f);

    float sum = 0.0f;
    for (int dy = 0; dy < 2; ++dy) {
        for (int dx = 0; dx < 2; ++dx) {
            float3 rgb = rgbaIn.read(clampCoord(base + int2(dx, dy), inSize)).rgb;
            sum += dot(saturate(rgb), kLuma);
        }
    }
    lumaOut.write(half4(half(sum * 0.25f), 0.0h, 0.0h, 1.0h), gid);
}

kernel void of_luma_downsample(
    texture2d<half, access::read> lumaIn [[texture(0)]],
    texture2d<half, access::write> lumaOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = lumaOut.get_width();
    const uint outH = lumaOut.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }
    const int2 inSize = int2(lumaIn.get_width(), lumaIn.get_height());
    const int2 base = int2(gid * 2u);

    half sum = 0.0h;
    for (int dy = 0; dy < 2; ++dy) {
        for (int dx = 0; dx < 2; ++dx) {
            sum += lumaIn.read(clampCoord(base + int2(dx, dy), inSize)).r;
        }
    }
    lumaOut.write(half4(sum * 0.25h, 0.0h, 0.0h, 1.0h), gid);
}

// MARK: - Scene Cut / Global Frame Difference Accumulator

kernel void of_scene_diff(
    texture2d<half, access::read> prevLuma [[texture(0)]],
    texture2d<half, access::read> currLuma [[texture(1)]],
    device atomic_uint *accumDiff [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = prevLuma.get_width();
    const uint h = prevLuma.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }
    // Sample every 2nd pixel in each axis for ultra-fast scene cut detection.
    uint2 p = gid * 2u;
    if (p.x >= w || p.y >= h) {
        return;
    }
    float d = abs(float(currLuma.read(p).r) - float(prevLuma.read(p).r));
    uint fixedDiff = uint(clamp(d, 0.0f, 1.0f) * 255.0f);
    atomic_fetch_add_explicit(accumDiff, fixedDiff, memory_order_relaxed);
}

// MARK: - Hierarchical Block Matching (Coarse 1/4-Res -> Refine 1/2-Res)

inline float blockSAD(
    texture2d<half, access::read> srcLuma,
    texture2d<half, access::read> refLuma,
    int2 pos,
    int2 disp,
    int2 size
) {
    float sad = 0.0f;
    for (int by = -2; by <= 2; ++by) {
        for (int bx = -2; bx <= 2; ++bx) {
            float a = float(srcLuma.read(clampCoord(pos + int2(bx, by), size)).r);
            float b = float(refLuma.read(clampCoord(pos + disp + int2(bx, by), size)).r);
            sad += abs(a - b);
        }
    }
    return sad;
}

kernel void of_block_match_coarse(
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

    // Zero-motion baseline with slight regularization favoring zero displacement on flat tiles.
    float bestCost = blockSAD(srcLuma, refLuma, pos, int2(0), size);
    int2 bestDisp = int2(0);

    // Coarse 2-step search within +/-8 pixels at 1/4 res (= +/-32 full-res pixels).
    for (int dy = -8; dy <= 8; dy += 2) {
        for (int dx = -8; dx <= 8; dx += 2) {
            if (dx == 0 && dy == 0) continue;
            float penalty = 0.002f * float(abs(dx) + abs(dy));
            float cost = blockSAD(srcLuma, refLuma, pos, int2(dx, dy), size) + penalty;
            if (cost < bestCost) {
                bestCost = cost;
                bestDisp = int2(dx, dy);
            }
        }
    }

    // Local 1-pixel refinement around best coarse candidate.
    int2 baseDisp = bestDisp;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            if (dx == 0 && dy == 0) continue;
            int2 cand = baseDisp + int2(dx, dy);
            float penalty = 0.002f * float(abs(cand.x) + abs(cand.y));
            float cost = blockSAD(srcLuma, refLuma, pos, cand, size) + penalty;
            if (cost < bestCost) {
                bestCost = cost;
                bestDisp = cand;
            }
        }
    }

    // Store motion vector in 1/4-res pixel units (scaled by 2 in refine pass).
    flowOut.write(half4(half(bestDisp.x), half(bestDisp.y), 0.0h, 1.0h), gid);
}

kernel void of_block_match_refine(
    texture2d<half, access::read> srcLuma [[texture(0)]],
    texture2d<half, access::read> refLuma [[texture(1)]],
    texture2d<half, access::sample> coarseFlow [[texture(2)]],
    texture2d<half, access::write> refinedFlow [[texture(3)]],
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

    // Upscale coarse vector from 1/4-res to 1/2-res pixel units.
    float2 coarseVec = float2(coarseFlow.sample(linearSam, uv).rg) * 2.0f;
    int2 pred = int2(round(coarseVec));

    float bestCost = blockSAD(srcLuma, refLuma, pos, pred, size);
    int2 bestDisp = pred;

    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            if (dx == 0 && dy == 0) continue;
            int2 cand = pred + int2(dx, dy);
            float penalty = 0.0015f * float(abs(dx) + abs(dy));
            float cost = blockSAD(srcLuma, refLuma, pos, cand, size) + penalty;
            if (cost < bestCost) {
                bestCost = cost;
                bestDisp = cand;
            }
        }
    }

    // Sub-pixel parabolic refinement along X and Y.
    float cCenter = blockSAD(srcLuma, refLuma, pos, bestDisp, size);
    float cLeft   = blockSAD(srcLuma, refLuma, pos, bestDisp + int2(-1, 0), size);
    float cRight  = blockSAD(srcLuma, refLuma, pos, bestDisp + int2( 1, 0), size);
    float cUp     = blockSAD(srcLuma, refLuma, pos, bestDisp + int2(0, -1), size);
    float cDown   = blockSAD(srcLuma, refLuma, pos, bestDisp + int2(0,  1), size);

    float denomX = 2.0f * (cLeft - 2.0f * cCenter + cRight);
    float denomY = 2.0f * (cUp   - 2.0f * cCenter + cDown);
    float subX = (abs(denomX) > 1e-4f) ? clamp((cLeft - cRight) / denomX, -0.5f, 0.5f) : 0.0f;
    float subY = (abs(denomY) > 1e-4f) ? clamp((cUp   - cDown)  / denomY, -0.5f, 0.5f) : 0.0f;

    // Output full-resolution pixel displacement (2x of 1/2-res units).
    float2 fullFlow = (float2(bestDisp) + float2(subX, subY)) * 2.0f;
    refinedFlow.write(half4(half(fullFlow.x), half(fullFlow.y), 0.0h, 1.0h), gid);
}

// MARK: - 3x3 Vector Median Filter (Despeckle Outliers)

inline float median9(thread float (&v)[9]) {
    for (int i = 0; i < 5; ++i) {
        for (int j = i + 1; j < 9; ++j) {
            if (v[j] < v[i]) {
                float tmp = v[i];
                v[i] = v[j];
                v[j] = tmp;
            }
        }
    }
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
    float vx[9], vy[9];
    int idx = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float2 mv = float2(flowIn.read(clampCoord(p + int2(dx, dy), size)).rg);
            vx[idx] = mv.x;
            vy[idx] = mv.y;
            ++idx;
        }
    }

    flowOut.write(half4(half(median9(vx)), half(median9(vy)), 0.0h, 1.0h), gid);
}

// MARK: - Bidirectional Motion-Compensated Warp + Artifact Guard

struct OpticalFlowWarpUniforms {
    float interpolationFactor; // t in [0, 1] between prev (0) and curr (1)
    uint artifactGuardLevel;   // 0 = off, 1 = balanced, 2 = strong
    float sceneDiffScore;      // normalized global frame diff in [0, 1]
    uint _pad0;
};

kernel void of_bidirectional_warp(
    texture2d<float, access::sample> prevFrame [[texture(0)]],
    texture2d<float, access::sample> currFrame [[texture(1)]],
    texture2d<half, access::sample> fwdFlow [[texture(2)]],
    texture2d<half, access::sample> bwdFlow [[texture(3)]],
    texture2d<float, access::write> output [[texture(4)]],
    constant OpticalFlowWarpUniforms &u [[buffer(0)]],
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

    // Bidirectional flow vectors in full-res pixel space:
    // fwd: prev -> curr, bwd: curr -> prev
    float2 mvFwd = float2(fwdFlow.sample(linearSam, uv).rg);
    float2 mvBwd = float2(bwdFlow.sample(linearSam, uv).rg);

    // Symmetric midpoint velocity estimate
    float2 flow = 0.5f * (mvFwd - mvBwd);

    // Forward-backward consistency check (detects disocclusions / fast crossing objects)
    float2 uvAtFwd = saturate(uv + mvFwd * invSize);
    float2 bwdAtFwd = float2(bwdFlow.sample(linearSam, uvAtFwd).rg);
    float fbError = length(mvFwd + bwdAtFwd);

    // Sample motion-compensated prev and curr frames at time t
    float2 uvPrev = saturate(uv - flow * t * invSize);
    float2 uvCurr = saturate(uv + flow * (1.0f - t) * invSize);

    float3 colPrev = prevFrame.sample(linearSam, uvPrev).rgb;
    float3 colCurr = currFrame.sample(linearSam, uvCurr).rgb;

    // Direct (unwarped) samples for static-UI preservation and artifact fallback
    float3 rawPrev = prevFrame.sample(linearSam, uv).rgb;
    float3 rawCurr = currFrame.sample(linearSam, uv).rgb;
    float3 nearerReal = (t < 0.5f) ? rawPrev : rawCurr;

    // Color discrepancy between warped correspondences
    float warpDiscrepancy = length(colPrev - colCurr);

    // Compute motion-compensated blend
    float3 warpedBlend = mix(colPrev, colCurr, t);

    // Artifact Guard: suppress ghosting/tearing on occlusions, high-error motion, or scene cuts
    float guardPull = 0.0f;
    if (u.artifactGuardLevel == 1u) {
        float occPull = smoothstep(3.0f, 12.0f, fbError);
        float colPull = smoothstep(0.18f, 0.45f, warpDiscrepancy);
        float cutPull = smoothstep(0.18f, 0.35f, u.sceneDiffScore);
        guardPull = max(max(occPull * 0.65f, colPull * 0.65f), cutPull);
    } else if (u.artifactGuardLevel >= 2u) {
        float occPull = smoothstep(1.5f, 7.0f, fbError);
        float colPull = smoothstep(0.10f, 0.30f, warpDiscrepancy);
        float cutPull = smoothstep(0.12f, 0.25f, u.sceneDiffScore);
        guardPull = max(max(occPull * 0.85f, colPull * 0.85f), cutPull);
    }

    // Preserve static UI/text cleanly when local pixels are unchanged across frames
    float staticDelta = length(rawPrev - rawCurr);
    float staticMask = 1.0f - smoothstep(0.005f, 0.03f, staticDelta);

    float3 finalColor = mix(warpedBlend, nearerReal, saturate(max(guardPull, staticMask)));
    output.write(float4(max(finalColor, float3(0.0f)), 1.0f), gid);
}
