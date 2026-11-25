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
        case .mlUpscaler: return "Apple Hardware / ML"
        case .anime: return "Anime & Neural"
        case .pixelArt: return "Pixel Art"
        case .crt: return "CRT"
        case .sharpening: return "Sharpening"
        case .interpolation: return "Interpolation"
        case .downscaling: return "Downscaling"
        case .utility: return "Post-Process"
        }
    }

    public var labelZH: String {
        switch self {
        case .superResolution: return "超分辨率"
        case .mlUpscaler: return "Apple 硬件 / ML"
        case .anime: return "动漫 / 神经网络"
        case .pixelArt: return "像素"
        case .crt: return "CRT"
        case .sharpening: return "锐化"
        case .interpolation: return "插值滤波"
        case .downscaling: return "降采样"
        case .utility: return "后处理"
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
            nameZH: "MetalFX Spatial",
            summaryEN: "Apple Silicon hardware spatial upscaler with HDR support.",
            summaryZH: "Apple 硬件空间超分，支持 HDR。",
            category: .mlUpscaler,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            minimumMacOSMajorVersion: 14,
            parameters: [
                EffectParameterDescriptor(
                    id: "colorProcessingMode",
                    labelEN: "Color Mode",
                    labelZH: "色彩模式",
                    descriptionEN: "Perceptual for SDR, linear light, or HDR tone handling.",
                    descriptionZH: "SDR 使用感知色彩，HDR 画面切换至 HDR。",
                    kind: .choice(
                        defaultValue: "perceptual",
                        options: [
                            EffectParameterChoice(value: "perceptual", labelEN: "Perceptual (SDR)", labelZH: "感知 (SDR)"),
                            EffectParameterChoice(value: "linear", labelEN: "Linear", labelZH: "线性"),
                            EffectParameterChoice(value: "hdr", labelEN: "HDR", labelZH: "HDR")
                        ]
                    )
                )
            ]
        ),
        EffectDescriptor(
            id: .vtSuperResolution,
            nameEN: "Apple ML Super Resolution",
            nameZH: "Apple ML 超分",
            summaryEN: "VideoToolbox Neural Engine super resolution (macOS 26+).",
            summaryZH: "VideoToolbox 神经网络引擎超分（需 macOS 26+）。",
            category: .mlUpscaler,
            scaleCapability: .discreteScales([1.5, 2.0, 4.0]),
            supportsHDR: false,
            minimumMacOSMajorVersion: 26,
            parameters: [
                EffectParameterDescriptor(
                    id: "scaleFactor",
                    labelEN: "Scale Factor",
                    labelZH: "倍率",
                    descriptionEN: "Neural Engine native scale factor before display fit.",
                    descriptionZH: "神经网络引擎原生放大倍率。",
                    kind: .choice(
                        defaultValue: "2.0",
                        options: [
                            EffectParameterChoice(value: "1.5", labelEN: "1.5×", labelZH: "1.5×"),
                            EffectParameterChoice(value: "2.0", labelEN: "2×", labelZH: "2×"),
                            EffectParameterChoice(value: "4.0", labelEN: "4×", labelZH: "4×")
                        ]
                    )
                )
            ]
        ),

        // MARK: - Game Super Resolution
        EffectDescriptor(
            id: .fsr1EASU,
            nameEN: "FSR 1.0 EASU",
            nameZH: "FSR 1.0 EASU",
            summaryEN: "AMD FidelityFX 1.0 edge-adaptive spatial upscaler.",
            summaryZH: "AMD FidelityFX 1.0 边缘自适应超分。",
            category: .superResolution,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),
        EffectDescriptor(
            id: .fsr1RCAS,
            nameEN: "FSR 1.0 RCAS",
            nameZH: "FSR 1.0 RCAS",
            summaryEN: "Noise-aware contrast-adaptive sharpening pass.",
            summaryZH: "抗噪对比度自适应锐化。",
            category: .sharpening,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "锐化",
                    descriptionEN: "Local edge and texture sharpening intensity.",
                    descriptionZH: "边缘与纹理锐化强度。",
                    kind: .float(defaultValue: 0.87, min: 0.0, max: 1.0, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "denoise",
                    labelEN: "Denoise",
                    labelZH: "降噪保护",
                    descriptionEN: "Attenuates sharpening on noisy regions.",
                    descriptionZH: "降低噪点区域的锐化强度。",
                    kind: .bool(defaultValue: true)
                )
            ]
        ),
        EffectDescriptor(
            id: .sgsr,
            nameEN: "SGSR",
            nameZH: "SGSR",
            summaryEN: "Single-pass edge-directed upscaler with low GPU overhead.",
            summaryZH: "单通道边缘定向超分，GPU 占用低。",
            category: .superResolution,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "edgeSharpness",
                    labelEN: "Edge Sharpness",
                    labelZH: "边缘锐度",
                    descriptionEN: "Contrast boost along reconstructed edges.",
                    descriptionZH: "重建边缘的对比度增益。",
                    kind: .float(defaultValue: 2.0, min: 0.0, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "edgeThreshold",
                    labelEN: "Edge Threshold",
                    labelZH: "边缘阈值",
                    descriptionEN: "Minimum local contrast required for edge-directed filtering.",
                    descriptionZH: "触发边缘滤波的最小对比度阈值。",
                    kind: .float(defaultValue: 8.0, min: 0.0, max: 32.0, step: 0.5)
                )
            ]
        ),

        // MARK: - Official Anime4K v4.0.1 Suite + CuNNy + FSRCNNX
        EffectDescriptor(
            id: .anime4kRestore,
            nameEN: "Anime4K Restore",
            nameZH: "Anime4K 修复",
            summaryEN: "1× CReLU CNN that restores compression blur and line art.",
            summaryZH: "1× 卷积网络，修复压缩模糊与线条重影。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Quality",
                    labelZH: "画质",
                    descriptionEN: "CNN model size (S/M/L/VL) or Soft variants.",
                    descriptionZH: "网络规模（S/M/L/VL）或柔和变体。",
                    kind: .choice(
                        defaultValue: "M",
                        options: [
                            EffectParameterChoice(value: "S", labelEN: "S", labelZH: "S"),
                            EffectParameterChoice(value: "M", labelEN: "M", labelZH: "M"),
                            EffectParameterChoice(value: "L", labelEN: "L", labelZH: "L"),
                            EffectParameterChoice(value: "VL", labelEN: "VL", labelZH: "VL"),
                            EffectParameterChoice(value: "softM", labelEN: "Soft M", labelZH: "Soft M"),
                            EffectParameterChoice(value: "softL", labelEN: "Soft L", labelZH: "Soft L")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "clampHighlights",
                    labelEN: "Clamp Highlights",
                    labelZH: "高光钳位",
                    descriptionEN: "Prevents bright ringing halos along dark outlines.",
                    descriptionZH: "抑制暗色轮廓周围的亮边光晕。",
                    kind: .bool(defaultValue: true)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kUpscaleDenoise,
            nameEN: "Anime4K Upscale + Denoise",
            nameZH: "Anime4K 超分降噪",
            summaryEN: "2× Anime4K CNN upscaler with integrated denoising.",
            summaryZH: "2× 神经网络超分并同步降噪。",
            category: .anime,
            scaleCapability: .fixed(factor: 2.0),
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Quality",
                    labelZH: "画质",
                    descriptionEN: "CNN model size from S (fastest) to VL (highest quality).",
                    descriptionZH: "模型规模，从 S（最快）到 VL（最高画质）。",
                    kind: .choice(
                        defaultValue: "L",
                        options: [
                            EffectParameterChoice(value: "S", labelEN: "S", labelZH: "S"),
                            EffectParameterChoice(value: "M", labelEN: "M", labelZH: "M"),
                            EffectParameterChoice(value: "L", labelEN: "L", labelZH: "L"),
                            EffectParameterChoice(value: "VL", labelEN: "VL", labelZH: "VL")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "clampHighlights",
                    labelEN: "Clamp Highlights",
                    labelZH: "高光钳位",
                    descriptionEN: "Clamps bright overshoot around high-contrast edges.",
                    descriptionZH: "抑制高对比度边缘的过冲白边。",
                    kind: .bool(defaultValue: true)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kUpscale,
            nameEN: "Anime4K Upscale",
            nameZH: "Anime4K 超分",
            summaryEN: "2× Anime4K CNN upscaler without aggressive denoising.",
            summaryZH: "纯 2× 神经网络超分，不含强降噪。",
            category: .anime,
            scaleCapability: .fixed(factor: 2.0),
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Quality",
                    labelZH: "画质",
                    descriptionEN: "CNN model size from S (fastest) to VL (highest quality).",
                    descriptionZH: "模型规模，从 S（最快）到 VL（最高画质）。",
                    kind: .choice(
                        defaultValue: "L",
                        options: [
                            EffectParameterChoice(value: "S", labelEN: "S", labelZH: "S"),
                            EffectParameterChoice(value: "M", labelEN: "M", labelZH: "M"),
                            EffectParameterChoice(value: "L", labelEN: "L", labelZH: "L"),
                            EffectParameterChoice(value: "VL", labelEN: "VL", labelZH: "VL")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "clampHighlights",
                    labelEN: "Clamp Highlights",
                    labelZH: "高光钳位",
                    descriptionEN: "Prevents ringing halos around dark outlines.",
                    descriptionZH: "抑制暗色线条边缘的白色光晕。",
                    kind: .bool(defaultValue: true)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kThin,
            nameEN: "Anime4K Thin",
            nameZH: "Anime4K 线条细化",
            summaryEN: "Narrows thick dark outlines via gradient-guided warping.",
            summaryZH: "基于梯度收细偏粗的暗色线条。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "strength",
                    labelEN: "Strength",
                    labelZH: "强度",
                    descriptionEN: "Line thinning strength (0.4–0.8 typical).",
                    descriptionZH: "线条收细幅度（常用 0.4–0.8）。",
                    kind: .float(defaultValue: 0.6, min: 0.0, max: 1.5, step: 0.1)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kDarken,
            nameEN: "Anime4K Darken",
            nameZH: "Anime4K 线条加深",
            summaryEN: "Selectively deepens dark ink lines without darkening flat fills.",
            summaryZH: "选择性加深暗色轮廓线条。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "strength",
                    labelEN: "Strength",
                    labelZH: "强度",
                    descriptionEN: "Line darkening strength (0.3–0.7 typical).",
                    descriptionZH: "线条加深幅度（常用 0.3–0.7）。",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.5, step: 0.1)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kDenoiseBilateral,
            nameEN: "Anime4K Bilateral Denoise",
            nameZH: "Anime4K 双边降噪",
            summaryEN: "Edge-preserving bilateral denoiser with Mode, Mean, and Median filters.",
            summaryZH: "保边双边降噪，支持众数、均值与中值滤镜。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "mode",
                    labelEN: "Mode",
                    labelZH: "模式",
                    descriptionEN: "Mode preserves edges; Mean smooths; Median removes speckles.",
                    descriptionZH: "众数保边，均值平滑，中值去椒盐噪点。",
                    kind: .choice(
                        defaultValue: "mode",
                        options: [
                            EffectParameterChoice(value: "mode", labelEN: "Mode", labelZH: "众数"),
                            EffectParameterChoice(value: "mean", labelEN: "Mean", labelZH: "均值"),
                            EffectParameterChoice(value: "median", labelEN: "Median", labelZH: "中值")
                        ]
                    )
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kClampHighlights,
            nameEN: "Anime4K Clamp Highlights",
            nameZH: "Anime4K 高光钳位",
            summaryEN: "Post-pass anti-ringing clamp for bright overshoot halos.",
            summaryZH: "消除超分或锐化后的边缘亮边过冲。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: []
        ),
        EffectDescriptor(
            id: .cunny,
            nameEN: "CuNNy 2×",
            nameZH: "CuNNy 2×",
            summaryEN: "Compact 2× neural upscaler for anime, visual novels, and 2D games.",
            summaryZH: "轻量级 2× 神经网络超分，适合动漫与 2D 游戏。",
            category: .anime,
            scaleCapability: .fixed(factor: 2.0),
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Model",
                    labelZH: "模型",
                    descriptionEN: "8ch fast, 12ch balanced, or full RGB 3×12 neural network.",
                    descriptionZH: "8 通道快速、12 通道均衡或全彩 RGB 3×12 模型。",
                    kind: .choice(
                        defaultValue: "balanced",
                        options: [
                            EffectParameterChoice(value: "fast", labelEN: "Fast (8ch)", labelZH: "快速 (8ch)"),
                            EffectParameterChoice(value: "balanced", labelEN: "Balanced (12ch)", labelZH: "均衡 (12ch)"),
                            EffectParameterChoice(value: "highQuality", labelEN: "High (RGB 3×12)", labelZH: "高画质 (RGB 3×12)")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "锐度",
                    descriptionEN: "High-frequency detail residual scale (1.0 native).",
                    descriptionZH: "高频细节残差倍率（1.0 为原生值）。",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 2.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .fsrcnnx,
            nameEN: "FSRCNNX 2×",
            nameZH: "FSRCNNX 2×",
            summaryEN: "6-pass 2× convolutional neural upscaler.",
            summaryZH: "6 通道 2× 卷积神经网络超分。",
            category: .anime,
            scaleCapability: .fixed(factor: 2.0),
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Model",
                    labelZH: "模型",
                    descriptionEN: "Standard, LineArt for 2D outlines, or Enhanced Detail.",
                    descriptionZH: "标准、二次元线条或细节增强模型。",
                    kind: .choice(
                        defaultValue: "standard",
                        options: [
                            EffectParameterChoice(value: "standard", labelEN: "Standard", labelZH: "标准"),
                            EffectParameterChoice(value: "lineArt", labelEN: "LineArt", labelZH: "线条"),
                            EffectParameterChoice(value: "enhancedDetail", labelEN: "Enhanced", labelZH: "细节增强")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "锐度",
                    descriptionEN: "High-frequency luminance gain (1.0 native).",
                    descriptionZH: "高频亮度细节增益（1.0 为原生值）。",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 1.5, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "antiRinging",
                    labelEN: "Anti-Ringing",
                    labelZH: "抗振铃",
                    descriptionEN: "Clamps neural overshoot to local source bounds.",
                    descriptionZH: "限制神经网络过冲以抑制白边。",
                    kind: .float(defaultValue: 0.35, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),

        // MARK: - Pixel Art
        EffectDescriptor(
            id: .xbrzFreescale,
            nameEN: "xBRZ",
            nameZH: "xBRZ",
            summaryEN: "Perceptual vector edge-smoothing for pixel art at arbitrary ratios.",
            summaryZH: "感知矢量像素平滑，支持任意缩放比例。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "equalColorTolerance",
                    labelEN: "Color Tolerance",
                    labelZH: "色差容差",
                    descriptionEN: "Perceptual YCbCr distance for treating neighbors as equal.",
                    descriptionZH: "相邻像素视为同色的 YCbCr 距离阈值。",
                    kind: .float(defaultValue: 30.0, min: 5.0, max: 60.0, step: 1.0)
                ),
                EffectParameterDescriptor(
                    id: "edgeThreshold",
                    labelEN: "Edge Threshold",
                    labelZH: "斜边阈值",
                    descriptionEN: "Threshold controlling 2:1 slope interpolation.",
                    descriptionZH: "2:1 斜边平滑触发阈值。",
                    kind: .float(defaultValue: 2.2, min: 1.2, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "dominantDirectionThreshold",
                    labelEN: "Direction Threshold",
                    labelZH: "主方向阈值",
                    descriptionEN: "Dominance threshold for full diagonal corner blending.",
                    descriptionZH: "强斜边覆盖拐角的判定阈值。",
                    kind: .float(defaultValue: 3.6, min: 1.5, max: 6.0, step: 0.1)
                )
            ]
        ),
        EffectDescriptor(
            id: .sharpBilinear,
            nameEN: "Sharp Bilinear",
            nameZH: "锐利双线性",
            summaryEN: "Crisp pixel scaling with 1-pixel boundary blending at non-integer ratios.",
            summaryZH: "非整数倍像素缩放，保留像素轮廓并消除闪烁。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "锐度",
                    descriptionEN: "Blends between bilinear (0.0) and crisp pixel transitions (1.0).",
                    descriptionZH: "0.0 为双线性，1.0 为最锐利像素过渡。",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .pixellate,
            nameEN: "Pixellate",
            nameZH: "Pixellate",
            summaryEN: "Texel-area box integration for shimmer-free non-integer pixel scaling.",
            summaryZH: "像素面积积分缩放，非整数倍下像素均匀无闪烁。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),
        EffectDescriptor(
            id: .nearest,
            nameEN: "Nearest",
            nameZH: "最近邻",
            summaryEN: "Point sampling without interpolation.",
            summaryZH: "无插值点采样，适合整数倍像素缩放。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),

        // MARK: - Retro CRT
        EffectDescriptor(
            id: .crtGeom,
            nameEN: "CRT-Geom",
            nameZH: "CRT-Geom",
            summaryEN: "CRT simulation with scanlines, phosphor masks, halation, vignette, and curvature.",
            summaryZH: "CRT 显像管模拟，含扫描线、掩膜、辉光、暗角与曲率。",
            category: .crt,
            scaleCapability: .arbitrary,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "curvature",
                    labelEN: "Curvature",
                    labelZH: "球面曲率",
                    descriptionEN: "Simulates curved CRT glass geometry.",
                    descriptionZH: "启用显像管球面弧度。",
                    kind: .bool(defaultValue: false)
                ),
                EffectParameterDescriptor(
                    id: "curvatureRadius",
                    labelEN: "Radius",
                    labelZH: "曲率半径",
                    descriptionEN: "Smaller values produce stronger curvature.",
                    descriptionZH: "数值越小曲率越明显。",
                    kind: .float(defaultValue: 2.0, min: 0.8, max: 5.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "scanlineWeight",
                    labelEN: "Scanlines",
                    labelZH: "扫描线",
                    descriptionEN: "Vertical beam width and darkness of horizontal scanlines.",
                    descriptionZH: "水平扫描线宽度与深浅。",
                    kind: .float(defaultValue: 0.3, min: 0.1, max: 0.6, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "maskType",
                    labelEN: "Phosphor Mask",
                    labelZH: "掩膜样式",
                    descriptionEN: "Aperture grille, shadow mask, slot mask, or off.",
                    descriptionZH: "荧光粉亚像素掩膜排列方式。",
                    kind: .choice(
                        defaultValue: "apertureGrille",
                        options: [
                            EffectParameterChoice(value: "apertureGrille", labelEN: "Aperture Grille", labelZH: "条纹光栅"),
                            EffectParameterChoice(value: "shadowMask", labelEN: "Shadow Mask", labelZH: "阴影掩膜"),
                            EffectParameterChoice(value: "slotMask", labelEN: "Slot Mask", labelZH: "槽形掩膜"),
                            EffectParameterChoice(value: "off", labelEN: "Off", labelZH: "关闭")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "dotMask",
                    labelEN: "Mask Strength",
                    labelZH: "掩膜强度",
                    descriptionEN: "Visibility of the RGB phosphor subpixel mask.",
                    descriptionZH: "RGB 掩膜纹理明显程度。",
                    kind: .float(defaultValue: 0.3, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "halation",
                    labelEN: "Halation",
                    labelZH: "辉光",
                    descriptionEN: "Phosphor bloom around bright pixels.",
                    descriptionZH: "高亮像素周围的荧光光晕。",
                    kind: .float(defaultValue: 0.15, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "vignette",
                    labelEN: "Vignette",
                    labelZH: "暗角",
                    descriptionEN: "Corner brightness falloff.",
                    descriptionZH: "屏幕四角暗角衰减。",
                    kind: .float(defaultValue: 0.15, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "brightness",
                    labelEN: "Brightness",
                    labelZH: "亮度",
                    descriptionEN: "Brightness compensation for scanlines and mask.",
                    descriptionZH: "扫描线与掩膜造成的亮度补偿。",
                    kind: .float(defaultValue: 1.05, min: 0.5, max: 1.5, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "crtGamma",
                    labelEN: "CRT Gamma",
                    labelZH: "CRT 伽马",
                    descriptionEN: "Simulated CRT input gamma curve.",
                    descriptionZH: "模拟显像管输入伽马。",
                    kind: .float(defaultValue: 2.4, min: 1.0, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "monitorGamma",
                    labelEN: "Display Gamma",
                    labelZH: "屏幕伽马",
                    descriptionEN: "Output gamma matching the host display (2.2 standard).",
                    descriptionZH: "目标显示器输出伽马（标准 2.2）。",
                    kind: .float(defaultValue: 2.2, min: 1.0, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "cornerSize",
                    labelEN: "Corner Radius",
                    labelZH: "圆角",
                    descriptionEN: "Outer bezel corner rounding.",
                    descriptionZH: "屏幕四角圆弧半径。",
                    kind: .float(defaultValue: 0.01, min: 0.001, max: 0.1, step: 0.005)
                )
            ]
        ),
        EffectDescriptor(
            id: .crtLottes,
            nameEN: "CRT-Lottes",
            nameZH: "CRT-Lottes",
            summaryEN: "Arcade CRT shader with Gaussian scanlines and shadow masks.",
            summaryZH: "街机 CRT 着色器，含高斯扫描线与阴影掩膜。",
            category: .crt,
            scaleCapability: .arbitrary,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "hardScan",
                    labelEN: "Scanline Hardness",
                    labelZH: "扫描线锐度",
                    descriptionEN: "More negative values create sharper scanlines (-8 default).",
                    descriptionZH: "越负扫描线越锐利（默认 -8）。",
                    kind: .float(defaultValue: -8.0, min: -16.0, max: -2.0, step: 0.5)
                ),
                EffectParameterDescriptor(
                    id: "hardPix",
                    labelEN: "Pixel Hardness",
                    labelZH: "像素锐度",
                    descriptionEN: "Horizontal pixel focus (-2 soft, -3 balanced, -5 sharp).",
                    descriptionZH: "水平像素锐度（-2 柔和，-3 均衡，-5 锐利）。",
                    kind: .float(defaultValue: -3.0, min: -6.0, max: -1.0, step: 0.25)
                ),
                EffectParameterDescriptor(
                    id: "warpX",
                    labelEN: "Warp X",
                    labelZH: "水平弯曲",
                    descriptionEN: "Horizontal barrel curvature (0.0 = flat).",
                    descriptionZH: "水平桶形曲率（0 为平面）。",
                    kind: .float(defaultValue: 0.0, min: 0.0, max: 0.125, step: 0.005)
                ),
                EffectParameterDescriptor(
                    id: "warpY",
                    labelEN: "Warp Y",
                    labelZH: "垂直弯曲",
                    descriptionEN: "Vertical barrel curvature (0.0 = flat).",
                    descriptionZH: "垂直桶形曲率（0 为平面）。",
                    kind: .float(defaultValue: 0.0, min: 0.0, max: 0.125, step: 0.005)
                ),
                EffectParameterDescriptor(
                    id: "shadowMask",
                    labelEN: "Shadow Mask",
                    labelZH: "掩膜样式",
                    descriptionEN: "Phosphor grid layout.",
                    descriptionZH: "荧光粉网格样式。",
                    kind: .choice(
                        defaultValue: "apertureGrille",
                        options: [
                            EffectParameterChoice(value: "none", labelEN: "Off", labelZH: "关闭"),
                            EffectParameterChoice(value: "compressedTV", labelEN: "TV Mask", labelZH: "彩电点阵"),
                            EffectParameterChoice(value: "apertureGrille", labelEN: "Aperture Grille", labelZH: "条纹光栅"),
                            EffectParameterChoice(value: "stretchedVGA", labelEN: "Stretched VGA", labelZH: "宽距 VGA"),
                            EffectParameterChoice(value: "vga", labelEN: "VGA", labelZH: "精细 VGA")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "brightBoost",
                    labelEN: "Brightness",
                    labelZH: "亮度",
                    descriptionEN: "Linear brightness multiplier.",
                    descriptionZH: "线性亮度增益。",
                    kind: .float(defaultValue: 1.0, min: 0.5, max: 2.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "maskDark",
                    labelEN: "Mask Dark",
                    labelZH: "掩膜暗部",
                    descriptionEN: "Minimum brightness of darkened mask subpixels.",
                    descriptionZH: "掩膜暗部亚像素下限。",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "maskLight",
                    labelEN: "Mask Light",
                    labelZH: "掩膜亮部",
                    descriptionEN: "Peak brightness of illuminated phosphor stripes.",
                    descriptionZH: "掩膜亮部亚像素上限。",
                    kind: .float(defaultValue: 1.5, min: 1.0, max: 2.0, step: 0.05)
                )
            ]
        ),

        // MARK: - Classic Interpolation
        EffectDescriptor(
            id: .lanczos6,
            nameEN: "Lanczos6",
            nameZH: "Lanczos6",
            summaryEN: "6-tap separable Lanczos3 filter with anti-ringing clamp.",
            summaryZH: "6 点可分离 Lanczos3 滤波，内置抗振铃。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "antiRinging",
                    labelEN: "Anti-Ringing",
                    labelZH: "抗振铃",
                    descriptionEN: "Suppresses ringing halos around high-contrast edges.",
                    descriptionZH: "抑制高对比度边缘的振铃白边。",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "锐度",
                    descriptionEN: "Lobe response scale (1.0 = exact Lanczos3).",
                    descriptionZH: "滤波核锐度（1.0 为标准 Lanczos3）。",
                    kind: .float(defaultValue: 1.0, min: 0.5, max: 1.5, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .jinc,
            nameEN: "Jinc",
            nameZH: "Jinc",
            summaryEN: "2D circular EWA Jinc2 filter for smooth diagonals.",
            summaryZH: "2D 圆形对称 EWA Jinc2 滤波，斜线平滑。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "windowSinc",
                    labelEN: "Window (A)",
                    labelZH: "窗口 (A)",
                    descriptionEN: "Window rolloff: lower is sharper, higher is softer.",
                    descriptionZH: "窗函数滚降：越小越锐利，越大越柔和。",
                    kind: .float(defaultValue: 0.5, min: 0.1, max: 1.0, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "sinc",
                    labelEN: "Frequency (B)",
                    labelZH: "频率 (B)",
                    descriptionEN: "0.825 balances smoothness; closer to 1.0 increases sharpness.",
                    descriptionZH: "0.825 均衡平滑，接近 1.0 提高锐度。",
                    kind: .float(defaultValue: 0.825, min: 0.5, max: 1.0, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "antiRinging",
                    labelEN: "Anti-Ringing",
                    labelZH: "抗振铃",
                    descriptionEN: "Clamps overshoot halos to local 2×2 source bounds.",
                    descriptionZH: "将过冲钳位至局部 2×2 源像素范围。",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .bicubic,
            nameEN: "Bicubic",
            nameZH: "双三次",
            summaryEN: "9-tap Mitchell-Netravali cubic filter (Catmull-Rom default).",
            summaryZH: "9 点 Mitchell-Netravali 双三次滤波（默认 Catmull-Rom）。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "b",
                    labelEN: "B",
                    labelZH: "B（平滑）",
                    descriptionEN: "Cubic B parameter (Catmull-Rom = 0.0, Mitchell = 0.33).",
                    descriptionZH: "双三次 B 系数（Catmull-Rom = 0，Mitchell = 0.33）。",
                    kind: .float(defaultValue: 0.0, min: 0.0, max: 1.0, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "c",
                    labelEN: "C",
                    labelZH: "C（锐度）",
                    descriptionEN: "Cubic C parameter (Catmull-Rom = 0.50, Mitchell = 0.33).",
                    descriptionZH: "双三次 C 系数（Catmull-Rom = 0.50，Mitchell = 0.33）。",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.01)
                )
            ]
        ),
        EffectDescriptor(
            id: .bilinear,
            nameEN: "Bilinear",
            nameZH: "双线性",
            summaryEN: "Hardware bilinear interpolation.",
            summaryZH: "硬件双线性插值。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),

        // MARK: - Sharpening
        EffectDescriptor(
            id: .cas,
            nameEN: "CAS",
            nameZH: "CAS 锐化",
            summaryEN: "AMD FidelityFX Contrast Adaptive Sharpening.",
            summaryZH: "AMD FidelityFX 对比度自适应锐化。",
            category: .sharpening,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "锐化",
                    descriptionEN: "Local contrast sharpening intensity.",
                    descriptionZH: "局部对比度锐化强度。",
                    kind: .float(defaultValue: 0.4, min: 0.0, max: 1.0, step: 0.02)
                )
            ]
        ),
        EffectDescriptor(
            id: .adaptiveSharpen,
            nameEN: "Adaptive Sharpen",
            nameZH: "自适应锐化",
            summaryEN: "Two-pass edge-aware curve sharpening.",
            summaryZH: "双通道边缘感知曲线锐化。",
            category: .sharpening,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "curveHeight",
                    labelEN: "Strength",
                    labelZH: "强度",
                    descriptionEN: "Height of the adaptive sharpening curve.",
                    descriptionZH: "自适应锐化曲线幅度。",
                    kind: .float(defaultValue: 0.3, min: 0.05, max: 2.0, step: 0.05)
                )
            ]
        ),

        // MARK: - Downscaling
        EffectDescriptor(
            id: .ssimDownscaler,
            nameEN: "SSimDownscaler",
            nameZH: "SSIM 降采样",
            summaryEN: "5-pass structural-similarity downscaler for supersampled chains.",
            summaryZH: "5 通道结构相似度降采样。",
            category: .downscaling,
            scaleCapability: .downscaleOnly,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "oversharp",
                    labelEN: "Detail Gain",
                    labelZH: "细节保留",
                    descriptionEN: "Structural contrast gain during downscaling (1.0 neutral).",
                    descriptionZH: "降采样结构对比度增益（1.0 为标准）。",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 3.0, step: 0.1)
                )
            ]
        ),

        // MARK: - Utility, Anti-Aliasing & Color
        EffectDescriptor(
            id: .fxaa,
            nameEN: "FXAA 3.11",
            nameZH: "FXAA 3.11",
            summaryEN: "Fast approximate edge anti-aliasing pre-pass.",
            summaryZH: "快速近似边缘抗锯齿。",
            category: .utility,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "qualityPreset",
                    labelEN: "Quality",
                    labelZH: "精度",
                    descriptionEN: "Edge search steps (Low=8, Medium=16, High=24, Ultra=32).",
                    descriptionZH: "边缘搜索步数（低 8 / 中 16 / 高 24 / 极高 32）。",
                    kind: .choice(
                        defaultValue: "high",
                        options: [
                            EffectParameterChoice(value: "low", labelEN: "Low", labelZH: "低"),
                            EffectParameterChoice(value: "medium", labelEN: "Medium", labelZH: "中"),
                            EffectParameterChoice(value: "high", labelEN: "High", labelZH: "高"),
                            EffectParameterChoice(value: "ultra", labelEN: "Ultra", labelZH: "极高")
                        ]
                    )
                ),
                EffectParameterDescriptor(
                    id: "edgeThreshold",
                    labelEN: "Edge Threshold",
                    labelZH: "边缘阈值",
                    descriptionEN: "Minimum local contrast required to trigger anti-aliasing.",
                    descriptionZH: "触发抗锯齿的最小局部对比度。",
                    kind: .float(defaultValue: 0.125, min: 0.06, max: 0.33, step: 0.005)
                ),
                EffectParameterDescriptor(
                    id: "subpixelQuality",
                    labelEN: "Subpixel",
                    labelZH: "亚像素平滑",
                    descriptionEN: "Subpixel aliasing blend factor.",
                    descriptionZH: "亚像素锯齿平滑系数。",
                    kind: .float(defaultValue: 0.75, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .deband,
            nameEN: "Deband",
            nameZH: "去色带",
            summaryEN: "Stochastic dithering pass removing 8-bit gradient banding.",
            summaryZH: "消除 8-bit 渐变色带断层。",
            category: .utility,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "threshold",
                    labelEN: "Threshold",
                    labelZH: "阈值",
                    descriptionEN: "Maximum color delta blended as banding.",
                    descriptionZH: "判定为色带的最大色差阈值。",
                    kind: .float(defaultValue: 0.015, min: 0.001, max: 0.1, step: 0.002)
                ),
                EffectParameterDescriptor(
                    id: "range",
                    labelEN: "Range",
                    labelZH: "范围",
                    descriptionEN: "Pixel radius sampled around each pixel.",
                    descriptionZH: "采样搜索半径（像素）。",
                    kind: .float(defaultValue: 16.0, min: 4.0, max: 32.0, step: 1.0)
                ),
                EffectParameterDescriptor(
                    id: "grain",
                    labelEN: "Grain",
                    labelZH: "抖动",
                    descriptionEN: "Micro-dither amplitude to prevent requantization.",
                    descriptionZH: "微粒抖动强度，防止 8-bit 输出重现色带。",
                    kind: .float(defaultValue: 0.006, min: 0.0, max: 0.05, step: 0.002)
                )
            ]
        ),
        EffectDescriptor(
            id: .imageAdjustment,
            nameEN: "Image Adjustment",
            nameZH: "画面调节",
            summaryEN: "Gamma, brightness, contrast, saturation, vibrance, and temperature.",
            summaryZH: "调节伽马、亮度、对比度、饱和度、鲜艳度与色温。",
            category: .utility,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "gamma",
                    labelEN: "Gamma",
                    labelZH: "伽马",
                    descriptionEN: "Midtone gamma curve (1.0 neutral).",
                    descriptionZH: "中间调伽马曲线（1.0 为中性）。",
                    kind: .float(defaultValue: 1.0, min: 0.5, max: 2.5, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "brightness",
                    labelEN: "Brightness",
                    labelZH: "亮度",
                    descriptionEN: "Uniform brightness offset.",
                    descriptionZH: "整体亮度偏移。",
                    kind: .float(defaultValue: 0.0, min: -0.5, max: 0.5, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "contrast",
                    labelEN: "Contrast",
                    labelZH: "对比度",
                    descriptionEN: "Luminance contrast multiplier.",
                    descriptionZH: "明暗对比度倍率。",
                    kind: .float(defaultValue: 1.0, min: 0.5, max: 2.0, step: 0.02)
                ),
                EffectParameterDescriptor(
                    id: "saturation",
                    labelEN: "Saturation",
                    labelZH: "饱和度",
                    descriptionEN: "Global color saturation multiplier.",
                    descriptionZH: "全局色彩饱和度。",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 2.0, step: 0.02)
                ),
                EffectParameterDescriptor(
                    id: "vibrance",
                    labelEN: "Vibrance",
                    labelZH: "鲜艳度",
                    descriptionEN: "Selectively boosts muted colors.",
                    descriptionZH: "优先增强低饱和色彩。",
                    kind: .float(defaultValue: 0.0, min: -0.5, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "temperature",
                    labelEN: "Temperature",
                    labelZH: "色温",
                    descriptionEN: "White balance shift (negative cooler, positive warmer).",
                    descriptionZH: "色温偏移（负值偏冷，正值偏暖）。",
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
