// Built-in guidance is read, never run; executable parts belong on Tools.
import SwiftUI
import NativeAgentShared
// Blueprint: | `SkillLifecycleView.swift` | Built-in guidance and ID-resolved details; Tools owns abilities; SkillsToolsView owns refresh/loading |

// MARK: - Snapshot model

struct SkillManifestEntry: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let source: String
    let bodyRevision: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, description, source, bodyRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Guidance requires its canonical identity.")
        }
        description = try c.decode(String.self, forKey: .description)
        source = try c.decode(String.self, forKey: .source)
        guard source == "persona_body" else {
            throw DecodingError.dataCorruptedError(forKey: .source, in: c, debugDescription: "Built-in guidance requires persona_body provenance.")
        }
        bodyRevision = try c.decodeIfPresent(String.self, forKey: .bodyRevision)
    }
}

// MARK: - Top-level view

struct SkillLifecycleView: View {
    let accessory: AnyView
    let isLoading: Bool
    let error: String?
    let refresh: () async -> Void
    private let sync = iCloudSyncEngine.shared

    @State private var selectedSkillID: String?

    private var allSkills: [SkillManifestEntry] { MobileDesignSamples.rows(sync.skills) }

    var body: some View {
        AlivePage(title: "Skills & Tools", line: "What I can do, and how.",
                 freshnessGroup: "skills_snapshot", accessory: accessory) {
            if !sync.skills.isEmpty, let err = error {
                AliveFootnote(err, systemImage: "wifi.slash")
                    .transition(.opacity)
            }

            if isLoading && allSkills.isEmpty {
                shimmerCard
            } else if allSkills.isEmpty, let error {
                AliveCalmState(title: "Skills aren’t here yet", line: error,
                               actionTitle: "Try again") {
                    Task { await refresh() }
                }
            } else if allSkills.isEmpty {
                AliveCalmState(title: "No built-in guidance published", line: emptyDescription)
            } else {
                AliveSection("Built-in guidance") {
                    ForEach(Array(allSkills.enumerated()), id: \.element.id) { index, skill in
                        if index > 0 { AliveDivider() }
                        SkillRow(skill: skill) { selectedSkillID = skill.id }
                    }
                }
            }
        }
        .animation(AppMotion.snappy, value: error)
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-designDetail") { selectedSkillID = allSkills.first?.id }
        }
        #endif
        .sheet(isPresented: Binding(get: { selectedSkillID != nil }, set: { if !$0 { selectedSkillID = nil } })) {
            if let skill = allSkills.first(where: { $0.id == selectedSkillID }) {
                SkillLifecycleDetailSheet(skill: skill)
            } else {
                AliveCalmState(title: "Skill unavailable", line: "This skill is no longer in the published catalog.")
            }
        }
    }

    // MARK: Subviews

    private var shimmerCard: some View {
        AliveCard {
            ForEach(0..<3, id: \.self) { index in
                if index > 0 { AliveDivider() }
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(AlivePalette.divider).frame(width: 180, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(AlivePalette.divider).frame(height: 12)
                }
                .appShimmer()
                .aliveRow()
            }
        }
    }

    private var emptyDescription: String {
        "Skills are built-in guidance. The agent's abilities are on the Tools page."
    }
}

// MARK: - Skill row

struct SkillRow: View {
    let skill: SkillManifestEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.body)
                        .foregroundStyle(AlivePalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.subheadline)
                            .foregroundStyle(AlivePalette.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Built-in guidance")
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AliveChevron()
            }
            .aliveRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail sheet

struct SkillLifecycleDetailSheet: View {
    let skill: SkillManifestEntry

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AlivePage(title: skill.name) {
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.body)
                        .lineSpacing(3)
                        .foregroundStyle(AlivePalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, -12)
                }

                AliveSection("About", footer: "Built-in guidance is read and followed. Executable abilities, senses and turns are on Tools.") {
                    AliveRow("Source") { value("Built in") }
                    if let revision = skill.bodyRevision {
                        AliveDivider()
                        AliveRow("Revision") { value(revision) }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(AlivePalette.text)
                }
            }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(AlivePalette.secondary)
            .multilineTextAlignment(.trailing)
    }
}
