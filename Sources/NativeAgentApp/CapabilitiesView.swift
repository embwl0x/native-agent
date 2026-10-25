import EngineRuntime
import MemoryV2
import Foundation
import SystemOps
import ToolRegistry
import Research
import SwiftUI
import TrustCenter
import ApprovalInbox
import WorkflowOrchestration
// Blueprint: | `CapabilitiesView.swift` | `CapabilitiesView` struct; shared engine NextGen snapshot and eligible actions; `AppModel.routeIntent`; `NextGenReceipt.humanized` |


enum CapabilitiesDisclosurePreference {
    static let nextGenKey = "capabilitiesShowNextGen"
    /// The Developer fold the self-checks sit inside.
    static let developerKey = "capabilitiesShowDeveloper"

    /// Opening the self-checks opens the Developer fold around them too.
    static func setNextGenExpanded(_ isExpanded: Bool, in defaults: UserDefaults) {
        defaults.set(isExpanded, forKey: nextGenKey)
        if isExpanded { defaults.set(true, forKey: developerKey) }
    }
}

/// Counts and availability come from the same engine owners on every route.
enum CapabilitiesRefreshPresentation {
    struct SummaryTiles: Equatable {
        let nextGen: String
        let approvals: String
        let notice: String?
    }

    @MainActor
    static func summary(trust: TrustFacade, approvals: ApprovalsFacade, nextGen: NextGenStatusProjection) -> SummaryTiles {
        let unavailable = trust.catalogRefresh == nil
            ? "Capability summary is loading."
            : trust.catalogRefresh?.isStale != true && nextGen.readError == nil && approvals.refreshErrorText == nil ? nil
            : "Some of this could not be loaded; anything marked — is missing, not zero."
        return SummaryTiles(
            nextGen: nextGen.readError == nil ? nextGen.current.map { "\($0.summary.readyPhaseCount ?? 0)/\($0.summary.totalPhaseCount ?? 0)" } ?? "—" : "—",
            approvals: approvals.hasLoadedSnapshot && approvals.refreshErrorText == nil
                ? String(WorkOverviewRead.waitingApprovals(approvals.records).count) : "—",
            notice: unavailable
        )
    }
}

/// The footer reports this page's refresh receipt, rather than unrelated
/// operation feedback in AppModel.statusText. Domain values remain engine-owned.
enum CapabilitiesStatusLinePresentation {
    struct State: Equatable {
        let text: String
        let status: String
    }

    static func resolve(refresh: PanelRefreshStatus?) -> State {
        guard let refresh else {
            return State(text: "Capabilities data has not loaded yet.", status: "info")
        }
        guard !refresh.isStale else {
            let count = refresh.failedEndpoints.count
            let source = count == 1 ? "source" : "sources"
            guard refresh.lastSuccessAt != nil else {
                return State(text: "Capabilities data is unavailable: \(count) \(source) did not load.", status: "failed")
            }
            return State(text: "Capabilities refresh is incomplete: \(count) \(source) did not load. Showing last known data where available.", status: "warn")
        }
        return State(text: "Capabilities data is current.", status: "ok")
    }
}

struct CapabilitiesStatusTextLine: View {
    let state: CapabilitiesStatusLinePresentation.State

    var body: some View {
        Text(state.text)
            .font(ShellType.caption)
            .foregroundStyle(AdvancedStatusWords.color(state.status))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("capabilities.statusText")
    }
}

enum NativeMacPowerPanelPresentation {
    enum ReadState: Equatable {
        case loading
        case available
        case stale
        case unavailable
    }

    struct Tile: Equatable {
        let value: String
        let detail: String
        let status: String
        let readState: ReadState
    }

    struct Action: Equatable {
        let canDryRun: Bool
        let canRun: Bool
        let blockedDetail: String?
    }

    static func tile(
        value: String?,
        detail: String?,
        runtimeStatus: String?,
        hasRefreshAttempt: Bool,
        readFailed: Bool
    ) -> Tile {
        let hasContent = runtimeStatus?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if readFailed {
            return Tile(
                value: value ?? "—",
                detail: hasContent ? "Showing last loaded data; refresh failed." : "Status unavailable; refresh failed.",
                status: "warn",
                readState: hasContent ? .stale : .unavailable
            )
        }
        guard hasContent else {
            return Tile(
                value: "—",
                detail: hasRefreshAttempt ? "Status unavailable." : "Checking status…",
                status: hasRefreshAttempt ? "warn" : "info",
                readState: hasRefreshAttempt ? .unavailable : .loading
            )
        }
        return Tile(
            value: value ?? "—",
            detail: nonEmpty(detail) ?? "No detail reported.",
            status: runtimeStatus ?? "unknown",
            readState: .available
        )
    }

    static func action(
        requiresApproval: Bool?,
        dryRunAvailable: Bool?,
        fullMacYoloAdmitted: Bool = false
    ) -> Action {
        if requiresApproval != false, !fullMacYoloAdmitted {
            return Action(
                canDryRun: dryRunAvailable != false,
                canRun: false,
                blockedDetail: "Approval is required before this action can run."
            )
        }
        if dryRunAvailable == false {
            return Action(
                canDryRun: false,
                canRun: true,
                blockedDetail: "Dry run is unavailable for this action."
            )
        }
        return Action(canDryRun: true, canRun: true, blockedDetail: nil)
    }

    static func readState(
        itemCount: Int,
        hasRefreshAttempt: Bool,
        readFailed: Bool
    ) -> ReadState {
        if readFailed { return itemCount > 0 ? .stale : .unavailable }
        if itemCount > 0 { return .available }
        return hasRefreshAttempt ? .available : .loading
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CapabilityCatalogInstallOutcome: Equatable {
    case installed(name: String)
    case refused(message: String)

    var message: String {
        switch self {
        case .installed(let name): "Installed signed pack \(name)."
        case .refused(let message): "Pack install refused: \(message)"
        }
    }

    var systemImage: String {
        switch self {
        case .installed: "checkmark.seal.fill"
        case .refused: "exclamationmark.triangle.fill"
        }
    }

    var status: String {
        switch self {
        case .installed: "ok"
        case .refused: "warn"
        }
    }
}

struct CapabilityCatalogInstallOutcomeRow: View {
    let outcome: CapabilityCatalogInstallOutcome

    var body: some View {
        Text(outcome.message)
            .font(ShellType.label)
            .foregroundStyle(AdvancedStatusWords.color(outcome.status))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("capabilities.catalog.install-outcome")
    }
}

struct CapabilitiesView: View {
    @Environment(AppModel.self) private var appModel
    /// Which of the page's tabs this is (CapabilitiesRailPage).
    private let mode: CapabilityWorkspaceMode
    private var routeText: String { appModel.editDraft("capability-route/new", seed: "Research a topic, save it as a reusable tool if it comes up again, and ask me before anything risky.") }
    private var researchObjective: String { appModel.editDraft("capability-research/new", seed: "Find current best practices for lightweight autonomous agent capability systems.") }
    @State private var researchLabMessage: CapabilitiesResearchLabPresentation.Message?
    @State private var isRunningResearchLab = false
    private var catalogSourceName: String { appModel.editDraft("capability-catalog/new/name", seed: "Local NativeAgent Catalog") }
    private var catalogSourceURL: String { appModel.editDraft("capability-catalog/new/url", seed: "") }
    @State private var catalogSourceOutcome: AppModel.CapabilityCatalogSourceSaveOutcome?
    @State private var showAllNativeActions = false
    @State private var capabilitySearch = ""
    // 2026-07-22 page-tighten: the two heaviest always-expanded blocks
    // (Next-Gen Runtime migration cockpit in Overview) collapse by default;
    // open-state persists across visits like the Trust Advanced group.
    @AppStorage(CapabilitiesDisclosurePreference.nextGenKey) private var showNextGen = false
    // Everything a stranger has no business reading — hardening, the research
    // lab, the demo pack and the gauntlet — behind one fold at the bottom.
    @AppStorage(CapabilitiesDisclosurePreference.developerKey) private var showDeveloperTools = false

    init(initialMode: CapabilityWorkspaceMode = .canDo) {
        mode = initialMode
    }

    var body: some View {
        pageBody
    }

    private var pageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                summaryGrid

                switch mode {
                case .canDo:
                    overview
                case .installed:
                    build
                }

                developerTools

                CapabilitiesStatusTextLine(state: CapabilitiesStatusLinePresentation.resolve(
                    refresh: appModel.panelRefreshStatus[.capabilities]))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
        // The tab row's right end, as on every tabbed page.
        .pageActions {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task {
                    await appModel.refreshForSidebarItem(.capabilities)
                    await appModel.engine.desk.refreshResearchRuns()
                }
            }
        }
        .alivePageLine(headerLine, id: "capabilities.line")
        .navigationTitle("Capabilities")
        .quietReadTask {
            await appModel.refreshForSidebarItem(.capabilities)
            await appModel.engine.desk.refreshResearchRuns()
        }
    }

