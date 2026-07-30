// CognitiveSubstrate+Reflection.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    /// Optional proposal invitation appended to the reflection prompt. Reflection used to
    /// ask only for a free-form state read, so Opus never emitted anything the proposal
    /// parser recognized and yield was always 0 — pretty journaling, no learning. This
    /// invites up to 3 parser-tagged lines, but only when genuinely warranted, and is
    /// explicit that a zero-proposal quiet pass is correct, so reflection can earn its cost
    /// without manufacturing noise. The lines are proposals for the operator to approve via the
    /// Observatory, never autonomous actions.
    private var reflectionProposalInvitation: String { """
    This is your own private reflection — read the state honestly. If something in it \
    genuinely warrants capturing or changing, you may close with up to 3 lines, each on its \
    own line, beginning with exactly one of these tags:
      proposal: <a concrete adjustment to how you act or respond>
      schema: <a refinement to how you model a recurring situation>
      memory: <a durable preference, principle, or correction worth keeping in long-term memory>
      identity: <a small, well-evidenced refinement to your self-model>
      view: <a standing view of yours that has settled — a durable way you see something, not a task or a rule>
    A durable line that emerged — a preference \(userAddress) stated, a principle you agreed to, a \
    correction worth keeping — is worth a memory: line even when it is calm and carries no \
    tension; don't let it evaporate just because nothing is wrong. Each line must be specific \
    and earned by the state above. These are proposals for \(userAddress) to approve, not actions you \
    take. If genuinely nothing is worth capturing or changing, write no such lines — a quiet \
    pass is a correct, expected outcome. Never invent one to fill space.
    """ }

    public func planReflection(reason: String) async -> CognitiveReflectionRequest? {
        await waitForMaintenanceTransition()
        guard reflectionBudgetSlotAvailable() else { return nil }
        let now = dependencies.now()
        let capsule = await compileCapsule(
            CognitiveCapsuleRequest(
                surface: "reflection",
                userMessage: reason,
                mode: .inspectOnly,
                maximumCharacters: min(800, configuration.maximumCapsuleCharacters)
            )
        )
        // Bound the reason and place the instruction before the (truncatable) state preview
        // so the proposal invitation always survives the bound — a long reason can never push
        // the proposal tags out. The prompt grows only ~600 chars on a 4/day call.
        let promptReason = bounded(reason, maxCharacters: 200)
        let prompt = bounded(
            "Reason: \(promptReason)\n\n\(reflectionProposalInvitation)\n\nState preview:\n\(capsule.combined)",
            maxCharacters: 1_900
        )
        // compileCapsule is async. Recheck after it returns: another manual or
        // scheduled planner may have claimed the final slot while this actor was
        // reentrant, or Settings may have disabled/lowered the budget.
        guard reflectionBudgetSlotAvailable() else { return nil }
        let reservation = ReflectionReservation(id: dependencies.makeUUID(), since: dependencies.now())
        reflectionReservation = reservation
        return CognitiveReflectionRequest(
            reservationId: reservation.id,
            reason: bounded(reason, maxCharacters: 200),
            prompt: prompt,
            surface: configuration.reflectionSurface,
            model: configuration.reflectionModel,
            provider: configuration.reflectionProvider,
            reasoningEffort: configuration.reflectionReasoningEffort,
            requestedAt: now
        )
    }

    @discardableResult
    public func recordReflectionResult(
        request: CognitiveReflectionRequest,
        resultSummary: String,
        provider: String,
        cancelled: Bool = false
    ) async -> CognitiveReflectionReceipt? {
        await waitForMaintenanceTransition()
        let ownedBudgetSlot = request.reservationId.map { reflectionReservation?.id == $0 } ?? false
        let integrationEnabled = configuration.enabled && configuration.reflectiveCallsEnabled
        // Only a request issued by planReflection may consume the public
        // terminal path. A nil token is not a compatibility bypass, and a late
        // expired request cannot integrate or release a newer reservation.
        guard ownedBudgetSlot else { return nil }
        // A caller without a substrate-issued request cannot inject a receipt
        // while reflection is disabled. A real in-flight call, however, must
        // still be accounted if Settings changed before its result returned.
        guard integrationEnabled || ownedBudgetSlot else { return nil }
        // An LLM reflection that hits its output cap (or the 600-char bound below)
        // ends mid-sentence ("…easy to let evaporate. Not") and that fragment
        // surfaces verbatim in the Observatory. Trim the dangling fragment for
        // real reflections; failure/cancel strings pass through untouched so
        // diagnostics are never eaten.
        var boundedResult = bounded(resultSummary, maxCharacters: 600)
        if integrationEnabled,
           !cancelled,
           boundedResult.localizedCaseInsensitiveContains("reflection failed") == false {
            boundedResult = Self.trimmingIncompleteTrailingSentence(boundedResult)
        }
        var receipt = CognitiveReflectionReceipt(
            id: dependencies.makeUUID(),
            request: request,
            resultSummary: boundedResult,
            provider: bounded(provider, maxCharacters: 80),
            createdAt: dependencies.now(),
            cancelled: cancelled,
            estimatedPromptTokens: estimatedTokens(request.prompt),
            estimatedResultTokens: estimatedTokens(boundedResult),
            estimatedCostUnits: reflectionCostUnits(prompt: request.prompt, result: boundedResult)
        )
        if integrationEnabled,
           !cancelled,
           boundedResult.localizedCaseInsensitiveContains("reflection failed") == false {
            // Parse proposals from the FULL result, not the 600-char receipt
            // bound: the prompt asks her to put `view:`/`proposal:`/`schema:`/
            // `memory:` lines LAST, so any reflection substantial enough to
            // propose something was exactly the one the bound clipped — live
            // proof: the 07-12 standing-view candidate stored truncated
            // mid-word (audit round 2, R1). The stored/displayed summary
            // stays bounded; only the parse reads the whole thing.
            receipt.proposalIds = await parseReflectionProposals(receipt: receipt, source: resultSummary)
            await applyReflectionAffectNudge(from: boundedResult)
            // The slow layer (User, 2026-07-09): the reflection's considered tone
            // nudges her day-scale disposition — feelings that move slower than
            // the moment, carried into mood and the felt fingerprint.
            await integrateDisposition(
                tone: reflectionDispositionTone(from: boundedResult),
                at: dependencies.now()
            )
        }
        receipt.proposalYieldScore = reflectionYieldScore(
            proposalCount: receipt.proposalIds.count,
            costUnits: receipt.estimatedCostUnits,
            cancelled: cancelled
        )
        reflectionReceipts[receipt.id] = receipt
        enforceReflectionReceiptCap()
        // Install terminal budget accounting before releasing the reservation.
        // Proposal/affect/disposition integration above is reentrant; clearing
        // this earlier let another planner claim the same final daily slot.
        if ownedBudgetSlot { reflectionReservation = nil }
        if !cancelled, boundedResult.localizedCaseInsensitiveContains("reflection failed") == false {
            _ = await addThoughtSeed(
                kind: .reflectionTakeaway,
                text: reflectionTakeawaySeedText(from: boundedResult),
                priority: min(0.9, max(0.45, receipt.proposalYieldScore + 0.55))
            )
        }
        return receipt
    }

    /// Test-only integration seam for exercising standing-view parsing without
    /// manufacturing a production budget bypass. This is internal and visible
    /// to the target's `@testable` tests only.
    func recordUnreservedReflectionResultForTesting(
        request: CognitiveReflectionRequest,
        resultSummary: String,
        provider: String,
        cancelled: Bool = false
    ) async -> CognitiveReflectionReceipt? {
        let reservation = ReflectionReservation(id: dependencies.makeUUID(), since: dependencies.now())
        reflectionReservation = reservation
        var reservedRequest = request
        reservedRequest.reservationId = reservation.id
        return await recordReflectionResult(
            request: reservedRequest,
            resultSummary: resultSummary,
            provider: provider,
            cancelled: cancelled
        )
    }

    /// Scheduled-runtime durability confirmation for a reflection that already
    /// completed integration in memory. Proposal rows and their lineage are
    /// checked before the terminal receipt, so a durable receipt can never point
    /// at proposal tissue that failed to land.
    public func persistReflectionResultChecked(_ receipt: CognitiveReflectionReceipt) async throws {
        guard reflectionReceipts[receipt.id] == receipt else {
            throw CognitivePersistenceError.artifactWriteFailed(
                family: "reflection_receipt",
                detail: "receipt was not integrated through the reservation-owned substrate path"
            )
        }
        for proposalId in receipt.proposalIds {
            if let view = standingViews[proposalId] {
                try await persistArtifactChecked(
                    kind: "standing_view",
                    id: view.id,
                    status: view.status.rawValue,
                    score: max(0, view.moodValenceAtFormation),
                    payload: view.toJSON()
                )
            } else if let proposal = schemaProposals[proposalId] {
                try await persistArtifactChecked(
                    kind: "schema_proposal",
                    id: proposal.id,
                    status: proposal.status.rawValue,
                    score: proposal.confidence,
                    payload: proposal.toJSON()
                )
            } else {
                throw CognitivePersistenceError.artifactWriteFailed(
                    family: "reflection_proposal",
                    detail: "missing in-memory proposal \(proposalId.uuidString)"
                )
            }
            for event in timelineEvents(for: proposalId) {
                try await persistArtifactChecked(
                    kind: "developmental_timeline",
                    id: event.id,
                    status: "recorded",
                    score: 0.5,
                    payload: event.toJSON()
                )
            }
        }
        try await persistArtifactChecked(
            kind: "reflection_receipt",
            id: receipt.id,
            status: receipt.cancelled ? "cancelled" : "recorded",
            score: 0,
            payload: receipt.toJSON()
        )
    }

    /// Drop an unterminated trailing sentence fragment from capped LLM output.
    /// Conservative on purpose: only trims when the dangling tail contains
    /// letters/digits (a bare trailing emoji or symbol is a deliberate sign-off,
    /// not a cut), and only when the terminated portion keeps at least 40% of
    /// the text (an error string or single unpunctuated line passes through).
    static func trimmingIncompleteTrailingSentence(_ text: String) -> String {
        let terminal: Set<Character> = [".", "!", "?", "…"]
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "*", "`"]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // Already terminated (ignoring closing decoration)? Leave it alone.
        var cursor = trimmed.index(before: trimmed.endIndex)
        while cursor > trimmed.startIndex, closers.contains(trimmed[cursor]) {
            cursor = trimmed.index(before: cursor)
        }
        if terminal.contains(trimmed[cursor]) { return trimmed }
        guard let lastTerminal = trimmed.lastIndex(where: { terminal.contains($0) }) else { return trimmed }
        var end = trimmed.index(after: lastTerminal)
        while end < trimmed.endIndex, closers.contains(trimmed[end]) {
            end = trimmed.index(after: end)
        }
        let tail = trimmed[end...]
        guard tail.contains(where: { $0.isLetter || $0.isNumber }) else { return trimmed }
        // Structured proposal lines ("view: …", "schema: …", "memory: …", …) are
        // protocol, not prose — they end unpunctuated by design and feed
        // parseReflectionProposals. A tail carrying one is a deliberate ending,
        // never a cap cut. Same vocabulary + normalization as the parser.
        let tailIsProtocol = tail.split(whereSeparator: \.isNewline).contains { line in
            let lowered = Self.normalizedProposalLine(line).lowercased()
            return Self.reflectionProposalPrefixTable.contains { lowered.hasPrefix($0.prefix) }
        }
        guard !tailIsProtocol else { return trimmed }
        let kept = String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard kept.count * 10 >= trimmed.count * 4 else { return trimmed }
        return kept
    }

    public func reflectionReceiptSnapshot() async -> [CognitiveReflectionReceipt] {
        reflectionReceipts.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func applyReflectionAffectNudge(from result: String) async {
        guard configuration.enabled, configuration.affectEnabled else { return }
        let lower = result.lowercased()
        let now = dependencies.now()
        // Reflection merges into the affect that is true now, not the last
        // materialized checkpoint a maintenance cadence happened to leave.
        var next = projectedAffect(at: now)
        var changed = false

        if containsAny(lower, [
            "warm",
            "warmth",
            "present",
            "settled",
            "grounded",
            "with user",
        ]) {
            next.socialWarmth = max(next.socialWarmth, 0.48)
            changed = true
        }
        if containsAny(lower, [
            "settled",
            "low-tension",
            "low tension",
            "calm",
            "steady",
            "grounded",
        ]) {
            next.uncertainty = clamp(next.uncertainty - 0.08)
            next.taskPressure = clamp(next.taskPressure - 0.08)
            changed = true
        }
        if containsAny(lower, [
            "contradiction",
            "misread",
            "stale",
            "wrong",
            "anomaly",
        ]) {
            next.uncertainty = clamp(next.uncertainty + 0.05)
            changed = true
        }

        guard changed else { return }
        next.updatedAt = now
        affect = next
        await persistArtifact(
            kind: "affect",
            id: stableArtifactID("affect"),
            status: "current",
            score: next.arousal,
            payload: next.toJSON(
                lastUserPresenceAt: lastUserPresenceAt,
                lastWarmPresenceAt: lastWarmPresenceAt
            )
        )
    }

    /// The SIGNED felt tone of a reflection — the slow-layer peer of the fast
    /// keyword nudge above (User, 2026-07-09: reflections give her feelings a
    /// slower-moving floor). The lexicon itself now lives in `dispositionTone`
    /// (+Mood.swift), shared with the dream-mood writer so the two surfaces can
    /// never disagree about what "heavy" means. Fed to `integrateDisposition`
    /// (±dispositionNudgeMagnitude per call, ≤2 reflections/day, day-scale decay
    /// — a tone, never a mood override).
    func reflectionDispositionTone(from result: String) -> Double {
        dispositionTone(from: result)
    }

    func reflectionReceiptsToday() -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let now = dependencies.now()
        return reflectionReceipts.values.filter {
            calendar.isDate($0.createdAt, inSameDayAs: now)
        }.count
    }

    private func reflectionBudgetSlotAvailable() -> Bool {
        guard configuration.enabled,
              configuration.reflectiveCallsEnabled,
              configuration.dailyReflectionCallBudget > 0,
              reflectionReceiptsToday() < configuration.dailyReflectionCallBudget else {
            return false
        }
        guard let reservation = reflectionReservation else { return true }
        return dependencies.now().timeIntervalSince(reservation.since) >= Self.reflectionInFlightMaximumAge
    }

    private func parseReflectionProposals(
        receipt: CognitiveReflectionReceipt,
        source: String? = nil
    ) async -> [UUID] {
        let candidates = reflectionProposalCandidates(source ?? receipt.resultSummary)
        guard !candidates.isEmpty else { return [] }
        let now = dependencies.now()
        let evidenceNodeIds = await workspaceSnapshot().items.prefix(3).map(\.node.id)
        var proposalIds: [UUID] = []
        for candidate in candidates.prefix(3) {
            // Wave E: a `view:` line settles into a proposal-shaped standing view rather than
            // a schema proposal — still counted in proposalIds/yield (its id is reused).
            if candidate.target == "standing-view" {
                if let view = await createStandingView(
                    receipt: receipt,
                    body: candidate.body,
                    evidenceNodeIds: Array(evidenceNodeIds),
                    at: now
                ),
                    // createStandingView is idempotent per receipt+body — a duplicated
                    // `view:` line returns the SAME view, and counting it twice would
                    // inflate proposalIds/yield (gpt-5.5 review, 2026-07-02).
                    !proposalIds.contains(view.id) {
                    proposalIds.append(view.id)
                }
                continue
            }
            let evidenceId = "reflection:\(receipt.id.uuidString)"
            let id = stableArtifactID("reflection_schema|\(receipt.id.uuidString)|\(candidate.target)|\(stableDigest(candidate.body))")
            guard schemaProposals[id] == nil else { continue }
            let proposal = CognitiveSchemaProposal(
                id: id,
                title: bounded("\(candidate.target) reflection proposal", maxCharacters: 120),
                body: bounded(candidate.body, maxCharacters: 500),
                target: bounded(candidate.target, maxCharacters: 120),
                status: .proposed,
                confidence: candidate.confidence,
                createdAt: now,
                evidenceNodeIds: Array(evidenceNodeIds),
                externalEvidenceIds: [evidenceId] + evidenceNodeIds.map { "node:\($0.uuidString)" },
                lineageId: bounded("reflection:\(receipt.id.uuidString)", maxCharacters: 120)
            )
            guard !proposal.body.isEmpty else { continue }
            schemaProposals[proposal.id] = proposal
            enforceSchemaProposalCap()
            proposalIds.append(proposal.id)
            await persistArtifact(kind: "schema_proposal", id: proposal.id, status: proposal.status.rawValue, score: proposal.confidence, payload: proposal.toJSON())
            _ = await recordTimelineEvent(
                kind: .schemaProposal,
                title: proposal.title,
                summary: proposal.body,
                artifactId: proposal.id,
                lineageId: proposal.lineageId,
                externalEvidenceIds: proposal.externalEvidenceIds
            )
        }
        return proposalIds
    }

    /// Structured proposal-line vocabulary — the ONE source shared by the parser
    /// and `trimmingIncompleteTrailingSentence`, so a prefix can never be
    /// parseable yet trimmable (a trimmed protocol line silently drops proposals).
    static let reflectionProposalPrefixTable: [(prefix: String, target: String, confidence: Double)] = [
        ("view:", "standing-view", 0.5),
        ("proposal:", "reflection-proposal", 0.55),
        ("suggestion:", "reflection-suggestion", 0.50),
        ("schema:", "reflection-schema", 0.60),
        ("memory:", "memory-proposal-review", 0.45),
        ("identity:", "identity-proposal-review", 0.35),
    ]

    /// Normalize one reflection line the way the proposal parser sees it:
    /// whitespace + bullet/list-marker stripped. Shared so the trim's
    /// protocol-line check matches EXACTLY what the parser would accept.
    static func normalizedProposalLine(_ rawLine: Substring) -> String {
        rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*0123456789. )\t"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reflectionProposalCandidates(
        _ text: String
    ) -> [(target: String, body: String, confidence: Double)] {
        var out: [(target: String, body: String, confidence: Double)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = Self.normalizedProposalLine(rawLine)
            let lower = trimmed.lowercased()
            for (prefix, target, confidence) in Self.reflectionProposalPrefixTable where lower.hasPrefix(prefix) {
                let body = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    out.append((target, bounded(body, maxCharacters: 500), confidence))
                }
                break
            }
            if out.count >= 3 { break }
        }
        return out
    }

    private func estimatedTokens(_ text: String) -> Int {
        max(0, Int(ceil(Double(text.count) / 4.0)))
    }

    private func reflectionCostUnits(prompt: String, result: String) -> Double {
        let promptUnits = Double(estimatedTokens(prompt))
        let resultUnits = Double(estimatedTokens(result)) * 3
        return (promptUnits + resultUnits) / 1_000
    }

    private func reflectionYieldScore(
        proposalCount: Int,
        costUnits: Double,
        cancelled: Bool
    ) -> Double {
        guard !cancelled, proposalCount > 0 else { return 0 }
        return clamp(Double(proposalCount) / max(1, costUnits * 4))
    }

    func restoreReflectionReceipts(from payloads: [JSONValue]) {
        reflectionReceipts.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let reason = stringValue(object["reason"]),
                  let prompt = stringValue(object["prompt"]),
                  let surface = stringValue(object["surface"]),
                  let model = stringValue(object["model"]),
                  let requestProvider = stringValue(object["requestProvider"]),
                  let reasoningEffort = stringValue(object["reasoningEffort"]),
                  let requestedAt = dateValue(object["requestedAt"]),
                  let resultSummary = stringValue(object["resultSummary"]),
                  let provider = stringValue(object["provider"]),
                  let createdAt = dateValue(object["createdAt"]) else {
                continue
            }
            let request = CognitiveReflectionRequest(
                reason: reason,
                prompt: prompt,
                surface: surface,
                model: model,
                provider: requestProvider,
                reasoningEffort: reasoningEffort,
                requestedAt: requestedAt
            )
            reflectionReceipts[id] = CognitiveReflectionReceipt(
                id: id,
                request: request,
                resultSummary: resultSummary,
                provider: provider,
                createdAt: createdAt,
                cancelled: boolValue(object["cancelled"]) ?? false,
                estimatedPromptTokens: intValue(object["estimatedPromptTokens"]) ?? 0,
                estimatedResultTokens: intValue(object["estimatedResultTokens"]) ?? 0,
                estimatedCostUnits: doubleValue(object["estimatedCostUnits"]) ?? 0,
                proposalYieldScore: doubleValue(object["proposalYieldScore"]) ?? 0,
                proposalIds: uuidArrayValue(object["proposalIds"])
            )
        }
    }

    private func reflectionTakeawaySeedText(from result: String) -> String {
        let lines = result
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidate = lines.first { line in
            let lower = line.lowercased()
            return !lower.hasPrefix("-")
                && !lower.hasPrefix("#")
                && !lower.hasPrefix("**what")
                && !lower.hasPrefix("**the")
        } ?? lines.first ?? result
        let cleaned = candidate
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capsuleLineText("Reflection takeaway: \(cleaned)", maxCharacters: 180)
    }
}
