import Foundation
// Blueprint: | `ApprovalsFace.swift` | Finished waiting approval count and read error for the face feed |

public struct ApprovalsFace: FaceValue {
    public var waitingCount: Int?
    public var error: String?

    public init(waitingCount: Int? = nil, error: String? = nil) {
        self.waitingCount = waitingCount
        self.error = error
    }
}
