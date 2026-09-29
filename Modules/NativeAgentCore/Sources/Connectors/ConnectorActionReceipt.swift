import Foundation

public struct ConnectorActionReceipt: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var actionId: String
    public var connectorId: String?
    public var name: String?
    public var status: String
    public var dryRun: Bool?
    public var approvalId: String?
    public var createdAt: String?
}
