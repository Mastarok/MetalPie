import AppKit
import Foundation
import MetalPieCore
import Observation
import os

/// Live state machine for MetalPie's native GitHub Releases in-app updater.
public enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: SemanticVersion, checkedAt: Date)
    case available(AppUpdateRelease)
    case downloading(release: AppUpdateRelease, progress: Double, receivedBytes: Int64, totalBytes: Int64)
    case verifying(release: AppUpdateRelease)
    case readyToInstall(release: AppUpdateRelease, stagedAppURL: URL?, dmgURL: URL)
    case installing(release: AppUpdateRelease)
    case failed(message: String)

    public var availableRelease: AppUpdateRelease? {
        switch self {
        case .available(let r),
             .downloading(let r, _, _, _),
             .verifying(let r),
             .readyToInstall(let r, _, _),
             .installing(let r):
            return r
        default:
            return nil
        }
    }

    public var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing:
            return true
        default:
            return false
        }
    }
}

/// Native macOS in-app updater powered by GitHub Releases (`Mastarok/MetalPie`):
/// - Checks `releases/latest` asynchronously (with 12-hour throttle for automatic startup checks).
/// - Downloads the ARM64 `.dmg` with live progress & cancel support.
/// - Verifies SHA-256 checksum (via GitHub API digest and/or companion `.dmg.sha256` file).
/// - Mounts the DMG privately (`hdiutil attach -nobrowse -readonly -plist`), verifies `codesign`,
///   stages `MetalPie.app`, and performs an atomic swap + relaunch (or opens the verified DMG in Finder
///   when running unbundled or from a read-only / App Translocation directory).
@Observable
@MainActor
public final class AppUpdateManager {
    private static let lastCheckDefaultsKey = "com.metalpie.updates.lastAutoCheckTimestamp"
    private static let autoCheckMinIntervalSeconds: TimeInterval = 12 * 60 * 60
    private static let osLog = Logger(subsystem: "com.metalpie.app", category: "Updater")

    public let currentVersion: SemanticVersion
    public private(set) var state: AppUpdateState = .idle
    public private(set) var lastCheckedAt: Date?

