import NativeAgentShared
import EngineRuntime
import Foundation
import SystemOps
import ToolRegistry
import SwiftUI
import TrustCenter
import ApprovalInbox
import MemoryV2
import Research
// Blueprint: | `CapabilitiesView.swift` | `CapabilitiesView`: capability inventory, catalogs and saved workflows |

/// Counts and availability come from the same engine owners on every route.
enum CapabilitiesRefreshPresentation {
    struct SummaryTiles: Equatable {
        let approvals: String
        let notice: String?
    }

    @MainActor
    static func summary(trust: TrustFacade, approvals: ApprovalsFacade) -> SummaryTiles {
        let unavailable = trust.catalogRefresh == nil
            ? "Capability summary is loading."
            : trust.catalogRefresh?.isStale != true && approvals.refreshErrorText == nil ? nil
            : "Some of this could not be loaded; anything marked — is missing, not zero."
        return SummaryTiles(
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

struct CapabilitiesView: View {
    @Environment(AppModel.self) var appModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Which of the page's tabs this is (CapabilitiesRailPage).
    private let mode: CapabilityWorkspaceMode
    var researchObjective: String { appModel.editDraft("capability-research/new", seed: "Find current best practices for lightweight autonomous agent capability systems.") }
    @State var researchLabMessage: CapabilitiesResearchLabPresentation.Message?
    @State var isRunningResearchLab = false
    private var catalogSourceName: String { appModel.editDraft("capability-catalog/new/name", seed: "Local NativeAgent Catalog") }
    private var catalogSourceURL: String { appModel.editDraft("capability-catalog/new/url", seed: "") }
    @State private var catalogSourceOutcome: AppModel.CapabilityCatalogSourceSaveOutcome?
    @State var showAllNativeActions = false
    @State private var capabilitySearch = ""
    // Everything a stranger has no business reading — hardening, the research
    // lab and the gauntlet — behind one fold at the bottom.
    @AppStorage("capabilitiesShowDeveloper") var showDeveloperTools = false

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

    /// The header stays nil until refresh and reports failed counts without claiming zero.
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
        let tiles = CapabilitiesRefreshPresentation.summary(trust: appModel.engine.trust, approvals: appModel.engine.approvals)
        // A dash means "not read", never zero.
        return VStack(alignment: .leading, spacing: 8) {
            AliveFlow(spacing: 18, lineSpacing: 6) {
                // Capabilities and workflows are in the header line already.
                ForEach([
                    (tiles.approvals, "approval", "approvals"),
                ], id: \.2) { value, one, many in
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

    private var overview: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            AdvancedSection(title: "Capabilities I can use") {
                let summary = appModel.engine.trust.capabilitySummary
                let failure = appModel.engine.trust.capabilitySummaryError
                if let summary, failure == nil, !summary.records.isEmpty {
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
                } else if summary != nil, failure == nil {
                    AdvancedEmptyState(
                        title: "Nothing listed yet",
                        detail: "Nothing is listed yet."
                    )
                } else {
                    AdvancedEmptyState(
                        title: "The capability list is unavailable",
                        detail: failure ?? "The capability list has not loaded. Refresh to try again."
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

    private var build: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            WorkflowBuilderPanel()

            AdvancedSection(title: "Capability list") {
                HStack(spacing: 8) {
                    if let capability = appModel.engine.trust.capabilitySummary?.records.first {
                        Button("Check trust") {
                            Task { await appModel.evaluateCapabilityTrust(capability) }
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                    AdvancedMeta("\(appModel.engine.trust.capabilityPackInstalls.count) installed")
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

                if !appModel.engine.trust.capabilityCatalogSources.isEmpty || appModel.engine.trust.capabilityNetwork != nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                        AdvancedStat(title: "Sources", value: "\(appModel.engine.trust.capabilityCatalogSources.count)", detail: appModel.engine.trust.capabilityCatalogSources.first?.status ?? "not checked")
                        AdvancedStat(title: "Trusted", value: "\(appModel.engine.trust.capabilityNetwork?.summary?.trusted ?? 0)", detail: "\(appModel.engine.trust.capabilityNetwork?.summary?.review ?? 0) to review")
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

// Saved workflow definitions do not execute; live work runs through workshop/executions.
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
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer()
                AdvancedStatusWord(status: status)
            }
            let trimmedDetail = detail
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDetail.isEmpty {
                Text(trimmedDetail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
