import Testing
import Darwin
import Foundation
@testable import BackgroundLoops
import NativeAgentCore
import PersistenceCore
import DreamREMCycle
import NativeAgentTestSupport

private func mkTmp() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("RemCycleLoopTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func setupPersona(_ dataRoot: URL) throws {
    let persona = dataRoot.appendingPathComponent("persona", isDirectory: true)
    try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
    try "soul body".data(using: .utf8)!.write(to: persona.appendingPathComponent("SOUL.md"))
    try "voice body".data(using: .utf8)!.write(to: persona.appendingPathComponent("VOICE.md"))
    try "growth body".data(using: .utf8)!.write(to: persona.appendingPathComponent("GROWTH.md"))
}

private func setupDiary(_ dataRoot: URL, dates: [String]) throws {
    let dir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for d in dates {
        let url = dir.appendingPathComponent("\(d).md")
        try "dream entry for \(d)".data(using: .utf8)!.write(to: url)
    }
}

private func fixedLoopNow() -> Date {
    ISO8601DateFormatter().date(from: "2026-06-03T12:00:00Z")!
}

private func proposalsJSON(targetDoc: String, evidence: [String], texts: [String]) -> String {
    let datesJSON = "[" + evidence.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    let items = texts.map { t in
        "{\"targetDoc\":\"\(targetDoc)\",\"proposalText\":\"\(t)\",\"evidenceDates\":\(datesJSON),\"confidence\":0.9}"
    }
    return "[" + items.joined(separator: ",") + "]"
}

private func makeLoop(
    dataRoot: URL,
    llm: any LLMClient,
    dryRun: Bool = false,
    clock: @escaping @Sendable () -> Date = { fixedLoopNow() },
    stageApproval: REMApprovalStager? = nil,
    replaySourceCommitted: (@Sendable () async -> Void)? = nil
) -> REMCycleLoop {
    let reader = DreamDiaryReader(dataRoot: dataRoot)
    let consolidator = SwiftNativeREMConsolidator(llm: llm, diary: reader)
    let tombstones = REMTombstoneStore(dataRoot: dataRoot)
    let growth = GrowthDocManager(personaRoot: dataRoot.appendingPathComponent("persona", isDirectory: true))
    return REMCycleLoop(
        consolidator: consolidator,
        tombstones: tombstones,
        growth: growth,
        dataRoot: dataRoot,
        dryRun: dryRun,
        clock: clock,
        stageApproval: stageApproval,
        replaySourceCommitted: replaySourceCommitted
    )
}

private func makeFullPipelineLoop(
    dataRoot: URL,
    llm: any LLMClient,
    gate: DreamREMGatePolicy = DreamREMGatePolicy(remCycleEnabled: true),
    replaySourceCommitted: (@Sendable () async -> Void)? = nil
) -> REMCycleLoop {
    let reader = DreamDiaryReader(dataRoot: dataRoot)
    let legacy = SwiftNativeREMConsolidator(llm: llm, diary: reader)
    let tombstones = REMTombstoneStore(dataRoot: dataRoot)
    let personaRoot = dataRoot.appendingPathComponent("persona", isDirectory: true)
    let growth = GrowthDocManager(personaRoot: personaRoot)
    let full = REMConsolidator(
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        llm: llm,
        gate: gate,
        clock: { fixedLoopNow() }
    )
    return REMCycleLoop(
        consolidator: legacy,
        tombstones: tombstones,
        growth: growth,
        dataRoot: dataRoot,
        personaRoot: personaRoot,
        clock: { fixedLoopNow() },
        fullConsolidator: full,
        replaySourceCommitted: replaySourceCommitted
    )
}

/// Canonical store path — `<dataRoot>/rem_proposals.jsonl` (REM-approval
/// cutover 2026-06-10; the harness/ side-store is import-only).
private func canonicalProposalsURL(_ root: URL) -> URL {
    root.appendingPathComponent("rem_proposals.jsonl")
}

