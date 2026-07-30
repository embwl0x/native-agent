import Foundation

// MARK: - InboxAction (must match iOS definition exactly)
// Redeclared here so Mac side compiles without importing iOS module.
// Wire format is identical — keep in sync with iOS iCloudSyncEngine.swift.

struct InboxAction: Codable {
    var msgId: String
    var clientId: String
    var action: String
    var payload: [String: String]
    var createdAt: String
    var protocolVersion: Int?
    var transactionId: String?
    /// C.1: HMAC-SHA256 of canonical JSON body (keys sorted, "signature" key excluded).
    /// TODO(iOS-side): iOS sender must compute and populate this field.
    var signature: String?
}
