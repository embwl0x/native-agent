import AttentionRouting
import ActivityWatch

/// The notification omits sensitive bundle IDs, paths and storage errors;
/// the retained issue in Trust Center remains the detail authority.
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
                userInfo: [NativeAgentNotificationRoute.pageKey: "trust/features"])
        }
    )
}
