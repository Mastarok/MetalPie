import Foundation
import Testing
@testable import MetalPieCore

@Suite("AppUpdater & SemanticVersion")
struct AppUpdaterTests {
    @Test("SemanticVersion parses tags, prereleases, build metadata, and enforces SemVer 2.0 order")
    func semanticVersionParsingAndOrdering() {
        let v102 = SemanticVersion(parsing: "v1.0.2")
        let v103Beta1 = SemanticVersion(parsing: "1.0.3-beta.1")
        let v103Beta2 = SemanticVersion(parsing: "v1.0.3-beta.2+sha1234")
        let v103RC1 = SemanticVersion(parsing: "1.0.3-rc.1")
        let v103 = SemanticVersion(parsing: "v1.0.3")
        let v110 = SemanticVersion(parsing: "1.1")
        let v200 = SemanticVersion(parsing: "V2.0.0")

        #expect(v102 == SemanticVersion(major: 1, minor: 0, patch: 2))
        #expect(v110 == SemanticVersion(major: 1, minor: 1, patch: 0))
        #expect(v103?.displayString == "v1.0.3")
        #expect(v103Beta1?.displayString == "v1.0.3-beta.1")

        #expect(v102! < v103Beta1!)
        #expect(v103Beta1! < v103Beta2!)
        #expect(v103Beta2! < v103RC1!)
        #expect(v103RC1! < v103!)
        #expect(v103! < v110!)
        #expect(v110! < v200!)

        #expect(SemanticVersion(parsing: "") == nil)
        #expect(SemanticVersion(parsing: "v1") == nil)
        #expect(SemanticVersion(parsing: "v1.0.2.3") == nil)
        #expect(SemanticVersion(parsing: "abc") == nil)
    }

    @Test("AppUpdateEvaluator parses GitHub Releases payload, selects arch DMG, and resolves inline SHA-256")
    func parseGitHubReleasePayload() throws {
        let fakeHash = String(repeating: "a1b2c3d4", count: 8)
        let json = """
        {
          "tag_name": "v1.0.3",
          "name": "MetalPie v1.0.3",
          "body": "### What's New\\n- In-app updater\\n- Screenshot cursor fix",
          "html_url": "https://github.com/Mastarok/MetalPie/releases/tag/v1.0.3",
          "published_at": "2026-11-26T10:00:00Z",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "MetalPie-1.0.3-arm64.dmg",
              "browser_download_url": "https://github.com/Mastarok/MetalPie/releases/download/v1.0.3/MetalPie-1.0.3-arm64.dmg",
              "size": 4567890,
              "digest": "sha256:\(fakeHash.uppercased())"
            },
            {
              "name": "MetalPie-1.0.3-arm64.dmg.sha256",
              "browser_download_url": "https://github.com/Mastarok/MetalPie/releases/download/v1.0.3/MetalPie-1.0.3-arm64.dmg.sha256",
              "size": 96
            }
          ]
        }
        """

        let release = try AppUpdateEvaluator.parseRelease(from: Data(json.utf8), architecture: "arm64")
        #expect(release.version == SemanticVersion(major: 1, minor: 0, patch: 3))
        #expect(release.title == "MetalPie v1.0.3")
        #expect(release.dmgAsset?.name == "MetalPie-1.0.3-arm64.dmg")
        #expect(release.sha256Asset?.name == "MetalPie-1.0.3-arm64.dmg.sha256")
        #expect(release.expectedSHA256 == fakeHash)
        #expect(release.publishedAt != nil)

        #expect(AppUpdateEvaluator.isUpdateAvailable(
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 2),
            latest: release
        ))
        #expect(!AppUpdateEvaluator.isUpdateAvailable(
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 3),
            latest: release
        ))
        #expect(!AppUpdateEvaluator.isUpdateAvailable(
            currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
            latest: release
        ))
    }

    @Test("AppUpdateEvaluator ignores draft and prerelease payloads")
    func ignoreDraftAndPrerelease() {
        let draftJSON = """
        {
          "tag_name": "v1.0.4",
          "html_url": "https://github.com/Mastarok/MetalPie/releases/tag/v1.0.4",
          "draft": true,
          "prerelease": false,
          "assets": []
        }
        """
        #expect(throws: AppUpdateError.draftOrPrereleaseIgnored) {
            try AppUpdateEvaluator.parseRelease(from: Data(draftJSON.utf8))
        }

        let preJSON = """
        {
          "tag_name": "v1.0.4-rc.1",
          "html_url": "https://github.com/Mastarok/MetalPie/releases/tag/v1.0.4-rc.1",
          "draft": false,
          "prerelease": true,
          "assets": []
        }
        """
        #expect(throws: AppUpdateError.draftOrPrereleaseIgnored) {
            try AppUpdateEvaluator.parseRelease(from: Data(preJSON.utf8))
        }
    }

    @Test("SHA-256 parsing and streaming file hashing match standard vectors")
    func sha256ParsingAndStreamingHash() throws {
        let knownHelloHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

        #expect(AppUpdateEvaluator.parseSHA256Checksum(from: "sha256:\(knownHelloHash.uppercased())") == knownHelloHash)
        #expect(AppUpdateEvaluator.parseSHA256Checksum(from: "\(knownHelloHash)  MetalPie-1.0.3-arm64.dmg\n") == knownHelloHash)
        #expect(AppUpdateEvaluator.parseSHA256Checksum(from: "sha256:short") == nil)
        #expect(AppUpdateEvaluator.parseSHA256Checksum(from: String(repeating: "z", count: 64)) == nil)

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalpie-sha-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try Data("hello".utf8).write(to: tmpURL)

        let computed = try AppUpdateEvaluator.computeSHA256(ofFile: tmpURL)
        #expect(computed == knownHelloHash)
    }

    @Test("hdiutil plist parser extracts mounted volume path")
    func parseHdiutilPlist() {
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>dev-entry</key>
                    <string>/dev/disk8</string>
                </dict>
                <dict>
                    <key>dev-entry</key>
                    <string>/dev/disk8s1</string>
                    <key>mount-point</key>
                    <string>/Volumes/MetalPie 1.0.3</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let mountURL = AppUpdateEvaluator.parseMountedVolumePath(fromHdiutilPlistData: Data(plistXML.utf8))
        #expect(mountURL?.path == "/Volumes/MetalPie 1.0.3")
    }

    @Test("AppConfig backwards-compatible decoding defaults automaticallyCheckForUpdates to true")
    func appConfigUpdateToggleBackwardsCompatibility() throws {
        var config = AppConfig.defaultConfig
        #expect(config.automaticallyCheckForUpdates == true)

        // Strip `automaticallyCheckForUpdates` from encoded JSON to simulate pre-updater config.json.
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(config)
        var rawDict = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        rawDict.removeValue(forKey: "automaticallyCheckForUpdates")
        let legacyData = try JSONSerialization.data(withJSONObject: rawDict)

        let decodedLegacy = try JSONDecoder().decode(AppConfig.self, from: legacyData)
        #expect(decodedLegacy.automaticallyCheckForUpdates == true)

        // Round-trip explicit false
        config.automaticallyCheckForUpdates = false
        let roundTrip = try JSONDecoder().decode(AppConfig.self, from: try encoder.encode(config))
        #expect(roundTrip.automaticallyCheckForUpdates == false)
    }
}
