import EngineRuntime
import NativeAgentCore
import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

typealias KernelGuardrail = EngineRuntime.KernelGuardrail

typealias ApprovalClass = EngineRuntime.ApprovalClass

typealias AutonomyKernelSummary = EngineRuntime.AutonomyKernelSummary

typealias PersonalOSSpace = EngineRuntime.PersonalOSSpace

typealias PersonalOSSummary = EngineRuntime.PersonalOSSummary

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

typealias PersonalityGrowthSummary = EngineRuntime.PersonalityGrowthSummary

struct NativeActionRegistry: Codable, Hashable {
    var status: String
    var actions: [NativeActionRecord]
    var createdAt: String?
}

typealias NativeActionRecord = NativeAgentCore.NativeActionRecord

typealias NativeActionReceipt = EngineRuntime.NativeActionReceipt

typealias NotificationRuntimeStatus = EngineRuntime.NotificationRuntimeStatus

typealias BrowserRuntimeStatus = EngineRuntime.BrowserRuntimeStatus

typealias BrowserRun = EngineRuntime.BrowserRun
