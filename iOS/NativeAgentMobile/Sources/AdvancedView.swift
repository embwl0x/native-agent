// PATCH-2026-05-07: ios-parity AdvancedView — Status / Runs log (read-only)
// PATCH-2026-05-07: mac-control-ui-1 Added Mac Tools section to AdvancedView
// PATCH-2026-05-10: sidebar-flatten — More menu rebuilt as a flat list of
// single-purpose destinations. Memory became a primary bottom tab. Added
// Personality / Connectors / Trust / Providers /
// Connection to the "Manage" section so core Mac surfaces stay reachable on
// iOS through one consistent overflow without nesting duplicate hubs.
// PATCH-2026-06-07: mac-integration-tab-ios — Mac Integration row added to
// the Manage section so the user can flip per-integration READ/WRITE toggles from
// his iPhone. Backed by NSUbiquitousKeyValueStore mirror of the Mac side.
// 2026-09-01 sweep item 20/36: WorkshopView shipped with no call site at all,
// so directed work could not be handed over from the phone even though the
// signed submit/approve/reject path was already wired. Mounted here — the
// launch-argument and notification routers already send "workshop" to More.
import SwiftUI
import NativeAgentShared

enum MoreAboutPresentation {
    static let text = "Some advanced controls require a live Mac connection. Skill installs, eval runs, and Workshop policy editing are Mac-only today. Desk changes sync with the paired Mac."
}

@MainActor
enum AdvancedHostViewStoreFactory {
    static func makeSettingsStore() -> SettingsStore {
        SettingsStore()
    }
}

private enum MorePowerUserDestination: CaseIterable, Identifiable {
    case knowledgeGraph
    case turnInspector
    case macTools

    var id: String { title }

    var title: String {
        switch self {
        case .knowledgeGraph: "Knowledge Graph"
        case .turnInspector: "Turn Inspector"
        case .macTools: "Mac Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .knowledgeGraph: "circle.hexagongrid"
        case .turnInspector: "waveform.path.ecg"
        case .macTools: "macbook.and.iphone"
        }
    }

    var sourceDescription: String {
        switch self {
        case .knowledgeGraph: "Mac-published iCloud snapshot"
        case .turnInspector: "Synced turn summaries"
        case .macTools: "Paired-Mac policy and actions"
        }
    }
}

// MARK: - AdvancedView (hidden behind "More" tab)

