import AgentConversations
import CognitiveSubstrate
import ChatSessionWork
import AgentWorkspace
import ToolRegistry
import Foundation
import NativeAgentShared
import Transcripts
import NativeAgentCore
import PersistenceCore
import MemoryV2
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution
// Blueprint: | `SwiftToolDispatcher+ChatHistoryTools.swift` | Explicit history search selection and ranking; coverage honors parse validity and cached structure; chronological digests retain true first/last instants |


struct ChatHistorySessionMetadata: Sendable {
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

// MARK: - Chat history search tools

extension SwiftToolDispatcher {
    static let chatHistoryCurrentSessionFloor = 0.3

    func impl_search_chat_history(
        input: [String: JSONValue], invokedAs: String,
        workContextQuery: WorkContextQuery? = nil,
        excludingRunID: String? = nil
    ) async throws -> JSONValue {
        var input = input.filter { $0.value != .string("") }
        let requestedScope = (input["scope"]?.stringValue ?? "all_sessions")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scope: String = try {
            switch requestedScope {
            case "", "auto", "current_session_first", "current_session", "all_sessions":
                return requestedScope.isEmpty ? "all_sessions" : requestedScope
            case "current":
                return "current_session"
            case "previous_session", "last_session":
                // The other half of the /new carry-over anchor. See the resolution branch below.
                return "previous_session"
            case "all", "global", "all_session":
                // Explicit all-scope spellings search every session.
                return "all_sessions"
            default:
                throw AutonomyGateError.toolDenied(reason: "Chat history scope must be all_sessions, current_session, previous_session, auto, or current_session_first.")
            }
        }()
        // A resolved previous session is complete without a query; empty queries admit every row at score zero and sort by recency.
        let wholeSession = scope == "previous_session"
        // Likewise a session or time window with no query lists that window.
        let window = wholeSession || ["session_id", "after", "before", "since"].contains {
            !(input[$0]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        let rawQuery = window
            ? (input["query"]?.stringValue ?? "")
            : try requireString(input, "query")
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || window else {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: empty chat-history search query")
        }
        let requestedLimit = Self.jsonInt(input["limit"]) ?? 8
        // A 25-snippet response regularly exceeded 18 KB in live turns and encouraged a second broad search before the model had digested the first one. Keep a compact page while preserving complete recall via offset pagination.
        let offset = max(0, Self.jsonInt(input["offset"]) ?? 0)
        let mode = (input["mode"]?.stringValue ?? "hybrid")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let exactMode = mode == "exact"
        let continuityMode = mode == "continuity"
        let requestedRole = input["role"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let roleFilter = requestedRole == Self.ownerAuthor ? "user" : requestedRole
        let authorFilter = requestedRole == Self.ownerAuthor ? Self.ownerAuthor : input["author"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sessionFilter = input["session_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSessionId = input["current_session_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let sessionMeta = readChatHistorySessionMetadata()
        let index = ChatHistoryIndex.shared(dataRoot: dataRoot)
        let tokens = chatSearchTokens(query)
        let normalizedQuery = query.lowercased()
        func bound(_ key: String) throws -> Date? {
            guard let value = input[key], value != .null else { return nil }
            guard let rawText = value.stringValue else {
                throw AutonomyGateError.toolDenied(reason: "Chat history '\(key)' must be an ISO8601 timestamp with a timezone.")
            }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if key == "since", let unit = text.lowercased().last,
               let seconds = ["d": 86_400.0, "h": 3_600.0, "m": 60.0][String(unit)] {
                guard let amount = Double(text.dropLast()), amount > 0, (amount * seconds).isFinite else {
                    throw AutonomyGateError.toolDenied(reason: "Chat history 'since' needs a positive duration such as 1d, 7d or 2h.")
                }
                return Date().addingTimeInterval(-amount * seconds)
            }
            // A bare day means its local midnight.
            let day = ISO8601DateFormatter()
            day.formatOptions = [.withFullDate]
            day.timeZone = .current
            guard let date = NativeTimestampFormat.parseISO8601FractionalFirst(text) ?? day.date(from: text) else {
                throw AutonomyGateError.toolDenied(reason: "Chat history '\(key)' must be an ISO8601 timestamp with a timezone.")
            }
            return date
        }
        let before = try bound("before")
        let after = try [bound("after"), bound("since")].compactMap { $0 }.max()
        input.removeValue(forKey: "since")
        if let after { input["after"] = .string(NativeTimestampFormat.fractionalZulu(after)) }
        if let before, let after, after >= before {
            throw AutonomyGateError.toolDenied(reason: "Chat history 'after' must precede 'before'.")
        }
        let dayDigest = query.isEmpty && (before != nil || after != nil)
        let limit = max(1, min(requestedLimit, dayDigest ? 8 : (continuityMode ? 4 : 12)))
        let requestedSort = input["sort"]?.stringValue ?? "relevance"
        guard ["relevance", "oldest", "newest", "recent", "latest"].contains(requestedSort) else {
            throw AutonomyGateError.toolDenied(reason: "Chat history sort must be relevance, oldest, or newest.")
        }
        let sort = (dayDigest && requestedSort == "relevance") || ["recent", "latest"].contains(requestedSort) ? "newest" : requestedSort
        // Count unique failures across the current-session probe and fallback. A partial scan must never masquerade as proof that evidence is absent.
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
                guard let rows = try? index.rows(at: file, receipts: roleFilter == "tool") else {
                    unreadableSessions.insert(sessionId)
                    continue
                }
                let meta = sessionMeta[sessionId]
                let searchableTitle = meta?.title.map(BridgeRoutingPrefix.stripping)?.lowercased()
                let firstHit = hits.count
                var runTools: [String: Set<String>] = [:]
                for (messageIndex, row) in rows.enumerated() {
                    if !row.valid, row.identity.isEmpty { continue }
                    // Shape is already retained by the index, including its existing cache: an object without role/content is not evidence that this transcript was completely searched.
                    guard row.valid, row.shape == 2 else {
                        malformedRows.insert("\(sessionId):\(messageIndex)")
                        continue
                    }
                    let role = (row.role ?? "unknown").lowercased()
                    let key = sessionId + ":" + row.identity
                    guard !seen.contains(key) else { continue }
                    fileRows.insert(key)
                    if let excludingRunID, row.runId == excludingRunID { continue }
                    if workContextQuery != nil, role == "tool",
                       let runID = row.runId, !runID.isEmpty {
                        if let tool = row.tool { runTools[runID, default: []].insert(tool) }
                    }
                    if let roleFilter, !roleFilter.isEmpty, role != roleFilter {
                        continue
                    }
                    let author = row.author
                    if let authorFilter, !authorFilter.isEmpty, author?.lowercased() != authorFilter { continue }
                    // Receipt metadata is an explicit evidence lane, never extra material injected into ordinary conversation recall.
                    if role == "tool", roleFilter != "tool" { continue }
                    let content = row.content
                    guard !content.isEmpty else { continue }
                    let instant = row.instant
                    if let instant {
                        if let before, instant >= before { continue }
                        if let after, instant <= after { continue }
                    }
                    let searchable = row.searchable
                    // Optional composition-level relevance policy. Work recall must not match unrelated rows merely because their broad session title happens to name the same project.
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
                    if (before != nil || after != nil), instant == nil {
                        undatedMatches.insert("\(sessionId):\(messageIndex)")
                        continue
                    }
                    hits.append(ChatHistorySearchHit(
                        score: score,
                        runId: row.runId,
                        sessionId: sessionId,
                        sessionTitle: meta?.title,
                        sessionCreatedAt: meta?.createdAt,
                        role: role,
                        author: author,
                        authorRoute: row.route,
                        timestamp: row.timestamp ?? "",
                        timestampInstant: instant,
                        messageId: row.messageId,
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
            // Resolved through the SAME surface-scoped, bridge-excluding resolver the /new anchor used, so the session this opens is always the session the anchor named — which is why the anchor never has to carry a UUID.
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
                // Only a plausible current-session answer skips the global search.
                let bestCurrentScore = current.hits.map(\.score).max() ?? 0
                if !current.hits.isEmpty && bestCurrentScore >= Self.chatHistoryCurrentSessionFloor {
                    selected = current
                    phase = "current_session"
                    fallbackSkipped = "all_sessions"
                } else {
                    let remaining = scan(allFiles().filter { $0.0 != currentSessionId })
                    selected = (current.hits + remaining.hits, current.sessions.union(remaining.sessions))
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
            // Equal instants (or absent dates) still need repeatable paging. Within a transcript, canonical row order is the final recency evidence; different sessions get a stable identity tie-break.
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
            // Retain the newest correction and one representative per persisted run; rows without run identity remain independent.
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
                let dated = messages.compactMap { message in
                    message.timestampInstant.map { (time: $0, stamp: message.timestamp) }
                }
                let ownMessages = messages.filter { $0.role == "user" && $0.author == Self.ownerAuthor }
                let own = ownMessages.prefix(6).map { message -> JSONValue in
                    var row: [String: JSONValue] = [
                        "timestamp": .string(message.timestamp),
                        "preview": .string(String(preview(message).prefix(160))),
                    ]
                    if let id = message.messageId { row["message_id"] = .string(id) }
                    row.merge(Self.historyEvidence(message.peer, words: preview(message), dataRoot: dataRoot)) { _, new in new }
                    return JSONValue.object(row)
                }
                let digest: JSONValue = .object([
                    "session_id": .string(hit.sessionId),
                    "session_title": hit.sessionTitle.map(JSONValue.string) ?? .null,
                    "message_count": .int(Int64(messages.count)),
                    "first_time": dated.min { $0.time < $1.time }.map { .string($0.stamp) } ?? .null,
                    "last_time": dated.max { $0.time < $1.time }.map { .string($0.stamp) } ?? .null,
                    "own_message_count": .int(Int64(ownMessages.count)),
                    "own_messages": .array(own),
                ])
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
            obj.merge(Self.historyEvidence(hit.peer, words: preview(hit), dataRoot: dataRoot)) { _, new in new }
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
                roleFilter: roleFilter, authorFilter: authorFilter, sessionId: hit.sessionId, excludingRunID: excludingRunID, dataRoot: dataRoot)) }
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
            var args = input.filter { !$0.key.hasPrefix("__") && $0.key != "current_session_id" }
            args["offset"] = response["next_offset"]
            response["next_call"] = .object(["tool": .string("app"), "input": .object([
                "action": .string("chat.search"), "args": .object(args)])])
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

    static let toolReceiptCoverage = "Historical persisted receipt, potentially redacted or truncated; not the full original result or a fresh source read. Paging expands only the retained receipt."

    func readChatHistorySessionMetadata() -> [String: ChatHistorySessionMetadata] {
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
                  let id = obj["id"]?.stringValue,
                  !id.isEmpty else {
                continue
            }
            out[id] = ChatHistorySessionMetadata(
                title: obj["title"]?.stringValue,
                createdAt: obj["createdAt"]?.stringValue ?? obj["created_at"]?.stringValue
            )
        }
        return out
    }

    func validatedChatSessionId(_ sessionId: String) throws -> String {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: invalid chat session id '\(sessionId)'"
            )
        }
        return safeSessionId
    }

    /// History-lookup provenance keeps newer echoes from displacing original work; other activity in that turn does not erase its provenance.
    private static func workContextActivityRank(_ tools: Set<String>) -> Int {
        let historyTools: Set<String> = [
            "workspace", "work_context", "artifact_find", "search_chat_history", "session_search",
            "read_chat_message", "recall_memory", "recall_search", "context_lookup", "studio_recall"
        ]
        if !tools.isDisjoint(with: historyTools) { return 2 }
        let discoveryTools: Set<String> = ["tool_catalog", "tool_load", "list_tools", "tool_result_page"]
        return tools.subtracting(discoveryTools).isEmpty ? 1 : 0
    }

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
