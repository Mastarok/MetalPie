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
        case .fit: return tr("Fit", "等比适应")
        case .fill: return tr("Fill", "等比填充")
        case .stretch: return tr("Stretch", "拉伸")
        case .integerFit: return tr("Integer", "整数倍")
        case .normal: return tr("Relative", "相对倍率")
        case .absolute: return tr("Absolute", "绝对像素")
        }
    }

    public func multiMonitorMode(_ mode: MultiMonitorMode) -> String {
        switch mode {
        case .closest: return tr("Window's Display", "所在屏幕")
        case .intersected: return tr("Intersected Displays", "跨越屏幕")
        case .all: return tr("All Displays", "全部屏幕")
        }
    }

    public func outputAlignment(_ alignment: OutputAlignment) -> String {
        switch alignment {
        case .topLeft: return tr("Top Left", "左上")
        case .top: return tr("Top", "上")
        case .topRight: return tr("Top Right", "右上")
        case .left: return tr("Left", "左")
        case .center: return tr("Center", "居中")
        case .right: return tr("Right", "右")
        case .bottomLeft: return tr("Bottom Left", "左下")
        case .bottom: return tr("Bottom", "下")
        case .bottomRight: return tr("Bottom Right", "右下")
        }
    }

    public func pixelFormat(_ fmt: CapturePixelFormat) -> String {
        switch fmt {
        case .bgra8: return "BGRA8 (SDR)"
        case .rgb10a2: return "RGB10A2 (10-bit)"
        case .rgba16f: return "RGBA16F (HDR)"
        case .nv12: return "NV12"
        }
    }

    public func dynamicRange(_ mode: DynamicRangeMode) -> String {
        switch mode {
        case .sdr: return "SDR"
        case .hdr: return "HDR"
        }
    }

    public func duplicateFrameMode(_ mode: DuplicateFrameMode) -> String {
        switch mode {
        case .dynamic: return tr("Dynamic", "动态")
        case .always: return tr("Always", "始终")
        case .never: return tr("Off", "关闭")
        }
    }

    public func frameGenBackend(_ backend: FrameGenBackend) -> String {
        switch backend {
        case .auto: return tr("Auto", "自动")
        case .videoToolboxML: return "VideoToolbox ML"
        case .metalOpticalFlow: return tr("Metal Optical Flow", "Metal 光流")
        }
    }

    public func artifactGuard(_ sensitivity: ArtifactGuardSensitivity) -> String {
        switch sensitivity {
        case .off: return tr("Off", "关闭")
        case .balanced: return tr("Balanced", "均衡")
        case .strong: return tr("Strong", "强")
        }
    }

    public func cursorScaleMode(_ mode: CursorScaleMode) -> String {
        switch mode {
        case .source: return tr("Match Scale", "跟随缩放")
        case .multiplier: return tr("Custom", "自定义")
        case .fixed: return tr("Original (1×)", "原始大小")
        }
    }

    public func cursorInterpolation(_ interp: CursorInterpolation) -> String {
        switch interp {
        case .nearest: return tr("Nearest", "最近邻")
        case .bilinear: return tr("Bilinear", "双线性")
        }
    }

    public func autoScaleMode(_ mode: AutoScaleMode) -> String {
        switch mode {
        case .disabled: return tr("Off", "关闭")
        case .fullscreen: return tr("Fullscreen", "全屏")
        case .windowed: return tr("Windowed", "窗口")
        }
    }

    public func toolbarMode(_ mode: ToolbarMode) -> String {
        switch mode {
        case .off: return tr("Hidden", "隐藏")
        case .autoHide: return tr("Auto-Hide", "自动隐藏")
        case .alwaysShow: return tr("Always Show", "始终显示")
        }
    }

    public func sessionState(_ state: SessionState) -> String {
        switch state {
        case .idle: return tr("Idle", "待机")
        case .countingDown: return tr("Countdown", "倒计时")
        case .starting: return tr("Starting", "启动中")
        case .running: return tr("Active", "运行中")
        case .suspended: return tr("Paused", "已暂停")
        case .waitingForWindow: return tr("Waiting", "等待恢复")
        case .stopping: return tr("Stopping", "停止中")
        case .error: return tr("Error", "错误")
        }
    }

    public func hotkeyAction(_ action: HotkeyAction) -> String {
        switch action {
        case .toggleFullscreen: return tr("Fullscreen Scale", "全屏缩放")
        case .toggleWindowed: return tr("Windowed Scale", "窗口缩放")
        case .toggleToolbar: return tr("Toolbar", "工具栏")
        case .captureScreenshot: return tr("Screenshot", "截图")
        case .panicStop: return tr("Force Exit", "强制退出")
        }
    }

    public func logCategory(_ category: LogCategory) -> String {
        switch category {
        case .capture: return tr("Capture", "采集")
        case .render: return tr("Render", "渲染")
        case .shader: return tr("Shader", "着色器")
        case .cursor: return tr("Cursor", "光标")
        case .input: return tr("Input", "输入")
        case .profile: return tr("Profile", "配置")
        case .app: return tr("App", "应用")
        }
    }
}
