import Foundation
// Blueprint: | `FaceReadPage.swift` | Revision-bound document chunks for the signed phone read door |

public struct FaceReadPage: Codable, Sendable {
    public let id: UUID
    public let cursor: Int
    public let text: String
    public let next: Int?
    public let revision: String
    public let face: PartFace?
    public init(id: UUID, cursor: Int, text: String, next: Int?, revision: String, face: PartFace? = nil) {
        self.id = id; self.cursor = cursor; self.text = text; self.next = next; self.revision = revision
        self.face = face
    }
}
public struct FaceDocumentPresentation: Codable, Sendable {
    public let text: String
    public let face: PartFace
    public init(text: String, face: PartFace) { self.text = text; self.face = face }
}
