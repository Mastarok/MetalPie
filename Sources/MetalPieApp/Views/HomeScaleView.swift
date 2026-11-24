import AppKit
import MetalPieCapture
import MetalPieCore
import SwiftUI

/// Primary Home & Quick Start Dashboard (`开始缩放` / `Scale`):
/// - Dismissible 3-Step Quick Start Guide (with `?` toggle button)
/// - Honest Screen Recording & Accessibility Permission Status Strip
/// - Active Session Card with monitor badge, live FPS/resolution, quick controls,
///   and actionable Accessibility live-upgrade banner whenever `needsAccessibilityForScaledClicks` is true
/// - Scenario Quick Chips + Grouped Preset Picker + Clear Launch Bar
/// - Live Searchable Window Picker Grid with thumbnails & clear monitor badges
struct HomeScaleView: View {
    @Bindable var coordinator: AppCoordinator
    @AppStorage("com.metalpie.showQuickStartGuide") private var showQuickStartGuide: Bool = true
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
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.tr("Scale Windows", "开始缩放"))
                            .font(.system(size: 22, weight: .bold))
                        Text(l10n.tr(
                            "Upscale any game, anime, or video window sharply on Apple Silicon — with optional 2×–4× frame generation.",
                            "把任意小窗口游戏、动漫番剧或视频一键高清放大到全屏或大窗口，还能开启 2×–4× 流畅补帧。"
                        ))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showQuickStartGuide.toggle()
                        }
                    } label: {
                        Image(systemName: showQuickStartGuide ? "questionmark.circle.fill" : "questionmark.circle")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(showQuickStartGuide ? Color.accentColor : .secondary)
                    .help(l10n.tr("Show / Hide 3-Step Quick Guide", "显示 / 隐藏三步快速上手指南"))
                }

                // 1. Dismissible 3-Step Quick Start Guide
                if showQuickStartGuide {
                    quickStartGuideBanner(l10n: l10n)
                }

                // 2. Honest Permissions Status Strip
                permissionsBanner(l10n: l10n)

                // 3. Active Session Card (or Countdown Banner)
                if coordinator.isScalingSessionOpen {
                    activeSessionHeroCard(l10n: l10n)
                } else if let remaining = coordinator.countdownRemaining {
                    countdownBanner(remaining: remaining, l10n: l10n)
                }

                // 4. Scenario Quick Picker + Launch Bar
                quickLaunchBar(l10n: l10n)

                // 5. Error Notice if any
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

                // 6. Live Window Picker Grid
                windowPickerSection(l10n: l10n)
            }
            .padding(20)
        }
    }

    // MARK: - 3-Step Quick Start Guide

    private func quickStartGuideBanner(l10n: L10n) -> some View {
        let fsHotkey = coordinator.config.hotkeys.toggleFullscreen.isEnabled
            ? coordinator.config.hotkeys.toggleFullscreen.displayString
            : "⌥⇧A"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.cyan)
                Text(l10n.tr("3-Step Quick Start", "三步快速上手"))
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showQuickStartGuide = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(l10n.tr("Got it", "我知道了"))
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 10) {
                quickStepTile(
                    number: "1",
                    title: l10n.tr("Pick a Window", "选中目标窗口"),
                    detail: l10n.tr(
                        "Click a window below, or switch to your game/video window first.",
                        "选中下方窗口，或先切到你想放大的游戏/视频窗口。"
                    )
                )
                quickStepTile(
                    number: "2",
                    title: l10n.tr("Choose a Mode", "选个合适模式"),
                    detail: l10n.tr(
                        "Pick a scenario below: 3D Games, Anime, Pixel Art, or General Video.",
                        "按场景一键选好「缩放模式」（游戏 / 动漫 / 像素 / 通用）。"
                    )
                )
                quickStepTile(
                    number: "3",
                    title: l10n.tr("Scale & Exit Anytime", "放大与随时退出"),
                    detail: l10n.tr(
                        "Click Fullscreen Scale or press \(fsHotkey). Press ⌃⌥⌘⎋ anytime to force exit.",
                        "点「全屏放大」或按 \(fsHotkey) 即可放大，按 ⌃⌥⌘⎋ 随时一键退出。"
                    )
                )
            }
        }
        .padding(13)
        .background(
            LinearGradient(
                colors: [Color.cyan.opacity(0.11), Color.blue.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.28), lineWidth: 1)
        }
    }

    private func quickStepTile(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Honest Permissions Strip

    private func permissionsBanner(l10n: L10n) -> some View {
        let srGranted = coordinator.permissions.screenRecordingGranted
        let axGranted = coordinator.permissions.accessibilityGranted

        return SectionCard {
            HStack(alignment: .center, spacing: 14) {
                // Screen Recording
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: srGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(srGranted ? .green : .orange)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(l10n.tr("Screen Recording", "屏幕录制"))
                                .font(.system(size: 12.5, weight: .semibold))
                            StatusBadge(
                                srGranted ? l10n.tr("Enabled", "已开启") : l10n.tr("Required", "必需"),
                                color: srGranted ? .green : .orange
                            )
                        }
                        Text(srGranted
                            ? l10n.tr("Ready to read window frames at full speed.", "已就绪，可实时读取窗口画面。")
                            : l10n.tr("Required to read and upscale your target window.", "未开启 — 用于读取窗口画面。"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !srGranted {
                    HStack(spacing: 6) {
                        Button(l10n.tr("Grant", "立即授权")) {
                            coordinator.requestScreenRecordingPermission()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)

                        Button(l10n.tr("Settings", "打开设置")) {
                            coordinator.openScreenRecordingSettings()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }

                Divider()
                    .frame(height: 36)

                // Accessibility — NEVER labeled merely "Optional"!
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: axGranted ? "hand.point.up.left.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(axGranted ? .green : .orange)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(l10n.tr("Accessibility", "辅助功能"))
                                .font(.system(size: 12.5, weight: .semibold))
                            StatusBadge(
                                axGranted
                                    ? l10n.tr("Enabled", "已开启")
                                    : l10n.tr("Needed for Scaled Clicks", "缩放点击必需"),
                                color: axGranted ? .green : .orange
                            )
                        }
                        Text(axGranted
                            ? l10n.tr("Scaled mouse clicks stay aligned and locked inside the window.", "放大画面后，鼠标点击按钮精准对齐、不会误点桌面退出。")
                            : l10n.tr(
                                "Required for scaled click alignment (only optional for 1:1) — prevents missed clicks & accidental exit.",
                                "缩放后鼠标精准点击必需（仅 1:1 缩放可不开）— 开启后放大画面点击不错位、不误退回桌面。"
                            ))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !axGranted {
                    HStack(spacing: 6) {
                        Button(l10n.tr("Enable", "一键开启")) {
                            coordinator.requestAccessibilityPermission()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button(l10n.tr("Settings", "系统设置")) {
                            coordinator.openAccessibilitySettings()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Active Session Hero Card

    private func activeSessionHeroCard(l10n: L10n) -> some View {
        let t = coordinator.telemetry
        let isFS = coordinator.activePresentationMode.isFullscreen
        let targetDisplay = coordinator.activeWindow.flatMap {
            ScreenGeometry.bestDisplay(forCGRect: $0.cgBounds, in: coordinator.displays)
        }
        let activeModeLabel = coordinator.activeScalingMode.map { l10n.builtInModeName($0) } ?? t.backendName

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(t.state == .running ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.activeWindow?.displayName ?? t.targetWindowName)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text("\(activeModeLabel) • \(l10n.sessionState(t.state))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 6) {
                    if let targetDisplay {
                        StatusBadge(targetDisplay.name, color: .indigo, symbol: "display")
                    }
                    if t.frameGenActive && t.frameGenMultiplier > 1 {
                        StatusBadge(l10n.tr("FG \(t.frameGenMultiplier)×", "补帧 \(t.frameGenMultiplier)×"), color: .cyan, symbol: "waveform.path.ecg")
                    }
                    if t.hdrActive {
                        StatusBadge("HDR", color: .orange, symbol: "sun.max.fill")
                    }
                    if coordinator.vrrDirectScanoutEnabled && isFS {
                        StatusBadge(l10n.tr("VRR Direct", "高刷直出"), color: .purple, symbol: "bolt.fill")
                    }
                    StatusBadge(
                        isFS ? l10n.tr("Fullscreen", "全屏放大") : l10n.tr("Windowed", "窗口放大"),
                        color: .blue
                    )
                }
            }

            // Actionable Accessibility Warning Callout whenever non-1:1 session lacks AX trust
            if coordinator.needsAccessibilityForScaledClicks {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "hand.point.up.left.and.text.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.tr(
                            "Accessibility Not Enabled — Scaled Clicks May Miss or Exit",
                            "未开启辅助功能 — 放大后点击按钮会错位，且容易误点桌面退出"
                        ))
                        .font(.system(size: 12, weight: .bold))
                        Text(l10n.tr(
                            "Grant Accessibility now and MetalPie will align your cursor automatically without restarting scaling.",
                            "现在开启辅助功能后，MetalPie 会自动对齐鼠标位置，无需重新开始缩放。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button {
                        coordinator.requestAccessibilityPermission()
                    } label: {
                        Label(
                            l10n.tr("Enable Accessibility", "去开启辅助功能（开启后自动对齐鼠标）"),
                            systemImage: "lock.open.fill"
                        )
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button(l10n.tr("System Settings", "打开设置")) {
                        coordinator.openAccessibilitySettings()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
                }
            }

            HStack(spacing: 10) {
                heroMetric(
                    label: l10n.tr("Resolution", "画面分辨率"),
                    value: "\(t.inputSize.width)×\(t.inputSize.height) → \(t.outputSize.width)×\(t.outputSize.height)"
                )
                heroMetric(label: l10n.tr("Source FPS", "原始帧率"), value: String(format: "%.1f", t.sourceFPS))
                heroMetric(label: l10n.tr("Output FPS", "放大帧率"), value: String(format: "%.1f", t.presentedFPS > 0.5 ? t.presentedFPS : t.outputFPS))
                heroMetric(label: l10n.tr("GPU Time", "显卡耗时"), value: String(format: "%.2f ms", max(t.frameTimeMs, t.totalGPUMilliseconds)))
            }

            HStack(spacing: 8) {
                Button {
                    Task { await coordinator.togglePresentationMode() }
                } label: {
                    Label(
                        isFS ? l10n.tr("Switch to Windowed", "切换为窗口放大") : l10n.tr("Switch to Fullscreen", "切换为全屏放大"),
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
                            ? l10n.tr("Hide FPS Overlay", "隐藏帧率信息")
                            : l10n.tr("FPS Overlay", "显示帧率信息"),
                        systemImage: "chart.bar.xaxis"
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    coordinator.togglePaused()
                } label: {
                    Label(
                        coordinator.isPaused ? l10n.tr("Resume", "继续") : l10n.tr("Pause", "暂停"),
                        systemImage: coordinator.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task { await coordinator.stopScaling(isManual: true, showToast: true) }
                } label: {
                    Label(l10n.tr("Exit Scaling", "退出缩放"), systemImage: "stop.fill")
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
                Text(l10n.tr("Scaling in \(remaining)s…", "\(remaining) 秒后自动放大…"))
                    .font(.system(size: 15, weight: .bold))
                Text(l10n.tr("Switch (⌘Tab) to your game or video window now.", "现在请切到你想放大的游戏或视频窗口。"))
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

    // MARK: - Scenario Quick Picker + Launch Bar

    private func quickLaunchBar(l10n: L10n) -> some View {
        let defaultProfile = coordinator.config.defaultProfile
        let activeMode = coordinator.config.resolvedScalingMode(for: defaultProfile)
        let modeBinding = Binding<UUID>(
            get: { coordinator.config.defaultProfile.scalingModeID },
            set: { newID in
                coordinator.updateDefaultProfile { $0.scalingModeID = newID }
                coordinator.selectedScalingModeID = newID
            }
        )

        return SectionCard(
            title: l10n.tr("Choose Mode & Start Scaling", "选择缩放模式并开始"),
            subtitle: l10n.tr(
                "Shortcuts: Fullscreen \(coordinator.config.hotkeys.toggleFullscreen.displayString) • Windowed \(coordinator.config.hotkeys.toggleWindowed.displayString) • Force Exit ⌃⌥⌘⎋",
                "快捷键：全屏放大 \(coordinator.config.hotkeys.toggleFullscreen.displayString) • 窗口放大 \(coordinator.config.hotkeys.toggleWindowed.displayString) • 强制退出 ⌃⌥⌘⎋"
            ),
            symbol: "bolt.circle.fill"
        ) {
            // One-click Scenario Quick Chips
            HStack(spacing: 8) {
                ForEach(ScenarioTag.allCases) { tag in
                    let isSelected = activeMode.scenario == tag && activeMode.isBuiltIn
                    Button {
                        selectRecommendedMode(for: tag)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tag.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                            Text(l10n.scenarioTag(tag))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 8)

                Button {
                    coordinator.selectedScalingModeID = activeMode.id
                    coordinator.selectedTab = .effects
                } label: {
                    HStack(spacing: 3) {
                        Text(l10n.tr("Preview & Fine-Tune", "预览与微调"))
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }

            // Grouped Mode Picker + Big Launch Actions
            HStack(spacing: 10) {
                Picker(l10n.tr("Scaling Mode", "缩放模式"), selection: modeBinding) {
                    ForEach(ScenarioTag.allCases) { tag in
                        let group = coordinator.orderedBuiltInModes(for: tag)
                        if !group.isEmpty {
                            Section(l10n.scenarioTag(tag)) {
                                ForEach(group) { mode in
                                    Text(l10n.builtInModeName(mode)).tag(mode.id)
                                }
                            }
                        }
                    }
                    let customModes = coordinator.config.scalingModes.filter { !$0.isBuiltIn }
                    if !customModes.isEmpty {
                        Section(l10n.tr("Custom Modes", "自定义模式")) {
                            ForEach(customModes) { mode in
                                Text(l10n.builtInModeName(mode)).tag(mode.id)
                            }
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 230, maxWidth: 280)

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
                    Label(l10n.tr("Fullscreen Scale", "全屏放大"), systemImage: "arrow.up.left.and.arrow.down.right")
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
                    Label(l10n.tr("Windowed Scale", "窗口放大"), systemImage: "macwindow")
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.permissions.screenRecordingGranted || defaultProfile.threeDGameMode)

                Button {
                    coordinator.startCountdownScale(mode: .fullscreen, specificWindow: nil)
                } label: {
                    Label(
                        l10n.tr(
                            "Scale Current in \(coordinator.config.countdownSeconds)s",
                            "\(coordinator.config.countdownSeconds) 秒后放大当前窗口"
                        ),
                        systemImage: "timer"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.permissions.screenRecordingGranted)
                .help(l10n.tr(
                    "Click this, then immediately switch to your game or video window — scaling starts when the timer finishes.",
                    "点击后立刻切换到你的游戏或视频窗口，倒计时结束自动将其放大。"
                ))
            }

            // Plain-language explanation of the active preset
            let modeDesc = l10n.builtInModeDescription(activeMode)
            if !modeDesc.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(modeDesc)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func selectRecommendedMode(for scenario: ScenarioTag) {
        let current = coordinator.config.resolvedScalingMode(for: coordinator.config.defaultProfile)
        if current.isBuiltIn && current.scenario == scenario {
            return
        }
        let recommendedID: UUID
        switch scenario {
        case .game3D: recommendedID = ScalingMode.metalFXSpatialID
        case .anime: recommendedID = ScalingMode.anime4kModeAID
        case .pixelRetro: recommendedID = ScalingMode.integerScaleID
        case .generalVideo: recommendedID = ScalingMode.lanczos6ID
        }
        let targetID = coordinator.config.scalingMode(for: recommendedID)?.id
            ?? coordinator.config.scalingModes.first(where: { $0.scenario == scenario })?.id
            ?? ScalingMode.metalFXSpatialID
        coordinator.updateDefaultProfile { $0.scalingModeID = targetID }
        coordinator.selectedScalingModeID = targetID
    }

    private func selectedTargetWindow() -> WindowDescriptor? {
        if let selectedWindowID {
            return coordinator.windows.first(where: { $0.windowID == selectedWindowID })
        }
        return nil
    }

    // MARK: - Window Picker Grid

    private func windowPickerSection(l10n: L10n) -> some View {
        let columns = [GridItem(.adaptive(minimum: 255, maximum: 345), spacing: 12)]

        return SectionCard(
            title: l10n.tr("Open Windows", "当前可放大的窗口"),
            subtitle: l10n.tr(
                "\(filteredWindows.count) window(s) across \(coordinator.displays.count) display(s) — click a card's Scale button to jump straight in.",
                "在 \(coordinator.displays.count) 台显示器上发现 \(filteredWindows.count) 个窗口 — 点卡片上的「放大」即可直接切过去放大。"
            ),
            symbol: "macwindow.on.rectangle"
        ) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(l10n.tr("Search by app name or window title…", "输入应用名或窗口标题搜索…"), text: $searchQuery)
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
                    Text(l10n.tr("No Matching Windows", "没有找到可放大的窗口"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(l10n.tr(
                        "Open your game or video window and click Refresh, or use the countdown button above.",
                        "请先打开游戏或视频窗口后点「刷新列表」，或使用上方倒计时按钮。"
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
            // Thumbnail Preview with Monitor Badge
            ZStack {
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

                VStack {
                    HStack {
                        if let display {
                            HStack(spacing: 4) {
                                Image(systemName: display.isPrimary ? "laptopcomputer" : "display")
                                    .font(.system(size: 9, weight: .bold))
                                Text(displayBadgeText(display, l10n: l10n))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.68), in: Capsule())
                        }
                        Spacer(minLength: 4)
                        if isActiveTarget {
                            StatusBadge(l10n.tr("ACTIVE", "放大中"), color: .green)
                        } else if isWineOrFullscreen {
                            StatusBadge(l10n.tr("Fullscreen / Wine", "全屏 / Wine"), color: .purple)
                        }
                    }
                    Spacer()
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
                    Text(verbatim: "\(window.estimatedPixelSize.width)×\(window.estimatedPixelSize.height)")
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
                .help(l10n.tr("Windowed Scale", "窗口放大"))

                Button {
                    Task {
                        do {
                            try await coordinator.startScaling(window: window, presentationOverride: .fullscreen)
                        } catch {
                            coordinator.lastErrorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label(l10n.tr("Scale", "放大"), systemImage: "play.fill")
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

    private func displayBadgeText(_ display: DisplayDescriptor, l10n: L10n) -> String {
        if display.isPrimary && display.name.localizedCaseInsensitiveContains("built-in") {
            return l10n.tr("Built-in Display", "内置显示器")
        }
        return display.name
    }
}
