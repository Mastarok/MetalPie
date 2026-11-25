import AppKit
import MetalPieCore
import MetalPieInput
import SwiftUI

/// AppKit lifecycle delegate keeping MetalPie alive in the Menu Bar when the main window closes
/// and guaranteeing clean overlay + cursor teardown on process termination.
@MainActor
final class MetalPieAppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let coordinator else { return false }
        if coordinator.isScalingSessionOpen || coordinator.config.keepRunningInMenuBar {
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.prepareForTermination()
        RunGuardWatchdog.forceRestoreSystemCursor()
    }
}

@main
struct MetalPieApp: App {
    @NSApplicationDelegateAdaptor(MetalPieAppDelegate.self) private var appDelegate
    @State private var coordinator = AppCoordinator()
    @State private var didStartSnapshotTask = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView(coordinator: coordinator)
                .onAppear {
                    appDelegate.coordinator = coordinator
                    if !didStartSnapshotTask, let snapshotPath = coordinator.snapshotOutputPath {
                        didStartSnapshotTask = true
                        Task { @MainActor in
                            await captureMainWindowSnapshotAndExit(to: snapshotPath)
                        }
                    }
                }
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("MetalPie") {
                let l10n = coordinator.l10n
                Button(l10n.tr("Fullscreen Scale", "全屏缩放")) {
                    Task { await coordinator.startScalingFrontmost(presentationOverride: .fullscreen) }
                }
                Button(l10n.tr("Windowed Scale", "窗口缩放")) {
                    Task { await coordinator.startScalingFrontmost(presentationOverride: .windowed()) }
                }
                Button(l10n.tr("Countdown (\(coordinator.config.countdownSeconds)s)", "倒计时 \(coordinator.config.countdownSeconds)s")) {
                    coordinator.startCountdownScale(mode: .fullscreen)
                }
                Divider()
                Button(l10n.tr("Screenshot", "截图")) {
                    Task { await coordinator.captureCursorFreeScreenshot() }
                }
                .disabled(!coordinator.isScalingSessionOpen)
                Button(l10n.tr("Stop", "停止")) {
                    Task { await coordinator.stopScaling(isManual: true, showToast: true) }
                }
                .disabled(!coordinator.isScalingSessionOpen)
            }
        }

        MenuBarExtra {
            menuBarContent
        } label: {
            Label("MetalPie", systemImage: coordinator.isScalingSessionOpen ? "sparkles.tv.fill" : "sparkles.tv")
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var menuBarContent: some View {
        let l10n = coordinator.l10n

        // Status Header
        Group {
            if coordinator.isScalingSessionOpen {
                let fps = coordinator.telemetry.presentedFPS > 0.5
                    ? coordinator.telemetry.presentedFPS
                    : coordinator.telemetry.outputFPS
                Text("● \(l10n.sessionState(coordinator.telemetry.state)) — \(String(format: "%.0f FPS", fps))")
                if let win = coordinator.activeWindow {
                    Text(win.displayName)
                }
            } else if let rem = coordinator.countdownRemaining {
                Text("⏱ \(l10n.tr("Countdown", "倒计时")): \(rem)s…")
            } else {
                Text("MetalPie — \(coordinator.capabilities.gpuName)")
            }
        }

        Divider()

        Button(l10n.tr("Fullscreen Scale", "全屏缩放")) {
            Task { await coordinator.startScalingFrontmost(presentationOverride: .fullscreen) }
        }
        .disabled(!coordinator.permissions.screenRecordingGranted)

        Button(l10n.tr("Windowed Scale", "窗口缩放")) {
            Task { await coordinator.startScalingFrontmost(presentationOverride: .windowed()) }
        }
        .disabled(!coordinator.permissions.screenRecordingGranted)

        Button(l10n.tr("Countdown (\(coordinator.config.countdownSeconds)s)", "倒计时 \(coordinator.config.countdownSeconds)s")) {
            coordinator.startCountdownScale(mode: .fullscreen)
        }
        .disabled(!coordinator.permissions.screenRecordingGranted)

        Divider()

        // Scenario-Grouped Quick Scaling Mode Picker
        Menu(l10n.tr("Scaling Mode", "缩放模式")) {
            let activeID = coordinator.config.defaultProfile.scalingModeID
            ForEach(ScenarioTag.allCases) { tag in
                let modes = coordinator.orderedBuiltInModes(for: tag)
                if !modes.isEmpty {
                    Menu(l10n.scenarioTag(tag)) {
                        ForEach(modes) { mode in
                            Button {
                                coordinator.updateDefaultProfile { $0.scalingModeID = mode.id }
                                coordinator.selectedScalingModeID = mode.id
                            } label: {
                                if mode.id == activeID {
                                    Label(l10n.builtInModeName(mode), systemImage: "checkmark")
                                } else {
                                    Text(l10n.builtInModeName(mode))
                                }
                            }
                        }
                    }
                }
            }
            let customModes = coordinator.config.scalingModes.filter { !$0.isBuiltIn }
            if !customModes.isEmpty {
                Divider()
                ForEach(customModes) { mode in
                    Button {
                        coordinator.updateDefaultProfile { $0.scalingModeID = mode.id }
                        coordinator.selectedScalingModeID = mode.id
                    } label: {
                        if mode.id == activeID {
                            Label(l10n.builtInModeName(mode), systemImage: "checkmark")
                        } else {
                            Text(l10n.builtInModeName(mode))
                        }
                    }
                }
            }
        }

        Divider()

        Button(l10n.tr("Toolbar", "工具栏")) {
            coordinator.toggleToolbarVisibility()
        }
        .disabled(!coordinator.isScalingSessionOpen)

        Button(l10n.tr("Profiler", "监视器")) {
            coordinator.toggleProfilerHUD()
        }
        .disabled(!coordinator.isScalingSessionOpen)

        Button(l10n.tr("Screenshot", "截图")) {
            Task { await coordinator.captureCursorFreeScreenshot() }
        }
        .disabled(!coordinator.isScalingSessionOpen)

        if coordinator.isScalingSessionOpen {
            Divider()
            Button(l10n.tr("Stop", "停止")) {
                Task { await coordinator.stopScaling(isManual: true, showToast: true) }
            }
        } else if coordinator.countdownRemaining != nil {
            Divider()
            Button(l10n.tr("Cancel Countdown", "取消倒计时")) {
                coordinator.cancelCountdown()
            }
        }

        Divider()

        Button(l10n.tr("Open Window", "打开窗口")) {
            NSApp.activate(ignoringOtherApps: true)
            if let existing = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) {
                existing.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
        }

        Button(l10n.tr("Quit MetalPie", "退出 MetalPie")) {
            coordinator.prepareForTermination()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Automated visual verification snapshot helper triggered ONLY when `--snapshot-out <path.png>` is passed.
    /// Waits for window layout, optional GPU preview / benchmark completion, snapshots the live main `NSWindow`
    /// at full Retina resolution without mutating user `config.json`, and exits 0 cleanly.
    @MainActor
    private func captureMainWindowSnapshotAndExit(to outputPath: String) async {
        // Wait for the main NSWindow to materialize and size consistently to 1040×720.
        var targetWindow: NSWindow?
        for _ in 0..<40 {
            if let win = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet && $0.contentView != nil }) {
                targetWindow = win
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard let window = targetWindow else {
            fputs("MetalPie snapshot error: main window did not appear.\n", stderr)
            coordinator.prepareForTermination()
            exit(1)
        }

        window.setContentSize(NSSize(width: 1040, height: 720))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Wait for Metal GPU before/after preview on `--tab effects`.
        if coordinator.selectedTab == .effects {
            for _ in 0..<120 {
                if coordinator.isPreviewReadyForSnapshot { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        // Optional live 30-shader GPU benchmark before snapshotting Diagnostics.
        if coordinator.autoRunBenchmarkForSnapshot {
            coordinator.selectedTab = .diagnostics
            await coordinator.runShaderBenchmark(
                inputSize: PixelSize(width: 1280, height: 720),
                outputSize: PixelSize(width: 2560, height: 1440),
                iterations: 2
            )
        }

        // Wait briefly for initial window list / thumbnails on Home tab.
        if coordinator.selectedTab == .home {
            for _ in 0..<40 {
                if !coordinator.isRefreshingWindows { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        // Let SwiftUI layout & CoreAnimation commit cleanly.
        try? await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let captureView = window.contentView?.superview ?? window.contentView
        guard let view = captureView,
              let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            fputs("MetalPie snapshot error: failed to allocate bitmap rep.\n", stderr)
            coordinator.prepareForTermination()
            exit(1)
        }

        view.cacheDisplay(in: view.bounds, to: bitmapRep)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            fputs("MetalPie snapshot error: failed to encode PNG.\n", stderr)
            coordinator.prepareForTermination()
            exit(1)
        }

        do {
            let outURL = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: outURL, options: [.atomic])
            coordinator.prepareForTermination()
            exit(0)
        } catch {
            fputs("MetalPie snapshot error: \(error.localizedDescription)\n", stderr)
            coordinator.prepareForTermination()
            exit(1)
        }
    }
}
