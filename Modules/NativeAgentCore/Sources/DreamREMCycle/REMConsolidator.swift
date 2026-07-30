import Foundation
import CryptoKit
import KnowledgeGraph
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

// MARK: - REMReport

/// Summary the weekly REM run returns to its caller (scheduler / debug menu).
public struct REMReport: Sendable, Codable, Equatable {
    public var proposalsGenerated: Int
    public var evidenceDatesMin: Int
    public var tombstoneSkips: Int
    public var growthMDEvicted: Int
    public var archivedEntries: Int

    public init(
        proposalsGenerated: Int,
        evidenceDatesMin: Int,
        tombstoneSkips: Int,
        growthMDEvicted: Int,
        archivedEntries: Int = 0
    ) {
        self.proposalsGenerated = proposalsGenerated
        self.evidenceDatesMin = evidenceDatesMin
        self.tombstoneSkips = tombstoneSkips
        self.growthMDEvicted = growthMDEvicted
        self.archivedEntries = archivedEntries
    }
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
    private let dataRoot: URL
    private let personaRoot: URL
    private let llm: any LLMClient
    private let router: any ProviderRoutingProtocol
    private let gate: DreamREMGatePolicy
    private let clock: @Sendable () -> Date
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
        // (1) Trust gate.
        guard gate.remEnabled else {
            throw DreamREMCycleError.cycleDisabled(
                error: "rem_cycle_disabled",
                detail: DreamREMGatePolicy.remDisabledDetail
            )
        }

