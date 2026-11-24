#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Interpolation & Utility Shaders:
// - lanczos6_h / lanczos6_v: 2-pass separable Lanczos radius 3 + Anti-Ringing
// - bicubic: 9-tap hardware-bilinear Mitchell-Netravali / Catmull-Rom / B-Spline
//            (also serves as MetalPie's cached Auto-Bicubic fallback pass)
// - sharp_bilinear: Crisp pixel-art prescale + smooth hardware bilinear
// - pixellate: Analytical texel-area integration box filter
// - nearest / bilinear: Fast point and hardware linear resamplers
// - deband: Multi-tap thresholded stochastic debanding + micro-dither
// - image_adjustment: Gamma, brightness, contrast, saturation, vibrance, temp
// ============================================================================

inline uint2 clampCoord(int2 p, int2 size) {
    return uint2(clamp(p, int2(0), max(size - int2(1), int2(0))));
}

// MARK: - 2-Pass Separable Lanczos6 (Radius 3) with Anti-Ringing

struct LanczosUniforms {
    float arStrength;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

inline float lanczos3Weight(float x) {
    float ax = abs(x);
    if (ax < 1e-5f) return 1.0f;
    if (ax >= 3.0f) return 0.0f;
    const float pi = 3.14159265359f;
    float pix = pi * ax;
    return (3.0f * sin(pix) * sin(pix / 3.0f)) / (pix * pix);
}

kernel void lanczos6_h(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant LanczosUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    const int inW = int(input.get_width());
    const int inH = int(input.get_height());
    const int2 inSize = int2(inW, inH);

    // Map output x center to source pixel space.
    float srcX = (float(gid.x) + 0.5f) * (float(inW) / float(outW)) - 0.5f;
    int baseX = int(floor(srcX));
    float fracX = srcX - float(baseX);
    int y = clamp(int(gid.y), 0, inH - 1);

    float3 sum = float3(0.0f);
    float wSum = 0.0f;
    float3 c0 = float3(0.0f);
    float3 c1 = float3(0.0f);

    for (int k = -2; k <= 3; ++k) {
        float w = lanczos3Weight(float(k) - fracX);
        float3 s = input.read(clampCoord(int2(baseX + k, y), inSize)).rgb;
        sum += s * w;
        wSum += w;
        if (k == 0) c0 = s;
        if (k == 1) c1 = s;
    }

    float3 color = (abs(wSum) > 1e-6f) ? (sum / wSum) : c0;
    float3 min2 = min(c0, c1);
    float3 max2 = max(c0, c1);
    color = mix(color, clamp(color, min2, max2), clamp(u.arStrength, 0.0f, 1.0f));
    output.write(float4(color, 1.0f), gid);
}

kernel void lanczos6_v(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant LanczosUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    const int inW = int(input.get_width());
    const int inH = int(input.get_height());
    const int2 inSize = int2(inW, inH);

    float srcY = (float(gid.y) + 0.5f) * (float(inH) / float(outH)) - 0.5f;
    int baseY = int(floor(srcY));
    float fracY = srcY - float(baseY);
    int x = clamp(int(gid.x), 0, inW - 1);

    float3 sum = float3(0.0f);
    float wSum = 0.0f;
    float3 c0 = float3(0.0f);
    float3 c1 = float3(0.0f);

    for (int k = -2; k <= 3; ++k) {
        float w = lanczos3Weight(float(k) - fracY);
        float3 s = input.read(clampCoord(int2(x, baseY + k), inSize)).rgb;
        sum += s * w;
        wSum += w;
        if (k == 0) c0 = s;
        if (k == 1) c1 = s;
    }

    float3 color = (abs(wSum) > 1e-6f) ? (sum / wSum) : c0;
    float3 min2 = min(c0, c1);
    float3 max2 = max(c0, c1);
    color = mix(color, clamp(color, min2, max2), clamp(u.arStrength, 0.0f, 1.0f));
    output.write(float4(max(color, float3(0.0f)), 1.0f), gid);
}

// MARK: - 9-Tap Hardware-Bilinear Bicubic (Mitchell-Netravali / Catmull-Rom / B-Spline)

struct BicubicUniforms {
    float paramB;
    float paramC;
    uint _pad0;
    uint _pad1;
};

inline float bicubicWeight(float x, float B, float C) {
    float ax = abs(x);
    if (ax < 1.0f) {
        return (x * x * ((12.0f - 9.0f * B - 6.0f * C) * ax + (-18.0f + 12.0f * B + 6.0f * C)) + (6.0f - 2.0f * B)) / 6.0f;
    } else if (ax < 2.0f) {
        return (x * x * ((-B - 6.0f * C) * ax + (6.0f * B + 30.0f * C)) + (-12.0f * B - 48.0f * C) * ax + (8.0f * B + 24.0f * C)) / 6.0f;
    }
    return 0.0f;
}

inline float4 bicubicWeight4(float x, float B, float C) {
    return float4(
        bicubicWeight(x - 2.0f, B, C),
        bicubicWeight(x - 1.0f, B, C),
        bicubicWeight(x,        B, C),
        bicubicWeight(x + 1.0f, B, C)
    );
}

kernel void bicubic(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant BicubicUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);

