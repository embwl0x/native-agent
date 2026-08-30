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
    _ root: URL, query: String, scope: String?, currentSessionId: String?,
    limit: Int? = nil, offset: Int? = nil
) async throws -> [String: JSONValue] {
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    var input: [String: JSONValue] = ["query": .string(query)]
    if let scope { input["scope"] = .string(scope) }
    if let currentSessionId { input["current_session_id"] = .string(currentSessionId) }
    if let limit { input["limit"] = .int(Int64(limit)) }
    if let offset { input["offset"] = .int(Int64(offset)) }
    let result = try await dispatcher.impl_search_chat_history(
        input: input, invokedAs: "search_chat_history")
    guard case .object(let obj) = result else {
        Issue.record("non-object response"); return [:]
    }
    return obj
}

private func writeEvidenceSearchSession(_ root: URL, rows: [[String: JSONValue]]) throws {
    let lines = try rows.map { row in
        String(decoding: try JSONEncoder().encode(JSONValue.object(row)), as: UTF8.self)
    }
    try Data(lines.joined(separator: "\n").utf8).write(to:
        root.appendingPathComponent("chat/messages/evidence.jsonl"))
}

@Test func explicit_history_search_preserves_recorded_speaker_and_reply_status() async throws {
    let root = try makeSearchRoot("recorded-evidence")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeEvidenceSearchSession(root, rows: [
        ["id": .string("bridge"), "role": .string("user"), "content": .string("needle request"),
         "metadata": .object(["origin": .object(["surface": .string("codex-bridge"), "agent": .string("codex")])])],
        ["id": .string("partial"), "role": .string("assistant"),
         "content": .string("needle " + String(repeating: "unfinished detail ", count: 80)),
         "metadata": .object(["partial": .bool(true)])],
        ["id": .string("cancelled"), "role": .string("assistant"), "content": .string("needle fragment"),
         "cancelled": .bool(true)],
        ["id": .string("complete"), "role": .string("assistant"), "content": .string("needle completed answer"),
         "metadata": .object(["partial": .bool(false), "cancelled": .string("true")])],
    ])
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let result = try await dispatcher.impl_search_chat_history(input: [
        "query": .string("needle"), "session_id": .string("evidence"), "mode": .string("continuity"),
    ], invokedAs: "search_chat_history")
    guard case .object(let object) = result, case .array(let hits)? = object["hits"] else {
        Issue.record("missing history hits"); return
    }
    #expect(hits.count == 4)
    var previews: [String: String] = [:]
    var excerpts: [Int64: String] = [:]
    for case .object(let hit) in hits {
        if case .string(let id)? = hit["message_id"], case .string(let preview)? = hit["preview"] {
            previews[id] = preview
            #expect(preview.count <= 368)
            if id == "bridge" { #expect(hit["role"] == .string("user")) }
        }
        if case .array(let neighbors)? = hit["surrounding_messages"] {
            for case .object(let neighbor) in neighbors {
                if case .int(let index)? = neighbor["message_index"], case .string(let excerpt)? = neighbor["excerpt"] {
                    excerpts[index] = excerpt
                    #expect(excerpt.count <= 480)
                    if index == 1 { #expect(neighbor["truncated"] == .bool(true)) }
                }
            }
        }
    }
    #expect(previews["bridge"]?.hasPrefix("[origin: Codex bridge]") == true)
    #expect(previews["partial"]?.hasPrefix("[incomplete reply: interrupted]") == true)
    #expect(previews["cancelled"]?.hasPrefix("[incomplete reply: cancelled]") == true)
    #expect(previews["complete"] == "needle completed answer")
    #expect(excerpts[0]?.hasPrefix("[origin: Codex bridge]") == true)
    #expect(excerpts[1]?.hasPrefix("[incomplete reply: interrupted]") == true)
    #expect(excerpts[2]?.hasPrefix("[incomplete reply: cancelled]") == true)
}

@Test func history_provenance_does_not_change_search_matches_or_scores() async throws {
    let plainRoot = try makeSearchRoot("plain-evidence")
    let markedRoot = try makeSearchRoot("marked-evidence")
    defer {
        try? FileManager.default.removeItem(at: plainRoot)
        try? FileManager.default.removeItem(at: markedRoot)
    }
    let plain: [String: JSONValue] = [
        "id": .string("same"), "role": .string("user"), "content": .string("cerulean request")]
    var marked = plain
    marked["metadata"] = .object([
        "origin": .object(["surface": .string("codex-bridge"), "agent": .string("codex")])])
    try writeEvidenceSearchSession(plainRoot, rows: [plain])
    try writeEvidenceSearchSession(markedRoot, rows: [marked])
    let original = try await search(plainRoot, query: "cerulean", scope: "all_sessions", currentSessionId: nil)
    let decorated = try await search(markedRoot, query: "cerulean", scope: "all_sessions", currentSessionId: nil)
    guard case .array(let originalHits)? = original["hits"], case .object(let originalHit)? = originalHits.first,
          case .array(let decoratedHits)? = decorated["hits"], case .object(let decoratedHit)? = decoratedHits.first else {
        Issue.record("missing comparison hits"); return
    }
    for key in ["score", "role", "message_id", "message_index"] {
        #expect(originalHit[key] == decoratedHit[key])
    }
    let metadataOnly = try await search(markedRoot, query: "Codex bridge", scope: "all_sessions", currentSessionId: nil)
    #expect(metadataOnly["hit_count"] == .int(0))
}

@Test func broad_results_are_compact_and_pageable() async throws {
    let root = try makeSearchRoot("compact-page")
    try writeSession(root, id: "older", lines: (0..<15).map {
        "durable compass result number \($0)"
    })

    let first = try await search(
        root, query: "durable compass", scope: "all_sessions",
        currentSessionId: nil, limit: 25)
    #expect(first["hit_count"] == .int(15))
    #expect(first["returned_count"] == .int(12))
    #expect(first["has_more"] == .bool(true))
    #expect(first["next_offset"] == .int(12))
    guard case .array(let firstHits)? = first["hits"] else {
        Issue.record("expected first result page"); return
    }
    #expect(firstHits.count == 12)

    let second = try await search(
        root, query: "durable compass", scope: "all_sessions",
        currentSessionId: nil, limit: 25, offset: 12)
    #expect(second["returned_count"] == .int(3))
    #expect(second["has_more"] == .bool(false))
    #expect(second["next_offset"] == nil)
}

@Test func history_recency_compares_instants_across_timestamp_formats() async throws {
    let root = try makeSearchRoot("timestamp-instants")
    defer { try? FileManager.default.removeItem(at: root) }
    let dates: [(String, String?)] = [
        ("whole", "2026-06-01T10:00:00Z"),
        ("offset-older", "2026-06-01T10:59:59.900+01:00"),
        ("fractional", "2026-06-01T10:00:00.500Z"),
        ("equal-offset-later-row", "2026-06-01T11:00:00.500+01:00"),
        ("invalid", "not-a-date"),
        ("missing", nil),
    ]
    try writeEvidenceSearchSession(root, rows: dates.map { id, timestamp in
        var row: [String: JSONValue] = [
            "id": .string(id), "role": .string("assistant"), "content": .string("chronology marker")]
        if let timestamp { row["createdAt"] = .string(timestamp) }
        return row
    })
    let result = try await search(root, query: "chronology marker", scope: "all_sessions", currentSessionId: nil)
    guard case .array(let hits)? = result["hits"] else {
        Issue.record("missing chronological hits"); return
    }
    let ids = hits.compactMap { hit -> String? in
        guard case .object(let row) = hit, case .string(let id)? = row["message_id"] else { return nil }
        return id
    }
    #expect(ids == ["equal-offset-later-row", "fractional", "whole", "offset-older", "missing", "invalid"])
    for case .object(let row) in hits {
        guard case .string(let id)? = row["message_id"], let original = dates.first(where: { $0.0 == id }) else { continue }
        #expect(row["timestamp"] == .string(original.1 ?? ""), "Date normalization is internal, not a rewrite of evidence.")
    }
}

@Test func history_relevance_still_precedes_chronological_tie_breaks() async throws {
    let root = try makeSearchRoot("relevance-before-time")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeEvidenceSearchSession(root, rows: [
        ["id": .string("older-exact"), "role": .string("assistant"),
         "content": .string("amber cedar"), "createdAt": .string("2026-06-01T10:00:00Z")],
        ["id": .string("newer-partial"), "role": .string("assistant"),
         "content": .string("cedar with amber"), "createdAt": .string("2026-06-02T10:00:00.500Z")],
    ])
    let result = try await search(root, query: "amber cedar", scope: "all_sessions", currentSessionId: nil)
    guard case .array(let hits)? = result["hits"], case .object(let first)? = hits.first else {
        Issue.record("missing relevance hits"); return
    }
    #expect(first["message_id"] == .string("older-exact"))
}

@Test func continuity_search_returns_bounded_neighbors_only_when_requested() async throws {
    let root = try makeSearchRoot("continuity")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root, id: "older", lines: [
        "We chose the smaller option because maintenance matters.",
        "The observatory decision is ready.",
        "Correction: wait for the replacement part before installing it.",
        String(repeating: "observatory note ", count: 100),
        "observatory final note", "observatory other note", "observatory last note",
    ])
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let response = try await dispatcher.impl_search_chat_history(input: [
        "query": .string("observatory decision"), "scope": .string("all_sessions"),
        "mode": .string("continuity"), "limit": .int(12),
    ], invokedAs: "search_chat_history")
    guard case .object(let object) = response, case .array(let hits)? = object["hits"] else {
        Issue.record("missing history results"); return
    }
    #expect(hits.count == 4)
    #expect(object["mode"] == .string("continuity"))
    #expect(String(describing: hits).contains("maintenance matters"))
    #expect(String(describing: hits).contains("replacement part"))
    for case .object(let hit) in hits {
        guard case .array(let neighbors)? = hit["surrounding_messages"] else {
            Issue.record("missing neighbors"); continue
        }
        #expect(neighbors.count <= 4)
        for case .object(let row) in neighbors {
            if case .string(let excerpt)? = row["excerpt"] { #expect(excerpt.count <= 480) }
        }
    }
    let normal = try await search(root, query: "observatory", scope: "all_sessions", currentSessionId: nil)
    #expect(!String(describing: normal["hits"]).contains("surrounding_messages"))
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
