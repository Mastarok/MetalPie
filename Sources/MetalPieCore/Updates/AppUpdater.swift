import CryptoKit
import Foundation

// MARK: - Semantic Version

/// Lightweight SemVer 2.0 value type supporting `v`-prefixed tags, 2- or 3-component versions,
/// optional prerelease identifiers (`1.0.3-beta.1 < 1.0.3`), and ignored build metadata (`+sha`).
public struct SemanticVersion: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int = 0, prerelease: String? = nil) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
        let trimmed = prerelease?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prerelease = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Parses strings such as `"v1.0.3"`, `"1.0.3"`, `"1.2"`, `"1.0.3-rc.1"`, or `"1.0.3+build12"`.
    public init?(parsing raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        guard !s.isEmpty else { return nil }

        // Strip optional `+build` metadata
        if let plusIdx = s.firstIndex(of: "+") {
            s = String(s[..<plusIdx])
        }

        // Split optional `-prerelease`
        let corePart: String
        let prereleasePart: String?
        if let dashIdx = s.firstIndex(of: "-") {
            corePart = String(s[..<dashIdx])
            let pre = String(s[s.index(after: dashIdx)...])
            prereleasePart = pre.isEmpty ? nil : pre
        } else {
            corePart = s
            prereleasePart = nil
        }

        let comps = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard comps.count >= 2 && comps.count <= 3 else { return nil }
        guard let maj = Int(comps[0]), maj >= 0,
              let min = Int(comps[1]), min >= 0
        else {
            return nil
        }
        let pat: Int
        if comps.count == 3 {
            guard let parsedPatch = Int(comps[2]), parsedPatch >= 0 else { return nil }
            pat = parsedPatch
        } else {
            pat = 0
        }

        self.init(major: maj, minor: min, patch: pat, prerelease: prereleasePart)
    }

    public var numericString: String {
        "\(major).\(minor).\(patch)"
    }

    public var displayString: String {
        if let prerelease {
            return "v\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "v\(major).\(minor).\(patch)"
    }

    public var description: String { displayString }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Per SemVer 2.0: a release without prerelease has HIGHER precedence than one with prerelease.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (let lPre?, let rPre?):
            let lIds = lPre.split(separator: ".").map(String.init)
            let rIds = rPre.split(separator: ".").map(String.init)
            for (l, r) in zip(lIds, rIds) where l != r {
                if let lNum = Int(l), let rNum = Int(r) {
                    return lNum < rNum
                }
                return l < r
            }
            return lIds.count < rIds.count
        }
    }
}

// MARK: - GitHub Release Models

public struct GitHubReleaseAsset: Hashable, Codable, Sendable {
    public let name: String
    public let downloadURL: URL
    public let size: Int64
    public let digest: String?

    public init(name: String, downloadURL: URL, size: Int64, digest: String? = nil) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.digest = digest
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
        case digest
    }
}

public struct GitHubReleasePayload: Hashable, Codable, Sendable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let publishedAt: String?
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
    }
}

/// Resolved update metadata ready for display, download, SHA-256 verification, and installation.
public struct AppUpdateRelease: Hashable, Sendable {
    public let version: SemanticVersion
    public let tagName: String
    public let title: String
    public let releaseNotes: String
    public let releasePageURL: URL
    public let publishedAt: Date?
    public let dmgAsset: GitHubReleaseAsset?
    public let sha256Asset: GitHubReleaseAsset?
    public let expectedSHA256: String?

    public init(
        version: SemanticVersion,
        tagName: String,
        title: String,
        releaseNotes: String,
        releasePageURL: URL,
        publishedAt: Date?,
        dmgAsset: GitHubReleaseAsset?,
        sha256Asset: GitHubReleaseAsset?,
        expectedSHA256: String?
    ) {
        self.version = version
        self.tagName = tagName
        self.title = title
        self.releaseNotes = releaseNotes
        self.releasePageURL = releasePageURL
        self.publishedAt = publishedAt
        self.dmgAsset = dmgAsset
        self.sha256Asset = sha256Asset
        self.expectedSHA256 = expectedSHA256
    }
}

public enum AppUpdateError: LocalizedError, Equatable, Sendable {
    case invalidReleasePayload
    case unsupportedVersionTag(String)
    case draftOrPrereleaseIgnored
    case missingInstallerAsset
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidReleasePayload:
            return "Invalid release response from GitHub."
        case .unsupportedVersionTag(let tag):
            return "Unrecognized release version tag: \(tag)"
        case .draftOrPrereleaseIgnored:
            return "Latest release is a draft or prerelease."
        case .missingInstallerAsset:
            return "No macOS DMG installer was found in this release."
        case .checksumMismatch(let expected, let actual):
            return "SHA-256 checksum mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        }
    }
}

