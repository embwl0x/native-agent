import SwiftUI
import NativeAgentShared

struct MobileDeskTasksLabel: View {
    var body: some View { Label("Desk tasks", systemImage: "checklist") }
}

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

    /// nil while the delivered rows are inside the published bound.
    ///
    /// 2026-09-12: the row count is only the fallback for a Mac too old to
    /// publish a report. The count cannot see a projection cut BELOW 300 rows to
    /// fit the 512 KiB bound, so it showed no boundary for exactly the largest
    /// Desks. `report` is the Mac's own omission metadata and outranks it.
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

/// The only Desk kinds the mobile creation sheet may send across the iCloud
/// action boundary. Keeping the picker state typed prevents a UI edit from
/// emitting an arbitrary wire value the canonical Desk store would reject.
enum MobileDeskItemKind: String, CaseIterable, Hashable {
    case plan
    case project
    case watch
    case gh
    case standing
}

/// iOS may submit only the statuses accepted by the Mac action router. A
/// blocked item keeps its current label visible so it can be moved elsewhere,
/// but the phone never offers a reasonless transition into `blocked`.
enum MobileDeskStatusPickerPresentation {
    private static let routerAcceptedStatuses = [
        "watch", "flag", "now", "next", "todo", "done", "canceled",
    ]

