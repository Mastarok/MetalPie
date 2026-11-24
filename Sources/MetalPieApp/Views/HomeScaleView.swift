import AppKit
import MetalPieCapture
import MetalPieCore
import SwiftUI

/// Primary Home & Scaling Dashboard:
/// - Live Screen Recording & Optional Accessibility permission banner
/// - Active Session Hero Card with real-time telemetry & quick controls
/// - Quick Launch Bar (Preset selector, Fullscreen, Windowed, Countdown)
/// - Live searchable Window Picker Grid with thumbnails, Wine/Fullscreen badges, and 1-click Scale!
struct HomeScaleView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var searchQuery = ""
    @State private var selectedWindowID: CGWindowID?

    private var filteredWindows: [WindowDescriptor] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return coordinator.windows }
        return coordinator.windows.filter { win in
            win.appName.localizedCaseInsensitiveContains(q)
                || win.title.localizedCaseInsensitiveContains(q)
                || (win.bundleIdentifier?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        let l10n = coordinator.l10n

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.tr("Real-Time Window Scaling", "实时窗口超分与帧生成"))
                            .font(.system(size: 22, weight: .bold))
                        Text(l10n.tr(
                            "Upscale any macOS game, Wine/CrossOver title, or video window with Apple Silicon MetalFX, FSR, Anime4K & ML Frame Gen.",
                            "使用 Apple Silicon MetalFX、FSR 1.0、Anime4K 与神经引擎帧生成，实时放大任意游戏、Wine/CrossOver 或视频窗口。"
                        ))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // 1. Live Permissions Banner
                permissionsBanner(l10n: l10n)

                // 2. Active Session Hero Card (or Countdown Banner)
                if coordinator.isScalingSessionOpen {
                    activeSessionHeroCard(l10n: l10n)
                } else if let remaining = coordinator.countdownRemaining {
                    countdownBanner(remaining: remaining, l10n: l10n)
                }

                // 3. Quick Launch Bar
                quickLaunchBar(l10n: l10n)

                // 4. Error Notice if any
                if let err = coordinator.lastErrorMessage, !err.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.system(size: 12))
                        Spacer()
                        Button(l10n.tr("Dismiss", "关闭")) {
                            coordinator.lastErrorMessage = nil
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                // 5. Live Window Picker Grid
                windowPickerSection(l10n: l10n)
            }
            .padding(20)
        }
    }

    // MARK: - Permissions Banner

    private func permissionsBanner(l10n: L10n) -> some View {
        let srGranted = coordinator.permissions.screenRecordingGranted
        let axGranted = coordinator.permissions.accessibilityGranted

        return SectionCard {
            HStack(spacing: 14) {
                // Screen Recording (Required)
                HStack(spacing: 8) {
                    Image(systemName: srGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(srGranted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(l10n.tr("Screen Recording", "屏幕录制权限"))
                                .font(.system(size: 12.5, weight: .semibold))
                            StatusBadge(
                                srGranted ? l10n.tr("Granted", "已授权") : l10n.tr("Required", "必需"),
                                color: srGranted ? .green : .orange
                            )
                        }
                        Text(srGranted
                            ? l10n.tr("Zero-copy ScreenCaptureKit ready.", "ScreenCaptureKit 零拷贝捕获已就绪。")
                            : l10n.tr("Required to capture target game & app windows.", "用于零拷贝捕获目标游戏与应用窗口。"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                if !srGranted {
                    HStack(spacing: 6) {
                        Button(l10n.tr("Grant", "请求权限")) {
                            coordinator.requestScreenRecordingPermission()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)

                        Button(l10n.tr("System Settings", "打开设置")) {
                            coordinator.openScreenRecordingSettings()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }

                Divider()
                    .frame(height: 30)

                // Accessibility (Strictly Optional — NEVER blocks 1:1 scaling!)
                HStack(spacing: 8) {
                    Image(systemName: axGranted ? "hand.point.up.left.fill" : "cursorarrow.motionlines")
                        .font(.system(size: 15))
                        .foregroundStyle(axGranted ? .green : .blue)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(l10n.tr("Accessibility", "辅助功能权限"))
                                .font(.system(size: 12.5, weight: .semibold))
                            StatusBadge(
                                axGranted ? l10n.tr("Granted", "已授权") : l10n.tr("Optional", "可选"),
                                color: axGranted ? .green : .blue
                            )
                        }
                        Text(l10n.tr(
                            "Optional — only for scaled cursor alignment & auto-scale; 1:1 scaling works without it.",
                            "可选 — 仅用于缩放后光标对齐与自动缩放，不影响 1:1 缩放与全局快捷键。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                if !axGranted {
                    HStack(spacing: 6) {
                        Button(l10n.tr("Enable", "启用")) {
                            coordinator.requestAccessibilityPermission()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)

                        Button(l10n.tr("Settings", "设置")) {
                            coordinator.openAccessibilitySettings()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: - Active Session Hero Card

    private func activeSessionHeroCard(l10n: L10n) -> some View {
        let t = coordinator.telemetry
        let isFS = coordinator.activePresentationMode.isFullscreen

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(t.state == .running ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(coordinator.activeWindow?.displayName ?? t.targetWindowName)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text("\(t.backendName) • \(l10n.sessionState(t.state))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    if t.frameGenActive && t.frameGenMultiplier > 1 {
                        StatusBadge("FG \(t.frameGenMultiplier)×", color: .cyan, symbol: "waveform.path.ecg")
                    }
                    if t.hdrActive {
                        StatusBadge("HDR / EDR", color: .orange, symbol: "sun.max.fill")
                    }
                    if coordinator.vrrDirectScanoutEnabled && isFS {
                        StatusBadge(l10n.tr("VRR Direct", "VRR 直扫"), color: .purple, symbol: "bolt.fill")
                    }
                    StatusBadge(
                        isFS ? l10n.tr("Fullscreen", "全屏") : l10n.tr("Windowed", "窗口"),
                        color: .blue
                    )
                }
            }

            HStack(spacing: 12) {
                heroMetric(
                    label: l10n.tr("Resolution", "分辨率"),
                    value: "\(t.inputSize.width)×\(t.inputSize.height) → \(t.outputSize.width)×\(t.outputSize.height)"
                )
                heroMetric(label: l10n.tr("Source FPS", "源帧率"), value: String(format: "%.1f", t.sourceFPS))
                heroMetric(label: l10n.tr("Output FPS", "输出帧率"), value: String(format: "%.1f", t.outputFPS))
                heroMetric(label: l10n.tr("Presented", "呈现帧率"), value: String(format: "%.1f", t.presentedFPS))
                heroMetric(label: l10n.tr("GPU Time", "GPU 耗时"), value: String(format: "%.2f ms", max(t.frameTimeMs, t.totalGPUMilliseconds)))
            }

            HStack(spacing: 8) {
                Button {
                    Task { await coordinator.togglePresentationMode() }
                } label: {
                    Label(
                        isFS ? l10n.tr("Switch to Windowed", "切换为窗口缩放") : l10n.tr("Switch to Fullscreen", "切换为全屏缩放"),
                        systemImage: isFS ? "macwindow" : "arrow.up.left.and.arrow.down.right"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.activeProfile?.threeDGameMode ?? false)

                Button {
                    Task { await coordinator.captureCursorFreeScreenshot() }
                } label: {
                    Label(l10n.tr("Screenshot", "无光标截图"), systemImage: "camera")
                }
                .buttonStyle(.bordered)

                Button {
                    coordinator.toggleProfilerHUD()
                } label: {
                    Label(
                        coordinator.isProfilerHUDActive
                            ? l10n.tr("Hide HUD", "隐藏 HUD")
                            : l10n.tr("Profiler HUD", "性能 HUD"),
                        systemImage: "chart.bar.xaxis"
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    coordinator.togglePaused()
                } label: {
                    Label(
                        coordinator.isPaused ? l10n.tr("Resume", "恢复") : l10n.tr("Pause", "暂停"),
                        systemImage: coordinator.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task { await coordinator.stopScaling(isManual: true, showToast: true) }
                } label: {
                    Label(l10n.tr("Stop Scaling", "停止缩放"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.14), Color.cyan.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1.2)
        }
    }

    private func heroMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func countdownBanner(remaining: Int, l10n: L10n) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "timer")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.tr("Starting Scaling in \(remaining)s…", "\(remaining) 秒后开始缩放…"))
                    .font(.system(size: 15, weight: .bold))
                Text(l10n.tr("Switch (⌘Tab) to your game or target window now.", "现在可以 ⌘Tab 切换到目标游戏或应用窗口。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(l10n.tr("Cancel", "取消倒计时")) {
                coordinator.cancelCountdown()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.4), lineWidth: 1)
        }
    }

    // MARK: - Quick Launch Bar

    private func quickLaunchBar(l10n: L10n) -> some View {
        let defaultProfile = coordinator.config.defaultProfile
        let modeBinding = Binding<UUID>(
            get: { coordinator.config.defaultProfile.scalingModeID },
            set: { newID in
                coordinator.updateDefaultProfile { $0.scalingModeID = newID }
                coordinator.selectedScalingModeID = newID
            }
        )

        return SectionCard(
            title: l10n.tr("Quick Launch", "快速启动"),
            subtitle: l10n.tr(
                "Hotkeys: Fullscreen \(coordinator.config.hotkeys.toggleFullscreen.displayString) • Windowed \(coordinator.config.hotkeys.toggleWindowed.displayString) • Panic Stop ⌃⌥⌘⎋",
                "全局快捷键：全屏 \(coordinator.config.hotkeys.toggleFullscreen.displayString) • 窗口 \(coordinator.config.hotkeys.toggleWindowed.displayString) • 紧急停止 ⌃⌥⌘⎋"
            ),
            symbol: "bolt.circle.fill"
        ) {
            HStack(spacing: 10) {
                Picker(l10n.tr("Scaling Preset", "超分预设"), selection: modeBinding) {
                    ForEach(coordinator.config.scalingModes) { mode in
                        Text(l10n.builtInModeName(mode)).tag(mode.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)

                Spacer(minLength: 4)

                Button {
                    let target = selectedTargetWindow()
                    Task {
                        if let target {
                            do {
                                try await coordinator.startScaling(window: target, presentationOverride: .fullscreen)
                            } catch {
                                coordinator.lastErrorMessage = error.localizedDescription
                            }
                        } else {
                            await coordinator.startScalingFrontmost(presentationOverride: .fullscreen)
                        }
                    }
                } label: {
                    Label(l10n.tr("Scale Fullscreen", "全屏缩放"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.permissions.screenRecordingGranted)

                Button {
                    let target = selectedTargetWindow()
                    Task {
                        if let target {
                            do {
                                try await coordinator.startScaling(window: target, presentationOverride: .windowed())
                            } catch {
                                coordinator.lastErrorMessage = error.localizedDescription
                            }
                        } else {
                            await coordinator.startScalingFrontmost(presentationOverride: .windowed())
                        }
                    }
                } label: {
                    Label(l10n.tr("Scale Windowed", "窗口缩放"), systemImage: "macwindow")
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.permissions.screenRecordingGranted || defaultProfile.threeDGameMode)

                Button {
                    coordinator.startCountdownScale(mode: .fullscreen, specificWindow: nil)
                } label: {
                    Label(
                        l10n.tr("Countdown (\(coordinator.config.countdownSeconds)s)", "倒计时 (\(coordinator.config.countdownSeconds)s)"),
                        systemImage: "timer"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.permissions.screenRecordingGranted)
                .help(l10n.tr(
                    "Starts a \(coordinator.config.countdownSeconds)-second timer so you can ⌘Tab to any game window.",
                    "启动 \(coordinator.config.countdownSeconds) 秒倒计时，便于 ⌘Tab 切换到任意游戏后自动开始缩放。"
                ))
            }
        }
    }

    private func selectedTargetWindow() -> WindowDescriptor? {
        if let selectedWindowID {
            return coordinator.windows.first(where: { $0.windowID == selectedWindowID })
        }
        return nil
    }

    // MARK: - Window Picker Grid

    private func windowPickerSection(l10n: L10n) -> some View {
        let columns = [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 12)]

        return SectionCard(
            title: l10n.tr("Running Windows", "正在运行的可缩放窗口"),
            subtitle: l10n.tr(
                "\(filteredWindows.count) capturable windows across \(coordinator.displays.count) display(s)",
                "共检测到 \(coordinator.displays.count) 台显示器上的 \(filteredWindows.count) 个可捕获窗口"
            ),
            symbol: "macwindow.on.rectangle"
        ) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(l10n.tr("Filter by app name or window title…", "按应用名称或窗口标题筛选…"), text: $searchQuery)
                        .textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    Task { await coordinator.refreshWindows(captureThumbnails: true) }
                } label: {
                    Label(l10n.tr("Refresh", "刷新列表"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.isRefreshingWindows)
            }

            if filteredWindows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(l10n.tr("No Matching Capturable Windows", "未找到匹配的可缩放窗口"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(l10n.tr(
                        "Open a game or application window and click Refresh, or use Countdown Scale.",
                        "请打开目标游戏或应用窗口后点击“刷新列表”，或使用“倒计时缩放”。"
                    ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredWindows) { win in
                        windowCard(win, l10n: l10n)
                    }
                }
            }
        }
    }

    private func windowCard(_ window: WindowDescriptor, l10n: L10n) -> some View {
        let isSelected = selectedWindowID == window.windowID
        let isActiveTarget = coordinator.activeWindow?.windowID == window.windowID
        let display = ScreenGeometry.bestDisplay(forCGRect: window.cgBounds, in: coordinator.displays)
        let isWineOrFullscreen = (window.bundleIdentifier?.lowercased().contains("wine") ?? false)
            || (window.bundleIdentifier?.lowercased().contains("crossover") ?? false)
            || (display.map { WindowEnumerator.boundsCoversDisplay(window.cgBounds, displayBounds: $0.cgBounds) } ?? false)
        let matchedProfile = coordinator.config.matchingProfile(for: window)
        let thumb = coordinator.windowThumbnails[window.windowID]

        return VStack(alignment: .leading, spacing: 8) {
            // Thumbnail Preview
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .frame(height: 118)
                    .overlay {
                        if let thumb {
                            Image(nsImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 118)
                                .clipped()
                        } else {
                            VStack(spacing: 5) {
                                Image(systemName: "macwindow")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: "\(window.estimatedPixelSize.width)×\(window.estimatedPixelSize.height)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 4) {
                    if isActiveTarget {
                        StatusBadge(l10n.tr("ACTIVE", "缩放中"), color: .green)
                    } else if isWineOrFullscreen {
                        StatusBadge(l10n.tr("Fullscreen / Wine", "全屏/Wine"), color: .purple)
                    }
                }
                .padding(6)
            }

            // Metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(window.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(window.title.isEmpty ? l10n.tr("Untitled Window", "无标题窗口") : window.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(verbatim: "\(window.estimatedPixelSize.width)×\(window.estimatedPixelSize.height) px")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let display {
                        Text("• \(display.name)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // Actions
            HStack(spacing: 6) {
                if !matchedProfile.isDefault {
                    StatusBadge(matchedProfile.name, color: .cyan)
                }
                Spacer(minLength: 4)

                Button {
                    Task {
                        do {
                            try await coordinator.startScaling(window: window, presentationOverride: .windowed())
                        } catch {
                            coordinator.lastErrorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "macwindow")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(!coordinator.permissions.screenRecordingGranted || matchedProfile.threeDGameMode)
                .help(l10n.tr("Scale in Resizable Window", "窗口模式缩放"))

                Button {
                    Task {
                        do {
                            try await coordinator.startScaling(window: window, presentationOverride: .fullscreen)
                        } catch {
                            coordinator.lastErrorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label(l10n.tr("Scale", "全屏缩放"), systemImage: "play.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.permissions.screenRecordingGranted)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isActiveTarget ? Color.green.opacity(0.6) : (isSelected ? Color.accentColor : Color.primary.opacity(0.08)),
                    lineWidth: (isSelected || isActiveTarget) ? 1.5 : 1
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedWindowID = window.windowID
        }
    }
}
