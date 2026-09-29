import Foundation

public struct NativeActionRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String?
    public var risk: String?
    public var requiresApproval: Bool?
    public var dryRunAvailable: Bool?

    public init(id: String, name: String, kind: String? = nil, risk: String? = nil, requiresApproval: Bool? = nil, dryRunAvailable: Bool? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.risk = risk
        self.requiresApproval = requiresApproval; self.dryRunAvailable = dryRunAvailable
    }
}

