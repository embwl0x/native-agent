import AppToolRuntime
import ChatToolRuntime
import ChatTurnContracts
import EngineRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import TrustCenter
// Blueprint: | `BodyQuietChatCommands.swift` | Connection-held quiet composer snapshots, CAS edits and canonical session commands |

@MainActor
struct BodyQuietChatCommands {
    let face: BodyFacePresentation
    private var model: AppModel { face.model }

    private func call(_ request: FaceCall) async throws -> FaceReply {
        let reply = try await face.call(request)
        switch reply {
        case .failed(let failure), .refused(let failure): throw failure
        case .cancelled: throw CancellationError()
        default: return reply
        }
    }

    private func act(_ request: FaceAct) async throws -> FaceActReply {
        let reply = try await face.act(request)
        switch reply {
        case .failed(let failure), .refused(let failure): throw failure
        default: return reply
        }
    }

    func scope() async throws -> QuietChatSessionScope {
        guard case .scene(let scene) = try await call(.readScene), scene.connection == face.connection, scene.mounted else {
            throw FaceWireError.invalidFeedOrder
        }
        guard case .detachedSessions(let detached) = try await call(.readDetachedConversations) else {
            throw FaceWireError.invalidFeedOrder
        }
        return .init(selectedSessionID: scene.selectedSession ?? "", detachedSessionIDs: Set(detached))
    }

    private var reportedScope: QuietChatSessionScope {
        .init(selectedSessionID: face.scene?.selectedSession ?? "", detachedSessionIDs: [])
    }

    func composerState(sessionID requested: String, turn: Turn?) async throws -> [String: JSONValue] {
        let scope = try await scope()
        let session: String
        if requested.isEmpty { session = scope.selectedSessionID }
        else {
            switch QuietChatSessionCommands.resolve(requested, appModel: model, turn: turn, scope: scope) {
            case .success(let found): session = found.id
            case .failure(let refusal):
                guard case .object(let fields) = refusal.json else { throw FaceWireError.invalidFeedOrder }
                return fields
            }
        }
        let draft = try await readComposer(session)
        guard case .composerControls(let controls) = try await call(.readComposerControls(turn: nil)) else {
            throw FaceWireError.invalidFeedOrder
        }
        var fields = await model.quietComposerPresentationState(sessionID: session)
        fields["conversation"] = .string(session)
        fields["on_screen"] = .bool(session == scope.selectedSessionID)
        fields["busy"] = .bool(QuietChatSessionCommands.isRunning(session, model))
        fields["attachments"] = .array(draft.attachments.map { .string($0.name) })
        fields["draft"] = .string(draft.text)
        fields["draft_characters"] = .int(Int64(draft.text.count))
        fields["open_card"] = .string(controls.openCard ?? "none")
        fields["pane_rows"] = .array(controls.rows.map(JSONValue.string))
        return fields
    }

    func composerFence(verb: String, value: String, sessionID: String, reachesUser: Bool,
                       turnSessionID: String, turn: Turn) async -> QuietComposerOutcome? {
        let callerTurn = model.macChatTurns.activeTurnIDsBySession[turnSessionID]
        do {
            let scope = try await composerScope(verb: verb, value: value, sessionID: sessionID, reachesUser: reachesUser)
            if let refusal = QuietComposerCommands.fence(verb: verb, value: value, sessionId: sessionID, reachesUser: reachesUser,
                turnSessionId: turnSessionID, appModel: model, turn: turn, scope: scope).refusal { return refusal }
            if verb == "show_pane" {
                guard case .composerControls(let controls) = try await call(.readComposerControls(turn: callerTurn)) else {
                    throw FaceWireError.invalidFeedOrder
                }
                if controls.workPaneClosed {
                    return .refuse("Work pane", "owner_closed_pane", "The person closed the Work pane this turn, so it stays closed.")
                }
            }
            return nil
        } catch { return .refuse(verb, "window_read_failed", error.localizedDescription) }
    }

    private func composerScope(verb: String, value: String, sessionID: String, reachesUser: Bool) async throws -> QuietChatSessionScope {
        if verb == "send", !value.isEmpty, !sessionID.isEmpty { return reportedScope }
        if ["speak", "check_updates"].contains(verb) { return reportedScope }
        if verb == "write_scratch", reachesUser, !sessionID.isEmpty { return reportedScope }
        return try await scope()
    }

