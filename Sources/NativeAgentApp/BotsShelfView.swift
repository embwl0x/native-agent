import BackgroundWork
import ChatTurnRuntime
import ChatToolRuntime
import AppToolRuntime
import NativeAgentCore
import SwiftUI
import StandingBots
import ProviderRouting
import ApprovalInbox
import PersistenceCore
import Transcripts
import NativeAgentShared
import AppKit
// Blueprint: | `BotsShelfView.swift` | shared helper status and transcript messages/streaming tail; no private transcript rows or JSONL observation |

struct BotsShelfView: View {
    @Environment(AppModel.self) private var appModel
    @State var records: [BotsShelfRecord] = []
    @State private var shelfRead = LatestRead()
    @State var selectedID: UUID?
    var onContinue: (NativeAgentNavigationDestination) -> Void = { _ in }
    var isVisible = true
    private struct WatchIdentity: Equatable {
        let visible: Bool
        let records: [UUID]
    }
    /// The sheet carries the exact helper it edits.
    private struct EditTarget: Identifiable { let id = UUID(); let definition: BotDefinition? }
    @State private var editTarget: EditTarget?
    @State private var notice: String?
    @State private var sessionOpen = false
    @State private var messagesLoading = true
    @State private var messagesError: String?
    @State private var shelfLoaded = false
    @State private var shelfError: String?
    @State private var busy = false
    /// `WorkshopBackgroundWork.unattendedWorkAllowed` for this root, read on
    /// every reload. Off means no bot card may show a next-run time.
    @State private var unattended = true
    /// One shelf read in flight, one pending refresh behind it.
    @State private var reloadInFlight = false
    @State private var reloadPending = false
    private var root: URL { appModel.engine.dataRoot }
    private var selected: BotsShelfRecord? { records.first { $0.id == selectedID } }
    private var aliveList: Bool { selected == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if aliveList {
                HStack(alignment: .top) {
                    AlivePageHeader(title: "Helpers", line: headerLine)
                    Spacer()
                    Button("New helper", systemImage: "plus") { editTarget = EditTarget(definition: nil) }
                        .buttonStyle(.borderedProminent)
                        .hazeTinted(.button)
                        .padding(.top, 14)
                        // Ends where the other pages' controls end.
                        .padding(.trailing, ShellScrollGutter.shared.width)
                }
                .padding(.bottom, AliveMetrics.sectionSpacing - 14)
            } else if let selected {
                HStack(alignment: .firstTextBaseline) {
                    Button {
                        selectedID = nil
                        sessionOpen = false
                        messagesLoading = true
                        messagesError = nil
                    } label: {
                        Label("Helpers", systemImage: "chevron.left")
                    }.buttonStyle(.plain)
                    Text(selected.definition.name).font(ShellType.title).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            if let notice { Text(notice).font(ShellType.label).foregroundStyle(NativeAgentShell.secondary) }
            if let shelfError { Text(shelfError).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble) }
            if let selected { detail(selected) } else { groupList }
        }
        .foregroundStyle(NativeAgentShell.text)
        .padding(.horizontal, NativeAgentSpacing.pageInset)
        .padding(.bottom, 20)
        .padding(.top, aliveList ? TodayMetrics.topPadding : 20)
        .frame(maxWidth: aliveList ? TodayMetrics.contentWidth : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: aliveList ? .top : .topLeading)
        .sheet(item: $editTarget) { target in
            BotsEditorSheet(definition: target.definition, nextRun: records.first { $0.id == target.definition?.id }?.nextRun) { bot in
                let store = BotDefinitionStore(dataRoot: root)
                let creating = target.definition == nil
                _ = try await Task.detached(priority: .utility) {
                    try (creating ? store.create(bot) : store.update(bot))
                }.value
                await reloadNow()
            }
        }
        .liveTask(id: WatchIdentity(visible: isVisible, records: records.map(\.id))) {
            guard isVisible else { return }
            // The approval inbox, the event log and the trust policy are
            // canonical for what a card says: a remote approval decision, the
            // evidence a held event shows, and the unattended gate all land in
            // these files and must repaint the open card.
            let paths = ["bots/definitions", "bots/shelf-index.json", "bots/run-queue.json", "bots/runner-jobs.json",
                         "workflows/approvals/requests.json", "bots/last-events.json", "trust/policy.json",
                         "providers/surfaces.json", "providers/active.json"]
                + records.map { "bots/\($0.id.uuidString)/run.lock" }
            let events = FileChangeEvents(paths: paths.map { root.appendingPathComponent($0) }, emitInitial: true)
            await withTaskCancellationHandler {
                for await _ in events.stream {
                    guard !Task.isCancelled else { break }
                    reload()
                }
            } onCancel: { events.cancel() }
        }
        // The visible page is loaded by the watcher above (it emits an
        // initial event); the offscreen copy has no watcher, so it reads once.
        .quietReadTask(live: false) { await reloadNow() }
        .onReceive(NotificationCenter.default.publisher(for: BotRunQueue.didChange)) { _ in
            if isVisible { reload() }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible { editTarget = nil }
        }
        .transformPreference(MoodTintProseRectKey.self) { rect in
            if !isVisible { rect = nil }
        }
    }

