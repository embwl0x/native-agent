import Foundation
import NativeAgentCore
import PersistenceCore
import Testing

@testable import ChatOrchestration

/// Continuous consolidation — NORTHSTAR clause 4, sweep item 45.
///
/// The contract these pin:
///   1. aging fires because an APPEND crossed a boundary, never on a clock;
///   2. the pre-turn threshold still works and its receipt names itself;
///   3. the transcript is byte-preserved through a verified backup on EVERY
///      path, aging included;
///   4. a background consolidation failure never reaches the turn;
///   5. the dream lane's half of "one consolidation owner" (its own suite).
@Suite("Continuous transcript consolidation")
struct ChatSessionAgingConsolidationTests {

    // MARK: 1 — event-driven, not scheduled

    @Test("aging fires on the append that crosses the boundary, not on a clock")
    func agingFiresOnTheCrossingAppend() async throws {
        let fixture = try Fixture(name: "crossing-append")
        try fixture.seed(messages: 6, contentChars: 400)
        let before = try Data(contentsOf: fixture.messagesURL)

        // BELOW the boundary: the same append, a boundary this transcript has
        // not reached — nothing is consolidated and nothing is written.
        //
        // 2026-09-06: the config threshold is raised for BOTH arms of this row.
        // The aging override is clamped to the model-capped backstop, so the
        // 1-token fixture default would collapse this "not reached" boundary to
        // 1 and consolidate. 200_000 against gpt-5.6's 400k window gives a
        // 160_000-token backstop, which this ~2.6 KB transcript is nowhere near.
        await SwiftNativeChatOrchestrationClient.runTranscriptAging(
            sessionId: fixture.sessionID,
            model: "gpt-5.6",
            surface: "chat",
            runId: nil,
            providerID: nil,
            boundaryTokens: 10_000_000,
            dataRoot: fixture.root,
            config: fixture.config(distill: false, thresholdTokens: 200_000),
            llm: SilentLLM(),
            now: { fixture.frozenNow },
            gate: fixture.openGate()
        )
        #expect(try Data(contentsOf: fixture.messagesURL) == before)
        #expect(try fixture.backupFiles().isEmpty)

        // The append that CROSSES it: older turns become one recollection row,
        // the keep-tail survives raw.
        await SwiftNativeChatOrchestrationClient.runTranscriptAging(
            sessionId: fixture.sessionID,
            model: "gpt-5.6",
            surface: "chat",
            runId: nil,
            providerID: nil,
            boundaryTokens: 1,
            dataRoot: fixture.root,
            config: fixture.config(distill: false, thresholdTokens: 200_000),
            llm: SilentLLM(),
            now: { fixture.frozenNow },
            gate: fixture.openGate()
        )
        let rows = try fixture.rows()
        #expect(rows.count == 3)               // recollection + keepCount(2) tail
        #expect(fixture.metadata(rows[0])?["kind"] == .string("compaction_summary"))
        #expect(fixture.metadata(rows[0])?["lane"] == .string("aging"))
        #expect(fixture.metadata(rows[0])?["messages_replaced"] == .int(4))
    }

