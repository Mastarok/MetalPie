import AppKit
import MetalPieCapture
import MetalPieCore
import SwiftUI

/// Primary Home workspace (`主页` / `Home`):
/// - Compact 1-line permissions status strip (tooltips for details)
/// - Active session status & controls (with 1-line Accessibility warning when needed)
/// - Scenario pills, preset selector, launch actions, and shortcut hints
/// - Live searchable window picker grid
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
            VStack(alignment: .leading, spacing: 14) {
                // Header
                Text(l10n.tr("Scale", "缩放"))
                    .font(.system(size: 20, weight: .bold))

                // 1. Compact 1-line Permissions Bar
                permissionsBar(l10n: l10n)

                // 2. Active Session Card or Countdown Banner
                if coordinator.isScalingSessionOpen {
                    activeSessionCard(l10n: l10n)
                } else if let remaining = coordinator.countdownRemaining {
                    countdownBanner(remaining: remaining, l10n: l10n)
                }

                // 3. Launch Bar
                quickLaunchBar(l10n: l10n)

                // 4. Error Notice
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

                // 5. Window Picker Grid
                windowPickerSection(l10n: l10n)
            }
            .padding(20)
        }
    }

    // MARK: - Compact Permissions Bar

    private func permissionsBar(l10n: L10n) -> some View {
        let srGranted = coordinator.permissions.screenRecordingGranted
        let axGranted = coordinator.permissions.accessibilityGranted

        return HStack(spacing: 12) {
            // Screen Recording
            HStack(spacing: 6) {
                Text(l10n.tr("Screen Recording", "屏幕录制"))
                    .font(.system(size: 12, weight: .medium))
                StatusBadge(
                    srGranted ? l10n.tr("Granted", "已授权") : l10n.tr("Not Granted", "未授权"),
                    color: srGranted ? .green : .orange
                )
                if !srGranted {
                    Button(l10n.tr("Grant", "授权")) {
                        coordinator.requestScreenRecordingPermission()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)

                    Button {
                        coordinator.openScreenRecordingSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .help(l10n.tr("Open System Settings", "打开系统设置"))
                }
            }
            .help(l10n.tr("Required to capture window frames.", "用于捕获窗口画面"))

            Divider()
                .frame(height: 16)

            // Accessibility
            HStack(spacing: 6) {
                Text(l10n.tr("Accessibility", "辅助功能"))
                    .font(.system(size: 12, weight: .medium))
                StatusBadge(
                    axGranted ? l10n.tr("Granted", "已授权") : l10n.tr("Not Granted", "未授权"),
                    color: axGranted ? .green : .orange
                )
                if !axGranted {
                    Button(l10n.tr("Grant", "授权")) {
                        coordinator.requestAccessibilityPermission()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button {
                        coordinator.openAccessibilitySettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .help(l10n.tr("Open System Settings", "打开系统设置"))
                }
            }
            .help(l10n.tr(
                "Used for cursor alignment and click positioning when scaling non-1:1 windows.",
                "缩放非 1:1 窗口时用于光标对齐与点击定位"
            ))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    // MARK: - Active Session Card

    private func activeSessionCard(l10n: L10n) -> some View {
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
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(coordinator.activeWindow?.displayName ?? t.targetWindowName)
                        .font(.system(size: 14.5, weight: .bold))
                        .lineLimit(1)
                    Text("\(activeModeLabel) · \(l10n.sessionState(t.state))")
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
                        StatusBadge("\(t.frameGenMultiplier)× FG", color: .cyan)
                    }
                    if t.hdrActive {
                        StatusBadge("HDR", color: .orange)
                    }
                    if coordinator.vrrDirectScanoutEnabled && isFS {
                        StatusBadge("VRR", color: .purple)
                    }
                    StatusBadge(
                        isFS ? l10n.tr("Fullscreen", "全屏") : l10n.tr("Windowed", "窗口"),
                        color: .blue
                    )
                }
            }

            // Concise 1-line Accessibility warning when scaling non-1:1 without Accessibility
            if coordinator.needsAccessibilityForScaledClicks {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.orange)
                    Text(l10n.tr(
                        "Accessibility disabled — scaled clicks will be offset.",
                        "未开启辅助功能，缩放后光标点击将偏移"
                    ))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    Spacer(minLength: 6)
                    Button(l10n.tr("Grant", "去授权")) {
                        coordinator.requestAccessibilityPermission()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
                }
            }

            HStack(spacing: 10) {
                heroMetric(
                    label: l10n.tr("Resolution", "分辨率"),
                    value: "\(t.inputSize.width)×\(t.inputSize.height) → \(t.outputSize.width)×\(t.outputSize.height)"
                )
                heroMetric(label: l10n.tr("Source", "源帧率"), value: String(format: "%.1f FPS", t.sourceFPS))
                heroMetric(label: l10n.tr("Output", "输出帧率"), value: String(format: "%.1f FPS", t.presentedFPS > 0.5 ? t.presentedFPS : t.outputFPS))
                heroMetric(label: "GPU", value: String(format: "%.2f ms", max(t.frameTimeMs, t.totalGPUMilliseconds)))
            }

            HStack(spacing: 8) {
                Button {
                    Task { await coordinator.togglePresentationMode() }
                } label: {
                    Label(
                        isFS ? l10n.tr("Windowed", "窗口") : l10n.tr("Fullscreen", "全屏"),
                        systemImage: isFS ? "macwindow" : "arrow.up.left.and.arrow.down.right"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.activeProfile?.threeDGameMode ?? false)

                Button {
                    Task { await coordinator.captureCursorFreeScreenshot() }
                } label: {
                    Label(l10n.tr("Screenshot", "截图"), systemImage: "camera")
                }
                .buttonStyle(.bordered)

                Button {
                    coordinator.toggleProfilerHUD()
                } label: {
                    Label(l10n.tr("Profiler", "监视器"), systemImage: "chart.bar.xaxis")
                }
                .buttonStyle(.bordered)
                .tint(coordinator.isProfilerHUDActive ? .accentColor : nil)

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
                    Label(l10n.tr("Stop", "停止"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), Color.cyan.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 1)
        }
    }

    private func heroMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func countdownBanner(remaining: Int, l10n: L10n) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.cyan)
            Text(l10n.tr("Scaling in \(remaining)s…", "\(remaining) 秒后缩放…"))
                .font(.system(size: 13.5, weight: .semibold))
            Spacer()
            Button(l10n.tr("Cancel", "取消")) {
                coordinator.cancelCountdown()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1)
        }
    }

    // MARK: - Launch Bar

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
        let fsKey = coordinator.config.hotkeys.toggleFullscreen.displayString
        let winKey = coordinator.config.hotkeys.toggleWindowed.displayString

        return SectionCard {
            // Row 1: Scenario Pills + Subtle Monospace Shortcuts
            HStack(spacing: 6) {
                ForEach(ScenarioTag.allCases) { tag in
                    let isSelected = activeMode.scenario == tag && activeMode.isBuiltIn
                    Button {
                        selectRecommendedMode(for: tag)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tag.symbolName)
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(l10n.scenarioTag(tag))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if coordinator.config.hotkeys.toggleFullscreen.isEnabled {
                        Text(fsKey)
                            .help(l10n.tr("Fullscreen Scale Shortcut", "全屏缩放快捷键"))
                    }
                    if coordinator.config.hotkeys.toggleWindowed.isEnabled {
                        Text(winKey)
                            .help(l10n.tr("Windowed Scale Shortcut", "窗口缩放快捷键"))
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            // Row 2: Preset Picker + Launch Actions
            HStack(spacing: 8) {
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
                        Section(l10n.tr("Custom", "自定义")) {
                            ForEach(customModes) { mode in
                                Text(l10n.builtInModeName(mode)).tag(mode.id)
                            }
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 190, maxWidth: 240)

                Button {
                    coordinator.selectedScalingModeID = activeMode.id
                    coordinator.selectedTab = .effects
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .help(l10n.tr("Edit Mode Parameters", "调整模式参数"))

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
                    Label(l10n.tr("Fullscreen", "全屏缩放"), systemImage: "arrow.up.left.and.arrow.down.right")
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
                    Label(l10n.tr("Windowed", "窗口缩放"), systemImage: "macwindow")
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.permissions.screenRecordingGranted || defaultProfile.threeDGameMode)

                Button {
                    coordinator.startCountdownScale(mode: .fullscreen, specificWindow: nil)
                } label: {
                    Label(
                        l10n.tr("Timer \(coordinator.config.countdownSeconds)s", "倒计时 \(coordinator.config.countdownSeconds)s"),
                        systemImage: "timer"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.permissions.screenRecordingGranted)
                .help(l10n.tr(
                    "Starts scaling the active window after the countdown.",
                    "倒计时结束后自动缩放当前前置窗口"
                ))
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

        return SectionCard {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Text(l10n.tr("Windows", "窗口"))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("(\(filteredWindows.count))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    TextField(l10n.tr("Search…", "搜索…"), text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: 230)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Button {
                    Task { await coordinator.refreshWindows(captureThumbnails: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(coordinator.isRefreshingWindows)
                .help(l10n.tr("Refresh", "刷新"))
            }

            if filteredWindows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(l10n.tr("No Windows", "无可用窗口"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
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
                                    .font(.system(size: 24))
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
                            StatusBadge(l10n.tr("Active", "运行中"), color: .green)
                        } else if isWineOrFullscreen {
                            StatusBadge(l10n.tr("Fullscreen / Wine", "全屏 / Wine"), color: .purple)
                        }
                    }
                    Spacer()
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(window.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(window.title.isEmpty ? l10n.tr("Untitled", "无标题") : window.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(verbatim: "\(window.estimatedPixelSize.width)×\(window.estimatedPixelSize.height)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let display {
                        Text("· \(display.name)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

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
                .help(l10n.tr("Windowed Scale", "窗口缩放"))

                Button {
                    Task {
                        do {
                            try await coordinator.startScaling(window: window, presentationOverride: .fullscreen)
                        } catch {
                            coordinator.lastErrorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label(l10n.tr("Scale", "缩放"), systemImage: "play.fill")
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
            return l10n.tr("Built-in", "内置屏幕")
        }
        return display.name
    }
}
