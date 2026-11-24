#include <metal_stdlib>
using namespace metal;

// ============================================================================
// FXAA 3.11 Fast Approximate Anti-Aliasing (Authentic MagpieFX Port)
// Supports configurable Quality Preset (Low/Medium/High/Ultra -> 8/16/24/32
// edge-search steps), Edge Threshold, and Subpixel Smoothing Quality.
// Ideal as a 1x pre-pass before FSR / MetalFX / Lanczos on jagged 3D/2D games.
// ============================================================================

struct FXAAUniforms {
    uint qualityPreset;    // 0 = Low (8), 1 = Medium (16), 2 = High (24), 3 = Ultra (32)
    float edgeThreshold;   // default 0.125 (0.06..0.33)
    float subpixelQuality; // default 0.75 (0.0..1.0)
    uint _pad0;
};

inline float fxaaLuma(float3 rgb) {
    return rgb.y * (0.587f / 0.299f) + rgb.x;
}

inline float3 fxaaLerp3(float3 a, float3 b, float amountOfA) {
    return (a - b) * amountOfA + b;
}

kernel void fxaa(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant FXAAUniforms &u [[buffer(0)]],
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
    const float2 pos = (float2(gid) + 0.5f) / float2(outW, outH);

    // Quality preset controls span search length and dark-region threshold trim.
    const int searchSteps = (u.qualityPreset == 0u) ? 8
        : ((u.qualityPreset == 1u) ? 16
        : ((u.qualityPreset == 2u) ? 24 : 32));
    const float edgeThreshold = clamp(u.edgeThreshold, 0.04f, 0.35f);
    const float edgeThresholdMin = (u.qualityPreset >= 2u) ? (1.0f / 24.0f) : (1.0f / 16.0f);
    const float searchThreshold = 0.25f;
    const float subpixCap = clamp(u.subpixelQuality, 0.0f, 1.0f);
    const float subpixTrim = mix(0.5f, 0.125f, subpixCap);
    const float subpixTrimScale = 1.0f / max(1.0f - subpixTrim, 1e-4f);

    // 5-tap cardinal cross
    float3 rgbN = input.sample(linearSam, pos + float2( 0.0f, -inputPt.y)).rgb;
    float3 rgbW = input.sample(linearSam, pos + float2(-inputPt.x,  0.0f)).rgb;
    float3 rgbM = input.sample(linearSam, pos).rgb;
    float3 rgbE = input.sample(linearSam, pos + float2( inputPt.x,  0.0f)).rgb;
    float3 rgbS = input.sample(linearSam, pos + float2( 0.0f,  inputPt.y)).rgb;

    float lumaN = fxaaLuma(rgbN);
    float lumaW = fxaaLuma(rgbW);
    float lumaM = fxaaLuma(rgbM);
    float lumaE = fxaaLuma(rgbE);
    float lumaS = fxaaLuma(rgbS);

    float rangeMin = min(lumaM, min(min(lumaN, lumaW), min(lumaS, lumaE)));
    float rangeMax = max(lumaM, max(max(lumaN, lumaW), max(lumaS, lumaE)));
    float range = rangeMax - rangeMin;

    // Early out on flat or low-contrast regions.
    if (range < max(edgeThresholdMin, rangeMax * edgeThreshold)) {
        output.write(float4(rgbM, 1.0f), gid);
        return;
    }

    // 4 diagonal corners for full 3x3 subpixel lowpass & orientation detection.
    float3 rgbNW = input.sample(linearSam, pos + float2(-inputPt.x, -inputPt.y)).rgb;
    float3 rgbNE = input.sample(linearSam, pos + float2( inputPt.x, -inputPt.y)).rgb;
    float3 rgbSW = input.sample(linearSam, pos + float2(-inputPt.x,  inputPt.y)).rgb;
    float3 rgbSE = input.sample(linearSam, pos + float2( inputPt.x,  inputPt.y)).rgb;

    float lumaL = (lumaN + lumaW + lumaE + lumaS) * 0.25f;
    float rangeL = abs(lumaL - lumaM);
    float blendL = max(0.0f, (rangeL / max(range, 1e-6f)) - subpixTrim) * subpixTrimScale;
    blendL = min(subpixCap, blendL);

    float3 rgbL = (rgbN + rgbW + rgbM + rgbE + rgbS + rgbNW + rgbNE + rgbSW + rgbSE) * (1.0f / 9.0f);

    float lumaNW = fxaaLuma(rgbNW);
    float lumaNE = fxaaLuma(rgbNE);
    float lumaSW = fxaaLuma(rgbSW);
    float lumaSE = fxaaLuma(rgbSE);

    float edgeVert =
        abs(0.25f * lumaNW - 0.5f * lumaN + 0.25f * lumaNE) +
        abs(0.50f * lumaW  - 1.0f * lumaM + 0.50f * lumaE) +
        abs(0.25f * lumaSW - 0.5f * lumaS + 0.25f * lumaSE);
    float edgeHorz =
        abs(0.25f * lumaNW - 0.5f * lumaW + 0.25f * lumaSW) +
        abs(0.50f * lumaN  - 1.0f * lumaM + 0.50f * lumaS) +
        abs(0.25f * lumaNE - 0.5f * lumaE + 0.25f * lumaSE);

    bool horzSpan = edgeHorz >= edgeVert;
    float lengthSign = horzSpan ? -inputPt.y : -inputPt.x;

    if (!horzSpan) {
        lumaN = lumaW;
        lumaS = lumaE;
    }

    float gradientN = abs(lumaN - lumaM);
    float gradientS = abs(lumaS - lumaM);
    lumaN = (lumaN + lumaM) * 0.5f;
    lumaS = (lumaS + lumaM) * 0.5f;

    if (gradientN < gradientS) {
        lumaN = lumaS;
        gradientN = gradientS;
        lengthSign *= -1.0f;
    }

    float2 posN = float2(
        pos.x + (horzSpan ? 0.0f : lengthSign * 0.5f),
        pos.y + (horzSpan ? lengthSign * 0.5f : 0.0f)
    );

    gradientN *= searchThreshold;

    float2 posP = posN;
    float2 offNP = horzSpan ? float2(inputPt.x, 0.0f) : float2(0.0f, inputPt.y);
    float lumaEndN = lumaN;
    float lumaEndP = lumaN;
    bool doneN = false;
    bool doneP = false;
    posN -= offNP;
    posP += offNP;

    for (int stepIdx = 0; stepIdx < searchSteps; ++stepIdx) {
        if (!doneN) {
            lumaEndN = fxaaLuma(input.sample(linearSam, posN).rgb);
        }
        if (!doneP) {
            lumaEndP = fxaaLuma(input.sample(linearSam, posP).rgb);
        }

        doneN = doneN || (abs(lumaEndN - lumaN) >= gradientN);
        doneP = doneP || (abs(lumaEndP - lumaN) >= gradientN);
        if (doneN && doneP) {
            break;
        }
        if (!doneN) {
            posN -= offNP;
        }
        if (!doneP) {
            posP += offNP;
        }
    }

    float dstN = horzSpan ? (pos.x - posN.x) : (pos.y - posN.y);
    float dstP = horzSpan ? (posP.x - pos.x) : (posP.y - pos.y);
    bool directionN = dstN < dstP;
    lumaEndN = directionN ? lumaEndN : lumaEndP;

    if (((lumaM - lumaN) < 0.0f) == ((lumaEndN - lumaN) < 0.0f)) {
        lengthSign = 0.0f;
    }

    float spanLength = max(dstP + dstN, 1e-6f);
    dstN = directionN ? dstN : dstP;
    float subPixelOffset = (0.5f + (dstN * (-1.0f / spanLength))) * lengthSign;
    float3 rgbF = input.sample(linearSam, float2(
        pos.x + (horzSpan ? 0.0f : subPixelOffset),
        pos.y + (horzSpan ? subPixelOffset : 0.0f)
    )).rgb;

    float3 finalRGB = saturate(fxaaLerp3(rgbL, rgbF, blendL));
    output.write(float4(finalRGB, 1.0f), gid);
}
