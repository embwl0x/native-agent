import ApprovalTransactions
import AppToolRuntime
import BackgroundWork
import AgentWorkspace
import Agents
import ChatOrchestration
import Connectors
import DeviceSync
import Desk
import Foundation
import MacIntegration
import MemoryV2
import PersonaEngine
import StandingBots
import Studio
import MCPDispatcher
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import TrustCenter
import TrustPersistence
import ToolExecution

@MainActor
extension RuntimeReadProjection {
    public static func quietPages(dataRoot: URL, profile: String) -> [QuietToolPage] {
        let layout = SurfaceLayoutStore.layout(dataRoot: dataRoot)
        let hidden = Set(["rail", "places"].flatMap { surface in
            (layout.surfaces[surface] ?? []).map(\.name)
                .filter { !layout.isShown(surface, $0, profile: profile) }.map(AppDoorNames.resolve)
        })
        return QuietToolPage.all.filter { !hidden.contains($0.id) }
    }

    private static func bounded(_ raw: String) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > 200 else { return collapsed }
        return String(collapsed.prefix(199)) + "\u{2026}"
    }

    public static func quietPageSection(_ heading: String, _ lines: [String]) -> JSONValue {
        .object([
            "heading": .string(heading),
            "lines": .array(lines.map { .string(bounded($0)) }),
        ])
    }

    public static func quietCountLine(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? "1 \(one)" : "\(count) \(many)"
    }

    public static func quietModelLines(_ members: [ProviderSurfaceMember], routing: ProviderRoutingSnapshot) -> [String] {
        members.map { member in
            if let issue = routing.unusablePickNotice(for: member.surface) { return "\(member.label): \(issue)" }
            let provider = routing.activeProviders[member.surface] ?? "same as Chat"
            guard let preference = routing.preferences[member.surface] else {
                return "\(member.label): \(provider) · no model pinned"
            }
            let fast = preference.serviceTier == "priority" ? "Fast on" : "Fast off"
            let think = preference.reasoningEffort.isEmpty ? "no thinking level" : "Think \(preference.reasoningEffort)"
            return "\(member.label): \(provider) · \(preference.model) · \(think) · \(fast)"
        }
    }

    public static func quietNotifications(_ inbox: InboxFacade) -> [JSONValue] {
        let items = inbox.items
        var sections = [quietPageSection("Notifications", [
            quietCountLine(items.count, "item in the inbox", "items in the inbox"),
            quietCountLine(items.filter { $0.status == "unread" }.count, "unread", "unread"),
        ])]
        if !items.isEmpty {
            sections.append(quietPageSection("Recent", items.prefix(15).map {
                "\($0.created_at) · \($0.status) · \($0.severity) · \($0.source): \($0.title) — \($0.summary)"
            }))
        }
        return sections
    }

    public static func quietTelegram(_ telegram: TelegramFacade) -> [JSONValue] {
        guard let status = telegram.status else {
            return [quietPageSection("Telegram", ["Telegram's status has not loaded."])]
        }
        var lines = [
            "Telegram: \(status.enabled ? "on" : "off") · bot token \(status.tokenConfigured ? "saved" : "not saved")",
            "Only answers when mentioned in a group: \(status.requireMention ? "yes" : "no")",
            quietCountLine(status.allowedChatIds.count, "allowed chat", "allowed chats")
                + ", " + quietCountLine(status.allowedUserIds.count, "allowed user", "allowed users"),
            "Model: \(status.model ?? "same as Chat") · Think \(status.reasoningEffort ?? "default")",
        ]
        if let at = status.lastReplyAt { lines.append("Last reply: \(at)") }
        if let error = status.lastError, !error.isEmpty { lines.append("Last error: \(error)") }
        return [quietPageSection("Telegram", lines)]
    }

    public static func quietMCP(servers: [MCPServer]) -> [JSONValue] {
        var sections = [quietPageSection("MCP", [quietCountLine(servers.count, "server", "servers")])]
        if !servers.isEmpty {
            sections.append(quietPageSection("Servers", servers.map {
                "\($0.name) [\($0.id)]: \($0.status) · \($0.toolCount) tools"
            }))
        }
        return sections
    }

    public static func quietPairing(_ sync: SyncFacade, dataRoot: URL) async -> [JSONValue] {
        var head = ["iCloud: \(sync.status)"]
        if let error = sync.pairingError { head.append("Problem: \(error)") }
        let phones = sync.phones.filter { $0.status != .removed }
        head.append(quietCountLine(phones.count, "phone", "phones"))
        var sections = [quietPageSection("iPhone pairing", head)]
        if !phones.isEmpty {
            sections.append(quietPageSection("Phones", phones.map { "\($0.id): \($0.status.rawValue)" }))
        }
        do {
            let phone = try await SwiftNativeAPNSSender().notificationReadiness(dataRoot: dataRoot)
            sections.append(quietPageSection("Notifications", [phone.detail]))
        } catch {
            sections.append(quietPageSection("Notifications", ["Unavailable: \(error.localizedDescription)"]))
        }
        return sections
    }

    /// A Mac app's or connector's page: the Mac app whose access it shows,
    /// and the connectors behind its actions.
    public static let quietServicePages: [String: (mac: String?, connectors: [String])] = [
        "mail": (MacIntegrationID.mail, ["local_mail", "gmail", "agentmail"]),
        "calendar": (MacIntegrationID.calendar, ["local_calendar", "google_calendar"]),
        "reminders": (MacIntegrationID.reminders, ["local_reminders"]),
        "notes": (MacIntegrationID.notes, []), "contacts": (MacIntegrationID.contacts, []),
        "messages": (MacIntegrationID.messages, []), "music": (MacIntegrationID.music, []),
        "github": (nil, ["github"]), "slack": (nil, ["slack"]), "notion": (nil, ["notion"]), "x": (nil, ["x"]),
    ]

    public static func quietMacAccess(_ mac: String, connectors: [ConnectorRecord], dataRoot: URL,
                                      permissions: Result<MacIntegrationPermissionStore.Snapshot, Error>,
                                      statusText: (ConnectorRecord) -> String, osAccess: (String) -> String) async -> JSONValue {
        let routes = AppActions.integrationRoutes(mac).map { route -> JSONValue in
            guard case .object(var row) = route else { return route }
            let ids = quietServicePages.values.filter { $0.mac == mac }.flatMap(\.connectors).map(ConnectorProofLedger.canonicalID)
            let words = connectors.filter { ids.contains(ConnectorProofLedger.canonicalID($0.id)) }.map {
                $0.name + ": " + statusText($0)
            }
            row["connection_readiness"] = .string(words.isEmpty ? "No connector receipt" : words.joined(separator: "; "))
            return .object(row)
        }
        var access: [String: JSONValue] = ["integration": .string(mac), "name": .string(MacIntegrationID.displayName(for: mac)),
            "supported_routes": .array(routes), "supported": .bool(!routes.isEmpty),
            "verified_os_access": .string("unverified"), "setting": .string("trust.mac_integration_\(mac)")]
        access["verified_os_access"] = .string(osAccess(mac))
        if mac == MacIntegrationID.notifyMobile {
            do {
                let phone = try await SwiftNativeAPNSSender().notificationReadiness(dataRoot: dataRoot)
                access["supported"] = .bool(phone.supported)
                access["connection_readiness"] = .string(phone.status)
                access["detail"] = .string(phone.detail)
                access["supported_routes"] = .array(routes.map { route in
                    guard case .object(var row) = route else { return route }
                    row["connection_readiness"] = .string(phone.status)
                    return .object(row)
                })
            } catch {
                access["supported"] = .bool(false)
                access["connection_readiness"] = .string("unavailable")
                access["detail"] = .string(error.localizedDescription)
            }
        }
        do {
            let snapshot = try permissions.get()
            let stored = snapshot.permissions[mac]!
            let readiness = snapshot.readiness
            var origin = SecurityOriginContext.currentTurn(verifiedSessionId: ChatToolSessionContext.verifiedSessionId,
                surface: ChatToolSessionContext.envelope?.surface ?? "chat")
            origin.source = "native_client_direct_action"
            let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot).fullMacYoloAuthority(tool: "mac_integration", origin: origin)
            access["full_mac_admission"] = .string(authority.state.rawValue)
            access["full_mac_reason"] = .string(authority.reason)
            if authority.state == .unavailable || authority.state == .explicitlyBlocked {
                access["permission_state"] = .string(authority.state == .unavailable ? "unavailable" : "blocked")
                access["blocker"] = .string(authority.reason)
                return .object(access)
            }
            let admitted = authority.admitted
            let read = snapshot.allows(mac, mode: .read, fullMacAdmitted: admitted)
            let write = snapshot.allows(mac, mode: .write, fullMacAdmitted: admitted)
            access["effective_permission"] = .object(["read": .bool(read), "write": .bool(write)])
            access["stored_permission"] = .object(["read": .bool(stored.read), "write": .bool(stored.write)])
            access["full_mac_admitted"] = .bool(admitted)
            access["permission_state"] = .string(read || write ? "allowed" : "off")
            access["permission_blockers"] = .array([MacIntegrationPermissionMode.read, .write].compactMap {
                readiness.refusal(integration: mac, mode: $0).map(JSONValue.string)
            })
        } catch {
            access["permission_state"] = .string("unavailable")
            access["blocker"] = .string(error.localizedDescription)
        }
        return .object(access)
    }

    public static func quietService(_ page: QuietToolPage, _ service: (mac: String?, connectors: [String]),
                                    dataRoot: URL, platform: any ConnectorStatusPlatform,
                                    statusText: (ConnectorRecord) -> String, osAccess: (String) -> String) async -> [JSONValue] {
        var sections: [JSONValue] = []
        var lines: [String] = []
        let connectors: [ConnectorRecord]
        do { connectors = try await ConnectorStatusProjection.readConnectorRecords(root: dataRoot, platform: platform) }
        catch { return [quietPageSection(page.title, ["Unavailable: \(error.localizedDescription)"])] }
        if let mac = service.mac {
            let permissions: Result<MacIntegrationPermissionStore.Snapshot, Error>
            do { permissions = .success(try await MacIntegrationPermissionStore(dataRoot: dataRoot).snapshotChecked()) }
            catch { permissions = .failure(error) }
            sections.append(await quietMacAccess(mac, connectors: connectors, dataRoot: dataRoot,
                permissions: permissions, statusText: statusText, osAccess: osAccess))
        }
        for connector in connectors where service.connectors.map(ConnectorProofLedger.canonicalID).contains(ConnectorProofLedger.canonicalID(connector.id)) {
            lines.append("\(connector.name.isEmpty ? connector.id : connector.name): "
                + statusText(connector)
                + " · enabled \(connector.enabled ? "on" : "off")"
                + (connector.authState.map { " · \($0)" } ?? ""))
        }
        if lines.isEmpty, sections.isEmpty { lines.append("\(page.title) is not set up in Connectors.") }
        if !lines.isEmpty { sections.append(quietPageSection(page.title, lines)) }
        return sections
    }

    public static func quietPageContext(_ content: [JSONValue], pageID: String, model: String,
                                        providerID: String, dataRoot: URL, providers: ProvidersFacade) async -> [JSONValue] {
        var content = content
        if ["settings", "providers"].contains(pageID) {
            let turn = ChatTurnRuntimeContext.current
            let context = ChatSessionAutocompactionConfig.productionDefault().contextWindowReadout(
                forModel: turn?.model ?? model, providerID: turn?.providerID ?? providerID,
                dataRoot: dataRoot)
            if case .string(let summary)? = context["summary"] { content.append(quietPageSection("Context window", [summary])) }
        }
        let surfaces: [String] = switch pageID {
        case "chat": ["chat", "compaction"]
        case "memories": ["memory"]
        case "desk": ["desk", "workshop", "swarms"]
        case "diagnostics": ["diagnostics", "cognition_reflection", "training"]
        case "settings": ["dream", "rem", "self_improvement", "studio_wander", "heartbeat", "autonomy"]
        case "pairing": ["ios"]
        case "telegram": ["telegram"]
        case "slack": ["slack"]
        default: []
        }
        if !surfaces.isEmpty {
            do {
                let routing = try await providers.routing.checkedRoutingSnapshotReadOnly()
                let members = ProviderSurfaceGroups.all.flatMap(\.members).filter { surfaces.contains($0.surface) }
                content.append(quietPageSection("Models", quietModelLines(members, routing: routing)))
            } catch { content.append(quietPageSection("Models", ["Models could not be read: \(error.localizedDescription)"])) }
        }
        return content
    }

    public static func quietVirtualPage(_ page: QuietToolPage) -> [JSONValue]? {
        guard let read = virtualPageReads[page.id] else { return nil }
        let registered = AppActions.on(page: page.id).filter { $0.page == page.id }.map(\.id)
        return [quietPageSection(page.title, [page.summary, read,
            "This version covers this page's guidance and registered actions, not a file, command, tab, URL or screen."]),
            quietPageSection("Registered actions", registered)]
    }

    private static let virtualPageReads = [
        "files": "Read a folder with files.list {path}; read a file with files.read {path}. File and folder results carry their own versions and next arguments.",
        "shell": "Read repository state with git.status {path}. Run commands with shell.run; a page read runs no command.",
        "web": "Read a URL with web.read {url}; discover web.search with find. A page read fetches no URL and performs no search.",
        "browser": "Read current browser state with browser.status, then read a tab with the browser or Chrome actions. A page read opens no tab.",
        "mac": "Read the current screen with mac.look, or a document with mac.read. A page read captures no screen and moves no control.",
        "markets": "Market research uses native routes. Read market.status for configured data sources; use market.watchlists, market.quote or market.tradingview for their results.",
    ]
    public static func quietConnectors(dataRoot: URL, platform: any ConnectorStatusPlatform,
                                       workspaceCount: Int, telegramConfigured: Bool, statusText: (ConnectorRecord) -> String) async -> [JSONValue] {
        do {
            return quietConnectors(try await ConnectorStatusProjection.readConnectorRecords(root: dataRoot, platform: platform), workspaceCount: workspaceCount, telegramConfigured: telegramConfigured, statusText: statusText)
        } catch { return [quietPageSection("Connectors", ["Unavailable: \(error.localizedDescription)"])] }
    }

    public static func quietConnectors(_ connectors: [ConnectorRecord], workspaceCount: Int,
                                       telegramConfigured: Bool, statusText: (ConnectorRecord) -> String) -> [JSONValue] {
        var sections = [quietPageSection("Connectors", [
            quietCountLine(connectors.count, "connector", "connectors"),
            quietCountLine(workspaceCount, "workspace", "workspaces"),
            "Telegram: \(telegramConfigured ? "configured" : "not configured")",
        ])]
        sections.append(quietPageSection("Connector ids", connectors.isEmpty ? ["None."] : connectors.map {
            // The same word the Connectors page shows (Connected / Needs sign-in / Off …),
            // so she never has to open each connector to learn who needs a sign-in (10-10).
            "\($0.id): \($0.name)\($0.kind.isEmpty ? "" : " (\($0.kind))"): "
                + statusText($0)
                + " · enabled \($0.enabled ? "on" : "off")"
        }))
        return sections
    }

    public static func quietMacIntegration(dataRoot: URL, platform: any ConnectorStatusPlatform,
                                           workspaceCount: Int, telegramConfigured: Bool,
                                           statusText: (ConnectorRecord) -> String, osAccess: (String) -> String) async -> [JSONValue] {
        let connectors: [ConnectorRecord]
        do { connectors = try await ConnectorStatusProjection.readConnectorRecords(root: dataRoot, platform: platform) }
        catch { return [quietPageSection("Connection readiness", ["Unavailable: \(error.localizedDescription)"])] }
        var capabilities: [JSONValue] = []
        let permissions: Result<MacIntegrationPermissionStore.Snapshot, Error>
        do { permissions = .success(try await MacIntegrationPermissionStore(dataRoot: dataRoot).snapshotChecked()) }
        catch { permissions = .failure(error) }
        for mac in MacIntegrationID.all {
            capabilities.append(await quietMacAccess(mac, connectors: connectors, dataRoot: dataRoot,
                permissions: permissions, statusText: statusText, osAccess: osAccess))
        }
        var overview: [JSONValue] = [.object(["heading": .string("Mac Integration"), "capabilities": .array(capabilities),
            "note": .string("Supported routes, effective permission, connection readiness and OS access are separate facts. OS access uses live nonprompting status where available; unverified is unknown, not denied. No app or content was probed; no permission was requested.")])]
        overview += quietConnectors(connectors, workspaceCount: workspaceCount, telegramConfigured: telegramConfigured, statusText: statusText)
        return overview
    }

    public static func quietMemories(_ memory: MemoryFacade, keptLine: String, graphEntityCount: Int) -> [JSONValue] {
        let memories = memory.memories
        var head = [keptLine]
        head.append(quietCountLine(memory.proposals.count, "proposal waiting", "proposals waiting"))
        head.append(quietCountLine(graphEntityCount, "thing in the graph", "things in the graph"))
        head.append(contentsOf: MemoryStatusProjection.afterTurnRecovery(dataRoot: PersistenceCore.defaultDataRoot()).lines)
        var sections = [quietPageSection("Memories", head)]
        if !memories.isEmpty {
            sections.append(quietPageSection("Kept", memories.prefix(20).map { record in
                let first = record.text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? record.text
                return "\(record.layer ?? ""): \(first)"
            }))
        }
        if !memory.proposals.isEmpty {
            sections.append(quietPageSection("Waiting", memory.proposals.prefix(12).map(\.content)))
        }
        return sections
    }

    public static func quietPersonality(name: String?, currentPersona: String, documents: [PersonaDocSpec], dataRootOverride: URL?) async -> [JSONValue] {
        var head: [String] = []
        if let name { head.append("Name: \(name)") }
        head.append("Current persona name: \(currentPersona).")
        head.append(quietCountLine(documents.count, "document", "documents"))
        var sections = [quietPageSection("Personality", head)]
        do {
            let persona = dataRootOverride.map(SwiftNativePersonaEngine.isolated(dataRoot:)) ?? SwiftNativePersonaEngine()
            let names = try PersonaCompiler.customPersonaNames(root: await persona.personaRoot)
            sections.append(quietPageSection("Custom names for persona.set", names.isEmpty ? ["None."] : names))
        } catch { sections.append(quietPageSection("Custom personas", ["Unavailable: \(error.localizedDescription)"])) }
        do {
            let consults = try await SwiftNativeStudioStore(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()).listConsults()
            sections.append(quietPageSection("Consult ids for studio.consult_read", consults.isEmpty ? ["None."]
                : consults.map { "\($0.id): \($0.question) · \($0.descriptionOnly ? "description only" : "has artifacts")" }))
        } catch { sections.append(quietPageSection("Consults", ["Unavailable: \(error.localizedDescription)"])) }
        if !documents.isEmpty {
            sections.append(quietPageSection("Documents", documents.map { doc in
                let first = doc.content.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? ""
                return "\(doc.title): \(first)"
            }))
        }
        return sections
    }
    public static func quietChatCards(_ collapsed: InlineInteractionResolver.CollapsedCards, dataRoot: URL) async -> [JSONValue] {
        var sections: [JSONValue] = []
        let pairs = collapsed.pairs
        guard !pairs.isEmpty else { return sections }
        sections.append(quietPageSection(
            "Cards",
            [collapsed.heading
                + " in this conversation. card.answer answers one by its id."]
        ))
        for pair in pairs {
            let descriptor = InlineInteractionResolver.descriptor(
                for: pair.interaction, dataRoot: dataRoot
            )
            // The same live read as the glass: done elsewhere reads as done.
            let card = InlineCardProjection.model(
                await InlineInteractionResolver.liveProjection(pair.interaction, dataRoot: dataRoot),
                descriptor: descriptor,
                repeatCount: collapsed.counts[pair.interaction.id] ?? 1
            )
            // The glass does not draw a settled card as a card. It draws ONE
            // line — the receipt, the refusal, or "Asked earlier" — and only a
            // card still waiting on the person carries the reason, the scope
            // lines and the two buttons. A projection that gave every row the
            // full body told Agent there were six live questions in a
            // conversation that shows one (Agent, 2026-09-13). The interaction
            // id stays on every line: a quiet card is still addressable.
            switch card.state {
            case .superseded:
                // "Asked earlier" is the superseded line and ONLY the
                // superseded line: a newer identical ask took this one's
                // place, so there is nothing to answer here.
                sections.append(quietPageSection(card.title, [
                    // Every other branch leads with the state; this one read as
                    // a bare "Asked earlier." with nothing saying what state
                    // that is (Agent, 2026-09-14).
                    "State: " + card.state.rawValue,
                    "Asked earlier — a newer copy of this ask took its place.",
                    "Interaction id: \(card.id)",
                    "On message: \(pair.rowID)",
                ]))
                continue
            case .unknown:
                // Terminal, but not because anybody answered it: this build
                // has no control for the thing. Say that, with the reason the
                // glass shows, instead of "asked earlier".
                var lines: [String] = ["State: unknown"]
                if let outcome = card.outcome { lines.append(outcome) }
                if let meta = card.outcomeMeta { lines.append(meta) }
                lines.append("Interaction id: \(card.id)")
                lines.append("On message: \(pair.rowID)")
                sections.append(quietPageSection(card.title, lines))
                continue
            case .declined, .settled:
                var receipt: [String] = ["State: \(card.state.rawValue)"]
                if let outcome = card.outcome { receipt.append(outcome) }
                if let meta = card.outcomeMeta { receipt.append(meta) }
                receipt.append("Interaction id: \(card.id)")
                receipt.append("On message: \(pair.rowID)")
                sections.append(quietPageSection(card.title, receipt))
                continue
            case .pending, .running, .failed:
                // A failure settled NOTHING — on the glass it keeps its card,
                // its explanation, its field and its "Try again" — so it is
                // projected with those too, not as a receipt.
                break
            }
            var lines: [String] = ["State: \(card.state.rawValue)"]
            if !card.why.isEmpty { lines.append("Why: \(card.why)") }
            lines.append(contentsOf: card.scopeLines)
            if card.state == .failed && !card.canRetry {
                // The one failure with nothing to offer: no control on this
                // build, so naming buttons that are not drawn would be a lie.
                lines.append("There is no control for this on this build, so it can't be answered here.")
            } else {
                lines.append("Do: \(card.state == .failed ? "Try again" : card.primaryLabel)")
                // Joined mid-sentence after a dash, so it takes the same
                // lowercased lead the settled decline line takes — "Not now —
                // Without Notion…" read as a new sentence beside "Not now —
                // without Notion…" (Agent, 2026-09-14).
                lines.append(
                    "Or: \(card.secondaryLabel) — "
                        + InlineInteraction.lowercasedLead(
                            card.consequence.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                )
            }
            if let note = card.persistenceNote { lines.append(note) }
            if let signIn = card.signInLabel { lines.append("Offers: \(signIn)") }
            for field in card.fields {
                lines.append(
                    "Takes: \(field.label)\(field.isSecret ? " (secret — the person types it into the card, never into chat)" : "")"
                )
            }
            for choice in card.choices {
                lines.append("Choice \(choice.id): \(choice.title)"
                    + (choice.note.map { " — \($0)" } ?? ""))
            }
            if let outcome = card.outcome { lines.append("Outcome: \(outcome)") }
            if let meta = card.outcomeMeta { lines.append(meta) }
            lines.append("Interaction id: \(card.id)")
            lines.append("On message: \(pair.rowID)")
            sections.append(quietPageSection(card.title, lines))
        }
        return sections
    }

    public static func quietDesk(desk: DeskFacade) async -> [JSONValue] {
        let snapshot = await Task.detached(priority: .userInitiated) {
            await DeskPageSnapshot.load(desk: desk)
        }.value
        guard snapshot.loaded else {
            return [quietPageSection("Desk", [snapshot.deskUnavailable ?? "The board could not be read."])]
        }
        let items = snapshot.items
        let waiting = DeskPageContent.waitingOnOwner(items)
        let blocked = DeskPageContent.blocked(items)
        let active = DeskPageContent.active(items)
        // `stuckReason` answers "why is this stuck" and always answers; asking
        // it about a row that is not stuck would print a blocked line over a
        // healthy item. Only the two stuck lanes ask.
        func rows(_ list: [DeskItem], stuck: Bool = false) -> [String] {
            list.prefix(20).map { item in
                let line = "desk.\(item.alias) \(item.status.rawValue) · \(DeskPageContent.title(item)) [\(item.project)]"
                guard stuck else { return line }
                let reason = DeskPageContent.stuckReason(item, in: items)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return reason.isEmpty ? line : "\(line) — \(reason)"
            }
        }
        var sections = [quietPageSection("Desk", [
            DeskState(items: items, generatedTs: snapshot.generatedTs ?? "").boardCountSummary,
            quietCountLine(waiting.count, "item waiting on you", "items waiting on you"),
            quietCountLine(blocked.count, "item blocked", "items blocked"),
        ])]
        if !waiting.isEmpty { sections.append(quietPageSection("Waiting on you", rows(waiting, stuck: true))) }
        if !blocked.isEmpty { sections.append(quietPageSection("Blocked", rows(blocked, stuck: true))) }
        if !active.isEmpty { sections.append(quietPageSection("In play", rows(active))) }
        return sections
    }

    public static func quietAgents(dataRoot: URL) -> [JSONValue] {
        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot, allowProcessGlobalTools: false)
        let usable = Set(["codex", "claude", "omp"].filter { dispatcher.builtInAgentLaneUsable($0) })
        guard let peers = try? AgentPeerStore(dataRoot: dataRoot).list() else {
            return [quietPageSection("Agents", ["Contacts and trusted switches could not be read."])]
        }
        let rows = AgentContactRow.rows(peers: peers, candidates: [], usable: usable, dataRoot: dataRoot)
        var sections = [quietPageSection("Agents", [quietCountLine(rows.count, "contact", "contacts")])]
        if !rows.isEmpty {
            sections.append(quietPageSection("Contacts", rows.map { "\($0.displayName): \($0.pillWord) · \($0.status)" }))
        }
        if !peers.isEmpty {
            sections.append(quietPageSection("Trusted switches", peers.map { "\($0.name): trusted \($0.elevationAllowed ? "on" : "off")" }))
        }
        return sections
    }

    public static func quietSettings(agentName: String, providerID: String, model: String, fileAccess: String, status: String) -> [JSONValue] {
        [quietPageSection("Settings", [
            "Agent name: \(agentName)",
            "Chat runs on: \(providerID) · \(model)",
            "File access: \(fileAccess)",
            "Status line: \(status)",
        ])]
    }

    public static func quietProviders(routing: ProviderRoutingSnapshot, providers: [ProviderInfo]) -> [JSONValue] {
        var sections: [JSONValue] = []
        for group in ProviderSurfaceGroups.all {
            sections.append(quietPageSection(group.title, RuntimeReadProjection.quietModelLines(group.members, routing: routing)))
        }
        let accounts = providers.map { info -> String in
            let mode = info.auth_mode.map { " via \($0)" } ?? ""
            return "\(info.display_name): \(info.auth_status.state) — \(info.auth_status.detail)\(mode)"
        }
        sections.append(quietPageSection("Accounts", accounts.isEmpty ? ["No providers listed."] : accounts))
        return sections
    }

    public static func quietTrust(trust: TrustFacade, dataRoot: URL, presetTitle: (TrustPolicy, String) -> String, guardrailLines: (TrustPolicy, String) -> [String]) -> [JSONValue] {
        guard let policy = trust.policy else {
            return [quietPageSection("Trust", ["No Trust policy has loaded."])]
        }
        let mode = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy)
        var head = ["Preset: \(presetTitle(policy, mode))", "Agent access: \(mode)"]
        head.append("Mac control: \(policy.macControlPolicy?.enabled == true ? "on" : "off")")
        var sections = [quietPageSection("Trust", head)]
        let rows = guardrailLines(policy, mode)
        if !rows.isEmpty {
            sections.append(quietPageSection("Guardrails", rows))
        }
        sections.append(quietPageSection("Backup ids for backup.restore", trust.backups.isEmpty ? ["None."]
            : trust.backups.map { "\($0.id): \($0.createdAt) · \($0.reason)" }))
        do {
            let legacy = try TrustBackupPersistence.readLegacyBackupRecords(root: dataRoot)
            if !legacy.isEmpty {
                sections.append(quietPageSection("Legacy daemon backups", legacy.map { "\($0.id): \($0.createdAt) · \($0.reason)" }))
            }
        } catch { sections.append(quietPageSection("Legacy daemon backups", ["Unavailable: \(error.localizedDescription)"])) }
        return sections
    }

    public static func quietCapabilities(trust: TrustFacade, approvals: ApprovalsFacade, workflowCount: Int, mcpServerCount: Int, actionCount: Int) -> [JSONValue] {
        [quietPageSection("Capabilities", [
            quietCountLine(trust.capabilitySummary?.records.count ?? 0, "capability", "capabilities"),
            quietCountLine(workflowCount, "workflow", "workflows"),
            quietCountLine(mcpServerCount, "MCP server", "MCP servers"),
            quietCountLine(actionCount, "action", "actions"),
            quietCountLine(approvals.records.filter { $0.status.lowercased() == "pending" }.count,
                      "approval waiting", "approvals waiting"),
        ])]
    }

    public static func quietBots(dataRoot: URL, stateWord: (BotsShelfRecord, Bool, Bool) -> String) async -> [JSONValue] {
        let unattended = await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot)
        let loaded = try? await Task.detached(priority: .userInitiated) {
            (records: try BotsShelfRecord.read(root: dataRoot, unattended: unattended),
             runs: try BotRunQueue(dataRoot: dataRoot).activeAndQueuedIDs())
        }.value
        guard let loaded else {
            return [quietPageSection("Helpers", ["The shelf could not be read."])]
        }
        var sections: [JSONValue] = []
        var header = [quietCountLine(loaded.records.count, "helper", "helpers") + " on the shelf."]
        if !unattended { header.append(BotsShelfUnattended.pageLine) }
        sections.append(quietPageSection("Helpers", header))
        for record in loaded.records {
            let state = stateWord(record, loaded.runs.active.contains(record.id), loaded.runs.queued.contains(record.id))
            var lines: [String] = ["State: \(state)"]
            let brief = record.definition.brief
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            if let brief { lines.append("Brief: \(brief)") }
            // "Sep 10 at 1:47 AM · Reply saved: …" — the dated first line of
            // what it last said, exactly as the card prints it.
            lines.append("Latest: \(record.lastOutcomeLine)")
            lines.append("Schedule: \(record.scheduleLine)")
            lines.append("Timing: \(record.timingLine)")
            lines.append("Runs on: \(record.choiceLine)")
            if let missed = record.missedLine { lines.append(missed) }
            if let wake = record.wakeLine { lines.append(wake) }
            lines.append(quietCountLine(record.entries.count, "run recorded", "runs recorded"))
            sections.append(quietPageSection(record.definition.name, lines))
        }
        return sections
    }

}
