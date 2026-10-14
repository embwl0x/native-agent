import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import MemoryV2
import TurnTrace

/// The two Mac chat entry points share their provider-facing tier setting.
/// Core resolves the installation's persona for every door.
public struct NativeChatTurnOptions: Sendable, Equatable {
    public let serviceTier: String?

    public static func resolve(
        fastModeEnabled: Bool,
        surface: String
    ) -> NativeChatTurnOptions {
        return NativeChatTurnOptions(
            serviceTier: surface == "chat" && fastModeEnabled ? "priority" : nil
        )
    }

    /// The picker displays the same normalized value Core compiles.
    public static func normalizedPickerPersona(_ raw: String?, fallback: String = "AI") -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    public static func current(surface: String, defaults: UserDefaults = .standard) -> NativeChatTurnOptions {
        resolve(
            fastModeEnabled: defaults.bool(forKey: "chatFastMode"),
            surface: surface
        )
    }
}

/// Read and publish the existing transcript projection without making the turn
/// runtime depend on the engine's UI row types.
@MainActor
public protocol MacChatTurnTranscriptPort: MacChatTurnPresentationPort {
    associatedtype MacChatMessage: MacChatRenderedMessage & Hashable & Sendable
    var macChatSessionRows: [NativeAgentShared.ChatSession] { get set }
    var macChatMessageRows: [String: [MacChatMessage]] { get set }
    func loadMacChatMessages(sessionId: String, cached: Bool) async throws -> [MacChatMessage]
    func loadMacChatSessions() async throws -> [NativeAgentShared.ChatSession]
    func appendMacChatMessage(_ message: MacChatMessage, to sessionId: String)
}

public extension MacChatTurnTranscriptPort {
    func clearMacChatTranscript(
        sessionId: String,
        clear: (String) async throws -> Void,
        didTruncate: (Error) -> Bool,
        didClear: () -> Void
    ) async throws {
        do {
            try await clear(sessionId)
            didClear()
            let lifecycleBeforeReload = macChatTurns.lifecycle(for: sessionId)
            let messages = try await loadMacChatMessages(sessionId: sessionId, cached: true)
            let lifecycleAfterReload = macChatTurns.lifecycle(for: sessionId)
            if !macChatTurns.streamingSessions.contains(sessionId),
               lifecycleAfterReload == nil || lifecycleAfterReload == lifecycleBeforeReload {
                macChatMessageRows[sessionId] = messages
            }
            macChatSessionRows = try await loadMacChatSessions()
        } catch {
            if didTruncate(error) {
                didClear()
                let lifecycleBeforeReload = macChatTurns.lifecycle(for: sessionId)
                if let actual = try? await loadMacChatMessages(sessionId: sessionId, cached: true) {
                    let lifecycleAfterReload = macChatTurns.lifecycle(for: sessionId)
                    if !macChatTurns.streamingSessions.contains(sessionId),
                       lifecycleAfterReload == nil || lifecycleAfterReload == lifecycleBeforeReload {
                        macChatMessageRows[sessionId] = actual
                    }
                }
            }
            throw error
        }
    }

    func archiveMacChatTranscript(
        sessionId: String,
        archive: (String) async throws -> NativeAgentShared.ChatSession?,
        prunePresentation: (String) -> Void
    ) async throws -> Bool {
        guard try await archive(sessionId) != nil else { return false }
        let runningTask = macChatTurns.tasks[sessionId]
        if runningTask != nil || macChatTurns.streamingSessions.contains(sessionId) {
            stopChatStream(sessionId: sessionId)
        }
        // Do not erase the reservation while its producer commits Stop proof.
        await runningTask?.value
        if runningTask == nil, macChatTurns.activeTurnIDsBySession[sessionId] == nil {
            macChatTurns.taskGenerations[sessionId] = nil
        }
        prunePresentation(sessionId)
        macChatSessionRows.removeAll { $0.id == sessionId }
        return true
    }

