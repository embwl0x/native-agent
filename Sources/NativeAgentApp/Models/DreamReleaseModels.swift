import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct DreamEntry: Codable, Hashable, Identifiable {
    var date: String
    var filename: String?
    var content: String
    var size: Int?
    var modified_at: String?   // present on diary/today, absent on single-date GET

    var id: String { date }

    init(date: String, filename: String? = nil, content: String, size: Int? = nil, modified_at: String? = nil) {
        self.date = date
        self.filename = filename
        self.content = content
        self.size = size
        self.modified_at = modified_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        modified_at = try c.decodeIfPresent(String.self, forKey: .modified_at)
    }
}

struct DreamDiaryResponse: Codable, Hashable {
    var entries: [DreamEntry]
    var enabled: Bool

    init(entries: [DreamEntry] = [], enabled: Bool = false) {
        self.entries = entries
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([DreamEntry].self, forKey: .entries) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

struct PolicySimulation: Codable, Hashable {
    var allowed: Bool
    var requiresApproval: Bool
    var risk: String
    var action: String
    var reasons: [String]
}

struct BackupRecord: Identifiable, Codable, Hashable {
    var id: String
    var reason: String
    var scope: [String]
    var path: String
    var createdAt: String
}

struct BackupRestoreResult: Codable, Hashable {
    var id: String
    var restored: [String]
    var restoredAt: String
}

struct ConnectorRecord: Identifiable, Codable, Hashable {
    var id: String
    // FIX: non-identifying fields defaulted so one omitted key doesn't drop the
    // whole connector record (getConnectors is also lossy now). Only id required.
    var name: String = ""
    var kind: String = ""
    var description: String = ""
    var enabled: Bool = false
    var authState: String?
    var healthStatus: String?
    var riskClass: String?
    var permissions: [String]?
    var actions: [String]?
    var lastCheckedAt: String?
    var updatedAt: String?

    // FIX-2026-05-28: synthesized Decodable throws keyNotFound on a missing
    // non-optional key even with a Swift default, so the defaults above were
    // dead for decoding. Use decodeIfPresent ?? default; keep id required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.authState = try c.decodeIfPresent(String.self, forKey: .authState)
        self.healthStatus = try c.decodeIfPresent(String.self, forKey: .healthStatus)
        self.riskClass = try c.decodeIfPresent(String.self, forKey: .riskClass)
        self.permissions = try c.decodeIfPresent([String].self, forKey: .permissions)
        self.actions = try c.decodeIfPresent([String].self, forKey: .actions)
        self.lastCheckedAt = try c.decodeIfPresent(String.self, forKey: .lastCheckedAt)
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct WorkspaceRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var path: String
    var permissions: [String]
    var createdAt: String
    var lastUsedAt: String?
}

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

struct ReleaseChecklistItem: Identifiable, Codable, Hashable {
    var id: String
    var title: String = ""
    var status: String = ""
    var detail: String = ""

    // FIX-2026-05-28: see EvalCheck. id required; everything else lenient.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

struct ReleaseChecklist: Codable, Hashable {
    var status: String = ""
    var items: [ReleaseChecklistItem] = []
    var createdAt: String = ""

    // FIX-2026-05-28: no id — every field tolerates a missing key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        self.items = try c.decodeIfPresent([ReleaseChecklistItem].self, forKey: .items) ?? []
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

struct WatchdogStatus: Codable, Hashable {
    var daemon: String = ""
    var uptimeSeconds: Double = 0
    var daemonLifecycleStatus: String = ""
    var daemonLifecycleDetail: String = ""
    var launchAgentStatus: String = ""
    var launchAgentDetail: String = ""
    var runningImprovements: Int = 0
    var runningExecutions: Int = 0
    var lastActivity: ActivityEvent?
    var repairAvailable: Bool = false

    enum CodingKeys: String, CodingKey {
        case daemon, uptimeSeconds, daemonLifecycleStatus, daemonLifecycleDetail
        case launchAgentStatus, launchAgentDetail, runningImprovements
        case runningExecutions = "runningMissions" // compatibility wire ID
        case lastActivity, repairAvailable
    }

    var runtimeBadgeText: String {
        let trimmed = daemon.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "RUNTIME" : trimmed.uppercased()
    }

    var runtimeBadgeStatus: String {
        switch runtimeLifecycleStatus.lowercased() {
        case "ok", "running", "active": return "ok"
        case "stopped", "warn", "warning": return "warn"
        case "fail", "failed", "error": return "error"
        default:
            return daemon.lowercased() == "swift" ? "ok" : (daemon.isEmpty ? "unknown" : daemon)
        }
    }

    var runtimeLifecycleStatus: String {
        let lifecycle = daemonLifecycleStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lifecycle.isEmpty { return lifecycle }
        if daemon.lowercased() == "swift", launchAgentStatus == "not_applicable" {
            return "ok"
        }
        return launchAgentStatus
    }

    var runtimeLifecycleDetail: String {
        let lifecycle = daemonLifecycleDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lifecycle.isEmpty { return lifecycle }
        if daemon.lowercased() == "swift", launchAgentStatus == "not_applicable" {
            return "Swift runtime is owned by NativeAgent.app."
        }
        return launchAgentDetail
    }

    // FIX-2026-05-28: no id — every field tolerates a missing key. lastActivity
    // is already optional → decodeIfPresent ?? nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.daemon = try c.decodeIfPresent(String.self, forKey: .daemon) ?? ""
        self.uptimeSeconds = try c.decodeIfPresent(Double.self, forKey: .uptimeSeconds) ?? 0
        self.daemonLifecycleStatus = try c.decodeIfPresent(String.self, forKey: .daemonLifecycleStatus) ?? ""
        self.daemonLifecycleDetail = try c.decodeIfPresent(String.self, forKey: .daemonLifecycleDetail) ?? ""
        self.launchAgentStatus = try c.decodeIfPresent(String.self, forKey: .launchAgentStatus) ?? ""
        self.launchAgentDetail = try c.decodeIfPresent(String.self, forKey: .launchAgentDetail) ?? ""
        self.runningImprovements = try c.decodeIfPresent(Int.self, forKey: .runningImprovements) ?? 0
        self.runningExecutions = try c.decodeIfPresent(Int.self, forKey: .runningExecutions) ?? 0
        self.lastActivity = try c.decodeIfPresent(ActivityEvent.self, forKey: .lastActivity) ?? nil
        self.repairAvailable = try c.decodeIfPresent(Bool.self, forKey: .repairAvailable) ?? false
    }
}
