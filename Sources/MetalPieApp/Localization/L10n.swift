import Foundation
import MetalPieCore

/// Idiomatic bilingual (English / 简体中文) localization helper driven by `AppConfig.language`.
///
/// Switching `AppConfig.language` updates every SwiftUI view, menu bar item, overlay panel,
/// and toast notification instantaneously without restarting the app.
public struct L10n: Sendable {
    public let isChinese: Bool

    public init(language: AppLanguage) {
        switch language {
        case .en:
            self.isChinese = false
        case .zhHans:
            self.isChinese = true
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            self.isChinese = preferred.hasPrefix("zh")
        }
    }

    /// Returns Chinese or English text depending on the active language.
    @inline(__always)
    public func tr(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }

    // MARK: - Core Enum Localizations

    public func languageName(_ lang: AppLanguage) -> String {
        switch lang {
        case .system: return tr("Follow System", "跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    public func effectName(_ descriptor: EffectDescriptor) -> String {
        isChinese ? descriptor.nameZH : descriptor.nameEN
    }

    public func effectSummary(_ descriptor: EffectDescriptor) -> String {
        isChinese ? descriptor.summaryZH : descriptor.summaryEN
    }

    public func effectCategory(_ category: EffectCategory) -> String {
        isChinese ? category.labelZH : category.labelEN
    }

    public func parameterLabel(_ param: EffectParameterDescriptor) -> String {
        isChinese ? param.labelZH : param.labelEN
    }

    public func parameterDescription(_ param: EffectParameterDescriptor) -> String {
        isChinese ? param.descriptionZH : param.descriptionEN
    }

    public func parameterChoiceLabel(_ choice: EffectParameterChoice) -> String {
        isChinese ? choice.labelZH : choice.labelEN
    }

    public func builtInModeName(_ mode: ScalingMode) -> String {
        guard mode.isBuiltIn else { return mode.name }
        switch mode.id {
        case ScalingMode.metalFXSpatialID:
            return tr("MetalFX Spatial", "MetalFX 空间超分")
        case ScalingMode.fsr1ID:
            return tr("FSR 1.0 (EASU + RCAS)", "FSR 1.0 (EASU + RCAS 锐化)")
        case ScalingMode.appleMLSuperResID:
            return tr("Apple ML Super Resolution", "Apple 机器学习超分")
        case ScalingMode.lanczos6ID:
            return tr("Lanczos6 Anti-Ringing", "Lanczos6 抗振铃")
        case ScalingMode.anime4kID:
            return tr("Anime4K Upscale & Denoise", "Anime4K 动漫超分降噪")
        case ScalingMode.fsrcnnxID:
            return tr("FSRCNNX 2× Neural", "FSRCNNX 2× 神经网络")
        case ScalingMode.sgsrID:
            return tr("SGSR Fast Upscaler", "SGSR 快速超分")
        case ScalingMode.xbrzID:
            return tr("xBRZ Pixel Art", "xBRZ 像素艺术")
        case ScalingMode.integerScaleID:
            return tr("Integer Scale (Crisp Pixels)", "整数倍像素缩放")
        case ScalingMode.sharpBilinearID:
            return tr("Sharp Bilinear", "锐利双线性")
        case ScalingMode.crtGeomID:
            return tr("CRT-Geom Retro", "CRT-Geom 复古显像管")
        case ScalingMode.bicubicCASID:
            return tr("Bicubic Catmull-Rom + CAS", "双三次 + CAS 锐化")
        default:
            return mode.name
        }
    }

    public func builtInModeDescription(_ mode: ScalingMode) -> String {
        guard mode.isBuiltIn else { return mode.localizedDescription }
        switch mode.id {
        case ScalingMode.metalFXSpatialID:
            return tr(
                "Apple Silicon hardware spatial upscaling — fast, crisp, and HDR-capable.",
                "Apple Silicon 原生硬件空间超分，高速锐利并完整支持 HDR/EDR。"
            )
        case ScalingMode.fsr1ID:
            return tr(
                "AMD FidelityFX Super Resolution 1.0 edge-adaptive upscaling with contrast sharpening.",
                "AMD FidelityFX 1.0 边缘自适应超分搭配抗噪对比度锐化。"
            )
        case ScalingMode.appleMLSuperResID:
            return tr(
                "VideoToolbox low-latency Neural Engine super resolution (macOS 26+).",
                "基于 VideoToolbox 神经网络引擎的低延迟超分（macOS 26+）。"
            )
        case ScalingMode.lanczos6ID:
            return tr(
                "Balanced 6-tap Lanczos filter with anti-ringing clamp for clean UI and games.",
                "6 采样点抗振铃 Lanczos 滤波器，兼顾游戏画面与清晰文字界面。"
            )
        case ScalingMode.anime4kID:
            return tr(
                "2x neural upscaling and denoising tailored for anime and 2D visual novels.",
                "专为动漫、视觉小说与二维游戏优化的 2× 神经网络超分与降噪。"
            )
        case ScalingMode.fsrcnnxID:
            return tr(
                "Multi-pass 2x convolutional neural upscaler for high-detail artwork and games.",
                "多层 2× 卷积神经网络超分，保留精细纹理与清晰线条。"
            )
        case ScalingMode.sgsrID:
            return tr(
                "Single-pass edge-directed upscaler designed for ultra-low GPU power draw.",
                "单通道边缘导向超分，极低 GPU 功耗与超高帧率表现。"
            )
        case ScalingMode.xbrzID:
            return tr(
                "Vectorized perceptual pixel-art smoothing at arbitrary scale ratios.",
                "矢量感知像素画平滑放大，支持任意缩放倍率。"
            )
        case ScalingMode.integerScaleID:
            return tr(
                "Exact whole-number pixel-perfect scaling using Nearest Neighbor.",
                "精确整数倍点采样缩放，还原零模糊像素颗粒。"
            )
        case ScalingMode.sharpBilinearID:
            return tr(
                "Shimmer-free crisp pixel art scaling that fills non-integer display sizes.",
                "非整数倍率下保持像素锐利且无滚动闪烁。"
            )
        case ScalingMode.crtGeomID:
            return tr(
                "Retro CRT scanlines and phosphor dot mask for classic console and arcade games.",
                "经典街机与主机 CRT 扫描线与荧光点栅模拟。"
            )
        case ScalingMode.bicubicCASID:
            return tr(
                "Smooth Catmull-Rom cubic interpolation paired with Contrast Adaptive Sharpening.",
                "平滑 Catmull-Rom 双三次插值结合 CAS 对比度自适应锐化。"
            )
        default:
            return mode.localizedDescription
        }
    }

    public func scalingType(_ type: ScalingType) -> String {
        switch type {
        case .fit: return tr("Fit (Aspect)", "等比适应 (Fit)")
        case .fill: return tr("Fill (Cover)", "等比填充 (Fill)")
        case .stretch: return tr("Stretch", "拉伸填满 (Stretch)")
        case .integerFit: return tr("Integer Fit", "整数倍适应")
        case .normal: return tr("Multiplier", "相对倍率 (Normal)")
        case .absolute: return tr("Absolute (px)", "绝对像素 (Absolute)")
        }
    }

    public func multiMonitorMode(_ mode: MultiMonitorMode) -> String {
        switch mode {
        case .closest: return tr("Closest Display", "所在显示器")
        case .intersected: return tr("Intersected Displays", "跨屏相交显示器")
        case .all: return tr("All Displays", "所有显示器")
        }
    }

    public func outputAlignment(_ alignment: OutputAlignment) -> String {
        switch alignment {
        case .topLeft: return tr("Top Left", "左上")
        case .top: return tr("Top Center", "顶部居中")
        case .topRight: return tr("Top Right", "右上")
        case .left: return tr("Center Left", "左侧居中")
        case .center: return tr("Center", "正中")
        case .right: return tr("Center Right", "右侧居中")
        case .bottomLeft: return tr("Bottom Left", "左下")
        case .bottom: return tr("Bottom Center", "底部居中")
        case .bottomRight: return tr("Bottom Right", "右下")
        }
    }

    public func pixelFormat(_ fmt: CapturePixelFormat) -> String {
        switch fmt {
        case .bgra8: return tr("8-bit BGRA (Standard SDR)", "8-bit BGRA（标准 SDR）")
        case .rgb10a2: return tr("10-bit RGB10A2 (Wide Color)", "10-bit RGB10A2（广色域）")
        case .rgba16f: return tr("16-bit Float RGBA16F (HDR/EDR)", "16-bit 浮点 RGBA16F（HDR/EDR）")
        case .nv12: return tr("NV12 4:2:0 (Video / ANE)", "NV12 4:2:0（视频/神经引擎）")
        }
    }

    public func dynamicRange(_ mode: DynamicRangeMode) -> String {
        switch mode {
        case .sdr: return tr("SDR (Standard Dynamic Range)", "SDR（标准动态范围）")
        case .hdr: return tr("HDR / EDR (macOS 15+)", "HDR / EDR 高动态范围（macOS 15+）")
        }
    }

    public func duplicateFrameMode(_ mode: DuplicateFrameMode) -> String {
        switch mode {
        case .dynamic: return tr("Dynamic (Recommended)", "动态自适应（推荐）")
        case .always: return tr("Always Check", "始终检测跳过")
        case .never: return tr("Never (Disabled)", "关闭检测")
        }
    }

    public func frameGenBackend(_ backend: FrameGenBackend) -> String {
        switch backend {
        case .auto: return tr("Auto (Apple ML ANE -> Optical Flow)", "自动（优先 Apple ML 神经引擎）")
        case .videoToolboxML: return tr("VideoToolbox ML (ANE, macOS 26+)", "VideoToolbox ML 神经引擎（macOS 26+）")
        case .metalOpticalFlow: return tr("Metal Compute Optical Flow", "Metal 计算着色器光流")
        }
    }

    public func artifactGuard(_ sensitivity: ArtifactGuardSensitivity) -> String {
        switch sensitivity {
        case .off: return tr("Off", "关闭")
        case .balanced: return tr("Balanced", "均衡")
        case .strong: return tr("Strong", "强力抑制")
        }
    }

    public func cursorScaleMode(_ mode: CursorScaleMode) -> String {
        switch mode {
        case .source: return tr("Match Source Scale", "跟随窗口缩放倍率")
        case .multiplier: return tr("Custom Multiplier", "自定义倍率")
        case .fixed: return tr("Fixed 1× Native", "固定 1× 原生大小")
        }
    }

    public func cursorInterpolation(_ interp: CursorInterpolation) -> String {
        switch interp {
        case .nearest: return tr("Nearest (Crisp Pixel)", "邻近采样（锐利像素）")
        case .bilinear: return tr("Bilinear (Smooth)", "双线性（平滑抗锯齿）")
        }
    }

    public func autoScaleMode(_ mode: AutoScaleMode) -> String {
        switch mode {
        case .disabled: return tr("Disabled", "关闭")
        case .fullscreen: return tr("Auto Fullscreen", "自动全屏缩放")
        case .windowed: return tr("Auto Windowed", "自动窗口缩放")
        }
    }

    public func toolbarMode(_ mode: ToolbarMode) -> String {
        switch mode {
        case .off: return tr("Off", "隐藏")
        case .autoHide: return tr("Auto-Hide (Hover Top)", "自动隐藏（悬停顶部显示）")
        case .alwaysShow: return tr("Always Show", "始终显示")
        }
    }

    public func sessionState(_ state: SessionState) -> String {
        switch state {
        case .idle: return tr("Idle", "空闲")
        case .countingDown: return tr("Countdown", "倒计时中")
        case .starting: return tr("Starting…", "正在启动…")
        case .running: return tr("Scaling Active", "正在缩放")
        case .suspended: return tr("Suspended (Unfocused)", "已挂起（窗口失焦）")
        case .waitingForWindow: return tr("Waiting for Restore…", "等待窗口恢复…")
        case .stopping: return tr("Stopping…", "正在停止…")
        case .error: return tr("Error", "异常")
        }
    }

    public func hotkeyAction(_ action: HotkeyAction) -> String {
        switch action {
        case .toggleFullscreen: return tr("Toggle Fullscreen Scaling", "切换全屏缩放")
        case .toggleWindowed: return tr("Toggle Windowed Scaling", "切换窗口缩放")
        case .toggleToolbar: return tr("Toggle Floating Toolbar", "切换悬浮工具栏")
        case .captureScreenshot: return tr("Capture Cursor-Free Screenshot", "捕获无光标高清截图")
        case .panicStop: return tr("Emergency Panic Stop (Reserved)", "紧急熔断停止（系统保留）")
        }
    }

    public func logCategory(_ category: LogCategory) -> String {
        switch category {
        case .capture: return tr("Capture", "捕获")
        case .render: return tr("Render", "渲染")
        case .shader: return tr("Shader", "着色器")
        case .cursor: return tr("Cursor", "光标")
        case .input: return tr("Input", "输入")
        case .profile: return tr("Profile", "配置")
        case .app: return tr("App", "应用")
        }
    }
}
