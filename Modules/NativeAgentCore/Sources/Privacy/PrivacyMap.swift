import Foundation
import PersistenceCore
// Blueprint: | `PrivacyMap.swift` | Privacy inventory counts hidden retained files, including notebooks and live Procedures; helpers, triggers, Doctor, weekly improvement, REM, appraisals, preferences and secondary bridge state; declares context, dreams, traces, Desk, Workshop, Studio, Make, agents (including peers) and full agent-conversations state, Slack, onboarding controls, embedding settings/install state, notifications, saved desktops, screen state, the whole ui directory, attention and notification deduplication ledgers, welcome markers, trust/catalog, legacy approval evidence, security audit, browser runs/captures, Chrome tab mappings, browser discovery and its retired token copy, paired phones, legacy pairing bytes and their live coordination lock, phone snapshot/response/transaction cache, received phone JPEGs, Mac-control state/audits and Mac integration permission authority, swarms, builder/restart/Codex/image evidence, child credentials, live provider status/vitals and owner-resolved workspace/bridge locations once each; owns productionExportRelativePaths consumed by archive creation; export claims derive from intersecting selected paths and name partial scope; chat Markdown export and activity support bundles are named separately; storage owners state backup/export/phone decisions; Telegram state.json support, ignored legacy push tokens, chat completion-delivery state, launch retirement markers and diagnostic outputs have explicit coverage decisions |

public struct PrivacyCategory: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var path: String
    public var contains: String
    /// At least one path is selected for production export; `contains` names the exact scope.
    public var exportable: Bool
}

public struct PrivacyMap: Codable, Hashable, Sendable {
    /// Complete production copy input scopes; all unselected data-root scopes
    /// are excluded. The inventory derives its export claims here.
    public static let productionExportRelativePaths: [String] = [
        "trust",
        "memory",
        "workshop",
        "skills",
        "abilities",
        "workflows",
        "catalog/registry.json",
        "catalog/sources/sources.json",
        "catalog/trust/roots.json",
        "capabilities",
        "persona",
        "scheduler/jobs.json",
        "connectors/registry.json",
        "connectors/workspaces.json",
        "mcp/consent/ledger.json",
    ]

    public var dataRoot: String
    public var categories: [PrivacyCategory]
    public var generatedAt: String

