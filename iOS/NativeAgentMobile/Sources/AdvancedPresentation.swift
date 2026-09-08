import SwiftUI
import NativeAgentShared

/// Process-local screenshot fixtures. Never published to a store or transport.
enum MobileDesignSamples {
    static var screen: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-designScreen"), args.indices.contains(index + 1) {
            return args[index + 1]
        }
        #endif
        return nil
    }

    static func rows<T: Decodable>(_ live: [T]) -> [T] {
        #if DEBUG
        guard screen != nil, live.isEmpty, let json = fixtures[String(describing: T.self)] else { return live }
        // A malformed shipped DEBUG fixture must fail visibly, never masquerade as an empty screen.
        return try! JSONDecoder().decode([T].self, from: Data(json.utf8))
        #else
        return live
        #endif
    }

    #if DEBUG
    private static let fixtures: [String: String] = [
        "ProviderInfo": #"[{"provider_id":"design-provider","display_name":"Research and long-form writing provider","auth_modes":["api_key"],"auth_status":{"provider_id":"design-provider","state":"ready","detail":"Connected"},"models":[]}]"#,
        "ApprovalRequest": #"[{"id":"design-approval","title":"Review the weekend project plan before sharing","action":"Share project summary","risk":"medium","reason":"The summary includes the updated milestones and a link to the working draft.","status":"pending","localOnly":false,"remoteResolvable":true}]"#,
        "InboxItemRecord": #"[{"id":"design-inbox","created_at":"2026-09-07T18:00:00Z","source":"desk","severity":"info","title":"The research summary is ready to read","summary":"Three sources agree on the main result. One open question is included for the next conversation.","actions":[],"status":"unread"}]"#,
        "MobileDeskItem": #"[{"handle":"design-desk","alias":"D-14","kind":"task","status":"active","project":"Weekend research and planning","title":"Collect the final notes for the project review","summary":"Compare the remaining sources and prepare a short summary.","openedAt":"2026-09-07T18:00:00Z","updatedAt":"2026-09-07T18:00:00Z","pinned":false,"blockedOn":[],"origin":"user","requiresOwnerInput":false,"recentNotes":[]}]"#,
        "WorkshopTaskRecord": #"[{"id":"design-task","title":"Prepare the project reading list","objective":"Collect the most useful references and explain what each adds.","status":"running","phase":"Research","summary":"Reviewing the final two references.","createdAt":"2026-09-07T18:00:00Z"}]"#,
        "TrainingProposalSummary": #"[{"id":"design-training","title":"Make project summaries easier to scan","status":"pending","proposed":"Start with the decision, then include the evidence and next step.","rationale":"Keep longer updates useful on a small screen."}]"#,
        "KGEntity": #"[{"id":"design-entity","name":"Weekend research and planning","type":"project","mention_count":12,"aliases":["Reading list"],"summary":"A collection of references and decisions for the next project review."}]"#,
        "SkillManifestEntry": #"[{"id":"design-skill","name":"Research notes and source comparison","description":"Collect useful sources, compare the evidence, and write a concise summary.","source":"learned","state":"active","use_count":8,"version":"1.2"}]"#,
        "TurnSummaryRecord": #"[{"id":"design-turn","surface":"iPhone conversation","startedAt":810000000,"lastAt":810000008,"eventCount":12,"wallMs":8200,"llmTokens":1240,"ttftMs":430,"kinds":{"reply":1,"tool":2}}]"#
    ]
    #endif
}

/// Secondary screens consume the shared foundation without adding another palette.
struct MobileReadingSurface<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(NativeAgentMobileTheme.Spacing.lg)
            .background(NativeAgentMobileTheme.Colors.contentSurface,
                        in: RoundedRectangle(cornerRadius: NativeAgentMobileTheme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: NativeAgentMobileTheme.Radius.card)
                    .strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : NativeAgentMobileTheme.Colors.hairline, lineWidth: 1)
            }
    }
}

struct MobileReadingSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        MobileReadingSurface { content }
    }
}

struct MobileReadingStat: View {
    let label: String
    let value: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        MobileAdaptiveRow(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).mobileTypography(.caption).foregroundStyle(.secondary)
                Text(value).mobileTypography(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }
}

struct MobileReadingEmptyState: View {
    let title: String
    let systemImage: String
    let kind: AppEmptyStateKind
    var description: String? = nil
    var tint: Color = .secondary
    var action: (title: String, systemImage: String, handler: () -> Void)? = nil

