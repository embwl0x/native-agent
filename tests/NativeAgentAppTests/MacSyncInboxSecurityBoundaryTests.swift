import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Mac mobile inbox security boundary")
struct MacSyncInboxSecurityBoundaryTests {
    private func action(messageID: String, transactionID: String?) -> InboxAction {
        InboxAction(
            msgId: messageID,
            clientId: "ios",
            action: "getStatus",
            payload: [:],
            createdAt: ISO8601DateFormatter().string(from: Date()),
            protocolVersion: 1,
            transactionId: transactionID,
            signature: nil
        )
    }

    @Test func canonicalUUIDsProduceChildrenOfTheOwnedDirectory() {
        let messageID = UUID().uuidString
        let transactionID = UUID().uuidString
        let ids = InboxActionFileBoundary.validatedIDs(
            for: action(messageID: messageID, transactionID: transactionID)
        )
        #expect(ids == ValidatedInboxActionIDs(
            messageID: messageID,
            transactionID: transactionID
        ))

        let directory = URL(fileURLWithPath: "/tmp/nativeagent-owned", isDirectory: true)
        let url = InboxActionFileBoundary.jsonURL(
            in: directory,
            validatedID: transactionID
        )
        #expect(url?.deletingLastPathComponent() == directory.standardizedFileURL)
        #expect(url?.lastPathComponent == "\(transactionID).json")
    }

    @Test func traversalAndNonUUIDIdentifiersAreRejectedBeforePathDerivation() {
        for value in ["../../escape", "../outside", "/tmp/absolute", "", "not-a-uuid"] {
            #expect(InboxActionFileBoundary.validatedIDs(
                for: action(messageID: value, transactionID: UUID().uuidString)
            ) == nil)
            #expect(InboxActionFileBoundary.validatedIDs(
                for: action(messageID: UUID().uuidString, transactionID: value)
            ) == nil)
            #expect(InboxActionFileBoundary.jsonURL(
                in: URL(fileURLWithPath: "/tmp/nativeagent-owned", isDirectory: true),
                validatedID: value
            ) == nil)
        }
    }
}
