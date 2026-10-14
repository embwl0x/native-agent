import Foundation
import NativeAgentShared
import PersistenceCore

public protocol ChatExportAttachment {
    var id: String { get }
    var type: String { get }
    var mime: String { get }
    var name: String? { get }
}

public protocol ChatExportMetadata {
    associatedtype Attachment: ChatExportAttachment
    var attachments: [Attachment]? { get }
}

public protocol ChatExportMessage {
    associatedtype Metadata: ChatExportMetadata
    var role: String { get }
    var content: String { get }
    var metadata: Metadata? { get }
}

public enum ChatExportError: LocalizedError {
    case noActiveSession
    case noMessages
    case downloadsUnavailable

    public var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active session to export"
        case .noMessages:
            return "No messages to export"
        case .downloadsUnavailable:
            return "Could not locate Downloads folder"
        }
    }
}

public enum ChatExportService {
    public static func export<Message: ChatExportMessage & Sendable>(
        session: ChatSession?,
        sessionId: String,
        messages: [Message],
        exportedAt: Date = Date()
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard !sessionId.isEmpty else { throw ChatExportError.noActiveSession }
            guard !messages.isEmpty else { throw ChatExportError.noMessages }
            guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                throw ChatExportError.downloadsUnavailable
            }

            let timestamp = fileTimestamp(exportedAt)
            let safeSessionId = safeFilesystemSessionId(sessionId)
            let markdown = sessionMarkdown(
                session: session,
                sessionId: sessionId,
                messages: messages,
                exportedAt: exportedAt
            )
            let fileURL = downloadsDir.appendingPathComponent("\(InstallPaths.current.name("NativeAgent"))-chat-\(safeSessionId)-\(timestamp)-\(UUID().uuidString).md")
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        }.value
    }

    public static func sessionMarkdown<Message: ChatExportMessage>(
        session: ChatSession?,
        sessionId: String,
        messages: [Message],
        exportedAt: Date
    ) -> String {
        let title = (session?.title ?? "chat").replacingOccurrences(of: "/", with: "-")
        var markdown = "# \(title)\n\n"
        markdown += "_Session: \(sessionId) - Exported: \(ISO8601DateFormatter().string(from: exportedAt))_\n\n"
        for message in messages {
            if message.role == "system" && message.content.hasPrefix("[tool:") {
                continue
            }
            markdown += messageMarkdown(message)
        }
        return markdown
    }

    /// Render one chat message as Markdown: role header, content, and compact
    /// attachment references. Each block ends blank so consecutive messages
    /// stay separated in exports and clipboard copies.
    public static func messageMarkdown<Message: ChatExportMessage>(_ message: Message) -> String {
        let role = message.role.capitalized
        var out = "**\(role):** \(message.content)\n\n"
        if let attachments = message.metadata?.attachments, !attachments.isEmpty {
            for attachment in attachments {
                let label = attachment.name ?? attachment.id
                if attachment.type == "image" {
                    out += "![image](\(label))\n"
                } else {
                    out += "- attachment: \(label) (\(attachment.mime))\n"
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
