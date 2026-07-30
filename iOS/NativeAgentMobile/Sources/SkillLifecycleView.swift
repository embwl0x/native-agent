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
    var state: String?          // "drafted" | "installed" | "active" | "dormant" | "quarantined"
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
        state = Self.normalizedState(rawState)
        version = try? c.decode(String.self, forKey: .version)
    }

    private static func normalizedState(_ raw: String?) -> String? {
        switch (raw ?? "").lowercased() {
        case "enabled", "active": return "active"
        case "installed", "available", "proposal": return "installed"
        case "draft", "drafted": return "drafted"
        case "disabled", "dormant": return "dormant"
        case "quarantine", "quarantined": return "quarantined"
        default: return raw
        }
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
    case drafted  = "Drafted"
    case installed = "Installed"
    case active   = "Active"
    case dormant  = "Dormant"
    var id: String { rawValue }
}

// MARK: - Store

@MainActor
final class SkillLifecycleStore: ObservableObject {
    @Published var skills: [SkillManifestEntry] = []
    @Published var isLoading = false
    @Published var bannerError: String?

    // MARK: Fetch (iCloud snapshot)

    func refresh(pairingStore: PairingStore) async {
        guard pairingStore.isPaired else {
            bannerError = "Pair iPhone with the Mac to see skills."
            return
        }
        bannerError = nil
        isLoading = true
        defer { isLoading = false }

        let engine = iCloudSyncEngine.shared
        await iCloudBridge.shared.pollIncomingNow()
        if let arr: [SkillManifestEntry] = await engine.loadSnapshotArrayAsync(named: "skills_snapshot.json") {
            withAnimation(AppMotion.snappy) { skills = Self.mergedSkills(learned: arr, manifest: []) }
            return
        }
        if let wrapped: SkillListResponse = await engine.loadSnapshotObjectAsync(named: "skills_snapshot.json") {
            withAnimation(AppMotion.snappy) { skills = Self.mergedSkills(learned: wrapped.skills, manifest: []) }
            return
        }
        if skills.isEmpty {
            bannerError = "No skills synced yet — Mac is publishing."
        }
    }

    private static func mergedSkills(learned: [SkillManifestEntry], manifest: [SkillManifestEntry]) -> [SkillManifestEntry] {
        var seen: Set<String> = []
        var merged: [SkillManifestEntry] = []

        func append(_ skill: SkillManifestEntry, fallbackSource: String) {
            let key = (skill.id.isEmpty ? skill.name : skill.id).lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            var normalized = skill
            if normalized.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                normalized.source = fallbackSource
            }
            merged.append(normalized)
        }

        // Learned skills are the useful runtime catalog; manifest skills are
        // connector/tool packs and should supplement, not hide, that list.
        for skill in learned {
            append(skill, fallbackSource: "learned")
        }
        for skill in manifest {
            append(skill, fallbackSource: "registry")
        }
        return merged
    }
}

// MARK: - Top-level view

