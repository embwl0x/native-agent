import SwiftUI

struct CapabilitiesView: View {
    @Environment(AppModel.self) private var appModel
    @State private var mode = CapabilityWorkspaceMode.overview
    @State private var routeText = "Research a topic, build a reusable tool if it repeats, and keep it approval-gated."
    @State private var workflowObjective = "Dry-run the selected workflow and record receipts."
    @State private var researchObjective = "Find current best practices for lightweight autonomous agent capability systems."
    @State private var mcpQuery = "NativeAgent capabilities"
    @State private var graphQuery = "memory workflow capability"
    @State private var catalogSourceName = "Local NativeAgent Catalog"
    @State private var catalogSourceURL = ""
    // 2026-07-22 page-tighten: the two heaviest always-expanded blocks
    // (Next-Gen Runtime migration cockpit in Overview, MCP Builder in Build —
    // whose canonical home is the dedicated MCP tab) collapse by default;
    // open-state persists across visits like the Trust Advanced group.
    @AppStorage("capabilitiesShowNextGen") private var showNextGen = false
    @AppStorage("capabilitiesShowMCPBuilder") private var showMCPBuilder = false

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

                Text(appModel.statusText)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle("Capabilities")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await appModel.refreshForSidebarItem(.capabilities) }
            }
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            MetricTile(title: "Capabilities", value: "\(appModel.capabilitySummary?.summary.total ?? 0)", systemImage: "shippingbox")
            MetricTile(title: "Workflows", value: "\(appModel.workflows.count)", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            MetricTile(title: "MCP", value: "\(appModel.mcpServers.count)", systemImage: "externaldrive.connected.to.line.below")
            MetricTile(title: "Next Gen", value: "\(nextGenReadyCount)/\(nextGenTotalCount)", systemImage: "sparkles.rectangle.stack")
            MetricTile(title: "Approvals", value: "\(appModel.approvals.filter { $0.status.lowercased() == "pending" }.count)", systemImage: "checkmark.shield")
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
                attentionBadge: nextGenReviewCount > 0 ? "\(nextGenReviewCount) to review" : nil
            ) {
                nextGenRuntime
            }

            NativePanel(title: "Foundry Index", systemImage: "shippingbox") {
                if let summary = appModel.capabilitySummary {
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
                } else {
                    NativeEmptyState(title: "No capability summary", detail: "Refresh when the native runtime is ready.", systemImage: "shippingbox")
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

    private var mcpErrorCount: Int {
        appModel.mcpSessions.filter { ($0.lastError?.isEmpty == false) }.count
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
            NativePanel(title: "Workflow Builder", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                TextField("Workflow objective", text: $workflowObjective, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                if appModel.workflows.isEmpty {
                    Text("No workflows loaded.")
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
                    Divider()
                    HStack(alignment: .top, spacing: 10) {
                        CapabilityDetailRow(
                            title: latest.workflowName ?? latest.workflowId,
                            detail: "\(latest.mode ?? "run") · \(latest.steps.count) step(s)",
                            status: latest.status,
                            systemImage: "play.rectangle"
                        )
                        Spacer()
                        Button("Resume", systemImage: "play.fill") {
                            Task { await appModel.resumeWorkflowRun(latest) }
                        }
                        .disabled(latest.status != "waiting_approval")
                        Button("Cancel", systemImage: "xmark.circle") {
                            Task { await appModel.cancelWorkflowRun(latest) }
                        }
                        .disabled(["succeeded", "failed", "canceled", "rolled_back"].contains(latest.status))
                        Button("Rollback", systemImage: "arrow.uturn.backward.circle") {
                            Task { await appModel.rollbackWorkflowRun(latest) }
                        }
                        .disabled(!["succeeded", "failed", "canceled"].contains(latest.status))
                    }
                }
            }

            NativePanel(title: "Capability Catalog", systemImage: "square.grid.3x3") {
                HStack {
                    Button("Install Signed Demo Pack", systemImage: "checkmark.seal") {
                        Task { await appModel.installDemoCapabilityPack() }
                    }
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

                HStack {
                    TextField("Source name", text: $catalogSourceName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Source URL or path", text: $catalogSourceURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Add Source", systemImage: "plus.circle") {
                        Task { await appModel.addCatalogSource(name: catalogSourceName, url: catalogSourceURL) }
                    }
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
                attentionBadge: mcpErrorCount > 0 ? "\(mcpErrorCount) error\(mcpErrorCount == 1 ? "" : "s")" : nil
            ) {
                mcpBuilderPanel
            }
        }
    }

    private var mcpBuilderPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                if appModel.mcpServers.isEmpty {
                    Text("No MCP server records loaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

                if let plan = appModel.routePlan {
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
                        if !plan.matchedCapabilities.isEmpty {
                            Text("Matched Capabilities")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(plan.matchedCapabilities.prefix(5)) { capability in
                                CapabilityRow(capability: capability, compact: true)
                            }
                        }
                    }
                }
            }

            NativePanel(title: "Research Lab", systemImage: "magnifyingglass") {
                TextField("Research objective", text: $researchObjective, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                Button("Run Research Lab", systemImage: "doc.text.magnifyingglass") {
                    Task { await appModel.runResearchLab(objective: researchObjective) }
                }

                if let latest = appModel.researchLabRuns.first {
                    Divider()
                    CapabilityDetailRow(title: latest.objective, detail: latest.brief ?? latest.status, status: latest.status, systemImage: "doc.text")
                }
            }

            NativePanel(title: "Trace Timeline", systemImage: "waveform.path") {
                if appModel.traces.isEmpty {
                    Text("No traces yet. Route, run a workflow, or install a catalog item to create one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(appModel.traces.prefix(14)) { trace in
                            CapabilityDetailRow(title: trace.title, detail: trace.kind, status: trace.status ?? "ok", systemImage: "waveform.path")
                            if trace.id != appModel.traces.prefix(14).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            if let graph = appModel.agentGraph {
                NativePanel(title: "Skill Memory Graph", systemImage: "point.3.filled.connected.trianglepath.dotted") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        CapabilityMetricCard(title: "Nodes", value: "\(graph.summary.nodes)", detail: "memories, runs, Desk tasks, capabilities", systemImage: "circle.grid.cross")
                        CapabilityMetricCard(title: "Edges", value: "\(graph.summary.edges)", detail: "produced and used links", systemImage: "point.3.connected.trianglepath.dotted")
                        CapabilityMetricCard(title: "Capabilities", value: "\(graph.summary.capabilities ?? 0)", detail: "indexed objects", systemImage: "shippingbox")
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
                }
            }
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

            NativePanel(title: "Approval Inbox", systemImage: "checkmark.shield") {
                if appModel.approvals.isEmpty {
                    Text("No approval requests yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
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
                                        Task { await appModel.resolveApproval(approval, decision: "approved") }
                                    }
                                    Button("Deny", systemImage: "xmark") {
                                        Task { await appModel.resolveApproval(approval, decision: "denied") }
                                    }
                                }
                            }
                            if approval.id != appModel.approvals.prefix(8).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            NativePanel(title: "Native macOS Power", systemImage: "macwindow") {
                // 2026-07-21 audit fix (dead-surface honesty): the
                // `nativePower.surfaces` list and the "App Intents" tile were
                // removed — getNativePower() is a DAEMON-KILL P1 stub that
                // returns surfaces: [] forever, and /v1/native/intents was
                // retired with no SwiftNative successor (the dead intent-registry
                // chain was fully deleted 2026-08-14), so both rendered permanent
                // empty/"Loading" furniture. The remaining tiles and action
                // rows below are fed by live readers.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    NativeRuntimeTile(
                        title: "Notifications",
                        value: "\(appModel.notificationStatus?.pendingApprovals ?? 0)",
                        detail: "pending approvals",
                        status: appModel.notificationStatus?.status ?? "warn",
                        systemImage: "bell.badge"
                    )
                    NativeRuntimeTile(
                        title: "Browser",
                        value: "\(appModel.browserRuntimeStatus?.receiptCount ?? 0)",
                        detail: appModel.browserRuntimeStatus?.status ?? "Loading",
                        status: appModel.browserRuntimeStatus?.status ?? "warn",
                        systemImage: "safari"
                    )
                    NativeRuntimeTile(
                        title: "Vector Memory",
                        value: "\(appModel.memoryVectorStatus?.nodeCount ?? 0)",
                        detail: appModel.memoryVectorStatus?.providerModel ?? "Loading",
                        status: appModel.memoryVectorStatus?.status ?? "warn",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                }

                if !appModel.nativeActions.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(appModel.nativeActions.prefix(6)) { action in
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
                                Button("Run", systemImage: "bolt.circle") {
                                    Task { await appModel.runNativeAction(action, dryRun: false) }
                                }
                                .disabled(action.requiresApproval == true)
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
                HStack(spacing: 8) {
                    Button("Browser Dry Run", systemImage: "safari") {
                        Task { await appModel.runBrowserDryRun() }
                    }
                    Button("Cancel Browser", systemImage: "stop.circle") {
                        Task { await appModel.cancelBrowserRun() }
                    }
                    Button("Run Gauntlet", systemImage: "checkmark.shield") {
                        Task { await appModel.runImprovementGauntlet() }
                    }
                    Spacer()
                    if let gauntlet = appModel.latestGauntletRun ?? appModel.improvementGauntletStatus?.latestRun {
                        StatusBadge(text: gauntlet.status.uppercased(), status: gauntlet.status)
                    }
                }
            }

            NativePanel(title: "Production Hardening", systemImage: "checkmark.seal") {
                if let hardening = appModel.productionHardening {
                    HStack(spacing: 8) {
                        StatusBadge(text: hardening.status.uppercased(), status: hardening.status)
                        if let doctor = hardening.doctorStatus {
                            StatusBadge(text: "Doctor \(doctor)", status: doctor)
                        }
                        Spacer()
                        Button("Export", systemImage: "square.and.arrow.up") {
                            Task { await appModel.createProductionExport() }
                        }
                        Button("Support Bundle", systemImage: "shippingbox") {
                            Task { await appModel.createProductionExport(support: true) }
                        }
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
                            ForEach(release.items.prefix(8)) { item in
                                CapabilityDetailRow(title: item.title, detail: item.detail, status: item.status, systemImage: "checkmark.seal")
                            }
                        }
                    }
                } else {
                    Text("Production summary has not loaded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
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
