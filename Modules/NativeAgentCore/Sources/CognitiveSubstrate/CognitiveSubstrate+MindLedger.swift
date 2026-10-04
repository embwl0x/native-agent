// CognitiveSubstrate+MindLedger.swift
// Phase 5 B0 (2026-10-03) — her two corrective verbs over her own mind.
//
// Agent: "reject a bad association, and reverse an update without rewriting my
// whole history." Two bounded lists in ONE artifact row (`mind_ledger`):
//   * suppressions — (source, context signature): this memory, view or seed
//     must not surface for this kind of thing. Every selector that can surface
//     the source honors it (the felt cue, the unbidden recall, the memory lane).
//   * undo — the PREVIOUS value of each item her own update changed, just the
//     previous, keyed by item. Undo restores that one item only, and only while
//     the item still holds the value that update left; anything newer is a
//     conflict and is refused with the current value.

import Foundation
import NativeAgentCore
import PersistenceCore
import Studio

public struct CognitiveAssociationSuppression: Sendable, Equatable {
    /// `memory:<record id>`, `view:<uuid>`, `seed:<uuid>` or `dream:<date>#<n>`;
    /// an outreach subject may also be `desk:<handle>` or `ship:<builder>[:<id>]`.
    public var source: String
    /// The signature of the turn it surfaced on. Empty means never.
    public var terms: [String]
    public var at: Date
}

public struct CognitiveUndoEntry: Sendable, Equatable {
    /// `view:<uuid>`, `seed:<uuid>` or `disposition`.
    public var key: String
    public var what: String
    /// The item before the update; `.null` when the update created it.
    public var previous: JSONValue
    /// The value the update left. Undo applies only over exactly that.
    public var stamp: String
    public var at: Date
}

public enum CognitiveUndoOutcome: Sendable, Equatable {
    case undone(what: String)
    case refused(reason: String, current: JSONValue)
}

extension CognitiveSubstrate {
    static let maximumAssociationSuppressions = 48
    static let maximumUndoEntries = 24
    static let associationSignatureTermCap = 8

    // MARK: - Association signature

    /// What a turn is about, as a few content terms: the context half of a
    /// suppression and of every `mind.why` record. Same tokenizer the
    /// standing-view relevance uses.
    public static func associationSignature(_ text: String) -> [String] {
        Array(appraisalConcernTerms(in: text).prefix(associationSignatureTermCap)).sorted()
    }

    /// A suppression covers a message that shares at least two of its terms
    /// (all of them when it has fewer). No terms: always.
    public static func suppressionCovers(_ terms: [String], messageTerms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let shared = terms.filter { term in messageTerms.contains { standingViewTermsMatch($0, term) } }.count
        return shared >= min(2, terms.count)
    }

    func isSuppressed(_ source: String, messageTerms: [String]) -> Bool {
        associationSuppressions.contains {
            $0.source == source && Self.suppressionCovers($0.terms, messageTerms: messageTerms)
        }
    }

    /// Memory record id → signature, for the context lane's attention read.
    func suppressedMemoryAssociations() -> [String: [[String]]] {
        var out: [String: [[String]]] = [:]
        for row in associationSuppressions where row.source.hasPrefix("memory:") {
            out[String(row.source.dropFirst(7)), default: []].append(row.terms)
        }
        return out
    }

