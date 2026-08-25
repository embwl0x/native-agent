import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.activityCapture.lastErrorLine
@MainActor
@Suite("Activity Capture critical issue delivery", .serialized)
struct ActivityCaptureLastErrorLineEvalTests {
    @Test("a failed purge remains primary after a lower-severity follow-up and reaches the external alert channel")
    func criticalFailureSurvivesLaterBenignIssueAndEscalates() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notificationSink = CriticalIssueNotificationSink()
        let controller = ActivityWatchController(
            dataRoot: root,
            criticalIssueNotifier: { title, body in notificationSink.record(title: title, body: body) }
        )

        let failedPurge = "Excluded com.example.Mail, but could not delete its recorded rows: fixture purge failed"
        let benignFollowUp = "Activity policy reload will be retried."
        controller.recordIssue(failedPurge, severity: .critical)
        controller.recordIssue(benignFollowUp, severity: .notice)

        #expect(controller.primaryIssue?.message == failedPurge)
        #expect(controller.lastError == failedPurge)
        #expect(controller.presentationIssues.map(\.message) == [failedPurge, benignFollowUp])

        // Negative control: the retired single-string/last-write behavior would
        // have selected this harmless follow-up and hidden the failed purge.
        #expect(controller.issues.last?.message == benignFollowUp)
        #expect(controller.issues.last?.message != controller.lastError)

        let delivery = try #require(notificationSink.deliveries.first)
        #expect(notificationSink.deliveries.count == 1)
        #expect(delivery.title == "Activity capture needs attention")
        #expect(delivery.body.contains("data-retention failure"))

        // `presentationIssues.first` is the production line projection the
        // panel renders with the `activity.capture.last-error` identity.
        // Assert that projection directly: AppKit's private SwiftUI wrappers
        // are not the view's state authority and expose unrelated controls.
        let visibleLine = try #require(controller.presentationIssues.first)
        #expect(visibleLine.id == controller.primaryIssue?.id)
        #expect(visibleLine.severity == .critical)
        #expect(visibleLine.severity.title == "Action needed")
        #expect(visibleLine.message == failedPurge)
    }

    @Test("only critical issues become privacy-safe external alerts")
    func lowerSeverityIssuesDoNotCreateLockScreenNoise() throws {
        let warning = ActivityCaptureIssue(
            id: UUID(), occurredAt: Date(), severity: .warning, message: "fixture warning"
        )
        let critical = ActivityCaptureIssue(
            id: UUID(), occurredAt: Date(), severity: .critical, message: "fixture critical"
        )

        #expect(ActivityCaptureIssueNotificationPresentation.notification(for: warning) == nil)
        let notification = try #require(ActivityCaptureIssueNotificationPresentation.notification(for: critical))
        #expect(notification.title == "Activity capture needs attention")
        #expect(notification.body.contains("fixture critical") == false,
                "raw capture errors must stay out of lock-screen notification text")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-capture-last-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}

@MainActor
private final class CriticalIssueNotificationSink {
    struct Delivery: Equatable {
        let title: String
        let body: String
    }

    private(set) var deliveries: [Delivery] = []

    func record(title: String, body: String) {
        deliveries.append(Delivery(title: title, body: body))
    }
}
