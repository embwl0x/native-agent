import Foundation
import SwiftUI

enum CapabilitiesDisclosurePreference {
    static let nextGenKey = "capabilitiesShowNextGen"

    static func isNextGenExpanded(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: nextGenKey)
    }

    static func setNextGenExpanded(_ isExpanded: Bool, in defaults: UserDefaults) {
        defaults.set(isExpanded, forKey: nextGenKey)
    }
}

enum CapabilitiesPresentation {
    /// Missing metadata is privileged ambiguity, never permission to run.
    static func runRequiresApproval(_ action: NativeActionRecord) -> Bool {
        action.requiresApproval != false
    }
}

/// The overview tiles are evidence from a scoped Capabilities refresh, not
/// launch defaults. A dash is intentional: it says the source was not loaded
/// (or failed) instead of silently reporting zero capabilities.
enum CapabilitiesRefreshPresentation {
    struct SummaryTiles: Equatable {
        let capabilities: String
        let workflows: String
        let mcp: String
        let nextGen: String
        let approvals: String
        let notice: String?
    }

    static func summary(
        capabilityCount: Int?,
        workflowCount: Int,
        mcpCount: Int,
        nextGenReadyCount: Int,
        nextGenTotalCount: Int,
        approvalCount: Int,
        refresh: AppModel.PanelRefreshStatus?
    ) -> SummaryTiles {
        let failures = Set(refresh?.failedEndpoints.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } ?? [])
        func value(_ value: String, endpoint: String) -> String {
            guard refresh != nil, !failures.contains(endpoint) else { return "—" }
            return value
        }
        let unavailable = refresh == nil
            ? "Capability summary is loading."
            : failures.isEmpty ? nil
            : "Some capability data is unavailable; tiles marked — were not loaded."
        return SummaryTiles(
            capabilities: value(capabilityCount.map { String($0) } ?? "—", endpoint: "capability summary"),
            workflows: value(String(workflowCount), endpoint: "workflows"),
            mcp: value(String(mcpCount), endpoint: "mcp servers"),
            nextGen: value("\(nextGenReadyCount)/\(nextGenTotalCount)", endpoint: "nextgen summary"),
            approvals: value(String(approvalCount), endpoint: "approvals"),
            notice: unavailable
        )
    }
}

/// The footer is scoped to Capabilities. `AppModel.statusText` is intentionally
/// global and can be replaced by a chat, approval, or background operation
/// before this view redraws; rendering it here made unrelated work look like a
/// Capabilities result.
enum CapabilitiesStatusLinePresentation {
    struct State: Equatable {
        let text: String
        let status: String
    }

    static func resolve(refresh: AppModel.PanelRefreshStatus?) -> State {
        guard let refresh else {
            return State(
                text: "Capabilities data has not loaded yet.",
                status: "info"
            )
        }
        guard !refresh.isStale else {
            let count = refresh.failedEndpoints.count
            let source = count == 1 ? "source" : "sources"
            guard refresh.lastSuccessAt != nil else {
                return State(
                    text: "Capabilities data is unavailable: \(count) \(source) did not load.",
                    status: "failed"
                )
            }
            return State(
                text: "Capabilities refresh is incomplete: \(count) \(source) did not load. Showing last known data where available.",
                status: "warn"
            )
        }
        return State(text: "Capabilities data is current.", status: "ok")
    }
}

struct CapabilitiesStatusTextLine: View {
    let state: CapabilitiesStatusLinePresentation.State

    var body: some View {
        Label(state.text, systemImage: state.status == "failed" ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
            .font(NativeAgentFont.label)
            .foregroundStyle(NativeAgentTheme.statusColor(state.status))
            .textSelection(.enabled)
            .accessibilityIdentifier("capabilities.statusText")
    }
}

/// The compact MCP Builder depends on three separately-read authorities. Do
/// not collapse a failed registry/session/consent read into an empty builder;
/// the detailed MCP hub remains the canonical full surface.
enum CapabilityMCPBuilderPresentation {
    enum ReadState: Equatable {
        case loading
        case empty
        case available
        case stale
        case unavailable
    }

    struct State: Equatable {
        let servers: ReadState
        let sessions: ReadState
        let consents: ReadState
        let sessionErrorCount: Int

        var collapsedAttentionBadge: String? {
            if sessionErrorCount > 0 {
                return "\(sessionErrorCount) error\(sessionErrorCount == 1 ? "" : "s")"
            }
            if servers == .unavailable || sessions == .unavailable || consents == .unavailable {
                return "MCP unavailable"
            }
            if servers == .stale || sessions == .stale || consents == .stale {
                return "MCP stale"
            }
            return nil
        }

        var serverEmptyCopy: String? {
            switch servers {
            case .loading:
                return "MCP servers have not loaded yet."
            case .empty:
                return "No MCP servers configured."
            case .unavailable:
                return "MCP server registry is unavailable. Refresh Capabilities to try again."
            case .available, .stale:
                return nil
            }
        }

        var detailNotice: String? {
            if sessions == .unavailable || consents == .unavailable {
                return "Live MCP session or consent details are unavailable; do not rely on missing status rows."
            }
            if sessions == .stale || consents == .stale {
                return "Some MCP session or consent details are from the last successful refresh."
            }
            if servers == .stale {
                return "Showing the last loaded MCP server registry."
            }
            return nil
        }
    }

    static func resolve(
        serverCount: Int,
        sessionCount: Int,
        consentCount: Int,
        sessionErrorCount: Int,
        hasRefreshAttempt: Bool,
        failedEndpoints: [String]
    ) -> State {
        let failures = Set(failedEndpoints.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return State(
            servers: readState(
                count: serverCount,
                hasRefreshAttempt: hasRefreshAttempt,
                failed: failures.contains("mcp servers")
            ),
            sessions: readState(
                count: sessionCount,
                hasRefreshAttempt: hasRefreshAttempt,
                failed: failures.contains("mcp sessions")
            ),
            consents: readState(
                count: consentCount,
                hasRefreshAttempt: hasRefreshAttempt,
                failed: failures.contains("mcp consent")
            ),
            sessionErrorCount: max(0, sessionErrorCount)
        )
    }

    private static func readState(count: Int, hasRefreshAttempt: Bool, failed: Bool) -> ReadState {
        if failed { return count > 0 ? .stale : .unavailable }
        if !hasRefreshAttempt { return count > 0 ? .available : .loading }
        return count > 0 ? .available : .empty
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
        Label(outcome.message, systemImage: outcome.systemImage)
            .font(.caption)
            .foregroundStyle(NativeAgentTheme.statusColor(outcome.status))
            .accessibilityIdentifier("capabilities.catalog.install-outcome")
    }
}

/// The hardening report is an externalized runtime authority, not a local
/// inference. Keep its missing and unavailable states explicit so an export
/// can be used to diagnose the latter without claiming the former is healthy.
enum CapabilityProductionExportButtonsPresentation {
    struct Notice: Equatable {
        let detail: String
        let status: String
    }

    static func notice(for outcome: ProductionExportCreationOutcome) -> Notice {
        switch outcome {
        case .verified(let export):
            let kind = export.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = kind?.isEmpty == false ? kind!.capitalized : "Export"
            let bytes = export.sizeBytes ?? 0
            return Notice(
                detail: "\(label) created and verified: \(export.path) (\(bytes) bytes).",
                status: "ok"
            )
        case .failed(let support, let detail):
            let label = support ? "Support bundle" : "Export"
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return Notice(
                detail: "\(label) was not verified: \(trimmed.isEmpty ? "no error detail was returned" : trimmed)",
                status: "failed"
            )
        }
    }
}

struct CapabilityProductionHardeningPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var exportNotice: CapabilityProductionExportButtonsPresentation.Notice?
    @State private var isCreatingExport = false

