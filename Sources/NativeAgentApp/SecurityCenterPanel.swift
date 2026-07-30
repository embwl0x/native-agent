import SwiftUI
import TrustCenter

struct NativeSecurityCenterPanel: View {
    @State private var status: SecurityCenterStatus?
    @State private var isRefreshing = false
    private let securityCenter = SwiftNativeSecurityCenter()

    var body: some View {
        NativePanel(title: "Security Center", systemImage: "shield.lefthalf.filled", tint: panelTint) {
            if let status {
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
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading security status...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(isRefreshing)
                Spacer()
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .task {
            await refresh()
        }
    }

    private var panelTint: Color {
        guard let status else { return .blue }
        if status.killSwitchEnabled { return .red }
        if status.developerMode { return .orange }
        return .green
    }

    @MainActor
    private func refresh() async {
        isRefreshing = true
        status = await securityCenter.status(limit: 10)
        isRefreshing = false
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
