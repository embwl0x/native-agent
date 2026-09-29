import Foundation

public struct RuntimeTrace: Identifiable, Codable, Hashable {
    public var id: String
    public var kind: String
    public var title: String
    public var status: String?
    public var createdAt: String?
    public init(id: String, kind: String, title: String, status: String? = nil, createdAt: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.createdAt = createdAt
    }
}