        let now = clock()

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
        try? FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockCore = SwiftNativePersistenceCore()
        // Unique claim token = freshness timestamp + a per-run UUID (gpt-5.5
        // review). The timestamp drives the 6-day freshness check (parse the
        // FIRST whitespace token); the UUID makes the marker a unique claim id
        // so the failure rollback compare-and-restores EXACTLY our claim and
        // can never clobber a concurrent force-run that re-claimed in the same
        // second. The prior marker is captured UNDER the claim lock so the
        // rollback restores exactly what our claim overwrote.
        let claimToken = "\(ISO8601DateFormatter().string(from: now)) \(UUID().uuidString)"
        let claim = (try? await lockCore.withFileLock(markerURL) { () -> (Bool, Data?) in
            let existing = try? Data(contentsOf: markerURL)
            if !force,
               let data = existing,
               let text = String(data: data, encoding: .utf8),
               let firstToken = text.split(separator: " ", maxSplits: 1).first,
               let stamp = ISO8601DateFormatter().date(
                   from: String(firstToken).trimmingCharacters(in: .whitespacesAndNewlines)),
               now.timeIntervalSince(stamp) < 6 * 86_400 {
                return (false, existing)
            }
            try? claimToken.data(using: .utf8)?.write(to: markerURL, options: .atomic)
            return (true, existing)
        }) ?? (true, (try? Data(contentsOf: markerURL))) // lock failure: prefer running
        let shouldRun = claim.0
        let priorMarker = claim.1
        guard shouldRun else {
            FileHandle.standardError.write(Data(
                "REMConsolidator: weekly REM already ran within 6 days — skipping\n".utf8
            ))
            // Marker-skip still runs the staging catch-up: legacy-imported or
            // previously-unstaged pending rows must not wait a week for an
            // approval card.
            await stagePendingUnstagedRows(store)
            return REMReport(
                proposalsGenerated: 0,
                evidenceDatesMin: REMConstants._REM_MIN_EVIDENCE_DATES,
                tombstoneSkips: 0, growthMDEvicted: 0, archivedEntries: 0
            )
        }
        // loop-A finding (2026-06-13): the marker rollback used to run in a
        // `defer` OUTSIDE the claim flock. An unlocked restore can clobber a
        // newer claim a concurrent force-run wrote between our claim and our
        // failure, reopening the weekly window for an extra consolidation.
        // Wrap the body so the rollback runs under the SAME flock and only
        // restores when the marker still holds OUR stamp (compare-and-restore).
        do {

        // (2) Read last-7-day entries by mtime.
        let entries = try readRecentDiaryEntries(now: now, days: 7)

        // (3) Distill via LLM under the Agent-persona-bypass: REM gets the
        // FULL untruncated persona (SOUL + VOICE + GROWTH + USER + AGENTS)
        // as context so it reflects on the whole entity, not a target-doc
        // stub. Proposals still target SOUL/VOICE/GROWTH only — USER.md is
        // MemoryV2's responsibility. Distillation runs on the rem-surface
        // model with a chat-surface fallback so REM speaks in her current
        // voice unless the user has explicitly pinned `rem` to a different model.
        let diary = DreamDiaryReader(dataRoot: dataRoot)
        let helper = SwiftNativeREMConsolidator(llm: llm, diary: diary)
        let since = now.addingTimeInterval(-7 * 86_400)
        let personaDocs = try readPersonaDocs()
        let contextDocs = try readContextDocs()
        // Pin-only lookup on `rem` so a daemon-era seed can't override
        // Agent's current chat voice. Falls back to the chat-surface
        // picker so she REM-distills in her own voice by default.
        let pinnedRem = await router.pinnedModelStringForSurface("rem")
        let pickedModel: String?
        if let m = pinnedRem {
            pickedModel = m
        } else {
            pickedModel = await router.modelStringForSurface("chat")
        }
        let bypassSystem = Self.remBypassSystemPrompt(contextDocs: contextDocs)
        var rawProposals: [REMProposal] = []
        if !entries.isEmpty {
            rawProposals = try await helper.consolidate(
                since: since,
                personaDocs: personaDocs,
                system: bypassSystem,
                model: pickedModel,
                surface: "rem"
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
        try await store.appendPending(kept)

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

        return REMReport(
            proposalsGenerated: kept.count,
            evidenceDatesMin: REMConstants._REM_MIN_EVIDENCE_DATES,
            tombstoneSkips: tombSkips,
            growthMDEvicted: evicted,
            archivedEntries: moved
        )
        } catch {
            // Run failed — restore the weekly marker so the retry isn't
            // suppressed, but ONLY if the marker still holds OUR claim stamp.
            // Compare-and-restore under the SAME flock that guards the claim, so
            // a concurrent force-run's newer claim is never clobbered.
            try? await lockCore.withFileLock(markerURL) {
                let current = try? Data(contentsOf: markerURL)
                guard current == Data(claimToken.utf8) else { return }
                if let priorMarker {
                    try? priorMarker.write(to: markerURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: markerURL)
                }
            }
            throw error
        }
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
        let cutoff = now.addingTimeInterval(TimeInterval(-days * 86_400))
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
            if mtime < cutoff { continue }
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
        var out: [String: [REMPin]] = [:]
        for (doc, items) in perDoc {
            let sorted = items.sorted { $0.createdAt > $1.createdAt }.prefix(3)
            out[doc] = sorted.map { REMPin(id: $0.id, text: $0.text, createdAt: $0.createdAt) }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(out)
        try data.write(to: pinsURL, options: .atomic)
    }

    // MARK: GROWTH.md eviction-to-KG

    /// Char-based eviction. When GROWTH.md exceeds `_REM_GROWTH_CHAR_CAP`,
    /// distil ~`_REM_GROWTH_EVICT_CHARS` of the oldest entries to a KG node
    /// and remove them from disk. The static preamble (everything before
    /// the first non-preamble `## ` heading) is ALWAYS preserved — without
    /// that guard we'd chop the file's title + intro. Returns the number
    /// of characters actually evicted (0 when the cap doesn't fire).
    private func runGrowthEviction() async throws -> Int {
        let growth = personaRoot.appendingPathComponent("GROWTH.md")
        guard FileManager.default.fileExists(atPath: growth.path) else { return 0 }

        // CROSS-PROCESS LOCK. Every other GROWTH writer (PersonaEngine
        // growth-journal appends, the daemon routes) serializes under the
        // same `<GROWTH.md>.lock` flock — but this read→splice→write used to
        // run bare, so an append landing mid-eviction was silently erased by
        // our atomic rewrite of the stale body. The whole read → compute →
        // (LLM distill) → KG merge → write now runs under withFileLock on
        // the GROWTH path. Holding the flock across the distill is fine:
        // eviction fires at most weekly and writers just wait on the lock.
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(growth) {
            try await self.evictGrowthUnderLock(growth: growth)
        }
    }

    /// The locked critical section of `runGrowthEviction`. Must only be
    /// called while holding the GROWTH.md flock.
    private func evictGrowthUnderLock(growth: URL) async throws -> Int {
        let body = (try? String(contentsOf: growth, encoding: .utf8)) ?? ""
        if body.count <= REMConstants._REM_GROWTH_CHAR_CAP { return 0 }

        // Find the preamble boundary: the start of the first "evictable"
        // entry. Preamble sections (the file title `# ...`, intro paragraphs,
        // and the static `## Conventions` block) MUST survive eviction.
        let preambleEnd = Self.preambleEndIndex(in: body)
        let evictableStart = preambleEnd
        guard evictableStart < body.endIndex else { return 0 }

        // Walk `## ` headings forward from the evictable region until we
        // pass `_REM_GROWTH_EVICT_CHARS` worth of content. Evict everything
        // up to the next heading after the threshold so we never cut an
        // entry mid-paragraph. `nextEntryHeading` is INCLUSIVE — it would
        // re-return the current cursor — so we advance past it first.
        let target = REMConstants._REM_GROWTH_EVICT_CHARS
        var cursor = evictableStart
        var evicted = 0
        while evicted < target && cursor < body.endIndex {
            let searchFrom = body.index(after: cursor)
            // OVERSHOOT BOUND. When no further `## ` heading exists, the old
            // walk set cursor = endIndex and evicted the ENTIRE remaining
            // body in one pass. Cap the slice instead: cut at the first
            // newline AFTER the evict-chars target so the pass stays near
            // the configured size while still ending on a line boundary.
            if searchFrom >= body.endIndex {
                cursor = Self.boundedTailCut(in: body, from: evictableStart, target: target)
                break
            }
            guard let nextHeading = Self.nextEntryHeading(in: body, after: searchFrom) else {
                cursor = Self.boundedTailCut(in: body, from: evictableStart, target: target)
                break
            }
            cursor = nextHeading
            evicted = body.distance(from: evictableStart, to: cursor)
        }
        if cursor == evictableStart { return 0 }

        let evictedSlice = String(body[evictableStart..<cursor])

        // FAIL CLOSED on distillation failure. The old shape was
        // `(try? distill) ?? stub-node`: the splice below still ran, so an
        // LLM outage permanently destroyed user-approved persona content into
        // a content-free "LLM unavailable" stub. A distill throw now aborts
        // this pass's eviction (propagates out of `runWeeklyREM`, whose
        // marker-restore defer makes the next weekly tick retry) with the
        // content still intact in GROWTH.md.
        let kgNode = try await distillToKGNode(evictedSlice)
        // A cancel during the distill above (its own LLM call) must not fall
        // through to the KG+GROWTH commit pair below. One guard here covers both
        // writes: the KG-first ordering means a throw leaves GROWTH.md intact and
        // the KG untouched, and it propagates to the marker-restore `catch` so the
        // eviction retries on the next tick.
        try Task.checkCancellation()
        // KG-FIRST ORDERING. The GROWTH splice and the KG merge must succeed
        // TOGETHER or NEITHER. Previously the KG append was best-effort and the
        // GROWTH splice unconditionally followed, so a missing/malformed KG file
        // could leave the slice gone from GROWTH and never landed in KG —
        // PERMANENT DATA LOSS. Now `appendKGNode` THROWS on any fail-closed
        // skip (file missing, wrong top-level shape, broken sub-shape, encode
        // failure), and we let that throw propagate out of `runWeeklyREM`. The
        // GROWTH eviction RETRIES on the next REM tick. Worst case: the cap
        // pressure stays high until the operator fixes the KG file. That is
        // strictly better than silently shredding the user's growth notes.
        try await appendKGNode(kgNode)

        // Splice the evicted section out, leaving the preamble + remainder.
        // ONLY reached when the KG merge above succeeded.
        var rebuilt = String(body[..<evictableStart])
        rebuilt += String(body[cursor...])
        try rebuilt.data(using: .utf8)!.write(to: growth, options: .atomic)
        return evictedSlice.count
    }

    /// Bounded cut for the no-more-headings tail: the first index AFTER the
    /// first newline past `start + target` characters. Falls back to
    /// `endIndex` when the remaining body is shorter than the target or
    /// carries no trailing newline (evicting it all is within the bound).
    fileprivate static func boundedTailCut(
        in body: String,
        from start: String.Index,
        target: Int
    ) -> String.Index {
        guard let targetIdx = body.index(start, offsetBy: target, limitedBy: body.endIndex),
              targetIdx < body.endIndex else {
            return body.endIndex
        }
        guard let newline = body[targetIdx...].firstIndex(of: "\n") else {
            return body.endIndex
        }
        return body.index(after: newline)
    }

    /// Returns the index where the static preamble ends and the first
    /// evictable entry begins. The preamble convention (see persona/GROWTH.md):
    ///   `# GROWTH.md ...` title
    ///   one or more intro paragraphs
    ///   `## Conventions` block
    /// Everything from the FIRST `## ` heading whose title is NOT
    /// "Conventions" onward is evictable.
    fileprivate static func preambleEndIndex(in body: String) -> String.Index {
        var cursor = body.startIndex
        while cursor < body.endIndex {
            guard let heading = nextEntryHeading(in: body, after: cursor) else {
                return body.endIndex
            }
            let lineEnd = body[heading...].firstIndex(of: "\n") ?? body.endIndex
            let title = body[heading..<lineEnd]
                .replacingOccurrences(of: "## ", with: "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if title == "conventions" {
                cursor = lineEnd
                continue
            }
            return heading
        }
        return body.endIndex
    }

    /// Find the start index of the next `## ` heading at or after `from`.
    /// Matches at column 0 only (not inside code blocks or quoted text).
    fileprivate static func nextEntryHeading(
        in body: String,
        after from: String.Index
    ) -> String.Index? {
        var cursor = from
        while cursor < body.endIndex {
            // Headings start at column 0. Find the next newline, then
            // check whether the line after it begins with "## ".
            if cursor == body.startIndex || body[body.index(before: cursor)] == "\n" {
                let tail = body[cursor...]
                if tail.hasPrefix("## ") && !tail.hasPrefix("### ") {
                    return cursor
                }
            }
            cursor = body.index(after: cursor)
        }
        return nil
    }

    private struct KGNode: Codable {
        let id: String
        let summary: String
        let sourceLines: Int
        let createdAt: String
    }

    private func distillToKGNode(_ text: String) async throws -> KGNode {
        let prompt = """
        Distill the following evicted GROWTH-doc slice into ONE compressed
        knowledge-graph node summary (<=400 chars). Return plain text only.

        ---
        \(text)
        """
        // Per-surface picker: use the model picked for the "training" surface
        // (GROWTH-doc distillation is a training-tier task). nil falls back
        // to the surface seed inside SwiftNativeLLMClient.
        let pickedModel = await router.modelStringForSurface("training")
        let raw = try await llm.complete(
            prompt: prompt, system: nil, model: pickedModel, surface: "training"
        )
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return KGNode(
            // Stable over the source slice, not the model summary. If the KG
            // commit succeeds but the following GROWTH.md splice fails, the
            // next pass upserts this same entity instead of minting a duplicate.
            id: Self.growthDistillationID(text),
            summary: summary.isEmpty ? "empty distillation" : summary,
            sourceLines: text.split(separator: "\n").count,
            createdAt: isoNow()
        )
    }

    private static func growthDistillationID(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "growth_\(digest)"
    }

    /// Merge a GROWTH-eviction distillation node through the canonical graph
    /// owner. `memory.sqlite` is authoritative whenever it exists. The JSON
    /// mutation below is retained only for a true pre-SQLite install/fixture.
    ///
    /// LEGACY COMPATIBILITY SHAPE — DO NOT BREAK. The pre-SQLite KG file is a dict:
    /// ```
    /// {
    ///   "_commit_seq": <int>,
    ///   "version":     <int>,
    ///   "entities":    { "<id>": { id, name, type, first_seen,
    ///                              last_seen, mention_count, aliases, summary }, ... },
    ///   "edges":       [ {...}, ... ]
    /// }
    /// ```
    /// The earlier version of
    /// this method decoded as `[KGNode]` (a top-level array), defaulted to
    /// `[]` on any failure, then wrote the array back. The first time REM
    /// fired a GROWTH eviction it would have silently OVERWRITTEN the
    /// compatibility file with an array, deleting the user's whole knowledge graph.
    /// That bug is the entire reason this function looks the way it does now.
    ///
    /// FAIL-CLOSED CONTRACT: any unexpected condition (file missing, read
    /// failure, top-level not a dict, `entities` present but not a dict)
    /// THROWS and we leave the file untouched. The caller (`runGrowthEviction`)
    /// must NOT splice the GROWTH.md slice unless this call succeeded —
    /// otherwise the slice would be gone from both GROWTH and KG.
    ///
    /// CROSS-PROCESS LOCK: the whole read → validate → mutate → encode →
    /// atomic-write sequence runs under `withFileLock` on the KG file path so
    /// a concurrent writer (daemon merge, manual edit, sibling tool) can't
    /// race us. The lock matches the convention `PersistenceCore` documents
    /// for any read-modify-write of a daemon-shared JSON file.
    private func appendKGNode(_ node: KGNode) async throws {
        let kgDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        let kgURL = kgDir.appendingPathComponent("knowledge_graph.json")
        let sqliteURL = kgDir.appendingPathComponent("memory.sqlite")
        if FileManager.default.fileExists(atPath: sqliteURL.path) {
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqliteURL)
            try await indexer.upsertGrowthDistillation(
                id: node.id,
                summary: node.summary,
                sourceLines: node.sourceLines,
                createdAt: node.createdAt,
                legacyJSONPath: kgURL
            )
            return
        }

        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(kgURL) {
            try Self.mergeKGNodeUnderLock(node, kgURL: kgURL)
        }
    }

    /// The locked critical section. Static so it can be passed into the
    /// `@Sendable` closure of `withFileLock` without capturing actor state.
    /// Every fail-closed branch throws — the on-disk file is read into memory,
    /// validated, mutated, encoded, and then atomically rewritten; if any
    /// step is wrong we bail out BEFORE the write.
    private static func mergeKGNodeUnderLock(_ node: KGNode, kgURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: kgURL.path) else {
            throw NSError(
                domain: "REMConsolidator",
                code: -201,
                userInfo: [NSLocalizedDescriptionKey:
                    "knowledge_graph.json missing at \(kgURL.path); refusing to "
                    + "create a fresh file because the canonical shape (dict with "
                    + "entities/edges/version/_commit_seq) must be authored by the "
                    + "KG owner, not by GROWTH eviction."]
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: kgURL)
        } catch {
            throw NSError(
                domain: "REMConsolidator",
                code: -202,
                userInfo: [NSLocalizedDescriptionKey:
                    "failed to read knowledge_graph.json: \(error)"]
            )
        }
        guard var graph = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NSError(
                domain: "REMConsolidator",
                code: -203,
                userInfo: [NSLocalizedDescriptionKey:
                    "knowledge_graph.json top level is not a dict — refusing to "
                    + "overwrite. The canonical shape is "
                    + "{_commit_seq, version, entities:{...}, edges:[...]}."]
            )
        }

