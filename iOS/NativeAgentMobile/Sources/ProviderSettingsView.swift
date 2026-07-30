// PATCH-2026-07-15: iOS ProviderSettingsView — signed remote control for the
// Mac-owned provider configuration. API keys are never stored or edited here;
// atomic surface selections and connection tests cross the authenticated action
// channel and are accepted only after the Mac returns a matching verified tuple.
import SwiftUI

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
        "chat", "ios", "telegram", "slack", "missions", "autonomy", "swarms",
        "dream", "rem", "training", "memory", "heartbeat", "diagnostics",
        "cognition_reflection", "compaction",
    ]

    /// Exact ordered surfaces accepted by the signed Mac action router.
    private var renderedSurfaces: [String] {
        Self.canonicalSurfaces
    }

    // Active provider per surface (local UI state; saves on change)
    @State private var activeSurface: [String: String] = [:]
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
                                    let previous = activeSurface[surface] ?? defaultProviderID
                                    activeSurface[surface] = newVal
                                    sendSelection(
                                        surface: surface,
                                        providerId: newVal,
                                        modelId: compatibleModel(for: surface, providerId: newVal),
                                        previousProviderId: previous
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
                                        sendSelection(
                                            surface: surface,
                                            providerId: activeSurface[surface] ?? defaultProviderID,
                                            modelId: model.id,
                                            previousProviderId: activeSurface[surface] ?? defaultProviderID
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
        await iCloudSyncEngine.shared.refreshProviderControlsSnapshot()
        seedActiveSurface()
        isRefreshing = false
    }

    private func seedActiveSurface() {
        let synced = sync.trustPolicy?.providerPolicy?.activePerSurface ?? [:]
        let readyProviderIds = Set(selectableProviders.map(\.provider_id))
        for surface in renderedSurfaces {
            if let providerId = sync.surfaceModels[surface]?.providerId,
               readyProviderIds.contains(providerId) {
                activeSurface[surface] = providerId
            } else if let providerId = synced[surface], readyProviderIds.contains(providerId) {
                activeSurface[surface] = providerId
            } else if let current = activeSurface[surface],
                      readyProviderIds.contains(current) {
                continue
            } else {
                activeSurface[surface] = defaultProviderID
            }
        }
    }

    private func compatibleModel(for surface: String, providerId: String) -> String {
        let models = selectableModels(for: providerId)
        let current = sync.surfaceModels[surface]?.model
        if let current, models.contains(where: { $0.id == current }) { return current }
        return models.first?.id ?? ""
    }

    private func sendSelection(
        surface: String,
        providerId: String,
        modelId: String,
        previousProviderId: String
    ) {
        Task {
            do {
                guard !modelId.isEmpty else {
                    throw NSError(
                        domain: "ProviderSettingsView",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "That provider has no selectable model."]
                    )
                }
                let preference = sync.surfaceModels[surface]
                _ = try await iCloudSyncEngine.shared.configureSurfaceSelection(
                    surface: surface,
                    providerId: providerId,
                    model: modelId,
                    reasoningEffort: preference?.reasoningEffort ?? "high",
                    serviceTier: preference?.serviceTier ?? "default"
                )
                await refreshProviders()
                statusText = "\(surfaceLabel(surface)) now uses \(modelId)."
            } catch {
                activeSurface[surface] = previousProviderId
                statusText = "Error: \(error.localizedDescription)"
                iOSSystemToastCenter.shared.push(
                    error: "Couldn't update \(surfaceLabel(surface)): \(error.localizedDescription)"
                )
            }
        }
    }

    private func selectedModelLabel(for surface: String) -> String {
        sync.surfaceModels[surface]?.model ?? "(not set)"
    }

    private func surfaceLabel(_ surface: String) -> String {
        switch surface {
        case "chat":      return "Chat"
        case "ios":       return "iPhone"
        case "missions":  return "Workshop" // Stable provider-surface wire id.
        case "training":  return "Training"
        case "dream":     return "Dream"
        case "telegram":  return "Telegram"
        case "slack":     return "Slack"
        case "autonomy":  return "Autonomy"
        case "swarms":    return "Swarms"
        case "rem":       return "REM"
        case "memory":    return "Memory"
        case "heartbeat": return "Heartbeat"
        case "diagnostics": return "Diagnostics"
        case "cognition_reflection": return "Cognition Reflection"
        default:          return surface.capitalized
        }
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
                if let model = provider.models.first {
                    Section {
                        HStack(spacing: 8) {
                            capPill("Streaming", ok: model.supports_streaming)
                            capPill("Vision", ok: model.supports_vision)
                            capPill("Tools", ok: model.supports_tools)
                            capPill("JSON", ok: model.supports_json_mode)
                        }
                    } header: {
                        Label("Capabilities (\(model.name))", systemImage: "cpu")
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
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "ok" {
            feedbackText = successPrefix
        } else if trimmed.lowercased().contains("error") || trimmed.lowercased().contains("failed") {
            feedbackText = "Error: \(trimmed)"
        } else {
            feedbackText = "\(successPrefix) \(trimmed)"
        }
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
