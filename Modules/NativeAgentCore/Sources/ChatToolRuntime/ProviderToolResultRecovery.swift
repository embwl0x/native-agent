import ChatSessionWork
import ChatToolParsing
import ChatTurnContracts
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
// Blueprint: | `ProviderToolResultRecovery.swift` | `SwiftToolDispatcher`, `impl_tool_result_page`: Retain turn-bound results without loss. |

private enum ResultRecoveryScopePart: TurnPart { static let unset: ProviderToolResultRecoveryStore.Scope? = nil }

extension Turn {
    /// The result owner's held resource scope, shared by nested calls; a derived turn binds its own identity.
    package var resultRecoveryScope: ProviderToolResultRecoveryStore.Scope? {
        get { self[ResultRecoveryScopePart.self] }
        set { self[ResultRecoveryScopePart.self] = newValue }
    }
}

/// Bound a view only after its exact, already-redacted body is retained. Script steps and outer calls use this same owner.
package enum ProviderToolResultPage {
    package static let defaultMaxUTF8Bytes = 48_000

    /// Non-loop doors and helpers release only the scope they admitted, after their operation settles on every exit.
    package static func holding<Value: Sendable>(turn: Turn, sessionId: String?,
        operation: @Sendable (Turn) async throws -> Value) async throws -> Value {
        let scope = ProviderToolResultRecoveryStore.Scope(sessionId: sessionId, turnId: turn.id)
        if scope == turn.resultRecoveryScope { return try await operation(turn) }
        let outcome: Result<Value, Error>
        do { outcome = .success(try await operation(turn.with(\.resultRecoveryScope, scope))) }
        catch { outcome = .failure(error) }
        if let scope { await settle { await ProviderToolResultRecoveryStore.shared.remove(scope: scope) } }
        return try outcome.get()
    }

    package struct View: Sendable {
        package let content: String
        package let recovery: JSONValue?
        package let failed: Bool
    }

    package struct ContextResult: Sendable {
        package let dataRoot: URL
        package let callID: String
        package init(dataRoot: URL, callID: String) { self.dataRoot = dataRoot; self.callID = callID }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @concurrent package static func project(
        toolName: String,
        content: String,
        sessionId: String?,
        turnId: String,
        originalResultClass: ChatToolOutcome.ExactResultClass,
        appDoor: Bool,
        inlineLimit: Int = defaultMaxUTF8Bytes,
        includeSections: Bool = true,
        contextResult: ContextResult? = nil
    ) async -> View {
        guard content.utf8.count > inlineLimit else { return View(content: content, recovery: nil, failed: false) }
        var recovery: JSONValue?
        do {
            // A plain-text tool answer has no parsed envelope; it is still retained byte for byte.
            let parsed = try? JSONValue.parse(Data(content.utf8))
            let durableURL = contextResult.map {
                $0.dataRoot.appendingPathComponent("chat/tool_results/\(digest(turnId))", isDirectory: true)
                    .appendingPathComponent(digest($0.callID + "\u{0}" + content) + ".txt")
            }
            let receipt = try await ProviderToolResultRecoveryStore.shared.store(
                content: content, parsed: parsed, toolName: toolName, sessionId: sessionId, turnId: turnId,
                originalResultClass: originalResultClass, durableURL: durableURL)
            var reference: [String: JSONValue] = [
                "result_handle": .string(receipt.handle), "full_result_retained": .bool(true),
                "original_bytes": .int(Int64(receipt.bytes)),
                "next_call": .object(["tool": .string("app"), "input": .object([
                    "action": .string("result.page"), "args": .object([
                        "result_handle": .string(receipt.handle), "page": .int(0), "raw": .bool(true)])])]),
            ]
            if let durableURL { reference["saved_result_path"] = .string(durableURL.path) }
            recovery = .object(reference)
            var fields = reference
            if includeSections {
                let result = await ProviderToolResultRecoveryStore.shared.page(
                    handle: receipt.handle, page: 0, sessionId: sessionId, turnId: turnId, query: "")
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
            // Exact live home controls stay outside paged reading evidence.
            if includeSections, toolName == "app", case .object(var frame)? = parsed {
                fields["version"] = frame["version"]
                if case .object(let view)? = frame["view"] { frame.merge(view) { top, _ in top } }
                let keys: Set<String> = ["status", "workspace", "path", "actions", "windows", "places", "desktop"]
                var candidate = fields
                candidate["navigation"] = .object(frame.filter { keys.contains($0.key) })
                if try JSONValue.object(candidate).serialize(pretty: false).utf8.count <= inlineLimit { fields = candidate }
            }
            return View(content: try JSONValue.object(fields).serialize(pretty: false), recovery: recovery, failed: false)
        } catch {
            // Retention failure is its own failure, never an unretained prefix or a verdict about the original effects.
            let kept = recovery?.objectValue?["result_handle"]?.stringValue.map {
                " The whole body is retained as \($0); read app result.page with result_handle:\"\($0)\", raw:true, page:0 and follow next_page."
            } ?? " The body could not be retained."
            return View(content: """
                Tool result retention/projection failed: \(error.localizedDescription). Original result class: \(originalResultClass.rawValue). \
                No clipped result was delivered.\(kept) Inspect the original dispatch receipt and repair result storage before repeating an action.
                """, recovery: recovery, failed: true)
        }
    }
}

/// Lossless, turn-scoped result storage. Live views spill to private temp files; context-overflow bodies stay at their existing durable chat path.
/// Owner-only files have scope/content-bound handles readable only in the originating session and turn.
package actor ProviderToolResultRecoveryStore {
    package static let shared = ProviderToolResultRecoveryStore()

    package static let pageUTF8Bytes = 8_000

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
    package static let ttl: TimeInterval = 30 * 60

    package struct Scope: Hashable, Sendable {
        package let sessionId: String
        package let turnId: String

        package init?(sessionId: String?, turnId: String?) {
            let session = (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let turn = (turnId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !session.isEmpty, !turn.isEmpty, turn != "unknown" else { return nil }
            self.sessionId = session
            self.turnId = turn
        }
    }

    package struct Receipt: Sendable {
        package let handle: String
        package let pageCount: Int
        package let characters: Int
        package let bytes: Int
        package let resultClass: ChatToolOutcome.ExactResultClass
    }

    private struct Entry: Sendable {
        let handle: String
        let toolName: String
        let scope: Scope
        var url: URL
        var removeOnRelease: Bool
        let characters: Int
        let bytes: Int
        let resultClass: ChatToolOutcome.ExactResultClass
        let pageByteOffsets: [Int]
        let sectionBudget: Int
        let version: JSONValue?
        let createdAt: Date
        let sectionProjection: [(value: JSONValue, text: String, bytes: Int)]
        var sectionPages: (query: String, pages: [[JSONValue]], counts: [Int])?
    }

    // Live result spills are outside backup/export/phone sync. Durable context bodies retain the chat owner's existing retention policy.
    private let root: URL
    private var entries: [String: Entry] = [:]
    private struct ReadCursor {
        let handle: String
        let nextPage: Int?
        let query: String?
    }
    private var readCursors: [Scope: ReadCursor] = [:]

    package init(root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(InstallPaths.current.name("NativeAgent"), isDirectory: true)
        .appendingPathComponent("provider_tool_results", isDirectory: true)) {
        self.root = root
    }

    package func store(
        content: String,
        parsed: JSONValue?,
        toolName: String,
        sessionId: String?,
        turnId: String?,
        originalResultClass: ChatToolOutcome.ExactResultClass,
        sectionBudget: Int = ToolResultSections.pageBudget,
        durableURL: URL? = nil
    ) throws -> Receipt {
        guard let scope = Scope(sessionId: sessionId, turnId: turnId) else {
            throw ToolFailureError("A retained result needs its originating session and turn.", effects: .unknown,
                owner: toolName, code: "missing_result_scope", recovery: .reconcile)
        }
        cleanupExpired(now: Date())

        let data = Data(content.utf8)
        let fields = parsed?.objectValue ?? [:]
        let receipt = if case .string(let id)? = fields["dispatch_receipt_id"] { UUID(uuidString: id) } else { nil as UUID? }
        let source = if case .string(let source)? = fields["dispatch_receipt_source"] { source } else { "" }
        // The same receipt can have distinct redacted views. Never overwrite bytes already promised by another view's handle.
        let digest = SHA256.hash(data: Data((scope.sessionId + "\u{0}" + scope.turnId + "\u{0}" + toolName + "\u{0}").utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
        let handle = (source == "detail" ? receipt : nil)
            .map { "receipt-" + $0.uuidString.lowercased() + "." + digest } ?? digest
        if var entry = entries[handle] {
            if let durableURL, entry.url != durableURL {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: durableURL)
                let temporary = entry.removeOnRelease ? entry.url : nil
                entry.url = durableURL
                entry.removeOnRelease = false
                entries[handle] = entry
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
            }
            return Receipt(handle: handle, pageCount: entry.pageByteOffsets.count - 1,
                characters: entry.characters, bytes: entry.bytes, resultClass: entry.resultClass)
        }

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
        let url = durableURL ?? root.appendingPathComponent(handle, isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)

        let now = Date()
        let version = fields["version"]
        let entry = Entry(
            handle: handle,
            toolName: toolName,
            scope: scope,
            url: url,
            removeOnRelease: durableURL == nil,
            characters: content.count,
            bytes: data.count,
            resultClass: originalResultClass,
            pageByteOffsets: pageByteOffsets,
            sectionBudget: sectionBudget,
            version: version,
            createdAt: now,
            sectionProjection: sections
        )
        entries[handle] = entry
        return Receipt(
            handle: handle,
            pageCount: max(1, entry.pageByteOffsets.count - 1),
            characters: entry.characters,
            bytes: entry.bytes,
            resultClass: entry.resultClass
        )
    }

    package func page(
        handle: String,
        page: Int,
        sessionId: String?,
        turnId: String?,
        query: String? = nil
    ) -> JSONValue {
        var result = readPage(handle: handle, page: page, sessionId: sessionId, turnId: turnId, query: query)
        let reply = ToolResult(result)
        if let scope = Scope(sessionId: sessionId, turnId: turnId),
           case .object(var object) = result, reply.said("completed"), reply.status == object["status"]?.stringValue {
            let next: Int?
            if case .int(let value)? = object["next_page"] { next = Int(exactly: value) }
            else { next = nil }
            readCursors[scope] = ReadCursor(handle: handle, nextPage: next, query: query)
            object["full_result_retained"] = .bool(true)
            object["version"] = entries[handle]?.version
            object["next_call"] = next == nil ? .null : .object(["tool": .string("app"), "input": .object([
                "action": .string("result.page"), "args": .object(["continue": .bool(true), "result_handle": .string(handle)])])])
            result = .object(object)
        }
        return result
    }

    /// Continue the exact last read in this turn, preserving its query/mode. Before the first read only an unambiguous retained result is selected.
    package func continueReading(handle: String?, sessionId: String?, turnId: String?) -> JSONValue {
        cleanupExpired(now: Date())
        guard let scope = Scope(sessionId: sessionId, turnId: turnId) else {
            return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("missing_result_scope"),
                "detail": .string("Continuing a result works inside the chat turn that read it; this call has no such turn.")])
        }
        if let cursor = readCursors[scope], handle == nil || handle == cursor.handle {
            guard let next = cursor.nextPage else {
                return .object(["status": .string("completed"), "result_handle": .string(cursor.handle),
                    "has_more": .bool(false), "reading_complete": .bool(true),
                    "full_result_retained": .bool(true), "next_call": .null,
                    "recovery_only": .bool(true),
                    "verification_scope": .string("retained_tool_response_not_external_outcome"),
                    "original_result_class": .string(entries[cursor.handle]?.resultClass.rawValue ?? "unknown"),
                    "detail": .string("You reached the end of this retained result. No operation was repeated.")])
            }
            return page(handle: cursor.handle, page: next, sessionId: sessionId, turnId: turnId, query: cursor.query)
        }
        let candidates = entries.values.filter { $0.scope == scope && (handle == nil || $0.handle == handle) }
            .sorted { $0.createdAt < $1.createdAt }
        guard candidates.count == 1, let entry = candidates.first else {
            if candidates.isEmpty, let handle { return unavailable(handle: handle, reason: "result_handle_unavailable", sessionId: sessionId) }
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string(candidates.isEmpty ? "result_handle_unavailable" : "choose_result"),
                "results": .array(candidates.map { .object(["result_handle": .string($0.handle), "tool": .string($0.toolName)]) }),
                "recovery_hint": .string(candidates.isEmpty
                    ? """
                        No matching retained result is readable in this turn. Inline results are not retained; handles expire at turn end. Follow \
                        the original read's next arguments if it has more; never repeat a write to recover output.
                        """
                    : "Several results are retained. Choose result_handle once; subsequent continue reads keep its position."),
            ])
        }
        return page(handle: entry.handle, page: 0, sessionId: sessionId, turnId: turnId, query: "")
    }

    private func unavailable(handle: String, reason: String, sessionId: String?) -> JSONValue {
        let receipt = handle.hasPrefix("receipt-") ? UUID(uuidString: String(handle.dropFirst(8).prefix(36))) : nil
        var args: [String: JSONValue] = ["view": .string("receipts")]
        if let receipt { args["receipt_id"] = .string(receipt.uuidString.lowercased()) }
        if let sessionId { args["session_id"] = .string(sessionId) }
        let recovery = receipt == nil
            ? "This handle has no bound receipt; next_call lists this conversation's receipts."
            : "next_call reads the original dispatch receipt."
        return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string(reason),
            "detail": .string("""
                Retained output \(handle) is unavailable. \
                \(recovery) \
                Missing output does not establish failure; never repeat a write to recover output.
                """),
            "remedy": .object(["kind": .string("inspect"),
                "instruction": .string("Read the retained receipt with next_call; missing output never authorizes repeating a write."),
                "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("trace.recent"), "args": .object(args)])])])])
    }

    private func readPage(
        handle: String, page: Int, sessionId: String?, turnId: String?, query: String?
    ) -> JSONValue {
        cleanupExpired(now: Date())
        guard let scope = Scope(sessionId: sessionId, turnId: turnId),
              var entry = entries[handle],
              entry.scope == scope else {
            return unavailable(handle: handle, reason: "result_handle_unavailable", sessionId: sessionId)
        }
        if let query {
            if entry.sectionPages?.query != query {
                let pages = ToolResultSections.pages(sections: entry.sectionProjection, query: query, budget: entry.sectionBudget)
                entry.sectionPages = (query, pages, pages.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1.count) })
                entries[handle] = entry
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
            return .object([
                "status": .string("completed"),
                "original_result_class": .string(entry.resultClass.rawValue),
                "recovery_only": .bool(true),
                "verification_scope": .string("retained_tool_response_not_external_outcome"),
                "result_handle": .string(handle), "query": .string(query),
                "page": .int(Int64(page)), "page_count": .int(Int64(pages.count)),
                "sections": .array(sections),
                "searched_sections": .int(Int64(entries[handle]?.sectionProjection.count ?? 0)),
                "matching_sections": .int(Int64(matching)),
                "displayed_sections": .int(Int64(sections.count)),
                "remaining_sections": .int(Int64(remaining)),
                "has_more": .bool(page + 1 < pages.count),
                "next_page": page + 1 < pages.count ? .int(Int64(page + 1)) : .null,
                "raw_page_count": .int(Int64(max(1, entry.pageByteOffsets.count - 1))),
                "detail": .string("""
                    Page \(page + 1) of \(pages.count) displays \(sections.count) of \(matching) matching sections; \(remaining) remain after this \
                    page. Paths and line numbers identify positions in this retained response only; unread source content was not searched. \
                    Continue with next_call. raw=true reads the original response bytes.
                    """),
            ])
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
        do {
            let file = try FileHandle(forReadingFrom: entry.url)
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(startByte))
            let data: Data?
            if endByte == startByte { data = Data() }
            else { data = try file.read(upToCount: endByte - startByte) }
            guard let data, data.count == endByte - startByte, let text = String(data: data, encoding: .utf8) else {
                return unavailable(handle: handle, reason: "result_spill_incomplete", sessionId: sessionId)
            }
            content = text
        } catch {
            return unavailable(handle: handle, reason: "result_spill_unreadable", sessionId: sessionId)
        }
        let hasMore = page + 1 < pageCount
        let nextPage: JSONValue = hasMore ? .int(Int64(page + 1)) : .null
        return .object([
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
            "original_bytes": .int(Int64(entry.bytes)),
            "content": .string(content),
            "has_more": .bool(hasMore),
            "next_page": nextPage,
        ])
    }

    package func remove(scope: Scope) {
        for handle in entries.values.filter({ $0.scope == scope }).map(\.handle) {
            remove(handle: handle)
        }
    }

    private func cleanupExpired(now: Date) {
        // A live turn owns its handles until settlement; age and later results never evict promised output.
        let liveNames = Set(entries.values.map { $0.url.lastPathComponent })
        let cutoff = now.addingTimeInterval(-Self.ttl)
        let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls ?? [] where !liveNames.contains(url.lastPathComponent) {
            let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if modified.map({ $0 < cutoff }) ?? true {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func remove(handle: String) {
        for scope in readCursors.keys.filter({ readCursors[$0]?.handle == handle }) { readCursors.removeValue(forKey: scope) }
        guard let entry = entries.removeValue(forKey: handle) else { return }
        if entry.removeOnRelease { try? FileManager.default.removeItem(at: entry.url) }
    }
}

extension SwiftToolDispatcher {
    package func impl_tool_result_page(turn: Turn, input: [String: JSONValue]) async -> JSONValue {
        if input["continue"] == .bool(true) {
            // Continue owns the position, even when a page is also supplied.
            let blank: (JSONValue?) -> Bool = {
                if case .string(let text)? = $0 { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                return [nil, .null, .int(0), .bool(false)].contains($0)
            }
            guard ["query", "raw"].allSatisfy({ blank(input[$0]) }) else {
                return .object(["status": .string("failed"), "reason": .string("conflicting_read_selection"),
                    "recovery_hint": .string("""
                        Use continue:true with optional result_handle and page, or omit continue to select an explicit page/query/raw mode. \
                        Continue ignores page and retains the previous mode and position.
                        """)])
            }
            let handle = input["result_handle"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return await ProviderToolResultRecoveryStore.shared.continueReading(
                handle: handle?.isEmpty == false ? handle : nil,
                sessionId: ChatToolSessionInjection.explicitSessionId(in: input), turnId: turn.id)
        }
        guard case .string(let handle)? = input["result_handle"], !handle.isEmpty else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("missing_result_handle"),
                "recovery_hint": .string("Copy result_handle from the earlier bounded_tool_result response in this turn."),
            ])
        }
        let page: Int?
        switch input["page"] ?? .null {
        case .null, .bool(false): page = 0
        case .int(let value): page = Int(exactly: value)
        case .double(let value): page = Int(exactly: value)
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            page = trimmed.isEmpty ? 0 : Int(trimmed)
        default: page = nil
        }
        guard let page, page >= 0 else {
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
        return await ProviderToolResultRecoveryStore.shared.page(
            handle: handle,
            page: page,
            sessionId: ChatToolSessionInjection.explicitSessionId(in: input),
            turnId: turn.id,
            query: input["raw"] == .bool(true) ? nil : (input["query"]?.stringValue ?? "")
        )
    }
}
