import AppKit
import MetalPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Master-detail editor for MetalPie's Default Profile and Per-Application Profiles.
///
/// Every edit persists immediately via `ConfigStore.save(...)` AND live-reconfigures any running
/// scaling session (completely fixing MetalDuck's silently-dropped profile edit bugs!).
struct ProfilesView: View {
    @Bindable var coordinator: AppCoordinator

    private var selectedProfile: Profile? {
        coordinator.config.profiles.first(where: { $0.id == coordinator.selectedProfileID })
            ?? coordinator.config.defaultProfile
    }

    var body: some View {
        let l10n = coordinator.l10n

        HSplitView {
            profilesSidebar(l10n: l10n)
                .frame(minWidth: 220, idealWidth: 245, maxWidth: 290)

            if let profile = selectedProfile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        profileHeader(profile: profile, l10n: l10n)
                        if !profile.isDefault {
                            matchRulesCard(profile: profile, l10n: l10n)
                        }
                        scalingAndPresentationCard(profile: profile, l10n: l10n)
                        alignmentAndCroppingCard(profile: profile, l10n: l10n)
                        autoScaleAndGameModeCard(profile: profile, l10n: l10n)
                        chromeAndCaptureCard(profile: profile, l10n: l10n)
                    }
                    .padding(18)
                }
                .frame(minWidth: 520)
            }
        }
    }

    // MARK: - Left Sidebar

    private func profilesSidebar(l10n: L10n) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(l10n.tr("Profiles", "应用配置"))
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Menu {
                    Menu(l10n.tr("Add from Running Window", "从运行中窗口创建")) {
                        if coordinator.windows.isEmpty {
                            Text(l10n.tr("No running windows found", "未检测到运行中窗口"))
                        } else {
                            ForEach(coordinator.windows) { win in
                                Button(win.displayName) {
                                    _ = coordinator.addProfile(from: win)
                                }
                            }
                        }
                    }
                    Button(l10n.tr("Add Application (.app)…", "选择应用程序 (.app)…")) {
                        pickApplicationForProfile()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .fixedSize()
                .help(l10n.tr("Add Per-App Profile", "新建应用专属配置"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(selection: $coordinator.selectedProfileID) {
                ForEach(coordinator.config.profiles) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: profile.isDefault ? "star.fill" : "app.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(profile.isDefault ? .yellow : .accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.isDefault ? l10n.tr("Default Profile", "全局默认配置") : profile.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            if let bundle = profile.bundleIdentifier, !bundle.isEmpty {
                                Text(bundle)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else if profile.isDefault {
                                Text(l10n.tr("Fallback for all apps", "所有未单独配置应用的默认值"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if profile.autoScaleMode != .disabled {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.cyan)
                        }
                    }
                    .tag(profile.id)
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 6) {
                Button {
                    pickApplicationForProfile()
                } label: {
                    Label(l10n.tr("Add App…", "添加应用…"), systemImage: "plus.app")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button {
                    if let p = selectedProfile {
                        _ = coordinator.duplicateProfile(id: p.id)
                    }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(selectedProfile == nil)
                .help(l10n.tr("Duplicate Selected Profile", "复制所选配置"))

                Spacer()

                Button {
                    if let p = selectedProfile, !p.isDefault {
                        coordinator.deleteProfile(id: p.id)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(selectedProfile?.isDefault ?? true)
                .help(l10n.tr("Delete Selected Profile", "删除所选配置"))
            }
            .padding(10)
        }
    }

    // MARK: - Profile Detail Cards

    private func profileHeader(profile: Profile, l10n: L10n) -> some View {
        HStack {
            if profile.isDefault {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.tr("Default Profile", "全局默认配置"))
                        .font(.system(size: 20, weight: .bold))
                    Text(l10n.tr("Applied automatically whenever no per-app profile matches the target window.", "当目标窗口未命中任何应用专属规则时自动使用此配置。"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField(
                    l10n.tr("Profile Name", "配置名称"),
                    text: binding(profile.id, \.name)
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16, weight: .bold))
                .frame(maxWidth: 320)
            }
            Spacer()
            if profile.threeDGameMode {
                StatusBadge(l10n.tr("3D Game Mode", "3D 游戏模式"), color: .purple, symbol: "gamecontroller.fill")
            }
        }
    }

    private func matchRulesCard(profile: Profile, l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Window Match Rules", "窗口匹配规则"),
            subtitle: l10n.tr("More specific rules (Bundle ID + Title Regex) take precedence over broader rules.", "规则越精确（Bundle ID + 窗口标题正则），优先级越高。"),
            symbol: "scope"
        ) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Bundle ID")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    TextField(
                        "com.example.game",
                        text: optionalStringBinding(profile.id, \.bundleIdentifier)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text(l10n.tr("App Path", "应用程序路径"))
                        .font(.system(size: 12, weight: .medium))
                    TextField(
                        "/Applications/Game.app",
                        text: optionalStringBinding(profile.id, \.appPath)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text(l10n.tr("Window Title Regex", "窗口标题正则"))
                        .font(.system(size: 12, weight: .medium))
                    TextField(
                        l10n.tr("Optional regex (e.g. ^Hollow Knight.*)", "可选正则（如 ^Hollow Knight.*）"),
                        text: optionalStringBinding(profile.id, \.windowTitlePattern)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }

    private func scalingAndPresentationCard(profile: Profile, l10n: L10n) -> some View {
        let isWindowed = profile.presentationMode.isWindowed
        let initialScale: Double = {
            if case .windowed(let scale, _) = profile.presentationMode {
                return scale ?? 1.5
            }
            return 1.5
        }()

        return SectionCard(
            title: l10n.tr("Scaling & Presentation", "超分与显示模式"),
            symbol: "display"
        ) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Scaling Mode", "超分预设"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 150, alignment: .leading)
                    Picker("", selection: binding(profile.id, \.scalingModeID)) {
                        ForEach(coordinator.config.scalingModes) { mode in
                            Text(l10n.builtInModeName(mode)).tag(mode.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }

                GridRow {
                    Text(l10n.tr("Presentation", "呈现方式"))
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: Binding<Int>(
                        get: { isWindowed ? 1 : 0 },
                        set: { idx in
                            coordinator.updateProfile(id: profile.id) { p in
                                if idx == 0 {
                                    p.presentationMode = .fullscreen
                                } else {
                                    p.presentationMode = .windowed(initialScale: initialScale, width: nil)
                                }
                            }
                        }
                    )) {
                        Text(l10n.tr("Fullscreen Overlay", "全屏覆盖缩放")).tag(0)
                        Text(l10n.tr("Resizable Windowed", "可调节窗口缩放")).tag(1)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    .disabled(profile.threeDGameMode)
                }

                if isWindowed {
                    GridRow {
                        Text(l10n.tr("Initial Window Scale", "初始窗口倍率"))
                            .font(.system(size: 12, weight: .medium))
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(
                                    get: { initialScale },
                                    set: { val in
                                        let rounded = (val * 20).rounded() / 20
                                        coordinator.updateProfile(id: profile.id) { p in
                                            p.presentationMode = .windowed(initialScale: rounded, width: nil)
                                        }
                                    }
                                ),
                                in: 1.0...3.0
                            )
                            .frame(maxWidth: 200)
                            Text(String(format: "%.2f×", initialScale))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }

                GridRow {
                    Text(l10n.tr("Multi-Monitor Target", "多显示器策略"))
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: binding(profile.id, \.multiMonitorMode)) {
                        ForEach(MultiMonitorMode.allCases) { m in
                            Text(l10n.multiMonitorMode(m)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
            }
        }
    }

    private func alignmentAndCroppingCard(profile: Profile, l10n: L10n) -> some View {
        let sampleSource = PixelSize(width: 1280, height: 720)
        let cropValid = profile.crop.isValid(for: sampleSource)

        return SectionCard(
            title: l10n.tr("Output Alignment & Pixel Cropping", "画面对齐与边缘裁切"),
            symbol: "crop"
        ) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.tr("9-Point Alignment", "九宫格画面对齐"))
                        .font(.system(size: 12, weight: .semibold))
                    OutputAlignmentGridPicker(
                        selection: binding(profile.id, \.outputAlignment),
                        l10n: l10n
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(
                            l10n.tr("Enable Source Pixel Cropping", "启用源画面像素裁切 (去除黑边/窗口边框)"),
                            isOn: binding(profile.id, \.crop.enabled)
                        )
                        .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if profile.crop.enabled {
                            StatusBadge(
                                cropValid
                                    ? l10n.tr("Valid (>=64px)", "有效 (>=64px)")
                                    : l10n.tr("Exceeds min 64px", "超出最小 64px 保护"),
                                color: cropValid ? .green : .red
                            )
                        }
                    }

                    if profile.crop.enabled {
                        HStack(spacing: 10) {
                            cropField(label: l10n.tr("Left", "左"), value: binding(profile.id, \.crop.left))
                            cropField(label: l10n.tr("Top", "上"), value: binding(profile.id, \.crop.top))
                            cropField(label: l10n.tr("Right", "右"), value: binding(profile.id, \.crop.right))
                            cropField(label: l10n.tr("Bottom", "下"), value: binding(profile.id, \.crop.bottom))
                        }
                        Text(l10n.tr(
                            "MetalPie enforces a 64px minimum remaining width/height safety guard automatically.",
                            "MetalPie 会自动强制保留至少 64×64 有效像素区域，防止非法裁切崩溃。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func cropField(label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 64)
        }
    }

    private func autoScaleAndGameModeCard(profile: Profile, l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Auto-Scale & 3D Game Mode", "自动缩放与 3D 游戏模式"),
            symbol: "gamecontroller.fill",
            accent: .purple
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(l10n.tr("Auto-Scale on Focus", "获焦自动缩放"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 150, alignment: .leading)
                    Picker("", selection: binding(profile.id, \.autoScaleMode)) {
                        ForEach(AutoScaleMode.allCases) { mode in
                            Text(l10n.autoScaleMode(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }

                if profile.autoScaleMode != .disabled {
                    HStack(spacing: 12) {
                        Text(l10n.tr("Activation Delay", "触发防抖延迟"))
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 150, alignment: .leading)
                        Slider(
                            value: binding(profile.id, \.autoScaleDelaySeconds),
                            in: 0.0...5.0,
                            step: 0.1
                        )
                        .frame(maxWidth: 200)
                        Text(String(format: "%.1f s", profile.autoScaleDelaySeconds))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Divider()

                Toggle(isOn: binding(profile.id, \.threeDGameMode)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("3D Game Mode (FPS / Action Safeguards)", "3D 游戏模式（FPS / 动作游戏专属优化）"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(l10n.tr(
                            "Forces fullscreen, hides toolbar, disables duplicate-frame check, enforces strict cursor lock, and safely stops if a foreign window overlaps >= 8 pt.",
                            "强制全屏、隐藏工具栏、关闭重复帧检测、启用严格光标锁定，并在其他窗口遮挡 >=8pt 时安全退出。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func chromeAndCaptureCard(profile: Profile, l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Window Capture & Overlay Chrome", "窗口捕获与悬浮组件"),
            symbol: "macwindow"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
                    Toggle(
                        l10n.tr("Capture Window Title Bar", "包含窗口标题栏"),
                        isOn: binding(profile.id, \.capture.captureTitleBar)
                    )
                    Toggle(
                        l10n.tr("Ignore Window Drop Shadows", "忽略窗口阴影（推荐）"),
                        isOn: binding(profile.id, \.capture.ignoreShadows)
                    )
                }
                .font(.system(size: 12.5))

                Divider()

                HStack(spacing: 12) {
                    Text(l10n.tr("Floating Toolbar", "顶部悬浮工具栏"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 150, alignment: .leading)
                    Picker("", selection: binding(profile.id, \.toolbarMode)) {
                        ForEach(ToolbarMode.allCases) { mode in
                            Text(l10n.toolbarMode(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 250)
                }

                Toggle(
                    l10n.tr("Show Real-Time Profiler HUD by Default", "启动时默认显示性能监视 HUD"),
                    isOn: binding(profile.id, \.showProfilerHUD)
                )
                .font(.system(size: 12.5))
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

    private func optionalStringBinding(_ profileID: UUID, _ keyPath: WritableKeyPath<Profile, String?>) -> Binding<String> {
        Binding(
            get: {
                (coordinator.config.profiles.first(where: { $0.id == profileID }) ?? coordinator.config.defaultProfile)[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                coordinator.updateProfile(id: profileID) {
                    $0[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
                }
            }
        )
    }

    private func pickApplicationForProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            _ = coordinator.addProfileFromApplicationURL(url)
        }
    }
}
