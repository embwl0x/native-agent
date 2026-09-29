import Foundation
import os
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import TurnTrace
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
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
import DeviceSync

struct AppMutationResult: Equatable, Sendable {
    let succeeded: Bool
    let userMessage: String

    static func success(_ message: String) -> Self {
        Self(succeeded: true, userMessage: message)
    }

    static func failure(_ message: String) -> Self {
        Self(succeeded: false, userMessage: message)
    }
}

@MainActor
extension AppModel {
    func compactActiveChat() async -> AppMutationResult {
        guard !activeChatSessionId.isEmpty else {
            return .failure("No active session to compact")
        }
        do {
            _ = try await client.compactSession(
                sessionId: activeChatSessionId,
                model: chatModel,
                providerID: chatProvider,
                force: true
            )
            chatMessages = (try? await engine.transcripts.loadMessages(sessionId: activeChatSessionId, cached: true)) ?? chatMessages
            statusText = "Session compacted"
            return .success(statusText)
        } catch {
            statusText = "Compact failed: \(error.localizedDescription)"
            return .failure(statusText)
        }
    }

    // PATCH-2026-05-08: wave2-chat-ux slash /clear support
    @MainActor
    @discardableResult
    func clearActiveChatMessages() async -> AppMutationResult {
        await clearActiveChatMessages(
            clear: { [transcripts = engine.transcripts] in try await transcripts.clear(sessionId: $0) },
            loadMessages: { [transcripts = engine.transcripts] in try await transcripts.loadMessages(sessionId: $0, cached: true) },
            loadSessions: { [transcripts = engine.transcripts] in try await transcripts.list() }
        )
    }

    @MainActor
    func clearActiveChatMessages(
        clear: (String) async throws -> Void,
        loadMessages: (String) async throws -> [ChatMessage],
        loadSessions: () async throws -> [ChatSession]
    ) async -> AppMutationResult {
        let clearingSessionID = activeChatSessionId
        guard !clearingSessionID.isEmpty else {
            statusText = "Clear failed: no active chat session"
            return .failure(statusText)
        }
        var transcriptCleared = false
        // 2026-09-06: republication is owed to the phone whenever the DURABLE
        // transcript was cleared, not only when everything after the clear also
        // succeeded. It used to sit on the success path alone, so a failed
        // reload — or the metadata write failing after the bytes were already
        // truncated — left the phone reading the pre-clear
        // chat_transcripts.json forever, which is the bug this whole change is
        // about. The engine's `isActive` guard makes it inert off-device, and
        // the transcript version decides on the phone what the empty may do:
        // when the index write failed the version never advanced, so the empty
        // reaches the phone but is correctly refused authority to clear.
        defer {
            if transcriptCleared {
                NativeAgentEngine.liveDeviceSync.engine.requestChatTranscriptSnapshotPublication()
            }
        }
        do {
            try await clear(clearingSessionID)
            transcriptCleared = true
            // The durable writer completed for this exact id. A user can select
            // another chat while this await is suspended; never clear that
            // newer transcript optimistically. Reload also retains a real new
            // append that landed after the clear instead of hiding it with [].
            let lifecycleBeforeReload = engine.turns.lifecycle(for: clearingSessionID)
            let messages = try await loadMessages(clearingSessionID)
            let lifecycleAfterReload = engine.turns.lifecycle(for: clearingSessionID)
            if !engine.turns.streamingSessions.contains(clearingSessionID),
               lifecycleAfterReload == nil || lifecycleAfterReload == lifecycleBeforeReload {
                engine.transcripts.setMessages(messages, for: clearingSessionID)
            }
            engine.transcripts.sessions = try await loadSessions()
            statusText = "Chat messages cleared"
            // The shared publisher here is sessions-only; the transcript group
            // is republished by the `defer` above.
            publishChatSnapshot()
            return .success(statusText)
        } catch let error as ChatMessageClearError {
            // The durable transcript IS empty in this case — this error is only
            // raised after the bytes were truncated, and names exactly what did
            // not survive it (the index metadata).
            transcriptCleared = true
            let lifecycleBeforeReload = engine.turns.lifecycle(for: clearingSessionID)
            if let actual = try? await loadMessages(clearingSessionID) {
                let lifecycleAfterReload = engine.turns.lifecycle(for: clearingSessionID)
                if !engine.turns.streamingSessions.contains(clearingSessionID),
                   lifecycleAfterReload == nil || lifecycleAfterReload == lifecycleBeforeReload {
                    engine.transcripts.setMessages(actual, for: clearingSessionID)
                }
            }
            statusText = error.localizedDescription
            publishChatSnapshot()
            return .failure(statusText)
        } catch {
            statusText = transcriptCleared
                ? "Messages were cleared, but conversation refresh failed: \(error.localizedDescription)"
                : "Clear failed: \(error.localizedDescription)"
            return .failure(statusText)
        }
    }

