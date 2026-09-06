import Foundation

enum InboxPushNotifier {
    static func notifyIfAttentionWorthy(
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
        guard shouldNotify(severity: severity) else { return }
        guard usesLiveAppDataRoot(dataRoot) else { return }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard ProcessInfo.processInfo.environment["NATIVE_AGENT_DISABLE_INBOX_PUSH"] != "1" else { return }

        do {
            // Item 26: the routing decision belongs to ONE place. The payload
            // below is unchanged; the router decides whether it reaches User's
            // phone, his Telegram, or nowhere.
            try await AttentionRouter.shared.route(
                eventId: "inbox:\(itemId)",
                importance: importance ?? AttentionImportance.fromInboxSeverity(severity),
                title: NativeAppSecretRedactor.redactText(String(title.prefix(160))),
                body: NativeAppSecretRedactor.redactText(String(summary.prefix(500))),
                reason: "\(severity)|\(summary.prefix(500))",
                userInfo: [
                    "screen": "inbox",
                    "source": source,
                    "itemId": itemId,
                    "severity": severity,
                    // 2026-07-04: everything this notifier sends already passed the
                    // attention-worthy gate (important/actionable/critical), so mark
                    // it time-sensitive — otherwise overnight pushes (e.g. the 3:30am
                    // dream card) are silenced by Sleep Focus and never light the
                    // lock screen. Requires the time-sensitive entitlement iOS-side.
                    "urgency": "urgent"
                ]
            )
        } catch {
            NSLog("[InboxPushNotifier] push failed item=%@ source=%@: %@", itemId, source, error.localizedDescription)
        }
    }

    private static func shouldNotify(severity: String) -> Bool {
        switch severity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "actionable", "important", "critical":
            return true
        default:
            return false
        }
    }

    private static func usesLiveAppDataRoot(_ dataRoot: URL) -> Bool {
        dataRoot.standardizedFileURL.path == NativeAgentPaths.dataRoot.standardizedFileURL.path
    }
}
