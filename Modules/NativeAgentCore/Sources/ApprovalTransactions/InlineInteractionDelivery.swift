import Foundation
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import ChatToolRuntime
// Blueprint: | `InlineInteractionDelivery.swift` | Transcript-owned asks file one matter with origin doors; inbox pointers read ForPerson |

/// Inbox rows are pointers. The originating transcript still owns the card, its revision, verification and continuation, on every surface.
public enum InlineInteractionDelivery {
    public static let source = "interaction"

    /// Only DeviceSync's authenticated paired-phone action calls this entry. Secrets arrive encrypted; the transcript still owns revision and settlement.
    @MainActor
    public static func answer(payload: [String: String], actionID: String, clientID: String, dataRoot: URL,
        controls: @MainActor () -> (any InlineInteractionControlPort)?
    ) async throws -> [String: String] {
        if payload["action"] == "open", let itemID = payload["itemID"], payload.count == 2 {
            let pointer = try await pointer(id: itemID, dataRoot: dataRoot)
            return ["status": "ok", "ok": "true", "sessionID": pointer.sessionID]
        }
        guard let session = payload["sessionID"], NativeAgentChatSessionID.normalizedPathComponent(session) == session,
              let id = payload["interactionID"], let revision = Int(payload["revision"] ?? ""),
              let action = payload["action"], ["primary", "decline", "verify"].contains(action),
              payload.count <= 12, payload.values.allSatisfy({ $0.utf8.count <= 16_384 }),
              let card = try await InlineInteractionResolver.interaction(id: id, sessionID: session, dataRoot: dataRoot),
              card.revision == revision else {
            throw NSError(domain: "InteractionCard", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "This card changed. Refresh the conversation and try again."])
        }
        if action == "decline" {
            let settled = try await InlineInteractionResolver.decline(id: id, sessionID: session,
                expectedRevision: revision, turn: nil, dataRoot: dataRoot)
            return ["status": "ok", "ok": "true", "state": settled.state.name]
        }
        if action == "verify" {
            let selection = try await InlineInteractionResolver.selectionForReturn(card, dataRoot: dataRoot)
            let checked = !card.state.isRetryable ? card : try await InlineInteractionResolver.begin(
                id: id, sessionID: session, expectedRevision: revision, dataRoot: dataRoot)
            let settled = try await InlineInteractionResolver.complete(id: id, sessionID: session,
                selection: selection, scope: card.kind == .modelChoice ? .persistent : nil,
                expectedRevision: checked.revision, turn: nil, dataRoot: dataRoot)
            return ["status": settled.state.failureReason == nil ? "ok" : "error",
                    "ok": settled.state.failureReason == nil ? "true" : "false", "state": settled.state.name,
                    "message": settled.state.failureReason ?? settled.state.outcome?.summary ?? ""]
        }
        let descriptor = InlineInteractionResolver.descriptor(for: card, dataRoot: dataRoot)
        guard let controls = controls() else {
            throw NSError(domain: "InteractionCard", code: 2, userInfo: [NSLocalizedDescriptionKey: "The Mac's controls are unavailable."])
        }
        switch descriptor.control {
        case .internetAccounts, .chromeSetup, .pairDevice, .trustPostureRequired, .keyring:
            return ["status": "error", "message": "This request needs its Mac setup control. Complete it on the Mac, then tap Check again here."]
        case .unknown, .unavailable:
            return ["status": "error", "message": descriptor.unavailableReason ?? "This build has no control for this card."]
        default: break
        }
        if card.kind == .choose || card.kind == .modelChoice {
            guard let choice = payload["choice"], card.options.contains(where: { $0.id == choice }),
                  choice != InlineInteractionRegistry.persistentChoiceOptionID else {
                return ["status": "error", "message": "Choose one of this card's options."]
            }
        }
        if card.kind == .modelChoice, let scope = payload["scope"], InlineInteraction.Scope(rawValue: scope) == nil {
            return ["status": "error", "message": "Choose this request or the provider group for this model."]
        }
        if descriptor.control == .connectorManualToken, (payload["token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ["status": "error", "message": "Enter the connector token to continue."]
        }
        if descriptor.control == .providerAPIKey, (payload["value"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ["status": "error", "message": "Enter the provider key or setup token to continue. Browser sign-in needs the Mac."]
        }
        let scope = payload["scope"].flatMap(InlineInteraction.Scope.init(rawValue:)) ?? card.primaryScope
        if descriptor.control == .providerGroupModel, let picked = payload["choice"] {
            let settled = try await InlineInteractionResolver.answerModelChoice(card, sessionID: session,
                picked: picked, scope: scope, controls: { controls }, dataRoot: dataRoot)
            return ["status": settled.state.failureReason == nil ? "ok" : "error",
                    "ok": settled.state.failureReason == nil ? "true" : "false", "state": settled.state.name,
                    "message": settled.state.failureReason ?? settled.state.outcome?.summary ?? ""]
        }
        let running = try await InlineInteractionResolver.begin(id: id, sessionID: session,
            expectedRevision: revision, dataRoot: dataRoot)
        let effect = await InlineInteractionResolver.applyControlEffect(card, descriptor: descriptor,
            value: payload["value"], values: payload, controls: controls, dataRoot: dataRoot,
            phone: (actionID, clientID))
        let settled = try await InlineInteractionResolver.complete(id: id, sessionID: session,
            selection: payload["choice"] ?? card.target, scope: card.kind == .modelChoice ? scope : nil,
            expectedRevision: running.revision, setupError: effect.error, note: effect.note, turn: nil, dataRoot: dataRoot)
        return ["status": settled.state.failureReason == nil ? "ok" : "error",
                "ok": settled.state.failureReason == nil ? "true" : "false", "state": settled.state.name,
                "message": settled.state.failureReason ?? settled.state.outcome?.summary ?? ""]
    }

    public struct Pointer: Sendable {
        public let sessionID: String
        public let interactionID: String

        public init(item: InboxItemRecord) throws {
            guard item.source == InlineInteractionDelivery.source, let session = item.interaction_session_id,
                  NativeAgentChatSessionID.normalizedPathComponent(session) == session,
                  let interaction = item.interaction_id else {
                throw NSError(domain: "InteractionCard", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "This request is unavailable. Refresh Activity and try again."
                ])
            }
            sessionID = session
            interactionID = interaction
        }
    }

