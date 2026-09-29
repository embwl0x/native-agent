import Foundation

public struct CodexDeviceLogin: Codable, Hashable, Sendable {
    public var running: Bool?
    public var pid: Int?
    public var url: String?
    public var code: String?
    public var expiresInMinutes: Int?
    public var openedBrowser: Bool?
    public var codexHome: String?
    public var loginCommand: String?
    public var detail: String?
    public var exitCode: Int?
    public var startedAt: String?
    public var finishedAt: String?
}
