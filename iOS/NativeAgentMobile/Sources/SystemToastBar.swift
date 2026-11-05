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
        let visibleToasts = Array(center.queue.suffix(Self.maxVisible))

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
        // The overlay caller preserves status-bar safe area so the stack stays beneath it on phone and tablet.
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
                    .frame(minWidth: 44, minHeight: 44) // Preserve the minimum iOS touch target.
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


/// Name every connection state so a healthy dot still explains its meaning and tappability.
struct MacStatusChip: View {
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
            // Pad the 8pt dot's hit area to 44pt without changing its visual size.
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

/// Release dismissal on changed/cleared engine warnings so new failures remain visible.
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
                // Keep guidance full-width and actions on their own row so compact layouts do not squeeze either.
                let split = MacSyncErrorBannerPresentation.headline(message)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(AlivePalette.secondary)
                            .accessibilityHidden(true)
                        Text(split.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AlivePalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            dismissedMessage = message
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AlivePalette.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss sync warning")
                    }
                    if let detail = split.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(AlivePalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Connection") { showsConnection = true }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                }
                .padding(14)
                .aliveGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .accessibilityLabel("Sync warning: \(message)")
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(AppMotion.snappy, value: sync.syncError)
        .sheet(isPresented: $showsConnection) {
            NavigationStack { SettingsViewFull(opensConnection: true) }
        }
        // Clear dismissal with its condition so a later occurrence of the same sync failure can show again.
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

    static func headline(_ message: String) -> (headline: String, detail: String?) {
        guard let end = message.range(of: ". ") else { return (message, nil) }
        let detail = message[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(message[..<end.upperBound]).trimmingCharacters(in: .whitespaces), detail.isEmpty ? nil : detail)
    }

    static func visibleMessage(syncError: String?, dismissedMessage: String?) -> String? {
        guard let message = normalizedMessage(syncError), message != dismissedMessage else {
            return nil
        }
        return message
    }
}

extension View {
    /// Use safeAreaInset so banners reflow Chat instead of covering the last bubble.
    func macSyncErrorBanner() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { MacSyncErrorBanner() }
    }
}
