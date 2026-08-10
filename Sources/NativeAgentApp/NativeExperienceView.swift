import SwiftUI

enum NativeExperienceSection: String, CaseIterable, Identifiable {
    case overview
    case context
    case projects
    case automations
    case capabilities
    case workbench
    case skills
    case remoteNodes

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Journey"
        case .context: "Context"
        case .projects: "Projects & Sessions"
        case .automations: "Automations"
        case .capabilities: "Capabilities"
        case .workbench: "Workbench"
        case .skills: "Skill Evolution"
        case .remoteNodes: "Remote Nodes"
        }
    }
    var icon: String {
        switch self {
        case .overview: "point.3.filled.connected.trianglepath.dotted"
        case .context: "gauge.with.dots.needle.67percent"
        case .projects: "folder.badge.gearshape"
        case .automations: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .capabilities: "square.grid.2x2"
        case .workbench: "rectangle.split.3x1"
        case .skills: "arrow.triangle.branch"
        case .remoteNodes: "network"
        }
    }
}

struct NativeExperienceView: View {
    @AppStorage(NativeExperiencePreferences.masterKey) private var enabled = false
    @AppStorage(NativeExperiencePreferences.journeyKey) private var journeyEnabled = true
    @AppStorage(NativeExperiencePreferences.contextKey) private var contextEnabled = true
    @AppStorage(NativeExperiencePreferences.projectsKey) private var projectsEnabled = true
    @AppStorage(NativeExperiencePreferences.automationsKey) private var automationsEnabled = true
    @AppStorage(NativeExperiencePreferences.capabilitiesKey) private var capabilitiesEnabled = true
    @AppStorage(NativeExperiencePreferences.lineageKey) private var lineageEnabled = true
    @AppStorage(NativeExperiencePreferences.workbenchKey) private var workbenchEnabled = true
    @AppStorage(NativeExperiencePreferences.diagnosticsKey) private var diagnosticsEnabled = true
    @AppStorage(NativeExperiencePreferences.kitsKey) private var kitsEnabled = true
    @AppStorage(NativeExperiencePreferences.remoteNodesKey) private var remoteNodesEnabled = true
    @AppStorage(NativeExperiencePreferences.skillEvolutionKey) private var skillEvolutionEnabled = true
    @State private var selection: NativeExperienceSection = .overview

    var body: some View {
        Group {
            if enabled {
                HSplitView {
                    List(availableSections, selection: $selection) { section in
                        Label(section.title, systemImage: section.icon)
                            .tag(section)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 175, idealWidth: 200, maxWidth: 230)

                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                NativeEmptyState(
                    title: "Classic NativeAgent Is Active",
                    detail: "The optional native experience makes existing intelligence, context, work, and receipts easier to see. It does not replace chat, Fluid Context, the subconscious, memory, tools, providers, or trust.",
                    systemImage: "sparkles",
                    actionTitle: "Enable Native Experience",
                    actionImage: "point.3.filled.connected.trianglepath.dotted",
                    action: { NativeExperiencePreferences.enableAll() }
                )
            }
        }
        .navigationTitle(selection.title)
        .onChange(of: availableSections) { _, sections in
            if !sections.contains(selection) { selection = sections.first ?? .overview }
        }
    }

    private var availableSections: [NativeExperienceSection] {
        NativeExperienceSection.allCases.filter { section in
            switch section {
            case .overview: journeyEnabled
            case .context: contextEnabled || diagnosticsEnabled
            case .projects: projectsEnabled || lineageEnabled
            case .automations: automationsEnabled
            case .capabilities: capabilitiesEnabled || kitsEnabled
            case .workbench: workbenchEnabled
            case .skills: skillEvolutionEnabled
            case .remoteNodes: remoteNodesEnabled
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .overview: NativeExperienceOverviewPage()
        case .context: NativeExperienceContextPage(showDiagnostics: diagnosticsEnabled)
        case .projects: NativeExperienceProjectsPage(showLineage: lineageEnabled)
        case .automations: NativeExperienceAutomationsPage()
        case .capabilities: NativeExperienceCapabilitiesPage(showKits: kitsEnabled)
        case .workbench: NativeExperienceWorkbenchPage()
        case .skills: NativeExperienceSkillsPage()
        case .remoteNodes: NativeExperienceRemoteNodesPage()
        }
    }
}

struct NativeExperiencePage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle.bold())
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(24)
        }
    }
}

struct NativeExperienceCard<Content: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let icon { Label(title, systemImage: icon).font(.headline) }
            else { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
