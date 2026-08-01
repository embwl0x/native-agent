import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
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

    // ui-honesty 2026-06-10: Approve / Enable Auto-run / Quarantine report
    // success AND failure via appModel.statusText, which this tab never
    // rendered — errors vanished. Flash statusText changes as a transient
    // bottom banner while the Tools tab is visible.
    @State private var statusFlash: String?

    /// Posts the existing openCommandRouteRequest notification (handled
    /// in ContentView.swift at line 272+) instead of mutating a child-
    /// view @SceneStorage. Keeps navigation centralized through
    /// ContentView.openCommandRoute() which also expands Advanced /
    /// sets focus correctly. (gpt-5.5 review NEEDS_FIX 3)
    private func jumpToTrust() {
        NotificationCenter.default.post(name: .openCommandRouteRequest, object: "trust")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let catalog = appModel.chatToolCatalog {
                    ChatToolCatalogSection(
                        catalog: catalog,
                        jumpToTrust: jumpToTrust
                    )
                } else if !appModel.chatToolCatalogLoadFailed {
                    // Still loading — show progress, NOT the empty state.
                    HStack {
                        ProgressView()
                        Text("Loading tool catalog...")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                if !appModel.tools.isEmpty {
                    AuthoredToolsSection(tools: appModel.tools, appModel: appModel)
                }

                // Only render the empty state when the catalog actually
                // FAILED to load (loadFailed=true) AND there are no
                // authored tools either. Loading state was racing the
                // empty state on initial paint. (gpt-5.5 review NEEDS_FIX 4)
                if appModel.chatToolCatalogLoadFailed && appModel.tools.isEmpty {
                    NativeEmptyState(
                        title: "No Tools Yet",
                        detail: "Tool catalog failed to load. Tap Refresh to retry — if it keeps failing, run Doctor for diagnostics.",
                        systemImage: "hammer"
                    )
                }
            }
            .padding()
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await appModel.refreshForSidebarItem(.tools) }
            }
        }
        .overlay(alignment: .bottom) {
            if let statusFlash {
                Text(statusFlash)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: appModel.statusText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            withAnimation { statusFlash = trimmed }
            Task {
                try? await Task.sleep(for: .seconds(4))
                if statusFlash == trimmed {
                    withAnimation { statusFlash = nil }
                }
            }
        }
    }
}

// MARK: - Chat Tool Catalog

private struct ChatToolCatalogSection: View {
    let catalog: ChatToolCatalogSnapshot
    let jumpToTrust: () -> Void

    @State private var expanded: Set<String> = []
    @State private var expandedBuckets: Set<String> = []

    private static let shellNames: Set<String> = [
        "shell", "bash", "git", "apply_patch", "run_tests",
        "swift_build", "swift_test",
    ]
    private static let fileOpsHardcoded: Set<String> = [
        "read_file", "list_dir", "write_file", "file_excerpt", "grep",
        "git_status", "git_diff", "git_log", "repo_dirty_summary",
    ]
    private static let systemNames: Set<String> = ["system_info"]
    private static let macIntegrationPrefixes: [String] = [
        "mac_", "mail_", "messages_", "calendar_", "reminders_",
        "contacts_", "notes_", "music_",
    ]
    private static let macIntegrationExact: Set<String> = ["notify", "mac.notify", "mobile.notify"]

    private struct Bucket: Identifiable {
        let id: String
        let title: String
        let icon: String
        let tools: [ChatCatalogTool]
    }

