import Foundation

// Blueprint: | `SlackReplyPreview.swift` | `SlackReplyPreview`: latest-value visible reply publication; joins an admitted send before final delivery, without blocking model deltas on the wire |

/// One writer for the live reply. Its durable identity belongs to the inbound journal.
actor SlackReplyPreview {
    private let publish: @Sendable (String) async throws -> Void
    private let failure: @Sendable (Error) async -> Void
    private var text = ""
    private var pending: String?
    private var closed = false
    private var worker: Task<Void, Never>?
    private var spacing: Task<Void, Error>?
    private var lastSend = Date.distantPast

    init(publish: @escaping @Sendable (String) async throws -> Void,
         failure: @escaping @Sendable (Error) async -> Void) {
        self.publish = publish
        self.failure = failure
    }

    func append(_ delta: String) {
        guard !closed, !delta.isEmpty else { return }
        text += delta
        pending = text
        guard worker == nil else { return }
        worker = Task { await self.flush() }
    }

    private func flush() async {
        while !closed, pending != nil {
            // chat.update permits 50+ calls/minute. First words have no delay.
            let wait = 1.2 - Date().timeIntervalSince(lastSend)
            if wait > 0 {
                let delay = Task { try await Task.sleep(for: .seconds(wait)) }
                spacing = delay
                _ = try? await delay.value
                spacing = nil
            }
            guard !closed, let snapshot = pending else { break }
            pending = nil
            lastSend = Date()
            do { try await publish(snapshot) }
            catch {
                closed = true
                await failure(error)
            }
        }
        worker = nil
    }

    func finish() async {
        closed = true
        pending = nil
        spacing?.cancel()
        // Do not cancel an admitted post: preserve its actual identity/outcome.
        await worker?.value
    }
}
