import SwiftUI
import PersistenceCore

enum MCPHubConsentPresentation {
    enum State: Equatable {
        case loading
        case empty
        case available
        case stale
        case unavailable
    }

    static func resolve(
        consentCount: Int,
        refresh: AppModel.PanelRefreshStatus?
    ) -> State {
        let failedConsentRead = refresh?.failedEndpoints.contains { endpoint in
            endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mcp consent"
        } ?? false
        if failedConsentRead { return consentCount > 0 ? .stale : .unavailable }
        if consentCount > 0 { return .available }
        return refresh == nil ? .loading : .empty
    }
}

struct MCPHubConsentSection: View {
    @Environment(AppModel.self) private var appModel

    private var presentation: MCPHubConsentPresentation.State {
        MCPHubConsentPresentation.resolve(
            consentCount: appModel.mcpConsent.count,
            refresh: appModel.panelRefreshStatus[.mcp]
        )
    }

    var body: some View {
        MCPSection(label: "Consent log") {
            switch presentation {
            case .loading:
                MCPNote("Reading the consent decisions the agent has been given.")
            case .empty:
                MCPNote("No consent decisions yet. Granting a tool records one here.")
            case .unavailable:
                MCPNote(
                    "The consent ledger is unavailable. Refresh MCP Hub before relying on tool authority.",
                    tone: NativeAgentShell.trouble
                )
                .accessibilityIdentifier("mcp.consent.unavailable")
            case .stale:
                MCPNote(
                    "Showing the last loaded consent decisions.",
                    tone: NativeAgentShell.trouble
                )
                .accessibilityIdentifier("mcp.consent.stale")
                consentRows
            case .available:
                consentRows
            }
        }
    }

    @ViewBuilder
    private var consentRows: some View {
        ForEach(appModel.mcpConsent) { consent in
            MCPHubConsentRow(consent: consent)
        }
    }
}

private struct MCPHubConsentRow: View {
    @Environment(AppModel.self) private var appModel
    let consent: MCPConsentRecord

    var body: some View {
        MCPCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(consent.serverId ?? "Unknown server") · \(consent.toolName ?? "Unknown tool")")
                    .font(ShellType.labelSemibold.monospaced())
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 8)
                Text(MCPHubWords.consentStatus(consent.status))
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(color(consent.status))
            }
            HStack(spacing: 12) {
                if let granted = consent.grantedAt, !granted.isEmpty {
                    Text("Granted \(granted)")
                }
                if let revoked = consent.revokedAt, !revoked.isEmpty {
                    Text("Revoked \(revoked)")
                }
                if let risk = consent.risk, !risk.isEmpty {
                    Text("Risk: \(risk)")
                }
                Spacer(minLength: 0)
            }
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.tertiary)
            if (consent.status ?? "") == "granted" {
                HStack {
                    Spacer(minLength: 0)
                    Button("Revoke", role: .destructive) {
                        Task { await appModel.revokeMCPConsent(consent) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("mcp.consent.revoke.\(consent.id)")
                }
            }
        }
    }

    private func color(_ status: String?) -> Color {
        switch status {
        case "granted": NativeAgentShell.calm
        case "revoked", "denied": NativeAgentShell.trouble
        default: NativeAgentShell.tertiary
        }
    }
}

// MCP server control hub — the page that surfaces all connected MCP servers,
// their tools, the consent log, and the most recent tool call. The backend
// (AppModel + NativeClient) is fully wired; this view is purely the SwiftUI
// layer. Dressed 2026-09-03 in the Advanced page kit: the room's sheet under
// eyebrow-and-card sections (`MCPSection` / `MCPCard` / `MCPNote` at the foot
// of this file), type from `ShellType`, colour from `NativeAgentShell`. No
// List, no Section chrome, no material of its own — the frame owns the room.
struct MCPHubView: View {
    @Environment(AppModel.self) private var appModel

    // Per-tool form state. Keyed by (tool.name, schemaFingerprint) so a
    // schema change for a same-named tool invalidates the dict in lockstep
    // with the form's SwiftUI identity below. gpt-5.5 v2 review caught the
    // bug where the form reset its @State on schema change but the Run
    // button still read perToolValues[tool.name] holding old/wrong-typed args.
    @State private var perToolValues: [String: [String: JSONValue]] = [:]
    @State private var expandedTool: Set<String> = []
    @State private var inputValidationErrors: [String: String] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false

    private func valuesKey(for tool: MCPToolRecord) -> String {
        "\(tool.name)|\(schemaFingerprint(tool.inputSchema))"
    }

