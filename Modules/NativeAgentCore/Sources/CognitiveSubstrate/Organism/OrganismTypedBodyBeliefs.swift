import Foundation

// Blueprint: | `OrganismTypedBodyBeliefs.swift` | Seven typed domain readings: evidence-bounded categories, freshness and compatibility values |

public enum PeerPresenceCategory: String, Codable, Sendable, Equatable {
    case present
    case stale
    case unobserved
}

public struct PeerPresenceBelief: Codable, Sendable, Equatable {
    public let category: PeerPresenceCategory
    public let metrics: BodyBeliefMetrics

    public var compatibilityReachable: Bool { category == .present }

    public init(
        generatedAt: Date,
        evidence: [BodyEvidenceReference],
        staleAfter: TimeInterval = 36 * 60 * 60
    ) {
        let boundedStale = staleAfter.isFinite ? max(1, staleAfter) : 36 * 60 * 60
        let bounded = BodyBeliefMetrics.boundedEvidence(
            evidence.filter { $0.evidenceClass == .signedPeerContact },
            generatedAt: generatedAt
        )
        let receivedAt = bounded.first?.receivedAt
        let freshness = BodyBeliefMetrics.freshness(
            receivedAt: receivedAt,
            now: generatedAt,
            halfLife: boundedStale / 2,
            staleAfter: boundedStale
        )
        let estimate = receivedAt == nil ? 0.5 : freshness
        let uncertainty = receivedAt == nil ? 1 : 1 - freshness
        self.metrics = BodyBeliefMetrics(
            generatedAt: generatedAt,
            estimate: estimate,
            uncertainty: uncertainty,
            freshness: freshness,
            evidence: bounded,
            nextMeaningfulExpiry: receivedAt?.addingTimeInterval(boundedStale)
        )
        self.category = Self.derive(metrics: metrics)
    }

    private enum CodingKeys: String, CodingKey { case category, metrics }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode(BodyBeliefMetrics.self, forKey: .metrics)
        let metrics = BodyBeliefMetrics(
            generatedAt: decoded.generatedAt,
            estimate: decoded.estimate,
            uncertainty: decoded.uncertainty,
            freshness: decoded.freshness,
            evidence: decoded.evidence.filter { $0.evidenceClass == .signedPeerContact },
            nextMeaningfulExpiry: decoded.nextMeaningfulExpiry
        )
        self.metrics = metrics
        self.category = Self.derive(metrics: metrics)
    }

    private static func derive(metrics: BodyBeliefMetrics) -> PeerPresenceCategory {
        guard metrics.receivedAt != nil else { return .unobserved }
        return metrics.freshness > 0 ? .present : .stale
    }
}

public enum NotificationDeliveryCategory: String, Codable, Sendable, Equatable {
    case unconfigured
    case configured
    case transportAccepted
    case deviceReceived
    case displayed
    case userSeen
    case failed
    case unknown
}

public struct NotificationDeliveryBelief: Codable, Sendable, Equatable {
    public let category: NotificationDeliveryCategory
    public let metrics: BodyBeliefMetrics
    public let transportConfigured: Bool
    public let transportAccepted: Bool
    public let deviceReceived: Bool
    public let displayed: Bool
    public let userSeen: Bool
    public let transportFailed: Bool

    public var compatibilityPathHealthy: Bool? {
        if !transportConfigured { return true }
        if transportFailed { return false }
        if deviceReceived && metrics.freshness > 0 { return true }
        return nil
    }

