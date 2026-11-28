import Foundation
// Blueprint: | `CountStatusValues.swift` | `CountStatusValues`: health, capture, download and notice facts drawn through the counts slot |

public struct CountStatusValues: FaceValue {
    public var health: RuntimeHealth?
    public var capture: ActivityCaptureFace?
    public var download: EmbeddingDownloadFace?
    public var toastQueues: [UUID: [SystemToast]] = [:]

    public init() {}
}

public struct ActivityCaptureFace: FaceValue {
    public enum Availability: FaceValue {
        case reading
        case available
        case unavailable(String)
    }

    public let isCapturing: Bool
    public let capturesTitles: Bool
    public let availability: Availability

    public init(isCapturing: Bool, capturesTitles: Bool, availability: Availability) {
        self.isCapturing = isCapturing
        self.capturesTitles = capturesTitles
        self.availability = availability
    }
}

public struct EmbeddingDownloadStatus: FaceValue {
    public var phase = "Not started"
    public var completed: Int64 = 0
    public var total: Int64 = 0
    public var running = false
    public var available = false
    /// Set by the installation commit, independently of staging cleanup.
    public var installedRelease: String?
    public var cleanupFailure: String?

    public init() {}
}

public struct EmbeddingDownloadFace: FaceValue {
    public let status: EmbeddingDownloadStatus
    public let activating: Bool

    public init(status: EmbeddingDownloadStatus, activating: Bool) {
        self.status = status
        self.activating = activating
    }
}

public struct RuntimeStatusFace: Sendable {
    public enum Tone: Sendable { case neutral, success, warning, failure }
    public let text: String
    public let detail: String?
    public let tone: Tone
    public let systemImage: String

    public static func project(health: RuntimeHealth?, lastRefreshError: String?) -> RuntimeStatusFace {
        let hasError = lastRefreshError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let detail = hasError ? "Some sections didn't refresh. The details are in the log." : health?.doctorIssue
        switch health?.reachable {
        case true:
            let needsAttention = hasError || health?.ok != true
            let text = hasError ? "App is online; some app data is unavailable"
                : health?.ok != true ? "App is online; needs attention" : "App is online"
            let onlineDetail = detail ?? (health?.ok != true ? "Check Diagnostics for details." : nil)
            return RuntimeStatusFace(text: text,
                detail: onlineDetail, tone: needsAttention ? .warning : .success,
                systemImage: needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        case false:
            return RuntimeStatusFace(text: "App reported a problem", detail: detail,
                tone: .failure, systemImage: "xmark.octagon.fill")
        case nil:
            return RuntimeStatusFace(text: hasError ? "App status is unavailable" : "App status has not been checked",
                detail: detail, tone: hasError ? .failure : .neutral,
                systemImage: hasError ? "xmark.octagon.fill" : "questionmark.circle")
        }
    }
}
