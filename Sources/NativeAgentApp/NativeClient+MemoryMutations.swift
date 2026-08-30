import Foundation
import Observation
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

// W-H Band (U5 decomposition, move-only): memory-mutation routes
// (updateMemory/deleteMemory/consolidateMemory/addMemory/postNote/
// postScratch + their dispatch-decode helpers), relocated verbatim into a
// same-module extension. Zero visibility lifts required.
extension NativeClient {
    func updateMemory(id: String, pinned: Bool, memory: SwiftNativeMemoryV2? = nil) async throws -> [String: Any] {
        // The canonical patch merges only pinned inside its transaction and
        // joins derived publication. Never replace a stale metadata snapshot.
        let owner = memory ?? SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        do {
            _ = try await owner.updateMemory(id: id, update: .object(["pinned": .bool(pinned)]))
        } catch MemoryV2Error.recordNotFound {
            throw NSError(domain: "NativeAgent", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "memory id not found: \(id)"
            ])
        }
        return ["status": "ok"]
    }

    func deleteMemory(id: String, memory: SwiftNativeMemoryV2? = nil) async throws -> [String: Any] {
        // Foreground completion joins the canonical owner's derived updates;
        // the storage's atomic result preserves missing-row behavior.
        let owner = memory ?? SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        let ok = try await owner.deleteMemoryIfPresent(id: id)
        guard ok else {
            throw NSError(domain: "NativeAgent", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "memory id not found: \(id)"
            ])
        }
        return ["status": "ok"]
    }

    // Fix 9: mutateMemoryStore and removeFromMemoryStore deleted — no callers
    // (verified by grep: only definition sites existed). The MemoryStorage
    // SQLite path (deleteMemory / updateMemory) is the current write surface.

    func consolidateMemory() async throws -> [String: Any] {
        // DAEMON-DEAD PORT (2026-06-03): manual foreground consolidation now
        // runs the same Swift MemoryConsolidator as the background loop.
        return try await triggerMemoryConsolidation(dryRun: false)
    }

    // PATCH-2026-05-08: wave2-chat-ux slash /remember support
    //
    // The resolved canonical owner embeds + inserts through MemoryStorage
    // with the same tombstone gate for both default and alternate roots.
    // The `layer` parameter is preserved on the round-tripped record
    // (Core may omit it; the shared decoder requires it).
    func addMemory(
        text: String,
        layer: String = "semantic",
        source: String = "mac.slash-remember",
        metadata: JSONValue? = nil,
        memory: SwiftNativeMemoryV2? = nil
    ) async throws -> MemoryRecord {
        let owner = memory ?? SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        let core = try await owner.store(
            content: text,
            source: source,
            metadata: metadata
        )
        var obj: [String: JSONValue] = [
            "id": .string(core.id),
            "text": .string(core.text),
            "layer": .string(core.layer ?? layer),
            "createdAt": .string(core.createdAt),
            "importance": .double(core.importance ?? 0),
            "confidence": .double(core.confidence ?? 0),
        ]
        if let v = core.sourceRunId { obj["sourceRunId"] = .string(v) }
        if let v = core.status { obj["status"] = .string(v) }
        if let v = core.pinned { obj["pinned"] = .bool(v) }
        if let v = core.tags { obj["tags"] = .array(v.map { .string($0) }) }
        if let v = core.updatedAt { obj["updatedAt"] = .string(v) }
        let data = try JSONValue.object(obj).serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(MemoryRecord.self, from: data)
    }

    func postNote(
        text: String,
        kind: String = "user_note",
        tags: [String] = [],
        memory: SwiftNativeMemoryV2 = .shared
    ) async throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentNotes", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "text is required"])
        }

        let resolvedKind = kind.isEmpty ? "note" : kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = try await memory.store(
            content: trimmed,
            source: "mac.note",
            metadata: .object([
                "note_kind": .string(resolvedKind),
                "tags": .array(tags.map { .string($0) }),
                "confidence": .double(0.8),
                "importance": .double(0.5),
                "surface": .string("mac"),
                "command": .string("/note"),
            ])
        )
        return ["ok": true, "id": record.id]
    }

    // PATCH-phase-3c: POST /v1/scratch — ephemeral scratchpad write used by /scratch slash command.
    // Dispatches scratchpad_write via Dispatcher.run() — same path as the agent calling the tool directly.
    //
    // WAVE 34 W20 (§6.97) — Dispatcher slash-command seam (retirement-path prereq 5 OPTION-A).
    // Same gating shape as postNote: when `.dispatcher` is ON, route /scratch through
    // Persist per-session scratch directly. A nil session refuses the write so
    // the caller does not accidentally create a throwaway namespace.
    func postScratch(key: String, value: String, sessionId: String? = nil) async throws -> [String: Any] {
        // Swift-native cutover sweep s4: scratch was a daemon in-memory namespace. With
        // the daemon retired, persist the per-session scratch JSON directly to
        // <dataRoot>/chat/sessions/<id>/scratch.json under the shared flock.
        // nil session preserves the daemon's 400-on-no-session refusal.
        guard let sid = sessionId, !sid.isEmpty else {
            return ["ok": false, "error": "scratch requires a session"]
        }
        // FIX 5b (2026-06-10 audit): build the session dir from the NORMALIZED
        // sid — every sibling session-dir writer goes through
        // NativeAgentChatSessionID.normalizedPathComponent; raw sid here wrote
        // scratch.json into a divergent (or unsafe) directory.
        guard let safeSid = NativeAgentChatSessionID.normalizedPathComponent(sid) else {
            return ["ok": false, "error": "invalid session id for scratch"]
        }
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(safeSid, isDirectory: true)
            .appendingPathComponent("scratch.json")
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = await persistence.readJSON(path, defaultValue: .object([:]))
            var root: [String: JSONValue]
            if case .object(let obj) = current { root = obj } else { root = [:] }
            root[key] = .string(value)
            try await persistence.writeJSON(.object(root), to: path)
        }
        return ["ok": true, "key": key, "namespace": safeSid, "full_key": "\(safeSid):\(key)"]
    }

    // PATCH-Phase7b: POST /v1/dispatch — invoke a dispatcher tool from the Mac UI.
    // Convenience overload for callers that already have a [String: Any] dict.
}
