import AppKit
import MetalPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Master-detail editor for default and per-application profiles (`配置文件` / `Profiles`).
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
                .frame(minWidth: 210, idealWidth: 235, maxWidth: 275)

            if let profile = selectedProfile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        profileHeader(profile: profile, l10n: l10n)
                        if !profile.isDefault {
                            matchRulesCard(profile: profile, l10n: l10n)
                        }
                        scalingAndDisplayCard(profile: profile, l10n: l10n)
                        alignmentAndCroppingCard(profile: profile, l10n: l10n)
                        autoScaleAndGameModeCard(profile: profile, l10n: l10n)
                        captureAndOverlayCard(profile: profile, l10n: l10n)
                    }
                    .padding(18)
                }
                .frame(minWidth: 500)
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
                    Menu(l10n.tr("From Open Window", "从打开的窗口")) {
                        if coordinator.windows.isEmpty {
                            Text(l10n.tr("No Windows", "无可用窗口"))
                        } else {
                            ForEach(coordinator.windows) { win in
                                Button(win.displayName) {
                                    _ = coordinator.addProfile(from: win)
                                }
                            }
                        }
                    }
                    Button(l10n.tr("Choose Application…", "选择应用…")) {
                        pickApplicationForProfile()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .fixedSize()
                .help(l10n.tr("Add Profile", "新建配置"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(selection: $coordinator.selectedProfileID) {
                ForEach(coordinator.config.profiles) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: profile.isDefault ? "star.fill" : "app.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(profile.isDefault ? .yellow : .accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.isDefault ? l10n.tr("Default", "默认") : profile.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            if let bundle = profile.bundleIdentifier, !bundle.isEmpty {
                                Text(bundle)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
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
                .help(l10n.tr("Duplicate", "复制"))

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
                .help(l10n.tr("Delete", "删除"))
            }
            .padding(10)
        }
    }

    // MARK: - Detail Header

    private func profileHeader(profile: Profile, l10n: L10n) -> some View {
        HStack {
            if profile.isDefault {
                Text(l10n.tr("Default Profile", "默认配置"))
                    .font(.system(size: 18, weight: .bold))
            } else {
                TextField(
                    l10n.tr("Profile Name", "名称"),
                    text: binding(profile.id, \.name)
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: 300)
            }
            Spacer()
            if profile.threeDGameMode {
                StatusBadge(l10n.tr("3D Game Mode", "3D 游戏模式"), color: .purple)
            }
            Button {
                coordinator.selectedProfileID = profile.id
                coordinator.selectedTab = .settings
            } label: {
                Label(l10n.tr("Cursor & Frame Gen…", "光标与帧生成…"), systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Match Rules

    private func matchRulesCard(profile: Profile, l10n: L10n) -> some View {
        SectionCard(title: l10n.tr("Match Rules", "匹配规则")) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Bundle ID")
                        .font(.system(size: 12.5))
                        .frame(width: 110, alignment: .leading)
                    TextField(
                        "com.example.game",
                        text: optionalStringBinding(profile.id, \.bundleIdentifier)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text(l10n.tr("App Path", "应用路径"))
                        .font(.system(size: 12.5))
                    TextField(
                        "/Applications/Game.app",
                        text: optionalStringBinding(profile.id, \.appPath)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text(l10n.tr("Window Title", "窗口标题"))
                        .font(.system(size: 12.5))
                    TextField(
                        l10n.tr("Regex (optional)", "正则（可选）"),
                        text: optionalStringBinding(profile.id, \.windowTitlePattern)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }

    // MARK: - Scaling & Display

    private func scalingAndDisplayCard(profile: Profile, l10n: L10n) -> some View {
        let isWindowed = profile.presentationMode.isWindowed
        let initialScale: Double = {
            if case .windowed(let scale, _) = profile.presentationMode {
                return scale ?? 1.5
            }
            return 1.5
        }()

        return SectionCard(title: l10n.tr("Scaling & Display", "缩放与显示")) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Scaling Mode", "缩放模式"))
                        .font(.system(size: 12.5))
                        .frame(width: 110, alignment: .leading)
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
                            Section(l10n.tr("Custom", "自定义")) {
                                ForEach(custom) { mode in
                                    Text(l10n.builtInModeName(mode)).tag(mode.id)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }

                GridRow {
                    Text(l10n.tr("Presentation", "显示方式"))
                        .font(.system(size: 12.5))
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
                        Text(l10n.tr("Fullscreen", "全屏")).tag(0)
                        Text(l10n.tr("Windowed", "窗口")).tag(1)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .disabled(profile.threeDGameMode)
                }

                if isWindowed {
                    GridRow {
                        Text(l10n.tr("Initial Scale", "初始倍率"))
                            .font(.system(size: 12.5))
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
                            .frame(maxWidth: 180)
                            Text(String(format: "%.2f×", initialScale))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }

                GridRow {
                    Text(l10n.tr("Target Display", "目标显示器"))
                        .font(.system(size: 12.5))
                    Picker("", selection: binding(profile.id, \.multiMonitorMode)) {
                        ForEach(MultiMonitorMode.allCases) { m in
                            Text(l10n.multiMonitorMode(m)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
            }
        }
    }

    // MARK: - Alignment & Cropping

    private func alignmentAndCroppingCard(profile: Profile, l10n: L10n) -> some View {
        let sampleSource = PixelSize(width: 1280, height: 720)
        let cropValid = profile.crop.isValid(for: sampleSource)

        return SectionCard(title: l10n.tr("Alignment & Crop", "对齐与裁剪")) {
            HStack(alignment: .top, spacing: 24) {
                OutputAlignmentGridPicker(
                    selection: binding(profile.id, \.outputAlignment),
                    l10n: l10n
                )

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(
                            l10n.tr("Crop", "裁剪"),
                            isOn: binding(profile.id, \.crop.enabled)
                        )
                        .font(.system(size: 12.5))
                        Spacer()
                        if profile.crop.enabled && !cropValid {
                            StatusBadge(
                                l10n.tr("Min 64 px", "至少保留 64 px"),
                                color: .red
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

    // MARK: - Auto-Scale & 3D Game Mode

    private func autoScaleAndGameModeCard(profile: Profile, l10n: L10n) -> some View {
        SectionCard(title: l10n.tr("Behavior", "行为")) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Auto-Scale", "自动缩放"))
                        .font(.system(size: 12.5))
                        .frame(width: 110, alignment: .leading)
                    Picker("", selection: binding(profile.id, \.autoScaleMode)) {
                        ForEach(AutoScaleMode.allCases) { mode in
                            Text(l10n.autoScaleMode(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }

                if profile.autoScaleMode != .disabled {
                    GridRow {
                        Text(l10n.tr("Delay", "延迟"))
                            .font(.system(size: 12.5))
                        HStack(spacing: 10) {
                            Slider(
                                value: binding(profile.id, \.autoScaleDelaySeconds),
                                in: 0.0...5.0,
                                step: 0.1
                            )
                            .frame(maxWidth: 180)
                            Text(String(format: "%.1fs", profile.autoScaleDelaySeconds))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }

            Divider()

            Toggle(
                l10n.tr("3D Game Mode", "3D 游戏模式"),
                isOn: binding(profile.id, \.threeDGameMode)
            )
            .font(.system(size: 12.5))
            .help(l10n.tr(
                "Forces fullscreen, hides toolbar, confines cursor, and stops scaling if another window overlaps.",
                "强制全屏、隐藏工具栏并限制光标范围，检测到其他窗口遮挡时自动停止缩放"
            ))
        }
    }

    // MARK: - Capture & Overlay

    private func captureAndOverlayCard(profile: Profile, l10n: L10n) -> some View {
        SectionCard(title: l10n.tr("Capture & Overlay", "捕获与界面")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    l10n.tr("Ignore Window Shadows", "忽略窗口阴影"),
                    isOn: binding(profile.id, \.capture.ignoreShadows)
                )
                .font(.system(size: 12.5))

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text(l10n.tr("Toolbar", "工具栏"))
                            .font(.system(size: 12.5))
                            .frame(width: 110, alignment: .leading)
                        Picker("", selection: binding(profile.id, \.toolbarMode)) {
                            ForEach(ToolbarMode.allCases) { mode in
                                Text(l10n.toolbarMode(mode)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }
                }

                Toggle(
                    l10n.tr("Profiler HUD", "性能监视器"),
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
