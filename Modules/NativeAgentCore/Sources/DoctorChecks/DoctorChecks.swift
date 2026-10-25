import AuthoredCapabilities
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
import ProviderRouting
import PersonaEngine
// M5: MemoryStoreCheck validates the REAL knowledge-graph store (memory.sqlite
// kg_entities/kg_relationships) through the reader the app already uses.
// 2026-07-12: CoreMLEmbedderCheck probes the real bundled-MiniLM load path.
import MemoryV2
import Experiences
import Transcripts
// Blueprint: | `DoctorChecks.swift` | `SwiftNativeDoctorChecks` actor; `makeDoctorChecks`, `runAll`; runtime JSON and transcript inspection is read-only; persona health never seeds identity; canonical owners alone create or mutate these stores; StorageCheck does not create research/downloads, rich_ui, personal_os, llm, context/evals, context/hints, production/migrations, self_worktrees, native_power/browser/profile or native_power/notifications, and leaves existing contents untouched; onboarded persona health requires the saved profile and validates it through `PersonaCompiler.compileProfile`, reporting its failure; StorageCheck does not create capabilities, graphs, routing, connectors/workspaces, research/downloads, rich_ui, personal_os, llm, context/evals, context/hints, production/migrations, self_worktrees or native_power/browser/profile, and leaves existing contents untouched; CheckResult carries the owner, registered native repair or person recovery step and its experience projection; app defects never create coding requests |

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
///   {"id", "title", "status", "detail", "harm", "repair"}.
/// Readings use "unmeasured"; adverse rows say why they matter in `harm`.
public struct CheckResult: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let status: String
    public let detail: String
    public let harm: String?
    /// Executable repair instruction in reports; legacy core checks are
    /// normalized by DoctorActionRuntime before they reach consumers.
    public let repair: String?
    public let receipt: String?
    /// Whether the repair changed app-owned state; nil in older readings.
    public let repairApplied: Bool?
    public let human_action: String?
    /// Live handler availability observed by DoctorActionRuntime, not inferred
    /// from human instructions or completion receipts. Nil in older reports.
    public let repair_available: Bool?
    /// False where unattended repair would discard live continuity.
    public let automaticRepairEligible: Bool?
    /// Sign-ins and permissions join the consent inbox ask; app-defect
    /// recovery steps stay separate from consent.
    public let ask: DoctorAskKind?
    /// Who heals an adverse row (`DoctorOwner.of`). A check declares only
    /// `builder` where a build is the fix; Doctor derives the rest.
    public let owner: DoctorOwner?
    public let source: String?
    public let nextCall: String?
    public let repairExperience: Experience?

    public init(
        source: String? = nil,
        nextCall: String? = nil,
        id: String,
        title: String,
        status: String,
        detail: String,
        harm: String? = nil,
        repair: String? = nil,
        receipt: String? = nil,
        repairApplied: Bool? = nil,
        human_action: String? = nil,
        repair_available: Bool? = nil,
        automaticRepairEligible: Bool? = nil,
        ask: DoctorAskKind? = nil,
        owner: DoctorOwner? = nil,
        repairExperience: Experience? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.harm = harm
        self.repair = repair
        self.receipt = receipt
        self.repairApplied = repairApplied
        self.human_action = human_action
        self.repair_available = repair_available
        self.automaticRepairEligible = automaticRepairEligible
        self.ask = ask
        self.owner = owner
        self.source = source
        self.nextCall = nextCall
        self.repairExperience = repairExperience
    }

    /// The human step for an adverse row, including older cached rows with
    /// only legacy repair copy. Doctor repairs what it can; a row with neither
    /// a repair nor a step names its harm before it can be routed.
    public func recoveryAction(repairAvailable: Bool) -> String? {
        if let action = human_action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            return action
        }
        guard !repairAvailable, DoctorSafeRepairPolicy.isAdverse(status) else { return nil }
        if let action = repair?.trimmingCharacters(in: .whitespacesAndNewlines),
           !action.isEmpty, !DoctorSafeRepairPolicy.isCoreRepairInstruction(action) {
            return action
        }
        return nil
    }
}

extension CheckResult {
    /// The check an owed repair is about: its operation names it; a measured row is itself.
    public var checkID: String {
        if let domain = repairExperience?.outcome?.domain, domain.hasPrefix("doctor.check:") { return String(domain.dropFirst("doctor.check:".count)) }
        return id
    }

    public var repairOwner: String? {
        if repairExperience != nil { return source }
        return owner == .builder ? "NativeAgent code: " + checkID : source
    }

    public var repairCall: String? {
        if repairExperience != nil { return nextCall }
        guard DoctorSafeRepairPolicy.isAdverse(status), ask == nil else { return nil }
        if let nextCall { return nextCall }
        if repair_available == true {
            return ToolFailureError.call("app", ["action": .string("doctor.repair"), "args": .object(["check_id": .string(id)])])
        }
        return nil
    }

    public var repairTap: String? {
        if repairExperience != nil { return human_action }
        guard DoctorSafeRepairPolicy.isAdverse(status), ask != nil || repairCall == nil else { return nil }
        if owner == .builder {
            return "Ask the person to resolve \(repairOwner ?? checkID). " + (recoveryAction(repairAvailable: false)
                ?? "Report this app defect and failed check \(checkID) to NativeAgent's maintainer; preserve saved data and all Trust, sign-in and privacy decisions.")
        }
        return recoveryAction(repairAvailable: false)
    }