/// Thread-safe recorder used as the injected approval stager.
private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    var ids: [String] {
        lock.lock(); defer { lock.unlock() }
        return _ids
    }
    func record(_ id: String) -> String {
        lock.lock(); defer { lock.unlock() }
        _ids.append(id)
        return "approval-\(id)"
    }
}

private final class ThrowingLLM: LLMClient, @unchecked Sendable {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        throw NSError(domain: "test", code: 1)
    }
}

private actor REMReplayCommitRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

@Suite(.serialized) struct REMCycleLoopTests {
    @Test func default_interval_is_7_days() async throws {
        let root = try mkTmp()
        let loop = makeLoop(dataRoot: root, llm: MockLLMClient())
        #expect(loop.interval == 604_800)
    }

    @Test func loopId_is_rem_cycle() async throws {
        let root = try mkTmp()
        let loop = makeLoop(dataRoot: root, llm: MockLLMClient())
        #expect(loop.loopId == "rem_cycle")
    }

    @Test func tick_with_empty_diary_does_nothing() async throws {
        let root = try mkTmp()
        let recorder = REMReplayCommitRecorder()
        let loop = makeLoop(
            dataRoot: root,
            llm: MockLLMClient(),
            replaySourceCommitted: { await recorder.record() }
        )
        #expect(await loop.tickOutcome() == .skipped(reason: "REM produced no proposals"))
        #expect(await recorder.count == 0)
        let target = canonicalProposalsURL(root)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func tick_writes_surviving_proposals_to_jsonl() async throws {
        let root = try mkTmp()
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-28"])
        let llm = MockLLMClient(scriptedResponses: [
            proposalsJSON(targetDoc: "GROWTH", evidence: ["2026-05-28"], texts: ["growth one"]),
        ])
        let recorder = REMReplayCommitRecorder()
        let loop = makeLoop(
            dataRoot: root,
            llm: llm,
            replaySourceCommitted: { await recorder.record() }
        )
        await loop.tick()
        #expect(await recorder.count == 1)
        let target = canonicalProposalsURL(root)
        #expect(FileManager.default.fileExists(atPath: target.path))
        let text = try String(contentsOf: target, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        #expect(text.contains("growth one"))
        #expect(!text.contains("soul one"))
        #expect(!text.contains("voice one"))
    }

    @Test func tick_filters_out_tombstoned_proposals() async throws {
        let root = try mkTmp()
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-28"])
        let llm = MockLLMClient(scriptedResponses: [
            proposalsJSON(targetDoc: "GROWTH", evidence: ["2026-05-28"], texts: ["growth keep", "growth drop"]),
        ])
        let tombstones = REMTombstoneStore(dataRoot: root)
        let drop = REMProposal(
            id: "x",
            targetDoc: "GROWTH",
            proposalText: "growth drop",
            evidenceDates: ["2026-05-28"],
            confidence: 0.9,
            createdAt: ""
        )
        try await tombstones.record(drop, reason: "test")

        let loop = makeLoop(dataRoot: root, llm: llm)
        await loop.tick()
        let target = canonicalProposalsURL(root)
        let text = try String(contentsOf: target, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        #expect(!text.contains("growth drop"))
        #expect(text.contains("growth keep"))
    }

    @Test func tick_dryRun_does_not_persist() async throws {
        let root = try mkTmp()
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-28"])
        let llm = MockLLMClient(scriptedResponses: [
            proposalsJSON(targetDoc: "GROWTH", evidence: ["2026-05-28"], texts: ["g1"]),
        ])
        let loop = makeLoop(dataRoot: root, llm: llm, dryRun: true)
        await loop.tick()
        let target = canonicalProposalsURL(root)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func tick_growth_near_cap_triggers_eviction_logic() async throws {
        let root = try mkTmp()
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-28"])
        let growthPath = root.appendingPathComponent("persona/GROWTH.md")
        var big = ""
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        fmt.timeZone = TimeZone(identifier: "UTC")
        let base = fmt.date(from: "2024-01-01")!
        for i in 0..<60 {
            let d = base.addingTimeInterval(TimeInterval(i * 86_400))
            big += "\(fmt.string(from: d)) " + String(repeating: "x", count: 1500) + "\n"
        }
        try big.data(using: .utf8)!.write(to: growthPath)
        let sizeBefore = ((try? FileManager.default.attributesOfItem(atPath: growthPath.path)[.size]) as? NSNumber)?.intValue ?? 0
        #expect(sizeBefore > REMCycleLoop.growthEvictThreshold)

        let llm = MockLLMClient(scriptedResponses: [
            proposalsJSON(targetDoc: "GROWTH", evidence: ["2026-05-28"], texts: ["g"]),
        ])
        let loop = makeLoop(dataRoot: root, llm: llm)
        await loop.tick()
        let sizeAfter = ((try? FileManager.default.attributesOfItem(atPath: growthPath.path)[.size]) as? NSNumber)?.intValue ?? 0
        #expect(sizeAfter < sizeBefore)
    }

    @Test func tick_non_throwing_on_consolidator_error() async throws {
        let root = try mkTmp()
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-28"])
        let recorder = REMReplayCommitRecorder()
        let loop = makeLoop(
            dataRoot: root,
            llm: ThrowingLLM(),
            replaySourceCommitted: { await recorder.record() }
        )
        guard case .failed = await loop.tickOutcome() else {
            Issue.record("expected typed REM failure")
            return
        }
        #expect(await recorder.count == 0)
        let target = canonicalProposalsURL(root)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func full_pipeline_emits_replay_commit_only_after_proposal_commit() async throws {
        let root = try mkTmp()
        defer { try? FileManager.default.removeItem(at: root) }
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-29", "2026-05-30"])
        let llm = MockLLMClient(scriptedResponses: [
            proposalsJSON(
                targetDoc: "GROWTH.md",
                evidence: ["2026-05-29", "2026-05-30"],
                texts: ["a pattern grounded across two dream dates"]
            ),
        ])
        let recorder = REMReplayCommitRecorder()
        let loop = makeFullPipelineLoop(
            dataRoot: root,
            llm: llm,
            replaySourceCommitted: { await recorder.record() }
        )

        guard case .completed = await loop.tickOutcome() else {
            Issue.record("expected full REM pipeline completion")
            return
        }
        #expect(await recorder.count == 1)
        #expect(REMProposalStore(dataRoot: root).loadAll().count == 1)

        // Weekly idempotency may still return a successful typed outcome, but
        // without a new canonical row it must not manufacture another wake.
        guard case .completed = await loop.tickOutcome() else {
            Issue.record("expected idempotent full REM rerun to complete")
            return
        }
        #expect(await recorder.count == 1)
        #expect(REMProposalStore(dataRoot: root).loadAll().count == 1)
    }

    @Test func full_pipeline_failure_emits_no_replay_commit() async throws {
        let root = try mkTmp()
        defer { try? FileManager.default.removeItem(at: root) }
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-29", "2026-05-30"])
        let recorder = REMReplayCommitRecorder()
        let loop = makeFullPipelineLoop(
            dataRoot: root,
            llm: MockLLMClient(),
            gate: DreamREMGatePolicy(remCycleEnabled: false),
            replaySourceCommitted: { await recorder.record() }
        )

        guard case .failed = await loop.tickOutcome() else {
            Issue.record("expected disabled full REM pipeline to fail closed")
            return
        }
        #expect(await recorder.count == 0)
    }

    // MARK: - REM-approval cutover regression: canonical path + schema
    //
    // 2026-06-10: the snake_case harness/ side-store is retired. The loop
    // writes camelCase REMProposalRow lines to `<dataRoot>/rem_proposals.jsonl`
    // — the SAME store REMConsolidator appends, the approval-resolve executor
    // flips, and emitREMPinsIndex derives rem_pins.json from. A loop write
    // landing anywhere else (or in snake_case) is invisible to the whole
    // approval pipeline.

    @Test func rem_proposals_written_at_canonical_root_path_not_harness() async throws {
        let root = try mkTmp()
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-28"])
        let llm = MockLLMClient(scriptedResponses: [
            proposalsJSON(targetDoc: "GROWTH", evidence: ["2026-05-28"], texts: ["proposal one"]),
        ])
        let loop = makeLoop(dataRoot: root, llm: llm)
        await loop.tick()
        #expect(FileManager.default.fileExists(atPath: canonicalProposalsURL(root).path),
                "rem_proposals.jsonl not written at the canonical dataRoot path")
        // The retired side-store must NOT reappear.
        let harnessPath = root
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("rem_proposals.jsonl")
        #expect(!FileManager.default.fileExists(atPath: harnessPath.path),
                "rem_proposals.jsonl regressed to the retired harness/ side-store")
    }

    @Test func rem_proposals_schema_is_canonical_camelCase() async throws {
        let root = try mkTmp()
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-28"])
        let llm = MockLLMClient(scriptedResponses: [
            proposalsJSON(targetDoc: "GROWTH", evidence: ["2026-05-28"], texts: ["schema check"]),
        ])
        let loop = makeLoop(dataRoot: root, llm: llm)
        await loop.tick()
        let text = try String(contentsOf: canonicalProposalsURL(root), encoding: .utf8)
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let data = try #require(firstLine.data(using: .utf8))
        let any = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(any as? [String: Any])
        // Canonical camelCase fields (REMProposalRow):
        #expect(dict["targetDoc"] != nil, "missing targetDoc; have \(Array(dict.keys))")
        #expect(dict["proposalText"] != nil, "missing proposalText; have \(Array(dict.keys))")
        #expect(dict["evidenceDates"] != nil, "missing evidenceDates; have \(Array(dict.keys))")
        #expect(dict["status"] as? String == "pending",
                "status must default to 'pending' for the approve/deny flow")
        // targetDoc is normalized to the doc FILENAME (bare "GROWTH" → "GROWTH.md").
        let td = try #require(dict["targetDoc"] as? String)
        #expect(td.hasSuffix(".md"), "targetDoc \(td) missing .md suffix")
        // Snake-case leakage check: the retired wire schema must not return.
        #expect(dict["target_doc"] == nil, "leaked snake_case target_doc into canonical store")
        #expect(dict["proposed_text"] == nil, "leaked snake_case proposed_text into canonical store")
        #expect(dict["evidence_dates"] == nil, "leaked snake_case evidence_dates into canonical store")
    }

    @Test func tick_stages_one_approval_per_proposal_and_rerun_does_not_double_stage() async throws {
        let root = try mkTmp()
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-28"])
        let llm = MockLLMClient(scriptedResponses: [
            proposalsJSON(targetDoc: "GROWTH", evidence: ["2026-05-28"], texts: ["stage growth"]),
        ])
        let recorder = StageRecorder()
        let loop = makeLoop(dataRoot: root, llm: llm, stageApproval: { row in
            recorder.record(row.id)
        })
        await loop.tick()
        #expect(recorder.ids.count == 1, "exactly ONE approval staged per appended proposal")

        // Rows carry the staging stamp.
        let text = try String(contentsOf: canonicalProposalsURL(root), encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        #expect(lines.allSatisfy { $0.contains("\"approvalId\":\"approval-") })

        // Re-running the staging scan must not re-stage stamped ids.
        let store = REMProposalStore(dataRoot: root)
        let restaged = try await store.stagePendingApprovals { row in recorder.record(row.id) }
        #expect(restaged == 0)
        #expect(recorder.ids.count == 1, "re-run double-staged an already-stamped proposal id")
    }

    @Test func tick_imports_legacy_harness_file_into_canonical_store_once() async throws {
        let root = try mkTmp()
        try setupPersona(root)
        // Empty diary: the legacy import must run even when the consolidator
        // produces nothing (it fires at store-open, not append time).
        let harness = root.appendingPathComponent("harness", isDirectory: true)
        try FileManager.default.createDirectory(at: harness, withIntermediateDirectories: true)
        let legacy = harness.appendingPathComponent("rem_proposals.jsonl")
        try Data("""
        {"change_type":"append","createdAt":"2026-05-31T04:30:00Z","evidence_dates":["2026-05-28"],"id":"legacy-loop-1","proposed_text":"legacy loop text","rationale":"","status":"pending","target_doc":"GROWTH.md"}

        """.utf8).write(to: legacy)

        let recorder = StageRecorder()
        let loop = makeLoop(dataRoot: root, llm: MockLLMClient(), stageApproval: { row in
            recorder.record(row.id)
        })
        await loop.tick()

        // Imported as pending camelCase, staged, and the source renamed.
        let text = try String(contentsOf: canonicalProposalsURL(root), encoding: .utf8)
        #expect(text.contains("\"id\":\"legacy-loop-1\""))
        #expect(text.contains("\"proposalText\":\"legacy loop text\""))
        #expect(recorder.ids == ["legacy-loop-1"])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(
            atPath: harness.appendingPathComponent("rem_proposals.jsonl.migrated").path))

        // Second tick: import is a no-op, no re-stage.
        await loop.tick()
        #expect(recorder.ids.count == 1)
    }

    @Test func rem_proposals_appended_concurrent_with_external_writer_under_flock_no_loss() async throws {
        // Simulate another approval writer appending into the same file while Swift's
        // tick() runs. Both go through `<path>.lock` flock. Assert every record
        // is present after both complete (no torn writes, no lost lines).
        let root = try mkTmp()
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-28"])
        // Canonical store target — both writers contend on its sibling .lock.
        let target = canonicalProposalsURL(root)

        let llm = MockLLMClient(scriptedResponses: [
            proposalsJSON(targetDoc: "GROWTH", evidence: ["2026-05-28"], texts: ["swift1", "swift2", "swift3"]),
        ])
        let loop = makeLoop(dataRoot: root, llm: llm)

        // External child grabs the same <path>.lock and appends five records
        // while the Swift tick runs.
        let helperAppender = try NativeAgentFlockChild.remProposalAppender(
            target: target,
            count: 5
        )
        defer { helperAppender.terminate() }

        await loop.tick()
        let helperStatus = helperAppender.wait(timeout: 10.0)
        if helperStatus == nil { helperAppender.terminate() }
        #expect(helperStatus != nil, "helper appender did not exit within timeout")
        guard let helperStatus else { return }
        #expect(helperStatus == 0, "helper appender failed: status \(helperStatus)")

        let text = try String(contentsOf: target, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        // Every line must parse — no torn writes.
        for line in lines {
            let d = try #require(line.data(using: .utf8))
            #expect((try? JSONSerialization.jsonObject(with: d)) != nil,
                    "torn write: line did not parse: \(line)")
        }
        // All 3 Swift GROWTH records present.
        #expect(text.contains("swift1"))
        #expect(text.contains("swift2"))
        #expect(text.contains("swift3"))
        // All 5 helper records present.
        for i in 0..<5 {
            #expect(text.contains("helper write \(i)"),
                    "helper record \(i) lost — flock contract broken")
        }
    }

