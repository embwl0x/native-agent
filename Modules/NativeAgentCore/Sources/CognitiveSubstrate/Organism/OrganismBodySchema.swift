import CryptoKit
import Foundation

public enum ProviderPathEvidenceOutcome: String, Codable, Sendable, Equatable {
    case succeeded
    case failed
    case recovered
    case cancelled
    case started
    case expired

    fileprivate var healthyEstimate: Double? {
        switch self {
        case .succeeded, .recovered: 1
        case .failed: 0
        // A cancelled request says nothing about path health. An unresolved
        // start and its later expiry are likewise unknown, not failures.
        case .cancelled, .started, .expired: nil
        }
    }
}

/// Payload-free evidence about a provider path. The initializer hashes the
/// supplied reference into `evidenceID`; provider output, prompts, account ids,
/// and credentials therefore cannot survive in the typed evidence value.
public struct ProviderPathEvidence: Codable, Sendable, Equatable {
    public let evidenceID: String
    public let observedAt: Date
    public let outcome: ProviderPathEvidenceOutcome
    public let sourceReliability: Double

    public init(
        evidenceID: String,
        observedAt: Date,
        outcome: ProviderPathEvidenceOutcome,
        sourceReliability: Double = 1
    ) {
        let cleanID = evidenceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let digestSource = cleanID.isEmpty ? "anonymous" : String(cleanID.prefix(512))
        let digest = SHA256.hash(data: Data(digestSource.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.init(
            canonicalEvidenceID: digest,
            observedAt: observedAt,
            outcome: outcome,
            sourceReliability: sourceReliability
        )
    }

    private enum CodingKeys: String, CodingKey {
        case evidenceID, observedAt, outcome, sourceReliability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .evidenceID)
        let observedAt = try container.decode(Date.self, forKey: .observedAt)
        let outcome = try container.decode(ProviderPathEvidenceOutcome.self, forKey: .outcome)
        let reliability = try container.decode(Double.self, forKey: .sourceReliability)
        let canonicalID: String
        if Self.isCanonicalDigest(rawID) {
            canonicalID = rawID
        } else {
            let cleanID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = cleanID.isEmpty ? "anonymous" : String(cleanID.prefix(512))
            canonicalID = SHA256.hash(data: Data(source.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }
        self.init(
            canonicalEvidenceID: canonicalID,
            observedAt: observedAt,
            outcome: outcome,
            sourceReliability: reliability
        )
    }

    private init(
        canonicalEvidenceID: String,
        observedAt: Date,
        outcome: ProviderPathEvidenceOutcome,
        sourceReliability: Double
    ) {
        self.evidenceID = canonicalEvidenceID
        self.observedAt = observedAt
        self.outcome = outcome
        self.sourceReliability = Self.clampFinite(sourceReliability)
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func clampFinite(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value).clamped01()
    }
}

public enum ProviderPathBeliefState: String, Codable, Sendable, Equatable {
    case healthy
    case brittle
    case uncertain
    case stale
    case unobserved
}

/// A read-time belief projection, not canonical provider reality. Exact
/// lifecycle events remain owned by their provider/trace stores. Consumers may
/// use estimate, freshness and uncertainty for posture; the optional Boolean
/// is only the legacy `BodySchema` compatibility view.
public struct ProviderPathBeliefProjection: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let estimate: Double
    public let freshness: Double
    public let uncertainty: Double
    public let evidenceCount: Int
    public let newestEvidenceAt: Date?
    public let state: ProviderPathBeliefState
    public let bodySchemaProvidersHealthy: Bool?

    public init(
        generatedAt: Date,
        estimate: Double,
        freshness: Double,
        uncertainty: Double,
        evidenceCount: Int,
        newestEvidenceAt: Date?,
        state: ProviderPathBeliefState,
        bodySchemaProvidersHealthy: Bool?
    ) {
        self.generatedAt = generatedAt
        self.estimate = Self.clampFinite(estimate, fallback: 0.5)
        self.freshness = Self.clampFinite(freshness, fallback: 0)
        self.uncertainty = Self.clampFinite(uncertainty, fallback: 1)
        self.evidenceCount = min(10_000, max(0, evidenceCount))
        self.newestEvidenceAt = newestEvidenceAt
        let derived = Self.categorize(
            estimate: self.estimate,
            freshness: self.freshness,
            uncertainty: self.uncertainty,
            evidenceCount: self.evidenceCount
        )
        // Category/compatibility are projections of the bounded numerics, not
        // independently trusted truth. The parameters remain source-compatible
        // for older callers/decoders but cannot create a contradictory value.
        self.state = derived.state
        self.bodySchemaProvidersHealthy = derived.compatibility
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt, estimate, freshness, uncertainty, evidenceCount
        case newestEvidenceAt, state, bodySchemaProvidersHealthy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            generatedAt: try container.decode(Date.self, forKey: .generatedAt),
            estimate: try container.decode(Double.self, forKey: .estimate),
            freshness: try container.decode(Double.self, forKey: .freshness),
            uncertainty: try container.decode(Double.self, forKey: .uncertainty),
            evidenceCount: try container.decode(Int.self, forKey: .evidenceCount),
            newestEvidenceAt: try container.decodeIfPresent(Date.self, forKey: .newestEvidenceAt),
            state: try container.decode(ProviderPathBeliefState.self, forKey: .state),
            bodySchemaProvidersHealthy: try container.decodeIfPresent(Bool.self, forKey: .bodySchemaProvidersHealthy)
        )
    }

    private static func clampFinite(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return (value).clamped01()
    }

    private static func categorize(
        estimate: Double,
        freshness: Double,
        uncertainty: Double,
        evidenceCount: Int
    ) -> (state: ProviderPathBeliefState, compatibility: Bool?) {
        guard evidenceCount > 0 else { return (.unobserved, nil) }
        if freshness < 0.05 { return (.stale, nil) }
        if uncertainty > 0.55 || (0.35...0.65).contains(estimate) {
            return (.uncertain, nil)
        }
        return estimate > 0.65 ? (.healthy, true) : (.brittle, false)
    }
}

public enum ProviderPathBeliefProjector {
    /// A few seconds of clock skew may occur across local evidence producers;
    /// anything farther ahead is not evidence about the present and must not
    /// manufacture maximal freshness or confidence.
    public static let maximumFutureClockSkew: TimeInterval = 5

