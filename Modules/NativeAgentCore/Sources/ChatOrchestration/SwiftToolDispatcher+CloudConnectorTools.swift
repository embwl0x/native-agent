import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftToolDispatcher {
    private struct CloudConnectorAuth {
        var accessToken: String
        var refreshToken: String?
        var clientId: String?
        var clientSecret: String?
        var object: [String: Any]
        var path: URL
    }

    func impl_gmail_status(input _: [String: JSONValue]) async -> JSONValue {
        await cloudConnectorRead(connector: "gmail") { token in
            var request = URLRequest(
                url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
            )
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let object = try await cloudConnectorJSONObject(
                request,
                connector: "gmail"
            )
            return .object([
                "status": .string("ok"),
                "email": Self.cloudString(object["emailAddress"]).map(JSONValue.string) ?? .null,
                "messagesTotal": Self.cloudInt(object["messagesTotal"]).map {
                    .int(Int64($0))
                } ?? .null,
                "threadsTotal": Self.cloudInt(object["threadsTotal"]).map {
                    .int(Int64($0))
                } ?? .null,
            ])
        }
    }

    func impl_gmail_search(input: [String: JSONValue]) async -> JSONValue {
        let query = Self.cloudInputString(input["query"] ?? input["q"]) ?? ""
        let limit = max(1, min(Self.cloudInputInt(input["limit"]) ?? 10, 20))
        return await cloudConnectorRead(connector: "gmail") { token in
            var components = URLComponents(
                string: "https://gmail.googleapis.com/gmail/v1/users/me/messages"
            )!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "maxResults", value: String(limit)),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let listing = try await cloudConnectorJSONObject(
                request,
                connector: "gmail"
            )
            let rows = (listing["messages"] as? [[String: Any]] ?? []).prefix(limit)
            var messages: [JSONValue] = []
            for row in rows {
                guard let id = Self.cloudString(row["id"]) else { continue }
                var metadataRequest = URLRequest(
                    url: URL(
                        string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(Self.cloudPath(id))?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Date"
                    )!
                )
                metadataRequest.setValue(
                    "Bearer \(token)",
                    forHTTPHeaderField: "Authorization"
                )
                let message = try await cloudConnectorJSONObject(
                    metadataRequest,
                    connector: "gmail"
                )
                messages.append(Self.gmailMessageProjection(message, includeBody: false))
            }
            return .object([
                "status": .string("ok"),
                "query": .string(query),
                "messages": .array(messages),
                "resultCount": .int(Int64(messages.count)),
                "resultSizeEstimate": Self.cloudInt(listing["resultSizeEstimate"]).map {
                    .int(Int64($0))
                } ?? .null,
            ])
        }
    }

    func impl_gmail_read(input: [String: JSONValue]) async -> JSONValue {
        guard let id = Self.cloudInputString(
            input["id"] ?? input["message_id"] ?? input["messageId"]
        ), !id.isEmpty else {
            return Self.cloudFailure(
                connector: "gmail",
                code: "invalid_input",
                detail: "gmail_read requires a message id."
            )
        }
        return await cloudConnectorRead(connector: "gmail") { token in
            var request = URLRequest(
                url: URL(
                    string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(Self.cloudPath(id))?format=full"
                )!
            )
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let message = try await cloudConnectorJSONObject(
                request,
                connector: "gmail"
            )
            return Self.gmailMessageProjection(message, includeBody: true)
        }
    }

    func impl_google_calendar_status(input _: [String: JSONValue]) async -> JSONValue {
        await cloudConnectorRead(connector: "calendar") { token in
            var request = URLRequest(
                url: URL(
                    string: "https://www.googleapis.com/calendar/v3/calendars/primary"
                )!
            )
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let object = try await cloudConnectorJSONObject(
                request,
                connector: "calendar"
            )
            return .object([
                "status": .string("ok"),
                "id": Self.cloudString(object["id"]).map(JSONValue.string) ?? .null,
                "summary": Self.cloudString(object["summary"]).map(JSONValue.string) ?? .null,
                "timeZone": Self.cloudString(object["timeZone"]).map(JSONValue.string) ?? .null,
            ])
        }
    }

    func impl_google_calendar_list(input: [String: JSONValue]) async -> JSONValue {
        let limit = max(1, min(Self.cloudInputInt(input["limit"]) ?? 20, 50))
        let now = Date()
        let end = now.addingTimeInterval(7 * 24 * 60 * 60)
        let timeMin = Self.cloudInputString(input["time_min"] ?? input["timeMin"])
            ?? Self.cloudISO8601(now)
        let timeMax = Self.cloudInputString(input["time_max"] ?? input["timeMax"])
            ?? Self.cloudISO8601(end)
        return await cloudConnectorRead(connector: "calendar") { token in
            var components = URLComponents(
                string: "https://www.googleapis.com/calendar/v3/calendars/primary/events"
            )!
            components.queryItems = [
                URLQueryItem(name: "timeMin", value: timeMin),
                URLQueryItem(name: "timeMax", value: timeMax),
                URLQueryItem(name: "maxResults", value: String(limit)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let object = try await cloudConnectorJSONObject(
                request,
                connector: "calendar"
            )
            let events = (object["items"] as? [[String: Any]] ?? []).map {
                Self.googleCalendarEventProjection($0)
            }
            return .object([
                "status": .string("ok"),
                "timeMin": .string(timeMin),
                "timeMax": .string(timeMax),
                "events": .array(events),
                "resultCount": .int(Int64(events.count)),
            ])
        }
    }

    func impl_notion_status(input _: [String: JSONValue]) async -> JSONValue {
        await cloudConnectorRead(connector: "notion") { token in
            var request = URLRequest(url: URL(string: "https://api.notion.com/v1/users/me")!)
            Self.applyNotionHeaders(token: token, to: &request)
            let object = try await cloudConnectorJSONObject(
                request,
                connector: "notion"
            )
            return .object([
                "status": .string("ok"),
                "id": Self.cloudString(object["id"]).map(JSONValue.string) ?? .null,
                "name": Self.cloudString(object["name"]).map(JSONValue.string) ?? .null,
                "type": Self.cloudString(object["type"]).map(JSONValue.string) ?? .null,
            ])
        }
    }

    func impl_notion_search(input: [String: JSONValue]) async -> JSONValue {
        let query = Self.cloudInputString(input["query"] ?? input["q"]) ?? ""
        let limit = max(1, min(Self.cloudInputInt(input["limit"]) ?? 20, 50))
        return await cloudConnectorRead(connector: "notion") { token in
            var request = URLRequest(url: URL(string: "https://api.notion.com/v1/search")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "page_size": limit,
                "sort": [
                    "direction": "descending",
                    "timestamp": "last_edited_time",
                ],
            ])
            Self.applyNotionHeaders(token: token, to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let object = try await cloudConnectorJSONObject(
                request,
                connector: "notion"
            )
            let results = (object["results"] as? [[String: Any]] ?? []).map {
                Self.notionObjectProjection($0)
            }
            return .object([
                "status": .string("ok"),
                "query": .string(query),
                "results": .array(results),
                "resultCount": .int(Int64(results.count)),
                "hasMore": .bool(object["has_more"] as? Bool ?? false),
            ])
        }
    }

    func impl_notion_read_page(input: [String: JSONValue]) async -> JSONValue {
        guard let id = Self.cloudInputString(
            input["id"] ?? input["page_id"] ?? input["pageId"]
        ), !id.isEmpty else {
            return Self.cloudFailure(
                connector: "notion",
                code: "invalid_input",
                detail: "notion_read_page requires a page id."
            )
        }
        return await cloudConnectorRead(connector: "notion") { token in
            var pageRequest = URLRequest(
                url: URL(string: "https://api.notion.com/v1/pages/\(Self.cloudPath(id))")!
            )
            Self.applyNotionHeaders(token: token, to: &pageRequest)
            let page = try await cloudConnectorJSONObject(
                pageRequest,
                connector: "notion"
            )

            var blocksRequest = URLRequest(
                url: URL(
                    string: "https://api.notion.com/v1/blocks/\(Self.cloudPath(id))/children?page_size=100"
                )!
            )
            Self.applyNotionHeaders(token: token, to: &blocksRequest)
            let blocks = try await cloudConnectorJSONObject(
                blocksRequest,
                connector: "notion"
            )
            let text = Self.notionPlainText(
                blocks["results"] as? [[String: Any]] ?? []
            )
            let projection = Self.notionObjectProjection(page)
            guard case .object(var output) = projection else { return projection }
            output["text"] = .string(Self.cloudClip(text, limit: 20_000))
            return .object(output)
        }
    }

    private func cloudConnectorRead(
        connector: String,
        operation: (String) async throws -> JSONValue
    ) async -> JSONValue {
        guard let auth = Self.loadCloudConnectorAuth(
            connector: connector,
            root: dataRoot
        ) else {
            return Self.cloudFailure(
                connector: connector,
                code: "not_connected",
                detail: "Connect \(Self.cloudConnectorDisplayName(connector)) in Connectors first."
            )
        }
        do {
            return try await operation(auth.accessToken)
        } catch let error as CloudConnectorHTTPError
            where error.statusCode == 401 && connector != "notion" {
            do {
                let refreshed = try await Self.refreshGoogleToken(
                    auth,
                    connector: connector
                )
                return try await operation(refreshed)
            } catch {
                return Self.cloudFailure(
                    connector: connector,
                    code: "reauth_required",
                    detail: Self.cloudErrorDetail(error)
                )
            }
        } catch {
            return Self.cloudFailure(
                connector: connector,
                code: "request_failed",
                detail: Self.cloudErrorDetail(error)
            )
        }
    }

    private struct CloudConnectorHTTPError: Error {
        let statusCode: Int
        let body: String
    }

    private func cloudConnectorJSONObject(
        _ request: URLRequest,
        connector: String
    ) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CloudConnectorHTTPError(
                statusCode: status,
                body: Self.cloudClip(
                    String(data: data, encoding: .utf8) ?? "",
                    limit: 1_000
                )
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudConnectorHTTPError(
                statusCode: status,
                body: "Provider returned a non-object JSON response."
            )
        }
        return object
    }

    private static func loadCloudConnectorAuth(
        connector: String,
        root: URL
    ) -> CloudConnectorAuth? {
        let path = root
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(connector, isDirectory: true)
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = cloudString(object["access_token"]),
              !accessToken.isEmpty else {
            return nil
        }
        let appPath = root
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(connector, isDirectory: true)
            .appendingPathComponent("oauth_app.json")
        if let data = try? Data(contentsOf: appPath),
           let app = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if object["client_id"] == nil { object["client_id"] = app["client_id"] }
            if object["client_secret"] == nil {
                object["client_secret"] = app["client_secret"]
            }
        }
        return CloudConnectorAuth(
            accessToken: accessToken,
            refreshToken: cloudString(object["refresh_token"]),
            clientId: cloudString(object["client_id"]),
            clientSecret: cloudString(object["client_secret"]),
            object: object,
            path: path
        )
    }

    private static func refreshGoogleToken(
        _ auth: CloudConnectorAuth,
        connector: String
    ) async throws -> String {
        guard let refreshToken = auth.refreshToken, !refreshToken.isEmpty,
              let clientId = auth.clientId, !clientId.isEmpty else {
            throw CloudConnectorHTTPError(
                statusCode: 401,
                body: "The saved Google authorization cannot be refreshed. Reconnect the account."
            )
        }
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]
        if let clientSecret = auth.clientSecret, !clientSecret.isEmpty {
            fields["client_secret"] = clientSecret
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = fields
            .sorted { $0.key < $1.key }
            .map {
                "\(cloudFormComponent($0.key))=\(cloudFormComponent($0.value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = cloudString(object["access_token"]),
              !accessToken.isEmpty else {
            throw CloudConnectorHTTPError(
                statusCode: status,
                body: cloudClip(String(data: data, encoding: .utf8) ?? "", limit: 800)
            )
        }
        var merged = auth.object
        for (key, value) in object { merged[key] = value }
        merged["refresh_token"] = refreshToken
        let expiresIn = cloudInt(object["expires_in"]) ?? 3_600
        merged["expires_at"] = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
        try FileManager.default.createDirectory(
            at: auth.path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let output = try JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys]
        )
        try output.write(to: auth.path, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: auth.path.path
        )
        return accessToken
    }

    private static func gmailMessageProjection(
        _ message: [String: Any],
        includeBody: Bool
    ) -> JSONValue {
        let payload = message["payload"] as? [String: Any] ?? [:]
        let headers = (payload["headers"] as? [[String: Any]] ?? []).reduce(
            into: [String: String]()
        ) { result, row in
            guard let name = cloudString(row["name"]),
                  let value = cloudString(row["value"]) else { return }
            result[name.lowercased()] = value
        }
        var output: [String: JSONValue] = [
            "status": .string("ok"),
            "id": cloudString(message["id"]).map(JSONValue.string) ?? .null,
            "threadId": cloudString(message["threadId"]).map(JSONValue.string) ?? .null,
            "from": headers["from"].map(JSONValue.string) ?? .null,
            "to": headers["to"].map(JSONValue.string) ?? .null,
            "subject": headers["subject"].map(JSONValue.string) ?? .null,
            "date": headers["date"].map(JSONValue.string) ?? .null,
            "snippet": cloudString(message["snippet"]).map {
                .string(cloudClip($0, limit: 1_000))
            } ?? .null,
        ]
        if includeBody {
            output["body"] = .string(
                cloudClip(gmailBodyText(payload), limit: 20_000)
            )
        }
        return .object(output)
    }

    private static func gmailBodyText(_ payload: [String: Any]) -> String {
        let mimeType = cloudString(payload["mimeType"]) ?? ""
        if mimeType == "text/plain",
           let body = payload["body"] as? [String: Any],
           let encoded = cloudString(body["data"]),
           let data = cloudBase64URLDecode(encoded),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        let parts = payload["parts"] as? [[String: Any]] ?? []
        let plain = parts.map(gmailBodyText).filter { !$0.isEmpty }
        return plain.joined(separator: "\n\n")
    }

    private static func googleCalendarEventProjection(
        _ event: [String: Any]
    ) -> JSONValue {
        let start = event["start"] as? [String: Any] ?? [:]
        let end = event["end"] as? [String: Any] ?? [:]
        return .object([
            "id": cloudString(event["id"]).map(JSONValue.string) ?? .null,
            "status": cloudString(event["status"]).map(JSONValue.string) ?? .null,
            "summary": cloudString(event["summary"]).map(JSONValue.string) ?? .null,
            "description": cloudString(event["description"]).map {
                .string(cloudClip($0, limit: 4_000))
            } ?? .null,
            "location": cloudString(event["location"]).map(JSONValue.string) ?? .null,
            "start": cloudString(start["dateTime"] ?? start["date"]).map(JSONValue.string) ?? .null,
            "end": cloudString(end["dateTime"] ?? end["date"]).map(JSONValue.string) ?? .null,
            "htmlLink": cloudString(event["htmlLink"]).map(JSONValue.string) ?? .null,
        ])
    }

    private static func notionObjectProjection(
        _ object: [String: Any]
    ) -> JSONValue {
        .object([
            "id": cloudString(object["id"]).map(JSONValue.string) ?? .null,
            "object": cloudString(object["object"]).map(JSONValue.string) ?? .null,
            "title": .string(notionTitle(object)),
            "url": cloudString(object["url"]).map(JSONValue.string) ?? .null,
            "lastEditedTime": cloudString(object["last_edited_time"]).map(JSONValue.string) ?? .null,
            "archived": .bool(object["archived"] as? Bool ?? false),
        ])
    }

    private static func notionTitle(_ object: [String: Any]) -> String {
        let properties = object["properties"] as? [String: Any] ?? [:]
        for (_, rawProperty) in properties {
            guard let property = rawProperty as? [String: Any],
                  cloudString(property["type"]) == "title",
                  let title = property["title"] as? [[String: Any]] else {
                continue
            }
            let text = title.compactMap {
                cloudString(($0["plain_text"]))
            }.joined()
            if !text.isEmpty { return cloudClip(text, limit: 500) }
        }
        return ""
    }

    private static func notionPlainText(_ blocks: [[String: Any]]) -> String {
        blocks.compactMap { block -> String? in
            guard let type = cloudString(block["type"]),
                  let body = block[type] as? [String: Any],
                  let richText = body["rich_text"] as? [[String: Any]] else {
                return nil
            }
            let text = richText.compactMap { cloudString($0["plain_text"]) }.joined()
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }

    private static func applyNotionHeaders(token: String, to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
    }

    private static func cloudFailure(
        connector: String,
        code: String,
        detail: String
    ) -> JSONValue {
        .object([
            "status": .string("failed"),
            "connector": .string(connector),
            "error": .string(code),
            "detail": .string(cloudClip(detail, limit: 1_500)),
        ])
    }

    private static func cloudErrorDetail(_ error: Error) -> String {
        if let http = error as? CloudConnectorHTTPError {
            return "HTTP \(http.statusCode): \(cloudClip(http.body, limit: 1_000))"
        }
        return cloudClip(error.localizedDescription, limit: 1_000)
    }

    private static func cloudConnectorDisplayName(_ connector: String) -> String {
        switch connector {
        case "gmail": "Gmail"
        case "calendar": "Google Calendar"
        case "notion": "Notion"
        default: connector
        }
    }

    private static func cloudInputString(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cloudInputInt(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let value): Int(value)
        case .double(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    private static func cloudString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cloudInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func cloudClip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    private static func cloudPath(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(
                CharacterSet(charactersIn: "/?#")
            )
        ) ?? ""
    }

    private static func cloudISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func cloudFormComponent(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-._~")
            )
        ) ?? ""
    }

    private static func cloudBase64URLDecode(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }
}
