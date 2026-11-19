import ApprovalTransactions
import AppToolRuntime
import AuthoredCapabilities
import ChatToolRuntime
import ChatTurnContracts
import Connectors
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Transcripts
import TrustCenter
// Blueprint: | `ConnectorFace.swift` | The Connectors page: one connector list (accounts from `ConnectorReadiness`, the iPhone, each agent) whose rows hold their own settings, then kept secrets and folders; each row is a door call, and the `connections` verbs the stem pages call run here |

/// A host verb's effect, as its owner's `prepare` returns it once every lookup the verb needs has held: what runs, and its words.
public typealias HostVerbEffect = @MainActor () async throws -> String?

/// The one rule for the row a call names (a contact, a phone): its exact id first, then any name the row is known by. A name no row is
/// listed under is unknown (`unknown_<kind>`, with what is listed); a listed row the verb cannot act on now is stale (`stale_row`, with why).
enum NamedRow {
    static func find<Row>(_ wanted: String, kind: String, in rows: [Row], ids: (Row) -> [String], names: (Row) -> [String] = { _ in [] },
                          shown: (Row) -> String) throws -> Row {
        let key = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, let row = rows.first(where: { ids($0).contains(key) })
            ?? rows.first(where: { names($0).contains { $0.caseInsensitiveCompare(key) == .orderedSame } }) { return row }
        let listed = rows.map(shown)
        throw PartCallError(code: "unknown_\(kind)", message: "No \(kind) called \(key.isEmpty ? "that" : key) is listed. "
            + (listed.isEmpty ? "None is listed; refresh Connectors." : "Listed: \(listed.joined(separator: ", "))."))
    }

    static func stale(_ why: String) -> PartCallError { PartCallError(code: "stale_row", message: why + " Refresh Connectors.") }
}

@MainActor
extension ConnectorReadiness {
    func faceReader(pages: PartFaces) -> PartFaces.Read {
        facePages = pages
        return { try await self.readFace() }
    }

    func refreshFace() async {
        await facePages?.refresh(page: "connectors")
    }