struct SkillLifecycleView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @StateObject private var store = SkillLifecycleStore()

    @State private var filter: SkillFilter = .all
    @State private var selectedSkill: SkillManifestEntry?

    private var filtered: [SkillManifestEntry] {
        switch filter {
        case .all:       return store.skills
        case .drafted:   return store.skills.filter { $0.state == "drafted" }
        case .installed: return store.skills.filter { $0.state == "installed" }
        case .active:    return store.skills.filter { $0.state == "active" }
        case .dormant:   return store.skills.filter { $0.state == "dormant" }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if !store.skills.isEmpty {
                    Picker("Filter", selection: $filter) {
                        ForEach(SkillFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                if store.isLoading && store.skills.isEmpty {
                    shimmerRows
                } else if store.skills.isEmpty, let error = store.bannerError {
                    AppEmptyState(
                        title: "Skills unavailable",
                        systemImage: "iphone.and.arrow.forward",
                        description: error
                    )
                } else if filtered.isEmpty {
                    AppEmptyState(
                        title: "No skills match this filter",
                        systemImage: "sparkles",
                        description: emptyDescription
                    )
                } else {
                    skillList
                }
            }

            // Banners
            VStack(spacing: 0) {
                if !store.skills.isEmpty, let err = store.bannerError {
                    SkillBannerView(message: err, style: .error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(AppMotion.snappy, value: store.bannerError)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.isLoading {
                    ProgressView().scaleEffect(0.8)
                }
            }
        }
        .refreshable {
            await store.refresh(pairingStore: pairingStore)
        }
        .task {
            await store.refresh(pairingStore: pairingStore)
        }
        .sheet(item: $selectedSkill) { skill in
            SkillLifecycleDetailSheet(skill: skill)
        }
    }

    // MARK: Subviews

    private var skillList: some View {
        List {
            ForEach(filtered) { skill in
                SkillRow(skill: skill) {
                    selectedSkill = skill
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .listStyle(.plain)
    }

    private var shimmerRows: some View {
        List {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 100)
                    .appShimmer()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    private var emptyDescription: String {
        switch filter {
        case .all:       return "No skills found. The Mac's skill manifest is empty or unreachable."
        case .drafted:   return "No drafted skills. Skills drafted by the agent appear here before installation."
        case .installed: return "No installed skills. Skills move to Installed after you approve them."
        case .active:    return "No active skills. Skills become Active the first time the agent calls them."
        case .dormant:   return "No dormant skills. Dormant skills haven't been called in a while."
        }
    }
}

// MARK: - Skill row card

struct SkillRow: View {
    let skill: SkillManifestEntry
    let onTap: () -> Void

    private var stateColor: Color {
        switch skill.state ?? "" {
        case "active":      return .green
        case "installed":   return .blue
        case "drafted":     return .orange
        case "dormant":     return .gray
        case "quarantined": return .red
        default:            return .secondary
        }
    }

    private var sourceColor: Color {
        switch (skill.source ?? "").lowercased() {
        case "persona":  return .purple
        case "learned", "data": return .teal
        case "registry": return .indigo
        default:         return .secondary
        }
    }

    private var sourceBadgeLabel: String {
        switch (skill.source ?? "").lowercased() {
        case "persona":  return "PERSONA"
        case "learned", "data": return "LEARNED"
        case "registry": return "REGISTRY"
        default:         return (skill.source ?? "UNKNOWN").uppercased()
        }
    }

    var body: some View {
        Button(action: onTap) {
            GlassCard(tint: stateColor) {
                VStack(alignment: .leading, spacing: 10) {
                    // Header row
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if skill.state == "active" {
                                    PulsingDot(color: .green, size: 7)
                                }
                                Text(skill.name)
                                    .font(AppFont.section)
                                    .lineLimit(1)
                            }
                            // State badge
                            Text((skill.state ?? "unknown").capitalized)
                                .font(AppFont.label)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(stateColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(stateColor)
                        }
                        Spacer()
                        // Source badge
                        if skill.source != nil {
                            Text(sourceBadgeLabel)
                                .font(AppFont.tag)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(sourceColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(sourceColor)
                        }
                    }

                    // Description
                    if let desc = skill.description, !desc.isEmpty {
                        Text(desc)
                            .font(AppFont.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    // Triggers
                    if let triggers = skill.triggers, !triggers.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(triggers.prefix(5), id: \.self) { trigger in
                                    Text(trigger)
                                        .font(AppFont.tag)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12))
                                        .foregroundStyle(.secondary)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    // Use count footnote
                    if let count = skill.use_count {
                        Text("Used \(count) time\(count == 1 ? "" : "s")")
                            .font(AppFont.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail sheet

struct SkillLifecycleDetailSheet: View {
    let skill: SkillManifestEntry

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Metadata section
                    VStack(alignment: .leading, spacing: 8) {
                        if let desc = skill.description, !desc.isEmpty {
                            Text(desc)
                                .font(AppFont.body)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            if let state = skill.state {
                                stateChip(state)
                            }
                            if let source = skill.source {
                                sourceChip(source)
                            }
                            if let kind = skill.kind {
                                Text(kind.capitalized)
                                    .font(AppFont.tag)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let count = skill.use_count {
                            Label("Used \(count) time\(count == 1 ? "" : "s")", systemImage: "chart.bar")
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                        }

                        if let triggers = skill.triggers, !triggers.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Triggers")
                                    .font(AppFont.label)
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 4) {
                                        ForEach(triggers, id: \.self) { t in
                                            Text(t)
                                                .font(AppFont.tag)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.12))
                                                .foregroundStyle(.secondary)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)

                    Label(
                        "Install, activate, quarantine, and delete skills from the Mac Skills view so OAuth, registry state, and the final result can be verified in one place.",
                        systemImage: "macbook"
                    )
                        .font(AppFont.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
                .padding(.top, 12)
            }
            .navigationTitle(skill.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: Badge helpers

    private func stateChip(_ state: String) -> some View {
        let color: Color = {
            switch state {
            case "active":      return .green
            case "installed":   return .blue
            case "drafted":     return .orange
            case "dormant":     return .gray
            case "quarantined": return .red
            default:            return .secondary
            }
        }()
        return Text(state.capitalized)
            .font(AppFont.label)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func sourceChip(_ source: String) -> some View {
        let (label, color): (String, Color) = {
            switch source.lowercased() {
            case "persona":  return ("PERSONA", .purple)
            case "learned", "data": return ("LEARNED", .teal)
            case "registry": return ("REGISTRY", .indigo)
            default:         return (source.uppercased(), .secondary)
            }
        }()
        return Text(label)
            .font(AppFont.tag)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - SkillBannerView — local banner (BannerView in ApprovalsView.swift is private)

private struct SkillBannerView: View {
    enum Style { case error }
    let message: String
    let style: Style

    private var bgColor: Color {
        Color.red.opacity(0.85)
    }
    private var icon: String {
        "wifi.slash"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(message).font(AppFont.label).lineLimit(2)
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bgColor)
        .ignoresSafeArea(edges: .horizontal)
    }
}
