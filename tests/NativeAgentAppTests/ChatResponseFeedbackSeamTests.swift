import Foundation
import Testing
@testable import NativeAgentApp

// Coverage ledger app.chat / store.chat.responseFeedback (UNCOVERED → COVERED,
// for the app seam).
//
// Silent-failure mode being pinned: the thumbs control toasts only on a THROW.
// The app seam (`NativeClient.postContextFeedback`) hands the store the ids the
// bubble held; if those ids are passed in the wrong roles — or a press lands on
// a row that is not in the canonical transcript — the store must REFUSE. A
// validate-then-drop (or a write under a wrong id) leaves the UI saying thanks
// while `data/context/feedback.jsonl` learns nothing, and nobody reads that feed
// to notice.
//
// Hermetic: every call pins an explicit temp `dataRoot`; nothing touches the
// live data root. (The core store's own rules are covered by
// PersistenceCoreTests/OutcomeFeedbackStoreTests — this pins the APP seam:
// argument roles, the write landing in the pinned root, and refusal behaviour.)

private struct FeedbackFixture {
    let root: URL
    let sessionID: String
    let messageID: String

    static func make(
        sessionID: String = "sess-feedback",
        messageID: String = "msg-assistant-1"
    ) throws -> FeedbackFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nativeagent-feedback-\(UUID().uuidString)", isDirectory: true)
        let messages = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let anchoredRow: [String: Any] = [
            "id": messageID,
            "role": "assistant",
            "content": "the reply the user reacted to",
            "createdAt": "2026-08-23T00:00:00Z",
            "metadata": [
                "outcomeObservation": [
                    "schema": "response.outcome-observation.v2",
                    "turnID": "turn-1",
                    "messageID": messageID,
                    "sessionID": sessionID,
                    "surface": "mac_chat",
                ],
            ],
        ]
        let userRow: [String: Any] = [
            "id": "msg-user-1",
            "role": "user",
            "content": "question",
            "createdAt": "2026-08-23T00:00:00Z",
        ]
        let lines = try [userRow, anchoredRow].map { row -> String in
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: messages.appendingPathComponent("\(sessionID).jsonl"))
        return FeedbackFixture(root: root, sessionID: sessionID, messageID: messageID)
    }

    var feedbackRows: [[String: Any]] {
        let path = root
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("feedback.jsonl")
        guard let data = try? Data(contentsOf: path) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                guard let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
                    return nil
                }
                return parsed as? [String: Any]
            }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Chat response feedback seam")
struct ChatResponseFeedbackSeamTests {