    var body: some View {
        NativePanel(title: "Production Hardening", systemImage: "checkmark.seal") {
            if let hardening = appModel.productionHardening {
                HStack(spacing: 8) {
                    StatusBadge(text: hardening.status.uppercased(), status: hardening.status)
                    if let doctor = hardening.doctorStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !doctor.isEmpty {
                        StatusBadge(text: "Doctor \(doctor)", status: doctor)
                    }
                    Spacer()
                    Button(isCreatingExport ? "Creating Export…" : "Export", systemImage: "square.and.arrow.up") {
                        Task { await createExport(support: false) }
                    }
                    .disabled(isCreatingExport)
                    .accessibilityIdentifier("capabilities.hardening.export")
                    Button(isCreatingExport ? "Creating Bundle…" : "Support Bundle", systemImage: "shippingbox") {
                        Task { await createExport(support: true) }
                    }
                    .disabled(isCreatingExport)
                    .accessibilityIdentifier("capabilities.hardening.support-bundle")
                }

                if let detail = hardening.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !detail.isEmpty {
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(NativeAgentTheme.statusColor(hardening.status))
                        .accessibilityIdentifier("capabilities.hardening.detail")
                }

                if let exportNotice {
                    Label(
                        exportNotice.detail,
                        systemImage: exportNotice.status == "failed" ? "exclamationmark.triangle.fill" : "archivebox.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(NativeAgentTheme.statusColor(exportNotice.status))
                    .accessibilityIdentifier("capabilities.hardening.export-receipt")
                }

                if let latest = appModel.productionExports.first {
                    CapabilityDetailRow(
                        title: (latest.kind ?? "export").capitalized,
                        detail: "\(latest.path) · \(latest.sizeBytes ?? 0) bytes",
                        status: "ok",
                        systemImage: "archivebox"
                    )
                }

                if let release = hardening.release {
                    VStack(alignment: .leading, spacing: 10) {
                        if !release.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            StatusBadge(text: "Release \(release.status.uppercased())", status: release.status)
                        }
                        if release.items.isEmpty {
                            Label("Release checklist contains no recorded checks.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(release.items.prefix(8)) { item in
                                CapabilityDetailRow(
                                    title: item.title,
                                    detail: item.detail,
                                    status: item.status,
                                    systemImage: "checkmark.seal"
                                )
                            }
                        }
                    }
                } else {
                    Label("This report did not include a release checklist.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Production summary has not loaded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("capabilities.production-hardening")
    }

    @MainActor
    private func createExport(support: Bool) async {
        guard !isCreatingExport else { return }
        isCreatingExport = true
        defer { isCreatingExport = false }
        exportNotice = CapabilityProductionExportButtonsPresentation.notice(
            for: await appModel.createProductionExport(support: support)
        )
    }
}

struct CapabilitiesView: View {
    @Environment(AppModel.self) private var appModel
    @State private var mode: CapabilityWorkspaceMode
    @State private var routeText = "Research a topic, build a reusable tool if it repeats, and keep it approval-gated."
    @State private var researchObjective = "Find current best practices for lightweight autonomous agent capability systems."
    @State private var researchLabRunsState: CapabilitiesResearchLabPresentation.RunList = .loading
    @State private var researchLabMessage: CapabilitiesResearchLabPresentation.Message?
    @State private var isRunningResearchLab = false
    @State private var mcpQuery = "NativeAgent capabilities"
    @State private var catalogSourceName = "Local NativeAgent Catalog"
    @State private var catalogSourceURL = ""
    @State private var catalogSourceOutcome: AppModel.CapabilityCatalogSourceSaveOutcome?
    /// Per-action result from the checked SecurityCenter authority owner.
    /// Missing stays conservative: the Run button remains disabled until a
    /// current policy/origin read proves admitted Full Mac YOLO.
    @State private var nativeActionYoloAdmission: [String: Bool] = [:]
    private let loadsOnAppear: Bool
    // 2026-07-22 page-tighten: the two heaviest always-expanded blocks
    // (Next-Gen Runtime migration cockpit in Overview, MCP Builder in Build —
    // whose canonical home is the dedicated MCP tab) collapse by default;
    // open-state persists across visits like the Trust Advanced group.
    @AppStorage(CapabilitiesDisclosurePreference.nextGenKey) private var showNextGen = false
    @AppStorage("capabilitiesShowMCPBuilder") private var showMCPBuilder = false

    init(initialMode: CapabilityWorkspaceMode = .overview, loadsOnAppear: Bool = true) {
        _mode = State(initialValue: initialMode)
        self.loadsOnAppear = loadsOnAppear
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Workspace", selection: $mode) {
                    ForEach(CapabilityWorkspaceMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                summaryGrid

                switch mode {
                case .overview:
                    overview
                case .build:
                    build
                case .operate:
                    operate
                case .hardening:
                    hardening
                }

                CapabilitiesStatusTextLine(
                    state: CapabilitiesStatusLinePresentation.resolve(
                        refresh: appModel.panelRefreshStatus[.capabilities]
                    )
                )
            }
            .padding()
        }
        .navigationTitle("Capabilities")
        .task {
            guard loadsOnAppear else { return }
            await appModel.refreshForSidebarItem(.capabilities)
            await refreshNativeActionYoloAdmission()
            await refreshResearchLabRuns()
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task {
                    await appModel.refreshForSidebarItem(.capabilities)
                    await refreshNativeActionYoloAdmission()
                    await refreshResearchLabRuns()
                }
            }
        }
    }

    private var summaryGrid: some View {
        let tiles = CapabilitiesRefreshPresentation.summary(
            capabilityCount: appModel.capabilitySummary?.summary.total,
            workflowCount: appModel.workflows.count,
            mcpCount: appModel.mcpServers.count,
            nextGenReadyCount: nextGenReadyCount,
            nextGenTotalCount: nextGenTotalCount,
            approvalCount: appModel.approvals.filter { $0.status.lowercased() == "pending" }.count,
            refresh: appModel.panelRefreshStatus[.capabilities]
        )
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                MetricTile(title: "Capabilities", value: tiles.capabilities, systemImage: "shippingbox")
                MetricTile(title: "Workflows", value: tiles.workflows, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                MetricTile(title: "MCP", value: tiles.mcp, systemImage: "externaldrive.connected.to.line.below")
                MetricTile(title: "Next Gen", value: tiles.nextGen, systemImage: "sparkles.rectangle.stack")
                MetricTile(title: "Approvals", value: tiles.approvals, systemImage: "checkmark.shield")
            }
            if let notice = tiles.notice {
                Label(notice, systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // 2026-07-22 page-tighten: collapsed-card wrapper — styling mirrors the
    // Trust tab's Advanced disclosure and MacControlPermissionsView's
    // Advanced Mac Control group for a consistent "more lives here" idiom.
    // 2026-07-23 audit F5-L1: a collapsed card hides its inner attention
    // state (e.g. an MCP session's lastError). When the underlying state
    // carries an attention signal, render a warn StatusBadge on the header so
    // the signal survives the collapse. Nil = no badge (identical to before).
    private func collapsedCard<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        attentionBadge: String? = nil,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let inner = content()
        return DisclosureGroup(isExpanded: isExpanded) {
            inner
                .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(NativeAgentFont.section)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let attentionBadge {
                    StatusBadge(text: attentionBadge, status: "warn")
                }
            }
            .togglesDisclosure(isExpanded)
        }
        .padding(NativeAgentSpacing.lg)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            // L3#7 (2026-08-11): the "Capability Foundry" panel is deleted.
            // E-1 already stripped its fake counters; what was left was a
            // status badge and 2-3 lane tiles over a subsystem that was never
            // ported (no auto-implementation ledger, no review pipeline). The
            // Core CapabilityFoundry stays behind its MCP metadata consumer;
            // the panel claimed a workshop that does not exist.

            collapsedCard(
                title: "Next-Gen Runtime",
                subtitle: "Phase readiness, dry-run probes, and migration receipts.",
                systemImage: "sparkles.rectangle.stack",
                isExpanded: $showNextGen,
                attentionBadge: nextGenReviewCount > 0 ? "\(nextGenReviewCount) to review" : nil,
                accessibilityIdentifier: "capabilities.show-next-gen"
            ) {
                nextGenRuntime
            }

            NativePanel(title: "Foundry Index", systemImage: "shippingbox") {
                switch CapabilitiesFoundryIndexPresentation.state(summary: appModel.capabilitySummary) {
                case .populated(let summary):
                    HStack(spacing: 8) {
                        StatusBadge(text: "\(summary.summary.active) active", status: "ok")
                        StatusBadge(text: "\(summary.summary.review) review", status: summary.summary.review > 0 ? "warn" : "ok")
                        StatusBadge(text: "\(summary.summary.autoloaded) autoloaded", status: summary.summary.autoloaded == 0 ? "ok" : "warn")
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(summary.records.prefix(14))) { capability in
                            CapabilityRow(capability: capability)
                            if capability.id != summary.records.prefix(14).last?.id {
                                Divider()
                            }
                        }
                    }
                case .empty:
                    NativeEmptyState(
                        title: "No indexed capabilities",
                        detail: CapabilitiesFoundryIndexPresentation.emptyDetail,
                        systemImage: "shippingbox"
                    )
                case .unavailable:
                    NativeEmptyState(
                        title: "Foundry index unavailable",
                        detail: CapabilitiesFoundryIndexPresentation.unavailableDetail,
                        systemImage: "shippingbox"
                    )
                case .inconsistent(let reason):
                    NativeEmptyState(
                        title: "Foundry index needs refresh",
                        detail: CapabilitiesFoundryIndexPresentation.inconsistentDetail(reason),
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }

            NativePanel(title: "Personal OS", systemImage: "rectangle.3.group.bubble.left") {
                if let personalOS = appModel.personalOS {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                        ForEach(personalOS.spaces) { space in
                            CapabilityMetricCard(title: space.name, value: "\(space.count)", detail: space.kind ?? "space", systemImage: "square.grid.2x2")
                        }
                    }
                } else {
                    Text("Personal OS summary has not loaded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var nextGenLoadedPhases: [NextGenPhase] {
        var seen = Set<String>()
        let combined = appModel.nextGenPhases + (appModel.nextGenSummary?.phases ?? [])
        return combined
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                switch (lhs.phaseNumber, rhs.phaseNumber) {
                case let (left?, right?):
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
            }
    }

    private var nextGenReadyCount: Int {
        if let count = appModel.nextGenSummary?.readyPhaseCount {
            return count
        }
        return nextGenLoadedPhases.filter { $0.ready == true || $0.displayStatus == "ready" }.count
    }

    private var nextGenTotalCount: Int {
        appModel.nextGenSummary?.totalPhaseCount ?? nextGenLoadedPhases.count
    }

    // F5-L1 attention signals surfaced on the collapsed card headers.
    // Next-Gen: phases not yet ready are the review-needed count. MCP: sessions
    // reporting a non-empty lastError (the detail otherwise hidden at :532).
    private var nextGenReviewCount: Int {
        max(0, nextGenTotalCount - nextGenReadyCount)
    }

    private var mcpBuilderPresentation: CapabilityMCPBuilderPresentation.State {
        let refresh = appModel.panelRefreshStatus[.capabilities]
        return CapabilityMCPBuilderPresentation.resolve(
            serverCount: appModel.mcpServers.count,
            sessionCount: appModel.mcpSessions.count,
            consentCount: appModel.mcpConsent.count,
            sessionErrorCount: appModel.mcpSessions.filter {
                !($0.lastError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }.count,
            hasRefreshAttempt: refresh != nil,
            failedEndpoints: refresh?.failedEndpoints ?? []
        )
    }

    private var nextGenReceipts: [NextGenReceipt] {
        var seen = Set<String>()
        let combined =
            (appModel.latestNextGenReceipt.map { [$0] } ?? []) +
            appModel.nextGenReceipts +
            (appModel.nextGenSummary?.displayReceipts ?? []) +
            nextGenLoadedPhases.compactMap(\.latestReceipt)
        return combined.filter { seen.insert($0.id).inserted }
    }

    /// L3#6 (2026-08-11): the catalog (`nextgen_phases.json`) is a data file and
    /// can list any action id; the read-only executor is a fixed switch. Only
    /// ids that switch actually has a case for get a button — everything else
    /// resolves to `default:` → 410 "not backed by a Swift read-only executor
    /// yet", which is a button that cannot do its job. One set intersection.
    private var nextGenActions: [NextGenAction] {
        var seen = Set<String>()
        let combined = (appModel.nextGenSummary?.actions ?? []) + nextGenLoadedPhases.flatMap { $0.actions ?? [] }
        return combined
            .filter { NativeClient.isNextGenActionBacked($0.id) }
            .filter { seen.insert($0.id).inserted }
    }

    private var nextGenRuntime: some View {
        NativePanel(title: "Next-Gen Runtime", systemImage: "sparkles.rectangle.stack") {
            if appModel.nextGenSummary == nil && nextGenLoadedPhases.isEmpty && appModel.latestNextGenReceipt == nil {
                Text("Next-gen runtime summary has not loaded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    StatusBadge(text: (appModel.nextGenSummary?.readinessStatus ?? "ready").uppercased(), status: appModel.nextGenSummary?.readinessStatus ?? "ready")
                    if let current = appModel.nextGenSummary?.currentPhaseName ?? appModel.nextGenSummary?.currentPhaseId {
                        InfoPill(text: current.withoutStaleNextGenPhaseCopy, systemImage: "flag.checkered")
                    }
                    InfoPill(text: "\(nextGenLoadedPhases.count) phases", systemImage: "square.stack.3d.up")
                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    NativeRuntimeTile(
                        title: "Phase Readiness",
                        value: "\(nextGenReadyCount)/\(nextGenTotalCount)",
                        detail: appModel.nextGenSummary?.readiness ?? "ready phases",
                        status: appModel.nextGenSummary?.readinessStatus ?? "ready",
                        systemImage: "checklist.checked"
                    )
                    NativeRuntimeTile(
                        title: "Receipts",
                        value: "\(appModel.nextGenSummary?.receiptCount ?? nextGenReceipts.count)",
                        detail: nextGenReceipts.first?.displayStatus ?? "none yet",
                        status: nextGenReceipts.first?.displayStatus ?? "warn",
                        systemImage: "receipt"
                    )
                    NativeRuntimeTile(
                        title: "Dry-Run Probes",
                        value: "\(appModel.nextGenSummary?.actionCount ?? nextGenActions.count)",
                        detail: appModel.isRunningNextGenAction ? "running" : "available",
                        status: appModel.isRunningNextGenAction ? "running" : "ready",
                        systemImage: "play.circle"
                    )
                }

                if !nextGenLoadedPhases.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(nextGenLoadedPhases) { phase in
                            NextGenPhaseRow(phase: phase, isRunning: appModel.isRunningNextGenAction) { actionId in
                                Task { await appModel.runNextGenAction(id: actionId, dryRun: true) }
                            }
                            if phase.id != nextGenLoadedPhases.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                if !nextGenActions.isEmpty {
                    Divider()
                    HStack(spacing: 8) {
                        ForEach(nextGenActions.prefix(4)) { action in
                            Button(action.displayName, systemImage: "play.circle") {
                                Task { await appModel.runNextGenAction(action, dryRun: true) }
                            }
                            .disabled(appModel.isRunningNextGenAction || action.dryRunAvailable == false)
                        }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                }

                if !nextGenReceipts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(nextGenReceipts.prefix(6)) { receipt in
                            // 2026-06-07 ui-taste-sweep #83: humanized title +
                            // subtitle replaces the raw kv-dump. rawPairs adds
                            // a "Show details" disclosure for the full payload.
                            let h = receipt.humanized
                            CapabilityDetailRow(
                                title: h.title,
                                detail: h.subtitle,
                                status: receipt.displayStatus,
                                systemImage: receipt.dryRun == true ? "testtube.2" : "receipt",
                                rawPairs: h.rawPairs.isEmpty ? nil : h.rawPairs
                            )
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("capabilities.show-next-gen.content")
    }

    private var build: some View {
        VStack(alignment: .leading, spacing: 16) {
            // W3 (eval5): surface the "feature disabled / not implemented"
            // envelope for Build-tab actions (workflow run, capability pack
            // install, MCP warm/refresh) so users see why nothing happened
            // instead of a fake success toast.
            if let disabled = appModel.disabledFeature, !disabled.isEmpty {
                Label(disabled, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.orange)
            }
            WorkflowBuilderPanel()

            NativePanel(title: "Capability Catalog", systemImage: "square.grid.3x3") {
                HStack {
                    Button("Install Signed Demo Pack", systemImage: "checkmark.seal") {
                        Task { await appModel.installDemoCapabilityPack() }
                    }
                    .disabled(appModel.isInstallingDemoCapabilityPack)
                    .accessibilityIdentifier("capabilities.catalog.install-signed-demo")
                    .accessibilityHint("Verifies the demo pack signature before any capability files are written. Evaluate Trust is informational and is not required to install.")
                    Button("Check Updates", systemImage: "arrow.down.circle") {
                        Task { await appModel.checkCapabilityUpdates() }
                    }
                    if let capability = appModel.capabilitySummary?.records.first {
                        Button("Evaluate Trust", systemImage: "checkmark.shield") {
                            Task { await appModel.evaluateCapabilityTrust(capability) }
                        }
                    }
                    Spacer()
                    InfoPill(text: "\(appModel.capabilityPackInstalls.count) install(s)", systemImage: "clock.arrow.circlepath")
                }

                if let outcome = appModel.capabilityCatalogInstallOutcome {
                    CapabilityCatalogInstallOutcomeRow(outcome: outcome)
                }

                HStack {
                    TextField("Source name", text: $catalogSourceName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("capabilities.catalogSource.name")
                    TextField("Source URL or path", text: $catalogSourceURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("capabilities.catalogSource.url")
                    Button(appModel.capabilityCatalogSourceSaveInFlight ? "Saving Source…" : "Add Source", systemImage: "plus.circle") {
                        addCatalogSource()
                    }
                    .disabled(appModel.capabilityCatalogSourceSaveInFlight)
                    .accessibilityIdentifier("capabilities.catalogSource.add")
                }

                if let catalogSourceOutcome {
                    Label(catalogSourceOutcome.detail, systemImage: catalogSourceOutcome.status == "failed" ? "exclamationmark.triangle.fill" : "tray.full.fill")
                        .font(.caption)
                        .foregroundStyle(NativeAgentTheme.statusColor(catalogSourceOutcome.status))
                        .accessibilityIdentifier("capabilities.catalogSource.outcome")
                }

                if !appModel.capabilityCatalogSources.isEmpty || appModel.capabilityTrust != nil || appModel.latestCapabilityUpdateCheck != nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        CapabilityMetricCard(title: "Sources", value: "\(appModel.capabilityCatalogSources.count)", detail: appModel.capabilityCatalogSources.first?.status ?? "not checked", systemImage: "tray.full")
                        CapabilityMetricCard(title: "Trusted", value: "\(appModel.capabilityTrust?.summary?.trusted ?? 0)", detail: "\(appModel.capabilityTrust?.summary?.review ?? 0) review", systemImage: "checkmark.shield")
                        CapabilityMetricCard(title: "Updates", value: "\(appModel.latestCapabilityUpdateCheck?.updates.count ?? 0)", detail: appModel.latestCapabilityUpdateCheck?.status ?? "not checked", systemImage: "arrow.down.circle")
                    }
                }

                if let trust = appModel.latestCapabilityTrustEvaluation {
                    CapabilityDetailRow(title: trust.name ?? trust.id, detail: trust.reasons.prefix(2).joined(separator: " "), status: trust.trustTier, systemImage: "checkmark.shield")
                }

                if appModel.capabilityCatalog.isEmpty {
                    Text("No catalog items loaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(appModel.capabilityCatalog) { item in
                            CatalogRow(item: item)
                            if item.id != appModel.capabilityCatalog.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                if !appModel.capabilityPackInstalls.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(appModel.capabilityPackInstalls.prefix(4)) { install in
                            HStack(alignment: .top, spacing: 10) {
                                CapabilityDetailRow(
                                    title: install.name ?? install.packId,
                                    detail: "\(install.version ?? "unknown") · \(install.signature?.prefix(12) ?? "unsigned")",
                                    status: install.status,
                                    systemImage: "shippingbox.and.arrow.backward"
                                )
                                Spacer()
                                Button("Rollback", systemImage: "arrow.uturn.backward") {
                                    Task { await appModel.rollbackCapabilityPack(install) }
                                }
                                .disabled(install.status == "rolled_back")
                            }
                        }
                    }
                }
            }

            collapsedCard(
                title: "MCP Builder",
                subtitle: "Server warm/restart, tool calls, and consent — the full hub lives in the MCP tab.",
                systemImage: "externaldrive.connected.to.line.below",
                isExpanded: $showMCPBuilder,
                attentionBadge: mcpBuilderPresentation.collapsedAttentionBadge
            ) {
                mcpBuilderPanel
            }
        }
    }

    private func addCatalogSource() {
        catalogSourceOutcome = nil
        Task {
            let outcome = await appModel.addCatalogSource(name: catalogSourceName, url: catalogSourceURL)
            catalogSourceOutcome = outcome
            if outcome.didSave {
                catalogSourceName = ""
                catalogSourceURL = ""
            }
        }
    }

    private var mcpBuilderPanel: some View {
        let presentation = mcpBuilderPresentation
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Open MCP Hub", systemImage: "arrow.up.right.square") {
                    NotificationCenter.default.post(name: .openCommandRouteRequest, object: "mcp")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            NativePanel(title: "MCP Builder", systemImage: "externaldrive.connected.to.line.below") {
                TextField("MCP test query", text: $mcpQuery)
                    .textFieldStyle(.roundedBorder)
                if let detailNotice = presentation.detailNotice {
                    Label(detailNotice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let serverEmptyCopy = presentation.serverEmptyCopy {
                    Text(serverEmptyCopy)
                        .font(.callout)
                        .foregroundStyle(presentation.servers == .unavailable ? .orange : .secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(appModel.mcpServers) { server in
                            VStack(alignment: .leading, spacing: 8) {
                                MCPServerRow(server: server) {
                                    Task { await appModel.loadMCPDetails(server) }
                                }
                                HStack {
                                    Button("Warm", systemImage: "flame") {
                                        Task { await appModel.warmMCPServer(server) }
                                    }
                                    Button("Restart", systemImage: "arrow.clockwise.circle") {
                                        Task { await appModel.restartMCPServer(server) }
                                    }
                                    Button("Refresh Cache", systemImage: "externaldrive.badge.icloud") {
                                        Task { await appModel.refreshMCPCache(server) }
                                    }
                                    if let session = appModel.mcpSessions.first(where: { $0.serverId == server.id }) {
                                        InfoPill(text: session.status ?? "configured", systemImage: "bolt.horizontal")
                                        if let error = session.lastError, !error.isEmpty {
                                            Text(error)
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                            if server.id != appModel.mcpServers.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                if !appModel.mcpTools.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(appModel.mcpTools.prefix(6)) { tool in
                            HStack(alignment: .top) {
                                CapabilityDetailRow(title: tool.name, detail: tool.description ?? "MCP tool", status: "ok", systemImage: "hammer")
                                Spacer()
                                if let server = appModel.selectedMCPServer {
                                    Button("Grant", systemImage: "checkmark.shield") {
                                        Task { await appModel.grantMCPConsent(server: server, toolName: tool.name) }
                                    }
                                    Button("Call", systemImage: "play.circle") {
                                        Task { await appModel.callMCPTool(server: server, tool: tool, query: mcpQuery) }
                                    }
                                }
                            }
                        }
                    }
                }

                if let call = appModel.latestMCPCall {
                    Divider()
                    CapabilityDetailRow(
                        title: call.toolName,
                        detail: [call.serverId, call.resultPreview]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "),
                        status: call.evidenceStatus == "failed" ? "evidence_failed" : call.status,
                        systemImage: "terminal"
                    )
                }

                if !appModel.mcpConsent.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appModel.mcpConsent.prefix(4)) { consent in
                            HStack(alignment: .top, spacing: 10) {
                                CapabilityDetailRow(
                                    title: consent.toolName ?? consent.id,
                                    detail: consent.argumentSummary ?? consent.serverId ?? "MCP consent",
                                    status: consent.status ?? "granted",
                                    systemImage: "checkmark.shield"
                                )
                                Spacer()
                                Button("Revoke", systemImage: "xmark.shield") {
                                    Task { await appModel.revokeMCPConsent(consent) }
                                }
                                .disabled(consent.status == "revoked")
                            }
                        }
                    }
                }
            }
        }
    }

    private var operate: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativePanel(title: "Intent Router", systemImage: "arrow.triangle.branch") {
                TextField("Task to route", text: $routeText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                Button("Plan Route", systemImage: "arrow.triangle.branch") {
                    Task { await appModel.routeIntent(routeText) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.routePresentation.isPlanning)

                switch appModel.routePresentation {
                case .idle:
                    EmptyView()
                case .planning:
                    ProgressView("Planning route…")
                        .controlSize(.small)
                case let .failed(message):
                    Label(
                        "Router did not produce a plan: \(message)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                case let .plan(plan):
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            StatusBadge(text: plan.goalType.uppercased(), status: plan.risk)
                            StatusBadge(text: plan.risk.uppercased(), status: plan.risk)
                            if plan.requiresApproval {
                                StatusBadge(text: "APPROVAL", status: "warn")
                            }
                            Spacer()
                        }
                        ForEach(plan.nextActions, id: \.self) { action in
                            Label(action, systemImage: "checkmark.circle")
                                .font(.callout)
                        }
                        Text("Matched Capabilities")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        switch IntentRoutePresentation.plan(plan).capabilityMatchState {
                        case let .matches(capabilities):
                            ForEach(capabilities.prefix(5)) { capability in
                                CapabilityRow(capability: capability, compact: true)
                            }
                        case .noMatches:
                            Label(
                                "The router completed, but no installed capability matched this task.",
                                systemImage: "magnifyingglass"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        case nil:
                            EmptyView()
                        }
                    }
                }
            }

            NativePanel(title: "Research Lab", systemImage: "magnifyingglass") {
                TextField("Research objective", text: $researchObjective, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                Button("Run Research Lab", systemImage: "doc.text.magnifyingglass") {
                    Task { await runResearchLab() }
                }
                .disabled(isRunningResearchLab)

                if let researchLabMessage {
                    researchLabMessageRow(researchLabMessage)
                }

                switch researchLabRunsState {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading Research Lab receipts…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .empty:
                    NativeEmptyState(
                        title: "No research runs",
                        detail: "The Research Lab receipt store has no completed or connector-blocked runs yet.",
                        systemImage: "magnifyingglass"
                    )
                case .loaded(let runs):
                    researchLabRunRows(runs)
                case .unavailable(let detail, let retained):
                    Divider()
                    Label("Research Lab receipts unavailable: \(detail)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    if !retained.isEmpty {
                        Text("Showing last known receipts")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        researchLabRunRows(retained)
                    }
                }
            }

            NativePanel(title: "Trace Timeline", systemImage: "waveform.path") {
                let traceState = appModel.capabilityTraceTimeline
                if case .sourceAbsent = traceState {
                    Label("Trace history is not available yet. The durable trace feed has not been created.", systemImage: "tray")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if case .empty = traceState {
                    Text("No traces yet. Route, run a workflow, or install a catalog item to create one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if case .unavailable(let detail) = traceState {
                    Label("Trace history is unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if case .partial(_, let rejectedRows) = traceState {
                        Label(
                            "\(rejectedRows) malformed \(rejectedRows == 1 ? "trace" : "traces") withheld from this timeline.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(traceState.traces.prefix(14)) { trace in
                            CapabilityDetailRow(title: trace.title, detail: trace.kind, status: trace.status ?? "ok", systemImage: "waveform.path")
                            if trace.id != traceState.traces.prefix(14).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            SkillMemoryGraphPanel()
        }
    }

    @MainActor
    private func runResearchLab() async {
        isRunningResearchLab = true
        defer { isRunningResearchLab = false }
        let outcome = await appModel.runResearchLab(objective: researchObjective)
        researchLabMessage = CapabilitiesResearchLabPresentation.message(for: outcome)
        if case .recorded(let run) = outcome {
            researchLabRunsState = CapabilitiesResearchLabPresentation.list(
                rows: [run] + appModel.researchLabRuns.filter { $0.id != run.id }
            )
            await refreshResearchLabRuns()
        }
    }

    @MainActor
    private func refreshResearchLabRuns() async {
        researchLabRunsState = await appModel.refreshResearchLabRunsForCapabilities()
    }

    @ViewBuilder
    private func researchLabMessageRow(_ message: CapabilitiesResearchLabPresentation.Message) -> some View {
        Label(message.text, systemImage: message.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(researchLabColor(message.tone))
        if let detail = message.detail {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(researchLabColor(message.tone))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func researchLabRunRows(_ runs: [ResearchLabRun]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(runs.prefix(4)) { run in
                let message = CapabilitiesResearchLabPresentation.message(for: run)
                CapabilityDetailRow(
                    title: run.objective,
                    detail: message.detail ?? message.text,
                    status: run.status,
                    systemImage: message.systemImage
                )
                if run.id != runs.prefix(4).last?.id {
                    Divider()
                }
            }
        }
    }

    private func researchLabColor(_ tone: CapabilitiesResearchLabPresentation.Tone) -> Color {
        switch tone {
        case .neutral, .progress:
            .secondary
        case .success:
            .green
        case .warning:
            .orange
        case .failure:
            .red
        }
    }

    private var hardening: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativePanel(title: "Autonomy Kernel", systemImage: "lock.shield") {
                if let kernel = appModel.autonomyKernel {
                    HStack(spacing: 8) {
                        StatusBadge(text: kernel.status.uppercased(), status: kernel.status)
                        if let mode = kernel.mode {
                            InfoPill(text: mode, systemImage: "slider.horizontal.3")
                        }
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(kernel.guardrails) { guardrail in
                            CapabilityDetailRow(title: guardrail.title, detail: guardrail.id, status: guardrail.status, systemImage: "checkmark.shield")
                        }
                    }
                } else {
                    Text("Kernel summary has not loaded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            CapabilitiesApprovalInboxPanel()

            NativePanel(title: "Native macOS Power", systemImage: "macwindow") {
                // 2026-07-21 audit fix (dead-surface honesty): the
                // `nativePower.surfaces` list and the "App Intents" tile were
                // removed — getNativePower() is a DAEMON-KILL P1 stub that
                // returns surfaces: [] forever, and /v1/native/intents was
                // retired with no SwiftNative successor (the dead intent-registry
                // chain was fully deleted 2026-08-14), so both rendered permanent
                // empty/"Loading" furniture. The remaining tiles and action
                // rows below are fed by live readers.
                let refresh = appModel.panelRefreshStatus[.capabilities]
                let failedEndpoints = Set((refresh?.failedEndpoints ?? []).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })
                let notificationTile = NativeMacPowerPanelPresentation.tile(
                    value: appModel.notificationStatus?.pendingApprovals.map(String.init),
                    detail: "pending approvals",
                    runtimeStatus: appModel.notificationStatus?.status,
                    hasRefreshAttempt: refresh != nil,
                    readFailed: failedEndpoints.contains("notification status")
                )
                let browserTile = NativeMacPowerPanelPresentation.tile(
                    value: appModel.browserRuntimeStatus?.receiptCount.map(String.init),
                    detail: appModel.browserRuntimeStatus?.domainPolicy,
                    runtimeStatus: appModel.browserRuntimeStatus?.status,
                    hasRefreshAttempt: refresh != nil,
                    readFailed: failedEndpoints.contains("browser status")
                )
                let vectorTile = NativeMacPowerPanelPresentation.tile(
                    value: appModel.memoryVectorStatus?.nodeCount.map(String.init),
                    detail: appModel.memoryVectorStatus?.providerModel,
                    runtimeStatus: appModel.memoryVectorStatus?.status,
                    hasRefreshAttempt: refresh != nil,
                    readFailed: failedEndpoints.contains("memory vector status")
                )
                let nativeActionsState = NativeMacPowerPanelPresentation.readState(
                    itemCount: appModel.nativeActions.count,
                    hasRefreshAttempt: refresh != nil,
                    readFailed: failedEndpoints.contains("native actions")
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    NativeRuntimeTile(
                        title: "Notifications",
                        value: notificationTile.value,
                        detail: notificationTile.detail,
                        status: notificationTile.status,
                        systemImage: "bell.badge"
                    )
                    NativeRuntimeTile(
                        title: "Browser",
                        value: browserTile.value,
                        detail: browserTile.detail,
                        status: browserTile.status,
                        systemImage: "safari"
                    )
                    NativeRuntimeTile(
                        title: "Vector Memory",
                        value: vectorTile.value,
                        detail: vectorTile.detail,
                        status: vectorTile.status,
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                }

                if nativeActionsState == .unavailable {
                    Divider()
                    Label("Native action registry is unavailable. Refresh Capabilities before relying on action availability.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if nativeActionsState == .loading {
                    Divider()
                    Text("Native actions have not loaded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if appModel.nativeActions.isEmpty {
                    Divider()
                    Text("No native actions are currently registered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Divider()
                    if nativeActionsState == .stale {
                        Label("Showing the last loaded native action registry.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(appModel.nativeActions.prefix(6)) { action in
                            let actionPresentation = NativeMacPowerPanelPresentation.action(
                                requiresApproval: action.requiresApproval,
                                dryRunAvailable: action.dryRunAvailable,
                                fullMacYoloAdmitted: nativeActionYoloAdmission[action.id] == true
                            )
                            HStack(alignment: .top, spacing: 10) {
                                CapabilityDetailRow(
                                    title: action.name,
                                    detail: action.kind ?? action.id,
                                    status: action.risk ?? "ok",
                                    systemImage: "command"
                                )
                                Spacer()
                                Button("Dry Run", systemImage: "play.circle") {
                                    Task { await appModel.runNativeAction(action, dryRun: true) }
                                }
                                .disabled(!actionPresentation.canDryRun)
                                Button("Run", systemImage: "bolt.circle") {
                                    Task { await appModel.runNativeAction(action, dryRun: false) }
                                }
                                .disabled(!actionPresentation.canRun)
                            }
                            if let blockedDetail = actionPresentation.blockedDetail {
                                Label(blockedDetail, systemImage: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // B2.3 residue restoration (gpt-5.5 review BLOCKING): the
                // retired Command Center's "Recent Receipts" rollup listed the
                // last FOUR native-action receipts; this row showed only the
                // latest, which silently narrowed visibility when the roll-up
                // died. Canonical home is here, next to the actions themselves.
                if !appModel.nativeActionReceipts.isEmpty {
                    Divider()
                    ForEach(appModel.nativeActionReceipts.prefix(4)) { receipt in
                        CapabilityDetailRow(title: receipt.name ?? receipt.actionId, detail: receipt.createdAt ?? receipt.actionId, status: receipt.status, systemImage: "receipt")
                    }
                }

                if let connectorRegistry = appModel.connectorActionRegistry {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("\(connectorRegistry.actions.count) connector action(s)", systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if let latest = appModel.latestConnectorActionReceipt ?? connectorRegistry.latestReceipt {
                                StatusBadge(text: latest.status.uppercased(), status: latest.status)
                            }
                        }
                        ForEach(connectorRegistry.actions.prefix(4)) { action in
                            HStack {
                                CapabilityDetailRow(
                                    title: action.name,
                                    detail: "\(action.connectorId ?? "connector") · \(action.authState ?? "unknown")",
                                    status: action.connectorStatus ?? (action.enabled == true ? "ok" : "warn"),
                                    systemImage: "link"
                                )
                                Spacer()
                                Button("Dry Run", systemImage: "play.circle") {
                                    Task { await appModel.runConnectorAction(action) }
                                }
                            }
                        }
                    }
                }

                Divider()
                CapabilitiesRunGauntletAndBrowserActions()
            }

            CapabilityProductionHardeningPanel()
        }
    }

    @MainActor
    private func refreshNativeActionYoloAdmission() async {
        let actionIDs = appModel.nativeActions
            .filter { $0.requiresApproval != false }
            .map(\.id)
        var checked: [String: Bool] = [:]
        for actionID in actionIDs {
            checked[actionID] = await appModel.fullMacYoloAuthorityAdmitted(
                tool: actionID,
                surface: "native_actions"
            )
        }
        nativeActionYoloAdmission = checked
    }
}

struct CapabilitiesRunGauntletAndBrowserActions: View {
    @Environment(AppModel.self) private var appModel
    @State private var isRunningBrowserDryRun = false
    @State private var isRunningGauntlet = false

    private var latestGauntlet: ImprovementGauntletRun? {
        appModel.latestGauntletRun ?? appModel.improvementGauntletStatus?.latestRun
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Browser Dry Run", systemImage: "safari") {
                    Task {
                        isRunningBrowserDryRun = true
                        defer { isRunningBrowserDryRun = false }
                        await appModel.runBrowserDryRun()
                    }
                }
                .disabled(isRunningBrowserDryRun)
                .accessibilityIdentifier("capabilities.browser-dry-run")

                Button("Cancel Browser", systemImage: "stop.circle") {
                    Task { await appModel.cancelBrowserRun() }
                }
                .accessibilityIdentifier("capabilities.browser-cancel")

                Button("Run Gauntlet", systemImage: "checkmark.shield") {
                    Task {
                        isRunningGauntlet = true
                        defer { isRunningGauntlet = false }
                        await appModel.runImprovementGauntlet()
                    }
                }
                .disabled(isRunningGauntlet)
                .accessibilityIdentifier("capabilities.run-gauntlet")

                Spacer()
                if let latestGauntlet {
                    StatusBadge(text: latestGauntlet.status.uppercased(), status: latestGauntlet.status)
                }
            }

            if let run = appModel.latestBrowserRun {
                let presentation = CapabilitiesRunActionPresentation.browserOutcome(for: run)
                CapabilityDetailRow(
                    title: presentation.title,
                    detail: presentation.detail,
                    status: presentation.status,
                    systemImage: "safari"
                )
                .accessibilityIdentifier("capabilities.browser-dry-run.outcome")
            }

            if let gauntlet = latestGauntlet {
                let presentation = CapabilitiesRunActionPresentation.gauntletOutcome(for: gauntlet)
                CapabilityDetailRow(
                    title: presentation.title,
                    detail: presentation.detail,
                    status: presentation.status,
                    systemImage: "checkmark.shield"
                )
                .accessibilityIdentifier("capabilities.run-gauntlet.outcome")

                if !presentation.failedCheckTitles.isEmpty {
                    Label(
                        "Failed: \(presentation.failedCheckTitles.joined(separator: ", "))",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("capabilities.run-gauntlet.failures")
                }
            }

            if appModel.statusText.hasPrefix("Browser dry run:")
                || appModel.statusText.hasPrefix("Browser run failed:")
                || appModel.statusText.hasPrefix("Gauntlet:")
                || appModel.statusText.hasPrefix("Gauntlet failed:") {
                Text(appModel.statusText)
                    .font(.caption)
                    .foregroundStyle(appModel.statusText.contains("failed:") ? .orange : .secondary)
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
            title: "Latest Browser Run",
            detail: "\(run.dryRun == true ? "Dry run" : "Not a dry run") · \(run.url ?? "no URL recorded")",
            status: run.status,
            failedCheckTitles: []
        )
    }

    static func gauntletOutcome(for run: ImprovementGauntletRun) -> Outcome {
        let checks = run.checks ?? []
        let passed = checks.filter(\.passed).count
        return Outcome(
            title: "Latest Gauntlet",
            detail: checks.isEmpty ? "No checks recorded" : "\(passed)/\(checks.count) checks passed",
            status: run.status,
            failedCheckTitles: checks.filter { !$0.passed }.map(\.title)
        )
    }
}

struct CapabilitiesApprovalInboxPanel: View {
    @Environment(AppModel.self) private var appModel

    private var readState: CapabilitiesApprovalInboxPresentation.ReadState {
        CapabilitiesApprovalInboxPresentation.readState(
            approvalCount: appModel.approvals.count,
            refresh: appModel.panelRefreshStatus[.capabilities]
        )
    }

    var body: some View {
        NativePanel(title: "Approval Inbox", systemImage: "checkmark.shield") {
            switch readState {
            case .loading:
                Label("Loading approval requests…", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .empty:
                Text("No approval requests yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Label(
                    "Approval inbox is unavailable. Refresh Capabilities before relying on an empty queue.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("capabilities.approvals.unavailable")
            case .stale:
                Label(
                    "Showing the last loaded approval requests; the latest refresh failed.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                approvalRows
            case .available:
                approvalRows
            }

            if let outcome = appModel.capabilitiesApprovalInboxOutcome {
                Label(outcome.visibleMessage, systemImage: outcomeIcon(outcome))
                    .font(.caption)
                    .foregroundStyle(outcomeColor(outcome))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("capabilities.approvals.outcome")
            }
        }
    }

    @ViewBuilder
    private var approvalRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(appModel.approvals.prefix(8)) { approval in
                HStack(alignment: .top, spacing: 10) {
                    CapabilityDetailRow(
                        title: approval.title,
                        detail: approval.reason ?? approval.action,
                        status: approval.status.lowercased() == "pending" ? approval.risk : approval.status,
                        systemImage: "checkmark.shield"
                    )
                    Spacer()
                    if approval.status.lowercased() == "pending" {
                        Button("Approve", systemImage: "checkmark") {
                            Task { await appModel.resolveCapabilitiesApprovalInbox(approval, decision: "approved") }
                        }
                        .disabled(appModel.isResolvingApproval(id: approval.id))
                        .accessibilityIdentifier("capabilities.approvals.approve.\(approval.id)")
                        .accessibilityHint(appModel.isResolvingApproval(id: approval.id)
                            ? "This approval is already being decided."
                            : "Approve this request once.")
                        Button("Deny", systemImage: "xmark") {
                            Task { await appModel.resolveCapabilitiesApprovalInbox(approval, decision: "denied") }
                        }
                        .disabled(appModel.isResolvingApproval(id: approval.id))
                        .accessibilityIdentifier("capabilities.approvals.deny.\(approval.id)")
                        .accessibilityHint(appModel.isResolvingApproval(id: approval.id)
                            ? "This approval is already being decided."
                            : "Deny this request once.")
                    }
                }
                if approval.id != appModel.approvals.prefix(8).last?.id {
                    Divider()
                }
            }
        }
    }

    private func outcomeIcon(_ outcome: CapabilitiesApprovalInboxResolution) -> String {
        switch CapabilitiesApprovalInboxPresentation.outcomeTone(outcome) {
        case "success": "checkmark.circle.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "xmark.octagon.fill"
        }
    }

    private func outcomeColor(_ outcome: CapabilitiesApprovalInboxResolution) -> Color {
        switch CapabilitiesApprovalInboxPresentation.outcomeTone(outcome) {
        case "success": .green
        case "warning": .orange
        default: .red
        }
    }
}

struct CapabilityMetricCard: View {
    var title: String
    var value: String
    var detail: String
    var systemImage: String

    var body: some View {
        NativePanel(title: nil, systemImage: nil) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 88)
        }
    }
}

struct CapabilityRow: View {
    var capability: CapabilityRecord
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text((capability.name ?? capability.id).withoutStaleNextGenPhaseCopy)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(1)
                Spacer()
                StatusBadge(text: (capability.status ?? "ready").uppercased(), status: capability.status ?? "ok")
            }
            HStack(spacing: 6) {
                InfoPill(text: capability.kind, systemImage: "tag")
                if let risk = capability.riskClass, !risk.isEmpty {
                    InfoPill(text: risk, systemImage: "lock.shield")
                }
                if let useCount = capability.useCount, useCount > 0 {
                    InfoPill(text: "\(useCount) uses", systemImage: "clock.arrow.circlepath")
                }
            }
            if !compact, let description = capability.description, !description.isEmpty {
                Text(description.withoutStaleNextGenPhaseCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .textSelection(.enabled)
    }
}

struct NextGenPhaseRow: View {
    var phase: NextGenPhase
    var isRunning: Bool
    var runProbe: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CapabilityDetailRow(
                title: phase.displayName,
                detail: phase.displayDetail,
                status: phase.displayStatus,
                systemImage: phase.ready == true ? "checkmark.circle" : "circle.dashed"
            )
            Spacer()
            // L3#6: a phase's primaryDryRunActionId comes from the catalog data
            // file and may name an id the read-only executor has no case for.
            // Render the probe only when an executor backs it.
            if let actionId = phase.primaryDryRunActionId, NativeClient.isNextGenActionBacked(actionId) {
                Button("Probe", systemImage: "play.circle") {
                    runProbe(actionId)
                }
                .disabled(isRunning)
            } else {
                StatusBadge(text: "NO PROBE", status: "warn")
            }
        }
    }

}

struct SkillMemoryGraphPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var graphQuery = "memory workflow capability"

    var body: some View {
        NativePanel(title: "Skill Memory Graph", systemImage: "point.3.filled.connected.trianglepath.dotted") {
            if let graph = appModel.agentGraph {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    CapabilityMetricCard(title: "Nodes", value: "\(graph.summary.nodes)", detail: "memories, runs, Desk tasks, capabilities", systemImage: "circle.grid.cross")
                    CapabilityMetricCard(title: "Edges", value: "\(graph.summary.edges)", detail: "produced and used links", systemImage: "point.3.connected.trianglepath.dotted")
                    CapabilityMetricCard(title: "Capabilities", value: "\(graph.summary.capabilities ?? 0)", detail: "indexed objects", systemImage: "shippingbox")
                }

                if let error = appModel.graphLoadError {
                    Label(
                        "Graph refresh failed; retained data may be stale: \(error)",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                HStack {
                    if let status = appModel.graphStatus {
                        StatusBadge(text: status.status.uppercased(), status: status.status)
                        InfoPill(text: "\(status.entityCount ?? appModel.graphEntities.count) entities", systemImage: "circle.grid.cross")
                    }
                    TextField("Search graph", text: $graphQuery)
                        .textFieldStyle(.roundedBorder)
                    Button("Search", systemImage: "magnifyingglass") {
                        Task { await appModel.searchGraph(graphQuery) }
                    }
                    Button("Refresh", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await appModel.refreshGraph() }
                    }
                }

                if graph.nodes.isEmpty {
                    Text("The checked graph is empty. New retained memories and linked capability activity will appear here when indexed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !appModel.graphSearchResults.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(appModel.graphSearchResults.prefix(8)) { result in
                            CapabilityDetailRow(
                                title: result.node.label ?? result.id,
                                detail: result.explanation ?? "Score \(String(format: "%.2f", result.score))",
                                status: result.node.status ?? "ok",
                                systemImage: "point.3.connected.trianglepath.dotted"
                            )
                        }
                    }
                }

                if !appModel.graphEntities.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appModel.graphEntities.prefix(5)) { entity in
                            CapabilityDetailRow(
                                title: entity.name,
                                detail: "\(entity.mentions ?? 0) mention(s) · confidence \(String(format: "%.2f", entity.confidence ?? 0))",
                                status: entity.kind ?? "ok",
                                systemImage: "circle.grid.cross"
                            )
                        }
                    }
                }
            } else if let error = appModel.graphLoadError {
                NativeEmptyState(
                    title: "Skill Memory Graph unavailable",
                    detail: "The graph could not be read: \(error)",
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Refresh Graph",
                    actionImage: "arrow.clockwise",
                    action: { Task { await appModel.refreshGraph() } }
                )
            } else {
                NativeEmptyState(
                    title: "Skill Memory Graph not loaded",
                    detail: "Refresh to read the current graph. This is not an empty-graph result.",
                    systemImage: "clock",
                    actionTitle: "Refresh Graph",
                    actionImage: "arrow.clockwise",
                    action: { Task { await appModel.refreshGraph() } }
                )
            }
        }
    }
}

struct WorkflowBuilderPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var workflowName = ""
    @State private var workflowObjective = "Dry-run the selected workflow and record receipts."
    @State private var creatingWorkflow = false
    @State private var creationError: String?
    @State private var lifecycleAction: WorkflowLifecycleAction?
    @State private var lifecycleNotice: WorkflowLifecycleButtonPresentation.Notice?

    var body: some View {
        NativePanel(title: "Workflow Builder", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
            TextField("New workflow name", text: $workflowName)
                .textFieldStyle(.roundedBorder)
                .disabled(creatingWorkflow)

            HStack(spacing: 8) {
                Button("Create Workflow", systemImage: "plus.circle") {
                    Task { await createWorkflow() }
                }
                .disabled(creatingWorkflow || workflowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if creatingWorkflow {
                    ProgressView().controlSize(.small)
                    Text("Saving and verifying…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("Creates a reviewable planning workflow. It will not run until you choose Run below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let creationError {
                Label(creationError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
            TextField("Workflow objective", text: $workflowObjective, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            if appModel.workflows.isEmpty {
                Text("No workflows loaded. Create one or refresh Capabilities to confirm the current registry.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(appModel.workflows) { workflow in
                        WorkflowRow(workflow: workflow) {
                            Task { await appModel.runWorkflow(workflow, objective: workflowObjective) }
                        }
                        if workflow.id != appModel.workflows.last?.id {
                            Divider()
                        }
                    }
                }
            }

            if let latest = appModel.workflowRuns.first {
                let approvalDecision = latest.approvalId.flatMap { approvalID in
                    appModel.approvals.first(where: { $0.id == approvalID })?.decision
                }
                let controls = latest.controlAvailability(approvalDecision: approvalDecision)
                let resumeEligibility = WorkflowLifecycleButtonPresentation.eligibility(
                    action: .resume,
                    run: latest,
                    approvalDecision: approvalDecision,
                    isPerforming: lifecycleAction != nil
                )
                let cancelEligibility = WorkflowLifecycleButtonPresentation.eligibility(
                    action: .cancel,
                    run: latest,
                    approvalDecision: approvalDecision,
                    isPerforming: lifecycleAction != nil
                )
                let rollbackEligibility = WorkflowLifecycleButtonPresentation.eligibility(
                    action: .rollback,
                    run: latest,
                    approvalDecision: approvalDecision,
                    isPerforming: lifecycleAction != nil
                )
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 10) {
                        CapabilityDetailRow(
                            title: latest.workflowName ?? latest.workflowId,
                            detail: "\(latest.mode ?? "run") · \(latest.steps.count) step(s)",
                            status: latest.status,
                            systemImage: "play.rectangle"
                        )
                        Spacer()
                        Button(lifecycleAction == .resume ? "Resuming…" : "Resume", systemImage: "play.fill") {
                            Task { await performLifecycle(.resume, run: latest) }
                        }
                        .disabled(!resumeEligibility.isEligible)
                        .help(resumeEligibility.detail)
                        Button(lifecycleAction == .cancel ? "Canceling…" : "Cancel", systemImage: "xmark.circle") {
                            Task { await performLifecycle(.cancel, run: latest) }
                        }
                        .disabled(!cancelEligibility.isEligible)
                        .help(cancelEligibility.detail)
                        Button(lifecycleAction == .rollback ? "Rolling Back…" : "Rollback", systemImage: "arrow.uturn.backward.circle") {
                            Task { await performLifecycle(.rollback, run: latest) }
                        }
                        .disabled(!rollbackEligibility.isEligible)
                        .help(rollbackEligibility.detail)
                    }
                    if let lifecycleNotice {
                        Label(lifecycleNotice.detail, systemImage: lifecycleNotice.status == "failed" ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(NativeAgentTheme.statusColor(lifecycleNotice.status))
                    } else if lifecycleAction != nil {
                        Label("Updating workflow lifecycle…", systemImage: "hourglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if latest.status.lowercased() == "waiting_approval", !controls.resume.isEligible {
                        Label(controls.resume.detail, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if !controls.resume.isEligible,
                              !controls.cancel.isEligible,
                              !controls.rollback.isEligible {
                        Label(controls.rollback.detail, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    @MainActor
    private func createWorkflow() async {
        creatingWorkflow = true
        defer { creatingWorkflow = false }
        do {
            _ = try await appModel.createWorkflow(named: workflowName)
            workflowName = ""
            creationError = nil
        } catch {
            creationError = "Could not create workflow: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func performLifecycle(_ action: WorkflowLifecycleAction, run: WorkflowRun) async {
        guard lifecycleAction == nil else { return }
        lifecycleAction = action
        lifecycleNotice = nil
        defer { lifecycleAction = nil }

        let outcome: WorkflowLifecycleActionOutcome
        switch action {
        case .resume:
            outcome = await appModel.resumeWorkflowRun(run)
        case .cancel:
            outcome = await appModel.cancelWorkflowRun(run)
        case .rollback:
            outcome = await appModel.rollbackWorkflowRun(run)
        }
        lifecycleNotice = WorkflowLifecycleButtonPresentation.notice(for: action, outcome: outcome)
    }
}

struct WorkflowRow: View {
    var workflow: WorkflowRecord
    var run: () -> Void

    var body: some View {
        let availability = workflow.executionAvailability
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(workflow.name)
                    .font(.headline)
                Spacer()
                StatusBadge(text: (workflow.status ?? "active").uppercased(), status: workflow.status ?? "ok")
                if availability.isRunnable {
                    Button("Run", systemImage: "play.circle", action: run)
                } else {
                    StatusBadge(
                        text: (workflow.status?.lowercased() == "template" ? "TEMPLATE" : "UNAVAILABLE"),
                        status: "warn"
                    )
                    .help(availability.detail)
                }
            }
            if !availability.isRunnable {
                Label("Run unavailable — \(availability.detail)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let description = workflow.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                InfoPill(text: "\(workflow.steps.count) steps", systemImage: "list.number")
                if let trigger = workflow.trigger, !trigger.isEmpty {
                    InfoPill(text: trigger, systemImage: "bolt")
                }
            }
        }
        .textSelection(.enabled)
    }
}

struct CatalogRow: View {
    var item: CapabilityCatalogItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.installed == true ? "checkmark.seal.fill" : "square.grid.3x3")
                .foregroundStyle(NativeAgentTheme.statusColor(item.installed == true ? "ok" : "warn"))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name)
                        .font(.headline)
                    Spacer()
                    StatusBadge(text: (item.status ?? "available").uppercased(), status: item.installed == true ? "ok" : "warn")
                }
                Text(item.description ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let kind = item.kind {
                        InfoPill(text: kind, systemImage: "tag")
                    }
                    if let risk = item.riskClass {
                        InfoPill(text: risk, systemImage: "lock.shield")
                    }
                    Spacer()
                    Text(item.installed == true ? "Installed by a verified pack" : "Catalog metadata")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
    }
}

struct MCPServerRow: View {
    var server: MCPServerRecord
    var load: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CapabilityDetailRow(
                title: server.name,
                detail: "\(server.transport ?? "stdio") · \(server.endpoint?.isEmpty == false ? server.endpoint! : server.command ?? "not configured") · \(server.toolCount ?? 0) tool(s)",
                status: server.healthStatus ?? server.status ?? "warn",
                systemImage: "externaldrive.connected.to.line.below"
            )
            Spacer()
            Button("Load", systemImage: "arrow.down.circle", action: load)
        }
    }
}

struct CapabilityDetailRow: View {
    var title: String
    var detail: String
    var status: String
    var systemImage: String
    // 2026-06-07 ui-taste-sweep #83: when caller has the raw key/value
    // pairs (e.g. NextGenReceipt), pass them here. Row gets a DisclosureGroup
    // labeled "Show details" that reveals each pair on its own line. Nil =
    // legacy callers (no disclosure rendered, identical to old behavior).
    var rawPairs: [(String, String)]? = nil

    // SwiftUI's DisclosureGroup tracks expansion internally when not bound;
    // we no longer need explicit @State now that the label is static.

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(NativeAgentTheme.statusColor(status))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title.withoutStaleNextGenPhaseCopy)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    StatusBadge(text: status.uppercased(), status: status)
                }
                let trimmedDetail = detail.withoutStaleNextGenPhaseCopy
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedDetail.isEmpty {
                    Text(trimmedDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let pairs = rawPairs, !pairs.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(pair.0)
                                        .font(.caption2.monospaced().weight(.medium))
                                        .foregroundStyle(.tertiary)
                                    Text(pair.1.isEmpty ? "—" : pair.1)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.top, 2)
                    } label: {
                        // Stable label — SwiftUI's chevron carries the
                        // expanded/collapsed affordance (gpt-5.5 polish note).
                        Text("Details")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .accentColor(.secondary)
                }
            }
        }
        .textSelection(.enabled)
    }
}
