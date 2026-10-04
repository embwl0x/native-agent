import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

extension SwiftToolDispatcher {
    private struct CloudConnectorAuth {
        var accessToken: String
        var path: URL
        var scopes: Set<String>
    }

    func impl_gmail_status(input _: [String: JSONValue]) async -> JSONValue {
        await cloudConnectorRead(connector: "gmail", statusRead: true) { token in
            var request = URLRequest(
                url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
            )
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let object = try await cloudConnectorJSONObject(
                request,
                connector: "gmail"
            )
            // The inbox's own counts: what "how much mail do I have" asks.
            var inboxRequest = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels/INBOX")!)
            inboxRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let inbox = (try? await cloudConnectorJSONObject(inboxRequest, connector: "gmail")) ?? [:]
            return .object([
                "status": .string("ok"),
                "inbox_total": Self.cloudInt(inbox["messagesTotal"]).map { .int(Int64($0)) } ?? .null,
                "inbox_unread": Self.cloudInt(inbox["messagesUnread"]).map { .int(Int64($0)) } ?? .null,
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
        let input = input.filter { $0.value != .string("") }
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
            if let cursor = Self.cloudInputString(input["page_token"]) {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor))
            }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let listing = try await cloudConnectorJSONObject(
                request,
                connector: "gmail"
            )
            let ids = (listing["messages"] as? [[String: Any]] ?? []).prefix(limit)
                .compactMap { Self.cloudString($0["id"]) }
            // Four in flight, replenished only after a successful read. A provider
            // failure cancels the group rather than silently dropping a message.
            let messages = try await withThrowingTaskGroup(of: (Int, JSONValue).self) { group in
                func enqueue(_ index: Int) {
                    group.addTask {
                        try Task.checkCancellation()
                        let message = try await self.gmailMetadata(id: ids[index], token: token)
                        return (index, message)
                    }
                }
                var ordered = Array(repeating: JSONValue.null, count: ids.count)
                var nextIndex = min(4, ids.count)
                for index in 0..<nextIndex { enqueue(index) }
                while let (index, message) = try await group.next() {
                    ordered[index] = message
                    if nextIndex < ids.count { enqueue(nextIndex); nextIndex += 1 }
                }
                return ordered
            }
            let cursor = Self.cloudString(listing["nextPageToken"])
            return .object([
                "status": .string("ok"),
                "query": .string(query),
                "messages": .array(messages),
                "resultCount": .int(Int64(messages.count)),
                "resultSizeEstimate": Self.cloudInt(listing["resultSizeEstimate"]).map {
                    .int(Int64($0))
                } ?? .null,
                "nextPageToken": cursor.map(JSONValue.string) ?? .null,
                "hasMore": .bool(cursor != nil),
                "next": cursor.map { .object([
                    "query": .string(query), "limit": .int(Int64(limit)), "page_token": .string($0),
                ]) } ?? .null,
            ])
        }
    }

