import CoreGraphics
import Foundation
import Testing
@testable import MetalPieCore

@Suite("ConfigStore, EffectCatalog, ProfileMatcher & PipelineLog")
struct ConfigStoreAndCatalogTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetalPieCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("EffectCatalog covers all 30 EffectIDs, Chinese UX descriptions, ScenarioTags, and 21 presets")
    func effectCatalogCompleteness() {
        #expect(EffectID.allCases.count == 30)
        #expect(EffectCatalog.all.count == 30)

        for id in EffectID.allCases {
            let desc = EffectCatalog.descriptor(for: id)
            #expect(desc.id == id)
            #expect(!desc.nameEN.isEmpty)
            #expect(!desc.nameZH.isEmpty)
            #expect(!desc.summaryEN.isEmpty)
            #expect(!desc.summaryZH.isEmpty)
            #expect(desc.displayNameEN == desc.nameEN)
            #expect(desc.displayNameZH == desc.nameZH)
            #expect(desc.descriptionEN == desc.summaryEN)
            #expect(desc.descriptionZH == desc.summaryZH)
            #expect(!desc.localizedDescription.isEmpty)
            for param in desc.parameters {
                #expect(!param.labelEN.isEmpty)
                #expect(!param.labelZH.isEmpty)
                #expect(!param.descriptionEN.isEmpty)
                #expect(!param.descriptionZH.isEmpty)
                #expect(param.displayNameZH == param.labelZH)
                #expect(!param.localizedDescription.isEmpty)
                switch param.kind {
                case .float(let def, let minVal, let maxVal, let step):
                    #expect(def >= minVal && def <= maxVal)
                    #expect(step > 0)
                case .int(let def, let minVal, let maxVal, let step):
                    #expect(def >= minVal && def <= maxVal)
                    #expect(step > 0)
                case .bool:
                    break
                case .choice(let def, let options):
                    let hasDefaultOption = options.contains { $0.value == def }
                    #expect(hasDefaultOption)
                    for opt in options {
                        #expect(!opt.labelEN.isEmpty)
                        #expect(!opt.labelZH.isEmpty)
                    }
                }
            }
        }

        // All 21 built-in ScalingMode presets exist with unique stable IDs, Chinese labels, and ScenarioTags
        #expect(ScalingMode.builtInPresets.count == 21)
        #expect(Set(ScalingMode.builtInPresets.map(\.id)).count == 21)
        #expect(ScalingMode.defaultMode.id == ScalingMode.metalFXSpatialID)
        #expect(ScalingMode.anime4kModeAID == ScalingMode.anime4kID)

        for preset in ScalingMode.builtInPresets {
            #expect(!preset.name.isEmpty)
            #expect(!preset.nameZH.isEmpty)
            #expect(!preset.localizedDescription.isEmpty)
            #expect(!preset.descriptionZH.isEmpty)
            #expect(!preset.displayName(isChinese: true).isEmpty)
            #expect(!preset.displayDescription(isChinese: true).isEmpty)
        }

        // Verify all 4 ScenarioTag tabs have presets and plain-Chinese labels
        #expect(ScenarioTag.allCases.count == 4)
        for tag in ScenarioTag.allCases {
            #expect(!tag.labelEN.isEmpty)
            #expect(!tag.labelZH.isEmpty)
            #expect(!tag.symbolName.isEmpty)
            #expect(ScalingMode.builtInPresets(for: tag).count >= 2)
        }

        // Verify the 6 official Anime4K v4 modes (A, B, C, A+A, B+B, C+A) and Magpie flagship presets exist
        let presetIDs = Set(ScalingMode.builtInPresets.map(\.id))
        #expect(presetIDs.contains(ScalingMode.anime4kModeAID))
        #expect(presetIDs.contains(ScalingMode.anime4kModeBID))
        #expect(presetIDs.contains(ScalingMode.anime4kModeCID))
        #expect(presetIDs.contains(ScalingMode.anime4kModeAAID))
        #expect(presetIDs.contains(ScalingMode.anime4kModeBBID))
        #expect(presetIDs.contains(ScalingMode.anime4kModeCAID))
        #expect(presetIDs.contains(ScalingMode.cunnyAnimeID))
        #expect(presetIDs.contains(ScalingMode.fxaaFSR1ID))
        #expect(presetIDs.contains(ScalingMode.jincVideoID))
        #expect(presetIDs.contains(ScalingMode.crtLottesArcadeID))

        // Verify Anime4K user-facing configuration stays clean and concise (no intimidating low-level knobs)
        #expect(EffectCatalog.descriptor(for: .anime4kRestore).parameters.count <= 2)
        #expect(EffectCatalog.descriptor(for: .anime4kUpscale).parameters.count <= 2)
        #expect(EffectCatalog.descriptor(for: .anime4kUpscaleDenoise).parameters.count <= 2)
        #expect(EffectCatalog.descriptor(for: .anime4kClampHighlights).parameters.isEmpty)
    }

    @Test("ConfigStore atomic round-trip persistence")
    func configStoreRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: configURL, logger: PipelineLog(maxEntries: 50))

        // First load seeds default config
        let initial = store.loadResult()
        #expect(initial.status == .createdDefault)
        #expect(initial.config.schemaVersion == AppConfig.currentSchemaVersion)
        let initialHasDefault = initial.config.profiles.contains(where: \.isDefault)
        #expect(initialHasDefault)
        #expect(initial.config.scalingModes.count == 21)
        #expect(initial.config.hotkeys.panicStop == HotkeyBinding.panicStop)

        // Customize config and save atomically
        var custom = initial.config
        custom.countdownSeconds = 5
        custom.language = .zhHans
        custom.launchAtLogin = true
        custom.profiles.append(
            Profile(
                name: "Hollow Knight",
                bundleIdentifier: "unity.Team Cherry.Hollow Knight",
                windowTitlePattern: "Hollow.*",
                scalingModeID: ScalingMode.fsr1ID,
                presentationMode: .windowed(initialScale: 1.5, width: 1920),
                outputAlignment: .topLeft,
                crop: CropInsets(enabled: true, left: 0, top: 28, right: 0, bottom: 0),
                capture: CaptureSettings(dynamicRange: .hdr, frameRateLimit: 120, duplicateFrameMode: .never),
                frameGen: FrameGenSettings(enabled: true, multiplier: .x2, backend: .videoToolboxML),
                autoScaleMode: .fullscreen,
                threeDGameMode: true,
                toolbarMode: .alwaysShow,
                showProfilerHUD: true
            )
        )

        try store.save(custom)
        #expect(FileManager.default.fileExists(atPath: configURL.path))

        let reloaded = store.loadResult()
        #expect(reloaded.status == .loaded)
        #expect(reloaded.config == custom)
    }

    @Test("ConfigStore recovers gracefully from corrupted JSON and backs up corrupt file")
    func configStoreCorruptionFallback() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("config.json")
        try "{ not valid json !!!".write(to: configURL, atomically: true, encoding: .utf8)

        let log = PipelineLog(maxEntries: 50)
        let store = ConfigStore(fileURL: configURL, logger: log)
        let result = store.loadResult()

        guard case .recoveredFromCorruption(let backupURL) = result.status else {
            Issue.record("Expected .recoveredFromCorruption, got \(result.status)")
            return
        }
        #expect(backupURL != nil)
        if let backupURL {
            #expect(FileManager.default.fileExists(atPath: backupURL.path))
        }
        #expect(result.config.schemaVersion == AppConfig.currentSchemaVersion)
        let recoveredHasDefault = result.config.profiles.contains(where: \.isDefault)
        #expect(recoveredHasDefault)
        #expect(result.config.scalingModes.count == 21)
        #expect(log.entries(minimumLevel: .error).count == 1)
    }

    @Test("ConfigStore backwards-compatibly upgrades v1.0 configs, migrates legacy keys, and seeds new presets")
    func legacyV1ConfigBackwardsCompatibilityAndPresetSeeding() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("config.json")
        let customID = UUID()

        // Encode a real AppConfig with only 1 old built-in mode + 1 custom mode, then strip
        // newly added v1.1 fields (`nameZH`, `descriptionZH`, `scenario`) to simulate an authentic v1.0 file.
        var base = AppConfig.defaultConfig
        base.scalingModes = [
            ScalingMode(
                id: ScalingMode.anime4kID,
                name: "Anime4K 2x",
                localizedDescription: "Legacy Anime4K",
                effects: [
                    EffectInstance(
                        effectID: .anime4kRestore,
                        scalingType: .normal,
                        parameters: ["strength": .float(0.72)]
                    )
                ],
                isBuiltIn: true
            ),
            ScalingMode(
                id: customID,
                name: "My Legacy Custom Chain",
                localizedDescription: "User custom preset",
                effects: [
                    EffectInstance(
                        effectID: .lanczos6,
                        scalingType: .fit,
                        parameters: ["arStrength": .float(0.65)]
                    ),
                    EffectInstance(
                        effectID: .crtGeom,
                        scalingType: .normal,
                        parameters: ["bloom": .float(0.28)]
                    )
                ],
                isBuiltIn: false
            )
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rawData = try encoder.encode(base)
        var jsonObj = try #require(JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        if var modes = jsonObj["scalingModes"] as? [[String: Any]] {
            for i in modes.indices {
                modes[i].removeValue(forKey: "nameZH")
                modes[i].removeValue(forKey: "descriptionZH")
                modes[i].removeValue(forKey: "scenario")
            }
            jsonObj["scalingModes"] = modes
        }
        let legacyData = try JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted])
        try legacyData.write(to: configURL, options: [.atomic])

        let store = ConfigStore(fileURL: configURL, logger: PipelineLog(maxEntries: 50))
        let result = store.loadResult()
        #expect(result.status == .loaded)

        // All 21 built-in presets + 1 user custom preset = 22 total
        #expect(result.config.scalingModes.count == 22)

        // Built-in Anime4K preset kept user's strength=0.72 while backfilling Chinese metadata, scenario, variant, clampHighlights
        let animeMode = try #require(result.config.scalingModes.first { $0.id == ScalingMode.anime4kID })
        #expect(animeMode.scenario == .anime)
        #expect(!animeMode.nameZH.isEmpty)
        #expect(!animeMode.descriptionZH.isEmpty)
        #expect(animeMode.effects[0].parameters["strength"]?.floatValue == 0.72)
        #expect(animeMode.effects[0].parameters["variant"]?.choiceValue != nil)
        #expect(animeMode.effects[0].parameters["clampHighlights"]?.boolValue == true)

        // All 6 official Anime4K modes + CuNNy + FXAA presets were seamlessly seeded
        let loadedIDs = Set(result.config.scalingModes.map(\.id))
        #expect(loadedIDs.contains(ScalingMode.anime4kModeAID))
        #expect(loadedIDs.contains(ScalingMode.anime4kModeBID))
        #expect(loadedIDs.contains(ScalingMode.anime4kModeCID))
        #expect(loadedIDs.contains(ScalingMode.anime4kModeAAID))
        #expect(loadedIDs.contains(ScalingMode.anime4kModeBBID))
        #expect(loadedIDs.contains(ScalingMode.anime4kModeCAID))
        #expect(loadedIDs.contains(ScalingMode.cunnyAnimeID))
        #expect(loadedIDs.contains(ScalingMode.fxaaFSR1ID))

        // User's custom preset preserved and legacy parameter keys migrated cleanly
        let userMode = try #require(result.config.scalingModes.first { $0.id == customID })
        #expect(userMode.isBuiltIn == false)
        #expect(userMode.effects[0].parameters["antiRinging"]?.floatValue == 0.65)
        #expect(userMode.effects[0].parameters["sharpness"]?.floatValue == 1.0)
        #expect(userMode.effects[1].parameters["halation"]?.floatValue == 0.28)
        #expect(userMode.effects[1].parameters["maskType"]?.choiceValue == "apertureGrille")
    }

    @Test("ConfigStore invokes schema migration hook for older schema versions")
    func configStoreSchemaMigration() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("config.json")
        var legacy = AppConfig.defaultConfig
        legacy.schemaVersion = 0
        legacy.countdownSeconds = 4

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: configURL, options: [.atomic])

        let store = ConfigStore(fileURL: configURL, logger: PipelineLog(maxEntries: 50)) { rawData, fromVersion in
            #expect(fromVersion == 0)
            var obj = try JSONSerialization.jsonObject(with: rawData) as! [String: Any]
            obj["schemaVersion"] = AppConfig.currentSchemaVersion
            obj["countdownSeconds"] = 6
            return try JSONSerialization.data(withJSONObject: obj)
        }

        let result = store.loadResult()
        #expect(result.status == .migrated(fromVersion: 0, toVersion: AppConfig.currentSchemaVersion))
        #expect(result.config.schemaVersion == AppConfig.currentSchemaVersion)
        #expect(result.config.countdownSeconds == 6)
    }

    @Test("ScalingMode JSON export and import round-trip")
    func scalingModeExportImport() throws {
        let store = ConfigStore(logger: PipelineLog(maxEntries: 20))
        let customMode = ScalingMode(
            name: "Retro Anime Combo",
            localizedDescription: "Anime4K Restore + Lanczos6 + CAS",
            effects: [
                EffectInstance(effectID: .anime4kRestore, scalingType: .normal, parameters: ["strength": .float(0.8)]),
                EffectInstance(effectID: .lanczos6, scalingType: .fit, parameters: ["arStrength": .float(0.6)]),
                EffectInstance(effectID: .cas, scalingType: .normal, parameters: ["sharpness": .float(0.35)])
            ],
            isBuiltIn: false
        )

        // Bundle round-trip
        let exported = try store.exportScalingModes([customMode])
        let imported = try store.importScalingModes(from: exported)
        #expect(imported == [customMode])

        // Single-object JSON import
        let singleEncoder = JSONEncoder()
        singleEncoder.dateEncodingStrategy = .iso8601
        let singleData = try singleEncoder.encode(customMode)
        let importedSingle = try store.importScalingModes(from: singleData)
        #expect(importedSingle == [customMode])

        // Regenerated IDs
        let regenerated = try store.importScalingModes(from: exported, regenerateIDs: true)
        #expect(regenerated.count == 1)
        #expect(regenerated[0].id != customMode.id)
        #expect(regenerated[0].name == customMode.name)
        #expect(regenerated[0].isBuiltIn == false)
    }

    @Test("ProfileMatcher resolves bundleID + title regex specificity and default fallback")
    func profileMatchingRules() {
        let defaultProf = Profile.defaultProfile
        let retroCatchAll = Profile(
            name: "RetroArch General",
            bundleIdentifier: "com.libretro.RetroArch",
            scalingModeID: ScalingMode.integerScaleID
        )
        let retroSNES = Profile(
            name: "RetroArch SNES CRT",
            bundleIdentifier: "com.libretro.RetroArch",
            windowTitlePattern: "bsnes|Snes9x",
            scalingModeID: ScalingMode.crtGeomID
        )
        let invalidRegexProfile = Profile(
            name: "Literal Bracket Game",
            bundleIdentifier: "com.example.game",
            windowTitlePattern: "[Demo Build",
            scalingModeID: ScalingMode.fsr1ID
        )
        let pathOnlyProfile = Profile(
            name: "Wine Game",
            appPath: "/Applications/CrossOver.app/Contents/MacOS/CrossOver",
            scalingModeID: ScalingMode.sgsrID
        )

        let profiles = [defaultProf, retroCatchAll, retroSNES, invalidRegexProfile, pathOnlyProfile]

        // BundleID + title regex beats bundleID-only catch-all even when listed after it
        let snesWindow = WindowDescriptor(
            windowID: 101,
            pid: 500,
            appName: "RetroArch",
            bundleIdentifier: "COM.LIBRETRO.RETROARCH", // case-insensitive
            title: "RetroArch Snes9x - Chrono Trigger",
            cgBounds: CGRect(x: 0, y: 0, width: 1024, height: 896)
        )
        #expect(ProfileMatcher.match(window: snesWindow, profiles: profiles).id == retroSNES.id)

        // BundleID-only match when title doesn't match regex
        let gbaWindow = WindowDescriptor(
            windowID: 102,
            pid: 500,
            appName: "RetroArch",
            bundleIdentifier: "com.libretro.RetroArch",
            title: "RetroArch mGBA - Metroid Fusion",
            cgBounds: CGRect(x: 0, y: 0, width: 960, height: 640)
        )
        #expect(ProfileMatcher.match(window: gbaWindow, profiles: profiles).id == retroCatchAll.id)

        // Invalid regex pattern falls back safely to case-insensitive substring match
        let bracketWindow = WindowDescriptor(
            windowID: 103,
            pid: 501,
            appName: "ExampleGame",
            bundleIdentifier: "com.example.game",
            title: "My Game [demo build v1]",
            cgBounds: CGRect(x: 0, y: 0, width: 1280, height: 720)
        )
        #expect(ProfileMatcher.match(window: bracketWindow, profiles: profiles).id == invalidRegexProfile.id)

        // AppPath fallback match
        let wineWindow = WindowDescriptor(
            windowID: 104,
            pid: 502,
            appName: "CrossOver",
            appPath: "/Applications/CrossOver.app/Contents/MacOS/CrossOver",
            title: "DirectX Window",
            cgBounds: CGRect(x: 0, y: 0, width: 1280, height: 720)
        )
        #expect(ProfileMatcher.match(window: wineWindow, profiles: profiles).id == pathOnlyProfile.id)

        // Unmatched app falls back to default profile
        let unknownWindow = WindowDescriptor(
            windowID: 105,
            pid: 503,
            appName: "UnknownApp",
            bundleIdentifier: "com.unknown.app",
            title: "Hello",
            cgBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        #expect(ProfileMatcher.match(window: unknownWindow, profiles: profiles).id == defaultProf.id)

        // System process auto-scale exclusions
        let config = AppConfig.defaultConfig
        #expect(config.isExcludedFromAutoScale(bundleIdentifier: "com.apple.dock"))
        #expect(config.isExcludedFromAutoScale(bundleIdentifier: "com.apple.WindowServer"))
        #expect(config.isExcludedFromAutoScale(bundleIdentifier: "com.metalpie.app"))
        #expect(!config.isExcludedFromAutoScale(bundleIdentifier: "com.libretro.RetroArch"))
    }

    @Test("PipelineLog ring buffer wraps cleanly and filters by level/category")
    func pipelineLogRingBuffer() {
        let log = PipelineLog(maxEntries: 3)
        log.debug(.capture, "m1")
        log.info(.render, "m2")
        log.warning(.shader, "m3")
        log.error(.input, "m4") // evicts m1

        #expect(log.count == 3)
        #expect(log.entries().map(\.message) == ["m2", "m3", "m4"])
        #expect(log.entries(minimumLevel: .warning).map(\.message) == ["m3", "m4"])
        #expect(log.entries(category: .shader).map(\.message) == ["m3"])

        let exported = log.formattedExport(minimumLevel: .warning)
        #expect(exported.contains("[WARN] [shader] m3"))
        #expect(exported.contains("[ERROR] [input] m4"))
        #expect(!exported.contains("m2"))
    }
}
