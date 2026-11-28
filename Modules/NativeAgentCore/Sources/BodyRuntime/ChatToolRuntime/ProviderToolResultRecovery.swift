import MacNerves
import MindCore
import NativeAgentShared
import SenseCore
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
// Blueprint: | `ProviderToolResultRecovery.swift` | `SwiftToolDispatcher`, `impl_tool_result_page`: Retain results for the record's detail horizon. |

/// The room one answer still has, shared by the steps of one `actions` call. A page read fills only what is left, so a batch of
/// reads never outgrows the answer and is never itself retained and paged.
package final class AnswerRoom: @unchecked Sendable {
    /// What a step that reads nothing still costs the answer: its receipt saying so, with its place.
    private static let pointer = 1_000
    private let lock = NSLock()
    private var left = ProviderToolResultPage.defaultMaxUTF8Bytes - 2_000
    private var steps: Int
    package init(steps: Int) { self.steps = max(1, steps) }
    /// What the step now running may fill: `whole` is the room less a pointer for each step still to come, so a first page is read
    /// whenever it fits; `share` is that room split evenly with them, which bounds how many further pages this read joins.
    package var allowance: (whole: Int, share: Int) {
        lock.withLock {
            let whole = left - Self.pointer * (steps - 1)
            return (whole, whole / steps)
        }
    }
    package func take(_ bytes: Int) { lock.withLock { left -= bytes; steps = max(1, steps - 1) } }
}
package enum AnswerRoomPart: NativeAgentCore.TurnPart { package static let unset: AnswerRoom? = nil }

/// Bound a view only after its redacted body is retained. Script steps and outer calls use this same owner.
package enum ProviderToolResultPage {
    package static let defaultMaxUTF8Bytes = 48_000

    package static func redactedContent(_ content: String) throws -> String {
        let parsed = try? JSONValue.parse(Data(content.utf8))
        return ChatSecretRedactor.redactText(try parsed.map { try TurnTraceRedactor.redactValue($0).serialize(pretty: false) } ?? content)
    }

    package struct View: Sendable {
        package let content: String
        package let recovery: JSONValue?
        package let failed: Bool
    }

    @concurrent package static func project(
        toolName: String,
        content: String,
        dataRoot: URL?,
        turn: Turn,
        originalResultClass: ChatToolOutcome.ExactResultClass,
        appDoor: Bool,
        inlineLimit: Int = defaultMaxUTF8Bytes,
        includeSections: Bool = true,
        batchActions: [JSONValue]? = nil
    ) async -> View {
        var recovery: JSONValue?
        do {
            let content = try redactedContent(content)
            guard content.utf8.count > inlineLimit else { return View(content: content, recovery: nil, failed: false) }
            guard let dataRoot else { throw ToolFailureError("The engine's result storage root is unavailable.", effects: .unknown) }
            // A plain-text tool answer has no parsed envelope; it is still retained byte for byte.
            let parsed = try? JSONValue.parse(Data(content.utf8))
            let receipt = try await ProviderToolResultRecoveryStore.shared.store(
                content: content, toolName: toolName, dataRoot: dataRoot, conversation: ChatToolSessionInjection.currentSession(turn: turn),
                originalResultClass: originalResultClass)
            var reference: [String: JSONValue] = [
                "result_handle": .string(receipt.handle), "full_result_retained": .bool(receipt.omittedBytes == 0),
                "original_bytes": .int(Int64(receipt.bytes + receipt.omittedBytes)),
                "omitted_bytes": .int(Int64(receipt.omittedBytes)),
                "retention_limit_bytes": .int(Int64(ProviderToolResultRecoveryStore.maxBodyUTF8Bytes)),
                "next_call": .object(["tool": .string("app"), "input": .object([
                    "action": .string("result.page"), "args": .object([
                        "result_handle": .string(receipt.handle), "page": .int(0), "raw": .bool(true)])])]),
            ]
            reference["saved_result_path"] = .string(receipt.url.path)
            if receipt.omittedBytes > 0 {
                reference["retention_detail"] = .string(
                    "Kept the first \(receipt.bytes) redacted bytes; cut \(receipt.omittedBytes) tail bytes at the retention limit.")
            }
            recovery = .object(reference)
            var fields = reference
            if includeSections {
                let steps = receipt.omittedBytes == 0 && batchActions != nil ? parsed?.objectValue?["receipts"]?.arrayValue : nil
                let result = await ProviderToolResultRecoveryStore.shared.page(
                    handle: receipt.handle, page: 0, dataRoot: dataRoot, turn: turn, query: "",
                    pages: steps == nil ? ProviderToolResultRecoveryStore.usualSectionPages : 1,
                    overview: steps.flatMap { receipts in batchActions.map { (receipts, $0) } })
                guard case .object(let page) = result, ToolResult(result).said("completed") else {
                    return View(content: try result.serialize(pretty: false), recovery: recovery, failed: true)
                }
                fields.merge(page) { _, page in page }
                fields["recovery_tool"] = .string(appDoor ? "app result.page" : "tool_result_page")
                if appDoor, case .string(let detail)? = fields["detail"] {
                    fields["detail"] = .string(ToolNameAliases.foldedProse(detail))
                }
            }
            fields["provider_projection"] = .string("bounded_tool_result")
            fields["tool"] = .string(appDoor ? ToolNameAliases.appAction(toolName) ?? toolName : toolName)
            fields["original_result_class"] = .string(originalResultClass.rawValue)
            fields["verification_scope"] = .string("tool_response_not_external_outcome")
            fields["original_characters"] = .int(Int64(content.count))
            fields["retained_bytes"] = .int(Int64(receipt.bytes))
            fields["retention_reason"] = .string("response_exceeds_inline_limit")
            if case .object(let receipt)? = parsed {
                fields["repeat"] = receipt["repeat"]
                fields["repeat_note"] = receipt["repeat_note"]
            }
            return View(content: try JSONValue.object(fields).serialize(pretty: false), recovery: recovery, failed: false)
        } catch {
            // Retention failure is its own failure, never an unretained prefix or a verdict about the original effects.
            let kept = recovery?.objectValue?["result_handle"]?.stringValue.map {
                " The retained body is at \($0); read app result.page with result_handle:\"\($0)\", raw:true, page:0 and follow next_page."
            } ?? " The body could not be retained."
            return View(content: """
                Result retention/projection failed: \(String(error.localizedDescription.prefix(300))). Original result class: \(originalResultClass.rawValue). \
                No clipped result was delivered.\(kept) Inspect the original dispatch receipt and repair result storage before repeating an action.
                """, recovery: recovery, failed: true)
        }
    }
}

