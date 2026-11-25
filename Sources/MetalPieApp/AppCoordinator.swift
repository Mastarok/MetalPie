import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import Metal
import MetalFX
import MetalPieCapture
import MetalPieCore
import MetalPieInput
import MetalPieShaders
import Observation
import os

/// Primary sidebar navigation tabs for MetalPie's native macOS window.
public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case home
    case effects
    case profiles
    case settings
    case diagnostics

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .home: return "play.display"
        case .effects: return "sparkles.rectangle.stack"
        case .profiles: return "app.badge.checkmark"
        case .settings: return "gearshape"
        case .diagnostics: return "gauge.with.dots.needle.67percent"
        }
    }

    public func title(_ l10n: L10n) -> String {
        switch self {
        case .home: return l10n.tr("Home", "主页")
        case .effects: return l10n.tr("Scaling Modes", "缩放模式")
        case .profiles: return l10n.tr("Profiles", "配置文件")
        case .settings: return l10n.tr("Settings", "设置")
        case .diagnostics: return l10n.tr("Benchmark", "性能测试")
        }
    }
}

/// Snapshot of Apple Silicon GPU, MetalFX, and VideoToolbox ML hardware capabilities.
public struct SystemCapabilitiesSnapshot: Sendable {
    public var gpuName: String
    public var supportsMetal3: Bool
    public var supportsMetal4: Bool
    public var supportsMetalFXSpatial: Bool
    public var supportsVTSuperResolution: Bool
    public var supportsVTFrameInterpolation: Bool
    public var macOSVersionString: String
    public var recommendedWorkingSetMB: Int
}

/// Central `@Observable @MainActor` orchestrator wiring every MetalPie engine subsystem:
/// `ConfigStore`, `EffectChainRenderer`, `VideoToolboxMLProcessor`, `ScreenCaptureEngine`,
/// `OverlayWindowController`, `RenderLoopController`, `WindowEnumerator`, `PermissionsManager`,
/// `CursorOverlayController`, `GlobalHotkeyManager`, `WindowLifecycleWatcher`,
/// `AutoScaleController`, `RunGuardWatchdog`, and floating overlay chrome panels.
@Observable
@MainActor
public final class AppCoordinator {
    // MARK: - Observable UI State

    public var config: AppConfig
    public var selectedTab: AppTab = .home
    public var selectedProfileID: UUID
    public var selectedScalingModeID: UUID

    public var telemetry: SessionTelemetry = .idle
    public var permissions: PermissionStatus
    public var displays: [DisplayDescriptor] = []
    public var windows: [WindowDescriptor] = []
    public var windowThumbnails: [CGWindowID: NSImage] = [:]
    public var isRefreshingWindows: Bool = false

    public var activeWindow: WindowDescriptor?
    public var activeProfile: Profile?
    public var activeScalingMode: ScalingMode?
    public var activePresentationMode: PresentationMode = .fullscreen
    public var isPaused: Bool = false
    public var isWindowedClickThrough: Bool = true
    public var isProfilerHUDActive: Bool = false
    public var isToolbarVisibleOverride: Bool? = nil
    public var cursorAlignmentMode: CursorAlignmentMode = .inactive
    public var needsAccessibilityForScaledClicks: Bool {
        cursorAlignmentMode == .accessibilityRequired
    }

    public var countdownRemaining: Int? = nil
    public var countdownTargetMode: PresentationMode? = nil

