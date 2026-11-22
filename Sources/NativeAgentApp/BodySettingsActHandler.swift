import AppKit
import ApprovalTransactions
import Agents
import AppToolRuntime
import AuthoredCapabilities
import BackgroundLoops
import ChatTurnContracts
import ChatTurnRuntime
import ChatToolRuntime
import DoctorChecks
import EngineRuntime
import Experiences
import Foundation
import MacControl
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import PersonaEngine
import Privacy
import ProviderRouting
import TrustCenter
import UniformTypeIdentifiers
// Blueprint: | `BodySettingsActHandler.swift` | Body platform acts, mounted presentation demands and pipe-owned reverse calls |

@MainActor
final class BodySettingsActHandler: FaceActHandler {
    private weak var appModel: AppModel?
    private let engine: NativeAgentEngine
    private var cards: BodyCardActions?
    private lazy var services = BodyFaceServices(engine: engine)
    private var palette: BodyFacePalette?
    private var composerObservations: [UUID: Task<Void, Never>] = [:]

    private func cardActions() throws -> BodyCardActions {
        if let cards { return cards }
        let model = try requireModel()
        let target = try BodyFacePresentation.current(model: model)
        let cards = BodyCardActions(engine: engine, controls: AppInlineInteractionControlPort(appModel: model, renderer: target.connection),
            call: { [weak self] request in
                guard let self else { throw FaceWireError.disconnected }
                return try await self.engine.faceActs.call(request, renderer: target.connection)
            }, restart: { try Self.restart() })
        self.cards = cards
        return cards
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        engine = appModel.engine
    }

    func rendererConnected(_ connection: UUID) async {
        BodyFacePresentation.connect(connection)
        services.connect(connection)
        await BodyFaceMotor.connect(connection, acts: engine.faceActs)
        BodyFaceDoctor.connect(connection, engine: engine)
    }

    func rendererDisconnected(_ connection: UUID?) async {
        UpdateController.shared.disconnect(renderer: connection)
        BodyFacePresentation.disconnect(connection)
        await SettingsDock.shared.close()
        cards = nil
        let composers = composerObservations
        composerObservations.removeAll()
        for task in composers.values { task.cancel() }
        for task in composers.values { await task.value }
        await palette?.close()
        await services.disconnect(connection)
    }

    func configure() {
        InlineInteractionResolver.platform = AppInlineInteractionPlatformPort()
        BodyOAuthPlatform.call = { [engine] request in
            return try await engine.faceActs.call(request)
        }
    }

    func handle(_ act: FaceAct) async throws -> FaceActReply {
        do { return try await perform(act) }
        catch let failure as WireFailure {
            throw WireFailure(code: failure.code, message: NativeAppSecretRedactor.redactText(failure.message),
                cause: failure.cause.map(NativeAppSecretRedactor.redactText), effects: failure.effects)
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw WireFailure(code: "settings_act_failed", message: "The requested operation could not complete.",
                cause: NativeAppSecretRedactor.redactText(error.localizedDescription), effects: .unknown)
        }
    }

