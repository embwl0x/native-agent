import SwiftUI
import CloudKit
import NativeAgentShared
// Blueprint: | `MemoryView.swift` | Memory page and proposal rows read the shared sync projection; composes mutation and local search owners |

// MARK: - MemoryView

struct MemoryView: View {
    @StateObject private var store = MemoryStore()
    private let sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var showsConnection = false
    @State private var hasNoCloudAccount = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var segment: MemorySegment
    /// Search filters only the memory snapshot already synced to this phone.
    @State private var searchQuery = ""
    /// Tab roots own navigation; pushed destinations use the caller’s stack.
    private let embedInNavigationStack: Bool

    enum MemorySegment: String, CaseIterable {
        case memories = "Memories"
        case proposals = "Proposals"
    }

    /// The Mac snapshot group behind each tab. They fail INDEPENDENTLY —
    /// `memories` and `memory_proposals` are separate fetches on the Mac — so a
    /// badge pinned to one group leaves the other tab looking fresh while the
    /// Mac already knows its rows are old.
    static func snapshotGroup(for segment: MemorySegment) -> String {
        switch segment {
        case .memories: return "memories"
        case .proposals: return "memory_proposals"
        }
    }

    init(initialSegment: MemorySegment = .memories, embedInNavigationStack: Bool = true) {
        var segment = initialSegment
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-memorySampleProposals") { segment = .proposals }
        #endif
        _segment = State(initialValue: segment)
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
        Group {
            switch segment {
            case .memories:
                MemoryListView(store: store, searchQuery: searchQuery, header: AnyView(memoryHeader))
            case .proposals:
                ProposalsListView(store: store, header: AnyView(memoryHeader))
            }
        }
        // At the tab root the bar has nothing to hold; pushed, it keeps Back.
        .alivePageChrome(title: "Memories", root: embedInNavigationStack)
        // The search floats over the list, above the tab bar, like the
        // composer. Outside the chrome, so the list's bottom fade runs under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Nothing to search until something has arrived.
            if segment == .memories && (!store.memories.isEmpty || MemorySamples.isOn || !searchQuery.isEmpty) {
                AliveSearchField(prompt: "Search memories", text: $searchQuery)
                    .padding(.horizontal, AliveMetrics.pageInset)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showsConnection) {
            PairingView(onSkip: { showsConnection = false }, onPaired: { showsConnection = false })
        }
        .refreshable { await store.refresh() }
        .onAppear { Task { await store.refresh() } }
        .task(id: scenePhase) {
            guard scenePhase == .active,
                  DeviceCloudKitPreflight.entitlementGrantsContainer(NativeAgentICloudBridgeConstants.containerID) else { return }
            hasNoCloudAccount = (try? await CKContainer(identifier: NativeAgentICloudBridgeConstants.containerID).accountStatus()) == .noAccount
        }
    }

    private var headerLine: String {
        let sample = MemorySamples.isOn
        switch segment {
        case .memories:
            return MemoryWords.memoriesLine(sample ? MemorySamples.memories.count : store.memories.count)
        case .proposals:
            let count = sample && store.memoryProposals.isEmpty ? MemorySamples.proposals.count : store.memoryProposals.count
            return MemoryWords.proposalsLine(count)
        }
    }

    private var memoryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            AlivePageHeader(title: "Memories", line: headerLine,
                            style: embedInNavigationStack ? .root : .pushed)
                .padding(.horizontal, 4)
            memorySyncStatus
            AliveSegmentedPicker(selection: $segment, options: MemorySegment.allCases) { $0.rawValue }
                .padding(.top, 6)
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
        // Reuse the freshness cadence and rules; connection and snapshot age
        // are independent facts, presented together with one recovery.
        TimelineView(MacSnapshotFreshnessSchedule(
            lastSyncedAt: sync.transportDeliveryAt(screenGroup: Self.snapshotGroup(for: segment)),
            fixed: sampleSyncState != nil, showsFreshAge: true)) { context in
            let sample = sampleSyncState
            let state = StatusConnectionPresentation.syncState(
                // This segment's own delivery clock, not the cache-read clock.
                lastSyncedAt: sample == "stale"
                    ? context.date.addingTimeInterval(-7200)
                    : sample != nil
                        ? nil
                        : sync.transportDeliveryAt(screenGroup: Self.snapshotGroup(for: segment)),
                now: context.date)
            let reason = MacSnapshotGroupStaleness.reason(in: sync.staleSnapshotGroups, group: Self.snapshotGroup(for: segment))
            let sharedError = MemoryErrorLinePresentation.visibleMessage(sync.syncError)
            // The Mac's status is said once, in the chat header and More ›
            // Connection. Here: unpaired, only the one way on; paired, only
            // this page's own age when it is stale or never arrived.
            let unpaired = sample == nil && !pairingStore.usesICloudTransport
            // A paired phone that lost its Apple Account: no snapshot can
            // arrive, so the age alone would not say why or how to fix it.
            let noAccount = sample == "noAccount" || (sample == nil && hasNoCloudAccount)
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
                    text: AliveConnection.noICloud + ". Sign in to iCloud in Settings and my memories will arrive here.",
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
                // The page note every page wears: what is true, and one way on.
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

/// Plain words for the page: counts spelled out, kinds named for people.
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
        let times = proposal.recurrenceCount <= 1 ? "once" : proposal.recurrenceCount == 2 ? "twice" : "\(AliveWords.spelled(proposal.recurrenceCount, capitalized: false)) times"
        let sessions = proposal.supportingSessionIds.count
        guard sessions > 1 else { return "noticed \(times)" }
        return "noticed \(times) across \(AliveWords.spelled(sessions, capitalized: false)) conversations"
    }
}

/// View-only fixtures for `-memorySample`; never inserted into the store or
/// sent to the Mac.
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
      {"id":"sample-1","layer":"semantic","text":"Keep mornings open for focused work and save errands for the afternoon.","importance":0.8,"confidence":1,"tags":["routine","focus"],"createdAt":"2026-09-07"},
      {"id":"sample-2","layer":"episodic","text":"A walk by the water was a good way to end a busy week.","importance":0.6,"confidence":1,"tags":["weekend","outdoors"],"createdAt":"2026-09-07"},
      {"id":"sample-3","layer":"semantic","text":"When planning a project, start with a short outline and one useful next step.","importance":0.7,"confidence":1,"tags":["planning"],"createdAt":"2026-09-07"}
    ]
    """)

    static let proposals: [MemoryProposalRecord] = decode("""
    [
      {"id":"sample-p1","text":"Prefers a short summary first, with the details after.","layer":"semantic","importance":0.85,"supporting_session_ids":["a","b"],"recurrence_count":3},
      {"id":"sample-p2","text":"Likes to finish the week with a walk outside.","layer":"episodic","importance":0.5,"supporting_session_ids":[],"recurrence_count":1}
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
            if proposals.isEmpty {
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
                        // Sample rows are pictures only; they never reach the Mac.
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

/// Something I would like to remember, and your two answers.
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
