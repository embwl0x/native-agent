import Testing
import Foundation
import NativeAgentCore
import PersistenceCore
@testable import DoctorChecks

// MARK: - PromptPrefixHealthCheck fixtures
//
// The honesty rules under test, one @Test each:
//   * a healthy trace reads ok and NAMES what it measured,
//   * a prefix break FAILS and names the offending turns,
//   * an empty feed reads UNMEASURED and never "0 problems",
//   * a day file that exists and will not read FAILS,
//   * a kill-switch rollback to v1Legacy is VISIBLE in the row.

@Suite("PromptPrefixHealthCheck")
struct PromptPrefixHealthCheckTests {

    // MARK: - Fixture builders

    private func tmpRoot(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefix-check-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let anchor = Date(timeIntervalSince1970: 1_788_000_000)  // fixed, no clock drift

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func dayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// One llm.call row in the shape the feed actually writes.
    private func llmCall(
        turnId: String,
        sessionId: String,
        at: Date,
        shape: String? = "v2Prefix",
        provider: String = "anthropic_oauth_direct",
        cacheRead: Int,
        cacheCreation: Int,
        inputTokens: Int = 400,
        windowSlid: Bool = false,
        fingerprint: String,
        volatileChars: Int = 9_000
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "provider": .string(provider),
            "model": .string("claude-fable-5-1"),
            "turnId": .string(turnId),
            "cacheReadInputTokens": .int(Int64(cacheRead)),
            "cacheCreationInputTokens": .int(Int64(cacheCreation)),
            "inputTokens": .int(Int64(inputTokens)),
            "outputTokens": .int(120),
            "windowSlid": .bool(windowSlid),
            "prefixFingerprintSHA256": .string(fingerprint),
            "volatileBlockChars": .int(Int64(volatileChars)),
            "volatileDelivery": .string("systemClearAt"),
        ]
        if let shape { payload["shapeVersion"] = .string(shape) }
        return .object([
            "kind": .string("llm.call"),
            "ts": .string(iso(at)),
            "turnId": .string(turnId),
            "sessionId": .string(sessionId),
            "surface": .string("chat"),
            "payload": .object(payload),
        ])
    }

    private func snapshot(turnId: String, sessionId: String, at: Date, toolSHA: String) -> JSONValue {
        .object([
            "kind": .string("context.snapshot"),
            "ts": .string(iso(at)),
            "turnId": .string(turnId),
            "sessionId": .string(sessionId),
            "surface": .string("chat"),
            "payload": .object([
                "schema": .string("context.snapshot.v1"),
                "toolSchemaFingerprintSHA256": .string(toolSHA),
                "toolSchemaCount": .int(50),
            ]),
        ])
    }

