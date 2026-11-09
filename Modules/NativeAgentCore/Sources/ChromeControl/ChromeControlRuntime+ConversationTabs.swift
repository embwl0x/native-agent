import Foundation
import PersistenceCore
import NativeAgentCore
import Darwin
import NativeAgentChromeRelayCore
import TrustCenter
import MacControl
// Blueprint: | `ChromeControlRuntime+ConversationTabs.swift` | `ChromeControlRuntime`, `ChromeTabTaken`; Per-conversation tab memory, release evidence and the person taking a tab. |

/// The person took one of the agent's tabs by selecting it, touching it or navigating it. The agent's own close and group changes are status, not this.
public struct ChromeTabTaken: Sendable {
    public static let happened = Notification.Name("NativeAgentChromeTabTaken")
    public let tabID: Int64
    public let reason: String
    /// The host alone: a URL's path and query can carry page-authored text and secrets.
    public let host: String?
    /// The event's own instant. Chrome reuses tab ids and the extension restarts its sequences across restarts.
    public let at: String

    init?(tabID: Int64, released row: [String: JSONValue]) {
        guard case .string(let reason)? = row["reason"], case .string(let at)? = row["at"],
              ["tab_active", "tab_activated"].contains(reason) || reason.hasPrefix("user_") else { return nil }
        self.tabID = tabID
        self.reason = reason
        self.at = at
        if case .string(let url)? = row["url"] { host = URL(string: url)?.host?.lowercased() } else { host = nil }
    }
}

extension ChromeControlRuntime {
    private func refreshGroupTabs() async {
        guard let channel = readyChannel else { return }
        guard let rows = await channel.tabs(), readyChannel === channel else { return }
        groupTabs = rows
        // Only an accepted channel's inventory can retire a remembered tab.
        // A disconnected or replaced channel says nothing about ownership.
        for id in Set(rememberedTabIDs.values) where rows[id] == nil { forgetTab(id) }
    }

    private func rememberTab(_ id: Int64?, session: String) {
        guard NativeAgentChatSessionID.isSafePathComponent(session) else { return }
        guard rememberedTabIDs[session] != id || conversationTabsStorageError != nil else { return }
        rememberedTabIDs[session] = id
        do {
            try FileManager.default.createDirectory(at: conversationTabsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONEncoder().encode(rememberedTabIDs), to: conversationTabsURL)
            conversationTabsStorageError = nil
        } catch { conversationTabsStorageError = "Chrome conversation tab IDs could not be saved: \(error.localizedDescription)" }
    }

    func recordReleasedTab(_ tab: JSONValue) {
        if case .object(let row) = tab, case .int(let id)? = row["tabId"] {
            forgetTab(id)
            if let taken = ChromeTabTaken(tabID: id, released: row) {
                NotificationCenter.default.post(name: ChromeTabTaken.happened, object: nil, userInfo: ["taken": taken])
            }
        }
        releasedTabs.append(tab)
        if releasedTabs.count > 8 { releasedTabs.removeFirst(releasedTabs.count - 8) }
    }

    private func forgetTab(_ id: Int64) {
        let sessions = rememberedTabIDs.compactMap { $0.value == id ? $0.key : nil }
        for session in sessions { rememberTab(nil, session: session) }
    }

    public func conversationTabStatus(_ verifiedSessionID: String?) async -> [String: JSONValue] {
        await refreshGroupTabs()
        let current = verifiedSessionID.flatMap { rememberedTabIDs[$0] }.flatMap { groupTabs[$0]?.tabID }
        let tabs = groupTabs.keys.sorted().compactMap { id -> JSONValue? in
            guard let tab = groupTabs[id] else { return nil }
            return .object(["tab_id": .int(id), "title": tab.title.map(JSONValue.string) ?? .null,
                "url": tab.url.map(JSONValue.string) ?? .null, "current": .bool(id == current),
                "audible": tab.audible, "mutedInfo": tab.mutedInfo,
                "last_capture_error": captureErrors[String(id)] ?? .null])
        }
        var result: [String: JSONValue] = ["tabs": .array(tabs), "extension_connected": .bool(readyChannel != nil),
            "released": .array(releasedTabs), "released_note": .string("tabs that were the agent's and why they stopped being the agent's")]
        if let conversationTabsStorageError { result["tab_memory_error"] = .string(conversationTabsStorageError) }
        return result
    }

