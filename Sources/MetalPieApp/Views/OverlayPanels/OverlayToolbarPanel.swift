import AppKit
import Foundation
import MetalPieCore
import SwiftUI

/// Non-activating borderless `NSPanel` base used for MetalPie's floating overlay chrome
/// (toolbar, profiler HUD, and toast notifications).
@MainActor
final class NonActivatingChromePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init(globalCocoaRect: CGRect, ignoresMouseEvents: Bool = false) {
        self.init(
            contentRect: globalCocoaRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: nil
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        self.ignoresMouseEvents = ignoresMouseEvents
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }
}

/// Observable state driving the floating top-center overlay toolbar.
@Observable
@MainActor
public final class OverlayToolbarState {
    public var language: AppLanguage = .system
    public var presentedFPS: Double = 0
    public var outputFPS: Double = 0
    public var isFullscreen: Bool = true
    public var isWindowedClickThrough: Bool = true
    public var isProfilerVisible: Bool = false
    public var isPaused: Bool = false
    public var frameGenActive: Bool = false
    public var frameGenMultiplier: Int = 1
    public var canToggleWindowed: Bool = true
}

/// Callbacks wired from `OverlayToolbarPanel` back into `AppCoordinator`.
public struct OverlayToolbarActions: Sendable {
    public var onToggleClickThrough: @MainActor () -> Void
    public var onToggleProfilerHUD: @MainActor () -> Void
    public var onCaptureScreenshot: @MainActor () -> Void
    public var onTogglePresentationMode: @MainActor () -> Void
    public var onTogglePause: @MainActor () -> Void
    public var onStopScaling: @MainActor () -> Void
}

/// Floating, proximity-fading top-center overlay toolbar (`Off` / `AutoHide` / `AlwaysShow`).
///
/// Features Fitts's-law top-edge proximity detection so moving the cursor to the top edge of the
/// scaled display smoothly reveals the controls without stealing focus from the running game/app.
@MainActor
public final class OverlayToolbarPanel {
    private var panel: NonActivatingChromePanel?
    private let state = OverlayToolbarState()
    private var actions: OverlayToolbarActions?
    private var mode: ToolbarMode = .autoHide
    private var anchorOverlayFrame: CGRect = .zero
    private var hoverTimer: Timer?
    private var isShown = false
    private var isRevealedByHover = false
    private var lastHoverLeaveTime: CFAbsoluteTime = 0
    private var currentLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)

    private static let toolbarSize = CGSize(width: 420, height: 42)
    private static let topMargin: CGFloat = 10
    private static let fittsTopStripHeight: CGFloat = 28

    public init() {}

    public var windowID: CGWindowID? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    public var nsWindow: NSWindow? { panel }

    public func configure(actions: OverlayToolbarActions) {
        self.actions = actions
    }

    public func show(
        mode: ToolbarMode,
        overlayCocoaFrame: CGRect,
        level: NSWindow.Level
    ) {
        self.mode = mode
        self.anchorOverlayFrame = overlayCocoaFrame
        self.currentLevel = level

        guard mode != .off, !overlayCocoaFrame.isEmpty else {
            hide()
            return
        }

        let targetFrame = computeToolbarFrame(for: overlayCocoaFrame)
        let activePanel = ensurePanel(frame: targetFrame)
        activePanel.level = level
        activePanel.setFrame(targetFrame, display: false, animate: false)
        isShown = true

        switch mode {
        case .off:
            hide()
        case .alwaysShow:
            stopHoverTimer()
            activePanel.ignoresMouseEvents = false
            activePanel.alphaValue = 1.0
            activePanel.orderFrontRegardless()
        case .autoHide:
            isRevealedByHover = false
            activePanel.ignoresMouseEvents = true
            activePanel.alphaValue = 0.0
            activePanel.orderFrontRegardless()
            startHoverTimer()
        }
    }

    public func updateOverlayFrame(_ overlayCocoaFrame: CGRect, level: NSWindow.Level? = nil) {
        anchorOverlayFrame = overlayCocoaFrame
        if let level {
            currentLevel = level
            panel?.level = level
        }
        guard isShown, let panel, !overlayCocoaFrame.isEmpty else { return }
        let frame = computeToolbarFrame(for: overlayCocoaFrame)
        panel.setFrame(frame, display: false, animate: false)
    }

    public func updateState(
        language: AppLanguage,
        telemetry: SessionTelemetry,
        isFullscreen: Bool,
        isWindowedClickThrough: Bool,
        isProfilerVisible: Bool,
        isPaused: Bool,
        canToggleWindowed: Bool
    ) {
        state.language = language
        state.presentedFPS = telemetry.presentedFPS
        state.outputFPS = telemetry.outputFPS
        state.isFullscreen = isFullscreen
        state.isWindowedClickThrough = isWindowedClickThrough
        state.isProfilerVisible = isProfilerVisible
        state.isPaused = isPaused
        state.frameGenActive = telemetry.frameGenActive
        state.frameGenMultiplier = telemetry.frameGenMultiplier
        state.canToggleWindowed = canToggleWindowed
    }

    public func hide() {
        isShown = false
        isRevealedByHover = false
        stopHoverTimer()
        panel?.orderOut(nil)
    }

    public func close() {
        hide()
        panel?.close()
        panel = nil
    }

    private func ensurePanel(frame: CGRect) -> NonActivatingChromePanel {
        if let panel { return panel }
        let created = NonActivatingChromePanel(globalCocoaRect: frame, ignoresMouseEvents: false)
        created.level = currentLevel
        let content = OverlayToolbarSwiftUIView(state: state) { [weak self] in
            self?.actions
        }
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        created.contentView = host
        self.panel = created
        return created
    }

    private func computeToolbarFrame(for overlayFrame: CGRect) -> CGRect {
        let w = min(Self.toolbarSize.width, max(380, overlayFrame.width - 16))
        let h = Self.toolbarSize.height
        let x = (overlayFrame.midX - w * 0.5).rounded()
        let y = (overlayFrame.maxY - h - Self.topMargin).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func startHoverTimer() {
        stopHoverTimer()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateAutoHideHover()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func stopHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func evaluateAutoHideHover() {
        guard isShown, mode == .autoHide, let panel else { return }
        let mouse = NSEvent.mouseLocation
        let topStrip = CGRect(
            x: anchorOverlayFrame.midX - Self.toolbarSize.width * 0.65,
            y: anchorOverlayFrame.maxY - Self.fittsTopStripHeight,
            width: Self.toolbarSize.width * 1.3,
            height: Self.fittsTopStripHeight + 8
        )
        let expandedToolbar = panel.frame.insetBy(dx: -16, dy: -12)
        let hovering = topStrip.contains(mouse) || (isRevealedByHover && expandedToolbar.contains(mouse))

        if hovering {
            lastHoverLeaveTime = 0
            if !isRevealedByHover {
                isRevealedByHover = true
                panel.ignoresMouseEvents = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    panel.animator().alphaValue = 1.0
                }
            }
        } else if isRevealedByHover {
            let now = CFAbsoluteTimeGetCurrent()
            if lastHoverLeaveTime == 0 {
                lastHoverLeaveTime = now
            } else if now - lastHoverLeaveTime >= 0.85 {
                isRevealedByHover = false
                lastHoverLeaveTime = 0
                panel.ignoresMouseEvents = true
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    panel.animator().alphaValue = 0.0
                }
            }
        }
    }
}

