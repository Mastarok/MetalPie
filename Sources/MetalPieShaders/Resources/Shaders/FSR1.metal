#include <metal_stdlib>
using namespace metal;

// ============================================================================
// AMD FidelityFX Super Resolution 1.0 (FSR 1.0)
// - fsr1_easu: 12-tap Edge-Adaptive Spatial Upsampling (anisotropic Lanczos2)
// - fsr1_rcas: 5-tap Robust Contrast Adaptive Sharpening
//              WITH FIXED max(max3(b, d, f), h) (fixing upstream min3 typo!)
// ============================================================================

inline float min3f(float a, float b, float c) { return min(a, min(b, c)); }
inline float max3f(float a, float b, float c) { return max(a, max(b, c)); }
inline float3 min3v(float3 a, float3 b, float3 c) { return min(a, min(b, c)); }
inline float3 max3v(float3 a, float3 b, float3 c) { return max(a, max(b, c)); }

inline uint2 clampCoord(int2 p, int2 size) {
    return uint2(clamp(p, int2(0), max(size - int2(1), int2(0))));
}

// MARK: - FSR 1.0 EASU

inline void fsrEasuSet(
    thread float2 &dir,
    thread float &len,
    float2 pp,
    bool biS,
    bool biT,
    bool biU,
    bool biV,
    float lA,
    float lB,
    float lC,
    float lD,
    float lE
) {
    float w = 0.0f;
    if (biS) w = (1.0f - pp.x) * (1.0f - pp.y);
    if (biT) w = pp.x * (1.0f - pp.y);
    if (biU) w = (1.0f - pp.x) * pp.y;
    if (biV) w = pp.x * pp.y;

    float dc = lD - lC;
    float cb = lC - lB;
    float lenX = max(abs(dc), abs(cb));
    float dirX = lD - lB;
    dir.x += dirX * w;
    lenX = (lenX > 1e-6f) ? saturate(abs(dirX) / lenX) : 0.0f;
    lenX *= lenX;
    len += lenX * w;

    float ec = lE - lC;
    float ca = lC - lA;
    float lenY = max(abs(ec), abs(ca));
    float dirY = lE - lA;
    dir.y += dirY * w;
    lenY = (lenY > 1e-6f) ? saturate(abs(dirY) / lenY) : 0.0f;
    lenY *= lenY;
    len += lenY * w;
}

inline void fsrEasuTap(
    thread float3 &aC,
    thread float &aW,
    float2 off,
    float2 dir,
    float2 len,
    float lob,
    float clp,
    float3 c
) {
    float2 v;
    v.x = off.x * dir.x + off.y * dir.y;
    v.y = off.x * (-dir.y) + off.y * dir.x;
    v *= len;
    float d2 = v.x * v.x + v.y * v.y;
    d2 = min(d2, clp);
    float wB = (2.0f / 5.0f) * d2 - 1.0f;
    float wA = lob * d2 - 1.0f;
    wB *= wB;
    wA *= wA;
    wB = (25.0f / 16.0f) * wB - (25.0f / 16.0f - 1.0f);
    float w = wB * wA;
    aC += c * w;
    aW += w;
}