struct AdvancedView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @StateObject private var store = AdvancedStore()
    @State private var showPairingRecovery = false

    var body: some View {
        NavigationStack {
            List {
                if PairingSkipPresentation.showsRecoveryAffordance(isPaired: pairingStore.isPaired) {
                    Section {
                        Button {
                            showPairingRecovery = true
                        } label: {
                            Label("Pair with Mac", systemImage: "link.badge.plus")
                        }
                        .accessibilityHint("Opens pairing so this iPhone can reconnect to the Mac.")
                    } header: {
                        Label("Connection required", systemImage: "icloud.slash")
                            .font(AppFont.section)
                    }
                }

                // ── Manage — everything the Mac sidebar promotes to primary ──
                Section {
                    NavigationLink {
                        WorkshopView(embedInNavigationStack: false)
                    } label: {
                        Label("Workshop", systemImage: "hammer")
                    }
                    NavigationLink {
                        SkillsToolsView(embedInNavigationStack: false)
                    } label: {
                        Label("Skills & Tools", systemImage: "puzzlepiece.extension")
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
                    ForEach(MorePowerUserDestination.allCases) { destination in
                        NavigationLink {
                            powerUserDestination(destination)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(destination.title, systemImage: destination.systemImage)
                                Text(destination.sourceDescription)
                                    .font(AppFont.label)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                            Text(MoreAboutPresentation.text)
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
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    MacStatusChip()
                }
            }
            .sheet(isPresented: $showPairingRecovery) {
                PairingView(onSkip: {
                    showPairingRecovery = false
                }, onPaired: {
                    showPairingRecovery = false
                })
                .environmentObject(pairingStore)
            }
        }
        .macSyncErrorBanner()
    }

    @ViewBuilder
    private func powerUserDestination(_ destination: MorePowerUserDestination) -> some View {
        switch destination {
        case .knowledgeGraph:
            KnowledgeGraphView()
        case .turnInspector:
            TurnInspectorView()
        case .macTools:
            MacToolsView()
        }
    }
}

// PATCH-2026-05-10: tiny wrappers so the More menu can push the
// Personality / Connectors / Trust detail views that today live as
// sub-rows inside SettingsViewFull's NavigationLink list.  Each
// re-uses the same underlying detail view SettingsViewFull pushes to.
private struct PersonalityDetailHostView: View {
    @State private var store: SettingsStore?

    var body: some View {
        Group {
            if let store {
                PersonalityDetailView(store: store)
            } else {
                ProgressView("Loading Personality…")
            }
        }
        .onAppear { beginFreshPush() }
    }

    private func beginFreshPush() {
        let freshStore = AdvancedHostViewStoreFactory.makeSettingsStore()
        store = freshStore
        Task { await freshStore.refresh() }
    }
}

private struct ConnectorsHostView: View {
    @State private var store: SettingsStore?

    var body: some View {
        Group {
            if let store {
                ConnectorsView(store: store)
            } else {
                ProgressView("Loading Connectors…")
            }
        }
        .onAppear { beginFreshPush() }
    }

    private func beginFreshPush() {
        let freshStore = AdvancedHostViewStoreFactory.makeSettingsStore()
        store = freshStore
        Task { await freshStore.refresh() }
    }
}

private struct TrustHostView: View {
    @State private var store: SettingsStore?

    var body: some View {
        Group {
            if let store {
                TrustPolicyView(store: store)
            } else {
                ProgressView("Loading Trust Policy…")
            }
        }
        .onAppear { beginFreshPush() }
    }

    private func beginFreshPush() {
        let freshStore = AdvancedHostViewStoreFactory.makeSettingsStore()
        store = freshStore
        Task { await freshStore.refresh() }
    }
}

// MARK: - Store

enum RunsLogPresentation: Equatable {
    case content
    case empty
    case unavailable(String)

    static func state(runs: [RunRecord], error: String?) -> RunsLogPresentation {
        guard runs.isEmpty else { return .content }
        if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unavailable(error)
        }
        return .empty
    }
}

enum RunKindPresentation {
    static func displayName(_ kind: String) -> String {
        RunKindVocabulary.displayName(kind, on: .iOS)
    }

    static func icon(_ kind: String) -> String {
        switch kind.lowercased() {
        case "codex": return "terminal"
        case "claude": return "sparkles"
        case "swarm": return "circle.hexagongrid.fill"
        case "mission": return "target"
        default: return "questionmark.circle"
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

struct RunDetailModelFact: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

enum RunDetailPresentation {
    static func modelFacts(for run: RunRecord) -> [RunDetailModelFact] {
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }

        var facts: [RunDetailModelFact] = []
        let model = nonEmpty(run.model)
        if let model { facts.append(.init(label: "Model", value: model)) }
        if let requested = nonEmpty(run.requestedModel), requested != model {
            facts.append(.init(label: "Requested (substituted)", value: requested))
        }
        if let effort = nonEmpty(run.reasoningEffort) {
            facts.append(.init(label: "Reasoning effort", value: effort.capitalized))
        }
        if let sandbox = nonEmpty(run.codexSandbox) {
            facts.append(.init(label: "Sandbox", value: sandbox))
        }
        if let fileAccess = nonEmpty(run.fileAccessMode) {
            facts.append(.init(label: "File access", value: fileAccess))
        }
        return facts
    }
}

enum RunDetailCopyPresentation {
    static func successMessage(for section: String) -> String {
        let label = section.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty
            ? "Copied run detail to clipboard."
            : "Copied \(label) to clipboard."
    }
}

enum RunDetailPromptPresentation {
    static let unavailableDescription = "The prompt was not captured for this run."

    /// Keep the captured prompt verbatim for copy fidelity, but do not render a
    /// prompt section (or a Copy action) for a blank payload.
    static func copyablePrompt(_ prompt: String?) -> String? {
        guard let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return prompt
    }
}

enum OrganismStatusPresentation {
    enum SnapshotState: Equatable {
        case available
        case disabled
        case unavailable(reason: String?)
        case invalidTimestamp(futureBy: TimeInterval)
        case stale(age: TimeInterval)
        case absent

        var displaysDetails: Bool {
            switch self {
            case .available, .stale: true
            case .disabled, .unavailable, .invalidTimestamp, .absent: false
            }
        }
    }

    struct DreamProposalSlice: Equatable {
        let visible: [OrganismLivingStandingViewProposalFile]
        let hiddenCount: Int
    }

    static func approvedBiasesText(_ value: Int?) -> String {
        value.map(String.init) ?? "Not reported"
    }

    static func canApprove(_ candidate: OrganismLivingReflexCandidateFile) -> Bool {
        candidate.trustClass == "lowRisk" && candidate.reviewRequired
    }

    static func isStale(generatedAt: Date, now: Date = Date(), maximumAge: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(generatedAt) > maximumAge
    }

    static func snapshotState(
        for organism: OrganismLivingStatusFile?,
        now: Date = Date(),
        maximumAge: TimeInterval = 300,
        maximumFutureClockSkew: TimeInterval = 60
    ) -> SnapshotState {
        guard let organism else { return .absent }
        switch organism.availabilityState {
        case .unavailable:
            return .unavailable(reason: organism.unavailableReason)
        case .disabled:
            return .disabled
        case .live:
            let age = now.timeIntervalSince(organism.generatedAt)
            let allowedFutureSkew = max(0, maximumFutureClockSkew)
            if age < -allowedFutureSkew {
                return .invalidTimestamp(futureBy: -age)
            }
            return age > maximumAge ? .stale(age: age) : .available
        }
    }

    static func staleAgeText(_ age: TimeInterval) -> String {
        let seconds = max(0, Int(age.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    struct ReflexCandidateSlice: Equatable {
        let visible: [OrganismLivingReflexCandidateFile]
        let hiddenCount: Int
    }

    static func reflexCandidateSlice(
        _ candidates: [OrganismLivingReflexCandidateFile],
        visibleLimit: Int = 6
    ) -> ReflexCandidateSlice {
        .init(visible: Array(candidates.prefix(visibleLimit)), hiddenCount: max(0, candidates.count - visibleLimit))
    }

    static func removingLocallyFinalizedCandidate(
        id: String,
        from candidates: [OrganismLivingReflexCandidateFile]
    ) -> [OrganismLivingReflexCandidateFile] {
        candidates.filter { $0.id != id }
    }

    static func dreamProposalSlice(
        _ proposals: [OrganismLivingStandingViewProposalFile],
        visibleLimit: Int = 4
    ) -> DreamProposalSlice {
        .init(visible: Array(proposals.prefix(visibleLimit)), hiddenCount: max(0, proposals.count - visibleLimit))
    }
}

@MainActor
final class AdvancedStore: ObservableObject {
    @Published var health: RuntimeHealth?
    @Published var runs: [RunRecord] = []
    @Published private(set) var healthLoadError: String?
    @Published private(set) var runsLoadError: String?
    private var healthRefreshInFlight = false
    private var runsRefreshInFlight = false

    func refreshHealth() async {
        guard !healthRefreshInFlight else { return }
        healthRefreshInFlight = true
        defer { healthRefreshInFlight = false }
        let engine = iCloudSyncEngine.shared
        let outcome = await engine.refreshHealthSnapshot()
        health = engine.health
        switch outcome {
        case .refreshed:
            healthLoadError = nil
        case .partial:
            healthLoadError = "Some Health snapshots are still downloading from iCloud."
        case .unavailable:
            healthLoadError = "Health snapshot is still downloading from iCloud. Try again in a moment."
        case .superseded:
            healthLoadError = "Health refresh was superseded by a sync reconfiguration. Try again."
        }
    }

    func refreshRuns() async {
        guard !runsRefreshInFlight else { return }
        runsRefreshInFlight = true
        defer { runsRefreshInFlight = false }
        let engine = iCloudSyncEngine.shared
        let outcome = await engine.refreshRunsSnapshot()
        runs = engine.runs
        switch outcome {
        case .refreshed:
            runsLoadError = nil
        case .unavailable:
            runsLoadError = "Runs snapshot is still downloading from iCloud. Try again in a moment."
        case .superseded:
            runsLoadError = "Runs refresh was superseded by a sync reconfiguration. Try again."
        case .partial:
            runsLoadError = "Some Runs data is still downloading from iCloud."
        }
    }

    func applySyncedRuns(_ next: [RunRecord]) {
        if next != runs { runs = next }
        if !next.isEmpty { runsLoadError = nil }
    }
}

// MARK: - Status detail

enum MacHealthPresentation {
    enum Snapshot {
        case available(RuntimeHealth)
        case unavailable
    }

    static let unavailableTitle = "Mac health is unavailable"
    static let unavailableDetail = "Waiting for a health snapshot from the Mac."

    static func snapshot(for health: RuntimeHealth?) -> Snapshot {
        guard let health else { return .unavailable }
        return .available(health)
    }
}

/// One freshness contract for Mac-owned iCloud snapshots on the phone. Every
/// screen that reports a snapshot age must use this threshold rather than
/// deciding independently when a snapshot becomes stale.
enum MobileSnapshotFreshnessPresentation {
    static let staleAfter: TimeInterval = 30

    static func isStale(lastSyncedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSyncedAt) > staleAfter
    }
}

enum StatusConnectionPresentation {
    enum SyncState: Equatable {
        case current(age: TimeInterval)
        case stale(age: TimeInterval, limit: TimeInterval)
        case neverSynced
        case clockMismatch(futureBy: TimeInterval)
    }

    static func syncState(
        lastSyncedAt: Date?,
        now: Date = Date(),
        staleAfter: TimeInterval = MobileSnapshotFreshnessPresentation.staleAfter,
        maximumFutureClockSkew: TimeInterval = 60
    ) -> SyncState {
        guard let lastSyncedAt else { return .neverSynced }

        let age = now.timeIntervalSince(lastSyncedAt)
        if age < -max(0, maximumFutureClockSkew) {
            return .clockMismatch(futureBy: -age)
        }
        let limit = max(0, staleAfter)
        return age > limit ? .stale(age: age, limit: limit) : .current(age: max(0, age))
    }

    static func ageText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    static func cardValue(for state: SyncState) -> String {
        switch state {
        case .current(let age): return "Fresh · \(ageText(age)) ago"
        case .stale(let age, _): return "STALE · \(ageText(age)) old"
        case .neverSynced: return "Never synced"
        case .clockMismatch: return "Clock mismatch"
        }
    }

    static func detail(for state: SyncState) -> String? {
        switch state {
        case .current:
            return nil
        case .stale(_, let limit):
            return "Expected a newer iCloud snapshot within \(ageText(limit))."
        case .neverSynced:
            return "No iCloud snapshot has reached this phone yet."
        case .clockMismatch(let futureBy):
            return "The Mac snapshot is \(ageText(futureBy)) ahead of this phone."
        }
    }

    static func needsAttention(_ state: SyncState) -> Bool {
        switch state {
        case .current: false
        case .stale, .neverSynced, .clockMismatch: true
        }
    }
}

struct StatusDetailView: View {
    @ObservedObject var store: AdvancedStore
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var decidingReflexID: String?
    @State private var locallyFinalizedReflexIDs = Set<String>()
    @State private var reflexDecisionErrors: [String: String] = [:]

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
                let syncState = StatusConnectionPresentation.syncState(
                    lastSyncedAt: iCloudSyncEngine.shared.lastSyncAt
                )
                StatCard(
                    label: "Last synced",
                    value: StatusConnectionPresentation.cardValue(for: syncState),
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: StatusConnectionPresentation.needsAttention(syncState)
                        ? .orange
                        : NativeAgentPalette.agentAccent
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                if let detail = StatusConnectionPresentation.detail(for: syncState) {
                    Text(detail)
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Mac") {
                switch MacHealthPresentation.snapshot(for: store.health) {
                case .available(let health):
                    if let healthLoadError = store.healthLoadError {
                        Label(healthLoadError, systemImage: "exclamationmark.triangle")
                            .font(AppFont.label)
                            .foregroundStyle(.orange)
                    }
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
                case .unavailable:
                    Label(MacHealthPresentation.unavailableTitle, systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text(store.healthLoadError ?? MacHealthPresentation.unavailableDetail)
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                }
            }
            if let organism = sync.organismLivingStatus {
                let organismState = OrganismStatusPresentation.snapshotState(for: organism)
                Section(sync.agentDisplayName) {
                    if organismState.displaysDetails {
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
                        Text(OrganismStatusPresentation.approvedBiasesText(organism.counters.approvedReflexBiases))
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
                    if case .stale(let age) = organismState {
                        Label("STALE · \(OrganismStatusPresentation.staleAgeText(age)) old — waiting for a newer Mac snapshot", systemImage: "clock.badge.exclamationmark")
                            .font(AppFont.label)
                            .foregroundStyle(.orange)
                    }
                    } else {
                        switch organismState {
                        case .disabled:
                            Label("Organism body is disabled — no live body readout is available.", systemImage: "power")
                                .foregroundStyle(.secondary)
                        case .unavailable(let reason):
                            Label("Organism status is unavailable", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(reason ?? "The Mac could not complete this status snapshot.")
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                        case .invalidTimestamp(let futureBy):
                            Label("Organism status timestamp is invalid", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                            Text("The Mac timestamp is \(OrganismStatusPresentation.staleAgeText(futureBy)) ahead of this phone.")
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                        case .available, .stale, .absent:
                            EmptyView()
                        }
                    }
                }
                let candidateSlice: OrganismStatusPresentation.ReflexCandidateSlice = organismState.displaysDetails
                    ? OrganismStatusPresentation.reflexCandidateSlice(
                        (organism.reflexCandidates ?? []).filter { !locallyFinalizedReflexIDs.contains($0.id) }
                    )
                    : .init(visible: [], hiddenCount: 0)
                if !candidateSlice.visible.isEmpty {
                    Section("Reflex review") {
                        ForEach(candidateSlice.visible) { candidate in
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
                                    .disabled(!OrganismStatusPresentation.canApprove(candidate) || decidingReflexID == candidate.id)

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
                            if let error = reflexDecisionErrors[candidate.id] {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        if candidateSlice.hiddenCount > 0 {
                            Text("\(candidateSlice.hiddenCount) more reflex candidate\(candidateSlice.hiddenCount == 1 ? "" : "s") need review on the Mac.")
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                let proposalSlice: OrganismStatusPresentation.DreamProposalSlice = organismState.displaysDetails
                    ? OrganismStatusPresentation.dreamProposalSlice(organism.standingViewProposals ?? [])
                    : .init(visible: [], hiddenCount: 0)
                if !proposalSlice.visible.isEmpty {
                    Section("Dream proposals") {
                        ForEach(proposalSlice.visible) { proposal in
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
                        if proposalSlice.hiddenCount > 0 {
                            Text("\(proposalSlice.hiddenCount) more proposal\(proposalSlice.hiddenCount == 1 ? "" : "s") can be reviewed on the Mac.")
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section(sync.agentDisplayName) {
                    Label("ABSENT — living status is not reporting yet", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("The phone has not received an organism status snapshot. This is different from a healthy zero.")
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
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
        reflexDecisionErrors.removeValue(forKey: candidate.id)
        Task {
            do {
                if approve {
                    _ = try await iCloudSyncEngine.shared.approveOrganismReflex(candidateId: candidate.id)
                } else {
                    _ = try await iCloudSyncEngine.shared.retireOrganismReflex(candidateId: candidate.id)
                }
                locallyFinalizedReflexIDs.insert(candidate.id)
            } catch {
                reflexDecisionErrors[candidate.id] = error.localizedDescription
            }
            decidingReflexID = nil
        }
    }
}

// MARK: - Runs log

struct RunsLogView: View {
    @ObservedObject var store: AdvancedStore
    @ObservedObject private var sync = iCloudSyncEngine.shared

    var body: some View {
        List {
            switch RunsLogPresentation.state(runs: store.runs, error: store.runsLoadError) {
            case .unavailable(let error):
                AppEmptyState(
                    title: "Runs are not available",
                    systemImage: "exclamationmark.triangle",
                    kind: .unavailable,
                    description: error
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            case .empty:
                AppEmptyState(
                    title: "No Runs Yet",
                    systemImage: "list.bullet.clipboard",
                    kind: .empty,
                    description: "The latest Mac run snapshot contains no runs."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            case .content:
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
        .onChange(of: sync.runs) { _, runs in
            store.applySyncedRuns(runs)
        }
    }
}

private struct RunRowView: View {
    let run: RunRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: RunKindPresentation.icon(run.kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RunKindPresentation.tint(run.kind))
                .frame(width: 32, height: 32)
                .background(RunKindPresentation.tint(run.kind).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(RunKindPresentation.displayName(run.kind))
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
                    Image(systemName: RunKindPresentation.icon(run.kind))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(RunKindPresentation.tint(run.kind))
                        .frame(width: 44, height: 44)
                        .background(RunKindPresentation.tint(run.kind).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(RunKindPresentation.displayName(run.kind))
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

            let modelFacts = RunDetailPresentation.modelFacts(for: run)
            if !modelFacts.isEmpty {
                Section("Model") {
                    ForEach(modelFacts) { fact in
                        LabeledContent(fact.label, value: fact.value)
                    }
                }
            }

            if let prompt = RunDetailPromptPresentation.copyablePrompt(run.prompt) {
                runTextSection("Prompt", systemImage: "text.bubble", text: prompt)
            } else {
                Section {
                    Text(RunDetailPromptPresentation.unavailableDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Prompt", systemImage: "text.bubble")
                        .font(AppFont.section)
                }
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
                        iOSSystemToastCenter.shared.push(
                            success: RunDetailCopyPresentation.successMessage(for: title)
                        )
                    }
                }
        } header: {
            Label(title, systemImage: systemImage)
                .font(AppFont.section)
        }
    }
}
