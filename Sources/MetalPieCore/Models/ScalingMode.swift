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
        case .game3D: return "3D Games"
        case .anime: return "Anime & 2D"
        case .pixelRetro: return "Pixel & Retro"
        case .generalVideo: return "General & Video"
        }
    }

    public var labelZH: String {
        switch self {
        case .game3D: return "3D 游戏"
        case .anime: return "动漫番剧"
        case .pixelRetro: return "像素复古"
        case .generalVideo: return "通用高清"
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
            name: "MetalFX Spatial",
            nameZH: "MetalFX 硬件超分（推荐）",
            localizedDescription: "Apple Silicon hardware spatial upscaling — fast, crisp, and HDR-capable.",
            descriptionZH: "Apple 芯片原生硬件加速超分，速度极快、边缘锐利且完整支持 HDR，3D 游戏首选。",
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
            name: "FSR 1.0 (EASU + RCAS)",
            nameZH: "FSR 1.0 超分锐化 (EASU + RCAS)",
            localizedDescription: "AMD FidelityFX Super Resolution 1.0 edge-adaptive upscaling with noise-aware contrast sharpening.",
            descriptionZH: "AMD 经典 3D 游戏超分搭配抗噪自适应锐化，在各种分辨率比例下都清晰硬朗。",
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
            name: "FXAA + FSR 1.0 (Anti-Aliased 3D)",
            nameZH: "FXAA 抗锯齿 + FSR 1.0 超分",
            localizedDescription: "Smooths jagged 3D edges with FXAA 3.11 first, then upscales cleanly with FSR 1.0.",
            descriptionZH: "先用 FXAA 3.11 抹平老游戏或低分辨率锯齿，再用 FSR 1.0 放大锐化，告别阶梯狗牙。",
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
            name: "SGSR Fast Upscaler",
            nameZH: "SGSR 低功耗快速超分",
            localizedDescription: "Single-pass edge-directed upscaler designed for ultra-low GPU power draw.",
            descriptionZH: "单通道轻量边缘超分，极低 GPU 占用与发热，适合 MacBook 续航模式高帧率游玩。",
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
            name: "Anime4K Mode A (Recommended · Restore)",
            nameZH: "Anime4K Mode A (推荐 · 通用修复)",
            localizedDescription: "Official Mode A: best all-rounder for most blurry or compressed 1080p anime.",
            descriptionZH: "适合大多数 1080p 模糊或有压缩感的番剧，线条清晰利落、一步到位。",
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
            name: "Anime4K Mode B (Soft · Balanced Denoise)",
            nameZH: "Anime4K Mode B (柔和 · 均衡降噪)",
            localizedDescription: "Official Mode B: gentle restoration and denoise tailored for 720p or soft-art anime.",
            descriptionZH: "适合 720p 片源或柔和画风动画，温和降噪的同时保留自然质感。",
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
            name: "Anime4K Mode C (Blu-ray · Pure Upscale)",
            nameZH: "Anime4K Mode C (原盘 · 纯净放大)",
            localizedDescription: "Official Mode C: clean 2× neural upscaling for sharp high-bitrate Blu-ray anime.",
            descriptionZH: "适合本身已很清晰的高码率原盘，纯净放大几乎不改变原始画风。",
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
            name: "Anime4K Mode A+A (Heavy Restore)",
            nameZH: "Anime4K Mode A+A (重度修复)",
            localizedDescription: "Official Mode A+A: two-pass neural restoration for blurry low-bitrate anime.",
            descriptionZH: "适合较糊的低码率番剧，双重神经修复让模糊线条重新锐利清晰。",
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
            name: "Anime4K Mode B+B (Soft Double Restore)",
            nameZH: "Anime4K Mode B+B (柔和双倍修复)",
            localizedDescription: "Official Mode B+B: balances noise cleanup with deeper soft line restoration.",
            descriptionZH: "兼顾降噪与深度线条修复，适合老番或偏柔和的 720p 流媒体片源。",
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
            name: "Anime4K Mode C+A (Blu-ray Refined)",
            nameZH: "Anime4K Mode C+A (原盘精修)",
            localizedDescription: "Official Mode C+A: pure 2× upscaling followed by light line refinement for clean sources.",
            descriptionZH: "高码率片源纯净放大后再做轻度精修，增强线条质感且不失原味。",
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
            name: "CuNNy 2× Neural (Fast Anime & 2D)",
            nameZH: "CuNNy 2× 轻量神经超分",
            localizedDescription: "Magpie's crisp, low-artifact CuNNy2 2× neural upscaler for anime, visual novels, and 2D games.",
            descriptionZH: "Magpie 广受好评的 CuNNy2 轻量级神经网络超分，画面干净通透、不涂抹文字，Galgame 绝配。",
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
            name: "FSRCNNX 2× Neural",
            nameZH: "FSRCNNX 2× 神经网络",
            localizedDescription: "Multi-pass 2× convolutional neural upscaler for high-detail artwork, anime, and games.",
            descriptionZH: "经典 6 通道 2× 卷积神经网络超分，细节还原自然扎实，兼容写实与二次元画面。",
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
            name: "Integer Scale (Crisp Pixels)",
            nameZH: "整数倍原味像素缩放",
            localizedDescription: "Exact whole-number pixel-perfect scaling using Nearest Neighbor.",
            descriptionZH: "按整数倍无损放大每个像素，零模糊、零畸变，原汁原味呈现复古像素风。",
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
            nameZH: "锐利双线性（全屏防闪烁）",
            localizedDescription: "Shimmer-free crisp pixel art scaling that fills non-integer display sizes.",
            descriptionZH: "无需留黑边即可铺满屏幕，同时保持像素颗粒锐利且滚动画面零波纹闪烁。",
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
            name: "xBRZ Pixel Art",
            nameZH: "xBRZ 矢量像素平滑",
            localizedDescription: "Vectorized perceptual pixel-art smoothing at arbitrary scale ratios.",
            descriptionZH: "自动识别像素斜边并圆滑成手绘矢量风格，适合 GBA/SNES/RPG Maker 等经典游戏。",
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
            name: "CRT-Geom Retro",
            nameZH: "CRT-Geom 经典显像管",
            localizedDescription: "Retro CRT scanlines, phosphor aperture grille, halation, and optional curvature.",
            descriptionZH: "经典家用机彩电与监视器 CRT 模拟，带有柔和扫描线、荧光点栅与微弱光晕。",
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
            name: "CRT-Lottes Arcade",
            nameZH: "CRT-Lottes 街机显像管",
            localizedDescription: "High-contrast arcade CRT shader with sharp Gaussian scanlines, subtle warp, and phosphor bloom.",
            descriptionZH: "高对比度街机显像管滤镜，呈现凌厉扫描线、轻微弧度与鲜艳荧光粉光束。",
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
            name: "Lanczos6 Anti-Ringing",
            nameZH: "Lanczos6 抗振铃（文字/通用）",
            localizedDescription: "Balanced 6-tap Lanczos filter with anti-ringing clamp for clean UI, text, and video.",
            descriptionZH: "6 点可分离抗振铃滤波，文字界面与普通视频清晰锐利且极少白边，通用场景稳妥之选。",
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
            name: "Jinc EWA Lanczos (Smooth Video & Text)",
            nameZH: "Jinc 圆形滤波（高清视频）",
            localizedDescription: "Circular 2D EWA Jinc filter for natural diagonal curves in movies, streams, and UI.",
            descriptionZH: "2D 圆形对称高精滤波，消除斜线阶梯锯齿，观看电影、网课和高清直播观感极佳。",
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
            name: "Bicubic Catmull-Rom + CAS",
            nameZH: "双三次插值 + CAS 锐化",
            localizedDescription: "Smooth Catmull-Rom cubic interpolation paired with Contrast Adaptive Sharpening.",
            descriptionZH: "平滑双三次放大结合 CAS 温和锐化，兼顾流畅观感与清晰细节，适合视频与浏览器窗口。",
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
            nameZH: "Apple 神经引擎超分",
            localizedDescription: "VideoToolbox low-latency Neural Engine super resolution (macOS 26+).",
            descriptionZH: "使用苹果神经引擎进行低延迟 AI 超分（macOS 26+ 专享），低分辨率视频与窗口放大效果出众。",
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
