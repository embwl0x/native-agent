import EngineRuntime
import Connectors
import DoctorChecks
import TrustPersistence
import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct PolicySimulation: Codable, Hashable {
    var allowed: Bool
    var requiresApproval: Bool
    var risk: String
    var action: String
    var reasons: [String]

    /// The SecurityCenter returns a fail-closed envelope when its saved policy
    /// cannot be read. That is not a policy denial: the simulator has no
    /// authority generation to evaluate, so the UI must say it is unavailable.
    var authorityUnavailable: Bool {
        reasons.contains {
            $0.localizedCaseInsensitiveContains("saved trust policy is unavailable")
        }
    }
}

enum PolicySimulationVerdict: Equatable {
    case allowed
    case approvalRequired
    case denied
    case unavailable

    init(simulation: PolicySimulation) {
        if simulation.authorityUnavailable {
            self = .unavailable
        } else if simulation.requiresApproval {
            self = .approvalRequired
        } else if simulation.allowed {
            self = .allowed
        } else {
            self = .denied
        }
    }

    var title: String {
        switch self {
        case .allowed: "Allowed"
        case .approvalRequired: "Requires Approval"
        case .denied: "Denied"
        case .unavailable: "Policy Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .allowed: "checkmark.circle"
        case .approvalRequired: "hand.raised.circle"
        case .denied: "xmark.octagon"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}

typealias BackupRecord = TrustPersistence.BackupRecord
typealias BackupRestoreResult = TrustPersistence.BackupRestoreResult

typealias ConnectorRecord = EngineRuntime.ConnectorRecord

typealias WorkspaceRecord = Connectors.WorkspaceRecord

struct WorkspaceSearchResult: Identifiable, Codable, Hashable {
    var workspaceId: String?
    var workspaceName: String?
    var path: String
    var relativePath: String
    var reason: String

    var id: String { path }
}

struct WorkspaceSearchResponse: Codable, Hashable {
    var query: String
    var results: [WorkspaceSearchResult]
}

// FIX: only `id` truly required; non-identifying fields defaulted so one
// omitted key doesn't throw the whole endpoint decode.
struct EvalCheck: Identifiable, Codable, Hashable {
    var id: String
    var title: String = ""
    var passed: Bool = false
    var detail: String = ""

    // FIX-2026-05-28: synthesized Decodable throws keyNotFound on missing non-
    // optional keys despite Swift defaults; decodeIfPresent ?? default fixes it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.passed = try c.decodeIfPresent(Bool.self, forKey: .passed) ?? false
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

struct EvalRun: Identifiable, Codable, Hashable {
    var id: String
    var name: String = ""
    var status: String = ""
    var checks: [EvalCheck] = []
    var createdAt: String = ""
    var durationSeconds: Double?

    // FIX-2026-05-28: see EvalCheck. id required; everything else lenient.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        self.checks = try c.decodeIfPresent([EvalCheck].self, forKey: .checks) ?? []
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
    }
}

typealias ReleaseChecklistItem = DoctorChecks.ReleaseChecklistItem

typealias ReleaseChecklist = DoctorChecks.ReleaseChecklist
