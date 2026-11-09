import Foundation
import NativeAgentCore
import Synchronization
// Blueprint: | `Turn+Skills.swift` | `Turn` holds authored run ownership and file reach |

private enum PartIDPart: TurnPart { static let unset: String? = nil }
private enum AbilityIDPart: TurnPart { static let unset: String? = nil }
private enum RequesterPart: TurnPart { static let unset: String? = nil }
private enum HostCallIDPart: TurnPart { static let unset: UUID? = nil }
private enum FileReachPart: TurnPart { static let unset: (root: URL, write: Bool)? = nil }
private enum AbilityRoundsPart: TurnPart { static let unset: AbilityRounds? = nil }

/// Executions report their accounting identity here, independent of the door verb that reached them.
public final class AbilityRounds: Sendable {
    public struct Version: Hashable, Sendable {
        public let id: String
        public let key: String
    }
    private struct State: Sendable {
        var pending: Set<Version> = []
        var rounds: [Version: Int] = [:]
    }
    private let state = Mutex(State())
    public init() {}
    func ran(id: String, version: String) {
        state.withLock { $0.pending.insert(Version(id: id, key: version)) }
    }
    /// Once per dispatch round, including its nested script/batch calls. No execution receipt means no observation to count.
    public func endRound() throws {
        try state.withLock { state in
            var next = state.rounds
            for version in state.pending {
                let (count, overflow) = (next[version] ?? 0).addingReportingOverflow(1)
                guard !overflow else { throw ToolFailureError("Round accounting overflow for \(version.id)@\(version.key).", effects: .none,
                    owner: "ability round accounting", code: "accounting_overflow", instruction: "Inspect this turn's round accounting.", recovery: .inspect) }
                next[version] = count
            }
            state.rounds = next; state.pending = []
        }
    }
    /// Settlement claims these observations once, whether the turn replied or stopped.
    public func take() throws -> [Version: Int] {
        try endRound()
        return state.withLock { state in
            let rounds = state.rounds
            state.rounds = [:]
            return rounds
        }
    }
}

extension Turn {
    public var abilityRounds: AbilityRounds? {
        get { self[AbilityRoundsPart.self] }
        set { self[AbilityRoundsPart.self] = newValue }
    }
    /// The part or script whose run this is, through every call it makes.
    public var partID: String? {
        get { self[PartIDPart.self] }
        set { self[PartIDPart.self] = newValue }
    }
    /// The ability whose own code may answer as that ability.
    public var abilityID: String? {
        get { self[AbilityIDPart.self] }
        set { self[AbilityIDPart.self] = newValue }
    }
    /// Who asked for the run, shown on its approvals and cards.
    public var requester: String? {
        get { self[RequesterPart.self] }
        set { self[RequesterPart.self] = newValue }
    }
    /// The host invocation carried into approvals.
    public var hostCallID: UUID? {
        get { self[HostCallIDPart.self] }
        set { self[HostCallIDPart.self] = newValue }
    }
    /// The authored ability's admitted file root and write authority.
    public var fileReach: (root: URL, write: Bool)? {
        get { self[FileReachPart.self] }
        set { self[FileReachPart.self] = newValue }
    }
}
