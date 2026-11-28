import Foundation
import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `ChatContextFillBar.swift` | `ContextFillPresentation` window and percent words over the Shared usage; missing measurements remain unavailable |

extension ContextFillPresentation {
    /// Zero means the catalog states no window size, never a measured size.
    static func window(_ budget: Int) -> String? {
        budget > 0 ? NumberFormatter.localizedString(from: NSNumber(value: budget), number: .decimal) : nil
    }

    static func roundedPercent(_ value: Double) -> String {
        guard value.isFinite else { return "unavailable" }
        return String(format: "%.0f%%", value.rounded())
    }
}

/// Draw the engine-owned context usage as a ring.
struct ComposerContextRing: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var status: SessionContextStatus? {
        let sessionId = sessionId
        return appModel.face.slot(.settings).select("providers.context.\(sessionId)", as: SettingsFace.self) {
            $0?.providers.sessions[sessionId]?.context
        }
    }

    private var usage: ContextFillPresentation.Usage {
        guard let status else { return .init(percent: 0, fillFraction: 0) }
        return ContextFillPresentation.usage(status)
    }

    private var ringColor: Color {
        let pct = usage.percent
        if pct >= 80 { return .red.opacity(0.85) }
        if pct >= 60 { return .orange.opacity(0.85) }
        return NativeAgentShell.secondary
    }

    private var helpText: String {
        guard let status else {
            let sessionId = sessionId
            return appModel.face.slot(.settings).select("providers.contextIssue.\(sessionId)", as: SettingsFace.self) {
                $0?.providers.sessions[sessionId]?.error
            }
                ?? "Context usage unavailable; no matching provider measurement has loaded."
        }
        let used = NumberFormatter.localizedString(from: NSNumber(value: status.used_tokens), number: .decimal)
        guard let window = ContextFillPresentation.window(status.budget) else { return "Context: \(used) tokens; window unknown" }
        let source = "last observed provider input"
        return "Context: \(used) of \(window) tokens (\(ContextFillPresentation.roundedPercent(usage.percent))); \(source)."
    }

    var body: some View {
        HStack(spacing: 5) {
            if status == nil {
                Circle()
                    .stroke(NativeAgentShell.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                    .frame(width: 11, height: 11)
            } else {
                ZStack {
                    Circle().stroke(NativeAgentShell.hairline, lineWidth: 1.5)
                    Circle()
                        .trim(from: 0, to: usage.fillFraction)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(
                            Animation.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
                            value: usage.fillFraction
                        )
                }
                .frame(width: 11, height: 11)
            }
            if let status, status.budget > 0 {
                Text((status.context_loaded == true ? "" : "~") + ContextFillPresentation.roundedPercent(usage.percent))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .monospacedDigit()
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }
}
