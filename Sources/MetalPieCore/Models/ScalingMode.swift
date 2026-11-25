import Foundation

/// High-level usage scenario grouping for scaling presets so users can pick modes by intent.
public enum ScenarioTag: String, Codable, Sendable, CaseIterable, Identifiable {
    case game3D
    case anime
    case pixelRetro
    case generalVideo

    public var id: String { rawValue }

    public var labelEN: String {
        switch self {
        case .game3D: return "Games"
        case .anime: return "Anime"
        case .pixelRetro: return "Pixel"
        case .generalVideo: return "General"
        }
    }

    public var labelZH: String {
        switch self {
        case .game3D: return "游戏"
        case .anime: return "动漫"
        case .pixelRetro: return "像素"
        case .generalVideo: return "通用"
        }
    }

    public var symbolName: String {
        switch self {
        case .game3D: return "gamecontroller.fill"
        case .anime: return "sparkles"
        case .pixelRetro: return "square.grid.3x3.fill"
        case .generalVideo: return "play.rectangle.fill"
        }
    }
}

/// A single configured step inside a `ScalingMode`'s effect chain.
public struct EffectInstance: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var effectID: EffectID
    public var enabled: Bool
    public var scalingType: ScalingType
    public var scaleFactorX: Double
    public var scaleFactorY: Double
    public var absoluteWidth: Int?
    public var absoluteHeight: Int?
    public var parameters: EffectParameters

    public init(
        id: UUID = UUID(),
        effectID: EffectID,
        enabled: Bool = true,
        scalingType: ScalingType = .fit,
        scaleFactorX: Double = 1.0,
        scaleFactorY: Double = 1.0,
        absoluteWidth: Int? = nil,
        absoluteHeight: Int? = nil,
        parameters: EffectParameters? = nil
    ) {
        self.id = id
        self.effectID = effectID
        self.enabled = enabled
        self.scalingType = scalingType
        self.scaleFactorX = scaleFactorX
        self.scaleFactorY = scaleFactorY
        self.absoluteWidth = absoluteWidth
        self.absoluteHeight = absoluteHeight
        self.parameters = parameters ?? EffectCatalog.descriptor(for: effectID).defaultParameters
    }
}

