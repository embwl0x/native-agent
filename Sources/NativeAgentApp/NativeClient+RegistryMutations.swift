import Foundation
import AppToolRuntime
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

typealias SkillMutationRecallReconciliationError = AppToolRuntime.SkillMutationRecallReconciliationError

extension NativeClient {
    func updateSkill(id: String, status: String) async throws -> SkillRecord {
        try await Self.updateSkill(
            id: id, status: status, dataRoot: PersistenceCore.defaultDataRoot(), memory: .shared,
            personaRoot: PersonaRootResolver.resolve()
        )
    }

    static func updateSkill(
        id: String, status: String, dataRoot: URL, memory: SwiftNativeMemoryV2, personaRoot: URL
    ) async throws -> SkillRecord {
        let result = try await NativeSkillRegistryActions.updateSkill(id: id, status: status, dataRoot: dataRoot, memory: memory, personaRoot: personaRoot)
        return try Self.decodeJSONValue(result, as: SkillRecord.self, context: "updateSkill(swiftNative)")
    }

    func deleteSkill(id: String) async throws -> EmptyResponse {
        try await Self.deleteSkill(
            id: id, dataRoot: PersistenceCore.defaultDataRoot(), memory: .shared,
            personaRoot: PersonaRootResolver.resolve()
        )
    }

    static func deleteSkill(
        id: String, dataRoot: URL, memory: SwiftNativeMemoryV2, personaRoot: URL
    ) async throws -> EmptyResponse {
        try await NativeSkillRegistryActions.deleteSkill(id: id, dataRoot: dataRoot, memory: memory, personaRoot: personaRoot)
        return EmptyResponse()
    }

    func archiveSkill(id: String) async throws -> SkillRecord {
        try await Self.archiveSkill(
            id: id, dataRoot: PersistenceCore.defaultDataRoot(), memory: .shared,
            personaRoot: PersonaRootResolver.resolve()
        )
    }

    static func archiveSkill(
        id: String, dataRoot: URL, memory: SwiftNativeMemoryV2, personaRoot: URL
    ) async throws -> SkillRecord {
        let result = try await NativeSkillRegistryActions.archiveSkill(id: id, dataRoot: dataRoot, memory: memory, personaRoot: personaRoot)
        return try Self.decodeJSONValue(result, as: SkillRecord.self, context: "archiveSkill(swiftNative)")
    }

    func restoreSkill(id: String, versionId: String) async throws -> SkillRecord {
        try await Self.restoreSkill(
            id: id, versionId: versionId, dataRoot: PersistenceCore.defaultDataRoot(), memory: .shared,
            personaRoot: PersonaRootResolver.resolve()
        )
    }

    static func restoreSkill(
        id: String, versionId: String, dataRoot: URL, memory: SwiftNativeMemoryV2, personaRoot: URL
    ) async throws -> SkillRecord {
        let result = try await NativeSkillRegistryActions.restoreSkill(id: id, versionId: versionId, dataRoot: dataRoot, memory: memory, personaRoot: personaRoot)
        return try Self.decodeJSONValue(result, as: SkillRecord.self, context: "restoreSkill(swiftNative)")
    }

    static func reconcileSkillEvolutionRecall(
        memory: SwiftNativeMemoryV2, dataRoot: URL, personaRoot: URL
    ) async throws {
        try await NativeSkillRegistryActions.reconcileSkillEvolutionRecall(memory: memory, dataRoot: dataRoot, personaRoot: personaRoot)
    }