        // Validate sub-shape BEFORE mutating. `entities` MUST be present and
        // must be a dict; if it's absent or wrong-typed we refuse rather than
        // silently default-to-empty and clobber a non-canonical file the user
        // is mid-migration on. Same for `edges`: if present it must be an
        // array. Missing edges is tolerated (older variants may omit it) but
        // we won't overwrite a non-array edges.
        guard let existingEntities = graph["entities"] as? [String: Any] else {
            throw NSError(
                domain: "REMConsolidator",
                code: -204,
                userInfo: [NSLocalizedDescriptionKey:
                    "knowledge_graph.json `entities` field is missing or not a "
                    + "dict — refusing to overwrite. Live KG has 793 entities "
                    + "keyed by id; defaulting to empty here would erase them."]
            )
        }
        if let edges = graph["edges"], !(edges is [Any]) {
            throw NSError(
                domain: "REMConsolidator",
                code: -205,
                userInfo: [NSLocalizedDescriptionKey:
                    "knowledge_graph.json `edges` field is present but not an "
                    + "array — refusing to overwrite. Canonical shape is "
                    + "edges:[...]."]
            )
        }

        // Adapter shape: a distilled GROWTH-eviction node lives under entities
        // as a single record with type="growth_distillation". This keeps the
        // file's contract (entities is a dict keyed by id) intact and lets
        // downstream consumers query/render these nodes the same way they do
        // any other entity. Name = summary truncated; first_seen/last_seen =
        // createdAt; mention_count = sourceLines.
        var entities = existingEntities
        let nameTruncated: String = {
            let summary = node.summary
            if summary.count <= 80 { return summary }
            let idx = summary.index(summary.startIndex, offsetBy: 80)
            return String(summary[..<idx])
        }()
        let entity: [String: Any] = [
            "id": node.id,
            "name": nameTruncated,
            "type": "growth_distillation",
            "first_seen": node.createdAt,
            "last_seen": node.createdAt,
            "mention_count": node.sourceLines,
            "aliases": [String](),
            "summary": node.summary,
        ]
        entities[node.id] = entity
        graph["entities"] = entities

