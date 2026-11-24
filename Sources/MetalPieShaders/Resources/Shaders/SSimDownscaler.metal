#include <metal_stdlib>
using namespace metal;

// ============================================================================
// SSimDownscaler: 5-Pass Perceptual Structural-Similarity Downscaler
// - ssim_pass1_postkernel: 9-tap Catmull-Rom (B=0, C=0.75) base downscale
// - ssim_pass2_l2_v:       Separable vertical Catmull-Rom downscale of INPUT^2
// - ssim_pass3_l2_h:       Separable horizontal Catmull-Rom downscale of L2
// - ssim_pass4_mean_r:     Local mean, Sl/Sh variance, structural gain R
// - ssim_pass5_reconstruct: Perceptual reconstruction preserving fine detail
// ============================================================================

inline uint2 clampCoord(int2 p, int2 size) {
    return uint2(clamp(p, int2(0), max(size - int2(1), int2(0))));
}

inline float4 ssimWeight4(float x) {
    // B=0, C=0.75 sharp bicubic
    return float4(
        ((-0.75f * x + 1.5f) * x - 0.75f) * x,
        (1.25f * x - 2.25f) * x * x + 1.0f,
        ((-1.25f * x + 1.5f) * x + 0.75f) * x,
        (0.75f * x - 0.75f) * x * x
    );
}

inline float ssimCatmullRom(float x) {
    float ax = abs(x);
    if (ax < 1.0f) {
        return (1.5f * ax - 2.5f) * ax * ax + 1.0f;
    } else if (ax < 2.0f) {
        return ((-0.5f * ax + 2.5f) * ax - 4.0f) * ax + 2.0f;
    }
    return 0.0f;
}

