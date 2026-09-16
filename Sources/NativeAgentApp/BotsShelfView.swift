import SwiftUI
import StandingBots
import ApprovalInbox
import PersistenceCore
import NativeAgentShared
import AppKit

struct BotsShelfView: View {
    @Environment(AppModel.self) private var appModel
    @State var records: [BotsShelfRecord] = []
    @State var selectedID: UUID?
    var onContinue: (NativeAgentNavigationDestination) -> Void = { _ in }
    var isVisible = true
    private struct WatchIdentity: Equatable {
        let visible: Bool
        let records: [UUID]
    }
    @State var activeIDs: Set<UUID> = []
    @State private var editing = false
    @State private var editedBot: BotDefinition?
    @State private var notice: String?
    @State private var sessionOpen = false
    @State private var messages: [ChatMessage] = []
    @State private var busy = false
    /// `BackgroundLoopsAssembly.unattendedWorkAllowed` for this root, read on
    /// every reload. Off means no bot card may show a next-run time.
    @State private var unattended = true
    /// One shelf read in flight, one pending refresh behind it.
    @State private var reloadInFlight = false
    @State private var reloadPending = false
    @AppStorage(BotRunLimits.minimumIntervalMinutesKey) private var minimumMinutes = 15
    private var root: URL { appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot() }
    private var selected: BotsShelfRecord? { records.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                if let selected {
                    Button { selectedID = nil; sessionOpen = false; messages = [] } label: {
                        Label("Bots", systemImage: "chevron.left")
                    }.buttonStyle(.plain)
                    Text(selected.definition.name).font(ShellType.title).fixedSize(horizontal: false, vertical: true)
                } else { Text("Bots").font(ShellType.display) }
                Spacer()
                if selected == nil {
                    Button("New bot", systemImage: "plus") { editedBot = nil; editing = true }
                }
            }
            if let notice { Text(notice).font(ShellType.label).foregroundStyle(NativeAgentShell.secondary) }
            if let selected { detail(selected) } else { list }
        }
        .foregroundStyle(NativeAgentShell.text)
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { ShellRoomBackdrop() }
        .sheet(isPresented: $editing) {
            BotsEditorSheet(definition: editedBot) { bot in
                if editedBot == nil { try BotDefinitionStore(dataRoot: root).create(bot) }
                else { try BotDefinitionStore(dataRoot: root).update(bot) }
                reload()
            }
        }
        .liveTask(id: WatchIdentity(visible: isVisible, records: records.map(\.id))) {
            guard isVisible else { return }
            // The approval inbox, the event log and the trust policy are
            // canonical for what a card says: a remote approval decision, the
            // evidence a held event shows, and the unattended gate all land in
            // these files and must repaint the open card.
            let paths = ["bots/definitions", "bots/shelf-index.json", "bots/run-queue.json", "bots/runner-jobs.json",
                         "workflows/approvals/requests.json", "bots/last-events.json", "trust/policy.json"]
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
            if !visible { editing = false }
        }
        .transformPreference(MoodTintProseRectKey.self) { rect in
            if !isVisible { rect = nil }
        }
    }

    /// The opening line the empty shelf writes into the composer. The person
    /// sends it; the agent asks for the rest.
    static let makeABotDraft = "Help me keep up with something regularly."

    private func state(_ record: BotsShelfRecord) -> BotState {
        BotState(record: record, running: activeIDs.contains(record.id))
    }

    /// One glass card per bot: the mark, the name, the brief, one caption.
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(records) { record in
                    Button { selectedID = record.id; notice = nil } label: {
                        BotCard(record: record, state: state(record), allowsMotion: isVisible)
                    }.buttonStyle(.plain)
                }
                if !unattended {
                    Text(BotsShelfUnattended.pageLine)
                        .font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
                }
                if records.isEmpty {
                    // The first bot is a conversation, not a form: the agent
                    // gathers the brief and timing and picks an explicit
                    // supported model from a connected account, then creates the
                    // bot through the ordinary bot_create path. "New bot" stays
                    // in the header for anyone who would rather fill it in.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No bots yet.").font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
                        Button("Ask \(appModel.agentDisplayName) to make a bot", systemImage: "bubble.left.and.bubble.right") {
                            NotificationCenter.default.post(name: .openChatDraftRequest,
                                                            object: BotsShelfView.makeABotDraft)
                        }
                        .buttonStyle(.borderedProminent)
                    }.padding(.vertical, 16)
                }
                DisclosureGroup("Scheduling") {
                    Picker("Minimum interval", selection: $minimumMinutes) {
                        ForEach(1...15, id: \.self) { Text("\($0) minutes").tag($0) }
                    }.frame(maxWidth: 300)
                    Text("Only the person can change this minimum.").font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
                }
                .font(ShellType.caption).foregroundStyle(NativeAgentShell.tertiary).padding(.top, 12)
                .onChange(of: minimumMinutes) { _, _ in NotificationCenter.default.post(name: BotRunQueue.didChange, object: nil) }
            }
            .frame(maxWidth: 720, alignment: .leading).padding(.bottom, 20)
        }
    }

    private func detail(_ record: BotsShelfRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        BotMark(state: state(record), allowsMotion: isVisible)
                        Text(state(record).word).font(ShellType.labelMedium).foregroundStyle(NativeAgentShell.text)
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
                        Button("Run once") { perform { _ = try BotRunQueue(dataRoot: root).enqueueRequest(bot: record.id); notice = "Run queued." } }
                        Button(record.definition.paused ? "Resume" : "Pause") {
                            perform { _ = try BotDefinitionStore(dataRoot: root).pause(record.id, paused: !record.definition.paused) }
                        }.help("Pause scheduled turns. Run once remains available.")
                        Button("Edit") { editedBot = record.definition; editing = true }
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
                        ForEach(messages) { message in MessageBubble(message: message) }
                        if messages.isEmpty { Text("No messages yet.").font(ShellType.label).foregroundStyle(NativeAgentShell.secondary) }
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
                .task(id: isVisible && sessionOpen) {
                    guard isVisible && sessionOpen else { return }
                    do { messages = try await appModel.client.getChatMessages(sessionId: record.definition.sessionID) }
                    catch { notice = error.localizedDescription }
                }
            }
            .frame(maxWidth: 760, alignment: .leading).padding(.bottom, 20)
        }
    }

    static func limits(_ bot: BotDefinition) -> String {
        "Limits: \(bot.budget.tokens.formatted()) output tokens and \(Int(bot.budget.seconds)) seconds per run · \((bot.dailyTokenCeiling ?? BotRunLimits.dailyTokens).formatted()) reserved output tokens daily"
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); reload() } catch { notice = error.localizedDescription }
    }
    private func reload() {
        #if DEBUG
        // The offscreen renderer injects its records and live states directly.
        if ProcessInfo.processInfo.environment["BOTS_SHELF_SNAPSHOT_DIR"] != nil { return }
        #endif
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
        let root = root
        let allowed = await BackgroundLoopsAssembly.unattendedWorkAllowed(dataRoot: root)
        if unattended != allowed { unattended = allowed }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                (records: try Self.readRecords(root: root, unattended: allowed),
                 active: try BotRunQueue(dataRoot: root).activeOrQueuedIDs())
            }.value
            // Most reloads in a burst find the same shelf. Publishing only what
            // actually changed keeps SwiftUI from re-laying out every card —
            // and keeps the file watcher above (keyed on the record ids) from
            // restarting for nothing.
            if records != loaded.records { records = loaded.records }
            if activeIDs != loaded.active { activeIDs = loaded.active }
        } catch { notice = "Bots could not be loaded: \(error.localizedDescription)" }
    }
    nonisolated static func readRecords(root: URL, unattended: Bool = true) throws -> [BotsShelfRecord] {
        let shelf = ShelfStore(dataRoot: root)
        let dates = try BotRunnerScheduler.scheduledDates(dataRoot: root)
        let missed = try BotRunnerScheduler.missedRuns(dataRoot: root)
        let events = (try? BotEventStore(dataRoot: root).lastEvents()) ?? [:]
        // One checked bulk read for the whole shelf, instead of paginating
        // every bot's history and then re-reading each row through `entry`
        // (each of which decoded and sorted every book of every bot).
        let stored = try shelf.entriesByBot()
        return try BotDefinitionStore(dataRoot: root).list().map { bot in
            // The shared shelf-reading boundary, the same one shelf_read and
            // shelf_entry go through: an approval resolved from Telegram or the
            // iPhone settles the entry wherever it is read next, not only here.
            let entries = shelf.reconciling(stored[bot.id] ?? [])
            return BotsShelfRecord(definition: bot, entries: entries, unreadIDs: [],
                                   nextRun: bot.paused ? nil : dates[bot.id], missed: missed[bot.id], lastEvent: events[bot.id],
                                   unattendedAllowed: unattended)
        }.sorted { $0.definition.createdAt < $1.definition.createdAt }
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
            editedBot = record.definition
            editing = true
            return
        }
        do {
            let session = try await Self.chatSession(for: record.definition, root: root)
            await appModel.selectChatSession(session)
            if appModel.activeChatSessionId == session.id {
                if !appModel.chatSessions.contains(where: { $0.id == session.id }) { appModel.chatSessions.append(session) }
                onContinue(destination)
            }
        } catch { notice = error.localizedDescription }
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

    /// A new bot can be opened before its first turn. Use the ordinary checked
    /// session index and lock, preserving an existing row if a turn won the race.
    static func chatSession(for bot: BotDefinition, root: URL) async throws -> ChatSession {
        let path = root.appendingPathComponent("chat/sessions.json")
        let bytes = try await SwiftNativePersistenceCore().withFileLock(path) {
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: path)
            if let existing = rows.first(where: { row in
                guard case .string(let id)? = row["id"] else { return false }
                return id == bot.sessionID
            }) {
                return try ChatSessionIndexFile.serializedData(for: [existing])
            }
            rows.append([
                "id": .string(bot.sessionID), "title": .string(bot.name), "source": .string("bot"),
                "createdAt": .string(ISO8601DateFormatter().string(from: bot.createdAt)),
                "archived": .bool(false), "messageCount": .int(0)
            ])
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(ChatSessionIndexFile.serializedData(for: rows), to: path)
            return try ChatSessionIndexFile.serializedData(for: [rows[rows.count - 1]])
        }
        return try JSONDecoder.nativeAgent.decode([ChatSession].self, from: bytes)[0]
    }
}

