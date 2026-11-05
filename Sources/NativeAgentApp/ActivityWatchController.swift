import AttentionRouting
import ActivityWatch

// Blueprint: | `ActivityWatchController.swift` | `ActivityWatchController`: Capture watch binding and privacy-safe issue notifications |

/// Omit sensitive IDs, paths and errors from notifications; Trust Center retains issue detail.
enum ActivityCaptureIssueNotificationPresentation {
    static func notification(for issue: ActivityCaptureIssue) -> (title: String, body: String)? {
        guard issue.severity == .critical else { return nil }
        return (
            title: "Activity capture needs attention",
            body: "A capture-stop or data-retention failure was recorded. Open Trust → Features → Activity Capture to review it."
        )
    }
}

extension ActivityWatchController {
    static let shared = ActivityWatchController(
        errorMessage: { UserFacingError.message($0, action: $1) },
        errorCause: { UserFacingError.cause($0, action: $1) },
        criticalIssueNotifier: { issue in
            guard let notification = ActivityCaptureIssueNotificationPresentation.notification(for: issue) else { return }
            NativeAgentNotifications.post(title: notification.title, body: notification.body,
                userInfo: ["eventId": issue.id.uuidString, NativeAgentNotificationRoute.pageKey: "trust/features"], deadline: nil)
        }
    )
}
