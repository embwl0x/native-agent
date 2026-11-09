import Foundation
// Blueprint: | `ApprovalsFace.swift` | Finished approval count, availability and public row words for the face feed |

public struct ApprovalsFace: FaceValue {
    public struct Row: Identifiable, Sendable, Equatable, Codable {
        public let id: String
        public let title: String
        public let status: String

        public init(id: String, title: String, status: String) {
            self.id = id
            self.title = title
            self.status = status
        }
    }

    public var rows: [String: Row]
    public var waitingCount: Int?
    public var hasLoadedSnapshot: Bool
    public var error: String?
    public var isRefreshing: Bool

    public init(rows: [String: Row] = [:], waitingCount: Int? = nil, hasLoadedSnapshot: Bool = false,
                error: String? = nil, isRefreshing: Bool = false) {
        self.rows = rows
        self.waitingCount = waitingCount
        self.hasLoadedSnapshot = hasLoadedSnapshot
        self.error = error
        self.isRefreshing = isRefreshing
    }
}
