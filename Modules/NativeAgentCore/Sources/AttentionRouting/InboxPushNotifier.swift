import NativeAgentCore
import Privacy
import Foundation
import PersistenceCore
import NativeAgentShared
import NotificationInbox
import ChatTurnRuntime
import ChatTurnContracts
import Transcripts
// Blueprint: | `InboxPushNotifier.swift` | Qualifying background knocks retain a current canonical-card intent before admission; severity and live-root gates preserve eligibility |

extension AttentionRouter {
    public func notifyIfAttentionWorthy(
        dataRoot: URL,
        itemId: String,
        title: String,
        summary: String,
        source: String,
        severity: String,
        /// Optional explicit class. Defaults to the severity mapping so every
        /// existing call site keeps its exact current gate — see
        /// `AttentionImportance.fromInboxSeverity`.
        importance: AttentionImportance? = nil
    ) async {
        let severityImportance = AttentionImportance.fromInboxSeverity(severity)
        guard severityImportance != .routineSuccess else { return }
        guard Self.usesLiveAppDataRoot(dataRoot) else { return }
        guard ProcessInfo.processInfo.environment["NATIVE_AGENT_DISABLE_INBOX_PUSH"] != "1" else { return }

        do {
            let title = String(NativeAppSecretRedactor.redactText(title).prefix(160))
            let body = String(NativeAppSecretRedactor.redactText(summary).prefix(500))
            let reason = "\(severity)|\(body)"
            let info = ["screen": "inbox", "source": source, "itemId": itemId, "severity": severity]
            let ownWork = try SessionConversation.checkedKind(ChatToolSessionContext.verifiedSessionId, dataRoot: dataRoot)?.isOwnWork == true
            let revision = try await LiveNotificationInbox.live(dataRoot: dataRoot).retainAttentionIntent(id: itemId,
                title: title, body: body, reason: reason, importance: (importance ?? severityImportance).rawValue, userInfo: info,
                honorsQuietHours: ownWork || Self.honorsQuietHours(importance ?? severityImportance))
            // The router decides whether this reaches User's phone, Telegram or neither.
            try await route(
                eventId: "inbox:\(itemId)",
                importance: importance ?? severityImportance,
                title: title, body: body, reason: reason, userInfo: info, sourceRevision: revision
            )
        } catch {
            nativeLog("[InboxPushNotifier] push failed item=%@ source=%@: %@", itemId, source, error.localizedDescription)
        }
    }

    private static func usesLiveAppDataRoot(_ dataRoot: URL) -> Bool {
        dataRoot.standardizedFileURL.path == PersistenceCore.defaultDataRoot().standardizedFileURL.path
    }
}
