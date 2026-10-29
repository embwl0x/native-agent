import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts
import NativeAgentShared
// Blueprint: | `CognitiveSubstrate+Reflection.swift` | `CognitiveSubstrate`: causal `planReflectionChecked`, frozen per-cause peer/node provenance, judged reflection integration and receipts |

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
    public var callsInWindow: Int
    public var ceiling: Int

    public var detail: String {
        "\(reason) (load \(String(format: "%.2f", load))/\(String(format: "%.2f", threshold)), "
            + "spend \(callsInWindow)/\(ceiling) per 24h)"
    }
}

public enum CognitiveReflectionPlan: Sendable {
    case admitted(CognitiveReflectionRequest)
    case refused(CognitiveReflectionAdmission)
}

extension CognitiveSubstrate {
    /// Admission-checked planning. A `.spontaneous` call must be earned by
    /// unresolved load; a `.requested` one only has to fit under the ceiling.
    /// The refusal carries its reason so the caller can report it instead of
    /// swallowing a nil.
    public func planReflectionChecked(
        reason: String,
        demand: CognitiveReflectionDemand = .requested,
        material: [String: CognitiveReflectionCause]? = nil,
        sameSourceCooldown: TimeInterval? = nil
    ) async -> CognitiveReflectionPlan {
        await waitForMaintenanceTransition()
        let epoch = mindEpoch
        let admission = await reflectionAdmission(demand: demand)
        guard admission.admitted else { return .refused(admission) }
        let now = dependencies.now()
        let read = await frozenRead(at: now)
        // Reflection inspects the frozen state without resolving turn cues or
        // committing presentation cadence.
        let capsule = compileFrozenCapsulePresentation(
            CognitiveCapsuleRequest(
                surface: "reflection",
                userMessage: reason,
                mode: .inspectOnly,
                maximumCharacters: min(800, configuration.maximumCapsuleCharacters)
            ), from: read
        ).capsule
        let frozenEvidence = capsule.provenanceNodeIds
        let nodes = field.peekNodes()
        // A committed wake supplies its own causes. Requested reflection uses
        // exactly the capsule's sources, never unrelated field-score winners.
        var causes = material ?? [:]
        if material == nil {
            for node in nodes where frozenEvidence.contains(node.id) {
                causes["node:\(node.id.uuidString)"] = CognitiveReflectionCause(
                    text: "\(node.subjectReference.type):\(node.subjectReference.id)\n\(node.summary)",
                    sourcePeerIds: Self.peerIdentity(metadata: node.metadata, dataRoot: conversationDataRoot).map { [$0] } ?? [],
                    sourceNodeIds: [node.id])
            }
        }
        let references = causes.flatMap { [$0.key] + $0.value.sourceRefs }
            + nodes.map { "\($0.subjectReference.type):\($0.subjectReference.id)" }
        let identities: [String: String]
        do {
            identities = try await ChatSessionRecollections.experienceIdentities(for: references,
                dataRoot: store?.databaseURL.deletingLastPathComponent().deletingLastPathComponent())
        } catch {
            var refused = admission
            refused.admitted = false
            refused.reason = "Reflection source identity unavailable: \(error)"
            return .refused(refused)
        }
        for (ref, cause) in Array(causes) {
            let sources = Set(([ref] + cause.sourceRefs).compactMap { identities[$0] })
            causes[ref]?.sourceNodeIds = Array(Set(cause.sourceNodeIds + nodes.filter { node in
                sources.contains("message:" + node.id.uuidString)
                    || identities["\(node.subjectReference.type):\(node.subjectReference.id)"].map(sources.contains) == true
            }.map(\.id))).sorted { $0.uuidString < $1.uuidString }
        }
        let sourceExcerpts = causes.sorted { $0.key < $1.key }.map { "[\($0.key)]\n\($0.value.text)" }
        let sourcePeers = CognitiveReflectionCause.unionPeerIds(causes.values.map(\.sourcePeerIds)
            + (capsule.combined.isEmpty ? [] : [capsule.sourcePeerIds]))
        // Her cares, closest first: the reflection names the one its thought
        // belongs to, or a new one. The embedding only orders the list.
        let shownCares = await caresShown(
            for: ([reason] + causes.keys.sorted().compactMap { causes[$0]?.text }).joined(separator: "\n"))
        let prompt: String
        do {
            let careKey = try (shownCares.isEmpty ? "" : completionPolicy("reflection", section: "care-key"))
            let caresSection = try (shownCares.isEmpty ? "" : completionPolicy("reflection", section: "cares", arguments: [
                shownCares.map { "[\($0.key)] \($0.text)" }.joined(separator: "\n")
            ]))
            prompt = try completionPolicy("reflection", arguments: [
                bounded(reason, maxCharacters: 200), careKey,
                sourceExcerpts.joined(separator: "\n\n"), capsule.combined, caresSection
            ])
        } catch {
            var refused = admission
            refused.admitted = false
            refused.reason = "Reflection policy unavailable: \(error)"
            return .refused(refused)
        }
        // frozenRead is async. Recheck after it returns: another manual or
        // scheduled planner may have claimed the final slot while this actor was
        // reentrant, or Settings may have disabled/lowered the budget.
        let recheck = await reflectionAdmission(demand: demand)
        guard recheck.admitted else { return .refused(recheck) }
        guard epoch == mindEpoch else {
            var refused = recheck
            refused.admitted = false
            refused.reason = "Reflection material was cleared during planning"
            return .refused(refused)
        }
        // The cooldown prevents repeated reflection on identical material across triggers.
        if let sameSourceCooldown {
            let cutoff = now.addingTimeInterval(-sameSourceCooldown)
            if reflectionReceipts.values.contains(where: {
                !$0.cancelled && $0.createdAt >= cutoff && $0.request.material.mapValues(\.text) == causes.mapValues(\.text)
            }) {
                var skip = recheck
                skip.admitted = false
                skip.reason = "same source material reflected on within \(Int(sameSourceCooldown / 3600))h"
                return .refused(skip)
            }
        }
        let reservation = ReflectionReservation(id: dependencies.makeUUID(), since: dependencies.now())
        reflectionReservation = reservation
        return .admitted(CognitiveReflectionRequest(
            reservationId: reservation.id,
            reason: bounded(reason, maxCharacters: 200),
            prompt: prompt,
            surface: configuration.reflectionSurface,
            requestedAt: now,
            sourceNodeIds: Array(Set(causes.values.flatMap(\.sourceNodeIds))).sorted { $0.uuidString < $1.uuidString },
            sourcePeerIds: sourcePeers,
            material: causes,
            cares: shownCares
        ))
    }