    private func perform(_ act: FaceAct) async throws -> FaceActReply {
        if case .observe(_, .palette) = act, palette == nil { palette = BodyFacePalette(model: try requireModel()) }
        if let reply = try await palette?.handle(act) { return reply }
        if let reply = try await services.handle(act) { return reply }
        switch act {
        case .reportScene(let report):
            try BodyFacePresentation.report(report)
            return .acknowledged
        case .reportInspector(let report):
            try BodyFaceDoctor.report(report)
            return .acknowledged
        case .notificationResponse(let response):
            let model = try requireModel()
            try await handleFaceNotification(response, model: model, target: BodyFacePresentation.current(model: model))
            return .acknowledged
        case .restoreConversation:
            return try await restoreFaceConversation()
        case .observe(let id, .composer(let session)):
            return try observeFaceComposer(id: id, session: session)
        case .onboarding(.greet):
            let model = try requireModel()
            model.markFirstRunWelcomePending()
            let outcome = await model.maybeSendFirstRunGreeting()
            return .result(.object(["routeFailure": outcome.routeFailureMessage.map(PartFace.Value.string) ?? .null]))
        case .observe(let id, let demand):
            return try await observeFaceDemand(id: id, demand: demand)
        case .unobserve(let id):
            await engine.pages.release(reader: id)
            let composer = composerObservations.removeValue(forKey: id)
            composer?.cancel()
            await composer?.value
            return .acknowledged
        case .refresh(let scope):
            try await refresh(scope)
            return .acknowledged
        case .declarePreferences(let keys):
            let values = try await BodySettingsPreferences.refreshPreferences(engine: engine, keys: keys)
            return .result(.object(values))
        case .setPreference(let key, let value):
            return try await setFacePreference(key, value: value)
        case .openBrowser:
            BrowserWindowController.shared.showWindow()
            return .acknowledged
        case .requestUpdate(let command):
            let target = try BodyFacePresentation.current(model: requireModel())
            return try await UpdateController.shared.request(command, presentation: target)
        case .updateInteraction(let operation, let action):
            let target = try BodyFacePresentation.current(model: requireModel())
            return try UpdateController.shared.interaction(operation: operation, action: action, renderer: target.connection)
        case .beginOAuth(let provider):
            return try await beginFaceOAuth(provider)
        case .answerCard(let answer): return try await cardActions().answer(answer)
        case .verifyCardOnReturn(let card, let session, let revision):
            return try await cardActions().verify(.init(card: card, session: session, revision: revision))
        case .requestMacOSAccess(let targets, let card):
            let problems = try await SystemPermissionPreflight.requestMacOSAccess(targets)
            await engine.macIntegration.refresh()
            if let card { return try await cardActions().verify(card) }
            return committed(.object(["problems": .array(problems.map(PartFace.Value.string))]))
        case .openMacOSSettings(let capability):
            return try await openFaceMacOSSettings(capability)
        case .runMacControl(let request):
            return try await runFaceMacControl(request)
        case .notify(let title, let message):
            let turn = Self.personTurn("mac_control.notify")
            let result = try await engine.trust.runMacControl(action: .notify, body: ["title": .string(title), "message": .string(message)],
                notificationCenterAdapter: MacNotificationPosting(turn: turn, deadline: nil), turn: turn)
            return committed(PartFace.Value(result.toJSON(readContent: nil)))
        case .runDoctor(let request): return try await runDoctor(request)
        case .resolveApproval(let id, let decision):
            let record = try await engine.approvals.resolveApproval(id: id, decision: decision.rawValue, coordinator: .app(),
                turn: Self.personTurn("approval." + decision.rawValue))
            return committed(.object(["status": .string(record.status), "decision": record.decision.map(PartFace.Value.string) ?? .null]),
                identities: [record.id])
        case .importGrokCredentials(let request):
            return try await importFaceGrokCredentials(request)
        case .setUpChrome:
            let url = try await ChromeExtensionFolder.setUp(turn: Self.personTurn("chrome.setup"), context: .init(dataRoot: engine.dataRoot))
            return committed(.string(url.path), identities: ["chrome"])
        case .reindexSpotlight:
            return try await reindexFaceSpotlight()
        case .inboxAction(let id, let action, _):
            return try await runFaceInboxAction(id: id, action: action)
        case .openCard(let id):
            return try await openFaceCard(id)
        case .restartBody:
            try Self.restart()
            return .acknowledged
        default:
            throw PartCallError(code: "act_owner_unmounted", message: "This operation belongs to an area that has not been integrated.")
        }
    }

    /// Restore the body's saved conversation and acknowledge its selection.
    private func restoreFaceConversation() async throws -> FaceActReply {
        let model = try requireModel()
        await model.loadChatState()
        guard !model.chatStateLoadFailed, !model.activeChatSessionId.isEmpty else {
            throw PartCallError(code: "conversation_restore_failed", message: model.statusText)
        }
        return try await engine.faceActs.handle(.selectConversation(session: model.activeChatSessionId, userInitiated: false))
    }

    /// Admit the mounted composer observation and start its provider read.
    private func observeFaceComposer(id: UUID, session: String) throws -> FaceActReply {
        guard !session.isEmpty else {
            throw PartCallError(code: "conversation_required", message: "Choose a conversation before observing its composer.")
        }
        guard composerObservations[id] == nil else {
            throw PartCallError(code: "observation_exists", message: "This composer observation is already open.")
        }
        let providers = engine.providers
        composerObservations[id] = Task { await providers.observeSession(session) }
        return .observation(id: id)
    }

