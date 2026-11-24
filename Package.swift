// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalPie",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MetalPieCore", targets: ["MetalPieCore"]),
        .library(name: "MetalPieShaders", targets: ["MetalPieShaders"]),
        .library(name: "MetalPieCapture", targets: ["MetalPieCapture"]),
        .library(name: "MetalPieInput", targets: ["MetalPieInput"]),
        .executable(name: "MetalPie", targets: ["MetalPieApp"])
    ],
    targets: [
        .target(
            name: "MetalPieCore",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal")
            ]
        ),
        .target(
            name: "MetalPieShaders",
            dependencies: ["MetalPieCore"],
            resources: [
                .copy("Resources/Shaders")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalFX"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .target(
            name: "MetalPieCapture",
            dependencies: ["MetalPieCore", "MetalPieShaders"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalFX"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AppKit")
            ]
        ),
        .target(
            name: "MetalPieInput",
            dependencies: ["MetalPieCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "MetalPieApp",
            dependencies: [
                "MetalPieCore",
                "MetalPieShaders",
                "MetalPieCapture",
                "MetalPieInput"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalFX"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .testTarget(
            name: "MetalPieCoreTests",
            dependencies: ["MetalPieCore"]
        ),
        .testTarget(
            name: "MetalPieShadersTests",
            dependencies: ["MetalPieCore", "MetalPieShaders"]
        ),
        .testTarget(
            name: "MetalPieIntegrationTests",
            dependencies: [
                "MetalPieCore",
                "MetalPieShaders",
                "MetalPieCapture",
                "MetalPieInput"
            ]
        )
    ]
)
