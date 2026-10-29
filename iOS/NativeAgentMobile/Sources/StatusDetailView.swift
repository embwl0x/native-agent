import SwiftUI
import NativeAgentShared
// Blueprint: | `StatusDetailView.swift` | Phone, Mac and organism status readback |

// MARK: - Status detail

struct StatusDetailView: View {
    @ObservedObject var store: AdvancedStore
    private let sync = iCloudSyncEngine.shared
    @ObservedObject private var cloudReplies = iCloudBridge.shared
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore

    var body: some View {
        List {
            AlivePageHeader(title: "Status", line: "How this iPhone, the Mac and I are doing.",
                            style: .pushed)
                .padding(.horizontal, 4)
                .aliveListRow(top: 4, bottom: 6)
            Group {
            if !cloudReplies.unverifiedRecords.isEmpty {
                // Show unverified Mac records with the reason they are deferred.
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
                    value: AliveConnection.line(bridgeClient.connection),
                    systemImage: "antenna.radiowaves.left.and.right"
                )

                MobileReadingStat(
                    label: "Pairing",
                    value: pairingStore.usesICloudTransport ? "iCloud" : "Not paired",
                    systemImage: "network"
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
                    systemImage: "arrow.triangle.2.circlepath"
                )
                if let detail = StatusConnectionPresentation.detail(for: syncState) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: { AliveEyebrow("Connection") }
            Section {
                if let health = sync.health {
                    if let healthLoadError = store.healthLoadError {
                        Label(healthLoadError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    MobileReadingStat(
                        label: "App",
                        value: health.app,
                        systemImage: "app.badge"
                    )

                    MobileReadingStat(
                        label: "Version",
                        value: health.version,
                        systemImage: "tag"
                    )

                    LabeledContent("OK") {
                        Image(systemName: health.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(health.ok ? Color.secondary : Color.red)
                    }
                } else {
                    Label("Mac health is unavailable", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    // Unpaired, nothing is downloading: say what is true.
                    Text(pairingStore.usesICloudTransport
                         ? store.healthLoadError ?? "Waiting for a health snapshot from the Mac."
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
                            : (needsAttention ? "exclamationmark.triangle" : "waveform.path.ecg")
                    )

                    MobileReadingStat(
                        label: "Behavior",
                        value: organism.behaviorLine,
                        systemImage: "slider.horizontal.3"
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
                        Label("\(StatusConnectionPresentation.ageText(age)) old. Waiting for a newer Mac snapshot.", systemImage: "clock.badge.exclamationmark")
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
                            Text("The Mac timestamp is \(StatusConnectionPresentation.ageText(futureBy)) ahead of this phone.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        case .available, .stale, .absent:
                            EmptyView()
                        }
                    }
                } header: { AliveEyebrow(sync.agentDisplayName) }
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
}
