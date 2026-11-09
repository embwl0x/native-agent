import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts
import NativeAgentShared
// Blueprint: | `CognitiveSubstrate+Reflection.swift` | `CognitiveSubstrate`: `planReflectionChecked`, frozen causes and receipts |

/// Keep admission reasons and readings so a skipped reflection is explainable.
public struct CognitiveReflectionAdmission: Sendable, Equatable {
    public var admitted: Bool
    public var reason: String
    public var callsInWindow: Int
    public var ceiling: Int

    public var detail: String {
        "\(reason) (spend \(callsInWindow)/\(ceiling) per 24h)"
    }
}

public enum CognitiveReflectionPlan: Sendable {
    case admitted(CognitiveReflectionRequest)
    case refused(CognitiveReflectionAdmission)
}

extension CognitiveSubstrate {
    /// Return the admission cause with its receipt budget and reservation evidence.
    public func planReflectionChecked(
        reason: String,
        material: [String: CognitiveReflectionCause]? = nil
    ) async -> CognitiveReflectionPlan {
        await waitForMaintenanceTransition()
        let epoch = mindEpoch
        let admission = await reflectionAdmission()
        guard admission.admitted else { return .refused(admission) }
        let now = dependencies.now()
        let read = await frozenRead(at: now)
        // Reflection inspects the frozen state without resolving turn cues or committing presentation cadence.
        let capsule = compileFrozenCapsulePresentation(
            CognitiveCapsuleRequest(
                surface: "reflection",
                userMessage: reason,
                mode: .inspectOnly,
                maximumCharacters: min(800, configuration.maximumCapsuleCharacters)
            ), from: read, turn: nil
        ).capsule
        let frozenEvidence = capsule.provenanceNodeIds
        let nodes = field.peekNodes()
        // A committed wake supplies its own causes. Requested reflection uses exactly the capsule's sources, never unrelated field-score winners.
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
            identities = try await ConversationHistory.experienceIdentities(for: references,
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
        // Embeddings order cares; the reflection names the care its thought belongs to.
        let shownCares: [CognitiveCareLine]
        do {
            shownCares = try await caresShown(
                for: ([reason] + causes.keys.sorted().compactMap { causes[$0]?.text }).joined(separator: "\n"))
        } catch {
            oweCareEmbedding(error)
            var refused = admission
            refused.admitted = false
            refused.reason = "Reflection care evidence unavailable: \(error.localizedDescription)"
            return .refused(refused)
        }
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
        // Recheck admission after frozenRead suspends: actor reentrancy permits another claim or a changed budget.
        let recheck = await reflectionAdmission()
        guard recheck.admitted else { return .refused(recheck) }
        guard epoch == mindEpoch else {
            var refused = recheck
            refused.admitted = false
            refused.reason = "Reflection material was cleared during planning"
            return .refused(refused)
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
        judgment: CognitiveReflectionJudgment? = nil,
        journalPending: Bool = false
    ) async -> CognitiveReflectionReceipt? {
        await waitForMaintenanceTransition()
        let integrationEnabled = configuration.enabled && configuration.reflectiveCallsEnabled
        // Only a live issued reservation may settle; nil or expired tokens cannot release a newer claim.
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
        receipt.journalPending = journalPending
        // Retain the judgment before any effect. Errors are observations, never gates; the pending flags below name work, not the last attempt.
        if integrationEnabled, !cancelled, let judgment {
            receipt.careIntegrationPending = true
            receipt.dispositionSaveFailed = judgment.affect != nil
            receipt.integrationEpoch = mindEpoch
        } else if cancelled || !integrationEnabled {
            receipt.integrationSkipped = cancelled ? "cancelled" : "reflection disabled"
        }
        reflectionReceipts[receipt.id] = receipt
        enforceReflectionReceiptCap()
        return receipt
    }

    /// Checkpoint the provider's input and judgment before any care or mood mutation. The dream journal also retains this receipt as its step input.
    public func checkpointReflectionResultChecked(_ receipt: CognitiveReflectionReceipt, requirePersistence: Bool = false) async throws {
        try requireIntegratedReflectionReceipt(receipt)
        let durable = requirePersistence || receipt.journalPending == true
        if durable, !configuration.persistenceEnabled { throw CognitivePersistenceError.storeUnavailable }
        if durable, !persistenceRestored || persistenceHealth.writesBlocked {
            throw CognitivePersistenceError.artifactWriteFailed(family: "reflection_receipt", detail: "cognition/cognition.sqlite is unavailable")
        }
        try await persistArtifactTransition(artifacts: reflectionEffectArtifacts(receipt, at: dependencies.now()),
            deletedArtifactIDs: [], at: dependencies.now())
        if durable, !configuration.persistenceEnabled { throw CognitivePersistenceError.storeUnavailable }
    }

    /// Resume only the effects of a retained judgment. Prefer the live owner: the journal's receipt is input, never a second progress authority.
    public func persistReflectionResultChecked(_ input: CognitiveReflectionReceipt) async throws {
        await waitForMaintenanceTransition()
        if input.journalPending == true, !persistenceRestored || persistenceHealth.writesBlocked {
            throw CognitivePersistenceError.artifactWriteFailed(family: "reflection_receipt", detail: "cognition/cognition.sqlite is unavailable")
        }
        if reflectionReceipts[input.id] == nil {
            guard input.integrationEpoch == mindEpoch else { throw CognitiveWriteDiscarded() }
            reflectionReceipts[input.id] = input
        }
        guard var receipt = reflectionReceipts[input.id] else { throw CognitiveWriteDiscarded() }
        if receipt.journalPending == true, !configuration.persistenceEnabled { throw CognitivePersistenceError.storeUnavailable }
        if let epoch = receipt.integrationEpoch, epoch != mindEpoch { throw CognitiveWriteDiscarded() }
        if receipt.careIntegrationPending == true, configuration.enabled, configuration.reflectiveCallsEnabled {
            try await applyReflectionCares(receipt: receipt)
            guard let current = reflectionReceipts[input.id] else { throw CognitiveWriteDiscarded() }
            receipt = current
        } else if receipt.careIntegrationPending == true {
            receipt.careIntegrationPending = false
            receipt.dispositionSaveFailed = false
            receipt.integrationSkipped = "reflection disabled"
            reflectionReceipts[receipt.id] = receipt
        }
        let at = dependencies.now()
        let previous = disposition
        var nudged = false
        if receipt.dispositionSaveFailed {
            if !configuration.enabled || !configuration.reflectiveCallsEnabled {
                receipt.integrationSkipped = "reflection disabled"
            } else {
                guard let tone = receipt.judgment?.affect else {
                    throw CognitivePersistenceError.artifactWriteFailed(family: "reflection_disposition", detail: "retained affect input is missing")
                }
                if !reflectionDispositionClaims.contains(receipt.id) {
                    if tone != 0 {
                        integrateDispositionInMemory(tone: tone, at: at, source: "reflection")
                        nudged = true
                    }
                    reflectionDispositionClaims.insert(receipt.id)
                }
            }
            receipt.dispositionSaveFailed = false
            reflectionReceipts[receipt.id] = receipt
            dirtyRevision &+= 1
        }
        let artifacts = try reflectionEffectArtifacts(receipt, at: at)
        let written = disposition
        // On failure the resident values and done flags stay together. The next attempt writes them; it does not apply them again. On restart their atomic
        // receipt is the witness that the effects already landed.
        try await persistArtifactTransition(artifacts: artifacts, deletedArtifactIDs: [], at: at)
        if receipt.journalPending == true, !configuration.persistenceEnabled { throw CognitivePersistenceError.storeUnavailable }
        try requireIntegratedReflectionReceipt(receipt)
        if nudged {
            await recordDispositionUndo(what: "undertone nudge: reflection", previous: .object([
                "valence": .double(previous.valence), "updatedAt": .double(previous.updatedAt.timeIntervalSince1970)
            ]), stamp: Self.undoStamp(written))
        }
    }

    private func reflectionEffectArtifacts(_ receipt: CognitiveReflectionReceipt, at: Date) throws -> [CognitiveArtifactWrite] {
        var artifacts = try receipt.affectedCareIDs.map { id -> CognitiveArtifactWrite in
            guard let care = cares[id] else {
                throw CognitiveCareNotSaved(detail: "retained reflection care missing: " + id.uuidString)
            }
            return CognitiveArtifactWrite(kind: "care", id: id, status: care.fadedAt == nil ? "live" : "faded",
                score: min(1, abs(care.charge(at: at))), payload: try Self.careJSON(care))
        }
        artifacts.append(CognitiveArtifactWrite(kind: "reflection_receipt", id: receipt.id,
            status: receipt.persistenceStatus, score: 0, payload: receipt.toJSON()))
        if reflectionDispositionClaims.contains(receipt.id) {
            artifacts.append(CognitiveArtifactWrite(kind: "disposition", id: stableArtifactID("disposition"),
                status: "current", score: (disposition.valence + 1) / 2, payload: dispositionArtifactPayload(at: at)))
        }
        return artifacts
    }

    public func acknowledgeDreamReflection(_ id: UUID) async throws {
        await waitForMaintenanceTransition()
        // A repeated acknowledgment after its journal checkpoint failed may find a pruned, already settled receipt; no effect is owed here.
        guard var receipt = reflectionReceipts[id] else { return }
        guard receipt.careIntegrationPending != true, !receipt.dispositionSaveFailed else {
            throw CognitivePersistenceError.artifactWriteFailed(family: "reflection_receipt", detail: "reflection effects remain owed")
        }
        receipt.journalPending = false
        reflectionReceipts[id] = receipt
        try await checkpointReflectionResultChecked(receipt, requirePersistence: true)
    }

    private func requireIntegratedReflectionReceipt(_ receipt: CognitiveReflectionReceipt) throws {
        guard reflectionReceipts[receipt.id] == receipt else {
            throw CognitivePersistenceError.artifactWriteFailed(family: "reflection_receipt",
                detail: "receipt is not the substrate's retained judgment")
        }
    }

    public func reflectionReceiptSnapshot() async -> [CognitiveReflectionReceipt] {
        reflectionReceipts.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Stable refusal strings keep loop outcomes and receipts consistent.
    public static let reflectionRefusalDisabled = "reflection_disabled"
    public static let reflectionRefusalCeilingReached = "reflection_cost_ceiling_reached"
    public static let reflectionRefusalInFlight = "reflection_in_flight"
    static let reflectionAdmittedReason = "admitted"

    /// A rolling window lets quiet hours leave room for harder hours without freeing slots at midnight.
    static let reflectionCostWindow: TimeInterval = 24 * 60 * 60

    /// Read spent calls from their receipt owner; do not mirror the ledger.
    func reflectionCallsInCostWindow(at now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Self.reflectionCostWindow)
        return reflectionReceipts.values.filter { $0.createdAt > cutoff }.count
    }

    /// Evidence-driven reflection shares the receipt budget and reservation.
    public func reflectionAdmission() async -> CognitiveReflectionAdmission {
        let now = dependencies.now()
        let ceiling = configuration.dailyReflectionCallBudget
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
        return CognitiveReflectionAdmission(
            admitted: refusal == nil,
            reason: refusal ?? Self.reflectionAdmittedReason,
            callsInWindow: spent,
            ceiling: ceiling
        )
    }

    /// Unknown peer provenance remains tainted.
    func reflectionIsTainted(_ request: CognitiveReflectionRequest) -> Bool {
        guard let peers = request.sourcePeerIds else { return true }
        return peers.contains { !dependencies.peerTrusted($0) }
    }

    /// Agent sessions use `peer:<uuid>`; built-in sessions use their surface name. Unknown peer identity grants no trust.
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

    private func applyReflectionCares(receipt: CognitiveReflectionReceipt) async throws {
        guard let judgment = receipt.judgment else {
            throw CognitivePersistenceError.artifactWriteFailed(family: "reflection_care", detail: "retained judgment input is missing")
        }
        if reflectionIsTainted(receipt.request) {
            var skipped = receipt
            skipped.careIntegrationPending = false
            reflectionReceipts[receipt.id] = skipped
            return
        }
        let generation = caringAppraisalGeneration
        var view: String?, because = "", unless = ""
        for raw in judgment.reflection.split(whereSeparator: \.isNewline) {
            let line = Self.normalizedProposalLine(raw).replacingOccurrences(of: "**", with: "")
            let lower = line.lowercased()
            func rest(_ prefix: String) -> String {
                String(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if lower.hasPrefix("view:"), view == nil { view = rest("view:") }
            else if lower.hasPrefix("because:") { because = rest("because:") }
            else if lower.hasPrefix("unless:") { unless = rest("unless:") }
        }
        // Both judgments are prepared before applying either. A takeaway joins the view's care inside the synchronous mutation, unless it is a root.
        let key = receipt.judgment?.care?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = key.flatMap { key in receipt.request.cares.first { $0.key.lowercased() == key }?.id }
        var judgments: [CognitiveCareJudgment] = []
        let stance = view.flatMap { text -> CognitiveCare.Stance? in
            guard !text.isEmpty, !judgment.sources.isEmpty else { return nil }
            return .init(text: text, because: because, wouldChangeMind: unless)
        }
        var candidates: [(String, CognitiveCare.Stance?, String?)] = []
        if let stance { candidates.append((stance.text, stance, nil)) }
        if let takeaway = judgment.takeaway { candidates.append((takeaway, nil, takeaway)) }
        for (text, stance, open) in candidates {
            let target: CognitiveCareJudgment.Target
            if let key, key != "new" {
                guard let named, let care = cares[named], care.fadedAt == nil,
                      open == nil || care.origin != .seed else {
                    await recordReceipt(kind: "reflection.care_refused", payload: .object([
                        "reflectionId": .string(receipt.id.uuidString), "care": .string(key),
                        "cause": .string(named == nil ? "target was not offered" : "target is absent, faded or cannot hold an open question"),
                    ]))
                    continue
                }
                target = .existing(named)
            } else {
                target = .new(about: careTitle(from: text), between: false)
            }
            judgments.append(CognitiveCareJudgment(target: target, moved: 0, by: .her, felt: "reflected",
                note: "my reflection", open: open, stance: stance))
        }
        _ = try await applyCareJudgments(judgments,
            provenance: .init(speaker: CognitiveCare.ownerKey, trusted: true, appAuthored: true,
                            source: "reflection:" + receipt.id.uuidString, at: receipt.createdAt),
            generation: generation, reflectionReceipt: receipt,
            joinReflectionTakeaway: key == nil || key == "new")
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

}
