import AgentWorkspace
import ApprovalInbox
import Transcripts
import Foundation
import Observation
import ImageIO
import UniformTypeIdentifiers
@_exported import NativeAgentShared
import PersistenceCore
import ChatTurnRuntime
import ChatTurnContracts
import ChatSessionWork
// Blueprint: | `ChatModels.swift` | `ChatMessage`: `ChatMessageMetadata`, `CodingKeys`; decode-only inline cards travel with loaded message revisions and never re-encode onto transcript wire; Mac ImageIO generation fills Shared's optional attachment preview bytes with a 720px display decode; transport copies can omit previews before rejecting history; concrete Markdown export and clipboard formatting |

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var sessionId: String? = nil
    // Missing canonical fields do not discard the transcript.
    public var role: String = "assistant"
    public var content: String = ""
    public var createdAt: String = NativeTimestampFormat.plainZulu(Date())
    public var runId: String? = nil
    public var source: String? = nil
    public var metadata: ChatMessageMetadata? = nil
    /// Presentation only; travels with the transcript revision, never on its wire.
    public var inlineCards: [TranscriptReadout.Card] = []
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, role, content, createdAt, runId, source, metadata
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(sessionId); hasher.combine(role)
        hasher.combine(content); hasher.combine(createdAt); hasher.combine(runId)
        hasher.combine(source); hasher.combine(metadata)
    }

    public init(
        id: String = UUID().uuidString,
        sessionId: String? = nil,
        role: String = "assistant",
        content: String = "",
        createdAt: String = NativeTimestampFormat.plainZulu(Date()),
        runId: String? = nil,
        source: String? = nil,
        metadata: ChatMessageMetadata? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.runId = runId
        self.source = source
        self.metadata = metadata
    }

    /// One transcript row, read straight from its parsed object (the
    /// transcript reader's `extras`). A message missing role/content/createdAt
    /// must not fail the transcript and blank the chat surface, and a malformed
    /// advisory sibling must not discard a valid metadata.origin trust signal:
    /// each field degrades independently to its default.
    public init(row o: [String: JSONValue]) {
        self.id = o["id"]?.stringValue ?? UUID().uuidString
        self.sessionId = o["sessionId"]?.stringValue
        self.content = o["content"]?.stringValue ?? ""
        self.createdAt = o["createdAt"]?.stringValue ?? NativeTimestampFormat.plainZulu(Date())
        self.runId = o["runId"]?.stringValue
        self.source = o["source"]?.stringValue

        // Missing/null metadata is the normal historical shape. A PRESENT
        // value of the wrong JSON type is different: silently turning it
        // into nil would make a user/source=app row look human even though its
        // provenance envelope was unreadable. Preserve that distinction with
        // the same closed, non-rendered sentinel used for malformed `origin`.
        switch o["metadata"] {
        case nil, .null?:
            self.metadata = nil
        case .object(let fields)?:
            self.metadata = ChatMessageMetadata(fields: fields)
        default:
            var unreadable = ChatMessageMetadata()
            unreadable.origin = ChatMessageOriginMetadata(surface: "unreadable")
            self.metadata = unreadable
        }

        let decodedRole = o["role"]?.stringValue
        let normalizedRole = decodedRole?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if self.metadata?.origin != nil, normalizedRole != "user" {
            // Canonical writers put origin only on user rows. A contradictory
            // or unreadable role must not suppress the warning and attribute
            // the row to Agent, so fail closed toward the provenance-bearing
            // user presentation.
            self.role = "user"
        } else {
            self.role = decodedRole ?? "assistant"
        }
    }

    /// The tolerant canonical row contract for a Codable container. Encodable stays synthesized.
    public init(from decoder: Decoder) throws {
        guard case .object(let o) = try JSONValue(from: decoder) else {
            throw DecodingError.typeMismatch(
                ChatMessage.self,
                .init(codingPath: decoder.codingPath, debugDescription: "A chat message is a JSON object.")
            )
        }
        self.init(row: o)
    }
}

extension ChatMessage {
    /// A wake input she wrote to herself (what changed, what she carries):
    /// hers, recorded for her, never the person's words. Her acts on the
    /// person's behalf (a draft she sends for him) are not this.
    public var isHerOwnTurnInput: Bool {
        role == "user" && metadata?.origin?.agent == "self" && metadata?.origin?.authored == "agent"
            && metadata?.origin?.surface == ResidentWake.session
    }
}

