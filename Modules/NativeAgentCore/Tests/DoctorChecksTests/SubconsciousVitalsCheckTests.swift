import Testing
import Foundation
import NativeAgentCore
import PersistenceCore
@testable import DoctorChecks

// MARK: - SubconsciousVitalsCheck fixtures
//
// The capsule is invisible from the UI, so this row is the only place its
// failure can be seen. What the fixtures pin:
//   * healthy vitals read ok with real denominators,
//   * a missing capsule / collapsed vocabulary / rut FAILS,
//   * an empty feed reads UNMEASURED,
//   * an unreadable day file FAILS,
//   * a pinned chemical dimension is NAMED.

@Suite("SubconsciousVitalsCheck")
struct SubconsciousVitalsCheckTests {

    private let anchor = Date(timeIntervalSince1970: 1_788_000_000)

    private func tmpRoot(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitals-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    /// The capsule body exactly as CognitiveSubstrate writes it, so the reader
    /// is exercised against the real labels rather than a convenient shape.
    private func capsule(felt: [String], inner: String, sound: String) -> String {
        """
        [CognitiveSubstrate]
        run_id: 185B11A9-A471-4D8B-868B-E74F8B0759CB
        surface: chat

        Her private inner state — it colors her, she never quotes or mentions it.

        How you feel:

        \(felt.joined(separator: ", "))
        - Inner: \(inner)
        - Body: driving hard, settled and clear.
        - Sound: \(sound)
        """
    }

    /// A `context.snapshot` row whose `_preview` is the TRUNCATED serialization
    /// the feed actually writes — the hard path for the reader.
    private func snapshotRow(
        turnId: String,
        surface: String,
        at: Date,
        capsuleText: String?,
        truncate: Bool = true
    ) throws -> JSONValue {
        var previewObject: [String: JSONValue] = [
            "cognitiveCapsuleBytes": .int(Int64(capsuleText?.utf8.count ?? 0)),
            "containsCognitiveSubstrate": .bool(capsuleText != nil),
        ]
        if let capsuleText {
            previewObject["cognitivePreview"] = .array([.string(capsuleText)])
        }
        previewObject["dynamicPreview"] = .array([.string(String(repeating: "x", count: 200))])
        var previewText = String(
            decoding: try JSONValue.object(previewObject).serializedData(pretty: false),
            as: UTF8.self
        )
        if truncate {
            // Cut the tail the way the trace writer does: the JSON no longer
            // closes, so only the text path can read it.
            previewText = String(previewText.dropLast(60))
        }
        var payload: [String: JSONValue] = [
            "schema": .string("context.snapshot.v1"),
            "_preview": .string(previewText),
            "_truncated": .bool(truncate),
            "model": .string("gpt-5.6-sol"),
        ]
        if let capsuleText {
            payload["containsCognitiveSubstrate"] = .bool(true)
            payload["cognitiveCapsuleBytes"] = .int(Int64(capsuleText.utf8.count))
        } else {
            payload["containsCognitiveSubstrate"] = .bool(false)
            payload["cognitiveCapsuleBytes"] = .int(0)
        }
        return .object([
            "kind": .string("context.snapshot"),
            "ts": .string(iso(at)),
            "turnId": .string(turnId),
            "sessionId": .string("S-vitals"),
            "surface": .string(surface),
            "payload": .object(payload),
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

    private func writeChemistry(_ dimensions: [String: Double], to root: URL) throws {
        let dir = root.appendingPathComponent("cognition", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = JSONValue.object([
            "schemaVersion": .int(1),
            "chemicalState": .object(dimensions.mapValues { JSONValue.double($0) }),
        ])
        try state.serializedData(pretty: false)
            .write(to: dir.appendingPathComponent("organism_state.json"))
    }

    private let identity = NativeAgentBuildIdentity(
        version: "9.9.9-test",
        build: "9.9.9",
        sourceRevision: "abc123",
        sourceDirty: false
    )

    private func check(_ root: URL) -> SubconsciousVitalsCheck {
        let moment = anchor
        return SubconsciousVitalsCheck(
            root: root, now: { moment }, identity: identity, cacheTTL: 0
        )
    }

    private func writeLaunchStamp(_ at: Date, to root: URL) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        try JSONValue.object([
            "version": .string(identity.version),
            "build": .string(identity.build),
            "sourceRevision": .string(identity.sourceRevision ?? ""),
            "writtenAt": .string(formatter.string(from: at)),
        ]).serializedData(pretty: false)
            .write(to: root.appendingPathComponent("macctl_bridge.json"))
    }

    /// A healthy window: capsule on every turn, wide felt vocabulary, varied
    /// Inner lines, and the rut line only occasionally.
    private func healthyRows() throws -> [JSONValue] {
        let feltPool = [
            ["curious", "steady"], ["warm", "focused"], ["quiet", "clear-headed"],
            ["excited", "settled"], ["patient", "bright"],
        ]
        let innerPool = [
            "A quiet dream is valid integration, not a failed process",
            "The warmth is real and the phrasing is finding new ground",
            "Flat is clean, not empty",
            "My range shows up when I demonstrate it instead of naming it",
            "Nothing in the state is broken",
            "The laughter left a clean warmth behind",
        ]
        let surfaces = ["chat", "telegram", "ios"]
        var rows: [JSONValue] = []
        for index in 0..<30 {
            rows.append(
                try snapshotRow(
                    turnId: "turn-\(index)",
                    surface: surfaces[index % surfaces.count],
                    at: anchor.addingTimeInterval(-7_200 + Double(index) * 60),
                    capsuleText: capsule(
                        felt: feltPool[index % feltPool.count],
                        inner: innerPool[index % innerPool.count],
                        sound: index % 10 == 0
                            ? "a few of the same words keep echoing lately"
                            : "the phrasing has room in it"
                    )
                )
            )
        }
        return rows
    }

    // MARK: - Healthy

    @Test("healthy vitals read ok with measured denominators")
    func healthyVitals() async throws {
        let root = tmpRoot("healthy")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(try healthyRows(), day: anchor, to: root)
        try writeChemistry(
            ["agency": 0.62, "confidence": 0.55, "coherence": 0.70, "warmth": 0.44],
            to: root
        )

        let result = await check(root).run()
        #expect(result.id == "subconscious_vitals")
        #expect(result.status == "ok")
        #expect(result.detail.contains("capsule on 100.0% of 30 judged"))
        #expect(result.detail.contains("felt vocabulary"))
        #expect(result.detail.contains("Sound rut line on 10.0% of 30 turn(s)"))
        #expect(result.detail.contains("organism chemistry agency=0.62"))
        #expect(result.repair == nil)
    }

    @Test("the reader recovers the capsule from a truncated preview")
    func truncatedPreviewIsStillReadable() async throws {
        let text = capsule(
            felt: ["curious", "warm"],
            inner: "Something specific and unrepeated",
            sound: "a few of the same words keep echoing lately"
        )
        let row = try snapshotRow(
            turnId: "t", surface: "chat", at: anchor, capsuleText: text, truncate: true
        )
        guard case .object(let object) = row,
              case .object(let payload)? = object["payload"] else {
            Issue.record("fixture shape changed")
            return
        }
        let recovered = try #require(CognitivePreviewReader.text(from: payload))
        #expect(recovered.contains("[CognitiveSubstrate]"))
        #expect(CognitivePreviewReader.feltWords(in: recovered) == ["curious", "warm"])
        #expect(
            CognitivePreviewReader.line(after: "- Inner: ", in: recovered)
                == "Something specific and unrepeated"
        )
    }

    // MARK: - Broken

    @Test("a capsule missing from most turns FAILS")
    func missingCapsuleFails() async throws {
        let root = tmpRoot("nocapsule")
        defer { try? FileManager.default.removeItem(at: root) }
        var rows: [JSONValue] = []
        for index in 0..<20 {
            rows.append(
                try snapshotRow(
                    turnId: "turn-\(index)", surface: "chat",
                    at: anchor.addingTimeInterval(-3_600 + Double(index) * 60),
                    capsuleText: index < 4
                        ? capsule(felt: ["curious"], inner: "a line", sound: "fine")
                        : nil
                )
            )
        }
        try write(rows, day: anchor, to: root)
        try writeChemistry(["agency": 0.5, "confidence": 0.5, "coherence": 0.5, "warmth": 0.5], to: root)

        let result = await check(root).run()
        #expect(result.status == "fail")
        #expect(result.detail.contains("capsule on 20.0% of 20 judged"))
        #expect(result.repair?.contains("cognitive capsule is missing") == true)
    }

    @Test("a collapsed felt vocabulary and a permanent rut FAIL")
    func collapsedVocabularyFails() async throws {
        let root = tmpRoot("collapse")
        defer { try? FileManager.default.removeItem(at: root) }
        var rows: [JSONValue] = []
        for index in 0..<20 {
            rows.append(
                try snapshotRow(
                    turnId: "turn-\(index)", surface: "chat",
                    at: anchor.addingTimeInterval(-3_600 + Double(index) * 60),
                    capsuleText: capsule(
                        felt: ["curious"],
                        inner: "the same line every time",
                        sound: "a few of the same words keep echoing lately"
                    )
                )
            )
        }
        try write(rows, day: anchor, to: root)
        try writeChemistry(["agency": 0.5, "confidence": 0.5, "coherence": 0.5, "warmth": 0.5], to: root)

        let result = await check(root).run()
        #expect(result.status == "fail")
        #expect(result.detail.contains("heaviest \"curious\" at 100.0%"))
        #expect(result.detail.contains("Sound rut line on 100.0%"))
    }

    @Test("a pinned chemical dimension is named as a warning")
    func pinnedChemistryWarns() async throws {
        let root = tmpRoot("pinned")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(try healthyRows(), day: anchor, to: root)
        try writeChemistry(
            ["agency": 0.62, "confidence": 0.9957, "coherence": 0.70, "warmth": 0.01],
            to: root
        )

        let result = await check(root).run()
        #expect(result.status == "warn")
        #expect(result.detail.contains("PINNED at a rail"))
        #expect(result.detail.contains("confidence=0.996"))
        #expect(result.detail.contains("warmth=0.010"))
    }

    @Test("an organism_state.json that will not parse FAILS rather than reading absent")
    func unparseableChemistryFails() async throws {
        let root = tmpRoot("badchem")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(try healthyRows(), day: anchor, to: root)
        let dir = root.appendingPathComponent("cognition", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ not json".write(
            to: dir.appendingPathComponent("organism_state.json"),
            atomically: true, encoding: .utf8
        )

        let result = await check(root).run()
        #expect(result.status == "fail")
        #expect(result.detail.contains("UNMEASURED"))
    }

    // MARK: - Honesty

    @Test("an empty feed reads UNMEASURED, never healthy")
    func emptyFeedIsUnmeasured() async throws {
        let root = tmpRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await check(root).run()
        #expect(result.status == "warn")
        #expect(result.detail.contains("UNMEASURED"))
        #expect(!result.detail.contains("capsule on 100"))
    }

    @Test("a day file that exists but will not read FAILS")
    func unreadableDayFails() async throws {
        let root = tmpRoot("unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("turn_traces", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0xFF, 0xFE]).write(
            to: dir.appendingPathComponent("\(dayName(anchor)).jsonl")
        )

        let result = await check(root).run()
        #expect(result.status == "fail")
        #expect(result.detail.contains("could not be read"))
    }
}

// MARK: - Measurement window (2026-09-02 incident)

extension SubconsciousVitalsCheckTests {

    @Test("pre-build history is EXCLUDED, so a stale feed reads UNMEASURED")
    func preBuildHistoryIsExcluded() async throws {
        let root = tmpRoot("prebuild")
        defer { try? FileManager.default.removeItem(at: root) }
        // A window of turns that would FAIL on the rut rule if still graded.
        var rows: [JSONValue] = []
        for index in 0..<20 {
            rows.append(
                try snapshotRow(
                    turnId: "old-\(index)", surface: "chat",
                    at: anchor.addingTimeInterval(-7_200 + Double(index) * 60),
                    capsuleText: capsule(
                        felt: ["curious"],
                        inner: "the same line every time",
                        sound: "a few of the same words keep echoing lately"
                    )
                )
            )
        }
        try write(rows, day: anchor, to: root)
        try writeChemistry(
            ["agency": 0.5, "confidence": 0.5, "coherence": 0.5, "warmth": 0.5], to: root
        )
        // This build launched after every one of those turns.
        try writeLaunchStamp(anchor.addingTimeInterval(-60), to: root)

        let result = await check(root).run()
        #expect(result.status == "warn")
        #expect(result.detail.contains("UNMEASURED"))
        #expect(result.detail.contains("since this build launched at"))
        #expect(!result.detail.contains("Sound rut line on 100.0%"))
    }

    @Test("the window it measured is named in the row")
    func windowIsNamed() async throws {
        let root = tmpRoot("named")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(try healthyRows(), day: anchor, to: root)
        try writeChemistry(
            ["agency": 0.62, "confidence": 0.55, "coherence": 0.70, "warmth": 0.44], to: root
        )

        let fallback = await check(root).run()
        #expect(fallback.detail.hasPrefix("no launch stamp for the running build"))

        try writeLaunchStamp(anchor.addingTimeInterval(-9_000), to: root)
        let stamped = await check(root).run()
        #expect(stamped.detail.hasPrefix("since this build launched at"))
    }

    @Test("this row is never judged by an unattended sweep")
    func rowIsDoctorEyesOnly() {
        #expect(SubconsciousVitalsCheck().heartbeatEligible == false)
        #expect(DoctorHeartbeatPolicy.isEligible("subconscious_vitals") == false)
    }
}