    /// She rejects one association. Idempotent per (source, signature); the
    /// oldest drops past the cap.
    @discardableResult
    public func rejectAssociation(
        source: String,
        terms: [String],
        seat: StudioCanonTurnProvenance
    ) async -> String? {
        // The same seat hold/release use: her own live turn, never a bridge.
        guard seat.isComplete else { return "a rejection is made from inside your own turn" }
        let source = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard ["memory:", "view:", "seed:", "dream:", "desk:", "ship:"].contains(where: source.hasPrefix), source.count > 6 else {
            return "source must be memory:<id>, view:<id>, seed:<id>, dream:<id>, desk:<handle> or ship:<builder>[:<id>]"
        }
        if let refusal = rejectionRefusal(source) { return refusal }
        let terms = Array(terms.prefix(Self.associationSignatureTermCap)).sorted()
        associationSuppressions.removeAll { $0.source == source && $0.terms == terms }
        associationSuppressions.append(.init(source: source, terms: terms, at: dependencies.now()))
        if associationSuppressions.count > Self.maximumAssociationSuppressions {
            associationSuppressions.removeFirst(associationSuppressions.count - Self.maximumAssociationSuppressions)
        }
        publishAttentionProjection(at: dependencies.now())
        await recordReceipt(kind: "mind.reject", payload: .object([
            "source": .string(source), "terms": .array(terms.map { .string($0) }),
        ]))
        do { try await persistMindLedger() } catch { return "kept for this session, not saved: \(error)" }
        return nil
    }

    /// User's authority, never hers to suppress: a view he signed, a concern
    /// he pinned. (Memory authority — pinned core, corrections, safety — is
    /// checked by the runtime, which can read the memory store.)
    func rejectionRefusal(_ source: String) -> String? {
        if source.hasPrefix("view:"), let id = UUID(uuidString: String(source.dropFirst(5))),
           standingViews[id]?.status == .active {
            return "User signed that view; it is his to retire, not yours to suppress"
        }
        if source.hasPrefix("seed:"), let id = UUID(uuidString: String(source.dropFirst(5))),
           thoughtSeeds[id]?.text.hasPrefix("Pinned concern:") == true {
            return "User pinned that concern; it is not yours to suppress"
        }
        return nil
    }

    public func associationSuppressionSnapshot() -> [CognitiveAssociationSuppression] {
        associationSuppressions
    }

    // MARK: - Undo

    static func undoStamp(_ view: CognitiveStandingView?) -> String {
        guard let view else { return "none" }
        return "\(view.status.rawValue)|\(view.updatedAt.timeIntervalSince1970)|\(view.revisitCount)|\(view.evidenceExcerpts.count)"
    }

    /// Decay rewrites a seed's priority and clock, so a seed's stamp is what an
    /// update changes: its wording and its evidence.
    static func undoStamp(_ seed: CognitiveThoughtSeed?) -> String {
        guard let seed else { return "none" }
        let stamp = "\(seed.text)|\(seed.sourceNodeIds.count)|\(seed.createdAt.timeIntervalSince1970)"
        guard seed.sourcePeerIds != nil || !seed.materialProvenances.isEmpty else { return stamp }
        let peers = seed.sourcePeerIds.map { $0.sorted().joined(separator: ",") } ?? "unknown"
        return "\(stamp)|\(peers)|\(seed.materialProvenances)"
    }

    static func undoStamp(_ disposition: CognitiveDisposition) -> String {
        "\(disposition.valence)|\(disposition.updatedAt.timeIntervalSince1970)"
    }

    /// One entry per item, newest last; the oldest drops past the cap.
    func recordUndo(key: String, what: String, previous: JSONValue, stamp: String) async {
        undoLedger.removeAll { $0.key == key }
        undoLedger.append(.init(
            key: key, what: bounded(what, maxCharacters: 160), previous: previous,
            stamp: stamp, at: dependencies.now()))
        if undoLedger.count > Self.maximumUndoEntries {
            undoLedger.removeFirst(undoLedger.count - Self.maximumUndoEntries)
        }
        try? await persistMindLedger()
    }

    public func undoSnapshot() -> [CognitiveUndoEntry] { undoLedger }

