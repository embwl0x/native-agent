import EngineRuntime
import SwiftUI
import NativeAgentShared
import ProviderRouting
import Cognition
import BackgroundLoops
// Blueprint: | `SetupMindsView.swift` | Personality minds tab shares the Memory and mind group transaction |

/// Use the canonical group transaction so reflection and the daily hour stay aligned.
struct SetupStudioWanderPicker: View {
    @Environment(AppModel.self) private var appModel
    @State private var pendingProvider: String?
    @State private var pendingModel: String?
    @State private var saving = false
    @State private var errorMessage: String?

    private let surface = NativeCognitionRuntime.studioWanderSurface
    private var providers: [ProviderInfo] { appModel.engine.providers.connections }
    private var preference: SurfacePreference? { appModel.engine.providers.settings?.routing.preferences[surface] }
    private var activeProvider: String { pendingProvider ?? appModel.engine.providers.settings?.routing.activeProviders[surface] ?? "" }
    private var model: String { pendingModel ?? preference?.model ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appModel.engine.providers.settings == nil {
                ProgressView().controlSize(.small)
            } else if providers.isEmpty {
                Text("Connect a provider to choose Memory and mind.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 8) {
                    Picker("Memory and mind — provider", selection: Binding(
                        get: { activeProvider },
                        set: { newValue in
                            pendingProvider = newValue
                            pendingModel = ""
                        }
                    )) {
                        Text("Choose provider").tag("")
                        ForEach(providers) { provider in
                            let ready = provider.auth_status.eligible
                            Text(provider.display_name + (ready ? "" : " ⚠️"))
                                .tag(provider.provider_id)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

                    Picker("Memory and mind — model", selection: Binding(
                        get: { model },
                        set: { newValue in
                            pendingModel = newValue
                            Task { await save() }
                        }
                    )) {
                        Text("Choose model").tag("")
                        if !model.isEmpty, !models(for: activeProvider).contains(where: { $0.id == model }) {
                            Text(model + " — unavailable").tag(model)
                        }
                        ForEach(models(for: activeProvider)) { item in
                            Text(item.name).tag(item.id)
                                .disabled(item.supported_reasoning_efforts == nil)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .disabled(saving)
                .font(.callout)
            }
            if let errorMessage = errorMessage ?? appModel.engine.providers.settingsError {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func models(for providerID: String) -> [NativeAgentShared.ProviderModelInfo] {
        providers.first { $0.provider_id == providerID }?.models ?? []
    }

    @MainActor
    private func save() async {
        guard !activeProvider.isEmpty, !model.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await appModel.engine.saveProviderGroupSelection(
                group: ProviderSurfaceGroups.mind,
                providerID: activeProvider,
                model: model,
                reasoningEffort: ProvidersFacade.normalizedReasoningEffort(
                    from: appModel.engine.providers.catalog,
                    providers: appModel.engine.providers.connections,
                    providerID: activeProvider,
                    model: model,
                    selected: preference?.reasoningEffort ?? ""
                ),
                serviceTier: preference?.serviceTier
            )
            errorMessage = nil
            appModel.statusText = "Memory and mind → \(model) saved"
            pendingProvider = nil
            pendingModel = nil
        } catch {
            errorMessage = UserFacingError.message(error, action: "save Memory and mind")
        }
    }
}

// MARK: - Minds (Advanced)

/// Reflection and the daily hour share Memory and mind; Chat choices belong to the composer and Providers.
struct SetupMindsView: View {
    @AppStorage(StudioWanderLane.enabledDefaultsKey) private var studioWanderEnabled = StudioWanderLane.enabledByDefault

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                AdvancedSection(
                    title: "Memory and mind",
                    card: .single,
                    note: studioWanderEnabled
                        ? "The provider and model for Memory and mind, including reflection and my daily hour."
                        : "The provider and model for Memory and mind, including reflection. My daily hour is off."
                ) {
                    SetupStudioWanderPicker()
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("\(AgentVoice.live.possessive) minds")
    }
}