    /// Every door reads the owner's published values; no credential, file or service is read here.
    @concurrent nonisolated func readFace() async throws -> (face: PartFace, epoch: UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let state = await MainActor.run {
            (accounts: accounts, secrets: secrets, workspacesReadError: workspacesReadError, workspaceSnapshot: workspaceSnapshot)
        }
        let accountRows: [PartFace.Row]
        let line: String
        switch state.accounts {
        case .failure(let error):
            accountRows = [notice("accounts-unavailable", error.localizedDescription)]
            line = "Connected accounts are unread; refresh Connectors to read them."
        case .success(let records):
            let on = records.filter(\.enabled).count
            // The line names who is asking: a count sends the reader down the page to find out.
            let waiting = records.filter { $0.needsConnectionAttention }.map(\.name)
            line = "\(on) of \(records.count) \(records.count == 1 ? "door is" : "doors are") on. "
                + (waiting.isEmpty ? "No account is asking for setup."
                    : ListFormatter.localizedString(byJoining: waiting) + (waiting.count == 1 ? " needs" : " need") + " your attention.")
            accountRows = records.isEmpty ? [.init(id: "accounts-empty", title: "No accounts are listed.", tone: .quiet)]
                : records.sorted {
                    if $0.connectionState != $1.connectionState { return $0.connectionState.rawValue < $1.connectionState.rawValue }
                    if $0.enabled != $1.enabled { return $0.enabled }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }.map(accountFaceRow)
        }
        // What is not kept or shared yet is one line each, together in one small section.
        var emptyRows: [PartFace.Row] = []
        let secretRows: [PartFace.Row]
        switch state.secrets {
        case nil:
            secretRows = [notice("secrets-unread", "Kept secrets have not been read yet. Refresh Connectors to read them.")]
        case .failure(let error)?:
            secretRows = [notice("secrets-unavailable", "Kept secrets could not be read: \(error.localizedDescription)")]
        case .success(let entries)?:
            secretRows = entries.map { entry in
                let destinations = (entry.hosts + entry.programs.map(\.path)).joined(separator: ", ")
                return .init(id: "secret:" + entry.name, title: entry.name,
                    detail: "May go to " + destinations + (entry.account.map { " · Account " + $0 } ?? ""),
                    value: "Granted", at: ISO8601DateFormatter().string(from: entry.at), symbol: "key",
                    actions: [.init(id: "forget", label: "Forget", role: .destructive,
                                    call: .init("connector.forget_secret", ["name": .string(entry.name)]))])
            }
            if entries.isEmpty { emptyRows.append(.init(id: "secrets-empty", title: "No secrets kept yet.", tone: .quiet)) }
        }
        let share = PartFace.Action(id: "share-folder", label: "Share a folder", doors: ["mac"], call: .init("connector.share_folder"))
        var folderRows: [PartFace.Row]
        if let error = state.workspacesReadError {
            folderRows = [notice("folders-unavailable", "Shared folders could not be read: " + error)]
        } else if let folders = state.workspaceSnapshot {
            folderRows = folders.map { folder in
                let access: String
                let permissions = Set(folder.permissions)
                if permissions == Set(["read"]) { access = "read" }
                else if permissions == Set(["read", "write"]) { access = "read/write" }
                else { access = folder.permissions.isEmpty ? "Access not recorded" : folder.permissions.joined(separator: "/") }
                return .init(id: folder.id, title: folder.name, detail: folder.path, value: access, symbol: "folder",
                    tone: folder.permissions.isEmpty ? .attention : nil)
            }
            if folders.isEmpty {
                emptyRows.append(.init(id: "folders-empty", title: "No folder is shared yet.", symbol: "folder", tone: .quiet))
                emptyRows.append(.init(id: "share-folder", title: "Share a folder", detail: "Choose a folder and its access on your Mac.",
                    symbol: "folder.badge.plus", actions: [share]))
            }
        } else {
            folderRows = [notice("folders-unread", "Shared folders have not been read yet. Refresh Connectors to read them.")]
        }
        if !folderRows.isEmpty {
            folderRows.append(.init(id: "share-folder", title: "Share a folder", detail: "Choose a folder and its access on your Mac.",
                symbol: "folder.badge.plus", actions: [share]))
        }
        let sections: [PartFace.Section] = [
            .init(id: Self.connectionsSection, title: "Where I reach", style: .list, rows: accountRows),
            .init(id: "secrets", title: "Kept secrets", style: .list, rows: secretRows),
            .init(id: "folders", title: "Folders I may open", style: .list, rows: folderRows),
            .init(id: "nothing-yet", title: "Secrets and folders", style: .list, rows: emptyRows),
        ]
        return (.init(title: "Connectors", line: line, sections: sections.filter { !$0.rows.isEmpty }), epoch)
    }

    /// The first section: every account, then the iPhone and each agent, one row each, its own settings behind it.
    nonisolated static let connectionsSection = "accounts"

    nonisolated private func notice(_ id: String, _ words: String) -> PartFace.Row {
        .init(id: id, title: words, tone: .attention)
    }

