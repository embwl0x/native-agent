import ApprovalTransactions
import AppToolRuntime
import BackgroundWork
import AgentWorkspace
import Agents
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import ChatToolParsing
import Connectors
import DeviceSync
import Desk
import Foundation
import MacControl
import MacIntegration
import MemoryV2
import NotificationInbox
import PersonaEngine
import StandingBots
import Studio
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import TrustCenter
import TrustPersistence
import ToolExecution
import Experiences
// Blueprint: | `RuntimeReadProjection+QuietPages.swift` | Shared semantic pages; permission-card pointers read ForPerson's in-memory inbox |

@MainActor
extension RuntimeReadouts {
    public static func quietPages() -> [QuietToolPage] { QuietToolPage.all }

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

    /// Keep failure and recovery structured, outside the section’s 200-character summary cap.
    public static func quietPageIssue(_ heading: String, reason: String, detail: String,
                                      instruction: String, next: [String: JSONValue]? = nil,
                                      tap: String? = nil, status: String = "unavailable",
                                      error: (any Error)? = nil) -> JSONValue {
        let remedy: JSONValue
        if status == "waiting", let tap {
            remedy = Repair.why(owner: heading, tap: tap, instruction: instruction)
        } else {
            remedy = Repair.remedy(owner: heading,
                nextCall: next.map { .object(["tool": .string("app"), "input": .object($0)]) },
                tap: tap, instruction: instruction)
        }
        var face: [String: JSONValue] = [
            "heading": .string(heading), "lines": .array([]),
            "status": .string(status), "reason": .string(reason), "detail": .string(detail),
            "remedy": remedy,
        ]
        if let error, case .object(let evidence) = ChatToolOutcome.failure(error: error, effects: ToolFailureError.Effects.none) {
            face.merge(evidence) { _, owned in owned }
            if evidence["reason"] == .string("dispatch_error") {
                face["reason"] = .string(reason)
                face["failure_code"] = .string(reason)
            }
        }
        return .object(face)
    }

    public static func quietCountLine(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? "1 \(one)" : "\(count) \(many)"
    }

    public static func quietModelLines(_ members: [ProviderSurfaceMember], routing: ProviderRoutingSnapshot) -> [String] {
        members.map { member in
            if routing.unusablePickNotice(for: member.surface) != nil { return "\(member.label): model unavailable" }
            let provider = routing.activeProviders[member.surface] ?? "same as Chat"
            guard let preference = routing.preferences[member.surface] else {
                return "\(member.label): \(provider) · no model pinned"
            }
            let fast = preference.serviceTier == "priority" ? "Fast on" : "Fast off"
            let think = preference.reasoningEffort.isEmpty ? "no thinking level" : "Think \(preference.reasoningEffort)"
            return "\(member.label): \(provider) · \(preference.model) · \(think) · \(fast)"
        }
    }

    private static func quietModelIssues(_ members: [ProviderSurfaceMember], routing: ProviderRoutingSnapshot) -> [JSONValue] {
        members.compactMap { member in
            routing.unusablePickNotice(for: member.surface).map { issue in
                quietPageIssue(member.label, reason: "provider_pick_unusable", detail: issue,
                    instruction: "Choose an available account and model in this activity's Providers group.", tap: "Providers")
            }
        }
    }

    public static func quietNotifications(_ inbox: InboxFacade) -> [JSONValue] {
        var sections = [quietPageSection("Notification preferences", [
            "The notification switches and trigger settings are on this page.",
            "Read the shared Inbox face for requests and news: app {page:\"inbox\"}.",
        ])]
        if let error = inbox.triggerError {
            sections.append(quietPageIssue("Notification triggers", reason: "triggers_read_failed", detail: error,
                instruction: "Resolve the reported trigger read problem, then reload Notifications.",
                next: ["page": .string("notifications")], status: inbox.triggersRead ? "stale" : "unavailable"))
        } else if !inbox.triggersRead {
            sections.append(quietPageIssue("Notification triggers", reason: "triggers_not_loaded",
                detail: "Notification triggers have not loaded.", instruction: "Read Notifications to load the trigger settings.",
                next: ["page": .string("notifications")], status: "not_loaded"))
        }
        if inbox.triggersRead {
            sections.append(quietPageSection("Triggers", inbox.triggerRows.map {
                $0.name + ": " + ($0.enabled ? "on" : "off")
            }))
        }
        return sections
    }

