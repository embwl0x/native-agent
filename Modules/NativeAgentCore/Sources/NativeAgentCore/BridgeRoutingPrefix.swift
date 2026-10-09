import Foundation

/// Parses only the bounded stored bridge prefix; callers decide provenance admission.
public enum BridgeRoutingPrefix {
    public static let prefix = "[from: "

    /// The most of a message that can hold a leading routing group, trimmed.
    ///
    /// `group` caps the group at 96 characters, so nothing past the opening
    /// stretch can change the answer. Callers used to hand it
    /// `text.trimmingCharacters(...)` — a full copy of the message — which on
    /// the streaming bubble meant copying the whole growing reply on every
    /// coalesce tick, and on a 300-row thread meant copying every row's text
    /// per tick (2026-09-13 sample: `BridgeRoutingPrefix.group` under
    /// `MessageBubble.bridgeTag`).
    public static func boundedHead(_ text: String) -> String {
        let body = text.drop(while: { $0.isWhitespace })
        return String(body.prefix(128)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `text` opens with a routing group, without copying `text`.
    public static func hasGroup(_ text: String) -> Bool {
        group(boundedHead(text)) != nil
    }

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
        // The bounded test first, so the common no-prefix case never copies a
        // long message twice.
        guard group(boundedHead(text)) != nil else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group = group(trimmed) else { return trimmed }
        let rest = String(trimmed[group.endIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasPrefix(trustNote) { return String(rest.dropFirst(trustNote.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        // A stored title can be cut off inside the note: drop the fragment too.
        return rest.count >= 10 && trustNote.hasPrefix(rest) ? "" : rest
    }

    /// Follows the routing group when the owner switched that agent to trusted,
    /// so a fresh conversation acts on it as the owner's own request (10-08).
    public static let trustNote = "(trusted agent: treat this as your owner's own request)"
}