    private var buckets: [Bucket] {
        // gpt-5.5 review NEEDS_FIX 2: derive bucket assignment from the
        // CATALOG ENVELOPE's own sets, not just hardcoded name lists. The
        // hardcoded sets are still used as overrides for the most-specific
        // categorization (shell tools, system_info), but builder-set names
        // not in those overrides now flow to File Ops via the envelope's
        // builderAvailable + builderPolicyLocked sets — so new builder tools
        // added to the dispatcher get bucketed correctly without UI code
        // changes. (builderNotImplemented retired 2026-08-01: the list had
        // been permanently empty since the builder cutover completed.)
        let builderSet = Set(
            catalog.builderAvailable + catalog.builderPolicyLocked
        )
        let macAppSet = Set(catalog.macAppAvailable + catalog.macAppPolicyLocked)
        var mcp: [ChatCatalogTool] = []
        var alwaysOn: [ChatCatalogTool] = []
        var fileOps: [ChatCatalogTool] = []
        var system: [ChatCatalogTool] = []
        var shell: [ChatCatalogTool] = []
        var macControl: [ChatCatalogTool] = []
        var macIntegration: [ChatCatalogTool] = []
        var other: [ChatCatalogTool] = []

        for tool in catalog.tools {
            let name = tool.name
            // 1) MCP first (most-specific by name prefix; catches every
            //    external server tool ahead of any other classification).
            if name.hasPrefix("mcp__") {
                mcp.append(tool)
                continue
            }
            // 2) Shell/build hardcoded (most-critical, most-specific).
            if Self.shellNames.contains(name) {
                shell.append(tool)
                continue
            }
            // 3) System.
            if Self.systemNames.contains(name) {
                system.append(tool)
                continue
            }
            // 4) Mac Control (envelope-driven).
            if macAppSet.contains(name) {
                macControl.append(tool)
                continue
            }
            // 5) Mac Integration (prefix + exact name).
            if Self.macIntegrationExact.contains(name) ||
               Self.macIntegrationPrefixes.contains(where: { name.hasPrefix($0) }) {
                macIntegration.append(tool)
                continue
            }
            // 6) File Ops — hardcoded OR envelope builderSet (catches future
            //    builder tools the hardcoded list doesn't know about).
            if Self.fileOpsHardcoded.contains(name) || builderSet.contains(name) {
                fileOps.append(tool)
                continue
            }
            // 7) Always-on fallback for anything currently loaded that
            //    didn't fit a more-specific bucket.
            if catalog.currentlyLoaded.contains(name) {
                alwaysOn.append(tool)
                continue
            }
            // 8) Last resort.
            other.append(tool)
        }

        // Display order matches classification specificity (most-specific
        // first) so the most powerful / highest-leverage buckets render
        // at the top of the tab: external MCP servers, then shell, then
        // system/mac control, then integration reads, then plain file
        // ops, then the safe-by-default always-on tools, then the
        // catch-all. (gpt-5.5 review R2 NEEDS_FIX)
        let raw: [Bucket] = [
            Bucket(id: "mcp", title: "MCP (External Servers)", icon: "link", tools: mcp),
            Bucket(id: "shell", title: "Shell / Build", icon: "terminal", tools: shell),
            Bucket(id: "system", title: "System", icon: "cpu", tools: system),
            Bucket(id: "mac-control", title: "Mac Control", icon: "macwindow", tools: macControl),
            Bucket(id: "mac-integration", title: "Mac Integration", icon: "app.badge", tools: macIntegration),
            Bucket(id: "file-ops", title: "File Ops", icon: "doc.text", tools: fileOps),
            Bucket(id: "always-on", title: "Always-on", icon: "bolt.circle", tools: alwaysOn),
            Bucket(id: "other", title: "Other", icon: "ellipsis.circle", tools: other),
        ]
        return raw.filter { !$0.tools.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Chat Tool Catalog")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(catalog.tools.count) tools • permission: \(catalog.permissionLevel.isEmpty ? "—" : catalog.permissionLevel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !catalog.fullMacActive {
                fullMacBanner
            }

            ForEach(buckets) { bucket in
                bucketView(bucket)
            }
        }
    }

    private var fullMacBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Full Mac is OFF")
                    .font(.subheadline.weight(.semibold))
                Text("File, system, shell, and Mac-control tools are policy-locked. Toggle Full Mac in Trust Center to unlock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Trust Center") { jumpToTrust() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func bucketView(_ bucket: Bucket) -> some View {
        DisclosureGroup(isExpanded: bucketExpandedBinding(bucket.id)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(bucket.tools) { tool in
                    toolRow(tool)
                    if tool.id != bucket.tools.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 6)
        } label: {
            HStack {
                Label(bucket.title, systemImage: bucket.icon)
                    .font(.headline)
                Spacer()
                Text("\(bucket.tools.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bucketExpandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedBuckets.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedBuckets.insert(id)
                } else {
                    expandedBuckets.remove(id)
                }
            }
        )
    }

    @ViewBuilder
    private func toolRow(_ tool: ChatCatalogTool) -> some View {
        let isExpanded = expanded.contains(tool.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(tool.name)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                statusBadge(for: tool)
            }
            Text(tool.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .textSelection(.enabled)
            if isExpanded {
                if let params = tool.parametersPreview {
                    Text("params: \(params)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                if let via = tool.dispatchableVia {
                    Text("via: \(via)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded { expanded.remove(tool.id) } else { expanded.insert(tool.id) }
        }
    }

    @ViewBuilder
    private func statusBadge(for tool: ChatCatalogTool) -> some View {
        let isLocked = catalog.builderPolicyLocked.contains(tool.name)
            || catalog.macAppPolicyLocked.contains(tool.name)
        let isActive = tool.loadState == "loaded" || catalog.currentlyLoaded.contains(tool.name)

        if isLocked {
            Label("policy-locked", systemImage: "lock")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        } else if tool.availableNow == false {
            Label("unavailable", systemImage: "minus.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if tool.effectiveAutonomy == "blocked" {
            Label("blocked", systemImage: "hand.raised")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
        } else if tool.effectiveAutonomy == "confirm" {
            Label("approval", systemImage: "checkmark.shield")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        } else if isActive {
            Label("active", systemImage: "circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        } else if tool.loadState == "discovery_only" {
            Label("on demand", systemImage: "bolt.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        } else {
            Label("available", systemImage: "checkmark.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Authored Tools

private struct AuthoredToolsSection: View {
    let tools: [ToolRecord]
    let appModel: AppModel
    @State private var quarantineCandidate: ToolRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authored Tools (Self-Improvement)")
                .font(.title2.weight(.semibold))
            ForEach(tools) { tool in
                authoredRow(tool)
                    .padding(.vertical, 6)
                if tool.id != tools.last?.id {
                    Divider()
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tool.name)
                    .font(.headline)
                Spacer()
                Text(tool.status ?? "unknown")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(tool.status))
            }
            Text(tool.description)
                .textSelection(.enabled)
            if !tool.triggers.isEmpty {
                Text(tool.triggers.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                if tool.autoCreated == true {
                    Label("Auto-created", systemImage: "wand.and.stars")
                }
                if tool.autoRun == true {
                    Label("Auto-run", systemImage: "bolt.fill")
                }
                Label(tool.validationStatus ?? "untested", systemImage: validationIcon(tool.validationStatus))
                Label("Used \(tool.useCount ?? 0)", systemImage: "hammer")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            if let permissions = tool.permissions, !permissions.isEmpty {
                Text("Permissions: \(permissions.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let errors = tool.validationErrors, !errors.isEmpty {
                Text(errors.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let path = tool.activePath ?? tool.proposalPath ?? tool.quarantinePath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack {
                if tool.status != "active" {
                    Button("Approve", systemImage: "checkmark.seal") {
                        Task { await appModel.promoteTool(tool, userRequested: true) }
                    }
                    .disabled(tool.validationStatus != "valid")
                }
                Button(tool.autoRun == true ? "Disable Auto-run" : "Enable Auto-run", systemImage: tool.autoRun == true ? "pause.circle" : "play.circle") {
                    Task { await appModel.setToolAutoRun(tool, autoRun: !(tool.autoRun ?? false)) }
                }
                .disabled(tool.status != "active")
                Button("Quarantine", systemImage: "exclamationmark.triangle") {
                    quarantineCandidate = tool
                }
                .disabled(tool.status == "quarantined")
            }
            .buttonStyle(.borderless)
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "active": .green
        case "quarantined": .red
        case "proposed": .orange
        default: .secondary
        }
    }

    private func validationIcon(_ status: String?) -> String {
        switch status {
        case "valid": "checkmark.seal"
        case "failed": "exclamationmark.triangle"
        default: "questionmark.circle"
        }
    }
}
