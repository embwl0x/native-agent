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
        NativePanel(title: "Security Center", systemImage: "shield.lefthalf.filled", tint: panelTint) {
            if let status = refreshModel.status {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    TrustPolicyTile(title: "Mode", value: status.mode, systemImage: "switch.2")
                    TrustPolicyTile(title: "Full Mac", value: status.fullMac ? "active" : "limited", systemImage: "macbook")
                    TrustPolicyTile(title: "Developer", value: status.developerMode ? "on" : "off", systemImage: "terminal")
                    TrustPolicyTile(title: "Receipts", value: status.recentReceipts.isEmpty ? "ready" : "\(status.recentReceipts.count) recent", systemImage: "doc.text.magnifyingglass")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                    ForEach(status.flags) { flag in
                        SecurityFlagRow(flag: flag)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    // ui-taste-sweep 2026-06-07: was exposing the full
                    // /Users/<home>/Library/... path. Tildify it and use the
                    // tooltip for the full path power users may want to copy.
                    Text(UserDisplayFormatters.tildifyPath(status.auditReceiptsPath))
                        .font(NativeAgentFont.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(status.auditReceiptsPath)

                    if status.recentReceipts.isEmpty {
                        Text("No security receipts yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(status.recentReceipts.prefix(5)) { receipt in
                            SecurityReceiptRow(receipt: receipt)
                        }
                    }
                }
            } else {
                switch refreshState {
                case .unavailable(let detail):
                    Label(
                        SecurityCenterRefreshPresentation.message(for: .unavailable(detail: detail)) ?? "Security status unavailable.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("security.center.refresh.unavailable")
                case .loading, .refreshing, .current, .stale:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading security status...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            switch refreshState {
            case .refreshing:
                Label(
                    SecurityCenterRefreshPresentation.message(for: refreshState) ?? "Refreshing security status…",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("security.center.refresh.inflight")
            case .stale(let detail):
                Label(
                    SecurityCenterRefreshPresentation.message(for: .stale(detail: detail))
                        ?? "Showing the last security status; refresh failed.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("security.center.refresh.stale")
            case .loading, .current, .unavailable:
                EmptyView()
            }

            HStack {
                Button(refreshModel.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") {
                    Task { await refreshModel.refresh() }
                }
                .disabled(refreshModel.isRefreshing)
                .accessibilityIdentifier("security.center.refresh")
                Spacer()
                if refreshModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .task {
            guard loadsOnAppear else { return }
            await refreshModel.refresh()
        }
    }

    private var panelTint: Color {
        guard let status = refreshModel.status else {
            if case .unavailable = refreshState { return .orange }
            return .blue
        }
        if status.killSwitchEnabled { return .red }
        if status.developerMode { return .orange }
        return .green
    }

    private static func liveStatus(limit: Int) async throws -> SecurityCenterStatus {
        await SwiftNativeSecurityCenter().status(limit: limit)
    }
}

private struct SecurityFlagRow: View {
    var flag: SecurityStatusFlag

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            InlineStatusDot(status: flag.status)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(flag.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    StatusBadge(text: flag.enabled ? flag.status : "off", status: flag.enabled ? flag.status : "disabled")
                }
                Text(flag.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }
}

private struct SecurityReceiptRow: View {
    var receipt: SecurityReceiptSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusBadge(text: receipt.decision, status: receipt.decision)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(receipt.tool) · \(receipt.surface) · \(receipt.risk)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if !receipt.reason.isEmpty {
                    Text(receipt.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // ui-taste-sweep 2026-06-07: receipt.at is raw ISO with
                // fractional seconds + timezone offset. Show relative phrase
                // (uses the shared formatter that landed in batch 2), keep
                // raw ISO in the tooltip for power users.
                Text(UserDisplayFormatters.humanizeISOTimestamp(receipt.at))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(receipt.at)
            }
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
    }
}
