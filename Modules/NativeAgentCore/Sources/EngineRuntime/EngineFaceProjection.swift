import AuthoredCapabilities
import ChatSessionWork
import ChatTurnRuntime
import DreamREMCycle
import Foundation
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
import Privacy
import StandingBots
import TurnTrace
// Blueprint: | `EngineFaceProjection.swift` | Body owner observations assemble finished Shared presentations off main, without consulting face slots |

enum EngineFaceProjection {
    @concurrent static func prepareCapture(_ key: FaceKey, engine: NativeAgentEngine) async throws {
        switch key {
        case .knowledgeGraph:
            let read = await MainActor.run { (engine.memory.graphSnapshot, engine.memory.graphLoadError) }
            if let issue = read.1 { throw EngineFaceActs.failure("graph_unavailable", issue) }
            guard let snapshot = read.0 else { throw EngineFaceActs.failure("graph_unavailable", "The graph owner supplied no checked snapshot.") }
            await engine.face.post(graphFace(snapshot, state: .ready), at: key)
        case .dreamDiary:
            let diary = try await engine.cognitionView.dreamDiary(limit: 60)
            await engine.face.post(diaryFace(diary, issue: nil), at: key)
        case .contacts:
            try await engine.contactThreads.prepareContactsForCapture()
            let input = await MainActor.run {
                (engine.contactThreads.contacts, engine.contactThreads.loaded, engine.contactThreads.contactRefreshError)
            }
            await engine.face.post(contactsFace(input.0, loaded: input.1, issue: input.2), at: key)
        case .helpers:
            guard await engine.contactThreads.refreshHelpers() else {
                throw WireFailure(code: "helpers_unavailable", message: "The Helpers owner did not confirm a catalog reading.",
                    cause: await engine.contactThreads.helpersRefreshError, effects: .none)
            }
            let input = await MainActor.run {
                (engine.contactThreads.helpers, engine.contactThreads.helpersLoaded, engine.contactThreads.helpersRefreshError)
            }
            await engine.face.post(helpersFace(input.0, loaded: input.1, issue: input.2), at: key)
        default:
            throw EngineFaceActs.failure("capture_key_unavailable", "This owner does not prepare that native capture value.")
        }
    }

    @concurrent static func layout(_ engine: NativeAgentEngine) async {
        let availability = await engine.layout.availability
        await engine.face.post(LayoutFace(availability: availability), at: .layout)
    }

    static func owns(_ demand: FaceDemand) -> Bool {
        switch demand {
        case .dreamDiary, .deskPalette, .graphNeighborhood, .agentScreen, .sessionSearch: return true
        case .key(let key):
            switch key {
            case .layout, .knowledgeGraph, .dreamDiary, .dreamEntry, .mood, .runs, .run, .contacts, .helpers, .contactThread, .helperRuns,
                 .memoryDiagnostics, .cognition, .contextFlowHealth, .deskDiagnostics, .workDetail, .makeShelf, .makePreview, .senseView,
                 .inspector, .inspectorReplay, .graphNeighborhood, .contextReceipt, .macControl:
                return true
            default: return false
            }
        default: return false
        }
    }

