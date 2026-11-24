import Synchronization
import Foundation
// Blueprint: | `SenseTurnReads.swift` | `SenseTurnReads`: bounded turn-local served-version evidence |

/// The execution owner passes this accumulator to parallel reads; the next execution makes its own.
public final class SenseTurnReads: Sendable {
    private struct State {
        var reads: [SenseProvenance] = []
        var overflowed = false
    }
    private let state = Mutex(State())
    public init() {}

    public func record(_ provenance: SenseProvenance) {
        state.withLock { state in
            guard !state.reads.contains(where: { $0.senseID == provenance.senseID && $0.version == provenance.version }) else { return }
            guard state.reads.count < 128 else { state.overflowed = true; return }
            state.reads.append(provenance)
        }
    }

    public func snapshot() throws -> [SenseProvenance] {
        return try state.withLock { state in
            guard !state.overflowed else {
                throw SenseFailure(code: "provenance_limit", message: "Cannot commit memory: this turn read more than 128 sense versions.")
            }
            return state.reads
        }
    }
}