    static func allowedStatuses(for current: String) -> [String] {
        current == "blocked" ? ["blocked"] + routerAcceptedStatuses : routerAcceptedStatuses
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
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @State private var selectedItem: MobileDeskItem?
    @State private var showingNewItem = false
    @State private var showingTasks = false
    @State private var showingPairing = false
    @State private var errorMessage: String?
    @State private var isRefreshingDesk = false
    @State private var hasAttemptedDeskLoad = false
    @State private var deskLoadError: String?
    @State private var historyLimit = 40
    @State private var notifiedHandle: String?

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
            WorkshopView(embedInNavigationStack: false)
        }
        .refreshable { await refreshDesk() }
        .task {
            openSampleRoute()
            notifiedHandle = MobileDeskItemNotificationIntent.consume() ?? notifiedHandle
            await refreshDesk()
            openNotifiedItem()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeagentOpenActivity)) { _ in
            guard let handle = MobileDeskItemNotificationIntent.consume() else { return }
            notifiedHandle = handle
            Task {
                await refreshDesk()
                openNotifiedItem()
            }
        }
        .onChange(of: sync.deskItems) { _, items in
            guard !items.isEmpty else { return }
            hasAttemptedDeskLoad = true
            deskLoadError = nil
            if let item = items.first(where: { $0.handle == selectedItem?.handle }) {
                selectedItem = item
            }
            openNotifiedItem()
        }
        .sheet(item: $selectedItem) { item in
            MobileDeskItemDetail(item: item, errorMessage: $errorMessage)
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
        Button { selectedItem = item } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    DeskStatusMark(status: item.status)
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
        Button { selectedItem = item } label: {
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
        case "detail": selectedItem = rows.first
        case "tasks", "taskdetail", "tasknew": showingTasks = true
        case "new": showingNewItem = true
        default: break
        }
    }

    private func openNotifiedItem() {
        guard let handle = notifiedHandle else { return }
        if let item = sync.deskItems.first(where: { $0.handle == handle }) {
            selectedItem = item
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

/// The mobile form validates the same note shape that the Mac action accepts,
/// so an iPhone user learns about a local input issue before an iCloud round
/// trip can return the router's otherwise generic rejection.
enum MobileDeskNotePresentation {
    static let maximumCharacterCount = 2_000
    static let maximumCharacterCountLabel = "2,000"

    static func submissionText(for draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumCharacterCount else { return nil }
        return text
    }

    static func validationMessage(for draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Enter a note before adding it." }
        if text.count > maximumCharacterCount {
            return "Desk notes can be at most \(maximumCharacterCountLabel) characters."
        }
        return nil
    }
}

struct MobileDeskItemDetail: View {
    let item: MobileDeskItem
    @Binding var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var outbox = MobileDeskNoteOutbox.shared
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @State private var note = ""
    @State private var isWorking = false

    /// The complete copy the Mac carries for priority items, when there is one.
    /// Its absence is not an error — the compact row is still the truth.
    private var readingCopy: MobileDeskItemReadingCopy? {
        sync.deskReadingCopies[item.handle]
    }

    private var displayedSummary: String? {
        readingCopy?.summary ?? item.summary
    }

    private var displayedNotes: [MobileDeskNote] {
        readingCopy?.notes ?? item.recentNotes
    }

    private var noteCount: Int { note.trimmingCharacters(in: .whitespacesAndNewlines).count }

    var body: some View {
        NavigationStack {
            AlivePage(title: item.title, line: item.requiresOwnerInput && item.closedAt == nil ? "Waiting on you" : (item.closedAt != nil ? DeskStatusWords.word(for: item.status) : item.activity(at: Date()).label), style: .pushed) {

                if let summary = displayedSummary, !summary.isEmpty {
                    AliveCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(summary)
                                .font(.body)
                                .lineSpacing(3)
                                .foregroundStyle(AlivePalette.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if let copy = readingCopy {
                                Text("Reading copy from \(AliveWords.readable(copy.capturedAt))")
                                    .font(.footnote)
                                    .foregroundStyle(AlivePalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let notice = MobileDeskBoundaryCopy.clippedNotice(summary) {
                                Text(notice)
                                    .font(.footnote)
                                    .foregroundStyle(AlivePalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .aliveRow()
                    }
                }

                AliveCard {
                    if let reason = item.blockedReason, !reason.isEmpty {
                        AliveValueRow(label: "Stuck on", value: reason)
                        AliveDivider()
                    }
                    if let waiting = item.waitingOn, !waiting.isEmpty {
                        AliveValueRow(label: "Waiting on", value: waiting)
                        AliveDivider()
                    }
                    AliveValueRow(label: "Project", value: item.project)
                    AliveDivider()
                    AliveValueRow(label: "Kind", value: DeskKindWords.word(for: item.kind))
                    AliveDivider()
                    HStack(spacing: 12) {
                        Text("Status")
                            .font(.body)
                            .foregroundStyle(AlivePalette.text)
                        Spacer(minLength: 8)
                        if isWorking { ProgressView().controlSize(.small) }
                        Picker("Status", selection: Binding(
                            get: { item.status },
                            set: { status in Task { await changeStatus(status) } }
                        )) {
                            ForEach(MobileDeskStatusPickerPresentation.allowedStatuses(for: item.status), id: \.self) {
                                Text(DeskStatusWords.word(for: $0)).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(AlivePalette.text)
                        .disabled(isWorking)
                    }
                    .aliveRow()
                }

                if !outbox.pendingNotes(for: item.handle).isEmpty {
                    AliveSection("Not on the Mac yet") {
                        ForEach(Array(outbox.pendingNotes(for: item.handle).enumerated()), id: \.element.id) { index, pending in
                            if index > 0 { AliveDivider() }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pending.text)
                                    .foregroundStyle(AlivePalette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(pending.statusLine)
                                    .font(.footnote)
                                    .foregroundStyle(AlivePalette.secondary)
                                if let error = pending.lastError {
                                    Text(error)
                                        .font(.footnote)
                                        .foregroundStyle(AlivePalette.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .aliveRow()
                        }
                    }
                }

                if !displayedNotes.isEmpty {
                    AliveSection(readingCopy == nil ? "Recent notes" : "Notes") {
                        ForEach(Array(displayedNotes.enumerated()), id: \.offset) { index, note in
                            if index > 0 { AliveDivider() }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.text)
                                    .foregroundStyle(AlivePalette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let notice = MobileDeskBoundaryCopy.clippedNotice(note.text) {
                                    Text(notice)
                                        .font(.footnote)
                                        .foregroundStyle(AlivePalette.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(AliveWords.readable(note.timestamp))
                                    .font(.footnote)
                                    .foregroundStyle(AlivePalette.secondary)
                            }
                            .aliveRow()
                        }
                    }
                }

                AliveSection("Add a note") {
                    TextField("What changed?", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                        .foregroundStyle(AlivePalette.text)
                        .onChange(of: note) { _, value in
                            outbox.setDraft(value, for: item.handle)
                        }
                        .aliveRow()
                    AliveDivider()
                    HStack {
                        Text("\(noteCount)/\(MobileDeskNotePresentation.maximumCharacterCountLabel)")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(noteCount > MobileDeskNotePresentation.maximumCharacterCount
                                             ? AnyShapeStyle(NativeAgentMobileTheme.Colors.trouble)
                                             : AnyShapeStyle(AlivePalette.secondary))
                        Spacer()
                        Button("Add Note") { addNote() }
                            .font(.subheadline.weight(.semibold))
                            .alivePrimaryButton()
                            .disabled(isWorking || MobileDeskNotePresentation.submissionText(for: note) == nil)
                    }
                    .aliveRow()
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { note = outbox.draft(for: item.handle) }
        }
    }

    private func changeStatus(_ status: String) async {
        guard status != item.status else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await iCloudSyncEngine.shared.setDeskItemStatus(handle: item.handle, status: status)
            await iCloudSyncEngine.shared.refreshDeskSnapshot()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    /// 2026-09-13: the note is saved here, not when the Mac answers. It leaves
    /// under one retained signed identity, shows as waiting, and the sheet
    /// closes — the Mac's confirmation reconciles the row later.
    private func addNote() {
        guard let clean = MobileDeskNotePresentation.submissionText(for: note) else {
            errorMessage = MobileDeskNotePresentation.validationMessage(for: note)
            return
        }
        outbox.submit(handle: item.handle, text: clean)
        note = ""
        dismiss()
    }
}

private struct NewMobileDeskItemSheet: View {
    @Binding var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var project = "General"
    @State private var summary = ""
    @State private var kind: MobileDeskItemKind = .plan
    @State private var isSaving = false
    @State private var submission: InboxAction?

    var body: some View {
        NavigationStack {
            AlivePage(title: "New item", line: "It goes on the board on your Mac.", style: .pushed) {
                AliveCard {
                    TextField("Title", text: $title)
                        .font(.headline)
                        .aliveRow()
                    AliveDivider()
                    HStack(spacing: 12) {
                        Text("Project").foregroundStyle(AlivePalette.text)
                        TextField("Project", text: $project)
                            .multilineTextAlignment(.trailing)
                    }
                    .aliveRow()
                    AliveDivider()
                    HStack {
                        Text("Kind").foregroundStyle(AlivePalette.text)
                        Spacer()
                        Picker("Kind", selection: $kind) {
                            ForEach(MobileDeskItemKind.allCases, id: \.self) {
                                Text(DeskKindWords.word(for: $0.rawValue)).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(AlivePalette.text)
                    }
                    .aliveRow()
                    AliveDivider()
                    TextField("Summary (optional)", text: $summary, axis: .vertical)
                        .lineLimit(2...6)
                        .aliveRow()
                }
                .foregroundStyle(AlivePalette.text)
                .disabled(submission != nil)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        } else {
                            Text("Add")
                        }
                    }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(isSaving ? "Adding Desk item" : "Add Desk item")
                }
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // 2026-09-06: each new sheet creates a request; uncertain saves retain it for retry.
        let intentionalNewRequest = submission == nil
        if submission == nil {
            var payload = [
                "kind": kind.rawValue,
                "project": project.trimmingCharacters(in: .whitespacesAndNewlines),
                "title": title.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanSummary.isEmpty { payload["summary"] = cleanSummary }
            submission = .make(action: "createDeskItem", payload: payload)
        }
        do {
            _ = try await iCloudSyncEngine.shared.createDeskItem(
                kind: kind.rawValue,
                project: project.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                submission: submission, intentionalNewRequest: intentionalNewRequest,
                onReplacement: { submission = $0 }
            )
            await iCloudSyncEngine.shared.refreshDeskSnapshot()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - Desk words and marks (shared with Desk tasks)

/// A status as a small mark: a breathing dot for what I'm doing now, a check
/// for done, a filled dot for next, a ring for the rest. The word beside it
/// carries the meaning; the mark is never coloured.
struct DeskStatusMark: View {
    let status: String

    var body: some View {
        Group {
            switch status.lowercased() {
            case "now", "running", "active":
                PulsingDot(color: AlivePalette.text, size: 7)
            case "done", "completed", "succeeded":
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AlivePalette.secondary)
            case "next":
                Circle().fill(AlivePalette.secondary).frame(width: 7, height: 7)
            default:
                Circle().strokeBorder(AlivePalette.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// Plain words for Desk and task statuses.
enum DeskStatusWords {
    static func word(for status: String) -> String {
        switch status.lowercased() {
        case "now": return "Doing now"
        case "next": return "Up next"
        case "todo": return "To do"
        case "watch": return "Watching"
        case "flag": return "Flagged"
        case "blocked": return "Stuck"
        case "done", "completed", "succeeded": return "Done"
        case "canceled", "cancelled": return "Canceled"
        case "active", "running": return "Working"
        case "queued": return "Waiting its turn"
        case "paused": return "Paused"
        case "failed", "error", "timeout": return "Didn't finish"
        default:
            if status.lowercased().contains("approval") { return "Needs your yes" }
            return AliveWords.humanized(status.lowercased())
        }
    }
}

enum DeskKindWords {
    static func word(for kind: String) -> String {
        switch kind.lowercased() {
        case "gh": return "GitHub"
        case "standing": return "Standing"
        case "watch": return "Watch"
        default: return AliveWords.humanized(kind.lowercased())
        }
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
