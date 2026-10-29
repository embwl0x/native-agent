import SwiftUI
import NativeAgentShared
// Blueprint: | `DeskView.swift` | Shared Desk board rows and reading copies; selected handles resolve current fields or an unavailable state |

struct MobileLoadedRecordsDisclosure: View {
    let title: String
    let remaining: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(title) (\(remaining) remaining)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AlivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .aliveRow()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Desk rows arrive clipped: the Mac bounds each summary and note, and publishes
/// only the most recent items. The phone must not present a clipped projection as
/// the whole record, so a cut string carries this line and the history section
/// says where its boundary is.
enum MobileDeskBoundaryCopy {
    static func clippedNotice(_ text: String?) -> String? {
        guard let text, MobileDeskProjectionBounds.isClipped(text) else { return nil }
        return "Cut off here — the rest of this text stays on the Mac."
    }

    /// Mac omission metadata outranks the row bound; nil means no reported cut.
    static func historyBoundary(
        deliveredRows: Int,
        report: MobileDeskProjectionReport? = nil
    ) -> String? {
        if let report {
            guard report.truncated else { return nil }
            return "The Mac published \(report.includedRows) of \(report.totalRows) items. "
                + "\(report.omittedCount) stayed on the Mac."
        }
        guard deliveredRows >= MobileDeskProjectionBounds.maximumRows else { return nil }
        return "The Mac publishes the \(MobileDeskProjectionBounds.maximumRows) most recent "
            + "items. Anything older stays on the Mac."
    }
}

enum MobileDeskEmptyStatePresentation: Equatable {
    case loading
    case unavailable(String)
    case empty

    static func state(
        hasAttemptedLoad: Bool,
        isRefreshing: Bool,
        loadError: String?
    ) -> MobileDeskEmptyStatePresentation {
        if !hasAttemptedLoad || isRefreshing { return .loading }
        if let loadError = loadError?.trimmingCharacters(in: .whitespacesAndNewlines), !loadError.isEmpty {
            return .unavailable(loadError)
        }
        return .empty
    }
}

/// iPhone projection of the Mac-owned, event-sourced Desk. All writes travel
/// through the existing signed action channel; iOS never owns a second Desk.
///
/// Alive glass, round 2: the Mac Desk page's structure on a phone. A serif
/// door and one sentence of what I'm working on; what waits on you in one
/// card lit with the haze; the work itself as one card each with a plain
/// status word; what finished in one quiet card. Empty, unpaired and syncing
/// each get a sentence and one way forward, never an error glyph.
struct MobileDeskView: View {
    @Binding var notifiedHandle: String?

    init(notifiedHandle: Binding<String?> = .constant(nil)) { _notifiedHandle = notifiedHandle }

    @EnvironmentObject private var pairingStore: PairingStore
    private let sync = iCloudSyncEngine.shared
    @State private var selectedItemHandle: String?
    @State private var showingNewItem = false
    @State private var showingTasks = false
    @State private var showingPairing = false
    @State private var errorMessage: String?
    @State private var isRefreshingDesk = false
    @State private var hasAttemptedDeskLoad = false
    @State private var deskLoadError: String?
    @State private var historyLimit = 40

    private static let syncingLine = "The board is still coming over from your Mac. It usually takes a moment."

    private var rows: [MobileDeskItem] {
        MobileDeskSample.rows(MobileDesignSamples.rows(sync.deskItems))
    }

    private var active: [MobileDeskItem] {
        rows.filter { MobileDeskSectionPresentation.section(for: $0) == .active }
    }

    private var history: [MobileDeskItem] {
        rows.filter { MobileDeskSectionPresentation.section(for: $0) == .history }
    }

    /// A sample run is judged as a paired phone.
    private var isPaired: Bool { MobileDeskSample.mode != nil || pairingStore.isPaired }

    private var movementDeadlines: [Date] {
        [Date()] + rows.flatMap { item in
            [item.executionEvidence?.lastMovementAt, item.status == "now" ? item.updatedAt : nil]
                .compactMap { DeskActivityState.movementDate($0)?.addingTimeInterval(DeskActivityState.movementWindow) }
        }.filter { $0 > Date() }.sorted()
    }

