import Foundation
import PersistenceCore
// Blueprint: | `SlackNotificationDelivery.swift` | `SlackWebAPI.notificationOutcome`: checked preflight, API refusal and uncertain dispatch |

extension SlackWebAPI {
    public static func notificationOutcome(input: [String: JSONValue], dataRoot: URL) async -> NotificationDeliveryOutcome {
        do { try requireConfiguredToken(dataRoot: dataRoot) }
        catch { return .notDelivered(reason: error.localizedDescription) }
        guard let channel = input["channel"]?.stringValue, !channel.isEmpty,
              let text = input["text"]?.stringValue, !text.isEmpty else {
            return .notDelivered(reason: "Slack notification needs a channel and text")
        }
        guard !Task.isCancelled else { return .notDelivered(reason: "cancelled before dispatch") }
        do {
            let value = try await postMessage(input: input, dataRoot: dataRoot)
            guard let response = value.objectValue?["response"]?.objectValue else {
                return .unknown(sent: true, reason: "Slack response envelope is unreadable")
            }
            if response["ok"] == .bool(true), let ts = response["ts"]?.stringValue, !ts.isEmpty,
               try !hasTruncationWarning(value) {
                return .delivered
            }
            if let status = response["httpStatus"]?.exactIntegerValue, status >= 500 || status == 408 {
                return .unknown(sent: true, reason: "Slack returned an inconclusive server failure")
            }
            if try isProvenMessageRejection(value), let reason = response["error"]?.stringValue {
                return .notDelivered(reason: reason)
            }
            return .unknown(sent: true, reason: "Slack did not return a checked message acceptance or API rejection")
        } catch {
            return Self.notificationFailure(error)
        }
    }

    static func notificationFailure(_ error: Error) -> NotificationDeliveryOutcome {
        if let failure = error as? NotificationDeliveryFailure { return failure.outcome }
        if let url = error as? URLError,
           [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .internationalRoamingOff, .dataNotAllowed].contains(url.code) {
            return .notDelivered(reason: error.localizedDescription)
        }
        // Token revocation/serialization are checked by postMessage before its effect.
        let ns = error as NSError
        if ns.domain == "NativeAgentSlack", [-400, -401].contains(ns.code) {
            return .notDelivered(reason: error.localizedDescription)
        }
        return .unknown(sent: true, reason: error.localizedDescription)
    }
}
