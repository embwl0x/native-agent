import Foundation
import PersistenceCore

public struct PrivacyCategory: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var path: String
    public var contains: String
    public var exportable: Bool
}

public struct PrivacyMap: Codable, Hashable, Sendable {
    public var dataRoot: String
    public var categories: [PrivacyCategory]
    public var generatedAt: String

    /// What lives where under this data root, and what an export may carry.
    public init(dataRoot: URL, generatedAt: String) {
        self.dataRoot = dataRoot.path
        self.categories = Self.categories(dataRoot: dataRoot)
        self.generatedAt = generatedAt
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
            // Ambient window history stays outside activity exports, backups and sync.
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
