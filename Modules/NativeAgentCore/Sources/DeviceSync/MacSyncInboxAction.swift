import Foundation
import NativeAgentShared
// Blueprint: | `MacSyncInboxAction.swift` | Shared `InboxAction` alias and checked remote message/transaction filename identities |

typealias InboxAction = NativeAgentShared.InboxAction

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
