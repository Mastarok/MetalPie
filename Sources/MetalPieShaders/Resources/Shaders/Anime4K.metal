#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Anime4K Neural & Restoration Suite (FP16 / RGBA16F CReLU CNNs):
// - anime4k_restore_pass1..4: 4-pass CReLU CNN line-art restoration + residual
// - anime4k_bilateral_mode:   Histogram-regularized bilateral mode denoiser
// - anime4k_thin_sobel / anime4k_thin_warp: Optional line-thinning pre-pass
// - anime4k_upscale_pass1..4: 4-pass CReLU CNN + 2x depth-to-space upscaler
// Authentic trained weights from bloc97/Anime4K (S architecture).
// ============================================================================

inline uint2 clampCoord(int2 p, int2 size) {
    return uint2(clamp(p, int2(0), max(size - int2(1), int2(0))));
}

inline half4 mulAdd3x4(half3 x, half3x4 m, half4 a) {
    half4 r = fma(half4(x.x), m[0], a);
    r = fma(half4(x.y), m[1], r);
    r = fma(half4(x.z), m[2], r);
    return r;
}

inline half4 mulAdd4x4(half4 x, half4x4 m, half4 a) {
    half4 r = fma(half4(x.x), m[0], a);
    r = fma(half4(x.y), m[1], r);
    r = fma(half4(x.z), m[2], r);
    r = fma(half4(x.w), m[3], r);
    return r;
}

inline half3 mulAdd4x3(half4 x, half4x3 m, half3 a) {
    half3 r = fma(half3(x.x), m[0], a);
    r = fma(half3(x.y), m[1], r);
    r = fma(half3(x.z), m[2], r);
    r = fma(half3(x.w), m[3], r);
    return r;
}

inline void load3x3Half3(texture2d<half, access::read> tex, int2 center, int2 size, thread half3 (&t)[9]) {
    int idx = 0;
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dy = -1; dy <= 1; ++dy) {
            t[idx++] = tex.read(clampCoord(center + int2(dx, dy), size)).rgb;
        }
    }
}

inline void load3x3Half4(texture2d<half, access::read> tex, int2 center, int2 size, thread half4 (&t)[9]) {
    int idx = 0;
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dy = -1; dy <= 1; ++dy) {
            t[idx++] = tex.read(clampCoord(center + int2(dx, dy), size));
        }
    }
}

// MARK: - Anime4K Restore (1x 4-Pass CReLU CNN)

