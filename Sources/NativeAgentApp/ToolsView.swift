import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import ChatOrchestration
import NativeAgentCore
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

struct ToolsView: View {
    @Environment(AppModel.self) private var appModel
    /// Production loads the authoritative runtime catalog when this surface
    /// becomes visible. Hermetic presentation hosts can hold a supplied state
    /// still, without accidentally reading the user's live data root.
    var loadsOnAppear = true

    /// Posts the existing openCommandRouteRequest notification (handled
    /// in ContentView.swift at line 272+) instead of mutating a child-
    /// view @SceneStorage. Keeps navigation centralized through
    /// ContentView.openCommandRoute() which also expands Advanced /
    /// sets focus correctly. (gpt-5.5 review NEEDS_FIX 3)
    private func jumpToTrust() {
        ToolsNavigation.openTrustCenter()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = ToolsRefreshPresentation.message(for: appModel.toolsRefreshState) {
                    Text(message)
                        .font(ShellType.label)
                        .foregroundStyle(
                            appModel.toolsRefreshState == .refreshed
                                ? NativeAgentShell.calm
                                : NativeAgentShell.trouble
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                catalogContent(ChatToolCatalogPresentation.catalogState(
                    catalog: appModel.chatToolCatalog,
                    loadFailed: appModel.chatToolCatalogLoadFailed,
                    loadError: appModel.chatToolCatalogLoadError
                ))

                if !appModel.tools.isEmpty {
                    AuthoredToolsSection(tools: appModel.tools, appModel: appModel)
                }

                if !appModel.toolOperationStatusReceipts.isEmpty {
                    ToolsSection(title: "Recent tool activity") {
                        ForEach(appModel.toolOperationStatusReceipts) { receipt in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(receipt.outcome == .succeeded ? "Completed" : "Needs attention")
                                    .font(ShellType.labelSemibold)
                                    .foregroundStyle(
                                        receipt.outcome == .succeeded
                                            ? NativeAgentShell.calm
                                            : NativeAgentShell.trouble
                                    )
                                Text(receipt.message)
                                    .font(ShellType.label)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            Button {
                Task { await appModel.refreshToolsFromToolbar() }
            } label: {
                if appModel.isRefreshingTools {
                    Label("Refreshing Tools", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(appModel.isRefreshingTools)
            .accessibilityIdentifier("tools.refresh")
        }
        .task {
            guard loadsOnAppear else { return }
            await appModel.refreshForSidebarItem(.tools)
        }
    }

    @ViewBuilder
    private func catalogContent(_ catalogState: ChatToolCatalogPresentation.CatalogState) -> some View {
        switch ToolsCatalogSurfacePresentation.state(for: catalogState) {
        case .loading(let presentation):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(presentation.detail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .padding(.vertical, 8)
        case let .empty(presentation), let .unavailable(presentation):
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text(presentation.detail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .catalog:
            switch catalogState {
            case let .available(catalog, bucketResult):
                ChatToolCatalogSection(
                    catalog: catalog,
                    bucketResult: bucketResult,
                    trustPolicy: appModel.trustPolicy,
                    trustRefreshStatus: appModel.panelRefreshStatus[.tools],
                    jumpToTrust: jumpToTrust
                )
            case let .stale(catalog, bucketResult, detail):
                ChatToolCatalogSection(
                    catalog: catalog,
                    bucketResult: bucketResult,
                    staleDetail: detail,
                    trustPolicy: appModel.trustPolicy,
                    trustRefreshStatus: appModel.panelRefreshStatus[.tools],
                    jumpToTrust: jumpToTrust
                )
            case .loading, .unavailable, .empty:
                EmptyView()
            }
        }
    }
}

enum ToolsNavigation {
    static func openTrustCenter(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: .openCommandRouteRequest, object: "trust")
    }
}

/// The toolbar reports the outcome of its scoped refresh rather than treating
/// a tap, or completion of only the side reads, as proof that the tool catalog
/// itself was refreshed.
enum ToolsRefreshPresentation {
    enum State: Equatable {
        case idle
        case refreshing
        case refreshed
        case partial
        case unavailable
        case alreadyRefreshing
    }

    static func completion(
        panelRefresh: AppModel.PanelRefreshStatus?,
        catalogLoadFailed: Bool,
        hasCatalog: Bool
    ) -> State {
        if catalogLoadFailed && !hasCatalog { return .unavailable }
        if catalogLoadFailed || panelRefresh?.isStale == true { return .partial }
        return panelRefresh == nil ? .unavailable : .refreshed
    }

    static func message(for state: State) -> String? {
        switch state {
        case .idle, .refreshing:
            return nil
        case .refreshed:
            return "Tools refreshed from current sources."
        case .partial:
            return "Some Tools data could not be refreshed; retained rows are marked stale."
        case .unavailable:
            return "The Tools catalog could not be refreshed. Check the displayed diagnostics and try again."
        case .alreadyRefreshing:
            return "Tools refresh is already in progress."
        }
    }

    static func systemImage(for state: State) -> String {
        switch state {
        case .refreshed: return "checkmark.circle.fill"
        case .partial, .unavailable: return "exclamationmark.triangle.fill"
        case .refreshing: return "arrow.triangle.2.circlepath"
        case .alreadyRefreshing: return "hourglass"
        case .idle: return "arrow.clockwise"
        }
    }
}

/// The visible catalog state, distinct from the toolbar receipt. A completed
/// `tools: []` runtime response is an honest empty state, whereas no catalog
/// after a failed read remains unavailable and no catalog before a read stays
/// loading. This is the exact projection ToolsView renders.
enum ToolsCatalogSurfacePresentation {
    struct Detail: Equatable {
        let title: String
        let detail: String
        let systemImage: String
    }

    enum State: Equatable {
        case loading(Detail)
        case empty(Detail)
        case unavailable(Detail)
        case catalog
    }

    static func state(for catalogState: ChatToolCatalogPresentation.CatalogState) -> State {
        switch catalogState {
        case .loading:
            return .loading(Detail(
                title: "Loading tool catalog",
                detail: "Loading tool catalog...",
                systemImage: "arrow.triangle.2.circlepath"
            ))
        case .empty:
            return .empty(Detail(
                title: "No Chat Tools Available",
                detail: "The live catalog completed successfully but returned no tools.",
                systemImage: "hammer"
            ))
        case let .unavailable(detail):
            return .unavailable(Detail(
                title: "Chat Tool Catalog Unavailable",
                detail: detail.map { "The live catalog could not be read: \($0). Tap Refresh to retry." }
                    ?? "The live catalog could not be read. Tap Refresh to retry — if it keeps failing, run Doctor for diagnostics.",
                systemImage: "exclamationmark.triangle"
            ))
        case .available, .stale:
            return .catalog
        }
    }
}

/// The catalog is the authority for which tools are currently mounted, while
/// the saved Trust policy explains the verdict behind it. Full Mac has no
/// timer (2026-09-10) - it is on until the person turns it off - so the only
/// states are on, off, and "the loaded catalog disagrees with Trust".
enum ToolsFullMacBannerPresentation {
    struct State: Equatable {
        let title: String
        let detail: String
        let status: String
        let systemImage: String
    }

    static func state(
        catalogFullMacActive: Bool,
        trustFullMacActive: Bool?,
        hasTrustRefreshAttempt: Bool,
        trustPolicyReadFailed: Bool
    ) -> State? {
        if catalogFullMacActive {
            guard let trustFullMacActive else { return nil }
            if trustFullMacActive { return nil }
            return State(
                title: "Full Mac status needs refresh",
                detail: "The current tool catalog still exposes Full Mac tools, but Trust now reports Full Mac off. Refresh Tools before relying on that catalog.",
                status: "warn",
                systemImage: "exclamationmark.triangle.fill"
            )
        }

        if trustPolicyReadFailed || trustFullMacActive == nil {
            return State(
                title: "Full Mac tools are locked",
                detail: hasTrustRefreshAttempt
                    ? "The Trust policy could not be refreshed, so NativeAgent cannot explain why Full Mac is locked. Check Trust Center and refresh Tools."
                    : "Trust status has not loaded yet. Full Mac tools stay locked until the current catalog is available.",
                status: "warn",
                systemImage: "lock.trianglebadge.exclamationmark"
            )
        }

        if trustFullMacActive == false {
            return State(
                title: "Full Mac is off",
                detail: "File, system, shell, and Mac-control tools are policy-locked. Turn Full Mac on in Trust Center to unlock.",
                status: "warn",
                systemImage: "lock.shield"
            )
        }
        return State(
            title: "Full Mac tools are locked",
            detail: "Trust reports Full Mac on, but the current tool catalog still has these tools locked. Refresh Tools; if it persists, save the Full Mac preset again in Trust Center.",
            status: "warn",
            systemImage: "lock.trianglebadge.exclamationmark"
        )
    }
}

// MARK: - Chat Tool Catalog

/// The catalog envelope is produced by the shared runtime. Keep the decisions
/// that turn that envelope into visible Settings state as values so they can be
/// exercised without a SwiftUI snapshot or a second copy of the classification
/// rules in tests.
enum ChatToolCatalogPresentation {
    enum ToolStatusBadgeTone: Equatable {
        case positive
        case neutral
        case warning
        case danger
    }

    /// The tool catalog is the live authority for this badge. A row with
    /// incomplete or unrecognised authority fields is not advertised as
    /// available: a stale or malformed receipt cannot establish usability.
    struct ToolStatusBadge: Equatable {
        let title: String
        let systemImage: String
        let tone: ToolStatusBadgeTone
    }

    struct Bucket: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        let tools: [ChatCatalogTool]
    }

    /// A catalog row cannot be rendered safely when it has no stable name or
    /// shares its SwiftUI identity with another row. Withhold the whole
    /// ambiguous identity group rather than silently showing an arbitrary one.
    struct BucketResult: Equatable {
        let buckets: [Bucket]
        let visibleToolCount: Int
        let withheldToolCount: Int
        let unclassifiedToolCount: Int

        var withheldNotice: String? {
            guard withheldToolCount > 0 else { return nil }
            return "\(withheldToolCount) malformed or duplicate catalog \(withheldToolCount == 1 ? "row was" : "rows were") withheld; refresh Tools after the runtime catalog is repaired."
        }

        var unclassifiedNotice: String? {
            guard unclassifiedToolCount > 0 else { return nil }
            return "\(unclassifiedToolCount) runtime \(unclassifiedToolCount == 1 ? "tool has" : "tools have") no reviewed dispatcher bucket. Their availability is shown, but their category needs runtime registration before it can be trusted."
        }
    }

    enum CatalogState: Equatable {
        case loading
        case unavailable(detail: String?)
        case empty
        case available(catalog: ChatToolCatalogSnapshot, buckets: BucketResult)
        case stale(catalog: ChatToolCatalogSnapshot, buckets: BucketResult, detail: String?)
    }

    static func catalogState(
        catalog: ChatToolCatalogSnapshot?,
        loadFailed: Bool,
        loadError: String?
    ) -> CatalogState {
        let detail = boundedDetail(loadError)
        guard let catalog else {
            return loadFailed ? .unavailable(detail: detail) : .loading
        }
        let result = bucketResult(for: catalog)
        if loadFailed {
            return .stale(catalog: catalog, buckets: result, detail: detail)
        }
        return catalog.tools.isEmpty
            ? .empty
            : .available(catalog: catalog, buckets: result)
    }

    static func buckets(for catalog: ChatToolCatalogSnapshot) -> [Bucket] {
        bucketResult(for: catalog).buckets
    }

    static func bucketResult(for catalog: ChatToolCatalogSnapshot) -> BucketResult {
        var toolsByBucket = Dictionary(uniqueKeysWithValues: ChatToolCatalogBucket.allCases.map {
            ($0.rawValue, [ChatCatalogTool]())
        })

        let normalizedNames = catalog.tools.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nameCounts = Dictionary(normalizedNames.map { ($0, 1) }, uniquingKeysWith: { $0 + $1 })
        let validTools = zip(catalog.tools, normalizedNames).compactMap { tool, normalizedName -> ChatCatalogTool? in
            guard !normalizedName.isEmpty, nameCounts[normalizedName] == 1 else { return nil }
            return tool
        }

        for tool in validTools {
            let bucket = bucket(for: tool, in: catalog)
            toolsByBucket[bucket.rawValue, default: []].append(tool)
        }

        let buckets: [Bucket] = ChatToolCatalogBucket.allCases.compactMap { definition -> Bucket? in
            guard let tools = toolsByBucket[definition.rawValue], !tools.isEmpty else { return nil }
            return Bucket(
                id: definition.rawValue,
                title: definition.title,
                icon: definition.systemImage,
                tools: tools.sorted { lhs, rhs in
                    let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    return comparison == .orderedSame ? lhs.name < rhs.name : comparison == .orderedAscending
                }
            )
        }
        return BucketResult(
            buckets: buckets,
            visibleToolCount: validTools.count,
            withheldToolCount: catalog.tools.count - validTools.count,
            unclassifiedToolCount: toolsByBucket[ChatToolCatalogBucket.unclassified.rawValue]?.count ?? 0
        )
    }

    private static func bucket(for tool: ChatCatalogTool, in catalog: ChatToolCatalogSnapshot) -> ChatToolCatalogBucket {
        if let rawBucket = tool.catalogBucket,
           let bucket = ChatToolCatalogBucket(rawValue: rawBucket) {
            if bucket == .core, catalog.currentlyLoaded.contains(tool.name) {
                return .alwaysOn
            }
            return bucket
        }
        if tool.name.hasPrefix("mcp__") { return .mcp }
        if let bucket = SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: tool.name) {
            if bucket == .core, catalog.currentlyLoaded.contains(tool.name) {
                return .alwaysOn
            }
            return bucket
        }
        if let bucket = AppChatToolDispatcher.catalogBucket(forRegisteredToolNamed: tool.name) {
            if bucket == .core, catalog.currentlyLoaded.contains(tool.name) {
                return .alwaysOn
            }
            return bucket
        }
        return .unclassified
    }

    private static func boundedDetail(_ value: String?, limit: Int = 240) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    static func toolStatusBadge(for tool: ChatCatalogTool, in catalog: ChatToolCatalogSnapshot) -> ToolStatusBadge {
        let name = normalized(tool.name)
        let policyLockedNames = Set((catalog.builderPolicyLocked + catalog.macAppPolicyLocked).map { normalized($0) })
        if !name.isEmpty, policyLockedNames.contains(name) {
            return ToolStatusBadge(title: "policy-locked", systemImage: "lock", tone: .warning)
        }
        if tool.availableNow == false {
            return ToolStatusBadge(title: "unavailable", systemImage: "minus.circle", tone: .neutral)
        }

        let autonomy = normalized(tool.effectiveAutonomy)
        if autonomy == "blocked" {
            return ToolStatusBadge(title: "blocked", systemImage: "hand.raised", tone: .danger)
        }
        guard tool.availableNow == true, ["", "auto", "confirm"].contains(autonomy) else {
            return unavailableStatusBadge()
        }
        if autonomy == "confirm" {
            return ToolStatusBadge(title: "approval", systemImage: "checkmark.shield", tone: .warning)
        }

        let loadState = normalized(tool.loadState)
        let currentlyLoaded = Set(catalog.currentlyLoaded.map { normalized($0) })
        if loadState == "loaded" || (!name.isEmpty && currentlyLoaded.contains(name)) {
            return ToolStatusBadge(title: "active", systemImage: "circle.fill", tone: .positive)
        }
        if loadState == "discovery_only" {
            return ToolStatusBadge(title: "on demand", systemImage: "bolt.circle", tone: .neutral)
        }
        guard loadState.isEmpty else { return unavailableStatusBadge() }
        return ToolStatusBadge(title: "available", systemImage: "checkmark.circle", tone: .neutral)
    }

    /// Compatibility for existing presentation-only readers. New rendering
    /// uses `toolStatusBadge(for:in:)` so its text, icon, and tone stay bound
    /// to one authoritative classification.
    static func status(for tool: ChatCatalogTool, in catalog: ChatToolCatalogSnapshot) -> String {
        toolStatusBadge(for: tool, in: catalog).title
    }

    private static func unavailableStatusBadge() -> ToolStatusBadge {
        ToolStatusBadge(title: "status unavailable", systemImage: "questionmark.circle", tone: .warning)
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

}

/// Local presentation only: search never reclassifies or grants a tool. Keep
/// normal disclosure choices separate so clearing a search restores the page.
struct ChatToolCatalogSearchState {
    private(set) var query = ""
    private var expandedBuckets: Set<String> = []
    private var collapsedSearchBuckets: Set<String> = []

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    mutating func setQuery(_ value: String) {
        guard query != value else { return }
        query = value
        collapsedSearchBuckets.removeAll()
    }

    func isExpanded(_ bucketID: String) -> Bool {
        isSearching ? !collapsedSearchBuckets.contains(bucketID) : expandedBuckets.contains(bucketID)
    }

    mutating func setExpanded(_ expanded: Bool, bucketID: String) {
        if isSearching {
            if expanded { collapsedSearchBuckets.remove(bucketID) }
            else { collapsedSearchBuckets.insert(bucketID) }
        } else {
            if expanded { expandedBuckets.insert(bucketID) }
            else { expandedBuckets.remove(bucketID) }
        }
    }

    func filteredBuckets(_ buckets: [ChatToolCatalogPresentation.Bucket]) -> [ChatToolCatalogPresentation.Bucket] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return buckets }
        return buckets.compactMap { bucket in
            let tools = bucket.tools.filter { tool in
                terms.allSatisfy { term in
                    tool.name.localizedStandardContains(term) || tool.description.localizedStandardContains(term)
                }
            }
            guard !tools.isEmpty else { return nil }
            return .init(id: bucket.id, title: bucket.title, icon: bucket.icon, tools: tools)
        }
    }
}

struct ChatToolDetailsButton: View {
    let toolName: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text(isExpanded ? "Hide details" : "Show details")
        }
        .buttonStyle(.borderless)
        .font(ShellType.label)
        .foregroundStyle(NativeAgentShell.secondary)
        .accessibilityLabel("\(isExpanded ? "Hide" : "Show") details for \(toolName)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .help("Show or hide the full tool description and catalog metadata. This does not run the tool.")
    }
}

private struct ChatToolCatalogSection: View {
    let catalog: ChatToolCatalogSnapshot
    let bucketResult: ChatToolCatalogPresentation.BucketResult
    var staleDetail: String? = nil
    let trustPolicy: TrustPolicy?
    let trustRefreshStatus: AppModel.PanelRefreshStatus?
    let jumpToTrust: () -> Void

    @State private var expanded: Set<String> = []
    @State private var searchState = ChatToolCatalogSearchState()

    var body: some View {
        let filteredBuckets = searchState.filteredBuckets(bucketResult.buckets)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Chat tool catalog")
                    .font(ShellType.labelSemibold)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(NativeAgentShell.secondary)
                Spacer(minLength: 8)
                Text("\(bucketResult.visibleToolCount) usable of \(catalog.tools.count) tools · permission \(catalog.permissionLevel.isEmpty ? "unknown" : catalog.permissionLevel)")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }

            if !bucketResult.buckets.isEmpty {
                HStack(spacing: 8) {
                    TextField("Search tool names or descriptions", text: Binding(
                        get: { searchState.query },
                        set: { searchState.setQuery($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(ShellType.label)
                    .frame(maxWidth: 420)
                    .accessibilityLabel("Search chat tool catalog")
                    if searchState.isSearching {
                        Button("Clear search") {
                            searchState.setQuery("")
                        }
                        .buttonStyle(.borderless)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .help("Clear tool search")
                        .accessibilityLabel("Clear tool search")
                        Text("\(filteredBuckets.reduce(0) { $0 + $1.tools.count }) matching tools")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }

            if let staleDetail {
                catalogWarning(
                    "Showing the last loaded catalog. The latest refresh failed\(staleDetail.isEmpty ? "." : ": \(staleDetail)")"
                )
            }

            if let withheldNotice = bucketResult.withheldNotice {
                catalogWarning(withheldNotice)
            }

            if let unclassifiedNotice = bucketResult.unclassifiedNotice {
                catalogWarning(unclassifiedNotice)
            }

            if let banner = ToolsFullMacBannerPresentation.state(
                catalogFullMacActive: catalog.fullMacActive,
                trustFullMacActive: trustPolicy.map { AppModel.fullMacGrantIsActive($0) },
                hasTrustRefreshAttempt: trustRefreshStatus != nil,
                trustPolicyReadFailed: trustRefreshStatus?.failedEndpoints.contains("trust policy") == true
            ) {
                fullMacBanner(banner)
            }

            if bucketResult.buckets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No usable chat tool rows")
                        .font(ShellType.bodySemibold)
                        .foregroundStyle(NativeAgentShell.text)
                    Text(catalog.tools.isEmpty
                        ? "The last catalog that loaded contained no tools. Refresh to get a current one."
                        : "The live catalog returned \(catalog.tools.count) row\(catalog.tools.count == 1 ? "" : "s"), but none had a unique, non-empty tool identity.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if filteredBuckets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No tools match this search")
                        .font(ShellType.bodySemibold)
                        .foregroundStyle(NativeAgentShell.text)
                    Text("Try another name or description, or clear the search to browse the loaded catalog.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Clear search") { searchState.setQuery("") }
                        .buttonStyle(.borderless)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(filteredBuckets) { bucket in
                    bucketView(bucket)
                }
            }
        }
    }

    private func catalogWarning(_ detail: String) -> some View {
        Text(detail)
            .font(ShellType.label)
            .foregroundStyle(NativeAgentShell.trouble)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fullMacBanner(_ banner: ToolsFullMacBannerPresentation.State) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(banner.title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(bannerColor(banner.status))
            Text(banner.detail)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open the Trust page") { jumpToTrust() }
                .buttonStyle(.link)
                .font(ShellType.label)
        }
        .padding(16)
        .settingsCardSurface()
    }

    private func bannerColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "ok", "active", "ready": NativeAgentShell.calm
        case "warn", "warning", "fail", "failed", "error": NativeAgentShell.trouble
        default: NativeAgentShell.text
        }
    }

    @ViewBuilder
    private func bucketView(_ bucket: ChatToolCatalogPresentation.Bucket) -> some View {
        // A bare fold: the chevron, the words, the count. The plate the rows
        // used to sit on and the rules between them are gone.
        ToolsFold(isExpanded: bucketExpandedBinding(bucket.id)) {
            HStack(spacing: 8) {
                Text(bucket.title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text("\(bucket.tools.count)")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(bucket.tools) { tool in
                    toolRow(tool)
                }
            }
            .padding(16)
            .settingsCardSurface()
        }
    }

    private func bucketExpandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { searchState.isExpanded(id) },
            set: { isExpanded in
                searchState.setExpanded(isExpanded, bucketID: id)
            }
        )
    }

    @ViewBuilder
    private func toolRow(_ tool: ChatCatalogTool) -> some View {
        let isExpanded = expanded.contains(tool.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // A tool name IS a code, so it takes `ShellType.code`.
                Text(tool.name)
                    .font(ShellType.code)
                    .foregroundStyle(NativeAgentShell.text)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                statusBadge(for: tool)
                ChatToolDetailsButton(toolName: tool.name, isExpanded: Binding(
                    get: { expanded.contains(tool.id) },
                    set: { value in
                        if value { expanded.insert(tool.id) } else { expanded.remove(tool.id) }
                    }
                ))
            }
            Text(tool.description)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: isExpanded)
                .textSelection(.enabled)
            if isExpanded {
                if let params = tool.parametersPreview {
                    Text("Takes \(params)")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .textSelection(.enabled)
                }
                if let via = tool.dispatchableVia {
                    Text("Runs through \(via)")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(minHeight: 48, alignment: .top)
    }

    @ViewBuilder
    private func statusBadge(for tool: ChatCatalogTool) -> some View {
        let badge = ChatToolCatalogPresentation.toolStatusBadge(for: tool, in: catalog)
        Text(badge.title)
            .font(ShellType.captionSemibold)
            .foregroundStyle(ToolsStatusTone.color(badge.tone))
            .accessibilityLabel(badge.title)
    }
}

/// Values consumed by the mounted authored-tool controls.
enum AuthoredToolPresentation {
    enum Action: Equatable {
        case approve
        case autoRun
        case quarantine
    }

    struct ActionControl: Equatable {
        let action: Action
        let title: String
        let isEnabled: Bool
        let accessibilityIdentifier: String?
        let help: String?
        let refusal: String?
    }

    static func autoRunTitle(_ tool: ToolRecord) -> String {
        tool.autoRun == true ? "Disable Auto-run" : "Enable Auto-run"
    }

    static func canQuarantine(_ tool: ToolRecord) -> Bool { tool.status != "quarantined" }

    /// Authored rows are durable registry records, not live dispatcher
    /// receipts. Keep their distinct lifecycle labels explicit rather than
    /// borrowing the catalog's availability wording.
    static func statusBadge(for tool: ToolRecord) -> ChatToolCatalogPresentation.ToolStatusBadge {
        let status = (tool.status ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch status {
        case "active":
            return .init(title: "active", systemImage: "circle.fill", tone: .positive)
        case "proposed":
            return .init(title: "proposed", systemImage: "clock", tone: .warning)
        case "quarantined":
            return .init(title: "quarantined", systemImage: "exclamationmark.triangle", tone: .danger)
        default:
            return .init(title: "status unavailable", systemImage: "questionmark.circle", tone: .warning)
        }
    }

    /// Every authored-tool row is derived from this one action catalog. The
    /// executor repeats its own gates, but the control cannot claim a mutation
    /// is available when its durable precondition is already absent.
    static func actionCatalog(for tool: ToolRecord) -> [ActionControl] {
        var controls: [ActionControl] = []
        if tool.status != "active" {
            let approval = ToolApprovalPresentation.control(for: tool)
            controls.append(ActionControl(
                action: .approve,
                title: "Approve",
                isEnabled: approval.isEnabled,
                accessibilityIdentifier: approval.accessibilityIdentifier,
                help: approval.help,
                refusal: approval.refusal
            ))
        }
        controls.append(ActionControl(
            action: .autoRun,
            title: autoRunTitle(tool),
            isEnabled: tool.status == "active",
            accessibilityIdentifier: nil,
            help: tool.status == "active"
                ? "Change whether this active tool may run automatically."
                : "Activate this tool before changing auto-run.",
            refusal: nil
        ))
        controls.append(ActionControl(
            action: .quarantine,
            title: "Quarantine",
            isEnabled: canQuarantine(tool),
            accessibilityIdentifier: nil,
            help: canQuarantine(tool)
                ? "Quarantine this tool and remove it from the active registry."
                : "This tool is already quarantined.",
            refusal: nil
        ))
        return controls
    }
}

// MARK: - Authored Tools

private struct AuthoredToolsSection: View {
    let tools: [ToolRecord]
    let appModel: AppModel
    @State private var quarantineCandidate: ToolRecord?

    var body: some View {
        ToolsSection(title: "Tools the agent wrote") {
            ForEach(tools) { tool in
                authoredRow(tool)
            }
        }
        .confirmationDialog(
            "Quarantine \(quarantineCandidate?.name ?? "tool")?",
            isPresented: Binding(
                get: { quarantineCandidate != nil },
                set: { if !$0 { quarantineCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Quarantine", role: .destructive) {
                guard let tool = quarantineCandidate else { return }
                quarantineCandidate = nil
                Task { await appModel.quarantineTool(tool) }
            }
            Button("Cancel", role: .cancel) { quarantineCandidate = nil }
        } message: {
            Text("The tool will stop being available to \(appModel.agentDisplayName) until it is reviewed and reactivated.")
        }
    }

    @ViewBuilder
    private func authoredRow(_ tool: ToolRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(tool.name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 8)
                let badge = AuthoredToolPresentation.statusBadge(for: tool)
                Text(badge.title)
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(ToolsStatusTone.color(badge.tone))
            }
            Text(tool.description)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !tool.triggers.isEmpty {
                Text(tool.triggers.joined(separator: ", "))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if tool.autoCreated == true {
                    Text("Written by the agent")
                }
                if tool.autoRun == true {
                    Text("Runs on its own")
                }
                Text(tool.validationStatus ?? "untested")
                Text("Used \(tool.useCount ?? 0) times")
            }
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.tertiary)

            if let permissions = tool.permissions, !permissions.isEmpty {
                Text("Permissions: \(permissions.joined(separator: ", "))")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let errors = tool.validationErrors, !errors.isEmpty {
                Text(errors.joined(separator: " "))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let path = tool.activePath ?? tool.proposalPath ?? tool.quarantinePath {
                Text(UserDisplayFormatters.tildifyPath(path))
                    .font(ShellType.code)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                let actionCatalog = AuthoredToolPresentation.actionCatalog(for: tool)
                if let approval = actionCatalog.first(where: { $0.action == .approve }) {
                    Button(approval.title) {
                        Task { await appModel.promoteTool(tool, userRequested: true) }
                    }
                    .disabled(!approval.isEnabled)
                    .accessibilityIdentifier(approval.accessibilityIdentifier ?? "")
                    .help(approval.help ?? "")
                    if let refusal = approval.refusal {
                        Text(refusal)
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                }
                let autoRun = actionCatalog.first(where: { $0.action == .autoRun })!
                Button(autoRun.title) {
                    Task { await appModel.setToolAutoRun(tool, autoRun: !(tool.autoRun ?? false)) }
                }
                .disabled(!autoRun.isEnabled)
                let quarantine = actionCatalog.first(where: { $0.action == .quarantine })!
                Button(quarantine.title) {
                    quarantineCandidate = tool
                }
                .disabled(!quarantine.isEnabled)
            }
            .buttonStyle(.borderless)
            .font(ShellType.label)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Page kit (2026-09-03 Advanced refinement)

/// One tone table for both tool lists. Four states, three room colours.
private enum ToolsStatusTone {
    static func color(_ tone: ChatToolCatalogPresentation.ToolStatusBadgeTone) -> Color {
        switch tone {
        case .positive: NativeAgentShell.calm
        case .neutral: NativeAgentShell.secondary
        case .warning, .danger: NativeAgentShell.trouble
        }
    }
}

/// One section of the page: the eyebrow the Advanced list uses, and the rows
/// under it on one card.
private typealias ToolsSection<Content: View> = SettingsCardSection<Content>

/// A bare fold: a chevron, the words, one gesture, and Reduce Motion honoured.
private struct ToolsFold<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: Label
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(NativeAgentMotion.respecting(ShellFoldMotion.open, reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(ShellType.captionSemibold)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    label
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .transition(ShellFoldMotion.transition(reduceMotion: reduceMotion))
            }
        }
    }
}