    public var remedy: JSONValue? {
        guard DoctorSafeRepairPolicy.isAdverse(status), let repairOwner else { return nil }
        if let repairTap, ask != nil { return Repair.why(owner: repairOwner, tap: repairTap) }
        guard repairCall != nil || repairTap != nil else { return nil }
        return Repair.remedy(owner: repairOwner,
            nextCall: repairCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }, tap: repairTap,
            instruction: repair_available == true
            ? "Press Repair in Diagnostics → Health checks to retry this check."
            : repairCall == nil ? repairTap
            : repair ?? human_action ?? "Use the native repair action for \(repairOwner), preserving the original bytes.")
    }

    public var repairFace: String {
        // Evidence is prose; remedies and executable calls have their own fields.
        detail
    }

    /// The reported row: its human step, an executable repair only where one
    /// runs, and its owner. Every writer of a Doctor report settles through it.
    public func settled(liveAvailable: Bool, coreAvailable: Bool) -> CheckResult {
        let humanAction = recoveryAction(repairAvailable: liveAvailable || coreAvailable) ?? (liveAvailable
            ? "Press Repair in Diagnostics → Health checks to retry this live service."
            : nil)
        return CheckResult(source: source, nextCall: nextCall, id: id, title: title, status: status, detail: detail, harm: harm,
                           repair: liveAvailable ? "Press Repair in Diagnostics → Health checks to retry this live service." : (coreAvailable ? repair : nil),
                           receipt: receipt, repairApplied: repairApplied,
                           human_action: humanAction, repair_available: liveAvailable || coreAvailable,
                           automaticRepairEligible: automaticRepairEligible, ask: ask,
                           owner: DoctorOwner.of(self, repairAvailable: liveAvailable || coreAvailable))
    }
}

public enum DoctorAskKind: String, Sendable, Codable, Equatable {
    case signIn = "sign_in"
    case permission
}

/// Each adverse row's healer and route: `app` repairs it, `owner` (User) gets
/// the one doctor-ask card, `agent` (Agent) is woken to triage it, `builder`
/// names an app defect for the person's recovery step.
public enum DoctorOwner: String, Sendable, Codable, Equatable {
    case app, owner, agent, builder

    /// A live repair or handler is the app's; a sign-in or permission is
    /// User's; a declared build fix is the builder's; Agent triages a named harm.
    public static func of(_ row: CheckResult, repairAvailable: Bool) -> DoctorOwner? {
        guard DoctorSafeRepairPolicy.isAdverse(row.status) else { return nil }
        if repairAvailable { return .app }
        if row.ask != nil { return .owner }
        guard let harm = row.harm?.trimmingCharacters(in: .whitespacesAndNewlines), !harm.isEmpty else { return nil }
        return row.owner == .builder ? .builder : .agent
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
    func runAll() async throws -> [CheckResult]
    func runCheck(id: String, repair: Bool, scope: DoctorRepairScope) async throws -> CheckResult?
}

// MARK: - Errors

public enum DoctorChecksError: Error, LocalizedError {
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .underlying(let m): return m
        }
    }
}

// MARK: - Shared helpers

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

// MARK: - StorageCheck

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

/// Prepares the runtime scaffold and checks writability with a fresh probe.
/// Retired directories and any existing contents are left for the operator.
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
            return CheckResult(source: "chat/sessions.json",
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
        return CheckResult(source: "chat/sessions.json",
            id: id, title: title, status: "ok",
            detail: "Chat session storage is available with \(count) session(s).",
            repair: nil
        )
    }

    private func failResult(_ reason: String) -> CheckResult {
        CheckResult(source: "chat/sessions.json",
            id: id, title: title, status: "fail",
            detail: "Chat session store failed: \(reason)",
            harm: "Saved conversations cannot be found or reopened.",
            human_action: ToolFailureError.fileRepairInstruction(root.appendingPathComponent("chat/sessions.json"),
                shape: "This is a JSON array of saved chat session objects, each with its original nonempty id and saved metadata."))
    }
}

// MARK: - PersonaEngineCheck

/// Reads persona health through its canonical engine; Doctor never seeds identity.
public struct PersonaEngineCheck: DoctorCheck {
    public let id: String = "persona_engine"
    public let title: String = "Persona Engine 2.0"
    private let engineProvider: @Sendable () -> SwiftNativePersonaEngine

    public init(root: URL? = nil, engineProvider: (@Sendable () -> SwiftNativePersonaEngine)? = nil) {
        self.engineProvider = engineProvider ?? { root.map { SwiftNativePersonaEngine.isolated(dataRoot: $0) } ?? SwiftNativePersonaEngine() }
    }