    func runComposer(verb: String, value: String, choice: String, sessionID: String, attachments: [URL],
                     reachesUser: Bool, turnSessionID: String, turn: Turn) async -> QuietComposerOutcome {
        let callerTurn = model.macChatTurns.activeTurnIDsBySession[turnSessionID]
        do {
            let scope = try await composerScope(verb: verb, value: value, sessionID: sessionID, reachesUser: reachesUser)
            let fence = QuietComposerCommands.fence(verb: verb, value: value, sessionId: sessionID, reachesUser: reachesUser,
                turnSessionId: turnSessionID, appModel: model, turn: turn, scope: scope)
            if let refusal = fence.refusal { return refusal }
            switch verb {
            case "set_draft", "send":
                return try await editOrSend(verb: verb, value: value, session: fence.session, files: attachments,
                    reachesUser: reachesUser, turnSessionID: turnSessionID, turn: turn)
            case "set_model", "set_think", "set_fast":
                return try await setChoice(verb: verb, value: value, choice: choice, session: scope.selectedSessionID)
            case "set_persona":
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return .refuse("/persona", "missing_persona", "Pass the persona name in value.") }
                let before = model.chatPersona
                guard case .committed(let result) = try await act(.setPreference(key: "chatPersona", value: .string(name))) else {
                    throw FaceWireError.invalidFeedOrder
                }
                if let failure = result.publicationFailure { throw failure }
                guard result.value == .string(name) else { throw FaceWireError.invalidFeedOrder }
                return .done("/persona", "Chat persona is \(name).", changed: before != name)
            default:
                if let presented = await face.composerPresentation(verb: verb, value: value, choice: choice, callerTurn: callerTurn) {
                    return presented
                }
                return await QuietComposerCommands.run(verb: verb, value: value, choice: choice, sessionId: sessionID,
                    attachments: attachments, reachesUser: reachesUser, turnSessionId: turnSessionID,
                    appModel: model, turn: turn, scope: scope)
            }
        } catch { return .refuse(verb, "composer_failed", error.localizedDescription, effects: .unknown) }
    }

    private func readComposer(_ session: String) async throws -> ComposerSnapshot {
        guard case .composer(let snapshot) = try await call(.readComposer(session: session)), snapshot.session == session else {
            throw FaceWireError.invalidFeedOrder
        }
        return snapshot
    }

    private func editOrSend(verb: String, value: String, session: String, files: [URL], reachesUser: Bool,
                            turnSessionID: String, turn: Turn) async throws -> QuietComposerOutcome {
        guard !session.isEmpty else { return .refuse(verb, "no_conversation", "No conversation is open.") }
        let consumesDraft = verb == "set_draft" || value.isEmpty
        let before = consumesDraft ? try await readComposer(session) : nil
        var intake: [MultimodalAttachment] = []
        for url in files {
            let kind = try ChatAttachmentTypeResolver.attachmentKind(url, resolveType: ChatAttachmentTypeResolver.typeAndMime).get()
            intake.append(try await ChatAttachmentTypeResolver.readAttachment(url, kind: kind).get())
        }
        let scope = consumesDraft ? try await scope() : reportedScope
        if let refusal = QuietComposerCommands.fence(verb: verb, value: value, sessionId: session, reachesUser: reachesUser,
            turnSessionId: turnSessionID, appModel: model, turn: turn, scope: scope).refusal { return refusal }
        if verb == "set_draft", let before {
            let submitted = try await Self.faceAttachments(intake)
            let text = value.isEmpty && !submitted.isEmpty ? before.text : value
            let request = ComposerEditRequest(session: session, text: text, attachments: before.attachments + submitted,
                expectedRevision: before.revision, expectedEditedAt: before.editedAt, existingAttachmentIDs: before.attachments.map(\.id))
            guard case .composerEdit(let result) = try await call(.editComposer(request)) else { throw FaceWireError.invalidFeedOrder }
            guard result.disposition == .applied else { return draftChanged() }
            return .done("composer draft", "Draft has \(result.snapshot.text.count) characters and \(result.snapshot.attachments.count) attached files.",
                changed: result.snapshot != before)
        }
        if let before {
            let checked = try await readComposer(session)
            guard checked == before else { return draftChanged() }
        }
        let staged = try await BodyChatCommands.readAttachments(before?.attachments ?? [])
        let message = before?.text ?? value
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(staged + intake).isEmpty else {
            return .refuse("send button", "empty_draft", "Nothing to send: pass text in value, or set_draft first.")
        }
        guard !model.isSavingChatBrain else { return .refuse("send button", "model_saving", "The model change has not landed yet.") }
        if let before {
            guard case .composerEdit(let receipt) = try await call(.editComposer(.init(session: session, text: before.text,
                attachments: before.attachments, expectedRevision: before.revision, expectedEditedAt: before.editedAt,
                existingAttachmentIDs: before.attachments.map(\.id)))) else { throw FaceWireError.invalidFeedOrder }
            guard receipt.disposition == .applied else { return draftChanged() }
        }
        let steer = PeerDataTaint.carried(turn: turn,
            peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: turn.envelope?.surface ?? "chat"), peerID: turn.envelope?.verifiedUserId)
        var origin = QuietChatSessionCommands.agentOrigin
        origin.peerSources = steer.sources
        origin.elevatedPeerSources = steer.elevated
        let model = model
        let all = staged + intake
        let acceptance = await Task.detached { [model, message, all, session, origin, turn] in
            await model.startChatTurn(message, attachments: all, sessionId: session, hideUserBubble: false,
                requireActiveSession: false, origin: origin, parent: turn).acceptance
        }.value
        switch acceptance {
        case .rejected(let detail): return .refuse("send button", "send_rejected", detail)
        case .accepted(let accepted):
            if let before {
                do {
                    guard case .composerEdit(let cleared) = try await call(.clearAcceptedComposer(.init(session: session,
                        text: before.text, revision: before.revision, attachmentIDs: before.attachments.map(\.id)))) else {
                        throw FaceWireError.invalidFeedOrder
                    }
                    if cleared.disposition != .applied {
                        return .done("send button", "Sent into \(accepted). A newer composer edit is preserved.")
                    }
                } catch {
                    return .refuse("send button", "sent_composer_unconfirmed",
                        "Sent into \(accepted), but clearing its accepted draft could not be confirmed: \(error.localizedDescription)", effects: .occurred)
                }
            }
            return .done("send button", "Sent into \(accepted).")
        }
    }

    private func draftChanged() -> QuietComposerOutcome {
        .refuse("composer draft", "draft_changed", "The draft or attached files changed. The person's edit is preserved.")
    }

    @concurrent private static func faceAttachments(_ values: [MultimodalAttachment]) async throws -> [FaceAttachment] {
        try values.map { value in
            guard let bytes = Data(base64Encoded: value.base64), bytes.count == value.byteSize else {
                throw PartCallError(code: "attachment_invalid", message: "The attachment bytes do not match their intake receipt.")
            }
            return FaceAttachment(id: value.id, name: value.name ?? value.type, mimeType: value.mime,
                byteCount: bytes.count, resource: nil, bytes: bytes)
        }
    }
}

