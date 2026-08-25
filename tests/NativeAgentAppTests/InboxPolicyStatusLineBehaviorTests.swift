import Testing
@testable import NativeAgentApp

@Suite("Inbox policy status line behavior")
struct InboxPolicyStatusLineBehaviorTests {
    // app.desk / desk.inboxPolicy.statusLine
    @Test("every Inbox Policy outcome carries an explicit honest tone")
    func statusEventsDoNotInferSeverityFromMessageWording() {
        let failures: [InboxPolicyStatus.Event] = [
            .settingsLoadFailed("offline"),
            .triggersLoadFailed("permission denied"),
            .masterSaveFailed("write rejected"),
            .triggerSaveFailed("scheduler unavailable"),
            .triggerFireFailed("no evidence"),
            .pathsSaveFailed("invalid path"),
        ]
        for event in failures {
            let status = InboxPolicyStatus(event)
            #expect(status.tone == .failure)
            #expect(!status.text.isEmpty)
        }

        let successes: [InboxPolicyStatus.Event] = [
            .masterSaved(enabled: true),
            .masterSaved(enabled: false),
            .triggerSaved(name: "morning_brief", enabled: true),
            .triggerSaved(name: "morning_brief", enabled: false),
            .triggerFired(itemID: nil, wasStub: false),
            .triggerFired(itemID: "abcdef012345", wasStub: true),
            .pathsSaved(count: 3),
        ]
        for event in successes {
            #expect(InboxPolicyStatus(event).tone == .success)
        }

        let unavailable = InboxPolicyStatus(.testUnavailable)
        #expect(unavailable.tone == .warning)
        #expect(unavailable.text.contains("unavailable"))
    }

    // app.desk / desk.inboxPolicy.statusLine
    @Test("status copy retains action facts while tint remains independent of copy")
    func statusCopyAndTintRemainBoundToTheSameEvent() {
        let enabled = InboxPolicyStatus(.triggerSaved(name: "file_watch", enabled: true))
        #expect(enabled.text == "file_watch enabled.")
        #expect(enabled.tone == .success)

        let failed = InboxPolicyStatus(.triggerSaveFailed("disk full"))
        #expect(failed.text == "Toggle failed: disk full")
        #expect(failed.tone == .failure)

        let fired = InboxPolicyStatus(.triggerFired(itemID: "123456789", wasStub: true))
        #expect(fired.text == "Fired (stub) — item: 12345678...")
        #expect(fired.tone == .success)
    }
}