    public static func quietTelegram(_ telegram: TelegramFacade) -> [JSONValue] {
        guard let status = telegram.status else {
            return [quietPageIssue("Telegram", reason: "telegram_status_not_loaded",
                detail: "Telegram's status has not loaded.", instruction: "Read Telegram to load its status.",
                next: ["page": .string("telegram")], status: "not_loaded")]
        }
        var lines = [
            "Telegram: \(status.enabled ? "on" : "off") · bot token \(status.tokenConfigured ? "saved" : "not saved")",
            "Only answers when mentioned in a group: \(status.requireMention ? "yes" : "no")",
            quietCountLine(status.allowedChatIds.count, "allowed chat", "allowed chats")
                + ", " + quietCountLine(status.allowedUserIds.count, "allowed user", "allowed users"),
            status.routingIssue.map { "Routing unavailable: \($0)" }
                ?? "Model: \(status.model ?? "unavailable") · Think \(status.reasoningEffort ?? "default")",
        ]
        if let at = status.lastReplyAt { lines.append("Last reply: \(at)") }
        var sections = [quietPageSection("Telegram", lines)]
        if !status.tokenConfigured {
            sections.append(quietPageIssue("Telegram token", reason: "telegram_token_missing",
                detail: "No bot token is saved.", instruction: "The owner saves the bot token in Telegram, never in chat.",
                tap: "Connectors → Telegram → Bot token"))
        } else if !status.enabled {
            sections.append(quietPageIssue("Telegram", reason: "telegram_disabled",
                detail: "Telegram is off.", instruction: "Waiting on the owner to enable Telegram if wanted.",
                tap: "Connectors → Telegram → Telegram is on", status: "waiting"))
        } else if !status.pollerEnabled {
            sections.append(quietPageIssue("Telegram poller", reason: "telegram_poller_not_running",
                detail: "Telegram is enabled, but its poller is not running.",
                instruction: "Read Doctor's Telegram check to identify what stopped the poller.",
                next: ["action": .string("doctor.run")]))
        }
        if let error = status.lastError, !error.isEmpty {
            sections.append(.object(["heading": .string("Last Telegram error"), "status": .string("last_reported"),
                "reason": .string("telegram_last_error"), "detail": .string(error),
                "remedy": Repair.terminal(
                    instruction: """
                        A last reported error is not proof of a current failure. Read app {page:\"telegram\",item:\"status\"} for current health before \
                        acting.
                        """)]))
        }
        return sections
    }

    public static func quietPairing(_ sync: SyncFacade, dataRoot: URL) async -> [JSONValue] {
        var head = ["iCloud: \(sync.status)"]
        let phones = sync.phones.filter { $0.status != .removed }
        if let standing = sync.standing { head.append(standing.line) }
        var sections = [quietPageSection("iPhone pairing", head)]
        if let standing = sync.standing, standing.waiting > 0 {
            sections.append(quietPageIssue("iPhone pairing", reason: "phone_waiting_to_pair", detail: standing.line,
                instruction: """
                    A phone is waiting for the owner to match its code and choose Pair; only the owner's Pair button lets it approve. Raise the pairing \
                    card (request_interaction kind=connector target=iphone) so it reaches them where they are.
                    """,
                tap: "Connectors → iPhone → Paired devices → Pair", status: "waiting"))
        }
        if let error = sync.pairingError {
            sections.append(quietPageIssue("iPhone pairing", reason: "pairing_unavailable", detail: error,
                instruction: "The owner checks iCloud and the pairing status on both devices using the same Apple Account. Keep the pairing key out of chat.",
                tap: "Connectors → iPhone → Connection"))
        }
        if !phones.isEmpty {
            sections.append(quietPageSection("Phones", phones.map { "\($0.id): \($0.status == .paired ? "can approve" : "waiting for Pair")" }))
        }
        do {
            let phone = try await SwiftNativeAPNSSender().notificationReadiness(dataRoot: dataRoot)
            if phone.supported {
                sections.append(quietPageSection("Notifications", [phone.detail]))
            } else {
                let instruction: String
                let tap: String?
                switch phone.status {
                case "not_paired":
                    instruction = "The owner opens the companion app, checks the phone's code and chooses Pair on this Mac."
                    tap = "Connectors → iPhone → Paired devices → Pair"
                default:
                    instruction = "Read Doctor's phone-notification check and the latest delivery evidence before sending another notification."
                    tap = nil
                }
                sections.append(quietPageIssue("Notifications", reason: "phone_notifications_" + phone.status,
                    detail: phone.detail, instruction: instruction,
                    next: tap == nil ? ["action": .string("doctor.run")] : nil, tap: tap, status: phone.status))
            }
        } catch {
            sections.append(quietPageIssue("Notifications", reason: "phone_notification_evidence_unavailable",
                detail: error.localizedDescription,
                    instruction: """
                        Inspect Doctor's phone-notification check for the unreadable evidence path; repair that file without deleting delivery history.
                        """,
                next: ["action": .string("doctor.run")], error: error))
        }
        return sections
    }

