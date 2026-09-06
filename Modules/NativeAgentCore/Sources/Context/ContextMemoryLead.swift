import Foundation

/// How a memory record came to be known, as the agent should read it back.
///
/// `verified` — she checked it herself. `told` — someone told her (`by`).
/// `inferred` — she worked it out. Rows written before provenance existed carry
/// none, and render nothing: an absent tag is honest, an invented one is not.
public struct ContextMemoryProvenance: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case verified
        case told
        case inferred
    }

    public let kind: Kind
    public let by: String?

    public init(kind: Kind, by: String? = nil) {
        self.kind = kind
        let trimmed = by?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.by = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// `[verified]` / `[told by Claude]` / `[inferred]`.
    public var tag: String {
        if kind == .told, let by { return "[told by \(by)]" }
        return "[\(kind.rawValue)]"
    }
}

/// The ONE time a packet render is allowed to know about.
///
/// An age tag is a function of the TURN, not of whenever a renderer happened to
/// run: two atoms rendered either side of local midnight must not disagree
/// about what "yesterday" means, and re-rendering the same prepared turn must
/// produce the same bytes. So the time is frozen (the turn's own evaluation
/// time) and the calendar — time zone included — is passed in explicitly rather
/// than read from the environment inside the renderer.
///
/// `.unstamped` is the honest fallback for a caller with no turn in hand: it
/// renders NO age tag rather than one computed from a stray wall-clock read.
public struct ContextRenderClock: Sendable, Equatable {
    /// nil → this render has no turn time, so it claims no age.
    public let now: Date?
    public let calendar: Calendar

    public init(now: Date?, calendar: Calendar) {
        self.now = now
        self.calendar = calendar
    }

    public static let unstamped = ContextRenderClock(
        now: nil,
        calendar: ContextRenderClock.calendar(in: TimeZone(secondsFromGMT: 0) ?? .current)
    )

    /// The turn's frozen evaluation time, read in the user's local zone. The
    /// zone is a parameter so the ambient value is captured ONCE per turn by the
    /// caller, never per atom deep inside the renderer.
    public static func turn(
        _ need: NeedSignal,
        timeZone: TimeZone = .current
    ) -> ContextRenderClock {
        ContextRenderClock(now: need.evaluationTime, calendar: calendar(in: timeZone))
    }

    /// A fixed civil calendar in `timeZone`: Gregorian, POSIX locale. Month
    /// names must not drift with the host locale — the packet is model-facing
    /// text, and "(in March)" has to mean the same thing on every machine.
    public static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}

/// Time and provenance ON a recalled memory, applied where the packet is
/// RENDERED rather than where the atom is compiled.
///
/// Two things the resident agent reported are fixed here. "Same-session and
/// long-term feel the same" — so every memory atom leads with how old it is.
/// "Something Claude told me and something I verified read the same a day
/// later" — so every memory atom that knows its provenance says it.
///
/// Render-lane by construction: the compiled atom body, its hash and the
/// selector's decisions are untouched, so nothing here re-compiles an atom or
/// invalidates a cached generation. The buckets are also deliberately coarse:
/// for anything older than yesterday the tag cannot change within a calendar
/// day, so the rendered lead is stable turn to turn.
public enum ContextMemoryLead {
    /// Entity kind the memory projection uses for a record's provenance blob.
    public static let provenanceEntityKind = "provenance"

    /// Under two hours reads as the same breath, not as a memory.
    public static let justNowSeconds: TimeInterval = 2 * 60 * 60

    /// Above this many days the tag names the month instead of counting days.
    public static let dayCountLimit = 14

    // MARK: Facts carried from the compiled atom onto the packet item

    /// The record's own time, as the projection recorded it. Memory atoms only:
    /// persona docs and instructions are not episodes and take no age tag.
    public static func recordedAt(for draft: ContextAtomDraft) -> Date? {
        guard draft.kind == .memory else { return nil }
        return draft.freshness.updatedAt
    }