    var body: some View {
        VStack(spacing: NativeAgentMobileTheme.Spacing.lg) {
            Image(systemName: systemImage)
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).mobileTypography(.title, weight: .semibold)
            if let description {
                Text(description).mobileTypography(.body).foregroundStyle(.secondary)
            }
            if let action {
                Button(action: action.handler) {
                    Label(action.title, systemImage: action.systemImage)
                        .frame(minHeight: NativeAgentMobileTheme.Layout.controlHeight)
                }
                .tint(NativeAgentMobileTheme.Colors.accentText)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(NativeAgentMobileTheme.Spacing.xl)
    }
}

/// Switch horizontal controls and facts to a reading column at accessibility sizes.
struct MobileAdaptiveRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat = NativeAgentMobileTheme.Spacing.sm
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        layout { content() }
    }
}

/// Action titles keep their intrinsic width; when the group cannot fit it becomes a column.
struct MobileActionRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                HStack(spacing: 8) { content() }
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) { content() }
        }
        .labelStyle(.titleOnly)
        .controlSize(.large)
    }
}

extension View {
    func mobileReadingScreen() -> some View {
        scrollContentBackground(.hidden)
            .background { MobileRoomBackground() }
            .tint(NativeAgentMobileTheme.Colors.accentText)
            .environment(\.defaultMinListRowHeight, NativeAgentMobileTheme.Layout.controlHeight)
            .navigationBarTitleDisplayMode(.inline)
            .allowsHitTesting(MobileDesignSamples.screen == nil)
    }
}

enum RunsLogPresentation: Equatable {
    case content
    case empty
    case unavailable(String)

    static func state(runs: [RunRecord], error: String?) -> RunsLogPresentation {
        guard runs.isEmpty else { return .content }
        if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unavailable(error)
        }
        return .empty
    }
}

enum RunKindPresentation {
    static func displayName(_ kind: String) -> String {
        RunKindVocabulary.displayName(kind, on: .iOS)
    }

    static func icon(_ kind: String) -> String {
        switch kind.lowercased() {
        case "codex": return "terminal"
        case "claude": return "sparkles"
        case "swarm": return "circle.hexagongrid.fill"
        case "mission": return "target"
        default: return "questionmark.circle"
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind.lowercased() {
        case "codex": return .teal
        case "claude": return NativeAgentPalette.agentAccent
        case "swarm": return .orange
        case "mission": return .blue
        default: return .secondary
        }
    }
}

struct RunDetailModelFact: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

enum RunDetailPresentation {
    static func modelFacts(for run: RunRecord) -> [RunDetailModelFact] {
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }

        var facts: [RunDetailModelFact] = []
        let model = nonEmpty(run.model)
        if let model { facts.append(.init(label: "Model", value: model)) }
        if let requested = nonEmpty(run.requestedModel), requested != model {
            facts.append(.init(label: "Requested (substituted)", value: requested))
        }
        if let effort = nonEmpty(run.reasoningEffort) {
            facts.append(.init(label: "Reasoning effort", value: effort.capitalized))
        }
        if let sandbox = nonEmpty(run.codexSandbox) {
            facts.append(.init(label: "Sandbox", value: sandbox))
        }
        if let fileAccess = nonEmpty(run.fileAccessMode) {
            facts.append(.init(label: "File access", value: fileAccess))
        }
        return facts
    }
}

enum RunDetailCopyPresentation {
    static func successMessage(for section: String) -> String {
        let label = section.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty
            ? "Copied run detail to clipboard."
            : "Copied \(label) to clipboard."
    }
}

enum RunDetailPromptPresentation {
    static let unavailableDescription = "The prompt was not captured for this run."

    /// Keep the captured prompt verbatim for copy fidelity, but do not render a
    /// prompt section (or a Copy action) for a blank payload.
    static func copyablePrompt(_ prompt: String?) -> String? {
        guard let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return prompt
    }
}

enum OrganismStatusPresentation {
    enum SnapshotState: Equatable {
        case available
        case disabled
        case unavailable(reason: String?)
        case invalidTimestamp(futureBy: TimeInterval)
        case stale(age: TimeInterval)
        case absent

        var displaysDetails: Bool {
            switch self {
            case .available, .stale: true
            case .disabled, .unavailable, .invalidTimestamp, .absent: false
            }
        }
    }

    struct DreamProposalSlice: Equatable {
        let visible: [OrganismLivingStandingViewProposalFile]
        let hiddenCount: Int
    }

    static func approvedBiasesText(_ value: Int?) -> String {
        value.map(String.init) ?? "Not reported"
    }

    static func canApprove(_ candidate: OrganismLivingReflexCandidateFile) -> Bool {
        candidate.trustClass == "lowRisk" && candidate.reviewRequired
    }

