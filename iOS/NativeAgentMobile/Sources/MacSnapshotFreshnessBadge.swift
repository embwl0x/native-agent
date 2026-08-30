// E6 (upgrade-sweep 2026-08): one freshness badge for every screen that renders
// a Mac-owned iCloud snapshot.
//
// `StatusConnectionPresentation` (AdvancedView.swift) already had the staleness
// contract and the copy, but only AdvancedView and WorkshopView consumed it, so
// Desk / Memory / Approvals / Inbox / Knowledge Graph / Autonomy rendered an
// overnight-stale snapshot exactly like a measured-empty one. This lifts the
// existing presentation into a shared modifier — no new staleness rules.
import SwiftUI

/// Renders nothing while the snapshot is fresh; a compact honest banner
/// otherwise. Time-based text is re-evaluated on a slow timeline so "4m old"
/// does not itself go stale on screen.
struct MacSnapshotFreshnessBadge: View {
    let lastSyncedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let state = StatusConnectionPresentation.syncState(
                lastSyncedAt: lastSyncedAt,
                now: context.date
            )
            if StatusConnectionPresentation.needsAttention(state) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(StatusConnectionPresentation.cardValue(for: state))
                            .font(AppFont.label.weight(.semibold))
                        if let detail = StatusConnectionPresentation.detail(for: state) {
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
                .accessibilityLabel(
                    "Mac snapshot freshness: "
                        + StatusConnectionPresentation.cardValue(for: state)
                )
            }
        }
    }
}

private struct MacSnapshotFreshnessModifier: ViewModifier {
    @ObservedObject private var sync = iCloudSyncEngine.shared

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            MacSnapshotFreshnessBadge(lastSyncedAt: sync.lastSyncAt)
        }
    }
}

extension View {
    /// Pin this screen's contents to the age of the Mac snapshot that produced
    /// them. Apply to the root content of any screen reading `iCloudSyncEngine`.
    func macSnapshotFreshnessBadge() -> some View {
        modifier(MacSnapshotFreshnessModifier())
    }
}
