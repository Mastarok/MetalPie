import MetalPieCapture
import MetalPieCore
import SwiftUI

/// Grouped macOS configuration workspace for Capture & Display, Apple Silicon ML Frame Generation,
/// and Zero-Double-Cursor / Zero-Delta-Drift Input Control.
struct CaptureCursorView: View {
    @Bindable var coordinator: AppCoordinator

    private var profile: Profile {
        coordinator.config.profiles.first(where: { $0.id == coordinator.selectedProfileID })
            ?? coordinator.config.defaultProfile
    }

    var body: some View {
        let l10n = coordinator.l10n
        let targetID = profile.id

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.tr("Capture, Frame Generation & Cursor", "捕获、帧生成与光标对齐"))
                            .font(.system(size: 22, weight: .bold))
                        Text(l10n.tr(
                            "Editing settings for: \(profile.isDefault ? "Default Profile" : profile.name) — changes apply immediately to active sessions.",
                            "当前编辑对象：\(profile.isDefault ? "全局默认配置" : profile.name) — 所有修改实时持久化并立即生效。"
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()

                    Picker(l10n.tr("Profile", "配置"), selection: $coordinator.selectedProfileID) {
                        ForEach(coordinator.config.profiles) { p in
                            Text(p.isDefault ? l10n.tr("Default", "默认配置") : p.name).tag(p.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 190)
                }

                captureAndDisplayCard(profileID: targetID, l10n: l10n)
                frameGenerationCard(profileID: targetID, l10n: l10n)
                cursorAndInputCard(profileID: targetID, l10n: l10n)
            }
            .padding(20)
        }
    }

    // MARK: - 1. Capture & Display

