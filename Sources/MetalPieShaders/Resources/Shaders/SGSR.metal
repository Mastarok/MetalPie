#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Qualcomm Snapdragon Game Super Resolution v1 (SGSR v1)
// Single-pass luminance edge-directed spatial upscaler with fast flat early-out
// ============================================================================

struct SGSRUniforms {
    float edgeSharpness;
    float edgeThreshold;
    uint _pad0;
    uint _pad1;
};

inline float sgsrFastLanczos2(float x) {
    float wA = x - 4.0f;
    float wB = x * wA - wA;
    wA *= wA;
    return wB * wA;
}

inline float2 sgsrWeightY(float dx, float dy, float c, float3 data) {
    float std = data.x;
    float2 dir = data.yz;

    float edgeDis = dx * dir.y + dy * dir.x;
    float x = (dx * dx + dy * dy) + (edgeDis * edgeDis) * (clamp((c * c) * std, 0.0f, 1.0f) * 0.7f - 1.0f);
    float w = sgsrFastLanczos2(x);
    return float2(w, w * c);
}

inline float2 sgsrEdgeDirection(float4 left, float4 right) {
    float RxLz = right.x - left.z;
    float RwLy = right.w - left.y;
    float2 delta = float2(RxLz + RwLy, RxLz - RwLy);
    float lengthInv = rsqrt(delta.x * delta.x + delta.y * delta.y + 3.075740e-05f);
    return delta * lengthInv;
}

kernel void sgsr_upscale(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant SGSRUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);
    constexpr sampler pointSam(filter::nearest, address::clamp_to_edge, coord::normalized);

    const float2 inputSize = float2(input.get_width(), input.get_height());
    const float2 inputPt = 1.0f / inputSize;
    const float2 uv = (float2(gid) + 0.5f) / float2(outW, outH);

    const float edgeThreshold = max(u.edgeThreshold, 0.0f) / 255.0f;
    const float edgeSharpness = max(u.edgeSharpness, 0.0f);

    float3 pix = input.sample(linearSam, uv).rgb;

    float2 imgCoord = uv * inputSize + float2(-0.5f, 0.5f);
    float2 imgCoordPixel = floor(imgCoord);
    float2 coord = imgCoordPixel * inputPt;
    float2 pl = imgCoord - imgCoordPixel;

    float4 left = input.gather(pointSam, coord, int2(0), component::y);

    float edgeVote = abs(left.z - left.y) + abs(pix.g - left.y) + abs(pix.g - left.z);
    if (edgeVote > edgeThreshold) {
        coord.x += inputPt.x;

        float4 right = input.gather(pointSam, coord + float2(inputPt.x, 0.0f), int2(0), component::y);
        float4 upDown;
        upDown.xy = input.gather(pointSam, coord + float2(0.0f, -inputPt.y), int2(0), component::y).wz;
        upDown.zw = input.gather(pointSam, coord + float2(0.0f,  inputPt.y), int2(0), component::y).yx;

        float mean = (left.y + left.z + right.x + right.w) * 0.25f;
        left -= mean;
        right -= mean;
        upDown -= mean;
        float pixG = pix.g - mean;

        float sum = abs(left.x) + abs(left.y) + abs(left.z) + abs(left.w)
                  + abs(right.x) + abs(right.y) + abs(right.z) + abs(right.w)
                  + abs(upDown.x) + abs(upDown.y) + abs(upDown.z) + abs(upDown.w);
        float sumMean = 10.14185f / max(sum, 1e-5f);
        float std = sumMean * sumMean;

        float3 data = float3(std, sgsrEdgeDirection(left, right));

        float2 aWY = sgsrWeightY(pl.x,        pl.y + 1.0f, upDown.x, data);
        aWY       += sgsrWeightY(pl.x - 1.0f, pl.y + 1.0f, upDown.y, data);
        aWY       += sgsrWeightY(pl.x - 1.0f, pl.y - 2.0f, upDown.z, data);
        aWY       += sgsrWeightY(pl.x,        pl.y - 2.0f, upDown.w, data);
        aWY       += sgsrWeightY(pl.x + 1.0f, pl.y - 1.0f, left.x,   data);
        aWY       += sgsrWeightY(pl.x,        pl.y - 1.0f, left.y,   data);
        aWY       += sgsrWeightY(pl.x,        pl.y,        left.z,   data);
        aWY       += sgsrWeightY(pl.x + 1.0f, pl.y,        left.w,   data);
        aWY       += sgsrWeightY(pl.x - 1.0f, pl.y - 1.0f, right.x,  data);
        aWY       += sgsrWeightY(pl.x - 2.0f, pl.y - 1.0f, right.y,  data);
        aWY       += sgsrWeightY(pl.x - 2.0f, pl.y,        right.z,  data);
        aWY       += sgsrWeightY(pl.x - 1.0f, pl.y,        right.w,  data);

        float finalY = (abs(aWY.x) > 1e-6f) ? (aWY.y / aWY.x) : pixG;
        float max4 = max(max(left.y, left.z), max(right.x, right.w));
        float min4 = min(min(left.y, left.z), min(right.x, right.w));
        finalY = clamp(edgeSharpness * finalY, min4, max4);

        float deltaY = finalY - pixG;
        pix = max(pix + deltaY, float3(0.0f));
    }

    output.write(float4(pix, 1.0f), gid);
}