    /// The opening line the empty shelf writes into the composer. The person
    /// sends it; the agent asks for the rest.
    static let makeABotDraft = "Help me keep up with something regularly."

    /// The Advanced shell's list shares its header's page column.
    private var groupList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                if !records.isEmpty {
                    AliveGroupCard {
                        ForEach(records) { record in
                            Button { selectedID = record.id; notice = nil } label: {
                                BotRow(record: record)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                listFooter
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, NativeAgentSpacing.pageInset)
        }
        .pageScrollColumn()
    }

    /// The header's one sentence, in numerals: how many helpers, and when the
    /// soonest real run is. Nil until the shelf has been read.
    private var headerLine: String? {
        guard shelfLoaded else { return nil }
        let count = records.count
        guard count > 0 else { return "No helpers yet." }
        let helpers = "\(count) \(count == 1 ? "helper" : "helpers")"
        // Only a time the scheduler will actually keep (the card's own rule).
        let next = records.compactMap { record -> Date? in
            guard !record.definition.paused, !record.needsModelChoice,
                  record.unattendedAllowed || record.runsWithUnattendedOff else { return nil }
            return record.nextRun
        }.min()
        if let next { return "\(helpers), the next runs \(BotRow.when(next))." }
        if !unattended { return "\(helpers). Scheduled runs are off." }
        return "\(helpers), none on a timer."
    }

    @ViewBuilder
    private var listFooter: some View {
                if !unattended {
                    Text(BotsShelfUnattended.pageLine)
                        .font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
                }
                if records.isEmpty, shelfError == nil, !shelfLoaded {
                    ProgressView("Loading helpers…")
                }
                if records.isEmpty, shelfError == nil, shelfLoaded {
                    // The first bot is a conversation, not a form: the agent
                    // gathers the brief and timing and picks an explicit
                    // supported model from a connected account, then creates the
                    // bot through the ordinary bot_create path. "New bot" stays
                    // in the header for anyone who would rather fill it in.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No helpers yet.").font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
                        Button("Make one in chat", systemImage: "bubble.left.and.bubble.right") {
                            NotificationCenter.default.post(name: .openChatDraftRequest,
                                                            object: BotsShelfView.makeABotDraft)
                        }
                        .buttonStyle(.borderedProminent)
                        .hazeTinted(.button)
                    }.padding(.vertical, 16)
                }
    }

