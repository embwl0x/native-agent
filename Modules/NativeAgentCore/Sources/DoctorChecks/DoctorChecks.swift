import Foundation
import Security
import CloudKit
#if canImport(Darwin)
import Darwin
#endif
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeviceSyncState
import Desk
import GitHubConnector
import XConnector
import SlackConnector
import ProviderRouting
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
public struct CheckResult: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let status: String
    public let detail: String
    /// Executable repair instruction in reports; legacy core checks are
    /// normalized by DoctorActionRuntime before they reach consumers.
    public let repair: String?
    public let receipt: String?
    public let human_action: String?
    /// Live handler availability observed by DoctorActionRuntime, not inferred
    /// from human instructions or completion receipts. Nil in older reports.
    public let repair_available: Bool?
    /// Set where `human_action` is a sign-in or permission — the only steps
    /// Doctor hands to User, gathered into one inbox ask.
    public let ask: DoctorAskKind?

    public init(
        id: String,
        title: String,
        status: String,
        detail: String,
        repair: String? = nil,
        receipt: String? = nil,
        human_action: String? = nil,
        repair_available: Bool? = nil,
        ask: DoctorAskKind? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.repair = repair
        self.receipt = receipt
        self.human_action = human_action
        self.repair_available = repair_available
        self.ask = ask
    }

    /// The human step for an adverse row, including older cached rows with
    /// only legacy repair copy. Doctor repairs what it can; a row with neither
    /// a repair nor a step stands on its detail, which says what is wrong.
    public func recoveryAction(repairAvailable: Bool) -> String? {
        if let action = human_action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            return action
        }
        guard !repairAvailable, DoctorSafeRepairPolicy.isAdverse(status) else { return nil }
        if let action = repair?.trimmingCharacters(in: .whitespacesAndNewlines),
           !action.isEmpty, !action.lowercased().hasPrefix("run repair safe issues") {
            return action
        }
        return nil
    }
}

public enum DoctorAskKind: String, Sendable, Codable, Equatable {
    case signIn = "sign_in"
    case permission
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
    /// May an UNATTENDED sweep run this check and count its verdict?
    ///
    /// 2026-09-02, live incident: two new diagnostic rows graded a rolling
    /// history window, went red on PRE-FIX history, and the heartbeat pushed
    /// "Doctor has 2 failing checks" to User's phone at 3am. The rows were
    /// right and the notification was still wrong — they are for a person
    /// LOOKING at Doctor, not for a robot deciding to wake someone.
    ///
    /// `false` means: an unattended sweep must skip the row entirely — not run
    /// it, not count it in "N failing", not derive health from it. It stays
    /// fully visible in the Doctor UI, which is the only place it was ever
    /// meant to be read. Defaults to `true`, so every existing check keeps its
    /// current behavior and a new check must OPT OUT deliberately.
    var heartbeatEligible: Bool { get }
    func run() async -> CheckResult
}

public extension DoctorCheck {
    var heartbeatEligible: Bool { true }
}

/// Which check ids an unattended sweep must leave alone.
///
/// Core ids derive from the default check list so heartbeat policy follows
/// their flags. App-mounted live ids have no DoctorCheck instances and are
/// listed here for persisted-report readers such as heartbeat and self-heal.
public enum DoctorHeartbeatPolicy {
    public static let ineligibleCheckIDs: Set<String> = Set(
        SwiftNativeDoctorChecks.defaultChecks
            .filter { !$0.heartbeatEligible }
            .map(\.id)
    ).union([
        // App-mounted Cognition checks include historical receipts and
        // operator-only readings. They belong in Doctor, not phone alerts.
        "live.cognition.runtime", "live.cognition.persistence",
        "live.cognition.receipts", "live.cognition.readouts",
        "live.cognition.body", "live.cognition.welfare",
        "live.cognition.capacity", "live.cognition.associations",
        "live.cognition.context_flow", "live.cognition.phone_pairing",
    ])

