import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
private final class ComposerToastTransitionProbe {
    enum Transition: Equatable, Sendable {
        case visible(String)
        case cleared
    }

    private let events: AsyncStream<Transition>
    private let continuation: AsyncStream<Transition>.Continuation
    private var recorded: [Transition] = []

    init() {
        let stream = AsyncStream<Transition>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func record(_ entry: String?) {
        let transition = entry.map(Transition.visible) ?? .cleared
        recorded.append(transition)
        continuation.yield(transition)
    }

    func next(within timeout: Duration) async -> Transition? {
        await withTaskGroup(of: Transition?.self) { group in
            let events = self.events
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return nil
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func transitions() -> [Transition] { recorded }
}

/// Drives the exact occurrence-preserving sink used by ChatView.showToast and
/// reads the exact projection rendered above the composer.
@MainActor
@Suite("Chat composer bottom toast")
struct ChatComposerBottomToastEvalTests {
    // EVAL FENCE: app.chat / ui.chat.composer.bottomToast
    @Test("every chat toast occurrence reaches the composer even when normalization matches")
    func composerToastShowsEveryProducerOccurrence() async {
        let probe = ComposerToastTransitionProbe()
        let queue = ChatToastQueue(
            displayDuration: 0.02,
            visibleEntryDidChange: { probe.record($0) }
        )
        let messages = [
            "Pinned tabs could not be updated at 2026-08-24T10:00:00Z",
            "Pinned tabs could not be updated at 2026-08-24T10:00:01Z",
            "Voice output failed: Speech recognition permission denied",
            "Slash command completed",
        ]

        for message in messages {
            ChatComposerBottomToastPresentation.show(message, in: queue)
        }

        let expected = messages.flatMap {
            [ComposerToastTransitionProbe.Transition.visible($0), .cleared]
        }
        for transition in expected {
            #expect(await probe.next(within: .seconds(1)) == transition)
        }
        #expect(await probe.next(within: .milliseconds(500)) == nil)
        #expect(probe.transitions() == expected)
        #expect(ChatComposerBottomToastPresentation.visibleEntry(from: queue) == nil)
    }
}
