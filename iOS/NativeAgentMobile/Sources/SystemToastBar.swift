// SystemToastBar.swift — iOS parity for the Mac SystemToastBar.
//
// Mirrors Sources/NativeAgentApp/SystemToastBar.swift: same `SystemToast`
// shape (info/warn/error/success), same auto-dismiss semantics, same
// replace-by-id behavior so a sticky re-push of an auto-dismissing toast
// doesn't get killed by the old timer.
//
// Differences from the Mac version:
//   • Renamed types — `iOSSystemToast`, `iOSSystemToastCenter`,
//     `iOSSystemToastBar` — so this file can coexist with the shared
//     Mac type names if either side later gets pulled into a shared
//     module.
//   • Bottom-of-screen safe-area-aware overlay (Mac shows under the
//     title bar; iOS shows above the home indicator).
//   • Taller hit target on the dismiss X (44 pt minimum).
//
// Wired as an overlay on ContentView's TabView root.

import Foundation
import SwiftUI

@MainActor
public struct iOSSystemToast: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: Kind
    public let text: String
    public let createdAt: Date
    public let autoDismissAfter: TimeInterval?

    public enum Kind: String, Sendable { case info, warn, error, success }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        createdAt: Date = Date(),
        autoDismissAfter: TimeInterval? = 3
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.autoDismissAfter = autoDismissAfter
    }

    public nonisolated static func == (lhs: iOSSystemToast, rhs: iOSSystemToast) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
public final class iOSSystemToastCenter: ObservableObject {
    public static let shared = iOSSystemToastCenter()

    @Published public private(set) var queue: [iOSSystemToast] = []

    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    static func dismissDelayNanoseconds(after: TimeInterval?) -> UInt64? {
        guard let after, after.isFinite, after > 0 else { return nil }
        let nanoseconds = after * 1_000_000_000
        guard nanoseconds <= Double(UInt64.max) else { return nil }
        return UInt64(nanoseconds)
    }

    public func push(_ toast: iOSSystemToast) {
        // Replace-by-id semantics — match the Mac SystemToastCenter so a
        // re-push of the same id (rare but possible if a caller hand-stamps
        // an id for sticky updates) doesn't see the old timer kill the new
        // entry, and ForEach doesn't trip on duplicate ids.
        dismissTasks.removeValue(forKey: toast.id)?.cancel()
        queue.removeAll { $0.id == toast.id }
        queue.append(toast)

        guard let delay = Self.dismissDelayNanoseconds(after: toast.autoDismissAfter) else { return }
        dismissTasks[toast.id] = Task {
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            self.dismiss(toast.id)
        }
    }

