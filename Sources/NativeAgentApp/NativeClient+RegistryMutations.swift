import Foundation
import Observation
import Darwin
import AppKit
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import ProviderRouting
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
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry

// W-H Band (U5 decomposition, move-only): skill/tool/connector/workspace/
// personality mutation routes (updateSkill, deleteSkill, updateTool,
// promoteTool, quarantineTool, runEval, updateConnector, addWorkspace,
// searchWorkspace, savePersonality). Relocated verbatim. Documented lifts:
// adaptCompiledProfile moves with the band (private->internal for its
// routed-helper caller); connectorRowWithRuntimeOverlay, normalizedConnectorID,
// swiftPromoteTool, swiftQuarantineTool stay in the root and are raised to
// internal.
extension NativeClient {
    func updateSkill(id: String, status: String) async throws -> SkillRecord {
        // wave 32 W15: gate to SwiftNativeSkillsClient.updateSkill when .skills
        // is ON. The Swift impl wraps the registry R-M-W in withFileLock and
        // fires the record_activity emission. Decode the returned skill object
        // with the shared native decoder.
        let impl = makeSkillsClient(root: PersistenceCore.defaultDataRoot())
        let result = try await impl.updateSkill(body: .object(["id": .string(id), "status": .string(status)]))
        return try Self.decodeJSONValue(result, as: SkillRecord.self, context: "updateSkill(swiftNative)")
    }

    func deleteSkill(id: String) async throws -> EmptyResponse {
        // wave 32 W15: gate to SwiftNativeSkillsClient.deleteSkill (registry
        // delete + body-file cleanup + manifest fallback + record_activity, all
        // flocked). The daemon route returns `{id, deleted:true[, source]}`;
        // the Mac caller discards the body (EmptyResponse), so we just run the
        // mutation and ignore the returned object.
        let impl = makeSkillsClient(root: PersistenceCore.defaultDataRoot())
        _ = try await impl.deleteSkill(id: id)
        return EmptyResponse()
    }

    func skillVersions(id: String) async throws -> [ExperienceSkillVersion] {
        let impl = makeSkillsClient(root: PersistenceCore.defaultDataRoot())
        return try await impl.listSkillVersions(id: id).compactMap(ExperienceSkillVersion.decode)
    }

    func archiveSkill(id: String) async throws -> SkillRecord {
        let impl = makeSkillsClient(root: PersistenceCore.defaultDataRoot())
        let result = try await impl.archiveSkill(id: id)
        return try Self.decodeJSONValue(result, as: SkillRecord.self, context: "archiveSkill(swiftNative)")
    }

    func restoreSkill(id: String, versionId: String) async throws -> SkillRecord {
        let impl = makeSkillsClient(root: PersistenceCore.defaultDataRoot())
        let result = try await impl.restoreSkill(id: id, versionId: versionId)
        return try Self.decodeJSONValue(result, as: SkillRecord.self, context: "restoreSkill(swiftNative)")
    }

