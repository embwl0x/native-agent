import SwiftUI
import NativeAgentShared
// Blueprint: | `MemoryView.swift` | Memories to keep: the memory proposals page and its rows read the shared sync projection; the memories themselves are the memories face |

// MARK: - MemoryView

struct MemoryView: View {
    @StateObject private var store = MemoryStore()
    private let sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var showsConnection = false
    @ObservedObject private var bridge = iCloudBridge.shared
    /// Pushed destinations reuse their caller's stack; only tab roots own navigation.
    private let embedInNavigationStack: Bool

    /// Proposals age from their own delivery.
    static let snapshotGroup = "memory_proposals"

    init(embedInNavigationStack: Bool = true) {
        self.embedInNavigationStack = embedInNavigationStack
    }

    var body: some View {
        Group {
            if embedInNavigationStack {
                NavigationStack { memoryContent }
            } else {
                memoryContent
            }
        }
    }

    @ViewBuilder
    private var memoryContent: some View {
        ProposalsListView(store: store, header: AnyView(memoryHeader))
        // Keep Back when pushed; tab roots need no navigation bar.
        .alivePageChrome(title: "Memories to keep", root: embedInNavigationStack)
        .sheet(isPresented: $showsConnection) {
            PairingView(onSkip: { showsConnection = false }, onPaired: { showsConnection = false })
        }
        .refreshable { await store.refresh() }
        .onAppear { Task { await store.refresh() } }
    }

    private var headerLine: String {
        let sample = MemorySamples.isOn
        guard sample || sync.memoryProposalsSnapshotLoaded else { return "Memory proposals have not arrived from the Mac yet." }
        let count = sample && store.memoryProposals.isEmpty ? MemorySamples.proposals.count : store.memoryProposals.count
        return MemoryWords.proposalsLine(count)
    }

    private var memoryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            AlivePageHeader(title: "Memories to keep", line: headerLine,
                            style: embedInNavigationStack ? .root : .pushed)
                .padding(.horizontal, 4)
            memorySyncStatus
            if let error = MemoryErrorLinePresentation.visibleMessage(store.error) {
                MemoryErrorLine(message: error) {
                    store.dismissError()
                }
            }
        }
        .padding(.top, embedInNavigationStack ? AliveMetrics.rootTop : 4)
    }

    private var sampleSyncState: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-memorySample"), let i = args.firstIndex(of: "-memorySampleStatus"), args.indices.contains(i + 1) {
            return args[i + 1]
        }
        #endif
        return nil
    }

    private var memorySyncStatus: some View {
        // Connection and snapshot age are independent facts; share freshness cadence and offer one recovery.
        TimelineView(MacSnapshotFreshnessSchedule(
            lastSyncedAt: sync.transportDeliveryAt(screenGroup: Self.snapshotGroup),
            fixed: sampleSyncState != nil, showsFreshAge: true)) { context in
            let sample = sampleSyncState
            let state = StatusConnectionPresentation.syncState(
                // Age proposals from their delivery, never from a cache read.
                lastSyncedAt: sample == "stale"
                    ? context.date.addingTimeInterval(-7200)
                    : sample != nil
                        ? nil
                        : sync.transportDeliveryAt(screenGroup: Self.snapshotGroup),
                now: context.date)
            let reason = MacSnapshotGroupStaleness.reason(in: sync.staleSnapshotGroups, group: Self.snapshotGroup)
            let sharedError = MemoryErrorLinePresentation.visibleMessage(sync.syncError)
            // Keep Mac status in Chat/Connection; this page explains only pairing or its own stale/missing delivery.
            let unpaired = sample == nil && !pairingStore.usesICloudTransport
            // Apple Account loss blocks snapshots; age alone cannot explain the cause or remedy.
            let accountFailure = sample == nil ? bridge.accountFailure : nil
            let noAccount = sample == "noAccount" || accountFailure != nil
            let attention = sharedError != nil || reason != nil || StatusConnectionPresentation.needsAttention(state)
            if unpaired {
                AliveNoteAction(title: "Pair with Mac", hint: "Connects this iPhone to your Mac") {
                    showsConnection = true
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if noAccount {
                AliveStatusNote(
                    systemImage: "icloud.slash",
                    text: accountFailure.map { DeviceSyncAccountFailure.phoneMessage + ": " + $0.detail }
                        ?? (AliveConnection.noICloud + ". Sign in to iCloud in Settings and my memories will arrive here."),
                    actionTitle: "Open Settings",
                    actionHint: "Sign in to Apple Account in Settings, then return to refresh memories."
                ) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else {
                        SystemToastCenter.shared.push(error: "The iPhone Settings address is unavailable.")
                        return
                    }
                    UIApplication.shared.open(url)
                }
            } else if attention {
                let title = sharedError != nil ? "My memories couldn\u{2019}t update"
                    : reason != nil ? "My memories may be out of date"
                    : MacSnapshotPageFreshness.line(for: state)
                let detail: String? = sharedError != nil ? nil
                    : reason.map { "Saved memories may be out of date. \($0)" }
                AliveStatusNote(
                    systemImage: "arrow.clockwise.icloud",
                    text: [title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". "),
                    actionTitle: "Refresh memories"
                ) {
                    Task { await store.refresh() }
                }
            } else {
                AliveFootnote(MacSnapshotPageFreshness.line(for: state))
            }
        }
        .macSyncErrorBanner()
    }
}

enum MemoryWords {
    static func memoriesLine(_ n: Int) -> String {
        switch n {
        case 0: return "What I keep from our conversations."
        case 1: return "I remember one thing."
        default: return "I remember \(AliveWords.spelled(n, capitalized: false)) things."
        }
    }

