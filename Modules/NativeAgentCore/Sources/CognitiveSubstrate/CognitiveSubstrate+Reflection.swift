// CognitiveSubstrate+Reflection.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore

/// Who is asking for the introspective call.
public enum CognitiveReflectionDemand: String, Sendable, Equatable {
    /// A person asked (the Observatory button, an explicit call). The cost
    /// ceiling still holds; unresolved load does not gate it — refusing a
    /// direct ask because her seeds are quiet would be a lie about why.
    case requested
    /// Nobody asked: the dream/REM commit signal reached her. Admitted ONLY
    /// when unresolved load is above threshold, under the same ceiling.
    case spontaneous
}

/// Why a reflection was (or was not) admitted — the honest ledger line behind
/// a skipped autonomous call, including the load reading that produced it.
public struct CognitiveReflectionAdmission: Sendable, Equatable {
    public var admitted: Bool
    public var reason: String
    public var demand: CognitiveReflectionDemand
    public var load: Double
    public var threshold: Double
    public var backlog: Double
    public var urgency: Double
    public var dispositionDrift: Double
    public var callsInWindow: Int
    public var ceiling: Int

    public var detail: String {
        "\(reason) (load \(String(format: "%.2f", load))/\(String(format: "%.2f", threshold)), "
            + "backlog \(String(format: "%.2f", backlog)), urgency \(String(format: "%.2f", urgency)), "
            + "drift \(String(format: "%.2f", dispositionDrift)), spend \(callsInWindow)/\(ceiling) per 24h)"
    }
}

public enum CognitiveReflectionPlan: Sendable {
    case admitted(CognitiveReflectionRequest)
    case refused(CognitiveReflectionAdmission)
}

extension CognitiveSubstrate {
    /// Reflection may propose one settled standing view. REM remains the only
    /// canonical growth-proposal owner; reflection does not manufacture generic
    /// schema/memory/identity mirrors without effect executors.
    private var reflectionProposalInvitation: String { """
    This is your own private reflection — read the state honestly. If something in it \
    genuinely warrants a settled standing view, you may close with one line beginning:
      view: <a standing view of yours that has settled — a durable way you see something, not a task or a rule>
    It must be specific and earned by the state above. It is a proposal for \(userAddress) to \
    approve, not an action you take. If genuinely nothing has settled, write no view line — a quiet \
    pass is a correct, expected outcome. Never invent one to fill space.
    """ }

    /// Admission-checked planning. A `.spontaneous` call must be earned by
    /// unresolved load; a `.requested` one only has to fit under the ceiling.
    /// The refusal carries its reason so the caller can report it instead of
    /// swallowing a nil.
    public func planReflectionChecked(
        reason: String,
        demand: CognitiveReflectionDemand = .requested
    ) async -> CognitiveReflectionPlan {
        await waitForMaintenanceTransition()
        let admission = await reflectionAdmission(demand: demand)
        guard admission.admitted else { return .refused(admission) }
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
        let recheck = await reflectionAdmission(demand: demand)
        guard recheck.admitted else { return .refused(recheck) }
        let reservation = ReflectionReservation(id: dependencies.makeUUID(), since: dependencies.now())
        reflectionReservation = reservation
        return .admitted(CognitiveReflectionRequest(
            reservationId: reservation.id,
            reason: bounded(reason, maxCharacters: 200),
            prompt: prompt,
            surface: configuration.reflectionSurface,
            model: configuration.reflectionModel,
            provider: configuration.reflectionProvider,
            reasoningEffort: configuration.reflectionReasoningEffort,
            requestedAt: now
        ))
    }

    /// The unchanged entry point: an explicit request, refusal collapsed to nil.
    public func planReflection(reason: String) async -> CognitiveReflectionRequest? {
        guard case .admitted(let request) = await planReflectionChecked(
            reason: reason,
            demand: .requested
        ) else { return nil }
        return request
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

    /// The SIGNED felt tone of a reflection. The lexicon lives in `dispositionTone`
    /// (+Mood.swift), shared with the dream-mood writer so the two surfaces can
    /// never disagree about what "heavy" means. Fed to `integrateDisposition`
    /// (±dispositionNudgeMagnitude per call, ≤2 reflections/day, day-scale decay
    /// — a tone, never a mood override).
    func reflectionDispositionTone(from result: String) -> Double {
        dispositionTone(from: result)
    }

    /// Refusal vocabulary — stable strings, so a skipped call reads the same in
    /// a loop outcome, a receipt and a test.
    public static let reflectionRefusalDisabled = "reflection_disabled"
    public static let reflectionRefusalCeilingReached = "reflection_cost_ceiling_reached"
    public static let reflectionRefusalInFlight = "reflection_in_flight"
    public static let reflectionRefusalLoadBelowThreshold = "reflection_load_below_threshold"
    static let reflectionAdmittedReason = "admitted"

    /// The cost ceiling's window. ROLLING, not calendar: a reflection at 23:50
    /// used to free its slot ten minutes later, and a hard afternoon could not
    /// borrow against a quiet morning.
    static let reflectionCostWindow: TimeInterval = 24 * 60 * 60

    /// This many live thought seeds read as a full backlog. Deliberately small:
    /// the seeds decay, so six still-standing ones IS an unresolved pile.
    static let reflectionBacklogSaturation = 6.0

    /// Reflection calls already spent inside the rolling window. The ledger is
    /// the receipts themselves — the same rows the calendar-day count read.
    func reflectionCallsInCostWindow(at now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Self.reflectionCostWindow)
        return reflectionReceipts.values.filter { $0.createdAt > cutoff }.count
    }

