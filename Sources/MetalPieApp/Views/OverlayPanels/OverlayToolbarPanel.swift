import AppKit
import Foundation
import MetalPieCapture
import MetalPieCore
import SwiftUI

/// Non-activating borderless `NSPanel` base used for MetalPie's floating overlay chrome
/// (toolbar, profiler HUD, and toast notifications).
@MainActor
final class NonActivatingChromePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Allows multi-monitor placement on displays with negative CG Y or non-primary coordinates
    /// without AppKit clamping or shifting the panel onto the primary display or below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

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
        // Disable WindowServer's rectangular borderless shadow; SwiftUI draws rounded shadows
        // inside a padded transparent canvas so no rectangular box appears around rounded corners.
        hasShadow = false
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
    private var autoHideState = OverlayToolbarAutoHideState()
    private var hoverTimer: Timer?
    private var currentLevel = NSWindow.Level(
        rawValue: OverlayWindowController.fullscreenOverlayLevel.rawValue + 2
    )

    public static let toolbarSize = OverlayChromeGeometry.defaultToolbarSize
    /// Transparent outer padding reserved for SwiftUI drop shadow bleed (prevents rectangular clipping).
    public static let shadowPadding: CGFloat = OverlayChromeGeometry.defaultShadowPadding
    private static let topMargin: CGFloat = OverlayChromeGeometry.defaultTopMargin
    private static let notchSafeTopMargin: CGFloat = OverlayChromeGeometry.notchSafeTopMargin

    /// Optional provider returning the active scaled cursor position in global Cocoa coordinates
    /// when `CGEventTap` confines the physical pointer inside the source window.
    public var scaledCursorCocoaProvider: (@MainActor () -> CGPoint?)?

    /// Fired whenever the toolbar's visible interactive Cocoa frame appears, moves, or hides.
    public var onInteractiveFrameChanged: (@MainActor () -> Void)?

    public init() {}

    public var windowID: CGWindowID? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    public var nsWindow: NSWindow? { panel }

    public var isShown: Bool { autoHideState.isShown }
    public var isRevealedByHover: Bool { autoHideState.isRevealedByHover }

    /// Exact visible pill rect in global AppKit (Cocoa Y-up) coordinates excluding transparent
    /// shadow bleed padding, or `nil` when hidden / auto-hidden.
    public var visibleInteractiveCocoaFrame: CGRect? {
        guard panel != nil else { return nil }
        return autoHideState.visibleInteractiveCocoaFrame
    }

    /// Strips the transparent shadow bleed margin from a panel frame to recover the visible pill frame.
    public static func visibleFrame(fromPanelFrame panelFrame: CGRect) -> CGRect {
        OverlayChromeGeometry.visibleFrame(fromPanelFrame: panelFrame, shadowPadding: shadowPadding)
    }

    /// Expands a visible pill frame by `shadowPadding` on all sides so SwiftUI drop shadows never clip.
    public static func panelFrame(fromVisibleFrame visibleFrame: CGRect) -> CGRect {
        OverlayChromeGeometry.panelFrame(fromVisibleFrame: visibleFrame, shadowPadding: shadowPadding)
    }

    /// Computes the visible toolbar pill frame in global AppKit (Y-up) coordinates, clamping cleanly
    /// below the macOS Menu Bar and MacBook Pro camera notch whenever `overlayFrame` extends into them.
    public static func computeVisibleToolbarCocoaFrame(
        for overlayFrame: CGRect,
        hostScreenVisibleFrame: CGRect?
    ) -> CGRect {
        OverlayChromeGeometry.computeVisibleToolbarCocoaFrame(
            for: overlayFrame,
            hostScreenVisibleFrame: hostScreenVisibleFrame,
            toolbarSize: toolbarSize,
            topMargin: topMargin,
            notchSafeTopMargin: notchSafeTopMargin
        )
    }

    public func configure(actions: OverlayToolbarActions) {
        self.actions = actions
    }

    /// Updates ONLY the panel's window level without modifying visibility, hover state, or frame.
    public func setLevel(_ level: NSWindow.Level) {
        currentLevel = level
        if let panel, panel.level != level {
            panel.level = level
        }
    }

    public func show(
        mode: ToolbarMode,
        overlayCocoaFrame: CGRect,
        level: NSWindow.Level
    ) {
        self.currentLevel = level

        guard mode != .off, !overlayCocoaFrame.isEmpty else {
            hide()
            return
        }

        let visiblePill = Self.computeVisibleToolbarCocoaFrame(
            for: overlayCocoaFrame,
            hostScreenVisibleFrame: hostScreenVisibleFrame(for: overlayCocoaFrame)
        )
        let targetFrame = Self.panelFrame(fromVisibleFrame: visiblePill)
        let activePanel = ensurePanel(frame: targetFrame)
        let transition = autoHideState.beginShow(
            mode: mode,
            overlayCocoaFrame: overlayCocoaFrame,
            visibleToolbarFrame: visiblePill
        )

        if transition.shouldHide {
            hide()
            return
        }

        if activePanel.level != level {
            activePanel.level = level
        }
        if OverlayToolbarAutoHideState.framesDiffer(activePanel.frame, targetFrame) {
            activePanel.setFrame(targetFrame, display: false, animate: false)
        }

        if !transition.isIdempotentUpdate {
            if transition.shouldStopHoverTimer {
                stopHoverTimer()
            }
            if transition.shouldRevealAlwaysShow {
                activePanel.ignoresMouseEvents = false
                activePanel.alphaValue = 1.0
                activePanel.orderFrontRegardless()
            } else if transition.shouldResetAutoHideHidden {
                activePanel.ignoresMouseEvents = true
                activePanel.alphaValue = 0.0
                activePanel.orderFrontRegardless()
            }
            if transition.shouldStartHoverTimer {
                startHoverTimer()
            }
        }

        if transition.interactiveFrameChanged {
            onInteractiveFrameChanged?()
        }
    }

    public func updateOverlayFrame(_ overlayCocoaFrame: CGRect, level: NSWindow.Level? = nil) {
        if let level {
            setLevel(level)
        }
        guard autoHideState.isShown, let panel, !overlayCocoaFrame.isEmpty else { return }
        let visiblePill = Self.computeVisibleToolbarCocoaFrame(
            for: overlayCocoaFrame,
            hostScreenVisibleFrame: hostScreenVisibleFrame(for: overlayCocoaFrame)
        )
        let frame = Self.panelFrame(fromVisibleFrame: visiblePill)
        let interactiveChanged = autoHideState.updateOverlayFrame(
            overlayCocoaFrame,
            visibleToolbarFrame: visiblePill
        )
        if OverlayToolbarAutoHideState.framesDiffer(panel.frame, frame) {
            panel.setFrame(frame, display: false, animate: false)
        }
        if interactiveChanged {
            onInteractiveFrameChanged?()
        }
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
        let interactiveChanged = autoHideState.hide()
        stopHoverTimer()
        panel?.orderOut(nil)
        if interactiveChanged {
            onInteractiveFrameChanged?()
        }
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
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        created.contentView = host
        self.panel = created
        return created
    }

    private func hostScreenVisibleFrame(for overlayFrame: CGRect) -> CGRect? {
        let bestScreen = NSScreen.screens.max { lhs, rhs in
            let lArea = lhs.frame.intersection(overlayFrame).area
            let rArea = rhs.frame.intersection(overlayFrame).area
            return lArea < rArea
        }
        if let bestScreen, bestScreen.frame.intersects(overlayFrame) {
            return bestScreen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
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
        guard let panel else { return }
        let eval = autoHideState.evaluateAutoHideHover(
            physicalCocoaPoint: NSEvent.mouseLocation,
            scaledCocoaPoint: scaledCursorCocoaProvider?(),
            now: CFAbsoluteTimeGetCurrent()
        )
        switch eval.action {
        case .none:
            break
        case .reveal:
            panel.ignoresMouseEvents = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 1.0
            }
        case .hide:
            panel.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                panel.animator().alphaValue = 0.0
            }
        }
        if eval.interactiveFrameChanged {
            onInteractiveFrameChanged?()
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
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
                        ? l10n.tr("Unlock Window", "解锁窗口")
                        : l10n.tr("Lock Window", "锁定窗口")
                ) {
                    actionsProvider()?.onToggleClickThrough()
                }
            }

            // Profiler HUD toggle
            toolbarIconButton(
                symbol: "chart.bar.xaxis",
                active: state.isProfilerVisible,
                helpText: l10n.tr("Profiler", "监视器")
            ) {
                actionsProvider()?.onToggleProfilerHUD()
            }

            // Cursor-Free Screenshot
            toolbarIconButton(
                symbol: "camera.fill",
                active: false,
                helpText: l10n.tr("Screenshot", "截图")
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
                        ? l10n.tr("Windowed", "窗口")
                        : l10n.tr("Fullscreen", "全屏")
                ) {
                    actionsProvider()?.onTogglePresentationMode()
                }
            }

            // Pause / Resume
            toolbarIconButton(
                symbol: state.isPaused ? "play.fill" : "pause.fill",
                active: state.isPaused,
                helpText: state.isPaused
                    ? l10n.tr("Resume", "继续")
                    : l10n.tr("Pause", "暂停")
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
            .help(l10n.tr("Stop (⌃⌥⌘⎋)", "停止 (⌃⌥⌘⎋)"))
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
        .padding(OverlayToolbarPanel.shadowPadding)
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