    public func run() async -> CheckResult {
        let engine = engineProvider()
        let rootPath = await engine.personaRoot.path
        do {
            let docs = try await engine.listPersonaDocs()
            let hasSoul = docs.contains { $0.id == "SOUL" }
            if !hasSoul {
                return CheckResult(source: rootPath + "/SOUL.md",
                    id: id,
                    title: title,
                    status: "fail",
                    detail: "Persona compiler failed: SOUL.md is absent from \(rootPath)",
                    harm: "Her identity is missing from the conversation.",
                    repair: nil
                )
            }
            // User, 2026-09-06: a completed onboarding whose profile.json has
            // gone missing or invalid is a REPAIR condition, not a fresh
            // install. Use the authoritative compiler's validation, while
            // requiring saved identity after onboarding rather than defaults.
            // Anchored on the `.onboarded`
            // sentinel so a machine that never onboarded stays ok. Deliberately
            // NOT auto-repaired: nothing here may invent a name.
            let dataRoot = await engine.dataRootURL
            if FileManager.default.fileExists(
                atPath: dataRoot.appendingPathComponent(".onboarded").path
            ) {
                let profileURL = dataRoot
                    .appendingPathComponent("memory", isDirectory: true)
                    .appendingPathComponent("profile.json")
                do {
                    guard try profileURL.checkResourceIsReachable() else {
                        throw CocoaError(.fileReadNoSuchFile)
                    }
                    _ = try PersonaCompiler.compileProfile(dataRoot: dataRoot)
                } catch {
                    return CheckResult(source: profileURL.path,
                        id: id,
                        title: title,
                        status: "fail",
                        detail: "Onboarding completed on this Mac but the saved personality profile at \(profileURL.path) is unavailable: \(error.localizedDescription)",
                        harm: "Her configured identity cannot be loaded reliably.",
                        human_action: "Open Trust → Advanced → Backups, select a verified backup containing memory/profile.json, then choose Restore → Restore backup to recover the configured names.",
                        ask: .permission
                    )
                }
            }
            return CheckResult(source: rootPath,
                id: id,
                title: title,
                status: "ok",
                detail: "Persona docs loaded (\(docs.count) entries) from \(rootPath).",
                repair: nil
            )
        } catch {
            return CheckResult(source: rootPath,
                id: id,
                title: title,
                status: "fail",
                detail: "Persona compiler failed: \(error.localizedDescription)",
                harm: "Her identity documents cannot be loaded.",
                repair: nil
            )
        }
    }

}

// MARK: - AbilityFilesCheck

public struct AbilityFilesCheck: DoctorCheck {
    public let id = "ability_files"
    public let title = "Ability Files"
    private let root: URL
    nonisolated(unsafe) private static var seedFailures: [String: [String]] = [:]

    package static func recordSeedFailures(_ failures: [String], root: URL) {
        AbilityStore.withLock { seedFailures[root.standardizedFileURL.path] = failures }
    }

    public init(root: URL = defaultDataRoot()) { self.root = root }

    public func run() async -> CheckResult {
        let failures = AbilityStore.withLock { Self.seedFailures[root.standardizedFileURL.path] ?? [] }
        if !failures.isEmpty {
            // Launch records "filename: error"; name each failed seed without
            // turning an arbitrary error body into the check's prose.
            let seeds = failures.compactMap { failure in
                failure.range(of: ": ").map { String(failure[..<$0.lowerBound]) }
            }
            return CheckResult(source: "abilities/", id: id, title: title, status: "fail",
                detail: "Bundled seed installation has \(failures.count) failure(s): "
                    + (seeds.isEmpty ? "the bundled ability directory could not be read" : seeds.joined(separator: ", ")) + ".",
                harm: "Bundled parts could not be installed; their capabilities are unavailable.",
                human_action: "Tell the person: NativeAgent could not install the named bundled parts; preserve existing parts and the reported installation errors.", owner: .builder)
        }
        do {
            let files = try AbilityStore(dataRoot: root).files()
            return CheckResult(source: "abilities/", id: id, title: title, status: "ok", detail: "\(files.count) ability files read successfully.")
        } catch {
            // AbilityStore's own no names its file and lever; an unattributed one is the store's.
            let failure = (error as? ToolFailureError).flatMap { $0.owner == nil ? nil : $0 }
                ?? AbilityStore(dataRoot: root).repairFailure(source: root.appendingPathComponent("abilities"), detail: error.localizedDescription)
            return CheckResult(source: failure.owner, nextCall: failure.nextCall,
                id: id, title: title, status: "fail", detail: error.localizedDescription,
                harm: "The affected ability cannot load. A failed migration leaves all original stores untouched.",
                human_action: failure.tap ?? failure.instruction, ask: failure.personDecides ? .permission : nil)
        }
    }
}

// MARK: - RuntimeJSONStoresCheck

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
}

public struct ChatMessagesIntegrityCheck: DoctorCheck {
    public let id: String = "chat_messages"
    public let title: String = "Chat Message Logs"
    private let root: URL