kernel void fsr1_easu(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
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

    const float4 con0 = float4(
        inputSize.x / outputSize.x,
        inputSize.y / outputSize.y,
        0.5f * (inputSize.x / outputSize.x) - 0.5f,
        0.5f * (inputSize.y / outputSize.y) - 0.5f
    );
    const float4 con1 = float4(inputPt.x, inputPt.y, inputPt.x, -inputPt.y);
    const float4 con2 = float4(-inputPt.x, 2.0f * inputPt.y, inputPt.x, 2.0f * inputPt.y);
    const float2 con3 = float2(0.0f, 4.0f * inputPt.y);

    float2 pp = float2(gid) * con0.xy + con0.zw;
    float2 fp = floor(pp);
    pp -= fp;

    // 12-tap cross footprint via 4 gather quads:
    //    b c
    //  e f g h
    //  i j k l
    //    n o
    float2 p0 = fp * con1.xy + con1.zw;
    float2 p1 = p0 + con2.xy;
    float2 p2 = p0 + con2.zw;
    float2 p3 = p0 + con3;

    float4 bczzR = input.gather(pointSam, p0, int2(0), component::x);
    float4 bczzG = input.gather(pointSam, p0, int2(0), component::y);
    float4 bczzB = input.gather(pointSam, p0, int2(0), component::z);

    float4 ijfeR = input.gather(pointSam, p1, int2(0), component::x);
    float4 ijfeG = input.gather(pointSam, p1, int2(0), component::y);
    float4 ijfeB = input.gather(pointSam, p1, int2(0), component::z);

    float4 klhgR = input.gather(pointSam, p2, int2(0), component::x);
    float4 klhgG = input.gather(pointSam, p2, int2(0), component::y);
    float4 klhgB = input.gather(pointSam, p2, int2(0), component::z);

    float4 zzonR = input.gather(pointSam, p3, int2(0), component::x);
    float4 zzonG = input.gather(pointSam, p3, int2(0), component::y);
    float4 zzonB = input.gather(pointSam, p3, int2(0), component::z);

    // Approximate luma (2 * L = 0.5*B + 0.5*R + G)
    float4 bczzL = bczzB * 0.5f + (bczzR * 0.5f + bczzG);
    float4 ijfeL = ijfeB * 0.5f + (ijfeR * 0.5f + ijfeG);
    float4 klhgL = klhgB * 0.5f + (klhgR * 0.5f + klhgG);
    float4 zzonL = zzonB * 0.5f + (zzonR * 0.5f + zzonG);

    float bL = bczzL.x;
    float cL = bczzL.y;
    float iL = ijfeL.x;
    float jL = ijfeL.y;
    float fL = ijfeL.z;
    float eL = ijfeL.w;
    float kL = klhgL.x;
    float lL = klhgL.y;
    float hL = klhgL.z;
    float gL = klhgL.w;
    float oL = zzonL.z;
    float nL = zzonL.w;

    float2 dir = float2(0.0f);
    float len = 0.0f;
    fsrEasuSet(dir, len, pp, true,  false, false, false, bL, eL, fL, gL, jL);
    fsrEasuSet(dir, len, pp, false, true,  false, false, cL, fL, gL, hL, kL);
    fsrEasuSet(dir, len, pp, false, false, true,  false, fL, iL, jL, kL, nL);
    fsrEasuSet(dir, len, pp, false, false, false, true,  gL, jL, kL, lL, oL);

    float dirR = dir.x * dir.x + dir.y * dir.y;
    bool zro = dirR < (1.0f / 32768.0f);
    dirR = zro ? 1.0f : rsqrt(dirR);
    dir.x = zro ? 1.0f : dir.x;
    dir.y = zro ? 0.0f : dir.y;
    dir *= dirR;

    len = len * 0.5f;
    len *= len;

    float maxAbsDir = max(max(abs(dir.x), abs(dir.y)), 1e-6f);
    float stretch = (dir.x * dir.x + dir.y * dir.y) / maxAbsDir;
    float2 len2 = float2(1.0f + (stretch - 1.0f) * len, 1.0f - 0.5f * len);
    float lob = 0.5f + ((0.25f - 0.04f) - 0.5f) * len;
    float clp = 1.0f / max(lob, 1e-5f);

    float3 cF = float3(ijfeR.z, ijfeG.z, ijfeB.z);
    float3 cG = float3(klhgR.w, klhgG.w, klhgB.w);
    float3 cJ = float3(ijfeR.y, ijfeG.y, ijfeB.y);
    float3 cK = float3(klhgR.x, klhgG.x, klhgB.x);

    float3 min4 = min(min3v(cF, cG, cJ), cK);
    float3 max4 = max(max3v(cF, cG, cJ), cK);

    float3 aC = float3(0.0f);
    float aW = 0.0f;
    fsrEasuTap(aC, aW, float2( 0.0f, -1.0f) - pp, dir, len2, lob, clp, float3(bczzR.x, bczzG.x, bczzB.x)); // b
    fsrEasuTap(aC, aW, float2( 1.0f, -1.0f) - pp, dir, len2, lob, clp, float3(bczzR.y, bczzG.y, bczzB.y)); // c
    fsrEasuTap(aC, aW, float2(-1.0f,  1.0f) - pp, dir, len2, lob, clp, float3(ijfeR.x, ijfeG.x, ijfeB.x)); // i
    fsrEasuTap(aC, aW, float2( 0.0f,  1.0f) - pp, dir, len2, lob, clp, cJ);                                 // j
    fsrEasuTap(aC, aW, float2( 0.0f,  0.0f) - pp, dir, len2, lob, clp, cF);                                 // f
    fsrEasuTap(aC, aW, float2(-1.0f,  0.0f) - pp, dir, len2, lob, clp, float3(ijfeR.w, ijfeG.w, ijfeB.w)); // e
    fsrEasuTap(aC, aW, float2( 1.0f,  1.0f) - pp, dir, len2, lob, clp, cK);                                 // k
    fsrEasuTap(aC, aW, float2( 2.0f,  1.0f) - pp, dir, len2, lob, clp, float3(klhgR.y, klhgG.y, klhgB.y)); // l
    fsrEasuTap(aC, aW, float2( 2.0f,  0.0f) - pp, dir, len2, lob, clp, float3(klhgR.z, klhgG.z, klhgB.z)); // h
    fsrEasuTap(aC, aW, float2( 1.0f,  0.0f) - pp, dir, len2, lob, clp, cG);                                 // g
    fsrEasuTap(aC, aW, float2( 1.0f,  2.0f) - pp, dir, len2, lob, clp, float3(zzonR.z, zzonG.z, zzonB.z)); // o
    fsrEasuTap(aC, aW, float2( 0.0f,  2.0f) - pp, dir, len2, lob, clp, float3(zzonR.w, zzonG.w, zzonB.w)); // n

    float3 resolved = (abs(aW) > 1e-6f) ? (aC / aW) : cF;
    float3 finalRGB = clamp(resolved, min4, max4);
    output.write(float4(finalRGB, 1.0f), gid);
}

