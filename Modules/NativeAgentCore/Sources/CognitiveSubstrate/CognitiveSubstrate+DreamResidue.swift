import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+DreamResidue.swift` | `CognitiveSubstrate` dream contribution: single-flight integration, night claims, residue minting, consumption and persistence; `CognitiveDreamResidue` |

extension CognitiveSubstrate {
    /// Persist explicit dream tone through night claims, disposition decay and residue, without classifying prose.
    @discardableResult
    public func integrateDreamDisposition(
        tone: Double,
        at now: Date,
        dreamId: String? = nil
    ) async -> Bool {
        let night = dreamResidueKey(for: dreamId, at: now)
        if let integration = dreamIntegrations[night] { return await integration.value }
        // Publish before suspending so duplicate deliveries join both writes and share their durable outcome.
        let integration = Task {
            await integrateDreamDispositionOnce(tone: tone, at: now, dreamId: dreamId)
        }
        dreamIntegrations[night] = integration
        defer { dreamIntegrations[night] = nil }
        return await integration.value
    }

    private func integrateDreamDispositionOnce(tone: Double, at now: Date, dreamId: String?) async -> Bool {
        await waitForMaintenanceTransition()
        // Each dream-integration write holds its own durable night claim so retries apply each half once.
        let night = dreamResidueKey(for: dreamId, at: now)
        let dispositionPersisted = dreamDispositionNight == night
            ? true
            : await integrateDisposition(
                tone: tone, at: now, dreamNight: night, source: "dream \(night)", undoable: true)
        // Mint residue at the committed dream's integration point.
        let residuePersisted = await mintDreamResidue(tone: tone, at: now, dreamId: dreamId)
        return dispositionPersisted && residuePersisted
    }

    /// Claim by committed dream id, else local calendar day, so re-rendering the same dream is inert.
    func dreamResidueKey(for dreamId: String?, at now: Date) -> String {
        if let dreamId {
            let trimmed = dreamId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return bounded(trimmed, maxCharacters: 80) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(
            format: "day-%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// How many accepted turns the night colors.
    static let dreamResidueTurns = 2
    /// A small saturating affect delta colors the waking room without overriding it.
    static let dreamResidueLean = 0.07
    /// Residue expires after this interval regardless of remaining turns.
    static let dreamResidueLifetime: TimeInterval = 8 * 60 * 60

    /// Returns whether the residue claim is durable; nothing to mint counts as durable.
    @discardableResult
    func mintDreamResidue(tone: Double, at now: Date, dreamId: String? = nil) async -> Bool {
        guard configuration.enabled, tone != 0 else {
            return true
        }
        let key = dreamResidueKey(for: dreamId, at: now)
        // A durable night claim prevents residue re-minting across rerenders and restarts.
        guard dreamResidueClaimKey != key else { return true }
        let valence = (tone.clampedSigned() * 0.35).clampedSigned()
        let previousClaimKey = dreamResidueClaimKey
        let previousResidue = dreamResidue
        dreamResidueClaimKey = key
        dreamResidue = CognitiveDreamResidue(
            valence: valence,
            mintedAt: now,
            turnsRemaining: Self.dreamResidueTurns
        )
        // Minting awaits claim persistence before reporting integration.
        let claimPersisted = await persistDreamResidueClaimChecked()
        // A claim that fails to reach disk must also be released in memory.
        guard claimPersisted else {
            if dreamResidueClaimKey == key {
                dreamResidueClaimKey = previousClaimKey
                dreamResidue = previousResidue
            }
            return false
        }
        // One story-free felt node per night; the field's seen-event check makes replay inert.
        let event = CognitiveEvent(
            id: "dream_residue:\(key)",
            kind: .appWake,
            subject: CognitiveSubjectReference(
                type: "night",
                id: "the night",
                label: "the night"
            ),
            sourceClass: .selfReported,
            occurredAt: now,
            // Deliberately empty: a residue has no story.
            summary: "",
            importance: min(1, 0.35 + abs(valence)),
            // Live state keeps the night in mood; `.appWake` otherwise defaults to system traffic.
            turnKind: .live,
            metadata: [
                CognitiveEvent.feltValenceMetadataKey: .double(valence),
                CognitiveEvent.feltArousalMetadataKey: .double(0.12),
                "dreamResidue": .bool(true),
            ]
        )
        await ingestResident(event)
        return true
    }

    /// A stale residue reads as zero without mutation; the next write boundary clears it.
    func dreamResidueLean(at now: Date) -> Double {
        guard let residue = dreamResidue, residue.turnsRemaining > 0 else { return 0 }
        guard now.timeIntervalSince(residue.mintedAt) <= Self.dreamResidueLifetime else { return 0 }
        return residue.valence * Self.dreamResidueLean
    }

    /// Affect apply spends each accepted live turn here, dropping spent or stale residue at this write boundary.
    func consumeDreamResidueTurn(at now: Date) {
        guard var residue = dreamResidue else { return }
        residue.turnsRemaining -= 1
        if residue.turnsRemaining <= 0
            || now.timeIntervalSince(residue.mintedAt) > Self.dreamResidueLifetime {
            dreamResidue = nil
        } else {
            dreamResidue = residue
        }
    }

    /// Minting checks the durable night claim before admitting its felt node.
    func persistDreamResidueClaimChecked() async -> Bool {
        guard configuration.enabled, configuration.persistenceEnabled else { return true }
        do {
            try await persistArtifactChecked(
                kind: "dream_residue",
                id: stableArtifactID("dream_residue"),
                status: "current",
                score: 0,
                payload: dreamResidueArtifactPayload(at: dependencies.now())
            )
            return true
        } catch {
            return false
        }
    }

    func dreamResidueArtifactPayload(at now: Date) -> JSONValue {
        var object: [String: JSONValue] = [
            "updatedAt": .double(now.timeIntervalSince1970),
            "claimKey": .string(dreamResidueClaimKey ?? ""),
        ]
        if let residue = dreamResidue {
            object["valence"] = .double(residue.valence)
            object["mintedAt"] = .double(residue.mintedAt.timeIntervalSince1970)
            object["turnsRemaining"] = .int(Int64(residue.turnsRemaining))
        }
        return .object(object)
    }

    /// Reset before restore so a missing or corrupt artifact cannot retain a stale in-memory night.
    func restoreDreamResidue(from payloads: [JSONValue]) {
        dreamResidue = nil
        dreamResidueClaimKey = nil
        guard case .object(let object)? = payloads.first else { return }
        if let key = object["claimKey"]?.stringValue, !key.isEmpty {
            dreamResidueClaimKey = key
        }
        guard let valence = object["valence"]?.numberValue(coercingStrings: false, finiteOnly: false),
              let mintedAt = dateValue(object["mintedAt"]),
              let turns = object["turnsRemaining"]?.integerValue.flatMap(Int.init(exactly:)), turns > 0 else { return }
        dreamResidue = CognitiveDreamResidue(
            valence: valence,
            mintedAt: mintedAt,
            turnsRemaining: turns
        )
    }
}

/// The night's leftover mood carries a feeling, timestamp and turn budget, never story text.
public struct CognitiveDreamResidue: Sendable, Equatable {
    /// −1…1, her explicit dream affect scaled down. It colors; it never leads.
    public var valence: Double
    public var mintedAt: Date
    /// Accepted turns still owed the lean; zero removes the residue rather than decaying it.
    public var turnsRemaining: Int

    public init(valence: Double, mintedAt: Date, turnsRemaining: Int) {
        self.valence = valence.clampedSigned()
        self.mintedAt = mintedAt
        self.turnsRemaining = max(0, turnsRemaining)
    }
}
