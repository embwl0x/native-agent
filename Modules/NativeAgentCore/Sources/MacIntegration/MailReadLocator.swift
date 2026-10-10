import Foundation
import PersistenceCore

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
        func text(_ value: JSONValue?) -> String? {
            switch value {
            case .string(let value): value
            case .int(let value): String(value)
            case .double(let value): String(value)
            case .bool(let value): value ? "true" : "false"
            default: nil
            }
        }
        guard let id = text(input["message_id"]).flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }), id > 0,
              let messageID = text(input["expected_message_id"]), messageID.count < 4096 else { return nil }
        let account = text(input["expected_account"]).flatMap { $0.isEmpty || $0.count > 512 ? nil : $0 }
        let accountID = text(input["expected_account_id"]).flatMap { $0.isEmpty || $0.count > 512 ? nil : $0 }
        let position = text(input["position"]).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 && $0 < 10_000_000 ? $0 : nil }
        guard !messageID.isEmpty || (allowMissingMessageID && (account != nil || position != nil)) else { return nil }
        return Self(id: id, messageID: messageID, account: account, accountID: accountID, position: position)
    }
}