    /// One thumbs press writes exactly one row, into the PINNED root, carrying
    /// the same ids the bubble held.
    @Test func oneThumbsPressWritesExactlyOneCorrelatedRowInThePinnedRoot() async throws {
        let fixture = try FeedbackFixture.make()
        defer { fixture.cleanUp() }
        let client = NativeClient(baseURL: "http://127.0.0.1:1")

        try await client.postContextFeedback(
            messageId: fixture.messageID,
            sessionId: fixture.sessionID,
            rating: "up",
            persona: "agent",
            dataRoot: fixture.root
        )

        let rows = fixture.feedbackRows
        #expect(rows.count == 1, "expected exactly one feedback row, got \(rows.count)")
        let row = try #require(rows.first)
        #expect(row["messageId"] as? String == fixture.messageID,
                "the row does not carry the message the user reacted to")
        #expect(row["sessionId"] as? String == fixture.sessionID,
                "the row does not carry the session the bubble belonged to")
        #expect(row["reaction"] as? String == "thumbs_up")
        #expect(row["payloadFree"] as? Bool == true,
                "the feedback row started carrying payload")
        // Payload-free means the reply text never leaves the transcript.
        let encoded = String(
            decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self
        )
        #expect(!encoded.contains("the reply the user reacted to"))
        #expect(!encoded.contains("agent"), "persona leaked into the feedback receipt")
    }

    /// Swapping the two ids must be REFUSED. This is the exact wrong-id write
    /// the toast cannot see: both arguments are non-empty strings, so only the
    /// transcript check can catch it.
    @Test func swappedSessionAndMessageIdsAreRefusedRatherThanWritten() async throws {
        let fixture = try FeedbackFixture.make()
        defer { fixture.cleanUp() }
        let client = NativeClient(baseURL: "http://127.0.0.1:1")

        await #expect(throws: (any Error).self) {
            try await client.postContextFeedback(
                messageId: fixture.sessionID,     // swapped
                sessionId: fixture.messageID,     // swapped
                rating: "up",
                persona: "agent",
                dataRoot: fixture.root
            )
        }
        #expect(fixture.feedbackRows.isEmpty,
                "a swapped-id press still wrote a feedback row")
    }

    /// A press on a message that is not in the canonical transcript (a purely
    /// in-memory error bubble, a stale row after a reload) must refuse.
    @Test func aPressOnAMessageAbsentFromTheTranscriptIsRefused() async throws {
        let fixture = try FeedbackFixture.make()
        defer { fixture.cleanUp() }
        let client = NativeClient(baseURL: "http://127.0.0.1:1")

        await #expect(throws: (any Error).self) {
            try await client.postContextFeedback(
                messageId: "msg-never-persisted",
                sessionId: fixture.sessionID,
                rating: "down",
                persona: "agent",
                dataRoot: fixture.root
            )
        }
        // A USER row is not a response — reacting to one must refuse too.
        await #expect(throws: (any Error).self) {
            try await client.postContextFeedback(
                messageId: "msg-user-1",
                sessionId: fixture.sessionID,
                rating: "down",
                persona: "agent",
                dataRoot: fixture.root
            )
        }
        #expect(fixture.feedbackRows.isEmpty,
                "a press on an unanchored row still wrote feedback")
    }

    /// Repeated presses of the SAME rating stay one row (no calibration weight
    /// manufactured by a double-click), while a flip to the other rating is
    /// recorded as a new row that supersedes the first.
    @Test func repeatedPressesAreIdempotentAndAFlipSupersedes() async throws {
        let fixture = try FeedbackFixture.make()
        defer { fixture.cleanUp() }
        let client = NativeClient(baseURL: "http://127.0.0.1:1")

        for _ in 0..<3 {
            try await client.postContextFeedback(
                messageId: fixture.messageID,
                sessionId: fixture.sessionID,
                rating: "up",
                persona: "agent",
                dataRoot: fixture.root
            )
        }
        #expect(fixture.feedbackRows.count == 1,
                "a repeated identical press manufactured extra rows")

        try await client.postContextFeedback(
            messageId: fixture.messageID,
            sessionId: fixture.sessionID,
            rating: "down",
            persona: "agent",
            dataRoot: fixture.root
        )
        let rows = fixture.feedbackRows
        #expect(rows.count == 2, "a rating flip was dropped instead of recorded")
        #expect(rows.last?["reaction"] as? String == "thumbs_down")
        #expect(rows.last?["supersedesEventId"] as? String == rows.first?["eventId"] as? String,
                "the flip does not point at the reaction it replaces")
    }

    /// An unknown rating must never reach the store, and nothing is written for
    /// it. The bubble only ever sends up/down; a new one must fail loudly.
    @Test func anUnknownRatingIsRefused() async throws {
        let fixture = try FeedbackFixture.make()
        defer { fixture.cleanUp() }
        let client = NativeClient(baseURL: "http://127.0.0.1:1")

        await #expect(throws: (any Error).self) {
            try await client.postContextFeedback(
                messageId: fixture.messageID,
                sessionId: fixture.sessionID,
                rating: "sideways",
                persona: "agent",
                dataRoot: fixture.root
            )
        }
        #expect(fixture.feedbackRows.isEmpty)
    }
}
