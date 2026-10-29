// Pages share StatusConnectionPresentation's freshness policy through
// AlivePage(freshnessGroup:) or AliveFreshnessNote(group:).
import SwiftUI
import NativeAgentShared

/// A Mac-reported group rebuild failure marks its rows stale regardless of sync age.
enum MacSnapshotGroupStaleness {
    /// The Mac's reason for this screen's group, or nil when the group built.
    static func reason(in markers: [String: String], group: String?) -> String? {
        guard let group, !group.isEmpty, let raw = markers[group] else { return nil }
        let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? NAMobileSnapshotGroup.stalePageMessage(group) : reason
    }
}

/// The page note's words; StatusConnectionPresentation owns classification.
enum MacSnapshotPageFreshness {
    /// "12 minutes", "2 hours", "3 days".
    static func spokenAge(_ interval: TimeInterval) -> String {
        guard interval.isFinite, let seconds = Int(exactly: max(0, interval).rounded(.towardZero)) else { return "an unknown interval" }
        if seconds < 60 { return AliveWords.count(seconds, "second") }
        if seconds < 3_600 { return AliveWords.count(seconds / 60, "minute") }
        if seconds < 86_400 { return AliveWords.count(seconds / 3_600, "hour") }
        return AliveWords.count(seconds / 86_400, "day")
    }

    static func line(for state: StatusConnectionPresentation.SyncState) -> String {
        switch state {
        case .current(let age): return "Last updated \(spokenAge(age)) ago"
        case .stale(let age, _): return "Hasn\u{2019}t updated in \(spokenAge(age))"
        case .neverSynced: return "Nothing has arrived from your Mac yet"
        case .clockMismatch: return "Your Mac\u{2019}s clock and this iPhone\u{2019}s disagree"
        }
    }
}

/// Renders nothing while the snapshot is fresh; a quiet honest note
/// otherwise. Time-based text is re-evaluated on a slow timeline so "4m old"
/// does not itself go stale on screen.
struct MacSnapshotFreshnessBadge: View {
    @State private var showsConnection = false
    let lastSyncedAt: Date?
    /// The Mac's reason this screen's snapshot group was skipped, if it was.
    var staleGroupReason: String? = nil

    var body: some View {
        TimelineView(MacSnapshotFreshnessSchedule(lastSyncedAt: lastSyncedAt, fixed: staleGroupReason != nil)) { context in
            let state = StatusConnectionPresentation.syncState(lastSyncedAt: lastSyncedAt, now: context.date)
            // A named group failure outranks age: a Mac that published five
            // seconds ago can still have failed to rebuild THIS group.
            let title = staleGroupReason ?? MacSnapshotPageFreshness.line(for: state)
            if staleGroupReason != nil || StatusConnectionPresentation.needsAttention(state) {
                // Said once under the page's header in secondary text: a
                // note, not a band.
                AliveStatusNote(text: title, actionTitle: staleGroupReason == nil ? nil : "Connection",
                                action: { showsConnection = true })
                    .accessibilityElement(children: staleGroupReason == nil ? .combine : .contain)
                    .accessibilityLabel("Mac snapshot freshness: " + title)
            }
        }
        .sheet(isPresented: $showsConnection) {
            NavigationStack { SettingsViewFull(opensConnection: true) }
        }
    }
}

struct MacSnapshotFreshnessSchedule: TimelineSchedule {
    let lastSyncedAt: Date?
    var fixed = false
    var showsFreshAge = false

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        AnySequence {
            var next: Date? = startDate
            return AnyIterator<Date> {
                guard let date = next else { return nil }
                defer {
                    if fixed || lastSyncedAt == nil { next = nil }
                    else if let lastSyncedAt {
                        let age = date.timeIntervalSince(lastSyncedAt)
                        let unit: TimeInterval = showsFreshAge && age < 60 ? 15 : age < 3_600 ? 60 : age < 86_400 ? 3_600 : 86_400
                        if age < -60 { next = lastSyncedAt.addingTimeInterval(-60) }
                        else {
                            let threshold = lastSyncedAt.addingTimeInterval(StatusConnectionPresentation.staleAfter)
                            let stale = Date(timeIntervalSinceReferenceDate: threshold.timeIntervalSinceReferenceDate.nextUp)
                            let changedText = lastSyncedAt.addingTimeInterval(max(unit, (floor(age / unit) + 1) * unit))
                            next = age <= StatusConnectionPresentation.staleAfter
                                ? (showsFreshAge ? min(changedText, stale) : stale) : changedText
                        }
                    }
                }
                return date
            }
        }
    }
}
