import Foundation
import Testing
@testable import NativeAgentApp

/// Executes the receipt reader, AppModel's active-session slot, and the
/// exact availability predicate consumed by ChatHeaderView.  It deliberately
/// uses a fixture root rather than the developer's live receipt feed.
@MainActor
@Suite("Chat header context receipt toggle")
struct ChatHeaderContextReceiptToggleEvalTests {
    // EVAL FENCE: app.chat / ui.chat.header.contextReceiptToggle
    @Test("a receipt from the active assembly enables the header by fingerprint or run ID")
    func contextReceiptToggleUsesTheActiveAssemblyReceiptIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-header-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let receipts = root.appendingPathComponent("context/receipts.jsonl")
        try FileManager.default.createDirectory(
            at: receipts.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // The first receipt belongs to another replayed turn.  The real
        // reader must not borrow that identity for the active session.
        try Data("""
        {"sessionId":"other-session","fingerprint":"other-fingerprint"}
        {"sessionId":"active-session","runId":"replayed-turn-run"}
        {"sessionId":"fingerprint-session","fingerprint":"assembly-fingerprint"}
        {"sessionId":"incomplete-session"}
        """.utf8).write(to: receipts)

        let activeReceipt = try await NativeClient.getLatestContextReceipt(
            sessionId: "active-session",
            dataRoot: root
        )
        let incompleteReceipt = try await NativeClient.getLatestContextReceipt(
            sessionId: "incomplete-session",
            dataRoot: root
        )
        let fingerprintReceipt = try await NativeClient.getLatestContextReceipt(
            sessionId: "fingerprint-session",
            dataRoot: root
        )
        let absentReceipt = try await NativeClient.getLatestContextReceipt(
            sessionId: "missing-session",
            dataRoot: root
        )

        let model = AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            activeChatSessionIDWriter: { _ in },
            chatSnapshotPublisher: {}
        )
        model.activeChatSessionId = "active-session"
        model.latestContextReceipt = activeReceipt

        #expect(model.latestContextReceipt?.fingerprint == nil)
        #expect(model.latestContextReceipt?.runId == "replayed-turn-run")
        #expect(ChatHeaderPresentation.contextReceiptToggleIsEnabled(model.latestContextReceipt))
        #expect(ChatHeaderPresentation.contextReceiptToggleIsEnabled(fingerprintReceipt))
        let receiptMetadata: ChatHeaderPresentation.Metadata = ChatHeaderPresentation.metadata(
            count: 1,
            fingerprint: model.latestContextReceipt?.fingerprint,
            runID: model.latestContextReceipt?.runId
        )
        #expect(receiptMetadata.showsContextReady)

        // This is the exact production action used by ChatHeaderView.  It is
        // deliberately exercised directly rather than assuming SwiftUI's
        // offscreen AppKit tree exposes a native NSButton.
        var showContext = ChatHeaderPresentation.contextReceiptVisibilityAfterToggle(
            isVisible: false,
            context: model.latestContextReceipt
        )
        #expect(showContext)
        showContext = ChatHeaderPresentation.contextReceiptVisibilityAfterToggle(
            isVisible: showContext,
            context: model.latestContextReceipt
        )
        #expect(!showContext)

        // Empty/missing receipt records are incomplete evidence, not a
        // successful receipt that happens to have no visible fingerprint.
        #expect(!ChatHeaderPresentation.contextReceiptToggleIsEnabled(incompleteReceipt))
        #expect(!ChatHeaderPresentation.contextReceiptToggleIsEnabled(absentReceipt))
        #expect(!ChatHeaderPresentation.contextReceiptToggleIsEnabled(nil))
        #expect(!ChatHeaderPresentation.contextReceiptVisibilityAfterToggle(
            isVisible: false,
            context: incompleteReceipt
        ))
        #expect(ChatHeaderPresentation.contextReceiptVisibilityAfterToggle(
            isVisible: true,
            context: absentReceipt
        ))
        #expect(!ChatHeaderPresentation.hasContextReceiptIdentity(
            fingerprint: " \n\t ", runID: ""
        ))
    }
}