extension ChatMessageMetadata {
    /// Shared transcript vocabulary for an approval awaiting a human decision.
    /// Producers must mint this value and transcript grouping/rendering must
    /// consume it through `isPendingApproval`; a literal drift must never hide
    /// an actionable card behind a collapsed tool summary.
    public static let approvalPendingKind = ChatTranscriptToolMessageKind.approvalPending

    public var isPendingApproval: Bool {
        kind == Self.approvalPendingKind
    }
    /// In-memory failure metadata: `error` enables Retry; `userRowPersisted` prevents suppressing an unsaved user message.
    /// Retry guards are excluded from CodingKeys and never written to the wire.
    public static func syntheticError(
        _ message: String,
        userRowPersisted: Bool = true,
        inputHadAttachments: Bool = false
    ) -> ChatMessageMetadata {
        var metadata = ChatMessageMetadata()
        metadata.error = message
        metadata.syntheticUserRowPersisted = userRowPersisted
        metadata.syntheticInputHadAttachments = inputHadAttachments
        return metadata
    }

    private static func _capString(_ s: String?, _ limit: Int) -> String? {
        guard let s, s.count > limit else { return s }
        return String(s.prefix(limit)) + "\n…(truncated)"
    }

    /// Wrong-typed advisory fields read as absent without discarding the row or its authority-bearing origin.
    /// Where both key spellings exist, snake_case wins; cap displayed strings to bound rendering and memory.
    public init(fields o: [String: JSONValue]) {
        self.init()
        model = o["model"]?.stringValue
        turnTraceId = o["turnTraceId"]?.stringValue
        requestedModel = o["requestedModel"]?.stringValue
        reasoningEffort = o["reasoningEffort"]?.stringValue
        fileAccessMode = o["fileAccessMode"]?.stringValue
        codexSandbox = o["codexSandbox"]?.stringValue
        error = o["error"]?.stringValue
        providerRefusal = o["provider_refusal"]?.boolValue
        providerRefusalDraft = o["provider_refusal_draft"]?.boolValue
        partial = o["partial"]?.boolValue
        cancelled = o["cancelled"]?.boolValue
        completionState = o["completionState"]?.stringValue
        kind = o["kind"]?.stringValue
        toolName = o["tool_name"]?.stringValue ?? o["toolName"]?.stringValue
        resultSummary = Self._capString(
            o["result_summary"]?.stringValue ?? o["resultSummary"]?.stringValue,
            4_000
        )
        resultStatus = o["result_status"]?.stringValue ?? o["resultStatus"]?.stringValue
        // Just the interaction's state name: the one field every build has
        // written since v1, so a shape this build does not understand still
        // yields it.
        if case .object(let interaction)? = o["interaction"],
           case .object(let state)? = interaction["state"] {
            switch state["name"] {
            case .string(let name)?: interactionState = name
            default: interactionState = nil
            }
        } else {
            interactionState = nil
        }
        ok = o["ok"]?.boolValue
        durationMs = chatRowInt(o["duration_ms"])
        beforeContent = Self._capString(o["before_content"]?.stringValue, 16_000)
        afterContent = Self._capString(o["after_content"]?.stringValue, 16_000)
        approvalId = o["approval_id"]?.stringValue ?? o["approvalId"]?.stringValue
        mirrorInteractionId = o["interactionId"]?.stringValue
        mirrorInteractionSessionId = o["interactionSessionId"]?.stringValue
        attachments = PersistedAttachment.list(o["attachments"])
        if case .object(let fields)? = o["envelope"] {
            envelope = ChatMessageOriginMetadata(fields: fields)
        }
        // Present but unreadable origins (including null) render as "Automated"; absent origins stay absent.
        switch o["origin"] {
        case nil:
            origin = nil
        case .object(let fields)?:
            origin = ChatMessageOriginMetadata(fields: fields)
                ?? ChatMessageOriginMetadata(surface: "unreadable")
        default:
            origin = ChatMessageOriginMetadata(surface: "unreadable")
        }
        workingCommentaryChars = chatRowInt(o["workingCommentaryChars"])
        mechanicalKind = o["mechanicalKind"]?.stringValue
        failureWork = o["failureWork"]?.stringValue
        // A legacy `input` object is shown as its JSON text; otherwise the
        // text the writer stored.
        if case .object(let rawInput)? = o["input"] {
            var dict: [String: Any] = [:]
            for (key, value) in rawInput.sorted(by: { $0.key < $1.key }) {
                dict[key] = Self.displayValue(value)
            }
            let json = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) }
            inputJSON = Self._capString(json, 4_000)
        } else {
            inputJSON = Self._capString(
                o["input"]?.stringValue ?? o["inputJSON"]?.stringValue,
                4_000
            )
        }
    }

    /// A legacy input value as display JSON: scalars keep their type (an
    /// integral number reads as an integer); nested values read as "".
    private static func displayValue(_ value: JSONValue) -> Any {
        switch value {
        case .bool(let b): return b
        case .int(let n): return Int(n)
        case .double(let d): return Int(exactly: d).map { $0 as Any } ?? d
        case .string(let s): return s
        case .null, .array, .object: return ""
        }
    }

}

