import Foundation

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
    public var localizedDescription: String
    public var effects: [EffectInstance]
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        localizedDescription: String = "",
        effects: [EffectInstance],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.localizedDescription = localizedDescription
        self.effects = effects
        self.isBuiltIn = isBuiltIn
    }

    // MARK: - Stable Built-In Preset Identifiers

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

    /// Curated built-in presets seeded on first launch.
    public static let builtInPresets: [ScalingMode] = [
        ScalingMode(
            id: metalFXSpatialID,
            name: "MetalFX Spatial",
            localizedDescription: "Apple Silicon hardware spatial upscaling — fast, crisp, and HDR-capable.",
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
            localizedDescription: "AMD FidelityFX Super Resolution 1.0 edge-adaptive upscaling with contrast sharpening.",
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
                    parameters: ["sharpness": .float(0.87)]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: appleMLSuperResID,
            name: "Apple ML Super Resolution",
            localizedDescription: "VideoToolbox low-latency Neural Engine super resolution (macOS 26+).",
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000004")!,
                    effectID: .vtSuperResolution,
                    scalingType: .fit,
                    parameters: ["scaleFactor": .choice("2.0")]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: lanczos6ID,
            name: "Lanczos6 Anti-Ringing",
            localizedDescription: "Balanced 6-tap Lanczos filter with anti-ringing clamp for clean UI and games.",
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000005")!,
                    effectID: .lanczos6,
                    scalingType: .fit,
                    parameters: ["arStrength": .float(0.5)]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: anime4kID,
            name: "Anime4K Upscale & Denoise",
            localizedDescription: "2x neural upscaling and denoising tailored for anime and 2D visual novels.",
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000006")!,
                    effectID: .anime4kUpscaleDenoise,
                    scalingType: .fit,
                    parameters: [
                        "denoiseStrength": .float(0.5),
                        "lineThinning": .float(0.0)
                    ]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: fsrcnnxID,
            name: "FSRCNNX 2× Neural",
            localizedDescription: "Multi-pass 2x convolutional neural upscaler for high-detail artwork and games.",
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000007")!,
                    effectID: .fsrcnnx,
                    scalingType: .fit,
                    parameters: ["variant": .choice("standard")]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: sgsrID,
            name: "SGSR Fast Upscaler",
            localizedDescription: "Single-pass edge-directed upscaler designed for ultra-low GPU power draw.",
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
        ScalingMode(
            id: xbrzID,
            name: "xBRZ Pixel Art",
            localizedDescription: "Vectorized perceptual pixel-art smoothing at arbitrary scale ratios.",
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-000000000009")!,
                    effectID: .xbrzFreescale,
                    scalingType: .fit,
                    parameters: ["equalColorTolerance": .float(30.0)]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: integerScaleID,
            name: "Integer Scale (Crisp Pixels)",
            localizedDescription: "Exact whole-number pixel-perfect scaling using Nearest Neighbor.",
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
            localizedDescription: "Shimmer-free crisp pixel art scaling that fills non-integer display sizes.",
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
            id: crtGeomID,
            name: "CRT-Geom Retro",
            localizedDescription: "Retro CRT scanlines and phosphor dot mask for classic console and arcade games.",
            effects: [
                EffectInstance(
                    id: UUID(uuidString: "20000000-0000-4000-8000-00000000000C")!,
                    effectID: .crtGeom,
                    scalingType: .fit,
                    parameters: [
                        "curvature": .bool(false),
                        "crtGamma": .float(1.8),
                        "monitorGamma": .float(2.2),
                        "scanlineWeight": .float(0.3),
                        "dotMask": .float(0.3),
                        "cornerSize": .float(0.005)
                    ]
                )
            ],
            isBuiltIn: true
        ),
        ScalingMode(
            id: bicubicCASID,
            name: "Bicubic Catmull-Rom + CAS",
            localizedDescription: "Smooth Catmull-Rom cubic interpolation paired with Contrast Adaptive Sharpening.",
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
        )
    ]

    public static var defaultMode: ScalingMode {
        builtInPresets[0]
    }
}