    /// What is still unresolved in her, 0...1 — the thing that earns the call.
    /// All three existing signals, multiplied and read back as a geometric mean
    /// so the scale stays comparable to the threshold: a backlog nobody would
    /// interrupt for, or one that has not moved her undertone at all, is not
    /// load. Any factor at zero is a quiet day.
    func reflectionUnresolvedLoad(
        at now: Date
    ) async -> (backlog: Double, urgency: Double, drift: Double, score: Double) {
        let backlog = (Double(projectedThoughtSeeds(at: now).count) / Self.reflectionBacklogSaturation).clamped01()
        let urgency = (await thoughtSuggestionSnapshot(
            surface: "reflection_admission",
            limit: 1,
            minimumInterruptionScore: 0
        )).first?.interruptionScore ?? 0
        let cap = max(0.0001, dynamics.dispositionValenceCap)
        let drift = (abs(decayedDispositionValence(at: now)) / cap).clamped01()
        let score = cbrt(backlog * urgency * drift).clamped01()
        return (backlog, urgency, drift, score)
    }

    /// The hard fence: enabled, under the rolling ceiling, nothing in flight.
    /// Nil means "no cost objection". Sync and cheap — the terminal recheck and
    /// the load path share it.
    private func reflectionCostRefusal(at now: Date) -> String? {
        guard configuration.enabled,
              configuration.reflectiveCallsEnabled,
              configuration.dailyReflectionCallBudget > 0 else {
            return Self.reflectionRefusalDisabled
        }
        guard reflectionCallsInCostWindow(at: now) < configuration.dailyReflectionCallBudget else {
            return Self.reflectionRefusalCeilingReached
        }
        if let reservation = reflectionReservation,
           now.timeIntervalSince(reservation.since) < Self.reflectionInFlightMaximumAge {
            return Self.reflectionRefusalInFlight
        }
        return nil
    }

    /// Would a reflection be admitted right now, and why. Load is read only for
    /// the spontaneous demand — a person asking is never told her seeds are too
    /// quiet.
    public func reflectionAdmission(
        demand: CognitiveReflectionDemand = .spontaneous
    ) async -> CognitiveReflectionAdmission {
        let now = dependencies.now()
        let ceiling = configuration.dailyReflectionCallBudget
        let threshold = configuration.reflectionLoadThreshold
        let spent = reflectionCallsInCostWindow(at: now)
        if let refusal = reflectionCostRefusal(at: now) {
            return CognitiveReflectionAdmission(
                admitted: false,
                reason: refusal,
                demand: demand,
                load: 0,
                threshold: threshold,
                backlog: 0,
                urgency: 0,
                dispositionDrift: 0,
                callsInWindow: spent,
                ceiling: ceiling
            )
        }
        guard demand == .spontaneous else {
            return CognitiveReflectionAdmission(
                admitted: true,
                reason: Self.reflectionAdmittedReason,
                demand: demand,
                load: 0,
                threshold: threshold,
                backlog: 0,
                urgency: 0,
                dispositionDrift: 0,
                callsInWindow: spent,
                ceiling: ceiling
            )
        }
        let load = await reflectionUnresolvedLoad(at: now)
        let admitted = load.score > 0 && load.score >= threshold
        return CognitiveReflectionAdmission(
            admitted: admitted,
            reason: admitted ? Self.reflectionAdmittedReason : Self.reflectionRefusalLoadBelowThreshold,
            demand: demand,
            load: load.score,
            threshold: threshold,
            backlog: load.backlog,
            urgency: load.urgency,
            dispositionDrift: load.drift,
            callsInWindow: reflectionCallsInCostWindow(at: dependencies.now()),
            ceiling: ceiling
        )
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
        for candidate in candidates.prefix(1) {
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
        }
        return proposalIds
    }

    /// Structured proposal-line vocabulary — the ONE source shared by the parser
    /// and `trimmingIncompleteTrailingSentence`, so a prefix can never be
    /// parseable yet trimmable (a trimmed protocol line silently drops proposals).
    static let reflectionProposalPrefixTable: [(prefix: String, target: String, confidence: Double)] = [
        ("view:", "standing-view", 0.5),
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
