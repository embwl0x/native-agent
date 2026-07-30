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

            if let login = appModel.codexDeviceLogin {
                NativePanel(title: "Codex OAuth", systemImage: "key.fill", tint: .blue) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open \(login.url ?? "https://auth.openai.com/codex/device")")
                            .font(NativeAgentFont.body)
                        Text("Code: \(login.code ?? "pending")")
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                        Text("CODEX_HOME: \(login.codexHome ?? "")")
                            .font(NativeAgentFont.mono)
                            .foregroundStyle(.secondary)
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
            NativePanel(title: "Background loops", systemImage: "arrow.triangle.2.circlepath", tint: loopPanelTint) {
                if loopVerdicts.isEmpty {
                    Text("Loop scheduler not started.")
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(unhealthyLoops) { verdict in
                            HStack(alignment: .firstTextBaseline) {
                                InlineStatusDot(status: verdict.level.statusText)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verdict.loopId)
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
                                Text("\(loopVerdicts.count) loops healthy")
                                    .font(NativeAgentFont.body)
                                    .foregroundStyle(.secondary)
                            }
                        } else if healthyCount > 0 {
                            Text("\(healthyCount) other loops healthy")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .task(id: appModel.doctorRunning) {
                loopVerdicts = await DoctorLoopHealth.current()
            }

            if let report = appModel.doctorReport {
                HStack {
                    Label(report.status.capitalized, systemImage: report.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.status == "ok" ? .green : .orange)
                    if let diagnostics = appModel.supportDiagnostics {
                        StatusBadge(text: "Support \(diagnostics.version)", status: diagnostics.doctorStatus)
                    }
                }

                List {
                    ForEach(groupedChecks, id: \.0) { group, checks in
                        Section(group) {
                            ForEach(checks) { check in
                                DoctorCheckRow(check: check)
                            }
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
