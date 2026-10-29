import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `BodyEvidence.swift` | Body evidence classes, secret-free identities and bounded freshness/uncertainty metrics |

/// Secret-free evidence classes shared by the narrow body-read projections.
/// These are correlation references only; payloads, credentials, paths, user
/// text, and provider output never enter the body belief layer.
public enum BodyEvidenceClass: String, Codable, Sendable, Equatable, CaseIterable {
    case signedPeerContact
    case apnsAcceptance
    case notificationTransportFailure
    case deviceProcessReceipt
    case deviceProcessFailure
    case displayReceipt
    case explicitUserReaction
    case localStorePresence
    case localStoreRead
    case maintenanceReceipt
    case dreamCompletion
    case toolConfiguration
    case liveToolCapability
    case approvalStore
    case processThermalState
    /// Read only from persisted body evidence; Low Power Mode is no longer sensed.
    case lowPowerMode
}

public struct BodyEvidenceReference: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let evidenceClass: BodyEvidenceClass
    /// Source-domain time. Retained for provenance, but never used to settle
    /// physiology. Freshness is always computed from locally received time.
    public let observedAt: Date
    public let receivedAt: Date
    public let reliability: Double

    public init(
        id: String,
        evidenceClass: BodyEvidenceClass,
        observedAt: Date,
        receivedAt: Date,
        reliability: Double = 1
    ) {
        self.id = Self.digest(id)
        self.evidenceClass = evidenceClass
        self.observedAt = observedAt
        self.receivedAt = receivedAt
        self.reliability = Self.clamp(reliability, fallback: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case id, evidenceClass, observedAt, receivedAt, reliability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        self.id = ProviderPathEvidence.isCanonicalDigest(rawID) ? rawID : Self.digest(rawID)
        self.evidenceClass = try container.decode(BodyEvidenceClass.self, forKey: .evidenceClass)
        self.observedAt = try container.decode(Date.self, forKey: .observedAt)
        self.receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        self.reliability = Self.clamp(
            try container.decode(Double.self, forKey: .reliability),
            fallback: 0
        )
    }

    static func digest(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = clean.isEmpty ? "anonymous" : String(clean.prefix(512))
        return SHA256.hash(data: Data(bounded.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    fileprivate static func clamp(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return (value).clamped01()
    }
}

/// Common bounded metrics used by every typed body read. It is a projection,
/// never a canonical evidence store. Hostile decoding is normalized, evidence
/// is deduplicated and capped, and future local-receipt times are discarded.
public struct BodyBeliefMetrics: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let estimate: Double
    public let uncertainty: Double
    public let freshness: Double
    public let evidence: [BodyEvidenceReference]
    public let observedAt: Date?
    public let receivedAt: Date?
    public let nextMeaningfulExpiry: Date?

    public init(
        generatedAt: Date,
        estimate: Double,
        uncertainty: Double,
        freshness: Double,
        evidence: [BodyEvidenceReference] = [],
        observedAt: Date? = nil,
        receivedAt: Date? = nil,
        nextMeaningfulExpiry: Date? = nil
    ) {
        self.generatedAt = generatedAt
        self.estimate = BodyEvidenceReference.clamp(estimate, fallback: 0.5)
        self.uncertainty = BodyEvidenceReference.clamp(uncertainty, fallback: 1)
        let bounded = Self.boundedEvidence(evidence, generatedAt: generatedAt)
        self.freshness = evidence.isEmpty || !bounded.isEmpty
            ? BodyEvidenceReference.clamp(freshness, fallback: 0)
            : 0
        self.evidence = bounded
        self.observedAt = bounded.map(\.observedAt).max() ?? observedAt
        self.receivedAt = bounded.map(\.receivedAt).max() ?? receivedAt
        self.nextMeaningfulExpiry = nextMeaningfulExpiry
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt, estimate, uncertainty, freshness, evidence
        case observedAt, receivedAt, nextMeaningfulExpiry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            generatedAt: try container.decode(Date.self, forKey: .generatedAt),
            estimate: try container.decode(Double.self, forKey: .estimate),
            uncertainty: try container.decode(Double.self, forKey: .uncertainty),
            freshness: try container.decode(Double.self, forKey: .freshness),
            evidence: try container.decodeIfPresent([BodyEvidenceReference].self, forKey: .evidence) ?? [],
            observedAt: try container.decodeIfPresent(Date.self, forKey: .observedAt),
            receivedAt: try container.decodeIfPresent(Date.self, forKey: .receivedAt),
            nextMeaningfulExpiry: try container.decodeIfPresent(Date.self, forKey: .nextMeaningfulExpiry)
        )
    }

    static func boundedEvidence(
        _ evidence: [BodyEvidenceReference],
        generatedAt: Date,
        maximum: Int = 8
    ) -> [BodyEvidenceReference] {
        var seen = Set<String>()
        return evidence
            .filter { $0.receivedAt.timeIntervalSince(generatedAt) <= 5 }
            .sorted {
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
                return $0.id < $1.id
            }
            .filter { seen.insert($0.id).inserted }
            .prefix(max(0, maximum))
            .map { $0 }
    }

    static func freshness(
        receivedAt: Date?,
        now: Date,
        halfLife: TimeInterval,
        staleAfter: TimeInterval
    ) -> Double {
        guard let receivedAt,
              receivedAt.timeIntervalSince(now) <= 5 else { return 0 }
        let age = max(0, now.timeIntervalSince(receivedAt))
        guard age <= max(1, staleAfter) else { return 0 }
        return exp(-log(2) * age / max(1, halfLife))
    }
}
