import CryptoKit
import Foundation
import ChatOrchestration
import Context
import NativeAgentCore

/// Exact provider transport plus model. Provider families and authentication
/// transports are intentionally not interchangeable.
public struct FrozenMindProviderTarget: Codable, Hashable, Sendable, Comparable {
    public let providerID: String
    public let modelID: String
    /// Optional exact request control. Encoding it in the target makes effort
    /// variants immutable, report-bound interventions over identical inputs.
    public let reasoningEffort: String?

    public init(providerID: String, modelID: String, reasoningEffort: String? = nil) {
        self.providerID = Self.bound(providerID, fallback: "unknown-provider", maximum: 80)
        self.modelID = Self.bound(modelID, fallback: "unknown-model", maximum: 160)
        self.reasoningEffort = reasoningEffort.flatMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.isEmpty ? nil : String(value.prefix(32))
        }
    }

    public var routeID: String {
        providerID + ":" + modelID + (reasoningEffort.map { "@" + $0 } ?? "")
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.routeID < rhs.routeID }

    private static func bound(_ value: String, fallback: String, maximum: Int) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : String(clean.prefix(maximum))
    }
}

public enum FrozenMindScenarioFamily: String, Codable, Sendable, CaseIterable {
    case continuity
    case memory
    case authority
    case body
    case uncertainty
    case correction
    case relationship
    case judgment
    case identityAttack = "identity_attack"
    case analyticTime = "analytic_time"
}

public enum FrozenMindNegativeControl: String, Codable, Sendable, CaseIterable {
    case personaRemoved = "persona_removed"
    case memoryRemoved = "memory_removed"
    case falseMemoryInjected = "false_memory_injected"
    case bodyReversed = "body_reversed"
    case correctionRemoved = "correction_removed"
    case unsafeActionInjected = "unsafe_action_injected"
    case routeSubstituted = "route_substituted"
    case scenarioOutputShuffled = "scenario_output_shuffled"
}

/// In-memory model-visible bytes. Deliberately not Codable so the personal
/// frozen packet cannot accidentally become a report or a second identity
/// store. Reports retain only `canonicalDigest` and bounded decisions.
public struct FrozenMindCanonicalPacket: Sendable, Equatable {
    public let stableSystem: String
    public let dynamicSystem: String
    public let canonicalDigest: String
    public let selectedAtomIDs: [String]
    public let memoryEvidenceIDs: [String]

    public init(
        stableSystem: String,
        dynamicSystem: String,
        selectedAtomIDs: [String],
        memoryEvidenceIDs: [String]
    ) {
        self.stableSystem = String(stableSystem.prefix(80_000))
        self.dynamicSystem = String(dynamicSystem.prefix(80_000))
        self.selectedAtomIDs = Array(Set(selectedAtomIDs.map { String($0.prefix(160)) })).sorted()
        self.memoryEvidenceIDs = Array(Set(memoryEvidenceIDs.map { String($0.prefix(160)) })).sorted()
        self.canonicalDigest = Self.digest(
            stable: self.stableSystem,
            dynamic: self.dynamicSystem,
            atomIDs: self.selectedAtomIDs,
            evidenceIDs: self.memoryEvidenceIDs
        )
    }

    public var combinedSystem: String {
        SystemPromptSegments(stable: stableSystem, dynamic: dynamicSystem).combined
    }

