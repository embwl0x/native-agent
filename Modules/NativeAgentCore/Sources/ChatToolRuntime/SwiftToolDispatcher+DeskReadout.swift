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
import Studio
// Blueprint: | `SwiftToolDispatcher+DeskReadout.swift` | `SwiftToolDispatcher`; canonical live/archive paging; a table contact's Desk and piece read |

extension SwiftToolDispatcher {
    func impl_desk_read(input: [String: JSONValue]) async throws -> JSONValue {
        try ToolArguments.requireDeclaredKeys(input, descriptor: BuiltInToolSchemaFactory(requestedNames: ["desk_read"]).deskSchemas().compactMap { $0 }.first)
        let store = deskStore()
        let state = try await store.liveState()
        for key in ["handle", "query", "sort", "updated_on"] where input[key] != nil {
            guard case .string? = input[key] else {
                throw ToolFailureError("\(key) must be a string.", argumentPath: "$.\(key)", effects: .none, code: "invalid_input")
            }
        }
        for key in ["limit", "offset", "notes_offset", "refs_offset", "detail_offset", "archived_offset"] where input[key] != nil {
            guard let value = Self.jsonInt(input[key]), value >= (key == "limit" ? 1 : 0), value <= (key == "limit" ? 100 : 1_000_000) else {
                throw ToolFailureError("\(key) must be an integer in \(key == "limit" ? "1…100" : "0…1000000").", argumentPath: "$.\(key)",
                    effects: .none, code: "invalid_input")
            }
        }
        if let sort = optionalString(input, "sort"), !["stale", "recent"].contains(sort) {
            throw ToolFailureError("sort must be recent or stale.", argumentPath: "$.sort", effects: .none, code: "invalid_input")
        }
        let handle = optionalString(input, "handle")?
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
                throw ToolFailureError("updated_on must be today or YYYY-MM-DD in the Mac's local timezone.", argumentPath: "$.updated_on",
                    effects: .none, code: "invalid_input")
            }
            day = Calendar.current.dateInterval(of: .day, for: date)
        } else { day = nil }
        func matchesDate(_ stamp: String) -> Bool {
            guard let day else { return true }
            guard let date = DeskClock.parseISO(stamp) else { return false }
            return date >= day.start && date < day.end
        }
        guard handle?.isEmpty != false || query?.isEmpty != false else {
            throw ToolFailureError("Use handle for one exact item or query for text search, not both.", argumentPath: "$.query", effects: .none,
                code: "invalid_input")
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
            let exact = try state.matching(handle)
            if exact.isEmpty, !includeArchived {
                throw ToolFailureError("No live item has handle '\(handle)'; desk.read lists the current handles.", argumentPath: "$.handle",
                    effects: .none, code: "invalid_input")
            }
            rawMatches = exact.filter { matchesDate($0.updatedAt) }
        } else if query?.isEmpty == false || day != nil {
            rawMatches = state.items.filter { item in
                matchesDate(item.updatedAt) && matchesText([item.alias, item.handle, item.project, item.title, item.summary ?? ""]
                    + (item.step.map { [$0.words, $0.source ?? ""] } ?? []))
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
                if let handle, !handle.isEmpty { return record.handle == DeskState.reference(handle) }
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
                var args: [String: JSONValue] = ["include_archived": .bool(true), "archived_offset": .int(Int64(offset + shown.count)),
                    "limit": .int(Int64(limit))]
                if let handle, !handle.isEmpty { args["handle"] = .string(handle) }
                if let query, !query.isEmpty { args["query"] = .string(query) }
                args["updated_on"] = input["updated_on"]
                nextArchiveRead = .object(["tool": .string("app"), "input": .object([
                    "action": .string("desk.read"), "args": .object(args)])])
            }
        }
        if let handle, archivedMatchCount == 0, try state.matching(handle).isEmpty {
            throw deskInvalid("handle", reason: "No item has handle '\(handle)'; desk.read lists the current handles.")
        }
        guard case .object(var result) = Self.workspaceDesk(state: state, input: input, handle: handle, query: query, matches: rawMatches,
                                                           peerName: deskPeerName()) else {
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

// MARK: - The table

extension SwiftToolDispatcher {
    /// Characters of a piece's words in one read.
    static let tablePage = 16_000

    /// The arguments a contact at the table reads with: `desk_read`'s own, and `piece` with its `version` and `text_offset`.
    package static func tableReadParameters() throws -> JSONValue {
        guard let desk = BuiltInToolSchemaFactory(requestedNames: ["desk_read"]).deskSchemas().compactMap({ $0 }).first,
              case .object(var parameters) = try JSONValue.parse(desk.parametersJSON),
              case .object(var properties)? = parameters["properties"] else {
            throw ToolFailureError("desk_read's argument schema could not be read.", effects: .none, code: "tool_schema_unavailable")
        }
        properties["piece"] = .object(["type": .string("string"), "description": .string("""
            A make_ref from an open item's on_the_table: reads that piece instead of the Desk. Text (HTML, Markdown, CSV, plain text) up to 2 MB \
            comes back as its words; anything else as its title, kind, version and size.
            """)])
        properties["version"] = .object(["type": .string("integer"), "minimum": .int(1),
            "description": .string("With piece: the version to read; default its newest.")])
        properties["text_offset"] = .object(["type": .string("integer"), "minimum": .int(0),
            "description": .string("With piece: the character its words start from; copy next_text_offset to read on.")])
        parameters["properties"] = .object(properties)
        return .object(parameters)
    }

    /// A contact at the table reads the Desk as `desk_read` gives it, or, with `piece`, one piece on the table (`DeskPiece.onTable`). The rest of Make is
    /// not on the table.
    package func tableRead(input: [String: JSONValue]) async throws -> JSONValue {
        guard let piece = input["piece"] else { return try await impl_desk_read(input: input) }
        guard case .string(let raw) = piece, MakeStudio.isRef(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw deskInvalid("piece", reason: "piece is a make_ref string from an item's on_the_table.")
        }
        if let other = input.keys.sorted().first(where: { !["piece", "version", "text_offset"].contains($0) }) {
            throw deskInvalid(other, reason: "With piece, the only other arguments are version and text_offset.")
        }
        var version: Int?
        if let given = input["version"] {
            guard let n = Self.jsonInt(given), n >= 1 else { throw deskInvalid("version", reason: "version is a whole number from 1.") }
            version = n
        }
        var start = 0
        if let given = input["text_offset"] {
            guard let n = Self.jsonInt(given), n >= 0 else { throw deskInvalid("text_offset", reason: "text_offset is a whole number from 0.") }
            start = n
        }
        let ref = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state = try await deskStore().liveState()
        let laid = DeskPiece.onTable(state).map(\.ref).filter { DeskPiece.makeRef($0) == ref }
        guard !laid.isEmpty else {
            throw ToolFailureError("""
                \(ref) is not on the table: only a piece laid on an open board item is. An open item's on_the_table lists what is.
                """, argumentPath: "$.piece", effects: .none, code: "not_on_the_table")
        }
        var title = ref
        for laidRef in laid { if case .url(_, let label?) = laidRef.kind { title = label; break } }
        let studio = MakeStudio(dataRoot: dataRoot)
        guard let meta = try studio.readMeta(ref), let newest = meta.versions.last else {
            throw ToolFailureError("\(ref) is laid on the Desk, but Make holds no version of it.", argumentPath: "$.piece", effects: .none,
                code: "piece_has_no_version")
        }
        let chosen: MakeStudio.Version
        if let version {
            guard let found = meta.versions.first(where: { $0.n == version }) else {
                throw deskInvalid("version", reason: "\(ref) has versions \(meta.versions.map { String($0.n) }.joined(separator: ", ")).")
            }
            chosen = found
        } else { chosen = newest }
        let file = studio.url(ref, chosen)
        let type = file.pathExtension.lowercased()
        // The same words the Desk page uses for what a piece is.
        let kind = MakeStudio.textTypes.contains(type) ? "document" : MakeStudio.webTypes.contains(type) ? "page"
            : MakeStudio.imageTypes.contains(type) ? "picture" : "file"
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw ToolFailureError("\(ref) version \(chosen.n) has no readable size.", effects: .none, code: "piece_unreadable")
        }
        var result: [String: JSONValue] = ["status": .string("ok"), "source": .string("make"), "piece": .object([
            "make_ref": .string(ref), "title": .string(title), "kind": .string(kind), "type": .string(type),
            "version": .int(Int64(chosen.n)), "newest_version": .int(Int64(newest.n)), "size": .int(Int64(size)),
            "created": .string(chosen.created)])]
        guard kind == "document" || kind == "page" else {
            result["detail"] = .string("A \(kind) reads as its facts here; its bytes stay on the Mac.")
            return .object(result)
        }
        // The file's own size bounds the read before any byte of it is loaded.
        guard size <= MakePreviewFace.wordsLimit else {
            result["detail"] = .string("Its words are too long to read here (over \(MakePreviewFace.wordsLimit / 1_000_000) MB), so it reads as its facts.")
            return .object(result)
        }
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ToolFailureError("\(ref) version \(chosen.n) is not UTF-8 text, so its words cannot be read.", effects: .none, code: "piece_unreadable")
        }
        guard let from = text.index(text.startIndex, offsetBy: start, limitedBy: text.endIndex) else {
            throw deskInvalid("text_offset", reason: "text_offset is past the end: this version has \(text.count) characters.")
        }
        let to = text.index(from, offsetBy: Self.tablePage, limitedBy: text.endIndex) ?? text.endIndex
        result["text"] = .string(String(text[from..<to]))
        result["text_offset"] = .int(Int64(start))
        result["has_more"] = .bool(to < text.endIndex)
        if to < text.endIndex { result["next_text_offset"] = .int(Int64(start + text.distance(from: from, to: to))) }
        return .object(result)
    }
}