    @discardableResult
    public func releaseReflectionReservation(request: CognitiveReflectionRequest) async -> Bool {
        await waitForMaintenanceTransition()
        guard ownsReflectionReservation(request) else { return false }
        reflectionReservation = nil
        return true
    }

    func ownsReflectionReservation(_ request: CognitiveReflectionRequest) -> Bool {
        request.reservationId.map { reflectionReservation?.id == $0 } ?? false
    }

    @discardableResult
    public func recordReflectionResult(
        request: CognitiveReflectionRequest,
        resultSummary: String,
        provider: String,
        cancelled: Bool = false,
        judgment: CognitiveReflectionJudgment? = nil
    ) async -> CognitiveReflectionReceipt? {
        await waitForMaintenanceTransition()
        let integrationEnabled = configuration.enabled && configuration.reflectiveCallsEnabled
        // Only a request issued by planReflection may consume the public
        // terminal path. A nil token is not a compatibility bypass, and a late
        // expired request cannot integrate or release a newer reservation.
        guard ownsReflectionReservation(request) else { return nil }
        defer {
            if ownsReflectionReservation(request) { reflectionReservation = nil }
        }
        let boundedResult = bounded(resultSummary, maxCharacters: 600)
        var receipt = CognitiveReflectionReceipt(
            id: dependencies.makeUUID(),
            request: request,
            resultSummary: boundedResult,
            provider: bounded(provider, maxCharacters: 80),
            createdAt: dependencies.now(),
            cancelled: cancelled,
            estimatedPromptTokens: estimatedTokens(request.prompt),
            estimatedResultTokens: estimatedTokens(resultSummary),
            estimatedCostUnits: reflectionCostUnits(prompt: request.prompt, result: resultSummary),
            judgment: judgment
        )
        if integrationEnabled, !cancelled, let judgment {
            receipt.proposalIds = await parseReflectionProposals(receipt: receipt, source: judgment.reflection)
            guard ownsReflectionReservation(request) else { return nil }
            if let tone = judgment.affect {
                receipt.dispositionSaveFailed = !(await integrateDisposition(
                    tone: tone, at: dependencies.now(), source: "reflection", undoable: true,
                    reflectionRequest: request))
                guard ownsReflectionReservation(request) else { return nil }
            }
        }
        if integrationEnabled, !cancelled, let takeaway = judgment?.takeaway {
            // A takeaway with a view lands in the care the view went to, unless
            // that care cannot hold a question.
            receipt.proposalIds += await applyReflectionCare(takeaway, open: takeaway,
                                                             joining: receipt.proposalIds.first, receipt: receipt)
            receipt.proposalIds = unique(receipt.proposalIds)
            guard ownsReflectionReservation(request) else { return nil }
        }
        receipt.proposalYieldScore = reflectionYieldScore(
            proposalCount: receipt.proposalIds.count,
            costUnits: receipt.estimatedCostUnits,
            cancelled: cancelled
        )
        reflectionReceipts[receipt.id] = receipt
        enforceReflectionReceiptCap()
        return receipt
    }

