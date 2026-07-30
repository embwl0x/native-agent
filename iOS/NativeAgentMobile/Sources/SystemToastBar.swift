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

    public init(kind: Kind, text: String, autoDismissAfter: TimeInterval? = 3) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.createdAt = Date()
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

    public func push(_ toast: iOSSystemToast) {
        // Replace-by-id semantics — match the Mac SystemToastCenter so a
        // re-push of the same id (rare but possible if a caller hand-stamps
        // an id for sticky updates) doesn't see the old timer kill the new
        // entry, and ForEach doesn't trip on duplicate ids.
        dismissTasks.removeValue(forKey: toast.id)?.cancel()
        queue.removeAll { $0.id == toast.id }
        queue.append(toast)

        guard let after = toast.autoDismissAfter, after > 0 else { return }
        dismissTasks[toast.id] = Task {
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
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
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        case .success: return .green
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
        HStack(spacing: 10) {
            // Keep the icon+text and dismiss Button as SEPARATE a11y
            // elements (Mac SystemToastBar 2026-06-06 fix) so VoiceOver
            // users can actuate dismiss instead of just hearing the text.
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(toast.text)
                    .font(AppFont.body)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(toast.kind.rawValue.capitalized): \(toast.text)")

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 32) // iOS touch target
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
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
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint.opacity(0.18)).interactive(),
                    in: Capsule(style: .continuous)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(tint.opacity(0.32), lineWidth: 0.8)
                }
                .shadow(color: tint.opacity(0.18), radius: 8, y: 2)
        }
    }
}
