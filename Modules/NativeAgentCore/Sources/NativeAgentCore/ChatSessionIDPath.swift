import Foundation

/// Path safety for chat session ids used as filenames or directory names.
///
/// Session ids intentionally allow `:` for existing Telegram legacy sessions
/// (`telegram:<chatId>`), but they must never contain path separators or
/// traversal markers.
public enum NativeAgentChatSessionID {
    public static func normalizedPathComponent(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafePathComponent(trimmed) else { return nil }
        return trimmed
    }

    public static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 160 else { return false }
        if value == "." || value == ".." || value.hasPrefix(".") { return false }
        if value.contains("/") || value.contains("\\") || value.contains("\0") { return false }
        if value.contains("..") { return false }
        if value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) {
            return false
        }
        return true
    }
}
