import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
// Blueprint: | `StorageChecks.swift` | StorageCheck prepares only STORAGE_SUBDIRS and leaves retired directories and existing contents untouched; RuntimeJSONStoresCheck inspects owner state without mutation; OpLogHealthCheck measures feed readability and compaction |

private enum DoctorJSONShape: Sendable {
    case object
    case array
}

private struct DoctorJSONStoreSpec: Sendable {
    let relativePath: String
    let shape: DoctorJSONShape
}

private enum DoctorJSONInspection {
    static func parseJSONFile(_ url: URL) throws -> JSONValue {
        let data = try Data(contentsOf: url)
        return try JSONValue.parse(data)
    }

    fileprivate static func value(_ value: JSONValue, matches shape: DoctorJSONShape) -> Bool {
        switch (shape, value) {
        case (.object, .object): return true
        case (.array, .array): return true
        default: return false
        }
    }

}

/// Canonical Swift runtime subdirectory tree created under `root`.
let STORAGE_SUBDIRS: [String] = [
    "runs", "memory",
    "chat", "chat/messages", "chat/session_state",
    "context", "context/cache", "context/feedback",
    "improvements",
    "logs",
    "scheduler",
    "config",
    "telegram",
    "codex_home",
    "work_journal",
    "activity",
    "workshop", "workshop/executions", "workshop/migrations",
    "trust",
    "backups",
    "release",
    "connectors",
    "abilities", "skills", "skills/runs",
    "tools",
    "workflows", "workflows/approvals",
    "swarms",
    "research/lab",
    "traces",
    "catalog", "catalog/quarantine", "catalog/sources", "catalog/trust",
    "native_power", "native_power/actions",
    "native_power/browser", "native_power/browser/screenshots", "native_power/browser/sources",
    "native_power/intents",
    "connectors/actions",
    "improvements/gauntlet",
    "nextgen", "nextgen/actions", "nextgen/remote",
    "production", "production/exports", "production/support",
]

/// Creates the root and every entry in `STORAGE_SUBDIRS`. Throws on the first directory it cannot create — the caller maps that
/// to status="fail".
func ensureDirs(_ root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for name in STORAGE_SUBDIRS {
        let path = root.appendingPathComponent(name)
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
    }
}

/// Prepares the runtime scaffold and checks writability with a fresh probe. Retired directories and any existing contents are
/// left for the operator.
public struct StorageCheck: DoctorCheck {
    public let id: String = "storage"
    public let title: String = "App Storage"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run() async -> CheckResult {
        let fm = FileManager.default
        do {
            try ensureDirs(root)
            let probe = root.appendingPathComponent(".doctor_probe_\(UUID().uuidString.lowercased())")
            try Data().write(to: probe, options: [.atomic])
            try fm.removeItem(at: probe)
            return CheckResult(source: root.path,
                id: id,
                title: title,
                status: "ok",
                detail: "App data is available at \(root.path)",
                repair: nil
            )
        } catch {
            return CheckResult(source: root.path,
                id: id,
                title: title,
                status: "fail",
                detail: "Could not prepare app storage: \(error.localizedDescription)",
                harm: "Conversations and memories cannot be saved on this Mac.",
                human_action: Self.accessStep(root.path),
                ask: .permission
            )
        }
    }

    /// The person's controls when this user cannot create or read app data.
    static func accessStep(_ path: String) -> String {
        "Free space in System Settings → General → Storage if the disk is full, or give this user read and write access to \(path) in Finder → Get Info → Sharing & Permissions."
    }
}

