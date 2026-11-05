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
// Blueprint: | `ChatModels.swift` | `ChatMessage`; Checked transcript codec, attachment previews and export |

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var sessionId: String? = nil
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

    /// Never invent canonical history; retain the prior published transcript if decoding fails.
    public init(row o: [String: JSONValue]) throws {
        let row = try JSONRow(.object(o))
        self.id = try row.string("id")
        self.sessionId = try row.optionalString("sessionId")
        self.content = try row.string("content")
        self.createdAt = try row.string("createdAt")
        let decodedRole = try row.string("role")
        guard !id.isEmpty, !createdAt.isEmpty, !decodedRole.isEmpty else {
            throw NSError(domain: "NativeAgent.ChatHistory", code: 422, userInfo: [
                NSLocalizedDescriptionKey: """
                    A saved message has an empty id, role or createdAt. Repair the original transcript row; its identity and authorship cannot be guessed.
                    """
            ])
        }
        self.runId = try row.optionalString("runId")
        self.source = try row.optionalString("source")

        // Malformed metadata must retain the closed provenance sentinel; treating it as absent could make an automated row look human.
        switch o["metadata"] {
        case nil, .null?:
            self.metadata = nil
        case .object(let fields)?:
            self.metadata = try JSONDecoder().decode(ChatMessageMetadata.self, from: JSONValue.object(fields).serializedData(pretty: false))
        default:
            var unreadable = ChatMessageMetadata()
            unreadable.origin = ChatMessageOriginMetadata(surface: "unreadable")
            unreadable.envelope = ChatMessageOriginMetadata(surface: "unreadable")
            self.metadata = unreadable
        }

        let normalizedRole = decodedRole
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if self.metadata?.origin != nil, normalizedRole != "user" {
            // An unreadable role cannot hide provenance warnings or attribute the row to the agent.
            self.role = "user"
        } else {
            self.role = decodedRole
        }
    }

    public init(from decoder: Decoder) throws {
        guard case .object(let o) = try JSONValue(from: decoder) else {
            throw DecodingError.typeMismatch(
                ChatMessage.self,
                .init(codingPath: decoder.codingPath, debugDescription: "A chat message is a JSON object.")
            )
        }
        try self.init(row: o)
    }
}

extension ChatMessage {
    /// Self-authored wake inputs are never the person’s words, including when the agent also acts on their behalf.
    public var isAgentOwnTurnInput: Bool {
        role == "user" && metadata?.origin?.agent == "self" && metadata?.origin?.authored == "agent"
            && metadata?.origin?.surface == ResidentWake.session
    }
}

extension ChatMessageMetadata {
    /// Producers and renderers must share `isPendingApproval` vocabulary so actionable cards cannot hide in collapsed tool summaries.
    public static let approvalPendingKind = ChatTranscriptToolMessageKind.approvalPending

    public var isPendingApproval: Bool {
        kind == Self.approvalPendingKind
    }
    /// Keep retry guards off the wire; `userRowPersisted` prevents suppressing an unsaved user message.
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
    /// Refresh attachments separately: their bytes may change without changing the transcript row or path.
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
            let fileURL = downloadsDir.appendingPathComponent(
                "\(InstallPaths.current.name("NativeAgent"))-chat-\(safeSessionId)-\(timestamp)-\(UUID().uuidString).md")
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

    /// End each Markdown block blank so exported and copied messages remain separated.
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
