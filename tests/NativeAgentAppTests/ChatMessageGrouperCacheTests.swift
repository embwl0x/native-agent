import Foundation
import Testing
@testable import NativeAgentApp

// Coverage ledger app.chat / api.MessageGrouper.groups (REPORTS-ONLY → COVERED).
//
// Silent-failure mode being pinned: the O(1) streaming patch path in
// `_MessageGroupCache` serves a cached grouping whose visibility rules no longer
// match `MessageGrouper._compute`, so a row `_compute` would now hide stays on
// screen — and a dropped sessionId key makes two transcripts share a slot, so a
// detached panel renders another session's bubbles. Neither throws, neither
// logs; the transcript just quietly shows the wrong thing.
//
// The envelope asserted here is EQUIVALENCE, not exact groupings: for every
// mutation the app actually performs on a transcript (append, streaming growth
// of the last assistant row, equal-length replacement, role flip, tool-run
// append, wholesale reload), the cached
// `groups(for:sessionId:structureVersion:)` must equal `_compute(for:)` — the
// uncached ground truth.
//
// 2026-09-06: the slot key gained `structureVersion` (6abb124a) — AppModel's
// transcript mutation counter — replacing a total-content-byte count that a
// same-length interior rewrite could slip past. Every transcript write bumps
// it EXCEPT the streaming delta, which rewrites only the FINAL row and which
// the cache patches in place (`setChatMessagesTailOnly`). These tests drive
// the counter by the same rule, so a cache hit here is a cache hit in the app.

private func grouperMessage(
    id: String,
    role: String,
    content: String,
    kind: String? = nil
) -> ChatMessage {
    var metadata: ChatMessageMetadata?
    if let kind {
        var m = ChatMessageMetadata()
        m.kind = kind
        metadata = m
    }
    return ChatMessage(
        id: id,
        role: role,
        content: content,
        createdAt: "2026-08-23T00:00:00Z",
        metadata: metadata
    )
}

/// Structural projection of a grouping — group identity + membership + the
/// rendered payload of every row. Compared instead of exact literals so the
/// test pins the cache-vs-recompute contract, not one hard-coded layout.
private func grouperProjection(_ groups: [MessageGroup]) -> [String] {
    groups.map { group in
        let rows = group.messages
            .map { "\($0.id)|\($0.role)|\($0.content)" }
            .joined(separator: "~")
        return "\(group.id)|tool=\(group.isToolGroup)|\(rows)"
    }
}

@Suite("Chat message grouper cache")
struct ChatMessageGrouperCacheTests {

    @Test func streamingCacheDoesNotHashTheGrowingMessageOrBuildCompositeKeys() throws {
        let source = try AppSourceScraping.appSource("ChatMessageListView.swift")
        let cacheStart = try #require(source.range(of: "private final class _MessageGroupCache"))
        let grouperStart = try #require(source.range(of: "enum MessageGrouper", range: cacheStart.upperBound..<source.endIndex))
        let cacheSource = source[cacheStart.lowerBound..<grouperStart.lowerBound]

        #expect(!cacheSource.contains("hashValue"))
        #expect(cacheSource.contains("private struct StableKey: Equatable"))
        #expect(cacheSource.contains("patched.messages[0] = last"))
    }

    /// Every mutation shape the transcript actually undergoes must leave the
    /// cached grouping identical to a fresh `_compute`. A stale slot is exactly
    /// how a hidden row survives on screen.
    @Test func cachedGroupingEqualsRecomputeForEveryLiveMutationShape() {
        let sessionId = "grouper-mutations-\(UUID().uuidString)"
        var messages: [ChatMessage] = []
        // Mirrors `AppModel.chatMessagesStructureVersion`: bumped by every
        // transcript write, held only for a tail-row rewrite (the streaming
        // delta's `setChatMessagesTailOnly`), which is the one mutation the
        // cache is allowed to serve from its O(1) patch path.
        var structureVersion: UInt64 = 0

        func check(_ label: String, tailOnlyWrite: Bool = false) {
            if !tailOnlyWrite { structureVersion &+= 1 }
            let cached = MessageGrouper.groups(
                for: messages,
                sessionId: sessionId,
                structureVersion: structureVersion
            )
            let fresh = MessageGrouper._compute(for: messages)
            #expect(
                grouperProjection(cached) == grouperProjection(fresh),
                "cached grouping diverged from _compute after \(label)"
            )
        }

