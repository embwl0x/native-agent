import Foundation
#if canImport(Darwin)
import Darwin
#endif
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// M5: MemoryStoreCheck validates the REAL knowledge-graph store (memory.sqlite
// kg_entities/kg_relationships) through the reader the app already uses.
import KnowledgeGraph
// 2026-07-12: CoreMLEmbedderCheck probes the real bundled-MiniLM load path.
import MemoryV2

// MARK: - Subsystem #5b: DoctorChecks
//
// Swift-native offline Doctor. This module intentionally does not call an LLM
// or delegate to any external runtime. Checks should either validate/repair
// app-owned local state directly, or fail/warn honestly when a fix needs user
// action or a rebuild.
//
// Historical source line references below exist only to pin old file shapes
// and retired-process cleanup behavior. They are not instructions to restore
// the removed runtime.
//
// Operationally: Doctor is the last-resort local safety net. Keep it light
// enough to run when provider/chat/tool subsystems are broken.

// MARK: - CheckResult

/// Stable Doctor check shape:
///   {"id", "title", "status", "detail", "repair"}.
/// status is one of "ok" | "warn" | "fail". `repair` is the optional
/// remediation hint.
public struct CheckResult: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let status: String
    public let detail: String
    public let repair: String?

    public init(
        id: String,
        title: String,
        status: String,
        detail: String,
        repair: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.repair = repair
    }
}

// MARK: - DoctorCheck

/// A single check the doctor runs. Deliberately NON-THROWING: a check that
/// hits an internal failure must catch it and return `status: "fail"` with
/// the error in `detail`. Letting a check throw would abort the entire
/// `runAll` traversal — that diverges from Python, where each check is
/// wrapped in `try/except` and silently degrades to status="fail".
public protocol DoctorCheck: Sendable {
    var id: String { get }
    var title: String { get }
    func run() async -> CheckResult
}

/// Optional extension point for checks that can safely repair app-owned state
/// without an LLM. Repairing checks still expose the plain run() shape so old
/// callers and tests remain simple.
public protocol RepairingDoctorCheck: DoctorCheck {
    func run(repair: Bool) async -> CheckResult
}

public extension RepairingDoctorCheck {
    func run() async -> CheckResult {
        await run(repair: false)
    }
}

// MARK: - DoctorChecksProtocol

/// SwiftNative impl never throws (the actor catches everything and reflects
/// it as `status: "fail"`).
public protocol DoctorChecksProtocol: Sendable {
    func runAll(repair: Bool, checkLLM: Bool) async throws -> [CheckResult]
    func runCheck(id: String, repair: Bool) async throws -> CheckResult?
}

// MARK: - Errors

public enum DoctorChecksError: Error, LocalizedError {
    case invalidResponse(status: Int)
    case unavailable(underlying: Error)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let s): return "doctor HTTP returned status \(s)"
        case .unavailable(let e): return "doctor unavailable: \(e.localizedDescription)"
        case .underlying(let m): return m
        }
    }
}

// MARK: - Shared helpers

private enum DoctorJSONShape: Sendable {
    case object
    case array
    case objectOrArray
}

private struct DoctorJSONStoreSpec: Sendable {
    let relativePath: String
    let label: String
    let shape: DoctorJSONShape
    let defaultValue: JSONValue

    init(_ relativePath: String, _ label: String, _ shape: DoctorJSONShape, _ defaultValue: JSONValue) {
        self.relativePath = relativePath
        self.label = label
        self.shape = shape
        self.defaultValue = defaultValue
    }
}

private enum DoctorFileRepair {
    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    static func backupExistingFile(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).doctor-bak-\(timestamp())")
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    static func writeJSON(_ value: JSONValue, to url: URL) async throws {
        try await SwiftNativePersistenceCore().writeJSON(value, to: url)
    }

    static func parseJSONFile(_ url: URL) throws -> JSONValue {
        let data = try Data(contentsOf: url)
        return try JSONValue.parse(data)
    }

    static func value(_ value: JSONValue, matches shape: DoctorJSONShape) -> Bool {
        switch (shape, value) {
        case (.object, .object): return true
        case (.array, .array): return true
        case (.objectOrArray, .object), (.objectOrArray, .array): return true
        default: return false
        }
    }

    static func appendJSONLReceipt(_ receipt: JSONValue, to path: URL) async {
        try? await SwiftNativePersistenceCore().appendJSONL(receipt, to: path)
    }
}

// MARK: - StorageCheck

