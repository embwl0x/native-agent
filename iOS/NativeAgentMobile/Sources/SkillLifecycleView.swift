// SkillLifecycleView.swift — iOS skill catalog (iCloud-only).
// Data: iCloudSyncEngine reads `snapshots/skills_snapshot.json` (Mac publishes).
// Lifecycle changes remain on the Mac, where the canonical registry and OAuth
// owners can verify their outcomes.
import SwiftUI
import NativeAgentShared

// MARK: - Snapshot model

/// Decoded from the skills snapshot — one entry per skill in the manifest.
struct SkillManifestEntry: Codable, Identifiable, Hashable {
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

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(triggers, forKey: .triggers)
        try c.encodeIfPresent(use_count, forKey: .use_count)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encodeIfPresent(version, forKey: .version)
    }
}

/// Thin wrapper so the store can hold a [String: Any] response if the endpoint
/// returns a dict-of-dicts rather than an array. We try array first.
private struct SkillListResponse: Decodable {
    var skills: [SkillManifestEntry]
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

    static func stateColor(for skill: SkillManifestEntry) -> Color {
        stateColor(for: canonicalState(for: skill))
    }

    static func stateColor(for state: CanonicalState) -> Color {
        switch state {
        case .on: return .green
        case .draft: return .orange
        case .archived, .off: return .gray
        case .quarantined: return .red
        case .unknown: return .secondary
        }
    }
}

enum SkillSourcePresentation {
    enum Source: Equatable {
        case persona, learned, registry
        case unknown(String?)
    }

    static func source(for skill: SkillManifestEntry) -> Source {
        switch skill.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "persona": return .persona
        case "learned", "data": return .learned
        case "registry": return .registry
        default: return .unknown(skill.source)
        }
    }

    static func label(for source: Source) -> String {
        switch source {
        case .persona: return "PERSONA"
        case .learned: return "LEARNED"
        case .registry: return "REGISTRY"
        case .unknown(let raw):
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? "UNKNOWN" : value.uppercased()
        }
    }

    static func color(for source: Source) -> Color {
        switch source {
        case .persona: return .purple
        case .learned: return .teal
        case .registry: return .indigo
        case .unknown: return .secondary
        }
    }
}

// MARK: - Store

@MainActor
final class SkillLifecycleStore: ObservableObject {
    @Published var skills: [SkillManifestEntry] = []
    @Published var isLoading = false
    @Published var bannerError: String?

    // MARK: Fetch (iCloud snapshot)

    func refresh(pairingStore: PairingStore, pollIncoming: Bool = true) async {
        isLoading = true
        defer { isLoading = false }

        guard applyPairingGate(isPaired: pairingStore.isPaired) else { return }

        let engine = iCloudSyncEngine.shared
        if pollIncoming { await iCloudBridge.shared.pollIncomingNow() }
        if let arr: [SkillManifestEntry] = await engine.loadSnapshotArrayAsync(named: "skills_snapshot.json") {
            guard !Task.isCancelled else { return }
            withAnimation(AppMotion.snappy) { skills = Self.mergedSkills(learned: arr, manifest: []) }
            return
        }
        if let wrapped: SkillListResponse = await engine.loadSnapshotObjectAsync(named: "skills_snapshot.json") {
            guard !Task.isCancelled else { return }
            withAnimation(AppMotion.snappy) { skills = Self.mergedSkills(learned: wrapped.skills, manifest: []) }
            return
        }
        if skills.isEmpty {
            bannerError = "No skills synced yet — Mac is publishing."
        }
    }

    /// A prior paired snapshot is no longer current once pairing is absent.
    /// Clearing it prevents an old Mac catalog from looking live behind an
    /// unpaired warning banner.
    @discardableResult
    func applyPairingGate(isPaired: Bool) -> Bool {
        guard isPaired else {
            skills = []
            bannerError = "Pair iPhone with the Mac to see skills."
            return false
        }
        bannerError = nil
        return true
    }

    private static func mergedSkills(learned: [SkillManifestEntry], manifest: [SkillManifestEntry]) -> [SkillManifestEntry] {
        var seen: Set<String> = []
        var merged: [SkillManifestEntry] = []

        func append(_ skill: SkillManifestEntry) {
            let key = (skill.id.isEmpty ? skill.name : skill.id).lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            // A missing or blank producer provenance is meaningful: retain it
            // so the screen can say Unknown instead of inventing "learned".
            merged.append(skill)
        }

        // Learned skills are the useful runtime catalog; manifest skills are
        // connector/tool packs and should supplement, not hide, that list.
        for skill in learned {
            append(skill)
        }
        for skill in manifest {
            append(skill)
        }
        return merged
    }
}

// MARK: - Top-level view

struct SkillLifecycleView: View {
    /// Rides under the page header (Skills & Tools puts its page switch here).
    var accessory: AnyView = AnyView(EmptyView())
    @EnvironmentObject private var pairingStore: PairingStore
    @StateObject private var store = SkillLifecycleStore()
    @ObservedObject private var sync = iCloudSyncEngine.shared

    @State private var filter: SkillFilter = .all
    @State private var selectedSkill: SkillManifestEntry?

    private var allSkills: [SkillManifestEntry] { MobileDesignSamples.rows(store.skills) }

    private var filtered: [SkillManifestEntry] {
        SkillLifecyclePresentation.filtered(
            allSkills,
            state: filter == .all ? nil : filter.rawValue.lowercased()
        )
    }

    var body: some View {
        AlivePage(title: "Skills & Tools", line: "What I can do, and how.",
                 freshnessGroup: "skills_snapshot", accessory: accessory) {
            if !store.skills.isEmpty, let err = store.bannerError {
                AliveFootnote(err, systemImage: "wifi.slash")
                    .transition(.opacity)
            }

            if store.isLoading && allSkills.isEmpty {
                shimmerCard
            } else if allSkills.isEmpty, let error = store.bannerError {
                AliveCalmState(title: "Skills aren’t here yet", line: error,
                               actionTitle: "Try again") {
                    Task { await store.refresh(pairingStore: pairingStore) }
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
                        SkillRow(skill: skill) { selectedSkill = skill }
                    }
                }
            }
        }
        .animation(AppMotion.snappy, value: store.bannerError)
        .refreshable {
            await store.refresh(pairingStore: pairingStore)
        }
        .task(id: sync.groupTransportDeliveryAt["catalog"]) {
            await store.refresh(pairingStore: pairingStore,
                                pollIncoming: sync.groupTransportDeliveryAt["catalog"] == nil)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-designDetail") { selectedSkill = allSkills.first }
            #endif
        }
        .sheet(item: $selectedSkill) { skill in
            SkillLifecycleDetailSheet(skill: skill)
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
        case .archived: return "No archived skills. Unused skills are archived, kept and available to restore on the Mac."
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
        parts.append(SkillSourcePresentation.label(for: SkillSourcePresentation.source(for: skill)).lowercased())
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

                AliveSection("About", footer: "Skills move from draft to on to archived. Manage skills on the Mac; archived skills are kept and can be restored.") {
                    AliveRow("State") { value(SkillLifecyclePresentation.stateLabel(for: skill)) }
                    AliveDivider()
                    AliveRow("Source") {
                        value(AliveWords.humanized(SkillSourcePresentation.label(for: SkillSourcePresentation.source(for: skill)).lowercased()))
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
