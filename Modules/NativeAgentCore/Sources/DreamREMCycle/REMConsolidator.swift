import SwarmRuns
import Foundation
import NativeAgentShared
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
//   minimumEvidenceCount = 2
//       A proposal needs two distinct supporting experiences OR dream dates
//       in the seven-day window. Two experiences on one date can qualify.
//
//   _REM_MAX_PROPOSALS = 5
//       Global weekly cap, applied after tombstone filtering.
//
//   _REM_GROWTH_CHAR_CAP = 20_000
//       Soft body-size cap for distilling exact approved paragraphs into the KG.
//
//   _REM_GROWTH_EVICT_CHARS = 5_000
//       Target characters per pass; contiguous whole approved paragraphs only.
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
    // Proposals use 1–3 short declarative sentences in her voice, clamped at a lesson-bearing sentence.
    public static let _REM_PROPOSAL_TEXT_CAP: Int = 180
    /// A lesson's "what surprised me / what changed" line.
    public static let whatChangedCap: Int = 200
}

// MARK: - REMConsolidator (weekly cycle)

/// Weekly cross-diary patterns become approval-gated GROWTH-only proposals.
/// Other persona documents are read-only context; MemoryV2 owns USER.md.
public actor REMConsolidator {
    let dataRoot: URL
    let personaRoot: URL
    let llm: any LLMClient
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
        gate: DreamREMGatePolicy = DreamREMGatePolicy(),
        clock: @escaping @Sendable () -> Date = { Date() },
        stageApproval: REMApprovalStager? = nil
    ) {
        self.dataRoot = dataRoot
        self.personaRoot = personaRoot
        self.llm = llm
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

        // The crash-safe run reservation excludes concurrent REM passes even when force bypasses weekly freshness.
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
            // Check cancellation before legacy import can write proposals.
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
        // Timestamp-first UUID claims restore only their locked predecessor; failed exclusion forbids REM work.
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
        let calendar = DreamREMSchedule.localCalendar()
        let start = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -7, to: start) ?? start
        let entries = try FileBackedDreamDiary(dataRoot: dataRoot).entriesSince(since)
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

        // One GROWTH.md distillation over the diary window and selected persona
        // context; the rem surface owns routing.
        let growthBody = try readGrowthBody()
        let contextDocs = try await readDreamPersonaDocs(
            dataRoot: dataRoot, personaRoot: personaRoot, surface: "rem"
        )
        let bypassSystem = try Self.remBypassSystemPrompt(contextDocs: contextDocs)
        var rawProposals: [REMProposalRow] = []
        if !entries.isEmpty {
            let distilled = try await PrivateWorkContextAssembly.$current.withValue(.suppliedPersona) {
                try await consolidate(
                    entries: entries,
                    growthBody: growthBody,
                    identities: identities,
                    system: bypassSystem,
                    surface: "rem",
                    systemGrowthBody: contextDocs["GROWTH.md"]
                )
            }
            rawProposals = distilled.proposals
            let parseErrors = distilled.parseErrors
            let evidenceDrops = distilled.evidenceDateDrops
            let targetDrops = distilled.targetMismatchDrops
            let passageDrops = distilled.passageDrops
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
            // A reply that did not decode releases the weekly claim for retry.
            let decodeFailures = distilled.decodeFailures
            if decodeFailures > 0 {
                throw DreamREMCycleError.remDecodeFailure(
                    "REM distillation could not decode the model's reply "
                    + "(\(decodeFailures) failure(s)): "
                    + parseErrors.joined(separator: "; ")
                )
            }
        }

        // (4) Fresh dates come only from admitted, quoted passages; an
        // unbound modern quote cannot qualify as legacy-unavailable evidence.
        var passEvidence: [REMProposalRow] = []
        for p in rawProposals {
            let floor = max(p.supportingExperienceCount(identities: identities) ?? 0, p.dreamDateCount)
            if floor >= REMConstants.minimumEvidenceCount {
                passEvidence.append(p)
            }
        }

        // (5) Tombstone filter.
        let passTomb = try await tombStore.filterTombstoned(passEvidence)
        let tombSkips = passEvidence.count - passTomb.count

        // The weekly cap ranks supporting experiences, breaks ties by emission
        // order and retains a dwelt-on proposal when present.
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
        // the run report.
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

        // Distill and remove contiguous exact approved paragraphs under character bounds.
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
    /// Recurrence ranks first; a labelled dwelt-on candidate retains a reserved inbox slot.
    nonisolated static func rankedByRecurrence(_ proposals: [REMProposalRow], identities: [String: String]) -> [REMProposalRow] {
        let cap = REMConstants._REM_MAX_PROPOSALS
        guard proposals.count > cap else { return proposals }
        let ordered = proposals.enumerated().map { (offset: $0.offset, element: $0.element,
            count: $0.element.supportingExperienceCount(identities: identities) ?? 0)
        }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
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

    /// Current GROWTH target; other persona documents are read-only context.
    private func readGrowthBody() throws -> String {
        let url = personaRoot.appendingPathComponent("GROWTH.md")
        let raw = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8) : ""
        return SwiftNativePersonaEngine.filterEpisodicGrowthLines(raw)
    }

    /// Private REM reflection with selected persona documents and USER context.
    fileprivate static func remBypassSystemPrompt(
        contextDocs: [String: String]
    ) throws -> String {
        return try completionPolicy("rem-proposal", section: "system", arguments: [renderDreamPersonaDocs(contextDocs)])
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

    /// Rebuild approved live-passage pins after eviction.
    private func emitREMPinsIndex() throws {
        try REMConsolidator.emitREMPinsIndex(dataRoot: dataRoot)
    }

    /// Rebuild `rem_pins.json` from approved live lessons in `rem_proposals.jsonl`.
    /// Shared by REM, proposal decisions and persona-write invalidation.
    public static func emitREMPinsIndex(dataRoot: URL) throws {
        // Share the proposal owner's flock across the complete derivation.
        // An older rebuild cannot publish over pins from a newer approval.
        try CredentialFileLock.withLock(dataRoot.appendingPathComponent("rem_proposals.jsonl")) {
            try emitREMPinsIndexLocked(dataRoot: dataRoot)
        }
    }

    private static func emitREMPinsIndexLocked(dataRoot: URL) throws {
        let pinsURL = dataRoot.appendingPathComponent("rem_pins.json")
        // Read approved rows through the store so compacted approvals remain pinned.
        let rows = try REMProposalStore(dataRoot: dataRoot).loadAllStrictly()
        // APPROVED rows only — pending/denied must never leak into the
        // chat-turn injection.
        let approved = rows.filter {
            $0.status == "approved" && REMProposalStore.supportsProposalTarget($0.targetDoc)
        }
        // A pin survives only while its approved lesson remains a standalone entry in the live document.
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
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: pinsURL)
    }

    /// A standalone entry keeps its pin; unreadable documents preserve pins, while absent documents retire them.
    static func pinIsLive(_ text: String, inDocument document: String?) -> Bool {
        guard let document else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return REMGrowthWriter.containsEntryParagraph(document, trimmed)
    }


}
