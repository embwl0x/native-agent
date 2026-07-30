import Foundation

enum ChatExportError: LocalizedError {
    case noActiveSession
    case noMessages
    case downloadsUnavailable

    var errorDescription: String? {
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

enum ChatExportService {
    static func export(
        session: ChatSession?,
        sessionId: String,
        messages: [ChatMessage],
        fileManager: FileManager = .default,
        exportedAt: Date = Date()
    ) throws -> URL {
        guard !sessionId.isEmpty else { throw ChatExportError.noActiveSession }
        guard !messages.isEmpty else { throw ChatExportError.noMessages }
        guard let downloadsDir = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
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
        let fileURL = downloadsDir.appendingPathComponent("NativeAgent-chat-\(safeSessionId)-\(timestamp).md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    static func sessionMarkdown(
        session: ChatSession?,
        sessionId: String,
        messages: [ChatMessage],
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
    static func messageMarkdown(_ message: ChatMessage) -> String {
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
