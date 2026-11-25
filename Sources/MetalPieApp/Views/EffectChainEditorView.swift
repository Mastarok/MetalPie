import AppKit
import MetalPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Scaling Modes workspace (`缩放模式` / `Scaling Modes`):
/// - Left column: Scenario filter chips and single-line preset list
/// - Right top: Live Metal GPU before/after split preview
/// - Right middle: Clean parameter controls (tooltips for technical notes)
/// - Right bottom: Collapsible `效果链 (N)` multi-pass editor
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
            modesSidebar(l10n: l10n)
                .frame(minWidth: 215, idealWidth: 236, maxWidth: 280)

            if let mode = selectedMode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        modeHeaderBar(mode: mode, l10n: l10n)
                        liveMetalPreviewCard(mode: mode, l10n: l10n)
                        parametersCard(mode: mode, l10n: l10n)
                        effectChainSection(mode: mode, l10n: l10n)
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
                    l10n.tr("No Mode Selected", "未选择模式"),
                    systemImage: "sparkles.rectangle.stack"
                )
            }
        }
    }

    // MARK: - Left Column: Preset List

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
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(l10n.tr("New Mode", "新建模式"))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Compact Scenario Filter Row
            HStack(spacing: 4) {
                scenarioFilterChip(title: l10n.tr("All", "全部"), tag: nil)
                ForEach(ScenarioTag.allCases) { tag in
                    scenarioFilterChip(title: l10n.scenarioTag(tag), tag: tag)
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
                    Section(l10n.tr("Custom", "自定义")) {
                        ForEach(customModes) { mode in
                            modeListRow(mode, l10n: l10n)
                                .tag(mode.id)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

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
                .help(l10n.tr("Duplicate", "复制"))

                Button {
                    coordinator.deleteScalingMode(id: coordinator.selectedScalingModeID)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(selectedMode?.isBuiltIn ?? true)
                .help(l10n.tr("Delete", "删除"))

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

    private func scenarioFilterChip(title: String, tag: ScenarioTag?) -> some View {
        let isSelected = selectedScenarioFilter == tag
        return Button {
            selectedScenarioFilter = tag
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func modeListRow(_ mode: ScalingMode, l10n: L10n) -> some View {
        let isDefaultActive = coordinator.config.defaultProfile.scalingModeID == mode.id

        return HStack(spacing: 6) {
            Text(l10n.builtInModeName(mode))
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if isDefaultActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 1.5)
    }

    // MARK: - Detail Header

    private func modeHeaderBar(mode: ScalingMode, l10n: L10n) -> some View {
        let isDefaultMode = coordinator.config.defaultProfile.scalingModeID == mode.id
        let desc = l10n.builtInModeDescription(mode)

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if mode.isBuiltIn {
                    HStack(spacing: 8) {
                        Text(l10n.builtInModeName(mode))
                            .font(.system(size: 18, weight: .bold))
                            .lineLimit(1)
                        StatusBadge(l10n.scenarioTag(mode.scenario), color: .blue)
                    }
                    if !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    TextField(
                        l10n.tr("Mode Name", "名称"),
                        text: Binding(
                            get: { mode.name },
                            set: { newName in
                                coordinator.updateScalingMode(id: mode.id) { $0.name = newName }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 300)

                    TextField(
                        l10n.tr("Description", "备注"),
                        text: Binding(
                            get: { mode.localizedDescription },
                            set: { newDesc in
                                coordinator.updateScalingMode(id: mode.id) { $0.localizedDescription = newDesc }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 380)
                }
            }

            Spacer(minLength: 6)

            if isDefaultMode {
                StatusBadge(l10n.tr("Default", "默认"), color: .green, symbol: "checkmark")
            } else {
                Button(l10n.tr("Set Default", "设为默认")) {
                    coordinator.updateDefaultProfile { $0.scalingModeID = mode.id }
                    coordinator.showToast(
                        icon: "checkmark.circle.fill",
                        title: l10n.tr("Default Mode Updated", "已设为默认"),
                        subtitle: l10n.builtInModeName(mode),
                        style: .success
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Live Metal Preview

    private func liveMetalPreviewCard(mode: ScalingMode, l10n: L10n) -> some View {
        SectionCard {
            HStack(spacing: 8) {
                Text(l10n.tr("Live Preview", "实时预览"))
                    .font(.system(size: 13, weight: .semibold))

                Picker("", selection: $selectedScene) {
                    ForEach(PreviewSampleScene.allCases) { scene in
                        Text(scene.title(l10n)).tag(scene)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 108, maxWidth: 148)

                HStack(spacing: 4) {
                    Button(customSourceName ?? l10n.tr("Open Image…", "打开图片…")) {
                        loadCustomPreviewImage(mode: mode)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .lineLimit(1)
                    .frame(maxWidth: 120)

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
                        .help(l10n.tr("Reset Sample", "恢复示例"))
                    }
                }

                Spacer(minLength: 4)

                Picker("", selection: $zoomLevel) {
                    Text("1×").tag(CGFloat(1.0))
                    Text("2×").tag(CGFloat(2.0))
                    Text("4×").tag(CGFloat(4.0))
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 96)

                if isRenderingPreview {
                    ProgressView()
                        .controlSize(.small)
                } else if let ms = previewRenderMs {
                    Text(String(format: "%.1f ms", ms))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(ms < 3.0 ? .green : .orange)
                }
            }

            if let previewError {
                Text(previewError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }

            GeometryReader { geo in
                let canvasW = max(1, geo.size.width)
                let canvasH = max(1, geo.size.height)
                let dividerX = canvasW * splitRatio

                ZStack {
                    Color.black

                    if let rendered = renderedDisplayImage {
                        Image(nsImage: rendered)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fill)
                            .scaleEffect(zoomLevel)
                            .frame(width: canvasW, height: canvasH)
                            .clipped()
                    }

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

                    VStack {
                        HStack {
                            Text(verbatim: "\(l10n.tr("Original", "原画")) \(previewSourceSize.width)×\(previewSourceSize.height)")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.66), in: Capsule())

                            Spacer()

                            Text(verbatim: "\(l10n.tr("Scaled", "缩放后")) \(previewOutputSize.width)×\(previewOutputSize.height)")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.72), in: Capsule())
                        }
                        .padding(10)
                        Spacer()
                    }

                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: 2, height: canvasH)
                            .shadow(color: .black.opacity(0.65), radius: 3)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 26, height: 26)
                            .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
                            .overlay {
                                Image(systemName: "arrow.left.and.right")
                                    .font(.system(size: 10.5, weight: .bold))
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
                            splitRatio = min(max(value.location.x / canvasW, 0.04), 0.96)
                        }
                )
            }
            .frame(height: 272)
        }
    }

    // MARK: - Parameters Card

    @ViewBuilder
    private func parametersCard(mode: ScalingMode, l10n: L10n) -> some View {
        if Self.officialAnime4KIDs.contains(mode.id) {
            anime4KParametersCard(mode: mode, l10n: l10n)
        } else {
            let tunablePasses: [(instance: EffectInstance, descriptor: EffectDescriptor)] = mode.effects.compactMap { eff in
                guard eff.enabled else { return nil }
                let desc = EffectCatalog.descriptor(for: eff.effectID)
                guard !desc.parameters.isEmpty else { return nil }
                return (eff, desc)
            }

            if !tunablePasses.isEmpty {
                SectionCard {
                    HStack {
                        Text(l10n.tr("Parameters", "参数"))
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if mode.isBuiltIn {
                            Button(l10n.tr("Reset", "重置")) {
                                resetBuiltInModeToDefaults(mode)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(tunablePasses, id: \.instance.id) { item in
                            if tunablePasses.count > 1 {
                                Text(l10n.effectName(item.descriptor))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(item.descriptor.parameters) { param in
                                parameterControlRow(
                                    modeID: mode.id,
                                    instance: item.instance,
                                    param: param,
                                    l10n: l10n
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func anime4KParametersCard(mode: ScalingMode, l10n: L10n) -> some View {
        let currentTier = currentAnime4KTier(for: mode)
        let clampEnabled = currentAnime4KClampHighlights(for: mode)

        return SectionCard {
            HStack {
                Text(l10n.tr("Parameters", "参数"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(l10n.tr("Reset", "重置")) {
                    resetBuiltInModeToDefaults(mode)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(l10n.tr("Quality", "画质"))
                        .font(.system(size: 12.5))
                        .frame(width: 110, alignment: .leading)

                    Picker("", selection: Binding<String>(
                        get: { currentTier },
                        set: { newTier in
                            applyAnime4KTier(newTier, to: mode)
                        }
                    )) {
                        Text("S").tag("S")
                        Text("M").tag("M")
                        Text("L").tag("L")
                        Text("VL").tag("VL")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)

                    Spacer(minLength: 0)
                }
                .help(l10n.tr("CNN model size: S (fastest) to VL (highest quality).", "神经网络规模：S 最快，VL 画质最高"))

                Toggle(
                    l10n.tr("Clamp Highlights", "高光钳位"),
                    isOn: Binding<Bool>(
                        get: { clampEnabled },
                        set: { enabled in
                            applyAnime4KClampHighlights(enabled, to: mode)
                        }
                    )
                )
                .font(.system(size: 12.5))
                .help(l10n.tr(
                    "Prevents bright ringing halos around dark outlines.",
                    "抑制暗色轮廓周围的亮边光晕"
                ))
            }
        }
    }

    private func currentAnime4KTier(for mode: ScalingMode) -> String {
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

    // MARK: - Collapsible Effect Chain

    private func effectChainSection(mode: ScalingMode, l10n: L10n) -> some View {
        SectionCard {
            DisclosureGroup(isExpanded: $isAdvancedChainExpanded) {
                VStack(alignment: .leading, spacing: 10) {
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
                            Label(l10n.tr("Add Effect", "添加效果"), systemImage: "plus")
                        }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)
                        .fixedSize()

                        Spacer()

                        if mode.isBuiltIn {
                            Button(l10n.tr("Reset", "重置")) {
                                resetBuiltInModeToDefaults(mode)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 6)

                    if mode.effects.isEmpty {
                        Text(l10n.tr("Empty chain (defaults to Bicubic).", "效果链为空（默认双三次）"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        VStack(spacing: 8) {
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
                Text(l10n.tr("Effect Chain (\(mode.effects.count))", "效果链 (\(mode.effects.count))"))
                    .font(.system(size: 13, weight: .semibold))
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

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("#\(index + 1)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                Toggle("", isOn: Binding(
                    get: { instance.enabled },
                    set: { enabled in
                        mutateEffect(modeID: modeID, effectInstanceID: instance.id) { $0.enabled = enabled }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

                Text(l10n.effectName(desc))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .help(l10n.effectSummary(desc))

                if desc.supportsHDR {
                    StatusBadge("HDR", color: .orange)
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
                        .help(l10n.tr("Reset Parameters", "重置参数"))
                    }

                    Button {
                        removeEffect(modeID: modeID, effectInstanceID: instance.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help(l10n.tr("Remove", "移除"))
                }
            }

            if desc.scaleCapability != .sameSize {
                HStack(spacing: 10) {
                    Picker(l10n.tr("Scaling", "缩放"), selection: Binding(
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
                    .frame(maxWidth: 190)

                    if instance.scalingType == .normal || instance.scalingType == .fit {
                        HStack(spacing: 4) {
                            Text("X")
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
                            .frame(width: 54)

                            Text("Y")
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
                            .frame(width: 54)
                        }
                    } else if instance.scalingType == .absolute {
                        HStack(spacing: 4) {
                            Text("W")
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
                            .frame(width: 68)

                            Text("H")
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
                            .frame(width: 68)
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
        .padding(10)
        .background(Color.primary.opacity(instance.enabled ? 0.04 : 0.02), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
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
        let tooltip = l10n.parameterDescription(param)

        switch param.kind {
        case .float(let defaultVal, let minVal, let maxVal, let stepVal):
            let value = instance.parameters.float(param.id, default: defaultVal)
            HStack(spacing: 10) {
                Text(l10n.parameterLabel(param))
                    .font(.system(size: 12))
                    .frame(width: 120, alignment: .leading)
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
                    .frame(width: 50, alignment: .trailing)
            }
            .help(tooltip)

        case .int(let defaultVal, let minVal, let maxVal, let stepVal):
            let value = instance.parameters.int(param.id, default: defaultVal)
            HStack(spacing: 10) {
                Text(l10n.parameterLabel(param))
                    .font(.system(size: 12))
                    .frame(width: 120, alignment: .leading)
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
            .help(tooltip)

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
            .help(tooltip)

        case .choice(let defaultVal, let options):
            let value = instance.parameters.choice(param.id, default: defaultVal)
            HStack(spacing: 10) {
                Text(l10n.parameterLabel(param))
                    .font(.system(size: 12))
                    .frame(width: 120, alignment: .leading)
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
                .frame(maxWidth: 210)
                Spacer()
            }
            .help(tooltip)
        }
    }

    // MARK: - Effect Mutations & Preview Rendering

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
                    title: l10n.tr("Imported \(imported.count) Mode(s)", "已导入 \(imported.count) 个模式"),
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
                    title: l10n.tr("Mode Exported", "已导出模式"),
                    subtitle: url.lastPathComponent,
                    style: .success
                )
            } catch {
                coordinator.lastErrorMessage = error.localizedDescription
            }
        }
    }
}