    const float2 inputSize = float2(input.get_width(), input.get_height());
    const float2 inputPt = 1.0f / inputSize;
    const float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);

    float2 pos = uv * inputSize;
    float2 pos1 = floor(pos - 0.5f) + 0.5f;
    float2 f = pos - pos1;

    float4 rowtaps = bicubicWeight4(1.0f - f.x, u.paramB, u.paramC);
    float4 coltaps = bicubicWeight4(1.0f - f.y, u.paramB, u.paramC);

    // Normalize weights to guarantee exact unity gain for any (B, C).
    float rowSum = rowtaps.x + rowtaps.y + rowtaps.z + rowtaps.w;
    float colSum = coltaps.x + coltaps.y + coltaps.z + coltaps.w;
    if (abs(rowSum) > 1e-6f) rowtaps /= rowSum;
    if (abs(colSum) > 1e-6f) coltaps /= colSum;

    float2 uv1 = pos1 * inputPt;
    float2 uv0 = uv1 - inputPt;
    float2 uv2 = uv1 + inputPt;
    float2 uv3 = uv2 + inputPt;

    float uWeightSum = rowtaps.y + rowtaps.z;
    float uMidOffset = (abs(uWeightSum) > 1e-6f) ? (rowtaps.z * inputPt.x / uWeightSum) : 0.0f;
    float uMiddle = uv1.x + uMidOffset;

    float vWeightSum = coltaps.y + coltaps.z;
    float vMidOffset = (abs(vWeightSum) > 1e-6f) ? (coltaps.z * inputPt.y / vWeightSum) : 0.0f;
    float vMiddle = uv1.y + vMidOffset;

    // 9-tap hardware-bilinear evaluation (4 corner samples + 5 folded linear samples)
    float3 top = input.sample(linearSam, float2(uv0.x, uv0.y)).rgb * rowtaps.x
               + input.sample(linearSam, float2(uMiddle, uv0.y)).rgb * uWeightSum
               + input.sample(linearSam, float2(uv3.x, uv0.y)).rgb * rowtaps.w;

    float3 mid = input.sample(linearSam, float2(uv0.x, vMiddle)).rgb * rowtaps.x
               + input.sample(linearSam, float2(uMiddle, vMiddle)).rgb * uWeightSum
               + input.sample(linearSam, float2(uv3.x, vMiddle)).rgb * rowtaps.w;

    float3 bot = input.sample(linearSam, float2(uv0.x, uv3.y)).rgb * rowtaps.x
               + input.sample(linearSam, float2(uMiddle, uv3.y)).rgb * uWeightSum
               + input.sample(linearSam, float2(uv3.x, uv3.y)).rgb * rowtaps.w;

    float3 total = top * coltaps.x + mid * vWeightSum + bot * coltaps.w;
    output.write(float4(max(total, float3(0.0f)), 1.0f), gid);
}

// MARK: - Sharp Bilinear (Pixel-Art Integer Prescale + Smooth Bilinear)

struct SharpBilinearUniforms {
    float sharpness;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

kernel void sharp_bilinear(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant SharpBilinearUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);

    const float2 inputSize = float2(input.get_width(), input.get_height());
    const float2 outputSize = float2(outW, outH);
    const float2 inputPt = 1.0f / inputSize;
    const float2 uv = (float2(gid) + 0.5f) / outputSize;

    // Effective prescale blends between 1.0 (pure bilinear) and full output/input ratio.
    float2 fullScale = max(outputSize / inputSize, float2(1.0f));
    float2 scale = mix(float2(1.0f), fullScale, clamp(u.sharpness, 0.0f, 1.0f));

    float2 texel = uv * inputSize;
    float2 texelFloored = floor(texel);
    float2 s = fract(texel);
    float2 regionRange = 0.5f - 0.5f / scale;

    float2 centerDist = s - 0.5f;
    float2 f = (centerDist - clamp(centerDist, -regionRange, regionRange)) * scale + 0.5f;
    float2 modTexel = texelFloored + f;

    float4 col = input.sample(linearSam, modTexel * inputPt);
    output.write(float4(col.rgb, 1.0f), gid);
}

// MARK: - Pixellate (Analytical Texel-Area Integration)

kernel void pixellate(
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
    const float2 texelSize = 1.0f / inputSize;
    const float2 pos = (float2(gid) + 0.5f) / outputSize;
    const float2 range = (1.0f / outputSize) * 0.5f * 0.999f;

    float left = pos.x - range.x;
    float right = pos.x + range.x;
    float bottom = pos.y - range.y;
    float top = pos.y + range.y;

    float3 tl = input.sample(pointSam, (floor(float2(left,  top)    * inputSize) + 0.5f) * texelSize).rgb;
    float3 tr = input.sample(pointSam, (floor(float2(right, top)    * inputSize) + 0.5f) * texelSize).rgb;
    float3 bl = input.sample(pointSam, (floor(float2(left,  bottom) * inputSize) + 0.5f) * texelSize).rgb;
    float3 br = input.sample(pointSam, (floor(float2(right, bottom) * inputSize) + 0.5f) * texelSize).rgb;

    float2 border = clamp(round(pos * inputSize) * texelSize, float2(left, bottom), float2(right, top));
    float totalArea = max(4.0f * range.x * range.y, 1e-12f);

    float3 avg = ((border.x - left)  * (top - border.y)    / totalArea) * tl
               + ((right - border.x) * (border.y - bottom) / totalArea) * br
               + ((border.x - left)  * (border.y - bottom) / totalArea) * bl
               + ((right - border.x) * (top - border.y)    / totalArea) * tr;

    output.write(float4(avg, 1.0f), gid);
}