    nonisolated private func accountFaceRow(_ connector: ConnectorRecord) -> PartFace.Row {
        var detail = connector.connectionDescription
        // The shared renderer gives a control the trailing slot; keep this row's health words visible beside it.
        if connector.canToggle { detail = connector.connectionStatusText + "\n" + detail }
        if let status = connector.runtimeStatus, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detail += "\nLive connection: " + ConnectorRecord.plainConnectionStatus(status)
                + (connector.runtimeDetail.map { " · " + $0 } ?? "")
        }
        if let access = connector.connectionAccessLabel { detail += "\n" + access }
        let id: [String: PartFace.Value] = ["id": .string(connector.id)]
        var actions: [PartFace.Action] = []
        if connector.id == "browser" {
            actions.append(.init(id: "browser.show", label: "Show browser", role: .primary, doors: ["mac"], call: .init("browser.show")))
        } else if ConnectorWizardSetupRoute.resolve(provider: connector.id) != .unavailable {
            let connect = connector.connectionState == .needsAuth || connector.connectionState == .comingSoon
            actions.append(.init(id: "connect", label: connect ? "Connect" : "Reconnect", role: .primary, call: .init("connector.connect", id)))
        }
        if MobileConnectorSnapshot(connector).canDisconnect == true {
            actions.append(.init(id: "connector.disconnect", label: "Disconnect", role: .destructive, call: .init("connector.disconnect", id)))
        }
        // The switch moves to the other position: on calls connector.off, off calls connector.on, with the new position as its value.
        let toggle = PartFace.Control.toggle(connector.enabled, call: .init(connector.enabled ? "connector.off" : "connector.on", id))
        let tone: PartFace.Tone = connector.connectionReadFailed ? .failed : connector.hasLiveConnectionProof ? .live
            : connector.needsConnectionAttention ? .attention : .quiet
        return .init(id: connector.id, title: connector.name, detail: detail,
            value: connector.canToggle ? (connector.enabled ? "On" : "Off")
                : connector.connectionStatusText + " · " + (connector.enabled ? "On" : "Off"), symbol: "link", tone: tone,
            actions: actions.isEmpty ? nil : actions, control: connector.canToggle ? toggle : nil)
    }

    /// `connector.share_folder`: the Mac's folder panel (the lookup), where the person chooses a folder and its access; the owner saves and
    /// confirms it (the effect).
    func shareFolder(renderer: UUID?) throws -> HostVerbEffect {
        guard let choose = platform.chooseSharedFolder else {
            throw PartCallError(code: "mac_required", message: "Share a folder on your Mac")
        }
        return { [self] in
            try await connectorVerb {
                guard let selection = try await choose(renderer) else { return "No folder was shared." }
                let result = try await addWorkspace(name: selection.name, path: selection.path, writable: selection.writable)
                guard result.verified else {
                    throw PartCallError(code: "unconfirmed", message: "The saved folder could not be confirmed. Refresh Connectors before sharing it again.")
                }
                return "Shared \(result.added.name) with \(selection.writable ? "read and write" : "read-only") access."
            }
        }
    }

    /// `connector.forget_secret`: the secret is in the current reading (the lookup); it leaves the keyring (the effect).
    func forgetSecret(name: String) async throws -> HostVerbEffect {
        try await connectorVerb {
            guard let secrets, try secrets.get().contains(where: { $0.name == name }) else {
                throw PartCallError(code: "stale_secret", message: "That secret is not in the current reading. Refresh Connectors before forgetting it.")
            }
            return { [self] in
                try await connectorVerb {
                    try Keyring.remove(name)
                    await refresh()
                    return "The secret was forgotten. What uses it needs a new grant before it can reach there again."
                }
            }
        }
    }

    /// `connector.connect`: an account in the current reading that has a setup route (the lookups) gets its setup card in the open
    /// conversation `setup` opens when the effect runs.
    func connect(id: String, setup: @escaping @MainActor () async throws -> Turn) async throws -> HostVerbEffect {
        let connector = try await connectorVerb {
            guard let record = try accounts.get().first(where: { $0.id == id }) else {
                throw PartCallError(code: "stale_connector", message: "That account is not in the current reading. Refresh Connectors before changing it.")
            }
            guard ConnectorWizardSetupRoute.resolve(provider: id) != .unavailable else {
                throw PartCallError(code: "no_action", message: "That action is not available on this row. Refresh Connectors to read its controls.")
            }
            return record
        }
        return { [self] in
            let turn = try await setup()
            return try await connectorVerb {
                try await raiseSetupCard(id, name: connector.name, why: "You asked to connect \(connector.name).",
                    origin: "face:connectors:connect", turn: turn)
            }
        }
    }

    /// A connector verb's failure is the owner's own words; any other error names itself and says to read Connectors again.
    private func connectorVerb<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let error as PartCallError { throw error }
        catch { throw PartCallError(code: "connector_action_failed", message: error.localizedDescription + " Refresh Connectors before trying again.") }
    }

    /// A credential goes only onto the connector's key-entry card in the open conversation; a row only raises that card.
    func raiseSetupCard(_ id: String, name: String, why: String, origin: String, turn: Turn) async throws -> String {
        let selected: String?
        if turn[FacePresentationPart.self] != nil { selected = turn.session }
        else { selected = try await Self.currentSession(root: root) }
        guard let session = selected, !session.isEmpty else {
            throw PartCallError(code: "conversation_required",
                message: "Open a chat with me, then choose this again so I can put the \(name) setup card there.")
        }
        let card = InlineInteractionRegistry.connector(id, why: why, dataRoot: root)
        let envelope = TurnEnvelope.native(origin)
        let turn = turn.with(\.session, session).with(\.envelope, envelope).with(\.verifiedSessionID, session)
        guard let raised = await InlineInteractionResolver.raise(card, sessionID: session, resumable: false,
            origin: envelope, turn: turn, dataRoot: root) else {
            throw PartCallError(code: "card_unavailable", message: "The \(name) setup card could not be saved. Open chat and choose this again.")
        }
        return "Connect \(name) on the setup card in chat (card:\(raised.id))."
    }

    @concurrent private static func currentSession(root: URL) async throws -> String? {
        try ConversationAnchor.checkedCurrent(dataRoot: root)?.sessionId
    }
}

