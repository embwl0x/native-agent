import Foundation
// Blueprint: | `CountStatusValues.swift` | `CountStatusValues`: phone, transport, health, capture, download and notice facts drawn through the counts slot |

public struct CountStatusValues: FaceValue {
    public var phoneConnection: NAPhoneConnection?
    public var phoneStanding: NAPhoneStanding?
    public var phoneStatus: String?
    public var pairingError: String?
    public var isCheckingPairing: Bool?
    public var health: RuntimeHealth?
    public var capture: ActivityCaptureFace?
    public var download: EmbeddingDownloadFace?
    public var telegram: TransportStatusFace?
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

public struct TransportStatusFace: FaceValue {
    public let enabled: Bool?
    public let pollerRunning: Bool?
    public let lastError: String?
    public let credentialIssue: String?
    public let routingIssue: String?
    public let readIssue: String?

    public init(enabled: Bool?, pollerRunning: Bool?, lastError: String?, credentialIssue: String?, routingIssue: String?, readIssue: String?) {
        self.enabled = enabled
        self.pollerRunning = pollerRunning
        self.lastError = lastError
        self.credentialIssue = credentialIssue
        self.routingIssue = routingIssue
        self.readIssue = readIssue
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

public struct RuntimeStatusFace: FaceValue {
    public enum Tone: FaceValue { case neutral, success, warning, failure }
    public let text: String
    public let detail: String?
    public let tone: Tone
    public let systemImage: String

    public static func project(health: RuntimeHealth?, lastRefreshError: String?) -> RuntimeStatusFace {
        let hasError = lastRefreshError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let detail = hasError ? "Some sections didn't refresh. The details are in the log." : nil
        switch health?.ok {
        case true:
            return RuntimeStatusFace(text: hasError ? "App is online; some app data is unavailable" : "App is online",
                detail: detail, tone: hasError ? .warning : .success,
                systemImage: hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
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
