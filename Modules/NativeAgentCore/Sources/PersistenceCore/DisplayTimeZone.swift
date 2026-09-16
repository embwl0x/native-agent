import Foundation

/// The one zone the app speaks in when it shows a time to a person.
///
/// Before this existed every people-facing formatter reached for
/// `TimeZone.current` independently, so there was nothing to set and nothing
/// to read back: the app simply spoke in whatever zone the Mac was in. That is
/// still the shipped behaviour — an unset identifier resolves to the Mac's own
/// zone — but it is now ONE named answer that the bots card, Today and the
/// morning brief share, so "what clock is the app speaking in?" has a single
/// truth and can be changed in one place.
///
/// Display only. Nothing persisted, scheduled or synced is formatted through
/// this: bot cron cadences carry their own IANA zone, and stored timestamps
/// stay UTC. Moving this zone changes what a person READS, never when anything
/// runs.
///
/// It lives in UserDefaults rather than the data root because it is a property
/// of this Mac's screen, not of the agent's memory.
public enum DisplayTimeZone {
    /// The `@AppStorage`-compatible key, so a settings control and this helper
    /// cannot drift apart.
    public static let key = "nativeagent.displayTimeZone"

    /// The saved IANA identifier, or "" when the app follows the Mac.
    ///
    /// An identifier the system does not recognise reads as "" rather than
    /// being handed on: a typo must fall back to the Mac's zone, never to GMT,
    /// because a silent several-hour shift in every time on screen is the one
    /// failure a person would not think to blame on a preference.
    public static func identifier(in defaults: UserDefaults = .standard) -> String {
        let raw = (defaults.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, TimeZone(identifier: raw) != nil else { return "" }
        return raw
    }

    /// Never nil, for the same reason.
    public static func resolved(in defaults: UserDefaults = .standard) -> TimeZone {
        let saved = identifier(in: defaults)
        guard !saved.isEmpty else { return TimeZone.current }
        return TimeZone(identifier: saved) ?? TimeZone.current
    }

    public static var current: TimeZone { resolved() }

    /// A calendar in the display zone, for the places that do people-facing day
    /// arithmetic ("this evening", "still waiting").
    public static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = resolved()
        return calendar
    }
}
