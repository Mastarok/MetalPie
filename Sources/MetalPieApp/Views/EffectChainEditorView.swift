import AppKit
import MetalPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Intuitive Scaling Modes workspace (`缩放模式` / `Scaling Modes`):
/// - Left column: Scenario filter chips (`全部` / `3D 游戏` / `动漫番剧` / `像素复古` / `通用高清`)
///   covering all 21 built-in presets (including the 6 official Anime4K modes, CuNNy, FXAA+FSR, Jinc, CRT-Lottes)
///   plus custom user modes (`+ New`, `Duplicate`, `Delete`, `Import`, `Export`).
/// - Right top: Live Apple Silicon Metal GPU Before/After Split Preview (`原画` vs `放大后`).
/// - Right middle: Clean, beginner-friendly 「画质微调」 card (for official Anime4K modes: just `画质档位` + `抑制白边`!).
/// - Right bottom: Collapsible `自定义效果链（进阶）` DisclosureGroup (collapsed for built-in presets, expanded for custom modes)
///   with full access to all 30 shaders and multi-pass `ScalingType` controls.
struct EffectChainEditorView: View {
    @Bindable var coordinator: AppCoordinator

    @State private var selectedScenarioFilter: ScenarioTag? = nil
    @State private var isAdvancedChainExpanded: Bool = false

    @State private var selectedScene: PreviewSampleScene = .pixelArtAnime
    @State private var customSourceImage: CGImage? = nil
    @State private var customSourceName: String? = nil
    @State private var previewSourceSize: PixelSize = PixelSize(width: 480, height: 270)
    @State private var previewOutputSize: PixelSize = PixelSize(width: 960, height: 540)
    @State private var originalDisplayImage: NSImage? = nil
    @State private var renderedDisplayImage: NSImage? = nil
    @State private var splitRatio: CGFloat = 0.5
    @State private var zoomLevel: CGFloat = 2.0
    @State private var previewRenderMs: Double? = nil
    @State private var isRenderingPreview: Bool = false
    @State private var previewError: String? = nil
    @State private var renderTask: Task<Void, Never>? = nil

    private var selectedMode: ScalingMode? {
        coordinator.config.scalingMode(for: coordinator.selectedScalingModeID)
            ?? coordinator.config.scalingModes.first
    }

    private static let officialAnime4KIDs: Set<UUID> = [
        ScalingMode.anime4kModeAID,
        ScalingMode.anime4kModeBID,
        ScalingMode.anime4kModeCID,
        ScalingMode.anime4kModeAAID,
        ScalingMode.anime4kModeBBID,
        ScalingMode.anime4kModeCAID
    ]

