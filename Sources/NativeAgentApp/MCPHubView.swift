import SwiftUI
import PersistenceCore

// MCP server control hub — a sidebar tab that surfaces all connected MCP
// servers, their tools, the consent log, and the most recent tool call. The
// backend (AppModel + NativeClient) is fully wired; this view is purely the
// SwiftUI layer. Style matches ConnectorsView (Sources/NativeAgentApp/
// ContentView.swift around line 7754) — same List/Section/Label idioms,
// `.font(.headline / .caption / .caption2)`, `.foregroundStyle(.secondary /
// .tertiary)`, `.buttonStyle(.bordered)`.
struct MCPHubView: View {
    @Environment(AppModel.self) private var appModel

    // Per-tool form state. Keyed by (tool.name, schemaFingerprint) so a
    // schema change for a same-named tool invalidates the dict in lockstep
    // with the form's SwiftUI identity below. gpt-5.5 v2 review caught the
    // bug where the form reset its @State on schema change but the Run
    // button still read perToolValues[tool.name] holding old/wrong-typed args.
    @State private var perToolValues: [String: [String: JSONValue]] = [:]
    @State private var expandedTool: Set<String> = []

    private func valuesKey(for tool: MCPToolRecord) -> String {
        "\(tool.name)|\(schemaFingerprint(tool.inputSchema))"
    }

    private func binding(for tool: MCPToolRecord) -> Binding<[String: JSONValue]> {
        let key = valuesKey(for: tool)
        return Binding(
            get: { perToolValues[key] ?? [:] },
            set: { perToolValues[key] = $0 }
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
        VStack(alignment: .leading, spacing: 12) {
            List {
                serversSection
                toolsSection
                resourcesSection
                consentSection
                recentCallSection
            }
        }
        .padding()
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
        }
    }

    // MARK: - Servers

    private var serversSection: some View {
        Section("Servers") {
            if appModel.mcpServers.isEmpty {
                Text("No MCP servers configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.mcpServers) { server in
                    serverRow(server)
                }
            }
        }
    }

    private func serverRow(_ server: MCPServerRecord) -> some View {
        let isSelected = server.id == appModel.selectedMCPServerId
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(server.name)
                    .font(.headline)
                Spacer()
                Text(server.healthStatus ?? "unknown")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(healthColor(server.healthStatus))
            }

            HStack(spacing: 12) {
                Label("\(server.toolCount ?? 0) tools", systemImage: "wrench.and.screwdriver")
                Label("\(server.resourceCount ?? 0) resources", systemImage: "doc.on.doc")
                Label(server.transport ?? "transport?", systemImage: "bolt.horizontal")
                if let risk = server.riskClass, !risk.isEmpty {
                    Label("risk: \(risk)", systemImage: "exclamationmark.shield")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let endpoint = server.endpoint, !endpoint.isEmpty {
                Text(endpoint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let command = server.command, !command.isEmpty {
                Text(command)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Button("Warm") {
                    Task { await appModel.warmMCPServer(server) }
                }
                Button("Restart") {
                    Task { await appModel.restartMCPServer(server) }
                }
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
                Spacer()
                if let updated = server.updatedAt, !updated.isEmpty {
                    Text(updated)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .naInteractive(radius: 6)
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
        case "ok": return .green
        case "fail", "error": return .red
        case "needs_setup": return .orange
        default: return .secondary
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        Section("Tools — \(appModel.selectedMCPServer?.name ?? "no server selected")") {
            if appModel.mcpTools.isEmpty {
                Text("No tools loaded. Select a server or warm it first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.mcpTools) { tool in
                    toolRow(tool)
                }
            }
        }
    }

    private func toolRow(_ tool: MCPToolRecord) -> some View {
        let isExpanded = expandedTool.contains(tool.name)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.subheadline.weight(.semibold))
                    if let description = tool.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(isExpanded ? "Hide" : "Edit") {
                    if isExpanded { expandedTool.remove(tool.name) } else { expandedTool.insert(tool.name) }
                }
                .font(.caption)
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
                        Task { await appModel.callMCPToolWithInput(server: server, tool: tool, input: input) }
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Resources

    private var resourcesSection: some View {
        Section("Resources — \(appModel.selectedMCPServer?.name ?? "no server selected")") {
            if appModel.mcpResources.isEmpty {
                Text("No resources exposed by this server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.mcpResources) { resource in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(resource.name ?? resource.uri)
                            .font(.subheadline.weight(.semibold))
                        if resource.name != nil {
                            Text(resource.uri)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let mime = resource.mimeType, !mime.isEmpty {
                            Text(mime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Consent log

    private var consentSection: some View {
        Section("Consent log") {
            if appModel.mcpConsent.isEmpty {
                Text("No consents granted yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.mcpConsent) { consent in
                    consentRow(consent)
                }
            }
        }
    }

    private func consentRow(_ consent: MCPConsentRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(consent.serverId ?? "?") · \(consent.toolName ?? "?")")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(consent.status ?? "unknown")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(consentColor(consent.status))
            }
            HStack(spacing: 12) {
                if let granted = consent.grantedAt, !granted.isEmpty {
                    Label("granted \(granted)", systemImage: "checkmark.seal")
                }
                if let revoked = consent.revokedAt, !revoked.isEmpty {
                    Label("revoked \(revoked)", systemImage: "xmark.seal")
                }
                if let risk = consent.risk, !risk.isEmpty {
                    Label(risk, systemImage: "exclamationmark.shield")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            if (consent.status ?? "") == "granted" {
                HStack {
                    Spacer()
                    Button("Revoke", role: .destructive) {
                        Task { await appModel.revokeMCPConsent(consent) }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func consentColor(_ status: String?) -> Color {
        switch status {
        case "granted": return .green
        case "revoked": return .orange
        case "denied": return .red
        default: return .secondary
        }
    }

    // MARK: - Recent call

    private var recentCallSection: some View {
        Section("Recent call") {
            if let call = appModel.latestMCPCall {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(call.serverId) · \(call.toolName)")
                        .font(.headline)
                    Text(call.status)
                        .font(.caption)
                        .foregroundStyle(callStatusColor(call.status))
                    if let duration = call.durationSeconds {
                        Text("\(duration, specifier: "%.2f")s")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let createdAt = call.createdAt, !createdAt.isEmpty {
                        Text(createdAt)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let preview = call.resultPreview, !preview.isEmpty {
                        Text(preview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(12)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if call.resultTruncated == true {
                        Label("Result preview truncated · \(call.resultByteCount ?? 0) bytes", systemImage: "scissors")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if call.evidenceStatus == "recorded" {
                        Label("Evidence recorded", systemImage: "checkmark.seal")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else if call.evidenceStatus == "failed" {
                        Label("Call completed; evidence write failed", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help(call.evidenceError ?? "The MCP result could not be appended to Activity.")
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("No MCP tool has been called this session yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func callStatusColor(_ status: String) -> Color {
        switch status {
        case "ok", "success": return .green
        case "error", "failed": return .red
        default: return .secondary
        }
    }
}
