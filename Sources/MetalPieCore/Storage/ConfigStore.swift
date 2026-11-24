import Foundation
import os

/// Describes how `ConfigStore.loadResult()` obtained the returned `AppConfig`.
public enum ConfigLoadStatus: Hashable, Sendable {
    case loaded
    case createdDefault
    case migrated(fromVersion: Int, toVersion: Int)
    case recoveredFromCorruption(backupURL: URL?)
}

/// Outcome returned by `ConfigStore.loadResult()`.
public struct ConfigLoadResult: Hashable, Sendable {
    public var config: AppConfig
    public var status: ConfigLoadStatus

    public init(config: AppConfig, status: ConfigLoadStatus) {
        self.config = config
        self.status = status
    }
}

/// Portable versioned wrapper for exporting and importing `ScalingMode` presets as JSON.
public struct ScalingModeExportBundle: Hashable, Codable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var scalingModes: [ScalingMode]

    public init(
        schemaVersion: Int = AppConfig.currentSchemaVersion,
        exportedAt: Date = Date(),
        scalingModes: [ScalingMode]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.scalingModes = scalingModes
    }
}

/// Thread-safe, atomic JSON persistence store for `AppConfig` with schema migration hooks,
/// corruption recovery, default seeding, and `ScalingMode` import/export.
public final class ConfigStore: Sendable {
    /// Custom migration hook transforming raw JSON data from an older `schemaVersion`
    /// toward `AppConfig.currentSchemaVersion`.
    public typealias MigrationHandler = @Sendable (_ rawData: Data, _ fromVersion: Int) throws -> Data

    public let fileURL: URL
    private let migrationHandler: MigrationHandler?
    private let logger: PipelineLog
    private let ioLock = OSAllocatedUnfairLock()

    public static var defaultConfigURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("MetalPie", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public init(
        fileURL: URL = ConfigStore.defaultConfigURL,
        logger: PipelineLog = .shared,
        migrationHandler: MigrationHandler? = nil
    ) {
        self.fileURL = fileURL
        self.logger = logger
        self.migrationHandler = migrationHandler
    }

    /// Loads `AppConfig` from disk, seeding defaults if missing or safely recovering on corruption.
    public func load() -> AppConfig {
        loadResult().config
    }

    /// Loads `AppConfig` along with diagnostic status describing whether migration or recovery occurred.
    public func loadResult() -> ConfigLoadResult {
        ioLock.withLock {
            let fm = FileManager.default
            guard fm.fileExists(atPath: fileURL.path) else {
                let seeded = Self.normalize(.defaultConfig)
                logger.info(.app, "No existing config at \(fileURL.path); seeding default configuration.")
                return ConfigLoadResult(config: seeded, status: .createdDefault)
            }

            do {
                let rawData = try Data(contentsOf: fileURL)
                let version = Self.inspectSchemaVersion(in: rawData)
                var workingData = rawData
                var migratedFrom: Int? = nil

                if let version, version < AppConfig.currentSchemaVersion {
                    if let handler = migrationHandler {
                        workingData = try handler(rawData, version)
                    } else {
                        workingData = try Self.defaultMigrate(rawData: rawData, fromVersion: version)
                    }
                    migratedFrom = version
                }

                let decoder = Self.makeDecoder()
                var decoded = try decoder.decode(AppConfig.self, from: workingData)
                if migratedFrom != nil {
                    decoded.schemaVersion = AppConfig.currentSchemaVersion
                }
                let normalized = Self.normalize(decoded)

                if let fromVersion = migratedFrom {
                    try? Self.writeAtomically(normalized, to: fileURL)
                    logger.info(.app, "Migrated config schema v\(fromVersion) -> v\(AppConfig.currentSchemaVersion).")
                    return ConfigLoadResult(
                        config: normalized,
                        status: .migrated(fromVersion: fromVersion, toVersion: AppConfig.currentSchemaVersion)
                    )
                }

                return ConfigLoadResult(config: normalized, status: .loaded)
            } catch {
                let backupURL = Self.backupCorruptFile(at: fileURL)
                logger.error(
                    .app,
                    "Failed to decode config at \(fileURL.path): \(error.localizedDescription). Recovered with defaults."
                )
                let fallback = Self.normalize(.defaultConfig)
                return ConfigLoadResult(
                    config: fallback,
                    status: .recoveredFromCorruption(backupURL: backupURL)
                )
            }
        }
    }

    /// Atomically persists `config` to disk (`Data.write(options: .atomic)`).
    public func save(_ config: AppConfig) throws {
        try ioLock.withLock {
            var normalized = Self.normalize(config)
            normalized.schemaVersion = AppConfig.currentSchemaVersion
            try Self.writeAtomically(normalized, to: fileURL)
        }
    }

    /// Exports one or more scaling modes to pretty-printed JSON data.
    public func exportScalingModes(_ modes: [ScalingMode]) throws -> Data {
        let bundle = ScalingModeExportBundle(scalingModes: modes)
        let encoder = Self.makeEncoder()
        return try encoder.encode(bundle)
    }

    /// Imports scaling modes from JSON data (supports `ScalingModeExportBundle`, `[ScalingMode]`,
    /// or a single `ScalingMode` object).
    public func importScalingModes(from data: Data, regenerateIDs: Bool = false) throws -> [ScalingMode] {
        let decoder = Self.makeDecoder()
        let decoded: [ScalingMode]

        if let bundle = try? decoder.decode(ScalingModeExportBundle.self, from: data) {
            decoded = bundle.scalingModes
        } else if let array = try? decoder.decode([ScalingMode].self, from: data) {
            decoded = array
        } else {
            let single = try decoder.decode(ScalingMode.self, from: data)
            decoded = [single]
        }

        guard regenerateIDs else { return decoded }
        return decoded.map { mode in
            var copy = mode
            copy.id = UUID()
            copy.isBuiltIn = false
            copy.effects = mode.effects.map { eff in
                var effCopy = eff
                effCopy.id = UUID()
                return effCopy
            }
            return copy
        }
    }

    // MARK: - Normalization & Migration Helpers

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int?
    }

