import Foundation

public struct CodexCheckResponse: Codable {
    public var ok: Bool
    public var model: String
    public init(ok: Bool, model: String) {
        self.ok = ok
        self.model = model
    }
}