    private func detail(_ record: BotsShelfRecord) -> some View {
        let messages = appModel.engine.transcripts.messages(for: record.definition.sessionID)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        BotMark(state: record, allowsMotion: isVisible)
                        Text(record.word).font(ShellType.labelMedium).foregroundStyle(NativeAgentShell.text)
                        Text("·").foregroundStyle(NativeAgentShell.tertiary)
                        Text(record.choiceLine).font(ShellType.label).foregroundStyle(NativeAgentShell.secondary).lineLimit(1)
                        Spacer()
                        Text(record.timingLine).font(ShellType.caption).foregroundStyle(NativeAgentShell.text)
                    }
                    if let missedLine = record.missedLine {
                        Text(missedLine).font(ShellType.caption).foregroundStyle(NativeAgentShell.text)
                    }
                    Text(record.definition.brief).font(ShellType.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let wakeLine = record.wakeLine {
                        Text(wakeLine).font(ShellType.caption).foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Run once") {
                            Task {
                                do {
                                    _ = try await BotRunConversation.enqueueRequestedCheck(botID: record.id, dataRoot: root)
                                    notice = "Run queued."
                                    reload()
                                } catch { notice = Self.problem(error, action: "queue a run") }
                            }
                        }
                        // Pause has nothing to stop on a manual bot with no event.
                        if record.definition.cadence != .manual || record.definition.eventTrigger != nil || record.definition.paused {
                            Button(record.definition.paused ? "Resume" : "Pause") {
                                let store = BotDefinitionStore(dataRoot: root)
                                Task { await perform { _ = try store.pause(record.id, paused: !record.definition.paused) } }
                            }.help("Pause scheduled turns. Run once remains available.")
                        }
                        Button("Edit") { editTarget = EditTarget(definition: record.definition) }
                        Button("Continue in Chat", systemImage: "arrow.up.right") { Task { await continueInChat(record) } }.disabled(busy)
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                .padding(16).botCardSurface()

                // One settled card per run, newest first; earlier runs stay in
                // the transcript below.
                let feed = BotRunFeed.rows(record.sortedEntries)
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(feed.prefix(BotRunCard.shown)) { row in
                        switch row {
                        case .run(let entry): BotRunCard(entry: entry)
                        case .quiet(let entries): BotQuietRunsRow(entries: entries)
                        }
                    }
                    if record.entries.isEmpty {
                        Text("No runs yet.").font(ShellType.label).foregroundStyle(NativeAgentShell.secondary).padding(.horizontal, 4)
                    } else if feed.count > BotRunCard.shown {
                        Text("Earlier runs are in the session below.")
                            .font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary).padding(.horizontal, 4)
                    }
                }
                DisclosureGroup("Session · messages and tool activity", isExpanded: $sessionOpen) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(messages) { message in
                            StreamingTailBubble(message: message, isLastAssistant: false,
                                isLive: appModel.engine.turns.streamingSessions.contains(record.definition.sessionID) && message.id == messages.last?.id)
                        }
                        if messagesLoading {
                            ProgressView("Loading messages…")
                        } else if let messagesError {
                            Text(messagesError).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble)
                        } else if messages.isEmpty {
                            Text("No messages yet.").font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
                        }
                    }.padding(.top, 8)
                }
                .font(ShellType.labelMedium).foregroundStyle(NativeAgentShell.secondary)
                .padding(16).botCardSurface()
                // Exclude transcript prose and its reading ground from the window's mood tint.
                .moodTintProseGuard()
                .task(id: "\(isVisible && sessionOpen):\(record.definition.sessionID)") {
                    guard isVisible && sessionOpen else { return }
                    let sessionID = record.definition.sessionID
                    await appModel.engine.observeSessionMessages(sessionID) { error in
                        messagesError = error.map { UserFacingError.message($0, action: "load these messages") }
                        messagesLoading = false
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading).padding(.bottom, 20)
        }
    }

    private func perform(_ action: @escaping @Sendable () throws -> Void) async {
        do {
            try await Task.detached(priority: .utility, operation: action).value
            await reloadNow()
        } catch { notice = Self.problem(error, action: "change that helper") }
    }
    private func reload() {
        // Coalesce shelf events into one active read and one pending refresh.
        if reloadInFlight { reloadPending = true; return }
        Task { await reloadNow() }
    }

    /// The same read, awaitable. A quiet read has to know when the shelf has
    /// actually landed before it draws the page, and a detached `Task {}` never
    /// tells anyone that.
    private func reloadNow() async {
        if reloadInFlight { reloadPending = true; return }
        reloadInFlight = true
        defer { reloadInFlight = false }
        repeat {
            reloadPending = false
            await readShelfOnce()
        } while reloadPending
    }

    private func readShelfOnce() async {
        // Definitions, the shelf and the scheduler's jobs are all read under the
        // cross-process store lock. That never belongs on the main actor.
        _ = await shelfRead.read({ () async -> Result<([BotsShelfRecord], Bool?), Error> in
        do {
            var unattended: Bool?
            let loaded = try await appModel.engine.botsShelfRead { allowed in
                unattended = allowed
            }
            return .success((loaded, unattended))
        } catch { return .failure(error) }
        }, publish: { result in
        do {
            let (loaded, allowed) = try result.get()
            if let allowed, unattended != allowed { unattended = allowed }
            // Most reloads in a burst find the same shelf. Publishing only what
            // actually changed keeps SwiftUI from re-laying out every card —
            // and keeps the file watcher above (keyed on the record ids) from
            // restarting for nothing.
            if records != loaded { records = loaded }
            shelfLoaded = true
            shelfError = nil
        } catch { shelfError = UserFacingError.message(error, action: "load helpers") }
        })
    }

    private func continueInChat(_ record: BotsShelfRecord) async {
        let destination = Self.continueDestination(for: record)
        if destination == .activity(.approvals) {
            onContinue(destination)
            return
        }
        busy = true
        defer { busy = false }
        // A blocked bot opens its account/model editor because its chat uses the same checked contract.
        if let contract = await BotChatContract.checked(record.definition.sessionID, dataRoot: root),
           let problem = contract.modelChoiceProblem {
            notice = "\(record.definition.name) can't run yet. \(problem) Its unfinished work is kept - choose here and it picks up from there."
            editTarget = EditTarget(definition: record.definition)
            return
        }
        do {
            let session = try await StandingBotContinuity.openSession(for: record.definition, dataRoot: root)
            appModel.engine.transcripts.sessionTransactions.publishOpenedSession(session, store: appModel.engine.transcripts)
            await appModel.selectChatSession(session)
            if appModel.activeChatSessionId == session.id {
                onContinue(destination)
            }
        } catch { notice = Self.problem(error, action: "open that helper's chat") }
    }

    /// Only an identified pending approval routes to Approvals; other entries
    /// open the helper's chat.
    static func continueDestination(for record: BotsShelfRecord) -> NativeAgentNavigationDestination {
        guard let latest = record.latestEntry, latest.runtimeStatus == .waitingForApproval,
              let approvalID = latest.approvalID, !approvalID.isEmpty else { return .sidebar(.chat) }
        return .activity(.approvals)
    }

    /// A helper-store failure in words: the store's own sentence when it
    /// carries one, otherwise one plain line (the raw error goes to the log).
    static func problem(_ error: Error, action: String) -> String {
        if case .invalidValue(let detail)? = error as? StandingBotsError { return detail }
        return UserFacingError.message(error, action: action)
    }

}

extension View {
    /// The kit's card (Alive glass), the one every other page wears.
    func botCardSurface() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .aliveCard()
            .accessibilityElement(children: .contain)
    }
}