    public init(
        generatedAt: Date,
        transportConfigured: Bool,
        transportAccepted: Bool = false,
        deviceReceived: Bool = false,
        displayed: Bool = false,
        userSeen: Bool = false,
        transportFailed: Bool = false,
        evidence: [BodyEvidenceReference] = [],
        staleAfter: TimeInterval = 36 * 60 * 60
    ) {
        let bounded = BodyBeliefMetrics.boundedEvidence(evidence, generatedAt: generatedAt)
        let classes = Set(bounded.map(\.evidenceClass))
        let supportedAccepted = transportAccepted && classes.contains(.apnsAcceptance)
        let supportedReceived = deviceReceived && classes.contains(.deviceProcessReceipt)
        let supportedDisplayed = displayed && classes.contains(.displayReceipt)
        let supportedSeen = userSeen && classes.contains(.explicitUserReaction)
        let supportedFailure = transportFailed && (
            classes.contains(.notificationTransportFailure)
                || classes.contains(.deviceProcessFailure)
        )
        self.transportConfigured = transportConfigured
        self.transportAccepted = supportedAccepted
        self.deviceReceived = supportedReceived
        self.displayed = supportedDisplayed
        self.userSeen = supportedSeen
        self.transportFailed = supportedFailure
        let receivedAt = bounded.first {
            if supportedFailure {
                return $0.evidenceClass == .notificationTransportFailure
                    || $0.evidenceClass == .deviceProcessFailure
            }
            if supportedSeen { return $0.evidenceClass == .explicitUserReaction }
            if supportedDisplayed { return $0.evidenceClass == .displayReceipt }
            if supportedReceived { return $0.evidenceClass == .deviceProcessReceipt }
            if supportedAccepted { return $0.evidenceClass == .apnsAcceptance }
            return false
        }?.receivedAt
        let freshness = BodyBeliefMetrics.freshness(
            receivedAt: receivedAt,
            now: generatedAt,
            halfLife: max(1, staleAfter / 2),
            staleAfter: staleAfter
        )
        let estimate: Double
        let uncertainty: Double
        if supportedFailure {
            estimate = 0
            uncertainty = 0
        } else if supportedSeen || supportedDisplayed || supportedReceived {
            estimate = 1
            uncertainty = 0
        } else if supportedAccepted {
            estimate = 0.5
            uncertainty = 1
        } else if transportConfigured {
            estimate = 0.5
            uncertainty = 1
        } else {
            estimate = 0
            uncertainty = 0
        }
        self.metrics = BodyBeliefMetrics(
            generatedAt: generatedAt,
            estimate: estimate,
            uncertainty: uncertainty,
            freshness: freshness,
            evidence: bounded,
            nextMeaningfulExpiry: receivedAt?.addingTimeInterval(staleAfter)
        )
        self.category = Self.derive(
            transportConfigured: transportConfigured,
            transportAccepted: supportedAccepted,
            deviceReceived: supportedReceived,
            displayed: supportedDisplayed,
            userSeen: supportedSeen,
            transportFailed: supportedFailure,
            metrics: metrics
        )
    }

    private enum CodingKeys: String, CodingKey {
        case category, metrics, transportConfigured, transportAccepted
        case deviceReceived, displayed, userSeen, transportFailed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metrics = try container.decode(BodyBeliefMetrics.self, forKey: .metrics)
        let configured = try container.decode(Bool.self, forKey: .transportConfigured)
        let classes = Set(metrics.evidence.map(\.evidenceClass))
        let accepted = try container.decode(Bool.self, forKey: .transportAccepted)
            && classes.contains(.apnsAcceptance)
        let received = try container.decode(Bool.self, forKey: .deviceReceived)
            && classes.contains(.deviceProcessReceipt)
        let displayed = try container.decode(Bool.self, forKey: .displayed)
            && classes.contains(.displayReceipt)
        let seen = try container.decode(Bool.self, forKey: .userSeen)
            && classes.contains(.explicitUserReaction)
        let failed = try container.decode(Bool.self, forKey: .transportFailed)
            && (classes.contains(.notificationTransportFailure) || classes.contains(.deviceProcessFailure))
        self.metrics = metrics
        self.transportConfigured = configured
        self.transportAccepted = accepted
        self.deviceReceived = received
        self.displayed = displayed
        self.userSeen = seen
        self.transportFailed = failed
        self.category = Self.derive(
            transportConfigured: configured,
            transportAccepted: accepted,
            deviceReceived: received,
            displayed: displayed,
            userSeen: seen,
            transportFailed: failed,
            metrics: metrics
        )
    }

    private static func derive(
        transportConfigured: Bool,
        transportAccepted: Bool,
        deviceReceived: Bool,
        displayed: Bool,
        userSeen: Bool,
        transportFailed: Bool,
        metrics: BodyBeliefMetrics
    ) -> NotificationDeliveryCategory {
        guard transportConfigured else { return .unconfigured }
        if transportFailed { return .failed }
        if userSeen { return .userSeen }
        if displayed { return .displayed }
        if deviceReceived { return .deviceReceived }
        if transportAccepted { return .transportAccepted }
        return metrics.evidence.isEmpty ? .configured : .unknown
    }
}

public enum MemoryIntegrityCategory: String, Codable, Sendable, Equatable {
    case healthy
    case degraded
    case unavailable
    case unknown
}

public struct MemoryIntegrityReading: Codable, Sendable, Equatable {
    public let category: MemoryIntegrityCategory
    public let metrics: BodyBeliefMetrics

    public var compatibilityHealthy: Bool? {
        switch category {
        case .healthy: true
        case .degraded, .unavailable: false
        case .unknown: nil
        }
    }

