import ChatSessionWork
import ChatToolParsing
import ChatTurnContracts
import CryptoKit
import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import TurnTrace
// Blueprint: | `ProviderToolResultRecovery.swift` | `SwiftToolDispatcher`, `impl_tool_result_page`: Retain results for the record's detail horizon. |

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
        includeSections: Bool = true
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
                let result = await ProviderToolResultRecoveryStore.shared.page(
                    handle: receipt.handle, page: 0, dataRoot: dataRoot, turn: turn, query: "",
                    pages: ProviderToolResultRecoveryStore.usualSectionPages)
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
        let digest = SHA256.hash(data: Data((toolName + "\u{0}" + content).utf8))
            .map { String(format: "%02x", $0) }.joined()
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

    package func page(
        handle: String,
        page: Int,
        dataRoot: URL,
        turn: Turn,
        query: String? = nil,
        pages: Int = 1
    ) -> JSONValue {
        let key = dataRoot.standardizedFileURL.appendingPathComponent("tool_results/" + handle)
        var result = readPage(handle: handle, page: page, dataRoot: dataRoot, turn: turn, query: query)
        // A read of several pages joins them in order while the whole answer stays within what one answer holds. Each mode's page size
        // differs, so the body is measured, never assumed: that measure alone sets how many pages one answer carries.
        if pages > 1, case .object(var answer) = result, ToolResult(result).said("completed") {
            let body = query.map { ToolResultSections.queryTerms($0).isEmpty ? "sections" : "matches" } ?? "content"
            func bytes(_ value: JSONValue?) -> Int { (try? (value ?? .null).serialize(pretty: false).utf8.count) ?? .max }
            // The body may fill what one answer holds less everything else the answer carries, with 1,000 bytes for what it gains below.
            let budget = ProviderToolResultPage.defaultMaxUTF8Bytes - 1_000 - max(0, bytes(result) - bytes(answer[body]))
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
            let next: Int?
            if case .int(let value)? = object["next_page"] { next = Int(exactly: value) }
            else { next = nil }
            readCursors[turn.id] = ReadCursor(handle: handle, nextPage: next, query: query)
            object["full_result_retained"] = .bool(entries[key]?.omittedBytes == 0)
            object["omitted_bytes"] = entries[key].map { .int(Int64($0.omittedBytes)) }
            object["version"] = entries[key]?.version
            var args: [String: JSONValue] = ["continue": .bool(true), "result_handle": .string(handle)]
            // Continuing already reads as much as fits; only an asked count travels with it.
            if pages > 1, pages < Self.usualSectionPages { args["pages"] = .int(Int64(pages)) }
            object["next_call"] = next == nil ? .null : .object(["tool": .string("app"), "input": .object([
                "action": .string("result.page"), "args": .object(args)])])
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
        turn.peerSteering?.isTainted != true
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
    package func impl_tool_result_page(turn: Turn, input: [String: JSONValue]) async -> JSONValue {
        func whole(_ given: JSONValue?, absent: Int) -> Int? {
            switch given ?? .null {
            case .null, .bool(false): return absent
            case .int(let value): return Int(exactly: value)
            case .double(let value): return Int(exactly: value)
            case .string(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? absent : Int(trimmed)
            default: return nil
            }
        }
        // A section read or a continuation fills one answer; an explicit raw read takes one page unless more are asked for.
        guard let pages = whole(input["pages"], absent: input["raw"] == .bool(true) ? 1 : ProviderToolResultRecoveryStore.usualSectionPages), pages >= 1 else {
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
        if input["continue"] == .bool(true) {
            // Continue owns the position, even when a page is also supplied. A query or raw named with it reads the continued result that
            // way: on from where that same read stopped, or from its start when it is a different read.
            // A query given, even an empty one (read everything), is named; only an absent or null query keeps the previous read's.
            let handle = input["result_handle"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return await heldReceiptPointer(turnId: turn.id, await ProviderToolResultRecoveryStore.shared.continueReading(
                handle: handle?.isEmpty == false ? handle : nil,
                dataRoot: dataRoot, turn: turn, pages: pages,
                query: input["query"]?.stringValue, raw: input["raw"] == .bool(true)))
        }
        guard case .string(let handle)? = input["result_handle"], !handle.isEmpty else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("missing_result_handle"),
                "recovery_hint": .string("Copy result_handle from a retained bounded_tool_result response."),
            ])
        }
        guard let page = whole(input["page"], absent: 0), page >= 0 else {
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
            query: input["raw"] == .bool(true) ? nil : (input["query"]?.stringValue ?? ""),
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
