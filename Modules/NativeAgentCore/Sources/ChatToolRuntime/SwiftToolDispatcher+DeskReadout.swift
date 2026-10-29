import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
import Experiences
import ToolExecution
import AuthoredCapabilities
import StandingBots
import Research
import CryptoKit
import PersonaEngine
import MemoryV2
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
// Blueprint: | `SwiftToolDispatcher+DeskReadout.swift` | `SwiftToolDispatcher`: live and archive Desk reading through the existing store; canonical row paging retains all fields independent of sort and carries archive continuations |

extension SwiftToolDispatcher {
    /// Page the live Desk or search by handle/alias/text, optionally including archived records.
    func impl_desk_read(input: [String: JSONValue]) async throws -> JSONValue {
        let store = deskStore()
        let state = try await store.liveState()
        // MY QUEUE is on her home and remains reachable by handle or query.
        guard input["handle"] == nil || input["id"] == nil || input["handle"] == input["id"] else {
            throw ToolFailureError("handle and id must agree.", argumentPath: "$.id", effects: .none, code: "invalid_input")
        }
        for key in ["handle", "id", "query", "sort", "updated_on"] where input[key] != nil {
            guard case .string? = input[key] else {
                throw ToolFailureError("\(key) must be a string.", argumentPath: "$.\(key)", effects: .none, code: "invalid_input")
            }
        }
        for key in ["limit", "offset", "notes_offset", "refs_offset", "detail_offset", "archived_offset"] where input[key] != nil {
            guard let value = Self.jsonInt(input[key]), value >= (key == "limit" ? 1 : 0), value <= (key == "limit" ? 100 : 1_000_000) else {
                throw ToolFailureError("\(key) must be an integer in \(key == "limit" ? "1…100" : "0…1000000").", argumentPath: "$.\(key)", effects: .none, code: "invalid_input")
            }
        }
        if let sort = optionalString(input, "sort"), !["stale", "recent"].contains(sort) {
            throw ToolFailureError("sort must be recent or stale.", argumentPath: "$.sort", effects: .none, code: "invalid_input")
        }
        let handle = (optionalString(input, "handle") ?? optionalString(input, "id"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if handle == "" {
            throw ToolFailureError("handle must not be empty.", argumentPath: "$.handle", effects: .none, code: "invalid_input")
        }
        let query = optionalString(input, "query")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedOn = optionalString(input, "updated_on")
        let day: DateInterval?
        if let updatedOn {
            let formatter = DateFormatter()
            formatter.calendar = Calendar.current
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = updatedOn == "today" ? Date() : formatter.date(from: updatedOn),
                  updatedOn == "today" || formatter.string(from: date) == updatedOn else {
                throw ToolFailureError("updated_on must be today or YYYY-MM-DD in the Mac's local timezone.", argumentPath: "$.updated_on", effects: .none, code: "invalid_input")
            }
            day = Calendar.current.dateInterval(of: .day, for: date)
        } else { day = nil }
        func matchesDate(_ stamp: String) -> Bool {
            guard let day else { return true }
            guard let date = DeskClock.parseISO(stamp) else { return false }
            return date >= day.start && date < day.end
        }
        guard handle?.isEmpty != false || query?.isEmpty != false else {
            throw ToolFailureError("Use handle for one exact item or query for text search, not both.", argumentPath: "$.query", effects: .none, code: "invalid_input")
        }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let locale = Locale(identifier: "en_US_POSIX")
        let needle = query?.folding(options: options, locale: locale) ?? ""
        func matchesText(_ values: [String]) -> Bool {
            return needle.isEmpty || values.contains { $0.folding(options: options, locale: locale).contains(needle) }
        }
        let includeArchived = flag(input, "include_archived")
        let rawMatches: [DeskItem]
        if let handle, !handle.isEmpty {
            let exact = try Self.deskMatches(handle, in: state)
            if exact.isEmpty, !includeArchived {
                throw ToolFailureError("No live item has handle '\(handle)'; desk.read lists the current handles.", argumentPath: "$.handle", effects: .none, code: "invalid_input")
            }
            rawMatches = exact.filter { matchesDate($0.updatedAt) }
        } else if query?.isEmpty == false || day != nil {
            rawMatches = state.items.filter { item in
                matchesDate(item.updatedAt) && matchesText([item.alias, item.handle, item.project, item.title, item.summary ?? ""])
            }
        } else {
            rawMatches = []
        }
        var archiveProjection = ""
        var archivedMatchCount = 0
        var nextArchiveRead: JSONValue = .null
        var archives: JSONValue = .null
        if includeArchived {
            let archived = try await store.archivedRecords().filter { record in
                guard matchesDate(record.closedAt) else { return false }
                if let handle, !handle.isEmpty { return record.handle == Self.deskAlias(handle) }
                return matchesText([record.handle, record.project, record.title, record.summary])
            }
            archivedMatchCount = archived.count
            let limit = Self.jsonInt(input["limit"]) ?? 25
            let offset = Self.jsonInt(input["archived_offset"]) ?? Self.jsonInt(input["offset"]) ?? 0
            let shown = Array(archived.dropFirst(offset).prefix(limit))
            let archiveText = shown.map {
                "  \($0.handle) \($0.finalStatus.rawValue) \($0.project) · \($0.title) — \($0.summary)"
            }.joined(separator: "\n")
            archiveProjection = "\n\narchived (\(archived.count) matching, offset \(offset)):\n" + archiveText
            archives = .object([
                "items": .array(shown.map { .object([
                    "handle": .string($0.handle), "title": .string($0.title), "project": .string($0.project),
                    "summary": .string($0.summary), "status": .string($0.finalStatus.rawValue), "closed_at": .string($0.closedAt),
                ]) }),
                "total": .int(Int64(archived.count)), "count": .int(Int64(shown.count)),
                "limit": .int(Int64(limit)), "offset": .int(Int64(offset)), "has_more": .bool(offset + shown.count < archived.count),
            ])
            if offset + shown.count < archived.count {
                var args: [String: JSONValue] = ["include_archived": .bool(true), "archived_offset": .int(Int64(offset + shown.count)), "limit": .int(Int64(limit))]
                if let handle, !handle.isEmpty { args["handle"] = .string(handle) }
                if let query, !query.isEmpty { args["query"] = .string(query) }
                args["updated_on"] = input["updated_on"]
                if input["structured"] == .bool(true) { args["structured"] = .bool(true) }
                nextArchiveRead = .object(["tool": .string("app"), "input": .object([
                    "action": .string("desk.read"), "args": .object(args)])])
            }
        }
        if let handle, archivedMatchCount == 0, try Self.deskMatches(handle, in: state).isEmpty {
            throw deskInvalid("handle", reason: "No item has handle '\(handle)'; desk.read lists the current handles.")
        }
        guard case .object(var result) = Self.workspaceDesk(state: state, input: input, handle: handle, query: query, matches: rawMatches) else {
            preconditionFailure("Desk projection must be an object")
        }
        if includeArchived {
            result["archives"] = archives
            result["archived_projection"] = .string(archiveProjection)
            result["archivedMatchCount"] = .int(Int64(archivedMatchCount))
            result["next_archive_read"] = nextArchiveRead
            result["archives_has_more"] = .bool(nextArchiveRead != .null)
            result["archives_total"] = .int(Int64(archivedMatchCount))
            if archivedMatchCount > 0 { result["status"] = .string("ok"); result["detail"] = nil }
        }
        return .object(result)
    }
}