extension NativeAgentEngine {
    /// The Connectors page: one list of everywhere I reach (the connector owner's accounts, the iPhone, each agent contact), each row holding
    /// its own settings; then agent conversations, secrets and folders, and Telegram's diagnostics and records folded last. Each part is
    /// read from its own owner, and one part's failed read is that part's failed row; the others still draw.
    @MainActor func connectorsFaceRead() -> PartFaces.Read {
        let accounts = connectors.faceReader(pages: pages)
        contactThreads.start()
        watchPhoneFace()
        return { [self] in try await connectorsFace(accounts: accounts) }
    }

    @concurrent private func connectorsFace(accounts: PartFaces.Read) async throws -> (face: PartFace, epoch: UInt64) {
        async let accountRead = accounts()
        async let telegramRead = telegramFace()
        async let phoneRead = phoneFaceRow()
        async let agentRead = agentFace()
        let (base, telegram, phone, agents) = try await (accountRead, telegramRead, phoneRead, agentRead)
        let list = base.face.sections.filter { $0.id == ConnectorReadiness.connectionsSection }.map { section -> PartFace.Section in
            var connections = section
            // Telegram's settings sit behind its account row, or behind a Telegram row of their own when no Telegram account is listed.
            connections.rows = section.rows.map { row in
                guard row.id == "telegram" else { return row }
                var account = row
                account.rows = telegram.settings
                return account
            }
            if !connections.rows.contains(where: { $0.id == "telegram" }) {
                connections.rows.append(.init(id: "telegram.settings", title: "Telegram", symbol: "paperplane", rows: telegram.settings))
            }
            connections.rows += [phone] + agents.rows
            return connections
        }
        let others = base.face.sections.filter { $0.id != ConnectorReadiness.connectionsSection }
        return (.init(title: base.face.title, line: base.face.line, sections: list + agents.sections + others + telegram.records), base.epoch)
    }

    /// Every file and change the Connectors page reads beyond the connector owner, which refreshes the page itself.
    var connectorsFacePaths: [URL] { telegramFacePaths + phoneFacePaths + agentFacePaths }
    static let connectorsFaceNotifications = [ConnectorFaceChange.phone, PhoneSenseHistory.changed] + agentFaceNotifications

