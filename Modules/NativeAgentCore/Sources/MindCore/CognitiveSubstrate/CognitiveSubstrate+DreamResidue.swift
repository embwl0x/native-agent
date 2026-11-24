import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+DreamResidue.swift` | `CognitiveSubstrate`, `CognitiveDreamResidue`: durable night claims |

extension CognitiveSubstrate {
    /// Sleep and completion come from their owners; absence of a tone cannot decide whether a dream happened.
    func dreamFeelingFrame(at now: Date, sleep: CognitiveSleepDreamReading?) -> String {
        let status: String
        if let failure = sleep?.failure {
            status = "My sleep and dream reading is unavailable: " + failure
        } else if let sleep, let beganAt = sleep.beganAt, beganAt <= now {
            if let completion = sleep.completion, completion.occurredAt >= beganAt, completion.occurredAt <= now {
                status = "A dream has completed since I fell asleep."
            } else {
                status = "Whether a dream has completed since I fell asleep is unknown."
            }
        } else {
            status = "My last sleep is unobserved here; whether I have dreamed since it is unknown."
        }
        guard persistenceRestored, !restoreInFlight else {
            return "My dream history is unread just now. " + status
        }
        if let dream = innerStateDreamResidue(at: now) {
            return "My last recorded dream felt \(dream.moodWord) (\(dream.date)). " + status
        }
        if !dreamResidueClaims.isEmpty || !dreamDispositionNights.isEmpty {
            return "A dream is recorded, but its tone is unknown. " + status
        }
        return "No dream tone is recorded here. " + status
    }

    /// Persist explicit dream tone through night claims, disposition decay and residue, without classifying prose.
    @discardableResult
    public func integrateDreamDisposition(
        tone: Double,
        at now: Date,
        dreamId: String? = nil
    ) async -> Bool {
        guard configuration.enabled, configuration.persistenceEnabled else { return false }
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
        guard configuration.enabled, configuration.persistenceEnabled, persistenceRestored, !restoreInFlight else { return false }
        // Each dream-integration write holds its own durable night claim so retries apply each half once.
        let night = dreamResidueKey(for: dreamId, at: now)
        let dispositionPersisted = dreamDispositionNights.contains(night)
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
            if !trimmed.isEmpty { return TextClipping.prefixOrWhole(trimmed, maxCharacters: 80) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(
            format: "day-%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// Spend residue across accepted exchanges rather than individual events.
    static let dreamResidueTurns = 2
    /// A small saturating affect delta colors the waking room without overriding it.
    static let dreamResidueLean = 0.07
    /// Residue expires after this interval regardless of remaining turns.
    static let dreamResidueLifetime: TimeInterval = 8 * 60 * 60

    /// The claim, felt event and affect share the normal field checkpoint. A failed save leaves the night owed.
    @discardableResult
    func mintDreamResidue(tone: Double, at now: Date, dreamId: String? = nil) async -> Bool {
        guard configuration.enabled, configuration.persistenceEnabled else { return false }
        // A neutral dream is still the latest dream: its zero residue moves no mood, but it is what she remembers the night felt like.
        let key = dreamResidueKey(for: dreamId, at: now)
        let valence = (tone.clampedSigned() * 0.35).clampedSigned()
        if !dreamResidueClaims.contains(key) || unconfirmedDreamClaims.contains(key) {
            let event = dreamResidueEvent(key: key, valence: valence, at: now)
            if dreamResidueClaims.contains(key), field.hasSeenEvent(event) {
                // An older claim whose felt event already landed is delivered; ingest would refuse the seen event forever.
                unconfirmedDreamClaims.remove(key)
            } else {
                // Stamp admission before ingest can suspend or another snapshot can capture half the night.
                let result = await ingest(event, defersPersistenceToMicrocycle: true) {
                    if dreamResidueClaims.insert(key).inserted {
                        dreamResidue = CognitiveDreamResidue(valence: valence, mintedAt: now, turnsRemaining: Self.dreamResidueTurns)
                    }
                    unconfirmedDreamClaims.remove(key)
                }
                guard result.accepted else { return false }
            }
        }
        guard configuration.enabled, configuration.persistenceEnabled, dreamResidueClaims.contains(key) else { return false }
        do {
            try await checkingPersistence("snapshot") { try await persistAffectAndNodes() }
            return true
        } catch { return false }
    }

    /// One story-free felt node per night; the field's seen-event check makes replay inert.
    private func dreamResidueEvent(key: String, valence: Double, at now: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: "dream_residue:\(key)",
            kind: .appWake,
            subject: CognitiveSubjectReference(type: "night", id: "the night", label: "the night"),
            sourceClass: .selfReported,
            occurredAt: now,
            // Residue carries feeling without story text.
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

    func dreamResidueArtifactPayload() -> JSONValue {
        var object: [String: JSONValue] = [
            "claimKeys": .array(dreamResidueClaims.sorted().map(JSONValue.string)),
            "unconfirmedKeys": .array(unconfirmedDreamClaims.sorted().map(JSONValue.string)),
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
        dreamResidueClaims = []
        unconfirmedDreamClaims = []
        guard case .object(let object)? = payloads.first else { return }
        if case .array(let keys)? = object["claimKeys"] {
            dreamResidueClaims = Set(keys.compactMap(\.stringValue))
        }
        if case .array(let keys)? = object["unconfirmedKeys"] {
            unconfirmedDreamClaims = Set(keys.compactMap(\.stringValue))
        } else {
            unconfirmedDreamClaims = dreamResidueClaims
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
    /// −1…1, the agent's explicit dream affect scaled down. It colors; it never leads.
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
