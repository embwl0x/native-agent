// Move-only extraction (tightness Wave C) from SidebarFlattenViews.swift

import SwiftUI
import Context
import NativeAgentShared
import NativeAgentCore

// MARK: - Slim Settings (the new "Settings" primary tab)

struct SlimSettingsView: View {
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

    @Environment(AppModel.self) private var appModel
    // The app menu and Settings use one Sparkle scheduler/controller.
    @State private var updateController = UpdateController.shared
    @AppStorage("nativeagent.showTour") private var showTour = false
    @AppStorage("nativeagent.darkMode") private var preferDark = false
    // User-selected transcript threshold ceiling. The shared compactor clamps
    // this to 40% of the active model window so smaller-window models compact
    // before the configured ceiling becomes unsafe.
    @AppStorage("nativeagent.compactionThresholdTokens") private var compactionThresholdTokens = 200_000
    // B2.2: gate developer/internal sidebar surfaces (Turn Inspector, MCP,
    // Cognition, …) behind an explicit preference. Off on fresh installs. Purely
    // a UI-visibility preference — NOT Trust Center's developerMode policy.
    @AppStorage("showDeveloperSurfaces") private var showDeveloperSurfaces = false
    @AppStorage(NativeExperiencePreferences.masterKey) private var experienceEnabled = false
    @AppStorage(NativeExperiencePreferences.journeyKey) private var journeyEnabled = true
    @AppStorage(NativeExperiencePreferences.contextKey) private var experienceContextEnabled = true
    @AppStorage(NativeExperiencePreferences.projectsKey) private var experienceProjectsEnabled = true
    @AppStorage(NativeExperiencePreferences.automationsKey) private var experienceAutomationsEnabled = true
    @AppStorage(NativeExperiencePreferences.capabilitiesKey) private var experienceCapabilitiesEnabled = true
    @AppStorage(NativeExperiencePreferences.lineageKey) private var experienceLineageEnabled = true
    @AppStorage(NativeExperiencePreferences.workbenchKey) private var experienceWorkbenchEnabled = true
    @AppStorage(NativeExperiencePreferences.diagnosticsKey) private var experienceDiagnosticsEnabled = true
    @AppStorage(NativeExperiencePreferences.kitsKey) private var experienceKitsEnabled = true
    @AppStorage(NativeExperiencePreferences.remoteNodesKey) private var experienceRemoteNodesEnabled = true
    @AppStorage(NativeExperiencePreferences.skillEvolutionKey) private var experienceSkillEvolutionEnabled = true
    // 2026-07-23 B2.6c: Subconscious + Embeddings are power-user internals a
    // stranger never touches; they collapse behind this persisted Advanced
    // disclosure. Attention flags let an error/partial state still surface a
    // warn badge on the collapsed header (CapabilitiesView collapsedCard idiom).
    @AppStorage("nativeagent.settingsShowAdvanced") private var showAdvancedSettings = false
    @State private var embeddingsAttention = false
    @State private var subconsciousAttention = false
    @State private var confirmClassicPresentation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        MacPairingView()
                    } label: {
                        Label("Pair iPhone / iPad", systemImage: "iphone.and.arrow.right.outward")
                    }
                } header: {
                    Text("Devices")
                }

                Section {
                    NavigationLink {
                        TelegramView()
                    } label: {
                        Label("Telegram", systemImage: "paperplane")
                    }
                } header: {
                    Text("Integrations")
                }

                Section {
                    Toggle("Prefer Dark Appearance", isOn: $preferDark)
                    Toggle("Show Developer Surfaces", isOn: $showDeveloperSurfaces)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Reveals internal tabs — Capabilities, Knowledge Graph, Dreams, Diagnostics (home of the Cognition and Inspector segments), Inbox Policy, and MCP — in the sidebar's Advanced group and the Cmd+K palette. Off by default; deep links to these still resolve.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Native Experience", isOn: $experienceEnabled)

                    if experienceEnabled {
                        Toggle("Learning journey", isOn: $journeyEnabled)
                        Toggle("Context economics", isOn: $experienceContextEnabled)
                        Toggle("Project spaces", isOn: $experienceProjectsEnabled)
                        Toggle("Automation blueprints", isOn: $experienceAutomationsEnabled)
                        Toggle("Capability readiness", isOn: $experienceCapabilitiesEnabled)
                        Toggle("Conversation lineage", isOn: $experienceLineageEnabled)
                        Toggle("Native workbench", isOn: $experienceWorkbenchEnabled)
                        Toggle("Diagnostic observer", isOn: $experienceDiagnosticsEnabled)
                        Toggle("Capability Kits", isOn: $experienceKitsEnabled)
                        Toggle("Skill evolution", isOn: $experienceSkillEvolutionEnabled)
                        Toggle("Trusted remote nodes", isOn: $experienceRemoteNodesEnabled)

                        Button("Return to Classic NativeAgent", role: .destructive) {
                            confirmClassicPresentation = true
                        }
                    }
                } header: {
                    Text("NativeAgent Experience")
                } footer: {
                    Text("Adds optional native views over existing NativeAgent owners. It does not change chat, models, memory, Fluid Context, the subconscious, the organism, trust, or background work. Return to Classic hides every addition without deleting data, tool loadouts, versions, receipts, or schedules you created.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section {
                    HotkeyControlView()
                } header: {
                    Text("Global Shortcut")
                }

                Section {
                    HStack {
                        Label("Auto-compact threshold", systemImage: "rectangle.compress.vertical")
                        Spacer()
                        Text(formatThresholdTokens(compactionThresholdTokens))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Stepper("",
                                value: $compactionThresholdTokens,
                                in: 50_000...500_000,
                                step: 10_000)
                            .labelsHidden()
                    }
                } header: {
                    Text("Chat")
                } footer: {
                    Text("Maximum transcript size before automatic compaction. Models with smaller context windows compact earlier at 40% of their window. Default ceiling is 200k.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // Swift-native Memory (CoreML embeddings) + Subconscious
                // background loops — power-user internals, collapsed behind an
                // Advanced disclosure (B2.6c). An error/partial state in either
                // block still raises a warn badge on the collapsed header.
                Section {
                    Button {
                        withAnimation(.snappy) { showAdvancedSettings.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Label("Advanced", systemImage: "slider.horizontal.3")
                            Spacer()
                            if !showAdvancedSettings, embeddingsAttention || subconsciousAttention {
                                StatusBadge(text: "Needs attention", status: "warn")
                            }
                            Image(systemName: showAdvancedSettings ? "chevron.down" : "chevron.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Semantic memory embeddings and the Subconscious background loops. Most people never need to change these.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if showAdvancedSettings {
                    EmbeddingsSettingsSection(attention: $embeddingsAttention)
                    SubconsciousSettingsSection(attention: $subconsciousAttention)
                }

                Section {
                    Button {
                        showTour = true
                    } label: {
                        Label("Replay Onboarding Tour", systemImage: "map")
                    }
                    Button {
                        // S.2: docs/data-bounds.md ships in Resources/docs/
                        let bundled = Bundle.main.url(forResource: "data-bounds", withExtension: "md", subdirectory: "docs")
                            ?? Bundle.main.url(forResource: "data-bounds", withExtension: "md")
                        if let url = bundled {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Show data limits", systemImage: "ruler")
                    }
                } header: {
                    Text("Help & Reference")
                }

                Section {
                    // Sweep R4 C13: NativeAgentBuildIdentity already computes
                    // version + source revision + dirty truth and no View
                    // rendered it, so a dev build and a release build looked
                    // identical and a bug report could not name the bytes.
                    // Copyable, because the point is pasting it into a report.
                    let identity = NativeAgentBuildIdentity.current
                    LabeledContent("Version") {
                        Text(Self.buildIdentityLine(identity))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        Button("Copy build identity") {
                            ChatClipboard.copy(Self.buildIdentityLine(identity))
                        }
                    }
                    if let notice = updateController.updateNoticeText {
                        Label(notice, systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .fontWeight(.semibold)
                    }
                    Button {
                        updateController.checkForUpdates()
                    } label: {
                        Label(
                            updateController.menuTitle,
                            systemImage: updateController.updateNoticeText == nil
                                ? "arrow.triangle.2.circlepath"
                                : "arrow.down.circle.fill"
                        )
                    }
                    .accessibilityHint(
                        updateController.updatesAreAvailable
                            ? "Checks the signed NativeAgent release feed now."
                            : "Explains how this build receives software updates."
                    )
                    LabeledContent("Status", value: appModel.statusText)
                } header: {
                    Text("About")
                } footer: {
                    Text(updateController.settingsDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            // Seed the Embeddings attention badge while the Advanced block is
            // collapsed (the child section that normally detects fail-closed /
            // failed-install isn't mounted then). Subconscious defaults off and
            // only turns partial via interaction, which mounts its child — so
            // only Embeddings needs a collapsed seed. (B2.6c)
            .task(id: showAdvancedSettings) {
                guard !showAdvancedSettings else { return }
                await seedEmbeddingsAttention()
            }
            .confirmationDialog(
                "Return to the classic NativeAgent presentation?",
                isPresented: $confirmClassicPresentation,
                titleVisibility: .visible
            ) {
                Button("Return to Classic", role: .destructive) {
                    NativeExperiencePreferences.returnToClassic()
                    experienceEnabled = false
                }
                Button("Keep Native Experience", role: .cancel) {}
            } message: {
                Text("Only the optional presentation is removed. NativeAgent's capabilities and living runtime stay exactly as they are.")
            }
        }
    }

    @MainActor
    private func seedEmbeddingsAttention() async {
        do {
            let s = try await appModel.fetchEmbeddingsStatus()
            embeddingsAttention = s.effectiveBackend == "unavailable"
                || s.installState?.state == "failed"
                || s.reindexState?.state == "failed"
        } catch {
            embeddingsAttention = true
        }
    }

    private func formatThresholdTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%dk",  n / 1_000) }
        return "\(n)"
    }
}

// MARK: - Subconscious section

private struct SubconsciousSettingsSection: View {
    private struct ReflectionModelChoice: Identifiable, Equatable {
        let id: String
        let providerID: String
        let modelID: String
        let label: String
        let providerReady: Bool
    }

    @Environment(AppModel.self) private var appModel
    // 2026-07-23 B2.6c: reports an attention signal up to the Advanced
    // disclosure so a partial/errored Subconscious still surfaces a warn badge
    // when the block is collapsed.
    @Binding var attention: Bool
    @AppStorage("cognitiveSubstrateEnabled") private var subconsciousEnabled = false
    @AppStorage("cognitiveSubstrateCapsuleEnabled") private var capsuleEnabled = true
    @AppStorage("cognitiveSubstrateBackgroundEnabled") private var backgroundEnabled = true
    @AppStorage("cognitiveSubstrateReflectionEnabled") private var reflectionEnabled = false
    @AppStorage("cognitiveSubstrateDailyReflectionBudget") private var reflectionBudget = 2
    @AppStorage("organismKernelEnabled") private var organismEnabled = false
    @AppStorage("contextFlowMode") private var contextFlowMode = ContextFlowMode.shadow.rawValue
    @AppStorage("cognitiveSubstrateReflectionModel") private var subconsciousModel = "claude-opus-4-8"
    @AppStorage("cognitiveSubstrateReflectionProvider") private var subconsciousProvider = ""
    @State private var savingToggle = false
    @State private var savingContextFlow = false
    @State private var savingModel = false
    @State private var errorMessage: String?
    @State private var contextFlowStatus: NativeContextFlowModeStatus?
    @State private var reflectionRouteStatus: NativeReflectionRouteStatus?
    @State private var pendingReflectionChoiceID: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { subconsciousEnabled },
                set: { enabled in Task { await setSubconsciousEnabled(enabled) } }
            )) {
                Label("Subconscious", systemImage: "sparkles")
            }
            .disabled(savingToggle)

            Picker("Fluid Context", selection: $contextFlowMode) {
                ForEach([ContextFlowMode.active, .shadow, .off], id: \.self) { mode in
                    Text(contextFlowModeLabel(mode)).tag(mode.rawValue)
                }
            }
            .disabled(savingToggle || savingContextFlow)
            .onChange(of: contextFlowMode) { _, rawMode in
                Task { await saveContextFlowMode(rawMode) }
            }

            if let contextFlowStatusText {
                Text(contextFlowStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if reflectionModelChoices.isEmpty {
                LabeledContent("LLM") {
                    Text("Connect a provider to choose a reflection model")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Picker("LLM", selection: Binding(
                    get: { pendingReflectionChoiceID ?? currentReflectionChoiceID },
                    set: { choiceID in
                        guard let choice = reflectionModelChoices.first(where: { $0.id == choiceID }) else {
                            return
                        }
                        pendingReflectionChoiceID = choiceID
                        Task { await saveSubconsciousSelection(choice) }
                    }
                )) {
                    ForEach(reflectionModelChoices) { choice in
                        Text(choice.label + (choice.providerReady ? "" : " ⚠️"))
                            .tag(choice.id)
                    }
                }
                .disabled(savingToggle || savingModel)
            }

            if let reflectionRouteStatus, !reflectionRouteStatus.isReady {
                Text(reflectionRouteStatus.detail)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Label(statusLabel, systemImage: statusSystemImage)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Spacer()
                if savingToggle || savingContextFlow || savingModel {
                    ProgressView().controlSize(.small)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Subconscious")
        } footer: {
            Text("When on, \(appModel.agentDisplayName) keeps bounded Swift-native cognitive background loops active and uses the selected model for budgeted reflection.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task {
            if appModel.modelCatalog == nil {
                await appModel.refreshModelCatalog()
            }
            _ = await appModel.loadProvidersForChat()
            contextFlowStatus = await NativeContextFlowRuntime.shared.modeStatus()
            await refreshReflectionRouteStatus()
            attention = attentionState
        }
        .onChange(of: attentionState) { _, newValue in
            attention = newValue
        }
    }

    private var reflectionModelChoices: [ReflectionModelChoice] {
        var choices: [ReflectionModelChoice] = []
        var seen: Set<String> = []
        for provider in appModel.providersList {
            let ready = provider.auth_status.state == "ready"
            for model in provider.models {
                let id = reflectionChoiceID(providerID: provider.provider_id, modelID: model.id)
                guard seen.insert(id).inserted else { continue }
                choices.append(ReflectionModelChoice(
                    id: id,
                    providerID: provider.provider_id,
                    modelID: model.id,
                    label: "\(model.name) · \(provider.display_name)",
                    providerReady: ready
                ))
            }
        }

        let currentProvider = effectiveSubconsciousProvider
        let currentID = reflectionChoiceID(
            providerID: currentProvider,
            modelID: effectiveSubconsciousModel
        )
        if !effectiveSubconsciousModel.isEmpty, !currentProvider.isEmpty,
           seen.insert(currentID).inserted {
            let provider = appModel.providersList.first { $0.provider_id == currentProvider }
            choices.append(ReflectionModelChoice(
                id: currentID,
                providerID: currentProvider,
                modelID: effectiveSubconsciousModel,
                label: "\(effectiveSubconsciousModel) · \(provider?.display_name ?? currentProvider) — Unavailable",
                providerReady: false
            ))
        }
        return choices.sorted { lhs, rhs in
            if lhs.id == currentID { return true }
            if rhs.id == currentID { return false }
            if lhs.providerReady != rhs.providerReady { return lhs.providerReady && !rhs.providerReady }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private var effectiveSubconsciousProvider: String {
        let stored = subconsciousProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        if let live = reflectionRouteStatus?.providerID, !live.isEmpty { return live }
        return NativeCognitionRuntime.inferredReflectionProvider(for: effectiveSubconsciousModel)
    }

    private var effectiveSubconsciousModel: String {
        if let live = reflectionRouteStatus?.model, !live.isEmpty { return live }
        return subconsciousModel
    }

    private var currentReflectionChoiceID: String {
        reflectionChoiceID(providerID: effectiveSubconsciousProvider, modelID: effectiveSubconsciousModel)
    }

    private func reflectionChoiceID(providerID: String, modelID: String) -> String {
        providerID + "\u{1f}" + modelID
    }

    private var fullyRunning: Bool {
        subconsciousEnabled && capsuleEnabled && backgroundEnabled && reflectionEnabled
            && reflectionBudget > 0 && organismEnabled
            && reflectionRouteStatus?.isReady == true
    }

    // Attention = enabled-but-not-fully-running (orange) or an error. Surfaced
    // as a badge on the collapsed Advanced disclosure (B2.6c).
    private var attentionState: Bool {
        (subconsciousEnabled && !fullyRunning) || errorMessage != nil
    }

    private var statusLabel: String {
        if fullyRunning { return "Running with \(effectiveSubconsciousModel)" }
        if subconsciousEnabled, reflectionRouteStatus?.isReady != true { return "Needs LLM setup" }
        if subconsciousEnabled { return "Partially enabled" }
        return "Off"
    }

    private var statusSystemImage: String {
        if fullyRunning { return "checkmark.circle.fill" }
        if subconsciousEnabled { return "exclamationmark.triangle.fill" }
        return "circle"
    }

    private var statusColor: Color {
        if fullyRunning { return .green }
        if subconsciousEnabled { return .orange }
        return .secondary
    }

    @MainActor
    private func setSubconsciousEnabled(_ enabled: Bool) async {
        savingToggle = true
        defer { savingToggle = false }
        if enabled, !(await ensureReflectionRouteForEnable()) {
            subconsciousEnabled = false
            errorMessage = reflectionRouteStatus?.detail
                ?? "Connect a provider or choose an available LLM before enabling Subconscious."
            appModel.statusText = "Subconscious needs a ready reflection LLM"
            return
        }
        subconsciousEnabled = enabled
        capsuleEnabled = enabled
        backgroundEnabled = enabled
        reflectionEnabled = enabled
        organismEnabled = enabled
        if enabled && reflectionBudget <= 0 {
            reflectionBudget = 2
        }
        let actual = await NativeCognitionRuntime.shared.setSubconsciousMasterEnabled(
            enabled,
            reflectionBudget: enabled ? max(1, reflectionBudget) : 0
        )
        await refreshReflectionRouteStatus()
        applySubconsciousRuntimeState(actual)
        let fullyActive = actual.enabled && actual.capsuleEnabled
            && actual.backgroundEnabled && actual.reflectionEnabled
            && actual.reflectionBudget > 0 && actual.organismEnabled
            && reflectionRouteStatus?.isReady == true
        if enabled && !fullyActive {
            errorMessage = "Some Subconscious lanes are held off by setup, safety, or provider health."
            appModel.statusText = "Subconscious is only partially active"
        } else {
            errorMessage = nil
            appModel.statusText = enabled
                ? "Subconscious running with \(effectiveSubconsciousModel)"
                : "Subconscious disabled"
        }
    }

    @MainActor
    private func saveContextFlowMode(_ rawMode: String) async {
        guard let requested = ContextFlowMode(rawValue: rawMode) else {
            contextFlowMode = ContextFlowMode.shadow.rawValue
            return
        }
        savingContextFlow = true
        defer { savingContextFlow = false }
        let status = await NativeContextFlowRuntime.shared.setMode(requested)
        contextFlowStatus = status
        errorMessage = nil
        appModel.statusText = status.effectiveMode == requested
            ? "Fluid Context set to \(contextFlowModeLabel(status.effectiveMode))"
            : "Fluid Context is effectively \(contextFlowModeLabel(status.effectiveMode))"
    }

    private var contextFlowStatusText: String? {
        guard let status = contextFlowStatus else { return nil }
        if status.setupForcedOff {
            return "Effective: Off until setup is complete."
        }
        if status.environmentManaged {
            return "Effective: \(contextFlowModeLabel(status.effectiveMode)) · managed by the launch environment."
        }
        if status.effectiveMode.rawValue != contextFlowMode {
            return "Effective: \(contextFlowModeLabel(status.effectiveMode))."
        }
        return status.effectiveMode == .shadow
            ? "Observe Only measures selection without supplying it to replies."
            : nil
    }

    private func applySubconsciousRuntimeState(_ state: NativeSubconsciousRuntimeState) {
        subconsciousEnabled = state.enabled
        capsuleEnabled = state.capsuleEnabled
        backgroundEnabled = state.backgroundEnabled
        reflectionEnabled = state.reflectionEnabled
        reflectionBudget = state.reflectionBudget
        organismEnabled = state.organismEnabled
    }

    private func contextFlowModeLabel(_ mode: ContextFlowMode) -> String {
        switch mode {
        case .active: "Active"
        case .shadow: "Observe Only"
        case .off: "Off"
        }
    }

    @MainActor
    @discardableResult
    private func saveSubconsciousSelection(
        _ choice: ReflectionModelChoice,
        updateStatus: Bool = true
    ) async -> Bool {
        savingModel = true
        defer { savingModel = false }
        do {
            try await NativeCognitionRuntime.shared.setReflectionSelection(
                model: choice.modelID,
                provider: choice.providerID
            )
            subconsciousModel = choice.modelID
            subconsciousProvider = choice.providerID
            pendingReflectionChoiceID = nil
            await refreshReflectionRouteStatus()
            errorMessage = nil
            if updateStatus {
                appModel.statusText = reflectionRouteStatus?.isReady == true
                    ? "Subconscious LLM saved: \(choice.modelID)"
                    : "Subconscious LLM saved, but its provider is not ready"
            }
            return true
        } catch {
            pendingReflectionChoiceID = nil
            errorMessage = "Subconscious LLM save failed: \(error.localizedDescription)"
            appModel.statusText = errorMessage ?? appModel.statusText
            return false
        }
    }

    @MainActor
    private func refreshReflectionRouteStatus() async {
        reflectionRouteStatus = await NativeCognitionRuntime.shared.reflectionRouteStatus()
    }

    @MainActor
    private func ensureReflectionRouteForEnable() async -> Bool {
        _ = await appModel.loadProvidersForChat()
        let defaults = UserDefaults.standard
        let hasExplicitSelection = defaults.object(
            forKey: NativeCognitionRuntime.reflectionModelKey
        ) != nil || defaults.object(
            forKey: NativeCognitionRuntime.reflectionProviderKey
        ) != nil

        if hasExplicitSelection {
            await refreshReflectionRouteStatus()
            return reflectionRouteStatus?.isReady == true
        }

        let readyProviders = appModel.providersList.filter { $0.auth_status.state == "ready" }
        let chatProvider = readyProviders.first { $0.provider_id == appModel.chatProvider }
        let preferred: ReflectionModelChoice? = {
            if let chatProvider {
                let model = chatProvider.models.first { $0.id == appModel.chatModel }
                    ?? chatProvider.models.first
                if let model {
                    return ReflectionModelChoice(
                        id: reflectionChoiceID(providerID: chatProvider.provider_id, modelID: model.id),
                        providerID: chatProvider.provider_id,
                        modelID: model.id,
                        label: "\(model.name) · \(chatProvider.display_name)",
                        providerReady: true
                    )
                }
            }
            guard let provider = readyProviders.first,
                  let model = provider.models.first else { return nil }
            return ReflectionModelChoice(
                id: reflectionChoiceID(providerID: provider.provider_id, modelID: model.id),
                providerID: provider.provider_id,
                modelID: model.id,
                label: "\(model.name) · \(provider.display_name)",
                providerReady: true
            )
        }()
        guard let preferred else {
            await refreshReflectionRouteStatus()
            return false
        }
        return await saveSubconsciousSelection(preferred, updateStatus: false)
            && reflectionRouteStatus?.isReady == true
    }
}

// MARK: - Embeddings backend section
// Swift-native CoreML status for semantic memory retrieval. The Python
// sentence-transformers installer path is retired; this view reports whether
// the bundled CoreML MiniLM model is active, the user explicitly disabled
// embeddings (mock), the developer-test env var is opted in (mock), or the
// runtime is fail-closed because the MiniLM bundle is missing / failed to
// load.

private struct EmbeddingsSettingsSection: View {
    @Environment(AppModel.self) private var appModel
    // 2026-07-23 B2.6c: reports fail-closed / failed-install / status-error up
    // to the Advanced disclosure so the error state surfaces a warn badge when
    // this block is collapsed.
    @Binding var attention: Bool
    @State private var status: EmbeddingsStatus?
    @State private var loading = false
    @State private var memoryModeSaving = false
    @State private var releasingMemory = false
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        Section {
            if let s = status {
                rows(for: s)
            } else if loading {
                ProgressView("Checking memory backend…").controlSize(.small)
            } else {
                Text("Status unavailable.")
                    .foregroundStyle(.secondary).font(.caption)
            }
            if let err = errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(err).foregroundStyle(.orange).font(.caption)
                    Button {
                        Task { await refreshStatus() }
                    } label: {
                        Label("Retry Memory Status", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(loading)
                }
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("CoreML semantic embeddings run inside the Swift app for richer memory retrieval. No Python runtime or external install is required.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .task {
            await refreshStatus()
            attention = attentionState
        }
        .onChange(of: attentionState) { _, newValue in
            attention = newValue
        }
        .onDisappear { pollTask?.cancel() }
    }

    // Attention = fail-closed backend, failed install/reindex, or a status
    // fetch error. Surfaced as a badge on the collapsed Advanced disclosure.
    private var attentionState: Bool {
        if errorMessage != nil { return true }
        guard let s = status else { return false }
        if s.effectiveBackend == "unavailable" { return true }
        if s.installState?.state == "failed" { return true }
        if s.reindexState?.state == "failed" { return true }
        return false
    }

    @ViewBuilder
    private func rows(for s: EmbeddingsStatus) -> some View {
        let installState = s.installState?.state ?? "idle"
        let reindexState = s.reindexState?.state ?? "idle"

        // Row 1 — top-line status.
        HStack {
            Label("Advanced semantic embeddings", systemImage: "brain.head.profile")
            Spacer()
            statusBadge(for: s, installState: installState)
        }

        // Row 2 — model status and memory mode.
        // gpt-5.5 review-4 STILL-NEEDS-FIX: branch on `effectiveBackend` not
        // `libraryAvailable`. When config opts out (mock) but CoreML resources
        // happen to be missing, libraryAvailable == false but effective is
        // "hash" (mock) — the row should show the model/mode row, not the
        // fail-closed unavailable row. NativeClient maps effectiveBackend to:
        //   "local"       → CoreML active
        //   "hash"        → explicit mock (config opt-out OR env opt-in)
        //   "unavailable" → fail-closed (resources missing / load failed)
        switch installState {
        case "installing":
            installProgressView(state: s.installState)
        case "failed":
            failedInstallView(state: s.installState)
        default:
            if s.effectiveBackend == "unavailable" {
                modelUnavailableRow(for: s)
            } else {
                coreMLStatusRow(for: s)
                memoryModeRow(for: s)
            }
        }

        if s.requestedEnabled || reindexState == "running" || reindexState == "failed" {
            reindexStatusView(state: s.reindexState, active: s.effectiveBackend == "local")
        }
    }

    @ViewBuilder
    private func statusBadge(for s: EmbeddingsStatus, installState: String) -> some View {
        let reindexState = s.reindexState?.state ?? "idle"
        switch installState {
        case "installing":
            Label("Preparing…", systemImage: "arrow.down.circle")
                .labelStyle(.titleAndIcon).foregroundStyle(.blue).font(.caption)
        case "failed":
            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon).foregroundStyle(.orange).font(.caption)
        default:
            // gpt-5.5 review-4 STILL-NEEDS-FIX: badge branches on
            // `effectiveBackend` directly, not on `libraryAvailable`. The four
            // states map cleanly:
            //   "unavailable" → Fail-closed (only when resources missing AND
            //                   not explicitly opted out)
            //   "local"       → Active (CoreML running)
            //   "hash"        → Mock (explicit opt-out via config OR env
            //                   NATIVE_AGENT_EMBEDDING_MOCK opt-in)
            //   otherwise     → Off (catch-all for runtime-not-wired)
            if s.effectiveBackend == "unavailable" {
                // UI-6 (2026-08-01): "Fail-closed" is an internal term for the
                // same thing the install-failure branch above already calls
                // "Unavailable". One word, and it is the plain one.
                Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon).foregroundStyle(.orange).font(.caption)
            } else if reindexState == "running" {
                Label("Indexing…", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon).foregroundStyle(.blue).font(.caption)
            } else if s.effectiveBackend == "local" {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon).foregroundStyle(.green).font(.caption)
            } else if s.effectiveBackend == "hash" {
                Label("Mock", systemImage: "circle.dashed")
                    .labelStyle(.titleAndIcon).foregroundStyle(.secondary).font(.caption)
            } else {
                Text("Off").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func modelUnavailableRow(for s: EmbeddingsStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // gpt-5.5 review-2 follow-up: the runtime fails closed when the
            // CoreML resources aren't on disk — embed() throws rather than
            // returning mock vectors. UI string matches that behavior.
            // UI-6 (2026-08-01): the headline says what the user lost; the
            // model identifiers moved down into the secondary line below,
            // which NativeClient fills from EmbeddingPlainCopy.technicalDetail.
            Text(EmbeddingPlainCopy.headline(.modelMissing))
                .font(.caption).foregroundStyle(.secondary)
            if let detail = s.reindexState?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private func installProgressView(state: EmbeddingsInstallState?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let step = state?.currentStep, !step.isEmpty {
                Text(step).font(.caption).foregroundStyle(.secondary)
            }
            if let detail = state?.detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            let progress = max(0, min(100, state?.progress ?? 0))
            ProgressView(value: Double(progress), total: 100)
            HStack {
                Text("\(progress)%").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Safe to keep the app open while the model prepares.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func failedInstallView(state: EmbeddingsInstallState?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = state?.error {
                Text("Install error: \(err)").font(.caption).foregroundStyle(.orange)
            }
            if let detail = state?.detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
            HStack {
                Button {
                    Task { await refreshStatus() }
                } label: {
                    Label("Retry status", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder
    private func coreMLStatusRow(for s: EmbeddingsStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("CoreML embeddings", systemImage: "cpu")
                Spacer()
                Text(s.modelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // gpt-5.5 review-5 + review-6 STILL-NEEDS-FIX: branches keyed on
            // `effectiveBackend` (the badge layer's source of truth). The
            // final 'local' branch is explicit so an unknown future backend
            // value falls into a safe 'status unknown' string instead of
            // silently asserting "CoreML is running."
            // UI-6 (2026-08-01): plain headline per state. The Core ML /
            // MiniLM / env-var identifiers still ship — one line down, in the
            // technical caption, and in the model name row above.
            if s.effectiveBackend == "unavailable" {
                Text(EmbeddingPlainCopy.headline(.modelFailed))
                    .font(.caption).foregroundStyle(.orange)
                if let detail = EmbeddingPlainCopy.technicalDetail(.modelFailed) {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            } else if s.effectiveBackend == "hash" {
                Text(EmbeddingPlainCopy.headline(.testVectors))
                    .font(.caption).foregroundStyle(.secondary)
                if let detail = EmbeddingPlainCopy.technicalDetail(.testVectors) {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            } else if s.effectiveBackend == "local" {
                Text(EmbeddingPlainCopy.headline(.byMeaning))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Embedding backend status unknown (\(s.effectiveBackend)).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func memoryModeRow(for s: EmbeddingsStatus) -> some View {
        let currentMode = normalizedMemoryMode(s.memoryMode)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Memory mode", systemImage: "memorychip")
                Spacer()
                if memoryModeSaving || releasingMemory {
                    ProgressView().controlSize(.small)
                }
            }
            Picker("Memory mode", selection: Binding(
                get: { currentMode },
                set: { mode in Task { await setMemoryMode(mode) } }
            )) {
                Text("Fast").tag("performance")
                Text("Balanced").tag("balanced")
                Text("Low").tag("low_memory")
            }
            .pickerStyle(.segmented)
            .disabled(memoryModeSaving || releasingMemory)

            HStack(spacing: 8) {
                Text(memoryModeDescription(for: s))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if s.modelState?.loaded == true {
                    Button {
                        Task { await releaseMemoryNow() }
                    } label: {
                        Label("Release now", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(releasingMemory)
                }
            }
        }
    }

    @ViewBuilder
    private func reindexStatusView(state: EmbeddingsInstallState?, active: Bool) -> some View {
        let phase = state?.state ?? "idle"
        switch phase {
        case "running":
            VStack(alignment: .leading, spacing: 6) {
                Text(state?.currentStep ?? "Indexing existing memories")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(max(0, min(100, state?.progress ?? 0))), total: 100)
                HStack {
                    Text("\(max(0, min(100, state?.progress ?? 0)))%")
                    if let embedded = state?.embedded, let candidates = state?.candidates {
                        Text("Updated \(embedded)/\(candidates)")
                    }
                    Spacer()
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        case "failed":
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory index update failed.")
                    .font(.caption).foregroundStyle(.orange)
                if let detail = state?.detail, !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        case "complete":
            if active {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    if let embedded = state?.embedded, let skipped = state?.skipped {
                        Text("Existing memory index ready. Updated \(embedded), skipped \(skipped).")
                    } else {
                        Text("Existing memory index ready.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Actions

    @MainActor
    private func refreshStatus() async {
        loading = (status == nil)
        defer { loading = false }
        do {
            let fresh = try await appModel.fetchEmbeddingsStatus()
            status = fresh
            errorMessage = nil
            // If model prep or indexing is running, keep polling for progress.
            if fresh.installState?.state == "installing" || fresh.reindexState?.state == "running" {
                startPollingIfNeeded()
            }
        } catch {
            errorMessage = "Status check failed: \(error.localizedDescription)"
            if status == nil {
                startPollingIfNeeded()
            }
        }
    }

    private func startPollingIfNeeded() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            // Poll every 2s for up to 10 minutes.
            for _ in 0..<300 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                do {
                    let fresh = try await appModel.fetchEmbeddingsStatus()
                    status = fresh
                    let installState = fresh.installState?.state ?? "idle"
                    let reindexState = fresh.reindexState?.state ?? "idle"
                    if installState != "installing" && reindexState != "running" {
                        return
                    }
                } catch {
                    // Network blip — keep polling unless cancelled.
                    continue
                }
            }
            // Codex review caught: polling timeout would silently exit
            // with the UI stuck on the installing state. Surface what
            // happened so the user knows and can choose to refresh.
            errorMessage = "Memory status is taking longer than expected. Refresh the status and check app logs if it persists."
            await refreshStatus()
        }
    }

    private func normalizedMemoryMode(_ raw: String?) -> String {
        let value = raw ?? "balanced"
        switch value {
        case "performance", "balanced", "low_memory":
            return value
        default:
            return "balanced"
        }
    }

    private func memoryModeDescription(for s: EmbeddingsStatus) -> String {
        if let detail = s.memoryModeDetail?.detail, !detail.isEmpty {
            return detail
        }
        switch normalizedMemoryMode(s.memoryMode) {
        case "performance":
            return "Keeps the model hot for fastest recall."
        case "low_memory":
            return "Allows the model to release sooner when idle."
        default:
            return "Balances recall speed and memory use."
        }
    }

    @MainActor
    private func setMemoryMode(_ mode: String) async {
        memoryModeSaving = true
        defer { memoryModeSaving = false }
        do {
            let result = try await appModel.setEmbeddingsMemoryMode(mode: mode)
            status = result.status
            if let err = result.error {
                errorMessage = result.detail.map { "\(err): \($0)" } ?? err
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = "Memory mode update failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func releaseMemoryNow() async {
        releasingMemory = true
        defer { releasingMemory = false }
        do {
            let result = try await appModel.releaseEmbeddingsMemory()
            status = result.status
            errorMessage = result.error
        } catch {
            errorMessage = "Release failed: \(error.localizedDescription)"
        }
    }
}