    public static func pointer(id: String, dataRoot: URL) async throws -> Pointer {
        guard let item = try await ForPerson.at(dataRoot).inbox().first(where: { $0.id == id }) else {
            throw NSError(domain: "InteractionCard", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This request is unavailable. Refresh Activity and try again."
            ])
        }
        return try Pointer(item: item)
    }

    @MainActor
    public static func observe(dataRoot root: URL = PersistenceCore.defaultDataRoot()) async {
        guard !Task.isCancelled else { return }
        // Register before recovery so an arrival racing the initial read is buffered. Notifications carry IDs only, never authority or secrets.
        let (changes, continuation) = AsyncStream<String>.makeStream()
        nonisolated(unsafe) let token = NotificationCenter.default.addObserver(
            forName: InlineInteractionWire.changedNotification, object: nil, queue: nil
        ) { notification in
            if let session = notification.object as? String { continuation.yield(session) }
        }
        continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token) }
        // Recover once after launch, parsing only transcripts with interaction rows to bound launch work.
        let recovery = Task.detached(priority: .utility) {
            let directory = root.appendingPathComponent("chat/messages", isDirectory: true)
            let marker = Data(InlineInteractionWire.transcriptKind.utf8)
            do {
                return try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
                    .filter { url in
                        guard !Task.isCancelled else { return false }
                        // An unreadable one is still handed on, so its read failure is logged.
                        return autoreleasepool {
                            (try? Data(contentsOf: url, options: .alwaysMapped)).map { $0.range(of: marker) != nil } ?? true
                        }
                    }
                    .map { $0.deletingPathExtension().lastPathComponent }
            } catch {
                nativeLog("[interaction-notification] recovery read failed: %@", error.localizedDescription)
                return []
            }
        }
        await withTaskCancellationHandler {
            let sessions = await recovery.value
            for session in sessions {
                guard !Task.isCancelled else { return }
                await refresh(sessionID: session, dataRoot: root, notify: false)
            }
            guard !Task.isCancelled else { return }
            await InlineInteractionResolver.platform.writeInteractionSnapshots()
            for await session in changes {
                guard !Task.isCancelled else { return }
                await refresh(sessionID: session, dataRoot: root, notify: true)
            }
        } onCancel: {
            continuation.finish()
            recovery.cancel()
        }
        await settle {
            continuation.finish()
            recovery.cancel()
            _ = await recovery.value
        }
    }

    @MainActor
    private static func refresh(sessionID: String, dataRoot: URL, notify: Bool) async {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) == sessionID else { return }
        let result = await InlineInteractionResolver.checkedInteractionsByRow(sessionID: sessionID, dataRoot: dataRoot)
        guard !Task.isCancelled, case .success(let pairs) = result, !pairs.isEmpty else { return }
        guard !Task.isCancelled else { return }
        var changed = false
        for pair in pairs {
            guard !Task.isCancelled else { return }
            if case .superseded = pair.interaction.state {
                do { try await ForPerson.at(dataRoot).answered("interaction:" + pair.interaction.id, evidence: nil, letGo: .expired) }
                catch { nativeLog("[interaction-notification] supersession settlement failed: %@", error.localizedDescription) }
            } else {
                InlineInteractionResolver.reconcileDecision(pair.interaction, sessionID: sessionID, dataRoot: dataRoot)
            }
            // The pointer follows the card the person sees: its owner-verified state and the card's own rule.
            let card = await InlineInteractionResolver.liveProjection(pair.interaction, dataRoot: dataRoot)
            let needs = InlineCards.model(card, descriptor: InlineInteractionResolver.descriptor(for: card, dataRoot: dataRoot)).needsAttention
            do {
                guard needs, !card.state.isUnknown else { continue }
                let filed = try await InlineInteractionResolver.fileMatter(card, sessionID: sessionID, dataRoot: dataRoot)
                guard !Task.isCancelled else { return }
                changed = filed == .born || filed == .refreshed || changed
                if case .posted = await ApprovalChatCards.postInteraction(
                    card, sessionID: sessionID, dataRoot: dataRoot) {
                    changed = true
                }
            } catch {
                nativeLog("[interaction-notification] delivery failed: %@", error.localizedDescription)
            }
        }
        guard changed, !Task.isCancelled else { return }
        await InlineInteractionResolver.platform.refreshInteractionInbox()
        if notify, !Task.isCancelled { await InlineInteractionResolver.platform.writeInteractionSnapshots() }
    }

    /// The same signed inbox-action transport the phone already uses. Opening a Mac-owned permission/OAuth control never pretends to grant access.
    @MainActor
    public static func act(id: String, action: String, dataRoot: URL, quiet: Bool = false, turn: Turn?,
        open: @MainActor (Pointer) async throws -> Void
    ) async throws {
        let pointer = try await pointer(id: id, dataRoot: dataRoot)
        if action.hasPrefix("interaction_choice_"),
           let index = Int(action.dropFirst("interaction_choice_".count)),
           let card = try await InlineInteractionResolver.interaction(id: pointer.interactionID,
                sessionID: pointer.sessionID, dataRoot: dataRoot),
           card.kind == .choose, card.options.indices.contains(index) {
            // Quiet inbox actions are agent-initiated; a signed phone tap carries the person's authority.
            _ = try await InlineInteractionResolver.complete(id: card.id, sessionID: pointer.sessionID,
                selection: card.options[index].id, expectedRevision: card.revision, byAgent: quiet, turn: turn, dataRoot: dataRoot)
        } else if action == "reject" || action == "deny" {
            let card = try await InlineInteractionResolver.require(id: pointer.interactionID,
                sessionID: pointer.sessionID, dataRoot: dataRoot)
            // A previous decline may have saved while its inbox disposition failed. Reconcile that disposition without replaying continuation.
            if case .declined = card.state { return }
            _ = try await InlineInteractionResolver.decline(id: card.id, sessionID: pointer.sessionID,
                expectedRevision: card.revision, resume: !quiet, turn: turn, dataRoot: dataRoot)
        } else if action == "act" {
            try await open(pointer)
        } else {
            throw NSError(domain: "InteractionCard", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Use Open on Mac or Not now for this request."
            ])
        }
    }
}
