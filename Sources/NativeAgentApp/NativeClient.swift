import Foundation
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting

// Cutover-seam: NativeAgentShared and Core's MemoryV2 module both ship a
// public `MemoryRecord` type. The app's UI/decoding has always used the
// NativeAgentShared variant — alias it at file scope so every existing
// unqualified `MemoryRecord` reference keeps resolving the same way it did
// before the Swift subsystem imports landed. (`ToolRecord` is defined
// internally in this app module, so module-local lookup already wins over
// `ToolRegistry.ToolRecord`.)
typealias MemoryRecord = NativeAgentShared.MemoryRecord
// Wave 16 (2026-06-01): ChatOrchestration product also exports a
// `MultimodalAttachment` (its own wire-mirror — see comment in
// ChatOrchestrationClient.swift). The app's existing call sites all expect
// the NativeAgentShared variant — alias at file scope so unqualified
// references keep resolving the way they did pre-import.
typealias MultimodalAttachment = NativeAgentShared.MultimodalAttachment
// Same disambiguation for ChatSession — ChatOrchestration exports a different
// ChatSession DTO (session-history shape). App's UI uses the NativeAgentShared one.
typealias ChatSession = NativeAgentShared.ChatSession
import NativeAgentCore
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
// TriggerScheduler owns inbox and Workshop trigger list/enable/disable/configure.
// Inbox /fire_now is Swift-native for stub=true canonical
// kinds (file_watch/idle/time/execution_complete/session_pattern); stub=false
// fails closed unless Swift can execute it. Execution trigger fire-now routes
// through SwiftNativeWorkshopRunner.
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
// SystemOps owns router planning, rebuild, stash recovery, and crash reports.
import SystemOps
// ScreenVision v1 (2026-06-06): Swift-native ScreenCaptureKit wrapper.
// Powers NativeClient.captureScreenForChat() and (via ContentView's
// NativeScreenCapture shim) the chat composer's "Show agent my screen"
// button. Fail-closed on permission denial; no daemon HTTP fallback.
import ScreenVision
// TelegramBot owns status, test, and log-clear management. The Mac UI's
// own TelegramStatus / TelegramTestResponse models stay the wire contract;
// the SwiftNative path round-trips through the module impl and re-decodes
// into them (lossless — receipts/blocked/errors ride the status `extras`).
// `TelegramBot.` qualification disambiguates the module's TelegramStatus /
// TelegramTestResult from the Mac app's same-named structs. See
// CUTOVER_PLAN.md §6.34.
import TelegramBot
// Dispatcher owns the Swift-native POST /v1/dispatch path.
import Dispatcher
// MacControl zero-daemon Swift surface. Implemented actions execute in Swift
// behind TrustCenter policy; unsupported actions fail closed in Swift.
import MacControl
// Onboarding owns start, completion, and reset in Swift.
import Onboarding
// MacAssistantStatus owns the Swift-native status projection.
import MacAssistantStatus
import WorkflowOrchestration
import Skills
// Connectors owns workspace listing and local workspace search.
import Connectors
// Browser owns status, cancel, dry-run, and
// approval-gated visible navigation are Swift-native.
import Browser

// 2026-06-07: lifted from `private` to internal so MacIntegrationBridgeImpl
// can construct the same provider when dispatching mac_spotlight_search (the
// connector-action route in this file uses an instance; the bridge needs an
// equivalent for parity).
struct TrustCenterMacControlPolicyProvider: MacControlPolicyProvider {
    func currentPolicy() async -> MacControlPolicy? {
        let policy = await SwiftNativeTrustCenter().loadTrustPolicy()
        return MacControlPolicy.fromTrustPolicyObject(policy)
    }
}

struct CodexCheckResponse: Codable {
    var ok: Bool
    var model: String
}

struct ChatResponse: Codable {
    var runId: String
    var model: String
    var requestedModel: String?
    var reasoningEffort: String?
    var output: String
    var sessionId: String?
    var attachments: [MultimodalAttachment]?
    var message: ChatMessage?
    var messages: [ChatMessage]?
    var personaFingerprint: String?
    var contextFingerprint: String?
}

struct NativeClient {
    var baseURL: String
    static let codexDeviceLoginManager = SwiftCodexDeviceLoginManager()
    /// The Mac surface keeps one immutable orchestration body resident. The
    /// client owns no canonical mind state; it reuses the same live cognition,
    /// memory, routing, TrustCenter, and tool owners while preserving their
    /// per-turn reads and effect-time checks.
    static let residentMacChatClient = makeNativeAgentAppChatOrchestrationClient(
        profile: .mac
    )
    private static let tailJSONLMaxBytes = 1_048_576