    public static func project(
        evidence: [ProviderPathEvidence],
        now: Date,
        halfLife: TimeInterval = 30 * 60,
        staleAfter: TimeInterval = 6 * 60 * 60,
        maximumEvidence: Int = 32
    ) -> ProviderPathBeliefProjection {
        let boundedHalfLife = halfLife.isFinite ? max(1, halfLife) : 30 * 60
        let boundedStaleAfter = staleAfter.isFinite
            ? max(boundedHalfLife, staleAfter)
            : 6 * 60 * 60
        let ordered = evidence
            .filter { item in
                item.observedAt.timeIntervalSince(now) <= maximumFutureClockSkew
            }
            .sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
                return $0.evidenceID < $1.evidenceID
            }
        var seenEvidenceIDs = Set<String>()
        var bounded: [ProviderPathEvidence] = []
        bounded.reserveCapacity(min(max(0, maximumEvidence), ordered.count))
        for item in ordered where bounded.count < max(0, maximumEvidence) {
            guard seenEvidenceIDs.insert(item.evidenceID).inserted else { continue }
            bounded.append(item)
        }

        guard let newest = bounded.first?.observedAt else {
            return ProviderPathBeliefProjection(
                generatedAt: now,
                estimate: 0.5,
                freshness: 0,
                uncertainty: 1,
                evidenceCount: 0,
                newestEvidenceAt: nil,
                state: .unobserved,
                bodySchemaProvidersHealthy: nil
            )
        }

        var weightedEstimate = 0.0
        var totalWeight = 0.0
        for observation in bounded {
            guard let healthyEstimate = observation.outcome.healthyEstimate else { continue }
            let age = max(0, now.timeIntervalSince(observation.observedAt))
            guard age <= boundedStaleAfter else { continue }
            let recency = exp(-log(2) * age / boundedHalfLife)
            let weight = recency * observation.sourceReliability
            weightedEstimate += healthyEstimate * weight
            totalWeight += weight
        }

        let newestAge = max(0, now.timeIntervalSince(newest))
        let freshness = newestAge <= boundedStaleAfter
            ? exp(-log(2) * newestAge / boundedHalfLife)
            : 0
        guard totalWeight > 0, freshness > 0 else {
            return ProviderPathBeliefProjection(
                generatedAt: now,
                estimate: 0.5,
                freshness: freshness,
                uncertainty: 1,
                evidenceCount: bounded.count,
                newestEvidenceAt: newest,
                state: freshness > 0 ? .uncertain : .stale,
                bodySchemaProvidersHealthy: nil
            )
        }

