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

enum HealthCardPillStatus: Equatable {
    case notChecked, unknown, healthy, warning, issue

    static func make(overall: String?) -> Self {
        guard let overall else { return .notChecked }
        switch overall.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok": return .healthy
        case "warn": return .warning
        case "error": return .issue
        default: return .unknown
        }
    }

    var label: String {
        switch self {
        case .notChecked: "Not checked"
        case .unknown: "Unknown"
        case .healthy: "Healthy"
        case .warning: "Warning"
        case .issue: "Issue"
        }
    }

    var emoji: String {
        switch self {
        case .notChecked, .unknown: "○"
        case .healthy: "🟢"
        case .warning: "🟡"
        case .issue: "🔴"
        }
    }
}

struct HealthCardPill: View {
    @Environment(AppModel.self) private var appModel
    @State private var showPopover = false

    private var status: HealthCardPillStatus {
        .make(overall: appModel.healthCard?.overall)
    }
    private var pillColor: Color {
        switch status {
        case .issue: .red
        case .warning: .yellow
        case .notChecked, .unknown: .gray
        case .healthy: .green
        }
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(status.emoji)
                    .font(.caption2)
                Text(status.label)
                    .font(.caption2)
                    .foregroundStyle(pillColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(pillColor.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("System health: \(status.label)")
        .accessibilityHint("Shows system health details")
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            HealthCardPopover()
                .frame(width: 320)
        }
        // RETAINED LIVENESS POLL: this read intentionally samples the live
        // Doctor surface. It merges a short-lived cached report with probes
        // whose truth spans providers, tools, permissions, and process state;
        // no single canonical store currently emits a complete invalidation.
        // Keep it visible/focus/stream gated until Doctor owns a push snapshot.
        .task {
            await appModel.loadHealthCard(includeApprovals: false)
            guard !Task.isCancelled else { return }
            appModel.pollScheduler.register(
                .init(id: "chat-health-pill", interval: 15, pauseWhenStreaming: true, pauseWhenUnfocused: true),
                fire: { await appModel.loadHealthCard(includeApprovals: false) }
            )
        }
        .onDisappear {
            appModel.pollScheduler.unregister("chat-health-pill")
        }
    }
}

struct HealthCardPopover: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("System Health")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close system health")
            }
            .padding(.bottom, 4)

            if let card = appModel.healthCard {
                ForEach(card.subsystems) { sub in
                    HStack(alignment: .top, spacing: 8) {
                        Text(sub.status == "ok" ? "🟢" : sub.status == "warn" ? "🟡" : "🔴")
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.label)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(sub.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                                .help(sub.detail)
                        }
                        Spacer()
                        if let fix = sub.fixAction {
                            HealthFixButton(subsystemId: sub.id, action: fix)
                        }
                    }
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            } else {
                ProgressView("Loading...")
            }
        }
        .padding()
    }
}

struct MCPRestartPresentation: Equatable, Sendable {
    var message: String
    var failed: Bool

    static func make(_ response: [String: Any]) -> Self {
        let ok = response["ok"] as? Bool ?? false
        let restarted = response["restarted"] as? Int ?? 0
        let errors = response["errors"] as? [[String: String]] ?? []
        if ok {
            return Self(
                message: restarted == 0 ? "No MCP servers needed restart" : "Restarted \(restarted) MCP server(s)",
                failed: false
            )
        }
        if restarted > 0 {
            return Self(
                message: "Partial restart: \(restarted) restarted, \(max(1, errors.count)) failed",
                failed: true
            )
        }
        return Self(message: "MCP restart failed", failed: true)
    }
}

struct HealthFixButton: View {
    @Environment(AppModel.self) private var appModel
    let subsystemId: String
    let action: String
    @State private var isRunning = false
    @State private var outcome: String?
    @State private var failed = false