/// Inspects existing runtime stores without creating or resetting their owners' state.
public struct RuntimeJSONStoresCheck: DoctorCheck {
    public let id: String = "runtime_json_stores"
    public let title: String = "Runtime JSON Stores"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run() async -> CheckResult {
        var malformed: [String] = []
        var wrongShape: [String] = []
        for spec in Self.specs {
            let path = root.appendingPathComponent(spec.relativePath)
            // Each canonical owner decides how an absent store begins.
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            do {
                let value = try DoctorJSONInspection.parseJSONFile(path)
                if !DoctorJSONInspection.value(value, matches: spec.shape) {
                    wrongShape.append(spec.relativePath)
                }
            } catch {
                malformed.append(spec.relativePath)
            }
        }
        if !malformed.isEmpty || !wrongShape.isEmpty {
            let issueCount = malformed.count + wrongShape.count
            return CheckResult(source: (malformed + wrongShape).joined(separator: ", "),
                id: id,
                title: title,
                status: "fail",
                detail: "\(issueCount) runtime JSON store(s) are malformed or wrong-shaped: \((malformed + wrongShape).prefix(8).joined(separator: ", "))",
                harm: "Saved provider, consent or registry choices cannot be used."
            )
        }
        return CheckResult(
            id: id,
            title: title,
            status: "ok",
            detail: "Existing runtime JSON stores have valid top-level shapes."
        )
    }

    private static let specs: [DoctorJSONStoreSpec] = [
        .init(relativePath: "providers/active.json", shape: .object),
        .init(relativePath: "providers/surfaces.json", shape: .object),
        .init(relativePath: "scheduler/jobs.json", shape: .array),
        .init(relativePath: "notifications/push_tokens.json", shape: .object),
        .init(relativePath: "connectors/registry.json", shape: .array),
        .init(relativePath: "connectors/workspaces.json", shape: .array),
        .init(relativePath: "catalog/registry.json", shape: .array),
        .init(relativePath: "workflows/registry.json", shape: .array),
    ]
}

/// Fail on unreadable or undecodable feeds; compaction must preserve rows this build cannot decode. Warn on excess growth or
/// torn trailing rows; missing feeds are healthy fresh-install state.
public struct OpLogHealthCheck: DoctorCheck {
    public let id: String = "op_log_health"
    public let title: String = "Op-Log Health"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run() async -> CheckResult {
        var lines: [String] = []
        var damaged: [URL] = []
        var blocked: [URL] = []
        var warned = false

        func record(_ health: SnapshotTailOpLog.OpLogHealth) {
            lines.append(health.detailLine)
            switch health.status {
            case .blocked: blocked.append(health.path)
            case .warn: warned = true
            case .ok: break
            }
        }

        // A failed feed read contributes its own finding without aborting the remaining probes.
        do {
            record(try await SwiftNativeDeskStore(dataRoot: root, changeBus: StoreChangeBus()).opLogHealth())
        } catch {
            damaged.append(root.appendingPathComponent("desk/desk_ops.jsonl"))
            lines.append("DeskStore: unreadable — \(error)")
        }
        do {
            record(try await SwiftNativeTaskLedger(dataRoot: root).feedHealth())
        } catch {
            damaged.append(root.appendingPathComponent("orchestration/task_ledger.jsonl"))
            lines.append("TaskLedger: unreadable — \(error)")
        }

        let detail = lines.joined(separator: "; ")
        if let file = blocked.first {
            // Rows a newer build wrote are valid; only a build that reads them can compact them.
            return CheckResult(source: file.path,
                id: id, title: title, status: "fail",
                detail: "Op-log compaction is blocked: \(detail)",
                harm: "Saved work may be unreadable and its history will keep growing.",
                owner: .builder
            )
        }
        if let file = damaged.first {
            return CheckResult(source: file.path,
                id: id, title: title, status: "fail",
                detail: "An op-log feed is unreadable: \(detail)",
                harm: "Saved work may be unreadable and its history will keep growing.",
                human_action: ToolFailureError.fileRepairInstruction(file,
                    shape: "This is an append-only JSONL operation feed for its saved work store. Preserve the original operation identities, ordering and payloads, including rows from newer versions."))
        }
        if warned {
            return CheckResult(source: "desk/desk_ops.jsonl",
                id: id, title: title, status: "warn",
                detail: "An op-log feed has grown well past its compaction threshold: \(detail)",
                owner: .builder
            )
        }
        return CheckResult(source: "desk/desk_ops.jsonl", id: id, title: title, status: "ok", detail: detail)
    }
}
