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

    public init(kind: Kind, text: String, autoDismissAfter: TimeInterval? = 3, id: UUID = UUID()) {
        self.id = id
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

/// Where the chat room wants the notice lane: just under its pinned chrome,
/// carrying the room's own turn notices. Published only while the chat is in
/// front; with no room the lane sits at the top of the page.
struct NoticeLaneRoom {
    let anchor: Anchor<CGRect>
    let notices: SystemToastCenter
}

struct NoticeLaneRoomKey: PreferenceKey {
    static let defaultValue: NoticeLaneRoom? = nil

    static func reduce(value: inout NoticeLaneRoom?, nextValue: () -> NoticeLaneRoom?) {
        value = nextValue() ?? value
    }
}

/// Fluid glass A2: the one notice lane. App-wide toasts and the open room's
/// turn notices stack in one column of glass capsules; each center keeps its
/// own durations by severity.
struct NoticeLane: View {
    let centers: [SystemToastCenter]

    var body: some View {
        GlassEffectContainer(spacing: NativeAgentSpacing.sm) {
            VStack(spacing: NativeAgentSpacing.sm) {
                ForEach(centers.indices, id: \.self) { index in
                    NoticeLaneColumn(center: centers[index])
                }
            }
            // Capsules hug their words up to this; the cap is the lane's.
            .frame(maxWidth: 520)
        }
        .padding(.horizontal, NativeAgentSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct NoticeLaneColumn: View {
    private static let maxVisible = 3

    @ObservedObject var center: SystemToastCenter

    var body: some View {
        // PATCH-2026-06-06: show NEWEST toasts when capped. Older `prefix(3)`
        // semantics meant a burst of 4 short-lived toasts could see the 4th
        // auto-dismiss while never visible (timer starts on push, not on
        // visibility). Tail-window keeps the surface honest.
        VStack(spacing: NativeAgentSpacing.sm) {
            ForEach(center.queue.suffix(Self.maxVisible)) { toast in
                NoticePill(text: toast.text, kind: toast.kind) {
                    center.dismiss(toast.id)
                }
                .transition(NativeAgentMotion.fade)
            }
        }
        .animation(NativeAgentMotion.quick, value: center.queue.map(\.id))
    }
}

/// The one notice style: a glass capsule. The lane gives it a kind and a
/// dismiss; the composer and bubble text toasts use it bare.
struct NoticePill: View {
    let text: String
    var kind: SystemToast.Kind? = nil
    var onDismiss: (() -> Void)? = nil

    private var tint: Color {
        switch kind {
        case .info, nil: NativeAgentTheme.info
        case .warn: NativeAgentTheme.warn
        case .error: NativeAgentTheme.fail
        case .success: NativeAgentTheme.ok
        }
    }

    private var icon: String {
        switch kind {
        case .info, nil: "info.circle.fill"
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
                if kind != nil {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                }
                Text(text)
                    .font(NativeAgentFont.body)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(kind.map { "\($0.rawValue.capitalized): \(text)" } ?? text)
            if let onDismiss {
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
        }
        .padding(.horizontal, NativeAgentSpacing.md)
        .padding(.vertical, NativeAgentSpacing.sm)
        .houseSurface(in: Capsule(style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
