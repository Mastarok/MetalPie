#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Pixel Art & Retro CRT Shaders:
// - xbrz_pass1 / xbrz_pass2: 2-pass YCbCr edge-preserving pixel art upscaler
// - crt_geom: Ray-sphere curvature, Lanczos2 scanlines, phosphor dot mask,
//             vignette, bloom, gamma calibration
// - crt_lottes: Timothy Lottes arcade CRT (hardScan, hardPix, warp, bloom,
//               5 shadow mask styles, brightboost)
// ============================================================================

inline uint2 clampCoord(int2 p, int2 size) {
    return uint2(clamp(p, int2(0), max(size - int2(1), int2(0))));
}

// MARK: - xBRZ Freescale (2-Pass YCbCr Perceptual Pixel-Art Upscaler)

struct XBRZUniforms {
    float equalColorTolerance;        // Default 30.0 (in 0..255 units)
    float edgeThreshold;              // Default 2.2 (steep direction ratio)
    float dominantDirectionThreshold; // Default 3.6
    uint _pad0;
};

constant int XBRZ_BLEND_NONE = 0;
constant int XBRZ_BLEND_NORMAL = 1;
constant int XBRZ_BLEND_DOMINANT = 2;

inline float xbrzDistYCbCr(float3 pixA, float3 pixB) {
    const float3 w = float3(0.2627f, 0.6780f, 0.0593f);
    const float scaleB = 0.5f / (1.0f - w.b);
    const float scaleR = 0.5f / (1.0f - w.r);
    float3 diff = pixA - pixB;
    float Y = dot(diff, w);
    float Cb = scaleB * (diff.b - Y);
    float Cr = scaleR * (diff.r - Y);
    return sqrt(Y * Y + Cb * Cb + Cr * Cr);
}

inline bool xbrzIsPixEqual(float3 pixA, float3 pixB, float tolNorm) {
    return xbrzDistYCbCr(pixA, pixB) < tolNorm;
}

inline bool xbrzEq(float3 a, float3 b) {
    return (a.x == b.x) && (a.y == b.y) && (a.z == b.z);
}

inline bool xbrzNeq(float3 a, float3 b) {
    return !xbrzEq(a, b);
}

inline float xbrzGetLeftRatio(float2 center, float2 origin, float2 direction, float2 scale) {
    float2 P0 = center - origin;
    float dd = max(dot(direction, direction), 1e-6f);
    float2 proj = direction * (dot(P0, direction) / dd);
    float2 distv = P0 - proj;
    float2 orth = float2(-direction.y, direction.x);
    float side = sign(dot(P0, orth));
    float v = side * length(distv * scale);
    const float invSqrt2 = 0.70710678f;
    return smoothstep(-invSqrt2, invSqrt2, v);
}

