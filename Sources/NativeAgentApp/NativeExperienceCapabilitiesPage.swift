import SwiftUI

struct NativeExperienceCapabilitiesPage: View {
    @Environment(AppModel.self) private var appModel
    let showKits: Bool
    @State private var outcomes: [String: ExperienceKitActivationOutcome] = [:]

    var body: some View {
        NativeExperiencePage(
            title: "Capability Readiness",
            subtitle: "One readiness vocabulary over providers, connectors, tools, permissions, and health. Capability Kits select ready tools for this conversation; they never grant authority."
        ) {
            NativeExperienceCard(title: "Readiness ladder", icon: "checklist.checked") {
                HStack(spacing: 10) {
                    ForEach(ExperienceReadinessState.allCases, id: \.self) { state in
                        VStack(spacing: 3) {
                            Text("\(readiness.filter { $0.state == state }.count)").font(.title3.monospacedDigit().bold())
                            Text(state.title).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Divider()
                ForEach(readiness.prefix(80)) { item in
                    HStack(alignment: .top) {
                        Image(systemName: symbol(item.state)).foregroundStyle(color(item.state)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.callout.weight(.medium))
                            Text("\(item.category) · \(item.reason)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.state.title).font(.caption).foregroundStyle(color(item.state))
                        if let destination = item.fixDestination {
                            Button("Fix") { NativeAgentAppCoordinator.shared.request(.sidebar(destination)) }.buttonStyle(.link)
                        }
                    }
                    Divider()
                }
            }

            if showKits {
                NativeExperienceCard(title: "Capability Kits", icon: "square.grid.2x2") {
                    Text("A kit only changes ActiveToolsStore for the current canonical conversation. Missing or untrusted tools remain off.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(NativeExperienceCatalogs.kits) { kit in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(kit.title, systemImage: kit.systemImage).font(.headline)
                                Spacer()
                                Button("Activate") { Task { outcomes[kit.id] = await appModel.activateCapabilityKit(kit) } }
                                Button("Remove") { Task { outcomes[kit.id] = await appModel.deactivateCapabilityKit(kit) } }
                            }
                            Text(kit.summary).font(.callout).foregroundStyle(.secondary)
                            Text(kit.toolNames.sorted().joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            if let result = outcomes[kit.id] { Text(result.message).font(.caption).foregroundStyle(.secondary) }
                        }
                        Divider()
                    }
                }
            }

            HStack {
                Button("Providers") { NativeAgentAppCoordinator.shared.request(.sidebar(.providers)) }
                Button("Connectors") { NativeAgentAppCoordinator.shared.request(.sidebar(.connectors)) }
                Button("Trust Center") { NativeAgentAppCoordinator.shared.request(.sidebar(.trust)) }
                Button("Skills & Tools") { NativeAgentAppCoordinator.shared.request(.skillsTools(.tools)) }
            }
        }
        .task {
            await appModel.refreshForSidebarItem(.capabilities)
            await appModel.refreshForSidebarItem(.connectors)
            await appModel.refreshForSidebarItem(.providers)
            await appModel.refreshChatToolCatalog()
        }
    }

    private var readiness: [ExperienceReadinessItem] {
        NativeExperienceReadModels.readiness(
            providers: appModel.providersList,
            connectors: appModel.connectors,
            tools: appModel.tools,
            health: appModel.healthCard
        )
    }
    private func symbol(_ state: ExperienceReadinessState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .awaitingTrust: "lock.circle"
        case .needsSetup: "gearshape"
        case .unavailable: "xmark.circle"
        }
    }
    private func color(_ state: ExperienceReadinessState) -> Color {
        switch state {
        case .ready: .green
        case .degraded: .orange
        case .awaitingTrust: .purple
        case .needsSetup: .blue
        case .unavailable: .secondary
        }
    }
}
