import Foundation
import Browser

public struct NotificationRuntimeStatus: Codable, Hashable {
    public var status: String
    public var authorization: String?
    public var pendingApprovals: Int?
    public var receiptCount: Int?
    public var latestReceipt: NativeActionReceipt?
    public var createdAt: String?
    public init(status: String, authorization: String? = nil, pendingApprovals: Int? = nil, receiptCount: Int? = nil, latestReceipt: NativeActionReceipt? = nil, createdAt: String? = nil) {
        self.status = status
        self.authorization = authorization
        self.pendingApprovals = pendingApprovals
        self.receiptCount = receiptCount
        self.latestReceipt = latestReceipt
        self.createdAt = createdAt
    }
}

public struct BrowserRuntimeStatus: Codable, Hashable {
    public var status: String
    public var profilePath: String?
    public var sourcePath: String?
    public var screenshotPath: String?
    public var approvedDomains: [String]?
    public var domainPolicy: String?
    public var activeRuns: [BrowserRun]?
    public var receiptCount: Int?
    public var latestReceipt: BrowserRun?
    public var createdAt: String?
    public init(status: String, profilePath: String? = nil, sourcePath: String? = nil, screenshotPath: String? = nil, approvedDomains: [String]? = nil, domainPolicy: String? = nil, activeRuns: [BrowserRun]? = nil, receiptCount: Int? = nil, latestReceipt: BrowserRun? = nil, createdAt: String? = nil) {
        self.status = status
        self.profilePath = profilePath
        self.sourcePath = sourcePath
        self.screenshotPath = screenshotPath
        self.approvedDomains = approvedDomains
        self.domainPolicy = domainPolicy
        self.activeRuns = activeRuns
        self.receiptCount = receiptCount
        self.latestReceipt = latestReceipt
        self.createdAt = createdAt
    }
}

public typealias BrowserRun = Browser.BrowserRun
public typealias NativeActionReceipt = Browser.NativeActionReceipt