    /// The header's one sentence (alive glass, 2026-09-23), in my own voice.
    /// Nil until the scoped refresh has run; a failed count says so rather
    /// than claim zero.
    private var headerLine: String? {
        guard appModel.engine.trust.catalogRefresh != nil else { return nil }
        let failed = appModel.engine.trust.catalogRefresh?.failedEndpoints.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "capability summary"
        } ?? false
        guard !failed, let counts = appModel.engine.trust.capabilitySummary?.summary else {
            return "I couldn't read all my capabilities just now."
        }
        // Total and ready come from the same summary the list's count reads,
        // so the two never disagree.
        let total = counts.total
        let workflows = appModel.engine.desk.workflows.count
        let ready = counts.active == total ? "all ready to use" : "\(counts.active) ready to use"
        let have = "I have \(total) \(total == 1 ? "capability" : "capabilities")"
            + (total > 0 ? ", \(ready)" : "")
        guard workflows > 0 else { return have + "." }
        return have + ", and \(workflows) saved \(workflows == 1 ? "workflow" : "workflows")."
    }

    private var summaryGrid: some View {
        let tiles = CapabilitiesRefreshPresentation.summary(trust: appModel.engine.trust, approvals: appModel.engine.approvals, nextGen: appModel.engine.nextGen)
        // Alive glass (2026-09-23): the five tiles fold into one quiet line of
        // counts; a dash still means "not read", never zero.
        return VStack(alignment: .leading, spacing: 8) {
            AliveFlow(spacing: 18, lineSpacing: 6) {
                // Capabilities and workflows are in the header line already.
                ForEach([
                    (tiles.nextGen, "self-checks ready", "self-checks ready"),
                    (tiles.approvals, "approval", "approvals"),
                ].filter { $0.0 != "0/0" }, id: \.2) { value, one, many in
                    Text("\(value) \(value == "1" ? one : many)")
                        .font(ShellType.label)
                        .monospacedDigit()
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("capabilities.counts")
            if let notice = tiles.notice {
                Text(notice)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // 2026-07-22 page-tighten: the two heaviest blocks fold away by default.
    // 2026-07-23 audit F5-L1: a fold hides its inner attention state (e.g. an
    // phase not yet ready). When the underlying state carries an attention
    // signal, the fold row says so, so the signal survives the collapse. Nil =
    // nothing to say (identical to before).
    // 2026-09-03 kit pass: the plate and the tinted badge are gone. A fold is a
    // chevron, the words and one gesture (AdvancedFold); the attention signal is
    // now a word in the room's trouble colour on the same row.
    private func collapsedCard<Content: View>(
        title: String,
        subtitle: String,
        isExpanded: Binding<Bool>,
        attentionBadge: String? = nil,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        AdvancedFold(
            title: title,
            subtitle: subtitle,
            attention: attentionBadge,
            isExpanded: isExpanded
        ) {
            content()
        }
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            // L3#7 (2026-08-11): the "Capability Foundry" panel is deleted.
            // E-1 already stripped its fake counters; what was left was a
            // status badge and 2-3 lane tiles over a subsystem that was never
            // ported (no auto-implementation ledger, no review pipeline):
            // the panel claimed a workshop that does not exist.

            AdvancedSection(title: "Capabilities I can use") {
                switch CapabilitiesFoundryIndexPresentation.state(summary: appModel.engine.trust.capabilitySummary) {
                case .populated(let summary):
                    // Fold, don't badge: a word only when it asks something.
                    // The ready count is the header's sentence already.
                    if summary.summary.review > 0 || summary.summary.autoloaded > 0 {
                        HStack(spacing: 12) {
                            if summary.summary.review > 0 {
                                AdvancedStatusWord(status: "pending", text: "\(summary.summary.review) to review")
                            }
                            if summary.summary.autoloaded > 0 {
                                AdvancedStatusWord(status: "warn", text: "\(summary.summary.autoloaded) loaded automatically")
                            }
                            Spacer()
                        }
                    }

                    let listed = CapabilityRecord.displayRecords(summary.records)
                    let query = capabilitySearch.trimmingCharacters(in: .whitespacesAndNewlines)
                    let matches = query.isEmpty ? [] : listed.filter { capability in
                        CapabilityRecord.title(for: capability).localizedCaseInsensitiveContains(query)
                            || (CapabilityRecord.description(for: capability)?
                                .localizedCaseInsensitiveContains(query) ?? false)
                    }
                    HStack(spacing: 8) {
                        TextField("Search capability names or descriptions", text: $capabilitySearch)
                            .textFieldStyle(.roundedBorder)
                            .font(ShellType.label)
                            .frame(maxWidth: 420)
                            .accessibilityLabel("Search the capabilities")
                        if !query.isEmpty {
                            Button("Clear search") { capabilitySearch = "" }
                                .buttonStyle(.borderless)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .help("Clear the search")
                                .accessibilityLabel("Clear the search")
                            Text("\(matches.count) matching \(matches.count == 1 ? "capability" : "capabilities")")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    // One row per capability, hairlines between. A search
                    // covers every record; browsing keeps the first fourteen.
                    if !query.isEmpty && matches.isEmpty {
                        Text("No capabilities match this search.")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                    ForEach(query.isEmpty ? Array(listed.prefix(14)) : matches) { capability in
                        CapabilityRow(capability: capability)
                    }
                case .empty:
                    AdvancedEmptyState(
                        title: "Nothing listed yet",
                        detail: CapabilitiesFoundryIndexPresentation.emptyDetail
                    )
                case .unavailable:
                    AdvancedEmptyState(
                        title: "The capability list is unavailable",
                        detail: CapabilitiesFoundryIndexPresentation.unavailableDetail
                    )
                case .inconsistent(let reason):
                    AdvancedEmptyState(
                        title: "The capability list needs a refresh",
                        detail: CapabilitiesFoundryIndexPresentation.inconsistentDetail(reason)
                    )
                }
            }

            AdvancedSection(title: "Your spaces") {
                if let profile = appModel.engine.persona.profile {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                        AdvancedStat(title: profile.name, value: "1", detail: "persona")
                    }
                } else {
                    Text("Your spaces have not loaded yet.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }
        }
    }

    private var nextGenLoadedPhases: [NextGenPhase] { appModel.engine.nextGen.current?.phases ?? [] }
    private var nextGenReadyCount: Int { appModel.engine.nextGen.current?.summary.readyPhaseCount ?? 0 }
    private var nextGenTotalCount: Int { appModel.engine.nextGen.current?.summary.totalPhaseCount ?? 0 }
    private var nextGenReviewCount: Int { max(0, nextGenTotalCount - nextGenReadyCount) }
    private var nextGenReceipts: [NextGenReceipt] { appModel.engine.nextGen.current?.receipts ?? [] }
    private var nextGenActions: [NextGenAction] { appModel.engine.nextGen.current?.eligibleActions ?? [] }

    private var nextGenRuntime: some View {
        AliveGroupCard {
            if let error = appModel.engine.nextGen.readError {
                Text(error).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble)
            }
            if appModel.engine.nextGen.current == nil {
                Text("These checks have not loaded yet.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            } else {
                HStack(spacing: 12) {
                    AdvancedStatusWord(status: appModel.engine.nextGen.current?.summary.readinessStatus ?? "ready")
                    if let current = appModel.engine.nextGen.current?.summary.currentPhaseName ?? appModel.engine.nextGen.current?.summary.currentPhaseId {
                        AdvancedMeta(current.withoutStaleNextGenPhaseCopy)
                    }
                    AdvancedMeta("\(nextGenLoadedPhases.count) checks")
                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                    AdvancedStat(
                        title: "Checks ready",
                        value: "\(nextGenReadyCount)/\(nextGenTotalCount)",
                        detail: appModel.engine.nextGen.current?.summary.readiness ?? "ready checks",
                        status: appModel.engine.nextGen.current?.summary.readinessStatus ?? "ready"
                    )
                    AdvancedStat(
                        title: "Receipts",
                        value: "\(appModel.engine.nextGen.current?.summary.receiptCount ?? nextGenReceipts.count)",
                        detail: nextGenReceipts.first?.displayStatus ?? "none yet",
                        status: nextGenReceipts.first?.displayStatus
                    )
                    AdvancedStat(
                        title: "Action previews",
                        value: "\(appModel.engine.nextGen.current?.summary.actionCount ?? nextGenActions.count)",
                        detail: appModel.isRunningNextGenAction ? "running" : "available",
                        status: appModel.isRunningNextGenAction ? "running" : "ready"
                    )
                }

                ForEach(nextGenLoadedPhases) { phase in
                    NextGenPhaseRow(phase: phase, eligibleActions: nextGenActions, isRunning: appModel.isRunningNextGenAction) { actionId in
                        Task { await appModel.runNextGenAction(id: actionId, dryRun: true) }
                    }
                }

                if !nextGenActions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(nextGenActions.prefix(4)) { action in
                            Button(action.displayName) {
                                Task { await appModel.runNextGenAction(action, dryRun: true) }
                            }
                            .disabled(appModel.isRunningNextGenAction || action.dryRunAvailable == false)
                        }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                }

                ForEach(nextGenReceipts.prefix(6)) { receipt in
                    // 2026-06-07 ui-taste-sweep #83: humanized title +
                    // subtitle replaces the raw kv-dump. rawPairs adds
                    // a "Show details" disclosure for the full payload.
                    let h = receipt.humanized
                    CapabilityDetailRow(
                        title: h.title,
                        detail: h.subtitle,
                        status: receipt.displayStatus,
                        rawPairs: h.rawPairs.isEmpty ? nil : h.rawPairs
                    )
                }
            }
        }
        .accessibilityIdentifier("capabilities.show-next-gen.content")
    }

    private var build: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            // W3 (eval5): surface the "feature disabled / not implemented"
            // envelope for Build-tab actions (capability pack install)
            // so users see why nothing happened
            // instead of a fake success toast.
            if let disabled = appModel.disabledFeature, !disabled.isEmpty {
                Text(disabled)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WorkflowBuilderPanel()

            AdvancedSection(title: "Capability list") {
                HStack(spacing: 8) {
                    // The demo pack install moved to the "Developer" fold
                    // at the bottom of the page; nothing else about the catalog
                    // changed.
                    Button("Check for updates") {
                        Task { await appModel.checkCapabilityUpdates() }
                    }
                    .controlSize(.small)
                    if let capability = appModel.engine.trust.capabilitySummary?.records.first {
                        Button("Check trust") {
                            Task { await appModel.evaluateCapabilityTrust(capability) }
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                    AdvancedMeta("\(appModel.engine.trust.capabilityPackInstalls.count) installed")
                }

                if let outcome = appModel.capabilityCatalogInstallOutcome {
                    CapabilityCatalogInstallOutcomeRow(outcome: outcome)
                }

                HStack(spacing: 8) {
                    TextField("Source name", text: appModel.editBinding("capability-catalog/new/name", seed: "Local NativeAgent Catalog"))
                        .textFieldStyle(.roundedBorder)
                        .font(ShellType.label)
                        .accessibilityIdentifier("capabilities.catalogSource.name")
                    TextField("Source URL or path", text: appModel.editBinding("capability-catalog/new/url", seed: ""))
                        .textFieldStyle(.roundedBorder)
                        .font(ShellType.label)
                        .accessibilityIdentifier("capabilities.catalogSource.url")
                    Button(appModel.capabilityCatalogSourceSaveInFlight ? "Saving source…" : "Add source") {
                        addCatalogSource()
                    }
                    .controlSize(.small)
                    .disabled(appModel.capabilityCatalogSourceSaveInFlight)
                    .accessibilityIdentifier("capabilities.catalogSource.add")
                }

                if let catalogSourceOutcome {
                    Text(catalogSourceOutcome.detail)
                        .font(ShellType.label)
                        .foregroundStyle(AdvancedStatusWords.color(catalogSourceOutcome.status))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capabilities.catalogSource.outcome")
                }

                if !appModel.engine.trust.capabilityCatalogSources.isEmpty || appModel.engine.trust.capabilityNetwork != nil || appModel.latestCapabilityUpdateCheck != nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                        AdvancedStat(title: "Sources", value: "\(appModel.engine.trust.capabilityCatalogSources.count)", detail: appModel.engine.trust.capabilityCatalogSources.first?.status ?? "not checked")
                        AdvancedStat(title: "Trusted", value: "\(appModel.engine.trust.capabilityNetwork?.summary?.trusted ?? 0)", detail: "\(appModel.engine.trust.capabilityNetwork?.summary?.review ?? 0) to review")
                        AdvancedStat(title: "Updates", value: "\(appModel.latestCapabilityUpdateCheck?.updates.count ?? 0)", detail: appModel.latestCapabilityUpdateCheck?.status ?? "not checked")
                    }
                }

                if let trust = appModel.latestCapabilityTrustEvaluation {
                    CapabilityDetailRow(title: trust.name ?? trust.id, detail: trust.reasons.prefix(2).joined(separator: " "), status: trust.trustTier)
                }

                if appModel.engine.trust.capabilityCatalog.isEmpty {
                    AdvancedEmptyState(
                        title: "No items yet",
                        detail: "Adding a source, or installing a signed pack, fills this list."
                    )
                } else {
                    ForEach(appModel.engine.trust.capabilityCatalog) { item in
                        CatalogRow(item: item)
                    }
                }

                if !appModel.engine.trust.capabilityPackInstalls.isEmpty {
                    ForEach(appModel.engine.trust.capabilityPackInstalls.prefix(4)) { install in
                            HStack(alignment: .top, spacing: 8) {
                                CapabilityDetailRow(
                                    title: install.name ?? install.packId,
                                    detail: "\(install.version ?? "unknown") · \(install.signature?.prefix(12) ?? "unsigned")",
                                    status: install.status
                                )
                                Spacer()
                                Button("Roll back") {
                                    Task { await appModel.rollbackCapabilityPack(install) }
                                }
                                .controlSize(.small)
                                .disabled(install.status == "rolled_back")
                            }
                    }
                }
            }
        }
    }

    private func addCatalogSource() {
        catalogSourceOutcome = nil
        let name = catalogSourceName
        let url = catalogSourceURL
        Task {
            let outcome = await appModel.addCatalogSource(name: name, url: url)
            catalogSourceOutcome = outcome
            if outcome.didSave, catalogSourceName == name, catalogSourceURL == url {
                appModel.clearEditDraft("capability-catalog/new/name")
                appModel.clearEditDraft("capability-catalog/new/url")
            }
        }
    }

    /// Everything behind "Developer": the self-checks, the planner and its
    /// activity log, the skill graph, the old Hardening tab whole, the
    /// research lab, and the demo pack. Nothing here was deleted — it is one
    /// door down instead of mixed in with what a person came here to read.
    private var developerTools: some View {
        AdvancedFold(
            title: "Developer",
            subtitle: "Checks, logs and tools for people working on the app.",
            // Folded, the self-checks' review count still says itself.
            attention: nextGenReviewCount > 0 ? "\(nextGenReviewCount) to review" : nil,
            isExpanded: $showDeveloperTools
        ) {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                collapsedCard(
                    title: "Checks I run on myself",
                    subtitle: "What I have checked after an update, action previews, and records of what changed.",
                    isExpanded: $showNextGen,
                    attentionBadge: nextGenReviewCount > 0 ? "\(nextGenReviewCount) to review" : nil,
                    accessibilityIdentifier: "capabilities.show-next-gen"
                ) {
                    nextGenRuntime
                }

                AdvancedSection(title: "Plan a task") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Describe a task", text: appModel.editBinding("capability-route/new", seed: "Research a topic, save it as a reusable tool if it comes up again, and ask me before anything risky."), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(ShellType.label)
                            .lineLimit(2...4)
                        Button("Make a plan") {
                            let submitted = routeText
                            Task {
                                await appModel.routeIntent(submitted)
                                if case .plan = appModel.routePresentation, routeText == submitted { appModel.clearEditDraft("capability-route/new") }
                            }
                        }
                        .disabled(appModel.routePresentation.isPlanning)
                    }

                    switch appModel.routePresentation {
                    case .idle:
                        EmptyView()
                    case .planning:
                        AdvancedWaitingLine("Working out a plan…")
                    case let .failed(message):
                        Text("No plan came back: \(message)")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.trouble)
                            .fixedSize(horizontal: false, vertical: true)
                    case let .plan(plan):
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                AdvancedStatusWord(status: plan.risk, text: plan.goalType)
                                AdvancedStatusWord(status: plan.risk)
                                if plan.requiresApproval {
                                    AdvancedStatusWord(status: "pending", text: "Waiting on you")
                                }
                                Spacer()
                            }
                            ForEach(plan.nextActions, id: \.self) { action in
                                Text(action)
                                    .font(ShellType.label)
                                    .foregroundStyle(NativeAgentShell.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            AdvancedEyebrow(text: "Matched capabilities")
                            switch IntentRoutePresentation.plan(plan).capabilityMatchState {
                            case let .matches(capabilities):
                                ForEach(capabilities.prefix(5)) { capability in
                                    CapabilityRow(capability: capability, compact: true)
                                }
                            case .noMatches:
                                Text("Nothing installed matches this task.")
                                    .font(ShellType.label)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            case nil:
                                EmptyView()
                            }
                        }
                    }
                }

                AdvancedSection(title: "Recent activity") {
                    let traceState = appModel.engine.turns.capabilityTraceTimeline
                    if case .sourceAbsent = traceState {
                        AdvancedEmptyState(
                            title: "No activity yet",
                            detail: "The activity log has not been created yet."
                        )
                    } else if case .empty = traceState {
                        AdvancedEmptyState(
                            title: "Nothing has happened yet",
                            detail: "Planning a task, saving a workflow, or installing an item writes the first entry."
                        )
                    } else if case .unavailable(let detail) = traceState {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recent activity is unavailable")
                                .font(ShellType.bodySemibold)
                                .foregroundStyle(NativeAgentShell.trouble)
                            Text(detail)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        if case .partial(_, let rejectedRows) = traceState {
                            Text("\(rejectedRows) unreadable \(rejectedRows == 1 ? "entry was" : "entries were") left out of this list.")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.trouble)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(traceState.traces.prefix(14)) { trace in
                            CapabilityDetailRow(title: trace.title, detail: trace.kind, status: trace.status ?? "ok")
                        }
                    }
                }

                SkillMemoryGraphPanel()

                researchLab
                demoPack
                hardening
            }
        }
        .accessibilityIdentifier("capabilities.for-developers")
    }

    private var demoPack: some View {
        AdvancedSection(title: "Demo pack") {
            HStack(spacing: 8) {
                Button("Install the signed demo pack") {
                    Task { await appModel.installDemoCapabilityPack() }
                }
                .controlSize(.small)
                .disabled(appModel.isInstallingDemoCapabilityPack)
                .accessibilityIdentifier("capabilities.catalog.install-signed-demo")
                .accessibilityHint("Verifies the demo pack signature before any capability files are written. Evaluate trust is informational and is not required to install.")
                Spacer()
            }
        }
    }

    private var researchLab: some View {
        AdvancedSection(title: "Research lab") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Research objective", text: appModel.editBinding("capability-research/new", seed: "Find current best practices for lightweight autonomous agent capability systems."), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(ShellType.label)
                    .lineLimit(2...4)
                Button("Run the research lab") {
                    let submitted = researchObjective
                    Task { await runResearchLab(objective: submitted) }
                }
                .disabled(isRunningResearchLab)
            }

            if let researchLabMessage {
                researchLabMessageRow(researchLabMessage)
            }

            if !appModel.engine.desk.researchRunsLoaded {
                AdvancedWaitingLine("Reading the research lab's receipts…")
            } else if let detail = appModel.engine.desk.researchRunsError {
                Text("Research lab receipts are unavailable: \(detail)")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !appModel.engine.desk.researchRuns.isEmpty {
                    AdvancedEyebrow(text: "Last known receipts")
                    researchLabRunRows(appModel.engine.desk.researchRuns)
                }
            } else if appModel.engine.desk.researchRuns.isEmpty {
                AdvancedEmptyState(
                    title: "No research runs",
                    detail: "A run started here leaves its receipt in this list."
                )
            } else {
                researchLabRunRows(appModel.engine.desk.researchRuns)
            }
        }
    }

    @MainActor
    private func runResearchLab(objective: String) async {
        isRunningResearchLab = true
        defer { isRunningResearchLab = false }
        let outcome = await appModel.runResearchLab(objective: objective)
        researchLabMessage = CapabilitiesResearchLabPresentation.message(for: outcome)
        if case .recorded = outcome {
            if researchObjective == objective { appModel.clearEditDraft("capability-research/new") }
            await appModel.engine.desk.refreshResearchRuns()
        }
    }

    private func researchLabMessageRow(_ message: CapabilitiesResearchLabPresentation.Message) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.text)
                .font(ShellType.labelSemibold)
                .foregroundStyle(researchLabColor(message.tone))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = message.detail {
                Text(detail)
                    .font(ShellType.caption)
                    .foregroundStyle(researchLabColor(message.tone))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func researchLabRunRows(_ runs: [ResearchLabRun]) -> some View {
        ForEach(runs.prefix(4)) { run in
            let message = CapabilitiesResearchLabPresentation.message(for: run)
            CapabilityDetailRow(
                title: run.objective,
                detail: message.detail ?? message.text,
                status: run.status
            )
        }
    }

    private func researchLabColor(_ tone: CapabilitiesResearchLabPresentation.Tone) -> Color {
        switch tone {
        case .neutral, .progress:
            NativeAgentShell.secondary
        case .success:
            NativeAgentShell.calm
        case .warning, .failure:
            NativeAgentShell.trouble
        }
    }

    private var hardening: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            AdvancedSection(title: "Autonomy guardrails") {
                if let kernel = appModel.engine.trust.autonomyKernel {
                    HStack(spacing: 12) {
                        AdvancedStatusWord(status: kernel.status)
                        if let mode = kernel.mode {
                            AdvancedMeta(AdvancedStatusWords.label(mode))
                        }
                        Spacer()
                    }
                    ForEach(kernel.guardrails) { guardrail in
                        CapabilityDetailRow(title: guardrail.title, detail: guardrail.id, status: guardrail.status)
                    }
                } else {
                    Text("The autonomy guardrails have not loaded yet.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }

            nativeMacPower
            CapabilityProductionHardeningPanel()
        }
    }

    private var nativeMacPower: some View {
            AdvancedSection(title: "Mac actions") {
                // 2026-07-21 audit fix (dead-surface honesty): the
                // `nativePower.surfaces` list and the "App Intents" tile were
                // removed — getNativePower() is a DAEMON-KILL P1 stub that
                // returns surfaces: [] forever, and /v1/native/intents was
                // retired with no SwiftNative successor (the dead intent-registry
                // chain was fully deleted 2026-08-14), so both rendered permanent
                // empty/"Loading" furniture. The remaining tiles and action
                // rows below are fed by live readers.
                let failedEndpoints = Set(((appModel.engine.tools.nativePowerRefresh?.failedEndpoints ?? [])
                    + (appModel.engine.memory.statusRefresh?.failedEndpoints ?? [])).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })
                let notificationTile = NativeMacPowerPanelPresentation.tile(
                    value: appModel.engine.tools.notificationStatus?.pendingApprovals.map(String.init),
                    detail: "pending approvals",
                    runtimeStatus: appModel.engine.tools.notificationStatus?.status,
                    hasRefreshAttempt: appModel.engine.tools.nativePowerRefresh != nil,
                    readFailed: failedEndpoints.contains("notification status")
                )
                let browserTile = NativeMacPowerPanelPresentation.tile(
                    value: appModel.engine.tools.browserStatus?.receiptCount.map(String.init),
                    detail: appModel.engine.tools.browserStatus?.domainPolicy,
                    runtimeStatus: appModel.engine.tools.browserStatus?.status,
                    hasRefreshAttempt: appModel.engine.tools.nativePowerRefresh != nil,
                    readFailed: failedEndpoints.contains("browser status")
                )
                let nativeActionsState = NativeMacPowerPanelPresentation.readState(
                    itemCount: appModel.engine.tools.nativeActions.count,
                    hasRefreshAttempt: true,
                    readFailed: false
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                    AdvancedStat(
                        title: "Notifications",
                        value: notificationTile.value,
                        detail: notificationTile.detail,
                        status: notificationTile.status
                    )
                    AdvancedStat(
                        title: "Browser",
                        value: browserTile.value,
                        detail: browserTile.detail,
                        status: browserTile.status
                    )
                }

                if nativeActionsState == .unavailable {
                    Text("The list of Mac actions could not be read. Refresh Capabilities before relying on what is listed here.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                } else if nativeActionsState == .loading {
                    Text("Mac actions have not loaded yet.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                } else if appModel.engine.tools.nativeActions.isEmpty {
                    Text("No Mac actions are available.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                } else {
                    if nativeActionsState == .stale {
                        Text("Showing the last list of Mac actions that loaded.")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.trouble)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let fullMacYoloAdmitted = appModel.engine.trust.nativeActionYoloAdmitted
                    ForEach(appModel.engine.tools.nativeActions.prefix(showAllNativeActions ? appModel.engine.tools.nativeActions.count : 6)) { action in
                            let actionPresentation = NativeMacPowerPanelPresentation.action(
                                requiresApproval: action.requiresApproval,
                                dryRunAvailable: action.dryRunAvailable,
                                fullMacYoloAdmitted: fullMacYoloAdmitted
                            )
                            VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                CapabilityDetailRow(
                                    title: action.name,
                                    detail: AdvancedStatusWords.label(action.kind ?? action.id),
                                    status: action.risk ?? "ok"
                                )
                                Spacer()
                                Button("Dry run") {
                                    Task { await appModel.runNativeAction(action, dryRun: true) }
                                }
                                .controlSize(.small)
                                .disabled(!actionPresentation.canDryRun)
                                Button("Run") {
                                    Task { await appModel.runNativeAction(action, dryRun: false) }
                                }
                                .controlSize(.small)
                                .disabled(!actionPresentation.canRun)
                            }
                            if let blockedDetail = actionPresentation.blockedDetail {
                                Text(blockedDetail)
                                    .font(ShellType.caption)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            }
                    }
                }

                if appModel.engine.tools.nativeActions.count > 6 && nativeActionsState != .unavailable {
                    HStack {
                        Button(showAllNativeActions ? "Show fewer actions" : "Show all actions") {
                            showAllNativeActions.toggle()
                        }
                        .accessibilityIdentifier("capabilities.show-all-native-actions")
                        Text("Showing \(showAllNativeActions ? appModel.engine.tools.nativeActions.count : 6) of \(appModel.engine.tools.nativeActions.count) loaded actions")
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                }

                // B2.3 residue restoration (gpt-5.5 review BLOCKING): the
                // retired Command Center's "Recent Receipts" rollup listed the
                // last FOUR native-action receipts; this row showed only the
                // latest, which silently narrowed visibility when the roll-up
                // died. Canonical home is here, next to the actions themselves.
                ForEach(appModel.engine.tools.nativeActionReceipts.prefix(4)) { receipt in
                    CapabilityDetailRow(
                        title: AdvancedStatusWords.label(receipt.name ?? receipt.actionId),
                        detail: receipt.createdAt ?? AdvancedStatusWords.label(receipt.actionId),
                        status: receipt.status
                    )
                }

                if let connectorRegistry = appModel.engine.connectors.actions {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            AdvancedEyebrow(text: "\(connectorRegistry.actions.count) connector actions")
                            Spacer()
                            if let latest = connectorRegistry.latestReceipt {
                                AdvancedStatusWord(status: latest.status)
                            }
                        }
                        ForEach(connectorRegistry.actions.prefix(4)) { action in
                            HStack(spacing: 8) {
                                CapabilityDetailRow(
                                    title: action.name,
                                    detail: "\(AdvancedStatusWords.label(action.connectorId ?? "connector")) · \(AdvancedStatusWords.label(action.authState ?? "unknown"))",
                                    status: action.connectorStatus ?? (action.enabled == true ? "ok" : "warn")
                                )
                                Spacer()
                                Button("Dry run") {
                                    Task { await appModel.runConnectorAction(action) }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                CapabilitiesRunGauntletAndBrowserActions()
            }

    }


}

struct CapabilitiesRunGauntletAndBrowserActions: View {
    @Environment(AppModel.self) private var appModel
    @State private var isRunningBrowserDryRun = false
    @State private var isRunningGauntlet = false

    private var latestGauntlet: Result<ImprovementGauntletRun?, Error> {
        Result {
            try appModel.engine.doctor.improvementGauntletStatus?.latestDisplayRun
        }
    }

    var body: some View {
        let gauntletRead = latestGauntlet
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("Browser dry run") {
                    Task {
                        isRunningBrowserDryRun = true
                        defer { isRunningBrowserDryRun = false }
                        await appModel.runBrowserDryRun()
                    }
                }
                .controlSize(.small)
                .disabled(isRunningBrowserDryRun)
                .accessibilityIdentifier("capabilities.browser-dry-run")

                Button("Cancel the browser run") {
                    Task { await appModel.cancelBrowserRun() }
                }
                .controlSize(.small)
                .accessibilityIdentifier("capabilities.browser-cancel")

                Button("Run the improvement checks") {
                    Task {
                        isRunningGauntlet = true
                        defer { isRunningGauntlet = false }
                        await appModel.runImprovementGauntlet()
                    }
                }
                .controlSize(.small)
                .disabled(isRunningGauntlet)
                .accessibilityIdentifier("capabilities.run-gauntlet")

                Spacer()
                if case .success(let latestGauntlet?) = gauntletRead {
                    AdvancedStatusWord(status: latestGauntlet.status)
                }
            }

            if let run = appModel.engine.tools.browserStatus?.latestReceipt {
                let presentation = CapabilitiesRunActionPresentation.browserOutcome(for: run)
                CapabilityDetailRow(
                    title: presentation.title,
                    detail: presentation.detail,
                    status: presentation.status
                )
                .accessibilityIdentifier("capabilities.browser-dry-run.outcome")
            }

            if case .failure(let error) = gauntletRead {
                Text(error.localizedDescription)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .success(let gauntlet?) = gauntletRead {
                let presentation = CapabilitiesRunActionPresentation.gauntletOutcome(for: gauntlet)
                CapabilityDetailRow(
                    title: presentation.title,
                    detail: presentation.detail,
                    status: presentation.status
                )
                .accessibilityIdentifier("capabilities.run-gauntlet.outcome")

                if !presentation.failedCheckTitles.isEmpty {
                    Text("Checks not passed: \(presentation.failedCheckTitles.joined(separator: ", "))")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capabilities.run-gauntlet.failures")
                }
            }

            if appModel.statusText.hasPrefix("Browser dry run:")
                || appModel.statusText.hasPrefix("Browser run failed:")
                || appModel.statusText.hasPrefix("Gauntlet:")
                || appModel.statusText.hasPrefix("Gauntlet failed:") {
                Text(appModel.statusText)
                    .font(ShellType.caption)
                    .foregroundStyle(appModel.statusText.contains("failed:") ? NativeAgentShell.trouble : NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capabilities.run-actions.status")
            }
        }
    }
}

/// The concrete outcome language shared by the capabilities actions and their
/// direct behavioral coverage. The action owners supply receipts; this model
/// makes their visible summary a pure, independently auditable projection.
struct CapabilitiesRunActionPresentation: Equatable {
    struct Outcome: Equatable {
        let title: String
        let detail: String
        let status: String
        let failedCheckTitles: [String]
    }

    static func browserOutcome(for run: BrowserRun) -> Outcome {
        Outcome(
            title: "Latest browser run",
            detail: "\(run.dryRun == true ? "Dry run" : "Not a dry run") · \(run.url ?? "no URL recorded")",
            status: run.status,
            failedCheckTitles: []
        )
    }

    static func gauntletOutcome(for run: ImprovementGauntletRun) -> Outcome {
        let checks = run.checks ?? []
        let passed = checks.filter(\.passed).count
        return Outcome(
            title: "Latest improvement run",
            detail: checks.isEmpty ? "No checks recorded" : "\(passed)/\(checks.count) checks passed",
            status: run.status,
            failedCheckTitles: checks.filter { !$0.passed }.map(\.title)
        )
    }
}

struct CapabilityRow: View {
    var capability: CapabilityRecord
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CapabilityRecord.title(for: capability))
                    .font(compact ? ShellType.labelSemibold : ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer()
                // Working is the norm; only an exception gets a word.
                if let status = capability.status, !["active", "ok", "ready"].contains(status.lowercased()) {
                    AdvancedStatusWord(status: status, text: status)
                }
            }
            HStack(spacing: 8) {
                // "Tool" is the common case; only another kind earns a word.
                if capability.kind?.lowercased() != "tool" {
                    AdvancedMeta(AdvancedStatusWords.label(capability.kind ?? ""))
                }
                // Low is the norm; only a higher risk earns a word.
                if let risk = capability.riskClass, !risk.isEmpty, risk.lowercased() != "low" {
                    if risk.lowercased() == "external_send" {
                        // Sending to other people is real trouble, as on Trust.
                        Text(AdvancedStatusWords.label(risk))
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.trouble)
                            .lineLimit(1)
                    } else {
                        AdvancedMeta(AdvancedStatusWords.label(risk))
                    }
                }
                if let useCount = capability.useCount, useCount > 0 {
                    AdvancedMeta("\(useCount) uses")
                }
            }
            if !compact, let description = CapabilityRecord.description(for: capability), !description.isEmpty {
                Text(description)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct NextGenPhaseRow: View {
    var phase: NextGenPhase
    var eligibleActions: [NextGenAction]
    var isRunning: Bool
    var runProbe: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CapabilityDetailRow(
                title: phase.displayName,
                detail: phase.displayDetail,
                status: phase.displayStatus
            )
            Spacer()
            // L3#6: a phase's primaryDryRunActionId comes from the catalog data
            // file and may name an id the read-only executor has no case for.
            // Render the probe only when an executor backs it.
            if let actionId = phase.primaryDryRunActionId, eligibleActions.contains(where: { $0.id == actionId }) {
                Button("Preview") {
                    runProbe(actionId)
                }
                .controlSize(.small)
                .disabled(isRunning)
            } else {
                AdvancedStatusWord(status: nil, text: "No preview")
            }
        }
    }

}

struct SkillMemoryGraphPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var graphQuery = "memory workflow capability"
    private var memory: MemoryFacade { appModel.engine.memory }

    var body: some View {
        AdvancedSection(title: "Skill memory graph") {
            if let snapshot = memory.graphSnapshot {
                let graph = KnowledgeGraphReadProjection.agentGraph(from: snapshot, executionCount: nil)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    AdvancedStat(title: "Items", value: "\(graph.summary.nodes)", detail: "memories, runs, Desk tasks, capabilities")
                    AdvancedStat(title: "Links", value: "\(graph.summary.edges)", detail: "what produced and used what")
                    AdvancedStat(title: "Capabilities", value: "\(graph.summary.capabilities ?? 0)", detail: "listed in the graph")
                }

                if let error = memory.graphLoadError {
                    Text("\(error) What is shown may be out of date.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    AdvancedStatusWord(status: KnowledgeGraphReadProjection.graphIndexStatus(from: snapshot).status)
                    AdvancedMeta("\(snapshot.entities.count) entities")
                    TextField("Search the graph", text: $graphQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(ShellType.label)
                    Button("Search") {
                        Task { await appModel.searchGraph(graphQuery) }
                    }
                    .controlSize(.small)
                    Button("Refresh") {
                        Task { await appModel.refreshGraph() }
                    }
                    .controlSize(.small)
                }

                if graph.nodes.isEmpty {
                    Text("The graph is empty. New memories and linked capability activity show up here once they are added.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !appModel.graphSearchResults.isEmpty {
                        ForEach(appModel.graphSearchResults.prefix(8)) { result in
                            CapabilityDetailRow(
                                title: result.node.label ?? AdvancedStatusWords.label(result.id),
                                detail: result.explanation ?? "Score \(String(format: "%.2f", result.score))",
                                status: result.node.status ?? "ok"
                            )
                        }
                }

                if !snapshot.entities.isEmpty {
                        ForEach(snapshot.entities.prefix(5)) { entity in
                            CapabilityDetailRow(
                                title: entity.name,
                                detail: "\(entity.mentions ?? 0) mentions · confidence \(String(format: "%.2f", entity.confidence ?? 0))",
                                status: entity.kind ?? "ok"
                            )
                        }
                }
            } else if let error = memory.graphLoadError {
                AdvancedEmptyState(
                    title: "Skill memory graph unavailable",
                    detail: error,
                    actionTitle: "Refresh the graph",
                    action: { Task { await appModel.refreshGraph() } }
                )
            } else {
                AdvancedEmptyState(
                    title: "Skill memory graph not loaded",
                    detail: "Refresh to read the current graph. This does not mean the graph is empty.",
                    actionTitle: "Refresh the graph",
                    action: { Task { await appModel.refreshGraph() } }
                )
            }
        }
    }
}

// The workflow RUN engine was retired 2026-09-01 (User authorized). Saved
// definitions do not execute, so this panel only lists what the registry holds
// — the live way to have work done is workshop/executions.
struct WorkflowBuilderPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AdvancedSection(title: "Saved workflows") {
            if appModel.engine.desk.workflows.isEmpty {
                AdvancedEmptyState(
                    title: "No workflows",
                    detail: "A workflow saved here shows up in this list. Refresh Capabilities to see the current set."
                )
            } else {
                ForEach(appModel.engine.desk.workflows) { workflow in
                    WorkflowRow(workflow: workflow)
                }
            }
        }
    }
}

struct WorkflowRow: View {
    var workflow: WorkflowRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(workflow.name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer()
                AdvancedStatusWord(status: workflow.status ?? "ok", text: workflow.status ?? "active")
            }
            if let description = workflow.description, !description.isEmpty {
                Text(description)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                AdvancedMeta("\(workflow.steps.count) steps")
                if let trigger = workflow.trigger, !trigger.isEmpty {
                    AdvancedMeta(AdvancedStatusWords.label(trigger))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct CatalogRow: View {
    var item: CapabilityCatalogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(item.name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer()
                AdvancedStatusWord(
                    status: item.installed == true ? "ok" : nil,
                    text: item.status ?? "available"
                )
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let kind = item.kind {
                    AdvancedMeta(AdvancedStatusWords.label(kind))
                }
                if let risk = item.riskClass {
                    AdvancedMeta(AdvancedStatusWords.label(risk))
                }
                Spacer()
                AdvancedMeta(item.installed == true ? "Installed by a verified pack" : "Listed, not installed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct CapabilityDetailRow: View {
    var title: String
    var detail: String
    var status: String
    /// 2026-09-03 kit pass: the row carries words, not a status-tinted glyph.
    /// The parameter stays because ToolsView (outside this pass) still passes
    /// one; nothing draws it.
    var systemImage: String = ""
    // 2026-06-07 ui-taste-sweep #83: when caller has the raw key/value
    // pairs (e.g. NextGenReceipt), pass them here. Row gets a fold labeled
    // "Details" that reveals each pair on its own line. Nil = legacy callers
    // (no fold rendered, identical to old behavior).
    var rawPairs: [(String, String)]? = nil

    @State private var showsPairs = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.withoutStaleNextGenPhaseCopy)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer()
                AdvancedStatusWord(status: status)
            }
            let trimmedDetail = detail.withoutStaleNextGenPhaseCopy
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDetail.isEmpty {
                Text(trimmedDetail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(3)
            }
            if let pairs = rawPairs, !pairs.isEmpty {
                Button {
                    withAnimation(
                        NativeAgentMotion.respecting(NativeAgentMotion.arrive, reduceMotion: reduceMotion)
                    ) {
                        showsPairs.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsPairs ? "chevron.down" : "chevron.right")
                        Text("Details")
                    }
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsPairs ? "Expanded" : "Collapsed")
                .padding(.top, 2)

                if showsPairs {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(pair.0)
                                    .font(AdvancedType.codeCaption)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                Text(pair.1.isEmpty ? "—" : pair.1)
                                    .font(AdvancedType.codeCaption)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .transition(NativeAgentMotion.arrivalFade)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
/// Presentation boundary for the native capability-records catalog. A catalog
/// summary is a receipt: its aggregate counts must agree with the actual rows
/// before Foundry Index can display it as a useful inventory.
enum CapabilitiesFoundryIndexPresentation {
    enum State: Equatable {
        case unavailable
        case empty
        case inconsistent(String)
        case populated(CapabilitySummaryResponse)
    }

    static func state(summary: CapabilitySummaryResponse?) -> State {
        guard let summary else { return .unavailable }
        guard !summary.records.isEmpty else {
            guard summary.summary.total == 0,
                  summary.summary.active == 0,
                  summary.summary.review == 0,
                  summary.summary.autoloaded == 0 else {
                return .inconsistent("the list has no entries but its counts are not zero")
            }
            return .empty
        }

        guard summary.records.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return .inconsistent("one or more entries have no stable id")
        }
        guard Set(summary.records.map(\.id)).count == summary.records.count else {
            return .inconsistent("the list contains duplicate ids")
        }

        let counts = summary.summary
        guard counts.total == summary.records.count else {
            return .inconsistent("the stated total does not match the entries")
        }
        guard counts.active >= 0, counts.review >= 0, counts.autoloaded >= 0,
              counts.active <= counts.total,
              counts.review <= counts.total,
              counts.autoloaded <= counts.total else {
            return .inconsistent("one or more stated counts are outside what the list holds")
        }

        let activeStatuses: Set<String> = ["active", "installed", "ready", "configured"]
        let reviewStatuses: Set<String> = ["review", "proposal", "draft", "drafted", "needs_setup"]
        let actualActive = summary.records.filter { activeStatuses.contains(($0.status ?? "").lowercased()) }.count
        let actualReview = summary.records.filter { reviewStatuses.contains(($0.status ?? "").lowercased()) }.count
        let actualAutoloaded = summary.records.filter { $0.autoload == true }.count
        guard counts.active == actualActive,
              counts.review == actualReview,
              counts.autoloaded == actualAutoloaded else {
            return .inconsistent("the stated status counts do not match the entries")
        }

        if let byKind = counts.byKind {
            var actualByKind: [String: Int] = [:]
            for record in summary.records {
                actualByKind[record.kind ?? "", default: 0] += 1
            }
            guard byKind == actualByKind else {
                return .inconsistent("the stated kind counts do not match the entries")
            }
        }

        return .populated(summary)
    }

    static var unavailableDetail: String {
        "The capability list has not loaded. Refresh to try again."
    }

    static var emptyDetail: String {
        "Nothing is listed yet."
    }

    static func inconsistentDetail(_ reason: String) -> String {
        "The capability list does not add up (\(reason)). Refresh before relying on it."
    }
}

/// Result of sending a Research Lab request through the native research owner.
/// A returned run can still describe an unavailable connector, so callers must
/// inspect the receipt rather than treating a non-throwing call as success.
enum ResearchLabActionOutcome: Equatable {
    case rejected(String)
    case recorded(ResearchLabRun)
    case failed(String)
}

enum CapabilitiesResearchLabPresentation {
    enum Tone: Equatable {
        case neutral
        case progress
        case success
        case warning
        case failure
    }

    struct Message: Equatable {
        let text: String
        let detail: String?
        let tone: Tone
        let systemImage: String
    }

    static func message(for outcome: ResearchLabActionOutcome) -> Message {
        switch outcome {
        case .rejected(let detail):
            Message(text: "Research objective required", detail: detail, tone: .warning,
                    systemImage: "exclamationmark.triangle.fill")
        case .failed(let detail):
            Message(text: "Research lab failed", detail: detail, tone: .failure,
                    systemImage: "exclamationmark.triangle.fill")
        case .recorded(let run):
            message(for: run)
        }
    }

    static func message(for run: ResearchLabRun) -> Message {
        let status = run.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let detail = meaningfulDetail(for: run)
        switch status {
        case "completed":
            if let error = nonempty(run.error) {
                return Message(text: "Research lab reported an error", detail: error, tone: .failure,
                               systemImage: "exclamationmark.triangle.fill")
            }
            return Message(
                text: "Research run completed",
                detail: "\(run.sources.count) source\(run.sources.count == 1 ? "" : "s") recorded.",
                tone: .success,
                systemImage: "checkmark.circle.fill"
            )
        case "needs_connector":
            return Message(
                text: "Research needs a connector",
                detail: detail ?? "Connect a research service before this can return sources.",
                tone: .warning,
                systemImage: "exclamationmark.triangle.fill"
            )
        case "failed", "error":
            return Message(
                text: "Research lab failed",
                detail: detail ?? "The research run came back failed, with no detail.",
                tone: .failure,
                systemImage: "exclamationmark.triangle.fill"
            )
        default:
            return Message(
                text: "Research result needs review",
                detail: detail ?? "The research run came back with a status this page does not recognise: \(run.status).",
                tone: .warning,
                systemImage: "questionmark.diamond"
            )
        }
    }

    private static func meaningfulDetail(for run: ResearchLabRun) -> String? {
        nonempty(run.error) ?? nonempty(run.brief)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : bounded(trimmed)
    }

    private static func bounded(_ text: String) -> String {
        let limit = 240
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

/// Mounted Intent Router state. A successful plan with no matching
/// capabilities is useful evidence; it must never look like the router did
/// not run or that it failed before producing a plan.
enum IntentRoutePresentation: Equatable {
    case idle
    case planning
    case plan(IntentRoutePlan)
    case failed(String)

    enum CapabilityMatchState: Equatable {
        case matches([CapabilityRecord])
        case noMatches
    }

    var capabilityMatchState: CapabilityMatchState? {
        guard case let .plan(plan) = self else { return nil }
        return plan.matchedCapabilities.isEmpty
            ? .noMatches
            : .matches(plan.matchedCapabilities)
    }

    var isPlanning: Bool {
        if case .planning = self { return true }
        return false
    }

    static func boundedFailure(_ error: Error) -> String {
        UserFacingError.cause(error, action: "plan that route")
    }
}

@MainActor
extension AppModel {
    @MainActor
    func routeIntent(_ message: String) async {
        let didRoute = await routeIntent(message, using: { message in
            try IntentRoutePlan(await SwiftNativeRouterPlanClient().planRoute(message: message))
        })
        guard didRoute else { return }
        await engine.turns.refreshCapabilityTraces()
    }

    /// The UI owns visible route state while the injected planner remains the
    /// real router boundary. The overload makes the successful-empty and
    /// failed paths executable without a source-text proxy.
    @MainActor
    @discardableResult
    func routeIntent(
        _ message: String,
        using planner: (String) async throws -> IntentRoutePlan
    ) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            routePlan = nil
            routePresentation = .failed("Enter a task before planning a route.")
            statusText = "Router needs a task to plan."
            return false
        }
        routePlan = nil
        routePresentation = .planning
        do {
            let plan = try await planner(trimmed)
            routePlan = plan
            routePresentation = .plan(plan)
            statusText = "Route planned: \(plan.goalType)"
            return true
        } catch {
            let failure = IntentRoutePresentation.boundedFailure(error)
            routePlan = nil
            routePresentation = .failed(failure)
            statusText = "Router failed: \(failure)"
            return false
        }
    }
}


extension NextGenReceipt {
    // 2026-06-07 ui-taste-sweep #83: receipt rows on Capabilities used to
    // render the raw `detail` string — comma-separated "key: value, key:
    // value, createdAt: <ISO>" dumps with microsecond timestamps. Users
    // can't parse that at a glance. `humanized` runs the parser in
    // UserDisplayFormatters.humanizeReceipt so the row shows
    // "Archived · stale duplicate · 5 days ago" and the raw kv pairs are
    // available for an inspector / disclosure. Falls back gracefully when
    // the detail isn't kv-shaped (free-form text passes through).
    var humanized: UserDisplayFormatters.HumanizedReceipt {
        UserDisplayFormatters.humanizeReceipt(
            name: name,
            detail: detail ?? output,
            fallbackTitle: actionId ?? phaseId ?? "Receipt"
        )
    }
}