    func regenerateMacChatResponse(
        target: MacChatMessage,
        sessionId: String,
        syntheticPrefix: String,
        client: SwiftNativeChatOrchestrationClient,
        serviceTier: @escaping @MainActor () -> String?,
        makeReplacement: @escaping @MainActor (String, String?) -> MacChatMessage,
        presentFailure: @escaping @MainActor (Error) -> Void,
        didComplete: @MainActor () -> Void
    ) async {
        guard !sessionId.isEmpty, knownChatSessionIDs.contains(sessionId) else {
            presentMacChatTurn(.status("Regenerate failed: that chat session is no longer available"))
            return
        }
        let isSyntheticNotice = target.id.hasPrefix(syntheticPrefix)
        guard let retrySnapshot = MacChatRetrySnapshot.capture(
            target: target, messages: macChatMessageRows[sessionId] ?? [],
            sessionId: sessionId, isSyntheticNotice: isSyntheticNotice
        ) else {
            presentMacChatTurn(.status("Regenerate failed: that response is no longer the current retry target"))
            return
        }
        guard !retrySnapshot.inputHadAttachments else {
            presentMacChatTurn(.status("That question is still here, but its attachment isn't - persisted rows keep a summary, not the file. Attach it again with the same question to retry."))
            return
        }
        guard let admission = await admitMacChatRetry(
            sessionId: sessionId,
            matchesCanonical: {
                let messages = try? await self.loadMacChatMessages(sessionId: sessionId, cached: true)
                return messages.map { retrySnapshot.matchesCanonical($0) } == true
            },
            stillMatchesLocal: {
                retrySnapshot.stillMatchesLocal(self.macChatMessageRows[sessionId] ?? [])
            }
        ) else { return }
        let lifecycleIdentity = admission.identity
        await runAdmittedMacChatRetry(admission, operation: { [self] in
            var regeneratedTurnCompleted = false
            do {
                macChatTurns.busySessions.insert(sessionId)
                defer { macChatTurns.busySessions.remove(sessionId) }
                let priorText = retrySnapshot.priorUserText
                let reply = try await TurnTraceContext.$turnId.withValue(lifecycleIdentity.turnId) {
                    try await TurnRequest(message: priorText, sessionID: sessionId, surface: "chat",
                        envelope: .some(nil), verifiedSessionID: .some(nil), verifiedChatID: .some(nil),
                        verifiedUserID: .some(nil), origin: .some(retrySnapshot.priorUserOrigin)).bind {
                        try await TurnRequest(
                            message: priorText, sessionID: sessionId,
                            model: "", reasoningEffort: "", attachments: [], persona: nil, surface: "chat",
                            suppressUserAppend: retrySnapshot.userRowPersisted,
                            replacementAssistantMessageID: isSyntheticNotice ? nil : target.id,
                            serviceTier: serviceTier()
                        ).chat(on: client)
                    }
                }
                try Task.checkCancellation()
                let freshMessages = try? await loadMacChatMessages(sessionId: sessionId, cached: true)
                let settlement = await settleMacChatRetry(identity: lifecycleIdentity)
                // The synthetic notice is the only recovery affordance before
                // a retry writes an exact receipt; never hide it on EOF alone.
                if !isSyntheticNotice || settlement.hasCanonicalReceipt {
                    if let freshMessages, !freshMessages.isEmpty {
                        macChatMessageRows[sessionId] = freshMessages
                    } else {
                        var replacement = macChatMessageRows[sessionId] ?? []
                        replacement.removeAll { $0.id == target.id }
                        replacement.append(makeReplacement(reply.output, reply.runId))
                        macChatMessageRows[sessionId] = replacement
                    }
                }
                switch settlement.state?.presentation.phase {
                case .completed:
                    regeneratedTurnCompleted = true
                    presentMacChatTurn(.status("Regenerated response"))
                case .failed:
                    presentMacChatTurn(.status("Regenerate failed"))
                case .canceled:
                    break
                default:
                    presentMacChatTurn(.status("Regenerate outcome could not be confirmed"))
                }
                macChatSessionRows = (try? await loadMacChatSessions()) ?? macChatSessionRows
            } catch {
                let freshMessages = try? await loadMacChatMessages(sessionId: sessionId, cached: true)
                let settlement = await settleMacChatRetry(identity: lifecycleIdentity, error: error)
                if (!isSyntheticNotice || settlement.hasCanonicalReceipt),
                   let freshMessages, !freshMessages.isEmpty {
                    macChatMessageRows[sessionId] = freshMessages
                }
                if settlement.state?.presentation.phase == .completed {
                    regeneratedTurnCompleted = true
                    presentMacChatTurn(.status("Regenerated response"))
                } else if settlement.state?.presentation.phase == .canceled {
                    // Preserve the quiet Stop behavior.
                } else if settlement.state?.presentation.phase == .outcomeUnknown {
                    presentMacChatTurn(.status("Regenerate outcome could not be confirmed"))
                } else if !Task.isCancelled {
                    presentFailure(error)
                }
            }
            return regeneratedTurnCompleted
        }, didComplete: didComplete)
    }
}

public extension MacChatTurnRuntime {
    nonisolated func storeMacChatMemoryFact(_ text: String) async throws {
        _ = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
            .store(content: text, source: "mac.slash-remember", metadata: nil)
    }

    nonisolated func storeMacChatNote(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentNotes", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "text is required"])
        }
        _ = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).store(
            content: trimmed, source: "mac.note",
            metadata: .object([
                "note_kind": .string("user_note"), "tags": .array([]),
                "confidence": .double(0.8), "importance": .double(0.5),
                "surface": .string("mac"), "command": .string("/note"),
            ])
        )
    }

    nonisolated func writeMacChatScratch(
        key: String, value: String, sessionId: String?
    ) async throws -> (succeeded: Bool, message: String) {
        guard let sessionId, !sessionId.isEmpty else {
            return (false, "Scratch write failed: scratch requires a session")
        }
        guard let safeSid = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return (false, "Scratch write failed: invalid session id for scratch")
        }
        let path = dataRoot.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(safeSid, isDirectory: true)
            .appendingPathComponent("scratch.json")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = try await persistence.readJSON(path, ifMissing: .object([:]))
            var root: [String: JSONValue]
            if case .object(let obj) = current { root = obj } else { root = [:] }
            root[key] = .string(value)
            try await persistence.writeJSON(.object(root), to: path)
        }
        return (true, "Scratch \(key) set")
    }

}
