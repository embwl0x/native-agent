import Foundation

/// One lifecycle for every capability she has, her skills and the tools she
/// wrote (User, 10-03: "a system that tools and skills can be added, upgraded,
/// retired"). Each store keeps its own rows; the decisions are these.
///
/// - Draft → on → archived. Archived is never deleted: it doesn't run, it
///   stays findable marked archived, and one call restores it.
/// - Use: a skill's run or `skill.read` (a recall pointer's one act is that
///   read), a tool's call. Turning one on restarts the clock.
/// - Unused for `unusedDays` → archived, every kind.
/// - Upgrade is a new version with the previous kept: approval and the trust
///   ladder start over, and rollback brings the previous back drafted.
public enum CapabilityLifecycle {
    public static let unusedDays = 30
    public static let archived = "archived"

    /// Use was recorded for every kind from this day (2026-10-03); nothing
    /// counts as unused from before it.
    static let useRecordedSince = Date(timeIntervalSince1970: 1_790_985_600)

    /// The clock: the later of its last use (else its last change) and its
    /// last turning on.
    public static func clock(used: String?, enabled: [String?]) -> Date {
        ([date(used)] + enabled.map(date)).compactMap { $0 }.reduce(useRecordedSince, max)
    }

    public static func isUnused(used: String?, enabled: [String?], now: Date, days: Int = unusedDays) -> Bool {
        clock(used: used, enabled: enabled) < now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// World stops an upgrade could fix. A decide and a floor hand-back
    /// (would_card, irreversible, users_step) never count.
    public static let worldStops: Set<String> = ["state_changed", "stale_version"]

    /// `reason@step` when the same world stop at the same step ended 2 of the
    /// last 3 runs (`runs` oldest first, each `reason@step`).
    public static func repeatedStop(_ runs: [String]) -> String? {
        let last = runs.suffix(3).filter { worldStops.contains(String($0.split(separator: "@").first ?? "")) }
        return Dictionary(grouping: last, by: { $0 }).first { $0.value.count >= 2 }?.key
    }

    /// A new version that faults offers the last clean one back.
    public static func offersRollback(digest: String, faulted: Bool, lastClean: String?) -> Bool {
        faulted && lastClean != nil && lastClean != digest
    }

    /// The versions a store keeps, never more (User: bounded in code): the
    /// newest copy of each distinct version, the newest `recent` of those
    /// (current and previous), and the last clean one. `versions` oldest
    /// first, each its key and the digest a clean run names; returns the
    /// indices kept, in order.
    public static func keptVersions(_ versions: [(key: String, digest: String?)], recent: Int, clean: String?) -> [Int] {
        var newest: [String: Int] = [:]
        for (i, version) in versions.enumerated() { newest[version.key] = i }
        var kept = Set(newest.values.sorted().suffix(recent))
        if let clean, let last = versions.lastIndex(where: { $0.digest == clean }) { kept.insert(last) }
        return kept.sorted()
    }

    /// The ladder's distinct inputs a row keeps.
    public static let inputLimit = 10

    /// A tool's failures in a row that ask whether to improve it, once per streak.
    public static let toolFailureStreak = 2

    /// ISO-8601, with or without fractional seconds.
    public static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)
    }
}
