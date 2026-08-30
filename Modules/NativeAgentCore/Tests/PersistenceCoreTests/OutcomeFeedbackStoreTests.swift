import Foundation
import NativeAgentCore
import PersistenceCore
import Testing

@Suite("Outcome feedback store")
struct OutcomeFeedbackStoreTests {
    @Test("exact feedback is injected-root hermetic and payload-free")
    func exactHermeticFeedback() async throws {
        let root = temporaryRoot("hermetic")
        try writeTranscript(root: root, sessionID: "session-a", messageID: "message-a", turnID: "turn-a")
        let store = OutcomeFeedbackStore(
            dataRoot: root,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            makeEventID: { "feedback-a" }
        )
        _ = try await store.record(sessionID: "session-a", messageID: "message-a", rating: "up")

        let path = root.appendingPathComponent("context/feedback.jsonl")
        let raw = try String(contentsOf: path, encoding: .utf8)
        #expect(raw.contains("response.feedback.v2"))
        #expect(raw.contains("thumbs_up"))
        #expect(raw.contains("turn-a"))
        #expect(raw.contains("selection-a"))
        #expect(!raw.contains("secret response body"))
        #expect(!raw.contains("Agent"))
        #expect(!raw.contains("/Users/"))
    }

    @Test("feedback refuses ambiguous transcript identity")
    func ambiguousTranscriptFailsClosed() async throws {
        let root = temporaryRoot("ambiguous")
        try writeTranscript(
            root: root,
            sessionID: "session-a",
            messageID: "message-a",
            turnID: "turn-a",
            duplicate: true
        )
        let store = OutcomeFeedbackStore(dataRoot: root)
        await #expect(throws: OutcomeFeedbackError.messageNotUnique) {
            _ = try await store.record(sessionID: "session-a", messageID: "message-a", rating: "down")
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("context/feedback.jsonl").path
        ))
    }

    @Test("corrupt existing feedback cannot be extended")
    func corruptFeedbackFailsClosed() async throws {
        let root = temporaryRoot("corrupt")
        try writeTranscript(root: root, sessionID: "session-a", messageID: "message-a", turnID: "turn-a")
        let path = root.appendingPathComponent("context/feedback.jsonl")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not-json\n".utf8).write(to: path)
        let before = try Data(contentsOf: path)
        await #expect(throws: OutcomeFeedbackError.feedbackStoreCorrupt) {
            _ = try await OutcomeFeedbackStore(dataRoot: root).record(
                sessionID: "session-a", messageID: "message-a", rating: "up"
            )
        }
        #expect(try Data(contentsOf: path) == before)
    }

    @Test("concurrent exact feedback appends remain valid")
    func concurrentFeedbackIsSerialized() async throws {
        let root = temporaryRoot("race")
        try writeTranscript(root: root, sessionID: "session-a", messageID: "message-a", turnID: "turn-a")
        async let up: JSONValue = OutcomeFeedbackStore(
            dataRoot: root, makeEventID: { "feedback-up" }
        ).record(sessionID: "session-a", messageID: "message-a", rating: "up")
        async let down: JSONValue = OutcomeFeedbackStore(
            dataRoot: root, makeEventID: { "feedback-down" }
        ).record(sessionID: "session-a", messageID: "message-a", rating: "down")
        _ = try await [up, down]

        let rows = try await SwiftNativePersistenceCore().readJSONL(
            root.appendingPathComponent("context/feedback.jsonl")
        )
        #expect(rows.count == 2)
        #expect(rows.allSatisfy {
            guard case .object(let object) = $0 else { return false }
            return object["schema"] == .string(OutcomeFeedbackStore.schema)
                && object["payloadFree"] == .bool(true)
                && object["controlAuthority"] == .bool(false)
        })
        #expect(rows.compactMap { row -> String? in
            guard case .object(let object) = row,
                  case .string(let value)? = object["supersedesEventId"] else { return nil }
            return value
        }.count == 1)
    }

    @Test("repeating the current reaction is idempotent")
    func repeatedCurrentReactionIsIdempotent() async throws {
        let root = temporaryRoot("idempotent")
        try writeTranscript(root: root, sessionID: "session-a", messageID: "message-a", turnID: "turn-a")
        let ids = LockedIDSequence(["feedback-one", "feedback-two"])
        let store = OutcomeFeedbackStore(dataRoot: root, makeEventID: { ids.next() })
        let first = try await store.record(sessionID: "session-a", messageID: "message-a", rating: "up")
        let replay = try await store.record(sessionID: "session-a", messageID: "message-a", rating: "up")
        #expect(first == replay)
        let rows = try await SwiftNativePersistenceCore().readJSONL(
            root.appendingPathComponent("context/feedback.jsonl")
        )
        #expect(rows.count == 1)
    }

    @Test("adjacent user continuation records one payload-free exact reaction")
    func adjacentContinuationIsExactAndPayloadFree() async throws {
        let root = temporaryRoot("continuation")
        try writeTranscript(root: root, sessionID: "session-a", messageID: "message-a", turnID: "turn-a")
        let path = root.appendingPathComponent("chat/messages/session-a.jsonl")
        let user: JSONValue = .object([
            "id": .string("user-message-a"),
            "sessionId": .string("session-a"),
            "role": .string("user"),
            "content": .string("private next message"),
        ])
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try user.serialize(pretty: false) + "\n").utf8))
        try handle.close()
        let store = OutcomeFeedbackStore(
            dataRoot: root,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            makeEventID: { "continuation-a" }
        )
        let first = try #require(try await store.recordConversationContinuation(
            sessionID: "session-a", reactionMessageID: "user-message-a"
        ))
        let replay = try #require(try await store.recordConversationContinuation(
            sessionID: "session-a", reactionMessageID: "user-message-a"
        ))
        #expect(first == replay)
        #expect(try await store.reactionEvidenceKeys() == Set([
            OutcomeReactionEvidenceKey(
                sessionID: "session-a", messageID: "message-a", turnID: "turn-a"
            ),
        ]))
        let raw = try String(contentsOf: root.appendingPathComponent("context/feedback.jsonl"))
        #expect(raw.contains(OutcomeFeedbackStore.continuationSchema))
        #expect(raw.contains("conversation_continued"))
        #expect(!raw.contains("private next message"))
        #expect(!raw.contains("secret response body"))
    }

    @Test("interleaved turn cannot borrow another run's continuation")
    func interleavedContinuationIsNotAttributed() async throws {
        let root = temporaryRoot("interleaved-continuation")
        try writeTranscript(
            root: root,
            sessionID: "session-a",
            messageID: "message-a",
            turnID: "turn-a"
        )
        let path = root.appendingPathComponent("chat/messages/session-a.jsonl")
        var rows = try await SwiftNativePersistenceCore().readJSONL(path)
        // Insert another assistant between the request and the target. The
        // following user row is not structurally attributable to message-a.
        rows.insert(.object([
            "id": .string("other-assistant"),
            "sessionId": .string("session-a"),
            "runId": .string("other-run"),
            "role": .string("assistant"),
            "content": .string("overlapping response"),
        ]), at: rows.count - 1)
        rows.append(.object([
            "id": .string("next-user"),
            "sessionId": .string("session-a"),
            "runId": .string("next-run"),
            "role": .string("user"),
            "content": .string("next turn"),
        ]))
        try Data((try rows.map { try $0.serialize(pretty: false) }.joined(separator: "\n") + "\n").utf8)
            .write(to: path)

        let result = try await OutcomeFeedbackStore(dataRoot: root)
            .recordConversationContinuation(
                sessionID: "session-a",
                reactionMessageID: "next-user"
            )
        #expect(result == nil)
    }

    @Test("v1 transition JSON remains observational under v2 schema")
    func oldTransitionDecodesObservational() throws {
        let raw = Data(#"{"domain":"github_command","operationId":"op","occurredAt":"2026-07-01T00:00:00Z","itemIdentity":"item","kind":"observe","beforeState":null,"afterState":"resolved","expectedNextEvidence":null,"outcome":"verified_success"}"#.utf8)
        let decoded = try JSONDecoder().decode(CausalTransitionEvidence.self, from: raw)
        #expect(decoded.isObservational)
        #expect(decoded.interventionAssignment == nil)
        #expect(decoded.trajectoryID == nil)
        #expect(decoded.sequenceNumber == nil)
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("outcome-feedback-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeTranscript(
        root: URL,
        sessionID: String,
        messageID: String,
        turnID: String,
        duplicate: Bool = false
    ) throws {
        let path = root
            .appendingPathComponent("chat/messages", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outcome: JSONValue = .object([
            "schema": .string("response.outcome-observation.v2"),
            "turnID": .string(turnID),
            "messageID": .string(messageID),
            "sessionID": .string(sessionID),
            "surface": .string("chat"),
            "contextSelectionReceiptID": .string("selection-a"),
        ])
        let runID = "run-a"
        let request: JSONValue = .object([
            "id": .string("request-a"),
            "sessionId": .string(sessionID),
            "runId": .string(runID),
            "role": .string("user"),
            "content": .string("request"),
        ])
        let row: JSONValue = .object([
            "id": .string(messageID),
            "sessionId": .string(sessionID),
            "runId": .string(runID),
            "role": .string("assistant"),
            "content": .string("secret response body"),
            "metadata": .object(["outcomeObservation": outcome]),
        ])
        let requestLine = try request.serialize(pretty: false) + "\n"
        let line = try row.serialize(pretty: false) + "\n"
        try Data((requestLine + (duplicate ? line + line : line)).utf8).write(to: path)
    }
}

private final class LockedIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]
    init(_ values: [String]) { self.values = values }
    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? UUID().uuidString.lowercased() : values.removeFirst()
    }
}
