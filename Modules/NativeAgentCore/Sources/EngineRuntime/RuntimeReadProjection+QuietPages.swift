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
// Blueprint: | `RuntimeReadProjection+QuietPages.swift` | Quiet page/item formatting and navigation over engine projections: Desk uses the complete retained `DeskFacade.page` and its prepared attention rows, helpers use `botsShelfRead` including followingModel, chat cards and heading use the checked transcript projection; unsupported card states share one person-directed defect naming the card; page indexing takes the live layout; Mac access/grants render `MacIntegrationFacade`; connector items expose secret names without values; shared Trust, provider, inbox and settings read formatting |

@MainActor
extension RuntimeReadouts {
    public static func quietPages(layout: SurfaceLayout, profile: String) -> [QuietToolPage] {
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

    /// Failure evidence and its recovery are one structured face, never prose
    /// clipped by the section's 200-character summary bound.
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
        let items = inbox.items
        var sections = [quietPageSection("Notifications", [
            quietCountLine(items.count, "item in the inbox", "items in the inbox"),
            quietCountLine(items.filter { $0.status == "unread" }.count, "unread", "unread"),
        ])]
        if let error = inbox.loadError {
            sections.append(quietPageIssue("Notifications", reason: "inbox_read_failed", detail: error,
                instruction: "Resolve the reported inbox read problem, preserving saved notes, then reload Notifications.",
                next: ["page": .string("notifications")], status: inbox.hasLoadedSnapshot ? "stale" : "unavailable"))
        } else if !inbox.hasLoadedSnapshot {
            sections.append(quietPageIssue("Notifications", reason: "inbox_not_loaded",
                detail: "The inbox has not loaded.", instruction: "Read Notifications to load the inbox.",
                next: ["page": .string("notifications")], status: "not_loaded"))
        }
        if !items.isEmpty {
            sections.append(quietPageSection("Recent", items.prefix(15).map {
                "\($0.created_at) · \($0.status) · \($0.severity) · \($0.source): \($0.title) — \($0.summary)"
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
            "Model: \(status.model ?? "same as Chat") · Think \(status.reasoningEffort ?? "default")",
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
                "remedy": Repair.terminal(instruction: "A last reported error is not proof of a current failure. Read app {page:\"telegram\",item:\"status\"} for current health before acting.")]))
        }
        return sections
    }