    /// Reverse ONE update of hers. Compare-and-set: the item must still hold
    /// the value that update left, else the call is refused with what it holds
    /// now and nothing changes.
    public func undoUpdate(key: String, seat: StudioCanonTurnProvenance) async -> CognitiveUndoOutcome {
        guard seat.isComplete else {
            return .refused(reason: "an undo is made from inside your own turn", current: .null)
        }
        await waitForMaintenanceTransition()
        guard let entry = undoLedger.last(where: { $0.key == key }) else {
            return .refused(reason: "nothing of yours to undo for \(key)", current: .null)
        }
        beginMaintenanceTransition()
        defer { endMaintenanceTransition() }
        let now = dependencies.now()
        var artifacts: [CognitiveArtifactWrite] = []
        var deletedArtifactIDs: [UUID] = []
        let rollback: () -> Void
        let previousValue: JSONValue
        if key == "disposition" {
            let current = disposition
            guard Self.undoStamp(current) == entry.stamp else {
                return .refused(reason: "your undertone moved again since that update",
                                current: .object(["valence": .double(current.valence)]))
            }
            guard case .object(let prior) = entry.previous,
                  let valence = doubleValue(prior["valence"]),
                  let updatedAt = dateValue(prior["updatedAt"]) else {
                return .refused(reason: "no previous undertone kept", current: .null)
            }
            let previousTransitions = dispositionTransitions
            let restored = CognitiveDisposition(valence: valence, updatedAt: updatedAt)
            disposition = restored
            dispositionTransitions.append(CognitiveDispositionTransition(
                before: current.valence, afterDecay: current.valence, afterContribution: valence,
                at: now, source: bounded("undo: \(entry.what)", maxCharacters: 60)))
            if dispositionTransitions.count > Self.maximumDispositionTransitions {
                dispositionTransitions.removeFirst(dispositionTransitions.count - Self.maximumDispositionTransitions)
            }
            dirtyRevision &+= 1
            artifacts.append(CognitiveArtifactWrite(
                kind: "disposition", id: stableArtifactID("disposition"), status: "current",
                score: (valence + 1) / 2, payload: dispositionArtifactPayload(at: updatedAt)))
            let writtenTransitions = dispositionTransitions
            previousValue = .object(["valence": .double(current.valence)])
            rollback = {
                if self.disposition == restored { self.disposition = current }
                if self.dispositionTransitions == writtenTransitions {
                    self.dispositionTransitions = previousTransitions
                }
            }
        } else if key.hasPrefix("view:"), let id = UUID(uuidString: String(key.dropFirst(5))) {
            let current = standingViews[id]
            guard Self.undoStamp(current) == entry.stamp else {
                return .refused(reason: "that view changed again since your update",
                                current: current?.toJSON() ?? .null)
            }
            let prior = standingView(fromPayload: entry.previous)
            if prior?.status == .held, current?.status != .held,
               standingViews.values.filter({ $0.status == .held }).count >= Self.maximumHeldStandingViews {
                return .refused(reason: "you already hold \(Self.maximumHeldStandingViews) views; release one first",
                                current: current?.toJSON() ?? .null)
            }
            if let prior { standingViews[id] = prior } else { standingViews.removeValue(forKey: id) }
            markDirty(at: now)
            if let prior, prior.status != .retired {
                artifacts.append(CognitiveArtifactWrite(
                    kind: "standing_view", id: id, status: prior.status.rawValue,
                    score: max(0, prior.moodValenceAtFormation), payload: prior.toJSON()))
            } else {
                deletedArtifactIDs.append(id)
            }
            previousValue = current?.toJSON() ?? .null
            rollback = {
                if self.standingViews[id] == prior {
                    self.standingViews[id] = current
                }
            }
        } else if key.hasPrefix("seed:"), let id = UUID(uuidString: String(key.dropFirst(5))) {
            let current = thoughtSeeds[id]
            guard Self.undoStamp(current) == entry.stamp else {
                return .refused(reason: "that thought changed again since your update",
                                current: current?.toJSON() ?? .null)
            }
            let prior = thoughtSeed(fromPayload: entry.previous)
            if let prior {
                thoughtSeeds[id] = prior
                artifacts.append(CognitiveArtifactWrite(
                    kind: "thought_seed", id: id, status: "open", score: prior.priority, payload: prior.toJSON()))
            } else {
                thoughtSeeds.removeValue(forKey: id)
                deletedArtifactIDs.append(id)
            }
            thoughtSeedRevision &+= 1
            markDirty(at: now)
            previousValue = current?.toJSON() ?? .null
            rollback = {
                if self.thoughtSeeds[id] == prior {
                    self.thoughtSeeds[id] = current
                    self.thoughtSeedRevision &+= 1
                }
            }
        } else {
            return .refused(reason: "unknown item \(key)", current: .null)
        }
        // The item and consumption of its retry entry are one durable change.
        artifacts.append(CognitiveArtifactWrite(
            kind: "mind_ledger", id: stableArtifactID("mind_ledger"), status: "current", score: 0,
            payload: mindLedgerArtifactPayload(at: now, undoEntries: undoLedger.filter { $0 != entry })))
        do {
            try await persistArtifactTransition(artifacts: artifacts, deletedArtifactIDs: deletedArtifactIDs, at: now)
        } catch {
            rollback()
            markDirty(at: dependencies.now())
            publishAttentionProjection(at: dependencies.now())
            return .refused(reason: "the undo was not saved; you can retry: \(error)", current: previousValue)
        }
        // Only the entry this call undid: a newer update of the same item may
        // have recorded its own while the write above was suspended.
        undoLedger.removeAll { $0 == entry }
        await recordReceipt(kind: "mind.undo", payload: .object([
            "item": .string(key), "what": .string(entry.what),
        ]))
        publishAttentionProjection(at: now)
        return .undone(what: entry.what)
    }

