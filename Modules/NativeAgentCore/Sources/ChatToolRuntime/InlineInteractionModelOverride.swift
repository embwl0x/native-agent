import Foundation

/// A model choice bound to ONE resumed request, and nothing else.
///
/// Agent's one-image seam. When a picture cannot be made because the Work
/// group's model has no image route, the honest ask is "which model should
/// make THIS picture" — and the honest answer must not rewrite what every
/// Work task runs on from now on. Before this, there was no such thing as a
/// per-request pick: Providers stores a per-SURFACE preference, so "choose a
/// model" could only mean "change it permanently".
///
/// So the choice is carried as a task-local for exactly the resumed request
/// and read by the route resolver, which is why it cannot leak: a task-local
/// dies with the task that set it. Nothing is written to `providers/`, and a
/// later turn resolves the group the way it always did. When the person picks
/// the SECONDARY action instead ("for future Work tasks too"), the resolver
/// does not use this at all — it writes through Providers' own owner, because
/// that is what a permanent change means.
public enum InlineInteractionModelOverride {
    public struct Binding: Sendable, Equatable {
        /// Providers group this override stands in for.
        public var group: String
        public var providerID: String
        public var model: String

        public init(group: String, providerID: String, model: String) {
            self.group = group
            self.providerID = providerID
            self.model = model
        }
    }

    /// Set only for the duration of one resumed request.
    @TaskLocal public static var current: Binding?

    /// The override standing in for `group`, if this request has one.
    public static func binding(forGroup group: String) -> Binding? {
        guard let current, current.group == group, !current.providerID.isEmpty else {
            return nil
        }
        return current
    }
}
