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

// W-H Band (U5 decomposition, move-only): tool-dispatch + chat-message ops
// (dispatchTool/dispatchToolData, clearChatMessages, deleteChatMessage,
// cancelChatSession + their helpers). Relocated verbatim. Documented lifts:
// _dispatchMissingNativeHandler and fileSafeTimestamp move here and are
// raised private→internal so their other-file callers still reach them;
// _swiftDispatch stays in the root file and is raised fileprivate→internal.
extension NativeClient {
    func dispatchTool(tool: String, input: [String: Any], sessionId: String?) async throws -> DispatchResult {
        return try await _swiftDispatch(tool: tool, input: input, sessionId: sessionId)
    }

    // PATCH-Phase7b: Sendable-safe variant — caller pre-serializes input to Data on its actor.
    // This avoids passing [String: Any] (non-Sendable) across concurrency boundaries.
    func dispatchToolData(tool: String, inputData: Data, sessionId: String?) async throws -> DispatchResult {
        // Re-parse the pre-serialized input data and wrap it in the full body dict.
        guard let inputObj = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else {
            throw NSError(domain: "NativeAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not deserialize inputData"])
        }
        return try await _swiftDispatch(tool: tool, input: inputObj, sessionId: sessionId)
    }

    // Swift-only failed dispatch envelope when the input cannot be represented
    // as a native object or the file sandbox cannot resolve a validated repo.
    // There is no HTTP retry path.
    // W-H lift (move-only): private->internal for cross-file callers.
    func _dispatchMissingNativeHandler(bodyData: Data) async throws -> DispatchResult {
        let parsed = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
        let toolName = (parsed?["tool"] as? String) ?? ""
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let runId = UUID().uuidString.lowercased()
        NSLog("[NativeClient] dispatch missing native handler for tool=\(toolName)")
        return DispatchResult(
            ok: false,
            tool: toolName,
            status: "failed",
            output: nil,
            error: DispatchResult.DispatchToolError(
                code: "native_handler_missing",
                message: "No Swift-native handler is available for tool '\(toolName)'",
                tool: toolName.isEmpty ? nil : toolName,
                recoverable: false
            ),
            executed: false,
            verifyPassed: nil,
            durationUs: 0,
            durationMs: 0,
            effectiveAutonomy: "",
            autonomySource: "",
            providerMatch: false,
            traceEventId: nil,
            runId: runId,
            startedAt: nowISO
        )
    }

    // PATCH-2026-05-08 / DAEMON-DEAD PORT (2026-06-02): truncate
    // <dataRoot>/chat/messages/<id>.jsonl under flock. Every live writer
    // (ChatOrchestrationClient.appendMessage / persistPartialIfNeeded /
    // SessionHistoryReader / iOS-bridge forward) uses this FLAT path; the
    // earlier nested `chat/sessions/<id>/messages.jsonl` carve was dead.
    // Also remove any stale nested file left over from the earlier shape.
    func clearChatMessages(sessionId: String) async throws -> EmptyResponse {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return EmptyResponse() }
        let root = PersistenceCore.defaultDataRoot()
        let messagesPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(trimmed).jsonl")
        let staleNestedPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(trimmed, isDirectory: true)
            .appendingPathComponent("messages.jsonl")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(messagesPath) {
            let parent = messagesPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data().write(to: messagesPath, options: .atomic)
            if FileManager.default.fileExists(atPath: staleNestedPath.path) {
                try? FileManager.default.removeItem(at: staleNestedPath)
            }
        }
        return EmptyResponse()
    }

    // W-H lift (move-only): private->internal for cross-file callers.
    static func fileSafeTimestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    // PATCH-2026-05-08 / DAEMON-DEAD PORT (2026-06-02): write a cancel marker at
    // <dataRoot>/chat/sessions/<id>/cancelled.flag. The Swift streaming chat
    // path checks this marker to abort an in-flight tool loop.
    func cancelChatSession(sessionId: String) async throws -> EmptyResponse {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { return EmptyResponse() }
        let root = PersistenceCore.defaultDataRoot()
        let flagPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(safeSessionId, isDirectory: true)
            .appendingPathComponent("cancelled.flag")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(flagPath) {
            let parent = flagPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let stamp = SwiftNativeManifestSigner.isoTimestamp(Date())
            try Data(stamp.utf8).write(to: flagPath, options: .atomic)
        }
        return EmptyResponse()
    }

}