    /// Process-wide fingerprint memo.
    static let sharedScanCache = ChatMessagesScanCache()

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
    }

    public func run() async -> CheckResult {
        let dir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return CheckResult(source: "chat/messages/",
                id: id,
                title: title,
                status: "warn",
                detail: "Chat message directory is missing at \(dir.path).",
                harm: "New conversation messages cannot be saved.",
                repair: nil
            )
        }

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "jsonl" }
        } catch {
            return CheckResult(source: "chat/messages/",
                id: id,
                title: title,
                status: "fail",
                detail: "Could not list chat message directory: \(error.localizedDescription)",
                harm: "Saved conversation messages cannot be read.",
                human_action: StorageCheck.accessStep(dir.path), ask: .permission
            )
        }

        var totalLines = 0
        var malformedLines = 0
        var malformedFiles: [URL] = []

        var scannedPaths: Set<String> = []

        for file in files {
            let cacheKey = Self.cacheKey(file)
            scannedPaths.insert(cacheKey)
            let fingerprint = Self.fingerprint(file)
            if let memo = await Self.sharedScanCache.lookup(path: cacheKey, stamp: fingerprint) {
                totalLines += memo.totalLines
                malformedLines += memo.malformedLines
                if memo.unreadable || memo.malformedLines > 0 { malformedFiles.append(file) }
                continue
            }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                malformedFiles.append(file)
                if let fingerprint {
                    await Self.sharedScanCache.store(
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
            if let fingerprint {
                await Self.sharedScanCache.store(
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
            }
        }

        await Self.sharedScanCache.retain(
            paths: scannedPaths, under: Self.cacheKey(dir) + "/"
        )

        if malformedLines > 0 || !malformedFiles.isEmpty {
            return CheckResult(source: malformedFiles.map { "chat/messages/" + $0.lastPathComponent }.joined(separator: ", "),
                id: id,
                title: title,
                status: "fail",
                detail: "\(malformedLines) malformed chat JSONL row(s) across \(malformedFiles.count) file(s).",
                harm: "Parts of saved conversations cannot be read.",
                repair: nil,
                human_action: malformedLines == 0 ? malformedFiles.first.map { ToolFailureError.fileRepairInstruction($0,
                    shape: "This transcript holds one saved chat message JSON object per line, retaining the original message identities, roles, content and ordering.") } : nil)
        }
        return CheckResult(source: "chat/messages/",
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
            return CheckResult(source: "memory/memory.sqlite",
                id: id,
                title: title,
                status: "fail",
                detail: "Could not prepare memory directory: \(error.localizedDescription)",
                harm: "Her memories cannot be saved.",
                human_action: StorageCheck.accessStep(memoryDir.path),
                ask: .permission
            )
        }

        var warnings: [String] = []
        if !FileManager.default.fileExists(atPath: sqlite.path) {
            warnings.append("memory.sqlite missing")
        } else {
            do {
                guard let size = try FileManager.default.attributesOfItem(atPath: sqlite.path)[.size] as? NSNumber else {
                    throw CocoaError(.fileReadUnknown)
                }
                if size.int64Value <= 0 { warnings.append("memory.sqlite is empty") }
            } catch {
                return CheckResult(source: sqlite.path, id: id, title: title, status: "fail",
                    detail: "The size of \(sqlite.path) could not be read.",
                    human_action: StorageCheck.accessStep(sqlite.path), ask: .permission)
            }
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
                return CheckResult(source: "memory/memory.sqlite",
                    id: id,
                    title: title,
                    status: "fail",
                    detail: "Knowledge graph tables in memory.sqlite could not be read: \(error.localizedDescription)",
                    harm: "She cannot recall connections between her saved memories.",
                    human_action: "Open Trust → Advanced → Backups, select a verified backup containing memory/memory.sqlite, then choose Restore → Restore backup.",
                    ask: .permission
                )
            }
        }

        if !warnings.isEmpty {
            return CheckResult(source: "memory/memory.sqlite",
                id: id,
                title: title,
                status: "fail",
                detail: "Memory store warning(s): \(warnings.joined(separator: ", ")).",
                human_action: "Open Trust → Advanced → Backups, select a verified backup containing memory/memory.sqlite, then choose Restore → Restore backup.",
                ask: .permission
            )
        }
        return CheckResult(source: "memory/memory.sqlite",
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
    static func localSyncStateWarnings(dataRoot: URL) -> (details: [String], fault: Bool) {
        var warnings: [String] = []
        let stranded = ICloudSyncStatePaths.completedUnarchivedMsgIds(dataRoot: dataRoot)
        if !stranded.isEmpty {
            warnings.append(
                "\(stranded.count) iPhone command(s) completed but their completion record could not be filed "
                + "with local markers at \(stranded.prefix(3).map { ICloudSyncStatePaths.completedUnarchivedMarker(dataRoot: dataRoot, msgId: $0).path }.joined(separator: ", "))"
                + "\(stranded.count > 3 ? ", …" : ""); they remain marked completed"
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
                        .joined(separator: "; ")
                )
            }
        }
        return (warnings, !stranded.isEmpty)
    }

    /// Folds local sync-state warnings into the active transport verdict without
    /// downgrading a harder existing status.
    private func merging(_ result: CheckResult) -> CheckResult {
        let local = Self.localSyncStateWarnings(dataRoot: dataRoot)
        let warnings = local.details
        let corrupt = ICloudSyncStatePaths.processedIdsCorruptBackup(dataRoot: dataRoot)
        let history = FileManager.default.fileExists(atPath: corrupt.path)
            ? "the processed-command list was unreadable and was preserved as processed_ids.corrupt.json, so iPhone commands from before that point may be re-run" : ""
        guard !warnings.isEmpty || !history.isEmpty else { return result }
        let status = result.status == "fail" || local.fault ? "fail" : "warn"
        return CheckResult(source: result.source, nextCall: result.nextCall,
            id: result.id,
            title: result.title,
            status: status,
            detail: ([result.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))] + warnings + (history.isEmpty ? [] : [history])).joined(separator: "; ") + ".",
            harm: result.harm,
            repair: result.repair,
            receipt: result.receipt,
            repairApplied: result.repairApplied,
            human_action: result.human_action,
            repair_available: result.repair_available,
            automaticRepairEligible: result.automaticRepairEligible,
            ask: result.ask,
            owner: result.owner
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
            return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
                id: id, title: title, status: "unmeasured",
                detail: "iCloud transport health is unmeasured; the app's bridge has not started."
            ))
        }
        let containerID = NativeAgentICloudBridgeConstants.containerID
        let cloudKit = snapshot.transport == .cloudKit
        // A CloudKit-signed build whose configured container is not the one its
        // signature grants never gets the CloudKit transport; say that, not
        // the iCloud Drive entitlement it fell back to and never needed.
        let grantedContainers = Self.entitlementValues(DeviceCloudKitPreflight.iCloudContainersEntitlementKey)
        if !cloudKit, services.contains("CloudKit"), !grantedContainers.isEmpty, !grantedContainers.contains(containerID) {
            return merging(CheckResult(source: "iCloud container " + containerID,
                id: id, title: title, status: "warn",
                detail: "This build is configured for iCloud container \(containerID), but its signature grants \(grantedContainers.joined(separator: ", ")), so it has no CloudKit transport for the phone.",
                harm: "The phone cannot exchange messages with her through iCloud.",
                owner: .builder
            ))
        }
        let service = cloudKit ? "CloudKit" : "CloudDocuments"
        let containerKey = cloudKit ? DeviceCloudKitPreflight.iCloudContainersEntitlementKey
            : "com.apple.developer.ubiquity-container-identifiers"
        guard services.contains(service), Self.entitlementValues(containerKey).contains(containerID) else {
            return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
                id: id, title: title, status: "warn",
                detail: "The active \(cloudKit ? "CloudKit" : "iCloud Drive") transport lacks its signed \(service) service or container entitlement.",
                harm: "The phone cannot exchange messages with her through iCloud.",
                owner: .builder
            ))
        }
        if cloudKit {
            return merging(cloudKitResult(snapshot))
        }
        // Doctor's launch run can precede the bridge's first transfer. Not
        // measured yet is a reading, not a defect: nothing is wrong and
        // nothing can be done, so it must not wake her or the phone.
        if case .unmeasured = snapshot.health {
            return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
                id: id, title: title, status: "unmeasured", detail: "iCloud Drive is starting; transport health is not measured yet."
            ))
        }
        guard case .available = snapshot.health, let docsURL = snapshot.documentsURL else {
            let signedIn = FileManager.default.ubiquityIdentityToken != nil
            return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
                id: id, title: title, status: "warn",
                detail: signedIn ? "The active iCloud Drive container is unavailable." : "The active iCloud Drive transport has no signed-in iCloud account.",
                harm: "The phone cannot exchange messages with her through iCloud.",
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
                        return CheckResult(source: docsURL.appendingPathComponent(rel).path,
                            id: id,
                            title: title,
                            status: "fail",
                            detail: "Could not create \(rel): \(error.localizedDescription)",
                            harm: "The phone cannot exchange messages with her through iCloud.",
                            repair: created.isEmpty ? nil : "Created: \(created.joined(separator: ", ")).",
                            repairApplied: !created.isEmpty,
                            repair_available: true
                        )
                    }
                }
            }
        }
        if repair, !created.isEmpty {
            return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
                id: id,
                title: title,
                status: "ok",
                detail: "iCloud/APNS bridge directories are present after repair.",
                repair: "Created: \(created.joined(separator: ", ")).", repairApplied: true
            ))
        }
        if !missing.isEmpty {
            return merging(CheckResult(source: missing.map { docsURL.appendingPathComponent($0).path }.joined(separator: ", "),
                id: id,
                title: title,
                status: "warn",
                detail: "Missing iCloud/APNS bridge path(s): \(missing.joined(separator: ", ")).",
                harm: "The phone cannot exchange messages with her through iCloud.",
                repair: "Press Repair in Diagnostics → Health checks to recreate bridge directories."
            ))
        }
        return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
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
            ? (snapshot.sendMeasured ? "CloudKit has accepted outbound delivery; iOS receipt is not confirmed"
                                     : "CloudKit send health is unmeasured")
            : failures.map { $0.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) }.joined(separator: "; ")
        let adverse = ([receive] + failures).first { $0.status == "fail" }
            ?? ([receive] + failures).first { DoctorSafeRepairPolicy.isAdverse($0.status) }
        return CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
            id: id, title: title,
            status: adverse?.status ?? (receive.status == "ok" && snapshot.sendMeasured && failures.isEmpty ? "ok" : "unmeasured"),
            detail: receive.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) + "; " + send + ".",
            harm: adverse?.harm, repair: adverse?.repair,
            human_action: adverse?.human_action, ask: adverse?.ask, owner: adverse?.owner
        )
    }

    private func cloudKitResult(_ health: ICloudBridgeHealthSnapshot.Health, operation: String) -> CheckResult {
        var status = "warn"
        let detail: String
        var action: String?
        var ask: DoctorAskKind?
        var owner: DoctorOwner?
        switch health {
        case .unmeasured:
            // Not measured yet (see the iCloud Drive branch above): a reading.
            status = "unmeasured"
            detail = "CloudKit \(operation) health is unmeasured; iCloud Drive is not required."
        case .available:
            status = "ok"
            detail = "CloudKit is active and its last \(operation) completed successfully; iCloud Drive is not required."
        case .signedOut:
            detail = "CloudKit \(operation) has no authenticated iCloud account."
            action = "Open System Settings → Apple Account and sign in to iCloud."
            ask = .signIn
        case .notEntitled:
            owner = .builder
            detail = "CloudKit \(operation) is not configured with its required entitlements."
            action = "Install a signed NativeAgent build granting CloudKit and container \(NativeAgentICloudBridgeConstants.containerID)."
        case .quotaExceeded:
            detail = "The active CloudKit transport cannot \(operation) because iCloud storage is full."
            action = "Open System Settings → Apple Account → iCloud → Manage and free iCloud storage."
            ask = .permission
        case .accountFailure(let code, let reason):
            detail = "CloudKit \(operation) was rejected: \(reason)"
            switch CKError.Code(rawValue: code) {
            case .notAuthenticated:
                action = "Open System Settings → Apple Account and complete iCloud sign-in."
                ask = .signIn
            case .missingEntitlement:
                owner = .builder
                action = "Install a signed NativeAgent build granting CloudKit and container \(NativeAgentICloudBridgeConstants.containerID)."
            case .managedAccountRestricted:
                action = "Ask your Apple Account administrator to allow CloudKit for NativeAgent."
                ask = .permission
            default: status = "fail"
            }
        case .unavailable(let reason):
            status = "fail"
            detail = "The active CloudKit transport's last \(operation) failed: \(reason)"
        case .pairedElsewhere:
            // The person's choice, not a fault: the phone follows one Mac.
            status = "ok"
            detail = "The iPhone is paired with another Mac (or an earlier install) on this Apple Account; this Mac stays quiet toward it."
            action = "Choose Use my iPhone with this Mac in Connectors → iPhone to disconnect it from the other Mac and connect it here."
        }
        return CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID + ": " + operation, id: id, title: title, status: status, detail: detail,
                           harm: DoctorSafeRepairPolicy.isAdverse(status) ? "The phone cannot exchange messages with her through iCloud." : nil,
                           human_action: action, ask: ask, owner: owner)
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
    public var title: String { "Core ML Embedder (\(resolvedModelID))" }

    private var resolvedModelID: String {
        (try? CoreMLEmbeddingProvider.installedExtrasModel(root: root))?.modelID
            ?? CoreMLEmbeddingProvider.bundledModelID
    }

    private let root: URL

    public init(root: URL = defaultDataRoot()) { self.root = root }

    public func run(repair: Bool) async -> CheckResult {
        // An installed model whose manifest is unusable fails here by name —
        // it is never reported as the MiniLM floor loading (S12, 2026-09-26).
        do {
            _ = try CoreMLEmbeddingProvider.installedExtrasModel(root: root)
        } catch {
            let unusable: (manifest: URL, reason: String)? = if case .installedModelUnusable(let path, let reason) = error as? EmbeddingError {
                (URL(fileURLWithPath: path), reason)
            } else { nil }
            let dataFile = unusable.flatMap { $0.manifest.path.hasPrefix(root.path + "/") ? $0 : nil }
            // The manifest's own words name a damaged manifest; anything else is a missing
            // or invalid model asset, which only the installation directory set aside fixes.
            let manifestDamaged = dataFile.map { $0.reason.hasPrefix("embedding.json") || $0.reason.hasPrefix("model and vocab") } ?? false
            return CheckResult(source: unusable.map { manifestDamaged ? $0.manifest.path : $0.manifest.deletingLastPathComponent().path } ?? "extras/coreml/embedding.json",
                id: id, title: "Core ML Embedder (installed model)", status: "fail",
                detail: "The installed model is unusable (\(error.localizedDescription)); semantic recall is off until it is fixed or removed.",
                harm: "She cannot search her memories by meaning.",
                human_action: dataFile.map { file in manifestDamaged
                    ? ToolFailureError.fileRepairInstruction(file.manifest,
                        shape: "This JSON manifest holds model and vocab file names beside it, a nonempty model_id and a positive integer dimensions. Preserve the selected model; do not substitute another model or invent missing assets.")
                    : ToolFailureError.fileRepairInstruction(file.manifest.deletingLastPathComponent(),
                        shape: "This installed memory model directory is unusable (\(file.reason)). If embedding.json names a model the person installed themselves, leave it and report that. "
                            + "Otherwise move the whole directory intact to a sibling recovery name, never deleting a file, so app embeddings.resume installs the release model again.") },
                owner: unusable != nil && dataFile == nil ? .builder : nil
            )
        }
        guard CoreMLEmbeddingProvider.bundledResourcesAvailable(extrasRoot: root) else {
            return CheckResult(source: "NativeAgent app bundle: minilm.mlpackage and minilm_vocab.txt",
                id: id, title: title, status: "fail",
                detail: "minilm.mlpackage or minilm_vocab.txt is missing from the app bundle.",
                harm: "She cannot search her memories by meaning.",
                owner: .builder
            )
        }
        if repair {
            CoreMLEmbeddingProvider.wipeBundledCompileCache(extrasRoot: root)
            let after = await probe()
            return CheckResult(source: after.source, nextCall: after.nextCall,
                id: id, title: title, status: after.status, detail: after.detail,
                harm: after.harm,
                repair: "Wiped the CoreML compile cache and re-probed the model load.",
                repairApplied: true,
                repair_available: true
            )
        }
        return await probe()
    }

    private func probe() async -> CheckResult {
        // The floor is reported separately from the resolved model: an extras
        // install that shadows a missing MiniLM is a different situation from
        // one that sits on top of it.
        let floor = CoreMLEmbeddingProvider.bundledFloorResourcesAvailable()
            ? "the bundled MiniLM floor is present"
            : "the bundled MiniLM floor is MISSING from the app bundle"
        do {
            // Full real-path probe: compile-cache resolution + MLModel load +
            // WordPiece vocab. Same code the runtime's first embed() runs — so
            // this loads whatever the runtime resolves, extras model included.
            let provider = try CoreMLEmbeddingProvider.bundled(extrasRoot: root)
            return CheckResult(source: "extras/coreml",
                id: id, title: title, status: "ok",
                detail: "\(provider.modelId), \(provider.dimensions)-d, loads: model compiles/loads from cache and the WordPiece vocab parses; \(floor)."
            )
        } catch {
            return CheckResult(source: "Core ML model \(resolvedModelID) and its compiled cache",
                id: id, title: title, status: "fail",
                detail: "\(resolvedModelID) failed to load (\(String(describing: error))); semantic recall is degraded; \(floor).",
                harm: "She cannot reliably search her memories by meaning.",
                repair: "Press Repair in Diagnostics → Health checks to clear the Core ML compile cache and retry loading the model."
            )
        }
    }
}

