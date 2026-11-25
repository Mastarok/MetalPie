#include <metal_stdlib>
using namespace metal;

// ============================================================================
// MetalPie Common Shaders:
// - Crop & Blit
// - 1x Non-Retina Demagnification (Nearest & Bilinear, Wine/CrossOver 4x win)
// - GPU Duplicate Frame Detector (Tiled atomic early-exit, zero CPU readback)
// - BGRA/RGBA16F <-> NV12 (420v BT.709 Video Range) for VideoToolbox ML
// - Single-pass TBDR Present (9-point alignment, black letterbox, HDR/EDR,
//   optional in-pass VRR cursor sprite & HUD overlay compositing)
// ============================================================================

inline uint2 clampCoord(int2 p, int2 size) {
    return uint2(clamp(p, int2(0), max(size - int2(1), int2(0))));
}

// MARK: - Crop & Blit

struct CropUniforms {
    uint2 cropOrigin;
    uint2 cropSize;
};

kernel void cropBlit(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant CropUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }
    int2 srcSize = int2(source.get_width(), source.get_height());
    uint2 srcCoord = clampCoord(int2(u.cropOrigin + gid), srcSize);
    destination.write(source.read(srcCoord), gid);
}

// MARK: - 1x Non-Retina Demagnification (MetalGoose Wine/CrossOver optimization)

kernel void demagnifyNearest(
    texture2d<half, access::read> magnified [[texture(0)]],
    texture2d<half, access::write> content [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= content.get_width() || gid.y >= content.get_height()) {
        return;
    }
    int2 magSize = int2(magnified.get_width(), magnified.get_height());
    uint2 srcCoord = clampCoord(int2(gid * 2u), magSize);
    content.write(magnified.read(srcCoord), gid);
}

inline void bilinearDemagTaps(uint i, uint n, uint magDim, thread uint (&index)[4], thread float (&weight)[4]) {
    if (i == 0 || i + 1 >= n) {
        uint edge = (i == 0) ? 0u : min(2u * n - 1u, magDim > 0u ? magDim - 1u : 0u);
        index[0] = edge;
        weight[0] = 1.0f;
        for (uint k = 1; k < 4; ++k) {
            index[k] = edge;
            weight[k] = 0.0f;
        }
        return;
    }
    uint maxIdx = magDim > 0u ? magDim - 1u : 0u;
    index[0] = min(2u * i - 1u, maxIdx);
    index[1] = min(2u * i, maxIdx);
    index[2] = min(2u * i + 1u, maxIdx);
    index[3] = min(2u * i + 2u, maxIdx);
    weight[0] = -0.25f;
    weight[1] = 0.75f;
    weight[2] = 0.75f;
    weight[3] = -0.25f;
}