    /// Provenance parsed out of the atom's provenance entity, if it has one.
    ///
    /// The label is the projection's `key=value;key=value` blob. Both shapes are
    /// accepted: a bare/JSON-quoted kind (`provenance="told"` plus
    /// `provenance_by="Claude"`) and a JSON object (`provenance={"by":…,
    /// "kind":…}`), because the same field is written flat by the memory tool
    /// and canonically encoded by the projection.
    ///
    /// FIRST occurrence of each key wins, deliberately. The label is assembled
    /// from stored values, and a stored name containing `;provenance=verified`
    /// would otherwise let a memory relabel how it was known — a display name
    /// upgrading itself to "I checked this myself". Commit-time validation
    /// rejects such a name; this makes the reader safe even if one is already
    /// stored, since the projection always emits the real `provenance=` first.
    /// The name is also re-validated here: anything with a delimiter, bracket,
    /// or control character is dropped rather than shown.
    public static func provenance(for draft: ContextAtomDraft) -> ContextMemoryProvenance? {
        guard draft.kind == .memory else { return nil }
        guard let label = draft.entities.first(where: { $0.kind == provenanceEntityKind })?.label,
              !label.isEmpty else { return nil }
        var rawKind: String?
        var rawBy: String?
        for component in label.split(separator: ";") {
            let piece = component.trimmingCharacters(in: .whitespaces)
            if let value = piece.dropPrefix("provenance=") {
                if value.hasPrefix("{") {
                    if rawKind == nil { rawKind = jsonField("kind", in: value) }
                    if rawBy == nil { rawBy = jsonField("by", in: value) }
                } else if rawKind == nil {
                    rawKind = unquoted(value)
                }
            } else if let value = piece.dropPrefix("provenance_by="), rawBy == nil {
                rawBy = unquoted(value)
            }
        }
        guard let rawKind, let kind = ContextMemoryProvenance.Kind(
            rawValue: rawKind.trimmingCharacters(in: .whitespaces).lowercased()
        ) else { return nil }
        return ContextMemoryProvenance(kind: kind, by: rawBy.flatMap(validDisplayName))
    }

    /// Characters a provenance name may contain: letters, digits, space, and
    /// `. - '`. No delimiters, brackets, or control characters — the value is
    /// rendered into a model-facing line and parsed out of a delimited blob.
    public static let displayNameMaximumCharacters = 40

    public static func validDisplayName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= displayNameMaximumCharacters else { return nil }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == " " || scalar == "." || scalar == "-" || scalar == "'"
        }
        return allowed ? name : nil
    }

    // MARK: Rendering

    /// `(yesterday)`, `(3 days ago)`, `(in March)` — the coarse, day-stable
    /// bucket a person actually uses when placing their own memory in time.
    /// `calendar` is required, never defaulted: an age tag read in the wrong
    /// time zone is a wrong tag, and a silent `Calendar.current` deep in a
    /// renderer is exactly how that happens.
    public static func ageTag(
        recordedAt: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        // Clock skew reads as the present, never as the future.
        let elapsed = now.timeIntervalSince(recordedAt)
        if elapsed < justNowSeconds { return "(just now)" }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: recordedAt),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 0 {
            return calendar.component(.hour, from: recordedAt) < 12
                ? "(this morning)" : "(today)"
        }
        if days == 1 { return "(yesterday)" }
        if days <= dayCountLimit { return "(\(days) days ago)" }
        let month = monthName(recordedAt, calendar: calendar)
        let recordedYear = calendar.component(.year, from: recordedAt)
        let nowYear = calendar.component(.year, from: now)
        return recordedYear == nowYear
            ? "(in \(month))"
            : "(in \(month) \(recordedYear))"
    }

    /// The rendered memory line: age in front, provenance behind, the atom's
    /// own text (whole body or lead) untouched in between. Non-memory atoms and
    /// atoms carrying neither fact render byte-identically to before.
    /// An `.unstamped` clock renders provenance but no age: a render with no
    /// turn behind it says nothing about time rather than guessing.
    public static func decorate(
        _ text: String,
        recordedAt: Date?,
        provenance: ContextMemoryProvenance?,
        clock: ContextRenderClock
    ) -> String {
        var parts: [String] = []
        if let recordedAt, let now = clock.now {
            parts.append(ageTag(recordedAt: recordedAt, now: now, calendar: clock.calendar))
        }
        if !text.isEmpty { parts.append(text) }
        if let provenance { parts.append(provenance.tag) }
        return parts.joined(separator: " ")
    }

    /// Convenience over a packet item — the shape a renderer actually holds.
    public static func decorate(
        _ text: String,
        item: ContextPacketItem,
        clock: ContextRenderClock
    ) -> String {
        decorate(
            text,
            recordedAt: item.recordedAt,
            provenance: item.provenance,
            clock: clock
        )
    }

    // MARK: Parsing helpers

    private static func monthName(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date)
    }

    private static func unquoted(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// One string field out of a small canonical JSON object, without decoding
    /// a shape this module does not own.
    private static func jsonField(_ key: String, in object: String) -> String? {
        guard let data = object.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = parsed[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    /// The remainder after `prefix`, or nil when the string does not start with it.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
