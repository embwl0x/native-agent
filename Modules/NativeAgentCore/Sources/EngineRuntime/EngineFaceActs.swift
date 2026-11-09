import AuthoredCapabilities
import BackgroundLoops
import ChatTurnRuntime
import Cognition
import Context
import ContextFlow
import DoctorChecks
import Foundation
import MemoryV2
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import PersonaEngine
import ProviderRouting
import Privacy
import TelegramBot
import TrustCenter
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
            case .result(let value):
                if case .testProvider = act { return .result(Self.redactedValue(value, act: act)) }
                return reply
            case .failed(let failure): return .failed(Self.redacted(failure, act: act))
            case .refused(let failure): return .refused(Self.redacted(failure, act: act))
            case .committed(var result):
                result.publicationFailure = result.publicationFailure.map { Self.redacted($0, act: act) }
                return .committed(result)
            case .operation(.completed(var result)):
                result.publicationFailure = result.publicationFailure.map { Self.redacted($0, act: act) }
                return .operation(.completed(result))
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
        case .observe(let id, let demand):
            guard !disconnecting else { throw FaceWireError.disconnected }
            guard observationKeys[id] == nil, platformObservations[id] == nil else {
                throw Self.failure("observation_exists", "That observation is already open.")
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
            case .dreamDiary(let limit):
                guard limit > 0 else { throw Self.failure("invalid_diary_limit", "The diary view requires a positive entry count.") }
                _ = try await engine.cognitionView.dreamDiary(limit: limit)
                key = .dreamDiary
            case .deskPalette(let view, _): key = .deskPalette(view)
            case .sessionSearch(let view, _): key = .sessionSearch(view)
            case .agentScreen(let room, let scope): key = .agentScreen(room: room, scope: scope)
            case .graphNeighborhood(let entity): key = .graphNeighborhood(entity: entity)
            default: throw Self.failure("invalid_observation", "This body observation requires a feed key.")
            }
            let source: FaceDemand
            switch demand {
            case .deskPalette, .agentScreen, .sessionSearch: source = demand
            default: source = .key(key)
            }
            if var observation = observations[key] {
                guard !observation.readers.isEmpty else { throw Self.failure("observation_releasing", "This presentation is still releasing its reader.") }
                guard observation.demand == source else {
                    throw Self.failure("observation_query_changed", "Close the previous search before changing its query.")
                }
                observation.readers.insert(id)
                observations[key] = observation
            } else {
                let task = Task { [engine] in await EngineFaceProjection.observe(source, engine: engine) }
                observations[key] = Observation(demand: source, task: task, readers: [id])
            }
            observationKeys[id] = key
            return .observation(id: id)
        case .unobserve(let id):
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
        case .createConversation, .selectConversation, .markConversationRead, .renameConversation,
             .archiveConversation, .clearConversation, .pinConversation, .unpinConversation, .send, .stop,
             .regenerate, .prepareRetryDraft, .appendSlashHelp:
            return try await chat.handle(act, renderer: sink)
        case .setSurfaceExpanded(let surface, let block, let open):
            let saved = try await engine.setSurfaceExpanded(open, surface: surface, block: block).get()
            await EngineFaceProjection.layout(engine)
            ModuleLog.app("[face-act] layout fold committed surface=\(surface) block=\(block) version=\(saved.layoutVersion)")
            return try Self.committed(saved)
        case .savePageSecret(let request, let secret):
            guard let expected = request.expectedCall, let text = try Self.secret(secret), !text.isEmpty else {
                throw Self.failure("secret_required", "Enter a secret in this form's protected Mac entry.")
            }
            let outcome: FaceActOutcome
            do {
                outcome = try await engine.pages.saveKeyringForm(page: request.page, row: request.row, action: request.action,
                    revision: request.expectedRevision, expecting: expected, secret: text)
            } catch let error as PartCallError { throw Self.failure(error.code, error.message) }
            return .result(try outcome.wireValue())
        case .readCredential(let request):
            return .result(try await readCredential(request).wireValue())
        case .readProviderAccount(let id):
            let saved = try await providerReadback()
            guard saved.snapshot?.providers.contains(where: { $0.provider_id == id }) == true else {
                throw Self.failure("provider_unavailable", "This account is absent from the checked provider list.")
            }
            return .provider(saved)
        case .pageAct(let request):
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
                guard let expected = request.expectedCall else { throw Self.failure("drawn_call_missing", "Read the page before acting.") }
                let renderer = sink
                let outcome: FaceActOutcome
                do {
                    if request.checking == true {
                        outcome = await engine.pages.reconcile(page: request.page, row: request.row, value: value, values: values, expecting: expected)
                    } else {
                        outcome = try await engine.pages.actOutcome(page: request.page, row: request.row, action: request.action, value: value,
                            values: values, formRevision: request.expectedRevision,
                            door: "mac", expecting: expected, renderer: renderer, operation: request.operation, undoOf: request.undoOf)
                    }
                } catch let error as PartCallError {
                    outcome = .interrupted(Self.failure(error.code, error.message))
                }
                if let renderer, renderer != sink { await engine.pages.releaseRenderer(renderer) }
                var clean = outcome
                clean.failure = outcome.failure.map { Self.redacted($0, act: act) }
                return .result(try clean.wireValue())
            }
            let words = try await engine.pages.act(page: request.page, row: request.row, action: request.action, value: value,
                values: values, formRevision: request.expectedRevision,
                door: "mac", expecting: request.expectedCall, renderer: sink)
            return .result(words.map(PartFace.Value.string) ?? .null)
        case .requestDocument(let request):
            return try await EngineFaceProjection.document(request, engine: engine)
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
        case .pinMemory(let id, let pinned):
            try await engine.memory.setPinned(pinned, id: id)
            return .acknowledged
        case .forgetMemory(let id):
            try await engine.memory.delete(id: id)
            return .acknowledged
        case .resolveMemoryProposal(let id, let decision):
            switch decision {
            case .accept: _ = try await engine.memory.accept(proposalID: id)
            case .reject: try await engine.memory.reject(proposalID: id, reason: "")
            }
            return .acknowledged
        case .searchMemories(let query):
            let reading = await engine.memory.search(query: query)
            if let issue = reading.issue { throw Self.failure("memory_search_unavailable", issue) }
            return .result(.object(["query": .string(reading.query), "records": try reading.records.map {
                PartFace.Value(try JSONValue.fromEncodable($0))
            } ?? .null]))
        case .readPersona(let documents):
            var reading = PersonaSettingsFace()
            if documents {
                reading.documents = try await engine.persona.loadDocuments()
            } else {
                let profile = try await engine.persona.loadProfile()
                reading.profile = profile
                reading.displayName = profile.name
            }
            return .persona(reading)
        case .savePersonaProfile(let profile):
            let saved = try await engine.persona.saveProfile(profile)
            await engine.memory.teachAssistantName(saved.profile)
            return .committed(.init(identities: [], value: PartFace.Value(try JSONValue.fromEncodable(saved.profile)), revision: nil, effects: .known,
                publicationFailure: saved.documentsIssue.map {
                    WireFailure(code: "persona_documents_unavailable", message: "The profile was saved, but its documents could not be refreshed.",
                        cause: $0, effects: .known)
                }))
        case .savePersonaName(let name):
            let saved = try await engine.persona.saveName(name)
            await engine.memory.teachAssistantName(saved)
            return try Self.committed(saved)
        case .savePersonaDocument(let id, let content, let append, let expectedContent):
            let saved = try await engine.persona.saveDocument(id: id, content: content, appending: append, expectedContent: expectedContent)
            return try Self.committed(saved)
        case .setDreamCycleEnabled(let enabled):
            let saved = try await engine.cognitionView.setDreamCycleEnabled(enabled)
            await engine.trust.publishPolicy(saved)
            return try Self.committed(saved)
        case .setREMCycleEnabled(let enabled):
            let saved = try await engine.cognitionView.setRemCycleEnabled(enabled)
            await engine.trust.publishPolicy(saved)
            return try Self.committed(saved)
        case .setInnerLifeEnabled(let enabled):
            guard let runtime = engine.cognition else { throw Self.failure("body_unavailable", "This root has no resident mind.") }
            let result = await engine.cognitionView.setInnerLifeEnabled(enabled, runtime: runtime, contextFlow: engine.contextFlow)
            return .result(.object(["enabled": .bool(result.state.enabled), "contextFlowReady": .bool(result.contextFlowReady)]))
        case .setContextFlowMode(let name):
            guard let mode = ContextFlowMode(rawValue: name) else { throw Self.failure("invalid_mode", "Choose an offered context mode.") }
            let status = await engine.contextFlow.setMode(mode)
            guard let saved = status.effectiveMode, status.unavailableReason == nil else {
                throw Self.failure("context_unavailable", status.unavailableReason ?? "The context owner returned no effective mode.")
            }
            await engine.cognitionView.refreshContextFlowHealth { @Sendable [engine] in
                await engine.contextFlow.observatoryHealthState()
            }
            return .result(.string(saved.rawValue))
        case .setEmbeddingsEnabled(let enabled):
            try await engine.memory.toggleEmbeddings(enabled)
            guard let saved = await engine.memory.readEmbeddingSnapshot() else {
                throw Self.failure("embedding_readback_unavailable", "The embedding choice was saved, but its runtime could not be read.", effects: .known)
            }
            return .result(.object(["requestedBackend": .string(saved.requestedBackend), "effectiveBackend": .string(saved.effectiveBackend),
                "model": .string(saved.modelId), "dimensions": .int(Int64(saved.dimensions)),
                "loadError": saved.lastLoadError.map(PartFace.Value.string) ?? .null]))
        case .setInboxTrigger(let name, let enabled):
            try await engine.inbox.setTrigger(name, enabled: enabled)
            return .acknowledged
        case .testProvider(let request):
            return try await testProvider(request)
        case .disconnectProvider(let id):
            return try await disconnectProvider(id)
        case .repairTelegram(let inbox):
            let result = try await TelegramUpdateInbox.repair(dataRoot: engine.dataRoot, inbox: inbox ?? "")
            return .result(PartFace.Value(result))
        case .clearTelegramLogs:
            let result = try await engine.telegram.clearTelegramDiagnostics(manager: .shared)
            return .committed(.init(identities: ["telegram"], value: .object(["removedRows": .int(Int64(result.removedRowCount)),
                "removedFiles": .int(Int64(result.removedFileCount))]), revision: result.clearedAt, effects: .known, publicationFailure: nil))
        case .runDream: return .result(PartFace.Value(try await Self.dream(engine.dataRoot, rem: false)))
        case .runREM: return .result(PartFace.Value(try await Self.dream(engine.dataRoot, rem: true)))
        case .cognition(let command): return try await cognition(command)
        case .onboarding(.greet):
            guard let platform else { throw Self.failure("body_adapter_unavailable", "The body greeting owner has not been installed.") }
            return try await platform.handle(act)
        case .onboarding(let request): return try await onboarding(request)
        case .createStarterPersona(let request):
            return try await onboarding(.complete(agentName: request.agentName, personaType: request.personaType, userName: request.userName))
        case .createBackup(let reason): return try await createBackup(reason)
        case .saveChatChoice(let request): return try await saveChatChoice(request)
        case .saveProviderConnection(let request): return try await saveProviderConnection(request)
        case .signOutProvider(let id): return try await disconnectProvider(id)
        case .decideCodexCLIConsent(let allow): return try await decideCodexCLIConsent(allow)
        case .repairCodexCLIConsent: return try await repairCodexCLIConsent()
        case .saveAnthropicSetupToken(let secret): return try await saveAnthropicSetupToken(secret)
        case .setConnectorEnabled(let id, let enabled): return try await setConnectorEnabled(id, enabled: enabled)
        case .disconnectConnector(let id): return try await disconnectConnector(id)
        case .saveConnectorCredentials(let request): return try await saveConnectorCredentials(request)
        case .configureTelegram(let request): return try await configureTelegram(request)
        case .saveSlackIngress(let request): return try await saveSlackIngress(request)
        case .testTelegram: return try await testTelegram()
        case .removePhonePairing(let id): return try await removePhonePairing(id)
        case .applyTrustPreset(let request): return try await applyTrustPreset(request)
        case .saveMemoryPolicy(let request): return try await savePolicyBlock("memoryPolicy", fields: request.fields, revision: request.expectedRevision)
        case .setAutonomyEnabled(let enabled): return try await savePolicy(["enableAutonomy": .bool(enabled)])
        case .setChromeControlEnabled(let enabled):
            let saved = try await savePolicy(["chromeControlPolicy": .object(["enabled": .bool(enabled)])])
            await engine.chrome.reconcilePolicy(context: .init(dataRoot: engine.dataRoot))
            return saved
        case .setKillSwitchEnabled(let enabled): return try await savePolicy(["securityPolicy": .object(["killSwitchEnabled": .bool(enabled)])])
        case .saveMacIntegrationPreset(let preset): return try await saveMacIntegrationPreset(preset)
        case .saveMacControlPolicy(let request): return try await saveMacControlPolicy(request)
        case .saveMultimodalPolicy(let request):
            return try await savePolicyBlock("multimodalPolicy", fields: request.fields, revision: request.expectedRevision)
        case .authorizeSafePolicy: return await trustReply(try await SwiftNativeTrustCenter(dataRoot: engine.dataRoot).reauthorizeSafePolicy())
        case .refreshPrivacyInventory: await engine.trust.refreshPrivacyMap(); return .acknowledged
        case .checkMail: await engine.macIntegration.checkMail(); return .acknowledged
        case .setActivityPolicy(let request): return try await saveActivityPolicy(request)
        case .excludeActivityApp(let id, let confirmed): return try await excludeActivityApp(id, confirmed: confirmed)
        case .removeActivityExclusion(let id): return try await removeActivityExclusion(id)
        case .wipeActivity(let confirmed): return try await wipeActivity(confirmed)
        case .restoreBackup(let id, let confirmed): return try await restoreBackup(id, confirmed: confirmed)
        case .requestSupportSnapshot: return try Self.result(await SupportDiagnostics.read(reusingChecks: nil))
        case .setEmbeddingDownload(let command):
            await MainActor.run {
                switch command {
                case .pause: EmbeddingModelDownloadController.shared.cancel()
                case .resume: EmbeddingModelDownloadController.shared.start(createOnly: false)
                }
            }
            return .acknowledged
        case .createProductionExport(let support):
            return try Self.committed(try await engine.doctor.createProductionExport(support: support))
        case .readRun(let id): return try await readRun(id)
        case .research(let query): return try await research(query)
        case .senseViewEvent(let presentation, let revision, let event):
            return try await EngineFaceWorkProjection.senseEvent(presentation, revision: revision, event: event, engine: engine)
        case .createDeskTask(let title, let objective):
            let result = try await NativeAgentEngine.submitDeskTask(title: title, objective: objective, dataRoot: engine.dataRoot)
            return .committed(.init(identities: [result.deskItem.handle, result.job], value: .string(result.deskItem.handle),
                revision: nil, effects: .known, publicationFailure: nil))
        case .runMacControl(let request) where request.checking == true:
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
        case .handBackMacControl(let generation):
            guard await MacAttentionSessionStore.shared.giveAgentControl(userGeneration: generation) else {
                throw Self.failure("mac_handoff_unconfirmed", "Mac control changed or its input observer is unavailable. Control was not handed back.")
            }
            return .acknowledged
        case .cancelRequest, .exportConversation, .requestCopy, .openTranscriptReader, .resizeTranscriptReader,
             .releaseTranscriptReader, .transcriptReceipt, .setTranscriptFold, .firstVisibleReply,
             .declarePreferences, .setPreference, .beginOAuth,
             .answerCard, .verifyCardOnReturn, .importGrokCredentials, .setUpChrome,
             .resolveApproval, .inboxAction, .requestMacOSAccess,
             .openMacOSSettings, .runMacControl, .notify,
             .runDoctor, .reindexSpotlight, .requestUpdate, .updateInteraction,
             .deskCommand, .addDeskNote,
             .exportMake, .sendContactMessage, .stopContactMessage, .resendContactMessage,
             .withdrawContactMessage, .ingestAttachment, .captureScreen, .openBrowser, .voice,
             .reportScene, .reportProtectedWindows, .reportOverlayWindow, .reportInspector, .reportRendererDiagnostic,
             .notificationResponse, .quitBody, .restartBody:
            guard let platform else { throw Self.failure("body_adapter_unavailable", "The body act adapter has not been installed.") }
            return try await platform.handle(act)
        }
    }

    func refresh(_ scope: FaceRefreshScope) async throws {
        switch scope {
        case .page(let page):
            if page == "trust" { await engine.macIntegration.refresh(refreshWatches: false) }
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

    static func committed<Value: Encodable>(_ value: Value, identities: [String] = []) throws -> FaceActReply {
        .committed(.init(identities: identities, value: PartFace.Value(try JSONValue.fromEncodable(value)),
            revision: nil, effects: .known, publicationFailure: nil))
    }
}
