import SwiftUI
import NativeAgentShared

/// A Mac-reported group rebuild failure marks its rows stale regardless of sync age.
enum MacSnapshotGroupStaleness {
    static func reason(in markers: [String: String], group: String?) -> String? {
        guard let group, !group.isEmpty, let raw = markers[group] else { return nil }
        let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? NAMobileSnapshotGroup.stalePageMessage(group) : reason
    }
}

enum MacSnapshotPageFreshness {
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

/// Use a slow timeline so stale-age wording stays accurate without frequent redraws.
struct MacSnapshotFreshnessBadge: View {
    @State private var showsConnection = false
    let lastSyncedAt: Date?
    var staleGroupReason: String? = nil

    var body: some View {
        TimelineView(MacSnapshotFreshnessSchedule(lastSyncedAt: lastSyncedAt, fixed: staleGroupReason != nil)) { context in
            let state = StatusConnectionPresentation.syncState(lastSyncedAt: lastSyncedAt, now: context.date)
            // A named group rebuild failure outranks sync age; a recent publication can still contain stale group rows.
            let title = staleGroupReason ?? MacSnapshotPageFreshness.line(for: state)
            if staleGroupReason != nil || StatusConnectionPresentation.needsAttention(state) {
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
