import SwiftUI
import PersistenceCore

extension DeskView {
    // MARK: GitHub Watcher — notification-only monitoring
    //
    // Directly below Waiting on you, above the bench (contract position).
    // Organized by who has the next move; healthy/waiting PRs collapse.

    private func ghBucketItems(_ bucket: DeskGitHubBucket) -> [GitHubCommandItem] {
        DeskGitHubPortfolioStrip.presentation(for: bucket, items: githubItems).renderedItems
    }

    var needsUserGitHubItems: [GitHubCommandItem] { ghBucketItems(.needsUser) }

    @ViewBuilder
    var githubCommandSection: some View {
        // Always visible (User, 2026-07-12: "this is just my window into
        // checking on what she's got with human eyes") — a monitoring surface
        // that hides itself when quiet reads as missing, not as quiet.
        sectionHeader(
            "GitHub Watcher",
            count: DeskGitHubPortfolioStrip.headerCount(items: githubItems),
            systemImage: "eye")
        switch DeskHonestyPresentation.githubLane(githubLane) {
        case .unavailable(let notice):
            laneUnavailableNotice(title: notice.title, detail: notice.detail)
        case .quiet(let copy):
            Text(copy)
                .font(.callout).foregroundStyle(.tertiary)
                .padding(.leading, 4)
        case .rows:
            ghPortfolioStrip
            ForEach(DeskGitHubBucket.inlineBuckets, id: \.rawValue) { bucket in
                let rows = ghBucketItems(bucket)
                if !rows.isEmpty {
                    ghSubheader(bucket.rawValue, count: rows.count,
                                tinted: bucket == .attention || bucket == .needsUser)
                    ForEach(rows, id: \.itemId) { ghItemRow($0) }
                }
            }
            ghWaitingCollapsed
            let resolved = ghBucketItems(DeskGitHubBucket.resolvedBucket)
            if !resolved.isEmpty {
                ghSubheader(DeskGitHubBucket.resolvedBucket.rawValue, count: resolved.count, tinted: false)
                ForEach(resolved, id: \.itemId) { ghItemRow($0) }
            }
        }
    }

    private var ghPortfolioStrip: some View {
        HStack(spacing: 10) {
            ForEach(DeskGitHubBucket.allCases, id: \.rawValue) { bucket in
                let presentation = DeskGitHubPortfolioStrip.presentation(for: bucket, items: githubItems)
                if presentation.renderedCount > 0 {
                    Text(presentation.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(bucket == .attention ? Color.red
                                         : bucket == .needsUser ? .orange : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func ghSubheader(_ title: String, count: Int, tinted: Bool) -> some View {
        Text("\(title)  ·  \(count)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tinted ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .padding(.top, 2)
    }

    // Waiting upstream: grouped by kind, collapsed by default (contract).
    @ViewBuilder
    private var ghWaitingCollapsed: some View {
        let waiting = ghBucketItems(DeskGitHubBucket.collapsedBucket)
        if !waiting.isEmpty {
            let toggleKey = DeskGitHubWaitingRollup.toggleKey
            let expanded = expandedRoots.contains(toggleKey)
            HStack(spacing: 8) {
                Text("Waiting upstream")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(GitHubCommandWaitingKind.allCases, id: \.rawValue) { kind in
                    let n = waiting.filter {
                        if case .waitingUpstream(let k) = $0.state { return k == kind }
                        return false
                    }.count
                    if n > 0 {
                        Text("\(DeskGitHubStatePillPresentation.waitingLabel(for: kind)) \(n)")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .naInteractive(radius: 8)
            .onTapGesture { toggle(toggleKey, expanded: expanded) }
            if expanded {
                ForEach(waiting, id: \.itemId) { ghItemRow($0) }
            }
        }
    }

    private func ghItemRow(_ item: GitHubCommandItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ghStatePill(item)
                Text(item.title.isEmpty ? "\(item.repository) #\(item.number)" : item.title)
                    .font(.body.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                Text(relativeTime(item.motorUpdatedAt ?? item.updatedAt))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Text("\(item.repository) #\(item.number) · \(item.kind == .pullRequest ? "PR" : "issue")")
                    .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                if let blocker = item.blocker {
                    Text("\(blocker.detail) — \(blocker.owner)")
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.tail)
                } else if let receipt = item.finalReceipt, !receipt.isEmpty {
                    Text(receipt)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else if let last = item.workLog.last {
                    Text(last.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.leading, 2)
            // Callback evidence is explicit: an absent provider error does
            // not erase a failed/no-final-result callback from the Desk row.
            if let callbackFailure = DeskGitHubCallbackFailurePresentation.detail(for: item) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(callbackFailure.message)
                        .font(.caption).foregroundStyle(.red)
                        .lineLimit(2).truncationMode(.tail)
                    if let noWork = callbackFailure.noWorkObserved {
                        Text(noWork ? "no work ran — resend safe" : "partial work possible")
                            .font(.caption2)
                            .foregroundStyle(noWork ? Color.secondary : Color.orange)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .id(DeskGitHubWaitingRollup.paletteHandle(for: item))
    }

    private func ghStatePill(_ item: GitHubCommandItem) -> some View {
        let pill = DeskGitHubStatePillPresentation.pill(for: item)
        return Text(pill.label)
            .capsuleTag(statusColor(pill.tone))
    }
}