private extension View {
    /// The shared settings card: slate under the lamp since 2026-09-10.
    func botCardSurface() -> some View { settingsCardSurface() }
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
            case .failed, .interrupted:
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
        case .interrupted: return "Stopped"
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

/// What a bot is doing right now, said in one word and one colour.
struct BotState {
    let word: String
    let color: Color
    let running: Bool

    init(record: BotsShelfRecord, running: Bool) {
        self.running = running
        if running { word = "Running"; color = NativeAgentShell.calm; return }
        if record.definition.paused { word = "Paused"; color = NativeAgentShell.tertiary; return }
        guard let latest = record.sortedEntries.first else { word = "New"; color = NativeAgentShell.secondary; return }
        switch latest.runtimeStatus {
        case .waitingForApproval: word = "Waiting for approval"
        case .waitingOnPerson: word = "Waiting on you"
        case .failed: word = "Failed"
        case .interrupted: word = "Interrupted"
        default: word = "Ready"
        }
        color = Self.color(forStatus: latest.runtimeStatus)
    }

    static func color(forStatus status: BotRunStatus) -> Color {
        switch status {
        case .waitingForApproval, .waitingOnPerson: NativeAgentShell.needsYou
        case .failed, .interrupted: NativeAgentShell.trouble
        default: NativeAgentShell.calm
        }
    }
}

/// The little bot itself: a rounded tile with one light that breathes while it works.
struct BotMark: View {
    let state: BotState
    var allowsMotion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        BotMarkContent(state: state, reduceMotion: reduceMotion, allowsMotion: allowsMotion)
    }
}

