import Foundation
import os

/// Every turn's text as it streams, whichever door started it. Device sync
/// observes it so the phone can watch a turn in its conversation that it did
/// not start. The observer must return at once: it runs inside the turn.
public enum ChatLiveTap {
    public enum Kind: Sendable {
        /// Provider text, in order.
        case delta(String)
        case answered(String)
        /// Saved text of a turn that stopped short; `status` is the turn's own
        /// runtime status ("interrupted", "waiting on you").
        case incomplete(String, status: String)
        case failed(String)
        case cancelled
    }

    public struct Event: Sendable {
        public let sessionId: String
        public let surface: String
        public let runId: String
        public let kind: Kind
        /// Only text that survived transcript persistence, including on Stop.
        public let savedPartial: String?
    }

    public typealias Observer = @Sendable (Event) -> Void

    // Boxed: a closure read back through withLock's inout state is re-wrapped
    // in a reabstraction thunk on every read; 2,000 deltas overflowed a turn's
    // stack (10-07 SIGBUS crashes).
    private final class Box: Sendable {
        let call: Observer
        init(_ call: @escaping Observer) { self.call = call }
    }
    private static let observer = OSAllocatedUnfairLock<Box?>(initialState: nil)

    public static func observe(_ next: Observer?) {
        let box = next.map(Box.init)
        observer.withLock { $0 = box }
    }

    static func emit(sessionId: String, surface: String, runId: String, _ kind: Kind, savedPartial: String? = nil) {
        guard let current = observer.withLock({ $0 }) else { return }
        current.call(Event(sessionId: sessionId, surface: surface, runId: runId, kind: kind, savedPartial: savedPartial))
    }
}