    static func proposalsLine(_ n: Int) -> String {
        switch n {
        case 0: return "What I\u{2019}d like to remember, for you to decide."
        case 1: return "One thing I\u{2019}d like to remember."
        default:
            return AliveWords.spelled(n) + " things I\u{2019}d like to remember."
        }
    }

    static func kind(_ layer: String?) -> String? {
        guard let raw = layer?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "semantic": return "Fact"
        case "episodic": return "Moment"
        case "procedural": return "Habit"
        case "working": return "For now"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    static func meta(kind: String?, pinned: Bool, importance: Double?, extra: [String]) -> String {
        var parts: [String] = []
        if let kind { parts.append(kind) }
        if pinned { parts.append("pinned") }
        if let importance, importance >= 0.8 { parts.append("important") }
        return (parts + extra).joined(separator: " \u{00B7} ")
    }

    static func evidence(_ proposal: MemoryProposalRecord) -> String {
        guard proposal.evidenceError == nil, let count = proposal.recurrenceCount, count > 0 else {
            return proposal.evidenceSummary
        }
        let times = count == 1 ? "once" : count == 2 ? "twice" : "\(AliveWords.spelled(count, capitalized: false)) times"
        let sessions = proposal.supportingSessionIds.count
        guard sessions > 1 else { return "noticed \(times)" }
        return "noticed \(times) across \(AliveWords.spelled(sessions, capitalized: false)) conversations"
    }
}

/// Memory screenshot fixtures stay view-local; never insert them into the store or send them.
enum MemorySamples {
    static var isOn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-memorySample")
        #else
        false
        #endif
    }

    static let memories: [MemoryRecord] = decode("""
    [
      {"id":"sample-1","layer":"semantic","text":"Keep mornings open for focused work and save errands for the \
    afternoon.","importance":0.8,"confidence":1,"tags":["routine","focus"],"createdAt":"2026-09-07"},
      {"id":"sample-2","layer":"episodic","text":"A walk by the water was a good way to end a busy \
    week.","importance":0.6,"confidence":1,"tags":["weekend","outdoors"],"createdAt":"2026-09-07"},
      {"id":"sample-3","layer":"semantic","text":"When planning a project, start with a short outline and one useful next \
    step.","importance":0.7,"confidence":1,"tags":["planning"],"createdAt":"2026-09-07"}
    ]
    """)

    static let proposals: [MemoryProposalRecord] = decode("""
    [
      {"proposal_id":"sample-p1","fact_text":"Prefers a short summary first, with the details \
    after.","status":"pending","createdAt":"2026-09-07","supporting_session_ids":["a","b"],"recurrence_count":3},
      {"proposal_id":"sample-p2","fact_text":"Likes to finish the week with a walk \
    outside.","status":"pending","createdAt":"2026-09-07","supporting_session_ids":[],"recurrence_count":1}
    ]
    """)

    private static func decode<T: Decodable>(_ json: String) -> [T] {
        (try? JSONDecoder().decode([T].self, from: Data(json.utf8))) ?? []
    }
}

// MARK: - Store

enum MemoryErrorLinePresentation {
    static func visibleMessage(_ error: String?) -> String? {
        guard let error else { return nil }
        let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}

private struct MemoryErrorLine: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(AppFont.label)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    .frame(width: 44, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss memory warning")
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Memory proposal list

struct ProposalsListView: View {
    @ObservedObject var store: MemoryStore
    var header: AnyView = AnyView(EmptyView())

    private var isSample: Bool { MemorySamples.isOn && store.memoryProposals.isEmpty }

    private var proposals: [MemoryProposalRecord] {
        isSample ? MemorySamples.proposals : store.memoryProposals
    }

    var body: some View {
        List {
            header.aliveListRow(top: 0, bottom: 10)
            if proposals.isEmpty && !iCloudSyncEngine.shared.memoryProposalsSnapshotLoaded && !isSample {
                AliveCalmState(title: "Proposals unavailable",
                    line: "The Mac proposal snapshot has not arrived. Keep NativeAgent open on the paired Mac and refresh after reconnecting.")
                    .aliveListRow()
            } else if proposals.isEmpty {
                AliveCalmState(
                    title: "Nothing to decide.",
                    line: "When something seems worth keeping, I\u{2019}ll ask you here first."
                )
                .aliveListRow()
            } else {
                ForEach(proposals) { proposal in
                    MemoryProposalRow(
                        proposal: proposal,
                        isDeciding: store.decidingMemoryProposalIDs.contains(proposal.id),
                        // Sample rows are presentation only and must not reach the Mac.
                        onApprove: { if !isSample { store.approveMemoryProposal(proposal) } },
                        onDeny: { if !isSample { store.rejectMemoryProposal(proposal) } }
                    )
                    .aliveListRow(top: 5, bottom: 5)
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .scrollContentBackground(.hidden)
    }
}

struct MemoryProposalRow: View {
    let proposal: MemoryProposalRecord
    let isDeciding: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(proposal.displayText ?? proposal.text)
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(AlivePalette.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MemoryWords.meta(kind: MemoryWords.kind(proposal.layer),
                                      pinned: false,
                                      importance: proposal.importance,
                                      extra: [MemoryWords.evidence(proposal)]))
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            MobileAdaptiveRow(spacing: 10) {
                Button(action: onDeny) {
                    Text("Discard").frame(maxWidth: .infinity)
                }
                .aliveSecondaryButton()
                .accessibilityLabel("Discard this memory")

                Button(action: onApprove) {
                    Group {
                        if isDeciding {
                            ProgressView().tint(.white)
                        } else {
                            Text("Keep")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .alivePrimaryButton()
                .accessibilityLabel("Keep this memory")
            }
            .font(.body.weight(.semibold))
            .controlSize(.large)
            .disabled(isDeciding)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aliveCard()
    }
}