struct Anime4KRestoreUniforms {
    float strength;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

kernel void anime4k_restore_pass1(
    texture2d<half, access::read> input [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = outTex.get_width();
    const uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) return;
    half3 t[9];
    load3x3Half3(input, int2(gid), int2(input.get_width(), input.get_height()), t);
    half4 acc = half4(half(-0.011108127), half(-0.07481861), half(0.07640154), half(0.4964964));
    acc = mulAdd3x4(t[0], half3x4(half(-0.19288683), half(-0.21397883), half(0.111997396), half(-0.04791413), half(-0.26682988), half(-0.06144587), half(-0.03601853), half(-0.16693151), half(0.038494494), half(-0.16651472), half(0.147657), half(-0.083003886)), acc);
    acc = mulAdd3x4(t[1], half3x4(half(-0.14286195), half(0.08746566), half(-0.40107322), half(0.12390977), half(-0.33392772), half(-0.18703035), half(-0.21326795), half(0.04780781), half(-0.15155545), half(-0.0010025925), half(-0.1554875), half(-0.10676251)), acc);
    acc = mulAdd3x4(t[2], half3x4(half(0.28095165), half(0.022872915), half(-0.21342312), half(-0.29982176), half(0.025937587), half(-0.055012174), half(-0.33779636), half(0.0015666655), half(0.076416336), half(0.06656033), half(-0.1557806), half(0.1078894)), acc);
    acc = mulAdd3x4(t[3], half3x4(half(-0.31584853), half(0.07527119), half(0.30713862), half(-0.34014285), half(-0.50103146), half(-0.07217874), half(0.512807), half(-0.09597398), half(-0.32097813), half(-0.051580857), half(-0.022466356), half(0.01148551)), acc);
    acc = mulAdd3x4(t[4], half3x4(half(-0.026032459), half(-0.04193211), half(0.37703893), half(-0.031916667), half(-0.27421117), half(1.0906446), half(-0.049654085), half(-0.19814016), half(0.07819544), half(0.06003738), half(0.1405805), half(-0.0064135445)), acc);
    acc = mulAdd3x4(t[5], half3x4(half(0.041450135), half(0.11319654), half(-0.23237701), half(0.08443178), half(0.53344345), half(0.30857387), half(-0.057264958), half(-0.1575803), half(0.2325609), half(-0.027797326), half(-0.04544767), half(-0.18720597)), acc);
    acc = mulAdd3x4(t[6], half3x4(half(0.2531829), half(-0.074966915), half(-0.27800754), half(-0.3146097), half(0.20126024), half(-0.5380133), half(-0.15082566), half(-0.19021043), half(0.29951036), half(0.17123336), half(-0.01681872), half(-0.12574998)), acc);
    acc = mulAdd3x4(t[7], half3x4(half(0.25203633), half(0.19882993), half(0.14906439), half(0.13593598), half(0.40712556), half(0.084902965), half(0.42969635), half(0.2961132), half(-0.057267334), half(-0.030388135), half(8.8084314e-05), half(0.0210724)), acc);
    acc = mulAdd3x4(t[8], half3x4(half(-0.13459359), half(-0.12199573), half(0.12591946), half(0.24736497), half(0.2033463), half(-0.09388599), half(-0.094370656), half(0.1071285), half(-0.18479438), half(-0.066625565), half(0.08279283), half(0.20130983)), acc);
    outTex.write(acc, gid);
}

kernel void anime4k_restore_pass2(
    texture2d<half, access::read> featIn [[texture(0)]],
    texture2d<half, access::write> featOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = featOut.get_width();
    const uint h = featOut.get_height();
    if (gid.x >= w || gid.y >= h) return;
    half4 t[9];
    load3x3Half4(featIn, int2(gid), int2(featIn.get_width(), featIn.get_height()), t);
    half4 acc = half4(half(-0.16371979), half(-0.024620198), half(-0.035754893), half(0.04176776));
    acc = mulAdd4x4(max(t[0], half4(0.0h)), half4x4(half(-0.056432575), half(0.0028165397), half(-0.026325442), half(-0.14802271), half(0.16885762), half(-0.062179096), half(-0.2332292), half(0.17513658), half(-0.08011296), half(0.02947316), half(0.014771492), half(-0.17946689), half(0.026012989), half(-0.09823925), half(0.036625937), half(-0.06924322)), acc);
    acc = mulAdd4x4(max(t[1], half4(0.0h)), half4x4(half(-0.13571467), half(0.09831142), half(0.12911566), half(0.06305893), half(-0.07188695), half(-0.20161287), half(0.3858435), half(-0.21069056), half(-0.12294444), half(-0.1404628), half(-0.022659872), half(0.23008968), half(0.10969853), half(0.17640765), half(0.39796907), half(0.20413099)), acc);
    acc = mulAdd4x4(max(t[2], half4(0.0h)), half4x4(half(-0.0061665224), half(0.055102807), half(-0.0059629944), half(-0.021429887), half(0.061626043), half(0.16898955), half(-0.21215646), half(0.16510476), half(0.2238265), half(0.19429931), half(0.09874656), half(0.06828208), half(-0.122404456), half(-0.00026717107), half(-0.28203064), half(-0.29979932)), acc);
    acc = mulAdd4x4(max(t[3], half4(0.0h)), half4x4(half(-0.22735378), half(0.14538136), half(0.11549746), half(0.194148), half(-0.09841722), half(-0.0661309), half(0.348576), half(-0.017375294), half(-0.044078812), half(0.1298332), half(0.04793373), half(-0.30687734), half(0.08353025), half(0.083519086), half(0.10766399), half(0.31796935)), acc);
    acc = mulAdd4x4(max(t[4], half4(0.0h)), half4x4(half(0.048365135), half(-0.17566709), half(-0.33212858), half(-0.052667376), half(-0.26443407), half(-0.010216014), half(0.1573303), half(0.05725314), half(0.08140953), half(-0.09664591), half(0.076109104), half(-0.026773714), half(0.07732627), half(0.10188082), half(-0.28266954), half(-0.16230233)), acc);
    acc = mulAdd4x4(max(t[5], half4(0.0h)), half4x4(half(0.29931107), half(0.117944), half(-0.10414009), half(0.12795551), half(0.12576093), half(0.17082554), half(-0.15803693), half(0.13430743), half(-0.025801308), half(-0.10797019), half(0.0721032), half(0.2825884), half(-0.11025257), half(0.12798019), half(0.081827976), half(-0.050441865)), acc);
    acc = mulAdd4x4(max(t[6], half4(0.0h)), half4x4(half(-0.11827391), half(0.08306765), half(-0.3430314), half(0.07898041), half(-0.023839617), half(-0.019507334), half(0.23176382), half(-0.40992323), half(0.09411734), half(0.38415068), half(-0.25845516), half(-0.29984522), half(0.1470966), half(-0.0684779), half(-0.07071314), half(-0.026773235)), acc);
    acc = mulAdd4x4(max(t[7], half4(0.0h)), half4x4(half(0.19091596), half(0.082110435), half(-0.5266589), half(-0.1744098), half(-0.015838385), half(-0.046316292), half(0.023171103), half(-0.03731331), half(0.2642396), half(0.31824252), half(-0.041754793), half(-0.09525519), half(-0.14696182), half(0.052168854), half(0.039857205), half(-0.027555354)), acc);
    acc = mulAdd4x4(max(t[8], half4(0.0h)), half4x4(half(0.15207373), half(0.09845733), half(0.0142631065), half(0.096375965), half(0.06089903), half(0.17902578), half(-0.42391995), half(0.22475442), half(0.016356342), half(-0.06277531), half(-0.12173141), half(-0.18635495), half(-0.0013459618), half(0.15725887), half(0.019310836), half(0.20293565)), acc);
    acc = mulAdd4x4(max(-t[0], half4(0.0h)), half4x4(half(-0.18395247), half(0.30672902), half(0.09034339), half(0.1821889), half(-0.0419004), half(-0.2169228), half(-0.14052129), half(0.11006559), half(0.1709272), half(0.51062274), half(0.13758625), half(-0.2242552), half(-0.030382963), half(0.3357568), half(-0.26491287), half(0.02501938)), acc);
    acc = mulAdd4x4(max(-t[1], half4(0.0h)), half4x4(half(0.040511727), half(0.12523083), half(-0.27318433), half(0.08388512), half(0.25354835), half(0.3404216), half(-0.2632471), half(-0.17784123), half(0.2732347), half(0.4468553), half(0.084667034), half(-0.1856242), half(0.034099877), half(-0.00954992), half(-0.32751867), half(-0.062207516)), acc);
    acc = mulAdd4x4(max(-t[2], half4(0.0h)), half4x4(half(0.17564747), half(0.11645554), half(-0.16362113), half(0.105654195), half(-0.2762563), half(-0.1413764), half(0.23264363), half(-0.14000498), half(0.095402054), half(0.0715738), half(-0.19346157), half(-0.028285999), half(0.009799127), half(0.04059529), half(0.19688335), half(0.1282381)), acc);
    acc = mulAdd4x4(max(-t[3], half4(0.0h)), half4x4(half(0.23575781), half(-0.11446148), half(-0.20504695), half(0.035568226), half(0.36890212), half(-0.85968876), half(-0.18545328), half(0.33796397), half(-0.30916876), half(-0.10445518), half(-0.3046253), half(0.33271998), half(-0.06263589), half(-0.2160114), half(-0.16383372), half(-0.31173357)), acc);
    acc = mulAdd4x4(max(-t[4], half4(0.0h)), half4x4(half(0.20469664), half(0.4039374), half(-0.070057206), half(0.030353077), half(0.39843914), half(-0.15490077), half(-0.24476516), half(0.38238233), half(-0.21809858), half(0.23496576), half(-0.051794037), half(0.033664484), half(-0.14411364), half(-0.2515329), half(0.124655396), half(-0.05818785)), acc);
    acc = mulAdd4x4(max(-t[5], half4(0.0h)), half4x4(half(-0.09065731), half(-0.16787091), half(0.013269188), half(0.23687351), half(-0.41504318), half(-0.048163068), half(0.31760025), half(-0.33648986), half(0.29752317), half(0.2926866), half(0.14408836), half(-0.33382463), half(-0.15873958), half(-0.121961035), half(0.11797893), half(0.09000567)), acc);
    acc = mulAdd4x4(max(-t[6], half4(0.0h)), half4x4(half(0.13356976), half(0.013763947), half(0.012169505), half(-0.109594524), half(0.03417223), half(0.7031121), half(0.65146804), half(0.5250268), half(-0.50132495), half(-0.419648), half(0.2940041), half(0.83051753), half(-0.17595838), half(0.1633008), half(-0.018587278), half(0.079596795)), acc);
    acc = mulAdd4x4(max(-t[7], half4(0.0h)), half4x4(half(0.07570128), half(-0.1581438), half(0.03904949), half(0.14890033), half(-0.054611947), half(0.17469402), half(-0.44252598), half(0.036181703), half(-0.4981031), half(-0.37507218), half(-0.18466389), half(0.2645845), half(0.25189674), half(-0.025896115), half(0.034307647), half(-0.020462232)), acc);
    acc = mulAdd4x4(max(-t[8], half4(0.0h)), half4x4(half(-0.11645865), half(0.02296537), half(0.040909223), half(0.015069485), half(0.062284566), half(-0.22526766), half(0.09241534), half(-0.32623053), half(0.18208642), half(0.3954284), half(0.2884468), half(-0.25137675), half(-0.037232924), half(-0.10185309), half(-0.17956531), half(0.018966453)), acc);
    featOut.write(acc, gid);
}

kernel void anime4k_restore_pass3(
    texture2d<half, access::read> featIn [[texture(0)]],
    texture2d<half, access::write> featOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = featOut.get_width();
    const uint h = featOut.get_height();
    if (gid.x >= w || gid.y >= h) return;
    half4 t[9];
    load3x3Half4(featIn, int2(gid), int2(featIn.get_width(), featIn.get_height()), t);
    half4 acc = half4(half(-0.0036821906), half(-0.050239526), half(-0.01355402), half(0.00048220603));
    acc = mulAdd4x4(max(t[0], half4(0.0h)), half4x4(half(0.01921286), half(-0.26684764), half(-0.12663573), half(0.31641877), half(-0.25313398), half(0.12264074), half(0.58750325), half(-0.14084283), half(0.5837018), half(-0.042300556), half(-0.20435576), half(-0.009954825), half(0.060783498), half(0.05540401), half(0.2205112), half(-0.06578902)), acc);
    acc = mulAdd4x4(max(t[1], half4(0.0h)), half4x4(half(-0.21930243), half(-0.03774968), half(0.22615197), half(0.18338196), half(0.011201461), half(-0.271034), half(0.00573116), half(-0.12248194), half(0.47990513), half(0.2982416), half(-0.1087603), half(-0.050099242), half(-0.07620939), half(-0.07148229), half(0.03691984), half(-0.16796488)), acc);
    acc = mulAdd4x4(max(t[2], half4(0.0h)), half4x4(half(-0.14962853), half(-0.053769328), half(0.02387081), half(0.22002189), half(0.052237745), half(-0.26160842), half(-0.08603077), half(0.012542448), half(0.08119985), half(0.075785555), half(-0.33437458), half(-0.43373227), half(-0.13206963), half(-0.08759176), half(-0.03288923), half(-0.09799959)), acc);
    acc = mulAdd4x4(max(t[3], half4(0.0h)), half4x4(half(-0.1305593), half(-0.5974288), half(0.06058367), half(0.08406488), half(0.013692483), half(0.06646377), half(0.16469325), half(0.08990975), half(0.42217395), half(-0.11289523), half(-0.06165009), half(0.48556912), half(-0.15702641), half(-0.19922857), half(-0.0035429662), half(-0.0022089656)), acc);
    acc = mulAdd4x4(max(t[4], half4(0.0h)), half4x4(half(-0.1964807), half(0.038099788), half(0.21587034), half(0.039734077), half(-0.07063389), half(0.11604167), half(-0.24558097), half(-0.08900199), half(-0.7684516), half(-0.1037487), half(-0.09380674), half(0.33144563), half(-0.16653742), half(0.0028585843), half(-0.33774406), half(-0.0528696)), acc);
    acc = mulAdd4x4(max(t[5], half4(0.0h)), half4x4(half(-0.27298656), half(-0.05665099), half(0.09661685), half(0.19780266), half(0.1025106), half(-0.22055034), half(-0.21218458), half(-0.040628925), half(0.0095010325), half(0.13118382), half(-0.42582452), half(-0.22197723), half(0.21006055), half(-0.06189587), half(-0.15285942), half(-0.09526762)), acc);
    acc = mulAdd4x4(max(t[6], half4(0.0h)), half4x4(half(-0.14494462), half(-0.046788953), half(0.065877035), half(0.09911713), half(0.35096622), half(0.16682479), half(0.028363144), half(0.36037162), half(0.29413632), half(0.28212717), half(-0.025364442), half(-0.3406269), half(0.047262143), half(-0.11892685), half(-0.008032766), half(0.29743317)), acc);
    acc = mulAdd4x4(max(t[7], half4(0.0h)), half4x4(half(-0.15191558), half(-0.36980554), half(0.14555687), half(0.0043930537), half(-0.012661432), half(0.15737776), half(-0.115250416), half(0.10324491), half(0.24491951), half(-0.15575431), half(-0.27802598), half(0.21959937), half(0.18063772), half(0.4455559), half(-0.09693302), half(0.33382267)), acc);
    acc = mulAdd4x4(max(t[8], half4(0.0h)), half4x4(half(0.2717801), half(0.13452889), half(0.14105384), half(0.16324317), half(-0.40111846), half(0.1154301), half(-0.0076733204), half(-0.09697362), half(0.44306824), half(-0.02831414), half(-0.2153124), half(-0.12075326), half(0.060776163), half(0.30347148), half(-0.0036976219), half(-0.12070682)), acc);
    acc = mulAdd4x4(max(-t[0], half4(0.0h)), half4x4(half(-0.39780128), half(-0.29875937), half(-0.12952097), half(0.080333896), half(0.07520163), half(0.021689568), half(-0.23121156), half(-0.038140096), half(-0.1593877), half(0.017156163), half(-0.06038025), half(0.009244022), half(-0.13917233), half(0.30957314), half(0.243109), half(-0.104947075)), acc);
    acc = mulAdd4x4(max(-t[1], half4(0.0h)), half4x4(half(-0.07965157), half(0.06776501), half(-0.13288979), half(0.005851189), half(-0.08768168), half(-0.03689969), half(0.12034646), half(0.22441491), half(0.14453568), half(-0.17648841), half(-0.3378289), half(-0.018329712), half(0.11722939), half(-0.34161824), half(0.08424494), half(-0.01400687)), acc);
    acc = mulAdd4x4(max(-t[2], half4(0.0h)), half4x4(half(0.08153887), half(0.07222914), half(-0.14663404), half(-0.038526025), half(-0.07385973), half(0.18440577), half(0.35890242), half(0.17084727), half(0.26345527), half(0.15280858), half(-0.007446105), half(-0.024403179), half(-0.30336383), half(-0.22978698), half(0.11612946), half(-0.23614909)), acc);
    acc = mulAdd4x4(max(-t[3], half4(0.0h)), half4x4(half(-0.07447396), half(0.09023449), half(-0.13798), half(-0.086943336), half(-0.30787337), half(0.15087669), half(0.14418626), half(-0.03371195), half(0.048989657), half(-0.13075387), half(-0.13458036), half(-0.059836224), half(0.06495196), half(0.269715), half(0.3674355), half(0.38956037)), acc);
    acc = mulAdd4x4(max(-t[4], half4(0.0h)), half4x4(half(0.34981915), half(-0.048779126), half(0.31717536), half(0.38080826), half(-0.20149232), half(-0.82969636), half(-0.10167862), half(0.6382858), half(0.25976858), half(0.4370118), half(-0.04724865), half(-0.10014156), half(0.19380626), half(-0.080370255), half(0.09578106), half(-0.035166856)), acc);
    acc = mulAdd4x4(max(-t[5], half4(0.0h)), half4x4(half(-0.026443917), half(0.4132611), half(0.01822534), half(0.12742202), half(-0.26652107), half(-0.2996705), half(0.30905882), half(0.07989903), half(0.38249823), half(0.21486135), half(0.025314959), half(-0.14717339), half(-0.13344015), half(-0.32088286), half(-0.2833883), half(-0.30973712)), acc);
    acc = mulAdd4x4(max(-t[6], half4(0.0h)), half4x4(half(0.021517841), half(0.006556378), half(0.2025686), half(-0.12044382), half(-0.38583103), half(-0.0027515136), half(-0.06556736), half(-0.097090125), half(0.04676486), half(-0.11954886), half(-0.051612873), half(0.07831412), half(-0.18823163), half(-0.16542958), half(0.04245155), half(0.6437998)), acc);
    acc = mulAdd4x4(max(-t[7], half4(0.0h)), half4x4(half(-0.39475346), half(-0.2936861), half(0.26768062), half(-0.28151843), half(0.21935691), half(0.2101108), half(-0.15455097), half(0.19548604), half(0.09188909), half(-0.020147726), half(0.103328265), half(-0.12574542), half(-0.34167948), half(0.07523185), half(-0.17669058), half(0.62446547)), acc);
    acc = mulAdd4x4(max(-t[8], half4(0.0h)), half4x4(half(-0.37661025), half(-0.29630858), half(0.05451026), half(0.1611643), half(0.14079669), half(-0.2170294), half(-0.038716137), half(0.13514164), half(-0.21235192), half(-0.07860726), half(-0.005749412), half(0.025625167), half(-0.13297133), half(0.33012658), half(-0.27434957), half(-0.18416783)), acc);
    featOut.write(acc, gid);
}

kernel void anime4k_restore_pass4(
    texture2d<half, access::read> input [[texture(0)]],
    texture2d<half, access::read> featIn [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    constant Anime4KRestoreUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = output.get_width();
    const uint h = output.get_height();
    if (gid.x >= w || gid.y >= h) return;
    half4 t[9];
    load3x3Half4(featIn, int2(gid), int2(featIn.get_width(), featIn.get_height()), t);
    half3 acc = half3(half(-0.0052927984), half(-0.0060193934), half(-0.0048643993));
    acc = mulAdd4x3(max(t[0], half4(0.0h)), half4x3(half(0.15873), half(0.17989138), half(0.14648493), half(-0.017379675), half(-0.017363746), half(-0.019855022), half(0.009670625), half(0.0070157526), half(0.0075994316), half(0.025388412), half(0.027231036), half(0.024052646)), acc);
    acc = mulAdd4x3(max(t[1], half4(0.0h)), half4x3(half(0.048195973), half(0.041760173), half(0.037366055), half(-0.115950756), half(-0.12887983), half(-0.12535639), half(0.032125086), half(0.03397254), half(0.032950625), half(0.01223746), half(0.020822672), half(0.0161561)), acc);
    acc = mulAdd4x3(max(t[2], half4(0.0h)), half4x3(half(0.0890567), half(0.094453335), half(0.09014035), half(0.016081346), half(0.017434116), half(0.020783134), half(-0.011775135), half(-0.010094134), half(-0.018522855), half(0.072103254), half(0.07940666), half(0.065876864)), acc);
    acc = mulAdd4x3(max(t[3], half4(0.0h)), half4x3(half(-0.04841196), half(-0.06963968), half(-0.056574684), half(0.10912542), half(0.11813441), half(0.10643838), half(-0.013013885), half(-0.01562045), half(-0.013802797), half(0.037505716), half(0.04352026), half(0.04645123)), acc);
    acc = mulAdd4x3(max(t[4], half4(0.0h)), half4x3(half(-0.3472869), half(-0.36243078), half(-0.33530185), half(0.23654196), half(0.2305048), half(0.22150646), half(-0.045226905), half(-0.041799217), half(-0.042511635), half(-0.10267792), half(-0.1123385), half(-0.10845448)), acc);
    acc = mulAdd4x3(max(t[5], half4(0.0h)), half4x3(half(0.011987401), half(0.012285043), half(0.007813165), half(-0.15911353), half(-0.17523928), half(-0.1535267), half(0.15675929), half(0.16531634), half(0.15948962), half(-0.09240023), half(-0.09513292), half(-0.084187366)), acc);
    acc = mulAdd4x3(max(t[6], half4(0.0h)), half4x3(half(0.069052905), half(0.07278333), half(0.0756627), half(-0.012180326), half(-0.018794727), half(-0.031050753), half(-0.044663202), half(-0.04362803), half(-0.038904265), half(-0.008540197), half(-0.011201734), half(-0.01556625)), acc);
    acc = mulAdd4x3(max(t[7], half4(0.0h)), half4x3(half(-0.08261173), half(-0.09042543), half(-0.07589266), half(0.043515377), half(0.045066774), half(0.04037769), half(-0.06262993), half(-0.07469342), half(-0.058593787), half(0.026696987), half(0.028740842), half(0.037405368)), acc);
    acc = mulAdd4x3(max(t[8], half4(0.0h)), half4x3(half(0.07975598), half(0.09597654), half(0.08997132), half(-0.07844719), half(-0.07880916), half(-0.06835411), half(0.05668995), half(0.050163813), half(0.053357534), half(-0.020040333), half(-0.019867316), half(-0.01907621)), acc);
    acc = mulAdd4x3(max(-t[0], half4(0.0h)), half4x3(half(-0.017078733), half(-0.017393313), half(-0.008266595), half(-0.0033478448), half(-0.0027439648), half(-0.0042334674), half(-0.06354017), half(-0.062058125), half(-0.04652064), half(-0.010787706), half(-0.0062706997), half(-0.007573461)), acc);
    acc = mulAdd4x3(max(-t[1], half4(0.0h)), half4x3(half(-0.019895451), half(-0.016341688), half(-0.008712399), half(0.026231976), half(0.023955572), half(0.0216376), half(-0.061950512), half(-0.05481285), half(-0.05261985), half(-0.018804235), half(-0.016235247), half(-0.0131616965)), acc);
    acc = mulAdd4x3(max(-t[2], half4(0.0h)), half4x3(half(-0.055628926), half(-0.063315354), half(-0.057192408), half(-0.0256364), half(-0.028660972), half(-0.02937357), half(-0.017604912), half(-0.020851422), half(-0.016070362), half(-0.0870202), half(-0.0832279), half(-0.07525406)), acc);
    acc = mulAdd4x3(max(-t[3], half4(0.0h)), half4x3(half(0.062738225), half(0.07106593), half(0.061644047), half(-0.06068257), half(-0.06983662), half(-0.066070385), half(0.024919355), half(0.03227179), half(0.028569462), half(-0.07866227), half(-0.098967604), half(-0.092128105)), acc);
    acc = mulAdd4x3(max(-t[4], half4(0.0h)), half4x3(half(0.040397774), half(0.047241107), half(0.03962998), half(-0.09112752), half(-0.10057507), half(-0.09301817), half(0.10833967), half(0.101835825), half(0.10027467), half(0.27189335), half(0.27433604), half(0.26781923)), acc);
    acc = mulAdd4x3(max(-t[5], half4(0.0h)), half4x3(half(-0.044211388), half(-0.042373534), half(-0.03658007), half(0.113148406), half(0.12423258), half(0.107804194), half(-0.17081551), half(-0.18562958), half(-0.17475435), half(0.09636739), half(0.10763415), half(0.093332425)), acc);
    acc = mulAdd4x3(max(-t[6], half4(0.0h)), half4x3(half(-0.03798545), half(-0.047811143), half(-0.050768293), half(0.018775463), half(0.026812987), half(0.03452908), half(0.0055677597), half(0.0039081173), half(-0.0017878668), half(-0.10728597), half(-0.12618187), half(-0.109045394)), acc);
    acc = mulAdd4x3(max(-t[7], half4(0.0h)), half4x3(half(0.06359783), half(0.064184755), half(0.04934199), half(-0.009819327), half(-0.006616115), half(-0.007431496), half(0.025055679), half(0.024787048), half(0.017360551), half(-0.047140837), half(-0.061695747), half(-0.06440822)), acc);
    acc = mulAdd4x3(max(-t[8], half4(0.0h)), half4x3(half(0.060199022), half(0.06482763), half(0.059514645), half(0.026998974), half(0.028776823), half(0.024897143), half(0.17968474), half(0.19337215), half(0.16760105), half(0.0075838566), half(0.010503482), half(0.011993149)), acc);
    half3 base = input.read(clampCoord(int2(gid), int2(input.get_width(), input.get_height()))).rgb;
    half3 restored = saturate(base + acc * half(clamp(u.strength, 0.0f, 2.0f)));
    output.write(half4(restored, 1.0h), gid);
}

// MARK: - Anime4K Bilateral Mode Denoise

struct Anime4KDenoiseUniforms {
    float denoiseStrength;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

inline float a4kGaussian(float x, float s, float m) {
    float scaled = (x - m) / max(s, 1e-4f);
    return exp(-0.5f * scaled * scaled);
}

kernel void anime4k_bilateral_mode(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Anime4KDenoiseUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = output.get_width();
    const uint h = output.get_height();
    if (gid.x >= w || gid.y >= h) return;

    const int2 size = int2(input.get_width(), input.get_height());
    const int2 p = int2(gid);
    float3 centerRGB = input.read(clampCoord(p, size)).rgb;
    float strength = clamp(u.denoiseStrength, 0.0f, 1.0f);
    if (strength <= 0.001f) {
        output.write(float4(centerRGB, 1.0f), gid);
        return;
    }

    const float intensitySigma = 0.05f + strength * 0.25f;
    const float spatialSigma = 1.0f;
    const float histReg = 0.2f;
    const float3 kLuma = float3(0.299f, 0.587f, 0.114f);

    float3 histV[9];
    float histL[9];
    float histW[9];
    float histWN[9];

    float vc = dot(centerRGB, kLuma);
    float is = max((vc + 0.0001f) * intensitySigma, 1e-4f);

    int k = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float3 rgb = input.read(clampCoord(p + int2(dx, dy), size)).rgb;
            float l = dot(rgb, kLuma);
            histV[k] = rgb;
            histL[k] = l;
            histW[k] = a4kGaussian(l, is, vc) * a4kGaussian(length(float2(dx, dy)), spatialSigma, 0.0f);
            histWN[k] = 0.0f;
            ++k;
        }
    }

    for (int a = 0; a < 9; ++a) {
        histWN[a] += histW[a];
        for (int b = a + 1; b < 9; ++b) {
            float d = a4kGaussian(histL[b], histReg, histL[a]);
            histWN[b] += d * histW[a];
            histWN[a] += d * histW[b];
        }
    }

    float3 modeRGB = centerRGB;
    float bestW = -1.0f;
    for (int a = 0; a < 9; ++a) {
        if (histWN[a] >= bestW) {
            bestW = histWN[a];
            modeRGB = histV[a];
        }
    }

    float3 blended = mix(centerRGB, modeRGB, strength);
    output.write(float4(saturate(blended), 1.0f), gid);
}

// MARK: - Optional Line-Thinning Pre-Pass (Anime4K Thin)

struct Anime4KThinUniforms {
    float lineThinning;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

kernel void anime4k_thin_sobel(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<half, access::write> gradOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = gradOut.get_width();
    const uint h = gradOut.get_height();
    if (gid.x >= w || gid.y >= h) return;

    const int2 size = int2(input.get_width(), input.get_height());
    const int2 p = int2(gid);
    const float3 kLuma = float3(0.299f, 0.587f, 0.114f);

    float l[9];
    int idx = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            l[idx++] = dot(input.read(clampCoord(p + int2(dx, dy), size)).rgb, kLuma);
        }
    }

