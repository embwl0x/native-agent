// The rest of Settings, on the Settings page.
//
// SetupView used to end in a door ("All settings") that pushed the old grouped
// Form in SlimSettingsView. The door is going away, so the sections that were
// behind it come onto the page in the page's own row format (`SetupRow`,
// SetupView.swift): a 14pt title and one 12pt sentence pinned to
// `SetupMetrics.rowContentHeight`, a spacer, and the control on the trailing
// edge. Alive glass (2026-09-23): the rows sit inside group cards —
// `.everyday` joins the "And the rest" card, `.app` is its own section.
//
// NOTHING IS FORKED. Every card here reads and writes the SAME storage, the
// SAME controller and the SAME presentation types the Form rows used, so the
// two surfaces can never disagree:
//   Global shortcut   → HotkeyControlView          (SlimSettingsView.swift:325)
//   Context window    → nativeagent.contextWindowMode + nativeagent.compactionThresholdTokens
//                                                  (SlimSettingsView.swift:330-359)
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
    enum Part { case everyday, app }
    /// `.everyday` is bare rows for a group card the page owns; `.app` is a
    /// whole section of its own.
    let part: Part

    // The app menu and every Settings surface share one Sparkle scheduler.
    @State private var updateController = UpdateController.shared
    @State private var tourReplayCoordinator = OnboardingTourReplayCoordinator.shared
    @AppStorage("nativeagent.showTour") private var showTour = false
    // Her context window (ChatSessionAutocompactionConfig.effectiveWindowTokens):
    // the model's default is 60% of its window; Custom is this size, still never
    // past 60% of the active model's window. An empty mode reads as Custom once
    // a size is saved, the same rule `productionDefault` applies.
    @AppStorage("nativeagent.compactionThresholdTokens") private var compactionThresholdTokens = 200_000
    @AppStorage("nativeagent.contextWindowMode") private var contextWindowMode = ""
    @Environment(AppModel.self) private var appModel
    @State private var dataLimitsFailure: String?

    var body: some View {
        switch part {
        case .everyday:
            // Bare rows, no container and no modifiers: the caller's group
            // card takes each one as its own row.
            hazeRow
            shortcutRow
            compactionRow
        case .app:
            appSection
        }
    }

    private var appSection: some View {
        SetupSection(title: "Updates and help") {
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

    // MARK: Haze

    private var hazeRow: some View {
        SetupRestCard(
            title: "Haze",
            detail: "The colour of the soft light drifting behind the window.",
            identifier: "setup.rest.haze"
        ) {
            HazeSwatches()
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
                .hazeTinted()
                .onChange(of: hotkeyEnabled) { _, newValue in
                    GlobalHotkeyManager.shared.setEnabled(newValue)
                }
                .accessibilityLabel("Global shortcut")
        }
    }

    // MARK: Context window

    /// The name this install's agent goes by, never a fixed one.
    private var agentName: String { AgentVoice(name: appModel.agentDisplayName).name }

    private var isCustomWindow: Binding<Bool> {
        Binding(
            get: {
                contextWindowMode == "custom" || (contextWindowMode.isEmpty
                    && UserDefaults.standard.integer(forKey: "nativeagent.compactionThresholdTokens") > 0)
            },
            set: { contextWindowMode = $0 ? "custom" : "model" }
        )
    }

    private var compactionRow: some View {
        SetupRestCard(
            title: "Context window",
            detail: "How much \(agentName) keeps in mind before compacting. On a model with a smaller window, \(agentName) uses 60% of that model's window.",
            identifier: "setup.rest.compaction"
        ) {
            HStack(spacing: 8) {
                Picker("Context window", selection: isCustomWindow) {
                    Text("Model default").tag(false)
                    Text("Custom").tag(true)
                }
                .pickerStyle(.segmented)
                .hazeTinted(.segments)
                .labelsHidden()
                .fixedSize()
                if isCustomWindow.wrappedValue {
                    Text(Self.formatThresholdTokens(compactionThresholdTokens))
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .accessibilityHidden(true)
                    Stepper("Custom size",
                            value: $compactionThresholdTokens,
                            in: 50_000...500_000,
                            step: 10_000)
                        .labelsHidden()
                        // NSStepper exposes its two visual arrows as separate,
                        // unnamed AX buttons unless SwiftUI is told to present the
                        // control as one adjustable element. VoiceOver then lands
                        // once, announces the setting and value, and can adjust it.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Custom context window size")
                        .accessibilityValue(Self.formatThresholdTokens(compactionThresholdTokens))
                        .accessibilityHint("Adjusts how much \(agentName) keeps in mind before compacting")
                }
            }
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
                Button("Take the tour") {
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
        if n >= 1_000_000 { return String(format: "%.1fM tokens", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%dK tokens",  n / 1_000) }
        return "\(n) tokens"
    }
}

/// One row, in the page's one row shape (`SetupRow`) — a second spelling of
/// that shape is how a column starts reading ragged.
private struct SetupRestCard<Control: View>: View {
    let title: String
    let detail: String
    let identifier: String
    @ViewBuilder var control: Control

    var body: some View {
        SetupRow(title: title, detail: detail) { control }
            .accessibilityIdentifier(identifier)
    }
}

/// The haze palette as a row of small swatches, the chosen one ringed.
/// Setup's Haze card and Simple view's settings share it.
struct HazeSwatches: View {
    @AppStorage(HazeColor.key) private var hazeColor = HazeColor.teal.rawValue

    var body: some View {
        let selected = HazeColor(stored: hazeColor)
        HStack(spacing: 8) {
            ForEach(HazeColor.allCases) { color in
                Button {
                    hazeColor = color.rawValue
                } label: {
                    Circle()
                        .fill(color.swatch)
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay {
                            Circle().strokeBorder(
                                color == selected ? NativeAgentShell.text : .clear,
                                lineWidth: 1.5)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.name)
                .accessibilityAddTraits(color == selected ? .isSelected : [])
            }
        }
    }
}
