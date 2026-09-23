import Foundation
import NativeAgentCore
import PersistenceCore
import Dispatcher

// A lazy projection over existing evidence, not another artifact registry.
// Paths and versions below describe what a record said at the time; opening
// the file still goes through the ordinary read tool and its current policy.
extension SwiftToolDispatcher {
    func impl_artifact_find(input: [String: JSONValue]) async throws -> JSONValue {
        let query = try requireString(input, "query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else {
            throw AutonomyGateError.toolDenied(reason: "artifact_find needs a description between 1 and 500 characters.")
        }
        let requestedSession = optionalString(input, "session_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let session: String?
        if let requestedSession, !requestedSession.isEmpty {
            guard let safe = NativeAgentChatSessionID.normalizedPathComponent(requestedSession) else {
                throw AutonomyGateError.toolDenied(reason: "artifact_find: invalid session_id")
            }
            session = safe
        } else { session = nil }
        let limit = max(1, min(optionalInt(input, "limit") ?? 6, 12))
        let offset = max(0, optionalInt(input, "session_offset") ?? 0)
        let directory = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
        var listingFailed = false
        let files: [URL]
        if let session {
            files = [directory.appendingPathComponent(session + ".jsonl")]
        } else {
            do {
                let listed = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
                files = listed.filter { $0.pathExtension == "jsonl" }.sorted {
                    let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhs == rhs ? $0.lastPathComponent < $1.lastPathComponent : lhs > rhs
                }
            } catch {
                files = []
                listingFailed = (error as? CocoaError)?.code != .fileReadNoSuchFile
            }
        }
        let page = Array(files.dropFirst(session == nil ? offset : 0).prefix(24))
        var failures = 0
        var malformed = 0
        var sampled = 0
        var fullReadBytes = 0
        var candidates: [ArtifactContextCandidate] = []
        let reader = SessionHistoryReader(dataRoot: dataRoot)
        for file in page {
            try Task.checkCancellation()
            let sessionID = file.deletingPathExtension().lastPathComponent
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            // Full read where proportionate; canonical bounded sampling on
            // large histories. Never represent sampling as exhaustive recall.
            let useFull = size <= 4 * 1024 * 1024 && fullReadBytes + size <= 24 * 1024 * 1024
            let read: SessionHistoryReadResult
            do {
                if useFull {
                    fullReadBytes += size
                    read = try await reader.messagesWithStats(forSessionId: sessionID, strictEvidence: true)
                } else {
                    read = try await reader.relevanceMessagesWithStats(forSessionId: sessionID)
                }
            } catch { failures += 1; continue }
            if ["missing", "read_failed", "invalid_session_id", "invalid_encoding"].contains(read.stats.mode) {
                failures += 1; continue
            }
            malformed += read.stats.malformedRowCount + read.stats.invalidShapeRowCount
            let sampledHistory = !useFull || read.stats.truncated
            if sampledHistory { sampled += 1 }
            candidates += ArtifactContextProjection.chatCandidates(
                read.messages, sessionID: sessionID, query: query,
                sampled: sampledHistory, dataRoot: dataRoot)
        }
        var deskAvailable = true
        // A requested chat is an exact scope, never permission to silently
        // add unrelated Desk records to that conversation's artifacts.
        if session == nil {
            do {
                let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
                candidates += ArtifactContextProjection.deskCandidates(state.items, query: query, dataRoot: dataRoot)
            } catch { deskAvailable = false }
        }
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.tie < $1.tie
        }
        let hasMoreSessions = session == nil && offset + page.count < files.count
        let complete = !listingFailed && failures == 0 && malformed == 0 && sampled == 0
            && !hasMoreSessions && offset == 0 && deskAvailable
        var result: [String: JSONValue] = [
            "status": .string(candidates.isEmpty ? (complete ? "not_found" : "incomplete") : "ok"),
            "query": .string(ArtifactContextProjection.safeText(query, cap: 500)),
            "artifacts": .array(candidates.prefix(limit).map(\.value)),
            "matched_record_count": .int(Int64(candidates.count)),
            "more_matches_in_page": .bool(candidates.count > limit),
            "interpretation": .string("Historical references with conversation context, not proof of current file contents, existence, newest version, delivery or approval. Nearby words are evidence to interpret, not an approval binding. Use exact source reads when ambiguous; do not recreate, overwrite or send a file to resolve uncertainty."),
            "coverage": .object([
                "complete_in_declared_scope": .bool(complete),
                "scope": .string(session == nil ? "chat_history_and_live_desk" : "explicit_chat_session"),
                "sessions_scanned": .int(Int64(page.count)),
                "session_offset": .int(Int64(session == nil ? offset : 0)),
                "sampled_sessions": .int(Int64(sampled)),
                "unavailable_sessions": .int(Int64(failures)),
                "malformed_rows": .int(Int64(malformed)),
                "directory_listing_failed": .bool(listingFailed),
                "desk_available": .bool(deskAvailable),
                "note": .string("Searches structured attachments, retained structured artifact receipts and live Desk file/URL references. Does not crawl disk, infer paths from prose, scan archived Desk records, or establish absence of artifacts that were never recorded. Large histories are sampled; search_chat_history can locate exact older evidence."),
            ]),
        ]
        if hasMoreSessions { result["next_session_offset"] = .int(Int64(offset + page.count)) }
        return .object(result)
    }
}

