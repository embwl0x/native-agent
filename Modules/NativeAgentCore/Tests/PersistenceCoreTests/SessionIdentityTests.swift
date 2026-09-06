import Testing
import Foundation
@testable import PersistenceCore

// MARK: - One Thread, Many Surfaces — Phase 0 tests
//
// docs/build_plans/one-thread-many-surfaces-plan.md §7 Phase 0:
//   "Tests: trace-row schema test; Doctor row asserts non-zero on the live
//    data root."
//
// This file owns the trace-row schema half and the two ledger readers the
// Doctor row is built from. The live-data-root half lives in
// DoctorChecksTests/SessionIdentityCheckTests.swift, which is where the
// check itself is tested.

@Suite("SessionIdentity Phase 0")
struct SessionIdentityTests {

    private func tmpRoot(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-identity-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: Schema

    @Test("the session.identity row carries all five plan fields")
    func traceRowSchema() throws {
        let event = SessionIdentityTrace.event(
            threadKey: "telegram:1394548068",
            sessionId: "telegram:1394548068",
            surface: "telegram",
            mintSite: .telegramSessionStore,
            resolvedBy: .minted,
            turnId: "turn-abc"
        )

        #expect(event.kind == "session.identity")
        #expect(event.turnId == "turn-abc")
        #expect(event.sessionId == "telegram:1394548068")
        #expect(event.surface == "telegram")

        guard case .object(let payload) = event.payload else {
            Issue.record("payload is not an object")
            return
        }
        #expect(payload["schema"] == .string("session.identity.v1"))
        #expect(payload["threadKey"] == .string("telegram:1394548068"))
        #expect(payload["sessionId"] == .string("telegram:1394548068"))
        #expect(payload["surface"] == .string("telegram"))
        #expect(payload["mintSite"] == .string("telegram_session_store"))
        #expect(payload["resolvedBy"] == .string("minted"))
    }

    @Test("a resolution with no thread concept writes threadKey null, not absent")
    func traceRowNullThreadKey() throws {
        let event = SessionIdentityTrace.event(
            threadKey: nil,
            sessionId: "9F0C-UUID",
            surface: "app",
            mintSite: .macAppChatSession,
            resolvedBy: .minted,
            turnId: "turn-1"
        )
        guard case .object(let payload) = event.payload else {
            Issue.record("payload is not an object")
            return
        }
        // Present-and-null, so a reader can tell "no thread yet" from "field
        // dropped". `nil` here would mean the key is missing.
        #expect(payload["threadKey"] != nil)
        #expect(payload["threadKey"] == JSONValue.null)
    }

    @Test("the row survives a JSONL round trip with no field loss")
    func traceRowRoundTrip() throws {
        let event = SessionIdentityTrace.event(
            threadKey: "slack:T1:C2",
            sessionId: "abc-123",
            surface: "slack",
            mintSite: .slackSessionStore,
            resolvedBy: .adopted,
            turnId: "turn-xyz"
        )
        let data = try event.jsonRow.serializedData(pretty: false)
        let parsed = try JSONValue.parse(data)
        let restored = try #require(TurnTraceEvent(jsonRow: parsed))

        #expect(restored.kind == event.kind)
        #expect(restored.turnId == event.turnId)
        #expect(restored.sessionId == event.sessionId)
        #expect(restored.surface == event.surface)
        #expect(restored.payload == event.payload)
    }

    @Test("resolution outside a bound turn is stamped unbound, never dropped")
    func traceRowUnboundTurn() throws {
        // The six mint sites run in the TRANSPORT, before the turn engine binds
        // a turnId. A row that required one would silence exactly what Phase 0
        // exists to observe.
        #expect(TurnTraceContext.turnId == nil)
        let event = SessionIdentityTrace.event(
            threadKey: nil,
            sessionId: "s1",
            surface: "claude-bridge",
            mintSite: .claudeBridge,
            resolvedBy: .activeRow
        )
        #expect(event.turnId == "unbound")
    }

    @Test("every plan mint site and resolution has a stable wire name")
    func vocabularyIsStable() {
        // One case per site in plan §1's table. These strings land in the
        // durable turn-trace feed and in the Doctor row's breakdown, so
        // renaming one silently breaks a reading of production history.
        #expect(Set(SessionIdentityTrace.MintSite.allCases.map(\.rawValue)) == [
            "telegram_session_store",
            "slack_session_store",
            "icloud_forwarding",
            "ios_client",
            "mac_app_chat_session",
            "claude_bridge",
        ])
        #expect(Set(SessionIdentityTrace.Resolution.allCases.map(\.rawValue)) == [
            "requested", "mapped", "activeRow", "minted", "adopted",
        ])
        #expect(Set(ChatThreadKind.allCases.map(\.rawValue)) == [
            "direct", "channel", "builder", "ephemeral", "legacy",
        ])
    }

    @Test("thread kind is inferred only from what a source actually proves")
    func threadKindInference() {
        #expect(ChatThreadKind.inferred(fromSource: "telegram") == .direct)
        #expect(ChatThreadKind.inferred(fromSource: "ios") == .direct)
        #expect(ChatThreadKind.inferred(fromSource: "app") == .direct)
        // A Slack channel has other humans in it — never a direct conversation.
        #expect(ChatThreadKind.inferred(fromSource: "slack") == .channel)
        // Anything unrecognized stays unclassified rather than guessing.
        #expect(ChatThreadKind.inferred(fromSource: "signal") == .legacy)
    }

    // MARK: Mint tally

    @Test("mintTally counts minted rows by site inside the window only")
    func mintTallyWindow() throws {
        let root = tmpRoot("tally")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let traces = root.appendingPathComponent("turn_traces", isDirectory: true)
        try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)

        func row(_ site: String, _ resolvedBy: String, at when: Date) -> String {
            let value = JSONValue.object([
                "turnId": .string("t"),
                "ts": .string(iso(when)),
                "kind": .string("session.identity"),
                "sessionId": .string("s"),
                "surface": .string("telegram"),
                "payload": .object([
                    "schema": .string("session.identity.v1"),
                    "mintSite": .string(site),
                    "resolvedBy": .string(resolvedBy),
                ]),
            ])
            return String(decoding: try! value.serializedData(pretty: false), as: UTF8.self)
        }

        var lines: [String] = [
            row("telegram_session_store", "minted", at: now.addingTimeInterval(-60)),
            row("telegram_session_store", "minted", at: now.addingTimeInterval(-120)),
            row("claude_bridge", "minted", at: now.addingTimeInterval(-180)),
            // In-window but NOT a mint — must not inflate the mint count.
            row("slack_session_store", "bound", at: now.addingTimeInterval(-240)),
            // Out of window.
            row("mac_app_chat_session", "minted", at: now.addingTimeInterval(-48 * 3600)),
        ]
        // An unrelated kind must be ignored entirely.
        lines.append(#"{"turnId":"t","ts":"\#(iso(now))","kind":"tool.dispatch","payload":{}}"#)

        try lines.joined(separator: "\n").appending("\n").write(
            to: traces.appendingPathComponent("\(dayStamp(now)).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let tally = SessionIdentityLedger.mintTally(dataRoot: root, now: now)
        #expect(tally.mintedByMintSite["telegram_session_store"] == 2)
        #expect(tally.mintedByMintSite["claude_bridge"] == 1)
        #expect(tally.mintedByMintSite["slack_session_store"] == nil)
        #expect(tally.mintedByMintSite["mac_app_chat_session"] == nil)
        #expect(tally.totalMinted == 3)
        // 4 identity rows in window (3 mints + 1 bound); the out-of-window mint
        // and the tool.dispatch row are excluded.
        #expect(tally.totalRows == 4)
        #expect(tally.daysRead >= 1)
    }

    @Test("mintTally on a root with no feed reports zero days read, not zero mints")
    func mintTallyNoFeed() {
        let root = tmpRoot("no-feed")
        defer { try? FileManager.default.removeItem(at: root) }
        let tally = SessionIdentityLedger.mintTally(dataRoot: root)
        #expect(tally.daysRead == 0)
        #expect(tally.totalRows == 0)
        #expect(tally.totalMinted == 0)
    }

    // MARK: Flapping detector (§1.3)

    private func writeSessions(_ rows: [JSONValue], to root: URL) throws {
        let dir = root.appendingPathComponent("chat", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONValue.array(rows).serializedData(pretty: false)
            .write(to: dir.appendingPathComponent("sessions.json"))
    }

    private func writeTranscript(_ sources: [String], id: String, to root: URL) throws {
        let dir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = sources.map { source in
            String(decoding: try! JSONValue.object([
                "id": .string(UUID().uuidString),
                "role": .string("user"),
                "content": .string("x"),
                "source": .string(source),
            ]).serializedData(pretty: false), as: UTF8.self)
        }
        try lines.joined(separator: "\n").appending("\n").write(
            to: dir.appendingPathComponent("\(id).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test("the flapping detector names a session whose index source lost to a later surface")
    func flappingDetected() throws {
        let root = tmpRoot("flap")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSessions([
            // Overwritten by the last surface to append: the row says telegram,
            // but the transcript is overwhelmingly app. This is §1.3.
            .object(["id": .string("flapper"), "source": .string("telegram")]),
            .object(["id": .string("steady"), "source": .string("app")]),
            .object(["id": .string("gone"), "source": .string("app"), "archived": .bool(true)]),
        ], to: root)
        try writeTranscript(["app", "app", "app", "telegram"], id: "flapper", to: root)
        try writeTranscript(["app", "app"], id: "steady", to: root)

        let report = SessionIdentityLedger.flappingReport(dataRoot: root)
        #expect(report.hotSessionCount == 2, "the archived row must not count as hot")
        #expect(report.disagreeingSessionIds == ["flapper"])
        #expect(report.mixedSourceSessionCount == 1)
        #expect(report.unreadableSessionCount == 0)
    }

    @Test("a session with no readable transcript is reported unread, never as agreeing")
    func unreadableIsNotSilentlyClean() throws {
        let root = tmpRoot("unread")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSessions([
            .object(["id": .string("orphan"), "source": .string("app")]),
        ], to: root)

        let report = SessionIdentityLedger.flappingReport(dataRoot: root)
        #expect(report.hotSessionCount == 1)
        #expect(report.unreadableSessionCount == 1)
        #expect(report.disagreeingSessionIds.isEmpty)
    }

    @Test("index source is compared against the same normalization the writer applies")
    func sourceNormalizationMatchesWriter() throws {
        let root = tmpRoot("normalize")
        defer { try? FileManager.default.removeItem(at: root) }
        // `iphone`/`icloud`/`mobile` all normalize to `ios`, and `chat`/`mac`
        // to `app` — exactly as ChatOrchestrationClient.messageSource(for:)
        // does when it writes the row. Comparing raw strings would report a
        // disagreement that does not exist.
        try writeSessions([
            .object(["id": .string("phone"), "source": .string("ios")]),
        ], to: root)
        try writeTranscript(["iphone", "icloud", "mobile"], id: "phone", to: root)

        let report = SessionIdentityLedger.flappingReport(dataRoot: root)
        #expect(report.disagreeingSessionIds.isEmpty)
        #expect(SessionIdentityLedger.normalizedSource("Mac") == "app")
        #expect(SessionIdentityLedger.normalizedSource("") == "app")
        #expect(SessionIdentityLedger.normalizedSource("slack") == "slack")
    }
}