        // A weak Beta(1,1) prior keeps one lifecycle observation from
        // masquerading as certainty about the future provider path. Exact
        // success/failure remains owned by provider lifecycle truth.
        let estimate = ((weightedEstimate + 1) / (totalWeight + 2)).clamped01()
        let lowSupport = 1 / sqrt(totalWeight + 1)
        let disagreement = 4 * estimate * (1 - estimate)
        let uncertainty = max(lowSupport, disagreement).clamped01()
        let state: ProviderPathBeliefState
        let compatibility: Bool?
        if freshness < 0.05 {
            state = .stale
            compatibility = nil
        } else if uncertainty > 0.55 || (0.35...0.65).contains(estimate) {
            state = .uncertain
            compatibility = nil
        } else if estimate > 0.65 {
            state = .healthy
            compatibility = true
        } else {
            state = .brittle
            compatibility = false
        }
        return ProviderPathBeliefProjection(
            generatedAt: now,
            estimate: estimate,
            freshness: freshness,
            uncertainty: uncertainty,
            evidenceCount: bounded.count,
            newestEvidenceAt: newest,
            state: state,
            bodySchemaProvidersHealthy: compatibility
        )
    }
}

public struct OrganismBodyRead: Sendable, Equatable {
    public var macAwake: Bool?
    public var iPhoneReachable: Bool?
    public var iPhoneLastSeenAt: Date?
    public var iPhoneStaleAfter: TimeInterval
    public var providersHealthy: Bool?
    /// Exact configuration/credential availability. This is not path health:
    /// a configured provider can still be stale, failing, or unobserved.
    public var providersAvailable: Bool?
    public var providerPathBelief: ProviderPathBeliefProjection?
    public var peerPresenceBelief: PeerPresenceBelief?
    public var notificationDeliveryBelief: NotificationDeliveryBelief?
    public var memoryIntegrityReading: MemoryIntegrityReading?
    public var dreamIntegrityReading: DreamIntegrityReading?
    public var toolCapabilityReading: ToolCapabilityReading?
    public var approvalPathReading: ApprovalPathReading?
    public var resourcePressureReading: ResourcePressureReading?
    public var memoryHealthy: Bool?
    public var dreamHealthy: Bool?
    public var toolHandsAvailable: Bool?
    public var approvalChannelsOpen: Bool?
    public var notificationPathHealthy: Bool?
    public var resourcePressure: OrganismResourcePressure?

    public init(
        macAwake: Bool? = nil,
        iPhoneReachable: Bool? = nil,
        iPhoneLastSeenAt: Date? = nil,
        iPhoneStaleAfter: TimeInterval = 60 * 60 * 36,
        providersHealthy: Bool? = nil,
        providersAvailable: Bool? = nil,
        providerPathBelief: ProviderPathBeliefProjection? = nil,
        peerPresenceBelief: PeerPresenceBelief? = nil,
        notificationDeliveryBelief: NotificationDeliveryBelief? = nil,
        memoryIntegrityReading: MemoryIntegrityReading? = nil,
        dreamIntegrityReading: DreamIntegrityReading? = nil,
        toolCapabilityReading: ToolCapabilityReading? = nil,
        approvalPathReading: ApprovalPathReading? = nil,
        resourcePressureReading: ResourcePressureReading? = nil,
        memoryHealthy: Bool? = nil,
        dreamHealthy: Bool? = nil,
        toolHandsAvailable: Bool? = nil,
        approvalChannelsOpen: Bool? = nil,
        notificationPathHealthy: Bool? = nil,
        resourcePressure: OrganismResourcePressure? = nil
    ) {
        self.macAwake = macAwake
        self.iPhoneReachable = iPhoneReachable
        self.iPhoneLastSeenAt = iPhoneLastSeenAt
        self.iPhoneStaleAfter = max(0, iPhoneStaleAfter)
        self.providersHealthy = providersHealthy
        self.providersAvailable = providersAvailable
        self.providerPathBelief = providerPathBelief
        self.peerPresenceBelief = peerPresenceBelief
        self.notificationDeliveryBelief = notificationDeliveryBelief
        self.memoryIntegrityReading = memoryIntegrityReading
        self.dreamIntegrityReading = dreamIntegrityReading
        self.toolCapabilityReading = toolCapabilityReading
        self.approvalPathReading = approvalPathReading
        self.resourcePressureReading = resourcePressureReading
        self.memoryHealthy = memoryHealthy
        self.dreamHealthy = dreamHealthy
        self.toolHandsAvailable = toolHandsAvailable
        self.approvalChannelsOpen = approvalChannelsOpen
        self.notificationPathHealthy = notificationPathHealthy
        self.resourcePressure = resourcePressure
    }
}

