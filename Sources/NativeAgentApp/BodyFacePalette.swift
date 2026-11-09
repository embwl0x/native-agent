import ActivityWatch
import AppToolRuntime
import ChatSessionWork
import EngineRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
import Privacy
// Blueprint: | `BodyFacePalette.swift` | Connection-owned global search using the canonical inventory, ranking and saved-result owners |

@MainActor
final class BodyFacePalette {
    private weak var model: AppModel?
    private let engine: NativeAgentEngine
    private var readers: [UUID: (view: UUID, task: Task<Void, Never>)] = [:]
    private var closing = false
    init(model: AppModel) { self.model = model; engine = model.engine }

    func handle(_ act: FaceAct) async throws -> FaceActReply? {
        switch act {
        case .observe(let id, .palette(let view, let query)):
            guard !closing, readers[id] == nil, !readers.values.contains(where: { $0.view == view }) else {
                throw BodyFaceServices.failure("palette_observation_exists", "Release this search before opening another query for it.")
            }
            try Task.checkCancellation()
            readers[id] = (view, Task { await self.observe(view, query: query) })
            return .observation(id: id)
        case .unobserve(let id) where readers[id] != nil:
            guard let reader = readers[id] else { return nil }
            reader.task.cancel()
            await reader.task.value
            if readers[id]?.task == reader.task { readers.removeValue(forKey: id) }
            return .acknowledged
        default: return nil
        }
    }

    func close() async {
        closing = true
        let held = readers
        for reader in held.values { reader.task.cancel() }
        for reader in held.values { await reader.task.value }
        readers.removeAll()
        closing = false
    }

    private func observe(_ view: UUID, query: String) async {
        await post(view, query: query, state: .waiting(on: "search sources"))
        let paths = ["chat/sessions.json", "desk/desk_ops.jsonl", "desk/desk_ops_base.json", "dream_diary",
            "memory/memory.sqlite", "memory/memory.sqlite-wal", "bots/definitions", "bots/shelf-index.json",
            "clock/times.json", "bots/missed-runs.json", "bots/last-events.json", "trust/policy.json", "agents/peers.json"]
            .map { engine.dataRoot.appendingPathComponent($0) }
        let changes = FileChangeEvents(paths: paths, emitInitial: false)
        let (events, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let root = engine.dataRoot
        let token = NotificationCenter.default.addObserver(forName: TranscriptsFacade.sessionIndexDidChange, object: nil, queue: nil) { notice in
            if notice.object as? URL == root { wake.yield(()) }
        }
        defer { NotificationCenter.default.removeObserver(token); wake.finish() }
        await withTaskCancellationHandler {
            guard await changes.waitUntilArmed(), !Task.isCancelled else {
                if !Task.isCancelled { await unavailable(view, query: query) }
                return
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in changes.stream { wake.yield(()) }
                    if !Task.isCancelled { wake.yield(()) }
                }
                group.addTask { await self.observeLayout(wake) }
                wake.yield(())
                for await _ in events {
                    guard !Task.isCancelled else { break }
                    guard await Self.isArmed(changes) else { await unavailable(view, query: query); break }
                    await refresh(view, query: query)
                }
                group.cancelAll()
            }
        } onCancel: { changes.cancel(); wake.finish() }
        changes.cancel()
    }

    private func observeLayout(_ wake: AsyncStream<Void>.Continuation) async {
        let (observed, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changed.finish() }
        var next = observed.makeAsyncIterator()
        while !Task.isCancelled {
            withObservationTracking {
                _ = engine.layout.availability
                _ = engine.activityWatch.removableExclusions
            } onChange: { changed.yield(()) }
            wake.yield(())
            guard await next.next() != nil else { break }
        }
    }

