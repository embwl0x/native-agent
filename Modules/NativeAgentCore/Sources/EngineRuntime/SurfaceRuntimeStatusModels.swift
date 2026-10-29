import Foundation
import Browser
// Blueprint: | `SurfaceRuntimeStatusModels.swift` | Approval-backed notification pending status and browser status models; no unwritten notification receipt or inferred authorization fields; browser status exposes capture paths, with no unused profile path |

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
    public init(status: String, sourcePath: String? = nil, screenshotPath: String? = nil, activeRuns: [BrowserRun]? = nil, receiptCount: Int? = nil, latestReceipt: BrowserRun? = nil, createdAt: String? = nil) {
        self.status = status
        self.sourcePath = sourcePath
        self.screenshotPath = screenshotPath
        self.activeRuns = activeRuns
        self.receiptCount = receiptCount
        self.latestReceipt = latestReceipt
        self.createdAt = createdAt
    }
}

public typealias BrowserRun = Browser.BrowserRun
public typealias NativeActionReceipt = Browser.NativeActionReceipt