/// Canonical Swift runtime subdirectory tree created under `root`.
let STORAGE_SUBDIRS: [String] = [
    "runs", "memory",
    "chat", "chat/messages", "chat/session_state",
    "context", "context/cache", "context/evals", "context/feedback", "context/hints",
    "llm",
    "research", "research/downloads",
    "improvements",
    "self_worktrees",
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
    "evals",
    "release",
    "connectors", "connectors/workspaces",
    "skills", "skills/bodies",
    "tools", "tools/proposals", "tools/active", "tools/quarantine", "tools/runtime", "tools/logs",
    "capabilities",
    "routing",
    "workflows", "workflows/approvals", "workflows/run_state",
    "swarms",
    "mcp", "mcp/cache", "mcp/consent", "mcp/logs", "mcp/sessions",
    "rich_ui",
    "research/lab",
    "graphs", "graphs/embeddings", "graphs/entities",
    "traces",
    "personal_os",
    "catalog", "catalog/packs", "catalog/quarantine", "catalog/sources", "catalog/trust",
    "native_power", "native_power/actions",
    "native_power/browser", "native_power/browser/profile", "native_power/browser/screenshots", "native_power/browser/sources",
    "native_power/intents",
    "native_power/notifications",
    "connectors/actions",
    "improvements/gauntlet",
    "nextgen", "nextgen/actions", "nextgen/observability", "nextgen/eval_os",
    "nextgen/proactive", "nextgen/mac_control", "nextgen/multimodal", "nextgen/simulation",
    "nextgen/remote", "nextgen/sdk", "nextgen/learning", "nextgen/ops",
    "nextgen/provider_router", "nextgen/eval_packs", "nextgen/promotion",
    "nextgen/release_train", "nextgen/phase_93_112",
    "production", "production/exports", "production/support", "production/migrations",
]

/// Creates the root and every entry in `STORAGE_SUBDIRS`. Throws on the first directory
/// it cannot create — the caller maps that to status="fail".
func ensureDirs(_ root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for name in STORAGE_SUBDIRS {
        let path = root.appendingPathComponent(name)
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
    }
}

/// The one real Swift check. Mirrors Python's storage check at
/// native_agentd.py L29487-29491:
///   try: ensure_dirs(self.root)
///        add("storage", "App Storage", "ok",
///            f"App data is available at {self.root}", ...)
///   except Exception as exc:
///        add("storage", "App Storage", "fail",
///            f"Could not prepare app storage: {exc}")
///
/// Swift port calls `ensureDirs(root)` so the full subdirectory tree is
/// materialized, then proves writability via a UUID-named probe file
/// (write+delete) to avoid clobbering any preexisting `.doctor_probe`.
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
            return CheckResult(
                id: id,
                title: title,
                status: "ok",
                detail: "App data is available at \(root.path)",
                repair: nil
            )
        } catch {
            return CheckResult(
                id: id,
                title: title,
                status: "fail",
                detail: "Could not prepare app storage: \(error.localizedDescription)",
                repair: nil
            )
        }
    }
}

// MARK: - ChatSessionsCheck

/// Mirrors Python's chat_sessions check at native_agentd.py L29493-29497:
///   try: sessions = self.list_chat_sessions(include_archived=True)
///        add("chat_sessions", "Persistent Chat Sessions", "ok",
///            f"Chat session storage is available with {len(sessions)} session(s).")
///   except Exception as exc:
///        add("chat_sessions", "Persistent Chat Sessions", "fail",
///            f"Chat session store failed: {exc}",
///            "Run Repair Safe Issues to recreate app-owned chat directories.")
///
/// NOTE: The daemon stores chat sessions as a single JSON list file at
/// `<root>/chat/sessions.json` (see chat_sessions_path at
/// native_agentd.py:2228 and list_chat_sessions at L30048). We mirror that
/// exact source-of-truth — read the file, count list entries — rather than
/// enumerate files in a `chat/sessions/` directory, which does NOT exist
/// in the daemon.
///
/// STATUS SEMANTICS (audit fix 2026-06-10): a MISSING file is a fresh
/// install and stays ok/0 sessions. Anything else that prevents counting —
/// an unreadable file, a directory at the path, an empty/garbage payload,
/// or valid JSON that is not a list — is store CORRUPTION and returns
/// status="fail". The previous behavior mirrored the daemon's
/// `read_json(path, default=[])` (which swallowed every failure into ok/0),
/// but a Doctor check that can never fail on a corrupt store is useless;
/// silent ok/0 hid real data loss.
public struct ChatSessionsCheck: DoctorCheck {
    public let id: String = "chat_sessions"
    public let title: String = "Persistent Chat Sessions"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run() async -> CheckResult {
        let sessionsPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsPath.path, isDirectory: &isDir) else {
            // Fresh install: no sessions.json yet.
            return CheckResult(
                id: id, title: title, status: "ok",
                detail: "Chat session storage is available with 0 session(s).",
                repair: nil
            )
        }
        if isDir.boolValue {
            return failResult("sessions.json is a directory, not a file")
        }
        let data: Data
        do {
            data = try Data(contentsOf: sessionsPath)
        } catch {
            return failResult("could not read sessions.json: \(error.localizedDescription)")
        }
        if data.isEmpty {
            return failResult("sessions.json is empty (not valid JSON)")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return failResult("sessions.json is not valid JSON")
        }
        guard let list = parsed as? [Any] else {
            return failResult("sessions.json is not a JSON list")
        }
        // Mirror list_chat_sessions (native_agentd.py L30055-30076):
        // skip non-dicts and dicts without a non-empty `id`.
        let count = list.reduce(into: 0) { acc, row in
            if let dict = row as? [String: Any],
               let sid = dict["id"] as? String, !sid.isEmpty {
                acc += 1
            }
        }
        return CheckResult(
            id: id, title: title, status: "ok",
            detail: "Chat session storage is available with \(count) session(s).",
            repair: nil
        )
    }

    private func failResult(_ reason: String) -> CheckResult {
        CheckResult(
            id: id, title: title, status: "fail",
            detail: "Chat session store failed: \(reason)",
            repair: "Run Repair Safe Issues to recreate app-owned chat directories."
        )
    }
}