    var body: some View {
        TimelineView(.explicit(movementDeadlines)) { _ in
        // The line describes the page; the Mac's status lives in the chat
        // header. Desk's own delivery clock drives the freshness note: a
        // Memory read is not a Desk delivery.
        AlivePage(title: "Desk", line: headerLine, style: .root,
                  freshnessGroup: isPaired ? "desk" : nil) {
            Button { showingNewItem = true } label: { AliveTitleControlLabel(systemImage: "plus") }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Desk item")
        } content: {
            MobileWorkOverviewView()
            if rows.isEmpty {
                emptyBoard
            } else {
                DisclosureGroup("Desk items and history") { board }
            }
        }
        .defaultScrollAnchor(MobileDeskSample.mode == "end" ? .bottom : nil)
        .macSyncErrorBanner()
        .navigationDestination(isPresented: $showingTasks) {
            WorkshopView()
        }
        .refreshable { await refreshDesk() }
        .task {
            openSampleRoute()
            await refreshDesk()
            openNotifiedItem()
        }
        .onChange(of: notifiedHandle) { _, handle in
            guard handle != nil else { return }
            Task {
                await refreshDesk()
                openNotifiedItem()
            }
        }
        .onChange(of: sync.deskItems) { _, items in
            guard !items.isEmpty else { return }
            hasAttemptedDeskLoad = true
            deskLoadError = nil
            openNotifiedItem()
        }
        .sheet(isPresented: Binding(get: { selectedItemHandle != nil }, set: { if !$0 { selectedItemHandle = nil } })) {
            if let item = rows.first(where: { $0.handle == selectedItemHandle }) {
                MobileDeskItemDetail(item: item, errorMessage: $errorMessage)
            } else {
                AliveCalmState(title: "Desk item unavailable", line: "This item is no longer on the published Desk.")
            }
        }
        .sheet(isPresented: $showingNewItem) {
            NewMobileDeskItemSheet(errorMessage: $errorMessage)
        }
        .sheet(isPresented: $showingPairing) {
            PairingView(onSkip: { showingPairing = false }, onPaired: { showingPairing = false })
                .environmentObject(pairingStore)
        }
        .alert("Desk", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        }
    }

    private func refreshDesk() async {
        guard !isRefreshingDesk else { return }
        isRefreshingDesk = true
        defer { isRefreshingDesk = false }
        // Any note still waiting to reach the Mac is re-offered here, under the
        // identity it was already signed with — never as a new note.
        MobileDeskNoteOutbox.shared.deliverPending()
        let loaded = await sync.refreshDeskSnapshot()
        hasAttemptedDeskLoad = true
        deskLoadError = loaded ? nil : Self.syncingLine
    }

    // MARK: Header

    /// "Working on four things. Two need you." Said only once there is a board.
    private var headerLine: String? {
        sync.workOverview?.headline
    }

    // MARK: The board

    @ViewBuilder
    private var board: some View {
        if !active.isEmpty {
            AliveSection("On the board", surface: .none) {
                ForEach(active) { item in workCard(item) }
            }
        }

        tasksCard

        if !history.isEmpty {
            AliveSection("Finished") {
                ForEach(Array(history.prefix(historyLimit).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { AliveDivider() }
                    historyRow(item)
                }
                if history.count > historyLimit {
                    AliveDivider()
                    MobileLoadedRecordsDisclosure(title: "Show more history", remaining: history.count - historyLimit) {
                        historyLimit += 40
                    }
                }
            }
        }

        // Outside History on purpose: the Mac drops rows from every
        // section, so a Desk whose History happens to be empty must still
        // say that records were left behind.
        if let boundary = MobileDeskBoundaryCopy.historyBoundary(
            deliveredRows: rows.count,
            report: sync.deskBounds
        ) {
            AliveFootnote(boundary)
        }
    }

    private func workCard(_ item: MobileDeskItem) -> some View {
        Button { selectedItemHandle = item.handle } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    DeskStatusMark(status: item.status,
                        movementAt: item.executionEvidence?.status == "running" ? item.executionEvidence?.lastMovementAt : nil)
                    Text(item.activity(at: Date()).label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AlivePalette.text)
                    Spacer(minLength: 8)
                    if item.pinned {
                        Text("Pinned")
                            .font(.footnote)
                            .foregroundStyle(AlivePalette.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(AlivePalette.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = Self.workLine(item) {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(AlivePalette.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                Text(Self.meta(item))
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                    .lineLimit(1)
            }
            .aliveRow()
            .aliveCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func workLine(_ item: MobileDeskItem) -> String? {
        if item.status == "blocked", let reason = item.blockedReason, !reason.isEmpty { return reason }
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty { return summary }
        return nil
    }

    /// "Studio grant · 20 min. ago"
    private static func meta(_ item: MobileDeskItem) -> String {
        [item.project, AliveWords.relative(item.updatedAt)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func historyRow(_ item: MobileDeskItem) -> some View {
        Button { selectedItemHandle = item.handle } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(AlivePalette.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text([DeskStatusWords.word(for: item.status), item.project, AliveWords.relative(item.closedAt)]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                AliveChevron()
            }
            .aliveRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The way into directed work. Same route the More hub opens.
    private var tasksCard: some View {
        AliveCard {
            Button { showingTasks = true } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Desk tasks")
                            .font(.headline)
                            .foregroundStyle(AlivePalette.text)
                        Text("Work you've handed me.")
                            .font(.subheadline)
                            .foregroundStyle(AlivePalette.secondary)
                    }
                    Spacer(minLength: 8)
                    AliveChevron()
                }
                .aliveRow()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens directed tasks and task history")
        }
    }

    // MARK: Empty, unpaired, syncing

    private var emptyPresentation: MobileDeskEmptyStatePresentation {
        switch MobileDeskSample.mode {
        case "empty": return .empty
        case "loading": return .loading
        case "syncing": return .unavailable(Self.syncingLine)
        default:
            return MobileDeskEmptyStatePresentation.state(
                hasAttemptedLoad: hasAttemptedDeskLoad,
                isRefreshing: isRefreshingDesk,
                loadError: deskLoadError
            )
        }
    }

    @ViewBuilder
    private var emptyBoard: some View {
        if !isPaired {
            AliveCalmState(
                title: "The desk lives on your Mac.",
                line: "Pair this iPhone and the board comes with it: what I'm working on, and anything waiting on you.",
                actionTitle: "Pair with Mac"
            ) { showingPairing = true }
        } else {
            switch emptyPresentation {
            case .loading:
                AliveCalmState(title: "Checking the desk…", line: "Reading the board from your Mac.", showsProgress: true)
            case .unavailable(let message):
                AliveCalmState(title: "Still on its way.", line: message, actionTitle: "Try again") {
                    Task { await refreshDesk() }
                }
            case .empty:
                AliveCalmState(
                    title: "A clear desk.",
                    line: "Nothing on the board right now. I'll keep watching, or you can add something from here.",
                    actionTitle: "Add something"
                ) { showingNewItem = true }
            }
            tasksCard
        }
    }

    /// `-deskSample detail|new|tasks|taskdetail|tasknew` opens that screen over the sample board.
    private func openSampleRoute() {
        switch MobileDeskSample.mode {
        case "detail": selectedItemHandle = rows.first?.handle
        case "tasks", "taskdetail", "tasknew": showingTasks = true
        case "new": showingNewItem = true
        default: break
        }
    }

    private func openNotifiedItem() {
        guard let handle = notifiedHandle else { return }
        if let item = sync.deskItems.first(where: { $0.handle == handle }) {
            selectedItemHandle = item.handle
            notifiedHandle = nil
        }
    }
}

/// The Mac stamps `closedAt` for every terminal Desk transition and includes
/// that stamp in the mobile snapshot. It is therefore the cross-version
/// terminal proof; matching raw status names here would leave a newly added
/// terminal Mac status in Active until the iOS app shipped again.
enum MobileDeskSectionPresentation {
    enum Section: Equatable {
        case active
        case history
    }

    static func section(for item: MobileDeskItem) -> Section {
        section(closedAt: item.closedAt)
    }

    /// What waits on him is the overview's Needs you above the board.
    static func section(closedAt: String?) -> Section {
        if let closedAt, !closedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .history
        }
        return .active
    }
}

// MARK: - Sample board (DEBUG)

/// `-deskSample [board|end|detail|new|tasks|taskdetail|tasknew|empty|loading|syncing]`
/// fills the Desk
/// and Desk tasks with a believable board so the design can be judged without
/// a paired Mac. Only when the live board is empty; nothing in Release.
enum MobileDeskSample {
    static var mode: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-deskSample") else { return nil }
        let next = args.indices.contains(index + 1) ? args[index + 1] : ""
        return next.isEmpty || next.hasPrefix("-") || next == "YES" ? "board" : next
        #else
        return nil
        #endif
    }

    static func rows(_ live: [MobileDeskItem]) -> [MobileDeskItem] {
        #if DEBUG
        guard live.isEmpty, let mode, !["empty", "loading", "syncing"].contains(mode) else { return live }
        return items
        #else
        return live
        #endif
    }

    static var tasks: [WorkshopTaskRecord]? {
        #if DEBUG
        guard let mode, !["empty", "loading", "syncing"].contains(mode) else { return nil }
        return taskItems
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static func ago(_ minutes: Double) -> String {
        Date().addingTimeInterval(-minutes * 60).formatted(.iso8601)
    }

    private static func item(
        _ alias: String, _ status: String, _ project: String, _ title: String, _ summary: String?,
        updated: Double, closed: Double? = nil, pinned: Bool = false, blocked: String? = nil,
        waitingOn: String? = nil, owner: Bool = false, kind: String = "plan", notes: [MobileDeskNote] = []
    ) -> MobileDeskItem {
        MobileDeskItem(
            handle: "sample-\(alias)", alias: alias, parent: nil, kind: kind, status: status,
            project: project, title: title, summary: summary, openedAt: ago(updated + 2_000),
            updatedAt: ago(updated), closedAt: closed.map(ago), pinned: pinned, blockedReason: blocked,
            waitingOn: waitingOn, blockedOn: [], deferUntil: nil, origin: "agent",
            requiresOwnerInput: owner, recentNotes: notes
        )
    }

    private static var items: [MobileDeskItem] {
        [
            item("D-31", "flag", "Mia's birthday", "Choose the restaurant for Saturday",
                 "Both hold a table for eight at 7:30. Nopa has the private room; Flour + Water is closer.",
                 updated: 35, waitingOn: "Your pick between Nopa and Flour + Water", owner: true,
                 notes: [MobileDeskNote(timestamp: ago(35), text: "Called both. Nopa needs a deposit by Thursday.")]),
            item("D-29", "blocked", "Home", "Book the plumber for the kitchen sink",
                 "The quote came back at $480, parts included.",
                 updated: 180, blocked: "I need your yes on the $480 quote before I book Tuesday.", owner: true),
            item("D-27", "now", "Studio grant", "Draft the grant proposal narrative",
                 "Section two is written. Tightening the budget story next, then the impact paragraph.",
                 updated: 12, pinned: true, kind: "project"),
            item("D-24", "next", "Home office", "Compare three standing desks",
                 "Down to Uplift, Fully and Branch. Reading two years of long-term reviews.",
                 updated: 95),
            item("D-22", "watch", "Travel", "Watch the passport renewal",
                 "Submitted September 12. I check the status page each morning.",
                 updated: 600, kind: "watch"),
            item("D-19", "todo", "Travel", "Plan the Lisbon week",
                 "Flights are held until Friday. Hotels next.",
                 updated: 1_500),
            item("D-17", "done", "Home", "Book the car service", nil, updated: 300, closed: 300),
            item("D-15", "done", "Money", "Send the tax documents to Dana", nil, updated: 1_600, closed: 1_600),
            item("D-12", "canceled", "Home", "Price an e-bike trade-in", nil, updated: 4_000, closed: 4_000),
        ]
    }

    private static var taskItems: [WorkshopTaskRecord] {
        [
            WorkshopTaskRecord(id: "sample-t1", title: "Email the three venues for quotes",
                               objective: "Ask Nopa, Flour + Water and Zuni for a Saturday table for eight.",
                               status: "awaiting_approval", phase: "Approval",
                               summary: "Drafts are ready. Sending needs your yes.",
                               createdAt: ago(40), updatedAt: ago(6), currentStepId: "send"),
            WorkshopTaskRecord(id: "sample-t2", title: "Build the Lisbon reading list",
                               objective: "Find the best neighbourhood guides and a short history to read on the flight.",
                               status: "running", phase: "Research",
                               summary: "Four sources in; comparing the last two.",
                               createdAt: ago(90), updatedAt: ago(3)),
            WorkshopTaskRecord(id: "sample-t3", title: "Tidy the studio budget sheet",
                               objective: "Merge the two expense tabs and flag anything over $200.",
                               status: "queued", phase: "Queued",
                               createdAt: ago(20)),
            WorkshopTaskRecord(id: "sample-t4", title: "Summarise the lease renewal",
                               objective: "Pull out what changed from last year's lease.",
                               status: "completed", phase: "Done",
                               summary: "Rent up 3%, pet clause removed, notice period now 60 days.",
                               createdAt: ago(3_000), completedAt: ago(2_800)),
            WorkshopTaskRecord(id: "sample-t5", title: "Find a Tuesday piano teacher",
                               objective: "Three options within twenty minutes, with prices.",
                               status: "failed", phase: "Research",
                               summary: "Only one teacher had Tuesday openings.",
                               createdAt: ago(6_000), completedAt: ago(5_900)),
        ]
    }
    #endif
}