/// Ordered multi-pass scaling preset composed of one or more `EffectInstance`s.
public struct ScalingMode: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var nameZH: String
    public var localizedDescription: String
    public var descriptionZH: String
    public var scenario: ScenarioTag
    public var effects: [EffectInstance]
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        nameZH: String = "",
        localizedDescription: String = "",
        descriptionZH: String = "",
        scenario: ScenarioTag = .generalVideo,
        effects: [EffectInstance],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.nameZH = nameZH
        self.localizedDescription = localizedDescription
        self.descriptionZH = descriptionZH
        self.scenario = scenario
        self.effects = effects
        self.isBuiltIn = isBuiltIn
    }

    /// Backwards-compatible Codable decoding so saved v1.0 configs lacking `nameZH`/`descriptionZH`/`scenario` load cleanly.
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case nameZH
        case localizedDescription
        case descriptionZH
        case scenario
        case effects
        case isBuiltIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.nameZH = try c.decodeIfPresent(String.self, forKey: .nameZH) ?? ""
        self.localizedDescription = try c.decodeIfPresent(String.self, forKey: .localizedDescription) ?? ""
        self.descriptionZH = try c.decodeIfPresent(String.self, forKey: .descriptionZH) ?? ""
        self.scenario = try c.decodeIfPresent(ScenarioTag.self, forKey: .scenario) ?? .generalVideo
        self.effects = try c.decode([EffectInstance].self, forKey: .effects)
        self.isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    /// Returns the display name for the active language, falling back to `name`.
    public func displayName(isChinese: Bool) -> String {
        if isChinese && !nameZH.isEmpty {
            return nameZH
        }
        return name
    }

    /// Returns the plain-language description for the active language, falling back to `localizedDescription`.
    public func displayDescription(isChinese: Bool) -> String {
        if isChinese && !descriptionZH.isEmpty {
            return descriptionZH
        }
        return localizedDescription
    }

    // MARK: - Stable Built-In Preset Identifiers

    // Original 12 built-in preset UUIDs (strictly preserved)
    public static let metalFXSpatialID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    public static let fsr1ID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    public static let appleMLSuperResID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    public static let lanczos6ID = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
    public static let anime4kID = UUID(uuidString: "10000000-0000-4000-8000-000000000005")!
    public static let fsrcnnxID = UUID(uuidString: "10000000-0000-4000-8000-000000000006")!
    public static let sgsrID = UUID(uuidString: "10000000-0000-4000-8000-000000000007")!
    public static let xbrzID = UUID(uuidString: "10000000-0000-4000-8000-000000000008")!
    public static let integerScaleID = UUID(uuidString: "10000000-0000-4000-8000-000000000009")!
    public static let sharpBilinearID = UUID(uuidString: "10000000-0000-4000-8000-00000000000A")!
    public static let crtGeomID = UUID(uuidString: "10000000-0000-4000-8000-00000000000B")!
    public static let bicubicCASID = UUID(uuidString: "10000000-0000-4000-8000-00000000000C")!

    // Official bloc97 Anime4K v4.0.1 presets (Mode A reuses anime4kID so legacy configs upgrade seamlessly without duplicates!)
    public static let anime4kModeAID = anime4kID
    public static let anime4kModeBID = UUID(uuidString: "10000000-0000-4000-8000-00000000000E")!
    public static let anime4kModeCID = UUID(uuidString: "10000000-0000-4000-8000-00000000000F")!
    public static let anime4kModeAAID = UUID(uuidString: "10000000-0000-4000-8000-000000000010")!
    public static let anime4kModeBBID = UUID(uuidString: "10000000-0000-4000-8000-000000000015")!
    public static let anime4kModeCAID = UUID(uuidString: "10000000-0000-4000-8000-000000000016")!

    // Additional Magpie flagship presets (CuNNy, FXAA+FSR, Jinc, CRT-Lottes)
    public static let cunnyAnimeID = UUID(uuidString: "10000000-0000-4000-8000-000000000011")!
    public static let fxaaFSR1ID = UUID(uuidString: "10000000-0000-4000-8000-000000000012")!
    public static let jincVideoID = UUID(uuidString: "10000000-0000-4000-8000-000000000013")!
    public static let crtLottesArcadeID = UUID(uuidString: "10000000-0000-4000-8000-000000000014")!

    /// Curated built-in presets seeded on first launch (21 presets across 4 scenarios).
    public static let builtInPresets: [ScalingMode] = [
        // MARK: - 3D Games
        ScalingMode(
            id: metalFXSpatialID,
            name: "MetalFX",
            nameZH: "MetalFX",
            localizedDescription: "Apple hardware spatial upscaling with HDR support.",
            descriptionZH: "Apple 原生硬件空间超分，支持 HDR。",
            scenario: .game3D,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
                    effectID: .metalFXSpatial,
                    scalingType: .fit
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: fsr1ID,
            name: "FSR 1.0",
            nameZH: "FSR 1.0",
            localizedDescription: "EASU edge-adaptive upscaling with RCAS sharpening.",
            descriptionZH: "EASU 边缘自适应超分 + RCAS 抗噪锐化。",
            scenario: .game3D,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
                    effectID: .fsr1EASU,
                    scalingType: .fit
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000003")!,
                    effectID: .fsr1RCAS,
                    scalingType: .normal,
                    parameters: [
                        "sharpness": .float(0.87),
                        "denoise": .bool(true)
                    ]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: fxaaFSR1ID,
            name: "FXAA + FSR 1.0",
            nameZH: "FXAA + FSR 1.0",
            localizedDescription: "FXAA 3.11 edge anti-aliasing followed by FSR 1.0.",
            descriptionZH: "FXAA 3.11 抗锯齿后接 FSR 1.0 超分。",
            scenario: .game3D,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000001F")!,
                    effectID: .fxaa,
                    scalingType: .normal,
                    parameters: [
                        "qualityPreset": .choice("high"),
                        "edgeThreshold": .float(0.125),
                        "subpixelQuality": .float(0.75)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000020")!,
                    effectID: .fsr1EASU,
                    scalingType: .fit
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000021")!,
                    effectID: .fsr1RCAS,
                    scalingType: .normal,
                    parameters: [
                        "sharpness": .float(0.85),
                        "denoise": .bool(true)
                    ]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: sgsrID,
            name: "SGSR",
            nameZH: "SGSR",
            localizedDescription: "Single-pass edge-directed upscaling for low GPU load.",
            descriptionZH: "单通道轻量边缘超分，GPU 占用低。",
            scenario: .game3D,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000008")!,
                    effectID: .sgsr,
                    scalingType: .fit,
                    parameters: [
                        "edgeSharpness": .float(2.0),
                        "edgeThreshold": .float(8.0)
                    ]
                )
            ],
            isBuiltIn: true
        ),

        // MARK: - Anime & 2D (6 Official bloc97 Anime4K v4.0.1 Modes + CuNNy + FSRCNNX)
        ScalingMode(
            id: anime4kModeAID,
            name: "Anime4K Mode A",
            nameZH: "Anime4K Mode A",
            localizedDescription: "General line restoration and 2× neural upscaling.",
            descriptionZH: "通用修复，适合多数 1080p 动画。",
            scenario: .anime,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000010")!,
                    effectID: .anime4kRestore,
                    scalingType: .normal,
                    parameters: [
                        "variant": .choice("L"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000011")!,
                    effectID: .anime4kUpscale,
                    scalingType: .fit,
                    parameters: [
                        "variant": .choice("L"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000012")!,
                    effectID: .anime4kClampHighlights,
                    scalingType: .normal
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: anime4kModeBID,
            name: "Anime4K Mode B",
            nameZH: "Anime4K Mode B",
            localizedDescription: "Soft restoration and denoising for 720p sources.",
            descriptionZH: "柔和降噪，适合 720p 或柔和画风动画。",
            scenario: .anime,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000013")!,
                    effectID: .anime4kRestore,
                    scalingType: .normal,
                    parameters: [
                        "variant": .choice("softL"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000014")!,
                    effectID: .anime4kUpscaleDenoise,
                    scalingType: .fit,
                    parameters: [
                        "variant": .choice("L"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000015")!,
                    effectID: .anime4kClampHighlights,
                    scalingType: .normal
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: anime4kModeCID,
            name: "Anime4K Mode C",
            nameZH: "Anime4K Mode C",
            localizedDescription: "Pure 2× neural upscaling for clean high-bitrate sources.",
            descriptionZH: "纯净放大，适合高码率原盘片源。",
            scenario: .anime,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000016")!,
                    effectID: .anime4kUpscaleDenoise,
                    scalingType: .fit,
                    parameters: [
                        "variant": .choice("L"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000017")!,
                    effectID: .anime4kClampHighlights,
                    scalingType: .normal
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: anime4kModeAAID,
            name: "Anime4K Mode A+A",
            nameZH: "Anime4K Mode A+A",
            localizedDescription: "Two-pass restoration for blurry or low-bitrate anime.",
            descriptionZH: "双倍修复，适合模糊或低码率动画。",
            scenario: .anime,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000018")!,
                    effectID: .anime4kRestore,
                    scalingType: .normal,
                    parameters: [
                        "variant": .choice("L"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000019")!,
                    effectID: .anime4kUpscale,
                    scalingType: .fit,
                    parameters: [
                        "variant": .choice("L"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000001A")!,
                    effectID: .anime4kRestore,
                    scalingType: .normal,
                    parameters: [
                        "variant": .choice("M"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000024")!,
                    effectID: .anime4kClampHighlights,
                    scalingType: .normal
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: anime4kModeBBID,
            name: "Anime4K Mode B+B",
            nameZH: "Anime4K Mode B+B",
            localizedDescription: "Two-pass soft restoration and denoise for older sources.",
            descriptionZH: "双倍降噪，适合老番或 720p 流媒体。",
            scenario: .anime,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000025")!,
                    effectID: .anime4kRestore,
                    scalingType: .normal,
                    parameters: [
                        "variant": .choice("softL"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000026")!,
                    effectID: .anime4kUpscaleDenoise,
                    scalingType: .fit,
                    parameters: [
                        "variant": .choice("L"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000027")!,
                    effectID: .anime4kRestore,
                    scalingType: .normal,
                    parameters: [
                        "variant": .choice("softM"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000028")!,
                    effectID: .anime4kClampHighlights,
                    scalingType: .normal
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: anime4kModeCAID,
            name: "Anime4K Mode C+A",
            nameZH: "Anime4K Mode C+A",
            localizedDescription: "Pure 2× upscaling followed by light line refinement.",
            descriptionZH: "原盘精修，纯净放大后轻度修复线条。",
            scenario: .anime,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000029")!,
                    effectID: .anime4kUpscaleDenoise,
                    scalingType: .fit,
                    parameters: [
                        "variant": .choice("L"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000002A")!,
                    effectID: .anime4kRestore,
                    scalingType: .normal,
                    parameters: [
                        "variant": .choice("M"),
                        "clampHighlights": .bool(true)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000002B")!,
                    effectID: .anime4kClampHighlights,
                    scalingType: .normal
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: cunnyAnimeID,
            name: "CuNNy 2×",
            nameZH: "CuNNy 2×",
            localizedDescription: "Compact 2× neural upscaler for anime and 2D games.",
            descriptionZH: "轻量 2× 神经网络超分，适合动漫与 2D 游戏。",
            scenario: .anime,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000001B")!,
                    effectID: .cunny,
                    scalingType: .fit,
                    parameters: [
                        "variant": .choice("balanced"),
                        "sharpness": .float(1.0)
                    ]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: fsrcnnxID,
            name: "FSRCNNX 2×",
            nameZH: "FSRCNNX 2×",
            localizedDescription: "6-pass 2× convolutional neural upscaler.",
            descriptionZH: "6 通道 2× 卷积神经网络超分。",
            scenario: .anime,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000007")!,
                    effectID: .fsrcnnx,
                    scalingType: .fit,
                    parameters: [
                        "variant": .choice("standard"),
                        "sharpness": .float(1.0),
                        "antiRinging": .float(0.35)
                    ]
                )
            ],
            isBuiltIn: true
        ),

        // MARK: - Pixel Art & Retro CRT
        ScalingMode(
            id: integerScaleID,
            name: "Integer Scale",
            nameZH: "整数缩放",
            localizedDescription: "Exact whole-number nearest-neighbor pixel scaling.",
            descriptionZH: "整数倍点采样，无模糊、无畸变。",
            scenario: .pixelRetro,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000000A")!,
                    effectID: .nearest,
                    scalingType: .integerFit
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: sharpBilinearID,
            name: "Sharp Bilinear",
            nameZH: "锐利双线性",
            localizedDescription: "Shimmer-free crisp pixel scaling at non-integer ratios.",
            descriptionZH: "非整数倍像素缩放，消除滚动闪烁。",
            scenario: .pixelRetro,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000000B")!,
                    effectID: .sharpBilinear,
                    scalingType: .fit,
                    parameters: ["sharpness": .float(1.0)]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: xbrzID,
            name: "xBRZ",
            nameZH: "xBRZ",
            localizedDescription: "Perceptual vector edge-smoothing for pixel art.",
            descriptionZH: "感知矢量像素平滑，支持任意倍率。",
            scenario: .pixelRetro,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000009")!,
                    effectID: .xbrzFreescale,
                    scalingType: .fit,
                    parameters: [
                        "equalColorTolerance": .float(30.0),
                        "edgeThreshold": .float(2.2),
                        "dominantDirectionThreshold": .float(3.6)
                    ]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: crtGeomID,
            name: "CRT-Geom",
            nameZH: "CRT-Geom",
            localizedDescription: "CRT scanlines, phosphor mask, halation, and optional curvature.",
            descriptionZH: "经典 CRT 模拟，含扫描线、荧光掩膜与辉光。",
            scenario: .pixelRetro,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000000C")!,
                    effectID: .crtGeom,
                    scalingType: .fit,
                    parameters: [
                        "curvature": .bool(false),
                        "curvatureRadius": .float(2.0),
                        "crtGamma": .float(1.8),
                        "monitorGamma": .float(2.2),
                        "scanlineWeight": .float(0.3),
                        "maskType": .choice("apertureGrille"),
                        "dotMask": .float(0.3),
                        "halation": .float(0.15),
                        "vignette": .float(0.15),
                        "brightness": .float(1.05),
                        "cornerSize": .float(0.005)
                    ]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: crtLottesArcadeID,
            name: "CRT-Lottes",
            nameZH: "CRT-Lottes",
            localizedDescription: "High-contrast arcade CRT with Gaussian scanlines and shadow mask.",
            descriptionZH: "高对比度街机 CRT，含高斯扫描线与阴影掩膜。",
            scenario: .pixelRetro,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000023")!,
                    effectID: .crtLottes,
                    scalingType: .fit,
                    parameters: [
                        "hardScan": .float(-8.0),
                        "hardPix": .float(-3.0),
                        "warpX": .float(0.02),
                        "warpY": .float(0.03),
                        "shadowMask": .choice("apertureGrille"),
                        "brightBoost": .float(1.1),
                        "maskDark": .float(0.5),
                        "maskLight": .float(1.5)
                    ]
                )
            ],
            isBuiltIn: true
        ),

        // MARK: - General & Video
        ScalingMode(
            id: lanczos6ID,
            name: "Lanczos6",
            nameZH: "Lanczos6",
            localizedDescription: "6-tap Lanczos filter with anti-ringing for UI, text, and video.",
            descriptionZH: "6 点抗振铃滤波，适合文字、UI 与常规视频。",
            scenario: .generalVideo,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000005")!,
                    effectID: .lanczos6,
                    scalingType: .fit,
                    parameters: [
                        "antiRinging": .float(0.5),
                        "sharpness": .float(1.0)
                    ]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: jincVideoID,
            name: "Jinc",
            nameZH: "Jinc",
            localizedDescription: "2D circular EWA Lanczos filter for smooth diagonals and video.",
            descriptionZH: "2D 圆形对称滤波，斜线平滑，适合视频内容。",
            scenario: .generalVideo,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000022")!,
                    effectID: .jinc,
                    scalingType: .fit,
                    parameters: [
                        "windowSinc": .float(0.5),
                        "sinc": .float(0.825),
                        "antiRinging": .float(0.5)
                    ]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: bicubicCASID,
            name: "Bicubic + CAS",
            nameZH: "Bicubic + CAS",
            localizedDescription: "Catmull-Rom cubic scaling paired with contrast-adaptive sharpening.",
            descriptionZH: "Catmull-Rom 双三次插值 + CAS 自适应锐化。",
            scenario: .generalVideo,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000000D")!,
                    effectID: .bicubic,
                    scalingType: .fit,
                    parameters: [
                        "b": .float(0.0),
                        "c": .float(0.5)
                    ]
                ),
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000000E")!,
                    effectID: .cas,
                    scalingType: .normal,
                    parameters: ["sharpness": .float(0.4)]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: appleMLSuperResID,
            name: "Apple ML Super Resolution",
            nameZH: "Apple ML 超分",
            localizedDescription: "VideoToolbox Neural Engine super resolution (macOS 26+).",
            descriptionZH: "VideoToolbox 神经网络引擎超分（需 macOS 26+）。",
            scenario: .generalVideo,
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000004")!,
                    effectID: .vtSuperResolution,
                    scalingType: .fit,
                    parameters: ["scaleFactor": .choice("2.0")]
                )
            ],
            isBuiltIn: true
        )
    ]

    /// Returns all built-in presets matching a specific scenario tab.
    public static func builtInPresets(for scenario: ScenarioTag) -> [ScalingMode] {
        builtInPresets.filter { $0.scenario == scenario }
    }

    public static var defaultMode: ScalingMode {
        builtInPresets[0]
    }
}
