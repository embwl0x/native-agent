// SkillLifecycleView.swift — iOS skill catalog (iCloud-only).
// Data: iCloudSyncEngine reads `snapshots/skills_snapshot.json` (Mac publishes).
// Lifecycle changes remain on the Mac, where the canonical registry and OAuth
// owners can verify their outcomes.
import SwiftUI
import NativeAgentShared
// Blueprint: | `SkillLifecycleView.swift` | Shared typed skill catalog renderer, local filters and ID-resolved details; SkillsToolsView owns catalog refresh/loading |

// MARK: - Snapshot model

/// Decoded from the skills snapshot — one entry per skill in the manifest.
struct SkillManifestEntry: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
    var source: String?         // "persona" | "learned" | "data" | "registry"
    var kind: String?
    var triggers: [String]?
    var use_count: Int?
    var state: String?          // Mac lifecycle state; presentation also accepts legacy names.
    var version: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, description, source, kind, triggers, use_count, useCount, state, status, version
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = (try? c.decode(String.self, forKey: .id)) ?? name
        description = try? c.decode(String.self, forKey: .description)
        source = try? c.decode(String.self, forKey: .source)
        kind = try? c.decode(String.self, forKey: .kind)
        triggers = try? c.decode([String].self, forKey: .triggers)
        use_count = (try? c.decode(Int.self, forKey: .use_count)) ?? (try? c.decode(Int.self, forKey: .useCount))
        let rawState = (try? c.decode(String.self, forKey: .state)) ?? (try? c.decode(String.self, forKey: .status))
        state = rawState
        version = try? c.decode(String.self, forKey: .version)
    }
}

// MARK: - Filter enum

private enum SkillFilter: String, CaseIterable, Identifiable {
    case all      = "All"
    case draft    = "Draft"
    case on       = "On"
    case archived = "Archived"
    case off      = "Off"
    case quarantined = "Quarantined"
    case unknown = "Unknown"
    var id: String { rawValue }
}

enum SkillLifecyclePresentation {
    enum CanonicalState: Equatable {
        case draft, on, archived, off, quarantined
        case unknown(String?)
    }

    static func canonicalState(for skill: SkillManifestEntry) -> CanonicalState {
        canonicalState(raw: skill.state)
    }

    static func canonicalState(raw: String?) -> CanonicalState {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "draft", "drafted", "available", "proposal": return .draft
        case "on", "enabled", "installed", "active": return .on
        case "archived": return .archived
        case "off", "disabled", "dormant": return .off
        case "quarantine", "quarantined": return .quarantined
        default: return .unknown(raw)
        }
    }

    static func filtered(_ skills: [SkillManifestEntry], state: String?) -> [SkillManifestEntry] {
        guard let state else { return skills }
        if state == "unknown" {
            return skills.filter {
                if case .unknown = canonicalState(for: $0) { return true }
                return false
            }
        }
        return skills.filter { canonicalState(for: $0) == canonicalState(raw: state) }
    }

    static func stateLabel(for skill: SkillManifestEntry) -> String {
        stateLabel(for: canonicalState(for: skill))
    }

    static func stateLabel(for state: CanonicalState) -> String {
        switch state {
        case .draft: return "Draft"
        case .on: return "On"
        case .archived: return "Archived"
        case .off: return "Off"
        case .quarantined: return "Quarantined"
        case .unknown(let raw):
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? "State unknown" : "Unknown: \(value)"
        }
    }


}

enum SkillSourcePresentation {
    static func label(for skill: SkillManifestEntry) -> String {
        switch skill.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "persona": return "PERSONA"
        case "learned", "data": return "LEARNED"
        case "registry": return "REGISTRY"
        default:
            let value = skill.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? "UNKNOWN" : value.uppercased()
        }
    }


}

// MARK: - Top-level view

struct SkillLifecycleView: View {
    /// Rides under the page header (Skills & Tools puts its page switch here).
    let accessory: AnyView
    let isLoading: Bool
    let error: String?
    let refresh: () async -> Void
    private let sync = iCloudSyncEngine.shared

    @State private var filter: SkillFilter = .all
    @State private var selectedSkillID: String?

    private var allSkills: [SkillManifestEntry] { MobileDesignSamples.rows(sync.skills) }

    private var filtered: [SkillManifestEntry] {
        SkillLifecyclePresentation.filtered(
            allSkills,
            state: filter == .all ? nil : filter.rawValue.lowercased()
        )
    }

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
                AliveCalmState(title: "No skills yet", line: emptyDescription)
            } else {
                AliveSection("Skills", trailing: { filterMenu }) {
                    if filtered.isEmpty {
                        Text(emptyDescription)
                            .font(.subheadline)
                            .foregroundStyle(AlivePalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .aliveRow()
                    }
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, skill in
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

    /// The state filter, as quiet words beside the eyebrow.
    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(SkillFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(filter.rawValue)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(AlivePalette.text)
        }
        .accessibilityLabel("Filter: \(filter.rawValue)")
    }

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
        switch filter {
        case .all:       return "No skills found. The Mac's skill manifest is empty or unreachable."
        case .draft:    return "No drafts. New skills and upgrades wait here until they are turned on."
        case .on:       return "No skills are on. Turn on a skill on the Mac to make it available."
        case .archived: return "No archived skills. Archived records stay available to restore on the Mac."
        case .off:      return "No skills are off. Skills turned off on the Mac remain here."
        case .quarantined: return "No quarantined skills. Quarantined skills require Mac review before they can run again."
        case .unknown: return "No skills with unknown state. Their original Mac state is preserved when present."
        }
    }
}

/// State, where it came from and how often it has run, as one line of words.
private enum SkillLine {
    static func status(_ skill: SkillManifestEntry) -> String {
        var parts = [SkillLifecyclePresentation.stateLabel(for: skill)]
        parts.append(SkillSourcePresentation.label(for: skill).lowercased())
        if let count = skill.use_count { parts.append("used " + AliveWords.count(count, "time")) }
        return parts.joined(separator: " · ")
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
                    if let desc = skill.description, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(AlivePalette.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(SkillLine.status(skill))
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
                if let desc = skill.description, !desc.isEmpty {
                    Text(desc)
                        .font(.body)
                        .lineSpacing(3)
                        .foregroundStyle(AlivePalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, -12)
                }

                AliveSection("About", footer: "The Mac reports each skill's state. Manage skills and restore archived records there.") {
                    AliveRow("State") { value(SkillLifecyclePresentation.stateLabel(for: skill)) }
                    AliveDivider()
                    AliveRow("Source") {
                        value(AliveWords.humanized(SkillSourcePresentation.label(for: skill).lowercased()))
                    }
                    if let kind = skill.kind, !kind.isEmpty {
                        AliveDivider()
                        AliveRow("Kind") { value(AliveWords.humanized(kind)) }
                    }
                    if let count = skill.use_count {
                        AliveDivider()
                        AliveRow("Used") { value(AliveWords.count(count, "time")) }
                    }
                    if let version = skill.version, !version.isEmpty {
                        AliveDivider()
                        AliveRow("Version") { value(version) }
                    }
                    if let triggers = skill.triggers, !triggers.isEmpty {
                        AliveDivider()
                        AliveRow("Wakes on", detail: triggers.joined(separator: ", "))
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