kernel void xbrz_pass1(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> blendTex [[texture(1)]],
    constant XBRZUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint inW = input.get_width();
    const uint inH = input.get_height();
    if (gid.x >= inW || gid.y >= inH) {
        return;
    }

    const int2 size = int2(inW, inH);
    const int2 center = int2(gid);
    const float tolNorm = clamp(u.equalColorTolerance, 1.0f, 128.0f) / 255.0f;
    const float steepThresh = clamp(u.edgeThreshold > 0.1f ? u.edgeThreshold : 2.2f, 1.0f, 6.0f);
    const float domThresh = clamp(u.dominantDirectionThreshold > 0.1f ? u.dominantDirectionThreshold : 3.6f, 1.0f, 8.0f);

    float3 src[5][5];
    for (int dx = 0; dx < 5; ++dx) {
        for (int dy = 0; dy < 5; ++dy) {
            src[dx][dy] = input.read(clampCoord(center + int2(dx - 2, dy - 2), size)).rgb;
        }
    }

    float3 A = src[1][1];
    float3 B = src[2][1];
    float3 C = src[3][1];
    float3 D = src[1][2];
    float3 E = src[2][2];
    float3 F = src[3][2];
    float3 G = src[1][3];
    float3 H = src[2][3];
    float3 I = src[3][3];

    int4 blendResult = int4(XBRZ_BLEND_NONE);

    // Bottom-right corner (z)
    if (!((xbrzEq(E, F) && xbrzEq(H, I)) || (xbrzEq(E, H) && xbrzEq(F, I)))) {
        float dist_H_F = xbrzDistYCbCr(G, E) + xbrzDistYCbCr(E, C) + xbrzDistYCbCr(src[2][4], I) + xbrzDistYCbCr(I, src[4][2]) + 4.0f * xbrzDistYCbCr(H, F);
        float dist_E_I = xbrzDistYCbCr(D, H) + xbrzDistYCbCr(H, src[3][4]) + xbrzDistYCbCr(B, F) + xbrzDistYCbCr(F, src[4][3]) + 4.0f * xbrzDistYCbCr(E, I);
        bool dominant = (domThresh * dist_H_F) < dist_E_I;
        blendResult.z = ((dist_H_F < dist_E_I) && xbrzNeq(E, F) && xbrzNeq(E, H)) ? (dominant ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
    }

    // Bottom-left corner (w)
    if (!((xbrzEq(D, E) && xbrzEq(G, H)) || (xbrzEq(D, G) && xbrzEq(E, H)))) {
        float dist_G_E = xbrzDistYCbCr(src[0][3], D) + xbrzDistYCbCr(D, B) + xbrzDistYCbCr(src[1][4], H) + xbrzDistYCbCr(H, F) + 4.0f * xbrzDistYCbCr(G, E);
        float dist_D_H = xbrzDistYCbCr(src[0][2], G) + xbrzDistYCbCr(G, src[2][4]) + xbrzDistYCbCr(A, E) + xbrzDistYCbCr(E, I) + 4.0f * xbrzDistYCbCr(D, H);
        bool dominant = (domThresh * dist_D_H) < dist_G_E;
        blendResult.w = ((dist_G_E > dist_D_H) && xbrzNeq(E, D) && xbrzNeq(E, H)) ? (dominant ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
    }

    // Top-right corner (y)
    if (!((xbrzEq(B, C) && xbrzEq(E, F)) || (xbrzEq(B, E) && xbrzEq(C, F)))) {
        float dist_E_C = xbrzDistYCbCr(D, B) + xbrzDistYCbCr(B, src[3][0]) + xbrzDistYCbCr(H, F) + xbrzDistYCbCr(F, src[4][1]) + 4.0f * xbrzDistYCbCr(E, C);
        float dist_B_F = xbrzDistYCbCr(A, E) + xbrzDistYCbCr(E, I) + xbrzDistYCbCr(src[2][0], C) + xbrzDistYCbCr(C, src[4][2]) + 4.0f * xbrzDistYCbCr(B, F);
        bool dominant = (domThresh * dist_B_F) < dist_E_C;
        blendResult.y = ((dist_E_C > dist_B_F) && xbrzNeq(E, B) && xbrzNeq(E, F)) ? (dominant ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
    }

    // Top-left corner (x)
    if (!((xbrzEq(A, B) && xbrzEq(D, E)) || (xbrzEq(A, D) && xbrzEq(B, E)))) {
        float dist_D_B = xbrzDistYCbCr(src[0][2], A) + xbrzDistYCbCr(A, src[2][0]) + xbrzDistYCbCr(G, E) + xbrzDistYCbCr(E, C) + 4.0f * xbrzDistYCbCr(D, B);
        float dist_A_E = xbrzDistYCbCr(src[0][1], D) + xbrzDistYCbCr(D, H) + xbrzDistYCbCr(src[1][0], B) + xbrzDistYCbCr(B, F) + 4.0f * xbrzDistYCbCr(A, E);
        bool dominant = (domThresh * dist_D_B) < dist_A_E;
        blendResult.x = ((dist_D_B < dist_A_E) && xbrzNeq(E, D) && xbrzNeq(E, B)) ? (dominant ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
    }

    float4 packed = float4(blendResult);

    if (blendResult.z == XBRZ_BLEND_DOMINANT || (blendResult.z == XBRZ_BLEND_NORMAL &&
        !((blendResult.y != XBRZ_BLEND_NONE && !xbrzIsPixEqual(E, G, tolNorm)) ||
          (blendResult.w != XBRZ_BLEND_NONE && !xbrzIsPixEqual(E, C, tolNorm)) ||
          (xbrzIsPixEqual(G, H, tolNorm) && xbrzIsPixEqual(H, I, tolNorm) && xbrzIsPixEqual(I, F, tolNorm) && xbrzIsPixEqual(F, C, tolNorm) && !xbrzIsPixEqual(E, I, tolNorm))))) {
        packed.z += 4.0f;
        float dist_F_G = xbrzDistYCbCr(F, G);
        float dist_H_C = xbrzDistYCbCr(H, C);
        if ((steepThresh * dist_F_G <= dist_H_C) && xbrzNeq(E, G) && xbrzNeq(D, G)) packed.z += 16.0f;
        if ((steepThresh * dist_H_C <= dist_F_G) && xbrzNeq(E, C) && xbrzNeq(B, C)) packed.z += 64.0f;
    }

    if (blendResult.w == XBRZ_BLEND_DOMINANT || (blendResult.w == XBRZ_BLEND_NORMAL &&
        !((blendResult.z != XBRZ_BLEND_NONE && !xbrzIsPixEqual(E, A, tolNorm)) ||
          (blendResult.x != XBRZ_BLEND_NONE && !xbrzIsPixEqual(E, I, tolNorm)) ||
          (xbrzIsPixEqual(A, D, tolNorm) && xbrzIsPixEqual(D, G, tolNorm) && xbrzIsPixEqual(G, H, tolNorm) && xbrzIsPixEqual(H, I, tolNorm) && !xbrzIsPixEqual(E, G, tolNorm))))) {
        packed.w += 4.0f;
        float dist_H_A = xbrzDistYCbCr(H, A);
        float dist_D_I = xbrzDistYCbCr(D, I);
        if ((steepThresh * dist_H_A <= dist_D_I) && xbrzNeq(E, A) && xbrzNeq(B, A)) packed.w += 16.0f;
        if ((steepThresh * dist_D_I <= dist_H_A) && xbrzNeq(E, I) && xbrzNeq(F, I)) packed.w += 64.0f;
    }

    if (blendResult.y == XBRZ_BLEND_DOMINANT || (blendResult.y == XBRZ_BLEND_NORMAL &&
        !((blendResult.x != XBRZ_BLEND_NONE && !xbrzIsPixEqual(E, I, tolNorm)) ||
          (blendResult.z != XBRZ_BLEND_NONE && !xbrzIsPixEqual(E, A, tolNorm)) ||
          (xbrzIsPixEqual(I, F, tolNorm) && xbrzIsPixEqual(F, C, tolNorm) && xbrzIsPixEqual(C, B, tolNorm) && xbrzIsPixEqual(B, A, tolNorm) && !xbrzIsPixEqual(E, C, tolNorm))))) {
        packed.y += 4.0f;
        float dist_B_I = xbrzDistYCbCr(B, I);
        float dist_F_A = xbrzDistYCbCr(F, A);
        if ((steepThresh * dist_B_I <= dist_F_A) && xbrzNeq(E, I) && xbrzNeq(H, I)) packed.y += 16.0f;
        if ((steepThresh * dist_F_A <= dist_B_I) && xbrzNeq(E, A) && xbrzNeq(D, A)) packed.y += 64.0f;
    }

    if (blendResult.x == XBRZ_BLEND_DOMINANT || (blendResult.x == XBRZ_BLEND_NORMAL &&
        !((blendResult.w != XBRZ_BLEND_NONE && !xbrzIsPixEqual(E, C, tolNorm)) ||
          (blendResult.y != XBRZ_BLEND_NONE && !xbrzIsPixEqual(E, G, tolNorm)) ||
          (xbrzIsPixEqual(C, B, tolNorm) && xbrzIsPixEqual(B, A, tolNorm) && xbrzIsPixEqual(A, D, tolNorm) && xbrzIsPixEqual(D, G, tolNorm) && !xbrzIsPixEqual(E, A, tolNorm))))) {
        packed.x += 4.0f;
        float dist_D_C = xbrzDistYCbCr(D, C);
        float dist_B_G = xbrzDistYCbCr(B, G);
        if ((steepThresh * dist_D_C <= dist_B_G) && xbrzNeq(E, C) && xbrzNeq(F, C)) packed.x += 16.0f;
        if ((steepThresh * dist_B_G <= dist_D_C) && xbrzNeq(E, G) && xbrzNeq(H, G)) packed.x += 64.0f;
    }

    blendTex.write(packed / 255.0f, gid);
}

kernel void xbrz_pass2(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::sample> blendTex [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler pointSam(filter::nearest, address::clamp_to_edge, coord::normalized);

    const float2 inputSize = float2(input.get_width(), input.get_height());
    const float2 outputSize = float2(outW, outH);
    const float2 inputPt = 1.0f / inputSize;
    const float2 pos = (float2(gid) + 0.5f) / outputSize;
    const float2 scale = outputSize / inputSize;
    const float2 f = fract(pos * inputSize) - 0.5f;

    float3 B = input.sample(pointSam, pos + float2( 0.0f, -1.0f) * inputPt).rgb;
    float3 D = input.sample(pointSam, pos + float2(-1.0f,  0.0f) * inputPt).rgb;
    float3 E = input.sample(pointSam, pos).rgb;
    float3 F = input.sample(pointSam, pos + float2( 1.0f,  0.0f) * inputPt).rgb;
    float3 H = input.sample(pointSam, pos + float2( 0.0f,  1.0f) * inputPt).rgb;

    float4 info = floor(blendTex.sample(pointSam, pos) * 255.0f + 0.5f);
    float4 blendResult = floor(fmod(info, 4.0f));
    float4 doLineBlend = floor(fmod(info / 4.0f, 4.0f));
    float4 haveShallowLine = floor(fmod(info / 16.0f, 4.0f));
    float4 haveSteepLine = floor(fmod(info / 64.0f, 4.0f));

    const float invSqrt2 = 0.70710678f;
    float3 res = E;

    if (blendResult.z > 0.0f) {
        float2 origin = float2(0.0f, invSqrt2);
        float2 direction = float2(1.0f, -1.0f);
        if (doLineBlend.z > 0.0f) {
            origin = (haveShallowLine.z > 0.0f) ? float2(0.0f, 0.25f) : float2(0.0f, 0.5f);
            direction.x += haveShallowLine.z;
            direction.y -= haveSteepLine.z;
        }
        float3 blendPix = mix(H, F, step(xbrzDistYCbCr(E, F), xbrzDistYCbCr(E, H)));
        res = mix(res, blendPix, xbrzGetLeftRatio(f, origin, direction, scale));
    }

    if (blendResult.w > 0.0f) {
        float2 origin = float2(-invSqrt2, 0.0f);
        float2 direction = float2(1.0f, 1.0f);
        if (doLineBlend.w > 0.0f) {
            origin = (haveShallowLine.w > 0.0f) ? float2(-0.25f, 0.0f) : float2(-0.5f, 0.0f);
            direction.y += haveShallowLine.w;
            direction.x += haveSteepLine.w;
        }
        float3 blendPix = mix(H, D, step(xbrzDistYCbCr(E, D), xbrzDistYCbCr(E, H)));
        res = mix(res, blendPix, xbrzGetLeftRatio(f, origin, direction, scale));
    }

    if (blendResult.y > 0.0f) {
        float2 origin = float2(invSqrt2, 0.0f);
        float2 direction = float2(-1.0f, -1.0f);
        if (doLineBlend.y > 0.0f) {
            origin = (haveShallowLine.y > 0.0f) ? float2(0.25f, 0.0f) : float2(0.5f, 0.0f);
            direction.y -= haveShallowLine.y;
            direction.x -= haveSteepLine.y;
        }
        float3 blendPix = mix(F, B, step(xbrzDistYCbCr(E, B), xbrzDistYCbCr(E, F)));
        res = mix(res, blendPix, xbrzGetLeftRatio(f, origin, direction, scale));
    }

    if (blendResult.x > 0.0f) {
        float2 origin = float2(0.0f, -invSqrt2);
        float2 direction = float2(-1.0f, 1.0f);
        if (doLineBlend.x > 0.0f) {
            origin = (haveShallowLine.x > 0.0f) ? float2(0.0f, -0.25f) : float2(0.0f, -0.5f);
            direction.x -= haveShallowLine.x;
            direction.y += haveSteepLine.x;
        }
        float3 blendPix = mix(D, B, step(xbrzDistYCbCr(E, B), xbrzDistYCbCr(E, D)));
        res = mix(res, blendPix, xbrzGetLeftRatio(f, origin, direction, scale));
    }

    output.write(float4(res, 1.0f), gid);
}

// MARK: - CRT-Geom

struct CRTGeomUniforms {
    uint curvature;
    float crtGamma;
    float monitorGamma;
    float scanlineWeight;
    float dotMask;
    float cornerSize;
    float vignette;
    float bloom;
    float curvatureRadius;
    uint maskType; // 0 = apertureGrille, 1 = shadowMask, 2 = slotMask, 3 = off
    float brightness;
    uint _pad0;
};

inline float crtFix(float c) { return max(abs(c), 1e-5f); }
inline float4 crtFix4(float4 c) { return max(abs(c), float4(1e-5f)); }

inline float crtIntersect(float2 xy, float4 sc, float dist, float radius) {
    float A = dot(xy, xy) + dist * dist;
    float B = 2.0f * (radius * (dot(xy, sc.xy) - dist * sc.z * sc.w) - dist * dist);
    float C = dist * dist + 2.0f * radius * dist * sc.z * sc.w;
    return (-B - sqrt(max(B * B - 4.0f * A * C, 0.0f))) / max(2.0f * A, 1e-6f);
}

inline float2 crtBkwtrans(float2 xy, float4 sc, float dist, float radius) {
    float c = crtIntersect(xy, sc, dist, radius);
    float2 pt = (c * xy + radius * sc.xy) / radius;
    float2 tang = sc.xy / sc.zw;
    float2 poc = pt / sc.zw;
    float A = dot(tang, tang) + 1.0f;
    float B = -2.0f * dot(poc, tang);
    float C = dot(poc, poc) - 1.0f;
    float a = (-B + sqrt(max(B * B - 4.0f * A * C, 0.0f))) / max(2.0f * A, 1e-6f);
    float2 uv = (pt - a * sc.xy) / sc.zw;
    float r = crtFix(radius * acos(clamp(a, -1.0f, 1.0f)));
    return uv * r / sin(r / radius);
}

inline float2 crtFwtrans(float2 uv, float4 sc, float dist, float radius) {
    float r = crtFix(length(uv));
    uv *= sin(r / radius) / r;
    float x = 1.0f - cos(r / radius);
    float D = dist / radius + x * sc.z * sc.w + dot(uv, sc.xy);
    return dist * (uv * sc.zw - x * sc.xy) / max(D, 1e-6f);
}

inline float3 crtMaxScale(float4 sc, float dist, float radius, float2 aspect) {
    float2 c = crtBkwtrans(-radius * sc.xy / (1.0f + radius / dist * sc.z * sc.w), sc, dist, radius);
    float2 a = 0.5f * aspect;
    float2 lo = float2(crtFwtrans(float2(-a.x, c.y), sc, dist, radius).x,
                       crtFwtrans(float2(c.x, -a.y), sc, dist, radius).y) / aspect;
    float2 hi = float2(crtFwtrans(float2( a.x, c.y), sc, dist, radius).x,
                       crtFwtrans(float2(c.x,  a.y), sc, dist, radius).y) / aspect;
    return float3((hi + lo) * aspect * 0.5f, max(hi.x - lo.x, hi.y - lo.y));
}

inline float4 crtScanlineWeights(float distance1, float4 color, float scanlineWeight, float lum) {
    float4 safeCol = max(color, float4(0.0f));
    float4 wid = 2.0f + 2.0f * pow(safeCol, 4.0f);
    float v = abs(distance1) / max(scanlineWeight, 0.05f);
    float4 weights = float4(v);
    float4 base = max(weights * rsqrt(0.5f * wid), float4(0.0f));
    return (lum + 1.4f) * exp(-pow(base, wid)) / (0.6f + 0.2f * wid);
}

inline float4 crtTex2D(texture2d<float, access::sample> input, sampler sam, float2 c, float crtGamma) {
    float4 s = max(input.sample(sam, c), float4(0.0f));
    return pow(s, crtGamma);
}

kernel void crt_geom(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant CRTGeomUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler pointSam(filter::nearest, address::clamp_to_edge, coord::normalized);

    const float2 inputSize = float2(input.get_width(), input.get_height());
    const float2 outputSize = float2(outW, outH);
    const float2 pos = (float2(gid) + 0.5f) / outputSize;

    const float crtGamma = max(u.crtGamma, 0.5f);
    const float monitorGamma = max(u.monitorGamma, 0.5f);
    const float scanlineWeight = clamp(u.scanlineWeight, 0.08f, 0.8f);
    const float dotMask = clamp(u.dotMask, 0.0f, 1.0f);
    const float cornerSize = max(u.cornerSize, 0.0005f);
    const float dist = 1.5f;
    const float radius = clamp(u.curvatureRadius > 0.1f ? u.curvatureRadius : 2.0f, 0.8f, 6.0f);
    const float halation = clamp(u.bloom, 0.0f, 1.0f);
    const float brightBoost = clamp(u.brightness > 0.01f ? u.brightness : 1.0f, 0.5f, 1.6f);
    const float cornerSmooth = 1000.0f;
    const float2 aspect = float2(1.0f, 0.75f);
    const float4 sinCos = float4(0.0f, 0.0f, 1.0f, 1.0f);

    float2 xy = pos;
    if (u.curvature != 0u) {
        float3 stretch = crtMaxScale(sinCos, dist, radius, aspect);
        float2 cd = (pos - 0.5f) * aspect * stretch.z + stretch.xy;
        xy = crtBkwtrans(cd, sinCos, dist, radius) / aspect + float2(0.5f);
    }

    // Rounded screen corner mask
    float2 cd2 = min(xy, 1.0f - xy) * aspect;
    float2 cdist = float2(cornerSize);
    float2 cdelta = cdist - min(cd2, cdist);
    float cval = clamp((cdist.x - length(cdelta)) * cornerSmooth, 0.0f, 1.0f);

    float2 ilfac = float2(1.0f, clamp(floor(inputSize.y / 1000.0f), 1.0f, 2.0f));
    float2 one = ilfac / inputSize;
    float2 ratioScale = (xy * inputSize - 0.5f) / ilfac;
    float filter = inputSize.y / outputSize.y;
    float2 uvRatio = fract(ratioScale);
    xy = (floor(ratioScale) * ilfac + 0.5f) / inputSize;

    // Lanczos2 horizontal filter
    const float pi = 3.141592653589f;
    float4 coeffs = pi * float4(1.0f + uvRatio.x, uvRatio.x, 1.0f - uvRatio.x, 2.0f - uvRatio.x);
    coeffs = crtFix4(coeffs);
    coeffs = 2.0f * sin(coeffs) * sin(coeffs * 0.5f) / (coeffs * coeffs);
    coeffs /= max(dot(coeffs, float4(1.0f)), 1e-6f);

    float4 col = clamp(
        coeffs.x * crtTex2D(input, pointSam, xy + float2(-one.x, 0.0f), crtGamma) +
        coeffs.y * crtTex2D(input, pointSam, xy, crtGamma) +
        coeffs.z * crtTex2D(input, pointSam, xy + float2( one.x, 0.0f), crtGamma) +
        coeffs.w * crtTex2D(input, pointSam, xy + float2(2.0f * one.x, 0.0f), crtGamma),
        0.0f, 1.0f
    );
    float4 col2 = clamp(
        coeffs.x * crtTex2D(input, pointSam, xy + float2(-one.x, one.y), crtGamma) +
        coeffs.y * crtTex2D(input, pointSam, xy + float2( 0.0f, one.y), crtGamma) +
        coeffs.z * crtTex2D(input, pointSam, xy + one, crtGamma) +
        coeffs.w * crtTex2D(input, pointSam, xy + float2(2.0f * one.x, one.y), crtGamma),
        0.0f, 1.0f
    );

    float4 weights  = crtScanlineWeights(uvRatio.y, col, scanlineWeight, halation * 0.25f);
    float4 weights2 = crtScanlineWeights(1.0f - uvRatio.y, col2, scanlineWeight, halation * 0.25f);

    float uvY = uvRatio.y + (1.0f / 3.0f) * filter;
    weights  = (weights  + crtScanlineWeights(uvY, col, scanlineWeight, halation * 0.25f)) / 3.0f;
    weights2 = (weights2 + crtScanlineWeights(abs(1.0f - uvY), col2, scanlineWeight, halation * 0.25f)) / 3.0f;
    uvY -= (2.0f / 3.0f) * filter;
    weights  += crtScanlineWeights(abs(uvY), col, scanlineWeight, halation * 0.25f) / 3.0f;
    weights2 += crtScanlineWeights(abs(1.0f - uvY), col2, scanlineWeight, halation * 0.25f) / 3.0f;

    float3 mulRes = (col * weights + col2 * weights2).rgb;

    // Soft phosphor halation / glow around bright highlights
    if (halation > 0.001f) {
        float3 glowSample = (col.rgb + col2.rgb) * 0.5f;
        float glowLuma = dot(glowSample, float3(0.2126f, 0.7152f, 0.0722f));
        mulRes += glowSample * smoothstep(0.15f, 1.0f, glowLuma) * halation * 0.35f;
    }

    mulRes *= brightBoost;

    // Subtle CRT tube vignette
    if (u.vignette > 0.0f) {
        float2 vpos = pos * 2.0f - 1.0f;
        float vig = saturate(1.0f - u.vignette * dot(vpos, vpos) * 0.35f);
        mulRes *= vig;
    }

    mulRes *= cval;

    // Selectable phosphor mask: 0=Aperture Grille, 1=Shadow Mask, 2=Slot Mask, 3=Off
    if (u.maskType != 3u && dotMask > 0.001f) {
        float strength = dotMask * 0.45f;
        float3 maskWeights = float3(1.0f);
        if (u.maskType == 0u) {
            // Aperture Grille (Trinitron alternating vertical RGB/GM stripes)
            maskWeights = mix(
                float3(1.0f, 1.0f - strength, 1.0f),
                float3(1.0f - strength, 1.0f, 1.0f - strength),
                floor(fmod(float(gid.x), 2.0f))
            );
        } else if (u.maskType == 1u) {
            // Shadow Mask (staggered RGB phosphor dot triad)
            float phase = fmod(float(gid.x) + floor(fmod(float(gid.y), 2.0f)) * 1.5f, 3.0f);
            float3 triad = float3(1.0f - strength);
            if (phase < 1.0f) triad.r = 1.0f;
            else if (phase < 2.0f) triad.g = 1.0f;
            else triad.b = 1.0f;
            maskWeights = triad;
        } else {
            // Slot Mask (arcade staggered brick RGB slots with horizontal dark bars)
            uint colIdx = gid.x % 3u;
            uint rowBrick = (gid.y + ((gid.x / 3u) % 2u) * 2u) % 4u;
            float3 slot = float3(1.0f - strength * 0.85f);
            if (colIdx == 0u) slot.r = 1.0f;
            else if (colIdx == 1u) slot.g = 1.0f;
            else slot.b = 1.0f;
            if (rowBrick == 3u) slot *= (1.0f - strength * 0.6f);
            maskWeights = slot;
        }
        mulRes *= maskWeights;
    }

    mulRes = pow(max(mulRes, float3(0.0f)), 1.0f / monitorGamma);
    output.write(float4(saturate(mulRes), 1.0f), gid);
}

// MARK: - CRT-Lottes (Timothy Lottes Arcade CRT)

struct CRTLottesUniforms {
    float hardScan;
    float hardPix;
    float warpX;
    float warpY;
    float maskDark;
    float maskLight;
    uint shadowMask;
    float brightBoost;
};

inline float3 lottesFetch(texture2d<float, access::sample> input, sampler sam, float2 pos, float2 off, float2 texSize, float brightBoost) {
    float2 p = (floor(pos * texSize + off) + float2(0.5f)) / texSize;
    if (p.x < 0.0f || p.x > 1.0f || p.y < 0.0f || p.y > 1.0f) {
        return float3(0.0f);
    }
    return brightBoost * pow(max(input.sample(sam, p).rgb, float3(0.0f)), 2.2f);
}

inline float2 lottesDist(float2 pos, float2 texSize) {
    float2 p = pos * texSize;
    return -((p - floor(p)) - float2(0.5f));
}

inline float lottesGaus(float pos, float scale) {
    return exp2(scale * pos * pos);
}

inline float3 lottesHorz3(texture2d<float, access::sample> input, sampler sam, float2 pos, float off, float2 texSize, float hardPix, float brightBoost) {
    float3 b = lottesFetch(input, sam, pos, float2(-1.0f, off), texSize, brightBoost);
    float3 c = lottesFetch(input, sam, pos, float2( 0.0f, off), texSize, brightBoost);
    float3 d = lottesFetch(input, sam, pos, float2( 1.0f, off), texSize, brightBoost);
    float dst = lottesDist(pos, texSize).x;
    float wb = lottesGaus(dst - 1.0f, hardPix);
    float wc = lottesGaus(dst,        hardPix);
    float wd = lottesGaus(dst + 1.0f, hardPix);
    return (b * wb + c * wc + d * wd) / max(wb + wc + wd, 1e-6f);
}

inline float3 lottesHorz5(texture2d<float, access::sample> input, sampler sam, float2 pos, float off, float2 texSize, float hardPix, float brightBoost) {
    float3 a = lottesFetch(input, sam, pos, float2(-2.0f, off), texSize, brightBoost);
    float3 b = lottesFetch(input, sam, pos, float2(-1.0f, off), texSize, brightBoost);
    float3 c = lottesFetch(input, sam, pos, float2( 0.0f, off), texSize, brightBoost);
    float3 d = lottesFetch(input, sam, pos, float2( 1.0f, off), texSize, brightBoost);
    float3 e = lottesFetch(input, sam, pos, float2( 2.0f, off), texSize, brightBoost);
    float dst = lottesDist(pos, texSize).x;
    float wa = lottesGaus(dst - 2.0f, hardPix);
    float wb = lottesGaus(dst - 1.0f, hardPix);
    float wc = lottesGaus(dst,        hardPix);
    float wd = lottesGaus(dst + 1.0f, hardPix);
    float we = lottesGaus(dst + 2.0f, hardPix);
    return (a * wa + b * wb + c * wc + d * wd + e * we) / max(wa + wb + wc + wd + we, 1e-6f);
}

inline float3 lottesMask(float2 pos, uint shadowMask, float maskDark, float maskLight) {
    float3 mask = float3(maskDark);
    if (shadowMask == 1u) {
        // Compressed TV dot triad
        float maskLine = maskLight;
        float odd = (fract(pos.x / 6.0f) < 0.5f) ? 1.0f : 0.0f;
        if (fract((pos.y + odd) / 2.0f) < 0.5f) maskLine = maskDark;
        float x = fract(pos.x / 3.0f);
        if (x < 0.333f) mask.r = maskLight;
        else if (x < 0.666f) mask.g = maskLight;
        else mask.b = maskLight;
        mask *= maskLine;
    } else if (shadowMask == 2u) {
        // Aperture grille
        float x = fract(pos.x / 3.0f);
        if (x < 0.333f) mask.r = maskLight;
        else if (x < 0.666f) mask.g = maskLight;
        else mask.b = maskLight;
    } else if (shadowMask == 3u) {
        // Stretched VGA shadow mask
        float x = fract((pos.x + pos.y * 3.0f) / 6.0f);
        if (x < 0.333f) mask.r = maskLight;
        else if (x < 0.666f) mask.g = maskLight;
        else mask.b = maskLight;
    } else if (shadowMask == 4u) {
        // Fine VGA shadow mask
        float2 p = floor(pos * float2(1.0f, 0.5f));
        float x = fract((p.x + p.y * 3.0f) / 6.0f);
        if (x < 0.333f) mask.r = maskLight;
        else if (x < 0.666f) mask.g = maskLight;
        else mask.b = maskLight;
    } else {
        return float3(1.0f);
    }
    return mask;
}

kernel void crt_lottes(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant CRTLottesUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler pointSam(filter::nearest, address::clamp_to_edge, coord::normalized);

    const float2 inputSize = float2(input.get_width(), input.get_height());
    const float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);

    // Barrel warp
    float2 warped = uv * 2.0f - 1.0f;
    warped *= float2(1.0f + (warped.y * warped.y) * u.warpX, 1.0f + (warped.x * warped.x) * u.warpY);
    warped = warped * 0.5f + 0.5f;

    float dy = lottesDist(warped, inputSize).y;
    float3 lineA = lottesHorz3(input, pointSam, warped, -1.0f, inputSize, u.hardPix, u.brightBoost);
    float3 lineB = lottesHorz5(input, pointSam, warped,  0.0f, inputSize, u.hardPix, u.brightBoost);
    float3 lineC = lottesHorz3(input, pointSam, warped,  1.0f, inputSize, u.hardPix, u.brightBoost);

    float wa = lottesGaus(dy - 1.0f, u.hardScan);
    float wb = lottesGaus(dy,        u.hardScan);
    float wc = lottesGaus(dy + 1.0f, u.hardScan);
    float3 outColor = lineA * wa + lineB * wb + lineC * wc;

    // Subtle phosphor bloom
    float3 bloom = (
        lottesHorz5(input, pointSam, warped, -1.0f, inputSize, -1.5f, u.brightBoost) * lottesGaus(dy - 1.0f, -2.0f) +
        lottesHorz5(input, pointSam, warped,  0.0f, inputSize, -1.5f, u.brightBoost) * lottesGaus(dy,        -2.0f) +
        lottesHorz5(input, pointSam, warped,  1.0f, inputSize, -1.5f, u.brightBoost) * lottesGaus(dy + 1.0f, -2.0f)
    );
    outColor += bloom * 0.12f;

    if (u.shadowMask != 0u) {
        outColor *= lottesMask(float2(gid) + 0.5f, u.shadowMask, u.maskDark, u.maskLight);
    }

    float3 gammaOut = pow(max(outColor, float3(0.0f)), 1.0f / 2.2f);
    output.write(float4(saturate(gammaOut), 1.0f), gid);
}
