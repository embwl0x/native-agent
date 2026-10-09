import Foundation

/// One box per turn, inherited by its tool calls (including parallel calls).
/// No session/global history: the next turn starts empty.
public final class SenseTurnReads: @unchecked Sendable {
    @TaskLocal public static var current: SenseTurnReads?
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
