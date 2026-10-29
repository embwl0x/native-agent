import SwiftUI

// Blueprint: | `HealthPill.swift` | `HealthPill`: compact health status color/label presentation |

/// The pill renders each owner's repair face without requiring another surface.
enum HealthPillPopoverPresentation: Equatable {
    static func headline(summary: SystemHealthSummary, isChecking: Bool) -> String {
        if isChecking { return "Looking things over…" }
        switch summary {
        case .unknown:
            return "The app's health isn't clear yet"
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

    static let detailsTitle = "Open Diagnostics"
}

public struct HealthPill: View {
    @Environment(AppModel.self) var appModel
    @AppStorage("showDeveloperSurfaces") private var showDeveloperSurfaces = false
    @State private var showPopover = false
    @State private var repairNotice: String?

    public init() {}

    public var body: some View {
        let health = appModel.engine.doctor.systemHealth
        let summary = health.summary
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
            .houseSurface(in: Capsule())
        }
        .buttonStyle(.plain)
        .help("How the app is doing")
        .accessibilityLabel("How the app is doing: \(label)")
        .accessibilityIdentifier("health-pill.open-doctor")
        .accessibilityHint("Shows what needs repair and how to fix it")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popoverContent(summary: summary, issues: health.issues, statusColor: statusColor)
        }
    }

    @ViewBuilder
    private func popoverContent(
        summary: SystemHealthSummary,
        issues: [(id: String, title: String, detail: String, repairAvailable: Bool)],
        statusColor: Color
    ) -> some View {
        let isChecking = appModel.engine.doctor.isRunning

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

            if !issues.isEmpty {
                ScrollView {
                    if appModel.engine.doctor.report == nil {
                        Text(issues.map { $0.title + ": " + $0.detail }.joined(separator: "\n\n"))
                            .font(.callout).textSelection(.enabled)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(issues, id: \.id) { check in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(check.title).font(.callout.bold())
                                    Text(check.detail).font(.callout)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            if let repairNotice {
                Text(repairNotice).font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if issues.contains(where: \.repairAvailable) {
                    Button("Repair safe issues") {
                        Task {
                            let outcome = await appModel.runDoctor(repair: true, repairScope: .button)
                            repairNotice = DoctorRunButtonPresentation.notice(for: outcome, repair: true).detail
                        }
                    }
                    .disabled(isChecking)
                    .accessibilityIdentifier("health-pill.repair-now")
                }
                Button(isChecking ? "Looking…" : "Take a look") {
                    Task { _ = await appModel.runDoctor(repair: false) }
                }
                .disabled(isChecking)
                .accessibilityIdentifier("health-pill.check-now")

                // Diagnostics follows developer-surface visibility.
                if showDeveloperSurfaces {
                    Button(HealthPillPopoverPresentation.detailsTitle) {
                        showPopover = false
                        ApplicationLifetime.shared.request(.sidebar(.diagnostics))
                    }
                    .accessibilityIdentifier("health-pill.open-diagnostics")
                }
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }

    private func label(for summary: SystemHealthSummary) -> String {
        switch summary {
        case .unknown:
            // Claim checking only during a real run.
            appModel.engine.doctor.isRunning ? "Checking" : "Unknown"
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
