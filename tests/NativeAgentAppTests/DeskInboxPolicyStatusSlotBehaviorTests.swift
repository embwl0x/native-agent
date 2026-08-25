import Testing
@testable import NativeAgentApp

@Suite("Desk Inbox Policy status-slot behavior")
struct DeskInboxPolicyStatusSlotBehaviorTests {
    // app.desk / desk.inboxPolicy.statusSlot
    @Test("a success from one writer cannot replace or recolor another writer's failure")
    func independentSourcesKeepTheirOwnVisibleOutcomes() {
        var slot = InboxPolicyStatusSlot()
        slot.record(
            InboxPolicyStatus(.settingsLoadFailed("trust store unreadable")),
            from: .settingsRead
        )
        slot.record(
            InboxPolicyStatus(.triggerSaved(name: "morning_brief", enabled: true)),
            from: .triggerToggle("morning_brief")
        )

        #expect(slot.entries.count == 2)
        let settings = slot.entries.first { $0.source == .settingsRead }
        #expect(settings?.status.text == "Failed to load inbox settings: trust store unreadable")
        #expect(settings?.status.tone == .failure)
        let trigger = slot.entries.first { $0.source == .triggerToggle("morning_brief") }
        #expect(trigger?.status.text == "morning_brief enabled.")
        #expect(trigger?.status.tone == .success)
    }

    // app.desk / desk.inboxPolicy.statusSlot
    @Test("only a healthy retry of the failed source removes that source's adverse outcome")
    func sourceScopedRecoveryDoesNotEraseOtherFailures() {
        var slot = InboxPolicyStatusSlot()
        slot.record(InboxPolicyStatus(.settingsLoadFailed("trust unavailable")), from: .settingsRead)
        slot.record(InboxPolicyStatus(.triggersLoadFailed("trigger store unavailable")), from: .triggersRead)

        slot.clear(source: .settingsRead)
        #expect(slot.entries.count == 1)
        #expect(slot.entries.first?.source == .triggersRead)
        #expect(slot.entries.first?.status.tone == .failure)
        #expect(slot.entries.first?.status.text.contains("trigger store unavailable") == true)
    }
}
