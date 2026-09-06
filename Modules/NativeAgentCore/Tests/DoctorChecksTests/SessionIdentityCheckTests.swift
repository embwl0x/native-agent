import Testing
import Foundation
import PersistenceCore
@testable import DoctorChecks

// MARK: - One Thread, Many Surfaces — Phase 0 Doctor row tests
//
// The plan's demand, verbatim: "Doctor row asserts non-zero on the live data
// root (a health row that reads '0' on a system with 202 sessions would be
// exactly the sweep-item-3 lie)."
//
// That live-root test is at the bottom and is deliberately NOT skipped when
// the repo's data root is present — it is the whole point of the phase.

@Suite("SessionIdentityCheck Phase 0")
struct SessionIdentityCheckTests {

    private func tmpRoot(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("si-check-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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
        let lines = try sources.map { source in
            String(
                decoding: try JSONValue.object([
                    "id": .string(UUID().uuidString),
                    "role": .string("user"),
                    "content": .string("x"),
                    "source": .string(source),
                ]).serializedData(pretty: false),
                as: UTF8.self
            )
        }
        try lines.joined(separator: "\n").appending("\n").write(
            to: dir.appendingPathComponent("\(id).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test("a fresh root reports ok with an explicit zero")
    func freshRoot() async throws {
        let root = tmpRoot("fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await SessionIdentityCheck(root: root).run()
        #expect(result.id == "session_identity")
        #expect(result.status == "ok")
        #expect(result.detail.contains("0 hot session(s)"))
    }

    @Test("an index that exists but yields no live rows FAILS rather than reading zero")
    func unreadableIndexFails() async throws {
        let root = tmpRoot("unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("chat", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("sessions.json"))

        let result = await SessionIdentityCheck(root: root).run()
        // Sweep item 3: a health row reading "0" on a populated system is the
        // lie. An unreadable index is a finding, not a clean bill.
        #expect(result.status == "fail")
        #expect(result.repair != nil)
    }

    @Test("the source-flapping detector warns and names the disagreeing session")
    func flappingWarns() async throws {
        let root = tmpRoot("flap")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSessions([
            .object(["id": .string("flapper"), "source": .string("telegram")]),
        ], to: root)
        try writeTranscript(["app", "app", "app", "telegram"], id: "flapper", to: root)

        let result = await SessionIdentityCheck(root: root).run()
        #expect(result.status == "warn")
        #expect(result.detail.contains("flapper"))
        #expect(result.detail.contains("1 session(s) whose index source disagrees"))
        // 2026-09-06 (42dd1fba): the repair used to point at "Phase 1 of the
        // one-thread-many-surfaces plan", which was a roadmap pointer, not an
        // action. Disagreement now means the index source differs from the
        // CREATION row's source, so the repair names the two artifacts to
        // compare.
        #expect(result.repair?.contains("data/chat/sessions.json") == true)
        #expect(result.repair?.contains("creation row") == true)
    }

    @Test("an empty identity feed says UNMEASURED, not zero mints")
    func emptyFeedIsUnmeasured() async throws {
        let root = tmpRoot("nofeed")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSessions([
            .object(["id": .string("s1"), "source": .string("app")]),
        ], to: root)
        try writeTranscript(["app"], id: "s1", to: root)

        let result = await SessionIdentityCheck(root: root).run()
        #expect(result.detail.contains("UNMEASURED"))
        #expect(result.detail.contains("1 hot session(s)"))
    }

    @Test("mints in the last 24h are broken out by mint site")
    func mintsByMintSite() async throws {
        let root = tmpRoot("mints")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSessions([
            .object(["id": .string("s1"), "source": .string("app")]),
        ], to: root)
        try writeTranscript(["app"], id: "s1", to: root)

        let now = Date()
        let traces = root.appendingPathComponent("turn_traces", isDirectory: true)
        try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
        let stampFormatter = DateFormatter()
        stampFormatter.calendar = Calendar(identifier: .gregorian)
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.timeZone = TimeZone.current
        stampFormatter.dateFormat = "yyyy-MM-dd"
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let row = try JSONValue.object([
            "turnId": .string("unbound"),
            "ts": .string(isoFormatter.string(from: now.addingTimeInterval(-30))),
            "kind": .string(SessionIdentityTrace.kind),
            "sessionId": .string("s1"),
            "surface": .string("telegram"),
            "payload": .object([
                "schema": .string(SessionIdentityTrace.schema),
                "mintSite": .string(SessionIdentityTrace.MintSite.telegramSessionStore.rawValue),
                "resolvedBy": .string(SessionIdentityTrace.Resolution.minted.rawValue),
            ]),
        ]).serializedData(pretty: false)
        try (String(decoding: row, as: UTF8.self) + "\n").write(
            to: traces.appendingPathComponent("\(stampFormatter.string(from: now)).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let result = await SessionIdentityCheck(root: root, now: { now }).run()
        #expect(result.detail.contains("1 minted in 24h"))
        #expect(result.detail.contains("telegram_session_store=1"))
    }

    // MARK: The live-root assertion the plan demands

    @Test("the row reads non-zero on the repository's live data root")
    func liveDataRootIsNonZero() async throws {
        // Walk up from this file to the repo root. The check must be able to
        // SEE the real 202-row index; a Phase-0 health row that reports 0
        // against it would be exactly the lie the sweep names.
        var candidate = URL(fileURLWithPath: #filePath)
        var liveRoot: URL? = nil
        for _ in 0..<10 {
            candidate = candidate.deletingLastPathComponent()
            let data = candidate.appendingPathComponent("data", isDirectory: true)
            if FileManager.default.fileExists(
                atPath: data.appendingPathComponent("chat/sessions.json").path
            ) {
                liveRoot = data
                break
            }
        }
        guard let liveRoot else {
            // A checkout with no live data tier (CI, a fresh clone) has nothing
            // to assert against. Skipping is honest; passing silently is not.
            withKnownIssue("no live data root in this checkout") {
                Issue.record("no live data root")
            }
            return
        }

        let result = await SessionIdentityCheck(root: liveRoot).run()
        #expect(result.id == "session_identity")
        // Non-zero, and said out loud.
        #expect(result.status != "fail", "live root: \(result.detail)")
        #expect(
            !result.detail.contains("0 hot session(s)"),
            "the live index has sessions; a row reading 0 is the sweep-item-3 lie: \(result.detail)"
        )
        let report = SessionIdentityLedger.flappingReport(dataRoot: liveRoot)
        #expect(report.hotSessionCount > 0)
        #expect(result.detail.contains("\(report.hotSessionCount) hot session(s)"))
    }
}
