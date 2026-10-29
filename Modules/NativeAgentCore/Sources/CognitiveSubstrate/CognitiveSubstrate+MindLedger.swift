// CognitiveSubstrate+MindLedger.swift
// The `mind_ledger` artifact holds bounded suppressions and one disposition undo.
// Every selector honors source/context suppressions; undo refuses changes newer than the update it reverses.

import Foundation
import NativeAgentCore
import PersistenceCore
import Studio

// Blueprint: | `CognitiveSubstrate+MindLedger.swift` | `CognitiveSubstrate` mind ledger: bounded association suppressions and one disposition undo, persistence and restoration |

public struct CognitiveAssociationSuppression: Sendable, Equatable {
    /// `memory:<record id>`, `care:<uuid>` or `dream:<date>#<n>`;
    /// an outreach subject may also be `desk:<handle>` or `ship:<builder>[:<id>]`.
    public var source: String
    /// The signature of the turn it surfaced on. Empty means never.
    public var terms: [String]
    public var at: Date
}

public struct CognitiveUndoEntry: Sendable, Equatable {
    /// `disposition`.
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
    static func associationTermsMatch(_ queryTerm: String, _ documentTerm: String) -> Bool {
        if queryTerm == documentTerm { return true }
        let inflectionSuffixes: Set<String> = ["s", "es", "ed", "ing", "er", "ers", "ion", "ions"]
        let (short, long) = queryTerm.count < documentTerm.count
            ? (queryTerm, documentTerm) : (documentTerm, queryTerm)
        guard short.count >= associationMinimumTermLength,
              long.hasPrefix(short) else { return false }
        return inflectionSuffixes.contains(String(long.dropFirst(short.count)))
    }

    static let maximumAssociationSuppressions = 48
    static let associationSignatureTermCap = 8

    // MARK: - Association signature

    /// What a turn is about, as a few content terms: the context half of a
    /// suppression and of every `mind.why` record. Same tokenizer the
    /// continuity matching uses.
    public static func associationSignature(_ text: String) -> [String] {
        Array(associationTerms(in: text).prefix(associationSignatureTermCap)).sorted()
    }