        // 1. empty transcript
        check("empty transcript")

        // 2. first user turn
        messages.append(grouperMessage(id: "u1", role: "user", content: "hello"))
        check("first user append")

        // 3. streaming assistant bubble appears empty, then grows in place —
        //    the O(1) patch path.
        messages.append(grouperMessage(id: "a1", role: "assistant", content: ""))
        check("empty assistant placeholder")
        for token in ["He", "Hello", "Hello t", "Hello there"] {
            messages[messages.count - 1].content = token
            check("streaming delta \(token)", tailOnlyWrite: true)
        }

        // 4. equal-length replacement of the last row (metadata-free rewrite,
        //    e.g. the optimistic bubble swapped for the persisted text). Same
        //    length means a content-LENGTH-keyed cache would miss this.
        messages[messages.count - 1].content = "Hello THERE"
        // `updateChatMessageContent` on the FINAL row is a tail-only write, so
        // the version holds and the cache must patch rather than recompute.
        check("equal-length last-row replacement", tailOnlyWrite: true)

        // 5. tool run appends — consecutive tool rows collapse into one group.
        messages.append(grouperMessage(id: "t1", role: "tool", content: "read_file", kind: "tool_use"))
        check("first tool row")
        messages.append(grouperMessage(id: "t2", role: "tool", content: "write_file", kind: "tool_use"))
        check("second tool row (same run)")
        messages.append(grouperMessage(id: "a2", role: "assistant", content: "done"))
        check("assistant reply after the tool run")

        // 6. role flip on the last row: an assistant row rewritten as a
        //    `[tool:` system summary is HIDDEN by _compute. The stale-visibility
        //    failure mode lives exactly here.
        messages[messages.count - 1].role = "system"
        messages[messages.count - 1].content = "[tool: read_file] ok"
        check("last row flipped to a hidden [tool: system row")

        // 7. wholesale reload with a different tail (end-of-turn disk refresh).
        messages = [
            grouperMessage(id: "u1", role: "user", content: "hello"),
            grouperMessage(id: "a1", role: "assistant", content: "Hello THERE"),
            grouperMessage(id: "t1", role: "tool", content: "read_file", kind: "tool_use"),
            grouperMessage(id: "t2", role: "tool", content: "write_file", kind: "tool_use"),
            grouperMessage(id: "a9", role: "assistant", content: "reloaded"),
        ]
        check("wholesale reload")

