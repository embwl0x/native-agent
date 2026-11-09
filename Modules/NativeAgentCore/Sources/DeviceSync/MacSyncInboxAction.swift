import Foundation
import NativeAgentShared
// Blueprint: | `MacSyncInboxAction.swift` | Shared `InboxAction` alias and checked remote message/transaction filename identities |

typealias InboxAction = NativeAgentShared.InboxAction

/// Remote UUIDs become filenames, so validate them before path derivation or ledger writes. Preserve original spelling because the phone uses it as wire
/// correlation identity.
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
        guard candidate.deletingLastPathComponent().path == base.path else { return nil }
        return candidate
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36, let parsed = UUID(uuidString: value) else {
            return false
        }
        return parsed.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }
}
