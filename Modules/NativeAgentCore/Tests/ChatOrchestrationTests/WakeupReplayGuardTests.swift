import Testing
import Foundation
@testable import ChatOrchestration
import PersistenceCore

// MARK: - Stale-wakeup replay guard tests (W2b, upgrade campaign 2026-08)
//
// L1#14: "the bridge is still replaying old wakeups as if they are new." The
// guard suppresses a re-fire only when the SAME text on the SAME topic already
// ran to completion AND its answer was confirmed delivered, within a window.
//
// Every fixture below is written from the RECORD SHAPES READ OFF THE LIVE
// STORES on 2026-08-11, not from a description:
//   claude wake-job: { messageId, createdAt, completedAt, state, status,
//                       bridgeStatus, deliveryLost, topicSlug, payload{text,topic} }
//   omp wake-job:     same minus topicSlug/bridgeStatus, plus bridge{status}
//   codex reply-job:  { id, entries[].payload{text,topic},
//                       completedExecution.turnResult{status, completedAt} }
//
// The NON-suppressions are the load-bearing half of this suite: a guard that
// over-fires silently strands real delegated work, which is strictly worse than
// the duplicate wake it exists to prevent.

@Suite("WakeupReplayGuard")
struct WakeupReplayGuardTests {

    // 2026-08-11T12:00:00Z
    private static let now = Date(timeIntervalSince1970: 1_786_449_600)

