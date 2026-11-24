import Foundation
import MacNerves
import PersistenceCore
// Blueprint: | `SurfaceRuntimeStatusModels.swift` | Browser recovery availability |

public struct BrowserRuntimeStatus: Codable, Hashable, Sendable {
    public var status: String
    public var sourcePath: String?
    public var screenshotPath: String?
    public var activeRuns: [BrowserRun]?
    public var receiptCount: Int?
    public var latestReceipt: BrowserRun?
    public var createdAt: String?
    public var recoveryIssue: String?
    public var admissionIssues: [JSONValue]?
    public var unavailableRuns: [JSONValue]?
    public init(status: String, sourcePath: String? = nil, screenshotPath: String? = nil, activeRuns: [BrowserRun]? = nil, receiptCount: Int? = nil,
        latestReceipt: BrowserRun? = nil, createdAt: String? = nil,
                recoveryIssue: String? = nil, admissionIssues: [JSONValue]? = nil, unavailableRuns: [JSONValue]? = nil) {
        self.status = status
        self.sourcePath = sourcePath
        self.screenshotPath = screenshotPath
        self.activeRuns = activeRuns
        self.receiptCount = receiptCount
        self.latestReceipt = latestReceipt
        self.createdAt = createdAt
        self.recoveryIssue = recoveryIssue
        self.admissionIssues = admissionIssues
        self.unavailableRuns = unavailableRuns
    }
}
