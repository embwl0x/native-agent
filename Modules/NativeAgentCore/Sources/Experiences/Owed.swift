import Foundation
import NativeAgentCore

/// Something she owes or is owed, under the id its owner hands her (a reply's
/// delivery id, a card's `interaction:<id>`): born owing `key` to `to` the
/// first time its owner records it, then moved only by that owner, at its own
/// persistence boundary. Any id she was shown is then one experience, so a
/// wait (`desk.wait`) or a let-go reads it with no second store.
public enum Owed {
    public enum Phase: Sendable { case owed, accepted, letGo(ObligationPhase.LetGo) }

    /// `born: false` only moves one already owed: a settled record from
    /// before this owner projected is never born just to be closed.
    @discardableResult
    public static func record(_ root: URL, id: String, kind: Experience.Kind, key: String, to: String,
                              phase: Phase, evidence: [Experience.Ref], born: Bool = true) -> Task<Void, Never> {
        ExperienceStore.record(root, id) { store in
            if try await store.experience(id) == nil {
                guard born else { return }
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
