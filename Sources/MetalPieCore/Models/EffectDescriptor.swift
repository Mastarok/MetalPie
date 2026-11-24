import Foundation

/// High-level grouping for MetalPie's built-in effect catalog.
public enum EffectCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case superResolution
    case mlUpscaler
    case anime
    case pixelArt
    case crt
    case sharpening
    case interpolation
    case downscaling
    case utility

    public var id: String { rawValue }

    public var labelEN: String {
        switch self {
        case .superResolution: return "Super Resolution"
        case .mlUpscaler: return "Apple ML / Hardware"
        case .anime: return "Anime & Neural"
        case .pixelArt: return "Pixel Art"
        case .crt: return "CRT & Retro"
        case .sharpening: return "Sharpening"
        case .interpolation: return "Interpolation"
        case .downscaling: return "Downscaling"
        case .utility: return "Utility & Post-Process"
        }
    }

    public var labelZH: String {
        switch self {
        case .superResolution: return "游戏超分辨率"
        case .mlUpscaler: return "Apple 硬件 / 机器学习"
        case .anime: return "动漫与神经网络"
        case .pixelArt: return "像素艺术"
        case .crt: return "CRT 复古显像管"
        case .sharpening: return "锐化增强"
        case .interpolation: return "经典插值滤波"
        case .downscaling: return "高质量降采样"
        case .utility: return "抗锯齿与色彩实用"
        }
    }
}

/// Stable identifier for every built-in scaling, sharpening, and post-processing effect.
///
/// Existing raw values are strictly preserved for backwards compatibility with saved configs.
public enum EffectID: String, Codable, Sendable, CaseIterable, Identifiable {
    // Original 22 built-in effects (do not rename or remove)
    case metalFXSpatial
    case vtSuperResolution
    case fsr1EASU
    case fsr1RCAS
    case sgsr
    case anime4kRestore
    case anime4kUpscaleDenoise
    case fsrcnnx
    case xbrzFreescale
    case crtGeom
    case crtLottes
    case lanczos6
    case bicubic
    case sharpBilinear
    case pixellate
    case nearest
    case bilinear
    case cas
    case adaptiveSharpen
    case ssimDownscaler
    case deband
    case imageAdjustment

    // Expanded Magpie-grade Anime4K v4.0.1 & flagship shader suite (+8 = 30 total)
    case anime4kUpscale
    case anime4kThin
    case anime4kDarken
    case anime4kDenoiseBilateral
    case anime4kClampHighlights
    case cunny
    case fxaa
    case jinc

    public var id: String { rawValue }
}

/// Describes what output resolutions an effect shader/backend can natively emit.
public enum EffectScaleCapability: Hashable, Codable, Sendable {
    /// Can directly render to any arbitrary output pixel size.
    case arbitrary
    /// Always emits a fixed multiple of input dimensions (e.g. `2.0x` CNN).
    case fixed(factor: Double)
    /// Post-processing pass that always keeps `outputSize == inputSize` (`1.0x`).
    case sameSize
    /// Specialized downscaler (runs at target size when downscaling, otherwise passes through 1x).
    case downscaleOnly
    /// Supports specific discrete scale factors (e.g. VideoToolbox ML SR `[1.5, 2.0, 4.0]`).
    case discreteScales([Double])
}

/// Single option within a `.choice` effect parameter.
public struct EffectParameterChoice: Hashable, Codable, Sendable {
    public var value: String
    public var labelEN: String
    public var labelZH: String

    public init(value: String, labelEN: String, labelZH: String) {
        self.value = value
        self.labelEN = labelEN
        self.labelZH = labelZH
    }

    public var displayNameEN: String { labelEN }
    public var displayNameZH: String { labelZH }
}

/// Typed schema and bounds for a single configurable effect parameter.
public enum EffectParameterKind: Hashable, Codable, Sendable {
    case float(defaultValue: Double, min: Double, max: Double, step: Double)
    case int(defaultValue: Int, min: Int, max: Int, step: Int)
    case bool(defaultValue: Bool)
    case choice(defaultValue: String, options: [EffectParameterChoice])

    public var defaultParameterValue: EffectParameterValue {
        switch self {
        case .float(let v, _, _, _): return .float(v)
        case .int(let v, _, _, _): return .int(v)
        case .bool(let v): return .bool(v)
        case .choice(let v, _): return .choice(v)
        }
    }
}

/// Descriptor for one configurable parameter exposed by an effect.
public struct EffectParameterDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var labelEN: String
    public var labelZH: String
    public var descriptionEN: String
    public var descriptionZH: String
    public var kind: EffectParameterKind

    public init(
        id: String,
        labelEN: String,
        labelZH: String,
        descriptionEN: String = "",
        descriptionZH: String = "",
        kind: EffectParameterKind
    ) {
        self.id = id
        self.labelEN = labelEN
        self.labelZH = labelZH
        self.descriptionEN = descriptionEN
        self.descriptionZH = descriptionZH
        self.kind = kind
    }

    /// Plain-English display label alias.
    public var displayNameEN: String { labelEN }
    /// Plain-Chinese display label alias.
    public var displayNameZH: String { labelZH }
    /// Localized description helper (prefers Chinese when available, falls back to English).
    public var localizedDescription: String {
        descriptionZH.isEmpty ? descriptionEN : descriptionZH
    }
}

/// Runtime value stored for an effect parameter.
public enum EffectParameterValue: Hashable, Codable, Sendable {
    case float(Double)
    case int(Int)
    case bool(Bool)
    case choice(String)

