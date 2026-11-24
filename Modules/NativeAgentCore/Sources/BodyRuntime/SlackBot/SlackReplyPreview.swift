import Foundation

// Blueprint: | `SlackReplyPreview.swift` | `SlackReplyPreview`: latest-value publication joins admitted sends before final delivery |

/// One writer for the live reply. Its durable identity belongs to the inbound journal.
actor SlackReplyPreview {
    private let publish: @Sendable (String) async throws -> Void
    private let failure: @Sendable (Error) async -> Void
    private var text = ""
    private var pending: String?
    private var closed = false
    private var worker: Task<Void, Never>?

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
            guard !closed, let snapshot = pending else { break }
            pending = nil
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
        // Do not cancel an admitted post: preserve its actual identity/outcome.
        await worker?.value
    }
}
