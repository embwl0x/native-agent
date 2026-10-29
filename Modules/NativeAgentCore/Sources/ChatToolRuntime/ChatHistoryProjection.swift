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
// Blueprint: | `ChatHistoryProjection.swift` | Persisted row and explicit receipt projection; ordinary turn recall never injects tool metadata |

/// One transcript line as history search reads it; `ChatHistoryIndex` keeps it by the line's bytes.
struct ChatHistorySearchRow: Sendable {
    var valid: Bool
    var identity: String
    /// As stored: continuity excerpts match it exactly, the scan lowercases it.
    var role: String?
    var runId: String?
    var messageId: String?
    /// `createdAt`, else `timestamp`.
    var timestamp: String?
    /// A conversation row's stored words (`content`, else `text`).
    var rawContent: String?
    var content: String
    var searchable: String
    var folded: String
    var instant: Date?
    var author: String?
    var route: String?
    var peer: String?
    var tool: String?
    var displayPrefix: String
    /// As the canonical transcript reader sees the line: 0 not JSON, 1 JSON it rejects (not an object, or no string role and words), 2 a message.
    var shape = 0
    /// The writer marked the row machinery (card copy, a failure row, a notice, a compaction summary): `CognitiveMechanicalRowKind.marksMechanicalRow`.
    var mechanical = false

    var isToolRow: Bool { role?.lowercased() == "tool" }
}

