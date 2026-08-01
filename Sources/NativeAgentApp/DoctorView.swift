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

struct DoctorView: View {
    @Environment(AppModel.self) private var appModel
    @State private var loopVerdicts: [LoopHealthVerdict] = []

    private var unhealthyLoops: [LoopHealthVerdict] {
        loopVerdicts.filter { $0.level != .ok }
    }

    private var healthyCount: Int {
        loopVerdicts.count - unhealthyLoops.count
    }

    private var loopPanelTint: Color {
        if loopVerdicts.contains(where: { $0.level == .fail }) { return .red }
        if loopVerdicts.contains(where: { $0.level == .warn }) { return .orange }
        return .green
    }

    private var groupedChecks: [(String, [DoctorCheck])] {
        guard let checks = appModel.doctorReport?.checks else { return [] }
        let order = ["Provider", "Runtime", "Connectors", "Data", "Tools", "Autonomy", "Release"]
        let grouped = Dictionary(grouping: checks, by: category)
        return order.compactMap { key in
            guard let values = grouped[key], !values.isEmpty else { return nil }
            return (key, values)
        }
    }

    // UI-2 (public-user honesty, 2026-08-01): the page used to open on
    // CODEX_HOME paths, raw loop IDs, and a bare "Ok" status word. A person who
    // did not write this app cannot read any of that. The plain summary leads;
    // every technical string still ships, one disclosure down.
    private var checkSummary: DoctorPlainCopy.Summary {
        DoctorPlainCopy.summarize(appModel.doctorReport?.checks ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Run Doctor", systemImage: "stethoscope") {
                    Task { await appModel.runDoctor(repair: false) }
                }
                .disabled(appModel.doctorRunning)
                Button("Repair Safe Issues", systemImage: "cross.case.fill") {
                    Task { await appModel.runDoctor(repair: true) }
                }
                .disabled(appModel.doctorRunning)
                Button("Open OAuth Login", systemImage: "safari") {
                    Task { await appModel.openCodexLoginInBrowser() }
                }
                Button("Support Snapshot", systemImage: "shippingbox") {
                    Task { await appModel.loadSupportDiagnostics() }
                }
                // PATCH-2026-05-30: in-flight indicator so the user sees the
                // Doctor is working during the ~7-15s probe. Previously the
                // UI looked frozen and people thought it wasn't running.
                // TimelineView ticks once per second to show elapsed duration.
                if appModel.doctorRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        if let started = appModel.doctorRunStartedAt {
                            TimelineView(.periodic(from: started, by: 1.0)) { ctx in
                                let elapsed = max(0, Int(ctx.date.timeIntervalSince(started)))
                                Text("Running Doctor checks · \(elapsed)s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Running Doctor checks…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 8)
                }
            }

            // Watchdog readout lives in Diagnostics ▸ Status (the canonical
            // health surface). It rendered identically here too until the
            // 2026-07-03 dead-weight audit flagged the duplication.

            healthSummaryPanel

            if let login = appModel.codexDeviceLogin {
                NativePanel(title: "Codex OAuth", systemImage: "key.fill", tint: .blue) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open \(login.url ?? "https://auth.openai.com/codex/device")")
                            .font(NativeAgentFont.body)
                        Text("Code: \(login.code ?? "pending")")
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                        // UI-2: the CODEX_HOME path is a developer detail. It
                        // still ships, collapsed, so support requests can read
                        // it without it being the second thing a user sees.
                        DisclosureGroup("Details") {
                            Text("CODEX_HOME: \(login.codexHome ?? "")")
                                .font(NativeAgentFont.mono)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(NativeAgentFont.label)
                        // Cancel + clear through the same Swift device-login
                        // subprocess owner used by the Setup view.
                        HStack {
                            Button("Cancel", systemImage: "xmark.circle") {
                                Task { await appModel.cancelCodexDeviceLogin() }
                            }
                            Button("Clear", systemImage: "eraser") {
                                Task { await appModel.clearCodexDeviceLogin() }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .textSelection(.enabled)
                }
            }

            // Background-loop health (2026-07-16): github_tracking failed every
            // tick for 4 days with zero surfacing. Rule + receipt parsing live
            // in DoctorLoopHealth (pure, unit-tested); this is display only.
            NativePanel(title: "Background tasks", systemImage: "arrow.triangle.2.circlepath", tint: loopPanelTint) {
                if loopVerdicts.isEmpty {
                    Text("Background tasks have not started yet.")
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(unhealthyLoops) { verdict in
                            HStack(alignment: .firstTextBaseline) {
                                InlineStatusDot(status: verdict.level.statusText)
                                VStack(alignment: .leading, spacing: 2) {
                                    // UI-2: plain name in the headline; the raw
                                    // loop ID moves into the Details list below.
                                    Text(DoctorPlainCopy.friendlyLoopName(verdict.loopId))
                                        .font(NativeAgentFont.section)
                                    Text(verdict.detail)
                                        .font(NativeAgentFont.body)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                StatusBadge(text: verdict.level.statusText.uppercased(), status: verdict.level.statusText)
                            }
                        }
                        if unhealthyLoops.isEmpty {
                            HStack {
                                InlineStatusDot(status: "ok")
                                Text(DoctorPlainCopy.allLoopsHealthyText(count: loopVerdicts.count))
                                    .font(NativeAgentFont.body)
                                    .foregroundStyle(.secondary)
                            }
                        } else if healthyCount > 0 {
                            Text(DoctorPlainCopy.otherLoopsHealthyText(count: healthyCount))
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.tertiary)
                        }
                        DisclosureGroup("Details") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(loopVerdicts) { verdict in
                                    Text("\(verdict.loopId) — \(verdict.level.statusText)")
                                        .font(NativeAgentFont.mono)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(NativeAgentFont.label)
                    }
                }
            }
            .task(id: appModel.doctorRunning) {
                loopVerdicts = await DoctorLoopHealth.current()
            }

            if appModel.doctorReport != nil {
                // UI-2: the raw report status word and the support badge moved
                // into healthSummaryPanel above, so the page leads with a
                // sentence instead of "Ok".
                List {
                    ForEach(groupedChecks, id: \.0) { group, checks in
                        Section(DoctorPlainCopy.sectionTitle(for: group)) {
                            ForEach(checks) { check in
                                DoctorCheckRow(check: check)
                            }
                            // One Details disclosure per section holds the raw
                            // check IDs that support asks for.
                            DisclosureGroup("Details") {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(checks) { check in
                                        Text("\(check.id) — \(check.status)")
                                            .font(NativeAgentFont.mono)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .font(NativeAgentFont.label)
                        }
                    }
                }
            } else {
                NativeEmptyState(
                    title: "Doctor",
                    detail: "Run diagnostics to check the native runtime, provider routing, SearXNG, Telegram, sessions, tools, and autonomy.",
                    systemImage: "cross.case",
                    actionTitle: "Run Doctor",
                    actionImage: "stethoscope"
                ) {
                    Task { await appModel.runDoctor(repair: false) }
                }
            }
        }
        .padding()
        .navigationTitle("Doctor")
        .task {
            await appModel.refreshLiveDoctorCoverage()
        }
    }

    // UI-2: the page's new lead. Plain sentence + plain counts; the raw report
    // status word and check tally live one disclosure down.
    @ViewBuilder
    private var healthSummaryPanel: some View {
        NativePanel(
            title: "Overall health",
            systemImage: "heart.text.square",
            tint: DoctorPlainCopy.tint(for: checkSummary)
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    InlineStatusDot(status: checkSummary.statusText)
                    Text(DoctorPlainCopy.headline(for: checkSummary))
                        .font(NativeAgentFont.section)
                    Spacer()
                    if let diagnostics = appModel.supportDiagnostics {
                        StatusBadge(text: "Support \(diagnostics.version)", status: diagnostics.doctorStatus)
                    }
                }
                Text(DoctorPlainCopy.detail(for: checkSummary))
                    .font(NativeAgentFont.body)
                    .foregroundStyle(.secondary)
                if let report = appModel.doctorReport {
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("report status: \(report.status)")
                            Text("checks run: \(report.checks.count)")
                            Text("safe repairs applied: \(report.repaired ? "yes" : "no")")
                        }
                        .font(NativeAgentFont.mono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                    .font(NativeAgentFont.label)
                }
            }
        }
    }

    private func category(for check: DoctorCheck) -> String {
        Self.categoryID(for: check.id)
    }

    static func categoryID(for id: String) -> String {
        switch id {
        case "codex_login", "llm", "codex_login_helper", "live.providers": "Provider"
        case "daemon_lifecycle", "legacy_launch_agent", "launch_agent": "Runtime"
        case "searxng", "telegram", "connectors", "live.telegram", "live.search": "Connectors"
        case "storage", "chat_sessions", "persona_engine", "backups", "write_test": "Data"
        case "tools", "live.tools": "Tools"
        case "autonomy", "live.autonomy": "Autonomy"
        default: "Release"
        }
    }
}

// MARK: - Plain-English Doctor copy
//
// UI-2 (2026-08-01, public era): pure string/count helpers so the honesty copy
// is unit-testable without a UI snapshot harness. No SwiftUI types here on
// purpose — everything below is a value in, a String or Int out.
enum DoctorPlainCopy {
    struct Summary: Equatable {
        var healthy = 0
        var warning = 0
        var failing = 0
        var unclear = 0

        var total: Int { healthy + warning + failing + unclear }

        /// Vocabulary understood by NativeAgentTheme.statusColor / StatusBadge.
        var statusText: String {
            if failing > 0 { return "failed" }
            if warning > 0 { return "warn" }
            if total == 0 { return "unknown" }
            return "ok"
        }
    }

    /// Bucket a raw doctor check status into the three words a person can act
    /// on. Mirrors the NativeAgentTheme.statusColor vocabulary so the dot next
    /// to the sentence never disagrees with the sentence.
    static func bucket(for status: String) -> String {
        switch status.lowercased() {
        case "ok", "done", "passed", "succeeded", "active", "valid", "ready", "scheduled":
            return "healthy"
        case "warn", "warning", "blocked", "needs_setup", "planned", "interrupted", "disabled":
            return "warning"
        case "fail", "failed", "error", "timeout", "quarantined":
            return "failing"
        default:
            return "unclear"
        }
    }

    static func summarize(_ checks: [DoctorCheck]) -> Summary {
        var summary = Summary()
        for check in checks {
            switch bucket(for: check.status) {
            case "healthy": summary.healthy += 1
            case "warning": summary.warning += 1
            case "failing": summary.failing += 1
            default: summary.unclear += 1
            }
        }
        return summary
    }

    static func headline(for summary: Summary) -> String {
        if summary.total == 0 { return "No checks have run yet." }
        if summary.failing > 0 { return "Some parts of the app are not working." }
        if summary.warning > 0 { return "The app is running, but some parts need attention." }
        if summary.unclear > 0 { return "The app is running. Some checks came back unclear." }
        return "Everything looks healthy."
    }

    static func detail(for summary: Summary) -> String {
        guard summary.total > 0 else {
            return "Press Run Doctor to check how the app is doing."
        }
        var parts = ["\(summary.healthy) working"]
        if summary.warning > 0 { parts.append("\(summary.warning) need attention") }
        if summary.failing > 0 { parts.append("\(summary.failing) not working") }
        if summary.unclear > 0 { parts.append("\(summary.unclear) unclear") }
        let checked = summary.total == 1 ? "1 area checked" : "\(summary.total) areas checked"
        return "\(checked): " + parts.joined(separator: ", ") + "."
    }

    static func tint(for summary: Summary) -> Color {
        if summary.failing > 0 { return .red }
        if summary.warning > 0 { return .orange }
        if summary.total == 0 { return .secondary }
        return .green
    }

    /// Group keys come from DoctorView.categoryID, which speaks in code words.
    /// These are the same seven groups said out loud.
    static func sectionTitle(for group: String) -> String {
        switch group {
        case "Provider": return "AI provider"
        case "Runtime": return "App runtime"
        case "Connectors": return "Connected services"
        case "Data": return "Your data"
        case "Tools": return "Tools"
        case "Autonomy": return "Actions the agent takes on its own"
        // "Release" holds the store-validity checks (JSON stores, chat logs,
        // memory database) — "App version" mislabeled them (taste pass).
        case "Release": return "Stored data health"
        default: return group
        }
    }

    /// Turn a loop identifier such as `github_tracking` into `Github tracking`.
    /// The raw identifier still renders inside the Details disclosure.
    static func friendlyLoopName(_ loopId: String) -> String {
        let spaced = loopId
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard let first = spaced.first else { return loopId }
        return String(first).uppercased() + spaced.dropFirst()
    }

    static func allLoopsHealthyText(count: Int) -> String {
        count == 1 ? "1 background task is running normally."
                   : "All \(count) background tasks are running normally."
    }

    static func otherLoopsHealthyText(count: Int) -> String {
        count == 1 ? "1 other background task is running normally."
                   : "\(count) other background tasks are running normally."
    }
}

struct DoctorCheckRow: View {
    var check: DoctorCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                InlineStatusDot(status: check.status)
                Text(check.title.withoutStaleNextGenPhaseCopy)
                    .font(NativeAgentFont.section)
                Spacer()
                StatusBadge(text: check.status.uppercased(), status: check.status)
            }
            Text(check.detail.withoutStaleNextGenPhaseCopy)
                .font(NativeAgentFont.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let repair = check.repair, !repair.isEmpty {
                Text(repair.withoutStaleNextGenPhaseCopy)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
