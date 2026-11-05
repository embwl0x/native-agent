import Foundation
import os
// Blueprint: | `ChatLiveTap.swift` | `ChatLiveTap` enum; `observe` (every turn's deltas and saved answer, for the phone) |

/// Device sync observes every turn so the phone can watch work started elsewhere. Observers run inside the turn and must return at once.
public enum ChatLiveTap {
    public enum Kind: Sendable {
        case delta(String)
        case answered(String)
        /// The status comes from the runtime, so retained output preserves the turn's actual outcome.
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

    // Box the closure: withLock's inout read otherwise adds a reabstraction thunk per delta and can overflow the stack.
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
