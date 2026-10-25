import SwarmRuns
import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import CognitiveSubstrate
import Transcripts
// Blueprint: | `REMConsolidator.swift` | `REMConsolidator` actor; `runWeeklyREM` shares one checked diary window with distillation, filters a fresh tombstone batch and resolves committed causal refs for reflection; `rankedByRecurrence` |

// USER.md is owned by MemoryV2 and lives in the active persona root beside
// SOUL/VOICE/GROWTH. REM reads selected persona context, but approval
// proposals are GROWTH.md-only compact reflexes. No legacy
// `<dataRoot>/memory/USER.md` fallback exists.

// MARK: - REM consolidation constants
//
// Pinned by the vault note `nativeagent-rem-dream-cycle`. These match the
// the retired daemon design before its retirement:
//
//   minimumEvidenceCount = 2
//       A proposal needs two distinct supporting experiences OR dream dates
//       in the seven-day window. Two experiences on one date can qualify.
//
//   _REM_MAX_PROPOSALS = 5
//       GLOBAL cap per weekly pass (not per persona-doc). The cap is
//       enforced AFTER tombstone filtering so a wave of dupes can't crowd
//       out fresh proposals. Three docs × 5 = 15 was flooding the inbox;
//       the skill reads this as a global cap and so does the consolidator.
//
//   _REM_GROWTH_CHAR_CAP = 20_000
//       Soft cap on GROWTH.md BODY size in characters. the user pinned this on
//       2026-06-05 — GROWTH is injected on every chat turn, so an
//       unbounded doc burns prompt budget every turn. When exceeded, the
//       oldest entries (past the static preamble) are LLM-distilled into a
//       knowledge-graph node and removed from the doc to make room for new
//       growth. The skill previously named this `_GROWTH_MD_MAX_CHARS` at
//       30k in adaptive_memory_promotion.py; we tightened to 20k.
//
//   _REM_GROWTH_EVICT_CHARS = 5_000
//       When the cap fires, evict roughly this many characters of oldest
//       entries in one pass. Eviction always lands on a `## ` heading
//       boundary so we never split an entry mid-paragraph.
//
//   _REM_ARCHIVE_DAYS = 14
//       dream_diary entries older than this move into
//       <dataRoot>/dream_diary/archive/<YYYY>/ when REM runs.
public enum REMConstants {
    public static let minimumEvidenceCount: Int = 2
    public static let _REM_MAX_PROPOSALS: Int = 5
    public static let _REM_GROWTH_CHAR_CAP: Int = 20_000
    public static let _REM_GROWTH_EVICT_CHARS: Int = 5_000
    public static let _REM_ARCHIVE_DAYS: Int = 14
    // Per-proposal text cap. the user pinned subconscious-voice 2026-06-05,
    // then tightened the product rule on 2026-06-21:
    // proposals should read like the existing GROWTH reflexes (1–3 short
    // declarative sentences in her voice), not scene recaps or SOUL essays.
    // Anything over this gets clamped to the last lesson-bearing sentence.
    public static let _REM_PROPOSAL_TEXT_CAP: Int = 180
    /// Phase 5 C1: a lesson's "what surprised me / what changed" line.
    public static let whatChangedCap: Int = 200

    /// Canonical persona-doc targets REM is allowed to draft approval
    /// proposals against. REM may read SOUL/VOICE/USER/AGENTS as context,
    /// but proposed writes are GROWTH-only.
    public static let personaTargets: [String] = ["GROWTH.md"]
}

// MARK: - REMConsolidator (weekly cycle)