    // fix2/F6 (2026-06-02): `daemonRetired(method:)` helper deleted after the
    // workflow stub stopped using it. The current workflow run/resume path
    // routes through SwiftNativeWorkflowOrchestrationClient.

    // DAEMON-KILL P1 helper: tail the last N JSON lines of a JSONL file and
    // decode each individually. Undecodable lines are skipped. Missing file
    // returns []. Used by getTraces / getNativeActionReceipts / getActivity.
    func tailJSONL<T: Decodable>(path: URL, limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let sizeNumber = attrs[.size] as? NSNumber else {
            return []
        }
        let size = sizeNumber.uint64Value
        guard size > 0 else { return [] }

        let maxBytes = UInt64(Self.tailJSONLMaxBytes)
        let toRead = min(size, maxBytes)
        let seekFromEnd = size > toRead
        guard let handle = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? handle.close() }
        if seekFromEnd {
            do {
                try handle.seek(toOffset: size - toRead)
            } catch {
                return []
            }
        }
        let data = handle.readData(ofLength: Int(toRead))
        let decoder = JSONDecoder.nativeAgent
        let lines = Self.decodeTailLines(data, dropFirstPartial: seekFromEnd)
        let tail = lines.suffix(limit)
        var out: [T] = []
        out.reserveCapacity(tail.count)
        for line in tail {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let lineData = trimmed.data(using: .utf8),
               let row = try? decoder.decode(T.self, from: lineData) {
                out.append(row)
            }
        }
        return out
    }

    static func decodeTailLines(_ data: Data, dropFirstPartial: Bool) -> [String] {
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        if dropFirstPartial && !parts.isEmpty { parts.removeFirst() }
        return parts
    }

    static func graphEntity(id: String, object: [String: JSONValue]) -> GraphEntity {
        GraphEntity(
            id: id,
            name: graphString(object["name"]) ?? id,
            aliases: graphStringArray(object["aliases"]).isEmpty ? nil : graphStringArray(object["aliases"]),
            kind: graphString(object["type"]) ?? graphString(object["kind"]),
            confidence: graphDouble(object["confidence"]),
            mentions: {
                let value = graphInt(object["mentions"])
                return value == 0 ? nil : value
            }(),
            sourceNodeIds: {
                let snake = graphStringArray(object["source_node_ids"])
                if !snake.isEmpty { return snake }
                let camel = graphStringArray(object["sourceNodeIds"])
                return camel.isEmpty ? nil : camel
            }(),
            updatedAt: graphString(object["updated_at"]) ?? graphString(object["updatedAt"])
        )
    }

    static func graphString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let string) = value { return string }
        return nil
    }

    static func graphStringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { graphString($0) }
    }

    static func graphInt(_ value: JSONValue?) -> Int {
        guard let value else { return 0 }
        switch value {
        case .int(let int): return Int(int)
        case .double(let double): return Int(double)
        case .string(let string): return Int(string) ?? 0
        default: return 0
        }
    }

    static func graphDouble(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let double): return double
        case .int(let int): return Double(int)
        case .string(let string): return Double(string)
        default: return nil
        }
    }

    static func privacyCategories(
        dataRoot: URL,
        includeInventory: Bool = true
    ) -> [PrivacyCategory] {
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
            Spec(id: "improvements", title: "Self Improvement", relativePath: "improvements", detail: "self-improvement runs, patches, gauntlets, and promotion state", exportable: true),
            Spec(id: "training_journal", title: "Training Journal", relativePath: "training_journal", detail: "drill runs, training proposals, and promotion staging", exportable: true),
            Spec(id: "backups", title: "Backups", relativePath: "backups", detail: "local backups and restore registry", exportable: false),
            Spec(id: "production", title: "Production Artifacts", relativePath: "production", detail: "exports, support bundles, and migration records", exportable: false),
            Spec(id: "logs", title: "Logs", relativePath: "logs", detail: "runtime logs and diagnostic output", exportable: false),
            Spec(id: "crash_reports", title: "Crash Reports", relativePath: "crash_reports", detail: "submitted crash report payloads", exportable: false),
        ]
        return specs.map { spec in
            let path = dataRoot.appendingPathComponent(spec.relativePath)
            let inventory = includeInventory ? "; \(privacyItemSummary(path))" : ""
            return PrivacyCategory(
                id: spec.id,
                title: spec.title,
                path: path.path,
                contains: "\(spec.detail)\(inventory)",
                exportable: spec.exportable
            )
        }
    }

    static func privacyItemSummary(_ path: URL) -> String {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            return "not present"
        }
        if !isDirectory.boolValue {
            let bytes = (try? fm.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0
            return "1 file, \(bytes) bytes"
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
            return "10,000+ files, \(bytes) bytes scanned"
        }
        return "\(files) file\(files == 1 ? "" : "s"), \(bytes) bytes"
    }

    static func nativeRouteMissing(path: String, method: String) -> NSError {
        return NSError(
            domain: "NativeAgentSwiftOnly",
            code: -410,
            userInfo: [
                NSLocalizedDescriptionKey: "\(method) \(path): no native Swift implementation is wired for this call."
            ]
        )
    }

    /// fix2/F6: stop-shipping-lies envelope. A method that returns `{ok: true}`
    /// without doing the work is worse than a disabled affordance. Methods whose
    /// real implementation is deliberately unavailable throw this — the UI can branch on
    /// `userInfo["code"] == "not_implemented"` to render a "panel-disabled" badge
    /// instead of a success toast. See docs/zombie_stub_audit.md.
    static func notImplemented(method: String, reason: String, followup: String) -> NSError {
        return NSError(
            domain: "NativeAgentNotImplemented",
            code: -501,
            userInfo: [
                NSLocalizedDescriptionKey: "\(method): \(reason)",
                "code": "not_implemented",
                "method": method,
                "reason": reason,
                "followup": followup,
                "panelDisabled": true,
            ]
        )
    }

    /// Same shape as `notImplemented` but for dict-returning routes whose Swift
    /// signature is `[String: Any]`. Returns the envelope the UI expects rather
    /// than throwing, so a panel can render the disabled badge without an error
    /// modal. Use this when the caller is `[String: Any]`-typed (e.g.
    /// consolidateMemory, runDrills, runRem). For typed-Codable routes throw
    /// `notImplemented(...)` instead.
    static func notImplementedDict(method: String, reason: String, followup: String) -> [String: Any] {
        return [
            "ok": false,
            "code": "not_implemented",
            "method": method,
            "reason": reason,
            "followup": followup,
            "panelDisabled": true,
        ]
    }

    /// Lossy array decode shared by the HTTP `getList` path and the SwiftNative
    /// route-replacement paths (e.g. `getSkills()` when `.skills` is ON), so the
    /// native path is decode-equivalent to HTTP: a single malformed element is
    /// dropped (not fatal to the whole batch), but an all-fail on a non-empty
    /// array throws so the caller's decodeLogged records it.
    static func decodeLossyArray<T: Decodable>(_ data: Data, context: String) throws -> [T] {
        let decoder = JSONDecoder.nativeAgent
        // Decode into an array of element containers; if the top level isn't an
        // array, fall back to the strict decode (preserves prior behavior for
        // dict-wrapped or otherwise-shaped responses).
        guard let elements = try? decoder.decode([LossyElement<T>].self, from: data) else {
            return try decoder.decode([T].self, from: data)
        }
        var firstDropError: Error? = nil
        let survivors: [T] = elements.compactMap { element in
            switch element.result {
            case .success(let value):
                return value
            case .failure(let error):
                if firstDropError == nil { firstDropError = error }
                print("[NativeAgent] \(context) dropped a malformed element: \(error)")
                return nil
            }
        }
        // FIX (B): partial success (some survivors) is fine and returns the good
        // elements. But if the raw array was non-empty and EVERY element failed
        // to decode (e.g. a server-side schema change), a silent [] would be
        // indistinguishable from a genuinely empty list. Throw so the caller's
        // decodeLogged records it in lastRefreshError; the caller still falls
        // back to an empty list, so the returned data is unchanged.
        if !elements.isEmpty && survivors.isEmpty {
            throw firstDropError ?? NSError(
                domain: "NativeAgent",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "\(context): all \(elements.count) element(s) failed to decode"]
            )
        }
        return survivors
    }

    /// Decode a SwiftNative route-replacement's JSONValue result into the model
    /// type the HTTP path returns, using the SAME JSONDecoder.nativeAgent. Used
    /// by the wave-32 W15 skill mutation gates (updateSkill → SkillRecord).
    static func decodeJSONValue<T: Decodable>(_ value: JSONValue, as type: T.Type, context: String) throws -> T {
        let data = try value.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(T.self, from: data)
    }

    /// U5 W-A item 1: honest JSONL read. `readJSONL` returns [] for a
    /// MISSING file (legitimate healthy-empty) but ALSO drops unparseable
    /// lines silently — so a fully-corrupt file is indistinguishable from
    /// an empty one. This wrapper applies decodeLossyArray's all-fail rule
    /// at the line layer: the file has bytes on disk but zero rows parsed →
    /// throw, so the caller surfaces a read error instead of rendering a
    /// fabricated empty list.
    static func readJSONLHonest(
        _ persistence: SwiftNativePersistenceCore,
        path: URL,
        context: String
    ) async throws -> [JSONValue] {
        let rows = try await persistence.readJSONL(path)
        if rows.isEmpty,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 0 {
            throw NSError(domain: "NativeAgent", code: -3, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(context): \(path.lastPathComponent) has \(size.intValue) byte(s) "
                    + "but no JSONL row parsed — corrupt file, refusing to render it as empty"
            ])
        }
        return rows
    }

    // A small number of view callers still use this catch-all shape. Sniff the
    // path and dispatch to the native impl. Unknown paths throw a route-missing
    // Swift error so the symptom surfaces instead of silently succeeding.
    func postRaw(_ path: String, body: [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        _ = timeout
        if path == "/v1/config" || path.hasPrefix("/v1/config?") {
            // Pre-convert outside the @Sendable closure (Any is non-Sendable).
            let entries: [(String, JSONValue)] = body.map { ($0.key, JSONValue(fromFoundation: $0.value)) }
            if let unsupported = entries.map(\.0).sorted().first(where: { key in
                key != "searxng_base_url"
                    && key != "auto_doctor"
                    && !key.hasPrefix("auto_doctor.")
            }) {
                return ["error": "unsupported_legacy_config_key", "key": unsupported]
            }

            let dataRoot = PersistenceCore.defaultDataRoot()
            let persistence = SwiftNativePersistenceCore()

            let autoDoctorEntries = entries.filter { key, _ in
                key == "auto_doctor" || key.hasPrefix("auto_doctor.")
            }
            if !autoDoctorEntries.isEmpty {
                let autoDoctorPath = dataRoot
                    .appendingPathComponent("auto_doctor", isDirectory: true)
                    .appendingPathComponent("config.json")
                try await persistence.withFileLock(autoDoctorPath) {
                    let current = await persistence.readJSON(autoDoctorPath, defaultValue: .object([:]))
                    var root: [String: JSONValue]
                    if case .object(let obj) = current { root = obj } else { root = [:] }
                    for (key, value) in autoDoctorEntries {
                        if key == "auto_doctor" {
                            if case .object(let obj) = value {
                                root = obj
                            }
                            continue
                        }
                        let nestedKey = String(key.dropFirst("auto_doctor.".count))
                        guard !nestedKey.isEmpty else { continue }
                        root[nestedKey] = value
                    }
                    try await persistence.writeJSON(.object(root), to: autoDoctorPath)
                }
            }

            if let (_, value) = entries.first(where: { $0.0 == "searxng_base_url" }) {
                let researchPath = dataRoot
                    .appendingPathComponent("research", isDirectory: true)
                    .appendingPathComponent("config.json")
                try await persistence.withFileLock(researchPath) {
                    let current = await persistence.readJSON(researchPath, defaultValue: .object([:]))
                    var root: [String: JSONValue]
                    if case .object(let obj) = current { root = obj } else { root = [:] }
                    root["searxng_base_url"] = value
                    try await persistence.writeJSON(.object(root), to: researchPath)
                }
            }
            return ["ok": true]
        }
        if path == "/v1/trust" || path.hasPrefix("/v1/trust?") {
            _ = try await postTrustWrite(body: body)
            return ["ok": true]
        }
        if path == "/v1/mcp/sessions/restart" || path.hasPrefix("/v1/mcp/sessions/restart?") {
            let servers = try await getMCPServers()
            var restarted = 0
            var errors: [[String: String]] = []
            for server in servers {
                do {
                    _ = try await restartMCPServer(serverId: server.id)
                    restarted += 1
                } catch {
                    errors.append(["serverId": server.id, "error": error.localizedDescription])
                }
            }
            return [
                "ok": errors.isEmpty,
                "restarted": restarted,
                "errors": errors,
            ]
        }
        throw NativeClient.nativeRouteMissing(path: path, method: "POST-raw")
    }
}

