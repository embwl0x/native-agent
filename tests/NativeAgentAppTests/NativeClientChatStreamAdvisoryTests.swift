import ChatOrchestration
import Foundation
import NativeAgentCore
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, row `client.chatStream.slowTurnAdvisory`
// (NativeClient+ChatRuntime.swift:223 delay / :279 watch / :286 defer cancel /
// :348 cancel on first non-empty delta).
//
// The "Still working on it" notice is the ONLY feedback a user gets during a
// long turn (a live turn measured 155,752 ms). The ledger names two silent
// breaks, neither of which changes any assertion anywhere today:
//   (a) an EMPTY liveness delta cancels the watch if the `!text.isEmpty` guard
//       regresses — so the notice never posts on exactly the turns it exists
//       for;
//   (b) a missed cancel path leaves the notice posting AFTER the reply already
//       rendered.
//
// `bridgeChatStreamEvents` is the internal seam the production producer calls,
// so both are drivable deterministically with no provider and no clock. The
// cancel COUNT is the mutation tooth: dropping the `!text.isEmpty` guard turns
// test (a)'s expected 1 into 3.
@Suite("Native client chat stream slow-turn advisory")
struct NativeClientChatStreamAdvisoryTests {
    private struct DriveResult {
        var deltas: [String]
        var threw: Bool
        var cancels: Int
    }

    private func drive(
        _ events: [TurnStreamEvent],
        firstToken: NativeClient.FirstTokenFlag
    ) async -> DriveResult {
        let cancels = CancelCounter()
        let core = AsyncThrowingStream<TurnStreamEvent, Error> { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
        let identity = MacChatTurnIdentity(sessionId: "advisory-session", turnId: "advisory-turn")
        let surface = AsyncThrowingStream<String, Error> { continuation in
            Task {
                await NativeClient.bridgeChatStreamEvents(
                    core,
                    sessionId: identity.sessionId,
                    activityIdentity: identity,
                    metaBox: NativeClient.MetaBox(),
                    firstToken: firstToken,
                    cancelSlowWatch: { cancels.record() },
                    onTurnActivity: { _ in },
                    continuation: continuation
                )
            }
        }

        var deltas: [String] = []
        var threw = false
        do {
            for try await text in surface { deltas.append(text) }
        } catch {
            threw = true
        }
        return DriveResult(deltas: deltas, threw: threw, cancels: cancels.value)
    }

    @Test("an EMPTY liveness delta must not mark first token or cancel the advisory")
    func emptyDeltaDoesNotSuppressTheAdvisory() async {
        let firstToken = NativeClient.FirstTokenFlag()
        let result = await drive([.delta(""), .delta("")], firstToken: firstToken)

        #expect(
            firstToken.seen() == false,
            "an empty keep-alive delta is not a first token — marking it silences the advisory on exactly the turns it exists for"
        )
        // Exactly ONE cancel: the unconditional end-of-stream one. Two empty
        // deltas contributing cancels of their own (3) is the regression.
        #expect(
            result.cancels == 1,
            "empty deltas must not cancel the advisory (observed \(result.cancels) cancels for 2 empty deltas + EOF)"
        )
        #expect(result.deltas == ["", ""], "empty deltas still pass through to the surface")
        #expect(result.threw == false)
    }

    @Test("the first visible delta marks the token and cancels the advisory")
    func firstVisibleDeltaCancelsTheAdvisory() async {
        let firstToken = NativeClient.FirstTokenFlag()
        let result = await drive(
            [.delta(""), .delta("Hello"), .delta(" there")],
            firstToken: firstToken
        )

        #expect(firstToken.seen(), "user-visible text IS the first token")
        #expect(
            result.cancels > 1,
            "real text must cancel the advisory before EOF, not leave it to post after the reply"
        )
        #expect(result.deltas == ["", "Hello", " there"])
    }

    @Test("a terminal error cancels the advisory and closes the surface")
    func terminalErrorCancelsTheAdvisory() async {
        let firstToken = NativeClient.FirstTokenFlag()
        let result = await drive([.error("upstream refused")], firstToken: firstToken)

        #expect(
            result.cancels >= 1,
            "an errored turn must not leave a timer that posts 'Still working on it' after the failure rendered"
        )
        #expect(result.threw, "a terminal error must reach the surface as a thrown error")
        #expect(firstToken.seen() == false)
    }
}

private final class CancelCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
