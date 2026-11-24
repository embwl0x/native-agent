import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ContextMemoryLead.swift` | `ContextMemoryLead`: rendered age at the turn's pinned instant, roots and source |

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
        calendar: MemoryRoot.calendar(in: TimeZone(secondsFromGMT: 0) ?? .current)
    )

    /// Capture the user's time zone once per turn, never per atom. Fixed Gregorian/POSIX formatting keeps month names and root dates independent of
    /// host locale. Ages read the turn's own instant, never the selection bucket's end, which can already be tomorrow in a day's last minute.
    public static func turn(
        _ prepared: ContextPreparedTurn,
        timeZone: TimeZone = .current
    ) -> ContextRenderClock {
        ContextRenderClock(now: prepared.turnTime, calendar: MemoryRoot.calendar(in: timeZone))
    }
}

/// Render age and roots without changing compiled bodies, hashes or selection; coarse day buckets keep older age tags stable within a day.
public enum ContextMemoryLead {
    public static func untrustedSources(for draft: ContextAtomDraft) -> [String] {
        draft.entities.filter { $0.kind == "untrusted_source" && !$0.label.isEmpty }.map(\.label)
    }

    /// Under two hours reads as the same breath, not as a memory.
    public static let justNowSeconds: TimeInterval = 2 * 60 * 60

    public static let dayCountLimit = 14

    // MARK: Facts carried from the compiled atom onto the packet item

    /// Only episodic memory and correction atoms take age tags; persona documents and instructions do not.
    public static func recordedAt(for draft: ContextAtomDraft) -> Date? {
        guard draft.kind == .memory || draft.kind == .correction else { return nil }
        return draft.freshness.createdAt
    }

    /// A memory's roots travel on its compiled atom; other atoms carry none.
    public static func roots(for draft: ContextAtomDraft) -> [MemoryRoot]? {
        guard draft.kind == .memory || draft.kind == .correction else { return nil }
        return draft.memoryRoots
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

    /// Preserve the atom's text between age and roots; `.unstamped` renders roots without guessing time. Roots read as one bracket: one to three
    /// in full, past three the earliest, the latest and how many more.
    public static func decorate(
        _ text: String,
        recordedAt: Date?,
        roots: [MemoryRoot]?,
        clock: ContextRenderClock
    ) -> String {
        var parts: [String] = []
        if let recordedAt, let now = clock.now {
            parts.append(ageTag(recordedAt: recordedAt, now: now, calendar: clock.calendar))
        }
        if !text.isEmpty { parts.append(text) }
        if let lead = roots.flatMap({ MemoryRoot.lead(of: $0, calendar: clock.calendar) }) { parts.append("[\(lead)]") }
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
            roots: item.roots,
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
}
