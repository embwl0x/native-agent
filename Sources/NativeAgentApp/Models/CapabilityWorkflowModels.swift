import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import SystemOps
import TrustCenter
import DoctorChecks

struct PrivacyCategory: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var path: String
    var contains: String
    var exportable: Bool
}

struct PrivacyMap: Codable, Hashable {
    var dataRoot: String
    var categories: [PrivacyCategory]
    var generatedAt: String

    /// What lives where under this data root, and what an export may carry.
    init(dataRoot: URL) {
        self.dataRoot = dataRoot.path
        self.categories = Self.categories(dataRoot: dataRoot)
        self.generatedAt = SwiftNativeManifestSigner.isoTimestamp(Date())
    }

    /// Each folder walked now: a whole data root takes seconds, so the page
    /// asks off the main actor and shows the map when the walk lands.
    private static func categories(dataRoot: URL) -> [PrivacyCategory] {
        struct Spec {
            var id: String
            var title: String
            var relativePath: String
            var detail: String
            var exportable: Bool
        }
        let specs: [Spec] = [
            Spec(id: "persona", title: "Persona", relativePath: "persona", detail: "agent identity, voice, profile, and onboarding state", exportable: true),
            Spec(id: "memory", title: "Memory", relativePath: "memory", detail: "semantic memories, recall indexes, and knowledge graph state", exportable: true),
            Spec(id: "chat", title: "Chat", relativePath: "chat", detail: "chat sessions, messages, context receipts, and session state", exportable: true),
            Spec(id: "activity", title: "Activity", relativePath: "activity", detail: "activity events, traces, receipts, and runtime audit rows", exportable: true),
            // W8 (2026-08-14) — the ambient activity watcher's store. A
            // SEPARATE directory from `activity/` above, and `exportable:
            // false`, both on purpose. `activity/` is the app's own event feed
            // and it is exported, backed up and shipped in support bundles;
            // putting a record of every window the human looked at inside it
            // would have opted this feature into three egress paths by
            // filename collision alone. Nothing copies `activity_watch` —
            // not backups, not exports, not support bundles, not the iCloud
            // snapshot — and ActivityWatchArchitectureTests reads those lists
            // and fails if that changes.
            Spec(id: "activity_watch", title: "Activity Capture", relativePath: "activity_watch", detail: "locally-recorded app usage spans (app name, duration, redacted window title where enabled) — never exported, backed up, or synced", exportable: false),
            Spec(id: "approvals", title: "Approvals", relativePath: "workflows/approvals", detail: "approval requests and resolved decisions", exportable: true),
            Spec(id: "connectors", title: "Connectors", relativePath: "connectors", detail: "connector registry, workspace records, and action receipts", exportable: true),
            Spec(id: "oauth_tokens", title: "OAuth Tokens", relativePath: "oauth_tokens", detail: "connector OAuth token material", exportable: false),
            Spec(id: "secrets", title: "Secrets", relativePath: "secrets", detail: "secret-bearing local runtime state", exportable: false),
            Spec(id: "sense_ledger", title: "Sense Wall Ledger", relativePath: "senses/ledger", detail: "private local wall history and growth needs — never exported, backed up, shared, or synced", exportable: false),
            Spec(id: "sense_news", title: "Unread Sense News", relativePath: "senses/news", detail: "private pending news and delivery deduplication — never exported, backed up, shared, or synced", exportable: false),
            Spec(id: "providers", title: "Providers", relativePath: "providers", detail: "provider auth/configuration state", exportable: false),
            Spec(id: "codex_home", title: "Codex Home", relativePath: "codex_home", detail: "app-owned Codex auth and session files", exportable: false),
            Spec(id: "tools", title: "Tools", relativePath: "tools", detail: "tool registry, runtime receipts, proposals, and quarantine state", exportable: true),
            Spec(id: "skills", title: "Skills", relativePath: "skills", detail: "skill registry and app-owned skill bodies", exportable: true),
            Spec(id: "workflows", title: "Workflows", relativePath: "workflows", detail: "workflow registry, runs, and run state", exportable: true),
            Spec(id: "scheduler", title: "Scheduler", relativePath: "scheduler", detail: "Swift scheduled jobs and trigger records", exportable: true),
            Spec(id: "mcp", title: "MCP", relativePath: "mcp", detail: "MCP server registry, sessions, consent ledger, and cache", exportable: true),
            Spec(id: "telegram", title: "Telegram", relativePath: "telegram", detail: "Telegram runtime configuration, offsets, receipts, and voice temp state", exportable: false),
            Spec(id: "mobile_push", title: "Mobile Push", relativePath: "mobile_push", detail: "iOS/APNS pairing and notification delivery state", exportable: false),
            Spec(id: "icloud", title: "iCloud Bridge", relativePath: "icloud", detail: "iCloud bridge transaction and sync state", exportable: false),
            Spec(id: "improvements", title: "Self Improvement", relativePath: "improvements", detail: "evaluation gauntlet records", exportable: true),
            Spec(id: "backups", title: "Backups", relativePath: "backups", detail: "local backups and restore registry", exportable: false),
            Spec(id: "production", title: "Production Artifacts", relativePath: "production", detail: "exports, support bundles, and migration records", exportable: false),
            Spec(id: "logs", title: "Logs", relativePath: "logs", detail: "runtime logs and diagnostic output", exportable: false),
            Spec(id: "crash_reports", title: "Crash Reports", relativePath: "crash_reports", detail: "submitted crash report payloads", exportable: false),
        ]
        return specs.map { spec in
            // The persona lives where the app reads it: beside a checkout's
            // data/, not inside it (`defaultPersonaRoot`).
            let path = spec.id == "persona"
                ? PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
                : dataRoot.appendingPathComponent(spec.relativePath)
            return PrivacyCategory(
                id: spec.id,
                title: spec.title,
                path: path.path,
                contains: "\(spec.detail); \(itemSummary(path))",
                exportable: spec.exportable
            )
        }
    }