// Pass 1: 9-tap Catmull-Rom base downscale -> POSTKERNEL (outW x outH)
kernel void ssim_pass1_postkernel(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> postKernel [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = postKernel.get_width();
    const uint outH = postKernel.get_height();
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

    float4 rowtaps = ssimWeight4(f.x);
    float4 coltaps = ssimWeight4(f.y);

    float2 uv1 = pos1 * inputPt;
    float2 uv0 = uv1 - inputPt;
    float2 uv2 = uv1 + inputPt;
    float2 uv3 = uv2 + inputPt;

    float uWeightSum = rowtaps.y + rowtaps.z;
    float uMiddle = uv1.x + ((abs(uWeightSum) > 1e-6f) ? (rowtaps.z * inputPt.x / uWeightSum) : 0.0f);

    float vWeightSum = coltaps.y + coltaps.z;
    float vMiddle = uv1.y + ((abs(vWeightSum) > 1e-6f) ? (coltaps.z * inputPt.y / vWeightSum) : 0.0f);

    float3 top = input.sample(linearSam, float2(uv0.x, uv0.y)).rgb * rowtaps.x
               + input.sample(linearSam, float2(uMiddle, uv0.y)).rgb * uWeightSum
               + input.sample(linearSam, float2(uv3.x, uv0.y)).rgb * rowtaps.w;

    float3 mid = input.sample(linearSam, float2(uv0.x, vMiddle)).rgb * rowtaps.x
               + input.sample(linearSam, float2(uMiddle, vMiddle)).rgb * uWeightSum
               + input.sample(linearSam, float2(uv3.x, vMiddle)).rgb * rowtaps.w;

    float3 bot = input.sample(linearSam, float2(uv0.x, uv3.y)).rgb * rowtaps.x
               + input.sample(linearSam, float2(uMiddle, uv3.y)).rgb * uWeightSum
               + input.sample(linearSam, float2(uv3.x, uv3.y)).rgb * rowtaps.w;

    float3 total = max(top * coltaps.x + mid * vWeightSum + bot * coltaps.w, float3(0.0f));
    postKernel.write(float4(total, 1.0f), gid);
}

// Pass 2: Separable vertical Catmull-Rom downscale of INPUT^2 -> L2 (inW x outH, RGBA16F)
kernel void ssim_pass2_l2_v(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> l2Out [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = l2Out.get_width();
    const uint outH = l2Out.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler pointSam(filter::nearest, address::clamp_to_edge, coord::normalized);

    const float inW = float(input.get_width());
    const float inH = float(input.get_height());
    const float inputPtY = 1.0f / inH;
    const float outputPtY = 1.0f / float(outH);

    const float baseX = (float(gid.x) + 0.5f) / inW;
    const float baseY = (float(gid.y) + 0.5f) * outputPtY;
    const float taps = 2.0f;

    int low = int(ceil((baseY - taps * outputPtY) * inH - 0.5f));
    int high = int(floor((baseY + taps * outputPtY) * inH - 0.5f));
    // Clamp span for extreme downscale factors so compute stays bounded.
    if (high - low > 32) {
        int mid = (low + high) / 2;
        low = mid - 16;
        high = mid + 16;
    }

    float W = 0.0f;
    float3 avg = float3(0.0f);
    for (int k = low; k <= high; ++k) {
        float sampleY = inputPtY * (float(k) + 0.5f);
        float rel = (sampleY - baseY) * float(outH);
        float w = ssimCatmullRom(rel);
        float3 tex = input.sample(pointSam, float2(baseX, sampleY)).rgb;
        avg += w * tex * tex;
        W += w;
    }

    float3 result = (abs(W) > 1e-6f) ? (avg / W) : float3(0.0f);
    l2Out.write(float4(max(result, float3(0.0f)), 1.0f), gid);
}

// Pass 3: Separable horizontal Catmull-Rom downscale of L2 -> L2_2 (outW x outH, RGBA16F)
kernel void ssim_pass3_l2_h(
    texture2d<float, access::sample> l2In [[texture(0)]],
    texture2d<float, access::write> l2Out [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = l2Out.get_width();
    const uint outH = l2Out.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    constexpr sampler pointSam(filter::nearest, address::clamp_to_edge, coord::normalized);

    const float inW = float(l2In.get_width());
    const float inputPtX = 1.0f / inW;
    const float outputPtX = 1.0f / float(outW);

    const float baseX = (float(gid.x) + 0.5f) * outputPtX;
    const float baseY = (float(gid.y) + 0.5f) / float(outH);
    const float taps = 2.0f;

    int low = int(ceil((baseX - taps * outputPtX) * inW - 0.5f));
    int high = int(floor((baseX + taps * outputPtX) * inW - 0.5f));
    if (high - low > 32) {
        int mid = (low + high) / 2;
        low = mid - 16;
        high = mid + 16;
    }

    float W = 0.0f;
    float3 avg = float3(0.0f);
    for (int k = low; k <= high; ++k) {
        float sampleX = inputPtX * (float(k) + 0.5f);
        float rel = (sampleX - baseX) * float(outW);
        float w = ssimCatmullRom(rel);
        avg += w * l2In.sample(pointSam, float2(sampleX, baseY)).rgb;
        W += w;
    }

    float3 result = (abs(W) > 1e-6f) ? (avg / W) : float3(0.0f);
    l2Out.write(float4(max(result, float3(0.0f)), 1.0f), gid);
}

// Pass 4: Local 3x3 weighted mean, Sl/Sh variance, and structural gain R -> MR (outW x outH, RGBA16F)

struct SSimUniforms {
    float oversharp;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

inline float ssimLuma(float3 rgb) {
    return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

kernel void ssim_pass4_mean_r(
    texture2d<float, access::read> postKernel [[texture(0)]],
    texture2d<float, access::read> l2_2 [[texture(1)]],
    texture2d<float, access::write> mrOut [[texture(2)]],
    constant SSimUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = mrOut.get_width();
    const uint outH = mrOut.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    const int2 size = int2(outW, outH);
    const int2 p = int2(gid);
    const float kWeights[3] = { 0.5f, 1.0f, 0.5f };

    float3 avgL = float3(0.0f);
    float3 avgL2 = float3(0.0f);
    float3 avgH2 = float3(0.0f);
    float W = 0.0f;

    for (int dy = -1; dy <= 1; ++dy) {
        float wy = kWeights[dy + 1];
        for (int dx = -1; dx <= 1; ++dx) {
            float w = wy * kWeights[dx + 1];
            uint2 coord = clampCoord(p + int2(dx, dy), size);
            float3 L = postKernel.read(coord).rgb;
            float3 H2 = l2_2.read(coord).rgb;
            avgL += w * L;
            avgL2 += w * (L * L);
            avgH2 += w * H2;
            W += w;
        }
    }

    float invW = 1.0f / max(W, 1e-6f);
    avgL *= invW;
    avgL2 *= invW;
    avgH2 *= invW;

    const float sigmaNsq = 10.0f / (255.0f * 255.0f);
    float Sl = ssimLuma(max(avgL2 - avgL * avgL, float3(0.0f)));
    float Sh = ssimLuma(max(avgH2 - avgL * avgL, float3(0.0f)));

    float oversharp = max(u.oversharp, 0.0f);
    float R;
    if (Sl > Sh) {
        R = clamp(Sh / max(Sl, 1e-6f), 0.0f, 1.0f);
    } else {
        R = sqrt((Sh + sigmaNsq) / (Sl + sigmaNsq)) * oversharp;
        R = min(R, 4.0f);
    }

    mrOut.write(float4(avgL, R), gid);
}

// Pass 5: Reconstruct sharp SSIM downscaled output -> OUTPUT (outW x outH)
kernel void ssim_pass5_reconstruct(
    texture2d<float, access::read> mrTex [[texture(0)]],
    texture2d<float, access::read> postKernel [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    const int2 size = int2(outW, outH);
    const int2 p = int2(gid);
    const float kWeights[3] = { 0.5f, 1.0f, 0.5f };

    float3 avgRMean = float3(0.0f);
    float3 avgMean = float3(0.0f);
    float avgR = 0.0f;
    float W = 0.0f;

    for (int dy = -1; dy <= 1; ++dy) {
        float wy = kWeights[dy + 1];
        for (int dx = -1; dx <= 1; ++dx) {
            float w = wy * kWeights[dx + 1];
            uint2 coord = clampCoord(p + int2(dx, dy), size);
            float4 mr = mrTex.read(coord);
            avgRMean += w * (mr.a * mr.rgb);
            avgMean += w * mr.rgb;
            avgR += w * mr.a;
            W += w;
        }
    }

    float invW = 1.0f / max(W, 1e-6f);
    avgRMean *= invW;
    avgMean *= invW;
    avgR *= invW;

    float3 post = postKernel.read(clampCoord(p, size)).rgb;
    float3 recon = max(avgMean + avgR * post - avgRMean, float3(0.0f));
    output.write(float4(recon, 1.0f), gid);
}