        // Bump _commit_seq so any consumer watching for changes sees a fresh
        // version. Treat the value defensively — older files may carry it as
        // a NSNumber or be missing entirely.
        let currentSeq: Int = {
            if let n = graph["_commit_seq"] as? Int { return n }
            if let n = graph["_commit_seq"] as? NSNumber { return n.intValue }
            return 0
        }()
        graph["_commit_seq"] = currentSeq + 1

        let out: Data
        do {
            out = try JSONSerialization.data(
                withJSONObject: graph,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw NSError(
                domain: "REMConsolidator",
                code: -206,
                userInfo: [NSLocalizedDescriptionKey:
                    "failed to encode merged KG: \(error)"]
            )
        }
        try out.write(to: kgURL, options: .atomic)
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: clock())
    }
}

// MARK: - REMPin (chat-turn injection shape)

/// One latest-approved REM proposal, surfaced into every chat turn's system
/// prompt as "Recent REM-approved persona drift". Public so the chat
/// orchestrator can decode the pins.json index.
public struct REMPin: Sendable, Codable, Equatable {
    public var id: String
    public var text: String
    public var createdAt: String

    public init(id: String, text: String, createdAt: String) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

// MARK: - REMPinsReader

/// Stateless reader for the rem_pins.json index emitted by REMConsolidator.
/// Lives in DreamREMCycle so ChatOrchestration can depend on it without
/// pulling the whole consolidation pipeline.
public enum REMPinsReader {
    /// Read the per-target pins index. Empty file / missing file / parse
    /// failure all return an empty dict — the chat turn must NOT inject
    /// anything in those cases.
    public static func read(dataRoot: URL) -> [String: [REMPin]] {
        let url = dataRoot.appendingPathComponent("rem_pins.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let decoded = try? JSONDecoder().decode([String: [REMPin]].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Flatten the per-target pins into the chat-turn injection lines.
    /// Returns at most `latestN` pins overall (default 3), newest first by
    /// createdAt. Empty input → empty array → no injection.
    public static func latest(_ index: [String: [REMPin]], latestN: Int = 3) -> [REMPin] {
        let all = index.values.flatMap { $0 }
        return Array(all.sorted { $0.createdAt > $1.createdAt }.prefix(latestN))
    }
}