kernel void demagnifyBilinear(
    texture2d<float, access::read> magnified [[texture(0)]],
    texture2d<half, access::write> content [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint2 size = uint2(content.get_width(), content.get_height());
    if (gid.x >= size.x || gid.y >= size.y) {
        return;
    }
    const uint magW = magnified.get_width();
    const uint magH = magnified.get_height();

    uint ix[4], iy[4];
    float wx[4], wy[4];
    bilinearDemagTaps(gid.x, size.x, magW, ix, wx);
    bilinearDemagTaps(gid.y, size.y, magH, iy, wy);

    float4 q = float4(0.0f);
    for (uint b = 0; b < 4; ++b) {
        if (wy[b] == 0.0f) continue;
        float4 row = float4(0.0f);
        for (uint a = 0; a < 4; ++a) {
            if (wx[a] != 0.0f) {
                row += wx[a] * magnified.read(uint2(ix[a], iy[b]));
            }
        }
        q += wy[b] * row;
    }
    content.write(half4(saturate(q)), gid);
}

// MARK: - GPU Duplicate Frame Detector (Tiled Atomic Early-Exit)

struct DuplicateCheckUniforms {
    float tolerance;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

kernel void duplicateFrameCheck(
    texture2d<float, access::read> currentTex [[texture(0)]],
    texture2d<float, access::read> prevTex [[texture(1)]],
    device atomic_uint *diffFlag [[buffer(0)]],
    constant DuplicateCheckUniforms &u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Immediate early exit once any tile finds a changed pixel.
    if (atomic_load_explicit(diffFlag, memory_order_relaxed) != 0u) {
        return;
    }

    const uint width = currentTex.get_width();
    const uint height = currentTex.get_height();
    const uint2 base = gid * 2u;
    if (base.x >= width || base.y >= height) {
        return;
    }

    const float tol = max(u.tolerance, 0.0f);
    for (uint dy = 0; dy < 2u; ++dy) {
        uint y = base.y + dy;
        if (y >= height) continue;
        for (uint dx = 0; dx < 2u; ++dx) {
            uint x = base.x + dx;
            if (x >= width) continue;
            float3 a = currentTex.read(uint2(x, y)).rgb;
            float3 b = prevTex.read(uint2(x, y)).rgb;
            float3 d = abs(a - b);
            if (d.r > tol || d.g > tol || d.b > tol) {
                atomic_store_explicit(diffFlag, 1u, memory_order_relaxed);
                return;
            }
        }
    }
}

// MARK: - BGRA/RGBA <-> NV12 (420v BT.709 Video Range) for VideoToolbox ML

constant half3 kBT709Luma = half3(0.2126h, 0.7152h, 0.0722h);

inline void writeNV12Block(
    const thread half3 (&rgb)[4],
    texture2d<half, access::write> luma,
    texture2d<half, access::write> chroma,
    uint2 gid
) {
    const uint2 base = gid * 2u;
    const uint lumaW = luma.get_width();
    const uint lumaH = luma.get_height();
    half3 avg = half3(0.0h);

    for (uint k = 0; k < 4; ++k) {
        half3 c = saturate(rgb[k]);
        uint2 p = base + uint2(k & 1u, k >> 1u);
        if (p.x < lumaW && p.y < lumaH) {
            half yVal = (16.0h + dot(c, kBT709Luma) * 219.0h) / 255.0h;
            luma.write(half4(yVal, 0.0h, 0.0h, 1.0h), p);
        }
        avg += c * 0.25h;
    }

    const half y = dot(avg, kBT709Luma);
    const half cb = (avg.b - y) / 1.8556h;
    const half cr = (avg.r - y) / 1.5748h;
    half cbNorm = saturate((128.0h + cb * 224.0h) / 255.0h);
    half crNorm = saturate((128.0h + cr * 224.0h) / 255.0h);
    chroma.write(half4(cbNorm, crNorm, 0.0h, 1.0h), gid);
}

kernel void bgraToNV12(
    texture2d<half, access::read> input [[texture(0)]],
    texture2d<half, access::write> luma [[texture(1)]],
    texture2d<half, access::write> chroma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= chroma.get_width() || gid.y >= chroma.get_height()) {
        return;
    }
    const int2 inSize = int2(input.get_width(), input.get_height());
    const int2 base = int2(gid * 2u);
    half3 rgb[4];
    for (uint k = 0; k < 4; ++k) {
        uint2 p = clampCoord(base + int2(int(k & 1u), int(k >> 1u)), inSize);
        rgb[k] = input.read(p).rgb;
    }
    writeNV12Block(rgb, luma, chroma, gid);
}

kernel void bgraToNV12Resampled(
    texture2d<half, access::sample> input [[texture(0)]],
    texture2d<half, access::write> luma [[texture(1)]],
    texture2d<half, access::write> chroma [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= chroma.get_width() || gid.y >= chroma.get_height()) {
        return;
    }
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge, coord::normalized);
    const float2 lumaSize = float2(luma.get_width(), luma.get_height());
    const uint2 base = gid * 2u;
    half3 rgb[4];
    for (uint k = 0; k < 4; ++k) {
        float2 uv = (float2(base + uint2(k & 1u, k >> 1u)) + 0.5f) / lumaSize;
        rgb[k] = input.sample(linearSampler, uv).rgb;
    }
    writeNV12Block(rgb, luma, chroma, gid);
}

