import SwiftUI

struct NativeExperienceOverviewPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var diary = DreamDiaryResponse()
    @State private var refreshing = false

    var body: some View {
        NativeExperiencePage(
            title: "One mind, made visible",
            subtitle: "A joined view of what the agent retained, learned, used, and completed. Every record stays with its canonical owner."
        ) {
            HStack(spacing: 12) {
                metric("Memories", appModel.memories.count, "brain")
                metric("Skills", appModel.skills.count, "puzzlepiece.extension")
                metric("Projects", appModel.workspaces.count, "folder")
                metric("Schedules", appModel.jobs.filter(\.enabled).count, "clock")
            }

            NativeExperienceCard(title: "Learning Journey", icon: "point.3.filled.connected.trianglepath.dotted") {
                if timeline.isEmpty {
                    Text("No recent learning receipts are available yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(timeline.prefix(18)) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.icon).foregroundStyle(item.color).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.title).font(.headline)
                                    Spacer()
                                    Text(item.date).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Text(item.detail).font(.callout).lineLimit(3)
                                Text(item.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if item.id != timeline.prefix(18).last?.id { Divider() }
                    }
                }
            }

            NativeExperienceCard(title: "Canonical owners", icon: "checkmark.shield") {
                Text("MemoryV2 retains facts. Skills owns playbooks and versions. Dream/REM owns reflections. Desk owns work and its execution lane. Context receipts and turn traces explain each turn. This screen does not write a parallel history.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Memories") { NativeAgentAppCoordinator.shared.request(.sidebar(.memories)) }
                    Button("Skills") { NativeAgentAppCoordinator.shared.request(.skillsTools(.skills)) }
                    Button("Desk") { NativeAgentAppCoordinator.shared.request(.sidebar(.desk)) }
                    Button("Diagnostics") { NativeAgentAppCoordinator.shared.request(.sidebar(.diagnostics)) }
                }
            }
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .disabled(refreshing)
        }
        .task { await refresh() }
    }

    private func metric(_ title: String, _ value: Int, _ icon: String) -> some View {
        NativeExperienceCard(title: title, icon: icon) {
            Text(value.formatted()).font(.title2.monospacedDigit().bold())
        }
    }

    private var timeline: [JourneyItem] {
        var rows = appModel.memories.map {
            JourneyItem(id: "memory:\($0.id)", date: $0.updatedAt ?? $0.createdAt, title: "Memory retained", detail: $0.text,
                        status: "\($0.layer) · \(Int(($0.confidence * 100).rounded()))% confidence", icon: "brain", color: .blue)
        }
        rows += appModel.skills.filter { $0.autoCreated == true || ($0.useCount ?? 0) > 0 }.map {
            JourneyItem(id: "skill:\($0.id)", date: $0.lastUsedAt ?? $0.updatedAt ?? $0.createdAt ?? "", title: $0.autoCreated == true ? "Skill learned" : "Skill used",
                        detail: $0.name, status: "\($0.useCount ?? 0) uses · \($0.status ?? "available")", icon: "puzzlepiece.extension", color: .purple)
        }
        rows += diary.entries.map {
            JourneyItem(id: "dream:\($0.id)", date: $0.modified_at ?? $0.date, title: "Dream / REM reflection",
                        detail: firstLine($0.content), status: $0.date, icon: "moon.stars", color: .indigo)
        }
        rows += appModel.memoryProposals.filter { $0.status == "pending" }.map {
            JourneyItem(id: "proposal:\($0.id)", date: $0.last_seen, title: "Memory proposed",
                        detail: $0.display_text ?? $0.fact_text, status: $0.evidenceSummary, icon: "questionmark.bubble", color: .orange)
        }
        return rows.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    @MainActor private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await appModel.refreshForSidebarItem(.memories)
        await appModel.refreshForSidebarItem(.capabilities)
        _ = await appModel.refreshSchedulerJobs()
        if let value = await appModel.fetchDreamDiary(limit: 12) { diary = value }
    }

    private func firstLine(_ value: String) -> String {
        String(value.split(whereSeparator: \.isNewline).map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("#") }?.prefix(220) ?? "Reflection recorded")
    }
}

private struct JourneyItem: Identifiable {
    let id: String
    let date: String
    let title: String
    let detail: String
    let status: String
    let icon: String
    let color: Color
}
