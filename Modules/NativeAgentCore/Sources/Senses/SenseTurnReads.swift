import Foundation
// Blueprint: | `SenseTurnReads.swift` | `SenseTurnReads`: bounded turn-local served-version evidence |

/// The execution owner passes this accumulator to parallel reads; the next execution makes its own.
public final class SenseTurnReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [SenseProvenance] = []
    private var overflowed = false
    public init() {}

    public func record(_ provenance: SenseProvenance) {
        lock.lock(); defer { lock.unlock() }
        guard !reads.contains(where: { $0.senseID == provenance.senseID && $0.version == provenance.version }) else { return }
        guard reads.count < 128 else { overflowed = true; return }
        reads.append(provenance)
    }

    public func snapshot() throws -> [SenseProvenance] {
        lock.lock(); defer { lock.unlock() }
        guard !overflowed else {
            throw SenseFailure(code: "provenance_limit", message: "Cannot commit memory: this turn read more than 128 sense versions.")
        }
        return reads
    }
}