    @MainActor
    func regenerateAssistantMessage(_ message: ChatMessage) async {
        if message.metadata?.providerRefusal == true {
            if message.metadata?.providerRefusalDraft == true {
                prepareRejectedTurnDraft(message)
            } else {
                statusText = "outcome unknown — inspect before retry. This rejected turn may have run steps."
            }
            return
        }
        let sessionId = message.sessionId ?? activeChatSessionId
        guard !sessionId.isEmpty,
              engine.transcripts.sessions.contains(where: { $0.id == sessionId }) else {
            statusText = "Regenerate failed: that chat session is no longer available"
            return
        }
        let sessionMessages = engine.transcripts.messages(for: sessionId)
        let isSyntheticNotice = message.id.hasPrefix(Self.syntheticErrorIDPrefix)
        guard let retrySnapshot = MacChatRetrySnapshot.capture(
            target: message,
            messages: sessionMessages,
            sessionId: sessionId,
            isSyntheticNotice: isSyntheticNotice
        ) else {
            statusText = "Regenerate failed: that response is no longer the current retry target"
            return
        }
        guard !retrySnapshot.inputHadAttachments else {
            // Persisted attachment rows intentionally contain summaries, not
            // bytes. Replaying text alone would silently answer a materially
            // different prompt, so ask for an explicit resend instead.
            // Say what is retained and what is missing, so the next move is
            // obvious without diagnosing anything: the question survived, the
            // file's bytes did not.
            statusText = "That question is still here, but its attachment isn't - persisted rows keep a summary, not the file. Attach it again with the same question to retry."
            return
        }
        let priorText = retrySnapshot.priorUserText
        guard let admission = await admitMacChatRetry(
            sessionId: sessionId,
            matchesCanonical: {
                let messages = try? await engine.transcripts.loadMessages(sessionId: sessionId, cached: true)
                return messages.map { retrySnapshot.matchesCanonical($0) } == true
            },
            stillMatchesLocal: {
                retrySnapshot.stillMatchesLocal(engine.transcripts.messages(for: sessionId))
            }
        ) else { return }
        let lifecycleIdentity = admission.identity
        // Sweep R4 C7: synthetic error bubbles are in-memory only — they were
        // never written to chat/messages/<sid>.jsonl. Passing one as the
        // replacement target makes the persistence layer throw ("regenerate
        // replacement target must identify exactly one persisted message"), so
        // now that these bubbles DO render Try again, the retry has to re-send
        // as a fresh turn. The local notice remains until an exact canonical
        // receipt proves that a replacement landed.
        // Whether the FAILED turn persisted the user's row decides the
        // re-send shape: the no-provider guard bails before client.chat, so
        // its bubble carries userRowPersisted=false and the retry must let
        // the fresh turn append the user message — suppressing it there
        // would drop the user's message from the persisted thread entirely
        // (gpt-5.5 review 2026-08-06, blocking). Stream/catch bubbles ran a
        // real turn, which appends the user row before the provider call.
        let suppressUserRow = retrySnapshot.userRowPersisted
        await runAdmittedMacChatRetry(admission, operation: { [self] in
            var regeneratedTurnCompleted = false
            do {
                engine.turns.busySessions.insert(sessionId)
                defer { engine.turns.busySessions.remove(sessionId) }
                let reply = try await TurnTraceContext.$turnId.withValue(lifecycleIdentity.turnId) {
                    try await client.chat(
                        message: priorText,
                        sessionId: sessionId,
                        model: chatModel,
                        reasoningEffort: chatReasoningEffort,
                        fileAccess: chatFileAccess,
                        suppressUserAppend: suppressUserRow,
                        replacementAssistantMessageId: isSyntheticNotice ? nil : message.id
                    )
                }
                try Task.checkCancellation()
                let freshMessages = try? await engine.transcripts.loadMessages(sessionId: sessionId, cached: true)
                let settlement = await settleMacChatRetry(identity: lifecycleIdentity)
                let terminalProof = settlement.proof
                let settled = settlement.state
                let hasCanonicalTerminalReceipt: Bool
                switch terminalProof {
                case .completed, .failed, .canceled:
                    hasCanonicalTerminalReceipt = true
                case .absent, .unavailable:
                    hasCanonicalTerminalReceipt = false
                }
                // A synthetic notice is the only recovery affordance when a
                // retry fails before writing a canonical row. Keep it until an
                // exact receipt proves that a replacement landed.
                if !isSyntheticNotice || hasCanonicalTerminalReceipt {
                    if let freshMessages, !freshMessages.isEmpty {
                        engine.transcripts.setMessages(freshMessages, for: sessionId)
                    } else {
                        var replacement = engine.transcripts.messages(for: sessionId)
                        replacement.removeAll { $0.id == message.id }
                        replacement.append(ChatMessage(
                            sessionId: sessionId,
                            role: "assistant",
                            content: reply.output,
                            runId: reply.runId
                        ))
                        engine.transcripts.setMessages(replacement, for: sessionId)
                    }
                }
                switch settled?.presentation.phase {
                case .completed:
                    regeneratedTurnCompleted = true
                    statusText = "Regenerated response"
                case .failed:
                    statusText = "Regenerate failed"
                case .outcomeUnknown, nil:
                    statusText = "Regenerate outcome could not be confirmed"
                case .canceled:
                    break
                default:
                    statusText = "Regenerate outcome could not be confirmed"
                }
                engine.transcripts.sessions = (try? await engine.transcripts.list()) ?? engine.transcripts.sessions
                setLatestContextReceipt(
                    try? await client.getLatestContextReceipt(sessionId: sessionId),
                    for: sessionId
                )
            } catch {
                let freshMessages = try? await engine.transcripts.loadMessages(sessionId: sessionId, cached: true)
                let settlement = await settleMacChatRetry(identity: lifecycleIdentity, error: error)
                let terminalProof = settlement.proof
                let settled = settlement.state
                let hasCanonicalTerminalReceipt: Bool
                switch terminalProof {
                case .completed, .failed, .canceled:
                    hasCanonicalTerminalReceipt = true
                case .absent, .unavailable:
                    hasCanonicalTerminalReceipt = false
                }
                if (!isSyntheticNotice || hasCanonicalTerminalReceipt),
                   let freshMessages, !freshMessages.isEmpty {
                    engine.transcripts.setMessages(freshMessages, for: sessionId)
                }
                if settled?.presentation.phase == .completed {
                    regeneratedTurnCompleted = true
                    statusText = "Regenerated response"
                } else if settled?.presentation.phase == .canceled {
                    // Preserve the existing quiet Stop behavior.
                } else if settled?.presentation.phase == .outcomeUnknown {
                    statusText = "Regenerate outcome could not be confirmed"
                } else if !Task.isCancelled {
                    statusText = "Regenerate failed: \(error.localizedDescription)"
                }
            }
            return regeneratedTurnCompleted
        }, didComplete: {
            NotificationCenter.default.post(
                name: .chatTurnCompleted,
                object: sessionId,
                userInfo: ["messagesAlreadyRefreshed": true]
            )
        })
    }