    private func captureAndDisplayCard(profileID: UUID, l10n: L10n) -> some View {
        let cap = profile.capture
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

        return SectionCard(
            title: l10n.tr("Capture & Display Pipeline", "零拷贝捕获与显示管线"),
            subtitle: l10n.tr("ScreenCaptureKit zero-copy IOSurface -> Metal GPU pipeline.", "ScreenCaptureKit 零拷贝 IOSurface 直通 Metal 渲染管线。"),
            symbol: "video.fill",
            accent: .blue
        ) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.tr("Capture Pixel Format", "捕获像素格式"))
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 195, alignment: .leading)
                    Picker("", selection: binding(profileID, \.capture.preferredPixelFormat)) {
                        ForEach(CapturePixelFormat.allCases) { fmt in
                            Text(l10n.pixelFormat(fmt)).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 310)
                }

                GridRow {
                    Text(l10n.tr("Dynamic Range", "动态范围"))
                        .font(.system(size: 12.5, weight: .medium))
                    Picker("", selection: binding(profileID, \.capture.dynamicRange)) {
                        ForEach(DynamicRangeMode.allCases) { dr in
                            Text(l10n.dynamicRange(dr)).tag(dr)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 310)
                }

                GridRow {
                    Text(l10n.tr("GPU Duplicate Frame Detection", "GPU 重复帧检测跳过"))
                        .font(.system(size: 12.5, weight: .medium))
                    Picker("", selection: binding(profileID, \.capture.duplicateFrameMode)) {
                        ForEach(DuplicateFrameMode.allCases) { mode in
                            Text(l10n.duplicateFrameMode(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 310)
                }

                GridRow {
                    Text(l10n.tr("1× Non-Retina (Wine/CrossOver)", "1× 非 Retina (Wine/CrossOver)"))
                        .font(.system(size: 12.5, weight: .medium))
                    HStack(spacing: 8) {
                        Picker("", selection: $coordinator.nonRetinaMode) {
                            Text(l10n.tr("Auto GPU Probe", "自动 GPU 检测")).tag(NonRetinaDetectionMode.auto)
                            Text(l10n.tr("Force 1× Demagnify (4× faster)", "强制 1× 还原（省 4× 算力）")).tag(NonRetinaDetectionMode.force1x)
                            Text(l10n.tr("Keep Native 2× Retina", "保持原生 2× Retina")).tag(NonRetinaDetectionMode.force2x)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)

                        if coordinator.detectedContentResolution != .nativeFull {
                            StatusBadge(l10n.tr("1× Active", "已启用 1× 还原"), color: .green)
                        }
                    }
                }

                GridRow {
                    Text(l10n.tr("Capture Frame Rate Cap", "捕获帧率上限"))
                        .font(.system(size: 12.5, weight: .medium))
                    HStack(spacing: 10) {
                        Toggle(l10n.tr("Limit FPS", "限制帧率"), isOn: fpsLimited)
                        if cap.frameRateLimit != nil {
                            Stepper(value: fpsValue, in: 15...240, step: 5) {
                                Text("\(fpsValue.wrappedValue) FPS")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                            }
                        } else {
                            Text(l10n.tr("Uncapped (Display Native Hz)", "不限帧率（跟随显示器刷新率）"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: binding(profileID, \.capture.lowLatencyPresent)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("Low-Latency Direct Present (when Frame Gen is OFF)", "低延迟直出呈现（关闭帧生成时）"))
                            .font(.system(size: 12.5, weight: .medium))
                        Text(l10n.tr("Bypasses CAMetalDisplayLink's ~41ms compositor lead for minimal input-to-photon latency.", "绕过 CAMetalDisplayLink 的约 41ms 缓冲提前量，获得最低输入到显示延迟。"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $coordinator.vrrDirectScanoutEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(l10n.tr("ProMotion VRR Direct-Scanout Mode", "ProMotion VRR 可变刷新率直扫模式"))
                                .font(.system(size: 12.5, weight: .medium))
                            StatusBadge("ProMotion VRR", color: .purple)
                        }
                        Text(l10n.tr(
                            "Composites cursor & HUD directly inside Metal with zero WindowServer sub-windows so ProMotion VRR locks cleanly to game cadence.",
                            "在单次 Metal 通道内直接合成光标与 HUD（零 WindowServer 悬浮子窗），让 ProMotion 可变刷新率完美同步游戏帧率。"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 2. Frame Generation

    private func frameGenerationCard(profileID: UUID, l10n: L10n) -> some View {
        let fg = profile.frameGen
        let aneReady = coordinator.capabilities.supportsVTFrameInterpolation

        return SectionCard(
            title: l10n.tr("Frame Generation (2× / 3× / 4×)", "实时帧生成 (2× / 3× / 4×)"),
            subtitle: l10n.tr("Synthesizes smooth intermediate frames on Apple Neural Engine or Metal Optical Flow with Artifact Guard.", "基于 Apple 神经网络引擎或 Metal 计算光流生成平滑中间帧，并配备场景切换防伪影保护。"),
            symbol: "waveform.path.ecg.rectangle.fill",
            accent: .cyan
        ) {
            HStack {
                Toggle(
                    l10n.tr("Enable Frame Generation", "开启实时帧生成"),
                    isOn: binding(profileID, \.frameGen.enabled)
                )
                .font(.system(size: 13, weight: .semibold))

                Spacer()

                StatusBadge(
                    aneReady
                        ? l10n.tr("Apple Silicon ANE ML Available", "Apple ML 神经引擎可用")
                        : l10n.tr("Metal Optical Flow Ready", "Metal 计算光流就绪"),
                    color: aneReady ? .green : .blue,
                    symbol: aneReady ? "cpu.fill" : "sparkles"
                )
            }

            if fg.enabled {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text(l10n.tr("Frame Rate Multiplier", "帧率倍增倍率"))
                            .font(.system(size: 12.5, weight: .medium))
                            .frame(width: 195, alignment: .leading)
                        Picker("", selection: binding(profileID, \.frameGen.multiplier)) {
                            ForEach(FrameGenMultiplier.allCases) { mult in
                                Text(mult.label).tag(mult)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                    }

                    GridRow {
                        Text(l10n.tr("Interpolation Backend", "插帧计算后端"))
                            .font(.system(size: 12.5, weight: .medium))
                        Picker("", selection: binding(profileID, \.frameGen.backend)) {
                            ForEach(FrameGenBackend.allCases) { backend in
                                Text(l10n.frameGenBackend(backend)).tag(backend)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                    }

                    GridRow {
                        Text(l10n.tr("Artifact Guard Sensitivity", "伪影防护灵敏度 (Artifact Guard)"))
                            .font(.system(size: 12.5, weight: .medium))
                        Picker("", selection: binding(profileID, \.frameGen.artifactGuardSensitivity)) {
                            ForEach(ArtifactGuardSensitivity.allCases) { sens in
                                Text(l10n.artifactGuard(sens)).tag(sens)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }
                }

                Toggle(
                    l10n.tr("Automatically disable Frame Generation in 3D Game Mode", "在 3D 游戏模式下自动关闭帧生成（优先最低延迟）"),
                    isOn: binding(profileID, \.frameGen.disableIn3DGameMode)
                )
                .font(.system(size: 12.5))
            }
        }
    }

    // MARK: - 3. Cursor & Input

    private func cursorAndInputCard(profileID: UUID, l10n: L10n) -> some View {
        let cur = profile.cursor
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

        return SectionCard(
            title: l10n.tr("Cursor Alignment & Input (Zero Double Cursor)", "光标对齐与输入控制（零双光标）"),
            subtitle: l10n.tr("Fencepost-accurate (N-1) mapping, zero-delta-drift confinement, and dynamic NSCursor mirroring.", "精确 (N-1) 坐标映射、零增量漂移边界限制与系统动态指针形态同步。"),
            symbol: "cursorarrow.and.square.on.square.dashed",
            accent: .green
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: binding(profileID, \.cursor.renderScaledCursor)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("Render Scaled Cursor Overlay (Eliminates Double Cursor)", "绘制缩放后独立光标（消除双光标与延迟拖影）"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(l10n.tr("Hides OS cursor cleanly with balanced refcounts and renders live NSCursor.currentSystem at display refresh rate.", "隐藏系统原光标并自动排除录制流中的指针，以满刷新率实时渲染当前系统光标形态。"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text(l10n.tr("Cursor Size Mode", "光标大小模式"))
                            .font(.system(size: 12.5, weight: .medium))
                            .frame(width: 195, alignment: .leading)
                        Picker("", selection: binding(profileID, \.cursor.cursorScaleMode)) {
                            ForEach(CursorScaleMode.allCases) { mode in
                                Text(l10n.cursorScaleMode(mode)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }

                    if cur.cursorScaleMode == .multiplier {
                        GridRow {
                            Text(l10n.tr("Cursor Multiplier", "光标倍率"))
                                .font(.system(size: 12.5, weight: .medium))
                            HStack(spacing: 10) {
                                Slider(
                                    value: binding(profileID, \.cursor.cursorScaleMultiplier),
                                    in: 0.5...2.0,
                                    step: 0.05
                                )
                                .frame(maxWidth: 200)
                                Text(String(format: "%.2f×", cur.cursorScaleMultiplier))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .frame(width: 48, alignment: .trailing)
                            }
                        }
                    }

                    GridRow {
                        Text(l10n.tr("Cursor Interpolation", "光标缩放插值"))
                            .font(.system(size: 12.5, weight: .medium))
                        Picker("", selection: binding(profileID, \.cursor.interpolation)) {
                            ForEach(CursorInterpolation.allCases) { interp in
                                Text(l10n.cursorInterpolation(interp)).tag(interp)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                    }

                    GridRow {
                        Text(l10n.tr("Hide Cursor on Idle", "静止自动隐藏光标"))
                            .font(.system(size: 12.5, weight: .medium))
                        HStack(spacing: 10) {
                            Toggle("", isOn: idleEnabled)
                                .labelsHidden()
                            if cur.hideOnIdleSeconds != nil {
                                Slider(value: idleSeconds, in: 0.5...10.0, step: 0.5)
                                    .frame(maxWidth: 160)
                                Text(String(format: "%.1f s", idleSeconds.wrappedValue))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                            } else {
                                Text(l10n.tr("Always Visible", "始终显示"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    Toggle(
                        l10n.tr("Confine Cursor inside Target Window (Zero-Delta-Drift)", "将光标限制在目标窗口内（零增量漂移，兼容 Wine/游戏）"),
                        isOn: binding(profileID, \.cursor.confineCursor)
                    )
                    Toggle(
                        l10n.tr("Compensate Cursor Speed by 1/Scale (without altering macOS system prefs)", "按 1/缩放倍率 补偿光标移动速度（不篡改 macOS 系统设置）"),
                        isOn: binding(profileID, \.cursor.adjustCursorSpeed)
                    )
                    Toggle(
                        l10n.tr("Hide Cursor Sprite in Screenshots", "截图时自动隐藏光标"),
                        isOn: binding(profileID, \.cursor.hideInScreenshots)
                    )
                    Toggle(
                        l10n.tr("Respect FPS / 3D Game Mouse-Grab", "自动识别 FPS/3D 游戏鼠标锁定（隐藏覆盖指针）"),
                        isOn: binding(profileID, \.cursor.respectGameMouseGrab)
                    )
                }
                .font(.system(size: 12.5))
            }
        }
    }

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
}
