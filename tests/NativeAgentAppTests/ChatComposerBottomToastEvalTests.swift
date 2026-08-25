import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
private func waitForComposerToast(
    _ queue: ChatToastQueue,
    equalTo expected: String,
    timeout: TimeInterval = 1
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if ChatComposerBottomToastPresentation.visibleEntry(from: queue) == expected { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return ChatComposerBottomToastPresentation.visibleEntry(from: queue) == expected
}

@MainActor
private func waitForComposerToastToClear(
    _ queue: ChatToastQueue,
    timeout: TimeInterval = 1
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if ChatComposerBottomToastPresentation.visibleEntry(from: queue) == nil { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return ChatComposerBottomToastPresentation.visibleEntry(from: queue) == nil
}

/// Drives the exact occurrence-preserving sink used by ChatView.showToast and
/// reads the exact projection rendered above the composer.
@MainActor
@Suite("Chat composer bottom toast")
struct ChatComposerBottomToastEvalTests {
    // EVAL FENCE: app.chat / ui.chat.composer.bottomToast
    @Test("every chat toast occurrence reaches the composer even when normalization matches")
    func composerToastShowsEveryProducerOccurrence() async {
        let queue = ChatToastQueue(displayDuration: 0.02)
        let messages = [
            "Pinned tabs could not be updated at 2026-08-24T10:00:00Z",
            "Pinned tabs could not be updated at 2026-08-24T10:00:01Z",
            "Voice output failed: Speech recognition permission denied",
            "Slash command completed",
        ]

        for message in messages {
            ChatComposerBottomToastPresentation.show(message, in: queue)
        }

        var observed: [String] = []
        for message in messages {
            let appeared = await waitForComposerToast(queue, equalTo: message)
            #expect(appeared, "composer never rendered toast: \(message)")
            if appeared { observed.append(message) }
        }
        #expect(observed == messages)
        #expect(await waitForComposerToastToClear(queue))
    }
}
