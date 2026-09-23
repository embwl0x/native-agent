import Foundation
import NativeAgentCore
import PersistenceCore

/// Read-time query shaping only, never a semantic decision or another memory
/// index. Keep a one-letter subject such as X while dropping conversational
/// scaffolding that would otherwise match nearly every transcript.
struct WorkContextQuery: Sendable {
    let terms: [String]
    private let includesLocator: Bool

    init(_ query: String) {
        let filler: Set<String> = [
            "a", "an", "the", "and", "or", "to", "of", "for", "with", "on", "in", "at", "from",
            "it", "its", "this", "that", "those", "these", "our", "my", "your", "we", "i", "me",
            "you", "us", "let", "lets", "s", "up", "back", "again", "please", "can", "could",
            "would", "should", "do", "did", "have", "has", "had", "was", "were", "been", "is",
            "are", "be", "about", "what", "where", "when", "how", "last", "latest", "previous",
            "continue", "continuing", "resume", "resuming", "pick", "remember", "recall", "work",
            "working", "worked", "project", "doing", "left", "off", "get", "bring", "find",
            "open", "show", "discussed"
        ]
        includesLocator = query.components(separatedBy: .whitespacesAndNewlines).contains(where: Self.isLocatorToken)
        var seen: Set<String> = []
        terms = Self.words(query).filter { !filler.contains($0) && seen.insert($0).inserted }
    }

    var text: String { terms.joined(separator: " ") }

    /// Match a topic in a bounded passage, not scattered words across an
    /// entire status report. Incidental repository paths are not prose about
    /// the project. An explicitly requested locator remains searchable.
    func matchedTerms(_ content: String) -> [String] {
        let searchable = includesLocator ? content : content.components(separatedBy: .whitespacesAndNewlines)
            .filter { !Self.isLocatorToken($0) }.joined(separator: " ")
        let words = Self.words(searchable, expandCompounds: true)
        guard !terms.isEmpty else { return [] }
        var counts: [Int: Int] = [:]
        var window = Array(repeating: [Int](), count: 64)
        var cursor = 0
        var best: Set<Int> = []
        for word in words {
            let matches = terms.indices.filter { terms[$0] == word || Self.simplePluralPair(terms[$0], word) }
            for index in window[cursor] {
                if counts[index] == 1 { counts.removeValue(forKey: index) }
                else { counts[index, default: 0] -= 1 }
            }
            window[cursor] = matches
            cursor = (cursor + 1) % window.count
            for index in matches { counts[index, default: 0] += 1 }
            if counts.count > best.count { best = Set(counts.keys) }
            if best.count == terms.count { break }
        }
        return terms.indices.filter { best.contains($0) }.map { terms[$0] }
    }

    func score(_ content: String) -> Int {
        let matches = matchedTerms(content).count
        // Preserve the existing partial-topic allowance for natural phrasing.
        let required = max(1, Int(ceil(Double(terms.count) * 0.6)))
        guard !terms.isEmpty, matches >= required else { return 0 }
        return matches
    }

