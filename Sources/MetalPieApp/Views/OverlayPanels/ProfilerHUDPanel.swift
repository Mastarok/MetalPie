import AppKit
import CoreGraphics
import Foundation
import MetalPieCore
import SwiftUI

/// Corner anchor used for edge-snapping the floating Profiler HUD panel.
public enum HUDCornerAnchor: String, Sendable, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

/// Observable telemetry holder rendered inside `ProfilerHUDPanel`.
@Observable
@MainActor
public final class ProfilerHUDState {
    public var telemetry: SessionTelemetry = .idle
    public var language: AppLanguage = .system
}

/// Draggable, edge-snapping dark-glass non-activating `NSPanel` displaying real-time GPU
/// performance, resolution, FPS breakdown, proportional pass timeline bar, and per-pass ms.
///
/// Also exposes `renderToCGImage(telemetry:language:)` reusing a single SwiftUI `ImageRenderer`
/// (~0.5 ms) so ProMotion VRR Direct-Scanout mode can composite the exact same HUD directly
/// inside Metal with zero WindowServer sub-windows!
@MainActor
public final class ProfilerHUDPanel {
    private var panel: NonActivatingChromePanel?
    private let state = ProfilerHUDState()
    private var anchorOverlayFrame: CGRect = .zero
    private var corner: HUDCornerAnchor = .topLeft
    private var isShown = false
    private var currentLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)

    /// Reused SwiftUI `ImageRenderer` for ultra-fast VRR Metal HUD compositing (MetalGoose pattern).
    private static var vrrRenderer: ImageRenderer<ProfilerHUDCardView>?

    private static let hudWidth: CGFloat = 296
    private static let edgeMargin: CGFloat = 16
    private static let notchSafeTopMargin: CGFloat = 6
    /// Transparent outer padding reserved for SwiftUI drop shadow bleed (prevents rectangular clipping).
    public static let shadowPadding: CGFloat = 20

    /// Fired whenever the HUD's visible interactive Cocoa frame appears, moves, resizes, or hides.
    public var onInteractiveFrameChanged: (@MainActor () -> Void)?

    public init() {}

    public var windowID: CGWindowID? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    public var nsWindow: NSWindow? { panel }

    public var isVisible: Bool { isShown }

    /// Exact visible HUD card rect in global AppKit (Cocoa Y-up) coordinates excluding transparent
    /// shadow bleed padding, or `nil` when hidden.
    public var visibleInteractiveCocoaFrame: CGRect? {
        guard isShown, let panel else { return nil }
        return Self.visibleFrame(fromPanelFrame: panel.frame)
    }

    public static func visibleFrame(fromPanelFrame panelFrame: CGRect) -> CGRect {
        panelFrame.insetBy(dx: shadowPadding, dy: shadowPadding)
    }

    public static func panelFrame(fromVisibleFrame visibleFrame: CGRect) -> CGRect {
        visibleFrame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
    }

    public static func computeVisibleHUDCocoaFrame(
        for overlayFrame: CGRect,
        cardHeight: CGFloat,
        corner: HUDCornerAnchor,
        hostScreenVisibleFrame: CGRect?
    ) -> CGRect {
        let w = hudWidth
        let h = cardHeight
        let m = edgeMargin
        let safeTopMaxY: CGFloat
        if let visible = hostScreenVisibleFrame, overlayFrame.maxY > visible.maxY {
            safeTopMaxY = visible.maxY - notchSafeTopMargin
        } else {
            safeTopMaxY = overlayFrame.maxY
        }
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft:
            x = overlayFrame.minX + m
            y = max(overlayFrame.minY + m, safeTopMaxY - h - m - 42)
        case .topRight:
            x = overlayFrame.maxX - w - m
            y = max(overlayFrame.minY + m, safeTopMaxY - h - m - 42)
        case .bottomLeft:
            x = overlayFrame.minX + m
            y = overlayFrame.minY + m
        case .bottomRight:
            x = overlayFrame.maxX - w - m
            y = overlayFrame.minY + m
        }
        return CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }

    public func show(
        overlayCocoaFrame: CGRect,
        level: NSWindow.Level
    ) {
        self.anchorOverlayFrame = overlayCocoaFrame
        self.currentLevel = level

        guard !overlayCocoaFrame.isEmpty else {
            hide()
            return
        }

        let targetFrame = computeHUDFrame(for: overlayCocoaFrame, height: estimatedHUDHeight())
        let activePanel = ensurePanel(frame: targetFrame)
        activePanel.level = level
        activePanel.setFrame(targetFrame, display: true, animate: false)
        activePanel.orderFrontRegardless()
        isShown = true
        onInteractiveFrameChanged?()
    }

    public func update(
        telemetry: SessionTelemetry,
        language: AppLanguage,
        overlayCocoaFrame: CGRect? = nil,
        level: NSWindow.Level? = nil
    ) {
        state.telemetry = telemetry
        state.language = language
        let previousAnchor = anchorOverlayFrame
        if let overlayCocoaFrame, !overlayCocoaFrame.isEmpty {
            anchorOverlayFrame = overlayCocoaFrame
        }
        let anchorChanged = previousAnchor != anchorOverlayFrame
        if let level {
            currentLevel = level
            panel?.level = level
        }
        guard isShown, let panel, !anchorOverlayFrame.isEmpty else { return }
        let targetCardHeight = estimatedHUDHeight()
        let currentCardHeight = Self.visibleFrame(fromPanelFrame: panel.frame).height
        if anchorChanged || abs(currentCardHeight - targetCardHeight) > 4 {
            let resized = computeHUDFrame(for: anchorOverlayFrame, height: targetCardHeight)
            panel.setFrame(resized, display: false, animate: false)
            onInteractiveFrameChanged?()
        }
    }

    public func hide() {
        let wasShown = isShown
        isShown = false
        panel?.orderOut(nil)
        if wasShown {
            onInteractiveFrameChanged?()
        }
    }

    public func close() {
        hide()
        panel?.close()
        panel = nil
    }

    /// Renders the Profiler HUD card to a `CGImage` for VRR Direct-Scanout in-Metal compositing
    /// using a single reused `ImageRenderer` (zero WindowServer sub-windows).
    public static func renderToCGImage(
        telemetry: SessionTelemetry,
        language: AppLanguage,
        scale: CGFloat = 2.0
    ) -> CGImage? {
        let view = ProfilerHUDCardView(
            telemetry: telemetry,
            language: language,
            isInteractiveDragHint: false
        )
        let renderer: ImageRenderer<ProfilerHUDCardView>
        if let existing = vrrRenderer {
            existing.content = view
            renderer = existing
        } else {
            let created = ImageRenderer(content: view)
            vrrRenderer = created
            renderer = created
        }
        renderer.scale = max(1.0, scale)
        renderer.proposedSize = ProposedViewSize(width: hudWidth, height: nil)
        return renderer.cgImage
    }

    private func ensurePanel(frame: CGRect) -> NonActivatingChromePanel {
        if let panel { return panel }
        let created = NonActivatingChromePanel(globalCocoaRect: frame, ignoresMouseEvents: false)
        created.level = currentLevel

        let dragWrapper = DraggableHUDContainerView(
            state: state,
            onDragDelta: { [weak self] dx, dy in
                self?.moveBy(dx: dx, dy: dy)
            },
            onDragEnded: { [weak self] in
                self?.snapToNearestCorner()
            }
        )
        let host = NSHostingView(rootView: dragWrapper)
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        created.contentView = host
        self.panel = created
        return created
    }

    private func estimatedHUDHeight() -> CGFloat {
        let passRows = min(state.telemetry.passTimings.count, 8)
        return CGFloat(132 + (passRows > 0 ? (24 + passRows * 18) : 0))
    }

    private func hostScreenVisibleFrame(for overlayFrame: CGRect) -> CGRect? {
        let bestScreen = NSScreen.screens.max { lhs, rhs in
            let lInter = lhs.frame.intersection(overlayFrame)
            let rInter = rhs.frame.intersection(overlayFrame)
            let lArea = (lInter.isNull || lInter.isEmpty) ? 0 : (lInter.width * lInter.height)
            let rArea = (rInter.isNull || rInter.isEmpty) ? 0 : (rInter.width * rInter.height)
            return lArea < rArea
        }
        if let bestScreen, bestScreen.frame.intersects(overlayFrame) {
            return bestScreen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
    }

    private func computeHUDFrame(for overlayFrame: CGRect, height: CGFloat) -> CGRect {
        let visibleCard = Self.computeVisibleHUDCocoaFrame(
            for: overlayFrame,
            cardHeight: height,
            corner: corner,
            hostScreenVisibleFrame: hostScreenVisibleFrame(for: overlayFrame)
        )
        return Self.panelFrame(fromVisibleFrame: visibleCard)
    }

    private func moveBy(dx: CGFloat, dy: CGFloat) {
        guard let panel else { return }
        var visibleCard = Self.visibleFrame(fromPanelFrame: panel.frame)
        visibleCard.origin.x += dx
        visibleCard.origin.y += dy
        if !anchorOverlayFrame.isEmpty {
            let safeTop: CGFloat
            if let screenVisible = hostScreenVisibleFrame(for: anchorOverlayFrame),
               anchorOverlayFrame.maxY > screenVisible.maxY
            {
                safeTop = screenVisible.maxY - Self.notchSafeTopMargin
            } else {
                safeTop = anchorOverlayFrame.maxY - 6
            }
            visibleCard.origin.x = min(
                max(visibleCard.origin.x, anchorOverlayFrame.minX + 6),
                anchorOverlayFrame.maxX - visibleCard.width - 6
            )
            visibleCard.origin.y = min(
                max(visibleCard.origin.y, anchorOverlayFrame.minY + 6),
                max(anchorOverlayFrame.minY + 6, safeTop - visibleCard.height)
            )
        }
        panel.setFrame(Self.panelFrame(fromVisibleFrame: visibleCard), display: false, animate: false)
        onInteractiveFrameChanged?()
    }

    private func snapToNearestCorner() {
        guard let panel, !anchorOverlayFrame.isEmpty else { return }
        let visibleCard = Self.visibleFrame(fromPanelFrame: panel.frame)
        let midX = visibleCard.midX
        let midY = visibleCard.midY
        let isRight = midX >= anchorOverlayFrame.midX
        let isTop = midY >= anchorOverlayFrame.midY
        switch (isTop, isRight) {
        case (true, false): corner = .topLeft
        case (true, true): corner = .topRight
        case (false, false): corner = .bottomLeft
        case (false, true): corner = .bottomRight
        }
        let snapped = computeHUDFrame(for: anchorOverlayFrame, height: visibleCard.height)
        panel.setFrame(snapped, display: true, animate: true)
        onInteractiveFrameChanged?()
    }
}

