import Foundation
import Observation
import SwiftUI
import TrustCenter

typealias SecurityCenterStatusReader = @Sendable (Int) async throws -> SecurityCenterStatus

enum SecurityCenterRefreshPresentation {
    enum State: Equatable {
        case loading
        case refreshing
        case current
        case stale(detail: String)
        case unavailable(detail: String)
    }

    static func state(
        hasStatus: Bool,
        isRefreshing: Bool,
        lastError: String?
    ) -> State {
        if isRefreshing { return hasStatus ? .refreshing : .loading }
        if let lastError, !lastError.isEmpty {
            return hasStatus ? .stale(detail: lastError) : .unavailable(detail: lastError)
        }
        return hasStatus ? .current : .loading
    }

    static func boundedDetail(_ error: any Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "The security reader returned no details." : String(detail.prefix(240))
    }

    static func message(for state: State) -> String? {
        switch state {
        case .loading, .current:
            return nil
        case .refreshing:
            return "Refreshing security status…"
        case let .stale(detail):
            return "Showing the last security status; refresh failed: \(detail)"
        case let .unavailable(detail):
            return "Security status unavailable: \(detail)"
        }
    }
}

/// The root-scoped state behind Security Center's one refresh affordance. The
/// previous readable snapshot deliberately survives a failed refresh, while a
/// failed first read remains unavailable rather than being presented as empty.
@MainActor @Observable
final class SecurityCenterRefreshState {
    private(set) var status: SecurityCenterStatus?
    private(set) var isRefreshing = false
    private(set) var lastRefreshError: String?
    private let statusReader: SecurityCenterStatusReader

    init(statusReader: @escaping SecurityCenterStatusReader) {
        self.statusReader = statusReader
    }

    var presentation: SecurityCenterRefreshPresentation.State {
        SecurityCenterRefreshPresentation.state(
            hasStatus: status != nil,
            isRefreshing: isRefreshing,
            lastError: lastRefreshError
        )
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshError = nil
        defer { isRefreshing = false }
        do {
            status = try await statusReader(10)
        } catch {
            lastRefreshError = SecurityCenterRefreshPresentation.boundedDetail(error)
        }
    }
}

struct NativeSecurityCenterPanel: View {
    @State private var refreshModel: SecurityCenterRefreshState
    private let loadsOnAppear: Bool

    init(
        statusReader: @escaping SecurityCenterStatusReader = Self.liveStatus,
        loadsOnAppear: Bool = true
    ) {
        _refreshModel = State(initialValue: SecurityCenterRefreshState(statusReader: statusReader))
        self.loadsOnAppear = loadsOnAppear
    }

    private var refreshState: SecurityCenterRefreshPresentation.State {
        refreshModel.presentation
    }

    var body: some View {
        NativePanel(title: "Security Center", systemImage: "shield.lefthalf.filled") {
            if let status = refreshModel.status {
                // The four counts were tinted tiles in a grid — a plate each,
                // inside the card. They are bare stat rows now.
                HStack(alignment: .top, spacing: NativeAgentSpacing.xl) {
                    AdvancedStat(title: "Mode", value: AdvancedStatusWords.label(status.mode))
                    AdvancedStat(
                        title: "Full Mac",
                        value: status.fullMac ? "Active" : "Limited",
                        status: status.fullMac ? "warn" : "ok"
                    )
                    AdvancedStat(
                        title: "Developer",
                        value: status.developerMode ? "On" : "Off",
                        status: status.developerMode ? "warn" : "ok"
                    )
                    AdvancedStat(
                        title: "Receipts",
                        value: status.recentReceipts.isEmpty ? "None yet" : "\(status.recentReceipts.count)",
                        detail: status.recentReceipts.isEmpty ? "" : "Recent"
                    )
                }

                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    ForEach(status.flags) { flag in
                        SecurityFlagRow(flag: flag)
                    }
                }

                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    // ui-taste-sweep 2026-06-07: was exposing the full
                    // /Users/<home>/Library/... path. Tildify it and use the
                    // tooltip for the full path power users may want to copy.
                    Text(UserDisplayFormatters.tildifyPath(status.auditReceiptsPath))
                        .font(ShellType.code)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(status.auditReceiptsPath)

                    if status.recentReceipts.isEmpty {
                        Text("No security receipts yet. Every approval and block the agent handles is written here.")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(status.recentReceipts.prefix(5)) { receipt in
                            SecurityReceiptRow(receipt: receipt)
                        }
                    }
                }
            } else {
                switch refreshState {
                case .unavailable(let detail):
                    Text(SecurityCenterRefreshPresentation.message(for: .unavailable(detail: detail)) ?? "Security status unavailable.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("security.center.refresh.unavailable")
                case .loading, .refreshing, .current, .stale:
                    HStack(spacing: NativeAgentSpacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading security status…")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                }
            }

            switch refreshState {
            case .refreshing:
                Text(SecurityCenterRefreshPresentation.message(for: refreshState) ?? "Refreshing security status…")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .accessibilityIdentifier("security.center.refresh.inflight")
            case .stale(let detail):
                Text(SecurityCenterRefreshPresentation.message(for: .stale(detail: detail))
                    ?? "Showing the last security status; refresh failed.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("security.center.refresh.stale")
            case .loading, .current, .unavailable:
                EmptyView()
            }

            HStack(spacing: NativeAgentSpacing.sm) {
                Button(refreshModel.isRefreshing ? "Refreshing…" : "Refresh") {
                    Task { await refreshModel.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(refreshModel.isRefreshing)
                .accessibilityIdentifier("security.center.refresh")
                if refreshModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
        }
        .task {
            guard loadsOnAppear else { return }
            await refreshModel.refresh()
        }
    }

    private static func liveStatus(limit: Int) async throws -> SecurityCenterStatus {
        await SwiftNativeSecurityCenter().status(limit: limit)
    }
}

/// One switch and where it stands. Was a grey plate with a dot AND a capsule
/// saying the same thing twice; the state is one word at the end of the row.
private struct SecurityFlagRow: View {
    var flag: SecurityStatusFlag

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.md) {
                Text(flag.title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer(minLength: NativeAgentSpacing.sm)
                StatusBadge(
                    text: flag.enabled ? flag.status : "off",
                    status: flag.enabled ? flag.status : "disabled"
                )
            }
            Text(flag.detail)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct SecurityReceiptRow: View {
    var receipt: SecurityReceiptSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.md) {
                Text("\(receipt.tool) · \(receipt.surface) · \(receipt.risk)")
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer(minLength: NativeAgentSpacing.sm)
                StatusBadge(text: receipt.decision, status: receipt.decision)
            }
            if !receipt.reason.isEmpty {
                Text(receipt.reason)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
            // ui-taste-sweep 2026-06-07: receipt.at is raw ISO with
            // fractional seconds + timezone offset. Show relative phrase
            // (uses the shared formatter that landed in batch 2), keep
            // raw ISO in the tooltip for power users.
            Text(UserDisplayFormatters.humanizeISOTimestamp(receipt.at))
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.tertiary)
                .lineLimit(1)
                .help(receipt.at)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
