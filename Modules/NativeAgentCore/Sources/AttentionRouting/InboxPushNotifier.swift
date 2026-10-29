import NativeAgentCore
import Privacy
import Foundation
import PersistenceCore
import NativeAgentShared
// Blueprint: | `InboxPushNotifier.swift` | `AttentionRouter.notifyIfAttentionWorthy`: severity and live-root notification routing |

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
            // The router decides whether this reaches User's phone, Telegram or neither.
            try await route(
                eventId: "inbox:\(itemId)",
                importance: importance ?? severityImportance,
                title: String(NativeAppSecretRedactor.redactText(title).prefix(160)),
                body: String(NativeAppSecretRedactor.redactText(summary).prefix(500)),
                reason: "\(severity)|\(summary.prefix(500))",
                userInfo: [
                    "screen": "inbox",
                    "source": source,
                    "itemId": itemId,
                    "severity": severity,
                    // AttentionRouter.wakesTheDevice owns urgency, separately from eligibility.
                ]
            )
        } catch {
            nativeLog("[InboxPushNotifier] push failed item=%@ source=%@: %@", itemId, source, error.localizedDescription)
        }
    }

    private static func usesLiveAppDataRoot(_ dataRoot: URL) -> Bool {
        dataRoot.standardizedFileURL.path == PersistenceCore.defaultDataRoot().standardizedFileURL.path
    }
}