struct SearchResponse: Codable {
    var results: [ResearchResult]
}

struct EmptyResponse: Codable {}

struct ProviderActiveResponse: Codable {
    var ok: Bool?
    var error: String?
    var detail: String?
}

struct SurfaceModelPreferencesResponse: Codable {
    var preferences: [SurfaceModelPreferenceEntry]
}

struct SurfaceModelPreferenceEntry: Codable {
    var surface: String
    var model: String
    var reasoningEffort: String
    var serviceTier: String? = nil
}

// PATCH-Phase7b: DispatchResult — receipt returned by POST /v1/dispatch
struct DispatchResult: Decodable {
    let ok: Bool
    let tool: String
    let status: String          // "ok" | "failed" | "blocked" | "pending_approval" | "dry_run"
    let output: DispatchOutput?
    let error: DispatchToolError?
    let executed: Bool
    let verifyPassed: Bool?
    let durationUs: Int
    let durationMs: Int
    let effectiveAutonomy: String
    let autonomySource: String
    let providerMatch: Bool
    let traceEventId: String?
    let runId: String
    let startedAt: String

    enum CodingKeys: String, CodingKey {
        case ok, tool, status, output, error, executed
        case verifyPassed      = "verify_passed"
        case durationUs        = "duration_us"
        case durationMs        = "duration_ms"
        case effectiveAutonomy = "effective_autonomy"
        case autonomySource    = "autonomy_source"
        case providerMatch     = "provider_match"
        case traceEventId      = "trace_event_id"
        case runId             = "run_id"
        case startedAt         = "started_at"
    }