    private static func isLocatorToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'()[]{}<>,;"))
        guard token.contains("/") else { return false }
        if token.hasPrefix("/") || token.hasPrefix("~/") || token.hasPrefix("./")
            || token.hasPrefix("../") || token.contains("://") { return true }
        let parts = token.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first, let last = parts.last, parts.count >= 2 else { return false }
        // Relative file references have a filename or a recognizable directory
        // root. Ordinary browser/research and Mac/Telegram topic pairs remain
        // prose, rather than being mistaken for filesystem paths.
        let roots: Set<String> = ["src", "sources", "modules", "docs", "data", "research", "script",
                                  "scripts", "tests", "users", "volumes", "applications", "library",
                                  "projects", "tmp", "var"]
        return roots.contains(first.lowercased()) || !(String(last) as NSString).pathExtension.isEmpty
    }

    // Local lexical equivalence, not a change to global memory matching.
    // Retain whole-word boundaries (especially X); allow bot/bots and the
    // existing conservative longer-word normalization on both sides.
    private static func simplePluralPair(_ lhs: String, _ rhs: String) -> Bool {
        let shorter = lhs.count < rhs.count ? lhs : rhs
        let longer = lhs.count < rhs.count ? rhs : lhs
        return shorter.count >= 3 && !shorter.hasSuffix("s")
            && shorter.utf8.allSatisfy { $0 >= 97 && $0 <= 122 }
            && longer == shorter + "s"
    }

    private static let compoundBoundary = try? NSRegularExpression(pattern: "([a-z0-9])([A-Z])")

    private static func words(_ text: String, expandCompounds: Bool = false) -> [String] {
        let chunks = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return chunks.flatMap { chunk -> [String] in
            var spellings = [chunk]
            if expandCompounds, chunk.rangeOfCharacter(from: .uppercaseLetters) != nil,
               let boundary = compoundBoundary {
                let expanded = boundary.stringByReplacingMatches(in: chunk,
                    range: NSRange(chunk.startIndex..., in: chunk), withTemplate: "$1 $2")
                if expanded != chunk { spellings += expanded.components(separatedBy: " ") }
            }
            return spellings.map {
                RecallLexicalNormalization.term($0.folding(options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")))
            }
        }
    }
}

extension SwiftToolDispatcher {
    /// One lazy read brings current work and supporting conversation together.
    /// Desk/history remain the owners; no execution, memory write or replay.
    func impl_work_context(input: [String: JSONValue]) async throws -> JSONValue {
        let rawQuery = try requireString(input, "query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuery.isEmpty, rawQuery.count <= 400 else {
            throw AutonomyGateError.toolDenied(reason: "work_context: give a work topic in 1–400 characters")
        }
        let query = WorkContextQuery(rawQuery)
        guard !query.terms.isEmpty else {
            return .object([
                "status": .string("needs_topic"),
                "message": .string("Name the work to pick up, for example browser replies or the approved mockup."),
                "query": .string(rawQuery),
            ])
        }
        let limit = max(1, min(optionalInt(input, "limit") ?? 3, 4))
        let deskOffset = max(0, min(optionalInt(input, "desk_offset") ?? 0, 1_000_000))
        let historyOffset = max(0, min(optionalInt(input, "history_offset") ?? 0, 1_000_000))
        var continuation = input.filter { ["query", "session_id", "limit"].contains($0.key) && $0.value != .null }
        continuation["query"] = .string(rawQuery)
        continuation["limit"] = .int(Int64(limit))
        continuation["desk_offset"] = .int(Int64(deskOffset))
        continuation["history_offset"] = .int(Int64(historyOffset))
        var historyInput: [String: JSONValue] = [
            "query": .string(query.text), "scope": .string("all_sessions"),
            "mode": .string("continuity"), "sort": .string("newest"), "limit": .int(Int64(limit)),
            "offset": .int(Int64(historyOffset))
        ]
        let requestedSession: String?
        switch input["session_id"] {
        case .string(let value)?: requestedSession = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case nil, .null?: requestedSession = nil
        default: throw AutonomyGateError.toolDenied(reason: "work_context: session_id must be a string")
        }
        if let session = requestedSession, !session.isEmpty {
            // Validate before either owner read; an invalid scope must not
            // silently fall back to another session or a global search.
            guard NativeAgentChatSessionID.normalizedPathComponent(session) != nil else {
                throw AutonomyGateError.toolDenied(reason: "work_context: invalid session_id")
            }
            historyInput["session_id"] = .string(session)
        }

        var deskResult: JSONValue
        var historyResult: JSONValue
        var partial = false
        do {
            let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
            let sequencing = DeskSequencing.compute(state)
            let matches = state.items.compactMap { item -> (item: DeskItem, score: Int)? in
                let searchable = [item.title, item.project, item.summary ?? ""]
                    + item.notes.suffix(3).map(\.text)
                let coverage = query.score(searchable.joined(separator: " "))
                guard coverage > 0 else { return nil }
                let titleMatches = query.matchedTerms(item.title).count
                return (item, coverage * 10 + titleMatches * 2)
            }.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.item.status.isTerminal != $1.item.status.isTerminal { return !$0.item.status.isTerminal }
                if $0.item.updatedAt != $1.item.updatedAt { return $0.item.updatedAt > $1.item.updatedAt }
                return $0.item.handle < $1.item.handle
            }
            deskResult = .object([
                "status": .string("ok"), "source": .string("canonical_current_desk"),
                "as_of": .string(state.generatedTs),
                "matched_count": .int(Int64(matches.count)),
                "has_more": .bool(deskOffset + limit < matches.count),
                "offset": .int(Int64(deskOffset)),
                "items": .array(matches.dropFirst(deskOffset).prefix(limit).map {
                    Self.workContextDeskItem($0.item, state: state, plan: sequencing.byHandle[$0.item.handle])
                }),
                "meaning": .string("Current recorded Desk state. Notes and receipts are attributed records, not fresh external verification."),
            ])
            if deskOffset + limit < matches.count, case .object(var lane) = deskResult {
                var next = continuation; next["desk_offset"] = .int(Int64(deskOffset + limit))
                lane["next_read"] = Self.workContextRead("work_context", next)
                deskResult = .object(lane)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            partial = true
            deskResult = .object([
                "status": .string("unavailable"), "source": .string("canonical_current_desk"),
                "message": .string(String(String(describing: error).prefix(600))),
                "next_read": Self.workContextRead("desk_read", [:])
            ])
        }
        do {
            let result = try await impl_search_chat_history(
                input: historyInput, invokedAs: "search_chat_history",
                workContextQuery: query,
                excludingRunID: ChatTurnExecution.current?.historyRunID
            )
            if case .object(let result) = result {
                var lane: [String: JSONValue] = [
                    "status": .string("ok"), "source": .string("canonical_chat_history"),
                    "meaning": .string("Historical excerpts balanced across work turns and the newest matching context. Recorded tool activity helps ranking; it does not establish success or authority. Excerpts may contain proposals, superseded decisions or claims, not current-state verification or automatically the last agreement."),
                    "excerpts": result["hits"] ?? .array([]),
                ]
                for key in ["coverage", "coverage_note", "searched_session_count", "hit_count", "has_more", "selection_policy"] {
                    lane[key] = result[key]
                }
                if case .object(let coverage)? = result["coverage"], coverage["complete"] != .bool(true) {
                    partial = true
                    lane["status"] = .string("partial")
                }
                if result["has_more"] == .bool(true) {
                    var next = continuation
                    let returned = optionalInt(result, "returned_count") ?? 0
                    if returned > 0 {
                        next["history_offset"] = .int(Int64(historyOffset + returned))
                        lane["next_read"] = Self.workContextRead("work_context", next)
                    }
                }
                historyResult = .object(lane)
            } else {
                partial = true
                historyResult = .object(["status": .string("unavailable"), "message": .string("History owner returned an unexpected result.")])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            partial = true
            historyResult = .object([
                "status": .string("unavailable"),
                "message": .string(String(String(describing: error).prefix(600))),
                "next_read": Self.workContextRead("search_chat_history", historyInput)
            ])
        }
        return .object([
            "status": .string(partial ? "partial" : "ok"),
            "query": .string(rawQuery), "matched_topic": .string(query.text),
            "request": .object(continuation),
            "current_work": deskResult, "supporting_history": historyResult,
            "matching_policy": .string("Whole topic words within 64 words; at least 60 percent topic coverage. Incidental paths do not establish a topic match unless the query asks for a path."),
            "coverage": .string("Bounded lexical recall of live Desk titles, projects, summaries and latest notes, plus saved chat message content. Memory, archived Desk records, files and external systems were not searched. No matches do not establish absence."),
            "next_step": .string("Use the current record and dated excerpts to orient; open their exact read locators where agreement, completion or authority needs confirmation. Nothing was resumed or repeated."),
        ])
    }

    private static func workContextRead(_ tool: String, _ arguments: [String: JSONValue]) -> JSONValue {
        .object(["tool": .string(tool), "arguments": .object(arguments)])
    }

    static func workContextDeskItem(_ item: DeskItem, state: DeskState, plan: DeskSequencing.ItemPlan?) -> JSONValue {
        var out: [String: JSONValue] = [
            "handle": .string(item.handle), "title": .string(String(item.title.prefix(300))),
            "project": .string(String(item.project.prefix(200))),
            "status": .string(item.status.rawValue), "updated_at": .string(item.updatedAt),
            "is_open": .bool(!item.status.isTerminal),
            "read_locator": workContextRead("desk_read", ["handle": .string(item.handle)]),
            "latest_recorded_notes": .array(item.notes.suffix(3).map {
                .object(["timestamp": .string($0.ts), "excerpt": .string(String($0.text.prefix(600))),
                         "truncated": .bool($0.text.count > 600)])
            }),
            "linked_evidence": .array(item.liveRefs(limit: 5).map {
                boundedWorkContextValue($0.toJSON())
            }),
            "additional_notes": .bool(item.notes.count > 3),
            "additional_links": .bool(item.refs.count > 5),
        ]
        for (key, value) in ["summary": item.summary, "blocked_reason": item.blockedReason,
                             "waiting_on": item.waitingOn, "defer_until": item.deferUntil] {
            if let value { out[key] = boundedWorkContextValue(.string(value)) }
        }
        if let progress = item.progress { out["recorded_progress"] = boundedWorkContextValue(progress.toJSON()) }
        if let parent = item.parent { out["parent_read"] = workContextRead("desk_read", ["handle": .string(parent)]) }
        if let plan {
            out["sequencing"] = .object([
                "ready_in_desk": .bool(plan.isReady), "deferred": .bool(plan.isDeferred),
                "dependency_cycle": .bool(plan.blockedByCycle),
                "blocking_items": .array(plan.effectiveBlockers.prefix(5).map {
                    workContextRead("desk_read", ["handle": .string($0)])
                }),
                "additional_blockers": .bool(plan.effectiveBlockers.count > 5),
                "meaning": .string("Desk dependency readiness only; does not authorize execution or prove external prerequisites.")
            ])
        }
        let children = state.children(of: item.handle)
        out["children"] = .array(children.prefix(5).map {
            .object(["title": .string(String($0.title.prefix(300))), "status": .string($0.status.rawValue),
                     "read_locator": workContextRead("desk_read", ["handle": .string($0.handle)])])
        })
        out["additional_children"] = .bool(children.count > 5)
        if let attempt = item.workAttempts.last {
            out["last_recorded_attempt"] = boundedWorkContextValue(attempt.toJSON())
        }
        if let reservation = item.pursuit?.reservations.last {
            out["last_recorded_work_session"] = boundedWorkContextValue(reservation.toJSON())
        }
        return .object(out)
    }

    /// Preserve structured evidence, visibly clip large free text. Full records
    /// remain at the exact Desk locator; this projection never reads files.
    static func boundedWorkContextValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(text.count > 800 ? String(text.prefix(800)) + " … [truncated; open Desk record]" : text)
        case .array(let values):
            var result = values.prefix(8).map(boundedWorkContextValue)
            if values.count > 8 { result.append(.string("[\(values.count - 8) more entries; open Desk record]")) }
            return .array(result)
        case .object(let fields): return .object(fields.mapValues(boundedWorkContextValue))
        default: return value
        }
    }
}