// MARK: - OpLogHealthCheck

/// Is any append-only op-log feed wedged or growing without bound?
///
/// WHY THIS CHECK EXISTS (gpt-5.5 review 2026-08-02, finding 3): the
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

        // A store whose read THROWS is itself a finding, so each feed is
        // probed independently and a throw becomes this feed's fail line,
        // never an abort of the other.
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

// MARK: - OAuthTokenExpiryCheck

/// Expiry repair delegates to the credential's runtime owner. Inspection never
/// exchanges tokens; safe repair refreshes only expired, refreshable credentials.
public struct OAuthTokenExpiryCheck: RepairingDoctorCheck {
    public let id = "oauth_token_expiry"
    public let title = "OAuth Token Expiry"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    private struct Credential {
        let owner: String
        let name: String
        let path: URL

        func signIn(_ root: URL) -> String {
            if let control = NativeOAuthFlow.signInControl(providerID: owner, dataRoot: root) { return "Open " + control + "." }
            return "Open Connectors → \(name) → Connect (or Reconnect)."
        }
    }

    private func credentials() -> [Credential] {
        let entries = [
            ("xai_oauth_direct", "xAI"), ("anthropic_oauth_direct", "Anthropic"),
            ("openai_oauth_direct", "ChatGPT"),
        ].map { owner, name in
            Credential(owner: owner, name: name,
                       path: ProviderOAuthCredentialMaintenance.credentialPath(provider: owner, root: root))
        }
        return entries.filter { credential in
            let fm = FileManager.default
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

    private func status(_ credential: Credential) async throws -> OAuthCredentialHealth {
        try ProviderOAuthCredentialMaintenance.status(provider: credential.owner, root: root)
    }

    private func refresh(_ credential: Credential) async throws {
        try await ProviderOAuthCredentialMaintenance.refresh(provider: credential.owner, root: root)
    }

    private func requiresSignIn(_ error: Error, credential: Credential) -> Bool {
        ProviderOAuthCredentialMaintenance.requiresSignIn(error)
    }

    public func run() async -> CheckResult { await run(repair: false) }

    public func run(repair: Bool) async -> CheckResult {
        let now = Date()
        var findings: [String] = []
        var asks: [String] = []
        var repaired: [String] = []
        var noExpiry: [String] = []
        var refreshable = false
        var unreadable = false
        var checked = 0
        for credential in credentials() {
            do {
                var state = try await status(credential)
                checked += 1
                guard state.configured else {
                    findings.append("\(credential.name) has no usable saved credential")
                    asks.append(credential.signIn(root))
                    continue
                }
                if state.expiresAt == nil && !state.requiresRefresh {
                    noExpiry.append(credential.name)
                    continue
                }
                if !state.requiresRefresh, let expiry = state.expiresAt, expiry > now {
                    if !state.canRefresh && expiry.timeIntervalSince(now) <= 7 * 24 * 60 * 60 {
                        findings.append("\(credential.name) access expires within 7 days and no refresh credential is available")
                        asks.append(credential.signIn(root))
                    }
                    continue
                }
                let reason = state.requiresRefresh ? "authorization needs renewal" : "access expired"
                guard state.canRefresh else {
                    findings.append("\(credential.name) \(reason) and no refresh credential is available")
                    asks.append(credential.signIn(root))
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
                    state = try await status(credential)
                    if state.configured && !state.requiresRefresh && (state.expiresAt.map { $0 > Date() } ?? true) {
                        repaired.append(credential.name)
                        if state.expiresAt == nil { noExpiry.append(credential.name) }
                    } else {
                        findings.append("\(credential.name) still has no current access credential after refresh")
                        if !state.configured || !state.canRefresh { asks.append(credential.signIn(root)) }
                        else { refreshable = true }
                    }
                } catch {
                    if requiresSignIn(error, credential: credential) {
                        findings.append("\(credential.name) rejected the saved refresh authorization")
                        asks.append(credential.signIn(root))
                    } else {
                        // Provider bodies and credential material never enter Doctor reports.
                        findings.append("\(credential.name) refresh could not complete")
                        refreshable = true
                    }
                }
            } catch {
                unreadable = true
                findings.append("\(credential.name) credential state could not be read from \(credential.path.path)")
                asks.append(credential.signIn(root))
            }
        }
        var parts = ["\(checked) credential(s) inspected through their owners"]
        if !noExpiry.isEmpty {
            parts.append("no scheduled expiry: \(noExpiry.joined(separator: ", "))")
        }
        if !repaired.isEmpty { parts.append("refreshed: \(repaired.joined(separator: ", "))") }
        parts += findings
        let actions = asks.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) }
        return CheckResult(source: credentials().map { $0.path.path }.joined(separator: ", "), id: id, title: title,
                           status: unreadable ? "fail" : findings.isEmpty ? "ok" : "warn",
                           detail: parts.joined(separator: "; ") + ".",
                           harm: asks.isEmpty ? nil : "She cannot keep using the affected services without renewed access.",
                           repair: refreshable ? DoctorSafeRepairPolicy.oauthRefreshInstruction : nil,
                           receipt: repaired.isEmpty ? nil : "Repaired: refreshed \(repaired.joined(separator: ", ")).",
                           repairApplied: !repaired.isEmpty,
                           human_action: asks.isEmpty ? nil : actions.joined(separator: "; ") + ".",
                           ask: asks.isEmpty ? nil : .signIn)
    }
}

