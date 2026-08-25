import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger row: chat.tools.tool_unload  (state-lifecycle leak)
//
// tool_unload is the ONLY explicit remove path for the persisted per-session
// loadout, and it has never been dispatched in the live window. If it regressed
// — `all:true` no longer honoured, or names silently ignored — the only
// backstops are a 24h TTL and the 24-tool LRU cap, and the receipt would still
// read status:"unloaded" with an empty `dropped` array. Success-shaped.
//
// The property with teeth: the receipt must be DERIVED FROM THE STORE, not from
// the request. `dropped` is before−after and `session_active_remaining_count`
// must match a fresh load() off disk — so a no-op cannot report a removal and a
// removal cannot report a no-op.
// ─────────────────────────────────────────────────────────────────────────────

private func unloadEvalRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolUnloadEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func receiptObject(_ value: JSONValue) -> [String: JSONValue]? {
    guard case .object(let object) = value else { return nil }
    return object
}

private func stringArray(_ value: JSONValue?) -> [String] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
}

@Test func toolUnload_receiptIsDerivedFromTheStoreNotTheRequest() async throws {
    let root = try unloadEvalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let store = dispatcher.activeToolsStore
    let session = "eval-session-\(UUID().uuidString)"
    let loaded: Set<String> = ["grep", "git_log", "notes_search", "mail_search", "music_control"]
    _ = try await store.addLoaded(sessionId: session, names: loaded)
    #expect(await store.load(sessionId: session).activeTools == loaded)

    // 1. Named removal: `dropped` names EXACTLY what left the persisted set.
    let byName = try await dispatcher.impl_tool_unload(input: [
        "__session_id": .string(session),
        "names": .array([.string("grep"), .string("git_log")]),
    ])
    let byNameReceipt = try #require(receiptObject(byName))
    #expect(byNameReceipt["status"] == .string("unloaded"))
    #expect(stringArray(byNameReceipt["dropped"]) == ["git_log", "grep"])
    let afterNamed = await store.load(sessionId: session).activeTools
    #expect(afterNamed == ["notes_search", "mail_search", "music_control"])
    #expect(
        byNameReceipt["session_active_remaining_count"] == .int(Int64(afterNamed.count)),
        "the remaining count must match a fresh load() of the persisted file, not the request"
    )

    // 2. A no-op must not be success-shaped: unloading a name that was never
    //    loaded reports an EMPTY dropped list and leaves the store untouched.
    let noop = try await dispatcher.impl_tool_unload(input: [
        "__session_id": .string(session),
        "names": .array([.string("never_loaded_tool")]),
    ])
    let noopReceipt = try #require(receiptObject(noop))
    #expect(
        stringArray(noopReceipt["dropped"]).isEmpty,
        "a no-op must report dropping nothing — claiming a removal that did not happen is the silent half of this bug"
    )
    #expect(await store.load(sessionId: session).activeTools == afterNamed)
    #expect(noopReceipt["session_active_remaining_count"] == .int(Int64(afterNamed.count)))

    // 3. all:true drains the persisted set and the receipt accounts for every
    //    name that left.
    let dropAll = try await dispatcher.impl_tool_unload(input: [
        "__session_id": .string(session),
        "all": .bool(true),
    ])
    let dropAllReceipt = try #require(receiptObject(dropAll))
    #expect(Set(stringArray(dropAllReceipt["dropped"])) == afterNamed)
    #expect(dropAllReceipt["session_active_remaining_count"] == .int(0))
    #expect(
        await store.load(sessionId: session).activeTools.isEmpty,
        "all:true must actually empty the PERSISTED loadout, not just the receipt"
    )

    // 4. Sessions are isolated: a drain of one session cannot take another's
    //    loadout with it (the leak direction nobody would notice).
    let sibling = "eval-sibling-\(UUID().uuidString)"
    _ = try await store.addLoaded(sessionId: sibling, names: ["grep"])
    _ = try await dispatcher.impl_tool_unload(input: [
        "__session_id": .string(session), "all": .bool(true),
    ])
    #expect(await store.load(sessionId: sibling).activeTools == ["grep"])

    // 5. A missing session id is a NAMED failure, never a silent global drain.
    let noSession = try await dispatcher.impl_tool_unload(input: ["all": .bool(true)])
    let noSessionReceipt = try #require(receiptObject(noSession))
    #expect(noSessionReceipt["status"] == .string("failed"))
    #expect(noSessionReceipt["reason"] == .string("missing_session_id"))
    #expect(await store.load(sessionId: sibling).activeTools == ["grep"])
}