/// Per-message attachment metadata with the transcript owner's display preview.
/// Source bytes remain at `path`; the bounded preview is a read projection,
/// carried to DeviceSync with the same message that the Mac renders.
/// Metadata comes from `ChatOrchestrationClient.appendMessage`'s
/// `metadata.attachments` in `chat/messages/<sid>.jsonl`. Encoded on the Mac
/// `ChatMessage.metadata`, snapshotted into iCloud `chat_transcripts.json`,
/// and decoded by iOS into `ChatMessageRecord.metadata.attachments`.
extension PersistedAttachment {
    /// One `metadata.attachments` element. A non-object, or a string field
    /// holding another type, is unreadable; a missing or non-integral
    /// byteSize reads as 0.
    public init?(value: JSONValue) {
        guard let row = try? JSONRow(value) else { return nil }
        do {
            self.init(id: try row.optionalString("id") ?? UUID().uuidString,
                      type: try row.optionalString("type") ?? "file",
                      mime: try row.optionalString("mime") ?? "application/octet-stream",
                      name: try row.optionalString("name"), byteSize: 0,
                      path: try row.optionalString("path"))
        } catch { return nil }
        let o = row.fields
        if let value = o["preview"], let bytes = try? value.serializedData(pretty: false) {
            self.preview = try? JSONDecoder().decode(TranscriptAttachmentPreview.self, from: bytes)
        }
        if let evidence = o["utterance"] {
            guard let bytes = try? evidence.serializedData(pretty: false),
                  let utterance = try? JSONDecoder().decode(SpeechUtterance.self, from: bytes) else { return nil }
            self.utterance = utterance
        }
        switch o["byteSize"] {
        case .int(let n)?: byteSize = n
        case .double(let d)?: byteSize = Int64(exactly: d) ?? 0
        default: byteSize = 0
        }
    }

    /// Every element, or nil when the value is not an array or any element is
    /// unreadable.
    public static func list(_ value: JSONValue?) -> [PersistedAttachment]? {
        guard case .array(let elements)? = value else { return nil }
        var out: [PersistedAttachment] = []
        for element in elements {
            guard let attachment = PersistedAttachment(value: element) else { return nil }
            out.append(attachment)
        }
        return out
    }
}

extension TranscriptAttachmentPreview {
    fileprivate init(path: String?) {
        // Keep the measured 720px decode: a 360pt transcript bubble at 2×.
        let bytes = NSMutableData()
        if let path, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let image = Self.thumbnail(from: source, maxDimension: 720),
           let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            self.init(png: CGImageDestinationFinalize(destination) ? bytes as Data : nil)
        } else {
            self.init(png: nil)
        }
    }
}

extension TranscriptReadout {
    /// Attachment files are refreshed outside the transcript-file cache: their
    /// contents may change without changing the message's path or JSONL row.
    func attachmentPreviews() async -> Self {
        await Task.detached(priority: .userInitiated) {
            let rows = self.messages.map { original in
                var message = original
                message.metadata?.attachments = original.metadata?.attachments?.map { original in
                    var attachment = original
                    if attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image" {
                        attachment.preview = TranscriptAttachmentPreview(path: attachment.path)
                    }
                    return attachment
                }
                return message
            }
            var projection = self
            projection.messages = rows
            return projection
        }.value
    }
}

