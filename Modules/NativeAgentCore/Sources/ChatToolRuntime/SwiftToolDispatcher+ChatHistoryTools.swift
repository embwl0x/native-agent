import AgentWorkspace
import ToolRegistry
import Foundation
import Transcripts
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution


private struct ChatHistorySessionMetadata: Sendable {
    var title: String?
    var createdAt: String?
}

private struct ChatHistorySearchHit: Sendable {
    var score: Double
    var runId: String?
    var workContextRank = 1
    var sessionId: String
    var sessionTitle: String?
    var sessionCreatedAt: String?
    var role: String
    var author: String?
    var authorRoute: String?
    var timestamp: String
    var timestampInstant: Date?
    var messageId: String?
    var messageIndex: Int
    var row: ChatHistorySearchRow
    var neighbors: [ChatHistorySearchRow]
    var peer: String?
}

private struct ChatHistorySearchRow: Sendable {
    var valid: Bool
    var object: [String: JSONValue]
    var identity: String
    var content: String
    var searchable: String
    var folded: String
    var instant: Date?
    var author: String?
    var route: String?
    var peer: String?
    var tool: String?
    var displayPrefix: String
}

/// Rebuildable search fields only; canonical files and their coverage remain authoritative.
private final class ChatHistorySearchCache: @unchecked Sendable {
    static let shared = ChatHistorySearchCache()
    private let lock = NSLock()
    private var entries: [String: (size: Int, modified: Date, inode: UInt64, receipts: Bool, rows: [ChatHistorySearchRow], cost: Int, use: UInt64)] = [:]
    private var cost = 0
    private var use: UInt64 = 0
    private let maximumCost = 256 * 1024 * 1024

    func rows(at file: URL, receipts: Bool, project: (String) -> ChatHistorySearchRow) throws -> [ChatHistorySearchRow] {
        lock.lock()
        defer { lock.unlock() }
        let path = file.path
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: path) }
        catch {
            cost -= entries.removeValue(forKey: path)?.cost ?? 0
            throw error
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        guard FileManager.default.isReadableFile(atPath: path) else {
            cost -= entries.removeValue(forKey: path)?.cost ?? 0
            throw CocoaError(.fileReadNoPermission)
        }
        use += 1
        if var entry = entries[path], entry.size == size, entry.modified == modified, entry.inode == inode,
           entry.receipts || !receipts {
            entry.use = use
            entries[path] = entry
            return entry.rows
        }
        cost -= entries.removeValue(forKey: path)?.cost ?? 0
        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true).map { project(String($0)) }
        // Include string storage and per-row/dictionary overhead, not the large discarded receipt metadata.
        let bytes = rows.reduce(0) { $0 + 1024 + 2 * ($1.identity.utf8.count + $1.content.utf8.count
            + $1.searchable.utf8.count + $1.folded.utf8.count) }
        let settled = try FileManager.default.attributesOfItem(atPath: path)
        if bytes <= maximumCost, [.size, .modificationDate, .systemFileNumber].allSatisfy({
            (attributes[$0] as? NSObject) == (settled[$0] as? NSObject)
        }) {
            while cost + bytes > maximumCost, let oldest = entries.min(by: { $0.value.use < $1.value.use })?.key {
                cost -= entries.removeValue(forKey: oldest)!.cost
            }
            entries[path] = (size, modified, inode, receipts, rows, bytes, use)
            cost += bytes
        }
        return rows
    }
}

// MARK: - Chat history search tools

extension SwiftToolDispatcher {
    static let chatHistoryCurrentSessionFloor = 0.3