    /// Mount a keyed presentation demand at its body owner.
    private func observeFaceDemand(id: UUID, demand: FaceDemand) async throws -> FaceActReply {
        guard case .key(let key) = demand else {
            throw PartCallError(code: "observation_owner_unmounted", message: "This presentation has not been mounted in the body.")
        }
        switch key {
        case .settings:
            _ = try await BodySettingsPreferences.refreshPreferences(engine: engine)
            try await engine.settingsFeed.deliverFaces()
        case .page(let page), .pageTitle(let page):
            await engine.pages.observe(page: page, reader: id,
                renderer: try BodyFacePresentation.current(model: requireModel()).connection, titleOnly: key == .pageTitle(page))
            await engine.pages.refresh(page: page)
            return .observation(id: id)
        case .sessions, .sessionPalette, .sessionSearch:
            _ = try await engine.transcripts.readSessionIndex()
        case .sessionNavigation:
            await engine.transcripts.refreshNavigationIdentity()
            await engine.transcripts.deliverSessionFaces()
        case .turns, .turn, .counts:
            try await engine.settingsFeed.deliverFaces()
        case .document:
            break
        default:
            throw PartCallError(code: "observation_owner_unmounted", message: "This presentation has not been mounted in the body.")
        }
        return .observation(id: id)
    }

