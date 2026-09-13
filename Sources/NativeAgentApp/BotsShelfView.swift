import SwiftUI
import StandingBots
import PersistenceCore
import NativeAgentShared
import AppKit

struct BotsShelfView: View {
    @Environment(AppModel.self) private var appModel
    @State var records: [BotsShelfRecord] = []
    @State var selectedID: UUID?
    var onContinue: (NativeAgentNavigationDestination) -> Void = { _ in }
    @State var activeIDs: Set<UUID> = []
    @State private var editing = false
    @State private var editedBot: BotDefinition?
    @State private var notice: String?
    @State private var sessionOpen = false
    @State private var messages: [ChatMessage] = []
    @State private var busy = false
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
        .task(id: records.map(\.id)) {
            let paths = ["bots/definitions", "bots/shelf-index.json", "bots/run-queue.json", "bots/runner-jobs.json"]
                + records.map { "bots/\($0.id.uuidString)/run.lock" }
            let events = FileChangeEvents(paths: paths.map { root.appendingPathComponent($0) }, emitInitial: true)
            await withTaskCancellationHandler {
                for await _ in events.stream {
                    guard !Task.isCancelled else { break }
                    reload()
                }
            } onCancel: { events.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: BotRunQueue.didChange)) { _ in reload() }
    }

    private func state(_ record: BotsShelfRecord) -> BotState {
        BotState(record: record, running: activeIDs.contains(record.id))
    }

    /// One glass card per bot: the mark, the name, the brief, one caption.
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(records) { record in
                    Button { selectedID = record.id; notice = nil } label: {
                        BotCard(record: record, state: state(record))
                    }.buttonStyle(.plain)
                }
                if records.isEmpty {
                    Text("No bots yet.").font(ShellType.label).foregroundStyle(NativeAgentShell.secondary).padding(.vertical, 16)
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
                        BotMark(state: state(record))
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
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(record.sortedEntries.prefix(BotRunCard.shown)) { entry in
                        BotRunCard(entry: entry)
                    }
                    if record.entries.isEmpty {
                        Text("No runs yet.").font(ShellType.label).foregroundStyle(NativeAgentShell.secondary).padding(.horizontal, 4)
                    } else if record.entries.count > BotRunCard.shown {
                        Text("The last \(BotRunCard.shown) runs. Earlier runs are in the session below.")
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
                .task(id: sessionOpen) {
                    guard sessionOpen else { return }
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
        // Definitions, the shelf and the scheduler's jobs are all read under the
        // cross-process store lock. That never belongs on the main actor.
        let root = root
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    (records: try Self.readRecords(root: root),
                     active: try BotRunQueue(dataRoot: root).activeOrQueuedIDs())
                }.value
                records = loaded.records
                activeIDs = loaded.active
            } catch { notice = "Bots could not be loaded: \(error.localizedDescription)" }
        }
    }
    nonisolated static func readRecords(root: URL) throws -> [BotsShelfRecord] {
        let shelf = ShelfStore(dataRoot: root)
        let dates = try BotRunnerScheduler.scheduledDates(dataRoot: root)
        let missed = try BotRunnerScheduler.missedRuns(dataRoot: root)
        let events = (try? BotEventStore(dataRoot: root).lastEvents()) ?? [:]
        return try BotDefinitionStore(dataRoot: root).list().map { bot in
            var entries: [ShelfEntry] = []
            var cursor: String?
            while true {
                let page = try shelf.shelfRead(bot: bot.id, limit: 100, cursor: cursor)
                entries += try page.rows.map { try shelf.entry($0.id) }
                guard !page.rows.isEmpty, page.nextCursor != cursor else { break }
                cursor = page.nextCursor
            }
            return BotsShelfRecord(definition: bot, entries: entries, unreadIDs: [],
                                   nextRun: bot.paused ? nil : dates[bot.id], missed: missed[bot.id], lastEvent: events[bot.id])
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
        do {
            let session = try await Self.chatSession(for: record.definition, root: root)
            await appModel.selectChatSession(session)
            if appModel.activeChatSessionId == session.id {
                if !appModel.chatSessions.contains(where: { $0.id == session.id }) { appModel.chatSessions.append(session) }
                onContinue(destination)
            }
        } catch { notice = error.localizedDescription }
    }

    static func continueDestination(for record: BotsShelfRecord) -> NativeAgentNavigationDestination {
        record.sortedEntries.first?.runtimeStatus == .waitingForApproval
            ? .activity(.approvals) : .sidebar(.chat)
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
    @State private var replyOpen = false

    /// The headline the run recorded, not the reply read again on every render.
    /// `make` over that one short line costs nothing and cleans a legacy
    /// headline stored before the prose rule existed.
    private var headline: String {
        if !entry.headline.isEmpty { return BotHeadline.make(from: entry.headline) }
        if !entry.actualReply.isEmpty { return BotHeadline.make(from: entry.actualReply) }
        // Nothing was said. The recorded cause is the only honest line left.
        if let detail = entry.statusDetail, !detail.isEmpty { return detail }
        return entry.runHealth == .nothingNew ? "Checked, nothing new" : "Nothing saved"
    }
    /// One word for how the run ended, never a verdict on the task.
    private var outcome: String {
        switch entry.runtimeStatus {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .interrupted: return "Stopped"
        case .waitingForApproval: return "Blocked"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(BotState.color(forStatus: entry.runtimeStatus)).frame(width: 7, height: 7)
                Text(outcome).font(ShellType.captionMedium).foregroundStyle(NativeAgentShell.text)
                Text("·").foregroundStyle(NativeAgentShell.tertiary)
                Text(BotsShelfRecord.shortDate(entry.runAt)).font(ShellType.caption).foregroundStyle(NativeAgentShell.text)
                if let duration {
                    Text("·").foregroundStyle(NativeAgentShell.tertiary)
                    Text(duration).font(ShellType.caption).foregroundStyle(NativeAgentShell.text)
                }
                Spacer(minLength: 8)
                Text(model).font(ShellType.caption).foregroundStyle(NativeAgentShell.text).lineLimit(1)
            }
            Text(headline).font(ShellType.bodyMedium).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let cause {
                Text(cause).font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                BotsShelfArtifactLink(artifact: artifact)
            }.foregroundStyle(.blue)
            if !entry.actualReply.isEmpty {
                Button(replyOpen ? "Hide the reply" : "Open the reply") { replyOpen.toggle() }
                    .buttonStyle(.link).font(ShellType.label)
                // Nothing reads the reply itself until the person opens it.
                if replyOpen {
                    let reply = entry.actualReply.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let attributed = ChatMarkdownCache.attributed(reply) {
                        Text(attributed).font(ShellType.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(reply).font(ShellType.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16).botCardSurface()
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
        case .failed: word = "Failed"
        case .interrupted: word = "Interrupted"
        default: word = "Ready"
        }
        color = Self.color(forStatus: latest.runtimeStatus)
    }

    static func color(forStatus status: BotRunStatus) -> Color {
        switch status {
        case .waitingForApproval: NativeAgentShell.needsYou
        case .failed, .interrupted: NativeAgentShell.trouble
        default: NativeAgentShell.calm
        }
    }
}

/// The little bot itself: a rounded tile with one light that breathes while it works.
struct BotMark: View {
    let state: BotState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .overlay {
                Circle().fill(state.color)
                    .frame(width: 8, height: 8)
                    .scaleEffect(state.running && breathing ? 1.35 : 1)
                    .opacity(state.running && breathing ? 0.55 : 1)
                    .shadow(color: state.color.opacity(state.running ? 0.6 : 0), radius: 4)
            }
            .frame(width: 30, height: 30)
            .onAppear {
                guard state.running, !reduceMotion else { return }
                withAnimation(NativeAgentMotion.pulse) { breathing = true }
            }
            .accessibilityLabel(state.word)
    }
}

struct BotCard: View {
    let record: BotsShelfRecord
    let state: BotState
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BotMark(state: state).padding(.top, 1)
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
    var body: some View {
        if enabled { BotsShelfView(onContinue: onContinue) }
        else { ShellRailPage(title: "Bots") { Text("Bots preview is turned off.") } }
    }
}