/// Weekly REM consolidation cycle. Distinct from the nightly Dream cycle:
/// Dream writes one dream_diary entry per day; REM reads 7 days of those
/// entries and distills cross-entry patterns into approval-gated proposals
/// against GROWTH.md only (NEVER USER.md — MemoryV2 owns that; SOUL/VOICE
/// are read-only context for this cycle).
///
/// Pipeline:
///   1. Trust gate (`rem_cycle_enabled`) — refuse if gated off.
///   2. Read last-7-day dream_diary entries.
///   3. Per persona-doc: LLM-distill with selected persona context into 1-3
///      proposals. Global cap _REM_MAX_PROPOSALS=5 across the week is
///      enforced at step 6 (NOT per-doc — see constants block).
///   4. Require minimumEvidenceCount=2 supporting experiences or dream dates.
///   5. Drop proposals whose fingerprint matches a tombstone.
///   6. Append surviving proposals to rem_proposals.jsonl with status='pending'
///      (canonical store, flock'd, id-deduped) and stage ONE approval record
///      per new row via the app-wired stager (stamped — no double-stage).
///   7. Emit rem_pins.json index (target → latest-3-APPROVED proposal ids).
///   8. GROWTH.md size-cap eviction → distill oldest 100 lines into KG.
///   9. 14-day disk archival of dream_diary entries.
public actor REMConsolidator {
    let dataRoot: URL
    let personaRoot: URL
    let llm: any LLMClient
    let router: any ProviderRoutingProtocol
    private let gate: DreamREMGatePolicy
    let clock: @Sendable () -> Date
    /// App-wired approval stager (ApprovalInbox record + inbox card). nil →
    /// proposals append but don't stage; the next stager-carrying pass picks
    /// up unstamped rows.
    private let stageApproval: REMApprovalStager?

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        personaRoot: URL,
        llm: any LLMClient,
        router: any ProviderRoutingProtocol = SwiftNativeProviderRouting(),
        gate: DreamREMGatePolicy = DreamREMGatePolicy(),
        clock: @escaping @Sendable () -> Date = { Date() },
        stageApproval: REMApprovalStager? = nil
    ) {
        self.dataRoot = dataRoot
        self.personaRoot = personaRoot
        self.llm = llm
        self.router = router
        self.gate = gate
        self.clock = clock
        self.stageApproval = stageApproval
    }

    // MARK: Public API

    public func runWeeklyREM(force: Bool = false) async throws -> REMReport {
        // The run ledger is the durable operator-facing surface for this
        // return-only report. Use wall clock for its duration while retaining
        // the injected clock below for REM's deterministic weekly semantics.
        let runStartedAt = Date()

        // (1) Trust gate.
        guard gate.remEnabled else {
            let error = DreamREMCycleError.cycleDisabled(
                error: "rem_cycle_disabled",
                detail: DreamREMGatePolicy.remDisabledDetail
            )
            await persistRunReport(
                outcome: .disabled,
                reason: "rem_cycle_disabled",
                error: error,
                startedAt: runStartedAt
            )
            throw error
        }

        let now = clock()

        // ONE REM AT A TIME (2026-09-06). The weekly marker below is a claim on
        // the WEEK; it is not a claim on the RUN. A forced manual pass bypasses
        // the freshness check entirely, so a "Run REM now" click landing beside
        // the scheduled job had both passes reading the same diary week,
        // calling the model, and appending two proposal sets under fresh
        // UUIDs — the store's id dedupe cannot see identical content as one
        // row. Same crash-safe `flock` shape the dream runner takes: a run that
        // cannot take the reservation exits having written nothing, and the
        // kernel releases a crashed run's lock.
        let harnessDir = dataRoot.appendingPathComponent("harness", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: harnessDir, withIntermediateDirectories: true)
        let runReservation: DreamRunReservation?
        do {
            runReservation = try DreamRunReservation.acquire(
                at: harnessDir.appendingPathComponent(".rem_run.lock"))
        } catch {
            await persistRunReport(
                outcome: .failed,
                reason: "rem_reservation_error",
                error: error,
                startedAt: runStartedAt
            )
            throw error
        }
        guard let runReservation else {
            FileHandle.standardError.write(Data(
                "REMConsolidator: another REM pass holds the run reservation — skipping\n".utf8
            ))
            let report = REMReport(
                proposalsGenerated: 0,
                evidenceDatesMin: REMConstants.minimumEvidenceCount,
                tombstoneSkips: 0, growthMDEvicted: 0, archivedEntries: 0,
                skipReason: "already_running"
            )
            await persistRunReport(
                outcome: .skipped,
                reason: "rem_already_running",
                report: report,
                startedAt: runStartedAt
            )
            return report
        }
        defer { runReservation.release() }

        // Only a reservation which this invocation acquired needs rollback.
        // Keeping it optional lets pre-reservation failures become durable run
        // records too, without manufacturing a marker mutation to undo.
        var rollback: (@Sendable () async -> Void)?
        do {
            // Cancelled-before-start (scheduler timeout/stop): commit nothing —
            // the legacy import below WRITES into the proposal store (review
            // finding 2026-07-01: it ran before any cancellation check).
            try Task.checkCancellation()

            // Tombstones are durable rejection state. Validate before importing,
            // claiming the weekly marker, calling the LLM, or writing proposals so
            // a corrupt denylist cannot be treated as empty and later overwritten.
            let tombStore = REMTombstoneStore(dataRoot: dataRoot)
            _ = try await tombStore.loadAll()

            // (1a) Canonical store open — first open in the pipeline triggers the
            // one-time legacy harness-file import (idempotent; NOT at app boot).
            // Import failure is non-fatal: the legacy file just waits for the
            // next pass.
            let store = REMProposalStore(dataRoot: dataRoot)
            // Validate eviction evidence before import, marker claims, or proposal
            // staging. A malformed log must not leave new rows/cards for a retry.
            let growthProposalRows = try store.loadAllStrictly()
            do {
                let imported = try await store.importLegacyHarnessFileIfNeeded()
                if imported > 0 {
                    FileHandle.standardError.write(Data(
                        "REMConsolidator: imported \(imported) legacy proposals\n".utf8
                    ))
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "REMConsolidator: legacy proposal import failed: \(error)\n".utf8
                ))
            }

        // (1b) Six-day exclusion claim shared by the weekly drivers, stamped
        // BEFORE distillation, not proof of completion. Failure releases it
        // only before proposals are durable; terminal outcomes live in the run
        // ledger. `force` bypasses freshness and still claims the window.
            let markerURL = dataRoot
                .appendingPathComponent("harness", isDirectory: true)
                .appendingPathComponent("last_weekly_rem_run")
        // Unique claim token = freshness timestamp + a per-run UUID (gpt-5.5
        // review). The timestamp drives the 6-day freshness check (parse the
        // FIRST whitespace token); the UUID makes the marker a unique claim id
        // so the failure rollback compare-and-restores EXACTLY our claim and
        // can never clobber a concurrent force-run that re-claimed in the same
        // second. The prior marker is captured UNDER the claim lock so the
        // rollback restores exactly what our claim overwrote. The shared
        // PersistenceCore reservation fails CLOSED on an unreadable marker,
        // lock failure, or stamp-write failure: weekly LLM work never runs
        // without first owning durable exclusion.
            let claimToken = "\(ISO8601DateFormatter().string(from: now)) \(UUID().uuidString)"
            let reservation = await reserveOncePerPeriod(at: markerURL, stamp: claimToken) { stored in
                if force { return false }
                guard let stored else { return false }
                guard let firstToken = stored.split(separator: " ", maxSplits: 1).first,
                      let priorRun = ISO8601DateFormatter().date(
                        from: String(firstToken).trimmingCharacters(in: .whitespacesAndNewlines)
                      ) else {
                    throw PersistenceCoreError.ioFailure(
                        "weekly REM marker is malformed: \(markerURL.path)"
                    )
                }
                return now.timeIntervalSince(priorRun) < 6 * 86_400
            }
            switch reservation {
        case .alreadyReserved:
            FileHandle.standardError.write(Data(
                "REMConsolidator: weekly REM already claimed within 6 days — skipping\n".utf8
            ))
            // Marker-skip still runs the staging catch-up: legacy-imported or
            // previously-unstaged pending rows must not wait a week for an
            // approval card.
            try await stagePendingUnstagedRows(store, resolver: ChatSessionRecollections.ExperienceResolver(dataRoot: dataRoot))
            let report = REMReport(
                proposalsGenerated: 0,
                evidenceDatesMin: REMConstants.minimumEvidenceCount,
                tombstoneSkips: 0, growthMDEvicted: 0, archivedEntries: 0,
                skipReason: "weekly_reservation_fresh"
            )
            await persistRunReport(
                outcome: .skipped,
                reason: "weekly_reservation_fresh",
                report: report,
                startedAt: runStartedAt
            )
            return report
        case .failed(let error):
            FileHandle.standardError.write(Data(
                "REMConsolidator: weekly reservation failed closed: \(error)\n".utf8
            ))
            throw error
        case .reserved(_, let restore):
            rollback = restore
        }

        // (2) Read the inclusive local-day window once for eligibility and LLM input.
        let since = DreamDiaryReader.startOfLocalDay(now, daysBefore: 7)
        let entries = try await DreamDiaryReader(dataRoot: dataRoot).entriesSince(since)
        let sourceRefs = Set(entries.flatMap { $0.content.map { DreamEntryProvenance.sources(in: $0) } ?? [] })
        let resolver = ChatSessionRecollections.ExperienceResolver(dataRoot: dataRoot)
        let resolved = try await resolver.resolve(for: Array(sourceRefs), includingSourceRows: true)
        let identities = resolved.identities
        var reflectionMaterial = try await DreamEntryProvenance.resolveSources(sourceRefs, dataRoot: dataRoot,
            messages: resolved.messages)
        for entry in entries {
            if let content = entry.content {
                let sources = DreamEntryProvenance.sources(in: content)
                var cause = CognitiveReflectionCause(text: content,
                    sources: sources, material: reflectionMaterial)
                cause.sourcePeerIds = CognitiveReflectionCause.unionPeerIds([DreamEntryProvenance.peerIds(in: content)]
                    + sources.map { reflectionMaterial[$0]?.sourcePeerIds })
                reflectionMaterial["dream_diary/\(entry.filename ?? "\(entry.date).md")"] = cause
            }
        }
        // Every diary read by REM contributes to its conclusions' trust, cited or not.
        let sourcePeers = CognitiveReflectionCause.unionPeerIds(entries.map {
            reflectionMaterial["dream_diary/\($0.filename ?? "\($0.date).md")"]?.sourcePeerIds
        })

        // (3) Distill with selected persona context. Proposals target GROWTH.md
        // only; USER.md remains MemoryV2-owned. The rem surface owns routing.
        let helper = SwiftNativeREMConsolidator(llm: llm)
        let personaDocs = try readPersonaDocs()
        let contextDocs = try await readDreamPersonaDocs(
            dataRoot: dataRoot, personaRoot: personaRoot, surface: "rem"
        )
        let pickedModel = await router.modelStringForSurface("rem")
        let bypassSystem = Self.remBypassSystemPrompt(contextDocs: contextDocs)
        var rawProposals: [REMProposal] = []
        if !entries.isEmpty {
            rawProposals = try await PrivateWorkContextAssembly.$current.withValue(.suppliedPersona) {
                try await helper.consolidate(
                    entries: entries,
                    personaDocs: personaDocs,
                    identities: identities,
                    system: bypassSystem,
                    model: pickedModel,
                    surface: "rem",
                    systemPersonaDocs: contextDocs
                )
            }
            // FAIL LOUD (2026-07-03 repair): the helper's drop diagnostics
            // were write-only — the 2026-06-28 pass burned a real Opus call,
            // kept zero proposals, and reported proposals=0 with no cause
            // anywhere. Surface every drop reason at the choke point so a
            // silent-zero week can never happen again.
            let parseErrors = await helper.lastParseErrors
            let evidenceDrops = await helper.lastEvidenceDateDrops
            let targetDrops = await helper.lastTargetMismatchDrops
            // A quote that isn't in the entry it names is not a passage — the
            // same verbatim rule the studio journal amendment takes. Counted
            // here so a model that paraphrases its evidence is visible.
            let passageDrops = await helper.lastPassageDrops
            if !parseErrors.isEmpty || evidenceDrops > 0 || targetDrops > 0 || passageDrops > 0 {
                let msg = "REMConsolidator: distill drops — parseErrors=\(parseErrors.count) "
                    + "evidenceDateDrops=\(evidenceDrops) targetMismatchDrops=\(targetDrops) "
                    + "unverifiedPassageDrops=\(passageDrops) "
                    + "(kept \(rawProposals.count) of the LLM's output)\n"
                    + parseErrors.map { "  parse: \($0)\n" }.joined()
                FileHandle.standardError.write(Data(msg.utf8))
            }
            if rawProposals.isEmpty {
                let zeroMsg = "REMConsolidator: LLM distillation yielded ZERO usable proposals over "
                    + "\(entries.count) diary entries — check the drops above; an empty week "
                    + "should be the model returning [], not a parse casualty.\n"
                FileHandle.standardError.write(Data(zeroMsg.utf8))
            }
            // 2026-09-06: A REPLY THAT DID NOT DECODE IS A FAILED RUN, not a
            // quiet week. The parse casualty above used to fall straight
            // through to `.completed` with proposalsGenerated=0: the weekly
            // claim stayed stamped, the scheduler reported a finished pass,
            // and a real week of dreams was silently discarded until the next
            // Sunday. Throwing here unwinds to the marker rollback, so the
            // claim is released and the next tick retries the distillation.
            let decodeFailures = await helper.lastDecodeFailures
            if decodeFailures > 0 {
                throw DreamREMCycleError.remDecodeFailure(
                    "REM distillation could not decode the model's reply "
                    + "(\(decodeFailures) failure(s)): "
                    + parseErrors.joined(separator: "; ")
                )
            }
        }

        // (4) Evidence floor — distinct supporting experiences or dream dates.
        // The dream-date floor is retained so entries
        // written before provenance existed still reach the inbox instead of
        // vanishing for a fortnight. What changed is that clearing the floor on
        // dream dates alone no longer LOOKS like recurrence: `support` says
        // whether it recurred, was dwelt on, or is simply not knowable.
        var passEvidence: [REMProposal] = []
        for p in rawProposals {
            let floor = max(p.supportingExperienceCount(identities: identities) ?? 0, p.dreamDateCount)
            if floor >= REMConstants.minimumEvidenceCount {
                passEvidence.append(p)
            }
        }

        // (5) Tombstone filter.
        let passTomb = try await tombStore.filterTombstoned(passEvidence)
        let tombSkips = passEvidence.count - passTomb.count

        // (6) Global cap (_REM_MAX_PROPOSALS). The skill reads this as a
        // weekly-pass cap, NOT per-doc. Per-doc allowed up to 15/week and
        // floods the approvals inbox.
        //
        // RANK BEFORE THE CAP (item 4). The five survivors used to be whichever
        // five the model happened to emit first — emission order is not
        // evidence. They are now ordered by INDEPENDENTLY SUPPORTED RECURRENCE
        // (distinct lived dates, descending), with emission order as the
        // tiebreak so the ordering stays total and deterministic.
        let kept = Self.rankedByRecurrence(passTomb, identities: identities)

        // A timed-out scheduler body is cancel()ed and abandoned; the LLM
        // distillation above honors cancellation, but a body that already got
        // its response could still fall through to commit these persona-mutating
        // artifacts. Check cancellation before each commit. Only failures before
        // proposal persistence release the weekly reservation; later ticks stage
        // any remaining approval cards from the existing proposal rows.

        // (7) Append to rem_proposals.jsonl as status='pending' through the
        // shared canonical appender (flock'd, id-deduped).
        try Task.checkCancellation()
        // The append REFUSES non-GROWTH targets (persona docs are the owner's).
        // Its receipt carries what it refused, by doc name, so the drop reaches
        // the run report instead of dying inside the store (fable51 #11).
        let appendReceipt = try await store.appendPendingWithReceipt(kept)
        // Once proposals are durable, retries must use their existing IDs.
        if appendReceipt.appended > 0 { rollback = nil }

        // (7b) Stage ONE approval record per newly-appended pending proposal.
        // Staging stamps each row with the approval id, so a re-run can't
        // double-stage. A failed stage stays owed under the same proposal IDs.
        try Task.checkCancellation()
        var stagingFailure: (any Error)?
        do { try await stagePendingUnstagedRows(store, resolver: resolver) }
        catch { stagingFailure = error }

        // (8) GROWTH.md size-cap eviction → KG.
        try Task.checkCancellation()
        let evicted = try await runGrowthEviction(proposalRows: growthProposalRows)

        // (9) Publish only the approved passages that survived eviction.
        try emitREMPinsIndex()

        // (10) 14-day disk archival.
        try Task.checkCancellation()
        let moved = try await archiveDreams()
        if let stagingFailure { throw stagingFailure }

        let dweltOnKept = kept.filter { $0.support == .dweltOn }.count
        let unavailableKept = kept.filter { $0.support == .provenanceUnavailable }.count
        var report = REMReport(
            proposalsGenerated: kept.count,
            evidenceDatesMin: REMConstants.minimumEvidenceCount,
            tombstoneSkips: tombSkips,
            growthMDEvicted: evicted,
            archivedEntries: moved,
            personaTargetDrops: appendReceipt.droppedByTarget.isEmpty
                ? nil : appendReceipt.droppedByTarget,
            passageBoundDrops: appendReceipt.droppedOverBound.isEmpty
                ? nil : appendReceipt.droppedOverBound,
            // How many of the week's survivors are NOT recurrence. A run
            // report that says "5 proposals" while three of them are one
            // Tuesday dreamt three times is a report that lies by omission.
            dweltOnKept: dweltOnKept == 0 ? nil : dweltOnKept,
            provenanceUnavailableKept: unavailableKept == 0 ? nil : unavailableKept
        )
        let keptIds = Set(kept.map(\.id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let committed = try await store.loadAllStrictly().filter { keptIds.contains($0.id) }
        report.reflectionMaterial = committed.isEmpty ? [:] : reflectionMaterial
        for row in committed {
            let sources = (row.supportingPassages ?? []).flatMap { passage in
                passage.sourceRefs + entries.filter { $0.date == passage.dreamDate }
                    .map { "dream_diary/\($0.filename ?? "\($0.date).md")" }
            }
            var cause = CognitiveReflectionCause(
                text: String(decoding: try encoder.encode(row), as: UTF8.self),
                sources: sources, material: report.reflectionMaterial)
            cause.sourcePeerIds = sourcePeers
            report.reflectionMaterial["rem_proposal:\(row.id)"] = cause
        }
        await persistRunReport(
            outcome: .completed,
            reason: nil,
            report: report,
            startedAt: runStartedAt
        )
        return report
        } catch {
            if let rollback {
                await rollback()
            }
            FileHandle.standardError.write(Data("REMConsolidator: run failed: \(error)\n".utf8))
            await persistRunReport(
                outcome: .failed,
                reason: Self.runFailureReason(error),
                error: error,
                startedAt: runStartedAt
            )
            throw error
        }
    }

    /// The week's survivors, ordered by independently supported recurrence and
    /// cut to `_REM_MAX_PROPOSALS`.
    ///
    /// Agent's binding constraint (2026-09-13): a thing dwelt on must NEVER
    /// sneak in as a pattern, and must NEVER vanish. Ordering by experiences
    /// puts every genuinely recurring candidate above every dwelt-on one, which
    /// covers the first half. The reserved slot below covers the second: when a
    /// week is full of real recurrence, the dwelt-on candidate still reaches the
    /// inbox — labelled `dwelt_on`, with its passages bound — so she can approve
    /// it deliberately or not at all, rather than never being asked.
    nonisolated static func rankedByRecurrence(_ proposals: [REMProposal], identities: [String: String]) -> [REMProposal] {
        let cap = REMConstants._REM_MAX_PROPOSALS
        guard proposals.count > cap else { return proposals }
        var counts: [Int: Int] = [:]
        for (index, proposal) in proposals.enumerated() {
            counts[index] = proposal.supportingExperienceCount(identities: identities) ?? 0
        }
        let ordered = proposals.enumerated().sorted { lhs, rhs in
            let l = counts[lhs.offset]!
            let r = counts[rhs.offset]!
            if l != r { return l > r }
            return lhs.offset < rhs.offset     // emission order, last
        }.map(\.element)

        var kept = Array(ordered.prefix(cap))
        let dwelt = ordered.filter { $0.support == .dweltOn }
        if !dwelt.isEmpty, !kept.contains(where: { $0.support == .dweltOn }),
           let first = dwelt.first {
            kept.removeLast()
            kept.append(first)
        }
        return kept
    }

    /// The cross-surface run ledger already supplies atomic, locked, bounded
    /// retention (500 rows) and survives process reload. REM writes only this
    /// compact summary so a scheduler run that makes no proposals cannot be
    /// mistaken for a scheduler run that never happened.
    private func persistRunReport(
        outcome: REMRunReportPayload.Outcome,
        reason: String? = nil,
        report: REMReport? = nil,
        error: (any Error)? = nil,
        startedAt: Date
    ) async {
        let payload = REMRunReportPayload(
            outcome: outcome,
            reason: reason,
            report: report
        )
        let output: String
        if let data = try? JSONEncoder().encode(payload),
           let encoded = String(data: data, encoding: .utf8) {
            output = encoded
        } else {
            // The payload contains only Codable scalar values, but retain an
            // honest sentinel if a future schema change breaks encoding.
            output = "{\"schemaVersion\":\"rem.run_report.v1\",\"outcome\":\"failed\",\"reason\":\"report_encoding_failed\"}"
        }
        await RunLedger.append(
            kind: "rem_weekly_consolidation",
            status: outcome.rawValue,
            output: output,
            error: error.map { String(describing: $0) },
            createdAt: startedAt,
            durationSeconds: max(0, Date().timeIntervalSince(startedAt)),
            dataRoot: dataRoot
        )
    }

    private nonisolated static func runFailureReason(_ error: any Error) -> String {
        if case DreamREMCycleError.cycleDisabled(let code, _) = error {
            return code
        }
        if error is CancellationError {
            return "cancelled"
        }
        return "execution_failed"
    }

    // MARK: Persona doc read

    /// Load the persona-doc bodies REM may draft against. REM proposals are
    /// GROWTH.md-only; SOUL/VOICE are present in the private system prompt as
    /// read-only context.
    private func readPersonaDocs() throws -> [String: String] {
        var out: [String: String] = [:]
        for name in REMConstants.personaTargets {
            let url = personaRoot.appendingPathComponent(name)
            let raw = FileManager.default.fileExists(atPath: url.path)
                ? try String(contentsOf: url, encoding: .utf8) : ""
            out[name] = (name == "GROWTH.md")
                ? SwiftNativePersonaEngine.filterEpisodicGrowthLines(raw)
                : raw
        }
        return out
    }

    /// Private REM reflection with selected persona documents and USER context.
    fileprivate static func remBypassSystemPrompt(
        contextDocs: [String: String]
    ) -> String {
        func body(_ name: String) -> String {
            let raw = contextDocs[name] ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(empty)" : raw
        }
        return """
        Reflect privately on the past week's dreams as yourself, with the same \
        identity, voice and boundaries as in conversation. Propose only earned \
        GROWTH.md updates for approval; this is not a message to the person.

        Below are the selected SOUL, VOICE, GROWTH and AGENTS documents and \
        the USER context selected for this pass. Keep proposals coherent with \
        this context.

        --- SOUL.md ---
        \(body("SOUL.md"))

        --- VOICE.md ---
        \(body("VOICE.md"))

        --- GROWTH.md ---
        \(body("GROWTH.md"))

        --- USER.md ---
        \(body("USER.md"))

        --- AGENTS.md ---
        \(body("AGENTS.md"))
        """
    }

    // MARK: rem_proposals.jsonl

    /// Repair committed REM work without generating another proposal set.
    public func repairPendingWork() async throws -> Int {
        guard gate.remEnabled else {
            throw DreamREMCycleError.cycleDisabled(error: "rem_cycle_disabled", detail: DreamREMGatePolicy.remDisabledDetail)
        }
        let directory = dataRoot.appendingPathComponent("harness", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let reservation = try DreamRunReservation.acquire(at: directory.appendingPathComponent(".rem_run.lock")) else {
            throw ToolFailureError("REM is still running; its repair remains owed until the current pass ends.", effects: .none)
        }
        defer { reservation.release() }
        try await stagePendingUnstagedRows(REMProposalStore(dataRoot: dataRoot),
            resolver: ChatSessionRecollections.ExperienceResolver(dataRoot: dataRoot))
        return try await archiveDreams()
    }

    private func archiveDreams() async throws -> Int {
        do {
            let moved = try await DreamArchiver(dataRoot: dataRoot).archiveOlderThan(
                daysOld: REMConstants._REM_ARCHIVE_DAYS, now: clock())
            await RepairOwed.settle(dataRoot, operation: "rem.archive",
                evidence: .init(source: "dream_diary/archive", id: NativeTimestampFormat.fractionalZulu(clock()))).value
            return moved
        } catch {
            await RepairOwed.owe(dataRoot, id: "rem-archive-repair:" + UUID().uuidString, kind: .run,
                operation: "rem.archive", owner: "dream_diary archival",
                words: "REM archival failed: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("mind.rem"), "args": .object(["repair": .bool(true)])])).value
            throw error
        }
    }

    private func stagePendingUnstagedRows(_ store: REMProposalStore, resolver: ChatSessionRecollections.ExperienceResolver) async throws {
        try await store.stagePendingApprovals({ [stageApproval] row, experiences in
            try Task.checkCancellation()
            guard let stageApproval else {
                throw ToolFailureError("REM approval staging has no connected owner.", effects: .none)
            }
            return try await stageApproval(row, experiences)
        }, resolver: resolver)
    }

    // MARK: rem_pins.json (latest-3-approved index)

    /// Re-derive the persona_doc → [latest-3-approved-proposal-ids] index
    /// from the JSONL log. APPROVED entries have status="approved". The
    /// jsonl is the source of truth — pins.json is a derived cache that
    /// REM rebuilds every run.
    private func emitREMPinsIndex() throws {
        try REMConsolidator.emitREMPinsIndex(dataRoot: dataRoot)
    }

    /// Public, instance-free rebuild of `<dataRoot>/rem_pins.json` from the
    /// `<dataRoot>/rem_proposals.jsonl` log. Used by REMCycleLoop's legacy
    /// (non-full-pipeline) path so the chat-turn injector always sees a
    /// fresh pins index after a tick — the full pipeline path already runs
    /// this internally after GROWTH eviction.
    public static func emitREMPinsIndex(dataRoot: URL) throws {
        // Share the proposal owner's flock across the complete derivation.
        // An older rebuild cannot publish over pins from a newer approval.
        try CredentialFileLock.withLock(dataRoot.appendingPathComponent("rem_proposals.jsonl")) {
            try emitREMPinsIndexLocked(dataRoot: dataRoot)
        }
    }

    private static func emitREMPinsIndexLocked(dataRoot: URL) throws {
        let pinsURL = dataRoot.appendingPathComponent("rem_pins.json")
        // P-L3: read through the store so APPROVED rows folded into the
        // compaction base are still seen — a raw feed read would miss them and
        // silently drop long-approved pins after a compaction.
        let rows = REMProposalStore(dataRoot: dataRoot).loadAll()
        // APPROVED rows only — pending/denied must never leak into the
        // chat-turn injection.
        let approved = rows.filter {
            $0.status == "approved" && REMProposalStore.supportsProposalTarget($0.targetDoc)
        }
        // RECONCILE AGAINST THE LIVE DOCUMENT (2026-09-06). An approved row is
        // a historical fact and stays one; a PIN is a live instruction that
        // rides into every chat turn. Removing or correcting a lesson in
        // GROWTH.md left the old text pinned forever — the approval log still
        // said approved, so the injector kept feeding the retracted wording.
        // A pin now survives only while its lesson is still an entry in the
        // document it was approved into.
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        var out: [String: [REMPin]] = [:]
        if !approved.isEmpty {
            let doc = "GROWTH.md"
            let document: String?
            // An absent document retires pins; an unreadable one preserves
            // them until its authority can be checked again.
            let url = personaRoot.appendingPathComponent(doc)
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    document = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    document = nil
                    FileHandle.standardError.write(Data(
                        "REMConsolidator: \(doc) unreadable (\(error)); keeping its pins\n".utf8
                    ))
                }
            } else {
                document = ""
                FileHandle.standardError.write(Data(
                    "REMConsolidator: \(doc) is absent; retiring its pins\n".utf8
                ))
            }
            let live = approved.filter { Self.pinIsLive($0.proposalText, inDocument: document) }
            let sorted = live.sorted { $0.createdAt > $1.createdAt }.prefix(3)
            out[doc] = sorted.map { REMPin(id: $0.id, text: $0.proposalText, createdAt: $0.createdAt) }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(out)
        try data.write(to: pinsURL, options: .atomic)
    }

    /// True when an approved lesson is still present in `document` as its own
    /// entry paragraph — the same standalone-entry test the writer uses to
    /// decide it has already been appended (2026-09-06). `nil` document (the
    /// file exists but could not be read) keeps the pin; an ABSENT document is
    /// passed as an empty body by the caller, so its pins retire.
    static func pinIsLive(_ text: String, inDocument document: String?) -> Bool {
        guard let document else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return REMGrowthWriter.containsEntryParagraph(document, trimmed)
    }


}