    public func push(info text: String, autoDismissAfter: TimeInterval? = 3) {
        push(iOSSystemToast(kind: .info, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func push(warn text: String, autoDismissAfter: TimeInterval? = 5) {
        push(iOSSystemToast(kind: .warn, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func push(error text: String, autoDismissAfter: TimeInterval? = 8) {
        push(iOSSystemToast(kind: .error, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func push(success text: String, autoDismissAfter: TimeInterval? = 3) {
        push(iOSSystemToast(kind: .success, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func dismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        queue.removeAll { $0.id == id }
    }

    public func dismissAll() {
        for task in dismissTasks.values { task.cancel() }
        dismissTasks.removeAll()
        queue.removeAll()
    }
}

public struct iOSSystemToastBar: View {
    private static let maxVisible = 3

    @ObservedObject var center: iOSSystemToastCenter

    public init(center: iOSSystemToastCenter) {
        self.center = center
    }

    public var body: some View {
        // Show NEWEST toasts when capped. Mirrors the Mac SystemToastBar
        // 2026-06-06 fix where prefix(3) could let a 4th short-lived toast
        // dismiss before ever being seen.
        let visibleToasts = Array(center.queue.suffix(Self.maxVisible))

        // Liquid Glass pilot (2026-07-02): stacked glass pills must live in
        // a GlassEffectContainer — glass can't sample other glass, the
        // container coordinates the shared sampling region.
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                pillStack(visibleToasts)
            }
        } else {
            pillStack(visibleToasts)
        }
    }

    private func pillStack(_ visibleToasts: [iOSSystemToast]) -> some View {
        VStack(spacing: 8) {
            ForEach(visibleToasts) { toast in
                iOSSystemToastPill(toast: toast) {
                    center.dismiss(toast.id)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(AppMotion.snappy, value: center.queue.map(\.id))
        .allowsHitTesting(!center.queue.isEmpty)
        // Sit above the TabView and home indicator on iPhone, and the home
        // indicator on iPad. The overlay caller already applies safe-area
        // semantics, this is the extra inset for the bar itself.
    }
}

private struct iOSSystemToastPill: View {
    let toast: iOSSystemToast
    let onDismiss: () -> Void

    private var tint: Color {
        switch toast.kind {
        case .info: return .secondary
        case .warn: return .secondary
        case .error: return .red
        case .success: return .secondary
        }
    }

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
            // Keep the icon+text and dismiss Button as SEPARATE a11y
            // elements (Mac SystemToastBar 2026-06-06 fix) so VoiceOver
            // users can actuate dismiss instead of just hearing the text.
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(toast.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(toast.kind.rawValue.capitalized): \(toast.text)")

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44) // iOS touch target
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .modifier(ToastPillSurface(tint: tint))
        .accessibilityElement(children: .contain)
    }
}

/// Toast pill chrome. Toasts are a floating control over content — exactly
/// the layer the iOS 26 HIG assigns to Liquid Glass — so on iOS 26 they use
/// the real material (lensing, motion highlights, auto contrast). Pre-26
/// keeps the hand-rolled ultraThinMaterial approximation.
private struct ToastPillSurface: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content.mobileGlassSurface(radius: NativeAgentMobileTheme.Radius.composer, interactive: true)
    }
}

// MARK: - Mac connection chip (Sweep R4 C11.4)
//
// Until now the phone's connection state rendered on exactly two screens:
// Diagnostics → Status and Settings → Connection. On Chat, Activity, Memory
// and Skills the app looked completely normal while the Mac was asleep — you
// found out by sending a message and waiting for a timeout.
//
// This is the SAME source of truth those two screens already read
// (`MacBridgeClient.bridgeStatus`, refreshed by the existing 5s poll in
// MacBridgeClient.init). No new timer, no new fetch — a second reader of a
// value that was already being computed.

/// A compact connection indicator for a navigation bar. Every state is named:
/// a green dot alone makes a healthy connection look like unexplained chrome,
/// especially when the user has no reason to know the dot is tappable.
struct MacStatusChip: View {
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @State private var showDetail = false

    private var status: BridgeStatus { bridgeClient.bridgeStatus }
    private var isHealthy: Bool { status == .online }

    var body: some View {
        Button {
            showDetail = true
        } label: {
            Label(shortLabel, systemImage: isHealthy ? "checkmark.icloud" : "icloud.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A bare 8pt dot is far under the 44pt minimum target, so pad the
            // hit area without padding the visual.
            .contentShape(Rectangle())
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mac connection: \(status.displayName)")
        .popover(isPresented: $showDetail) {
            MacStatusDetail(status: status, lastSeenAt: bridgeClient.lastSeenAt, lastSyncAt: sync.lastSyncAt)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// Navigation bars are tight — the full `displayName` ("Connected via
    /// iCloud", "Last seen 4m ago") does not fit beside a title. The popover
    /// carries the full sentence.
    private var shortLabel: String {
        MacStatusChipPresentation.shortLabel(for: status)
    }
}

enum MacStatusChipPresentation {
    static func shortLabel(for status: BridgeStatus) -> String {
        switch status {
        case .online: return "Live"
        case .awaitingMacActivity: return "Waiting for Mac"
        case .offline: return "No iCloud"
        case .macUnreachable: return "Mac unavailable"
        case .deviceOffline: return "iPhone offline"
        case .stale(let minutesAgo): return "\(minutesAgo)m ago"
        case .connecting: return "Connecting"
        }
    }

    static func explanation(for status: BridgeStatus) -> String {
        switch status {
        case .online:
            return "The Mac checked in recently through iCloud. If it goes offline, new messages may wait until it returns."
        case .awaitingMacActivity:
            return "iCloud is available, but this phone has not received any activity from the Mac yet. Messages may wait until the Mac checks in."
        case .offline:
            return "This iPhone cannot reach iCloud right now, so nothing can be sent or received."
        case .macUnreachable:
            return "The paired Mac connection has not recovered. The Mac may be asleep or offline, or iCloud may be unavailable. Messages may wait until the connection returns."
        case .deviceOffline:
            return "This iPhone has no network connection. That is a local outage, not a Mac problem — messages are queued and send themselves when it returns."
        case .stale:
            return "The Mac has gone quiet. What you see may be out of date, and a new message may sit waiting."
        case .connecting:
            return "Still establishing the iCloud link. Give it a moment."
        }
    }
}

private struct MacStatusDetail: View {
    let status: BridgeStatus
    let lastSeenAt: Date?
    let lastSyncAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(status.color).frame(width: 9, height: 9)
                Text(status.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(MacStatusChipPresentation.explanation(for: status))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let lastSeenAt {
                LabeledContent("Mac last seen") {
                    Text(lastSeenAt, style: .relative).foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
            if let lastSyncAt {
                LabeledContent("Last synced") {
                    Text(lastSyncAt, style: .relative).foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
        .padding(16)
        .frame(minWidth: 240, maxWidth: 300, alignment: .leading)
    }

}

// MARK: - Sync error banner (Sweep R4 C11.3)
//
// `iCloudSyncEngine.syncError` has always been `@Published` and read by
// nothing — a CloudKit decode failure (iCloudSyncEngine+Setup.swift) set a
// string that no view rendered, so a screen showing stale data looked
// identical to a screen showing fresh data.
//
// RENDER-ONLY. This adds no retry, no polling and no sync machinery; it shows
// the string the engine already writes.

/// One-line dismissible banner over the top of a screen. Tap to see the full
/// text, X to dismiss. A NEW error text un-dismisses itself — dismissing
/// "snapshots downloading" must not also silence a later decode failure.
struct MacSyncErrorBanner: View {
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @State private var dismissedMessage: String?
    @State private var isExpanded = false

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
                    Button {
                        isExpanded.toggle()
                    } label: {
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
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sync warning: \(message)")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint(isExpanded ? "Collapses the warning" : "Reads the full warning")
                    Button {
                        dismissedMessage = message
                        isExpanded = false
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
        .animation(AppMotion.snappy, value: isExpanded)
        // The latch must only survive as long as the condition does. Without
        // this, dismissing "snapshots still downloading", letting a sync
        // succeed, and then hitting the SAME failure again would leave the
        // banner permanently silent — a dismissal in one situation would
        // swallow a genuinely new occurrence later.
        .onChange(of: sync.syncError) { _, newValue in
            if MacSyncErrorBannerPresentation.normalizedMessage(newValue) == nil {
                dismissedMessage = nil
                isExpanded = false
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