/// Decoded twin of the `metadata.origin` object written by
/// ChatOrchestrationClient.appendMessage. Deliberately dumb: it carries the
/// raw recorded strings and makes no display decisions. All allowlisting and
/// sanitizing happens in MacChatMessageProvenance, at the render boundary.
extension ChatMessageOriginMetadata {
    /// The recorded strings, or nil when either is present with another type.
    public init?(fields o: [String: JSONValue]) {
        self.init()
        for key in ["surface", "agent"] {
            switch o[key] {
            case nil, .null?, .string?: continue
            default: return nil
            }
        }
        surface = o["surface"]?.stringValue
        agent = o["agent"]?.stringValue
        authored = o["authored"]?.stringValue
        verifiedUserId = o["verifiedUserId"]?.stringValue
        if case .array(let values)? = o["peerSources"] {
            peerSources = values.compactMap { $0.stringValue }
        }
        if case .array(let values)? = o["elevatedPeerSources"] {
            elevatedPeerSources = values.compactMap { $0.stringValue }
        }
    }
}

// MARK: - Transcript row fields

/// An integer field; an integral JSON float reads as its integer.
private func chatRowInt(_ value: JSONValue?) -> Int? {
    if case .double(let number)? = value, number != number.rounded() { return nil }
    return value?.integerValue.flatMap(Int.init(exactly:))
}
extension ChatMessage: MacChatRetryMessage {
    public var retryOrigin: ChatMessageOrigin? {
        guard let recorded = metadata?.origin else { return nil }
        var origin = ChatMessageOrigin(surface: recorded.surface ?? "unreadable", agent: recorded.agent,
            authored: recorded.authored.flatMap(ChatMessageAuthorship.init(rawValue:))
                ?? (recorded.agent == nil ? nil : .agent))
        origin.peerSources = recorded.peerSources
        origin.elevatedPeerSources = recorded.elevatedPeerSources
        if origin.peerSources == nil, origin.authored == .agent, recorded.agent != "self" {
            origin.peerSources = [recorded.agent ?? "an agent"]
        }
        return origin
    }
    public var retryHasAttachments: Bool { metadata?.attachments?.isEmpty == false }
    public var retryUserRowPersisted: Bool? { metadata?.syntheticUserRowPersisted }
    public var retryInputHadAttachments: Bool? { metadata?.syntheticInputHadAttachments }
}

extension ChatMessage: FirstRunWelcomeMessage {
    public var firstRunMechanicalKind: String? { metadata?.mechanicalKind }
    public var firstRunTurnCompleted: Bool {
        metadata?.completionState == "completed"
            && metadata?.partial != true && metadata?.cancelled != true
    }
}

extension ChatMessageMetadata: ChatTurnFailureMetadata {}
extension ChatMessage: ChatTurnFailureMessage {}

extension ChatMessage: MacChatRenderedMessage {
    public var macChatHasMetadata: Bool { metadata != nil }
    public var macChatPartial: Bool { metadata?.partial == true }
    public var macChatCancelled: Bool { metadata?.cancelled == true }
}

extension ChatMessage {
    public init(approval: ApprovalRecord) {
        var metadata = ChatMessageMetadata()
        metadata.kind = ChatMessageMetadata.approvalPendingKind
        metadata.approvalId = approval.id
        self.init(id: approval.id, role: "tool",
                  content: "\(approval.title)\n\(approval.reason)\n\(approval.payloadPreview)", metadata: metadata)
    }
}

