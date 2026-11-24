import AppKit
import Foundation
import MetalPieCore
import SwiftUI

/// Visual style of a floating glass toast notification.
public enum ToastStyle: Sendable {
    case info
    case success
    case warning
    case countdown
}

@Observable
@MainActor
private final class ToastOverlayState {
    var icon: String = "checkmark.circle.fill"
    var title: String = ""
    var subtitle: String? = nil
    var style: ToastStyle = .info
}

/// Non-activating floating dark-glass toast pill with smooth fade-in / auto-dismiss (`2.5s`)
/// and persistent countdown mode for 1–5s Countdown Scale.
@MainActor
public final class ToastOverlayPanel {
    private var panel: NonActivatingChromePanel?
    private let state = ToastOverlayState()
    private var dismissTimer: Timer?
    private var presentationGeneration: UInt64 = 0

    private static let toastWidth: CGFloat = 376
    private static let toastHeight: CGFloat = 68

    public init() {}

    public var windowID: CGWindowID? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    public func show(
        icon: String,
        title: String,
        subtitle: String? = nil,
        style: ToastStyle = .info,
        durationSeconds: TimeInterval? = 2.5,
        anchorScreenFrame: CGRect? = nil
    ) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        presentationGeneration &+= 1

        state.icon = icon
        state.title = title
        state.subtitle = subtitle
        state.style = style

        let targetFrame = computeToastFrame(anchorScreenFrame: anchorScreenFrame)
        let activePanel = ensurePanel(frame: targetFrame)
        activePanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
        activePanel.setFrame(targetFrame, display: true, animate: false)
        activePanel.alphaValue = 0.0
        activePanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            activePanel.animator().alphaValue = 1.0
        }

        if let duration = durationSeconds, duration > 0 {
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.dismissAnimated()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            dismissTimer = timer
        }
    }

    public func dismissAnimated() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel else { return }
        let expectedGeneration = presentationGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, self.presentationGeneration == expectedGeneration else { return }
                panel?.orderOut(nil)
            }
        })
    }

    public func hideImmediately() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        presentationGeneration &+= 1
        panel?.orderOut(nil)
    }

    private func ensurePanel(frame: CGRect) -> NonActivatingChromePanel {
        if let panel { return panel }
        let created = NonActivatingChromePanel(globalCocoaRect: frame, ignoresMouseEvents: true)
        let host = NSHostingView(rootView: ToastPillSwiftUIView(state: state))
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        created.contentView = host
        self.panel = created
        return created
    }

    private func computeToastFrame(anchorScreenFrame: CGRect?) -> CGRect {
        let screenFrame = anchorScreenFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let x = (screenFrame.maxX - Self.toastWidth - 20).rounded()
        let y = (screenFrame.maxY - Self.toastHeight - 20).rounded()
        return CGRect(x: x, y: y, width: Self.toastWidth, height: Self.toastHeight)
    }
}

private struct ToastPillSwiftUIView: View {
    let state: ToastOverlayState

    private var accentColor: Color {
        switch state.style {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .countdown: return .cyan
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let sub = state.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.92))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.45), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
    }
}
