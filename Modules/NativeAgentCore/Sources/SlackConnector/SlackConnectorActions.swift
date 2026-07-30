import Foundation
import NativeAgentCore
import PersistenceCore

public enum SlackConnectorActions {
    private static let baseURL = URL(string: "https://slack.com/api")!

    /// Validate local Slack authentication without making a network request.
    /// Completion delivery uses this before recording that dispatch began so a
    /// missing credential remains a retryable pre-dispatch failure rather than
    /// an ambiguous external outcome.
    public static func requireConfiguredToken(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws {
        _ = try loadToken(dataRoot: dataRoot)
    }

    public static func status(input: [String: JSONValue]) async throws -> JSONValue {
        _ = input
        let response = try await call(method: "auth.test", httpMethod: "POST")
        return envelope(
            action: "slack.status",
            response: response,
            successStatus: "completed"
        )
    }

    public static func listChannels(input: [String: JSONValue]) async throws -> JSONValue {
        let limit = clamp(int(input["limit"], default: 100), min: 1, max: 1000)
        let types = string(input["types"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = try await call(
            method: "conversations.list",
            httpMethod: "GET",
            params: [
                "limit": String(limit),
                "exclude_archived": "true",
                "types": types?.isEmpty == false ? types! : "public_channel,private_channel,mpim,im",
            ]
        )
        return envelope(
            action: "slack.list_channels",
            response: response,
            successStatus: "completed"
        )
    }

    public static func searchMessages(input: [String: JSONValue]) async throws -> JSONValue {
        let query = string(input["query"] ?? input["q"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            throw NSError(domain: "NativeAgentSlack", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "slack.search_messages requires query"
            ])
        }
        let count = clamp(int(input["count"] ?? input["limit"], default: 20), min: 1, max: 100)
        let response = try await call(
            method: "search.messages",
            httpMethod: "GET",
            params: [
                "query": query,
                "count": String(count),
            ]
        )
        return envelope(
            action: "slack.search_messages",
            response: response,
            successStatus: "completed"
        )
    }

    public static func postMessage(
        input: [String: JSONValue],
        idempotencyKey: String? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> JSONValue {
        let channel = string(input["channel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = string(input["text"] ?? input["message"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !channel.isEmpty else {
            throw NSError(domain: "NativeAgentSlack", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "slack.post_message requires channel"
            ])
        }
        guard !text.isEmpty else {
            throw NSError(domain: "NativeAgentSlack", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "slack.post_message requires text"
            ])
        }
        let threadTs = string(input["thread_ts"] ?? input["threadTs"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = [
            "channel": channel,
            "text": text,
        ]
        if let threadTs, !threadTs.isEmpty {
            body["thread_ts"] = threadTs
        }
        if let idempotencyKey = idempotencyKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !idempotencyKey.isEmpty {
            body["client_msg_id"] = idempotencyKey
        }
        let response = try await call(
            method: "chat.postMessage",
            httpMethod: "POST",
            jsonBody: body,
            dataRoot: dataRoot
        )
        return envelope(
            action: "slack.post_message",
            response: response,
            successStatus: "completed"
        )
    }

    public static func uploadFile(input: [String: JSONValue]) async throws -> JSONValue {
        let channel = string(input["channel"] ?? input["channel_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = string(input["file_path"] ?? input["path"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !channel.isEmpty else {
            throw NSError(domain: "NativeAgentSlack", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "slack.upload_file requires channel"
            ])
        }
        guard !path.isEmpty else {
            throw NSError(domain: "NativeAgentSlack", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "slack.upload_file requires file_path"
            ])
        }

        let fileURL = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            throw NSError(domain: "NativeAgentSlack", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "slack.upload_file file is empty"
            ])
        }
        let filename = string(input["filename"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? fileURL.lastPathComponent
        let title = string(input["title"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? filename
        let threadTs = string(input["thread_ts"] ?? input["threadTs"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let initialComment = string(input["initial_comment"] ?? input["initialComment"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let uploadURLResponse = try await callForm(
            method: "files.getUploadURLExternal",
            form: [
                "filename": filename,
                "length": String(data.count),
            ]
        )
        guard (uploadURLResponse["ok"] as? Bool) == true,
              let rawUploadURL = uploadURLResponse["upload_url"] as? String,
              let uploadURL = URL(string: rawUploadURL),
              let fileId = uploadURLResponse["file_id"] as? String,
              !fileId.isEmpty else {
            return envelope(
                action: "slack.upload_file",
                response: uploadURLResponse,
                successStatus: "completed"
            )
        }

        var uploadReq = URLRequest(url: uploadURL)
        uploadReq.httpMethod = "POST"
        uploadReq.timeoutInterval = 60
        uploadReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadReq.httpBody = data
        let (uploadData, uploadResp) = try await URLSession.shared.data(for: uploadReq)
        let uploadStatus = (uploadResp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(uploadStatus) else {
            return envelope(
                action: "slack.upload_file",
                response: [
                    "ok": false,
                    "error": "upload_http_\(uploadStatus)",
                    "rawPreview": String(data: uploadData.prefix(300), encoding: .utf8) ?? "",
                ],
                successStatus: "completed"
            )
        }

        let filesData = try JSONSerialization.data(
            withJSONObject: [["id": fileId, "title": title]],
            options: []
        )
        let filesJSON = String(data: filesData, encoding: .utf8) ?? "[{\"id\":\"\(fileId)\"}]"
        var completeForm: [String: String] = [
            "files": filesJSON,
            "channel_id": channel,
        ]
        if let threadTs { completeForm["thread_ts"] = threadTs }
        if let initialComment { completeForm["initial_comment"] = initialComment }
        let completeResponse = try await callForm(
            method: "files.completeUploadExternal",
            form: completeForm
        )
        return envelope(
            action: "slack.upload_file",
            response: completeResponse,
            successStatus: "completed"
        )
    }

    public static func listUnreads(input: [String: JSONValue]) async throws -> JSONValue {
        _ = input
        return .object([
            "actionId": .string("slack.list_unreads"),
            "connectorId": .string("slack"),
            "ok": .bool(false),
            "status": .string("failed"),
            "error": .string("Slack unread counts are not available from the bot-token Web API path yet."),
        ])
    }

    private static func call(
        method: String,
        httpMethod: String,
        params: [String: String] = [:],
        jsonBody: [String: Any]? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> [String: Any] {
        let token = try loadToken(dataRoot: dataRoot)
        let url = try requestURL(method: method, params: httpMethod == "GET" ? params : [:])
        var req = URLRequest(url: url)
        req.httpMethod = httpMethod
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if httpMethod != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let bodyObject: [String: Any]
            if let jsonBody {
                bodyObject = jsonBody
            } else {
                bodyObject = params.reduce(into: [String: Any]()) { out, pair in
                    out[pair.key] = pair.value
                }
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: bodyObject)
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let parsed: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsed = object
        } else {
            parsed = [
                "ok": false,
                "error": "non_json_response",
                "rawPreview": String(data: data.prefix(300), encoding: .utf8) ?? "",
            ]
        }

        guard let http = resp as? HTTPURLResponse else { return parsed }
        guard http.statusCode < 400 else {
            var failed = parsed
            failed["ok"] = false
            failed["error"] = (parsed["error"] as? String) ?? "http_\(http.statusCode)"
            failed["httpStatus"] = http.statusCode
            return failed
        }
        return parsed
    }

    private static func callForm(
        method: String,
        form: [String: String]
    ) async throws -> [String: Any] {
        let token = try loadToken()
        let url = try requestURL(method: method, params: [:])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = formURLEncoded(form)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let parsed: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsed = object
        } else {
            parsed = [
                "ok": false,
                "error": "non_json_response",
                "rawPreview": String(data: data.prefix(300), encoding: .utf8) ?? "",
            ]
        }

        guard let http = resp as? HTTPURLResponse else { return parsed }
        guard http.statusCode < 400 else {
            var failed = parsed
            failed["ok"] = false
            failed["error"] = (parsed["error"] as? String) ?? "http_\(http.statusCode)"
            failed["httpStatus"] = http.statusCode
            return failed
        }
        return parsed
    }

    private static func requestURL(method: String, params: [String: String]) throws -> URL {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent(method),
            resolvingAgainstBaseURL: false
        )!
        if !params.isEmpty {
            comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name }
        }
        guard let url = comps.url else {
            throw NSError(domain: "NativeAgentSlack", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "Could not build Slack API URL."
            ])
        }
        return url
    }

    private static func loadToken(dataRoot root: URL = PersistenceCore.defaultDataRoot()) throws -> String {
        let paths = [
            root
                .appendingPathComponent("oauth_tokens", isDirectory: true)
                .appendingPathComponent("slack.json"),
            root
                .appendingPathComponent("connectors", isDirectory: true)
                .appendingPathComponent("slack", isDirectory: true)
                .appendingPathComponent("auth.json"),
        ]
        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = object["access_token"] as? String,
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw NSError(domain: "NativeAgentSlack", code: -401, userInfo: [
            NSLocalizedDescriptionKey: "Slack token is not configured. Paste the Slack OAuth token in Connectors > Slack."
        ])
    }

    private static func envelope(
        action: String,
        response: [String: Any],
        successStatus: String
    ) -> JSONValue {
        let ok = (response["ok"] as? Bool) == true
        var obj: [String: JSONValue] = [
            "actionId": .string(action),
            "connectorId": .string("slack"),
            "ok": .bool(ok),
            "status": .string(ok ? successStatus : "failed"),
            "response": JSONValue(fromFoundation: response),
        ]
        if let error = response["error"] as? String, !error.isEmpty {
            obj["error"] = .string(error)
        }
        return SlackConnectorSecretRedactor.redactValue(.object(obj))
    }

    private static func string(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    private static func int(_ raw: JSONValue?, default defaultValue: Int) -> Int {
        switch raw {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        case .bool(let b): return b ? 1 : 0
        default: return defaultValue
        }
    }

    private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.max(minValue, Swift.min(maxValue, value))
    }

    private static func formURLEncoded(_ form: [String: String]) -> Data {
        let encoded = form
            .sorted { $0.key < $1.key }
            .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private enum SlackConnectorSecretRedactor {
    private static let slackToken = try! NSRegularExpression(
        pattern: "\\bxox[baprs]-[A-Za-z0-9-]{20,}\\b",
        options: []
    )

    static func redactValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let raw):
            let range = NSRange(location: 0, length: (raw as NSString).length)
            return .string(slackToken.stringByReplacingMatches(
                in: raw,
                options: [],
                range: range,
                withTemplate: "[REDACTED_SLACK_TOKEN]"
            ))
        case .array(let items):
            return .array(items.map { redactValue($0) })
        case .object(let object):
            return .object(object.mapValues { redactValue($0) })
        default:
            return value
        }
    }
}