    public static let quietServicePages: [String: (mac: String?, connectors: [String])] = [
        "mail": (MacIntegrationID.mail, ["local_mail"]),
        "calendar": (MacIntegrationID.calendar, ["local_calendar"]),
        "reminders": (MacIntegrationID.reminders, ["local_reminders"]),
        "notes": (MacIntegrationID.notes, []), "contacts": (MacIntegrationID.contacts, []),
        "messages": (MacIntegrationID.messages, []), "music": (MacIntegrationID.music, []),
        "slack": (nil, ["slack"]),
    ]

    public static func quietMacAccess(_ mac: String, connectors: [ConnectorRecord], dataRoot: URL,
                                      permissions: Result<MacIntegrationPermissionStore.Snapshot, Error>,
                                      authority: FullMacYoloAuthorityAssessment, systemStatuses: [String: String], statusText: (
                                          ConnectorRecord) -> String) async -> JSONValue {
        let catalogRoutes: [JSONValue]
        do { catalogRoutes = try AppActions.integrationRoutes(mac) }
        catch { return quietPageIssue("Mac access", reason: "action_catalog_unavailable",
            detail: error.localizedDescription, instruction: "Repair the action catalog before reading supported routes.", error: error) }
        let routes = catalogRoutes.map { route -> JSONValue in
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
        access["verified_os_access"] = .string(systemStatuses[mac] ?? "unverified")
        // Share one engine read across automation rows and macOS grants.
        let appName = MacIntegrationID.displayName(for: mac)
        if AppleScriptExecution.automationTargetApps.contains(appName) {
            access["verified_os_access"] = .string(systemStatuses["apple_events_\(appName.lowercased())"] ?? "unknown")
        }
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
            guard let stored = snapshot.permissions[mac] else {
                throw RuntimeReadError.unreadableFeed("Mac permission snapshot omitted \(mac).")
            }
            let readiness = snapshot.readiness
            access["full_mac_admission"] = .string(authority.state.rawValue)
            access["full_mac_reason"] = .string(authority.reason)
            if authority.state == .unavailable || authority.state == .explicitlyBlocked {
                access["permission_state"] = .string(authority.state == .unavailable ? "unavailable" : "blocked")
                access["blocker"] = .string(authority.reason)
                return .object(access)
            }
            let admitted = authority.admitted
            let read = snapshot.allows(mac, mode: .read)
            let write = snapshot.allows(mac, mode: .write)
            access["effective_permission"] = .object(["read": .bool(read), "write": .bool(write)])
            access["stored_permission"] = .object(["read": .bool(stored.read), "write": .bool(stored.write)])
            access["full_mac_admitted"] = .bool(admitted)
            access["permission_state"] = .string(read || write ? "allowed" : "off")
            let blockers = [MacIntegrationPermissionMode.read, .write].compactMap { readiness.refusal(integration: mac, mode: $0) }
            access["permission_blockers"] = .array(blockers.map(JSONValue.string))
            // Respect owner switches, including Full Mac, and retain hold reasons.
            func words(_ read: Bool, _ write: Bool) -> String {
                read && write ? "read and write" : read ? "read-only" : write ? "write-only" : "off"
            }
            access["in_effect"] = .string(words(read, write) + ", your switches"
                + (admitted ? " (Full Mac does not change them)" : "")
                + (blockers.isEmpty ? "" : "; held back by: " + blockers.joined(separator: "; ")))
        } catch {
            access["permission_state"] = .string("unavailable")
            access["blocker"] = .string(error.localizedDescription)
        }
        return .object(access)
    }