// MARK: - PersonaEngineCheck

/// Mirrors Python's persona_engine check at native_agentd.py L29499-29503:
///   try: packet = self.compiled_personality_packet("chat")
///        add("persona_engine", "Persona Engine 2.0", "ok",
///            f"{packet.get('personaKind')} persona compiled for {packet.get('surface')} with fingerprint {packet.get('fingerprint')}.")
///   except Exception as exc:
///        add("persona_engine", "Persona Engine 2.0", "fail",
///            f"Persona compiler failed: {exc}",
///            "Run Repair Safe Issues to normalize the personality profile.")
///
/// DOCUMENTED DIVERGENCE: the daemon's check actually COMPILES the
/// personality packet — a heavy pipeline (template merge, USER.md cap,
/// fingerprint hash, etc.) that the persona compiler subsystem has not
/// migrated to Swift yet. Phase B's Swift check verifies the strict subset
/// the migrated read-only persona surface CAN attest: persona docs LOAD
/// and SOUL.md is present. This is strictly weaker than the Python check
/// (a corrupt USER.md that breaks compilation would still pass here) and
/// the detail wording is deliberately "Persona docs loaded ..." not
/// "compiled" so an operator reading the report cannot mistake one for
/// the other. Byte-equivalence with the Python detail is not achievable
/// until the persona compiler migrates.
public struct PersonaEngineCheck: RepairingDoctorCheck {
    public let id: String = "persona_engine"
    public let title: String = "Persona Engine 2.0"
    private let engineProvider: @Sendable () -> SwiftNativePersonaEngine

    public init(engineProvider: @escaping @Sendable () -> SwiftNativePersonaEngine = { SwiftNativePersonaEngine() }) {
        self.engineProvider = engineProvider
    }

    public func run(repair: Bool) async -> CheckResult {
        let engine = engineProvider()
        let rootPath = await engine.personaRoot.path
        if repair {
            do {
                let repaired = try seedMissingPersonaDocs(at: await engine.personaRoot)
                let after = await run(repair: false)
                if repaired.isEmpty {
                    return after
                }
                return CheckResult(
                    id: id,
                    title: title,
                    status: after.status,
                    detail: after.detail,
                    repair: "Seeded missing persona doc(s): \(repaired.joined(separator: ", "))."
                )
            } catch {
                return CheckResult(
                    id: id,
                    title: title,
                    status: "fail",
                    detail: "Persona repair failed: \(error.localizedDescription)",
                    repair: "Could not seed missing persona docs."
                )
            }
        }
        do {
            let docs = try await engine.listPersonaDocs()
            let hasSoul = docs.contains { $0.id == "SOUL" }
            if !hasSoul {
                return CheckResult(
                    id: id,
                    title: title,
                    status: "fail",
                    detail: "Persona compiler failed: SOUL.md is absent from \(rootPath)",
                    repair: "Run Repair Safe Issues to normalize the personality profile."
                )
            }
            return CheckResult(
                id: id,
                title: title,
                status: "ok",
                detail: "Persona docs loaded (\(docs.count) entries) from \(rootPath).",
                repair: nil
            )
        } catch {
            return CheckResult(
                id: id,
                title: title,
                status: "fail",
                detail: "Persona compiler failed: \(error.localizedDescription)",
                repair: "Run Repair Safe Issues to normalize the personality profile."
            )
        }
    }

    private func seedMissingPersonaDocs(at root: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seeds: [(String, String)] = [
            ("SOUL.md", "You are a NativeAgent assistant. Keep this identity file updated from the app onboarding flow.\n"),
            ("USER.md", "The user's profile has not been filled in yet. Use onboarding or chat memory to personalize this safely.\n"),
            ("VOICE.md", "Speak clearly, directly, and in the user's preferred agent voice.\n"),
            ("GROWTH.md", "# Growth\n\n"),
            ("AGENTS.md", "# Agent Notes\n\n"),
        ]
        var created: [String] = []
        for (name, body) in seeds {
            let path = root.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: path.path) {
                try Data(body.utf8).write(to: path, options: [.atomic])
                created.append(name)
            }
        }
        return created
    }
}