    /// WHAT A PASS NEWLY FOLDED MUST BE VISIBLE — WITHOUT LYING ABOUT COVERAGE
    /// (2026-09-11, retargeted after the Astra audit).
    ///
    /// A second pass replaces [prior recollection, new raw turns...]. The
    /// recollection's text carries the prior note in full, so `covers_from`
    /// stays at the whole text's start — the dream lane's admission test reads
    /// it. The newly folded interval is reported separately in
    /// `incorporated_from` / `incorporated_until`, and THAT is what advances.
    @Test("a second consolidation advances the incorporated window, coverage stays honest")
    func secondPassAdvancesCoversFrom() async throws {
        let fixture = try Fixture(name: "covers-from-advances")
        try fixture.seed(messages: 6, contentChars: 400)
        await SwiftNativeChatOrchestrationClient.runTranscriptAging(
            sessionId: fixture.sessionID,
            model: "gpt-5.6",
            surface: "chat",
            runId: nil,
            providerID: nil,
            boundaryTokens: 1,
            dataRoot: fixture.root,
            config: fixture.config(distill: false, thresholdTokens: 200_000),
            llm: SilentLLM(),
            now: { fixture.frozenNow },
            gate: fixture.openGate()
        )
        let firstRows = try fixture.rows()
        let firstFrom = fixture.string(
            fixture.metadata(firstRows[0])?[ChatSessionRecollections.coversFromKey])
        let firstUntil = fixture.string(
            fixture.metadata(firstRows[0])?[ChatSessionRecollections.coversUntilKey])
        #expect(firstFrom != nil)
        #expect(firstUntil != nil)

        // New life lands after the first recollection, then a second pass folds
        // [recollection + those turns] into one row.
        try fixture.appendRawTurns(count: 4, startingIndex: 100, contentChars: 400)
        await SwiftNativeChatOrchestrationClient.runTranscriptAging(
            sessionId: fixture.sessionID,
            model: "gpt-5.6",
            surface: "chat",
            runId: nil,
            providerID: nil,
            boundaryTokens: 1,
            dataRoot: fixture.root,
            config: fixture.config(distill: false, thresholdTokens: 200_000),
            llm: SilentLLM(),
            now: { fixture.frozenNow },
            gate: fixture.openGate()
        )
        let secondRows = try fixture.rows()
        #expect(fixture.metadata(secondRows[0])?["kind"] == .string("compaction_summary"))
        let secondFrom = fixture.string(
            fixture.metadata(secondRows[0])?[ChatSessionRecollections.coversFromKey])
        let secondUntil = fixture.string(
            fixture.metadata(secondRows[0])?[ChatSessionRecollections.coversUntilKey])
        #expect(secondFrom != nil)
        #expect(secondUntil != nil)
        // Coverage still describes the whole text: the prior note is pinned
        // into it, so the span start must not move forward past it.
        #expect(secondFrom! == firstFrom!, "covers_from must stay honest about the pinned prior note")
        #expect(secondUntil! > firstUntil!)
        #expect(secondFrom! <= secondUntil!)
        // What this pass newly folded: the raw turns appended after pass one.
        let incorporatedFrom = fixture.string(
            fixture.metadata(secondRows[0])?[ChatSessionRecollections.incorporatedFromKey])
        let incorporatedUntil = fixture.string(
            fixture.metadata(secondRows[0])?[ChatSessionRecollections.incorporatedUntilKey])
        #expect(incorporatedFrom != nil)
        #expect(incorporatedUntil != nil)
        #expect(incorporatedFrom! > firstUntil!, "the incorporated window starts after pass one's material")
        #expect(incorporatedFrom! <= incorporatedUntil!)
    }

    /// REGRESSION (Astra audit 2026-09-11, finding 2): a recollection written
    /// before the dream mark, folded together with raw turns after it, must
    /// NOT read as "wholly after the mark". If it did, the dream lane would
    /// admit the whole row and re-consume the pre-mark material pinned in its
    /// text. Honest coverage makes the combined row straddle the mark, which
    /// the writer's clamp refuses to create in the first place.
    @Test("a pre-mark recollection folded with post-mark turns is never wholly after the mark")
    func combinedRecollectionIsNotWhollyAfterTheDreamMark() throws {
        func iso(_ value: String) -> String { value }
        let priorRecollection: JSONValue = .object([
            "id": .string("compact-prior"),
            "role": .string("system"),
            "content": .string("[NativeAgent compacted 4 earlier message(s).]\nuser: the old arc"),
            "createdAt": .string(iso("2026-09-08T10:00:00.000Z")),
            "metadata": .object([
                "kind": .string(ChatSessionRecollections.rowKind),
                ChatSessionRecollections.coversFromKey: .string(iso("2026-09-06T09:00:00.000Z")),
                ChatSessionRecollections.coversUntilKey: .string(iso("2026-09-08T09:00:00.000Z")),
            ]),
        ])
        func rawTurn(_ id: String, _ at: String) -> JSONValue {
            .object([
                "id": .string(id),
                "role": .string("user"),
                "content": .string("new life"),
                "createdAt": .string(iso(at)),
            ])
        }
        let rows = [
            priorRecollection,
            rawTurn("t1", "2026-09-10T12:00:00.000Z"),
            rawTurn("t2", "2026-09-10T13:00:00.000Z"),
        ]
        // The dream consumed everything through 09-09, raw.
        let mark = ChatSessionRecollections.parseTimestamp(.string("2026-09-09T00:00:00.000Z"))!

        let span = ChatSessionAutocompactor.coverageRange(rows)
        #expect(span.from == "2026-09-06T09:00:00.000Z",
                "coverage must start where the pinned prior note starts")
        #expect(span.until == "2026-09-10T13:00:00.000Z")
        let from = ChatSessionRecollections.parseTimestamp(.string(span.from!))!
        #expect(from <= mark, "the combined row is NOT wholly after the dream mark")