    private func write(_ rows: [JSONValue], day: Date, to root: URL) throws {
        let dir = root.appendingPathComponent("turn_traces", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = try rows.map {
            String(decoding: try $0.serializedData(pretty: false), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(dayName(day)).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// The build the fixtures pretend is running.
    private let identity = NativeAgentBuildIdentity(
        version: "9.9.9-test",
        build: "9.9.9",
        sourceRevision: "abc123",
        sourceDirty: false
    )

    private func check(_ root: URL, killSwitch: String? = nil) -> PromptPrefixHealthCheck {
        let moment = anchor
        return PromptPrefixHealthCheck(
            root: root,
            now: { moment },
            killSwitchRaw: { killSwitch },
            identity: identity,
            cacheTTL: 0
        )
    }

    /// The launch descriptor the app writes on startup, as this build.
    private func writeLaunchStamp(
        _ at: Date,
        to root: URL,
        build: String? = nil,
        version: String? = nil
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload = JSONValue.object([
            "port": .int(8770),
            "bundleId": .string("com.example.nativeagent.mac"),
            "version": .string(version ?? identity.version),
            "build": .string(build ?? identity.build),
            "sourceRevision": .string(identity.sourceRevision ?? ""),
            "sourceDirty": .bool(identity.sourceDirty),
            "writtenAt": .string(formatter.string(from: at)),
        ])
        try payload.serializedData(pretty: false)
            .write(to: root.appendingPathComponent("macctl_bridge.json"))
    }

    // MARK: - Healthy

    @Test("a healthy trace reads ok and names what it measured")
    func healthyTrace() async throws {
        let root = tmpRoot("healthy")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "S-healthy"
        let sha = String(repeating: "a", count: 64)
        let tools = String(repeating: "t", count: 64)
        var rows: [JSONValue] = []
        for index in 0..<6 {
            let at = anchor.addingTimeInterval(-3_600 + Double(index) * 60)
            let turn = "turn-\(index)"
            rows.append(
                llmCall(
                    turnId: turn, sessionId: session, at: at,
                    // Turn 0 has no prefix to reuse; every later turn reads it.
                    cacheRead: index == 0 ? 0 : 19_000,
                    cacheCreation: index == 0 ? 19_142 : 0,
                    fingerprint: sha
                )
            )
            rows.append(snapshot(turnId: turn, sessionId: session, at: at, toolSHA: tools))
        }
        try write(rows, day: anchor, to: root)

        let result = await check(root).run()
        #expect(result.id == "prompt_prefix_health")
        #expect(result.status == "ok")
        #expect(result.detail.contains("6 v2Prefix turn(s)"))
        #expect(result.detail.contains("0 cold non-first turns"))
        #expect(result.detail.contains("prefix fingerprint stable"))
        #expect(result.detail.contains("volatileBlockChars p50=9000"))
        // The uncached per-turn block is named, so the hit rate is not misread.
        #expect(result.detail.contains("uncached BY DESIGN"))
        #expect(result.repair == nil)
    }

    @Test("windowSlid and a tool-array change exempt a cold turn instead of failing it")
    func exemptionsHold() async throws {
        let root = tmpRoot("exempt")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "S-exempt"
        let shaA = String(repeating: "a", count: 64)
        let shaB = String(repeating: "b", count: 64)
        let toolsA = String(repeating: "1", count: 64)
        let toolsB = String(repeating: "2", count: 64)
        var rows: [JSONValue] = []
        // t0 first turn, t1 window slid, t2 tool array changed. None is a defect.
        rows.append(llmCall(
            turnId: "t0", sessionId: session, at: anchor.addingTimeInterval(-300),
            cacheRead: 0, cacheCreation: 12_000, fingerprint: shaA
        ))
        rows.append(snapshot(
            turnId: "t0", sessionId: session, at: anchor.addingTimeInterval(-300), toolSHA: toolsA
        ))
        rows.append(llmCall(
            turnId: "t1", sessionId: session, at: anchor.addingTimeInterval(-200),
            cacheRead: 0, cacheCreation: 0, windowSlid: true, fingerprint: shaB
        ))
        rows.append(snapshot(
            turnId: "t1", sessionId: session, at: anchor.addingTimeInterval(-200), toolSHA: toolsA
        ))
        rows.append(llmCall(
            turnId: "t2", sessionId: session, at: anchor.addingTimeInterval(-100),
            cacheRead: 0, cacheCreation: 0, fingerprint: shaB
        ))
        rows.append(snapshot(
            turnId: "t2", sessionId: session, at: anchor.addingTimeInterval(-100), toolSHA: toolsB
        ))
        try write(rows, day: anchor, to: root)

        let result = await check(root).run()
        #expect(result.status == "ok")
        #expect(result.detail.contains("0 cold non-first turns"))
        #expect(result.detail.contains("1 windowSlid"))
        #expect(result.detail.contains("1 tool-array change"))
    }

    // MARK: - Broken

    @Test("a prefix break fails and names the offending turns")
    func prefixBreakFails() async throws {
        let root = tmpRoot("break")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "S-break"
        let tools = String(repeating: "t", count: 64)
        var rows: [JSONValue] = []
        for index in 0..<5 {
            let at = anchor.addingTimeInterval(-3_600 + Double(index) * 60)
            let turn = "broken-\(index)"
            rows.append(
                llmCall(
                    turnId: turn, sessionId: session, at: at,
                    // Every turn rebuilds: 0 read, a fresh fingerprint, and a
                    // big creation on a non-first turn.
                    cacheRead: 0,
                    cacheCreation: 19_000,
                    fingerprint: String(repeating: "\(index)", count: 64)
                )
            )
            rows.append(snapshot(turnId: turn, sessionId: session, at: at, toolSHA: tools))
        }
        try write(rows, day: anchor, to: root)

        let result = await check(root).run()
        #expect(result.status == "fail")
        #expect(result.detail.contains("non-first turn(s) read 0 cache tokens"))
        #expect(result.detail.contains("broken-1"))
        #expect(result.detail.contains("unexplained prefix fingerprint change"))
        #expect(result.detail.contains("created >3000"))
        #expect(result.detail.contains("above the tolerance"))
        #expect(result.repair != nil)
    }

    @Test("a single violation in a session-day stays inside the tolerance")
    func toleranceAbsorbsOneViolation() async throws {
        let root = tmpRoot("tolerance")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "S-tol"
        let sha = String(repeating: "a", count: 64)
        let tools = String(repeating: "t", count: 64)
        var rows: [JSONValue] = []
        for index in 0..<5 {
            let at = anchor.addingTimeInterval(-3_600 + Double(index) * 60)
            let turn = "tol-\(index)"
            rows.append(
                llmCall(
                    turnId: turn, sessionId: session, at: at,
                    cacheRead: index == 2 ? 0 : (index == 0 ? 0 : 19_000),
                    cacheCreation: index == 0 ? 19_142 : 0,
                    fingerprint: sha
                )
            )
            rows.append(snapshot(turnId: turn, sessionId: session, at: at, toolSHA: tools))
        }
        try write(rows, day: anchor, to: root)

        let result = await check(root).run()
        // One cold turn is named, but it does not tip the row into failure.
        #expect(result.detail.contains("tol-2"))
        #expect(result.status != "fail")
    }

    // MARK: - Honesty

    @Test("an empty feed reads UNMEASURED, never zero problems")
    func emptyFeedIsUnmeasured() async throws {
        let root = tmpRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await check(root).run()
        #expect(result.status == "warn")
        #expect(result.detail.contains("UNMEASURED"))
        #expect(!result.detail.contains("0 cold non-first turns"))
    }

    @Test("a day file that exists but will not read FAILS")
    func unreadableDayFails() async throws {
        let root = tmpRoot("unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("turn_traces", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(dayName(anchor)).jsonl")
        // Invalid UTF-8: the file is THERE and cannot be decoded.
        try Data([0xFF, 0xFE, 0xFF, 0xFE]).write(to: path)

        let result = await check(root).run()
        #expect(result.status == "fail")
        #expect(result.detail.contains("could not be read"))
        #expect(result.detail.contains("UNMEASURED"))
    }

    @Test("a feed with only v1Legacy rows reads UNMEASURED and shows the rollback")
    func rollbackIsVisible() async throws {
        let root = tmpRoot("rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = (0..<3).map { index in
            llmCall(
                turnId: "legacy-\(index)", sessionId: "S-legacy",
                at: anchor.addingTimeInterval(-600 + Double(index) * 60),
                shape: "v1Legacy", cacheRead: 0, cacheCreation: 0,
                fingerprint: String(repeating: "c", count: 64)
            )
        }
        try write(rows, day: anchor, to: root)

        let result = await check(root, killSwitch: "v1").run()
        #expect(result.status == "warn")
        #expect(result.detail.contains("UNMEASURED"))
        #expect(result.detail.contains("v1Legacy=3"))
        #expect(result.detail.contains("chatConversationPrefixShape=v1Legacy"))
        #expect(result.repair != nil)
    }

    @Test("an unparseable kill-switch value is named rather than silently ignored")
    func unparseableKillSwitchIsNamed() async throws {
        let root = tmpRoot("badswitch")
        defer { try? FileManager.default.removeItem(at: root) }
        try write([], day: anchor, to: root)
        let result = await check(root, killSwitch: "v9-nonsense").run()
        #expect(result.detail.contains("UNPARSEABLE"))
    }
}

// MARK: - Measurement window (2026-09-02 incident)

extension PromptPrefixHealthCheckTests {

    @Test("with no launch stamp the window falls back to 24h and says so")
    func fallbackWindowIsNamed() async throws {
        let root = tmpRoot("fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(try oneHealthySession(), day: anchor, to: root)

        let result = await check(root).run()
        #expect(result.detail.contains("falls back to the last 24h"))
        #expect(result.detail.contains("v2Prefix turn(s)"))
    }

    @Test("a matching launch stamp becomes the window floor and is named")
    func launchStampBecomesFloor() async throws {
        let root = tmpRoot("stamp")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(try oneHealthySession(), day: anchor, to: root)
        try writeLaunchStamp(anchor.addingTimeInterval(-4_000), to: root)

        let result = await check(root).run()
        #expect(result.detail.contains("since this build launched at"))
        #expect(!result.detail.contains("falls back to the last 24h"))
    }

    @Test("pre-build history is EXCLUDED, so an all-old feed reads UNMEASURED")
    func preBuildHistoryIsExcluded() async throws {
        let root = tmpRoot("prebuild")
        defer { try? FileManager.default.removeItem(at: root) }
        // A broken session that would FAIL loudly if it were still graded...
        let session = "S-old"
        let tools = String(repeating: "t", count: 64)
        var rows: [JSONValue] = []
        for index in 0..<5 {
            let at = anchor.addingTimeInterval(-5_400 + Double(index) * 60)
            let turn = "old-\(index)"
            rows.append(
                llmCall(
                    turnId: turn, sessionId: session, at: at,
                    cacheRead: 0, cacheCreation: 19_000,
                    fingerprint: String(repeating: "\(index)", count: 64)
                )
            )
            rows.append(snapshot(turnId: turn, sessionId: session, at: at, toolSHA: tools))
        }
        try write(rows, day: anchor, to: root)
        // ...but this build launched AFTER all of it.
        try writeLaunchStamp(anchor.addingTimeInterval(-600), to: root)

        let result = await check(root).run()
        #expect(result.status == "warn")
        #expect(result.detail.contains("UNMEASURED"))
        #expect(result.detail.contains("since this build launched at"))
        #expect(!result.detail.contains("old-1"))
    }

    @Test("a stamp from a DIFFERENT build is refused, not trusted")
    func foreignLaunchStampIsRefused() async throws {
        let root = tmpRoot("foreign")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(try oneHealthySession(), day: anchor, to: root)
        // Same file, previous build's numbers: it says nothing about this one.
        try writeLaunchStamp(anchor.addingTimeInterval(-600), to: root, build: "0.0.1")

        let result = await check(root).run()
        #expect(result.detail.contains("falls back to the last 24h"))
    }

    @Test("this row is never judged by an unattended sweep")
    func rowIsDoctorEyesOnly() {
        #expect(PromptPrefixHealthCheck().heartbeatEligible == false)
        #expect(DoctorHeartbeatPolicy.isEligible("prompt_prefix_health") == false)
    }

    /// Six clean turns in one session, inside the fallback window.
    private func oneHealthySession() throws -> [JSONValue] {
        let session = "S-window"
        let sha = String(repeating: "a", count: 64)
        let tools = String(repeating: "t", count: 64)
        var rows: [JSONValue] = []
        for index in 0..<6 {
            let at = anchor.addingTimeInterval(-3_600 + Double(index) * 60)
            let turn = "w-\(index)"
            rows.append(
                llmCall(
                    turnId: turn, sessionId: session, at: at,
                    cacheRead: index == 0 ? 0 : 19_000,
                    cacheCreation: index == 0 ? 19_142 : 0,
                    fingerprint: sha
                )
            )
            rows.append(snapshot(turnId: turn, sessionId: session, at: at, toolSHA: tools))
        }
        return rows
    }
}
