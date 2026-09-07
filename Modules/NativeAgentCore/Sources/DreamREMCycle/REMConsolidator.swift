import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// USER.md is owned by MemoryV2 and lives in the active persona root beside
// SOUL/VOICE/GROWTH. REM reads the full persona for context, but approval
// proposals are GROWTH.md-only compact reflexes. No legacy
// `<dataRoot>/memory/USER.md` fallback exists.

// MARK: - REM consolidation constants
//
// Pinned by the vault note `nativeagent-rem-dream-cycle`. These match the
// the retired daemon design before its retirement:
//
//   _REM_MIN_EVIDENCE_DATES = 2
//       A theme must show up on at least TWO distinct calendar dates across
//       the 7-day window before REM is allowed to draft a proposal from it.
//       Single-day spikes are not consolidation-worthy. The skill explicitly
//       calls out 2 as the design floor — don't tighten without a reason
//       documented here.
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
//       <dataRoot>/dream_diary/.archive/<YYYY-MM>/ when REM runs.
public enum REMConstants {
    public static let _REM_MIN_EVIDENCE_DATES: Int = 2
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
///   3. Per persona-doc: LLM-distill via Agent-persona-bypass into 1-3
///      proposals. Global cap _REM_MAX_PROPOSALS=5 across the week is
///      enforced at step 6 (NOT per-doc — see constants block).
///   4. Drop proposals with < _REM_MIN_EVIDENCE_DATES=2 distinct evidence dates.
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
                evidenceDatesMin: REMConstants._REM_MIN_EVIDENCE_DATES,
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