    func updateTool(id: String, autoRun: Bool) async throws -> ToolRecord {
        // DAEMON-DEAD PORT P4: read tools/registry.json under flock, merge
        // {autoRun} into the matching tool by id, write back, return the
        // merged record. Mirrors the daemon's POST /v1/tools/update row patch.
        let root = PersistenceCore.defaultDataRoot()
        let regPath = root.appendingPathComponent("tools/registry.json")
        let core = SwiftNativePersistenceCore()
        return try await core.withFileLock(regPath) {
            let fm = FileManager.default
            try? fm.createDirectory(at: regPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            var rows: [[String: Any]] = []
            if let data = try? Data(contentsOf: regPath),
               let raw = try? JSONSerialization.jsonObject(with: data, options: []) {
                if let arr = raw as? [[String: Any]] {
                    rows = arr
                } else if let dict = raw as? [String: Any], let arr = dict["tools"] as? [[String: Any]] {
                    rows = arr
                }
            }
            guard let idx = rows.firstIndex(where: { ($0["id"] as? String) == id }) else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -404, userInfo: [
                    NSLocalizedDescriptionKey: "updateTool: tool id \(id) not found in \(regPath.path)"
                ])
            }
            rows[idx]["autoRun"] = autoRun
            let out = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
            try out.write(to: regPath, options: .atomic)
            let recordData = try JSONSerialization.data(withJSONObject: rows[idx], options: [])
            return try JSONDecoder().decode(ToolRecord.self, from: recordData)
        }
    }

    func promoteTool(id: String, allowRisky: Bool, userRequested: Bool) async throws -> ToolRecord {
        return try await swiftPromoteTool(id: id, allowRisky: allowRisky)
    }

    func quarantineTool(id: String, reason: String) async throws -> ToolRecord {
        return try await swiftQuarantineTool(id: id, reason: reason)
    }

    func runEval(name: String) async throws -> EvalRun {
        // DAEMON-DEAD PORT (2026-06-03): manual eval runs a bounded Swift-native
        // harness and persists the result to evals/runs.json.
        let started = Date()
        let repoRoot = PersistenceCore.defaultDataRoot().deletingLastPathComponent()
        let smokeScript = repoRoot
            .appendingPathComponent("script", isDirectory: true)
            .appendingPathComponent("smoke_all.sh")
        let checks: [JSONValue] = [
            try await Self.evalProcessCheck(
                id: "swift_build",
                title: "Swift package builds",
                executable: "/usr/bin/swift",
                arguments: ["build"],
                currentDirectory: repoRoot,
                timeout: 180
            ),
            try await Self.evalProcessCheck(
                id: "native_smoke",
                title: "Native smoke sweep passes",
                executable: "/bin/zsh",
                arguments: [smokeScript.path],
                currentDirectory: repoRoot,
                timeout: 240
            ),
        ]
        let passed = checks.allSatisfy { check in
            guard case .object(let obj) = check, case .bool(let ok)? = obj["passed"] else { return false }
            return ok
        }
        let duration = Date().timeIntervalSince(started)
        let row: JSONValue = .object([
            "id": .string("eval-\(UUID().uuidString.lowercased())"),
            "name": .string(name),
            "status": .string(passed ? "passed" : "failed"),
            "checks": .array(checks),
            "createdAt": .string(SwiftNativeManifestSigner.isoTimestamp(started)),
            "durationSeconds": .double(duration),
        ])
        try await Self.appendEvalRun(row)
        let data = try row.serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(EvalRun.self, from: data)
    }

    private static func evalProcessCheck(
        id: String,
        title: String,
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> JSONValue {
        let result = try await runProcess(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            timeout: timeout
        )
        return .object([
            "id": .string(id),
            "title": .string(title),
            "passed": .bool(result.status == 0),
            "detail": .string(processDetail(result)),
        ])
    }

    private static func appendEvalRun(_ row: JSONValue) async throws {
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("evals", isDirectory: true)
            .appendingPathComponent("runs.json")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let raw = await persistence.readJSON(path, defaultValue: .array([]))
            var rows: [JSONValue]
            if case .array(let existing) = raw {
                rows = existing
            } else {
                rows = []
            }
            rows.append(row)
            if rows.count > 200 {
                rows = Array(rows.suffix(200))
            }
            try await persistence.writeJSON(.array(rows), to: path)
        }
    }

    func updateConnector(id: String, enabled: Bool) async throws -> ConnectorRecord {
        try await updateConnector(
            id: id,
            enabled: enabled,
            root: PersistenceCore.defaultDataRoot()
        )
    }

    func updateConnector(
        id: String,
        enabled: Bool,
        root: URL
    ) async throws -> ConnectorRecord {
        // DAEMON-DEAD PORT (2026-06-03): registry.json is canonically an array
        // of connector rows. Preserve that shape and update the matching row
        // under flock; older object-shaped files are still supported.
        let normalizedID = Self.normalizedConnectorID(id)
        guard let currentEntry = try await Self.readConnectorRegistryEntry(
            root: root,
            provider: normalizedID
        ) else {
            throw NSError(domain: "NativeAgentConnectorMutation", code: -404, userInfo: [
                NSLocalizedDescriptionKey: "Connector \(normalizedID) is not registered."
            ])
        }
        let registryToggleOwners: Set<String> = [
            "local_files", "github", "slack", "notion", "gmail", "gcal", "x",
        ]
        guard registryToggleOwners.contains(normalizedID) else {
            throw NSError(domain: "NativeAgentConnectorMutation", code: -409, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(Self.defaultConnectorName(normalizedID)) is controlled by its canonical setup surface."
            ])
        }
        if enabled {
            let runtime = Self.connectorRowWithRuntimeOverlay(currentEntry, root: root)
            let auth = Self.connectorString(runtime["authState"])?.lowercased()
            let health = Self.connectorString(runtime["healthStatus"])?.lowercased()
            let hasVerifiedReadiness = auth == "connected"
                || auth == "configured"
                || health == "ok"
                || normalizedID == "local_files"
            guard hasVerifiedReadiness else {
                throw NSError(domain: "NativeAgentConnectorMutation", code: -409, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Configure and verify \(Self.defaultConnectorName(normalizedID)) before enabling it."
                ])
            }
        }
        let resultEntry = try await Self.mutateConnectorRegistryEntry(
            root: root,
            provider: normalizedID,
            createIfMissing: false
        ) { entry in
            entry["enabled"] = .bool(enabled)
            entry["updatedAt"] = .string(SwiftNativeManifestSigner.isoTimestamp(Date()))
        }
        if normalizedID == "telegram",
           let cfg = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: root) {
            let updated = TelegramBot.TelegramConfig(
                botToken: cfg.botToken,
                allowedChatIds: cfg.allowedChatIds,
                allowedUserIds: cfg.allowedUserIds,
                requireMention: cfg.requireMention,
                enabled: enabled,
                model: cfg.model,
                reasoningEffort: cfg.reasoningEffort
            )
            try TelegramBot.TelegramConfig.saveToDisk(updated, dataRoot: root)
        }
        let overlay = Self.connectorRowWithRuntimeOverlay(resultEntry, root: root)
        let data = try JSONValue.object(overlay).serializedData(pretty: false)
        return try JSONDecoder().decode(ConnectorRecord.self, from: data)
    }

    func addWorkspace(name: String, path: String, permissions: [String]) async throws -> WorkspaceRecord {
        // DAEMON-DEAD PORT P4: append a new row to <dataRoot>/connectors/
        // workspaces.json under flock. Matches the reader path in
        // Connectors.swift L132.
        let root = PersistenceCore.defaultDataRoot()
        let wsPath = root.appendingPathComponent("connectors/workspaces.json")
        let core = SwiftNativePersistenceCore()
        let now = ISO8601DateFormatter().string(from: Date())
        let record = WorkspaceRecord(
            id: UUID().uuidString,
            name: name,
            path: path,
            permissions: permissions,
            createdAt: now,
            lastUsedAt: nil
        )
        return try await core.withFileLock(wsPath) {
            let fm = FileManager.default
            try? fm.createDirectory(at: wsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            var rows: [[String: Any]] = []
            if let data = try? Data(contentsOf: wsPath),
               let arr = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
                rows = arr
            }
            let rowData = try JSONEncoder().encode(record)
            let row = try JSONSerialization.jsonObject(with: rowData, options: []) as? [String: Any] ?? [:]
            rows.append(row)
            let out = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
            try out.write(to: wsPath, options: .atomic)
            return record
        }
    }

    func searchWorkspace(query: String) async throws -> WorkspaceSearchResponse {
        // Subsystem #24 wave 31 (W14): when .connectors is on, run the workspace
        // file search in-process (workspaces.json read + local directory walk +
        // content match), matching Runtime.search_workspaces. The SwiftNative
        // path returns nil for an empty query so the HTTP path produces the
        // daemon's real ValueError; a non-empty query is served natively.
        // wave 32 (W20): the FLIP PREREQ is now CLOSED — the native search path
        // appends the SAME redacted activity row (kind="connector",
        // "Workspace search", payload={resultCount}) the daemon does, with an
        // envelope + secret redaction that are byte-identical modulo the
        // createdAt precision divergence (millis vs micros; see Connectors.swift).
        // .connectors is now a flip CANDIDATE (still default-OFF until cutover).
        let impl = makeConnectorsClient(root: PersistenceCore.defaultDataRoot())
        if let envelope = try await impl.searchWorkspaces(query: query) {
            let data = try envelope.serializedData(pretty: false)
            return try JSONDecoder().decode(WorkspaceSearchResponse.self, from: data)
        }
        // Swift-native cutover sweep s4: native impl declined (empty query / missing
        // index). Surface an empty response instead of throwing so the UI just
        // shows "no results" rather than an error toast.
        return WorkspaceSearchResponse(query: query, results: [])
    }

    func savePersonality(_ profile: PersonalityProfile) async throws -> PersonalityProfile {
        var body: [String: Any] = [
            "name": profile.name,
            "personaKind": profile.personaKind,
            "essence": profile.essence,
            "voice": profile.voice,
            "customDirective": profile.customDirective ?? "",
            "traits": [
                "warmth": profile.traits.warmth,
                "directness": profile.traits.directness,
                "humor": profile.traits.humor,
                "proactivity": profile.traits.proactivity,
                "rigor": profile.traits.rigor,
                "autonomy": profile.traits.autonomy,
                "creativity": profile.traits.creativity,
                "brevity": profile.traits.brevity
            ]
        ]
        if let instincts = profile.instincts {
            body["instincts"] = instincts
        }
        if let boundaries = profile.boundaries {
            body["boundaries"] = boundaries
        }
        if let examples = profile.examples {
            body["examples"] = examples
        }
        if let forbiddenPatterns = profile.forbiddenPatterns {
            body["forbiddenPatterns"] = forbiddenPatterns
        }
        if let surfaceOverrides = profile.surfaceOverrides {
            body["surfaceOverrides"] = surfaceOverrides
        }
        // WAVE 33 W06: write gate. When `.personaEngineWrites` is ON,
        // merge+normalize+atomic-write profile.json through the native
        // `SwiftNativePersonaEngine.savePersonality(body:)` under a cross-process
        // flock, instead of POST /v1/personality. The native merge uses the SAME
        // `dict.update` semantics + `PersonaCompiler.normalize` seed/caps the
        // daemon applies; the on-disk bytes are byte-identical to a daemon write.
        // DEDICATED default-OFF write flag (NOT the live read flag `.personaEngine`)
        // — see savePersonalityDoc above + CUTOVER §6.96 for the pre-flip prereqs.
        // NOTE one such prereq is acute for profile.json: `Runtime.personality()`
        // rewrites profile.json UNLOCKED on every read,
        // so flipping this gate before that writer is flocked would split-write
        // profile.json against the live daemon — named in §6.96.
        let engine = makePersonaEngineWriter()
        let jvBody = try Self.jsonValueBody(body)
        let saved = try await engine.savePersonality(body: jvBody)
        return Self.adaptCompiledProfile(saved)
    }

    /// Convert a `[String: Any]` HTTP-style body to the `[String: JSONValue]`
    /// the native `savePersonality(body:)` consumes. Mirrors the `_swiftDispatch`
    /// JSON round-trip (parse via `JSONValue`), so a body built here normalizes
    /// identically to one decoded off the wire — `merged.update(body)` sees the
    /// same leaf types JSONSerialization would have produced.
    // W-H MCP-band lift (move-only): fileprivate→internal so the relocated
    // MCP live-ops cluster (NativeClient+MCP.swift) still reaches it.
    static func jsonValueBody(_ body: [String: Any]) throws -> [String: JSONValue] {
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        let parsed = try JSONValue.parse(data)
        guard case .object(let obj) = parsed else { return [:] }
        return obj
    }

    /// Map Core `CompiledPersonalityProfile` (the persisted, normalized profile
    /// returned by the native write) to the app-side `PersonalityProfile`.
    /// Field-for-field identical to the `swiftPersonality()` read-path mapping
    /// so the Personality tab sees the same shape on save as on load.
    // W-H lift (move-only): fileprivate->internal for its routed-helper caller.
    static func adaptCompiledProfile(_ compiled: CompiledPersonalityProfile) -> PersonalityProfile {
        PersonalityProfile(
            schemaVersion: compiled.schemaVersion,
            personaEngineVersion: compiled.personaEngineVersion,
            name: compiled.name,
            personaKind: compiled.personaKind,
            essence: compiled.essence,
            voice: compiled.voice,
            customDirective: compiled.customDirective.isEmpty ? nil : compiled.customDirective,
            traits: PersonalityTraits(
                warmth: compiled.traits.warmth,
                directness: compiled.traits.directness,
                humor: compiled.traits.humor,
                proactivity: compiled.traits.proactivity,
                rigor: compiled.traits.rigor,
                autonomy: compiled.traits.autonomy,
                creativity: compiled.traits.creativity,
                brevity: compiled.traits.brevity
            ),
            examples: compiled.examples,
            forbiddenPatterns: compiled.forbiddenPatterns,
            instincts: compiled.instincts,
            boundaries: compiled.boundaries,
            surfaceOverrides: compiled.surfaceOverrides,
            updatedAt: compiled.updatedAt.isEmpty ? nil : compiled.updatedAt
        )
    }
}