    float gx = (-l[0] + l[2] - 2.0f * l[3] + 2.0f * l[5] - l[6] + l[8]) * 0.125f;
    float gy = (-l[0] - 2.0f * l[1] - l[2] + l[6] + 2.0f * l[7] + l[8]) * 0.125f;
    float mag = pow(max(sqrt(gx * gx + gy * gy), 0.0f), 0.7f);
    gradOut.write(half4(half(mag), 0.0h, 0.0h, 1.0h), gid);
}

kernel void anime4k_thin_warp(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<half, access::read> gradMag [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant Anime4KThinUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = output.get_width();
    const uint h = output.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);
    const int2 size = int2(gradMag.get_width(), gradMag.get_height());
    const int2 p = int2(gid);

    float g[9];
    int idx = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            g[idx++] = float(gradMag.read(clampCoord(p + int2(dx, dy), size)).r);
        }
    }
    float2 dn = float2(
        (-g[0] + g[2] - 2.0f * g[3] + 2.0f * g[5] - g[6] + g[8]) * 0.125f,
        (-g[0] - 2.0f * g[1] - g[2] + g[6] + 2.0f * g[7] + g[8]) * 0.125f
    );
    float2 inputPt = 1.0f / float2(w, h);
    float relStr = (float(h) / 1080.0f) * clamp(u.lineThinning, 0.0f, 1.0f) * 0.6f;
    float2 dd = (dn / (length(dn) + 0.01f)) * inputPt * relStr;
    float2 uv = (float2(gid) + 0.5f) * inputPt - dd;
    float3 col = input.sample(linearSam, uv).rgb;
    output.write(float4(saturate(col), 1.0f), gid);
}