    /// A suppression covers a message that shares at least two of its terms
    /// (all of them when it has fewer). No terms: always.
    public static func suppressionCovers(_ terms: [String], messageTerms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let shared = terms.filter { term in messageTerms.contains { associationTermsMatch($0, term) } }.count
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
        // Her own live turn, never a bridge.
        guard seat.isComplete else { return "a rejection is made from inside your own turn" }
        let source = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard ["memory:", "care:", "dream:", "desk:", "ship:"].contains(where: source.hasPrefix), source.count > 6 else {
            return "source must be memory:<id>, care:<id>, dream:<id>, desk:<handle> or ship:<builder>[:<id>]"
        }
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

    public func associationSuppressionSnapshot() -> [CognitiveAssociationSuppression] {
        associationSuppressions
    }

    // MARK: - Undo

    static func undoStamp(_ disposition: CognitiveDisposition) -> String {
        "\(disposition.valence)|\(disposition.updatedAt.timeIntervalSince1970)"
    }

    /// The newest undertone update replaces the previous undo.
    func recordDispositionUndo(what: String, previous: JSONValue, stamp: String) async {
        dispositionUndo = .init(
            key: "disposition", what: bounded(what, maxCharacters: 160), previous: previous,
            stamp: stamp, at: dependencies.now())
        await notingPersistence("mind_ledger") { try await persistMindLedger() }
    }

    public func undoSnapshot() -> [CognitiveUndoEntry] { dispositionUndo.map { [$0] } ?? [] }

    /// Reverse ONE update of hers. Compare-and-set: the item must still hold
    /// the value that update left, else the call is refused with what it holds
    /// now and nothing changes.
    public func undoUpdate(key: String, seat: StudioCanonTurnProvenance) async -> CognitiveUndoOutcome {
        guard seat.isComplete else {
            return .refused(reason: "an undo is made from inside your own turn", current: .null)
        }
        await waitForMaintenanceTransition()
        guard key == "disposition", let entry = dispositionUndo else {
            return .refused(reason: "nothing of yours to undo for \(key)", current: .null)
        }
        beginMaintenanceTransition()
        defer { endMaintenanceTransition() }
        let now = dependencies.now()
        let current = disposition
        guard Self.undoStamp(current) == entry.stamp else {
            return .refused(reason: "your undertone moved again since that update",
                            current: .object(["valence": .double(current.valence)]))
        }
        guard case .object(let prior) = entry.previous,
              let valence = prior["valence"]?.numberValue(coercingStrings: false, finiteOnly: false),
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
        let writtenTransitions = dispositionTransitions
        // The item and consumption of its retry entry are one durable change.
        let artifacts = [
            CognitiveArtifactWrite(
                kind: "disposition", id: stableArtifactID("disposition"), status: "current",
                score: (valence + 1) / 2, payload: dispositionArtifactPayload(at: updatedAt)),
            CognitiveArtifactWrite(
                kind: "mind_ledger", id: stableArtifactID("mind_ledger"), status: "current", score: 0,
                payload: mindLedgerArtifactPayload(at: now, undoEntry: nil)),
        ]
        do {
            try await persistArtifactTransition(artifacts: artifacts, deletedArtifactIDs: [], at: now)
        } catch {
            if disposition == restored { disposition = current }
            if dispositionTransitions == writtenTransitions { dispositionTransitions = previousTransitions }
            markDirty(at: dependencies.now())
            publishAttentionProjection(at: dependencies.now())
            return .refused(reason: "the undo was not saved; you can retry: \(error)",
                            current: .object(["valence": .double(current.valence)]))
        }
        // Only the entry this call undid: a newer update of the same item may
        // have recorded its own while the write above was suspended.
        if dispositionUndo == entry { dispositionUndo = nil }
        await recordReceipt(kind: "mind.undo", payload: .object([
            "item": .string(key), "what": .string(entry.what),
        ]))
        publishAttentionProjection(at: now)
        return .undone(what: entry.what)
    }

    // MARK: - Persistence (one row)

    func persistMindLedger() async throws {
        try await persistArtifactChecked(
            kind: "mind_ledger", id: stableArtifactID("mind_ledger"), status: "current", score: 0,
            payload: mindLedgerArtifactPayload(at: dependencies.now(), undoEntry: dispositionUndo))
    }

    func mindLedgerArtifactPayload(at now: Date, undoEntry: CognitiveUndoEntry?) -> JSONValue {
        let suppressions: [JSONValue] = associationSuppressions.map {
            .object([
                "source": .string($0.source),
                "terms": .array($0.terms.map { .string($0) }),
                "at": .double($0.at.timeIntervalSince1970),
            ])
        }
        let undo: [JSONValue] = (undoEntry.map { [$0] } ?? []).map {
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
        dispositionUndo = nil
        guard case .object(let object)? = payloads.first else { return }
        if case .array(let rows)? = object["suppressions"] {
            for case .object(let row) in rows {
                guard let source = row["source"]?.stringValue,
                      ["memory:", "care:", "dream:", "desk:", "ship:"].contains(where: source.hasPrefix),
                      let at = dateValue(row["at"]) else { continue }
                var terms: [String] = []
                if case .array(let values)? = row["terms"] { terms = values.compactMap { $0.stringValue } }
                associationSuppressions.append(.init(source: source, terms: terms, at: at))
            }
            associationSuppressions = Array(associationSuppressions.suffix(Self.maximumAssociationSuppressions))
        }
        if case .array(let rows)? = object["undo"] {
            for case .object(let row) in rows {
                guard let key = row["key"]?.stringValue, key == "disposition", let stamp = row["stamp"]?.stringValue,
                      let at = dateValue(row["at"]) else { continue }
                dispositionUndo = .init(
                    key: key, what: row["what"]?.stringValue ?? key, previous: row["previous"] ?? .null,
                    stamp: stamp, at: at)
            }
        }
    }
}