    public static func quietPairing(_ sync: SyncFacade, dataRoot: URL) async -> [JSONValue] {
        var head = ["iCloud: \(sync.status)"]
        let phones = sync.phones.filter { $0.status != .removed }
        head.append(quietCountLine(phones.count, "phone", "phones"))
        var sections = [quietPageSection("iPhone pairing", head)]
        if let error = sync.pairingError {
            sections.append(quietPageIssue("iPhone pairing", reason: "pairing_unavailable", detail: error,
                instruction: "The owner checks iCloud and the pairing status on both devices using the same Apple Account. Keep the pairing key out of chat.",
                tap: "Connectors → iPhone → Connection"))
        }
        if !phones.isEmpty {
            sections.append(quietPageSection("Phones", phones.map { "\($0.id): \($0.status.rawValue)" }))
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
                case "not_configured":
                    instruction = "The owner configures direct push on this Mac before sending phone notifications."
                    tap = "NativeAgent data folder → config/apns.json"
                case "needs_token":
                    instruction = "The owner enables notifications for the companion app and connects it to this Mac."
                    tap = "iPhone Settings → Notifications → NativeAgent"
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
                detail: error.localizedDescription, instruction: "Inspect Doctor's phone-notification check for the unreadable evidence path; repair that file without deleting delivery history.",
                next: ["action": .string("doctor.run")], error: error))
        }
        return sections
    }

    /// A Mac app's or connector's page: the Mac app whose access it shows,
    /// and the connectors behind its actions.
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
                                      authority: FullMacYoloAuthorityAssessment, systemStatuses: [String: String], statusText: (ConnectorRecord) -> String) async -> JSONValue {
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
        access["verified_os_access"] = .string(systemStatuses[mac] ?? "unverified")
        // Automation rows and the macOS grants section share one engine read.
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
            let read = snapshot.allows(mac, mode: .read, fullMacAdmitted: admitted)
            let write = snapshot.allows(mac, mode: .write, fullMacAdmitted: admitted)
            access["effective_permission"] = .object(["read": .bool(read), "write": .bool(write)])
            access["stored_permission"] = .object(["read": .bool(stored.read), "write": .bool(stored.write)])
            access["full_mac_admitted"] = .bool(admitted)
            access["permission_state"] = .string(read || write ? "allowed" : "off")
            let blockers = [MacIntegrationPermissionMode.read, .write].compactMap { readiness.refusal(integration: mac, mode: $0) }
            access["permission_blockers"] = .array(blockers.map(JSONValue.string))
            // What is in effect leads, with why; the saved setting is named as
            // what it is (the one used outside Full Mac), never as the truth.
            func words(_ read: Bool, _ write: Bool) -> String {
                read && write ? "read and write" : read ? "read-only" : write ? "write-only" : "off"
            }
            let now = words(read, write), saved = words(stored.read, stored.write)
            access["in_effect"] = .string((now == saved ? now + (admitted ? " under Full Mac" : ", your saved setting")
                : admitted ? "\(now) under Full Mac; your saved setting is \(saved) and applies when Full Mac is off"
                : "\(now); your saved setting is \(saved)")
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
                                    statusText: (ConnectorRecord) -> String) async -> [JSONValue] {
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
                    origin: .currentTurn(verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: ChatToolSessionContext.envelope?.surface ?? "chat"))
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
                content += quietModelIssues(members, routing: routing)
            } catch { content.append(quietPageIssue("Models", reason: "provider_routing_unavailable",
                detail: error.localizedDescription, instruction: "Open Providers and resolve the reported routing problem.",
                tap: "Providers", error: error)) }
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
        "web": "Read a URL with web.read {url}; search with web.search {query}. A page read fetches no URL and performs no search.",
        "browser": "Read current browser state with browser.status, then read a tab with the browser or Chrome actions. A page read opens no tab.",
        "mac": "Read the current screen with mac.look, or a document with mac.read. A page read captures no screen and moves no control.",
    ]
    public static func quietConnectors(_ owner: ConnectorReadiness,
                                       workspaceCount: Int, statusText: (ConnectorRecord) -> String) async -> [JSONValue] {
        let connectors: [JSONValue]
        do {
            connectors = quietConnectors(try await owner.refresh().get(), workspaceCount: workspaceCount, statusText: statusText)
        } catch { connectors = [quietPageIssue("Connectors", reason: "connectors_read_failed", detail: error.localizedDescription,
            instruction: "Inspect Doctor's connector checks and resolve the reported read problem before changing connections.",
            next: ["action": .string("doctor.run")], error: error)] }
        // What the keyring keeps, by name and where each may go; never a value.
        let kept: JSONValue
        do {
            // After refresh, the owner has metadata or its checked failure.
            guard let secrets = owner.secrets else {
                throw RuntimeReadError.unreadableFeed("Secret metadata has not been read.")
            }
            let entries = try secrets.get().map { entry in
                "secret:\(entry.name): " + (entry.hosts + entry.programs.map { "program " + $0.path }).joined(separator: ", ")
                    + (entry.account.map { " · account \($0)" } ?? "") + " · granted " + entry.at.formatted(.iso8601.year().month().day())
            }
            kept = quietPageSection("Kept secrets", entries.isEmpty ? ["None."] : entries)
        } catch { kept = quietPageIssue("Kept secrets", reason: "secret_metadata_read_failed", detail: error.localizedDescription,
            instruction: "Resolve the reported credential-metadata read problem in Connectors; keep secret values out of chat.",
            tap: "Connectors → Secrets", error: error) }
        return connectors + [kept]
    }

    public static func quietConnectors(_ connectors: [ConnectorRecord], workspaceCount: Int,
                                       statusText: (ConnectorRecord) -> String) -> [JSONValue] {
        var sections = [quietPageSection("Connectors", [
            quietCountLine(connectors.count, "connector", "connectors"),
            quietCountLine(workspaceCount, "workspace", "workspaces"),
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

    public static func quietMacIntegration(connectors owner: ConnectorReadiness,
                                           macIntegration: MacIntegrationFacade,
                                           workspaceCount: Int,
                                           statusText: (ConnectorRecord) -> String) async -> [JSONValue] {
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
            origin: .currentTurn(verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: ChatToolSessionContext.envelope?.surface ?? "chat"))
        for mac in MacIntegrationID.all {
            capabilities.append(await quietMacAccess(mac, connectors: connectors, dataRoot: owner.root,
                permissions: permissions, authority: authority, systemStatuses: systemStatuses, statusText: statusText))
        }
        var overview: [JSONValue] = [.object(["heading": .string("Mac Integration"), "capabilities": .array(capabilities),
            "note": .string("Routes, permission, connection and macOS access are separate. Live OS status is read without prompting where supported; unverified means unknown. No app or content probe; no permission request.")]),
            .object(["heading": .string("macOS grants"), "grants": .array(quietMacOSGrants(systemStatuses)),
                "note": .string("Read live from macOS at this page read, without prompting. A grant that is not granted names the one card that asks for it.")])]
        overview += quietConnectors(connectors, workspaceCount: workspaceCount, statusText: statusText)
        return overview
    }

    /// The macOS grants her Mac work rides on, as macOS holds them now, never a
    /// saved copy: Accessibility, Screen Recording, Full Disk Access, and
    /// Automation per app she scripts.
    static func quietMacOSGrants(_ systemStatuses: [String: String]) -> [JSONValue] {
        func grant(_ name: String, _ state: String, card capability: String) -> JSONValue {
            var row: [String: JSONValue] = ["grant": .string(name), "state": .string(state)]
            if state != SystemPermissionStatus.granted.rawValue {
                row["card"] = .string("permissions.request {capability: \"\(capability)\"}")
            }
            return .object(row)
        }
        var grants = [SystemPermissionCapability.accessibility, .screenRecording, .fullDiskAccess].map {
            grant($0.displayName, systemStatuses[$0.rawValue] ?? "unknown", card: $0.rawValue)
        }
        for app in AppleScriptExecution.automationTargetApps {
            guard let bundleID = AppleScriptExecution.automationTargetBundleIDs[app] else { continue }
            grants.append(grant("Automation for \(app)", systemStatuses["apple_events_\(app.lowercased())"] ?? "unknown",
                                card: "applescript:" + bundleID))
        }
        return grants
    }

    public static func quietMemories(_ memory: MemoryFacade, keptLine: String, graphEntityCount: Int) -> [JSONValue] {
        let memories = memory.memories
        let shown = min(20, memories.count)
        var head = [keptLine]
        let slice = memory.totalCount.map { "\(shown) of \($0)" } ?? "\(shown) shown · total not loaded"
        head.append(slice + ((memory.totalCount ?? memories.count) > shown
            ? " · app {action:\"memory.list\",args:{offset:20,limit:20}}" : ""))
        head.append(quietCountLine(memory.proposals.count, "proposal waiting", "proposals waiting"))
        head.append(quietCountLine(graphEntityCount, "thing in the graph", "things in the graph"))
        head.append(contentsOf: memory.status?.afterTurn?.lines ?? [])
        var sections = [quietPageSection("Memories", head)]
        if !memories.isEmpty {
            sections.append(quietPageSection("Kept", memories.prefix(20).map { record in
                let first = record.text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? record.text
                return MemoryDataProvenance.presentation("\(record.layer ?? ""): \(first)", metadata: record.extras, dataRoot: memory.dataRoot)
            }))
        }
        if !memory.proposals.isEmpty {
            sections.append(quietPageSection("Waiting", memory.proposals.prefix(12).map(\.content)))
        }
        return sections
    }

    public static func quietPersonality(_ persona: PersonaFacade, currentPersona: String) async -> [JSONValue] {
        var head: [String] = []
        var selectionIssue: JSONValue?
        if let name = persona.profile?.name { head.append("Name: \(name)") }
        let root = persona.personaRoot
        let documents = persona.documents
        // The picker's word names a persona only when its directory holds one;
        // otherwise the root SOUL.md is her, under the name the person chose.
        do {
            let id = try PersonaCompiler.selectedPersonaID(root: root, personaOverride: currentPersona)
            if id != "canonical" { head.append("Current persona name: \(id).") }
            else if let name = persona.profile?.name { head.append("Current persona name: \(name) (the root persona).") }
            else { head.append("Current persona: the root persona.") }
        } catch {
            selectionIssue = quietPageIssue("Current persona", reason: "persona_selection_unavailable",
                detail: error.localizedDescription, instruction: "Inspect the persona directory and resolve the reported selection problem without replacing persona documents.",
                next: ["action": .string("files.list"), "args": .object(["path": .string(root.path)])], error: error)
        }
        head.append(quietCountLine(documents.count, "document", "documents"))
        var sections = [quietPageSection("Personality", head)]
        if let selectionIssue { sections.append(selectionIssue) }
        do {
            let names = try PersonaCompiler.customPersonaNames(root: root)
            sections.append(quietPageSection("Custom names for persona.set", names.isEmpty ? ["None."] : names))
        } catch { sections.append(quietPageIssue("Custom personas", reason: "persona_names_unavailable",
            detail: error.localizedDescription, instruction: "Resolve the reported persona-directory read problem without changing persona content.",
            next: ["action": .string("files.list"), "args": .object(["path": .string(root.path)])], error: error)) }
        do {
            let consults = try await SwiftNativeStudioStore(dataRoot: persona.dataRoot).listConsults()
            sections.append(quietPageSection("Consult ids for studio.consult_read", consults.isEmpty ? ["None."]
                : consults.map { "\($0.id): \($0.question) · \($0.descriptionOnly ? "description only" : "has artifacts")" }))
        } catch { sections.append(quietPageIssue("Consults", reason: "studio_consults_unavailable",
            detail: error.localizedDescription, instruction: "Resolve the reported consult-store read problem, preserving saved consults, then reload Personality.",
            next: ["page": .string("personality")], error: error)) }
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
                let unsupportedInstruction = "Tell the person: this copy of NativeAgent has no control for card \(card.id) (\(card.title)). Preserve the card; no answer can run here."
                let unsupported = Repair.remedy(owner: "NativeAgent card controls", nextCall: nil, tap: unsupportedInstruction, instruction: unsupportedInstruction)
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
            // Every interaction keeps its id; settled cards show receipts, while actionable cards keep their body.
            switch card.state {
            case .superseded:
                // "Asked earlier" is the superseded line and ONLY the
                // superseded line: a newer identical ask took this one's
                // place, so there is nothing to answer here.
                sections.append(cardSection([
                    // Every branch leads with its state.
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
                lines.append("Do: \(card.state == .stopped ? "Resume" : card.state == .failed ? "Try again" : card.primaryLabel)")
                // Consequences after a dash start lowercase, matching the settled decline line.
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

    public static func quietDesk(desk: DeskFacade) async -> [JSONValue] {
        let snapshot = await desk.loadPage()
        guard snapshot.loaded else {
            return [quietPageIssue("Desk", reason: "desk_unavailable",
                detail: snapshot.deskUnavailable ?? "The board could not be read.",
                instruction: "Inspect Doctor's Desk check and repair the reported board problem without discarding work.",
                next: ["action": .string("doctor.run")])]
        }
        let items = snapshot.boardItems
        let waiting = snapshot.rows.owner
        let blocked = snapshot.rows.blocked
        let shown = Set((waiting + blocked).map(\.handle))
        let active = DeskPageContent.active(items).filter { !shown.contains($0.handle) }
        // `stuckReason` answers "why is this stuck" and always answers; asking
        // it about a row that is not stuck would print a blocked line over a
        // healthy item. Only the two stuck lanes ask.
        func rows(_ list: [DeskItem], stuck: Bool = false) -> [String] {
            list.prefix(20).map { item in
                let line = "desk.\(item.alias) \(item.statusDescription) · \(DeskPageContent.title(item)) [\(item.project)]"
                guard stuck else { return line }
                let reason = DeskPageContent.stuckReason(item, in: items)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return reason.isEmpty ? line : "\(line) — \(reason)"
            }
        }
        var sections = [quietPageSection("Desk", [
            DeskState(items: items, generatedTs: snapshot.generatedTs ?? "").boardCountSummary,
            quietCountLine(waiting.count, "item waiting on the owner", "items waiting on the owner"),
            quietCountLine(blocked.count, "item blocked", "items blocked"),
            "To wait on a person: desk.wait {handle, on:\"<person>\", note?}; on:\"owner\" waits on the owner.",
            "ledger.list reads the shared task ledger, a separate list from this Desk.",
        ])]
        if !waiting.isEmpty { sections.append(quietPageSection("Waiting on the owner", rows(waiting, stuck: true))) }
        if !blocked.isEmpty { sections.append(quietPageSection("Blocked", rows(blocked, stuck: true))) }
        if !active.isEmpty { sections.append(quietPageSection("In play", rows(active))) }
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
            "agent.contacts {discover:true} finds A2A cards, MCP settings and ACP programs; may run --help or initialize under send authority; receipts name reads and runs.",
        ])]
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
            sections.append(quietPageSection(group.title, RuntimeReadouts.quietModelLines(group.members, routing: routing)))
            sections += quietModelIssues(group.members, routing: routing)
        }
        let accounts = providers.map { info -> String in
            let mode = info.auth_mode.map { " via \($0)" } ?? ""
            return "\(info.display_name): \(info.auth_status.state) — \(info.auth_status.detail)\(mode)"
        }
        sections.append(quietPageSection("Accounts", accounts.isEmpty ? ["No providers listed."] : accounts))
        for info in providers where !info.auth_status.eligible {
            sections.append(quietPageIssue(info.display_name, reason: "provider_account_" + info.auth_status.state,
                detail: info.auth_status.detail, instruction: "Resolve the reported credential problem in this account's Providers controls; keys stay out of chat.",
                tap: "Providers → \(info.display_name)"))
        }
        return sections
    }

    public static func quietTrust(trust: TrustFacade, dataRoot: URL, presetTitle: (TrustPolicy, String) -> String, guardrailLines: (TrustPolicy, String) -> [String]) -> [JSONValue] {
        guard let policy = trust.policy else {
            return [quietPageIssue("Trust", reason: "trust_policy_unavailable",
                detail: trust.securityStatus?.flags.first(where: { $0.id == "trust_policy_unavailable" })?.detail
                    ?? trust.securityRefreshError ?? "No Trust policy has loaded.",
                instruction: "Inspect Doctor's Trust check; repair the reported policy problem without deleting or replacing the saved policy.",
                next: ["action": .string("doctor.run")])]
        }
        let mode = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy)
        var head = ["Preset: \(presetTitle(policy, mode))", "Agent access: \(mode)"]
        head.append("Mac control: \(policy.macControlPolicy?.enabled == true ? "on" : "off")")
        var sections = [quietPageSection("Trust", head)]
        let rows = guardrailLines(policy, mode)
        if !rows.isEmpty {
            sections.append(quietPageSection("Guardrails", rows))
        }
        do {
            let backups = try TrustBackupPersistence.readBackupRecords(root: dataRoot)
            sections.append(quietPageSection("Backup ids for backup.restore", backups.isEmpty ? ["None."]
                : backups.map { "\($0.id): \($0.createdAt) · \($0.reason)" }))
        } catch { sections.append(quietPageIssue("Backups", reason: "trust_backups_unavailable",
            detail: error.localizedDescription, instruction: "Resolve the reported backup-store read problem before restoring; preserve existing backups.",
            tap: "Trust → Advanced → Backups", error: error)) }
        return sections
    }

    public static func quietCapabilities(trust: TrustFacade, approvals: ApprovalsFacade, workflowCount: Int, actionCount: Int) -> [JSONValue] {
        [quietPageSection("Capabilities", [
            quietCountLine(trust.capabilitySummary?.records.count ?? 0, "capability", "capabilities"),
            quietCountLine(workflowCount, "workflow", "workflows"),
            quietCountLine(actionCount, "action", "actions"),
            quietCountLine(approvals.records.filter { $0.status.lowercased() == "pending" }.count,
                      "approval waiting", "approvals waiting"),
        ])]
    }

    public static func quietBots(engine: NativeAgentEngine) async -> [JSONValue] {
        var unattended = false
        let loaded: [BotsShelfRecord]
        do { loaded = try await engine.botsShelfRead { unattended = $0 } }
        catch {
            return [quietPageIssue("Helpers", reason: "helpers_shelf_unavailable", detail: error.localizedDescription,
                instruction: "Resolve the reported helper-shelf read problem, preserving definitions and run history, then reload Helpers.",
                next: ["page": .string("bots")], error: error)]
        }
        var sections: [JSONValue] = []
        var header = [quietCountLine(loaded.count, "helper", "helpers") + " on the shelf."]
        if !unattended { header.append(BotsShelfUnattended.pageLine) }
        sections.append(quietPageSection("Helpers", header))
        for record in loaded {
            var lines: [String] = ["State: \(record.statusWord)"]
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