    /// ProMotion VRR Direct-Scanout toggle (single fullscreen display, zero WindowServer sub-windows).
    public var vrrDirectScanoutEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(vrrDirectScanoutEnabled, forKey: Self.vrrDefaultsKey)
            overlayWindowController?.isVRRDirectScanoutEnabled = vrrDirectScanoutEnabled
            if isScalingSessionOpen {
                Task { await self.reconfigureActiveSession() }
            }
        }
    }

    /// 1× Non-Retina auto-demagnify mode for Wine / CrossOver / retro apps.
    public var nonRetinaMode: NonRetinaDetectionMode = .auto {
        didSet {
            UserDefaults.standard.set(nonRetinaMode.rawValue, forKey: Self.nonRetinaDefaultsKey)
            screenCaptureEngine?.nonRetinaMode = nonRetinaMode
            applyDemagnifyMode(for: screenCaptureEngine?.detectedContentResolution ?? .nativeFull)
        }
    }

    public var detectedContentResolution: DetectedContentResolution = .nativeFull

    public var hotkeyWarning: String? = nil
    public var lastErrorMessage: String? = nil
    public var lastScreenshotURL: URL? = nil

    public var benchmarkResults: [ShaderBenchmarkResult] = []
    public var isBenchmarkRunning: Bool = false
    public var benchmarkProgress: Double = 0
    public var benchmarkCurrentEffectName: String = ""

    public var logEntries: [LogEntry] = []
    public var shaderCacheSizeBytes: Int64 = 0
    public var shaderCachePath: String = ""

    /// Optional ephemeral language override (`--lang en|zh`) that never mutates `config.json`.
    public var languageOverride: AppLanguage? = nil
    /// Optional automated visual snapshot path (`--snapshot-out <path.png>`).
    public let snapshotOutputPath: String?
    /// Optional flag to run the 30-shader GPU benchmark before taking a snapshot (`--run-benchmark`).
    public let autoRunBenchmarkForSnapshot: Bool
    /// Set to `true` by `EffectChainEditorView` once the initial Metal GPU preview image finishes rendering.
    public var isPreviewReadyForSnapshot: Bool = false

    public var effectiveLanguage: AppLanguage { languageOverride ?? config.language }
    public var l10n: L10n { L10n(language: effectiveLanguage) }

    public var isScalingSessionOpen: Bool {
        switch telemetry.state {
        case .starting, .running, .suspended, .waitingForWindow:
            return true
        default:
            return false
        }
    }

    public let capabilities: SystemCapabilitiesSnapshot

    // MARK: - Engine Subsystems

    public let configStore: ConfigStore
    public let metalDevice: (any MTLDevice)?
    public let effectChainRenderer: EffectChainRenderer?
    private let screenCaptureEngine: ScreenCaptureEngine?
    private let overlayWindowController: OverlayWindowController?
    private let renderLoopController: RenderLoopController?
    private let permissionsManager = PermissionsManager.shared
    private let cursorController: CursorOverlayController
    private let hotkeyManager: GlobalHotkeyManager
    private let windowLifecycleWatcher: WindowLifecycleWatcher
    private let autoScaleController: AutoScaleController
    private let watchdog = RunGuardWatchdog.shared

    private let toolbarPanel = OverlayToolbarPanel()
    private let profilerHUDPanel = ProfilerHUDPanel()
    private let toastPanel = ToastOverlayPanel()

    // MARK: - Internal Coordination State

    private struct SavedSourceWindowGeometry {
        var windowID: CGWindowID
        var pid: Int32
        var cgRect: CGRect
    }

    private struct SelfRepositionGuard {
        var windowID: CGWindowID
        var expectedCGRect: CGRect
        var expiresAtUptime: TimeInterval
    }

    private struct CursorCallbackFastPathState: Sendable {
        var isVRRDirectScanoutActive: Bool = false
        var registeredCursorOverlayWindowID: CGWindowID? = nil
    }

    private struct PopupMenuMonitorSnapshot: Sendable {
        var isActive: Bool = false
        var targetPID: Int32 = 0
        var sourceCGRect: CGRect = .zero
        var displays: [DisplayDescriptor] = []
        var menuBarHeightByDisplayID: [CGDirectDisplayID: CGFloat] = [:]
        var overlayWindowID: CGWindowID? = nil
        var isBoosted: Bool = false
        var isMenuBarDropdownActive: Bool = false
    }

    private struct ChromeVisibilitySnapshot: Equatable {
        var isRevealed: Bool
        var isSuspended: Bool
        var isVRRDirectScanoutActive: Bool
        var toolbarMode: ToolbarMode
        var isProfilerHUDActive: Bool
    }

    private var watchdogToken: RunGuardWatchdog.RecoveryToken?
    private var workspaceSafetyObservers: [any NSObjectProtocol] = []
    private var countdownTask: Task<Void, Never>?
    private var logRefreshTimer: Timer?
    private var lastLayout: ScalingLayoutResult?
    private var lastOverlayMetrics: OverlayDrawableMetrics?
    private var lastSyncedChromeVisibility: ChromeVisibilitySnapshot?
    private var cachedVRRCursorGeneration: UInt64 = 0
    private var cachedVRRCursorTexture: (any MTLTexture)?
    private var cachedVRRHUDTexture: (any MTLTexture)?
    private var lastVRRHUDRenderTime: CFAbsoluteTime = 0
    private var vrrCursorRetryPending: Bool = false
    private var isStartingSession = false
    private var isRetargetingFullscreenWindow = false
    private var didWarnAccessibilityForCurrentSession = false

    private var savedSourceWindowGeometry: SavedSourceWindowGeometry?
    private var didUserManuallyMoveWindowedOverlay: Bool = false
    private var isInteractiveWindowedDragActive: Bool = false
    private var selfRepositionGuard: SelfRepositionGuard?
    private var cachedAXWindowRef: (windowID: CGWindowID, pid: Int32, element: AXUIElement)?
    private var lastAXRepositionTime: CFAbsoluteTime = 0
    private var isSyncingWindowedSourcePosition: Bool = false
    private var lastIgnoredOverlayWindowIDs: Set<CGWindowID> = []
    private let cursorCallbackFastPath = OSAllocatedUnfairLock(initialState: CursorCallbackFastPathState())
    private let popupMenuMonitorState = OSAllocatedUnfairLock(initialState: PopupMenuMonitorSnapshot())
    private let popupMenuMonitorQueue = DispatchQueue(
        label: "com.metalpie.app.popup-menu-monitor",
        qos: .userInitiated
    )
    private var popupMenuMonitorTimer: (any DispatchSourceTimer)?

    private static let vrrDefaultsKey = "com.metalpie.vrrDirectScanoutEnabled"
    private static let nonRetinaDefaultsKey = "com.metalpie.nonRetinaMode"

    // MARK: - Initialization

    public init(configStore: ConfigStore = ConfigStore()) {
        self.configStore = configStore

        let loadResult = configStore.loadResult()
        let loadedConfig = loadResult.config
        self.config = loadedConfig
        self.selectedProfileID = loadedConfig.defaultProfile.id
        self.selectedScalingModeID = loadedConfig.defaultProfile.scalingModeID
        self.permissions = PermissionsManager.shared.currentStatus()

        let savedVRR = UserDefaults.standard.bool(forKey: Self.vrrDefaultsKey)
        let savedNonRetina = UserDefaults.standard.string(forKey: Self.nonRetinaDefaultsKey)
            .flatMap(NonRetinaDetectionMode.init(rawValue:)) ?? .auto
        self.vrrDirectScanoutEnabled = savedVRR
        self.nonRetinaMode = savedNonRetina

        let device = MTLCreateSystemDefaultDevice()
        self.metalDevice = device

        var supportsMetal3 = false
        var supportsMetal4 = false
        var supportsMetalFX = false
        var workingSetMB = 0
        if let device {
            supportsMetal3 = device.supportsFamily(.metal3)
            if #available(macOS 26.0, *) {
                supportsMetal4 = device.supportsFamily(.metal4)
            }
            supportsMetalFX = MTLFXSpatialScalerDescriptor.supportsDevice(device)
            workingSetMB = Int(device.recommendedMaxWorkingSetSize / (1024 * 1024))
        }

        self.capabilities = SystemCapabilitiesSnapshot(
            gpuName: device?.name ?? "Unavailable",
            supportsMetal3: supportsMetal3,
            supportsMetal4: supportsMetal4,
            supportsMetalFXSpatial: supportsMetalFX,
            supportsVTSuperResolution: VideoToolboxSuperResolution.isSupportedOnSystem,
            supportsVTFrameInterpolation: VideoToolboxMLProcessor.isFrameInterpolationSupportedOnSystem,
            macOSVersionString: ProcessInfo.processInfo.operatingSystemVersionString,
            recommendedWorkingSetMB: workingSetMB
        )

        let renderer: EffectChainRenderer?
        let capture: ScreenCaptureEngine?
        let overlay: OverlayWindowController?
        let renderLoop: RenderLoopController?

        if let device {
            renderer = try? EffectChainRenderer(device: device)
            capture = try? ScreenCaptureEngine(device: device, pipelineDepth: 2, nonRetinaMode: savedNonRetina)
            overlay = try? OverlayWindowController(device: device)
            if let renderer {
                renderLoop = try? RenderLoopController(
                    device: device,
                    effectRenderer: renderer,
                    frameInterpolator: renderer.videoToolboxML
                )
            } else {
                renderLoop = nil
            }
        } else {
            renderer = nil
            capture = nil
            overlay = nil
            renderLoop = nil
        }

        self.effectChainRenderer = renderer
        self.screenCaptureEngine = capture
        self.overlayWindowController = overlay
        self.renderLoopController = renderLoop

        self.cursorController = CursorOverlayController(
            presentationMode: .overlayLayer,
            requireAccessibilityForScaledMode: false,
            watchdog: .shared
        )
        self.hotkeyManager = GlobalHotkeyManager()
        self.windowLifecycleWatcher = WindowLifecycleWatcher(
            excludedBundleIDs: loadedConfig.autoScaleExcludedBundleIDs
        )
        self.autoScaleController = AutoScaleController(config: loadedConfig)

        if let renderer {
            self.shaderCachePath = renderer.shaderManager.binaryArchiveURL.path
        }

        // Parse optional launch arguments: `--tab`, `--lang <en|zh>`, `--run-benchmark`, `--snapshot-out <path>`
        self.snapshotOutputPath = Self.parseStringArgument("--snapshot-out")
        self.autoRunBenchmarkForSnapshot = CommandLine.arguments.contains("--run-benchmark")
        if let langArg = Self.parseStringArgument("--lang")?.lowercased() {
            if langArg == "zh" || langArg == "zh-hans" || langArg == "zhhans" {
                self.languageOverride = .zhHans
            } else if langArg == "en" {
                self.languageOverride = .en
            }
        }
        if let argTab = Self.parseInitialTabArgument() {
            self.selectedTab = argTab
        }

        configureSubsystems()
        refreshShaderCacheMetadata()
        refreshDisplays()
        refreshLogs()

        Task {
            await self.refreshWindows(captureThumbnails: true)
            await self.prewarmDefaultScalingMode()
        }
    }

    private static func parseStringArgument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: flag), idx + 1 < args.count {
            return args[idx + 1]
        }
        return nil
    }

    private static func parseInitialTabArgument() -> AppTab? {
        guard let raw = parseStringArgument("--tab")?.lowercased() else { return nil }
        // Keep legacy `--tab capture` working cleanly after merging Capture & Cursor into Settings.
        if raw == "capture" {
            return .settings
        }
        return AppTab(rawValue: raw)
    }

    // MARK: - Subsystem Wiring

    private func configureSubsystems() {
        // 1. RunGuardWatchdog stall + exit recovery
        watchdog.start()
        watchdogToken = watchdog.registerRecoveryHandler(name: "MetalPieAppCoordinator") { [weak self] in
            RunGuardWatchdog.forceRestoreSystemCursor()
            Task { @MainActor [weak self] in
                await self?.stopScaling(isManual: false, showToast: false)
            }
        }

        // 2. Permissions live polling (also live-upgrades cursor alignment when Accessibility is granted!)
        permissionsManager.startPolling(intervalSeconds: 1.5, stopWhenAllGranted: false) { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasScreenGranted = self.permissions.screenRecordingGranted
                let wasAXGranted = self.permissions.accessibilityGranted
                self.permissions = status
                if !wasScreenGranted && status.screenRecordingGranted {
                    await self.refreshWindows(captureThumbnails: true)
                }
                if !wasAXGranted && status.accessibilityGranted && self.isScalingSessionOpen {
                    self.overlayWindowController?.allowInwardResizeBelowSource = true
                    await self.reconfigureActiveSession()
                    self.showToast(
                        icon: "checkmark.circle.fill",
                        title: self.l10n.tr("Accessibility Enabled", "辅助功能已授权"),
                        subtitle: self.l10n.tr("Cursor aligned.", "光标已对齐"),
                        style: .success,
                        durationSeconds: 2.6
                    )
                } else {
                    self.overlayWindowController?.allowInwardResizeBelowSource = status.accessibilityGranted
                }
            }
        }

        // 3. Cursor alignment mode observer (never fail silently when Accessibility is missing)
        cursorController.setAlignmentModeHandler { [weak self] mode in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cursorAlignmentMode = mode
                self.syncIgnoredOverlayWindowIDsIfNeeded()
                if mode == .accessibilityRequired,
                   self.isScalingSessionOpen,
                   !self.didWarnAccessibilityForCurrentSession
                {
                    self.presentAccessibilityRequiredToast(anchorScreenFrame: self.lastOverlayMetrics?.cocoaFrame)
                }
            }
        }

        // 4. Toolbar actions & scaled-cursor top-edge hover provider
        toolbarPanel.configure(actions: OverlayToolbarActions(
            onToggleClickThrough: { [weak self] in self?.toggleWindowedClickThrough() },
            onToggleProfilerHUD: { [weak self] in self?.toggleProfilerHUD() },
            onCaptureScreenshot: { [weak self] in
                Task { await self?.captureCursorFreeScreenshot() }
            },
            onTogglePresentationMode: { [weak self] in
                Task { await self?.togglePresentationMode() }
            },
            onTogglePause: { [weak self] in self?.togglePaused() },
            onStopScaling: { [weak self] in
                Task { await self?.stopScaling(isManual: true, showToast: true) }
            }
        ))
        toolbarPanel.scaledCursorCocoaProvider = { [weak self] in
            guard let self, self.cursorAlignmentMode == .scaledConfinedEventTap else {
                return nil
            }
            let scaledCG = self.cursorController.currentState.scaledCGPosition
            return ScreenGeometry.cgToCocoa(point: scaledCG, displays: self.displays)
        }
        toolbarPanel.onInteractiveFrameChanged = { [weak self] in
            self?.syncInteractiveChromeRects()
        }
        profilerHUDPanel.onInteractiveFrameChanged = { [weak self] in
            self?.syncInteractiveChromeRects()
        }

        // 4. Overlay geometry & interactive windowed resize callbacks
        overlayWindowController?.isVRRDirectScanoutEnabled = vrrDirectScanoutEnabled
        overlayWindowController?.allowInwardResizeBelowSource = permissions.accessibilityGranted
        overlayWindowController?.onOverlayLevelChanged = { [weak self] newBaseLevel in
            self?.syncLayeredWindowLevels(baseLevel: newBaseLevel)
        }
        overlayWindowController?.onDrawableMetricsChanged = { [weak self] metrics in
            guard let self else { return }
            self.lastOverlayMetrics = metrics
            self.cursorCallbackFastPath.withLock { $0.isVRRDirectScanoutActive = metrics.isVRRDirectScanoutActive }
            self.handleOverlayMetricsChanged(metrics)
        }
        overlayWindowController?.onWindowedFrameChanged = { [weak self] cocoaFrame, _, _ in
            guard let self else { return }
            self.updateChromePanelFrames(for: cocoaFrame)
            if self.isScalingSessionOpen && self.activePresentationMode.isWindowed {
                if self.isInteractiveWindowedDragActive {
                    self.didUserManuallyMoveWindowedOverlay = true
                }
                self.syncSourceWindowUnderWindowedOverlay(
                    overlayCocoaFrame: cocoaFrame,
                    forceImmediate: !self.isInteractiveWindowedDragActive,
                    onlyIfUncovered: false
                )
            }
        }
        overlayWindowController?.onWindowedDragStateChanged = { [weak self] isDragging, cocoaFrame in
            guard let self else { return }
            self.isInteractiveWindowedDragActive = isDragging
            if !isDragging && self.isScalingSessionOpen && self.activePresentationMode.isWindowed {
                self.syncSourceWindowUnderWindowedOverlay(
                    overlayCocoaFrame: cocoaFrame,
                    forceImmediate: true,
                    onlyIfUncovered: false
                )
            }
        }

        // 5. RenderLoop callbacks (first-frame reveal, 5 Hz telemetry, layout updates)
        renderLoopController?.setFirstFrameHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleFirstFramePresented()
            }
        }
        renderLoopController?.setTelemetryHandler { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.handleTelemetryUpdate(snapshot)
            }
        }
        renderLoopController?.setLayoutUpdatedHandler { [weak self] layout in
            Task { @MainActor [weak self] in
                self?.handleLayoutUpdated(layout)
            }
        }

        // 6. Non-Retina 1x Wine/CrossOver auto-demagnify callback
        screenCaptureEngine?.setContentResolutionHandler { [weak self] detected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.detectedContentResolution = detected
                self.applyDemagnifyMode(for: detected)
            }
        }

        // 7. WindowLifecycleWatcher detailed events
        windowLifecycleWatcher.setDetailedEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleWindowLifecycleEvent(event)
            }
        }

        // 8. Global Carbon Hotkeys (plus always-active Panic Stop ⌃⌥⌘⎋)
        registerHotkeys()

        // 9. Auto-Scale controller
        autoScaleController.start { [weak self] trigger in
            Task { @MainActor [weak self] in
                guard let self, !self.isScalingSessionOpen, self.countdownRemaining == nil else { return }
                let mode = self.config.resolvedScalingMode(for: trigger.profile)
                do {
                    try await self.startScaling(
                        window: trigger.window,
                        profile: trigger.profile,
                        scalingMode: mode,
                        presentationOverride: trigger.presentationMode
                    )
                } catch {
                    PipelineLog.shared.warning(.profile, "Auto-scale failed: \(error.localizedDescription)")
                }
            }
        }

        // 10. Periodic lightweight log refresh for Diagnostics view
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.selectedTab == .diagnostics else { return }
                self.refreshLogs()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        logRefreshTimer = timer

        // 11. System sleep, display sleep, and fast-user-switch / screen-lock safety guards:
        //     immediately stop scaling and restore the OS cursor so waking/unlocking never hits
        //     a stuck overlay or hidden cursor.
        let wsCenter = NSWorkspace.shared.notificationCenter
        let sleepSafetyNotifications: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        workspaceSafetyObservers = sleepSafetyNotifications.map { name in
            wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                RunGuardWatchdog.forceRestoreSystemCursor()
                let noteName = note.name.rawValue
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.isScalingSessionOpen || self.countdownRemaining != nil else { return }
                    PipelineLog.shared.info(
                        .app,
                        "Stopping scaling due to workspace safety event '\(noteName)'."
                    )
                    self.cancelCountdown()
                    await self.stopScaling(isManual: false, showToast: false)
                }
            }
        }
    }

    private func prewarmDefaultScalingMode() async {
        guard let renderer = effectChainRenderer else { return }
        let mode = config.resolvedScalingMode(for: config.defaultProfile)
        try? await renderer.prewarm(scalingMode: mode)
        refreshShaderCacheMetadata()
    }

    public func prepareForTermination() {
        countdownTask?.cancel()
        logRefreshTimer?.invalidate()
        let wsCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceSafetyObservers {
            wsCenter.removeObserver(observer)
        }
        workspaceSafetyObservers.removeAll()
        stopPopupMenuMonitor()
        permissionsManager.stopPolling()
        autoScaleController.stop()
        windowLifecycleWatcher.stopObserving()
        hotkeyManager.unregisterAll()
        cursorController.stop()
        renderLoopController?.stop()
        overlayWindowController?.close()
        toolbarPanel.close()
        profilerHUDPanel.close()
        toastPanel.hideImmediately()
        watchdog.setScalingActive(false)
        if let token = watchdogToken {
            watchdog.unregisterRecoveryHandler(token)
            watchdogToken = nil
        }
        RunGuardWatchdog.forceRestoreSystemCursor()
    }

    // MARK: - Persistence & Live Reconfiguration

    /// Atomically saves `config` to disk and live-reconfigures any active scaling session immediately.
    public func persistConfig(
        reconfigureHotkeys: Bool = false,
        reconfigureSession: Bool = true
    ) {
        do {
            try configStore.save(config)
        } catch {
            lastErrorMessage = error.localizedDescription
            PipelineLog.shared.error(.app, "Failed to persist AppConfig: \(error.localizedDescription)")
        }

        autoScaleController.updateConfig(config)
        windowLifecycleWatcher.updateExcludedBundleIDs(config.autoScaleExcludedBundleIDs)

        if reconfigureHotkeys {
            registerHotkeys()
        }

        if isScalingSessionOpen && reconfigureSession {
            Task {
                await self.reconfigureActiveSession()
            }
        }
    }

    public func registerHotkeys() {
        hotkeyWarning = nil
        do {
            try hotkeyManager.register(config: config.hotkeys) { [weak self] action in
                Task { @MainActor [weak self] in
                    await self?.handleHotkeyAction(action)
                }
            }
        } catch {
            hotkeyWarning = error.localizedDescription
            PipelineLog.shared.warning(.input, "Hotkey registration warning: \(error.localizedDescription)")
        }
    }

    public var defaultProfileBindingIndex: Int {
        config.profiles.firstIndex(where: \.isDefault) ?? 0
    }

    /// Returns built-in scaling modes for `scenario` sorted in canonical `ScalingMode.builtInPresets` order,
    /// keeping the 6 official Anime4K modes (`A`, `B`, `C`, `A+A`, `B+B`, `C+A`) cleanly grouped even on upgraded v1.0 configs.
    public func orderedBuiltInModes(for scenario: ScenarioTag) -> [ScalingMode] {
        let rankByID = Dictionary(
            uniqueKeysWithValues: ScalingMode.builtInPresets.enumerated().map { ($0.element.id, $0.offset) }
        )
        return config.scalingModes
            .filter { $0.isBuiltIn && $0.scenario == scenario }
            .sorted { (rankByID[$0.id] ?? Int.max) < (rankByID[$1.id] ?? Int.max) }
    }

    public func updateDefaultProfile(_ mutate: (inout Profile) -> Void) {
        let idx = defaultProfileBindingIndex
        guard config.profiles.indices.contains(idx) else { return }
        mutate(&config.profiles[idx])
        persistConfig(reconfigureSession: true)
    }

    public func updateProfile(id: UUID, _ mutate: (inout Profile) -> Void) {
        guard let idx = config.profiles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&config.profiles[idx])
        persistConfig(reconfigureSession: true)
    }

    public func addProfile(from window: WindowDescriptor) -> Profile {
        let base = config.defaultProfile
        let profile = Profile(
            id: UUID(),
            name: window.appName,
            isDefault: false,
            bundleIdentifier: window.bundleIdentifier,
            appPath: window.appPath,
            windowTitlePattern: nil,
            scalingModeID: base.scalingModeID,
            presentationMode: base.presentationMode,
            outputAlignment: base.outputAlignment,
            multiMonitorMode: base.multiMonitorMode,
            crop: base.crop,
            capture: base.capture,
            cursor: base.cursor,
            frameGen: base.frameGen,
            autoScaleMode: .disabled,
            autoScaleDelaySeconds: 0.5,
            threeDGameMode: base.threeDGameMode,
            toolbarMode: base.toolbarMode,
            showProfilerHUD: base.showProfilerHUD
        )
        config.profiles.append(profile)
        selectedProfileID = profile.id
        persistConfig(reconfigureSession: false)
        return profile
    }

    public func addProfileFromApplicationURL(_ appURL: URL) -> Profile {
        let bundle = Bundle(url: appURL)
        let bundleID = bundle?.bundleIdentifier
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let base = config.defaultProfile
        let profile = Profile(
            id: UUID(),
            name: name,
            isDefault: false,
            bundleIdentifier: bundleID,
            appPath: appURL.path,
            windowTitlePattern: nil,
            scalingModeID: base.scalingModeID,
            presentationMode: base.presentationMode,
            outputAlignment: base.outputAlignment,
            multiMonitorMode: base.multiMonitorMode,
            crop: base.crop,
            capture: base.capture,
            cursor: base.cursor,
            frameGen: base.frameGen,
            autoScaleMode: .disabled,
            autoScaleDelaySeconds: 0.5,
            threeDGameMode: base.threeDGameMode,
            toolbarMode: base.toolbarMode,
            showProfilerHUD: base.showProfilerHUD
        )
        config.profiles.append(profile)
        selectedProfileID = profile.id
        persistConfig(reconfigureSession: false)
        return profile
    }

    public func duplicateProfile(id: UUID) -> Profile? {
        guard let source = config.profiles.first(where: { $0.id == id }) else { return nil }
        let baseName = source.isDefault ? l10n.tr("Default", "默认配置") : source.name
        var copy = source
        copy.id = UUID()
        copy.isDefault = false
        copy.name = "\(baseName) \(l10n.tr("Copy", "副本"))"
        config.profiles.append(copy)
        selectedProfileID = copy.id
        persistConfig(reconfigureSession: false)
        return copy
    }

    public func deleteProfile(id: UUID) {
        guard let idx = config.profiles.firstIndex(where: { $0.id == id && !$0.isDefault }) else { return }
        config.profiles.remove(at: idx)
        if selectedProfileID == id {
            selectedProfileID = config.defaultProfile.id
        }
        persistConfig(reconfigureSession: true)
    }

    /// Immediately pushes the active UI language to floating toolbar & profiler HUD panels.
    public func refreshActiveChromeLanguage() {
        syncToolbarState()
        if isScalingSessionOpen, let metrics = lastOverlayMetrics {
            if metrics.isVRRDirectScanoutActive {
                if isProfilerHUDActive {
                    lastVRRHUDRenderTime = 0
                    updateVRRGPUHUDOverlay(telemetry: telemetry, metrics: metrics)
                }
            } else if isProfilerHUDActive {
                profilerHUDPanel.update(
                    telemetry: telemetry,
                    language: effectiveLanguage,
                    overlayCocoaFrame: metrics.cocoaFrame
                )
            }
        }
    }

    public func updateScalingMode(id: UUID, _ mutate: (inout ScalingMode) -> Void) {
        guard let idx = config.scalingModes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&config.scalingModes[idx])
        persistConfig(reconfigureSession: true)
    }

    public func createNewScalingMode() -> ScalingMode {
        let newMode = ScalingMode(
            id: UUID(),
            name: l10n.tr("Custom Mode", "自定义模式"),
            localizedDescription: "",
            effects: [
                EffectInstance(effectID: .fsr1EASU, scalingType: .fit),
                EffectInstance(effectID: .cas, scalingType: .normal, parameters: ["sharpness": .float(0.35)])
            ],
            isBuiltIn: false
        )
        config.scalingModes.append(newMode)
        selectedScalingModeID = newMode.id
        persistConfig(reconfigureSession: false)
        return newMode
    }

    public func duplicateScalingMode(id: UUID) -> ScalingMode? {
        guard let source = config.scalingMode(for: id) else { return nil }
        let displayName = l10n.builtInModeName(source)
        let copy = ScalingMode(
            id: UUID(),
            name: "\(displayName) \(l10n.tr("Copy", "副本"))",
            localizedDescription: l10n.builtInModeDescription(source),
            effects: source.effects.map { eff in
                var c = eff
                c.id = UUID()
                return c
            },
            isBuiltIn: false
        )
        config.scalingModes.append(copy)
        selectedScalingModeID = copy.id
        persistConfig(reconfigureSession: false)
        return copy
    }

    public func deleteScalingMode(id: UUID) {
        guard let idx = config.scalingModes.firstIndex(where: { $0.id == id && !$0.isBuiltIn }) else { return }
        config.scalingModes.remove(at: idx)
        let fallbackID = config.scalingModes.first?.id ?? ScalingMode.metalFXSpatialID
        for i in config.profiles.indices where config.profiles[i].scalingModeID == id {
            config.profiles[i].scalingModeID = fallbackID
        }
        if selectedScalingModeID == id {
            selectedScalingModeID = fallbackID
        }
        persistConfig(reconfigureSession: true)
    }

    public func exportScalingModes(ids: [UUID]? = nil) throws -> Data {
        let modes: [ScalingMode]
        if let ids {
            let set = Set(ids)
            modes = config.scalingModes.filter { set.contains($0.id) }
        } else {
            modes = config.scalingModes
        }
        return try configStore.exportScalingModes(modes)
    }

    @discardableResult
    public func importScalingModes(from data: Data) throws -> [ScalingMode] {
        let imported = try configStore.importScalingModes(from: data, regenerateIDs: true)
        guard !imported.isEmpty else { return [] }
        config.scalingModes.append(contentsOf: imported)
        if let first = imported.first {
            selectedScalingModeID = first.id
        }
        persistConfig(reconfigureSession: false)
        return imported
    }

    public func resetConfigToDefaults() {
        config = .defaultConfig
        selectedProfileID = config.defaultProfile.id
        selectedScalingModeID = config.defaultProfile.scalingModeID
        persistConfig(reconfigureHotkeys: true, reconfigureSession: true)
        showToast(
            icon: "arrow.counterclockwise.circle.fill",
            title: l10n.tr("Defaults Restored", "已恢复默认"),
            style: .info
        )
    }

    // MARK: - Permissions & Window Discovery

    public func requestScreenRecordingPermission() {
        _ = permissionsManager.requestScreenRecordingAccess()
        permissions = permissionsManager.currentStatus()
    }

    public func requestAccessibilityPermission() {
        _ = permissionsManager.requestAccessibilityAccess(prompt: true)
        permissions = permissionsManager.currentStatus()
    }

    public func openScreenRecordingSettings() {
        _ = permissionsManager.openScreenRecordingSettings()
    }

    public func openAccessibilitySettings() {
        _ = permissionsManager.openAccessibilitySettings()
    }

    public func refreshDisplays() {
        displays = WindowEnumerator.enumerateDisplaysOnMain()
    }

    public func refreshWindows(captureThumbnails: Bool = true) async {
        guard !isRefreshingWindows else { return }
        isRefreshingWindows = true
        defer { isRefreshingWindows = false }

        refreshDisplays()
        let excluded = Set(config.autoScaleExcludedBundleIDs)
        let discovered = await WindowEnumerator.enumerateWindows(
            includeOffScreen: false,
            excludedBundleIDs: excluded
        )
        self.windows = discovered

        guard captureThumbnails, permissions.screenRecordingGranted else { return }
        let visibleIDs = Set(discovered.map(\.windowID))
        windowThumbnails = windowThumbnails.filter { visibleIDs.contains($0.key) }

        for win in discovered.prefix(16) {
            if let cgImg = await WindowEnumerator.captureThumbnail(for: win.windowID, maxDimension: 360) {
                let nsImg = NSImage(
                    cgImage: cgImg,
                    size: NSSize(width: cgImg.width, height: cgImg.height)
                )
                windowThumbnails[win.windowID] = nsImg
            }
        }
    }

    // MARK: - Scaling Session Lifecycle (Fullscreen, Windowed, Countdown)

    public func startCountdownScale(mode: PresentationMode, specificWindow: WindowDescriptor? = nil) {
        cancelCountdown()
        let totalSeconds = max(1, min(config.countdownSeconds, 5))
        countdownRemaining = totalSeconds
        countdownTargetMode = mode
        telemetry.state = .countingDown

        let modeLabel = mode.isFullscreen
            ? l10n.tr("Fullscreen", "全屏")
            : l10n.tr("Windowed", "窗口")
        let targetAnchor = specificWindow.flatMap {
            ScreenGeometry.bestDisplay(forCGRect: $0.cgBounds, in: self.displays)?.cocoaFrame
        }

        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: totalSeconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                self.countdownRemaining = remaining
                self.toastPanel.show(
                    icon: "timer",
                    title: self.l10n.tr(
                        "Scaling (\(modeLabel)) in \(remaining)s",
                        "\(remaining)s 后\(modeLabel)缩放"
                    ),
                    subtitle: specificWindow?.displayName,
                    style: .countdown,
                    durationSeconds: nil,
                    anchorScreenFrame: targetAnchor
                )
                try? await Task.sleep(for: .seconds(1))
            }

            if Task.isCancelled { return }
            self.countdownRemaining = nil
            self.countdownTargetMode = nil
            self.toastPanel.hideImmediately()

            if let specificWindow {
                let profile = self.config.matchingProfile(for: specificWindow)
                let scalingMode = self.config.resolvedScalingMode(for: profile)
                do {
                    try await self.startScaling(
                        window: specificWindow,
                        profile: profile,
                        scalingMode: scalingMode,
                        presentationOverride: mode
                    )
                } catch {
                    self.presentSessionError(error)
                }
            } else {
                await self.startScalingFrontmost(presentationOverride: mode)
            }
        }
    }

    public func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        if countdownRemaining != nil {
            countdownRemaining = nil
            countdownTargetMode = nil
            if telemetry.state == .countingDown {
                telemetry.state = .idle
            }
            toastPanel.dismissAnimated()
        }
    }

    public func startScalingFrontmost(presentationOverride: PresentationMode? = nil) async {
        let candidate: WindowDescriptor?
        if let front = windowLifecycleWatcher.activeFrontmostWindow(),
           front.ownerCategory == .application,
           front.pid != ProcessInfo.processInfo.processIdentifier
        {
            candidate = front
        } else {
            await refreshWindows(captureThumbnails: false)
            candidate = windows.first
        }

        guard let target = candidate else {
            showToast(
                icon: "exclamationmark.triangle.fill",
                title: l10n.tr("No Target Window", "未找到目标窗口"),
                style: .warning
            )
            return
        }

        let profile = config.matchingProfile(for: target)
        let scalingMode = config.resolvedScalingMode(for: profile)
        do {
            try await startScaling(
                window: target,
                profile: profile,
                scalingMode: scalingMode,
                presentationOverride: presentationOverride
            )
        } catch {
            presentSessionError(error)
        }
    }

    public func startScaling(
        window: WindowDescriptor,
        profile: Profile? = nil,
        scalingMode: ScalingMode? = nil,
        presentationOverride: PresentationMode? = nil
    ) async throws {
        guard !isStartingSession else { return }
        isStartingSession = true
        defer { isStartingSession = false }

        cancelCountdown()
        toastPanel.hideImmediately()
        lastErrorMessage = nil

        guard permissionsManager.isScreenRecordingGranted() else {
            permissions = permissionsManager.currentStatus()
            throw EngineError.screenRecordingPermissionDenied
        }

        guard let captureEngine = screenCaptureEngine,
              let overlayController = overlayWindowController,
              let renderLoop = renderLoopController,
              let renderer = effectChainRenderer
        else {
            throw EngineError.metalDeviceUnavailable
        }

        let resolvedProfile = profile ?? config.matchingProfile(for: window)
        let resolvedMode = scalingMode ?? config.resolvedScalingMode(for: resolvedProfile)
        var resolvedPresentation = presentationOverride ?? resolvedProfile.presentationMode

        if resolvedProfile.threeDGameMode && resolvedPresentation.isWindowed {
            resolvedPresentation = .fullscreen
            PipelineLog.shared.info(.app, "3D Game Mode active — forced fullscreen presentation.")
        }

        // Cleanly stop any prior session before starting a new one.
        if isScalingSessionOpen {
            await stopScaling(isManual: false, showToast: false)
        }

        activeWindow = window
        activeProfile = resolvedProfile
        activeScalingMode = resolvedMode
        activePresentationMode = resolvedPresentation
        isPaused = false
        isWindowedClickThrough = true
        isProfilerHUDActive = resolvedProfile.showProfilerHUD
        isToolbarVisibleOverride = nil
        didWarnAccessibilityForCurrentSession = false
        savedSourceWindowGeometry = nil
        didUserManuallyMoveWindowedOverlay = false
        isInteractiveWindowedDragActive = false
        selfRepositionGuard = nil
        cachedAXWindowRef = nil
        lastAXRepositionTime = 0
        lastIgnoredOverlayWindowIDs.removeAll()
        lastSyncedChromeVisibility = nil
        cursorCallbackFastPath.withLock { $0 = CursorCallbackFastPathState() }
        stopPopupMenuMonitor()
        telemetry.state = .starting
        telemetry.targetWindowName = window.displayName

        // Cooperatively yield focus, order back MetalPie's main window, and raise the exact target
        // window BEFORE starting WindowLifecycleWatcher or revealing the overlay so clicking the
        // scaled target never hits MetalPie underneath and never falsely exits scaling!
        await WindowLifecycleWatcher.activateAndRaiseTargetWindow(
            windowID: window.windowID,
            pid: window.pid,
            orderBackOwnMainWindows: true,
            timeoutMilliseconds: 300
        )

        // Prewarm pipelines before opening overlay.
        try await renderer.prewarm(scalingMode: resolvedMode)
        refreshShaderCacheMetadata()

        // Prepare overlay panel (hidden until first upscaled frame presents — zero black flash!).
        overlayController.isVRRDirectScanoutEnabled = vrrDirectScanoutEnabled
        overlayController.allowInwardResizeBelowSource = AXIsProcessTrusted()
        overlayController.isWindowedClickThrough = isWindowedClickThrough
        var metrics = overlayController.prepareOverlay(
            sourceWindow: window,
            profile: resolvedProfile,
            presentationOverride: resolvedPresentation
        )
        lastOverlayMetrics = metrics
        let initialVRR = metrics.isVRRDirectScanoutActive
        cursorCallbackFastPath.withLock { $0.isVRRDirectScanoutActive = initialVRR }

        // In windowed mode, if the source window pokes outside the overlay (e.g., near a display
        // edge or straddling monitors), reposition it cleanly underneath the scaled overlay.
        if resolvedPresentation.isWindowed {
            syncSourceWindowUnderWindowedOverlay(
                overlayCocoaFrame: metrics.cocoaFrame,
                forceImmediate: true,
                onlyIfUncovered: true
            )
            metrics = overlayController.currentDrawableMetrics()
            lastOverlayMetrics = metrics
        }
        let sessionWindow = activeWindow ?? window

        guard let metalLayer = overlayController.metalLayer else {
            overlayController.close()
            throw EngineError.metalDeviceUnavailable
        }

        let effectiveProfile = effectiveProfileForSession(resolvedProfile)
        let renderConfig = RenderSessionConfiguration(
            targetWindowName: sessionWindow.displayName,
            profile: effectiveProfile,
            scalingMode: resolvedMode,
            overlayMetrics: metrics,
            vrrDirectScanout: metrics.isVRRDirectScanoutActive,
            isNativeFullscreenSource: isFullscreenVideoOrGameSource(for: sessionWindow)
        )

        renderLoop.start(
            metalLayer: metalLayer,
            configuration: renderConfig,
            onMarkDisplayLinkAttached: { [weak overlayController] in
                overlayController?.overlayView?.markDisplayLinkAttached()
            }
        )

        // Start zero-copy ScreenCaptureKit stream feeding RenderLoopController.
        do {
            captureEngine.nonRetinaMode = nonRetinaMode
            try await captureEngine.start(
                window: sessionWindow,
                profile: resolvedProfile,
                scalingMode: resolvedMode,
                onFrame: { [weak renderLoop] frame in
                    renderLoop?.ingest(frame: frame)
                },
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        await self?.handleCaptureEvent(event)
                    }
                }
            )
        } catch {
            renderLoop.stop()
            overlayController.close()
            restoreSavedSourceWindowGeometryIfNeeded()
            activeWindow = nil
            activeProfile = nil
            activeScalingMode = nil
            telemetry = .idle
            throw error
        }

        // Wire cursor alignment + VRR external compositor mode
        configureCursorForActiveSession(window: sessionWindow, profile: resolvedProfile, metrics: metrics, layout: nil)

        // Start WindowLifecycleWatcher tracking + 3D Game Mode overlap exclusion
        let initialIgnoredIDs = collectIgnoredOverlayWindowIDs()
        lastIgnoredOverlayWindowIDs = initialIgnoredIDs
        windowLifecycleWatcher.setThreeDGameMode(
            resolvedProfile.threeDGameMode,
            ignoredOverlayWindowIDs: initialIgnoredIDs
        )
        windowLifecycleWatcher.startObserving(trackedWindowID: sessionWindow.windowID) { _ in }

        autoScaleController.setCurrentlyScaling(window: sessionWindow)
        watchdog.setScalingActive(true)

        if cursorAlignmentMode == .accessibilityRequired && !didWarnAccessibilityForCurrentSession {
            presentAccessibilityRequiredToast(anchorScreenFrame: metrics.cocoaFrame)
        }

        PipelineLog.shared.info(
            .app,
            "Started scaling session for '\(window.displayName)' using '\(resolvedMode.name)' (\(resolvedPresentation.isFullscreen ? "fullscreen" : "windowed"))."
        )
    }

    public func stopScaling(
        isManual: Bool = true,
        showToast: Bool = false,
        toastOverride: String? = nil
    ) async {
        let stoppedWindowID = activeWindow?.windowID
        let lastAnchor = lastOverlayMetrics?.cocoaFrame

        watchdog.setScalingActive(false)
        stopPopupMenuMonitor()
        windowLifecycleWatcher.stopObserving()
        cursorController.updateInteractiveChromeRects([])
        cursorController.stop()
        cursorAlignmentMode = .inactive
        didWarnAccessibilityForCurrentSession = false
        toolbarPanel.hide()
        profilerHUDPanel.hide()

        await screenCaptureEngine?.stop()
        renderLoopController?.stop()
        overlayWindowController?.close()

        // If we shifted the source window for edge-coverage without the user manually moving
        // the windowed overlay, restore its original geometry cleanly on stop.
        restoreSavedSourceWindowGeometryIfNeeded()
        savedSourceWindowGeometry = nil
        didUserManuallyMoveWindowedOverlay = false
        isInteractiveWindowedDragActive = false
        selfRepositionGuard = nil
        cachedAXWindowRef = nil
        lastAXRepositionTime = 0
        lastIgnoredOverlayWindowIDs.removeAll()
        lastSyncedChromeVisibility = nil
        cursorCallbackFastPath.withLock { $0 = CursorCallbackFastPathState() }

        autoScaleController.setCurrentlyScaling(window: nil)
        if isManual, let wid = stoppedWindowID {
            autoScaleController.notifyManualStop(windowID: wid)
        }

        activeWindow = nil
        activeProfile = nil
        activeScalingMode = nil
        isPaused = false
        lastLayout = nil
        lastOverlayMetrics = nil
        cachedVRRCursorTexture = nil
        cachedVRRCursorGeneration = 0
        cachedVRRHUDTexture = nil
        telemetry = .idle

        RunGuardWatchdog.forceRestoreSystemCursor()

        // Post-stop safety guard: re-assert OS cursor visibility after 100ms if no new session
        // has started, covering delayed macOS Space transitions (e.g. exiting native fullscreen).
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !self.isScalingSessionOpen else { return }
            RunGuardWatchdog.forceRestoreSystemCursor()
        }

        if showToast {
            self.showToast(
                icon: "stop.circle.fill",
                title: toastOverride ?? l10n.tr("Scaling Stopped", "缩放已停止"),
                style: .info,
                anchorScreenFrame: lastAnchor
            )
        }
    }

    public func togglePresentationMode() async {
        guard isScalingSessionOpen,
              let overlayController = overlayWindowController,
              let window = activeWindow,
              let profile = activeProfile,
              let mode = activeScalingMode
        else {
            return
        }

        if profile.threeDGameMode && activePresentationMode.isFullscreen {
            showToast(
                icon: "lock.shield.fill",
                title: l10n.tr("3D Game Mode: Fullscreen Only", "3D 游戏模式仅支持全屏"),
                style: .warning
            )
            return
        }

        let nextMode: PresentationMode = activePresentationMode.isFullscreen
            ? .windowed(width: overlayController.lastWindowedWidth.map(Double.init))
            : .fullscreen

        activePresentationMode = nextMode
        var metrics = overlayController.setPresentationMode(nextMode, multiMonitorMode: profile.multiMonitorMode)
        lastOverlayMetrics = metrics
        let isVRRActive = metrics.isVRRDirectScanoutActive
        cursorCallbackFastPath.withLock { $0.isVRRDirectScanoutActive = isVRRActive }

        if nextMode.isWindowed {
            syncSourceWindowUnderWindowedOverlay(
                overlayCocoaFrame: metrics.cocoaFrame,
                forceImmediate: true,
                onlyIfUncovered: true
            )
            metrics = overlayController.currentDrawableMetrics()
            lastOverlayMetrics = metrics
        }
        let syncedWindow = activeWindow ?? window

        let effectiveProfile = effectiveProfileForSession(profile)
        renderLoopController?.updateConfiguration(RenderSessionConfiguration(
            targetWindowName: syncedWindow.displayName,
            profile: effectiveProfile,
            scalingMode: mode,
            overlayMetrics: metrics,
            vrrDirectScanout: metrics.isVRRDirectScanoutActive,
            isNativeFullscreenSource: isFullscreenVideoOrGameSource(for: syncedWindow)
        ))

        configureCursorForActiveSession(window: syncedWindow, profile: effectiveProfile, metrics: metrics, layout: lastLayout)
        syncOverlayChromeVisibility(profile: effectiveProfile, metrics: metrics)

        showToast(
            icon: nextMode.isFullscreen ? "arrow.up.left.and.arrow.down.right" : "macwindow",
            title: nextMode.isFullscreen
                ? l10n.tr("Fullscreen", "全屏缩放")
                : l10n.tr("Windowed", "窗口缩放"),
            style: .info
        )
    }

    public func toggleWindowedClickThrough() {
        isWindowedClickThrough.toggle()
        overlayWindowController?.allowInwardResizeBelowSource = AXIsProcessTrusted()
        overlayWindowController?.isWindowedClickThrough = isWindowedClickThrough
        if isWindowedClickThrough {
            cursorController.resume()
        } else {
            // Suspend cursor confinement while unlocked so the user can freely drag/resize overlay edges.
            cursorController.suspend()
        }
        cursorAlignmentMode = cursorController.alignmentMode
        syncToolbarState()
        showToast(
            icon: isWindowedClickThrough ? "lock.fill" : "hand.draw.fill",
            title: isWindowedClickThrough
                ? l10n.tr("Window Locked", "窗口已锁定")
                : l10n.tr("Window Unlocked", "窗口已解锁"),
            style: .info
        )
    }

    public func toggleProfilerHUD() {
        isProfilerHUDActive.toggle()
        if let profile = activeProfile, let metrics = lastOverlayMetrics {
            syncOverlayChromeVisibility(profile: profile, metrics: metrics)
        }
        syncToolbarState()
    }

    public func toggleToolbarVisibility() {
        guard isScalingSessionOpen, let profile = activeProfile, let metrics = lastOverlayMetrics else { return }
        let currentlyVisible = isToolbarVisibleOverride ?? (profile.toolbarMode != .off)
        isToolbarVisibleOverride = !currentlyVisible
        syncOverlayChromeVisibility(profile: profile, metrics: metrics)
    }

    public func togglePaused() {
        guard isScalingSessionOpen else { return }
        isPaused.toggle()
        screenCaptureEngine?.setPaused(isPaused)
        renderLoopController?.setPaused(isPaused)
        if isPaused {
            overlayWindowController?.setPopupMenuLevelBoost(false)
            stopPopupMenuMonitor()
            cursorController.suspend()
            telemetry.state = .suspended
        } else {
            cursorController.resume()
            telemetry.state = .running
            startOrUpdatePopupMenuMonitor()
        }
        syncToolbarState()
    }

    /// Live-reconfigures active capture, render, overlay, cursor, and chrome panels whenever
    /// any profile or scaling mode setting is edited while scaling is running.
    public func reconfigureActiveSession() async {
        guard isScalingSessionOpen,
              let window = activeWindow,
              let oldProfile = activeProfile,
              let overlayController = overlayWindowController,
              let captureEngine = screenCaptureEngine,
              let renderLoop = renderLoopController
        else {
            return
        }

        let updatedProfile = config.profiles.first(where: { $0.id == oldProfile.id })
            ?? config.matchingProfile(for: window)
        let updatedMode = config.resolvedScalingMode(for: updatedProfile)
        let previousPresentation = activePresentationMode

        if updatedProfile.threeDGameMode && activePresentationMode.isWindowed {
            activePresentationMode = .fullscreen
        } else if updatedProfile.presentationMode != oldProfile.presentationMode {
            activePresentationMode = updatedProfile.threeDGameMode ? .fullscreen : updatedProfile.presentationMode
        }

        activeProfile = updatedProfile
        activeScalingMode = updatedMode
        isProfilerHUDActive = updatedProfile.showProfilerHUD

        if let renderer = effectChainRenderer {
            try? await renderer.prewarm(scalingMode: updatedMode)
        }

        overlayController.isVRRDirectScanoutEnabled = vrrDirectScanoutEnabled
        if activePresentationMode != previousPresentation
            || updatedProfile.multiMonitorMode != oldProfile.multiMonitorMode
            || updatedProfile.threeDGameMode != oldProfile.threeDGameMode
        {
            _ = overlayController.setPresentationMode(
                activePresentationMode,
                multiMonitorMode: updatedProfile.multiMonitorMode
            )
        }

        overlayController.updateLayerFormat(
            pixelFormat: updatedProfile.capture.preferredPixelFormat,
            dynamicRange: updatedProfile.capture.dynamicRange,
            displaySyncEnabled: !updatedProfile.capture.lowLatencyPresent || updatedProfile.frameGen.enabled
        )

        var metrics = overlayController.currentDrawableMetrics()
        lastOverlayMetrics = metrics
        let isVRRActive = metrics.isVRRDirectScanoutActive
        cursorCallbackFastPath.withLock { $0.isVRRDirectScanoutActive = isVRRActive }

        if activePresentationMode.isWindowed {
            syncSourceWindowUnderWindowedOverlay(
                overlayCocoaFrame: metrics.cocoaFrame,
                forceImmediate: true,
                onlyIfUncovered: true
            )
            metrics = overlayController.currentDrawableMetrics()
            lastOverlayMetrics = metrics
        }
        let syncedWindow = activeWindow ?? window

        let effectiveProfile = effectiveProfileForSession(updatedProfile)

        try? await captureEngine.updateConfiguration(
            window: syncedWindow,
            profile: effectiveProfile,
            scalingMode: updatedMode
        )

        renderLoop.updateConfiguration(RenderSessionConfiguration(
            targetWindowName: syncedWindow.displayName,
            profile: effectiveProfile,
            scalingMode: updatedMode,
            overlayMetrics: metrics,
            vrrDirectScanout: metrics.isVRRDirectScanoutActive,
            isNativeFullscreenSource: isFullscreenVideoOrGameSource(for: syncedWindow)
        ))

        configureCursorForActiveSession(window: syncedWindow, profile: effectiveProfile, metrics: metrics, layout: lastLayout)
        let ignoredIDs = collectIgnoredOverlayWindowIDs()
        lastIgnoredOverlayWindowIDs = ignoredIDs
        windowLifecycleWatcher.setThreeDGameMode(
            effectiveProfile.threeDGameMode,
            ignoredOverlayWindowIDs: ignoredIDs
        )
        syncOverlayChromeVisibility(profile: effectiveProfile, metrics: metrics)
    }

    private func effectiveProfileForSession(_ profile: Profile) -> Profile {
        var copy = profile
        copy.presentationMode = activePresentationMode
        return copy
    }

    private func isFullscreenVideoOrGameSource(for window: WindowDescriptor) -> Bool {
        if overlayWindowController?.isCoveringNativeFullscreenSpace == true {
            return true
        }
        let currentDisplays = displays.isEmpty ? WindowEnumerator.enumerateDisplaysOnMain() : displays
        return WindowEnumerator.isFullscreenVideoOrGameWindow(
            windowID: window.windowID,
            bounds: window.cgBounds,
            displays: currentDisplays
        )
    }

    // MARK: - Cursor-Free PNG Screenshots

    @discardableResult
    public func captureCursorFreeScreenshot() async -> URL? {
        guard isScalingSessionOpen, let renderLoop = renderLoopController else {
            showToast(
                icon: "camera.badge.ellipsis",
                title: l10n.tr("No Active Session", "当前未在缩放"),
                style: .warning
            )
            return nil
        }

        cursorController.setHiddenForScreenshot(true)
        defer { cursorController.setHiddenForScreenshot(false) }

        do {
            let cgImage = try await renderLoop.requestCursorFreeScreenshot()
            let pngData = try PreviewSampleGenerator.encodePNG(cgImage)

            let dirPath = (config.screenshotDirectory as NSString).expandingTildeInPath
            let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

            let stem = ScreenshotFilenameTemplate.expand(
                template: config.screenshotFilenameTemplate,
                processName: activeWindow?.appName ?? "MetalPie",
                windowTitle: activeWindow?.title ?? ""
            )
            let fileURL = ScreenshotFilenameTemplate.uniqueFileURL(
                in: dirURL,
                baseName: stem,
                fileExtension: "png"
            )
            try pngData.write(to: fileURL, options: [.atomic])
            lastScreenshotURL = fileURL

            PipelineLog.shared.info(.app, "Saved cursor-free PNG screenshot to \(fileURL.path).")
            showToast(
                icon: "camera.fill",
                title: l10n.tr("Screenshot Saved", "截图已保存"),
                subtitle: fileURL.lastPathComponent,
                style: .success
            )
            return fileURL
        } catch {
            PipelineLog.shared.error(.app, "Screenshot failed: \(error.localizedDescription)")
            showToast(
                icon: "exclamationmark.triangle.fill",
                title: l10n.tr("Screenshot Failed", "截图失败"),
                subtitle: error.localizedDescription,
                style: .warning
            )
            return nil
        }
    }

    // MARK: - Real GPU Preview & Shader Benchmarks

    public func renderPreview(
        sourceImage: CGImage,
        scalingMode: ScalingMode,
        outputSize: PixelSize,
        crop: CropInsets = .zero,
        alignment: OutputAlignment = .center,
        isHDR: Bool = false
    ) async throws -> (image: CGImage, elapsedMs: Double) {
        guard let renderer = effectChainRenderer else {
            throw EngineError.metalDeviceUnavailable
        }
        return try await Task.detached(priority: .userInitiated) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let rendered = try renderer.renderPreview(
                sourceImage: sourceImage,
                scalingMode: scalingMode,
                outputSize: outputSize,
                crop: crop,
                alignment: alignment,
                isHDR: isHDR
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            return (rendered, elapsedMs)
        }.value
    }

    public func runShaderBenchmark(
        inputSize: PixelSize,
        outputSize: PixelSize,
        iterations: Int = 5
    ) async {
        guard !isBenchmarkRunning, let renderer = effectChainRenderer else { return }
        isBenchmarkRunning = true
        benchmarkResults = []
        benchmarkProgress = 0
        benchmarkCurrentEffectName = ""
        defer {
            isBenchmarkRunning = false
            benchmarkProgress = 1.0
            benchmarkCurrentEffectName = ""
            refreshShaderCacheMetadata()
        }

        let effects = EffectID.allCases
        let total = Double(max(1, effects.count))

        for (index, effectID) in effects.enumerated() {
            let desc = EffectCatalog.descriptor(for: effectID)
            benchmarkCurrentEffectName = l10n.effectName(desc)
            benchmarkProgress = Double(index) / total

            let batchResult: [ShaderBenchmarkResult] = await Task.detached(priority: .userInitiated) {
                (try? renderer.runBenchmark(
                    effects: [effectID],
                    inputSize: inputSize,
                    outputSize: outputSize,
                    iterations: iterations
                )) ?? []
            }.value

            benchmarkResults.append(contentsOf: batchResult)
        }

        try? renderer.shaderManager.saveBinaryArchive()
        refreshLogs()
    }

    public func clearAndRebuildShaderCache() async {
        guard let renderer = effectChainRenderer else { return }
        do {
            try renderer.shaderManager.clearCache()
            let mode = config.resolvedScalingMode(for: config.defaultProfile)
            try await renderer.prewarm(scalingMode: mode)
            try? renderer.shaderManager.saveBinaryArchive(force: true)
            refreshShaderCacheMetadata()
            refreshLogs()
            showToast(
                icon: "checkmark.seal.fill",
                title: l10n.tr("Cache Rebuilt", "缓存已重建"),
                style: .success
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func refreshShaderCacheMetadata() {
        guard let renderer = effectChainRenderer else { return }
        let url = renderer.shaderManager.binaryArchiveURL
        shaderCachePath = url.path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber
        {
            shaderCacheSizeBytes = size.int64Value
        } else {
            shaderCacheSizeBytes = 0
        }
    }

    public func refreshLogs() {
        logEntries = PipelineLog.shared.entries()
    }

    public func clearLogs() {
        PipelineLog.shared.clear()
        logEntries = []
    }

    public func showToast(
        icon: String,
        title: String,
        subtitle: String? = nil,
        style: ToastStyle = .info,
        durationSeconds: TimeInterval = 2.6,
        anchorScreenFrame: CGRect? = nil
    ) {
        toastPanel.show(
            icon: icon,
            title: title,
            subtitle: subtitle,
            style: style,
            durationSeconds: durationSeconds,
            anchorScreenFrame: anchorScreenFrame ?? lastOverlayMetrics?.cocoaFrame
        )
        if isScalingSessionOpen {
            syncIgnoredOverlayWindowIDsIfNeeded()
        }
    }

    private func presentAccessibilityRequiredToast(anchorScreenFrame: CGRect?) {
        didWarnAccessibilityForCurrentSession = true
        showToast(
            icon: "hand.point.up.left.and.text.fill",
            title: l10n.tr("Accessibility Required", "需要辅助功能权限"),
            subtitle: l10n.tr(
                "Scaled clicks will be offset until enabled.",
                "未开启辅助功能，缩放后光标点击将偏移"
            ),
            style: .warning,
            durationSeconds: 4.5,
            anchorScreenFrame: anchorScreenFrame
        )
    }

    // MARK: - Private Event Handlers & VRR Coordination

    private func handleHotkeyAction(_ action: HotkeyAction) async {
        switch action {
        case .panicStop:
            cancelCountdown()
            await stopScaling(
                isManual: true,
                showToast: true,
                toastOverride: l10n.tr("Force Exited", "已强制退出")
            )
        case .toggleFullscreen:
            if countdownRemaining != nil {
                cancelCountdown()
            } else if isScalingSessionOpen {
                await stopScaling(isManual: true, showToast: true)
            } else {
                await startScalingFrontmost(presentationOverride: .fullscreen)
            }
        case .toggleWindowed:
            if countdownRemaining != nil {
                cancelCountdown()
            } else if isScalingSessionOpen {
                await stopScaling(isManual: true, showToast: true)
            } else {
                await startScalingFrontmost(presentationOverride: .windowed())
            }
        case .toggleToolbar:
            toggleToolbarVisibility()
        case .captureScreenshot:
            await captureCursorFreeScreenshot()
        }
    }

    private func handleFirstFramePresented() {
        guard isScalingSessionOpen,
              let overlayController = overlayWindowController,
              let profile = activeProfile
        else {
            return
        }
        overlayController.revealAfterFirstFrame()
        let metrics = overlayController.currentDrawableMetrics()
        lastOverlayMetrics = metrics
        cursorCallbackFastPath.withLock { $0.isVRRDirectScanoutActive = metrics.isVRRDirectScanoutActive }
        telemetry.state = .running
        syncOverlayChromeVisibility(profile: profile, metrics: metrics)
        syncIgnoredOverlayWindowIDsIfNeeded()
        startOrUpdatePopupMenuMonitor()
    }

    private func handleTelemetryUpdate(_ snapshot: SessionTelemetry) {
        guard isScalingSessionOpen else { return }
        var merged = snapshot
        // Preserve suspended / waitingForWindow state against late in-flight telemetry snapshots.
        if isPaused
            || overlayWindowController?.isSuspended == true
            || telemetry.state == .suspended
            || telemetry.state == .waitingForWindow
        {
            merged.state = telemetry.state
        }
        telemetry = merged
        syncToolbarState()

        guard let metrics = lastOverlayMetrics else { return }
        if metrics.isVRRDirectScanoutActive {
            if isProfilerHUDActive {
                updateVRRGPUHUDOverlay(telemetry: merged, metrics: metrics)
            } else if cachedVRRHUDTexture != nil {
                cachedVRRHUDTexture = nil
                renderLoopController?.updateGPUHUDOverlay(nil)
            }
        } else if isProfilerHUDActive {
            profilerHUDPanel.update(
                telemetry: merged,
                language: effectiveLanguage,
                overlayCocoaFrame: metrics.cocoaFrame
            )
        }
    }

    private func handleLayoutUpdated(_ layout: ScalingLayoutResult) {
        lastLayout = layout
        guard isScalingSessionOpen,
              let window = activeWindow,
              let profile = activeProfile,
              let metrics = lastOverlayMetrics
        else {
            return
        }
        let cursorConfig = buildCursorConfiguration(
            window: window,
            profile: profile,
            metrics: metrics,
            layout: layout
        )
        cursorController.update(configuration: cursorConfig)
        cursorAlignmentMode = cursorController.alignmentMode
        syncIgnoredOverlayWindowIDsIfNeeded()
    }

    private func handleOverlayMetricsChanged(_ metrics: OverlayDrawableMetrics) {
        guard isScalingSessionOpen,
              let window = activeWindow,
              let profile = activeProfile,
              let mode = activeScalingMode
        else {
            return
        }
        let effectiveProfile = effectiveProfileForSession(profile)
        renderLoopController?.updateConfiguration(RenderSessionConfiguration(
            targetWindowName: window.displayName,
            profile: effectiveProfile,
            scalingMode: mode,
            overlayMetrics: metrics,
            vrrDirectScanout: metrics.isVRRDirectScanoutActive,
            isNativeFullscreenSource: isFullscreenVideoOrGameSource(for: window)
        ))
        cursorController.update(configuration: buildCursorConfiguration(
            window: window,
            profile: effectiveProfile,
            metrics: metrics,
            layout: lastLayout
        ))
        cursorAlignmentMode = cursorController.alignmentMode
        syncVRRCursorSnapshotIfNeeded()

        let currentChromeSnapshot = currentChromeVisibilitySnapshot(
            profile: effectiveProfile,
            metrics: metrics
        )
        if lastSyncedChromeVisibility == currentChromeSnapshot {
            updateChromePanelFrames(for: metrics.cocoaFrame)
        } else {
            syncOverlayChromeVisibility(profile: effectiveProfile, metrics: metrics)
        }
    }

    private func handleCaptureEvent(_ event: CaptureSessionEvent) async {
        switch event {
        case .windowBoundsChanged(let newBounds):
            guard isScalingSessionOpen, var window = activeWindow else { return }
            let suppressWindowedOverlayMove = shouldSuppressOverlayUpdateForSelfReposition(
                windowID: window.windowID,
                newBounds: newBounds
            )
            window.cgBounds = newBounds
            activeWindow = window
            overlayWindowController?.updateSourceWindowGeometry(
                newBounds,
                windowID: window.windowID,
                repositionWindowedOverlay: !suppressWindowedOverlayMove
            )
            if let profile = activeProfile, let metrics = lastOverlayMetrics {
                let effectiveProfile = effectiveProfileForSession(profile)
                if let mode = activeScalingMode {
                    renderLoopController?.updateConfiguration(RenderSessionConfiguration(
                        targetWindowName: window.displayName,
                        profile: effectiveProfile,
                        scalingMode: mode,
                        overlayMetrics: metrics,
                        vrrDirectScanout: metrics.isVRRDirectScanoutActive,
                        isNativeFullscreenSource: isFullscreenVideoOrGameSource(for: window)
                    ))
                }
                cursorController.update(configuration: buildCursorConfiguration(
                    window: window,
                    profile: effectiveProfile,
                    metrics: metrics,
                    layout: lastLayout
                ))
                syncVRRCursorSnapshotIfNeeded()
            }
        case .windowClosed:
            if isScalingSessionOpen {
                await stopScaling(isManual: false, showToast: true)
            }
        case .streamStopped(let reason):
            if isScalingSessionOpen {
                await stopScaling(
                    isManual: false,
                    showToast: true,
                    toastOverride: reason.map { l10n.tr("Capture Ended: \($0)", "采集结束：\($0)") }
                )
            }
        default:
            break
        }
    }

    private func handleWindowLifecycleEvent(_ event: DetailedWindowLifecycleEvent) async {
        guard isScalingSessionOpen else {
            if case .screenParametersChanged(let newDisplays) = event {
                displays = newDisplays
                cursorController.updateDisplays(newDisplays)
            }
            return
        }

        switch event {
        case .targetLostFocus:
            // If the same app is still frontmost (e.g. Chrome/Safari entering or exiting HTML5
            // fullscreen video), seamlessly follow the replacement window instead of suspending!
            if let currentWin = activeWindow,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == currentWin.pid,
               await attemptFollowFullscreenReplacementWindow(forPreviousWindow: currentWin, allowShortSettleWait: false)
            {
                return
            }
            // Immediately hide overlay & restore OS cursor on Cmd+Tab (zero stuck overlay!).
            stopPopupMenuMonitor()
            overlayWindowController?.suspend()
            screenCaptureEngine?.setPaused(true)
            renderLoopController?.setPaused(true)
            cursorController.updateInteractiveChromeRects([])
            cursorController.suspend()
            toolbarPanel.hide()
            profilerHUDPanel.hide()
            lastSyncedChromeVisibility = nil
            telemetry.state = .suspended

        case .targetGainedFocus(let refreshedWindow):
            activeWindow = refreshedWindow
            guard !isPaused else { return }
            overlayWindowController?.updateSourceWindowGeometry(
                refreshedWindow.cgBounds,
                windowID: refreshedWindow.windowID
            )
            overlayWindowController?.resume(revealImmediately: false)
            screenCaptureEngine?.setPaused(false)
            renderLoopController?.setPaused(false)
            triggerImmediateRedrawForResume(window: refreshedWindow)
            cursorController.resume()
            telemetry.state = .running
            startOrUpdatePopupMenuMonitor()

        case .targetClosed:
            if let currentWin = activeWindow,
               await attemptFollowFullscreenReplacementWindow(forPreviousWindow: currentWin, allowShortSettleWait: true)
            {
                return
            }
            // Immediately tear down cleanly (zero orphan overlay!).
            await stopScaling(
                isManual: false,
                showToast: true,
                toastOverride: l10n.tr("Window Closed", "窗口已关闭")
            )

        case .targetMinimized:
            if let currentWin = activeWindow,
               await attemptFollowFullscreenReplacementWindow(forPreviousWindow: currentWin, allowShortSettleWait: true)
            {
                return
            }
            // Magpie Auto-Reposition Wait: suspend cleanly and auto-resume upon restore.
            stopPopupMenuMonitor()
            overlayWindowController?.suspend()
            screenCaptureEngine?.setPaused(true)
            renderLoopController?.setPaused(true)
            cursorController.updateInteractiveChromeRects([])
            cursorController.suspend()
            toolbarPanel.hide()
            profilerHUDPanel.hide()
            lastSyncedChromeVisibility = nil
            telemetry.state = .waitingForWindow
            showToast(
                icon: "arrow.down.right.and.arrow.up.left",
                title: l10n.tr("Window Minimized", "窗口已最小化"),
                style: .info
            )

        case .targetRestored(let restoredWindow):
            activeWindow = restoredWindow
            guard !isPaused else { return }
            overlayWindowController?.updateSourceWindowGeometry(
                restoredWindow.cgBounds,
                windowID: restoredWindow.windowID
            )
            if let profile = activeProfile, let mode = activeScalingMode {
                let effectiveProfile = effectiveProfileForSession(profile)
                try? await screenCaptureEngine?.updateConfiguration(
                    window: restoredWindow,
                    profile: effectiveProfile,
                    scalingMode: mode
                )
            }
            overlayWindowController?.resume(revealImmediately: false)
            screenCaptureEngine?.setPaused(false)
            renderLoopController?.setPaused(false)
            triggerImmediateRedrawForResume(window: restoredWindow)
            cursorController.resume()
            telemetry.state = .running
            startOrUpdatePopupMenuMonitor()

        case .targetFrameChanged(let updatedWindow, let newBounds, _):
            let previousBounds = activeWindow?.cgBounds
            let suppressWindowedOverlayMove = shouldSuppressOverlayUpdateForSelfReposition(
                windowID: updatedWindow.windowID,
                newBounds: newBounds
            )
            let sizeUnchanged: Bool
            if let prev = previousBounds {
                sizeUnchanged = abs(prev.width - newBounds.width) < 1.0 && abs(prev.height - newBounds.height) < 1.0
            } else {
                sizeUnchanged = false
            }
            activeWindow = updatedWindow
            overlayWindowController?.updateSourceWindowGeometry(
                newBounds,
                windowID: updatedWindow.windowID,
                repositionWindowedOverlay: !suppressWindowedOverlayMove
            )
            if let profile = activeProfile, let mode = activeScalingMode {
                let effectiveProfile = effectiveProfileForSession(profile)
                // Debounce live resize SCStream updates so titlebar double-click zoom animations and
                // edge drags never trigger mid-animation SCShareableContent / IOSurface teardown storms.
                if !(suppressWindowedOverlayMove && sizeUnchanged) {
                    screenCaptureEngine?.requestDebouncedResizeReconfiguration(
                        window: updatedWindow,
                        profile: effectiveProfile,
                        scalingMode: mode
                    )
                }
                if let metrics = lastOverlayMetrics {
                    let cursorConfig = buildCursorConfiguration(
                        window: updatedWindow,
                        profile: effectiveProfile,
                        metrics: metrics,
                        layout: lastLayout
                    )
                    cursorController.update(configuration: cursorConfig)
                    syncVRRCursorSnapshotIfNeeded()
                }
            }
            syncPopupMonitorSnapshot()

        case .foreignWindowOverlapped(_, let overlapping, _):
            // 3D Game Mode >= 8pt foreign window overlap guard
            await stopScaling(
                isManual: false,
                showToast: true,
                toastOverride: l10n.tr(
                    "Stopped (Overlapped by \(overlapping.appName))",
                    "已停止（\(overlapping.appName) 遮挡）"
                )
            )

        case .screenParametersChanged(let newDisplays):
            displays = newDisplays
            cursorController.updateDisplays(newDisplays)
            syncInteractiveChromeRects()
            syncPopupMonitorSnapshot()

        case .activeSpaceChanged:
            if let currentWin = activeWindow {
                let wasNativeFS = overlayWindowController?.isCoveringNativeFullscreenSpace ?? false
                let followed = await attemptFollowFullscreenReplacementWindow(
                    forPreviousWindow: currentWin,
                    allowShortSettleWait: true
                )
                if !followed && isScalingSessionOpen && activeWindow?.windowID == currentWin.windowID {
                    if let refreshed = WindowEnumerator.windowDescriptor(for: currentWin.windowID),
                       refreshed.isOnScreen
                    {
                        // Same windowID transitioned Spaces (e.g. Chrome/Safari entering or exiting
                        // HTML5 native fullscreen while reusing the same CGWindowID): immediately sync
                        // overlay level/policy, render fullscreen SR gating, and SCStream filter mode!
                        activeWindow = refreshed
                        overlayWindowController?.updateSourceWindowGeometry(
                            refreshed.cgBounds,
                            windowID: refreshed.windowID
                        )
                        if let profile = activeProfile,
                           let mode = activeScalingMode,
                           let overlayController = overlayWindowController
                        {
                            let effectiveProfile = effectiveProfileForSession(profile)
                            let metrics = overlayController.currentDrawableMetrics()
                            lastOverlayMetrics = metrics
                            renderLoopController?.updateConfiguration(RenderSessionConfiguration(
                                targetWindowName: refreshed.displayName,
                                profile: effectiveProfile,
                                scalingMode: mode,
                                overlayMetrics: metrics,
                                vrrDirectScanout: metrics.isVRRDirectScanoutActive,
                                isNativeFullscreenSource: isFullscreenVideoOrGameSource(for: refreshed)
                            ))
                            try? await screenCaptureEngine?.updateConfiguration(
                                window: refreshed,
                                profile: effectiveProfile,
                                scalingMode: mode
                            )
                            cursorController.update(configuration: buildCursorConfiguration(
                                window: refreshed,
                                profile: effectiveProfile,
                                metrics: metrics,
                                layout: lastLayout
                            ))
                            syncVRRCursorSnapshotIfNeeded()
                            syncPopupMonitorSnapshot()
                        }
                    } else if wasNativeFS {
                        // Exited a native Full-Screen Space and the previous fullscreen window is no longer
                        // on screen with no replacement desktop window for the same app: stop cleanly so
                        // neither an orphan overlay nor `.accessory` policy lingers.
                        let sameAppFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == currentWin.pid
                        if sameAppFront {
                            await stopScaling(isManual: false, showToast: false)
                        }
                    }
                }
            }

        case .activeWindowChanged:
            break
        }
    }

    private func buildCursorConfiguration(
        window: WindowDescriptor,
        profile: Profile,
        metrics: OverlayDrawableMetrics,
        layout: ScalingLayoutResult?
    ) -> CursorMappingConfiguration {
        let sourceRect: CGRect
        let contentRect: CGRect
        if let layout, !layout.contentRect.isEmpty {
            sourceRect = PointerMapping.effectiveSourceCGRect(
                sourceWindowCGRect: window.cgBounds,
                layout: layout
            )
            contentRect = layout.contentRect
        } else {
            sourceRect = window.cgBounds
            contentRect = metrics.cgFrame
        }
        return CursorMappingConfiguration(
            sourceCGRect: sourceRect,
            destinationCGRect: contentRect,
            overlayCGRect: metrics.cgFrame,
            backingScaleFactor: metrics.backingScaleFactor,
            settings: profile.cursor,
            threeDGameMode: profile.threeDGameMode
        )
    }

    private func configureCursorForActiveSession(
        window: WindowDescriptor,
        profile: Profile,
        metrics: OverlayDrawableMetrics,
        layout: ScalingLayoutResult?
    ) {
        let isVRR = metrics.isVRRDirectScanoutActive
        cursorCallbackFastPath.withLock { $0.isVRRDirectScanoutActive = isVRR }
        cursorController.setPresentationMode(isVRR ? .externalCompositor : .overlayLayer)

        let fallbackBaseLevel = activePresentationMode.isWindowed
            ? OverlayWindowController.windowedOverlayLevel
            : OverlayWindowController.fullscreenOverlayLevel
        let baseLevel = overlayWindowController?.panel?.level ?? fallbackBaseLevel
        cursorController.setOverlayWindowLevel(NSWindow.Level(rawValue: baseLevel.rawValue + 1))
        cursorController.setPresentationIsWindowed(activePresentationMode.isWindowed)
        cursorController.updateDisplays(displays)

        let cursorConfig = buildCursorConfiguration(
            window: window,
            profile: profile,
            metrics: metrics,
            layout: layout
        )

        if cursorController.isActive {
            cursorController.update(configuration: cursorConfig)
        } else {
            try? cursorController.start(configuration: cursorConfig) { [weak self] _ in
                guard let self else { return }
                let currentCursorWID = self.cursorController.cursorOverlayWindowID
                let needsMainActorWork = self.cursorCallbackFastPath.withLock { fast -> Bool in
                    let cursorWIDChanged = (currentCursorWID != nil && currentCursorWID != fast.registeredCursorOverlayWindowID)
                    if cursorWIDChanged {
                        fast.registeredCursorOverlayWindowID = currentCursorWID
                    }
                    return fast.isVRRDirectScanoutActive || cursorWIDChanged
                }
                guard needsMainActorWork else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.syncVRRCursorSnapshotIfNeeded()
                    self.syncIgnoredOverlayWindowIDsIfNeeded()
                }
            }
        }

        cursorAlignmentMode = cursorController.alignmentMode
        syncIgnoredOverlayWindowIDsIfNeeded()

        if !isVRR {
            renderLoopController?.updateGPUCursorSprite(nil)
            renderLoopController?.updateGPUHUDOverlay(nil)
        } else {
            syncVRRCursorSnapshotIfNeeded()
        }
    }

    /// Forces an immediate redraw from the cached GPU frame after refocus/restore so completely
    /// static target windows never wait indefinitely for a new capture sample to reveal the overlay.
    private func triggerImmediateRedrawForResume(window: WindowDescriptor) {
        guard let overlayController = overlayWindowController,
              let profile = activeProfile,
              let mode = activeScalingMode
        else {
            return
        }
        let metrics = overlayController.currentDrawableMetrics()
        lastOverlayMetrics = metrics
        let effectiveProfile = effectiveProfileForSession(profile)
        renderLoopController?.updateConfiguration(RenderSessionConfiguration(
            targetWindowName: window.displayName,
            profile: effectiveProfile,
            scalingMode: mode,
            overlayMetrics: metrics,
            vrrDirectScanout: metrics.isVRRDirectScanoutActive,
            isNativeFullscreenSource: isFullscreenVideoOrGameSource(for: window)
        ))
        cursorController.update(configuration: buildCursorConfiguration(
            window: window,
            profile: effectiveProfile,
            metrics: metrics,
            layout: lastLayout
        ))
    }

    private func syncVRRCursorSnapshotIfNeeded() {
        guard isScalingSessionOpen,
              let metrics = lastOverlayMetrics,
              metrics.isVRRDirectScanoutActive,
              let device = metalDevice
        else {
            return
        }

        let snap = cursorController.latestRenderSnapshot
        guard snap.state.isVisible else {
            renderLoopController?.updateGPUCursorSprite(GPUCursorSpriteSnapshot(isVisible: false))
            return
        }
        guard let img = snap.image, let geom = snap.spriteGeometry else {
            // SystemCursorMirror initializes asynchronously on startup — schedule a short 50ms retry.
            if !vrrCursorRetryPending {
                vrrCursorRetryPending = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self else { return }
                    self.vrrCursorRetryPending = false
                    self.syncVRRCursorSnapshotIfNeeded()
                }
            }
            return
        }

        if cachedVRRCursorGeneration != img.generation || cachedVRRCursorTexture == nil {
            cachedVRRCursorTexture = PreviewSampleGenerator.makeMetalTexture(from: img.cgImage, device: device)
            cachedVRRCursorGeneration = img.generation
        }

        guard let texture = cachedVRRCursorTexture else { return }
        let drawW = max(1.0, Double(metrics.drawablePixelSize.width))
        let drawH = max(1.0, Double(metrics.drawablePixelSize.height))
        let normPos = CGPoint(
            x: (geom.overlayLocalCGPosition.x * metrics.backingScaleFactor) / drawW,
            y: (geom.overlayLocalCGPosition.y * metrics.backingScaleFactor) / drawH
        )
        let normHotSpot = CGPoint(
            x: img.pointSize.width > 0 ? (img.hotSpot.x / img.pointSize.width) : 0,
            y: img.pointSize.height > 0 ? (img.hotSpot.y / img.pointSize.height) : 0
        )

        let gpuSprite = GPUCursorSpriteSnapshot(
            isVisible: true,
            normalizedPosition: normPos,
            pixelSize: geom.drawablePixelRect.size,
            normalizedHotSpot: normHotSpot,
            useNearestFilter: snap.interpolation == .nearest,
            texture: texture
        )
        renderLoopController?.updateGPUCursorSprite(gpuSprite)
    }

    private func updateVRRGPUHUDOverlay(
        telemetry: SessionTelemetry,
        metrics: OverlayDrawableMetrics
    ) {
        guard let device = metalDevice else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // Cap HUD re-rasterization to ~4 Hz so VRR frame pacing stays butter smooth.
        guard now - lastVRRHUDRenderTime >= 0.24 else { return }
        lastVRRHUDRenderTime = now

        guard let hudImage = ProfilerHUDPanel.renderToCGImage(
            telemetry: telemetry,
            language: effectiveLanguage,
            scale: CGFloat(metrics.backingScaleFactor)
        ),
              let texture = PreviewSampleGenerator.makeMetalTexture(from: hudImage, device: device)
        else {
            return
        }
        cachedVRRHUDTexture = texture
        let margin = Int((16.0 * metrics.backingScaleFactor).rounded())
        let rect = PixelRect(x: margin, y: margin, width: texture.width, height: texture.height)
        renderLoopController?.updateGPUHUDOverlay(GPUHUDOverlaySnapshot(
            isVisible: true,
            pixelRect: rect,
            texture: texture
        ))
    }

    private func resolvedToolbarMode(for profile: Profile) -> ToolbarMode {
        if let overrideVisible = isToolbarVisibleOverride {
            return overrideVisible ? .alwaysShow : .off
        }
        if profile.threeDGameMode {
            return .off
        }
        return profile.toolbarMode
    }

    private func currentChromeVisibilitySnapshot(
        profile: Profile,
        metrics: OverlayDrawableMetrics
    ) -> ChromeVisibilitySnapshot {
        ChromeVisibilitySnapshot(
            isRevealed: overlayWindowController?.isRevealed ?? false,
            isSuspended: overlayWindowController?.isSuspended ?? true,
            isVRRDirectScanoutActive: metrics.isVRRDirectScanoutActive,
            toolbarMode: resolvedToolbarMode(for: profile),
            isProfilerHUDActive: isProfilerHUDActive
        )
    }

    private func syncOverlayChromeVisibility(
        profile: Profile,
        metrics: OverlayDrawableMetrics
    ) {
        let snapshot = currentChromeVisibilitySnapshot(profile: profile, metrics: metrics)
        guard isScalingSessionOpen,
              let overlayController = overlayWindowController,
              overlayController.isRevealed,
              !overlayController.isSuspended
        else {
            lastSyncedChromeVisibility = snapshot
            stopPopupMenuMonitor()
            toolbarPanel.hide()
            profilerHUDPanel.hide()
            syncInteractiveChromeRects()
            return
        }

        lastSyncedChromeVisibility = snapshot

        if metrics.isVRRDirectScanoutActive {
            // ProMotion VRR requires ZERO WindowServer sub-windows above the fullscreen overlay!
            toolbarPanel.hide()
            profilerHUDPanel.hide()
            syncInteractiveChromeRects()
            stopPopupMenuMonitor()
            if isProfilerHUDActive {
                updateVRRGPUHUDOverlay(telemetry: telemetry, metrics: metrics)
            } else {
                renderLoopController?.updateGPUHUDOverlay(nil)
            }
            return
        }

        let fallbackBaseLevel = activePresentationMode.isWindowed
            ? OverlayWindowController.windowedOverlayLevel
            : OverlayWindowController.fullscreenOverlayLevel
        let baseLevel = overlayController.panel?.level ?? fallbackBaseLevel
        let chromeLevel = NSWindow.Level(rawValue: baseLevel.rawValue + 2)

        // 3D Game Mode hides floating toolbar by default unless explicitly toggled on.
        let effectiveToolbarMode = resolvedToolbarMode(for: profile)

        if effectiveToolbarMode == .off {
            toolbarPanel.hide()
        } else {
            toolbarPanel.show(
                mode: effectiveToolbarMode,
                overlayCocoaFrame: metrics.cocoaFrame,
                level: chromeLevel
            )
            syncToolbarState()
        }

        if isProfilerHUDActive {
            profilerHUDPanel.update(
                telemetry: telemetry,
                language: effectiveLanguage,
                overlayCocoaFrame: metrics.cocoaFrame,
                level: chromeLevel
            )
            profilerHUDPanel.show(overlayCocoaFrame: metrics.cocoaFrame, level: chromeLevel)
        } else {
            profilerHUDPanel.hide()
        }

        syncIgnoredOverlayWindowIDsIfNeeded()
        syncInteractiveChromeRects()
        startOrUpdatePopupMenuMonitor()
    }

    // MARK: - Windowed Mode Single-Window AX Synchronization

    private func syncSourceWindowUnderWindowedOverlay(
        overlayCocoaFrame: CGRect,
        forceImmediate: Bool,
        onlyIfUncovered: Bool
    ) {
        guard !isSyncingWindowedSourcePosition,
              isScalingSessionOpen,
              activePresentationMode.isWindowed,
              var window = activeWindow,
              let overlayController = overlayWindowController
        else {
            return
        }

        isSyncingWindowedSourcePosition = true
        defer { isSyncingWindowedSourcePosition = false }

        if displays.isEmpty {
            refreshDisplays()
        }
        let currentDisplays = displays.isEmpty ? WindowEnumerator.enumerateDisplaysOnMain() : displays
        let overlayCG = ScreenGeometry.cocoaToCG(rect: overlayCocoaFrame, displays: currentDisplays).standardized
        let isCurrentlyCovered = OverlayWindowController.overlayCoversSource(
            overlayRect: overlayCG,
            sourceRect: window.cgBounds
        )
        if onlyIfUncovered && isCurrentlyCovered {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        // Throttle live drag AX IPC to ~60 Hz while always allowing immediate moves when source would peek out.
        if !forceImmediate && isCurrentlyCovered && (now - lastAXRepositionTime) < 0.016 {
            return
        }

        let hostDisplay = ScreenGeometry.bestDisplay(forCocoaRect: overlayCocoaFrame, in: currentDisplays)
            ?? ScreenGeometry.primaryDisplay(in: currentDisplays)
        let hostCGBounds = hostDisplay?.cgBounds ?? overlayCG
        let hostVisibleCocoa = hostDisplay.flatMap { WindowEnumerator.nsScreen(for: $0.id)?.visibleFrame }
        let hostScreenCocoa = hostVisibleCocoa
            ?? hostDisplay?.cocoaFrame
            ?? NSScreen.main?.visibleFrame
            ?? overlayCocoaFrame
        let visibleCGBounds: CGRect? = hostVisibleCocoa.map {
            ScreenGeometry.cocoaToCG(rect: $0, displays: currentDisplays)
        }

        // If the user dragged the unlocked windowed overlay smaller than the source window and
        // Accessibility is trusted, shrink the underlying source window via AX `kAXSizeAttribute`
        // (reading back the real accepted size so apps with a larger min size never peek out).
        var didShrinkSourceSize = false
        if AXIsProcessTrusted(),
           (overlayCG.width < window.cgBounds.width - 0.5 || overlayCG.height < window.cgBounds.height - 0.5)
        {
            if savedSourceWindowGeometry == nil {
                savedSourceWindowGeometry = SavedSourceWindowGeometry(
                    windowID: window.windowID,
                    pid: window.pid,
                    cgRect: window.cgBounds
                )
            }
            let targetSourceSize = CGSize(
                width: max(64.0, min(window.cgBounds.width, floor(overlayCG.width))),
                height: max(64.0, min(window.cgBounds.height, floor(overlayCG.height)))
            )
            let expectedResizeRect = CGRect(origin: window.cgBounds.origin, size: targetSourceSize)
            selfRepositionGuard = SelfRepositionGuard(
                windowID: window.windowID,
                expectedCGRect: expectedResizeRect,
                expiresAtUptime: ProcessInfo.processInfo.systemUptime + 0.45
            )
            if let actualSize = setAXWindowSize(
                windowID: window.windowID,
                pid: window.pid,
                cgSize: targetSourceSize
            ) {
                lastAXRepositionTime = now
                if abs(actualSize.width - window.cgBounds.width) >= 0.5
                    || abs(actualSize.height - window.cgBounds.height) >= 0.5
                {
                    didShrinkSourceSize = true
                }
                let resizedRect = CGRect(origin: window.cgBounds.origin, size: actualSize)
                selfRepositionGuard = SelfRepositionGuard(
                    windowID: window.windowID,
                    expectedCGRect: resizedRect,
                    expiresAtUptime: ProcessInfo.processInfo.systemUptime + 0.45
                )
                window.cgBounds = resizedRect
                activeWindow = window
                overlayController.updateSourceWindowGeometry(
                    resizedRect,
                    windowID: window.windowID,
                    repositionWindowedOverlay: false
                )
                if let profile = activeProfile, let mode = activeScalingMode {
                    screenCaptureEngine?.requestDebouncedResizeReconfiguration(
                        window: window,
                        profile: effectiveProfileForSession(profile),
                        scalingMode: mode
                    )
                }
            }
        }

        let targetOrigin = OverlayWindowController.computeHiddenSourceWindowCGOrigin(
            sourceSize: window.cgBounds.size,
            overlayCGRect: overlayCG,
            hostDisplayCGBounds: hostCGBounds,
            hostVisibleCGBounds: visibleCGBounds
        )

        if AXIsProcessTrusted() {
            let needsMove = abs(targetOrigin.x - window.cgBounds.origin.x) >= 1.0
                || abs(targetOrigin.y - window.cgBounds.origin.y) >= 1.0
            if needsMove {
                if savedSourceWindowGeometry == nil {
                    savedSourceWindowGeometry = SavedSourceWindowGeometry(
                        windowID: window.windowID,
                        pid: window.pid,
                        cgRect: window.cgBounds
                    )
                }

                let expectedRect = CGRect(origin: targetOrigin, size: window.cgBounds.size)
                selfRepositionGuard = SelfRepositionGuard(
                    windowID: window.windowID,
                    expectedCGRect: expectedRect,
                    expiresAtUptime: ProcessInfo.processInfo.systemUptime + 0.35
                )

                if let actualOrigin = setAXWindowOrigin(
                    windowID: window.windowID,
                    pid: window.pid,
                    cgOrigin: targetOrigin
                ) {
                    lastAXRepositionTime = now
                    let actualRect = CGRect(origin: actualOrigin, size: window.cgBounds.size)
                    selfRepositionGuard = SelfRepositionGuard(
                        windowID: window.windowID,
                        expectedCGRect: actualRect,
                        expiresAtUptime: ProcessInfo.processInfo.systemUptime + 0.35
                    )
                    window.cgBounds = actualRect
                    activeWindow = window

                    // Sync OverlayWindowController's stored source bounds WITHOUT triggering a feedback move.
                    overlayController.updateSourceWindowGeometry(
                        actualRect,
                        windowID: window.windowID,
                        repositionWindowedOverlay: false
                    )

                    // Update cursor mapping immediately so clicks & hover stay 100% aligned with moved source!
                    if let profile = activeProfile {
                        let metrics = overlayController.currentDrawableMetrics()
                        lastOverlayMetrics = metrics
                        cursorController.update(configuration: buildCursorConfiguration(
                            window: window,
                            profile: effectiveProfileForSession(profile),
                            metrics: metrics,
                            layout: lastLayout
                        ))
                        syncVRRCursorSnapshotIfNeeded()
                    }
                }
            } else if didShrinkSourceSize, let profile = activeProfile {
                let metrics = overlayController.currentDrawableMetrics()
                lastOverlayMetrics = metrics
                cursorController.update(configuration: buildCursorConfiguration(
                    window: window,
                    profile: effectiveProfileForSession(profile),
                    metrics: metrics,
                    layout: lastLayout
                ))
                syncVRRCursorSnapshotIfNeeded()
            }
        }

        // If the target app refused to shrink smaller than its own minimum window size, or macOS clamped
        // the source window (e.g. menu bar), or AX permission is unavailable and the source peeks outside,
        // clamp the overlay cleanly over the real source rect so a second window never peeks out!
        let latestSourceCG = activeWindow?.cgBounds ?? window.cgBounds
        let latestOverlayCocoa = overlayController.panel?.frame ?? overlayCocoaFrame
        let latestOverlayCG = ScreenGeometry.cocoaToCG(rect: latestOverlayCocoa, displays: currentDisplays)
        let sourceRefusedShrink = latestSourceCG.width > latestOverlayCG.width + 1.0
            || latestSourceCG.height > latestOverlayCG.height + 1.0
        if (forceImmediate && !isInteractiveWindowedDragActive) || sourceRefusedShrink {
            if !OverlayWindowController.overlayCoversSource(overlayRect: latestOverlayCG, sourceRect: latestSourceCG) {
                let sourceCocoa = ScreenGeometry.cgToCocoa(rect: latestSourceCG, displays: currentDisplays)
                let adjustedCocoa = OverlayWindowController.ensureOverlayCoversSource(
                    overlayCocoaRect: latestOverlayCocoa,
                    sourceCocoaRect: sourceCocoa,
                    hostScreenCocoa: hostScreenCocoa
                )
                overlayController.setWindowedOverlayCocoaFrame(adjustedCocoa)
                updateChromePanelFrames(for: adjustedCocoa)
            }
        }
        syncPopupMonitorSnapshot()
    }

    private func shouldSuppressOverlayUpdateForSelfReposition(
        windowID: CGWindowID,
        newBounds: CGRect
    ) -> Bool {
        guard activePresentationMode.isWindowed else { return false }
        if isInteractiveWindowedDragActive {
            return true
        }
        guard let activeGuard = selfRepositionGuard else { return false }
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if nowUptime >= activeGuard.expiresAtUptime {
            selfRepositionGuard = nil
            return false
        }
        guard activeGuard.windowID == windowID else { return false }
        let sizeUnchanged = abs(newBounds.width - activeGuard.expectedCGRect.width) < 1.5
            && abs(newBounds.height - activeGuard.expectedCGRect.height) < 1.5
        guard sizeUnchanged else {
            // Genuine external resize must immediately update the windowed overlay!
            return false
        }
        let originDelta = hypot(
            newBounds.origin.x - activeGuard.expectedCGRect.origin.x,
            newBounds.origin.y - activeGuard.expectedCGRect.origin.y
        )
        if originDelta <= 12.0 {
            return true
        }
        if let overlayCG = lastOverlayMetrics?.cgFrame,
           OverlayWindowController.overlayCoversSource(overlayRect: overlayCG, sourceRect: newBounds)
        {
            return true
        }
        return false
    }

    private func restoreSavedSourceWindowGeometryIfNeeded() {
        guard let saved = savedSourceWindowGeometry,
              !didUserManuallyMoveWindowedOverlay,
              AXIsProcessTrusted()
        else {
            return
        }
        _ = setAXWindowSize(windowID: saved.windowID, pid: saved.pid, cgSize: saved.cgRect.size)
        _ = setAXWindowOrigin(windowID: saved.windowID, pid: saved.pid, cgOrigin: saved.cgRect.origin)
    }

    @discardableResult
    private func setAXWindowSize(
        windowID: CGWindowID,
        pid: Int32,
        cgSize: CGSize
    ) -> CGSize? {
        guard let axWin = resolveAXWindowElement(windowID: windowID, pid: pid) else {
            return nil
        }

        var size = cgSize
        guard let axSize = AXValueCreate(.cgSize, &size) else {
            return nil
        }

        var err = AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, axSize)
        if err != .success {
            cachedAXWindowRef = nil
            guard let refreshed = resolveAXWindowElement(windowID: windowID, pid: pid) else {
                return nil
            }
            err = AXUIElementSetAttributeValue(refreshed, kAXSizeAttribute as CFString, axSize)
            guard err == .success else { return nil }
            return readAXWindowSize(refreshed) ?? cgSize
        }

        return readAXWindowSize(axWin) ?? cgSize
    }

    private func readAXWindowSize(_ axWin: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeRef,
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let axVal = unsafeDowncast(sizeRef, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axVal, .cgSize, &size) else {
            return nil
        }
        return size
    }

    @discardableResult
    private func setAXWindowOrigin(
        windowID: CGWindowID,
        pid: Int32,
        cgOrigin: CGPoint
    ) -> CGPoint? {
        guard let axWin = resolveAXWindowElement(windowID: windowID, pid: pid) else {
            return nil
        }

        var point = cgOrigin
        guard let axPoint = AXValueCreate(.cgPoint, &point) else {
            return nil
        }

        var err = AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, axPoint)
        if err != .success {
            // Cached AXUIElement may be stale; re-resolve once and retry.
            cachedAXWindowRef = nil
            guard let refreshed = resolveAXWindowElement(windowID: windowID, pid: pid) else {
                return nil
            }
            err = AXUIElementSetAttributeValue(refreshed, kAXPositionAttribute as CFString, axPoint)
            guard err == .success else { return nil }
            return readAXWindowOrigin(refreshed) ?? cgOrigin
        }

        return readAXWindowOrigin(axWin) ?? cgOrigin
    }

    private func resolveAXWindowElement(windowID: CGWindowID, pid: Int32) -> AXUIElement? {
        if let cached = cachedAXWindowRef, cached.windowID == windowID, cached.pid == pid {
            return cached.element
        }

        typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return nil }
        let getWindowID = unsafeBitCast(sym, to: AXGetWindowFn.self)

        let appElem = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else {
            return nil
        }

        for axWin in axWindows {
            var candidateID: CGWindowID = 0
            if getWindowID(axWin, &candidateID) == .success && candidateID == windowID {
                cachedAXWindowRef = (windowID, pid, axWin)
                return axWin
            }
        }
        return nil
    }

    private func readAXWindowOrigin(_ axWin: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef) == .success,
              let posRef,
              CFGetTypeID(posRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let axVal = unsafeDowncast(posRef, to: AXValue.self)
        var pt = CGPoint.zero
        guard AXValueGetValue(axVal, .cgPoint, &pt) else {
            return nil
        }
        return pt
    }

    // MARK: - Interactive Chrome Rects, Layered Levels, Popup Menu Dedup & Fullscreen Follow

    private func syncInteractiveChromeRects() {
        guard isScalingSessionOpen,
              let overlayController = overlayWindowController,
              overlayController.isRevealed,
              !overlayController.isSuspended,
              !(lastOverlayMetrics?.isVRRDirectScanoutActive ?? false)
        else {
            cursorController.updateInteractiveChromeRects([])
            return
        }

        let currentDisplays = displays.isEmpty ? WindowEnumerator.enumerateDisplaysOnMain() : displays
        var cgRects: [CGRect] = []
        if let toolbarCocoa = toolbarPanel.visibleInteractiveCocoaFrame {
            cgRects.append(ScreenGeometry.cocoaToCG(rect: toolbarCocoa, displays: currentDisplays))
        }
        if let hudCocoa = profilerHUDPanel.visibleInteractiveCocoaFrame {
            cgRects.append(ScreenGeometry.cocoaToCG(rect: hudCocoa, displays: currentDisplays))
        }
        cursorController.updateInteractiveChromeRects(cgRects)
    }

    private func syncLayeredWindowLevels(baseLevel: NSWindow.Level) {
        cursorController.setOverlayWindowLevel(NSWindow.Level(rawValue: baseLevel.rawValue + 1))
        let chromeLevel = NSWindow.Level(rawValue: baseLevel.rawValue + 2)
        toolbarPanel.setLevel(chromeLevel)
        profilerHUDPanel.setLevel(chromeLevel)
    }

    private func startOrUpdatePopupMenuMonitor() {
        syncPopupMonitorSnapshot()
        let shouldRun = popupMenuMonitorState.withLock(\.isActive)
        guard shouldRun else {
            stopPopupMenuMonitor()
            return
        }
        guard popupMenuMonitorTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: popupMenuMonitorQueue)
        timer.schedule(deadline: .now() + .milliseconds(35), repeating: .milliseconds(35), leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            self?.pollPopupMenuWindowBoostOnBackground()
        }
        popupMenuMonitorTimer = timer
        timer.resume()
    }

    private func stopPopupMenuMonitor() {
        popupMenuMonitorTimer?.cancel()
        popupMenuMonitorTimer = nil
        popupMenuMonitorState.withLock { s in
            s.isActive = false
            s.isBoosted = false
            s.isMenuBarDropdownActive = false
            s.overlayWindowID = nil
        }
        overlayWindowController?.setPopupMenuLevelBoost(false)
    }

    private func syncPopupMonitorSnapshot() {
        let isActive = isScalingSessionOpen
            && !isPaused
            && (overlayWindowController?.isRevealed ?? false)
            && !(overlayWindowController?.isSuspended ?? true)
            && !(lastOverlayMetrics?.isVRRDirectScanoutActive ?? false)
        let targetPID = activeWindow?.pid ?? 0
        let sourceRect = activeWindow?.cgBounds ?? .zero
        let currentDisplays = displays.isEmpty ? WindowEnumerator.enumerateDisplaysOnMain() : displays
        let overlayWID: CGWindowID? = {
            guard let num = overlayWindowController?.panel?.windowNumber, num > 0 else { return nil }
            return CGWindowID(num)
        }()
        var mbHeights: [CGDirectDisplayID: CGFloat] = [:]
        for screen in NSScreen.screens {
            if let did = WindowEnumerator.screenDisplayID(for: screen) {
                let topInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
                if topInset > 0 {
                    mbHeights[did] = topInset
                }
            }
        }
        let finalMenuBarHeights = mbHeights
        let boosted = overlayWindowController?.isPopupMenuLevelBoostActive ?? false

        popupMenuMonitorState.withLock { s in
            s.isActive = isActive
            s.targetPID = targetPID
            s.sourceCGRect = sourceRect
            s.displays = currentDisplays
            s.menuBarHeightByDisplayID = finalMenuBarHeights
            s.overlayWindowID = overlayWID
            if !isActive {
                s.isBoosted = false
                s.isMenuBarDropdownActive = false
            } else {
                s.isBoosted = boosted
            }
        }
    }

    nonisolated private func pollPopupMenuWindowBoostOnBackground() {
        let snap = popupMenuMonitorState.withLock { $0 }
        guard snap.isActive, snap.targetPID > 0 else { return }

        let popUpLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let rawList: [[String: Any]]?
        if !snap.isBoosted, let ovWID = snap.overlayWindowID {
            rawList = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], ovWID) as? [[String: Any]]
        } else {
            rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        }

        var popups: [PopupMenuWindowSnapshot] = []
        if let rawList {
            for dict in rawList {
                guard let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue,
                      layer == popUpLayer,
                      let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      pid == snap.targetPID,
                      let widNum = dict[kCGWindowNumber as String] as? NSNumber,
                      let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict)
                else {
                    continue
                }
                let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
                popups.append(PopupMenuWindowSnapshot(
                    windowID: CGWindowID(widNum.uint32Value),
                    pid: pid,
                    layer: layer,
                    bounds: bounds,
                    alpha: alpha
                ))
            }
        }

        let pointerCG: CGPoint?
        if cursorController.alignmentMode == .scaledConfinedEventTap {
            pointerCG = cursorController.currentState.scaledCGPosition
        } else {
            pointerCG = CGEvent(source: nil)?.location
        }

        let evaluation = OverlayWindowController.evaluatePopupMenuLevelBoost(
            popupWindows: popups,
            targetPID: snap.targetPID,
            sourceCGRect: snap.sourceCGRect,
            displays: snap.displays,
            pointerCGPosition: pointerCG,
            menuBarHeightByDisplayID: snap.menuBarHeightByDisplayID,
            wasBoosted: snap.isBoosted,
            wasMenuBarDropdownActive: snap.isMenuBarDropdownActive
        )

        let boostChanged = popupMenuMonitorState.withLock { s -> Bool in
            let changed = (s.isBoosted != evaluation.shouldBoostAbovePopupMenus)
            s.isBoosted = evaluation.shouldBoostAbovePopupMenus
            s.isMenuBarDropdownActive = evaluation.isMenuBarDropdownActive
            return changed
        }

        if boostChanged {
            let shouldBoost = evaluation.shouldBoostAbovePopupMenus
            Task { @MainActor [weak self] in
                guard let self, self.isScalingSessionOpen else { return }
                self.overlayWindowController?.setPopupMenuLevelBoost(shouldBoost)
            }
        }
    }

    private func attemptFollowFullscreenReplacementWindow(
        forPreviousWindow previousWindow: WindowDescriptor,
        allowShortSettleWait: Bool
    ) async -> Bool {
        guard isScalingSessionOpen, !isStartingSession, !isRetargetingFullscreenWindow else {
            return false
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previousWindow.pid else {
            return false
        }

        let currentDisplaysSnapshot = displays.isEmpty ? WindowEnumerator.enumerateDisplaysOnMain() : displays
        let wasFullscreenSource = (overlayWindowController?.isCoveringNativeFullscreenSpace ?? false)
            || currentDisplaysSnapshot.contains {
                WindowEnumerator.boundsCoversDisplay(previousWindow.cgBounds, displayBounds: $0.cgBounds, tolerance: 4.0)
            }
            || WindowEnumerator.isNotchInsetFullscreenBounds(previousWindow.cgBounds, displays: currentDisplaysSnapshot)

        let maxAttempts = allowShortSettleWait ? (wasFullscreenSource ? 5 : 3) : 1
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(110))
                guard isScalingSessionOpen,
                      !isStartingSession,
                      !isRetargetingFullscreenWindow,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == previousWindow.pid
                else {
                    return false
                }
            }

            let currentDisplays = displays.isEmpty ? WindowEnumerator.enumerateDisplaysOnMain() : displays
            if let replacement = WindowLifecycleWatcher.findFullscreenReplacementWindow(
                forPID: previousWindow.pid,
                excluding: previousWindow.windowID,
                displays: currentDisplays
            ) {
                await retargetActiveSession(to: replacement, previousWindowID: previousWindow.windowID)
                return true
            }

            // Smooth fullscreen video exit (`Esc` out of Bilibili/Safari/Chrome/IINA native fullscreen):
            // once the native fullscreen video window leaves/closes and the same app remains frontmost
            // with a normal desktop window (`W1`), seamlessly follow back to `W1` so OverlayWindowController
            // transitions cleanly from level `19` -> `98`/`21` and restores `.regular` activation policy!
            if wasFullscreenSource {
                let prevStillOnScreen = WindowEnumerator.windowDescriptor(for: previousWindow.windowID)?.isOnScreen ?? false
                if !prevStillOnScreen,
                   let desktopFallback = WindowEnumerator.bestTargetWindow(
                       forPID: previousWindow.pid,
                       displays: currentDisplays
                   ),
                   desktopFallback.windowID != previousWindow.windowID
                {
                    await retargetActiveSession(to: desktopFallback, previousWindowID: previousWindow.windowID)
                    return true
                }
            }
        }
        return false
    }

    private func retargetActiveSession(
        to replacement: WindowDescriptor,
        previousWindowID: CGWindowID
    ) async {
        guard isScalingSessionOpen,
              !isRetargetingFullscreenWindow,
              let overlayController = overlayWindowController,
              let captureEngine = screenCaptureEngine,
              let renderLoop = renderLoopController,
              let profile = activeProfile,
              let mode = activeScalingMode
        else {
            return
        }

        isRetargetingFullscreenWindow = true
        defer { isRetargetingFullscreenWindow = false }

        savedSourceWindowGeometry = nil
        cachedAXWindowRef = nil
        selfRepositionGuard = nil
        activeWindow = replacement
        telemetry.targetWindowName = replacement.displayName

        let effectiveProfile = effectiveProfileForSession(profile)
        let metrics = overlayController.prepareOverlay(
            sourceWindow: replacement,
            profile: effectiveProfile,
            presentationOverride: activePresentationMode
        )
        lastOverlayMetrics = metrics
        let isVRR = metrics.isVRRDirectScanoutActive
        cursorCallbackFastPath.withLock { $0.isVRRDirectScanoutActive = isVRR }

        do {
            try await captureEngine.updateConfiguration(
                window: replacement,
                profile: effectiveProfile,
                scalingMode: mode
            )
        } catch {
            PipelineLog.shared.warning(
                .app,
                "Fullscreen follow live filter update failed (\(error.localizedDescription)); keeping session."
            )
        }

        renderLoop.updateConfiguration(RenderSessionConfiguration(
            targetWindowName: replacement.displayName,
            profile: effectiveProfile,
            scalingMode: mode,
            overlayMetrics: metrics,
            vrrDirectScanout: metrics.isVRRDirectScanoutActive,
            isNativeFullscreenSource: isFullscreenVideoOrGameSource(for: replacement)
        ))
        captureEngine.setPaused(isPaused)
        renderLoop.setPaused(isPaused)

        configureCursorForActiveSession(
            window: replacement,
            profile: effectiveProfile,
            metrics: metrics,
            layout: nil
        )
        if !isPaused {
            cursorController.resume()
            overlayController.revealAfterFirstFrame()
            telemetry.state = .running
        }

        windowLifecycleWatcher.updateTrackedWindow(replacement.windowID)
        autoScaleController.setCurrentlyScaling(window: replacement)
        syncOverlayChromeVisibility(profile: effectiveProfile, metrics: metrics)
        syncIgnoredOverlayWindowIDsIfNeeded(force: true)
        startOrUpdatePopupMenuMonitor()

        PipelineLog.shared.info(
            .app,
            "Followed fullscreen replacement window \(replacement.windowID) for '\(replacement.appName)' (replaced \(previousWindowID))."
        )
    }

    private func syncIgnoredOverlayWindowIDsIfNeeded(force: Bool = false) {
        let current = collectIgnoredOverlayWindowIDs()
        if force || current != lastIgnoredOverlayWindowIDs {
            lastIgnoredOverlayWindowIDs = current
            windowLifecycleWatcher.updateIgnoredOverlayWindowIDs(current)
        }
    }

    private func syncToolbarState() {
        toolbarPanel.updateState(
            language: effectiveLanguage,
            telemetry: telemetry,
            isFullscreen: activePresentationMode.isFullscreen,
            isWindowedClickThrough: isWindowedClickThrough,
            isProfilerVisible: isProfilerHUDActive,
            isPaused: isPaused,
            canToggleWindowed: !(activeProfile?.threeDGameMode ?? false)
        )
    }

    private func updateChromePanelFrames(for cocoaFrame: CGRect) {
        toolbarPanel.updateOverlayFrame(cocoaFrame)
        if isProfilerHUDActive {
            profilerHUDPanel.update(
                telemetry: telemetry,
                language: effectiveLanguage,
                overlayCocoaFrame: cocoaFrame
            )
        }
    }

    private func applyDemagnifyMode(for detected: DetectedContentResolution) {
        guard let renderer = effectChainRenderer else { return }
        switch detected {
        case .nativeFull:
            renderer.demagnifyMode = .none
        case .magnifiedNearest2x:
            renderer.demagnifyMode = .nearest
        case .magnifiedBilinear2x:
            renderer.demagnifyMode = .bilinear
        }
    }

    private func collectIgnoredOverlayWindowIDs() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        if let num = overlayWindowController?.panel?.windowNumber, num > 0 {
            ids.insert(CGWindowID(num))
        }
        if let cid = cursorController.cursorOverlayWindowID {
            ids.insert(cid)
        }
        if let tid = toolbarPanel.windowID {
            ids.insert(tid)
        }
        if let hid = profilerHUDPanel.windowID {
            ids.insert(hid)
        }
        if let toastID = toastPanel.windowID {
            ids.insert(toastID)
        }
        return ids
    }

    private func presentSessionError(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        PipelineLog.shared.error(.app, "Scaling session error: \(error.localizedDescription)")
        showToast(
            icon: "exclamationmark.octagon.fill",
            title: l10n.tr("Scaling Failed", "启动失败"),
            subtitle: error.localizedDescription,
            style: .warning
        )
    }
}
