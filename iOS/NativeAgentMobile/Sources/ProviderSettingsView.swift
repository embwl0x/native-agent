// PATCH-2026-07-15: iOS ProviderSettingsView — signed remote control for the
// Mac-owned provider configuration. API keys are never stored or edited here;
// atomic surface selections and connection tests cross the authenticated action
// channel and are accepted only after the Mac returns a matching verified tuple.
import SwiftUI

/// Keeps the refresh button honest once its spinner stops: a failed provider
/// snapshot refresh remains visible instead of looking like an empty success.
enum ProviderRefreshPresentation {
    static func statusText(for outcome: ProviderControlsRefreshOutcome) -> String {
        outcome.feedbackMessage ?? ""
    }
}

/// iOS cannot import the Mac-only provider-routing module, so it retains a
/// presentation mirror for the canonical routing surfaces. Unknown or malformed
/// wire keys must read as a repair condition, never as a plausible prettified
/// storage key such as `Cognition_reflection`.
enum MobileProviderSurfaceLabelPresentation: Equatable {
    case named(String)
    case unrecognized(String)
    case malformed

    private static let namedLabels: [String: String] = [
        "chat": "Chat",
        "ios": "iPhone",
        "telegram": "Telegram",
        "slack": "Slack",
        "desk": "Desk",
        "workshop": "Workshop",
        "missions": "Workshop",
        "autonomy": "Autonomy",
        "swarms": "Swarms",
        "dream": "Dream",
        "rem": "REM",
        "training": "Training",
        "memory": "Memory",
        "heartbeat": "Heartbeat",
        "diagnostics": "Diagnostics",
        "cognition_reflection": "Cognition Reflection",
        "studio_wander": "Studio Wandering",
        "compaction": "Compaction",
        "self_improvement": "Self-Improvement",
    ]

    static func presentation(for rawSurface: String) -> Self {
        let trimmed = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == rawSurface, rawSurface == rawSurface.lowercased() else {
            return .malformed
        }
        guard let label = namedLabels[rawSurface] else { return .unrecognized(rawSurface) }
        return .named(label)
    }

    var text: String {
        switch self {
        case .named(let label): label
        case .unrecognized(let surface): "Unrecognized surface (\(surface))"
        case .malformed: "Surface label unavailable"
        }
    }
}

/// Model pins are Mac-owned and arrive in `surfaceModels`. Keep their visible
/// state separate from an absent projection: a published pin must always be
/// shown verbatim, while a missing row says the phone is still waiting for the
/// Mac instead of looking like an intentional unset selection.
enum MobileProviderSurfaceModelMenuPresentation {
    static let unpublishedLabel = "Model not published"

    static func label(for surface: String, surfaceModels: [String: SurfaceModelPref]) -> String {
        guard let rawModel = surfaceModels[surface]?.model else {
            return unpublishedLabel
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return unpublishedLabel
        }
        return model
    }
}

/// A signed action reply proves a provider test passed only when the Mac uses
/// its explicit `ok` status. An absent or unfamiliar payload is an incomplete
/// test result, not evidence that the connection works.
enum ProviderConnectionTestPresentation {
    static func feedback(status: String, successPrefix: String = "Test complete.") -> String {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Error: Mac did not return a test result."
        }
        guard trimmed.lowercased() == "ok" else {
            if ["error", "failed", "needs_credentials"].contains(trimmed.lowercased()) {
                return "Error: \(trimmed)"
            }
            return "Error: Mac returned an unrecognized test status: \(trimmed)"
        }
        return successPrefix
    }
}

/// Provider/model changes are optimistic. A response may arrive after the user
/// has picked another tuple, so only the request that still owns a surface may
/// restore its former selection.
enum ProviderSelectionRollbackPresentation {
    struct Selection: Equatable {
        let providerID: String
        let modelID: String
    }

    static func rollback(
        currentGeneration: UInt64,
        requestGeneration: UInt64,
        previous: Selection
    ) -> Selection? {
        currentGeneration == requestGeneration ? previous : nil
    }

    static func acceptReceipt(
        _ receipt: MobileSurfaceSelectionReceipt,
        currentGeneration: UInt64,
        requestGeneration: UInt64
    ) -> Selection? {
        guard currentGeneration == requestGeneration else { return nil }
        return Selection(providerID: receipt.providerID, modelID: receipt.model)
    }
}

