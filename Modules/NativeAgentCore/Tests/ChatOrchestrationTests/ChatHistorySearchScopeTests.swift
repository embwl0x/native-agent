import Testing
import Foundation
@testable import ChatOrchestration
import PersistenceCore

// U5 follow-up (Agent, 2026-06-11, found during the memory backfill):
// search_chat_history (1) silently degraded explicit scope:"all" to "auto",
// and (2) the auto scope's current-session short-circuit fired on ANY hit —
// a 0.11-score single-token overlap blocked the all-sessions pass. These
// tests pin the fixes: "all" is honored, and the short-circuit needs a real
// relevance floor (chatHistoryCurrentSessionFloor).

private func makeSearchRoot(_ tag: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("chatSearch-\(tag)-\(UUID().uuidString)", isDirectory: true)
    let messages = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
    return root
}

private func writeSession(_ root: URL, id: String, lines: [String]) throws {
    let file = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("\(id).jsonl")
    let rows = lines.enumerated().map { i, content in
        #"{"role":"assistant","content":"\#(content)","createdAt":"2026-06-01T0\#(i):00:00Z","id":"m\#(i)"}"#
    }
    try rows.joined(separator: "\n").data(using: .utf8)!.write(to: file)
}

private func search(
    _ root: URL, query: String, scope: String?, currentSessionId: String?
) async throws -> [String: JSONValue] {
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    var input: [String: JSONValue] = ["query": .string(query)]
    if let scope { input["scope"] = .string(scope) }
    if let currentSessionId { input["current_session_id"] = .string(currentSessionId) }
    let result = try await dispatcher.impl_search_chat_history(
        input: input, invokedAs: "search_chat_history")
    guard case .object(let obj) = result else {
        Issue.record("non-object response"); return [:]
    }
    return obj
}

@Test func scope_all_is_honored_not_degraded_to_auto() async throws {
    let root = try makeSearchRoot("scope-all")
    try writeSession(root, id: "current", lines: ["the daemon restart happened here"])
    try writeSession(root, id: "older", lines: ["full daemon restart sync procedure for the migration"])

    let resp = try await search(
        root, query: "daemon restart sync procedure",
        scope: "all", currentSessionId: "current")

    // Explicit all must NOT echo back "auto" and must search every session.
    #expect(resp["scope"] == .string("all_sessions"))
    #expect(resp["phase"] == .string("all_sessions"))
}

@Test func auto_scope_weak_current_hit_does_not_block_global_search() async throws {
    let root = try makeSearchRoot("weak-hit")
    // Current session: ONE incidental token ("daemon") out of a long query —
    // score well under the floor. The real answer lives in the older session.
    try writeSession(root, id: "current", lines: ["mentioned the daemon once in passing"])
    try writeSession(root, id: "older", lines: [
        "telegram photo ingest daemon attachment vision pipeline restored end to end",
    ])

    // Query SHARES the token "daemon" with the current-session fixture —
    // 1 of 8 tokens = score 0.125, the exact reported failure shape. The
    // pre-fix code short-circuited on this (any hit); the floor must not.
    let resp = try await search(
        root,
        query: "telegram photo ingest daemon attachment vision pipeline restored",
        scope: "auto", currentSessionId: "current")

    // The weak current hit must fall through to the all-sessions pass.
    #expect(resp["phase"] == .string("all_sessions_fallback"))
}

@Test func auto_scope_strong_current_hit_still_short_circuits() async throws {
    let root = try makeSearchRoot("strong-hit")
    try writeSession(root, id: "current", lines: [
        "the heartbeat loop silent ok contract was verified today",
    ])
    try writeSession(root, id: "older", lines: ["unrelated noise"])

    let resp = try await search(
        root, query: "heartbeat loop silent ok contract",
        scope: "auto", currentSessionId: "current")

    // Phrase/multi-token match in the current session: short-circuit intact.
    #expect(resp["phase"] == .string("current_session"))
}
