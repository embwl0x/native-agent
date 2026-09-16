import Foundation
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
    var sessionId: String
    var sessionTitle: String?
    var sessionCreatedAt: String?
    var role: String
    var timestamp: String
    var timestampInstant: Date?
    var messageId: String?
    var messageIndex: Int
    var preview: String
    var continuity: [JSONValue]
}

// MARK: - Chat history search tools

extension SwiftToolDispatcher {
    static let chatHistoryCurrentSessionFloor = 0.3

    func impl_search_chat_history(input: [String: JSONValue], invokedAs: String) async throws -> JSONValue {
        let requestedScope = (jsonString(input["scope"]) ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scope: String = {
            switch requestedScope {
            case "", "auto", "current_session_first", "current_session", "all_sessions":
                return requestedScope.isEmpty ? "auto" : requestedScope
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
                return "auto"
            }
        }()
        // `previous_session` pins exactly ONE session by resolution, so it is
        // the one scope that is complete WITHOUT a query: "pull my last
        // session back" is a whole-session request, and the anchor's pointer
        // would otherwise name a call she cannot actually make. Empty query
        // means "no relevance filter" — every row is admitted at score 0 and
        // the sort falls through to recency, i.e. the tail of that session.
        let wholeSession = scope == "previous_session"
        let rawQuery = wholeSession
            ? (jsonString(input["query"]) ?? "")
            : try requireString(input, "query")
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || wholeSession else {
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
        let limit = max(1, min(requestedLimit, continuityMode ? 4 : 12))
        let roleFilter = jsonString(input["role"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sessionFilter = jsonString(input["session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSessionId = jsonString(input["current_session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let messagesDir = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        let sessionMeta = readChatHistorySessionMetadata()
        let tokens = chatSearchTokens(query)
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
            guard let date = fractionalTimestamp.date(from: text) ?? wholeTimestamp.date(from: text) else {
                throw AutonomyGateError.toolDenied(reason: "Chat history '\(key)' must be an ISO8601 timestamp with a timezone.")
            }
            return date
        }
        let before = try bound("before")
        let after = try bound("after")
        if let before, let after, after >= before {
            throw AutonomyGateError.toolDenied(reason: "Chat history 'after' must precede 'before'.")
        }
        let sort = jsonString(input["sort"]) ?? "relevance"
        guard ["relevance", "oldest", "newest"].contains(sort) else {
            throw AutonomyGateError.toolDenied(reason: "Chat history sort must be relevance, oldest, or newest.")
        }
        // Count unique failures across the current-session probe and fallback.
        // A partial scan must never masquerade as proof that evidence is absent.
        var unreadableSessions: Set<String> = []
        var malformedRows: Set<String> = []
        var undatedMatches: Set<String> = []
        var listingFailed = false
        func allFiles() -> [URL] {
            guard FileManager.default.fileExists(atPath: messagesDir.path) else { return [] }
            do {
                return try FileManager.default.contentsOfDirectory(
                    at: messagesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "jsonl" }
            } catch {
                listingFailed = true
                return []
            }
        }

        func scan(_ messageFiles: [URL]) -> (hits: [ChatHistorySearchHit], sessions: Set<String>) {
            var hits: [ChatHistorySearchHit] = []
            var searchedSessions: Set<String> = []
            for file in messageFiles {
                let sessionId = sessionIdForMessageFile(file)
                searchedSessions.insert(sessionId)
                guard let data = try? Data(contentsOf: file),
                      let text = String(data: data, encoding: .utf8) else {
                    unreadableSessions.insert(sessionId)
                    continue
                }
                let meta = sessionMeta[sessionId]
                var messageIndex = 0
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                for rawLine in lines {
                    defer { messageIndex += 1 }
                    let trimmed = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    guard let lineData = trimmed.data(using: .utf8),
                          let parsed = try? JSONValue.parse(lineData),
                          case .object(let obj) = parsed else {
                        malformedRows.insert("\(sessionId):\(messageIndex)")
                        continue
                    }
                    let role = (jsonString(obj["role"]) ?? "unknown").lowercased()
                    if let roleFilter, !roleFilter.isEmpty, role != roleFilter {
                        continue
                    }
                    // Receipt metadata is an explicit evidence lane, never
                    // extra material injected into ordinary conversation recall.
                    if role == "tool", roleFilter != "tool" { continue }
                    let recordedContent = role == "tool"
                        ? Self.persistedToolReceiptText(row: obj)
                        : (jsonString(obj["content"]) ?? jsonString(obj["text"]))
                    guard let content = recordedContent,
                          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    // Agent, 2026-09-06: the bridge routing prefix and the
                    // wake-receipt slip are plumbing, not things anyone said.
                    // Matching inside them buried real answers under hundreds
                    // of "[from: claude, via bridge]" / "Automated completion
                    // event … Do NOT auto-fire …" hits. Score and preview the
                    // substantive text; a row that is nothing BUT plumbing
                    // scores zero and drops out through the guard below.
                    //
                    // 2026-09-06: gated on the row's PERSISTED bridge
                    // provenance, not on the syntax of its text, so a person
                    // who quotes that syntax keeps every word.
                    let searchable = ChatTranscriptBoilerplate.substantiveText(
                        content,
                        bridgeRouted: ChatTranscriptBoilerplate.isBridgeRouted(
                            rowMetadata: obj["metadata"]
                        )
                    )
                    let score = chatHistoryScore(
                        content: searchable,
                        sessionTitle: meta?.title.map(ChatTranscriptBoilerplate.stripBridgePrefix),
                        query: query,
                        tokens: tokens,
                        exactMode: exactMode
                    )
                    guard score > 0 || query.isEmpty else { continue }
                    let timestamp = jsonString(obj["createdAt"]) ?? jsonString(obj["timestamp"]) ?? ""
                    let instant = fractionalTimestamp.date(from: timestamp) ?? wholeTimestamp.date(from: timestamp)
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
                        sessionId: sessionId,
                        sessionTitle: meta?.title,
                        sessionCreatedAt: meta?.createdAt,
                        role: role,
                        timestamp: timestamp,
                        timestampInstant: instant,
                        messageId: jsonString(obj["id"]),
                        messageIndex: messageIndex,
                        preview: String(Self.chatHistoryDisplayEvidence(
                            chatHistoryPreview(
                                content: searchable.isEmpty ? content : searchable,
                                query: query, tokens: tokens
                            ),
                            role: role, row: obj
                        ).prefix(368)),
                        continuity: continuityMode ? Self.continuityNeighbors(
                            lines: lines, index: messageIndex, roleFilter: roleFilter
                        ) : []
                    ))
                }
            }
            return (hits, searchedSessions)
        }

        func files(forSessionId sessionId: String) throws -> [URL] {
            let safeSessionId = try validatedChatSessionId(sessionId)
            return [messagesDir.appendingPathComponent("\(safeSessionId).jsonl")]
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
               let prior = PriorChatSession.latest(
                   excluding: currentSessionId, dataRoot: dataRoot
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
        hits.sort {
            if sort == "relevance", $0.score != $1.score { return $0.score > $1.score }
            switch ($0.timestampInstant, $1.timestampInstant) {
            case let (left?, right?) where left != right: return sort == "oldest" ? left < right : left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            // Equal instants (or absent dates) still need repeatable paging.
            // Within a transcript, canonical row order is the final recency
            // evidence; different sessions get a stable identity tie-break.
            if $0.sessionId != $1.sessionId { return $0.sessionId < $1.sessionId }
            return sort == "oldest" ? $0.messageIndex < $1.messageIndex : $0.messageIndex > $1.messageIndex
        }
        let page = hits.dropFirst(min(offset, hits.count)).prefix(limit)
        let out = page.map { hit -> JSONValue in
            var obj: [String: JSONValue] = [
                "session_id": .string(hit.sessionId),
                "role": .string(hit.role),
                "timestamp": .string(hit.timestamp),
                "message_index": .int(Int64(hit.messageIndex)),
                "preview": .string(hit.preview),
                "score": .double(hit.score),
            ]
            if hit.role == "tool" { obj["evidence_type"] = .string("persisted_tool_receipt") }
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
            if continuityMode { obj["surrounding_messages"] = .array(hit.continuity) }
            return .object(obj)
        }
        var response: [String: JSONValue] = [
            "status": .string("ok"),
            "runtime": .string("swift-native"),
            "tool": .string(invokedAs),
            "source": .string("chat_history_jsonl"),
            "query": .string(query),
            "mode": .string(continuityMode ? "continuity" : (exactMode ? "exact" : "hybrid")),
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
            "has_more": .bool(offset + out.count < hits.count),
            "hits": .array(Array(out)),
        ]
        if roleFilter == "tool" {
            response["evidence_type"] = .string("persisted_tool_receipt")
            response["receipt_coverage"] = .string(Self.toolReceiptCoverage)
        }
        if before != nil { response["before"] = input["before"] }
        if after != nil { response["after"] = input["after"] }
        if sort != "relevance", !exactMode, !query.isEmpty {
            response["search_hint"] = .string("Chronological sorting includes partial word matches in hybrid/continuity mode. Use mode: exact to find the whole query phrase.")
        }
        if listingFailed || !unreadableSessions.isEmpty || !malformedRows.isEmpty || !undatedMatches.isEmpty {
            response["coverage_note"] = .string("Some evidence could not be searched or dated. Missing results do not establish absence; coverage applies only to the reported search scope.")
        }
        if offset + out.count < hits.count {
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

    private static let toolReceiptCoverage = "Historical persisted receipt, potentially redacted or truncated; not the full original result or a fresh source read. Paging expands only the retained receipt."

    /// A narrow projection owned by explicit history tools. Do not teach the
    /// ordinary history reader to inject tool metadata into every new turn.
    private static func persistedToolReceiptText(row: [String: JSONValue]) -> String {
        let metadata: [String: JSONValue]
        switch row["metadata"] {
        case .object(let object)?: metadata = object
        case .string(let text)?:
            if let value = try? JSONValue.parse(Data(text.utf8)), case .object(let object) = value { metadata = object }
            else { metadata = [:] }
        default: metadata = [:]
        }
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
                SwiftNativeChatOrchestrationClient.injectionRedactedArgJSON(tool: toolName, json: input), maximum: 5_000
            ))
        }
        let result = serialized(value("resultSummary"))
            ?? serialized(row["content"]) ?? serialized(row["text"]) ?? ""
        // Preserve a clipped JSON string as a string. Parsing a surviving
        // prefix into a fresh success envelope would invent missing evidence.
        let safeResult = SwiftNativeChatOrchestrationClient.screenViewRedactedResultJSON(tool: toolName, json: result)
        receipt["resultSummary"] = .string(bounded(
            SwiftNativeChatOrchestrationClient.injectionRedactedResultJSON(tool: toolName, json: safeResult), maximum: 10_000
        ))
        for key in ["resultClass", "resultStatus", "status", "ok"] {
            guard let stored = value(key) else { continue }
            switch stored {
            case .string(let text): receipt[key] = .string(bounded(text, maximum: 200))
            case .bool: receipt[key] = stored
            default: break
            }
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

    /// Only the explicitly invoked history tool asks for this material. No
    /// background digest, cross-session scan, or work reminder is injected.
    private static func continuityNeighbors(
        lines: [Substring], index: Int, roleFilter: String?
    ) -> [JSONValue] {
        guard lines.indices.contains(index) else { return [] }
        return (max(0, index - 2)...min(lines.count - 1, index + 2)).compactMap { offset in
            guard offset != index,
                  let value = try? JSONValue.parse(Data(lines[offset].utf8)),
                  case .object(let row) = value,
                  case .string(let role)? = row["role"],
                  ["user", "assistant"].contains(role),
                  roleFilter == nil || roleFilter == role,
                  case .string(let content)? = row["content"] ?? row["text"] else { return nil }
            let display = chatHistoryDisplayEvidence(String(content.prefix(480)), role: role, row: row)
            return .object([
                "role": .string(role), "message_index": .int(Int64(offset)),
                "excerpt": .string(String(display.prefix(480))),
                "truncated": .bool(content.count > 480 || display.count > 480),
            ])
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

    private func chatMessageFiles(messagesDir: URL) throws -> [URL] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: messagesDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            if (error as? CocoaError)?.code == .fileReadNoSuchFile { return [] }
            throw error
        }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate == rDate ? lhs.lastPathComponent < rhs.lastPathComponent : lDate > rDate
            }
    }

    private func validatedChatSessionId(_ sessionId: String) throws -> String {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: invalid chat session id '\(sessionId)'"
            )
        }
        return safeSessionId
    }

    private func sessionIdForMessageFile(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.hasSuffix(".jsonl") {
            return String(name.dropLast(".jsonl".count))
        }
        return url.deletingPathExtension().lastPathComponent
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
        let searchable = "\(content) \(sessionTitle ?? "")".lowercased()
        let normalizedQuery = query.lowercased()
        let phraseMatch = searchable.contains(normalizedQuery)
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

        let messagesDir = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        // The session ids to look in, most recently written first. An explicit
        // id is the most specific instruction there is; without one this walks
        // the same file set search_chat_history walks and stops at the match.
        let sessionIds: [String]
        var listingFailed = false
        if let requestedSession, !requestedSession.isEmpty {
            sessionIds = [try validatedChatSessionId(requestedSession)]
        } else {
            do {
                sessionIds = try chatMessageFiles(messagesDir: messagesDir).map(sessionIdForMessageFile)
            } catch {
                sessionIds = []
                listingFailed = true
            }
        }

        // The canonical transcript reader — the same one prompt assembly uses.
        // No second JSONL parser lives here.
        let reader = SessionHistoryReader(dataRoot: dataRoot)
        // 2026-09-06: a FORK copies the source transcript's rows byte for byte,
        // ids included (`NativeClient+SessionLineage.forkChatSession`), so one
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
        for sessionId in sessionIds {
            guard let read = try? await reader.messagesWithStats(forSessionId: sessionId, strictEvidence: true) else {
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
            } else {
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
                "searched_session_count": .int(Int64(sessionIds.count)),
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
