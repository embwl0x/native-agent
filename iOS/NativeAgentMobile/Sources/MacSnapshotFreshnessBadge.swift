// E6 (upgrade-sweep 2026-08): one freshness badge for every screen that renders
// a Mac-owned iCloud snapshot.
//
// `StatusConnectionPresentation` (AdvancedView.swift) already had the staleness
// contract and the copy, but only AdvancedView and WorkshopView consumed it, so
// Desk / Memory / Approvals / Inbox / Knowledge Graph / Autonomy rendered an
// overnight-stale snapshot exactly like a measured-empty one. This lifts the
// existing presentation into a shared modifier — no new staleness rules.
import SwiftUI

/// Sweep 2026-09-01 item 2: a snapshot age is not the only way a screen lies.
/// The Mac publishes the groups it could NOT rebuild, and a screen whose group
/// is named there is showing old rows no matter how recently the phone synced.
enum MacSnapshotGroupStaleness {
    static let title = "STALE — the Mac could not rebuild this"

    /// The Mac's reason for this screen's group, or nil when the group built.
    static func reason(in markers: [String: String], group: String?) -> String? {
        guard let group, !group.isEmpty, let raw = markers[group] else { return nil }
        let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "The Mac could not rebuild this snapshot." : reason
    }
}

/// Renders nothing while the snapshot is fresh; a compact honest banner
/// otherwise. Time-based text is re-evaluated on a slow timeline so "4m old"
/// does not itself go stale on screen.
struct MacSnapshotFreshnessBadge: View {
    let lastSyncedAt: Date?
    /// The Mac's reason this screen's snapshot group was skipped, if it was.
    var staleGroupReason: String? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let state = StatusConnectionPresentation.syncState(
                lastSyncedAt: lastSyncedAt,
                now: context.date
            )
            // A named group failure outranks age: a Mac that published five
            // seconds ago can still have failed to rebuild THIS group.
            let title = staleGroupReason == nil
                ? StatusConnectionPresentation.cardValue(for: state)
                : MacSnapshotGroupStaleness.title
            let detail = staleGroupReason ?? StatusConnectionPresentation.detail(for: state)
            if staleGroupReason != nil || StatusConnectionPresentation.needsAttention(state) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(AppFont.label.weight(.semibold))
                        if let detail {
                            Text(detail)
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Mac snapshot freshness: " + title)
            }
        }
    }
}

private struct MacSnapshotFreshnessModifier: ViewModifier {
    @ObservedObject private var sync = iCloudSyncEngine.shared
    /// The Mac snapshot group this screen renders, when it has exactly one.
    let group: String?

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            MacSnapshotFreshnessBadge(
                lastSyncedAt: sync.lastSyncAt,
                staleGroupReason: MacSnapshotGroupStaleness.reason(
                    in: sync.staleSnapshotGroups,
                    group: group
                )
            )
        }
    }
}

extension View {
    /// Pin this screen's contents to the age of the Mac snapshot that produced
    /// them, and — when `group` names the snapshot group this screen renders —
    /// to whether the Mac could rebuild that group at all.
    func macSnapshotFreshnessBadge(group: String? = nil) -> some View {
        modifier(MacSnapshotFreshnessModifier(group: group))
    }
}