extension BodyQuietChatCommands {
    private func setChoice(verb: String, value: String, choice: String, session: String) async throws -> QuietComposerOutcome {
        let presentation = await model.engine.providers.refreshSession(session)
        if let error = presentation.error { throw PartCallError(code: "provider_read_failed", message: error) }
        guard presentation.contract == nil else {
            return .refuse("model card", "bot_conversation", "This conversation uses its helper's model. Change it on the Helpers page.")
        }
        guard case .provider(let read) = try await act(.pageAct(.init(page: "providers", row: session,
            action: "read_chat_choice", value: nil, expectedRevision: nil, expectedCall: nil))),
              let baseline = read.chatChoice, let snapshot = read.snapshot else { throw FaceWireError.invalidFeedOrder }
        let candidate: ProviderTurnChoice
        let edit: ChatChoiceEdit
        switch verb {
        case "set_model":
            guard let group = presentation.controls.providerGroups.first(where: { $0.id == value }),
                  group.models.contains(where: { $0.id == choice }) else {
                return .refuse("model card", "unknown_model", "Choose a provider and model from this conversation's Providers page.")
            }
            candidate = .init(provider: value, model: choice, reasoningEffort: baseline.reasoningEffort, fast: baseline.fast)
            edit = .selection
        case "set_think":
            guard presentation.controls.efforts.contains(where: { $0.id == value }) else {
                return .refuse("think card", "unknown_think_level",
                    "This model's thinking levels are: " + presentation.controls.efforts.map(\.id).joined(separator: ", "))
            }
            candidate = .init(provider: baseline.provider, model: baseline.model, reasoningEffort: value, fast: baseline.fast)
            edit = .reasoning
        default:
            guard let fast = ["on": true, "true": true, "off": false, "false": false][value.lowercased()] else {
                return .refuse("model card", "unknown_value", "Pass on or off in value.")
            }
            guard presentation.controls.supportsFast else { return .refuse("model card", "no_fast", "This model has no Fast mode.") }
            candidate = .init(provider: baseline.provider, model: baseline.model, reasoningEffort: baseline.reasoningEffort, fast: fast)
            edit = .fast
        }
        let write = ChatChoiceWrite(choice: candidate, expectedBaseline: baseline, expectedRevision: snapshot.routing.revision, edit: edit)
        guard case .provider(let saved) = try await act(.saveChatChoice(write)), let landed = saved.chatChoice else {
            throw FaceWireError.invalidFeedOrder
        }
        return .done("model card", "Chat uses \(landed.provider) · \(landed.model), thinking \(landed.reasoningEffort), Fast \(landed.fast ? "on" : "off").",
            changed: landed != baseline)
    }