// MARK: - RuntimeJSONStoresCheck

/// Verifies the app-owned JSON files that route core runtime behavior. Repair
/// only writes safe empty/default shapes and backs up malformed existing files.
public struct RuntimeJSONStoresCheck: RepairingDoctorCheck {
    public let id: String = "runtime_json_stores"
    public let title: String = "Runtime JSON Stores"
    private let root: URL
    private let specs: [DoctorJSONStoreSpec]

    public init(root: URL = defaultDataRoot()) {
        self.root = root
        self.specs = Self.defaultSpecs
    }

    private init(root: URL, specs: [DoctorJSONStoreSpec]) {
        self.root = root
        self.specs = specs
    }

    public func run(repair: Bool) async -> CheckResult {
        var missing: [String] = []
        var malformed: [String] = []
        var wrongShape: [String] = []
        var repaired: [String] = []
        var unrepaired: [String] = []

        for spec in specs {
            let path = root.appendingPathComponent(spec.relativePath)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir)
            if !exists {
                missing.append(spec.relativePath)
                if repair {
                    do {
                        try await DoctorFileRepair.writeJSON(spec.defaultValue, to: path)
                        repaired.append("created \(spec.relativePath)")
                    } catch {
                        unrepaired.append("\(spec.relativePath): \(error.localizedDescription)")
                    }
                }
                continue
            }
            if isDir.boolValue {
                wrongShape.append("\(spec.relativePath) is a directory")
                if repair {
                    // A directory at a store path is NOT auto-repairable —
                    // Doctor will not delete directories. Record it as
                    // unrepaired so the repair summary cannot claim
                    // "valid after repair" while it remains (audit 2026-06-10).
                    unrepaired.append("\(spec.relativePath): path is a directory; move it aside manually")
                }
                continue
            }
            do {
                let value = try DoctorFileRepair.parseJSONFile(path)
                if !DoctorFileRepair.value(value, matches: spec.shape) {
                    wrongShape.append(spec.relativePath)
                    if repair {
                        do {
                            _ = try DoctorFileRepair.backupExistingFile(path)
                            try await DoctorFileRepair.writeJSON(spec.defaultValue, to: path)
                            repaired.append("reset \(spec.relativePath)")
                        } catch {
                            unrepaired.append("\(spec.relativePath): \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                malformed.append(spec.relativePath)
                if repair {
                    do {
                        _ = try DoctorFileRepair.backupExistingFile(path)
                        try await DoctorFileRepair.writeJSON(spec.defaultValue, to: path)
                        repaired.append("reset \(spec.relativePath)")
                    } catch {
                        unrepaired.append("\(spec.relativePath): \(error.localizedDescription)")
                    }
                }
            }
        }

        if !unrepaired.isEmpty {
            return CheckResult(
                id: id,
                title: title,
                status: "fail",
                detail: "Could not repair \(unrepaired.count) runtime JSON store(s): \(unrepaired.prefix(5).joined(separator: "; "))",
                repair: repaired.isEmpty ? nil : "Completed: \(repaired.joined(separator: "; "))."
            )
        }
        // "valid after repair" may only be claimed when NOTHING is left
        // broken — every wrongShape/malformed entry must have been reset (or
        // recorded in `unrepaired`, which already returned "fail" above).
        if repair, !repaired.isEmpty, unrepaired.isEmpty {
            return CheckResult(
                id: id,
                title: title,
                status: "ok",
                detail: "Runtime JSON stores are valid after repair (\(specs.count) checked).",
                repair: repaired.joined(separator: "; ")
            )
        }
        if !malformed.isEmpty || !wrongShape.isEmpty {
            let issueCount = malformed.count + wrongShape.count
            return CheckResult(
                id: id,
                title: title,
                status: "fail",
                detail: "\(issueCount) runtime JSON store(s) are malformed or wrong-shaped: \((malformed + wrongShape).prefix(8).joined(separator: ", "))",
                repair: "Run Repair Safe Issues to back up and reset malformed app-owned JSON stores."
            )
        }
        if !missing.isEmpty {
            return CheckResult(
                id: id,
                title: title,
                status: "warn",
                detail: "\(missing.count) runtime JSON store(s) are missing but can be recreated: \(missing.prefix(8).joined(separator: ", "))",
                repair: "Run Repair Safe Issues to create missing app-owned JSON stores."
            )
        }
        return CheckResult(
            id: id,
            title: title,
            status: "ok",
            detail: "Runtime JSON stores are valid (\(specs.count) checked)."
        )
    }

    private static let defaultSpecs: [DoctorJSONStoreSpec] = [
        .init("providers/active.json", "Active providers", .object, .object([:])),
        .init("providers/surfaces.json", "Surface model picks", .object, .object([:])),
        .init("trust/policy.json", "Trust policy", .object, .object([:])),
        .init("scheduler/jobs.json", "Scheduler jobs", .array, .array([])),
        .init("mcp/servers.json", "MCP servers", .array, .array([])),
        .init("mcp/cache/tools.json", "MCP tool cache", .object, .object([:])),
        .init("mcp/cache/resources.json", "MCP resource cache", .object, .object([:])),
        .init("mcp/sessions/state.json", "MCP session state", .object, .object([:])),
        .init("mcp/consent/ledger.json", "MCP consent ledger", .array, .array([])),
        .init("notifications/push_tokens.json", "Swift push tokens", .object, .object([:])),
        .init("mobile_push/tokens.json", "Legacy mobile push tokens", .array, .array([])),
        .init("connectors/registry.json", "Connector registry", .array, .array([])),
        .init("connectors/workspaces.json", "Connector workspaces", .array, .array([])),
        .init("tools/registry.json", "Tool registry", .array, .array([])),
        .init("skills/registry.json", "Skill registry", .array, .array([])),
        .init("catalog/registry.json", "Capability pack catalog", .array, .array([])),
        .init("workflows/registry.json", "Workflow registry", .array, .array([])),
        .init("evals/runs.json", "Eval runs", .array, .array([])),
    ]
}

// MARK: - ChatMessagesIntegrityCheck

public struct ChatMessagesIntegrityCheck: RepairingDoctorCheck {
    public let id: String = "chat_messages"
    public let title: String = "Chat Message Logs"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run(repair: Bool) async -> CheckResult {
        let dir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            if repair {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    return CheckResult(
                        id: id,
                        title: title,
                        status: "ok",
                        detail: "Chat message directory exists and contains 0 JSONL file(s).",
                        repair: "Created \(dir.path)."
                    )
                } catch {
                    return CheckResult(
                        id: id,
                        title: title,
                        status: "fail",
                        detail: "Could not create chat message directory: \(error.localizedDescription)",
                        repair: nil
                    )
                }
            }
            return CheckResult(
                id: id,
                title: title,
                status: "warn",
                detail: "Chat message directory is missing at \(dir.path).",
                repair: "Run Repair Safe Issues to recreate chat message storage."
            )
        }

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "jsonl" }

        var totalLines = 0
        var malformedLines = 0
        var malformedFiles: [URL] = []
        var repairedFiles: [String] = []

        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                malformedFiles.append(file)
                continue
            }
            var validLines: [String] = []
            var fileMalformed = 0
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                totalLines += 1
                if let data = line.data(using: .utf8), (try? JSONValue.parse(data)) != nil {
                    validLines.append(line)
                } else {
                    fileMalformed += 1
                }
            }
            if fileMalformed > 0 {
                malformedLines += fileMalformed
                malformedFiles.append(file)
                if repair {
                    do {
                        _ = try DoctorFileRepair.backupExistingFile(file)
                        let repairedText = validLines.isEmpty ? "" : validLines.joined(separator: "\n") + "\n"
                        try Data(repairedText.utf8).write(to: file, options: [.atomic])
                        repairedFiles.append(file.lastPathComponent)
                    } catch {
                        return CheckResult(
                            id: id,
                            title: title,
                            status: "fail",
                            detail: "Could not repair \(file.lastPathComponent): \(error.localizedDescription)",
                            repair: repairedFiles.isEmpty ? nil : "Repaired: \(repairedFiles.joined(separator: ", "))."
                        )
                    }
                }
            }
        }

        if repair, !repairedFiles.isEmpty {
            return CheckResult(
                id: id,
                title: title,
                status: "ok",
                detail: "Chat message logs are valid after repair (\(files.count) file(s), \(totalLines - malformedLines) valid row(s)).",
                repair: "Backed up and rewrote malformed JSONL file(s): \(repairedFiles.joined(separator: ", "))."
            )
        }
        if malformedLines > 0 || !malformedFiles.isEmpty {
            return CheckResult(
                id: id,
                title: title,
                status: "fail",
                detail: "\(malformedLines) malformed chat JSONL row(s) across \(malformedFiles.count) file(s).",
                repair: "Run Repair Safe Issues to back up malformed JSONL files and keep valid rows."
            )
        }
        return CheckResult(
            id: id,
            title: title,
            status: "ok",
            detail: "Chat message logs are valid (\(files.count) file(s), \(totalLines) row(s))."
        )
    }
}

