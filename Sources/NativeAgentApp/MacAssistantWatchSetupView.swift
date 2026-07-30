import SwiftUI

struct MacAssistantWatchSetupView: View {
    var refreshToken: Int = 0

    @Environment(AppModel.self) private var appModel
    @State private var status: MacAssistantStatusResponse?
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        NativePanel(title: "Assistant Watch Setup", systemImage: "eye", tint: .teal) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusBadge(text: status?.status.capitalized ?? "Loading", status: normalizedStatus(status?.status))
                    if let attention = status?.templateAttentionCount, attention > 0 {
                        StatusBadge(text: "\(attention) needs setup", status: "warn")
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                }

                if let summary = status?.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isLoading && status == nil {
                    ProgressView("Checking access...")
                } else if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let status {
                    accessSection(status.access)
                    Divider()
                    templatesSection(status.watchTemplates)
                }
            }
        }
        .task { await load() }
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
        errorText = nil
        defer { isLoading = false }
        do {
            status = try await appModel.getMacAssistantStatus()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func normalizedStatus(_ status: String?) -> String {
        switch status?.lowercased() {
        case "ready", "ok", "succeeded":
            return "ready"
        case "attention", "needs_setup", "needs_proof", "needs_policy", "needs_permission", "probe_needed":
            return "warn"
        case "failed", "error":
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
