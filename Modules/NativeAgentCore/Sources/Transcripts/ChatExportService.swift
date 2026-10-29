import Foundation
// Blueprint: | `ChatExportService.swift` | Shared chat export errors and completion value; concrete Markdown export lives beside EngineRuntime's ChatMessage |

public enum ChatExportError: LocalizedError {
    case noActiveSession
    case noMessages
    case downloadsUnavailable

    public var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active session to export"
        case .noMessages:
            return "No messages to export"
        case .downloadsUnavailable:
            return "Could not locate Downloads folder"
        }
    }
}

public struct ChatExportResult: Sendable {
    public let url: URL
    public let unavailableImages: [String]

    public init(url: URL, unavailableImages: [String]) {
        self.url = url
        self.unavailableImages = unavailableImages
    }
}
