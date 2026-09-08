import Foundation

/// Parses only the bounded stored bridge prefix; callers decide provenance admission.
public enum BridgeRoutingPrefix {
    public static let prefix = "[from: "

    /// The leading `[from: <agent>, via bridge]` group, or nil. The exact shape
    /// is required: a person who types "[from: my notes] …" keeps every word.
    public static func group(_ trimmed: String) -> Substring? {
        guard trimmed.hasPrefix(prefix),
              let close = trimmed.firstIndex(of: "]"),
              trimmed.distance(from: trimmed.startIndex, to: close) <= 96
        else { return nil }
        let group = trimmed[trimmed.startIndex...close]
        return group.contains("via bridge") ? group : nil
    }

    /// Drop a leading `[from: claude, via bridge]` routing prefix. Bounded and
    /// anchored: only a leading bracket group on the FIRST line is removed, so
    /// prose that merely contains a bracket is untouched.
    public static func stripping(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group = group(trimmed) else { return trimmed }
        return String(trimmed[group.endIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

