import Foundation
// Blueprint: | `PersonaDocument.swift` | Shared finished personality document used by the editor and agent pages |

public struct PersonaDocSpec: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let filename: String
    public let path: String
    public let content: String
    public let updatedAt: String?

    public init(id: String, title: String, filename: String, path: String, content: String, updatedAt: String?) {
        self.id = id
        self.title = title
        self.filename = filename
        self.path = path
        self.content = content
        self.updatedAt = updatedAt
    }
}