    public var floatValue: Double? {
        switch self {
        case .float(let v): return v
        case .int(let v): return Double(v)
        case .bool, .choice: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .float(let v): return Int(v.rounded())
        case .bool, .choice: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var choiceValue: String? {
        if case .choice(let v) = self { return v }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueTag: String, Codable {
        case float, int, bool, choice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(ValueTag.self, forKey: .type)
        switch tag {
        case .float:
            self = .float(try container.decode(Double.self, forKey: .value))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .value))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .choice:
            self = .choice(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .float(let v):
            try container.encode(ValueTag.float, forKey: .type)
            try container.encode(v, forKey: .value)
        case .int(let v):
            try container.encode(ValueTag.int, forKey: .type)
            try container.encode(v, forKey: .value)
        case .bool(let v):
            try container.encode(ValueTag.bool, forKey: .type)
            try container.encode(v, forKey: .value)
        case .choice(let v):
            try container.encode(ValueTag.choice, forKey: .type)
            try container.encode(v, forKey: .value)
        }
    }
}

/// Strongly-typed parameter map for an `EffectInstance`.
public struct EffectParameters: Hashable, Codable, Sendable, ExpressibleByDictionaryLiteral {
    public var values: [String: EffectParameterValue]

    public init(_ values: [String: EffectParameterValue] = [:]) {
        self.values = values
    }

    public init(dictionaryLiteral elements: (String, EffectParameterValue)...) {
        self.values = Dictionary(uniqueKeysWithValues: elements)
    }

    public subscript(key: String) -> EffectParameterValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var isEmpty: Bool { values.isEmpty }

    public func float(_ key: String, default fallback: Double) -> Double {
        values[key]?.floatValue ?? fallback
    }

    public func float32(_ key: String, default fallback: Float) -> Float {
        Float(float(key, default: Double(fallback)))
    }

    public func int(_ key: String, default fallback: Int) -> Int {
        values[key]?.intValue ?? fallback
    }

    public func bool(_ key: String, default fallback: Bool) -> Bool {
        values[key]?.boolValue ?? fallback
    }

    public func choice(_ key: String, default fallback: String) -> String {
        values[key]?.choiceValue ?? fallback
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        self.values = try single.decode([String: EffectParameterValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        try single.encode(values)
    }
}

/// Static metadata describing a built-in MetalPie effect.
public struct EffectDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: EffectID
    public var nameEN: String
    public var nameZH: String
    public var summaryEN: String
    public var summaryZH: String
    public var category: EffectCategory
    public var scaleCapability: EffectScaleCapability
    public var supportsHDR: Bool
    public var minimumMacOSMajorVersion: Int
    public var parameters: [EffectParameterDescriptor]

    public init(
        id: EffectID,
        nameEN: String,
        nameZH: String,
        summaryEN: String,
        summaryZH: String,
        category: EffectCategory,
        scaleCapability: EffectScaleCapability,
        supportsHDR: Bool = true,
        minimumMacOSMajorVersion: Int = 14,
        parameters: [EffectParameterDescriptor] = []
    ) {
        self.id = id
        self.nameEN = nameEN
        self.nameZH = nameZH
        self.summaryEN = summaryEN
        self.summaryZH = summaryZH
        self.category = category
        self.scaleCapability = scaleCapability
        self.supportsHDR = supportsHDR
        self.minimumMacOSMajorVersion = minimumMacOSMajorVersion
        self.parameters = parameters
    }

    /// Plain-English display name alias.
    public var displayNameEN: String { nameEN }
    /// Plain-Chinese display name alias.
    public var displayNameZH: String { nameZH }
    /// Plain-English 1-sentence description alias.
    public var descriptionEN: String { summaryEN }
    /// Plain-Chinese 1-sentence description alias.
    public var descriptionZH: String { summaryZH }
    /// Default localized description helper.
    public var localizedDescription: String {
        summaryZH.isEmpty ? summaryEN : summaryZH
    }

    /// Parameter map populated with each parameter's default value.
    public var defaultParameters: EffectParameters {
        var map: [String: EffectParameterValue] = [:]
        for param in parameters {
            map[param.id] = param.kind.defaultParameterValue
        }
        return EffectParameters(map)
    }
}

/// Authoritative catalog of all 30 built-in MetalPie effects.
public enum EffectCatalog: Sendable {
    public static let all: [EffectDescriptor] = [
        // MARK: - Apple Hardware / ML
        EffectDescriptor(
            id: .metalFXSpatial,
            nameEN: "MetalFX Spatial",
            nameZH: "MetalFX 硬件超分",
            summaryEN: "Apple Silicon hardware-accelerated spatial upscaler with crisp edges and native HDR support.",
            summaryZH: "Apple 芯片原生硬件加速超分，放大速度快、画面锐利且完整支持 HDR。",
            category: .mlUpscaler,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            minimumMacOSMajorVersion: 14,
            parameters: [
                EffectParameterDescriptor(
                    id: "colorProcessingMode",
                    labelEN: "Color Space Mode",
                    labelZH: "色彩处理模式",
                    descriptionEN: "Choose perceptual (standard SDR), linear light, or HDR tone handling.",
                    descriptionZH: "普通游戏和窗口建议选“感知 (SDR)”，开启高动态范围画面时选“HDR”。",
                    kind: .choice(
                        defaultValue: "perceptual",
                        options: [
                            EffectParameterChoice(value: "perceptual", labelEN: "Perceptual (SDR)", labelZH: "感知色彩 (SDR 推荐)"),
                            EffectParameterChoice(value: "linear", labelEN: "Linear Light", labelZH: "线性光空间"),
                            EffectParameterChoice(value: "hdr", labelEN: "HDR / EDR", labelZH: "高动态范围 (HDR)")
                        ]
                    )
                )
            ]
        ),
        EffectDescriptor(
            id: .vtSuperResolution,
            nameEN: "Apple ML Super Resolution",
            nameZH: "Apple 神经引擎超分",
            summaryEN: "VideoToolbox low-latency Neural Engine super resolution (macOS 26+, discrete 1.5x/2x/4x).",
            summaryZH: "调用苹果神经网络引擎进行低延迟 AI 超分（需 macOS 26+，支持 1.5×/2×/4×）。",
            category: .mlUpscaler,
            scaleCapability: .discreteScales([1.5, 2.0, 4.0]),
            supportsHDR: false,
            minimumMacOSMajorVersion: 26,
            parameters: [
                EffectParameterDescriptor(
                    id: "scaleFactor",
                    labelEN: "ML Scale Factor",
                    labelZH: "AI 放大倍率",
                    descriptionEN: "Discrete Neural Engine scaling factor before final display fit.",
                    descriptionZH: "选择神经网络引擎的原生放大倍数，常规窗口推荐使用 2 倍。",
                    kind: .choice(
                        defaultValue: "2.0",
                        options: [
                            EffectParameterChoice(value: "1.5", labelEN: "1.5×", labelZH: "1.5 倍（轻量）"),
                            EffectParameterChoice(value: "2.0", labelEN: "2.0×", labelZH: "2.0 倍（推荐）"),
                            EffectParameterChoice(value: "4.0", labelEN: "4.0×", labelZH: "4.0 倍（低分辨率源）")
                        ]
                    )
                )
            ]
        ),

        // MARK: - Game Super Resolution
        EffectDescriptor(
            id: .fsr1EASU,
            nameEN: "FSR 1.0 EASU",
            nameZH: "FSR 1.0 边缘自适应超分",
            summaryEN: "AMD FidelityFX 1.0 directional edge-adaptive upscaler that reconstructs clean diagonal edges.",
            summaryZH: "AMD 经典游戏超分算法，能沿物体边缘方向重建清晰轮廓，适合各类 3D/2D 游戏。",
            category: .superResolution,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),
        EffectDescriptor(
            id: .fsr1RCAS,
            nameEN: "FSR 1.0 RCAS",
            nameZH: "FSR 1.0 抗噪锐化 (RCAS)",
            summaryEN: "Noise-aware contrast adaptive sharpening pass typically paired right after FSR EASU.",
            summaryZH: "常搭配 FSR 超分使用的自适应锐化通道，增强纹理清晰度同时自动避开噪点。",
            category: .sharpening,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "锐化强度",
                    descriptionEN: "Controls how strongly local edges and textures are accentuated.",
                    descriptionZH: "数值越高画面越锐利，推荐 0.75–0.90 兼顾清晰度与自然观感。",
                    kind: .float(defaultValue: 0.87, min: 0.0, max: 1.0, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "denoise",
                    labelEN: "Noise Suppression",
                    labelZH: "智能抗噪保护",
                    descriptionEN: "Attenuates sharpening on noisy or grainy regions to avoid amplifying film grain.",
                    descriptionZH: "开启后会自动降低噪点区域的锐化力度，避免把画面颗粒感一并放大。",
                    kind: .bool(defaultValue: true)
                )
            ]
        ),
        EffectDescriptor(
            id: .sgsr,
            nameEN: "SGSR v1",
            nameZH: "SGSR v1 高效游戏超分",
            summaryEN: "Qualcomm Snapdragon Game Super Resolution single-pass edge-directed upscaler for low GPU power.",
            summaryZH: "单通道快速边缘超分算法，GPU 占用极低且省电，非常适合 MacBook 离电高帧率游玩。",
            category: .superResolution,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "edgeSharpness",
                    labelEN: "Edge Sharpness",
                    labelZH: "边缘锐利度",
                    descriptionEN: "Boosts contrast along detected edges during directional reconstruction.",
                    descriptionZH: "控制放大后物体轮廓的清晰程度，数值越大线条越硬朗。",
                    kind: .float(defaultValue: 2.0, min: 0.0, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "edgeThreshold",
                    labelEN: "Edge Detection Threshold",
                    labelZH: "边缘检测门槛",
                    descriptionEN: "Minimum local contrast required to trigger edge-directed filtering instead of fast bilinear.",
                    descriptionZH: "数值越小越敏感（更多细节参与锐化），数值越大则更省电且画面更柔和。",
                    kind: .float(defaultValue: 8.0, min: 0.0, max: 32.0, step: 0.5)
                )
            ]
        ),

        // MARK: - Official Anime4K v4.0.1 Suite + CuNNy + FSRCNNX
        EffectDescriptor(
            id: .anime4kRestore,
            nameEN: "Anime4K Restore (CNN)",
            nameZH: "Anime4K 画质修复",
            summaryEN: "1× CReLU convolutional network that repairs compression blur, ringing, and fuzzy anime line art.",
            summaryZH: "在原分辨率下用神经网络修复动漫模糊与压缩重影，支持标准与柔和档位。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Quality Tier",
                    labelZH: "画质档位",
                    descriptionEN: "Choose Fast (S), Balanced (M), High Quality (L), Ultra (VL), or Soft variants.",
                    descriptionZH: "轻量到超高依次增强修复精度；柔和版更适合画质较好或偏暖画风的番剧。",
                    kind: .choice(
                        defaultValue: "M",
                        options: [
                            EffectParameterChoice(value: "S", labelEN: "Fast (S)", labelZH: "轻量 (S)"),
                            EffectParameterChoice(value: "M", labelEN: "Balanced (M)", labelZH: "标准 (M)"),
                            EffectParameterChoice(value: "L", labelEN: "High Quality (L)", labelZH: "高画质 (L)"),
                            EffectParameterChoice(value: "VL", labelEN: "Ultra (VL)", labelZH: "超高画质 (VL)"),
                            EffectParameterChoice(value: "softM", labelEN: "Soft Balanced (Soft M)", labelZH: "柔和标准 (Soft M)"),
                            EffectParameterChoice(value: "softL", labelEN: "Soft High Quality (Soft L)", labelZH: "柔和高清 (Soft L)")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "clampHighlights",
                    labelEN: "Clamp Highlights",
                    labelZH: "抑制白边",
                    descriptionEN: "Prevents bright haloing and overshoot artifacts along high-contrast anime outlines.",
                    descriptionZH: "防止修复后人物轮廓与暗色黑边周围出现发亮的白色光晕。",
                    kind: .bool(defaultValue: true)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kUpscaleDenoise,
            nameEN: "Anime4K 2× Upscale + Denoise",
            nameZH: "Anime4K 2× 超分降噪",
            summaryEN: "2× Anime4K CNN upscaler trained to simultaneously remove compression noise and sharpen anime lines.",
            summaryZH: "专为动漫番剧与视觉小说设计的 2× 神经网络放大与去噪，一举清理噪点并还原清晰线条。",
            category: .anime,
            scaleCapability: .fixed(factor: 2.0),
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Quality Tier",
                    labelZH: "画质档位",
                    descriptionEN: "Select Fast (S), Balanced (M), High Quality (L), or Ultra (VL) neural network.",
                    descriptionZH: "档位越高线条细节与降噪表现越出色，推荐标准或高画质档位。",
                    kind: .choice(
                        defaultValue: "L",
                        options: [
                            EffectParameterChoice(value: "S", labelEN: "Fast (S)", labelZH: "轻量 (S)"),
                            EffectParameterChoice(value: "M", labelEN: "Balanced (M)", labelZH: "标准 (M)"),
                            EffectParameterChoice(value: "L", labelEN: "High Quality (L)", labelZH: "高画质 (L)"),
                            EffectParameterChoice(value: "VL", labelEN: "Ultra (VL)", labelZH: "超高画质 (VL)")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "clampHighlights",
                    labelEN: "Clamp Highlights",
                    labelZH: "抑制白边",
                    descriptionEN: "Clamps bright overshoot spikes so highlights stay clean without white edge halos.",
                    descriptionZH: "限制放大后的高亮过冲，避免人物发丝和黑边外侧出现发白光晕。",
                    kind: .bool(defaultValue: true)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kUpscale,
            nameEN: "Anime4K 2× Pure Upscale",
            nameZH: "Anime4K 2× 纯净超分",
            summaryEN: "Pure 2× Anime4K CNN upscaler without aggressive denoising — ideal for clean Blu-ray anime and 2D games.",
            summaryZH: "不含强力降噪的纯 2× 神经网络超分，最适合搭配修复模式或用于干净的二次元游戏。",
            category: .anime,
            scaleCapability: .fixed(factor: 2.0),
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Quality Tier",
                    labelZH: "画质档位",
                    descriptionEN: "Choose Fast (S), Balanced (M), High Quality (L), or Ultra (VL) 2× CNN.",
                    descriptionZH: "轻量最快，高画质（L）为清晰度与帧率的黄金平衡，超高（VL）精度最高。",
                    kind: .choice(
                        defaultValue: "L",
                        options: [
                            EffectParameterChoice(value: "S", labelEN: "Fast (S)", labelZH: "轻量 (S)"),
                            EffectParameterChoice(value: "M", labelEN: "Balanced (M)", labelZH: "标准 (M)"),
                            EffectParameterChoice(value: "L", labelEN: "High Quality (L)", labelZH: "高画质 (L)"),
                            EffectParameterChoice(value: "VL", labelEN: "Ultra (VL)", labelZH: "超高画质 (VL)")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "clampHighlights",
                    labelEN: "Clamp Highlights",
                    labelZH: "抑制白边",
                    descriptionEN: "Prevents bright ringing halos around dark ink outlines after 2× upscaling.",
                    descriptionZH: "防止放大后暗色线条边缘冒出白色亮边，保持画面通透自然。",
                    kind: .bool(defaultValue: true)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kThin,
            nameEN: "Anime4K Line Thinning",
            nameZH: "Anime4K 线条细化",
            summaryEN: "Narrows overly thick or bloated low-res anime ink outlines using gradient-guided warping.",
            summaryZH: "自动收细低分辨率动漫中显得臃肿粗重的黑边，让轮廓更加精致纤细。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "strength",
                    labelEN: "Thinning Strength",
                    labelZH: "细化力度",
                    descriptionEN: "Controls how much thick dark lines are narrowed (0.4–0.8 recommended).",
                    descriptionZH: "控制线条收细的幅度，推荐 0.4–0.8，过高可能导致极细线条断裂。",
                    kind: .float(defaultValue: 0.6, min: 0.0, max: 1.5, step: 0.1)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kDarken,
            nameEN: "Anime4K Line Darkening",
            nameZH: "Anime4K 线条加深",
            summaryEN: "Selectively deepens faded anime ink lines to boost 2D contrast and depth without darkening flat fills.",
            summaryZH: "精准加深发灰发淡的二次元黑边，提升画面立体感且不影响人物肤色与背景亮度。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "strength",
                    labelEN: "Darken Strength",
                    labelZH: "加深力度",
                    descriptionEN: "Controls how strongly detected dark outlines are emphasized (0.3–0.7 recommended).",
                    descriptionZH: "数值越高轮廓线条越乌黑醒目，常规番剧推荐 0.3–0.7。",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.5, step: 0.1)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kDenoiseBilateral,
            nameEN: "Anime4K Bilateral Denoise",
            nameZH: "Anime4K 双边保边降噪",
            summaryEN: "Edge-preserving bilateral denoiser with Mode, Mean, and Median filters for flat cel-shaded regions.",
            summaryZH: "抹平动漫色块噪点的同时守住清晰边界，支持众数、均值、中值三种滤镜。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "mode",
                    labelEN: "Filter Mode",
                    labelZH: "降噪模式",
                    descriptionEN: "Mode keeps flat cel edges sharpest; Mean is smoothest; Median excels against speckle noise.",
                    descriptionZH: "众数最保边，均值最柔滑，中值擅长去除椒盐杂点。",
                    kind: .choice(
                        defaultValue: "mode",
                        options: [
                            EffectParameterChoice(value: "mode", labelEN: "Mode (Edge-Preserving)", labelZH: "众数保边 (Mode)"),
                            EffectParameterChoice(value: "mean", labelEN: "Mean (Smooth)", labelZH: "均值平滑 (Mean)"),
                            EffectParameterChoice(value: "median", labelEN: "Median (Despeckle)", labelZH: "中值去杂点 (Median)")
                        ]
                    )
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kClampHighlights,
            nameEN: "Anime4K Clamp Highlights",
            nameZH: "Anime4K 防白边抗振铃",
            summaryEN: "Automatic anti-ringing pass that eliminates bright overshoot halos after neural upscaling.",
            summaryZH: "自动防白边通道，放在超分或锐化之后可有效消除物体边缘刺眼的白色光晕。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: []
        ),
        EffectDescriptor(
            id: .cunny,
            nameEN: "CuNNy 2× Neural",
            nameZH: "CuNNy 2× 轻量神经超分",
            summaryEN: "Magpie's signature compact 2× neural upscaler prized for clean anime, visual novels, and 2D games.",
            summaryZH: "Magpie 标志性的轻量级 2× 神经网络超分，画质干净自然且几乎无涂抹感，极适合 Galgame 与二次元游戏。",
            category: .anime,
            scaleCapability: .fixed(factor: 2.0),
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Model Tier",
                    labelZH: "模型档位",
                    descriptionEN: "Fast (veryfast 8ch), Balanced (fast 12ch), or High Quality (full RGB 3×12 neural network).",
                    descriptionZH: "快速版极省电，均衡版兼顾锐利与速度，高质量版采用全 RGB 三通道神经网络还原色彩细节。",
                    kind: .choice(
                        defaultValue: "balanced",
                        options: [
                            EffectParameterChoice(value: "fast", labelEN: "Fast (VeryFast 8ch)", labelZH: "快速 (轻量 8 通道)"),
                            EffectParameterChoice(value: "balanced", labelEN: "Balanced (Fast 12ch)", labelZH: "均衡 (推荐 12 通道)"),
                            EffectParameterChoice(value: "highQuality", labelEN: "High Quality (RGB 3×12)", labelZH: "高质量 (全彩 RGB 3×12)")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Detail Sharpness",
                    labelZH: "细节锐度",
                    descriptionEN: "Scales the neural high-frequency detail residual added during 2× reconstruction.",
                    descriptionZH: "调节神经网络重建细节的强弱，1.0 为标准值，调高可让线条与文字更醒目。",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 2.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .fsrcnnx,
            nameEN: "FSRCNNX 2× Neural",
            nameZH: "FSRCNNX 2× 神经网络超分",
            summaryEN: "6-pass 2× convolutional neural network upscaler with dedicated Standard, LineArt, and Enhanced Detail modes.",
            summaryZH: "经典 6 通道 2× 卷积神经网络超分，提供通用、二次元线条与细节强化三种模式。",
            category: .anime,
            scaleCapability: .fixed(factor: 2.0),
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Model Variant",
                    labelZH: "模型风格",
                    descriptionEN: "Standard for general video/games, LineArt for crisp 2D outlines, Enhanced Detail for extra micro-contrast.",
                    descriptionZH: "标准版适合影视与综合游戏，线条版专攻动漫与手绘，细节强化版进一步突出微弱纹理。",
                    kind: .choice(
                        defaultValue: "standard",
                        options: [
                            EffectParameterChoice(value: "standard", labelEN: "Standard 8-0-4-1", labelZH: "标准版 (8-0-4-1)"),
                            EffectParameterChoice(value: "lineArt", labelEN: "LineArt 8-0-4-1", labelZH: "二次元线条版 (8-0-4-1)"),
                            EffectParameterChoice(value: "enhancedDetail", labelEN: "Enhanced Detail", labelZH: "细节强化版")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "细节锐度",
                    descriptionEN: "Scales the reconstructed high-frequency luminance detail relative to smooth upsampling.",
                    descriptionZH: "控制放大后的高频细节增益，1.0 为模型原生输出，可按观感微调。",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 1.5, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "antiRinging",
                    labelEN: "Anti-Ringing",
                    labelZH: "抑制边缘白边",
                    descriptionEN: "Clamps neural overshoot toward local source bounds to keep high-contrast edges clean.",
                    descriptionZH: "抑制神经网络在文字与黑边旁产生的白边光晕，推荐 0.25–0.50。",
                    kind: .float(defaultValue: 0.35, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),

        // MARK: - Pixel Art
        EffectDescriptor(
            id: .xbrzFreescale,
            nameEN: "xBRZ Freescale",
            nameZH: "xBRZ 矢量像素平滑",
            summaryEN: "Two-pass perceptual pixel-art vectorizing upscaler that turns jagged sprites into smooth curves at any ratio.",
            summaryZH: "双通道感知像素画矢量平滑算法，可将复古像素锯齿自动圆滑成清晰曲线，支持任意倍率。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "equalColorTolerance",
                    labelEN: "Equal Color Tolerance",
                    labelZH: "相似色合并容差",
                    descriptionEN: "Perceptual YCbCr distance below which neighboring pixels are treated as the same region.",
                    descriptionZH: "决定多接近的颜色被视为同一色块，调大更容易平滑渐变像素，默认 30。",
                    kind: .float(defaultValue: 30.0, min: 5.0, max: 60.0, step: 1.0)
                ),
                EffectParameterDescriptor(
                    id: "edgeThreshold",
                    labelEN: "Steep Edge Threshold",
                    labelZH: "斜边平滑阈值",
                    descriptionEN: "Ratio threshold controlling when shallow/steep 2:1 pixel slopes are interpolated smoothly.",
                    descriptionZH: "控制 2:1 斜线锯齿触发平滑的灵敏度，数值越小斜边越圆润（默认 2.2）。",
                    kind: .float(defaultValue: 2.2, min: 1.2, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "dominantDirectionThreshold",
                    labelEN: "Dominant Direction Threshold",
                    labelZH: "主导边缘判定阈值",
                    descriptionEN: "Controls how strongly one diagonal direction must dominate to force full corner blending.",
                    descriptionZH: "决定强斜边覆盖拐角的门槛，数值越低曲线更连贯，越高越忠于原像素方格（默认 3.6）。",
                    kind: .float(defaultValue: 3.6, min: 1.5, max: 6.0, step: 0.1)
                )
            ]
        ),
        EffectDescriptor(
            id: .sharpBilinear,
            nameEN: "Sharp Bilinear",
            nameZH: "锐利双线性（像素防闪烁）",
            summaryEN: "Keeps pixel-art interiors crisp while smoothly blending only 1-pixel boundaries at non-integer ratios.",
            summaryZH: "在非整数倍率全屏游玩像素游戏时，既保留方正像素颗粒又消除画面移动时的波纹闪烁。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Edge Crispness",
                    labelZH: "像素边缘锐度",
                    descriptionEN: "Blends between soft bilinear (0.0) and razor-sharp single-pixel transitions (1.0).",
                    descriptionZH: "1.0 呈现最锐利的像素方格，略微调低（0.6–0.8）可让边缘更柔和。",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .pixellate,
            nameEN: "Pixellate",
            nameZH: "面积积分像素缩放",
            summaryEN: "Analytical texel-area box integration eliminating shimmer on non-integer pixel-art scaling.",
            summaryZH: "通过精确计算像素覆盖面积进行缩放，任意屏幕比例下均零闪烁、像素大小均匀一致。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),
        EffectDescriptor(
            id: .nearest,
            nameEN: "Nearest Neighbor",
            nameZH: "点采样（整数倍原味像素）",
            summaryEN: "Zero-blur point sampling ideal for exact integer scaling of retro pixel games.",
            summaryZH: "完全无模糊的原始像素点采样，搭配“整数倍适应”还原刀削般锐利的复古像素点。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),

        // MARK: - Retro CRT
        EffectDescriptor(
            id: .crtGeom,
            nameEN: "CRT-Geom",
            nameZH: "CRT-Geom 经典球面显像管",
            summaryEN: "Authentic curved CRT simulation with beam scanlines, selectable phosphor masks, halation, vignette, and gamma.",
            summaryZH: "高度还原经典彩电与监视器 CRT 观感，可自由调节曲率、扫描线、荧光掩膜、辉光与暗角。",
            category: .crt,
            scaleCapability: .arbitrary,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "curvature",
                    labelEN: "Screen Curvature",
                    labelZH: "启用球面曲率",
                    descriptionEN: "Simulates the curved glass face of a vintage CRT television tube.",
                    descriptionZH: "模拟老式球面显像管的玻璃弧度与圆角边框，关闭则为平面 CRT。",
                    kind: .bool(defaultValue: false)
                ),
                EffectParameterDescriptor(
                    id: "curvatureRadius",
                    labelEN: "Curvature Radius",
                    labelZH: "曲率半径",
                    descriptionEN: "Smaller values produce stronger glass curvature when Screen Curvature is enabled.",
                    descriptionZH: "开启球面曲率时生效，数值越小屏幕鼓起弯曲越明显，默认 2.0。",
                    kind: .float(defaultValue: 2.0, min: 0.8, max: 5.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "scanlineWeight",
                    labelEN: "Scanline Weight",
                    labelZH: "扫描线粗细",
                    descriptionEN: "Controls the vertical beam width and darkness of horizontal CRT scanlines.",
                    descriptionZH: "数值越小扫描线黑缝越明显、复古感越强，数值越大扫描线越柔和饱满。",
                    kind: .float(defaultValue: 0.3, min: 0.1, max: 0.6, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "maskType",
                    labelEN: "Phosphor Mask Type",
                    labelZH: "荧光粉掩膜样式",
                    descriptionEN: "Choose Trinitron Aperture Grille, classic Shadow Mask, arcade Slot Mask, or Off.",
                    descriptionZH: "模拟不同显像管亚像素排列：特丽珑条纹光栅、经典圆点阴影掩膜或街机槽栅。",
                    kind: .choice(
                        defaultValue: "apertureGrille",
                        options: [
                            EffectParameterChoice(value: "apertureGrille", labelEN: "Aperture Grille", labelZH: "条纹光栅 (特丽珑)"),
                            EffectParameterChoice(value: "shadowMask", labelEN: "Shadow Mask", labelZH: "阴影点阵 (彩电)"),
                            EffectParameterChoice(value: "slotMask", labelEN: "Slot Mask", labelZH: "槽形掩膜 (街机)"),
                            EffectParameterChoice(value: "off", labelEN: "Off", labelZH: "关闭掩膜")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "dotMask",
                    labelEN: "Phosphor Mask Strength",
                    labelZH: "掩膜纹理强度",
                    descriptionEN: "Controls how visible the RGB phosphor subpixel mask pattern appears.",
                    descriptionZH: "调节荧光粉网格的明显程度，0 为完全关闭，推荐 0.25–0.45。",
                    kind: .float(defaultValue: 0.3, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "halation",
                    labelEN: "Phosphor Halation / Glow",
                    labelZH: "荧光辉光",
                    descriptionEN: "Adds soft luminous phosphor bloom around bright pixels and scanlines.",
                    descriptionZH: "为高亮像素增添柔和的显像管荧光光晕，提升暗场氛围与通透度。",
                    kind: .float(defaultValue: 0.15, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "vignette",
                    labelEN: "Tube Vignette",
                    labelZH: "显像管暗角",
                    descriptionEN: "Subtle brightness falloff toward the four corners of the CRT glass.",
                    descriptionZH: "模拟显像管四角轻微变暗的光学暗角，0 为关闭。",
                    kind: .float(defaultValue: 0.15, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "brightness",
                    labelEN: "Brightness Boost",
                    labelZH: "亮度补偿",
                    descriptionEN: "Compensates for brightness lost to dark scanlines and phosphor masks.",
                    descriptionZH: "补偿扫描线和掩膜带来的画面变暗，让色彩在现代屏幕上依旧鲜艳。",
                    kind: .float(defaultValue: 1.05, min: 0.5, max: 1.5, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "crtGamma",
                    labelEN: "CRT Gamma",
                    labelZH: "模拟 CRT 伽马",
                    descriptionEN: "Input gamma curve of the simulated CRT tube (higher = deeper contrast).",
                    descriptionZH: "模拟老式显像管的对比度曲线，数值越高暗部越深邃（推荐 1.8–2.4）。",
                    kind: .float(defaultValue: 2.4, min: 1.0, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "monitorGamma",
                    labelEN: "Monitor Gamma",
                    labelZH: "当前屏幕伽马",
                    descriptionEN: "Output gamma calibration matching your Mac display (2.2 standard).",
                    descriptionZH: "匹配现代 Mac 显示器的输出伽马，一般保持 2.2 即可。",
                    kind: .float(defaultValue: 2.2, min: 1.0, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "cornerSize",
                    labelEN: "Corner Radius",
                    labelZH: "边角圆弧大小",
                    descriptionEN: "Rounds the four outer corners of the simulated CRT bezel.",
                    descriptionZH: "控制屏幕四角的黑色圆角大小，调小至 0.005 可获得近似直角画面。",
                    kind: .float(defaultValue: 0.01, min: 0.001, max: 0.1, step: 0.005)
                )
            ]
        ),
        EffectDescriptor(
            id: .crtLottes,
            nameEN: "CRT-Lottes",
            nameZH: "CRT-Lottes 街机显像管",
            summaryEN: "Timothy Lottes' high-contrast arcade CRT shader with fine Gaussian scanlines, bloom, and 4 shadow masks.",
            summaryZH: "著名街机 CRT 着色器，拥有清晰锐利的高斯扫描线、街机光束辉光与多种阴影掩膜。",
            category: .crt,
            scaleCapability: .arbitrary,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "hardScan",
                    labelEN: "Scanline Hardness",
                    labelZH: "扫描线锐度",
                    descriptionEN: "More negative values create sharper, higher-contrast scanline gaps (-8 balanced, -12 crisp).",
                    descriptionZH: "数值越负扫描线黑缝越清晰锋利，-8 为标准街机，-12 适合高对比复古感。",
                    kind: .float(defaultValue: -8.0, min: -16.0, max: -2.0, step: 0.5)
                ),
                EffectParameterDescriptor(
                    id: "hardPix",
                    labelEN: "Pixel Hardness",
                    labelZH: "水平像素锐度",
                    descriptionEN: "Controls horizontal pixel focus (-2 soft composite, -3 balanced RGB, -5 crisp).",
                    descriptionZH: "控制水平方向像素清晰度，-2 偏柔和电视感，-3 平衡，-5 接近高清单色监视器。",
                    kind: .float(defaultValue: -3.0, min: -6.0, max: -1.0, step: 0.25)
                ),
                EffectParameterDescriptor(
                    id: "warpX",
                    labelEN: "Horizontal Warp",
                    labelZH: "水平屏幕弯曲",
                    descriptionEN: "Horizontal barrel curvature (0.0 = flat, 0.03 = classic arcade).",
                    descriptionZH: "画面左右边缘的显像管弧度弯曲，0 为平面，0.03 为经典街机曲率。",
                    kind: .float(defaultValue: 0.0, min: 0.0, max: 0.125, step: 0.005)
                ),
                EffectParameterDescriptor(
                    id: "warpY",
                    labelEN: "Vertical Warp",
                    labelZH: "垂直屏幕弯曲",
                    descriptionEN: "Vertical barrel curvature (0.0 = flat, 0.04 = classic arcade).",
                    descriptionZH: "画面上下边缘的显像管弧度弯曲，0 为平面，0.04 为经典街机曲率。",
                    kind: .float(defaultValue: 0.0, min: 0.0, max: 0.125, step: 0.005)
                ),
                EffectParameterDescriptor(
                    id: "shadowMask",
                    labelEN: "Shadow Mask Style",
                    labelZH: "阴影掩膜类型",
                    descriptionEN: "Selects the CRT phosphor grid layout overlaid on the scanlines.",
                    descriptionZH: "选择不同年代显像管的荧光粉像素排列风格。",
                    kind: .choice(
                        defaultValue: "apertureGrille",
                        options: [
                            EffectParameterChoice(value: "none", labelEN: "None", labelZH: "关闭"),
                            EffectParameterChoice(value: "compressedTV", labelEN: "Compressed TV", labelZH: "经典彩电点阵"),
                            EffectParameterChoice(value: "apertureGrille", labelEN: "Aperture Grille", labelZH: "特丽珑光栅条纹"),
                            EffectParameterChoice(value: "stretchedVGA", labelEN: "Stretched VGA", labelZH: "宽距 VGA 掩膜"),
                            EffectParameterChoice(value: "vga", labelEN: "VGA Fine", labelZH: "精细 VGA 显示器")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "brightBoost",
                    labelEN: "Brightness Boost",
                    labelZH: "画面亮度增益",
                    descriptionEN: "Linear brightness multiplier compensating for scanline and mask attenuation.",
                    descriptionZH: "补偿扫描线与掩膜造成的亮度衰减，推荐 1.0–1.25。",
                    kind: .float(defaultValue: 1.0, min: 0.5, max: 2.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "maskDark",
                    labelEN: "Mask Dark Level",
                    labelZH: "掩膜暗部深度",
                    descriptionEN: "Minimum brightness of darkened subpixels in the shadow mask.",
                    descriptionZH: "数值越低掩膜网格对比越强烈，调高则掩膜更柔和。",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "maskLight",
                    labelEN: "Mask Light Level",
                    labelZH: "掩膜亮部增益",
                    descriptionEN: "Peak brightness of illuminated RGB phosphor stripes.",
                    descriptionZH: "提升发光荧光条的亮度，与“掩膜暗部”配合平衡整体明暗。",
                    kind: .float(defaultValue: 1.5, min: 1.0, max: 2.0, step: 0.05)
                )
            ]
        ),

        // MARK: - Classic Interpolation
        EffectDescriptor(
            id: .lanczos6,
            nameEN: "Lanczos6 (Anti-Ringing)",
            nameZH: "Lanczos6 抗振铃滤波",
            summaryEN: "6-tap separable Lanczos3 scaler with anti-ringing clamp and adjustable sharpness for crisp UI and text.",
            summaryZH: "经典 6 点可分离 Lanczos 缩放算法，文字与界面边缘清晰自然且自带防白边抑制。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "antiRinging",
                    labelEN: "Anti-Ringing",
                    labelZH: "抑制边缘白边",
                    descriptionEN: "Suppresses ringing halos around high-contrast text and dark borders.",
                    descriptionZH: "防止缩放后文字和物体边缘出现发亮光晕，推荐 0.5–0.8。",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Filter Sharpness",
                    labelZH: "滤波锐利度",
                    descriptionEN: "Tightens or relaxes the Lanczos lobe response (1.0 = exact Lanczos3).",
                    descriptionZH: "1.0 为标准 Lanczos3，调高画面更紧凑锐利，调低更柔和顺滑。",
                    kind: .float(defaultValue: 1.0, min: 0.5, max: 1.5, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .jinc,
            nameEN: "Jinc (EWA Lanczos)",
            nameZH: "Jinc 圆形高精滤波",
            summaryEN: "2D elliptical circular Jinc2 filter that avoids horizontal/vertical staircase artifacts on diagonals and video.",
            summaryZH: "采用 2D 圆形对称卷积核的经典高质量缩放，斜线与高清视频过渡比常规算法更圆润无锯齿。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "windowSinc",
                    labelEN: "Window Sinc (A)",
                    labelZH: "窗口柔和度 (A)",
                    descriptionEN: "Controls the Jinc window rolloff: lower values sharpen, higher values soften (0.50 optimal).",
                    descriptionZH: "控制滤波器柔和程度：数值越小画面越锐利，越大越柔和（0.50 为经典最优值）。",
                    kind: .float(defaultValue: 0.5, min: 0.1, max: 1.0, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "sinc",
                    labelEN: "Sinc Frequency (B)",
                    labelZH: "细节采样系数 (B)",
                    descriptionEN: "0.825 suppresses dithering cleanly; values near 1.0 increase fine sharpness like Lanczos.",
                    descriptionZH: "0.825 可兼顾细节与去抖动，调近 1.0 可获得接近 Lanczos 的高锐度。",
                    kind: .float(defaultValue: 0.825, min: 0.5, max: 1.0, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "antiRinging",
                    labelEN: "Anti-Ringing",
                    labelZH: "抑制边缘白边",
                    descriptionEN: "Clamps overshoot halos to local 2×2 source bounds while preserving diagonal smoothness.",
                    descriptionZH: "消除高对比度边缘的过冲白边，同时保留圆形滤波的自然斜线过渡。",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .bicubic,
            nameEN: "Bicubic (Mitchell / Catmull-Rom)",
            nameZH: "双三次插值 (Bicubic)",
            summaryEN: "Hardware-optimized 9-tap Mitchell-Netravali cubic filter (Catmull-Rom B=0, C=0.5 default).",
            summaryZH: "高效 9 点硬件优化双三次缩放，可通过 B/C 系数在平滑与锐利之间自由切换。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "b",
                    labelEN: "Smoothness (B)",
                    labelZH: "平滑系数 (B)",
                    descriptionEN: "Higher B yields softer smoothing (Catmull-Rom = 0.0, Mitchell = 0.33, B-Spline = 1.0).",
                    descriptionZH: "数值越大画面越柔和（Catmull-Rom 为 0，Mitchell 均衡为 0.33）。",
                    kind: .float(defaultValue: 0.0, min: 0.0, max: 1.0, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "c",
                    labelEN: "Crispness (C)",
                    labelZH: "锐度系数 (C)",
                    descriptionEN: "Higher C increases edge crispness (Catmull-Rom = 0.50, Mitchell = 0.33, Sharp = 0.75).",
                    descriptionZH: "数值越大边缘越清晰（Catmull-Rom 为 0.50，过高可能产生轻微白边）。",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.01)
                )
            ]
        ),
        EffectDescriptor(
            id: .bilinear,
            nameEN: "Bilinear",
            nameZH: "双线性快速插值",
            summaryEN: "Ultra-lightweight hardware bilinear resampling with virtually zero GPU overhead.",
            summaryZH: "开销几乎为零的基础双线性平滑缩放，适合极低功耗或调试对比。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),

        // MARK: - Sharpening
        EffectDescriptor(
            id: .cas,
            nameEN: "CAS (Contrast Adaptive Sharpen)",
            nameZH: "CAS 对比度自适应锐化",
            summaryEN: "AMD FidelityFX Contrast Adaptive Sharpening restoring crisp detail without edge halos.",
            summaryZH: "AMD 对比度自适应锐化，可放在任意超分之后温和提清细节，不易产生刺眼白边。",
            category: .sharpening,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "锐化强度",
                    descriptionEN: "Controls local contrast sharpening intensity (0.3–0.6 recommended).",
                    descriptionZH: "数值越高纹理越清晰，常规视频和游戏推荐 0.3–0.6。",
                    kind: .float(defaultValue: 0.4, min: 0.0, max: 1.0, step: 0.02)
                )
            ]
        ),
        EffectDescriptor(
            id: .adaptiveSharpen,
            nameEN: "Adaptive Sharpen",
            nameZH: "自适应曲面锐化",
            summaryEN: "Two-pass edge-aware curve sharpening that boosts subtle textures while protecting crisp contours.",
            summaryZH: "双通道智能曲线锐化，重点提升暗部和柔和区域的微弱纹理，同时保护已有清晰边缘不过锐。",
            category: .sharpening,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "curveHeight",
                    labelEN: "Sharpen Strength",
                    labelZH: "锐化力度",
                    descriptionEN: "Height of the adaptive sharpening curve (0.2–0.6 natural, >1.0 strong).",
                    descriptionZH: "决定细节拉升幅度，0.2–0.5 最自然，调高可获得更强烈的锐化观感。",
                    kind: .float(defaultValue: 0.3, min: 0.05, max: 2.0, step: 0.05)
                )
            ]
        ),

        // MARK: - Downscaling
        EffectDescriptor(
            id: .ssimDownscaler,
            nameEN: "SSimDownscaler",
            nameZH: "SSIM 感知高精降采样",
            summaryEN: "5-pass structural-similarity downscaler that keeps 2× supersampled edges razor sharp when scaling down.",
            summaryZH: "5 通道结构相似度降采样，搭配 2× 神经网络超分缩小到目标屏幕时能完美保留清晰纹理。",
            category: .downscaling,
            scaleCapability: .downscaleOnly,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "oversharp",
                    labelEN: "Detail Preservation",
                    labelZH: "细节保留力度",
                    descriptionEN: "Structural contrast gain during downscaling (1.0 accurate, >1.0 extra crisp).",
                    descriptionZH: "1.0 为精准还原原图结构对比度，适当调高可让缩小后的画面更锐利。",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 3.0, step: 0.1)
                )
            ]
        ),

        // MARK: - Utility, Anti-Aliasing & Color
        EffectDescriptor(
            id: .fxaa,
            nameEN: "FXAA 3.11 Anti-Aliasing",
            nameZH: "FXAA 3.11 边缘抗锯齿",
            summaryEN: "Fast approximate anti-aliasing pre-pass that smooths jagged 3D/2D edges before upscaling.",
            summaryZH: "经典快速抗锯齿滤镜，放在超分前可预先消除老游戏与低分辨率画面的阶梯状锯齿。",
            category: .utility,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "qualityPreset",
                    labelEN: "Quality Preset",
                    labelZH: "抗锯齿精度",
                    descriptionEN: "Higher presets trace longer diagonal edges (Low=8, Medium=16, High=24, Ultra=32 steps).",
                    descriptionZH: "档位越高对长斜线锯齿的追踪修复越彻底，推荐“高”或“极致”。",
                    kind: .choice(
                        defaultValue: "high",
                        options: [
                            EffectParameterChoice(value: "low", labelEN: "Low (Fast)", labelZH: "低 (8 步 · 极速)"),
                            EffectParameterChoice(value: "medium", labelEN: "Medium", labelZH: "中 (16 步 · 均衡)"),
                            EffectParameterChoice(value: "high", labelEN: "High (Recommended)", labelZH: "高 (24 步 · 推荐)"),
                            EffectParameterChoice(value: "ultra", labelEN: "Ultra", labelZH: "极致 (32 步 · 精细)")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "edgeThreshold",
                    labelEN: "Edge Threshold",
                    labelZH: "锯齿检测阈值",
                    descriptionEN: "Minimum local contrast needed to trigger AA (lower smooths more subtle edges).",
                    descriptionZH: "数值越小越容易触发抗锯齿（处理更多微弱边缘），推荐 0.125。",
                    kind: .float(defaultValue: 0.125, min: 0.06, max: 0.33, step: 0.005)
                ),
                EffectParameterDescriptor(
                    id: "subpixelQuality",
                    labelEN: "Subpixel Smoothing",
                    labelZH: "亚像素平滑度",
                    descriptionEN: "Controls how much subpixel aliasing is softened (lower keeps fine text/wires sharper).",
                    descriptionZH: "数值越高抗锯齿越柔和，调低可更好地保留细小文字与铁丝网等高频细节。",
                    kind: .float(defaultValue: 0.75, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .deband,
            nameEN: "Deband",
            nameZH: "去色带断层 (Deband)",
            summaryEN: "Smooths 8-bit color banding in dark skies and compressed video using stochastic dithering.",
            summaryZH: "消除暗部夜景、天空渐变与低码率视频中的一层层色块断层，让色彩过渡如丝般顺滑。",
            category: .utility,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "threshold",
                    labelEN: "Smooth Threshold",
                    labelZH: "去色带阈值",
                    descriptionEN: "Maximum color difference smoothed as banding; higher values remove stronger bands.",
                    descriptionZH: "数值越大可抚平越明显的色带断层，过高可能轻微模糊暗部细微纹理。",
                    kind: .float(defaultValue: 0.015, min: 0.001, max: 0.1, step: 0.002)
                ),
                EffectParameterDescriptor(
                    id: "range",
                    labelEN: "Sample Radius",
                    labelZH: "采样搜索范围",
                    descriptionEN: "Pixel radius searched when blending banded gradients.",
                    descriptionZH: "搜寻相似颜色的像素范围，宽色带视频可适当调大至 16–24。",
                    kind: .float(defaultValue: 16.0, min: 4.0, max: 32.0, step: 1.0)
                ),
                EffectParameterDescriptor(
                    id: "grain",
                    labelEN: "Dither Grain",
                    labelZH: "微粒抖动掩蔽",
                    descriptionEN: "Adds subtle micro-dither to prevent 8-bit quantization from reintroducing bands.",
                    descriptionZH: "加入肉眼几乎不可察觉的微弱抖动颗粒，防止输出回 8-bit 时色带再次出现。",
                    kind: .float(defaultValue: 0.006, min: 0.0, max: 0.05, step: 0.002)
                )
            ]
        ),
        EffectDescriptor(
            id: .imageAdjustment,
            nameEN: "Image Adjustment",
            nameZH: "色彩与画面调节",
            summaryEN: "Fine-tune gamma, brightness, contrast, saturation, vibrance, and color temperature at the end of a chain.",
            summaryZH: "在管线末端微调伽马、亮度、对比度、饱和度、自然鲜艳度与冷暖色温。",
            category: .utility,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "gamma",
                    labelEN: "Gamma",
                    labelZH: "伽马明暗曲线",
                    descriptionEN: "Adjusts midtone brightness curve (1.0 = neutral, >1.0 brightens shadows).",
                    descriptionZH: "调节画面中间调明暗，大于 1.0 可提亮发暗的老游戏场景。",
                    kind: .float(defaultValue: 1.0, min: 0.5, max: 2.5, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "brightness",
                    labelEN: "Brightness",
                    labelZH: "整体亮度",
                    descriptionEN: "Uniform brightness offset applied to the full image.",
                    descriptionZH: "整体提亮或压暗画面，0.0 为原始亮度。",
                    kind: .float(defaultValue: 0.0, min: -0.5, max: 0.5, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "contrast",
                    labelEN: "Contrast",
                    labelZH: "画面对比度",
                    descriptionEN: "Expands or compresses separation between darks and highlights.",
                    descriptionZH: "拉开明暗层次对比，略微调高（1.05–1.15）可让泛白画面更有通透感。",
                    kind: .float(defaultValue: 1.0, min: 0.5, max: 2.0, step: 0.02)
                ),
                EffectParameterDescriptor(
                    id: "saturation",
                    labelEN: "Saturation",
                    labelZH: "色彩饱和度",
                    descriptionEN: "Uniformly boosts or mutes color intensity across all channels.",
                    descriptionZH: "全局增强或减弱色彩浓淡，1.0 为原色，0.0 为黑白画面。",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 2.0, step: 0.02)
                ),
                EffectParameterDescriptor(
                    id: "vibrance",
                    labelEN: "Smart Vibrance",
                    labelZH: "自然鲜艳度",
                    descriptionEN: "Boosts muted colors while protecting already-saturated tones and skin hues.",
                    descriptionZH: "优先提亮偏灰淡的颜色而不让高饱和区域过曝，比直接拉饱和度更自然。",
                    kind: .float(defaultValue: 0.0, min: -0.5, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "temperature",
                    labelEN: "Color Temperature",
                    labelZH: "画面冷暖色温",
                    descriptionEN: "Shifts image warmth (negative = cooler blue, positive = warmer amber).",
                    descriptionZH: "负值偏向清冷通透，正值偏向暖黄护眼，0.0 保持原始白平衡。",
                    kind: .float(defaultValue: 0.0, min: -1.0, max: 1.0, step: 0.05)
                )
            ]
        )
    ]

    private static let lookup: [EffectID: EffectDescriptor] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    public static func descriptor(for id: EffectID) -> EffectDescriptor {
        guard let desc = lookup[id] else {
            preconditionFailure("Missing EffectDescriptor for \(id.rawValue)")
        }
        return desc
    }

    public static func effects(in category: EffectCategory) -> [EffectDescriptor] {
        all.filter { $0.category == category }
    }
}
