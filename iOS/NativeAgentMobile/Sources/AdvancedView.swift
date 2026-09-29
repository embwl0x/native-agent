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
}

// MARK: - AdvancedView (hidden behind "More" tab)

struct AdvancedView: View {
    @Binding var deskTaskNavigationTarget: MobileDeskTaskNotificationIntent?

    init(deskTaskNavigationTarget: Binding<MobileDeskTaskNotificationIntent?> = .constant(nil)) {
        _deskTaskNavigationTarget = deskTaskNavigationTarget
    }
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @StateObject private var store = AdvancedStore()
    @State private var showPairingRecovery = false
    @State private var showDesignScreen = MobileDesignSamples.screen != nil
    #if DEBUG
    @StateObject private var designApprovals = ApprovalsStore()
    @StateObject private var designInbox = InboxStore()
    #endif

    var body: some View {
        NavigationStack {
            AlivePage(title: "More", line: "Rooms, settings and tools.", style: .root) {
                if PairingSkipPresentation.showsRecoveryAffordance(isPaired: pairingStore.isPaired) {
                    AliveSection("Connection", surface: .none) {
                        AliveCalmState(title: AliveConnection.unpaired,
                                       line: "I live on your Mac. Pair this iPhone and I can reach you here.",
                                       actionTitle: "Pair with Mac",
                                       actionHint: "Opens pairing so this iPhone can reconnect to the Mac.") {
                            showPairingRecovery = true
                        }
                    }
                }

                AliveSection("Rooms") {
                    link("Scheduler", "Things set to happen later") { MobileSchedulerView() }
                    AliveDivider()
                    link("Helpers", "Run and manage helpers") { MobileHelpersView() }
                    AliveDivider()
                    link("Agents", "Conversations with other agents") { MobileAgentsView() }
                    AliveDivider()
                    link("Desk tasks", "Work I'm doing for you") {
                        WorkshopView(embedInNavigationStack: false)
                    }
                    AliveDivider()
                    link("Skills & Tools", "What I know how to do") {
                        SkillsToolsView(embedInNavigationStack: false)
                    }
                    AliveDivider()
                    link("Personality", "How I think and sound") { PersonalityDetailHostView() }
                    AliveDivider()
                    link("Connectors", "The services I can reach") { ConnectorsHostView() }
                    AliveDivider()
                    link("Trust", "What I may do on my own") { TrustHostView() }
                }

                AliveSection("Setup") {
                    link("Telegram", "Telegram settings on your Mac") { TelegramView() }
                    AliveDivider()
                    link("Mac Integration", "Apps on your Mac I can use") { MacIntegrationView() }
                    AliveDivider()
                    link("Providers", "The models I think with") { ProviderSettingsView() }
                    AliveDivider()
                    link("Settings", "Appearance and the Mac link") { SettingsViewFull() }
                }

                // Opt-in deep surfaces and diagnostics: lower and quieter.
                AliveSection("Power user", footer: MoreAboutPresentation.text) {
                    ForEach(Array(MorePowerUserDestination.allCases.enumerated()), id: \.element.id) { index, destination in
                        if index > 0 { AliveDivider() }
                        quietLink(destination.title) { powerUserDestination(destination) }
                    }
                    AliveDivider()
                    quietLink("Status") { StatusDetailView(store: store) }
                    AliveDivider()
                    quietLink("Runs Log") { RunsLogView(store: store) }
                }
                .padding(.top, 12)
            }
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

    private func link<Destination: View>(_ title: String, _ detail: String,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            AliveRow(title, detail: detail) { AliveChevron() }
        }
        .aliveRowButtonStyle()
    }

    private func quietLink<Destination: View>(_ title: String,
                                              @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            AliveRow(title) { AliveChevron() }
        }
        .aliveRowButtonStyle()
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
        case "personality": PersonalityDetailView(store: Self.sampleSettingsStore())
        case "trust": TrustPolicyView(store: Self.sampleSettingsStore())
        case "connectors": ConnectorsView(store: Self.sampleSettingsStore())
        case "trust-empty": TrustPolicyView(store: SettingsStore())
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

    #if DEBUG
    /// Process-local screenshot data for the Personality, Trust and Connectors rooms.
    private static func sampleSettingsStore() -> SettingsStore {
        let store = SettingsStore()
        store.personality = PersonalityProfile(
            name: "Sample", personaKind: "Companion",
            essence: "A steady, curious presence that keeps the day simple and the next step clear.",
            voice: "Plain and warm. Short sentences, one idea at a time, no filler.",
            traits: PersonalityTraits(warmth: 0.8, directness: 0.7, humor: 0.45, proactivity: 0.6,
                                      rigor: 0.75, autonomy: 0.55, creativity: 0.65, brevity: 0.7))
        store.trustPolicy = TrustPolicy(
            permissionLevel: "Standard", autonomyDefault: "Ask first", requireBackups: true,
            outsideDefault: "Read only", developerMode: false,
            workshopPolicy: TrustWorkshopPolicy(enabled: true, showTimeline: true),
            trainingPolicy: TrustTrainingPolicy(autonomousTraining: false, dreamScheduler: true))
        store.connectors = [
            ConnectorRecord(id: "calendar", name: "Calendar", kind: "Calendar", enabled: true, healthStatus: "ok"),
            ConnectorRecord(id: "github", name: "GitHub", kind: "Code", enabled: true, healthStatus: "connected"),
            ConnectorRecord(id: "notes", name: "Notes", kind: "Notes", status: "idle", enabled: false),
        ]
        return store
    }
    #endif

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
            AlivePageHeader(title: "Status", line: "How this iPhone, the Mac and I are doing.",
                            style: .pushed)
                .padding(.horizontal, 4)
                .aliveListRow(top: 4, bottom: 6)
            Group {
            if !cloudReplies.unverifiedRecords.isEmpty {
                // 2026-09-08: a Mac record the phone could not verify is deferred, not
                // hidden; name it so a person can see what is stuck and why.
                Section {
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
                } header: { AliveEyebrow("Unverified Mac records") }
            }
            Section {
                MobileReadingStat(
                    label: "State",
                    value: AliveConnection.line(for: bridgeClient.bridgeStatus, paired: pairingStore.isPaired),
                    systemImage: "antenna.radiowaves.left.and.right",
                    tint: bridgeClient.bridgeStatus.color
                )

                MobileReadingStat(
                    label: "Pairing",
                    value: pairingStore.usesICloudTransport ? "iCloud" : "Not paired",
                    systemImage: "network",
                    tint: NativeAgentPalette.agentAccent
                )

                if let lastSeen = bridgeClient.lastSeenAt {
                    LabeledContent("Last seen") {
                        Text(lastSeen, style: .relative).foregroundStyle(.secondary)
                    }
                }
                // This screen renders the advanced group (runs, turn
                // summaries): its own delivery clock, not a cache read.
                let syncState = StatusConnectionPresentation.syncState(
                    lastSyncedAt: iCloudSyncEngine.shared.transportDeliveryAt(screenGroup: "runs")
                )
                MobileReadingStat(
                    label: "Last synced",
                    value: StatusConnectionPresentation.cardValue(for: syncState),
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: StatusConnectionPresentation.needsAttention(syncState)
                        ? .orange
                        : NativeAgentPalette.agentAccent
                )
                if let detail = StatusConnectionPresentation.detail(for: syncState) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: { AliveEyebrow("Connection") }
            Section {
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

                    MobileReadingStat(
                        label: "Version",
                        value: health.version,
                        systemImage: "tag",
                        tint: NativeAgentPalette.agentAccent
                    )

                    LabeledContent("OK") {
                        Image(systemName: health.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(health.ok ? Color.secondary : Color.red)
                    }
                case .unavailable:
                    Label(MacHealthPresentation.unavailableTitle, systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    // Unpaired, nothing is downloading: say what is true.
                    Text(pairingStore.usesICloudTransport
                         ? store.healthLoadError ?? MacHealthPresentation.unavailableDetail
                         : AliveConnection.unpaired + ".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: { AliveEyebrow("Mac") }
            if let organism = sync.organismLivingStatus {
                let organismState = OrganismStatusPresentation.snapshotState(for: organism)
                Section {
                    if organismState.displaysDetails {
                        let needsAttention = organism.needsAttention == true
                        MobileReadingStat(
                        label: "Posture",
                        value: AliveWords.humanized(organism.posture.lowercased()),
                        systemImage: organism.needsUser
                            ? "person.crop.circle.badge.exclamationmark"
                            : (needsAttention ? "exclamationmark.triangle" : "waveform.path.ecg"),
                        tint: organism.needsUser ? .orange : (needsAttention ? .yellow : .green)
                    )

                    MobileReadingStat(
                        label: "Behavior",
                        value: organism.behaviorLine,
                        systemImage: "slider.horizontal.3",
                        tint: NativeAgentPalette.agentAccent
                    )

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
                        Label("\(OrganismStatusPresentation.staleAgeText(age)) old. Waiting for a newer Mac snapshot.", systemImage: "clock.badge.exclamationmark")
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
                } header: { AliveEyebrow(sync.agentDisplayName) }
                let candidateSlice: OrganismStatusPresentation.ReflexCandidateSlice = organismState.displaysDetails
                    ? OrganismStatusPresentation.reflexCandidateSlice(
                        (organism.reflexCandidates ?? []).filter { !locallyFinalizedReflexIDs.contains($0.id) }
                    )
                    : .init(visible: [], hiddenCount: 0)
                if !candidateSlice.visible.isEmpty {
                    Section {
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
                                    .aliveSecondaryButton()
                                    .disabled(!OrganismStatusPresentation.canApprove(candidate) || decidingReflexID == candidate.id)

                                    Button(role: .destructive) {
                                        decideReflex(candidate, approve: false)
                                    } label: {
                                        Label("Retire", systemImage: "archivebox")
                                    }
                                    .aliveSecondaryButton()
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
                            Text(AliveWords.count(candidateSlice.hiddenCount, "more reflex candidate") + " need review on the Mac.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } header: { AliveEyebrow("Reflex review") }
                }
                let proposalSlice: OrganismStatusPresentation.DreamProposalSlice = organismState.displaysDetails
                    ? OrganismStatusPresentation.dreamProposalSlice(organism.standingViewProposals ?? [])
                    : .init(visible: [], hiddenCount: 0)
                if !proposalSlice.visible.isEmpty {
                    Section {
                        ForEach(proposalSlice.visible) { proposal in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(proposal.title)
                                    .font(.callout)
                                Text(proposal.rationale)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !proposal.evidenceIDs.isEmpty {
                                    Text(AliveWords.count(proposal.evidenceIDs.count, "linked evidence item"))
                                        .font(.caption)
                                        .foregroundStyle(AlivePalette.secondary)
                                }
                            }
                        }
                        if proposalSlice.hiddenCount > 0 {
                            Text(AliveWords.count(proposalSlice.hiddenCount, "more proposal") + " can be reviewed on the Mac.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } header: { AliveEyebrow("Dream proposals") }
                }
            } else {
                Section {
                    Label("Not reporting yet", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text("The phone has not received an agent status update yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: { AliveEyebrow(sync.agentDisplayName) }
            }
            }
            .listRowBackground(AlivePalette.fill)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .alivePageChrome(title: "Status", root: false)
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
            AlivePageHeader(title: "Runs Log", line: "What I've run on the Mac lately.", style: .pushed)
                .padding(.horizontal, 4)
                .aliveListRow(top: 4, bottom: 6)
            switch RunsLogPresentation.state(runs: store.runs, error: store.runsLoadError) {
            case .unavailable(let error):
                AliveCalmState(title: "Runs are not available", line: error)
                    .aliveListRow()
            case .empty:
                AliveCalmState(title: "No runs yet", line: "The latest Mac run snapshot contains no runs.")
                    .aliveListRow()
            case .content:
                ForEach(store.runs) { run in
                    NavigationLink {
                        RunDetailView(run: run)
                    } label: {
                        RunRowView(run: run)
                    }
                }
                .listRowBackground(AlivePalette.fill)
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .alivePageChrome(title: "Runs Log", root: false)
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
                .foregroundStyle(AlivePalette.secondary)
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
            AlivePageHeader(title: "Run detail", style: .pushed)
                .padding(.horizontal, 4)
                .aliveListRow(top: 4, bottom: 6)
            Group {
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
                Section {
                    ForEach(modelFacts) { fact in
                        LabeledContent(fact.label, value: fact.value)
                    }
                } header: { AliveEyebrow("Model") }
            }

            if let prompt = RunDetailPromptPresentation.copyablePrompt(run.prompt) {
                runTextSection("Prompt", systemImage: "text.bubble", text: prompt)
            } else {
                Section {
                    Text(RunDetailPromptPresentation.unavailableDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: { AliveEyebrow("Prompt") }
            }
            if let error = run.error, !error.isEmpty {
                Section {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } header: { AliveEyebrow("Error") }
            }
            if let output = run.output, !output.isEmpty {
                runTextSection("Output", systemImage: "text.alignleft", text: output)
            }
            }
            .listRowBackground(AlivePalette.fill)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .alivePageChrome(title: "Run Detail", root: false)
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
        } header: { AliveEyebrow(title) }
    }
}