    private func refresh(_ view: UUID, query: String) async {
        guard let model else {
            await post(view, query: query, state: .unavailable(Self.failure("The settings presentation owner closed.", cause: "Reopen the window.")))
            return
        }
        var failures: [String: WireFailure] = [:]
        var settings: [PaletteItem] = []
        do {
            settings = try await QuietSettings.navigation(host: AppQuietSettingsHost(model)).map { row in
                PaletteItem(id: "setting." + row.id, title: row.label, subtitle: QuietPages.page(named: row.page)?.title ?? row.page,
                    systemImage: "slider.horizontal.3", kind: .setting(row.page, tab: row.tab))
            }
        } catch { failures["settings"] = Self.failure("Settings could not be searched.", cause: error.localizedDescription) }
        _ = await engine.desk.loadBoard()
        await engine.cognitionView.refreshDiary()
        await engine.transcripts.refreshSavedSearch(bots: engine.bots, memory: engine.memory)
        if let issue = engine.desk.board.deskError { failures["desk"] = Self.failure("Desk could not be searched.", cause: issue) }
        if let issue = engine.cognitionView.diaryError { failures["dreams"] = Self.failure("Dreams could not be searched.", cause: issue) }
        if let issue = engine.transcripts.savedSearchError { failures["saved"] = Self.failure("Saved results may be out of date.", cause: issue) }
        let layout = engine.layout.availability
        if let issue = layout.failure { failures["layout"] = Self.failure("The page layout could not be read.", cause: issue.localizedDescription) }
        var sessions: [NativeAgentShared.ChatSession] = []
        var hits: [PaletteItem] = []
        do {
            let unread = try await engine.transcripts.refreshPaletteMessageIndexFailures()
            for (id, cause) in unread { failures["conversation." + id] = Self.failure("A saved conversation could not be searched.", cause: cause) }
            sessions = engine.transcripts.sessions
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= 3 {
                hits = await engine.transcripts.messageIndex.search(text).map {
                    PaletteItem(id: "message." + $0.sessionID, title: "", subtitle: $0.snippet,
                        systemImage: "text.bubble", kind: .chatSession($0.sessionID))
                }
            }
        } catch { failures["conversations"] = Self.failure("Saved conversations could not be searched.", cause: error.localizedDescription) }
        let pool = CommandPalettePresentation.itemPool(layout: layout, settings: settings, saved: CommandPaletteSavedThings.shared(engine: engine))
        let rail = CommandPalettePresentation.railItems(layout)
        let inputSessions = sessions
        let confirmed = hits
        let items = await Task.detached(priority: .userInitiated) {
            CommandPalettePresentation.filteredItems(pool: pool, query: query, confirmed: confirmed, rail: rail,
                sessions: ConversationPaletteRanking.matches(inputSessions, query: query))
        }.value
        guard !Task.isCancelled else { return }
        var rows: [PartFace.Row] = []
        var targets: [String: FacePaletteTarget] = [:]
        for item in items {
            let target: FacePaletteTarget
            do { target = try Self.target(item) }
            catch {
                failures[item.id] = Self.failure("This search result has no supported destination.", cause: error.localizedDescription)
                continue
            }
            let title: String
            if case .chatSession(let id) = item.kind {
                guard let session = sessions.first(where: { $0.id == id }) else {
                    failures[item.id] = Self.failure("A search result lost its conversation identity.", cause: "Reopen search against the current index.")
                    continue
                }
                title = ChatShellConversationRow.faceTitle(session.displayTitle)
            } else { title = item.title }
            targets[item.id] = target
            rows.append(.init(id: item.id, title: NativeAppSecretRedactor.redactText(title),
                detail: item.subtitle.map(NativeAppSecretRedactor.redactText), value: Self.label(target), actions: []))
        }
        await engine.face.post(PaletteFace(view: view, query: query, ranks: [rows], targets: targets, sourceFailures: failures, state: .ready),
            at: .palette(view))
    }

    private static func target(_ item: PaletteItem) throws -> FacePaletteTarget {
        switch item.kind {
        case .tab(let page): return .page(page.rawValue)
        case .railTab(let page, let tab): return .tab(page: page.rawValue, tab: tab)
        case .setting(let page, let tab): return .setting(page: page, tab: tab)
        case .chatSession(let session): return .conversation(session)
        case .deskItem(let handle): return .desk(handle)
        case .saved(.memory(let id)): return .memory(id)
        case .saved(.dream(let date)): return .dream(date)
        case .saved(.botReply(let bot, let entry)): return .helperResult(bot: bot, entry: entry)
        case .recentAction(let id):
            switch CommandPaletteRecentAction(rawValue: id) {
            case .newChat: return .newConversation
            case .refreshActivity: return .refresh(.panel(SidebarItem.activity.rawValue))
            case .reloadAll: return .refresh(.all)
            case nil: throw BodyFaceServices.failure("palette_action_unknown", "The inventory supplied an unknown action: " + id)
            }
        }
    }

    private static func label(_ target: FacePaletteTarget) -> String {
        switch target {
        case .page: "Page"
        case .tab: "Tab"
        case .setting: "Setting"
        case .conversation: "Chat"
        case .newConversation, .refresh: "Action"
        case .desk: "Desk"
        case .memory: "Memory"
        case .dream: "Dream"
        case .helperResult: "Helper"
        }
    }

    private func unavailable(_ view: UUID, query: String) async {
        await post(view, query: query, state: .unavailable(Self.failure("Search changes could not be observed.", cause: "Reopen search.")))
    }

    private func post(_ view: UUID, query: String, state: FaceReadState) async {
        guard !Task.isCancelled else { return }
        await engine.face.post(PaletteFace(view: view, query: query, ranks: [], targets: [:], sourceFailures: [:], state: state), at: .palette(view))
    }

    private static func failure(_ message: String, cause: String) -> WireFailure {
        .init(code: "palette_source_unavailable", message: message, cause: NativeAppSecretRedactor.redactText(cause), effects: .none)
    }

    @concurrent private static func isArmed(_ events: FileChangeEvents) async -> Bool { events.isArmed }
}
