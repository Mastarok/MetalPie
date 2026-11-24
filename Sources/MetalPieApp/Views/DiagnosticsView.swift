import AppKit
import MetalPieCore
import MetalPieShaders
import SwiftUI
import UniformTypeIdentifiers

private enum BenchmarkResolutionPreset: String, CaseIterable, Identifiable {
    case p720to1440
    case p1080to4K
    case p360to720

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p720to1440: return "720p → 2K (2×)"
        case .p1080to4K: return "1080p → 4K (2×)"
        case .p360to720: return "360p → 720p (2×)"
        }
    }

    var inputSize: PixelSize {
        switch self {
        case .p720to1440: return PixelSize(width: 1280, height: 720)
        case .p1080to4K: return PixelSize(width: 1920, height: 1080)
        case .p360to720: return PixelSize(width: 640, height: 360)
        }
    }

    var outputSize: PixelSize {
        switch self {
        case .p720to1440: return PixelSize(width: 2560, height: 1440)
        case .p1080to4K: return PixelSize(width: 3840, height: 2160)
        case .p360to720: return PixelSize(width: 1280, height: 720)
        }
    }
}

/// Hardware & Multi-Monitor Inspector, One-Click 30-Shader GPU Benchmark, Shader Cache & Logs (`显卡测速` / `Benchmark`).
struct DiagnosticsView: View {
    @Bindable var coordinator: AppCoordinator

    @State private var benchmarkPreset: BenchmarkResolutionPreset = .p720to1440
    @State private var selectedLogCategory: LogCategory? = nil
    @State private var minimumLogLevel: LogLevel = .debug
    @State private var logSearchQuery: String = ""

    private var filteredLogs: [LogEntry] {
        let q = logSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return coordinator.logEntries.filter { entry in
            guard entry.level >= minimumLogLevel else { return false }
            if let cat = selectedLogCategory, entry.category != cat { return false }
            if !q.isEmpty && !entry.message.localizedCaseInsensitiveContains(q) { return false }
            return true
        }
    }