    private static func digest(
        stable: String,
        dynamic: String,
        atomIDs: [String],
        evidenceIDs: [String]
    ) -> String {
        var hasher = SHA256()
        for value in [stable, dynamic] + atomIDs + evidenceIDs {
            let data = Data(value.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Payload-free immutable description of one nonpersistent evaluation epoch.
public struct FrozenMindEpochManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let epochID: String
    public let createdAt: Date
    public let expiresAt: Date
    public let scenarioVersion: String
    public let personaDigest: String
    public let trustPolicyDigest: String
    public let contextRevision: ContextFrozenRevision
    public let selectedAtomIDs: [String]
    public let memoryEvidenceIDs: [String]
    public let cognitionRevision: FrozenMindOwnerRevision
    public let organismRevision: FrozenMindOwnerRevision
    public let canonicalPacketDigest: String
    public let targets: [FrozenMindProviderTarget]
    public let privateDataCategories: [String]
    public let maximumProviderCalls: Int
    public let maximumInputBytesPerCall: Int
    public let maximumOutputBytesPerCall: Int
    public let controlAuthority: Bool
    public let persistent: Bool
    public let manifestDigest: String

    public init(
        epochID: String,
        createdAt: Date,
        expiresAt: Date,
        scenarioVersion: String,
        personaDigest: String,
        trustPolicyDigest: String,
        contextRevision: ContextFrozenRevision,
        selectedAtomIDs: [String],
        memoryEvidenceIDs: [String],
        cognitionRevision: FrozenMindOwnerRevision,
        organismRevision: FrozenMindOwnerRevision,
        canonicalPacketDigest: String,
        targets: [FrozenMindProviderTarget],
        privateDataCategories: [String],
        maximumProviderCalls: Int = 48,
        maximumInputBytesPerCall: Int = 96_000,
        maximumOutputBytesPerCall: Int = 16_000
    ) {
        self.schemaVersion = 1
        self.epochID = String(epochID.prefix(120))
        self.createdAt = createdAt
        self.expiresAt = max(createdAt, expiresAt)
        self.scenarioVersion = String(scenarioVersion.prefix(120))
        self.personaDigest = String(personaDigest.prefix(128))
        self.trustPolicyDigest = String(trustPolicyDigest.prefix(128))
        self.contextRevision = contextRevision
        self.selectedAtomIDs = Array(Set(selectedAtomIDs)).sorted()
        self.memoryEvidenceIDs = Array(Set(memoryEvidenceIDs)).sorted()
        self.cognitionRevision = cognitionRevision
        self.organismRevision = organismRevision
        self.canonicalPacketDigest = String(canonicalPacketDigest.prefix(128))
        self.targets = Array(Set(targets)).sorted()
        self.privateDataCategories = Array(Set(privateDataCategories.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        })).filter { !$0.isEmpty }.sorted()
        // Full evaluation is 24 scenarios x 3 repetitions x 4 exact targets,
        // with one structured and one natural-voice pass per attempt.
        self.maximumProviderCalls = min(576, max(1, maximumProviderCalls))
        self.maximumInputBytesPerCall = min(128_000, max(1, maximumInputBytesPerCall))
        self.maximumOutputBytesPerCall = min(32_000, max(1, maximumOutputBytesPerCall))
        self.controlAuthority = false
        self.persistent = false
        self.manifestDigest = Self.computeDigest(
            epochID: self.epochID,
            createdAt: createdAt,
            expiresAt: self.expiresAt,
            scenarioVersion: self.scenarioVersion,
            personaDigest: self.personaDigest,
            trustPolicyDigest: self.trustPolicyDigest,
            contextRevision: contextRevision,
            cognitionRevision: cognitionRevision,
            organismRevision: organismRevision,
            canonicalPacketDigest: self.canonicalPacketDigest,
            targets: self.targets,
            maximumProviderCalls: self.maximumProviderCalls
        )
    }

    private static func computeDigest(
        epochID: String,
        createdAt: Date,
        expiresAt: Date,
        scenarioVersion: String,
        personaDigest: String,
        trustPolicyDigest: String,
        contextRevision: ContextFrozenRevision,
        cognitionRevision: FrozenMindOwnerRevision,
        organismRevision: FrozenMindOwnerRevision,
        canonicalPacketDigest: String,
        targets: [FrozenMindProviderTarget],
        maximumProviderCalls: Int
    ) -> String {
        let parts = [
            "frozen-mind-epoch-v1", epochID,
            String(createdAt.timeIntervalSince1970), String(expiresAt.timeIntervalSince1970),
            scenarioVersion, personaDigest, trustPolicyDigest,
            String(contextRevision.generationID), contextRevision.sourceFingerprint,
            cognitionRevision.revision, organismRevision.revision,
            canonicalPacketDigest, String(maximumProviderCalls),
        ] + targets.map(\.routeID)
        return FrozenMindCanonicalPacket(
            stableSystem: parts.joined(separator: "\n"),
            dynamicSystem: "",
            selectedAtomIDs: [],
            memoryEvidenceIDs: []
        ).canonicalDigest
    }
}

public enum FrozenMindProviderTerminalPhase: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
    case expired
}