    /// True when the currently running process is an installed `.app` bundle on a writable volume
    /// (not App Translocation and not unbundled `swift run`), allowing one-click atomic replace + relaunch.
    public var canInstallInPlace: Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return false }
        if bundleURL.path.contains("/AppTranslocation/") { return false }
        let parentDir = bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parentDir)
    }

    private var activeDownloadDelegate: DownloadBridge?
    private var activeDownloadSession: URLSession?
    private var activeDownloadTask: URLSessionDownloadTask?

    public init() {
        let infoVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.currentVersion = infoVer.flatMap(SemanticVersion.init(parsing:))
            ?? AppUpdateEvaluator.fallbackCurrentVersion
        let savedTs = UserDefaults.standard.double(forKey: Self.lastCheckDefaultsKey)
        if savedTs > 0 {
            self.lastCheckedAt = Date(timeIntervalSince1970: savedTs)
        }
    }

    /// Triggers a quiet startup check when `automaticallyCheckForUpdates` is enabled and at least
    /// 12 hours have elapsed since the last automatic check.
    public func performStartupCheckIfNeeded(enabled: Bool) {
        guard enabled else { return }
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < Self.autoCheckMinIntervalSeconds {
            return
        }
        Task { [weak self] in
            // Let the main window settle cleanly before hitting the network.
            try? await Task.sleep(for: .seconds(3))
            await self?.checkForUpdates(userInitiated: false)
        }
    }

    /// Queries GitHub Releases for the latest stable release using rate-limit-free `github.com`
    /// web endpoints first (immune to unauthenticated `api.github.com` 60/hr shared-IP/proxy limits),
    /// enriching with GitHub REST API metadata when an update exists and quota permits.
    public func checkForUpdates(userInitiated: Bool) async {
        guard !state.isBusy else { return }
        if userInitiated {
            state = .checking
        }

        let userAgent = "MetalPie/\(currentVersion.numericString) (macOS)"

        do {
            // Step 1: Rate-limit-free latest stable tag probe on `github.com/Mastarok/MetalPie/releases/latest`.
            var webReq = URLRequest(url: AppUpdateEvaluator.latestReleaseWebURL)
            webReq.httpMethod = "GET"
            webReq.timeoutInterval = 15
            webReq.cachePolicy = .reloadIgnoringLocalCacheData
            webReq.setValue("application/json", forHTTPHeaderField: "Accept")
            webReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (webData, webResponse) = try await URLSession.shared.data(for: webReq)
            if let http = webResponse as? HTTPURLResponse {
                if http.statusCode == 404 {
                    let now = Date()
                    recordCheckTime(now)
                    if userInitiated {
                        state = .upToDate(currentVersion: currentVersion, checkedAt: now)
                    }
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    if userInitiated {
                        state = .failed(message: "GitHub returned HTTP \(http.statusCode).")
                    }
                    return
                }
            }

            guard let latestTag = AppUpdateEvaluator.parseLatestTag(fromWebJSON: webData, finalURL: webResponse.url),
                  let latestVersion = SemanticVersion(parsing: latestTag)
            else {
                // Repository has no stable release tag yet (redirect stayed on `/releases`).
                let now = Date()
                recordCheckTime(now)
                if userInitiated {
                    state = .upToDate(currentVersion: currentVersion, checkedAt: now)
                }
                return
            }

            let now = Date()
            recordCheckTime(now)

            // Fast path: already on latest version — zero api.github.com calls needed!
            guard latestVersion > currentVersion else {
                state = .upToDate(currentVersion: currentVersion, checkedAt: now)
                if userInitiated {
                    PipelineLog.shared.info(.app, "MetalPie is up to date (\(currentVersion.displayString)).")
                }
                return
            }

            // Step 2: Update IS available — enrich metadata from API if quota allows, else seamlessly
            // assemble full release + SHA-256 + notes from rate-limit-free github.com web endpoints.
            let arch = currentArchitecture()
            let release = try await resolveReleaseMetadata(forTag: latestTag, architecture: arch, userAgent: userAgent)

            state = .available(release)
            let msg = "Update available: \(release.version.displayString) (current \(currentVersion.displayString))."
            PipelineLog.shared.info(.app, msg)
            Self.osLog.notice("\(msg, privacy: .public)")
        } catch is CancellationError {
            if userInitiated { state = .idle }
        } catch let err as AppUpdateError where err == .draftOrPrereleaseIgnored {
            let now = Date()
            recordCheckTime(now)
            if userInitiated {
                state = .upToDate(currentVersion: currentVersion, checkedAt: now)
            }
        } catch {
            if userInitiated {
                state = .failed(message: error.localizedDescription)
                PipelineLog.shared.warning(.app, "Update check failed: \(error.localizedDescription)")
            }
        }
    }

    private func resolveReleaseMetadata(
        forTag tagName: String,
        architecture: String,
        userAgent: String
    ) async throws -> AppUpdateRelease {
        // Attempt rich REST API payload first (gives exact byte size + Markdown release notes).
        if let apiURL = AppUpdateEvaluator.releaseTagAPIURL(forTag: tagName) {
            var apiReq = URLRequest(url: apiURL)
            apiReq.httpMethod = "GET"
            apiReq.timeoutInterval = 10
            apiReq.cachePolicy = .reloadIgnoringLocalCacheData
            apiReq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            apiReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            if let (apiData, apiResp) = try? await URLSession.shared.data(for: apiReq),
               let http = apiResp as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               let parsed = try? AppUpdateEvaluator.parseRelease(from: apiData, architecture: architecture)
            {
                return parsed
            }
        }

        // Seamless rate-limit-free fallback: expanded_assets HTML + releases.atom feed on github.com.
        var expandedHTML: String? = nil
        if let assetsURL = AppUpdateEvaluator.expandedAssetsURL(forTag: tagName) {
            var assetsReq = URLRequest(url: assetsURL)
            assetsReq.timeoutInterval = 12
            assetsReq.cachePolicy = .reloadIgnoringLocalCacheData
            assetsReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let (data, resp) = try? await URLSession.shared.data(for: assetsReq),
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode)
            {
                expandedHTML = String(data: data, encoding: .utf8)
            }
        }

        var atomXML: Data? = nil
        var atomReq = URLRequest(url: AppUpdateEvaluator.releasesAtomURL)
        atomReq.timeoutInterval = 12
        atomReq.cachePolicy = .reloadIgnoringLocalCacheData
        atomReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let (data, resp) = try? await URLSession.shared.data(for: atomReq),
           let http = resp as? HTTPURLResponse,
           (200...299).contains(http.statusCode)
        {
            atomXML = data
        }

        return try AppUpdateEvaluator.buildReleaseFromWebMetadata(
            tagName: tagName,
            expandedAssetsHTML: expandedHTML,
            atomXML: atomXML,
            architecture: architecture
        )
    }

    /// Downloads the release DMG, verifies SHA-256 checksum & code signature, and stages `MetalPie.app`.
    public func downloadAndPrepareUpdate(_ release: AppUpdateRelease) {
        guard let dmgAsset = release.dmgAsset else {
            openReleasePage(release)
            return
        }
        cancelDownload(resetToAvailable: false)

        state = .downloading(release: release, progress: 0, receivedBytes: 0, totalBytes: dmgAsset.size)

        let bridge = DownloadBridge(
            onProgress: { [weak self] received, expected in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let total = expected > 0 ? expected : dmgAsset.size
                    let frac = total > 0 ? min(1.0, max(0.0, Double(received) / Double(total))) : 0.0
                    self.state = .downloading(
                        release: release,
                        progress: frac,
                        receivedBytes: received,
                        totalBytes: total
                    )
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cleanupDownloadSession()
                    switch result {
                    case .success(let tempLocation):
                        await self.finalizeDownloadedDMG(tempLocation: tempLocation, release: release, dmgAsset: dmgAsset)
                    case .failure(let error):
                        if (error as NSError).code == NSURLErrorCancelled {
                            self.state = .available(release)
                        } else {
                            self.state = .failed(message: error.localizedDescription)
                            PipelineLog.shared.warning(.app, "Update download failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        )

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        let session = URLSession(configuration: cfg, delegate: bridge, delegateQueue: nil)
        var req = URLRequest(url: dmgAsset.downloadURL)
        req.setValue("MetalPie/\(currentVersion.numericString) (macOS)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req)

        self.activeDownloadDelegate = bridge
        self.activeDownloadSession = session
        self.activeDownloadTask = task
        task.resume()
    }

    /// Cancels an active download and returns to `.available(release)`.
    public func cancelDownload(resetToAvailable: Bool = true) {
        let prevRelease = state.availableRelease
        activeDownloadTask?.cancel()
        cleanupDownloadSession()
        if resetToAvailable, let prevRelease {
            state = .available(prevRelease)
        }
    }

    /// Installs the staged update atomically and relaunches MetalPie (or opens the verified DMG in Finder
    /// if running unbundled / from a non-writable location).
    /// Returns `true` when an in-place relaunch was initiated (process is terminating), or `false` when
    /// Finder opened the DMG for manual drag-and-drop.
    @discardableResult
    public func installPreparedUpdateAndRelaunch(beforeExit: @MainActor () -> Void) -> Bool {
        guard case .readyToInstall(let release, let stagedAppURL, let dmgURL) = state else {
            return false
        }

        if canInstallInPlace, let stagedApp = stagedAppURL, FileManager.default.fileExists(atPath: stagedApp.path) {
            state = .installing(release: release)
            let targetAppURL = Bundle.main.bundleURL
            let pid = ProcessInfo.processInfo.processIdentifier

            do {
                try launchDetachedReplaceAndRelaunch(
                    oldPID: pid,
                    stagedAppURL: stagedApp,
                    targetAppURL: targetAppURL
                )
                PipelineLog.shared.info(.app, "Installing MetalPie \(release.version.displayString) and relaunching…")
                beforeExit()
                NSApp.terminate(nil)
                return true
            } catch {
                PipelineLog.shared.warning(.app, "In-place install failed (\(error.localizedDescription)); opening verified DMG.")
                state = .readyToInstall(release: release, stagedAppURL: stagedAppURL, dmgURL: dmgURL)
                NSWorkspace.shared.open(dmgURL)
                return false
            }
        } else {
            NSWorkspace.shared.open(dmgURL)
            return false
        }
    }

    public func openReleasePage(_ release: AppUpdateRelease? = nil) {
        NSWorkspace.shared.open(release?.releasePageURL ?? AppUpdateEvaluator.releasesPageURL)
    }

    // MARK: - Verification & DMG Staging

    private func finalizeDownloadedDMG(
        tempLocation: URL,
        release: AppUpdateRelease,
        dmgAsset: GitHubReleaseAsset
    ) async {
        state = .verifying(release: release)

        let updatesDir = Self.updatesCacheDirectory()
        let dmgDestURL = updatesDir.appendingPathComponent(dmgAsset.name)
        let stagingDir = updatesDir.appendingPathComponent("staged-\(release.version.numericString)", isDirectory: true)

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: updatesDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dmgDestURL.path) {
                try fm.removeItem(at: dmgDestURL)
            }
            try fm.moveItem(at: tempLocation, to: dmgDestURL)

            // 1. Resolve expected SHA-256 (from API digest or companion `.sha256` file) and verify.
            var expectedSHA = release.expectedSHA256
            if expectedSHA == nil, let shaAsset = release.sha256Asset {
                var shaReq = URLRequest(url: shaAsset.downloadURL)
                shaReq.timeoutInterval = 15
                shaReq.setValue("MetalPie/\(currentVersion.numericString) (macOS)", forHTTPHeaderField: "User-Agent")
                if let (shaData, resp) = try? await URLSession.shared.data(for: shaReq),
                   let http = resp as? HTTPURLResponse,
                   (200...299).contains(http.statusCode),
                   let shaText = String(data: shaData, encoding: .utf8)
                {
                    expectedSHA = AppUpdateEvaluator.parseSHA256Checksum(from: shaText)
                }
            }

            let actualSHA = try await Task.detached(priority: .userInitiated) {
                try AppUpdateEvaluator.computeSHA256(ofFile: dmgDestURL)
            }.value

            if let expected = expectedSHA, expected != actualSHA {
                try? fm.removeItem(at: dmgDestURL)
                throw AppUpdateError.checksumMismatch(expected: expected, actual: actualSHA)
            }

            // 2. Mount DMG privately, verify codesign, and stage MetalPie.app off the disk image.
            let stagedAppURL: URL?
            if canInstallInPlace {
                stagedAppURL = try await Task.detached(priority: .userInitiated) {
                    try Self.extractAndVerifyApp(fromDMG: dmgDestURL, into: stagingDir)
                }.value
            } else {
                stagedAppURL = nil
            }

            state = .readyToInstall(release: release, stagedAppURL: stagedAppURL, dmgURL: dmgDestURL)
            PipelineLog.shared.info(
                .app,
                "Update \(release.version.displayString) verified (SHA-256 \(actualSHA.prefix(12))…) and ready to install."
            )
        } catch {
            state = .failed(message: error.localizedDescription)
            PipelineLog.shared.warning(.app, "Update verification failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func extractAndVerifyApp(fromDMG dmgURL: URL, into stagingDir: URL) throws -> URL {
        let attach = try runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path]
        )
        guard attach.exitCode == 0,
              let mountPoint = AppUpdateEvaluator.parseMountedVolumePath(fromHdiutilPlistData: attach.stdout)
        else {
            throw NSError(
                domain: "com.metalpie.updater",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to mount update disk image."]
            )
        }

        defer {
            _ = try? runProcess(
                executable: "/usr/bin/hdiutil",
                arguments: ["detach", mountPoint.path, "-force"]
            )
        }

        let mountedApp = mountPoint.appendingPathComponent("MetalPie.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: mountedApp.path) else {
            throw NSError(
                domain: "com.metalpie.updater",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "MetalPie.app was not found inside the downloaded DMG."]
            )
        }

        let verifySign = try runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", mountedApp.path]
        )
        guard verifySign.exitCode == 0 else {
            throw NSError(
                domain: "com.metalpie.updater",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded MetalPie.app failed code signature verification."]
            )
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: stagingDir.path) {
            try fm.removeItem(at: stagingDir)
        }
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let stagedApp = stagingDir.appendingPathComponent("MetalPie.app", isDirectory: true)
        let copyResult = try runProcess(
            executable: "/usr/bin/ditto",
            arguments: [mountedApp.path, stagedApp.path]
        )
        guard copyResult.exitCode == 0 else {
            throw NSError(
                domain: "com.metalpie.updater",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to stage updated MetalPie.app."]
            )
        }
        return stagedApp
    }

    private func launchDetachedReplaceAndRelaunch(
        oldPID: Int32,
        stagedAppURL: URL,
        targetAppURL: URL
    ) throws {
        let stagingParent = stagedAppURL.deletingLastPathComponent()
        let backupPath = targetAppURL.path + ".metalpie-update-backup"
        let script = """
        PID="$1"
        STAGED="$2"
        TARGET="$3"
        BACKUP="$4"
        STAGE_DIR="$5"

        for _ in $(seq 1 150); do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done

        rm -rf "$BACKUP"
        if mv "$TARGET" "$BACKUP"; then
            if mv "$STAGED" "$TARGET"; then
                /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
                rm -rf "$BACKUP" "$STAGE_DIR"
                /usr/bin/open -n "$TARGET"
                exit 0
            else
                mv "$BACKUP" "$TARGET" 2>/dev/null || true
                exit 1
            fi
        else
            exit 1
        fi
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            "-c", script, "metalpie-updater",
            String(oldPID),
            stagedAppURL.path,
            targetAppURL.path,
            backupPath,
            stagingParent.path
        ]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    private nonisolated static func runProcess(
        executable: String,
        arguments: [String]
    ) throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, outData, errData)
    }

    private func recordCheckTime(_ date: Date) {
        lastCheckedAt = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastCheckDefaultsKey)
    }

    private func cleanupDownloadSession() {
        activeDownloadTask = nil
        activeDownloadSession?.invalidateAndCancel()
        activeDownloadSession = nil
        activeDownloadDelegate = nil
    }

    private func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static func updatesCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.metalpie.app", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }
}

// MARK: - URLSessionDownloadDelegate Bridge

private final class DownloadBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onFinish: @Sendable (Result<URL, Error>) -> Void
    private let finished = OSAllocatedUnfairLock(initialState: false)

    init(
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinish: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move the downloaded file immediately out of URLSession's ephemeral temp location before returning!
        let preserved = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalpie-dl-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: preserved)
            completeOnce(.success(preserved))
        } catch {
            completeOnce(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            completeOnce(.failure(error))
        }
    }

    private func completeOnce(_ result: Result<URL, Error>) {
        let shouldFire = finished.withLock { done -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        if shouldFire {
            onFinish(result)
        }
    }
}