    // MARK: - gpt-5.5 round-3 strengthening: prove blocking + ordering,
    // not just no-loss.
    //
    // The existing test above proves "every record present after both
    // finish" — sufficient when each side is small + the race window is
    // narrow. It does NOT prove the Swift writer actually WAITED on the
    // external holder: a naive impl with no lock at all could pass it
    // simply because the two writes happen to land in disjoint byte
    // ranges. This test pins the cross-process flock contract by:
    //   1. Spawning a Swift helper that grabs <path>.lock for 1.5s
    //      and emits acquired/released timestamps to marker files.
    //   2. Waiting for the helper side to have the lock.
    //   3. Measuring how long Swift's locked write takes.
    //   4. Asserting (a) Swift waited >= 1.0s and (b) Swift's start was
    //      after the helper release timestamp — i.e. real blocking +
    //      ordering, not lucky interleaving.
    @Test func rem_proposals_lock_blocks_swift_until_helper_releases() async throws {
        let root = try mkTmp()
        try setupPersona(root)
        try setupDiary(root, dates: ["2026-05-28"])
        let target = canonicalProposalsURL(root)

        // Marker file paths the helper will write Unix-epoch
        // floats into. Distinct from <target>.lock so reading them
        // doesn't perturb the lock contents.
        let acquiredMarker = root.appendingPathComponent("helper_acquired.txt")
        let releasedMarker = root.appendingPathComponent("helper_released.txt")

        // Bumped 1.5s → 3.0s (lower bound below 1.0s → 2.0s) so Swift
        // startup lag on a loaded box can't eat into the measured-hold
        // window and false-fail the assertion.
        let helperHoldSec = 3.0
        let helper = try NativeAgentFlockChild.hold(
            lockPath: target.path + ".lock",
            acquiredMarker: acquiredMarker,
            releasedMarker: releasedMarker,
            holdSeconds: helperHoldSec
        )
        defer { helper.terminate() }

        // Wait until the helper has actually acquired the lock; polling the
        // marker file is more reliable than a flat sleep on a loaded CI box.
        let acquireDeadline = Date().addingTimeInterval(10.0)
        while !FileManager.default.fileExists(atPath: acquiredMarker.path) {
            if Date() > acquireDeadline { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: acquiredMarker.path),
                "Swift helper failed to acquire lock within deadline")

        // Build a single-proposal payload via the loop's normal path. We
        // measure how long tick() takes — under flock + helper holding it
        // for ~1.5s, tick() must take >= ~1s before it can write.
        let llm = MockLLMClient(scriptedResponses: [
            proposalsJSON(targetDoc: "GROWTH", evidence: ["2026-05-28"], texts: ["blocked_growth"]),
        ])
        let loop = makeLoop(dataRoot: root, llm: llm)

        let swiftStart = Date()
        await loop.tick()
        let swiftEnd = Date()
        let helperStatus = helper.wait(timeout: 10.0)
        if helperStatus == nil { helper.terminate() }
        #expect(helperStatus != nil, "flock helper did not exit within timeout")
        guard let helperStatus else { return }
        #expect(helperStatus == 0, "Swift helper failed: status \(helperStatus)")

        // (a) Swift's tick was blocked on the lock — total wait must
        // approach the hold duration. We use 1.0s (a generous floor under
        // helperHoldSec=1.5s) to leave margin for the gap between
        // the helper acquiring the lock and Swift's tick() reaching its
        // withFileLock call. Anything below 1.0s here means Swift slipped
        // through without ever blocking — i.e. the lock contract is
        // broken.
        let swiftElapsed = swiftEnd.timeIntervalSince(swiftStart)
        #expect(swiftElapsed >= 2.0,
                "Swift tick took only \(swiftElapsed)s — lock did not block (expected >= 2.0s while helper held it for \(helperHoldSec)s)")

        // (b) Ordering: Swift's write completion must be AFTER the helper's
        // release timestamp. We use end-of-tick as the conservative proxy
        // for when Swift was inside the locked region (it can only have
        // written after acquiring the lock, which can only have happened
        // after the helper released it).
        let releasedRaw = try String(contentsOf: releasedMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let helperReleased = try #require(TimeInterval(releasedRaw))
        let swiftEndUnix = swiftEnd.timeIntervalSince1970
        #expect(swiftEndUnix >= helperReleased,
                "Swift tick finished at \(swiftEndUnix) before helper released at \(helperReleased) — flock ordering violated")

        // Sanity: Swift's record landed.
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text.contains("blocked_growth"),
                "Swift's locked write was lost; file contents: \(text)")
    }
}
