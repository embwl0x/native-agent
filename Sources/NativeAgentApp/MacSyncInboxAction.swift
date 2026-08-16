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

/// File-boundary identity for an iOS action. Both identifiers originate in a
/// remote envelope and are used as local/iCloud filenames, so they must be
/// canonical UUID strings before any path is derived or any transaction state
/// is written. The original spelling is retained because it is also the wire
/// correlation identity expected by the phone.
struct ValidatedInboxActionIDs: Equatable, Sendable {
    let messageID: String
    let transactionID: String
}

enum InboxActionFileBoundary {
    static func validatedIDs(for action: InboxAction) -> ValidatedInboxActionIDs? {
        guard isCanonicalUUID(action.msgId) else { return nil }
        let transactionID = action.transactionId ?? action.msgId
        guard isCanonicalUUID(transactionID) else { return nil }
        return ValidatedInboxActionIDs(
            messageID: action.msgId,
            transactionID: transactionID
        )
    }

    static func jsonURL(in directory: URL, validatedID: String) -> URL? {
        guard isCanonicalUUID(validatedID) else { return nil }
        let base = directory.standardizedFileURL
        let candidate = base
            .appendingPathComponent(validatedID, isDirectory: false)
            .appendingPathExtension("json")
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == base else { return nil }
        return candidate
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36, let parsed = UUID(uuidString: value) else {
            return false
        }
        return parsed.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }
}
