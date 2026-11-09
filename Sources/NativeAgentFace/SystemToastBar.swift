import Foundation
import NativeAgentShared
import SwiftUI

// Blueprint: | `SystemToastBar.swift` | platform notice rendering and room-scoped positioning; values, queue and timers belong to NativeAgentShared |

/// Bind placement to the visible room so hidden chat notices cannot appear on another page.
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

/// Share one notice column while each owner retains its severity-based durations.
struct NoticeLane: View {
    let centers: [SystemToastCenter]

    var body: some View {
        GlassEffectContainer(spacing: NativeAgentSpacing.sm) {
            VStack(spacing: NativeAgentSpacing.sm) {
                ForEach(centers, id: \.id) { center in
                    NoticeLaneColumn(center: center)
                }
            }
            // Cap capsule width to keep long notices within the lane.
            .frame(maxWidth: 520)
        }
        .padding(.horizontal, NativeAgentSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct NoticeLaneColumn: View {
    private static let maxVisible = 3
    let center: SystemToastCenter
    @State private var notices: [SystemToast] = []

    var body: some View {
        // Timers start on push, so show newest notices first.
        VStack(spacing: NativeAgentSpacing.sm) {
            ForEach(notices) { notice in
                NoticePill(text: notice.text, kind: notice.kind) { center.dismiss(notice.id) }
                    .transition(NativeAgentMotion.fade)
            }
        }
        .animation(NativeAgentMotion.quick, value: notices.map(\.id))
        .task(id: center.id) {
            for await queue in center.updates() { notices = Array(queue.suffix(Self.maxVisible)) }
        }
    }
}

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
