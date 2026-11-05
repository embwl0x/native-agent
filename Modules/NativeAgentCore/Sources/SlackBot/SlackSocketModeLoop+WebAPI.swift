import Foundation
import PersistenceCore
import NativeAgentShared
// Blueprint: | `SlackSocketModeLoop+WebAPI.swift` | `SlackSocketModeLoop.slackAPI`: checked reads for accepted-reply reconciliation |

extension SlackSocketModeLoop {
    func slackAPI(method: String, httpMethod: String, params: [String: String]) async throws -> [String: JSONValue] {
        guard var components = URLComponents(url: Self.apiURL(method), resolvingAgainstBaseURL: false) else {
            throw SlackSocketModeError.api("Could not build Slack API URL for \(method)")
        }
        if httpMethod == "GET" {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name }
        }
        guard let url = components.url else {
            throw SlackSocketModeError.api("Could not build Slack API URL for \(method)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = httpMethod
        req.timeoutInterval = 30
        req.setValue("Bearer \(config.botToken)", forHTTPHeaderField: "Authorization")
        if httpMethod != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: params)
        }
        let parsed = try await SlackWebAPI.response(for: req, session: session)
        guard parsed["error"] as? String != "non_json_response",
              case .object(let obj) = JSONValue(fromFoundation: parsed) else {
            throw SlackSocketModeError.api("\(method) returned non-object JSON")
        }
        if let status = parsed["httpStatus"] as? Int {
            throw SlackSocketModeError.api("\(method) HTTP \(status)")
        }
        return obj
    }
}