// MARK: - Nearest Neighbor & Bilinear

kernel void nearest(
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
    float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);
    float4 c = input.sample(pointSam, uv);
    output.write(float4(c.rgb, 1.0f), gid);
}

kernel void bilinear(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }
    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);
    float4 c = input.sample(linearSam, uv);
    output.write(float4(c.rgb, 1.0f), gid);
}

// MARK: - Deband (Multi-tap Thresholded Stochastic Debanding + Micro-Dither)

struct DebandUniforms {
    float threshold;
    float range;
    float grain;
    float frameSeed;
};

inline float debandMod289(float x) { return x - floor(x / 289.0f) * 289.0f; }
inline float debandPermute(float x) { return debandMod289((34.0f * x + 1.0f) * x); }
inline float debandRand(float x) { return fract(x / 41.0f); }

inline float3 debandAverage(
    texture2d<float, access::sample> input,
    sampler linearSam,
    float2 uv,
    float2 pt,
    float r,
    thread float &h
) {
    float dist = debandRand(h) * r;          h = debandPermute(h);
    float dir = debandRand(h) * 6.2831853f;  h = debandPermute(h);
    float2 o = float2(cos(dir), sin(dir)) * pt * dist;

    float3 r0 = input.sample(linearSam, uv + float2( o.x,  o.y)).rgb;
    float3 r1 = input.sample(linearSam, uv + float2(-o.y,  o.x)).rgb;
    float3 r2 = input.sample(linearSam, uv + float2(-o.x, -o.y)).rgb;
    float3 r3 = input.sample(linearSam, uv + float2( o.y, -o.x)).rgb;
    return (r0 + r1 + r2 + r3) * 0.25f;
}

kernel void deband(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant DebandUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);
    constexpr sampler pointSam(filter::nearest, address::clamp_to_edge, coord::normalized);

    const float2 pt = 1.0f / float2(input.get_width(), input.get_height());
    const float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);

    // Deterministic spatial+frame PRNG hash
    float h = debandPermute(debandPermute(debandPermute(float(gid.x) * 0.137f) + float(gid.y) * 0.193f) + u.frameSeed);

    float3 col = input.sample(pointSam, uv).rgb;
    const float baseThreshold = max(u.threshold, 0.0f);
    const float baseRange = max(u.range, 1.0f);

    for (int i = 1; i <= 4; ++i) {
        float3 avg = debandAverage(input, linearSam, uv, pt, float(i) * baseRange * 0.5f, h);
        float3 diff = abs(col - avg);
        float3 thres = float3(baseThreshold / float(i));
        col = mix(avg, col, step(thres, diff));
    }

    // Subtle micro-dither to mask remaining 8-bit quantization steps
    float3 noise;
    noise.x = debandRand(h); h = debandPermute(h);
    noise.y = debandRand(h); h = debandPermute(h);
    noise.z = debandRand(h);
    col = saturate(col + u.grain * (noise - 0.5f));

    output.write(float4(col, 1.0f), gid);
}

// MARK: - Image Adjustment (Gamma, Brightness, Contrast, Saturation, Vibrance, Color Temp)

struct ImageAdjustmentUniforms {
    float gamma;
    float brightness;
    float contrast;
    float saturation;
    float vibrance;
    float temperature;
    uint _pad0;
    uint _pad1;
};

kernel void image_adjustment(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ImageAdjustmentUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    const int2 size = int2(input.get_width(), input.get_height());
    float3 color = input.read(clampCoord(int2(gid), size)).rgb;

    // Color temperature shift (warm +R/-B, cool -R/+B)
    float temp = clamp(u.temperature, -1.0f, 1.0f) * 0.15f;
    color *= float3(1.0f + temp, 1.0f, 1.0f - temp);

    // Brightness and contrast around midpoint 0.5
    color = (color - 0.5f) * max(u.contrast, 0.0f) + 0.5f + u.brightness;

    // Saturation + adaptive vibrance
    float luma = dot(color, float3(0.2126f, 0.7152f, 0.0722f));
    float maxCh = max(color.r, max(color.g, color.b));
    float minCh = min(color.r, min(color.g, color.b));
    float currentSat = maxCh - minCh;
    float effSat = max(u.saturation, 0.0f) + u.vibrance * (1.0f - saturate(currentSat));
    color = mix(float3(luma), color, max(effSat, 0.0f));

    // Gamma adjustment
    float g = max(u.gamma, 0.05f);
    color = pow(max(color, float3(0.0f)), 1.0f / g);

    output.write(float4(color, 1.0f), gid);
}
