import CoreGraphics
import Foundation
import Testing

@testable import MetalPieCore
@testable import MetalPieCapture

@Suite("ConfigStore & Profile Plumbing Regression")
struct ConfigAndProfilePlumbingTests {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetalPieIntegration_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Create, edit, duplicate profiles and custom scaling modes persist atomically, survive reload, export/import JSON, and plumb into RenderSessionConfiguration")
    func fullConfigLifecycleAndRenderPlumbing() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: configURL)

        // 1. First load seeds defaults cleanly
        let initial = store.loadResult()
        #expect(initial.status == .createdDefault)
        var config = initial.config
        #expect(config.scalingModes.count >= ScalingMode.builtInPresets.count)
        let hasInitialDefault = config.profiles.contains(where: \.isDefault)
        #expect(hasInitialDefault)

        // 2. Create a custom multi-pass ScalingMode (FSR_EASU -> ImageAdjustment -> CAS)
        let customMode = ScalingMode(
            name: "Custom Crisp HDR Chain",
            localizedDescription: "FSR EASU + Color Boost + CAS",
            effects: [
                EffectInstance(effectID: .fsr1EASU, scalingType: .fit),
                EffectInstance(
                    effectID: .imageAdjustment,
                    scalingType: .normal,
                    parameters: [
                        "gamma": .float(1.05),
                        "brightness": .float(0.02),
                        "contrast": .float(1.12),
                        "saturation": .float(1.15),
                        "vibrance": .float(0.1),
                        "temperature": .float(0.0)
                    ]
                ),
                EffectInstance(
                    effectID: .cas,
                    scalingType: .normal,
                    parameters: ["sharpness": .float(0.62)]
                )
            ],
            isBuiltIn: false
        )
        config.scalingModes.append(customMode)

        // 3. Create, edit, and duplicate per-app Profiles (verifying MetalDuck's discarded-edits bug is impossible!)
        var gameProfile = Profile(
            name: "Cyberpunk (CrossOver)",
            isDefault: false,
            bundleIdentifier: "com.codeweavers.CrossOver",
            windowTitlePattern: "Cyberpunk",
            scalingModeID: customMode.id,
            presentationMode: .fullscreen,
            outputAlignment: .top,
            multiMonitorMode: .closest,
            crop: CropInsets(enabled: true, left: 16, top: 32, right: 16, bottom: 0),
            capture: CaptureSettings(
                captureMode: .window,
                captureTitleBar: false,
                ignoreShadows: true,
                preferredPixelFormat: .rgba16f,
                dynamicRange: .hdr,
                frameRateLimit: 60,
                duplicateFrameMode: .never,
                lowLatencyPresent: false
            ),
            cursor: CursorSettings(
                renderScaledCursor: true,
                cursorScaleMode: .multiplier,
                cursorScaleMultiplier: 1.5,
                interpolation: .nearest,
                confineCursor: true,
                adjustCursorSpeed: true,
                hideOnIdleSeconds: 2.5,
                hideInScreenshots: true,
                respectGameMouseGrab: true
            ),
            frameGen: FrameGenSettings(
                enabled: true,
                multiplier: .x2,
                backend: .auto,
                artifactGuardSensitivity: .strong,
                disableIn3DGameMode: false
            ),
            autoScaleMode: .fullscreen,
            autoScaleDelaySeconds: 1.0,
            threeDGameMode: true,
            toolbarMode: .off,
            showProfilerHUD: true
        )

        // Edit profile after creation
        gameProfile.capture.frameRateLimit = 90
        gameProfile.outputAlignment = .center

        // Duplicate profile for a windowed variant
        var duplicatedProfile = gameProfile
        duplicatedProfile.id = UUID()
        duplicatedProfile.name = "Cyberpunk (Windowed Debug)"
        duplicatedProfile.windowTitlePattern = "Cyberpunk.*Debug"
        duplicatedProfile.presentationMode = .windowed(initialScale: 1.5, width: 1280)
        duplicatedProfile.threeDGameMode = false

        config.profiles.append(contentsOf: [gameProfile, duplicatedProfile])
        config.countdownSeconds = 4
        config.language = .zhHans

        // 4. Persist atomically to disk and reload from a brand-new ConfigStore instance
        try store.save(config)
        #expect(FileManager.default.fileExists(atPath: configURL.path))

        let reloadedStore = ConfigStore(fileURL: configURL)
        let reloadResult = reloadedStore.loadResult()
        #expect(reloadResult.status == .loaded)
        let reloaded = reloadResult.config

        #expect(reloaded.countdownSeconds == 4)
        #expect(reloaded.language == .zhHans)
        let reloadedMode = try #require(reloaded.scalingMode(for: customMode.id))
        #expect(reloadedMode == customMode)

        let reloadedProfile = try #require(reloaded.profiles.first { $0.id == gameProfile.id })
        #expect(reloadedProfile == gameProfile)
        #expect(reloadedProfile.capture.frameRateLimit == 90)
        #expect(reloadedProfile.capture.dynamicRange == .hdr)
        #expect(reloadedProfile.crop == CropInsets(enabled: true, left: 16, top: 32, right: 16, bottom: 0))
        #expect(reloadedProfile.frameGen.enabled == true)
        #expect(reloadedProfile.frameGen.multiplier == .x2)

        let reloadedDup = try #require(reloaded.profiles.first { $0.id == duplicatedProfile.id })
        #expect(reloadedDup.presentationMode == .windowed(initialScale: 1.5, width: 1280))

        // 5. Export & import ScalingModes JSON cleanly (both preserving IDs and regenerating IDs)
        let exportedJSON = try reloadedStore.exportScalingModes([reloadedMode])
        let importedExact = try reloadedStore.importScalingModes(from: exportedJSON, regenerateIDs: false)
        #expect(importedExact == [reloadedMode])

        let importedFresh = try reloadedStore.importScalingModes(from: exportedJSON, regenerateIDs: true)
        #expect(importedFresh.count == 1)
        #expect(importedFresh[0].id != reloadedMode.id)
        #expect(importedFresh[0].isBuiltIn == false)
        #expect(importedFresh[0].effects.map(\.effectID) == [.fsr1EASU, .imageAdjustment, .cas])

        // 6. Plumb matched profile + resolved scaling mode directly into RenderSessionConfiguration & ScalingLayoutCalculator
        let mockWin = WindowDescriptor(
            windowID: 888,
            pid: 8888,
            appName: "CrossOver",
            bundleIdentifier: "com.codeweavers.CrossOver",
            title: "Cyberpunk 2077",
            cgBounds: CGRect(x: 100, y: 100, width: 640, height: 360)
        )
        let matched = reloaded.matchingProfile(for: mockWin)
        #expect(matched.id == gameProfile.id)
        let resolvedMode = reloaded.resolvedScalingMode(for: matched)
        #expect(resolvedMode.id == customMode.id)

        let overlayMetrics = OverlayDrawableMetrics(
            cocoaFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            cgFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            drawablePixelSize: PixelSize(width: 3024, height: 1964),
            backingScaleFactor: 2.0,
            screenMaxFPS: 120.0,
            displayID: 1,
            supportsEDR: true,
            isVRRDirectScanoutActive: false
        )
        let sessionConfig = RenderSessionConfiguration(
            targetWindowName: mockWin.displayName,
            profile: matched,
            scalingMode: resolvedMode,
            overlayMetrics: overlayMetrics
        )

        #expect(sessionConfig.profile.capture.frameRateLimit == 90)
        #expect(sessionConfig.profile.capture.dynamicRange == .hdr)
        #expect(sessionConfig.scalingMode.effects.count == 3)

        let layout = ScalingLayoutCalculator.calculate(
            sourcePixelSize: mockWin.estimatedPixelSize,
            targetPixelSize: sessionConfig.overlayMetrics.drawablePixelSize,
            targetCGRect: sessionConfig.overlayMetrics.cgFrame,
            backingScaleFactor: sessionConfig.overlayMetrics.backingScaleFactor,
            crop: sessionConfig.profile.crop,
            effects: sessionConfig.scalingMode.effects,
            presentationMode: sessionConfig.profile.presentationMode,
            alignment: sessionConfig.profile.outputAlignment
        )
        #expect(layout.croppedSourceRect == PixelRect(x: 16, y: 32, width: 1248, height: 688))
        #expect(layout.effectPasses.map(\.effectID) == [.fsr1EASU, .imageAdjustment, .cas])
        #expect(layout.finalOutputPixelSize.width == 3024)
    }

    @Test("ConfigStore recovers gracefully from corrupt JSON and runs schema migration hook")
    func corruptRecoveryAndSchemaMigration() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptURL = tempDir.appendingPathComponent("corrupt.json")
        try Data("{ invalid json !!!".utf8).write(to: corruptURL)
        let corruptStore = ConfigStore(fileURL: corruptURL)
        let recovered = corruptStore.loadResult()
        if case .recoveredFromCorruption(let backupURL) = recovered.status {
            #expect(backupURL != nil)
            if let backupURL {
                #expect(FileManager.default.fileExists(atPath: backupURL.path))
            }
        } else {
            Issue.record("Expected recoveredFromCorruption status, got \(recovered.status)")
        }
        let hasRecoveredDefault = recovered.config.profiles.contains(where: \.isDefault)
        #expect(hasRecoveredDefault)
        #expect(recovered.config.scalingModes.count >= ScalingMode.builtInPresets.count)

        // Schema v0 -> v1 migration hook
        let oldURL = tempDir.appendingPathComponent("v0.json")
        var v0Config = AppConfig.defaultConfig
        v0Config.schemaVersion = 0
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(v0Config).write(to: oldURL)

        let migratingStore = ConfigStore(fileURL: oldURL) { rawData, fromVersion in
            #expect(fromVersion == 0)
            var json = try #require(try JSONSerialization.jsonObject(with: rawData) as? [String: Any])
            json["schemaVersion"] = AppConfig.currentSchemaVersion
            json["countdownSeconds"] = 5
            return try JSONSerialization.data(withJSONObject: json)
        }
        let migrated = migratingStore.loadResult()
        #expect(migrated.status == .migrated(fromVersion: 0, toVersion: AppConfig.currentSchemaVersion))
        #expect(migrated.config.countdownSeconds == 5)
    }
}
