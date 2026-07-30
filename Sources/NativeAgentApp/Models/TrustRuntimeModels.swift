import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct KernelGuardrail: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var status: String
}

struct ApprovalClass: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var requiresApproval: Bool
}

struct AutonomyKernelSummary: Codable, Hashable {
    var status: String
    var mode: String?
    var enabled: Bool?
    var processEnabled: Bool?
    var trustEnabled: Bool?
    var disabledReason: String?
    var guardrails: [KernelGuardrail]
    var approvalClasses: [ApprovalClass]
    var runningImprovements: Int?
    var createdAt: String?
}

struct PersonalOSSpace: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var count: Int
    var kind: String?
}

struct PersonalOSSummary: Codable, Hashable {
    var spaces: [PersonalOSSpace]
    var createdAt: String?
}

struct CapabilityCatalogItem: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: String?
    var description: String?
    var status: String?
    var riskClass: String?
    var installed: Bool?
    var provenance: String?
    var installedAt: String?
}

struct CapabilityPackInstall: Identifiable, Codable, Hashable {
    var id: String
    var packId: String
    var name: String?
    var version: String?
    var status: String
    var signature: String?
    var installedAt: String?
    var rolledBackAt: String?
}

struct CapabilityCatalogSource: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: String?
    var url: String?
    var status: String?
    var trustedRootId: String?
    var lastCheckedAt: String?
    var createdAt: String?
    var updatedAt: String?
}

struct CapabilityTrustRoot: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: String?
    var fingerprint: String?
    var status: String?
    var createdAt: String?
    var updatedAt: String?
}

struct CapabilityTrustRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String?
    var kind: String?
    var status: String?
    var riskClass: String?
    var trustScore: Double?
    var trustTier: String?
    var reasons: [String]?
}

struct CapabilityTrustSummary: Codable, Hashable {
    var trusted: Int
    var review: Int
    var untrusted: Int
}

struct CapabilityTrustNetwork: Codable, Hashable {
    var status: String
    var roots: [CapabilityTrustRoot]
    var sources: [CapabilityCatalogSource]
    var records: [CapabilityTrustRecord]
    var summary: CapabilityTrustSummary?
    var createdAt: String?
}

struct CapabilityTrustEvaluation: Codable, Hashable {
    var id: String
    var name: String?
    var trustScore: Double
    var trustTier: String
    var reasons: [String]
    var createdAt: String?
}

struct CapabilityUpdateRecord: Identifiable, Codable, Hashable {
    var id: String
    var packId: String?
    var installedVersion: String?
    var availableVersion: String?
    var status: String?
    var sourceId: String?
}

struct CapabilityUpdateCheck: Codable, Hashable {
    var status: String
    var updates: [CapabilityUpdateRecord]
    var sourceCount: Int?
    var createdAt: String?
}

struct PersonalityGrowthSummary: Codable, Hashable {
    var engineVersion: String
    var activeKind: String?
    var fingerprint: String?
    var growthEntries: Int
    var feedbackMemories: Int
    var nextActions: [String]
    var createdAt: String?
}

struct NativePowerSurface: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var status: String
    var detail: String?
}

struct NativePowerSummary: Codable, Hashable {
    var surfaces: [NativePowerSurface]
    var createdAt: String?
}

struct NativeActionRegistry: Codable, Hashable {
    var status: String
    var actions: [NativeActionRecord]
    var createdAt: String?
}

struct NativeActionRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: String?
    var risk: String?
    var requiresApproval: Bool?
    var dryRunAvailable: Bool?
}

struct NativeActionReceipt: Identifiable, Codable, Hashable {
    var id: String
    var actionId: String
    var name: String?
    var kind: String?
    var status: String
    var dryRun: Bool?
    var approvalId: String?
    var createdAt: String?
    var url: String?
    var textPath: String?
    var textPreview: String?
    var textChars: Int64?
    var linksPath: String?
    var pngPath: String?
    var linkCount: Int64?
    var linksPreview: [BrowserLink]?
}

struct NativeIntentRegistry: Codable, Hashable {
    var status: String
    var source: String?
    var intentCount: Int
    var actionsAvailable: [String]?
    var intents: [NativeIntentRecord]
    var receipts: [NativeIntentReceipt]?
    var createdAt: String?
}

struct NativeIntentRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var actionId: String?
    var risk: String?
    var returns: String?
}

struct NativeIntentReceipt: Identifiable, Codable, Hashable {
    var id: String
    var intentId: String
    var status: String
    var createdAt: String?
}

struct NotificationRuntimeStatus: Codable, Hashable {
    var status: String
    var authorization: String?
    var pendingApprovals: Int?
    var receiptCount: Int?
    var latestReceipt: NativeActionReceipt?
    var createdAt: String?
}

struct BrowserRuntimeStatus: Codable, Hashable {
    var status: String
    var profilePath: String?
    var sourcePath: String?
    var screenshotPath: String?
    var approvedDomains: [String]?
    var domainPolicy: String?
    var activeRuns: [BrowserRun]?
    var receiptCount: Int?
    var latestReceipt: BrowserRun?
    var createdAt: String?
}

struct BrowserRun: Identifiable, Codable, Hashable {
    var id: String
    var url: String?
    var domain: String?
    var status: String
    var dryRun: Bool?
    var visible: Bool?
    var opened: Bool?
    var approvalId: String?
    var createdAt: String?
}