    public static func quietService(_ page: QuietToolPage, _ service: (mac: String?, connectors: [String]),
                                    connectors owner: ConnectorReadiness,
                                    macIntegration: MacIntegrationFacade,
                                    statusText: (ConnectorRecord) -> String, turn: Turn?) async -> [JSONValue] {
        var sections: [JSONValue] = []
        var lines: [String] = []
        let connectors: [ConnectorRecord]
        do { connectors = try await owner.refresh().get() }
        catch { return [quietPageIssue(page.title, reason: "connection_read_failed", detail: error.localizedDescription,
            instruction: "Inspect Doctor's connector checks and resolve the reported read problem before changing this connection.",
            next: ["action": .string("doctor.run")], error: error)] }
        if let mac = service.mac {
            await macIntegration.refresh()
            if let permissions = macIntegration.checkedPermissions {
                let authority = await SwiftNativeSecurityCenter(dataRoot: owner.root).fullMacYoloAuthority(
                    origin: .currentTurn(turn: turn, surface: turn?.envelope?.surface
                        ?? "chat"), turn: turn)
                sections.append(await quietMacAccess(mac, connectors: connectors, dataRoot: owner.root,
                    permissions: permissions, authority: authority, systemStatuses: macIntegration.systemStatuses, statusText: statusText))
            }
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
                                        providerID: String, dataRoot: URL, providers: ProvidersFacade, turn: Turn?) async -> [JSONValue] {
        var content = content
        if pageID == "settings" {
            do {
                let context = try await ContextWindowPolicy.readout(
                    forModel: turn?.runtime?.model ?? turn?.admission?.model ?? model,
                    providerID: turn?.runtime?.providerID ?? turn?.admission?.provider ?? providerID,
                    dataRoot: dataRoot,
                    call: .init(turn: turn, surface: turn?.envelope?.surface ?? "chat", purpose: "context_window"))
                if case .string(let summary)? = context["summary"] { content.append(quietPageSection("Context window", [summary])) }
            } catch {
                content.append(quietPageSection("Context window", ["Unavailable: \(error.localizedDescription)"]))
            }
        }
        let surfaces: [String] = switch pageID {
        case "chat": ["chat"]
        case "memories": ["memory"]
        case "desk": ["desk", "workshop"]
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
                content += quietModelIssues(members, routing: routing)
            } catch { content.append(quietPageIssue("Models", reason: "provider_routing_unavailable",
                detail: error.localizedDescription, instruction: "Open Providers and resolve the reported routing problem.",
                tap: "Providers", error: error)) }
        }
        return content
    }

    public static func quietVirtualPage(_ page: QuietToolPage, turn: Turn?) -> [JSONValue]? {
        guard let read = virtualPageReads[page.id] else { return nil }
        let registered: [String]
        do { registered = try AppActions.on(page: page.id, turn: turn).filter { $0.page == page.id }.map(\.id) }
        catch { return [quietPageIssue(page.title, reason: "action_catalog_unavailable",
            detail: error.localizedDescription, instruction: "Repair the action catalog before reading registered actions.", error: error)] }
        return [quietPageSection(page.title, [page.summary, read,
            "This version covers this page's guidance and registered actions, not a file, command, tab, URL or screen."]),
            quietPageSection("Registered actions", registered)]
    }

    private static let virtualPageReads = [
        "files": """
            Read a folder with files.list {path}; read a file with files.read {path}. File and folder results carry their own versions and next \
            arguments.
            """,
        "shell": "Read repository state with git.status {path}. Run commands with shell.run; a page read runs no command.",
        "web": "Read a URL with web.read {url}; search with web.search {query}. A page read fetches no URL and performs no search.",
        "browser": "Read current browser state with browser.status, then read a tab with the browser or Chrome actions. A page read opens no tab.",
        "mac": "Read the current screen with mac.look, or a document with mac.read. A page read captures no screen and moves no control.",
    ]
    public static func quietConnectors(_ connectors: [ConnectorRecord], workspaceCount: Int?, workspaceError: String?,
                                       statusText: (ConnectorRecord) -> String) -> [JSONValue] {
        var sections = [quietPageSection("Connectors", [
            quietCountLine(connectors.count, "connector", "connectors"),
        ])]
        if let workspaceCount {
            sections.append(quietPageSection("Workspaces", [quietCountLine(workspaceCount, "workspace", "workspaces")]))
        } else {
            sections.append(quietPageIssue("Workspaces", reason: "workspaces_unavailable",
                detail: workspaceError ?? "Workspaces have not been read.",
                instruction: "Repair the reported workspace read problem, then reload Connectors.", next: ["page": .string("connectors")]))
        }
        sections.append(quietPageSection("Connector ids", connectors.isEmpty ? ["None."] : connectors.map {
            // Share connector status wording so sign-in needs are visible without opening each row.
            "\($0.id): \($0.name)\($0.kind.isEmpty ? "" : " (\($0.kind))"): "
                + statusText($0)
                + " · enabled \($0.enabled ? "on" : "off")"
        }))
        return sections
    }

