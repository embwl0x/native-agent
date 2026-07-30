// PATCH-2026-05-07: ios-parity AdvancedView — Status / Runs log (read-only)
// PATCH-2026-05-07: mac-control-ui-1 Added Mac Tools section to AdvancedView
// PATCH-2026-05-10: sidebar-flatten — More menu rebuilt as a flat list of
// single-purpose destinations.  Memory + Skills came out (now primary bottom
// tabs). Added Workshop / Personality / Connectors / Trust / Providers /
// Connection to the "Manage" section so core Mac surfaces stay reachable on
// iOS through one consistent overflow without nesting duplicate hubs.
// PATCH-2026-06-07: mac-integration-tab-ios — Mac Integration row added to
// the Manage section so the user can flip per-integration READ/WRITE toggles from
// his iPhone. Backed by NSUbiquitousKeyValueStore mirror of the Mac side.
import SwiftUI
import NativeAgentShared

// MARK: - AdvancedView (hidden behind "More" tab)

struct AdvancedView: View {
    @StateObject private var store = AdvancedStore()
    var body: some View {
        NavigationStack {
            List {
                // ── Manage — everything the Mac sidebar promotes to primary ──
                Section {
                    NavigationLink {
                        WorkshopView()
                    } label: {
                        Label("Workshop", systemImage: "target")
                    }
                    NavigationLink {
                        PersonalityDetailHostView()
                    } label: {
                        Label("Personality", systemImage: "person.crop.circle")
                    }
                    NavigationLink {
                        ConnectorsHostView()
                    } label: {
                        Label("Connectors", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    NavigationLink {
                        TrustHostView()
                    } label: {
                        Label("Trust", systemImage: "lock.shield")
                    }
                    NavigationLink {
                        MacIntegrationView()
                    } label: {
                        Label("Mac Integration", systemImage: "macbook.and.iphone")
                    }
                    NavigationLink {
                        ProviderSettingsView()
                    } label: {
                        Label("Providers", systemImage: "server.rack")
                    }
                    NavigationLink {
                        SettingsViewFull()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } header: {
                    Label("Manage", systemImage: "slider.horizontal.3")
                        .font(AppFont.section)
                }

                // ── Power user — opt-in deep surfaces ──
                Section {
                    NavigationLink {
                        KnowledgeGraphView()
                    } label: {
                        Label("Knowledge Graph", systemImage: "circle.hexagongrid")
                    }
                    NavigationLink {
                        TurnInspectorView()
                    } label: {
                        Label("Turn Inspector", systemImage: "waveform.path.ecg")
                    }
                    NavigationLink {
                        MacToolsView()
                    } label: {
                        Label("Mac Tools", systemImage: "macbook.and.iphone")
                    }
                } header: {
                    Label("Power user", systemImage: "bolt.circle")
                        .font(AppFont.section)
                }

                // ── Diagnostics ──
                Section {
                    NavigationLink("Status") {
                        StatusDetailView(store: store)
                    }
                    NavigationLink("Runs Log") {
                        RunsLogView(store: store)
                    }
                } header: {
                    Label("Diagnostics", systemImage: "stethoscope")
                        .font(AppFont.section)
                }

                Section {
                    GlassCard(tint: NativeAgentPalette.agentAccent.opacity(0.5)) {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(NativeAgentPalette.agentAccent)
                            Text("Some advanced controls require a live Mac connection. Skill installs, eval runs, and Workshop policy editing are Mac-only today.")
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Label("About", systemImage: "info.circle")
                        .font(AppFont.section)
                }
            }
            .navigationTitle("More")
        }
    }
}

// PATCH-2026-05-10: tiny wrappers so the More menu can push the
// Personality / Connectors / Trust detail views that today live as
// sub-rows inside SettingsViewFull's NavigationLink list.  Each
// re-uses the same underlying detail view SettingsViewFull pushes to.
private struct PersonalityDetailHostView: View {
    @StateObject private var store = SettingsStore()
    var body: some View {
        PersonalityDetailView(store: store)
            .onAppear { Task { await store.refresh() } }
    }
}

private struct ConnectorsHostView: View {
    @StateObject private var store = SettingsStore()
    var body: some View {
        ConnectorsView(store: store)
            .onAppear { Task { await store.refresh() } }
    }
}

private struct TrustHostView: View {
    @StateObject private var store = SettingsStore()
    var body: some View {
        TrustPolicyView(store: store)
            .onAppear { Task { await store.refresh() } }
    }
}

// MARK: - Store

@MainActor
final class AdvancedStore: ObservableObject {
    @Published var health: RuntimeHealth?
    @Published var runs: [RunRecord] = []
    @Published var isLoading = false

    func refreshHealth() async {
        isLoading = true
        await iCloudSyncEngine.shared.refreshHealthSnapshot()
        health = iCloudSyncEngine.shared.health
        isLoading = false
    }

    func refreshRuns() async {
        isLoading = true
        await iCloudSyncEngine.shared.refreshRunsSnapshot()
        runs = iCloudSyncEngine.shared.runs
        isLoading = false
    }
}

// MARK: - Status detail

struct StatusDetailView: View {
    @ObservedObject var store: AdvancedStore
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var decidingReflexID: String?
    @State private var reflexDecisionError: String?

    var body: some View {
        List {
            Section("Connection") {
                StatCard(
                    label: "State",
                    value: bridgeClient.bridgeStatus.displayName,
                    systemImage: "antenna.radiowaves.left.and.right",
                    tint: bridgeClient.bridgeStatus.color
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                StatCard(
                    label: "Transport",
                    value: pairingStore.usesICloudTransport ? "iCloud" : "Unpaired",
                    systemImage: "network",
                    tint: NativeAgentPalette.agentAccent
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let lastSeen = bridgeClient.lastSeenAt {
                    LabeledContent("Last seen") {
                        Text(lastSeen, style: .relative).foregroundStyle(.secondary)
                    }
                }
                if let syncAt = iCloudSyncEngine.shared.lastSyncAt {
                    LabeledContent("Last synced") {
                        Text(syncAt, style: .relative)
                            .foregroundStyle(Date().timeIntervalSince(syncAt) > 30 ? .orange : .secondary)
                    }
                }
            }
            if let health = store.health {
                Section("Mac") {
                    StatCard(
                        label: "App",
                        value: health.app,
                        systemImage: "app.badge",
                        tint: NativeAgentPalette.agentAccent
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    StatCard(
                        label: "Version",
                        value: health.version,
                        systemImage: "tag",
                        tint: NativeAgentPalette.agentAccent
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    LabeledContent("OK") {
                        Image(systemName: health.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(health.ok ? .green : .red)
                    }
                }
            }
            if let organism = sync.organismLivingStatus {
                Section(sync.agentDisplayName) {
                    let needsAttention = organism.needsAttention == true
                    StatCard(
                        label: "Posture",
                        value: organism.posture.capitalized,
                        systemImage: organism.needsUser
                            ? "person.crop.circle.badge.exclamationmark"
                            : (needsAttention ? "exclamationmark.triangle" : "waveform.path.ecg"),
                        tint: organism.needsUser ? .orange : (needsAttention ? .yellow : .green)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    StatCard(
                        label: "Behavior",
                        value: organism.behaviorLine,
                        systemImage: "slider.horizontal.3",
                        tint: NativeAgentPalette.agentAccent
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    if let bodyLine = organism.bodyLine, !bodyLine.isEmpty {
                        Text(bodyLine)
                            .font(AppFont.label)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Body") {
                        Text(organism.enabled ? "on" : "off")
                            .foregroundStyle(organism.enabled ? Color.green : Color.secondary)
                    }
                    LabeledContent("Signals") {
                        Text("\(organism.signalCount)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Needs review") {
                        Text("\(organism.counters.reflexesNeedReview)")
                            .foregroundStyle(organism.counters.reflexesNeedReview > 0 ? Color.orange : Color.secondary)
                    }
                    LabeledContent("Approved biases") {
                        Text("\(organism.counters.approvedReflexBiases ?? 0)")
                            .foregroundStyle((organism.counters.approvedReflexBiases ?? 0) > 0 ? Color.green : Color.secondary)
                    }
                    LabeledContent("iPhone") {
                        Text(organism.body.iPhoneReachable ? "reachable" : "stale")
                            .foregroundStyle(organism.body.iPhoneReachable ? Color.green : Color.orange)
                    }
                    LabeledContent("Resources") {
                        Text(organism.body.resourcePressure)
                            .foregroundStyle(organism.body.resourcePressure == "nominal" ? Color.secondary : Color.orange)
                    }
                    LabeledContent("Body updated") {
                        Text(organism.generatedAt, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }
                let candidates = organism.reflexCandidates ?? []
                if !candidates.isEmpty {
                    Section("Reflex review") {
                        ForEach(candidates.prefix(6)) { candidate in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(candidate.trustClass)
                                        .font(AppFont.tag)
                                        .foregroundStyle(candidate.trustClass == "lowRisk" ? Color.green : Color.orange)
                                    Text("\(Int((candidate.confidence * 100).rounded()))%")
                                        .font(AppFont.tag)
                                        .foregroundStyle(.secondary)
                                    if candidate.autoActivationAllowed {
                                        Label("Biasing", systemImage: "checkmark.seal.fill")
                                            .font(AppFont.tag)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text(candidate.pattern)
                                    .font(AppFont.label)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 10) {
                                    Button {
                                        decideReflex(candidate, approve: true)
                                    } label: {
                                        Label("Approve", systemImage: "checkmark")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(candidate.trustClass != "lowRisk" || decidingReflexID == candidate.id)

                                    Button(role: .destructive) {
                                        decideReflex(candidate, approve: false)
                                    } label: {
                                        Label("Retire", systemImage: "archivebox")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(decidingReflexID == candidate.id)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                let proposals = organism.standingViewProposals ?? []
                if !proposals.isEmpty {
                    Section("Dream proposals") {
                        ForEach(proposals.prefix(4)) { proposal in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(proposal.title)
                                    .font(AppFont.label)
                                Text(proposal.rationale)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !proposal.evidenceIDs.isEmpty {
                                    Text("\(proposal.evidenceIDs.count) linked evidence item\(proposal.evidenceIDs.count == 1 ? "" : "s")")
                                        .font(AppFont.tag)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                if let reflexDecisionError {
                    Section {
                        Text(reflexDecisionError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Status")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refreshHealth() }
        .refreshable { await store.refreshHealth() }
    }

    private func decideReflex(_ candidate: OrganismLivingReflexCandidateFile, approve: Bool) {
        decidingReflexID = candidate.id
        reflexDecisionError = nil
        Task {
            do {
                if approve {
                    _ = try await iCloudSyncEngine.shared.approveOrganismReflex(candidateId: candidate.id)
                } else {
                    _ = try await iCloudSyncEngine.shared.retireOrganismReflex(candidateId: candidate.id)
                }
            } catch {
                reflexDecisionError = error.localizedDescription
            }
            decidingReflexID = nil
        }
    }
}

// MARK: - Runs log

/// Presentation facts for a run kind — icon + tint + display name in one
/// place so the row and detail view can't drift apart.
private enum RunKindStyle {
    static func displayName(_ kind: String) -> String {
        switch kind.lowercased() {
        case "codex": return "Codex"
        // `claude` remains a compatibility identifier on the wire. The public
        // UI names the actual integration instead of a maintainer nickname.
        case "claude": return "Claude Code"
        case "swarm": return "Swarm"
        case "mission": return "Workshop"
        default: return kind.capitalized
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind.lowercased() {
        case "codex": return "terminal"
        case "claude": return "sparkles"
        case "swarm": return "circle.hexagongrid.fill"
        case "mission": return "target"
        default: return "gearshape.2"
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind.lowercased() {
        case "codex": return .teal
        case "claude": return NativeAgentPalette.agentAccent
        case "swarm": return .orange
        case "mission": return .blue
        default: return .secondary
        }
    }
}

struct RunsLogView: View {
    @ObservedObject var store: AdvancedStore

    var body: some View {
        List {
            if store.runs.isEmpty {
                AppEmptyState(
                    title: "No Runs Yet",
                    systemImage: "list.bullet.clipboard",
                    description: "Codex, swarm, and Workshop runs on the Mac land here — or the snapshot is still syncing. Pull to refresh."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(store.runs) { run in
                    NavigationLink {
                        RunDetailView(run: run)
                    } label: {
                        RunRowView(run: run)
                    }
                }
            }
        }
        .navigationTitle("Runs Log")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refreshRuns() }
        .refreshable { await store.refreshRuns() }
    }
}

private struct RunRowView: View {
    let run: RunRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: RunKindStyle.icon(run.kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RunKindStyle.tint(run.kind))
                .frame(width: 32, height: 32)
                .background(RunKindStyle.tint(run.kind).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(RunKindStyle.displayName(run.kind))
                        .font(AppFont.section)
                    Spacer()
                    StatusBadge(status: run.status)
                }
                if let prompt = run.prompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(UserDisplayFormatters.humanizeISOTimestamp(run.createdAt))
                    if let duration = run.durationSeconds {
                        Text("·")
                        Text(UserDisplayFormatters.humanizeDuration(duration))
                    }
                    if let model = run.model, !model.isEmpty {
                        Text("·")
                        Text(model).lineLimit(1)
                    }
                }
                .font(AppFont.tag)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Recorded \(run.createdAt)")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Run detail

/// Full record for one run: what ran, with which model/settings, the whole
/// prompt, and the whole output/error. Content stays on plain list rows —
/// no glass on the content layer.
struct RunDetailView: View {
    let run: RunRecord

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: RunKindStyle.icon(run.kind))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(RunKindStyle.tint(run.kind))
                        .frame(width: 44, height: 44)
                        .background(RunKindStyle.tint(run.kind).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(RunKindStyle.displayName(run.kind))
                            .font(AppFont.title)
                        Text(UserDisplayFormatters.humanizeISOTimestamp(run.createdAt))
                            .font(AppFont.label)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(status: run.status)
                }
                .padding(.vertical, 2)
                if let duration = run.durationSeconds {
                    LabeledContent("Duration", value: UserDisplayFormatters.humanizeDuration(duration))
                }
                if let date = UserDisplayFormatters.parseISOTimestamp(run.createdAt) {
                    LabeledContent("Started") {
                        Text(date, format: .dateTime.month().day().hour().minute().second())
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Run ID") {
                    Text(run.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            let nonEmpty: (String?) -> Bool = { !($0 ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            let hasModelFacts = nonEmpty(run.model) || nonEmpty(run.requestedModel)
                || nonEmpty(run.reasoningEffort) || nonEmpty(run.codexSandbox) || nonEmpty(run.fileAccessMode)
            if hasModelFacts {
                Section("Model") {
                    if let model = run.model, !model.isEmpty {
                        LabeledContent("Model", value: model)
                    }
                    if let requested = run.requestedModel, !requested.isEmpty, requested != run.model {
                        LabeledContent("Requested", value: requested)
                    }
                    if let effort = run.reasoningEffort, !effort.isEmpty {
                        LabeledContent("Reasoning effort", value: effort.capitalized)
                    }
                    if let sandbox = run.codexSandbox, !sandbox.isEmpty {
                        LabeledContent("Sandbox", value: sandbox)
                    }
                    if let fileAccess = run.fileAccessMode, !fileAccess.isEmpty {
                        LabeledContent("File access", value: fileAccess)
                    }
                }
            }

            if let prompt = run.prompt, !prompt.isEmpty {
                runTextSection("Prompt", systemImage: "text.bubble", text: prompt)
            }
            if let error = run.error, !error.isEmpty {
                Section {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } header: {
                    Label("Error", systemImage: "exclamationmark.triangle")
                        .font(AppFont.section)
                        .foregroundStyle(.red)
                }
            }
            if let output = run.output, !output.isEmpty {
                runTextSection("Output", systemImage: "text.alignleft", text: output)
            }
        }
        .navigationTitle("Run Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runTextSection(_ title: String, systemImage: String, text: String) -> some View {
        Section {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy \(title)", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                    }
                }
        } header: {
            Label(title, systemImage: systemImage)
                .font(AppFont.section)
        }
    }
}
