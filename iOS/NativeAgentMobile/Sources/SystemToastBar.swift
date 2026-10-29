import Foundation
import SwiftUI
import NativeAgentShared

public struct iOSSystemToastBar: View {
    private static let maxVisible = 3

    @ObservedObject var center: SystemToastCenter

    public init(center: SystemToastCenter) {
        self.center = center
    }

    public var body: some View {
        // Show the newest notices; dismissal timers start on push.
        let visibleToasts = Array(center.queue.suffix(Self.maxVisible))

        // The container coordinates sampling for stacked glass pills.
        GlassEffectContainer(spacing: 8) {
            pillStack(visibleToasts)
        }
    }

    private func pillStack(_ visibleToasts: [SystemToast]) -> some View {
        VStack(spacing: 8) {
            ForEach(visibleToasts) { toast in
                iOSSystemToastPill(toast: toast) {
                    center.dismiss(toast.id)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(AppMotion.snappy, value: center.queue.map(\.id))
        .allowsHitTesting(!center.queue.isEmpty)
        // The overlay caller keeps the status bar's safe area, so the stack
        // sits just under it on iPhone and iPad alike.
    }
}

private struct iOSSystemToastPill: View {
    let toast: SystemToast
    let onDismiss: () -> Void

    private var icon: String {
        switch toast.kind {
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Keep dismissal separate so VoiceOver can actuate it.
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(toast.kind == .error ? Color.red : AlivePalette.secondary)
                Text(toast.text)
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(toast.kind.rawValue.capitalized): \(toast.text)")

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AlivePalette.secondary)
                    .frame(minWidth: 44, minHeight: 44) // iOS touch target
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .aliveGlass(in: RoundedRectangle(cornerRadius: NativeAgentMobileTheme.Radius.composer, style: .continuous),
                    interactive: true, tint: AlivePalette.room.opacity(0.5))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Mac connection chip

// Connection presentation reads the phone's assessment without another fetch.

/// A compact connection indicator for a navigation bar. Every state is named:
/// a green dot alone makes a healthy connection look like unexplained chrome,
/// especially when the user has no reason to know the dot is tappable.
struct MacStatusChip: View {
    /// The chat header's status line: the agent says where it is, in its own
    /// words and the header's type, instead of an icon and a system label.
    var speaksAsAgent = false
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    private let sync = iCloudSyncEngine.shared
    @State private var showDetail = false

    private var connection: NAPhoneConnection { bridgeClient.connection }

    var body: some View {
        Button {
            showDetail = true
        } label: {
            Group {
                if speaksAsAgent {
                    Text(AliveConnection.line(connection))
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    Label(AliveConnection.line(connection), systemImage: connection.holds ? "checkmark.icloud" : "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A bare 8pt dot is far under the 44pt minimum target, so pad the
            // hit area without padding the visual.
            .contentShape(Rectangle())
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mac connection: \(AliveConnection.line(connection))")
        .popover(isPresented: $showDetail) {
            MacStatusDetail(connection: connection,
                            lastSeenAt: bridgeClient.lastSeenAt, lastSnapshotReadAt: sync.lastSyncAt)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct MacStatusDetail: View {
    let connection: NAPhoneConnection
    let lastSeenAt: Date?
    let lastSnapshotReadAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(connection.headline.state == .holds ? Color.green
                              : connection.headline.state == .waiting ? Color.orange : Color.red)
                    .frame(width: 9, height: 9)
                Text(AliveConnection.line(connection))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // The three facts, never one: what holds, what waits on whom.
            ForEach(connection.facts, id: \.label) { item in
                AliveConnectionFactLine(label: item.label, fact: item.fact)
            }
            if let lastSeenAt {
                LabeledContent("Mac last seen") {
                    Text(lastSeenAt, style: .relative).foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
            if let lastSnapshotReadAt {
                LabeledContent("Last snapshot read") {
                    Text(lastSnapshotReadAt, style: .relative).foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
        .padding(16)
        .frame(minWidth: 240, maxWidth: 300, alignment: .leading)
    }

}

// MARK: - Sync error banner

/// Shows the full engine warning; a new message or cleared error releases dismissal.
struct MacSyncErrorBanner: View {
    private let sync = iCloudSyncEngine.shared
    @State private var dismissedMessage: String?
    @State private var showsConnection = false

    private var message: String? {
        MacSyncErrorBannerPresentation.visibleMessage(
            syncError: sync.syncError,
            dismissedMessage: dismissedMessage
        )
    }

    var body: some View {
        Group {
            if let message {
                HStack(alignment: .top, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Sync warning: \(message)")
                    }
                    Button("Connection") { showsConnection = true }
                        .font(.footnote)
                        .buttonStyle(.plain)
                    Button {
                        dismissedMessage = message
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss sync warning")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(NativeAgentMobileTheme.Colors.contentSurface)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 0.5)
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(AppMotion.snappy, value: sync.syncError)
        .sheet(isPresented: $showsConnection) {
            NavigationStack { SettingsViewFull(opensConnection: true) }
        }
        // The latch must only survive as long as the condition does. Without
        // this, dismissing "snapshots still downloading", letting a sync
        // succeed, and then hitting the SAME failure again would leave the
        // banner permanently silent — a dismissal in one situation would
        // swallow a genuinely new occurrence later.
        .onChange(of: sync.syncError) { _, newValue in
            if MacSyncErrorBannerPresentation.normalizedMessage(newValue) == nil {
                dismissedMessage = nil
            }
        }
    }
}

enum MacSyncErrorBannerPresentation {
    static func normalizedMessage(_ syncError: String?) -> String? {
        guard let syncError else { return nil }
        let message = syncError.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    static func visibleMessage(syncError: String?, dismissedMessage: String?) -> String? {
        guard let message = normalizedMessage(syncError), message != dismissedMessage else {
            return nil
        }
        return message
    }
}

extension View {
    /// Pins `MacSyncErrorBanner` to the top of a screen without disturbing the
    /// layout underneath it (a `safeAreaInset` reflows scroll content rather
    /// than covering it, which matters on Chat where the last bubble must stay
    /// visible).
    func macSyncErrorBanner() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { MacSyncErrorBanner() }
    }
}
