import AppKit
import MetalPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Magpie-class Multi-Pass Effect Chain Builder + Interactive Real-Time Metal Before/After Split-View Preview!
///
/// - Left column: Built-in (12) & custom Scaling Modes (`+ New`, `Duplicate`, `Delete`, `Import JSON`, `Export JSON`).
/// - Right top: Live Apple Silicon GPU `EffectChainRenderer.renderPreview(...)` before/after comparison
///   with smooth draggable curtain divider, `1×`/`2×`/`4×` zoom, procedural sample scenes + custom image picker,
///   and real GPU render ms badge!
/// - Right bottom: Ordered multi-pass effect graph editor supporting all 22 `EffectID`s grouped by category,
///   reordering, `ScalingType` + scale/pixel inputs, and live typed parameter controls!
struct EffectChainEditorView: View {
    @Bindable var coordinator: AppCoordinator

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

    var body: some View {
        let l10n = coordinator.l10n

        HSplitView {
            // Left: Scaling Modes Master List
            modesSidebar(l10n: l10n)
                .frame(minWidth: 205, idealWidth: 225, maxWidth: 270)

            // Right: Live Metal Split-View Preview + Multi-Pass Effect Chain Builder
            if let mode = selectedMode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        modeHeaderBar(mode: mode, l10n: l10n)
                        liveMetalPreviewCard(mode: mode, l10n: l10n)
                        effectChainBuilderCard(mode: mode, l10n: l10n)
                    }
                    .padding(16)
                }
                .frame(minWidth: 520)
                .onChange(of: mode) { _, newMode in
                    schedulePreviewRender(for: newMode, debounce: true)
                }
                .onChange(of: selectedScene) { _, _ in
                    customSourceImage = nil
                    customSourceName = nil
                    schedulePreviewRender(for: mode, debounce: false)
                }
                .onAppear {
                    schedulePreviewRender(for: mode, debounce: false)
                }
            } else {
                ContentUnavailableView(
                    l10n.tr("No Scaling Mode Selected", "未选择缩放模式"),
                    systemImage: "sparkles.rectangle.stack"
                )
            }
        }
    }

    // MARK: - Left Column: Scaling Modes List

    private func modesSidebar(l10n: L10n) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(l10n.tr("Scaling Modes", "缩放预设与管线"))
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button {
                    _ = coordinator.createNewScalingMode()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(l10n.tr("New Custom Scaling Mode", "新建自定义缩放模式"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(selection: $coordinator.selectedScalingModeID) {
                Section(l10n.tr("Built-In Presets (12)", "内置精选预设 (12)")) {
                    ForEach(coordinator.config.scalingModes.filter(\.isBuiltIn)) { mode in
                        modeListRow(mode, l10n: l10n)
                            .tag(mode.id)
                    }
                }

                let customModes = coordinator.config.scalingModes.filter { !$0.isBuiltIn }
                if !customModes.isEmpty {
                    Section(l10n.tr("Custom Modes", "自定义模式")) {
                        ForEach(customModes) { mode in
                            modeListRow(mode, l10n: l10n)
                                .tag(mode.id)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            // Footer Actions: Duplicate / Delete / Import / Export JSON
            HStack(spacing: 6) {
                Button {
                    _ = coordinator.duplicateScalingMode(id: coordinator.selectedScalingModeID)
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help(l10n.tr("Duplicate Mode", "复制当前模式"))

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

    private func modeListRow(_ mode: ScalingMode, l10n: L10n) -> some View {
        let isDefaultActive = coordinator.config.defaultProfile.scalingModeID == mode.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(l10n.builtInModeName(mode))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if isDefaultActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
            Text("\(mode.effects.filter(\.enabled).count) \(l10n.tr("pass(es)", "个通道"))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Mode Header

    private func modeHeaderBar(mode: ScalingMode, l10n: L10n) -> some View {
        let isDefaultMode = coordinator.config.defaultProfile.scalingModeID == mode.id

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if mode.isBuiltIn {
                    HStack(spacing: 8) {
                        Text(l10n.builtInModeName(mode))
                            .font(.system(size: 18, weight: .bold))
                        StatusBadge(l10n.tr("Built-In", "内置预设"), color: .blue)
                    }
                    Text(l10n.builtInModeDescription(mode))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    TextField(
                        l10n.tr("Scaling Mode Name", "缩放模式名称"),
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
                        l10n.tr("Description", "描述说明"),
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

            Spacer()

            if isDefaultMode {
                StatusBadge(l10n.tr("Active Default Preset", "当前默认预设"), color: .green, symbol: "checkmark.circle.fill")
            } else {
                Button {
                    coordinator.updateDefaultProfile { $0.scalingModeID = mode.id }
                    coordinator.showToast(
                        icon: "checkmark.circle.fill",
                        title: l10n.tr("Set as Default Preset", "已设为默认缩放预设"),
                        subtitle: l10n.builtInModeName(mode),
                        style: .success
                    )
                } label: {
                    Label(l10n.tr("Use as Default", "设为默认预设"), systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Interactive Real-Time Metal Before/After Split-View Preview

    private func liveMetalPreviewCard(mode: ScalingMode, l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Real-Time Metal Before / After Preview", "实时 Metal GPU 前后对比预览"),
            subtitle: l10n.tr(
                "Drag the vertical curtain to compare raw original input (left) vs live Apple Silicon GPU output (right).",
                "拖动中间分隔线，实时对比原始低分画面（左）与 Apple Silicon GPU 着色器输出（右）。"
            ),
            symbol: "rectangle.split.2x1.fill",
            accent: .cyan
        ) {
            // Preview Toolbar
            HStack(spacing: 8) {
                Picker("", selection: $selectedScene) {
                    ForEach(PreviewSampleScene.allCases) { scene in
                        Text(scene.title(l10n)).tag(scene)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 158, maxWidth: 195)

                HStack(spacing: 4) {
                    Button {
                        loadCustomPreviewImage(mode: mode)
                    } label: {
                        Label(
                            customSourceName ?? l10n.tr("Image…", "图片…"),
                            systemImage: "photo.badge.plus"
                        )
                        .lineLimit(1)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)

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
                        .help(l10n.tr("Revert to Built-In Test Scene", "恢复内置测试场景"))
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
                .frame(width: 108)

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

                    // Right side (full background): REAL Metal GPU rendered output!
                    if let rendered = renderedDisplayImage {
                        Image(nsImage: rendered)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fill)
                            .scaleEffect(zoomLevel)
                            .frame(width: canvasW, height: canvasH)
                            .clipped()
                    }

                    // Left side (clipped to dividerX): Crisp un-upscaled Original input!
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
                            Text(verbatim: "\(l10n.tr("ORIGINAL", "原始输入")) (\(previewSourceSize.width)×\(previewSourceSize.height))")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Color.black.opacity(0.65), in: Capsule())

                            Spacer()

                            Text(verbatim: "\(l10n.tr("GPU OUTPUT", "GPU 输出")) (\(previewOutputSize.width)×\(previewOutputSize.height))")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Color.black.opacity(0.70), in: Capsule())
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
            .frame(height: 270)
        }
    }

    // MARK: - Magpie-Style Multi-Pass Effect Chain Builder

    private func effectChainBuilderCard(mode: ScalingMode, l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Multi-Pass Effect Chain", "多通道着色器链 (Effect Chain)"),
            subtitle: l10n.tr(
                "Effects run sequentially from top to bottom on the GPU. An automatic Bicubic Catmull-Rom pass adapts fixed-factor CNNs when needed.",
                "着色器通道按从上到下的顺序在 GPU 上串联执行。定倍神经网络在输出不匹配时会自动补全双三次平滑通道。"
            ),
            symbol: "square.stack.3d.down.right.fill",
            accent: .indigo
        ) {
            // Add Effect Grouped Menu (All 22 EffectIDs grouped by all 9 EffectCategories!)
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
                    Label(l10n.tr("Add Effect Pass", "添加着色器通道"), systemImage: "plus.circle.fill")
                }
                .menuStyle(.borderedButton)
                .fixedSize()

                Spacer()

                Text("\(mode.effects.count) \(l10n.tr("effect(s) configured", "个通道"))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if mode.effects.isEmpty {
                VStack(spacing: 6) {
                    Text(l10n.tr("No effects in chain — default Bicubic Catmull-Rom fit will be used.", "当前链为空 — 将默认使用双三次 Catmull-Rom 等比缩放。"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
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
                        .help(l10n.tr("Reset Parameters to Default", "恢复默认参数"))
                    }

                    Button {
                        removeEffect(modeID: modeID, effectInstanceID: instance.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help(l10n.tr("Remove Effect", "移除此通道"))
                }
            }

            // Effect summary description
            Text(l10n.effectSummary(desc))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Scaling Type + Scale/Absolute Inputs (when effect is not strictly sameSize)
            if desc.scaleCapability != .sameSize {
                HStack(spacing: 12) {
                    Picker(l10n.tr("Scaling Type", "缩放方式"), selection: Binding(
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
                    .frame(maxWidth: 220)

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

            // Dynamic Typed Parameter Controls
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
                .frame(maxWidth: 210)
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

        // Prepare crisp nearest-neighbor original comparison image at matching output size
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
                    title: l10n.tr("Exported Scaling Mode", "已导出缩放模式 JSON"),
                    subtitle: url.lastPathComponent,
                    style: .success
                )
            } catch {
                coordinator.lastErrorMessage = error.localizedDescription
            }
        }
    }
}
