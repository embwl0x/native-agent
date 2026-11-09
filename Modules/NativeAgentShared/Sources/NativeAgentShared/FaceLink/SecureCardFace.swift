import Foundation
// Blueprint: | `SecureCardFace.swift` | Protected card entry fields and controls projected by the interaction owner without secret values |

public struct SecureCardFace: Codable, Sendable, Equatable {
    public struct Field: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let placeholder: String
        public let helper: String?
        public let secret: Bool
        public let optional: Bool
        public init(id: String, label: String, placeholder: String, helper: String?, secret: Bool, optional: Bool) {
            self.id = id; self.label = label; self.placeholder = placeholder; self.helper = helper
            self.secret = secret; self.optional = optional
        }
    }
    public let identity: CardIdentity
    public let fields: [Field]
    public let primaryLabel: String
    public let signInLabel: String?
    public let fullSetupLabel: String?
    public let restartNote: String?
    public let busyNote: String?
    public let acceptsEntry: Bool
    public init(identity: CardIdentity, fields: [Field], primaryLabel: String, signInLabel: String?, fullSetupLabel: String?,
                restartNote: String?, busyNote: String? = nil, acceptsEntry: Bool) {
        self.identity = identity; self.fields = fields; self.primaryLabel = primaryLabel; self.signInLabel = signInLabel
        self.fullSetupLabel = fullSetupLabel; self.restartNote = restartNote; self.acceptsEntry = acceptsEntry
        self.busyNote = busyNote
    }
}

public enum CardControlPresentation: Codable, Sendable {
    case page(String)
    case connector(String)
}
