import AppKit
import Carbon
import Foundation
import MetalPieCore
import SwiftUI

// MARK: - Native macOS Grouped Card

/// Clean adaptive macOS card container with optional header icon, title, and subtitle.
struct SectionCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    let symbol: String?
    let accent: Color
    @ViewBuilder let content: () -> Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        symbol: String? = nil,
        accent: Color = .accentColor,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.accent = accent
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 22, height: 22)
                            .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .semibold))
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            content()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

/// Compact pill badge used across capability, status, and preset headers.
struct StatusBadge: View {
    let text: String
    let color: Color
    let symbol: String?

    init(_ text: String, color: Color, symbol: String? = nil) {
        self.text = text
        self.color = color
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 7.5)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Visual 3×3 anchor grid picker for `OutputAlignment`.
struct OutputAlignmentGridPicker: View {
    @Binding var selection: OutputAlignment
    let l10n: L10n

    private let rows: [[OutputAlignment]] = [
        [.topLeft, .top, .topRight],
        [.left, .center, .right],
        [.bottomLeft, .bottom, .bottomRight]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 4) {
                ForEach(0..<rows.count, id: \.self) { rowIdx in
                    HStack(spacing: 4) {
                        ForEach(rows[rowIdx]) { anchor in
                            let isSelected = selection == anchor
                            Button {
                                selection = anchor
                            } label: {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                                    .frame(width: 28, height: 22)
                                    .overlay {
                                        Circle()
                                            .fill(isSelected ? Color.white : Color.secondary.opacity(0.55))
                                            .frame(width: isSelected ? 6 : 4, height: isSelected ? 6 : 4)
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(l10n.outputAlignment(anchor))
                        }
                    }
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            Text(l10n.outputAlignment(selection))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Interactive Global Hotkey Recorder

/// Click-to-record native macOS shortcut control producing Carbon virtual key codes + `HotkeyModifiers`.
struct HotkeyRecorderField: View {
    let binding: HotkeyBinding
    let l10n: L10n
    let onRecord: (HotkeyBinding) -> Void
    let onClear: () -> Void

    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Button {
                    isRecording.toggle()
                } label: {
                    HStack(spacing: 6) {
                        if isRecording {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                            Text(l10n.tr("Press keys…", "按下快捷键…"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        } else if binding.isEnabled {
                            Text(binding.displayString)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)
                        } else {
                            Text(l10n.tr("None", "无"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 126, minHeight: 26)
                    .padding(.horizontal, 10)
                    .background(
                        isRecording ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isRecording ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: isRecording ? 1.5 : 1
                            )
                    }
                }
                .buttonStyle(.plain)

                if isRecording {
                    KeyEventCaptureOverlay { keyCode, modifiers, display in
                        isRecording = false
                        onRecord(HotkeyBinding(
                            keyCode: keyCode,
                            modifiers: modifiers,
                            displayString: display,
                            isEnabled: true
                        ))
                    } onCancel: {
                        isRecording = false
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                }
            }

            if binding.isEnabled {
                Button {
                    isRecording = false
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n.tr("Clear", "清除"))
            }
        }
    }
}

private struct KeyEventCaptureOverlay: NSViewRepresentable {
    let onCapture: (UInt32, HotkeyModifiers, String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        DispatchQueue.main.async {
            if nsView.window?.firstResponder !== nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

private final class KeyCaptureNSView: NSView {
    var onCapture: ((UInt32, HotkeyModifiers, String) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        onCancel?()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // Bare Escape cancels recording.
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 && flags.isEmpty {
            onCancel?()
            return
        }

        // Require at least one modifier key so normal typing is never hijacked globally.
        guard !flags.isEmpty else {
            NSSound.beep()
            return
        }

        var mods: HotkeyModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift)   { mods.insert(.shift) }

        let keyLabel = Self.displayKeyName(for: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers)
        let display = mods.symbolString + keyLabel
        onCapture?(UInt32(event.keyCode), mods, display)
    }

    private static func displayKeyName(for keyCode: UInt16, charactersIgnoringModifiers: String?) -> String {
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            if let chars = charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
               !chars.isEmpty
            {
                return chars.uppercased()
            }
            return "Key\(keyCode)"
        }
    }
}