    /// True when an unattended sweep may judge this id.
    public static func isEligible(_ id: String) -> Bool {
        !ineligibleCheckIDs.contains(id)
    }
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

/// File repair entry point available without an explicit Repair button.
public protocol CreateMissingDoctorCheck: RepairingDoctorCheck {
    func createMissing() async -> CheckResult
}

// MARK: - DoctorChecksProtocol

/// SwiftNative impl never throws (the actor catches everything and reflects
/// it as `status: "fail"`).
public protocol DoctorChecksProtocol: Sendable {
    func runAll(repair: Bool) async throws -> [CheckResult]
    func runCheck(id: String, repair: Bool, scope: DoctorRepairScope) async throws -> CheckResult?
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

public enum DoctorFileRepair {
    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    public static func backupExistingFile(_ url: URL) throws -> URL? {
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

    static func createJSON(_ value: JSONValue, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Exclusive creation also protects files/symlinks appearing after the check.
        try value.serializedData(pretty: true).write(to: url, options: [.withoutOverwriting])
    }

    static func parseJSONFile(_ url: URL) throws -> JSONValue {
        let data = try Data(contentsOf: url)
        return try JSONValue.parse(data)
    }

    fileprivate static func value(_ value: JSONValue, matches shape: DoctorJSONShape) -> Bool {
        switch (shape, value) {
        case (.object, .object): return true
        case (.array, .array): return true
        case (.objectOrArray, .object), (.objectOrArray, .array): return true
        default: return false
        }
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
            // User, 2026-09-06: a completed onboarding whose profile.json has
            // gone missing or unreadable is a REPAIR condition, not a fresh
            // install. Everything downstream substitutes a default profile
            // silently — the agent is renamed and the configured identity is
            // gone with no error anywhere. Anchored on the `.onboarded`
            // sentinel so a machine that never onboarded stays ok. Deliberately
            // NOT auto-repaired: nothing here may invent a name.
            let dataRoot = await engine.dataRootURL
            if FileManager.default.fileExists(
                atPath: dataRoot.appendingPathComponent(".onboarded").path
            ) {
                let profileURL = dataRoot
                    .appendingPathComponent("memory", isDirectory: true)
                    .appendingPathComponent("profile.json")
                var profileIsReadable = false
                if let data = try? Data(contentsOf: profileURL),
                   let object = try? JSONSerialization.jsonObject(with: data),
                   object is [String: Any] {
                    profileIsReadable = true
                }
                if !profileIsReadable {
                    return CheckResult(
                        id: id,
                        title: title,
                        status: "fail",
                        detail: "Onboarding completed on this Mac but \(profileURL.path) is missing or unreadable, so the configured agent and user names are gone and a default profile is being used in their place.",
                        repair: "Restore memory/profile.json from a backup, or set the names again in Settings. Repair will not write this file — it must not invent a name."
                    )
                }
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

/// Verifies the app-owned JSON files that route core runtime behavior.
/// Creation never overwrites; the full button repair backs up existing files.
public struct RuntimeJSONStoresCheck: CreateMissingDoctorCheck {
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
        await run(repair: repair, replaceExisting: repair)
    }

    public func createMissing() async -> CheckResult {
        await run(repair: true, replaceExisting: false)
    }

    private func run(repair: Bool, replaceExisting: Bool) async -> CheckResult {
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
                        try DoctorFileRepair.createJSON(spec.defaultValue, at: path)
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
                    if replaceExisting {
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
                if replaceExisting {
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
        if repair, !repaired.isEmpty, unrepaired.isEmpty,
           replaceExisting || (malformed.isEmpty && wrongShape.isEmpty) {
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
                repair: "Run Repair Safe Issues to back up and reset malformed app-owned JSON stores.",
                receipt: repaired.isEmpty ? nil : "Completed: \(repaired.joined(separator: "; ")).",
                human_action: "These stores hold provider, consent and registry choices, so Doctor never resets them by itself. Open Diagnostics → Doctor and press Repair to back up and reset them to empty."
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
        // `trust/policy.json` is DELIBERATELY ABSENT. Doctor's repair resets a
        // malformed store to its spec default, and the spec default for an
        // object store is `{}` — which TrustCenter's canonical read treats as a
        // fresh install and re-seeds with `enableAutonomy: true` and
        // `autonomyDefault: workspace_autonomous`. "Repair Safe Issues" on a
        // Safe machine therefore handed the person back Work mode with
        // unattended work on. TrustCenter owns this file and already fails
        // CLOSED on bytes it cannot read (`loadAuthorizationSnapshot` →
        // `failClosedTrustPolicy`), so the repair had nothing to add and one
        // way to raise the fence by itself.
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
    ]
}

// MARK: - ChatMessagesIntegrityCheck

/// Per-file scan memo for `ChatMessagesIntegrityCheck`, keyed on the file's
/// (modification date, size). A JSONL file whose mtime AND size are both
/// unchanged since the last scan cannot have become malformed, so re-parsing
/// every line of it produces the same per-file numbers the previous scan
/// already produced. The verdict is rebuilt from those numbers exactly as if
/// the parse had run — this is a work skip, never a verdict skip.
///
/// Process-wide (`static`) because the doctor runner builds a fresh check
/// value per run; entries are keyed on absolute path so alternate data roots
/// (tests, secondary roots) never collide.
actor ChatMessagesScanCache {
    /// stat-strength identity (gpt-5.5 wave-1 NEEDS_FIX): Date+size alone
    /// misses a same-size metadata-preserving replacement; device+inode+
    /// nanosecond mtimespec matches ChatTranscriptLineCountCache's stamp.
    struct Stamp: Sendable, Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    struct Entry: Sendable, Equatable {
        let stamp: Stamp
        let totalLines: Int
        let malformedLines: Int
        let unreadable: Bool
    }

    private var entries: [String: Entry] = [:]

    func lookup(path: String, stamp: Stamp?) -> Entry? {
        guard let stamp, let entry = entries[path], entry.stamp == stamp else { return nil }
        return entry
    }

    func store(path: String, entry: Entry) {
        entries[path] = entry
    }

    /// Drops memos for files that no longer exist so the map cannot grow
    /// without bound across a long-lived process (state-lifecycle audit: every
    /// insert needs a matching remove).
    /// Scoped to the directory that was just scanned. The memo is
    /// process-wide, but a scan only has authority over its OWN root — an
    /// unscoped filter lets a check on an alternate data root evict the live
    /// root's memos (and vice versa) on every run.
    func retain(paths: Set<String>, under prefix: String) {
        entries = entries.filter { !$0.key.hasPrefix(prefix) || paths.contains($0.key) }
    }

    /// Test seam: forget everything (a fresh-process equivalent).
    func reset() {
        entries.removeAll()
    }

    func count() -> Int { entries.count }
}

public struct ChatMessagesIntegrityCheck: CreateMissingDoctorCheck {
    public let id: String = "chat_messages"
    public let title: String = "Chat Message Logs"
    private let root: URL

    /// Process-wide memo. Injectable so a test can own an isolated one.
    static let sharedScanCache = ChatMessagesScanCache()
    private let scanCache: ChatMessagesScanCache

    /// Memo key. Symlinks are resolved so the same file reached through
    /// `/var/...` and `/private/var/...` is one entry, and so directory-scoped
    /// eviction can compare against a canonical prefix.
    static func cacheKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// stat identity of a file, or nil when unreadable — a nil stamp never
    /// matches a stored memo, so the file is always re-scanned.
    static func fingerprint(_ file: URL) -> ChatMessagesScanCache.Stamp? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        return ChatMessagesScanCache.Stamp(
            device: info.st_dev,
            inode: info.st_ino,
            size: Int64(info.st_size),
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }

    public init(root: URL = defaultDataRoot()) {
        self.root = root
        self.scanCache = Self.sharedScanCache
    }

    init(root: URL, scanCache: ChatMessagesScanCache) {
        self.root = root
        self.scanCache = scanCache
    }

    public func run(repair: Bool) async -> CheckResult {
        await run(repair: repair, replaceExisting: repair)
    }

    public func createMissing() async -> CheckResult {
        await run(repair: true, replaceExisting: false)
    }

    private func run(repair: Bool, replaceExisting: Bool) async -> CheckResult {
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

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "jsonl" }
        } catch {
            return CheckResult(
                id: id,
                title: title,
                status: "fail",
                detail: "Could not list chat message directory: \(error.localizedDescription)",
                repair: nil
            )
        }

        var totalLines = 0
        var malformedLines = 0
        var malformedFiles: [URL] = []
        var repairedFiles: [String] = []

        // A1/FIX-1b: the (mtime,size) memo is consulted only on the read-only
        // path. Repair mode rewrites files, so it always re-parses and lets the
        // rewritten fingerprint invalidate the old memo naturally.
        let useCache = !replaceExisting
        var scannedPaths: Set<String> = []

        for file in files {
            let cacheKey = Self.cacheKey(file)
            scannedPaths.insert(cacheKey)
            let fingerprint = Self.fingerprint(file)
            if useCache,
               let memo = await scanCache.lookup(path: cacheKey, stamp: fingerprint) {
                totalLines += memo.totalLines
                malformedLines += memo.malformedLines
                if memo.unreadable || memo.malformedLines > 0 { malformedFiles.append(file) }
                continue
            }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                malformedFiles.append(file)
                if useCache, let fingerprint {
                    await scanCache.store(
                        path: cacheKey,
                        entry: .init(
                            stamp: fingerprint,
                            totalLines: 0, malformedLines: 0, unreadable: true
                        )
                    )
                }
                continue
            }
            var fileMalformed = 0
            var fileTotal = 0
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                fileTotal += 1
                if (try? JSONValue.parse(Data(line.utf8))) == nil {
                    fileMalformed += 1
                }
            }
            totalLines += fileTotal
            if useCache, let fingerprint {
                await scanCache.store(
                    path: cacheKey,
                    entry: .init(
                        stamp: fingerprint,
                        totalLines: fileTotal, malformedLines: fileMalformed, unreadable: false
                    )
                )
            }
            if fileMalformed > 0 {
                malformedLines += fileMalformed
                malformedFiles.append(file)
                if replaceExisting {
                    do {
                        try await SwiftNativePersistenceCore().withFileLock(file) {
                            // Re-read under the same lock as message appenders;
                            // the diagnostic scan may predate a committed reply.
                            let current = try String(contentsOf: file, encoding: .utf8)
                            let lines = current.split(separator: "\n").map {
                                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                            }.filter { !$0.isEmpty }
                            let validLines = lines.filter { (try? JSONValue.parse(Data($0.utf8))) != nil }
                            // Revalidated under the appenders' lock: nothing
                            // malformed now means nothing to rewrite.
                            guard validLines.count < lines.count else { return }
                            _ = try DoctorFileRepair.backupExistingFile(file)
                            let repairedText = validLines.isEmpty ? "" : validLines.joined(separator: "\n") + "\n"
                            try Data(repairedText.utf8).write(to: file, options: [.atomic])
                        }
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

        if useCache {
            await scanCache.retain(
                paths: scannedPaths, under: Self.cacheKey(dir) + "/"
            )
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

public struct ICloudBridgeStateCheck: CreateMissingDoctorCheck {
    public let id: String = "icloud_bridge_state"
    public let title: String = "iCloud Bridge State"
    /// Local (non-iCloud) sync bookkeeping root. Sweep R4 items 1 + 2 record
    /// their durable failure state here, and this row is where it surfaces —
    /// reusing the existing iCloud bridge row rather than opening a second
    /// reporting lane for the same subsystem.
    private let dataRoot: URL

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    /// Warnings derived from the sync engine's own durable state files.
    /// Deliberately ordered most-actionable first.
    static func localSyncStateWarnings(dataRoot: URL) -> [String] {
        var warnings: [String] = []
        let stranded = ICloudSyncStatePaths.completedUnarchivedMsgIds(dataRoot: dataRoot)
        if !stranded.isEmpty {
            warnings.append(
                "\(stranded.count) iPhone command(s) completed but their completion record could not be filed "
                + "(\(stranded.prefix(3).joined(separator: ", "))\(stranded.count > 3 ? ", …" : "")). "
                + "They are marked completed and will not run again; free disk space or fix iCloud permissions."
            )
        }
        let corrupt = ICloudSyncStatePaths.processedIdsCorruptBackup(dataRoot: dataRoot)
        if FileManager.default.fileExists(atPath: corrupt.path) {
            warnings.append(
                "The processed-command list was unreadable and was preserved as processed_ids.corrupt.json — "
                + "iPhone commands from before that point may be re-run."
            )
        }
        let skipsURL = ICloudSyncStatePaths.snapshotSkips(dataRoot: dataRoot)
        if let data = try? Data(contentsOf: skipsURL),
           let skips = try? JSONDecoder().decode([String: String].self, from: data) {
            let groups = skips.keys.filter { !$0.hasPrefix("_") }.sorted()
            if !groups.isEmpty {
                // Named with why, so a group that never reached the phone says
                // so instead of only that it is old.
                let byReason = Dictionary(grouping: groups) { String(skips[$0, default: ""].prefix(160)) }
                warnings.append(
                    "iPhone is showing stale \(groups.joined(separator: ", ")) — the last snapshot pass could not "
                    + "build or publish \(groups.count == 1 ? "that group" : "those groups"): "
                    + byReason.keys.sorted().map { "\(byReason[$0, default: []].joined(separator: ", ")) (\($0))" }
                        .joined(separator: "; ") + "."
                )
            }
        }
        return warnings
    }

    /// Folds local sync-state warnings into the active transport verdict without
    /// downgrading a harder existing status.
    private func merging(_ result: CheckResult) -> CheckResult {
        let warnings = Self.localSyncStateWarnings(dataRoot: dataRoot)
        guard !warnings.isEmpty else { return result }
        let status = result.status == "fail" ? "fail" : "warn"
        return CheckResult(
            id: result.id,
            title: result.title,
            status: status,
            detail: "\(result.detail) \(warnings.joined(separator: " "))",
            repair: result.repair,
            ask: result.ask
        )
    }

    public func createMissing() async -> CheckResult {
        await run(repair: true)
    }

    private static func entitlementValues(_ key: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let raw = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return [] }
        if let values = raw as? [String] { return values }
        if let value = raw as? String { return [value] }
        return []
    }

    public func run(repair: Bool) async -> CheckResult {
        let services = Self.entitlementValues(DeviceCloudKitPreflight.iCloudServicesEntitlementKey)
        guard let snapshot = await ICloudBridgeHealthReader.snapshot(dataRoot: dataRoot) else {
            return merging(CheckResult(
                id: id, title: title, status: "warn",
                detail: "iCloud transport health is unmeasured; the app's bridge has not started."
            ))
        }
        let containerID = NativeAgentICloudBridgeConstants.containerID
        let cloudKit = snapshot.transport == .cloudKit
        let service = cloudKit ? "CloudKit" : "CloudDocuments"
        let containerKey = cloudKit ? DeviceCloudKitPreflight.iCloudContainersEntitlementKey
            : "com.apple.developer.ubiquity-container-identifiers"
        guard services.contains(service), Self.entitlementValues(containerKey).contains(containerID) else {
            return merging(CheckResult(
                id: id, title: title, status: "warn",
                detail: "The active \(cloudKit ? "CloudKit" : "iCloud Drive") transport lacks its signed \(service) service or container entitlement.",
                repair: "Install a signed NativeAgent build granting \(service) and container \(containerID)."
            ))
        }
        if cloudKit {
            return merging(cloudKitResult(snapshot))
        }
        if case .unmeasured = snapshot.health {
            return merging(CheckResult(
                id: id, title: title, status: "warn", detail: "iCloud Drive is starting; transport health is not measured yet."
            ))
        }
        guard case .available = snapshot.health, let docsURL = snapshot.documentsURL else {
            let signedIn = FileManager.default.ubiquityIdentityToken != nil
            return merging(CheckResult(
                id: id, title: title, status: "warn",
                detail: signedIn ? "The active iCloud Drive container is unavailable." : "The active iCloud Drive transport has no signed-in iCloud account.",
                repair: signedIn
                    ? "Open System Settings → Apple Account → iCloud → Drive and turn on Sync this Mac; allow NativeAgent under Apps Syncing to iCloud Drive."
                    : "Open System Settings → Apple Account and sign in to iCloud.",
                ask: signedIn ? .permission : .signIn
            ))
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
            return merging(CheckResult(
                id: id,
                title: title,
                status: "ok",
                detail: "iCloud/APNS bridge directories are present after repair.",
                repair: "Created: \(created.joined(separator: ", "))."
            ))
        }
        if !missing.isEmpty {
            return merging(CheckResult(
                id: id,
                title: title,
                status: "warn",
                detail: "Missing iCloud/APNS bridge path(s): \(missing.joined(separator: ", ")).",
                repair: "Run Repair Safe Issues to recreate bridge directories."
            ))
        }
        return merging(CheckResult(
            id: id,
            title: title,
            status: "ok",
            detail: "iCloud/APNS bridge directories are present."
        ))
    }

    private func cloudKitResult(_ snapshot: ICloudBridgeHealthSnapshot) -> CheckResult {
        let receive = cloudKitResult(snapshot.health, operation: "receive")
        let failures = snapshot.sendFailures.sorted { $0.key < $1.key }.map {
            cloudKitResult($0.value, operation: "send (\($0.key))")
        }
        let send = failures.isEmpty
            ? (snapshot.sendMeasured ? "CloudKit has accepted outbound delivery; iOS receipt is not confirmed."
                                     : "CloudKit send health is unmeasured.")
            : failures.map(\.detail).joined(separator: " ")
        return CheckResult(
            id: id, title: title,
            status: receive.status == "ok" && snapshot.sendMeasured && failures.isEmpty ? "ok" : "warn",
            detail: "\(receive.detail) \(send)",
            repair: receive.repair ?? failures.compactMap(\.repair).first,
            ask: receive.ask ?? failures.compactMap(\.ask).first
        )
    }

    private func cloudKitResult(_ health: ICloudBridgeHealthSnapshot.Health, operation: String) -> CheckResult {
        var status = "warn"
        let detail: String
        var action: String?
        var ask: DoctorAskKind?
        switch health {
        case .unmeasured:
            detail = "CloudKit \(operation) health is unmeasured. iCloud Drive is not required."
        case .available:
            status = "ok"
            detail = "CloudKit is active and its last \(operation) completed successfully. iCloud Drive is not required."
        case .signedOut:
            detail = "CloudKit \(operation) has no authenticated iCloud account."
            action = "Open System Settings → Apple Account and sign in to iCloud."
            ask = .signIn
        case .notEntitled:
            detail = "CloudKit \(operation) is not configured with its required entitlements."
            action = "Install a signed NativeAgent build granting CloudKit and container \(NativeAgentICloudBridgeConstants.containerID)."
        case .quotaExceeded:
            detail = "The active CloudKit transport cannot \(operation) because iCloud storage is full."
            action = "Open System Settings → Apple Account → iCloud → Manage and free iCloud storage."
        case .accountFailure(let code, let reason):
            detail = "CloudKit \(operation) was rejected: \(reason)"
            switch CKError.Code(rawValue: code) {
            case .notAuthenticated:
                action = "Open System Settings → Apple Account and complete iCloud sign-in."
                ask = .signIn
            case .missingEntitlement:
                action = "Install a signed NativeAgent build granting CloudKit and container \(NativeAgentICloudBridgeConstants.containerID)."
            case .managedAccountRestricted:
                action = "Ask your Apple Account administrator to allow CloudKit for NativeAgent."
                ask = .permission
            default: break
            }
        case .unavailable(let reason):
            detail = "The active CloudKit transport's last \(operation) failed: \(reason)"
        }
        return CheckResult(id: id, title: title, status: status, detail: detail, repair: action, ask: ask)
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
/// 2026-07-12 (User's broken-panel incident): the memory stack panel showed
/// "Core ML MiniLM BROKEN" while Doctor reported all-green — Doctor never
/// probed the embedder. This check ACTUALLY LOADS the bundled MiniLM through
/// the same compile-cache path the runtime uses, so an install-restart race
/// that poisons the temp compile cache (the incident's root cause) surfaces
/// here instead of only in degraded recall. Repair = wipe the compile cache
/// and re-probe; the pristine .mlpackage in the app bundle recompiles fresh.
public struct CoreMLEmbedderCheck: RepairingDoctorCheck {
    public let id: String = "coreml_embedder"

    /// Exact required assets of the installed source package. Unknown files,
    /// caches and download staging remain dynamic storage. Model load/integrity
    /// checks still belong to this check's ordinary run path.
    public static func installedModelStorageFiles(dataRoot: URL) throws -> Set<String> {
        let directory = dataRoot.appendingPathComponent("extras/coreml", isDirectory: true)
        guard let installed = try CoreMLEmbeddingProvider.installedExtrasModel(root: dataRoot),
              installed.modelURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              installed.modelURL.pathExtension == "mlpackage" else { return [] }
        let manifest = installed.modelURL.appendingPathComponent("Manifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        guard let entries = object?["itemInfoEntries"] as? [String: [String: Any]],
              let root = object?["rootModelIdentifier"] as? String,
              entries[root]?["path"] as? String == "com.apple.CoreML/model.mlmodel",
              entries.values.contains(where: { $0["path"] as? String == "com.apple.CoreML/weights" }) else { return [] }
        let files = [manifest, installed.vocabURL, directory.appendingPathComponent("embedding.json"),
                     installed.modelURL.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"),
                     installed.modelURL.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")]
        let base = directory.standardizedFileURL.path + "/"
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0,
                  file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
                  file.standardizedFileURL.path.hasPrefix(base) else { return [] }
        }
        return Set(files.map { $0.standardizedFileURL.path })
    }

    /// Agent, 2026-09-06: this row said "MiniLM loads" whatever was actually
    /// running. Since 2026-09-05 the runtime prefers an installed extras model
    /// (`CoreMLEmbeddingProvider.installedExtrasModel`), so the row was naming
    /// a model the store had not been embedded with. Title and detail now name
    /// the model the runtime RESOLVES, and the detail says separately whether
    /// the bundled MiniLM floor is still there.
    public var title: String { "Core ML Embedder (\(Self.resolvedModelID))" }

    private static var resolvedModelID: String {
        (try? CoreMLEmbeddingProvider.installedExtrasModel(root: defaultDataRoot()))?.modelID
            ?? CoreMLEmbeddingProvider.bundledModelID
    }

    public init() {}

    public func run(repair: Bool) async -> CheckResult {
        // An installed model whose manifest is unusable fails here by name —
        // it is never reported as the MiniLM floor loading (S12, 2026-09-26).
        do {
            _ = try CoreMLEmbeddingProvider.installedExtrasModel(root: defaultDataRoot())
        } catch {
            return CheckResult(
                id: id, title: "Core ML Embedder (installed model)", status: "fail",
                detail: "\(error.localizedDescription). Semantic recall is off until the installed model is fixed or removed.",
                repair: repair ? "Cannot repair: the installed model's files need fixing, not cached state." : nil
            )
        }
        guard CoreMLEmbeddingProvider.bundledResourcesAvailable(extrasRoot: defaultDataRoot()) else {
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
            CoreMLEmbeddingProvider.wipeBundledCompileCache(extrasRoot: defaultDataRoot())
            let after = await probe()
            return CheckResult(
                id: id, title: title, status: after.status, detail: after.detail,
                repair: "Wiped the CoreML compile cache and re-probed the model load."
            )
        }
        return await probe()
    }

    private func probe() async -> CheckResult {
        // The floor is reported separately from the resolved model: an extras
        // install that shadows a missing MiniLM is a different situation from
        // one that sits on top of it.
        let floor = CoreMLEmbeddingProvider.bundledFloorResourcesAvailable()
            ? "Bundled MiniLM floor is present."
            : "Bundled MiniLM floor is MISSING from the app bundle."
        do {
            // Full real-path probe: compile-cache resolution + MLModel load +
            // WordPiece vocab. Same code the runtime's first embed() runs — so
            // this loads whatever the runtime resolves, extras model included.
            let provider = try CoreMLEmbeddingProvider.bundled(extrasRoot: defaultDataRoot())
            return CheckResult(
                id: id, title: title, status: "ok",
                detail: "\(provider.modelId), \(provider.dimensions)-d, loads: model compiles/loads from cache and the WordPiece vocab parses. \(floor)"
            )
        } catch {
            return CheckResult(
                id: id, title: title, status: "fail",
                detail: "\(Self.resolvedModelID) failed to load: \(String(describing: error)). Semantic recall is degraded until this is repaired. \(floor)",
                repair: "Run Repair Safe Issues to clear the Core ML compile cache and retry loading the model."
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
                repair: "Run the newest build of NativeAgent.app — "
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

// MARK: - OAuthTokenExpiryCheck

/// Expiry repair delegates to the credential's runtime owner. Inspection never
/// exchanges tokens; safe repair refreshes only expired, refreshable credentials.
public struct OAuthTokenExpiryCheck: RepairingDoctorCheck {
    public let id = "oauth_token_expiry"
    public let title = "OAuth Token Expiry"
    private let root: URL
    private let now: Date?

    public init(root: URL = defaultDataRoot(), now: Date? = nil) {
        self.root = root
        self.now = now
    }

    private struct Credential {
        let owner: String
        let name: String
        let path: URL

        var signIn: String {
            let section = owner.hasSuffix("_oauth_direct") ? "Providers" : "Connectors"
            return "Open Settings → \(section) → \(name) and sign in again."
        }
    }

    private func credentials() -> [Credential] {
        let entries = [
            Credential(owner: "x", name: "X", path: root.appendingPathComponent("oauth_tokens/x.json")),
            Credential(owner: "gmail", name: "Gmail", path: root.appendingPathComponent("connectors/gmail/auth.json")),
            Credential(owner: "calendar", name: "Google Calendar", path: root.appendingPathComponent("connectors/calendar/auth.json")),
            Credential(owner: "github", name: "GitHub", path: root.appendingPathComponent("connectors/github/auth.json")),
            Credential(owner: "slack", name: "Slack", path: root.appendingPathComponent("oauth_tokens/slack.json")),
        ] + [
            ("xai_oauth_direct", "xAI"), ("anthropic_oauth_direct", "Anthropic"),
            ("openai_oauth_direct", "ChatGPT"),
        ].map { owner, name in
            Credential(owner: owner, name: name,
                       path: ProviderOAuthCredentialMaintenance.credentialPath(provider: owner, root: root))
        }
        return entries.filter { credential in
            let fm = FileManager.default
            if credential.owner == "github" {
                return GitHubCredentialStore.metadataPaths(dataRoot: root).contains { fm.fileExists(atPath: $0.path) }
            }
            if credential.owner == "slack" {
                return fm.fileExists(atPath: credential.path.path)
                    || fm.fileExists(atPath: root.appendingPathComponent("connectors/slack/auth.json").path)
            }
            guard fm.fileExists(atPath: credential.path.path) else { return false }
            if credential.owner.hasSuffix("_oauth_direct"),
               let data = try? Data(contentsOf: credential.path),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // A provider settings file with no credential is not a failed sign-in.
                return object["access_token"] != nil || object["refresh_token"] != nil || object["tokens"] != nil
            }
            return true
        }
    }

    private func status(_ credential: Credential, afterRefresh: Bool = false) async throws -> OAuthCredentialHealth {
        switch credential.owner {
        case "gmail", "calendar":
            return try GoogleOAuthCredentials.credentialStatus(path: credential.path)
        case "x":
            let state = try XConnectorActions.credentialStatus(dataRoot: root)
            return OAuthCredentialHealth(configured: state.configured, expiresAt: state.expiresAt, canRefresh: state.canRefresh)
        case "github":
            let state = try await GitHubCredentialStore.shared.credentialStatus(dataRoot: root, requiringOAuth: afterRefresh)
            return OAuthCredentialHealth(configured: state.configured, expiresAt: state.expiresAt, canRefresh: state.canRefresh)
        case "slack":
            try SlackConnectorActions.requireConfiguredToken(dataRoot: root)
            return OAuthCredentialHealth(configured: true, expiresAt: nil, canRefresh: false)
        default:
            return try ProviderOAuthCredentialMaintenance.status(provider: credential.owner, root: root)
        }
    }

    private func refresh(_ credential: Credential) async throws {
        switch credential.owner {
        case "gmail", "calendar":
            _ = try await GoogleOAuthCredentials.refresh(path: credential.path)
        case "x":
            try await XConnectorActions.refreshCredential(dataRoot: root)
        case "github":
            try await GitHubCredentialStore.shared.refreshCredential(dataRoot: root)
        default:
            try await ProviderOAuthCredentialMaintenance.refresh(provider: credential.owner, root: root)
        }
    }

    private func requiresSignIn(_ error: Error, credential: Credential) -> Bool {
        switch credential.owner {
        case "gmail", "calendar":
            return (error as? GoogleOAuthCredentials.RefreshError)?.requiresReauthentication == true
        case "x":
            return XConnectorActions.refreshRequiresSignIn(error)
        case "github":
            if case .refreshRejected = error as? GitHubOAuthDeviceFlow.FlowError { return true }
            return false
        default:
            return ProviderOAuthCredentialMaintenance.requiresSignIn(error)
        }
    }

    public func run() async -> CheckResult { await run(repair: false) }

    public func run(repair: Bool) async -> CheckResult {
        let now = self.now ?? Date()
        var findings: [String] = []
        var asks: [String] = []
        var repaired: [String] = []
        var noExpiry: [String] = []
        var refreshable = false
        var checked = 0
        for credential in credentials() {
            do {
                var state = try await status(credential)
                checked += 1
                guard state.configured else {
                    findings.append("\(credential.name) has no usable saved credential.")
                    asks.append(credential.signIn)
                    continue
                }
                if state.expiresAt == nil && !state.requiresRefresh {
                    noExpiry.append(credential.name)
                    continue
                }
                if !state.requiresRefresh, let expiry = state.expiresAt, expiry > now {
                    if !state.canRefresh && expiry.timeIntervalSince(now) <= 7 * 24 * 60 * 60 {
                        findings.append("\(credential.name) access expires within 7 days and no refresh credential is available.")
                        asks.append(credential.signIn)
                    }
                    continue
                }
                let reason = state.requiresRefresh ? "authorization needs renewal" : "access expired"
                guard state.canRefresh else {
                    findings.append("\(credential.name) \(reason) and no refresh credential is available.")
                    asks.append(credential.signIn)
                    continue
                }
                // Refreshable is normal (it renews on next use): not a finding, or
                // she reads it as signed out and asks User to sign in again.
                guard repair else {
                    refreshable = true
                    continue
                }
                do {
                    try Task.checkCancellation()
                    try await refresh(credential)
                    state = try await status(credential, afterRefresh: true)
                    if state.configured && !state.requiresRefresh && (state.expiresAt.map { $0 > Date() } ?? true) {
                        repaired.append(credential.name)
                        if state.expiresAt == nil { noExpiry.append(credential.name) }
                    } else {
                        findings.append("\(credential.name) still has no current access credential after refresh.")
                        if !state.configured || !state.canRefresh { asks.append(credential.signIn) }
                        else { refreshable = true }
                    }
                } catch {
                    if requiresSignIn(error, credential: credential) {
                        findings.append("\(credential.name) rejected the saved refresh authorization.")
                        asks.append(credential.signIn)
                    } else {
                        // Provider bodies and credential material never enter Doctor reports.
                        findings.append("\(credential.name) refresh could not complete. Retry Repair Safe Issues when the provider is available.")
                        refreshable = true
                    }
                }
            } catch {
                findings.append("\(credential.name) credential state is unavailable from its owner.")
            }
        }
        var detail = "\(checked) credential(s) inspected through their owners."
        if !noExpiry.isEmpty {
            detail += " No scheduled expiry: \(noExpiry.joined(separator: ", "))."
        }
        if !repaired.isEmpty { detail += " Refreshed: \(repaired.joined(separator: ", "))." }
        if !findings.isEmpty { detail += " " + findings.joined(separator: " ") }
        return CheckResult(id: id, title: title, status: findings.isEmpty ? "ok" : "warn",
                           detail: detail,
                           repair: refreshable ? DoctorSafeRepairPolicy.oauthRefreshInstruction : nil,
                           receipt: repaired.isEmpty ? nil : "Repaired: refreshed \(repaired.joined(separator: ", ")).",
                           human_action: asks.isEmpty ? nil : asks.joined(separator: " "),
                           ask: asks.isEmpty ? nil : .signIn)
    }
}

public actor SwiftNativeDoctorChecks: DoctorChecksProtocol {
    private let checks: [DoctorCheck]

    /// The production check list. Exposed as a named value (rather than an
    /// inline default argument) so `DoctorHeartbeatPolicy` can DERIVE the
    /// unattended-sweep exclusions from the same array the app runs, instead
    /// of keeping a second hand-maintained list beside it.
    public static let defaultChecks: [DoctorCheck] = [
        StorageCheck(),
        RuntimeJSONStoresCheck(),
        RunLedgerIntegrityCheck(),
        TurnTraceIntegrityCheck(),
        ChatSessionsCheck(),
        // One-thread-many-surfaces Phase 0: hot session count, 24h mints BY
        // MINT SITE, and the source-flapping detector. Read-only.
        SessionIdentityCheck(),
        // 2026-09-02: two per-turn health rows over the turn-trace feed, so a
        // regression in either can no longer be invisible. Both are read-only,
        // bounded (tailed day files), and run ONLY inside a Doctor pass —
        // never on a turn, a timer, or the cognition runtime. Both are
        // `heartbeatEligible == false`: they are for a person reading Doctor,
        // never for an unattended sweep that can wake User.
        //   * PromptPrefixHealthCheck — cross-turn prefix cache reuse.
        //   * SubconsciousVitalsCheck — capsule attachment and felt/Inner/Sound
        //     variety, plus the organism's own chemistry.
        PromptPrefixHealthCheck(),
        SubconsciousVitalsCheck(),
        ChatMessagesIntegrityCheck(),
        PersonaEngineCheck(),
        MemoryStoreCheck(),
        CoreMLEmbedderCheck(),
        ICloudBridgeStateCheck(),
        OpLogHealthCheck(),
        OAuthTokenExpiryCheck(),
    ]

    /// `defaultChecks` with every memoizing check REBUILT, so this runner
    /// measures instead of replaying.
    ///
    /// Astra audit 2026-09-11 finding 6: `defaultChecks` is a `static let` of
    /// check INSTANCES, and `PromptPrefixHealthCheck` / `SubconsciousVitalsCheck`
    /// each own a 60-second `DoctorScanCache` actor. "One memo per check
    /// instance" therefore means "one memo per PROCESS" — constructing a new
    /// `SwiftNativeDoctorChecks` gets a new actor wrapped around the same two
    /// check values and the same two memos. So the first-turn refresh ran right
    /// after launch, hit both memos, and republished the launch measurement
    /// ("zero rows since launch") under a fresh `runAt`; the drained trace files
    /// were never opened, because `run()` consults the memo before `measure()`.
    ///
    /// A caller that exists BECAUSE something just became true asks for this.
    /// The polling health card keeps `defaultChecks` and its memo: there the
    /// memo is doing its job, sparing a trace-file scan every few seconds.
    public static func freshMeasurementChecks() -> [DoctorCheck] {
        defaultChecks.map { check in
            switch check.id {
            case "prompt_prefix_health": PromptPrefixHealthCheck(cacheTTL: 0)
            case "subconscious_vitals": SubconsciousVitalsCheck(cacheTTL: 0)
            default: check
            }
        }
    }

    public init(checks: [DoctorCheck] = SwiftNativeDoctorChecks.defaultChecks) {
        self.checks = checks
    }

    public func runAll(repair: Bool) async throws -> [CheckResult] {
        // Bulk repairs run the automatic scope sequentially; persona writes
        // still require runCheck with explicit button scope.
        // The repair:false path is read-only — every check only stats,
        // reads and parses its own subtree — so the checks are independent and
        // run concurrently. Results are re-sorted back into declaration order,
        // so the emitted array (and therefore the rollup, the wire shape, and
        // every consumer's index assumptions) is byte-identical to the
        // sequential run.
        if repair {
            var results: [CheckResult] = []
            results.reserveCapacity(checks.count)
            for check in checks {
                if let result = try await runCheck(id: check.id, repair: true, scope: .automatic) {
                    results.append(result)
                }
            }
            return results
        }
        // gpt-5.5 wave-1 NEEDS_FIX: StorageCheck is NOT read-only even under
        // repair:false — it creates the root/subdirectory tree and writes a
        // probe file. Mutating checks run sequentially FIRST (so the tree
        // exists before readers race it on a fresh root); only genuinely
        // read-only checks join the concurrent group. Output order stays
        // declaration order.
        var sequentialResults: [(Int, CheckResult)] = []
        var concurrentChecks: [(Int, any DoctorCheck)] = []
        for (index, check) in checks.enumerated() {
            if check is StorageCheck {
                sequentialResults.append((index, await check.run()))
            } else {
                concurrentChecks.append((index, check))
            }
        }
        let ordered = await withTaskGroup(of: (Int, CheckResult).self) { group in
            for (index, check) in concurrentChecks {
                group.addTask {
                    if let repairable = check as? any RepairingDoctorCheck {
                        return (index, await repairable.run(repair: false))
                    }
                    return (index, await check.run())
                }
            }
            var collected = sequentialResults
            collected.reserveCapacity(checks.count)
            for await item in group { collected.append(item) }
            return collected
        }
        return ordered.sorted { $0.0 < $1.0 }.map(\.1)
    }

    public func runCheck(id: String, repair: Bool, scope: DoctorRepairScope) async throws -> CheckResult? {
        for check in checks where check.id == id {
            if repair, scope != .button {
                if let oauth = check as? OAuthTokenExpiryCheck {
                    return await oauth.run(repair: true)
                }
                // Automatic runs the full repair: every one backs up and
                // revalidates under the writer's lock before it replaces.
                // Authority stores and onboarding only create what is missing.
                if scope == .automatic, DoctorSafeRepairPolicy.automaticCoreIDs.contains(id),
                   !DoctorSafeRepairPolicy.createMissingOnlyIDs.contains(id),
                   let repairable = check as? any RepairingDoctorCheck {
                    return await repairable.run(repair: true)
                }
                if DoctorSafeRepairPolicy.automaticCoreIDs.contains(id),
                   let creator = check as? any CreateMissingDoctorCheck {
                    return await creator.createMissing()
                }
                return await check.run()
            }
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