// MARK: - Pure Update Evaluator & Verification Helpers

public enum AppUpdateEvaluator: Sendable {
    public static let defaultRepositoryOwner = "Mastarok"
    public static let defaultRepositoryName = "MetalPie"
    public static let fallbackCurrentVersion = SemanticVersion(major: 1, minor: 0, patch: 2)

    public static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(defaultRepositoryOwner)/\(defaultRepositoryName)/releases/latest")!
    }

    public static var releasesPageURL: URL {
        URL(string: "https://github.com/\(defaultRepositoryOwner)/\(defaultRepositoryName)/releases")!
    }

    /// Parses a GitHub Releases API JSON payload into a strongly typed `AppUpdateRelease`.
    public static func parseRelease(
        from data: Data,
        architecture: String = "arm64"
    ) throws -> AppUpdateRelease {
        let payload: GitHubReleasePayload
        do {
            payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        } catch {
            throw AppUpdateError.invalidReleasePayload
        }

        guard !payload.isDraft, !payload.isPrerelease else {
            throw AppUpdateError.draftOrPrereleaseIgnored
        }
        guard let version = SemanticVersion(parsing: payload.tagName) else {
            throw AppUpdateError.unsupportedVersionTag(payload.tagName)
        }

        let archLower = architecture.lowercased()
        let dmgAssets = payload.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let selectedDMG = dmgAssets.first { $0.name.lowercased().contains(archLower) }
            ?? dmgAssets.first { $0.name.lowercased().contains("universal") }
            ?? dmgAssets.first

        let selectedSHA: GitHubReleaseAsset?
        if let dmg = selectedDMG {
            let exactSHAName = dmg.name.lowercased() + ".sha256"
            selectedSHA = payload.assets.first { $0.name.lowercased() == exactSHAName }
                ?? payload.assets.first { $0.name.lowercased().hasSuffix(".sha256") }
        } else {
            selectedSHA = payload.assets.first { $0.name.lowercased().hasSuffix(".sha256") }
        }

        let inlineSHA = selectedDMG?.digest.flatMap { parseSHA256Checksum(from: $0) }
        let iso = ISO8601DateFormatter()
        let publishedDate = payload.publishedAt.flatMap { iso.date(from: $0) }
        let cleanTitle = (payload.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "MetalPie \(version.displayString)"
        let cleanBody = (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return AppUpdateRelease(
            version: version,
            tagName: payload.tagName,
            title: cleanTitle,
            releaseNotes: cleanBody,
            releasePageURL: payload.htmlURL,
            publishedAt: publishedDate,
            dmgAsset: selectedDMG,
            sha256Asset: selectedSHA,
            expectedSHA256: inlineSHA
        )
    }

    /// Returns `true` iff `latest.version` is strictly newer than `currentVersion`.
    public static func isUpdateAvailable(
        currentVersion: SemanticVersion,
        latest: AppUpdateRelease
    ) -> Bool {
        latest.version > currentVersion
    }

    /// Parses a 64-character hexadecimal SHA-256 checksum from either `"sha256:<hex>"` (GitHub API digest)
    /// or standard `shasum -a 256` output (`"<hex>  MetalPie-1.0.3-arm64.dmg"`).
    public static func parseSHA256Checksum(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.lowercased().hasPrefix("sha256:") {
            candidate = String(trimmed.dropFirst("sha256:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            candidate = trimmed
                .split(whereSeparator: { $0.isWhitespace })
                .first
                .map(String.init) ?? ""
        }

        guard candidate.count == 64 else { return nil }
        for scalar in candidate.unicodeScalars {
            let v = scalar.value
            let isDigit = (48...57).contains(v)
            let isLowerHex = (97...102).contains(v)
            let isUpperHex = (65...70).contains(v)
            if !(isDigit || isLowerHex || isUpperHex) {
                return nil
            }
        }
        return candidate.lowercased()
    }

    /// Computes lowercase hexadecimal SHA-256 of a file using streaming 256 KB reads (constant memory).
    public static func computeSHA256(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Extracts the mounted volume path from `hdiutil attach -nobrowse -readonly -plist` XML output.
    public static func parseMountedVolumePath(fromHdiutilPlistData data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            return nil
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return URL(fileURLWithPath: mountPoint, isDirectory: true)
            }
        }
        return nil
    }
}