    struct DispatchToolError: Decodable {
        let code: String
        let message: String
        let tool: String?
        let recoverable: Bool

        init(code: String, message: String, tool: String?, recoverable: Bool) {
            self.code = code; self.message = message; self.tool = tool; self.recoverable = recoverable
        }
    }

    init(ok: Bool, tool: String, status: String, output: DispatchOutput?, error: DispatchToolError?, executed: Bool, verifyPassed: Bool?, durationUs: Int, durationMs: Int, effectiveAutonomy: String, autonomySource: String, providerMatch: Bool, traceEventId: String?, runId: String, startedAt: String) {
        self.ok = ok; self.tool = tool; self.status = status; self.output = output; self.error = error; self.executed = executed; self.verifyPassed = verifyPassed; self.durationUs = durationUs; self.durationMs = durationMs; self.effectiveAutonomy = effectiveAutonomy; self.autonomySource = autonomySource; self.providerMatch = providerMatch; self.traceEventId = traceEventId; self.runId = runId; self.startedAt = startedAt
    }
}

/// Permissive output wrapper: the Receipt's `output` field can be any JSON shape.
/// We capture it as a best-effort string for display.
struct DispatchOutput: Decodable {
    let rawString: String

    // Wave 36 W11 — memberwise init so the in-process `_swiftDispatch` seam can
    // preserve a native handler's `output` payload (e.g. persona_read's
    // `content`) instead of dropping it to nil. The module-side
    // `Dispatcher.DispatchOutput.value` (a JSONValue) is serialized to a JSON
    // string here, matching the shape `init(from:)` produces for an object/array
    // on the HTTP path so raw-string consumers parse it identically.
    init(rawString: String) {
        self.rawString = rawString
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Try each concrete type; fall back to JSON serialization.
        if let s = try? c.decode(String.self) {
            rawString = s
        } else if let d = try? c.decode([String: AnyDecodableValue].self) {
            let obj = d.mapValues { $0.anyValue }
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)) ?? Data()
            rawString = String(data: data, encoding: .utf8) ?? "{}"
        } else if let a = try? c.decode([AnyDecodableValue].self) {
            let arr = a.map { $0.anyValue }
            let data = (try? JSONSerialization.data(withJSONObject: arr, options: .prettyPrinted)) ?? Data()
            rawString = String(data: data, encoding: .utf8) ?? "[]"
        } else {
            rawString = "(unparseable output)"
        }
    }
}

// Local errors for Swift-native app routes. Retired-route callers either use a
// native implementation or throw an explicit notImplemented envelope.
enum DaemonError: Error, LocalizedError {
    case notFound(String)
    case swiftNativeNotImplemented(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path): return "Not found: \(path)"
        case .swiftNativeNotImplemented(let what):
            return "Swift-native impl for \(what) is not built yet."
        }
    }
}

/// Minimal Any-JSON leaf decoder used by DispatchOutput.
enum AnyDecodableValue: Decodable {
    case string(String), int(Int), double(Double), bool(Bool), null

    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i):    return i
        case .double(let d): return d
        case .bool(let b):   return b
        case .null:          return NSNull()
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self)   { self = .bool(b);   return }
        if let i = try? c.decode(Int.self)    { self = .int(i);    return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .null
    }
}


extension JSONDecoder {
    static var nativeAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension URL {
    func appendingNativeRelativePath(_ relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(self) { partial, component in
                partial.appendingPathComponent(String(component))
            }
    }
}
