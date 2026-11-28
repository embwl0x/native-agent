import SenseCore
import MindCore
import Foundation
import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import ProviderRouting
// Blueprint: | `EngineFaceActs.swift` | Body act dispatch, renderer-call attachment and connection-owned observation lifetimes |

/// App services install their body adapter; the engine never retains a window or its model.
public actor EngineFaceActs: FaceActHandler {
    let engine: NativeAgentEngine
    let chat: BodyChatCommands
    private var platform: (any FaceActHandler)?
    private var renderer: (@Sendable (FaceCall) async throws -> FaceReply)?
    private var sink: UUID?
    private struct Observation {
        let demand: FaceDemand
        let task: Task<Void, Never>
        var readers: Set<UUID>
    }
    private var observations: [FaceKey: Observation] = [:]
    private var observationKeys: [UUID: FaceKey] = [:]
    private var platformObservations: [UUID: Task<FaceActReply, Error>] = [:]
    private var disconnecting = false

    @MainActor public init(engine: NativeAgentEngine) {
        self.engine = engine
        self.chat = BodyChatCommands(engine: engine)
    }

    public func installPlatform(_ handler: any FaceActHandler) throws {
        guard platform == nil else { throw Self.failure("platform_already_installed", "The body act adapter is already installed.") }
        platform = handler
    }

    /// The connection supplies its own sink so one renderer cannot acknowledge another consumer's frame.
    public func attachRenderer(sink: UUID, call: @escaping @Sendable (FaceCall) async throws -> FaceReply) throws {
        guard self.sink == nil, !disconnecting else { throw Self.failure("renderer_already_attached", "A renderer is attached or still releasing its work.") }
        self.sink = sink
        renderer = call
    }

    /// Closing a window releases presentation subscriptions, never a running turn.
    public func detachRenderer() async throws {
        guard !disconnecting else { throw Self.failure("renderer_disconnecting", "The renderer is already releasing its work.") }
        disconnecting = true
        defer { disconnecting = false }
        renderer = nil
        if let sink {
            await engine.face.detachSink(sink)
            await engine.pages.releaseRenderer(sink)
        }
        sink = nil
        let tasks = observations.values.map(\.task)
        observations.removeAll()
        observationKeys.removeAll()
        for task in tasks { task.cancel() }
        let external = platformObservations
        for task in external.values { task.cancel() }
        var failures: [String] = []
        if let platform {
            for (id, task) in external {
                _ = await task.result
                do { _ = try await platform.handle(.unobserve(id: id)) }
                catch { failures.append("\(id): \(error.localizedDescription)") }
            }
        }
        platformObservations.removeAll()
        for task in tasks { await task.value }
        guard failures.isEmpty else {
            throw WireFailure(code: "observation_release_failed", message: "The window closed, but body presentation work did not fully release.",
                cause: failures.joined(separator: "\n"), effects: .unknown)
        }
    }

    public var hasRenderer: Bool { renderer != nil }

    public func call(_ request: FaceCall) async throws -> FaceReply {
        guard let renderer else { throw Self.failure("renderer_unavailable", "Open NativeAgent's window to perform this presentation.") }
        return try await renderer(request)
    }

    public func call(_ request: FaceCall, renderer connection: UUID) async throws -> FaceReply {
        guard sink == connection else { throw FaceWireError.disconnected }
        let reply = try await call(request)
        guard sink == connection else { throw FaceWireError.disconnected }
        return reply
    }

    public func handle(_ act: FaceAct) async throws -> FaceActReply {
        do {
            let reply = try await dispatch(act)
            switch reply {
            case .providerTest(let probe): return .providerTest(Self.redacted(probe, act: act))
            case .failed(let failure): return .failed(Self.redacted(failure, act: act))
            case .refused(let failure): return .refused(Self.redacted(failure, act: act))
            case .committed(var result):
                result.publicationFailure = result.publicationFailure.map { Self.redacted($0, act: act) }
                return .committed(result)
            case .card(var result):
                result.failure = result.failure.map { Self.redacted($0, act: act) }
                return .card(result)
            default: return reply
            }
        } catch let failure as WireFailure {
            throw Self.redacted(failure, act: act)
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw Self.redacted(WireFailure(code: "body_act_failed", message: "The requested action could not finish.",
                cause: error.localizedDescription, effects: .unknown), act: act)
        }
    }

    public func handle(_ act: FaceAct, renderer connection: UUID) async throws -> FaceActReply {
        guard sink == connection else { throw FaceWireError.disconnected }
        return try await handle(act)
    }

    private func dispatch(_ act: FaceAct) async throws -> FaceActReply {
        switch act {
        case .attach(let version):
            guard version == FaceEnvelope.protocolVersion else {
                throw Self.failure("protocol_version", "The body and window use different FaceLink protocol versions.")
            }
            await EngineFaceProjection.layout(engine)
            return .acknowledged
        case .frameApplied(let epoch, let sequence, let barriers):
            guard let sink else { throw Self.failure("renderer_unavailable", "No renderer owns this frame receipt.") }
            guard epoch == sink else { throw FaceWireError.invalidFeedOrder }
            try await engine.face.applied(epoch: epoch, sequence: sequence, barriers: barriers)
            return .acknowledged
        case .observe(let id, let demand): return try await openObservation(act, id: id, demand: demand)
        case .unobserve(let id): return try await closeObservation(act, id: id)
        case .refresh(let scope):
            switch scope {
            case .page, .session:
                try await refresh(scope)
                return .acknowledged
            case .all, .settings, .panel:
                guard let platform else { throw Self.failure("body_adapter_unavailable", "The body refresh adapter has not been installed.") }
                return try await platform.handle(act)
            }
        case .restoreConversation:
            guard let platform else { throw Self.failure("body_adapter_unavailable", "The body selection adapter has not been installed.") }
            return try await platform.handle(act)
        case .createConversation, .selectConversation, .renameConversation,
             .archiveConversation, .clearConversation, .pinConversation, .unpinConversation, .send, .stop,
             .regenerate, .revise, .appendSlashHelp:
            return try await chat.handle(act, renderer: sink)
        case .setSurfaceExpanded(let surface, let block, let open):
            let saved = try await engine.setSurfaceExpanded(open, surface: surface, block: block).get()
            await EngineFaceProjection.layout(engine)
            ModuleLog.app("[face-act] layout fold committed surface=\(surface) block=\(block) version=\(saved.layoutVersion)")
            return try Self.committed(saved)
        case .savePageSecret(let request, let secret): return try await savePageSecret(request, secret: secret)
        case .readCredential(let request):
            return .result(try await readCredential(request).wireValue())
        case .readProviderAccount(let id):
            let saved = try await providerReadback()
            guard saved.snapshot?.providers.contains(where: { $0.provider_id == id }) == true else {
                throw Self.failure("provider_unavailable", "This account is absent from the checked provider list.")
            }
            return .provider(saved)
        case .pageAct(let request): return try await actOnPage(act, request: request)
        case .requestDocument(let request):
            return try await EngineFaceProjection.document(request, engine: engine, stampRevision: true)
        case .remember(let text):
            try await engine.turns.runtime.storeMacChatMemoryFact(text)
            return .acknowledged
        case .commitNote(let text):
            try await engine.turns.runtime.storeMacChatNote(text)
            return .acknowledged
        case .writeScratch(let session, let key, let value):
            let saved = try await engine.turns.runtime.writeMacChatScratch(key: key, value: value, sessionId: session)
            guard saved.succeeded else { throw Self.failure("scratch_refused", saved.message) }
            return .result(.string(saved.message))
        case .forgetMemory(let id):
            try await engine.memory.delete(id: id)
            return .committed(.init(identities: [id], value: .null, revision: nil, effects: .known, publicationFailure: nil))
        case .searchMemories(let query): return try await searchMemories(query)
        case .readPersona(let documents): return try await readPersona(documents: documents)
        case .savePersonaName(let name):
            let saved = try await engine.persona.saveName(name)
            await engine.memory.teachAssistantName(saved)
            return try Self.committed(saved)
        case .savePersonaDocument(let id, let content, let append, let expectedContent):
            let saved = try await engine.persona.saveDocument(id: id, content: content, appending: append, expectedContent: expectedContent)
            return try Self.committed(saved)
        case .testProvider(let request):
            return try await testProvider(request)
        case .disconnectProvider(let id):
            return try await disconnectProvider(id)
        case .cognition(let command): return try await cognition(command)
        case .onboarding(.greet):
            guard let platform else { throw Self.failure("body_adapter_unavailable", "The body greeting owner has not been installed.") }
            return try await platform.handle(act)
        case .onboarding(let request): return try await onboarding(request)
        case .saveChatChoice(let request): return try await saveChatChoice(request)
        case .saveProviderConnection(let request): return try await saveProviderConnection(request)
        case .signOutProvider(let id): return try await disconnectProvider(id)
        case .decideCodexCLIConsent(let allow): return try await decideCodexCLIConsent(allow)
        case .repairCodexCLIConsent: return try await repairCodexCLIConsent()
        case .saveAnthropicSetupToken(let secret): return try await saveAnthropicSetupToken(secret)
        case .saveConnectorCredentials(let request): return try await saveConnectorCredentials(request)
        case .applyTrustPreset(let request): return try await applyTrustPreset(request)
        case .setEmbeddingDownload(let command):
            await MainActor.run {
                switch command {
                case .pause: EmbeddingModelDownloadController.shared.cancel()
                case .resume: EmbeddingModelDownloadController.shared.start(createOnly: false)
                }
            }
            return .acknowledged
        case .readRun(let id): return try await readRun(id)
        case .research(let query): return try await research(query)
        case .senseViewEvent(let presentation, let revision, let event):
            return try await EngineFaceWorkProjection.senseEvent(presentation, revision: revision, event: event, engine: engine)
        case .createDeskTask(let title, let objective):
            let result = try await engine.submitDeskTask(title: title, objective: objective)
            return .committed(.init(identities: [result.deskItem.handle, result.job], value: .string(result.deskItem.handle),
                revision: nil, effects: .known, publicationFailure: nil))
        case .runMacControl(let request) where request.checking == true: return try await readMacControlOperation(request)
        case .handBackMacControl(let generation):
            guard await MacAttentionSessionStore.shared.giveAgentControl(userGeneration: generation) else {
                throw Self.failure("mac_handoff_unconfirmed", "Mac control changed or its input observer is unavailable. Control was not handed back.")
            }
            return .acknowledged
        case .cancelRequest, .exportConversation, .openTranscriptReader, .resizeTranscriptReader,
             .releaseTranscriptReader, .transcriptReceipt, .setTranscriptFold, .firstVisibleReply,
             .setPreference, .beginOAuth, .answerCard, .verifyCardOnReturn, .importGrokCredentials,
             .inboxAction, .openCard, .runMacControl, .reindexSpotlight, .requestUpdate, .updateInteraction,
             .deskCommand, .addDeskNote,
             .exportMake, .sendContactMessage, .stopContactMessage, .resendContactMessage,
             .ingestAttachment, .captureScreen, .openBrowser, .voice,
             .reportScene, .followSettled, .reportProtectedWindows, .reportOverlayWindow, .reportInspector,
             .notificationResponse, .quitBody:
            guard let platform else { throw Self.failure("body_adapter_unavailable", "The body act adapter has not been installed.") }
            return try await platform.handle(act)
        }
    }

    // MARK: - Observations

    /// Opens a feed observation: the platform's own, or one shared engine projection per key with this id as a reader.
    private func openObservation(_ act: FaceAct, id: UUID, demand: FaceDemand) async throws -> FaceActReply {
        guard !disconnecting else { throw FaceWireError.disconnected }
        let connection = sink
        guard observationKeys[id] == nil, platformObservations[id] == nil else {
            throw Self.failure("observation_exists", "That observation is already open.")
        }
        if demand == .key(.page("connectors")) {
            await AgentContactHealth.shared.refresh(dataRoot: engine.dataRoot)
        }
        if !EngineFaceProjection.owns(demand) {
            guard let platform else { throw Self.failure("body_adapter_unavailable", "The body presentation adapter has not been installed.") }
            let task = Task { try await platform.handle(act) }
            platformObservations[id] = task
            let reply = try await task.value
            guard !disconnecting, platformObservations[id] == task else { throw FaceWireError.disconnected }
            return reply
        }
        let key: FaceKey
        switch demand {
        case .key(let value): key = value
        case .deskPalette(let view, _): key = .deskPalette(view)
        case .sessionSearch(let view, _): key = .sessionSearch(view)
        case .agentScreen(let room, let scope): key = .agentScreen(room: room, scope: scope)
        default: throw Self.failure("invalid_observation", "This body observation requires a feed key.")
        }
        while let observation = observations[key], observation.readers.isEmpty {
            try Task.checkCancellation()
            await observation.task.value
            if observations[key]?.task == observation.task { observations.removeValue(forKey: key) }
        }
        try Task.checkCancellation()
        guard !disconnecting, sink == connection else { throw FaceWireError.disconnected }
        guard observationKeys[id] == nil, platformObservations[id] == nil else {
            throw Self.failure("observation_exists", "That observation is already open.")
        }
        if var observation = observations[key] {
            guard observation.demand == demand else {
                throw Self.failure("observation_query_changed", "Close the previous search before changing its query.")
            }
            observation.readers.insert(id)
            observations[key] = observation
        } else {
            let task = Task { [engine] in await EngineFaceProjection.observe(demand, engine: engine) }
            observations[key] = Observation(demand: demand, task: task, readers: [id])
        }
        observationKeys[id] = key
        return .observation(id: id)
    }

    /// Releases a reader; the last reader ends the shared projection, and a platform observation is closed by its owner.
    private func closeObservation(_ act: FaceAct, id: UUID) async throws -> FaceActReply {
        if let key = observationKeys.removeValue(forKey: id), var observation = observations[key] {
            observation.readers.remove(id)
            observations[key] = observation
            if observation.readers.isEmpty {
                observation.task.cancel()
                await observation.task.value
                if observations[key]?.task == observation.task { observations.removeValue(forKey: key) }
            }
        }
        if let task = platformObservations[id] {
            guard let platform else { throw Self.failure("body_adapter_unavailable", "The body presentation adapter is unavailable.") }
            task.cancel()
            _ = await task.result
            let reply = try await platform.handle(act)
            if platformObservations[id] == task { platformObservations.removeValue(forKey: id) }
            return reply
        }
        return .acknowledged
    }

    // MARK: - Domain acts

    private func savePageSecret(_ request: PageActRequest, secret: Data) async throws -> FaceActReply {
        guard let expected = request.expectedCall, let text = try Self.secret(secret), !text.isEmpty else {
            throw Self.failure("secret_required", "Enter a secret in this form's protected Mac entry.")
        }
        let outcome: FaceActOutcome
        do {
            outcome = try await engine.pages.saveKeyringForm(page: request.page, row: request.row, action: request.action,
                revision: request.expectedRevision, expecting: expected, secret: text)
        } catch let error as PartCallError { throw Self.failure(error.code, error.message) }
        return .result(try outcome.wireValue())
    }

    /// Page reads that answer here, then a drawn call's checked outcome or a plain page act.
    private func actOnPage(_ act: FaceAct, request: PageActRequest) async throws -> FaceActReply {
        if request.page == "providers", request.action == "read_chat_choice" {
            guard request.value == nil, request.expectedRevision == nil, request.expectedCall == nil else {
                throw Self.failure("provider_read_invalid", "Reading the current Chat choice takes only its conversation identity.")
            }
            return try await readChatChoice(session: request.row)
        }
        if request.page == "trust", request.row == "policy", request.action == "read_revision" {
            guard request.value == nil, request.expectedRevision == nil, request.expectedCall == nil else {
                throw Self.failure("trust_read_invalid", "Reading the Trust revision takes no edited values.")
            }
            return try await readTrustRevision()
        }
        let values: [String: PartFace.Value]?
        if case .object(let fields)? = request.value { values = fields }
        else { values = nil }
        guard request.expectedRevision == nil || values != nil else {
            throw Self.failure("page_revision_unavailable", "Page revision admission requires its body adapter. No page action ran.")
        }
        let value: String?
        switch request.value {
        case nil: value = nil
        case .string(let text)?: value = text
        case .bool(let enabled)?: value = enabled ? "true" : "false"
        case .int(let number)?: value = String(number)
        case .double(let number)?: value = String(number)
        case .object?: value = nil
        case .null?, .array?:
            throw Self.failure("invalid_control_value", "This page control takes a scalar value.")
        }
        if request.answers == true {
            let renderer = sink
            let outcome: FaceActOutcome
            do {
                if request.checking == true {
                    guard let expected = request.expectedCall else { throw Self.failure("drawn_call_missing", "Read the page before checking.") }
                    if let checked = try checkTurnStep(request, expecting: expected) {
                        outcome = checked
                    } else {
                        outcome = await engine.pages.reconcile(page: request.page, row: request.row, value: value, values: values, expecting: expected)
                    }
                } else {
                    outcome = try await engine.pages.actOutcome(page: request.page, row: request.row, action: request.action, value: value,
                        values: values, formRevision: request.expectedRevision,
                        door: "mac", expecting: request.expectedCall, renderer: renderer, operation: request.operation, undoOf: request.undoOf,
                        expectedPageRevision: request.expectedPageRevision)
                }
            } catch let error as PartCallError {
                outcome = .interrupted(Self.failure(error.code, error.message))
            }
            if let renderer, renderer != sink { await engine.pages.releaseRenderer(renderer) }
            var clean = outcome
            clean.failure = outcome.failure.map { Self.redacted($0, act: act) }
            return .result(try clean.wireValue())
        }
        do {
            let words = try await engine.pages.act(page: request.page, row: request.row, action: request.action, value: value,
                values: values, formRevision: request.expectedRevision,
                door: "mac", expecting: request.expectedCall, renderer: sink, expectedPageRevision: request.expectedPageRevision)
            return .result(words.map(PartFace.Value.string) ?? .null)
        } catch let error as PartCallError {
            throw Self.failure(error.code, error.message)
        }
    }

    private func searchMemories(_ query: String) async throws -> FaceActReply {
        let reading = await engine.memory.search(query: query)
        if let issue = reading.issue { throw Self.failure("memory_search_unavailable", issue) }
        return .result(.object(["query": .string(reading.query), "records": try reading.records.map {
            PartFace.Value(try JSONValue.fromEncodable($0))
        } ?? .null]))
    }

    private func readPersona(documents: Bool) async throws -> FaceActReply {
        var reading = PersonaSettingsFace()
        if documents {
            reading.documents = try await engine.persona.loadDocuments()
        } else {
            let profile = try await engine.persona.loadProfile()
            reading.profile = profile
            reading.displayName = profile.name
        }
        return .persona(reading)
    }

    private func checkTurnStep(_ request: PageActRequest, expecting call: PartFace.Call) throws -> FaceActOutcome? {
        guard let act = ChatTurnSteering.OwnerAct(rawValue: request.action) else { return nil }
        guard call.action == request.action, let session = call.args["session"]?.stringValue,
              NativeAgentChatSessionID.normalizedPathComponent(session) == session,
              let turn = call.args["turn"]?.stringValue, request.row == turn,
              let run = call.args["run"]?.stringValue, !run.isEmpty, request.page == PageFaceKey.turnSteps(session) else {
            throw PartCallError(code: "drawn_call_missing", message: "Read the page before checking.")
        }
        let root = engine.dataRoot
        switch act {
        case .withdrawUnstarted:
            if let checkpoint = try TurnCheckpoint.read(dataRoot: root, sessionId: session, turnId: turn),
               checkpoint.runId == run, checkpoint.withdrawsUnstarted == true {
                return .init(words: "Withdrawal was recorded for this turn.", effects: .known, accepted: true)
            }
        case .stop:
            let marker = ChatCancelFlag.path(dataRoot: root, sessionId: session)
            if let saved = try? String(contentsOf: marker, encoding: .utf8), saved.split(separator: "\n").contains(where: { $0 == run }) {
                return .init(words: "Stop was requested for this run.", effects: .known, accepted: true)
            }
        }
        return .init(words: "The saved evidence does not confirm this command.", effects: .unknown)
    }

    /// A checking Mac control act reads its original operation's record; nothing runs again.
    private func readMacControlOperation(_ request: MacControlRequest) async throws -> FaceActReply {
        guard let id = request.arguments["operationId"]?.stringValue,
              let record = try await MacControlOperationStore(dataRoot: engine.dataRoot).record(operationId: id),
              record.action == request.action else {
            throw WireFailure(code: "workbench_operation_unavailable", message: "The original Mac control operation could not be read.",
                cause: nil, effects: .unknown)
        }
        var receipt: [String: PartFace.Value] = [
            "ok": .bool(record.state == .completed), "status": .string(record.state == .completed ? "completed" : "failed"),
            "operationId": .string(id), "operationState": .string(record.state.rawValue),
            "verification": .string(record.verification.rawValue),
            "error": record.outcomeCode.map(PartFace.Value.string) ?? .null,
        ]
        if record.terminalAt == nil { receipt["effects"] = .string("unknown") }
        return .committed(.init(identities: [id], value: .object(receipt), revision: nil, effects: .none, publicationFailure: nil))
    }

    func refresh(_ scope: FaceRefreshScope) async throws {
        switch scope {
        case .page(let page):
            if page == "trust" { await engine.macIntegration.refresh(refreshWatches: false) }
            if page == "connectors" { await AgentContactHealth.shared.refresh(dataRoot: engine.dataRoot) }
            guard let snapshot = await engine.pages.refresh(page: page) else { throw Self.failure("unknown_page", "That page is not registered.") }
            if let error = snapshot.error { throw error }
        case .session(let session):
            _ = try await engine.transcripts.refreshMessages(sessionId: session, cached: false)
        case .all, .settings, .panel:
            throw Self.failure("wrong_owner", "This refresh belongs to the body platform adapter.")
        }
    }

    static func failure(_ code: String, _ message: String, effects: FaceEffects = .none) -> WireFailure {
        WireFailure(code: code, message: message, cause: nil, effects: effects)
    }

    static func secret(_ bytes: Data?) throws -> String? {
        guard let bytes else { return nil }
        guard let text = String(data: bytes, encoding: .utf8) else { throw failure("invalid_secret_encoding", "The secure entry is not UTF-8.") }
        return text
    }

    static func result<Value: Encodable>(_ value: Value) throws -> FaceActReply {
        .result(PartFace.Value(try JSONValue.fromEncodable(value)))
    }

    static func committed<Value: Encodable>(_ value: Value, identities: [String] = [],
        publicationFailure: WireFailure? = nil) throws -> FaceActReply {
        .committed(.init(identities: identities, value: PartFace.Value(try JSONValue.fromEncodable(value)),
            revision: nil, effects: .known, publicationFailure: publicationFailure))
    }
}