    @MainActor
    func prepareRejectedTurnDraft(_ message: ChatMessage) {
        let sessionId = message.sessionId ?? activeChatSessionId
        guard message.metadata?.providerRefusalDraft == true,
              sessionId == activeChatSessionId,
              let snapshot = MacChatRetrySnapshot.capture(
                target: message,
                messages: engine.transcripts.messages(for: sessionId),
                sessionId: sessionId,
                isSyntheticNotice: false
              ) else {
            statusText = "Retry draft unavailable: open the original conversation."
            return
        }
        guard !snapshot.inputHadAttachments else {
            statusText = "Retry draft needs its original attachment; attach it again before sending."
            return
        }
        NotificationCenter.default.post(name: .chatFlushLiveDrafts, object: nil)
        guard chatDraft(for: sessionId).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusText = "The composer already has a draft; clear it before using Retry draft."
            return
        }
        injectChatDraft(snapshot.priorUserText, sessionId: sessionId)
        statusText = "Retry draft ready. Choose another configured model in the chat model picker, then send."
    }

    // PATCH-2026-05-08: wave2-chat-ux slash /remember
    @MainActor
    func addMemoryFact(_ text: String) async -> AppMutationResult {
        do {
            _ = try await client.addMemory(text: text)
            statusText = "Memory saved"
            return .success(statusText)
        } catch {
            statusText = "Remember failed: \(error.localizedDescription)"
            return .failure(statusText)
        }
    }

    // PATCH-Phase1a-dispatcher: /note slash command handler.
    // POSTs to /v1/notes → daemon dispatches commit_memory via Dispatcher.run().
    // Same execution path as the agent calling commit_memory as a tool.
    func addNote(_ text: String) async -> AppMutationResult {
        do {
            _ = try await client.postNote(text: text, kind: "user_note")
            statusText = "Note committed"
            return .success(statusText)
        } catch {
            statusText = "Note failed: \(error.localizedDescription)"
            return .failure(statusText)
        }
    }

    // PATCH-phase-3c: /scratch slash command handler.
    // POSTs to /v1/scratch → daemon dispatches scratchpad_write via Dispatcher.run().
    func writeScratch(key: String, value: String) async -> AppMutationResult {
        do {
            let sessionId = activeChatSessionId.isEmpty ? nil : activeChatSessionId
            let body = try await client.postScratch(key: key, value: value, sessionId: sessionId)
            // FIX 5a (2026-06-10 audit): postScratch reports refusals as
            // {ok:false, error} WITHOUT throwing (no-session, bad sid).
            // Ignoring the body toasted "Scratch set" over a write that never
            // happened.
            guard (body["ok"] as? Bool) == true else {
                let reason = (body["error"] as? String) ?? "scratch write rejected"
                statusText = "Scratch write failed: \(reason)"
                return .failure(statusText)
            }
            statusText = "Scratch \(key) set"
            return .success(statusText)
        } catch {
            statusText = "Scratch write failed: \(error.localizedDescription)"
            return .failure(statusText)
        }
    }

    @MainActor
    @discardableResult
    func archiveActiveChat() async -> AppMutationResult {
        guard !activeChatSessionId.isEmpty else {
            statusText = "Archive failed: no active chat session"
            return .failure(statusText)
        }
        let archivingId = activeChatSessionId
        do {
            guard try await engine.transcripts.archive(id: archivingId) != nil else {
                statusText = "Archive failed: that chat session is no longer available"
                return .failure(statusText)
            }
            // PATCH-2026-05-13: parallel-sessions — cancel any in-flight task
            // for the archived session and clean up per-session state so we
            // don't leak entries in the generation/text dicts.
            let runningTask = engine.turns.tasks[archivingId]
            if engine.turns.tasks[archivingId] != nil || engine.turns.streamingSessions.contains(archivingId) {
                stopChatStream(sessionId: archivingId)
            }
            // Archive must not erase the exact lifecycle reservation while its
            // producer is still committing cancellation evidence.
            await runningTask?.value
            if runningTask == nil,
               engine.turns.activeTurnIDsBySession[archivingId] == nil {
                engine.turns.taskGenerations[archivingId] = nil
            }
            engine.turns.streamingTexts[archivingId] = nil
            engine.turns.streamingBubbleIds[archivingId] = nil
            engine.turns.streamingUserTurnIds[archivingId] = nil
            engine.turns.streamingUserTurnTexts[archivingId] = nil
            // 2026-07-21 audit fix: also drop the archived session's cached
            // messages/receipt/detached-refresh state — pruneSessionChatState
            // covers the queue entries the two inline lines used to clear.
            pruneSessionChatState(archivingId)
            engine.transcripts.sessions.removeAll { $0.id == archivingId }
            // Do not redirect or erase a chat the user selected while the
            // archival write was in flight. Only the originally active chat
            // chooses a replacement and clears its active projection.
            if activeChatSessionId == archivingId {
                chatSelectionGeneration += 1
                activeChatSessionId = ""
                persistActiveChatSessionID(nil)
                if let replacement = engine.transcripts.sessions.first(where: { $0.archived != true }) {
                    await selectChatSession(replacement)
                }
                // 2026-09-06: these two lines used to run through the
                // ACTIVE-session accessors after the line above had already
                // pointed them at the replacement conversation, so archiving
                // one chat blanked the transcript and receipt of the chat it
                // moved you to. The archived session's own copies are already
                // gone — pruneSessionChatState above removes both.
            }
            statusText = "Chat archived"
            publishChatSnapshot()
            return .success(statusText)
        } catch {
            statusText = "Archive failed: \(error.localizedDescription)"
            return .failure(statusText)
        }
    }

    typealias ChatTurnAcceptance = MacChatTurnAcceptance
    typealias _StartedChatTurn = MacChatStartedTurn
    typealias _ChatBodyContext = MacChatTurnBodyContext

    /// Accept a turn for the currently visible chat without waiting for the
    /// model response. The composer uses this transaction boundary so it only
    /// clears its draft and attachments after the task is actually installed.
    @MainActor
    func startActiveChatTurn(
        _ text: String,
        attachments: [MultimodalAttachment] = [],
        expectedSessionId: String? = nil
    ) async -> ChatTurnAcceptance {
        guard let targetSessionId = readyActiveChatSessionId() else {
            return rejectChatTurn(activeChatReadinessFailureMessage())
        }
        if let expectedSessionId,
           expectedSessionId.isEmpty || expectedSessionId != targetSessionId {
            return rejectChatTurn("The active chat changed before send. Your message was not sent.")
        }
        return await startChatTurn(
            text,
            attachments: attachments,
            sessionId: targetSessionId,
            hideUserBubble: false,
            requireActiveSession: true
        ).acceptance
    }

    /// Fixed-session acceptance boundary for detached chat panels. Like the
    /// active composer boundary, this returns as soon as the turn is started
    /// or queued; it does not keep the draft visible until the model finishes.
    @MainActor
    func startChatTurnForSession(
        _ text: String,
        attachments: [MultimodalAttachment] = [],
        sessionId: String
    ) async -> ChatTurnAcceptance {
        await startChatTurn(
            text,
            attachments: attachments,
            sessionId: sessionId,
            hideUserBubble: false,
            requireActiveSession: false
        ).acceptance
    }

    @MainActor
    // PATCH-2026-05-06: multimodal-ui Sprint 3 — sendChat now accepts optional attachments
    // PATCH-2026-05-08: wave2-chat-ux — wraps body in cancellable Task, sets isChatStreaming
    // PATCH-2026-05-13: parallel-sessions — guard and bookkeep per-session
    /// Returns the turn's acceptance so one-shot callers (first-run welcome)
    /// can tell a rejected send from an accepted one; ordinary callers ignore
    /// it. Acceptance means the turn was installed, not that streaming
    /// succeeded — mid-stream failures surface in the transcript, not here.
    @discardableResult
    func sendChat(_ text: String, attachments: [MultimodalAttachment] = [], sessionId: String? = nil, hideUserBubble: Bool = false, requireIdleAndEmpty: Bool = false) async -> ChatTurnAcceptance {
        let started: _StartedChatTurn
        if let sessionId, !sessionId.isEmpty {
            // Fixed-session callers (detached windows, first-run greeting) own
            // their target identity and may legitimately send while another
            // session is active.
            started = await startChatTurn(
                text,
                attachments: attachments,
                sessionId: sessionId,
                hideUserBubble: hideUserBubble,
                requireActiveSession: false,
                requireIdleAndEmpty: requireIdleAndEmpty
            )
        } else {
            guard let targetSessionId = readyActiveChatSessionId() else {
                return rejectChatTurn(activeChatReadinessFailureMessage())
            }
            started = await startChatTurn(
                text,
                attachments: attachments,
                sessionId: targetSessionId,
                hideUserBubble: hideUserBubble,
                requireActiveSession: true,
                requireIdleAndEmpty: requireIdleAndEmpty
            )
        }
        await started.task?.value
        return started.acceptance
    }

    @MainActor
    private func readyActiveChatSessionId() -> String? {
        let sessionId = activeChatSessionId
        guard !sessionId.isEmpty,
              engine.transcripts.sessions.contains(where: { $0.id == sessionId })
        else { return nil }
        return sessionId
    }

    @MainActor
    private func activeChatReadinessFailureMessage() -> String {
        if chatStateLoadInFlight || engine.transcripts.sessions.isEmpty {
            return "Chat is still starting. Your message was not sent."
        }
        return "No active chat session. Your message was not sent."
    }

    @MainActor
    private func rejectChatTurn(_ message: String) -> ChatTurnAcceptance {
        statusText = message
        return .rejected(message: message)
    }

    @MainActor
    func _sendChatBody(
        _ text: String,
        attachments: [MultimodalAttachment] = [],
        sessionId: String? = nil,
        generation: Int,
        ctx: _ChatBodyContext? = nil,
        hideUserBubble: Bool = false,
        activityIdentity: MacChatTurnIdentity
    ) async {
        // PATCH-2026-05-06: hotpath-4 streaming chat — add empty bubble immediately, stream deltas into it
        // PATCH-2026-05-13: parallel-sessions — only mutate `chatMessages`
        // when the active session still matches; otherwise this background
        // task would pollute the view of another session. The user can
        // navigate back and we re-fetch on the success/cancel/error paths.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if activeChatSessionId.isEmpty {
            await loadChatState()
        }
        // H4 follow-up (gpt-5.5 review, 2026-07-09): when the success path below
        // lands a fresh disk snapshot itself, the `.chatTurnCompleted` handler
        // must not read the whole transcript a second time. False whenever the
        // local refresh didn't happen (error path, failed fetch) so the
        // notification path stays the safety net exactly when it's needed.
        var messagesAlreadyRefreshed = false
        // 2026-06-08 detached-chat-windows W0.3 fix HIGH #1: this is `var`
        // (was `let`) so the placeholder-id latch below can rebind it when
        // the daemon returns a confirmed sessionId in metaBox. With dict
        // storage, every subsequent write needs to target the new id —
        // otherwise the active slot (now `sid`) goes empty while final
        // flush + disk refresh write to the dead `requestSessionId` slot.
        var requestSessionId = (sessionId?.isEmpty == false ? sessionId : activeChatSessionId) ?? ""
        let userContent = trimmed.isEmpty ? "(attached \(attachments.count) item(s))" : trimmed
        let bubbleId = UUID().uuidString
        let userTurnId = UUID().uuidString
        // Fresh-install honest surface (G4-6, 2026-07-04): if NO provider is
        // connected at all, don't fire a doomed turn (silent no-reply / provider
        // error). Show the user their message plus a clear "connect a provider"
        // reply. `missingProviderChatGuidance()` is conservative — it only trips
        // on a truly blank machine, never an established one, so User's setup is
        // unaffected. Placed BEFORE the streaming-state `defer` below so the
        // early return doesn't tear down state it never set up.
        if let guidance = missingProviderChatGuidance() {
            var typedBubble = ChatMessage(sessionId: requestSessionId, role: "user", content: userContent)
            typedBubble.id = userTurnId
            appendChatMessage(typedBubble, to: requestSessionId)
            // Tag the guidance with the synthetic-error prefix so the session
            // reload-preservation path keeps it when the user navigates to
            // the Providers tab and back (gpt-5.5 review 2026-07-04).
            let guidanceBubble = ChatMessage(
                id: Self.syntheticErrorIDPrefix + UUID().uuidString,
                sessionId: requestSessionId,
                role: "assistant",
                content: guidance,
                // Sweep R4 C7: without metadata.error the retry gate is false and
                // the bubble renders with no way to re-send once a provider is
                // connected. Stamp it so "Try again" is there when it will work.
                metadata: .syntheticError(
                    "no_provider_connected",
                    userRowPersisted: false,
                    inputHadAttachments: !attachments.isEmpty
                )
            )
            appendChatMessage(guidanceBubble, to: requestSessionId)
            // ...and the control itself, beside the message that needed it.
            // This is the one need with no tool behind it: nothing was
            // dispatched, so nothing could raise it, and the person would
            // otherwise be told to go find a page. The card is written
            // directly; resolving it re-asks THIS question automatically,
            // which is why their own text travels with it.
            //
            // Provider-blind: this condition is "nothing at all is connected",
            // so the card may not name one vendor's key field. It sends the
            // person to Providers — where every account, of every kind, is
            // connected — and coming back re-reads the Chat group's own
            // routing snapshot, which is the shared answer to "can Chat run
            // now", not one provider's.
            let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let raised = await InlineInteractionResolver.raise(
                InlineInteraction(
                    kind: .modelChoice,
                    target: ProviderSurfaceGroups.chat.id,
                    title: "Connect a provider",
                    why: "No AI provider is connected yet, so I can't answer anything.",
                    primaryActionLabel: "Open Providers",
                    declineConsequence:
                        "I can't reply to anything until a provider is connected.",
                    cardProse: "Connect an account in Providers and pick what Chat runs on "
                        + "\u{2014} I'll check when you come back.",
                    primaryScope: .persistent
                ),
                sessionID: requestSessionId,
                // The bytes of an attachment never travel with a resumed turn:
                // the persisted row keeps a summary, not the file. Carrying
                // the text alone would answer a materially different question
                // — "(attached 1 item(s))" with no image — so only a text-only
                // request rides along.
                resumeText: attachments.isEmpty ? userContent : nil,
                // Same rule the Try-again path already applies to an
                // attachment-bearing turn: no silent replay. Connecting a
                // provider still settles this card; the person sends the file
                // again with its question, and it arrives whole. Written
                // non-resumable in the raise itself — the follow-up
                // invalidation was a second write that could fail unnoticed and
                // leave the card resumable.
                resumable: attachments.isEmpty,
                dataRoot: root
            )
            statusText = "No AI provider connected — connect one with Open Providers in the chat."
            _ = await settleChatTurnLifecycle(
                identity: activityIdentity,
                kind: .failed(reason: "No AI provider is connected."),
                at: Date()
            )
            return
        }
        // A bot's session runs on the bot's own model. One saved before that rule
        // (2026-09-13) has no usable tuple, and it must NOT quietly borrow Chat's
        // route: say what is missing, the same thing its card says, and refuse
        // the turn.
        // Gated ONCE, and this exact contract is what the turn runs on
        // (2026-09-13, fourth review). Re-checking below meant a second answer
        // could disagree with the one that was accepted — and a newly refused
        // bot would have fallen through to Chat's routing with choice == nil.
        let acceptedBotContract = await BotChatContract.checked(
            requestSessionId,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        if let contract = acceptedBotContract,
           let problem = contract.modelChoiceProblem {
            var typedBubble = ChatMessage(sessionId: requestSessionId, role: "user", content: userContent)
            typedBubble.id = userTurnId
            appendChatMessage(typedBubble, to: requestSessionId)
            // 2026-09-13 (first-failure pass): name the one repair and say what
            // survives it. This bot's chat cannot be the escape route from its
            // own blocked account, so the sentence points at the bot's card,
            // where that account and model are chosen.
            let guidance = "\(contract.name) can't run yet. \(problem) This bot runs on its own account, never Chat's - choose it on the bot's card in Bots. Nothing was started, and its unfinished work is kept."
            let guidanceBubble = ChatMessage(
                id: Self.syntheticErrorIDPrefix + UUID().uuidString,
                sessionId: requestSessionId,
                role: "assistant",
                content: guidance,
                metadata: .syntheticError(
                    "bot_model_not_chosen",
                    userRowPersisted: false,
                    inputHadAttachments: !attachments.isEmpty
                )
            )
            appendChatMessage(guidanceBubble, to: requestSessionId)
            statusText = "Choose a model for \(contract.name) in Bots."
            _ = await settleChatTurnLifecycle(
                identity: activityIdentity,
                kind: .failed(reason: "This bot has no model chosen."),
                at: Date()
            )
            return
        }
        // Retain only the accepted local request and its preceding conversation
        // row. If routing fails before the core writes the user, an unchanged
        // canonical tail can prove that this request still needs persistence.
        let originalUserBubble = ChatMessage(
            id: userTurnId, sessionId: requestSessionId, role: "user", content: userContent
        )
        let originalRequestPredecessor = engine.transcripts.messages(for: requestSessionId)
            .last(where: { $0.role == "user" || $0.role == "assistant" })

        // PATCH-2026-05-13: parallel-sessions — track the bubble id, the
        // user-turn id, and the live-delta buffer per session so
        // selectChatSession can restore both the prompt and the streaming
        // reply when the user comes back to this session mid-flight.
        engine.turns.streamingBubbleIds[requestSessionId] = bubbleId
        engine.turns.streamingTexts[requestSessionId] = ""
        // Hidden (agent-first) turns must not register user-turn restore state,
        // or a mid-greeting session switch would reinject the hidden kickoff as a
        // user bubble on return.
        if !hideUserBubble {
            engine.turns.streamingUserTurnIds[requestSessionId] = userTurnId
            engine.turns.streamingUserTurnTexts[requestSessionId] = userContent
        }
        // 2026-06-08 detached-chat-windows W0.3: optimistic bubbles now land
        // in the request session's slot unconditionally. When request ==
        // active, the active chat view re-renders (computed `chatMessages`
        // reads the same slot). When request != active, a detached panel
        // bound to this session sees them; the main view does not until the
        // user switches.
        // Proactive agent-first turns (first-run welcome) hide the user bubble:
        // the kickoff drives the LLM but is never shown or persisted (paired with
        // suppressUserAppend below), so only the agent's greeting lands.
        if !hideUserBubble {
            appendChatMessage(originalUserBubble, to: requestSessionId)
        }
        var streamingBubble = ChatMessage(sessionId: requestSessionId, role: "assistant", content: "")
        streamingBubble.id = bubbleId
        appendChatMessage(streamingBubble, to: requestSessionId)
        engine.turns.busySessions.insert(requestSessionId)
        defer {
            engine.turns.busySessions.remove(requestSessionId)
            engine.turns.replyingSessions.remove(requestSessionId)
            engine.turns.streamingTexts[requestSessionId] = nil
            engine.turns.streamingBubbleIds[requestSessionId] = nil
            engine.turns.streamingUserTurnIds[requestSessionId] = nil
            engine.turns.streamingUserTurnTexts[requestSessionId] = nil
        }

        let metaBox = NativeClient.MetaBox()
        do {
            // S.5: use lock-guarded MetaBox for safe cross-isolation metadata passing
            // A bot session continued in Chat keeps the bot's own execution
            // contract — its model, its effort, its surface — instead of
            // inheriting the Chat picker (lane1 finding 4).
            // The accepted contract, not a fresh gate run: a bot session that
            // got past the refusal above carries a usable choice by definition.
            let botContract = acceptedBotContract
            let stream = client.chatStream(
                message: trimmed.isEmpty ? "(see attachments)" : trimmed,
                sessionId: requestSessionId,
                model: botContract?.model ?? chatModel,
                reasoningEffort: botContract?.reasoningEffort ?? chatReasoningEffort,
                fileAccess: chatFileAccess,
                attachments: attachments,
                metaBox: metaBox,
                suppressUserAppend: hideUserBubble,
                surface: botContract?.surface ?? "chat",
                choice: botContract?.choice,
                activityIdentity: activityIdentity,
                onTurnActivity: { [weak self] activity in
                    await self?.receiveChatTurnActivity(activity)
                },
                onScreenPreview: { [weak self] update in
                    await self?.receiveMacScreenPreview(update, identity: activityIdentity)
                },
                // This turn's deltas render in a mounted Mac chat transcript,
                // which draws the card itself — so a turn parked on a card does
                // not restate it in prose here. Nothing else that consumes a
                // core stream may claim this (2026-09-13).
                consumerRendersInlineCards: true
            )
            // Previously only append ran on the accumulator: the for-await
            // loop still resumed MainActor for every token. Publish only a
            // changed frame to the main window and any detached viewers.
            let streamedText = try await consumeMacChatStream(
                stream, sessionId: requestSessionId, bubbleId: bubbleId,
                generation: generation, activityIdentity: activityIdentity
            )
            guard let completion = try await completeMacChatStream(
                metaBox: metaBox, sessionId: requestSessionId,
                generation: generation, streamedText: streamedText
            ) else { return }
            let finalStreamText = completion.text
            // Safety-net: zero deltas streamed AND the final result carries no output —
            // surface explicitly instead of leaving an empty assistant bubble.
            let finalTrimmed = finalStreamText.trimmingCharacters(in: .whitespacesAndNewlines)
            let streamProducedNoContent = finalTrimmed.isEmpty
            // 2026-06-08 W0.3: final flush + bubble cleanup target the
            // request session's slot directly, not just when active.
            if !streamProducedNoContent {
                updateChatMessageContent(id: bubbleId, in: requestSessionId, content: finalStreamText)
            }
            // activeChatSessionId latch — the metadata's confirmed sid may
            // replace a placeholder id on first-turn-of-a-new-session.
            // 2026-06-08 W0.3 fix HIGH #1: with dict storage, flipping
            // activeChatSessionId is not enough — subsequent writes still
            // target the old `requestSessionId` slot, leaving the new
            // active slot empty. Migrate the dict entries to the new key
            // AND update the local `requestSessionId` so the remaining
            // writes (no-content cleanup, disk refresh, error bubble,
            // receipt refresh) hit the right slot.
            //
            // 2026-06-08 W0.3 fix-2 HIGH-B: guard against overwriting a
            // pre-existing `sid` slot. If the daemon reconciled this
            // placeholder turn into an already-loaded real session (rare
            // race: concurrent session creates against the same sourceKey),
            // the real-id slot holds canonical state; blindly overwriting
            // would corrupt the active real session. Instead, DROP the
            // placeholder slot and let the in-flight stream continue
            // writing into the (now-shared) real-id slot. Disk refresh at
            // end-of-turn pulls canonical state for `sid`.
            if let sid = completion.sessionId, !sid.isEmpty, sid != requestSessionId {
                let migratingActive = (activeChatSessionId == requestSessionId)
                let sidAlreadyPopulated = (engine.transcripts.messagesBySession[sid] != nil)
                    || engine.turns.streamingSessions.contains(sid)
                    || engine.turns.tasks[sid] != nil

                if sidAlreadyPopulated {
                    // 2026-06-08 W0.3 fix-3 HIGH: the daemon reconciled this
                    // placeholder turn into an already-loaded/active session
                    // `sid` (rare sourceKey race). `sid`'s real state is
                    // canonical and may be ACTIVELY STREAMING — we must not
                    // migrate into it, rebind to it, or let the outer cleanup
                    // touch its task/generation (generation is per-session,
                    // so removing `chatTaskGenerations[sid]` could abort an
                    // unrelated real stream that happens to share a
                    // generation counter value).
                    //
                    // Correct move: drop ONLY this placeholder's transient
                    // optimistic UI (message/receipt/draft slots). Leave the
                    // placeholder's task/generation/busy/streaming bookkeeping
                    // INTACT and `requestSessionId` UNCHANGED so the OUTER
                    // sendChat cleanup (keyed off the unchanged placeholder
                    // via `ctx.effectiveSessionId`, which we do NOT advance to
                    // `sid`) and this function's `defer` tear them down
                    // exactly once — all against the placeholder, never
                    // against `sid`. Then bail: the turn already landed on
                    // disk under `sid`; sid's own refresh path / next
                    // selectChatSession surfaces it.
                    engine.transcripts.messagesBySession.removeValue(forKey: requestSessionId)
                    latestContextReceiptBySession.removeValue(forKey: requestSessionId)
                    chatDrafts.removeValue(forKey: requestSessionId)
                    chatDraftLastEdited.removeValue(forKey: requestSessionId)
                    _ = await settleChatTurnLifecycle(
                        identity: MacChatTurnIdentity(
                            sessionId: requestSessionId,
                            turnId: activityIdentity.turnId
                        ),
                        kind: .outcomeUnknown(
                            reason: "I'm not sure that finished \u{2014} if my answer isn't here, say it again and I'll pick it up."
                        ),
                        at: Date()
                    )
                    // ctx.effectiveSessionId stays at the placeholder (initial
                    // value) — outer cleanup tears down placeholder bookkeeping.
                    // requestSessionId stays at the placeholder — defer clears
                    // placeholder streaming buffers. Neither touches `sid`.
                    return
                } else {
                    // Normal placeholder migration. Move every per-session
                    // stash from the placeholder id to the confirmed `sid`.
                    if let placeholderMessages = engine.transcripts.messagesBySession.removeValue(forKey: requestSessionId) {
                        engine.transcripts.messagesBySession[sid] = placeholderMessages
                    }
                    if let placeholderReceipt = latestContextReceiptBySession.removeValue(forKey: requestSessionId) {
                        latestContextReceiptBySession[sid] = placeholderReceipt
                    }
                    if let v = engine.turns.streamingTexts.removeValue(forKey: requestSessionId) {
                        engine.turns.streamingTexts[sid] = v
                    }
                    if let v = engine.turns.streamingBubbleIds.removeValue(forKey: requestSessionId) {
                        engine.turns.streamingBubbleIds[sid] = v
                    }
                    if let v = engine.turns.streamingUserTurnIds.removeValue(forKey: requestSessionId) {
                        engine.turns.streamingUserTurnIds[sid] = v
                    }
                    if let v = engine.turns.streamingUserTurnTexts.removeValue(forKey: requestSessionId) {
                        engine.turns.streamingUserTurnTexts[sid] = v
                    }
                    if let v = chatDrafts.removeValue(forKey: requestSessionId) {
                        chatDrafts[sid] = v
                        // 2026-07-21 audit fix: carry the LRU timestamp too —
                        // without it the migrated draft is invisible to the
                        // 50-cap eviction ordering. Fall back to now only when
                        // the placeholder never recorded a touch.
                        chatDraftLastTouched[sid] = chatDraftLastTouched.removeValue(forKey: requestSessionId) ?? Date()
                    }
                    // 2026-09-06: carry the edit stamp with the draft. No
                    // fallback — inventing "now" here would outrank a live
                    // composer's older-but-real typing and drop it.
                    if let editedAt = chatDraftLastEdited.removeValue(forKey: requestSessionId) {
                        chatDraftLastEdited[sid] = editedAt
                    }
                    await migrateMacChatTurnRuntime(
                        from: requestSessionId, to: sid, turnId: activityIdentity.turnId
                    )
                }

                if migratingActive {
                    activeChatSessionId = sid
                    UserDefaults.standard.set(activeChatSessionId, forKey: "activeChatSessionId")
                }
                // Re-bind the local so every subsequent write in this
                // function targets the new slot. ALSO report the effective
                // session id back to `sendChat` so its outer cleanup
                // targets the post-migration key (chatTasks, generation,
                // streamingSessions, busySessions all live under `sid`
                // now). Without this, those entries leak forever and
                // block future sends on this session.
                requestSessionId = sid
                ctx?.effectiveSessionId = sid
            }
            // After streaming, refresh messages to pick up any tool pills written by daemon.
            // When the stream produced no content, drop the optimistic empty bubble FIRST so
            // the no-content check below doesn't see it and mistake it for an assistant reply.
            // 2026-06-08 W0.3 fix HIGH #3: also clear the per-session
            // streaming bubble + user-turn ids BEFORE the disk-refresh
            // await below. Without this, a concurrent selectChatSession
            // during the await can re-inject the empty optimistic bubble
            // via the streamingSessions/streamingBubbleIds reinjection
            // block (lines ~1490-1505), and the subsequent assistantLanded
            // check would see the re-injected empty bubble and silently
            // suppress the error message. Mirrors the old inactive-path
            // clearStreamingBubbleState() call now folded into the unified
            // path.
            if streamProducedNoContent {
                removeChatMessage(id: bubbleId, from: requestSessionId)
                engine.turns.clearStreamingBubbleState(requestSessionId)
            }
            // 2026-06-08 W0.3: disk refresh now runs for EVERY session that
            // completes a turn, not just the active one. Tool pills + final
            // assistant content land in `engine.transcripts.messagesBySession[req]` so a
            // detached panel for `req` sees them immediately.
            let freshOnSuccess: [ChatMessage]? = try? await engine.transcripts.loadMessages(sessionId: requestSessionId, cached: true)
            if let fresh = freshOnSuccess, !fresh.isEmpty {
                engine.transcripts.setMessages(fresh, for: requestSessionId)
                messagesAlreadyRefreshed = true
            }
            let terminalIdentity = MacChatTurnIdentity(
                sessionId: requestSessionId,
                turnId: activityIdentity.turnId
            )
            let settlement = await settleMacChatStream(
                identity: terminalIdentity, metaBox: metaBox, exit: .exhausted
            )
            let terminalProof = settlement.proof
            let settled = settlement.state
            if settled?.presentation.phase == .canceled { return }
            // Safety-net: if the stream produced no content AND no assistant turn landed on
            // disk for this run, append (or stash) a visible error bubble so the failure
            // isn't silent. Inverted check from "last is user" to "last is NOT assistant" so
            // a failed refresh (freshOnSuccess == nil) still surfaces the error instead of
            // leaving the cleared bubble + persisted user turn looking like a stall.
            if streamProducedNoContent {
                // Friendly, honest wording on the no-content path too (this
                // string does NOT pass through normalizeStreamErrorForChat).
                // audit finding #17, 2026-06-14.
                let errorText = "No reply came back. Use Try again to retry."
                let assistantLanded: Bool
                switch terminalProof {
                case .completed, .failed:
                    assistantLanded = true
                case .canceled, .absent, .unavailable:
                    assistantLanded = false
                }
                if !assistantLanded {
                    let errorBubble = ChatMessage(
                        id: Self.syntheticErrorIDPrefix + UUID().uuidString,
                        sessionId: requestSessionId,
                        role: "assistant",
                        content: errorText,
                        // Sweep R4 C7: this is THE bubble whose text says "Use
                        // Try again to retry" — messageNeedsRetry requires
                        // metadata.error, so without this stamp the copy named
                        // an affordance that never rendered.
                        metadata: .syntheticError(
                            "stream_produced_no_content",
                            inputHadAttachments: !attachments.isEmpty
                        )
                    )
                    appendChatMessage(errorBubble, to: requestSessionId)
                }
            }
            engine.transcripts.sessions = (try? await engine.transcripts.list()) ?? engine.transcripts.sessions
            // 2026-06-08 W0.3: receipt refresh runs for the request session
            // regardless of active state, so a detached panel for `req` sees
            // the new context-receipt without waiting for a focus change.
            setLatestContextReceipt(
                try? await client.getLatestContextReceipt(sessionId: requestSessionId),
                for: requestSessionId
            )
            compiledPersonality = try? await client.getCompiledPersonality(surface: "chat")
        } catch {
            guard await joinFailedMacChatStream(
                metaBox: metaBox, sessionId: requestSessionId, generation: generation
            ) else { return }
            if Task.isCancelled {
                // 2026-06-08 W0.3: cancel-cleanup targets the request session
                // regardless of active state — a detached panel that was
                // streaming should also see its empty bubble disappear and
                // any partial tool pills land when the user stops the stream.
                removeChatMessage(id: bubbleId, from: requestSessionId)
                let freshMessages = try? await engine.transcripts.loadMessages(sessionId: requestSessionId, cached: true)
                if let freshMessages, !freshMessages.isEmpty {
                    engine.transcripts.setMessages(freshMessages, for: requestSessionId)
                }
                let terminalIdentity = MacChatTurnIdentity(
                    sessionId: requestSessionId,
                    turnId: activityIdentity.turnId
                )
                _ = await settleMacChatStream(
                    identity: terminalIdentity, metaBox: metaBox, exit: .consumerCancelled
                )
                return
            }
            // Streaming failed after the Swift chat path may already have
            // appended the user turn. Do not submit a second chat request here;
            // that can duplicate the user message and run the request twice.
            // 2026-06-08 W0.3: optimistic-bubble cleanup targets the request
            // session's slot directly. Same UX for active viewer; detached
            // panels for this session also see the empty bubble disappear.
            removeChatMessage(id: bubbleId, from: requestSessionId)
            // The streaming LLM call failed AFTER the user turn was persisted (the Swift
            // chat path appends the user message BEFORE calling the LLM). A bare refresh
            // therefore shows the user bubble with NO assistant reply and no error —
            // looks identical to a stalled response. Surface the error explicitly when
            // no assistant turn landed; mirror the success-path pattern (invert from
            // "last is user" to "last is NOT assistant") so a failed refresh still fires.
            let isRefusal = ProviderFailure.classify(error) == .refused
            let errorText = normalizeStreamErrorForChat(error)
                + (isRefusal ? " outcome unknown — inspect before retry." : "")
            let freshOnError: [ChatMessage]? = try? await engine.transcripts.loadMessages(sessionId: requestSessionId, cached: true)
            if let fresh = freshOnError, !fresh.isEmpty {
                engine.transcripts.setMessages(fresh, for: requestSessionId)
            }
            let terminalIdentity = MacChatTurnIdentity(
                sessionId: requestSessionId,
                turnId: activityIdentity.turnId
            )
            let settlement = await settleMacChatStream(
                identity: terminalIdentity, metaBox: metaBox,
                exit: .failed(cancellationShaped: error is CancellationError)
            )
            let terminalProof = settlement.proof
            let settled = settlement.state
            let errorSignal = settlement.signal
            // Marker-only cancellation (for example Status chrome) may not
            // cancel this AppModel task. The typed core receipt still owns the
            // truth; do not turn it into a retry bubble or completion notice.
            if settled?.presentation.phase == .canceled { return }

            // A remote/marker-only Stop that never cancelled this task reaches
            // here as an ambiguous terminal with no canonical receipt (nothing
            // streamed, so no partial row was written). Its raw transport text
            // is literally "cancelled" — surfacing that verbatim would read as
            // a provider crash for what the user deliberately stopped from
            // another device. We still refuse to CLAIM a cancel we cannot
            // prove, so say exactly what is true: the outcome is unconfirmed.
            if errorSignal == .ambiguousTermination,
               settled?.presentation.phase == .outcomeUnknown {
                removeChatMessage(id: bubbleId, from: requestSessionId)
                statusText = "Turn stopped; its outcome could not be confirmed"
                return
            }

            // Only an exact current-turn receipt can suppress the current
            // failure bubble. An older completed assistant at the transcript
            // tail is unrelated evidence and must never make this turn vanish.
            let assistantLandedErr: Bool
            switch terminalProof {
            case .completed, .failed:
                assistantLandedErr = true
            case .canceled, .absent, .unavailable:
                assistantLandedErr = false
            }
            if !assistantLandedErr {
                // Carry sessionId (mirrors the no-content bubble above) so the
                // row is correctly attributed to its session for any code that
                // keys off msg.sessionId (e.g. detached-panel regeneration).
                // Sweep R4 C7: stamp metadata.error (the raw, un-normalized
                // failure) so the normalized bubble text — which ends in "Use
                // Try again to retry" on every arm — actually renders the
                // Try again button.
                var failureMetadata = ChatMessageMetadata.syntheticError(
                    error.localizedDescription,
                    inputHadAttachments: !attachments.isEmpty
                )
                if isRefusal { failureMetadata.providerRefusal = true }
                let errorBubble = ChatMessage(
                    id: Self.syntheticErrorIDPrefix + UUID().uuidString,
                    sessionId: requestSessionId,
                    role: "assistant",
                    content: errorText,
                    metadata: failureMetadata
                )
                if !hideUserBubble, let freshOnError,
                   let restored = Self.restoredUnpersistedChatRequest(
                    originalUser: originalUserBubble,
                    predecessor: originalRequestPredecessor,
                    notice: errorBubble,
                    canonicalMessages: freshOnError
                   ) {
                    engine.transcripts.setMessages(restored, for: requestSessionId)
                } else {
                    appendChatMessage(errorBubble, to: requestSessionId)
                }
            }
            engine.transcripts.sessions = (try? await engine.transcripts.list()) ?? engine.transcripts.sessions
        }
        // PATCH-2026-05-07: chat-context-fill notify the ContextFillBar so
        // it re-polls usage after each turn.
        NotificationCenter.default.post(
            name: .chatTurnCompleted, object: requestSessionId,
            userInfo: ["messagesAlreadyRefreshed": messagesAlreadyRefreshed])
    }

    /// Synthetic (in-memory-only) error/no-content bubbles use this id prefix so
    /// the post-turn disk reload (performLoadChatState) can PRESERVE them instead
    /// of wiping them — these notices are never persisted (audit #2 durability
    /// fix Z, 2026-06-14). Without this they flash for one frame then vanish on
    /// the async `.chatTurnCompleted` reload.
    static let syntheticErrorIDPrefix = "na-synthetic-error-"

    /// Restore a failed request only when canonical IDs prove that its user row
    /// was never appended. A prior unanswered user is not this request, even if
    /// its text is identical. Unknown/advanced snapshots keep the existing path.
    static func restoredUnpersistedChatRequest(
        originalUser: ChatMessage,
        predecessor: ChatMessage?,
        notice: ChatMessage,
        canonicalMessages: [ChatMessage]
    ) -> [ChatMessage]? {
        guard let sessionID = originalUser.sessionId, !sessionID.isEmpty,
              notice.sessionId == sessionID,
              originalUser.role == "user",
              notice.id.hasPrefix(syntheticErrorIDPrefix),
              notice.metadata != nil else { return nil }
        var unpersistedNotice = notice
        unpersistedNotice.metadata?.syntheticUserRowPersisted = false
        let local = [predecessor].compactMap { $0 } + [originalUser, unpersistedNotice]
        guard let snapshot = MacChatRetrySnapshot.capture(
            target: unpersistedNotice, messages: local, sessionId: sessionID, isSyntheticNotice: true
        ), snapshot.matchesCanonical(canonicalMessages) else { return nil }
        return canonicalMessages + [originalUser, unpersistedNotice]
    }

    /// A persisted assistant row counts as a real, completed reply only if it is
    /// NOT a partial/cancelled truncation. persistPartialIfNeeded
    /// (NativeAgentCore) stamps metadata.partial/cancelled on mid-stream
    /// failures; treating those as "landed" suppresses the failure bubble
    /// (audit finding #2, 2026-06-14).
    func isCompletedAssistant(_ m: ChatMessage?) -> Bool {
        guard let m, m.role == "assistant" else { return false }
        if m.metadata?.partial == true { return false }
        if m.metadata?.cancelled == true { return false }
        return true
    }

    /// Maps a streaming failure to a clean, user-facing chat-bubble sentence.
    /// Runs ONLY at this UI catch site (line ~2343) — engine/orchestration-layer
    /// `.error` events still carry the raw provider text (ChatErrorSurfacingTests
    /// assert on that raw text). Keep the raw error in any os_log/telemetry on
    /// this path; only the bubble text is normalized.
    ///
    /// A typed provider failure speaks its own person sentence (2026-09-22: its
    /// localizedDescription ended " Work: …" in the bubble). Anything else:
    /// (1) the ProviderStreamGuard's stable timeout strings; (2) URLError
    /// categories / transport strings; (3) default "Chat error: <desc>".
    private func normalizeStreamErrorForChat(_ error: Error) -> String {
        ProviderRecoveryPolicy.personMessage(error)
            ?? ChatStreamErrorText.normalize(error.localizedDescription)
    }
}