    private func binding(for tool: MCPToolRecord) -> Binding<[String: JSONValue]> {
        let key = valuesKey(for: tool)
        return Binding(
            get: { perToolValues[key] ?? [:] },
            set: {
                perToolValues[key] = $0
                inputValidationErrors.removeValue(forKey: key)
            }
        )
    }

    /// Stable in-process fingerprint of a JSON Schema, used as part of the
    /// form's SwiftUI identity so a schema change forces a fresh @State scope.
    /// Falls back to "nil" / "0" if the schema isn't serializable (shouldn't
    /// happen for well-formed JSONValue but we don't want to crash on it).
    private func schemaFingerprint(_ schema: JSONValue?) -> String {
        guard let schema = schema else { return "nil" }
        guard let data = try? schema.serializedData(pretty: false) else { return "unhashable" }
        // String.hashValue is per-process-seeded; that's fine — view identity
        // only matters within a process, and equal schemas in one process
        // always produce equal hashes.
        return "\(data.count)-\(String(data: data, encoding: .utf8)?.hashValue ?? 0)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                serversSection
                toolsSection
                resourcesSection
                consentSection
                recentCallSection
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The new shell's `ShellPageFrame` already insets the column; the
            // classic shell hands a page the bare pane, so the page keeps its
            // own margin there.
            .padding(.horizontal, classicShell ? 20 : 0)
            .padding(.top, classicShell ? 20 : 0)
        }
        .navigationTitle("MCP Hub")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await appModel.refreshForSidebarItem(.mcp) }
            }
        }
        // gpt-5.5 review: dropped the child .task here — ContentView's parent
        // task at line ~125 already fires refreshForSidebarItem(selection) on
        // appear and on selection change. The child .task was a redundant
        // refresh that widened the stale-result race window.
        .onChange(of: appModel.selectedMCPServerId) { _, _ in
            // gpt-5.5 review: per-tool form state is keyed only by tool.name;
            // switching servers can preserve stale expanded/values entries and
            // even submit one server's args against a same-named tool on the
            // other server. Clear both on server change. (state-lifecycle:
            // every add path needs a remove path.)
            perToolValues.removeAll()
            expandedTool.removeAll()
            inputValidationErrors.removeAll()
        }
    }

    // MARK: - Servers

    private var serversSection: some View {
        MCPSection(label: "Servers") {
            switch MCPHubCollectionPresentation.resolve(
                recordCount: appModel.mcpServers.count,
                endpoint: "mcp servers",
                refresh: appModel.panelRefreshStatus[.mcp]
            ) {
            case .loading:
                MCPNote("Reading the tool servers the agent can call.")
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

    @ViewBuilder
    private var serverRows: some View {
        ForEach(appModel.mcpServers) { server in
            serverRow(server)
        }
    }

    private func serverRow(_ server: MCPServerRecord) -> some View {
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(server.name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 8)
                Text(MCPHubWords.health(server.healthStatus))
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(healthColor(server.healthStatus))
            }

            HStack(spacing: 12) {
                Text(toolCount.label(noun: "tool"))
                    .help(toolCount.help)
                Text(resourceCount.label(noun: "resource"))
                    .help(resourceCount.help)
                Text(server.transport ?? "Transport unknown")
                if let risk = server.riskClass, !risk.isEmpty {
                    Text("Risk: \(risk)")
                }
                Spacer(minLength: 0)
            }
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)

            if let endpoint = server.endpoint, !endpoint.isEmpty {
                Text(endpoint)
                    .font(ShellType.caption.monospaced())
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let command = server.command, !command.isEmpty {
                Text(command)
                    .font(ShellType.caption.monospaced())
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Button("Warm") {
                    Task { await appModel.warmMCPServer(server) }
                }
                .accessibilityIdentifier("mcp.server.warm.\(server.id)")
                Button("Restart") {
                    Task { await appModel.restartMCPServer(server) }
                }
                .accessibilityIdentifier("mcp.server.restart.\(server.id)")
                Button("Refresh") {
                    // gpt-5.5 review: refreshMCPCache updates the cache on
                    // disk but doesn't reload the in-memory mcpTools /
                    // mcpResources arrays. User clicked Refresh and saw the
                    // UI not change. Chain a loadMCPDetails so the visible
                    // inventory reflects the refreshed cache.
                    Task {
                        await appModel.refreshMCPCache(server)
                        if appModel.selectedMCPServerId == server.id {
                            await appModel.loadMCPDetails(server)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let updated = server.updatedAt, !updated.isEmpty {
                    Text(updated)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
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
        // gpt-5.5 review: added "error" as a red state. The NativeClient
        // surfaces both "fail" and "error" depending on which adapter and
        // codepath produced the health row; without this, an "error" state
        // showed as muted secondary instead of red.
        switch status {
        case "ok": return NativeAgentShell.calm
        case "fail", "error", "needs_setup": return NativeAgentShell.trouble
        default: return NativeAgentShell.tertiary
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        MCPSection(label: "Tools — \(appModel.selectedMCPServer?.name ?? "no server selected")") {
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
            if notice.showsTools {
                ForEach(appModel.mcpTools) { tool in
                    toolRow(tool)
                }
            }
        }
    }

    private func toolRow(_ tool: MCPToolRecord) -> some View {
        let isExpanded = expandedTool.contains(tool.name)
        return MCPCard {
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
                Button(isExpanded ? "Hide" : "Edit") {
                    withAnimation(
                        NativeAgentMotion.respecting(
                            ShellFoldMotion.open,
                            reduceMotion: reduceMotion
                        )
                    ) {
                        if isExpanded { expandedTool.remove(tool.name) } else { expandedTool.insert(tool.name) }
                    }
                }
                .buttonStyle(.bordered)
            }
            if isExpanded {
                // gpt-5.5 review: pin form identity to (tool.name, schema-hash)
                // so a daemon refresh that changes a tool's schema forces fresh
                // local @State (stringStore, didApplyDefaults, fallbackText).
                // The binding key uses the SAME composite so the values dict
                // invalidates in lockstep — without that, the form resets but
                // Run still reads stale wrong-typed args (v2 review BUG).
                let key = valuesKey(for: tool)
                MCPInputSchemaForm(schema: tool.inputSchema, values: binding(for: tool))
                    .id(key)
                HStack {
                    Button("Grant consent") {
                        guard let server = appModel.selectedMCPServer else { return }
                        Task { await appModel.grantMCPConsent(server: server, toolName: tool.name) }
                    }
                    Button("Run") {
                        guard let server = appModel.selectedMCPServer else { return }
                        let input = perToolValues[key] ?? [:]
                        if let validation = MCPInputSchemaForm.validationMessage(
                            schema: tool.inputSchema,
                            values: input
                        ) {
                            inputValidationErrors[key] = validation
                            return
                        }
                        inputValidationErrors.removeValue(forKey: key)
                        Task { await appModel.callMCPToolWithInput(server: server, tool: tool, input: input) }
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.bordered)
                if let validation = inputValidationErrors[key] {
                    Text(validation)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("mcp.tool.input.invalid.\(tool.name)")
                }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Resources

    private var resourcesSection: some View {
        MCPSection(label: "Resources — \(appModel.selectedMCPServer?.name ?? "no server selected")") {
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
                                .foregroundStyle(NativeAgentShell.tertiary)
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

    // MARK: - Consent log

    private var consentSection: some View {
        MCPHubConsentSection()
    }

    // MARK: - Recent call

    private var recentCallSection: some View {
        MCPSection(label: "Recent call") {
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
                    "The latest call failed this app session: \(detail). No durable call receipt was recorded.",
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
        MCPCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(call.serverId) · \(call.toolName)")
                    .font(ShellType.labelSemibold.monospaced())
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 8)
                Text(MCPHubWords.callStatus(call.status))
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(callStatusColor(call.status))
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
            .foregroundStyle(NativeAgentShell.tertiary)
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
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(NativeAgentShell.quietFill)
                    )
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

    private func callStatusColor(_ status: String) -> Color {
        switch status {
        case "ok", "success": return NativeAgentShell.calm
        case "error", "failed": return NativeAgentShell.trouble
        default: return NativeAgentShell.tertiary
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

    static func consentStatus(_ status: String?) -> String {
        switch status {
        case "granted": "Granted"
        case "revoked": "Revoked"
        case "denied": "Denied"
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

/// An eyebrow over its run of cards — the shape every group on an Advanced
/// page takes.
private struct MCPSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        // Lazy because a server's tool list can run to dozens of rows, and the
        // `List` this page used to be built them lazily too.
        LazyVStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
                .padding(.horizontal, 2)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One card: a group of controls or one row of a list.
private struct MCPCard<Content: View>: View {
    var selected: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .fill(selected ? NativeAgentShell.softFill : NativeAgentShell.quietFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
        )
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
