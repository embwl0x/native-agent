// PATCH-2026-06-06: effect-timing-tags — capsule next to Trust toggles indicating
// when a change takes effect: now / next run / restart. Visual only.
import SwiftUI

struct EffectTimingTag: View {
    enum Timing {
        case now
        case nextRun
        case restart

        var label: String {
            switch self {
            case .now:     return "applies now"
            case .nextRun: return "next run"
            case .restart: return "restart"
            }
        }

        var color: Color {
            switch self {
            case .now:     return .green
            case .nextRun: return .yellow
            case .restart: return .orange
            }
        }
    }

    let timing: Timing

    var body: some View {
        Text(timing.label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(timing.color.opacity(0.18), in: Capsule())
            .foregroundStyle(timing.color)
            .accessibilityLabel("Effect timing: \(timing.label)")
    }
}
