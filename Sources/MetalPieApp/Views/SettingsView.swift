import AppKit
import MetalPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Global application settings: Carbon Global Hotkey Recorder + Reserved Panic Stop,
/// Countdown timer, Screenshot directory & live template preview, Menu Bar behavior,
/// Instant Bilingual Language switcher, Auto-Scale System Blacklist, and Config Export/Reset.
struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var newExcludedBundleID: String = ""
    @State private var showResetConfirmation: Bool = false

    var body: some View {
        let l10n = coordinator.l10n

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.tr("General Settings", "通用设置与快捷键"))
                        .font(.system(size: 22, weight: .bold))
                    Text(l10n.tr(
                        "Global Carbon shortcuts (work without Accessibility), screenshots, language, and system safeguards.",
                        "全局 Carbon 快捷键（无需辅助功能权限即可跨全屏空间生效）、截图模板、界面语言与自动缩放黑名单。"
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                hotkeysCard(l10n: l10n)
                screenshotsCard(l10n: l10n)
                behaviorAndLanguageCard(l10n: l10n)
                blacklistCard(l10n: l10n)
                configStorageCard(l10n: l10n)
            }
            .padding(20)
        }
        .alert(
            l10n.tr("Reset All Settings to Defaults?", "确认恢复所有默认配置？"),
            isPresented: $showResetConfirmation
        ) {
            Button(l10n.tr("Cancel", "取消"), role: .cancel) {}
            Button(l10n.tr("Reset", "确认重置"), role: .destructive) {
                coordinator.resetConfigToDefaults()
            }
        } message: {
            Text(l10n.tr(
                "Custom profiles, hotkeys, and custom scaling modes will be replaced by MetalPie's default configuration.",
                "所有自定义应用配置、快捷键与自定义着色器管线将被恢复为初始默认配置。"
            ))
        }
    }

    // MARK: - Global Hotkeys Card

    private func hotkeysCard(l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Global Keyboard Shortcuts", "全局快捷键"),
            subtitle: l10n.tr(
                "Powered by Carbon RegisterEventHotKey — works inside games & native Full-Screen Spaces without Accessibility permission.",
                "基于 Carbon RegisterEventHotKey 实现 — 无需辅助功能权限，在游戏与原生全屏空间内全局可用。"
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

                // Reserved Panic Stop Badge (non-overridable safety chord)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.hotkeyAction(.panicStop))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(l10n.tr(
                            "Always active with zero debounce — immediately closes overlay and restores system cursor.",
                            "始终生效且零防抖 — 立即终止覆盖层并强制恢复系统硬件光标。"
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

    // MARK: - Screenshots Card

    private func screenshotsCard(l10n: L10n) -> some View {
        let validation = ScreenshotFilenameTemplate.validate(coordinator.config.screenshotFilenameTemplate)
        let exampleName = ScreenshotFilenameTemplate.expand(
            template: coordinator.config.screenshotFilenameTemplate,
            processName: "HollowKnight",
            windowTitle: "City of Tears"
        ) + ".png"

        return SectionCard(
            title: l10n.tr("Cursor-Free PNG Screenshots", "无光标高清 PNG 截图"),
            subtitle: l10n.tr(
                "Tokens: %PN% (App), %WT% (Window Title), %Y% %M% %D% %H% %m% %S% %MS%",
                "支持变量：%PN% (应用名)、%WT% (窗口标题)、%Y% %M% %D% %H% %m% %S% %MS%"
            ),
            symbol: "camera.fill",
            accent: .green
        ) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Output Directory", "保存目录"))
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 150, alignment: .leading)
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

                        Button(l10n.tr("Choose…", "浏览…")) {
                            chooseScreenshotDirectory()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                GridRow {
                    Text(l10n.tr("Filename Template", "文件名模板"))
                        .font(.system(size: 12.5, weight: .medium))
                    VStack(alignment: .leading, spacing: 5) {
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
                                StatusBadge(l10n.tr("Valid", "格式有效"), color: .green)
                            case .invalid(let reason):
                                StatusBadge(localizedTemplateValidationReason(reason, l10n: l10n), color: .red)
                            }
                        }

                        HStack(spacing: 6) {
                            Text(l10n.tr("Preview:", "输出预览："))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(exampleName)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    // MARK: - App Behavior & Language Card

    private func behaviorAndLanguageCard(l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("App Behavior & Language", "应用行为与界面语言"),
            symbol: "globe",
            accent: .blue
        ) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Display Language", "界面显示语言"))
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 170, alignment: .leading)
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
                    .frame(width: 280)
                }

                GridRow {
                    Text(l10n.tr("Countdown Scale Timer", "倒计时缩放时长"))
                        .font(.system(size: 12.5, weight: .medium))
                    HStack(spacing: 10) {
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
            }

            Divider()

            Toggle(isOn: Binding(
                get: { coordinator.config.keepRunningInMenuBar },
                set: { keep in
                    coordinator.config.keepRunningInMenuBar = keep
                    coordinator.persistConfig(reconfigureSession: false)
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.tr("Keep Running in Menu Bar When Window Closes", "关闭主窗口后保持在菜单栏常驻运行"))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(l10n.tr("Allows global hotkeys, Auto-Scale, and active scaling sessions to keep running cleanly in the background.", "保持全局快捷键、自动缩放和正在进行的超分会话在后台稳定运行。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Auto-Scale System Blacklist

    private func blacklistCard(l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Auto-Scale Excluded Bundle IDs", "自动缩放排除名单 (Bundle ID)"),
            subtitle: l10n.tr("macOS system processes and MetalPie itself are permanently protected from auto-scaling.", "保护 macOS 系统界面进程与 MetalPie 自身不被误触发自动缩放。"),
            symbol: "hand.raised.fill",
            accent: .orange
        ) {
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
                                StatusBadge(l10n.tr("Protected", "受保护"), color: .secondary)
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
            .frame(maxHeight: 140)
        }
    }

    // MARK: - Config Persistence Card

    private func configStorageCard(l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Configuration Storage", "配置文件与备份"),
            symbol: "externaldrive.fill"
        ) {
            HStack(spacing: 10) {
                Text(coordinator.configStore.fileURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(l10n.tr("Reveal in Finder", "在访达中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([coordinator.configStore.fileURL])
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button(l10n.tr("Export Config…", "导出配置…")) {
                    exportFullConfig(l10n: l10n)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button(l10n.tr("Reset Defaults…", "恢复默认…"), role: .destructive) {
                    showResetConfirmation = true
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
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