    private static func inspectSchemaVersion(in data: Data) -> Int? {
        try? JSONDecoder().decode(SchemaHeader.self, from: data).schemaVersion
    }

    private static func defaultMigrate(rawData: Data, fromVersion: Int) throws -> Data {
        // Placeholder for future v1 -> v2+ migrations; currently bumps schemaVersion in JSON object.
        guard var json = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            return rawData
        }
        json["schemaVersion"] = AppConfig.currentSchemaVersion
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    private static func normalize(_ config: AppConfig) -> AppConfig {
        var result = config

        // Ensure all built-in scaling modes are present (appending missing ones without clobbering user edits).
        let existingModeIDs = Set(result.scalingModes.map(\.id))
        for builtIn in ScalingMode.builtInPresets where !existingModeIDs.contains(builtIn.id) {
            result.scalingModes.append(builtIn)
        }

        // Ensure at least one default profile exists.
        if !result.profiles.contains(where: \.isDefault) {
            result.profiles.insert(.defaultProfile, at: 0)
        }

        // Clamp countdown seconds to safe range.
        result.countdownSeconds = min(max(result.countdownSeconds, 1), 10)

        // Ensure MetalPie itself is always excluded from auto-scale.
        if !result.autoScaleExcludedBundleIDs.contains(where: {
            $0.caseInsensitiveCompare("com.metalpie.app") == .orderedSame
        }) {
            result.autoScaleExcludedBundleIDs.append("com.metalpie.app")
        }

        return result
    }

    private static func writeAtomically(_ config: AppConfig, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try makeEncoder().encode(config)
        try data.write(to: url, options: [.atomic])
    }

    private static func backupCorruptFile(at url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupName = "\(url.deletingPathExtension().lastPathComponent).corrupt.\(timestamp).json"
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            try fm.copyItem(at: url, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