    var body: some View {
        let l10n = coordinator.l10n

        HSplitView {
            // Left: Scenario-Grouped Scaling Modes List
            modesSidebar(l10n: l10n)
                .frame(minWidth: 236, idealWidth: 256, maxWidth: 296)

            // Right: Live GPU Split Preview + Simple Quality Tuning + Collapsible Advanced Effect Chain
            if let mode = selectedMode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        modeHeaderBar(mode: mode, l10n: l10n)
                        liveMetalPreviewCard(mode: mode, l10n: l10n)
                        simpleQualityTuningCard(mode: mode, l10n: l10n)
                        advancedEffectChainSection(mode: mode, l10n: l10n)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .frame(minWidth: 480, maxWidth: .infinity)
                .onChange(of: coordinator.selectedScalingModeID) { _, newID in
                    if let updated = coordinator.config.scalingMode(for: newID) {
                        isAdvancedChainExpanded = !updated.isBuiltIn
                    }
                }
                .onChange(of: mode) { _, newMode in
                    schedulePreviewRender(for: newMode, debounce: true)
                }
                .onChange(of: selectedScene) { _, _ in
                    customSourceImage = nil
                    customSourceName = nil
                    schedulePreviewRender(for: mode, debounce: false)
                }
                .onAppear {
                    isAdvancedChainExpanded = !mode.isBuiltIn
                    schedulePreviewRender(for: mode, debounce: false)
                }
            } else {
                ContentUnavailableView(
                    l10n.tr("No Scaling Mode Selected", "请选择一个缩放模式"),
                    systemImage: "sparkles.rectangle.stack"
                )
            }
        }
    }

    // MARK: - Left Column: Scenario-Filtered Scaling Modes List

    private func modesSidebar(l10n: L10n) -> some View {
        let customModes = coordinator.config.scalingModes.filter { !$0.isBuiltIn }

        return VStack(spacing: 0) {
            HStack {
                Text(l10n.tr("Scaling Modes", "缩放模式"))
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button {
                    let created = coordinator.createNewScalingMode()
                    selectedScenarioFilter = nil
                    isAdvancedChainExpanded = true
                    coordinator.selectedScalingModeID = created.id
                } label: {
                    Label(l10n.tr("New", "新建"), systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(l10n.tr("Create Custom Scaling Mode", "新建自定义缩放模式"))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Scenario Filter Chips (2 neat rows — compact "All" so "Anime & 2D" & "General & Video" never truncate)
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    scenarioFilterChip(title: l10n.tr("All", "全部"), symbol: nil, tag: nil, fillWidth: false)
                    scenarioFilterChip(
                        title: l10n.scenarioTag(.game3D),
                        symbol: ScenarioTag.game3D.symbolName,
                        tag: .game3D,
                        fillWidth: true
                    )
                    scenarioFilterChip(
                        title: l10n.scenarioTag(.anime),
                        symbol: ScenarioTag.anime.symbolName,
                        tag: .anime,
                        fillWidth: true
                    )
                }
                HStack(spacing: 5) {
                    scenarioFilterChip(
                        title: l10n.scenarioTag(.pixelRetro),
                        symbol: ScenarioTag.pixelRetro.symbolName,
                        tag: .pixelRetro,
                        fillWidth: true
                    )
                    scenarioFilterChip(
                        title: l10n.scenarioTag(.generalVideo),
                        symbol: ScenarioTag.generalVideo.symbolName,
                        tag: .generalVideo,
                        fillWidth: true
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            List(selection: $coordinator.selectedScalingModeID) {
                if let filter = selectedScenarioFilter {
                    let matching = coordinator.orderedBuiltInModes(for: filter)
                    Section(l10n.scenarioTag(filter)) {
                        ForEach(matching) { mode in
                            modeListRow(mode, l10n: l10n)
                                .tag(mode.id)
                        }
                    }
                } else {
                    ForEach(ScenarioTag.allCases) { tag in
                        let group = coordinator.orderedBuiltInModes(for: tag)
                        if !group.isEmpty {
                            Section(l10n.scenarioTag(tag)) {
                                ForEach(group) { mode in
                                    modeListRow(mode, l10n: l10n)
                                        .tag(mode.id)
                                }
                            }
                        }
                    }
                }

                if !customModes.isEmpty && selectedScenarioFilter == nil {
                    Section(l10n.tr("My Custom Modes", "我的自定义模式")) {
                        ForEach(customModes) { mode in
                            modeListRow(mode, l10n: l10n)
                                .tag(mode.id)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            // Footer Actions: Duplicate / Delete / Import / Export
            HStack(spacing: 6) {
                Button {
                    if let copy = coordinator.duplicateScalingMode(id: coordinator.selectedScalingModeID) {
                        selectedScenarioFilter = nil
                        isAdvancedChainExpanded = true
                        coordinator.selectedScalingModeID = copy.id
                    }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help(l10n.tr("Duplicate as Custom Mode", "复制为自定义模式"))

                Button {
                    coordinator.deleteScalingMode(id: coordinator.selectedScalingModeID)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(selectedMode?.isBuiltIn ?? true)
                .help(l10n.tr("Delete Custom Mode", "删除自定义模式"))

                Spacer()

                Button(l10n.tr("Import", "导入")) {
                    importScalingModesJSON(l10n: l10n)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button(l10n.tr("Export", "导出")) {
                    exportSelectedModeJSON(l10n: l10n)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .padding(10)
        }
        .background(.background)
    }

    private func scenarioFilterChip(
        title: String,
        symbol: String?,
        tag: ScenarioTag?,
        fillWidth: Bool = true
    ) -> some View {
        let isSelected = selectedScenarioFilter == tag
        return Button {
            selectedScenarioFilter = tag
        } label: {
            HStack(spacing: 3.5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .padding(.horizontal, fillWidth ? 6 : 9)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func modeListRow(_ mode: ScalingMode, l10n: L10n) -> some View {
        let isDefaultActive = coordinator.config.defaultProfile.scalingModeID == mode.id
        let subtitle = l10n.builtInModeDescription(mode)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(l10n.builtInModeName(mode))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if isDefaultActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Mode Header

    private func modeHeaderBar(mode: ScalingMode, l10n: L10n) -> some View {
        let isDefaultMode = coordinator.config.defaultProfile.scalingModeID == mode.id

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if mode.isBuiltIn {
                    HStack(spacing: 8) {
                        Text(l10n.builtInModeName(mode))
                            .font(.system(size: 17.5, weight: .bold))
                            .lineLimit(2)
                        StatusBadge(l10n.scenarioTag(mode.scenario), color: .blue, symbol: mode.scenario.symbolName)
                    }
                    Text(l10n.builtInModeDescription(mode))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField(
                        l10n.tr("Custom Mode Name", "自定义模式名称"),
                        text: Binding(
                            get: { mode.name },
                            set: { newName in
                                coordinator.updateScalingMode(id: mode.id) { $0.name = newName }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 320)

                    TextField(
                        l10n.tr("Notes (when to use this mode)", "简短说明（什么时候用它）"),
                        text: Binding(
                            get: { mode.localizedDescription },
                            set: { newDesc in
                                coordinator.updateScalingMode(id: mode.id) { $0.localizedDescription = newDesc }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 420)
                }
            }

            Spacer(minLength: 6)

            if isDefaultMode {
                StatusBadge(l10n.tr("Default Mode", "当前默认模式"), color: .green, symbol: "checkmark.circle.fill")
            } else {
                Button {
                    coordinator.updateDefaultProfile { $0.scalingModeID = mode.id }
                    coordinator.showToast(
                        icon: "checkmark.circle.fill",
                        title: l10n.tr("Set as Default Mode", "已设为默认缩放模式"),
                        subtitle: l10n.builtInModeName(mode),
                        style: .success
                    )
                } label: {
                    Label(l10n.tr("Use This Mode", "设为默认模式"), systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Live Metal GPU Before/After Split Preview

    private func liveMetalPreviewCard(mode: ScalingMode, l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Live Before / After Preview", "实时画质对比预览"),
            subtitle: l10n.tr(
                "Drag the divider to compare Original (left) vs Upscaled GPU output (right).",
                "左右拖动中间滑块，实时对比左侧「原画」与右侧「放大后」的实际效果。"
            ),
            symbol: "rectangle.split.2x1.fill",
            accent: .cyan
        ) {
            // Preview Toolbar (compact min widths so right pane never overflows horizontally in English or Chinese)
            HStack(spacing: 6) {
                Picker("", selection: $selectedScene) {
                    ForEach(PreviewSampleScene.allCases) { scene in
                        Text(scene.title(l10n)).tag(scene)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 116, maxWidth: 175)

                HStack(spacing: 4) {
                    Button {
                        loadCustomPreviewImage(mode: mode)
                    } label: {
                        Label(
                            customSourceName ?? l10n.tr("Image…", "选本地图片…"),
                            systemImage: "photo.badge.plus"
                        )
                        .lineLimit(1)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: 118)

                    if customSourceImage != nil {
                        Button {
                            customSourceImage = nil
                            customSourceName = nil
                            schedulePreviewRender(for: mode, debounce: false)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(l10n.tr("Back to Built-In Sample", "恢复示例图片"))
                    }
                }

                Spacer(minLength: 4)

                // Zoom selector (1x / 2x / 4x)
                Picker("", selection: $zoomLevel) {
                    Text("1×").tag(CGFloat(1.0))
                    Text("2×").tag(CGFloat(2.0))
                    Text("4×").tag(CGFloat(4.0))
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 96)

                // Real GPU Render Time Badge
                if isRenderingPreview {
                    ProgressView()
                        .controlSize(.small)
                } else if let ms = previewRenderMs {
                    StatusBadge(
                        String(format: "%.2f ms", ms),
                        color: ms < 3.0 ? .green : .orange,
                        symbol: "bolt.fill"
                    )
                }
            }

            if let previewError {
                Text(previewError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }

            // Interactive Split-Curtain Canvas
            GeometryReader { geo in
                let canvasW = max(1, geo.size.width)
                let canvasH = max(1, geo.size.height)
                let dividerX = canvasW * splitRatio

                ZStack {
                    Color.black

                    // Right side (full background): Real Metal GPU rendered output
                    if let rendered = renderedDisplayImage {
                        Image(nsImage: rendered)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fill)
                            .scaleEffect(zoomLevel)
                            .frame(width: canvasW, height: canvasH)
                            .clipped()
                    }

                    // Left side (clipped to dividerX): Original input
                    if let original = originalDisplayImage {
                        Image(nsImage: original)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fill)
                            .scaleEffect(zoomLevel)
                            .frame(width: canvasW, height: canvasH)
                            .clipped()
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: max(0, dividerX), height: canvasH)
                            }
                    }

                    // Corner Labels
                    VStack {
                        HStack {
                            Text(verbatim: "\(l10n.tr("ORIGINAL", "原画")) (\(previewSourceSize.width)×\(previewSourceSize.height))")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(Color.black.opacity(0.68), in: Capsule())

                            Spacer()

                            Text(verbatim: "\(l10n.tr("UPSCALED", "放大后")) (\(previewOutputSize.width)×\(previewOutputSize.height))")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(Color.black.opacity(0.72), in: Capsule())
                        }
                        .padding(10)
                        Spacer()
                    }

                    // Draggable Vertical Split Curtain Handle
                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: 2, height: canvasH)
                            .shadow(color: .black.opacity(0.65), radius: 3)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 28, height: 28)
                            .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
                            .overlay {
                                Image(systemName: "arrow.left.and.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.black)
                            }
                    }
                    .position(x: dividerX, y: canvasH * 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clamped = min(max(value.location.x / canvasW, 0.04), 0.96)
                            splitRatio = clamped
                        }
                )
            }
            .frame(height: 268)
        }
    }

    // MARK: - Beginner-Friendly Quality Tuning Card

    @ViewBuilder
    private func simpleQualityTuningCard(mode: ScalingMode, l10n: L10n) -> some View {
        if Self.officialAnime4KIDs.contains(mode.id) {
            anime4KSimpleTuningCard(mode: mode, l10n: l10n)
        } else {
            let tunablePasses: [(instance: EffectInstance, descriptor: EffectDescriptor)] = mode.effects.compactMap { eff in
                guard eff.enabled else { return nil }
                let desc = EffectCatalog.descriptor(for: eff.effectID)
                guard !desc.parameters.isEmpty else { return nil }
                return (eff, desc)
            }

            SectionCard(
                title: l10n.tr("Quality Tuning", "画质微调"),
                subtitle: l10n.tr(
                    "Adjust key look & sharpness options — preview updates in real time.",
                    "常用画质选项已为你整理好，拖动滑块即可在上方实时看到变化。"
                ),
                symbol: "slider.horizontal.3",
                accent: .blue
            ) {
                if tunablePasses.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(l10n.tr(
                            "This mode works great out of the box with no manual tuning required.",
                            "此模式已按最佳效果预设好，无需手动调参，直接开启即可。"
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tunablePasses, id: \.instance.id) { item in
                            if tunablePasses.count > 1 {
                                Text(l10n.effectName(item.descriptor))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(item.descriptor.parameters) { param in
                                VStack(alignment: .leading, spacing: 2) {
                                    parameterControlRow(
                                        modeID: mode.id,
                                        instance: item.instance,
                                        param: param,
                                        l10n: l10n
                                    )
                                    let descText = l10n.parameterDescription(param)
                                    if !descText.isEmpty {
                                        Text(descText)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, 158)
                                    }
                                }
                            }
                        }

                        if mode.isBuiltIn {
                            HStack {
                                Spacer()
                                Button {
                                    resetBuiltInModeToDefaults(mode)
                                } label: {
                                    Label(l10n.tr("Reset to Preset Default", "恢复预设默认"), systemImage: "arrow.counterclockwise")
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Ultra-clean 2-control card for the 6 Official Anime4K modes (`画质档位` + `抑制白边`).
    private func anime4KSimpleTuningCard(mode: ScalingMode, l10n: L10n) -> some View {
        let currentTier = currentAnime4KTier(for: mode)
        let clampEnabled = currentAnime4KClampHighlights(for: mode)

        return SectionCard(
            title: l10n.tr("Anime4K Quality Tuning", "画质微调（Anime4K 官方模式）"),
            subtitle: l10n.tr(
                "Pick a quality tier and halo protection — MetalPie handles the official multi-pass recipe automatically.",
                "官方模式已经配置好完整处理流程，平时只需选择画质档位与是否抑制白边即可。"
            ),
            symbol: "sparkles",
            accent: .purple
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(l10n.tr("Quality Tier", "画质档位"))
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 84, alignment: .leading)

                    Picker("", selection: Binding<String>(
                        get: { currentTier },
                        set: { newTier in
                            applyAnime4KTier(newTier, to: mode)
                        }
                    )) {
                        Text(l10n.tr("Fast (S)", "轻量 (S)")).tag("S")
                        Text(l10n.tr("Balanced (M)", "标准 (M)")).tag("M")
                        Text(l10n.tr("High (L)", "高画质 (L)")).tag("L")
                        Text(l10n.tr("Ultra (VL)", "超高 (VL)")).tag("VL")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)

                    Spacer(minLength: 0)
                }

                Toggle(isOn: Binding<Bool>(
                    get: { clampEnabled },
                    set: { enabled in
                        applyAnime4KClampHighlights(enabled, to: mode)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("Reduce White Edge Halos (Clamp Highlights)", "抑制白边光晕"))
                            .font(.system(size: 12.5, weight: .medium))
                        Text(l10n.tr(
                            "Prevents bright white ringing outlines around dark anime ink lines (recommended ON).",
                            "防止人物黑边与发丝外侧出现刺眼的白色亮边，建议保持开启。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text(l10n.tr(
                        "Tip: Mode A is best for most 1080p anime; Mode B is softer for 720p; Mode C is cleanest for Blu-ray.",
                        "小提示：大多数番剧选 Mode A；720p 或柔和画风选 Mode B；高清原盘选 Mode C；片源偏糊可选 A+A / B+B。"
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        resetBuiltInModeToDefaults(mode)
                    } label: {
                        Label(l10n.tr("Reset", "恢复默认"), systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func currentAnime4KTier(for mode: ScalingMode) -> String {
        // Inspect the primary upscaling pass (or first restore pass) to normalize S / M / L / VL.
        let primary = mode.effects.first(where: {
            $0.effectID == .anime4kUpscale || $0.effectID == .anime4kUpscaleDenoise
        }) ?? mode.effects.first(where: { $0.effectID == .anime4kRestore })

        let raw = primary?.parameters.choice("variant", default: "L") ?? "L"
        switch raw {
        case "S": return "S"
        case "M", "softM": return "M"
        case "VL": return "VL"
        default: return "L"
        }
    }

    private func currentAnime4KClampHighlights(for mode: ScalingMode) -> Bool {
        if let clampPass = mode.effects.first(where: { $0.effectID == .anime4kClampHighlights }) {
            return clampPass.enabled
        }
        if let first = mode.effects.first(where: {
            $0.effectID == .anime4kRestore || $0.effectID == .anime4kUpscale || $0.effectID == .anime4kUpscaleDenoise
        }) {
            return first.parameters.bool("clampHighlights", default: true)
        }
        return true
    }

    private func applyAnime4KTier(_ tier: String, to mode: ScalingMode) {
        let isSoftMode = (mode.id == ScalingMode.anime4kModeBID || mode.id == ScalingMode.anime4kModeBBID)
        let secondaryRestoreTier: String = {
            switch tier {
            case "S": return "S"
            case "M": return isSoftMode ? "softM" : "M"
            case "L": return isSoftMode ? "softM" : "M"
            case "VL": return isSoftMode ? "softL" : "L"
            default: return isSoftMode ? "softM" : "M"
            }
        }()
        let primaryRestoreTier: String = {
            switch tier {
            case "S": return "S"
            case "M": return isSoftMode ? "softM" : "M"
            case "L": return isSoftMode ? "softL" : "L"
            case "VL": return "VL"
            default: return isSoftMode ? "softL" : "L"
            }
        }()

        coordinator.updateScalingMode(id: mode.id) { m in
            var seenUpscale = false
            for idx in m.effects.indices {
                switch m.effects[idx].effectID {
                case .anime4kUpscale, .anime4kUpscaleDenoise:
                    seenUpscale = true
                    m.effects[idx].parameters["variant"] = .choice(tier)
                case .anime4kRestore:
                    m.effects[idx].parameters["variant"] = .choice(seenUpscale ? secondaryRestoreTier : primaryRestoreTier)
                default:
                    break
                }
            }
        }
    }

    private func applyAnime4KClampHighlights(_ enabled: Bool, to mode: ScalingMode) {
        coordinator.updateScalingMode(id: mode.id) { m in
            for idx in m.effects.indices {
                switch m.effects[idx].effectID {
                case .anime4kClampHighlights:
                    m.effects[idx].enabled = enabled
                case .anime4kRestore, .anime4kUpscale, .anime4kUpscaleDenoise:
                    m.effects[idx].parameters["clampHighlights"] = .bool(enabled)
                default:
                    break
                }
            }
        }
    }

    private func resetBuiltInModeToDefaults(_ mode: ScalingMode) {
        guard let canonical = ScalingMode.builtInPresets.first(where: { $0.id == mode.id }) else { return }
        coordinator.updateScalingMode(id: mode.id) { m in
            m.effects = canonical.effects
        }
    }

    // MARK: - Collapsible Advanced Multi-Pass Effect Chain

    private func advancedEffectChainSection(mode: ScalingMode, l10n: L10n) -> some View {
        SectionCard {
            DisclosureGroup(isExpanded: $isAdvancedChainExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n.tr(
                        "Combine any of MetalPie's 30 GPU shaders in sequence. Effects run from top to bottom.",
                        "进阶玩家可在此自由增删、排序全部 30 种画质算法，并设置每个步骤的缩放方式与细节参数。"
                    ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                    // Add Effect Grouped Menu (All 30 EffectIDs grouped by all 9 categories)
                    HStack {
                        Menu {
                            ForEach(EffectCategory.allCases) { category in
                                let items = EffectCatalog.effects(in: category)
                                if !items.isEmpty {
                                    Menu(l10n.effectCategory(category)) {
                                        ForEach(items) { desc in
                                            Button {
                                                addEffect(desc.id, to: mode.id)
                                            } label: {
                                                Text(l10n.effectName(desc))
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label(l10n.tr("Add Effect", "添加画质效果"), systemImage: "plus.circle.fill")
                        }
                        .menuStyle(.borderedButton)
                        .fixedSize()

                        Spacer()

                        if mode.isBuiltIn {
                            Button {
                                resetBuiltInModeToDefaults(mode)
                            } label: {
                                Label(l10n.tr("Reset Preset Chain", "还原内置效果链"), systemImage: "arrow.counterclockwise")
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }

                        Text("\(mode.effects.count) \(l10n.tr("step(s)", "个步骤"))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    if mode.effects.isEmpty {
                        VStack(spacing: 6) {
                            Text(l10n.tr("No effects added — smooth Bicubic scaling will be used automatically.", "效果链为空 — 将自动使用平滑双三次缩放。"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(Array(mode.effects.enumerated()), id: \.element.id) { index, instance in
                                effectInstanceCard(
                                    modeID: mode.id,
                                    instance: instance,
                                    index: index,
                                    totalCount: mode.effects.count,
                                    l10n: l10n
                                )
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.down.right.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.indigo)
                        .frame(width: 22, height: 22)
                        .background(Color.indigo.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("Custom Effect Chain (Advanced)", "自定义效果链（进阶）"))
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(l10n.tr(
                            "\(mode.effects.filter(\.enabled).count) active pass(es) • Expand to edit individual shaders",
                            "当前包含 \(mode.effects.filter(\.enabled).count) 个步骤 • 展开可自由组合全部 30 种着色器"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func effectInstanceCard(
        modeID: UUID,
        instance: EffectInstance,
        index: Int,
        totalCount: Int,
        l10n: L10n
    ) -> some View {
        let desc = EffectCatalog.descriptor(for: instance.effectID)

        return VStack(alignment: .leading, spacing: 10) {
            // Top bar: Order #, Enable Toggle, Effect Name, Category/HDR badges, Move Up/Down, Reset, Remove
            HStack(spacing: 8) {
                Text("#\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                Toggle("", isOn: Binding(
                    get: { instance.enabled },
                    set: { enabled in
                        mutateEffect(modeID: modeID, effectInstanceID: instance.id) { $0.enabled = enabled }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.effectName(desc))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        StatusBadge(l10n.effectCategory(desc.category), color: .secondary)
                        if desc.supportsHDR {
                            StatusBadge("HDR", color: .orange)
                        }
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 4) {
                    Button {
                        moveEffect(modeID: modeID, from: index, to: index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(index == 0)

                    Button {
                        moveEffect(modeID: modeID, from: index, to: index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(index >= totalCount - 1)

                    if !desc.parameters.isEmpty {
                        Button {
                            mutateEffect(modeID: modeID, effectInstanceID: instance.id) {
                                $0.parameters = desc.defaultParameters
                            }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help(l10n.tr("Reset Parameters", "恢复默认参数"))
                    }

                    Button {
                        removeEffect(modeID: modeID, effectInstanceID: instance.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help(l10n.tr("Remove Effect", "移除此步骤"))
                }
            }

            Text(l10n.effectSummary(desc))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if desc.scaleCapability != .sameSize {
                HStack(spacing: 12) {
                    Picker(l10n.tr("Scaling Mode", "缩放方式"), selection: Binding(
                        get: { instance.scalingType },
                        set: { newType in
                            mutateEffect(modeID: modeID, effectInstanceID: instance.id) { $0.scalingType = newType }
                        }
                    )) {
                        ForEach(ScalingType.allCases) { st in
                            Text(l10n.scalingType(st)).tag(st)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 230)

                    if instance.scalingType == .normal || instance.scalingType == .fit {
                        HStack(spacing: 4) {
                            Text("X:")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField(
                                "1.0",
                                value: Binding(
                                    get: { instance.scaleFactorX },
                                    set: { val in
                                        mutateEffect(modeID: modeID, effectInstanceID: instance.id) {
                                            $0.scaleFactorX = max(0.1, min(val, 8.0))
                                        }
                                    }
                                ),
                                format: .number.precision(.fractionLength(0...2))
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)

                            Text("Y:")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField(
                                "1.0",
                                value: Binding(
                                    get: { instance.scaleFactorY },
                                    set: { val in
                                        mutateEffect(modeID: modeID, effectInstanceID: instance.id) {
                                            $0.scaleFactorY = max(0.1, min(val, 8.0))
                                        }
                                    }
                                ),
                                format: .number.precision(.fractionLength(0...2))
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        }
                    } else if instance.scalingType == .absolute {
                        HStack(spacing: 4) {
                            Text("W:")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField(
                                "2560",
                                value: Binding(
                                    get: { instance.absoluteWidth ?? 2560 },
                                    set: { val in
                                        mutateEffect(modeID: modeID, effectInstanceID: instance.id) {
                                            $0.absoluteWidth = max(64, val)
                                        }
                                    }
                                ),
                                format: .number
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)

                            Text("H:")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField(
                                "1440",
                                value: Binding(
                                    get: { instance.absoluteHeight ?? 1440 },
                                    set: { val in
                                        mutateEffect(modeID: modeID, effectInstanceID: instance.id) {
                                            $0.absoluteHeight = max(64, val)
                                        }
                                    }
                                ),
                                format: .number
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                        }
                    }

                    Spacer()
                }
            }

            if !desc.parameters.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(desc.parameters) { param in
                        parameterControlRow(
                            modeID: modeID,
                            instance: instance,
                            param: param,
                            l10n: l10n
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(instance.enabled ? 0.04 : 0.02), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .opacity(instance.enabled ? 1.0 : 0.65)
    }

    @ViewBuilder
    private func parameterControlRow(
        modeID: UUID,
        instance: EffectInstance,
        param: EffectParameterDescriptor,
        l10n: L10n
    ) -> some View {
        switch param.kind {
        case .float(let defaultVal, let minVal, let maxVal, let stepVal):
            let value = instance.parameters.float(param.id, default: defaultVal)
            HStack(spacing: 10) {
                Text(l10n.parameterLabel(param))
                    .font(.system(size: 12))
                    .frame(width: 148, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { value },
                        set: { newVal in
                            let snapped = (newVal / max(stepVal, 1e-6)).rounded() * max(stepVal, 1e-6)
                            mutateEffect(modeID: modeID, effectInstanceID: instance.id) {
                                $0.parameters[param.id] = .float(snapped)
                            }
                        }
                    ),
                    in: minVal...maxVal
                )
                Text(String(format: stepVal < 0.01 ? "%.3f" : "%.2f", value))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }

        case .int(let defaultVal, let minVal, let maxVal, let stepVal):
            let value = instance.parameters.int(param.id, default: defaultVal)
            HStack(spacing: 10) {
                Text(l10n.parameterLabel(param))
                    .font(.system(size: 12))
                    .frame(width: 148, alignment: .leading)
                Stepper(
                    value: Binding(
                        get: { value },
                        set: { newVal in
                            mutateEffect(modeID: modeID, effectInstanceID: instance.id) {
                                $0.parameters[param.id] = .int(newVal)
                            }
                        }
                    ),
                    in: minVal...maxVal,
                    step: max(1, stepVal)
                ) {
                    Text("\(value)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                Spacer()
            }

        case .bool(let defaultVal):
            let value = instance.parameters.bool(param.id, default: defaultVal)
            Toggle(
                l10n.parameterLabel(param),
                isOn: Binding(
                    get: { value },
                    set: { newVal in
                        mutateEffect(modeID: modeID, effectInstanceID: instance.id) {
                            $0.parameters[param.id] = .bool(newVal)
                        }
                    }
                )
            )
            .font(.system(size: 12))

        case .choice(let defaultVal, let options):
            let value = instance.parameters.choice(param.id, default: defaultVal)
            HStack(spacing: 10) {
                Text(l10n.parameterLabel(param))
                    .font(.system(size: 12))
                    .frame(width: 148, alignment: .leading)
                Picker("", selection: Binding(
                    get: { value },
                    set: { newVal in
                        mutateEffect(modeID: modeID, effectInstanceID: instance.id) {
                            $0.parameters[param.id] = .choice(newVal)
                        }
                    }
                )) {
                    ForEach(options, id: \.value) { opt in
                        Text(l10n.parameterChoiceLabel(opt)).tag(opt.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 230)
                Spacer()
            }
        }
    }

    // MARK: - Effect Mutations & Live Preview Rendering

    private func addEffect(_ effectID: EffectID, to modeID: UUID) {
        let desc = EffectCatalog.descriptor(for: effectID)
        let defaultType: ScalingType = (desc.scaleCapability == .sameSize) ? .normal : .fit
        let instance = EffectInstance(effectID: effectID, scalingType: defaultType)
        coordinator.updateScalingMode(id: modeID) { mode in
            mode.effects.append(instance)
        }
    }

    private func mutateEffect(
        modeID: UUID,
        effectInstanceID: UUID,
        _ mutate: (inout EffectInstance) -> Void
    ) {
        coordinator.updateScalingMode(id: modeID) { mode in
            if let idx = mode.effects.firstIndex(where: { $0.id == effectInstanceID }) {
                mutate(&mode.effects[idx])
            }
        }
    }

    private func moveEffect(modeID: UUID, from: Int, to: Int) {
        coordinator.updateScalingMode(id: modeID) { mode in
            guard mode.effects.indices.contains(from),
                  mode.effects.indices.contains(to)
            else { return }
            let item = mode.effects.remove(at: from)
            mode.effects.insert(item, at: to)
        }
    }

    private func removeEffect(modeID: UUID, effectInstanceID: UUID) {
        coordinator.updateScalingMode(id: modeID) { mode in
            mode.effects.removeAll { $0.id == effectInstanceID }
        }
    }

    private func schedulePreviewRender(for mode: ScalingMode, debounce: Bool = false) {
        renderTask?.cancel()
        coordinator.isPreviewReadyForSnapshot = false
        let srcCG = customSourceImage ?? PreviewSampleGenerator.sampleImage(for: selectedScene)
        let srcSize = PixelSize(width: srcCG.width, height: srcCG.height)
        let outSize = PixelSize(width: max(2, srcCG.width * 2), height: max(2, srcCG.height * 2))
        previewSourceSize = srcSize
        previewOutputSize = outSize

        if let crispOrig = PreviewSampleGenerator.resizeCGImage(
            srcCG,
            width: outSize.width,
            height: outSize.height,
            interpolation: .none
        ) {
            originalDisplayImage = NSImage(
                cgImage: crispOrig,
                size: NSSize(width: outSize.width, height: outSize.height)
            )
        }

        renderTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            isRenderingPreview = true
            previewError = nil
            defer { isRenderingPreview = false }
            do {
                let (renderedCG, elapsedMs) = try await coordinator.renderPreview(
                    sourceImage: srcCG,
                    scalingMode: mode,
                    outputSize: outSize
                )
                if Task.isCancelled { return }
                renderedDisplayImage = NSImage(
                    cgImage: renderedCG,
                    size: NSSize(width: renderedCG.width, height: renderedCG.height)
                )
                previewRenderMs = elapsedMs
                coordinator.isPreviewReadyForSnapshot = true
            } catch {
                if !Task.isCancelled {
                    previewError = error.localizedDescription
                }
            }
        }
    }

    private func loadCustomPreviewImage(mode: ScalingMode) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let loaded = PreviewSampleGenerator.loadUserImage(from: url)
        {
            customSourceImage = loaded
            customSourceName = url.lastPathComponent
            schedulePreviewRender(for: mode, debounce: false)
        }
    }

    private func importScalingModesJSON(l10n: L10n) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let imported = try coordinator.importScalingModes(from: data)
                selectedScenarioFilter = nil
                isAdvancedChainExpanded = true
                coordinator.showToast(
                    icon: "square.and.arrow.down.fill",
                    title: l10n.tr("Imported \(imported.count) Scaling Mode(s)", "已导入 \(imported.count) 个缩放模式"),
                    style: .success
                )
            } catch {
                coordinator.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func exportSelectedModeJSON(l10n: L10n) {
        guard let mode = selectedMode else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(mode.name.replacingOccurrences(of: " ", with: "_")).json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try coordinator.exportScalingModes(ids: [mode.id])
                try data.write(to: url, options: [.atomic])
                coordinator.showToast(
                    icon: "square.and.arrow.up.fill",
                    title: l10n.tr("Exported Scaling Mode", "已导出缩放模式"),
                    subtitle: url.lastPathComponent,
                    style: .success
                )
            } catch {
                coordinator.lastErrorMessage = error.localizedDescription
            }
        }
    }
}
