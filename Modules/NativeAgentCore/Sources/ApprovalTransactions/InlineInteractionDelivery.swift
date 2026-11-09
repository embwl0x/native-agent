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
            await InlineInteractionResolver.settleProviderRequests(dataRoot: root)
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
            do {
                // Readiness can complete an unanswered setup only by saving its answer and settling its continuation first.
                if [.connector, .permission, .apiKey, .capability].contains(pair.interaction.kind),
                   pair.interaction.state.isOpen {
                    _ = await InlineInteractionResolver.completeIfVerified(id: pair.interaction.id, sessionID: sessionID,
                        expectedRevision: pair.interaction.revision, checkMail: false, dataRoot: dataRoot)
                }
                // Verification awaits owners and may lose a revision race. File only committed readback, including a competing person's decision.
                let card = try await InlineInteractionResolver.require(id: pair.interaction.id, sessionID: sessionID, dataRoot: dataRoot)
                guard !Task.isCancelled else { return }
                if case .superseded = card.state {
                    try await ForPerson.at(dataRoot).answered("interaction:" + card.id, evidence: nil, letGo: .expired)
                } else {
                    InlineInteractionResolver.reconcileDecision(card, sessionID: sessionID, dataRoot: dataRoot)
                }
                let descriptor = await InlineInteractionResolver.descriptor(for: card, dataRoot: dataRoot)
                let needs = InlineCards.model(card, descriptor: descriptor).needsAttention
                let filed = try await InlineInteractionResolver.fileMatter(card, sessionID: sessionID, dataRoot: dataRoot)
                guard !Task.isCancelled else { return }
                changed = filed == .born || filed == .refreshed || changed
                if needs, case .posted = await ApprovalChatCards.postInteraction(
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
