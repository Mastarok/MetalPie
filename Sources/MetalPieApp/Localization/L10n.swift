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

    public func scenarioTag(_ tag: ScenarioTag) -> String {
        isChinese ? tag.labelZH : tag.labelEN
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

    /// Resolves the canonical built-in preset definition (so upgraded v1.0 configs always display
    /// up-to-date English & Chinese names like `Anime4K Mode A (Recommended · Restore)`).
    public func builtInModeName(_ mode: ScalingMode) -> String {
        let resolved = mode.isBuiltIn
            ? (ScalingMode.builtInPresets.first(where: { $0.id == mode.id }) ?? mode)
            : mode
        return resolved.displayName(isChinese: isChinese)
    }

    /// Resolves the canonical built-in preset description for both English and Chinese.
    public func builtInModeDescription(_ mode: ScalingMode) -> String {
        let resolved = mode.isBuiltIn
            ? (ScalingMode.builtInPresets.first(where: { $0.id == mode.id }) ?? mode)
            : mode
        return resolved.displayDescription(isChinese: isChinese)
    }

    public func scalingType(_ type: ScalingType) -> String {
        switch type {
        case .fit: return tr("Fit (Keep Aspect)", "等比缩放（保留比例）")
        case .fill: return tr("Fill (Crop Edges)", "等比铺满（裁切边缘）")
        case .stretch: return tr("Stretch to Fill", "拉伸铺满")
        case .integerFit: return tr("Integer Scale", "整数倍缩放（像素最清晰）")
        case .normal: return tr("Relative Multiplier", "按倍率缩放")
        case .absolute: return tr("Fixed Size (px)", "指定像素大小")
        }
    }

    public func multiMonitorMode(_ mode: MultiMonitorMode) -> String {
        switch mode {
        case .closest: return tr("Window's Display (Recommended)", "窗口所在显示器（推荐）")
        case .intersected: return tr("Displays Crossed by Window", "窗口跨过的显示器")
        case .all: return tr("Span All Displays", "横跨全部显示器")
        }
    }

    public func outputAlignment(_ alignment: OutputAlignment) -> String {
        switch alignment {
        case .topLeft: return tr("Top Left", "左上")
        case .top: return tr("Top Center", "顶部居中")
        case .topRight: return tr("Top Right", "右上")
        case .left: return tr("Center Left", "左侧居中")
        case .center: return tr("Center", "居中")
        case .right: return tr("Center Right", "右侧居中")
        case .bottomLeft: return tr("Bottom Left", "左下")
        case .bottom: return tr("Bottom Center", "底部居中")
        case .bottomRight: return tr("Bottom Right", "右下")
        }
    }

    public func pixelFormat(_ fmt: CapturePixelFormat) -> String {
        switch fmt {
        case .bgra8: return tr("Standard SDR (8-bit, Recommended)", "标准 SDR（8-bit，推荐）")
        case .rgb10a2: return tr("10-bit Wide Color", "10-bit 广色域")
        case .rgba16f: return tr("HDR High Dynamic Range (16-bit)", "HDR 高动态范围（16-bit）")
        case .nv12: return tr("Video / Apple ML Format (NV12)", "视频 / 芯片加速格式 (NV12)")
        }
    }

    public func dynamicRange(_ mode: DynamicRangeMode) -> String {
        switch mode {
        case .sdr: return tr("Standard SDR", "标准 SDR")
        case .hdr: return tr("HDR High Dynamic Range (macOS 15+)", "HDR 高动态范围（macOS 15+）")
        }
    }

    public func duplicateFrameMode(_ mode: DuplicateFrameMode) -> String {
        switch mode {
        case .dynamic: return tr("Auto Power-Saving (Recommended)", "自动省电（推荐）")
        case .always: return tr("Always Skip Static Frames", "始终跳过静止画面")
        case .never: return tr("Off (Render Every Frame)", "关闭（逐帧渲染）")
        }
    }

    public func frameGenBackend(_ backend: FrameGenBackend) -> String {
        switch backend {
        case .auto: return tr("Auto (Apple Silicon Hardware First)", "自动（优先 Apple 芯片硬件）")
        case .videoToolboxML: return tr("Apple Silicon Hardware (macOS 26+)", "Apple 芯片硬件补帧（macOS 26+）")
        case .metalOpticalFlow: return tr("Metal Optical Flow", "Metal 光流补帧")
        }
    }

    public func artifactGuard(_ sensitivity: ArtifactGuardSensitivity) -> String {
        switch sensitivity {
        case .off: return tr("Off", "关闭")
        case .balanced: return tr("Balanced", "均衡")
        case .strong: return tr("Strong", "强力防鬼影")
        }
    }

    public func cursorScaleMode(_ mode: CursorScaleMode) -> String {
        switch mode {
        case .source: return tr("Match Window Scale (Recommended)", "随画面自动放大（推荐）")
        case .multiplier: return tr("Custom Size", "自定义大小")
        case .fixed: return tr("Original 1× Size", "保持系统原始大小")
        }
    }

    public func cursorInterpolation(_ interp: CursorInterpolation) -> String {
        switch interp {
        case .nearest: return tr("Crisp Pixel", "锐利像素")
        case .bilinear: return tr("Smooth", "平滑清晰")
        }
    }

    public func autoScaleMode(_ mode: AutoScaleMode) -> String {
        switch mode {
        case .disabled: return tr("Off", "关闭")
        case .fullscreen: return tr("Auto Fullscreen", "切到窗口时自动全屏放大")
        case .windowed: return tr("Auto Windowed", "切到窗口时自动窗口放大")
        }
    }

    public func toolbarMode(_ mode: ToolbarMode) -> String {
        switch mode {
        case .off: return tr("Hidden", "隐藏")
        case .autoHide: return tr("Auto-Hide (Hover Top Edge)", "自动隐藏（鼠标移到顶部显示）")
        case .alwaysShow: return tr("Always Visible", "始终显示")
        }
    }

    public func sessionState(_ state: SessionState) -> String {
        switch state {
        case .idle: return tr("Ready", "待机中")
        case .countingDown: return tr("Counting Down", "倒计时中")
        case .starting: return tr("Starting…", "正在启动…")
        case .running: return tr("Scaling Active", "正在放大")
        case .suspended: return tr("Paused (Unfocused)", "已暂停（窗口已切走）")
        case .waitingForWindow: return tr("Waiting for Restore…", "窗口已最小化，等待恢复…")
        case .stopping: return tr("Stopping…", "正在退出…")
        case .error: return tr("Error", "出错")
        }
    }

    public func hotkeyAction(_ action: HotkeyAction) -> String {
        switch action {
        case .toggleFullscreen: return tr("Fullscreen Scale / Exit", "全屏放大 / 退出")
        case .toggleWindowed: return tr("Windowed Scale / Exit", "窗口放大 / 退出")
        case .toggleToolbar: return tr("Show / Hide Floating Toolbar", "显示 / 隐藏顶部工具栏")
        case .captureScreenshot: return tr("Cursor-Free Screenshot", "无光标高清截图")
        case .panicStop: return tr("Force Exit Scaling (System Reserved)", "强制退出缩放（系统保留，随时可用）")
        }
    }

    public func logCategory(_ category: LogCategory) -> String {
        switch category {
        case .capture: return tr("Capture", "画面采集")
        case .render: return tr("Render", "画面渲染")
        case .shader: return tr("Shader", "画质算法")
        case .cursor: return tr("Cursor", "鼠标光标")
        case .input: return tr("Input", "快捷键与窗口")
        case .profile: return tr("Profile", "配置文件")
        case .app: return tr("App", "应用")
        }
    }
}
