#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Sharpening Shaders:
// - cas_sharpen: AMD FidelityFX Contrast Adaptive Sharpening (linear/HDR aware)
// - adaptive_sharpen_pass1 / adaptive_sharpen_pass2:
//     2-pass edge-aware curve sharpening avoiding haloing (tanh overshoot limit)
// ============================================================================

inline uint2 clampCoord(int2 p, int2 size) {
    return uint2(clamp(p, int2(0), max(size - int2(1), int2(0))));
}

inline float3 min3v(float3 a, float3 b, float3 c) { return min(a, min(b, c)); }
inline float3 max3v(float3 a, float3 b, float3 c) { return max(a, max(b, c)); }

// MARK: - AMD FidelityFX CAS

struct CASUniforms {
    float sharpness;
    uint isHDR;
    uint _pad0;
    uint _pad1;
};

inline float3 casToWorking(float3 c, bool isHDR) {
    if (!isHDR) {
        // Approximate sRGB -> linear for accurate contrast math.
        float3 s = saturate(c);
        return s * s;
    }
    float3 x = max(c, 0.0f);
    return x / (1.0f + x);
}

inline float3 casFromWorking(float3 c, bool isHDR) {
    if (!isHDR) {
        return sqrt(saturate(c));
    }
    float3 x = clamp(c, 0.0f, 0.9995f);
    return x / (1.0f - x);
}

kernel void cas_sharpen(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant CASUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    const int2 size = int2(input.get_width(), input.get_height());
    const int2 p = int2(gid);
    const bool hdr = (u.isHDR != 0u);

    // 3x3 neighborhood:
    //  a b c
    //  d e f
    //  g h i
    float3 a = casToWorking(input.read(clampCoord(p + int2(-1, -1), size)).rgb, hdr);
    float3 b = casToWorking(input.read(clampCoord(p + int2( 0, -1), size)).rgb, hdr);
    float3 c = casToWorking(input.read(clampCoord(p + int2( 1, -1), size)).rgb, hdr);
    float3 d = casToWorking(input.read(clampCoord(p + int2(-1,  0), size)).rgb, hdr);
    float3 e = casToWorking(input.read(clampCoord(p,                size)).rgb, hdr);
    float3 f = casToWorking(input.read(clampCoord(p + int2( 1,  0), size)).rgb, hdr);
    float3 g = casToWorking(input.read(clampCoord(p + int2(-1,  1), size)).rgb, hdr);
    float3 h = casToWorking(input.read(clampCoord(p + int2( 0,  1), size)).rgb, hdr);
    float3 i = casToWorking(input.read(clampCoord(p + int2( 1,  1), size)).rgb, hdr);

    // Soft min/max combining cross + full 3x3 diagonals (CAS_BETTER_DIAGONALS).
    float3 mn = min(min3v(d, e, f), min(b, h));
    float3 mn2 = min(min(mn, min(a, c)), min(g, i));
    mn += mn2;

    float3 mx = max(max3v(d, e, f), max(b, h));
    float3 mx2 = max(max(mx, max(a, c)), max(g, i));
    mx += mx2;

    float3 amp = saturate(min(mn, 2.0f - mx) / max(mx, float3(1e-6f)));
    amp = sqrt(amp);

    float sharpness = clamp(u.sharpness, 0.0f, 1.0f);
    float peak = -1.0f / mix(8.0f, 5.0f, sharpness);
    float w = amp.g * peak;
    float rcpWeight = 1.0f / (1.0f + 4.0f * w);

    float3 outWork = saturate((w * (b + d + f + h) + e) * rcpWeight);
    float3 finalRGB = casFromWorking(outWork, hdr);
    output.write(float4(finalRGB, 1.0f), gid);
}

// MARK: - 2-Pass Adaptive Sharpen

