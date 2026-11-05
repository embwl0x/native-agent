import Foundation
import NativeAgentCore
// Blueprint: | `Owed.swift` | Nonperson births and existing obligation settlements; person asks are born only through Matter |

/// Use the owner's shown ID as one experience; only that owner moves its obligation at its persistence boundary.
/// Waits and let-go reads use the same record rather than another store.
public enum Owed {
    public enum Phase: Sendable { case owed, accepted, letGo(ObligationPhase.LetGo) }

    /// Do not create a settled past obligation merely to close it; born false moves only existing debt.
    @discardableResult
    public static func record(_ root: URL, id: String, kind: Experience.Kind, key: String, to: String,
                              phase: Phase, evidence: [Experience.Ref], born: Bool = true) -> Task<Void, Never> {
        ExperienceStore.record(root, id) { store in
            if try await store.experience(id) == nil {
                guard born, kind != .decision || to != ForPerson.person else { return }
                var fresh = Experience(id: id, kind: kind, evidence: evidence, owes: [key: .init(to: to)])
                fresh.addressedTo = [to]
                try await store.begin(fresh)
            }
            switch phase {
            case .owed: break
            case .accepted: try await store.append([.obligation(key: key, phase: .accepted, evidence: evidence.first)], to: id)
            case .letGo(let reason): try await store.append([.letGo(key: key, reason: reason)], to: id)
            }
        }
    }
}