// MARK: - MemoryStoreCheck

/// M5 (honesty sweep, 2026-07-09): this check used to validate — and "repair" —
/// `<dataRoot>/memory/knowledge_graph.json`. The knowledge graph has lived in
/// `memory.sqlite` (`kg_entities` / `kg_relationships`) since the MemoryV2
/// migration; that JSON file is only ever consulted as a fallback when SQLite is
/// absent or empty. The old shape therefore did two dishonest things on a
/// perfectly healthy machine: it warned forever that `knowledge_graph.json` was
/// missing, and "Repair Safe Issues" answered by writing an empty file nothing
/// reads. It never once opened the database it claimed to be checking.
///
/// It now validates the real store by counting `kg_entities` /
/// `kg_relationships` through the same reader the app uses, which throws when
/// the database exists but cannot be read. There is nothing here Doctor can
/// safely auto-repair, so this is no longer a `RepairingDoctorCheck` — a repair
/// affordance that resets user data is worse than none.
public struct MemoryStoreCheck: DoctorCheck {
    public let id: String = "memory_store"
    public let title: String = "MemoryV2 and Knowledge Graph Store"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run() async -> CheckResult {
        let memoryDir = root.appendingPathComponent("memory", isDirectory: true)
        let sqlite = memoryDir.appendingPathComponent("memory.sqlite")
        do {
            try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        } catch {
            return CheckResult(
                id: id,
                title: title,
                status: "fail",
                detail: "Could not prepare memory directory: \(error.localizedDescription)",
                repair: nil
            )
        }

        var warnings: [String] = []
        if !FileManager.default.fileExists(atPath: sqlite.path) {
            warnings.append("memory.sqlite missing")
        } else if ((try? FileManager.default.attributesOfItem(atPath: sqlite.path)[.size] as? NSNumber)?.int64Value ?? 0) <= 0 {
            warnings.append("memory.sqlite is empty")
        }

        // Only interrogate the graph when there is a database to interrogate;
        // a missing/empty SQLite is already reported above and would send the
        // reader down its legitimate-empty fallback path.
        var kgSummary: String?
        if warnings.isEmpty {
            let reader = makeKnowledgeGraphReader(
                graphPath: memoryDir.appendingPathComponent("knowledge_graph.json")
            )
            do {
                let envelope = try await reader.allEntitiesChecked(page: 0)
                guard case .object(let obj) = envelope,
                      case .int(let entities)? = obj["total_entities"],
                      case .int(let relationships)? = obj["total_edges"] else {
                    throw DoctorChecksError.underlying("knowledge graph envelope malformed")
                }
                kgSummary = "knowledge graph: \(entities) entities, \(relationships) relationships"
            } catch {
                return CheckResult(
                    id: id,
                    title: title,
                    status: "fail",
                    detail: "Knowledge graph tables in memory.sqlite could not be read: \(error.localizedDescription)",
                    repair: nil
                )
            }
        }

        if !warnings.isEmpty {
            return CheckResult(
                id: id,
                title: title,
                status: "warn",
                detail: "Memory store warning(s): \(warnings.joined(separator: ", ")).",
                repair: "Run MemoryV2 migration if memory.sqlite is absent — Doctor cannot safely rebuild the store."
            )
        }
        return CheckResult(
            id: id,
            title: title,
            status: "ok",
            detail: "memory.sqlite is present and readable (\(kgSummary ?? "knowledge graph readable"))."
        )
    }
}