    @Test func fixedClockIsTheInstantTheFixturesAssume() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(formatter.string(from: Self.now) == "2026-08-11T12:00:00Z")
    }

    private static func iso(_ offsetSeconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(offsetSeconds))
    }

    private func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayGuard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ json: JSONValue, to dir: URL, named name: String) {
        let data = (try? json.serializedData(pretty: false)) ?? Data()
        try? data.write(to: dir.appendingPathComponent(name))
    }

    private static let text = "Build the delegation outcome loop."

    private func claudeJob(
        id: String = "msg-1",
        topicSlug: String? = "w2b-delegation",
        topic: String = "w2b delegation",
        text: String = WakeupReplayGuardTests.text,
        status: String = "completed",
        completedAt: String? = iso(-600),
        bridgeStatus: String? = "delivered",
        deliveryLost: Bool? = false
    ) -> JSONValue {
        var obj: [String: JSONValue] = [
            "messageId": .string(id),
            "createdAt": .string(Self.iso(-1_200)),
            "state": .string("settled"),
            "status": .string(status),
            "payload": .object([
                "messageId": .string(id),
                "text": .string(text),
                "topic": .string(topic),
            ]),
        ]
        if let topicSlug { obj["topicSlug"] = .string(topicSlug) }
        if let completedAt { obj["completedAt"] = .string(completedAt) }
        if let bridgeStatus { obj["bridgeStatus"] = .string(bridgeStatus) }
        if let deliveryLost { obj["deliveryLost"] = .bool(deliveryLost) }
        return .object(obj)
    }

    private func find(
        store: WakeupReplayGuard.Store = .claude,
        dir: URL,
        topic: String? = "w2b delegation",
        text: String = WakeupReplayGuardTests.text,
        now: Date = WakeupReplayGuardTests.now
    ) -> WakeupReplayGuard.Match? {
        WakeupReplayGuard.terminalDuplicate(
            store: store, jobsDirectory: dir, topic: topic, text: text, now: now)
    }

    // MARK: - The suppression it exists for

    @Test func identicalCompletedDeliveredClaudeJobSuppressesTheWakeup() throws {
        let dir = makeDir()
        write(claudeJob(), to: dir, named: "msg-1.json")
        let match = try #require(find(dir: dir))
        #expect(match.jobId == "msg-1")
        #expect(match.topicSlug == "w2b-delegation")
        #expect(match.storeLabel == "claude")
    }

    @Test func receiptSaysSkippedAlreadyCompletedAndNamesTheJob() throws {
        let dir = makeDir()
        write(claudeJob(), to: dir, named: "msg-1.json")
        let match = try #require(find(dir: dir))
        guard case .object(let obj) = WakeupReplayGuard.receipt(match) else {
            Issue.record("receipt is not an object"); return
        }
        #expect(obj["status"] == .string("skipped"))
        #expect(obj["reason"] == .string("already_completed"))
        #expect(obj["jobId"] == .string("msg-1"))
        // The receipt must tell the caller the durable row still landed —
        // otherwise "skipped" reads as "your message was dropped".
        guard case .string(let detail)? = obj["detail"] else { Issue.record("no detail"); return }
        #expect(detail.contains("durable inbox row was still written"))
    }

    /// The newest matching run is the one named, so the receipt points at the
    /// job the caller would actually be duplicating.
    @Test func newestMatchingJobWins() throws {
        let dir = makeDir()
        write(claudeJob(id: "older", completedAt: Self.iso(-7_000)), to: dir, named: "a.json")
        write(claudeJob(id: "newer", completedAt: Self.iso(-60)), to: dir, named: "b.json")
        #expect(try #require(find(dir: dir)).jobId == "newer")
    }

    // MARK: - The non-suppressions (the half that must never over-fire)

    @Test func differentTextOnTheSameTopicAlwaysGoesThrough() {
        let dir = makeDir()
        write(claudeJob(), to: dir, named: "msg-1.json")
        #expect(find(dir: dir, text: "Now write the tests.") == nil)
    }

    @Test func sameTextOnADifferentTopicGoesThrough() {
        let dir = makeDir()
        write(claudeJob(), to: dir, named: "msg-1.json")
        #expect(find(dir: dir, topic: "some other topic") == nil)
    }

    @Test func inFlightJobIsNotAReplay() {
        let dir = makeDir()
        write(claudeJob(status: "running", completedAt: nil, bridgeStatus: nil, deliveryLost: nil),
              to: dir, named: "msg-1.json")
        #expect(find(dir: dir) == nil)
    }

    /// Re-sending after a FAILED run is the whole point of re-sending.
    @Test func failedPriorRunIsNotSuppressed() {
        let dir = makeDir()
        write(claudeJob(status: "failed"), to: dir, named: "msg-1.json")
        #expect(find(dir: dir) == nil)
    }

    /// A lost answer must stay re-askable — suppressing here would strand the
    /// work permanently, which is strictly worse than a duplicate wake.
    @Test func lostDeliveryIsNotSuppressed() {
        let dir = makeDir()
        write(claudeJob(bridgeStatus: "failed", deliveryLost: true), to: dir, named: "msg-1.json")
        #expect(find(dir: dir) == nil)
    }

    @Test func unconfirmedDeliveryIsNotSuppressed() {
        let dir = makeDir()
        write(claudeJob(bridgeStatus: "unknown", deliveryLost: false), to: dir, named: "msg-1.json")
        #expect(find(dir: dir) == nil)
    }

    @Test func aJobWithNoBridgeRecordAtAllIsNotSuppressed() {
        let dir = makeDir()
        write(claudeJob(bridgeStatus: nil, deliveryLost: nil), to: dir, named: "msg-1.json")
        #expect(find(dir: dir) == nil)
    }

    @Test func anIdenticalRequestOutsideTheWindowGoesThrough() {
        let dir = makeDir()
        write(claudeJob(completedAt: Self.iso(-(48 * 60 * 60))), to: dir, named: "msg-1.json")
        #expect(find(dir: dir) == nil)
    }

    /// Terminal-by-status with no completion stamp cannot be dated, so it must
    /// not suppress: an undateable record is not evidence of a recent run.
    @Test func terminalWithoutACompletionStampIsNotSuppressed() {
        let dir = makeDir()
        write(claudeJob(completedAt: nil), to: dir, named: "msg-1.json")
        #expect(find(dir: dir) == nil)
    }

    @Test func emptyOrMissingStoreNeverSuppresses() {
        #expect(find(dir: makeDir()) == nil)
        #expect(find(dir: URL(fileURLWithPath: "/nonexistent/wake-jobs-\(UUID().uuidString)")) == nil)
    }

    @Test func malformedRecordsAreSkippedNotFatal() throws {
        let dir = makeDir()
        try? Data("{not json".utf8).write(to: dir.appendingPathComponent("bad.json"))
        try? Data("[]".utf8).write(to: dir.appendingPathComponent("array.json"))
        write(claudeJob(), to: dir, named: "good.json")
        #expect(try #require(find(dir: dir)).jobId == "msg-1")
    }

    @Test func emptyRequestTextNeverSuppresses() {
        let dir = makeDir()
        write(claudeJob(text: ""), to: dir, named: "msg-1.json")
        #expect(find(dir: dir, text: "") == nil)
    }

    // MARK: - OMP store shape (no topicSlug field; bridge is an object)

    @Test func ompRecordSlugsItsTopicFromThePayload() throws {
        let dir = makeDir()
        let record: JSONValue = .object([
            "messageId": .string("omp-1"),
            "state": .string("settled"),
            "status": .string("completed"),
            "completedAt": .string(Self.iso(-300)),
            "bridge": .object(["status": .string("delivered")]),
            "payload": .object([
                "text": .string(Self.text),
                "topic": .string("W2b Delegation"),
            ]),
        ])
        write(record, to: dir, named: "omp-1.json")
        let match = try #require(find(store: .omp, dir: dir))
        #expect(match.jobId == "omp-1")
        // Slugged through the dispatcher's own function: "W2b Delegation" and
        // "w2b delegation" must land on the same slug or the guard is blind.
        #expect(match.topicSlug == "w2b-delegation")
        #expect(match.storeLabel == "omp")
    }

    @Test func ompUndeliveredBridgeStatusIsNotSuppressed() {
        let dir = makeDir()
        let record: JSONValue = .object([
            "messageId": .string("omp-1"),
            "status": .string("completed"),
            "completedAt": .string(Self.iso(-300)),
            "bridge": .object(["status": .string("unknown")]),
            "payload": .object([
                "text": .string(Self.text),
                "topic": .string("w2b delegation"),
            ]),
        ])
        write(record, to: dir, named: "omp-1.json")
        #expect(find(store: .omp, dir: dir) == nil)
    }

    // MARK: - Codex store shape

    private func codexJob(
        id: String = "codex-1",
        status: String = "completed",
        completedAt: String? = iso(-300),
        text: String = WakeupReplayGuardTests.text,
        topic: String = "w2b delegation"
    ) -> JSONValue {
        var turnResult: [String: JSONValue] = ["status": .string(status)]
        if let completedAt { turnResult["completedAt"] = .string(completedAt) }
        return .object([
            "id": .string(id),
            "phase": .string("watching_turn"),
            "entries": .array([
                .object(["payload": .object([
                    "text": .string(text),
                    "topic": .string(topic),
                ])]),
            ]),
            "completedExecution": .object(["turnResult": .object(turnResult)]),
        ])
    }

    @Test func codexTerminalRecordStillInReplyJobsSuppresses() throws {
        let dir = makeDir()
        write(codexJob(), to: dir, named: "codex-1.json")
        let match = try #require(find(store: .codex, dir: dir))
        #expect(match.jobId == "codex-1")
        #expect(match.storeLabel == "codex")
    }

    @Test func codexJobWithNoCompletedExecutionIsNotSuppressed() {
        let dir = makeDir()
        write(.object([
            "id": .string("codex-1"),
            "phase": .string("watching_turn"),
            "entries": .array([
                .object(["payload": .object([
                    "text": .string(Self.text),
                    "topic": .string("w2b delegation"),
                ])]),
            ]),
        ]), to: dir, named: "codex-1.json")
        #expect(find(store: .codex, dir: dir) == nil)
    }

    @Test func codexFailedTurnIsNotSuppressed() {
        let dir = makeDir()
        write(codexJob(status: "failed"), to: dir, named: "codex-1.json")
        #expect(find(store: .codex, dir: dir) == nil)
    }

    /// `undelivered/` is a SUBDIRECTORY of reply-jobs and is never scanned —
    /// a preserved undeliverable job must stay re-askable. This pins that the
    /// scan does not descend.
    @Test func codexUndeliveredSubdirectoryIsNotScanned() {
        let dir = makeDir()
        let undelivered = dir.appendingPathComponent("undelivered", isDirectory: true)
        try? FileManager.default.createDirectory(at: undelivered, withIntermediateDirectories: true)
        write(codexJob(), to: undelivered, named: "codex-1.json")
        #expect(find(store: .codex, dir: dir) == nil)
    }

    // MARK: - Directory resolution + escape hatch

    @Test func configRootOverrideWinsOverTheEnvironment() {
        let root = URL(fileURLWithPath: "/tmp/fixture-config")
        let env = ["NATIVE_AGENT_CLAUDE_BRIDGE_DIR": "/tmp/env-claude"]
        let dir = WakeupReplayGuard.jobsDirectory(for: .claude, configRoot: root, environment: env)
        #expect(dir.path == "/tmp/fixture-config/claude-bridge/wake-jobs")
    }

    @Test func environmentOverrideMatchesTheJSWriters() {
        let env = [
            "NATIVE_AGENT_CLAUDE_BRIDGE_DIR": "/tmp/env-claude",
            "NATIVE_AGENT_OMP_BRIDGE_DIR": "/tmp/env-omp",
            "NATIVE_AGENT_CODEX_REPLY_JOBS_DIR": "/tmp/env-codex-jobs",
        ]
        #expect(WakeupReplayGuard.jobsDirectory(for: .claude, configRoot: nil, environment: env).path
            == "/tmp/env-claude/wake-jobs")
        #expect(WakeupReplayGuard.jobsDirectory(for: .omp, configRoot: nil, environment: env).path
            == "/tmp/env-omp/wake-jobs")
        // Codex's env var names the JOBS directory itself, not the bridge root.
        #expect(WakeupReplayGuard.jobsDirectory(for: .codex, configRoot: nil, environment: env).path
            == "/tmp/env-codex-jobs")
    }

    @Test func defaultsLandUnderDotConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(WakeupReplayGuard.jobsDirectory(for: .claude, configRoot: nil, environment: [:]).path
            == home + "/.config/claude-bridge/wake-jobs")
        #expect(WakeupReplayGuard.jobsDirectory(for: .codex, configRoot: nil, environment: [:]).path
            == home + "/.config/codex-nativeagent-bridge/reply-jobs")
    }

    @Test func escapeHatchIsReadFromTheEnvironment() {
        #expect(WakeupReplayGuard.isDisabled(environment: [:]) == false)
        #expect(WakeupReplayGuard.isDisabled(
            environment: [WakeupReplayGuard.disableEnvironmentKey: "1"]))
        #expect(WakeupReplayGuard.isDisabled(
            environment: [WakeupReplayGuard.disableEnvironmentKey: "TRUE"]))
        #expect(WakeupReplayGuard.isDisabled(
            environment: [WakeupReplayGuard.disableEnvironmentKey: "0"]) == false)
    }
}