// MARK: - FSR 1.0 RCAS (Fixed max(max3(...)) bug!)

struct RCASUniforms {
    float sharpness;
    uint isHDR;
    uint _pad0;
    uint _pad1;
};

#define FSR_RCAS_LIMIT (0.25f - (1.0f / 16.0f))

inline float3 rcasTonemapForward(float3 c, bool isHDR) {
    if (!isHDR) return saturate(c);
    float3 x = max(c, 0.0f);
    return x / (1.0f + x);
}

inline float3 rcasTonemapInverse(float3 c, bool isHDR) {
    if (!isHDR) return saturate(c);
    float3 x = clamp(c, 0.0f, 0.9995f);
    return x / (1.0f - x);
}

kernel void fsr1_rcas(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant RCASUniforms &u [[buffer(0)]],
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

    // 5-tap cross:
    //    b
    //  d e f
    //    h
    float3 b = rcasTonemapForward(input.read(clampCoord(p + int2( 0, -1), size)).rgb, hdr);
    float3 d = rcasTonemapForward(input.read(clampCoord(p + int2(-1,  0), size)).rgb, hdr);
    float3 e = rcasTonemapForward(input.read(clampCoord(p,               size)).rgb, hdr);
    float3 f = rcasTonemapForward(input.read(clampCoord(p + int2( 1,  0), size)).rgb, hdr);
    float3 h = rcasTonemapForward(input.read(clampCoord(p + int2( 0,  1), size)).rgb, hdr);

    // Approximate luma * 2.
    float bL = b.b * 0.5f + (b.r * 0.5f + b.g);
    float dL = d.b * 0.5f + (d.r * 0.5f + d.g);
    float eL = e.b * 0.5f + (e.r * 0.5f + e.g);
    float fL = f.b * 0.5f + (f.r * 0.5f + f.g);
    float hL = h.b * 0.5f + (h.r * 0.5f + h.g);

    // Noise detection.
    float nz = 0.25f * (bL + dL + fL + hL) - eL;
    float rangeL = max3f(max3f(bL, dL, eL), fL, hL) - min3f(min3f(bL, dL, eL), fL, hL);
    nz = (rangeL > 1e-6f) ? saturate(abs(nz) / rangeL) : 0.0f;
    nz = 1.0f - 0.5f * nz;

    // Min and max of ring — FIXED: uses max(max3(...)) instead of upstream Magpie's min3 typo!
    float mn4R = min(min3f(b.r, d.r, f.r), h.r);
    float mn4G = min(min3f(b.g, d.g, f.g), h.g);
    float mn4B = min(min3f(b.b, d.b, f.b), h.b);
    float mx4R = max(max3f(b.r, d.r, f.r), h.r);
    float mx4G = max(max3f(b.g, d.g, f.g), h.g);
    float mx4B = max(max3f(b.b, d.b, f.b), h.b);

    // Guarded high-precision limiters (prevent 0/0 NaNs on pure black or pure white regions).
    float hitMinR = min(mn4R, e.r) / max(4.0f * mx4R, 1e-6f);
    float hitMinG = min(mn4G, e.g) / max(4.0f * mx4G, 1e-6f);
    float hitMinB = min(mn4B, e.b) / max(4.0f * mx4B, 1e-6f);

    float hitMaxR = (1.0f - max(mx4R, e.r)) / min(4.0f * mn4R - 4.0f, -1e-6f);
    float hitMaxG = (1.0f - max(mx4G, e.g)) / min(4.0f * mn4G - 4.0f, -1e-6f);
    float hitMaxB = (1.0f - max(mx4B, e.b)) / min(4.0f * mn4B - 4.0f, -1e-6f);

    float lobeR = max(-hitMinR, hitMaxR);
    float lobeG = max(-hitMinG, hitMaxG);
    float lobeB = max(-hitMinB, hitMaxB);

    float sharpness = clamp(u.sharpness, 0.0f, 1.0f);
    float lobe = max(-FSR_RCAS_LIMIT, min(max3f(lobeR, lobeG, lobeB), 0.0f)) * sharpness * nz;

    float rcpL = 1.0f / (4.0f * lobe + 1.0f);
    float3 sharpened = (lobe * (b + d + f + h) + e) * rcpL;
    float3 finalRGB = rcasTonemapInverse(sharpened, hdr);
    output.write(float4(finalRGB, 1.0f), gid);
}
