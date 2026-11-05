import Foundation
import NativeAgentCore
// Blueprint: | `InlineInteractionModelOverride.swift` | `InlineInteractionModelOverride` enum; `binding` |

/// A turn-held model choice expires with the resumed request so finishing one image cannot rewrite future Work routing. Permanent choices write through the
/// Providers owner.
public enum InlineInteractionModelOverride {
    public struct Binding: Sendable, Equatable {
        public var group: String
        public var providerID: String
        public var model: String

        public init(group: String, providerID: String, model: String) {
            self.group = group
            self.providerID = providerID
            self.model = model
        }
    }

    public static func binding(turn: Turn?, forGroup group: String) -> Binding? {
        guard let current = turn?.modelOverride, current.group == group, !current.providerID.isEmpty else {
            return nil
        }
        return current
    }
}
