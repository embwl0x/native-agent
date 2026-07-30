import Testing
import Foundation
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MissionCheckpointTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeCheckpoint(
    id: String = UUID().uuidString.lowercased(),
    executionId: String,
    phase: String = "investigating",
    progress: Double? = nil,
    summary: String = "step done",
    detail: String? = nil,
    nextStep: String? = nil,
    blockingQuestion: String? = nil,
    ts: String = "2026-06-06T12:00:00.000Z"
) -> WorkshopCheckpoint {
    WorkshopCheckpoint(
        id: id,
        executionId: executionId,
        ts: ts,
        phase: phase,
        progress: progress,
        summary: summary,
        detail: detail,
        nextStep: nextStep,
        blockingQuestion: blockingQuestion
    )
}

// MARK: - Checkpoint store tests

@Suite("SwiftNativeWorkshopCheckpointStore")
struct CheckpointStoreSuite {

    @Test func appendThenReadRoundTrip() async throws {
        let root = try makeTempRoot()
        let store = SwiftNativeWorkshopCheckpointStore(dataRoot: root)
        let execution = "m-roundtrip"

        let c1 = makeCheckpoint(
            id: "c1",
            executionId: execution,
            phase: "investigating",
            progress: 0.1,
            summary: "started",
            detail: "first context",
            nextStep: "run more",
            blockingQuestion: nil
        )
        let c2 = makeCheckpoint(
            id: "c2",
            executionId: execution,
            phase: "blocked",
            progress: 0.45,
            summary: "hit a wall",
            detail: "stack trace etc",
            nextStep: nil,
            blockingQuestion: "what should I do about the deploy"
        )
        try await store.appendCheckpoint(c1)
        try await store.appendCheckpoint(c2)

        let read = try await store.readCheckpoints(executionId: execution)
        #expect(read.count == 2)
        #expect(read[0] == c1)
        #expect(read[1] == c2)
        // All optional fields preserved.
        #expect(read[0].progress == 0.1)
        #expect(read[0].detail == "first context")
        #expect(read[0].nextStep == "run more")
        #expect(read[0].blockingQuestion == nil)
        #expect(read[1].blockingQuestion == "what should I do about the deploy")
        #expect(read[1].nextStep == nil)
    }

    @Test func latestCheckpointReturnsLastAppended() async throws {
        let root = try makeTempRoot()
        let store = SwiftNativeWorkshopCheckpointStore(dataRoot: root)
        let execution = "m-latest"

        let c1 = makeCheckpoint(id: "c1", executionId: execution, summary: "one")
        let c2 = makeCheckpoint(id: "c2", executionId: execution, summary: "two")
        let c3 = makeCheckpoint(id: "c3", executionId: execution, summary: "three")
        try await store.appendCheckpoint(c1)
        try await store.appendCheckpoint(c2)
        try await store.appendCheckpoint(c3)

        let latest = try await store.latestCheckpoint(executionId: execution)
        #expect(latest == c3)
    }

    @Test func readCheckpointsOnMissingFileReturnsEmpty() async throws {
        let root = try makeTempRoot()
        let store = SwiftNativeWorkshopCheckpointStore(dataRoot: root)
        let read = try await store.readCheckpoints(executionId: "never-written")
        #expect(read.isEmpty)
        let latest = try await store.latestCheckpoint(executionId: "never-written")
        #expect(latest == nil)
    }