    private static func itemSummary(_ path: URL) -> String {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            return "not present"
        }
        if !isDirectory.boolValue {
            let bytes = (try? fm.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0
            return "1 file, \(sized(bytes))"
        }
        guard let enumerator = fm.enumerator(
            at: path,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "directory present"
        }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard files < 10_000 else { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values?.fileSize ?? 0)
        }
        if files >= 10_000 {
            return "10,000+ files, \(sized(bytes)) scanned"
        }
        return "\(files.formatted()) file\(files == 1 ? "" : "s"), \(sized(bytes))"
    }

    /// "47 MB": the Mac's own file sizes, not raw bytes.
    private static func sized(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct SupportDiagnostics: Codable, Hashable {
    var app: String
    var version: String
    var doctorStatus: String?
    var generatedAt: String

    /// The Support Snapshot. `reusing` takes a still-fresh `DoctorReport`
    /// so the full offline Doctor pass is not re-run just for the rollup: the
    /// reuse path excludes exactly the app-added live-coverage checks
    /// (`live.*`) that `runAll` never produces, so the snapshot is
    /// byte-identical to a cold run. The export path (and any stale-cache
    /// caller) passes nil → full run.
    static func read(reusing report: DoctorReport? = nil) async throws -> SupportDiagnostics {
        let doctorStatus: String
        if let report {
            doctorStatus = DoctorStatusProjection.supportSnapshotOfflineRollup(report.checks)
        } else {
            let statuses = try await makeDoctorChecks().runAll(repair: false).map(\.status)
            doctorStatus = DoctorStatusProjection.supportSnapshotRollup(statuses)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return SupportDiagnostics(
            app: "NativeAgent",
            version: version,
            doctorStatus: doctorStatus,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }
}

struct IntentRoutePlan: Identifiable, Codable, Hashable {
    var id: String
    var message: String
    var goalType: String
    var recommendedSurface: String?
    var risk: String
    var requiresApproval: Bool
    var matchedCapabilities: [CapabilityRecord]
    var nextActions: [String]
    var createdAt: String?

    /// The router's plan, its matched catalog rows read as capabilities.
    init(_ plan: RoutePlanResult) throws {
        self.init(
            id: plan.id, message: plan.message, goalType: plan.goalType,
            recommendedSurface: plan.recommendedSurface, risk: plan.risk,
            requiresApproval: plan.requiresApproval,
            matchedCapabilities: try plan.matchedCapabilities.map { value in
                guard case .object(let row) = value else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "A capability is a JSON object."))
                }
                return try CapabilityRecord(catalogRow: row)
            },
            nextActions: plan.nextActions, createdAt: plan.createdAt
        )
    }

    init(
        id: String, message: String, goalType: String, recommendedSurface: String?, risk: String,
        requiresApproval: Bool, matchedCapabilities: [CapabilityRecord], nextActions: [String], createdAt: String?
    ) {
        self.id = id; self.message = message; self.goalType = goalType
        self.recommendedSurface = recommendedSurface; self.risk = risk
        self.requiresApproval = requiresApproval; self.matchedCapabilities = matchedCapabilities
        self.nextActions = nextActions; self.createdAt = createdAt
    }
}

/// Mounted Intent Router state. A successful plan with no matching
/// capabilities is useful evidence; it must never look like the router did
/// not run or that it failed before producing a plan.
enum IntentRoutePresentation: Equatable {
    case idle
    case planning
    case plan(IntentRoutePlan)
    case failed(String)

    enum CapabilityMatchState: Equatable {
        case matches([CapabilityRecord])
        case noMatches
    }

    var capabilityMatchState: CapabilityMatchState? {
        guard case let .plan(plan) = self else { return nil }
        return plan.matchedCapabilities.isEmpty
            ? .noMatches
            : .matches(plan.matchedCapabilities)
    }

    var isPlanning: Bool {
        if case .planning = self { return true }
        return false
    }

    static func boundedFailure(_ error: Error) -> String {
        UserFacingError.cause(error, action: "plan that route")
    }
}

// 2026-09-01: `WorkflowRun` and its run-control projection were retired with
// the workflow run engine (User authorized). The registry record
// (WorkflowOrchestration's `WorkflowRecord`) is what the Capabilities panel
// still reads.

// ApprovalRequest moved to NativeAgentShared.
