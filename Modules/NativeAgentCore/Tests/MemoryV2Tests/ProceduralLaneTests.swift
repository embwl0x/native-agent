import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import MemoryV2

// The procedural lane (sweep item 38; docs/build_plans/procedural-memory-lane.md).
//
// Pins the plan's evidence floor and every bound the lane promises: one
// proposal per n-gram, dedupe by compiled digest, a pending cap, verified
// successes only, and — the clause-6 line — nothing entering a prompt before
// the owner has approved a card.
@Suite("Procedural lane")
struct ProceduralLaneTests {

    // MARK: Harness

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedural-lane-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeMemory() throws -> SwiftNativeMemoryV2 {
        let store = try MemoryStorage()
        return SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: MemoryStorageBridge(storage: store)
        )
    }

    /// The evidence-line shape `TurnToolEvidenceProjection` emits: succeeded,
    /// secret-redacted, `name(k=v) ok: result`.
    private let readThenWrite = [
        "read_file(path=/Users/j/Projects/a/Auth.swift) ok: struct Auth {",
        "write_file(path=/Users/j/Projects/a/Auth.swift) ok: wrote 812 bytes",
    ]

    private func lane(
        _ root: URL,
        configuration: ProceduralLaneConfiguration = .init()
    ) -> ProceduralLane {
        ProceduralLane(dataRoot: root, configuration: configuration)
    }

    private func pendingProposals(_ root: URL) async throws -> [ApprovalRecord] {
        try await SwiftNativeApprovalInbox(root: root).list(
            filter: ApprovalFilter(status: "pending", action: ProceduralSkillProposal.approvalAction)
        )
    }

    // MARK: The floor

    @Test("three same-shape verified runs across two days mint exactly one proposal")
    func threeRunsAcrossTwoDaysMintOne() async throws {
        let root = makeRoot()
        let lane = lane(root)
        let first = await lane.observe(
            steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: "2026-08-30")
        let second = await lane.observe(
            steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: "2026-08-30")
        let third = await lane.observe(
            steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: "2026-08-31")

        if case .counted(_, let occurrences, let days) = first {
            #expect(occurrences == 1)
            #expect(days == 1)
        } else {
            Issue.record("first run should count, got \(first)")
        }
        // Two occurrences on ONE day is not the floor — the floor is two DAYS.
        if case .counted(_, let occurrences, let days) = second {
            #expect(occurrences == 2)
            #expect(days == 1)
        } else {
            Issue.record("second run should count, got \(second)")
        }
        guard case .minted(let approvalID, _, _) = third else {
            Issue.record("third run on a second day should mint, got \(third)")
            return
        }
        #expect(!approvalID.isEmpty)
        let pending = try await pendingProposals(root)
        #expect(pending.count == 1)
        #expect(pending[0].action == "skill.proposal")
        #expect(pending[0].localOnly)
        #expect(!pending[0].remoteResolvable)
    }

    @Test("two runs do not mint")
    func twoRunsDoNotMint() async throws {
        let root = makeRoot()
        let lane = lane(root)
        _ = await lane.observe(
            steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: "2026-08-30")
        let second = await lane.observe(
            steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: "2026-08-31")
        // Two days, but only two occurrences: the count floor is three.
        if case .counted(_, let occurrences, let days) = second {
            #expect(occurrences == 2)
            #expect(days == 2)
        } else {
            Issue.record("second run should count without minting, got \(second)")
        }
        #expect(try await pendingProposals(root).isEmpty)
    }

    @Test("a fourth repeat does not mint a second proposal")
    func fourthRepeatDoesNotMintAgain() async throws {
        let root = makeRoot()
        let lane = lane(root)
        let days = ["2026-08-30", "2026-08-30", "2026-08-31", "2026-09-01"]
        var outcomes: [ProceduralLaneOutcome] = []
        for day in days {
            outcomes.append(await lane.observe(
                steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: day))
        }
        guard case .minted = outcomes[2] else {
            Issue.record("third run should mint, got \(outcomes[2])")
            return
        }
        #expect(outcomes[3] == .blocked(.alreadyProposedForSequence))
        #expect(try await pendingProposals(root).count == 1)
        // The fourth repeat is still COUNTED — evidence keeps accruing even
        // though the lane has already asked once.
        let entries = await lane.ledgerEntries()
        #expect(entries.count == 1)
        #expect(entries[0].occurrenceCount == 4)
        #expect(entries[0].proposedProcedureID != nil)
    }

    @Test("a failed run in the middle does not count and resets nothing")
    func failedRunDoesNotCountAndDoesNotReset() async throws {
        let root = makeRoot()
        let lane = lane(root)
        _ = await lane.observe(
            steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: "2026-08-30")
        // A turn whose write FAILED: the evidence projection is success-only,
        // so the failed dispatch contributes no line at all and the turn's
        // sequence is a different (one-step, below the length floor) shape.
        let failedTurn = await lane.observe(
            steps: ProceduralEvidenceShaper.steps(from: [readThenWrite[0]]), day: "2026-08-31")
        #expect(failedTurn == .ignored)

        let entriesAfterFailure = await lane.ledgerEntries()
        #expect(entriesAfterFailure.count == 1)
        #expect(entriesAfterFailure[0].occurrenceCount == 1)

        _ = await lane.observe(
            steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: "2026-08-31")
        let third = await lane.observe(
            steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: "2026-09-01")
        guard case .minted = third else {
            Issue.record("the failed run must not have reset the count, got \(third)")
            return
        }
        #expect(try await pendingProposals(root).count == 1)
    }

    @Test("a turn whose window was broken counts nothing")
    func brokenWindowTurnsAreIgnored() async throws {
        let root = makeRoot()
        let lane = lane(root)
        // `read ok, write ok, run_tests failed` — the projection drops the
        // failure and appends its break marker. Without reading that marker
        // this reads as a clean `read → write` and mints on the third day.
        let brokenTurn = readThenWrite + [ProceduralEvidenceShaper.sequenceBreakMarker]
        for day in ["2026-08-30", "2026-08-30", "2026-08-31"] {
            let outcome = await lane.observeTurn(
                userMessage: "fix the auth file",
                toolEvidence: brokenTurn,
                sessionId: "session-broken"
            )
            #expect(outcome == .ignored, "a broken window must not count, got \(outcome) on \(day)")
        }
        #expect(await lane.ledgerEntries().isEmpty)
        #expect(try await pendingProposals(root).isEmpty)

        // The same shape from three CLEAN turns still mints: a bad afternoon
        // is ignored, not held against the procedure.
        var last: ProceduralLaneOutcome = .ignored
        for _ in 0..<3 {
            last = await lane.observeTurn(
                userMessage: "fix the auth file",
                toolEvidence: readThenWrite,
                sessionId: "session-clean"
            )
        }
        // Three clean turns on one wall-clock day: counted, not yet minted.
        if case .counted(_, let occurrences, _) = last {
            #expect(occurrences == 3)
        } else {
            Issue.record("clean turns should count, got \(last)")
        }
    }

    @Test("a step is only verified when the line says ok where ok belongs")
    func onlyExplicitSuccessTokensBecomeSteps() {
        // Present and in position ⇒ a step.
        #expect(ProceduralEvidenceShaper.step(from: "read_file(path=/a/b.swift) ok") != nil)
        #expect(ProceduralEvidenceShaper.step(from: "read_file ok: /a/b.swift") != nil)
        // Absent, or any other status ⇒ not a step. A bare tool name used to
        // be stamped `tool_result_succeeded` on the strength of its prefix.
        for line in [
            "read_file",
            "read_file(path=/a/b.swift)",
            "run_tests(path=/a) failed: 3 assertions",
            "mac_open(path=/a) pending_approval",
            "mac_open(path=/a) cancelled",
            "mac_open(path=/a) timeout: no reply",
            "read_file(path=/a/b.swift okay",
            ProceduralEvidenceShaper.sequenceBreakMarker,
        ] {
            #expect(ProceduralEvidenceShaper.step(from: line) == nil,
                    "expected no step for \(line)")
        }
    }

    @Test("a different argument shape is a different procedure")
    func differentArgumentShapeIsADifferentSequence() async throws {
        let root = makeRoot()
        let lane = lane(root)
        for day in ["2026-08-30", "2026-08-31"] {
            _ = await lane.observe(
                steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: day)
        }
        let other = await lane.observe(
            steps: ProceduralEvidenceShaper.steps(from: [
                "read_file(limit=200, path=/Users/j/x.swift) ok: struct X {",
                "write_file(path=/Users/j/x.swift) ok: wrote 12 bytes",
            ]),
            day: "2026-09-01"
        )
        // Compatible arg SHAPES only: `read_file(limit,path)` is not
        // `read_file(path)`, so this is a second sequence at one occurrence.
        if case .counted(_, let occurrences, _) = other {
            #expect(occurrences == 1)
        } else {
            Issue.record("a different arg shape should start its own count, got \(other)")
        }
        #expect(await lane.ledgerEntries().count == 2)
        #expect(try await pendingProposals(root).isEmpty)
    }

    // MARK: Bounds

    @Test("the pending cap holds")
    func pendingCapHolds() async throws {
        let root = makeRoot()
        let lane = lane(root, configuration: .init(pendingProposalCap: 2))
        // Three distinct sequences, each crossing the floor.
        let sequences = [
            ["read_file(path=/a/One.swift) ok: x", "write_file(path=/a/One.swift) ok: y"],
            ["list_dir(path=/b) ok: One.swift", "read_file(path=/b/Two.swift) ok: z"],
            ["git_status(cwd=/c) ok: /c/Three.swift", "run_tests(cwd=/c) ok: /c/report.txt"],
        ]
        var outcomes: [ProceduralLaneOutcome] = []
        for sequence in sequences {
            for day in ["2026-08-30", "2026-08-30", "2026-08-31"] {
                outcomes.append(await lane.observe(
                    steps: ProceduralEvidenceShaper.steps(from: sequence), day: day))
            }
        }
        let minted = outcomes.filter { if case .minted = $0 { return true } else { return false } }
        #expect(minted.count == 2)
        #expect(outcomes.contains(.blocked(.pendingCapReached)))
        #expect(try await pendingProposals(root).count == 2)
    }

    @Test("a card for the same sequence blocks a re-mint on different days")
    func duplicateSequenceIsBlockedAcrossEvidenceAggregates() async throws {
        let root = makeRoot()
        let steps = ProceduralEvidenceShaper.steps(from: readThenWrite)
        // A card filed from a DIFFERENT evidence aggregate: nine runs, three
        // days in July. Its `procedureId` digest folds those in, so it shares
        // nothing with what the lane compiles below except the shape — which
        // is the only thing that should matter.
        let filed = ProceduralProcedureCompiler.compile(
            steps: steps, occurrenceCount: 9,
            observedDays: ["2026-07-01", "2026-07-02", "2026-07-03"],
            verifiedSuccessCount: 9
        )
        let inbox = SwiftNativeApprovalInbox(root: root)
        _ = try await ProceduralSkillProposal.stage(procedure: filed, inbox: inbox)

        // A fresh lane (no ledger memory of the mint) reaches the floor on new
        // days and compiles a different `procedureId`. Keyed on the shape, the
        // card already on file still stops it.
        let lane = lane(root)
        var last: ProceduralLaneOutcome = .ignored
        for day in ["2026-08-30", "2026-08-30", "2026-08-31"] {
            last = await lane.observe(steps: steps, day: day)
        }
        let reminted = ProceduralProcedureCompiler.compile(
            steps: steps, occurrenceCount: 3,
            observedDays: ["2026-08-30", "2026-08-31"], verifiedSuccessCount: 3
        )
        #expect(reminted.id != filed.id)
        #expect(reminted.sequenceIdentity == filed.sequenceIdentity)
        #expect(last == .blocked(.duplicateProcedureDigest))
        #expect(try await pendingProposals(root).count == 1)
    }

    @Test("losing the ledger row does not re-mint an already-proposed sequence")
    func proposedSequencesOutliveLedgerEviction() async throws {
        let root = makeRoot()
        let steps = ProceduralEvidenceShaper.steps(from: readThenWrite)
        let first = lane(root)
        var minted: ProceduralLaneOutcome = .ignored
        for day in ["2026-08-30", "2026-08-30", "2026-08-31"] {
            minted = await first.observe(steps: steps, day: day)
        }
        guard case .minted(_, _, let identity) = minted else {
            Issue.record("the floor should mint, got \(minted)")
            return
        }
        #expect(await first.proposedSequenceIdentities() == [identity])

        // The occurrence ledger is capped at 512 rows and evicts oldest-touched
        // first, so this row is not durable. Take it away entirely.
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("procedural_lane/ledger.json"))
        #expect(await first.ledgerEntries().isEmpty)

        let fresh = lane(root)
        var last: ProceduralLaneOutcome = .ignored
        for day in ["2026-09-14", "2026-09-14", "2026-09-15"] {
            last = await fresh.observe(steps: steps, day: day)
        }
        #expect(last == .blocked(.alreadyProposedForSequence))
        #expect(try await pendingProposals(root).count == 1)
    }

    @Test("transient readers never become procedure")
    func transientReadersAreExcluded() async throws {
        let root = makeRoot()
        let lane = lane(root)
        // Both tools are on the evidence lane's denylist: a reading that is
        // true for a moment is not craft.
        let steps = ProceduralEvidenceShaper.steps(from: [
            "recall_memory(query=auth) ok: /Users/j/notes.md",
            "screenshot(path=/tmp/shot.png) ok: /tmp/shot.png",
        ])
        #expect(steps.isEmpty)
        for day in ["2026-08-30", "2026-08-30", "2026-08-31"] {
            #expect(await lane.observe(steps: steps, day: day) == .ignored)
        }
        #expect(try await pendingProposals(root).isEmpty)
    }

    // 2026-09-12, User: a bridge turn is a full turn. A procedure she runs for
    // Claude or Codex is her procedure as much as one she runs for User, so the
    // agent-seat skip is gone and the ordinary floor is the only gate left.
    @Test("bridge-agent turns are counted like any turn")
    func agentSeatTurnsAreCounted() async throws {
        let root = makeRoot()
        let lane = lane(root)
        var outcomes: [ProceduralLaneOutcome] = []
        for _ in 0..<3 {
            outcomes.append(await lane.observeTurn(
                userMessage: "[from: claude, via bridge] read then write the file",
                toolEvidence: readThenWrite,
                sessionId: "session-bridge"
            ))
        }
        // Three runs, but all on ONE day: the two-DAY floor is what holds them
        // back now, not the seat they came from.
        for (index, outcome) in outcomes.enumerated() {
            if case .counted(_, let occurrences, let days) = outcome {
                #expect(occurrences == index + 1)
                #expect(days == 1)
            } else {
                Issue.record("bridge run \(index + 1) should count, got \(outcome)")
            }
        }
        #expect(await lane.ledgerEntries().count == 1)
        // Clause 6 unchanged: nothing reaches a prompt before the owner approves.
        #expect(try await pendingProposals(root).isEmpty)
    }

    // MARK: Payload-free

    @Test("nothing the lane stores carries an argument value")
    func ledgerAndCardArePayloadFree() async throws {
        let root = makeRoot()
        let lane = lane(root)
        for day in ["2026-08-30", "2026-08-30", "2026-08-31"] {
            _ = await lane.observe(
                steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: day)
        }
        let ledgerBytes = try String(
            contentsOf: root.appendingPathComponent("procedural_lane/ledger.json"),
            encoding: .utf8
        )
        #expect(ledgerBytes.contains("read_file"))
        #expect(ledgerBytes.contains("\"path\""))
        // The VALUE never survives shaping — only the key does.
        #expect(!ledgerBytes.contains("Auth.swift"))
        #expect(!ledgerBytes.contains("/Users/j"))

        let card = try #require(try await pendingProposals(root).first)
        #expect(!card.payloadPreview.contains("Auth.swift"))
        let payloadBytes = try card.payload.serialize(pretty: false)
        #expect(!payloadBytes.contains("Auth.swift"))
    }

    // MARK: The landing strip

    @Test("approval writes a skill body and a recall pointer; nothing before it")
    func approvalProducesBodyAndPointer() async throws {
        let root = makeRoot()
        let memory = try makeMemory()
        let lane = lane(root)
        for day in ["2026-08-30", "2026-08-30", "2026-08-31"] {
            _ = await lane.observe(
                steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: day)
        }
        let bodiesDir = root.appendingPathComponent("skills/bodies", isDirectory: true)

        // BEFORE approval: no body, no pointer, no prompt-facing row anywhere.
        #expect(!FileManager.default.fileExists(atPath: bodiesDir.path))
        _ = try await memory.syncSkillPointers(bodiesDirs: [bodiesDir])
        #expect(try await memory.listMemory(kind: "skill").isEmpty)

        let inbox = SwiftNativeApprovalInbox(root: root)
        let card = try #require(try await pendingProposals(root).first)
        let resolved = try await inbox.resolve(
            card.id, decision: .approved, provenance: .local(decidedBy: "user"))

        let outcome = try await ProceduralSkillProposal.applyResolved(
            record: resolved, dataRoot: root)
        guard case .applied(let skillName, let bodyPath, let written) = outcome else {
            Issue.record("approval should apply, got \(outcome)")
            return
        }
        #expect(written)
        #expect(skillName.hasPrefix("learned-read-file-then-write-file-"))
        let body = try String(contentsOfFile: bodyPath, encoding: .utf8)
        #expect(body == card.payloadPreview)
        #expect(SkillBodyHygiene.violations(in: body).isEmpty)

        let sync = try await memory.syncSkillPointers(bodiesDirs: [bodiesDir])
        #expect(sync.added == 1)
        let pointers = try await memory.listMemory(kind: "skill")
        #expect(pointers.count == 1)
        #expect(pointers[0].id == "skill-pointer:\(skillName)")

        // Idempotent: a crash-window reconcile re-fire writes nothing new.
        let again = try await ProceduralSkillProposal.applyResolved(
            record: resolved, dataRoot: root)
        #expect(again == .applied(skillName: skillName, bodyPath: bodyPath, bodyWritten: false))
    }

    @Test("rejection leaves no body and no pointer")
    func rejectionLeavesNoPointer() async throws {
        let root = makeRoot()
        let memory = try makeMemory()
        let lane = lane(root)
        for day in ["2026-08-30", "2026-08-30", "2026-08-31"] {
            _ = await lane.observe(
                steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: day)
        }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let card = try #require(try await pendingProposals(root).first)
        let resolved = try await inbox.resolve(
            card.id, decision: .denied, provenance: .local(decidedBy: "user"))

        let outcome = try await ProceduralSkillProposal.applyResolved(
            record: resolved, dataRoot: root)
        guard case .declined = outcome else {
            Issue.record("a denied card must decline, got \(outcome)")
            return
        }
        let bodiesDir = root.appendingPathComponent("skills/bodies", isDirectory: true)
        let bodies = (try? FileManager.default.contentsOfDirectory(atPath: bodiesDir.path)) ?? []
        #expect(bodies.isEmpty)
        _ = try await memory.syncSkillPointers(bodiesDirs: [bodiesDir])
        #expect(try await memory.listMemory(kind: "skill").isEmpty)
    }

    @Test("an unresolved card cannot write a body")
    func pendingCardCannotApply() async throws {
        let root = makeRoot()
        let lane = lane(root)
        for day in ["2026-08-30", "2026-08-30", "2026-08-31"] {
            _ = await lane.observe(
                steps: ProceduralEvidenceShaper.steps(from: readThenWrite), day: day)
        }
        let card = try #require(try await pendingProposals(root).first)
        await #expect(throws: ProceduralSkillProposalError.approvalNotApproved) {
            _ = try await ProceduralSkillProposal.applyResolved(record: card, dataRoot: root)
        }
    }

    @Test("a card whose preview no longer matches its body is refused")
    func tamperedCardIsRefused() async throws {
        let root = makeRoot()
        let steps = ProceduralEvidenceShaper.steps(from: readThenWrite)
        let procedure = ProceduralProcedureCompiler.compile(
            steps: steps, occurrenceCount: 3,
            observedDays: ["2026-08-30", "2026-08-31"], verifiedSuccessCount: 3
        )
        var tampered = ApprovalRecord(
            id: "approval-tampered",
            title: "t",
            action: ProceduralSkillProposal.approvalAction,
            risk: "low",
            reason: "r",
            status: "resolved",
            payload: ProceduralSkillProposal.binding(
                procedure: procedure, body: procedure.draftSkillBody()),
            payloadPreview: "# something the owner never read\n\nnot the body.\n",
            createdAt: "2026-09-01T00:00:00Z",
            resolvedAt: "2026-09-01T00:00:01Z",
            decision: "approved",
            remoteResolvable: false,
            localOnly: true
        )
        await #expect(throws: ProceduralSkillProposalError.approvalPayloadMismatch) {
            _ = try await ProceduralSkillProposal.applyResolved(record: tampered, dataRoot: root)
        }
        tampered.payloadPreview = procedure.draftSkillBody()
        tampered.remoteResolvable = true
        await #expect(throws: ProceduralSkillProposalError.approvalNotLocal) {
            _ = try await ProceduralSkillProposal.applyResolved(record: tampered, dataRoot: root)
        }
    }

    // MARK: The compiled shape

    @Test("the compiled procedure activates nothing and generates no code")
    func compiledProcedureIsInert() throws {
        let steps = ProceduralEvidenceShaper.steps(from: readThenWrite)
        let procedure = ProceduralProcedureCompiler.compile(
            steps: steps, occurrenceCount: 3,
            observedDays: ["2026-08-31", "2026-08-30", "2026-08-30"],
            verifiedSuccessCount: 3
        )
        #expect(procedure.schema == "procedural-lane-tool-sequence.v1")
        #expect(procedure.observedDays == ["2026-08-30", "2026-08-31"])
        #expect(procedure.distinctDayCount == 2)
        #expect(!procedure.safety.automaticActivationAllowed)
        #expect(!procedure.safety.permissionAuthority)
        #expect(!procedure.safety.externalSendsEligible)
        #expect(!procedure.generatedExecutableCode)
        #expect(procedure.transitionTable.count == 2)
        #expect(procedure.transitionTable.last?.terminalClass == .verifiedSuccess)
        // Same shape, same evidence ⇒ same digest (the dedupe key).
        let again = ProceduralProcedureCompiler.compile(
            steps: steps, occurrenceCount: 3,
            observedDays: ["2026-08-30", "2026-08-31"], verifiedSuccessCount: 3
        )
        #expect(again.id == procedure.id)
        #expect(again.sequenceIdentity == procedure.sequenceIdentity)
        // More evidence moves the artifact digest but never the sequence one,
        // which is what keeps "one proposal per n-gram" enforceable.
        let later = ProceduralProcedureCompiler.compile(
            steps: steps, occurrenceCount: 4,
            observedDays: ["2026-08-30", "2026-08-31"], verifiedSuccessCount: 4
        )
        #expect(later.id != procedure.id)
        #expect(later.sequenceIdentity == procedure.sequenceIdentity)
        #expect(CompiledToolProcedure(jsonValue: procedure.jsonValue) == procedure)
    }

    @Test("verified motor outcomes join the sequence; unverified ones do not")
    func motorStepsCountOnlyWhenVerified() async throws {
        let root = makeRoot()
        let lane = lane(root)
        let verified = ProceduralMotorStep(
            bundleID: "com.apple.Notes", verb: "act",
            targetRole: "AXButton", verification: "satisfied")
        let unverified = ProceduralMotorStep(
            bundleID: "com.apple.Notes", verb: "act",
            targetRole: "AXButton", verification: "unverified")
        #expect(verified.isVerified)
        #expect(!unverified.isVerified)

        var last: ProceduralLaneOutcome = .ignored
        for _ in 0..<3 {
            last = await lane.observeTurn(
                userMessage: "file that note",
                toolEvidence: [readThenWrite[0]],
                motorSteps: [verified, unverified],
                sessionId: "session-motor"
            )
        }
        // read_file + ONE verified motor step = a two-step sequence. The
        // unverified one contributed nothing.
        let entries = await lane.ledgerEntries()
        #expect(entries.count == 1)
        #expect(entries[0].steps.count == 2)
        #expect(entries[0].steps[1].action == "com.apple.Notes:act")
        #expect(entries[0].steps[1].origin == .motor)
        // Same day three times: the two-day floor still governs.
        if case .counted(_, let occurrences, let days) = last {
            #expect(occurrences == 3)
            #expect(days == 1)
        } else {
            Issue.record("three same-day runs must not mint, got \(last)")
        }
        #expect(try await pendingProposals(root).isEmpty)
    }
}
