import NativeAgentShared
import EngineRuntime
import Foundation
import SwiftUI
import TrustCenter

// Blueprint: | `SecurityCenterPanel.swift` | `NativeSecurityCenterPanel`: checked posture, kill-switch, flags and receipt presentation; local pending state lasts only through saved-policy reread |

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

struct NativeSecurityCenterPanel: View {
    @Environment(AppModel.self) private var appModel
    private var trust: TrustFacade { appModel.engine.trust }
    /// The kill switch as just flipped, held until the saved policy is re-read
    /// so the switch doesn't snap back mid-save.
    @State private var pendingKillSwitch: Bool?
    /// The Trust preset name for the live posture ("Full Mac"), so this panel
    /// never shows a second name for it ("Full mac os" was the raw level).
    private let modeTitle: String?

    init(modeTitle: String? = nil) {
        self.modeTitle = modeTitle
    }

    private var refreshState: SecurityCenterRefreshPresentation.State {
        SecurityCenterRefreshPresentation.state(
            hasStatus: trust.securityStatus != nil,
            isRefreshing: trust.isRefreshingSecurity,
            lastError: trust.securityRefreshError
        )
    }

    var body: some View {
        NativePanel(title: "Security Center") {
            if let status = trust.securityStatus {
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
                    // Display a tilde path and expose the full path in the tooltip.
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
                Button(trust.isRefreshingSecurity ? "Refreshing…" : "Refresh") {
                    Task { await trust.refreshSecurity() }
                }
                .buttonStyle(.bordered)
                .disabled(trust.isRefreshingSecurity)
                .accessibilityIdentifier("security.center.refresh")
                if trust.isRefreshingSecurity {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
        }
    }

    private func setKillSwitch(_ on: Bool) {
        guard pendingKillSwitch == nil else { return }
        pendingKillSwitch = on
        Task {
            if await appModel.saveKillSwitchEnabled(on) {
                await trust.refreshSecurity()
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
                    .foregroundStyle(NativeAgentShell.secondary)
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
            // Show relative time while retaining the raw ISO timestamp in the tooltip.
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