public enum OrganismBodySchemaSampler {
    public static func bodySchema(
        from read: OrganismBodyRead,
        previous: BodySchema = .neutral,
        now: Date
    ) -> BodySchema {
        var body = previous
        if let macAwake = read.macAwake {
            body.macAwake = macAwake
        }
        if let peerPresenceBelief = read.peerPresenceBelief {
            body.peerPresenceBelief = peerPresenceBelief
            body.iPhoneReachable = peerPresenceBelief.compatibilityReachable
        } else if let iPhoneReachable = read.iPhoneReachable {
            body.iPhoneReachable = iPhoneReachable
        }
        if read.peerPresenceBelief == nil, let lastSeen = read.iPhoneLastSeenAt {
            body.iPhoneReachable = now.timeIntervalSince(lastSeen) <= read.iPhoneStaleAfter
        }
        if let providersAvailable = read.providersAvailable {
            body.providersAvailable = providersAvailable
            if !providersAvailable {
                body.providersHealthy = false
            }
        }
        if let belief = read.providerPathBelief {
            body.providerPathBelief = belief
            if let providersHealthy = belief.bodySchemaProvidersHealthy {
                body.providersHealthy = providersHealthy
            } else if read.providersAvailable != nil {
                // Compatibility Bool cannot express unknown. Fail closed until
                // informative lifecycle evidence exists instead of promoting
                // mere configuration to health.
                body.providersHealthy = false
            }
        } else if let providersHealthy = read.providersHealthy {
            body.providerPathBelief = nil
            body.providersHealthy = providersHealthy
        }
        if let memoryIntegrityReading = read.memoryIntegrityReading {
            body.memoryIntegrityReading = memoryIntegrityReading
            if let healthy = memoryIntegrityReading.compatibilityHealthy {
                body.memoryHealthy = healthy
            }
        } else if let memoryHealthy = read.memoryHealthy {
            body.memoryHealthy = memoryHealthy
        }
        if let dreamIntegrityReading = read.dreamIntegrityReading {
            body.dreamIntegrityReading = dreamIntegrityReading
            if let healthy = dreamIntegrityReading.compatibilityHealthy {
                body.dreamHealthy = healthy
            }
        } else if let dreamHealthy = read.dreamHealthy {
            body.dreamHealthy = dreamHealthy
        }
        if let toolCapabilityReading = read.toolCapabilityReading {
            body.toolCapabilityReading = toolCapabilityReading
            if let available = toolCapabilityReading.compatibilityAvailable {
                body.toolHandsAvailable = available
            }
        } else if let toolHandsAvailable = read.toolHandsAvailable {
            body.toolHandsAvailable = toolHandsAvailable
        }
        if let approvalPathReading = read.approvalPathReading {
            body.approvalPathReading = approvalPathReading
            if let open = approvalPathReading.compatibilityOpen {
                body.approvalChannelsOpen = open
            }
        } else if let approvalChannelsOpen = read.approvalChannelsOpen {
            body.approvalChannelsOpen = approvalChannelsOpen
        }
        if let notificationDeliveryBelief = read.notificationDeliveryBelief {
            body.notificationDeliveryBelief = notificationDeliveryBelief
            if notificationDeliveryBelief.deviceReceived {
                body.iPhoneReachable = true
            }
            if let healthy = notificationDeliveryBelief.compatibilityPathHealthy {
                body.notificationPathHealthy = healthy
            } else if notificationDeliveryBelief.transportConfigured {
                // APNS acceptance is exact transport truth, not proof that the
                // app displayed the notification. A fresh authenticated peer
                // contact can still establish that the peripheral path is live.
                body.notificationPathHealthy = body.iPhoneReachable
            }
        } else if let notificationPathHealthy = read.notificationPathHealthy {
            body.notificationPathHealthy = notificationPathHealthy
        } else if (read.iPhoneReachable != nil || read.iPhoneLastSeenAt != nil),
                  body.iPhoneReachable == false {
            body.notificationPathHealthy = false
        }
        if let resourcePressureReading = read.resourcePressureReading {
            body.resourcePressureReading = resourcePressureReading
            body.resourcePressure = resourcePressureReading.category
        } else if let resourcePressure = read.resourcePressure {
            body.resourcePressure = resourcePressure
        }
        return body
    }
}
