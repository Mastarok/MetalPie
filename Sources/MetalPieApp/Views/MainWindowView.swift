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
            VStack(spacing: 0) {
                // Brand Header
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.cyan, Color.blue, Color.indigo],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("MetalPie")
                            .font(.system(size: 14, weight: .bold))
                        Text(l10n.tr("GPU Upscaler & Frame Gen", "窗口高清放大与补帧"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

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

                Divider()

                // Persistent Live Engine Status Pill
                engineStatusPill(l10n: l10n)
                    .padding(10)
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
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 960, minHeight: 640)
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
                    .font(.system(size: 10.5))
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
                        Label(l10n.tr("Exit", "退出"), systemImage: "stop.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Text(coordinator.capabilities.supportsVTFrameInterpolation
                         ? l10n.tr("Apple ML", "芯片补帧")
                         : "Metal 3")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.cyan)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.cyan.opacity(0.14), in: Capsule())
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