    /// Write the preference and read back the value for the commit receipt.
    private func setFacePreference(_ key: String, value: PartFace.Value) async throws -> FaceActReply {
        if key == "chatPersona" {
            guard case .string(let name) = value, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PartCallError(code: "persona_name_required", message: "Choose a named persona before changing this selection.")
            }
            let selected = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if PersonaSelection.current() != selected {
                PersonaSelection.select(selected)
                await engine.contextFlow.personaPickerDidChange()
            }
        } else if value == .null { try await engine.settingsFeed.useDeclaredPreference(key) }
        else { try await engine.settingsFeed.setPreference(value, key: key) }
        let values = try await BodySettingsPreferences.refreshPreferences(engine: engine, keys: [key])
        guard let saved = values[key] else {
            throw WireFailure(code: "preference_readback_unavailable", message: "The preference was written, but its value could not be read.",
                cause: nil, effects: .known)
        }
        return committed(saved, identities: [key])
    }

    /// Save the OAuth sign-in, then report any routing or publication failure.
    private func beginFaceOAuth(_ provider: String) async throws -> FaceActReply {
        let result = await NativeOAuthFlow.startOAuthFlow(platform: BodyOAuthPlatform.self, providerId: provider, dataRoot: engine.dataRoot)
        guard result.ok else {
            throw PartCallError(code: "oauth_failed", message: result.error ?? "Sign-in did not complete.")
        }
        engine.providers.fetchModelListInBackground(after: provider)
        var issue: WireFailure?
        _ = await engine.providers.adoptProviderForBlankSurfaces(provider, dataRoot: engine.dataRoot) { error, _ in
            issue = WireFailure(code: "oauth_routing_publication_failed", message: "Sign-in was saved, but Chat could not select the account.",
                cause: error.localizedDescription, effects: .known)
        }
        let saved: PartFace.Value = .object(["credentialSaved": .bool(true)])
        do { _ = try await refreshProviders() }
        catch {
            issue = WireFailure(code: "oauth_publication_failed", message: "Sign-in was saved, but Providers could not be refreshed.",
                cause: error.localizedDescription, effects: .known)
        }
        return .committed(.init(identities: [provider], value: saved, revision: nil, effects: .known, publicationFailure: issue))
    }

    /// Open the macOS settings for a recognized permission capability.
    private func openFaceMacOSSettings(_ capability: String) async throws -> FaceActReply {
        guard let gate = SystemPermissionPreflight.cardSettingsCapability(capability) else {
            throw PartCallError(code: "unknown_permission", message: "That macOS permission is not recognized.")
        }
        if let failure = await SystemPermissionPreflight.openSettings(gate) {
            throw PartCallError(code: "permission_settings_failed", message: failure)
        }
        return .acknowledged
    }

    /// Run the supported Mac control action under the person's turn.
    private func runFaceMacControl(_ request: MacControlRequest) async throws -> FaceActReply {
        guard let action = MacControlWorkbenchAction(rawValue: request.action) else {
            throw PartCallError(code: "unknown_mac_action", message: "Choose a supported Mac control action.")
        }
        let turn = Self.personTurn("mac_control." + request.action)
        let result = try await engine.trust.runMacControl(action: action, body: request.arguments.mapValues { JSONValue($0) },
            notificationCenterAdapter: MacNotificationPosting(turn: turn, deadline: nil), turn: turn)
        return committed(PartFace.Value(result.toJSON(readContent: nil)))
    }

    /// Save Grok credentials before refreshing the connector presentation.
    private func importFaceGrokCredentials(_ request: GrokCredentialWrite) async throws -> FaceActReply {
        guard let secret = String(data: request.secret, encoding: .utf8) else {
            throw PartCallError(code: "invalid_secret_encoding", message: "The submitted credentials are not UTF-8.")
        }
        let root = engine.dataRoot
        let saved = try await Self.saveGrok(contact: request.contact, secret: secret, root: root)
        guard saved else {
            throw PartCallError(code: "grok_credentials_invalid", message: """
                Paste the webhook address and key: {"url":"…","key":"…"}, or the address and the key one after the other separated by a space or \
                a new line. Nothing was saved.
                """)
        }
        var issue: WireFailure?
        do { _ = try await engine.connectors.refresh().get() }
        catch { issue = WireFailure(code: "grok_publication_failed", message: "The credentials were saved, but Connectors could not be refreshed.",
            cause: error.localizedDescription, effects: .known) }
        return committed(.bool(true), identities: [request.contact, request.operation.uuidString], publicationFailure: issue)
    }

    /// Reindex Spotlight and refresh the body's memory diagnostics.
    private func reindexFaceSpotlight() async throws -> FaceActReply {
        let result = await MemorySpotlightReindexOperation.run(dataRoot: engine.dataRoot)
        await engine.memory.refreshDiagnostics()
        guard case .indexed = result else {
            throw PartCallError(code: "spotlight_reindex_failed", message: result.agentMessage)
        }
        return committed(.string(result.userMessage), identities: ["spotlight"])
    }

    /// Apply the requested Inbox action and refresh the list after it commits.
    private func runFaceInboxAction(id: String, action: String) async throws -> FaceActReply {
        let turn = Self.personTurn("inbox." + action)
        let target = try BodyFacePresentation.current(model: requireModel())
        let effects = BodyInboxCardActionEffects(call: { try await target.call($0) }, renderer: target.connection)
        try await ApprovalTransactions.InboxCardActions.perform(id, action: action, dataRootOverride: engine.dataRoot,
            turn: turn, effects: effects)
        var issue: WireFailure?
        do { _ = try await engine.inbox.list() }
        catch { issue = WireFailure(code: "inbox_publication_failed", message: "The Inbox action completed, but its list could not be refreshed.",
            cause: error.localizedDescription, effects: .known) }
        return committed(.object(["action": .string(action)]), identities: [id], publicationFailure: issue)
    }

    /// Open the conversation that owns the card link.
    private func openFaceCard(_ id: String) async throws -> FaceActReply {
        // The card's own conversation, opened as a notification opens one: where its request was raised, or the thread its matter came
        // from. A card: link names a request by its id or its matter's, and a note by its matter's.
        let owner = ForPerson.at(engine.dataRoot)
        var found = try await owner.matter(id)
        if found == nil, !id.hasPrefix("interaction:") { found = try await owner.matter("interaction:" + id) }
        guard let matter = found else {
            throw PartCallError(code: "card_unavailable", message: "This card is no longer kept, so it has no conversation to open.")
        }
        let raised = matter.evidence.first { $0.source.hasPrefix(Matter.conversations) }
            .map { String($0.source.dropFirst(Matter.conversations.count)) }
        var thread: String?
        if case .conversation(let session)? = ForPerson.thread(matter) { thread = session }
        guard let session = raised ?? thread else {
            throw PartCallError(code: "card_conversation_unavailable",
                message: "This item was not raised in a conversation; it reads in the Inbox.")
        }
        try await BodyFacePresentation.current(model: requireModel()).present(.openConversation(session: session, message: nil))
        return .acknowledged
    }

    private func refresh(_ scope: FaceRefreshScope) async throws {
        switch scope {
        case .settings:
            _ = try await BodySettingsPreferences.refreshPreferences(engine: engine)
            _ = try await refreshProviders()
            _ = try await engine.trust.load()
            await engine.macIntegration.refresh()
        case .panel(SidebarItem.providers.rawValue):
            // Reading the accounts again (setup's "Read accounts again") starts asking any connected provider whose list is missing or failed,
            // and reads at once: those accounts say they are being asked; the answer, or the plain sentence, arrives when the ask lands.
            engine.providers.startAskingMissingModelLists()
            let saved = try await refreshProviders()
            if let issue = saved.catalogError { throw PartCallError(code: "provider_catalog_unavailable", message: issue) }
        case .panel(SidebarItem.connectors.rawValue):
            _ = try await engine.connectors.refresh().get()
            _ = try await engine.connectors.refreshWorkspaces()
        case .panel("telegram"): _ = try await engine.telegram.refresh(manager: .shared)
        case .panel(SidebarItem.personality.rawValue):
            _ = try await engine.persona.loadProfile()
            _ = try await engine.persona.loadDocuments()
        case .panel(SidebarItem.cognition.rawValue):
            await engine.cognitionView.refreshObservatory(contextFlowHealthRead: { await self.engine.contextFlow.observatoryHealthState() })
        case .panel(SidebarItem.memories.rawValue):
            let issues = await engine.memory.refreshStatuses()
            await engine.memory.refreshDiagnostics()
            guard issues.isEmpty else {
                throw PartCallError(code: "memory_refresh_failed", message: issues.map { $0.error.localizedDescription }.joined(separator: "\n"))
            }
            guard let reading = await engine.pages.refresh(page: "memories") else {
                throw PartCallError(code: "memory_page_unavailable", message: "The Memories page is not registered by its body owner.")
            }
            if let error = reading.error { throw error }
        case .panel("chat.sessions"), .panel("sidebar"):
            _ = try await engine.transcripts.readSessionIndex()
            await engine.transcripts.refreshNavigationIdentity()
            await engine.transcripts.deliverSessionFaces()
        case .panel("inbox"):
            guard let reading = await engine.pages.refresh(page: "inbox") else {
                throw PartCallError(code: "inbox_page_unavailable", message: "The Inbox page is not registered by its body owner.")
            }
            if let error = reading.error { throw error }
        case .all:
            let model = try requireModel()
            await model.refreshAll()
            if let issue = model.lastRefreshError { throw PartCallError(code: "refresh_failed", message: issue) }
        case .panel(let raw):
            guard let item = SidebarItem(rawValue: raw) else {
                throw PartCallError(code: "refresh_owner_unmounted", message: "This panel has no mounted body refresh owner.")
            }
            let model = try requireModel()
            let receipt = await model.refreshForSidebarItem(item)
            try Task.checkCancellation()
            guard receipt.failedEndpoints.isEmpty else {
                throw PartCallError(code: "panel_refresh_failed",
                    message: "Couldn't refresh " + item.rawValue + ": " + receipt.failedEndpoints.joined(separator: ", ") + ".")
            }
        case .page, .session:
            throw PartCallError(code: "refresh_owner_unmounted", message: "This refresh has no mounted settings owner.")
        }
        try await engine.settingsFeed.deliverFaces()
    }

    private func refreshProviders() async throws -> ProviderSettingsSnapshot {
        switch await engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause) {
        case .loaded(let saved): return saved
        case .failed(let detail): throw PartCallError(code: "providers_unavailable", message: detail)
        }
    }

    private func runDoctor(_ request: DoctorRequest) async throws -> FaceActReply {
        guard engine.doctor.admitRun() else {
            throw PartCallError(code: "doctor_busy", message: "Health checks are already running.")
        }
        do {
            let scope: DoctorRepairScope
            switch request.scope {
            case "automatic": scope = .automatic
            case "onboarding": scope = .onboarding
            case "button": scope = .button
            default: throw PartCallError(code: "unknown_doctor_scope", message: "The requested repair scope is not recognized.")
            }
            let report = try await AppDoctorPort(dataRoot: engine.dataRoot).runtime.runDoctor(repair: request.repair, repairScope: scope)
            engine.doctor.finishRun(report)
            return .result(try Self.value(report))
        } catch {
            engine.doctor.finishRun(nil, failure: error.localizedDescription)
            throw error
        }
    }

    private func requireModel() throws -> AppModel {
        guard let appModel else { throw FaceWireError.disconnected }
        return appModel
    }

    private static func personTurn(_ action: String) -> Turn {
        TurnRequest(message: "", sessionID: nil, surface: "native_actions",
            envelope: .personOnMac("mac_ui:" + action, surface: "native_actions")).turn()
    }

    @concurrent private static func saveGrok(contact: String, secret: String, root: URL) async throws -> Bool {
        try GrokBotConnection.saveSecureCredentials(peer: contact, paste: secret, dataRoot: root)
    }

    private func committed(_ value: PartFace.Value, identities: [String] = [], publicationFailure: WireFailure? = nil) -> FaceActReply {
        .committed(.init(identities: identities, value: value, revision: nil, effects: .known, publicationFailure: publicationFailure))
    }

    private static func value<T: Encodable>(_ value: T) throws -> PartFace.Value {
        PartFace.Value(try JSONValue.fromEncodable(value))
    }

    static func restart() throws {
        var failure: Error?
        AppRelaunch.relaunchApp(terminate: AppDelegate.terminateFromRunLoop, onSpawnFailure: { failure = $0 })
        if let failure { throw failure }
    }
}