struct AdaptiveSharpenUniforms {
    float curveHeight;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

inline float adaptiveLuma(float3 rgb) {
    float3 c = max(rgb, 0.0f);
    return sqrt((1.0f / 3.0f) * dot(c, c));
}

// Pass 1: Precompute perceptual greyscale + edge magnitude into RG16F intermediate.
kernel void adaptive_sharpen_pass1(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<half, access::write> edgeOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = edgeOut.get_width();
    const uint outH = edgeOut.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    const int2 size = int2(input.get_width(), input.get_height());
    const int2 p = int2(gid);

    float3 c0  = input.read(clampCoord(p + int2( 0,  0), size)).rgb;
    float3 c1  = input.read(clampCoord(p + int2(-1, -1), size)).rgb;
    float3 c2  = input.read(clampCoord(p + int2( 0, -1), size)).rgb;
    float3 c3  = input.read(clampCoord(p + int2( 1, -1), size)).rgb;
    float3 c4  = input.read(clampCoord(p + int2(-1,  0), size)).rgb;
    float3 c5  = input.read(clampCoord(p + int2( 1,  0), size)).rgb;
    float3 c6  = input.read(clampCoord(p + int2(-1,  1), size)).rgb;
    float3 c7  = input.read(clampCoord(p + int2( 0,  1), size)).rgb;
    float3 c8  = input.read(clampCoord(p + int2( 1,  1), size)).rgb;
    float3 c9  = input.read(clampCoord(p + int2( 0, -2), size)).rgb;
    float3 c10 = input.read(clampCoord(p + int2(-2,  0), size)).rgb;
    float3 c11 = input.read(clampCoord(p + int2( 2,  0), size)).rgb;
    float3 c12 = input.read(clampCoord(p + int2( 0,  2), size)).rgb;

    // 3x3 Gaussian blur
    float3 blur = (2.0f * (c2 + c4 + c5 + c7) + (c1 + c3 + c6 + c8) + 4.0f * c0) / 16.0f;
    float blurY = (blur.r + blur.g + blur.b) * (1.0f / 3.0f);

    // 13-tap edge detection
    float edge = length(
        abs(blur - c0) + abs(blur - c1) + abs(blur - c2) + abs(blur - c3) +
        abs(blur - c4) + abs(blur - c5) + abs(blur - c6) + abs(blur - c7) + abs(blur - c8) +
        0.25f * (abs(blur - c9) + abs(blur - c10) + abs(blur - c11) + abs(blur - c12))
    ) * (1.0f / 3.0f);

    // Dark-region contrast compression
    edge *= min(0.8f + 2.7f * exp2(-7.4f * max(blurY, 0.0f)), 3.2f);

    float luma = adaptiveLuma(c0);
    edgeOut.write(half4(half(luma), half(edge), 0.0h, 1.0h), gid);
}

inline void trackTop2Bottom2(
    float v,
    thread float &min1,
    thread float &min2,
    thread float &max1,
    thread float &max2
) {
    if (v < min1) {
        min2 = min1;
        min1 = v;
    } else if (v < min2) {
        min2 = v;
    }
    if (v > max1) {
        max2 = max1;
        max1 = v;
    } else if (v > max2) {
        max2 = v;
    }
}

// Pass 2: Adaptive curve sharpening with register-only top-2/bottom-2 tracking (zero stack spill!)
// and tanh overshoot limiting.
kernel void adaptive_sharpen_pass2(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<half, access::read> edgeTex [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant AdaptiveSharpenUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    const int2 size = int2(input.get_width(), input.get_height());
    const int2 p = int2(gid);

    const float curveHeight = max(u.curveHeight, 0.0f);
    const float curveslope = curveHeight * 1.5f;
    const float D_overshoot = 0.016f;
    const float D_comp_ratio = 0.250f;
    const float L_overshoot = 0.004f;
    const float L_comp_ratio = 0.167f;
    const float max_scale_lim = 10.0f;

    float2 centerLE = float2(edgeTex.read(clampCoord(p, size)).rg);
    float k0 = centerLE.x;
    float edge = centerLE.y;

    // 25-tap diamond luma kernel held purely in scalar registers (no dynamic array spill!).
    float k1  = float(edgeTex.read(clampCoord(p + int2(-1, -1), size)).r);
    float k2  = float(edgeTex.read(clampCoord(p + int2( 0, -1), size)).r);
    float k3  = float(edgeTex.read(clampCoord(p + int2( 1, -1), size)).r);
    float k4  = float(edgeTex.read(clampCoord(p + int2(-1,  0), size)).r);
    float k5  = float(edgeTex.read(clampCoord(p + int2( 1,  0), size)).r);
    float k6  = float(edgeTex.read(clampCoord(p + int2(-1,  1), size)).r);
    float k7  = float(edgeTex.read(clampCoord(p + int2( 0,  1), size)).r);
    float k8  = float(edgeTex.read(clampCoord(p + int2( 1,  1), size)).r);
    float k9  = float(edgeTex.read(clampCoord(p + int2( 0, -2), size)).r);
    float k10 = float(edgeTex.read(clampCoord(p + int2(-2,  0), size)).r);
    float k11 = float(edgeTex.read(clampCoord(p + int2( 2,  0), size)).r);
    float k12 = float(edgeTex.read(clampCoord(p + int2( 0,  2), size)).r);
    float k13 = float(edgeTex.read(clampCoord(p + int2( 0,  3), size)).r);
    float k14 = float(edgeTex.read(clampCoord(p + int2( 1,  2), size)).r);
    float k15 = float(edgeTex.read(clampCoord(p + int2(-1,  2), size)).r);
    float k16 = float(edgeTex.read(clampCoord(p + int2( 3,  0), size)).r);
    float k17 = float(edgeTex.read(clampCoord(p + int2( 2,  1), size)).r);
    float k18 = float(edgeTex.read(clampCoord(p + int2( 2, -1), size)).r);
    float k19 = float(edgeTex.read(clampCoord(p + int2(-3,  0), size)).r);
    float k20 = float(edgeTex.read(clampCoord(p + int2(-2,  1), size)).r);
    float k21 = float(edgeTex.read(clampCoord(p + int2(-2, -1), size)).r);
    float k22 = float(edgeTex.read(clampCoord(p + int2( 0, -3), size)).r);
    float k23 = float(edgeTex.read(clampCoord(p + int2( 1, -2), size)).r);
    float k24 = float(edgeTex.read(clampCoord(p + int2(-1, -2), size)).r);

    float mdiff_c0 = 0.03f + 4.0f * (
        abs(k0 - k2) + abs(k0 - k4) + abs(k0 - k5) + abs(k0 - k7) +
        0.25f * (abs(k0 - k1) + abs(k0 - k3) + abs(k0 - k6) + abs(k0 - k8))
    );
    float mdiff_c9 = max(
        abs(k9 - k2) + abs(k9 - k24) + abs(k9 - k23) + abs(k9 - k22) +
        0.5f * (abs(k9 - k1) + abs(k9 - k3)),
        1e-5f
    );
    float mdiff_c10 = max(
        abs(k10 - k20) + abs(k10 - k19) + abs(k10 - k21) + abs(k10 - k4) +
        0.5f * (abs(k10 - k1) + abs(k10 - k6)),
        1e-5f
    );
    float mdiff_c11 = max(
        abs(k11 - k17) + abs(k11 - k5) + abs(k11 - k18) + abs(k11 - k16) +
        0.5f * (abs(k11 - k3) + abs(k11 - k8)),
        1e-5f
    );
    float mdiff_c12 = max(
        abs(k12 - k13) + abs(k12 - k15) + abs(k12 - k7) + abs(k12 - k14) +
        0.5f * (abs(k12 - k6) + abs(k12 - k8)),
        1e-5f
    );

    float4 weights = float4(
        min(mdiff_c0 / mdiff_c9,  2.0f),
        min(mdiff_c0 / mdiff_c10, 2.0f),
        min(mdiff_c0 / mdiff_c11, 2.0f),
        min(mdiff_c0 / mdiff_c12, 2.0f)
    );

    float neg_laplace = (
        0.25f * (k2 + k4 + k5 + k7) + (k1 + k3 + k6 + k8) +
        k9 * weights.x + k10 * weights.y + k11 * weights.z + k12 * weights.w
    ) / (5.0f + weights.x + weights.y + weights.z + weights.w);

    float safeEdge = max(edge, 0.0f);
    float sharpen_val = 0.01f
        + (curveHeight / (curveslope * pow(safeEdge, 3.5f) + 0.5f))
        - (curveHeight / (8192.0f * pow(safeEdge * 2.2f, 4.5f) + 0.5f));

    float sharpdiff = (k0 - neg_laplace) * (sharpen_val * 0.8f);

    // Exact 2 smallest and 2 largest values across the 25-tap diamond in 4 registers!
    float min1 = min(k0, k1), min2 = max(k0, k1);
    float max1 = max(k0, k1), max2 = min(k0, k1);
    trackTop2Bottom2(k2,  min1, min2, max1, max2);
    trackTop2Bottom2(k3,  min1, min2, max1, max2);
    trackTop2Bottom2(k4,  min1, min2, max1, max2);
    trackTop2Bottom2(k5,  min1, min2, max1, max2);
    trackTop2Bottom2(k6,  min1, min2, max1, max2);
    trackTop2Bottom2(k7,  min1, min2, max1, max2);
    trackTop2Bottom2(k8,  min1, min2, max1, max2);
    trackTop2Bottom2(k9,  min1, min2, max1, max2);
    trackTop2Bottom2(k10, min1, min2, max1, max2);
    trackTop2Bottom2(k11, min1, min2, max1, max2);
    trackTop2Bottom2(k12, min1, min2, max1, max2);
    trackTop2Bottom2(k13, min1, min2, max1, max2);
    trackTop2Bottom2(k14, min1, min2, max1, max2);
    trackTop2Bottom2(k15, min1, min2, max1, max2);
    trackTop2Bottom2(k16, min1, min2, max1, max2);
    trackTop2Bottom2(k17, min1, min2, max1, max2);
    trackTop2Bottom2(k18, min1, min2, max1, max2);
    trackTop2Bottom2(k19, min1, min2, max1, max2);
    trackTop2Bottom2(k20, min1, min2, max1, max2);
    trackTop2Bottom2(k21, min1, min2, max1, max2);
    trackTop2Bottom2(k22, min1, min2, max1, max2);
    trackTop2Bottom2(k23, min1, min2, max1, max2);
    trackTop2Bottom2(k24, min1, min2, max1, max2);

    float nmax = max((max1 + max2) * 0.5f, k0);
    float nmin = min((min1 + min2) * 0.5f, k0);

    float nmax_scale = max(1.0f / ((nmax - k0) + L_overshoot), max_scale_lim);
    float nmin_scale = max(1.0f / ((k0 - nmin) + D_overshoot), max_scale_lim);

    float posDiff = max(sharpdiff, 0.0f);
    float negDiff = min(sharpdiff, 0.0f);
    sharpdiff = mix(tanh(posDiff * nmax_scale) / nmax_scale, posDiff, L_comp_ratio)
              + mix(tanh(negDiff * nmin_scale) / nmin_scale, negDiff, D_comp_ratio);

    float3 orig = input.read(clampCoord(p, size)).rgb;
    float3 result = max(orig + sharpdiff, float3(0.0f));
    output.write(float4(result, 1.0f), gid);
}