    /// A listed row, top-level or held behind another, reads from the owner's current face; the phone guide and agent threads read their
    /// documents on demand.
    @MainActor func connectorsFaceBody() -> PartFaces.Body {
        { [weak self] item in
            guard let self else { throw PartCallError(code: "connectors_closed", message: "The connectors owner has closed.") }
            if item == "iphone.senses-guide" { return PhoneSensesGuide.steps }
            if item.hasPrefix("agent-thread:") { return try await agentThreadDocument(String(item.dropFirst("agent-thread:".count))) }
            guard let snapshot = await pages.snapshots["connectors"] else {
                throw PartCallError(code: "connectors_unread", message: "Connectors has not been read yet. Read Connectors again.")
            }
            guard let face = snapshot.drawnFace else {
                throw snapshot.error ?? PartCallError(code: "connectors_unavailable", message: "Connectors is unavailable. Read Connectors again.")
            }
            let sections = face.sections.compactMap { section -> PartFace.Section? in
                let rows = section.allRows.filter { $0.id == item }
                return rows.isEmpty ? nil : .init(id: section.id, title: section.title, style: section.style, rows: rows)
            }
            guard !sections.isEmpty else {
                throw PartCallError(code: "row_not_in_reading",
                    message: "This Connectors reading does not include that row. Read Connectors again for current rows and any unavailable sections.")
            }
            return PartFace(title: face.title, sections: sections).text(door: true)
        }
    }

    @MainActor public func connectionsVerb(_ verb: String, input: [String: JSONValue], turn: Turn) async -> JSONValue {
        let effect: HostVerbEffect
        do {
            guard let prepared = try await prepareConnections(verb, input, turn) else {
                return AppToolExecutor.failure("unknown_verb", "No connections verb is called \(verb).")
            }
            effect = prepared
        } catch { return Self.prepareRefusal(error, verb: verb) }
        do {
            let words = try await effect()
            var reply: [String: JSONValue] = ["status": .string("ok")]
            if let words { reply["detail"] = .string(words) }
            return .object(reply)
        } catch { return Self.connectionsFailure(error, verb: verb) }
    }

    /// The gate's check before any card: the verb's own `prepare`, its effect not run. Nil when every lookup holds.
    @MainActor public func connectionsFence(_ verb: String, input: [String: JSONValue], turn: Turn) async -> JSONValue? {
        do {
            _ = try await prepareConnections(verb, input, turn)
            return nil
        } catch { return Self.prepareRefusal(error, verb: verb) }
    }