// MARK: - Main View

struct ProviderSettingsView: View {
    @StateObject private var sync = iCloudSyncEngine.shared

    // CANONICAL SURFACE LIST — SOURCE OF TRUTH is the Mac's `MODEL_SURFACES`
    // (Modules/NativeAgentCore/Sources/ProviderRouting/ProviderRouting.swift,
    // Swift-native model routing). iOS cannot import ProviderRouting (it pulls
    // in the macOS-only NativeAgentCore graph), so this list is mirrored by hand
    // and defended by ProviderSettingsSurfaceContractTests, which requires
    // exact equality with the Mac action router's accepted surfaces.
    // If you add a surface to MODEL_SURFACES, append it here too (keep order).
    // Last synced 2026-07-15.
    static let canonicalSurfaces = [
        "chat", "ios", "telegram", "slack", "desk", "workshop", "autonomy", "swarms",
        "dream", "rem", "training", "memory", "heartbeat", "diagnostics",
        "cognition_reflection", "compaction", "self_improvement",
        // Added 2026-09-02 with MODEL_SURFACES (personality depth item 9).
        "studio_wander",
    ]

    /// Exact ordered surfaces accepted by the signed Mac action router.
    private var renderedSurfaces: [String] {
        Self.canonicalSurfaces
    }

    // Active provider per surface (local UI state; saves on change)
    @State private var activeSurface: [String: String] = [:]
    @State private var requestedModel: [String: String] = [:]
    @State private var pendingSurfaceReceipts: [String: MobileSurfaceSelectionReceipt] = [:]
    @State private var selectionGeneration: [String: UInt64] = [:]
    @State private var configSheet: ProviderInfo? = nil
    @State private var statusText = ""
    @State private var isRefreshing = false

    private var selectableProviders: [ProviderInfo] {
        sync.providers.filter { $0.auth_status.state == "ready" }
    }

    private var defaultProviderID: String {
        selectableProviders.first?.provider_id ?? ""
    }

    private func selectableModels(for providerID: String) -> [ProviderModelInfo] {
        sync.providers.first(where: { $0.provider_id == providerID })?.models ?? []
    }

