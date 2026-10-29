import NativeAgentShared
import EngineRuntime
import AppToolRuntime

// Blueprint: | `SetupRestRows.swift` | `SetupRestRows`: remaining settings controls in shared page rows, build identity and bundled data-limit reference handoff |
// Settings rows share canonical storage and controllers inside the page's group cards.

import SwiftUI
import Onboarding
import NativeAgentCore

struct SetupRestRows: View {
    enum Part { case everyday, app }
    /// `.everyday` is bare rows for a group card the page owns; `.app` is a
    /// whole section of its own.
    let part: Part

    // The app menu and every Settings surface share one Sparkle scheduler.
    @State private var updateController = UpdateController.shared
    @State private var tourReplayCoordinator = OnboardingTourReplay.shared
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
            shotgunShortcutRow
            compactionRow
        case .app:
            appSection
        }
    }

    private var appSection: some View {
        AdvancedSection(title: "Updates and help") {
            updatesRow
            helpRow
            aboutRow
            appStatusRow
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
        SetupRow(
            title: "Haze",
            detail: "The color of the soft light drifting behind the window.",
            identifier: "setup.rest.haze"
        ) {
            HazeSwatches()
        }
    }

    // MARK: Global shortcut

    /// A switch in the card's own format. The default and the manager call
    /// are kept together here so the switch never drifts from the installed key.
    @AppStorage("globalHotkeyEnabled") private var hotkeyEnabled: Bool = true

    private var shortcutRow: some View {
        SetupRow(
            title: "Global shortcut",
            detail: "⌘⇧J brings the window forward from anywhere. Hold it to talk, which needs Microphone and Speech Recognition.",
            identifier: "setup.rest.shortcut"
        ) {
            Toggle("Global shortcut", isOn: $hotkeyEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .hazeTinted()
                .onChange(of: hotkeyEnabled) { _, newValue in
                    GlobalHotkey.shared.setEnabled(newValue)
                }
                .accessibilityLabel("Global shortcut")
        }
    }

    // MARK: Shotgun shortcut

    @AppStorage(ShotgunShortcut.storageKey) private var shotgunShortcut = ShotgunShortcut.optionSpace.rawValue

    /// The key that shows or hides Shotgun (Shotgun.swift). A few fixed
    /// choices, since launchers and other AI apps often own ⌥Space.
    private var shotgunShortcutRow: some View {
        let taken = ShotgunController.shared.shortcutTaken
        return SetupRow(
            title: "Shotgun shortcut",
            detail: taken.map { "\($0.title) is taken by another app. Pick another, or use View ▸ Show Shotgun." }
                ?? "Shows or hides Shotgun, the small chat this window steps aside into.",
            identifier: "setup.rest.shotgunShortcut"
        ) {
            Picker("Shotgun shortcut", selection: Binding(
                get: { ShotgunShortcut(rawValue: shotgunShortcut) ?? .optionSpace },
                set: { shortcut in
                    shotgunShortcut = shortcut.rawValue
                    ShotgunController.shared.applyShortcut()
                }
            )) {
                ForEach(ShotgunShortcut.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Shotgun shortcut")
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
        SetupRow(
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
        // Keep the automatic preference separate from manual-check readiness.
        let state = SoftwareUpdateRowPresentation.resolve(
            availableVersion: updateController.status.availableVersion,
            updatesAreAvailable: updateController.updatesAreAvailable,
            automaticChecksEnabled: updateController.automaticChecksEnabled,
            canCheckForUpdates: updateController.canCheckForUpdates,
            unavailableDetail: updateController.settingsDetail
        )
        return SetupRow(
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
        SetupRow(
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
                    guard let url = Bundle.main.url(
                        forResource: "data-bounds", withExtension: "md", subdirectory: "docs"
                    ) else {
                        dataLimitsFailure = "Tell the person: the data-limits reference is missing from this copy of NativeAgent."
                        return
                    }
                    if !NSWorkspace.shared.open(url) {
                        dataLimitsFailure = "NativeAgent found the data-limits reference but macOS could not open it. Try again or open the document from the installed app bundle."
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
        let line = "\(Self.appName) \(Self.buildIdentityLine(identity))"
        return SetupRow(
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

    // MARK: App status

    /// The same runtime liveness and read-failure presentation as Status.
    private var appStatusRow: some View {
        let state = appModel.engine.doctor.runtimeStatus(lastRefreshError: appModel.lastRefreshError)
        return VStack(alignment: .leading, spacing: 6) {
            SetupRow(
                title: "App status",
                detail: state.text,
                identifier: "setup.rest.appStatus"
            ) {
                EmptyView()
            }
            if let detail = state.detail {
                Text(detail)
                    .font(ShellType.rowDetail)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("setup.rest.appStatus.error")
            }
        }
    }

    // MARK: Copy helpers

    /// One-line, paste-into-a-bug-report identity of the running bytes:
    /// `0.3.7 (abc1234, modified)`. The revision is shown short; `modified` is
    /// shown whenever the builder did not stamp clean-source truth, because an
    /// unstamped bundle is exactly the case that must not be read as exact
    /// proof of a commit (see NativeAgentBuildIdentity).
    static func buildIdentityLine(_ identity: NativeAgentBuildIdentity) -> String {
        var line = identity.version
        var parenthetical: [String] = []
        if let revision = identity.sourceRevision, !revision.isEmpty {
            parenthetical.append(String(revision.prefix(7)))
        }
        if identity.sourceDirty {
            parenthetical.append("modified")
        }
        if !parenthetical.isEmpty {
            line += " (\(parenthetical.joined(separator: ", ")))"
        }
        if identity.build != identity.version {
            line += " build \(identity.build)"
        }
        return line
    }

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