    /// Scheduled-runtime durability confirmation for a reflection that already
    /// completed integration in memory. Affected cares save before its receipt.
    public func persistReflectionResultChecked(_ receipt: CognitiveReflectionReceipt) async throws {
        try requireIntegratedReflectionReceipt(receipt)
        guard !receipt.dispositionSaveFailed else {
            throw CognitivePersistenceError.artifactWriteFailed(
                family: "reflection_disposition",
                detail: "produced affect failed to save; the reflection judgment is retained in its resident receipt"
            )
        }
        for careId in receipt.proposalIds {
            try requireIntegratedReflectionReceipt(receipt)
            guard cares[careId] != nil else {
                throw CognitivePersistenceError.artifactWriteFailed(
                    family: "reflection_care",
                    detail: "missing in-memory care \(careId.uuidString)"
                )
            }
            try await saveCares([careId], at: dependencies.now()).get()
        }
        try requireIntegratedReflectionReceipt(receipt)
        try await persistArtifactChecked(
            kind: "reflection_receipt",
            id: receipt.id,
            status: receipt.cancelled ? "cancelled" : "recorded",
            score: 0,
            payload: receipt.toJSON()
        )
    }

    private func requireIntegratedReflectionReceipt(_ receipt: CognitiveReflectionReceipt) throws {
        guard reflectionReceipts[receipt.id] == receipt else {
            throw CognitivePersistenceError.artifactWriteFailed(
                family: "reflection_receipt",
                detail: "receipt was not integrated through the reservation-owned substrate path"
            )
        }
    }

    public func reflectionReceiptSnapshot() async -> [CognitiveReflectionReceipt] {
        reflectionReceipts.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
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

    /// Reflection calls already spent inside the rolling window. The ledger is
    /// the receipts themselves — the same rows the calendar-day count read.
    func reflectionCallsInCostWindow(at now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Self.reflectionCostWindow)
        return reflectionReceipts.values.filter { $0.createdAt > cutoff }.count
    }

    /// The pressure of everything still open for her, read from cares.
    func reflectionUnresolvedLoad(at now: Date) -> Double {
        cares.values.filter { $0.fadedAt == nil && $0.open != nil }
            .reduce(0) { $0 + Self.carePressure($1, at: now) }
    }

    /// Would a reflection be admitted right now, and why. Load is read only for
    /// the spontaneous demand — a person asking is never told her cares are too
    /// quiet.
    public func reflectionAdmission(
        demand: CognitiveReflectionDemand = .spontaneous
    ) async -> CognitiveReflectionAdmission {
        let now = dependencies.now()
        let ceiling = configuration.dailyReflectionCallBudget
        let threshold = configuration.reflectionLoadThreshold
        let spent = reflectionCallsInCostWindow(at: now)
        var refusal: String?
        if !configuration.enabled || !configuration.reflectiveCallsEnabled || ceiling <= 0 {
            refusal = Self.reflectionRefusalDisabled
        } else if spent >= ceiling {
            refusal = Self.reflectionRefusalCeilingReached
        } else if let reservation = reflectionReservation,
                  now.timeIntervalSince(reservation.since) < Self.reflectionInFlightMaximumAge {
            refusal = Self.reflectionRefusalInFlight
        }
        let load = refusal == nil && demand == .spontaneous ? reflectionUnresolvedLoad(at: now) : 0
        if refusal == nil, demand == .spontaneous, !(load > 0 && load >= threshold) {
            refusal = Self.reflectionRefusalLoadBelowThreshold
        }
        return CognitiveReflectionAdmission(
            admitted: refusal == nil,
            reason: refusal ?? Self.reflectionAdmittedReason,
            demand: demand,
            load: load,
            threshold: threshold,
            callsInWindow: spent,
            ceiling: ceiling
        )
    }

    /// Unknown peer provenance is tainted, just as it was for view formation.
    func reflectionIsTainted(_ request: CognitiveReflectionRequest) -> Bool {
        guard let peers = request.sourcePeerIds else { return true }
        return peers.contains { !dependencies.peerTrusted($0) }
    }

