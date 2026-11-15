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
        /// The card asked which model the continued turn itself runs on (raised by the turn's own question, not by a tool such as image
        /// generation, whose card binds only that tool's call).
        public var drivesTurn: Bool

        public init(group: String, providerID: String, model: String, drivesTurn: Bool = false) {
            self.group = group
            self.providerID = providerID
            self.model = model
            self.drivesTurn = drivesTurn
        }
    }

    public static func binding(turn: Turn?, forGroup group: String) -> Binding? {
        guard let current = turn?.modelOverride, current.group == group, !current.providerID.isEmpty else {
            return nil
        }
        return current
    }
}
