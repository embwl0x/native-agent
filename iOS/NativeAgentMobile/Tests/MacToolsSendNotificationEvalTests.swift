import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.mactools.sendNotification`.
///
/// A policy-disabled notification control must explain the lock before the
/// disabled Send button, and its result must name the notification operation.
final class MacToolsSendNotificationEvalTests: XCTestCase {
    func test_notificationFeedbackAlwaysNamesItsOutcome() {
        XCTAssertEqual(
            MacNotificationSendPresentation.Feedback.sent.text,
            "Notification sent to the Mac."
        )
        XCTAssertEqual(
            MacNotificationSendPresentation.Feedback.sent.systemImage,
            "checkmark.circle.fill"
        )
        XCTAssertEqual(
            MacNotificationSendPresentation.Feedback.failed("policy denied").text,
            "Couldn’t send notification: policy denied"
        )
        XCTAssertEqual(
            MacNotificationSendPresentation.Feedback.failed("policy denied").systemImage,
            "exclamationmark.triangle.fill"
        )
    }

    func test_policyExplanationPrecedesTheDisabledSendControlAndFeedbackIsLabeled() throws {
        let source = try MobileEvalSources.mobileSource("MacToolsView.swift")
        let notificationStart = try XCTUnwrap(source.range(of: "// Send notification"))
        let notificationEnd = try XCTUnwrap(source.range(of: "// Lock screen", range: notificationStart.upperBound..<source.endIndex))
        let notificationComposer = String(source[notificationStart.lowerBound..<notificationEnd.lowerBound])
        // The view routes the copy through MacToolsPrivilegePresentation rather
        // than inlining the literal; pin the call site AND the human-readable
        // string it resolves to.
        let policyCue = try XCTUnwrap(notificationComposer.range(of: "lockedPolicyRow(MacToolsPrivilegePresentation.disabledDescription(for: .notifications))"))
        XCTAssertEqual(
            MacToolsPrivilegePresentation.disabledDescription(for: .notifications),
            "Notifications are disabled by Mac Control policy."
        )
        let sendButton = try XCTUnwrap(notificationComposer.range(of: "Task { await sendNotification() }"))
        XCTAssertLessThan(policyCue.lowerBound, sendButton.lowerBound)
        XCTAssertTrue(notificationComposer.contains("Label(r.text, systemImage: r.systemImage)"))
        XCTAssertTrue(notificationComposer.contains("accessibilityLabel(\"Notification status: \\(r.text)\")"))
    }
}