private struct DraggableHUDContainerView: View {
    let state: ProfilerHUDState
    let onDragDelta: @MainActor (CGFloat, CGFloat) -> Void
    let onDragEnded: @MainActor () -> Void

    @State private var lastDragTranslation: CGSize = .zero

    var body: some View {
        ProfilerHUDCardView(
            telemetry: state.telemetry,
            language: state.language,
            isInteractiveDragHint: true
        )
        .padding(ProfilerHUDPanel.shadowPadding)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let dx = value.translation.width - lastDragTranslation.width
                    // SwiftUI Y increases downward; Cocoa screen Y increases upward.
                    let dy = -(value.translation.height - lastDragTranslation.height)
                    lastDragTranslation = value.translation
                    onDragDelta(dx, dy)
                }
                .onEnded { _ in
                    lastDragTranslation = .zero
                    onDragEnded()
                }
        )
    }
}

/// Shared SwiftUI HUD card view rendered both in the live floating `ProfilerHUDPanel`
/// and via `ImageRenderer` for VRR Direct-Scanout Metal compositing.
public struct ProfilerHUDCardView: View {
    public let telemetry: SessionTelemetry
    public let language: AppLanguage
    public let isInteractiveDragHint: Bool

    public init(
        telemetry: SessionTelemetry,
        language: AppLanguage,
        isInteractiveDragHint: Bool = false
    ) {
        self.telemetry = telemetry
        self.language = language
        self.isInteractiveDragHint = isInteractiveDragHint
    }