    public static func quietMacIntegration(connectors owner: ConnectorReadiness,
                                           macIntegration: MacIntegrationFacade,
                                           statusText: (ConnectorRecord) -> String, turn: Turn?) async -> [JSONValue] {
        let connectors: [ConnectorRecord]
        do { connectors = try await owner.refresh().get() }
        catch { return [quietPageIssue("Connection readiness", reason: "connection_readiness_unavailable", detail: error.localizedDescription,
            instruction: "Inspect Doctor's connector checks and resolve the reported read problem before changing Mac access.",
            next: ["action": .string("doctor.run")], error: error)] }
        var capabilities: [JSONValue] = []
        await macIntegration.refresh()
        guard let permissions = macIntegration.checkedPermissions else {
            return []
        }
        let systemStatuses = macIntegration.systemStatuses
        let authority = await SwiftNativeSecurityCenter(dataRoot: owner.root).fullMacYoloAuthority(
            origin: .currentTurn(turn: turn, surface: turn?.envelope?.surface ?? "chat"), turn: turn)
        for mac in MacIntegrationID.all {
            capabilities.append(await quietMacAccess(mac, connectors: connectors, dataRoot: owner.root,
                permissions: permissions, authority: authority, systemStatuses: systemStatuses, statusText: statusText))
        }
        var overview: [JSONValue] = [.object(["heading": .string("Mac Integration"), "capabilities": .array(capabilities),
            "note": .string("""
                Routes, permission, connection and macOS access are separate. Live OS status is read without prompting where supported; unverified \
                means unknown. No app or content probe; no permission request.
                """)]),
            .object(["heading": .string("macOS grants"), "grants": .array(await quietMacOSGrants(systemStatuses)),
                "note": .string("""
                    Your reach on this Mac, read live at this page read without prompting, as the permission card reads it, in the order a card asks. \
                    Every reach row not granted goes on ONE card: permissions.request {capability: <its first target>, also_needed: [<the other \
                    targets>]}. A grant that takes effect after one restart is restarted by the card on the person's tap. Automation rows are asked \
                    in context, the first time that app is needed. Full Mac is the person's own switch in Trust; no card turns it on.
                    """)])]
        overview.append(await quietRunningGrantCards(dataRoot: owner.root))
        overview += quietConnectors(connectors, workspaceCount: owner.workspacesReadError == nil ? owner.workspaceSnapshot?.count : nil,
            workspaceError: owner.workspacesReadError, statusText: statusText)
        return overview
    }

    /// The macOS grants that make up the agent's reach on this Mac. Automation is per app and asked in context, so it is not part of the reach.
    static let reachGrants: [SystemPermissionCapability] = [.notifications, .calendars, .reminders, .contacts, .microphone, .speechRecognition,
        .accessibility, .screenRecording, .inputMonitoring, .fullDiskAccess]