    @concurrent static func observe(_ demand: FaceDemand, engine: NativeAgentEngine) async {
        if case .sessionSearch(let view, let query) = demand {
            await engine.transcripts.observeSessionSearch(query, viewID: view)
            return
        }
        if case .agentScreen(let room, let scope) = demand {
            await agentScreen(room, scope: scope, engine: engine)
            return
        }
        if case .deskPalette(let view, let query) = demand {
            await EngineFaceWorkProjection.deskPalette(view, query: query, engine: engine)
            return
        }
        guard case .key(let key) = demand else { return }
        await waiting(key, engine: engine)
        switch key {
        case .macControl:
            await EngineFaceMacControlProjection.observe(engine: engine)
        case .contextReceipt(let session):
            await EngineFaceContextProjection.observe(session, engine: engine)
        case .inspector, .inspectorReplay:
            await inspector(key, engine: engine)
        case .contactThread, .helperRuns:
            await EngineFaceThreadProjection.observe(key, engine: engine)
        case .deskDiagnostics, .workDetail, .makeShelf, .makePreview, .senseView:
            await EngineFaceWorkProjection.observe(key, engine: engine)
        case .memoryDiagnostics, .cognition, .contextFlowHealth:
            await EngineFaceMindProjection.observe(key, engine: engine)
        case .layout:
            await watch(read: { engine.layout.availability }) { availability in
                await engine.face.post(LayoutFace(availability: availability), at: .layout)
            }
        case .knowledgeGraph, .graphNeighborhood:
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await engine.memory.watchGraphChanges() }
                await watch(read: { (engine.memory.graphSnapshot, engine.memory.graphLoadError, engine.memory.graphObservationError) }) { input in
                    let state = readState(issue: input.1 ?? input.2, ready: input.0 != nil, owner: "knowledge graph")
                    if case .graphNeighborhood(let id) = key {
                        let detail = input.0?.neighborhood(entityID: id)
                        let state = state == .ready && detail == nil
                            ? .unavailable(EngineFaceActs.failure("graph_entity_missing", "That entity is absent from the checked graph.")) : state
                        await engine.face.post(FaceGraphNeighborhood(entity: id,
                            entities: detail.map { $0.neighbors.values.sorted { $0.id < $1.id }.map(entity) } ?? [],
                            edges: detail?.edges.map(edge) ?? [], state: state), at: key)
                    } else {
                        await engine.face.post(graphFace(input.0, state: state), at: key)
                    }
                }
                group.cancelAll()
            }
        case .dreamDiary:
            await engine.cognitionView.refreshDiary()
            await watch(read: { (engine.cognitionView.diary, engine.cognitionView.diaryError) }) { input in
                await engine.face.post(diaryFace(input.0, issue: input.1), at: key)
            }
        case .dreamEntry(let date):
            await watchFiles([engine.dataRoot.appendingPathComponent("dream_diary")], refresh: { await entry(date, engine: engine) },
                unavailable: { await unavailable(key, cause: $0, engine: engine) })
        case .mood:
            guard let runtime = engine.cognition else {
                let state = FaceReadState.unavailable(EngineFaceActs.failure("body_unavailable", "This root has no mind."))
                await engine.face.post(MoodFace(warmth: nil, state: state), at: key)
                return
            }
            let changes = await runtime.changes()
            await engine.face.post(MoodFace(warmth: await runtime.moodWarmth(), state: .ready), at: key)
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await engine.face.post(MoodFace(warmth: await runtime.moodWarmth(), state: .ready), at: key)
            }
        case .runs:
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await watchFiles([engine.dataRoot.appendingPathComponent("runs/runs.json")], refresh: {
                        await engine.runs.setObservationIssue(nil)
                        do { _ = try await engine.runs.refresh(dataRoot: engine.dataRoot) }
                        catch { /* The owner publishes the failed reading. */ }
                    }, unavailable: { await engine.runs.setObservationIssue($0) })
                }
                await watch(read: { (engine.runs.rows, engine.runs.readSucceeded, engine.runs.readIssue, engine.runs.observationIssue) }) { input in
                    let state = readState(issue: input.2 ?? input.3, ready: input.1 == true, owner: "run history")
                    let rows = input.0.map { row($0.id, title: $0.kind, detail: $0.error.map(NativeAppSecretRedactor.redactText), state: $0.status) }
                    await engine.face.post(RunsFace(ids: input.0.map(\.id), rows: rows, state: state), at: key)
                }
                group.cancelAll()
            }
        case .run:
            await watchFiles([engine.dataRoot.appendingPathComponent("runs/runs.json")], refresh: { await runs(key, engine: engine) },
                unavailable: { await unavailable(key, cause: $0, engine: engine) })
        case .contacts:
            await engine.contactThreads.start()
            await watch(read: { (engine.contactThreads.contacts, engine.contactThreads.loaded, engine.contactThreads.contactRefreshError) }) { input in
                await engine.face.post(contactsFace(input.0, loaded: input.1, issue: input.2), at: key)
            }
        case .helpers:
            _ = await engine.contactThreads.refreshHelpers()
            await watch(read: { (engine.contactThreads.helpers, engine.contactThreads.helpersLoaded, engine.contactThreads.helpersRefreshError) }) { input in
                await engine.face.post(helpersFace(input.0, loaded: input.1, issue: input.2), at: key)
            }
        default: return
        }
    }

    @concurrent private static func agentScreen(_ room: String, scope: String?, engine: NativeAgentEngine) async {
        let key = FaceKey.agentScreen(room: room, scope: scope)
        await engine.face.post(AgentScreenFace(room: room, scope: scope, text: nil, state: .waiting(on: "my room")), at: key)
        let paths = AgentScreenPreview.watchedPaths.map { engine.dataRoot.appendingPathComponent($0) }
        let events = FileChangeEvents(paths: paths, emitInitial: false)
        let (signals, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let notifications = ObservationNotifications(names: [AgentScreenPreview.didChange, AbilityStore.didChange]) { wake.yield(()) }
        defer { notifications.cancel(); wake.finish() }
        await withTaskCancellationHandler {
            guard await events.waitUntilArmed(), !Task.isCancelled else {
                if !Task.isCancelled { await agentScreenUnavailable(room, scope: scope, engine: engine) }
                return
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in events.stream { wake.yield(()) }
                    if !Task.isCancelled { wake.yield(()) }
                }
                wake.yield(())
                for await _ in signals {
                    guard !Task.isCancelled else { break }
                    guard events.isArmed else { await agentScreenUnavailable(room, scope: scope, engine: engine); break }
                    let text = await engine.turns.readAgentScreen(room: room, scope: scope ?? "")
                    guard !Task.isCancelled else { break }
                    await engine.face.post(AgentScreenFace(room: room, scope: scope,
                        text: NativeAppSecretRedactor.redactText(text), state: .ready), at: key)
                }
                group.cancelAll()
            }
        } onCancel: { events.cancel(); wake.finish() }
        events.cancel()
    }

    @concurrent private static func agentScreenUnavailable(_ room: String, scope: String?, engine: NativeAgentEngine) async {
        await engine.face.post(AgentScreenFace(room: room, scope: scope, text: nil,
            state: .unavailable(EngineFaceActs.failure("agent_screen_observation_unavailable",
                "My room changes could not be observed. Reopen this room."))), at: .agentScreen(room: room, scope: scope))
    }

    @concurrent private static func inspector(_ key: FaceKey, engine: NativeAgentEngine) async {
        let reader = UUID()
        let (lifetime, held) = AsyncStream<Void>.makeStream()
        defer { held.finish() }
        switch key {
        case .inspector(let after): await engine.trace.showLive(reader: reader, after: after)
        case .inspectorReplay(let day): await engine.trace.showReplay(for: day, reader: reader)
        default: return
        }
        for await _ in lifetime { }
        await engine.trace.removeReader(reader)
    }

    @concurrent private static func runs(_ key: FaceKey, engine: NativeAgentEngine) async {
        if case .run(let id) = key {
            let record: RunRecord?
            let state: FaceReadState
            do {
                record = try await EngineFaceActs.readRunRecord(id, root: engine.dataRoot)
                state = .ready
            } catch let failure as WireFailure { record = nil; state = .unavailable(failure) }
            catch { record = nil; state = .unavailable(WireFailure(code: "run_unavailable", message: "The run could not be read.",
                cause: error.localizedDescription, effects: .none)) }
            guard !Task.isCancelled else { return }
            await engine.face.post(RunFace(id: id, record: record, rows: [], status: record?.status, state: state), at: key)
        }
    }

    @concurrent private static func waiting(_ key: FaceKey, engine: NativeAgentEngine) async {
        let state = FaceReadState.waiting(on: "body owner")
        switch key {
        case .knowledgeGraph:
            await engine.face.post(KnowledgeGraphFace(entities: [], edges: [], totalEntities: nil, totalEdges: nil, state: state), at: key)
        case .graphNeighborhood(let entity):
            await engine.face.post(FaceGraphNeighborhood(entity: entity, entities: [], edges: [], state: state), at: key)
        case .dreamDiary:
            await engine.face.post(DreamDiaryFace(entries: [], total: nil, unreadableCount: nil, gate: nil, state: state), at: key)
        case .dreamEntry(let date):
            await engine.face.post(DreamEntryFace(entry: .init(date: date, title: date, text: nil, state: state)), at: key)
        case .mood: await engine.face.post(MoodFace(warmth: nil, state: state), at: key)
        case .runs: await engine.face.post(RunsFace(ids: [], rows: [], state: state), at: key)
        case .run(let id): await engine.face.post(RunFace(id: id, record: nil, rows: [], status: nil, state: state), at: key)
        case .contacts: await engine.face.post(ContactsFace(contacts: [], state: state), at: key)
        case .helpers: await engine.face.post(HelpersFace(rows: [], runningIDs: [], waitingIDs: [], needsYouIDs: [], state: state), at: key)
        default: break
        }
    }

    @concurrent static func watchFiles(_ paths: [URL], refresh: @escaping @Sendable () async -> Void,
        unavailable: @escaping @Sendable (String) async -> Void) async {
        let events = FileChangeEvents(paths: paths, emitInitial: true)
        await withTaskCancellationHandler {
            let armed = await events.waitUntilArmed()
            guard !Task.isCancelled else { return }
            guard armed else {
                await unavailable("The file source could not observe " + paths.map(\.path).joined(separator: ", ") + ". Reopen this presentation.")
                return
            }
            for await _ in events.stream {
                guard !Task.isCancelled else { break }
                await refresh()
            }
            if !Task.isCancelled {
                await unavailable("File observation closed for " + paths.map(\.path).joined(separator: ", ") + ". Reopen this presentation.")
            }
        } onCancel: { events.cancel() }
        events.cancel()
    }

    @concurrent private static func unavailable(_ key: FaceKey, cause: String, engine: NativeAgentEngine) async {
        let state = FaceReadState.unavailable(EngineFaceActs.failure("file_observation_unavailable", cause))
        switch key {
        case .runs: await engine.face.post(RunsFace(ids: [], rows: [], state: state), at: key)
        case .run(let id): await engine.face.post(RunFace(id: id, record: nil, rows: [], status: nil, state: state), at: key)
        case .dreamEntry(let date):
            await engine.face.post(DreamEntryFace(entry: .init(date: date, title: date, text: nil, state: state)), at: key)
        default: break
        }
    }

    /// Subscribe before copying each snapshot so a change during publication remains pending for the next read.
    @concurrent static func watch<Input: Sendable>(read: @escaping @MainActor @Sendable () -> Input,
        publish: @escaping @Sendable (Input) async -> Void) async {
        let (events, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        var changes = events.makeAsyncIterator()
        while !Task.isCancelled {
            let input = await MainActor.run { withObservationTracking(read, onChange: { continuation.yield() }) }
            guard !Task.isCancelled else { return }
            await publish(input)
            guard await changes.next() != nil else { return }
        }
    }

    @concurrent static func document(_ request: DocumentRequest, engine: NativeAgentEngine,
                                     surface: String? = nil, publish: Bool = true, readUsing: PartFaces.DemandRead? = nil) async throws -> FaceActReply {
        let text: String
        let title: String
        var reply: PartFace.Value?
        do {
            if let read = request.pageRead {
                guard case .pageItem(let page, let item) = request.subject, read.id == request.id, read.key == item else {
                    throw EngineFaceActs.failure("invalid_page_read", "The page read must name its own item and request identity.")
                }
                let pages = surface == "ios" && page == "memories" ? engine.phoneMemoryPages : engine.pages
                if request.release == true {
                    await pages.releaseItem(page: page, item: read.scope, request: read.id)
                    return .result(.null)
                }
                let face = try await pages.presentation(page: page, item: item, request: read, readUsing: readUsing)
                try Task.checkCancellation()
                return .result(try JSONDecoder().decode(PartFace.Value.self, from: JSONEncoder().encode(face)))
            }
            switch request.subject {
            case .pageItem(let page, let item):
                if page == "memories", let target = MemoriesFaceTarget(row: item) {
                    let subject: DocumentSubject
                    switch target {
                    case .memory(let id): subject = .memory(id: id, rejected: false)
                    case .rejected(let id): subject = .memory(id: id, rejected: true)
                    case .graph, .upkeep:
                        throw EngineFaceActs.failure("not_a_document", "This memory destination is an interactive page, not a document.")
                    }
                    text = try await engine.readDocument(subject: subject, surface: surface, readUsing: readUsing)
                } else {
                    let pages = surface == "ios" && page == "memories" ? engine.phoneMemoryPages : engine.pages
                    text = try await pages.body(page: page, item: item, expecting: request.expectedCall, readUsing: readUsing)
                }
                title = item
            case .run(let id):
                text = RunDocument.text(try await EngineFaceActs.readRunRecord(id, root: engine.dataRoot)); title = "Run detail"
            case .context(let session):
                guard surface != "ios" else {
                    throw EngineFaceActs.failure("other_door", "The context receipt's disclosure opens on the Mac.")
                }
                switch ContextFedRecord.load(sessionId: session, dataRoot: engine.dataRoot) {
                case .loaded(let record):
                    text = record.fed + (record.brief.isEmpty ? "" : "\n\n— Turn brief —\n" + record.brief)
                case .missing:
                    throw EngineFaceActs.failure("context_record_missing", "No saved context record exists for this conversation.")
                case .unavailable(let cause):
                    throw EngineFaceActs.failure("context_record_unavailable", cause)
                }
                title = "What I was given"
            case .dream(let date):
                let entry = try await engine.cognitionView.dreamEntry(date: date)
                guard let content = entry.content else { throw EngineFaceActs.failure("dream_content_unavailable", "The dream entry contains no text.") }
                text = content; title = date
            case .message(let session, let id):
                let message: ChatMessage
                if session.hasPrefix("contact:") {
                    message = try await engine.contactThreadMessage(String(session.dropFirst(8)), id: id)
                } else {
                    let messages = try await engine.transcripts.loadMessages(sessionId: session, cached: false)
                    guard let found = messages.first(where: { $0.id == id }) else {
                        throw EngineFaceActs.failure("message_not_found", "That message is absent from the checked transcript.")
                    }
                    message = found
                }
                let safe = NativeAppSecretRedactor.redactArguments(try JSONValue.fromEncodable(message))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                guard let json = String(data: try encoder.encode(safe), encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                text = json; title = "Message data"
            case .memory(let id, let rejected):
                if rejected {
                    let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: engine.dataRoot)
                    guard let proposal = try await storage.getProposal(id: id), proposal.status == "rejected" else {
                        throw EngineFaceActs.failure("rejected_memory_not_found", "That rejected proposal is absent from the checked memory store.")
                    }
                    try requireDisclosure(proposal, surface: surface)
                    text = proposal.content; title = "Rejected memory"
                } else {
                    let memories = try await engine.memory.activeMemories(ids: [id])
                    guard let memory = memories.first(where: { $0.id == id }) else {
                        throw EngineFaceActs.failure("memory_not_found", "That memory is absent from the checked memory store.")
                    }
                    if let surface, MemoryRecordDisclosurePolicy.classify(memory)?.permits(surface: surface, personaID: nil) != true {
                        throw EngineFaceActs.failure("memory_not_disclosed", "This memory is not disclosed to this door.")
                    }
                    text = memory.text; title = "Memory"
                }
            case .proposal(let id):
                let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: engine.dataRoot)
                guard let proposal = try await storage.getProposal(id: id) else {
                    throw EngineFaceActs.failure("proposal_not_found", "That proposal is absent from the checked memory store.")
                }
                try requireDisclosure(proposal, surface: surface)
                text = proposal.content; title = "Memory proposal"
            case .helperEntry(let raw):
                guard let id = UUID(uuidString: raw) else {
                    throw EngineFaceActs.failure("helper_entry_invalid", "Choose a saved helper result.")
                }
                let entry = try ShelfStore(dataRoot: engine.dataRoot).entry(id)
                text = entry.actualReply
                title = entry.headline
                reply = .object(["entry_id": .string(entry.id.uuidString), "bot_id": .string(entry.botId.uuidString),
                    "session_id": entry.sessionID.map(PartFace.Value.string) ?? .null])
            }
            try Task.checkCancellation()
            if publish { await engine.face.post(DocumentFace(id: request.id, subject: request.subject, title: NativeAppSecretRedactor.redactText(title),
                text: NativeAppSecretRedactor.redactText(text), revision: nil, state: .ready),
                at: .document(request.id)) }
            if request.presentation == true {
                let safe = NativeAppSecretRedactor.redactText(text)
                let face = try await engine.documentFace(title: NativeAppSecretRedactor.redactText(title), text: safe,
                                                        format: request.subject.documentFormat)
                return .result(.object(["text": .string(safe), "face": try JSONDecoder().decode(PartFace.Value.self,
                    from: JSONEncoder().encode(face))]))
            }
            if request.textOnly == true { return .result(.string(NativeAppSecretRedactor.redactText(text))) }
            return .result(reply ?? .string(NativeAppSecretRedactor.redactText(text)))
        } catch {
            let failure = WireFailure(code: "document_unavailable", message: "The document could not be read.",
                cause: NativeAppSecretRedactor.redactText(error.localizedDescription), effects: .none)
            if publish, !Task.isCancelled {
                await engine.face.post(DocumentFace(id: request.id, subject: request.subject, title: nil, text: nil, revision: nil,
                    state: .unavailable(failure)), at: .document(request.id))
            }
            if error is CancellationError { throw CancellationError() }
            throw failure
        }
    }

    private static func requireDisclosure(_ proposal: StoredProposal, surface: String?) throws {
        guard let surface else { return }
        guard MemoryRecordDisclosurePolicy.classify(personaID: proposal.personaId, status: "active", lifecycle: nil,
            tags: nil, metadata: proposal.metadata)?.permits(surface: surface, personaID: nil) == true else {
            throw EngineFaceActs.failure("memory_not_disclosed", "This proposal is not disclosed to this door.")
        }
    }

    @concurrent private static func entry(_ date: String, engine: NativeAgentEngine) async {
        let value: FaceDreamEntry
        do { value = dream(try await engine.cognitionView.dreamEntry(date: date)) }
        catch { value = FaceDreamEntry(date: date, title: date, text: nil,
            state: .unavailable(WireFailure(code: "dream_unavailable", message: "The dream entry could not be read.",
                cause: error.localizedDescription, effects: .none))) }
        guard !Task.isCancelled else { return }
        await engine.face.post(DreamEntryFace(entry: value), at: .dreamEntry(date: date))
    }

    private static func readState(issue: String?, ready: Bool, owner: String) -> FaceReadState {
        if let issue { return .unavailable(EngineFaceActs.failure("owner_read_unavailable", NativeAppSecretRedactor.redactText(issue))) }
        return ready ? .ready : .waiting(on: owner)
    }
    private static func graphFace(_ snapshot: CanonicalAgentGraphReadout?, state: FaceReadState) -> KnowledgeGraphFace {
        KnowledgeGraphFace(entities: snapshot?.canvasEntities.map(entity) ?? [], edges: snapshot?.canvasEdges.map(edge) ?? [],
            totalEntities: snapshot.map { $0.canvasEntities.count }, totalEdges: snapshot.map { $0.canvasEdges.count }, state: state)
    }
    private static func diaryFace(_ diary: DreamDiary?, issue: String?) -> DreamDiaryFace {
        DreamDiaryFace(entries: diary?.entries.map(dream) ?? [], total: diary?.totalEntries,
            unreadableCount: diary?.unreadableEntries, gate: diary.map { $0.enabled ? "enabled" : "disabled" },
            state: readState(issue: issue, ready: diary != nil, owner: "dream diary"))
    }
    private static func contactsFace(_ contacts: [AgentContactPresentation], loaded: Bool, issue: String?) -> ContactsFace {
        ContactsFace(contacts: contacts.map { FaceContact(id: $0.id, label: $0.name, portrait: nil, appBundleID: $0.appBundleID,
            state: $0.sendRestriction.map { .unavailable(EngineFaceActs.failure("contact_restricted", $0)) } ?? .ready, needsYou: $0.needsYou) },
            state: readState(issue: issue, ready: loaded, owner: "contacts"))
    }
    private static func helpersFace(_ helpers: [BotsShelfRecord], loaded: Bool, issue: String?) -> HelpersFace {
        let rows = helpers.map { row($0.id.uuidString, title: $0.definition.name, detail: $0.modelChoiceIssue ?? $0.runReadIssue,
            state: $0.status.rawValue) }
        return HelpersFace(rows: rows, runningIDs: helpers.filter(\.running).map { $0.id.uuidString },
            waitingIDs: helpers.filter(\.queued).map { $0.id.uuidString }, needsYouIDs: helpers.filter(\.needsYou).map { $0.id.uuidString },
            state: readState(issue: issue, ready: loaded, owner: "helpers"))
    }
    private static func entity(_ value: KnowledgeGraphEntity) -> FaceGraphEntity {
        FaceGraphEntity(id: value.id, name: NativeAppSecretRedactor.redactText(value.name), kind: value.type,
            detail: value.summary.map(NativeAppSecretRedactor.redactText), weight: nil, lastSeen: value.lastSeenDate)
    }
    private static func edge(_ value: KnowledgeGraphEdge) -> FaceGraphEdge {
        FaceGraphEdge(from: value.from, to: value.to, kind: NativeAppSecretRedactor.redactText(value.kind), weight: value.weight)
    }
    private static func dream(_ entry: DreamEntry) -> FaceDreamEntry {
        FaceDreamEntry(date: entry.date, title: entry.date, text: entry.content,
            state: entry.content == nil ? .waiting(on: "dream entry text") : .ready)
    }
    private static func row(_ id: String, title: String, detail: String?, state: String?) -> PartFace.Row {
        PartFace.Row(id: id, title: title, detail: detail, value: state, actions: [])
    }
}
