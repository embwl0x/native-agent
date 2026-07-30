import Foundation

/// A compact revision stamp exposed by live resident owners and consumed by
/// evaluation harnesses when they need to prove that an intervention changed
/// the intended owner.
public struct FrozenMindOwnerRevision: Codable, Hashable, Sendable, Equatable {
    public let owner: String
    public let revision: String

    public init(owner: String, revision: String) {
        self.owner = String(owner.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.revision = String(revision.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
    }
}