// MARK: - Anime4K Upscale & Denoise 2x (4-Pass CReLU CNN + Depth-to-Space)

kernel void anime4k_upscale_pass1(
    texture2d<half, access::read> input [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = outTex.get_width();
    const uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) return;
    half3 t[9];
    load3x3Half3(input, int2(gid), int2(input.get_width(), input.get_height()), t);
    half4 acc = half4(half(-0.004601904), half(-0.0030944077), half(0.14569537), half(-0.016794242));
    acc = mulAdd3x4(t[0], half3x4(half(6.5515305e-05), half(0.09565814), half(-0.0022499533), half(0.14627136), half(-0.0065872427), half(0.1441769), half(0.17772098), half(0.16298898), half(0.03727593), half(0.02010636), half(0.013131043), half(0.07891907)), acc);
    acc = mulAdd3x4(t[1], half3x4(half(0.029612074), half(-0.01204274), half(0.07698074), half(0.3855172), half(0.0045466167), half(-0.0859741), half(0.26930287), half(0.67549795), half(-0.036623597), half(0.051749162), half(-0.04714053), half(0.16092339)), acc);
    acc = mulAdd3x4(t[2], half3x4(half(-0.030328937), half(-0.15884648), half(0.0082092965), half(-0.05052196), half(0.041409027), half(-0.23017453), half(0.31568366), half(0.05136558), half(-0.0106390705), half(-0.12503141), half(-0.07030922), half(-0.08512375)), acc);
    acc = mulAdd3x4(t[3], half3x4(half(0.059616547), half(-0.12322959), half(0.058520414), half(-0.039292034), half(0.08059592), half(-0.22441447), half(0.15380386), half(-0.17675085), half(-0.009270574), half(0.034731936), half(-0.048767723), half(0.025933916)), acc);
    acc = mulAdd3x4(t[4], half3x4(half(-0.4495482), half(0.37551787), half(-0.4227873), half(-0.4890034), half(-0.9007091), half(0.7524192), half(-1.271679), half(-0.68366605), half(-0.07302573), half(0.09378561), half(0.010367829), half(-0.24593607)), acc);
    acc = mulAdd3x4(t[5], half3x4(half(0.12684742), half(-0.11042779), half(0.01793761), half(0.06982078), half(0.12901784), half(-0.10123104), half(-0.2129385), half(-0.15062876), half(0.019824497), half(-0.015181707), half(0.070795976), half(0.13549626)), acc);
    acc = mulAdd3x4(t[6], half3x4(half(-0.036070887), half(-0.2733308), half(0.05836442), half(-0.06817092), half(-0.08980838), half(-0.514616), half(0.2965783), half(0.103823625), half(-0.015213521), half(-0.16376303), half(0.0017071419), half(-0.0922202)), acc);
    acc = mulAdd3x4(t[7], half3x4(half(-0.053406045), half(0.011273207), half(-0.05544644), half(0.09432561), half(-0.04143601), half(-0.0783786), half(-0.39899537), half(0.040322974), half(-0.046442945), half(0.052499074), half(0.03397099), half(0.05516481)), acc);
    acc = mulAdd3x4(t[8], half3x4(half(0.35976252), half(0.197882), half(0.031213427), half(-0.02211337), half(0.7940331), half(0.327452), half(0.30120966), half(0.03181121), half(0.13782893), half(0.060073618), half(-0.00940469), half(-0.0358819)), acc);
    outTex.write(acc, gid);
}