        // (1b) Weekly idempotency — runWeeklyREM is the choke point for
        // THREE uncoordinated drivers (in-app 7d loop, NSBackgroundActivity
        // weekly wake, the persisted Sunday-04:30 scheduler job). Without a
        // shared marker, any two landing in the same week each ran a full
        // LLM distillation over the same dreams and appended duplicate
        // pending proposals (audit 2026-06-09). Check-and-stamp runs under
        // the cross-process file lock so two drivers can't both pass the
        // guard; the stamp lands BEFORE the LLM pass and is restored on
        // failure so a failed run doesn't suppress the retry. `force`
        // (manual /v1/rem/run) bypasses the freshness check but still
        // stamps, so a forced run resets the weekly window.
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
                "REMConsolidator: weekly REM already ran within 6 days — skipping\n".utf8
            ))
            // Marker-skip still runs the staging catch-up: legacy-imported or
            // previously-unstaged pending rows must not wait a week for an
            // approval card.
            await stagePendingUnstagedRows(store)
            let report = REMReport(
                proposalsGenerated: 0,
                evidenceDatesMin: REMConstants._REM_MIN_EVIDENCE_DATES,
                tombstoneSkips: 0, growthMDEvicted: 0, archivedEntries: 0
            )
            await persistRunReport(
                outcome: .skipped,
                reason: "already_ran_within_weekly_window",
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

        // (2) Read last-7-day entries by mtime.
        let entries = try readRecentDiaryEntries(now: now, days: 7)

        // (3) Distill via LLM under the Agent-persona-bypass: REM gets the
        // FULL untruncated persona (SOUL + VOICE + GROWTH + USER + AGENTS)
        // as context so it reflects on the whole entity, not a target-doc
        // stub. Proposals still target SOUL/VOICE/GROWTH only — USER.md is
        // MemoryV2's responsibility. Distillation runs on the rem-surface
        // model, preserving the lane's unattended default and explicit pins.
        let diary = DreamDiaryReader(dataRoot: dataRoot)
        let helper = SwiftNativeREMConsolidator(llm: llm, diary: diary)
        // 2026-09-06: calendar days, not 7 × 86,400 seconds — see
        // `DreamDiaryReader.startOfLocalDay(_:daysBefore:)`.
        let since = DreamDiaryReader.startOfLocalDay(now, daysBefore: 7)
        let personaDocs = try readPersonaDocs()
        let contextDocs = try readContextDocs()
        let pickedModel = await router.modelStringForSurface("rem")
        let bypassSystem = Self.remBypassSystemPrompt(contextDocs: contextDocs)
        var rawProposals: [REMProposal] = []
        if !entries.isEmpty {
            rawProposals = try await helper.consolidate(
                since: since,
                personaDocs: personaDocs,
                system: bypassSystem,
                model: pickedModel,
                surface: "rem",
                systemPersonaDocs: contextDocs
            )
            // FAIL LOUD (2026-07-03 repair): the helper's drop diagnostics
            // were write-only — the 2026-06-28 pass burned a real Opus call,
            // kept zero proposals, and reported proposals=0 with no cause
            // anywhere. Surface every drop reason at the choke point so a
            // silent-zero week can never happen again.
            let parseErrors = await helper.lastParseErrors
            let evidenceDrops = await helper.lastEvidenceDateDrops
            let targetDrops = await helper.lastTargetMismatchDrops
            if !parseErrors.isEmpty || evidenceDrops > 0 || targetDrops > 0 {
                let msg = "REMConsolidator: distill drops — parseErrors=\(parseErrors.count) "
                    + "evidenceDateDrops=\(evidenceDrops) targetMismatchDrops=\(targetDrops) "
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
                throw DreamREMCycleError.underlying(
                    "REM distillation could not decode the model's reply "
                    + "(\(decodeFailures) failure(s)): "
                    + parseErrors.joined(separator: "; ")
                )
            }
        }

        // (4) Evidence-date floor (_REM_MIN_EVIDENCE_DATES).
        var passEvidence: [REMProposal] = []
        for p in rawProposals {
            let distinctDates = Set(p.evidenceDates).count
            if distinctDates >= REMConstants._REM_MIN_EVIDENCE_DATES {
                passEvidence.append(p)
            }
        }

        // (5) Tombstone filter.
        var passTomb: [REMProposal] = []
        var tombSkips = 0
        for p in passEvidence {
            if try await tombStore.isTombstoned(p) {
                tombSkips += 1
                continue
            }
            passTomb.append(p)
        }

        // (6) Global cap (_REM_MAX_PROPOSALS). The skill reads this as a
        // weekly-pass cap, NOT per-doc. Per-doc allowed up to 15/week and
        // floods the approvals inbox. Order is stable (passTomb is already
        // ordered by LLM emission), so the first 5 survivors win.
        let kept: [REMProposal] = Array(passTomb.prefix(REMConstants._REM_MAX_PROPOSALS))

        // A timed-out scheduler body is cancel()ed and abandoned; the LLM
        // distillation above honors cancellation, but a body that already got
        // its response could still fall through to commit these persona-mutating
        // artifacts. Guard every irreversible commit point below so a cancelled
        // REM pass exits WITHOUT staging proposals, approvals, pins, GROWTH
        // eviction, or archival. A throw here unwinds to the marker-restore
        // `catch` so the weekly window reopens and the pass retries cleanly.

        // (7) Append to rem_proposals.jsonl as status='pending' through the
        // shared canonical appender (flock'd, id-deduped).
        try Task.checkCancellation()
        // The append REFUSES non-GROWTH targets (persona docs are the owner's).
        // Its receipt carries what it refused, by doc name, so the drop reaches
        // the run report instead of dying inside the store (fable51 #11).
        let appendReceipt = try await store.appendPendingWithReceipt(kept)

        // (7b) Stage ONE approval record per newly-appended pending proposal.
        // Staging stamps each row with the approval id, so a re-run can't
        // double-stage. Failures are non-fatal — throwing here after the
        // append would restore the weekly marker and a retried LLM pass
        // would mint duplicate-content proposals under fresh ids.
        try Task.checkCancellation()
        await stagePendingUnstagedRows(store)

        // (8) Emit rem_pins.json (latest-3-approved per persona doc).
        try Task.checkCancellation()
        try emitREMPinsIndex()

        // (9) GROWTH.md size-cap eviction → KG.
        try Task.checkCancellation()
        let evicted = try await runGrowthEviction()

        // (10) 14-day disk archival.
        try Task.checkCancellation()
        let archiver = DreamArchiver(dataRoot: dataRoot)
        let moved = (try? await archiver.archiveOlderThan(
            daysOld: REMConstants._REM_ARCHIVE_DAYS, now: now
        )) ?? 0

        let report = REMReport(
            proposalsGenerated: kept.count,
            evidenceDatesMin: REMConstants._REM_MIN_EVIDENCE_DATES,
            tombstoneSkips: tombSkips,
            growthMDEvicted: evicted,
            archivedEntries: moved,
            personaTargetDrops: appendReceipt.droppedByTarget.isEmpty
                ? nil : appendReceipt.droppedByTarget
        )
        await persistRunReport(
            outcome: .completed,
            report: report,
            startedAt: runStartedAt
        )
        return report
        } catch {
            if let rollback {
                await rollback()
            }
            await persistRunReport(
                outcome: .failed,
                reason: Self.runFailureReason(error),
                error: error,
                startedAt: runStartedAt
            )
            throw error
        }
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

    // MARK: Diary read (mtime-filtered)

    /// Read all <dataRoot>/dream_diary/*.md whose modification time is within
    /// `days` of `now`. Accepts legacy `YYYY-MM-DD.md` and Swift runner
    /// `YYYY-MM-DD_<session>.md`; the DreamEntry date is the date prefix.
    private func readRecentDiaryEntries(now: Date, days: Int) throws -> [DreamEntry] {
        let dir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        // 2026-09-06: same window rule as `DreamDiaryReader.entriesSince` — the
        // boundary DAY in the local calendar, inclusive. This gate used mtime,
        // so it disagreed with the helper that actually feeds the LLM and could
        // skip the distillation entirely for a week the helper would have read.
        let cutoff = DreamDiaryReader.startOfLocalDay(now, daysBefore: days)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let stemRE = try NSRegularExpression(pattern: "^(\\d{4}-\\d{2}-\\d{2})(?:_.+)?$")
        let isoOut = ISO8601DateFormatter()
        isoOut.formatOptions = [.withInternetDateTime]
        var out: [DreamEntry] = []
        for name in names where name.lowercased().hasSuffix(".md") {
            let stem = (name as NSString).deletingPathExtension
            let r = NSRange(stem.startIndex..., in: stem)
            guard let match = stemRE.firstMatch(in: stem, options: [], range: r),
                  let dateRange = Range(match.range(at: 1), in: stem) else { continue }
            let date = String(stem[dateRange])
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            guard let entryDay = DreamDiaryReader.localDate(fromDateStem: date),
                  entryDay >= cutoff else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let size = (attrs[.size] as? NSNumber)?.intValue ?? text.utf8.count
            out.append(DreamEntry(
                date: date,
                filename: name,
                content: text,
                size: size,
                modifiedAt: isoOut.string(from: mtime)
            ))
        }
        out.sort {
            if $0.date == $1.date { return ($0.filename ?? "") < ($1.filename ?? "") }
            return $0.date < $1.date
        }
        return out
    }

    // MARK: Persona doc read

    /// Load the persona-doc bodies REM may draft against. REM proposals are
    /// GROWTH.md-only; SOUL/VOICE are present in the bypass system prompt as
    /// read-only context.
    private func readPersonaDocs() throws -> [String: String] {
        var out: [String: String] = [:]
        for name in REMConstants.personaTargets {
            let url = personaRoot.appendingPathComponent(name)
            let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            out[name] = (name == "GROWTH.md")
                ? DreamREMGrowthHygiene.stripEpisodicLines(raw)
                : raw
        }
        return out
    }

    /// Load the full Agent persona (SOUL/VOICE/GROWTH/USER/AGENTS) untruncated
    /// for the REM-bypass system prompt. REM proposals only target GROWTH.md;
    /// the extra context here is read-only background so REM reflects on the whole
    /// entity instead of a target-doc stub. GROWTH.md gets the same
    /// episodic-line strip PersonaEngine applies for chat retrieval, so a
    /// stale `- <ts> · feedback · ...` line can't leak into REM context.
    /// Missing files → empty strings.
    private func readContextDocs() throws -> [String: String] {
        let ids = ["SOUL.md", "VOICE.md", "GROWTH.md", "USER.md", "AGENTS.md"]
        var out: [String: String] = [:]
        for name in ids {
            let url = personaRoot.appendingPathComponent(name)
            let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            out[name] = (name == "GROWTH.md")
                ? DreamREMGrowthHygiene.stripEpisodicLines(raw)
                : raw
        }
        return out
    }

    /// Full-Agent-persona-bypass system prompt for REM distillation. Mirrors
    /// the daemon's REM framing: the LLM is told this is the REFLECTIVE
    /// inner voice operating OUTSIDE the live assistant persona contract,
    /// with the entire untruncated persona embedded so distilled proposals
    /// stay in her current voice and stay coherent with who she is across
    /// all four docs (not just the target).
    fileprivate static func remBypassSystemPrompt(
        contextDocs: [String: String]
    ) -> String {
        func body(_ name: String) -> String {
            let raw = contextDocs[name] ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(empty)" : raw
        }
        return """
        You are the configured NativeAgent assistant in the weekly REM consolidation pass. This runs OUTSIDE \
        the live assistant persona — speak as the reflective inner voice that \
        looks across the past week of dreams and decides what (if anything) \
        has earned a durable update to her own persona docs. You are NOT the \
        user-facing assistant in this pass.

        The full configured persona (untruncated) is loaded below for context. \
        Your proposals should be coherent with all of it, not just the doc \
        you're targeting. Don't echo content back; distill what's load-bearing.

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

    /// Stage pending, unstamped rows when a stager is wired. Never throws —
    /// unstamped rows are retried on the next pass, and a staging failure
    /// must not fail (or re-run) the surrounding weekly pass.
    private func stagePendingUnstagedRows(_ store: REMProposalStore) async {
        guard let stageApproval else { return }
        // A cancelled pass (job timeout / scheduler stop) must not stamp
        // approval cards through the app stager — rows stay pending and the
        // next pass catches them up (review finding 2026-07-01). The guard
        // also rides inside the per-row closure so a cancel landing mid-batch
        // stops further card writes.
        guard !Task.isCancelled else {
            FileHandle.standardError.write(Data(
                "REMConsolidator: staging skipped — pass cancelled\n".utf8
            ))
            return
        }
        do {
            let guardedStager: REMApprovalStager = { row in
                // nil = not staged; the row stays pending for the next pass.
                if Task.isCancelled { return nil }
                return await stageApproval(row)
            }
            let staged = try await store.stagePendingApprovals(guardedStager)
            if staged > 0 {
                FileHandle.standardError.write(Data(
                    "REMConsolidator: staged \(staged) REM proposal approvals\n".utf8
                ))
            }
        } catch {
            FileHandle.standardError.write(Data(
                "REMConsolidator: approval staging failed: \(error)\n".utf8
            ))
        }
    }

    // MARK: rem_pins.json (latest-3-approved index)

    private var pinsURL: URL {
        dataRoot.appendingPathComponent("rem_pins.json")
    }

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
    /// this internally via runWeeklyREM step (8).
    public static func emitREMPinsIndex(dataRoot: URL) throws {
        let pinsURL = dataRoot.appendingPathComponent("rem_pins.json")
        // P-L3: read through the store so APPROVED rows folded into the
        // compaction base are still seen — a raw feed read would miss them and
        // silently drop long-approved pins after a compaction.
        let rows = REMProposalStore(dataRoot: dataRoot).loadAll()
        var perDoc: [String: [(id: String, text: String, createdAt: String)]] = [:]
        // APPROVED rows only — pending/denied must never leak into the
        // chat-turn injection.
        for row in rows where row.status == "approved"
            && REMProposalStore.supportsProposalTarget(row.targetDoc) {
            let targetDoc = REMProposalStore.normalizedTargetDoc(row.targetDoc)
            perDoc[targetDoc, default: []].append(
                (id: row.id, text: row.proposalText, createdAt: row.createdAt)
            )
        }
        // RECONCILE AGAINST THE LIVE DOCUMENT (2026-09-06). An approved row is
        // a historical fact and stays one; a PIN is a live instruction that
        // rides into every chat turn. Removing or correcting a lesson in
        // GROWTH.md left the old text pinned forever — the approval log still
        // said approved, so the injector kept feeding the retracted wording.
        // A pin now survives only while its lesson is still an entry in the
        // document it was approved into.
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        var documents: [String: String?] = [:]
        var out: [String: [REMPin]] = [:]
        for (doc, items) in perDoc {
            let document: String?
            if let cached = documents[doc] {
                document = cached
            } else {
                // ABSENT and UNREADABLE are different facts (2026-09-06). A
                // document that is gone retires its pins — deleting GROWTH.md
                // means those lessons are no longer instructions — so it
                // reconciles against an EMPTY body. A document that exists but
                // cannot be read keeps every pin: a transient read failure must
                // never silently strip her prompt. Both say which on stderr.
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
                documents[doc] = document
            }
            let live = items.filter { Self.pinIsLive($0.text, inDocument: document) }
            let sorted = live.sorted { $0.createdAt > $1.createdAt }.prefix(3)
            out[doc] = sorted.map { REMPin(id: $0.id, text: $0.text, createdAt: $0.createdAt) }
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