    /// Read grants live from macOS, never from saved copies. A reach row reads what the permission card reads, in the card's own order and words: granted
    /// only when the card would not wait on it, and a launch-applied grant this process did not launch with says it takes effect after one restart.
    static func quietMacOSGrants(_ systemStatuses: [String: String]) async -> [JSONValue] {
        var grants: [JSONValue] = []
        for target in SystemPermissionPreflight.frictionOrder(reachGrants.map { "privacy:" + $0.rawValue }) {
            guard let gate = SystemPermissionPreflight.cardSettingsCapability(target) else { continue }
            var row: [String: JSONValue] = ["grant": .string(gate.displayName), "target": .string(target)]
            if let waiting = await SystemPermissionPreflight.cardBlockReason([target], mode: nil) {
                row["state"] = .string("not granted")
                row["detail"] = .string(waiting)
                row["turn_on"] = .string(SystemPermissionPreflight.settingsPath(gate))
            } else {
                row["state"] = .string(SystemPermissionPreflight.launchPending([target]).isEmpty ? "granted" : "granted, takes effect after one restart")
            }
            grants.append(.object(row))
        }
        for app in AppleScriptExecution.automationTargetApps {
            guard let bundleID = AppleScriptExecution.automationTargetBundleIDs[app] else { continue }
            let state = systemStatuses["apple_events_\(app.lowercased())"] ?? "unknown"
            var row: [String: JSONValue] = ["grant": .string("Automation for \(app)"), "state": .string(state),
                "target": .string("applescript:" + bundleID)]
            if state != SystemPermissionStatus.granted.rawValue { row["asked"] = .string("in context, the first time \(app) is needed") }
            grants.append(.object(row))
        }
        return grants
    }

    /// What each running permission card waits on, in the words the card itself shows. The Inbox points at every card that still needs the person; the
    /// card's own transcript row owns its state.
    static func quietRunningGrantCards(dataRoot: URL) async -> JSONValue {
        let heading = "Running permission cards"
        let rows: [InboxItemRecord]
        do { rows = try await ForPerson.at(dataRoot).inbox() }
        catch { return quietPageIssue(heading, reason: "inbox_unreadable", detail: error.localizedDescription,
            instruction: "Repair the reported Inbox read problem; until then what a running card waits on shows only on the card itself.",
            tap: "Today", error: error) }
        var cards: [JSONValue] = []
        for row in rows where row.source == InlineInteractionDelivery.source && !row.isHiddenFromDefaultInbox {
            let pointer: InlineInteractionDelivery.Pointer
            do { pointer = try InlineInteractionDelivery.Pointer(item: row) }
            catch {
                cards.append(.object(["id": .string(row.id), "unreadable": .string(error.localizedDescription)]))
                continue
            }
            let sessionID = pointer.sessionID, id = pointer.interactionID
            let found: InlineInteraction?
            do { found = try await InlineInteractionResolver.interaction(id: id, sessionID: sessionID, dataRoot: dataRoot) }
            catch {
                cards.append(.object(["id": .string(id), "session_id": .string(sessionID), "unreadable": .string(error.localizedDescription)]))
                continue
            }
            guard let found else {
                cards.append(.object(["id": .string(id), "session_id": .string(sessionID),
                    "unreadable": .string("The linked card is unavailable; what it waits on is unknown.")]))
                continue
            }
            guard found.kind == .permission else { continue }
            let card = await InlineInteractionResolver.liveProjection(found, dataRoot: dataRoot)
            guard case .running = card.state, card.waitingOn != nil,
                  let note = InlineCards.model(card, descriptor: InlineInteractionResolver.descriptor(for: card, dataRoot: dataRoot)).busyNote
            else { continue }
            cards.append(.object(["id": .string(card.id), "session_id": .string(sessionID), "title": .string(card.title),
                "waiting_on": .string(note)]))
        }
        return .object(["heading": .string(heading), "cards": .array(cards),
            "note": .string(cards.isEmpty ? "No permission card is running."
                : "What each running card waits on; unreadable cards remain unknown.")])
    }

