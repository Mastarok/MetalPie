import AppKit
import MetalPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Master-detail editor for MetalPie's Default Profile and Per-Application Rules (`配置文件` / `Profiles`).
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
                Text(l10n.tr("Profiles", "配置文件"))
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Menu {
                    Menu(l10n.tr("Add from Open Window", "从已打开窗口创建")) {
                        if coordinator.windows.isEmpty {
                            Text(l10n.tr("No open windows found", "暂未检测到打开的窗口"))
                        } else {
                            ForEach(coordinator.windows) { win in
                                Button(win.displayName) {
                                    _ = coordinator.addProfile(from: win)
                                }
                            }
                        }
                    }
                    Button(l10n.tr("Choose Application (.app)…", "选择应用程序 (.app)…")) {
                        pickApplicationForProfile()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .fixedSize()
                .help(l10n.tr("Add App Rule", "为单个游戏或应用新建规则"))
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
                                Text(l10n.tr("Used for all apps without custom rules", "未单独设置的应用默认使用此项"))
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
                .help(l10n.tr("Duplicate Profile", "复制此配置"))

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
                .help(l10n.tr("Delete Profile", "删除此配置"))
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
                    Text(l10n.tr(
                        "Applies to any window that doesn't have its own per-app rule. Changes save immediately.",
                        "没有单独设置规则的游戏或软件都会使用这里的效果，修改后自动保存并立即生效。"
                    ))
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
            Button {
                coordinator.selectedProfileID = profile.id
                coordinator.selectedTab = .settings
            } label: {
                Label(l10n.tr("Mouse & Frame Gen…", "调鼠标与补帧…"), systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }

    private func matchRulesCard(profile: Profile, l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("App Matching Rules", "匹配目标应用"),
            subtitle: l10n.tr(
                "MetalPie automatically picks this profile when a window matches these fields.",
                "当窗口符合以下条件时，自动套用这套专属缩放设置。"
            ),
            symbol: "scope"
        ) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(l10n.tr("Bundle ID", "应用标识 (Bundle ID)"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 145, alignment: .leading)
                    TextField(
                        "com.example.game",
                        text: optionalStringBinding(profile.id, \.bundleIdentifier)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text(l10n.tr("App Location", "应用路径"))
                        .font(.system(size: 12, weight: .medium))
                    TextField(
                        "/Applications/Game.app",
                        text: optionalStringBinding(profile.id, \.appPath)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text(l10n.tr("Window Title Filter", "窗口标题匹配（可选）"))
                        .font(.system(size: 12, weight: .medium))
                    TextField(
                        l10n.tr("Optional regex (e.g. ^Hollow Knight.*)", "可留空；填关键词或正则可仅匹配特定窗口"),
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
            title: l10n.tr("Scaling Mode & Display", "放大方式与显示器"),
            symbol: "display"
        ) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Scaling Mode", "缩放模式"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 150, alignment: .leading)
                    Picker("", selection: binding(profile.id, \.scalingModeID)) {
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
                        let custom = coordinator.config.scalingModes.filter { !$0.isBuiltIn }
                        if !custom.isEmpty {
                            Section(l10n.tr("Custom Modes", "自定义模式")) {
                                ForEach(custom) { mode in
                                    Text(l10n.builtInModeName(mode)).tag(mode.id)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }

                GridRow {
                    Text(l10n.tr("Display Style", "放大形态"))
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
                        Text(l10n.tr("Fullscreen", "全屏放大")).tag(0)
                        Text(l10n.tr("Resizable Window", "窗口放大（可调大小）")).tag(1)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    .disabled(profile.threeDGameMode)
                }

                if isWindowed {
                    GridRow {
                        Text(l10n.tr("Initial Window Scale", "初始放大倍数"))
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
                    Text(l10n.tr("Multi-Monitor Target", "多显示器目标"))
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: binding(profile.id, \.multiMonitorMode)) {
                        ForEach(MultiMonitorMode.allCases) { m in
                            Text(l10n.multiMonitorMode(m)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
            }
        }
    }

    private func alignmentAndCroppingCard(profile: Profile, l10n: L10n) -> some View {
        let sampleSource = PixelSize(width: 1280, height: 720)
        let cropValid = profile.crop.isValid(for: sampleSource)

        return SectionCard(
            title: l10n.tr("Screen Position & Edge Cropping", "画面位置与去黑边裁切"),
            symbol: "crop"
        ) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.tr("Screen Alignment", "画面对齐位置"))
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
                            l10n.tr("Crop Window Edges (Remove Black Bars / Borders)", "裁切多余边缘（去除视频黑边或窗口白边）"),
                            isOn: binding(profile.id, \.crop.enabled)
                        )
                        .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if profile.crop.enabled {
                            StatusBadge(
                                cropValid
                                    ? l10n.tr("Valid", "裁切有效")
                                    : l10n.tr("Too Large (Min 64px)", "裁切过大（需保留≥64px）"),
                                color: cropValid ? .green : .red
                            )
                        }
                    }

                    if profile.crop.enabled {
                        HStack(spacing: 10) {
                            cropField(label: l10n.tr("Left", "左 (px)"), value: binding(profile.id, \.crop.left))
                            cropField(label: l10n.tr("Top", "上 (px)"), value: binding(profile.id, \.crop.top))
                            cropField(label: l10n.tr("Right", "右 (px)"), value: binding(profile.id, \.crop.right))
                            cropField(label: l10n.tr("Bottom", "下 (px)"), value: binding(profile.id, \.crop.bottom))
                        }
                        Text(l10n.tr(
                            "MetalPie automatically keeps at least 64×64 pixels of visible content.",
                            "系统会自动保护至少保留 64×64 像素画面，不必担心填错导致异常。"
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
                .frame(width: 66)
        }
    }

    private func autoScaleAndGameModeCard(profile: Profile, l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Auto-Scale & 3D Game Mode", "自动放大与 3D 游戏模式"),
            symbol: "gamecontroller.fill",
            accent: .purple
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(l10n.tr("Auto-Scale on Focus", "自动放大"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 150, alignment: .leading)
                    Picker("", selection: binding(profile.id, \.autoScaleMode)) {
                        ForEach(AutoScaleMode.allCases) { mode in
                            Text(l10n.autoScaleMode(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }

                if profile.autoScaleMode != .disabled {
                    HStack(spacing: 12) {
                        Text(l10n.tr("Wait Before Scaling", "切换等待时间"))
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 150, alignment: .leading)
                        Slider(
                            value: binding(profile.id, \.autoScaleDelaySeconds),
                            in: 0.0...5.0,
                            step: 0.1
                        )
                        .frame(maxWidth: 200)
                        Text(l10n.tr(
                            String(format: "%.1fs", profile.autoScaleDelaySeconds),
                            String(format: "%.1f 秒", profile.autoScaleDelaySeconds)
                        ))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                    }
                }

                Divider()

                Toggle(isOn: binding(profile.id, \.threeDGameMode)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("3D Game Mode (FPS / Action Games)", "3D 游戏模式（FPS / 动作游戏专用）"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(l10n.tr(
                            "Forces fullscreen, hides toolbar, locks cursor inside the game, and safely exits if another app pops up on top.",
                            "强制全屏并隐藏工具栏、锁定游戏鼠标，有其他弹窗遮挡时自动安全退出缩放。"
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
            title: l10n.tr("Window Borders & Overlay Bar", "窗口边框与顶部工具栏"),
            symbol: "macwindow"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
                    Toggle(
                        l10n.tr("Include Window Title Bar", "保留窗口顶部标题栏"),
                        isOn: binding(profile.id, \.capture.captureTitleBar)
                    )
                    Toggle(
                        l10n.tr("Exclude Window Shadows (Recommended)", "去除窗口外阴影（推荐）"),
                        isOn: binding(profile.id, \.capture.ignoreShadows)
                    )
                }
                .font(.system(size: 12.5))

                Divider()

                HStack(spacing: 12) {
                    Text(l10n.tr("Top Floating Toolbar", "顶部悬浮工具栏"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 150, alignment: .leading)
                    Picker("", selection: binding(profile.id, \.toolbarMode)) {
                        ForEach(ToolbarMode.allCases) { mode in
                            Text(l10n.toolbarMode(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 270)
                }

                Toggle(
                    l10n.tr("Show Live FPS Overlay Automatically", "开始放大时自动显示左上角帧率信息"),
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