        // 8. truncation (session cleared back to a single row).
        messages = [grouperMessage(id: "u1", role: "user", content: "hello")]
        check("truncation to one row")
    }

    /// A hidden `[tool:` system row must never reach a group, and consecutive
    /// tool rows must land in exactly one tool group. This is the visibility
    /// contract the cache is allowed to memoize — pinned directly so a cache
    /// hit can't be "equal to a _compute that itself regressed".
    @Test func computeHidesToolSummaryRowsAndCollapsesConsecutiveToolRows() {
        let messages = [
            grouperMessage(id: "u1", role: "user", content: "hi"),
            grouperMessage(id: "s1", role: "system", content: "[tool: read_file] summary"),
            grouperMessage(id: "t1", role: "tool", content: "a", kind: "tool_use"),
            grouperMessage(id: "t2", role: "tool", content: "b", kind: "tool_use"),
            grouperMessage(id: "a1", role: "assistant", content: "answer"),
        ]
        let groups = MessageGrouper._compute(for: messages)
        let renderedIDs = groups.flatMap { $0.messages.map(\.id) }
        #expect(!renderedIDs.contains("s1"), "a [tool: system summary row rendered as a bubble")
        #expect(renderedIDs.contains("u1") && renderedIDs.contains("a1"))
        let toolGroups = groups.filter(\.isToolGroup)
        #expect(toolGroups.count == 1, "consecutive tool rows must collapse into one group")
        #expect(toolGroups.first?.messages.map(\.id) == ["t1", "t2"])
        // The run's id is stable on the FIRST tool row so appending a tool
        // UPDATES the group instead of recreating the view.
        #expect(toolGroups.first?.id == "toolrun-t1")
    }

    /// Two sessions interleaved through the shared cache must never see each
    /// other's rows. The sessionId is part of the slot key precisely so a
    /// detached panel can't thrash (or poison) the main window's transcript.
    @Test func interleavedSessionsNeverShareACacheSlot() {
        let a = "grouper-A-\(UUID().uuidString)"
        let b = "grouper-B-\(UUID().uuidString)"
        // Deliberately identical SHAPE (same count, same last role) with
        // different ids/content: a cache keyed on shape alone would collide.
        var messagesA = [
            grouperMessage(id: "a-u1", role: "user", content: "from A"),
            grouperMessage(id: "a-a1", role: "assistant", content: "A reply"),
        ]
        var messagesB = [
            grouperMessage(id: "b-u1", role: "user", content: "from B"),
            grouperMessage(id: "b-a1", role: "assistant", content: "B reply"),
        ]

        // Both sessions share one counter in AppModel; a streaming delta on
        // either tail holds it, so the shape+version key is identical for the
        // two transcripts and only the sessionId keeps their slots apart.
        let structureVersion: UInt64 = 1
        for step in 0..<6 {
            messagesA[1].content = "A reply \(step)"
            messagesB[1].content = "B reply \(step)"
            let groupsA = MessageGrouper.groups(
                for: messagesA, sessionId: a, structureVersion: structureVersion)
            let groupsB = MessageGrouper.groups(
                for: messagesB, sessionId: b, structureVersion: structureVersion)
            #expect(grouperProjection(groupsA) == grouperProjection(MessageGrouper._compute(for: messagesA)))
            #expect(grouperProjection(groupsB) == grouperProjection(MessageGrouper._compute(for: messagesB)))
            #expect(groupsA.flatMap { $0.messages.map(\.id) }.allSatisfy { $0.hasPrefix("a-") },
                    "session A rendered a row belonging to another session")
            #expect(groupsB.flatMap { $0.messages.map(\.id) }.allSatisfy { $0.hasPrefix("b-") },
                    "session B rendered a row belonging to another session")
        }
    }

    /// The slot table is FIFO-capped. Eviction must degrade to a recompute,
    /// never to a wrong grouping — the cap is a memory bound, not a
    /// correctness knob.
    @Test func fifoEvictionDegradesToRecomputeNotToAWrongGrouping() {
        let run = UUID().uuidString
        let sessionIDs = (0..<12).map { "grouper-cap-\($0)-\(run)" }
        var transcripts: [String: [ChatMessage]] = [:]
        // Each session load is a transcript write, so the shared counter
        // advances; the render loop below performs no writes and holds it.
        var structureVersion: UInt64 = 0
        for (index, sid) in sessionIDs.enumerated() {
            transcripts[sid] = [
                grouperMessage(id: "\(sid)-u", role: "user", content: "q\(index)"),
                grouperMessage(id: "\(sid)-a", role: "assistant", content: "reply \(index)"),
            ]
            structureVersion &+= 1
            _ = MessageGrouper.groups(
                for: transcripts[sid]!, sessionId: sid, structureVersion: structureVersion)
        }
        // Every session — including the ones evicted by the 8-slot cap — must
        // still group exactly as a fresh compute would.
        for sid in sessionIDs {
            let messages = transcripts[sid]!
            #expect(
                grouperProjection(MessageGrouper.groups(
                    for: messages, sessionId: sid, structureVersion: structureVersion))
                    == grouperProjection(MessageGrouper._compute(for: messages)),
                "grouping for \(sid) diverged after FIFO eviction"
            )
        }
    }
}
