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
    case quarantined = "Quarantined"
    case unknown = "Unknown"
    var id: String { rawValue }
}

enum SkillLifecyclePresentation {
    enum CanonicalState: Equatable {
        case drafted, installed, active, dormant, quarantined
        case unknown(String?)
    }

    static func canonicalState(for skill: SkillManifestEntry) -> CanonicalState {
        canonicalState(raw: skill.state)
    }

    static func canonicalState(raw: String?) -> CanonicalState {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "drafted": return .drafted
        case "installed": return .installed
        case "active": return .active
        case "dormant": return .dormant
        case "quarantined": return .quarantined
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
        return skills.filter { $0.state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == state }
    }

    static func stateLabel(for skill: SkillManifestEntry) -> String {
        stateLabel(for: canonicalState(for: skill))
    }

    static func stateLabel(for state: CanonicalState) -> String {
        switch state {
        case .drafted: return "Drafted"
        case .installed: return "Installed"
        case .active: return "Active"
        case .dormant: return "Dormant"
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
        case .active: return .green
        case .installed: return .blue
        case .drafted: return .orange
        case .dormant: return .gray
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

    func refresh(pairingStore: PairingStore) async {
        isLoading = true
        defer { isLoading = false }

        guard applyPairingGate(isPaired: pairingStore.isPaired) else { return }

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
    @EnvironmentObject private var pairingStore: PairingStore
    @StateObject private var store = SkillLifecycleStore()

    @State private var filter: SkillFilter = .all
    @State private var selectedSkill: SkillManifestEntry?

    private var filtered: [SkillManifestEntry] {
        SkillLifecyclePresentation.filtered(
            MobileDesignSamples.rows(store.skills),
            state: filter == .all ? nil : filter.rawValue.lowercased()
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if !MobileDesignSamples.rows(store.skills).isEmpty {
                    Picker("Filter", selection: $filter) {
                        ForEach(SkillFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                if store.isLoading && MobileDesignSamples.rows(store.skills).isEmpty {
                    shimmerRows
                } else if MobileDesignSamples.rows(store.skills).isEmpty, let error = store.bannerError {
                    MobileReadingEmptyState(
                        title: "Skills unavailable",
                        systemImage: "iphone.and.arrow.forward",
                        kind: .unavailable,
                        description: error,
                        action: (
                            title: "Try Again",
                            systemImage: "arrow.clockwise",
                            handler: {
                                Task { await store.refresh(pairingStore: pairingStore) }
                            }
                        )
                    )
                } else if filtered.isEmpty {
                    MobileReadingEmptyState(
                        title: "No skills match this filter",
                        systemImage: "sparkles",
                        kind: .empty,
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
        case .quarantined: return "No quarantined skills. Quarantined skills require Mac review before they can run again."
        case .unknown: return "No skills with unknown state. Their original Mac state is preserved when present."
        }
    }
}

// MARK: - Skill row card

struct SkillRow: View {
    let skill: SkillManifestEntry
    let onTap: () -> Void

    private var stateColor: Color {
        SkillLifecyclePresentation.stateColor(for: skill)
    }

    private var sourceColor: Color {
        SkillSourcePresentation.color(for: SkillSourcePresentation.source(for: skill))
    }

    private var sourceBadgeLabel: String {
        SkillSourcePresentation.label(for: SkillSourcePresentation.source(for: skill))
    }

    var body: some View {
        Button(action: onTap) {
            MobileReadingSurface {
                VStack(alignment: .leading, spacing: 12) {
                    // Header row
                    MobileAdaptiveRow(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            MobileAdaptiveRow(spacing: 6) {
                                if skill.state == "active" {
                                    Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(skill.name)
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            // State badge
                            Text(SkillLifecyclePresentation.stateLabel(for: skill))
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(NativeAgentMobileTheme.Colors.quietFill, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Source badge
                        Text(sourceBadgeLabel)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(NativeAgentMobileTheme.Colors.quietFill, in: Capsule())
                            .foregroundStyle(.secondary)
                    }

                    // Description
                    if let desc = skill.description, !desc.isEmpty {
                        Text(desc)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Triggers
                    if let triggers = skill.triggers, !triggers.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            MobileAdaptiveRow(spacing: 4) {
                                ForEach(triggers.prefix(5), id: \.self) { trigger in
                                    Text(trigger)
                                        .font(.caption)
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
                            .font(.callout)
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
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }

                        MobileAdaptiveRow(spacing: 8) {
                            if let state = skill.state {
                                stateChip(state)
                            }
                            sourceChip(skill)
                            if let kind = skill.kind {
                                Text(kind.capitalized)
                                    .font(.caption)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let count = skill.use_count {
                            Label("Used \(count) time\(count == 1 ? "" : "s")", systemImage: "chart.bar")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if let triggers = skill.triggers, !triggers.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Triggers")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    MobileAdaptiveRow(spacing: 4) {
                                        ForEach(triggers, id: \.self) { t in
                                            Text(t)
                                                .font(.caption)
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
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
                .padding(.top, 12)
            }
            .mobileReadingScreen()
            .navigationTitle(skill.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    MacStatusChip()
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: Badge helpers

    private func stateChip(_ state: String) -> some View {
        let canonical = SkillLifecyclePresentation.canonicalState(raw: state)
        let color = SkillLifecyclePresentation.stateColor(for: canonical)
        return Text(SkillLifecyclePresentation.stateLabel(for: canonical))
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(NativeAgentMobileTheme.Colors.quietFill, in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func sourceChip(_ skill: SkillManifestEntry) -> some View {
        let source = SkillSourcePresentation.source(for: skill)
        return Text(SkillSourcePresentation.label(for: source))
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(NativeAgentMobileTheme.Colors.quietFill, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

// MARK: - SkillBannerView — local banner (BannerView in ApprovalsView.swift is private)

private struct SkillBannerView: View {
    enum Style { case error }
    let message: String
    let style: Style

    private var bgColor: Color {
        NativeAgentMobileTheme.Colors.contentSurface
    }
    private var icon: String {
        "wifi.slash"
    }

    var body: some View {
        MobileAdaptiveRow(spacing: 8) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bgColor)
        .ignoresSafeArea(edges: .horizontal)
    }
}
