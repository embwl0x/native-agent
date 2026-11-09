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
// Blueprint: | `REMConsolidator.swift` | `REMConsolidator`, `runWeeklyREM`, `rankedByRecurrence`. |

// MemoryV2 owns USER; REM reads persona context but proposes only compact GROWTH reflexes.

// MARK: - REM consolidation constants
// Require distinct supporting experiences or dream dates within the week; two experiences on one date can qualify.
// Cap weekly proposals after tombstone filtering; evict only contiguous exact approved growth paragraphs.
public enum REMConstants {
    public static let minimumEvidenceCount: Int = 2
    public static let _REM_MAX_PROPOSALS: Int = 5
    public static let _REM_GROWTH_CHAR_CAP: Int = 20_000
    public static let _REM_GROWTH_EVICT_CHARS: Int = 5_000
    public static let _REM_ARCHIVE_DAYS: Int = 14
    // Keep proposals in the agent's voice and end at a lesson-bearing sentence.
    public static let _REM_PROPOSAL_TEXT_CAP: Int = 180
    public static let whatChangedCap: Int = 200
}

// MARK: - REMConsolidator (weekly cycle)

/// Keep persona context read-only; GROWTH proposals require approval and USER remains MemoryV2-owned.
public actor REMConsolidator {
    let dataRoot: URL
    let personaRoot: URL
    let llm: any LLMClient
    private let gate: DreamREMGatePolicy
    let clock: @Sendable () -> Date
    /// Without a stager retain unstamped proposals for the next pass rather than inventing approval.
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
        // Use wall time for report duration and the injected clock for weekly semantics.
        let runStartedAt = Date()

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

        // Keep concurrent passes excluded even when force bypasses weekly freshness.
        let bodyDir = dataRoot.appendingPathComponent("body", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: bodyDir, withIntermediateDirectories: true)
        let runReservation: DreamRunReservation?
        do {
            runReservation = try DreamRunReservation.acquire(
                at: bodyDir.appendingPathComponent(".rem_run.lock"))
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
                outcome: report.outcome,
                reason: "rem_already_running",
                report: report,
                startedAt: runStartedAt
            )
            return report
        }
        defer { runReservation.release() }

        // Only undo a reservation acquired by this invocation; earlier failures still need durable run records.
        var rollback: (@Sendable () async -> Void)?
        do {
            // Check cancellation before any proposal write.
            try Task.checkCancellation()

            // Validate tombstone authority before weekly claims or effects so corrupt rejection state cannot be treated as empty.
            let tombStore = REMTombstoneStore(dataRoot: dataRoot)
            _ = try await tombStore.loadAll()

            let store = REMProposalStore(dataRoot: dataRoot)
            // Validate eviction evidence before marker claims or staging so malformed history cannot leave new effects for a retry.
            let growthProposalRows = try store.loadAllStrictly()

        // Claim weekly exclusion before distillation; it is not completion proof.
        // Release failed claims only before durable proposals; later work retains IDs and terminal evidence in the run ledger.
            let markerURL = dataRoot
                .appendingPathComponent("body", isDirectory: true)
                .appendingPathComponent("last_weekly_rem_run")
        // Claims can restore only their locked predecessor; failed exclusion forbids work.
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
            // Catch up unstaged pending approvals even on a fresh-marker skip so existing work cannot wait another week.
            try await stagePendingUnstagedRows(store, resolver: ConversationHistory.ExperienceResolver(dataRoot: dataRoot))
            let report = REMReport(
                proposalsGenerated: 0,
                evidenceDatesMin: REMConstants.minimumEvidenceCount,
                tombstoneSkips: 0, growthMDEvicted: 0, archivedEntries: 0,
                skipReason: "weekly_reservation_fresh"
            )
            await persistRunReport(
                outcome: report.outcome,
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

        // Unreadable sections stay active for repair; age cannot remove them from the next pass.
        let pendingEntries = try FileBackedDreamDiary(dataRoot: dataRoot).entriesSince(nil)
        var entries: [DreamEntry] = []
        var unavailableSections: [String] = []
        var entrySources: [String: [String]] = [:]
        for var entry in pendingEntries {
            guard let content = entry.content else {
                unavailableSections.append("dream_diary/\(entry.filename ?? entry.date): content unavailable")
                continue
            }
            let sections = DreamEntryProvenance.readClaims(in: content, as: DreamEntryProvenance.self)
            unavailableSections += sections.compactMap { section in
                section.unavailable.map { "dream_diary/\(entry.filename ?? entry.date): \($0)" }
            }
            let readable = sections.filter { $0.unavailable == nil }
            guard !readable.isEmpty else { continue }
            entry.content = readable.map(\.content).joined(separator: "\n")
            entrySources[entry.filename ?? entry.date] = Array(Set(readable.flatMap { $0.claims.flatMap(\.sourceRefs) })).sorted()
            entries.append(entry)
        }
        let sourceRefs = Set(entrySources.values.flatMap { $0 })
        let resolver = ConversationHistory.ExperienceResolver(dataRoot: dataRoot)
        let resolved = try await resolver.resolve(for: Array(sourceRefs), includingSourceRows: true)
        let identities = resolved.identities
        var reflectionMaterial = try await DreamEntryProvenance.resolveSources(sourceRefs, dataRoot: dataRoot,
            messages: resolved.messages)
        for entry in entries {
            if let content = entry.content {
                let sources = entrySources[entry.filename ?? entry.date] ?? []
                var cause = CognitiveReflectionCause(text: content,
                    sources: sources, material: reflectionMaterial)
                cause.sourcePeerIds = CognitiveReflectionCause.unionPeerIds([DreamEntryProvenance.peerIds(in: content)]
                    + sources.map { reflectionMaterial[$0]?.sourcePeerIds })
                reflectionMaterial["dream_diary/\(entry.filename ?? "\(entry.date).md")"] = cause
            }
        }
        // Every read diary section contributes trust, whether cited or not.
        let sourcePeers = CognitiveReflectionCause.unionPeerIds(entries.map {
            reflectionMaterial["dream_diary/\($0.filename ?? "\($0.date).md")"]?.sourcePeerIds
        })

        // Bind distillation to the selected persona and REM routing surface.
        let growthBody = try readGrowthBody()
        let contextDocs = try await readDreamPersonaDocs(
            dataRoot: dataRoot, personaRoot: personaRoot, surface: "rem", preview: false
        )
        let bypassSystem = try Self.remBypassSystemPrompt(contextDocs: contextDocs)
        var rawProposals: [REMProposalRow] = []
        if !entries.isEmpty {
            let distilled = try await consolidate(
                entries: entries, growthBody: growthBody, identities: identities,
                system: bypassSystem, surface: "rem",
                systemGrowthBody: contextDocs["GROWTH.md"])
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
                    + "should be the model returning {\"proposals\": []}, not a parse casualty.\n"
                FileHandle.standardError.write(Data(zeroMsg.utf8))
            }
            // Release the weekly claim on decode failure so the pass remains retryable.
            let decodeFailures = distilled.decodeFailures
            if decodeFailures > 0 {
                throw DreamREMCycleError.remDecodeFailure(
                    "REM distillation could not decode the model's reply "
                    + "(\(decodeFailures) failure(s)): "
                    + parseErrors.joined(separator: "; ")
                )
            }
        }

        // Count dates only from verified quoted support; an unbound quote cannot establish unavailable provenance.
        var passEvidence: [REMProposalRow] = []
        for p in rawProposals {
            let floor = max(p.supportingExperienceCount(identities: identities) ?? 0, p.dreamDateCount)
            if floor >= REMConstants.minimumEvidenceCount {
                passEvidence.append(p)
            }
        }

        let passTomb = try await tombStore.filterTombstoned(passEvidence)
        let tombSkips = passEvidence.count - passTomb.count

        // Rank by supporting experiences and stable emission order while reserving a slot for labelled dwelling.
        let kept = Self.rankedByRecurrence(passTomb, identities: identities)

        // Check cancellation before commits even after model response.
        // Only pre-persistence failure releases weekly exclusion; durable proposals keep their IDs for staging catch-up.

        // Append pending proposals through the shared locked, identity-deduplicated store.
        try Task.checkCancellation()
        // Refuse non-GROWTH targets and carry their names into receipts so drops remain actionable.
        let appendReceipt = try await store.appendPendingWithReceipt(kept)
        // Once proposals are durable, retries must use existing IDs.
        if appendReceipt.appended > 0 { rollback = nil }

        // Stage and stamp under the shared owner so retries cannot create duplicate cards; failed stages remain owed.
        try Task.checkCancellation()
        var stagingFailure: (any Error)?
        do { try await stagePendingUnstagedRows(store, resolver: resolver) }
        catch { stagingFailure = error }

        // Evict only exact contiguous approved paragraphs within character bounds.
        try Task.checkCancellation()
        let evicted = try await runGrowthEviction(proposalRows: growthProposalRows)

        // Publish pins only for approved passages still live after eviction.
        try emitREMPinsIndex()

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
            // Report dwelling separately so repeated dreams of one occasion cannot masquerade as independent recurrence.
            dweltOnKept: dweltOnKept == 0 ? nil : dweltOnKept,
            provenanceUnavailableKept: unavailableKept == 0 ? nil : unavailableKept
        )
        report.unavailableDreamSections = unavailableSections.isEmpty ? nil : unavailableSections
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
        // A partial read fails its pass; release only this claim and only before durable proposals.
        if !unavailableSections.isEmpty, let release = rollback {
            await release()
            rollback = nil
        }
        await persistRunReport(
            outcome: report.outcome,
            reason: unavailableSections.isEmpty ? nil : "dream_evidence_unavailable",
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

    /// Rank supported recurrence first while retaining a reserved slot for a labelled dwelt-on candidate.
    nonisolated static func rankedByRecurrence(_ proposals: [REMProposalRow], identities: [String: String]) -> [REMProposalRow] {
        let cap = REMConstants._REM_MAX_PROPOSALS
        guard proposals.count > cap else { return proposals }
        let ordered = proposals.enumerated().map { (offset: $0.offset, element: $0.element,
            count: $0.element.supportingExperienceCount(identities: identities) ?? 0)
        }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.offset < rhs.offset
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

    /// Write a bounded counter-only run summary so a quiet completed week remains distinguishable from a missed invocation.
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
            // Keep an explicit encoding-failure sentinel if the scalar payload ever stops encoding.
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

    /// Other persona documents remain read-only; GROWTH is the mutation target.
    private func readGrowthBody() throws -> String {
        let url = personaRoot.appendingPathComponent("GROWTH.md")
        do { return try SwiftNativePersonaEngine.readPersonaDocument(at: url) }
        catch {
            throw PersonaEngineError.rootUnreadable(
                reason: "cannot read \(url.path): \(error.localizedDescription). Repair or restore this document before continuing."
            )
        }
    }

    /// Keep REM reflection private while retaining selected persona and USER context.
    fileprivate static func remBypassSystemPrompt(
        contextDocs: [String: String]
    ) throws -> String {
        return try completionPolicy("rem-proposal", section: "system", arguments: [renderDreamPersonaDocs(contextDocs)])
    }

    // MARK: rem_proposals.jsonl

    /// Repair committed work without generating another proposal set.
    public func repairPendingWork() async throws -> Int {
        guard gate.remEnabled else {
            throw DreamREMCycleError.cycleDisabled(error: "rem_cycle_disabled", detail: DreamREMGatePolicy.remDisabledDetail)
        }
        let directory = dataRoot.appendingPathComponent("body", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let reservation = try DreamRunReservation.acquire(at: directory.appendingPathComponent(".rem_run.lock")) else {
            throw ToolFailureError("REM is still running; its repair remains owed until the current pass ends.", effects: .none)
        }
        defer { reservation.release() }
        try await stagePendingUnstagedRows(REMProposalStore(dataRoot: dataRoot),
            resolver: ConversationHistory.ExperienceResolver(dataRoot: dataRoot))
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

    private func stagePendingUnstagedRows(_ store: REMProposalStore, resolver: ConversationHistory.ExperienceResolver) async throws {
        try await store.stagePendingApprovals({ [stageApproval] row, experiences in
            try Task.checkCancellation()
            guard let stageApproval else {
                throw ToolFailureError("REM approval staging has no connected owner.", effects: .none)
            }
            return try await stageApproval(row, experiences)
        }, resolver: resolver)
    }

    // MARK: rem_pins.json (latest-3-approved index)

    /// Rebuild pins only from approved live passages after eviction.
    private func emitREMPinsIndex() throws {
        try REMConsolidator.emitREMPinsIndex(dataRoot: dataRoot)
    }

    /// Share pin derivation across REM, decisions and persona invalidation.
    public static func emitREMPinsIndex(dataRoot: URL) throws {
        // Hold the proposal lock across derivation so an older rebuild cannot publish over a newer approval.
        try CredentialFileLock.withLock(dataRoot.appendingPathComponent("rem_proposals.jsonl")) {
            try emitREMPinsIndexLocked(dataRoot: dataRoot)
        }
    }

    private static func emitREMPinsIndexLocked(dataRoot: URL) throws {
        let pinsURL = dataRoot.appendingPathComponent("rem_pins.json")
        // Read through the store so approvals compacted into its base remain pinned.
        let rows = try REMProposalStore(dataRoot: dataRoot).loadAllStrictly()
        // Only approved rows may enter chat context; pending and denied rows cannot.
        let approved = rows.filter {
            $0.status == "approved" && REMProposalStore.supportsProposalTarget($0.targetDoc)
        }
        // Retain a pin only while its approved lesson remains a standalone live entry.
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        var out: [String: [REMPin]] = [:]
        if !approved.isEmpty {
            let doc = "GROWTH.md"
            let url = personaRoot.appendingPathComponent(doc)
            let document: String
            do {
                document = try SwiftNativePersonaEngine.readPersonaDocument(at: url)
            } catch {
                throw PersistenceCoreError.ioFailure(
                    "REM pins could not be derived from \(url.path): \(error.localizedDescription). "
                        + "Preserve the existing index and repair the document before rebuilding pins.")
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

    /// Only a successfully read document can prove a live standalone entry.
    static func pinIsLive(_ text: String, inDocument document: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return REMGrowthWriter.containsEntryParagraph(document, trimmed)
    }


}