// MARK: - ICloudBridgeStateCheck

public struct ICloudBridgeStateCheck: RepairingDoctorCheck {
    public let id: String = "icloud_bridge_state"
    public let title: String = "iCloud Bridge State"
    private let docsURLProvider: @Sendable () -> URL?
    /// Whether THIS build actually ships iCloud (a real container id is
    /// configured, not the standalone "com.example" sentinel). The public
    /// no-iCloud DMG ships without iCloud on purpose, so an unavailable
    /// container there is EXPECTED, not a problem to warn about (User,
    /// 2026-07-04). Only a build that genuinely configures iCloud should nag to
    /// sign in.
    private let iCloudConfigured: Bool

    public init(
        docsURLProvider: @escaping @Sendable () -> URL? = {
            let containerID = ICloudBridgeStateCheck.resolvedContainerID()
            return FileManager.default
                .url(forUbiquityContainerIdentifier: containerID)?
                .appendingPathComponent("Documents", isDirectory: true)
        },
        iCloudConfigured: Bool = ICloudBridgeStateCheck.buildConfiguresICloud()
    ) {
        self.docsURLProvider = docsURLProvider
        self.iCloudConfigured = iCloudConfigured
    }

    /// The configured container id, or the standalone "com.example" sentinel.
    public static func resolvedContainerID() -> String {
        let envContainerID = ProcessInfo.processInfo.environment["NATIVEAGENT_ICLOUD_CONTAINER_ID"]
        let infoContainerID = Bundle.main.object(forInfoDictionaryKey: "NativeAgentICloudContainerID") as? String
        let configured = (envContainerID ?? infoContainerID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty, !configured.contains("$(") {
            return configured
        }
        return "iCloud.io.github.embwl0x.nativeagent"
    }

    /// True only when a REAL (non-placeholder) iCloud container is configured.
    public static func buildConfiguresICloud() -> Bool {
        let id = resolvedContainerID()
        return !id.contains("com.example")
    }

    public func run(repair: Bool) async -> CheckResult {
        guard let docsURL = docsURLProvider() else {
            // Public no-iCloud build: iCloud isn't part of it, so an
            // unavailable container is expected — report OK, not a warning.
            if !iCloudConfigured {
                return CheckResult(
                    id: id,
                    title: title,
                    status: "ok",
                    detail: "iCloud sync isn't part of this build (no iCloud container configured)."
                )
            }
            return CheckResult(
                id: id,
                title: title,
                status: "warn",
                detail: "iCloud container is unavailable to this process.",
                repair: "Run Doctor from the signed Mac app after signing into iCloud; CLI builds may not have the iCloud entitlement."
            )
        }
        let bridgeDirs = [
            "outbox/mac",
            "outbox/ios",
            "processing",
            "processed",
            "snapshots",
            "inbox",
            "inbox/_rejected",
            "responses",
            "transactions/mac",
            "transactions/ios",
        ]
        var missing: [String] = []
        var created: [String] = []
        for rel in bridgeDirs {
            let dir = docsURL.appendingPathComponent(rel, isDirectory: true)
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) || !isDir.boolValue {
                missing.append(rel)
                if repair {
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        created.append(rel)
                    } catch {
                        return CheckResult(
                            id: id,
                            title: title,
                            status: "fail",
                            detail: "Could not create \(rel): \(error.localizedDescription)",
                            repair: created.isEmpty ? nil : "Created: \(created.joined(separator: ", "))."
                        )
                    }
                }
            }
        }
        if repair, !created.isEmpty {
            return CheckResult(
                id: id,
                title: title,
                status: "ok",
                detail: "iCloud/APNS bridge directories are present after repair.",
                repair: "Created: \(created.joined(separator: ", "))."
            )
        }
        if !missing.isEmpty {
            return CheckResult(
                id: id,
                title: title,
                status: "warn",
                detail: "Missing iCloud/APNS bridge path(s): \(missing.joined(separator: ", ")).",
                repair: "Run Repair Safe Issues to recreate bridge directories."
            )
        }
        return CheckResult(
            id: id,
            title: title,
            status: "ok",
            detail: "iCloud/APNS bridge directories are present."
        )
    }
}