    /// Inventory of local stores and the archive's selected paths, not an admission policy.
    /// Off-disk traversal stays with TrustBackupPersistence; phone scope names
    /// projections rather than directory replication.
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
        }
        // Provider config/consent, Codex homes, research, provider status and
        // vitals: no local backup or production export; off-disk uses credential
        // filtering (providers: active/surfaces only). Phone receives provider,
        // sign-in and routing projections; no raw files or dedicated research/vitals snapshot.
        // Session provider_usage.json: local/off-disk backup, no production
        // export or dedicated phone snapshot.
        // Chat anchor-mirror and human-reply-delivery lifecycle JSON, migration
        // inputs and quarantine bytes: off-disk backup only; no local backup,
        // production export or raw phone sync. The chat category inventories both.
        // Launch retirement markers: connectors/.retired{-github,}-told are
        // locally/off-disk backed up, not exported or phone-synced. mcp/.told is
        // off-disk only; local backup selects servers.json and consent/ledger.json.
        // BodyReport crash breadcrumbs are operator diagnostics, excluded from
        // backups, archive inputs and phone sync. EngineDoctorRuntime repair
        // receipts are off-disk/support only, with no raw phone sync.
        let specs: [Spec] = [
            Spec(id: "persona", title: "Persona", relativePath: "persona", detail: "agent identity, voice, instructions, optional persona inputs, and document recovery copies"),
            Spec(id: "onboarding", title: "Onboarding", relativePath: "onboarding", detail: "pending completion/reset transactions; excluded from local backup, export, and phone sync"),
            Spec(id: "onboarded", title: "Setup Completion", relativePath: ".onboarded", detail: "local completion sentinel; excluded from local backup, export, and phone sync"),
            Spec(id: "embeddings", title: "Embedding Settings", relativePath: "config/embeddings.json", detail: "local embedding backend selection; excluded from local backup, export, and phone sync"),
            Spec(id: "user_prefs", title: "Quiet Hours", relativePath: "user_prefs.json", detail: "retained quiet-hour preferences; off-disk backup only; no local backup, production export, or preferences-file phone snapshot"),
            Spec(id: "embedding_install", title: "Embedding Installation", relativePath: "extras", detail: "downloaded embedding model and resumable installation state; excluded from backup, export, and phone sync"),
            Spec(id: "notifications", title: "Notifications", relativePath: "notifications", detail: "live cards, archive, and canonical APNs registrations; phone receives the live-card projection; excluded from local backup and export"),
            Spec(id: "trust", title: "Trust", relativePath: "trust", detail: "saved trust policy and preserved damaged-policy evidence; backed up and exported; phone receives the policy projection"),
            Spec(id: "task_ledger", title: "Task Ledger", relativePath: "orchestration", detail: "task ledger events and compaction base; excluded from local backups and phone sync"),
            Spec(id: "native_actions", title: "Native Actions", relativePath: "native_power/actions", detail: "native action receipts; excluded from local backups and phone sync"),
            Spec(id: "page_shots", title: "Page Pictures", relativePath: "diagnostics/page_shots", detail: "PNG page pictures returned to callers; excluded from local and off-disk backups and phone sync"),
            Spec(id: "layout", title: "Layout", relativePath: "ui", detail: "surface layout and previous revision; off-disk backup only; no local backup or production export; phone sync projects the current layout as ui_layout.json"),
            Spec(id: "workspace_desktops", title: "Saved Desktops", relativePath: "workspace_desktops", detail: "navigation references and draft inputs; off-disk backup excludes lock and temporary sidecars; no local backup, production export, or phone sync"),
            Spec(id: "her_screen", title: "Her Screen", relativePath: "her_screen", detail: "stable screen names, touched items, last-seen marks, acknowledgement stamps, app maps and retained quarantine bytes; off-disk backup only; no local backup, production export, or phone sync"),
            Spec(id: "notice_state", title: "App Offers", relativePath: "notice-state.json", detail: "notice part's per-app/version offer and dismissal state; off-disk backup only; no local backup, production export, or phone copy"),
            Spec(id: "procedure_revalidation", title: "Procedure Revalidation", relativePath: "living_fabric/procedures/migrations", detail: "legacy procedure revalidation marker; off-disk backup only, no local backup, production export, or phone sync"),
            Spec(id: "memory", title: "Memory", relativePath: "memory", detail: "semantic memories, recall indexes, and knowledge graph state"),
            Spec(id: "chat", title: "Chat", relativePath: "chat", detail: "chat sessions, messages, archives, compaction copies, pins, prefix replay and session scratch state; local backups also carry queued-turn lifecycle and attachments; separate per-session Markdown export"),
            Spec(id: "context", title: "Context", relativePath: "context", detail: "derived ContextFlow SQLite generations, outcome feedback, session directives, and retained legacy receipt files and update-delivery notes"),
            Spec(id: "activity", title: "Activity", relativePath: "activity", detail: "activity events and their runtime receipts; selected by support bundles"),
            Spec(id: "traces", title: "Traces", relativePath: "traces", detail: "shared bounded diagnostic event feed and model-call telemetry, including unbound and historical calls; phone summaries contain selected telemetry only"),
            Spec(id: "mac_control_audit", title: "Mac Control Audit", relativePath: "mac_control_audit.jsonl", detail: "blocked Mac-control action receipts; off-disk backup only; no local backup, export or phone copy"),
            Spec(id: "mac_control", title: "Mac Control", relativePath: "mac_control", detail: "operation records, operator-provisioned trusted nodes and retained remote receipts; off-disk backup only; no local backup, export or phone copy"),
            Spec(id: "dream_diary", title: "Dream Diary", relativePath: "dream_diary", detail: "dream Markdown, archived entries and consolidation boundary state; local/off-disk backup; no production export or diary phone snapshot"),
            Spec(id: "desk", title: "Desk", relativePath: "desk", detail: "work operations, compaction base, archive, holds, nag configuration, and cadence statistics; excluded from local backups and production export; phone sync carries Desk projections only"),
            Spec(id: "workshop", title: "Workshop", relativePath: "workshop", detail: "execution records including legacy filenames, timelines, receipts, leases, claims, session results, and artifacts; backed up and exported; phone sync carries task projections only"),
            Spec(id: "studio", title: "Studio", relativePath: "studio", detail: "journal and archives, amendments, consults, canon and recall counters, working shelf, graph backfill marker and relation audit; off-disk backup only; no local backup, archive inputs or phone snapshot"),
            Spec(id: "agents", title: "Agents", relativePath: "agents", detail: "peer, conversation and wake state, SQLite contact tasks and retained JSON migration evidence, including credential-bearing peer configuration; off-disk backup with credential exclusions only; phone receives helper projections; no local backup or production export"),
            Spec(id: "slack", title: "Slack", relativePath: "slack", detail: "Slack configuration, session bindings, errors and inbound delivery journal; off-disk backup with credential exclusions only; no local backup, production export, or raw Slack phone snapshot"),
            Spec(id: "swarms", title: "Swarm Receipts", relativePath: "swarms", detail: "retained swarm run receipts; phone run feeds use runs/runs.json"),
            Spec(id: "builder_audit", title: "Builder Audit", relativePath: "builder_audit", detail: "builder JSON receipts and installer logs"),
            Spec(id: "restart_audit", title: "Restart Audit", relativePath: "restart_audit", detail: "restart receipts and cooldown stamp"),
            Spec(id: "from_codex", title: "Codex Replies", relativePath: "from_codex", detail: "bounded prompt/reply audits and last-message files"),
            Spec(id: "generated_images", title: "Generated Images", relativePath: "generated_images", detail: "generated image bytes, receipts and Codex working files; chat delivers selected attachments"),
            Spec(id: "phone_photos", title: "Phone Photos", relativePath: "generated/phone", detail: "received JPEGs; off-disk backup only; no production export or raw phone sync"),
            Spec(id: "codex_child_home", title: "Codex Child Home", relativePath: "codex_child_home", detail: "private child-process credentials and session files"),
            Spec(id: "bridge_codex", title: "Codex Bridge", relativePath: "codex-nativeagent-bridge", detail: "private inbox, history and reply jobs"),
            Spec(id: "bridge_claude", title: "Claude Bridge", relativePath: "claude-bridge", detail: "private inbox and delivery state"),
            Spec(id: "bridge_omp", title: "OMP Bridge", relativePath: "omp-bridge", detail: "private inbox and delivery state"),
            Spec(id: "bridge_worktrees", title: "Builder Worktrees", relativePath: "nativeagent-builder-worktrees", detail: "working-directory and continuity-token pointers"),
            Spec(id: "bots", title: "Helpers", relativePath: "bots", detail: "definitions, run state, spend and saved results; off-disk backup only; phone receives helper projections; no local backup or production export"),
            Spec(id: "rem_proposals", title: "REM Proposals", relativePath: "rem_proposals.jsonl", detail: "proposal feed; off-disk backup only; no local backup, production export, or REM phone snapshot"),
            Spec(id: "rem_proposals_base", title: "REM Proposal Base", relativePath: "rem_proposals_base.json", detail: "proposal compaction base; off-disk backup only; no local backup, production export, or REM phone snapshot"),
            Spec(id: "rem_pins", title: "REM Pins", relativePath: "rem_pins.json", detail: "proposal pin index; off-disk backup only; no local backup, production export, or REM phone snapshot"),
            Spec(id: "caring_appraisals", title: "Caring Appraisals", relativePath: "cognition/caring_appraisals.jsonl", detail: "appraisal rows; off-disk backup only; no local backup, production export, or appraisal phone snapshot"),
            Spec(id: "agent_completion", title: "Agent Conversation Records", relativePath: "agent-conversations", detail: "Dot admissions, retained migration inputs and markers, and completion lifecycle records with corrupt-state evidence; off-disk backup only; no local backup, production export, or raw phone snapshot"),
            // Ambient window history stays outside activity exports, backups and sync.
            Spec(id: "activity_watch", title: "Activity Capture", relativePath: "activity_watch", detail: "locally-recorded app usage spans (app name, duration, redacted window title where enabled) — never exported, backed up, or synced"),
            Spec(id: "approvals", title: "Approvals", relativePath: "workflows/approvals", detail: "approval requests and resolved decisions"),
            Spec(id: "legacy_approvals", title: "Legacy Approvals", relativePath: "approvals", detail: "legacy approval import input and completed-import archive; canonical decisions win"),
            Spec(id: "security", title: "Security Audit", relativePath: "security", detail: "security audit receipts, preserved pretrim archive, completion marker and Mac integration permission authority; no backup or export; phone receives effective permission axes only"),
            Spec(id: "browser_runs", title: "Browser Runs", relativePath: "native_power/browser/runs.json", detail: "browser operation records"),
            Spec(id: "chrome", title: "Chrome Tabs", relativePath: "chrome", detail: "ChromeControlRuntime conversation-to-tab mapping; off-disk backup only; no local backup, archive inputs or phone snapshot"),
            Spec(id: "browser_ipc", title: "Browser Discovery", relativePath: "browser_ipc.json", detail: "BrowserIPCServer endpoint and token descriptor for external clients and Doctor readiness events; no backup, archive inputs or phone copy"),
            Spec(id: "browser_ipc_token", title: "Retained Browser Token", relativePath: "browser_ipc_token", detail: "retired duplicate token file; no in-app reader or writer; credential exclusions keep retained bytes out of backups, archive inputs and phone sync"),
            Spec(id: "paired_phones", title: "Paired Phones", relativePath: "paired_phones.json", detail: "paired-phone public keys and local approval status"),
            Spec(id: "pairing_secret_legacy", title: "Legacy Pairing Secret", relativePath: "icloud_pairing_secret.bin", detail: "migration-only 32-byte pairing secret; no backup, export, or raw phone copy"),
            Spec(id: "pairing_secret_lock", title: "Pairing Lock", relativePath: "icloud_pairing_secret.bin.lock", detail: "pairing creation/migration/rotation lock; no backup, export, or phone copy"),
            Spec(id: "connectors", title: "Connectors", relativePath: "connectors", detail: "connector registry, workspace records, and action receipts"),
            Spec(id: "oauth_tokens", title: "OAuth Tokens", relativePath: "oauth_tokens", detail: "connector OAuth token material"),
            Spec(id: "secrets", title: "Secrets", relativePath: "secrets", detail: "secret-bearing local runtime state"),
            Spec(id: "senses", title: "Sense Storage", relativePath: "senses", detail: "part notebooks and retained sense files; notebooks are backed up except news/ledger, excluded from production export and phone sync"),
            Spec(id: "sense_ledger", title: "Sense Wall Ledger", relativePath: "senses/ledger", detail: "private local wall history and growth needs — never exported, backed up, shared, or synced"),
            Spec(id: "sense_news", title: "Unread Sense News", relativePath: "senses/news", detail: "private pending news and delivery deduplication — never exported, backed up, shared, or synced"),
            Spec(id: "providers", title: "Providers", relativePath: "providers", detail: "provider auth/configuration state"),
            Spec(id: "codex_home", title: "Codex Home", relativePath: "codex_home", detail: "app-owned Codex auth and session files"),
            Spec(id: "abilities", title: "Abilities", relativePath: "abilities", detail: "authored tools, skills, and senses: current, previous, and proposed files plus run state"),
            Spec(id: "tools", title: "Tools", relativePath: "tools", detail: "local manifest signing key and retained legacy tool files"),
            Spec(id: "skills", title: "Skills", relativePath: "skills", detail: "resumable part runs and retained legacy skill files"),
            Spec(id: "procedures", title: "Saved Procedures", relativePath: "living_fabric/procedures", detail: "reviewed artifacts, activation authority, revalidation and invocation evidence; off-disk backup only, no local backup, production export, or phone sync"),
            Spec(id: "workflows", title: "Workflows", relativePath: "workflows", detail: "workflow templates, approvals, and retained retired run history"),
            Spec(id: "scheduler", title: "Scheduler", relativePath: "scheduler", detail: "Swift scheduled jobs and trigger records"),
            Spec(id: "triggers", title: "Triggers", relativePath: "triggers", detail: "config and last-fire state; off-disk backup only; no local backup, production export, or trigger-file phone snapshot"),
            Spec(id: "mcp", title: "MCP", relativePath: "mcp", detail: "retained legacy MCP server configuration, sessions, consent ledger, and cache; no active MCP client"),
            Spec(id: "telegram", title: "Telegram", relativePath: "telegram", detail: "Telegram configuration, offsets, sessions, receipts and recovery evidence; locally backed up; support includes state.json; phone receives settings/status projections"),
            Spec(id: "mobile_push", title: "Mobile Push", relativePath: "mobile_push", detail: "APNs delivery outcomes and retained tokens.json, which is no longer read or written; excluded from local backup and archive inputs; no direct phone copy"),
            Spec(id: "icloud", title: "iCloud Bridge", relativePath: "icloud", detail: "iCloud bridge transaction and sync state"),
            Spec(id: "notify_edges", title: "Notification Edges", relativePath: "notify", detail: "attention delivery and notification deduplication ledgers; off-disk backup only; no local backup, production export, or phone sync"),
            Spec(id: "mobile_snapshot_cache", title: "Phone Sync Cache", relativePath: "mobile_snapshot_cache", detail: "phone snapshots/responses and local transaction ledger; no backup or export"),
            Spec(id: "improvements", title: "Self Improvement", relativePath: "improvements", detail: "evaluation gauntlet records"),
            Spec(id: "evals", title: "Retained Evaluations", relativePath: "evals", detail: "orphaned legacy evaluation files; no live reader or writer; excluded from backups, export and phone sync; retained for the owner to decide"),
            Spec(id: "benchmark", title: "Retained Benchmarks", relativePath: "harness/benchmark", detail: "orphaned benchmark receipts; no live reader or writer; excluded from backups, export and phone sync; retained for the owner to decide"),
            Spec(id: "self_improvement", title: "Weekly Improvement", relativePath: "self_improvement", detail: "run requests, cadence and digests; off-disk backup only; no local backup, production export, or weekly-state phone snapshot"),
            Spec(id: "backups", title: "Backups", relativePath: "backups", detail: "local backups and restore registry"),
            Spec(id: "production", title: "Production Artifacts", relativePath: "production", detail: "exports, support bundles, and migration records"),
            Spec(id: "logs", title: "Logs", relativePath: "logs", detail: "runtime logs and diagnostic output"),
            Spec(id: "crash_reports", title: "Crash Reports", relativePath: "crash_reports", detail: "submitted crash report payloads"),
            Spec(id: "catalog", title: "Capability Catalog", relativePath: "catalog", detail: "catalog authority, sources, trust roots, install receipts and hidden local signing key; local backup selects registry, installs, sources and trust roots, excluding retained packs and quarantine; no raw phone snapshot"),
            Spec(id: "capabilities", title: "Capability Files", relativePath: "capabilities", detail: "retained capability files; locally backed up; no raw phone snapshot"),
            Spec(id: "graphs", title: "Graph Files", relativePath: "graphs", detail: "retained graph files; locally backed up; no raw phone snapshot"),
            Spec(id: "routing", title: "Routing Files", relativePath: "routing", detail: "retained routing files; locally backed up; no raw phone snapshot"),
            Spec(id: "make", title: "Make", relativePath: "make", detail: "versioned artifact bytes and metadata; locally backed up under its owner lock and included in off-disk backup; no archive inputs or raw phone snapshot; selected artifacts export separately with their prompt sidecar"),
            Spec(id: "make_lock", title: "Make Lock", relativePath: "make.lock", detail: "MakeStudio write and local-backup coordination; excluded from all backups, archive inputs and phone sync"),
            Spec(id: "experiences", title: "Experiences", relativePath: "experiences", detail: "experience SQLite store, including repair obligations; off-disk backup only; no local backup or export; phone receives work-activity projections"),
            Spec(id: "cognition", title: "Cognition", relativePath: "cognition", detail: "organism/substrate state, human-turn timing, and repair copies written by their owner; excluded from local backup and archive inputs; phone receives the living status projection"),
            Spec(id: "runs", title: "Runs", relativePath: "runs", detail: "run ledger; excluded from local backup and archive inputs; phone receives a bounded run projection"),
            Spec(id: "turn_traces", title: "Turn Traces", relativePath: "turn_traces", detail: "turn trace JSONL, reconciliation cursor, byte-preserved repair originals, and each agent's practice ledger and tape (exact redacted bodies of nominated calls only); excluded from all backups and archive inputs; phone receives turn summaries"),
            Spec(id: "build_launch", title: "Build Identity", relativePath: "build_launch.json", detail: "build and launch identity; excluded from local backup and archive inputs; no direct phone copy"),
            Spec(id: "doctor", title: "Doctor Reports", relativePath: "doctor", detail: "DoctorReadout measured reports; support copies this tree; excluded from local backup and direct phone copy; phone health.json is a separate process-health projection"),
            Spec(id: "auto_doctor", title: "Doctor Configuration", relativePath: "auto_doctor", detail: "optional Doctor scheduling configuration read by DoctorReadout; excluded from local backup, archive inputs and phone sync"),
            Spec(id: "runtime", title: "Runtime Reports", relativePath: "runtime", detail: "operator-produced hardening report and local runtime state; support copies this tree; excluded from local backup and direct phone copy"),
            Spec(id: "release", title: "Release Reports", relativePath: "release", detail: "release reports; support copies this tree; excluded from local backup and direct phone copy"),
            Spec(id: "cutover", title: "Cutover Records", relativePath: "cutover", detail: "retained cutover records; support copies this tree; excluded from local backup and direct phone copy"),
            Spec(id: "harness", title: "Learning Receipts", relativePath: "harness", detail: "retained harness records; support selects learning_receipts.jsonl; excluded from all backups and direct phone copy"),
            Spec(id: "install", title: "Install Identity", relativePath: "install", detail: "InstallPaths public data-root marker; excluded from local backup, archive inputs and phone sync"),
            Spec(id: "workspace", title: "Workspace", relativePath: "workspace", detail: "work files owned by tools at the resolved workspace; caller-authored files and transient bridge reply directories; not independently selected for local backup, archive inputs or phone directory replication; off-disk traversal covers it only when it lies within the data root"),
            Spec(id: "bridge_config", title: "Local Bridge Configuration", relativePath: "bridge-config", detail: "relocated-install IPC configuration and credentials; excluded from local backup, archive inputs and phone sync"),
            Spec(id: "config", title: "Local Configuration", relativePath: "config", detail: "local configuration files; excluded from local backup, archive inputs and direct phone copy"),
            Spec(id: "research", title: "Research Files", relativePath: "research", detail: "search configuration, fetched sources, lab runs and retained legacy files; excluded from local backup, archive inputs and direct phone copy"),
            Spec(id: "work_journal", title: "Work Journal", relativePath: "work_journal", detail: "retained work journal files; excluded from local backup, archive inputs and direct phone copy"),
            Spec(id: "native_power", title: "Mac Action Files", relativePath: "native_power", detail: "Mac action receipts, browser operations/receipts and disposable source/link/PNG captures, intent and notification files, and retained unused browser profile; off-disk backup only; no local backup, archive inputs or direct phone copy"),
            Spec(id: "nextgen", title: "Retained Action Files", relativePath: "nextgen", detail: "retained action and remote files; excluded from local backup, archive inputs and direct phone copy"),
            Spec(id: "self_worktrees", title: "Retained Worktrees", relativePath: "self_worktrees", detail: "retained worktrees; the external cleanup script still references self_worktrees; Doctor no longer creates this directory; excluded from local backup, archive inputs and direct phone copy"),
            Spec(id: "rich_ui", title: "Retained Rich UI Files", relativePath: "rich_ui", detail: "legacy files retained for the operator; Doctor no longer creates this directory; excluded from local backup, archive inputs and direct phone copy"),
            Spec(id: "personal_os", title: "Retained Personal OS Files", relativePath: "personal_os", detail: "legacy files retained for the operator; Doctor no longer creates this directory; excluded from local backup, archive inputs and direct phone copy"),
            Spec(id: "llm", title: "LLM Files", relativePath: "llm", detail: "live provider probe receipts and retained LLM files; excluded from local backup, archive inputs and direct phone copy"),
            Spec(id: "provider_vitals", title: "Provider Vitals", relativePath: "telemetry/provider_vitals.json", detail: "provider latency and failure summaries; off-disk backup only; no local backup, production export or raw phone sync"),
            Spec(id: "diagnostics", title: "Diagnostics", relativePath: "diagnostics", detail: "cutoff output and runtime diagnostic artifacts"),
            Spec(id: "welcome_pending", title: "Welcome Request", relativePath: ".needs_welcome", detail: "pending first-run welcome marker"),
            Spec(id: "welcome_inflight", title: "Welcome Claim", relativePath: ".needs_welcome.inflight", detail: "claimed first-run welcome marker"),
        ]
        return specs.map { spec in
            let selected = productionExportRelativePaths.compactMap { path in
                NativeAgentWorkspaceRoot.relativePath(path, under: spec.relativePath) != nil ? path
                    : NativeAgentWorkspaceRoot.relativePath(spec.relativePath, under: path) != nil ? spec.relativePath : nil
            }
            // The persona lives where the app reads it: beside a checkout's
            // data/, not inside it (`defaultPersonaRoot`).
            let path: URL
            switch spec.id {
            case "persona": path = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
            case "workspace": path = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
            case let id where id.hasPrefix("bridge_") && id != "bridge_config":
                path = InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot).appendingPathComponent(spec.relativePath)
            default: path = dataRoot.appendingPathComponent(spec.relativePath)
            }
            return PrivacyCategory(
                id: spec.id,
                title: spec.title,
                path: path.path,
                contains: "\(spec.detail); \(itemSummary(path)); export includes: \(selected.isEmpty ? "none" : selected.joined(separator: ", "))",
                exportable: !selected.isEmpty
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
            includingPropertiesForKeys: [.isRegularFileKey]
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