    private var label: String {
        switch action {
        case "reauthorize_provider": return "Reauthorize"
        case "enable_autonomy":      return "Enable"
        case "restart_mcp":          return "Restart"
        case "show_approvals":       return "Show All"
        default:                     return "Fix"
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(isRunning ? "Working…" : label) {
                Task { await runFix() }
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(isRunning)
            if let outcome {
                Text(outcome)
                    .font(.caption2)
                    .foregroundStyle(failed ? .red : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .help(outcome)
            }
        }
    }

    @MainActor
    private func runFix() async {
        guard !isRunning else { return }
        isRunning = true
        outcome = nil
        failed = false
        defer { isRunning = false }
        // R22: source from AppModel's canonical `client`.
        let api = appModel.client
        do {
            switch action {
            case "enable_autonomy":
                _ = try await api.postRaw("/v1/trust", body: ["enableAutonomy": true])
                outcome = "Enable requested"
            case "restart_mcp":
                let response = try await api.postRaw("/v1/mcp/sessions/restart", body: [:])
                let restart = MCPRestartPresentation.make(response)
                outcome = restart.message
                failed = restart.failed
            case "show_approvals":
                NativeAgentAppCoordinator.shared.request(.activity(.approvals))
                outcome = "Opened"
            case "reauthorize_provider":
                NativeAgentAppCoordinator.shared.request(.sidebar(.providers))
                outcome = "Opened"
            case "doctor":
                NativeAgentAppCoordinator.shared.request(.sidebar(.diagnostics))
                // This quick fix only claims to have OPENED Doctor and run it —
                // failing checks are shown in the Diagnostics pane, not folded
                // into this row's outcome.
                let completed = await appModel.runDoctor(repair: false).didRun
                outcome = completed ? "Doctor finished" : "Doctor unavailable"
                failed = !completed
            default:
                failed = true
                outcome = "Fix unavailable"
            }
        } catch {
            failed = true
            outcome = "Failed: \(NativeClient.safeDoctorDetail(error.localizedDescription))"
            appModel.statusText = "Health quick fix failed: \(NativeClient.safeDoctorDetail(error.localizedDescription))"
        }
        await appModel.loadHealthCard(includeApprovals: false)
    }
}

// PATCH-2026-05-08: wave3-whats-running Feature B — collapsible panel
struct WhatsRunningPresentation: Equatable, Sendable {
    var title: String
    var emptyDetail: String
    var isChecking: Bool
    var isStale: Bool

    static func make(snapshot: WhatsRunning?, status: AppModel.PanelRefreshStatus?) -> Self {
        if snapshot == nil, status == nil {
            return Self(title: "Checking…", emptyDetail: "Checking current work…", isChecking: true, isStale: false)
        }
        let count = snapshot?.items.count ?? 0
        if status?.isStale == true {
            let hasLastGood = status?.lastSuccessAt != nil
            return Self(
                title: hasLastGood ? "Running: \(count) · stale" : "Running status unavailable",
                emptyDetail: "Could not refresh running work.",
                isChecking: false,
                isStale: true
            )
        }
        return Self(
            title: count > 0 ? "Running: \(count)" : "Idle",
            emptyDetail: "Nothing in flight",
            isChecking: false,
            isStale: false
        )
    }
}

struct WhatsRunningPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var expanded = false

    private var items: [WhatsRunningItem] { appModel.whatsRunning?.items ?? [] }
    private var count: Int { items.count }
    private var presentation: WhatsRunningPresentation {
        .make(snapshot: appModel.whatsRunning, status: appModel.whatsRunningRefreshStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: presentation.isStale
                        ? "exclamationmark.triangle.fill"
                        : (presentation.isChecking ? "clock" : (count > 0 ? "bolt.circle.fill" : "bolt.circle")))
                        .foregroundStyle(presentation.isStale ? .yellow : (count > 0 ? .orange : .secondary))
                        .font(.caption)
                    Text(presentation.title)
                        .font(.caption2)
                        .foregroundStyle(count > 0 ? .primary : .secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Running work: \(presentation.title)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Collapses running work details" : "Shows running work details")

            if expanded {
                VStack(spacing: 4) {
                    if items.isEmpty {
                        Text(presentation.emptyDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    } else {
                        ForEach(items) { item in
                            WhatsRunningRow(item: item)
                        }
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .help(presentation.isStale ? "The last refresh failed; any count shown is the last known value." : "Current in-flight work")
        .task {
            await appModel.loadWhatsRunning()
            guard !Task.isCancelled else { return }
            // RETAINED LIVENESS POLL: the summary joins actor-owned background
            // loop status with pending self-improvement work. Neither owner
            // exposes one complete change stream, so file-only invalidation
            // would silently stale in-process run transitions.
            appModel.pollScheduler.register(
                .init(id: "chat-whats-running", interval: 10, pauseWhenStreaming: true, pauseWhenUnfocused: true),
                fire: { await appModel.loadWhatsRunning() }
            )
        }
        .onDisappear {
            appModel.pollScheduler.unregister("chat-whats-running")
        }
    }
}

struct WhatsRunningRow: View {
    @Environment(AppModel.self) private var appModel
    let item: WhatsRunningItem
    @State private var isCancelling = false

    private var kindIcon: String {
        switch item.kind {
        case "improvement": return "wand.and.stars"
        case "mission":     return "target"
        case "chat":        return "bubble.left.and.bubble.right"
        case "scheduler":   return "calendar.badge.clock"
        default:            return "bolt"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kindIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(item.label)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if item.cancellable {
                Button {
                    Task { await cancelItem() }
                } label: {
                    if isCancelling {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "stop.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isCancelling)
                .help(item.cancelHint ?? "Cancel \(item.label)")
                .accessibilityLabel(isCancelling
                    ? "Cancelling \(item.label)"
                    : (item.cancelHint ?? "Cancel \(item.label)"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    @MainActor
    private func cancelItem() async {
        guard !isCancelling else { return }
        isCancelling = true
        defer { isCancelling = false }

        // R22: source from AppModel's canonical `client`.
        let api = appModel.client
        do {
            switch item.kind {
            case "improvement":
                // B.5: use typed discardImprovement which calls _encodePath
                let result = try await api.discardImprovement(runId: item.id)
                if !result.ok {
                    appModel.systemToasts.push(error: "Discard failed: \(result.error ?? "unknown error")")
                }
            case "chat":
                // Route through the same AppModel owner as the composer Stop:
                // record intent, cancel the exact task, and let observed core
                // settlement decide canceled versus outcome-unknown.
                appModel.stopChatStream(sessionId: item.id)
            default:
                appModel.systemToasts.push(error: "\(item.label) cannot be cancelled from this panel.")
            }
        } catch {
            appModel.systemToasts.push(
                error: "Could not cancel \(item.label): \(error.localizedDescription)"
            )
        }
        await appModel.loadWhatsRunning()
    }
}

// PATCH-2026-06-06: chat-upgrades — compact capabilities pill near the composer.
// Renders "<N> tools · <M> connectors · screen on/off" using the live AppModel
// state. Tap opens a popover with each section listed; tap the screen-capture
// row to flip it. Sections with no data are omitted so the chip stays honest.
struct CapabilitiesChip: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingDetails = false

    private var toolCount: Int {
        // Prefer the capability catalog (user-facing tools) when populated,
        // else fall back to the local tool list (appModel.tools).
        let cat = appModel.capabilityCatalog.count
        if cat > 0 { return cat }
        return appModel.tools.count
    }

    private var connectorCount: Int {
        appModel.connectors.filter {
            let auth = $0.authState?.lowercased() ?? ""
            let health = $0.healthStatus?.lowercased() ?? ""
            return auth == "connected" || health == "ok"
        }.count
    }

    private var screenOn: Bool {
        appModel.trustPolicy?.multimodalPolicy?.screen_capture == true
    }

    var body: some View {
        Button {
            showingDetails.toggle()
        } label: {
            HStack(spacing: 4) {
                if toolCount > 0 {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.tertiary)
                    Text("\(toolCount) tools")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                }
                if connectorCount > 0 {
                    Text("\u{2022}")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.quaternary)
                    Image(systemName: "link")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.tertiary)
                    Text("\(connectorCount) connectors")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                }
                // Screen capture state always rendered — it's a privacy signal.
                Text("\u{2022}")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.quaternary)
                Image(systemName: screenOn ? "rectangle.dashed.badge.record" : "rectangle.dashed")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(screenOn ? Color.green : Color.secondary.opacity(0.5))
                Text(screenOn ? "screen on" : "screen off")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, NativeAgentSpacing.sm)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .help("Show what \(appModel.agentDisplayName) can do right now")
        .accessibilityLabel(
            "Capabilities: \(toolCount) tools, \(connectorCount) connectors, screen \(screenOn ? "on" : "off")"
        )
        .accessibilityValue(showingDetails ? "Details shown" : "Details hidden")
        .accessibilityHint("Shows currently available tools, connectors, and screen access")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            CapabilitiesChipDetail()
                .frame(minWidth: 280, idealWidth: 320)
        }
    }
}

struct CapabilitiesChipDetail: View {
    @Environment(AppModel.self) private var appModel

    private var screenOn: Bool {
        appModel.trustPolicy?.multimodalPolicy?.screen_capture == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            // Tools section
            if !appModel.capabilityCatalog.isEmpty || !appModel.tools.isEmpty {
                Text("Tools").font(NativeAgentFont.label).foregroundStyle(.secondary)
                if !appModel.capabilityCatalog.isEmpty {
                    ForEach(appModel.capabilityCatalog.prefix(8)) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.tertiary)
                            Text(item.name)
                                .font(NativeAgentFont.tag)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    if appModel.capabilityCatalog.count > 8 {
                        Text("+ \(appModel.capabilityCatalog.count - 8) more")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ForEach(appModel.tools.prefix(8), id: \.name) { tool in
                        HStack(spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.tertiary)
                            Text(tool.name)
                                .font(NativeAgentFont.tag)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    if appModel.tools.count > 8 {
                        Text("+ \(appModel.tools.count - 8) more")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.tertiary)
                    }
                }
                Divider()
            }

            // Connectors section
            let liveConnectors = appModel.connectors.filter {
                let auth = $0.authState?.lowercased() ?? ""
                let health = $0.healthStatus?.lowercased() ?? ""
                return auth == "connected" || health == "ok"
            }
            if !liveConnectors.isEmpty {
                Text("Connectors").font(NativeAgentFont.label).foregroundStyle(.secondary)
                ForEach(liveConnectors.prefix(8)) { c in
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.green)
                        Text(c.name.isEmpty ? c.id : c.name)
                            .font(NativeAgentFont.tag)
                            .lineLimit(1)
                        Spacer()
                        if let health = c.healthStatus {
                            Text(health)
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if liveConnectors.count > 8 {
                    Text("+ \(liveConnectors.count - 8) more")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.tertiary)
                }
                Divider()
            }

            // Screen capture toggle row — always present; this is a privacy signal.
            Text("Screen").font(NativeAgentFont.label).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: screenOn ? "rectangle.dashed.badge.record" : "rectangle.dashed")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(screenOn ? Color.green : Color.secondary.opacity(0.5))
                Text(screenOn ? "Screen capture is enabled" : "Screen capture is off")
                    .font(NativeAgentFont.tag)
                Spacer()
                if screenOn {
                    // v1: surface the privacy signal; the actual toggle lives
                    // in Trust → Multimodal. Deep-link there.
                    Button("Review") {
                        NotificationCenter.default.post(name: .openTrustMultimodalRequest, object: nil)
                    }
                    .font(NativeAgentFont.tag)
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(NativeAgentSpacing.md)
    }
}

extension Notification.Name {
    static let openTrustMultimodalRequest = Notification.Name("openTrustMultimodalRequest")
}