/// The same mounted content, with the system motion preference passed in so
/// lifecycle checks need not change the owner's global accessibility setting.
struct BotMarkContent: View {
    let state: BotState
    let reduceMotion: Bool
    var allowsMotion = true
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .overlay {
                if state.running && !reduceMotion && allowsMotion {
                    light.phaseAnimator([false, true]) { content, expanded in
                        content
                            .scaleEffect(expanded ? 1.35 : 1)
                            .opacity(expanded ? 0.55 : 1)
                    } animation: { _ in .easeInOut(duration: 1.4) }
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
    let state: BotState
    var allowsMotion = true
    /// The card is one thing to a reader: this bot. SwiftUI publishes nothing
    /// for a stack of styled Texts asked offscreen, so the words are stated
    /// here — VoiceOver and the quiet page read get the same line.
    private var spokenName: String {
        record.definition.brief.isEmpty
            ? record.definition.name
            : "\(record.definition.name). \(record.definition.brief)"
    }
    /// State word, what it last said, when it runs next, and a run it missed.
    private var spokenState: String {
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
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.link)
            } else { Text("\(artifact.name) · File unavailable") }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct BotsShelfPreviewPage: View {
    @AppStorage(BotsShelfPreference.key) private var enabled = true
    var onContinue: (NativeAgentNavigationDestination) -> Void = { _ in }
    var isVisible = true
    var body: some View {
        if enabled { BotsShelfView(onContinue: onContinue, isVisible: isVisible) }
        else { ShellRailPage(title: "Bots") { Text("Bots preview is turned off.") } }
    }
}
