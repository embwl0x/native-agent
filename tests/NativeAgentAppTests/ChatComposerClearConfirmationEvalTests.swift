import Testing
@testable import NativeAgentApp

@Suite("Chat composer clear confirmation")
struct ChatComposerClearConfirmationEvalTests {
    private func source(_ name: String) throws -> String {
        try AppSourceScraping.appSource(name)
    }

    @Test("cancel keeps the transcript untouched and cannot later consume a clear")
    func cancelDoesNotAuthorizeClear() {
        var confirmation = ChatClearConfirmationState()
        var messageIDs = ["first", "second"]

        confirmation.request()
        #expect(confirmation.isPresented)
        confirmation.cancel()
        #expect(!confirmation.isPresented)

        if confirmation.consumeConfirmation() {
            messageIDs.removeAll()
        }
        #expect(messageIDs == ["first", "second"])
    }

    @Test("a displayed confirmation authorizes exactly one destructive clear")
    func confirmationIsOneShot() {
        var confirmation = ChatClearConfirmationState()

        let consumesWithoutRequest = confirmation.consumeConfirmation()
        #expect(!consumesWithoutRequest)
        confirmation.request()
        let consumesRequestedClear = confirmation.consumeConfirmation()
        #expect(consumesRequestedClear)
        #expect(!confirmation.isPresented)
        let consumesRepeatedClear = confirmation.consumeConfirmation()
        #expect(!consumesRepeatedClear)
    }

    @Test("slash clear, mounted dialog, and destructive action share the same gate")
    func clearRouteIsMountedAndGated() throws {
        let slash = try source("ChatView+SlashCommands.swift")
        #expect(slash.contains("case .clear:\n            clearConfirmation.request()"))

        let chat = try source("ChatView.swift")
        #expect(!chat.contains(".frame(width: 0, height: 0)\n                .confirmationDialog"),
                "the confirmation must not be hosted by the zero-size tool-form view")

        guard let start = chat.range(of: ".confirmationDialog(\n            \"Clear all messages in this session?\"") else {
            Issue.record("mounted clear confirmation moved")
            return
        }
        let dialog = String(chat[start.lowerBound...].prefix(900))
        #expect(dialog.contains("isPresented: clearConfirmationBinding"))
        #expect(dialog.contains("Button(\"Clear Messages\", role: .destructive)"))
        #expect(dialog.contains("guard clearConfirmation.consumeConfirmation() else { return }"))
        #expect(dialog.contains("await appModel.clearActiveChatMessages()"))
        #expect(dialog.contains("Button(\"Cancel\", role: .cancel) {\n                clearConfirmation.cancel()\n            }"))
    }
}