    private func sessionScope(verb: String, input: [String: JSONValue], reachesUser: Bool, turn: Turn) async throws -> QuietChatSessionScope {
        if ["list", "new"].contains(verb) { return reportedScope }
        let explicit = input["session_id"]?.scalarText?.isEmpty == false
        let resolved = explicit || turn.verifiedSessionID != nil
        if resolved, ["rename", "pin", "unpin", "export"].contains(verb) { return reportedScope }
        if resolved, reachesUser, ["clear", "archive", "stop", "regenerate"].contains(verb) { return reportedScope }
        return try await scope()
    }

    func sessionFence(verb: String, input: [String: JSONValue], reachesUser: Bool, turn: Turn) async -> JSONValue? {
        do {
            let scope = try await sessionScope(verb: verb, input: input, reachesUser: reachesUser, turn: turn)
            if case .failure(let refusal) = QuietChatSessionCommands.fence(verb: verb, input: input, reachesUser: reachesUser,
                appModel: model, turn: turn, scope: scope) { return refusal.json }
            return nil
        } catch { return AppToolExecutor.failure("window_read_failed", error.localizedDescription) }
    }

    func runSession(verb: String, input: [String: JSONValue], reachesUser: Bool, turn: Turn) async -> JSONValue {
        do {
            let scope = try await sessionScope(verb: verb, input: input, reachesUser: reachesUser, turn: turn)
            let resolved = QuietChatSessionCommands.fence(verb: verb, input: input, reachesUser: reachesUser,
                appModel: model, turn: turn, scope: scope)
            if case .failure(let refusal) = resolved { return refusal.json }
            guard ["show", "detach", "close_window"].contains(verb), case .success(let session?) = resolved else {
                return await QuietChatSessionCommands.run(verb: verb, input: input, reachesUser: reachesUser,
                    appModel: model, turn: turn, scope: scope)
            }
            let changed: Bool
            switch verb {
            case "show":
                try await face.present(.openConversation(session: session.id, message: nil))
                let after = try await self.scope()
                guard after.selectedSessionID == session.id else { throw FaceWireError.invalidFeedOrder }
                changed = scope.selectedSessionID != session.id
            case "detach":
                try await face.present(.openDetachedConversation(session: session.id))
                guard case .detachedSessions(let after) = try await call(.readDetachedConversations), after.contains(session.id) else {
                    throw FaceWireError.invalidFeedOrder
                }
                changed = !scope.detachedSessionIDs.contains(session.id)
            default:
                try await face.present(.closeDetachedConversation(session: session.id))
                guard case .detachedSessions(let after) = try await call(.readDetachedConversations), !after.contains(session.id) else {
                    throw FaceWireError.invalidFeedOrder
                }
                changed = scope.detachedSessionIDs.contains(session.id)
            }
            return .object(["status": .string("ok"), "session_id": .string(session.id), "title": .string(session.title),
                "changed": .bool(changed), "detail": .string("The originating window confirmed \(verb) for \(session.title).")])
        } catch { return AppToolExecutor.failure("chat_session_failed", error.localizedDescription, extra: ["effects": .string("unknown")]) }
    }
}