    func impl_search_chat_history(
        input: [String: JSONValue], invokedAs: String,
        workContextQuery: WorkContextQuery? = nil,
        excludingRunID: String? = nil
    ) async throws -> JSONValue {
        let input = input.filter { $0.value != .string("") }
        let requestedScope = (jsonString(input["scope"]) ?? "all_sessions")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scope: String = try {
            switch requestedScope {
            case "", "auto", "current_session_first", "current_session", "all_sessions":
                return requestedScope.isEmpty ? "all_sessions" : requestedScope
            case "current":
                return "current_session"
            case "previous_session", "last_session":
                // The other half of the /new carry-over anchor. See the
                // resolution branch below.
                return "previous_session"
            case "all", "global", "all_session":
                // Honor the obvious spellings of "search everything" — an
                // explicit all-scope silently degrading to auto cost Agent
                // three blocked global searches during the memory backfill
                // (caught by her, 2026-06-11).
                return "all_sessions"
            default:
                throw AutonomyGateError.toolDenied(reason: "Chat history scope must be all_sessions, current_session, previous_session, auto, or current_session_first.")
            }
        }()
        // `previous_session` pins exactly ONE session by resolution, so it is
        // the one scope that is complete WITHOUT a query: "pull my last
        // session back" is a whole-session request, and the anchor's pointer
        // would otherwise name a call she cannot actually make. Empty query
        // means "no relevance filter" — every row is admitted at score 0 and
        // the sort falls through to recency, i.e. the tail of that session.
        let wholeSession = scope == "previous_session"
        // Likewise a session or time window with no query lists that window.
        let window = wholeSession || ["session_id", "after", "before"].contains {
            !(jsonString(input[$0]) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        let rawQuery = window
            ? (jsonString(input["query"]) ?? "")
            : try requireString(input, "query")
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || window else {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: empty chat-history search query")
        }
        let requestedLimit = optionalInt(input, "limit") ?? 8
        // A 25-snippet response regularly exceeded 18 KB in live turns and
        // encouraged a second broad search before the model had digested the
        // first one. Keep a compact page while preserving complete recall via
        // offset pagination.
        let offset = max(0, optionalInt(input, "offset") ?? 0)
        let mode = (jsonString(input["mode"]) ?? "hybrid")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let exactMode = mode == "exact"
        let continuityMode = mode == "continuity"
        let requestedRole = jsonString(input["role"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let roleFilter = requestedRole == Self.ownerAuthor ? "user" : requestedRole
        let authorFilter = requestedRole == Self.ownerAuthor ? Self.ownerAuthor : jsonString(input["author"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sessionFilter = jsonString(input["session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSessionId = jsonString(input["current_session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let sessionMeta = readChatHistorySessionMetadata()
        let tokens = chatSearchTokens(query)
        let normalizedQuery = query.lowercased()
        // Native messages carry fractional seconds while compaction rows and
        // legacy transcripts can use whole seconds or another ISO time zone.
        // Parse only admitted hits, once each, rather than in the comparator.
        let fractionalTimestamp = ISO8601DateFormatter()
        fractionalTimestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeTimestamp = ISO8601DateFormatter()

        func bound(_ key: String) throws -> Date? {
            guard let value = input[key], value != .null else { return nil }
            guard let rawText = jsonString(value) else {
                throw AutonomyGateError.toolDenied(reason: "Chat history '\(key)' must be an ISO8601 timestamp with a timezone.")
            }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // A bare day ("2026-09-22") means its local midnight.
            let day = ISO8601DateFormatter()
            day.formatOptions = [.withFullDate]
            day.timeZone = .current
            guard let date = fractionalTimestamp.date(from: text) ?? wholeTimestamp.date(from: text) ?? day.date(from: text) else {
                throw AutonomyGateError.toolDenied(reason: "Chat history '\(key)' must be an ISO8601 timestamp with a timezone.")
            }
            return date
        }
        let before = try bound("before")
        let after = try bound("after")
        if let before, let after, after >= before {
            throw AutonomyGateError.toolDenied(reason: "Chat history 'after' must precede 'before'.")
        }
        let dayDigest = query.isEmpty && (before != nil || after != nil)
        let limit = max(1, min(requestedLimit, dayDigest ? 8 : (continuityMode ? 4 : 12)))
        let requestedSort = jsonString(input["sort"]) ?? "relevance"
        guard ["relevance", "oldest", "newest", "recent", "latest"].contains(requestedSort) else {
            throw AutonomyGateError.toolDenied(reason: "Chat history sort must be relevance, oldest, or newest.")
        }
        let sort = dayDigest || ["recent", "latest"].contains(requestedSort) ? "newest" : requestedSort
        // Count unique failures across the current-session probe and fallback.
        // A partial scan must never masquerade as proof that evidence is absent.
        var unreadableSessions: Set<String> = []
        var malformedRows: Set<String> = []
        var undatedMatches: Set<String> = []
        var listingFailed = false
        var archived: [String: [URL]] = [:]
        do { archived = try ChatSessionRetention.archivedTranscripts(dataRoot: dataRoot) }
        catch { listingFailed = true }
        func allFiles() -> [(String, URL)] {
            do {
                return try ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, archived: archived)
            } catch {
                listingFailed = true
                return []
            }
        }

        func scan(_ messageFiles: [(String, URL)]) -> (hits: [ChatHistorySearchHit], sessions: Set<String>) {
            var hits: [ChatHistorySearchHit] = []
            var searchedSessions: Set<String> = []
            var seen: Set<String> = []
            for (sessionId, file) in messageFiles {
                var fileRows: Set<String> = []
                searchedSessions.insert(sessionId)
                guard let rows = try? ChatHistorySearchCache.shared.rows(at: file, receipts: roleFilter == "tool", project: { line in
                    Self.chatHistorySearchRow(line, receipts: roleFilter == "tool", fractional: fractionalTimestamp, whole: wholeTimestamp)
                }) else {
                    unreadableSessions.insert(sessionId)
                    continue
                }
                let meta = sessionMeta[sessionId]
                let searchableTitle = meta?.title.map(ChatTranscriptBoilerplate.stripBridgePrefix)?.lowercased()
                let firstHit = hits.count
                var runTools: [String: Set<String>] = [:]
                for (messageIndex, row) in rows.enumerated() {
                    if !row.valid, row.identity.isEmpty { continue }
                    let obj = row.object
                    guard row.valid else {
                        malformedRows.insert("\(sessionId):\(messageIndex)")
                        continue
                    }
                    let role = (jsonString(obj["role"]) ?? "unknown").lowercased()
                    let key = sessionId + ":" + row.identity
                    guard !seen.contains(key) else { continue }
                    fileRows.insert(key)
                    if let excludingRunID, jsonString(obj["runId"]) == excludingRunID { continue }
                    if workContextQuery != nil, role == "tool",
                       let runID = jsonString(obj["runId"]), !runID.isEmpty {
                        if let tool = row.tool { runTools[runID, default: []].insert(tool) }
                    }
                    if let roleFilter, !roleFilter.isEmpty, role != roleFilter {
                        continue
                    }
                    let author = row.author
                    if let authorFilter, !authorFilter.isEmpty, author?.lowercased() != authorFilter { continue }
                    // Receipt metadata is an explicit evidence lane, never
                    // extra material injected into ordinary conversation recall.
                    if role == "tool", roleFilter != "tool" { continue }
                    let content = row.content
                    guard !content.isEmpty else { continue }
                    let searchable = row.searchable
                    // Optional composition-level relevance policy. Work recall
                    // must not match unrelated rows merely because their broad
                    // session title happens to name the same project.
                    let workScore = workContextQuery.map { $0.score(searchable) }
                    if let workScore, workScore == 0 { continue }
                    let score = workScore.map(Double.init) ?? chatHistoryScore(
                        content: row.folded,
                        sessionTitle: searchableTitle,
                        query: normalizedQuery,
                        tokens: tokens,
                        exactMode: exactMode
                    )
                    guard score > 0 || query.isEmpty else { continue }
                    let timestamp = jsonString(obj["createdAt"]) ?? jsonString(obj["timestamp"]) ?? ""
                    let instant = row.instant
                    if before != nil || after != nil {
                        guard let instant else {
                            undatedMatches.insert("\(sessionId):\(messageIndex)")
                            continue
                        }
                        if let before, instant >= before { continue }
                        if let after, instant <= after { continue }
                    }
                    hits.append(ChatHistorySearchHit(
                        score: score,
                        runId: jsonString(obj["runId"]),
                        sessionId: sessionId,
                        sessionTitle: meta?.title,
                        sessionCreatedAt: meta?.createdAt,
                        role: role,
                        author: author,
                        authorRoute: row.route,
                        timestamp: timestamp,
                        timestampInstant: instant,
                        messageId: jsonString(obj["id"]),
                        messageIndex: messageIndex,
                        row: row,
                        neighbors: continuityMode && !dayDigest
                            ? Array(rows[max(0, messageIndex - 2)...min(rows.count - 1, messageIndex + 2)]) : [],
                        peer: row.peer
                    ))
                }
                seen.formUnion(fileRows)
                if workContextQuery != nil {
                    for index in firstHit..<hits.count {
                        let tools = hits[index].runId.flatMap { runTools[$0] } ?? []
                        hits[index].workContextRank = Self.workContextActivityRank(tools)
                    }
                }
            }
            return (hits, searchedSessions)
        }

        func files(forSessionId sessionId: String) throws -> [(String, URL)] {
            try ChatSessionRetention.transcriptFiles(
                dataRoot: dataRoot, sessionId: validatedChatSessionId(sessionId), archived: archived)
        }

        let selected: (hits: [ChatHistorySearchHit], sessions: Set<String>)
        let phase: String
        let fallbackSkipped: String?
        var resolvedPreviousSessionId: String? = nil
        if let sessionFilter, !sessionFilter.isEmpty {
            // An explicit id stays the most specific instruction there is.
            selected = scan(try files(forSessionId: sessionFilter))
            phase = "explicit_session"
            fallbackSkipped = nil
        } else if wholeSession {
            // Resolved through the SAME surface-scoped, bridge-excluding
            // resolver the /new anchor used, so the session this opens is
            // always the session the anchor named — which is why the anchor
            // never has to carry a UUID.
            if let currentSessionId, !currentSessionId.isEmpty,
               let prior = try PriorChatSession.latest(
                   excluding: currentSessionId, dataRoot: dataRoot
               ),
               try PriorChatSession.sameParticipant(
                   sessionId: currentSessionId, otherSessionId: prior.id, dataRoot: dataRoot
               ) {
                selected = scan(try files(forSessionId: prior.id))
                resolvedPreviousSessionId = prior.id
                phase = "previous_session"
            } else {
                selected = ([], [])
                phase = "previous_session_unavailable"
            }
            fallbackSkipped = "all_sessions"
        } else if scope == "current_session" {
            if let currentSessionId, !currentSessionId.isEmpty {
                selected = scan(try files(forSessionId: currentSessionId))
                phase = "current_session"
            } else {
                selected = ([], [])
                phase = "current_session_unavailable"
            }
            fallbackSkipped = "all_sessions"
        } else if scope == "auto" || scope == "current_session_first" {
            if let currentSessionId, !currentSessionId.isEmpty {
                let current = scan(try files(forSessionId: currentSessionId))
                // The short-circuit must mean "the answer is plausibly HERE",
                // not "some token overlapped". A 0.11-score single-token hit
                // blocked the all-sessions pass three times during Agent's
                // backfill. Floor chosen against chatHistoryScore's scale:
                // single-token incidental overlap lands well under 0.3;
                // genuine phrase/multi-token matches land above it.
                let bestCurrentScore = current.hits.map(\.score).max() ?? 0
                if !current.hits.isEmpty && bestCurrentScore >= Self.chatHistoryCurrentSessionFloor {
                    selected = current
                    phase = "current_session"
                    fallbackSkipped = "all_sessions"
                } else {
                    selected = scan(allFiles())
                    phase = "all_sessions_fallback"
                    fallbackSkipped = nil
                }
            } else {
                selected = scan(allFiles())
                phase = "all_sessions_no_current"
                fallbackSkipped = nil
            }
        } else {
            selected = scan(allFiles())
            phase = "all_sessions"
            fallbackSkipped = nil
        }

        var hits = selected.hits
        let searchedSessions = selected.sessions
        func hitsOrder(_ lhs: ChatHistorySearchHit, _ rhs: ChatHistorySearchHit) -> Bool {
            if sort == "relevance", lhs.score != rhs.score { return lhs.score > rhs.score }
            switch (lhs.timestampInstant, rhs.timestampInstant) {
            case let (left?, right?) where left != right: return sort == "oldest" ? left < right : left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            // Equal instants (or absent dates) still need repeatable paging.
            // Within a transcript, canonical row order is the final recency
            // evidence; different sessions get a stable identity tie-break.
            if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
            return sort == "oldest" ? lhs.messageIndex < rhs.messageIndex : lhs.messageIndex > rhs.messageIndex
        }
        hits.sort(by: hitsOrder)
        let digestSessions = dayDigest ? Dictionary(grouping: hits, by: \.sessionId) : [:]
        let page: [ChatHistorySearchHit]
        let selectableCount: Int
        if dayDigest {
            var seen: Set<String> = []
            let sessions = hits.filter { seen.insert($0.sessionId).inserted }
            selectableCount = sessions.count
            page = Array(sessions.dropFirst(min(offset, sessions.count)).prefix(limit))
        } else if workContextQuery != nil {
            // Keep the newest match alongside source-oriented turns so a
            // later correction is not buried by older recorded activity.
            // One representative per persisted run prevents its request and
            // answer consuming the entire small page. Legacy rows retain
            // their own identity; do not guess their run membership.
            let newest = hits.first
            var ranked = hits.sorted {
                if $0.workContextRank != $1.workContextRank { return $0.workContextRank < $1.workContextRank }
                return hitsOrder($0, $1)
            }
            var chosen: [ChatHistorySearchHit] = []
            var represented: Set<String> = []
            func append(_ hit: ChatHistorySearchHit) {
                let identity = hit.sessionId + ":" + (hit.runId.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "row:\(hit.messageIndex)")
                if represented.insert(identity).inserted { chosen.append(hit) }
            }
            if !ranked.isEmpty { append(ranked.removeFirst()) }
            if limit > 1, let newest { append(newest) }
            for hit in ranked { append(hit) }
            selectableCount = chosen.count
            page = Array(chosen.dropFirst(min(offset, chosen.count)).prefix(limit))
        } else {
            selectableCount = hits.count
            page = Array(hits.dropFirst(min(offset, hits.count)).prefix(limit))
        }
        let out = page.map { hit -> JSONValue in
            func preview(_ hit: ChatHistorySearchHit) -> String {
                String((hit.row.displayPrefix + chatHistoryPreview(
                    content: hit.row.searchable.isEmpty ? hit.row.content : hit.row.searchable,
                    query: query, tokens: tokens)).prefix(368))
            }
            if dayDigest {
                let messages = digestSessions[hit.sessionId] ?? []
                let ownMessages = messages.filter { $0.role == "user" && $0.author == Self.ownerAuthor }
                let own = ownMessages.prefix(6).map { message -> JSONValue in
                    var row: [String: JSONValue] = [
                        "timestamp": .string(message.timestamp),
                        "preview": .string(String(preview(message).prefix(160))),
                    ]
                    if let id = message.messageId { row["message_id"] = .string(id) }
                    if let peer = message.peer {
                        row["agent"] = .string(peer)
                        row["untrusted_remote_data"] = .bool(!PeerDataTaint.ownerTrusts(peer))
                    }
                    return JSONValue.object(row)
                }
                let digest: JSONValue = .object([
                    "session_id": .string(hit.sessionId),
                    "session_title": hit.sessionTitle.map(JSONValue.string) ?? .null,
                    "message_count": .int(Int64(messages.count)),
                    "first_time": messages.last.map { .string($0.timestamp) } ?? .null,
                    "last_time": .string(hit.timestamp),
                    "own_message_count": .int(Int64(ownMessages.count)),
                    "own_messages": .array(own),
                ])
                Self.consumePersistedHistoryEvidence(digest)
                return digest
            }
            var obj: [String: JSONValue] = [
                "session_id": .string(hit.sessionId),
                "role": .string(hit.role),
                "timestamp": .string(hit.timestamp),
                "message_index": .int(Int64(hit.messageIndex)),
                "preview": .string(preview(hit)),
                "score": .double(hit.score),
            ]
            if let currentSessionId, !currentSessionId.isEmpty {
                obj["is_current_session"] = .bool(hit.sessionId == currentSessionId)
            }
            if hit.role == "tool" { obj["evidence_type"] = .string("persisted_tool_receipt") }
            if let author = hit.author {
                obj["author"] = .string(author)
                obj["author_route"] = .string(hit.authorRoute ?? "unknown")
            }
            if let peer = hit.peer {
                obj["agent"] = .string(peer)
                obj["untrusted_remote_data"] = .bool(!PeerDataTaint.ownerTrusts(peer) && !preview(hit).isEmpty)
            }
            if workContextQuery != nil {
                obj["ranking_basis"] = .string([
                    "same_turn_tool_activity_without_history_lookup",
                    "no_classifiable_turn_activity",
                    "turn_includes_history_lookup"
                ][hit.workContextRank])
            }
            if let title = hit.sessionTitle, !title.isEmpty { obj["session_title"] = .string(title) }
            if let created = hit.sessionCreatedAt, !created.isEmpty { obj["session_created_at"] = .string(created) }
            obj["source_path"] = .string("chat/messages/\(hit.sessionId).jsonl")
            if let messageId = hit.messageId, !messageId.isEmpty {
                obj["message_id"] = .string(messageId)
                obj["read_locator"] = .object([
                    "tool": .string("read_chat_message"),
                    "arguments": .object(["session_id": .string(hit.sessionId), "message_id": .string(messageId)]),
                ])
            }
            if continuityMode { obj["surrounding_messages"] = .array(Self.continuityNeighbors(
                rows: hit.neighbors, startIndex: max(0, hit.messageIndex - 2), index: hit.messageIndex,
                roleFilter: roleFilter, authorFilter: authorFilter, sessionId: hit.sessionId, excludingRunID: excludingRunID)) }
            Self.consumePersistedHistoryEvidence(.object(obj))
            return .object(obj)
        }
        var response: [String: JSONValue] = [
            "status": .string("ok"),
            "runtime": .string("swift-native"),
            "tool": .string(invokedAs),
            "source": .string("chat_history_jsonl"),
            "query": .string(query),
            "mode": .string(dayDigest ? "day_digest" : (continuityMode ? "continuity" : (exactMode ? "exact" : "hybrid"))),
            "scope": .string(scope),
            "phase": .string(phase),
            "sort": .string(sort),
            "coverage": .object([
                "complete": .bool(!listingFailed && unreadableSessions.isEmpty && malformedRows.isEmpty && undatedMatches.isEmpty),
                "directory_listing_failed": .bool(listingFailed),
                "unreadable_session_count": .int(Int64(unreadableSessions.count)),
                "malformed_row_count": .int(Int64(malformedRows.count)),
                "undated_matches_excluded": .int(Int64(undatedMatches.count)),
                "scope": .string(phase),
            ]),
            "searched_session_count": .int(Int64(searchedSessions.count)),
            "hit_count": .int(Int64(hits.count)),
            "returned_count": .int(Int64(out.count)),
            "offset": .int(Int64(offset)),
            "has_more": .bool(offset + out.count < selectableCount),
            dayDigest ? "sessions" : "hits": .array(Array(out)),
        ]
        if roleFilter == "tool" {
            response["evidence_type"] = .string("persisted_tool_receipt")
            response["receipt_coverage"] = .string(Self.toolReceiptCoverage)
        }
        if workContextQuery != nil {
            response["selection_policy"] = .string("Prefer matching turns with recorded activity outside history lookup, newest within each tier; retain the newest matching context and one excerpt per known run. Tool activity is a retrieval hint, not proof of success. Ordinary history search remains available for every matching row.")
        }
        if before != nil { response["before"] = input["before"] }
        if after != nil { response["after"] = input["after"] }
        if before == nil, after == nil, let days = Self.chatHistoryQueryDays(query) {
            response["date_query_note"] = .string("Dates in query text do not filter results. Use after/before with no query to read a local-day digest. A month/day without a year uses the current local year.")
            if days.count == 1, let day = days.first,
               let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) {
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = .current
                formatter.dateFormat = "yyyy-MM-dd"
                var args = input.filter { ["scope", "session_id", "current_session_id", "role", "author", "limit"].contains($0.key) }
                args["after"] = .string(formatter.string(from: day))
                args["before"] = .string(formatter.string(from: nextDay))
                response["next_call"] = .object(["tool": .string("app"), "input": .object([
                    "action": .string("chat.search"), "args": .object(args)])])
            }
        }
        if let authorFilter, !authorFilter.isEmpty { response["author"] = .string(authorFilter) }
        if sort != "relevance", !exactMode, !query.isEmpty {
            response["search_hint"] = .string("Chronological sorting includes partial word matches in hybrid/continuity mode. Use mode: exact to find the whole query phrase.")
        }
        if listingFailed || !unreadableSessions.isEmpty || !malformedRows.isEmpty || !undatedMatches.isEmpty {
            response["coverage_note"] = .string("Some evidence could not be searched or dated. Missing results do not establish absence; coverage applies only to the reported search scope.")
        }
        if offset + out.count < selectableCount {
            response["next_offset"] = .int(Int64(offset + out.count))
        }
        if let currentSessionId, !currentSessionId.isEmpty {
            response["current_session_id"] = .string(currentSessionId)
        }
        if let fallbackSkipped {
            response["fallback_skipped"] = .string(fallbackSkipped)
        }
        if let resolvedPreviousSessionId {
            response["previous_session_id"] = .string(resolvedPreviousSessionId)
        }
        return .object(response)
    }

    /// Evidence about how a turn was produced, never a text classifier for
    /// "test" or "done" and never a success/authority judgment. A turn that
    /// reads history can repeat older work verbatim; don't let that echo
    /// displace the original simply by being newer. Other activity in that
    /// turn does not erase its history-lookup provenance.
    private static func workContextActivityRank(_ tools: Set<String>) -> Int {
        let historyTools: Set<String> = [
            "workspace", "work_context", "artifact_find", "search_chat_history", "session_search",
            "read_chat_message", "recall_memory", "recall_search", "context_lookup", "studio_recall"
        ]
        if !tools.isDisjoint(with: historyTools) { return 2 }
        let discoveryTools: Set<String> = ["tool_catalog", "tool_load", "list_tools", "tool_result_page"]
        return tools.subtracting(discoveryTools).isEmpty ? 1 : 0
    }

    private static let toolReceiptCoverage = "Historical persisted receipt, potentially redacted or truncated; not the full original result or a fresh source read. Paging expands only the retained receipt."

    /// An explicit next call, never an implicit relevance or date filter.
    private static func chatHistoryQueryDays(_ query: String) -> Set<Date>? {
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        let pattern = "\\b(today|yesterday|last\\s+night|[0-9]{4}-[0-9]{2}-[0-9]{2}|(?:\(months.joined(separator: "|")))\\s+[0-9]{1,2}(?:,?\\s+[0-9]{4})?)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: query, range: NSRange(query.startIndex..., in: query))
        guard !matches.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        var days: Set<Date> = []
        for match in matches {
            guard let range = Range(match.range, in: query) else { return [] }
            let text = query[range].lowercased()
            let parts = text.split { $0.isWhitespace || $0 == "," || $0 == "-" }.map(String.init)
            if text == "today" { days.insert(today); continue }
            if text == "yesterday" || parts == ["last", "night"] {
                guard let date = calendar.date(byAdding: .day, value: -1, to: today) else { return [] }
                days.insert(date)
                continue
            }
            let year: Int?
            let month: Int?
            let day: Int?
            if let index = months.firstIndex(of: parts[0]) {
                year = parts.count == 3 ? Int(parts[2]) : calendar.component(.year, from: today)
                month = index + 1
                day = Int(parts[1])
            } else {
                year = Int(parts[0]); month = Int(parts[1]); day = Int(parts[2])
            }
            guard let year, let month, let day,
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day)
            else { return [] }
            days.insert(date)
        }
        return days
    }

    private static func chatHistorySearchRow(
        _ line: String, receipts: Bool, fractional: ISO8601DateFormatter, whole: ISO8601DateFormatter
    ) -> ChatHistorySearchRow {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = try? JSONValue.parse(Data(trimmed.utf8)), case .object(let obj) = parsed else {
            return ChatHistorySearchRow(valid: false, object: [:], identity: trimmed, content: "", searchable: "", folded: "",
                instant: nil, author: nil, route: nil, peer: nil, tool: nil, displayPrefix: "")
        }
        func string(_ value: JSONValue?) -> String? { if case .string(let text)? = value { return text }; return nil }
        let role = (string(obj["role"]) ?? "unknown").lowercased()
        var content = role == "tool" ? (receipts ? persistedToolReceiptText(row: obj) : "")
            : (string(obj["content"]) ?? string(obj["text"]) ?? "")
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content = "" }
        // Only persisted bridge provenance strips routing boilerplate; quoted words stay searchable.
        let searchable = ChatTranscriptBoilerplate.substantiveText(content,
            bridgeRouted: ChatTranscriptBoilerplate.isBridgeRouted(rowMetadata: obj["metadata"]))
        let timestamp = string(obj["createdAt"]) ?? string(obj["timestamp"]) ?? ""
        let metadata = persistedHistoryMetadata(row: obj)
        let name = string(metadata["toolName"] ?? obj["toolName"])
        return ChatHistorySearchRow(
            valid: true,
            object: obj.filter { ["id", "role", "runId", "createdAt", "timestamp", "content", "text"].contains($0.key) && (role != "tool" || !["content", "text"].contains($0.key)) },
            identity: string(obj["id"]) ?? trimmed, content: content, searchable: searchable, folded: searchable.lowercased(),
            instant: role == "tool" && !receipts ? nil : (fractional.date(from: timestamp) ?? whole.date(from: timestamp)),
            author: persistedHistoryAuthor(role: role, row: obj), route: persistedHistoryRoute(row: obj),
            peer: role != "tool" || receipts ? persistedHistoryPeer(role: role, row: obj) : nil,
            tool: name.flatMap { $0.isEmpty ? nil : ToolNameAliases.shown($0, inputJSON: string(metadata["inputJSON"])).name },
            displayPrefix: chatHistoryDisplayEvidence("", role: role, row: obj))
    }

    private static func persistedHistoryMetadata(row: [String: JSONValue]) -> [String: JSONValue] {
        switch row["metadata"] {
        case .object(let object)?: return object
        case .string(let text)?:
            if let value = try? JSONValue.parse(Data(text.utf8)), case .object(let object) = value { return object }
            return [:]
        default: return [:]
        }
    }

    /// A narrow projection owned by explicit history tools. Do not teach the
    /// ordinary history reader to inject tool metadata into every new turn.
    private static func persistedToolReceiptText(row: [String: JSONValue]) -> String {
        let metadata = persistedHistoryMetadata(row: row)
        func value(_ key: String) -> JSONValue? { metadata[key] ?? row[key] }
        func serialized(_ value: JSONValue?) -> String? {
            guard let value, value != .null else { return nil }
            if case .string(let text) = value { return text }
            return try? value.serialize(pretty: false)
        }
        let toolName = serialized(value("toolName")) ?? serialized(value("name")) ?? "unknown"
        var clipped = false
        func bounded(_ text: String, maximum: Int) -> String {
            let redacted = ChatSecretRedactor.redactText(String(text.prefix(maximum + 512)))
            guard text.count > maximum || redacted.count > maximum else { return redacted }
            clipped = true
            return String(redacted.prefix(maximum)) + "\n[receipt field truncated in history projection]"
        }
        var receipt: [String: JSONValue] = ["toolName": .string(bounded(toolName, maximum: 200))]
        if let input = serialized(value("inputJSON")) {
            receipt["inputJSON"] = .string(bounded(
                ChatToolJSONRedaction.injectionRedactedArgJSON(tool: toolName, json: input), maximum: 5_000
            ))
        }
        let result = serialized(value("resultSummary"))
            ?? serialized(row["content"]) ?? serialized(row["text"]) ?? ""
        // Preserve a clipped JSON string as a string. Parsing a surviving
        // prefix into a fresh success envelope would invent missing evidence.
        // An app call of a folded action is redacted as the tool it ran.
        let ran = ToolNameAliases.shown(toolName, inputJSON: serialized(value("inputJSON"))).name
        let safeResult = ChatToolJSONRedaction.screenViewRedactedResultJSON(tool: ran, json: result)
        receipt["resultSummary"] = .string(bounded(
            ChatToolJSONRedaction.injectionRedactedResultJSON(tool: ran, json: safeResult), maximum: 10_000
        ))
        if let body = serialized(value("resultBody")) {
            let safeBody = ChatToolJSONRedaction.screenViewRedactedResultJSON(tool: ran, json: body)
            receipt["resultBody"] = .string(bounded(
                ChatToolJSONRedaction.injectionRedactedResultJSON(tool: ran, json: safeBody), maximum: 10_000
            ))
        }
        for key in ["resultClass", "resultStatus", "resultReturnedID", "resultEffects", "status", "ok"] {
            guard let stored = value(key) else { continue }
            switch stored {
            case .string(let text): receipt[key] = .string(bounded(text, maximum: 200))
            case .bool: receipt[key] = stored
            default: break
            }
        }
        if value("resultBody") == nil, case .object(var evidence)? = value("receiptEvidence"),
           let encoded = try? JSONValue.object(evidence).serialize(pretty: false), encoded.count <= 6_000,
           let safe = try? JSONValue.parse(Data(ChatSecretRedactor.redactText(encoded).utf8)),
           case .object(let redacted) = safe {
            evidence = redacted
            if let status = serialized(value("resultStatus"))
                ?? ChatTranscriptEvidenceRendering.recordedToolStatus(metadata) { evidence["status"] = .string(status) }
            receipt["receiptEvidence"] = .object(SessionHistoryPromptRenderer.restoringReceiptBoundaries(evidence))
        }
        receipt["evidence_type"] = .string("persisted_tool_receipt")
        receipt["receipt_projection_truncated"] = .bool(clipped)
        return (try? JSONValue.object(receipt).serialize(pretty: false)) ?? "[unreadable persisted tool receipt]"
    }

    /// Search relevance still uses the original content. Recorded provenance
    /// is display-only, shared with ordinary history and compaction, and never
    /// grants a bridge request or an interrupted answer additional authority.
    private static func chatHistoryDisplayEvidence(
        _ content: String, role: String, row: [String: JSONValue]
    ) -> String {
        let metadata: [String: JSONValue]?
        if case .object(let value)? = row["metadata"] { metadata = value }
        else { metadata = nil }
        if case .string(let kind)? = metadata?["kind"], kind.lowercased() == "compaction_summary" {
            return content
        }
        return ChatTranscriptEvidenceRendering.displayContent(
            content,
            originLabel: role == "user"
                ? ChatTranscriptEvidenceRendering.recordedOriginLabel(metadata?["origin"]) : nil,
            incompleteReplyLabel: role == "assistant"
                ? ChatTranscriptEvidenceRendering.recordedIncompleteReplyLabel(extras: row, metadata: metadata) : nil
        )
    }

    /// Resolve peer identity from persisted app provenance, as full reads do.
    package static func persistedHistoryPeer(role: String, row: [String: JSONValue]) -> String? {
        let metadata = persistedHistoryMetadata(row: row)
        if case .array(let saved)? = metadata["untrusted_sources"] {
            let sources = saved.compactMap { if case .string(let source) = $0, !source.isEmpty { return source }; return nil }
            if !sources.isEmpty {
                // Retained taint is not a live contact whose elevation can
                // retroactively grant authority to these stored words.
                return "retained untrusted content (\(sources.joined(separator: ", ")))"
            }
        }
        if role.lowercased() == "tool" {
            let tool = HumanConversationReader.string(metadata["toolName"] ?? row["toolName"]
                ?? metadata["name"] ?? row["name"]) ?? ""
            let storedInput = metadata["inputJSON"] ?? row["inputJSON"]
            let input: [String: JSONValue]
            if case .string(let text)? = storedInput,
               let parsed = try? JSONValue.parse(Data(text.utf8)) {
                input = HumanConversationReader.object(parsed)
            } else {
                input = HumanConversationReader.object(storedInput)
            }
            for key in ["receiptEvidence", "resultSummary", "resultBody", "content", "text"] {
                let stored = metadata[key] ?? row[key]
                let result: JSONValue?
                if case .string(let text)? = stored { result = try? JSONValue.parse(Data(text.utf8)) }
                else { result = stored }
                if let result, PeerDataTaintDispatcher.remoteProvenance(in: result, depth: 0) != nil {
                    return "a remote peer"
                }
            }
            if let peer = PeerDataTaintDispatcher.routedContact(tool: tool, input: input) { return peer }
            // Clipped routing cannot attest a trusted contact. Keep peer
            // receipts subject to the approval floor when that identity is lost.
            if ["agent_message", "agent_read"].contains(ToolNameAliases.ranTool(tool, input: input)) {
                return "a remote peer"
            }
            if ["read_page", "browser.chrome_snapshot", "browser.read_text", "browser.read_links"]
                .contains(ToolNameAliases.ranTool(tool, input: input)) { return "web content" }
            return nil
        }
        guard role.lowercased() == "user" else { return nil }
        let envelope = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
        let origin = HumanConversationReader.object(metadata["origin"])
        let surface = HumanConversationReader.string(origin["surface"]) ?? envelope?.surface ?? ""
        guard surface.hasSuffix("-bridge") || PeerTurnEffectPolicy.isPeerBridge(surface: surface) else { return nil }
        if let agent = HumanConversationReader.string(origin["agent"]) ?? envelope?.agent,
           ["codex", "claude", "omp"].contains(agent) { return agent }
        let id = envelope?.verifiedUserId ?? "unknown"
        return id.hasPrefix("peer:") ? id : "peer:" + id
    }

    private static func persistedHistoryRoute(row: [String: JSONValue]) -> String? {
        let metadata = persistedHistoryMetadata(row: row)
        let origin = HumanConversationReader.object(metadata["origin"])
        let source = HumanConversationReader.string(row["source"])
        return HumanConversationReader.string(origin["surface"])
            ?? (source?.hasSuffix("-bridge") == true ? source : nil)
            ?? TurnEnvelope.fromPersistedMetadata(metadata["envelope"])?.surface
            ?? source
    }

    /// The author of the owner's own messages on their own doors: a role, never a name.
    package static let ownerAuthor = "owner"

    package static func persistedHistoryAuthor(role: String, row: [String: JSONValue]) -> String? {
        guard role == "user" else { return nil }
        let metadata = persistedHistoryMetadata(row: row)
        let origin = HumanConversationReader.object(metadata["origin"])
        let envelope = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
        let route = (persistedHistoryRoute(row: row) ?? "").lowercased()
        if route == "bridge" || route.hasSuffix("-bridge") || envelope?.agent != nil {
            if origin["authored"] == .string("human") { return "human via bridge" }
            return HumanConversationReader.string(origin["agent"]) ?? envelope?.agent ?? "unknown agent"
        }
        if metadata["mechanicalKind"] != nil { return "automated" }
        if ["app", "chat", "ios"].contains(route), origin.isEmpty { return ownerAuthor }
        return envelope?.verifiedUserId ?? "unknown"
    }

    /// Latch only selected, returned excerpts, never rows scanned for ranking.
    package static func consumeRenderedToolReceipt(_ text: String) {
        let receipt = text.range(of: " [context.expand history:", options: .backwards)
            .map { String(text[..<$0.lowerBound]) } ?? text
        if let evidence = try? JSONValue.parse(Data(receipt.utf8)) {
            consumePersistedHistoryEvidence(evidence)
        }
    }

    package static func consumePersistedHistoryEvidence(_ value: JSONValue) {
        switch value {
        case .object(let fields):
            MemoryDataProvenance.consume(.object(fields))
            if case .bool(true)? = fields["untrusted_remote_data"],
               case .string(let peer)? = fields["agent"] {
                let line = HumanConversationReader.string(fields["preview"] ?? fields["excerpt"] ?? fields["text"]) ?? ""
                PeerDataTaint.markConsumed(peer: peer, line: line, attested: fields["source_boundary"] == nil)
            }
            for child in fields.values { consumePersistedHistoryEvidence(child) }
        case .array(let values):
            for child in values { consumePersistedHistoryEvidence(child) }
        default: break
        }
    }

    /// Only the explicitly invoked history tool asks for this material. No
    /// background digest, cross-session scan, or work reminder is injected.
    private static func continuityNeighbors(
        rows: [ChatHistorySearchRow], startIndex: Int, index: Int, roleFilter: String?, authorFilter: String?, sessionId: String,
        excludingRunID: String?
    ) -> [JSONValue] {
        return rows.enumerated().compactMap { localIndex, cached in
            let offset = startIndex + localIndex
            let row = cached.object
            guard offset != index,
                  case .string(let role)? = row["role"],
                  ["user", "assistant"].contains(role),
                  roleFilter == nil || roleFilter == role,
                  case .string(let content)? = row["content"] ?? row["text"] else { return nil }
            let author = cached.author
            if let authorFilter, !authorFilter.isEmpty, author?.lowercased() != authorFilter { return nil }
            let display = cached.displayPrefix + String(content.prefix(480))
            var result: [String: JSONValue] = [
                "role": .string(role), "message_index": .int(Int64(offset)),
                "excerpt": .string(String(display.prefix(480))),
                "truncated": .bool(content.count > 480 || display.count > 480),
            ]
            if let author {
                result["author"] = .string(author)
                result["author_route"] = .string(cached.route ?? "unknown")
            }
            if let peer = cached.peer {
                result["agent"] = .string(peer)
                result["untrusted_remote_data"] = .bool(!PeerDataTaint.ownerTrusts(peer) && !display.isEmpty)
            }
            if let excludingRunID, row["runId"] == .string(excludingRunID) { return nil }
            result["timestamp"] = row["createdAt"] ?? row["timestamp"]
            if case .string(let messageId)? = row["id"], !messageId.isEmpty {
                result["message_id"] = .string(messageId)
                result["read_locator"] = .object([
                    "tool": .string("read_chat_message"),
                    "arguments": .object(["session_id": .string(sessionId), "message_id": .string(messageId)])
                ])
            }
            return .object(result)
        }
    }

    private func readChatHistorySessionMetadata() -> [String: ChatHistorySessionMetadata] {
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .array(let rows) = parsed else {
            return [:]
        }
        var out: [String: ChatHistorySessionMetadata] = [:]
        for row in rows {
            guard case .object(let obj) = row,
                  let id = jsonString(obj["id"]),
                  !id.isEmpty else {
                continue
            }
            out[id] = ChatHistorySessionMetadata(
                title: jsonString(obj["title"]),
                createdAt: jsonString(obj["createdAt"]) ?? jsonString(obj["created_at"])
            )
        }
        return out
    }

    private func validatedChatSessionId(_ sessionId: String) throws -> String {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: invalid chat session id '\(sessionId)'"
            )
        }
        return safeSessionId
    }

    private func chatSearchTokens(_ query: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "into",
            "about", "what", "when", "where", "who", "why", "how",
        ]
        let pieces = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        var seen: Set<String> = []
        var out: [String] = []
        for piece in pieces {
            guard piece.count >= 2, !stopWords.contains(piece), !seen.contains(piece) else {
                continue
            }
            seen.insert(piece)
            out.append(piece)
        }
        return out
    }

    private func chatHistoryScore(
        content: String,
        sessionTitle: String?,
        query: String,
        tokens: [String],
        exactMode: Bool
    ) -> Double {
        let searchable = "\(content) \(sessionTitle ?? "")"
        let phraseMatch = searchable.contains(query)
        if exactMode {
            return phraseMatch ? 1.0 : 0.0
        }
        var score = phraseMatch ? 1.0 : 0.0
        if !tokens.isEmpty {
            let matched = tokens.filter { searchable.contains($0) }.count
            score += Double(matched) / Double(tokens.count)
        }
        return score
    }

    private func chatHistoryPreview(content: String, query: String, tokens: [String]) -> String {
        let maxChars = 360
        let compact = content.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        guard compact.count > maxChars else { return compact }
        let queryRange = compact.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        let tokenRange = tokens.lazy.compactMap {
            compact.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }.first
        let range = queryRange ?? tokenRange
        let anchorOffset = range.map { compact.distance(from: compact.startIndex, to: $0.lowerBound) } ?? 0
        let startOffset = max(0, anchorOffset - 90)
        let start = compact.index(compact.startIndex, offsetBy: startOffset)
        let available = compact.distance(from: start, to: compact.endIndex)
        let end = compact.index(start, offsetBy: min(maxChars, available))
        var snippet = String(compact[start..<end])
        if startOffset > 0 { snippet = "... " + snippet }
        if end < compact.endIndex { snippet += " ..." }
        return snippet
    }
}

// MARK: - Read one chat message in full

/// Agent, 2026-09-06: `search_chat_history` returns a 368-character preview and
/// `mode:"continuity"` adds bounded NEIGHBOURS — but the matched message itself
/// was never available whole. Reading past the preview meant re-phrasing the
/// query until a different fragment happened to be the anchor. This tool takes
/// the `message_id` search already returns and pages the complete stored text.
///
/// The text is returned VERBATIM — no boilerplate stripping, no evidence
/// rendering. Search hides plumbing so matches stay honest; this is the tool
/// for seeing exactly what the row says, plumbing included.
extension SwiftToolDispatcher {
    /// Characters per page. A page is a bounded read, not a whole transcript.
    static let readChatMessageDefaultPageCharacters = 8_000
    static let readChatMessageMaximumPageCharacters = 16_000

    func impl_read_chat_message(input: [String: JSONValue], invokedAs: String) async throws -> JSONValue {
        let input = input.filter { $0.value != .string("") }
        let messageId = (jsonString(input["message_id"]) ?? jsonString(input["id"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageId.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: read_chat_message needs the 'message_id' search_chat_history returned"
            )
        }
        let offset = max(0, optionalInt(input, "offset") ?? 0)
        let limit = max(
            1,
            min(
                optionalInt(input, "limit") ?? Self.readChatMessageDefaultPageCharacters,
                Self.readChatMessageMaximumPageCharacters
            )
        )
        let requestedSession = jsonString(input["session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The session ids to look in, most recently written first. An explicit
        // id is the most specific instruction there is; without one this walks
        // the same file set search_chat_history walks and stops at the match.
        let files: [(String, URL)]
        var listingFailed = false
        let archived = try ChatSessionRetention.archivedTranscripts(dataRoot: dataRoot)
        if let requestedSession, !requestedSession.isEmpty {
            files = try ChatSessionRetention.transcriptFiles(
                dataRoot: dataRoot, sessionId: validatedChatSessionId(requestedSession), archived: archived)
        } else {
            do {
                files = try ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, archived: archived)
            } catch {
                files = []
                listingFailed = true
            }
        }

        // The canonical transcript reader — the same one prompt assembly uses.
        // No second JSONL parser lives here.
        let reader = SessionHistoryReader(dataRoot: dataRoot)
        // 2026-09-06: a FORK copies the source transcript's rows byte for byte,
        // ids included (the fork writer, since deleted), so one
        // message id can live in several sessions. This used to stop at the
        // first file and say nothing, which could hand back a different copy
        // than the search hit came from. Every session is checked now: the
        // newest-written copy is returned (the file list is mtime-ordered) and
        // the others are named so the caller can ask for one by session_id.
        var found: (sessionId: String, index: Int, message: ChatMessage, stats: SessionHistoryReadStats)?
        var alsoIn: [String] = []
        var unreadableSessionCount = 0
        var missingSessionCount = 0
        var malformedRowCount = 0
        var invalidShapeRowCount = 0
        for (sessionId, file) in files {
            guard let read = try? await reader.messagesWithStats(forSessionId: sessionId, strictEvidence: true, transcriptURL: file) else {
                unreadableSessionCount += 1
                continue
            }
            if read.stats.mode == "missing" {
                missingSessionCount += 1
                continue
            }
            guard read.stats.mode == "full", !read.stats.truncated else {
                unreadableSessionCount += 1
                continue
            }
            malformedRowCount += read.stats.malformedRowCount
            invalidShapeRowCount += read.stats.invalidShapeRowCount
            let messages = read.messages
            guard let index = messages.firstIndex(where: { message in
                guard case .object(let row)? = message.extras,
                      case .string(let id)? = row["id"] else { return false }
                return id == messageId
            }) else { continue }
            if found == nil {
                found = (sessionId, index, messages[index], read.stats)
            } else if found?.sessionId != sessionId, !alsoIn.contains(sessionId) {
                alsoIn.append(sessionId)
            }
        }
        let complete = !listingFailed && unreadableSessionCount == 0
            && malformedRowCount == 0 && invalidShapeRowCount == 0
        let coverage: JSONValue = .object([
            "complete": .bool(complete),
            "scope": .string(requestedSession?.isEmpty == false ? "explicit_session" : "all_sessions"),
            "directory_listing_failed": .bool(listingFailed),
            "unreadable_session_count": .int(Int64(unreadableSessionCount)),
            "missing_session_count": .int(Int64(missingSessionCount)),
            "malformed_row_count": .int(Int64(malformedRowCount)),
            "invalid_shape_row_count": .int(Int64(invalidShapeRowCount)),
        ])
        guard let found else {
            return .object([
                "status": .string(complete ? "not_found" : "error"),
                "runtime": .string("swift-native"),
                "tool": .string(invokedAs),
                "message_id": .string(messageId),
                "searched_session_count": .int(Int64(Set(files.map { $0.0 }).count)),
                "coverage": coverage,
                "reason": .string(!complete
                    ? "History could not be read completely. This does not establish that the message is absent. Preserve the original locator; do not recreate or replay the original action."
                    : requestedSession?.isEmpty == false
                    ? "No message with that id in that session. Drop session_id to search every transcript."
                    : "No message with that id in any transcript. Ids come from search_chat_history hits."),
            ])
        }

        let isToolReceipt = found.message.role.lowercased() == "tool"
        let readText: String
        if isToolReceipt, case .object(let row)? = found.message.extras {
            readText = Self.persistedToolReceiptText(row: row)
        } else {
            readText = found.message.content
        }
        let characters = Array(readText)
        let start = min(offset, characters.count)
        let end = min(start + limit, characters.count)
        let page = String(characters[start..<end])
        var response: [String: JSONValue] = [
            "status": .string("ok"),
            "runtime": .string("swift-native"),
            "tool": .string(invokedAs),
            "source": .string("chat_history_jsonl"),
            "message_id": .string(messageId),
            "session_id": .string(found.sessionId),
            "role": .string(found.message.role),
            "timestamp": .string(found.message.timestamp),
            "message_index": .int(Int64(found.index)),
            "coverage": coverage,
            "total_characters": .int(Int64(characters.count)),
            "offset": .int(Int64(start)),
            "returned_characters": .int(Int64(end - start)),
            "has_more": .bool(end < characters.count),
            "text": .string(page),
        ]
        if found.message.role.lowercased() == "user",
           case .object(let row)? = found.message.extras,
           case .object(let metadata)? = row["metadata"] {
            if let origin = metadata["origin"] {
                response["origin"] = origin
                if let label = ChatTranscriptEvidenceRendering.recordedOriginLabel(origin) {
                    response["authorship"] = .string(label)
                }
            }
        }
        if case .object(let row)? = found.message.extras,
           let peer = Self.persistedHistoryPeer(role: found.message.role, row: row) {
            response["agent"] = .string(peer)
            response["untrusted_remote_data"] = .bool(!PeerDataTaint.ownerTrusts(peer) && !page.isEmpty)
            if !page.isEmpty { PeerDataTaint.markConsumed(peer: peer, line: page) }
        }
        if found.stats.malformedRowCount > 0 || found.stats.invalidShapeRowCount > 0 {
            response["message_index"] = .null
            response["message_index_note"] = .string("Source row index unavailable because earlier rows may have been skipped. Use the exact message_id and session_id.")
        }
        if !complete {
            response["coverage_note"] = .string("The returned message was readable, but other history evidence was unavailable or malformed. Other copies or missing messages cannot be ruled out.")
        }
        if isToolReceipt {
            response["evidence_type"] = .string("persisted_tool_receipt")
            response["receipt_coverage"] = .string(Self.toolReceiptCoverage)
        }
        if end < characters.count {
            response["next_offset"] = .int(Int64(end))
        }
        if !alsoIn.isEmpty {
            response["also_in_sessions"] = .array(alsoIn.map { .string($0) })
            response["session_ambiguous"] = .bool(true)
            response["note"] = .string(
                "This id also exists in \(alsoIn.count) other session(s) — forks copy rows verbatim. "
                + "Returned the most recently written copy, from session_id '\(found.sessionId)'. "
                + "Pass session_id to read a named copy."
            )
        }
        if let title = readChatHistorySessionMetadata()[found.sessionId]?.title, !title.isEmpty {
            response["session_title"] = .string(title)
        }
        return .object(response)
    }
}
