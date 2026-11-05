import Foundation
import NativeAgentCore
// Blueprint: | `Turn+Skills.swift` | `Turn` holds authored run ownership and file reach |

private enum PartIDPart: TurnPart { static let unset: String? = nil }
private enum AbilityIDPart: TurnPart { static let unset: String? = nil }
private enum RequesterPart: TurnPart { static let unset: String? = nil }
private enum HostCallIDPart: TurnPart { static let unset: UUID? = nil }
private enum FileReachPart: TurnPart { static let unset: (root: URL, write: Bool)? = nil }

extension Turn {
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
