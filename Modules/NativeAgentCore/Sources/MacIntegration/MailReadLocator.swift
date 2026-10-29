import Foundation
import PersistenceCore
// Blueprint: | `MailReadLocator.swift` | `MailReadLocator` |

/// Exact inbox locator for reads. An RFC ID is required for mutations.
public struct MailReadLocator {
    public let id: Int64
    public let messageID: String
    public let account: String?
    /// Mail's account id: the host of the message's mailbox URL in Mail's index.
    public let accountID: String?
    public let position: Int?
    /// The fields that carry one row's exact identity from a list to a later read or action.
    public static let fields: Set<String> = ["message_id", "expected_message_id", "expected_account", "expected_account_id", "position", "scope"]

    public static func parse(_ input: [String: JSONValue], allowMissingMessageID: Bool = false) -> Self? {
        guard let id = input["message_id"]?.scalarText.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }), id > 0,
              let messageID = input["expected_message_id"]?.scalarText, messageID.count < 4096 else { return nil }
        let account = input["expected_account"]?.scalarText.flatMap { $0.isEmpty || $0.count > 512 ? nil : $0 }
        let accountID = input["expected_account_id"]?.scalarText.flatMap { $0.isEmpty || $0.count > 512 ? nil : $0 }
        let position = input["position"]?.scalarText.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 && $0 < 10_000_000 ? $0 : nil }
        guard !messageID.isEmpty || (allowMissingMessageID && (account != nil || position != nil)) else { return nil }
        return Self(id: id, messageID: messageID, account: account, accountID: accountID, position: position)
    }
}