public enum ChatExport {
    public static func export(
        session: ChatSession?,
        sessionId: String,
        messages: [ChatMessage],
        exportedAt: Date = Date()
    ) async throws -> ChatExportResult {
        try await Task.detached(priority: .userInitiated) {
            guard !sessionId.isEmpty else { throw ChatExportError.noActiveSession }
            guard !messages.isEmpty else { throw ChatExportError.noMessages }
            guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                throw ChatExportError.downloadsUnavailable
            }

            let timestamp = fileTimestamp(exportedAt)
            let safeSessionId = safeFilesystemSessionId(sessionId)
            let fileURL = downloadsDir.appendingPathComponent("\(InstallPaths.current.name("NativeAgent"))-chat-\(safeSessionId)-\(timestamp)-\(UUID().uuidString).md")
            let assets = fileURL.deletingPathExtension().appendingPathExtension("assets")
            var imagePaths: [String: String] = [:]
            var unavailableImages: [String: String] = [:]
            var unavailableDetails: [String] = []
            do {
                for message in messages {
                    if message.role == "system" && message.content.hasPrefix("[tool:") { continue }
                    for attachment in message.metadata?.attachments ?? [] where attachment.type == "image" {
                        guard imagePaths[attachment.id] == nil, unavailableImages[attachment.id] == nil else { continue }
                        let label = attachment.name ?? attachment.id
                        guard let path = attachment.path, !path.isEmpty else {
                            let detail = "\(label): no saved file"
                            unavailableImages[attachment.id] = detail
                            unavailableDetails.append(detail)
                            continue
                        }
                        let source = URL(fileURLWithPath: path)
                        let name = UUID().uuidString + "." + safeFilesystemSessionId(source.pathExtension)
                        let destination = assets.appendingPathComponent(name)
                        do {
                            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                            try FileManager.default.copyItem(at: source, to: destination)
                            imagePaths[attachment.id] = assets.lastPathComponent + "/" + name
                        } catch {
                            try? FileManager.default.removeItem(at: destination)
                            let detail = "\(label): \(error.localizedDescription)"
                            unavailableImages[attachment.id] = detail
                            unavailableDetails.append(detail)
                        }
                    }
                }
                let markdown = sessionMarkdown(session: session, sessionId: sessionId, messages: messages,
                                               exportedAt: exportedAt, imagePaths: imagePaths,
                                               unavailableImages: unavailableImages)
                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
                return ChatExportResult(url: fileURL, unavailableImages: unavailableDetails)
            } catch {
                if FileManager.default.fileExists(atPath: assets.path) { try? FileManager.default.removeItem(at: assets) }
                throw error
            }
        }.value
    }

    public static func sessionMarkdown(
        session: ChatSession?,
        sessionId: String,
        messages: [ChatMessage],
        exportedAt: Date,
        imagePaths: [String: String] = [:],
        unavailableImages: [String: String] = [:]
    ) -> String {
        let title = (session?.title ?? "chat").replacingOccurrences(of: "/", with: "-")
        var markdown = "# \(title)\n\n"
        markdown += "_Session: \(sessionId) - Exported: \(ISO8601DateFormatter().string(from: exportedAt))_\n\n"
        for message in messages {
            if message.role == "system" && message.content.hasPrefix("[tool:") {
                continue
            }
            markdown += messageMarkdown(message, imagePaths: imagePaths, unavailableImages: unavailableImages)
        }
        return markdown
    }

    /// Render one chat message as Markdown: role header, content, and compact
    /// attachment references. Each block ends blank so consecutive messages
    /// stay separated in exports and clipboard copies.
    public static func messageMarkdown(
        _ message: ChatMessage, imagePaths: [String: String] = [:], unavailableImages: [String: String] = [:]
    ) -> String {
        let role = message.role.capitalized
        var out = "**\(role):** \(message.content)\n\n"
        if let attachments = message.metadata?.attachments, !attachments.isEmpty {
            for attachment in attachments {
                let label = attachment.name ?? attachment.id
                if attachment.type == "image" {
                    if let detail = unavailableImages[attachment.id] {
                        out += "- image unavailable: \(detail)\n"
                        continue
                    }
                    let target = imagePaths[attachment.id] ?? label
                    guard let escaped = target.addingPercentEncoding(withAllowedCharacters:
                        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")) else {
                        out += "- image unavailable: its export target could not be encoded\n"
                        continue
                    }
                    out += "![image](\(escaped))\n"
                } else {
                    out += "- attachment: \(label) (\(attachment.mime ?? "application/octet-stream"))\n"
                }
            }
            out += "\n"
        }
        return out
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private static func safeFilesystemSessionId(_ sessionId: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let scalars = sessionId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalars)
        return cleaned.isEmpty ? "session" : String(cleaned.prefix(64))
    }
}