    public var body: some View {
        let l10n = L10n(language: language)
        let totalMs = max(telemetry.frameTimeMs, telemetry.totalGPUMilliseconds)

        VStack(alignment: .leading, spacing: 8) {
            // Header: GPU + Backend + Badges
            HStack(spacing: 6) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.cyan)
                Text(telemetry.gpuName.isEmpty ? "Apple Silicon GPU" : telemetry.gpuName)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if telemetry.hdrActive {
                    badge("HDR", color: .orange)
                }
                if telemetry.frameGenActive && telemetry.frameGenMultiplier > 1 {
                    badge("FG \(telemetry.frameGenMultiplier)×", color: .cyan)
                }
            }

            // Pipeline & Resolution
            HStack {
                Text(telemetry.backendName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.76))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: "\(telemetry.inputSize.width)×\(telemetry.inputSize.height) → \(telemetry.outputSize.width)×\(telemetry.outputSize.height)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.92))
            }

            // FPS & Frame Time Metrics Grid
            HStack(spacing: 10) {
                metricCell(label: l10n.tr("SRC", "源"), value: String(format: "%.1f", telemetry.sourceFPS), unit: "fps", accent: .white)
                metricCell(label: l10n.tr("OUT", "输出"), value: String(format: "%.1f", telemetry.outputFPS), unit: "fps", accent: .green)
                metricCell(label: l10n.tr("DISP", "显示"), value: String(format: "%.1f", telemetry.presentedFPS), unit: "fps", accent: .cyan)
                metricCell(label: "GPU", value: String(format: "%.2f", totalMs), unit: "ms", accent: totalMs > 8.0 ? .orange : .mint)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Color-coded proportional pass timeline bar + breakdown
            if !telemetry.passTimings.isEmpty {
                let sumPassMs = max(0.001, telemetry.passTimings.reduce(0) { $0 + max(0.001, $1.gpuMilliseconds) })

                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { geo in
                        HStack(spacing: 1.5) {
                            ForEach(telemetry.passTimings.prefix(8)) { pass in
                                let frac = max(0.04, pass.gpuMilliseconds / sumPassMs)
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(Color(hexString: pass.colorHex))
                                    .frame(width: max(4, geo.size.width * frac - 1.5))
                            }
                        }
                    }
                    .frame(height: 6)
                    .clipShape(Capsule())

                    VStack(spacing: 2.5) {
                        ForEach(telemetry.passTimings.prefix(8)) { pass in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(hexString: pass.colorHex))
                                    .frame(width: 6, height: 6)
                                Text(pass.name)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.84))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(String(format: "%.2f ms", pass.gpuMilliseconds))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white.opacity(0.95))
                            }
                        }
                    }
                }
            }

            // Footer counters
            HStack {
                Text("\(l10n.tr("Skip", "跳过")): \(telemetry.duplicateFramesSkipped)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Text("\(l10n.tr("Drop", "丢帧")): \(telemetry.droppedFrames)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(telemetry.droppedFrames > 0 ? Color.orange.opacity(0.9) : Color.white.opacity(0.55))
            }
        }
        .padding(11)
        .frame(width: 296, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.07, green: 0.08, blue: 0.11).opacity(0.88))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    }

    private func metricCell(label: String, value: String, unit: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.55))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                Text(unit)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.24), in: Capsule())
            .foregroundStyle(color)
    }
}

extension Color {
    /// Parses a `#RRGGBB` hex string safely (used for `PassTiming.colorHex`).
    init(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