    public static func quietChatCards(_ read: TranscriptReadout) -> [JSONValue] {
        var sections: [JSONValue] = []
        let pairs = read.messages.flatMap { message in
            message.inlineCards.map { (rowID: message.id, card: $0.model) }
        }
        guard !pairs.isEmpty else { return sections }
        sections.append(quietPageSection(
            "Cards",
            [read.cardsHeading
                + " in this conversation. card.answer answers one by its id."]
        ))
        for pair in pairs {
            let card = pair.card
            func cardSection(_ lines: [String]) -> JSONValue {
                var face: [String: JSONValue] = [
                    "heading": .string(card.title), "lines": .array(lines.map { .string(bounded($0)) }),
                    "status": .string(card.state.rawValue),
                ]
                if let outcome = card.outcome { face["outcome"] = .string(outcome) }
                if let meta = card.outcomeMeta { face["outcome_meta"] = .string(meta) }
                let unsupportedInstruction = """
                    Tell the person: this copy of NativeAgent has no control for card \(card.id) (\(card.title)). Preserve the card; no answer can run \
                    here.
                    """
                let unsupported = Repair.remedy(owner: "NativeAgent card controls", nextCall: nil, tap: unsupportedInstruction,
                    instruction: unsupportedInstruction)
                switch card.state {
                case .stopped:
                    face["reason"] = .string(DataRootLife.stoppedReason)
                    face["remedy"] = Repair.remedy(owner: card.title, nextCall: nil,
                        tap: "Chat → \(card.title) [\(card.id)] → Resume",
                        instruction: "The person can use Resume to start this request fresh after the restore.")
                case .unknown:
                    face["reason"] = .string("card_unsupported")
                    face["detail"] = .string(card.outcome ?? "This build has no control for this card.")
                    face["remedy"] = unsupported
                case .failed:
                    face["reason"] = .string(card.canRetry ? "card_action_failed" : "card_unsupported")
                    face["detail"] = .string(card.outcome ?? card.why)
                    face["scope"] = .array(card.scopeLines.map(JSONValue.string))
                    face["remedy"] = card.canRetry
                        ? Repair.remedy(owner: card.title, nextCall: nil,
                            tap: "Chat → \(card.title) [\(card.id)] → Try again",
                            instruction: "Resolve the reported cause; the owner can then use this card's Try again control.")
                        : unsupported
                case .pending, .running, .settled, .declined, .superseded:
                    break
                }
                return .object(face)
            }
            // Preserve interaction ids; only settled cards become receipts.
            switch card.state {
            case .superseded:
                // Superseded asks have no remaining decision because a newer identical ask owns it.
                sections.append(cardSection([
                    "State: " + card.state.rawValue,
                    "Asked earlier — a newer copy of this ask took its place.",
                    "Interaction id: \(card.id)",
                    "On message: \(pair.rowID)",
                ]))
                continue
            case .unknown, .declined, .settled:
                var receipt: [String] = ["State: \(card.state.rawValue)"]
                if let outcome = card.outcome { receipt.append(outcome) }
                if let meta = card.outcomeMeta { receipt.append(meta) }
                receipt.append("Interaction id: \(card.id)")
                receipt.append("On message: \(pair.rowID)")
                sections.append(cardSection(receipt))
                continue
            case .pending, .running, .failed, .stopped:
                // Failure settles nothing: retain the card’s explanation, field and retry control rather than presenting a receipt.
                break
            }
            var lines: [String] = ["State: \(card.state.rawValue)"]
            if !card.why.isEmpty { lines.append("Why: \(card.why)") }
            if card.state == .running, let note = card.busyNote { lines.append("Working: \(note)") }
            if let restart = card.restartNote { lines.append("Restart: \(restart) Only the person's tap on the card restarts.") }
            lines.append(contentsOf: card.scopeLines)
            if card.state == .failed && !card.canRetry {
                // Never name controls this build cannot draw.
                lines.append("There is no control for this on this build, so it can't be answered here.")
            } else {
                lines.append("Do: \(card.state == .stopped ? "Resume" : card.state == .failed ? "Try again" : card.primaryLabel)")
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
            sections.append(cardSection(lines))
        }
        return sections
    }

    public static func quietAgents(_ contacts: ContactListFacade) async -> [JSONValue] {
        let doors: [AgentContactRow]
        do { doors = try await contacts.refreshDoors().doors }
        catch {
            return [quietPageIssue("Agents", reason: "agent_contacts_unavailable", detail: error.localizedDescription,
                instruction: "Inspect Doctor for the contact-store failure before changing contacts or trusted switches.",
                next: ["action": .string("doctor.run")], error: error)]
        }
        let rows = doors.filter(\.primary)
        let peers = doors.compactMap(\.contact)
        var sections = [quietPageSection("Agents", [
            quietCountLine(rows.count, "contact", "contacts"),
            "This page only reads contacts and switches; it runs nothing.",
            """
                agent.contacts {discover:true} finds A2A cards, MCP settings and ACP programs; may run --help or initialize under send authority; \
                receipts name reads and runs.
                """,
        ])]
        if !rows.isEmpty {
            sections.append(quietPageSection("Contacts", rows.map { "\($0.displayName): \($0.pillWord) · \($0.status)" }))
        }
        if !peers.isEmpty {
            sections.append(quietPageSection("Trusted switches", peers.map { "\($0.name): trusted \($0.elevationAllowed ? "on" : "off")" }))
        }
        return sections
    }

}