    @Test func concurrentAppendsPreserveAllRecords() async throws {
        // gpt-5.5 review NIT 1: a single actor instance serializes calls at
        // the actor boundary, which never exercises the cross-process flock
        // the impl uses. Use N DISTINCT actor instances (each is its own
        // isolated boundary) pointing at the SAME dataRoot — this approximates
        // the real cross-process scenario the flock guards: two app/runtime
        // writers racing to append to the same checkpoints.jsonl. flock(2)
        // serializes them; without it
        // a single logical JSONL row could tear across the appendBytes
        // short-write loop.
        let root = try makeTempRoot()
        let execution = "m-concurrent"
        let count = 20

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                let cp = makeCheckpoint(
                    id: "c\(i)",
                    executionId: execution,
                    phase: "p\(i)",
                    progress: Double(i) / Double(count),
                    summary: "summary \(i)",
                    // Make each line >100 bytes so a torn write is detectable
                    // as a malformed JSONL line.
                    detail: String(repeating: "x", count: 256) + " \(i)"
                )
                group.addTask {
                    // Each task gets its OWN store instance over the SAME
                    // root — different actor isolation domains, same on-disk
                    // file. This is the path the flock actually defends.
                    let store = SwiftNativeWorkshopCheckpointStore(dataRoot: root)
                    do { try await store.appendCheckpoint(cp) }
                    catch { fatalError("append failed: \(error)") }
                }
            }
        }

        let reader = SwiftNativeWorkshopCheckpointStore(dataRoot: root)
        let read = try await reader.readCheckpoints(executionId: execution)
        #expect(read.count == count)
        let ids = Set(read.map(\.id))
        for i in 0..<count {
            #expect(ids.contains("c\(i)"), "missing checkpoint c\(i)")
        }
        // Bonus: each detail prefix preserved (proves no torn line).
        for cp in read {
            #expect(cp.detail?.hasPrefix(String(repeating: "x", count: 256)) == true,
                    "torn detail field for \(cp.id)")
        }
    }

    @Test func appendCheckpointFailsClosedOnInvalidWorkshopExecutionId() async throws {
        let root = try makeTempRoot()
        let store = SwiftNativeWorkshopCheckpointStore(dataRoot: root)
        let cp = makeCheckpoint(id: "c1", executionId: "   ")  // whitespace-only
        do {
            try await store.appendCheckpoint(cp)
            Issue.record("expected appendCheckpoint to throw on empty missionId")
        } catch let e as WorkshopCheckpointError {
            if case .invalidWorkshopExecutionId = e { /* ok */ }
            else { Issue.record("wrong error: \(e)") }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func readCheckpointsFailsClosedOnInvalidWorkshopExecutionId() async throws {
        let root = try makeTempRoot()
        let store = SwiftNativeWorkshopCheckpointStore(dataRoot: root)
        do {
            _ = try await store.readCheckpoints(executionId: "")
            Issue.record("expected readCheckpoints to throw on empty missionId")
        } catch let e as WorkshopCheckpointError {
            if case .invalidWorkshopExecutionId = e { /* ok */ }
            else { Issue.record("wrong error: \(e)") }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    /// gpt-5.5 follow-up BLOCKING regression test.
    /// PersistenceCore.readJSONL silent-drops syntactically malformed lines
    /// via `compactMap { try? parse }`. The implementation now bypasses that
    /// helper and throws on parse failure. Inject a torn line directly on
    /// disk and confirm read throws — proves the upper-layer schema-decode
    /// throw is reachable for syntactically malformed bytes too.
    @Test func readCheckpointsFailsClosedOnMalformedLine() async throws {
        let root = try makeTempRoot()
        let store = SwiftNativeWorkshopCheckpointStore(dataRoot: root)
        let execution = "m-malformed"
        // Write one good line then one malformed line.
        let good = makeCheckpoint(id: "g1", executionId: execution, summary: "ok")
        try await store.appendCheckpoint(good)
        let path = store.checkpointsPath(executionId: execution)
        // Append a torn JSONL line that won't parse.
        let torn = "{\"id\":\"bad\",\"missionId\":\"m-malformed\",\"ts\":\"x\",\"phase\":\"y\",\"summary\":\n"
        let fh = try FileHandle(forWritingTo: path)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(torn.utf8))
        try fh.close()
        do {
            _ = try await store.readCheckpoints(executionId: execution)
            Issue.record("expected readCheckpoints to throw on malformed line")
        } catch let e as WorkshopCheckpointError {
            if case .persistenceFailure(let msg) = e {
                #expect(msg.contains("parse") || msg.contains("decode"),
                        "unexpected persistenceFailure msg: \(msg)")
            } else {
                Issue.record("wrong WorkshopCheckpointError variant: \(e)")
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

// MARK: - Escalator tests

@Suite("SwiftNativeWorkshopEscalator")
struct EscalatorSuite {

    @Test func escalatorWritesEscalationFileAndInboxCard() async throws {
        let root = try makeTempRoot()
        // Deterministic uuid via a lock-backed counter so we can assert on the
        // exact card id in the index overlay. (Strict-concurrency-safe.)
        let uuidProvider = DeterministicUUIDs(["esc-1", "card-1"])
        let escalator = SwiftNativeWorkshopEscalator(
            dataRoot: root,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            uuid: { uuidProvider.next() }
        )

        let execution = "m-escalate"
        let cp = makeCheckpoint(
            id: "cp-1",
            executionId: execution,
            phase: "blocked",
            summary: "the deploy needs your approval",
            blockingQuestion: "ok to ship?"
        )
        let escId = try await escalator.escalate(
            executionId: execution,
            reason: .userInputRequired,
            question: "ok to ship?",
            checkpoint: cp
        )
        #expect(escId == "esc-1")

        // escalations.jsonl present + has one record matching shape.
        let escs = try await escalator.readEscalations(executionId: execution)
        #expect(escs.count == 1)
        #expect(escs[0].id == "esc-1")
        #expect(escs[0].executionId == execution)
        #expect(escs[0].reason == .userInputRequired)
        #expect(escs[0].question == "ok to ship?")
        #expect(escs[0].checkpoint == cp)

        // A5.2 (2026-07-23): card lands in the LIVE inbox
        // (notifications/inbox.jsonl), NOT the retired inbox/ silo. Status lives
        // per-line — no separate index.json overlay.
        let itemsURL = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let itemsText = try String(contentsOf: itemsURL, encoding: .utf8)
        let lines = itemsText.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)
        let parsed = try JSONValue.parse(Data(lines[0].utf8))
        guard case .object(let card) = parsed else {
            Issue.record("inbox card line is not a JSON object")
            return
        }
        if case .string(let r) = card["related_mission_id"] ?? .null {
            #expect(r == execution)
        } else {
            Issue.record("related_mission_id missing or wrong type")
        }
        if case .string(let s) = card["summary"] ?? .null {
            #expect(s == "ok to ship?")
        } else {
            Issue.record("summary missing or wrong type")
        }
        if case .string(let cid) = card["id"] ?? .null {
            #expect(cid == "card-1")
        } else {
            Issue.record("card id missing or wrong type")
        }

        // Status/read_at now live PER-LINE on the card (the daemon-era index.json
        // overlay is retired). First write must be unread + null read_at.
        if case .string(let st) = card["status"] ?? .null {
            #expect(st == "unread")
        } else {
            Issue.record("card.status missing or wrong type")
        }
        if case .null = card["read_at"] ?? .string("MISSING") {
            // ok
        } else {
            Issue.record("card.read_at should be JSON null at first write")
        }
        // The retired silo must NOT be written.
        let deadSilo = root.appendingPathComponent("inbox").appendingPathComponent("items.jsonl")
        #expect(!FileManager.default.fileExists(atPath: deadSilo.path),
                "A5.2: the dead inbox/ silo must no longer be written")
    }

    @Test func escalatorAppendsCardWithCorrectShape() async throws {
        let root = try makeTempRoot()
        let uuidProvider = DeterministicUUIDs(["esc-x", "card-x"])
        let escalator = SwiftNativeWorkshopEscalator(
            dataRoot: root,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            uuid: { uuidProvider.next() }
        )
        let execution = "shape-mission"
        let cp = makeCheckpoint(
            id: "cp-x", executionId: execution, summary: "summary line"
        )
        _ = try await escalator.escalate(
            executionId: execution,
            reason: .budgetExceeded,
            question: "ran out of budget — extend?",
            checkpoint: cp
        )
        let itemsURL = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let itemsText = try String(contentsOf: itemsURL, encoding: .utf8)
        let line = itemsText.split(separator: "\n").first.map(String.init) ?? ""
        let parsed = try JSONValue.parse(Data(line.utf8))
        guard case .object(let card) = parsed else {
            Issue.record("card not an object")
            return
        }

        // EXACT key set — gpt-5.5 NIT 3. The Mac/iOS decoders bind these
        // keys positionally; an extra key would be ignored but a missing one
        // would surface as a decode failure on the consumer.
        let expectedKeys: Set<String> = [
            "id", "created_at", "source", "severity", "title", "summary",
            "detail", "related_mission_id", "related_approval_id",
            "related_paths", "related_groups", "actions", "status", "read_at",
        ]
        #expect(Set(card.keys) == expectedKeys,
                "card keys mismatch: \(Set(card.keys).symmetricDifference(expectedKeys))")
        // Null-typed fields must be JSON null (not missing, not empty string).
        for nullKey in ["related_approval_id", "related_paths", "related_groups", "read_at"] {
            if case .null = card[nullKey] ?? .string("MISSING") {
                // ok
            } else {
                Issue.record("card.\(nullKey) should be JSON null, got \(String(describing: card[nullKey]))")
            }
        }
        // Specific values.
        if case .string(let s) = card["source"] ?? .null {
            #expect(s == "workshop")
        } else { Issue.record("source missing or wrong type") }
        if case .string(let s) = card["severity"] ?? .null {
            // Brief said "warning"; we map to actionable (existing vocab).
            #expect(s == "actionable")
        } else { Issue.record("severity missing or wrong type") }
        if case .string(let s) = card["title"] ?? .null {
            #expect(s.contains(execution))
        } else { Issue.record("title missing or wrong type") }
        if case .string(let s) = card["summary"] ?? .null {
            #expect(s == "ran out of budget — extend?")
        } else { Issue.record("summary missing or wrong type") }
        if case .array(let acts) = card["actions"] ?? .null {
            #expect(acts.count == 4)
            // Each action is an {id, label} object with the four expected ids.
            let actionIds: [String] = acts.compactMap {
                if case .object(let o) = $0, case .string(let i) = o["id"] ?? .null {
                    return i
                }
                return nil
            }
            #expect(Set(actionIds) == Set(["view", "approve", "reject", "dismiss"]))
        } else { Issue.record("actions missing or wrong type") }
        if case .string(let s) = card["status"] ?? .null {
            #expect(s == "unread")
        } else { Issue.record("status missing or wrong type") }
    }

    @Test func escalateFailsClosedOnEmptyQuestion() async throws {
        let root = try makeTempRoot()
        let escalator = SwiftNativeWorkshopEscalator(dataRoot: root)
        let cp = makeCheckpoint(id: "cp", executionId: "m", summary: "x")
        do {
            _ = try await escalator.escalate(
                executionId: "m",
                reason: .repeatedFailure,
                question: "   ",  // whitespace-only
                checkpoint: cp
            )
            Issue.record("expected escalate to throw on empty question")
        } catch let e as WorkshopCheckpointError {
            if case .invalidEscalation = e { /* ok */ }
            else { Issue.record("wrong error: \(e)") }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func escalateFailsClosedOnEmptyWorkshopExecutionId() async throws {
        let root = try makeTempRoot()
        let escalator = SwiftNativeWorkshopEscalator(dataRoot: root)
        let cp = makeCheckpoint(id: "cp", executionId: "m", summary: "x")
        do {
            _ = try await escalator.escalate(
                executionId: "",
                reason: .toolUnavailable,
                question: "what?",
                checkpoint: cp
            )
            Issue.record("expected escalate to throw on empty missionId")
        } catch let e as WorkshopCheckpointError {
            if case .invalidWorkshopExecutionId = e { /* ok */ }
            else { Issue.record("wrong error: \(e)") }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

// MARK: - Deterministic uuid sequence for escalator tests.
//
// Lock-backed (NSLock) so the @Sendable uuid closure can call it synchronously
// under Swift 6 strict concurrency. The escalator currently calls uuid() twice
// per escalate() (one for the escalation id, one for the inbox card id); the
// constructor takes those two seed values in order. Falls back to a
// "fallback-N" string if drained, so the tests fail loudly rather than reuse a
// repeated id.
final class DeterministicUUIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]
    private var fallback = 0
    init(_ values: [String]) { self.values = values }
    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        if values.isEmpty {
            fallback += 1
            return "fallback-\(fallback)"
        }
        return values.removeFirst()
    }
}