kernel void nv12ToBGRA(
    texture2d<half, access::sample> luma [[texture(0)]],
    texture2d<half, access::sample> chroma [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge, coord::normalized);
    const float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);

    // Exact texel center at 1:1 and smooth linear filtering if destination differs from NV12 size.
    half yRaw = luma.sample(linearSampler, uv).r;
    half2 cbcrRaw = chroma.sample(linearSampler, uv).rg;

    // Invert BT.709 video range: Y in [16/255, 235/255], Cb/Cr in [16/255, 240/255].
    half y = (yRaw * 255.0h - 16.0h) / 219.0h;
    half cb = (cbcrRaw.x * 255.0h - 128.0h) / 224.0h;
    half cr = (cbcrRaw.y * 255.0h - 128.0h) / 224.0h;

    half r = y + 1.5748h * cr;
    half g = y - 0.187324h * cb - 0.468124h * cr;
    half b = y + 1.8556h * cb;

    output.write(half4(saturate(half3(r, g, b)), 1.0h), gid);
}

// MARK: - Single-Pass TBDR Present (+ Optional In-Pass VRR Cursor & HUD Compositing)

struct PresentUniforms {
    // Normalized [0, 1] Y-down rect of visible scaled image inside destination canvas: (x, y, w, h).
    float4 destRectNorm;
    // Normalized [0, 1] UV sub-rectangle of source texture visible inside destRectNorm: (u0, v0, uw, vh).
    float4 uvRect;
    // Normalized [0, 1] Y-down rect of VRR cursor sprite inside destination canvas: (x, y, w, h).
    float4 cursorRectNorm;
    // Normalized [0, 1] Y-down rect of VRR HUD texture inside destination canvas: (x, y, w, h).
    float4 hudRectNorm;
    // Exposure / EDR scale (1.0 for SDR).
    float exposure;
    // Bit 0: isHDR, Bit 1: hasCursor, Bit 2: cursorNearest, Bit 3: hasHUD,
    // Bit 4: srgbDecode, Bit 5: srgbEncode
    uint flags;
    uint _pad0;
    uint _pad1;
};

struct PresentVertexOut {
    float4 position [[position]];
    float2 screenUV;
};

vertex PresentVertexOut presentVertex(uint vid [[vertex_id]]) {
    // Full-screen single triangle covering NDC [-1, 1] x [-1, 1] with Y-down UV [0, 1].
    float2 pos = float2((vid == 1) ? 3.0f : -1.0f, (vid == 2) ? -3.0f : 1.0f);
    float2 uv = float2((vid == 1) ? 2.0f : 0.0f, (vid == 2) ? 2.0f : 0.0f);
    PresentVertexOut out;
    out.position = float4(pos, 0.0f, 1.0f);
    out.screenUV = uv;
    return out;
}

inline float3 srgbToLinear(float3 c) {
    float3 lo = c / 12.92f;
    float3 hi = pow(max((c + 0.055f) / 1.055f, 0.0f), 2.4f);
    return select(hi, lo, c <= 0.04045f);
}

inline float3 linearToSRGB(float3 c) {
    float3 clamped = max(c, 0.0f);
    float3 lo = clamped * 12.92f;
    float3 hi = 1.055f * pow(clamped, 1.0f / 2.4f) - 0.055f;
    return select(hi, lo, clamped <= 0.0031308f);
}