    private func gmailMetadata(id: String, token: String) async throws -> JSONValue {
        var request = URLRequest(url: URL(
            string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(Self.cloudPath(id))?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Date"
        )!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let message = try await cloudConnectorJSONObject(request, connector: "gmail")
        return .object(Self.gmailMessageProjection(message))
    }

    func impl_gmail_read(input: [String: JSONValue]) async -> JSONValue {
        let input = input.filter { $0.value != .null && $0.value != .string("") }
        guard let id = Self.cloudInputString(
            input["id"] ?? input["message_id"] ?? input["messageId"]
        ), !id.isEmpty else {
            return Self.cloudFailure(
                connector: "gmail",
                code: "invalid_input",
                detail: "Say which message: pass the id from a gmail_search row."
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
            var output = Self.gmailMessageProjection(message)
            let payload = message["payload"] as? [String: Any] ?? [:]
            let body = Self.gmailReadableBody(payload)
            let incomplete = Self.gmailHasExternalBodyText(payload)
                || (body.isEmpty && Self.cloudString(message["snippet"]) != nil)
            Self.cloudTextPage(body,
                field: "body", input: input, nextInput: ["id": .string(id)], output: &output)
            output["bodyRetrievalIncomplete"] = .bool(incomplete)
            if incomplete {
                output["bodyRetrievalNote"] = .string("Body retrieval is incomplete. Some message text was not retrieved; snippet is a preview. totalCharacters and next describe retrieved text only.")
            }
            return .object(output)
        }
    }

    func impl_google_calendar_status(input _: [String: JSONValue]) async -> JSONValue {
        await cloudConnectorRead(connector: "calendar", statusRead: true) { token in
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
        let input = input.filter { $0.value != .string("") }
        let calendarID = Self.cloudInputString(input["calendar_id"]) ?? "primary"
        let limit = max(1, min(Self.cloudInputInt(input["limit"]) ?? 20, 50))
        var now = Date()
        var end = now.addingTimeInterval(7 * 24 * 60 * 60)
        // A bare day ("today", "tomorrow", "2026-09-25") is that local day;
        // Google refuses anything short of a full RFC 3339 time.
        func localDay(_ raw: String?) -> Date? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
            let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
            if raw == "today" { return today }
            if raw == "tomorrow" { return calendar.date(byAdding: .day, value: 1, to: today) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
            return raw.count == 10 ? formatter.date(from: raw) : nil
        }
        if let day = localDay(Self.cloudInputString(input["day"])) {
            now = day; end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        let rawMin = Self.cloudInputString(input["time_min"] ?? input["timeMin"])
        let rawMax = Self.cloudInputString(input["time_max"] ?? input["timeMax"])
        let timeMin = localDay(rawMin).map(Self.cloudISO8601) ?? rawMin ?? Self.cloudISO8601(now)
        let timeMax = localDay(rawMax).map(Self.cloudISO8601) ?? rawMax ?? Self.cloudISO8601(end)
        return await cloudConnectorRead(connector: "calendar") { token in
            var components = URLComponents(
                string: "https://www.googleapis.com/calendar/v3/calendars/\(Self.cloudPath(calendarID))/events"
            )!
            components.queryItems = [
                URLQueryItem(name: "timeMin", value: timeMin),
                URLQueryItem(name: "timeMax", value: timeMax),
                URLQueryItem(name: "maxResults", value: String(limit)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
            ]
            if let cursor = Self.cloudInputString(input["page_token"]) {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor))
            }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let object = try await cloudConnectorJSONObject(
                request,
                connector: "calendar"
            )
            let events = (object["items"] as? [[String: Any]] ?? []).map {
                Self.googleCalendarEventProjection($0)
            }
            let cursor = Self.cloudString(object["nextPageToken"])
            return .object([
                "status": .string("ok"),
                "calendarId": .string(calendarID),
                "timeMin": .string(timeMin),
                "timeMax": .string(timeMax),
                "events": .array(events),
                "resultCount": .int(Int64(events.count)),
                "nextPageToken": cursor.map(JSONValue.string) ?? .null,
                "hasMore": .bool(cursor != nil),
                "next": cursor.map { .object([
                    "time_min": .string(timeMin), "time_max": .string(timeMax),
                    "limit": .int(Int64(limit)), "page_token": .string($0), "calendar_id": .string(calendarID),
                ]) } ?? .null,
            ])
        }
    }

    func impl_google_calendar_calendars(input: [String: JSONValue]) async -> JSONValue {
        await cloudConnectorRead(connector: "calendar") { token in
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
            components.queryItems = [URLQueryItem(name: "maxResults", value: "100")]
            if let cursor = Self.cloudInputString(input["page_token"]) {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor))
            }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let object = try await cloudConnectorJSONObject(request, connector: "calendar")
            let calendars: [JSONValue] = (object["items"] as? [[String: Any]] ?? []).map { row in
                .object(["calendarId": Self.cloudString(row["id"]).map(JSONValue.string) ?? .null,
                    "title": Self.cloudString(row["summary"]).map(JSONValue.string) ?? .null,
                    "timeZone": Self.cloudString(row["timeZone"]).map(JSONValue.string) ?? .null,
                    "accessRole": Self.cloudString(row["accessRole"]).map(JSONValue.string) ?? .null,
                    "primary": .bool(row["primary"] as? Bool == true)])
            }
            let cursor = Self.cloudString(object["nextPageToken"])
            return .object(["status": .string("ok"), "calendars": .array(calendars),
                "next": cursor.map { .object(["page_token": .string($0)]) } ?? .null])
        }
    }

    func impl_google_calendar_free_busy(input: [String: JSONValue]) async -> JSONValue {
        guard let ids = Self.calendarIDs(input["calendar_ids"]),
              let start = Self.calendarInstant(input["start"]), let end = Self.calendarInstant(input["end"]),
              end > start, end.timeIntervalSince(start) <= 31 * 86_400 else {
            return Self.calendarInvalidArguments()
        }
        return await cloudConnectorRead(connector: "calendar") { token in
            try await googleCalendarFreeBusy(ids: ids, start: start, end: end, token: token)
        }
    }

    func impl_google_calendar_read(input: [String: JSONValue]) async -> JSONValue {
        guard let calendarID = Self.cloudInputString(input["calendar_id"]), !calendarID.isEmpty,
              let eventID = Self.cloudInputString(input["event_id"]), !eventID.isEmpty else {
            return Self.calendarInvalidArguments()
        }
        return await cloudConnectorRead(connector: "calendar") { token in
            var request = URLRequest(url: URL(string:
                "https://www.googleapis.com/calendar/v3/calendars/\(Self.cloudPath(calendarID))/events/\(Self.cloudPath(eventID))")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let event = try await cloudConnectorJSONObject(request, connector: "calendar")
            return .object(["status": .string("ok"), "calendarId": .string(calendarID), "event": Self.googleCalendarEventProjection(event)])
        }
    }

    private func googleCalendarFreeBusy(ids: [String], start: Date, end: Date, token: String) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/freeBusy")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["timeMin": Self.cloudISO8601(start),
            "timeMax": Self.cloudISO8601(end), "items": ids.map { ["id": $0] }])
        let object = try await cloudConnectorJSONObject(request, connector: "calendar")
        let calendars = object["calendars"] as? [String: [String: Any]] ?? [:]
        let rows: [JSONValue] = ids.map { calendarID in
            let calendar = calendars[calendarID]
            let busy = calendar?["busy"] as? [[String: Any]]
            let errors = calendar?["errors"] as? [[String: Any]] ?? []
            let known = calendar != nil && busy != nil && errors.isEmpty
            return .object(["calendarId": .string(calendarID),
                "availability": .string(known ? busy!.isEmpty ? "free" : "busy" : "unknown"),
                "busy": .array((busy ?? []).map { .object([
                    "start": Self.cloudString($0["start"]).map(JSONValue.string) ?? .null,
                    "end": Self.cloudString($0["end"]).map(JSONValue.string) ?? .null]) }),
                "errors": .array(errors.map { .object(["reason": Self.cloudString($0["reason"]).map(JSONValue.string) ?? .null]) })])
        }
        return .object(["status": .string("ok"), "start": .string(Self.cloudISO8601(start)),
            "end": .string(Self.cloudISO8601(end)), "calendars": .array(rows)])
    }

    func impl_google_calendar_send_invitations(input: [String: JSONValue]) async -> JSONValue {
        guard let calendarID = Self.cloudInputString(input["calendar_id"]), !calendarID.isEmpty, calendarID != "primary",
              let eventID = Self.cloudInputString(input["event_id"]), (5...1024).contains(eventID.count),
              eventID.allSatisfy({ "0123456789abcdefghijklmnopqrstuv".contains($0) }),
              let title = Self.cloudInputString(input["title"]), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let start = Self.calendarInstant(input["start"]), let end = Self.calendarInstant(input["end"]),
              end > start, end.timeIntervalSince(start) <= 31 * 86_400,
              let zone = Self.cloudInputString(input["time_zone"]), TimeZone(identifier: zone) != nil,
              let attendees = Self.calendarIDs(input["attendees"]),
              attendees.allSatisfy({ $0.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil }) else {
            return Self.calendarInvalidArguments()
        }
        let recurrence: [String]
        if let raw = input["recurrence"] {
            guard case .array(let values) = raw, values.count <= 20,
                  values.allSatisfy({ value in
                      guard let line = Self.cloudInputString(value), line.count <= 2048,
                            !line.contains("\n"), !line.contains("\r") else { return false }
                      return ["RRULE:", "RDATE", "EXDATE", "EXRULE:"].contains { line.hasPrefix($0) }
                  }) else { return Self.calendarInvalidArguments() }
            recurrence = values.compactMap(Self.cloudInputString)
        } else { recurrence = [] }
        let checkIDs: [String]
        if let raw = input["check_calendar_ids"] {
            guard let ids = Self.calendarIDs(raw), Set(ids + [calendarID]).count <= 50 else { return Self.calendarInvalidArguments() }
            checkIDs = Array(Set(ids + [calendarID])).sorted()
        } else { checkIDs = [calendarID] }
        var body: [String: Any] = ["id": eventID, "summary": title,
            "start": ["dateTime": Self.cloudISO8601(start), "timeZone": zone],
            "end": ["dateTime": Self.cloudISO8601(end), "timeZone": zone],
            "attendees": attendees.map { ["email": $0] }, "recurrence": recurrence,
            "extendedProperties": ["private": ["nativeagent_invitation": "all"]]]
        for field in ["location", "description"] {
            if let value = Self.cloudInputString(input[field]) { body[field] = value }
        }
        if let auth = Self.loadCloudConnectorAuth(connector: "calendar", root: dataRoot),
           auth.scopes.isDisjoint(with: ["https://www.googleapis.com/auth/calendar", "https://www.googleapis.com/auth/calendar.events"]) {
            return InlineInteractionNeed.envelope(InlineInteractionRegistry.connector("calendar",
                why: "Reconnect Google Calendar to grant event-write access before sending invitations.", dataRoot: dataRoot))
        }
        return await cloudConnectorRead(connector: "calendar", purpose: "schedule this meeting") { token in
            let base = "https://www.googleapis.com/calendar/v3/calendars/\(Self.cloudPath(calendarID))/events"
            func readEvent() async throws -> [String: Any]? {
                var request = URLRequest(url: URL(string: base + "/" + Self.cloudPath(eventID))!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                do { return try await cloudConnectorJSONObject(request, connector: "calendar") }
                catch let error as CloudConnectorHTTPError where error.statusCode == 404 { return nil }
            }
            func receipt(_ event: [String: Any], invitations: String, availability: JSONValue) -> JSONValue {
                var result: [String: JSONValue] = ["status": .string("completed"), "calendarId": .string(calendarID),
                    "event": Self.googleCalendarEventProjection(event), "invitations": .string(invitations),
                    "deliveryConfirmed": .bool(false), "availability": availability,
                    "availabilityScope": .string(recurrence.isEmpty ? "meeting" : "first_occurrence_only")]
                if !Self.calendarEventMatches(event, body: body) {
                    result["status"] = .string("outcome_unknown")
                    result["detail"] = .string("The event does not match the request. Inspect this event_id before any further send.")
                }
                return .object(result)
            }
            if let existing = try await readEvent() { return receipt(existing, invitations: "not_sent_this_call", availability: .null) }
            let availability = try await googleCalendarFreeBusy(ids: checkIDs, start: start, end: end, token: token)
            guard case .object(let availabilityObject) = availability,
                  case .array(let rows)? = availabilityObject["calendars"],
                  rows.allSatisfy({ row in
                      guard case .object(let calendar) = row else { return false }
                      return calendar["availability"] == .string("free")
                          || (input["allow_conflicts"] == .bool(true) && calendar["availability"] == .string("busy"))
                  }) else {
                return .object(["status": .string("failed"), "detail": .string("No invitations sent: checked calendars are busy or availability is unknown."), "availability": availability])
            }
            var request = URLRequest(url: URL(string: base + "?sendUpdates=all")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            var inserted = false
            do {
                _ = try await cloudConnectorJSONObject(request, connector: "calendar")
                inserted = true
                guard let confirmed = try await readEvent() else {
                    return .object(["status": .string("outcome_unknown"), "calendarId": .string(calendarID), "eventId": .string(eventID),
                        "detail": .string("The invitation outcome is unknown. Read this calendar and event_id before retrying; do not create a new event_id.")])
                }
                return receipt(confirmed, invitations: "requested_for_all_attendees", availability: availability)
            } catch let error as CloudConnectorHTTPError where !inserted && error.statusCode == 409 {
                do {
                    if let confirmed = try await readEvent() {
                        return receipt(confirmed, invitations: "not_sent_this_call", availability: availability)
                    }
                } catch {}
                return .object(["status": .string("outcome_unknown"), "calendarId": .string(calendarID), "eventId": .string(eventID),
                    "detail": .string("The invitation outcome is unknown. Read this calendar and event_id before retrying; do not create a new event_id.")])
            } catch let error as CloudConnectorHTTPError where !inserted && (400..<500).contains(error.statusCode) {
                throw error
            } catch {
                return .object(["status": .string("outcome_unknown"), "calendarId": .string(calendarID), "eventId": .string(eventID),
                    "detail": .string("The invitation outcome is unknown. Read this calendar and event_id before retrying; do not create a new event_id.")])
            }
        }
    }

    private static func calendarIDs(_ value: JSONValue?) -> [String]? {
        guard case .array(let values)? = value, (1...50).contains(values.count),
              values.allSatisfy({ cloudInputString($0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else { return nil }
        let ids = values.compactMap(cloudInputString)
        return Set(ids).count == ids.count ? ids : nil
    }

    private static func calendarInstant(_ value: JSONValue?) -> Date? {
        guard let raw = cloudInputString(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func calendarInvalidArguments() -> JSONValue {
        cloudFailure(connector: "calendar", code: "invalid_arguments", detail: "Use exact calendar IDs, RFC3339 start/end with offsets (at most 31 days), an IANA time_zone, attendee email addresses, a stable base32hex event_id and RFC5545 recurrence lines.")
    }

    private static func calendarEventMatches(_ event: [String: Any], body: [String: Any]) -> Bool {
        let expectedAttendees = Set((body["attendees"] as? [[String: Any]] ?? []).compactMap { cloudString($0["email"])?.lowercased() })
        let actualAttendees = Set((event["attendees"] as? [[String: Any]] ?? []).compactMap { cloudString($0["email"])?.lowercased() })
        let properties = event["extendedProperties"] as? [String: [String: String]]
        guard event["id"] as? String == body["id"] as? String, event["summary"] as? String == body["summary"] as? String,
              event["status"] as? String == "confirmed", event["attendeesOmitted"] as? Bool != true,
              expectedAttendees == actualAttendees, properties?["private"]?["nativeagent_invitation"] == "all",
              (event["recurrence"] as? [String] ?? []) == (body["recurrence"] as? [String] ?? []) else { return false }
        for field in ["start", "end"] {
            guard let actual = event[field] as? [String: Any], let expected = body[field] as? [String: Any],
                  let actualTime = cloudString(actual["dateTime"]), let expectedTime = cloudString(expected["dateTime"]),
                  calendarInstant(.string(actualTime)) == calendarInstant(.string(expectedTime)),
                  actual["timeZone"] as? String == expected["timeZone"] as? String else { return false }
        }
        return ["location", "description"].allSatisfy { (event[$0] as? String ?? "") == (body[$0] as? String ?? "") }
    }

    func impl_notion_status(input _: [String: JSONValue]) async -> JSONValue {
        await cloudConnectorRead(connector: "notion", statusRead: true) { token in
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
        let input = input.filter { $0.value != .string("") }
        let query = Self.cloudInputString(input["query"] ?? input["q"]) ?? ""
        let limit = max(1, min(Self.cloudInputInt(input["limit"]) ?? 20, 50))
        return await cloudConnectorRead(connector: "notion") { token in
            var request = URLRequest(url: URL(string: "https://api.notion.com/v1/search")!)
            request.httpMethod = "POST"
            var body: [String: Any] = [
                "query": query,
                "page_size": limit,
                "sort": [
                    "direction": "descending",
                    "timestamp": "last_edited_time",
                ],
            ]
            if let cursor = Self.cloudInputString(input["start_cursor"]) { body["start_cursor"] = cursor }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            Self.applyNotionHeaders(token: token, to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let object = try await cloudConnectorJSONObject(
                request,
                connector: "notion"
            )
            let results = (object["results"] as? [[String: Any]] ?? []).map {
                Self.notionObjectProjection($0)
            }
            let cursor = Self.cloudString(object["next_cursor"])
            return .object([
                "status": .string("ok"),
                "query": .string(query),
                "results": .array(results),
                "resultCount": .int(Int64(results.count)),
                "hasMore": .bool(object["has_more"] as? Bool ?? false),
                "nextCursor": cursor.map(JSONValue.string) ?? .null,
                "next": cursor.map { .object([
                    "query": .string(query), "limit": .int(Int64(limit)), "start_cursor": .string($0),
                ]) } ?? .null,
            ])
        }
    }

    func impl_notion_read_page(input: [String: JSONValue]) async -> JSONValue {
        let input = input.filter { $0.value != .null && $0.value != .string("") }
        guard let given = Self.cloudInputString(
            input["id"] ?? input["page_id"] ?? input["pageId"] ?? input["url"] ?? input["title"]
        ), !given.isEmpty else {
            return Self.cloudFailure(
                connector: "notion",
                code: "invalid_input",
                detail: "Give the page's title, link or id."
            )
        }
        // A link's or id's 32 hex digits are the id; anything else is a title.
        let stripped = given.replacingOccurrences(of: "-", with: "")
        let hex = stripped.range(of: #"[0-9a-fA-F]{32}(?=$|[?#])"#, options: .regularExpression).map { String(stripped[$0]) }
        return await cloudConnectorRead(connector: "notion") { token in
            var id = hex ?? given
            if hex == nil {
                var search = URLRequest(url: URL(string: "https://api.notion.com/v1/search")!)
                search.httpMethod = "POST"
                search.httpBody = try JSONSerialization.data(withJSONObject: [
                    "query": given, "page_size": 10, "filter": ["property": "object", "value": "page"]])
                Self.applyNotionHeaders(token: token, to: &search)
                search.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let searchResult = try await cloudConnectorJSONObject(search, connector: "notion")
                guard searchResult["has_more"] as? Bool == false else {
                    return Self.cloudFailure(connector: "notion", code: "incomplete_search",
                        detail: "The title search is incomplete. Use notion_search to find the page, then pass its exact page id or link.")
                }
                let pages = searchResult["results"] as? [[String: Any]] ?? []
                // Exactly one page with exactly that title; never a nearest hit.
                let exact = pages.filter { Self.notionTitle($0).caseInsensitiveCompare(given) == .orderedSame }
                guard exact.count == 1, let found = exact[0]["id"] as? String else {
                    let shown = (exact.isEmpty ? pages : exact).prefix(5)
                        .map { "\"\(Self.notionTitle($0))\" (\(($0["id"] as? String) ?? "?"))" }.joined(separator: ", ")
                    return Self.cloudFailure(connector: "notion", code: exact.isEmpty ? "not_found" : "ambiguous",
                        detail: (exact.isEmpty ? "No page is titled exactly \"\(given)\"." : "\(exact.count) pages are titled \"\(given)\"; pass one id.")
                            + (shown.isEmpty ? " notion_search lists what the integration can see." : " Candidates: \(shown)."))
                }
                id = found
            }
            var pageRequest = URLRequest(
                url: URL(string: "https://api.notion.com/v1/pages/\(Self.cloudPath(id))")!
            )
            Self.applyNotionHeaders(token: token, to: &pageRequest)
            let page = try await cloudConnectorJSONObject(
                pageRequest,
                connector: "notion"
            )

            let blockID = Self.cloudInputString(input["block_id"]) ?? id
            var components = URLComponents(string: "https://api.notion.com/v1/blocks/\(Self.cloudPath(blockID))/children")!
            components.queryItems = [URLQueryItem(name: "page_size", value: "100")]
            let startCursor = Self.cloudInputString(input["start_cursor"])
            if let startCursor { components.queryItems?.append(URLQueryItem(name: "start_cursor", value: startCursor)) }
            var blocksRequest = URLRequest(url: components.url!)
            Self.applyNotionHeaders(token: token, to: &blocksRequest)
            let blocks = try await cloudConnectorJSONObject(
                blocksRequest,
                connector: "notion"
            )
            let rows = blocks["results"] as? [[String: Any]] ?? []
            let text = Self.notionPlainText(rows)
            let projection = Self.notionObjectProjection(page)
            guard case .object(var output) = projection else { return projection }
            var nextInput: [String: JSONValue] = ["id": .string(id), "block_id": .string(blockID)]
            if let startCursor { nextInput["start_cursor"] = .string(startCursor) }
            Self.cloudTextPage(text, field: "text", input: input, nextInput: nextInput, output: &output)
            let cursor = Self.cloudString(blocks["next_cursor"])
            output["blockId"] = .string(blockID)
            output["nextCursor"] = cursor.map(JSONValue.string) ?? .null
            output["nextPage"] = cursor.map { .object([
                "id": .string(id), "block_id": .string(blockID), "start_cursor": .string($0),
            ]) } ?? .null
            // Each child is another bounded read through this same owner. No
            // recursive request storm or second store is needed to finish a page.
            let children: [JSONValue] = rows.compactMap { row in
                guard row["has_children"] as? Bool == true, let childID = Self.cloudString(row["id"]) else { return nil }
                return .object(["id": .string(id), "block_id": .string(childID)])
            }
            output["children"] = .array(children)
            output["hasMore"] = .bool(output["hasMore"] == .bool(true) || blocks["has_more"] as? Bool == true || !children.isEmpty)
            output["truncated"] = output["hasMore"]
            return .object(output)
        }
    }

    private func cloudConnectorRead(
        connector: String,
        statusRead: Bool = false,
        purpose: String = "read this",
        operation: (String) async throws -> JSONValue
    ) async -> JSONValue {
        guard let auth = Self.loadCloudConnectorAuth(
            connector: connector,
            root: dataRoot
        ) else {
            // The shared cloud read — Gmail, Calendar, Notion — through their
            // one owner. `not_connected` is the single most common reason a
            // perfectly good request cannot start, and it used to end as a
            // sentence pointing at a settings page. It is now a Connect card
            // beside the question that needed it.
            let need = InlineInteractionNeed.envelope(
                InlineInteractionRegistry.connector(
                    connector,
                    why: "Connect \(Self.cloudConnectorDisplayName(connector)) so I can \(purpose).",
                    dataRoot: dataRoot
                )
            )
            guard statusRead, case .object(var result) = need else { return need }
            result["connected"] = .bool(false)
            result["connector"] = .string(connector)
            result["detail"] = .string("\(Self.cloudConnectorDisplayName(connector)) is not connected.")
            return .object(result)
        }
        // A refresh that cannot be rescued ends as `reauth_required` — the
        // saved connection is there but no longer works. That is the same
        // need with different prose: the person reconnects the account, and
        // the request resumes. Every other failure below (retryable
        // transport, 429, 5xx, cancellation) is untouched and still a failure.
        func needingReconnect(_ result: JSONValue) -> JSONValue {
            guard case .object(let object) = result,
                  case .string("reauth_required")? = object["error"]
            else { return result }
            return InlineInteractionNeed.envelope(
                InlineInteractionRegistry.connector(
                    connector,
                    why: "\(Self.cloudConnectorDisplayName(connector)) needs connecting again before I can \(purpose).",
                    dataRoot: dataRoot
                )
            )
        }
        do {
            return try await operation(auth.accessToken)
        } catch let error as CloudConnectorHTTPError
            where error.statusCode == 401 && connector != "notion" {
            let refreshed: String
            do {
                try Task.checkCancellation()
                refreshed = try await GoogleOAuthCredentials.refresh(
                    path: auth.path,
                    rejectedAccessToken: auth.accessToken
                )
            } catch {
                return needingReconnect(Self.cloudReadFailure(
                    error, connector: connector,
                    reauthenticate: (error as? GoogleOAuthCredentials.RefreshError)?.requiresReauthentication == true
                ))
            }
            do {
                try Task.checkCancellation()
                return try await operation(refreshed)
            } catch {
                return needingReconnect(Self.cloudReadFailure(
                    error, connector: connector,
                    reauthenticate: (error as? CloudConnectorHTTPError)?.statusCode == 401
                ))
            }
        } catch {
            // Notion has no refresh: its 401 is a revoked token, so it offers Connect.
            return needingReconnect(Self.cloudReadFailure(error, connector: connector,
                reauthenticate: connector == "notion" && (error as? CloudConnectorHTTPError)?.statusCode == 401))
        }
    }

    private static func cloudReadFailure(
        _ error: Error, connector: String, reauthenticate: Bool = false
    ) -> JSONValue {
        let cancelled = Task.isCancelled || error is CancellationError
            || (error as? URLError)?.code == .cancelled
        let accountChanged = error is GoogleOAuthCredentials.AccountChangedError
        let status = (error as? CloudConnectorHTTPError)?.statusCode
            ?? (error as? GoogleOAuthCredentials.RefreshError)?.statusCode
        let retryable = !cancelled && !reauthenticate
            && (accountChanged || error is URLError
                || (error as? CloudConnectorHTTPError)?.isRateLimited == true
                || status == 429 || status.map { (500..<600).contains($0) } == true)
        var output: [String: JSONValue] = [
            "status": .string(cancelled ? "cancelled" : "failed"),
            "connector": .string(connector),
            "error": .string(cancelled ? "cancelled" : accountChanged ? "account_changed" : reauthenticate ? "reauth_required" : "request_failed"),
            "retryable": .bool(retryable),
            "detail": .string(cloudErrorDetail(error)),
        ]
        if let retryAfter = (error as? CloudConnectorHTTPError)?.retryAfter {
            output["retryAfter"] = .string(retryAfter)
            output["detail"] = .string("Retry-After: \(retryAfter). \(cloudErrorDetail(error))")
        }
        return .object(output)
    }

    private struct CloudConnectorHTTPError: Error {
        let statusCode: Int
        let body: String
        var retryAfter: String? = nil

        var isRateLimited: Bool {
            if statusCode == 429 { return true }
            guard statusCode == 403, let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = object["error"] as? [String: Any],
                  let rows = error["errors"] as? [[String: Any]] else { return false }
            return rows.contains { row in
                ["rateLimitExceeded", "userRateLimitExceeded"].contains(row["reason"] as? String ?? "")
            }
        }
    }

    private func cloudConnectorJSONObject(
        _ request: URLRequest,
        connector: String
    ) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 30
        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CloudConnectorHTTPError(
                statusCode: status,
                body: Self.cloudClip(
                    String(data: data, encoding: .utf8) ?? "",
                    limit: 1_000
                ),
                retryAfter: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
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
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = cloudString(object["access_token"]),
              !accessToken.isEmpty else {
            return nil
        }
        return CloudConnectorAuth(
            accessToken: accessToken,
            path: path,
            scopes: Set((cloudString(object["scope"]) ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        )
    }

    private static func gmailMessageProjection(_ message: [String: Any]) -> [String: JSONValue] {
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
        if let labels = message["labelIds"] as? [String] { output["unread"] = .bool(labels.contains("UNREAD")) }
        return output
    }

    private static func cloudTextPage(
        _ text: String, field: String, input: [String: JSONValue],
        nextInput: [String: JSONValue], output: inout [String: JSONValue]
    ) {
        let offset = max(0, min(cloudInputInt(input["text_offset"]) ?? 0, text.count))
        let part = String(text.dropFirst(offset).prefix(20_000))
        let end = offset + part.count
        var next = nextInput
        next["text_offset"] = .int(Int64(end))
        output[field] = .string(part)
        output["textOffset"] = .int(Int64(offset))
        output["totalCharacters"] = .int(Int64(text.count))
        output["hasMore"] = .bool(end < text.count)
        output["truncated"] = .bool(end < text.count)
        output["next"] = end < text.count ? .object(next) : .null
    }

    private static func gmailHasExternalBodyText(_ payload: [String: Any]) -> Bool {
        if ["text/plain", "text/html"].contains(cloudString(payload["mimeType"]) ?? ""),
           let body = payload["body"] as? [String: Any],
           cloudString(body["attachmentId"]) != nil {
            return true
        }
        return (payload["parts"] as? [[String: Any]] ?? []).contains { gmailHasExternalBodyText($0) }
    }

    /// Plain text when the mail has it; an HTML-only mail (receipts,
    /// newsletters) read as an empty body before, so its HTML is flattened.
    private static func gmailReadableBody(_ payload: [String: Any]) -> String {
        let plain = gmailBodyText(payload)
        guard plain.isEmpty else { return plain }
        var text = gmailBodyText(payload, mimeType: "text/html")
        for pattern in ["(?is)<(script|style|head)\\b.*?</\\1>", "(?i)<br\\s*/?>|</(p|div|tr|li|h[1-6])>", "(?s)<[^>]+>"] {
            text = text.replacingOccurrences(of: pattern, with: pattern.hasPrefix("(?i)<br") ? "\n" : " ", options: .regularExpression)
        }
        for (entity, character) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\n\\s*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gmailBodyText(_ payload: [String: Any], mimeType wanted: String = "text/plain") -> String {
        let mimeType = cloudString(payload["mimeType"]) ?? ""
        if mimeType == wanted,
           let body = payload["body"] as? [String: Any],
           let encoded = cloudString(body["data"]),
           let data = cloudBase64URLDecode(encoded),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        let parts = payload["parts"] as? [[String: Any]] ?? []
        let plain = parts.map { gmailBodyText($0, mimeType: wanted) }.filter { !$0.isEmpty }
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
            "descriptionTruncated": .bool((cloudString(event["description"])?.count ?? 0) > 4_000),
            "location": cloudString(event["location"]).map(JSONValue.string) ?? .null,
            "start": cloudString(start["dateTime"] ?? start["date"]).map(JSONValue.string) ?? .null,
            "end": cloudString(end["dateTime"] ?? end["date"]).map(JSONValue.string) ?? .null,
            "htmlLink": cloudString(event["htmlLink"]).map(JSONValue.string) ?? .null,
            "timeZone": cloudString(start["timeZone"]).map(JSONValue.string) ?? .null,
            "recurrence": .array((event["recurrence"] as? [String] ?? []).map(JSONValue.string)),
            "recurringEventId": cloudString(event["recurringEventId"]).map(JSONValue.string) ?? .null,
            "organizer": cloudString((event["organizer"] as? [String: Any])?["email"]).map(JSONValue.string) ?? .null,
            "attendees": .array((event["attendees"] as? [[String: Any]] ?? []).map { .object([
                "email": cloudString($0["email"]).map(JSONValue.string) ?? .null,
                "responseStatus": cloudString($0["responseStatus"]).map(JSONValue.string) ?? .null]) }),
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
        if let title = object["title"] as? [[String: Any]] {
            return cloudClip(title.compactMap { cloudString($0["plain_text"]) }.joined(), limit: 500)
        }
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
                  let body = block[type] as? [String: Any] else {
                return nil
            }
            if let cells = body["cells"] as? [[[String: Any]]] {
                return cells.map { $0.compactMap { $0["plain_text"] as? String }.joined() }.joined(separator: "\t")
            }
            guard let richText = body["rich_text"] as? [[String: Any]] else { return nil }
            let text = richText.compactMap { $0["plain_text"] as? String }.joined()
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
        if let refresh = error as? GoogleOAuthCredentials.RefreshError {
            return "Google authorization refresh failed (HTTP \(refresh.statusCode))."
        }
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
        case .double(let value): Int(exactly: value.rounded(.towardZero))
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
