import SwiftUI

public enum SystemHealthSummary: Sendable, Equatable {
    case unknown          // PATCH-2026-06-06: cold-launch — no Doctor run yet.
    case ok
    case warn(count: Int)
    case error(count: Int)
}

extension AppModel {
    var systemHealthSummary: SystemHealthSummary {
        // PATCH-2026-06-06: cold-launch honesty — before Doctor has ever run
        // (doctorReport == nil), the pill said "OK", which is a lie that the
        // user reads as "all clear". Return .unknown until we have real data.
        guard let checks = doctorReport?.checks else { return .unknown }
        let failCount = checks.filter { $0.status.lowercased() == "fail" }.count
        let warnCount = checks.filter { $0.status.lowercased() == "warn" }.count
        if failCount > 0 { return .error(count: failCount) }
        if warnCount > 0 { return .warn(count: warnCount) }
        return .ok
    }
}

public struct HealthPill: View {
    @Environment(AppModel.self) var appModel
    @Binding var showingDoctor: Bool

    public init(showingDoctor: Binding<Bool>) {
        self._showingDoctor = showingDoctor
    }

    public var body: some View {
        let summary = appModel.systemHealthSummary
        let label = label(for: summary)
        let statusColor = color(for: summary)

        Button(action: { showingDoctor = true }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(NativeAgentFont.tag)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(statusColor.opacity(0.32), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
        .help("System health")
        .accessibilityLabel("System health: \(label)")
    }

    private func label(for summary: SystemHealthSummary) -> String {
        switch summary {
        case .unknown:
            "Checking"
        case .ok:
            "OK"
        case .warn(let count):
            "\(count) warning\(count == 1 ? "" : "s")"
        case .error(let count):
            "\(count) issue\(count == 1 ? "" : "s")"
        }
    }

    private func color(for summary: SystemHealthSummary) -> Color {
        switch summary {
        case .unknown: .secondary
        case .ok: NativeAgentTheme.ok
        case .warn: NativeAgentTheme.warn
        case .error: NativeAgentTheme.fail
        }
    }
}
