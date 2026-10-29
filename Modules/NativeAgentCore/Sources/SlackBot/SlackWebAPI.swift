import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SlackWebAPI.swift` | Shared HTTP response normalization for replies, history's injected session and explicit setup tokens; replies retain grant checks and record proofs through ConnectorActionReceipt, history/setup retain strict rejection; uploads and `requireConfiguredToken` |

/// Slack Web API HTTP mechanics, replies and uploads. Callers own token grants,
/// setup validation, history sessions and connection-proof policy.
public enum SlackWebAPI {
    public static func apiURL(_ method: String) -> URL {
        if let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_SLACK_LOOPBACK_API"],
           let url = URL(string: raw), ["127.0.0.1", "localhost"].contains(url.host ?? "") {
            return url.appendingPathComponent(method)
        }
        return URL(string: "https://slack.com/api/\(method)")!
    }

    /// Validate local Slack authentication without making a network request.
    /// Completion delivery uses this before recording that dispatch began so a
    /// missing credential remains a retryable pre-dispatch failure rather than
    /// an ambiguous external outcome.
    public static func requireConfiguredToken(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws {
        _ = try loadToken(dataRoot: dataRoot)
    }

    public static func postMessage(
        input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        tokenOverride: String? = nil
    ) async throws -> JSONValue {
        let input = input.filter { $0.value != .null && $0.value != .string("") }
        let channel = input["channel"]?.scalarText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = (input["text"] ?? input["message"])?.scalarText?
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
        let threadTs = (input["thread_ts"] ?? input["threadTs"])?.scalarText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = [
            "channel": channel,
            "text": text,
        ]
        if let threadTs, !threadTs.isEmpty {
            body["thread_ts"] = threadTs
        }
        if let metadata = try messageMetadata(input: input) {
            body["metadata"] = metadata
        }
        if let idempotencyKey = input["client_msg_id"]?.scalarText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !idempotencyKey.isEmpty {
            body["client_msg_id"] = idempotencyKey
        }
        let token = try resolvedToken(override: tokenOverride, dataRoot: dataRoot)
        var request = URLRequest(url: apiURL("chat.postMessage"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Slack accepts JSON without an explicit charset, but returns a
        // `missing_charset` response warning.
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return envelope(
            action: "slack.post_message",
            response: try await response(for: request, dataRoot: dataRoot)
        )
    }

    static func uploadFile(
        _ upload: SlackPreparedUpload,
        data: Data,
        channel: String,
        threadTs: String?,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        tokenOverride: String? = nil
    ) async throws -> JSONValue {
        let channel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channel.isEmpty else {
            throw NSError(domain: "NativeAgentSlack", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "slack.upload_file requires channel"
            ])
        }
        let name = upload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = name.isEmpty ? URL(fileURLWithPath: upload.path).lastPathComponent : name

        let uploadURLResponse = try await callForm(
            method: "files.getUploadURLExternal",
            form: [
                "filename": filename,
                "length": String(data.count),
            ],
            dataRoot: dataRoot,
            tokenOverride: tokenOverride
        )
        guard (uploadURLResponse["ok"] as? Bool) == true,
              let rawUploadURL = uploadURLResponse["upload_url"] as? String,
              let fileId = uploadURLResponse["file_id"] as? String,
              !fileId.isEmpty else {
            return envelope(
                action: "slack.upload_file",
                response: uploadURLResponse
            )
        }
        guard let uploadURL = trustedExternalUploadURL(rawUploadURL) else {
            return envelope(
                action: "slack.upload_file",
                response: ["ok": false, "error": "unsafe_upload_url"]
            )
        }

        // The bytes go only while the token is still granted (Disconnect may land mid-upload).
        _ = try resolvedToken(override: tokenOverride, dataRoot: dataRoot)
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
                ]
            )
        }

        let filesData = try JSONSerialization.data(
            withJSONObject: [["id": fileId, "title": filename]],
            options: []
        )
        let filesJSON = String(data: filesData, encoding: .utf8) ?? "[{\"id\":\"\(fileId)\"}]"
        var completeForm: [String: String] = [
            "files": filesJSON,
            "channel_id": channel,
        ]
        if let threadTs = threadTs?.trimmingCharacters(in: .whitespacesAndNewlines), !threadTs.isEmpty {
            completeForm["thread_ts"] = threadTs
        }
        let completeResponse = try await callForm(
            method: "files.completeUploadExternal",
            form: completeForm,
            dataRoot: dataRoot,
            tokenOverride: tokenOverride
        )
        return envelope(
            action: "slack.upload_file",
            response: completeResponse
        )
    }

    private static func callForm(
        method: String,
        form: [String: String],
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        tokenOverride: String? = nil
    ) async throws -> [String: Any] {
        let token = try resolvedToken(override: tokenOverride, dataRoot: dataRoot)
        var req = URLRequest(url: apiURL(method))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = formURLEncoded(form)

        return try await response(for: req, dataRoot: dataRoot)
    }

    private static func response(for request: URLRequest, dataRoot: URL) async throws -> [String: Any] {
        do {
            let parsed = try await response(for: request, session: .shared)
            await recordConnectionProof(parsed, dataRoot: dataRoot)
            return parsed
        }
        catch {
            await recordConnectionProof(["ok": false, "error": "transport_failed"], dataRoot: dataRoot)
            throw error
        }
    }

    public static func response(for request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: request)
        var parsed: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsed = object
        } else {
            parsed = [
                "ok": false,
                "error": "non_json_response",
                "rawPreview": String(data: data.prefix(300), encoding: .utf8) ?? "",
            ]
        }

        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            parsed["ok"] = false
            parsed["error"] = (parsed["error"] as? String) ?? "http_\(http.statusCode)"
            parsed["httpStatus"] = http.statusCode
        }
        return parsed
    }

    private static func recordConnectionProof(_ response: [String: Any], dataRoot: URL) async {
        do {
            _ = try await ConnectorActionReceipt.append(
                actionId: "slack.http", connectorId: "slack", name: nil,
                status: response["ok"] as? Bool == true ? "completed" : "failed",
                ok: response["ok"] as? Bool == true,
                dryRun: false, approvalId: nil, createdAt: ISO8601DateFormatter().string(from: Date()),
                output: .object([
                    "error": .string(response["error"] as? String ?? ""),
                    "httpStatus": (response["httpStatus"] as? Int).map { .int(Int64($0)) } ?? .null,
                ]), dataRoot: dataRoot)
        } catch {
            ModuleLog(category: "SlackBot")("Could not record transport proof: %@", error.localizedDescription)
        }
    }

    static func messageMetadata(input: [String: JSONValue]) throws -> [String: Any]? {
        guard case .object? = input["metadata"], let metadata = input["metadata"] else { return nil }
        return try JSONSerialization.jsonObject(with: Data(metadata.serialize(pretty: false).utf8)) as? [String: Any]
    }

    static func resolvedToken(override: String?, dataRoot: URL) throws -> String {
        if let override {
            let token = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw NSError(domain: "NativeAgentSlack", code: -401, userInfo: [
                    NSLocalizedDescriptionKey: "Slack token snapshot is empty"
                ])
            }
            // A snapshot a turn captured is used only while it is still the granted
            // token: every request and upload step checks, so Disconnect stops them all.
            guard (try? SlackCredentials.read(.bot, dataRoot: dataRoot)) == token else {
                throw NSError(domain: "NativeAgentSlack", code: -401, userInfo: [
                    NSLocalizedDescriptionKey: "Slack was disconnected; nothing more was sent"
                ])
            }
            return token
        }
        return try loadToken(dataRoot: dataRoot)
    }

    /// SlackCredentials owns tokens in Keychain.
    private static func loadToken(dataRoot root: URL = PersistenceCore.defaultDataRoot()) throws -> String {
        guard let token = try SlackCredentials.read(.bot, dataRoot: root) else {
            throw NSError(domain: "NativeAgentSlack", code: -401, userInfo: [
                NSLocalizedDescriptionKey: "Slack token is not configured. Paste the Slack OAuth token in Connectors > Slack."
            ])
        }
        return token
    }

    static func envelope(
        action: String,
        response: [String: Any]
    ) -> JSONValue {
        let ok = (response["ok"] as? Bool) == true
        var obj: [String: JSONValue] = [
            "actionId": .string(action),
            "connectorId": .string("slack"),
            "ok": .bool(ok),
            "status": .string(ok ? "completed" : "failed"),
            "response": JSONValue(fromFoundation: response),
        ]
        if let error = response["error"] as? String, !error.isEmpty {
            obj["error"] = .string(error)
            // What to do next, in words, for the codes that have one.
            let fix: String? = switch error {
            case "not_authed", "invalid_auth", "token_revoked", "account_inactive": "The owner can sign in to Slack by requesting a setup card in chat or opening Connectors in Advanced view."
            case "missing_scope": "The owner must add \((response["needed"] as? String) ?? "the required scope") in the Slack app settings, then sign in to Slack by requesting a setup card in chat or opening Connectors in Advanced view."
            case "not_in_channel": "The bot isn't in that channel; invite it there with /invite first."
            case "ratelimited": "Slack is rate limiting; wait a minute before trying again."
            default: nil
            }
            if let fix { obj["fix"] = .string(fix) }
        }
        return redactReceipt(.object(obj))
    }

    static func redactReceipt(_ value: JSONValue) -> JSONValue {
        SlackTokenRedactor.redactValue(value)
    }

    /// `files.getUploadURLExternal` may return a short-lived signed URL, but
    /// the file body must still only leave for Slack's HTTPS upload domain.
    static func trustedExternalUploadURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              (host == "files.slack.com" || host.hasSuffix(".files.slack.com")),
              url.port == nil || url.port == 443
        else { return nil }
        return url
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

private enum SlackTokenRedactor {
    private static let slackToken = try! NSRegularExpression(
        pattern: "\\b(?:xox[baprs]-[A-Za-z0-9-]{20,}|xapp-[A-Za-z0-9-]{20,}|xoxe(?:\\.xoxp)?-[A-Za-z0-9-]{20,})\\b",
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
            return .object(object.reduce(into: [:]) { redacted, pair in
                // `files.getUploadURLExternal` returns a short-lived signed
                // upload credential. A partial/malformed Slack response can
                // still flow through the ordinary failure envelope, so scrub
                // it by field identity even when its value does not resemble a
                // bot token.
                if pair.key.lowercased() == "upload_url" {
                    redacted[pair.key] = .string("[REDACTED_SLACK_UPLOAD_URL]")
                } else {
                    redacted[pair.key] = redactValue(pair.value)
                }
            })
        default:
            return value
        }
    }
}
