import Foundation

enum InboxPushNotifier {
    static func notifyIfAttentionWorthy(
        dataRoot: URL,
        itemId: String,
        title: String,
        summary: String,
        source: String,
        severity: String
    ) async {
        guard shouldNotify(severity: severity) else { return }
        guard usesLiveAppDataRoot(dataRoot) else { return }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard ProcessInfo.processInfo.environment["NATIVE_AGENT_DISABLE_INBOX_PUSH"] != "1" else { return }

        do {
            try await MacSyncEngine.shared.sendNotificationToPairedDevices(
                title: NativeAppSecretRedactor.redactText(String(title.prefix(160))),
                body: NativeAppSecretRedactor.redactText(String(summary.prefix(500))),
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
