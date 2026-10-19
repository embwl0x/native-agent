import SwiftUI
import NativeAgentShared
import AppToolRuntime
import PersistenceCore
import MCPDispatcher

// MCP server control hub — the page that surfaces all connected MCP servers,
// their tools, and the most recent tool call. The backend
// (AppModel + MCPDispatcher) is fully wired; this view is purely the SwiftUI
// layer. Dressed 2026-09-03 in the Advanced page kit: the room's sheet under
// eyebrow-and-card sections (`MCPSection` / `MCPCard` / `MCPNote` at the foot
// of this file), type from `ShellType`, colour from `NativeAgentShell`. No
// List, no Section chrome, no material of its own — the frame owns the room.
struct MCPHubView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                serversSection
                toolsSection
                resourcesSection
                recentCallSection
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("MCP Hub")
        .pageActions {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await appModel.refreshForSidebarItem(.mcp) }
            }
            .accessibilityLabel("Refresh MCP connections")
        }
        .onChange(of: appModel.mcpTools, initial: true) { _, _ in refreshDrafts() }
    }

    private func refreshDrafts() {
        guard let server = appModel.selectedMCPServerId else { return }
        for tool in appModel.mcpTools {
            let key = MCPHubToolDraft.subject(server: server, tool: tool.name)
            let held: MCPHubToolDraft? = appModel.editDraft(key, seed: Optional<MCPHubToolDraft>.none)
            if inputSchemaContainsSecret(tool.inputSchema) || (held != nil && held?.schema != tool.inputSchema) {
                appModel.clearEditDraft(key)
            }
        }
    }

    // MARK: - Servers

    private var serversSection: some View {
        AdvancedSection(title: "Servers", card: .bare) {
            switch MCPHubCollectionPresentation.resolve(
                recordCount: appModel.mcpServers.count,
                endpoint: "mcp servers",
                refresh: appModel.panelRefreshStatus[.mcp]
            ) {
            case .loading:
                MCPNote("Reading the tool servers I can call.")
                    .accessibilityIdentifier("mcp.servers.loading")
            case .unavailable:
                MCPNote("The servers are unavailable. Refresh MCP Hub to retry.", tone: NativeAgentShell.trouble)
                    .accessibilityIdentifier("mcp.servers.unavailable")
            case .empty:
                MCPNote("No tool servers yet. A server added to the MCP config appears here.")
                    .accessibilityIdentifier("mcp.servers.empty")
            case .stale:
                MCPNote("Showing the last loaded servers; the latest refresh failed.", tone: NativeAgentShell.trouble)
                    .accessibilityIdentifier("mcp.servers.stale")
                serverRows
            case .available:
                serverRows
            }
        }
    }

    private var serverRows: some View {
        AliveGroupCard(lazy: true) {
            ForEach(appModel.mcpServers) { server in
                serverRow(server)
            }
        }
    }

    private func serverRow(_ server: MCPServer) -> some View {
        let isSelected = server.id == appModel.selectedMCPServerId
        let toolCount = MCPHubServerCountPresentation.resolve(
            isSelected: isSelected,
            isCurrent: appModel.mcpToolReadState == .current,
            visibleCount: appModel.mcpTools.count,
            reportedCount: server.toolCount
        )
        let resourceCount = MCPHubServerCountPresentation.resolve(
            isSelected: isSelected,
            isCurrent: appModel.mcpResourceReadState == .current,
            visibleCount: appModel.mcpResources.count,
            reportedCount: server.resourceCount
        )
        return MCPCard(selected: isSelected) {
            HStack(alignment: .center, spacing: 8) {
                Text(server.name)
                    .font(ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 8)
                ConnectorsStatusPill(text: MCPHubWords.health(server.healthStatus), tone: healthColor(server.healthStatus))
            }

            HStack(spacing: 12) {
                Text(toolCount.label(noun: "tool"))
                    .help(toolCount.help)
                Text(resourceCount.label(noun: "resource"))
                    .help(resourceCount.help)
                Text(server.transport)
                if !server.riskClass.isEmpty {
                    Text("Risk: \(server.riskClass)")
                }
                Spacer(minLength: 0)
            }
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)

            if !server.endpoint.isEmpty {
                Text(server.endpoint)
                    .font(ShellType.caption.monospaced())
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let command = server.command, !command.isEmpty {
                Text(command)
                    .font(ShellType.caption.monospaced())
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Button("Warm") {
                    Task { await appModel.runMCPCommand(.warm, server: server) }
                }
                .accessibilityIdentifier("mcp.server.warm.\(server.id)")
                Button("Restart") {
                    Task { await appModel.runMCPCommand(.restart, server: server) }
                }
                .accessibilityIdentifier("mcp.server.restart.\(server.id)")
                Button("Refresh") {
                    Task { await appModel.runMCPCommand(.refresh, server: server) }
                }
                Spacer(minLength: 0)
                if !server.updatedAt.isEmpty {
                    Text(server.updatedAt)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }
            .buttonStyle(.bordered)
        }
        .contentShape(Rectangle())
        .naInteractive(radius: TodayMetrics.cardRadius)
        .onTapGesture {
            appModel.selectedMCPServerId = server.id
            Task { await appModel.loadMCPDetails(server) }
        }
    }

    private func healthColor(_ status: String?) -> Color {
        // gpt-5.5 review: added "error" as a red state. The app
        // surfaces both "fail" and "error" depending on which adapter and
        // codepath produced the health row; without this, an "error" state
        // showed as muted secondary instead of red.
        switch status {
        case "ok": return NativeAgentShell.calm
        case "fail", "error", "needs_setup": return NativeAgentShell.trouble
        default: return NativeAgentShell.secondary
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        AdvancedSection(title: "Tools — \(appModel.selectedMCPServer?.name ?? "no server selected")", card: .bare) {
            let notice = MCPHubInventoryPresentation.notice(
                state: appModel.mcpToolReadState,
                selectedServerName: appModel.selectedMCPServer?.name,
                toolCount: appModel.mcpTools.count
            )
            if !notice.text.isEmpty {
                MCPNote(
                    notice.text,
                    tone: notice.isFailure ? NativeAgentShell.trouble : NativeAgentShell.secondary
                )
                .accessibilityIdentifier(notice.isFailure ? "mcp.tools.unavailable" : "mcp.tools.empty-or-loading")
            }
            if notice.showsTools, !appModel.mcpTools.isEmpty {
                AliveGroupCard(lazy: true) {
                    ForEach(appModel.mcpTools) { tool in
                        if let server = appModel.selectedMCPServerId {
                            let subject = MCPHubToolDraft.subject(server: server, tool: tool.name)
                            MCPHubToolRow(tool: tool, subject: subject, form: inputSchemaContainsSecret(tool.inputSchema)
                                ? MCPHubToolDraft(schema: tool.inputSchema)
                                : appModel.editDraft(subject, seed: MCPHubToolDraft(schema: tool.inputSchema)))
                                .id(subject)
                        }
                    }
                }
                .id(appModel.selectedMCPServerId)
            }
        }
    }

    // MARK: - Resources

    private var resourcesSection: some View {
        AdvancedSection(title: "Resources — \(appModel.selectedMCPServer?.name ?? "no server selected")", card: .bare) {
            switch appModel.mcpResourceReadState {
            case .notLoaded, .loading:
                MCPNote(MCPHubResourcesPresentation.notice(
                    state: appModel.mcpResourceReadState,
                    resourceCount: appModel.mcpResources.count
                )!.text)
            case .unavailable(let detail):
                MCPNote(MCPHubResourcesPresentation.notice(
                    state: .unavailable(detail),
                    resourceCount: appModel.mcpResources.count
                )!.text, tone: NativeAgentShell.trouble)
            case .current where appModel.mcpResources.isEmpty:
                MCPNote(MCPHubResourcesPresentation.notice(
                    state: .current,
                    resourceCount: appModel.mcpResources.count
                )!.text)
            case .current:
                AliveGroupCard(lazy: true) {
                ForEach(appModel.mcpResources) { resource in
                    MCPCard {
                        Text(resource.name ?? resource.uri)
                            .font(resource.name == nil
                                  ? ShellType.labelSemibold.monospaced()
                                  : ShellType.bodySemibold)
                            .foregroundStyle(NativeAgentShell.text)
                        if resource.name != nil {
                            Text(resource.uri)
                                .font(ShellType.caption.monospaced())
                                .foregroundStyle(NativeAgentShell.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let mime = resource.mimeType, !mime.isEmpty {
                            Text(mime)
                                .font(ShellType.caption)
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                    }
                }
                }
            }
        }
    }

    // MARK: - Recent call

    private var recentCallSection: some View {
        AdvancedSection(title: "Recent call", card: .bare) {
            switch appModel.mcpRecentCallState {
            case .durable(let call):
                recentCallRow(call, provenance: "Recorded in Activity; available after relaunch.")
            case .partial(let call, let rejectedRows):
                if let call {
                    recentCallRow(
                        call,
                        provenance: "Recorded in Activity; \(rejectedRows) malformed receipt row\(rejectedRows == 1 ? "" : "s") ignored."
                    )
                } else {
                    MCPNote(
                        "The call history is partly unreadable (\(rejectedRows) malformed receipt row\(rejectedRows == 1 ? "" : "s")).",
                        tone: NativeAgentShell.trouble
                    )
                }
            case .sessionOnly(let call):
                recentCallRow(
                    call,
                    provenance: "This app session only — durable Activity evidence was not recorded."
                )
            case .latestAttemptFailed(let detail):
                MCPNote(
                    "The latest call failed this app session. \(detail) No durable call receipt was recorded.",
                    tone: NativeAgentShell.trouble
                )
            case .unavailable(let detail):
                MCPNote("The recorded call history is unavailable: \(detail)", tone: NativeAgentShell.trouble)
            case .notLoaded:
                MCPNote("Reading the recorded call history.")
            case .absent:
                MCPNote("No tool call recorded yet. Running a tool above records one here.")
            }
        }
    }

    @ViewBuilder
    private func recentCallRow(_ call: MCPCallResult, provenance: String) -> some View {
        AliveGroupCard {
        MCPCard {
            HStack(alignment: .center, spacing: 8) {
                Text("\(call.serverId) · \(call.toolName)")
                    .font(ShellType.labelSemibold.monospaced())
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 8)
                ConnectorsStatusPill(text: MCPHubWords.callStatus(call.status), tone: callStatusColor(call.status))
            }
            HStack(spacing: 12) {
                if let createdAt = call.createdAt, !createdAt.isEmpty {
                    Text(createdAt)
                }
                if let duration = call.durationSeconds {
                    Text("\(duration, specifier: "%.2f")s")
                }
                Spacer(minLength: 0)
            }
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)
            Text(provenance)
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let preview = call.resultPreview, !preview.isEmpty {
                Text(preview)
                    .font(ShellType.label.monospaced())
                    .foregroundStyle(NativeAgentShell.text)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .houseInset(in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
            }
            if call.resultTruncated == true {
                Text("Result preview truncated · \(call.resultByteCount ?? 0) bytes")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            if call.evidenceStatus == "recorded" {
                Text("Evidence recorded")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.calm)
            } else if call.evidenceStatus == "failed" {
                Text("Call completed; evidence write failed")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .help(call.evidenceError ?? "The MCP result could not be appended to Activity.")
            }
        }
        }
    }

    private func callStatusColor(_ status: String) -> Color {
        switch status {
        case "ok", "success": return NativeAgentShell.calm
        case "error", "failed": return NativeAgentShell.trouble
        default: return NativeAgentShell.secondary
        }
    }
}

// MARK: - The kit

/// Words for the states the daemon spells as slugs. A person never reads
/// `needs_setup` off this page.
private enum MCPHubWords {
    static func health(_ status: String?) -> String {
        switch status {
        case "ok": "Ready"
        case "fail", "error": "Not responding"
        case "needs_setup": "Needs setup"
        default: "Unknown"
        }
    }

    static func callStatus(_ status: String) -> String {
        switch status {
        case "ok", "success": "Succeeded"
        case "error", "failed": "Failed"
        default: "Unknown"
        }
    }
}

@Observable
private final class MCPHubToolDraft {
    static func subject(server: String, tool: String) -> String { "mcp/\(server)/\(tool)" }
    let schema: JSONValue?
    var isExpanded = false
    var values: [String: JSONValue] = [:]
    var parseErrors: [String: String] = [:]
    var draft = MCPInputSchemaForm.Draft()
    var validationError: String?
    var isRunning = false

    init(schema: JSONValue?) { self.schema = schema }
}

private struct MCPHubToolRow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tool: MCPTool
    let subject: String
    @State var form: MCPHubToolDraft

    private var heldDraft: MCPHubToolDraft? {
        inputSchemaContainsSecret(tool.inputSchema) ? nil : appModel.editDraft(subject, seed: Optional<MCPHubToolDraft>.none)
    }

    private var values: Binding<[String: JSONValue]> {
        Binding(get: { form.values }, set: { input in
            form.values = input
            form.validationError = nil
        })
    }

    var body: some View {
        MCPCard {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(ShellType.labelSemibold.monospaced())
                        .foregroundStyle(NativeAgentShell.text)
                    if let description = tool.description, !description.isEmpty {
                        Text(description)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button(form.isExpanded ? "Hide" : "Edit") {
                    withAnimation(
                        NativeAgentMotion.respecting(
                            NativeAgentMotion.spring,
                            reduceMotion: reduceMotion
                        )
                    ) {
                        form.isExpanded.toggle()
                    }
                }
                .buttonStyle(.bordered)
            }
            if form.isExpanded {
                MCPInputSchemaForm(schema: tool.inputSchema, values: values,
                                   jsonErrors: $form.parseErrors, draft: $form.draft,
                                   onEdit: {
                                       if !inputSchemaContainsSecret(tool.inputSchema) {
                                           appModel.setEditDraft(form, for: subject)
                                       }
                                   })
                    .id(ObjectIdentifier(form))
                HStack {
                    Button("Run") {
                        guard form.parseErrors.isEmpty else { return }
                        guard let server = appModel.selectedMCPServer else { return }
                        let input = values.wrappedValue
                        if let validation = MCPUIActions.validationMessage(
                            schema: tool.inputSchema,
                            values: input
                        ) {
                            form.validationError = validation
                            return
                        }
                        form.validationError = nil
                        form.isRunning = true
                        let submitted = form
                        Task {
                            defer { submitted.isRunning = false }
                            if await appModel.callMCPToolWithInput(server: server, tool: tool, input: input) {
                                guard form === submitted else { return }
                                let held: MCPHubToolDraft? = appModel.editDraft(subject, seed: Optional<MCPHubToolDraft>.none)
                                if held === submitted {
                                    appModel.clearEditDraft(subject)
                                }
                                form = MCPHubToolDraft(schema: tool.inputSchema)
                            }
                        }
                    }
                    .disabled(!form.parseErrors.isEmpty)
                    Spacer(minLength: 0)
                }
                .buttonStyle(.bordered)
                if let validation = form.validationError {
                    Text(validation)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("mcp.tool.input.invalid.\(tool.name)")
                }
            }
        }
        .disabled(form.isRunning)
        .contentShape(Rectangle())
        .onChange(of: tool.inputSchema) {
            form = MCPHubToolDraft(schema: tool.inputSchema)
        }
        .onChange(of: heldDraft.map(ObjectIdentifier.init)) {
            if let heldDraft {
                form = heldDraft
            } else {
                form = MCPHubToolDraft(schema: tool.inputSchema)
            }
        }
    }
}

/// One row of a list. Alive glass (2026-09-23): rows carry no chrome; the
/// list's `AliveGroupCard` is the card. A selected row takes the next fill
/// rung, reaching out into the card's row inset.
private struct MCPCard<Content: View>: View {
    var selected: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                    .fill(NativeAgentShell.softFill)
                    .padding(.horizontal, -12)
                    .padding(.vertical, -8)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A sentence on the sheet: a state, an empty list, or something that went
/// wrong. Plain text, no plate.
private struct MCPNote: View {
    let text: String
    var tone: Color = NativeAgentShell.secondary

    init(_ text: String, tone: Color = NativeAgentShell.secondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(ShellType.label)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}

/// Server metadata can lag the inventory already displayed below its row.
/// Only the selected server's successful read proves a current visible count.
enum MCPHubServerCountPresentation: Equatable {
    case loaded(Int)
    case reported(Int)
    case unknown

    static func resolve(
        isSelected: Bool,
        isCurrent: Bool,
        visibleCount: Int,
        reportedCount: Int?
    ) -> Self {
        if isSelected, isCurrent { return .loaded(visibleCount) }
        guard let reportedCount, reportedCount >= 0 else { return .unknown }
        return .reported(reportedCount)
    }

    func label(noun: String) -> String {
        switch self {
        case let .loaded(count):
            return "\(count) \(noun)\(count == 1 ? "" : "s")"
        case let .reported(count):
            return "\(count) \(noun)\(count == 1 ? "" : "s") reported"
        case .unknown:
            return "\(noun.capitalized) count unknown"
        }
    }

    var help: String {
        switch self {
        case .loaded:
            return "Count from this server's successfully loaded inventory."
        case .reported:
            return "Last reported by the server; its current inventory has not been verified here."
        case .unknown:
            return "This server has not reported a usable count, and its current inventory has not been loaded."
        }
    }
}
enum MCPHubResourceReadState: Equatable {
    case notLoaded
    case loading
    case current
    case unavailable(String)
}

/// Tool discovery is an independent server-scoped read. It cannot borrow the
/// resource state: one side of an MCP server can be healthy while the other
/// refuses or times out.
enum MCPHubToolReadState: Equatable {
    case notLoaded
    case loading
    case current
    case unavailable(String)
}

enum MCPHubCollectionPresentation {
    enum State: Equatable {
        case loading
        case empty
        case available
        case stale
        case unavailable
    }

    /// A panel refresh receipt is the only evidence that an empty array is a
    /// completed empty read. A failed endpoint retains earlier rows as stale,
    /// or remains unavailable when there are no prior rows to show.
    static func resolve(
        recordCount: Int,
        endpoint: String,
        refresh: AppModel.PanelRefreshStatus?
    ) -> State {
        let failed = refresh?.failedEndpoints.contains { candidate in
            candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(endpoint) == .orderedSame
        } ?? false
        if failed { return recordCount > 0 ? .stale : .unavailable }
        if recordCount > 0 { return .available }
        return refresh == nil ? .loading : .empty
    }
}

enum MCPHubInventoryPresentation {
    static func notice(
        state: MCPHubToolReadState,
        selectedServerName: String?,
        toolCount: Int
    ) -> (text: String, isFailure: Bool, showsTools: Bool) {
        switch state {
        case .notLoaded:
            return selectedServerName == nil
                ? ("Select an MCP server to inspect its tools.", false, false)
                : ("Tools have not loaded yet.", false, false)
        case .loading:
            return ("Loading tools…", false, false)
        case .unavailable(let detail):
            return ("Tools unavailable: \(detail)", true, toolCount > 0)
        case .current where toolCount == 0:
            return ("This server exposes no tools.", false, false)
        case .current:
            return ("", false, true)
        }
    }
}

enum MCPHubResourcesPresentation {
    static func notice(
        state: MCPHubResourceReadState,
        resourceCount: Int
    ) -> (text: String, isFailure: Bool)? {
        switch state {
        case .notLoaded, .loading:
            return ("Resources have not loaded yet.", false)
        case .unavailable(let detail):
            return ("Resources unavailable: \(detail)", true)
        case .current where resourceCount == 0:
            return ("No resources exposed by this server.", false)
        case .current:
            return nil
        }
    }
}

extension AppModel {
    @MainActor
    func refreshMCPHubRecentCall() {
        do {
            mcpRecentCallState = try MCPResultEvidence.readRecentCall(root: engine.dataRoot)
        } catch {
            mcpRecentCallState = .unavailable(UserFacingError.cause(error, action: "read the Activity receipt"))
        }
    }
}

@MainActor
extension AppModel {
    @MainActor
    func loadMCPDetails(_ server: MCPServer) async {
        // gpt-5.5 review: race-safe load. User can tap server A then tap
        // server B before A's fetch returns; without this check, A's late
        // result would overwrite B's. Tag the request with the target id
        // and only adopt the result if the user is still on it.
        selectedMCPServerId = server.id
        // Clear stale inventories immediately so the UI doesn't show the
        // previous server's tools under the new server's name during fetch.
        mcpTools = []
        mcpToolReadState = .loading
        mcpResources = []
        mcpResourceReadState = .loading
        let pendingId = server.id
        do {
            let toolsResult = try await MCPUIActions.listTools(serverId: pendingId, dispatcher: engine.tools.mcp)
            let resourcesResult = try await MCPUIActions.listResources(serverId: pendingId, dispatcher: engine.tools.mcp)
            // Late-arrival guard: discard if user has moved on.
            guard selectedMCPServerId == pendingId else { return }
            mcpTools = toolsResult
            mcpToolReadState = .current
            mcpResources = resourcesResult
            mcpResourceReadState = .current
            statusText = "Loaded MCP details for \(server.name)"
        } catch {
            guard selectedMCPServerId == pendingId else { return }
            mcpToolReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP tools"))
            mcpResources = []
            mcpResourceReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP resources"))
            setFailureStatus(error, action: "load MCP details")
        }
    }

    @discardableResult
    func runMCPCommand(_ command: MCPUIActions.ServerCommand, server: MCPServer) async -> JSONValue {
        let pendingId = server.id
        selectedMCPServerId = pendingId
        mcpTools = []
        mcpToolReadState = .loading
        mcpResources = []
        mcpResourceReadState = .loading
        let label = command == .refresh ? "MCP cache refresh" : "MCP \(command.rawValue)"
        do {
            let result = try await MCPUIActions.runServerCommand(command, server: server, dispatcher: engine.tools.mcp)
            if case .success(let sessions) = result.sessions { engine.tools.mcpSessions = sessions }
            if selectedMCPServerId == pendingId {
                mcpTools = result.tools
                mcpToolReadState = .current
                switch result.resources {
                case .success(let resources):
                    mcpResources = resources
                    mcpResourceReadState = .current
                case .failure(let error):
                    mcpResourceReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP resources"))
                }
            }
            disabledFeature = nil
            statusText = result.detail
            return result.toolResult
        } catch {
            if selectedMCPServerId == pendingId {
                mcpToolReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP tools"))
                mcpResourceReadState = .unavailable(UserFacingError.cause(error, action: "read the MCP resources"))
            }
            let line: String
            if AppModel.isNotImplemented(error as NSError) {
                line = AppModel.disabledBadge(for: label, error: error as NSError)
                disabledFeature = line
            } else {
                line = UserFacingError.message(error, action: command == .refresh ? "refresh the MCP cache" : "\(command.rawValue) the MCP server")
            }
            setFailureStatus(line, cause: error)
            return .object([
                "server_id": .string(pendingId), "command": .string(command.rawValue),
                "status": .string("failed"), "command_completed": .bool(false),
                "detail": .string(UserFacingError.forAgent(line, cause: error.localizedDescription))
            ])
        }
    }

    @MainActor
    func callMCPToolWithInput(server: MCPServer, tool: MCPTool, input: [String: JSONValue]) async -> Bool {
        if let validation = MCPUIActions.validationMessage(
            schema: tool.inputSchema,
            values: input
        ) {
            statusText = "MCP input refused: \(validation)"
            return false
        }
        do {
            let call = try await MCPUIActions.callMCPTool(
                serverId: server.id, toolName: tool.name, input: input,
                dataRoot: engine.dataRoot, authority: .runtime(dataRoot: engine.dataRoot)
            )
            latestMCPCall = call
            if latestMCPCall?.evidenceStatus == "recorded" {
                refreshMCPHubRecentCall()
            } else if let latestMCPCall {
                mcpRecentCallState = .sessionOnly(latestMCPCall)
            }
            statusText = "MCP \(tool.name): \(latestMCPCall?.status ?? "done")"
            await refreshAll()
            return call.status == "ok" || call.status == "success"
        } catch {
            mcpRecentCallState = .latestAttemptFailed(UserFacingError.cause(error, action: "call that MCP tool"))
            setFailureStatus(error, action: "call that MCP tool")
            return false
        }
    }

}