extension SwiftToolDispatcher {
    /// One parse yields a row and its explicit receipt lane; bump ChatHistoryIndex.projector when projection semantics change.
    static func chatHistorySearchRow(_ line: String) -> (row: ChatHistorySearchRow, receipt: ChatHistorySearchRow?) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = SessionHistoryReader.decodeRow(line)
        guard case .object(let obj)? = decoded.value else {
            return (ChatHistorySearchRow(valid: false, identity: trimmed, content: "", searchable: "", folded: "",
                displayPrefix: "", shape: decoded.value == nil ? 0 : 1), nil)
        }
        func string(_ value: JSONValue?) -> String? { if case .string(let text)? = value { return text }; return nil }
        let role = (decoded.role ?? "unknown").lowercased()
        let words = role == "tool" ? nil : decoded.content
        let bridgeRouted = ChatTranscriptBoilerplate.isBridgeRouted(rowMetadata: obj["metadata"])
        let timestamp = decoded.timestamp
        let instant = timestamp.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst)
        let metadata = persistedHistoryMetadata(row: obj)
        let name = string(metadata["toolName"] ?? obj["toolName"])
        func project(_ text: String) -> ChatHistorySearchRow {
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
            // Only persisted bridge provenance strips routing boilerplate; quoted words stay searchable.
            let searchable = bridgeRouted ? DelegatedReplyEnvelope(content).searchText : content
            return ChatHistorySearchRow(
                valid: true,
                identity: string(obj["id"]) ?? trimmed, role: decoded.role, runId: string(obj["runId"]),
                messageId: string(obj["id"]), timestamp: timestamp, rawContent: words,
                content: content, searchable: searchable, folded: searchable.lowercased(),
                instant: role == "tool" ? nil : instant,
                author: persistedHistoryAuthor(role: role, row: obj, metadata: metadata), route: persistedHistoryRoute(row: obj, metadata: metadata),
                peer: role != "tool" ? persistedHistoryPeer(role: role, row: obj, metadata: metadata) : nil,
                tool: name.flatMap { $0.isEmpty ? nil : ToolNameAliases.shown($0, inputJSON: string(metadata["inputJSON"])).name },
                displayPrefix: chatHistoryDisplayEvidence("", role: role, row: obj, decodedMetadata: metadata),
                shape: decoded.role != nil && decoded.content != nil ? 2 : 1,
                mechanical: CognitiveMechanicalRowKind.marksMechanicalRow(metadata))
        }
        guard role == "tool" else { return (project(words ?? ""), nil) }
        // Receipt metadata is an explicit evidence lane, never conversation recall.
        var receipt = project(persistedToolReceiptText(row: obj, metadata: metadata))
        receipt.instant = instant
        receipt.peer = persistedHistoryPeer(role: role, row: obj, metadata: metadata)
        return (project(""), receipt)
    }

    static func persistedHistoryMetadata(row: [String: JSONValue]) -> [String: JSONValue] {
        switch row["metadata"] {
        case .object(let object)?: return object
        case .string(let text)?:
            if let value = try? JSONValue.parse(Data(text.utf8)), case .object(let object) = value { return object }
            return [:]
        default: return [:]
        }
    }

    /// A narrow projection owned by explicit history tools. Do not teach the ordinary history reader to inject tool metadata into every new turn.
    static func persistedToolReceiptText(row: [String: JSONValue], metadata: [String: JSONValue]) -> String {
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
        // Preserve a clipped JSON string as a string. Parsing a surviving prefix into a fresh success envelope would invent missing evidence. An app call of a folded action is redacted as the tool it ran.
        let ran = ToolNameAliases.shown(toolName, inputJSON: serialized(value("inputJSON"))).name
        receipt["resultSummary"] = .string(bounded(
            ChatToolJSONRedaction.redactedResultJSON(tool: ran, json: result), maximum: 10_000
        ))
        if let body = serialized(value("resultBody")) {
            receipt["resultBody"] = .string(bounded(
                ChatToolJSONRedaction.redactedResultJSON(tool: ran, json: body), maximum: 10_000
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
            receipt["receiptEvidence"] = .object(ChatTranscriptEvidenceRendering.restoringReceiptBoundaries(evidence))
        }
        receipt["evidence_type"] = .string("persisted_tool_receipt")
        receipt["receipt_projection_truncated"] = .bool(clipped)
        return (try? JSONValue.object(receipt).serialize(pretty: false)) ?? "[unreadable persisted tool receipt]"
    }

    /// Search relevance still uses the original content. Recorded provenance is display-only, shared with ordinary history and compaction, and never grants a bridge request or an interrupted answer additional authority.
    package static func chatHistoryDisplayEvidence(
        _ content: String, role: String, row: [String: JSONValue], decodedMetadata: [String: JSONValue]? = nil
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
                ? ChatTranscriptEvidenceRendering.recordedOriginLabel(row, role: role, metadata: decodedMetadata) : nil,
            incompleteReplyLabel: role == "assistant"
                ? ChatTranscriptEvidenceRendering.recordedIncompleteReplyLabel(extras: row, metadata: metadata) : nil
        )
    }

    /// Receipt sources retain their own evidence; speech uses the shared row stamp.
    package static func persistedHistoryPeer(role: String, row: [String: JSONValue], metadata: [String: JSONValue]? = nil) -> String? {
        let principals = role.lowercased() == "tool"
            ? toolReceiptSources(row: row, metadata: metadata ?? persistedHistoryMetadata(row: row))
            : ContactThread.Line(row, role: role.lowercased(), metadata: metadata).speakers
        var seen: Set<String> = []
        let unique = principals.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: "\n")
    }

    /// The sources a tool receipt's own result labels, or its routed contact.
    private static func toolReceiptSources(row: [String: JSONValue], metadata: [String: JSONValue]) -> [String] {
        let tool = (metadata["toolName"] ?? row["toolName"]
            ?? metadata["name"] ?? row["name"])?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? ""
        let storedInput = metadata["inputJSON"] ?? row["inputJSON"]
        let input: [String: JSONValue]
        if case .string(let text)? = storedInput,
           let parsed = try? JSONValue.parse(Data(text.utf8)) {
            input = parsed.objectValue ?? [:]
        } else {
            input = (storedInput?.objectValue ?? [:])
        }
        for key in ["receiptEvidence", "resultSummary", "resultBody", "content", "text"] {
            let stored = metadata[key] ?? row[key]
            let result: JSONValue?
            if case .string(let text)? = stored { result = try? JSONValue.parse(Data(text.utf8)) }
            else { result = stored }
            if let result {
                let peers = PeerDataTaintDispatcher.remoteProvenances(in: result)
                if !peers.isEmpty { return peers }
            }
        }
        if let peer = PeerDataTaintDispatcher.routedContact(tool: tool, input: input) { return [peer] }
        // Clipped routing cannot attest a trusted contact. Keep peer receipts subject to the approval floor when that identity is lost.
        if ["agent_message", "agent_read"].contains(ToolNameAliases.ranTool(tool, input: input)) {
            return ["peer:unknown"]
        }
        if ["read_page", "browser.chrome_snapshot", "browser.read_text", "browser.read_links"]
            .contains(ToolNameAliases.ranTool(tool, input: input)) { return ["web content"] }
        return []
    }

    /// A history row's evidence fields, retaining the speakers' attribution.
    package static func historyEvidence(_ peer: String?, words: String, dataRoot: URL) -> [String: JSONValue] {
        let principals = (peer ?? "").split(separator: "\n").map(String.init)
        guard let speaker = principals.first else { return [:] }
        let attested = principals.map { PeerTrust.principal($0, dataRoot: dataRoot) }
        var fields: [String: JSONValue] = ["agent": .string(speaker),
            "untrusted_remote_data": .bool(!attested.allSatisfy(PeerDataTaint.ownerTrusts) && !words.isEmpty)]
        if attested[0] != speaker { fields["agent_id"] = .string(attested[0]) }
        if principals.count > 1 { fields["steered_by"] = .array(principals.dropFirst().map(JSONValue.string)) }
        return fields
    }

    private static func persistedHistoryRoute(row: [String: JSONValue], metadata: [String: JSONValue]) -> String? {
        let origin = (metadata["origin"]?.objectValue ?? [:])
        let source = row["source"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
        return origin["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
            ?? (source?.hasSuffix("-bridge") == true ? source : nil)
            ?? TurnEnvelope.fromPersistedMetadata(metadata["envelope"])?.surface
            ?? source
    }

    /// The author of the owner's own messages on their own doors: a role, never a name.
    package static let ownerAuthor = "owner"

    package static func persistedHistoryAuthor(role: String, row: [String: JSONValue], metadata: [String: JSONValue]? = nil) -> String? {
        guard role == "user" else { return nil }
        let metadata = metadata ?? persistedHistoryMetadata(row: row)
        let origin = (metadata["origin"]?.objectValue ?? [:])
        let envelope = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])
        let route = (persistedHistoryRoute(row: row, metadata: metadata) ?? "").lowercased()
        if route == "bridge" || route.hasSuffix("-bridge") || envelope?.agent != nil {
            if origin["authored"] == .string("human") { return "human via bridge" }
            return origin["agent"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? envelope?.agent ?? "unknown agent"
        }
        if metadata["mechanicalKind"] != nil { return "automated" }
        if ["app", "chat", "ios"].contains(route), origin.isEmpty { return ownerAuthor }
        return envelope?.verifiedUserId ?? "unknown"
    }

    package static func consumePersistedHistoryEvidence(_ value: JSONValue) {
        switch value {
        case .object(let fields):
            // Reopening retained evidence marks its speaker, never its recorded steering.
            if case .string(let peer)? = fields["agent"],
               fields["untrusted_remote_data"] == .bool(true) || fields["steered_by"] != nil {
                let line = (fields["preview"] ?? fields["excerpt"] ?? fields["text"])?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? ""
                ContactThread.consume(.init(text: line, stamp: .init(source: peer, steeredBy: [], contact: true)),
                    mark: { PeerDataTaint.markConsumed(peer: $0, line: $1) })
            }
            for child in fields.values { consumePersistedHistoryEvidence(child) }
        case .array(let values):
            for child in values { consumePersistedHistoryEvidence(child) }
        default: break
        }
    }

    /// Only the explicitly invoked history tool asks for this material. No background digest, cross-session scan, or work reminder is injected.
    static func continuityNeighbors(
        rows: [ChatHistorySearchRow], startIndex: Int, index: Int, roleFilter: String?, authorFilter: String?, sessionId: String,
        excludingRunID: String?, dataRoot: URL
    ) -> [JSONValue] {
        return rows.enumerated().compactMap { localIndex, cached in
            let offset = startIndex + localIndex
            guard offset != index,
                  let role = cached.role,
                  ["user", "assistant"].contains(role),
                  roleFilter == nil || roleFilter == role,
                  let content = cached.rawContent else { return nil }
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
            result.merge(Self.historyEvidence(cached.peer, words: display, dataRoot: dataRoot)) { _, new in new }
            if let excludingRunID, cached.runId == excludingRunID { return nil }
            result["timestamp"] = cached.timestamp.map(JSONValue.string)
            if let messageId = cached.messageId, !messageId.isEmpty {
                result["message_id"] = .string(messageId)
                result["read_locator"] = .object([
                    "tool": .string("read_chat_message"),
                    "arguments": .object(["session_id": .string(sessionId), "message_id": .string(messageId)])
                ])
            }
            return .object(result)
        }
    }
}
