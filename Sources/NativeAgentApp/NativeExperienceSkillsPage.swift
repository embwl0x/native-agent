import SwiftUI

struct NativeExperienceSkillsPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedSkillID: String?
    @State private var versions: [ExperienceSkillVersion] = []
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        HSplitView {
            List(appModel.skills, selection: $selectedSkillID) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                    Text(skill.status ?? "available").font(.caption).foregroundStyle(.secondary)
                }.tag(skill.id)
            }
            .frame(minWidth: 220, idealWidth: 270)

            NativeExperiencePage(
                title: selectedSkill?.name ?? "Skill Evolution",
                subtitle: "Version, archive, inspect, and restore inside the canonical Skills owner. Restoring never grants tools, permissions, or approval bypasses."
            ) {
                if let skill = selectedSkill {
                    NativeExperienceCard(title: "Current version", icon: "puzzlepiece.extension") {
                        Text(skill.description).font(.callout)
                        LabeledContent("Status", value: skill.status ?? "available")
                        LabeledContent("Uses", value: "\(skill.useCount ?? 0)")
                        LabeledContent("Updated", value: skill.updatedAt ?? skill.createdAt ?? "unknown")
                        HStack {
                            Button("Read canonical skill") { NativeAgentAppCoordinator.shared.request(.skillsTools(.skills)) }
                            Button("Archive", role: .destructive) { Task { await archive(skill) } }
                                .disabled(busy || skill.status == "archived")
                            Spacer()
                            Button("Refresh versions", systemImage: "arrow.clockwise") { Task { await loadVersions() } }
                        }
                    }

                    NativeExperienceCard(title: "Version history", icon: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                        if versions.isEmpty {
                            Text("A version is recorded before and after canonical skill mutations. Existing untouched skills begin their history with the next mutation.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(versions) { version in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(version.reason.replacingOccurrences(of: "-", with: " ").capitalized).font(.headline)
                                    Spacer()
                                    Text(version.createdAt).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Text("\(version.status ?? "unknown") · \(version.bodySHA256.isEmpty ? "body unavailable" : String(version.bodySHA256.prefix(16)) + "…")")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                Button("Restore this exact version") { Task { await restore(skill, version: version) } }
                                    .buttonStyle(.link).disabled(busy)
                            }
                            Divider()
                        }
                    }
                } else {
                    ContentUnavailableView("Choose a skill", systemImage: "arrow.triangle.branch")
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .task {
            await appModel.refreshForSidebarItem(.capabilities)
            selectedSkillID = selectedSkillID ?? appModel.skills.first?.id
            await loadVersions()
        }
        .onChange(of: selectedSkillID) { _, _ in Task { await loadVersions() } }
    }

    private var selectedSkill: SkillRecord? { appModel.skills.first { $0.id == selectedSkillID } }

    @MainActor private func loadVersions() async {
        guard let id = selectedSkillID else { versions = []; return }
        do { versions = try await appModel.client.skillVersions(id: id); error = nil }
        catch { self.error = error.localizedDescription; versions = [] }
    }

    @MainActor private func archive(_ skill: SkillRecord) async {
        busy = true; defer { busy = false }
        do {
            _ = try await appModel.client.archiveSkill(id: skill.id)
            await appModel.refreshForSidebarItem(.capabilities)
            await loadVersions()
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func restore(_ skill: SkillRecord, version: ExperienceSkillVersion) async {
        busy = true; defer { busy = false }
        do {
            _ = try await appModel.client.restoreSkill(id: skill.id, versionId: version.id)
            await appModel.refreshForSidebarItem(.capabilities)
            await loadVersions()
        } catch { self.error = error.localizedDescription }
    }
}
