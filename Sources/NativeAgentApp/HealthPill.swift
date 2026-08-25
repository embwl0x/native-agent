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

/// The health pill has one navigation responsibility: take the person to the
/// mounted Doctor diagnostics surface. A queued request is useful, but it is
/// not the same as Doctor having already rendered.
enum HealthPillDoctorJump {
    static let destination: NativeAgentNavigationDestination = .sidebar(.diagnostics)

    @MainActor
    static func request(
        using coordinator: NativeAgentAppCoordinator = .shared
    ) -> NativeAgentNavigationRequestReceipt {
        coordinator.request(destination)
    }

    static func help(for receipt: NativeAgentNavigationRequestReceipt?) -> String {
        switch receipt {
        case .some(.deliveredToMountedScene):
            return "Doctor navigation was delivered to the app window."
        case .some(.queuedForMainScene):
            return "Doctor navigation is queued until the main window is ready."
        case .none:
            return "Open Doctor diagnostics"
        }
    }
}

public struct HealthPill: View {
    @Environment(AppModel.self) var appModel
    @State private var doctorJumpReceipt: NativeAgentNavigationRequestReceipt?

    public init() {}

    public var body: some View {
        let summary = appModel.systemHealthSummary
        let label = label(for: summary)
        let statusColor = color(for: summary)

        Button(action: { doctorJumpReceipt = HealthPillDoctorJump.request() }) {
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
        .help(HealthPillDoctorJump.help(for: doctorJumpReceipt))
        .accessibilityLabel("System health: \(label)")
        .accessibilityIdentifier("health-pill.open-doctor")
        .accessibilityHint(HealthPillDoctorJump.help(for: doctorJumpReceipt))
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
