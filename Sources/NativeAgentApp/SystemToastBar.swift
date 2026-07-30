import Foundation
import SwiftUI

@MainActor
public struct SystemToast: Identifiable, Sendable, Equatable {
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

    public nonisolated static func == (lhs: SystemToast, rhs: SystemToast) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
public final class SystemToastCenter: ObservableObject {
    @Published public private(set) var queue: [SystemToast] = []

    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func push(_ toast: SystemToast) {
        // PATCH-2026-06-06: replace-by-id semantics — if the same toast id is
        // pushed twice, cancel the existing auto-dismiss task and remove the
        // stale entry before appending. Without this, a sticky re-push of a
        // previously-pushed auto-dismissing toast would have the old timer
        // fire and remove the new one. Also prevents ForEach duplicate-id.
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
        push(SystemToast(kind: .info, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func push(warn text: String, autoDismissAfter: TimeInterval? = 5) {
        push(SystemToast(kind: .warn, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func push(error text: String, autoDismissAfter: TimeInterval? = 8) {
        push(SystemToast(kind: .error, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func push(success text: String, autoDismissAfter: TimeInterval? = 3) {
        push(SystemToast(kind: .success, text: text, autoDismissAfter: autoDismissAfter))
    }

    public func dismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        queue.removeAll { $0.id == id }
    }

    public func dismissAll() {
        for task in dismissTasks.values {
            task.cancel()
        }
        dismissTasks.removeAll()
        queue.removeAll()
    }
}

enum SystemToastPlacement {
    case top
    case bottom

    var transitionEdge: Edge {
        switch self {
        case .top: .top
        case .bottom: .bottom
        }
    }
}

public struct SystemToastBar: View {
    private static let maxVisible = 3

    @ObservedObject var center: SystemToastCenter
    var placement: SystemToastPlacement

    public init(center: SystemToastCenter) {
        self.center = center
        self.placement = .bottom
    }

    init(center: SystemToastCenter, placement: SystemToastPlacement) {
        self.center = center
        self.placement = placement
    }

    public var body: some View {
        // PATCH-2026-06-06: show NEWEST toasts when capped. Older `prefix(3)`
        // semantics meant a burst of 4 short-lived toasts could see the 4th
        // auto-dismiss while never visible (timer starts on push, not on
        // visibility). Tail-window keeps the surface honest.
        let visibleToasts = Array(center.queue.suffix(Self.maxVisible))

        VStack(spacing: NativeAgentSpacing.sm) {
            ForEach(visibleToasts) { toast in
                SystemToastPill(toast: toast) {
                    center.dismiss(toast.id)
                }
                .transition(.move(edge: placement.transitionEdge).combined(with: .opacity))
            }
        }
        .padding(.horizontal, NativeAgentSpacing.lg)
        .padding(.top, placement == .top ? NativeAgentSpacing.md : 0)
        .padding(.bottom, placement == .bottom ? NativeAgentSpacing.md : 0)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(NativeAgentMotion.snappy, value: center.queue.map(\.id))
        .allowsHitTesting(!center.queue.isEmpty)
    }
}

private struct SystemToastPill: View {
    let toast: SystemToast
    let onDismiss: () -> Void

    private var tint: Color {
        switch toast.kind {
        case .info: NativeAgentTheme.info
        case .warn: NativeAgentTheme.warn
        case .error: NativeAgentTheme.fail
        case .success: NativeAgentTheme.ok
        }
    }

    private var icon: String {
        switch toast.kind {
        case .info: "info.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            // PATCH-2026-06-06: keep the icon+text and the dismiss Button as
            // SEPARATE a11y elements. The previous .combine on the outer
            // capsule swallowed the dismiss Button into the parent label so
            // VoiceOver users could hear the toast but not actuate dismiss.
            HStack(spacing: NativeAgentSpacing.sm) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(toast.text)
                    .font(NativeAgentFont.body)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(toast.kind.rawValue.capitalized): \(toast.text)")
            Spacer(minLength: NativeAgentSpacing.sm)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, NativeAgentSpacing.md)
        .padding(.vertical, NativeAgentSpacing.sm)
        .frame(maxWidth: 520)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.32), lineWidth: 0.8)
        }
        .shadow(color: tint.opacity(0.18), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
    }
}
