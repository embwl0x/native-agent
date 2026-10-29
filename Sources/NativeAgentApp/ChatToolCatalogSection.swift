import SwiftUI
import AppKit
import ChatToolRuntime
import ToolRegistry
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter

// Blueprint: | `ChatToolCatalogSection.swift` | Mounted tool catalog classification/search, approval and Full Mac presentation, detail controls and shared status tones |
/// Compare the authoritative mounted catalog with saved Trust; Full Mac stays on until disabled.
enum ToolsFullMacBannerPresentation {
    struct State: Equatable {
        let title: String
        let detail: String
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
                detail: "Full Mac tools are still loaded, but Trust now says Full Mac is off. Refresh Tools before relying on this list."
            )
        }
        if trustPolicyReadFailed || trustFullMacActive == nil {
            return State(
                title: "Full Mac tools are locked",
                detail: hasTrustRefreshAttempt
                    ? "The Trust settings could not be refreshed, so the app cannot explain why Full Mac is locked. Check Trust Center and refresh Tools."
                    : "Trust has not loaded yet. Full Mac tools stay locked until it does."
            )
        }
        if trustFullMacActive == false {
            return State(
                title: "Full Mac is off",
                detail: "File, system, shell, and Mac-control tools are locked. Turn Full Mac on in Trust Center to unlock them."
            )
        }
        return State(
            title: "Full Mac tools are locked",
            detail: "Trust says Full Mac is on, but these tools are still locked. Refresh Tools; if that does not help, save the Full Mac preset again in Trust Center."
        )
    }
}
/// The authored-tools row is a projection of the same promotion boundary the
/// action repeats. Keeping its enabled state and refusal copy here prevents a
/// mounted SwiftUI control from becoming a second, untested eligibility rule.
enum ToolApprovalPresentation {
    struct Control: Equatable {
        let accessibilityIdentifier: String
        let isEnabled: Bool
        let help: String
        let refusal: String?
    }
    static func review(for tool: ToolRecord) -> [String: JSONValue]? {
        tool.keepReview
    }
    static func control(for tool: ToolRecord, keepRefusal: String?) -> Control {
        let refusal = (tool.candidateDigest ?? tool.codeFingerprint) != nil && review(for: tool) == nil
            ? "Version unavailable. Refresh Tools before approving." : keepRefusal
        return Control(
            accessibilityIdentifier: "tools.authored.approve.\(tool.id)",
            isEnabled: refusal == nil,
            help: refusal ?? "Keep this rehearsed version and turn it on.",
            refusal: refusal
        )
    }
}
/// Local catalog grouping and search; tool status belongs to the engine.
enum ChatToolCatalogPresentation {
    struct Bucket: Identifiable, Equatable {
        let id: String
        let title: String
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
            return "\(withheldToolCount) broken or duplicate \(withheldToolCount == 1 ? "row was" : "rows were") left out; refresh Tools once the list is fixed."
        }
        var unclassifiedNotice: String? {
            guard unclassifiedToolCount > 0 else { return nil }
            return "\(unclassifiedToolCount) \(unclassifiedToolCount == 1 ? "tool has" : "tools have") not been sorted into a group yet. Whether they are available is shown, but their group has not been checked."
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
        authored: [ToolRecord],
        loadFailed: Bool,
        loadError: String?
    ) -> CatalogState {
        let detail = boundedDetail(loadError)
        guard let catalog else {
            return loadFailed ? .unavailable(detail: detail) : .loading
        }
        let result = bucketResult(for: catalog, authored: authored)
        if loadFailed {
            return .stale(catalog: catalog, buckets: result, detail: detail)
        }
        return result.visibleToolCount == 0 && result.withheldToolCount == 0
            ? .empty
            : .available(catalog: catalog, buckets: result)
    }
    static func bucketResult(for catalog: ChatToolCatalogSnapshot, authored: [ToolRecord]) -> BucketResult {
        var toolsByBucket = Dictionary(uniqueKeysWithValues: ChatToolCatalogBucket.allCases.map {
            ($0.rawValue, [ChatCatalogTool]())
        })
        let authoredIDs = Set(authored.map(\.id))
        let runtimeTools = catalog.tools.filter { !authoredIDs.contains($0.name) }
        let normalizedNames = runtimeTools.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nameCounts = Dictionary(normalizedNames.map { ($0, 1) }, uniquingKeysWith: { $0 + $1 })
        let validTools = zip(runtimeTools, normalizedNames).compactMap { tool, normalizedName -> ChatCatalogTool? in
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
                tools: tools.sorted { lhs, rhs in
                    let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    return comparison == .orderedSame ? lhs.name < rhs.name : comparison == .orderedAscending
                }
            )
        }
        return BucketResult(
            buckets: buckets,
            visibleToolCount: validTools.count,
            withheldToolCount: runtimeTools.count - validTools.count,
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
        if let bucket = SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: tool.name) {
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
            return .init(id: bucket.id, title: bucket.title, tools: tools)
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
        .help("Show or hide the full description and details for this tool. This does not run it.")
    }
}
internal struct ChatToolCatalogSection: View {
    let catalog: ChatToolCatalogSnapshot
    let bucketResult: ChatToolCatalogPresentation.BucketResult
    var staleDetail: String? = nil
    let trustPolicy: TrustPolicy?
    let trustRefreshStatus: AppModel.PanelRefreshStatus?
    let jumpToTrust: () -> Void
    @State private var expanded: Set<String> = []
    @State private var searchState = ChatToolCatalogSearchState()
    @State private var filteredBuckets: [ChatToolCatalogPresentation.Bucket] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Chat tools")
                    .font(ShellType.labelSemibold)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(NativeAgentShell.secondary)
                Spacer(minLength: 8)
                // "Chat tools" are the chat catalog, not the Capabilities
                // records; say so in the count itself. Rows withheld for a
                // blank or duplicate name are the only difference.
                Text(bucketResult.visibleToolCount == catalog.tools.count
                    ? "\(catalog.tools.count) chat tools"
                    : "\(bucketResult.visibleToolCount) of \(catalog.tools.count) chat tools shown")
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
                    .accessibilityLabel("Search the chat tools")
                    if searchState.isSearching {
                        Button("Clear search") {
                            searchState.setQuery("")
                        }
                        .buttonStyle(.borderless)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .help("Clear the search")
                        .accessibilityLabel("Clear the search")
                        Text("\(filteredBuckets.reduce(0) { $0 + $1.tools.count }) matching tools")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let staleDetail {
                catalogWarning(
                    "Showing the tools that loaded last time. The latest refresh failed\(staleDetail.isEmpty ? "." : ": \(staleDetail)")"
                )
            }
            if let withheldNotice = bucketResult.withheldNotice {
                catalogWarning(withheldNotice)
            }
            if let unclassifiedNotice = bucketResult.unclassifiedNotice {
                Text(unclassifiedNotice)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let banner = ToolsFullMacBannerPresentation.state(
                catalogFullMacActive: catalog.fullMacActive,
                trustFullMacActive: trustPolicy.map { TrustAccessModeCapabilityCatalog.fullMacGrantIsActive($0) },
                hasTrustRefreshAttempt: trustRefreshStatus != nil,
                trustPolicyReadFailed: trustRefreshStatus?.failedEndpoints.contains("trust policy") == true
            ) {
                fullMacBanner(banner)
            }
            if bucketResult.buckets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No tools to show")
                        .font(ShellType.bodySemibold)
                        .foregroundStyle(NativeAgentShell.text)
                    Text(catalog.tools.isEmpty
                        ? "The last list that loaded had no tools in it. Refresh to get a current one."
                        : "The list came back with \(catalog.tools.count) row\(catalog.tools.count == 1 ? "" : "s"), but none of them had a usable name.")
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
                    Text("Try another name or description, or clear the search to browse every tool.")
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
        .onChange(of: bucketResult.buckets, initial: true) { _, buckets in
            filteredBuckets = searchState.filteredBuckets(buckets)
        }
        .onChange(of: searchState.query) { _, _ in
            filteredBuckets = searchState.filteredBuckets(bucketResult.buckets)
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
                .foregroundStyle(NativeAgentShell.trouble)
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
    @ViewBuilder
    private func bucketView(_ bucket: ChatToolCatalogPresentation.Bucket) -> some View {
        DisclosureGroup(isExpanded: bucketExpandedBinding(bucket.id).animation(
            NativeAgentMotion.respecting(NativeAgentMotion.arrive, reduceMotion: reduceMotion)
        )) {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(bucket.tools) { tool in
                    toolRow(tool)
                }
            }
            .padding(16)
            .settingsCardSurface()
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text(bucket.title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text("\(bucket.tools.count)")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
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
            Text(tool.description.isEmpty ? "An additional tool I can use for your tasks." : tool.description)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: isExpanded)
                .textSelection(.enabled)
            if isExpanded {
                if let params = tool.parametersPreview {
                    Text("Takes \(params)")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .textSelection(.enabled)
                }
                if let via = tool.dispatchableVia {
                    Text("Runs through \(via)")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(minHeight: 48, alignment: .top)
    }
    @ViewBuilder
    private func statusBadge(for tool: ChatCatalogTool) -> some View {
        let badge = catalog.status(for: tool)
        Text(badge.title)
            .font(ShellType.captionSemibold)
            .foregroundStyle(ToolsStatusTone.color(badge.tone))
            .accessibilityLabel(badge.title)
    }
}
/// One tone table for both tool lists. Four states, three room colours.
internal enum ToolsStatusTone {
    static func color(_ tone: ToolCatalogStatus.Tone) -> Color {
        switch tone {
        case .positive: NativeAgentShell.calm
        case .neutral: NativeAgentShell.secondary
        case .warning, .danger: NativeAgentShell.trouble
        }
    }
}