    /// The `connections` verbs' one switch: every lookup a verb needs (the account, secret, chat, contact, phone, record or value it names,
    /// read now) throws its owner's refusal, or the verb's effect comes back to run. Nil for a verb that is not the engine's.
    @MainActor func prepareConnections(_ verb: String, _ input: [String: JSONValue], _ turn: Turn) async throws -> HostVerbEffect? {
        func text(_ key: String) -> String { input[key]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let version: Int? = if case .int(let number)? = input["version"] { Int(number) } else { nil }
        switch verb {
        case "provider_choose": return try await chooseProviderFace(group: text("group"), setting: text("setting"), value: input["value"])
        case "provider_sign_in": return try await providerSignIn(text("provider"), renderer: turn[FacePresentationPart.self])
        case "provider_codex_session": return try await answerCodexSession(text("answer"))
        case "connector_connect": return try await connectors.connect(id: text("id"), setup: { [self] in try await connectorSetupTurn(turn) })
        case "connector_forget_secret": return try await connectors.forgetSecret(name: text("name"))
        case "connector_share_folder": return try connectors.shareFolder(renderer: turn[FacePresentationPart.self])
        case "telegram_refresh": return { [self] in try await telegramRefresh() }
        case "telegram_token": return { [self] in try await telegramToken(turn: connectorSetupTurn(turn)) }
        case "telegram_allowlist": return try telegramAllowlist(list: text("list"), value: text("value"))
        case "telegram_allow_chat": return try await telegramAllowChat(text("chat"))
        case "telegram_check_sender": return { [self] in try await telegramCheckSender() }
        case "telegram_choose": return try telegramChoose(setting: text("setting"), value: text("value"))
        case "telegram_voice_setup": return { [self] in try await telegramVoiceSetup() }
        case "pairing_check_delivery": return try pairingCheckDelivery()
        case "pairing_pair": return try pairingPair(text("id"))
        case "pairing_rotate": return try pairingRotate()
        case "pairing_use_here": return try pairingUseHere()
        case "agent_refresh": return { [self] in try await agentsRefresh() }
        case "agent_look": return { [self] in try await agentsLook() }
        case "agent_ask_in_chat": return try agentAskInChat(agent: text("agent"), ask: text("ask"))
        case "agent_send": return try await agentSend(agent: text("agent"), text: text("value"), session: text("session"), turn: turn)
        case "agent_grok_paste": return try grokPaste(peer: text("agent"), turn: turn)
        case "agent_grok_bot": return try grokBot(peer: text("agent"), name: text("value"))
        case "capability_check_trust": return try CapabilitiesFace.checkTrust(self, id: text("id"))
        case "connector_dry_run": return try CapabilitiesFace.connectorDryRun(self, id: text("id"))
        case "native_dry_run", "native_run": return try CapabilitiesFace.nativeAction(self, id: text("id"), dryRun: verb == "native_dry_run")
        case "browser_preview": return { [self] in try await CapabilitiesFace.previewBrowser(self) }
        case "browser_cancel": return try CapabilitiesFace.cancelBrowser(self, id: text("id"))
        case "tools_refresh": return { [self] in try await CapabilitiesFace.refreshTools(self) }
        case "sense_switch": return try await CapabilitiesFace.switchSense(id: text("sense_id"), version: version, on: input["value"]?.boolValue,
            byPerson: AppToolExecutor.personDecided(tool: "connections", input: input, turn: turn))
        case "sense_share": return try await CapabilitiesFace.shareSense(self, id: text("sense_id"), version: version)
        case "ability_keep": return try await CapabilitiesFace.keepAbility(self, id: text("id"), version: input["version"]?.stringValue,
            byPerson: PermissionLaw.personDecided(tool: "app", input: ["action": .string("ability.keep"),
                "args": .object(input.filter { $0.key != "verb" && !$0.key.hasPrefix("__") })], turn: turn), turn: turn)
        case "ability_off": return try CapabilitiesFace.switchOffAbility(self, id: text("id"),
            byPerson: PermissionLaw.personDecided(tool: "app", input: ["action": .string("ability.off"),
                "args": .object(input.filter { $0.key != "verb" && !$0.key.hasPrefix("__") })], turn: turn), turn: turn)
        case "skill_build": return try CapabilitiesFace.buildSkill(self)
        default: return nil
        }
    }

    /// A host verb's lookup that threw before its effect ran: the one refusal shape (`ChatToolOutcome.refusedBeforeRunning`), in the
    /// owner's own code and words, for its run and the gate's check alike.
    public static func prepareRefusal(_ error: Error, verb: String) -> JSONValue {
        ChatToolOutcome.refusedBeforeRunning(owner: (error as? QuietArgumentRefusal)?.json ?? connectionsFailure(error, verb: verb))
    }

    /// A `connections` verb's failure as its answer: the owner's own code and words.
    static func connectionsFailure(_ error: Error, verb: String) -> JSONValue {
        switch error {
        case let error as ToolFailureError: ChatToolOutcome.failure(error: error, tool: "connections")
        case let error as PartCallError: .object(["status": .string("failed"), "reason": .string(error.code), "detail": .string(error.message)])
        default: .object(["status": .string("failed"), "reason": .string("\(verb)_failed"), "detail": .string(error.localizedDescription)])
        }
    }

    @MainActor private func connectorSetupTurn(_ turn: Turn) async throws -> Turn {
        guard let renderer = turn[FacePresentationPart.self] else { return turn }
        let reply = try await faceActs.call(.readScene, renderer: renderer)
        let scene: SceneReport
        switch reply {
        case .scene(let report): scene = report
        case .failed(let issue), .refused(let issue): throw issue
        case .cancelled: throw CancellationError()
        default: throw FaceWireError.invalidFeedOrder
        }
        guard scene.connection == renderer, scene.mounted, let session = scene.selectedSession, !session.isEmpty else {
            throw PartCallError(code: "conversation_required", message: "Open a chat with me, then choose this again to put its setup card there.")
        }
        guard try await transcripts.list().contains(where: { $0.id == session }) else {
            throw PartCallError(code: "conversation_unknown", message: "That conversation is unavailable. Choose a conversation again.")
        }
        switch try await faceActs.call(.openConversation(session: session, message: nil), renderer: renderer) {
        case .acknowledged: return turn.with(\.session, session)
        case .failed(let issue), .refused(let issue): throw issue
        case .cancelled: throw CancellationError()
        default: throw FaceWireError.invalidFeedOrder
        }
    }
}

enum ConnectorFaceState: Int {
    case live, ready, unverified, planned, needsAuth, comingSoon, unknown

