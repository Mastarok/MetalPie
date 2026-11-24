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
        case .utility: return "Utility & Color"
        }
    }

    public var labelZH: String {
        switch self {
        case .superResolution: return "超分辨率"
        case .mlUpscaler: return "Apple 硬件 / 机器学习"
        case .anime: return "动漫与神经网络"
        case .pixelArt: return "像素艺术"
        case .crt: return "CRT 复古显示"
        case .sharpening: return "锐化增强"
        case .interpolation: return "经典插值"
        case .downscaling: return "高质量降采样"
        case .utility: return "实用与色彩"
        }
    }
}

/// Stable identifier for every built-in scaling, sharpening, and post-processing effect.
public enum EffectID: String, Codable, Sendable, CaseIterable, Identifiable {
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

    /// Parameter map populated with each parameter's default value.
    public var defaultParameters: EffectParameters {
        var map: [String: EffectParameterValue] = [:]
        for param in parameters {
            map[param.id] = param.kind.defaultParameterValue
        }
        return EffectParameters(map)
    }
}

/// Authoritative catalog of all 22 built-in MetalPie effects.
public enum EffectCatalog: Sendable {
    public static let all: [EffectDescriptor] = [
        EffectDescriptor(
            id: .metalFXSpatial,
            nameEN: "MetalFX Spatial",
            nameZH: "MetalFX 空间超分",
            summaryEN: "Apple Silicon hardware-accelerated spatial upscaler with perceptual and HDR color modes.",
            summaryZH: "Apple Silicon 原生硬件加速空间超分，支持感知色彩与 HDR 模式。",
            category: .mlUpscaler,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            minimumMacOSMajorVersion: 14,
            parameters: [
                EffectParameterDescriptor(
                    id: "colorProcessingMode",
                    labelEN: "Color Processing",
                    labelZH: "色彩处理模式",
                    descriptionEN: "Select perceptual (sRGB), linear, or HDR tone handling.",
                    descriptionZH: "选择感知 (sRGB)、线性或 HDR 色调处理方式。",
                    kind: .choice(
                        defaultValue: "perceptual",
                        options: [
                            EffectParameterChoice(value: "perceptual", labelEN: "Perceptual (SDR)", labelZH: "感知 (SDR)"),
                            EffectParameterChoice(value: "linear", labelEN: "Linear", labelZH: "线性"),
                            EffectParameterChoice(value: "hdr", labelEN: "HDR", labelZH: "高动态范围 (HDR)")
                        ]
                    )
                )
            ]
        ),
        EffectDescriptor(
            id: .vtSuperResolution,
            nameEN: "Apple ML Super Resolution",
            nameZH: "Apple 机器学习超分",
            summaryEN: "VideoToolbox low-latency Neural Engine super resolution (macOS 26+, discrete 1.5x/2x/4x).",
            summaryZH: "基于 VideoToolbox 神经网络引擎的低延迟超分（macOS 26+，支持 1.5×/2×/4×）。",
            category: .mlUpscaler,
            scaleCapability: .discreteScales([1.5, 2.0, 4.0]),
            supportsHDR: false,
            minimumMacOSMajorVersion: 26,
            parameters: [
                EffectParameterDescriptor(
                    id: "scaleFactor",
                    labelEN: "ML Scale Factor",
                    labelZH: "超分倍率",
                    descriptionEN: "Discrete Neural Engine scaling ratio.",
                    descriptionZH: "神经网络引擎离散放大倍率。",
                    kind: .choice(
                        defaultValue: "2.0",
                        options: [
                            EffectParameterChoice(value: "1.5", labelEN: "1.5x", labelZH: "1.5 倍"),
                            EffectParameterChoice(value: "2.0", labelEN: "2.0x", labelZH: "2.0 倍"),
                            EffectParameterChoice(value: "4.0", labelEN: "4.0x", labelZH: "4.0 倍")
                        ]
                    )
                )
            ]
        ),
        EffectDescriptor(
            id: .fsr1EASU,
            nameEN: "FSR 1.0 EASU",
            nameZH: "FSR 1.0 边缘自适应超分 (EASU)",
            summaryEN: "AMD FidelityFX Super Resolution 1.0 Edge-Adaptive Spatial Upsampling pass.",
            summaryZH: "AMD FidelityFX Super Resolution 1.0 边缘自适应空间上采样通道。",
            category: .superResolution,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),
        EffectDescriptor(
            id: .fsr1RCAS,
            nameEN: "FSR 1.0 RCAS",
            nameZH: "FSR 1.0 鲁棒对比度自适应锐化 (RCAS)",
            summaryEN: "Noise-aware contrast adaptive sharpening pass paired with FSR EASU.",
            summaryZH: "与 FSR EASU 搭配使用的抗噪自适应锐化通道。",
            category: .sharpening,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "锐化强度",
                    descriptionEN: "Higher values increase local edge contrast.",
                    descriptionZH: "数值越高，边缘锐化效果越明显。",
                    kind: .float(defaultValue: 0.87, min: 0.0, max: 1.0, step: 0.01)
                )
            ]
        ),
        EffectDescriptor(
            id: .sgsr,
            nameEN: "SGSR v1",
            nameZH: "SGSR v1 快速超分",
            summaryEN: "Snapdragon Game Super Resolution single-pass edge-directed upscaler optimized for low GPU power.",
            summaryZH: "单通道边缘导向快速超分，适合低功耗与高帧率场景。",
            category: .superResolution,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "edgeSharpness",
                    labelEN: "Edge Sharpness",
                    labelZH: "边缘锐度",
                    kind: .float(defaultValue: 2.0, min: 0.0, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "edgeThreshold",
                    labelEN: "Edge Threshold",
                    labelZH: "边缘阈值",
                    kind: .float(defaultValue: 8.0, min: 0.0, max: 32.0, step: 0.5)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kRestore,
            nameEN: "Anime4K Restore",
            nameZH: "Anime4K 线条修复",
            summaryEN: "1x CReLU neural line restoration and artifact cleanup for 2D anime and visual novels.",
            summaryZH: "面向二次元动漫与视觉小说的 1× 线条修复与压缩伪影清理。",
            category: .anime,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "strength",
                    labelEN: "Restore Strength",
                    labelZH: "修复强度",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 1.5, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .anime4kUpscaleDenoise,
            nameEN: "Anime4K Upscale & Denoise",
            nameZH: "Anime4K 2× 放大与降噪",
            summaryEN: "2x neural upscaler and denoiser crafted for anime, cartoons, and 2D artwork.",
            summaryZH: "专为动漫、卡通与二维插画设计的 2× 神经网络放大与降噪。",
            category: .anime,
            scaleCapability: .fixed(factor: 2.0),
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "denoiseStrength",
                    labelEN: "Denoise Strength",
                    labelZH: "降噪强度",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "lineThinning",
                    labelEN: "Line Thinning",
                    labelZH: "线条细化",
                    kind: .float(defaultValue: 0.0, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .fsrcnnx,
            nameEN: "FSRCNNX 2x",
            nameZH: "FSRCNNX 2× 神经网络超分",
            summaryEN: "Multi-layer 2x convolutional neural network upscaler for crisp general & line-art content.",
            summaryZH: "多层 2× 卷积神经网络超分，兼顾通用画面与清晰线条表现。",
            category: .anime,
            scaleCapability: .fixed(factor: 2.0),
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "variant",
                    labelEN: "Model Variant",
                    labelZH: "模型变体",
                    kind: .choice(
                        defaultValue: "standard",
                        options: [
                            EffectParameterChoice(value: "standard", labelEN: "Standard (8-0-4-1)", labelZH: "标准版 (8-0-4-1)"),
                            EffectParameterChoice(value: "lineArt", labelEN: "Line Art", labelZH: "线条增强版")
                        ]
                    )
                )
            ]
        ),
        EffectDescriptor(
            id: .xbrzFreescale,
            nameEN: "xBRZ Freescale",
            nameZH: "xBRZ 自由倍率像素平滑",
            summaryEN: "Two-pass perceptual pixel-art vectorizing upscaler supporting arbitrary output ratios.",
            summaryZH: "双通道感知像素艺术矢量平滑算法，支持任意缩放倍率。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "equalColorTolerance",
                    labelEN: "Color Tolerance",
                    labelZH: "色彩容差",
                    kind: .float(defaultValue: 30.0, min: 5.0, max: 60.0, step: 1.0)
                )
            ]
        ),
        EffectDescriptor(
            id: .crtGeom,
            nameEN: "CRT-Geom",
            nameZH: "CRT-Geom 复古显像管",
            summaryEN: "Classic CRT shader with scanlines, phosphor dot mask, gamma calibration, and optional curvature.",
            summaryZH: "经典 CRT 显像管着色器，支持扫描线、荧光点栅、伽马校准与可选曲率。",
            category: .crt,
            scaleCapability: .arbitrary,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "curvature",
                    labelEN: "Screen Curvature",
                    labelZH: "屏幕曲率",
                    kind: .bool(defaultValue: false)
                ),
                EffectParameterDescriptor(
                    id: "crtGamma",
                    labelEN: "CRT Gamma",
                    labelZH: "CRT 伽马",
                    kind: .float(defaultValue: 2.4, min: 1.0, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "monitorGamma",
                    labelEN: "Monitor Gamma",
                    labelZH: "显示器伽马",
                    kind: .float(defaultValue: 2.2, min: 1.0, max: 4.0, step: 0.1)
                ),
                EffectParameterDescriptor(
                    id: "scanlineWeight",
                    labelEN: "Scanline Weight",
                    labelZH: "扫描线强度",
                    kind: .float(defaultValue: 0.3, min: 0.1, max: 0.6, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "dotMask",
                    labelEN: "Phosphor Mask",
                    labelZH: "荧光点栅强度",
                    kind: .float(defaultValue: 0.3, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "cornerSize",
                    labelEN: "Corner Radius",
                    labelZH: "边角圆弧",
                    kind: .float(defaultValue: 0.01, min: 0.001, max: 0.1, step: 0.005)
                )
            ]
        ),
        EffectDescriptor(
            id: .crtLottes,
            nameEN: "CRT-Lottes",
            nameZH: "CRT-Lottes 街机显像管",
            summaryEN: "Timothy Lottes' high-contrast arcade CRT shader with shadow mask and beam bloom.",
            summaryZH: "Timothy Lottes 街机风格 CRT 着色器，呈现高对比度阴影掩膜与光束辉光。",
            category: .crt,
            scaleCapability: .arbitrary,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "hardScan",
                    labelEN: "Scanline Hardness",
                    labelZH: "扫描线锐度",
                    kind: .float(defaultValue: -8.0, min: -16.0, max: -2.0, step: 0.5)
                ),
                EffectParameterDescriptor(
                    id: "hardPix",
                    labelEN: "Pixel Hardness",
                    labelZH: "像素锐度",
                    kind: .float(defaultValue: -3.0, min: -6.0, max: -1.0, step: 0.25)
                ),
                EffectParameterDescriptor(
                    id: "warpX",
                    labelEN: "Horizontal Warp",
                    labelZH: "水平弯曲",
                    kind: .float(defaultValue: 0.0, min: 0.0, max: 0.125, step: 0.005)
                ),
                EffectParameterDescriptor(
                    id: "warpY",
                    labelEN: "Vertical Warp",
                    labelZH: "垂直弯曲",
                    kind: .float(defaultValue: 0.0, min: 0.0, max: 0.125, step: 0.005)
                ),
                EffectParameterDescriptor(
                    id: "maskDark",
                    labelEN: "Mask Dark",
                    labelZH: "掩膜暗部",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "maskLight",
                    labelEN: "Mask Light",
                    labelZH: "掩膜亮部",
                    kind: .float(defaultValue: 1.5, min: 1.0, max: 2.0, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "shadowMask",
                    labelEN: "Shadow Mask Style",
                    labelZH: "阴影掩膜类型",
                    kind: .choice(
                        defaultValue: "apertureGrille",
                        options: [
                            EffectParameterChoice(value: "none", labelEN: "None", labelZH: "无"),
                            EffectParameterChoice(value: "compressedTV", labelEN: "Compressed TV", labelZH: "电视点阵"),
                            EffectParameterChoice(value: "apertureGrille", labelEN: "Aperture Grille", labelZH: "光栅条纹"),
                            EffectParameterChoice(value: "stretchedVGA", labelEN: "Stretched VGA", labelZH: "拉伸 VGA"),
                            EffectParameterChoice(value: "vga", labelEN: "VGA Fine", labelZH: "精细 VGA")
                        ]
                    )
                )
            ]
        ),
        EffectDescriptor(
            id: .lanczos6,
            nameEN: "Lanczos6 (Anti-Ringing)",
            nameZH: "Lanczos6 抗振铃缩放",
            summaryEN: "6-tap separable Lanczos3 scaler with configurable anti-ringing clamp for crisp text and UI.",
            summaryZH: "6 采样点可分离 Lanczos3 滤波器并带抗振铃抑制，文字与界面清晰自然。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "arStrength",
                    labelEN: "Anti-Ringing",
                    labelZH: "抗振铃强度",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .bicubic,
            nameEN: "Bicubic (Mitchell / Catmull-Rom)",
            nameZH: "双三次插值 (Bicubic)",
            summaryEN: "Hardware-accelerated 9-tap Mitchell-Netravali cubic filter (B=0, C=0.5 Catmull-Rom default).",
            summaryZH: "9 采样点硬件优化双三次滤波器（默认 Catmull-Rom B=0, C=0.5）。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "b",
                    labelEN: "Blur (B)",
                    labelZH: "平滑系数 (B)",
                    kind: .float(defaultValue: 0.0, min: 0.0, max: 1.0, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "c",
                    labelEN: "Ringing (C)",
                    labelZH: "锐度系数 (C)",
                    kind: .float(defaultValue: 0.5, min: 0.0, max: 1.0, step: 0.01)
                )
            ]
        ),
        EffectDescriptor(
            id: .sharpBilinear,
            nameEN: "Sharp Bilinear",
            nameZH: "锐利双线性 (像素艺术)",
            summaryEN: "Keeps pixel-art interiors crisp while smoothly blending only 1-pixel texel boundaries.",
            summaryZH: "保持像素内部锐利，仅在 1 像素边界处平滑过渡，消除非整数缩放锯齿。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Prescale Sharpness",
                    labelZH: "边缘锐度",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 1.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .pixellate,
            nameEN: "Pixellate",
            nameZH: "面积积分像素缩放",
            summaryEN: "Analytical texel-area integration eliminating shimmer on non-integer pixel-art scaling.",
            summaryZH: "精确像素面积积分，非整数倍率缩放像素画时零闪烁、无畸变。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),
        EffectDescriptor(
            id: .nearest,
            nameEN: "Nearest Neighbor",
            nameZH: "邻近采样 (整数像素)",
            summaryEN: "Zero-blur point sampling ideal for exact integer scaling of retro pixel games.",
            summaryZH: "零模糊点采样，配合整数缩放呈现极致锐利的复古像素。",
            category: .pixelArt,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),
        EffectDescriptor(
            id: .bilinear,
            nameEN: "Bilinear",
            nameZH: "双线性插值",
            summaryEN: "Fast hardware bilinear resampling with minimal GPU overhead.",
            summaryZH: "极低 GPU 开销的硬件双线性采样。",
            category: .interpolation,
            scaleCapability: .arbitrary,
            supportsHDR: true
        ),
        EffectDescriptor(
            id: .cas,
            nameEN: "CAS (Contrast Adaptive Sharpen)",
            nameZH: "CAS 对比度自适应锐化",
            summaryEN: "AMD FidelityFX Contrast Adaptive Sharpening restoring detail without haloing.",
            summaryZH: "AMD FidelityFX 对比度自适应锐化，还原细节且不产生光晕伪影。",
            category: .sharpening,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "sharpness",
                    labelEN: "Sharpness",
                    labelZH: "锐化强度",
                    kind: .float(defaultValue: 0.4, min: 0.0, max: 1.0, step: 0.02)
                )
            ]
        ),
        EffectDescriptor(
            id: .adaptiveSharpen,
            nameEN: "Adaptive Sharpen",
            nameZH: "自适应曲面锐化",
            summaryEN: "Edge-aware curve-based sharpening enhancing subtle textures while protecting clean edges.",
            summaryZH: "基于边缘曲线的自适应锐化，突出细微纹理同时保护边缘平滑。",
            category: .sharpening,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "curveHeight",
                    labelEN: "Curve Height",
                    labelZH: "锐化曲线高度",
                    kind: .float(defaultValue: 0.3, min: 0.05, max: 2.0, step: 0.05)
                )
            ]
        ),
        EffectDescriptor(
            id: .ssimDownscaler,
            nameEN: "SSimDownscaler",
            nameZH: "SSIM 感知降采样",
            summaryEN: "5-pass perceptual structural-similarity downscaler for crisp supersampled output.",
            summaryZH: "5 通道结构相似度感知降采样，用于 2× 神经网络超分后的高品质缩小。",
            category: .downscaling,
            scaleCapability: .downscaleOnly,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "oversharp",
                    labelEN: "Oversharp",
                    labelZH: "过锐系数",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 3.0, step: 0.1)
                )
            ]
        ),
        EffectDescriptor(
            id: .deband,
            nameEN: "Deband",
            nameZH: "去色带 (Deband)",
            summaryEN: "Removes 8-bit gradient banding in dark scenes and compressed video with optional micro-dither.",
            summaryZH: "消除暗部与压缩视频中的 8-bit 色带断层，支持可选细微抖动。",
            category: .utility,
            scaleCapability: .sameSize,
            supportsHDR: false,
            parameters: [
                EffectParameterDescriptor(
                    id: "threshold",
                    labelEN: "Threshold",
                    labelZH: "平滑阈值",
                    kind: .float(defaultValue: 0.015, min: 0.001, max: 0.1, step: 0.002)
                ),
                EffectParameterDescriptor(
                    id: "range",
                    labelEN: "Sample Radius",
                    labelZH: "采样半径",
                    kind: .float(defaultValue: 16.0, min: 4.0, max: 32.0, step: 1.0)
                ),
                EffectParameterDescriptor(
                    id: "grain",
                    labelEN: "Dither Grain",
                    labelZH: "抖动颗粒",
                    kind: .float(defaultValue: 0.006, min: 0.0, max: 0.05, step: 0.002)
                )
            ]
        ),
        EffectDescriptor(
            id: .imageAdjustment,
            nameEN: "Image Adjustment",
            nameZH: "色彩与画面调节",
            summaryEN: "Fine-tune gamma, brightness, contrast, and saturation at the end of the pipeline.",
            summaryZH: "在渲染管线末端微调伽马、亮度、对比度与饱和度。",
            category: .utility,
            scaleCapability: .sameSize,
            supportsHDR: true,
            parameters: [
                EffectParameterDescriptor(
                    id: "gamma",
                    labelEN: "Gamma",
                    labelZH: "伽马",
                    kind: .float(defaultValue: 1.0, min: 0.5, max: 2.5, step: 0.05)
                ),
                EffectParameterDescriptor(
                    id: "brightness",
                    labelEN: "Brightness",
                    labelZH: "亮度",
                    kind: .float(defaultValue: 0.0, min: -0.5, max: 0.5, step: 0.01)
                ),
                EffectParameterDescriptor(
                    id: "contrast",
                    labelEN: "Contrast",
                    labelZH: "对比度",
                    kind: .float(defaultValue: 1.0, min: 0.5, max: 2.0, step: 0.02)
                ),
                EffectParameterDescriptor(
                    id: "saturation",
                    labelEN: "Saturation",
                    labelZH: "饱和度",
                    kind: .float(defaultValue: 1.0, min: 0.0, max: 2.0, step: 0.02)
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