kernel void anime4k_upscale_pass2(
    texture2d<half, access::read> featIn [[texture(0)]],
    texture2d<half, access::write> featOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = featOut.get_width();
    const uint h = featOut.get_height();
    if (gid.x >= w || gid.y >= h) return;
    half4 t[9];
    load3x3Half4(featIn, int2(gid), int2(featIn.get_width(), featIn.get_height()), t);
    half4 acc = half4(half(0.022899346), half(0.033619333), half(0.030674957), half(-0.017047008));
    acc = mulAdd4x4(max(t[0], half4(0.0h)), half4x4(half(-0.103708945), half(-0.050891697), half(-0.2067834), half(-0.033582103), half(-0.08676132), half(0.15528207), half(-0.10070597), half(-0.13641205), half(0.030959459), half(0.12798834), half(-0.058627255), half(-0.008511715), half(0.023304658), half(-0.027084433), half(0.120355256), half(-0.023104342)), acc);
    acc = mulAdd4x4(max(t[1], half4(0.0h)), half4x4(half(0.0550643), half(-0.26851672), half(0.11073926), half(0.21989855), half(0.012853378), half(0.028077757), half(0.073306665), half(-0.04551125), half(0.16005373), half(-0.018154016), half(-0.12347146), half(-0.07590073), half(-0.10193998), half(0.084696375), half(0.04041413), half(-0.030883553)), acc);
    acc = mulAdd4x4(max(t[2], half4(0.0h)), half4x4(half(-0.04816972), half(0.0804637), half(0.0071406), half(-0.08482986), half(0.11176785), half(0.060121994), half(-0.047804814), half(-0.036170192), half(0.01989302), half(-0.12537469), half(-0.16283676), half(0.19132937), half(-0.052577138), half(-0.005143432), half(0.045614418), half(0.04198543)), acc);
    acc = mulAdd4x4(max(t[3], half4(0.0h)), half4x4(half(-0.33660156), half(0.036350835), half(-0.4623589), half(-0.04140598), half(0.2436438), half(-0.044735093), half(0.20876355), half(-0.004252532), half(0.81046224), half(-0.18550895), half(0.32743093), half(0.109012894), half(-0.34675312), half(-0.03464997), half(-0.09489919), half(-0.07961427)), acc);
    acc = mulAdd4x4(max(t[4], half4(0.0h)), half4x4(half(-0.08862038), half(-0.8168393), half(0.03584266), half(0.32159033), half(0.06634099), half(0.2985745), half(-0.18204363), half(-0.016070427), half(0.35503992), half(1.1388919), half(0.16171643), half(-0.63834023), half(-0.0037699202), half(-0.27919513), half(-0.20949292), half(0.03270466)), acc);
    acc = mulAdd4x4(max(t[5], half4(0.0h)), half4x4(half(0.021701936), half(-0.04537874), half(-0.05514495), half(0.23225744), half(0.024968185), half(0.1816845), half(0.03485249), half(-0.28249854), half(-0.37759346), half(-0.3225813), half(0.021595621), half(0.17104608), half(-0.0044055753), half(0.01621266), half(-0.015169225), half(0.08956203)), acc);
    acc = mulAdd4x4(max(t[6], half4(0.0h)), half4x4(half(-0.033255238), half(-0.110517226), half(0.10664505), half(0.019566126), half(-0.0695305), half(0.059743922), half(-0.19161415), half(-0.024217626), half(-0.08578889), half(-0.16358584), half(-0.23050265), half(-0.004697784), half(-0.060790297), half(0.1174991), half(0.08205285), half(-0.011846926)), acc);
    acc = mulAdd4x4(max(t[7], half4(0.0h)), half4x4(half(0.6119327), half(0.0791928), half(-0.118774265), half(0.42233524), half(-0.16248553), half(-0.017692063), half(0.13530938), half(-0.3207985), half(-0.147722), half(-0.24525681), half(0.05243329), half(-0.38583818), half(0.5147888), half(-0.072632834), half(-0.6014986), half(0.26713687)), acc);
    acc = mulAdd4x4(max(t[8], half4(0.0h)), half4x4(half(0.23735437), half(-0.032110002), half(0.17445332), half(-0.3272264), half(0.020623574), half(0.26734766), half(-0.16806662), half(0.0796467), half(-0.34921628), half(0.016648084), half(-0.14200358), half(0.59190625), half(0.13177821), half(0.11139572), half(-0.14972521), half(-0.16784541)), acc);
    acc = mulAdd4x4(max(-t[0], half4(0.0h)), half4x4(half(-0.047283772), half(-0.003196778), half(0.44890094), half(0.14619343), half(-0.17113213), half(-0.068454474), half(0.07681565), half(-0.04306807), half(-0.0022641511), half(-0.20954822), half(0.0344229), half(0.014815744), half(-0.010632933), half(0.13355999), half(-0.0860752), half(-0.069001146)), acc);
    acc = mulAdd4x4(max(-t[1], half4(0.0h)), half4x4(half(0.11664345), half(0.099102855), half(0.1642523), half(0.047408774), half(0.038490184), half(0.16064398), half(-0.08694127), half(-0.2149453), half(-0.1413128), half(-0.06531084), half(-0.10105762), half(0.19743964), half(0.10458527), half(-0.04133969), half(0.1425028), half(-0.01328308)), acc);
    acc = mulAdd4x4(max(-t[2], half4(0.0h)), half4x4(half(0.0138432095), half(-0.20053013), half(0.079355195), half(0.273772), half(0.05484276), half(0.13891658), half(0.16240036), half(-0.25245088), half(0.011192391), half(0.104164094), half(0.08112111), half(-0.250435), half(-0.0559613), half(-0.031029798), half(-0.015725998), half(0.09240792)), acc);
    acc = mulAdd4x4(max(-t[3], half4(0.0h)), half4x4(half(0.18754779), half(-0.33171803), half(0.34917468), half(0.29074225), half(-0.37954012), half(0.20898043), half(-0.24973525), half(-0.13707505), half(-0.31585664), half(0.13607393), half(-0.29118514), half(0.015055187), half(0.18549949), half(-0.06351915), half(0.2823401), half(-0.00019733967)), acc);
    acc = mulAdd4x4(max(-t[4], half4(0.0h)), half4x4(half(0.10060476), half(0.2883022), half(-0.15810104), half(-0.041112892), half(0.31050095), half(0.18517002), half(0.020033397), half(-0.35919502), half(-0.17903808), half(-0.43506318), half(-0.14783014), half(0.20092726), half(-0.002020754), half(0.13320895), half(0.040995706), half(0.052643474)), acc);
    acc = mulAdd4x4(max(-t[5], half4(0.0h)), half4x4(half(-0.014892139), half(0.005828587), half(0.044784732), half(-0.27272886), half(0.21069369), half(0.044396695), half(-0.03411123), half(0.031441864), half(0.17224072), half(0.1708587), half(-0.00729118), half(-0.13070418), half(-0.19128975), half(-0.09342688), half(-0.051133234), half(-0.089075714)), acc);
    acc = mulAdd4x4(max(-t[6], half4(0.0h)), half4x4(half(0.08799108), half(0.04157696), half(-0.15010124), half(0.26832178), half(-0.0040120087), half(0.040308744), half(0.17632529), half(-0.09464763), half(0.07786305), half(0.038288828), half(0.40799135), half(0.037377868), half(-0.049877923), half(-0.25080636), half(0.00068664295), half(0.0013101585)), acc);
    acc = mulAdd4x4(max(-t[7], half4(0.0h)), half4x4(half(0.0353459), half(-0.21445732), half(0.112647906), half(-0.3513759), half(0.16887255), half(0.3224789), half(-0.17073384), half(0.10875396), half(0.18919177), half(0.14288992), half(0.07364533), half(0.20205943), half(-0.34363645), half(-0.3520186), half(0.6763608), half(-0.19051236)), acc);
    acc = mulAdd4x4(max(-t[8], half4(0.0h)), half4x4(half(-0.032245517), half(0.039594565), half(-0.11825768), half(0.16509856), half(0.11749939), half(-0.005166539), half(0.10740687), half(-0.3794017), half(0.12722437), half(0.14066173), half(0.08025407), half(-0.34773758), half(-0.027300838), half(-0.08963159), half(0.29774833), half(0.053532287)), acc);
    featOut.write(acc, gid);
}

