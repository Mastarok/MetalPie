import AppKit
import MetalPieCapture
import MetalPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Unified, beginner-friendly Settings workspace (`设置` / `Settings`):
///
/// Tier 1 (Visible by Default — Everyday Controls):
/// 1. 常用快捷键 (Global Shortcuts + System-Reserved Force Exit `⌃⌥⌘⎋`)
/// 2. 鼠标与光标 (Honest Accessibility status, cursor alignment, confinement, speed, idle hide, size)
/// 3. 流畅补帧 (One-click 2×/3×/4× Frame Generation with clear guidance)
/// 4. 常规、语言与截图 (Instant Language Switcher, Countdown, Menu Bar, Screenshot folder & template)
///
/// Tier 2 (Collapsed by Default — `高级设置` DisclosureGroup):
/// - Display Color & HDR, Low-Latency Direct Present, ProMotion VRR Direct-Scanout,
///   Idle Power-Saving, Wine/Emulator 1× Low-Res Auto Detection, Capture FPS Cap
/// - Frame Gen Engine & Anti-Ghosting Sensitivity
/// - Auto-Scale Excluded Apps & Config Backup/Reset
struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var isAdvancedExpanded: Bool = false
    @State private var newExcludedBundleID: String = ""
    @State private var showResetConfirmation: Bool = false

    private var activeEditedProfile: Profile {
        coordinator.config.profiles.first(where: { $0.id == coordinator.selectedProfileID })
            ?? coordinator.config.defaultProfile
    }

    var body: some View {
        let l10n = coordinator.l10n
        let targetID = activeEditedProfile.id

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Page Header
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.tr("Settings", "设置"))
                            .font(.system(size: 22, weight: .bold))
                        Text(l10n.tr(
                            "Everyday shortcuts, cursor alignment, frame generation, and language — advanced tuning is neatly tucked below.",
                            "常用快捷键、鼠标对齐、流畅补帧与界面语言都在这里，进阶性能选项收纳在底部「高级设置」中。"
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if coordinator.config.profiles.count > 1 {
                        HStack(spacing: 6) {
                            Text(l10n.tr("Applies to:", "当前编辑:"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $coordinator.selectedProfileID) {
                                ForEach(coordinator.config.profiles) { p in
                                    Text(p.isDefault ? l10n.tr("Default", "全局默认") : p.name).tag(p.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 165)
                        }
                    }
                }

                // Tier 1: Everyday Controls
                hotkeysCard(l10n: l10n)
                cursorAndMouseCard(profileID: targetID, l10n: l10n)
                frameGenerationCard(profileID: targetID, l10n: l10n)
                generalLanguageAndScreenshotsCard(l10n: l10n)

                // Tier 2: Collapsible Advanced Settings
                advancedSettingsSection(profileID: targetID, l10n: l10n)
            }
            .padding(20)
        }
        .alert(
            l10n.tr("Reset All Settings to Defaults?", "确认恢复所有默认设置？"),
            isPresented: $showResetConfirmation
        ) {
            Button(l10n.tr("Cancel", "取消"), role: .cancel) {}
            Button(l10n.tr("Reset", "确认恢复"), role: .destructive) {
                coordinator.resetConfigToDefaults()
            }
        } message: {
            Text(l10n.tr(
                "Custom profiles, shortcuts, and custom scaling modes will be restored to factory defaults.",
                "所有自定义配置文件、快捷键与自定义缩放模式都会恢复为出厂默认值。"
            ))
        }
    }

    // MARK: - 1. Everyday Shortcuts

    private func hotkeysCard(l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Shortcuts", "常用快捷键"),
            subtitle: l10n.tr(
                "Works globally inside games and fullscreen apps.",
                "在任意游戏和全屏应用内按下即可直接触发。"
            ),
            symbol: "keyboard.fill",
            accent: .indigo
        ) {
            if let warning = coordinator.hotkeyWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.system(size: 11.5))
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(spacing: 10) {
                hotkeyRow(
                    action: .toggleFullscreen,
                    binding: coordinator.config.hotkeys.toggleFullscreen,
                    l10n: l10n
                ) { recorded in
                    coordinator.config.hotkeys.toggleFullscreen = recorded
                    coordinator.persistConfig(reconfigureHotkeys: true, reconfigureSession: false)
                } onClear: {
                    coordinator.config.hotkeys.toggleFullscreen.isEnabled = false
                    coordinator.persistConfig(reconfigureHotkeys: true, reconfigureSession: false)
                }

                hotkeyRow(
                    action: .toggleWindowed,
                    binding: coordinator.config.hotkeys.toggleWindowed,
                    l10n: l10n
                ) { recorded in
                    coordinator.config.hotkeys.toggleWindowed = recorded
                    coordinator.persistConfig(reconfigureHotkeys: true, reconfigureSession: false)
                } onClear: {
                    coordinator.config.hotkeys.toggleWindowed.isEnabled = false
                    coordinator.persistConfig(reconfigureHotkeys: true, reconfigureSession: false)
                }

                hotkeyRow(
                    action: .toggleToolbar,
                    binding: coordinator.config.hotkeys.toggleToolbar,
                    l10n: l10n
                ) { recorded in
                    coordinator.config.hotkeys.toggleToolbar = recorded
                    coordinator.persistConfig(reconfigureHotkeys: true, reconfigureSession: false)
                } onClear: {
                    coordinator.config.hotkeys.toggleToolbar.isEnabled = false
                    coordinator.persistConfig(reconfigureHotkeys: true, reconfigureSession: false)
                }

                hotkeyRow(
                    action: .captureScreenshot,
                    binding: coordinator.config.hotkeys.captureScreenshot,
                    l10n: l10n
                ) { recorded in
                    coordinator.config.hotkeys.captureScreenshot = recorded
                    coordinator.persistConfig(reconfigureHotkeys: true, reconfigureSession: false)
                } onClear: {
                    coordinator.config.hotkeys.captureScreenshot.isEnabled = false
                    coordinator.persistConfig(reconfigureHotkeys: true, reconfigureSession: false)
                }

                Divider()

                // System-reserved Force Exit chord
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.hotkeyAction(.panicStop))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(l10n.tr(
                            "Always active — immediately exits scaling and restores your mouse cursor.",
                            "任何时候按下都会立刻退出放大画面并恢复系统鼠标指针。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(HotkeyBinding.panicStop.displayString, color: .red, symbol: "shield.lefthalf.filled")
                }

                HStack {
                    Spacer()
                    Button(l10n.tr("Reset Default Shortcuts", "恢复默认快捷键")) {
                        coordinator.config.hotkeys = HotkeyConfig()
                        coordinator.persistConfig(reconfigureHotkeys: true, reconfigureSession: false)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func hotkeyRow(
        action: HotkeyAction,
        binding: HotkeyBinding,
        l10n: L10n,
        onRecord: @escaping (HotkeyBinding) -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(l10n.hotkeyAction(action))
                .font(.system(size: 12.5, weight: .medium))
            Spacer()
            HotkeyRecorderField(
                binding: binding,
                l10n: l10n,
                onRecord: onRecord,
                onClear: onClear
            )
        }
    }

    // MARK: - 2. Mouse & Cursor

    private func cursorAndMouseCard(profileID: UUID, l10n: L10n) -> some View {
        let cur = activeEditedProfile.cursor
        let axGranted = coordinator.permissions.accessibilityGranted

        let idleEnabled = Binding<Bool>(
            get: { cur.hideOnIdleSeconds != nil },
            set: { on in
                coordinator.updateProfile(id: profileID) {
                    $0.cursor.hideOnIdleSeconds = on ? 3.0 : nil
                }
            }
        )
        let idleSeconds = Binding<Double>(
            get: { cur.hideOnIdleSeconds ?? 3.0 },
            set: { val in
                coordinator.updateProfile(id: profileID) {
                    $0.cursor.hideOnIdleSeconds = val
                }
            }
        )

        return SectionCard(
            title: l10n.tr("Mouse & Cursor Alignment", "鼠标与光标"),
            subtitle: l10n.tr(
                "Accurate click alignment & window confinement so scaled buttons work accurately without accidentally clicking the desktop.",
                "鼠标精准对齐与范围限制（放大后点按钮指哪打哪，防止移出画面误点桌面退出）。"
            ),
            symbol: "cursorarrow.and.square.on.square.dashed",
            accent: .green
        ) {
            // Honest Accessibility guidance banner inside Mouse & Cursor settings
            if !axGranted {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr(
                            "Accessibility Permission Needed for Scaled Click Alignment",
                            "缩放后鼠标精准点击必需（仅 1:1 缩放可不开）"
                        ))
                        .font(.system(size: 12, weight: .semibold))
                        Text(l10n.tr(
                            "macOS requires Accessibility access so MetalPie can align clicks to enlarged buttons and prevent accidental exit.",
                            "未开启辅助功能时，放大画面后点击按钮会错位，点到窗口外会直接退回桌面。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(l10n.tr("Enable", "一键开启")) {
                        coordinator.requestAccessibilityPermission()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(10)
                .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: binding(profileID, \.cursor.renderScaledCursor)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("Show Scaled Cursor (Prevents Double Cursor)", "显示放大光标（避免出现双光标）"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(l10n.tr(
                            "Hides the original cursor cleanly and draws a sharp synced pointer at screen refresh rate.",
                            "放大时自动隐藏系统原指针，并在正确位置实时绘制同步光标。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: binding(profileID, \.cursor.confineCursor)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("Keep Mouse Inside Scaled Window", "锁定鼠标在画面内（防误点桌面退出）"))
                            .font(.system(size: 12.5, weight: .medium))
                        Text(l10n.tr(
                            "Prevents the pointer from slipping outside the target window while playing or clicking edges.",
                            "防止鼠标移出游戏或窗口边缘时误点到桌面导致缩放退出。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: binding(profileID, \.cursor.adjustCursorSpeed)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("Auto-Match Mouse Speed to Scale", "自动适配鼠标移速"))
                            .font(.system(size: 12.5, weight: .medium))
                        Text(l10n.tr(
                            "Keeps pointer movement feeling natural after upscaling without changing macOS mouse preferences.",
                            "让放大后的鼠标移动速度与平时桌面手感一致，不会改动系统设置。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text(l10n.tr("Cursor Size", "光标大小"))
                            .font(.system(size: 12.5, weight: .medium))
                            .frame(width: 155, alignment: .leading)
                        Picker("", selection: binding(profileID, \.cursor.cursorScaleMode)) {
                            ForEach(CursorScaleMode.allCases) { mode in
                                Text(l10n.cursorScaleMode(mode)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }

                    if cur.cursorScaleMode == .multiplier {
                        GridRow {
                            Text(l10n.tr("Size Multiplier", "放大倍数"))
                                .font(.system(size: 12.5, weight: .medium))
                            HStack(spacing: 10) {
                                Slider(
                                    value: binding(profileID, \.cursor.cursorScaleMultiplier),
                                    in: 0.5...2.0,
                                    step: 0.05
                                )
                                .frame(maxWidth: 200)
                                Text(String(format: "%.2f×", cur.cursorScaleMultiplier))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .frame(width: 48, alignment: .trailing)
                            }
                        }
                    }

                    GridRow {
                        Text(l10n.tr("Cursor Sharpness", "光标清晰度"))
                            .font(.system(size: 12.5, weight: .medium))
                        Picker("", selection: binding(profileID, \.cursor.interpolation)) {
                            ForEach(CursorInterpolation.allCases) { interp in
                                Text(l10n.cursorInterpolation(interp)).tag(interp)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }

                    GridRow {
                        Text(l10n.tr("Auto-Hide When Idle", "空闲自动隐藏光标"))
                            .font(.system(size: 12.5, weight: .medium))
                        HStack(spacing: 10) {
                            Toggle("", isOn: idleEnabled)
                                .labelsHidden()
                            if cur.hideOnIdleSeconds != nil {
                                Slider(value: idleSeconds, in: 0.5...10.0, step: 0.5)
                                    .frame(maxWidth: 160)
                                Text(l10n.tr(
                                    String(format: "%.1fs", idleSeconds.wrappedValue),
                                    String(format: "%.1f 秒", idleSeconds.wrappedValue)
                                ))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                            } else {
                                Text(l10n.tr("Always Visible", "始终显示"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 24) {
                    Toggle(
                        l10n.tr("Hide Cursor in Screenshots", "截图时自动隐藏光标"),
                        isOn: binding(profileID, \.cursor.hideInScreenshots)
                    )
                    Toggle(
                        l10n.tr("Auto-Detect 3D/FPS Game Mouse Lock", "自动识别 3D/FPS 游戏锁鼠"),
                        isOn: binding(profileID, \.cursor.respectGameMouseGrab)
                    )
                }
                .font(.system(size: 12))
            }
        }
    }

    // MARK: - 3. Smooth Frame Generation

    private func frameGenerationCard(profileID: UUID, l10n: L10n) -> some View {
        let fg = activeEditedProfile.frameGen
        let aneReady = coordinator.capabilities.supportsVTFrameInterpolation

        return SectionCard(
            title: l10n.tr("Smooth Frame Generation (2× / 3× / 4×)", "流畅补帧（2× / 3× / 4×）"),
            subtitle: l10n.tr(
                "Great for 30/60 FPS games and anime/video — not recommended for competitive FPS where lowest input lag matters most.",
                "适合 30/60 帧游戏和视频，让动态画面更丝滑（不建议竞技类 FPS 游戏开启）。"
            ),
            symbol: "waveform.path.ecg.rectangle.fill",
            accent: .cyan
        ) {
            HStack {
                Toggle(
                    l10n.tr("Enable Smooth Frame Generation", "开启流畅补帧"),
                    isOn: binding(profileID, \.frameGen.enabled)
                )
                .font(.system(size: 13, weight: .semibold))

                Spacer()

                StatusBadge(
                    aneReady
                        ? l10n.tr("Apple Silicon Hardware Ready", "支持 Apple 芯片硬件补帧")
                        : l10n.tr("Metal Optical Flow Ready", "Metal 光流补帧就绪"),
                    color: aneReady ? .green : .blue,
                    symbol: aneReady ? "cpu.fill" : "sparkles"
                )
            }

            if fg.enabled {
                Divider()
                HStack(spacing: 14) {
                    Text(l10n.tr("Frame Multiplier", "帧率倍数"))
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 155, alignment: .leading)
                    Picker("", selection: binding(profileID, \.frameGen.multiplier)) {
                        ForEach(FrameGenMultiplier.allCases) { mult in
                            Text(mult.label).tag(mult)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    Spacer()
                }

                Toggle(
                    l10n.tr("Auto-Disable in 3D Game Mode (Lowest Latency)", "在 3D 游戏模式下自动关闭补帧（优先低延迟）"),
                    isOn: binding(profileID, \.frameGen.disableIn3DGameMode)
                )
                .font(.system(size: 12))
            }
        }
    }

    // MARK: - 4. General, Language & Screenshots

    private func generalLanguageAndScreenshotsCard(l10n: L10n) -> some View {
        let validation = ScreenshotFilenameTemplate.validate(coordinator.config.screenshotFilenameTemplate)
        let exampleName = ScreenshotFilenameTemplate.expand(
            template: coordinator.config.screenshotFilenameTemplate,
            processName: "HollowKnight",
            windowTitle: "City of Tears"
        ) + ".png"

        return SectionCard(
            title: l10n.tr("General, Language & Screenshots", "常规、语言与截图"),
            symbol: "globe",
            accent: .blue
        ) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Interface Language", "界面语言"))
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 155, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { coordinator.config.language },
                        set: { lang in
                            coordinator.languageOverride = nil
                            coordinator.config.language = lang
                            coordinator.persistConfig(reconfigureSession: false)
                            coordinator.refreshActiveChromeLanguage()
                        }
                    )) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(l10n.languageName(lang)).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 310)
                }

                GridRow {
                    Text(l10n.tr("Countdown Delay", "倒计时秒数"))
                        .font(.system(size: 12.5, weight: .medium))
                    Stepper(
                        value: Binding(
                            get: { coordinator.config.countdownSeconds },
                            set: { val in
                                coordinator.config.countdownSeconds = min(max(val, 1), 5)
                                coordinator.persistConfig(reconfigureSession: false)
                            }
                        ),
                        in: 1...5
                    ) {
                        Text(l10n.tr("\(coordinator.config.countdownSeconds) second(s)", "\(coordinator.config.countdownSeconds) 秒"))
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { coordinator.config.keepRunningInMenuBar },
                set: { keep in
                    coordinator.config.keepRunningInMenuBar = keep
                    coordinator.persistConfig(reconfigureSession: false)
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.tr("Keep Running in Menu Bar When Closed", "关闭窗口后保持在顶部菜单栏运行"))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(l10n.tr(
                        "Keeps global shortcuts and auto-scaling ready even after closing this window.",
                        "关掉主窗口后仍可通过快捷键或顶部菜单栏随时启动缩放。"
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Screenshot Folder", "截图保存文件夹"))
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 155, alignment: .leading)
                    HStack(spacing: 8) {
                        TextField(
                            "~/Pictures/MetalPie",
                            text: Binding(
                                get: { coordinator.config.screenshotDirectory },
                                set: { val in
                                    coordinator.config.screenshotDirectory = val
                                    coordinator.persistConfig(reconfigureSession: false)
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                        Button(l10n.tr("Choose…", "选择文件夹…")) {
                            chooseScreenshotDirectory()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                GridRow {
                    Text(l10n.tr("Filename Template", "截图文件名模板"))
                        .font(.system(size: 12.5, weight: .medium))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            TextField(
                                AppConfig.defaultScreenshotFilenameTemplate,
                                text: Binding(
                                    get: { coordinator.config.screenshotFilenameTemplate },
                                    set: { val in
                                        coordinator.config.screenshotFilenameTemplate = val
                                        coordinator.persistConfig(reconfigureSession: false)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                            switch validation {
                            case .valid:
                                StatusBadge(l10n.tr("Valid", "格式正确"), color: .green)
                            case .invalid(let reason):
                                StatusBadge(localizedTemplateValidationReason(reason, l10n: l10n), color: .red)
                            }
                        }

                        Text("\(l10n.tr("Example:", "示例：")) \(exampleName)   •   %PN% \(l10n.tr("App", "应用名")), %WT% \(l10n.tr("Title", "标题")), %Y%%M%%D%")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - 5. Collapsible Advanced Settings (Tier 2)

    private func advancedSettingsSection(profileID: UUID, l10n: L10n) -> some View {
        let cap = activeEditedProfile.capture
        let fpsLimited = Binding<Bool>(
            get: { cap.frameRateLimit != nil },
            set: { enabled in
                coordinator.updateProfile(id: profileID) {
                    $0.capture.frameRateLimit = enabled ? 60 : nil
                }
            }
        )
        let fpsValue = Binding<Int>(
            get: { cap.frameRateLimit ?? 60 },
            set: { val in
                coordinator.updateProfile(id: profileID) {
                    $0.capture.frameRateLimit = min(max(val, 15), 240)
                }
            }
        )

        return SectionCard {
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    // Display, Color & Performance
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n.tr("Display Color, HDR & Performance", "画面色彩、HDR 与性能微调"))
                            .font(.system(size: 12.5, weight: .bold))
                            .padding(.top, 6)

                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow {
                                Text(l10n.tr("Color Format", "色彩深度"))
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 175, alignment: .leading)
                                Picker("", selection: binding(profileID, \.capture.preferredPixelFormat)) {
                                    ForEach(CapturePixelFormat.allCases) { fmt in
                                        Text(l10n.pixelFormat(fmt)).tag(fmt)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            }

                            GridRow {
                                Text(l10n.tr("Dynamic Range (SDR / HDR)", "动态范围 (SDR / HDR)"))
                                    .font(.system(size: 12, weight: .medium))
                                Picker("", selection: binding(profileID, \.capture.dynamicRange)) {
                                    ForEach(DynamicRangeMode.allCases) { dr in
                                        Text(l10n.dynamicRange(dr)).tag(dr)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            }

                            GridRow {
                                Text(l10n.tr("Static Screen Power Saving", "静止画面自动省电"))
                                    .font(.system(size: 12, weight: .medium))
                                VStack(alignment: .leading, spacing: 2) {
                                    Picker("", selection: binding(profileID, \.capture.duplicateFrameMode)) {
                                        ForEach(DuplicateFrameMode.allCases) { mode in
                                            Text(l10n.duplicateFrameMode(mode)).tag(mode)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 300)
                                    Text(l10n.tr(
                                        "Skips redundant GPU work when window contents stop changing to reduce heat and battery drain.",
                                        "窗口画面无变化时跳过重复渲染，降低发热与耗电。"
                                    ))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                }
                            }

                            GridRow {
                                Text(l10n.tr("Wine / Emulator Low-Res Auto Detect", "自动识别低分辨率窗口（Wine / 模拟器优化）"))
                                    .font(.system(size: 12, weight: .medium))
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Picker("", selection: $coordinator.nonRetinaMode) {
                                            Text(l10n.tr("Auto Detect (Recommended)", "自动识别（推荐）")).tag(NonRetinaDetectionMode.auto)
                                            Text(l10n.tr("Always Use Original 1× Pixels", "始终还原原始 1× 画面（更清晰省电）")).tag(NonRetinaDetectionMode.force1x)
                                            Text(l10n.tr("Keep macOS 2× Retina", "保持系统 2× Retina 画面")).tag(NonRetinaDetectionMode.force2x)
                                        }
                                        .labelsHidden()
                                        .frame(maxWidth: 280)

                                        if coordinator.detectedContentResolution != .nativeFull {
                                            StatusBadge(l10n.tr("1× Active", "已启用 1× 还原"), color: .green)
                                        }
                                    }
                                    Text(l10n.tr(
                                        "Skips macOS blurry 2× stretch and upscales straight from original pixels — sharper and faster.",
                                        "跳过系统模糊放大，直接从原始画面超分，更清晰且省电。"
                                    ))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                }
                            }

                            GridRow {
                                Text(l10n.tr("Capture Frame Rate Limit", "画面采集帧率上限"))
                                    .font(.system(size: 12, weight: .medium))
                                HStack(spacing: 10) {
                                    Toggle(l10n.tr("Cap FPS", "限制帧率"), isOn: fpsLimited)
                                    if cap.frameRateLimit != nil {
                                        Stepper(value: fpsValue, in: 15...240, step: 5) {
                                            Text("\(fpsValue.wrappedValue) FPS")
                                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                .monospacedDigit()
                                        }
                                    } else {
                                        Text(l10n.tr("Uncapped (Matches Display Refresh)", "不限（跟随显示器刷新率）"))
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        Toggle(isOn: binding(profileID, \.capture.lowLatencyPresent)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l10n.tr("Ultra-Low-Latency Direct Present (Recommended when Frame Gen is OFF)", "超低延迟直出（不开补帧时推荐）"))
                                    .font(.system(size: 12, weight: .medium))
                                Text(l10n.tr(
                                    "Skips extra display compositor buffering for snappier mouse and keyboard response.",
                                    "跳过系统合成缓冲，操作更跟手。"
                                ))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            }
                        }

                        Toggle(isOn: $coordinator.vrrDirectScanoutEnabled) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(l10n.tr("ProMotion VRR Direct-Scanout Mode", "高刷自适应刷新率（ProMotion VRR）直出模式"))
                                        .font(.system(size: 12, weight: .medium))
                                    StatusBadge("ProMotion VRR", color: .purple)
                                }
                                Text(l10n.tr(
                                    "Disables floating helper windows and draws cursor & FPS directly inside the scaled frame so ProMotion locks cleanly.",
                                    "关闭独立悬浮层，把光标与帧率直接画进画面，让高刷屏更跟手。"
                                ))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    // Frame Gen Advanced
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n.tr("Frame Generation Engine", "补帧引擎进阶"))
                            .font(.system(size: 12.5, weight: .bold))

                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow {
                                Text(l10n.tr("Interpolation Engine", "补帧引擎选择"))
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 175, alignment: .leading)
                                Picker("", selection: binding(profileID, \.frameGen.backend)) {
                                    ForEach(FrameGenBackend.allCases) { backend in
                                        Text(l10n.frameGenBackend(backend)).tag(backend)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            }

                            GridRow {
                                Text(l10n.tr("Anti-Ghosting Sensitivity", "防鬼影灵敏度"))
                                    .font(.system(size: 12, weight: .medium))
                                Picker("", selection: binding(profileID, \.frameGen.artifactGuardSensitivity)) {
                                    ForEach(ArtifactGuardSensitivity.allCases) { sens in
                                        Text(l10n.artifactGuard(sens)).tag(sens)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 260)
                            }
                        }
                    }

                    Divider()

                    // Auto-Scale Ignore List
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n.tr("Auto-Scale Ignore List", "自动缩放忽略名单"))
                            .font(.system(size: 12.5, weight: .bold))
                        Text(l10n.tr(
                            "System apps and listed Bundle IDs will never be triggered by Auto-Scale.",
                            "下列系统进程与应用永远不会被「自动缩放」误触发。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField("com.vendor.helper", text: $newExcludedBundleID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button(l10n.tr("Add", "添加")) {
                                let trimmed = newExcludedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty,
                                      !coordinator.config.autoScaleExcludedBundleIDs.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
                                else { return }
                                coordinator.config.autoScaleExcludedBundleIDs.append(trimmed)
                                newExcludedBundleID = ""
                                coordinator.persistConfig(reconfigureSession: false)
                            }
                            .buttonStyle(.bordered)
                            .disabled(newExcludedBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(coordinator.config.autoScaleExcludedBundleIDs, id: \.self) { bundleID in
                                    let isProtected = bundleID.caseInsensitiveCompare("com.metalpie.app") == .orderedSame
                                    HStack {
                                        Text(bundleID)
                                            .font(.system(size: 11.5, design: .monospaced))
                                        Spacer()
                                        if isProtected {
                                            StatusBadge(l10n.tr("Protected", "内置保护"), color: .secondary)
                                        } else {
                                            Button {
                                                coordinator.config.autoScaleExcludedBundleIDs.removeAll { $0 == bundleID }
                                                coordinator.persistConfig(reconfigureSession: false)
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }

                    Divider()

                    // Config Storage & Reset
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l10n.tr("Configuration File", "配置文件备份与恢复"))
                                .font(.system(size: 12, weight: .semibold))
                            Text(coordinator.configStore.fileURL.path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(l10n.tr("Reveal in Finder", "在访达中打开")) {
                            NSWorkspace.shared.activateFileViewerSelecting([coordinator.configStore.fileURL])
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)

                        Button(l10n.tr("Export…", "导出备份…")) {
                            exportFullConfig(l10n: l10n)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)

                        Button(l10n.tr("Reset Defaults…", "恢复默认设置…"), role: .destructive) {
                            showResetConfirmation = true
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.below.square.filled.and.square")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("Advanced Settings", "高级设置"))
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(l10n.tr(
                            "HDR/10-bit color, ProMotion VRR, Wine 1× detection, power-saving, ignore list & reset",
                            "色彩与 HDR、高刷 VRR 直出、Wine 低清优化、静止省电、忽略名单与恢复默认"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Helpers

    private func binding<Value>(_ profileID: UUID, _ keyPath: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        Binding(
            get: {
                (coordinator.config.profiles.first(where: { $0.id == profileID }) ?? coordinator.config.defaultProfile)[keyPath: keyPath]
            },
            set: { newValue in
                coordinator.updateProfile(id: profileID) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func localizedTemplateValidationReason(_ reason: String, l10n: L10n) -> String {
        if reason.contains("empty") {
            return l10n.tr("Template cannot be empty", "文件名模板不能为空")
        }
        if reason.contains("Unclosed") {
            return l10n.tr("Unclosed '%' token", "存在未闭合的 '%' 变量")
        }
        if reason.hasPrefix("Unknown token") {
            let suffix = reason.replacingOccurrences(of: "Unknown token ", with: "")
            return l10n.tr("Unknown token \(suffix)", "未知变量 \(suffix)")
        }
        return reason
    }

    private func chooseScreenshotDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.config.screenshotDirectory = url.path
            coordinator.persistConfig(reconfigureSession: false)
        }
    }

    private func exportFullConfig(l10n: L10n) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MetalPie-Config.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(coordinator.config)
                try data.write(to: url, options: [.atomic])
                coordinator.showToast(
                    icon: "checkmark.circle.fill",
                    title: l10n.tr("Configuration Exported", "配置已导出"),
                    subtitle: url.lastPathComponent,
                    style: .success
                )
            } catch {
                coordinator.lastErrorMessage = error.localizedDescription
            }
        }
    }
}
