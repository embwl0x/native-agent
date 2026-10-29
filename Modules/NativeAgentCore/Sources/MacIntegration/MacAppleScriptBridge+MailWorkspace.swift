import Foundation
import MacControl
import PersistenceCore
// Blueprint: | `MacAppleScriptBridge+MailWorkspace.swift` | `MacAppleScriptBridge`: bounded workspace-read orchestration and mailbox scope validation |

extension MacAppleScriptBridge {
    /// Bounded mailbox reads with opaque owner IDs. Transport fields are encoded
    /// separately so message content can never manufacture another message ID.
    static func mailWorkspaceRead(input: [String: JSONValue], query: [String]? = nil) async throws -> JSONValue {
        var input = input
        if input["message_id"] != nil, input["expected_message_id"] == nil { input["expected_message_id"] = .string("") }
        guard let scope = mailReadScope(input) else {
            return .object(["status": .string("failed"), "integration": .string("mail"),
                "reason": .string("unsupported_mailbox"),
                "message": .string("Accepted scopes: inbox, sent, drafts. scope and mailbox must agree when both are supplied.")])
        }
        if input["message_id"] != nil && MailReadLocator.parse(input, allowMissingMessageID: true) == nil {
            return .object(["status": .string("failed"), "integration": .string("mail"),
                "reason": .string("invalid_message_locator"),
                "message": .string("Call mail_list_recent without message_id, then copy scope, message_id, expected_message_id, expected_account, expected_account_id and position from the same row to read it.")])
        }
        do {
            let local = mailLocalRead(input)
            if let mismatch = local.accountMismatch {
                return .object(["status": .string("failed"), "integration": .string("mail"),
                    "reason": .string("account_mismatch"), "message": .string(mismatch)])
            }
            if let row = local.row {
                return .object(["status": .string("completed"), "count": .int(1),
                    "messages": .array([.object(row)]), "scope": .string(scope), "detail": .bool(true)])
            }
            try Task.checkCancellation()
            let raw = try await runAppleScript(mailWorkspaceScript(input: input), bundleID: "com.apple.mail")
            if let setup = readSetupEnvelope(raw: raw, integration: "mail") { return setup }
            if raw == "__MESSAGE_CHANGED__" {
                return .object(["status": .string("failed"), "integration": .string("mail"),
                    "reason": .string("message_changed_or_moved_refresh_inbox"),
                    "message": .string("The message no longer matches this mailbox locator. Call mail_list_recent without message_id in the same scope and use the identifiers from one fresh row; do not reuse its old position.")])
            }
            if input["message_id"] == nil { return mailIndexPage(header: raw, input: input, query: query) }
            let rows = parseMailWorkspaceRecords(raw)
            if rows.isEmpty { return failedEnvelope(integration: "mail", reason: "message_not_in_inbox") }
            return .object(["status": .string("completed"), "count": .int(Int64(rows.count)),
                "messages": .array(rows.map { row in
                    guard case .object(var object) = row else { return row }
                    object["scope"] = .string(scope)
                    object["attachments_status"] = .string(local.attachments)
                    return .object(object)
                }), "scope": .string(scope), "detail": .bool(true)])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "mail", app: app)
        } catch let error as NSError where error.domain == "NativeAgentAppleScript" && [-1712, -1001, AppleScriptExecution.appleScriptOutcomeUnknownCode].contains(error.code) {
            // A read changes nothing, so the "outcome unknown" caution for sends does not apply.
            // One attempt per request: an immediate rerun would wait on the same dialog or busy Mail.
            let observed = (error.userInfo["observation"] as? String).map { " " + $0 } ?? ""
            return .object(["status": .string("failed"), "integration": .string("mail"), "error_code": .int(Int64(error.code)),
                "reason": .string(error.userInfo["state"] as? String ?? "app_timeout"),
                "error": .string("Mail did not answer this read in time (it may be showing a dialog or busy syncing).\(observed) Nothing was changed. When Mail is ready, call mail_list_recent again; for a message body, use the scope, identifiers and position from a fresh row.")])
        } catch { return failedEnvelope(integration: "mail", error: error) }
    }

    static func mailReadScope(_ input: [String: JSONValue]) -> String? {
        let value = input["scope"] ?? input["mailbox"] ?? .string("inbox")
        guard case .string(let scope) = value, ["inbox", "sent", "drafts"].contains(scope),
              input["scope"] == nil || input["mailbox"] == nil || input["scope"] == input["mailbox"] else { return nil }
        return scope
    }
}