kernel void anime4k_upscale_pass3(
    texture2d<half, access::read> featIn [[texture(0)]],
    texture2d<half, access::write> featOut [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint w = featOut.get_width();
    const uint h = featOut.get_height();
    if (gid.x >= w || gid.y >= h) return;
    half4 t[9];
    load3x3Half4(featIn, int2(gid), int2(featIn.get_width(), featIn.get_height()), t);
    half4 acc = half4(half(0.04921464), half(-0.0011432811), half(0.062071066), half(-0.06594219));
    acc = mulAdd4x4(max(t[0], half4(0.0h)), half4x4(half(-0.0714004), half(-0.0545495), half(-0.050848898), half(0.04724593), half(0.2214181), half(0.26353878), half(0.07314053), half(-0.18771721), half(0.06282607), half(-0.03720548), half(0.020577375), half(-0.08951135), half(0.40820515), half(0.012179098), half(0.52947706), half(-0.48448065)), acc);
    acc = mulAdd4x4(max(t[1], half4(0.0h)), half4x4(half(0.10311368), half(-0.10970221), half(0.07008208), half(-0.07143153), half(0.073753305), half(0.03786335), half(-0.4312538), half(-0.17680745), half(-0.15527713), half(-0.06711554), half(-0.21828765), half(0.27252844), half(-0.0025433605), half(0.31595528), half(-0.06065309), half(0.059542265)), acc);
    acc = mulAdd4x4(max(t[2], half4(0.0h)), half4x4(half(-0.036736265), half(0.08704119), half(-0.06530063), half(0.04546563), half(0.010335546), half(-0.040761005), half(-0.021500558), half(0.104531065), half(0.094652064), half(-0.05088704), half(0.14768088), half(-0.08585825), half(0.057680476), half(0.09885713), half(0.18074304), half(-0.14277679)), acc);
    acc = mulAdd4x4(max(t[3], half4(0.0h)), half4x4(half(-0.04810641), half(-0.01735864), half(-0.06405213), half(0.04889552), half(-0.011552542), half(-0.04617259), half(0.023976233), half(0.27587202), half(-0.117965676), half(-0.07052052), half(-0.030583147), half(-0.036600694), half(-0.08542387), half(-0.053850796), half(0.27242282), half(-0.73792183)), acc);
    acc = mulAdd4x4(max(t[4], half4(0.0h)), half4x4(half(-0.1340838), half(0.1256252), half(-0.040528856), half(0.13554344), half(-0.13733707), half(-0.14641404), half(0.42666963), half(-0.4933124), half(-0.34908), half(0.054332364), half(-0.2768947), half(0.44689894), half(0.42182985), half(-0.027279109), half(-0.17136064), half(-0.009496184)), acc);
    acc = mulAdd4x4(max(t[5], half4(0.0h)), half4x4(half(0.075086355), half(-0.025501372), half(0.02172236), half(-0.052761186), half(-0.055753034), half(-0.028023237), half(-0.08829973), half(0.14333946), half(0.062496934), half(0.034493748), half(0.17640088), half(-0.084869936), half(0.21283653), half(0.1184779), half(0.0016387368), half(-0.1498814)), acc);
    acc = mulAdd4x4(max(t[6], half4(0.0h)), half4x4(half(0.054841094), half(0.040639404), half(-0.025044259), half(-0.071105786), half(-0.07473824), half(-0.04719771), half(0.016553668), half(-0.10028357), half(0.009365985), half(-0.0133521445), half(0.022320358), half(-0.09318326), half(0.17342545), half(0.19281831), half(0.16737404), half(-0.09583887)), acc);
    acc = mulAdd4x4(max(t[7], half4(0.0h)), half4x4(half(-0.03950585), half(0.091417804), half(-0.021395942), half(0.08735149), half(-0.029363452), half(-0.04763804), half(-0.1430701), half(0.15344201), half(-0.006604305), half(0.05897304), half(-0.13595524), half(0.083323576), half(0.008187976), half(0.12946083), half(0.14983748), half(-0.08178542)), acc);
    acc = mulAdd4x4(max(t[8], half4(0.0h)), half4x4(half(-0.00046765045), half(-0.07914878), half(0.03529457), half(-0.007752294), half(-0.10084779), half(-0.1531338), half(-0.1408283), half(0.20638838), half(0.01466853), half(-0.059309185), half(-0.11161097), half(0.08481583), half(0.090416916), half(0.081118226), half(0.08677104), half(-0.20095336)), acc);
    acc = mulAdd4x4(max(-t[0], half4(0.0h)), half4x4(half(0.3200496), half(-0.049090706), half(0.11554867), half(-0.11949655), half(-0.18064958), half(0.0012254696), half(-0.032284267), half(0.00076361356), half(-0.13239916), half(-0.13838826), half(-0.20345089), half(0.00692921), half(-0.2271236), half(-0.07132879), half(-0.097703665), half(0.29881954)), acc);
    acc = mulAdd4x4(max(-t[1], half4(0.0h)), half4x4(half(0.4095371), half(0.3008338), half(-0.43109173), half(-0.495734), half(0.15016843), half(-0.3890023), half(1.0669806), half(-0.20876339), half(-0.32241493), half(-0.10387533), half(-0.018227777), half(0.1349976), half(-0.0019588785), half(-0.19263229), half(0.38952798), half(0.08135965)), acc);
    acc = mulAdd4x4(max(-t[2], half4(0.0h)), half4x4(half(0.01517036), half(-0.51562387), half(-0.13939962), half(-0.23287989), half(0.09597558), half(0.017624658), half(0.16989397), half(-0.09395267), half(-0.29612765), half(0.11843327), half(-0.07493133), half(0.14523852), half(0.040488124), half(0.016568637), half(0.10204776), half(-0.13137013)), acc);
    acc = mulAdd4x4(max(-t[3], half4(0.0h)), half4x4(half(-0.1512155), half(-0.12732185), half(0.08002965), half(0.024762904), half(0.05106389), half(0.011125884), half(-0.043196492), half(-0.17617282), half(0.09791206), half(0.120643355), half(0.075500526), half(0.10948051), half(0.04969893), half(-0.20776172), half(-0.06905779), half(-0.20245977)), acc);
    acc = mulAdd4x4(max(-t[4], half4(0.0h)), half4x4(half(-0.41836104), half(-0.82896453), half(-0.20962712), half(0.7804863), half(0.17322528), half(0.53994787), half(-0.18730208), half(-0.021233026), half(0.7417944), half(-0.4544313), half(0.23165174), half(-0.63969344), half(0.09383021), half(-0.046137553), half(-0.07796646), half(0.11413524)), acc);
    acc = mulAdd4x4(max(-t[5], half4(0.0h)), half4x4(half(-0.32532063), half(0.09456587), half(0.43708017), half(-0.40595353), half(0.061229162), half(0.006663704), half(-0.19821976), half(0.07661682), half(-0.21427135), half(0.17748164), half(-0.31958643), half(0.3883502), half(0.068938896), half(0.022886515), half(0.022923468), half(-0.04269318)), acc);
    acc = mulAdd4x4(max(-t[6], half4(0.0h)), half4x4(half(0.23775512), half(0.04026384), half(0.12276414), half(-0.2545085), half(0.0894177), half(0.115443565), half(0.029124375), half(0.08887401), half(-0.0057824687), half(0.017655179), half(-0.025270017), half(-0.06643964), half(0.01316084), half(0.024039604), half(0.034566984), half(-0.12682836)), acc);
    acc = mulAdd4x4(max(-t[7], half4(0.0h)), half4x4(half(0.036596492), half(0.22772355), half(-0.05508538), half(-0.18005793), half(-0.06432669), half(-0.037058707), half(0.2718052), half(-0.10313161), half(0.016055575), half(0.051271006), half(-0.038919963), half(-0.036601298), half(-0.019457681), half(0.03805731), half(0.03252896), half(-0.07179724)), acc);
    acc = mulAdd4x4(max(-t[8], half4(0.0h)), half4x4(half(0.15046261), half(0.13090402), half(-0.023847125), half(-0.039356075), half(0.045424663), half(-0.20594294), half(0.2154043), half(-0.18429665), half(-0.07969159), half(0.08719893), half(-0.057626463), half(0.08344988), half(-0.018651528), half(0.047302175), half(0.060727824), half(-0.035960387)), acc);
    featOut.write(acc, gid);
}

kernel void anime4k_upscale_pass4(
    texture2d<half, access::sample> input [[texture(0)]],
    texture2d<half, access::read> featIn [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Dispatched at input resolution (inW x inH); each thread writes a 2x2 output subpixel quad.
    const uint inW = featIn.get_width();
    const uint inH = featIn.get_height();
    if (gid.x >= inW || gid.y >= inH) return;

    const uint outW = output.get_width();
    const uint outH = output.get_height();
    constexpr sampler linearSam(filter::linear, address::clamp_to_edge, coord::normalized);

    half4 t[9];
    load3x3Half4(featIn, int2(gid), int2(inW, inH), t);
    half4 acc = half4(half(-0.0031417734), half(-0.002754766), half(-0.004053268), half(-0.003937834));
    acc = mulAdd4x4(max(t[0], half4(0.0h)), half4x4(half(-0.04508749), half(0.00222134), half(0.013338363), half(-0.0067310617), half(0.099346675), half(0.05804196), half(0.018694466), half(-0.008126048), half(0.007771997), half(-0.0072556734), half(-0.008293339), half(0.001518462), half(-0.06296499), half(-0.064195156), half(0.0727399), half(0.044078834)), acc);
    acc = mulAdd4x4(max(t[1], half4(0.0h)), half4x4(half(0.20800652), half(-0.016071903), half(-0.08095607), half(-0.03472411), half(-0.20690396), half(0.061331827), half(-0.10627648), half(0.12838624), half(0.036534917), half(-0.006113497), half(0.029266752), half(-0.002263159), half(0.2937966), half(-0.05544609), half(0.14546311), half(-0.01290958)), acc);
    acc = mulAdd4x4(max(t[2], half4(0.0h)), half4x4(half(0.07792222), half(-7.288649e-05), half(0.2800036), half(0.019709835), half(-0.010950291), half(0.021879988), half(0.037608813), half(0.055267945), half(0.018646395), half(-0.016691998), half(0.03787624), half(-0.006547077), half(0.03214097), half(-0.018541625), half(0.12142825), half(-0.070806496)), acc);
    acc = mulAdd4x4(max(t[3], half4(0.0h)), half4x4(half(-0.009798109), half(-0.06606263), half(0.0010101331), half(0.009924258), half(-0.10272075), half(-0.07983353), half(0.028398676), half(0.04967719), half(0.12467993), half(0.06775066), half(0.017111637), half(0.012814711), half(0.0031143876), half(-0.0902014), half(0.11242646), half(0.076476306)), acc);
    acc = mulAdd4x4(max(t[4], half4(0.0h)), half4x4(half(0.07650971), half(0.35096344), half(0.0612814), half(0.06036218), half(0.253547), half(-0.0460987), half(-0.11145313), half(-0.48844674), half(-0.050644107), half(0.038706005), half(0.19390784), half(0.035322774), half(-0.010191005), half(0.58071), half(-0.2856661), half(-0.009533105)), acc);
    acc = mulAdd4x4(max(t[5], half4(0.0h)), half4x4(half(-0.071486905), half(-0.036179904), half(-0.07303894), half(0.19301178), half(-0.11499898), half(-0.024847068), half(-0.0027055284), half(0.20373714), half(-0.09671404), half(-0.020897992), half(-0.25572056), half(-0.008931707), half(-0.13582602), half(-0.006546881), half(-0.16154496), half(0.26454738)), acc);
    acc = mulAdd4x4(max(t[6], half4(0.0h)), half4x4(half(0.005463064), half(0.006769753), half(0.0039625713), half(0.014121269), half(-0.068200685), half(-0.057850275), half(0.008622973), half(0.061149873), half(0.017436448), half(0.11660872), half(-0.02994459), half(0.008590145), half(-0.03223439), half(0.052557915), half(-0.011846354), half(0.03523357)), acc);
    acc = mulAdd4x4(max(t[7], half4(0.0h)), half4x4(half(-0.00015264735), half(0.0012872831), half(0.021878848), half(0.022240406), half(0.01822283), half(-0.008284247), half(-0.018443186), half(-0.04997753), half(-0.111760505), half(-0.20911667), half(0.006166832), half(0.14597091), half(0.02305932), half(-0.16312876), half(0.023375351), half(-0.028755601)), acc);
    acc = mulAdd4x4(max(t[8], half4(0.0h)), half4x4(half(0.013701143), half(0.010794129), half(0.0024321147), half(-0.018976321), half(0.0365032), half(-0.006783485), half(0.01046472), half(-0.08473902), half(0.057523903), half(0.029831914), half(0.0040916028), half(-0.2046352), half(0.03542), half(-0.034598), half(0.0031058635), half(-0.20746285)), acc);
    acc = mulAdd4x4(max(-t[0], half4(0.0h)), half4x4(half(0.09283864), half(-0.0035849356), half(0.013190911), half(-0.035437535), half(0.035798516), half(0.022954805), half(-0.0029692063), half(-0.006633743), half(-0.13456796), half(-0.011448714), half(0.011536131), half(0.046695728), half(-0.0359048), half(-0.01144856), half(-0.0027279712), half(0.0065755467)), acc);
    acc = mulAdd4x4(max(-t[1], half4(0.0h)), half4x4(half(-0.14295974), half(-0.0034393691), half(0.0051469817), half(-0.021334402), half(-0.05882422), half(-0.003004241), half(0.011182507), half(0.0015169785), half(0.08474255), half(0.1255887), half(-0.23984577), half(0.07119401), half(-0.12547183), half(0.038449038), half(0.007738907), half(0.031506266)), acc);
    acc = mulAdd4x4(max(-t[2], half4(0.0h)), half4x4(half(-0.028237654), half(0.010254326), half(-0.11843009), half(0.03034298), half(-0.038323015), half(0.0026470951), half(-0.060652684), half(0.0022312272), half(-0.022539174), half(-0.01008126), half(0.14868541), half(0.02881852), half(-0.05327277), half(-0.012296453), half(-0.21280704), half(-0.021286633)), acc);
    acc = mulAdd4x4(max(-t[3], half4(0.0h)), half4x4(half(-0.034825645), half(0.0877418), half(-0.009103147), half(0.041650586), half(0.0135769), half(-0.005229229), half(0.00082947424), half(-0.0020421906), half(0.12402267), half(0.007698874), half(-0.056337915), half(-0.006580138), half(-0.018867968), half(-0.08487179), half(-0.020938644), half(-0.029210499)), acc);
    acc = mulAdd4x4(max(-t[4], half4(0.0h)), half4x4(half(-0.37082648), half(-0.30321857), half(-0.22912364), half(-0.07368761), half(0.15169628), half(0.0013253551), half(0.09232649), half(0.011408914), half(0.06347244), half(-0.377988), half(0.13980117), half(-0.41065913), half(-0.00040237256), half(-0.23220152), half(-0.03643865), half(-0.10101427)), acc);
    acc = mulAdd4x4(max(-t[5], half4(0.0h)), half4x4(half(0.10692653), half(0.049867555), half(-0.011915118), half(-0.10688069), half(0.042109665), half(-0.017163716), half(0.10852331), half(-0.0088934945), half(0.06780516), half(-0.017808875), half(0.26564032), half(0.0523693), half(0.099033475), half(0.042864073), half(0.18299587), half(-0.13503626)), acc);
    acc = mulAdd4x4(max(-t[6], half4(0.0h)), half4x4(half(0.07014404), half(0.08841395), half(0.01895322), half(0.0036451078), half(-0.00933168), half(0.044764042), half(-0.0034986525), half(0.010701783), half(-0.043601245), half(-0.1375109), half(0.0039965697), half(-0.054331), half(0.018830067), half(0.040386382), half(0.007759782), half(-0.012478715)), acc);
    acc = mulAdd4x4(max(-t[7], half4(0.0h)), half4x4(half(0.024152381), half(-0.11462646), half(0.07005155), half(0.0424638), half(-0.0048070764), half(0.06089261), half(-0.036675487), half(0.057459857), half(0.02478629), half(0.2926517), half(-0.08248396), half(-0.053960845), half(0.013205341), half(0.09851673), half(-0.04310949), half(-0.001428641)), acc);
    acc = mulAdd4x4(max(-t[8], half4(0.0h)), half4x4(half(0.016168298), half(0.009701502), half(0.0064305146), half(-0.068672284), half(-0.044653386), half(-0.016051823), half(-0.015055443), half(0.032019246), half(-0.0829852), half(-0.011304939), half(0.0023902296), half(0.30322486), half(-0.023831543), half(-0.0046928846), half(0.026961725), half(0.16314326)), acc);

    const float2 outputPt = 1.0f / float2(outW, outH);
    const uint2 base = gid * 2u;

    if (base.x < outW && base.y < outH) {
        float2 uv = (float2(base) + 0.5f) * outputPt;
        output.write(half4(saturate(acc.x + input.sample(linearSam, uv).rgb), 1.0h), base);
    }
    if (base.x + 1u < outW && base.y < outH) {
        uint2 p = base + uint2(1u, 0u);
        float2 uv = (float2(p) + 0.5f) * outputPt;
        output.write(half4(saturate(acc.y + input.sample(linearSam, uv).rgb), 1.0h), p);
    }
    if (base.x < outW && base.y + 1u < outH) {
        uint2 p = base + uint2(0u, 1u);
        float2 uv = (float2(p) + 0.5f) * outputPt;
        output.write(half4(saturate(acc.z + input.sample(linearSam, uv).rgb), 1.0h), p);
    }
    if (base.x + 1u < outW && base.y + 1u < outH) {
        uint2 p = base + uint2(1u, 1u);
        float2 uv = (float2(p) + 0.5f) * outputPt;
        output.write(half4(saturate(acc.w + input.sample(linearSam, uv).rgb), 1.0h), p);
    }
}