    var body: some View {
        let l10n = coordinator.l10n
        let effectCount = EffectID.allCases.count

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.tr("GPU Benchmark & Hardware Info", "显卡测速与硬件信息"))
                            .font(.system(size: 22, weight: .bold))
                        Text(l10n.tr(
                            "Check your Apple Silicon GPU, connected multi-monitor setup, benchmark all \(effectCount) shaders, and inspect logs.",
                            "查看本机芯片与多显示器状态、一键实测全部 \(effectCount) 种画质算法的帧率表现，并查看运行日志。"
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }

                    hardwareCapabilitiesCard(l10n: l10n)
                    connectedDisplaysCard(l10n: l10n)
                    gpuBenchmarkCard(l10n: l10n)
                        .id("gpuBenchmarkCard")
                    shaderBinaryCacheCard(l10n: l10n)
                    pipelineLogConsoleCard(l10n: l10n)
                }
                .padding(20)
            }
            .onChange(of: coordinator.isBenchmarkRunning) { _, running in
                if !running && !coordinator.benchmarkResults.isEmpty {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("gpuBenchmarkCard", anchor: .top)
                    }
                }
            }
            .onChange(of: coordinator.benchmarkResults.count) { oldCount, newCount in
                if oldCount == 0 && newCount > 0 {
                    proxy.scrollTo("gpuBenchmarkCard", anchor: .top)
                }
            }
            .onAppear {
                coordinator.refreshDisplays()
                coordinator.refreshShaderCacheMetadata()
                coordinator.refreshLogs()
                if !coordinator.benchmarkResults.isEmpty {
                    proxy.scrollTo("gpuBenchmarkCard", anchor: .top)
                }
            }
        }
    }

    // MARK: - Hardware Capabilities

    private func hardwareCapabilitiesCard(l10n: L10n) -> some View {
        let cap = coordinator.capabilities
        let columns = [GridItem(.adaptive(minimum: 205), spacing: 10)]

        return SectionCard(
            title: l10n.tr("Apple Silicon GPU & Hardware Features", "芯片显卡与硬件加速"),
            subtitle: cap.macOSVersionString,
            symbol: "cpu.fill",
            accent: .cyan
        ) {
            LazyVGrid(columns: columns, spacing: 10) {
                capabilityTile(
                    title: l10n.tr("Graphics (GPU)", "图形处理器"),
                    value: cap.gpuName,
                    detail: "\(cap.recommendedWorkingSetMB) MB \(l10n.tr("Unified Memory", "统一内存"))",
                    ok: true
                )
                capabilityTile(
                    title: l10n.tr("Metal Support", "Metal 支持"),
                    value: cap.supportsMetal4 ? "Metal 4 + Metal 3" : (cap.supportsMetal3 ? "Metal 3" : "Metal 2"),
                    detail: l10n.tr("GPU Shader Pipeline", "支持全部实时画质算法"),
                    ok: cap.supportsMetal3
                )
                capabilityTile(
                    title: l10n.tr("MetalFX Upscaler", "MetalFX 硬件超分"),
                    value: cap.supportsMetalFXSpatial ? l10n.tr("SDR + HDR Ready", "支持 SDR 与 HDR") : l10n.tr("Unavailable", "不支持"),
                    detail: l10n.tr("Apple Hardware Spatial Upscaling", "Apple 芯片原生硬件超分"),
                    ok: cap.supportsMetalFXSpatial
                )
                capabilityTile(
                    title: l10n.tr("Hardware Frame Gen", "硬件流畅补帧"),
                    value: cap.supportsVTFrameInterpolation
                        ? l10n.tr("Apple Silicon Hardware Ready", "支持 Apple 芯片硬件补帧")
                        : l10n.tr("Metal Optical Flow", "使用 Metal 光流补帧"),
                    detail: l10n.tr("2× / 3× / 4× Smooth Motion", "2× / 3× / 4× 丝滑插帧"),
                    ok: cap.supportsVTFrameInterpolation
                )
                capabilityTile(
                    title: l10n.tr("Apple ML Upscaler", "Apple 神经引擎超分"),
                    value: cap.supportsVTSuperResolution
                        ? l10n.tr("1.5× / 2× / 4× Ready", "支持 1.5× / 2× / 4×")
                        : l10n.tr("Requires macOS 26+", "需 macOS 26+"),
                    detail: l10n.tr("Neural Engine Super Resolution", "神经引擎 AI 超分辨率"),
                    ok: cap.supportsVTSuperResolution
                )
            }
        }
    }

    private func capabilityTile(title: String, value: String, detail: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(ok ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
            }
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Connected Multi-Monitor Table

    private func connectedDisplaysCard(l10n: L10n) -> some View {
        let primaryDisplay = ScreenGeometry.primaryDisplay(in: coordinator.displays)

        return SectionCard(
            title: l10n.tr("Connected Displays (\(coordinator.displays.count))", "已连接的显示器（共 \(coordinator.displays.count) 台）"),
            subtitle: l10n.tr(
                "Shows resolution, HiDPI scaling, refresh rate, and multi-monitor layout position for each screen.",
                "实时识别每块屏幕的分辨率、清晰度缩放（@2x/@1x）、刷新率与多屏相对位置。"
            ),
            symbol: "display.2",
            accent: .blue
        ) {
            VStack(spacing: 6) {
                HStack {
                    Text(l10n.tr("Display & Position", "显示器与位置")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(l10n.tr("Resolution", "物理分辨率")).frame(width: 105, alignment: .trailing)
                    Text("DPI").frame(width: 48, alignment: .trailing)
                    Text(l10n.tr("Refresh", "刷新率")).frame(width: 68, alignment: .trailing)
                    Text("HDR").frame(width: 82, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

                Divider()

                ForEach(coordinator.displays) { display in
                    let posLabel = multiMonitorPositionBadge(for: display, relativeTo: primaryDisplay, l10n: l10n)
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: display.isPrimary ? "laptopcomputer" : "display")
                                .font(.system(size: 12))
                                .foregroundStyle(display.isPrimary ? .blue : .secondary)
                            Text(display.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            if display.isPrimary {
                                StatusBadge(l10n.tr("Primary", "主屏"), color: .blue)
                            } else {
                                StatusBadge(posLabel, color: .indigo)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(verbatim: "\(display.pixelSize.width)×\(display.pixelSize.height)")
                            .font(.system(size: 12, design: .monospaced))
                            .monospacedDigit()
                            .frame(width: 105, alignment: .trailing)

                        Text(String(format: "@%.0fx", display.backingScaleFactor))
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)

                        Text(String(format: "%.0f Hz", display.refreshRateHz))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(display.refreshRateHz >= 100 ? .cyan : .primary)
                            .frame(width: 68, alignment: .trailing)

                        Text(display.supportsHDR ? String(format: "%.1f× HDR", display.maxEDRHeadroom) : "SDR")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(display.supportsHDR ? .orange : .secondary)
                            .frame(width: 82, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    private func multiMonitorPositionBadge(
        for display: DisplayDescriptor,
        relativeTo primary: DisplayDescriptor?,
        l10n: L10n
    ) -> String {
        guard let primary, display.id != primary.id else {
            return l10n.tr("Primary", "主屏")
        }
        var parts: [String] = []
        if display.cgBounds.midX < primary.cgBounds.minX {
            parts.append(l10n.tr("Left", "左侧外接"))
        } else if display.cgBounds.midX > primary.cgBounds.maxX {
            parts.append(l10n.tr("Right", "右侧外接"))
        }
        if display.cgBounds.midY < primary.cgBounds.minY {
            parts.append(l10n.tr("Above", "上方"))
        } else if display.cgBounds.midY > primary.cgBounds.maxY {
            parts.append(l10n.tr("Below", "下方"))
        }
        if parts.isEmpty {
            return l10n.tr("External", "外接屏")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - One-Click 30-Shader GPU Benchmark

    private func gpuBenchmarkCard(l10n: L10n) -> some View {
        let totalEffects = EffectID.allCases.count
        let maxMs = max(
            0.5,
            coordinator.benchmarkResults.filter(\.succeeded).map(\.averageGPUMilliseconds).max() ?? 4.0
        )

        return SectionCard(
            title: l10n.tr("One-Click \(totalEffects)-Shader GPU Benchmark", "一键显卡测速（全部 \(totalEffects) 种画质算法）"),
            subtitle: l10n.tr(
                "Measures real rendering speed of all \(totalEffects) built-in effects directly on \(coordinator.capabilities.gpuName).",
                "在 \(coordinator.capabilities.gpuName) 上实地测试全部 \(totalEffects) 种超分与滤镜的单帧耗时与理论帧率。"
            ),
            symbol: "speedometer",
            accent: .green
        ) {
            HStack(spacing: 10) {
                Picker("", selection: $benchmarkPreset) {
                    ForEach(BenchmarkResolutionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .disabled(coordinator.isBenchmarkRunning)

                Spacer()

                Button {
                    Task {
                        await coordinator.runShaderBenchmark(
                            inputSize: benchmarkPreset.inputSize,
                            outputSize: benchmarkPreset.outputSize,
                            iterations: 4
                        )
                    }
                } label: {
                    Label(
                        coordinator.isBenchmarkRunning
                            ? l10n.tr("Testing…", "测速中…")
                            : l10n.tr("Start Benchmark", "开始一键测速"),
                        systemImage: "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isBenchmarkRunning)
            }

            if coordinator.isBenchmarkRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: coordinator.benchmarkProgress)
                    Text("\(l10n.tr("Testing", "正在测试")): \(coordinator.benchmarkCurrentEffectName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if !coordinator.benchmarkResults.isEmpty {
                VStack(spacing: 6) {
                    ForEach(coordinator.benchmarkResults) { result in
                        let desc = EffectCatalog.descriptor(for: result.effectID)
                        let frac = result.succeeded ? min(1.0, max(0.03, result.averageGPUMilliseconds / maxMs)) : 0
                        let barColor: Color = result.averageGPUMilliseconds < 1.0 ? .green : (result.averageGPUMilliseconds < 2.5 ? .cyan : .orange)

                        HStack(spacing: 10) {
                            Text(l10n.effectName(desc))
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 190, alignment: .leading)
                                .lineLimit(1)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                    if result.succeeded {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(barColor.gradient)
                                            .frame(width: max(6, geo.size.width * frac))
                                    }
                                }
                            }
                            .frame(height: 12)

                            if result.succeeded {
                                Text(String(format: "%.2f ms", result.averageGPUMilliseconds))
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .frame(width: 64, alignment: .trailing)

                                Text(String(format: "%.0f FPS", result.estimatedFPS))
                                    .font(.system(size: 11, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 68, alignment: .trailing)
                            } else {
                                Text(result.note ?? l10n.tr("Skipped", "已跳过"))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.orange)
                                    .frame(width: 138, alignment: .trailing)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Shader Acceleration Cache

    private func shaderBinaryCacheCard(l10n: L10n) -> some View {
        let formattedSize = ByteCountFormatter.string(fromByteCount: coordinator.shaderCacheSizeBytes, countStyle: .file)

        return SectionCard(
            title: l10n.tr("Shader Pre-Compile Cache", "着色器加速缓存"),
            subtitle: l10n.tr(
                "Stores compiled Metal shaders on disk so future scaling starts in under 1 ms.",
                "自动把编译好的画质算法缓存到本地，下次开启缩放几乎瞬间启动。"
            ),
            symbol: "memorychip.fill",
            accent: .indigo
        ) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.shaderCachePath.isEmpty ? "—" : coordinator.shaderCachePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(l10n.tr("Cache Size", "缓存占用")): \(formattedSize) • \(coordinator.effectChainRenderer?.shaderManager.cachedPipelineCount ?? 0) \(l10n.tr("ready shaders", "个已就绪算法"))")
                        .font(.system(size: 11.5, weight: .medium))
                }
                Spacer()
                Button {
                    Task { await coordinator.clearAndRebuildShaderCache() }
                } label: {
                    Label(l10n.tr("Rebuild Cache", "清理并重建缓存"), systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Logs Console

    private func pipelineLogConsoleCard(l10n: L10n) -> some View {
        SectionCard(
            title: l10n.tr("Runtime Logs", "运行日志"),
            subtitle: l10n.tr("Showing \(filteredLogs.count) of \(coordinator.logEntries.count) entries", "当前显示 \(filteredLogs.count) 条（共 \(coordinator.logEntries.count) 条）"),
            symbol: "terminal.fill",
            accent: .secondary
        ) {
            HStack(spacing: 8) {
                Picker(l10n.tr("Module", "分类"), selection: $selectedLogCategory) {
                    Text(l10n.tr("All", "全部分类")).tag(LogCategory?.none)
                    ForEach(LogCategory.allCases) { cat in
                        Text(l10n.logCategory(cat)).tag(LogCategory?.some(cat))
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                Picker(l10n.tr("Level", "级别"), selection: $minimumLogLevel) {
                    Text("DEBUG+").tag(LogLevel.debug)
                    Text("INFO+").tag(LogLevel.info)
                    Text("WARN+").tag(LogLevel.warning)
                    Text("ERROR").tag(LogLevel.error)
                }
                .labelsHidden()
                .frame(width: 95)

                TextField(l10n.tr("Search logs…", "搜索日志关键字…"), text: $logSearchQuery)
                    .textFieldStyle(.roundedBorder)

                Button {
                    let text = PipelineLog.shared.formattedExport(minimumLevel: minimumLogLevel, category: selectedLogCategory)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    coordinator.showToast(
                        icon: "doc.on.clipboard.fill",
                        title: l10n.tr("Logs Copied", "日志已复制到剪贴板"),
                        style: .info
                    )
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .help(l10n.tr("Copy Logs", "复制日志"))

                Button {
                    exportLogFile(l10n: l10n)
                } label: {
                    Label(l10n.tr("Export .log", "导出日志"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button {
                    coordinator.clearLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help(l10n.tr("Clear Logs", "清空日志"))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(filteredLogs.reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.timeFormatter.string(from: entry.timestamp))
                                .foregroundStyle(.secondary)
                            Text("[\(entry.level.tag)]")
                                .foregroundStyle(colorForLevel(entry.level))
                                .fontWeight(.bold)
                                .frame(width: 52, alignment: .leading)
                            Text("[\(entry.category.rawValue)]")
                                .foregroundStyle(.cyan)
                                .frame(width: 64, alignment: .leading)
                            Text(entry.message)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func exportLogFile(l10n: L10n) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        panel.nameFieldStringValue = "MetalPie-Diagnostics.log"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PipelineLog.shared.export(to: url, minimumLevel: minimumLogLevel, category: selectedLogCategory)
                coordinator.showToast(
                    icon: "checkmark.circle.fill",
                    title: l10n.tr("Log Exported", "运行日志已导出"),
                    subtitle: url.lastPathComponent,
                    style: .success
                )
            } catch {
                coordinator.lastErrorMessage = error.localizedDescription
            }
        }
    }
}
