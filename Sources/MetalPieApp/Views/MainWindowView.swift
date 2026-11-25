import AppKit
import MetalPieCore
import SwiftUI

/// Root native macOS `NavigationSplitView` window hosting MetalPie's streamlined 5 workspaces
/// and a persistent live Apple Silicon engine status pill in the sidebar footer.
public struct MainWindowView: View {
    @Bindable var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        let l10n = coordinator.l10n

        NavigationSplitView {
            List(AppTab.allCases, selection: $coordinator.selectedTab) { tab in
                Label {
                    Text(tab.title(l10n))
                        .font(.system(size: 13, weight: .medium))
                } icon: {
                    Image(systemName: tab.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 18, alignment: .center)
                }
                .tag(tab)
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    sidebarAppIcon
                    Text("MetalPie")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.trailing, 14)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    engineStatusPill(l10n: l10n)
                        .padding(10)
                }
            }
            .navigationSplitViewColumnWidth(min: 196, ideal: 214, max: 245)
        } detail: {
            Group {
                switch coordinator.selectedTab {
                case .home:
                    HomeScaleView(coordinator: coordinator)
                case .effects:
                    EffectChainEditorView(coordinator: coordinator)
                case .profiles:
                    ProfilesView(coordinator: coordinator)
                case .settings:
                    SettingsView(coordinator: coordinator)
                case .diagnostics:
                    DiagnosticsView(coordinator: coordinator)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 960, minHeight: 640)
    }

    @ViewBuilder
    private var sidebarAppIcon: some View {
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let appIcon = NSImage(contentsOf: icnsURL),
           appIcon.size.width > 0
        {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.05, green: 0.08, blue: 0.17),
                                Color(red: 0.13, green: 0.09, blue: 0.26)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                    )
                Text("M")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan, Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 22, height: 22)
        }
    }

    private func engineStatusPill(l10n: L10n) -> some View {
        let isActive = coordinator.isScalingSessionOpen
        let stateColor: Color = {
            switch coordinator.telemetry.state {
            case .running: return .green
            case .starting, .countingDown: return .cyan
            case .suspended, .waitingForWindow: return .orange
            case .error: return .red
            default: return .secondary
            }
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(coordinator.capabilities.gpuName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isActive {
                    let fps = coordinator.telemetry.presentedFPS > 0.5
                        ? coordinator.telemetry.presentedFPS
                        : coordinator.telemetry.outputFPS
                    Text(String(format: "%.0f FPS", fps))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 6) {
                Text(l10n.sessionState(coordinator.telemetry.state))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if coordinator.countdownRemaining != nil {
                    Button(l10n.tr("Cancel", "取消")) {
                        coordinator.cancelCountdown()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                } else if isActive {
                    Button {
                        Task { await coordinator.stopScaling(isManual: true, showToast: true) }
                    } label: {
                        Label(l10n.tr("Stop", "停止"), systemImage: "stop.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isActive ? Color.green.opacity(0.35) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        }
    }
}