    func updateTool(id: String, autoRun: Bool) async throws -> ToolRecord {
        // Legacy callers get an explicit refusal: autoRun has no execution consumer.
        return try await Self.updateTool(
            id: id,
            autoRun: autoRun,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    /// Compatibility entry point; the owner refuses the unsupported setting.
    static func updateTool(id: String, autoRun: Bool, dataRoot root: URL) async throws -> ToolRecord {
        try await ToolRegistryActions.updateTool(id: id, autoRun: autoRun, dataRoot: root, validate: ToolsFacade.checkAuthored)
    }

    func promoteTool(id: String, allowRisky: Bool, userRequested: Bool) async throws -> ToolRecord {
        return try await swiftPromoteTool(id: id, allowRisky: allowRisky)
    }

    func quarantineTool(id: String, reason: String) async throws -> ToolRecord {
        return try await swiftQuarantineTool(id: id, reason: reason)
    }

    static func appendBoundedRun(_ row: JSONValue, to path: URL) async throws {
        try await NativeRegistryEvaluation.appendBoundedRun(row, to: path)
    }

    func updateConnector(id: String, enabled: Bool) async throws -> ConnectorRecord {
        try await updateConnector(
            id: id,
            enabled: enabled,
            root: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    func updateConnector(id: String, enabled: Bool, root: URL) async throws -> ConnectorRecord {
        let row = try await ConnectorRegistryActions.updateConnector(
            id: id, enabled: enabled, root: root,
            projection: ConnectorRegistryProjectionPort(
                defaultName: Self.defaultConnectorName,
                overlay: { Self.connectorRowWithRuntimeOverlay($0, root: $1) }
            )
        )
        return try JSONDecoder().decode(ConnectorRecord.self, from: row.serializedData(pretty: false))
    }

    func addWorkspace(name: String, path: String, permissions: [String]) async throws -> WorkspaceRecord {
        try await addWorkspace(
            name: name,
            path: path,
            permissions: permissions,
            root: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    /// The app action's canonical workspace writer. `root` stays injectable so
    /// isolated callers exercise the same flocked store rather than a copy of
    /// the mutation rules.
    func addWorkspace(name: String, path: String, permissions: [String], root: URL) async throws -> WorkspaceRecord {
        try await ConnectorRegistryActions.addWorkspace(name: name, path: path, permissions: permissions, root: root)
    }

    func searchWorkspace(query: String) async throws -> WorkspaceSearchResponse {
        try await searchWorkspace(
            query: query,
            root: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    /// Uses the same in-process workspace search and activity receipt as the
    /// Settings action; the injected root is solely for hermetic callers.
    func searchWorkspace(query: String, root: URL) async throws -> WorkspaceSearchResponse {
        let row = try await ConnectorRegistryActions.searchWorkspace(query: query, root: root)
        return try JSONDecoder().decode(WorkspaceSearchResponse.self, from: row.serializedData(pretty: false))
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

    /// Save only the live display-name field.  The identity editor must not
    /// re-submit an older full profile draft and overwrite concurrent edits to
    /// the rest of profile.json just to rename the agent.
    func savePersonalityName(_ name: String) async throws -> PersonalityProfile {
        let engine: any PersonaEngineWriting = dataRootOverride.map(
            SwiftNativePersonaEngine.isolated(dataRoot:)
        ) ?? makePersonaEngineWriter()
        let saved = try await engine.savePersonality(body: ["name": .string(name)])
        return Self.adaptCompiledProfile(saved)
    }

    /// Convert a `[String: Any]` HTTP-style body to the `[String: JSONValue]`
    /// the native `savePersonality(body:)` consumes. Mirrors the `_swiftDispatch`
    /// JSON round-trip (parse via `JSONValue`), so a body built here normalizes
    /// identically to one decoded off the wire — `merged.update(body)` sees the
    /// same leaf types JSONSerialization would have produced.
    static func jsonValueBody(_ body: [String: Any]) throws -> [String: JSONValue] {
        try NativeActionRouteSupport.jsonValueBody(body)
    }

    /// Map Core `CompiledPersonalityProfile` (the persisted, normalized profile
    /// returned by the native write) to the app-side `PersonalityProfile`.
    /// Field-for-field identical to the `swiftPersonality()` read-path mapping
    /// so the Personality tab sees the same shape on save as on load.
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
