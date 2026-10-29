import Foundation
import PersistenceCore
import NativeAgentCore
import Darwin
import NativeAgentChromeRelayCore
import TrustCenter
import MacControl
// Blueprint: | `ChromeControlRuntime+ConversationTabs.swift` | `ChromeControlRuntime` conversation tab members: durable last-tab memory rebuilt from the group, numeric addressing, per-tab reading views and remembered owned-tab page.look; last eight release causes/times/URLs survive reconnects for this app run |

extension ChromeControlRuntime {
    private func refreshGroupTabs() async {
        guard let channel = readyChannel else { return }
        let rows = await channel.tabs()
        guard readyChannel === channel else { return }
        groupTabs = rows
    }

    private func rememberTab(_ id: Int64, session: String) {
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
        releasedTabs.append(tab)
        if releasedTabs.count > 8 { releasedTabs.removeFirst(releasedTabs.count - 8) }
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
            "released": .array(releasedTabs), "released_note": .string("tabs that were hers and why they stopped being hers")]
        if let conversationTabsStorageError { result["tab_memory_error"] = .string(conversationTabsStorageError) }
        return result
    }

    public func conversationSnapshotView(_ verifiedSessionID: String?, tabID: Int64? = nil) -> [String: JSONValue]? {
        let tab = tabID.flatMap { groupTabs[$0] } ?? verifiedSessionID.flatMap { rememberedTabIDs[$0] }.flatMap { groupTabs[$0] }
        return tab?.hasReadView == true ? tab?.readingView : nil
    }

    public func performInConversation(
        _ effect: ChromeControlEffect, payload: [String: JSONValue], verifiedSessionID: String?
    ) async throws -> JSONValue {
        if channel != nil, readyChannel == nil { throw await connectionFailure() }
        let session = verifiedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session, !session.isEmpty {
            guard busyConversations.insert(session).inserted else {
                throw ChromeControlRuntimeError.conversationContext("Another Chrome action is still running in this conversation. Nothing was sent; wait for its result before continuing.")
            }
        }
        defer { if let session { busyConversations.remove(session) } }
        await refreshGroupTabs()
        var resolved = payload
        let explicitID: Int64? = if case .int(let id)? = payload["tabId"] { id } else { nil }
        let rememberedID = session.flatMap { rememberedTabIDs[$0] }
        let current = explicitID.flatMap { groupTabs[$0] }
            ?? (explicitID == nil ? rememberedID.flatMap { groupTabs[$0] } : nil)
        if resolved["tabId"] == nil {
            if let rememberedID { resolved["tabId"] = .int(rememberedID) }
            else if let current { resolved["tabId"] = .int(current.tabID) }
        }
        if effect != .navigate, resolved["tabId"] == nil {
            throw ChromeControlRuntimeError.conversationContext("This conversation has no Chrome tab yet. browser.chrome_navigate{url} opens one; later calls reuse it. Nothing was sent.")
        }
        if resolved["expectedUserSequence"] == nil, let current, resolved["tabId"] == .int(current.tabID) { resolved["expectedUserSequence"] = current.userSequence }
        if effect == .snapshot, let current, resolved["tabId"] == .int(current.tabID) {
            for (key, value) in current.readingView where resolved[key] == nil { resolved[key] = value }
        }
        let (response, respondingChannel) = try await performOnChannel(effect, payload: resolved)
        if channel === respondingChannel, case .object(let envelope) = response, case .object(let result)? = envelope["result"] {
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
