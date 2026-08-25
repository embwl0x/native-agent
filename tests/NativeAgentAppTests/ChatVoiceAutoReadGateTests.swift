import Testing

@testable import NativeAgentApp

@Suite("Chat Voice Auto-Read setting")
struct ChatVoiceAutoReadGateTests {
    private let sessionID = "voice-session"

    private func assistant(
        id: String = "assistant-reply",
        sessionID: String? = "voice-session",
        content: String = "  Reply ready  "
    ) -> ChatMessage {
        ChatMessage(id: id, sessionId: sessionID, role: "assistant", content: content)
    }

    @Test("a newly appended assistant reply passes once and a re-render cannot speak it twice")
    func newlyAppendedReplyIsClaimedExactlyOnce() {
        let reply = assistant()
        let first = ChatVoiceAutoReadGate.decide(
            enabled: true,
            sessionID: sessionID,
            isSessionPrimed: true,
            lastMessage: reply,
            lastReadMessageID: nil
        )
        #expect(first == .speak(messageID: "assistant-reply", text: "Reply ready"))

        // This mirrors ChatView committing the cursor before it starts the
        // asynchronous output request; repeated count/content/busy renders
        // therefore cannot replay the same reply.
        #expect(ChatVoiceAutoReadGate.decide(
            enabled: true,
            sessionID: sessionID,
            isSessionPrimed: true,
            lastMessage: reply,
            lastReadMessageID: "assistant-reply"
        ) == .alreadyRead)
    }

    @Test("disabled, unprimed, malformed, and non-assistant tails refuse without consuming a reply")
    func adverseStatesAreExplicitAndDoNotPretendToSpeak() {
        let reply = assistant()
        #expect(ChatVoiceAutoReadGate.decide(
            enabled: false,
            sessionID: sessionID,
            isSessionPrimed: true,
            lastMessage: reply,
            lastReadMessageID: nil
        ) == .disabled)
        #expect(ChatVoiceAutoReadGate.decide(
            enabled: true,
            sessionID: sessionID,
            isSessionPrimed: false,
            lastMessage: reply,
            lastReadMessageID: nil
        ) == .unprimedSession)
        #expect(ChatVoiceAutoReadGate.decide(
            enabled: true,
            sessionID: sessionID,
            isSessionPrimed: true,
            lastMessage: assistant(sessionID: "other-session"),
            lastReadMessageID: nil
        ) == .messageFromAnotherSession)
        #expect(ChatVoiceAutoReadGate.decide(
            enabled: true,
            sessionID: sessionID,
            isSessionPrimed: true,
            lastMessage: ChatMessage(id: "user-tail", sessionId: sessionID, role: "user", content: "hello"),
            lastReadMessageID: nil
        ) == .notAssistant)
        #expect(ChatVoiceAutoReadGate.decide(
            enabled: true,
            sessionID: sessionID,
            isSessionPrimed: true,
            lastMessage: assistant(content: " \n "),
            lastReadMessageID: nil
        ) == .emptyReply)
    }

    @Test("a hidden session retains its old cursor so its next reply remains eligible")
    func sessionSwitchCannotSeedAwayANewReply() {
        let oldReply = assistant(id: "already-read")
        let newerReply = assistant(id: "newly-arrived", content: "A reply while this tab was hidden")

        #expect(ChatVoiceAutoReadGate.decide(
            enabled: true,
            sessionID: sessionID,
            isSessionPrimed: true,
            lastMessage: oldReply,
            lastReadMessageID: "already-read"
        ) == .alreadyRead)
        #expect(ChatVoiceAutoReadGate.decide(
            enabled: true,
            sessionID: sessionID,
            isSessionPrimed: true,
            lastMessage: newerReply,
            lastReadMessageID: "already-read"
        ) == .speak(messageID: "newly-arrived", text: "A reply while this tab was hidden"))
    }
}