    public init(
        generatedAt: Date,
        storeAvailable: Bool,
        maintenanceSucceeded: Bool?,
        evidence: [BodyEvidenceReference]
    ) {
        let estimate = storeAvailable ? (maintenanceSucceeded == false ? 0.25 : 1) : 0
        // A successful canonical read proves readability, not successful
        // maintenance. Presence alone supplies neither proof.
        let uncertainty = storeAvailable && maintenanceSucceeded == nil ? 1.0 : 0
        self.metrics = BodyBeliefMetrics(
            generatedAt: generatedAt,
            estimate: estimate,
            uncertainty: uncertainty,
            freshness: evidence.isEmpty ? 0 : 1,
            evidence: evidence
        )
        self.category = Self.derive(estimate: metrics.estimate, uncertainty: metrics.uncertainty)
    }

    private enum CodingKeys: String, CodingKey { case category, metrics }
    public init(from decoder: Decoder) throws {
        let metrics = try decoder.container(keyedBy: CodingKeys.self)
            .decode(BodyBeliefMetrics.self, forKey: .metrics)
        self.metrics = metrics
        self.category = Self.derive(estimate: metrics.estimate, uncertainty: metrics.uncertainty)
    }

    private static func derive(estimate: Double, uncertainty: Double) -> MemoryIntegrityCategory {
        if uncertainty >= 0.75 { return .unknown }
        if estimate >= 0.75 { return .healthy }
        if estimate > 0 { return .degraded }
        return .unavailable
    }
}

public enum DreamIntegrityCategory: String, Codable, Sendable, Equatable {
    case healthy
    case stale
    case idle
    case unavailable
    case unknown
}

public struct DreamIntegrityReading: Codable, Sendable, Equatable {
    public let category: DreamIntegrityCategory
    public let metrics: BodyBeliefMetrics
    public let storeAvailable: Bool

    public var compatibilityHealthy: Bool? {
        switch category {
        case .healthy, .idle: true
        case .stale, .unavailable: false
        case .unknown: nil
        }
    }

    public init(
        generatedAt: Date,
        storeAvailable: Bool,
        completionEvidence: [BodyEvidenceReference],
        staleAfter: TimeInterval = 10 * 24 * 60 * 60
    ) {
        self.storeAvailable = storeAvailable
        let bounded = BodyBeliefMetrics.boundedEvidence(completionEvidence, generatedAt: generatedAt)
        let last = bounded.first?.receivedAt
        let freshness = BodyBeliefMetrics.freshness(
            receivedAt: last,
            now: generatedAt,
            halfLife: max(1, staleAfter / 2),
            staleAfter: staleAfter
        )
        let estimate = !storeAvailable ? 0 : (last == nil ? 0.75 : freshness)
        let uncertainty = storeAvailable && last == nil ? 0.25 : 0
        self.metrics = BodyBeliefMetrics(
            generatedAt: generatedAt,
            estimate: estimate,
            uncertainty: uncertainty,
            freshness: freshness,
            evidence: bounded,
            nextMeaningfulExpiry: last?.addingTimeInterval(staleAfter)
        )
        self.category = Self.derive(storeAvailable: storeAvailable, metrics: metrics)
    }

    private enum CodingKeys: String, CodingKey { case category, metrics, storeAvailable }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metrics = try container.decode(BodyBeliefMetrics.self, forKey: .metrics)
        let available = try container.decode(Bool.self, forKey: .storeAvailable)
        self.metrics = metrics
        self.storeAvailable = available
        self.category = Self.derive(storeAvailable: available, metrics: metrics)
    }

    private static func derive(
        storeAvailable: Bool,
        metrics: BodyBeliefMetrics
    ) -> DreamIntegrityCategory {
        guard storeAvailable else { return .unavailable }
        guard metrics.receivedAt != nil else { return .idle }
        return metrics.freshness > 0 ? .healthy : .stale
    }
}

public enum ToolCapabilityCategory: String, Codable, Sendable, Equatable {
    case available
    case configured
    case unavailable
    case unknown
}

public struct ToolCapabilityReading: Codable, Sendable, Equatable {
    public let category: ToolCapabilityCategory
    public let metrics: BodyBeliefMetrics
    public let configured: Bool
    public let liveCapabilityObserved: Bool

    public var compatibilityAvailable: Bool? {
        category == .unknown ? nil : category != .unavailable
    }

    public init(
        generatedAt: Date,
        configured: Bool,
        liveCapabilityObserved: Bool,
        evidence: [BodyEvidenceReference]
    ) {
        self.configured = configured
        self.liveCapabilityObserved = liveCapabilityObserved
        let liveReceivedAt = evidence
            .filter { $0.evidenceClass == .liveToolCapability }
            .map(\.receivedAt)
            .max()
        let liveFreshness = BodyBeliefMetrics.freshness(
            receivedAt: liveReceivedAt,
            now: generatedAt,
            halfLife: 3 * 60 * 60,
            staleAfter: 6 * 60 * 60
        )
        self.metrics = BodyBeliefMetrics(
            generatedAt: generatedAt,
            estimate: liveCapabilityObserved ? 1 : (configured ? 0.6 : 0),
            uncertainty: liveCapabilityObserved ? 0 : (configured ? 0.5 : 0),
            freshness: liveCapabilityObserved ? liveFreshness : (evidence.isEmpty ? 0 : 1),
            evidence: evidence,
            nextMeaningfulExpiry: liveCapabilityObserved
                ? liveReceivedAt?.addingTimeInterval(6 * 60 * 60)
                : nil
        )
        self.category = Self.derive(
            configured: configured,
            liveCapabilityObserved: liveCapabilityObserved,
            metrics: metrics
        )
    }