        // The newly folded interval is reported separately and does sit after
        // the mark — that is the key a "what moved this pass" reader wants.
        let incorporated = ChatSessionAutocompactor.incorporatedRange(rows)
        #expect(incorporated.from == "2026-09-10T12:00:00.000Z")

        // And the writer refuses to create the straddling row at all: only the
        // rows whose material ends at or before the mark may be folded.
        let safe = ChatSessionAutocompactor.markSafeReplacementCount(
            rows: rows,
            replaceCount: 3,
            mark: mark
        )
        #expect(safe == 1, "clamped to the pre-mark recollection; the post-mark turns stay raw")
    }

    /// No timer, no schedule, no budget — the lane exists only as a reaction to
    /// an append, and all three turn lanes must reach it. A source pin because
    /// the absence of a scheduler is the whole point of the item.
    @Test("the aging lane owns no clock and every turn lane triggers it")
    func agingLaneIsPurelyEventDriven() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ChatOrchestrationTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // NativeAgentCore
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // repo root
        let lane = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatSessionAgingConsolidation.swift"
            ),
            encoding: .utf8
        )
        for scheduler in ["Timer.", "asyncAfter", "DispatchSourceTimer", "RunLoop"] {
            #expect(!lane.contains(scheduler), "aging must not own a clock (found \(scheduler))")
        }
        // 2026-09-06: `Task.sleep` is no longer an absolute ban. The lane owns
        // exactly ONE sleep — the `agingPassDeadlineSeconds` watchdog that
        // cancels a wedged pass and hands its claim back, so a stuck
        // distillation cannot disable aging for the session for the life of
        // the process. That is a bound on a pass already running, not a clock
        // that decides when a pass starts, so the item's contract holds. A
        // SECOND sleep would be a schedule and fails this.
        #expect(
            lane.components(separatedBy: "Task.sleep").count - 1 == 1,
            "the only sleep in the lane is the wedged-pass watchdog"
        )
        #expect(lane.contains("agingPassDeadlineSeconds"))
        let callSites = [
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+TextCompatibility.swift",
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+StructuredChat.swift",
        ]
        var triggers = 0
        for path in callSites {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            triggers += source.components(separatedBy: "prepareSessionHistoryForTurn(").count - 1
        }
        // a11c1940 routes all three lanes through one aging preparation owner.
        #expect(triggers == 3)
        let preparation = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+MessagePersistence.swift"
            ), encoding: .utf8
        )
        #expect(preparation.components(separatedBy: "scheduleTranscriptAgingIfNeeded(").count - 1 == 1)
    }

    /// SEAM PIN (2026-09-01). The pre-turn backstop still builds its own
    /// distiller inline in `+MessagePersistence.swift` — a file owned by
    /// another builder this wave, so the two constructions were left as twins
    /// rather than rewritten under someone else's hands. They must stay
    /// identical; when that file is next touched, both call
    /// `makeAgingDistiller`. This fails the moment they drift.
    @Test("the aging distiller matches the backstop's construction")
    func agingDistillerMatchesBackstopConstruction() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChatOrchestration", isDirectory: true)
        let backstop = try String(
            contentsOf: sources.appendingPathComponent("ChatOrchestrationClient+MessagePersistence.swift"),
            encoding: .utf8
        )
        let aging = try String(
            contentsOf: sources.appendingPathComponent("ChatSessionAgingConsolidation.swift"),
            encoding: .utf8
        )
        // The pieces that decide WHICH model writes a recollection and HOW.
        for marker in [
            "pinnedModelStringForSurface(surface)",
            "surfacesPathOverride: dataRoot",
            "activeProviderPathOverride: dataRoot",
            "system: ChatCompactionDistiller.distillSystem",
            "surface: ChatCompactionDistiller.distillSurface",
        ] {
            #expect(backstop.contains(marker), "backstop construction changed: \(marker)")
            #expect(aging.contains(marker), "aging construction drifted: \(marker)")
        }
    }

    // MARK: 2 — the backstop still works, and names itself

    @Test("the pre-turn threshold still compacts and its receipt names the lane")
    func backstopStillWorksAndNamesItself() async throws {
        let fixture = try Fixture(name: "backstop-lane")
        try fixture.seed(messages: 6, contentChars: 400)

        let outcome = try await ChatSessionAutocompactor(
            dataRoot: fixture.root,
            config: fixture.config(distill: false),
            now: { fixture.frozenNow }
        ).compactIfNeeded(
            sessionId: fixture.sessionID,
            model: "gpt-5.6",
            surface: "chat",
            runId: nil
        )

        #expect(outcome.compacted)
        #expect(outcome.trigger == "auto_threshold")
        #expect(outcome.lane == "backstop")
        // Every lane is named, and only from its trigger.
        #expect(ChatSessionCompactionOutcome.lane(forTrigger: "aging_boundary") == "aging")
        #expect(ChatSessionCompactionOutcome.lane(forTrigger: "manual_request") == "manual")
        #expect(ChatSessionCompactionOutcome.lane(forTrigger: "auto_threshold") == "backstop")

        let trace = try fixture.traceRows().last
        #expect(fixture.payload(trace)?["lane"] == .string("backstop"))
        #expect(fixture.payload(trace)?["schema"] == .string("context.compact.v1"))
    }

    /// The aging boundary is always below the pre-turn threshold, so the
    /// backstop is what fires LAST, not first.
    @Test("the aging boundary sits below the backstop threshold")
    func agingBoundaryIsBelowTheBackstop() {
        let config = ChatSessionAutocompactionConfig(thresholdTokens: 200_000, keepCount: 20)
        let backstop = config.effectiveThresholdTokens(forModel: "gpt-5.6")
        let aging = config.effectiveAgingThresholdTokens(forModel: "gpt-5.6")
        #expect(aging < backstop)
        // 2026-09-06: the old 50_000 read the 200k PREFERENCE as the ceiling.
        // `effectiveAgingThresholdTokens` takes a quarter of the MODEL-CAPPED
        // backstop, and gpt-5.6 has a verified 400k window
        // (FirstPartyModelCatalog), so the backstop is
        // min(200_000, 0.40 × 400_000) = 160_000 and the aging boundary is a
        // quarter of that. Both numbers are pinned so a window change or a
        // fraction change names itself instead of moving one derived literal.
        #expect(backstop == 160_000)
        #expect(aging == 40_000)
    }

    // MARK: 3 — transcript byte-preserved via backup on every path

    @Test("aging takes a verified byte-identical backup before replacing anything")
    func agingBacksUpBeforeReplacing() async throws {
        let fixture = try Fixture(name: "aging-backup")
        try fixture.seed(messages: 6, contentChars: 400)
        let before = try Data(contentsOf: fixture.messagesURL)

        await SwiftNativeChatOrchestrationClient.runTranscriptAging(
            sessionId: fixture.sessionID,
            model: "gpt-5.6",
            surface: "chat",
            runId: nil,
            providerID: nil,
            boundaryTokens: 1,
            dataRoot: fixture.root,
            config: fixture.config(distill: false),
            llm: SilentLLM(),
            now: { fixture.frozenNow },
            gate: fixture.openGate()
        )

        let backups = try fixture.backupFiles()
        #expect(backups.count == 1)
        // Byte-for-byte: nothing the transcript held before aging is lost.
        #expect(try Data(contentsOf: try #require(backups.first)) == before)
        #expect(try Data(contentsOf: fixture.messagesURL) != before)
    }

    @Test("an unbackupable transcript is never rewritten by the aging lane")
    func agingRefusesWithoutAVerifiedBackup() async throws {
        let fixture = try Fixture(name: "aging-backup-refused")
        try fixture.seed(messages: 6, contentChars: 400)
        let before = try Data(contentsOf: fixture.messagesURL)

        // Same refusal the backstop makes, reached through the aging lane: the
        // autocompactor throws, the background pass swallows it into a receipt,
        // and the transcript is exactly as the turn left it.
        let compactor = ChatSessionAutocompactor(
            dataRoot: fixture.root,
            config: fixture.config(distill: false),
            now: { fixture.frozenNow },
            backupFileCopy: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        await #expect(throws: Error.self) {
            _ = try await compactor.compactIfNeeded(
                sessionId: fixture.sessionID,
                model: "gpt-5.6",
                surface: "chat",
                runId: nil,
                trigger: SwiftNativeChatOrchestrationClient.agingTrigger,
                thresholdTokensOverride: 1,
                keepTailFixed: true
            )
        }
        #expect(try Data(contentsOf: fixture.messagesURL) == before)
        #expect(try fixture.backupFiles().isEmpty)
    }

    @Test("a corrupt transcript is refused by the aging lane, not repaired")
    func agingRefusesCorruptTranscript() async throws {
        let fixture = try Fixture(name: "aging-corrupt")
        try fixture.seed(messages: 4, contentChars: 400)
        var corrupt = try Data(contentsOf: fixture.messagesURL)
        corrupt.append(Data("{not json\n".utf8))
        try corrupt.write(to: fixture.messagesURL)

        await SwiftNativeChatOrchestrationClient.runTranscriptAging(
            sessionId: fixture.sessionID,
            model: "gpt-5.6",
            surface: "chat",
            runId: nil,
            providerID: nil,
            boundaryTokens: 1,
            dataRoot: fixture.root,
            config: fixture.config(distill: false),
            llm: SilentLLM(),
            now: { fixture.frozenNow },
            gate: fixture.openGate()
        )

        #expect(try Data(contentsOf: fixture.messagesURL) == corrupt)
        #expect(try fixture.backupFiles().isEmpty)
        // Fail LOUD: the refusal is a receipt, not silence.
        let trace = try fixture.traceRows().last
        #expect(fixture.string(trace?["status"]) == "error")
        #expect(fixture.payload(trace)?["lane"] == .string("aging"))
    }

    // MARK: 4 — a background failure never blocks a turn

    @Test("a distillation failure leaves the mechanical recollection standing")
    func distillationFailureNeverBlocksATurn() async throws {
        let fixture = try Fixture(name: "distill-failure")
        try fixture.seed(messages: 6, contentChars: 400)

        // The whole pass is non-throwing by signature; this proves the LLM
        // failure is absorbed AND that the consolidation itself still stands.
        await SwiftNativeChatOrchestrationClient.runTranscriptAging(
            sessionId: fixture.sessionID,
            model: "gpt-5.6",
            surface: "chat",
            runId: nil,
            providerID: nil,
            boundaryTokens: 1,
            dataRoot: fixture.root,
            config: fixture.config(distill: true),
            llm: ThrowingLLM(),
            now: { fixture.frozenNow },
            gate: fixture.openGate()
        )

        let rows = try fixture.rows()
        #expect(rows.count == 3)
        let metadata = fixture.metadata(rows[0])
        #expect(metadata?["kind"] == .string("compaction_summary"))
        // Mechanical text stands; the distiller never got to swap it.
        #expect(metadata?["distill"] == .string("pending"))
        #expect(fixture.string(rows[0]["content"])?.contains("NativeAgent compacted") == true)
    }

    @Test("a throttled body defers the pass without touching the transcript")
    func throttledBodyDefersWithoutWriting() async throws {
        let fixture = try Fixture(name: "gate-deferred")
        try fixture.seed(messages: 6, contentChars: 400)
        let before = try Data(contentsOf: fixture.messagesURL)

        let gate = BackgroundConsolidationGate()
        gate.install { _ in .deferred("thermal pressure") }
        let coordinator = ChatTranscriptAgingCoordinator()
        for _ in 0..<3 {
            await SwiftNativeChatOrchestrationClient.runTranscriptAging(
                sessionId: fixture.sessionID,
                model: "gpt-5.6",
                surface: "chat",
                runId: nil,
                providerID: nil,
                boundaryTokens: 1,
                dataRoot: fixture.root,
                config: fixture.config(distill: false),
                llm: SilentLLM(),
                now: { fixture.frozenNow },
                gate: gate,
                coordinator: coordinator
            )
        }

        #expect(try Data(contentsOf: fixture.messagesURL) == before)
        #expect(try fixture.backupFiles().isEmpty)
        let traces = try fixture.traceRows()
        // Honest once, not once per append while the Mac stays hot.
        #expect(traces.count == 1)
        #expect(fixture.string(traces.last?["status"]) == "deferred")
        #expect(fixture.payload(traces.last)?["reason"] == .string("thermal pressure"))
    }

    @Test("one aging pass per session at a time")
    func agingIsSerializedPerSession() async {
        let coordinator = ChatTranscriptAgingCoordinator()
        #expect(await coordinator.claim("s1"))
        #expect(!(await coordinator.claim("s1")))
        #expect(await coordinator.claim("s2"))
        await coordinator.release("s1")
        #expect(await coordinator.claim("s1"))
    }

    // MARK: — the recollection row the dream lane reads

    @Test("a recollection row records the stretch of life it stands for")
    func recollectionRecordsItsCoverage() async throws {
        let fixture = try Fixture(name: "coverage")
        try fixture.seed(messages: 6, contentChars: 400)

        await SwiftNativeChatOrchestrationClient.runTranscriptAging(
            sessionId: fixture.sessionID,
            model: "gpt-5.6",
            surface: "chat",
            runId: nil,
            providerID: nil,
            boundaryTokens: 1,
            dataRoot: fixture.root,
            config: fixture.config(distill: false),
            llm: SilentLLM(),
            now: { fixture.frozenNow },
            gate: fixture.openGate()
        )

        let recollections = ChatSessionRecollections.recollections(
            forSession: fixture.sessionID,
            dataRoot: fixture.root
        )
        #expect(recollections.count == 1)
        let recollection = try #require(recollections.first)
        #expect(recollection.messagesReplaced == 4)
        #expect(!recollection.distilled)
        // Coverage spans the REPLACED turns, not the write instant — the field
        // the dream lane compares its high-water mark against.
        #expect(recollection.coversFrom == fixture.messageDate(0))
        #expect(recollection.coversUntil == fixture.messageDate(3))
        #expect(recollection.consolidatedThrough == fixture.messageDate(3))
        #expect(recollection.consolidatedThrough != recollection.createdAt)
    }

    // MARK: — clause 6: reach, not weight

    /// The aging lane adds NO prompt mass. What it writes is the row history
    /// already renders — same `kind`, same per-row cap, same bounded head+tail
    /// budget — so a consolidated session costs LESS context than the raw turns
    /// it replaced, never more, and there is no second injection site.
    @Test("aging adds no new prompt mass")
    func agingAddsNoPromptMass() async throws {
        let fixture = try Fixture(name: "no-prompt-mass")
        // 2026-09-06: seeded LONG on purpose. The mechanical summary caps each
        // replaced turn at 500 chars, so at the 400-char body the rest of this
        // suite uses, nothing is truncated and the fold can only win back JSON
        // overhead — which the recollection row's own coverage metadata
        // (coversFrom / coversUntil / consolidatedThrough) now spends. At 2 KB
        // bodies the cap is what decides the result, which is the claim this
        // row is making.
        try fixture.seed(messages: 6, contentChars: 2_000)
        let rawChars = try Data(contentsOf: fixture.messagesURL).count

        await SwiftNativeChatOrchestrationClient.runTranscriptAging(
            sessionId: fixture.sessionID,
            model: "gpt-5.6",
            surface: "chat",
            runId: nil,
            providerID: nil,
            boundaryTokens: 1,
            dataRoot: fixture.root,
            config: fixture.config(distill: false),
            llm: SilentLLM(),
            now: { fixture.frozenNow },
            gate: fixture.openGate()
        )

        // Rendered through the SAME path a compaction summary always took.
        let rows = try fixture.rows()
        #expect(fixture.metadata(rows[0])?["kind"] == .string(ChatSessionRecollections.rowKind))
        #expect(try Data(contentsOf: fixture.messagesURL).count < rawChars)

        // No context assembly reaches into the aging lane, and the lane reaches
        // into no prompt.
        let lane = try String(contentsOf: fixture.laneSourceURL, encoding: .utf8)
        for injection in ["systemPrompt", "conversationHistory", "buildContext", "residentPacket"] {
            #expect(!lane.contains(injection), "aging must not assemble prompt (found \(injection))")
        }
    }

    // MARK: - fixture

    private struct Fixture {
        let root: URL
        let sessionID: String
        let messagesURL: URL
        let frozenNow = Date(timeIntervalSince1970: 1_780_000_000)

        init(name: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nativeagent-aging-\(name)-\(UUID().uuidString)", isDirectory: true)
            sessionID = "session-\(name)"
            messagesURL = root
                .appendingPathComponent("chat/messages", isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl")
            try FileManager.default.createDirectory(
                at: messagesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var laneSourceURL: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/ChatOrchestration/ChatSessionAgingConsolidation.swift"
                )
        }

        /// `thresholdTokens: 1` makes every seeded transcript already over the
        /// backstop, which is what most rows here want.
        ///
        /// 2026-09-06: a row that needs a boundary the transcript has NOT
        /// reached must raise it. `compactIfNeeded` now clamps the aging
        /// override to the model-capped backstop
        /// (`thresholdTokensOverride.map { max(1, min($0, modelThresholdTokens)) }`
        /// in ChatSessionAutocompactor.swift) so the continuous lane can never
        /// sit above the stop-the-world one — with a 1-token config every
        /// override collapses to 1 and no boundary is ever "not reached".
        func config(
            distill: Bool,
            thresholdTokens: Int = 1
        ) -> ChatSessionAutocompactionConfig {
            ChatSessionAutocompactionConfig(
                thresholdTokens: thresholdTokens,
                keepCount: 2,
                distillEnabled: distill
            )
        }

        func openGate() -> BackgroundConsolidationGate {
            let gate = BackgroundConsolidationGate()
            gate.install { _ in .allowed }
            return gate
        }

        func messageDate(_ index: Int) -> Date {
            frozenNow.addingTimeInterval(Double(index) * 60 - 3_600)
        }

        func seed(messages: Int, contentChars: Int) throws {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var payload = Data()
            for index in 0..<messages {
                let row = JSONValue.object([
                    "id": .string("row-\(index)"),
                    "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                    "content": .string("turn \(index) " + String(repeating: "x", count: contentChars)),
                    "createdAt": .string(iso.string(from: messageDate(index))),
                ])
                payload.append(Data(try row.serialize(pretty: false).utf8))
                payload.append(0x0A)
            }
            try payload.write(to: messagesURL)
        }

        /// Extra raw turns appended AFTER an existing transcript (recollection
        /// rows included), timestamped later than everything seeded.
        func appendRawTurns(count: Int, startingIndex: Int, contentChars: Int) throws {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var payload = try Data(contentsOf: messagesURL)
            for offset in 0..<count {
                let index = startingIndex + offset
                let row = JSONValue.object([
                    "id": .string("row-\(index)"),
                    "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                    "content": .string("turn \(index) " + String(repeating: "x", count: contentChars)),
                    "createdAt": .string(iso.string(from: messageDate(index))),
                ])
                payload.append(Data(try row.serialize(pretty: false).utf8))
                payload.append(0x0A)
            }
            try payload.write(to: messagesURL)
        }

        func rows() throws -> [[String: JSONValue]] {
            let text = try String(contentsOf: messagesURL, encoding: .utf8)
            return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let parsed = try? JSONValue.parse(data),
                      case .object(let obj) = parsed else { return nil }
                return obj
            }
        }

        func traceRows() throws -> [[String: JSONValue]] {
            let path = root
                .appendingPathComponent("traces", isDirectory: true)
                .appendingPathComponent("events.jsonl")
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
            return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let parsed = try? JSONValue.parse(data),
                      case .object(let obj) = parsed else { return nil }
                return obj
            }
        }

        func metadata(_ row: [String: JSONValue]) -> [String: JSONValue]? {
            guard case .object(let value)? = row["metadata"] else { return nil }
            return value
        }

        func payload(_ row: [String: JSONValue]?) -> [String: JSONValue]? {
            guard case .object(let value)? = row?["payload"] else { return nil }
            return value
        }

        func string(_ value: JSONValue?) -> String? {
            guard case .string(let text)? = value else { return nil }
            return text
        }

        func backupFiles() throws -> [URL] {
            let directory = root
                .appendingPathComponent("chat/sessions", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("messages.compact.") }
        }
    }
}

private struct SilentLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String { "" }
}

private struct ThrowingLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        throw NSError(domain: "ChatSessionAgingConsolidationTests", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "distill provider unavailable",
        ])
    }
}
