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
    var messageId: String?
    var messageIndex: Int
    var preview: String
}

// MARK: - Chat history search tools

extension SwiftToolDispatcher {
    static let chatHistoryCurrentSessionFloor = 0.3

    func impl_search_chat_history(input: [String: JSONValue], invokedAs: String) async throws -> JSONValue {
        let rawQuery = try requireString(input, "query")
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: empty chat-history search query")
        }
        let requestedLimit = optionalInt(input, "limit") ?? 8
        let limit = max(1, min(requestedLimit, 25))
        let mode = (jsonString(input["mode"]) ?? "hybrid")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let exactMode = mode == "exact"
        let roleFilter = jsonString(input["role"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sessionFilter = jsonString(input["session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSessionId = jsonString(input["current_session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedScope = (jsonString(input["scope"]) ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scope: String = {
            switch requestedScope {
            case "", "auto", "current_session_first", "current_session", "all_sessions":
                return requestedScope.isEmpty ? "auto" : requestedScope
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

        let messagesDir = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        let sessionMeta = readChatHistorySessionMetadata()
        let tokens = chatSearchTokens(query)

        func scan(_ messageFiles: [URL]) -> (hits: [ChatHistorySearchHit], sessions: Set<String>) {
            var hits: [ChatHistorySearchHit] = []
            var searchedSessions: Set<String> = []
            for file in messageFiles {
                let sessionId = sessionIdForMessageFile(file)
                searchedSessions.insert(sessionId)
                guard let data = try? Data(contentsOf: file),
                      let text = String(data: data, encoding: .utf8) else {
                    continue
                }
                let meta = sessionMeta[sessionId]
                var messageIndex = 0
                for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    defer { messageIndex += 1 }
                    let trimmed = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          let lineData = trimmed.data(using: .utf8),
                          let parsed = try? JSONValue.parse(lineData),
                          case .object(let obj) = parsed else {
                        continue
                    }
                    let role = (jsonString(obj["role"]) ?? "unknown").lowercased()
                    if let roleFilter, !roleFilter.isEmpty, role != roleFilter {
                        continue
                    }
                    guard let content = jsonString(obj["content"]) ?? jsonString(obj["text"]),
                          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    let score = chatHistoryScore(
                        content: content,
                        sessionTitle: meta?.title,
                        query: query,
                        tokens: tokens,
                        exactMode: exactMode
                    )
                    guard score > 0 else { continue }
                    hits.append(ChatHistorySearchHit(
                        score: score,
                        sessionId: sessionId,
                        sessionTitle: meta?.title,
                        sessionCreatedAt: meta?.createdAt,
                        role: role,
                        timestamp: jsonString(obj["createdAt"]) ?? jsonString(obj["timestamp"]) ?? "",
                        messageId: jsonString(obj["id"]),
                        messageIndex: messageIndex,
                        preview: chatHistoryPreview(content: content, query: query, tokens: tokens)
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
        if let sessionFilter, !sessionFilter.isEmpty {
            selected = scan(try files(forSessionId: sessionFilter))
            phase = "explicit_session"
            fallbackSkipped = nil
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
                    selected = scan(chatMessageFiles(messagesDir: messagesDir))
                    phase = "all_sessions_fallback"
                    fallbackSkipped = nil
                }
            } else {
                selected = scan(chatMessageFiles(messagesDir: messagesDir))
                phase = "all_sessions_no_current"
                fallbackSkipped = nil
            }
        } else {
            selected = scan(chatMessageFiles(messagesDir: messagesDir))
            phase = "all_sessions"
            fallbackSkipped = nil
        }

        var hits = selected.hits
        let searchedSessions = selected.sessions
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.timestamp > $1.timestamp
        }
        let out = hits.prefix(limit).map { hit -> JSONValue in
            var obj: [String: JSONValue] = [
                "session_id": .string(hit.sessionId),
                "role": .string(hit.role),
                "timestamp": .string(hit.timestamp),
                "message_index": .int(Int64(hit.messageIndex)),
                "preview": .string(hit.preview),
                "score": .double(hit.score),
            ]
            if let title = hit.sessionTitle, !title.isEmpty { obj["session_title"] = .string(title) }
            if let created = hit.sessionCreatedAt, !created.isEmpty { obj["session_created_at"] = .string(created) }
            if let messageId = hit.messageId, !messageId.isEmpty { obj["message_id"] = .string(messageId) }
            return .object(obj)
        }
        var response: [String: JSONValue] = [
            "status": .string("ok"),
            "runtime": .string("swift-native"),
            "tool": .string(invokedAs),
            "source": .string("chat_history_jsonl"),
            "query": .string(query),
            "mode": .string(exactMode ? "exact" : "hybrid"),
            "scope": .string(scope),
            "phase": .string(phase),
            "searched_session_count": .int(Int64(searchedSessions.count)),
            "hit_count": .int(Int64(hits.count)),
            "hits": .array(Array(out)),
        ]
        if let currentSessionId, !currentSessionId.isEmpty {
            response["current_session_id"] = .string(currentSessionId)
        }
        if let fallbackSkipped {
            response["fallback_skipped"] = .string(fallbackSkipped)
        }
        return .object(response)
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

    private func chatMessageFiles(messagesDir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: messagesDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate > rDate
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