private struct OverlayToolbarSwiftUIView: View {
    let state: OverlayToolbarState
    let actionsProvider: @MainActor () -> OverlayToolbarActions?

    var body: some View {
        let l10n = L10n(language: state.language)
        let fps = state.presentedFPS > 0.5 ? state.presentedFPS : state.outputFPS

        HStack(spacing: 8) {
            // Live FPS Pill
            HStack(spacing: 5) {
                Circle()
                    .fill(state.isPaused ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text(String(format: "%.0f FPS", fps))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if state.frameGenActive && state.frameGenMultiplier > 1 {
                    Text("\(state.frameGenMultiplier)× FG")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.cyan.opacity(0.28), in: Capsule())
                        .foregroundStyle(Color.cyan)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())

            Divider()
                .frame(height: 18)
                .overlay(Color.white.opacity(0.18))

            // Pin / Click-Through (Windowed mode)
            if !state.isFullscreen {
                toolbarIconButton(
                    symbol: state.isWindowedClickThrough ? "lock.fill" : "arrow.up.and.down.and.arrow.left.and.right",
                    active: !state.isWindowedClickThrough,
                    helpText: state.isWindowedClickThrough
                        ? l10n.tr("Unlock Window Drag/Resize", "解锁窗口拖拽与缩放")
                        : l10n.tr("Lock Click-Through", "锁定鼠标穿透")
                ) {
                    actionsProvider()?.onToggleClickThrough()
                }
            }

            // Profiler HUD toggle
            toolbarIconButton(
                symbol: "chart.bar.xaxis",
                active: state.isProfilerVisible,
                helpText: l10n.tr("Toggle Profiler HUD", "切换性能监视 HUD")
            ) {
                actionsProvider()?.onToggleProfilerHUD()
            }

            // Cursor-Free Screenshot
            toolbarIconButton(
                symbol: "camera.fill",
                active: false,
                helpText: l10n.tr("Cursor-Free Screenshot", "捕获无光标截图")
            ) {
                actionsProvider()?.onCaptureScreenshot()
            }

            // Fullscreen <-> Windowed toggle
            if state.canToggleWindowed {
                toolbarIconButton(
                    symbol: state.isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    active: false,
                    helpText: state.isFullscreen
                        ? l10n.tr("Switch to Windowed Scaling", "切换为窗口缩放")
                        : l10n.tr("Switch to Fullscreen Scaling", "切换为全屏缩放")
                ) {
                    actionsProvider()?.onTogglePresentationMode()
                }
            }

            // Pause / Resume
            toolbarIconButton(
                symbol: state.isPaused ? "play.fill" : "pause.fill",
                active: state.isPaused,
                helpText: state.isPaused
                    ? l10n.tr("Resume Scaling", "恢复缩放")
                    : l10n.tr("Pause Scaling", "暂停缩放")
            ) {
                actionsProvider()?.onTogglePause()
            }

            Spacer(minLength: 2)

            // Stop button
            Button {
                actionsProvider()?.onStopScaling()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(l10n.tr("Stop", "停止"))
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(l10n.tr("Stop Scaling (⌃⌥⌘⎋ Panic Stop)", "停止缩放（⌃⌥⌘⎋ 紧急熔断）"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Capsule()
                .fill(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.88))
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    }

    private func toolbarIconButton(
        symbol: String,
        active: Bool,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.cyan : Color.white.opacity(0.92))
                .frame(width: 28, height: 26)
                .background(
                    active ? Color.cyan.opacity(0.22) : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}
