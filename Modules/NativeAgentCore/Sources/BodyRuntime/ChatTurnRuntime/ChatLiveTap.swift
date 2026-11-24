import Synchronization
import Foundation
// Blueprint: | `ChatLiveTap.swift` | DeviceSync's live relay for its root's turn deltas and saved answers |

public final class ChatLiveTap: Sendable {
    public enum Kind: Sendable {
        case delta(String)
        case writing(String)
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

    private let relay = Mutex<MacLiveTurnRelay?>(nil)

    func connect(_ next: MacLiveTurnRelay?) {
        relay.withLock { $0 = next }
    }

    @discardableResult
    func emit(sessionId: String, surface: String, runId: String, _ kind: Kind, savedPartial: String? = nil) -> Bool {
        guard let current = relay.withLock({ $0 }) else { return false }
        current.enqueue(Event(sessionId: sessionId, surface: surface, runId: runId, kind: kind, savedPartial: savedPartial))
        return true
    }
}