inline float4 evaluatePresentColor(
    float2 screenUV,
    texture2d<float, access::sample> contentTex,
    texture2d<float, access::sample> cursorTex,
    texture2d<float, access::sample> hudTex,
    constant PresentUniforms &u
) {
    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);
    constexpr sampler nearestSam(filter::nearest, address::clamp_to_edge, coord::normalized);

    const bool isHDR = (u.flags & 1u) != 0u;
    const bool hasCursor = (u.flags & 2u) != 0u;
    const bool cursorNearest = (u.flags & 4u) != 0u;
    const bool hasHUD = (u.flags & 8u) != 0u;
    const bool decodeSRGB = (u.flags & 16u) != 0u;
    const bool encodeSRGB = (u.flags & 32u) != 0u;

    // Crisp solid black letterbox/pillarbox outside destination rect.
    float3 color = float3(0.0f);

    float2 rel = (screenUV - u.destRectNorm.xy) / max(u.destRectNorm.zw, float2(1e-6f));
    if (rel.x >= 0.0f && rel.x <= 1.0f && rel.y >= 0.0f && rel.y <= 1.0f) {
        float2 srcUV = u.uvRect.xy + rel * u.uvRect.zw;
        color = contentTex.sample(linearSam, srcUV).rgb;
        if (decodeSRGB) {
            color = srgbToLinear(color);
        }
        color *= max(u.exposure, 0.0f);
        if (!isHDR) {
            color = saturate(color);
        } else {
            // Preserve extended dynamic range while guarding negative / non-finite values.
            color = max(color, float3(0.0f));
        }
        if (encodeSRGB) {
            color = linearToSRGB(color);
        }
    }

    // Optional in-pass VRR HUD overlay (alpha-over).
    if (hasHUD && u.hudRectNorm.z > 0.0f && u.hudRectNorm.w > 0.0f) {
        float2 hudUV = (screenUV - u.hudRectNorm.xy) / u.hudRectNorm.zw;
        if (hudUV.x >= 0.0f && hudUV.x <= 1.0f && hudUV.y >= 0.0f && hudUV.y <= 1.0f) {
            float4 hudSample = hudTex.sample(linearSam, hudUV);
            color = mix(color, hudSample.rgb, saturate(hudSample.a));
        }
    }

    // Optional in-pass VRR cursor sprite (alpha-over on top of content & HUD).
    if (hasCursor && u.cursorRectNorm.z > 0.0f && u.cursorRectNorm.w > 0.0f) {
        float2 cursorUV = (screenUV - u.cursorRectNorm.xy) / u.cursorRectNorm.zw;
        if (cursorUV.x >= 0.0f && cursorUV.x <= 1.0f && cursorUV.y >= 0.0f && cursorUV.y <= 1.0f) {
            float4 curSample = cursorNearest
                ? cursorTex.sample(nearestSam, cursorUV)
                : cursorTex.sample(linearSam, cursorUV);
            color = mix(color, curSample.rgb, saturate(curSample.a));
        }
    }

    return float4(color, 1.0f);
}

fragment float4 presentFragment(
    PresentVertexOut in [[stage_in]],
    texture2d<float, access::sample> contentTex [[texture(0)]],
    texture2d<float, access::sample> cursorTex [[texture(1)]],
    texture2d<float, access::sample> hudTex [[texture(2)]],
    constant PresentUniforms &u [[buffer(0)]]
) {
    return evaluatePresentColor(in.screenUV, contentTex, cursorTex, hudTex, u);
}

kernel void presentCompute(
    texture2d<float, access::sample> contentTex [[texture(0)]],
    texture2d<float, access::sample> cursorTex [[texture(1)]],
    texture2d<float, access::sample> hudTex [[texture(2)]],
    texture2d<float, access::write> destination [[texture(3)]],
    constant PresentUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = destination.get_width();
    const uint outH = destination.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }
    float2 screenUV = (float2(gid) + 0.5f) / float2(outW, outH);
    float4 outColor = evaluatePresentColor(screenUV, contentTex, cursorTex, hudTex, u);
    destination.write(outColor, gid);
}
