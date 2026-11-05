import ApprovalTransactions
import AuthoredCapabilities
import ChatToolRuntime
import ChatTurnContracts
import Connectors
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Transcripts
// Blueprint: | `ConnectorFace.swift` | `ConnectorReadiness`: in-memory Connectors face, status words and row actions |

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
    func readFace() async throws -> (face: PartFace, epoch: UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let accountRows: [PartFace.Row]
        let line: String
        switch accounts {
        case .failure(let error):
            accountRows = [notice("accounts-unavailable", error.localizedDescription)]
            line = "Connected accounts are unread; refresh Connectors to read them."
        case .success(let records):
            let on = records.filter(\.enabled).count
            let waiting = records.filter { $0.needsConnectionAttention }.count
            line = "\(on) of \(records.count) \(records.count == 1 ? "door is" : "doors are") on. "
                + (waiting == 0 ? "No account is asking for setup." : "\(waiting) \(waiting == 1 ? "account needs" : "accounts need") your attention.")
            accountRows = records.isEmpty ? [.init(id: "accounts-empty", title: "No accounts are listed.", tone: .quiet)]
                : records.sorted {
                    if $0.connectionState != $1.connectionState { return $0.connectionState.rawValue < $1.connectionState.rawValue }
                    if $0.enabled != $1.enabled { return $0.enabled }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }.map(accountFaceRow)
        }
        let secretRows: [PartFace.Row]
        switch secrets {
        case nil:
            secretRows = [notice("secrets-unread", "Kept secrets have not been read yet. Refresh Connectors to read them.")]
        case .failure(let error)?:
            secretRows = [notice("secrets-unavailable", "Kept secrets could not be read: \(error.localizedDescription)")]
        case .success(let entries)?:
            secretRows = entries.isEmpty ? [.init(id: "secrets-empty", title: "No secrets kept yet.", tone: .quiet)] : entries.map { entry in
                let destinations = (entry.hosts + entry.programs.map(\.path)).joined(separator: ", ")
                return .init(id: "secret:" + entry.name, title: entry.name,
                    detail: "May go to " + destinations + (entry.account.map { " · Account " + $0 } ?? ""),
                    value: "Granted", at: ISO8601DateFormatter().string(from: entry.at), symbol: "key",
                    actions: [.init(id: "forget", label: "Forget", role: .destructive)])
            }
        }
        var folderRows: [PartFace.Row]
        if let error = workspacesReadError {
            folderRows = [notice("folders-unavailable", "Shared folders could not be read: " + error)]
        } else if let folders = workspaceSnapshot {
            folderRows = folders.isEmpty ? [.init(id: "folders-empty", title: "No folder is shared yet.", tone: .quiet)] : folders.map { folder in
                let access: String
                let permissions = Set(folder.permissions)
                if permissions == Set(["read"]) { access = "read" }
                else if permissions == Set(["read", "write"]) { access = "read/write" }
                else { access = folder.permissions.isEmpty ? "Access not recorded" : folder.permissions.joined(separator: "/") }
                return .init(id: folder.id, title: folder.name, detail: folder.path, value: access, symbol: "folder",
                    tone: folder.permissions.isEmpty ? .attention : nil)
            }
        } else {
            folderRows = [notice("folders-unread", "Shared folders have not been read yet. Refresh Connectors to read them.")]
        }
        folderRows.append(.init(id: "share-folder", title: "Share a folder", detail: "Choose a folder and its access on your Mac.",
            symbol: "folder.badge.plus", actions: [.init(id: "share-folder", label: "Share a folder")]))
        return (.init(title: "Connectors", line: line, sections: [
            .init(id: "accounts", title: "Accounts", style: .list, rows: accountRows),
            .init(id: "secrets", title: "Kept secrets", style: .list, rows: secretRows),
            .init(id: "folders", title: "Folders I may open", style: .list, rows: folderRows)
        ]), epoch)
    }

    private func notice(_ id: String, _ words: String) -> PartFace.Row {
        .init(id: id, title: words, tone: .attention)
    }

    private func accountFaceRow(_ connector: ConnectorRecord) -> PartFace.Row {
        var detail = connector.connectionDescription
        // The shared renderer gives a control the trailing slot; keep this row's health words visible beside it.
        if connector.canToggle { detail = connector.connectionStatusText + "\n" + detail }
        if let status = connector.runtimeStatus, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detail += "\nLive connection: " + ConnectorRecord.plainConnectionStatus(status)
                + (connector.runtimeDetail.map { " · " + $0 } ?? "")
        }
        if let access = connector.connectionAccessLabel { detail += "\n" + access }
        var actions: [PartFace.Action] = []
        var open: String?
        if connector.id == "browser" {
            actions.append(.init(id: "browser.show", label: "Show browser", role: .primary))
        } else if connector.id == "telegram" {
            open = "page:telegram"
        } else if ConnectorWizardSetupRoute.resolve(provider: connector.id) != .unavailable {
            let connect = connector.connectionState == .needsAuth || connector.connectionState == .comingSoon
            actions.append(.init(id: "connect", label: connect ? "Connect" : "Reconnect", role: .primary))
        }
        if MobileConnectorSnapshot(connector).canDisconnect == true {
            actions.append(.init(id: "connector.disconnect", label: "Disconnect", role: .destructive))
        }
        let tone: PartFace.Tone = connector.connectionReadFailed ? .failed : connector.hasLiveConnectionProof ? .live
            : connector.needsConnectionAttention ? .attention : .quiet
        return .init(id: connector.id, title: connector.name, detail: detail,
            value: connector.canToggle ? (connector.enabled ? "On" : "Off")
                : connector.connectionStatusText + " · " + (connector.enabled ? "On" : "Off"), symbol: "link", tone: tone,
            open: open, actions: actions.isEmpty ? nil : actions, control: connector.canToggle ? .toggle(connector.enabled) : nil)
    }

    /// The person's face controls call the same connector owner as the tool and phone doors.
    func actOnFace(row: String, action: String, value: String?, by: PartFaces.Actor) async throws -> String? {
        // From this page the agent may only lower access (switch a door off); everything else here belongs to the person.
        if case .agent = by, !(action == "set" && value == "off") {
            throw PartCallError(code: "person_only", message: "From Connectors the agent may only switch a door off; the rest belongs to the person.")
        }
        do {
            if row == "share-folder", action == "share-folder" {
                guard case .person(door: "mac", _) = by, let choose = platform.chooseSharedFolder else {
                    throw PartCallError(code: "mac_required", message: "Share a folder on your Mac")
                }
                guard let selection = try await choose() else { return "No folder was shared." }
                let result = try await addWorkspace(name: selection.name, path: selection.path, writable: selection.writable)
                guard result.verified else {
                    throw PartCallError(code: "unconfirmed", message: "The saved folder could not be confirmed. Refresh Connectors before sharing it again.")
                }
                return "Shared \(result.added.name) with \(selection.writable ? "read and write" : "read-only") access."
            }
            if row.hasPrefix("secret:"), action == "forget" {
                guard let secrets, try secrets.get().contains(where: { "secret:" + $0.name == row }) else {
                    throw PartCallError(code: "stale_secret", message: "That secret is not in the current reading. Refresh Connectors before forgetting it.")
                }
                try Keyring.remove(String(row.dropFirst("secret:".count)))
                await refresh()
                return "The secret was forgotten. What uses it needs a new grant before it can reach there again."
            }
            guard let connector = try accounts.get().first(where: { $0.id == row }) else {
                throw PartCallError(code: "stale_connector", message: "That account is not in the current reading. Refresh Connectors before changing it.")
            }
            switch action {
            case "set", "connector.on", "connector.off":
                guard connector.canToggle else {
                    throw PartCallError(code: "setup_required", message: "This account is controlled by its own setup. Open its setup to change it.")
                }
                let enabled: Bool
                if action == "set" {
                    guard value == "on" || value == "off" else {
                        throw PartCallError(code: "bad_value", message: "The account switch needs on or off.")
                    }
                    enabled = value == "on"
                } else { enabled = action == "connector.on" }
                guard try await update(id: row, enabled: enabled) != nil else {
                    throw PartCallError(code: "unconfirmed", message: "The account change could not be confirmed. Refresh Connectors before changing it again.")
                }
                return nil
            case "connector.disconnect" where MobileConnectorSnapshot(connector).canDisconnect == true:
                _ = try await disconnectMobileConnector(id: row)
                return nil
            case "browser.show" where row == "browser":
                guard let show = platform.showBrowser else {
                    throw PartCallError(code: "mac_required", message: "Show the browser on your Mac.")
                }
                try await show()
                return "Visible Browser opened."
            case "connect" where ConnectorWizardSetupRoute.resolve(provider: row) != .unavailable:
                guard let session = try ConversationAnchor.checkedCurrent(dataRoot: root)?.sessionId else {
                    throw PartCallError(code: "conversation_required",
                        message: "Open a chat with me, then choose Connect again so I can put the setup card there.")
                }
                let card = InlineInteractionRegistry.connector(row, why: "You asked to connect \(connector.name).", dataRoot: root)
                let origin = TurnEnvelope.native("face:connectors:connect")
                let turn = Turn(session: session).with(\.envelope, origin).with(\.verifiedSessionID, session)
                guard let raised = await InlineInteractionResolver.raise(card, sessionID: session, resumable: false,
                    origin: origin, turn: turn, dataRoot: root) else {
                    throw PartCallError(code: "card_unavailable", message: "The setup card could not be saved. Open chat and choose Connect again.")
                }
                return "Connect \(connector.name) on the setup card in chat (card:\(raised.id))."
            default:
                throw PartCallError(code: "no_action", message: "That action is not available on this row. Refresh Connectors to read its current controls.")
            }
        } catch let error as PartCallError { throw error }
        catch { throw PartCallError(code: "connector_action_failed", message: error.localizedDescription + " Refresh Connectors before trying again.") }
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
        if auth == "connected" || auth == "configured" || health == "ok" { return .live }
        if health == "ready" { return auth == "planned" ? .planned : .ready }
        if auth == "not_required" { return .ready }
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
        case .unverified: return auth?.lowercased() == ConnectorHealthDecay.configuredAuth ? "Set up · Not checked" : "Not checked"
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