public actor SwiftNativeDoctorChecks: DoctorChecksProtocol {
    private let checks: [DoctorCheck]

    /// The production check list. Exposed as a named value (rather than an
    /// inline default argument) so `DoctorHeartbeatPolicy` can DERIVE the
    /// unattended-sweep exclusions from the same array the app runs, instead
    /// of keeping a second hand-maintained list beside it.
    public static let defaultChecks: [DoctorCheck] = checks()

    public static func checks(root: URL? = nil) -> [DoctorCheck] {
        let dataRoot = root ?? defaultDataRoot()
        return [
            StorageCheck(root: dataRoot),
            RuntimeJSONStoresCheck(root: dataRoot),
            AbilityFilesCheck(root: dataRoot),
            RunLedgerIntegrityCheck(root: dataRoot),
            TurnTraceIntegrityCheck(root: dataRoot),
            ChatSessionsCheck(root: dataRoot),
            // One-thread-many-surfaces Phase 0: hot session count, 24h mints BY
            // MINT SITE, and the source-flapping detector. Read-only.
            SessionIdentityCheck(root: dataRoot),
            // Read-only Doctor rows over the turn-trace feed, so a
            // behavior no longer depends on bounded previews. All are read-only,
            // bounded (tailed day files), and run ONLY inside a Doctor pass —
            // never on a turn, a timer, or the cognition runtime. These are
            // `heartbeatEligible == false`: they are for a person reading Doctor,
            // never for an unattended sweep that can wake User.
            //   * PromptPrefixHealthCheck — cross-turn prefix cache reuse.
            //   * SubconsciousVitalsCheck — capsule attachment and felt/Inner/Sound
            //     variety, plus the organism's own chemistry.
            //   * ModelCompensationsCheck — compensation receipts, without judgment.
            PromptPrefixHealthCheck(root: dataRoot),
            SubconsciousVitalsCheck(root: dataRoot),
            ModelCompensationsCheck(root: dataRoot),
            ChatMessagesIntegrityCheck(root: dataRoot),
            PersonaEngineCheck(root: root),
            MemoryStoreCheck(root: dataRoot),
            CoreMLEmbedderCheck(root: dataRoot),
            ICloudBridgeStateCheck(dataRoot: dataRoot),
            OpLogHealthCheck(root: dataRoot),
            OAuthTokenExpiryCheck(root: dataRoot),
        ]
    }

    public init(checks: [DoctorCheck] = SwiftNativeDoctorChecks.defaultChecks) {
        self.checks = checks
    }

    public func runAll() async throws -> [CheckResult] {
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
                // Only registered owner repairs run automatically; onboarding
                // uses the remaining create-missing handlers.
                if scope == .automatic, DoctorSafeRepairPolicy.automaticCoreIDs.contains(id),
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

public func makeDoctorChecks(root: URL? = nil, freshMeasurement: Bool = false) -> any DoctorChecksProtocol {
    let root = root == defaultDataRoot() ? nil : root
    var checks = root.map { SwiftNativeDoctorChecks.checks(root: $0) } ?? SwiftNativeDoctorChecks.defaultChecks
    if freshMeasurement {
        checks = checks.map { check in
            switch check.id {
            case "prompt_prefix_health": PromptPrefixHealthCheck(root: root ?? defaultDataRoot(), cacheTTL: 0)
            case "subconscious_vitals": SubconsciousVitalsCheck(root: root ?? defaultDataRoot(), cacheTTL: 0)
            case "model.shims": ModelCompensationsCheck(root: root ?? defaultDataRoot(), cacheTTL: 0)
            default: check
            }
        }
    }
    return SwiftNativeDoctorChecks(checks: checks)
}
