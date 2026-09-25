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
    private var completedInitialRead = false
    private var appearanceRead = false
    private var readGate = LatestAsyncRequestGate()

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
        await refresh(isAppearanceRead: false)
    }

    func loadOnAppearance() async {
        guard !completedInitialRead else { return }
        await refresh(isAppearanceRead: true)
    }

    func cancelAppearanceRead() {
        guard appearanceRead else { return }
        _ = readGate.begin()
        appearanceRead = false
        isRefreshing = false
    }

    private func refresh(isAppearanceRead: Bool) async {
        guard !Task.isCancelled else { return }
        guard !isRefreshing else { return }
        let request = readGate.begin()
        appearanceRead = isAppearanceRead
        isRefreshing = true
        lastRefreshError = nil
        defer {
            if readGate.accepts(request) {
                isRefreshing = false
                appearanceRead = false
            }
        }
        do {
            let loaded = try await statusReader(10)
            guard !Task.isCancelled, readGate.accepts(request) else { return }
            status = loaded
            completedInitialRead = true
        } catch {
            guard !Task.isCancelled, readGate.accepts(request) else { return }
            lastRefreshError = SecurityCenterRefreshPresentation.boundedDetail(error)
            completedInitialRead = true
        }
    }
}

struct NativeSecurityCenterPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var refreshModel: SecurityCenterRefreshState
    /// The kill switch as just flipped, held until the saved policy is re-read
    /// so the switch doesn't snap back mid-save.
    @State private var pendingKillSwitch: Bool?
    private let loadsOnAppear: Bool
    /// The Trust preset name for the live posture ("Full Mac"), so this panel
    /// never shows a second name for it ("Full mac os" was the raw level).
    private let modeTitle: String?

    init(
        statusReader: @escaping SecurityCenterStatusReader = Self.liveStatus,
        loadsOnAppear: Bool = true,
        modeTitle: String? = nil
    ) {
        _refreshModel = State(initialValue: SecurityCenterRefreshState(statusReader: statusReader))
        self.loadsOnAppear = loadsOnAppear
        self.modeTitle = modeTitle
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
                    // Full Mac is named once: the mode carries it, tinted when
                    // it is the live posture. A separate "Full Mac: Active"
                    // stat said the same thing a second time.
                    AdvancedStat(
                        title: "Mode",
                        value: status.fullMac ? "Full Mac" : (modeTitle ?? "Custom"),
                        status: status.fullMac ? "warn" : nil
                    )
                    AdvancedStat(
                        title: "Developer mode",
                        value: status.developerMode ? "On" : "Off",
                        detail: status.developerMode
                            ? "Destructive actions on this Mac are allowed. The riskiest setting."
                            : "",
                        status: status.developerMode ? "warn" : "ok"
                    )
                    // The reader tails the last N lines of the audit log;
                    // there is no time window, so say how far back they go.
                    AdvancedStat(
                        title: "Actions I logged",
                        value: status.recentReceipts.isEmpty ? "None yet" : "Last \(status.recentReceipts.count)",
                        detail: Self.receiptSpan(status.recentReceipts)
                    )
                }

                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    ForEach(status.flags) { flag in
                        if flag.id == "security_center" {
                            SecurityFlagRow(flag: flag, pause: Binding(
                                get: { pendingKillSwitch ?? status.killSwitchEnabled },
                                set: { setKillSwitch($0) }
                            ), pauseSaving: pendingKillSwitch != nil)
                        } else {
                            SecurityFlagRow(flag: flag)
                        }
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
                        Text("No security receipts yet. Every approval and block I handle is written here.")
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
            await refreshModel.loadOnAppearance()
        }
        .onDisappear { refreshModel.cancelAppearanceRead() }
    }

    private func setKillSwitch(_ on: Bool) {
        guard pendingKillSwitch == nil else { return }
        pendingKillSwitch = on
        Task {
            if await appModel.saveKillSwitchEnabled(on) {
                await refreshModel.refresh()
            }
            pendingKillSwitch = nil
        }
    }

    /// "Past 3 hr": how far the logged actions shown here reach.
    private static func receiptSpan(_ receipts: [SecurityReceiptSummary]) -> String {
        guard let oldest = receipts
            .compactMap({ UserDisplayFormatters.parseISOTimestamp($0.at) }).min()
        else { return "" }
        let span = DateComponentsFormatter()
        span.unitsStyle = .short
        span.maximumUnitCount = 1
        span.allowedUnits = [.minute, .hour, .day]
        return "Past " + (span.string(from: oldest, to: max(Date(), oldest.addingTimeInterval(60))) ?? "")
    }

    private static func liveStatus(limit: Int) async throws -> SecurityCenterStatus {
        await SwiftNativeSecurityCenter().status(limit: limit)
    }
}

/// One switch and where it stands. Was a grey plate with a dot AND a capsule
/// saying the same thing twice; the state is one word at the end of the row.
private struct SecurityFlagRow: View {
    var flag: SecurityStatusFlag
    /// Set only on "Pause everything": the row is then a real switch.
    var pause: Binding<Bool>? = nil
    var pauseSaving = false

    /// Plain words first, taken from each flag's own detail line; the
    /// engineering name stays underneath as a caption for anyone matching it
    /// to a setting.
    static func plainTitle(for id: String) -> String? {
        switch id {
        case "security_center": "Pause everything"
        // The detail already says "I check how risky each action is"; the
        // title names it instead of repeating it.
        case "capability_policy": "Risk check"
        case "origin_trust": "Requests from other devices"
        case "signed_remote_commands": "Risky requests from your iPhone"
        case "prompt_injection_shield": "Hidden instructions in what I read"
        default: nil
        }
    }

    var body: some View {
        let plain = Self.plainTitle(for: flag.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.md) {
                Text(plain ?? flag.title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(pause?.wrappedValue == true ? NativeAgentShell.trouble : NativeAgentShell.text)
                    .lineLimit(1)
                Spacer(minLength: NativeAgentSpacing.sm)
                if let pause {
                    Toggle(plain ?? flag.title, isOn: pause)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .hazeTinted()
                        .controlSize(.small)
                        .disabled(pauseSaving)
                } else {
                    StatusBadge(
                        text: flag.enabled ? flag.status : "off",
                        status: flag.enabled ? flag.status : "disabled"
                    )
                }
            }
            if plain != nil {
                Text(flag.title)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(1)
            }
            // The switch already says off; only a live pause earns its line.
            if pause.map({ $0.wrappedValue }) ?? true {
                Text(pause != nil ? "Everything is paused — I cannot take any action right now." : flag.detail)
                    .font(ShellType.label)
                    .foregroundStyle(pause != nil ? NativeAgentShell.trouble : NativeAgentShell.secondary)
                    .lineLimit(2)
            }
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