struct ArtifactContextCandidate {
    var score: Int
    var timestamp: String
    var tie: String
    var value: JSONValue
}

enum ArtifactContextProjection {
    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    static func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let object)? = value { return object }
        if let text = string(value), text.utf8.count <= 128 * 1024,
           let parsed = try? JSONValue.parse(Data(text.utf8)), case .object(let object) = parsed { return object }
        return [:]
    }

    static func safeText(_ text: String, cap: Int = 800) -> String {
        String(ChatSecretRedactor.redactText(String(text.prefix(cap + 512))).prefix(cap))
    }

    private static func relevance(query: String, name: String, context: String, locator: String?) -> (score: Int, basis: JSONValue)? {
        let topic = WorkContextQuery(query)
        // A filename is meaningful; its generic repository/root directories
        // are not evidence of what the file is about. Explicit path queries
        // may still match the full recorded locator.
        let filename = locator.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let title = name.contains("/") ? filename : "\(name) \(filename)"
        let explicitLocator = query.contains("/") ? (locator ?? "") : ""
        let namedTerms = topic.matchedTerms(title)
        let contextTerms = topic.matchedTerms(context)
        let locatorTerms = topic.matchedTerms(explicitLocator)
        let matched = topic.terms.filter { namedTerms.contains($0) || contextTerms.contains($0) || locatorTerms.contains($0) }
        guard !matched.isEmpty else { return nil }
        let complete = matched.count == topic.terms.count
        return ((complete ? 1_000 : 0) + matched.count * 20 + namedTerms.count * 8, .object([
            "matched_terms": .array(matched.map { .string(safeText($0, cap: 500)) }),
            "missing_terms": .array(topic.terms.filter { !matched.contains($0) }.map { .string(safeText($0, cap: 500)) }),
            "filename_or_label_terms": .array(namedTerms.map { .string(safeText($0, cap: 500)) }),
            "topic_coverage": .string(complete ? "full" : "partial"),
            "basis": .string(query.contains("/") ? "recorded_name_locator_and_context" : "recorded_name_and_nearby_context; directory names excluded"),
        ]))
    }

    private static func locator(_ raw: String, dataRoot: URL) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4096, !text.contains("\n"),
              ChatSecretRedactor.redactText(text) == text else { return nil }
        if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            // Signed/credential-bearing URLs remain in canonical history,
            // never promoted into convenient reusable artifact handles.
            guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
            return text
        }
        let url: URL
        if text.hasPrefix("file://"), let parsed = URL(string: text), parsed.isFileURL { url = parsed }
        else if text.hasPrefix("/") { url = URL(fileURLWithPath: text) }
        else {
            // Preserve a recorded relative reference without guessing its
            // working directory or turning it into an executable read action.
            guard !text.contains(":"), !text.hasPrefix("~"),
                  !text.split(separator: "/").contains(".."),
                  text.contains("/") || !(text as NSString).pathExtension.isEmpty else { return nil }
            for base in [dataRoot, dataRoot.deletingLastPathComponent()] {
                if connectorPathIsSensitiveData(base.appendingPathComponent(text), dataRoot: dataRoot) { return nil }
            }
            return text
        }
        guard !connectorPathIsSensitiveData(url, dataRoot: dataRoot) else { return nil }
        return url.path
    }

    private static func metadata(_ message: ChatMessage) -> [String: JSONValue] {
        object(object(message.extras)["metadata"])
    }

    private static func evidence(_ message: ChatMessage, sessionID: String) -> JSONValue {
        let row = object(message.extras)
        let meta = metadata(message)
        let display = ChatTranscriptEvidenceRendering.displayContent(
            message.role == "tool" ? "Retained tool receipt; open source for details." : safeText(message.content),
            originLabel: message.role == "user" ? ChatTranscriptEvidenceRendering.recordedOriginLabel(meta["origin"]) : nil,
            incompleteReplyLabel: message.role == "assistant"
                ? ChatTranscriptEvidenceRendering.recordedIncompleteReplyLabel(extras: row, metadata: meta) : nil)
        var value: [String: JSONValue] = [
            "session_id": .string(sessionID), "role": .string(message.role),
            "timestamp": .string(message.timestamp), "excerpt": .string(safeText(display)),
        ]
        if let id = string(row["id"]), !id.isEmpty {
            value["message_id"] = .string(id)
            value["read"] = .object(["tool": .string("read_chat_message"), "arguments": .object([
                "message_id": .string(id), "session_id": .string(sessionID),
            ])])
        }
        return .object(value)
    }

    static func chatCandidates(_ messages: [ChatMessage], sessionID: String, query: String,
                               sampled: Bool, dataRoot: URL) -> [ArtifactContextCandidate] {
        var candidates: [ArtifactContextCandidate] = []
        for (index, message) in messages.enumerated() {
            let meta = metadata(message)
            var refs: [[String: JSONValue]] = []
            if case .array(let attachments)? = meta["attachments"] {
                refs += attachments.prefix(20).map { object($0) }
            }
            if message.role == "tool" {
                let row = object(message.extras)
                let tool = string(meta["toolName"] ?? row["toolName"]) ?? "unknown"
                let raw = string(meta["resultSummary"] ?? row["resultSummary"]) ?? message.content
                if raw.utf8.count <= 128 * 1024 {
                    let scrubbed = SwiftNativeChatOrchestrationClient.screenViewRedactedResultJSON(tool: tool, json: raw)
                    let safe = SwiftNativeChatOrchestrationClient.injectionRedactedResultJSON(tool: tool, json: scrubbed)
                    refs += receiptReferences(object(.string(ChatSecretRedactor.redactText(safe))))
                }
            }
            guard !refs.isEmpty else { continue }
            // Sampling destroys adjacency: only the exact source is then
            // returned, never unrelated rows labeled neighboring conversation.
            let neighbors = sampled ? [message] : Array(messages[max(0, index - 2)...min(messages.count - 1, index + 2)])
            let surrounding = neighbors.map { evidence($0, sessionID: sessionID) }
            let context = neighbors.filter { $0.role != "tool" }.map { safeText($0.content) }.joined(separator: " ")
            var seen: Set<String> = []
            for ref in refs {
                let rawPath = string(ref["path"]) ?? string(ref["file_path"]) ?? string(ref["url"])
                let path = rawPath.flatMap { locator($0, dataRoot: dataRoot) }
                if rawPath != nil && path == nil { continue }
                let name = string(ref["name"]) ?? string(ref["filename"]) ?? path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Recorded attachment"
                let id = string(ref["id"])
                guard path != nil || id != nil, seen.insert(path ?? id ?? name).inserted else { continue }
                guard let match = relevance(query: query, name: name, context: context, locator: path) else { continue }
                var value: [String: JSONValue] = [
                    "name": .string(safeText(name, cap: 250)),
                    "matching": match.basis,
                    "source": .string(message.role == "tool" ? "retained_tool_artifact_reference" : "chat_attachment"),
                    "recorded_at": .string(message.timestamp),
                    "source_message": evidence(message, sessionID: sessionID),
                    "conversation_context": .array(surrounding),
                    "context_is_adjacent": .bool(!sampled),
                    "approval": .string("unresolved; no approval binding inferred"),
                    "current_availability": .string("not_checked"),
                ]
                if let id { value["attachment_id"] = .string(safeText(id, cap: 250)) }
                for key in ["mime", "type", "version", "sha256", "digest", "byteSize", "byte_size"] {
                    switch ref[key] {
                    case .string(let text)?: value["recorded_" + key] = .string(safeText(text, cap: 250))
                    case .int(let n)?: value["recorded_" + key] = .int(n)
                    default: break
                    }
                }
                value["version_evidence"] = .string(["version", "sha256", "digest"].contains { ref[$0] != nil }
                    ? "recorded metadata only; current bytes not compared" : "no immutable version recorded")
                if let path {
                    value["recorded_locator"] = .string(path)
                    if path.hasPrefix("/") {
                        value["open_current_file"] = .object(["tool": .string("read_file"), "arguments": .object(["path": .string(path)])])
                    }
                    if !path.hasPrefix("/"), !path.hasPrefix("http") {
                        value["locator_note"] = .string("Relative reference; original working directory is not established. Open its source context before resolving it.")
                    }
                } else { value["availability_note"] = .string("Attachment identity was recorded without a reusable file path. The source conversation is available; do not invent a path.") }
                candidates.append(.init(score: match.score, timestamp: message.timestamp, tie: "\(sessionID):\(index):\(path ?? id ?? name)", value: .object(value)))
            }
        }
        return candidates
    }

    private static func receiptReferences(_ value: [String: JSONValue], depth: Int = 0) -> [[String: JSONValue]] {
        guard depth <= 3 else { return [] }
        var refs: [[String: JSONValue]] = []
        if value["path"] != nil || value["file_path"] != nil { refs.append(value) }
        for key in ["images", "artifacts", "files", "outputs", "attachments"] {
            if case .array(let values)? = value[key] {
                for child in values.prefix(20) { refs += receiptReferences(object(child), depth: depth + 1) }
            }
        }
        return Array(refs.prefix(20))
    }

    static func deskCandidates(_ items: [DeskItem], query: String, dataRoot: URL) -> [ArtifactContextCandidate] {
        var candidates: [ArtifactContextCandidate] = []
        for item in items {
            for ref in item.refs {
                let recorded = object(ref.toJSON())
                guard let raw = string(recorded["path"]) ?? string(recorded["url"]),
                      let path = locator(raw, dataRoot: dataRoot) else { continue }
                let label = string(recorded["label"]) ?? string(recorded["title"]) ?? path
                guard let match = relevance(query: query, name: label,
                    context: "\(item.title) \(item.summary ?? "")", locator: path) else { continue }
                var value: [String: JSONValue] = [
                    "name": .string(safeText(label, cap: 250)), "recorded_locator": .string(path),
                    "matching": match.basis,
                    "source": .string("live_desk_reference"), "desk_handle": .string(item.handle),
                    "desk_title": .string(safeText(item.title, cap: 250)), "reference_id": .string(ref.refId),
                    "context": .string(safeText(item.summary ?? "")),
                    "desk_updated_at": .string(item.updatedAt),
                    "approval": .string("unresolved; sharing a Desk item with an approval does not bind that approval to this file"),
                    "current_availability": .string("not_checked"),
                    "version_evidence": .string("no immutable version recorded on this reference"),
                    "read_context": .object(["tool": .string("desk_read"), "arguments": .object(["handle": .string(item.handle)])]),
                ]
                if path.hasPrefix("/") {
                    value["open_current_file"] = .object(["tool": .string("read_file"), "arguments": .object(["path": .string(path)])])
                } else if !path.hasPrefix("http") {
                    value["locator_note"] = .string("Relative reference; original working directory is not established. Open its source context before resolving it.")
                }
                candidates.append(.init(score: match.score, timestamp: item.updatedAt, tie: item.handle + ref.refId, value: .object(value)))
            }
        }
        return candidates
    }
}