// MARK: - SwiftNative impl

/// Actor-isolated to keep the registered `checks` array and any future
/// caching field safe under concurrent runAll calls. Sequential check
/// execution matches Python's serial loop in doctor().
///
/// Default check set covers the local runtime surfaces that can break without
/// needing provider access or an LLM. Repair mode is intentionally conservative:
/// it creates missing app-owned directories/default JSON, backs up malformed
/// files before rewriting, and stops only the retired external-runtime process.
/// `checkLLM` is accepted for API compatibility but remains unused here.
/// 2026-07-12 (User's broken-panel incident): the memory stack panel showed
/// "Core ML MiniLM BROKEN" while Doctor reported all-green — Doctor never
/// probed the embedder. This check ACTUALLY LOADS the bundled MiniLM through
/// the same compile-cache path the runtime uses, so an install-restart race
/// that poisons the temp compile cache (the incident's root cause) surfaces
/// here instead of only in degraded recall. Repair = wipe the compile cache
/// and re-probe; the pristine .mlpackage in the app bundle recompiles fresh.
public struct CoreMLEmbedderCheck: RepairingDoctorCheck {
    public let id: String = "coreml_embedder"
    public let title: String = "Core ML Embedder (MiniLM)"

    public init() {}

    public func run(repair: Bool) async -> CheckResult {
        guard CoreMLEmbeddingProvider.bundledResourcesAvailable() else {
            return CheckResult(
                id: id, title: title, status: "fail",
                // A2.4: dropped a stale "script/install_minilm.sh" pointer —
                // that Python-era script no longer exists; the model ships in
                // the MemoryV2 resource bundle and only a reinstall restores it.
                detail: "minilm.mlpackage or minilm_vocab.txt is missing from the app bundle — reinstall the app.",
                repair: repair ? "Cannot repair: bundle resources are missing, not cached state." : nil
            )
        }
        if repair {
            CoreMLEmbeddingProvider.wipeBundledCompileCache()
            let after = await probe()
            return CheckResult(
                id: id, title: title, status: after.status, detail: after.detail,
                repair: "Wiped the CoreML compile cache and re-probed the model load."
            )
        }
        return await probe()
    }

    private func probe() async -> CheckResult {
        do {
            // Full real-path probe: compile-cache resolution + MLModel load +
            // WordPiece vocab. Same code the runtime's first embed() runs.
            _ = try CoreMLEmbeddingProvider.bundled()
            return CheckResult(
                id: id, title: title, status: "ok",
                detail: "MiniLM loads: model compiles/loads from cache and the WordPiece vocab parses."
            )
        } catch {
            return CheckResult(
                id: id, title: title, status: "fail",
                detail: "MiniLM failed to load: \(String(describing: error)). Semantic recall is degraded until this is repaired.",
                repair: nil
            )
        }
    }
}

