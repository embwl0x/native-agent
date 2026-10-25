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
    /// The sheet opens WITH the bot it edits, one value: a separate "editing"
    /// flag opened before the chosen bot reached it, so Edit showed "New bot"
    /// and Save updated a helper that did not exist (User, 10-24).
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
    /// Alive glass (2026-09-23) is the list's; every bot's detail keeps the
    /// cards it had.
    private var root: URL { appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot() }
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
            } else {
            HStack(alignment: .firstTextBaseline) {
                if let selected {
                    Button {
                        selectedID = nil
                        sessionOpen = false
                        messagesLoading = true
                        messagesError = nil
                    } label: {
                        Label("Helpers", systemImage: "chevron.left")
                    }.buttonStyle(.plain)
                    Text(selected.definition.name).font(ShellType.title).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Helpers").font(ShellType.display)
                            ShellRailSubtitle(page: .bots)
                                .font(ShellType.labelMedium)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if selected == nil {
                    Button("New helper", systemImage: "plus") { editTarget = EditTarget(definition: nil) }
                }
            }
            }
            if let notice { Text(notice).font(ShellType.label).foregroundStyle(NativeAgentShell.secondary) }
            if let shelfError { Text(shelfError).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble) }
            if let selected { detail(selected) } else if aliveList { groupList } else { list }
        }
        .foregroundStyle(NativeAgentShell.text)
        .padding(.horizontal, NativeAgentSpacing.pageInset)
        .padding(.bottom, 20)
        .padding(.top, aliveList ? TodayMetrics.topPadding : 20)
        .frame(maxWidth: aliveList ? TodayMetrics.contentWidth : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: aliveList ? .top : .topLeading)
        .background { ShellRoomBackdrop() }
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

    /// One glass card per bot: the mark, the name, the brief, one caption.
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(records) { record in
                    Button { selectedID = record.id; notice = nil } label: {
                        BotCard(record: record, state: record, allowsMotion: isVisible)
                    }.buttonStyle(.plain)
                }
                listFooter
            }
            .frame(maxWidth: 720, alignment: .leading).padding(.bottom, 20)
        }
    }

    /// The Advanced shell's list shares its header's page column.
    private var groupList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                if !records.isEmpty {
                    AliveGroupCard {
                        ForEach(records) { record in
                            Button { selectedID = record.id; notice = nil } label: {
                                BotRow(record: record, state: record)
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
                // Mood in the tint, 2026-09-14: this is a transcript — the same
                // MessageBubble prose the room draws — sitting under the same
                // window pass. Without a guard its reading ground warms, which
                // is the one thing the tint never does. Publish the block as
                // the punched-out band, exactly as the chat transcript does.
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

    static func limits(_ bot: BotDefinition) -> String {
        "Limits: \(bot.budget.tokens.formatted()) output tokens and \(Int(bot.budget.seconds)) seconds per run · \(bot.dailyTokenCeiling.map { $0.formatted() + " reserved output tokens daily" } ?? "no daily ceiling")"
    }
    private func perform(_ action: @escaping @Sendable () throws -> Void) async {
        do {
            try await Task.detached(priority: .utility, operation: action).value
            await reloadNow()
        } catch { notice = Self.problem(error, action: "change that helper") }
    }
    private func reload() {
        // A settling run writes several watched files in a burst, and each
        // event used to launch its own unstructured reload of the whole shelf.
        // One read in flight, one pending refresh behind it: the last event of
        // a burst is still honoured, but the middle of the burst is not read
        // once per file.
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
        // 2026-09-13 (first-failure pass): a bot blocked on a retired model or a
        // disconnected account cannot be continued in its own chat — that
        // conversation runs the same checked contract and refuses the same way,
        // so the escape route depended on the thing that broke. Open the repair
        // for THIS bot instead: its own editor, where its account and model are
        // chosen. The missed run stays on the card above it.
        if let contract = await BotChatContract.checked(record.definition.sessionID, dataRoot: root),
           let problem = contract.modelChoiceProblem {
            notice = "\(record.definition.name) can't run yet. \(problem) Its unfinished work is kept - choose here and it picks up from there."
            editTarget = EditTarget(definition: record.definition)
            return
        }
        do {
            let session = try await StandingBotContinuity.openSession(for: record.definition, dataRoot: root)
            await appModel.selectChatSession(session)
            if appModel.activeChatSessionId == session.id {
                if !appModel.engine.transcripts.sessions.contains(where: { $0.id == session.id }) { appModel.engine.transcripts.sessions.append(session) }
                onContinue(destination)
            }
        } catch { notice = Self.problem(error, action: "open that helper's chat") }
    }

    /// Only an IDENTIFIED pending approval sends the person to Approvals. A
    /// legacy entry written before approvalID existed cannot be reconciled, so
    /// a stale "Waiting for approval" on one would route to Approvals forever;
    /// it opens the bot's chat instead.
    static func continueDestination(for record: BotsShelfRecord) -> NativeAgentNavigationDestination {
        guard let latest = record.sortedEntries.first, latest.runtimeStatus == .waitingForApproval,
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

private extension View {
    /// The kit's card (Alive glass), the one every other page wears.
    func botCardSurface() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .aliveCard()
            .accessibilityElement(children: .contain)
    }
}

/// One settled run, summarized: the headline the reply opened with, when the
/// run happened and how long it took, the outcome word, the model it ran on,
/// and whatever the reply produced. The full reply is behind "Open the reply";
/// the session transcript stays below the cards.
struct BotRunCard: View {
    /// How many settled cards the detail stacks before the transcript.
    static let shown = 5
    let entry: ShelfEntry


    /// The headline the run recorded, not the reply read again on every render.
    /// `make` over that one short line costs nothing and cleans a legacy
    /// headline stored before the prose rule existed.
    private var headline: String {
        // Reply presence is read BEFORE the stored headline: a run that said
        // nothing is never headlined with words. Entries written before
        // 2026-09-13 placeholdered an empty reply as "Reply saved", so a
        // stored headline is only trusted when there is a reply behind it.
        guard !entry.actualReply.isEmpty else {
            switch entry.runtimeStatus {
            case .completed:
                return entry.runHealth == .nothingNew ? "Checked, nothing new" : "Nothing saved"
            case .waitingForApproval:
                return "Waiting for approval — no reply yet"
            case .waitingOnPerson:
                return "Waiting on you — no reply yet"
            case .failed, .stopped, .interrupted:
                // The recorded cause, said once, with the absence stated.
                return (causeStem.isEmpty ? outcome : causeStem) + " — no reply"
            }
        }
        if !entry.headline.isEmpty { return BotHeadline.make(from: entry.headline) }
        return BotHeadline.make(from: entry.actualReply)
    }
    /// The recorded cause as one clean clause, without its full stop.
    private var causeStem: String {
        let recorded = [entry.statusDetail, entry.uncertainties.first]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return recorded.split(separator: ".").first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
    /// One word for how the run ended, never a verdict on the task.
    private var outcome: String {
        switch entry.runtimeStatus {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .interrupted: return "Interrupted"
        case .waitingForApproval: return "Blocked"
        case .waitingOnPerson: return "Waiting"
        }
    }
    private var duration: String? {
        let seconds = entry.spend.seconds
        guard seconds > 0 else { return nil }
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let whole = Int(seconds.rounded())
        return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s"
    }
    /// What the run ran on, recorded at run time. A run written before 0.4.12
    /// says so rather than borrowing the bot's current choice.
    private var model: String { entry.model ?? "Model not recorded" }
    /// The recorded cause when a run did not complete; never invented.
    private var cause: String? {
        guard entry.runtimeStatus != .completed else { return nil }
        let recorded = [entry.statusDetail, entry.uncertainties.first]
            .compactMap { $0 }.first { !$0.isEmpty && $0 != headline }
        return recorded ?? "Cause not recorded."
    }
    private var artifacts: [BotArtifact] { entry.artifacts ?? [] }
    /// How the run ended and when — the row's name to a reader.
    private var spokenOutcome: String {
        [outcome, BotsShelfRecord.shortDate(entry.runAt), duration]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
    /// What the run actually said, plus the cause when it did not complete and
    /// the model it ran on. Stated here because a stack of styled Texts
    /// publishes no words when the page is read offscreen.
    private var spokenSummary: String {
        [headline, cause, model].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    /// A settled run wears one of the family's three marks: done, or — for a
    /// run that failed, was stopped, or is still blocked — the yellow mark that
    /// means "this did not land, or I cannot say it did". A bot run is never
    /// "declined": nobody refused it.
    private var mark: InlineCardMark {
        entry.runtimeStatus == .completed ? .done : .unknown
    }

    /// Date, duration and the model it ran on — the metadata the settled
    /// receipt carries beside the outcome.
    private var metaLine: String {
        [outcome, BotsShelfRecord.shortDate(entry.runAt), duration, model]
            .compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // 0.4.12 cards round: one settled run, in the shared receipt grammar —
    // hairline only, one line, mark + what the run said, with the date, the
    // duration and the model beside it. The cause, the artifacts and the full
    // reply are all still here, one disclosure away; nothing the card carried
    // is dropped.
    var body: some View {
        InlineCardReceipt(
            mark: mark,
            outcome: headline,
            meta: metaLine,
            detailsLabel: hasDetails ? "Full reply" : nil
        ) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                if let cause {
                    Text(cause).font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                    BotsShelfArtifactLink(artifact: artifact)
                }.foregroundStyle(.blue)
                if !entry.actualReply.isEmpty {
                    let reply = entry.actualReply.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let attributed = ChatMarkdownCache.attributed(reply) {
                        Text(attributed).font(ShellType.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(reply).font(ShellType.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        // `.contain`, not `.ignore`: the row names itself while the disclosure
        // and the artifact links stay reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenOutcome)
        .accessibilityValue(spokenSummary)
    }

    /// Whether there is anything behind the fold at all.
    private var hasDetails: Bool {
        !entry.actualReply.isEmpty || cause != nil || !artifacts.isEmpty
    }
}

/// Consecutive checks that found nothing, as one quiet dated row. The count is
/// on the face of it and the exact runs are one disclosure away — a finding a
/// few checks back stays on the card instead of falling into the transcript.
struct BotQuietRunsRow: View {
    let entries: [ShelfEntry]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in BotRunCard(entry: entry) }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(NativeAgentShell.tertiary).frame(width: 7, height: 7)
                    Text(BotRunFeed.quietLine(entries))
                        .font(ShellType.captionMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)
        }
        .padding(16).botCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BotRunFeed.quietLine(entries))
    }
}

/// The Mac draws the shared helper status in the shell's colors.
extension BotsShelfRecord {
    var word: String { statusWord }
    var color: Color {
        switch status {
        case .running, .ready: NativeAgentShell.calm
        case .queued, .new, .stopped: NativeAgentShell.secondary
        case .paused: NativeAgentShell.tertiary
        case .waitingForApproval, .waitingOnPerson: NativeAgentShell.needsYou
        case .failed, .interrupted, .needsModelChoice: NativeAgentShell.trouble
        }
    }

    static func color(forStatus status: BotRunStatus) -> Color {
        switch status {
        case .waitingForApproval, .waitingOnPerson: NativeAgentShell.needsYou
        case .stopped: NativeAgentShell.secondary
        case .failed, .interrupted: NativeAgentShell.trouble
        default: NativeAgentShell.calm
        }
    }
}

/// The little bot itself: a rounded tile with one light that breathes while it works.
struct BotMark: View {
    let state: BotsShelfRecord
    var allowsMotion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        BotMarkContent(state: state, reduceMotion: reduceMotion, allowsMotion: allowsMotion)
    }
}

/// The same mounted content, with the system motion preference passed in so
/// lifecycle checks need not change the owner's global accessibility setting.
struct BotMarkContent: View {
    let state: BotsShelfRecord
    let reduceMotion: Bool
    var allowsMotion = true
    var body: some View {
        RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .overlay {
                if state.running && !reduceMotion && allowsMotion {
                    light.phaseAnimator([false, true]) { content, expanded in
                        content
                            .scaleEffect(expanded ? 1.35 : 1)
                            .opacity(expanded ? 0.55 : 1)
                    } animation: { _ in NativeAgentMotion.breathe }
                } else {
                    light
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityLabel(state.word)
    }

    private var light: some View {
        Circle().fill(state.color)
            .frame(width: 8, height: 8)
            .shadow(color: state.color.opacity(state.running ? 0.6 : 0), radius: 4)
    }
}

struct BotCard: View {
    let record: BotsShelfRecord
    let state: BotsShelfRecord
    var allowsMotion = true
    /// The card is one thing to a reader: this bot. SwiftUI publishes nothing
    /// for a stack of styled Texts asked offscreen, so the words are stated
    /// here — VoiceOver and the quiet page read get the same line.
    private var spokenName: String { Self.spokenName(record) }
    private var spokenState: String { Self.spokenState(record, state: state) }
    static func spokenName(_ record: BotsShelfRecord) -> String {
        record.definition.brief.isEmpty
            ? record.definition.name
            : "\(record.definition.name). \(record.definition.brief)"
    }
    /// State word, what it last said, when it runs next, and a run it missed.
    static func spokenState(_ record: BotsShelfRecord, state: BotsShelfRecord) -> String {
        [state.word, record.lastOutcomeLine, record.scheduleLine, record.missedLine]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BotMark(state: state, allowsMotion: allowsMotion).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.definition.name).font(ShellType.bodySemibold).lineLimit(1).layoutPriority(-1)
                    // The word carries the state in text ink; the mark's light carries the colour.
                    Text(state.word).font(ShellType.captionMedium).foregroundStyle(NativeAgentShell.text).fixedSize()
                    Spacer(minLength: 0)
                }
                Text(record.definition.brief).font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                // Small text over a lamp-lit card: text ink, not the greys (4.5:1 target).
                Text(record.lastOutcomeLine).font(ShellType.caption).foregroundStyle(NativeAgentShell.text).lineLimit(1)
                Text(record.scheduleLine).font(ShellType.caption).foregroundStyle(NativeAgentShell.text).lineLimit(1)
                // A run that never fired says so, in the same ink as the rest.
                if let missedLine = record.missedLine {
                    Text(missedLine).font(ShellType.caption).foregroundStyle(NativeAgentShell.text).lineLimit(1)
                }
            }
        }
        .padding(14).contentShape(Rectangle()).botCardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenName)
        .accessibilityValue(spokenState)
    }
}

/// One helper in the Advanced shell's group card: a glyph tile, the name, its
/// timing and last run in plain words, and a status pill. The tile never
/// animates; a helper waiting on him wears the waiting dot, the one teal.
struct BotRow: View {
    let record: BotsShelfRecord
    let state: BotsShelfRecord

    private var isManual: Bool {
        if case .manual = record.definition.cadence, record.definition.eventTrigger == nil { return true }
        return false
    }

    /// The state, never the timing: Scheduled, On event, Paused or Manual.
    private var status: String {
        if record.definition.paused { return "Paused" }
        if isManual { return "Manual" }
        return record.definition.eventTrigger != nil ? "On event" : "Scheduled"
    }

    /// Clock for a schedule, bolt for an event, a plain tool for run-by-hand.
    /// Not "play": the tile is decoration (the row opens the helper), and a
    /// play glyph read as a Run button.
    private var glyph: String {
        if record.definition.eventTrigger != nil { return "bolt" }
        return isManual ? "wrench.and.screwdriver" : "clock"
    }

    /// When it runs, in the words the card already uses — never a time the
    /// scheduler will not keep. Nil for a manual helper: the pill says it.
    private var timing: String? {
        if record.needsModelChoice { return "Choose a model" }
        if !record.definition.paused, !record.unattendedAllowed, !record.runsWithUnattendedOff {
            return BotsShelfUnattended.cardLine
        }
        if let trigger = record.definition.eventTrigger { return "Wakes on \(trigger.label)" }
        if isManual { return nil }
        return record.cadence
    }

    /// How its last run went, and a run it missed.
    private var last: String {
        var parts: [String] = []
        if state.running {
            parts.append("running now")
        } else if state.queued {
            parts.append("queued")
        } else if let latest = record.sortedEntries.first {
            let when = BotsShelfRecord.shortDate(latest.runAt)
            switch latest.runtimeStatus {
            case .completed: parts.append("last ran \(when)")
            case .waitingForApproval: parts.append("waiting for approval")
            case .waitingOnPerson: parts.append("waiting on you")
            case .failed: parts.append("last run failed \(when)")
            case .stopped: parts.append("last run stopped \(when)")
            case .interrupted: parts.append("last run interrupted \(when)")
            }
        } else {
            parts.append("no runs yet")
        }
        if let missed = record.missed { parts.append("missed \(BotsShelfRecord.shortDate(missed.dueAt))") }
        return parts.joined(separator: " · ")
    }

    private var waitingOnHim: Bool {
        guard !state.running, let latest = record.sortedEntries.first else { return false }
        return latest.runtimeStatus == .waitingForApproval || latest.runtimeStatus == .waitingOnPerson
    }

    /// "at 8:30 AM" today, "tomorrow at 8:30 AM", else "on Sep 25 at 8:30 AM".
    static func when(_ date: Date, now: Date = Date()) -> String {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.autoupdatingCurrent
        let time = DateFormatter()
        time.setLocalizedDateFormatFromTemplate("jm")
        time.timeZone = TimeZone.autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time.string(from: date))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time.string(from: date))"
        }
        return "on \(BotsShelfRecord.shortDate(date))"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .fill(NativeAgentShell.softFill)
                .overlay {
                    Image(systemName: glyph)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                .overlay(alignment: .topTrailing) {
                    if waitingOnHim { AliveWaitingDot().offset(x: 3, y: -3) }
                }
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                Text(record.definition.name)
                    .font(ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text([timing, last].compactMap { $0 }.joined(separator: " · "))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(height: TodayMetrics.rowContentHeight, alignment: .leading)
            Spacer(minLength: 12)
            AlivePill(status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BotCard.spokenName(record))
        .accessibilityValue(BotCard.spokenState(record, state: state))
    }
}

private struct BotsShelfArtifactLink: View {
    let artifact: BotArtifact
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading) {
            if !artifact.path.isEmpty {
                if let url = URL(string: artifact.path), let scheme = url.scheme {
                    if ["https", "http", "file"].contains(scheme.lowercased()) { Link(artifact.name, destination: url) }
                    else { Text(artifact.name) }
                } else { Link(artifact.name, destination: URL(fileURLWithPath: artifact.path)) }
            } else if let encoded = artifact.base64, let data = Data(base64Encoded: encoded) {
                Button("Save \(artifact.name)", systemImage: "arrow.down.doc") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = artifact.name
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        do { try data.write(to: url, options: .atomic) }
                        catch { self.error = UserFacingError.message(error, action: "save that file") }
                    }
                }.buttonStyle(.link)
            } else { Text("\(artifact.name) · File unavailable") }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

extension BotRunFeed {
    /// "Three quiet checks since Sep 10 at 1:47 AM" — the count stays visible.
    static func quietLine(_ entries: [ShelfEntry]) -> String {
        let since = entries.last.map { BotsShelfRecord.shortDate($0.runAt) }
        return "\(TodayWords.spelled(entries.count)) quiet check\(entries.count == 1 ? "" : "s")"
            + (since.map { " since \($0)" } ?? "")
    }
}