    static func resolve(_ connector: ConnectorRecord) -> Self {
        let auth = connector.authState?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let health = connector.healthStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if auth == "coming_soon" || health == "coming_soon" { return .comingSoon }
        if health == ConnectorHealthDecay.unverifiedHealth { return .unverified }
        if auth == "failed" || health == "failed" { return .unknown }
        if auth.map({ ["connected_unverified", "not_connected", "needs_auth"].contains($0) }) == true
            || health.map({ ["needs_auth", "needs_probe", "needs_permission", "probe_needed", "needs_config", "needs_setup"].contains($0) }) == true {
            return .needsAuth
        }
        if health.map({ ["ok", "healthy", "connected", "active", "live"].contains($0) }) == true { return .live }
        if health == "ready" { return auth == "planned" ? .planned : .ready }
        if health == nil || health == "unknown" || health == "" { return .unverified }
        return .unknown
    }
}

extension ConnectorRecord {
    var connectionState: ConnectorFaceState { .resolve(self) }
    var connectionReadFailed: Bool {
        authState == "failed" || healthStatus.map { ["failed", "unavailable"].contains($0) } == true
    }
    var needsConnectionAttention: Bool {
        connectionReadFailed || [.needsAuth, .unverified].contains(connectionState)
    }
    var hasLiveConnectionProof: Bool {
        enabled && connectionState == .live
            && healthStatus.map { ["ok", "healthy", "connected", "active", "live"].contains($0.lowercased()) } == true
    }

    /// One set of status words for the face and the service/permission pages that still read these records.
    public var connectionStatusText: String {
        let health = healthStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth = authState?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch connectionState {
        case .unverified:
            return auth.map { [ConnectorHealthDecay.configuredAuth, "connected", "not_required"].contains($0.lowercased()) } == true
                ? "Set up · Not checked" : "Not checked"
        case .planned: return "Not available yet"
        case .ready: return "Ready"
        case .comingSoon: return "Coming soon"
        case .needsAuth:
            switch health?.lowercased() {
            case "needs_permission": return "Needs permission"
            case "needs_probe", "probe_needed": return "Needs a check"
            case "needs_config", "needs_setup": return "Needs setup"
            default: return "Needs sign-in"
            }
        case .live: return "Connected"
        case .unknown: return Self.plainConnectionStatus(health ?? auth ?? "unknown")
        }
    }

    static func plainConnectionStatus(_ value: String) -> String {
        switch value.lowercased() {
        case "needs_auth", "auth_required", "needs_sign_in": "Needs sign-in"
        case "connected", "live", "ok", "healthy": "Connected"
        case "ready": "Ready"
        case "connecting", "starting": "Connecting"
        case "disconnected", "offline": "Disconnected"
        case "disabled": "Off"
        case "failed", "error", "unavailable": "Unavailable"
        default: "Not checked"
        }
    }

    var connectionAccessLabel: String? {
        switch riskClass {
        case "network_read": "Reads the web"
        case "network_write": "Can change things online"
        case "file_access": "Reads your files"
        default: nil
        }
    }

    var connectionDescription: String {
        switch id {
        case "shortcuts": "Run Apple Shortcuts for Desk tasks, Diagnostics, status, and chat."
        case "telegram": "Talk with me from Telegram. Only people and group chats you approve can message me, and everyone in an approved group can."
        case "browser": "I browse in a window you can watch, and keep a record of what I looked at."
        case "local_files": "Folders you have approved as workspaces, which I can search and read."
        default: description
        }
    }
}