    private enum CodingKeys: String, CodingKey {
        case category, metrics, configured, liveCapabilityObserved
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metrics = try container.decode(BodyBeliefMetrics.self, forKey: .metrics)
        let classes = Set(metrics.evidence.map(\.evidenceClass))
        let live = try container.decode(Bool.self, forKey: .liveCapabilityObserved)
            && classes.contains(.liveToolCapability)
        let configured = try container.decode(Bool.self, forKey: .configured)
            && (classes.contains(.toolConfiguration) || live)
        self.metrics = metrics
        self.configured = configured
        self.liveCapabilityObserved = live
        self.category = Self.derive(configured: configured, liveCapabilityObserved: live, metrics: metrics)
    }

    private static func derive(
        configured: Bool,
        liveCapabilityObserved: Bool,
        metrics: BodyBeliefMetrics
    ) -> ToolCapabilityCategory {
        if liveCapabilityObserved { return .available }
        if configured { return .configured }
        return metrics.uncertainty >= 0.75 ? .unknown : .unavailable
    }
}

public enum ApprovalPathCategory: String, Codable, Sendable, Equatable {
    case open
    case closed
    case unknown
}

public struct ApprovalPathReading: Codable, Sendable, Equatable {
    public let category: ApprovalPathCategory
    public let metrics: BodyBeliefMetrics
    public let writable: Bool

    public var compatibilityOpen: Bool? { category == .unknown ? nil : category == .open }

    public init(generatedAt: Date, writable: Bool?, evidence: [BodyEvidenceReference]) {
        self.writable = writable == true
        self.metrics = BodyBeliefMetrics(
            generatedAt: generatedAt,
            estimate: writable == true ? 1 : 0,
            uncertainty: writable == nil ? 1 : 0,
            freshness: writable == nil ? 0 : 1,
            evidence: evidence,
            observedAt: generatedAt,
            receivedAt: generatedAt
        )
        self.category = writable.map { $0 ? .open : .closed } ?? .unknown
    }

    private enum CodingKeys: String, CodingKey { case category, metrics, writable }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metrics = try container.decode(BodyBeliefMetrics.self, forKey: .metrics)
        let writable = try container.decode(Bool.self, forKey: .writable)
            && metrics.evidence.contains { $0.evidenceClass == .approvalStore }
        self.metrics = metrics
        self.writable = writable
        self.category = metrics.uncertainty >= 0.75 ? .unknown : (writable ? .open : .closed)
    }
}

public struct ResourcePressureReading: Codable, Sendable, Equatable {
    public let category: OrganismResourcePressure
    public let metrics: BodyBeliefMetrics
    public let thermalPressure: OrganismResourcePressure

    public init(
        generatedAt: Date,
        thermalPressure: OrganismResourcePressure,
        evidence: [BodyEvidenceReference]
    ) {
        // Heat alone sets resource pressure; Low Power Mode never changes her work.
        self.thermalPressure = thermalPressure
        self.category = thermalPressure
        self.metrics = BodyBeliefMetrics(
            generatedAt: generatedAt,
            estimate: Self.estimate(category),
            uncertainty: 0,
            freshness: 1,
            evidence: evidence,
            observedAt: generatedAt,
            receivedAt: generatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case category, metrics, thermalPressure
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let thermal = try container.decode(OrganismResourcePressure.self, forKey: .thermalPressure)
        let decodedMetrics = try container.decode(BodyBeliefMetrics.self, forKey: .metrics)
        self.thermalPressure = thermal
        self.category = thermal
        self.metrics = BodyBeliefMetrics(
            generatedAt: decodedMetrics.generatedAt,
            estimate: Self.estimate(category),
            uncertainty: 0,
            freshness: 1,
            evidence: decodedMetrics.evidence,
            observedAt: decodedMetrics.observedAt,
            receivedAt: decodedMetrics.receivedAt,
            nextMeaningfulExpiry: nil
        )
    }

    private static func estimate(_ pressure: OrganismResourcePressure) -> Double {
        switch pressure {
        case .nominal: 0
        case .elevated: 1.0 / 3.0
        case .high: 2.0 / 3.0
        case .critical: 1
        }
    }

}
