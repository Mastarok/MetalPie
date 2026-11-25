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
        case .p720to1440: return "720p → 1440p"
        case .p1080to4K: return "1080p → 4K"
        case .p360to720: return "360p → 720p"
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

/// Hardware summary, connected displays, shader benchmark, cache, and logs (`性能测试` / `Benchmark`).
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

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(l10n.tr("Benchmark", "性能测试"))
                        .font(.system(size: 20, weight: .bold))

                    hardwareSummaryBar(l10n: l10n)
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

    // MARK: - Compact Hardware Summary

    private func hardwareSummaryBar(l10n: L10n) -> some View {
        let cap = coordinator.capabilities
        let memText: String = {
            if cap.recommendedWorkingSetMB >= 1024 {
                let gb = (Double(cap.recommendedWorkingSetMB) / 1024.0).rounded()
                return String(format: "%.0f GB", gb)
            }
            return "\(cap.recommendedWorkingSetMB) MB"
        }()
        let metalLabel = cap.supportsMetal4 ? "Metal 4" : (cap.supportsMetal3 ? "Metal 3" : "Metal 2")

        return HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(cap.gpuName) · \(memText)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }

            Divider().frame(height: 14)

            capabilityChip(metalLabel, supported: cap.supportsMetal3)
            capabilityChip("MetalFX", supported: cap.supportsMetalFXSpatial)
            capabilityChip(l10n.tr("ML Frame Gen", "ML 补帧"), supported: cap.supportsVTFrameInterpolation)
            capabilityChip(l10n.tr("ML Super Res", "ML 超分"), supported: cap.supportsVTSuperResolution)

            Spacer(minLength: 4)

            Text(cap.macOSVersionString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func capabilityChip(_ label: String, supported: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(supported ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 6.5, height: 6.5)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(supported ? .primary : .secondary)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Displays Table

    private func connectedDisplaysCard(l10n: L10n) -> some View {
        SectionCard(title: l10n.tr("Displays", "显示器")) {
            VStack(spacing: 5) {
                HStack {
                    Text(l10n.tr("Display", "名称")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(l10n.tr("Resolution", "分辨率")).frame(width: 96, alignment: .trailing)
                    Text(l10n.tr("Scale", "缩放")).frame(width: 44, alignment: .trailing)
                    Text(l10n.tr("Refresh", "刷新率")).frame(width: 64, alignment: .trailing)
                    Text("HDR").frame(width: 72, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

                Divider()

                ForEach(coordinator.displays) { display in
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: display.isPrimary ? "laptopcomputer" : "display")
                                .font(.system(size: 11.5))
                                .foregroundStyle(display.isPrimary ? .blue : .secondary)
                            Text(display.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            StatusBadge(
                                display.isPrimary ? l10n.tr("Primary", "主屏") : l10n.tr("External", "外接"),
                                color: display.isPrimary ? .blue : .secondary
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(verbatim: "\(display.pixelSize.width)×\(display.pixelSize.height)")
                            .font(.system(size: 12, design: .monospaced))
                            .monospacedDigit()
                            .frame(width: 96, alignment: .trailing)

                        Text(String(format: "@%.0fx", display.backingScaleFactor))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)

                        Text(String(format: "%.0f Hz", display.refreshRateHz))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(display.refreshRateHz >= 100 ? .cyan : .primary)
                            .frame(width: 64, alignment: .trailing)

                        Text(display.supportsHDR ? String(format: "HDR %.0f×", display.maxEDRHeadroom) : "SDR")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(display.supportsHDR ? .orange : .secondary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    // MARK: - Shader Benchmark

    private func gpuBenchmarkCard(l10n: L10n) -> some View {
        let maxMs = max(
            0.5,
            coordinator.benchmarkResults.filter(\.succeeded).map(\.averageGPUMilliseconds).max() ?? 4.0
        )

        return SectionCard(title: l10n.tr("Shader Benchmark", "着色器基准测试")) {
            HStack(spacing: 10) {
                Picker("", selection: $benchmarkPreset) {
                    ForEach(BenchmarkResolutionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
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
                            ? l10n.tr("Running…", "测试中…")
                            : l10n.tr("Start Benchmark", "开始测试"),
                        systemImage: "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isBenchmarkRunning)
            }

            if coordinator.isBenchmarkRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: coordinator.benchmarkProgress)
                    Text(coordinator.benchmarkCurrentEffectName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if !coordinator.benchmarkResults.isEmpty {
                VStack(spacing: 5) {
                    ForEach(coordinator.benchmarkResults) { result in
                        let desc = EffectCatalog.descriptor(for: result.effectID)
                        let frac = result.succeeded ? min(1.0, max(0.03, result.averageGPUMilliseconds / maxMs)) : 0
                        let barColor: Color = result.averageGPUMilliseconds < 1.0 ? .green : (result.averageGPUMilliseconds < 2.5 ? .cyan : .orange)

                        HStack(spacing: 10) {
                            Text(l10n.effectName(desc))
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 175, alignment: .leading)
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
                            .frame(height: 10)

                            if result.succeeded {
                                Text(String(format: "%.2f ms", result.averageGPUMilliseconds))
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .frame(width: 62, alignment: .trailing)

                                Text(String(format: "%.0f FPS", result.estimatedFPS))
                                    .font(.system(size: 11, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .trailing)
                            } else {
                                Text(result.note ?? l10n.tr("Skipped", "跳过"))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.orange)
                                    .frame(width: 132, alignment: .trailing)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Shader Cache

    private func shaderBinaryCacheCard(l10n: L10n) -> some View {
        let formattedSize = ByteCountFormatter.string(fromByteCount: coordinator.shaderCacheSizeBytes, countStyle: .file)
        let count = coordinator.effectChainRenderer?.shaderManager.cachedPipelineCount ?? 0

        return SectionCard(title: l10n.tr("Shader Cache", "着色器缓存")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(formattedSize) · \(count) \(l10n.tr("pipelines", "个管线"))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text(coordinator.shaderCachePath.isEmpty ? "—" : coordinator.shaderCachePath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(l10n.tr("Rebuild", "重建缓存")) {
                    Task { await coordinator.clearAndRebuildShaderCache() }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Logs

    private func pipelineLogConsoleCard(l10n: L10n) -> some View {
        SectionCard {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text(l10n.tr("Logs", "日志"))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("(\(filteredLogs.count))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Picker("", selection: $selectedLogCategory) {
                    Text(l10n.tr("All", "全部")).tag(LogCategory?.none)
                    ForEach(LogCategory.allCases) { cat in
                        Text(l10n.logCategory(cat)).tag(LogCategory?.some(cat))
                    }
                }
                .labelsHidden()
                .frame(width: 96)

                Picker("", selection: $minimumLogLevel) {
                    Text("DEBUG+").tag(LogLevel.debug)
                    Text("INFO+").tag(LogLevel.info)
                    Text("WARN+").tag(LogLevel.warning)
                    Text("ERROR").tag(LogLevel.error)
                }
                .labelsHidden()
                .frame(width: 92)

                TextField(l10n.tr("Filter…", "筛选…"), text: $logSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                Button {
                    let text = PipelineLog.shared.formattedExport(minimumLevel: minimumLogLevel, category: selectedLogCategory)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    coordinator.showToast(
                        icon: "doc.on.clipboard.fill",
                        title: l10n.tr("Logs Copied", "已复制日志"),
                        style: .info
                    )
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help(l10n.tr("Copy", "复制"))

                Button {
                    exportLogFile(l10n: l10n)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help(l10n.tr("Export", "导出"))

                Button {
                    coordinator.clearLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help(l10n.tr("Clear", "清空"))
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
            .frame(height: 180)
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
                    title: l10n.tr("Logs Exported", "日志已导出"),
                    subtitle: url.lastPathComponent,
                    style: .success
                )
            } catch {
                coordinator.lastErrorMessage = error.localizedDescription
            }
        }
    }
}
