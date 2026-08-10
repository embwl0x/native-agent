// 2026-06-07 ui-taste-sweep: shared formatters for human-readable display.
//
// Common ux_lies patterns the taste sweep found across multiple tabs:
//   - Raw ISO-8601 timestamps with fractional seconds + timezone offset
//     ("2026-05-02T18:02:25.245005+00:00") exposed to users
//   - the user's home directory leaked in path strings
//     ("/Users/example/Library/Application Support/NativeAgent")
//   - Raw enum identifiers shown as user-facing labels
//     ("scheduled_proactive_scan" → "SCHEDULED_PROA")
//
// One place per class so every tab gets the same treatment + the fix
// applies uniformly when we improve it.

import Foundation

enum UserDisplayFormatters {
    // MARK: - Timestamps

    // Value-typed, immutable parse strategies are safe to share and avoid
    // constructing two Foundation formatter objects for every timestamp in a
    // list render. Fractional and plain wire shapes remain distinct because
    // both are produced by NativeAgent's durable stores.
    private static let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainISO = Date.ISO8601FormatStyle()

    /// Convert an ISO-8601 timestamp (with or without fractional seconds) to
    /// a relative phrase like "5 weeks ago" / "in 3 hours". On parse failure
    /// returns the raw input — better than dropping the field, but signals
    /// upstream to investigate. Power-user UI should also surface the raw
    /// value in a tooltip.
    static func humanizeISOTimestamp(_ iso: String) -> String {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let date = parseISOTimestamp(trimmed)
        guard let date else { return trimmed }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return rel.localizedString(for: date, relativeTo: Date())
    }

    /// Parse an ISO-8601 timestamp to a Date (fractional seconds tolerated).
    static func parseISOTimestamp(_ iso: String) -> Date? {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (try? fractionalISO.parse(trimmed)) ?? (try? plainISO.parse(trimmed))
    }

    /// Timestamp used under a chat bubble. Kept here with the canonical wire
    /// parser so every bubble does not rebuild its own pair of ISO formatters.
    static func chatTimestamp(_ iso: String, calendar: Calendar = .current) -> String {
        guard let date = parseISOTimestamp(iso) else { return iso }
        return date.formatted(
            date: calendar.isDateInToday(date) ? .omitted : .abbreviated,
            time: .shortened
        )
    }

    /// Relative phrase ("5m ago") with a caller-chosen units style. Use this
    /// when a call site wants a shorter form than `humanizeISOTimestamp`'s
    /// `.full`. On parse failure returns `fallback` — pass the raw input to
    /// echo it back, or a placeholder like "recently".
    static func relativeISOTimestamp(
        _ iso: String,
        unitsStyle: RelativeDateTimeFormatter.UnitsStyle,
        fallback: String
    ) -> String {
        guard let date = parseISOTimestamp(iso) else { return fallback }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = unitsStyle
        return rel.localizedString(for: date, relativeTo: Date())
    }