    public func performInConversation(
        _ effect: ChromeControlEffect, payload: [String: JSONValue], verifiedSessionID: String?,
        turn: Turn, context: MacOperationContext
    ) async throws -> JSONValue {
        if channel != nil, readyChannel == nil { throw await connectionFailure( context: context) }
        let session = verifiedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session, !session.isEmpty {
            guard busyConversations.insert(session).inserted else {
                throw ChromeControlRuntimeError.conversationContext(
                    "Another Chrome action is still running in this conversation. Nothing was sent; wait for its result before continuing.")
            }
        }
        defer { if let session { busyConversations.remove(session) } }
        await refreshGroupTabs()
        var resolved = payload
        let newTab = effect == .navigate && payload["newTab"] == .bool(true)
        if newTab, payload["tabId"] != nil || ["back", "forward"].contains(payload["url"]?.stringValue ?? "") {
            throw ChromeControlRuntimeError.conversationContext("new_tab opens a URL in another background tab; omit tab_id and do not use back/forward.")
        }
        let explicitID: Int64? = if case .int(let id)? = payload["tabId"] { id } else { nil }
        let rememberedID = session.flatMap { rememberedTabIDs[$0] }
        let current = explicitID.flatMap { groupTabs[$0] }
            ?? (explicitID == nil && !newTab ? rememberedID.flatMap { groupTabs[$0] } : nil)
        if resolved["tabId"] == nil && !newTab, let current {
            resolved["tabId"] = .int(current.tabID)
        }
        if effect != .navigate, resolved["tabId"] == nil {
            throw ChromeControlRuntimeError.conversationContext(
                "This conversation has no Chrome tab yet. browser.chrome_navigate{url} opens one; later calls reuse it. Nothing was sent.")
        }
        if resolved["expectedUserSequence"] == nil, let current,
            resolved["tabId"] == .int(current.tabID) { resolved["expectedUserSequence"] = current.userSequence }
        if effect == .snapshot, let current, resolved["tabId"] == .int(current.tabID) {
            // Scope/scroller describe the place. Limits belong to this call;
            // an earlier default must not hold a new reader to an old cut.
            for (key, value) in current.readingView where resolved[key] == nil && !["maxNodes", "maxTextChars"].contains(key) {
                if key == "readCursor", resolved["find"] != nil { continue }
                resolved[key] = value
            }
        }
        let reply: (response: JSONValue, channel: ChromeControlChannel)
        do {
            reply = try await performOnChannel(effect, payload: resolved, turn: turn, context: context)
        } catch ChromeControlRuntimeError.extensionRejected(let code, let message) where code == "tab_not_owned" {
            if case .int(let id)? = resolved["tabId"] { forgetTab(id) }
            throw ChromeControlRuntimeError.extensionRejected(code: code, message: message)
        }
        let (response, respondingChannel) = reply
        if effect != .preview, channel === respondingChannel,
           case .object(let envelope) = response, case .object(let result)? = envelope["result"] {
            if case .object(let error)? = result["error"], error["code"] == .string("tab_not_owned"),
               case .int(let id)? = resolved["tabId"] { forgetTab(id) }
            if effect == .closeTab, result["tabClosed"] == .bool(true), case .int(let id)? = resolved["tabId"] { forgetTab(id) }
            await refreshGroupTabs()
            if channel === respondingChannel, !(effect == .closeTab && result["tabClosed"] == .bool(true)),
               effect != .navigate || result["outcome"] == .string("succeeded"),
               case .int(let id)? = result["tabId"], groupTabs[id] != nil {
                if let session, !session.isEmpty { rememberTab(id, session: session) }
            }
        }
        if effect == .media || effect == .closeTab, case .object(var envelope) = response,
           case .object(var result)? = envelope["result"] {
            result["tabSelection"] = .string(explicitID != nil ? "Explicit tab_id."
                : "Default tab: this conversation's remembered tab (tab_id omitted).")
            envelope["result"] = .object(result)
            return .object(envelope)
        }
        return response
    }
}
