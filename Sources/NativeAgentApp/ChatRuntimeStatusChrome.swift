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
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
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
        .liveTask(id: chatPageIsVisible) {
            guard chatPageIsVisible else {
                appModel.pollScheduler.unregister("chat-health-pill")
                showPopover = false
                return
            }
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
                outcome = completed ? "Health checks finished" : "Health checks unavailable"
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
