import Foundation
import Browser
import PersistenceCore
// Blueprint: | `SurfaceRuntimeStatusModels.swift` | Approval-backed notification pending status and browser status models; browser preserves owner recovery cause and named damaged-run projections alongside capture paths |

public struct NotificationRuntimeStatus: Codable, Hashable {
    public var status: String
    public var pendingApprovals: Int?
    public var createdAt: String?
    public init(status: String, pendingApprovals: Int? = nil, createdAt: String? = nil) {
        self.status = status
        self.pendingApprovals = pendingApprovals
        self.createdAt = createdAt
    }
}

public struct BrowserRuntimeStatus: Codable, Hashable {
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
    public init(status: String, sourcePath: String? = nil, screenshotPath: String? = nil, activeRuns: [BrowserRun]? = nil, receiptCount: Int? = nil, latestReceipt: BrowserRun? = nil, createdAt: String? = nil,
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

public typealias BrowserRun = Browser.BrowserRun
public typealias NativeActionReceipt = Browser.NativeActionReceipt