    static func isStale(generatedAt: Date, now: Date = Date(), maximumAge: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(generatedAt) > maximumAge
    }

    static func snapshotState(
        for organism: OrganismLivingStatusFile?,
        now: Date = Date(),
        maximumAge: TimeInterval = 300,
        maximumFutureClockSkew: TimeInterval = 60
    ) -> SnapshotState {
        guard let organism else { return .absent }
        switch organism.availabilityState {
        case .unavailable:
            return .unavailable(reason: organism.unavailableReason)
        case .disabled:
            return .disabled
        case .live:
            let age = now.timeIntervalSince(organism.generatedAt)
            let allowedFutureSkew = max(0, maximumFutureClockSkew)
            if age < -allowedFutureSkew {
                return .invalidTimestamp(futureBy: -age)
            }
            return age > maximumAge ? .stale(age: age) : .available
        }
    }

    static func staleAgeText(_ age: TimeInterval) -> String {
        let seconds = max(0, Int(age.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    struct ReflexCandidateSlice: Equatable {
        let visible: [OrganismLivingReflexCandidateFile]
        let hiddenCount: Int
    }

    static func reflexCandidateSlice(
        _ candidates: [OrganismLivingReflexCandidateFile],
        visibleLimit: Int = 6
    ) -> ReflexCandidateSlice {
        .init(visible: Array(candidates.prefix(visibleLimit)), hiddenCount: max(0, candidates.count - visibleLimit))
    }

    static func removingLocallyFinalizedCandidate(
        id: String,
        from candidates: [OrganismLivingReflexCandidateFile]
    ) -> [OrganismLivingReflexCandidateFile] {
        candidates.filter { $0.id != id }
    }

    static func dreamProposalSlice(
        _ proposals: [OrganismLivingStandingViewProposalFile],
        visibleLimit: Int = 4
    ) -> DreamProposalSlice {
        .init(visible: Array(proposals.prefix(visibleLimit)), hiddenCount: max(0, proposals.count - visibleLimit))
    }
}

enum MacHealthPresentation {
    enum Snapshot {
        case available(RuntimeHealth)
        case unavailable
    }

    static let unavailableTitle = "Mac health is unavailable"
    static let unavailableDetail = "Waiting for a health snapshot from the Mac."

    static func snapshot(for health: RuntimeHealth?) -> Snapshot {
        guard let health else { return .unavailable }
        return .available(health)
    }
}

/// One freshness contract for Mac-owned iCloud snapshots on the phone. Every
/// screen that reports a snapshot age must use this threshold rather than
/// deciding independently when a snapshot becomes stale.
enum MobileSnapshotFreshnessPresentation {
    static let staleAfter: TimeInterval = 30

    static func isStale(lastSyncedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSyncedAt) > staleAfter
    }
}

enum StatusConnectionPresentation {
    enum SyncState: Equatable {
        case current(age: TimeInterval)
        case stale(age: TimeInterval, limit: TimeInterval)
        case neverSynced
        case clockMismatch(futureBy: TimeInterval)
    }

    static func syncState(
        lastSyncedAt: Date?,
        now: Date = Date(),
        staleAfter: TimeInterval = MobileSnapshotFreshnessPresentation.staleAfter,
        maximumFutureClockSkew: TimeInterval = 60
    ) -> SyncState {
        guard let lastSyncedAt else { return .neverSynced }

        let age = now.timeIntervalSince(lastSyncedAt)
        if age < -max(0, maximumFutureClockSkew) {
            return .clockMismatch(futureBy: -age)
        }
        let limit = max(0, staleAfter)
        return age > limit ? .stale(age: age, limit: limit) : .current(age: max(0, age))
    }

    static func ageText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    static func cardValue(for state: SyncState) -> String {
        switch state {
        case .current(let age): return "Fresh · \(ageText(age)) ago"
        case .stale(let age, _): return "STALE · \(ageText(age)) old"
        case .neverSynced: return "Never synced"
        case .clockMismatch: return "Clock mismatch"
        }
    }

    static func detail(for state: SyncState) -> String? {
        switch state {
        case .current:
            return nil
        case .stale(_, let limit):
            return "Expected a newer iCloud snapshot within \(ageText(limit))."
        case .neverSynced:
            return "No iCloud snapshot has reached this phone yet."
        case .clockMismatch(let futureBy):
            return "The Mac snapshot is \(ageText(futureBy)) ahead of this phone."
        }
    }

    static func needsAttention(_ state: SyncState) -> Bool {
        switch state {
        case .current: false
        case .stale, .neverSynced, .clockMismatch: true
        }
    }
}
