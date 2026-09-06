// The rest of Settings, on the Settings page.
//
// SetupView used to end in a door ("All settings") that pushed the old grouped
// Form in SlimSettingsView. The door is going away, so the sections that were
// behind it come onto the page in the page's own card format — the exact shape
// of `SetupView.appearanceRow` (SetupView.swift:573-592): a semibold title and
// one 13pt sentence pinned to `SetupMetrics.restCardContentHeight`, a spacer,
// and the control on the trailing edge, inside `SetupCardShell`.
//
// NOTHING IS FORKED. Every card here reads and writes the SAME storage, the
// SAME controller and the SAME presentation types the Form rows used, so the
// two surfaces can never disagree:
//   Global shortcut   → HotkeyControlView          (SlimSettingsView.swift:325)
//   Chat compaction   → nativeagent.compactionThresholdTokens
//                                                  (SlimSettingsView.swift:330-359)
//   Classic sidebar   → NativeAgentShellPreference.classicShellKey
//                                                  (SlimSettingsView.swift:315-317)
//   Updates           → UpdateController.shared + SoftwareUpdateRowPresentation
//                                                  (SlimSettingsView.swift:405-415)
//   Help and reference→ OnboardingTourReplayCoordinator, SlimSettingsDataLimitsReference
//                                                  (SlimSettingsView.swift:362-385)
//   About             → NativeAgentBuildIdentity + SlimSettingsView.buildIdentityLine
//                                                  (SlimSettingsView.swift:388-403)
//
// Devices and Integrations are deliberately absent: Telegram and iPhone already
// have their own cards on this page (SetupView.swift:549-567) and the rail
// carries Connectors.

import SwiftUI
import NativeAgentCore

struct SetupRestRows: View {
    /// The gap between cards on the Settings page (`SetupView.body`, the
    /// `VStack(alignment: .leading, spacing: 22)`).
    private static let cardSpacing: CGFloat = 22

