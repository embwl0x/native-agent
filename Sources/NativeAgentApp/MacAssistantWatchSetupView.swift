import SwiftUI

struct MacAssistantWatchSetupView: View {
    typealias StatusReader = @MainActor () async throws -> MacAssistantStatusResponse

    var refreshToken: Int
    private let statusReader: StatusReader?
    private let loadsOnAppear: Bool

    @Environment(AppModel.self) private var appModel
    @State private var loadState: MacAssistantWatchSetupLoadState = .loading
    @State private var isLoading = false

    init(
        refreshToken: Int = 0,
        statusReader: StatusReader? = nil,
        loadsOnAppear: Bool = true
    ) {
        self.refreshToken = refreshToken
        self.statusReader = statusReader
        self.loadsOnAppear = loadsOnAppear
    }

    var body: some View {
        NativePanel(title: "Assistant Watch Setup", systemImage: "eye", tint: .teal) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusBadge(text: loadState.badgeText, status: normalizedStatus(loadState.badgeStatus))
                        .accessibilityIdentifier("mac-assistant-watch.load-status")
                    if let attention = loadState.response?.templateAttentionCount, attention > 0 {
                        StatusBadge(text: "\(attention) needs setup", status: "warn")
                            .accessibilityIdentifier("mac-assistant-watch.template-attention")
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                    .accessibilityIdentifier("mac-assistant-watch.refresh")
                }

                if let summary = loadState.response?.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let createsJobs = loadState.response?.createsJobs {
                    Label(
                        createsJobs
                            ? "Watch jobs are active; their receipts will appear as they run."
                            : "These are setup templates only. No watch job or receipt exists until you schedule one.",
                        systemImage: createsJobs ? "checkmark.circle" : "clock.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(createsJobs ? NativeAgentTheme.ok : Color.secondary)
                }

                if isLoading && loadState.response == nil {
                    ProgressView("Checking access...")
                } else if let diagnostic = loadState.diagnosticText {
                    Label(diagnostic, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("mac-assistant-watch.load-error")
                    if let status = loadState.response {
                        Text("Showing the last known inventory; refresh did not complete.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        accessSection(status.access)
                        Divider()
                        templatesSection(status.watchTemplates)
                    } else {
                        Text("No watch setup inventory is available. Check Mac Control and try Refresh again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let status = loadState.response {
                    accessSection(status.access)
                    Divider()
                    templatesSection(status.watchTemplates)
                }
            }
        }
        .task {
            guard loadsOnAppear else { return }
            await load()
        }
        .onChange(of: refreshToken) { _, _ in
            Task { await load() }
        }
    }

    private func accessSection(_ access: [MacAssistantAccessItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Access")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)

            ForEach(access) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: item.id))
                        .frame(width: 18)
                        .foregroundStyle(tint(for: item.status))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                            StatusBadge(text: label(for: item.status), status: normalizedStatus(item.status))
                        }
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let nextStep = item.nextStep, !nextStep.isEmpty {
                            Text(nextStep)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func templatesSection(_ templates: [MacAssistantWatchTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Job Templates")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)

            ForEach(templates) { template in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .frame(width: 18)
                        .foregroundStyle(tint(for: template.status))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(template.title)
                                .font(.caption.weight(.semibold))
                            StatusBadge(text: label(for: template.status), status: normalizedStatus(template.status))
                        }
                        if let schedule = template.scheduleLabel {
                            Text(schedule)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let summary = template.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let status: MacAssistantStatusResponse
            if let statusReader {
                status = try await statusReader()
            } else {
                status = try await appModel.getMacAssistantStatus()
            }
            loadState = .current(status)
        } catch {
            loadState = loadState.afterFailure(
                "Couldn’t refresh Assistant Watch setup: \(error.localizedDescription)"
            )
        }
    }

    private func normalizedStatus(_ status: String?) -> String {
        switch status?.lowercased() {
        case "ready", "ok", "succeeded":
            return "ready"
        case "attention", "needs_setup", "needs_proof", "needs_policy", "needs_permission", "probe_needed":
            return "warn"
        case "failed", "error", "unavailable":
            return "failed"
        default:
            return status ?? "unknown"
        }
    }

    private func label(for status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func tint(for status: String) -> Color {
        switch normalizedStatus(status) {
        case "ready": return NativeAgentTheme.ok
        case "warn": return NativeAgentTheme.warn
        case "failed": return NativeAgentTheme.fail
        default: return .secondary
        }
    }

    private func icon(for id: String) -> String {
        switch id {
        case "mac_control": return "macwindow"
        case "mac_notifications": return "bell"
        case "iphone_push": return "iphone.radiowaves.left.and.right"
        case "gmail", "local_mail": return "envelope"
        case "google_calendar", "local_calendar": return "calendar"
        case "local_reminders": return "checklist"
        default: return "circle"
        }
    }
}