    /// `peer:<uuid>` for an agent conversation, the lane name for a built-in
    /// one; an unknown peer session is returned as is (and trusts no one).
    public static func peerIdentity(session: String, dataRoot: URL = defaultDataRoot()) -> String? {
        guard SessionConversation.kind(session, dataRoot: dataRoot, includingArchived: true)?.isPeerConversation == true else { return nil }
        let lowered = session.lowercased()
        if let range = lowered.range(of: "-mcp-") {
            let tail = String(lowered[range.upperBound...])
            return UUID(uuidString: tail) != nil ? "peer:" + tail : tail
        }
        return lowered
    }

    public static func peerIdentity(metadata: [String: JSONValue], dataRoot: URL = defaultDataRoot()) -> String? {
        var session: String?
        if case .string(let value)? = metadata["sessionId"] { session = value }
        if case .object(let origin)? = metadata["origin"], case .string(let authored)? = origin["authored"],
           authored.lowercased() == peerAuthoredAttestation {
            if case .string(let agent)? = origin["agent"], agent.lowercased() != "agent" { return agent }
            return session.flatMap { peerIdentity(session: $0, dataRoot: dataRoot) } ?? "agent"
        }
        return session.flatMap { peerIdentity(session: $0, dataRoot: dataRoot) }
    }

    private func parseReflectionProposals(
        receipt: CognitiveReflectionReceipt,
        source: String? = nil
    ) async -> [UUID] {
        guard ownsReflectionReservation(receipt.request), !reflectionIsTainted(receipt.request),
              let judgment = receipt.judgment, !judgment.sources.isEmpty else { return [] }
        var view: String?, because = "", unless = ""
        for raw in (source ?? receipt.resultSummary).split(whereSeparator: \.isNewline) {
            let line = Self.normalizedProposalLine(raw).replacingOccurrences(of: "**", with: "")
            let lower = line.lowercased()
            func rest(_ prefix: String) -> String {
                String(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if lower.hasPrefix("view:"), view == nil { view = rest("view:") }
            else if lower.hasPrefix("because:") { because = rest("because:") }
            else if lower.hasPrefix("unless:") { unless = rest("unless:") }
        }
        guard let view, !view.isEmpty else { return [] }
        return await applyReflectionCare(
            view, stance: .init(text: view, because: because, wouldChangeMind: unless), receipt: receipt)
    }

    /// The reflection's thought, in the care it named (`judgment.care`, a key
    /// it was shown), else in `made` (the care its view just went to), else in
    /// a new care of hers. An open takeaway goes only to a care that can hold
    /// a question, never a life root.
    func applyReflectionCare(_ text: String, stance: CognitiveCare.Stance? = nil,
                             open: String? = nil, joining made: UUID? = nil,
                             receipt: CognitiveReflectionReceipt) async -> [UUID] {
        guard ownsReflectionReservation(receipt.request), !reflectionIsTainted(receipt.request) else { return [] }
        let generation = caringAppraisalGeneration
        func holds(_ id: UUID) -> Bool { cares[id].map { open == nil || $0.origin != .seed } ?? false }
        let key = receipt.judgment?.care?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = key.flatMap { key in receipt.request.cares.first { $0.key.lowercased() == key }?.id }
        let target: CognitiveCareJudgment.Target
        if let named, holds(named) {
            target = .existing(named)
        } else if let made, holds(made) {
            target = .existing(made)
        } else {
            target = .new(about: careTitle(from: text), between: false)
        }
        do {
            return try await applyCares([
                CognitiveCareJudgment(target: target, moved: 0, by: .her, felt: "reflected",
                                      note: "my reflection", open: open, stance: stance)
            ], provenance: .init(speaker: CognitiveCare.ownerKey, trusted: true, appAuthored: true,
                                source: "reflection:" + receipt.id.uuidString, at: receipt.createdAt),
               generation: generation)
        } catch let error as CognitiveCareNotSaved {
            // Keep the care identity with the produced judgment. Terminal
            // settlement saves these resident changes before its receipt;
            // it must never judge or apply the reflection a second time.
            nativeLog("reflection: care durability owed: %@", error.description)
            return error.ids
        } catch {
            nativeLog("reflection: care was not saved: %@", String(describing: error))
            return []
        }
    }

    static func normalizedProposalLine(_ rawLine: Substring) -> String {
        rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*0123456789. )\t"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        return (Double(proposalCount) / max(1, costUnits * 4)).clamped01()
    }

}