    var body: some View {
        List {
            // ── Per-surface active picker ─────────────────────────────────
            Section {
                if selectableProviders.isEmpty {
                    Text("Connect a provider on the Mac to configure surfaces.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(renderedSurfaces, id: \.self) { surface in
                    if !selectableProviders.isEmpty {
                        HStack {
                            Text(surfaceLabel(surface))
                                .frame(width: 80, alignment: .leading)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { activeSurface[surface] ?? defaultProviderID },
                                set: { newVal in
                                    guard let selection = SurfaceProviderPickerPresentation.selection(
                                        providerID: newVal,
                                        currentModelID: sync.surfaceModels[surface]?.model,
                                        providers: selectableProviders
                                    ) else {
                                        statusText = "That provider has no selectable model."
                                        return
                                    }
                                    submitSelection(
                                        surface: surface,
                                        selection: .init(
                                            providerID: selection.providerID,
                                            modelID: selection.modelID
                                        )
                                    )
                                }
                            )) {
                                ForEach(selectableProviders) { p in
                                    Text(p.display_name)
                                        .tag(p.provider_id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    HStack {
                        Text("\(surfaceLabel(surface)) Model")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                        Spacer()
                        if selectableProviders.isEmpty {
                            Text("No connected provider models.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        } else {
                            Menu {
                                ForEach(selectableModels(for: activeSurface[surface] ?? defaultProviderID)) { model in
                                    Button {
                                        submitSelection(
                                            surface: surface,
                                            selection: .init(
                                                providerID: activeSurface[surface] ?? defaultProviderID,
                                                modelID: model.id
                                            )
                                        )
                                    } label: {
                                        Text(model.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(selectedModelLabel(for: surface))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Label("Active per Surface", systemImage: "square.3.layers.3d.top.filled")
            } footer: {
                Text("Changes are applied on the Mac immediately.")
                    .font(.caption2)
            }

            // ── Provider list ─────────────────────────────────────────────
            Section {
                if isRefreshing {
                    HStack {
                        ProgressView()
                        Text("Refreshing…").font(.callout).foregroundStyle(.secondary)
                    }
                } else if sync.providers.isEmpty {
                    ContentUnavailableView(
                        "No Providers",
                        systemImage: "server.rack",
                        description: Text("Mac must be running and syncing via iCloud.")
                    )
                } else {
                    ForEach(sync.providers) { provider in
                        Button {
                            configSheet = provider
                        } label: {
                            ProviderRow(provider: provider)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Label("Providers", systemImage: "server.rack")
            }

            // ── Status feedback ───────────────────────────────────────────
            if !statusText.isEmpty {
                Section {
                    Text(statusText)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Providers")
        .macSyncErrorBanner()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await refreshProviders() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
        }
        .sheet(item: $configSheet) { provider in
            ProviderDetailSheet(provider: provider, onDone: {
                configSheet = nil
                statusText = "Action sent to Mac."
                // Trigger snapshot refresh after a short delay to pick up Mac updates
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await refreshProviders()
                }
            })
        }
        .onAppear {
            seedActiveSurface()
            if sync.surfaceModels.isEmpty || sync.providers.isEmpty {
                Task {
                    _ = await iCloudBridge.shared.drainDeviceTransport()
                    await sync.refreshProviderControlsSnapshot()
                    seedActiveSurface()
                }
            }
        }
        .onChange(of: sync.providers) { _, _ in
            seedActiveSurface()
        }
        .onChange(of: sync.surfaceModels) { _, _ in
            seedActiveSurface()
        }
    }

    // MARK: - Helpers

    private func refreshProviders() async {
        isRefreshing = true
        _ = await iCloudBridge.shared.drainDeviceTransport()
        let outcome = await iCloudSyncEngine.shared.refreshProviderControlsSnapshot()
        seedActiveSurface()
        statusText = ProviderRefreshPresentation.statusText(for: outcome)
        isRefreshing = false
    }

    private func seedActiveSurface() {
        let synced = sync.trustPolicy?.providerPolicy?.activePerSurface ?? [:]
        let readyProviderIds = Set(selectableProviders.map(\.provider_id))
        for surface in renderedSurfaces {
            if let receipt = pendingSurfaceReceipts[surface] {
                guard receipt.isAcknowledged(by: sync.surfaceModels[surface]) else { continue }
                pendingSurfaceReceipts.removeValue(forKey: surface)
            }
            if let providerId = sync.surfaceModels[surface]?.providerId,
               readyProviderIds.contains(providerId) {
                activeSurface[surface] = providerId
                requestedModel[surface] = sync.surfaceModels[surface]?.model
            } else if let providerId = synced[surface], readyProviderIds.contains(providerId) {
                activeSurface[surface] = providerId
                requestedModel[surface] = selectableModels(for: providerId).first?.id
            } else if let current = activeSurface[surface],
                      readyProviderIds.contains(current) {
                continue
            } else {
                activeSurface[surface] = defaultProviderID
                requestedModel[surface] = selectableModels(for: defaultProviderID).first?.id
            }
        }
    }

    private func currentSelection(for surface: String) -> ProviderSelectionRollbackPresentation.Selection {
        let providerID = activeSurface[surface] ?? defaultProviderID
        let modelID = requestedModel[surface]
            ?? sync.surfaceModels[surface]?.model
            ?? selectableModels(for: providerID).first?.id
            ?? ""
        return .init(providerID: providerID, modelID: modelID)
    }

    private func submitSelection(
        surface: String,
        selection: ProviderSelectionRollbackPresentation.Selection
    ) {
        let previous = currentSelection(for: surface)
        let requestGeneration = (selectionGeneration[surface] ?? 0) &+ 1
        selectionGeneration[surface] = requestGeneration
        pendingSurfaceReceipts.removeValue(forKey: surface)
        activeSurface[surface] = selection.providerID
        requestedModel[surface] = selection.modelID
        sendSelection(
            surface: surface,
            selection: selection,
            previous: previous,
            requestGeneration: requestGeneration
        )
    }

    private func sendSelection(
        surface: String,
        selection: ProviderSelectionRollbackPresentation.Selection,
        previous: ProviderSelectionRollbackPresentation.Selection,
        requestGeneration: UInt64
    ) {
        Task {
            do {
                guard !selection.modelID.isEmpty else {
                    throw NSError(
                        domain: "ProviderSettingsView",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "That provider has no selectable model."]
                    )
                }
                let preference = sync.surfaceModels[surface]
                let receipt = try await iCloudSyncEngine.shared.configureSurfaceSelection(
                    surface: surface,
                    providerId: selection.providerID,
                    model: selection.modelID,
                    reasoningEffort: preference?.reasoningEffort ?? "high",
                    serviceTier: preference?.serviceTier ?? "default"
                )
                guard let committed = ProviderSelectionRollbackPresentation.acceptReceipt(
                    receipt, currentGeneration: selectionGeneration[surface] ?? 0,
                    requestGeneration: requestGeneration
                ) else { return }
                activeSurface[surface] = committed.providerID
                requestedModel[surface] = committed.modelID
                pendingSurfaceReceipts[surface] = receipt
                // The signed reply is already authoritative. Do not await a
                // second refresh whose stale snapshot could race a newer pick.
                seedActiveSurface()
                statusText = "\(surfaceLabel(surface)) now uses \(receipt.model)."
            } catch {
                guard let restored = ProviderSelectionRollbackPresentation.rollback(
                    currentGeneration: selectionGeneration[surface] ?? 0,
                    requestGeneration: requestGeneration,
                    previous: previous
                ) else { return }
                activeSurface[surface] = restored.providerID
                requestedModel[surface] = restored.modelID
                statusText = "Error: \(error.localizedDescription)"
                iOSSystemToastCenter.shared.push(
                    error: "Couldn't update \(surfaceLabel(surface)): \(error.localizedDescription)"
                )
            }
        }
    }

    private func selectedModelLabel(for surface: String) -> String {
        if let requested = requestedModel[surface], !requested.isEmpty { return requested }
        return MobileProviderSurfaceModelMenuPresentation.label(
            for: surface,
            surfaceModels: sync.surfaceModels
        )
    }

    private func surfaceLabel(_ surface: String) -> String {
        MobileProviderSurfaceLabelPresentation.presentation(for: surface).text
    }
}

/// Produces the only provider/model pair the surface picker may submit. A
/// provider switch retains the current model when possible; otherwise it uses
/// the provider's first advertised model rather than emitting a mismatched
/// pair.
enum SurfaceProviderPickerPresentation {
    struct Selection: Equatable {
        let providerID: String
        let modelID: String
    }

    static func selection(
        providerID: String,
        currentModelID: String?,
        providers: [ProviderInfo]
    ) -> Selection? {
        guard let provider = providers.first(where: { $0.provider_id == providerID }),
              let fallbackModel = provider.models.first else {
            return nil
        }
        let modelID: String
        if let currentModelID,
           provider.models.contains(where: { $0.id == currentModelID }) {
            modelID = currentModelID
        } else {
            modelID = fallbackModel.id
        }
        return Selection(providerID: providerID, modelID: modelID)
    }

    static func rollbackProviderID(previousProviderID: String) -> String {
        previousProviderID
    }
}

// MARK: - Provider row

private struct ProviderRow: View {
    let provider: ProviderInfo

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.display_name)
                    .font(.headline)
                Text(provider.auth_modes.joined(separator: " / "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProviderStatusBadge(state: provider.auth_status.state)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Status badge

private struct ProviderStatusBadge: View {
    let state: String

    var label: String {
        switch state {
        case "ready":       return "Ready"
        case "needs_key":   return "Needs Key"
        case "needs_oauth": return "OAuth"
        case "error":       return "Error"
        default:            return state.capitalized
        }
    }

    var color: Color {
        switch state {
        case "ready":       return .green
        case "error":       return .red
        default:            return .orange
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Detail / action sheet

enum ProviderCapabilityPresentation {
    struct Model: Identifiable, Equatable {
        let id: String
        let name: String
        let supportsStreaming: Bool
        let supportsVision: Bool
        let supportsTools: Bool
        let supportsJSONMode: Bool
    }

    static func models(from source: [ProviderModelInfo]) -> [Model] {
        source.enumerated().map { index, model in
            let displayName = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return Model(
                id: "\(index):\(model.id)",
                name: displayName.isEmpty ? model.id : displayName,
                supportsStreaming: model.supports_streaming,
                supportsVision: model.supports_vision,
                supportsTools: model.supports_tools,
                supportsJSONMode: model.supports_json_mode
            )
        }
    }
}

struct ProviderDetailSheet: View {
    let provider: ProviderInfo
    let onDone: () -> Void

    @State private var isWorking = false
    @State private var workLabel = ""
    @State private var feedbackText = ""

    init(provider: ProviderInfo, onDone: @escaping () -> Void) {
        self.provider = provider
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Status section ────────────────────────────────────────
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        ProviderStatusBadge(state: provider.auth_status.state)
                    }
                    if !provider.auth_status.detail.isEmpty {
                        Text(provider.auth_status.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let userInfo = provider.auth_status.user_info, !userInfo.isEmpty {
                        ForEach(Array(userInfo.prefix(3)), id: \.key) { kv in
                            HStack {
                                Text(kv.key).foregroundStyle(.secondary).font(.footnote)
                                Spacer()
                                Text(kv.value).font(.footnote)
                            }
                        }
                    }
                } header: {
                    Label("Status", systemImage: "info.circle")
                }

                // ── Capabilities ──────────────────────────────────────────
                let capabilityModels = ProviderCapabilityPresentation.models(from: provider.models)
                if capabilityModels.isEmpty {
                    Section {
                        Label("The Mac has not published model capabilities for this provider yet.", systemImage: "questionmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Label("Capabilities", systemImage: "cpu")
                    }
                } else {
                    ForEach(capabilityModels) { model in
                        Section {
                            HStack(spacing: 8) {
                                capPill("Streaming", ok: model.supportsStreaming)
                                capPill("Vision", ok: model.supportsVision)
                                capPill("Tools", ok: model.supportsTools)
                                capPill("JSON", ok: model.supportsJSONMode)
                            }
                        } header: {
                            Label("Capabilities (\(model.name))", systemImage: "cpu")
                        }
                    }
                }

                // ── API Key section (api_key providers only) ───────────────
                if provider.auth_modes.contains("api_key") {
                    Section {
                        Label("API keys stay on the Mac. Open the Mac Providers view to add or rotate credentials.", systemImage: "macbook.and.iphone")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } header: {
                        Label("API Key", systemImage: "key.fill")
                    }
                }

                // ── OAuth section ─────────────────────────────────────────
                if provider.auth_modes.contains("oauth") {
                    Section {
                        Label("OAuth must begin in the Mac Providers view, where the browser callback and recovered credential state can be verified.", systemImage: "macbook.and.iphone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Label("OAuth / Subscription", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }

                // ── Actions ───────────────────────────────────────────────
                Section {
                    Button {
                        sendAction("test")
                    } label: {
                        Label(isWorking && workLabel == "test" ? "Testing…" : "Test Connection", systemImage: "network")
                    }
                    .disabled(isWorking)

                } header: {
                    Label("Actions", systemImage: "bolt")
                } footer: {
                    Text("The test runs on the Mac. Results appear here after the signed action completes.")
                        .font(.caption2)
                }

                // ── Feedback ──────────────────────────────────────────────
                if !feedbackText.isEmpty {
                    Section {
                        Text(feedbackText)
                            .font(.footnote)
                            .foregroundStyle(feedbackText.hasPrefix("Error") ? Color.red : .secondary)
                    }
                }
            }
            .navigationTitle(provider.display_name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { onDone() }
                }
            }
        }
    }

    // MARK: - Actions

    private func sendAction(_ kind: String) {
        isWorking = true
        workLabel = kind
        feedbackText = ""
        Task {
            do {
                switch kind {
                case "test":
                    let status = try await iCloudSyncEngine.shared.testProvider(providerId: provider.provider_id)
                    finish(status: status, successPrefix: "Test complete.")

                default:
                    isWorking = false
                }
            } catch {
                feedbackText = "Error: \(error.localizedDescription)"
                isWorking = false
            }
        }
    }

    private func finish(status: String, successPrefix: String) {
        isWorking = false
        feedbackText = ProviderConnectionTestPresentation.feedback(
            status: status,
            successPrefix: successPrefix
        )
    }

    @ViewBuilder
    private func capPill(_ label: String, ok: Bool) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ok ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
            .foregroundStyle(ok ? Color.green : Color.secondary)
            .clipShape(Capsule())
    }
}
