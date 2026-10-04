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