// MARK: - OpLogHealthCheck

/// Is any append-only op-log feed wedged or growing without bound?
///
/// WHY THIS CHECK EXISTS (gpt-5.5 review 2026-08-02, finding 3): the three
/// snapshot+tail stores REFUSE to compact while any row is undecodable — right,
/// because compacting would delete rows this build cannot read — but refusing
/// costs liveness, and the only signal was a deduped stderr line plus a couple
/// of APIs nothing called. In a GUI app stderr goes nowhere. One row written by
/// a newer build can therefore wedge compaction for weeks while every append
/// replays an ever-longer feed, and the first thing User would notice is the desk
/// getting slow. Doctor is where "app-owned local state is in a bad way" already
/// lives, so the surface goes here rather than in a new reporting lane.
///
/// STATUS SEMANTICS:
///   • `fail` — a feed cannot be read at all, or holds rows this build cannot
///     use. Compaction is blocked; the feed can only grow.
///   • `warn` — every feed is decodable but one has grown past
///     `growthWarnMultiple`× its own compaction threshold (i.e. compaction has
///     not run in a long time), or a torn trailing line was seen.
///   • `ok` — nothing skipped and every feed is inside its normal band. Missing
///     feed files are a fresh install and count as ok.
public struct OpLogHealthCheck: DoctorCheck {
    public let id: String = "op_log_health"
    public let title: String = "Op-Log Health"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run() async -> CheckResult {
        var lines: [String] = []
        var failed = false
        var warned = false

        func record(_ health: SnapshotTailOpLog.OpLogHealth) {
            lines.append(health.detailLine)
            switch health.status {
            case .blocked: failed = true
            case .warn: warned = true
            case .ok: break
            }
        }

        // A store whose read THROWS is itself a finding — GitHubCommandStore
        // fails loud on an undecodable op — so each feed is probed
        // independently and a throw becomes this feed's fail line, never an
        // abort of the other two.
        do {
            record(try await SwiftNativeDeskStore(dataRoot: root, changeBus: StoreChangeBus()).opLogHealth())
        } catch {
            failed = true
            lines.append("DeskStore: unreadable — \(error)")
        }
        do {
            record(try await SwiftNativeTaskLedger(dataRoot: root).feedHealth())
        } catch {
            failed = true
            lines.append("TaskLedger: unreadable — \(error)")
        }
        do {
            record(try await GitHubCommandStore(dataRoot: root, changeBus: StoreChangeBus()).opLogHealth())
        } catch {
            failed = true
            lines.append("GitHubCommandStore: unreadable — \(error)")
        }

        let detail = lines.joined(separator: "; ")
        if failed {
            return CheckResult(
                id: id, title: title, status: "fail",
                detail: "Op-log compaction is blocked: \(detail)",
                repair: "Run the newest build of the app AND of the task-ledger / desk-sweep CLIs — "
                    + "the feed holds rows an older binary cannot decode, and compaction refuses to "
                    + "delete them. The feed keeps growing until a build that understands them runs."
            )
        }
        if warned {
            return CheckResult(
                id: id, title: title, status: "warn",
                detail: "An op-log feed has grown well past its compaction threshold: \(detail)",
                repair: "Usually self-healing — the next write past the threshold compacts. If it "
                    + "persists, a writer is failing before it reaches the compaction step."
            )
        }
        return CheckResult(id: id, title: title, status: "ok", detail: detail)
    }
}

public actor SwiftNativeDoctorChecks: DoctorChecksProtocol {
    private let checks: [DoctorCheck]

    public init(checks: [DoctorCheck] = [
        StorageCheck(),
        RuntimeJSONStoresCheck(),
        ChatSessionsCheck(),
        ChatMessagesIntegrityCheck(),
        PersonaEngineCheck(),
        MemoryStoreCheck(),
        CoreMLEmbedderCheck(),
        ICloudBridgeStateCheck(),
        OpLogHealthCheck(),
    ]) {
        self.checks = checks
    }

    public func runAll(repair: Bool, checkLLM: Bool) async throws -> [CheckResult] {
        // Note: checkLLM intentionally unused — see class docstring.
        var results: [CheckResult] = []
        results.reserveCapacity(checks.count)
        for check in checks {
            if let repairable = check as? any RepairingDoctorCheck {
                results.append(await repairable.run(repair: repair))
            } else {
                results.append(await check.run())
            }
        }
        return results
    }

    public func runCheck(id: String, repair: Bool) async throws -> CheckResult? {
        for check in checks where check.id == id {
            if let repairable = check as? any RepairingDoctorCheck {
                return await repairable.run(repair: repair)
            }
            return await check.run()
        }
        return nil
    }
}

// MARK: - Factory

public func makeDoctorChecks() -> any DoctorChecksProtocol {
    return SwiftNativeDoctorChecks()
}
