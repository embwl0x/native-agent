import Foundation

/// Maps the Provider Settings operation receipt into one bounded, truthful
/// status row. The raw operation string remains available to the owner, while
/// this view contract prevents a failed or repair-required result from taking
/// on the same neutral appearance as a successful save.
enum ProviderSettingsStatusTextPresentation {
    static let maximumVisibleCharacters = 220

    enum Tone: Equatable {
        case info
        case progress
        case success
        case warning
        case failure
    }

    struct State: Equatable {
        let text: String
        let tone: Tone
        let systemImage: String
        let isTruncated: Bool
    }

    static func state(for raw: String) -> State? {
        let normalized = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let bounded = boundedText(normalized)
        let lower = normalized.lowercased()

        if lower.contains("failed") || lower.contains("error") || lower.contains("unavailable") {
            return State(text: bounded.text, tone: .failure,
                         systemImage: "exclamationmark.triangle.fill", isTruncated: bounded.isTruncated)
        }
        if lower.contains("need repair") || lower.contains("not available") {
            return State(text: bounded.text, tone: .warning,
                         systemImage: "exclamationmark.triangle", isTruncated: bounded.isTruncated)
        }
        if lower.hasPrefix("saving ") {
            return State(text: bounded.text, tone: .progress,
                         systemImage: "hourglass", isTruncated: bounded.isTruncated)
        }
        if lower.hasSuffix(" saved") || lower == "credentials removed." {
            return State(text: bounded.text, tone: .success,
                         systemImage: "checkmark.circle", isTruncated: bounded.isTruncated)
        }
        return State(text: bounded.text, tone: .info,
                     systemImage: "info.circle", isTruncated: bounded.isTruncated)
    }

    private static func boundedText(_ text: String) -> (text: String, isTruncated: Bool) {
        guard text.count > maximumVisibleCharacters else { return (text, false) }
        return (String(text.prefix(maximumVisibleCharacters)) + "…", true)
    }
}
