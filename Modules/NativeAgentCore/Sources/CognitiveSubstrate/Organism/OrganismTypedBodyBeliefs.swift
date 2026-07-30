import CryptoKit
import Foundation

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
    case maintenanceReceipt
    case dreamCompletion
    case toolConfiguration
    case liveToolCapability
    case approvalStore
    case processThermalState
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
        self.id = Self.isDigest(rawID) ? rawID : Self.digest(rawID)
        self.evidenceClass = try container.decode(BodyEvidenceClass.self, forKey: .evidenceClass)
        self.observedAt = try container.decode(Date.self, forKey: .observedAt)
        self.receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        self.reliability = Self.clamp(
            try container.decode(Double.self, forKey: .reliability),
            fallback: 0
        )
    }

    private static func digest(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = clean.isEmpty ? "anonymous" : String(clean.prefix(512))
        return SHA256.hash(data: Data(bounded.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
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

    fileprivate static func boundedEvidence(
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

    fileprivate static func freshness(
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

public enum PeerPresenceCategory: String, Codable, Sendable, Equatable {
    case present
    case stale
    case unobserved
}

public struct PeerPresenceBelief: Codable, Sendable, Equatable {
    public let category: PeerPresenceCategory
    public let metrics: BodyBeliefMetrics

    public var estimate: Double { metrics.estimate }
    public var uncertainty: Double { metrics.uncertainty }
    public var freshness: Double { metrics.freshness }
    public var evidence: [BodyEvidenceReference] { metrics.evidence }
    public var observedAt: Date? { metrics.observedAt }
    public var receivedAt: Date? { metrics.receivedAt }
    public var nextMeaningfulExpiry: Date? { metrics.nextMeaningfulExpiry }
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

    public var estimate: Double { metrics.estimate }
    public var uncertainty: Double { metrics.uncertainty }
    public var freshness: Double { metrics.freshness }
    public var evidence: [BodyEvidenceReference] { metrics.evidence }
    public var observedAt: Date? { metrics.observedAt }
    public var receivedAt: Date? { metrics.receivedAt }
    public var nextMeaningfulExpiry: Date? { metrics.nextMeaningfulExpiry }
    public var compatibilityPathHealthy: Bool? {
        if !transportConfigured { return true }
        if transportFailed { return false }
        if deviceReceived { return true }
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
        let receivedAt = bounded.first?.receivedAt
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

    public var estimate: Double { metrics.estimate }
    public var uncertainty: Double { metrics.uncertainty }
    public var freshness: Double { metrics.freshness }
    public var evidence: [BodyEvidenceReference] { metrics.evidence }
    public var observedAt: Date? { metrics.observedAt }
    public var receivedAt: Date? { metrics.receivedAt }
    public var nextMeaningfulExpiry: Date? { metrics.nextMeaningfulExpiry }
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
        let uncertainty = storeAvailable && maintenanceSucceeded == nil ? 0.25 : 0
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

    public var estimate: Double { metrics.estimate }
    public var uncertainty: Double { metrics.uncertainty }
    public var freshness: Double { metrics.freshness }
    public var evidence: [BodyEvidenceReference] { metrics.evidence }
    public var observedAt: Date? { metrics.observedAt }
    public var receivedAt: Date? { metrics.receivedAt }
    public var nextMeaningfulExpiry: Date? { metrics.nextMeaningfulExpiry }
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

    public var estimate: Double { metrics.estimate }
    public var uncertainty: Double { metrics.uncertainty }
    public var freshness: Double { metrics.freshness }
    public var evidence: [BodyEvidenceReference] { metrics.evidence }
    public var observedAt: Date? { metrics.observedAt }
    public var receivedAt: Date? { metrics.receivedAt }
    public var nextMeaningfulExpiry: Date? { metrics.nextMeaningfulExpiry }
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

    public var estimate: Double { metrics.estimate }
    public var uncertainty: Double { metrics.uncertainty }
    public var freshness: Double { metrics.freshness }
    public var evidence: [BodyEvidenceReference] { metrics.evidence }
    public var observedAt: Date? { metrics.observedAt }
    public var receivedAt: Date? { metrics.receivedAt }
    public var nextMeaningfulExpiry: Date? { metrics.nextMeaningfulExpiry }
    public var compatibilityOpen: Bool? { category == .unknown ? nil : category == .open }

    public init(generatedAt: Date, writable: Bool, evidence: [BodyEvidenceReference]) {
        self.writable = writable
        self.metrics = BodyBeliefMetrics(
            generatedAt: generatedAt,
            estimate: writable ? 1 : 0,
            uncertainty: 0,
            freshness: 1,
            evidence: evidence,
            observedAt: generatedAt,
            receivedAt: generatedAt
        )
        self.category = writable ? .open : .closed
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

// MARK: - Lossless posture decisions

public extension BodySchema {
    /// Decision helpers consume typed evidence when it exists. Compatibility
    /// booleans remain available for old readers and persistence, but an
    /// uncertainty-bearing read must not silently inherit an optimistic bit
    /// from an earlier sample.
    var providerPathRequiresCaution: Bool {
        guard providersAvailable else { return true }
        guard let belief = providerPathBelief else { return !providersHealthy }
        return belief.state != .healthy
    }

    var toolPathRequiresCaution: Bool {
        guard let reading = toolCapabilityReading else { return !toolHandsAvailable }
        switch reading.category {
        case .available, .configured:
            return false
        case .unavailable, .unknown:
            return true
        }
    }

    var memoryRequiresCurrentContext: Bool {
        guard let reading = memoryIntegrityReading else { return !memoryHealthy }
        switch reading.category {
        case .healthy:
            return false
        case .degraded, .unavailable, .unknown:
            return true
        }
    }

    var approvalRequiresPause: Bool {
        guard let reading = approvalPathReading else { return !approvalChannelsOpen }
        return reading.category != .open
    }

    var notificationRequiresReceipt: Bool {
        guard let belief = notificationDeliveryBelief else { return !notificationPathHealthy }
        switch belief.category {
        case .unconfigured, .deviceReceived, .displayed, .userSeen:
            return false
        case .configured, .transportAccepted, .failed, .unknown:
            return true
        }
    }
}

public struct ResourcePressureReading: Codable, Sendable, Equatable {
    public let category: OrganismResourcePressure
    public let metrics: BodyBeliefMetrics
    public let thermalPressure: OrganismResourcePressure
    public let lowPowerMode: Bool

    public var estimate: Double { metrics.estimate }
    public var uncertainty: Double { metrics.uncertainty }
    public var freshness: Double { metrics.freshness }
    public var evidence: [BodyEvidenceReference] { metrics.evidence }
    public var observedAt: Date? { metrics.observedAt }
    public var receivedAt: Date? { metrics.receivedAt }
    public var nextMeaningfulExpiry: Date? { metrics.nextMeaningfulExpiry }

    public init(
        generatedAt: Date,
        thermalPressure: OrganismResourcePressure,
        lowPowerMode: Bool,
        evidence: [BodyEvidenceReference]
    ) {
        self.thermalPressure = thermalPressure
        self.lowPowerMode = lowPowerMode
        self.category = Self.derive(thermalPressure: thermalPressure, lowPowerMode: lowPowerMode)
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
        case category, metrics, thermalPressure, lowPowerMode
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let thermal = try container.decode(OrganismResourcePressure.self, forKey: .thermalPressure)
        let lowPower = try container.decode(Bool.self, forKey: .lowPowerMode)
        let decodedMetrics = try container.decode(BodyBeliefMetrics.self, forKey: .metrics)
        self.thermalPressure = thermal
        self.lowPowerMode = lowPower
        self.category = Self.derive(thermalPressure: thermal, lowPowerMode: lowPower)
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

    private static func derive(
        thermalPressure: OrganismResourcePressure,
        lowPowerMode: Bool
    ) -> OrganismResourcePressure {
        guard lowPowerMode, severity(thermalPressure) < severity(.elevated) else {
            return thermalPressure
        }
        return .elevated
    }

    private static func estimate(_ pressure: OrganismResourcePressure) -> Double {
        switch pressure {
        case .nominal: 0
        case .elevated: 1.0 / 3.0
        case .high: 2.0 / 3.0
        case .critical: 1
        }
    }

    private static func severity(_ pressure: OrganismResourcePressure) -> Int {
        switch pressure {
        case .nominal: 0
        case .elevated: 1
        case .high: 2
        case .critical: 3
        }
    }
}
