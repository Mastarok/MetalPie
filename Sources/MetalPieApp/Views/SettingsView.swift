import AppKit
import MetalPieCapture
import MetalPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Clean native macOS Settings workspace (`设置` / `Settings`).
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Text(l10n.tr("Settings", "设置"))
                        .font(.system(size: 20, weight: .bold))
                    Spacer()

                    if coordinator.config.profiles.count > 1 {
                        HStack(spacing: 6) {
                            Text(l10n.tr("Profile", "配置"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $coordinator.selectedProfileID) {
                                ForEach(coordinator.config.profiles) { p in
                                    Text(p.isDefault ? l10n.tr("Default", "默认") : p.name).tag(p.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 160)
                        }
                    }
                }

                hotkeysCard(l10n: l10n)
                cursorCard(profileID: targetID, l10n: l10n)
                frameGenerationCard(profileID: targetID, l10n: l10n)
                generalCard(l10n: l10n)
                advancedSection(profileID: targetID, l10n: l10n)
            }
            .padding(20)
        }
        .alert(
            l10n.tr("Reset Configuration?", "重置配置？"),
            isPresented: $showResetConfirmation
        ) {
            Button(l10n.tr("Cancel", "取消"), role: .cancel) {}
            Button(l10n.tr("Reset", "重置"), role: .destructive) {
                coordinator.resetConfigToDefaults()
            }
        } message: {
            Text(l10n.tr(
                "All profiles, shortcuts, and custom scaling modes will be restored to defaults.",
                "所有配置文件、快捷键与自定义缩放模式将恢复为默认。"
            ))
        }
    }

    // MARK: - Shortcuts

    private func hotkeysCard(l10n: L10n) -> some View {
        SectionCard {
            HStack {
                Text(l10n.tr("Shortcuts", "快捷键"))
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button(l10n.tr("Reset Defaults", "恢复默认")) {
                    coordinator.config.hotkeys = HotkeyConfig()
                    coordinator.persistConfig(reconfigureHotkeys: true, reconfigureSession: false)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

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

            VStack(spacing: 9) {
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

                HStack {
                    Text(l10n.hotkeyAction(.panicStop))
                        .font(.system(size: 12.5))
                    Spacer()
                    Text(HotkeyBinding.panicStop.displayString)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .help(l10n.tr(
                    "Immediately stops scaling and restores the system cursor.",
                    "立即停止缩放并恢复系统光标"
                ))
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
                .font(.system(size: 12.5))
            Spacer()
            HotkeyRecorderField(
                binding: binding,
                l10n: l10n,
                onRecord: onRecord,
                onClear: onClear
            )
        }
    }

    // MARK: - Cursor

    private func cursorCard(profileID: UUID, l10n: L10n) -> some View {
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

        return SectionCard(title: l10n.tr("Cursor", "光标")) {
            if !axGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text(l10n.tr(
                        "Accessibility disabled — scaled clicks will be offset.",
                        "未开启辅助功能，缩放后光标点击将偏移"
                    ))
                    .font(.system(size: 12))
                    Spacer()
                    Button(l10n.tr("Grant", "授权")) {
                        coordinator.requestAccessibilityPermission()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 9) {
                Toggle(
                    l10n.tr("Render Scaled Cursor", "绘制缩放光标"),
                    isOn: binding(profileID, \.cursor.renderScaledCursor)
                )
                .help(l10n.tr("Hides the system pointer and renders a synced cursor on the scaled overlay.", "隐藏系统指针并在缩放层同步绘制光标"))

                Toggle(
                    l10n.tr("Confine Cursor", "限制光标范围"),
                    isOn: binding(profileID, \.cursor.confineCursor)
                )
                .help(l10n.tr("Keeps the pointer within the scaled window bounds.", "将光标限制在缩放窗口范围内"))

                Toggle(
                    l10n.tr("Adjust Cursor Speed", "按比例调整光标速度"),
                    isOn: binding(profileID, \.cursor.adjustCursorSpeed)
                )
                .help(l10n.tr("Matches pointer travel speed to the scaled output dimensions.", "按缩放比例匹配光标移动速度"))

                HStack(spacing: 12) {
                    Toggle(
                        l10n.tr("Hide When Idle", "空闲隐藏"),
                        isOn: idleEnabled
                    )
                    if cur.hideOnIdleSeconds != nil {
                        Slider(value: idleSeconds, in: 0.5...10.0, step: 0.5)
                            .frame(maxWidth: 150)
                        Text(String(format: "%.1fs", idleSeconds.wrappedValue))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                HStack(spacing: 24) {
                    Toggle(
                        l10n.tr("Hide in Screenshots", "截图时隐藏"),
                        isOn: binding(profileID, \.cursor.hideInScreenshots)
                    )
                    Toggle(
                        l10n.tr("Respect Game Mouse Grab", "响应游戏鼠标捕获"),
                        isOn: binding(profileID, \.cursor.respectGameMouseGrab)
                    )
                    .help(l10n.tr("Yields cursor control when 3D games capture relative mouse input.", "3D 游戏捕获相对鼠标输入时自动让出光标控制"))
                }
            }
            .font(.system(size: 12.5))

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text(l10n.tr("Cursor Scale", "光标缩放"))
                        .font(.system(size: 12.5))
                        .frame(width: 120, alignment: .leading)
                    Picker("", selection: binding(profileID, \.cursor.cursorScaleMode)) {
                        ForEach(CursorScaleMode.allCases) { mode in
                            Text(l10n.cursorScaleMode(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

                if cur.cursorScaleMode == .multiplier {
                    GridRow {
                        Text(l10n.tr("Multiplier", "倍率"))
                            .font(.system(size: 12.5))
                        HStack(spacing: 10) {
                            Slider(
                                value: binding(profileID, \.cursor.cursorScaleMultiplier),
                                in: 0.5...2.0,
                                step: 0.05
                            )
                            .frame(maxWidth: 180)
                            Text(String(format: "%.2f×", cur.cursorScaleMultiplier))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }

                GridRow {
                    Text(l10n.tr("Interpolation", "插值"))
                        .font(.system(size: 12.5))
                    Picker("", selection: binding(profileID, \.cursor.interpolation)) {
                        ForEach(CursorInterpolation.allCases) { interp in
                            Text(l10n.cursorInterpolation(interp)).tag(interp)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
            }
        }
    }

    // MARK: - Frame Generation

    private func frameGenerationCard(profileID: UUID, l10n: L10n) -> some View {
        let fg = activeEditedProfile.frameGen
        let aneReady = coordinator.capabilities.supportsVTFrameInterpolation

        return SectionCard(title: l10n.tr("Frame Generation", "帧生成")) {
            HStack {
                Toggle(
                    l10n.tr("Enable Frame Generation", "启用帧生成"),
                    isOn: binding(profileID, \.frameGen.enabled)
                )
                .font(.system(size: 12.5))

                Spacer()

                Text(aneReady ? "VideoToolbox ML" : l10n.tr("Metal Optical Flow", "Metal 光流"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if fg.enabled {
                Divider()

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    GridRow {
                        Text(l10n.tr("Multiplier", "倍率"))
                            .font(.system(size: 12.5))
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: binding(profileID, \.frameGen.multiplier)) {
                            ForEach(FrameGenMultiplier.allCases) { mult in
                                Text(mult.label).tag(mult)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 190)
                    }
                }

                Toggle(
                    l10n.tr("Disable in 3D Mode", "3D 模式自动关闭"),
                    isOn: binding(profileID, \.frameGen.disableIn3DGameMode)
                )
                .font(.system(size: 12.5))
                .help(l10n.tr("Disables frame generation in 3D Game Mode to minimize input latency.", "在 3D 游戏模式下自动关闭以降低输入延迟"))
            }
        }
    }

    // MARK: - General

    private func generalCard(l10n: L10n) -> some View {
        let validation = ScreenshotFilenameTemplate.validate(coordinator.config.screenshotFilenameTemplate)

        return SectionCard(title: l10n.tr("General", "常规")) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Language", "语言"))
                        .font(.system(size: 12.5))
                        .frame(width: 120, alignment: .leading)
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
                    .frame(maxWidth: 280)
                }

                GridRow {
                    Text(l10n.tr("Countdown", "倒计时"))
                        .font(.system(size: 12.5))
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
                        Text("\(coordinator.config.countdownSeconds)s")
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                    }
                }
            }

            Toggle(
                l10n.tr("Keep in Menu Bar", "菜单栏驻留"),
                isOn: Binding(
                    get: { coordinator.config.keepRunningInMenuBar },
                    set: { keep in
                        coordinator.config.keepRunningInMenuBar = keep
                        coordinator.persistConfig(reconfigureSession: false)
                    }
                )
            )
            .font(.system(size: 12.5))
            .help(l10n.tr(
                "Keeps global shortcuts and auto-scale active after closing the main window.",
                "关闭主窗口后继续在菜单栏保持快捷键与自动缩放运行"
            ))

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Screenshot Folder", "截图目录"))
                        .font(.system(size: 12.5))
                        .frame(width: 120, alignment: .leading)
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

                        Button(l10n.tr("Choose…", "选择…")) {
                            chooseScreenshotDirectory()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }

                GridRow {
                    Text(l10n.tr("Filename Template", "文件名模板"))
                        .font(.system(size: 12.5))
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

                        if case .invalid(let reason) = validation {
                            StatusBadge(localizedTemplateValidationReason(reason, l10n: l10n), color: .red)
                        }
                    }
                    .help(l10n.tr(
                        "Tokens: %PN% (App), %WT% (Window Title), %Y%, %M%, %D%, %H%, %m%, %S%",
                        "可用变量：%PN% 应用名，%WT% 窗口标题，%Y%%M%%D% 日期，%H%%m%%S% 时间"
                    ))
                }
            }
        }
    }

    // MARK: - Advanced (Collapsed)

    private func advancedSection(profileID: UUID, l10n: L10n) -> some View {
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
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text(l10n.tr("Pixel Format", "像素格式"))
                                .font(.system(size: 12.5))
                                .frame(width: 130, alignment: .leading)
                            Picker("", selection: binding(profileID, \.capture.preferredPixelFormat)) {
                                ForEach(CapturePixelFormat.allCases) { fmt in
                                    Text(l10n.pixelFormat(fmt)).tag(fmt)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }

                        GridRow {
                            Text(l10n.tr("Dynamic Range", "动态范围"))
                                .font(.system(size: 12.5))
                            Picker("", selection: binding(profileID, \.capture.dynamicRange)) {
                                ForEach(DynamicRangeMode.allCases) { dr in
                                    Text(l10n.dynamicRange(dr)).tag(dr)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 160)
                        }

                        GridRow {
                            Text(l10n.tr("Duplicate Frames", "重复帧检测"))
                                .font(.system(size: 12.5))
                            Picker("", selection: binding(profileID, \.capture.duplicateFrameMode)) {
                                ForEach(DuplicateFrameMode.allCases) { mode in
                                    Text(l10n.duplicateFrameMode(mode)).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                        }
                        .help(l10n.tr(
                            "Skips redundant GPU passes when source frames are static.",
                            "画面静止时跳过重复渲染以降低功耗"
                        ))

                        GridRow {
                            Text(l10n.tr("1× Demagnify", "1× 窗口反放大"))
                                .font(.system(size: 12.5))
                            HStack(spacing: 8) {
                                Picker("", selection: $coordinator.nonRetinaMode) {
                                    Text(l10n.tr("Auto", "自动")).tag(NonRetinaDetectionMode.auto)
                                    Text(l10n.tr("Force 1×", "强制 1×")).tag(NonRetinaDetectionMode.force1x)
                                    Text(l10n.tr("Off (2×)", "关闭")).tag(NonRetinaDetectionMode.force2x)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 220)

                                if coordinator.detectedContentResolution != .nativeFull {
                                    StatusBadge("1×", color: .green)
                                }
                            }
                        }
                        .help(l10n.tr(
                            "Recovers native 1× pixels from macOS-magnified Wine and retro windows.",
                            "还原 Wine 或低分辨率窗口被系统 2× 放大的原始像素"
                        ))

                        GridRow {
                            Text(l10n.tr("Fullscreen Video Input", "全屏视频输入"))
                                .font(.system(size: 12.5))
                            HStack(spacing: 8) {
                                Picker("", selection: binding(profileID, \.capture.fullscreenVideoInput)) {
                                    Text(l10n.tr("Auto", "自动")).tag(FullscreenVideoInputMode.auto)
                                    Text("480p").tag(FullscreenVideoInputMode.p480)
                                    Text("720p").tag(FullscreenVideoInputMode.p720)
                                    Text("1080p").tag(FullscreenVideoInputMode.p1080)
                                    Text(l10n.tr("Native", "原生")).tag(FullscreenVideoInputMode.native)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 280)

                                if cap.fullscreenVideoInput == .auto,
                                   coordinator.isScalingSessionOpen,
                                   coordinator.detectedOpticalResolution.isConfirmed
                                {
                                    let detected = coordinator.detectedOpticalResolution
                                    let label = detected.tier == .native
                                        ? l10n.tr("Native", "原生")
                                        : detected.tier.badgeLabel
                                    StatusBadge(label, color: detected.tier == .native ? .secondary : .green)
                                }
                            }
                        }
                        .help(l10n.tr(
                            "Auto uses real-time GPU spectral analysis to detect true video resolution (480p/720p/1080p/1440p) across any display and aspect ratio, while keeping native Retina UI sharp.",
                            "自动模式通过 GPU 实时频谱分析识别视频真实分辨率（480p/720p/1080p/1440p），兼容各种屏幕尺寸与黑边比例，同时保持原生 Retina 界面文字锐利。"
                        ))

                        GridRow {
                            Text(l10n.tr("Frame Rate Limit", "帧率上限"))
                                .font(.system(size: 12.5))
                            HStack(spacing: 10) {
                                Toggle("", isOn: fpsLimited)
                                    .labelsHidden()
                                if cap.frameRateLimit != nil {
                                    Stepper(value: fpsValue, in: 15...240, step: 5) {
                                        Text("\(fpsValue.wrappedValue) FPS")
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .monospacedDigit()
                                    }
                                } else {
                                    Text(l10n.tr("Uncapped", "不限"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)

                    HStack(spacing: 24) {
                        Toggle(
                            l10n.tr("Low-Latency Present", "低延迟呈现"),
                            isOn: binding(profileID, \.capture.lowLatencyPresent)
                        )
                        .help(l10n.tr(
                            "Disables extra compositor buffering when frame generation is off.",
                            "未启用帧生成时跳过额外合成缓冲以降低延迟"
                        ))

                        Toggle(
                            l10n.tr("VRR Direct-Scanout", "VRR 直出"),
                            isOn: $coordinator.vrrDirectScanoutEnabled
                        )
                        .help(l10n.tr(
                            "Composites cursor and HUD directly in Metal with zero sub-windows for ProMotion VRR.",
                            "在 Metal 内直接合成光标与监视器，避免悬浮层影响 ProMotion VRR"
                        ))
                    }
                    .font(.system(size: 12.5))

                    Divider()

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text(l10n.tr("Frame Gen Backend", "补帧后端"))
                                .font(.system(size: 12.5))
                                .frame(width: 130, alignment: .leading)
                            Picker("", selection: binding(profileID, \.frameGen.backend)) {
                                ForEach(FrameGenBackend.allCases) { backend in
                                    Text(l10n.frameGenBackend(backend)).tag(backend)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }

                        GridRow {
                            Text(l10n.tr("Artifact Guard", "伪影抑制"))
                                .font(.system(size: 12.5))
                            Picker("", selection: binding(profileID, \.frameGen.artifactGuardSensitivity)) {
                                ForEach(ArtifactGuardSensitivity.allCases) { sens in
                                    Text(l10n.artifactGuard(sens)).tag(sens)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                        }
                        .help(l10n.tr(
                            "Suppresses ghosting and occlusion artifacts during frame generation.",
                            "抑制帧生成过程中的残影与遮挡伪影"
                        ))
                    }

                    Divider()

                    // Ignore List
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n.tr("Ignore List", "忽略列表"))
                            .font(.system(size: 12.5, weight: .medium))

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
                            .controlSize(.small)
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
                                            Text(l10n.tr("Built-in", "内置"))
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(.secondary)
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
                        .frame(maxHeight: 110)
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Text(coordinator.configStore.fileURL.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(l10n.tr("Reveal", "在访达中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([coordinator.configStore.fileURL])
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)

                        Button(l10n.tr("Export…", "导出…")) {
                            exportFullConfig(l10n: l10n)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)

                        Button(l10n.tr("Reset Config…", "重置配置…"), role: .destructive) {
                            showResetConfirmation = true
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            } label: {
                Text(l10n.tr("Advanced", "高级"))
                    .font(.system(size: 13.5, weight: .semibold))
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
            return l10n.tr("Empty", "不能为空")
        }
        if reason.contains("Unclosed") {
            return l10n.tr("Unclosed '%'", "未闭合 '%'")
        }
        if reason.hasPrefix("Unknown token") {
            let suffix = reason.replacingOccurrences(of: "Unknown token ", with: "")
            return l10n.tr("Unknown \(suffix)", "未知 \(suffix)")
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
                    title: l10n.tr("Config Exported", "配置已导出"),
                    subtitle: url.lastPathComponent,
                    style: .success
                )
            } catch {
                coordinator.lastErrorMessage = error.localizedDescription
            }
        }
    }
}