    // MARK: - Persistence (one row, both lists capped)

    func persistMindLedger() async throws {
        try await persistArtifactChecked(
            kind: "mind_ledger", id: stableArtifactID("mind_ledger"), status: "current", score: 0,
            payload: mindLedgerArtifactPayload(at: dependencies.now()))
    }

    func mindLedgerArtifactPayload(at now: Date, undoEntries: [CognitiveUndoEntry]? = nil) -> JSONValue {
        let suppressions: [JSONValue] = associationSuppressions.map {
            .object([
                "source": .string($0.source),
                "terms": .array($0.terms.map { .string($0) }),
                "at": .double($0.at.timeIntervalSince1970),
            ])
        }
        let undo: [JSONValue] = (undoEntries ?? undoLedger).map {
            .object([
                "key": .string($0.key),
                "what": .string($0.what),
                "previous": $0.previous,
                "stamp": .string($0.stamp),
                "at": .double($0.at.timeIntervalSince1970),
            ])
        }
        return .object([
            "updatedAt": .double(now.timeIntervalSince1970),
            "suppressions": .array(suppressions),
            "undo": .array(undo),
        ])
    }

    func restoreMindLedger(from payloads: [JSONValue]) {
        associationSuppressions = []
        undoLedger = []
        guard case .object(let object)? = payloads.first else { return }
        if case .array(let rows)? = object["suppressions"] {
            for case .object(let row) in rows {
                guard let source = stringValue(row["source"]), let at = dateValue(row["at"]) else { continue }
                var terms: [String] = []
                if case .array(let values)? = row["terms"] { terms = values.compactMap { stringValue($0) } }
                associationSuppressions.append(.init(source: source, terms: terms, at: at))
            }
            associationSuppressions = Array(associationSuppressions.suffix(Self.maximumAssociationSuppressions))
        }
        if case .array(let rows)? = object["undo"] {
            for case .object(let row) in rows {
                guard let key = stringValue(row["key"]), let stamp = stringValue(row["stamp"]),
                      let at = dateValue(row["at"]) else { continue }
                undoLedger.append(.init(
                    key: key, what: stringValue(row["what"]) ?? key, previous: row["previous"] ?? .null,
                    stamp: stamp, at: at))
            }
            undoLedger = Array(undoLedger.suffix(Self.maximumUndoEntries))
        }
    }
}
