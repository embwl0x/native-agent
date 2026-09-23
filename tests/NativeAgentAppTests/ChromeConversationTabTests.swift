import Testing
import PersistenceCore
@testable import NativeAgentApp

@Test func chromeConversationRetainsExactLeaseAndSequenceWithoutInferringSnapshots() throws {
    let current = ChromeConversationTab(result: ["leaseId": .string("one"), "userSequence": .int(3)])
    let resolved = try ChromeConversationTab.resolve(effect: .click, payload: [
        "leaseId": .string(""),
        "snapshotId": .string("observed-page"), "nodeId": .string("n4"),
    ], current: current)
    #expect(resolved["leaseId"] == .string("one"))
    #expect(resolved["expectedUserSequence"] == .int(3))
    #expect(resolved["snapshotId"] == .string("observed-page"))
    #expect(resolved["nodeId"] == .string("n4"))
    let missing = try ChromeConversationTab.resolve(effect: .click, payload: [
        "leaseId": .string(""), "nodeId": .string("n4"),
    ], current: current)
    #expect(missing["snapshotId"] == nil)
}

@Test func chromeConversationNeverBorrowsSequenceForAnotherExplicitTabOrOverridesProof() throws {
    let current = ChromeConversationTab(result: ["leaseId": .string("one"), "userSequence": .int(3)])
    let other: [String: JSONValue] = ["leaseId": .string("two"), "expectedUserSequence": .int(-1)]
    #expect(try ChromeConversationTab.resolve(effect: .navigate, payload: other, current: current) == other)
    let explicit: [String: JSONValue] = ["leaseId": .string("one"), "expectedUserSequence": .int(2)]
    #expect(try ChromeConversationTab.resolve(effect: .navigate, payload: explicit, current: current) == explicit)
}

@Test func chromeConversationWithoutRememberedTabRefusesInsteadOfOpeningOrClaiming() {
    #expect(throws: ChromeControlRuntimeError.self) {
        try ChromeConversationTab.resolve(effect: .snapshot, payload: ["leaseId": .string("")], current: nil)
    }
    #expect(ChromeConversationTab(result: ["leaseId": .string("one")]) == nil)
}
