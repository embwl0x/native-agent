import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+ChatActions.swift` | Chat acts and typed admission receipts; the body owns execution and settlement |

struct AppMutationResult: Equatable, Sendable {
    let succeeded: Bool
    let userMessage: String
    var cause: String?
    var agentMessage: String { cause.map { userMessage + "\n" + $0 } ?? userMessage }
    static func success(_ message: String) -> Self { Self(succeeded: true, userMessage: message) }
    static func failure(_ message: String, cause: String? = nil) -> Self {
        Self(succeeded: false, userMessage: message, cause: cause)
    }
}

@MainActor
extension AppModel {
    enum ChatTurnAcceptance: Equatable {
        case accepted(sessionId: String)
        case rejected(message: String)
    }

    /// A reply is proof of admission; a retained frame is only presentation.
    func chatAct(_ act: FaceAct) async throws -> FaceActReply {
        let reply = try await client.act(act)
        switch reply {
        case .refused(let failure), .failed(let failure): throw failure
        default: return reply
        }
    }

    func chatProtocolFailure(_ expected: String) -> WireFailure {
        WireFailure(code: "chat_reply_mismatch", message: "I did not return " + expected, cause: nil, effects: .unknown)
    }

    @discardableResult
    func performChatMutation(_ act: FaceAct, success: String) async -> AppMutationResult {
        do {
            let reply = try await chatAct(act)
            let issue: WireFailure?
            switch (act, reply) {
            case (_, .committed(let receipt)): issue = receipt.publicationFailure
            case (.remember, .acknowledged), (.commitNote, .acknowledged), (.writeScratch, .acknowledged): issue = nil
            case (.pinConversation, .result(.object(let fields))), (.unpinConversation, .result(.object(let fields))):
                guard case .bool? = fields["changed"] else { throw chatProtocolFailure("the saved pin result.") }
                if fields["shared"] == .bool(false) {
                    issue = WireFailure(code: "pin_publication_failed", message: "The pin was saved, but it could not be shared.",
                                        cause: nil, effects: .known)
                } else { issue = nil }
            default: throw chatProtocolFailure("the completed operation's result.")
            }
            if let failure = issue {
                setFailureStatus(failure, action: success)
                return .failure(failure.message, cause: failure.cause)
            }
            statusText = success
            return .success(success)
        } catch {
            setFailureStatus(error, action: success)
            return .failure(statusText, cause: error.localizedDescription)
        }
    }

    @discardableResult
    func clearActiveChatMessages(sessionId: String? = nil) async -> AppMutationResult {
        await performChatMutation(.clearConversation(session: sessionId ?? activeChatSessionId), success: "Chat messages cleared")
    }

    @discardableResult
    func archiveActiveChat(sessionId: String? = nil) async -> AppMutationResult {
        let session = sessionId ?? activeChatSessionId
        let selection = chatSelectionGeneration
        do {
            guard case .result(.bool(let changed)) = try await chatAct(.archiveConversation(session: session)) else {
                throw chatProtocolFailure("the archived conversation result.")
            }
            if changed, activeChatSessionId == session, chatSelectionGeneration == selection {
                commitChatSessionSelection("")
                await newChatSession()
                guard !activeChatSessionId.isEmpty else { return .failure(statusText) }
            }
            statusText = "Chat archived"
            return .success(statusText)
        } catch {
            setFailureStatus(error, action: "archive this chat")
            return .failure(statusText, cause: error.localizedDescription)
        }
    }

    func regenerateAssistantMessage(message: String, session: String, choice: RetryChoice = .restartConfirmed) async {
        do {
            let reply = try await chatAct(.regenerate(session: session, message: message, choice: choice))
            if choice == .continueFromResults {
                guard try acceptedConversation(reply) == session else { throw chatProtocolFailure("the continued conversation identity.") }
            } else {
                guard case .result(.object(let result)) = reply, result["session"] == .string(session),
                      case .string? = result["turn"] else { throw chatProtocolFailure("the regenerated turn's result.") }
            }
        } catch { setFailureStatus(error, action: "try that again") }
    }

    /// Keep an existing edit while the body reconstructs the rejected input.
    func prepareRejectedTurnDraft(message: String, session: String) async {
        let before = readFaceComposer(session: session)
        do {
            guard case .result(.string(let text)) = try await chatAct(.prepareRetryDraft(session: session, message: message)) else {
                throw chatProtocolFailure("a retry-draft result.")
            }
            guard before.text.isEmpty else {
                throw WireFailure(code: "composer_draft_occupied", message: "The person's existing draft is preserved.", cause: nil, effects: .none)
            }
            let result = editFaceComposer(.init(session: session, text: text, attachments: before.attachments, expectedRevision: before.revision,
                expectedEditedAt: before.editedAt, existingAttachmentIDs: before.attachments.map(\.id)))
            guard result.disposition == .applied else {
                throw WireFailure(code: "composer_changed", message: "The draft changed while the retry was prepared. The draft is preserved.",
                                  cause: nil, effects: .none)
            }
        } catch { setFailureStatus(error, action: "prepare the retry draft") }
    }

    func addMemoryFact(_ text: String) async -> AppMutationResult {
        await performChatMutation(.remember(text: text), success: "Memory saved")
    }

    func addNote(_ text: String) async -> AppMutationResult {
        await performChatMutation(.commitNote(text: text), success: "Note committed")
    }

    func writeScratch(key: String, value: String, sessionId: String? = nil) async -> AppMutationResult {
        await performChatMutation(.writeScratch(session: sessionId ?? activeChatSessionId, key: key, value: value), success: "Scratch note saved")
    }

    func startActiveChatTurn(
        _ text: String, attachments: [FaceAttachment] = [], expectedSessionId: String? = nil, composerRevision: UInt64? = nil
    ) async -> ChatTurnAcceptance {
        await submitChat(text, attachments: attachments, session: activeChatSessionId,
                         expectedSelection: expectedSessionId ?? activeChatSessionId, hideUserBubble: false, composerRevision: composerRevision)
    }

    func startChatTurnForSession(
        _ text: String, attachments: [FaceAttachment] = [], sessionId: String, composerRevision: UInt64? = nil
    ) async -> ChatTurnAcceptance {
        await submitChat(text, attachments: attachments, session: sessionId, expectedSelection: nil, hideUserBubble: false, composerRevision: composerRevision)
    }

    /// The body owns the turn after acceptance, including completion and cross-surface publication.
    private func submitChat(_ text: String, attachments: [FaceAttachment], session: String, expectedSelection: String?,
                            hideUserBubble: Bool, composerRevision: UInt64?) async -> ChatTurnAcceptance {
        let revision = composerRevision ?? composerDraft(for: session).manualEditRevision
        do {
            let request = SendRequest(session: session, text: text, attachments: attachments, composerRevision: revision,
                                      expectedSelection: expectedSelection,
                                      options: FaceSendOptions(hideUserBubble: hideUserBubble, choice: nil, continuationReference: nil))
            let acceptedSession = try acceptedConversation(try await chatAct(.send(request)))
            guard acceptedSession == session, !acceptedSession.isEmpty else {
                throw chatProtocolFailure("a send admission.")
            }
            return .accepted(sessionId: acceptedSession)
        } catch {
            setFailureStatus(error, action: "send your message")
            return .rejected(message: error.localizedDescription)
        }
    }

    /// A committed admission with a publication issue still owns the send; clearing it prevents an accidental repeated effect.
    func acceptedConversation(_ reply: FaceActReply) throws -> String {
        switch reply {
        case .accepted(let session, _, _) where !session.isEmpty: return session
        case .committed(let receipt):
            guard case .object(let fields) = receipt.value, case .string(let session)? = fields["session"],
                  !session.isEmpty, receipt.identities == [session] else { throw chatProtocolFailure("an admitted conversation identity.") }
            if let failure = receipt.publicationFailure { setFailureStatus(failure, action: "share the accepted conversation") }
            return session
        default: throw chatProtocolFailure("an admitted conversation identity.")
        }
    }
}
