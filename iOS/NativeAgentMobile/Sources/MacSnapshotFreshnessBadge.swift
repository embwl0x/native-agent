// E6 (upgrade-sweep 2026-08): one freshness badge for every screen that renders
// a Mac-owned iCloud snapshot.
//
// `StatusConnectionPresentation` (AdvancedView.swift) already had the staleness
// contract and the copy, but only AdvancedView and WorkshopView consumed it, so
// Desk / Memory / Approvals / Inbox / Knowledge Graph / Autonomy rendered an
// overnight-stale snapshot exactly like a measured-empty one. This lifts the
// existing presentation into one shared note — no new staleness rules. Pages
// mount it under their header with `AlivePage(freshnessGroup:)` or
// `AliveFreshnessNote(group:)` (AliveKit.swift).
import SwiftUI
import NativeAgentShared

/// Sweep 2026-09-01 item 2: a snapshot age is not the only way a screen lies.
/// The Mac publishes the groups it could NOT rebuild, and a screen whose group
/// is named there is showing old rows no matter how recently the phone synced.
enum MacSnapshotGroupStaleness {
    /// The Mac's reason for this screen's group, or nil when the group built.
    static func reason(in markers: [String: String], group: String?) -> String? {
        guard let group, !group.isEmpty, let raw = markers[group] else { return nil }
        let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? NAMobileSnapshotGroup.stalePageMessage(group) : reason
    }
}

/// The page note's words and patience: iCloud delivery is not instant, so a
/// page only calls itself old after a few minutes, and says so plainly.
enum MacSnapshotPageFreshness {
    static let staleAfter: TimeInterval = 5 * 60

    static func state(lastSyncedAt: Date?, now: Date = Date()) -> StatusConnectionPresentation.SyncState {
        StatusConnectionPresentation.syncState(lastSyncedAt: lastSyncedAt, now: now, staleAfter: staleAfter)
    }

    /// "12 minutes", "2 hours", "3 days".
    static func spokenAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
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
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let state = MacSnapshotPageFreshness.state(lastSyncedAt: lastSyncedAt, now: context.date)
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