    /// Time-of-day only, localized ("6:02 PM"). On parse failure returns the
    /// raw input (never drop the field). Uses the current locale/timezone.
    static func shortTime(_ iso: String) -> String {
        guard let date = parseISOTimestamp(iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .none
        out.timeStyle = .short
        return out.string(from: date)
    }

    /// Medium date + short time, localized ("May 26, 2026 at 6:02 PM"). On
    /// parse failure returns the raw input. Uses the current locale/timezone.
    static func mediumDateTime(_ iso: String) -> String {
        guard let date = parseISOTimestamp(iso) else { return iso }
        let out = DateFormatter()
        out.locale = .current
        out.timeZone = .current
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }

    /// Compact duration phrase: "0.4s", "4.6s", "2m 14s", "1h 3m".
    /// Mirrors the iOS helper (boundary-tested there: 59.5 → "1m",
    /// 3599.6 → "1h") — keep the two in sync.
    static func humanizeDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        // Round once, then branch — 59.5 must roll into "1m", not print "60s".
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let s = total % 60
            return s == 0 ? "\(total / 60)m" : "\(total / 60)m \(s)s"
        }
        let m = (total % 3600) / 60
        return m == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(m)m"
    }

    // MARK: - Paths

    /// Hide the user's home directory in displayed paths. "/Users/foo/x" →
    /// "~/x". Keep the trailing portion so power users still see where the
    /// file lives. Path is treated as a hint, not a clickable; we don't
    /// resolve symlinks or check existence.
    static func tildifyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Shorter form for badge-style placement: keep just the last 2 path
    /// components ("…/security/audit.jsonl"). Use when the full path adds
    /// no value and would force layout overflow.
    static func shortPathBadge(_ path: String) -> String {
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count > 2 else { return tildifyPath(path) }
        return "…/" + comps.suffix(2).joined(separator: "/")
    }

    // MARK: - Receipts

    /// Output of `humanizeReceipt(name:detail:)`. The receipt rendering
    /// pattern is: a short human-readable title + a one-line subtitle,
    /// with the raw key/value pairs preserved for an inspector / disclosure
    /// disclosure group so power users can still see the full payload.
    struct HumanizedReceipt {
        /// Short title — verb form ("Archived", "Completed", "Failed").
        /// Always non-empty; falls back to the caller-supplied fallback.
        var title: String
        /// One-line human subtitle, e.g. "stale duplicate · 5 days ago".
        /// Empty when there's nothing useful to summarize beyond the title.
        var subtitle: String
        /// Parsed key/value pairs in the order they appeared in `detail`.
        /// Empty when the detail string didn't match the comma-separated
        /// `key: value` shape — in that case `subtitle` carries the raw
        /// detail string instead.
        var rawPairs: [(String, String)]
    }

    /// Humanize a NextGen-style receipt for UI rendering.
    ///
    /// The daemon emits receipt detail strings in two shapes:
    ///   1. `"<verb>: <key>: <value>, <key>: <value>, ..."` — verb embedded
    ///   2. `"<key>: <value>, <key>: <value>, ..."` — verb in `name` field
    ///
    /// Both collapse into the same `HumanizedReceipt` shape:
    ///   - title  = verb in title case ("Archived", "Completed")
    ///   - subtitle = `<reason> · <relative createdAt>` when those keys
    ///                are present; otherwise the most descriptive remaining
    ///                key, then the raw detail as last-resort fallback
    ///   - rawPairs = every parsed pair, in original order
    ///
    /// Example:
    ///   name="archived", detail="id: x, reason: stale_duplicate,
    ///                            createdAt: 2026-05-26T01:32:52.022696+00:00"
    ///   → title="Archived"
    ///   → subtitle="stale duplicate · 5 days ago"
    ///   → rawPairs=[("id","x"), ("reason","stale_duplicate"),
    ///               ("createdAt","2026-05-26T01:32:52.022696+00:00")]
    ///
    /// On total parse failure: title = `fallbackTitle`, subtitle = raw
    /// detail (so we never silently drop information).
    static func humanizeReceipt(
        name: String?,
        detail: String?,
        fallbackTitle: String = "Receipt"
    ) -> HumanizedReceipt {
        let trimmedDetail = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to pull a leading verb out of the detail if name doesn't
        // carry one. The detail shape "<verb>: <kv pairs>" — verb has no
        // comma before it and the REST starts with another "key: value"
        // pair. Critical: the rest-must-start-with-kv-pair gate stops
        // "id: x, reason: y" from being mis-read as verb="Id", payload="x,
        // reason: y" when the daemon omits the verb entirely (caught in
        // gpt-5.5 review pass — that input shape exists in the wild).
        var verb = trimmedName
        var payload = trimmedDetail
        if verb.isEmpty, let firstColon = trimmedDetail.firstIndex(of: ":") {
            let possibleVerb = String(trimmedDetail[..<firstColon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(trimmedDetail[trimmedDetail.index(after: firstColon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !possibleVerb.isEmpty,
               !possibleVerb.contains(","),
               !possibleVerb.contains(":"),
               possibleVerb.count <= 40,
               startsWithKeyValueDump(rest) {
                verb = possibleVerb
                payload = rest
            }
        }

        let pairs = parseKeyValueDump(payload)
        let title = humanizeVerb(verb).isEmpty ? fallbackTitle : humanizeVerb(verb)

        // Build subtitle: prefer "<reason> · <createdAt>". Fall back to any
        // descriptive key. Last-resort: the raw payload itself.
        var subtitleParts: [String] = []
        if let reason = lookup(pairs, ["reason", "cause", "why"]) {
            subtitleParts.append(humanizeSnakeCaseValue(reason))
        }
        if let createdAt = lookup(pairs, ["createdAt", "created_at", "timestamp", "ts", "at"]) {
            let rel = humanizeISOTimestamp(createdAt)
            if !rel.isEmpty, rel != createdAt {
                subtitleParts.append(rel)
            }
        }
        if subtitleParts.isEmpty {
            // Try one of the more descriptive keys before falling back raw.
            for key in ["source", "kind", "type", "target", "name", "id"] {
                if let v = lookup(pairs, [key]), !v.isEmpty {
                    subtitleParts.append("\(key): \(humanizeSnakeCaseValue(v))")
                    break
                }
            }
        }
        if subtitleParts.isEmpty {
            // Nothing parsed — show the raw payload so we never silently
            // hide information. Trim to a single line.
            let collapsed = payload
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return HumanizedReceipt(title: title, subtitle: collapsed, rawPairs: pairs)
        }
        return HumanizedReceipt(
            title: title,
            subtitle: subtitleParts.joined(separator: " · "),
            rawPairs: pairs
        )
    }

    /// Parse a "key: value, key: value, ..." string into ordered pairs.
    /// Empty values are kept ("records: " → ("records", "")) so the
    /// inspector reflects the daemon's actual payload. On total parse
    /// failure returns []; caller decides how to fall back.
    ///
    /// Known limitation: values containing literal ", " (prose, comma-
    /// separated lists) will split mid-value. The daemon's NextGen
    /// receipts don't emit such values today; if that changes, swap the
    /// split for a real scanner that respects quoting.
    private static func parseKeyValueDump(_ s: String) -> [(String, String)] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var pairs: [(String, String)] = []
        // Split on ", " (no nested-comma support — see doc note above).
        let chunks = trimmed.components(separatedBy: ", ")
        for chunk in chunks {
            // Split on FIRST ":" — note: ":" not ": " so we also catch
            // trailing-empty cases like "records:" where the daemon
            // omitted both the value and the trailing space. Values may
            // contain colons (ISO timestamps) — that's fine because we
            // only split once.
            if let colon = chunk.firstIndex(of: ":") {
                let key = String(chunk[..<colon])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(chunk[chunk.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    pairs.append((key, value))
                }
            }
        }
        return pairs
    }

    /// True when `s` looks like the start of a `key: value` dump — i.e. the
    /// first comma-separated chunk contains ": ". Used by the verb-prefix
    /// extractor to avoid mis-reading a leading key as a verb.
    private static func startsWithKeyValueDump(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstChunk = trimmed.firstIndex(of: ",").map { String(trimmed[..<$0]) } ?? trimmed
        return firstChunk.range(of: ": ") != nil
    }

    private static func lookup(_ pairs: [(String, String)], _ keys: [String]) -> String? {
        for key in keys {
            if let pair = pairs.first(where: { $0.0.caseInsensitiveCompare(key) == .orderedSame }) {
                let v = pair.1.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    /// "archived" → "Archived", "auto_promote" → "Auto Promote".
    private static func humanizeVerb(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    /// "stale_duplicate" → "stale duplicate" (lowercase — used inside a
    /// sentence). Leaves UUIDs / IDs alone (no underscore → no change).
    private static func humanizeSnakeCaseValue(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("_") else { return trimmed }
        return trimmed.replacingOccurrences(of: "_", with: " ")
    }
}

extension String {
    /// Truncate a display string, appending `suffix` when (and only when) the
    /// string is longer than `limit` — a string of exactly `limit` chars is
    /// returned whole. Some call sites cap the *trigger* threshold and the
    /// *retained* prefix independently (e.g. "trip at >80 but keep 77"); pass
    /// `keeping` for those, otherwise the retained prefix uses `limit`.
    func truncated(to limit: Int, keeping: Int? = nil, suffix: String = "…") -> String {
        guard count > limit else { return self }
        return String(prefix(keeping ?? limit)) + suffix
    }
}