    // The app menu and every Settings surface share one Sparkle scheduler.
    @State private var updateController = UpdateController.shared
    @State private var tourReplayCoordinator = OnboardingTourReplayCoordinator.shared
    @AppStorage("nativeagent.showTour") private var showTour = false
    // User-selected transcript threshold ceiling. The shared compactor clamps
    // this to 40% of the active model window, so a smaller-window model still
    // compacts before the configured ceiling becomes unsafe.
    @AppStorage("nativeagent.compactionThresholdTokens") private var compactionThresholdTokens = 200_000
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false
    @State private var dataLimitsFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Self.cardSpacing) {
            shortcutRow
            compactionRow
            classicSidebarRow
            updatesRow
            helpRow
            aboutRow
        }
        .alert(
            "Can’t open data limits",
            isPresented: Binding(
                get: { dataLimitsFailure != nil },
                set: { if !$0 { dataLimitsFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dataLimitsFailure ?? "The data-limits reference is unavailable.")
        }
    }

    // MARK: Global shortcut

    /// A switch in the card's own format. The default and the manager call
    /// are the same pair HotkeyControlView owns (MenuBarController.swift),
    /// kept together here so the switch never drifts from the installed key.
    @AppStorage("globalHotkeyEnabled") private var hotkeyEnabled: Bool = true

    private var shortcutRow: some View {
        SetupRestCard(
            title: "Global shortcut",
            detail: "⌘⇧J brings the window forward from anywhere. Hold it to talk, which needs Microphone and Speech Recognition.",
            identifier: "setup.rest.shortcut"
        ) {
            Toggle("Global shortcut", isOn: $hotkeyEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(NativeAgentBrand.accent)
                .onChange(of: hotkeyEnabled) { _, newValue in
                    GlobalHotkeyManager.shared.setEnabled(newValue)
                }
                .accessibilityLabel("Global shortcut")
        }
    }

    // MARK: Chat compaction

    private var compactionRow: some View {
        SetupRestCard(
            title: "Chat compaction",
            detail: "The largest a transcript grows before it is compacted; a smaller context window compacts earlier.",
            identifier: "setup.rest.compaction"
        ) {
            HStack(spacing: 8) {
                Text(Self.formatThresholdTokens(compactionThresholdTokens))
                    .font(ShellType.label.monospaced())
                    .foregroundStyle(NativeAgentShell.secondary)
                    .accessibilityHidden(true)
                // Same range, same step, same clamp story as the Form row.
                Stepper("Auto-compact threshold",
                        value: $compactionThresholdTokens,
                        in: 50_000...500_000,
                        step: 10_000)
                    .labelsHidden()
                    // NSStepper exposes its two visual arrows as separate,
                    // unnamed AX buttons unless SwiftUI is told to present the
                    // control as one adjustable element. VoiceOver then lands
                    // once, announces the setting and value, and can adjust it.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Auto-compact threshold")
                    .accessibilityValue(Self.formatThresholdTokens(compactionThresholdTokens))
                    .accessibilityHint("Adjusts the maximum chat transcript size before automatic compaction")
            }
        }
    }

    // MARK: Classic sidebar

    private var classicSidebarRow: some View {
        SetupRestCard(
            title: "Use the classic sidebar",
            detail: "Restores the previous sidebar, session list, and chat layout.",
            identifier: "setup.rest.classic-sidebar"
        ) {
            Toggle("Use the classic sidebar", isOn: $classicShell)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(NativeAgentBrand.accent)
                .accessibilityIdentifier("setup.rest.classic-shell-toggle")
                .accessibilityHint("Restores the previous sidebar, session list, and chat layout")
        }
    }

    // MARK: Updates

    private var updatesRow: some View {
        // The same two independent facts the Form row resolved: whether this
        // build has a published feed at all, and whether Sparkle can start
        // another manual check right now.
        let state = SoftwareUpdateRowPresentation.resolve(
            availableVersion: updateController.status.availableVersion,
            updatesAreAvailable: updateController.updatesAreAvailable,
            canCheckForUpdates: updateController.canCheckForUpdates,
            unavailableDetail: updateController.settingsDetail
        )
        return SetupRestCard(
            title: "Updates",
            detail: state.detail.isEmpty ? state.title : "\(state.title). \(state.detail)",
            identifier: "setup.rest.updates"
        ) {
            Button(updateController.menuTitle) {
                updateController.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .tint(NativeAgentShell.text)
            .disabled(!state.actionEnabled)
            .accessibilityIdentifier("setup.rest.softwareUpdate.check")
        }
    }

    // MARK: Help and reference

    private var helpRow: some View {
        SetupRestCard(
            title: "Help and reference",
            detail: "The onboarding tour, and what the app keeps and for how long.",
            identifier: "setup.rest.help"
        ) {
            HStack(spacing: 8) {
                Button("Replay the tour") {
                    showTour = true
                    tourReplayCoordinator.requestReplay()
                }
                .buttonStyle(.bordered)
                .tint(NativeAgentShell.text)
                Button("Show data limits") {
                    let outcome = SlimSettingsDataLimitsReference.open(
                        resourceLookup: { name, ext, subdirectory in
                            Bundle.main.url(
                                forResource: name,
                                withExtension: ext,
                                subdirectory: subdirectory
                            )
                        },
                        opener: { NSWorkspace.shared.open($0) }
                    )
                    if let failure = outcome.failureMessage {
                        dataLimitsFailure = failure
                    }
                }
                .buttonStyle(.bordered)
                .tint(NativeAgentShell.text)
            }
        }
    }

    // MARK: About

    private var aboutRow: some View {
        // NativeAgentBuildIdentity is the one source of truth for the running
        // bytes, and `buildIdentityLine` is the one spelling of it — a dev build
        // and a release build must never render identically in a bug report.
        let identity = NativeAgentBuildIdentity.current
        let line = "\(Self.appName) \(SlimSettingsView.buildIdentityLine(identity))"
        return SetupRestCard(
            title: "About",
            detail: line,
            identifier: "setup.rest.about"
        ) {
            Button("Copy") {
                ChatClipboard.copy(line)
            }
            .buttonStyle(.bordered)
            .tint(NativeAgentShell.text)
            .accessibilityLabel("Copy build identity")
        }
    }

    // MARK: Copy helpers

    private static var appName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        guard let display, !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "NativeAgent"
        }
        return display
    }

    private static func formatThresholdTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%dk",  n / 1_000) }
        return "\(n)"
    }
}

/// One card, in the page's rest-card shape: `SetupCardShell`, a semibold title
/// over one 13pt sentence held to `SetupMetrics.restCardContentHeight`, and the
/// control on the trailing edge. Identical to `SetupView.appearanceRow`
/// (SetupView.swift:573-592) — a second spelling of that shape is how a column
/// starts reading ragged.
private struct SetupRestCard<Control: View>: View {
    let title: String
    let detail: String
    let identifier: String
    @ViewBuilder var control: Control

    var body: some View {
        SetupCardShell {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold).lineLimit(1)
                    Text(detail)
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .frame(height: SetupMetrics.restCardContentHeight, alignment: .topLeading)
                Spacer(minLength: 12)
                control
            }
        }
        .accessibilityIdentifier(identifier)
    }
}
