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
    static let text = "Some advanced controls require a live Mac connection. Skill installs, eval runs, and Desk policy editing are Mac-only today. Desk changes sync with the paired Mac."
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
    @Binding var deskTaskNavigationTarget: MobileDeskTaskNotificationIntent?

    init(deskTaskNavigationTarget: Binding<MobileDeskTaskNotificationIntent?> = .constant(nil)) {
        _deskTaskNavigationTarget = deskTaskNavigationTarget
    }
    @EnvironmentObject private var pairingStore: PairingStore
    @StateObject private var store = AdvancedStore()
    @State private var showPairingRecovery = false
    @State private var showDesignScreen = MobileDesignSamples.screen != nil
    #if DEBUG
    @StateObject private var designApprovals = ApprovalsStore()
    @StateObject private var designInbox = InboxStore()
    #endif

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
                            .font(.headline)
                    }
                }

                // ── Manage — everything the Mac sidebar promotes to primary ──
                Section {
                    NavigationLink {
                        WorkshopView(embedInNavigationStack: false)
                    } label: {
                        Label("Desk tasks", systemImage: "hammer").foregroundStyle(.primary)
                    }
                    NavigationLink {
                        SkillsToolsView(embedInNavigationStack: false)
                    } label: {
                        Label("Skills & Tools", systemImage: "puzzlepiece.extension").foregroundStyle(.primary)
                    }
                    NavigationLink {
                        PersonalityDetailHostView()
                    } label: {
                        Label("Personality", systemImage: "person.crop.circle").foregroundStyle(.primary)
                    }
                    NavigationLink {
                        ConnectorsHostView()
                    } label: {
                        Label("Connectors", systemImage: "point.3.connected.trianglepath.dotted").foregroundStyle(.primary)
                    }
                    NavigationLink {
                        TrustHostView()
                    } label: {
                        Label("Trust", systemImage: "lock.shield").foregroundStyle(.primary)
                    }
                    NavigationLink {
                        MacIntegrationView()
                    } label: {
                        Label("Mac Integration", systemImage: "macbook.and.iphone").foregroundStyle(.primary)
                    }
                    NavigationLink {
                        ProviderSettingsView()
                    } label: {
                        Label("Providers", systemImage: "server.rack").foregroundStyle(.primary)
                    }
                    NavigationLink {
                        SettingsViewFull()
                    } label: {
                        Label("Settings", systemImage: "gearshape").foregroundStyle(.primary)
                    }
                } header: {
                    Label("Manage", systemImage: "slider.horizontal.3")
                        .font(.headline)
                }

                // ── Power user — opt-in deep surfaces ──
                Section {
                    ForEach(MorePowerUserDestination.allCases) { destination in
                        NavigationLink {
                            powerUserDestination(destination)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(destination.title, systemImage: destination.systemImage).foregroundStyle(.primary)
                                Text(destination.sourceDescription)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Label("Power user", systemImage: "bolt.circle")
                        .font(.headline)
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
                        .font(.headline)
                }

                Section {
                    MobileReadingSurface {
                        MobileAdaptiveRow(spacing: 12) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text(MoreAboutPresentation.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Label("About", systemImage: "info.circle")
                        .font(.headline)
                }
            }
            .mobileReadingScreen()
            .navigationTitle("More")
            .navigationDestination(item: $deskTaskNavigationTarget) { intent in
                WorkshopView(embedInNavigationStack: false, notifiedTaskID: intent.taskID)
                    .id(intent.id)
            }
            #if DEBUG
            .navigationDestination(isPresented: $showDesignScreen) {
                designDestination
                    .allowsHitTesting(false)
            }
            #endif
            .safeAreaInset(edge: .top, spacing: 0) {
                MacStatusChip().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
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
    private var designDestination: some View {
        #if DEBUG
        switch MobileDesignSamples.screen {
        case "settings": SettingsViewFull()
        case "providers": ProviderSettingsView()
        case "pairing": PairingView()
        case "approvals": ApprovalsView(embedInNavigationStack: false).environmentObject(designApprovals)
        case "inbox": InboxView(embedInNavigationStack: false).environmentObject(designInbox)
        case "autonomy": AutonomyView()
        case "mac-tools": MacToolsView()
        case "mac-integration": MacIntegrationView()
        case "skills": SkillsToolsView(embedInNavigationStack: false)
        case "graph": KnowledgeGraphView()
        case "turns": TurnInspectorView()
        case "workshop": WorkshopView(embedInNavigationStack: false)
        case "desk": MobileDeskView()
        case "status": StatusDetailView(store: store)
        case "runs": RunsLogView(store: store)
        case "toast":
            VStack(spacing: 0) {
                MacSnapshotFreshnessBadge(lastSyncedAt: nil)
                Spacer()
            }
            .mobileReadingScreen()
            .navigationTitle("Connection updates")
            .onAppear { iOSSystemToastCenter.shared.push(info: "The latest project summary is available on the Mac.") }
        default: EmptyView()
        }
        #endif
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

struct StatusDetailView: View {
    @ObservedObject var store: AdvancedStore
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @ObservedObject private var cloudReplies = iCloudBridge.shared
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var decidingReflexID: String?
    @State private var locallyFinalizedReflexIDs = Set<String>()
    @State private var reflexDecisionErrors: [String: String] = [:]

    var body: some View {
        List {
            if !cloudReplies.unverifiedRecords.isEmpty {
                // 2026-09-08: a Mac record the phone could not verify is deferred, not
                // hidden; name it so a person can see what is stuck and why.
                Section("Unverified Mac records") {
                    ForEach(cloudReplies.unverifiedRecords) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.kind).font(.headline)
                            Text("Sender: \(record.sender)")
                            Text(record.timestamp, style: .date)
                            Text(record.timestamp, style: .time)
                            Text(record.reason).font(.caption)
                            Text("Pairing version: \(record.pairingVersion)").font(.caption)
                            Text(record.id).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            Section("Connection") {
                MobileReadingStat(
                    label: "State",
                    value: bridgeClient.bridgeStatus.displayName,
                    systemImage: "antenna.radiowaves.left.and.right",
                    tint: bridgeClient.bridgeStatus.color
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                MobileReadingStat(
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
                MobileReadingStat(
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
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Mac") {
                switch MacHealthPresentation.snapshot(for: store.health) {
                case .available(let health):
                    if let healthLoadError = store.healthLoadError {
                        Label(healthLoadError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    MobileReadingStat(
                        label: "App",
                        value: health.app,
                        systemImage: "app.badge",
                        tint: NativeAgentPalette.agentAccent
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    MobileReadingStat(
                        label: "Version",
                        value: health.version,
                        systemImage: "tag",
                        tint: NativeAgentPalette.agentAccent
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    LabeledContent("OK") {
                        Image(systemName: health.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(health.ok ? Color.secondary : Color.red)
                    }
                case .unavailable:
                    Label(MacHealthPresentation.unavailableTitle, systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text(store.healthLoadError ?? MacHealthPresentation.unavailableDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let organism = sync.organismLivingStatus {
                let organismState = OrganismStatusPresentation.snapshotState(for: organism)
                Section(sync.agentDisplayName) {
                    if organismState.displaysDetails {
                        let needsAttention = organism.needsAttention == true
                        MobileReadingStat(
                        label: "Posture",
                        value: organism.posture.capitalized,
                        systemImage: organism.needsUser
                            ? "person.crop.circle.badge.exclamationmark"
                            : (needsAttention ? "exclamationmark.triangle" : "waveform.path.ecg"),
                        tint: organism.needsUser ? .orange : (needsAttention ? .yellow : .green)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    MobileReadingStat(
                        label: "Behavior",
                        value: organism.behaviorLine,
                        systemImage: "slider.horizontal.3",
                        tint: NativeAgentPalette.agentAccent
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    if let bodyLine = organism.bodyLine, !bodyLine.isEmpty {
                        Text(bodyLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Body") {
                        Text(organism.enabled ? "on" : "off")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Signals") {
                        Text("\(organism.signalCount)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Needs review") {
                        Text("\(organism.counters.reflexesNeedReview)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Approved biases") {
                        Text(OrganismStatusPresentation.approvedBiasesText(organism.counters.approvedReflexBiases))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("iPhone") {
                        Text(organism.body.iPhoneReachable ? "reachable" : "stale")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Resources") {
                        Text(organism.body.resourcePressure)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Body updated") {
                        Text(organism.generatedAt, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                    if case .stale(let age) = organismState {
                        Label("STALE · \(OrganismStatusPresentation.staleAgeText(age)) old — waiting for a newer Mac snapshot", systemImage: "clock.badge.exclamationmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    } else {
                        switch organismState {
                        case .disabled:
                            Label("Organism body is disabled — no live body readout is available.", systemImage: "power")
                                .foregroundStyle(.secondary)
                        case .unavailable(let reason):
                            Label("Organism status is unavailable", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            Text(reason ?? "The Mac could not complete this status snapshot.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        case .invalidTimestamp(let futureBy):
                            Label("Organism status timestamp is invalid", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                            Text("The Mac timestamp is \(OrganismStatusPresentation.staleAgeText(futureBy)) ahead of this phone.")
                                .font(.callout)
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
                                MobileAdaptiveRow(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(candidate.trustClass)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(Int((candidate.confidence * 100).rounded()))%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if candidate.autoActivationAllowed {
                                        Label("Biasing", systemImage: "checkmark.seal.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(candidate.pattern)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                MobileAdaptiveRow(spacing: 12) {
                                    Button {
                                        decideReflex(candidate, approve: true)
                                    } label: {
                                        Label("Approve", systemImage: "checkmark")
                                    }
                                    .buttonStyle(.bordered)
                .tint(.secondary)
                                    .disabled(!OrganismStatusPresentation.canApprove(candidate) || decidingReflexID == candidate.id)

                                    Button(role: .destructive) {
                                        decideReflex(candidate, approve: false)
                                    } label: {
                                        Label("Retire", systemImage: "archivebox")
                                    }
                                    .buttonStyle(.bordered)
                .tint(.secondary)
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
                                .font(.callout)
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
                                    .font(.callout)
                                Text(proposal.rationale)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !proposal.evidenceIDs.isEmpty {
                                    Text("\(proposal.evidenceIDs.count) linked evidence item\(proposal.evidenceIDs.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        if proposalSlice.hiddenCount > 0 {
                            Text("\(proposalSlice.hiddenCount) more proposal\(proposalSlice.hiddenCount == 1 ? "" : "s") can be reviewed on the Mac.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section(sync.agentDisplayName) {
                    Label("ABSENT — living status is not reporting yet", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text("The phone has not received an agent status update yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .mobileReadingScreen()
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
                MobileReadingEmptyState(
                    title: "Runs are not available",
                    systemImage: "exclamationmark.triangle",
                    kind: .unavailable,
                    description: error
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            case .empty:
                MobileReadingEmptyState(
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
        .mobileReadingScreen()
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
        MobileAdaptiveRow(alignment: .top, spacing: 12) {
            Image(systemName: RunKindPresentation.icon(run.kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(NativeAgentMobileTheme.Colors.quietFill,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                MobileAdaptiveRow {
                    Text(RunKindPresentation.displayName(run.kind))
                        .font(.headline)
                    Spacer()
                    StatusBadge(status: run.status)
                }
                if let prompt = run.prompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                MobileAdaptiveRow(spacing: 6) {
                    Text(UserDisplayFormatters.humanizeISOTimestamp(run.createdAt))
                    if let duration = run.durationSeconds {
                        Text("·")
                        Text(UserDisplayFormatters.humanizeDuration(duration))
                    }
                    if let model = run.model, !model.isEmpty {
                        Text("·")
                        Text(model).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption)
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
                MobileAdaptiveRow(spacing: 12) {
                    Image(systemName: RunKindPresentation.icon(run.kind))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(NativeAgentMobileTheme.Colors.quietFill,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(RunKindPresentation.displayName(run.kind))
                            .font(.title2.weight(.semibold))
                        Text(UserDisplayFormatters.humanizeISOTimestamp(run.createdAt))
                            .font(.callout)
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
                        .fixedSize(horizontal: false, vertical: true)
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
                        .font(.headline)
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
                        .font(.headline)
                        .foregroundStyle(.red)
                }
            }
            if let output = run.output, !output.isEmpty {
                runTextSection("Output", systemImage: "text.alignleft", text: output)
            }
        }
        .mobileReadingScreen()
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
                .font(.headline)
        }
    }
}
