import Foundation
import NativeAgentCore
// Blueprint: | `ContextMemoryLead.swift` | `ContextMemoryLead`: rendered age, provenance and source |

/// Render only recorded provenance: verified, told with its speaker, or inferred; unstamped rows make no claim.
public struct ContextMemoryProvenance: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
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

    public var text: String {
        if kind == .told, let by { return "told by \(by)" }
        return kind.rawValue
    }

    /// Context brackets the same wording recall returns as plain text.
    public var tag: String { "[\(text)]" }
}

/// Freeze time and calendar per turn so midnight and rerendering cannot change age tags. Without a turn clock, `.unstamped` claims no age.
public struct ContextRenderClock: Sendable, Equatable {
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

    /// Capture the user's time zone once per turn, never per atom.
    public static func turn(
        _ need: NeedSignal,
        timeZone: TimeZone = .current
    ) -> ContextRenderClock {
        ContextRenderClock(now: need.evaluationTime, calendar: calendar(in: timeZone))
    }

    /// Fixed Gregorian/POSIX formatting keeps model-facing month names independent of host locale.
    public static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}

/// Render age and provenance without changing compiled bodies, hashes or selection; coarse day buckets keep older age tags stable within a day.
public enum ContextMemoryLead {
    public static func untrustedSources(for draft: ContextAtomDraft) -> [String] {
        draft.entities.filter { $0.kind == "untrusted_source" && !$0.label.isEmpty }.map(\.label)
    }

    public static let provenanceEntityKind = "provenance"

    /// Under two hours reads as the same breath, not as a memory.
    public static let justNowSeconds: TimeInterval = 2 * 60 * 60

    public static let dayCountLimit = 14

    // MARK: Facts carried from the compiled atom onto the packet item

    /// Only episodic memory and correction atoms take age tags; persona documents and instructions do not.
    public static func recordedAt(for draft: ContextAtomDraft) -> Date? {
        guard draft.kind == .memory || draft.kind == .correction else { return nil }
        return draft.freshness.createdAt
    }

    /// Typed attribution and delimited labels carry provenance; evidence terminates the label prefix and must never be parsed as a field.
    public static func provenance(for draft: ContextAtomDraft) -> ContextMemoryProvenance? {
        guard draft.kind == .memory || draft.kind == .correction else { return nil }
        if let provenance = draft.memoryProvenance {
            return ContextMemoryProvenance(kind: provenance.kind, by: provenance.by.flatMap(validDisplayName))
        }
        guard let label = draft.entities.first(where: { $0.kind == provenanceEntityKind })?.label,
              !label.isEmpty else { return nil }
        var rawKind: String?
        var rawBy: String?
        for component in label.split(separator: ";") {
            let piece = component.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("evidence=") { break }
            if let value = piece.dropPrefix("provenance=") {
                if rawKind == nil { rawKind = unquoted(value) }
            } else if let value = piece.dropPrefix("provenance_by="), rawBy == nil {
                rawBy = unquoted(value)
            }
        }
        guard let rawKind, let kind = ContextMemoryProvenance.Kind(
            rawValue: rawKind.trimmingCharacters(in: .whitespaces).lowercased()
        ) else { return nil }
        return ContextMemoryProvenance(kind: kind, by: rawBy.flatMap(validDisplayName))
    }

    /// Exclude delimiters, brackets and controls because provenance names enter model-facing lines and delimited metadata.
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

    /// Require the turn's calendar: ambient time-zone reads can produce the wrong age tag.
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

    /// Preserve the atom's text between age and provenance; `.unstamped` renders provenance without guessing time.
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

    public static func decorate(
        _ text: String,
        item: ContextPacketItem,
        clock: ContextRenderClock
    ) -> String {
        MemoryDisplayText.attributed(decorate(
            text,
            recordedAt: item.recordedAt,
            provenance: item.provenance,
            clock: clock
        ), sources: item.untrustedSources ?? [])
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

}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
