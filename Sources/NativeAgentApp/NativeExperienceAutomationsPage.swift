import SwiftUI

struct NativeExperienceAutomationsPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedWorkspaceID: String?
    @State private var outcomes: [ExperienceBlueprintID: ExperienceBlueprintInstallOutcome] = [:]
    @State private var installing: ExperienceBlueprintID?

    var body: some View {
        NativeExperiencePage(
            title: "Automation Blueprints",
            subtitle: "Inspectable templates compiled into the existing TriggerScheduler and Desk execution lane. Installing is explicit and idempotent; hiding this page never cancels a schedule."
        ) {
            NativeExperienceCard(title: "Installation target", icon: "calendar.badge.plus") {
                Picker("Project Space", selection: $selectedWorkspaceID) {
                    Text("General / no project").tag(String?.none)
                    ForEach(appModel.workspaces) { workspace in Text(workspace.name).tag(Optional(workspace.id)) }
                }
                Text("Project-aware blueprints store only the canonical workspace identifier. Execution stays on the Desk and inside its trust boundary.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(NativeExperienceCatalogs.blueprints) { blueprint in
                NativeExperienceCard(title: blueprint.title, icon: icon(blueprint.id)) {
                    Text(blueprint.summary).font(.callout)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow { Text("Route").foregroundStyle(.secondary); Text(blueprint.modelLabel) }
                        GridRow { Text("Cost shape").foregroundStyle(.secondary); Text(blueprint.estimatedCost) }
                        GridRow { Text("Evidence").foregroundStyle(.secondary); Text(blueprint.expectedEvidence) }
                        GridRow { Text("Delivery").foregroundStyle(.secondary); Text(blueprint.delivery.joined(separator: " · ")) }
                    }
                    DisclosureGroup("Tools and trust") {
                        Text(blueprint.requiredTools.joined(separator: " · ")).font(.caption.monospaced())
                        Text(blueprint.trustImplications).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Install blueprint", systemImage: "plus.circle") {
                            Task {
                                installing = blueprint.id
                                outcomes[blueprint.id] = await appModel.installExperienceBlueprint(
                                    blueprint,
                                    projectSpaceId: selectedWorkspaceID
                                )
                                installing = nil
                            }
                        }
                        .disabled(installing != nil)
                        if let result = outcomes[blueprint.id] {
                            Text(result.message).font(.caption).foregroundStyle(outcomeColor(result))
                        }
                        Spacer()
                    }
                }
            }

            NativeExperienceCard(title: "Canonical schedules", icon: "clock") {
                if appModel.jobs.isEmpty { Text("No schedules are installed.").foregroundStyle(.secondary) }
                ForEach(appModel.jobs) { job in
                    LabeledContent(job.name) {
                        Text(job.enabled ? "enabled" : "paused")
                            .foregroundStyle(job.enabled ? Color.green : Color.secondary)
                    }
                }
                HStack {
                    Button("Open Scheduler") { NativeAgentAppCoordinator.shared.request(.sidebar(.desk)) }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { _ = await appModel.refreshSchedulerJobs() } }
                }
            }
        }
        .task {
            await appModel.refreshForSidebarItem(.connectors)
            _ = await appModel.refreshSchedulerJobs()
        }
    }

    private func icon(_ id: ExperienceBlueprintID) -> String {
        switch id {
        case .morningBriefing: "sunrise"
        case .projectStatus: "checklist"
        case .repositoryMaintenance: "wrench.and.screwdriver"
        case .calendarPreparation: "calendar"
        case .serviceWatch: "eye"
        case .weeklyMemoryReview: "brain"
        case .deliveredReport: "doc.text"
        }
    }

    private func outcomeColor(_ result: ExperienceBlueprintInstallOutcome) -> Color {
        if case .failed = result { return .orange }
        return .secondary
    }
}
