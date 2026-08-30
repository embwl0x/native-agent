import SwiftUI

public enum SystemHealthSummary: Sendable, Equatable {
    case unknown          // PATCH-2026-06-06: cold-launch — no Doctor run yet.
    case ok
    case warn(count: Int)
    case error(count: Int)
}

extension AppModel {
    var systemHealthSummary: SystemHealthSummary {
        // Prefer an explicit Doctor run. Otherwise reuse the health card that
        // Chat already keeps current instead of launching a second full Doctor
        // pass from this always-mounted toolbar control.
        if let checks = doctorReport?.checks {
            let failCount = checks.filter { $0.status.lowercased() == "fail" }.count
            let warnCount = checks.filter { $0.status.lowercased() == "warn" }.count
            if failCount > 0 { return .error(count: failCount) }
            if warnCount > 0 { return .warn(count: warnCount) }
            return .ok
        }
        guard let subsystems = healthCard?.subsystems else { return .unknown }
        let failCount = subsystems.filter {
            ["fail", "error"].contains($0.status.lowercased())
        }.count
        let warnCount = subsystems.filter { $0.status.lowercased() == "warn" }.count
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

/// D3 (2026-08-28): what the pill SAYS when you open it.
///
/// The pill used to jump straight to Diagnostics — a developer-gated surface
/// whose sidebar row a normal user cannot even see (`SidebarItem.developerItems`
/// contains `.diagnostics`), so the one always-visible health control led into a
/// room the user was not admitted to. It now explains itself in place.
///
/// Copy bar: nothing in the user-visible strings may name a developer concept.
/// No "Doctor", no "diagnostics", no "checks", no "repair", no "report" — a
/// person reading this has never heard those words in this app.
enum HealthPillPopoverPresentation: Equatable {
    /// The one action offered. Details stay out unless the user has already
    /// turned developer surfaces on — otherwise the button lands them somewhere
    /// with no way back.
    enum Action: Equatable {
        case check          // run it now
        case checking       // a run is already in flight
    }

    static func headline(summary: SystemHealthSummary, isChecking: Bool) -> String {
        if isChecking { return "Looking things over…" }
        switch summary {
        case .unknown:
            return "Nothing has been looked at yet"
        case .ok:
            return "Everything looks fine"
        case .warn(let count):
            return "\(count) thing\(count == 1 ? "" : "s") could use attention"
        case .error(let count):
            return "\(count) thing\(count == 1 ? "" : "s") \(count == 1 ? "isn't" : "aren't") working"
        }
    }

    static func detail(summary: SystemHealthSummary, isChecking: Bool) -> String {
        if isChecking { return "This takes a few seconds." }
        switch summary {
        case .unknown:
            return "Take a look to see how the app is doing."
        case .ok:
            return "The app looked over its own setup and found no problems."
        case .warn:
            return "The app still works. These are things worth fixing when you have a minute."
        case .error:
            return "Some features will not work until these are fixed."
        }
    }

    static func action(isChecking: Bool) -> Action {
        isChecking ? .checking : .check
    }

    static func actionTitle(_ action: Action) -> String {
        switch action {
        case .check: "Take a look"
        case .checking: "Looking…"
        }
    }

    static let detailsTitle = "Open Diagnostics"
}

public struct HealthPill: View {
    @Environment(AppModel.self) var appModel
    @AppStorage("showDeveloperSurfaces") private var showDeveloperSurfaces = false
    @State private var showPopover = false

    public init() {}

    public var body: some View {
        let summary = appModel.systemHealthSummary
        let label = label(for: summary)
        let statusColor = color(for: summary)

        Button(action: { showPopover = true }) {
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
        // D3: the tooltip used to be derived from the LAST navigation receipt,
        // so after one click it read "Doctor navigation is queued until the
        // main window is ready." forever — stale, and developer vocabulary in
        // a permanent tooltip. It is a fixed description of the control now.
        .help("How the app is doing")
        .accessibilityLabel("How the app is doing: \(label)")
        .accessibilityIdentifier("health-pill.open-doctor")
        .accessibilityHint("Shows what the app has found, and lets you check again")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popoverContent(summary: summary, statusColor: statusColor)
        }
    }

    @ViewBuilder
    private func popoverContent(
        summary: SystemHealthSummary,
        statusColor: Color
    ) -> some View {
        let isChecking = appModel.doctorRunning
        let action = HealthPillPopoverPresentation.action(isChecking: isChecking)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(HealthPillPopoverPresentation.headline(
                    summary: summary, isChecking: isChecking
                ))
                .font(.headline)
            }
            Text(HealthPillPopoverPresentation.detail(
                summary: summary, isChecking: isChecking
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(HealthPillPopoverPresentation.actionTitle(action)) {
                    Task { _ = await appModel.runDoctor(repair: false) }
                }
                .disabled(action == .checking)
                .accessibilityIdentifier("health-pill.check-now")

                // The jump survives, but only for people who already turned
                // developer surfaces on — everyone else has no Diagnostics row
                // to come back to.
                if showDeveloperSurfaces {
                    Button(HealthPillPopoverPresentation.detailsTitle) {
                        showPopover = false
                        _ = HealthPillDoctorJump.request()
                    }
                    .accessibilityIdentifier("health-pill.open-diagnostics")
                }
            }
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
    }

    private func label(for summary: SystemHealthSummary) -> String {
        switch summary {
        case .unknown:
            // D3: this arm rendered "Checking" whether or not anything was
            // actually running, so a machine that never ran a check displayed
            // a permanent progress claim. "Checking" now belongs to a real
            // in-flight run; a cold pill says it has no answer yet.
            appModel.doctorRunning ? "Checking" : "Not checked"
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