/// Redacted results live with their record, with an explicit cut past the body cap; memory holds only a rebuildable paging cache.
package actor ProviderToolResultRecoveryStore {
    package static let shared = ProviderToolResultRecoveryStore()

    package static let pageUTF8Bytes = 8_000
    /// No common upstream result cap exists; keep this head and explicitly name any omitted tail.
    package static let maxBodyUTF8Bytes = 4 * 1024 * 1024

    /// Bound pages by raw and serialized bytes, leaving envelope space below the projection ceiling.
    package static let pageSerializedUTF8Bytes = 10_000

    /// Bytes one scalar costs INSIDE a serialized JSON string, matching `JSONValue.encodeString` exactly.
    package static func jsonEscapedByteCount(_ v: UInt32) -> Int {
        switch v {
        case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: return 2
        default:
            if v < 0x20 { return 6 }
            if v < 0x7F { return 1 }
            if v <= 0xFFFF { return 6 }
            return 12
        }
    }
    package struct Receipt: Sendable {
        package let handle: String
        package let url: URL
        package let pageCount: Int
        package let characters: Int
        package let bytes: Int
        package let omittedBytes: Int
        package let resultClass: ChatToolOutcome.ExactResultClass
    }

    private struct Entry: Sendable {
        let handle: String
        let toolName: String
        let content: Data
        let characters: Int
        let conversations: Set<String>
        let omittedBytes: Int
        let originalBytes: Int
        let resultClass: ChatToolOutcome.ExactResultClass
        let pageByteOffsets: [Int]
        let sectionBudget: Int
        let version: JSONValue?
        /// The retained answer's own continuation of its source, apart from page position.
        let source: JSONValue?
        let sectionProjection: [(value: JSONValue, text: String, bytes: Int)]
        var sectionPages: (query: String, pages: [[JSONValue]], counts: [Int])?
        /// The last query's search, read only as far as its pages have been asked for.
        var search: ToolResultSections.Search?
    }

    /// A rebuildable paging cache of the most recently read bodies; the files are the record.
    private var entries: [URL: Entry] = [:]
    private var cacheOrder: [URL] = []
    private static let cachedEntries = 8
    /// Pruning runs on the first store of each day per root, not on every call.
    private var prunedDay: [URL: Date] = [:]
    private struct ReadCursor {
        let handle: String
        let nextPage: Int?
        let query: String?
    }
    private var readCursors: [String: ReadCursor] = [:]

    package func store(
        content: String,
        toolName: String,
        dataRoot: URL,
        conversation: String?,
        originalResultClass: ChatToolOutcome.ExactResultClass,
        sectionBudget: Int = ToolResultSections.pageBudget
    ) throws -> Receipt {
        let root = dataRoot.standardizedFileURL.appendingPathComponent("tool_results", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let day = Calendar.current.startOfDay(for: Date())
        if prunedDay[root] != day {
            // A prune that fails is tried again on the next store; it never costs this result its retention.
            do { try cleanupExpired(root: root, now: Date()); prunedDay[root] = day }
            catch { nativeLog("[results] pruning %@ failed: %@", root.path, error.localizedDescription) }
        }

        let redacted = try ProviderToolResultPage.redactedContent(content)
        let data = Data(redacted.utf8)
        var head = min(data.count, Self.maxBodyUTF8Bytes)
        while String(data: data.prefix(head), encoding: .utf8) == nil { head -= 1 }
        let omittedBytes = data.count - head
        let content = String(decoding: data.prefix(head), as: UTF8.self) + (omittedBytes == 0 ? "" :
            "\n[Result body cut: kept \(head) bytes; \(omittedBytes) bytes omitted by the \(Self.maxBodyUTF8Bytes)-byte retention limit.]")
        let parsed = try? JSONValue.parse(Data(content.utf8))
        let fields = (try? JSONValue.parse(Data(redacted.utf8)))?.objectValue ?? [:]
        let receipt = if case .string(let id)? = fields["dispatch_receipt_id"] { UUID(uuidString: id) } else { nil as UUID? }
        let source = if case .string(let source)? = fields["dispatch_receipt_source"] { source } else { "" }
        // The same receipt can have distinct redacted views. Never overwrite bytes already promised by another view's handle.
        let digest = SHA256Hex.of(Data((toolName + "\u{0}" + content).utf8))
        let handle = (source == "detail" ? receipt : nil)
            .map { "receipt-" + $0.uuidString.lowercased() + "." + digest } ?? digest
        let url = root.appendingPathComponent(handle)
        var conversations = Set(conversation.map { [$0] } ?? [])
        if FileManager.default.fileExists(atPath: url.path) {
            conversations.formUnion(try loadEntry(handle: handle, url: url).conversations)
        }
        let entry = try makeEntry(handle: handle, content: content, parsed: parsed, toolName: toolName,
            originalResultClass: originalResultClass, sectionBudget: sectionBudget, conversations: conversations,
            omittedBytes: omittedBytes, originalBytes: data.count)
        let saved: JSONValue = .object(["content": .string(content), "tool": .string(toolName),
            "conversations": .array(conversations.sorted().map(JSONValue.string)), "omitted_bytes": .int(Int64(omittedBytes)),
            "original_bytes": .int(Int64(data.count)),
            "original_result_class": .string(originalResultClass.rawValue), "section_budget": .int(Int64(sectionBudget))])
        try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(try saved.serialize(pretty: false).utf8), to: url)
        cache(entry, at: url)
        return Receipt(handle: entry.handle, url: url, pageCount: entry.pageByteOffsets.count - 1,
            characters: entry.characters, bytes: head, omittedBytes: omittedBytes, resultClass: entry.resultClass)
    }

    private func makeEntry(handle: String, content: String, parsed: JSONValue?, toolName: String,
                           originalResultClass: ChatToolOutcome.ExactResultClass, sectionBudget: Int,
                           conversations: Set<String>, omittedBytes: Int, originalBytes: Int) throws -> Entry {
        let fields = parsed?.objectValue ?? [:]

        // Build valid Unicode-scalar byte boundaries once. Bounding bytes (not grapheme count) prevents a pathological combining sequence from becoming an
        // unexpectedly huge provider page.
        var pageByteOffsets = [0]
        var byteOffset = 0
        var pageStartByte = 0
        var pageSerializedBytes = 0
        for scalar in content.unicodeScalars {
            let value = scalar.value
            let scalarBytes = value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4
            let escapedBytes = Self.jsonEscapedByteCount(value)
            let overRaw = byteOffset - pageStartByte + scalarBytes > Self.pageUTF8Bytes
            let overSerialized = pageSerializedBytes + escapedBytes > Self.pageSerializedUTF8Bytes
            if byteOffset > pageStartByte, overRaw || overSerialized {
                pageByteOffsets.append(byteOffset)
                pageStartByte = byteOffset
                pageSerializedBytes = 0
            }
            byteOffset += scalarBytes
            pageSerializedBytes += escapedBytes
        }
        // Retain an empty page at [0, 0] so empty output remains readable.
        if pageByteOffsets.count == 1 || pageByteOffsets.last != byteOffset {
            pageByteOffsets.append(byteOffset)
        }

        let sections = try ToolResultSections.projection(content: content, value: parsed, budget: sectionBudget)
        let version = fields["version"]
        // An answer that said its source has more keeps that call beside every page: paging the answer never reaches the rest of the source.
        // Only an action of the app's own door is named: its next is that action's whole argument set, which another tool's cursor is not.
        var continues: JSONValue?
        if let action = fields["action"],
           let answer = [fields["result"]?.objectValue, fields].compactMap({ $0 }).first(where: { $0["has_more"] == .bool(true) }),
           case .object(let next)? = answer["next"] {
            let input: JSONValue = .object(["action": action, "args": .object(next)])
            continues = .object([
                "detail": .string("""
                    These pages hold only the part of its source this answer returned; the source continues past it, and paging never reaches \
                    the rest. Read on with next_call.
                    """),
                "next_call": .object(["tool": .string("app"), "input": input]),
            ])
        }
        return Entry(
            handle: handle,
            toolName: toolName,
            content: Data(content.utf8),
            characters: content.count,
            conversations: conversations,
            omittedBytes: omittedBytes,
            originalBytes: originalBytes,
            resultClass: originalResultClass,
            pageByteOffsets: pageByteOffsets,
            sectionBudget: sectionBudget,
            version: version,
            source: continues,
            sectionProjection: sections
        )
    }

    /// A read with no `pages` joins as many as one answer holds; the joiner's measure of the answer is what stops it.
    package static let usualSectionPages = Int.max

    /// The page numbers use the very same section layout that result.page will read.
    private static func batchOverview(receipts: [JSONValue], actions: [JSONValue], pages: [[JSONValue]]) -> JSONValue {
        var starts: [Int64: Int] = [:]
        for (page, sections) in pages.enumerated() {
            for section in sections {
                guard let path = section.objectValue?["path"]?.arrayValue, path.count >= 2,
                      path[0] == .string("receipts"), case .int(let index) = path[1], starts[index] == nil else { continue }
                starts[index] = page
            }
        }
        func excerpt(_ text: String, limit: Int) -> JSONValue {
            .string(text.utf8.count <= limit ? text : String(decoding: text.utf8.prefix(limit), as: UTF8.self) + "…")
        }
        return .array(receipts.enumerated().map { index, value in
            let fields = value.objectValue ?? [:]
            let step = fields["step"]?.integerValue.flatMap(Int.init(exactly:)) ?? (receipts.count == actions.count ? index + 1 : nil)
            var row: [String: JSONValue] = [:]
            if let step, step > 0, step <= actions.count {
                row["step"] = .int(Int64(step))
                let call = actions[step - 1].objectValue ?? [:]
                if let label = (call["action"] ?? call["page"])?.stringValue {
                    row["action"] = excerpt(ChatSecretRedactor.redactText(label), limit: 100)
                }
            }
            row["section_page"] = starts[Int64(index)].map { .int(Int64($0)) }
            for key in ["status", "ok", "reason", "error", "count", "liveItemCount", "has_more"] {
                guard let fact = fields[key] else { continue }
                switch fact {
                case .int, .bool: row[key] = fact
                case .string(let text): row[key] = excerpt(text, limit: 96)
                default: break
                }
            }
            let detail = fields["detail"]?.objectValue ?? [:]
            if let summary = [fields["summary"], fields["detail"], fields["message"], detail["summary"], fields["title"], fields["text"], value]
                .compactMap({ $0?.stringValue }).first(where: { !$0.isEmpty }) {
                row["summary"] = excerpt(summary, limit: 220)
            }
            if let first = (fields["items"] ?? fields["hits"] ?? fields["contacts"])?.arrayValue?.first?.objectValue,
               let name = (first["title"] ?? first["name"] ?? first["summary"])?.stringValue {
                row["first_item"] = excerpt(name, limit: 100)
            }
            return .object(row)
        })
    }

    package func page(
        handle: String,
        page: Int,
        dataRoot: URL,
        turn: Turn,
        query: String? = nil,
        pages: Int = 1,
        overview: (receipts: [JSONValue], actions: [JSONValue])? = nil
    ) -> JSONValue {
        let key = dataRoot.standardizedFileURL.appendingPathComponent("tool_results/" + handle)
        var result = readPage(handle: handle, page: page, dataRoot: dataRoot, turn: turn, query: query)
        func bytes(_ value: JSONValue?) -> Int { (try? (value ?? .null).serialize(pretty: false).utf8.count) ?? .max }
        // The same read, named by its page: inside a batch several results are read at once, and the turn holds one cursor.
        func call(at page: Int) -> JSONValue {
            var args: [String: JSONValue] = ["result_handle": .string(handle), "page": .int(Int64(page))]
            if let query { if !query.isEmpty { args["query"] = .string(query) } } else { args["raw"] = .bool(true) }
            if pages < Self.usualSectionPages { args["pages"] = .int(Int64(pages)) }
            return .object(["tool": .string("app"), "input": .object(["action": .string("result.page"), "args": .object(args)])])
        }
        let room = turn[AnswerRoomPart.self]?.allowance
        // A page with no room left beside the batch's other steps is not read; its place is kept.
        if let room, ToolResult(result).said("completed"), bytes(result) + bytes(entries[key]?.version) + 1_000 > room.whole {
            let read = result.objectValue ?? [:]
            return .object(["status": .string("completed"), "result_handle": .string(handle), "page": .int(Int64(page)),
                "page_count": read["page_count"] ?? .null,
                "raw_page_count": .int(Int64(max(1, (entries[key]?.pageByteOffsets.count ?? 2) - 1))),
                "original_bytes": entries[key].map { .int(Int64($0.originalBytes)) } ?? .null,
                "pages_read": .int(0), "next_page": .int(Int64(page)), "has_more": .bool(true), "reading_complete": .bool(false),
                "recovery_only": .bool(true),
                "detail": .string("This answer is full, so this page was not read. Read it with next_call."),
                "next_call": call(at: page)])
        }
        // A read of several pages joins them in order while the whole answer stays within what one answer holds. Each mode's page size
        // differs, so the body is measured, never assumed: that measure alone sets how many pages one answer carries.
        if pages > 1, case .object(var answer) = result, ToolResult(result).said("completed") {
            let body = query.map { ToolResultSections.queryTerms($0).isEmpty ? "sections" : "matches" } ?? "content"
            // The body may fill what one answer holds less everything else the answer carries, with 1,000 bytes for what it gains below.
            let budget = (room?.share ?? ProviderToolResultPage.defaultMaxUTF8Bytes) - 1_000 - max(0, bytes(result) - bytes(answer[body]))
            func int(_ key: String) -> Int { if case .int(let value)? = answer[key] { Int(value) } else { 0 } }
            var used = bytes(answer[body]), read = 1
            while read < pages, case .int(let next)? = answer["next_page"] {
                let more = readPage(handle: handle, page: Int(next), dataRoot: dataRoot, turn: turn, query: query)
                guard case .object(var joined) = more, ToolResult(more).said("completed") else { return more }
                let added = bytes(joined[body])
                guard added <= budget - used else { break }
                used += added
                if case .string(let head)? = answer[body], case .string(let tail)? = joined[body] { joined[body] = .string(head + tail) }
                if case .array(let head)? = answer[body], case .array(let tail)? = joined[body] { joined[body] = .array(head + tail) }
                for count in ["page_bytes", "displayed_sections", "displayed_matches"] {
                    if case .int(let head)? = answer[count], case .int(let tail)? = joined[count] { joined[count] = .int(head + tail) }
                }
                answer = joined
                read += 1
            }
            answer["pages_read"] = .int(Int64(read))
            // `page` is where this answer starts, as it was asked; `pages_read` and `next_page` say how far it went.
            let last = int("page")
            answer["page"] = .int(Int64(page))
            if body == "sections" {
                let detail = Self.sectionsDetail(first: page, last: last, count: int("page_count"), raw: int("raw_page_count"),
                    displayed: int("displayed_sections"), matching: int("matching_sections"), remaining: int("remaining_sections"))
                answer["detail"] = .string(detail)
            }
            if body == "matches" {
                answer["detail"] = .string(Self.matchesDetail(first: page, last: last, raw: int("raw_page_count"),
                    displayed: int("displayed_matches"), searched: int("searched_sections"), sections: int("section_count"),
                    readAs: answer["query_read_as"]?.stringValue.flatMap { ToolResultSections.Search.Reading(rawValue: $0) } ?? .phrase))
            }
            result = .object(answer)
        }
        let reply = ToolResult(result)
        if case .object(var object) = result, reply.said("completed"), reply.status == object["status"]?.stringValue {
            if let overview, let layout = entries[key]?.sectionPages?.pages {
                object["steps"] = Self.batchOverview(receipts: overview.receipts, actions: overview.actions, pages: layout)
                object["step_readback"] = .string("To inspect a step, read app result.page with this result_handle and its section_page as page.")
            }
            let next: Int?
            if case .int(let value)? = object["next_page"] { next = Int(exactly: value) }
            else { next = nil }
            readCursors[turn.id] = ReadCursor(handle: handle, nextPage: next, query: query)
            object["full_result_retained"] = .bool(entries[key]?.omittedBytes == 0)
            object["omitted_bytes"] = entries[key].map { .int(Int64($0.omittedBytes)) }
            object["version"] = entries[key]?.version
            var args: [String: JSONValue] = ["continue": .bool(true), "result_handle": .string(handle)]
            // Continuing already reads as much as fits; only an asked count travels with it.
            if pages < Self.usualSectionPages { args["pages"] = .int(Int64(pages)) }
            object["next_call"] = next.map { room == nil ? .object(["tool": .string("app"), "input": .object([
                "action": .string("result.page"), "args": .object(args)])]) : call(at: $0) } ?? .null
            result = .object(object)
        }
        return result
    }

    /// Continue the exact last read in this turn, preserving its query/mode. A first read names its retained result.
    /// A query or raw given with the continuation is the read wanted: the same read goes on from its position, a different one starts at its page 0.
    /// An empty query is the whole-sections read: after a search it starts that read at page 0.
    package func continueReading(handle: String?, dataRoot: URL, turn: Turn, pages: Int = 1,
                                 query: String? = nil, raw: Bool = false) -> JSONValue {
        if let cursor = readCursors[turn.id], handle == nil || handle == cursor.handle {
            // A read is raw (nil), whole sections (a query without terms, "" here) or a search; a mode left unnamed keeps the cursor's.
            func reading(_ query: String?) -> String? { query.map { ToolResultSections.queryTerms($0).isEmpty ? "" : $0 } }
            let mode = raw ? nil : query ?? cursor.query
            if reading(mode) != reading(cursor.query) {
                return page(handle: cursor.handle, page: 0, dataRoot: dataRoot, turn: turn, query: mode, pages: pages)
            }
            guard let next = cursor.nextPage else {
                let check = readPage(handle: cursor.handle, page: 0, dataRoot: dataRoot, turn: turn, query: nil)
                guard ToolResult(check).said("completed") else { return check }
                let key = dataRoot.standardizedFileURL.appendingPathComponent("tool_results/" + cursor.handle)
                var end: [String: JSONValue] = ["status": .string("completed"), "result_handle": .string(cursor.handle),
                    "has_more": .bool(false), "reading_complete": .bool(true),
                    "full_result_retained": .bool(entries[key]?.omittedBytes == 0), "next_call": .null,
                    "recovery_only": .bool(true),
                    "verification_scope": .string("retained_tool_response_not_external_outcome"),
                    "original_result_class": .string(entries[key]?.resultClass.rawValue ?? "unknown"),
                    "detail": .string("You reached the end of this retained result. No operation was repeated.")]
                end["source_continues"] = entries[key]?.source
                return .object(end)
            }
            return page(handle: cursor.handle, page: next, dataRoot: dataRoot, turn: turn, query: cursor.query, pages: pages)
        }
        guard let handle else {
            return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("missing_result_handle"),
                "recovery_hint": .string("Name result_handle for the first read in this turn; subsequent continue reads keep its position.")])
        }
        return page(handle: handle, page: 0, dataRoot: dataRoot, turn: turn, query: raw ? nil : query ?? "", pages: pages)
    }

    private func unavailable(handle: String, reason: String, cause: String = "") -> JSONValue {
        let receipt = handle.hasPrefix("receipt-") ? UUID(uuidString: String(handle.dropFirst(8).prefix(36))) : nil
        var args: [String: JSONValue] = ["view": .string("receipts")]
        // The receipt is found by its own id wherever it was recorded; only listing receipts needs this conversation.
        if let receipt { args["receipt_id"] = .string(receipt.uuidString.lowercased()) }
        let recovery = receipt == nil
            ? "This handle has no bound receipt; next_call lists this conversation's receipts."
            : "next_call reads the original dispatch receipt."
        return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string(reason),
            "detail": .string("""
                Retained output \(handle) is unavailable. \(cause) \
                \(recovery) \
                Missing output does not establish failure; never repeat a write to recover output.
                """),
            "remedy": .object(["kind": .string("inspect"),
                "instruction": .string("Read the retained receipt with next_call; missing output never authorizes repeating a write."),
                "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("trace.recent"), "args": .object(args)])])])])
    }

    /// Pages are named by the same zero-based numbers the `page` argument and `next_page` use.
    private static func sectionsDetail(first: Int, last: Int, count: Int, raw: Int, displayed: Int, matching: Int, remaining: Int) -> String {
        let shown = first == last ? "Page \(first) displays" : "Pages \(first) through \(last) display"
        return """
            \(shown) \(displayed) of \(matching) matching sections, of \(count) section pages numbered from 0; \(remaining) sections \
            remain after this. Paths and line numbers identify positions in this retained response only; unread source content was not \
            searched. Continue with next_call. raw=true reads the original response bytes instead, in \(raw) raw pages of their own.
            """
    }

    /// A search gives the lines that hold its phrase (or, when the phrase is nowhere, its words), each with its place; the whole section
    /// around one is a page of a reading without query. `query_read_as` and the detail say which the search did.
    private static func matchesDetail(first: Int, last: Int, raw: Int, displayed: Int, searched: Int, sections: Int,
                                      readAs: ToolResultSections.Search.Reading) -> String {
        let shown = first == last ? "Page \(first) displays" : "Pages \(first) through \(last) display"
        let rule = readAs == .phrase
            ? "The query was read as the phrase as written, case aside: a match is the first place in a line that holds the phrase"
            : """
                The phrase as written is nowhere in this result, so its words were read separately: a match is the first place in a line \
                that holds one of them, from a section that holds every word
                """
        return """
            \(shown) \(displayed) matches; the search has read \(searched) of \(sections) sections, only as far as these pages, so later \
            matches are found as reading goes on. \(rule); a line gives one match: path; line, numbered from 1 within the string at path; \
            offset, in Unicode scalars from the \
            start of the line or value to where text starts, when text is not the whole line; text, the line or a window of a long line \
            around the match; before and after, the adjacent lines. To read the whole section around a match, read tool_result_page with \
            page set to its section_page and no query. Paths, lines and offsets identify positions in this retained response only; unread \
            source content was not searched. Continue with next_call. raw=true reads the original response bytes instead, in \(raw) raw \
            pages of their own.
            """
    }

    private func loadEntry(handle: String, url: URL) throws -> Entry {
        let saved = try JSONValue.parse(Data(contentsOf: url)).objectValue
        guard let content = saved?["content"]?.stringValue, let tool = saved?["tool"]?.stringValue,
              let result = saved?["original_result_class"]?.stringValue,
              let resultClass = ChatToolOutcome.ExactResultClass(rawValue: result),
              case .array(let conversations)? = saved?["conversations"], conversations.allSatisfy({ $0.stringValue != nil }),
              case .int(let omitted)? = saved?["omitted_bytes"], let omittedBytes = Int(exactly: omitted), omittedBytes >= 0,
              case .int(let original)? = saved?["original_bytes"], let originalBytes = Int(exactly: original), originalBytes >= omittedBytes,
              case .int(let budget)? = saved?["section_budget"], let sectionBudget = Int(exactly: budget), sectionBudget > 0
        else { throw CocoaError(.fileReadCorruptFile) }
        return try makeEntry(handle: handle, content: content, parsed: try? JSONValue.parse(Data(content.utf8)),
            toolName: tool, originalResultClass: resultClass, sectionBudget: sectionBudget,
            conversations: Set(conversations.compactMap(\.stringValue)), omittedBytes: omittedBytes, originalBytes: originalBytes)
    }

    /// A reference alone proves nothing: open the saved body, even if a paging entry is already cached.
    package func wholeBodyAvailable(handle: String, dataRoot: URL, turn: Turn) -> Bool {
        guard validHandle(handle), let entry = try? loadEntry(handle: handle,
            url: dataRoot.standardizedFileURL.appendingPathComponent("tool_results/" + handle)) else { return false }
        return entry.omittedBytes == 0 && mayRead(entry, turn: turn)
    }

    private func validHandle(_ handle: String) -> Bool {
        handle.range(of: "^(receipt-[0-9a-f-]{36}\\.)?[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private func mayRead(_ entry: Entry, turn: Turn) -> Bool {
        turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) != true
            || ChatToolSessionInjection.currentSession(turn: turn).map { entry.conversations.contains($0) } == true
    }

    private func readPage(
        handle: String, page: Int, dataRoot: URL, turn: Turn, query: String?
    ) -> JSONValue {
        guard validHandle(handle) else {
            return unavailable(handle: handle, reason: "result_handle_unavailable")
        }
        let key = dataRoot.standardizedFileURL.appendingPathComponent("tool_results/" + handle)
        do {
            if entries[key] == nil {
                cache(try loadEntry(handle: handle, url: key), at: key)
            }
        } catch {
            let missing = (error as? CocoaError)?.code == .fileReadNoSuchFile
            return unavailable(handle: handle, reason: missing ? "result_handle_unavailable" : "result_spill_unreadable",
                cause: error.localizedDescription)
        }
        guard var entry = entries[key] else { return unavailable(handle: handle, reason: "result_handle_unavailable") }
        guard mayRead(entry, turn: turn) else {
            return .object(["status": .string("refused"), "effects": .string("none"), "reason": .string("result_not_in_conversation"),
                "detail": .string("A turn steered by an untrusted source reads only results produced in its own conversation. No body was disclosed.")])
        }
        if let query, !ToolResultSections.queryTerms(query).isEmpty {
            // A search reads on from where its last read stopped, only as far as this page.
            var search = entry.search?.query == query ? entry.search! : ToolResultSections.Search(query: query, budget: entry.sectionBudget)
            entry.search = nil
            search.fill(through: page, entry.sectionProjection)
            entry.search = search
            entries[key] = entry
            guard search.pages.indices.contains(page) else {
                return .object(["status": .string("failed"), "reason": .string("page_out_of_range"),
                    "page_count": .int(Int64(search.pages.count)),
                    "recovery_hint": .string("""
                        Read the same retained result with a page from 0 through \(search.pages.count - 1), keeping query and raw unchanged; do \
                        not rerun the original operation.
                        """)])
            }
            let raw = max(1, entry.pageByteOffsets.count - 1)
            let matches = search.pages[page].map { row -> JSONValue in
                guard case .object(var pointer) = row,
                      case .int(let start)? = pointer["raw_byte_start"],
                      case .int(let end)? = pointer["raw_byte_end"] else { return row }
                pointer["raw_first_page"] = .int(Int64(max(0, entry.pageByteOffsets.lastIndex(where: { $0 <= start }) ?? 0)))
                pointer["raw_last_page"] = .int(Int64(max(0, entry.pageByteOffsets.lastIndex(where: { $0 < end }) ?? 0)))
                return .object(pointer)
            }
            var answer: [String: JSONValue] = [
                "status": .string("completed"),
                "original_result_class": .string(entry.resultClass.rawValue),
                "recovery_only": .bool(true),
                "verification_scope": .string("retained_tool_response_not_external_outcome"),
                "result_handle": .string(handle), "query": .string(query),
                "query_read_as": .string(search.reading.rawValue),
                "page": .int(Int64(page)),
                "matches": .array(matches),
                "displayed_matches": .int(Int64(matches.count)),
                "searched_sections": .int(Int64(search.searched)),
                "section_count": .int(Int64(entry.sectionProjection.count)),
                "has_more": .bool(page + 1 < search.pages.count),
                "next_page": page + 1 < search.pages.count ? .int(Int64(page + 1)) : .null,
                "raw_page_count": .int(Int64(raw)),
                "detail": .string(Self.matchesDetail(first: page, last: page, raw: raw, displayed: matches.count,
                    searched: search.searched, sections: entry.sectionProjection.count, readAs: search.reading)),
            ]
            answer["source_continues"] = entry.source
            return .object(answer)
        }
        if let query {
            if entry.sectionPages?.query != query {
                let pages = ToolResultSections.pages(sections: entry.sectionProjection, budget: entry.sectionBudget)
                entry.sectionPages = (query, pages, pages.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1.count) })
                entries[key] = entry
            }
            let (_, pages, counts) = entry.sectionPages!
            guard pages.indices.contains(page) else {
                return .object(["status": .string("failed"), "reason": .string("page_out_of_range"),
                    "page_count": .int(Int64(pages.count)),
                    "recovery_hint": .string("""
                        Read the same retained result with a page from 0 through \(pages.count - 1), keeping query and raw unchanged; do not rerun \
                        the original operation.
                        """)])
            }
            let matching = counts[pages.count], remaining = matching - counts[page + 1]
            let sections = pages[page].map { section -> JSONValue in
                guard case .object(var row) = section,
                      case .int(let start)? = row["raw_byte_start"],
                      case .int(let end)? = row["raw_byte_end"] else { return section }
                row["raw_first_page"] = .int(Int64(max(0, entry.pageByteOffsets.lastIndex(where: { $0 <= start }) ?? 0)))
                row["raw_last_page"] = .int(Int64(max(0, entry.pageByteOffsets.lastIndex(where: { $0 < end }) ?? 0)))
                return .object(row)
            }
            var answer: [String: JSONValue] = [
                "status": .string("completed"),
                "original_result_class": .string(entry.resultClass.rawValue),
                "recovery_only": .bool(true),
                "verification_scope": .string("retained_tool_response_not_external_outcome"),
                "result_handle": .string(handle), "query": .string(query),
                "page": .int(Int64(page)), "page_count": .int(Int64(pages.count)),
                "sections": .array(sections),
                "searched_sections": .int(Int64(entry.sectionProjection.count)),
                "matching_sections": .int(Int64(matching)),
                "displayed_sections": .int(Int64(sections.count)),
                "remaining_sections": .int(Int64(remaining)),
                "has_more": .bool(page + 1 < pages.count),
                "next_page": page + 1 < pages.count ? .int(Int64(page + 1)) : .null,
                "raw_page_count": .int(Int64(max(1, entry.pageByteOffsets.count - 1))),
                "detail": .string(Self.sectionsDetail(first: page, last: page, count: pages.count,
                    raw: max(1, entry.pageByteOffsets.count - 1), displayed: sections.count, matching: matching, remaining: remaining)),
            ]
            answer["source_continues"] = entry.source
            return .object(answer)
        }
        let pageCount = max(1, entry.pageByteOffsets.count - 1)
        guard page >= 0, page < pageCount else {
            return .object([
                "status": .string("failed"),
                "reason": .string("page_out_of_range"),
                "page_count": .int(Int64(pageCount)),
                "recovery_hint": .string("Read the same retained result with a page from 0 through \(pageCount - 1); do not rerun the original operation."),
            ])
        }
        let startByte = entry.pageByteOffsets[page]
        let endByte = entry.pageByteOffsets[page + 1]
        let content: String
        guard let text = String(data: entry.content.subdata(in: startByte..<endByte), encoding: .utf8) else {
            return unavailable(handle: handle, reason: "result_spill_incomplete")
        }
        content = text
        let hasMore = page + 1 < pageCount
        let nextPage: JSONValue = hasMore ? .int(Int64(page + 1)) : .null
        var answer: [String: JSONValue] = [
            "status": .string("completed"),
            "original_result_class": .string(entry.resultClass.rawValue),
            "recovery_only": .bool(true),
            "verification_scope": .string("retained_tool_response_not_external_outcome"),
            "tool": .string(entry.toolName),
            "result_handle": .string(handle),
            "page": .int(Int64(page)),
            "page_count": .int(Int64(pageCount)),
            "page_bytes": .int(Int64(endByte - startByte)),
            "original_characters": .int(Int64(entry.characters)),
            "original_bytes": .int(Int64(entry.originalBytes)),
            "content": .string(content),
            "has_more": .bool(hasMore),
            "next_page": nextPage,
        ]
        answer["source_continues"] = entry.source
        return .object(answer)
    }

    /// The named fields of a whole retained result and nothing else of it: the read for a large result she needs two fields of. It reads
    /// what paging reads, the retained redacted body, under the same conversation rule, so nothing that judged or recorded the call changes.
    package func selected(handle: String, paths: [String], dataRoot: URL, turn: Turn) -> JSONValue {
        let first = readPage(handle: handle, page: 0, dataRoot: dataRoot, turn: turn, query: nil)
        let key = dataRoot.standardizedFileURL.appendingPathComponent("tool_results/" + handle)
        guard ToolResult(first).said("completed"), let entry = entries[key] else { return first }
        func failed(_ reason: String, _ hint: String) -> JSONValue {
            .object(["status": .string("failed"), "effects": .string("none"), "reason": .string(reason), "result_handle": .string(handle),
                     "recovery_hint": .string(hint)])
        }
        guard entry.omittedBytes == 0, let whole = try? JSONDecoder().decode(JSONValue.self, from: entry.content) else {
            return failed("select_needs_whole_json", "This retained result is not one whole JSON value; read it by page or with query.")
        }
        let answer = ToolResult.stepAnswer(whole)
        var kept: JSONValue = .null, missing: [JSONValue] = []
        for path in paths {
            let segments = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)[...]
            // A path is read as it stands in the retained result, and otherwise against what the action returned inside its receipt.
            if let part = Self.pick(whole, segments) ?? Self.pick(answer, segments) {
                kept = Self.merged(kept, part)
            } else {
                // A path that found nothing says what was at the place it stopped, so a wrong path and an absent field read differently.
                missing.append(.object(["path": .string(path), "there": .array(Self.keysWhereLost(whole, segments).map(JSONValue.string))]))
            }
        }
        var reply: [String: JSONValue] = ["status": .string("completed"), "recovery_only": .bool(true),
            "verification_scope": .string("retained_tool_response_not_external_outcome"), "tool": .string(entry.toolName),
            "original_result_class": .string(entry.resultClass.rawValue), "result_handle": .string(handle),
            "original_bytes": .int(Int64(entry.originalBytes)), "selected": kept]
        if !missing.isEmpty { reply["select_missing"] = .array(missing) }
        reply["source_continues"] = entry.source
        reply["selected_bytes"] = .int(Int64((try? kept.serialize(pretty: false).utf8.count) ?? 0))
        let size = (try? JSONValue.object(reply).serialize(pretty: false).utf8.count) ?? .max
        let room = turn[AnswerRoomPart.self]?.allowance.whole ?? ProviderToolResultPage.defaultMaxUTF8Bytes - 2_000
        guard size <= room else {
            return failed("selection_too_large", "The selected fields are \(size) bytes and \(max(0, room)) fit here. Name fewer or deeper paths, or read by page.")
        }
        return .object(reply)
    }

    /// One path into a value, kept in its structure: object keys, a numeric index into a list, and at a list reached by a name every element.
    static func pick(_ value: JSONValue, _ path: ArraySlice<String>) -> JSONValue? {
        guard let key = path.first else { return value }
        switch value {
        case .object(let fields):
            if let child = fields[key] { return pick(child, path.dropFirst()).map { .object([key: $0]) } }
            // A receipt holds its answer flat or under `result`: a path written either way finds it. Any other object is read as written.
            guard Self.isReceipt(fields) else { return nil }
            if key == "result" { return pick(value, path.dropFirst()) }
            return fields["result"].flatMap { $0.objectValue == nil ? nil : pick($0, path) }.map { .object(["result": $0]) }
        case .array(let items):
            // One element taken by number keeps its number, so two such paths never fold into one row.
            if let index = Int(key) { return items.indices.contains(index) ? pick(items[index], path.dropFirst()).map { .object([key: $0]) } : nil }
            let rows = items.map { pick($0, path) }
            return rows.contains { $0 != nil } ? .array(rows.map { $0 ?? .null }) : nil
        default: return nil
        }
    }

    /// A door receipt, whose answer sits flat on it or under `result`. Any other object is read exactly as written.
    static func isReceipt(_ fields: [String: JSONValue]) -> Bool {
        fields["action"] != nil && (fields["status"] != nil || fields["result"] != nil)
    }

    /// The field names at the place a path stopped finding anything.
    static func keysWhereLost(_ value: JSONValue, _ path: ArraySlice<String>) -> [String] {
        guard let key = path.first else { return [] }
        switch value {
        case .object(let fields):
            if let child = fields[key] { return keysWhereLost(child, path.dropFirst()) }
            if key == "result", Self.isReceipt(fields) { return keysWhereLost(value, path.dropFirst()) }
            if case .object(let inner)? = fields["result"], Self.isReceipt(fields) {
                // The answer is under result: what is there is its fields, not the receipt's own.
                return inner[key] != nil ? keysWhereLost(.object(inner), path) : Array(inner.keys.sorted().prefix(30))
            }
            return Array(fields.keys.sorted().prefix(30))
        case .array(let items):
            if let index = Int(key) { return items.indices.contains(index) ? keysWhereLost(items[index], path.dropFirst()) : ["list of \(items.count)"] }
            return items.first.map { keysWhereLost($0, path) } ?? ["empty list"]
        default: return []
        }
    }

    static func merged(_ one: JSONValue, _ other: JSONValue) -> JSONValue {
        switch (one, other) {
        case (.object(let a), .object(let b)): .object(a.merging(b) { merged($0, $1) })
        case (.array(let a), .array(let b)) where a.count == b.count: .array(zip(a, b).map { merged($0, $1) })
        // One element taken by number beside a field taken from every row: the element joins its own row.
        case (.array(let rows), .object(let byNumber)), (.object(let byNumber), .array(let rows)):
            .array(rows.enumerated().map { index, row in byNumber[String(index)].map { merged(row, $0) } ?? row })
        case (.null, _): other
        default: one
        }
    }

    private func cache(_ entry: Entry, at key: URL) {
        entries[key] = entry
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > Self.cachedEntries { entries.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    private func cleanupExpired(root: URL, now: Date) throws {
        let cutoff = now.addingTimeInterval(-ExperienceStore.detailHorizon)
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls {
            let modified = try url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            guard let modified else { throw CocoaError(.fileReadUnknown) }
            if modified < cutoff {
                try FileManager.default.removeItem(at: url)
                entries.removeValue(forKey: url)
                cacheOrder.removeAll { $0 == url }
                for turn in readCursors.keys.filter({ readCursors[$0]?.handle == url.lastPathComponent }) { readCursors.removeValue(forKey: turn) }
            }
        }
    }

}

extension SwiftToolDispatcher {
    func impl_tool_result_page(turn: Turn, input: ToolResultPageArgs) async -> JSONValue {
        // A section read or a continuation fills one answer; an explicit raw read takes one page unless more are asked for.
        let pages = input.pages.map { $0.wire.exactIntegerValue ?? 0 } ?? (input.raw == true ? 1 : ProviderToolResultRecoveryStore.usualSectionPages)
        guard pages >= 1 else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("invalid_pages"),
                "recovery_hint": .string("""
                    Set pages to a whole number from 1, or omit it for the usual read. Keep result_handle, query and raw unchanged; do not rerun the \
                    original operation.
                    """),
            ])
        }
        if let select = input.select {
            let paths = select.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let handle = input.resultHandle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty, (1...12).contains(paths.count) else {
                return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("invalid_select"),
                    "recovery_hint": .string("Give result_handle and select as 1 to 12 comma-separated paths, such as \"rows.id, rows.title, total\".")])
            }
            return await heldReceiptPointer(turnId: turn.id, await ProviderToolResultRecoveryStore.shared.selected(
                handle: handle, paths: paths, dataRoot: dataRoot, turn: turn))
        }
        if input.resume == true {
            // Continue owns the position, even when a page is also supplied. A query or raw named with it reads the continued result that
            // way: on from where that same read stopped, or from its start when it is a different read.
            // A query given, even an empty one (read everything), is named; only an absent or null query keeps the previous read's.
            let handle = input.resultHandle?.trimmingCharacters(in: .whitespacesAndNewlines)
            return await heldReceiptPointer(turnId: turn.id, await ProviderToolResultRecoveryStore.shared.continueReading(
                handle: handle?.isEmpty == false ? handle : nil,
                dataRoot: dataRoot, turn: turn, pages: pages,
                query: input.query, raw: input.raw == true))
        }
        guard let handle = input.resultHandle, !handle.isEmpty else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("missing_result_handle"),
                "recovery_hint": .string("Copy result_handle from a retained bounded_tool_result response."),
            ])
        }
        let page = input.page.map { $0.wire.exactIntegerValue ?? -1 } ?? 0
        guard page >= 0 else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("invalid_page"),
                "recovery_hint": .string("""
                    Set page to a whole number starting at 0, or copy next_page from the previous response. Keep result_handle, query and raw \
                    unchanged; do not rerun the original operation.
                    """),
            ])
        }
        return await heldReceiptPointer(turnId: turn.id, await ProviderToolResultRecoveryStore.shared.page(
            handle: handle,
            page: page,
            dataRoot: dataRoot,
            turn: turn,
            query: input.raw == true ? nil : (input.query ?? ""),
            pages: pages
        ))
    }

    /// An unavailable output points at its dispatch receipt only while the trace still holds it. Every receipt is dated by its own time in the
    /// trace, which keeps details `ExperienceStore.detailHorizon`. A receipt the whole readable trace no longer holds within that gets no pointer,
    /// and the answer says the detail aged out; a trace that cannot be read whole leaves the pointer as it was.
    func heldReceiptPointer(turnId: String, _ answer: JSONValue) async -> JSONValue {
        guard case .object(var fields) = answer, case .object(let remedy)? = fields["remedy"],
              let id = remedy["next_call"]?.objectValue?["input"]?.objectValue?["args"]?.objectValue?["receipt_id"]?.stringValue else { return answer }
        // This turn's receipts still on their way to the trace land first, so a fresh receipt is never read as aged out.
        try? await TurnTraceBus.shared.flush(turnId: turnId)
        guard let trace = try? await TurnTraceRecentReader(dataRootOverride: dataRoot).read(history: true,
                  since: Date().addingTimeInterval(-ExperienceStore.detailHorizon), kinds: ["tool.dispatch"]), trace.completeSequences,
              !trace.events.contains(where: { $0.payload.objectValue?["phase"] == .string("end")
                  && $0.payload.objectValue?["receipt"]?.objectValue?["id"] == .string(id) }) else { return answer }
        let days = Int(ExperienceStore.detailHorizon / 86_400)
        fields["detail"] = .string("""
            This retained output is unavailable, and its dispatch receipt is no longer in the trace: trace details are kept \(days) days, so \
            the detail aged out. Missing output does not establish failure; never repeat a write to recover output.
            """)
        fields["receipt_aged_out"] = .bool(true)
        fields["remedy"] = Repair.terminal(instruction: """
            This handle and its receipt can no longer be read back; retained result files are pruned with trace details. \
            Inspect the affected state itself before any further change; never repeat a write to recover output.
            """)
        return .object(fields)
    }
}
