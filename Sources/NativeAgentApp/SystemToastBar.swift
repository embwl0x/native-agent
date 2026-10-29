import Foundation
import NativeAgentShared
import SwiftUI

// Blueprint: | `SystemToastBar.swift` | platform notice rendering and room-scoped positioning; values, queue and timers belong to NativeAgentShared |

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
        // Show the newest notices; dismissal timers start on push.
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
            // Keep dismissal separate so VoiceOver can actuate it.
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
